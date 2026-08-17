#!/usr/bin/env bash
# dispatch.sh — spawn one worker session for one story, per its route: frontmatter.
#
# Usage:   dispatch.sh path/to/story.md [cycle]
# Deps:    yq (mikefarah v4+), jq, claude CLI, codex CLI (whichever providers you route to)
# Exit:    0 = done, gates green
#          1 = worker finished but gates failed (feed review notes, re-dispatch next cycle)
#          2 = spawn/config error
#          3 = worker is blocked and needs a human (NEEDS-HUMAN marker)
#
# Billing note: this intentionally uses `claude -p` (plan-billed as of Aug 2026) and
# `codex exec` (plan-billed). Never add --bare or export ANTHROPIC_API_KEY here —
# either one silently moves Claude spawns to metered API billing.

set -euo pipefail

STORY="${1:?usage: dispatch.sh <story.md> [cycle]}"
CYCLE="${2:-1}"
ROUTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBS="${SUBSCRIPTIONS_FILE:-$ROUTER_DIR/subscriptions.yaml}"
AGENT_DIR="${AGENT_DIR:-.bmad/agents}"          # where BMAD persona .md files live
PERMISSION_MODE="${PERMISSION_MODE:-acceptEdits}" # claude permission mode for workers
SESSION_FILE="$(mktemp)"; trap 'rm -f "$SESSION_FILE"' EXIT  # runners execute in subshells, so session_id rides a file

for dep in yq jq; do
  command -v "$dep" >/dev/null || { echo "dispatch: missing dependency: $dep" >&2; exit 2; }
done
[[ -f "$STORY" ]] || { echo "dispatch: no such story: $STORY" >&2; exit 2; }
[[ -f "$SUBS"  ]] || { echo "dispatch: no registry at $SUBS" >&2; exit 2; }

# The worker's sandbox is rooted at $PWD — a story outside it is unreadable to the
# worker even though it's readable here. Mirror the story (gitignored) into the
# worktree and dispatch from there instead.
case "$(realpath "$STORY")" in
  "$(realpath "$PWD")"/*) ;;
  *) echo "dispatch: story is OUTSIDE the current directory ($PWD) — the sandboxed worker cannot read it. cd into the worktree and use a story path inside it." >&2; exit 2 ;;
esac

fm() { yq --front-matter=extract -r "$1 // \"\"" "$STORY"; }

PROVIDER="$(fm '.route.provider')"
MODEL="$(fm '.route.model')"
EFFORT="$(fm '.route.effort')"
AGENT="$(fm '.route.agent')"
MAX_CYCLES="$(fm '.max_cycles')"; MAX_CYCLES="${MAX_CYCLES:-3}"
mapfile -t GATES     < <(yq --front-matter=extract -r '.gates[]?'          "$STORY")
mapfile -t FALLBACKS < <(yq --front-matter=extract -r '.route.fallback[]?' "$STORY")

[[ -n "$PROVIDER" && -n "$MODEL" ]] || { echo "dispatch: story has no route.provider/model" >&2; exit 2; }
(( CYCLE <= MAX_CYCLES )) || { echo "dispatch: max_cycles ($MAX_CYCLES) exceeded — escalate to human" >&2; exit 3; }

PROMPT="You are the ${AGENT:-dev} agent. Execute the story file at ${STORY} (cycle ${CYCLE} of ${MAX_CYCLES}).
Read it fully. Implement until every acceptance criterion is satisfied. Run the gate
commands listed in its frontmatter yourself before you consider the work complete, and
record what you did in the story's Dev Agent Record section.
If you hit a decision that genuinely needs a human, print one line starting with
'NEEDS-HUMAN:' describing the question, then stop."

# ---- provider runners -------------------------------------------------------

run_claude() {  # args: model effort -> prints worker's final text; session_id via $SESSION_FILE
  local model="$1" effort="$2" raw rc
  local persona_args=()
  [[ -n "$AGENT" && -f "$AGENT_DIR/$AGENT.md" ]] && persona_args=(--append-system-prompt-file "$AGENT_DIR/$AGENT.md")
  raw="$(claude -p "$PROMPT" \
          --model "$model" \
          ${effort:+--effort "$effort"} \
          "${persona_args[@]}" \
          --permission-mode "$PERMISSION_MODE" \
          --output-format json)"; rc=$?
  # Surface text + session even on failure, so the caller can spot rate-limit errors
  jq -r '.result // ""' <<<"$raw" 2>/dev/null || printf '%s' "$raw"
  jq -r '.session_id // ""' <<<"$raw" 2>/dev/null > "$SESSION_FILE" || : > "$SESSION_FILE"
  (( rc == 0 )) || return 1
  [[ "$(jq -r '.is_error // false' <<<"$raw" 2>/dev/null)" == "true" ]] && return 1
  return 0
}

run_codex() {   # args: model effort -> prints worker's final message
  local model="$1" effort="$2" out ce=""
  case "$effort" in xhigh|high) ce="high" ;; medium) ce="medium" ;; low) ce="low" ;; esac
  out="$(mktemp)"
  # persona: codex has no system-prompt flag in exec; prepend persona to the prompt
  local full_prompt="$PROMPT"
  [[ -n "$AGENT" && -f "$AGENT_DIR/$AGENT.md" ]] && full_prompt="$(cat "$AGENT_DIR/$AGENT.md")

$PROMPT"
  codex exec --model "$model" \
    ${ce:+--config model_reasoning_effort="$ce"} \
    --full-auto --skip-git-repo-check \
    -o "$out" "$full_prompt" >/dev/null || { cat "$out" 2>/dev/null; rm -f "$out"; return 1; }
  : > "$SESSION_FILE"   # codex follow-ups: `codex exec resume --last` from the same directory
  cat "$out"; rm -f "$out"
}

run_devin() {   # args: model effort -> prints worker's final message
  local model="$1" effort="$2"   # effort unused: devin bakes it into the model id suffix
  # persona: like codex, no system-prompt flag in print mode; prepend persona to the prompt
  local full_prompt="$PROMPT"
  [[ -n "$AGENT" && -f "$AGENT_DIR/$AGENT.md" ]] && full_prompt="$(cat "$AGENT_DIR/$AGENT.md")

$PROMPT"
  # map claude-style PERMISSION_MODE to devin's modes; trust check off — print mode can't show the prompt
  local pm="accept-edits"
  case "$PERMISSION_MODE" in
    default|plan)        pm="auto" ;;
    bypassPermissions)   pm="dangerous" ;;
    acceptEdits|*)       pm="accept-edits" ;;
  esac
  devin -p "$full_prompt" --model "$model" \
    --permission-mode "$pm" \
    --respect-workspace-trust false
  : > "$SESSION_FILE"   # devin follow-ups: `devin -c` from the same directory
}

# ---- try primary route, then fallbacks on rate-limit-shaped failures ---------

ROUTES=("$PROVIDER/$MODEL" "${FALLBACKS[@]:-}")
RESULT="" USED_ROUTE="" SESSION_ID="" SPAWN_OK=false

for route in "${ROUTES[@]}"; do
  [[ -z "$route" ]] && continue
  prov="${route%%/*}"; model="${route##*/}"
  cli="$(yq -r ".providers.\"$prov\".cli // \"\"" "$SUBS")"
  [[ -n "$cli" ]] || { echo "dispatch: provider '$prov' not in registry, skipping" >&2; continue; }
  echo "dispatch: [$STORY] cycle $CYCLE -> $prov/$model via $cli" >&2

  set +e
  case "$cli" in
    claude) RESULT="$(run_claude "$model" "$EFFORT")" ;;
    codex)  RESULT="$(run_codex  "$model" "$EFFORT")" ;;
    devin)  RESULT="$(run_devin  "$model" "$EFFORT")" ;;
    *)      echo "dispatch: no runner for cli '$cli'" >&2; RESULT=""; false ;;
  esac
  rc=$?
  set -e

  if (( rc == 0 )); then SPAWN_OK=true; USED_ROUTE="$route"; break; fi
  if grep -qiE 'rate.?limit|usage limit|limit reached|overloaded|quota' <<<"$RESULT"; then
    echo "dispatch: $route looks rate-limited, trying fallback" >&2; continue
  fi
  USED_ROUTE="$route"; break   # real failure — don't burn the other pool on it
