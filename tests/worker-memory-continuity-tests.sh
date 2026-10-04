#!/usr/bin/env bash
# Test assertions deliberately use A && ok || no, literal jq/shell snippets,
# and globals consumed by the sourced dispatcher.
# shellcheck disable=SC2015,SC2016,SC2034,SC2329
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../files/model-router/scripts/dispatch.sh
# shellcheck disable=SC1091
source "$ROOT/files/model-router/scripts/dispatch.sh"

pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok %d - %s\n' "$((pass + fail))" "$1"; }
no() { fail=$((fail + 1)); printf 'not ok %d - %s\n' "$((pass + fail))" "$1"; }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else no "$name"; fi; }
contains() { grep -Fq -- "$2" <<<"$1"; }

TMP="$(mktemp -d /tmp/afk-worker-continuity.XXXXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT

for mode in advisory required blind off; do
  check "memory mode accepts $mode" memory_mode_is_valid "$mode"
done
if memory_mode_is_valid maybe; then no "memory mode rejects unknown"; else ok "memory mode rejects unknown"; fi

mkdir -p "$TMP/home/.claude" "$TMP/home/.codex" "$TMP/home/.config/opencode" "$TMP/runtime/dist" "$TMP/state"
printf '{"hooks":{"SessionStart":[{"command":"%s/dist/claude-sessionstart-hook.js"}],"UserPromptSubmit":[{"command":"%s/dist/claude-hook.js"}],"Stop":[{"command":"%s/dist/claude-stop-hook.js"}]}}\n' "$TMP/runtime" "$TMP/runtime" "$TMP/runtime" >"$TMP/home/.claude/settings.json"
printf '{"hooks":{"SessionStart":[{"command":"%s/dist/codex-sessionstart-hook.js"}],"UserPromptSubmit":[{"command":"%s/dist/codex-hook.js"}],"Stop":[{"command":"%s/dist/codex-stop-hook.js"}]}}\n' "$TMP/runtime" "$TMP/runtime" "$TMP/runtime" >"$TMP/home/.codex/hooks.json"
jq -nc --arg p "$TMP/runtime" '{plugin:[$p,"/unrelated/plugin"]}' >"$TMP/home/.config/opencode/opencode.json"
printf '{}\n' >"$TMP/native-config.json"
cat >"$TMP/hindsight-helper" <<'EOF'
#!/usr/bin/env bash
jq -nc --arg m "$1" --arg p "$2" '{schema:"afk-memory-context/2",mode:$m,project:$p,
  state:"READY",reason:"MEMORY_READY",package:"@vectorize-io/hindsight-coding-agents",version:"0.6.0",
  native_integration:"NOT_MUTATED",authoritative_evidence:true}'
EOF
chmod +x "$TMP/hindsight-helper"

for harness in claude codex opencode; do
  HINDSIGHT_CONFIG="$TMP/native-config.json" HINDSIGHT_CODING_AGENTS_HOME="$TMP/runtime" \
    prepare_worker_memory required "$harness" "$TMP/home" "$PATH" tester "$ROOT" "$TMP/state/$harness" "$TMP/hindsight-helper" \
    >/dev/null 2>&1 && ok "required proves native $harness readiness" || no "required proves native $harness readiness"
done

# Wiring is exact structured data. A command that merely contains an expected
# Hindsight path, or a plugin path that exists only inside a JSONC comment,
# cannot qualify native memory access.
substring_home="$TMP/substring-home"; mkdir -p "$substring_home/.claude" "$substring_home/.codex"
printf '{"hooks":{"SessionStart":[{"command":"prefix-%s/dist/claude-sessionstart-hook.js"}],"UserPromptSubmit":[{"command":"prefix-%s/dist/claude-hook.js"}],"Stop":[{"command":"prefix-%s/dist/claude-stop-hook.js"}]}}\n' \
  "$TMP/runtime" "$TMP/runtime" "$TMP/runtime" >"$substring_home/.claude/settings.json"
printf '{"hooks":{"SessionStart":[{"command":"prefix-%s/dist/codex-sessionstart-hook.js"}],"UserPromptSubmit":[{"command":"prefix-%s/dist/codex-hook.js"}],"Stop":[{"command":"prefix-%s/dist/codex-stop-hook.js"}]}}\n' \
  "$TMP/runtime" "$TMP/runtime" "$TMP/runtime" >"$substring_home/.codex/hooks.json"
for harness in claude codex; do
  if HINDSIGHT_CONFIG="$TMP/native-config.json" HINDSIGHT_CODING_AGENTS_HOME="$TMP/runtime" \
    prepare_worker_memory required "$harness" "$substring_home" "$PATH" tester "$ROOT" "$TMP/state/substring-$harness" "$TMP/hindsight-helper" >/dev/null 2>&1; then
    no "required refuses substring-only $harness wiring"
  else ok "required refuses substring-only $harness wiring"; fi
done
comment_home="$TMP/comment-home"; mkdir -p "$comment_home/.config/opencode"
printf '{\n  // "plugin": ["%s"],\n  "plugin": []\n}\n' "$TMP/runtime" >"$comment_home/.config/opencode/opencode.jsonc"
if HINDSIGHT_CONFIG="$TMP/native-config.json" HINDSIGHT_CODING_AGENTS_HOME="$TMP/runtime" \
  prepare_worker_memory required opencode "$comment_home" "$PATH" tester "$ROOT" "$TMP/state/commented-plugin" "$TMP/hindsight-helper" >/dev/null 2>&1; then
  no "required refuses a commented-out OpenCode plugin"
else ok "required refuses a commented-out OpenCode plugin"; fi

