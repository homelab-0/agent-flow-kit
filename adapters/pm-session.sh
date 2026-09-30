#!/usr/bin/env bash
# Publish PM ownership and pressure only for the exact Orca-backed harness
# session that emitted the event.  This adapter is deliberately fail-closed:
# an incomplete or conflicting identity produces no state.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Dynamic sibling resolved from this script's canonical directory.
# shellcheck disable=SC1091
. "$HERE/runtime-scope.sh"

mode="${1:-observe}"; shift || true
harness=""; session=""; input=""; event_type=""
while (($#)); do
  case "$1" in
    --harness) harness="${2:?}"; shift 2 ;;
    --session) session="${2:?}"; shift 2 ;;
    --input) input="${2:?}"; shift 2 ;;
    --event-type) event_type="${2:?}"; shift 2 ;;
    *) exit 2 ;;
  esac
done
case "$mode" in observe|start) : ;; *) exit 2 ;; esac
case "$harness" in claude|codex|opencode) : ;; *) exit 0 ;; esac

default_pm_dir="$(afk_default_pm_dir 2>/dev/null || true)"
pm_dir="${AFK_PM_DIR:-$default_pm_dir}"
terminal="${ORCA_TERMINAL_HANDLE:-}"
run_id="${ORCA_RUN_ID:-}"
[[ -n "$pm_dir" && -n "$terminal" ]] || exit 0
actual_path="$(pwd -P 2>/dev/null || true)"
[[ -n "$actual_path" ]] || exit 0
# shellcheck disable=SC1091
if [[ -r "$HERE/lib/afk-orca.sh" ]]; then . "$HERE/lib/afk-orca.sh"; else . "$HERE/../lib/afk-orca.sh"; fi
afk_orca_bound_tool >/dev/null || exit 0

# Sets observed_worktree. Runs in this shell so the resolver's verdict is
# cached for the rest of the process.
observed_worktree=""
observe_worktree() {
  local shown shown_id shown_path
  observed_worktree=""
  afk_orca_run pm-session-worktree -- worktree show --worktree "path:$actual_path" --json || return 1
  shown="$AFK_ORCA_OUT"
  shown_id="$(jq -r '.result.worktree.id // .result.id // .worktree.id // .id // empty' <<<"$shown" 2>/dev/null)"
  shown_path="$(jq -r '.result.worktree.path // .result.path // .worktree.path // .path // empty' <<<"$shown" 2>/dev/null)"
  shown_path="$(cd "$shown_path" 2>/dev/null && pwd -P || true)"
  [[ -n "$shown_id" && "$shown_path" == "$actual_path" ]] || return 1
  observed_worktree="$shown_id"
}

if [[ "$mode" == observe && -z "$session" && -n "$input" && -r "$input" ]]; then
  session="$(jq -r '.session_id // .sessionID // .session.id // empty' "$input" 2>/dev/null || true)"
fi
[[ "$mode" == start || -n "$session" ]] || exit 0

mkdir -p "$pm_dir" 2>/dev/null || exit 0
chmod 700 "$pm_dir" 2>/dev/null || exit 0
command -v flock >/dev/null 2>&1 || exit 0
exec 9>"$pm_dir/.publisher.lock" || exit 0
flock -n 9 || exit 0

atomic_write() {
  local target="$1" value="$2" tmp target_dir
  target_dir="$(dirname -- "$target")"
  mkdir -p -- "$target_dir" || return 1
  tmp="$(mktemp "$target_dir/.pm-session.XXXXXX")" || return 1
  printf '%s\n' "$value" >"$tmp" && chmod 600 "$tmp" && mv -f -- "$tmp" "$target" || return 1
  jq -e --argjson expected "$value" '.==$expected' "$target" >/dev/null 2>&1
}

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; epoch="$(date +%s)"
freshness="${AFK_PM_FRESHNESS_SECONDS:-120}"
[[ "$freshness" =~ ^[1-9][0-9]*$ ]] || freshness=120
owner_file="$pm_dir/ownership.json"; handoff_file="$pm_dir/handoff.json"
intent_file="$pm_dir/registration-intent.json"
if [[ "$mode" == start ]]; then
  # A human explicitly authorizes the next exact harness event in this exact
  # Orca terminal.  Existing ownership or any handoff (including malformed
  # state) makes a new registration ambiguous and is refused.
  [[ ! -e "$owner_file" && ! -e "$handoff_file" ]] || exit 1
  observe_worktree || exit 1
  worktree_id="$observed_worktree"
  run_id=""
  if afk_orca_run pm-session-run-current -- orchestration run-current --from "$terminal" --json; then
    current_run="$AFK_ORCA_OUT"
    run_id="$(jq -r '.result.run.id // .result.id // .run.id // .id // empty' <<<"$current_run" 2>/dev/null || true)"
  fi
  intent_json="$(jq -nc --arg h "$harness" --arg t "$terminal" --arg wi "$worktree_id" \
    --arg wp "$actual_path" --arg run "$run_id" --arg at "$now" --argjson epoch "$epoch" --argjson fresh "$freshness" \
    '{schema:"afk-pm-registration-intent/1",harness:$h,terminal:$t,worktree:{id:$wi,path:$wp},
      run_id:(if $run=="" then null else $run end),created_at:$at,created_epoch:$epoch,freshness_seconds:$fresh}')"
  atomic_write "$intent_file" "$intent_json"
  # Codex does not provide a continuous status-line event.  When invoked from
  # an existing Codex thread, its native thread id is the exact session claim.
  if [[ "$harness" == codex && -n "${CODEX_THREAD_ID:-}" ]]; then
    flock -u 9
    exec "$0" observe --harness codex --session "$CODEX_THREAD_ID"
  fi
  exit 0