done

$SPAWN_OK || { echo "dispatch: worker spawn failed on all routes" >&2; exit 2; }
SESSION_ID="$(cat "$SESSION_FILE" 2>/dev/null || true)"

# ---- human-needed marker ------------------------------------------------------

rm -f "${STORY}.blocked"   # clear stale marker from an earlier cycle
if grep -q '^NEEDS-HUMAN:' <<<"$RESULT"; then
  grep '^NEEDS-HUMAN:' <<<"$RESULT" > "${STORY}.blocked"
  echo "dispatch: worker is blocked — see ${STORY}.blocked" >&2
  exit 3
fi

# ---- deterministic gates: never trust the worker's word -----------------------

declare -A GATE_RESULTS; GATES_OK=true
for g in "${GATES[@]:-}"; do
  [[ -z "$g" ]] && continue
  if bash -c "$g" >/dev/null 2>&1; then GATE_RESULTS["$g"]="pass"
  else GATE_RESULTS["$g"]="fail"; GATES_OK=false; fi
done

# ---- write a thin result the PM can read without loading the transcript -------

{
  jq -n \
    --arg story "$STORY" --arg cycle "$CYCLE" --arg route "$USED_ROUTE" \
    --arg session "$SESSION_ID" \
    --arg status "$([[ $GATES_OK == true ]] && echo done || echo gates_failed)" \
    --argjson gates "$(for k in "${!GATE_RESULTS[@]}"; do jq -n --arg k "$k" --arg v "${GATE_RESULTS[$k]}" '{($k):$v}'; done | jq -s 'add // {}')" \
    '{story:$story, cycle:($cycle|tonumber), route:$route, session_id:$session, status:$status, gates:$gates}'
} > "${STORY}.result.json"

echo "dispatch: $(jq -c . "${STORY}.result.json")" >&2
[[ "$GATES_OK" == true ]] && exit 0 || exit 1