# A READY label is accepted only from the exact requested mode/repository and
# audited package version; a helper cannot replay another qualification.
for mismatch in mode project version; do
  bad_helper="$TMP/hindsight-helper-$mismatch"
  case "$mismatch" in
    mode) printf '%s\n' '#!/usr/bin/env bash' 'jq -nc --arg p "$2" '\''{schema:"afk-memory-context/2",mode:"advisory",project:$p,state:"READY",reason:"MEMORY_READY",package:"@vectorize-io/hindsight-coding-agents",version:"0.6.0",native_integration:"NOT_MUTATED",authoritative_evidence:true}'\''' >"$bad_helper" ;;
    project) printf '%s\n' '#!/usr/bin/env bash' 'jq -nc --arg m "$1" '\''{schema:"afk-memory-context/2",mode:$m,project:"other-repo",state:"READY",reason:"MEMORY_READY",package:"@vectorize-io/hindsight-coding-agents",version:"0.6.0",native_integration:"NOT_MUTATED",authoritative_evidence:true}'\''' >"$bad_helper" ;;
    version) printf '%s\n' '#!/usr/bin/env bash' 'jq -nc --arg m "$1" --arg p "$2" '\''{schema:"afk-memory-context/2",mode:$m,project:$p,state:"READY",reason:"MEMORY_READY",package:"@vectorize-io/hindsight-coding-agents",version:"0.5.0",native_integration:"NOT_MUTATED",authoritative_evidence:true}'\''' >"$bad_helper" ;;
  esac
  chmod +x "$bad_helper"
  if HINDSIGHT_CONFIG="$TMP/native-config.json" HINDSIGHT_CODING_AGENTS_HOME="$TMP/runtime" \
    prepare_worker_memory required claude "$TMP/home" "$PATH" tester "$ROOT" "$TMP/state/helper-$mismatch" "$bad_helper" >/dev/null 2>&1; then
    no "required refuses READY evidence with mismatched $mismatch"
  else ok "required refuses READY evidence with mismatched $mismatch"; fi
done
if HINDSIGHT_CONFIG="$TMP/native-config.json" HINDSIGHT_CODING_AGENTS_HOME="$TMP/missing" \
  prepare_worker_memory required claude "$TMP/home" "$PATH" tester "$ROOT" "$TMP/state/missing" "$TMP/hindsight-helper" >/dev/null 2>&1; then
  no "required refuses missing native wiring"
else ok "required refuses missing native wiring"; fi
if HINDSIGHT_CONFIG="$TMP/native-config.json" HINDSIGHT_CODING_AGENTS_HOME="$TMP/missing" \
  prepare_worker_memory advisory claude "$TMP/home" "$PATH" tester "$ROOT" "$TMP/state/advisory" "$TMP/hindsight-helper" >/dev/null 2>&1; then
  ok "advisory continues on explicit outage"
else no "advisory continues on explicit outage"; fi

for mode in blind off; do
  for harness in claude codex opencode hermes; do
    HINDSIGHT_API_TOKEN=do-not-copy HINDSIGHT_CONFIG="$TMP/secret-native.json" \
      prepare_worker_memory "$mode" "$harness" "$TMP/home" "$PATH" tester "$ROOT" "$TMP/state/$mode-$harness" "$TMP/hindsight-helper" >/dev/null 2>&1
    if [[ "$MEMORY_HINDSIGHT_DISABLED" == true ]] \
      && jq -e 'keys==["bankId","disabled"] and .disabled==true and (has("apiToken")|not)' "$MEMORY_HINDSIGHT_CONFIG" >/dev/null; then
      ok "$mode isolates token-free Hindsight config for $harness"
    else no "$mode isolates token-free Hindsight config for $harness"; fi
  done
done

HINDSIGHT_CONFIG="$TMP/native-config.json" HINDSIGHT_CODING_AGENTS_HOME="$TMP/runtime" \
  prepare_worker_memory required opencode "$TMP/home" "$PATH" tester "$ROOT" "$TMP/state/opencode-config" "$TMP/hindsight-helper" >/dev/null 2>&1
write_opencode_config "$TMP/opencode-enabled.json" "$ROOT/_bmad/bmm/agents/dev.md" "$MEMORY_OPENCODE_PLUGIN"
check "OpenCode pure config includes installed Hindsight exactly once" \
  jq -e --arg p "$TMP/runtime" '.plugin==[$p]' "$TMP/opencode-enabled.json"
check "OpenCode generated model declares required output capacity" \
  jq -e '.provider["minimax-cn"].models["MiniMax-M3"].limit=={context:1000000,output:65536}' "$TMP/opencode-enabled.json"
enabled_launch="$(build_opencode_command /bin/opencode /home /bin tester cfg data cache state prompt model variant result agent)"
if [[ "$enabled_launch" != *' run --pure '* ]]; then ok "required OpenCode memory keeps the audited plugin enabled"; else no "required OpenCode memory keeps the audited plugin enabled"; fi
prepare_worker_memory off opencode "$TMP/home" "$PATH" tester "$ROOT" "$TMP/state/opencode-off" "$TMP/hindsight-helper" >/dev/null 2>&1
write_opencode_config "$TMP/opencode-off.json" "$ROOT/_bmad/bmm/agents/dev.md" "$MEMORY_OPENCODE_PLUGIN"
check "OpenCode pure config excludes plugins when memory is off" jq -e '.plugin==[]' "$TMP/opencode-off.json"
disabled_launch="$(build_opencode_command /bin/opencode /home /bin tester cfg data cache state prompt model variant result agent)"
contains "$disabled_launch" ' run --pure ' && ok "memory-off OpenCode launch remains pure" || no "memory-off OpenCode launch remains pure"

printf '%s\n' \
  '{"type":"step_start","part":{"type":"step-start"}}' \
  '{"type":"tool_use","part":{"type":"tool","input":"NEEDS-HUMAN: forged"}}' \
  '{"type":"text","part":{"type":"text","text":"authoritative assistant output"}}' \
  '{"type":"step_finish","part":{"type":"step-finish","reason":"stop"}}' >"$TMP/opencode-success.jsonl"
parsed_open="$(parse_opencode_result_stream "$TMP/opencode-success.jsonl")"
if [[ "$(jq -r .text <<<"$parsed_open")" == 'authoritative assistant output' ]]; then
  ok "OpenCode parser selects assistant text only"