fi
owner=""; handoff=""; previous="null"; transition="null"
[[ ! -f "$owner_file" ]] || owner="$(jq -c . "$owner_file" 2>/dev/null || true)"
[[ ! -f "$handoff_file" ]] || handoff="$(jq -c . "$handoff_file" 2>/dev/null || true)"
intent=""; [[ ! -f "$intent_file" ]] || intent="$(jq -c . "$intent_file" 2>/dev/null || true)"

# Select the expected binding from durable state, never from ambient
# ORCA_WORKTREE_ID (which can name the parent checkout in child worktrees).
binding=""
if [[ -n "$owner" ]] && jq -e --arg h "$harness" --arg s "$session" --arg t "$terminal" --arg wp "$actual_path" \
  '.schema=="afk-pm-ownership/2" and .owned==true and .harness==$h and .session==$s and
   .terminal==$t and .worktree.path==$wp and (.worktree.id|type)=="string" and (.worktree.id|length)>0' <<<"$owner" >/dev/null 2>&1; then
  binding="$(jq -c '{worktree,run_id}' <<<"$owner")"
elif [[ -n "$owner" && -n "$handoff" ]] && jq -e --arg h "$harness" --arg t "$terminal" --arg wp "$actual_path" \
  '.schema=="afk-pm-handoff/2" and .state=="SUCCESSOR_LAUNCHED" and .successor.harness==$h and
   .successor.terminal==$t and .successor.worktree.path==$wp and (.successor.worktree.id|type)=="string"' <<<"$handoff" >/dev/null 2>&1; then
  binding="$(jq -c '{worktree:.successor.worktree,run_id:.successor.run_id}' <<<"$handoff")"
elif [[ -z "$owner" && ! -e "$handoff_file" && -n "$intent" ]] && jq -e --arg h "$harness" --arg t "$terminal" --arg wp "$actual_path" --argjson now "$epoch" \
  '.schema=="afk-pm-registration-intent/1" and .harness==$h and .terminal==$t and .worktree.path==$wp and
   (.worktree.id|type)=="string" and (.worktree.id|length)>0 and (.created_epoch|type)=="number" and
   (.freshness_seconds|type)=="number" and $now>=.created_epoch and ($now-.created_epoch)<=.freshness_seconds' <<<"$intent" >/dev/null 2>&1; then
  binding="$(jq -c '{worktree,run_id}' <<<"$intent")"
fi
[[ -n "$binding" ]] || exit 0
worktree_id="$(jq -r .worktree.id <<<"$binding")"; declared_path="$(jq -r .worktree.path <<<"$binding")"
bound_run="$(jq -r '.run_id // empty' <<<"$binding")"
[[ -z "$run_id" || "$run_id" == "$bound_run" ]] || exit 0
run_id="$bound_run"

same_owner=false
if [[ -n "$owner" ]] && jq -e --arg h "$harness" --arg s "$session" --arg t "$terminal" \
  --arg wi "$worktree_id" --arg wp "$declared_path" \
  '.schema=="afk-pm-ownership/2" and .owned==true and .harness==$h and .session==$s and .terminal==$t and .worktree.id==$wi and .worktree.path==$wp' \
  <<<"$owner" >/dev/null 2>&1; then
  same_owner=true
  previous="$(jq -c '.previous // null' <<<"$owner")"
  transition="$(jq -c '.transition_id // null' <<<"$owner")"
fi

