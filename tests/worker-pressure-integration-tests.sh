#!/usr/bin/env bash
# The compact assertion idiom is safe here because both ok/no always return 0.
# shellcheck disable=SC2015
set -uo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
if ! command -v jq >/dev/null || ! command -v yq >/dev/null || ! command -v node >/dev/null; then
  printf 'worker-pressure-integration-tests: jq, yq, and node are required\n' >&2
  exit 2
fi
TMP="$(mktemp -d)"; trap 'rm -rf -- "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$((PASS + FAIL))" "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'not ok %d - %s\n' "$((PASS + FAIL))" "$1"; }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (got=$2 expected=$3)"; fi; }
contains() { grep -Fq -- "$2" <<<"$1"; }
event_count() { find "$1" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
wait_events() { local dir="$1" count="$2"; for _ in {1..50}; do [[ "$(event_count "$dir")" -ge "$count" ]] && return 0; sleep 0.02; done; return 1; }
event_for() { jq -r --arg s "$2" 'select(.state==$s)|input_filename' "$1"/*.json 2>/dev/null | head -1; }

RUNTIME="$TMP/skills/afk-runtime"; mkdir -p "$RUNTIME/bin"
cp -R "$ROOT/adapters/." "$RUNTIME/"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''{"state":"CURRENT","last_good_verified":true}\n'\''' >"$RUNTIME/bin/afk-session-start"
chmod +x "$RUNTIME/bin/afk-session-start"

# Dispatch freezes the already-validated policy values, rather than making a
# harness adapter read policy or invent a threshold.
ENV_TEXT="$(bash -c '. "$1"; MEMORY_MODE=blind; MEMORY_HINDSIGHT_CONFIG=/tmp/h; MEMORY_HINDSIGHT_DISABLED=true; worker_environment_assignments r s /tmp/s 1 d run:r pm "$1" /tmp/e 712345 867890' _ "$ROOT/files/model-router/scripts/dispatch.sh")"
contains "$ENV_TEXT" 'AFK_CONTEXT_CHECKPOINT_PPM=712345' && ok 'dispatch freezes validated checkpoint threshold' || no 'dispatch freezes validated checkpoint threshold'
contains "$ENV_TEXT" 'AFK_CONTEXT_CONTINUATION_PPM=867890' && ok 'dispatch freezes validated continuation threshold' || no 'dispatch freezes validated continuation threshold'

INPUT="$TMP/claude-input.json"
jq -nc '{session_id:"worker-session",context_window:{used_percentage:70,context_window_size:100000}}' >"$INPUT"
env -u AFK_WORKER_IDENTITY -u AFK_RUN_ID -u AFK_STORY_ID -u AFK_STORY_PATH -u AFK_CYCLE \
  -u AFK_DISPATCH_ID -u AFK_OWNING_PM -u AFK_DELEGATING_PM -u AFK_CONTEXT_EVENT_HOOK \
  -u AFK_PM_DIR AFK_CONTEXT_EVENT_DIR="$TMP/no-route-events" \
  "$RUNTIME/worker-context.sh" observe --harness claude --input "$INPUT"
[[ ! -e "$TMP/no-route-events" ]] && ok 'non-routed session is a no-op' || no 'non-routed session is a no-op'

STORY="$TMP/story.md"; EVENTS="$TMP/events"
printf '# test story\n' >"$STORY"
write_checkpoint() {
  jq -nc '{schema:"afk-checkpoint/1",completed:["read"],current_state:"implementation",remaining_acceptance:["gate"],next_steps:["continue"],updated_at:"2099-01-01T00:00:00Z"}' >"$1.checkpoint.json"
}
write_checkpoint "$STORY"
export AFK_WORKER_IDENTITY=worker:dispatch-1 AFK_RUN_ID=run-1 AFK_STORY_ID=story AFK_STORY_PATH="$STORY"
export AFK_CYCLE=1 AFK_DISPATCH_ID=dispatch-1 AFK_OWNING_PM=run:run-1 AFK_DELEGATING_PM=pm-owner
export AFK_CONTEXT_EVENT_HOOK="$ROOT/files/model-router/scripts/dispatch.sh" AFK_CONTEXT_EVENT_DIR="$EVENTS"
export AFK_CONTEXT_EVENT_TRANSPORT=none AFK_WORKER_TERMINAL=worker-terminal
export AFK_CONTEXT_CHECKPOINT_PPM=700000 AFK_CONTEXT_CONTINUATION_PPM=850000
export ORCA_TERMINAL_HANDLE='' ORCA_WORKTREE_ID=''
export AFK_STATUS_CACHE="$TMP/status-cache.json" AFK_STATUS_CACHE_DIR="$TMP/status-cache-dir" AFK_STATUS_REFRESH_SECONDS=999999
jq -nc '{schema_version:"1.0",kind:"lifecycle_result",source_eligibility:{},orchestration:{state:"ACTIVE",session:{}},dispatch_monitor:{state:"WATCHING",dispatches:[]}}' >"$AFK_STATUS_CACHE"

# A hermetic owner status line (the host's own ~/.local/state is never read):
# AFK adds nothing to a plain chat, and the owner's line must still print.
PRIOR_STATE="$TMP/prior-state"; mkdir -p "$PRIOR_STATE/adapters"
jq -nc --arg b "$PRIOR_STATE/adapters/prior.json" '{backup:$b}' >"$PRIOR_STATE/adapters/claude.json"
jq -nc '{value:{command:"printf OWNER-LINE"}}' >"$PRIOR_STATE/adapters/prior.json"
START_MS="$(date +%s%3N)"
STATUS_OUT="$(env AFK_STATE_DIR="$PRIOR_STATE" "$RUNTIME/claude/statusline.sh" <"$INPUT")"; STATUS_RC=$?
ELAPSED_MS=$(( $(date +%s%3N) - START_MS ))
[[ "$STATUS_RC" == 0 && "$STATUS_OUT" == 'OWNER-LINE' ]] && ok 'Claude statusline still renders under worker pressure' || no "Claude statusline still renders under worker pressure ($STATUS_OUT)"
(( ELAPSED_MS < 1000 )) && ok 'Claude pressure publisher never blocks rendering' || no "Claude pressure publisher never blocks rendering (${ELAPSED_MS}ms)"
wait_events "$EVENTS" 1 || true
CHECK_EVENT="$(event_for "$EVENTS" CHECKPOINT_DUE)"
[[ -n "$CHECK_EVENT" ]] && ok 'authoritative used_percentage emits CHECKPOINT_DUE at equality' || no 'authoritative used_percentage emits CHECKPOINT_DUE at equality'
eq 'Claude event derives usage only to describe the authoritative percentage' "$(jq -r '.source+":"+(.usage.used_tokens|tostring)+":"+(.usage.window_tokens|tostring)' "$CHECK_EVENT")" 'CLAUDE_USED_PERCENTAGE:70000:100000'
"$RUNTIME/claude/statusline.sh" <"$INPUT" >/dev/null
sleep 0.15
eq 'CHECKPOINT_DUE replays once per dispatch and state' "$(find "$EVENTS" -maxdepth 1 -name '*.json' -exec jq -r .state {} \; | grep -c '^CHECKPOINT_DUE$')" 1

jq '.context_window.used_percentage=85' "$INPUT" >"$TMP/continuation-input.json"
"$RUNTIME/claude/statusline.sh" <"$TMP/continuation-input.json" >/dev/null
wait_events "$EVENTS" 2 || true
CONT_EVENT="$(event_for "$EVENTS" CONTINUATION_REQUIRED)"
[[ -n "$CONT_EVENT" ]] && ok 'authoritative used_percentage emits CONTINUATION_REQUIRED at equality' || no 'authoritative used_percentage emits CONTINUATION_REQUIRED at equality'
"$RUNTIME/claude/statusline.sh" <"$TMP/continuation-input.json" >/dev/null; sleep 0.15
eq 'CONTINUATION_REQUIRED replays once per dispatch and state' "$(find "$EVENTS" -maxdepth 1 -name '*.json' -exec jq -r .state {} \; | grep -c '^CONTINUATION_REQUIRED$')" 1

# Missing or invalid observations never manufacture pressure.
for shape in '{}' '{"context_window":{}}' '{"context_window":{"used_percentage":"70"}}' '{"context_window":{"used_percentage":101}}'; do
  BAD_EVENTS="$TMP/bad-$PASS-$RANDOM"; AFK_CONTEXT_EVENT_DIR="$BAD_EVENTS" AFK_DISPATCH_ID="bad-$RANDOM" \
    "$RUNTIME/worker-context.sh" observe --harness claude --input <(printf '%s\n' "$shape")
  eq 'missing/invalid Claude context is a no-op' "$(event_count "$BAD_EVENTS")" 0
done

# A checkpoint event is not marked delivered until the canonical resumable
# checkpoint exists; the same observation remains retryable.
MISSING_STORY="$TMP/missing.md"; printf '# missing checkpoint\n' >"$MISSING_STORY"
MISSING_EVENTS="$TMP/missing-events"; export AFK_STORY_PATH="$MISSING_STORY" AFK_STORY_ID=missing
export AFK_DISPATCH_ID=dispatch-missing AFK_WORKER_IDENTITY=worker:dispatch-missing AFK_CONTEXT_EVENT_DIR="$MISSING_EVENTS"
"$RUNTIME/worker-context.sh" observe --harness claude --input "$INPUT"
eq 'CHECKPOINT_DUE stays unpublished when checkpoint is missing' "$(event_count "$MISSING_EVENTS")" 0
write_checkpoint "$MISSING_STORY"
"$RUNTIME/worker-context.sh" observe --harness claude --input "$INPUT"
eq 'missing-checkpoint observation retries after evidence appears' "$(event_count "$MISSING_EVENTS")" 1

# A broken publisher is fail-open, gets no credentials, and leaves no dedupe
# receipt that could suppress a later successful retry.
FAIL_HOOK="$TMP/fail-hook"; FAIL_ENV="$TMP/fail-env"; FAIL_ARGS="$TMP/fail-args"
printf '#!/usr/bin/env bash\nenv | sort >"%s"\nprintf "%%s\\n" "$*" >"%s"\nexit 7\n' \
  "$FAIL_ENV" "$FAIL_ARGS" >"$FAIL_HOOK"; chmod +x "$FAIL_HOOK"
FAIL_EVENTS="$TMP/fail-events"; export AFK_STORY_PATH="$STORY" AFK_STORY_ID=story AFK_DISPATCH_ID=dispatch-fail
export AFK_WORKER_IDENTITY=worker:dispatch-fail AFK_CONTEXT_EVENT_DIR="$FAIL_EVENTS" AFK_CONTEXT_EVENT_HOOK="$FAIL_HOOK"
START_MS="$(date +%s%3N)"
env AFK_STATE_DIR="$PRIOR_STATE" AFK_SECRET_DO_NOT_EXPOSE=credential \
  "$RUNTIME/claude/statusline.sh" <"$INPUT" >"$TMP/fail-status.out"; FAIL_RC=$?
ELAPSED_MS=$(( $(date +%s%3N) - START_MS )); sleep 0.2
[[ "$FAIL_RC" == 0 && "$(<"$TMP/fail-status.out")" == 'OWNER-LINE' && $ELAPSED_MS -lt 1000 ]] && ok 'publisher failure is fail-open for Claude rendering' || no 'publisher failure is fail-open for Claude rendering'
if [[ -e "$FAIL_ENV" ]] && ! grep -Fq 'AFK_SECRET_DO_NOT_EXPOSE' "$FAIL_ENV"; then ok 'publisher receives no ambient credential'; else no 'publisher receives no ambient credential'; fi
eq 'failed publisher writes no delivery receipt' "$(find "$FAIL_EVENTS" -maxdepth 1 -name '*.done' 2>/dev/null | wc -l | tr -d ' ')" 0
export AFK_CONTEXT_EVENT_HOOK="$ROOT/files/model-router/scripts/dispatch.sh"
"$RUNTIME/worker-context.sh" observe --harness claude --input "$INPUT"
eq 'publisher failure remains retryable' "$(event_count "$FAIL_EVENTS")" 1

# Exact native PreCompact invocation consumes stdin, publishes once, and the
# compact SessionStart path returns model-visible continuation context.
COMPACT_EVENTS="$TMP/compact-events"; export AFK_DISPATCH_ID=dispatch-compact AFK_WORKER_IDENTITY=worker:dispatch-compact
export AFK_CONTEXT_EVENT_DIR="$COMPACT_EVENTS" AFK_STORY_PATH="$STORY" AFK_STORY_ID=story
PRECOMPACT='{"hook_event_name":"PreCompact","session_id":"worker-session","transcript_path":"/must/not/be/read"}'
printf '%s\n' "$PRECOMPACT" | "$RUNTIME/worker-context.sh" compact --harness claude
wait_events "$COMPACT_EVENTS" 1 || true
eq 'native PreCompact publishes CONTINUATION_REQUIRED' "$(jq -r .state "$COMPACT_EVENTS"/*.json)" CONTINUATION_REQUIRED
printf '%s\n' "$PRECOMPACT" | "$RUNTIME/worker-context.sh" compact --harness claude; sleep 0.15
eq 'native PreCompact replay is deduplicated' "$(event_count "$COMPACT_EVENTS")" 1
SESSION_INPUT="$TMP/session-compact.json"; printf '%s\n' '{"hook_event_name":"SessionStart","source":"compact","session_id":"worker-session"}' >"$SESSION_INPUT"
INSTRUCTION_JSON="$("$RUNTIME/worker-context.sh" session-start --harness claude --input "$SESSION_INPUT")"
if jq -e '.hookSpecificOutput.hookEventName=="SessionStart" and (.hookSpecificOutput.additionalContext|contains("canonical <story>.continuation.json") and contains("CONTINUATION-REQUIRED:") and contains("then end this worker turn"))' <<<"$INSTRUCTION_JSON" >/dev/null; then
  ok 'compact SessionStart gives the worker canonical safe-boundary instructions'
else no 'compact SessionStart gives the worker canonical safe-boundary instructions'; fi
eq 'non-compact SessionStart adds no worker instruction' "$(printf '%s\n' '{"source":"startup"}' | "$RUNTIME/worker-context.sh" session-start --harness claude)" ''

# An exact registered PM gets PM instructions and PM pressure only; a wrong
# session or terminal is neither adopted nor treated as a worker.
unset AFK_WORKER_IDENTITY AFK_RUN_ID AFK_STORY_ID AFK_STORY_PATH AFK_CYCLE AFK_DISPATCH_ID AFK_OWNING_PM AFK_DELEGATING_PM AFK_CONTEXT_EVENT_HOOK AFK_CONTEXT_EVENT_DIR
PM_DIR="$TMP/pm"; mkdir -p "$PM_DIR"; export AFK_PM_DIR="$PM_DIR" ORCA_TERMINAL_HANDLE=pm-terminal
NOW_EPOCH="$(date +%s)"
jq -nc --arg p "$(pwd -P)" --argjson e "$NOW_EPOCH" '{schema:"afk-pm-ownership/2",owned:true,role:"PM",harness:"claude",session:"pm-session",terminal:"pm-terminal",worktree:{id:"wt",path:$p},run_id:"run-pm",observed_epoch:$e,freshness_seconds:120}' >"$PM_DIR/ownership.json"
printf '%s\n' '{"hook_event_name":"PreCompact","session_id":"pm-session"}' | "$RUNTIME/worker-context.sh" compact --harness claude
eq 'registered PM compaction writes only PM pressure state' "$(jq -r '.schema+":"+.harness+":"+.session' "$PM_DIR/pressure.json")" 'afk-pm-pressure/1:claude:pm-session'
printf '%s\n' '{"source":"compact","session_id":"pm-session"}' >"$TMP/pm-session-start.json"
PM_INSTRUCTION="$("$RUNTIME/worker-context.sh" session-start --harness claude --input "$TMP/pm-session-start.json")"
if jq -e '.hookSpecificOutput.additionalContext|contains("pm-checkpoint --continuation") and contains("agent-flow-kit pm-continue")' <<<"$PM_INSTRUCTION" >/dev/null; then
  ok 'registered PM receives autonomous managed continuation instructions'
else no 'registered PM receives autonomous managed continuation instructions'; fi
eq 'wrong PM session receives no instruction' "$(printf '%s\n' '{"source":"compact","session_id":"other"}' | "$RUNTIME/worker-context.sh" session-start --harness claude)" ''
ORCA_TERMINAL_HANDLE=other eq 'wrong PM terminal receives no instruction' "$(ORCA_TERMINAL_HANDLE=other "$RUNTIME/worker-context.sh" session-start --harness claude --input "$TMP/pm-session-start.json")" ''

POLICY="$TMP/context-budget-policy.yaml"; printf 'checkpoint_ratio: 0.70\ncontinuation_ratio: 0.85\n' >"$POLICY"
export AGENT_FLOW_BUDGET_POLICY="$POLICY"
jq -nc '{session_id:"pm-session",context_window:{used_percentage:85,context_window_size:100000}}' >"$TMP/pm-pressure-input.json"
"$RUNTIME/claude/statusline.sh" <"$TMP/pm-pressure-input.json" >/dev/null
for _ in {1..50}; do [[ -r "$PM_DIR/pressure.json" ]] && break; sleep 0.02; done
eq 'exact Claude PM numeric pressure writes durable flag' "$(jq -r '.kind+":"+(.used_ppm|tostring)' "$PM_DIR/pressure.json")" 'CONTEXT_PERCENTAGE:850000'
PROMPT_INPUT='{"hook_event_name":"UserPromptSubmit","session_id":"pm-session","prompt":"continue"}'
PROMPT_OUT="$(printf '%s\n' "$PROMPT_INPUT" | "$RUNTIME/worker-context.sh" prompt-boundary --harness claude)"
if jq -e '.hookSpecificOutput.hookEventName=="UserPromptSubmit" and (.hookSpecificOutput.additionalContext|contains("pm-checkpoint --continuation") and contains("agent-flow-kit pm-continue"))' <<<"$PROMPT_OUT" >/dev/null; then
  ok 'next exact Claude PM prompt boundary injects continuation instructions'
else no 'next exact Claude PM prompt boundary injects continuation instructions'; fi
eq 'wrong Claude PM prompt session gets no instruction' "$(printf '%s\n' '{"hook_event_name":"UserPromptSubmit","session_id":"other"}' | "$RUNTIME/worker-context.sh" prompt-boundary --harness claude)" ''

# Composition owns only the exact AFK hooks and restores user/Hindsight hooks.
unset AFK_PM_DIR ORCA_TERMINAL_HANDLE
unset ORCA_WORKTREE_ID AGENT_FLOW_BUDGET_POLICY
CLAUDE_HOME="$TMP/claude-home"; CLAUDE_STATE="$TMP/claude-state"; mkdir -p "$CLAUDE_HOME/.claude"
jq -nc '{theme:"owner",hooks:{SessionStart:[{hooks:[{type:"command",command:"hindsight recall"}]}],PreCompact:[{hooks:[{type:"command",command:"owner compact"}]}]}}' >"$CLAUDE_HOME/.claude/settings.json"
cp "$CLAUDE_HOME/.claude/settings.json" "$TMP/claude-before.json"
"$RUNTIME/manage.sh" install claude --home "$CLAUDE_HOME" --state-dir "$CLAUDE_STATE" --adapter-root "$RUNTIME" >/dev/null
"$RUNTIME/manage.sh" install claude --home "$CLAUDE_HOME" --state-dir "$CLAUDE_STATE" --adapter-root "$RUNTIME" >/dev/null
CLAUDE_CONFIG="$CLAUDE_HOME/.claude/settings.json"; CLAUDE_COMPACT="$RUNTIME/worker-context.sh compact --harness claude"; CLAUDE_RESUME="$RUNTIME/worker-context.sh session-start --harness claude"
CLAUDE_PROMPT="$RUNTIME/worker-context.sh prompt-boundary --harness claude"
eq 'Claude owns one exact PreCompact publisher' "$(jq --arg c "$CLAUDE_COMPACT" '[.hooks.PreCompact[]?.hooks[]?|select(.command==$c and .type=="command" and .timeout==3)]|length' "$CLAUDE_CONFIG")" 1
eq 'Claude owns one compact SessionStart instruction' "$(jq --arg c "$CLAUDE_RESUME" '[.hooks.SessionStart[]?|select(.matcher=="compact")|.hooks[]?|select(.command==$c)]|length' "$CLAUDE_CONFIG")" 1
eq 'Claude owns one exact PM prompt-boundary instruction' "$(jq --arg c "$CLAUDE_PROMPT" '[.hooks.UserPromptSubmit[]?.hooks[]?|select(.command==$c and .type=="command" and .timeout==3)]|length' "$CLAUDE_CONFIG")" 1
eq 'Claude preserves existing Hindsight/user hooks' "$(jq '[.hooks.SessionStart[]?.hooks[]?|select(.command=="hindsight recall")]+[.hooks.PreCompact[]?.hooks[]?|select(.command=="owner compact")]|length' "$CLAUDE_CONFIG")" 2
"$RUNTIME/manage.sh" remove claude --home "$CLAUDE_HOME" --state-dir "$CLAUDE_STATE" --adapter-root "$RUNTIME" >/dev/null
diff -u <(jq -S . "$TMP/claude-before.json") <(jq -S . "$CLAUDE_CONFIG") >/dev/null && ok 'Claude removal restores exact prior hooks' || no 'Claude removal restores exact prior hooks'

CODEX_HOME="$TMP/codex-home"; CODEX_STATE="$TMP/codex-state"; mkdir -p "$CODEX_HOME/.codex"
printf '[tui]\nstatus_line=["model"]\n' >"$CODEX_HOME/.codex/config.toml"
jq -nc '{hooks:{SessionStart:[{hooks:[{type:"command",command:"hindsight recall"}]}],PreCompact:[{hooks:[{type:"command",command:"owner compact"}]}]}}' >"$CODEX_HOME/.codex/hooks.json"
cp "$CODEX_HOME/.codex/hooks.json" "$TMP/codex-before.json"
"$RUNTIME/manage.sh" install codex --home "$CODEX_HOME" --state-dir "$CODEX_STATE" --adapter-root "$RUNTIME" >/dev/null
"$RUNTIME/manage.sh" install codex --home "$CODEX_HOME" --state-dir "$CODEX_STATE" --adapter-root "$RUNTIME" >/dev/null
CODEX_CONFIG="$CODEX_HOME/.codex/hooks.json"; CODEX_RESUME="$RUNTIME/worker-context.sh session-start --harness codex"
eq 'Codex owns one compact SessionStart instruction' "$(jq --arg c "$CODEX_RESUME" '[.hooks.SessionStart[]?|select(.matcher=="compact")|.hooks[]?|select(.command==$c)]|length' "$CODEX_CONFIG")" 1
eq 'Codex preserves Hindsight and user PreCompact hook' "$(jq '[.hooks.SessionStart[]?.hooks[]?|select(.command=="hindsight recall")]+[.hooks.PreCompact[]?.hooks[]?|select(.command=="owner compact")]|length' "$CODEX_CONFIG")" 2
"$RUNTIME/manage.sh" remove codex --home "$CODEX_HOME" --state-dir "$CODEX_STATE" --adapter-root "$RUNTIME" >/dev/null
diff -u <(jq -S . "$TMP/codex-before.json") <(jq -S . "$CODEX_CONFIG") >/dev/null && ok 'Codex removal restores exact prior hooks' || no 'Codex removal restores exact prior hooks'

# Codex's real PreCompact publisher consumes native stdin and fails open while
# returning only supported universal output.
UNBOUND_CODEX_OUT="$(env -u AFK_WORKER_IDENTITY -u AFK_RUN_ID -u AFK_STORY_ID -u AFK_STORY_PATH -u AFK_CYCLE \
  -u AFK_DISPATCH_ID -u AFK_OWNING_PM -u AFK_DELEGATING_PM -u AFK_CONTEXT_EVENT_HOOK -u AFK_PM_DIR \
  ORCA_TERMINAL_HANDLE='' AFK_STATUS_CACHE="$TMP/status-cache.json" AFK_STATUS_CACHE_DIR="$TMP/unbound-codex-cache" \
  "$RUNTIME/codex/publish.sh" <<<"$PRECOMPACT")"
jq -e 'has("continue")|not' <<<"$UNBOUND_CODEX_OUT" >/dev/null \
  && ! jq -e '.systemMessage|contains("CONTINUATION_REQUIRED")' <<<"$UNBOUND_CODEX_OUT" >/dev/null \
  && ok 'unbound Codex PreCompact makes no continuation claim' || no 'unbound Codex PreCompact makes no continuation claim'
export AFK_WORKER_IDENTITY=worker:codex AFK_RUN_ID=run-c AFK_STORY_ID=story AFK_STORY_PATH="$STORY" AFK_CYCLE=1
export AFK_DISPATCH_ID=dispatch-codex AFK_OWNING_PM=run:run-c AFK_DELEGATING_PM=pm-owner
export AFK_CONTEXT_EVENT_HOOK="$ROOT/files/model-router/scripts/dispatch.sh" AFK_CONTEXT_EVENT_DIR="$TMP/codex-events" AFK_CONTEXT_EVENT_TRANSPORT=none
CODEX_OUT="$(printf '%s\n' "$PRECOMPACT" | "$RUNTIME/codex/publish.sh")"
wait_events "$TMP/codex-events" 1 || true
jq -e '.continue==true and (.systemMessage|contains("bound to an AFK worker or PM") and contains("stop at the next safe boundary"))' <<<"$CODEX_OUT" >/dev/null && ok 'Codex PreCompact returns truthful supported universal output' || no 'Codex PreCompact returns truthful supported universal output'
eq 'Codex PreCompact publishes worker continuation pressure' "$(jq -r .state "$TMP/codex-events"/*.json)" CONTINUATION_REQUIRED

# OpenCode uses its documented compaction hook and event API. Both observations
# converge on one dispatch+state event.
export AFK_DISPATCH_ID=dispatch-open AFK_WORKER_IDENTITY=worker:dispatch-open AFK_CONTEXT_EVENT_DIR="$TMP/open-events"
OPEN_CONTEXT="$TMP/open-context.txt"; OPEN_PLUGIN="$RUNTIME/opencode/plugin.js"
AFK_TEST_PLUGIN="$OPEN_PLUGIN" AFK_TEST_CONTEXT="$OPEN_CONTEXT" AFK_STATUS_CACHE_DIR="$TMP/open-cache" \
  node --input-type=module <<'NODE'
import { writeFileSync } from "node:fs"
import { pathToFileURL } from "node:url"
const mod = await import(pathToFileURL(process.env.AFK_TEST_PLUGIN))
const plugin = await mod.default({ client: { tui: { showToast: async () => {} } } })
const output = { context: [] }
await plugin["experimental.session.compacting"]({ sessionID: "worker-session" }, output)
await plugin.event({ event: { type: "session.compacted", properties: { sessionID: "worker-session" } } })
writeFileSync(process.env.AFK_TEST_CONTEXT, output.context.join("\n"))
await new Promise((resolve) => setTimeout(resolve, 250))
NODE
contains "$(<"$OPEN_CONTEXT")" 'CONTINUATION-REQUIRED:' && ok 'OpenCode compacting injects model-visible worker instruction' || no 'OpenCode compacting injects model-visible worker instruction'
wait_events "$TMP/open-events" 1 || true; sleep 0.15
eq 'OpenCode compacting/compacted replay publishes once' "$(event_count "$TMP/open-events")" 1
eq 'OpenCode event publishes CONTINUATION_REQUIRED' "$(jq -r .state "$TMP/open-events"/*.json)" CONTINUATION_REQUIRED

if grep -nE 'canonical_continuation_dispatch|--consume-context-event|terminal (create|close)|cat .*transcript|OPENAI_API_KEY|ANTHROPIC_API_KEY' "$ROOT/adapters/worker-context.sh" >/dev/null; then
  no 'worker event publisher has no launch/close/transcript/credential path'
else
  ok 'worker event publisher has no launch/close/transcript/credential path'
fi

printf '1..%d\n' "$((PASS + FAIL))"
if (( FAIL )); then printf '%d worker-pressure assertions failed\n' "$FAIL" >&2; exit 1; fi
printf 'All %d worker-pressure assertions passed.\n' "$PASS"