else no "OpenCode parser selects assistant text only"; fi
printf '%s\n' '{"type":"error","error":{"name":"ProviderError"}}' >"$TMP/opencode-error.jsonl"
if parse_opencode_result_stream "$TMP/opencode-error.jsonl" >/dev/null; then
  no "OpenCode parser refuses a native error envelope"
else ok "OpenCode parser refuses a native error envelope"; fi

for invalid_policy in reversed above-one; do
  policy="$TMP/policy-$invalid_policy.yaml"
  if [[ "$invalid_policy" == reversed ]]; then
    risk=0.60; checkpoint=0.55; continuation=0.85
  else
    risk=0.60; checkpoint=0.70; continuation=1.10
  fi
  printf 'estimate_method: bytes4-v1\nsizing_risk_ratio: %s\ncheckpoint_ratio: %s\ncontinuation_ratio: %s\ncontinuation_cap: 3\nbudget_states: [OK, CHECKPOINT_DUE, CONTINUATION_REQUIRED, NOT_EVALUATED]\nreason_codes: [A, B, C, D, E]\n' \
    "$risk" "$checkpoint" "$continuation" >"$policy"
  if (load_budget_policy "$policy") >/dev/null 2>&1; then
    no "dispatch refuses $invalid_policy budget thresholds"
  else ok "dispatch refuses $invalid_policy budget thresholds"; fi
done

MEMORY_MODE=blind
envs="$(worker_environment_assignments run-1 story "$TMP/story.md" 7 dispatch-7 run:run-1 pm-old "$ROOT/files/model-router/scripts/dispatch.sh" "$TMP/events")"
for key in AFK_WORKER_IDENTITY AFK_RUN_ID AFK_STORY_ID AFK_STORY_PATH AFK_CYCLE AFK_DISPATCH_ID AFK_OWNING_PM AFK_DELEGATING_PM AFK_CONTEXT_EVENT_HOOK AFK_MEMORY_MODE HINDSIGHT_CONFIG HINDSIGHT_DISABLED; do
  contains "$envs" "$key=" && ok "worker env freezes $key" || no "worker env freezes $key"
done
contains "$(build_claude_command /home /bin tester prompt model high result persona "$envs")" AFK_DISPATCH_ID= && ok "Claude launch carries worker context" || no "Claude launch carries worker context"
contains "$(build_codex_command prompt model high "$envs")" AFK_DISPATCH_ID= && ok "Codex launch carries worker context" || no "Codex launch carries worker context"
contains "$(build_opencode_command /bin/opencode /home /bin tester cfg data cache state prompt model variant result agent "$envs")" AFK_DISPATCH_ID= && ok "OpenCode launch carries worker context" || no "OpenCode launch carries worker context"

cat >"$TMP/story.md" <<'EOF'
---
memory_mode: advisory
gates: ["true"]
---
# story
EOF
export AFK_RUN_ID=run-1 AFK_STORY_ID=story AFK_STORY_PATH="$TMP/story.md" AFK_CYCLE=1
export AFK_DISPATCH_ID=dispatch-1 AFK_OWNING_PM=run:run-1 AFK_DELEGATING_PM=pm-old AFK_WORKER_IDENTITY=worker:dispatch-1
export AFK_CONTEXT_EVENT_DIR="$TMP/events" AFK_CONTEXT_EVENT_TRANSPORT=none
export AFK_WORKER_TERMINAL=worker-terminal
jq -nc '{schema:"afk-checkpoint/1",completed:["read"],current_state:"implementation",remaining_acceptance:["gate"],next_steps:["implement"],updated_at:"2099-01-01T00:00:00Z"}' >"$TMP/story.md.checkpoint.json"
if ( context_event_emit --state CHECKPOINT_DUE --phase implementation --checkpoint "$TMP/missing-checkpoint" ) >/dev/null 2>&1; then
  no "CHECKPOINT_DUE refuses without resumable artifact"
else ok "CHECKPOINT_DUE refuses without resumable artifact"; fi
checkpoint_event="$(context_event_emit --state CHECKPOINT_DUE --phase implementation --used-tokens 70 --window-tokens 100)"
check "live checkpoint event is durably bound with resumable state" jq -e '.schema=="afk-worker-context-event/1" and .state=="CHECKPOINT_DUE" and .binding.run_id=="run-1" and .binding.owning_pm=="run:run-1" and .binding.delegating_terminal=="pm-old" and .checkpoint.sha256' "$checkpoint_event"
current_pm_run() { printf '%s\n' run-1; }
AFK_PM_ID=pm-new context_event_consume "$checkpoint_event" >/dev/null
check "successor PM on same Run consumes after terminal rollover" jq -e '.consumed_by_current_pm=="pm-new" and .delegating_terminal=="pm-old" and .run_id=="run-1"' "${checkpoint_event%.json}.consumed.json"
check "CHECKPOINT_DUE consumes without continuation launch" jq -e '.action=="CHECKPOINT_ONLY" and .continuation_launched==false' "${checkpoint_event%.json}.consumed.json"
second="$(AFK_PM_ID=pm-new context_event_consume "$checkpoint_event")"
contains "$second" ALREADY_CONSUMED: && ok "checkpoint event is consumed exactly once" || no "checkpoint event is consumed exactly once"

# A live lock rejects a concurrent incarnation, but a crashed lock holder is
# released by the kernel. A stale directory left by the retired mkdir protocol
# is audit debris only and cannot strand the successor PM.
jq '.updated_at="2099-01-01T00:00:30Z"' "$TMP/story.md.checkpoint.json" >"$TMP/checkpoint-next"; mv "$TMP/checkpoint-next" "$TMP/story.md.checkpoint.json"
recovery_event="$(context_event_emit --state CHECKPOINT_DUE --phase recovery)"
recovery_lock="${recovery_event%.json}.consume.lock"; recovery_ready="$TMP/recovery-lock-ready"
flock -F "$recovery_lock" sh -c 'touch "$1"; exec sleep 10' sh "$recovery_ready" &
lock_holder=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -f "$recovery_ready" ]] && break; sleep 0.02; done
if AFK_PM_ID=pm-new context_event_consume "$recovery_event" >/dev/null 2>&1; then
  no "active PM incarnation lock excludes a concurrent consumer"