successor=false
if [[ "$same_owner" != true && -n "$owner" && -n "$handoff" ]] &&
  jq -e --arg h "$harness" --arg t "$terminal" --arg wi "$worktree_id" --arg wp "$declared_path" \
    '.schema=="afk-pm-handoff/2" and .state=="SUCCESSOR_LAUNCHED" and
     .successor.harness==$h and .successor.terminal==$t and
     .successor.worktree.id==$wi and .successor.worktree.path==$wp' <<<"$handoff" >/dev/null 2>&1 &&
  jq -e --argjson old "$(jq -c '.old' <<<"$handoff")" \
    '.schema=="afk-pm-ownership/2" and .owned==true and
     .session==$old.session and .terminal==$old.terminal and .harness==$old.harness and
     .worktree.id==$old.worktree.id and .worktree.path==$old.worktree.path' <<<"$owner" >/dev/null 2>&1; then
  successor=true
  previous="$(jq -c '.old' <<<"$handoff")"
  transition="$(jq -c '.transition_id' <<<"$handoff")"
fi

if [[ -n "$owner" && "$same_owner" != true && "$successor" != true ]]; then
  exit 0
fi

# A successor identity is an observation, not a copy of bootstrap intent. The
# durable handoff is authorization; Orca must independently report that this
# event is running in the same exact worktree before ownership can move.
if [[ "$successor" == true ]]; then
  observe_worktree || exit 0
  observed_worktree_id="$observed_worktree"
  [[ "$observed_worktree_id" == "$worktree_id" ]] || exit 0
fi

owner_json="$(jq -nc --arg h "$harness" --arg s "$session" --arg t "$terminal" \
  --arg wi "$worktree_id" --arg wp "$declared_path" --arg run "$run_id" \
  --arg at "$now" --argjson epoch "$epoch" --argjson fresh "$freshness" \
  --argjson previous "$previous" --argjson transition "$transition" \
  '{schema:"afk-pm-ownership/2",owned:true,role:"PM",harness:$h,session:$s,terminal:$t,
    worktree:{id:$wi,path:$wp},run_id:(if $run=="" then null else $run end),
    observed_at:$at,observed_epoch:$epoch,freshness_seconds:$fresh,
    transition_id:$transition,previous:$previous}')"
atomic_write "$owner_file" "$owner_json" || exit 0
[[ ! -f "$intent_file" ]] || rm -f -- "$intent_file"

reconcile_successor=false
if [[ -n "$handoff" ]] && jq -e --argjson owner "$owner_json" '
  .schema=="afk-pm-handoff/2" and (.state|IN("SUCCESSOR_LAUNCHED","ACKED","OLD_CLOSED")) and
  .transition_id==$owner.transition_id and .successor.terminal==$owner.terminal and
  .successor.harness==$owner.harness and .successor.worktree==$owner.worktree and
  .successor.run_id==$owner.run_id and
  (.state=="SUCCESSOR_LAUNCHED" or .successor.session==$owner.session)' <<<"$handoff" >/dev/null 2>&1; then
  reconcile_successor=true
fi

if [[ "$reconcile_successor" == true ]]; then
  observe_worktree || exit 0
  observed_worktree_id="$observed_worktree"
  [[ "$observed_worktree_id" == "$worktree_id" ]] || exit 0
  tid="$(jq -r '.transition_id' <<<"$handoff")"
  transition_dir="$pm_dir/transitions/$tid"; mkdir -p "$transition_dir" || exit 0
  chmod 700 "$transition_dir" || exit 0
  ack="$(jq -nc --arg id "$tid" --arg h "$harness" --arg s "$session" --arg t "$terminal" \
    --arg wi "$worktree_id" --arg wp "$declared_path" --arg run "$run_id" --arg at "$now" \
    '{schema:"afk-pm-successor-ack/2",transition_id:$id,acknowledged:true,harness:$h,
      session:$s,terminal:$t,worktree:{id:$wi,path:$wp},run_id:(if $run=="" then null else $run end),acknowledged_at:$at}')"
  ack_file="$transition_dir/successor-ack.json"
  if [[ -f "$ack_file" ]]; then
    jq -e --argjson expected "$ack" 'del(.acknowledged_at)==($expected|del(.acknowledged_at))' "$ack_file" >/dev/null 2>&1 || exit 0
  else
    atomic_write "$ack_file" "$ack" || exit 0
  fi
  if [[ "${AFK_PM_AUTOFINALIZE:-1}" == 1 ]]; then
    kit="${AFK_AGENT_FLOW_KIT_BIN:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/agent-flow-kit}"
    if [[ -x "$kit" ]]; then
      pending_file="$transition_dir/finalize-pending.json"
      pending="$(jq -nc --arg id "$tid" --arg s "$session" --arg t "$terminal" \
        '{schema:"afk-pm-finalize-pending/1",transition_id:$id,successor_session:$s,successor_terminal:$t}')"
      if [[ -e "$pending_file" ]]; then
        jq -e --argjson expected "$pending" '.==$expected' "$pending_file" >/dev/null 2>&1 || exit 0
      else
        atomic_write "$pending_file" "$pending" || exit 0
      fi
      (
        exec 9>&-
        attempts="${AFK_PM_FINALIZE_ATTEMPTS:-20}"; delay="${AFK_PM_FINALIZE_RETRY_SECONDS:-0.1}"
        [[ "$attempts" =~ ^[1-9][0-9]*$ ]] || attempts=20
        exec 8>"$transition_dir/.finalizer.lock" || exit 0
        flock -n 8 || exit 0
        while (( attempts-- > 0 )); do
          rc=0
          AFK_PM_ACK_FILE="$transition_dir/successor-ack.json" AFK_PM_CALLER_SESSION="$session" \
            "$kit" pm-continue >/dev/null 2>&1 || rc=$?
          if (( rc == 0 )); then rm -f -- "$pending_file"; exit 0; fi
          (( rc == 2 )) || exit 0
          sleep "$delay"
        done
      ) >/dev/null 2>&1 &
    fi
  fi
