#!/usr/bin/env bash
# Command-level: STAGGERED real `agent-flow-kit update` processes against an
# installation carrying one ABANDONED lock. Counts how many are told to remove
# the lock by hand while a successor is reclaiming/holding it.
set -uo pipefail
KIT_ROOT="$1"; ROOT="$2"; ROUNDS="$3"
AFK="$KIT_ROOT/bin/agent-flow-kit"
export GIT_AUTHOR_NAME=afk-test GIT_AUTHOR_EMAIL=afk@test.invalid
export GIT_COMMITTER_NAME=afk-test GIT_COMMITTER_EMAIL=afk@test.invalid
rm -rf "$ROOT"; mkdir -p "$ROOT"
STATE_REL=".local/state/agent-flow-kit"
DELAYS=(0 0.004 0.008 0.012 0.016 0.020 0.024 0.028 0.032 0.040 0.048 0.056 0.064 0.072 0.080 0.090)

make_checkout() {
  local d="$1"
  mkdir -p "$d/lifecycle" "$d/files/model-router/scripts" "$d/files/humanizer/skills/humanizer"
  cat > "$d/lifecycle/kit.json" <<'JSON'
{ "kit_id": "agent-flow-kit", "lifecycle_schema_version": "1.0",
  "state_schema_version": "1.0", "result_schema_version": "1.0",
  "default_branch": "master", "managed_inputs": ["files", "lifecycle"] }
JSON
  printf 'model-router skill v1\n' > "$d/files/model-router/SKILL.md"
  printf 'dispatch v1\n' > "$d/files/model-router/scripts/dispatch.sh"
  printf 'launcher:\n  router_endpoint: https://canonical.invalid\n' > "$d/files/model-router/subscriptions.yaml"
  printf 'humanizer v1\n' > "$d/files/humanizer/SKILL.md"
  printf 'humanizer inner skill v1\n' > "$d/files/humanizer/skills/humanizer/SKILL.md"
  printf 'policy line one\npolicy line two\n' > "$d/files/claude-global-CLAUDE.md"
  printf 'codex guidance v1\n' > "$d/files/codex-AGENTS.md"
  git init -q "$d" >/dev/null 2>&1
  git -C "$d" symbolic-ref HEAD refs/heads/master >/dev/null 2>&1
  git -C "$d" add -A >/dev/null 2>&1
  git -C "$d" -c commit.gpgsign=false commit -q --no-verify -m v1 >/dev/null 2>&1
}
install_kit() {
  local h="$1" c="$2"
  mkdir -p "$h/.agents/skills" "$h/.claude/skills" "$h/.codex"
  cp -R "$c/files/model-router" "$h/.agents/skills/model-router"
  cp -R "$c/files/humanizer" "$h/.agents/skills/humanizer"
  ln -s "$h/.agents/skills/model-router" "$h/.claude/skills/model-router"
  ln -s "$h/.agents/skills/humanizer" "$h/.claude/skills/humanizer"
  { printf '# my own notes\n'
    printf '# >>> agent-flow-kit managed section: claude-global-policy >>>\n'
    cat "$c/files/claude-global-CLAUDE.md"
    printf '# <<< agent-flow-kit managed section: claude-global-policy <<<\n'
    printf '# trailing note\n'; } > "$h/.claude/CLAUDE.md"
  cp "$c/files/codex-AGENTS.md" "$h/.codex/AGENTS.md"
}
strand_lock() { # <home>
  HOME="$1" XDG_STATE_HOME="$1/.local/state" bash -c '
    . "$1/lib/afk-common.sh"; . "$1/lib/afk-source.sh"; . "$1/lib/afk-inventory.sh"
    . "$1/lib/afk-commands.sh"; . "$1/lib/afk-plan.sh"; . "$1/lib/afk-mutate.sh"
    AFK_STATE_DIR="$2"; AFK_LOCK_DIR="$2/lock"
    afk_state_dir_ensure "$AFK_STATE_DIR" || exit 1
    afk_lock_take >/dev/null 2>&1 || exit 1
    printf "%s" "$AFK_LOCK_INCARNATION"' _ "$KIT_ROOT" "$1/$STATE_REL"
}