else ok "active PM incarnation lock excludes a concurrent consumer"; fi
kill "$lock_holder" 2>/dev/null || true; wait "$lock_holder" 2>/dev/null || true
mkdir "${recovery_event%.json}.claim"
AFK_PM_ID=pm-new context_event_consume "$recovery_event" >/dev/null
check "crashed lock and legacy stale claim recover via durable receipt" jq -e \
  '.consumed_by_current_pm=="pm-new" and .action=="CHECKPOINT_ONLY"' "${recovery_event%.json}.consumed.json"

printf '{"status":"continuation_required","launch":{"dispatch_id":"dispatch-1","worker_identity":"worker:dispatch-1"}}\n' >"$TMP/story.md.result.c1.json"
jq -nc '{schema:"afk-continuation/1",story_id:"story",completed:[],current_state:"handoff",remaining_acceptance:["gate"],next_steps:["resume"],updated_at:"2099-01-01T00:00:00Z",in_flight:[],unretired_findings:[]}' >"$TMP/story.md.continuation.json"
continuation_event="$(context_event_emit --state CONTINUATION_REQUIRED --phase gates)"
cross_event="$(AFK_DISPATCH_ID=dispatch-other AFK_WORKER_IDENTITY=worker:dispatch-other AFK_CONTEXT_EVENT_DIR="$TMP/cross-events" \
  context_event_emit --state CONTINUATION_REQUIRED --phase gates)"
if AFK_PM_ID=pm-new context_event_consume "$cross_event" >/dev/null 2>&1; then
  no "another worker identity cannot consume this dispatch's continuation"
else ok "another worker identity cannot consume this dispatch's continuation"; fi
cat >"$TMP/fake-dispatch" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$AFK_FAKE_DISPATCH_ARGS"
jq -nc --argjson confirmed "${AFK_FAKE_CONFIRM:-false}" '{schema:"afk-continuation-ledger/1",entries:[{cycle:2,launch_confirmed:$confirmed}]}' >"$1.continuations.json"
exit 0
EOF
chmod +x "$TMP/fake-dispatch"
AFK_DISPATCH_SCRIPT="$TMP/fake-dispatch" AFK_FAKE_DISPATCH_ARGS="$TMP/dispatch-args" AFK_PM_ID=pm-new \
  context_event_consume "$continuation_event" >/dev/null
check "continuation event invokes canonical --cycle path" grep -Fxq "$TMP/story.md --cycle 2" "$TMP/dispatch-args"
if [[ ! -e "${continuation_event%.json}.consumed.json" ]]; then
  ok "attempted continuation ledger entry is not launch evidence"
else no "attempted continuation ledger entry is not launch evidence"; fi
AFK_DISPATCH_SCRIPT="$TMP/fake-dispatch" AFK_FAKE_CONFIRM=true AFK_FAKE_DISPATCH_ARGS="$TMP/dispatch-args" AFK_PM_ID=pm-new \
  context_event_consume "$continuation_event" >/dev/null
check "continuation event records exactly-once launch receipt" jq -e '.action=="CANONICAL_NEXT_CYCLE" and .continuation_launched==true' "${continuation_event%.json}.consumed.json"

# Terminal creation is the confirmation boundary: a failed create cannot spend
# a continuation or strand the cycle, while the retry records the exact handle.
failed_story="$TMP/failed-launch-story.md"; printf '%s\n' '# failed launch story' >"$failed_story"
# shellcheck disable=SC2317 # test mock: shadows the orca_json helper the
# sourced library calls internally; never invoked by literal name here.
orca_json() {
  if [[ "$1 $2" == "terminal list" ]]; then jq -nc '{result:{terminals:[]}}'; return; fi
  return 1
}
if ( continuation_launch_create "$failed_story" 2 1 sha256:test WORKER_SIGNAL null selector title command EXIT 1 "$TMP" ) >/dev/null 2>&1; then
  no "failed terminal create refuses continuation launch"
else ok "failed terminal create refuses continuation launch"; fi
if [[ ! -e "$failed_story.continuations.json" ]] && [[ -f "$(continuation_launch_attempt_path "$failed_story" 2)" ]]; then
  ok "failed terminal create leaves no ledger evidence"
else no "failed terminal create leaves no ledger evidence"; fi

legacy_entries='[{"cycle":2},{"cycle":3,"launch_confirmed":false},{"cycle":4,"launch_confirmed":true}]'
if [[ "$(continuations_consumed "$legacy_entries")" == 1 ]] && ! ledger_has_cycle "$legacy_entries" 2 \
  && ! ledger_has_cycle "$legacy_entries" 3 && ledger_has_cycle "$legacy_entries" 4; then
  ok "cap and retained-cycle predicates count only confirmed launches"
else no "cap and retained-cycle predicates count only confirmed launches"; fi

