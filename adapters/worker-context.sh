#!/usr/bin/env bash
# Harness-neutral worker pressure bridge. It can publish only the immutable
# context event that dispatch.sh already owns; it has no continuation-launch,
# terminal, transcript, route, or credential interface.
set -uo pipefail

SELF="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
HERE="$(dirname -- "$SELF")"
# Dynamic sibling resolved from this script's canonical directory.
# shellcheck disable=SC1091
. "$HERE/runtime-scope.sh"
WORKER_INSTRUCTION='AFK CONTINUATION REQUIRED: stop at the next safe boundary. Write or refresh the canonical <story>.continuation.json artifact (schema afk-continuation/1 with completed, current_state, remaining_acceptance, next_steps, updated_at, in_flight, and unretired_findings), print exactly one CONTINUATION-REQUIRED: line with a non-secret reason, then end this worker turn. Do not launch a successor or continue implementation after that boundary; only the owning PM may dispatch the next cycle.'
PM_INSTRUCTION='AFK PM CONTINUATION REQUIRED: stop taking new work at the next safe boundary. Following the managed PM instructions, write the secret-free continuation with agent-flow-kit pm-checkpoint --continuation --write <json>, then run agent-flow-kit pm-continue without waiting for another human prompt and end this PM turn. Do not directly launch or close a terminal; pm-continue owns the acknowledged handoff.'