TOTAL=0; REMOVE=0; UNVER=0; UNAVAIL=0; CONV=0; CONC=0; OTHER=""
for r in $(seq 1 "$ROUNDS"); do
  SC="$ROOT/sc$r"; H="$SC/home"; C="$SC/checkout"; mkdir -p "$H" "$C"
  make_checkout "$C"; install_kit "$H" "$C"
  HOME="$H" XDG_STATE_HOME="$H/.local/state" AFK_KIT_ROOT="$C" bash "$AFK" adopt --json >/dev/null 2>&1
  printf 'model-router skill v2\n' > "$C/files/model-router/SKILL.md"
  git -C "$C" add -A >/dev/null 2>&1; git -C "$C" -c commit.gpgsign=false commit -q --no-verify -m v2 >/dev/null 2>&1
  strand_lock "$H" >/dev/null
  O="$SC/out"; mkdir -p "$O"; pids=(); k=0
  for d in "${DELAYS[@]}"; do
    k=$((k+1))
    ( sleep "$d"; HOME="$H" XDG_STATE_HOME="$H/.local/state" AFK_KIT_ROOT="$C" \
        exec bash "$AFK" update --json ) > "$O/$k" 2>/dev/null & pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; done
  for k in $(seq 1 ${#DELAYS[@]}); do
    TOTAL=$((TOTAL+1))
    res=$(jq -r '.operation.result // "NO_JSON"' "$O/$k" 2>/dev/null)
    rsn=$(jq -r '.operation.reason // ""' "$O/$k" 2>/dev/null)
    nsa=$(jq -r '.next_safe_action // ""' "$O/$k" 2>/dev/null)
    case "$res" in
      CONVERGED|NO_CHANGE) CONV=$((CONV+1)) ;;
      REFUSED) : ;;
      *) OTHER="$OTHER $r/$k:$res" ;;
    esac
    case "$rsn" in
      CONCURRENT_OPERATION_IN_PROGRESS) CONC=$((CONC+1)) ;;
      OPERATION_LOCK_OWNER_UNVERIFIABLE) UNVER=$((UNVER+1)) ;;
      OPERATION_LOCK_UNAVAILABLE) UNAVAIL=$((UNAVAIL+1)) ;;
    esac
    if [[ "$nsa" == *"remove"* ]]; then
      REMOVE=$((REMOVE+1))
      echo "REMOVE-GUIDANCE round=$r c=$k reason=$rsn"
      jq -c '{reason:.operation.reason, next:.next_safe_action, ev:[.findings[]?.evidence.observed]}' "$O/$k" 2>/dev/null
    fi
  done
  lockleft=$([[ -e "$H/$STATE_REL/lock" ]] && echo yes || echo no)
  resid=$(ls -A "$H/$STATE_REL" 2>/dev/null | grep -E '^(lock\.stale|lock\.released|\.afk-reclaim)' | tr '\n' ' ')
  [[ "$lockleft" == "yes" || -n "$resid" ]] && echo "round=$r lock_left=$lockleft residue=[$resid]"
  verified=$(HOME="$H" XDG_STATE_HOME="$H/.local/state" AFK_KIT_ROOT="$C" bash "$AFK" verify --json 2>/dev/null | jq -r '.extra.verification.verified')
  [[ "$verified" == "true" ]] || echo "round=$r VERIFY_FAILED verified=$verified"
done
echo "=== TOTAL=$TOTAL converged/nochange=$CONV concurrent=$CONC unverifiable=$UNVER unavailable=$UNAVAIL told_to_remove=$REMOVE other=[$OTHER] ==="