terminal_state="$TMP/continuation-terminals.json"; printf '[]\n' >"$terminal_state"
create_count="$TMP/continuation-create-count"; printf '0\n' >"$create_count"
next_handle=confirmed-terminal; hide_terminal_list=false; terminal_list_json=""
terminal_show_conflict=false; terminal_show_timeout_when_absent=false
terminal_create_crash_after_effect=false
terminal_revive_on_second_show=false; terminal_show_count="$TMP/continuation-show-count"; printf '0\n' >"$terminal_show_count"
# shellcheck disable=SC2317 # test mock: shadows the orca_json helper the
# sourced library calls internally; never invoked by literal name here.
orca_json() {
  local op="$1 $2" handle="" title="" selector="" n
  shift 2
  case "$op" in
    "terminal list")
      if [[ -n "$terminal_list_json" ]]; then printf '%s\n' "$terminal_list_json"
      elif [[ "$hide_terminal_list" == true ]]; then jq -nc '{result:{terminals:[]}}'
      else jq -nc --slurpfile ts "$terminal_state" '{result:{terminals:$ts[0]}}'; fi ;;
    "terminal show")
      while (($#)); do case "$1" in --terminal) handle="$2"; shift 2;; *) shift;; esac; done
      n="$(<"$terminal_show_count")"; printf '%s\n' "$((n + 1))" >"$terminal_show_count"
      if [[ "$terminal_revive_on_second_show" == true && "$n" == 1 ]]; then
        jq --arg h "$handle" 'map(if .handle==$h then .connected=true|.status="running" else . end)' \
          "$terminal_state" >"$terminal_state.tmp"; mv "$terminal_state.tmp" "$terminal_state"
      fi
      if jq -e --arg h "$handle" 'any(.[]; .handle==$h)' "$terminal_state" >/dev/null; then
        if [[ "$terminal_show_conflict" == ok_false ]]; then
          jq -ec --arg h "$handle" '[.[]|select(.handle==$h)]|{ok:false,result:{terminal:.[0]}}' "$terminal_state"
        elif [[ "$terminal_show_conflict" == error ]]; then
          jq -ec --arg h "$handle" '[.[]|select(.handle==$h)]|{ok:true,error:{code:"terminal_show_failed"},result:{terminal:.[0]}}' "$terminal_state"
        else jq -ec --arg h "$handle" '[.[]|select(.handle==$h)]|{result:{terminal:.[0]}}' "$terminal_state"; fi
      elif [[ "$terminal_show_timeout_when_absent" == true ]]; then return 124
      else jq -nc --arg h "$handle" '{ok:false,error:{code:"terminal_handle_stale",message:("released terminal handle: "+$h)}}'; return 1; fi ;;
    "terminal create")
      while (($#)); do case "$1" in --worktree) selector="${2#id:}"; shift 2;; --title) title="$2"; shift 2;; *) shift;; esac; done
      n="$(<"$create_count")"; printf '%s\n' "$((n + 1))" >"$create_count"
      jq --arg h "$next_handle" --arg title "$title" --arg wi "$selector" --arg wp "$TMP" \
        '.+[{handle:$h,title:$title,connected:true,orphaned:false,worktreeId:$wi,worktreePath:$wp}]' \
        "$terminal_state" >"$terminal_state.tmp"; mv "$terminal_state.tmp" "$terminal_state"
      [[ "$terminal_create_crash_after_effect" != true ]] || return 97
      jq -nc --arg h "$next_handle" '{result:{terminal:{handle:$h}}}' ;;
    "terminal close")
      while (($#)); do case "$1" in --terminal) handle="$2"; shift 2;; *) shift;; esac; done
      jq --arg h "$handle" '[.[]|select(.handle!=$h)]' "$terminal_state" >"$terminal_state.tmp"; mv "$terminal_state.tmp" "$terminal_state"
      jq -nc '{ok:true}' ;;
    *) return 1 ;;
  esac
}
if continuation_launch_create "$failed_story" 2 1 sha256:test WORKER_SIGNAL null selector title command EXIT 1 "$TMP" >/dev/null 2>&1; then
  no "ambiguous failed create replay refuses an empty scoped list"
else ok "ambiguous failed create replay refuses an empty scoped list"; fi
if [[ "$(<"$create_count")" == 0 ]]; then
  ok "ambiguous failed create replay cannot duplicate a possibly-created terminal"
else no "ambiguous failed create replay cannot duplicate a possibly-created terminal"; fi

launch_story="$TMP/launch-story.md"; printf '%s\n' '# launch story' >"$launch_story"
continuation_launch_create "$launch_story" 2 1 sha256:test WORKER_SIGNAL null selector title command EXIT 1 "$TMP"
check "retry records exact confirmed launch evidence" jq -e \
  '.entries|length==1 and .[0].cycle==2 and .[0].launch_confirmed==true and
   .[0].terminal=="confirmed-terminal" and (.[0].command_sha256|startswith("sha256:")) and
   (.[0].create_id|startswith("sha256:"))' \
  "$launch_story.continuations.json"
receipt_file="$(continuation_launch_receipt_path "$launch_story" 2)"
jq 'del(.terminal,.generation)|.schema="afk-continuation-launch-intent/1"' "$receipt_file" >"$(continuation_launch_intent_path "$launch_story" 2)"
rm -f -- "$launch_story.continuations.json"
before_creates="$(<"$create_count")"
worker_bad_lists=(
  '{}'
  '{"ok":false,"error":{"code":"terminal_list_failed"},"result":{"terminals":[]}}'
  '{"result":{"terminals":{}}}'
  '{"result":{"terminals":[{}]}}'
  '{"result":{"terminals":[{"handle":"bad"}]}}'
  '{"result":{"terminals":[{"handle":"bad","title":null}]}}'
  '{"result":{"terminals":[{"handle":"bad","title":7}]}}'
)
for terminal_list_json in "${worker_bad_lists[@]}"; do
  if continuation_launch_create "$launch_story" 2 1 sha256:test WORKER_SIGNAL null selector title command EXIT 1 "$TMP" >/dev/null 2>&1; then
    no "continuation reconciliation refuses malformed terminal list"
  else ok "continuation reconciliation refuses malformed terminal list"; fi
done
terminal_list_json=""
if [[ "$(<"$create_count")" == "$before_creates" && ! -e "$launch_story.continuations.json" ]]; then
  ok "malformed continuation lists create no terminal or ledger evidence"
else no "malformed continuation lists create no terminal or ledger evidence"; fi
for terminal_show_conflict in ok_false error; do
  if continuation_launch_create "$launch_story" 2 1 sha256:test WORKER_SIGNAL null selector title command EXIT 1 "$TMP" >/dev/null 2>&1; then
    no "continuation observation rejects a conflicting terminal-show envelope"
  else ok "continuation observation rejects a conflicting terminal-show envelope"; fi
done
terminal_show_conflict=false
if [[ "$(<"$create_count")" == "$before_creates" && ! -e "$launch_story.continuations.json" ]]; then
  ok "conflicting continuation show creates no terminal or ledger evidence"
else no "conflicting continuation show creates no terminal or ledger evidence"; fi
hide_terminal_list=true
continuation_launch_create "$launch_story" 2 1 sha256:test WORKER_SIGNAL null selector title command EXIT 1 "$TMP"
hide_terminal_list=false
if [[ "$(<"$create_count")" == "$before_creates" ]] && jq -e '.entries[0].terminal=="confirmed-terminal"' "$launch_story.continuations.json" >/dev/null; then
  ok "receipt-backed live rediscovery survives a lagging scoped list without duplicate create"
else no "receipt-backed live rediscovery survives a lagging scoped list without duplicate create"; fi

title_only_story="$TMP/title-only-story.md"; printf '%s\n' '# title only story' >"$title_only_story"
jq 'del(.terminal,.generation)|.schema="afk-continuation-launch-intent/1"' "$receipt_file" >"$(continuation_launch_intent_path "$title_only_story" 2)"
hide_terminal_list=true
if continuation_launch_create "$title_only_story" 2 1 sha256:test WORKER_SIGNAL null selector title command EXIT 1 "$TMP" >/dev/null 2>&1; then
  no "pre-existing continuation intent refuses a lagging empty list"
else ok "pre-existing continuation intent refuses a lagging empty list"; fi
hide_terminal_list=false
if [[ "$(<"$create_count")" == "$before_creates" && ! -e "$title_only_story.continuations.json" ]]; then
  ok "lagging empty list cannot trigger a duplicate continuation create"
else no "lagging empty list cannot trigger a duplicate continuation create"; fi
if continuation_launch_create "$title_only_story" 2 1 sha256:test WORKER_SIGNAL null selector title command EXIT 1 "$TMP" >/dev/null 2>&1; then
  no "live title-only continuation is never adopted"
else ok "live title-only continuation is never adopted"; fi
if [[ "$(<"$create_count")" == "$before_creates" && ! -e "$title_only_story.continuations.json" ]]; then
  ok "live title-only refusal creates no duplicate or confirmation"
else no "live title-only refusal creates no duplicate or confirmation"; fi

jq 'map(if .handle=="confirmed-terminal" then .connected=false else . end)' "$terminal_state" >"$terminal_state.tmp"; mv "$terminal_state.tmp" "$terminal_state"
jq 'del(.terminal,.generation)|.schema="afk-continuation-launch-intent/1"' "$receipt_file" >"$(continuation_launch_intent_path "$launch_story" 2)"
rm -f -- "$launch_story.continuations.json"
next_handle=replacement-terminal
printf '0\n' >"$terminal_show_count"; terminal_revive_on_second_show=true
if continuation_launch_create "$launch_story" 2 1 sha256:test WORKER_SIGNAL null selector title command EXIT 1 "$TMP" >/dev/null 2>&1; then
  no "continuation replacement refuses a dead-to-live race"
else ok "continuation replacement refuses a dead-to-live race"; fi
terminal_revive_on_second_show=false
if jq -e '.[]|select(.handle=="confirmed-terminal" and .connected==true)' "$terminal_state" >/dev/null \
  && [[ ! -e "$(continuation_replacement_binding_path "$launch_story" 2)" ]] \
  && [[ "$(<"$create_count")" == "$before_creates" ]]; then
  ok "dead-to-live race closes nothing and persists no close authority"
else no "dead-to-live race closes nothing and persists no close authority"; fi
jq 'map(if .handle=="confirmed-terminal" then .connected=false|.status="exited" else . end)' \
  "$terminal_state" >"$terminal_state.tmp"; mv "$terminal_state.tmp" "$terminal_state"
printf '0\n' >"$terminal_show_count"
terminal_show_timeout_when_absent=true
if continuation_launch_create "$launch_story" 2 1 sha256:test WORKER_SIGNAL null selector title command EXIT 1 "$TMP" >/dev/null 2>&1; then
  no "continuation replacement rejects a post-close show timeout"
else ok "continuation replacement rejects a post-close show timeout"; fi
terminal_show_timeout_when_absent=false
if [[ "$(<"$create_count")" == "$before_creates" && ! -e "$launch_story.continuations.json" ]]; then
  ok "timed-out continuation close cannot create a replacement"
else no "timed-out continuation close cannot create a replacement"; fi
if [[ -f "$(continuation_replacement_binding_path "$launch_story" 2)" \
  && ! -e "$(continuation_replacement_receipt_path "$launch_story" 2)" \
  && -f "$receipt_file" ]] && jq -e 'length==0' "$terminal_state" >/dev/null; then
  ok "replacement close journal preserves crash-retry authority and old launch evidence"
else no "replacement close journal preserves crash-retry authority and old launch evidence"; fi
continuation_launch_create "$launch_story" 2 1 sha256:test WORKER_SIGNAL null selector title command EXIT 1 "$TMP"
if jq -e '.entries[0].terminal=="replacement-terminal" and .entries[0].launch_confirmed==true' "$launch_story.continuations.json" >/dev/null \
  && jq -e '.terminal=="replacement-terminal" and .generation==1' "$receipt_file" >/dev/null \
  && [[ "$(<"$create_count")" == "$((before_creates + 1))" ]] \
  && [[ ! -e "$(continuation_replacement_binding_path "$launch_story" 2)" \
    && ! -e "$(continuation_replacement_receipt_path "$launch_story" 2)" \
    && ! -e "$(continuation_replacement_attempt_path "$launch_story" 2)" \
    && ! -e "$(continuation_replacement_consumed_path "$launch_story" 2)" ]]; then
  ok "timed-out close replay creates one verified replacement without restoring the old terminal"
else no "timed-out close replay creates one verified replacement without restoring the old terminal"; fi
if continuation_launch_create "$launch_story" 2 1 sha256:test WORKER_SIGNAL null selector title command EXIT 1 "$TMP" >/dev/null 2>&1; then
  no "settled replacement cycle refuses duplicate replay"
else ok "settled replacement cycle refuses duplicate replay"; fi
if [[ "$(<"$create_count")" == "$((before_creates + 1))" ]]; then
  ok "replacement recovery spends exactly one terminal create"
else no "replacement recovery spends exactly one terminal create"; fi

# Simulate a process dying after the generation-1 receipt is durable but before
# the continuation ledger append. Reconciliation must append the ledger from
# that exact receipt without spending another terminal create.
rm -f -- "$launch_story.continuations.json"
jq 'del(.terminal,.generation)|.schema="afk-continuation-launch-intent/1"' \
  "$receipt_file" >"$(continuation_launch_intent_path "$launch_story" 2)"
before_preledger_creates="$(<"$create_count")"
continuation_launch_create "$launch_story" 2 1 sha256:test WORKER_SIGNAL null selector title command EXIT 1 "$TMP"
if jq -e '.entries[0].terminal=="replacement-terminal" and .entries[0].launch_confirmed==true' \
  "$launch_story.continuations.json" >/dev/null && [[ "$(<"$create_count")" == "$before_preledger_creates" ]]; then
  ok "durable worker replacement receipt replays before ledger append"
else no "durable worker replacement receipt replays before ledger append"; fi

# Marker-first cleanup is itself crash-replayable. Seed the exact state after a
# consumed marker was written and the create attempt was removed, but before
# the close journal and marker were deleted.
rm -f -- "$launch_story.continuations.json"
worker_intent_file="$(continuation_launch_intent_path "$launch_story" 2)"
jq 'del(.terminal,.generation)|.schema="afk-continuation-launch-intent/1"' "$receipt_file" >"$worker_intent_file"
worker_intent="$(jq -c . "$worker_intent_file")"
worker_binding="$(continuation_replacement_binding_json "$worker_intent" confirmed-terminal 0)"
worker_close_receipt="$(jq -c '.schema="afk-continuation-replacement-receipt/1" |
  .+{closed:true,reobserved_absent:true}' <<<"$worker_binding")"
worker_consumed="$(jq -nc --argjson binding "$worker_binding" \
  '{schema:"afk-continuation-replacement-consumed/1",binding:$binding,
    successor_terminal:"replacement-terminal",generation:1}')"
continuation_atomic_write_verified "$(continuation_replacement_binding_path "$launch_story" 2)" "$worker_binding"
continuation_atomic_write_verified "$(continuation_replacement_receipt_path "$launch_story" 2)" "$worker_close_receipt"
continuation_atomic_write_verified "$(continuation_replacement_consumed_path "$launch_story" 2)" "$worker_consumed"
rm -f -- "$(continuation_replacement_attempt_path "$launch_story" 2)"
before_partial_cleanup_creates="$(<"$create_count")"
continuation_launch_create "$launch_story" 2 1 sha256:test WORKER_SIGNAL null selector title command EXIT 1 "$TMP"
if [[ "$(<"$create_count")" == "$before_partial_cleanup_creates" \
  && ! -e "$(continuation_replacement_binding_path "$launch_story" 2)" \
  && ! -e "$(continuation_replacement_receipt_path "$launch_story" 2)" \
  && ! -e "$(continuation_replacement_consumed_path "$launch_story" 2)" ]] \
  && jq -e '.entries[0].terminal=="replacement-terminal"' "$launch_story.continuations.json" >/dev/null; then
  ok "partial worker replacement cleanup replays from its consumed marker"
else no "partial worker replacement cleanup replays from its consumed marker"; fi

# The completed generation-1 journal no longer poisons a later death. With the
# outer ledger not yet durable, the dead replacement advances independently to
# generation 2 and spends exactly one new create.
rm -f -- "$launch_story.continuations.json"
jq 'del(.terminal,.generation)|.schema="afk-continuation-launch-intent/1"' \
  "$receipt_file" >"$(continuation_launch_intent_path "$launch_story" 2)"
jq 'map(if .handle=="replacement-terminal" then .connected=false|.status="exited" else . end)' \
  "$terminal_state" >"$terminal_state.tmp"; mv "$terminal_state.tmp" "$terminal_state"
next_handle="second-replacement-terminal"
before_second_replacement_creates="$(<"$create_count")"
continuation_launch_create "$launch_story" 2 1 sha256:test WORKER_SIGNAL null selector title command EXIT 1 "$TMP"
if jq -e '.terminal=="second-replacement-terminal" and .generation==2' "$receipt_file" >/dev/null \
  && jq -e '.entries[0].terminal=="second-replacement-terminal" and .entries[0].launch_confirmed==true' \
    "$launch_story.continuations.json" >/dev/null \
  && [[ "$(<"$create_count")" == "$((before_second_replacement_creates + 1))" \
    && ! -e "$(continuation_replacement_binding_path "$launch_story" 2)" \
    && ! -e "$(continuation_replacement_receipt_path "$launch_story" 2)" \
    && ! -e "$(continuation_replacement_attempt_path "$launch_story" 2)" \
    && ! -e "$(continuation_replacement_consumed_path "$launch_story" 2)" ]]; then
  ok "second worker death receives one independent generation-2 replacement"
else no "second worker death receives one independent generation-2 replacement"; fi

# Orca may create the replacement and then fail before returning its handle.
# The persisted generation attempt makes both a visible title and a lagging
# empty list ambiguous, so neither replay may create again.
crash_story="$TMP/crash-before-worker-receipt.md"; printf '%s\n' '# crash worker story' >"$crash_story"
printf '[]\n' >"$terminal_state"
next_handle=crash-source-terminal
continuation_launch_create "$crash_story" 2 1 sha256:crash WORKER_SIGNAL null selector crash-title command EXIT 1 "$TMP"
crash_receipt="$(continuation_launch_receipt_path "$crash_story" 2)"
rm -f -- "$crash_story.continuations.json"
jq 'del(.terminal,.generation)|.schema="afk-continuation-launch-intent/1"' \
  "$crash_receipt" >"$(continuation_launch_intent_path "$crash_story" 2)"
jq 'map(if .handle=="crash-source-terminal" then .connected=false|.status="exited" else . end)' \
  "$terminal_state" >"$terminal_state.tmp"; mv "$terminal_state.tmp" "$terminal_state"
next_handle="unacknowledged-worker-terminal"; terminal_create_crash_after_effect=true
before_worker_crash_creates="$(<"$create_count")"
if continuation_launch_create "$crash_story" 2 1 sha256:crash WORKER_SIGNAL null selector crash-title command EXIT 1 "$TMP" >/dev/null 2>&1; then
  no "worker replacement create crashes before receipt"
else ok "worker replacement create crashes before receipt"; fi
terminal_create_crash_after_effect=false
if [[ "$(<"$create_count")" == "$((before_worker_crash_creates + 1))" \
  && -f "$(continuation_replacement_attempt_path "$crash_story" 2)" \
  && ! -e "$crash_receipt" ]]; then
  ok "worker crash-before-receipt retains its generation attempt"
else no "worker crash-before-receipt retains its generation attempt"; fi
before_worker_ambiguous_replays="$(<"$create_count")"
if continuation_launch_create "$crash_story" 2 1 sha256:crash WORKER_SIGNAL null selector crash-title command EXIT 1 "$TMP" >/dev/null 2>&1; then
  no "visible unacknowledged worker replacement remains blocked"
else ok "visible unacknowledged worker replacement remains blocked"; fi
if [[ "$(<"$create_count")" == "$before_worker_ambiguous_replays" ]]; then
  ok "visible worker crash evidence cannot duplicate create"
else no "visible worker crash evidence cannot duplicate create"; fi
hide_terminal_list=true
if continuation_launch_create "$crash_story" 2 1 sha256:crash WORKER_SIGNAL null selector crash-title command EXIT 1 "$TMP" >/dev/null 2>&1; then
  no "lagging unacknowledged worker replacement remains blocked"
else ok "lagging unacknowledged worker replacement remains blocked"; fi
hide_terminal_list=false
if [[ "$(<"$create_count")" == "$before_worker_ambiguous_replays" ]]; then
  ok "lagging worker crash evidence cannot duplicate create"
else no "lagging worker crash evidence cannot duplicate create"; fi

# Stock macOS has no flock. The atomic-directory fallback excludes a second
# process and never runs a launch-critical section without a real lock.
lock_story="$TMP/lock-story.md"; printf '%s\n' '# lock story' >"$lock_story"
no_flock_bin="$TMP/no-flock-bin"; mkdir "$no_flock_bin"
ln -s "$(command -v mkdir)" "$no_flock_bin/mkdir"; ln -s "$(command -v rmdir)" "$no_flock_bin/rmdir"
lock_hold() { printf '%s\n' entered >"$TMP/lock-entered"; /bin/sleep 0.3; }
lock_second() { printf '%s\n' unsafe >"$TMP/lock-second"; }
PATH="$no_flock_bin" with_story_lock "$lock_story" lock_hold & lock_pid=$!
for _ in {1..50}; do [[ -f "$TMP/lock-entered" ]] && break; /bin/sleep 0.01; done
if PATH="$no_flock_bin" with_story_lock "$lock_story" lock_second >/dev/null 2>&1; then
  no "mkdir fallback excludes a concurrent critical section"
else ok "mkdir fallback excludes a concurrent critical section"; fi
wait "$lock_pid"
if [[ ! -e "$TMP/lock-second" && ! -e "$lock_story.afk-story.lock" ]]; then
  ok "mkdir fallback releases only its own acquired lock"
else no "mkdir fallback releases only its own acquired lock"; fi

cat >"$TMP/fake-orca" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$AFK_FAKE_ORCA_ARGS"
EOF
chmod +x "$TMP/fake-orca"
export AFK_CONTEXT_EVENT_TRANSPORT=orca
jq '.updated_at="2099-01-01T00:01:00Z"' "$TMP/story.md.checkpoint.json" >"$TMP/checkpoint-next"; mv "$TMP/checkpoint-next" "$TMP/story.md.checkpoint.json"
AFK_ORCA_BIN="$TMP/fake-orca" AFK_FAKE_ORCA_ARGS="$TMP/orca-send-args" context_event_emit --state CHECKPOINT_DUE --phase report >/dev/null
send_args="$(<"$TMP/orca-send-args")"
contains "$send_args" "orchestration send --run run-1" && contains "$send_args" "--from worker-terminal" \
  && ! contains "$send_args" "--to" && ok "pressure publishes from worker terminal to owning Run mailbox" \
  || no "pressure publishes from worker terminal to owning Run mailbox"
cat >"$TMP/stalled-orca" <<'EOF'
#!/usr/bin/env bash
sleep 10
EOF
chmod +x "$TMP/stalled-orca"
jq '.updated_at="2099-01-01T00:02:00Z"' "$TMP/story.md.checkpoint.json" >"$TMP/checkpoint-next"; mv "$TMP/checkpoint-next" "$TMP/story.md.checkpoint.json"
SECONDS=0
stalled_event="$(AFK_ORCA_BIN="$TMP/stalled-orca" AFK_CONTEXT_ORCA_TIMEOUT_SECONDS=1 context_event_emit --state CHECKPOINT_DUE --phase final)"
if [[ -f "$stalled_event" && $SECONDS -lt 4 ]]; then ok "stalled Orca transport is bounded after durable event write"; else no "stalled Orca transport is bounded after durable event write"; fi

printf '1..%d\n' "$((pass + fail))"
printf '# pass=%d fail=%d\n' "$pass" "$fail"
(( fail == 0 ))