routed_worker() {
  local name
  for name in AFK_WORKER_IDENTITY AFK_RUN_ID AFK_STORY_ID AFK_STORY_PATH AFK_CYCLE \
    AFK_DISPATCH_ID AFK_OWNING_PM AFK_DELEGATING_PM AFK_CONTEXT_EVENT_HOOK AFK_CONTEXT_EVENT_DIR; do
    [[ -n "${!name:-}" ]] || return 1
  done
  [[ "$AFK_WORKER_IDENTITY" == worker:* && "$AFK_CYCLE" =~ ^[1-9][0-9]*$ \
    && "$AFK_OWNING_PM" == "run:$AFK_RUN_ID" && "$AFK_CONTEXT_EVENT_HOOK" == /* \
    && -x "$AFK_CONTEXT_EVENT_HOOK" ]]
}

pm_binding() { # harness session
  local harness="$1" session="$2" pm_dir terminal owner actual
  pm_dir="${AFK_PM_DIR:-$(afk_default_pm_dir 2>/dev/null || true)}"
  terminal="${ORCA_TERMINAL_HANDLE:-}"
  [[ -n "$pm_dir" && -n "$terminal" && -n "$session" && -r "$pm_dir/ownership.json" ]] || return 1
  actual="$(pwd -P 2>/dev/null || true)"; [[ -n "$actual" ]] || return 1
  owner="$pm_dir/ownership.json"
  jq -e --arg h "$harness" --arg s "$session" --arg t "$terminal" --arg p "$actual" '
    .schema=="afk-pm-ownership/2" and .owned==true and .role=="PM"
    and .harness==$h and .session==$s and .terminal==$t and .worktree.path==$p
    and (.worktree.id|type)=="string" and (.worktree.id|length)>0' "$owner" >/dev/null 2>&1
}

binding_kind() { # harness session
  if routed_worker; then printf 'worker\n'
  elif pm_binding "$1" "$2"; then printf 'pm\n'
  else printf 'none\n'; fi
}

record_pm_pressure() { # harness session kind [used-ppm]
  local harness="$1" session="$2" kind="${3:-COMPACTION}" used_ppm="${4:-}" pm_dir owner now epoch tmp
  pm_binding "$harness" "$session" || return 0
  case "$kind" in COMPACTION|CONTEXT_PERCENTAGE) : ;; *) return 0 ;; esac
  [[ -z "$used_ppm" || "$used_ppm" =~ ^[0-9]+$ ]] || return 0
  pm_dir="${AFK_PM_DIR:-$(afk_default_pm_dir 2>/dev/null || true)}"; owner="$pm_dir/ownership.json"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; epoch="$(date +%s)"
  tmp="$pm_dir/.pressure.tmp.$$"
  jq -nc --arg h "$harness" --arg s "$session" --arg t "${ORCA_TERMINAL_HANDLE:-}" --arg kind "$kind" \
    --arg wi "$(jq -r .worktree.id "$owner")" --arg wp "$(jq -r .worktree.path "$owner")" \
    --arg at "$now" --arg used "$used_ppm" --argjson epoch "$epoch" \
    --argjson fresh "$(jq -r '.freshness_seconds // 120' "$owner")" \
    '{schema:"afk-pm-pressure/1",kind:$kind,harness:$h,session:$s,terminal:$t,
      worktree:{id:$wi,path:$wp},observed_at:$at,observed_epoch:$epoch,freshness_seconds:$fresh,
      used_ppm:(if $used=="" then null else ($used|tonumber) end)}' >"$tmp" \
    && chmod 600 "$tmp" && mv -f -- "$tmp" "$pm_dir/pressure.json"
  rm -f -- "$tmp" 2>/dev/null || true
}

policy_ppm() { # threshold-key
  local key="$1" policy line value
  policy="${AGENT_FLOW_BUDGET_POLICY:-${AFK_SKILLS_HOME:+$AFK_SKILLS_HOME/model-router/context-budget-policy.yaml}}"
  [[ -n "$policy" && -r "$policy" ]] || return 1
  line="$(grep -E "^${key}:[[:space:]]+[0-9]+(\.[0-9]+)?[[:space:]]*(#.*)?$" "$policy" 2>/dev/null | head -1)"
  [[ -n "$line" ]] || return 1
  value="${line#*:}"; value="${value%%#*}"; value="${value//[[:space:]]/}"
  awk -v r="$value" 'BEGIN { if (r < 0 || r > 1) exit 1; printf "%d", (r * 1000000) + 0.5 }'
}

sha256_text() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  else return 1; fi
}

publish_state() { # state source [used window]
  local state="$1" source="$2" used="${3:-}" window="${4:-}" key lock marker tmp bound seconds rc=0
  routed_worker || return 0
  case "$state" in CHECKPOINT_DUE|CONTINUATION_REQUIRED) : ;; *) return 0 ;; esac
  command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || return 0
  mkdir -p -- "$AFK_CONTEXT_EVENT_DIR" 2>/dev/null || return 0
  chmod 700 "$AFK_CONTEXT_EVENT_DIR" 2>/dev/null || true
  key="$(printf '%s\0%s' "$AFK_DISPATCH_ID" "$state" | sha256_text 2>/dev/null)" || return 0
  lock="$AFK_CONTEXT_EVENT_DIR/.publisher-$key.lock"
  marker="$AFK_CONTEXT_EVENT_DIR/.publisher-$key.done"
  exec 9>"$lock" || return 0
  chmod 600 "$lock" 2>/dev/null || true
  flock -n 9 || { exec 9>&-; return 0; }
  [[ ! -e "$marker" ]] || { flock -u 9; exec 9>&-; return 0; }

  bound=""; command -v timeout >/dev/null 2>&1 && bound=timeout
  [[ -n "$bound" ]] || { command -v gtimeout >/dev/null 2>&1 && bound=gtimeout; }
  [[ -n "$bound" ]] || { flock -u 9; exec 9>&-; return 0; }
  seconds="${AFK_CONTEXT_PUBLISH_TIMEOUT_SECONDS:-4}"
  [[ "$seconds" =~ ^[1-9][0-9]*$ ]] && (( seconds <= 10 )) || seconds=4
  local -a args=(--emit-context-event --state "$state" --phase harness-pressure --source "$source")
  [[ "$used" =~ ^[0-9]+$ ]] && args+=(--used-tokens "$used")
  [[ "$window" =~ ^[1-9][0-9]*$ ]] && args+=(--window-tokens "$window")
  env -i HOME="${HOME:-}" PATH="${PATH:-/usr/local/bin:/usr/bin:/bin}" \
    AFK_WORKER_IDENTITY="$AFK_WORKER_IDENTITY" AFK_RUN_ID="$AFK_RUN_ID" \
    AFK_STORY_ID="$AFK_STORY_ID" AFK_STORY_PATH="$AFK_STORY_PATH" AFK_CYCLE="$AFK_CYCLE" \
    AFK_DISPATCH_ID="$AFK_DISPATCH_ID" AFK_OWNING_PM="$AFK_OWNING_PM" \
    AFK_DELEGATING_PM="$AFK_DELEGATING_PM" AFK_CONTEXT_EVENT_DIR="$AFK_CONTEXT_EVENT_DIR" \
    AFK_WORKER_TERMINAL="${AFK_WORKER_TERMINAL:-}" ORCA_TERMINAL_HANDLE="${ORCA_TERMINAL_HANDLE:-}" \
    AFK_CONTEXT_EVENT_TRANSPORT="${AFK_CONTEXT_EVENT_TRANSPORT:-orca}" \
    AFK_CONTEXT_ORCA_TIMEOUT_SECONDS="${AFK_CONTEXT_ORCA_TIMEOUT_SECONDS:-3}" \
    AFK_ORCA_BIN="${AFK_ORCA_BIN:-}" ORCA_CLI_COMMAND="${ORCA_CLI_COMMAND:-}" \
    "$bound" "$seconds" "$AFK_CONTEXT_EVENT_HOOK" "${args[@]}" >/dev/null 2>&1 || rc=$?
  if (( rc == 0 )); then
    tmp="$marker.tmp.$$"
    jq -nc --arg dispatch "$AFK_DISPATCH_ID" --arg state "$state" \
      '{schema:"afk-worker-context-publication/1",dispatch_id:$dispatch,state:$state}' >"$tmp" \
      && chmod 600 "$tmp" && mv -f -- "$tmp" "$marker"
  fi
  flock -u 9; exec 9>&-
  return 0
}

observe_claude() { # input file
  local input="$1" percentage used_ppm checkpoint continuation state='' window='' used='' session kind
  [[ -r "$input" ]] || return 0
  session="$(jq -r '.session_id // .sessionID // .session.id // empty' "$input" 2>/dev/null || true)"
  kind="$(binding_kind claude "$session")"; [[ "$kind" != none ]] || return 0
  percentage="$(jq -er '.context_window.used_percentage
    | select(type=="number" and .>=0 and .<=100)' "$input" 2>/dev/null)" || return 0
  used_ppm="$(jq -nr --arg p "$percentage" '$p|tonumber|.*10000|floor')" || return 0
  if [[ "$kind" == pm ]]; then
    continuation="$(policy_ppm continuation_ratio 2>/dev/null)" || return 0
    (( used_ppm >= continuation )) && record_pm_pressure claude "$session" CONTEXT_PERCENTAGE "$used_ppm"
    return 0
  fi
  checkpoint="${AFK_CONTEXT_CHECKPOINT_PPM:-}"; continuation="${AFK_CONTEXT_CONTINUATION_PPM:-}"
  [[ "$checkpoint" =~ ^[0-9]+$ && "$continuation" =~ ^[0-9]+$ ]] || return 0
  (( checkpoint >= 0 && checkpoint < continuation && continuation <= 1000000 )) || return 0
  if (( used_ppm >= continuation )); then state=CONTINUATION_REQUIRED
  elif (( used_ppm >= checkpoint )); then state=CHECKPOINT_DUE
  else return 0; fi
  window="$(jq -r '.context_window.context_window_size
    | select(type=="number" and .>0 and floor==.) // empty' "$input" 2>/dev/null || true)"
  if [[ "$window" =~ ^[1-9][0-9]*$ ]]; then
    used="$(jq -nr --arg p "$percentage" --argjson w "$window" '$p|tonumber|($w*./100)|floor')" || used=''
  fi
  publish_state "$state" CLAUDE_USED_PERCENTAGE "$used" "$window"
}

prompt_boundary_instruction() { # harness input-file-or-empty
  local harness="$1" input="$2" payload='' event='' session='' pressure pm_dir now
  [[ "$harness" == claude ]] || return 0
  if [[ -n "$input" ]]; then
    [[ -r "$input" ]] || return 0
    payload="$(cat -- "$input" 2>/dev/null || true)"
  else
    payload="$(cat 2>/dev/null || true)"
  fi
  event="$(jq -r '.hook_event_name // empty' <<<"$payload" 2>/dev/null || true)"
  session="$(jq -r '.session_id // .sessionID // .session.id // empty' <<<"$payload" 2>/dev/null || true)"
  [[ "$event" == UserPromptSubmit ]] || return 0
  pm_binding claude "$session" || return 0
  pm_dir="${AFK_PM_DIR:-$(afk_default_pm_dir 2>/dev/null || true)}"; [[ -r "$pm_dir/pressure.json" ]] || return 0
  pressure="$pm_dir/pressure.json"; now="$(date +%s)"
  jq -e --arg s "$session" --arg t "${ORCA_TERMINAL_HANDLE:-}" --arg p "$(pwd -P)" --argjson now "$now" '
    .schema=="afk-pm-pressure/1" and .kind=="CONTEXT_PERCENTAGE" and .harness=="claude"
    and .session==$s and .terminal==$t and .worktree.path==$p
    and (.worktree.id|type)=="string" and (.worktree.id|length)>0
    and (.observed_epoch|type)=="number" and (.freshness_seconds|type)=="number"
    and $now>=.observed_epoch and ($now-.observed_epoch)<=.freshness_seconds' "$pressure" >/dev/null 2>&1 || return 0
  jq -nc --arg context "$PM_INSTRUCTION" \
    '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$context}}' 2>/dev/null || true
}

session_start_instruction() { # harness input-file-or-empty format explicit-session
  local harness="$1" input="$2" format="$3" session="$4" source='' kind instruction
  if [[ -n "$input" ]]; then
    [[ -r "$input" ]] || return 0
    source="$(jq -r '.source // empty' "$input" 2>/dev/null || true)"
    [[ -n "$session" ]] || session="$(jq -r '.session_id // .sessionID // .session.id // empty' "$input" 2>/dev/null || true)"
  else
    local payload
    payload="$(cat 2>/dev/null || true)"
    source="$(jq -r '.source // empty' <<<"$payload" 2>/dev/null || true)"
    [[ -n "$session" ]] || session="$(jq -r '.session_id // .sessionID // .session.id // empty' <<<"$payload" 2>/dev/null || true)"
  fi
  [[ "$source" == compact ]] || return 0
  kind="$(binding_kind "$harness" "$session")"; [[ "$kind" != none ]] || return 0
  if [[ "$kind" == worker ]]; then instruction="$WORKER_INSTRUCTION"; else instruction="$PM_INSTRUCTION"; fi
  if [[ "$format" == text ]]; then printf '%s\n' "$instruction"; return 0; fi
  case "$harness" in claude|codex)
    jq -nc --arg h SessionStart --arg context "$instruction" \
      '{hookSpecificOutput:{hookEventName:$h,additionalContext:$context}}' 2>/dev/null || true ;;
  esac
}

mode="${1:-}"; shift || true
harness=""; input=""; format=json; state=""; source=""; used=""; window=""; session=""
while (( $# )); do
  case "$1" in
    --harness) harness="${2:-}"; shift 2 ;;
    --input) input="${2:-}"; shift 2 ;;
    --format) format="${2:-}"; shift 2 ;;
    --state) state="${2:-}"; shift 2 ;;
    --source) source="${2:-}"; shift 2 ;;
    --used-tokens) used="${2:-}"; shift 2 ;;
    --window-tokens) window="${2:-}"; shift 2 ;;
    --session) session="${2:-}"; shift 2 ;;
    *) exit 0 ;;
  esac
done
case "$harness" in claude|codex|opencode) : ;; *) exit 0 ;; esac
case "$mode" in
  observe) [[ "$harness" == claude && -n "$input" ]] && observe_claude "$input" || true ;;
  compact)
    compact_event=""; payload=""
    if [[ -n "$input" && -r "$input" ]]; then
      compact_event="$(jq -r '.hook_event_name // empty' "$input" 2>/dev/null || true)"
      [[ -n "$session" ]] || session="$(jq -r '.session_id // .sessionID // .session.id // empty' "$input" 2>/dev/null || true)"
    elif [[ "$harness" != opencode ]]; then
      payload="$(cat 2>/dev/null || true)"
      compact_event="$(jq -r '.hook_event_name // empty' <<<"$payload" 2>/dev/null || true)"
      [[ -n "$session" ]] || session="$(jq -r '.session_id // .sessionID // .session.id // empty' <<<"$payload" 2>/dev/null || true)"
    fi
    if [[ "$harness" == opencode ]]; then [[ -n "$session" ]] || exit 0
    else [[ "$compact_event" == PreCompact ]] || exit 0; fi
    kind="$(binding_kind "$harness" "$session")"
    if [[ "$kind" == worker ]]; then
      ("$SELF" publish --harness "$harness" --state CONTINUATION_REQUIRED \
        --source "${harness^^}_COMPACTION" >/dev/null 2>&1 </dev/null &)
    elif [[ "$kind" == pm ]]; then
      record_pm_pressure "$harness" "$session" || true
    fi ;;
  session-start) session_start_instruction "$harness" "$input" "$format" "$session" ;;
  prompt-boundary) prompt_boundary_instruction "$harness" "$input" ;;
  instruction)
    kind="$(binding_kind "$harness" "$session")"
    if [[ "$kind" == worker ]]; then printf '%s\n' "$WORKER_INSTRUCTION"
    elif [[ "$kind" == pm ]]; then printf '%s\n' "$PM_INSTRUCTION"; fi ;;
  publish) publish_state "$state" "$source" "$used" "$window" ;;
esac
exit 0