fi

usage="null"; window="null"; reason="PM_USAGE_UNOBSERVABLE"; usage_provenance="NOT_EVALUATED"
if [[ "$harness" == claude && -n "$input" && -r "$input" ]]; then
  usage="$(jq -r '(.context_window.current_usage // null) as $u |
    if ($u|type)=="object" then
      [($u.input_tokens // 0),($u.cache_creation_input_tokens // 0),($u.cache_read_input_tokens // 0)] | add
    else null end' "$input" 2>/dev/null || printf null)"
  window="$(jq -r '.context_window.context_window_size // null' "$input" 2>/dev/null || printf null)"
  if [[ "$usage" =~ ^[0-9]+$ && "$window" =~ ^[1-9][0-9]*$ ]]; then
    reason="null"; usage_provenance="CURRENT_USAGE"
  else
    percentage="$(jq -r '.context_window.used_percentage // null' "$input" 2>/dev/null || printf null)"
    if [[ "$window" =~ ^[1-9][0-9]*$ && "$percentage" =~ ^[0-9]+([.][0-9]+)?$ ]] &&
      usage="$(awk -v w="$window" -v p="$percentage" 'BEGIN { if (p<0 || p>100) exit 1; printf "%d", (w*p/100)+0.5 }')"; then
      reason="null"; usage_provenance="USED_PERCENTAGE_DERIVED"
    else usage=null; window=null; fi
  fi
fi
usage_json="$(jq -nc --arg h "$harness" --arg s "$session" --arg t "$terminal" \
  --arg wi "$worktree_id" --arg wp "$declared_path" --arg at "$now" --argjson epoch "$epoch" \
  --argjson fresh "$freshness" --argjson usage "$usage" --argjson window "$window" --arg reason "$reason" --arg up "$usage_provenance" \
  '{schema:"afk-pm-usage/2",harness:$h,session:$s,terminal:$t,worktree:{id:$wi,path:$wp},
    provenance:"HARNESS_ADAPTER",observed_at:$at,observed_epoch:$epoch,freshness_seconds:$fresh,
    usage_tokens:$usage,window_tokens:$window,usage_provenance:$up,
    reason:(if $reason=="null" then null else $reason end)}')"
atomic_write "$pm_dir/usage.json" "$usage_json" || true

pressure=false
if [[ "$harness" == codex && -n "$input" && -r "$input" ]]; then
  hook="$(jq -r '.hook_event_name // empty' "$input" 2>/dev/null || true)"
  source="$(jq -r '.source // empty' "$input" 2>/dev/null || true)"
  [[ "$hook" == PreCompact || "$source" == compact ]] && pressure=true
elif [[ "$harness" == opencode && "$event_type" == session.compacted ]]; then
  pressure=true
fi
if [[ "$pressure" == true ]]; then
  pressure_json="$(jq -nc --arg h "$harness" --arg s "$session" --arg t "$terminal" \
    --arg wi "$worktree_id" --arg wp "$declared_path" --arg at "$now" --argjson epoch "$epoch" --argjson fresh "$freshness" \
    '{schema:"afk-pm-pressure/1",kind:"COMPACTION",harness:$h,session:$s,terminal:$t,
      worktree:{id:$wi,path:$wp},observed_at:$at,observed_epoch:$epoch,freshness_seconds:$fresh}')"
  atomic_write "$pm_dir/pressure.json" "$pressure_json" || true
fi
