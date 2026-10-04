#!/usr/bin/env bash
# Test assertions intentionally use `condition && ok || no` with helpers that
# always return success.
# shellcheck disable=SC2015,SC2016,SC2329 # test idioms, generated fixtures, exported poison functions
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); }; no(){ printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }
eq(){ if [[ "$2" == "$3" ]]; then ok; else no "$1 expected=$3 got=$2"; fi; }

jq -n '{schema_version:"1.0",kind:"lifecycle_result",source_eligibility:{revision_relation:"SAME"},orchestration:{state:"ACTIVE",session:{mode:"ORCH",persona:"PM",task:"AFK-1",phase:"implementation",needs_human:true}},dispatch_monitor:{state:"WATCHING",dispatches:[{state:"WATCHING"},{state:"SETTLED"}]},extra:{pm_budget:{usage_tokens:70,window_tokens:100,needs_human:true}},runtime:{model:"gpt",subscription:{state:"ACTIVE",reset_at:"tomorrow"}}}' >"$TMP/status.json"
out="$("$ROOT/adapters/render-status.sh" --input "$TMP/status.json" --harness codex)"
if [[ "$out" == *'AFK ORCH/PM'* && "$out" == *'workers=1/0/1'* && "$out" == *'!NEEDS_HUMAN!'* ]]; then ok; else no "visible status rendering"; fi

# Default runtime state is isolated by exact Orca terminal, so concurrent
# harness sessions cannot overwrite one another's model/context presentation.
scope_cache="$TMP/scoped-cache"; mkdir -p "$TMP/work-a" "$TMP/work-b"
jq -nc '{session_id:"session-a",model:{display_name:"Alpha"},context_window:{used_percentage:10,context_window_size:100}}' >"$TMP/runtime-a.json"
jq -nc '{session_id:"session-b",model:{display_name:"Beta"},context_window:{used_percentage:20,context_window_size:200}}' >"$TMP/runtime-b.json"
env -u AFK_STATUS_CACHE -u AFK_STATUS_CACHE_DIR XDG_CACHE_HOME="$scope_cache" ORCA_TERMINAL_HANDLE=terminal-a \
  "$ROOT/adapters/publish-runtime.sh" --harness claude --input "$TMP/runtime-a.json"
env -u AFK_STATUS_CACHE -u AFK_STATUS_CACHE_DIR XDG_CACHE_HOME="$scope_cache" ORCA_TERMINAL_HANDLE=terminal-b \
  "$ROOT/adapters/publish-runtime.sh" --harness claude --input "$TMP/runtime-b.json"
mapfile -t scoped_runtime_files < <(find "$scope_cache/agent-flow-kit/scopes" -name runtime-claude.json -type f | sort)
eq "two terminals receive two runtime caches" "${#scoped_runtime_files[@]}" 2
eq "terminal runtime models do not cross" "$(jq -rs 'map(.model.value)|sort|join(":")' "${scoped_runtime_files[@]}")" Alpha:Beta
# shellcheck disable=SC2016
cache_a="$(env XDG_CACHE_HOME="$scope_cache" ORCA_TERMINAL_HANDLE=terminal-a bash -c '. "$1"; afk_default_status_cache_dir' _ "$ROOT/adapters/runtime-scope.sh")"
# shellcheck disable=SC2016
cache_b="$(env XDG_CACHE_HOME="$scope_cache" ORCA_TERMINAL_HANDLE=terminal-b bash -c '. "$1"; afk_default_status_cache_dir' _ "$ROOT/adapters/runtime-scope.sh")"
cp "$TMP/status.json" "$cache_a/status.json"; cp "$TMP/status.json" "$cache_b/status.json"
out_a="$(env -u AFK_STATUS_CACHE -u AFK_STATUS_CACHE_DIR XDG_CACHE_HOME="$scope_cache" ORCA_TERMINAL_HANDLE=terminal-a "$ROOT/adapters/render-status.sh" --harness claude)"
out_b="$(env -u AFK_STATUS_CACHE -u AFK_STATUS_CACHE_DIR XDG_CACHE_HOME="$scope_cache" ORCA_TERMINAL_HANDLE=terminal-b "$ROOT/adapters/render-status.sh" --harness claude)"
if [[ "$out_a" == *'cli=claude/Alpha'* && "$out_b" == *'cli=claude/Beta'* ]]; then ok; else no "terminal render selected another terminal's observation"; fi

# Runtime observations age independently from the lifecycle cache. A stale or
# non-regular harness observation cannot masquerade as the active model/context
# or block the status renderer.
jq '.observed_at="2000-01-01T00:00:00Z"|.model.value="Expired"' "$cache_a/runtime-claude.json" >"$TMP/expired-runtime.json"
mv "$TMP/expired-runtime.json" "$cache_a/runtime-claude.json"
out_a="$(env -u AFK_STATUS_CACHE -u AFK_STATUS_CACHE_DIR XDG_CACHE_HOME="$scope_cache" ORCA_TERMINAL_HANDLE=terminal-a "$ROOT/adapters/render-status.sh" --harness claude)"
if [[ "$out_a" == *'cli=claude/gpt'* && "$out_a" != *Expired* ]]; then ok; else no "stale runtime observation is not presented as current"; fi
rm -f "$cache_a/runtime-claude.json"; mkfifo "$cache_a/runtime-claude.json"
if timeout 2 env -u AFK_STATUS_CACHE -u AFK_STATUS_CACHE_DIR XDG_CACHE_HOME="$scope_cache" ORCA_TERMINAL_HANDLE=terminal-a \
  "$ROOT/adapters/render-status.sh" --harness claude >"$TMP/fifo-render.out"; then
  [[ "$(<"$TMP/fifo-render.out")" == *'cli=claude/gpt'* ]] && ok || no "FIFO runtime observation falls back safely"
else no "FIFO runtime observation cannot block rendering"; fi

# Outside Orca, native hook session IDs replace the former worktree-global
# fallback; an event with no terminal or session receives no default cache.
non_orca_cache="$TMP/non-orca-cache"
for session_input in "$TMP/runtime-a.json" "$TMP/runtime-b.json"; do
  env -u ORCA_TERMINAL_HANDLE -u AFK_STATUS_CACHE -u AFK_STATUS_CACHE_DIR XDG_CACHE_HOME="$non_orca_cache" \
    AFK_STATUS_BIN="$TMP/not-installed" "$ROOT/adapters/claude/statusline.sh" <"$session_input" >/dev/null
done
mapfile -t non_orca_files < <(find "$non_orca_cache/agent-flow-kit/scopes" -name runtime-claude.json -type f | sort)
eq "two non-Orca sessions receive two runtime caches" "${#non_orca_files[@]}" 2
eq "non-Orca session models do not cross" "$(jq -rs 'map(.model.value)|sort|join(":")' "${non_orca_files[@]}")" Alpha:Beta
set +e
# shellcheck disable=SC2016
env -u ORCA_TERMINAL_HANDLE -u AFK_RUNTIME_SESSION_ID bash -c '. "$1"; afk_default_status_cache_dir' _ "$ROOT/adapters/runtime-scope.sh" >/dev/null
no_session_scope_rc=$?
set -e
eq "unidentified non-Orca event has no default runtime cache" "$no_session_scope_rc" 1
# Native input always overrides an inherited session variable from a parent
# process, so stale launcher state cannot redirect publication.
inherited_cache="$TMP/inherited-session-cache"
env -u ORCA_TERMINAL_HANDLE -u AFK_STATUS_CACHE -u AFK_STATUS_CACHE_DIR AFK_RUNTIME_SESSION_ID=stale-session \
  XDG_CACHE_HOME="$inherited_cache" AFK_STATUS_BIN="$TMP/not-installed" "$ROOT/adapters/codex/publish.sh" \
  <<<'{"session_id":"fresh-session","model":"fresh"}' >/dev/null
# shellcheck disable=SC2016
fresh_dir="$(env -u ORCA_TERMINAL_HANDLE AFK_RUNTIME_SESSION_ID=fresh-session XDG_CACHE_HOME="$inherited_cache" bash -c '. "$1"; afk_default_status_cache_dir' _ "$ROOT/adapters/runtime-scope.sh")"
# shellcheck disable=SC2016
stale_dir="$(env -u ORCA_TERMINAL_HANDLE AFK_RUNTIME_SESSION_ID=stale-session XDG_CACHE_HOME="$inherited_cache" bash -c '. "$1"; afk_default_status_cache_dir' _ "$ROOT/adapters/runtime-scope.sh")"
[[ -f "$fresh_dir/runtime-codex.json" && ! -e "$stale_dir/runtime-codex.json" ]] && ok || no "Codex wrapper rejects inherited runtime session scope"

# PM ownership is worktree-scoped rather than host-global: a successor terminal
# in one worktree shares its handoff, while another project cannot claim it.
pm_a="$(cd "$TMP/work-a" && HOME="$TMP/scope-home" AFK_STATE_DIR="$TMP/scope-state" bash -c '. "$1"; afk_default_pm_dir' _ "$ROOT/adapters/runtime-scope.sh")"
pm_a_successor="$(cd "$TMP/work-a" && HOME="$TMP/scope-home" AFK_STATE_DIR="$TMP/scope-state" ORCA_TERMINAL_HANDLE=successor bash -c '. "$1"; afk_default_pm_dir' _ "$ROOT/adapters/runtime-scope.sh")"
pm_b="$(cd "$TMP/work-b" && HOME="$TMP/scope-home" AFK_STATE_DIR="$TMP/scope-state" bash -c '. "$1"; afk_default_pm_dir' _ "$ROOT/adapters/runtime-scope.sh")"
eq "successor terminal shares worktree PM state" "$pm_a_successor" "$pm_a"
if [[ "$pm_a" != "$pm_b" ]]; then ok; else no "distinct worktrees shared PM ownership state"; fi
jq -nc '{schema:"afk-pm-checkpoint/1",decisions:[],envelope_actions:[],open_escalations:[],budget_state:{},in_flight_dispatches:[],updated_at:"2026-09-15T00:00:00Z"}' >"$TMP/scoped-pm-checkpoint.json"
for scoped_worktree in "$TMP/work-a" "$TMP/work-b"; do
  (cd "$scoped_worktree" && HOME="$TMP/scope-home" AFK_STATE_DIR="$TMP/scoped-lifecycle-state" \
    "$ROOT/bin/agent-flow-kit" pm-checkpoint --write "$TMP/scoped-pm-checkpoint.json" --json >/dev/null) \
    || no "lifecycle default PM scope writes checkpoint"
done
eq "lifecycle command creates one PM scope per worktree" \
  "$(find "$TMP/scoped-lifecycle-state/pm/scopes" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" 2
eq "each lifecycle PM scope receives its own checkpoint" \
  "$(find "$TMP/scoped-lifecycle-state/pm/scopes" -name checkpoint.json -type f | wc -l | tr -d ' ')" 2

# Run the readiness-before-PM status consumer regression before the known
# Hindsight root-ownership precondition later in this script.
pm_precedence="$TMP/pm-precedence"; mkdir -p "$pm_precedence"
jq -nc --arg p "$ROOT" '{schema:"afk-pm-ownership/3",owned:true,role:"PM",harness:"codex",session:"s",terminal:"t",worktree:{id:"w",path:$p},run_id:null,control:{schema:"afk-pm-control/1",execution_profile:"interactive",control_owner:"human",approval_channel:"terminal_human",revision:null,launch_provenance:{status:"attested"},provenance:{status:"attested"}}}' \
  >"$pm_precedence/ownership.json"
for readiness_exit in 3 5; do
  preserved_exit="$(bash -c '
    ROOT="$1"; AFK_PM_DIR="$2"; AFK_TEST_READINESS_EXIT="$3"
    . "$ROOT/lib/afk-common.sh"; . "$ROOT/lib/afk-pm-control.sh"; . "$ROOT/lib/afk-commands.sh"
    afk_evaluate_installation() { AFK_R_EXTRA="{}"; AFK_FINDINGS="[]"; AFK_LIVE_MODE=true; }
    afk_readiness_exit_code() { printf "%s" "$AFK_TEST_READINESS_EXIT"; }
    afk_pm_observation() { return 1; }
    afk_pm_handoff_json() { printf "{}"; }
    afk_emit_result() { return "$AFK_R_FORCED_EXIT"; }
    if afk_cmd_status true false false false >/dev/null 2>&1; then rc=0; else rc=$?; fi
    [[ "$AFK_FINDINGS" == *PM_CONTROL_INVALID* ]] && finding=true || finding=false
    printf "%s|%s" "${rc:-0}" "$finding"
  ' _ "$ROOT" "$pm_precedence" "$readiness_exit")"
  IFS='|' read -r actual_exit invalid_control_findings <<<"$preserved_exit"
  eq "invalid PM control preserves readiness exit $readiness_exit" "$actual_exit" "$readiness_exit"
  eq "readiness exit $readiness_exit retains invalid-control finding" "$invalid_control_findings" true
done

cp "$TMP/status.json" "$TMP/cache.json"; touch -d '@100' "$TMP/cache.json"
# The generated fixture expands this at runtime.
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nprintf invoked >"$AFK_SLOW_MARKER"\nsleep 1\n' >"$TMP/slow"; chmod +x "$TMP/slow"
out="$(AFK_SLOW_MARKER="$TMP/slow-marker" AFK_STATUS_BIN="$TMP/slow" "$ROOT/adapters/render-status.sh" --cache "$TMP/cache.json" --now 300 --harness claude)"
if [[ "$out" == STALE* ]]; then ok; else no "stale fallback"; fi
if [[ ! -e "$TMP/slow-marker" ]]; then ok; else no "renderer invoked slow producer"; fi
out="$(AFK_SLOW_MARKER="$TMP/slow-marker" AFK_STATUS_BIN="$TMP/slow" "$ROOT/adapters/render-status.sh" --cache "$TMP/missing.json" --now 200 --harness claude)"
eq "unavailable fallback" "$out" 'AFK UNAVAILABLE[STATUS_UNAVAILABLE]'
if [[ ! -e "$TMP/slow-marker" ]]; then ok; else no "unavailable renderer invoked producer"; fi

home="$TMP/home"; state="$TMP/state"; mkdir -p "$home/.claude"
prior="$TMP/prior-status"; received="$TMP/prior-input"
# The generated fixture expands this at runtime.
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\ntee "$AFK_PRIOR_RECEIVED" >/dev/null\nprintf PRIOR-STATUS\n' >"$prior"; chmod +x "$prior"
prior_command="$prior | sed 's/PRIOR/OWNER/'"
jq -nc --arg c "$prior_command" '{statusLine:{type:"command",command:$c,padding:3,refreshInterval:7,hideVimModeIndicator:true},hooks:{keep:true,SessionStart:[],PreCompact:[],UserPromptSubmit:[]}}' >"$home/.claude/settings.json"
cp "$home/.claude/settings.json" "$TMP/claude-before.json"
"$ROOT/adapters/manage.sh" install claude --home "$home" --state-dir "$state" --adapter-root "$ROOT/adapters" >/dev/null || no "Claude install"
"$ROOT/adapters/manage.sh" install claude --home "$home" --state-dir "$state" --adapter-root "$ROOT/adapters" >/dev/null || no "Claude reinstall"
eq "one Claude registration" "$(jq '[.statusLine]|length' "$home/.claude/settings.json")" 1
eq "Claude padding preserved while installed" "$(jq -r .statusLine.padding "$home/.claude/settings.json")" 3
claude_input="$TMP/claude-input.json"
jq -nc '{session_id:"session-1",model:{id:"claude-opus",display_name:"Opus"},context_window:{total_input_tokens:42,total_output_tokens:7,context_window_size:200000,used_percentage:12},rate_limits:{five_hour:{used_percentage:21},seven_day:{used_percentage:31}}}' >"$claude_input"
touch "$TMP/cache.json"
out="$(AFK_STATE_DIR="$state" AFK_STATUS_CACHE="$TMP/cache.json" AFK_STATUS_CACHE_DIR="$TMP/runtime-cache" AFK_STATUS_REFRESH_SECONDS=999999 AFK_PRIOR_RECEIVED="$received" "$ROOT/adapters/claude/statusline.sh" <"$claude_input")"
if [[ "$(tail -n1 <<<"$out")" == 'OWNER-STATUS' && "$(head -n1 <<<"$out")" == *'! AFK NEEDS YOU'* ]]; then ok; else no "Claude composed status preserves owner shell semantics"; fi
if cmp "$claude_input" "$received" >/dev/null; then ok; else no "Claude prior command received exact stdin"; fi
eq "Claude prior invoked once" "$(wc -l <"$received" | tr -d ' ')" 1
"$ROOT/adapters/manage.sh" remove claude --home "$home" --state-dir "$state" --adapter-root "$ROOT/adapters" >/dev/null || no "Claude removal"
if diff -u <(jq -S . "$TMP/claude-before.json") <(jq -S . "$home/.claude/settings.json") >/dev/null; then ok; else no "Claude prior object exact restoration"; fi
eq "unrelated Claude configuration preserved" "$(jq -r '.hooks.keep' "$home/.claude/settings.json")" true

# A post-install user edit to the composed statusLine is never overwritten by
# removal; ownership evidence remains for an explicit retry after resolution.
claude_drift_home="$TMP/claude-drift-home"; claude_drift_state="$TMP/claude-drift-state"
mkdir -p "$claude_drift_home/.claude"; printf '{"statusLine":{"type":"command","command":"owner"}}\n' >"$claude_drift_home/.claude/settings.json"
"$ROOT/adapters/manage.sh" install claude --home "$claude_drift_home" --state-dir "$claude_drift_state" --adapter-root "$ROOT/adapters" >/dev/null
jq '.statusLine.padding=9' "$claude_drift_home/.claude/settings.json" >"$TMP/claude-drift.json"; mv "$TMP/claude-drift.json" "$claude_drift_home/.claude/settings.json"
set +e; "$ROOT/adapters/manage.sh" remove claude --home "$claude_drift_home" --state-dir "$claude_drift_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; claude_drift_rc=$?; set -e
eq "drifted Claude statusLine removal refuses" "$claude_drift_rc" 3
eq "drifted Claude statusLine edit survives" "$(jq -r .statusLine.padding "$claude_drift_home/.claude/settings.json")" 9
if [[ -f "$claude_drift_state/adapters/claude.json" && -f "$claude_drift_state/adapters/claude-prior.json" ]]; then ok; else no "drifted Claude removal retains ownership evidence"; fi
# Drift on an owned hook object is likewise preserved rather than partially
# deleting the user's augmented object.
jq 'del(.statusLine.padding) | .hooks.PreCompact[-1].ownerField="keep"' "$claude_drift_home/.claude/settings.json" >"$TMP/claude-hook-drift.json"; mv "$TMP/claude-hook-drift.json" "$claude_drift_home/.claude/settings.json"
set +e; "$ROOT/adapters/manage.sh" remove claude --home "$claude_drift_home" --state-dir "$claude_drift_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; claude_hook_drift_rc=$?; set -e
eq "drifted Claude owned hook removal refuses" "$claude_hook_drift_rc" 3
eq "drifted Claude owned hook survives intact" "$(jq -r '.hooks.PreCompact[-1].ownerField' "$claude_drift_home/.claude/settings.json")" keep

mkdir -p "$home/.codex"
printf '[tui]\nstatus_line = ["model", "git-branch"]\n' >"$home/.codex/config.toml"
printf '{"hooks":{"SessionStart":[],"PreCompact":[],"Stop":[{"hooks":[{"type":"command","command":"keep"}]}]}}\n' >"$home/.codex/hooks.json"
cp "$home/.codex/hooks.json" "$TMP/codex-hooks-before.json"
"$ROOT/adapters/manage.sh" install codex --home "$home" --state-dir "$state" --adapter-root "$ROOT/adapters" >/dev/null || no "Codex install"
"$ROOT/adapters/manage.sh" install codex --home "$home" --state-dir "$state" --adapter-root "$ROOT/adapters" >/dev/null || no "Codex reinstall"
codex_items="$(yq -p=toml -o=json '.tui.status_line' "$home/.codex/config.toml")"
if jq -n -e 'all(["model-with-reasoning","context-used","context-remaining","five-hour-limit","weekly-limit","git-branch","task-progress"][]; . as $x | $ARGS.positional[0] | index($x))' --args "$codex_items" >/dev/null 2>&1; then :; fi
eq "Codex native model item" "$(jq --arg x model-with-reasoning 'index($x)!=null' <<<"$codex_items")" true
eq "Codex native context item" "$(jq --arg x context-remaining 'index($x)!=null' <<<"$codex_items")" true
eq "Codex native rate item" "$(jq --arg x weekly-limit 'index($x)!=null' <<<"$codex_items")" true
eq "Codex publisher hook composed" "$(jq '[.hooks.SessionStart[]?.hooks[]?|select(.command|endswith("/codex/publish.sh"))]|length' "$home/.codex/hooks.json")" 1
eq "Codex publisher is synchronous for visible output" "$(jq '[.hooks.SessionStart[]?.hooks[]?|select(.command|endswith("/codex/publish.sh"))][0]|has("async")' "$home/.codex/hooks.json")" false
codex_hook_out="$(AFK_STATUS_CACHE="$TMP/cache.json" AFK_STATUS_CACHE_DIR="$TMP/runtime-cache" AFK_STATUS_REFRESH_SECONDS=999999 "$ROOT/adapters/codex/publish.sh" <<<'{"session_id":"codex-session","model":"gpt-test"}')"
if jq -e '.systemMessage|startswith("AFK ")' <<<"$codex_hook_out" >/dev/null; then ok; else no "Codex visible AFK session message"; fi
"$ROOT/adapters/manage.sh" remove codex --home "$home" --state-dir "$state" --adapter-root "$ROOT/adapters" >/dev/null || no "Codex removal"
eq "Codex native surface restored" "$(yq -p=toml -o=json -I=0 '.tui.status_line' "$home/.codex/config.toml")" '["model","git-branch"]'
if diff -u <(jq -S . "$TMP/codex-hooks-before.json") <(jq -S . "$home/.codex/hooks.json") >/dev/null; then ok; else no "Codex hooks restored"; fi

# A host with no prior native footer must return to no tui table, not fail in
# yq or leave an empty table behind. Empty hook groups remain user-owned too.
absent_home="$TMP/codex-absent-home"; absent_state="$TMP/codex-absent-state"
mkdir -p "$absent_home/.codex"
printf '[features]\nhooks = true\n' >"$absent_home/.codex/config.toml"
printf '{"hooks":{"SessionStart":[],"PreCompact":[]}}\n' >"$absent_home/.codex/hooks.json"
cp "$absent_home/.codex/config.toml" "$TMP/codex-absent-before.toml"
cp "$absent_home/.codex/hooks.json" "$TMP/codex-absent-hooks-before.json"
"$ROOT/adapters/manage.sh" install codex --home "$absent_home" --state-dir "$absent_state" --adapter-root "$ROOT/adapters" >/dev/null || no "Codex absent-footer install"
"$ROOT/adapters/manage.sh" remove codex --home "$absent_home" --state-dir "$absent_state" --adapter-root "$ROOT/adapters" >/dev/null || no "Codex absent-footer removal"
eq "Codex absent footer stays absent" "$(yq -p=toml -o=json 'has("tui")' "$absent_home/.codex/config.toml")" false
if diff -u <(yq -p=toml -o=json -I=0 '.' "$TMP/codex-absent-before.toml") <(yq -p=toml -o=json -I=0 '.' "$absent_home/.codex/config.toml") >/dev/null; then ok; else no "Codex absent-footer config restored"; fi
if diff -u <(jq -S . "$TMP/codex-absent-hooks-before.json") <(jq -S . "$absent_home/.codex/hooks.json") >/dev/null; then ok; else no "Codex absent-footer hooks restored"; fi

# Completely absent harness configuration is removed exactly after uninstall.
for absent_harness in claude codex opencode; do
  clean_home="$TMP/clean-$absent_harness-home"; clean_state="$TMP/clean-$absent_harness-state"; mkdir -p "$clean_home"
  "$ROOT/adapters/manage.sh" install "$absent_harness" --home "$clean_home" --state-dir "$clean_state" --adapter-root "$ROOT/adapters" >/dev/null || no "$absent_harness clean install"
  "$ROOT/adapters/manage.sh" remove "$absent_harness" --home "$clean_home" --state-dir "$clean_state" --adapter-root "$ROOT/adapters" >/dev/null || no "$absent_harness clean removal"
  case "$absent_harness" in
    claude) [[ ! -e "$clean_home/.claude/settings.json" ]] && ok || no "Claude absent settings restored" ;;
    codex)
      [[ ! -e "$clean_home/.codex/config.toml" ]] && ok || no "Codex absent config restored"
      [[ ! -e "$clean_home/.codex/hooks.json" ]] && ok || no "Codex absent hooks restored" ;;
    opencode) [[ ! -e "$clean_home/.config/opencode/opencode.json" ]] && ok || no "OpenCode absent config restored" ;;
  esac
done

# An identical-looking entry without AFK's ownership record is user-owned.
unmanaged_home="$TMP/unmanaged-home"; unmanaged_state="$TMP/unmanaged-state"
mkdir -p "$unmanaged_home/.codex" "$unmanaged_home/.config/opencode"
printf '[tui]\nstatus_line = ["model"]\n' >"$unmanaged_home/.codex/config.toml"
jq -nc --arg c "$ROOT/adapters/codex/publish.sh" '{hooks:{SessionStart:[{hooks:[{type:"command",command:$c}]}]}}' >"$unmanaged_home/.codex/hooks.json"
set +e; "$ROOT/adapters/manage.sh" install codex --home "$unmanaged_home" --state-dir "$unmanaged_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; unmanaged_rc=$?; set -e
eq "unmanaged Codex hook is not adopted" "$unmanaged_rc" 3
jq -nc --arg p "file://$ROOT/adapters/opencode/plugin.js" '{plugin:[$p]}' >"$unmanaged_home/.config/opencode/opencode.jsonc"
set +e; "$ROOT/adapters/manage.sh" install opencode --home "$unmanaged_home" --state-dir "$unmanaged_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; unmanaged_rc=$?; set -e
eq "unmanaged OpenCode plugin is not adopted" "$unmanaged_rc" 3

# Removal refuses without deleting its hook or restoration evidence when the
# user changed the native footer after installation.
drift_home="$TMP/drift-home"; drift_state="$TMP/drift-state"; mkdir -p "$drift_home/.codex"
printf '[tui]\nstatus_line = ["model"]\n' >"$drift_home/.codex/config.toml"
printf '{"hooks":{}}\n' >"$drift_home/.codex/hooks.json"
"$ROOT/adapters/manage.sh" install codex --home "$drift_home" --state-dir "$drift_state" --adapter-root "$ROOT/adapters" >/dev/null
yq -i -p=toml -o=toml '.tui.status_line += ["current-dir"]' "$drift_home/.codex/config.toml"
set +e; "$ROOT/adapters/manage.sh" remove codex --home "$drift_home" --state-dir "$drift_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; drift_rc=$?; set -e
eq "drifted Codex removal refuses" "$drift_rc" 3
if [[ -f "$drift_state/adapters/codex.json" && -f "$drift_state/adapters/codex-prior.json" ]] && jq -e --arg c "$ROOT/adapters/codex/publish.sh" 'any(.hooks.SessionStart[]?.hooks[]?; .command==$c)' "$drift_home/.codex/hooks.json" >/dev/null; then ok; else no "drifted Codex removal retains ownership evidence"; fi

mkdir -p "$home/.config/opencode"
# shellcheck disable=SC2016
printf '%s\n' '{"$schema":"https://opencode.ai/config.json","plugin":["/native/hindsight","file:///native/orca-opencode-status.js"],"keep":true}' >"$home/.config/opencode/opencode.jsonc"
cp "$home/.config/opencode/opencode.jsonc" "$TMP/opencode-before.json"
"$ROOT/adapters/manage.sh" install opencode --home "$home" --state-dir "$state" --adapter-root "$ROOT/adapters" >/dev/null || no "OpenCode install"
"$ROOT/adapters/manage.sh" install opencode --home "$home" --state-dir "$state" --adapter-root "$ROOT/adapters" >/dev/null || no "OpenCode reinstall"
eq "OpenCode AFK plugin once" "$(jq '[.plugin[]|select(endswith("/opencode/plugin.js"))]|length' "$home/.config/opencode/opencode.jsonc")" 1
eq "OpenCode native plugins preserved" "$(jq '[.plugin[]|select(startswith("/native") or contains("/native/"))]|length' "$home/.config/opencode/opencode.jsonc")" 2
"$ROOT/adapters/manage.sh" remove opencode --home "$home" --state-dir "$state" --adapter-root "$ROOT/adapters" >/dev/null || no "OpenCode removal"
if diff -u <(jq -S . "$TMP/opencode-before.json") <(jq -S . "$home/.config/opencode/opencode.jsonc") >/dev/null; then ok; else no "OpenCode exact plugin/settings restoration"; fi

jsonc_home="$TMP/jsonc-home"; jsonc_state="$TMP/jsonc-state"; mkdir -p "$jsonc_home/.config/opencode"
cat >"$jsonc_home/.config/opencode/opencode.jsonc" <<'JSONC'
{
  // owner comment must survive
  "plugin": [
    "@vectorize-io/hindsight-coding-agents",
  ],
  "credentialRef": "env:OPENCODE_TOKEN",
  "apiToken": "DO-NOT-PERSIST",
}
JSONC
cp "$jsonc_home/.config/opencode/opencode.jsonc" "$TMP/jsonc-before.jsonc"
"$ROOT/adapters/manage.sh" install opencode --home "$jsonc_home" --state-dir "$jsonc_state" --adapter-root "$ROOT/adapters" >/dev/null || no "OpenCode JSONC install"
if grep -Fq '// owner comment must survive' "$jsonc_home/.config/opencode/opencode.jsonc" \
  && grep -Fq 'hindsight-coding-agents' "$jsonc_home/.config/opencode/opencode.jsonc" \
  && grep -Fq '/opencode/plugin.js' "$jsonc_home/.config/opencode/opencode.jsonc"; then ok; else no "OpenCode JSONC composition preserves comments and plugins"; fi
"$ROOT/adapters/manage.sh" remove opencode --home "$jsonc_home" --state-dir "$jsonc_state" --adapter-root "$ROOT/adapters" >/dev/null || no "OpenCode JSONC removal"
if cmp "$TMP/jsonc-before.jsonc" "$jsonc_home/.config/opencode/opencode.jsonc" >/dev/null; then ok; else no "OpenCode JSONC exact restoration"; fi
if ! rg -F 'DO-NOT-PERSIST' "$jsonc_state" >/dev/null 2>&1; then ok; else no "adapter state persists no OpenCode credential value"; fi
[[ ! -e "$jsonc_state/adapters/opencode-config-prior" ]] && ok || no "OpenCode install persists no full config snapshot"

# Exact schema-v2 fixtures produced by the 245b6a4 manager must migrate before
# idempotent reinstall/removal. Migration is conservative where v2 did not
# record whether a config existed, and removal preserves all user-owned data.
v2_updater="$ROOT/bin/afk-session-start"
v2_claude_home="$TMP/v2-claude-home"; v2_claude_state="$TMP/v2-claude-state"; mkdir -p "$v2_claude_home/.claude" "$v2_claude_state/adapters"
printf '%s\n' '{"owner":"claude","statusLine":{"type":"command","command":"owner-status","keep":true},"hooks":{"Stop":[]}}' >"$v2_claude_home/.claude/settings.json"
cp "$v2_claude_home/.claude/settings.json" "$TMP/v2-claude-before.json"
jq '{present:has("statusLine"),value:(.statusLine // null),hooks_preexisting:has("hooks"),hook_groups:{SessionStart:((.hooks // {})|has("SessionStart")),PreCompact:((.hooks // {})|has("PreCompact")),UserPromptSubmit:((.hooks // {})|has("UserPromptSubmit"))}}' \
  "$v2_claude_home/.claude/settings.json" >"$v2_claude_state/adapters/claude-prior.json"
jq --arg c "$ROOT/adapters/claude/statusline.sh" --arg u "$v2_updater" \
  --arg p "$ROOT/adapters/worker-context.sh compact --harness claude" \
  --arg i "$ROOT/adapters/worker-context.sh session-start --harness claude" \
  --arg b "$ROOT/adapters/worker-context.sh prompt-boundary --harness claude" '
  .statusLine.command=$c
  | .hooks.SessionStart=((.hooks.SessionStart // [])+[{hooks:[{type:"command",command:$u,timeout:30}]},{matcher:"compact",hooks:[{type:"command",command:$i,timeout:3}]}])
  | .hooks.PreCompact=((.hooks.PreCompact // [])+[{hooks:[{type:"command",command:$p,timeout:3}]}])
  | .hooks.UserPromptSubmit=((.hooks.UserPromptSubmit // [])+[{hooks:[{type:"command",command:$b,timeout:3}]}])' \
  "$v2_claude_home/.claude/settings.json" >"$TMP/v2-claude-installed.json"; mv "$TMP/v2-claude-installed.json" "$v2_claude_home/.claude/settings.json"
jq -nc --arg s "$v2_claude_home/.claude/settings.json" --arg c "$ROOT/adapters/claude/statusline.sh" --arg u "$v2_updater" \
  --arg p "$ROOT/adapters/worker-context.sh compact --harness claude" \
  --arg i "$ROOT/adapters/worker-context.sh session-start --harness claude" \
  --arg b "$ROOT/adapters/worker-context.sh prompt-boundary --harness claude" --arg k "$v2_claude_state/adapters/claude-prior.json" \
  '{schema:"afk-adapter-install/2",harness:"claude",target:$s,command:$c,updater:$u,compact:$p,instruction:$i,prompt:$b,backup:$k}' >"$v2_claude_state/adapters/claude.json"
"$ROOT/adapters/manage.sh" install claude --home "$v2_claude_home" --state-dir "$v2_claude_state" --adapter-root "$ROOT/adapters" >/dev/null || no "schema-v2 Claude reinstall migrates"
eq "schema-v2 Claude record migrated" "$(jq -r .schema "$v2_claude_state/adapters/claude.json")" afk-adapter-install/3
"$ROOT/adapters/manage.sh" remove claude --home "$v2_claude_home" --state-dir "$v2_claude_state" --adapter-root "$ROOT/adapters" >/dev/null || no "schema-v2 Claude removal"
if diff -u <(jq -S . "$TMP/v2-claude-before.json") <(jq -S . "$v2_claude_home/.claude/settings.json") >/dev/null; then ok; else no "schema-v2 Claude preserves user config"; fi

v2_codex_home="$TMP/v2-codex-home"; v2_codex_state="$TMP/v2-codex-state"; mkdir -p "$v2_codex_home/.codex" "$v2_codex_state/adapters"
printf 'owner = "codex"\n\n[tui]\nstatus_line = ["custom", "git-branch"]\n' >"$v2_codex_home/.codex/config.toml"
printf '%s\n' '{"owner":"hooks","hooks":{"Stop":[]}}' >"$v2_codex_home/.codex/hooks.json"
cp "$v2_codex_home/.codex/config.toml" "$TMP/v2-codex-before.toml"; cp "$v2_codex_home/.codex/hooks.json" "$TMP/v2-codex-hooks-before.json"
yq -p=toml -o=json '{"present":(.tui | has("status_line")),"value":(.tui.status_line // null)}' "$v2_codex_home/.codex/config.toml" >"$v2_codex_state/adapters/codex-prior.json"
yq -i -p=toml -o=toml '.tui.status_line = (((.tui.status_line // []) + ["model-with-reasoning","context-used","context-remaining","five-hour-limit","weekly-limit","git-branch","task-progress"]) | unique)' "$v2_codex_home/.codex/config.toml"
jq --arg c "$ROOT/adapters/codex/publish.sh" --arg u "$v2_updater" --arg i "$ROOT/adapters/worker-context.sh session-start --harness codex" '
  .hooks.SessionStart=((.hooks.SessionStart // [])+[{hooks:[{type:"command",command:$u,timeout:30}]},{hooks:[{type:"command",command:$c,timeout:3}]},{matcher:"compact",hooks:[{type:"command",command:$i,timeout:3}]}])
  | .hooks.PreCompact=((.hooks.PreCompact // [])+[{hooks:[{type:"command",command:$c,timeout:3}]}])' \
  "$v2_codex_home/.codex/hooks.json" >"$TMP/v2-codex-installed-hooks.json"; mv "$TMP/v2-codex-installed-hooks.json" "$v2_codex_home/.codex/hooks.json"
v2_codex_installed="$(yq -p=toml -o=json '.tui.status_line' "$v2_codex_home/.codex/config.toml")"
jq -nc --arg c "$ROOT/adapters/codex/publish.sh" --arg u "$v2_updater" --arg x "$ROOT/adapters/worker-context.sh session-start --harness codex" \
  --arg s "$v2_codex_home/.codex/config.toml" --arg b "$v2_codex_state/adapters/codex-prior.json" --arg h "$v2_codex_home/.codex/hooks.json" \
  --argjson i "$v2_codex_installed" '{schema:"afk-adapter-install/2",harness:"codex",target:$s,command:$c,updater:$u,instruction:$x,backup:$b,hooks:$h,hooks_preexisting:true,hook_groups:{SessionStart:false,PreCompact:false},installed:$i}' \
  >"$v2_codex_state/adapters/codex.json"
"$ROOT/adapters/manage.sh" install codex --home "$v2_codex_home" --state-dir "$v2_codex_state" --adapter-root "$ROOT/adapters" >/dev/null || no "schema-v2 Codex reinstall migrates"
eq "schema-v2 Codex record migrated" "$(jq -r .schema "$v2_codex_state/adapters/codex.json")" afk-adapter-install/3
"$ROOT/adapters/manage.sh" remove codex --home "$v2_codex_home" --state-dir "$v2_codex_state" --adapter-root "$ROOT/adapters" >/dev/null || no "schema-v2 Codex removal"
if diff -u <(yq -p=toml -o=json '.' "$TMP/v2-codex-before.toml" | jq -S .) <(yq -p=toml -o=json '.' "$v2_codex_home/.codex/config.toml" | jq -S .) >/dev/null \
  && diff -u <(jq -S . "$TMP/v2-codex-hooks-before.json") <(jq -S . "$v2_codex_home/.codex/hooks.json") >/dev/null; then ok; else no "schema-v2 Codex preserves user config"; fi

v2_open_home="$TMP/v2-open-home"; v2_open_state="$TMP/v2-open-state"; mkdir -p "$v2_open_home/.config/opencode" "$v2_open_state/adapters"
printf '%s\n' '{"owner":"opencode","plugin":["user-plugin"]}' >"$v2_open_home/.config/opencode/opencode.json"
cp "$v2_open_home/.config/opencode/opencode.json" "$TMP/v2-open-before.json"
jq --arg p "file://$ROOT/adapters/opencode/plugin.js" '.plugin += [$p]' "$v2_open_home/.config/opencode/opencode.json" >"$TMP/v2-open-installed.json"; mv "$TMP/v2-open-installed.json" "$v2_open_home/.config/opencode/opencode.json"
jq -nc --arg p "file://$ROOT/adapters/opencode/plugin.js" --arg s "$v2_open_home/.config/opencode/opencode.json" \
  '{schema:"afk-adapter-install/2",harness:"opencode",target:$s,command:$p,prior_plugin_present:true}' >"$v2_open_state/adapters/opencode.json"
"$ROOT/adapters/manage.sh" install opencode --home "$v2_open_home" --state-dir "$v2_open_state" --adapter-root "$ROOT/adapters" >/dev/null || no "schema-v2 OpenCode reinstall migrates"
eq "schema-v2 OpenCode record migrated" "$(jq -r .schema "$v2_open_state/adapters/opencode.json")" afk-adapter-install/3
"$ROOT/adapters/manage.sh" remove opencode --home "$v2_open_home" --state-dir "$v2_open_state" --adapter-root "$ROOT/adapters" >/dev/null || no "schema-v2 OpenCode removal"
if diff -u <(jq -S . "$TMP/v2-open-before.json") <(jq -S . "$v2_open_home/.config/opencode/opencode.json") >/dev/null; then ok; else no "schema-v2 OpenCode preserves user config"; fi

v2_forged_home="$TMP/v2-forged-home"; v2_forged_state="$TMP/v2-forged-state"; mkdir -p "$v2_forged_home/.config/opencode" "$v2_forged_state/adapters"
printf '%s\n' '{"plugin":["user-plugin"]}' >"$v2_forged_home/.config/opencode/opencode.json"
jq -nc --arg p "file://$ROOT/adapters/opencode/plugin.js" --arg s "$v2_forged_home/.config/opencode/opencode.json" \
  '{schema:"afk-adapter-install/2",harness:"opencode",target:$s,command:$p,prior_plugin_present:false,forged:true}' >"$v2_forged_state/adapters/opencode.json"
set +e; "$ROOT/adapters/manage.sh" remove opencode --home "$v2_forged_home" --state-dir "$v2_forged_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; v2_forged_rc=$?; set -e
eq "schema-v2 non-exact shape refuses migration" "$v2_forged_rc" 3
eq "refused schema-v2 migration preserves user plugin" "$(jq -r '.plugin[0]' "$v2_forged_home/.config/opencode/opencode.json")" user-plugin

# Invoke the exact schema-v2 manager revision with relative home, state, and
# installed-runtime adapter paths. The current manager proves canonical path
# equality plus exact command suffixes, then persists only absolute v3 paths.
v2_base_manager="$TMP/manage-245b6a4.sh"
git -C "$ROOT" show 245b6a4:adapters/manage.sh >"$v2_base_manager"; chmod +x "$v2_base_manager"
for relative_harness in claude codex opencode; do
  relative_root="$TMP/v2-relative-$relative_harness"; mkdir -p "$relative_root/relative-home"
  mkdir -p "$relative_root/relative-runtime/bin"
  cp -R "$ROOT/adapters/." "$relative_root/relative-runtime/"
  cp "$ROOT/bin/afk-session-start" "$relative_root/relative-runtime/bin/afk-session-start"
  case "$relative_harness" in
    claude)
      mkdir -p "$relative_root/relative-home/.claude"
      printf '{"owner":"relative-claude"}\n' >"$relative_root/relative-home/.claude/settings.json"
      jq -S . "$relative_root/relative-home/.claude/settings.json" >"$relative_root/before" ;;
    codex)
      mkdir -p "$relative_root/relative-home/.codex"
      printf 'owner = "relative-codex"\n' >"$relative_root/relative-home/.codex/config.toml"
      printf '{"owner":"relative-hooks","hooks":{}}\n' >"$relative_root/relative-home/.codex/hooks.json"
      { yq -p=toml -o=json '.' "$relative_root/relative-home/.codex/config.toml" | jq -S .; jq -S . "$relative_root/relative-home/.codex/hooks.json"; } >"$relative_root/before" ;;
    opencode)
      mkdir -p "$relative_root/relative-home/.config/opencode"
      printf '{"owner":"relative-open","plugin":["user-plugin"]}\n' >"$relative_root/relative-home/.config/opencode/opencode.json"
      jq -S . "$relative_root/relative-home/.config/opencode/opencode.json" >"$relative_root/before" ;;
  esac
  (cd "$relative_root" && "$v2_base_manager" install "$relative_harness" --home relative-home --state-dir relative-state --adapter-root relative-runtime >/dev/null) \
    || no "exact-base relative $relative_harness install"
  (cd "$relative_root" && "$ROOT/adapters/manage.sh" install "$relative_harness" --home relative-home --state-dir relative-state --adapter-root relative-runtime >/dev/null) \
    || no "exact-base relative $relative_harness migration"
  relative_record="$relative_root/relative-state/adapters/$relative_harness.json"
  if jq -e '.schema=="afk-adapter-install/3" and (.target|startswith("/"))
      and ((.backup // "/")|startswith("/")) and ((.hooks // "/")|startswith("/"))
      and ([.command,.updater?,.compact?,.instruction?,.prompt?]
        | all(. == null or startswith("/") or startswith("file:///")))' "$relative_record" >/dev/null; then
    ok
  else
    no "exact-base relative $relative_harness record was not rewritten absolute"
  fi
  (cd "$relative_root" && "$ROOT/adapters/manage.sh" remove "$relative_harness" --home relative-home --state-dir relative-state --adapter-root relative-runtime >/dev/null) \
    || no "exact-base relative $relative_harness removal"
  case "$relative_harness" in
    claude) jq -S . "$relative_root/relative-home/.claude/settings.json" >"$relative_root/after" ;;
    codex) { yq -p=toml -o=json '.' "$relative_root/relative-home/.codex/config.toml" | jq -S .; jq -S . "$relative_root/relative-home/.codex/hooks.json"; } >"$relative_root/after" ;;
    opencode) jq -S . "$relative_root/relative-home/.config/opencode/opencode.json" >"$relative_root/after" ;;
  esac
  if cmp "$relative_root/before" "$relative_root/after" >/dev/null; then ok; else no "exact-base relative $relative_harness preserves user config"; fi
done

# A v2 migration journals both live identities before its one user-file rename.
# Interpose only that rename, stop the manager after /usr/bin/mv has completed,
# and deliver a real SIGKILL before the shell can finalize the record.
v2_crash_bin="$TMP/v2-crash-bin"; mkdir -p "$v2_crash_bin"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
  '/usr/bin/mv "$@"; rc=$?; (( rc == 0 )) || exit "$rc"' \
  'target="${!#}"' \
  'if [[ "$target" == "$AFK_V2_CRASH_TARGET" ]]; then : >"$AFK_V2_CRASH_MARKER"; kill -STOP "$PPID"; fi' \
  'exit 0' >"$v2_crash_bin/mv"; chmod +x "$v2_crash_bin/mv"
snapshot_relative_v2_fixture() { # root harness
  case "$2" in
    claude) jq -S . "$1/home/.claude/settings.json" ;;
    codex) { yq -p=toml -o=json '.' "$1/home/.codex/config.toml" | jq -S .; jq -S . "$1/home/.codex/hooks.json"; } ;;
    opencode) jq -S . "$1/home/.config/opencode/opencode.json" ;;
  esac
}
prepare_relative_v2_fixture() { # root harness
  local fixture="$1" harness="$2"
  mkdir -p "$fixture/home" "$fixture/state" "$fixture/relative-runtime/bin" "$fixture/origin"
  cp -R "$ROOT/adapters/." "$fixture/relative-runtime/"
  cp "$ROOT/bin/afk-session-start" "$fixture/relative-runtime/bin/afk-session-start"
  ln -s ../home "$fixture/origin/home"
  ln -s ../state "$fixture/origin/state"
  ln -s ../relative-runtime "$fixture/origin/relative-runtime"
  case "$harness" in
    claude)
      mkdir -p "$fixture/home/.claude"
      printf '{"owner":"crash-claude"}\n' >"$fixture/home/.claude/settings.json" ;;
    codex)
      mkdir -p "$fixture/home/.codex"
      printf 'owner = "crash-codex"\n' >"$fixture/home/.codex/config.toml"
      printf '{"owner":"crash-hooks","hooks":{}}\n' >"$fixture/home/.codex/hooks.json" ;;
    opencode)
      mkdir -p "$fixture/home/.config/opencode"
      printf '{"owner":"crash-open","plugin":["user-plugin"]}\n' >"$fixture/home/.config/opencode/opencode.json" ;;
  esac
  snapshot_relative_v2_fixture "$fixture" "$harness" >"$fixture/before"
  (cd "$fixture/origin" && "$v2_base_manager" install "$harness" --home home --state-dir state --adapter-root relative-runtime >/dev/null)
}
for crash_harness in claude codex opencode; do
  crash_root="$TMP/v2-crash-$crash_harness"; prepare_relative_v2_fixture "$crash_root" "$crash_harness"
  case "$crash_harness" in
    claude) crash_target="$crash_root/home/.claude/settings.json" ;;
    codex) crash_target="$crash_root/home/.codex/hooks.json" ;;
    opencode) crash_target="$crash_root/home/.config/opencode/opencode.json" ;;
  esac
  crash_marker="$crash_root/live-mv-complete"
  (cd "$crash_root/origin" && exec env PATH="$v2_crash_bin:$PATH" AFK_V2_CRASH_TARGET="$crash_target" AFK_V2_CRASH_MARKER="$crash_marker" \
    "$ROOT/adapters/manage.sh" install "$crash_harness" --home "$crash_root/home" --state-dir "$crash_root/state" \
      --adapter-root "$crash_root/relative-runtime" >/dev/null 2>&1) & crash_pid=$!
  for _ in $(seq 1 500); do [[ -e "$crash_marker" ]] && break; /bin/sleep 0.01; done
  [[ -e "$crash_marker" ]] && ok || no "exact-base relative $crash_harness reached live migration rename"
  kill -9 "$crash_pid" 2>/dev/null || true
  set +e; wait "$crash_pid" 2>/dev/null; set -e
  rm -f -- "$crash_root/origin/home" "$crash_root/origin/state" "$crash_root/origin/relative-runtime"
  rmdir -- "$crash_root/origin"
  [[ ! -e "$crash_root/origin" ]] && ok || no "exact-base relative $crash_harness origin cwd was removed"
  crash_record="$crash_root/state/adapters/$crash_harness.json"
  crash_guard="$(jq -r .migration.live.guard "$crash_record")"
  if jq -e '.phase=="migrating-v2" and .migration.schema=="afk-adapter-migration/1"
      and (.migration|has("origin_cwd")|not)
      and all(.migration.canonical[]; startswith("/") or startswith("file:///"))' "$crash_record" >/dev/null \
    && [[ "$(sha256sum "$crash_target" | cut -d' ' -f1)" == "$(jq -r .migration.live.new_sha256 "$crash_record")" \
      && "$(sha256sum "$crash_guard" | cut -d' ' -f1)" == "$(jq -r .migration.live.old_sha256 "$crash_record")" ]]; then
    ok
  else
    no "exact-base relative $crash_harness SIGKILL retains exact new identity journal"
  fi
  (cd "$TMP" && "$ROOT/adapters/manage.sh" install "$crash_harness" \
    --home "$crash_root/home" --state-dir "$crash_root/state" --adapter-root "$crash_root/relative-runtime" >/dev/null) \
    || no "exact-base relative $crash_harness migration recovers after origin cwd removal"
  jq -e '.schema=="afk-adapter-install/3" and .phase=="active" and (has("migration")|not)' "$crash_record" >/dev/null \
    && ok || no "exact-base relative $crash_harness recovery finalizes migration journal"
  (cd "$TMP" && "$ROOT/adapters/manage.sh" remove "$crash_harness" \
    --home "$crash_root/home" --state-dir "$crash_root/state" --adapter-root "$crash_root/relative-runtime" >/dev/null) \
    || no "exact-base relative $crash_harness recovered removal"
  snapshot_relative_v2_fixture "$crash_root" "$crash_harness" >"$crash_root/after"
  cmp "$crash_root/before" "$crash_root/after" >/dev/null && ok || no "exact-base relative $crash_harness SIGKILL recovery preserves user config"
done

# The cleanup handoff is itself journaled under one stable path. Stop after the
# old config moves there but before removal, then prove every harness resumes
# that exact cleanup instead of orphaning an unjournaled random file.
v2_cleanup_bin="$TMP/v2-cleanup-bin"; mkdir -p "$v2_cleanup_bin"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
  'source_path="${@: -2:1}"' \
  'source_inode="$(/usr/bin/stat -Lc "%d:%i" "$source_path")" || exit' \
  '/usr/bin/mv "$@"; rc=$?; (( rc == 0 )) || exit "$rc"' \
  'destination="${!#}"' \
  'if [[ "$destination" == "$AFK_V2_CLEANUP_PATH" ]]; then' \
  '  destination_inode="$(/usr/bin/stat -Lc "%d:%i" "$destination")" || exit' \
  '  printf "%s %s\n" "$source_inode" "$destination_inode" >"$AFK_V2_CLEANUP_MARKER"' \
  '  kill -STOP "$PPID"' \
  'fi' \
  'exit 0' >"$v2_cleanup_bin/mv"; chmod +x "$v2_cleanup_bin/mv"
for cleanup_harness in claude codex opencode; do
  cleanup_root="$TMP/v2-cleanup-$cleanup_harness"; prepare_relative_v2_fixture "$cleanup_root" "$cleanup_harness"
  case "$cleanup_harness" in
    claude) cleanup_target="$cleanup_root/home/.claude/settings.json" ;;
    codex) cleanup_target="$cleanup_root/home/.codex/hooks.json" ;;
    opencode) cleanup_target="$cleanup_root/home/.config/opencode/opencode.json" ;;
  esac
  cleanup_old_hash="$(sha256sum "$cleanup_target" | cut -d' ' -f1)"
  cleanup_guard="${cleanup_target}.afk-v2-guard.${cleanup_old_hash}"
  cleanup_path="${cleanup_guard}.cleanup"
  cleanup_tombstone="$cleanup_root/state/adapters/.v2-migration-$cleanup_harness-${cleanup_old_hash}.tombstone"
  cleanup_marker="$cleanup_root/cleanup-mv-complete"
  (cd "$cleanup_root" && exec env PATH="$v2_cleanup_bin:$PATH" AFK_V2_CLEANUP_PATH="$cleanup_path" \
    AFK_V2_CLEANUP_MARKER="$cleanup_marker" "$ROOT/adapters/manage.sh" install "$cleanup_harness" \
    --home home --state-dir state --adapter-root relative-runtime >/dev/null 2>&1) & cleanup_pid=$!
  for _ in $(seq 1 500); do [[ -e "$cleanup_marker" ]] && break; /bin/sleep 0.01; done
  [[ -e "$cleanup_marker" ]] && ok || no "schema-v2 $cleanup_harness reached journaled cleanup move"
  kill -9 "$cleanup_pid" 2>/dev/null || true
  set +e; wait "$cleanup_pid" 2>/dev/null; set -e
  cleanup_record="$cleanup_root/state/adapters/$cleanup_harness.json"
  if jq -e --arg p "$cleanup_path" --arg t "$cleanup_tombstone" '
      .phase=="migrating-v2" and .migration.stage=="cleanup"
      and .migration.live.cleanup==$p and .migration.live.tombstone==$t' "$cleanup_record" >/dev/null \
    && [[ ! -e "$cleanup_guard" && ! -L "$cleanup_guard" \
      && ! -e "$cleanup_tombstone" && ! -L "$cleanup_tombstone" \
      && "$(sha256sum "$cleanup_path" | cut -d' ' -f1)" == "$cleanup_old_hash" ]]; then
    ok
  else
    no "schema-v2 $cleanup_harness SIGKILL retains journaled old config cleanup"
  fi
  (cd "$TMP" && "$ROOT/adapters/manage.sh" install "$cleanup_harness" \
    --home "$cleanup_root/home" --state-dir "$cleanup_root/state" --adapter-root "$cleanup_root/relative-runtime" >/dev/null) \
    || no "schema-v2 $cleanup_harness resumes journaled cleanup"
  if [[ ! -e "$cleanup_guard" && ! -L "$cleanup_guard" && ! -e "$cleanup_path" && ! -L "$cleanup_path" \
      && ! -e "$cleanup_tombstone" && ! -L "$cleanup_tombstone" \
      && -z "$(find "$(dirname "$cleanup_target")" -maxdepth 1 -name "$(basename "$cleanup_target").afk-v2-guard.*" -print -quit)" ]] \
    && jq -e '.phase=="active" and (has("migration")|not)' "$cleanup_record" >/dev/null; then
    ok
  else
    no "schema-v2 $cleanup_harness leaves no orphan after cleanup recovery"
  fi
  (cd "$TMP" && "$ROOT/adapters/manage.sh" remove "$cleanup_harness" \
    --home "$cleanup_root/home" --state-dir "$cleanup_root/state" --adapter-root "$cleanup_root/relative-runtime" >/dev/null) \
    || no "schema-v2 $cleanup_harness cleanup-boundary removal"
  snapshot_relative_v2_fixture "$cleanup_root" "$cleanup_harness" >"$cleanup_root/after"
  cmp "$cleanup_root/before" "$cleanup_root/after" >/dev/null && ok || no "schema-v2 $cleanup_harness cleanup recovery preserves user config"
done

# A second interruption boundary covers the private tombstone itself. Once the
# verified public cleanup inode has moved there, a killed manager must leave one
# journal-addressable identity that a later run can prove and finish deleting.
for tombstone_harness in claude codex opencode; do
  tombstone_root="$TMP/v2-tombstone-$tombstone_harness"; prepare_relative_v2_fixture "$tombstone_root" "$tombstone_harness"
  case "$tombstone_harness" in
    claude) tombstone_target="$tombstone_root/home/.claude/settings.json" ;;
    codex) tombstone_target="$tombstone_root/home/.codex/hooks.json" ;;
    opencode) tombstone_target="$tombstone_root/home/.config/opencode/opencode.json" ;;
  esac
  tombstone_old_hash="$(sha256sum "$tombstone_target" | cut -d' ' -f1)"
  tombstone_guard="${tombstone_target}.afk-v2-guard.${tombstone_old_hash}"
  tombstone_cleanup="${tombstone_guard}.cleanup"
  tombstone_path="$tombstone_root/state/adapters/.v2-migration-$tombstone_harness-${tombstone_old_hash}.tombstone"
  tombstone_marker="$tombstone_root/tombstone-mv-complete"
  (cd "$tombstone_root" && exec env PATH="$v2_cleanup_bin:$PATH" AFK_V2_CLEANUP_PATH="$tombstone_path" \
    AFK_V2_CLEANUP_MARKER="$tombstone_marker" "$ROOT/adapters/manage.sh" install "$tombstone_harness" \
    --home home --state-dir state --adapter-root relative-runtime >/dev/null 2>&1) & tombstone_pid=$!
  for _ in $(seq 1 500); do [[ -e "$tombstone_marker" ]] && break; /bin/sleep 0.01; done
  [[ -e "$tombstone_marker" ]] && ok || no "schema-v2 $tombstone_harness reached private tombstone move"
  kill -9 "$tombstone_pid" 2>/dev/null || true
  set +e; wait "$tombstone_pid" 2>/dev/null; set -e
  tombstone_record="$tombstone_root/state/adapters/$tombstone_harness.json"
  read -r tombstone_source_inode tombstone_destination_inode <"$tombstone_marker"
  eq "schema-v2 $tombstone_harness private tombstone preserves inode" \
    "$tombstone_destination_inode" "$tombstone_source_inode"
  if jq -e --arg t "$tombstone_path" '.phase=="migrating-v2" and .migration.stage=="cleanup"
      and .migration.live.tombstone==$t' "$tombstone_record" >/dev/null \
    && [[ ! -e "$tombstone_guard" && ! -L "$tombstone_guard" \
      && ! -e "$tombstone_cleanup" && ! -L "$tombstone_cleanup" \
      && "$(sha256sum "$tombstone_path" | cut -d' ' -f1)" == "$tombstone_old_hash" ]]; then
    ok
  else
    no "schema-v2 $tombstone_harness SIGKILL retains verified private tombstone"
  fi
  (cd "$TMP" && "$ROOT/adapters/manage.sh" install "$tombstone_harness" \
    --home "$tombstone_root/home" --state-dir "$tombstone_root/state" \
    --adapter-root "$tombstone_root/relative-runtime" >/dev/null) \
    || no "schema-v2 $tombstone_harness resumes private tombstone cleanup"
  if [[ ! -e "$tombstone_guard" && ! -L "$tombstone_guard" \
      && ! -e "$tombstone_cleanup" && ! -L "$tombstone_cleanup" \
      && ! -e "$tombstone_path" && ! -L "$tombstone_path" ]] \
    && jq -e '.phase=="active" and (has("migration")|not)' "$tombstone_record" >/dev/null; then
    ok
  else
    no "schema-v2 $tombstone_harness finalizes private tombstone recovery"
  fi
  (cd "$TMP" && "$ROOT/adapters/manage.sh" remove "$tombstone_harness" \
    --home "$tombstone_root/home" --state-dir "$tombstone_root/state" \
    --adapter-root "$tombstone_root/relative-runtime" >/dev/null) \
    || no "schema-v2 $tombstone_harness private tombstone recovery removal"
  snapshot_relative_v2_fixture "$tombstone_root" "$tombstone_harness" >"$tombstone_root/after"
  cmp "$tombstone_root/before" "$tombstone_root/after" >/dev/null \
    && ok || no "schema-v2 $tombstone_harness private tombstone recovery preserves user config"
done

# Replace the public cleanup identity inside the cleanup-to-tombstone move,
# after the manager's final pre-move proof. The manager must move the refill
# back out of private state without clobbering, then refuse with both identities
# and the migration journal preserved.
v2_move_refill_bin="$TMP/v2-move-refill-bin"; mkdir -p "$v2_move_refill_bin"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
  'source_path="${@: -2:1}"; destination="${!#}"' \
  'if [[ "$source_path" == "$AFK_V2_REFILL_PATH" && "$destination" == "$AFK_V2_TOMBSTONE" && ! -e "$AFK_V2_REFILL_MARKER" ]]; then' \
  '  /usr/bin/mv -- "$source_path" "$AFK_V2_ORIGINAL_SIDE" || exit' \
  '  /bin/cp -- "$AFK_V2_REFILL_SOURCE" "$source_path" || exit' \
  '  : >"$AFK_V2_REFILL_MARKER"' \
  'fi' \
  '/usr/bin/mv "$@"' >"$v2_move_refill_bin/mv"; chmod +x "$v2_move_refill_bin/mv"
for move_refill_harness in claude codex opencode; do
  move_refill_root="$TMP/v2-move-refill-$move_refill_harness"
  prepare_relative_v2_fixture "$move_refill_root" "$move_refill_harness"
  case "$move_refill_harness" in
    claude) move_refill_target="$move_refill_root/home/.claude/settings.json" ;;
    codex) move_refill_target="$move_refill_root/home/.codex/hooks.json" ;;
    opencode) move_refill_target="$move_refill_root/home/.config/opencode/opencode.json" ;;
  esac
  move_refill_old_hash="$(sha256sum "$move_refill_target" | cut -d' ' -f1)"
  move_refill_guard="${move_refill_target}.afk-v2-guard.${move_refill_old_hash}"
  move_refill_path="${move_refill_guard}.cleanup"
  move_refill_tombstone="$move_refill_root/state/adapters/.v2-migration-$move_refill_harness-${move_refill_old_hash}.tombstone"
  move_refill_source="$move_refill_root/concurrent-refill"
  move_refill_original="$move_refill_root/verified-original"
  move_refill_marker="$move_refill_root/concurrent-refill-moved"
  printf 'concurrent move refill for %s\n' "$move_refill_harness" >"$move_refill_source"
  set +e
  (cd "$move_refill_root" && env PATH="$v2_move_refill_bin:$PATH" \
    AFK_V2_REFILL_PATH="$move_refill_path" AFK_V2_TOMBSTONE="$move_refill_tombstone" \
    AFK_V2_REFILL_SOURCE="$move_refill_source" AFK_V2_ORIGINAL_SIDE="$move_refill_original" \
    AFK_V2_REFILL_MARKER="$move_refill_marker" "$ROOT/adapters/manage.sh" install "$move_refill_harness" \
      --home home --state-dir state --adapter-root relative-runtime >/dev/null 2>"$move_refill_root/error")
  move_refill_rc=$?
  set -e
  eq "schema-v2 $move_refill_harness move refill refuses finalization" "$move_refill_rc" 3
  grep -Fxq 'adapter-manager: RECOVERY_VERIFICATION_FAILED' "$move_refill_root/error" \
    && ok || no "schema-v2 $move_refill_harness move refill reports recovery refusal"
  [[ -e "$move_refill_marker" ]] && ok \
    || no "schema-v2 $move_refill_harness move refill reached cleanup-to-tombstone boundary"
  [[ -f "$move_refill_path" && ! -L "$move_refill_path" ]] \
    && cmp "$move_refill_source" "$move_refill_path" >/dev/null \
    && ok || no "schema-v2 $move_refill_harness move refill returns to public cleanup path"
  [[ ! -e "$move_refill_tombstone" && ! -L "$move_refill_tombstone" ]] \
    && ok || no "schema-v2 $move_refill_harness move refill is not stranded in private tombstone"
  [[ -f "$move_refill_original" && ! -L "$move_refill_original" \
    && "$(sha256sum "$move_refill_original" | cut -d' ' -f1)" == "$move_refill_old_hash" ]] \
    && ok || no "schema-v2 $move_refill_harness move refill preserves verified original identity"
  move_refill_record="$move_refill_root/state/adapters/$move_refill_harness.json"
  if jq -e --arg p "$move_refill_path" --arg t "$move_refill_tombstone" '
      .phase=="migrating-v2" and .migration.stage=="cleanup"
      and .migration.live.cleanup==$p and .migration.live.tombstone==$t
      and all(.migration.canonical[]; startswith("/") or startswith("file:///"))' \
      "$move_refill_record" >/dev/null; then
    ok
  else
    no "schema-v2 $move_refill_harness move refill retains canonical migration evidence"
  fi
done

# Kill recovery after a concurrent refill has crossed the cleanup-to-tombstone
# rename but before the in-process mismatch path can return it. The next run
# must recognize that non-old tombstone identity, restore it to the absent
# public path without clobbering, and refuse with the journal retained.
v2_move_refill_crash_bin="$TMP/v2-move-refill-crash-bin"; mkdir -p "$v2_move_refill_crash_bin"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
  'source_path="${@: -2:1}"; destination="${!#}"' \
  'if [[ "$source_path" == "$AFK_V2_REFILL_PATH" && "$destination" == "$AFK_V2_TOMBSTONE" && ! -e "$AFK_V2_REFILL_MARKER" ]]; then' \
  '  /usr/bin/mv -- "$source_path" "$AFK_V2_ORIGINAL_SIDE" || exit' \
  '  /bin/cp -- "$AFK_V2_REFILL_SOURCE" "$source_path" || exit' \
  '  /usr/bin/mv "$@"; rc=$?; (( rc == 0 )) || exit "$rc"' \
  '  /usr/bin/stat -Lc "%d:%i" "$destination" >"$AFK_V2_REFILL_MARKER" || exit' \
  '  kill -STOP "$PPID"' \
  '  exit 0' \
  'fi' \
  '/usr/bin/mv "$@"' >"$v2_move_refill_crash_bin/mv"; chmod +x "$v2_move_refill_crash_bin/mv"
for refill_crash_harness in claude codex opencode; do
  refill_crash_root="$TMP/v2-move-refill-crash-$refill_crash_harness"
  prepare_relative_v2_fixture "$refill_crash_root" "$refill_crash_harness"
  case "$refill_crash_harness" in
    claude) refill_crash_target="$refill_crash_root/home/.claude/settings.json" ;;
    codex) refill_crash_target="$refill_crash_root/home/.codex/hooks.json" ;;
    opencode) refill_crash_target="$refill_crash_root/home/.config/opencode/opencode.json" ;;
  esac
  refill_crash_old_hash="$(sha256sum "$refill_crash_target" | cut -d' ' -f1)"
  refill_crash_guard="${refill_crash_target}.afk-v2-guard.${refill_crash_old_hash}"
  refill_crash_path="${refill_crash_guard}.cleanup"
  refill_crash_tombstone="$refill_crash_root/state/adapters/.v2-migration-$refill_crash_harness-${refill_crash_old_hash}.tombstone"
  refill_crash_source="$refill_crash_root/concurrent-refill"
  refill_crash_original="$refill_crash_root/verified-original"
  refill_crash_marker="$refill_crash_root/refill-tombstone-moved"
  printf 'crash-boundary refill for %s\n' "$refill_crash_harness" >"$refill_crash_source"
  (cd "$refill_crash_root" && exec env PATH="$v2_move_refill_crash_bin:$PATH" \
    AFK_V2_REFILL_PATH="$refill_crash_path" AFK_V2_TOMBSTONE="$refill_crash_tombstone" \
    AFK_V2_REFILL_SOURCE="$refill_crash_source" AFK_V2_ORIGINAL_SIDE="$refill_crash_original" \
    AFK_V2_REFILL_MARKER="$refill_crash_marker" "$ROOT/adapters/manage.sh" install "$refill_crash_harness" \
      --home home --state-dir state --adapter-root relative-runtime >/dev/null 2>&1) & refill_crash_pid=$!
  for _ in $(seq 1 500); do [[ -e "$refill_crash_marker" ]] && break; /bin/sleep 0.01; done
  [[ -e "$refill_crash_marker" ]] && ok \
    || no "schema-v2 $refill_crash_harness reached refill tombstone crash boundary"
  kill -9 "$refill_crash_pid" 2>/dev/null || true
  set +e; wait "$refill_crash_pid" 2>/dev/null; set -e
  [[ ! -e "$refill_crash_path" && ! -L "$refill_crash_path" \
    && -f "$refill_crash_tombstone" && ! -L "$refill_crash_tombstone" ]] \
    && cmp "$refill_crash_source" "$refill_crash_tombstone" >/dev/null \
    && ok || no "schema-v2 $refill_crash_harness SIGKILL retains refill in private tombstone"
  set +e
  (cd "$TMP" && "$ROOT/adapters/manage.sh" install "$refill_crash_harness" \
    --home "$refill_crash_root/home" --state-dir "$refill_crash_root/state" \
    --adapter-root "$refill_crash_root/relative-runtime" >/dev/null 2>"$refill_crash_root/retry-error")
  refill_crash_rc=$?
  set -e
  eq "schema-v2 $refill_crash_harness refill tombstone retry refuses finalization" "$refill_crash_rc" 3
  grep -Fxq 'adapter-manager: RECOVERY_VERIFICATION_FAILED' "$refill_crash_root/retry-error" \
    && ok || no "schema-v2 $refill_crash_harness refill tombstone retry reports recovery refusal"
  [[ -f "$refill_crash_path" && ! -L "$refill_crash_path" ]] \
    && cmp "$refill_crash_source" "$refill_crash_path" >/dev/null \
    && ok || no "schema-v2 $refill_crash_harness refill tombstone retry restores public bytes"
  eq "schema-v2 $refill_crash_harness refill tombstone retry preserves inode" \
    "$(stat -Lc '%d:%i' "$refill_crash_path")" "$(cat "$refill_crash_marker")"
  [[ ! -e "$refill_crash_tombstone" && ! -L "$refill_crash_tombstone" ]] \
    && ok || no "schema-v2 $refill_crash_harness refill tombstone retry leaves no private strand"
  [[ -f "$refill_crash_original" && ! -L "$refill_crash_original" \
    && "$(sha256sum "$refill_crash_original" | cut -d' ' -f1)" == "$refill_crash_old_hash" ]] \
    && ok || no "schema-v2 $refill_crash_harness refill tombstone retry preserves old identity"
  refill_crash_record="$refill_crash_root/state/adapters/$refill_crash_harness.json"
  if jq -e --arg p "$refill_crash_path" --arg t "$refill_crash_tombstone" '
      .phase=="migrating-v2" and .migration.stage=="cleanup"
      and .migration.live.cleanup==$p and .migration.live.tombstone==$t
      and all(.migration.canonical[]; startswith("/") or startswith("file:///"))' \
      "$refill_crash_record" >/dev/null; then
    ok
  else
    no "schema-v2 $refill_crash_harness refill tombstone retry retains migration evidence"
  fi
done

# Refill the public cleanup path only after the manager has moved its verified
# inode to the private tombstone and completed the post-move inode+digest proof.
# The unlink may remove only that tombstone; every concurrent refill survives
# and keeps the migration journal open for owner action.
v2_cleanup_refill_bin="$TMP/v2-cleanup-refill-bin"; mkdir -p "$v2_cleanup_refill_bin"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
  'target="${!#}"' \
  'if [[ "$target" == "$AFK_V2_TOMBSTONE" && ! -e "$AFK_V2_REFILL_MARKER" ]]; then' \
  '  /bin/cp -- "$AFK_V2_REFILL_SOURCE" "$AFK_V2_REFILL_PATH" || exit' \
  '  : >"$AFK_V2_REFILL_MARKER"' \
  'fi' \
  '/bin/rm "$@"' >"$v2_cleanup_refill_bin/rm"; chmod +x "$v2_cleanup_refill_bin/rm"
for refill_harness in claude codex opencode; do
  refill_root="$TMP/v2-cleanup-refill-$refill_harness"; prepare_relative_v2_fixture "$refill_root" "$refill_harness"
  case "$refill_harness" in
    claude) refill_target="$refill_root/home/.claude/settings.json" ;;
    codex) refill_target="$refill_root/home/.codex/hooks.json" ;;
    opencode) refill_target="$refill_root/home/.config/opencode/opencode.json" ;;
  esac
  refill_old_hash="$(sha256sum "$refill_target" | cut -d' ' -f1)"
  refill_guard="${refill_target}.afk-v2-guard.${refill_old_hash}"
  refill_path="${refill_guard}.cleanup"
  refill_tombstone="$refill_root/state/adapters/.v2-migration-$refill_harness-${refill_old_hash}.tombstone"
  refill_source="$refill_root/concurrent-refill"; refill_marker="$refill_root/concurrent-refill-installed"
  printf 'concurrent cleanup refill for %s\n' "$refill_harness" >"$refill_source"
  set +e
  (cd "$refill_root" && env PATH="$v2_cleanup_refill_bin:$PATH" \
    AFK_V2_TOMBSTONE="$refill_tombstone" AFK_V2_REFILL_PATH="$refill_path" \
    AFK_V2_REFILL_SOURCE="$refill_source" AFK_V2_REFILL_MARKER="$refill_marker" \
    "$ROOT/adapters/manage.sh" install "$refill_harness" \
      --home home --state-dir state --adapter-root relative-runtime >/dev/null 2>"$refill_root/error")
  refill_rc=$?
  set -e
  eq "schema-v2 $refill_harness cleanup refill refuses finalization" "$refill_rc" 3
  grep -Fxq 'adapter-manager: RECOVERY_VERIFICATION_FAILED' "$refill_root/error" \
    && ok || no "schema-v2 $refill_harness cleanup refill reports recovery refusal"
  [[ -e "$refill_marker" ]] && ok || no "schema-v2 $refill_harness cleanup refill reached pre-unlink boundary"
  [[ -f "$refill_path" && ! -L "$refill_path" ]] && cmp "$refill_source" "$refill_path" >/dev/null \
    && ok || no "schema-v2 $refill_harness concurrent cleanup refill survives"
  [[ ! -e "$refill_tombstone" && ! -L "$refill_tombstone" ]] \
    && ok || no "schema-v2 $refill_harness removes only the verified private tombstone"
  refill_record="$refill_root/state/adapters/$refill_harness.json"
  if jq -e --arg p "$refill_path" --arg t "$refill_tombstone" '
      .phase=="migrating-v2" and .migration.stage=="cleanup"
      and .migration.live.cleanup==$p and .migration.live.tombstone==$t
      and all(.migration.canonical[]; startswith("/") or startswith("file:///"))' \
      "$refill_record" >/dev/null; then
    ok
  else
    no "schema-v2 $refill_harness cleanup refill retains canonical migration evidence"
  fi
done

# Change the live file in the last instant before the guarded old-to-side move.
# Recovery must detect the changed bytes after the move, restore them without
# overwriting anything, and retain the migration journal for inspection.
v2_boundary_bin="$TMP/v2-boundary-bin"; mkdir -p "$v2_boundary_bin"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
  'source_path="${@: -2:1}"; destination="${!#}"' \
  'if [[ "$source_path" == "$AFK_V2_EDIT_TARGET" && "$destination" == "$AFK_V2_EDIT_GUARD" && ! -e "$AFK_V2_EDIT_MARKER" ]]; then' \
  '  /usr/bin/jq '\'' .owner="boundary-drift" '\'' "$source_path" >"$source_path.afk-user-edit" || exit' \
  '  /usr/bin/mv "$source_path.afk-user-edit" "$source_path" || exit' \
  '  : >"$AFK_V2_EDIT_MARKER"' \
  'fi' \
  '/usr/bin/mv "$@"' >"$v2_boundary_bin/mv"; chmod +x "$v2_boundary_bin/mv"
boundary_root="$TMP/v2-boundary-edit"; prepare_relative_v2_fixture "$boundary_root" claude
boundary_target="$boundary_root/home/.claude/settings.json"
boundary_old_hash="$(sha256sum "$boundary_target" | cut -d' ' -f1)"
boundary_guard="${boundary_target}.afk-v2-guard.${boundary_old_hash}"
boundary_marker="$boundary_root/edit-complete"
set +e
(cd "$boundary_root" && env PATH="$v2_boundary_bin:$PATH" AFK_V2_EDIT_TARGET="$boundary_target" \
  AFK_V2_EDIT_GUARD="$boundary_guard" AFK_V2_EDIT_MARKER="$boundary_marker" \
  "$ROOT/adapters/manage.sh" install claude --home home --state-dir state --adapter-root relative-runtime >/dev/null 2>&1)
boundary_rc=$?
set -e
eq "schema-v2 boundary edit refuses recovery" "$boundary_rc" 3
[[ -e "$boundary_marker" ]] && ok || no "schema-v2 boundary edit ran at guarded replacement"
jq -e '.owner=="boundary-drift"' "$boundary_target" >/dev/null && ok || no "schema-v2 boundary edit preserves user bytes"
[[ ! -e "$boundary_guard" && ! -L "$boundary_guard" ]] && ok || no "schema-v2 boundary edit restores drift from guard"
jq -e '.phase=="migrating-v2" and .migration.schema=="afk-adapter-migration/1"' \
  "$boundary_root/state/adapters/claude.json" >/dev/null && ok || no "schema-v2 boundary edit retains journal"

# Codex status-line entries are user-facing data rather than executable fields;
# escaped newlines remain valid while hook and path values stay control-checked.
codex_status_root="$TMP/v2-codex-escaped-status"; prepare_relative_v2_fixture "$codex_status_root" codex
codex_status_config="$codex_status_root/home/.codex/config.toml"
codex_status_record="$codex_status_root/state/adapters/codex.json"
yq -i -p=toml -o=toml '.tui.status_line += ["custom\nstatus"]' "$codex_status_config"
jq '.installed += ["custom\nstatus"]' "$codex_status_record" >"$codex_status_root/record"; mv "$codex_status_root/record" "$codex_status_record"
(cd "$codex_status_root" && "$ROOT/adapters/manage.sh" install codex --home home --state-dir state --adapter-root relative-runtime >/dev/null) \
  || no "schema-v2 Codex escaped-newline status migrates"
jq -e '.schema=="afk-adapter-install/3" and .phase=="active" and (.installed|index("custom\nstatus")!=null)' \
  "$codex_status_record" >/dev/null && ok || no "schema-v2 Codex escaped-newline status is preserved as data"
(cd "$codex_status_root" && "$ROOT/adapters/manage.sh" remove codex --home home --state-dir state --adapter-root relative-runtime >/dev/null) \
  || no "schema-v2 Codex escaped-newline status removal"
snapshot_relative_v2_fixture "$codex_status_root" codex >"$codex_status_root/after"
cmp "$codex_status_root/before" "$codex_status_root/after" >/dev/null && ok || no "schema-v2 Codex escaped-newline status restores prior config"

# A journal authorizes exactly its old or new live identity. Once a third
# identity appears, recovery refuses without finalizing, rolling back, or
# rewriting either the user's drift or the retained migration evidence.
drift_root="$TMP/v2-migration-drift"; prepare_relative_v2_fixture "$drift_root" claude
drift_target="$drift_root/home/.claude/settings.json"; drift_marker="$drift_root/live-mv-complete"
(cd "$drift_root" && exec env PATH="$v2_crash_bin:$PATH" AFK_V2_CRASH_TARGET="$drift_target" AFK_V2_CRASH_MARKER="$drift_marker" \
  "$ROOT/adapters/manage.sh" install claude --home home --state-dir state --adapter-root relative-runtime >/dev/null 2>&1) & drift_pid=$!
for _ in $(seq 1 500); do [[ -e "$drift_marker" ]] && break; /bin/sleep 0.01; done
[[ -e "$drift_marker" ]] && ok || no "migration drift fixture reached live rename"
kill -9 "$drift_pid" 2>/dev/null || true
set +e; wait "$drift_pid" 2>/dev/null; set -e
drift_record="$drift_root/state/adapters/claude.json"; drift_prior="$drift_root/state/adapters/claude-prior.json"
jq '.owner="independent-drift"' "$drift_target" >"$drift_root/drifted"; mv "$drift_root/drifted" "$drift_target"
drift_target_hash="$(sha256sum "$drift_target")"; drift_record_hash="$(sha256sum "$drift_record")"; drift_prior_hash="$(sha256sum "$drift_prior")"
set +e; (cd "$drift_root" && "$ROOT/adapters/manage.sh" install claude --home home --state-dir state --adapter-root relative-runtime >/dev/null 2>&1); drift_rc=$?; set -e
eq "schema-v2 migration journal refuses third live identity" "$drift_rc" 3
eq "schema-v2 migration drift leaves live config untouched" "$(sha256sum "$drift_target")" "$drift_target_hash"
eq "schema-v2 migration drift retains journal unchanged" "$(sha256sum "$drift_record")" "$drift_record_hash"
eq "schema-v2 migration drift retains backup unchanged" "$(sha256sum "$drift_prior")" "$drift_prior_hash"
jq -e '.phase=="migrating-v2" and .migration.schema=="afk-adapter-migration/1"' "$drift_record" >/dev/null \
  && ok || no "schema-v2 migration drift remains recoverable evidence"

# JSON escapes can carry bytes Bash command substitution cannot preserve. Every
# v2 path/command/plugin string is therefore control-checked inside jq before
# any jq -r extraction; refusal leaves both live files and evidence untouched.
for control_harness in claude codex opencode; do
  for control_kind in nul trailing-lf; do
    control_root="$TMP/v2-control-$control_harness-$control_kind"; prepare_relative_v2_fixture "$control_root" "$control_harness"
    control_record="$control_root/state/adapters/$control_harness.json"
    control_prior="$control_root/state/adapters/$control_harness-prior.json"
    snapshot_relative_v2_fixture "$control_root" "$control_harness" >"$control_root/installed-before"
    if [[ "$control_kind" == nul ]]; then
      jq '.target += "\u0000"' "$control_record" >"$control_root/record-mutated"
    else
      jq '.command += "\n"' "$control_record" >"$control_root/record-mutated"
    fi
    mv "$control_root/record-mutated" "$control_record"
    control_record_hash="$(sha256sum "$control_record")"
    if [[ -f "$control_prior" ]]; then control_prior_hash="$(sha256sum "$control_prior")"; else control_prior_hash=ABSENT; fi
    set +e; (cd "$control_root" && "$ROOT/adapters/manage.sh" install "$control_harness" --home home --state-dir state --adapter-root relative-runtime >/dev/null 2>&1); control_rc=$?; set -e
    eq "schema-v2 $control_harness $control_kind control byte refuses" "$control_rc" 3
    snapshot_relative_v2_fixture "$control_root" "$control_harness" >"$control_root/installed-after"
    cmp "$control_root/installed-before" "$control_root/installed-after" >/dev/null && ok || no "schema-v2 $control_harness $control_kind leaves config untouched"
    eq "schema-v2 $control_harness $control_kind retains record evidence" "$(sha256sum "$control_record")" "$control_record_hash"
    if [[ "$control_prior_hash" == ABSENT ]]; then
      [[ ! -e "$control_prior" ]] && ok || no "schema-v2 $control_harness $control_kind creates no backup evidence"
    else
      eq "schema-v2 $control_harness $control_kind retains backup evidence" "$(sha256sum "$control_prior")" "$control_prior_hash"
    fi
  done
done

# Legacy adapter command strings are parsed as fixed data, never shell text.
# Canonically equivalent traversal, extra fixed-suffix arguments, and malformed
# file URLs all refuse before changing installed configuration or evidence.
v2_traversal_root="$TMP/v2-adapter-traversal"; mkdir -p "$v2_traversal_root/home/.claude" "$v2_traversal_root/relative-runtime/bin"
cp -R "$ROOT/adapters/." "$v2_traversal_root/relative-runtime/"; cp "$ROOT/bin/afk-session-start" "$v2_traversal_root/relative-runtime/bin/afk-session-start"
printf '{"owner":"traversal"}\n' >"$v2_traversal_root/home/.claude/settings.json"
(cd "$v2_traversal_root" && "$v2_base_manager" install claude --home home --state-dir state --adapter-root relative-runtime >/dev/null)
jq '.compact="relative-runtime/../relative-runtime/worker-context.sh compact --harness claude"' "$v2_traversal_root/state/adapters/claude.json" >"$v2_traversal_root/record"; mv "$v2_traversal_root/record" "$v2_traversal_root/state/adapters/claude.json"
v2_traversal_hash="$(sha256sum "$v2_traversal_root/home/.claude/settings.json")"
set +e; (cd "$v2_traversal_root" && "$ROOT/adapters/manage.sh" install claude --home home --state-dir state --adapter-root relative-runtime >/dev/null 2>&1); v2_traversal_rc=$?; set -e
eq "schema-v2 adapter traversal refuses" "$v2_traversal_rc" 3
eq "schema-v2 adapter traversal leaves config untouched" "$(sha256sum "$v2_traversal_root/home/.claude/settings.json")" "$v2_traversal_hash"
[[ -f "$v2_traversal_root/state/adapters/claude.json" && -f "$v2_traversal_root/state/adapters/claude-prior.json" ]] && ok || no "schema-v2 adapter traversal retains evidence"

v2_extra_root="$TMP/v2-adapter-extra"; mkdir -p "$v2_extra_root/home/.codex" "$v2_extra_root/relative-runtime/bin"
cp -R "$ROOT/adapters/." "$v2_extra_root/relative-runtime/"; cp "$ROOT/bin/afk-session-start" "$v2_extra_root/relative-runtime/bin/afk-session-start"
printf 'owner = "extra"\n' >"$v2_extra_root/home/.codex/config.toml"
(cd "$v2_extra_root" && "$v2_base_manager" install codex --home home --state-dir state --adapter-root relative-runtime >/dev/null)
jq '.instruction += " --extra"' "$v2_extra_root/state/adapters/codex.json" >"$v2_extra_root/record"; mv "$v2_extra_root/record" "$v2_extra_root/state/adapters/codex.json"
v2_extra_config_hash="$(sha256sum "$v2_extra_root/home/.codex/config.toml")"; v2_extra_hooks_hash="$(sha256sum "$v2_extra_root/home/.codex/hooks.json")"
set +e; (cd "$v2_extra_root" && "$ROOT/adapters/manage.sh" install codex --home home --state-dir state --adapter-root relative-runtime >/dev/null 2>&1); v2_extra_rc=$?; set -e
eq "schema-v2 adapter extra argument refuses" "$v2_extra_rc" 3
eq "schema-v2 adapter extra argument leaves config untouched" "$(sha256sum "$v2_extra_root/home/.codex/config.toml")" "$v2_extra_config_hash"
eq "schema-v2 adapter extra argument leaves hooks untouched" "$(sha256sum "$v2_extra_root/home/.codex/hooks.json")" "$v2_extra_hooks_hash"
[[ -f "$v2_extra_root/state/adapters/codex.json" && -f "$v2_extra_root/state/adapters/codex-prior.json" ]] && ok || no "schema-v2 adapter extra argument retains evidence"

v2_url_root="$TMP/v2-adapter-url"; mkdir -p "$v2_url_root/home/.config/opencode" "$v2_url_root/relative-runtime/bin"
cp -R "$ROOT/adapters/." "$v2_url_root/relative-runtime/"; cp "$ROOT/bin/afk-session-start" "$v2_url_root/relative-runtime/bin/afk-session-start"
printf '{"owner":"url","plugin":["user-plugin"]}\n' >"$v2_url_root/home/.config/opencode/opencode.json"
(cd "$v2_url_root" && "$v2_base_manager" install opencode --home home --state-dir state --adapter-root relative-runtime >/dev/null)
jq '.command=("file:" + (.command|ltrimstr("file://")))' "$v2_url_root/state/adapters/opencode.json" >"$v2_url_root/record"; mv "$v2_url_root/record" "$v2_url_root/state/adapters/opencode.json"
v2_url_hash="$(sha256sum "$v2_url_root/home/.config/opencode/opencode.json")"
set +e; (cd "$v2_url_root" && "$ROOT/adapters/manage.sh" install opencode --home home --state-dir state --adapter-root relative-runtime >/dev/null 2>&1); v2_url_rc=$?; set -e
eq "schema-v2 malformed adapter URL refuses" "$v2_url_rc" 3
eq "schema-v2 malformed adapter URL leaves config untouched" "$(sha256sum "$v2_url_root/home/.config/opencode/opencode.json")" "$v2_url_hash"
[[ -f "$v2_url_root/state/adapters/opencode.json" ]] && ok || no "schema-v2 malformed adapter URL retains evidence"

# Contradictory v2 ownership metadata is never migration authority. Exercise
# each present/value and hooks/group implication independently and retain the
# installed config plus all evidence on refusal.
malformed_v2_claude() { # name jq-filter
  local name="$1" filter="$2" fixture rc target_hash
  fixture="$TMP/malformed-v2-$name"
  mkdir -p "$fixture/home/.claude"
  printf '{"owner":"claude"}\n' >"$fixture/home/.claude/settings.json"
  "$v2_base_manager" install claude --home "$fixture/home" --state-dir "$fixture/state" --adapter-root "$ROOT/adapters" >/dev/null
  jq "$filter" "$fixture/state/adapters/claude-prior.json" >"$fixture/prior"; mv "$fixture/prior" "$fixture/state/adapters/claude-prior.json"
  target_hash="$(sha256sum "$fixture/home/.claude/settings.json")"
  set +e; "$ROOT/adapters/manage.sh" install claude --home "$fixture/home" --state-dir "$fixture/state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; rc=$?; set -e
  eq "$name refuses v2 migration" "$rc" 3
  eq "$name leaves Claude config untouched" "$(sha256sum "$fixture/home/.claude/settings.json")" "$target_hash"
  [[ -f "$fixture/state/adapters/claude.json" && -f "$fixture/state/adapters/claude-prior.json" ]] && ok || no "$name retains Claude migration evidence"
}
malformed_v2_claude claude-hooks-contradiction '.hooks_preexisting=false | .hook_groups.SessionStart=true'
malformed_v2_claude claude-present-contradiction '.present=false | .value={forged:true}'

malformed_v2_codex() { # name record-or-backup jq-filter
  local name="$1" subject="$2" filter="$3" fixture rc config_hash hooks_hash path
  fixture="$TMP/malformed-v2-$name"
  mkdir -p "$fixture/home/.codex"
  printf 'owner = "codex"\n' >"$fixture/home/.codex/config.toml"
  "$v2_base_manager" install codex --home "$fixture/home" --state-dir "$fixture/state" --adapter-root "$ROOT/adapters" >/dev/null
  if [[ "$subject" == record ]]; then path="$fixture/state/adapters/codex.json"; else path="$fixture/state/adapters/codex-prior.json"; fi
  jq "$filter" "$path" >"$fixture/malformed"; mv "$fixture/malformed" "$path"
  config_hash="$(sha256sum "$fixture/home/.codex/config.toml")"; hooks_hash="$(sha256sum "$fixture/home/.codex/hooks.json")"
  set +e; "$ROOT/adapters/manage.sh" install codex --home "$fixture/home" --state-dir "$fixture/state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; rc=$?; set -e
  eq "$name refuses v2 migration" "$rc" 3
  eq "$name leaves Codex config untouched" "$(sha256sum "$fixture/home/.codex/config.toml")" "$config_hash"
  eq "$name leaves Codex hooks untouched" "$(sha256sum "$fixture/home/.codex/hooks.json")" "$hooks_hash"
  [[ -f "$fixture/state/adapters/codex.json" && -f "$fixture/state/adapters/codex-prior.json" ]] && ok || no "$name retains Codex migration evidence"
}
malformed_v2_codex codex-hooks-contradiction record '.hooks_preexisting=false | .hook_groups.PreCompact=true'
malformed_v2_codex codex-present-contradiction backup '.present=false | .value=["forged"]'
malformed_v2_codex codex-owner-metadata-contradiction backup '. + {config_preexisting:true,hooks_preexisting:true,hook_groups:{SessionStart:false,PreCompact:false}}'

duplicate_home="$TMP/duplicate-home"; duplicate_state="$TMP/duplicate-state"; mkdir -p "$duplicate_home/.config/opencode"
printf '{"plugin":[],"plugin":["owner"]}\n' >"$duplicate_home/.config/opencode/opencode.jsonc"
set +e; "$ROOT/adapters/manage.sh" install opencode --home "$duplicate_home" --state-dir "$duplicate_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; duplicate_rc=$?; set -e
eq "duplicate top-level OpenCode plugin keys refuse" "$duplicate_rc" 3
eq "duplicate-key OpenCode config remains byte-identical" "$(<"$duplicate_home/.config/opencode/opencode.jsonc")" '{"plugin":[],"plugin":["owner"]}'

# The manager lock is an atomic directory. A symlink at the lock path must
# block the operation without opening or truncating its target.
manager_lock_home="$TMP/manager-lock-home"; manager_lock_state="$TMP/manager-lock-state"; mkdir -p "$manager_lock_home/.claude" "$manager_lock_state/adapters"
printf 'LOCK-VICTIM\n' >"$TMP/manager-lock-victim"
ln -s "$TMP/manager-lock-victim" "$manager_lock_state/adapters/.manage-claude.lockdir"
set +e; "$ROOT/adapters/manage.sh" install claude --home "$manager_lock_home" --state-dir "$manager_lock_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; manager_lock_rc=$?; set -e
eq "symlink manager lock refuses" "$manager_lock_rc" 3
eq "symlink manager lock target is not truncated" "$(<"$TMP/manager-lock-victim")" LOCK-VICTIM
live_manager_home="$TMP/live-manager-home"; live_manager_state="$TMP/live-manager-state"; mkdir -p "$live_manager_home/.claude" "$live_manager_state/adapters/.manage-claude.lockdir"
printf '%s live\n' "$$" >"$live_manager_state/adapters/.manage-claude.lockdir/owner"
set +e; "$ROOT/adapters/manage.sh" install claude --home "$live_manager_home" --state-dir "$live_manager_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; live_manager_rc=$?; set -e
eq "live manager lock refuses concurrent operation" "$live_manager_rc" 3
stale_manager_home="$TMP/stale-manager-home"; stale_manager_state="$TMP/stale-manager-state"; mkdir -p "$stale_manager_home/.claude" "$stale_manager_state/adapters/.manage-claude.lockdir"
printf '2147483647 live\n' >"$stale_manager_state/adapters/.manage-claude.lockdir/owner"
if "$ROOT/adapters/manage.sh" install claude --home "$stale_manager_home" --state-dir "$stale_manager_state" --adapter-root "$ROOT/adapters" >/dev/null; then ok; else no "manager reclaims dead owner lock"; fi
[[ ! -e "$stale_manager_state/adapters/.manage-claude.lockdir" ]] && ok || no "manager releases reclaimed lock"
"$ROOT/adapters/manage.sh" remove claude --home "$stale_manager_home" --state-dir "$stale_manager_state" --adapter-root "$ROOT/adapters" >/dev/null

# Force the old root-directory publication interleaving. The first process is
# stopped after creating the root; the second atomically publishes its complete
# owner record. Releasing the first must never produce a second owner.
lock_race_bin="$TMP/lock-race-bin"; lock_race_dir="$TMP/lock-race"; mkdir -p "$lock_race_bin" "$lock_race_dir"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
  '/bin/mkdir "$@"; rc=$?; candidate="${!#}"' \
  'if [[ "$rc" == 0 && "$candidate" == "$AFK_RACE_LOCK" && "$AFK_RACE_ROLE" == *-first ]]; then : >"$AFK_RACE_DIR/$AFK_RACE_ROLE-root"; while [[ ! -e "$AFK_RACE_DIR/$AFK_RACE_ROLE-release-root" ]]; do /bin/sleep 0.01; done; fi' \
  'exit "$rc"' >"$lock_race_bin/mkdir"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
  'out="$(/usr/bin/stat "$@")"; rc=$?; candidate="${!#}"' \
  'if [[ "$rc" == 0 && "$candidate" == "$AFK_RACE_OWNER" && "$AFK_RACE_ROLE" == *-second ]]; then : >"$AFK_RACE_DIR/$AFK_RACE_ROLE-owned"; while [[ ! -e "$AFK_RACE_DIR/$AFK_RACE_ROLE-release-owner" ]]; do /bin/sleep 0.01; done; fi' \
  'if [[ "$rc" == 0 && "$candidate" == "$AFK_RACE_OWNER" && "$AFK_RACE_ROLE" == *-killed ]]; then : >"$AFK_RACE_DIR/$AFK_RACE_ROLE-owned"; while [[ ! -e "$AFK_RACE_DIR/$AFK_RACE_ROLE-release-owner" ]]; do /bin/sleep 0.01; done; fi' \
  'printf "%s\n" "$out"; exit "$rc"' >"$lock_race_bin/stat"
chmod +x "$lock_race_bin/mkdir" "$lock_race_bin/stat"

race_manager_home="$TMP/race-manager-home"; race_manager_state="$TMP/race-manager-state"; mkdir -p "$race_manager_home/.claude" "$race_manager_state/adapters"
race_manager_lock="$race_manager_state/adapters/.manage-claude.lockdir"; race_manager_owner="$race_manager_lock/owner"
PATH="$lock_race_bin:$PATH" AFK_RACE_LOCK="$race_manager_lock" AFK_RACE_OWNER="$race_manager_owner" AFK_RACE_ROLE=manager-first AFK_RACE_DIR="$lock_race_dir" \
  "$ROOT/adapters/manage.sh" install claude --home "$race_manager_home" --state-dir "$race_manager_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1 & manager_first_pid=$!
for _ in $(seq 1 500); do [[ -e "$lock_race_dir/manager-first-root" ]] && break; /bin/sleep 0.01; done
TZ=Pacific/Honolulu PATH="$lock_race_bin:$PATH" AFK_RACE_LOCK="$race_manager_lock" AFK_RACE_OWNER="$race_manager_owner" AFK_RACE_ROLE=manager-second AFK_RACE_DIR="$lock_race_dir" \
  "$ROOT/adapters/manage.sh" install claude --home "$race_manager_home" --state-dir "$race_manager_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1 & manager_second_pid=$!
for _ in $(seq 1 500); do [[ -e "$lock_race_dir/manager-second-owned" ]] && break; /bin/sleep 0.01; done
: >"$lock_race_dir/manager-first-release-root"
set +e; wait "$manager_first_pid"; manager_first_rc=$?; set -e
eq "manager initialization contender refuses" "$manager_first_rc" 3
eq "manager publishes one complete owner" "$(<"$race_manager_owner")" "$manager_second_pid $(sed -n 's/^[0-9][0-9]* //p' "$race_manager_owner")"
manager_owner_before="$(<"$race_manager_owner")"
set +e; TZ=Asia/Tokyo "$ROOT/adapters/manage.sh" install claude --home "$race_manager_home" --state-dir "$race_manager_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; mixed_tz_manager_rc=$?; set -e
eq "mixed-TZ manager contender sees live owner" "$mixed_tz_manager_rc" 3
eq "mixed-TZ manager contender cannot replace owner" "$(<"$race_manager_owner")" "$manager_owner_before"
: >"$lock_race_dir/manager-second-release-owner"
set +e; wait "$manager_second_pid"; manager_second_rc=$?; set -e
eq "manager atomic owner wins alone" "$manager_second_rc" 0

# Candidate publication is written only through the already-open descriptor.
# Swapping its pathname to a victim symlink after validation must fail closed
# without changing the victim through the replacement name.
candidate_swap_bin="$TMP/candidate-swap-bin"; mkdir -p "$candidate_swap_bin"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
  'out="$(/usr/bin/stat "$@")"; rc=$?; candidate="${!#}"' \
  'if [[ "$rc" == 0 && "$candidate" == "$AFK_SWAP_CANDIDATE_PREFIX"* && ! -e "$AFK_SWAP_CANDIDATE_MARKER" ]]; then /usr/bin/mv -- "$candidate" "$candidate.original"; /usr/bin/ln -s "$AFK_SWAP_CANDIDATE_VICTIM" "$candidate"; : >"$AFK_SWAP_CANDIDATE_MARKER"; fi' \
  'printf "%s\n" "$out"; exit "$rc"' >"$candidate_swap_bin/stat"; chmod +x "$candidate_swap_bin/stat"
candidate_manager_home="$TMP/candidate-manager-home"; candidate_manager_state="$TMP/candidate-manager-state"; mkdir -p "$candidate_manager_home/.claude"
candidate_manager_victim="$TMP/candidate-manager-victim"; printf 'MANAGER-VICTIM\n' >"$candidate_manager_victim"
set +e
PATH="$candidate_swap_bin:$PATH" AFK_SWAP_CANDIDATE_PREFIX="$candidate_manager_state/adapters/.manage-claude.candidate." \
  AFK_SWAP_CANDIDATE_MARKER="$TMP/candidate-manager-swapped" AFK_SWAP_CANDIDATE_VICTIM="$candidate_manager_victim" \
  "$ROOT/adapters/manage.sh" install claude --home "$candidate_manager_home" --state-dir "$candidate_manager_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1
candidate_manager_rc=$?
set -e
eq "swapped manager owner candidate refuses" "$candidate_manager_rc" 3
[[ -e "$TMP/candidate-manager-swapped" ]] && ok || no "manager owner candidate swap fixture did not execute"
eq "swapped manager owner candidate cannot truncate victim" "$(<"$candidate_manager_victim")" MANAGER-VICTIM

# A process killed after the complete claim is visible leaves enough identity
# for the next acquisition to reclaim safely; no partial metadata state exists.
killed_manager_home="$TMP/killed-manager-home"; killed_manager_state="$TMP/killed-manager-state"; mkdir -p "$killed_manager_home/.claude" "$killed_manager_state/adapters"
killed_manager_lock="$killed_manager_state/adapters/.manage-claude.lockdir"; killed_manager_owner="$killed_manager_lock/owner"
PATH="$lock_race_bin:$PATH" AFK_RACE_LOCK="$killed_manager_lock" AFK_RACE_OWNER="$killed_manager_owner" AFK_RACE_ROLE=manager-killed AFK_RACE_DIR="$lock_race_dir" \
  "$ROOT/adapters/manage.sh" install claude --home "$killed_manager_home" --state-dir "$killed_manager_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1 & killed_manager_pid=$!
for _ in $(seq 1 500); do [[ -e "$lock_race_dir/manager-killed-owned" ]] && break; /bin/sleep 0.01; done
kill -9 "$killed_manager_pid" 2>/dev/null || true
: >"$lock_race_dir/manager-killed-release-owner"
set +e; wait "$killed_manager_pid" 2>/dev/null; set -e
# The killed process's own child (the "stat" race helper, blocked on the
# release file) is not this script's direct child and `wait` above never
# covers it. Let it actually exit before the next case reuses this bin/dir,
# instead of trusting that it happened to finish in time.
for _ in $(seq 1 500); do pgrep -f "$lock_race_bin/stat" >/dev/null 2>&1 || break; /bin/sleep 0.01; done
# The loop above is a bounded poll, not a proof: it also exits after 500
# iterations even if the helper never exited. Check again, explicitly, so a
# still-running helper fails this case instead of silently letting the next
# case reuse the same bin/dir underneath it.
if pgrep -f "$lock_race_bin/stat" >/dev/null 2>&1; then
  no "race-helper stat child is still running after the poll deadline"
else
  ok
fi
if "$ROOT/adapters/manage.sh" install claude --home "$killed_manager_home" --state-dir "$killed_manager_state" --adapter-root "$ROOT/adapters" >/dev/null; then ok; else no "manager reclaims complete claim after SIGKILL"; fi
"$ROOT/adapters/manage.sh" remove claude --home "$killed_manager_home" --state-dir "$killed_manager_state" --adapter-root "$ROOT/adapters" >/dev/null

duplicate_owned_home="$TMP/duplicate-owned-home"; duplicate_owned_state="$TMP/duplicate-owned-state"; mkdir -p "$duplicate_owned_home/.config/opencode"
printf '{"plugin":["owner"]}\n' >"$duplicate_owned_home/.config/opencode/opencode.json"
"$ROOT/adapters/manage.sh" install opencode --home "$duplicate_owned_home" --state-dir "$duplicate_owned_state" --adapter-root "$ROOT/adapters" >/dev/null
jq '.plugin += [.plugin[-1]]' "$duplicate_owned_home/.config/opencode/opencode.json" >"$TMP/duplicate-owned.json"; mv "$TMP/duplicate-owned.json" "$duplicate_owned_home/.config/opencode/opencode.json"
set +e; "$ROOT/adapters/manage.sh" remove opencode --home "$duplicate_owned_home" --state-dir "$duplicate_owned_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; duplicate_owned_rc=$?; set -e
eq "duplicate owned OpenCode plugin values refuse removal" "$duplicate_owned_rc" 3
eq "duplicate owned OpenCode plugin values remain intact" "$(jq '[.plugin[]|select(endswith("/opencode/plugin.js"))]|length' "$duplicate_owned_home/.config/opencode/opencode.json")" 2
[[ -f "$duplicate_owned_state/adapters/opencode.json" ]] && ok || no "duplicate owned OpenCode plugin retains ownership evidence"
jq '.phase="installing"' "$duplicate_owned_state/adapters/opencode.json" >"$TMP/duplicate-owned-record.json"; mv "$TMP/duplicate-owned-record.json" "$duplicate_owned_state/adapters/opencode.json"
set +e; "$ROOT/adapters/manage.sh" remove opencode --home "$duplicate_owned_home" --state-dir "$duplicate_owned_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; duplicate_owned_recovery_rc=$?; set -e
eq "duplicate owned OpenCode plugin values refuse recovery" "$duplicate_owned_recovery_rc" 3
eq "duplicate owned OpenCode recovery leaves both values" "$(jq '[.plugin[]|select(endswith("/opencode/plugin.js"))]|length' "$duplicate_owned_home/.config/opencode/opencode.json")" 2
[[ -f "$duplicate_owned_state/adapters/opencode.json" ]] && ok || no "duplicate owned OpenCode recovery retains ownership evidence"

# An interrupted prepared install is rolled back from secret-free structural
# ownership metadata on the next adapter-manager invocation.
recovery_home="$TMP/recovery-home"; recovery_state="$TMP/recovery-state"; mkdir -p "$recovery_home/.claude" "$recovery_state/adapters"
printf '{"theme":"original"}\n' >"$recovery_home/.claude/settings.json"; cp "$recovery_home/.claude/settings.json" "$TMP/recovery-before.json"
"$ROOT/adapters/manage.sh" install claude --home "$recovery_home" --state-dir "$recovery_state" --adapter-root "$ROOT/adapters" >/dev/null
jq '.phase="installing"' "$recovery_state/adapters/claude.json" >"$TMP/pending.json"; mv "$TMP/pending.json" "$recovery_state/adapters/claude.json"
"$ROOT/adapters/manage.sh" remove claude --home "$recovery_home" --state-dir "$recovery_state" --adapter-root "$ROOT/adapters" >/dev/null || no "prepared Claude install recovery"
if diff -u <(jq -S . "$TMP/recovery-before.json") <(jq -S . "$recovery_home/.claude/settings.json") >/dev/null; then ok; else no "interrupted install restores pre-transaction structure"; fi

# Pending rollback must not overwrite user changes made after the interrupted
# install, even when the ownership record still describes the installed value.
pending_drift_home="$TMP/pending-drift-home"; pending_drift_state="$TMP/pending-drift-state"; mkdir -p "$pending_drift_home/.claude"
printf '{"statusLine":{"type":"command","command":"owner"}}\n' >"$pending_drift_home/.claude/settings.json"
"$ROOT/adapters/manage.sh" install claude --home "$pending_drift_home" --state-dir "$pending_drift_state" --adapter-root "$ROOT/adapters" >/dev/null
jq '.phase="installing"' "$pending_drift_state/adapters/claude.json" >"$TMP/pending.json"; mv "$TMP/pending.json" "$pending_drift_state/adapters/claude.json"
jq '.statusLine.afterCrash="keep" | .hooks.PreCompact[-1].afterCrash="keep"' "$pending_drift_home/.claude/settings.json" >"$TMP/pending-drift.json"; mv "$TMP/pending-drift.json" "$pending_drift_home/.claude/settings.json"
set +e; "$ROOT/adapters/manage.sh" remove claude --home "$pending_drift_home" --state-dir "$pending_drift_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; pending_drift_rc=$?; set -e
eq "pending Claude recovery refuses status and hook drift" "$pending_drift_rc" 3
eq "pending Claude status drift survives" "$(jq -r .statusLine.afterCrash "$pending_drift_home/.claude/settings.json")" keep
eq "pending Claude hook drift survives" "$(jq -r '.hooks.PreCompact[-1].afterCrash' "$pending_drift_home/.claude/settings.json")" keep
[[ -f "$pending_drift_state/adapters/claude.json" && -f "$pending_drift_state/adapters/claude-prior.json" ]] && ok || no "pending Claude drift retains recovery evidence"

codex_recovery_home="$TMP/codex-recovery-home"; codex_recovery_state="$TMP/codex-recovery-state"
mkdir -p "$codex_recovery_home/.codex" "$codex_recovery_state/adapters"
printf 'model = "owner"\n' >"$codex_recovery_home/.codex/config.toml"; printf '{"hooks":{"Stop":[]}}\n' >"$codex_recovery_home/.codex/hooks.json"
"$ROOT/adapters/manage.sh" install codex --home "$codex_recovery_home" --state-dir "$codex_recovery_state" --adapter-root "$ROOT/adapters" >/dev/null
jq '.phase="installing"' "$codex_recovery_state/adapters/codex.json" >"$TMP/pending.json"; mv "$TMP/pending.json" "$codex_recovery_state/adapters/codex.json"
"$ROOT/adapters/manage.sh" remove codex --home "$codex_recovery_home" --state-dir "$codex_recovery_state" --adapter-root "$ROOT/adapters" >/dev/null || no "prepared Codex install recovery"
eq "interrupted Codex config restores pre-transaction bytes" "$(<"$codex_recovery_home/.codex/config.toml")" 'model = "owner"'
if diff -u <(jq -S . <<<'{"hooks":{"Stop":[]}}') <(jq -S . "$codex_recovery_home/.codex/hooks.json") >/dev/null; then ok; else no "interrupted Codex hooks restore pre-transaction structure"; fi

multi_home="$TMP/multi-home"; multi_state="$TMP/multi-state"; mkdir -p "$multi_home/.codex"
printf 'model="owner"\n' >"$multi_home/.codex/config.toml"; printf '{"hooks":{}}\n' >"$multi_home/.codex/hooks.json"
"$ROOT/adapters/manage.sh" install codex --home "$multi_home" --state-dir "$multi_state" --adapter-root "$ROOT/adapters" >/dev/null
jq '.phase="installing"' "$multi_state/adapters/codex.json" >"$TMP/pending.json"; mv "$TMP/pending.json" "$multi_state/adapters/codex.json"
printf '{broken\n' >"$multi_home/.codex/hooks.json"
set +e; "$ROOT/adapters/manage.sh" remove codex --home "$multi_home" --state-dir "$multi_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; multi_rc=$?; set -e
eq "unverifiable multi-target recovery refuses" "$multi_rc" 3
[[ -f "$multi_state/adapters/codex.json" && -f "$multi_state/adapters/codex-prior.json" ]] && ok || no "multi-target recovery retains all evidence"
eq "failed multi-target recovery leaves first target installed" "$(yq -p=toml -o=json '.tui.status_line|length>0' "$multi_home/.codex/config.toml")" true

codex_pending_drift_home="$TMP/codex-pending-drift-home"; codex_pending_drift_state="$TMP/codex-pending-drift-state"; mkdir -p "$codex_pending_drift_home/.codex"
printf 'model="owner"\n' >"$codex_pending_drift_home/.codex/config.toml"; printf '{"hooks":{}}\n' >"$codex_pending_drift_home/.codex/hooks.json"
"$ROOT/adapters/manage.sh" install codex --home "$codex_pending_drift_home" --state-dir "$codex_pending_drift_state" --adapter-root "$ROOT/adapters" >/dev/null
jq '.phase="installing"' "$codex_pending_drift_state/adapters/codex.json" >"$TMP/pending.json"; mv "$TMP/pending.json" "$codex_pending_drift_state/adapters/codex.json"
yq -i -p=toml -o=toml '.tui.status_line += ["current-dir"]' "$codex_pending_drift_home/.codex/config.toml"
set +e; "$ROOT/adapters/manage.sh" remove codex --home "$codex_pending_drift_home" --state-dir "$codex_pending_drift_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; codex_pending_drift_rc=$?; set -e
eq "pending Codex recovery refuses footer drift" "$codex_pending_drift_rc" 3
eq "pending Codex footer drift survives" "$(yq -p=toml -o=json '.tui.status_line' "$codex_pending_drift_home/.codex/config.toml" | jq 'index("current-dir")!=null')" true
[[ -f "$codex_pending_drift_state/adapters/codex.json" && -f "$codex_pending_drift_state/adapters/codex-prior.json" ]] && ok || no "pending Codex footer drift retains all evidence"

codex_metadata_home="$TMP/codex-metadata-home"; codex_metadata_state="$TMP/codex-metadata-state"; mkdir -p "$codex_metadata_home/.codex"
printf 'model="owner"\n' >"$codex_metadata_home/.codex/config.toml"; printf '{"hooks":{}}\n' >"$codex_metadata_home/.codex/hooks.json"
"$ROOT/adapters/manage.sh" install codex --home "$codex_metadata_home" --state-dir "$codex_metadata_state" --adapter-root "$ROOT/adapters" >/dev/null
jq '.hooks.PreCompact[-1].ownerField="keep"' "$codex_metadata_home/.codex/hooks.json" >"$TMP/codex-metadata.json"; mv "$TMP/codex-metadata.json" "$codex_metadata_home/.codex/hooks.json"
set +e; "$ROOT/adapters/manage.sh" remove codex --home "$codex_metadata_home" --state-dir "$codex_metadata_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; codex_metadata_rc=$?; set -e
eq "augmented Codex wrapper removal refuses" "$codex_metadata_rc" 3
eq "augmented Codex wrapper metadata survives" "$(jq -r '.hooks.PreCompact[-1].ownerField' "$codex_metadata_home/.codex/hooks.json")" keep
[[ -f "$codex_metadata_state/adapters/codex.json" && -f "$codex_metadata_state/adapters/codex-prior.json" ]] && ok || no "augmented Codex wrapper retains ownership evidence"

# A target recorded as pre-existing cannot disappear during recovery. Missing
# files are drift, not evidence that rollback already completed.
missing_claude_home="$TMP/missing-claude-home"; missing_claude_state="$TMP/missing-claude-state"; mkdir -p "$missing_claude_home/.claude"
printf '{"owner":true}\n' >"$missing_claude_home/.claude/settings.json"
"$ROOT/adapters/manage.sh" install claude --home "$missing_claude_home" --state-dir "$missing_claude_state" --adapter-root "$ROOT/adapters" >/dev/null
jq '.phase="installing"' "$missing_claude_state/adapters/claude.json" >"$TMP/pending.json"; mv "$TMP/pending.json" "$missing_claude_state/adapters/claude.json"; rm "$missing_claude_home/.claude/settings.json"
set +e; "$ROOT/adapters/manage.sh" remove claude --home "$missing_claude_home" --state-dir "$missing_claude_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; missing_claude_rc=$?; set -e
eq "missing pre-existing Claude recovery target refuses" "$missing_claude_rc" 3
[[ -f "$missing_claude_state/adapters/claude.json" && -f "$missing_claude_state/adapters/claude-prior.json" ]] && ok || no "missing Claude recovery target retains all evidence"

missing_hooks_home="$TMP/missing-hooks-home"; missing_hooks_state="$TMP/missing-hooks-state"; mkdir -p "$missing_hooks_home/.codex"
printf 'model="owner"\n' >"$missing_hooks_home/.codex/config.toml"; printf '{"hooks":{"Stop":[]}}\n' >"$missing_hooks_home/.codex/hooks.json"
"$ROOT/adapters/manage.sh" install codex --home "$missing_hooks_home" --state-dir "$missing_hooks_state" --adapter-root "$ROOT/adapters" >/dev/null
jq '.phase="installing"' "$missing_hooks_state/adapters/codex.json" >"$TMP/pending.json"; mv "$TMP/pending.json" "$missing_hooks_state/adapters/codex.json"; rm "$missing_hooks_home/.codex/hooks.json"
missing_hooks_config_hash="$(sha256sum "$missing_hooks_home/.codex/config.toml")"
set +e; "$ROOT/adapters/manage.sh" remove codex --home "$missing_hooks_home" --state-dir "$missing_hooks_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; missing_hooks_rc=$?; set -e
eq "missing pre-existing Codex hooks recovery target refuses" "$missing_hooks_rc" 3
eq "missing Codex hooks recovery leaves config untouched" "$(sha256sum "$missing_hooks_home/.codex/config.toml")" "$missing_hooks_config_hash"
[[ -f "$missing_hooks_state/adapters/codex.json" && -f "$missing_hooks_state/adapters/codex-prior.json" ]] && ok || no "missing Codex hooks recovery retains all evidence"

open_recovery_home="$TMP/open-recovery-home"; open_recovery_state="$TMP/open-recovery-state"
mkdir -p "$open_recovery_home/.config/opencode" "$open_recovery_state/adapters"
printf '{\n  // retained\n  "theme": "owner",\n}\n' >"$open_recovery_home/.config/opencode/opencode.jsonc"
cp "$open_recovery_home/.config/opencode/opencode.jsonc" "$TMP/open-recovery-before.jsonc"
"$ROOT/adapters/manage.sh" install opencode --home "$open_recovery_home" --state-dir "$open_recovery_state" --adapter-root "$ROOT/adapters" >/dev/null
jq '.phase="installing"' "$open_recovery_state/adapters/opencode.json" >"$TMP/pending.json"; mv "$TMP/pending.json" "$open_recovery_state/adapters/opencode.json"
"$ROOT/adapters/manage.sh" remove opencode --home "$open_recovery_home" --state-dir "$open_recovery_state" --adapter-root "$ROOT/adapters" >/dev/null || no "prepared OpenCode install recovery"
if cmp "$TMP/open-recovery-before.jsonc" "$open_recovery_home/.config/opencode/opencode.jsonc" >/dev/null; then ok; else no "interrupted OpenCode install restores pre-transaction bytes"; fi

missing_open_home="$TMP/missing-open-home"; missing_open_state="$TMP/missing-open-state"; mkdir -p "$missing_open_home/.config/opencode"
printf '{"theme":"owner"}\n' >"$missing_open_home/.config/opencode/opencode.json"
"$ROOT/adapters/manage.sh" install opencode --home "$missing_open_home" --state-dir "$missing_open_state" --adapter-root "$ROOT/adapters" >/dev/null
jq '.phase="installing"' "$missing_open_state/adapters/opencode.json" >"$TMP/pending.json"; mv "$TMP/pending.json" "$missing_open_state/adapters/opencode.json"; rm "$missing_open_home/.config/opencode/opencode.json"
set +e; "$ROOT/adapters/manage.sh" remove opencode --home "$missing_open_home" --state-dir "$missing_open_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; missing_open_rc=$?; set -e
eq "missing pre-existing OpenCode recovery target refuses" "$missing_open_rc" 3
[[ -f "$missing_open_state/adapters/opencode.json" ]] && ok || no "missing OpenCode recovery target retains ownership evidence"

forged_open_home="$TMP/forged-open-home"; forged_open_state="$TMP/forged-open-state"; mkdir -p "$forged_open_home/.config/opencode" "$forged_open_state/adapters"
printf '{"plugin":["user-owned-plugin"]}\n' >"$forged_open_home/.config/opencode/opencode.json"
printf '{"config_preexisting":true,"prior_plugin_present":true}\n' >"$forged_open_state/adapters/opencode-prior.json"
forged_open_digest="$(sha256sum "$forged_open_state/adapters/opencode-prior.json" | awk '{print $1}')"
jq -nc --arg t "$forged_open_home/.config/opencode/opencode.json" --arg b "$forged_open_state/adapters/opencode-prior.json" --arg d "$forged_open_digest" \
  '{schema:"afk-adapter-install/3",harness:"opencode",phase:"installing",target:$t,command:"user-owned-plugin",backup:$b,backup_sha256:$d,config_preexisting:true,prior_plugin_present:true}' >"$forged_open_state/adapters/opencode.json"
set +e; "$ROOT/adapters/manage.sh" remove opencode --home "$forged_open_home" --state-dir "$forged_open_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; forged_open_rc=$?; set -e
eq "forged OpenCode command refuses recovery" "$forged_open_rc" 3
eq "forged OpenCode command cannot delete user plugin" "$(jq -r '.plugin[0]' "$forged_open_home/.config/opencode/opencode.json")" user-owned-plugin
[[ -f "$forged_open_state/adapters/opencode.json" && -f "$forged_open_state/adapters/opencode-prior.json" ]] && ok || no "forged OpenCode recovery retains evidence"

tampered_prior_home="$TMP/tampered-prior-home"; tampered_prior_state="$TMP/tampered-prior-state"; mkdir -p "$tampered_prior_home/.claude"
printf '{"owner":true}\n' >"$tampered_prior_home/.claude/settings.json"
"$ROOT/adapters/manage.sh" install claude --home "$tampered_prior_home" --state-dir "$tampered_prior_state" --adapter-root "$ROOT/adapters" >/dev/null
jq '.phase="installing"' "$tampered_prior_state/adapters/claude.json" >"$TMP/pending.json"; mv "$TMP/pending.json" "$tampered_prior_state/adapters/claude.json"
tampered_target_hash="$(sha256sum "$tampered_prior_home/.claude/settings.json")"
jq '.value={"command":"forged"}' "$tampered_prior_state/adapters/claude-prior.json" >"$TMP/tampered-prior.json"; mv "$TMP/tampered-prior.json" "$tampered_prior_state/adapters/claude-prior.json"
set +e; "$ROOT/adapters/manage.sh" remove claude --home "$tampered_prior_home" --state-dir "$tampered_prior_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; tampered_prior_rc=$?; set -e
eq "tampered restoration metadata refuses recovery" "$tampered_prior_rc" 3
eq "tampered restoration metadata leaves config untouched" "$(sha256sum "$tampered_prior_home/.claude/settings.json")" "$tampered_target_hash"
[[ -f "$tampered_prior_state/adapters/claude.json" && -f "$tampered_prior_state/adapters/claude-prior.json" ]] && ok || no "tampered restoration metadata retains evidence"

# Even a compromised mktemp implementation cannot redirect a recovery write:
# recovery accepts only its newly-created regular inode beside the target.
temp_attack_home="$TMP/temp-attack-home"; temp_attack_state="$TMP/temp-attack-state"; mkdir -p "$temp_attack_home/.claude" "$TMP/fake-mktemp-bin"
printf '{"owner":true}\n' >"$temp_attack_home/.claude/settings.json"; printf 'DO-NOT-TOUCH\n' >"$TMP/temp-attack-victim"
"$ROOT/adapters/manage.sh" install claude --home "$temp_attack_home" --state-dir "$temp_attack_state" --adapter-root "$ROOT/adapters" >/dev/null
jq '.phase="installing"' "$temp_attack_state/adapters/claude.json" >"$TMP/pending.json"; mv "$TMP/pending.json" "$temp_attack_state/adapters/claude.json"
fake_recovery_temp="$temp_attack_home/.claude/settings.json.afk-recovery.aaaaaa"
ln -s "$TMP/temp-attack-victim" "$fake_recovery_temp"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\\n" "$AFK_FAKE_MKTEMP_PATH"' >"$TMP/fake-mktemp-bin/mktemp"; chmod +x "$TMP/fake-mktemp-bin/mktemp"
set +e; PATH="$TMP/fake-mktemp-bin:$PATH" AFK_FAKE_MKTEMP_PATH="$fake_recovery_temp" "$ROOT/adapters/manage.sh" remove claude --home "$temp_attack_home" --state-dir "$temp_attack_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; temp_attack_rc=$?; set -e
eq "unsafe recovery temporary refuses" "$temp_attack_rc" 3
eq "unsafe recovery temporary leaves victim untouched" "$(<"$TMP/temp-attack-victim")" DO-NOT-TOUCH
[[ -f "$temp_attack_state/adapters/claude.json" && -f "$temp_attack_state/adapters/claude-prior.json" ]] && ok || no "unsafe recovery temporary retains all evidence"

inode_swap_home="$TMP/inode-swap-home"; inode_swap_state="$TMP/inode-swap-state"; inode_swap_bin="$TMP/inode-swap-bin"; mkdir -p "$inode_swap_home/.claude" "$inode_swap_bin"
printf '{"owner":true}\n' >"$inode_swap_home/.claude/settings.json"
"$ROOT/adapters/manage.sh" install claude --home "$inode_swap_home" --state-dir "$inode_swap_state" --adapter-root "$ROOT/adapters" >/dev/null
jq '.phase="installing"' "$inode_swap_state/adapters/claude.json" >"$TMP/pending.json"; mv "$TMP/pending.json" "$inode_swap_state/adapters/claude.json"
inode_swap_target_hash="$(sha256sum "$inode_swap_home/.claude/settings.json")"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
  'out="$(/usr/bin/stat "$@")"; rc=$?; candidate="${!#}"' \
  'if [[ "$rc" == 0 && "$candidate" == "$AFK_SWAP_TEMP_PREFIX".afk-recovery.* && ! -e "$AFK_SWAP_TEMP_MARKER" ]]; then /usr/bin/mv -- "$candidate" "$candidate.original"; : >"$candidate"; printf swapped >"$AFK_SWAP_TEMP_MARKER"; fi' \
  'printf "%s\\n" "$out"; exit "$rc"' >"$inode_swap_bin/stat"; chmod +x "$inode_swap_bin/stat"
set +e; PATH="$inode_swap_bin:$PATH" AFK_SWAP_TEMP_PREFIX="$inode_swap_home/.claude/settings.json" AFK_SWAP_TEMP_MARKER="$TMP/inode-swapped" "$ROOT/adapters/manage.sh" remove claude --home "$inode_swap_home" --state-dir "$inode_swap_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; inode_swap_rc=$?; set -e
eq "swapped recovery temporary inode refuses rename" "$inode_swap_rc" 3
[[ -f "$TMP/inode-swapped" ]] && ok || no "recovery inode swap fixture did not execute"
eq "swapped recovery temporary leaves target untouched" "$(sha256sum "$inode_swap_home/.claude/settings.json")" "$inode_swap_target_hash"
[[ -f "$inode_swap_state/adapters/claude.json" && -f "$inode_swap_state/adapters/claude-prior.json" ]] && ok || no "swapped recovery temporary retains all evidence"

# A pending record cannot redirect recovery outside its harness-owned paths.
unsafe_home="$TMP/unsafe-home"; unsafe_state="$TMP/unsafe-state"; mkdir -p "$unsafe_home/.claude" "$unsafe_state/adapters"
printf '{"safe":true}\n' >"$unsafe_home/victim.json"; printf '{"present":false,"hooks_preexisting":false,"hook_groups":{}}\n' >"$unsafe_state/adapters/claude-prior.json"
jq -nc --arg t "$unsafe_home/victim.json" --arg b "$unsafe_state/adapters/claude-prior.json" \
  '{schema:"afk-adapter-install/3",harness:"claude",phase:"installing",target:$t,backup:$b,command:"c",updater:"u",compact:"p",instruction:"i",prompt:"b",config_preexisting:true}' >"$unsafe_state/adapters/claude.json"
set +e; "$ROOT/adapters/manage.sh" remove claude --home "$unsafe_home" --state-dir "$unsafe_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; unsafe_rc=$?; set -e
eq "redirected recovery target refuses" "$unsafe_rc" 3
eq "redirected recovery leaves victim untouched" "$(<"$unsafe_home/victim.json")" '{"safe":true}'
[[ -f "$unsafe_state/adapters/claude.json" ]] && ok || no "failed recovery retains ownership evidence"
symlink_home="$TMP/recovery-symlink-home"; symlink_state="$TMP/recovery-symlink-state"; mkdir -p "$symlink_home/.claude" "$symlink_state/adapters"
ln -s "$unsafe_home/victim.json" "$symlink_home/.claude/settings.json"; printf '{"present":false,"hooks_preexisting":false,"hook_groups":{}}\n' >"$symlink_state/adapters/claude-prior.json"
jq -nc --arg t "$symlink_home/.claude/settings.json" --arg b "$symlink_state/adapters/claude-prior.json" \
  '{schema:"afk-adapter-install/3",harness:"claude",phase:"installing",target:$t,backup:$b,command:"c",updater:"u",compact:"p",instruction:"i",prompt:"b",config_preexisting:true}' >"$symlink_state/adapters/claude.json"
set +e; "$ROOT/adapters/manage.sh" remove claude --home "$symlink_home" --state-dir "$symlink_state" --adapter-root "$ROOT/adapters" >/dev/null 2>&1; recovery_symlink_rc=$?; set -e
eq "symlink recovery target refuses" "$recovery_symlink_rc" 3
set +e; hermes_out="$(PATH=/usr/bin:/bin "$ROOT/adapters/manage.sh" install hermes --home "$home" --state-dir "$state" --adapter-root "$ROOT/adapters")"; hermes_rc=$?; set -e
eq "Hermes absent code" "$hermes_rc" 4; eq "Hermes absence explicit" "$hermes_out" HARNESS_NOT_INSTALLED:hermes

blind="$(AFK_STATE_DIR="$state" "$ROOT/adapters/hindsight.sh" blind "$ROOT")"
eq "blind review disabled" "$(jq -r .state <<<"$blind")" DISABLED
eq "blind review supported env boundary" "$(jq -r '.environment.HINDSIGHT_DISABLED' <<<"$blind")" true
blind_config="$(jq -r '.environment.HINDSIGHT_CONFIG' <<<"$blind")"
eq "blind config has no token" "$(jq 'has("apiToken")' "$blind_config")" false

blind_poison_bin="$TMP/blind-poison-bin"; blind_poison_marker="$TMP/blind-poisoned"
blind_bash_env="$TMP/blind-bash-env"
mkdir "$blind_poison_bin"
for poison_tool in realpath stat jq mkdir chmod mv; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$0" >>"$AFK_TEST_POISON_MARKER"\nexit 99\n' \
    >"$blind_poison_bin/$poison_tool"
  chmod +x "$blind_poison_bin/$poison_tool"
done
printf '#!/bin/bash -p\nprintf "%%s\\n" "$0" >>"$AFK_TEST_POISON_MARKER"\nexit 99\n' \
  >"$blind_poison_bin/bash"
chmod +x "$blind_poison_bin/bash"
printf 'printf "bash-env\\n" >>"$AFK_TEST_POISON_MARKER"\n' >"$blind_bash_env"
set +e
# shellcheck disable=SC2317 # poison mocks: exported (export -f) to the child,
# which the assertions below prove never calls them; never called here either.
blind_poison="$({
  realpath() { printf 'function-realpath\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  stat() { printf 'function-stat\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  jq() { printf 'function-jq\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  mkdir() { printf 'function-mkdir\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  chmod() { printf 'function-chmod\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  mv() { printf 'function-mv\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  compgen() { printf 'function-compgen\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  mapfile() { printf 'function-mapfile\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  export -f realpath stat jq mkdir chmod mv compgen mapfile
  PATH="$blind_poison_bin:/usr/bin:/bin" AFK_TEST_POISON_MARKER="$blind_poison_marker" \
    BASH_ENV="$blind_bash_env" \
    AFK_STATE_DIR="$TMP/blind-poison-state" "$ROOT/adapters/hindsight.sh" blind "$ROOT"
})"
blind_poison_rc=$?
set -e
eq "blind boundary ignores PATH and imported-function poisoning" \
  "$blind_poison_rc:$(jq -r .state <<<"$blind_poison")" '0:DISABLED'
eq "blind boundary executes no poisoned bootstrap helper" \
  "$([[ -e "$blind_poison_marker" ]] && wc -c <"$blind_poison_marker" || printf 0)" 0

extra_uid_map="$TMP/extra-uid-map"
printf '%s\n' "$EUID 0 1" '0 1000 1' >"$extra_uid_map"
extra_uid_adapter="$TMP/hindsight-extra-uid.sh"
cp "$ROOT/adapters/hindsight.sh" "$extra_uid_adapter"
sed -i "s|readonly UID_MAP_FILE='/proc/self/uid_map'|readonly UID_MAP_FILE='$extra_uid_map'|" \
  "$extra_uid_adapter"
chmod +x "$extra_uid_adapter"
extra_uid_state="$TMP/extra-uid-state"
set +e
AFK_STATE_DIR="$extra_uid_state" "$extra_uid_adapter" blind "$ROOT" \
  >"$TMP/extra-uid.out" 2>"$TMP/extra-uid.err"
extra_uid_rc=$?
set -e
eq "overflow-owner mode rejects a matching uid_map with an extra row" "$extra_uid_rc" 1
if [[ ! -e "$extra_uid_state" ]]; then ok
else no "extra uid_map row is rejected before disabled-state creation"; fi

darwin_user_jq_root="$TMP/darwin-user-jq"; mkdir -p "$darwin_user_jq_root"
darwin_user_jq_marker="$TMP/darwin-user-jq-executed"
printf '#!/usr/bin/env bash\nprintf invoked >%q\nexit 99\n' \
  "$darwin_user_jq_marker" >"$darwin_user_jq_root/jq"
chmod +x "$darwin_user_jq_root/jq"
darwin_hindsight_fixture="$TMP/darwin-hindsight.sh"
cp "$ROOT/adapters/hindsight.sh" "$darwin_hindsight_fixture"
sed -i \
  -e 's|case "${OSTYPE:-}" in|case darwin in|' \
  -e "s|readonly -a JQ_CANDIDATES=(/usr/bin/jq /opt/homebrew/bin/jq /usr/local/bin/jq)|readonly -a JQ_CANDIDATES=('$darwin_user_jq_root/jq')|" \
  -e "s|readonly STAT_STYLE='bsd'|readonly STAT_STYLE='gnu'|" \
  "$darwin_hindsight_fixture"
chmod +x "$darwin_hindsight_fixture"
darwin_hindsight_state="$TMP/darwin-hindsight-state"
set +e
AFK_STATE_DIR="$darwin_hindsight_state" "$darwin_hindsight_fixture" blind "$ROOT" \
  >"$TMP/darwin-hindsight.out" 2>"$TMP/darwin-hindsight.err"
darwin_hindsight_rc=$?
set -e
eq "user-owned Darwin jq is rejected" "$darwin_hindsight_rc" 1
if [[ ! -e "$darwin_user_jq_marker" && ! -e "$darwin_hindsight_state" ]]; then ok
else no "untrusted Darwin jq was neither executed nor allowed to write disabled state"; fi

hindsight="$TMP/hindsight"; mkdir -p "$hindsight/dist"
chmod 755 "$hindsight" "$hindsight/dist"
printf '{"name":"@vectorize-io/hindsight-coding-agents","version":"0.6.0"}\n' >"$hindsight/package.json"
counterfeit_marker="$TMP/counterfeit-hindsight-executed"
counterfeit_marker_json="$(jq -Rn --arg marker "$counterfeit_marker" '$marker')"
printf 'require("fs").writeFileSync(%s, "executed"); console.log(JSON.stringify({bank:"test-bank",chatDocs:20,pagesCount:1,synced:false,apiToken:"NATIVE-DO-NOT-EXPOSE",diagnostic:"not-allowlisted"}))\n' "$counterfeit_marker_json" >"$hindsight/dist/status.js"
printf '{"source":%s}\n' "$(jq -Rn --arg source "$hindsight" '$source')" >"$hindsight/.install-origin.json"
chmod 644 "$hindsight/package.json" "$hindsight/dist/status.js"
printf '{"apiUrl":"http://127.0.0.1:8888","bankId":"test-bank","apiToken":"DO-NOT-EXPOSE"}\n' >"$TMP/hindsight-config.json"
before_hash="$(sha256sum "$TMP/hindsight-config.json" | cut -d' ' -f1)"
printf '{"name":"not-hindsight","version":"0.6.0"}\n' >"$hindsight/package.json"
set +e; unqualified="$(HOME="$home" HINDSIGHT_CODING_AGENTS_HOME="$hindsight" HINDSIGHT_CONFIG="$TMP/hindsight-config.json" "$ROOT/adapters/hindsight.sh" required "$ROOT")"; unqualified_rc=$?; set -e
eq "wrong Hindsight package name is unqualified" "$unqualified_rc:$(jq -r .reason <<<"$unqualified")" '1:MEMORY_RUNTIME_UNQUALIFIED'
printf '{"name":"@vectorize-io/hindsight-coding-agents","version":"0.6.0"}\n' >"$hindsight/package.json"
chmod 644 "$hindsight/package.json"
set +e; counterfeit="$(HOME="$home" HINDSIGHT_CODING_AGENTS_HOME="$hindsight" HINDSIGHT_CONFIG="$TMP/hindsight-config.json" "$ROOT/adapters/hindsight.sh" required "$ROOT")"; counterfeit_rc=$?; set -e
eq "counterfeit Hindsight bytes are unqualified" "$counterfeit_rc:$(jq -r .reason <<<"$counterfeit")" '1:MEMORY_RUNTIME_UNQUALIFIED'
if [[ ! -e "$counterfeit_marker" ]]; then ok; else no "counterfeit Hindsight executable was not run"; fi
if [[ "$counterfeit" != *DO-NOT-EXPOSE* && "$counterfeit" != *NATIVE-DO-NOT-EXPOSE* ]]; then ok; else no "Hindsight token exposed"; fi
eq "Hindsight config unmodified" "$(sha256sum "$TMP/hindsight-config.json" | cut -d' ' -f1)" "$before_hash"

# The positive qualification proof is fully generated, offline, and independent
# of ~/.hindsight. A copied adapter is pinned to this fixture's package and file
# identities at test time; production has no bypass or test-only trust input.
stable_hindsight="$TMP/stable-hindsight"; mkdir -p "$stable_hindsight/dist"
printf '%s\n' '{"name":"@vectorize-io/hindsight-coding-agents","version":"0.6.0","type":"module"}' >"$stable_hindsight/package.json"
printf '%s\n' 'console.log(JSON.stringify({bank:process.env.HOME,chatDocs:2,pagesCount:1,synced:true,apiToken:"NEVER-EXPOSE",diagnostic:"DROP-ME"}))' >"$stable_hindsight/dist/status.js"
chmod 755 "$stable_hindsight" "$stable_hindsight/dist"
chmod 644 "$stable_hindsight/package.json" "$stable_hindsight/dist/status.js"
stable_config="$TMP/stable-hindsight-config.json"
printf '%s\n' '{"apiUrl":"https://fixture.invalid","bankId":"fixture-bank","apiToken":"CONFIG-NEVER-EXPOSE"}' >"$stable_config"
fixture_npm="$TMP/fixture-npm"; mkdir -p "$fixture_npm/home" "$fixture_npm/cache"
fixture_audit="$(env -i PATH=/usr/bin:/bin LANG=C HOME="$fixture_npm/home" \
  npm_config_userconfig="$fixture_npm/user.npmrc" npm_config_globalconfig="$fixture_npm/global.npmrc" \
  npm_config_cache="$fixture_npm/cache" npm_config_offline=true npm_config_update_notifier=false \
  npm_config_audit=false npm_config_fund=false /usr/bin/npm pack --ignore-scripts --dry-run --json "$stable_hindsight")"
fixture_integrity="$(jq -er '.[0].integrity' <<<"$fixture_audit")"
fixture_package_sha="$(sha256sum "$stable_hindsight/package.json")"; fixture_package_sha="${fixture_package_sha%% *}"
fixture_status_sha="$(sha256sum "$stable_hindsight/dist/status.js")"; fixture_status_sha="${fixture_status_sha%% *}"
fixture_adapter="$TMP/hindsight-fixture-adapter.sh"; cp "$ROOT/adapters/hindsight.sh" "$fixture_adapter"
sed -i \
  -e "s|readonly HINDSIGHT_STAGED_INTEGRITY=.*|readonly HINDSIGHT_STAGED_INTEGRITY='$fixture_integrity'|" \
  -e "s|readonly HINDSIGHT_PACKAGE_JSON_SHA256=.*|readonly HINDSIGHT_PACKAGE_JSON_SHA256='$fixture_package_sha'|" \
  -e "s|readonly HINDSIGHT_STATUS_SHA256=.*|readonly HINDSIGHT_STATUS_SHA256='$fixture_status_sha'|" \
  "$fixture_adapter"
chmod +x "$fixture_adapter"

poison_bin="$TMP/hindsight-poison-bin"; poison_marker="$TMP/hindsight-poisoned"; mkdir "$poison_bin"
for poison_tool in realpath stat jq awk env cp chmod mktemp id dirname rm mkdir mv; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$0" >>"$AFK_TEST_POISON_MARKER"\nexit 99\n' >"$poison_bin/$poison_tool"
  chmod +x "$poison_bin/$poison_tool"
done
set +e
# shellcheck disable=SC2317 # poison mocks: exported (export -f) to the child,
# which the assertions below prove never calls them; never called here either.
stable="$({
  realpath() { printf 'function-realpath\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  stat() { printf 'function-stat\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  jq() { printf 'function-jq\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  awk() { printf 'function-awk\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  env() { printf 'function-env\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  cp() { printf 'function-cp\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  chmod() { printf 'function-chmod\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  mktemp() { printf 'function-mktemp\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  id() { printf 'function-id\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  dirname() { printf 'function-dirname\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  export -f realpath stat jq awk env cp chmod mktemp id dirname
  PATH="$poison_bin:/usr/bin:/bin" AFK_TEST_POISON_MARKER="$poison_marker" HOME="$home" \
    HINDSIGHT_CODING_AGENTS_HOME="$stable_hindsight" HINDSIGHT_CONFIG="$stable_config" \
    "$fixture_adapter" required "$ROOT"
})"; stable_rc=$?
set -e
eq "offline staged Hindsight fixture is READY" "$stable_rc:$(jq -r '.state+":"+.reason' <<<"$stable")" '0:READY:MEMORY_READY'
eq "qualified Hindsight status remains allowlisted" "$(jq -c '.status|keys' <<<"$stable")" '["bank","chatDocs","pagesCount","synced"]'
if [[ "$(jq -r '.status.bank' <<<"$stable")" == /tmp/afk-hindsight-integrity.*/home &&
      "$(jq -r '.status.bank' <<<"$stable")" != "$home" ]]; then
  ok
else
  no "qualified Hindsight status receives a private HOME"
fi
if [[ "$stable" != *NEVER-EXPOSE* && "$stable" != *DROP-ME* ]]; then ok; else no "qualified Hindsight output leaked unowned fields"; fi
eq "Hindsight trust chain ignores poisoned ambient helpers" \
  "$([[ -e "$poison_marker" ]] && wc -c <"$poison_marker" || printf 0)" 0

# Exercise the runtime exactly as lifecycle installs it: adapter files at the
# runtime root with managed bin/lib siblings, not paths from this checkout.
installed="$TMP/installed-runtime"; mkdir -p "$installed/bin" "$installed/lib"
cp -R "$ROOT/adapters/." "$installed/"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s\n'\'' '\''{"schema_version":"1.0","kind":"lifecycle_result","source_eligibility":{},"orchestration":{"state":"ACTIVE","session":{}},"dispatch_monitor":{"state":"WATCHING","dispatches":[]}}'\''' >"$installed/bin/agent-flow-kit"; chmod +x "$installed/bin/agent-flow-kit"
AFK_STATUS_BIN='' "$installed/refresh-status-cache.sh" --cache "$TMP/installed-cache.json"
out="$(AFK_STATUS_CACHE="$TMP/installed-cache.json" "$installed/render-status.sh" --harness codex)"
if [[ "$out" == AFK* ]]; then ok; else no "fake installed runtime resolves managed binary"; fi
# A stale file from the older flock implementation is inert; the portable
# directory lock is removed when each refresh finishes.
legacy_cache="$TMP/legacy-lock-cache.json"; : >"$legacy_cache.refresh.lock"
AFK_STATUS_BIN="$installed/bin/agent-flow-kit" "$ROOT/adapters/refresh-status-cache.sh" --cache "$legacy_cache"
if [[ -f "$legacy_cache" && -f "$legacy_cache.refresh.lock" && ! -e "$legacy_cache.refresh.lockdir" ]]; then ok; else no "refresh ignores legacy flock file and releases directory lock"; fi
AFK_STATUS_BIN="$installed/bin/agent-flow-kit" AFK_STATUS_REFRESH_SECONDS=0 "$ROOT/adapters/refresh-status-cache.sh" --cache "$legacy_cache"
if [[ -f "$legacy_cache" && ! -e "$legacy_cache.refresh.lockdir" ]]; then ok; else no "released directory lock remains reusable"; fi
lock_victim="$TMP/lock-victim"; printf 'DO-NOT-TRUNCATE\n' >"$lock_victim"; symlink_cache="$TMP/symlink-cache.json"; ln -s "$lock_victim" "$symlink_cache.refresh.lockdir"
set +e; AFK_STATUS_BIN="$installed/bin/agent-flow-kit" "$ROOT/adapters/refresh-status-cache.sh" --cache "$symlink_cache" >/dev/null 2>&1; symlink_lock_rc=$?; set -e
eq "symlink refresh lock refuses" "$symlink_lock_rc" 1
eq "symlink refresh lock target is not truncated" "$(<"$lock_victim")" DO-NOT-TRUNCATE
fifo_cache="$TMP/fifo-cache.json"; mkfifo "$fifo_cache.refresh.lockdir"
set +e; AFK_STATUS_BIN="$installed/bin/agent-flow-kit" "$ROOT/adapters/refresh-status-cache.sh" --cache "$fifo_cache" >/dev/null 2>&1; fifo_lock_rc=$?; set -e
eq "non-regular refresh lock refuses without opening" "$fifo_lock_rc" 1
busy_cache="$TMP/busy-cache.json"; mkdir -p "$busy_cache.refresh.lockdir"; printf '%s live\n' "$$" >"$busy_cache.refresh.lockdir/owner"
AFK_STATUS_BIN="$installed/bin/agent-flow-kit" "$ROOT/adapters/refresh-status-cache.sh" --cache "$busy_cache"
[[ ! -e "$busy_cache" ]] && ok || no "concurrent refresh lock runs no producer"
stale_refresh_cache="$TMP/stale-refresh-cache.json"; mkdir -p "$stale_refresh_cache.refresh.lockdir"; printf '2147483647 live\n' >"$stale_refresh_cache.refresh.lockdir/owner"
AFK_STATUS_BIN="$installed/bin/agent-flow-kit" "$ROOT/adapters/refresh-status-cache.sh" --cache "$stale_refresh_cache"
if [[ -f "$stale_refresh_cache" && ! -e "$stale_refresh_cache.refresh.lockdir" ]]; then ok; else no "refresh reclaims dead owner lock"; fi

race_refresh_cache="$TMP/race-refresh-cache.json"; race_refresh_lock="$race_refresh_cache.refresh.lockdir"; race_refresh_owner="$race_refresh_lock/owner"
PATH="$lock_race_bin:$PATH" AFK_RACE_LOCK="$race_refresh_lock" AFK_RACE_OWNER="$race_refresh_owner" AFK_RACE_ROLE=refresh-first AFK_RACE_DIR="$lock_race_dir" \
  AFK_STATUS_BIN="$installed/bin/agent-flow-kit" "$ROOT/adapters/refresh-status-cache.sh" --cache "$race_refresh_cache" >/dev/null 2>&1 & refresh_first_pid=$!
for _ in $(seq 1 500); do [[ -e "$lock_race_dir/refresh-first-root" ]] && break; /bin/sleep 0.01; done
TZ=Pacific/Honolulu PATH="$lock_race_bin:$PATH" AFK_RACE_LOCK="$race_refresh_lock" AFK_RACE_OWNER="$race_refresh_owner" AFK_RACE_ROLE=refresh-second AFK_RACE_DIR="$lock_race_dir" \
  AFK_STATUS_BIN="$installed/bin/agent-flow-kit" "$ROOT/adapters/refresh-status-cache.sh" --cache "$race_refresh_cache" >/dev/null 2>&1 & refresh_second_pid=$!
for _ in $(seq 1 500); do [[ -e "$lock_race_dir/refresh-second-owned" ]] && break; /bin/sleep 0.01; done
: >"$lock_race_dir/refresh-first-release-root"
wait "$refresh_first_pid"
[[ ! -e "$race_refresh_cache" ]] && ok || no "refresh initialization contender runs no producer"
eq "refresh publishes one complete owner" "$(<"$race_refresh_owner")" "$refresh_second_pid $(sed -n 's/^[0-9][0-9]* //p' "$race_refresh_owner")"
refresh_owner_before="$(<"$race_refresh_owner")"
TZ=Asia/Tokyo AFK_STATUS_BIN="$installed/bin/agent-flow-kit" "$ROOT/adapters/refresh-status-cache.sh" --cache "$race_refresh_cache"
[[ ! -e "$race_refresh_cache" ]] && ok || no "mixed-TZ refresh contender ran producer"
eq "mixed-TZ refresh contender cannot replace owner" "$(<"$race_refresh_owner")" "$refresh_owner_before"
: >"$lock_race_dir/refresh-second-release-owner"; wait "$refresh_second_pid"
[[ -f "$race_refresh_cache" ]] && ok || no "refresh atomic owner wins alone"

candidate_refresh_cache="$TMP/candidate-refresh-cache.json"; candidate_refresh_victim="$TMP/candidate-refresh-victim"
printf 'REFRESH-VICTIM\n' >"$candidate_refresh_victim"
set +e
PATH="$candidate_swap_bin:$PATH" AFK_SWAP_CANDIDATE_PREFIX="$candidate_refresh_cache.refresh.lockdir.candidate." \
  AFK_SWAP_CANDIDATE_MARKER="$TMP/candidate-refresh-swapped" AFK_SWAP_CANDIDATE_VICTIM="$candidate_refresh_victim" \
  AFK_STATUS_BIN="$installed/bin/agent-flow-kit" "$ROOT/adapters/refresh-status-cache.sh" --cache "$candidate_refresh_cache" >/dev/null 2>&1
candidate_refresh_rc=$?
set -e
eq "swapped refresh owner candidate refuses" "$candidate_refresh_rc" 1
[[ -e "$TMP/candidate-refresh-swapped" ]] && ok || no "refresh owner candidate swap fixture did not execute"
eq "swapped refresh owner candidate cannot truncate victim" "$(<"$candidate_refresh_victim")" REFRESH-VICTIM

killed_refresh_cache="$TMP/killed-refresh-cache.json"; killed_refresh_lock="$killed_refresh_cache.refresh.lockdir"; killed_refresh_owner="$killed_refresh_lock/owner"
PATH="$lock_race_bin:$PATH" AFK_RACE_LOCK="$killed_refresh_lock" AFK_RACE_OWNER="$killed_refresh_owner" AFK_RACE_ROLE=refresh-killed AFK_RACE_DIR="$lock_race_dir" \
  AFK_STATUS_BIN="$installed/bin/agent-flow-kit" "$ROOT/adapters/refresh-status-cache.sh" --cache "$killed_refresh_cache" >/dev/null 2>&1 & killed_refresh_pid=$!
for _ in $(seq 1 500); do [[ -e "$lock_race_dir/refresh-killed-owned" ]] && break; /bin/sleep 0.01; done
kill -9 "$killed_refresh_pid" 2>/dev/null || true
: >"$lock_race_dir/refresh-killed-release-owner"
set +e; wait "$killed_refresh_pid" 2>/dev/null; set -e
AFK_STATUS_BIN="$installed/bin/agent-flow-kit" "$ROOT/adapters/refresh-status-cache.sh" --cache "$killed_refresh_cache"
[[ -f "$killed_refresh_cache" ]] && ok || no "refresh reclaims complete claim after SIGKILL"

# Simulate stock macOS command behavior: flock and realpath are unavailable,
# while stat supports BSD -f formats but rejects GNU flags.
portable_bin="$TMP/portable-bin"; mkdir -p "$portable_bin"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'printf called >"$AFK_PORTABLE_FLOCK_MARKER"; exit 127' >"$portable_bin/flock"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'printf called >"$AFK_PORTABLE_REALPATH_MARKER"; exit 127' >"$portable_bin/realpath"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
  'if [[ "$1" == -f && "$2" == "%d:%i" ]]; then exec /usr/bin/stat -c "%d:%i" "$3"; fi' \
  'if [[ "$1" == -f && "$2" == "%m" ]]; then exec /usr/bin/stat -c "%Y" "$3"; fi' \
  'exit 64' >"$portable_bin/stat"
chmod +x "$portable_bin/flock" "$portable_bin/realpath" "$portable_bin/stat"
portable_home="$TMP/portable-home"; portable_state="$TMP/portable-state"; mkdir -p "$portable_home/.claude"
printf '{"owner":true}\n' >"$portable_home/.claude/settings.json"
"$ROOT/adapters/manage.sh" install claude --home "$portable_home" --state-dir "$portable_state" --adapter-root "$ROOT/adapters" >/dev/null
jq '.phase="installing"' "$portable_state/adapters/claude.json" >"$TMP/portable-record.json"; mv "$TMP/portable-record.json" "$portable_state/adapters/claude.json"
PATH="$portable_bin:$PATH" AFK_PORTABLE_FLOCK_MARKER="$TMP/portable-flock-called" AFK_PORTABLE_REALPATH_MARKER="$TMP/portable-realpath-called" \
  "$ROOT/adapters/manage.sh" remove claude --home "$portable_home" --state-dir "$portable_state" --adapter-root "$ROOT/adapters" >/dev/null || no "BSD-stat manager recovery"
eq "BSD-stat manager recovery restores config" "$(jq -r .owner "$portable_home/.claude/settings.json")" true
portable_cache="$TMP/portable-cache.json"; cp "$TMP/status.json" "$portable_cache"; touch -d '@100' "$portable_cache"
PATH="$portable_bin:$PATH" AFK_PORTABLE_FLOCK_MARKER="$TMP/portable-flock-called" AFK_PORTABLE_REALPATH_MARKER="$TMP/portable-realpath-called" \
  AFK_STATUS_BIN="$installed/bin/agent-flow-kit" AFK_STATUS_REFRESH_SECONDS=0 "$ROOT/adapters/refresh-status-cache.sh" --cache "$portable_cache"
[[ -f "$portable_cache" ]] && ok || no "BSD-stat refresh succeeds"
[[ ! -e "$TMP/portable-flock-called" && ! -e "$TMP/portable-realpath-called" ]] && ok || no "portable locks invoked unavailable flock or realpath"
# The status producer must not inherit a stale descriptor from lock handling.
fd_probe="$TMP/fd-probe"; fd_seen="$TMP/fd-seen"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' '[[ ! -e /proc/$$/fd/9 ]] || printf inherited >"$AFK_FD_SEEN"' \
  'printf '\''{"schema_version":"1.0","kind":"lifecycle_result","orchestration":{},"dispatch_monitor":{}}\n'\''' >"$fd_probe"; chmod +x "$fd_probe"
AFK_FD_SEEN="$fd_seen" AFK_STATUS_BIN="$fd_probe" "$ROOT/adapters/refresh-status-cache.sh" --cache "$TMP/fd-cache.json"
[[ ! -e "$fd_seen" ]] && ok || no "refresh child inherits no flock descriptor"
if bash -c '. "$1"; afk_component_exists afk-runtime-bin && afk_component_exists afk-runtime-lib && afk_component_exists afk-runtime-release-policy' _ "$ROOT/lib/afk-inventory.sh"; then ok; else no "runtime executable, libs and release policy declared in lifecycle inventory"; fi

# Replacing only the parent adapter tree must not erase its independently
# managed bin/lib children.
src_tree="$TMP/runtime-src"; dst_tree="$TMP/runtime-dst"; stage_tree="$TMP/runtime-stage"
mkdir -p "$src_tree" "$dst_tree/bin" "$dst_tree/lib" "$dst_tree/lifecycle" "$stage_tree"
printf 'adapter-v2\n' >"$src_tree/README"; printf 'adapter-v1\n' >"$dst_tree/README"
printf 'bin-owned\n' >"$dst_tree/bin/agent-flow-kit"; printf 'lib-owned\n' >"$dst_tree/lib/afk-common.sh"
printf 'policy-owned\n' >"$dst_tree/lifecycle/release-policy.json"
if bash -c '. "$1"; . "$2"; AFK_OP_STAGE_DIR="$5"; afk_write_managed_tree "$3" "$4" "bin,lib,lifecycle"' \
  _ "$ROOT/lib/afk-common.sh" "$ROOT/lib/afk-mutate.sh" "$src_tree" "$dst_tree" "$stage_tree"; then
  eq "adapter-only replacement updates adapter" "$(<"$dst_tree/README")" adapter-v2
  eq "adapter-only replacement preserves runtime bin" "$(<"$dst_tree/bin/agent-flow-kit")" bin-owned
  eq "adapter-only replacement preserves runtime lib" "$(<"$dst_tree/lib/afk-common.sh")" lib-owned
  eq "adapter-only replacement preserves release policy" "$(<"$dst_tree/lifecycle/release-policy.json")" policy-owned
else
  no "adapter-only replacement"
fi

set +e
"$ROOT/bin/afk-release-reconcile" --source "$TMP/empty-source" --revision aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --state-dir "$TMP/release-state" --plan >/dev/null 2>&1
release_rc=$?
set -e
eq "release source and revision are AFK-owned, not caller supplied" "$release_rc" 2

if yq -o=json '.' "$ROOT/files/model-router/harness-bindings.yaml" | jq -e '.schema=="afk-harness-bindings/1" and ([.bindings[]|select(.harness=="opencode")]|length)==2' >/dev/null; then ok; else no "OpenCode bindings"; fi

# Fake Orca supplies exact worktree/run identity and records terminal effects.
fake_orca="$TMP/orca"; orca_terminals="$TMP/orca-terminals.json"; orca_bound="$TMP/orca-bound.json"
printf '[]\n' >"$orca_terminals"; printf '[]\n' >"$orca_bound"
# shellcheck disable=SC2016
{
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' '[[ "${1:-}" != --version ]] || { echo 1.4.216; exit 0; }'
  # List and show answers carry the runtime id, as Orca's do (AFK_FAKE_RUNTIME_ID, default runtime-a).
  printf '%s\n' 'if [[ -z "${AFK_FAKE_META_INNER:-}" && ( "$1 $2" == "terminal list" || "$1 $2" == "terminal show" ) ]]; then rc=0; out="$(AFK_FAKE_META_INNER=1 "$0" "$@")" || rc=$?; if jq -e '\''type=="object"'\'' <<<"$out" >/dev/null 2>&1; then jq -c --arg rt "${AFK_FAKE_RUNTIME_ID:-runtime-a}" '\''. + {_meta:{runtimeId:$rt}}'\'' <<<"$out"; else printf "%s" "$out"; fi; exit "$rc"; fi'
  printf '%s\n' 'printf "%s\n" "$*" >>"$AFK_FAKE_ORCA_LOG"'
  printf '%s\n' 'if [[ "$1 $2" == "worktree show" ]]; then if [[ -n "${AFK_FAKE_WORKTREE_SHOW_JSON:-}" ]]; then printf "%s\n" "$AFK_FAKE_WORKTREE_SHOW_JSON"; exit "${AFK_FAKE_WORKTREE_SHOW_RC:-0}"; fi; jq -nc --arg p "$AFK_FAKE_WORKTREE_PATH" --arg id "${AFK_FAKE_WORKTREE_ID:-child-worktree-id}" '\''{result:{worktree:{id:$id,path:$p}}}'\''; exit; fi'
  printf '%s\n' 'if [[ "$1 $2" == "orchestration run-current" ]]; then [[ -n "${AFK_FAKE_RUN_ID:-}" ]] || exit 1; jq -nc --arg id "$AFK_FAKE_RUN_ID" '\''{result:{run:{id:$id}}}'\''; exit; fi'
  printf '%s\n' 'if [[ "$1 $2" == "orchestration run-use" ]]; then id=""; terminal=""; while (($#)); do case "$1" in --id) id="$2"; shift 2;; --from) terminal="$2"; shift 2;; *) shift;; esac; done; jq -nc --arg id "$id" --arg t "$terminal" '\''{result:{run:{id:$id},coordinatorTerminalHandle:$t}}'\''; exit; fi'
  printf '%s\n' 'if [[ "$1 $2" == "terminal list" ]]; then if [[ -n "${AFK_FAKE_TERMINAL_LIST_JSON:-}" ]]; then printf "%s\n" "$AFK_FAKE_TERMINAL_LIST_JSON"; elif [[ "${AFK_FAKE_HIDE_TERMINALS:-0}" == 1 ]]; then jq -nc '\''{result:{terminals:[]}}'\''; elif [[ -n "${AFK_FAKE_FAIL_EMPTY_LIST_ONCE:-}" && ! -e "$AFK_FAKE_FAIL_EMPTY_LIST_ONCE" ]] && jq -e '\''length==0'\'' "$AFK_FAKE_TERMINALS" >/dev/null; then : >"$AFK_FAKE_FAIL_EMPTY_LIST_ONCE"; exit 1; else jq -nc --slurpfile ts "$AFK_FAKE_TERMINALS" '\''{result:{terminals:$ts[0]}}'\''; fi; exit; fi'
  printf '%s\n' 'if [[ "$1 $2" == "terminal show" ]]; then target=""; while (($#)); do case "$1" in --terminal) target="$2"; shift 2;; *) shift;; esac; done; if [[ -n "${AFK_FAKE_SHOW_COUNT:-}" ]]; then n="$(<"$AFK_FAKE_SHOW_COUNT")"; printf "%s\n" "$((n+1))" >"$AFK_FAKE_SHOW_COUNT"; if [[ "${AFK_FAKE_REVIVE_ON_SECOND_SHOW:-0}" == 1 && "$n" == 1 ]]; then jq --arg t "$target" '\''map(if .handle==$t then .connected=true|.status="running" else . end)'\'' "$AFK_FAKE_BOUND" >"$AFK_FAKE_BOUND.tmp"; mv "$AFK_FAKE_BOUND.tmp" "$AFK_FAKE_BOUND"; cp "$AFK_FAKE_BOUND" "$AFK_FAKE_TERMINALS"; fi; fi; if [[ -n "${AFK_FAKE_TERMINAL_SHOW_JSON:-}" ]]; then printf "%s\n" "$AFK_FAKE_TERMINAL_SHOW_JSON"; exit "${AFK_FAKE_TERMINAL_SHOW_RC:-0}"; fi; [[ "${AFK_FAKE_SHOW_TIMEOUT:-0}" != 1 ]] || exit 124; if jq -e --arg t "$target" '\''any(.[]; .handle==$t)'\'' "$AFK_FAKE_BOUND" >/dev/null; then jq -ec --arg t "$target" '\''[.[]|select(.handle==$t)]|{result:{terminal:.[0]}}'\'' "$AFK_FAKE_BOUND"; elif [[ "${AFK_FAKE_SHOW_TIMEOUT_WHEN_ABSENT:-0}" == 1 ]]; then exit 124; else jq -nc --arg t "$target" '\''{ok:false,error:{code:"terminal_handle_stale",message:("released terminal handle: "+$t)}}'\''; exit 1; fi; exit; fi'
  printf '%s\n' 'if [[ "$1 $2" == "terminal create" ]]; then title=""; command=""; handle="${AFK_FAKE_CREATE_HANDLE:-new-terminal}"; while (($#)); do case "$1" in --title) title="$2"; shift 2;; --command) command="$2"; shift 2;; *) shift;; esac; done; jq --arg handle "$handle" --arg title "$title" --arg wi "${AFK_FAKE_WORKTREE_ID:-child-worktree-id}" --arg wp "$AFK_FAKE_WORKTREE_PATH" '\''.+[{handle:$handle,title:$title,status:"running",connected:true,orphaned:false,worktreeId:$wi,worktreePath:$wp}]'\'' "$AFK_FAKE_TERMINALS" >"$AFK_FAKE_TERMINALS.tmp"; mv "$AFK_FAKE_TERMINALS.tmp" "$AFK_FAKE_TERMINALS"; cp "$AFK_FAKE_TERMINALS" "$AFK_FAKE_BOUND"; printf "%s" "$command" >"$AFK_FAKE_COMMAND"; [[ "${AFK_FAKE_CREATE_CRASH_AFTER_EFFECT:-0}" != 1 ]] || exit 97; jq -nc --arg handle "$handle" '\''{result:{terminal:{handle:$handle}}}'\''; exit; fi'
  printf '%s\n' 'if [[ "$1 $2" == "terminal close" ]]; then target=""; while (($#)); do case "$1" in --terminal) target="$2"; shift 2;; *) shift;; esac; done; jq --arg t "$target" '\''map(select(.handle!=$t))'\'' "$AFK_FAKE_TERMINALS" >"$AFK_FAKE_TERMINALS.tmp"; mv "$AFK_FAKE_TERMINALS.tmp" "$AFK_FAKE_TERMINALS"; jq --arg t "$target" '\''map(select(.handle!=$t))'\'' "$AFK_FAKE_BOUND" >"$AFK_FAKE_BOUND.tmp"; mv "$AFK_FAKE_BOUND.tmp" "$AFK_FAKE_BOUND"; jq -nc '\''{ok:true}'\''; exit; fi' 'exit 1'
} >"$fake_orca"; chmod +x "$fake_orca"
# The fake reaches the adapters only through the resolver's host config.
printf '{"orca_bin":"%s"}\n' "$fake_orca" >"$TMP/orca-host.json"
orca_env=(AFK_HOST_CONFIG="$TMP/orca-host.json" AFK_STATE_DIR="$state" AFK_FAKE_ORCA_LOG="$TMP/orca-log" AFK_FAKE_WORKTREE_PATH="$ROOT" AFK_FAKE_TERMINALS="$orca_terminals" AFK_FAKE_BOUND="$orca_bound" AFK_FAKE_COMMAND="$TMP/orca-command")

# Exercise the installed public PM entrypoint, not only its adapter. The command
# must write the exact registration intent and identify itself in the lifecycle
# result coordinators consume.
public_pm="$TMP/public-pm"; public_pm_state="$TMP/public-pm-state"; mkdir -p "$public_pm"
env -u CODEX_THREAD_ID "${orca_env[@]}" HOME="$home" AFK_STATE_DIR="$public_pm_state" AFK_PM_DIR="$public_pm" \
  AFK_PM_SESSION_ADAPTER="$ROOT/adapters/pm-session.sh" ORCA_TERMINAL_HANDLE=public-pm-terminal \
  "$ROOT/bin/agent-flow-kit" pm-start --harness codex --json >"$TMP/public-pm-result.json" \
  || no "public pm-start succeeds"
eq "public pm-start writes the registration intent" \
  "$(jq -r '.schema+":"+.harness+":"+.terminal' "$public_pm/registration-intent.json")" \
  'afk-pm-registration-intent/1:codex:public-pm-terminal'
eq "public pm-start emits its lifecycle command" \
  "$(jq -r '.command+":"+.extra.pm_registration.state' "$TMP/public-pm-result.json")" \
  'pm-start:WAITING_FOR_EXACT_SESSION_EVENT'

# Initial ownership always needs a fresh, explicit pm-start intent. Ambient
# parent worktree ids are ignored, and an unlocked stale flock file is harmless.
for harness in claude codex opencode; do
  reg="$TMP/register-$harness"; mkdir -p "$reg"; : >"$reg/.publisher.lock"
  env "${orca_env[@]}" AFK_PM_DIR="$reg" ORCA_TERMINAL_HANDLE="terminal-$harness" ORCA_WORKTREE_ID=wrong-parent \
    "$ROOT/adapters/pm-session.sh" start --harness "$harness" || no "$harness pm-start intent"
  if [[ "$harness" == claude ]]; then
    jq -nc '{session_id:"session-claude",context_window:{context_window_size:200000,used_percentage:12}}' >"$TMP/pm-claude.json"
    env "${orca_env[@]}" AFK_PM_DIR="$reg" ORCA_TERMINAL_HANDLE="terminal-$harness" ORCA_WORKTREE_ID=wrong-parent \
      "$ROOT/adapters/pm-session.sh" observe --harness claude --input "$TMP/pm-claude.json"
    eq "Claude percent-derived PM occupancy" "$(jq -r '.usage_tokens|tostring' "$reg/usage.json")" 24000
  else
    env "${orca_env[@]}" AFK_PM_DIR="$reg" ORCA_TERMINAL_HANDLE="terminal-$harness" ORCA_WORKTREE_ID=wrong-parent \
      "$ROOT/adapters/pm-session.sh" observe --harness "$harness" --session "session-$harness"
  fi
  eq "$harness exact PM registration" "$(jq -r '.harness+":"+.worktree.id' "$reg/ownership.json")" "$harness:child-worktree-id"
  eq "$harness manual registration leaves launch unverified" \
    "$(jq -r '.control.execution_profile+":"+.control.control_owner+":"+.control.approval_channel+":"+.control.launch_provenance.status' "$reg/ownership.json")" \
    'unverified:human:unverified:unverified'
  registered_session="$(jq -r .session "$reg/ownership.json")"
  eq "$harness registration binds exact session and worktree" \
    "$(jq -r '.control.provenance.owner.session+":"+.control.provenance.owner.worktree.id' "$reg/ownership.json")" \
    "$registered_session:child-worktree-id"
  before_control="$(jq -c .control "$reg/ownership.json")"
  env "${orca_env[@]}" AFK_PM_DIR="$reg" ORCA_TERMINAL_HANDLE="terminal-$harness" \
    "$ROOT/adapters/pm-session.sh" observe --harness "$harness" --session "$registered_session"
  eq "$harness repeat observation preserves control" "$(jq -c .control "$reg/ownership.json")" "$before_control"
done
pm_status="$(env HOME="$home" AFK_STATE_DIR="$state" AFK_PM_DIR="$reg" "$ROOT/bin/agent-flow-kit" status --json 2>/dev/null || true)"
eq "status projects the same registered control" \
  "$(jq -Sc '.extra.pm_control.control' <<<"$pm_status")" "$(jq -Sc .control "$reg/ownership.json")"
cp "$reg/ownership.json" "$TMP/valid-pm-owner.json"
jq 'del(.control) | .role="worker"' "$reg/ownership.json" >"$TMP/invalid-owner.json"
mv "$TMP/invalid-owner.json" "$reg/ownership.json"
if pm_status="$(env HOME="$home" AFK_STATE_DIR="$state" AFK_PM_DIR="$reg" "$ROOT/bin/agent-flow-kit" status --json 2>/dev/null)"; then
  pm_status_rc=0
else
  pm_status_rc=$?
fi
eq "non-PM legacy row has invalid control state" \
  "$(jq -r '.extra.pm_control.state+":"+.extra.pm_control.reason' <<<"$pm_status")" 'invalid:PM_CONTROL_INVALID'
eq "non-PM legacy row requires owner action" "$pm_status_rc" 2
cp "$TMP/valid-pm-owner.json" "$reg/ownership.json"
jq '.control.revision=null' "$reg/ownership.json" >"$TMP/invalid-control.json"
mv "$TMP/invalid-control.json" "$reg/ownership.json"
if pm_status="$(env HOME="$home" AFK_STATE_DIR="$state" AFK_PM_DIR="$reg" "$ROOT/bin/agent-flow-kit" status --json 2>/dev/null)"; then
  pm_status_rc=0
else
  pm_status_rc=$?
fi
eq "status names malformed supplied control" \
  "$(jq -r '.extra.pm_control.state+":"+.extra.pm_control.reason' <<<"$pm_status")" 'invalid:PM_CONTROL_INVALID'
eq "malformed control status exits with reported owner action" \
  "$pm_status_rc:$(jq -r '.overall.exit_code' <<<"$pm_status")" '2:2'
eq "malformed control status includes finding" \
  "$(jq -r '[.findings[].reason]|index("PM_CONTROL_INVALID")!=null' <<<"$pm_status")" true
bad_control_hash="$(sha256sum "$reg/ownership.json")"
env "${orca_env[@]}" AFK_PM_DIR="$reg" ORCA_TERMINAL_HANDLE=terminal-opencode \
  "$ROOT/adapters/pm-session.sh" observe --harness opencode --session session-opencode
eq "observation does not repair null revision" "$(sha256sum "$reg/ownership.json")" "$bad_control_hash"
jq '.control.revision=0|del(.control.provenance.owner.session)' "$reg/ownership.json" >"$TMP/invalid-control.json"
mv "$TMP/invalid-control.json" "$reg/ownership.json"
bad_control_hash="$(sha256sum "$reg/ownership.json")"
env "${orca_env[@]}" AFK_PM_DIR="$reg" ORCA_TERMINAL_HANDLE=terminal-opencode \
  "$ROOT/adapters/pm-session.sh" observe --harness opencode --session session-opencode
eq "observation does not repair missing identity binding" "$(sha256sum "$reg/ownership.json")" "$bad_control_hash"
worker_pm="$TMP/worker-pm"; mkdir -p "$worker_pm"
env AFK_PM_DIR="$worker_pm" ORCA_TERMINAL_HANDLE=worker "$ROOT/adapters/pm-session.sh" observe --harness codex --session worker-session
if [[ ! -e "$worker_pm/ownership.json" ]]; then ok; else no "ordinary worker self-registered as PM"; fi
stale_pm="$TMP/stale-pm"; mkdir -p "$stale_pm"
env "${orca_env[@]}" AFK_PM_DIR="$stale_pm" ORCA_TERMINAL_HANDLE=stale "$ROOT/adapters/pm-session.sh" start --harness opencode
jq '.created_epoch=1' "$stale_pm/registration-intent.json" >"$stale_pm/i"; mv "$stale_pm/i" "$stale_pm/registration-intent.json"
env AFK_PM_DIR="$stale_pm" ORCA_TERMINAL_HANDLE=stale "$ROOT/adapters/pm-session.sh" observe --harness opencode --session stale
if [[ ! -e "$stale_pm/ownership.json" ]]; then ok; else no "stale registration intent was accepted"; fi

# The real Orca launcher uses a transition title, reuses it on replay, and its
# command contains only the fixed bootstrap plus intent path (resume is data).
launch_pm="$TMP/launch-pm"; mkdir -p "$launch_pm"
jq -nc --arg p "$ROOT" --arg pm "$launch_pm" '{schema:"afk-pm-bootstrap-intent/1",transition_id:"pm-launch",harness:"codex",resume_instruction:"$(touch /tmp/never)",continuation_sha256:"sha256:launch",worktree:{id:"child-worktree-id",path:$p},run_id:null,pm_dir:$pm}' >"$launch_pm/intent.json"
conflicting_worktree_shows=(
  "$(jq -nc --arg p "$ROOT" '{ok:false,result:{worktree:{id:"child-worktree-id",path:$p}}}')"
  "$(jq -nc --arg p "$ROOT" '{ok:true,error:{code:"worktree_show_failed"},result:{worktree:{id:"child-worktree-id",path:$p}}}')"
)
before_worktree_conflict_creates="$(grep -c '^terminal create ' "$TMP/orca-log" || true)"
for conflicting_worktree_show in "${conflicting_worktree_shows[@]}"; do
  if env "${orca_env[@]}" AFK_FAKE_WORKTREE_SHOW_JSON="$conflicting_worktree_show" \
    "$ROOT/adapters/orca-pm-successor.sh" "$launch_pm/intent.json" pm-launch >/dev/null 2>&1; then
    no "successor rejects a conflicting worktree-show envelope"
  else ok "successor rejects a conflicting worktree-show envelope"; fi
done
eq "conflicting successor worktree show cannot create a terminal" \
  "$(grep -c '^terminal create ' "$TMP/orca-log" || true)" "$before_worktree_conflict_creates"
env "${orca_env[@]}" "$ROOT/adapters/orca-pm-successor.sh" "$launch_pm/intent.json" pm-launch >/dev/null
env "${orca_env[@]}" AFK_FAKE_HIDE_TERMINALS=1 "$ROOT/adapters/orca-pm-successor.sh" "$launch_pm/intent.json" pm-launch >/dev/null
eq "receipt-backed successor survives a lagging scoped list without duplication" "$(jq 'length' "$orca_terminals")" 1
before_successor_validation_creates="$(grep -c '^terminal create ' "$TMP/orca-log" || true)"
successor_bad_lists=(
  '{}'
  '{"ok":false,"error":{"code":"terminal_list_failed"},"result":{"terminals":[]}}'
  '{"result":{"terminals":{}}}'
  '{"result":{"terminals":[{}]}}'
  '{"result":{"terminals":[{"handle":"bad"}]}}'
  '{"result":{"terminals":[{"handle":"bad","title":null}]}}'
  '{"result":{"terminals":[{"handle":"bad","title":7}]}}'
)
for successor_bad_list in "${successor_bad_lists[@]}"; do
  if env "${orca_env[@]}" AFK_FAKE_TERMINAL_LIST_JSON="$successor_bad_list" \
    "$ROOT/adapters/orca-pm-successor.sh" "$launch_pm/intent.json" pm-launch >/dev/null 2>&1; then
    no "successor reconciliation refuses malformed terminal list"
  else ok "successor reconciliation refuses malformed terminal list"; fi
done
eq "malformed successor lists cannot create a terminal" "$(grep -c '^terminal create ' "$TMP/orca-log" || true)" "$before_successor_validation_creates"
conflicting_successor_shows=(
  "$(jq -nc --slurpfile ts "$orca_bound" '{ok:false,result:{terminal:$ts[0][0]}}')"
  "$(jq -nc --slurpfile ts "$orca_bound" '{ok:true,error:{code:"terminal_show_failed"},result:{terminal:$ts[0][0]}}')"
)
for conflicting_successor_show in "${conflicting_successor_shows[@]}"; do
  if env "${orca_env[@]}" AFK_FAKE_TERMINAL_SHOW_JSON="$conflicting_successor_show" \
    "$ROOT/adapters/orca-pm-successor.sh" "$launch_pm/intent.json" pm-launch >/dev/null 2>&1; then
    no "successor rejects a conflicting terminal-show envelope"
  else ok "successor rejects a conflicting terminal-show envelope"; fi
done
eq "conflicting successor show cannot create a terminal" "$(grep -c '^terminal create ' "$TMP/orca-log" || true)" "$before_successor_validation_creates"
cp "$launch_pm/transitions/pm-launch/launch-create.json" "$TMP/launch-create.saved"
rm -f -- "$launch_pm/transitions/pm-launch/launch-create.json"
before_lagged_create_count="$(grep -c '^terminal create ' "$TMP/orca-log" || true)"
if env "${orca_env[@]}" AFK_FAKE_HIDE_TERMINALS=1 "$ROOT/adapters/orca-pm-successor.sh" "$launch_pm/intent.json" pm-launch >/dev/null 2>&1; then
  no "attempted successor refuses a lagging empty scoped list"
else ok "attempted successor refuses a lagging empty scoped list"; fi
eq "lagging empty list cannot duplicate a successor" "$(grep -c '^terminal create ' "$TMP/orca-log" || true)" "$before_lagged_create_count"
if [[ "$(<"$TMP/orca-command")" != *'touch /tmp/never'* && "$(<"$TMP/orca-command")" == *orca-pm-bootstrap.sh* ]]; then ok; else no "successor used free-form resume command"; fi
if env "${orca_env[@]}" AFK_FAKE_WORKTREE_ID=other-worktree "$ROOT/adapters/orca-pm-successor.sh" "$launch_pm/intent.json" pm-launch >/dev/null 2>&1; then
  no "successor refuses copied worktree identity"
else ok "successor refuses copied worktree identity"; fi
cp "$TMP/launch-create.saved" "$launch_pm/transitions/pm-launch/launch-create.json"
before_create_count="$(grep -c '^terminal create ' "$TMP/orca-log" || true)"
jq '.[0].status="exited"|.[0].connected=false' "$orca_terminals" >"$orca_terminals.tmp"; mv "$orca_terminals.tmp" "$orca_terminals"; cp "$orca_terminals" "$orca_bound"
successor_show_count="$TMP/successor-show-count"; printf '0\n' >"$successor_show_count"
before_race_closes="$(grep -c '^terminal close ' "$TMP/orca-log" || true)"
if env "${orca_env[@]}" AFK_FAKE_SHOW_COUNT="$successor_show_count" AFK_FAKE_REVIVE_ON_SECOND_SHOW=1 \
  "$ROOT/adapters/orca-pm-successor.sh" "$launch_pm/intent.json" pm-launch >/dev/null 2>&1; then
  no "successor replacement refuses a dead-to-live race"
else ok "successor replacement refuses a dead-to-live race"; fi
eq "dead-to-live successor race never reaches global close" \
  "$(grep -c '^terminal close ' "$TMP/orca-log" || true)" "$before_race_closes"
if [[ ! -e "$launch_pm/transitions/pm-launch/replacement-close-binding.json" ]]; then
  ok "dead-to-live successor race persists no replacement authority"
else no "dead-to-live successor race persists no replacement authority"; fi
jq '.[0].status="exited"|.[0].connected=false' "$orca_terminals" >"$orca_terminals.tmp"; mv "$orca_terminals.tmp" "$orca_terminals"; cp "$orca_terminals" "$orca_bound"
printf '0\n' >"$successor_show_count"
if env "${orca_env[@]}" AFK_FAKE_SHOW_COUNT="$successor_show_count" AFK_FAKE_SHOW_TIMEOUT_WHEN_ABSENT=1 \
  "$ROOT/adapters/orca-pm-successor.sh" "$launch_pm/intent.json" pm-launch >/dev/null 2>&1; then
  no "successor replacement rejects a post-close show timeout"
else ok "successor replacement rejects a post-close show timeout"; fi
eq "timed-out successor close cannot create a replacement" "$(grep -c '^terminal create ' "$TMP/orca-log" || true)" "$before_create_count"
if [[ -f "$launch_pm/transitions/pm-launch/replacement-close-binding.json" \
  && ! -e "$launch_pm/transitions/pm-launch/replacement-close-receipt.json" \
  && -f "$launch_pm/transitions/pm-launch/launch-create.json" ]] \
  && jq -e 'length==0' "$orca_terminals" >/dev/null; then
  ok "successor replacement journal survives close timeout with old launch evidence"
else no "successor replacement journal survives close timeout with old launch evidence"; fi
eq "the replacement binding records its runtime" \
  "$(jq -r .runtime_id "$launch_pm/transitions/pm-launch/replacement-close-binding.json")" "runtime-a"
before_runtime_b_creates="$(grep -c '^terminal create ' "$TMP/orca-log" || true)"
if env "${orca_env[@]}" AFK_FAKE_RUNTIME_ID=runtime-b "$ROOT/adapters/orca-pm-successor.sh" \
  "$launch_pm/intent.json" pm-launch >/dev/null 2>&1; then
  no "successor replacement refuses absence in another runtime"
else ok "successor replacement refuses absence in another runtime"; fi
if [[ ! -e "$launch_pm/transitions/pm-launch/replacement-close-receipt.json" ]]; then ok
else no "runtime-b absence wrote a replacement close receipt"; fi
rb_binding="$launch_pm/transitions/pm-launch/replacement-close-binding.json"
cp "$rb_binding" "$TMP/replacement-binding.json"
jq -c 'del(.runtime_id)' "$TMP/replacement-binding.json" >"$rb_binding"
if env "${orca_env[@]}" "$ROOT/adapters/orca-pm-successor.sh" "$launch_pm/intent.json" pm-launch >/dev/null 2>&1; then
  no "a replacement binding without a runtime never proves absence"
else ok "a replacement binding without a runtime never proves absence"; fi
if [[ ! -e "$launch_pm/transitions/pm-launch/replacement-close-receipt.json" ]]; then ok
else no "a runtime-less replacement binding wrote a close receipt"; fi
cp "$TMP/replacement-binding.json" "$rb_binding"
eq "no runtime-unproven replacement creates a successor" "$(grep -c '^terminal create ' "$TMP/orca-log" || true)" "$before_runtime_b_creates"
dead_receipt="$(env "${orca_env[@]}" AFK_FAKE_CREATE_HANDLE=replacement-terminal \
  "$ROOT/adapters/orca-pm-successor.sh" "$launch_pm/intent.json" pm-launch)"
if jq -e '.accepted==true and .terminal=="replacement-terminal"' <<<"$dead_receipt" >/dev/null; then
  ok "successor replay replaces after timeout without restoring the old terminal"
else no "successor replay replaces after timeout without restoring the old terminal"; fi
eq "dead rediscovery creates exactly one replacement" "$(grep -c '^terminal create ' "$TMP/orca-log" || true)" "$((before_create_count + 1))"
if [[ ! -e "$launch_pm/transitions/pm-launch/replacement-close-binding.json" \
  && ! -e "$launch_pm/transitions/pm-launch/replacement-close-receipt.json" \
  && ! -e "$launch_pm/transitions/pm-launch/replacement-create-attempt.json" ]] \
  && jq -e '.generation==1 and .terminal=="replacement-terminal"' \
    "$launch_pm/transitions/pm-launch/launch-create.json" >/dev/null; then
  ok "durable replacement receipt consumes its completed generation journals"
else no "durable replacement receipt consumes its completed generation journals"; fi

# A caller crash after the adapter's receipt but before the lifecycle ledger is
# harmless: replay returns that exact successor and never spends another create.
before_preledger_replay_creates="$(grep -c '^terminal create ' "$TMP/orca-log" || true)"
preledger_replay="$(env "${orca_env[@]}" "$ROOT/adapters/orca-pm-successor.sh" \
  "$launch_pm/intent.json" pm-launch)"
if jq -e '.accepted==true and .terminal=="replacement-terminal"' <<<"$preledger_replay" >/dev/null; then
  ok "replacement receipt replays before the caller ledger is durable"
else no "replacement receipt replays before the caller ledger is durable"; fi
eq "pre-ledger replay creates no duplicate successor" \
  "$(grep -c '^terminal create ' "$TMP/orca-log" || true)" "$before_preledger_replay_creates"

# orphaned:true means the tab lost its pane, not that the successor died
# (AD-28 R5). A connected, orphaned successor is replayed as-is: never closed,
# never replaced.
jq 'map(if .handle=="replacement-terminal" then .orphaned=true else . end)' \
  "$orca_terminals" >"$orca_terminals.tmp"; mv "$orca_terminals.tmp" "$orca_terminals"; cp "$orca_terminals" "$orca_bound"
before_orphan_closes="$(grep -c '^terminal close ' "$TMP/orca-log" || true)"
orphan_replay="$(env "${orca_env[@]}" "$ROOT/adapters/orca-pm-successor.sh" "$launch_pm/intent.json" pm-launch)"
if jq -e '.accepted==true and .terminal=="replacement-terminal"' <<<"$orphan_replay" >/dev/null; then
  ok "an orphaned live successor is kept on replay"
else no "an orphaned live successor is kept on replay"; fi
eq "  ...it is never closed" "$(grep -c '^terminal close ' "$TMP/orca-log" || true)" "$before_orphan_closes"
eq "  ...and never replaced" "$(grep -c '^terminal create ' "$TMP/orca-log" || true)" "$before_preledger_replay_creates"
jq 'map(if .handle=="replacement-terminal" then .orphaned=false else . end)' \
  "$orca_terminals" >"$orca_terminals.tmp"; mv "$orca_terminals.tmp" "$orca_terminals"; cp "$orca_terminals" "$orca_bound"

# The consumed first-generation journal cannot poison a later death.  The next
# source gets its own generation-bound close and create attempt.
jq 'map(if .handle=="replacement-terminal" then .status="exited"|.connected=false else . end)' \
  "$orca_terminals" >"$orca_terminals.tmp"; mv "$orca_terminals.tmp" "$orca_terminals"; cp "$orca_terminals" "$orca_bound"
before_second_replacement_creates="$(grep -c '^terminal create ' "$TMP/orca-log" || true)"
second_dead_receipt="$(env "${orca_env[@]}" AFK_FAKE_CREATE_HANDLE=second-replacement-terminal \
  "$ROOT/adapters/orca-pm-successor.sh" "$launch_pm/intent.json" pm-launch)"
if jq -e '.accepted==true and .terminal=="second-replacement-terminal"' <<<"$second_dead_receipt" >/dev/null \
  && jq -e '.generation==2 and .terminal=="second-replacement-terminal"' \
    "$launch_pm/transitions/pm-launch/launch-create.json" >/dev/null; then
  ok "second dead successor receives an independent second-generation replacement"
else no "second dead successor receives an independent second-generation replacement"; fi
eq "second-generation death spends exactly one additional create" \
  "$(grep -c '^terminal create ' "$TMP/orca-log" || true)" "$((before_second_replacement_creates + 1))"
if [[ ! -e "$launch_pm/transitions/pm-launch/replacement-close-binding.json" \
  && ! -e "$launch_pm/transitions/pm-launch/replacement-close-receipt.json" \
  && ! -e "$launch_pm/transitions/pm-launch/replacement-create-attempt.json" ]]; then
  ok "second replacement also consumes only its completed generation"
else no "second replacement also consumes only its completed generation"; fi
rm -f -- "$launch_pm/transitions/pm-launch/launch-create.json"
jq '.[0] |= del(.status)' "$orca_terminals" >"$orca_terminals.tmp"; mv "$orca_terminals.tmp" "$orca_terminals"; cp "$orca_terminals" "$orca_bound"
if env "${orca_env[@]}" "$ROOT/adapters/orca-pm-successor.sh" "$launch_pm/intent.json" pm-launch >/dev/null 2>&1; then
  no "title-only successor is refused"
else ok "title-only successor is refused"; fi
jq '.[0].status="running"|.[0].connected=true' "$orca_terminals" >"$orca_terminals.tmp"; mv "$orca_terminals.tmp" "$orca_terminals"; cp "$orca_terminals" "$orca_bound"

# If Orca creates a replacement but the adapter crashes before recording its
# receipt, both a visible title and a lagging empty list remain ambiguous.  The
# durable generation attempt prevents either observation from issuing create.
crash_pm="$TMP/crash-before-receipt-pm"; mkdir -p "$crash_pm"
jq -nc --arg p "$ROOT" --arg pm "$crash_pm" \
  '{schema:"afk-pm-bootstrap-intent/1",transition_id:"pm-crash-before-receipt",harness:"codex",resume_instruction:"resume",continuation_sha256:"sha256:crash",worktree:{id:"child-worktree-id",path:$p},run_id:null,pm_dir:$pm}' \
  >"$crash_pm/intent.json"
printf '[]\n' >"$orca_terminals"; printf '[]\n' >"$orca_bound"
env "${orca_env[@]}" AFK_FAKE_CREATE_HANDLE=crash-source-terminal \
  "$ROOT/adapters/orca-pm-successor.sh" "$crash_pm/intent.json" pm-crash-before-receipt >/dev/null
jq 'map(if .handle=="crash-source-terminal" then .status="exited"|.connected=false else . end)' \
  "$orca_terminals" >"$orca_terminals.tmp"; mv "$orca_terminals.tmp" "$orca_terminals"; cp "$orca_terminals" "$orca_bound"
before_crash_effect_creates="$(grep -c '^terminal create ' "$TMP/orca-log" || true)"
if env "${orca_env[@]}" AFK_FAKE_CREATE_HANDLE=unacknowledged-terminal AFK_FAKE_CREATE_CRASH_AFTER_EFFECT=1 \
  "$ROOT/adapters/orca-pm-successor.sh" "$crash_pm/intent.json" pm-crash-before-receipt >/dev/null 2>&1; then
  no "replacement create crash occurs before receipt"
else ok "replacement create crash occurs before receipt"; fi
eq "crashing create produces one unacknowledged side effect" \
  "$(grep -c '^terminal create ' "$TMP/orca-log" || true)" "$((before_crash_effect_creates + 1))"
if [[ -f "$crash_pm/transitions/pm-crash-before-receipt/replacement-create-attempt.json" \
  && ! -e "$crash_pm/transitions/pm-crash-before-receipt/launch-create.json" ]]; then
  ok "crash-before-receipt retains its generation-specific create attempt"
else no "crash-before-receipt retains its generation-specific create attempt"; fi
before_ambiguous_replays="$(grep -c '^terminal create ' "$TMP/orca-log" || true)"
if env "${orca_env[@]}" "$ROOT/adapters/orca-pm-successor.sh" \
  "$crash_pm/intent.json" pm-crash-before-receipt >/dev/null 2>&1; then
  no "visible unacknowledged replacement remains blocked"
else ok "visible unacknowledged replacement remains blocked"; fi
eq "visible crash-before-receipt evidence cannot duplicate create" \
  "$(grep -c '^terminal create ' "$TMP/orca-log" || true)" "$before_ambiguous_replays"
if env "${orca_env[@]}" AFK_FAKE_HIDE_TERMINALS=1 "$ROOT/adapters/orca-pm-successor.sh" \
  "$crash_pm/intent.json" pm-crash-before-receipt >/dev/null 2>&1; then
  no "lagging crash-before-receipt replacement remains blocked"
else ok "lagging crash-before-receipt replacement remains blocked"; fi
eq "lagging crash-before-receipt evidence cannot duplicate create" \
  "$(grep -c '^terminal create ' "$TMP/orca-log" || true)" "$before_ambiguous_replays"

# A matching terminal payload inside an explicit error envelope is not exact
# handle authority, even when every payload field matches the close intent.
conflict_close_pm="$TMP/conflict-close-pm"; mkdir -p "$conflict_close_pm"
jq -nc --arg p "$ROOT" '{schema:"afk-pm-close-intent/1",transition_id:"pm-close-conflict",authorized:true,old:{session:"old",terminal:"conflict-terminal",harness:"codex",worktree:{id:"child-worktree-id",path:$p}}}' >"$conflict_close_pm/intent.json"
before_conflict_close_calls="$(grep -c '^terminal close ' "$TMP/orca-log" || true)"
for conflicting_worktree_show in "${conflicting_worktree_shows[@]}"; do
  if env "${orca_env[@]}" AFK_FAKE_WORKTREE_SHOW_JSON="$conflicting_worktree_show" \
    "$ROOT/adapters/orca-pm-close.sh" "$conflict_close_pm/intent.json" >/dev/null 2>&1; then
    no "close rejects a conflicting worktree-show envelope"
  else ok "close rejects a conflicting worktree-show envelope"; fi
done
if [[ ! -e "$conflict_close_pm/close-binding.json" ]]; then ok; else no "conflicting worktree show persisted close authority"; fi
eq "conflicting close worktree show never reaches global close" "$(grep -c '^terminal close ' "$TMP/orca-log" || true)" "$before_conflict_close_calls"
conflicting_close_shows=(
  "$(jq -nc --arg p "$ROOT" '{ok:false,result:{terminal:{handle:"conflict-terminal",title:"old",status:"running",connected:true,orphaned:false,worktreeId:"child-worktree-id",worktreePath:$p}}}')"
  "$(jq -nc --arg p "$ROOT" '{ok:true,error:{code:"terminal_show_failed"},result:{terminal:{handle:"conflict-terminal",title:"old",status:"running",connected:true,orphaned:false,worktreeId:"child-worktree-id",worktreePath:$p}}}')"
)
for conflicting_close_show in "${conflicting_close_shows[@]}"; do
  if env "${orca_env[@]}" AFK_FAKE_TERMINAL_SHOW_JSON="$conflicting_close_show" \
    "$ROOT/adapters/orca-pm-close.sh" "$conflict_close_pm/intent.json" >/dev/null 2>&1; then
    no "close binding rejects a conflicting terminal-show envelope"
  else ok "close binding rejects a conflicting terminal-show envelope"; fi
done
if [[ ! -e "$conflict_close_pm/close-binding.json" ]]; then ok; else no "conflicting close show persisted binding authority"; fi
eq "conflicting close show never reaches global close" "$(grep -c '^terminal close ' "$TMP/orca-log" || true)" "$before_conflict_close_calls"

# Missing-before is not durable close evidence. The adapter must still request
# an accepted --tab close and re-observe absence before emitting a receipt.
close_pm="$TMP/close-pm"; mkdir -p "$close_pm"
jq -nc --arg p "$ROOT" '{schema:"afk-pm-close-intent/1",transition_id:"pm-close",authorized:true,old:{session:"old",terminal:"old-terminal",harness:"codex",worktree:{id:"child-worktree-id",path:$p}}}' >"$close_pm/intent.json"
jq -nc --arg p "$ROOT" '[{handle:"old-terminal",title:"old",status:"exited",connected:false,orphaned:false,worktreeId:"child-worktree-id",worktreePath:$p}]' >"$orca_bound"
absent_close_receipt="$(env "${orca_env[@]}" "$ROOT/adapters/orca-pm-close.sh" "$close_pm/intent.json")"
if jq -e '.closed==true and .observed_before==false and .close_requested==true and .reobserved_absent==true and .recovered_after_close==true' <<<"$absent_close_receipt" >/dev/null; then
  ok "absent old terminal still requires durable close proof"
else no "absent old terminal still requires durable close proof"; fi
jq -nc --arg p "$ROOT" '[{handle:"old-terminal",title:"old",status:"running",connected:true,orphaned:false,worktreeId:"child-worktree-id",worktreePath:$p}]' >"$orca_terminals"; cp "$orca_terminals" "$orca_bound"
close_receipt="$(env "${orca_env[@]}" "$ROOT/adapters/orca-pm-close.sh" "$close_pm/intent.json")"
if jq -e '.closed==true and .observed_before==true and .close_requested==true and .reobserved_absent==true and .recovered_after_close==false' <<<"$close_receipt" >/dev/null; then
  ok "durable tab close emits verified receipt"
else no "durable tab close emits verified receipt"; fi

# Crash after Orca accepted the exact close but before the adapter could emit a
# receipt. Replay may recover only from the durable pre-close binding plus two
# fresh absence observations; it must not issue a second global close.
crash_close_pm="$TMP/crash-close-pm"; mkdir -p "$crash_close_pm"
jq -nc --arg p "$ROOT" '{schema:"afk-pm-close-intent/1",transition_id:"pm-close-crash",authorized:true,old:{session:"old",terminal:"crash-terminal",harness:"codex",worktree:{id:"child-worktree-id",path:$p}}}' >"$crash_close_pm/intent.json"
jq -nc --arg p "$ROOT" '[{handle:"crash-terminal",title:"old",status:"running",connected:true,orphaned:false,worktreeId:"child-worktree-id",worktreePath:$p}]' >"$orca_terminals"; cp "$orca_terminals" "$orca_bound"
crash_list_once="$TMP/crash-list-once"
if env "${orca_env[@]}" AFK_FAKE_FAIL_EMPTY_LIST_ONCE="$crash_list_once" "$ROOT/adapters/orca-pm-close.sh" "$crash_close_pm/intent.json" >/dev/null 2>&1; then
  no "crash-after-close fixture interrupts before receipt"
else ok "crash-after-close fixture interrupts before receipt"; fi
if [[ -f "$crash_close_pm/close-binding.json" ]] && jq -e '.terminal=="crash-terminal" and .worktree.id=="child-worktree-id"' "$crash_close_pm/close-binding.json" >/dev/null; then
  ok "pre-close binding survives the crash window"
else no "pre-close binding survives the crash window"; fi
before_recovery_closes="$(grep -c '^terminal close ' "$TMP/orca-log" || true)"
eq "the pre-close binding records its runtime" "$(jq -r .runtime_id "$crash_close_pm/close-binding.json")" "runtime-a"
# After an Orca restart every old handle is absent and answers stale while its
# process may still run: absence in another runtime is never a release.
runtime_b_close_output="$TMP/runtime-b-close-output"
if env "${orca_env[@]}" AFK_FAKE_RUNTIME_ID=runtime-b "$ROOT/adapters/orca-pm-close.sh" \
  "$crash_close_pm/intent.json" >"$runtime_b_close_output" 2>/dev/null; then
  no "close replay refuses absence in another runtime"
else ok "close replay refuses absence in another runtime"; fi
if [[ ! -s "$runtime_b_close_output" ]]; then ok; else no "runtime-b absence emitted a close receipt"; fi
cp "$crash_close_pm/close-binding.json" "$TMP/crash-binding.json"
jq -c 'del(.runtime_id)' "$TMP/crash-binding.json" >"$crash_close_pm/close-binding.json"
if env "${orca_env[@]}" "$ROOT/adapters/orca-pm-close.sh" "$crash_close_pm/intent.json" >"$runtime_b_close_output" 2>/dev/null; then
  no "a binding without a runtime never takes the recovered-absence branch"
else ok "a binding without a runtime never takes the recovered-absence branch"; fi
if [[ ! -s "$runtime_b_close_output" ]]; then ok; else no "a runtime-less binding emitted a close receipt"; fi
cp "$TMP/crash-binding.json" "$crash_close_pm/close-binding.json"
malformed_list_labels=(
  "missing list envelope"
  "non-array terminal list"
  "empty terminal handle"
  "null terminal handle"
  "non-object terminal member"
  "missing terminal title"
  "null terminal title"
  "non-string terminal title"
  "failed terminal-list ok flag"
  "explicit terminal-list error"
)
malformed_list_payloads=(
  '{}'
  '{"result":{"terminals":{}}}'
  '{"result":{"terminals":[{"handle":""}]}}'
  '{"result":{"terminals":[{"handle":null}]}}'
  '{"result":{"terminals":[7]}}'
  '{"result":{"terminals":[{"handle":"other"}]}}'
  '{"result":{"terminals":[{"handle":"other","title":null}]}}'
  '{"result":{"terminals":[{"handle":"other","title":7}]}}'
  '{"ok":false,"result":{"terminals":[]}}'
  '{"ok":true,"error":{"code":"terminal_list_failed"},"result":{"terminals":[]}}'
)
for malformed_index in "${!malformed_list_labels[@]}"; do
  malformed_close_output="$TMP/malformed-close-output-$malformed_index"
  if env "${orca_env[@]}" AFK_FAKE_FAIL_EMPTY_LIST_ONCE="$crash_list_once" \
    AFK_FAKE_TERMINAL_LIST_JSON="${malformed_list_payloads[$malformed_index]}" \
    "$ROOT/adapters/orca-pm-close.sh" "$crash_close_pm/intent.json" >"$malformed_close_output" 2>/dev/null; then
    no "close replay refuses ${malformed_list_labels[$malformed_index]}"
  else ok "close replay refuses ${malformed_list_labels[$malformed_index]}"; fi
  if [[ ! -s "$malformed_close_output" ]]; then ok; else no "${malformed_list_labels[$malformed_index]} emitted a recovered close receipt"; fi
done
eq "malformed lists never reissue the global close" "$(grep -c '^terminal close ' "$TMP/orca-log" || true)" "$before_recovery_closes"
conflicting_stale_show="$(jq -nc --arg p "$ROOT" \
  '{ok:false,error:{code:"terminal_handle_stale"},result:{terminal:{handle:"crash-terminal",title:"old",worktreeId:"child-worktree-id",worktreePath:$p}}}')"
conflicting_stale_output="$TMP/conflicting-stale-output"
if env "${orca_env[@]}" AFK_FAKE_FAIL_EMPTY_LIST_ONCE="$crash_list_once" \
  AFK_FAKE_TERMINAL_SHOW_JSON="$conflicting_stale_show" AFK_FAKE_TERMINAL_SHOW_RC=1 \
  "$ROOT/adapters/orca-pm-close.sh" "$crash_close_pm/intent.json" >"$conflicting_stale_output" 2>/dev/null; then
  no "close replay rejects stale error carrying a terminal payload"
else ok "close replay rejects stale error carrying a terminal payload"; fi
if [[ ! -s "$conflicting_stale_output" ]]; then ok; else no "conflicting stale show emitted a recovered close receipt"; fi
eq "conflicting stale show never reissues the global close" "$(grep -c '^terminal close ' "$TMP/orca-log" || true)" "$before_recovery_closes"
ambiguous_close_output="$TMP/ambiguous-close-output"
if env "${orca_env[@]}" AFK_FAKE_FAIL_EMPTY_LIST_ONCE="$crash_list_once" AFK_FAKE_SHOW_TIMEOUT=1 \
  "$ROOT/adapters/orca-pm-close.sh" "$crash_close_pm/intent.json" >"$ambiguous_close_output" 2>/dev/null; then
  no "close replay refuses an ambiguous terminal-show timeout"
else ok "close replay refuses an ambiguous terminal-show timeout"; fi
if [[ ! -s "$ambiguous_close_output" ]]; then ok; else no "ambiguous show failure emitted a recovered close receipt"; fi
eq "ambiguous show failure never reissues the global close" "$(grep -c '^terminal close ' "$TMP/orca-log" || true)" "$before_recovery_closes"
recovered_close_receipt="$(env "${orca_env[@]}" AFK_FAKE_FAIL_EMPTY_LIST_ONCE="$crash_list_once" "$ROOT/adapters/orca-pm-close.sh" "$crash_close_pm/intent.json")"
if jq -e '.terminal=="crash-terminal" and .closed==true and .observed_before==false and
  .close_requested==true and .reobserved_absent==true and .recovered_after_close==true' <<<"$recovered_close_receipt" >/dev/null; then
  ok "close replay recovers from exact binding and independent absence"
else no "close replay recovers from exact binding and independent absence"; fi
eq "close recovery never reissues the global close" "$(grep -c '^terminal close ' "$TMP/orca-log" || true)" "$before_recovery_closes"

# A binding that does not exactly match its durable intent is not recovery
# authority, even when both current terminal observations are absent.
forged_close_pm="$TMP/forged-close-pm"; mkdir -p "$forged_close_pm"
jq -nc --arg p "$ROOT" '{schema:"afk-pm-close-intent/1",transition_id:"pm-close-forged",authorized:true,old:{session:"old",terminal:"forged-terminal",harness:"codex",worktree:{id:"child-worktree-id",path:$p}}}' >"$forged_close_pm/intent.json"
jq -nc --arg p "$ROOT" '{schema:"afk-pm-close-binding/1",transition_id:"pm-close-forged",terminal:"forged-terminal",worktree:{id:"other-worktree",path:$p},intent_sha256:"sha256:forged"}' >"$forged_close_pm/close-binding.json"
before_forged_closes="$(grep -c '^terminal close ' "$TMP/orca-log" || true)"
if env "${orca_env[@]}" "$ROOT/adapters/orca-pm-close.sh" "$forged_close_pm/intent.json" >/dev/null 2>&1; then
  no "forged pre-close binding is refused"
else ok "forged pre-close binding is refused"; fi
eq "forged binding never reaches global close" "$(grep -c '^terminal close ' "$TMP/orca-log" || true)" "$before_forged_closes"

# Changing a close intent after its exact binding was persisted invalidates the
# binding digest; the forged intent cannot turn old authority into a new close.
forged_intent_pm="$TMP/forged-intent-pm"; mkdir -p "$forged_intent_pm"
cp "$crash_close_pm/intent.json" "$forged_intent_pm/intent.json"
cp "$crash_close_pm/close-binding.json" "$forged_intent_pm/close-binding.json"
jq '.old.session="forged-session"' "$forged_intent_pm/intent.json" >"$forged_intent_pm/intent.tmp"
mv "$forged_intent_pm/intent.tmp" "$forged_intent_pm/intent.json"
before_forged_intent_closes="$(grep -c '^terminal close ' "$TMP/orca-log" || true)"
if env "${orca_env[@]}" "$ROOT/adapters/orca-pm-close.sh" "$forged_intent_pm/intent.json" >/dev/null 2>&1; then
  no "forged close intent cannot reuse a pre-close binding"
else ok "forged close intent cannot reuse a pre-close binding"; fi
eq "forged close intent never reaches global close" "$(grep -c '^terminal close ' "$TMP/orca-log" || true)" "$before_forged_intent_closes"

# A global handle close is forbidden unless handle-specific Orca metadata binds
# it to the exact worktree named by the durable close intent.
jq -nc --arg p "$ROOT" '[{handle:"old-terminal",title:"old",status:"running",connected:true,orphaned:false,worktreeId:"other-worktree",worktreePath:$p}]' >"$orca_bound"
before_close_calls="$(grep -c '^terminal close ' "$TMP/orca-log" || true)"
if env "${orca_env[@]}" "$ROOT/adapters/orca-pm-close.sh" "$close_pm/intent.json" >/dev/null 2>&1; then
  no "unbound global terminal handle is refused"
else ok "unbound global terminal handle is refused"; fi
eq "unbound handle is never sent to global close" "$(grep -c '^terminal close ' "$TMP/orca-log" || true)" "$before_close_calls"
printf '[]\n' >"$orca_bound"

# Fixed OpenCode bootstrap binds the current Run, then passes resume as prompt
# data in one argument.
write_bootstrap_evidence() { # <pm-dir> <intent-file> <terminal>
  local dir="$1" intent_file="$2" terminal="$3" tid common
  tid="$(jq -r .transition_id "$intent_file")"
  mkdir -p "$dir/transitions/$tid"
  common="$(jq -nc --argjson i "$(jq -c . "$intent_file")" \
    '{schema:"afk-pm-launch-create/1",transition_id:$i.transition_id,harness:$i.harness,
      worktree:$i.worktree,run_id:$i.run_id,title:"test-successor",
      continuation_sha256:$i.continuation_sha256,command_sha256:"sha256:command",create_id:"sha256:create"}')"
  jq -c . <<<"$common" >"$dir/transitions/$tid/launch-create.json"
  jq -c '.schema="afk-pm-launch-attempt/1"' <<<"$common" >"$dir/transitions/$tid/launch-attempt.json"
  jq -c --arg terminal "$terminal" '.schema="afk-pm-launch-receipt/2" |
    del(.title) + {accepted:true,terminal:$terminal,identity:null}' <<<"$common" >"$dir/transitions/$tid/launch-receipt.json"
}
bootstrap_pm="$TMP/bootstrap-pm"; mkdir -p "$bootstrap_pm"
jq -nc --arg p "$ROOT" --arg pm "$bootstrap_pm" '{schema:"afk-pm-bootstrap-intent/1",transition_id:"pm-boot",harness:"opencode",resume_instruction:"resume ; never-eval",continuation_sha256:"sha256:x",worktree:{id:"child-worktree-id",path:$p},run_id:"run-1",pm_dir:$pm}' >"$bootstrap_pm/intent.json"
jq -nc --arg p "$ROOT" '{schema:"afk-pm-handoff/2",transition_id:"pm-boot",state:"SUCCESSOR_LAUNCHED",continuation_sha256:"sha256:x",old:{session:"o",terminal:"old",harness:"opencode",worktree:{id:"child-worktree-id",path:$p},run_id:"run-1"},successor:{terminal:"boot-terminal",harness:"opencode",worktree:{id:"child-worktree-id",path:$p},run_id:"run-1"}}' >"$bootstrap_pm/handoff.json"
write_bootstrap_evidence "$bootstrap_pm" "$bootstrap_pm/intent.json" boot-terminal
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nprintf "%%s\n" "$#:$1:$2" >"$AFK_FAKE_HARNESS_ARGS"\n' >"$TMP/fake-opencode"; chmod +x "$TMP/fake-opencode"
bootstrap_receipt="$bootstrap_pm/transitions/pm-boot/launch-receipt.json"
cp "$bootstrap_receipt" "$TMP/bootstrap-receipt.saved"
for mismatch in absent transition digest create worktree run runtime terminal; do
  if [[ "$mismatch" == absent ]]; then rm -f "$bootstrap_receipt"
  else
    jq --arg kind "$mismatch" '
      if $kind=="transition" then .transition_id="other"
      elif $kind=="digest" then .command_sha256="sha256:other"
      elif $kind=="create" then .create_id="sha256:other"
      elif $kind=="worktree" then .worktree.id="other"
      elif $kind=="run" then .run_id="other"
      elif $kind=="runtime" then .identity={handle:.terminal,worktree_id:.worktree.id,runtime_id:"other"}
      else .terminal="other" end' "$TMP/bootstrap-receipt.saved" >"$bootstrap_receipt"
  fi
  rm -f "$TMP/harness-args"
  if env "${orca_env[@]}" AFK_PM_BOOTSTRAP_POLLS=1 AFK_PM_BOOTSTRAP_POLL_SECONDS=0.01 \
    AFK_OPENCODE_BIN="$TMP/fake-opencode" AFK_FAKE_HARNESS_ARGS="$TMP/harness-args" ORCA_TERMINAL_HANDLE=boot-terminal \
    "$ROOT/adapters/orca-pm-bootstrap.sh" --intent "$bootstrap_pm/intent.json" >/dev/null 2>&1; then
    no "bootstrap refuses $mismatch launch evidence"
  else ok "bootstrap refuses $mismatch launch evidence"; fi
  [[ ! -e "$TMP/harness-args" ]] && ok || no "bootstrap $mismatch evidence ran harness"
done
cp "$TMP/bootstrap-receipt.saved" "$bootstrap_receipt"
env "${orca_env[@]}" AFK_OPENCODE_BIN="$TMP/fake-opencode" AFK_FAKE_HARNESS_ARGS="$TMP/harness-args" ORCA_TERMINAL_HANDLE=boot-terminal \
  "$ROOT/adapters/orca-pm-bootstrap.sh" --intent "$bootstrap_pm/intent.json"
eq "OpenCode resume is prompt data" "$(<"$TMP/harness-args")" '2:--prompt:resume ; never-eval'
if [[ "$(<"$TMP/orca-log")" == *'orchestration run-use --id run-1 --from boot-terminal'* ]]; then ok; else no "successor did not bind current Run"; fi
jq -nc --arg p "$ROOT" '{schema:"afk-pm-ownership/2",owned:true,role:"PM",harness:"opencode",session:"changed",terminal:"other",worktree:{id:"child-worktree-id",path:$p},run_id:"run-1"}' >"$bootstrap_pm/ownership.json"
if env "${orca_env[@]}" AFK_PM_BOOTSTRAP_POLLS=1 AFK_OPENCODE_BIN="$TMP/fake-opencode" ORCA_TERMINAL_HANDLE=boot-terminal \
  "$ROOT/adapters/orca-pm-bootstrap.sh" --intent "$bootstrap_pm/intent.json" >/dev/null 2>&1; then
  no "legacy bootstrap accepts changed old owner"
else ok "legacy bootstrap refuses changed old owner"; fi
if env "${orca_env[@]}" AFK_FAKE_WORKTREE_ID=other-worktree AFK_OPENCODE_BIN="$TMP/fake-opencode" AFK_FAKE_HARNESS_ARGS="$TMP/harness-args" ORCA_TERMINAL_HANDLE=boot-terminal \
  "$ROOT/adapters/orca-pm-bootstrap.sh" --intent "$bootstrap_pm/intent.json" >/dev/null 2>&1; then
  no "bootstrap refuses copied worktree identity"
else ok "bootstrap refuses copied worktree identity"; fi

# Claude/Codex resume text is data even when it begins with an option marker.
option_pm="$TMP/option-pm"; mkdir -p "$option_pm"
jq -nc --arg p "$ROOT" --arg pm "$option_pm" '{schema:"afk-pm-bootstrap-intent/1",transition_id:"pm-option",harness:"codex",resume_instruction:"--dangerous",continuation_sha256:"sha256:option",worktree:{id:"child-worktree-id",path:$p},run_id:null,pm_dir:$pm}' >"$option_pm/intent.json"
jq -nc --arg p "$ROOT" '{schema:"afk-pm-handoff/2",transition_id:"pm-option",state:"SUCCESSOR_LAUNCHED",continuation_sha256:"sha256:option",old:{session:"o",terminal:"old",harness:"codex",worktree:{id:"child-worktree-id",path:$p}},successor:{terminal:"option-terminal",harness:"codex",worktree:{id:"child-worktree-id",path:$p}}}' >"$option_pm/handoff.json"
write_bootstrap_evidence "$option_pm" "$option_pm/intent.json" option-terminal
env "${orca_env[@]}" AFK_CODEX_BIN="$TMP/fake-opencode" AFK_FAKE_HARNESS_ARGS="$TMP/option-harness-args" ORCA_TERMINAL_HANDLE=option-terminal \
  "$ROOT/adapters/orca-pm-bootstrap.sh" --intent "$option_pm/intent.json"
eq "Codex leading-dash resume is positional data" "$(<"$TMP/option-harness-args")" '2:--:--dangerous'

# Durable handoff: launch once, reject spoofed/old ACK, transfer on an exact
# successor event, recover a crash after close, and reconcile once.
pmd="$TMP/pm"; mkdir -p "$pmd"; now_epoch="$(date +%s)"
jq -nc '{schema:"afk-pm-continuation/1",decisions:[],envelope_actions:[],open_escalations:[],budget_state:{},in_flight_dispatches:[],updated_at:"2026-09-14T00:00:00Z",resume_instruction:"resume-afk-pm"}' >"$pmd/continuation.json"
jq -nc --arg p "$ROOT" --argjson e "$now_epoch" '{schema:"afk-pm-ownership/2",owned:true,role:"PM",harness:"codex",session:"old-session",terminal:"old-terminal",worktree:{id:"child-worktree-id",path:$p},run_id:null,observed_at:"now",observed_epoch:$e,freshness_seconds:120,transition_id:null,previous:null}' >"$pmd/ownership.json"
old_control="$(bash -c '. "$1"; afk_pmc_manual "$(jq -c . "$2")" "$(afk_pmc_common_dir "$3")"' _ "$ROOT/lib/afk-pm-control.sh" "$pmd/ownership.json" "$ROOT")"
jq --argjson c "$old_control" '.control=($c|.revision=7)' "$pmd/ownership.json" >"$TMP/owner-control.json"
mv "$TMP/owner-control.json" "$pmd/ownership.json"
launcher="$TMP/launcher"; closer="$TMP/closer"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'n=0; [[ ! -f "$AFK_LAUNCH_COUNT_FILE" ]] || n="$(<"$AFK_LAUNCH_COUNT_FILE")"; n=$((n+1)); printf "%s\n" "$n" >"$AFK_LAUNCH_COUNT_FILE"; terminal="new-terminal"; [[ "$n" == 1 ]] || terminal="next-terminal"' 'dir="$(dirname "$1")"; mkdir -p "$dir"' 'jq -nc --argjson i "$(jq -c . "$1")" '\''{schema:"afk-pm-launch-create/1",transition_id:$i.transition_id,harness:$i.harness,worktree:$i.worktree,run_id:$i.run_id,title:"fake",continuation_sha256:$i.continuation_sha256,command_sha256:"sha256:command",create_id:"sha256:create"}'\'' >"$dir/launch-create.json"' 'jq -c '\''.schema="afk-pm-launch-attempt/1"'\'' "$dir/launch-create.json" >"$dir/launch-attempt.json"' 'jq -nc --arg id "$2" --arg t "$terminal" --argjson i "$(jq -c . "$1")" '\''{schema:"afk-pm-launch-receipt/2",transition_id:$id,accepted:true,terminal:$t,harness:$i.harness,worktree:$i.worktree,run_id:$i.run_id,continuation_sha256:$i.continuation_sha256,command_sha256:"sha256:command",create_id:"sha256:create"}'\''' >"$launcher"
# First invocation simulates an already-absent observation, which is not close
# proof. Replay obtains a fresh durable close receipt.
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'n=0; [[ ! -f "$AFK_CLOSE_COUNT_FILE" ]] || n="$(<"$AFK_CLOSE_COUNT_FILE")"; n=$((n+1)); printf "%s\n" "$n" >"$AFK_CLOSE_COUNT_FILE"' 'if [[ "$n" == 1 ]]; then jq -nc --argjson i "$(jq -c . "$1")" '\''{schema:"afk-pm-close-receipt/2",transition_id:$i.transition_id,terminal:$i.old.terminal,worktree:$i.old.worktree,closed:true,observed_before:false,close_requested:false,reobserved_absent:true,recovered_after_close:true}'\''; exit; fi' 'jq -nc --argjson i "$(jq -c . "$1")" '\''{schema:"afk-pm-close-receipt/2",transition_id:$i.transition_id,terminal:$i.old.terminal,worktree:$i.old.worktree,closed:true,observed_before:true,close_requested:true,reobserved_absent:true,recovered_after_close:false}'\''' >"$closer"
chmod +x "$launcher" "$closer"
run_continue() { local ack="${1:-}" terminal="${2:-old-terminal}" caller="${3:-}"; local -a args=(--json); [[ -z "$ack" ]] || args+=(--ack "$ack"); set +e; HOME="$home" AFK_STATE_DIR="$state" AFK_PM_DIR="$pmd" AFK_LAUNCH_COUNT_FILE="$TMP/launch-count" AFK_CLOSE_COUNT_FILE="$TMP/close-count" AFK_PM_SUCCESSOR_LAUNCHER="$launcher" AFK_PM_TERMINAL_CLOSER="$closer" AFK_PM_CALLER_SESSION="$caller" ORCA_TERMINAL_HANDLE="$terminal" "$ROOT/bin/agent-flow-kit" pm-continue "${args[@]}" >/dev/null; set -e; }
run_continue
eq "handoff waits after one launch" "$(jq -r .state "$pmd/handoff.json")" SUCCESSOR_LAUNCHED
eq "handoff persists expected owner control revision" \
  "$(jq -r '.expected_old.owner.session+":"+(.expected_old.control.revision|tostring)' "$pmd/handoff.json")" 'old-session:7'
run_continue; eq "successor launched once" "$(<"$TMP/launch-count")" 1
transition="$(jq -r .transition_id "$pmd/handoff.json")"; transition_dir="$pmd/transitions/$transition"
jq '.control.revision=8' "$pmd/ownership.json" >"$TMP/owner-conflict.json"; mv "$TMP/owner-conflict.json" "$pmd/ownership.json"
run_continue
eq "revision conflict does not relaunch" "$(<"$TMP/launch-count")" 1
eq "revision conflict retains old owner" "$(jq -r .session "$pmd/ownership.json")" old-session
conflict_status="$(HOME="$home" AFK_STATE_DIR="$state" AFK_PM_DIR="$pmd" "$ROOT/bin/agent-flow-kit" status --json 2>/dev/null || true)"
eq "status suppresses conflicting handoff projection" \
  "$(jq -r '.extra.pm_control.reason+":"+(.extra.pm_handoff|type)' <<<"$conflict_status")" 'PM_HANDOFF_CONTROL_CONFLICT:null'
env "${orca_env[@]}" AFK_PM_DIR="$pmd" AFK_PM_AUTOFINALIZE=0 ORCA_TERMINAL_HANDLE=new-terminal \
  "$ROOT/adapters/pm-session.sh" observe --harness codex --session new-session
eq "publisher refuses stale control revision" "$(jq -r .session "$pmd/ownership.json")" old-session
jq '.control.revision=7' "$pmd/ownership.json" >"$TMP/owner-restored.json"; mv "$TMP/owner-restored.json" "$pmd/ownership.json"
cp "$transition_dir/launch-receipt.json" "$TMP/prepublish-receipt.json"
jq '.create_id="sha256:wrong"' "$TMP/prepublish-receipt.json" >"$transition_dir/launch-receipt.json"
env "${orca_env[@]}" AFK_PM_DIR="$pmd" AFK_PM_AUTOFINALIZE=0 ORCA_TERMINAL_HANDLE=new-terminal \
  "$ROOT/adapters/pm-session.sh" observe --harness codex --session new-session
eq "publisher checks evidence before ownership write" "$(jq -r .session "$pmd/ownership.json")" old-session
cp "$TMP/prepublish-receipt.json" "$transition_dir/launch-receipt.json"
jq '.identity={handle:"new-terminal",runtime_id:"other-runtime",execution_host_id:"local",worktree_id:.worktree.id,tab_id:"tab",leaf_id:"leaf",incarnation_id:"inc",agent_type:"codex"}' \
  "$TMP/prepublish-receipt.json" >"$transition_dir/launch-receipt.json"
jq --slurpfile r "$transition_dir/launch-receipt.json" '.successor.identity=$r[0].identity' "$pmd/handoff.json" >"$TMP/identity-handoff.json"
mv "$TMP/identity-handoff.json" "$pmd/handoff.json"
env "${orca_env[@]}" AFK_PM_DIR="$pmd" AFK_PM_AUTOFINALIZE=0 ORCA_TERMINAL_HANDLE=new-terminal \
  "$ROOT/adapters/pm-session.sh" observe --harness codex --session new-session
eq "publisher refuses changed successor runtime" "$(jq -r .session "$pmd/ownership.json")" old-session
cp "$TMP/prepublish-receipt.json" "$transition_dir/launch-receipt.json"
jq '.successor.identity=null' "$pmd/handoff.json" >"$TMP/identity-handoff.json"; mv "$TMP/identity-handoff.json" "$pmd/handoff.json"
# A publisher cannot compare/write while the lifecycle lock is held.
lock_ready="$TMP/lock-ready"; lock_release="$TMP/lock-release"
bash -c 'source "$1/lib/afk-common.sh"; source "$1/lib/afk-mutate.sh"; AFK_STATE_DIR="$2"; AFK_LOCK_DIR="$2/lock"; afk_lock_acquire || exit 1; : >"$3"; while [[ ! -e "$4" ]]; do sleep 0.02; done; afk_lock_release' \
  _ "$ROOT" "$state" "$lock_ready" "$lock_release" & lock_pid=$!
for _ in {1..50}; do [[ -e "$lock_ready" ]] && break; sleep 0.02; done
locked_owner_hash="$(sha256sum "$pmd/ownership.json")"
env "${orca_env[@]}" AFK_PM_DIR="$pmd" AFK_PM_AUTOFINALIZE=0 AFK_PM_PUBLISH_LOCK_POLLS=1 AFK_PM_PUBLISH_LOCK_POLL_SECONDS=0.02 \
  ORCA_TERMINAL_HANDLE=old-terminal "$ROOT/adapters/pm-session.sh" observe --harness codex --session old-session & publisher_pid=$!
sleep 0.05
eq "publisher leaves owner alone during lifecycle lock" "$(sha256sum "$pmd/ownership.json")" "$locked_owner_hash"
: >"$lock_release"; wait "$lock_pid"; wait "$publisher_pid"
for _ in {1..100}; do
  [[ "$(sha256sum "$pmd/ownership.json")" != "$locked_owner_hash" ]] && break
  sleep 0.02
done
if [[ "$(sha256sum "$pmd/ownership.json")" != "$locked_owner_hash" ]]; then
  ok "publisher resumes the owner observation after lock release"
else no "publisher lost the event after lifecycle lock release"; fi
run_continue
eq "old identity upgrade remains a valid handoff" "$(jq -r .state "$pmd/handoff.json")" SUCCESSOR_LAUNCHED
jq -nc --arg id "$transition" --arg p "$ROOT" '{schema:"afk-pm-successor-ack/2",transition_id:$id,acknowledged:true,harness:"codex",session:"spoof",terminal:"new-terminal",worktree:{id:"child-worktree-id",path:$p},run_id:null}' >"$TMP/spoof-ack.json"
run_continue "$TMP/spoof-ack.json" old-terminal old-session
if [[ ! -e "$TMP/close-count" ]]; then ok; else no "old PM synchronously closed itself"; fi
env "${orca_env[@]}" AFK_STATE_DIR="$state" AFK_PM_DIR="$pmd" AFK_PM_AUTOFINALIZE=0 ORCA_TERMINAL_HANDLE=new-terminal "$ROOT/adapters/pm-session.sh" observe --harness codex --session new-session
eq "successor preserves control intent and revision but resets launch proof" \
  "$(jq -r '.control.control_owner+":"+(.control.revision|tostring)+":"+.control.execution_profile+":"+.control.launch_provenance.status+":"+.control.provenance.owner.session' "$pmd/ownership.json")" \
  'human:7:unverified:unverified:new-session'
eq "successor records the exact prior control snapshot" \
  "$(jq -Sc .control.provenance.prior_control "$pmd/ownership.json")" \
  "$(jq -Sc .expected_old.control "$pmd/handoff.json")"
jq '.expected_old.control.revision=8' "$pmd/handoff.json" >"$TMP/handoff-conflict.json"; mv "$TMP/handoff-conflict.json" "$pmd/handoff.json"
run_continue "$transition_dir/successor-ack.json" new-terminal new-session
eq "successor snapshot conflict cannot advance ACK" "$(jq -r .state "$pmd/handoff.json")" SUCCESSOR_LAUNCHED
jq '.expected_old.control.revision=7' "$pmd/handoff.json" >"$TMP/handoff-restored.json"; mv "$TMP/handoff-restored.json" "$pmd/handoff.json"
cp "$transition_dir/launch-receipt.json" "$TMP/accepted-receipt.saved"
jq '.create_id="sha256:other"' "$transition_dir/launch-receipt.json" >"$TMP/receipt-conflict.json"
mv "$TMP/receipt-conflict.json" "$transition_dir/launch-receipt.json"
run_continue "$transition_dir/successor-ack.json" new-terminal new-session
eq "modified accepted receipt cannot advance ACK" "$(jq -r .state "$pmd/handoff.json")" SUCCESSOR_LAUNCHED
cp "$TMP/accepted-receipt.saved" "$transition_dir/launch-receipt.json"
rm -f -- "$transition_dir/successor-ack.json"
env "${orca_env[@]}" AFK_STATE_DIR="$state" AFK_PM_DIR="$pmd" AFK_PM_AUTOFINALIZE=0 ORCA_TERMINAL_HANDLE=new-terminal "$ROOT/adapters/pm-session.sh" observe --harness codex --session new-session
if jq -e --arg id "$transition" '.transition_id==$id and .session=="new-session" and .acknowledged==true' "$transition_dir/successor-ack.json" >/dev/null; then
  ok "matching event repairs ACK after ownership-write crash"
else no "matching event repairs ACK after ownership-write crash"; fi
finalizer="$TMP/finalizer"; finalizer_count="$TMP/finalizer-count"
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' 'n=0; [[ ! -f "$AFK_FINALIZER_COUNT" ]] || n="$(<"$AFK_FINALIZER_COUNT")"; n=$((n+1)); printf "%s\n" "$n" >"$AFK_FINALIZER_COUNT"; [[ "$n" -ge 4 ]] || exit 2' >"$finalizer"
chmod +x "$finalizer"
env "${orca_env[@]}" AFK_STATE_DIR="$state" AFK_PM_DIR="$pmd" AFK_AGENT_FLOW_KIT_BIN="$finalizer" AFK_FINALIZER_COUNT="$finalizer_count" \
  AFK_PM_FINALIZE_ATTEMPTS=2 AFK_PM_FINALIZE_RETRY_SECONDS=0.01 ORCA_TERMINAL_HANDLE=new-terminal \
  "$ROOT/adapters/pm-session.sh" observe --harness codex --session new-session
for _ in {1..50}; do [[ -f "$finalizer_count" && "$(<"$finalizer_count")" -ge 2 ]] && break; sleep 0.02; done
eq "automatic finalizer persists after exhausting contention retries" "$(<"$finalizer_count")" 2
if [[ -f "$transition_dir/finalize-pending.json" ]]; then ok; else no "exhausted finalizer lost durable retry intent"; fi
env "${orca_env[@]}" AFK_STATE_DIR="$state" AFK_PM_DIR="$pmd" AFK_AGENT_FLOW_KIT_BIN="$finalizer" AFK_FINALIZER_COUNT="$finalizer_count" \
  AFK_PM_FINALIZE_ATTEMPTS=2 AFK_PM_FINALIZE_RETRY_SECONDS=0.01 ORCA_TERMINAL_HANDLE=new-terminal \
  "$ROOT/adapters/pm-session.sh" observe --harness codex --session new-session
for _ in {1..50}; do [[ -f "$finalizer_count" && "$(<"$finalizer_count")" -ge 4 && ! -e "$transition_dir/finalize-pending.json" ]] && break; sleep 0.02; done
eq "next matching event retries persisted finalization" "$(<"$finalizer_count")" 4
if [[ ! -e "$transition_dir/finalize-pending.json" ]]; then ok; else no "successful finalizer retained retry intent"; fi
run_continue "" new-terminal new-session
eq "crash after close leaves ACKED" "$(jq -r .state "$pmd/handoff.json")" ACKED
run_continue "$transition_dir/successor-ack.json" new-terminal new-session
eq "close replay finalizes" "$(jq -r .state "$pmd/handoff.json")" OLD_CLOSED
eq "ownership transfers exactly" "$(jq -r '.session+":"+.previous.session' "$pmd/ownership.json")" new-session:old-session
run_continue "$transition_dir/successor-ack.json" new-terminal new-session
eq "reconciliation increments once" "$(jq -r .pm_continuations "$pmd/budget-state.json")" 1
jq '.control.revision=8' "$pmd/ownership.json" >"$TMP/closed-owner-revision.json"
mv "$TMP/closed-owner-revision.json" "$pmd/ownership.json"
closed_status="$(HOME="$home" AFK_STATE_DIR="$state" AFK_PM_DIR="$pmd" "$ROOT/bin/agent-flow-kit" status --json 2>/dev/null || true)"
eq "closed handoff allows later control revision" "$(jq -r '.extra.pm_control.state+":"+(.extra.pm_handoff.state//"null")' <<<"$closed_status")" valid:OLD_CLOSED
env "${orca_env[@]}" AFK_PM_DIR="$pmd" AFK_PM_AUTOFINALIZE=0 ORCA_TERMINAL_HANDLE=new-terminal \
  "$ROOT/adapters/pm-session.sh" observe --harness codex --session new-session
eq "closed handoff permits current owner observation" "$(jq -r .control.revision "$pmd/ownership.json")" 8
mv "$transition_dir/launch-receipt.json" "$TMP/closed-launch-receipt.json"
jq '.observed_epoch=1' "$pmd/ownership.json" >"$TMP/closed-owner-observation.json"
mv "$TMP/closed-owner-observation.json" "$pmd/ownership.json"
env "${orca_env[@]}" AFK_PM_DIR="$pmd" AFK_PM_AUTOFINALIZE=0 ORCA_TERMINAL_HANDLE=new-terminal \
  "$ROOT/adapters/pm-session.sh" observe --harness codex --session new-session
if [[ "$(jq -r .observed_epoch "$pmd/ownership.json")" != 1 ]]; then
  ok "closed handoff audit receipt does not block current owner observation"
else no "closed handoff still blocks current owner observation"; fi
mv "$TMP/closed-launch-receipt.json" "$transition_dir/launch-receipt.json"

# OLD_CLOSED is itself durable recovery authority. If reconciliation crashed
# after its transition receipt, replay rebuilds the global receipt and counter.
rm -f -- "$pmd/continuation.reconciled.json" "$pmd/budget-state.json"
run_continue "$transition_dir/successor-ack.json" new-terminal new-session
if [[ -f "$pmd/continuation.reconciled.json" ]] && [[ "$(jq -r .pm_continuations "$pmd/budget-state.json")" == 1 ]]; then
  ok "OLD_CLOSED replay heals partial reconciliation idempotently"
else no "OLD_CLOSED replay heals partial reconciliation idempotently"; fi

# A completed transition leaves no fixed-path intent that can poison the next.
jq -nc '{schema:"afk-pm-continuation/1",decisions:["second"],envelope_actions:[],open_escalations:[],budget_state:{},in_flight_dispatches:[],updated_at:"2026-09-14T01:00:00Z",resume_instruction:"resume-second-pm"}' >"$TMP/second-cont.json"
set +e; HOME="$home" AFK_STATE_DIR="$state" AFK_PM_DIR="$pmd" "$ROOT/bin/agent-flow-kit" pm-checkpoint --continuation --write "$TMP/second-cont.json" --json >/dev/null; second_checkpoint_rc=$?; set -e
eq "second continuation accepted" "$second_checkpoint_rc" 2
run_continue "" new-terminal new-session
eq "second rollover launches a new exact transition" "$(jq -r .state "$pmd/handoff.json")" SUCCESSOR_LAUNCHED
env "${orca_env[@]}" AFK_STATE_DIR="$state" AFK_PM_DIR="$pmd" AFK_PM_AUTOFINALIZE=0 ORCA_TERMINAL_HANDLE=next-terminal "$ROOT/adapters/pm-session.sh" observe --harness codex --session next-session
run_continue "" next-terminal next-session
eq "second rollover closes independently" "$(jq -r .state "$pmd/handoff.json")" OLD_CLOSED
eq "two transition-scoped intent directories remain auditable" "$(find "$pmd/transitions" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" 2
eq "two rollovers count exactly twice" "$(jq -r .pm_continuations "$pmd/budget-state.json")" 2

# A shape-correct launcher answer cannot authorize a successor unless it is
# the same receipt as the journaled create attempt.
bad_pm="$TMP/bad-receipt-pm"; mkdir -p "$bad_pm"
cp "$pmd/continuation.json" "$pmd/ownership.json" "$bad_pm/"
bad_launcher="$TMP/bad-receipt-launcher"
printf '%s\n' '#!/usr/bin/env bash' 'receipt="$("$AFK_REAL_LAUNCHER" "$@")" || exit 1' 'jq -c '\''.create_id="sha256:unrelated"'\'' <<<"$receipt"' >"$bad_launcher"
chmod +x "$bad_launcher"
set +e
HOME="$home" AFK_STATE_DIR="$state" AFK_PM_DIR="$bad_pm" AFK_LAUNCH_COUNT_FILE="$TMP/bad-launch-count" \
  AFK_REAL_LAUNCHER="$launcher" AFK_PM_SUCCESSOR_LAUNCHER="$bad_launcher" ORCA_TERMINAL_HANDLE=next-terminal \
  "$ROOT/bin/agent-flow-kit" pm-continue --json >/dev/null 2>&1
bad_receipt_rc=$?
set -e
eq "unrelated receipt remains held" "$(jq -r .state "$bad_pm/handoff.json"):$bad_receipt_rc" 'CHECKPOINTED:2'
eq "unrelated receipt leaves old owner authoritative" "$(jq -r .session "$bad_pm/ownership.json")" next-session
if [[ ! -e "$bad_pm/transitions/$(jq -r .transition_id "$bad_pm/handoff.json")/launch-receipt.json" ]]; then
  ok "unrelated receipt is not persisted as accepted"
else no "unrelated receipt was persisted"; fi

# Corruption and a different active continuation both fail closed. Each gets
# its own HOME/AFK_STATE_DIR (fresh temp dirs, not the ambient environment's):
# without one, afk_lock_acquire judges the REAL host's lock file before the
# corrupt/different artifact is ever read, so a lock genuinely busy elsewhere
# on the host (e.g. a real dispatch running concurrently) turns an expected
# artifact-refusal (exit 1) into a lock refusal (exit 2) — timing-dependent
# and exactly the kind of leak a scoped temp dir exists to prevent.
corrupt="$TMP/corrupt-pm"; corrupt_home="$TMP/corrupt-pm-home"; corrupt_state="$TMP/corrupt-pm-state"
mkdir -p "$corrupt" "$corrupt_home" "$corrupt_state"
cp "$pmd/continuation.json" "$corrupt/continuation.json"; printf '{bad\n' >"$corrupt/handoff.json"; cp "$pmd/ownership.json" "$corrupt/ownership.json"
before="$(sha256sum "$corrupt/handoff.json")"
set +e; HOME="$corrupt_home" AFK_STATE_DIR="$corrupt_state" AFK_PM_DIR="$corrupt" ORCA_TERMINAL_HANDLE=new-terminal "$ROOT/bin/agent-flow-kit" pm-continue --json >/dev/null 2>&1; corrupt_rc=$?; set -e
eq "corrupt handoff refuses" "$corrupt_rc" 1; eq "corrupt handoff not replaced" "$(sha256sum "$corrupt/handoff.json")" "$before"
active_before="$(sha256sum "$pmd/continuation.json")"; jq '.resume_instruction="different"' "$pmd/continuation.json" >"$TMP/different-cont.json"
# Re-open the completed state as active to exercise the artifact guard.
jq '.state="ACKED"' "$pmd/handoff.json" >"$pmd/h"; mv "$pmd/h" "$pmd/handoff.json"
different_home="$TMP/different-pm-home"; different_state="$TMP/different-pm-state"; mkdir -p "$different_home" "$different_state"
set +e; HOME="$different_home" AFK_STATE_DIR="$different_state" AFK_PM_DIR="$pmd" "$ROOT/bin/agent-flow-kit" pm-checkpoint --continuation --write "$TMP/different-cont.json" --json >/dev/null 2>&1; different_rc=$?; set -e
eq "different active continuation refuses" "$different_rc" 2; eq "active continuation unchanged" "$(sha256sum "$pmd/continuation.json")" "$active_before"
# --- AFK-VIS-1A: Claude status line layout (design checklist 1-10, 12) ---
set +e
vis="$TMP/vis"; mkdir -p "$vis/rt" "$vis/pm" "$vis/state/adapters" "$vis/wd"; vnow="$(date +%s)"
vstatus() { jq -nc --argjson x "${1:-{\}}" '{schema_version:"1.0",kind:"lifecycle_result",orchestration:{state:"NOT_AVAILABLE",session:null},dispatch_monitor:{state:"IDLE",dispatches:[]},overall:{state:"READY_WITH_WARNINGS"},extra:{auto_update:{enrolled:true,health:"ok",platform:"linux",update_available:false,last_result:{state:"CURRENT"}},catalog:{findings:[]}}} * $x'; }
vcache() { vstatus "$2" >"$vis/$1.json"; touch -d "@$((vnow - ${3:-30}))" "$vis/$1.json"; }
vplain() { AFK_STATUS_CACHE_DIR="$vis/rt" "$ROOT/adapters/render-status.sh" --harness claude --form claude --now "$vnow" --cache "$vis/$1.json" "${@:2}"; }
vpm() { (cd "$vis/wd" && AFK_PM_DIR="$vis/pm" ORCA_TERMINAL_HANDLE=vt AFK_RUNTIME_SESSION_ID=vs vplain "$@"); }
jq -nc --arg p "$(cd "$vis/wd" && pwd -P)" '{schema:"afk-pm-ownership/2",owned:true,role:"PM",harness:"claude",session:"vs",terminal:"vt",worktree:{path:$p,id:"w"}}' >"$vis/pm/ownership.json"
vwidth() { jq -Rr 'gsub("\u001b\\[[0-9;]*m";"")|length'; }
esc=$'\033'
vcache plain '{}'
eq "plain chat with a current updater: AFK prints nothing" "$(vplain plain)" ""
vcache pmline '{"dispatch_monitor":{"dispatches":[{"state":"WORKING"},{"state":"BLOCKED"},{"state":"SETTLED"},{"state":"DONE"}]},"extra":{"pm_handoff":{"state":"ACKED"}}}'
out="$(vpm pmline)"; plain_out="$(vpm pmline | sed "s/$esc\[[0-9;]*m//g")"
eq "PM line counts only active dispatches" "$plain_out" "L	AFK PM · 1 blocked · 1 worker · handing off to successor"
eq "role is PM only through the ownership binding" "$(vplain pmline | sed "s/$esc\[[0-9;]*m//g")" "L	AFK · 1 blocked · handing off to successor"
# Update and health states (2.5), stale at 90 s vs 200 s (F9).
vcache upd '{"extra":{"auto_update":{"update_available":true,"enrolled":true,"platform":"linux"}}}'
eq "Linux enrolled update-ready wording" "$(vplain upd | sed "s/$esc\[[0-9;]*m//g")" "L	AFK · update ready: applies at next session start"
vcache updm '{"extra":{"auto_update":{"update_available":true,"enrolled":false,"platform":"darwin"}}}'
eq "Mac update-available wording" "$(vplain updm | sed "s/$esc\[[0-9;]*m//g")" "L	AFK · update available: run agent-flow-kit update"
vcache sick '{"extra":{"auto_update":{"health":"check_stale"},"catalog":{"findings":[{"code":"CATALOG_SYNC_STALE"}]}}}'
eq "unhealthy updater and stale catalog" "$(vplain sick | sed "s/$esc\[[0-9;]*m//g")" "L	AFK · updater unhealthy: run agent-flow-kit status · catalog stale"
vcache stale90 '{}' 90; vcache stale200 '{}' 200
eq "age 90 s shows nothing (plain and PM)" "$(vpm stale90 | sed "s/$esc\[[0-9;]*m//g")" "L	AFK PM"
eq "age 200 s shows (Nm old) right after the role" "$(vpm stale200 | sed "s/$esc\[[0-9;]*m//g")" "L	AFK PM (3m old)"
eq "stale plain chat stays silent" "$(vplain stale200)" ""
# Alerts (2.4): keyword position, severity order, +N more, reason table, verbatim unknown code.
vcache a_nh '{"orchestration":{"session":{"needs_human":true}},"findings":[{"severity":"owner_action","reason":"WORKER_HEARTBEAT_EXPIRED"}]}'
vcache a_ck '{"extra":{"pm_budget":{"state":"CHECKPOINT_DUE","reason":"PM_CHECKPOINT_DUE","needs_human":false}}}'
vcache a_ct '{"extra":{"pm_budget":{"state":"CONTINUATION_REQUIRED","reason":"PM_CONTINUATION_REQUIRED","needs_human":true}},"findings":[{"severity":"owner_action","reason":"PM_CONTINUATION_REQUIRED"}]}'
vcache a_unk '{"findings":[{"severity":"owner_action","reason":"SOME_FUTURE_CODE"}]}'
vcache a_many '{"orchestration":{"session":{"needs_human":true}},"extra":{"pm_budget":{"state":"CHECKPOINT_DUE"}}}'
for st in nh:"NEEDS YOU" ck:CHECKPOINT ct:"HANDOFF NOW"; do
  a="$(vpm "a_${st%%:*}" | grep '^A')"; ap="$(sed "s/$esc\[[0-9;]*m//g;s/^A	//" <<<"$a")"
  head20="${ap:0:20}"; kw="${st#*:}"; kw="${kw#\"}"
  [[ "$head20" == *"${kw%% *}"* && "$a" == *"${esc}[1;7;3"* ]] && ok || no "alert ${st%%:*} keyword in first 20 columns, reverse video: $ap"
done
eq "NEEDS_HUMAN detail comes from the reason table" "$(vpm a_nh | sed "s/$esc\[[0-9;]*m//g" | sed -n 's/^A	//p')" " ! AFK NEEDS YOU  a worker went quiet: look at it · PM"
eq "an unknown reason code prints verbatim" "$(vplain a_unk | sed "s/$esc\[[0-9;]*m//g" | sed -n 's/^A	//p')" " ! AFK NEEDS YOU  SOME_FUTURE_CODE"
eq "highest severity wins, with +N more" "$(vplain a_many | sed "s/$esc\[[0-9;]*m//g" | sed -n 's/^A	//p')" " ! AFK NEEDS YOU  your decision is needed +1 more"
eq "continuation is not also reported as needs-you" "$(vplain a_ct | grep -c '^A')" 1
eq "the alert keeps its age when data is stale" "$(vpm a_nh | sed -n 's/^A	//p' | sed "s/$esc\[[0-9;]*m//g" | grep -c 'a worker went quiet')" 1
vcache a_stale '{"extra":{"pm_budget":{"state":"CHECKPOINT_DUE"}}}' 260
[[ "$(vplain a_stale | sed -n 's/^A	//p')" == *"· 4m"* ]] && ok || no "stale alert carries its age"
# Width and reset for the worst-case fixture (checklist 5), plus debug-noise ban (checklist 3).
vcache worst '{"orchestration":{"session":{"needs_human":true}},"findings":[{"severity":"owner_action","reason":"AN_EXTREMELY_LONG_UNKNOWN_REASON_CODE_THAT_KEEPS_GOING_AND_GOING_PAST_ANY_WIDTH_BUDGET"}],"dispatch_monitor":{"dispatches":[{"state":"BLOCKED"},{"state":"WORKING"},{"state":"WORKING"},{"state":"WORKING"}]},"extra":{"pm_budget":{"state":"CHECKPOINT_DUE"},"pm_handoff":{"state":"SUCCESSOR_LAUNCHED"},"auto_update":{"update_available":true,"enrolled":false,"platform":"darwin"},"catalog":{"findings":[{"code":"X"}]}}}' 260
all_out=""
for f in plain pmline upd updm sick stale200 a_nh a_ck a_ct a_unk a_many worst; do all_out+="$(vpm "$f")"$'\n'; done
w_ok=1; r_ok=1
while IFS=$'\t' read -r tag body; do
  [[ -n "$tag" ]] || continue
  (( $(vwidth <<<"$body") <= 100 )) || { w_ok=0; printf 'too wide: %s\n' "$body"; }
  [[ "$body" == *"${esc}[0m" ]] || { r_ok=0; printf 'no reset: %s\n' "$body"; }
done <<<"$all_out"
eq "AFK and alert lines are at most 100 columns in every fixture" "$w_ok" 1
eq "every AFK line ends with a reset" "$r_ok" 1
[[ "$all_out" != *NOT_EVALUATED* && "$all_out" != *NOT_AVAILABLE* && "$all_out" != *owner=* && "$all_out" != *bridge=* && "$all_out" != *'UNAVAILABLE['* ]] && ok || no "default output carries no debug fields"
eq "the worst case keeps the label and drops low-rank fields" "$(vpm worst | sed "s/$esc\[[0-9;]*m//g" | sed -n 's/^L	//p' | cut -c1-6)" "AFK PM"
# NO_COLOR and verbose (checklists 9, 10).
[[ "$(NO_COLOR=1 vpm worst | grep -c "$esc")" == 0 && "$(NO_COLOR=1 vpm worst)" == *'! AFK NEEDS YOU'* ]] && ok || no "NO_COLOR removes every ESC and keeps ! plus keyword"
eq "verbose adds exactly one debug line" "$(( $(AFK_STATUS_VERBOSE=1 vpm pmline | wc -l) - $(vpm pmline | wc -l) ))" 1
[[ "$(AFK_STATUS_VERBOSE=1 vpm pmline | grep '^V')" == *NOT_EVALUATED*"role_source=pm_binding"*"prior=none"* ]] && ok || no "verbose line carries the old dump and provenance"
# Compositor: byte-identical passthrough, replay, bounds (checklists 1, 2, 7, 8, 12).
vd="$TMP/vis-comp"; mkdir -p "$vd/state/adapters" "$vd/cache"
jq -nc --arg b "$vd/state/adapters/prior.json" '{backup:$b}' >"$vd/state/adapters/claude.json"
vprior() { jq -nc --arg c "$1" '{value:{command:$c}}' >"$vd/state/adapters/prior.json"; }
printf '\033[94mSession [██░░] 42%%\033[0m | Weekly [██████] 75%%  \nContext [██] 23%% \033[2m|\033[0m Pace\n\n\033[35mline three\033[0m\n' >"$vd/prior.txt"
printf '\033[94mSession [██░░] 42%%\033[0m | Weekly [██████] 75%%  \nContext [██] 23%% \033[2m|\033[0m Pace\n\033[35mline three\033[0m\n' >"$vd/prior.expected"
vcomp() { env -u ORCA_TERMINAL_HANDLE AFK_STATE_DIR="$vd/state" AFK_STATUS_CACHE="$1" AFK_STATUS_CACHE_DIR="$vd/cache" AFK_STATUS_REFRESH_SECONDS=999999 "${@:2}" "$ROOT/adapters/claude/statusline.sh" <"$claude_input"; }
vprior "cat $vd/prior.txt"
vcomp "$vis/plain.json" >"$vd/out1"
cmp -s "$vd/out1" "$vd/prior.expected" && ok || no "plain chat prints exactly the owner's lines (byte-identical, empty line dropped)"
vcomp "$vis/a_ck.json" >"$vd/out2"
cmp -s <(tail -n +2 "$vd/out2") "$vd/prior.expected" && [[ "$(head -1 "$vd/out2")" == *'! AFK CHECKPOINT'* ]] && ok || no "alert line above, owner's lines byte-identical below"
eq "last-good copy is private" "$(stat -c %a "$vd/cache/prior-last-good.out" 2>/dev/null || stat -f %Lp "$vd/cache/prior-last-good.out")" 600
vprior "sleep 30 & echo \$! >$vd/child.pid; wait"
start="$(date +%s)"; vcomp "$vis/plain.json" AFK_CLAUDE_PRIOR_TIMEOUT_SECONDS=1.37 >"$vd/out3"; took=$(( $(date +%s) - start ))
cmp -s "$vd/out3" "$vd/prior.expected" && ok || no "a timed-out prior replays the last good lines verbatim"
(( took <= 4 )) && ok || no "prior is bounded (${took}s)"
sleep 0.5; kill -0 "$(cat "$vd/child.pid")" 2>/dev/null && no "prior's process group is killed on timeout" || ok
touch -d "@$((vnow - 400))" "$vd/cache/prior-last-good.out"
vcomp "$vis/plain.json" AFK_CLAUDE_PRIOR_TIMEOUT_SECONDS=1.37 >"$vd/out4"
[[ "$(<"$vd/out4")" != *'line three'* ]] && ok || no "a last-good copy older than 300 s is not replayed"
[[ "$(sed "s/$esc\[[0-9;]*m//g" "$vd/out4")" == *'5h ['* ]] && ok || no "a timeout with no usable replay falls back to the usage line"
sleep 0.3
eq "no orphan watchdog sleep after a timeout" "$(pgrep -f 'sleep 1.37' | wc -l | tr -d ' ')" 0
vprior "true"; rm -f "$vd/cache/prior-last-good.out"
jq -nc --argjson t "$((vnow - 5))" '{schema:"afk-runtime-observation/1",harness:"claude",observed_at:($t|todate),model:{value:"Opus 5.5"},context:{used_percentage:23,limit_tokens:1000000},rate_limits:{seven_day:{used_percentage:75}}}' >"$vis/rt/runtime-claude.json"
u="$(vplain plain --usage | sed "s/$esc\[[0-9;]*m//g" | sed -n 's/^U	//p')"
eq "no prior: usage line omits unknown five_hour" "$u" "7d [██████░░] 75% | ctx 23% of 1M | Opus 5.5"
# A host with neither timeout nor gtimeout: the renderer and the prior bound still work.
nb="$TMP/nobound-bin"; mkdir -p "$nb"
for f in /usr/bin/* /bin/*; do case "${f##*/}" in timeout|gtimeout) ;; *) ln -sf "$f" "$nb/${f##*/}" ;; esac; done 2>/dev/null
eq "the fixture PATH hides timeout and gtimeout" "$(PATH="$nb" command -v timeout gtimeout | wc -l | tr -d ' ')" 0
[[ "$(PATH="$nb" vpm a_ck | grep '^A')" == *'! AFK CHECKPOINT'* && "$(PATH="$nb" vpm a_ck)" != *STATUS_TIMEOUT* ]] && ok || no "renderer works without timeout/gtimeout"
vprior "cat $vd/prior.txt"
PATH="$nb" vcomp "$vis/a_ck.json" >"$vd/out5"
cmp -s <(tail -n +2 "$vd/out5") "$vd/prior.expected" && ok || no "compositor works without timeout/gtimeout"
# Fail-open: no jq, or no scratch space, still prints the owner's lines.
vprior "cat \"$vd/prior.txt\""
nj="$TMP/nojq-bin"; mkdir -p "$nj"
for f in /usr/bin/* /bin/*; do [[ "${f##*/}" == jq ]] || ln -sf "$f" "$nj/${f##*/}"; done 2>/dev/null
eq "the fixture PATH hides jq" "$(PATH="$nj" command -v jq | wc -l | tr -d ' ')" 0
PATH="$nj" vcomp "$vis/plain.json" >"$vd/out6"
cmp -s "$vd/out6" "$vd/prior.expected" && ok || no "without jq the owner's lines still print"
vcomp "$vis/plain.json" TMPDIR=/nonexistent/afk >"$vd/out7"
cmp -s "$vd/out7" "$vd/prior.txt" && ok || no "with an unwritable TMPDIR the owner's lines still print"
# A fast prior leaves no watchdog sleep behind.
vcomp "$vis/plain.json" AFK_CLAUDE_PRIOR_TIMEOUT_SECONDS=9.37 >/dev/null; sleep 0.3
eq "no orphan watchdog sleep after a fast prior" "$(pgrep -f 'sleep 9.37' | wc -l | tr -d ' ')" 0
# The usage line does not depend on the lifecycle cache.
u="$(vplain missing-cache --usage | sed "s/$esc\[[0-9;]*m//g" | sed -n 's/^U	//p')"
eq "usage line prints when the lifecycle cache is missing" "$u" "7d [██████░░] 75% | ctx 23% of 1M | Opus 5.5"
# Alert age is capped.
vcache a_old '{"extra":{"pm_budget":{"state":"CHECKPOINT_DUE"}}}' 90000
[[ "$(vplain a_old | sed -n 's/^A	//p')" == *'>16h'* ]] && ok || no "alert age is capped"
set -e
# ===== AFK-VIS-2: Claude status line wiring, recovery and status (separate section) =====
vis2_mgr() { # <home> <state> args... ; runs the adapter manager against a fixture home
  local h="$1" st="$2"; shift 2
  "$ROOT/adapters/manage.sh" "$@" --home "$h" --state-dir "$st" --adapter-root "$ROOT/adapters"
}
vis2_status() { # <home> <state> -> claude_statusline state from `status --json`
  (cd "$TMP" && env -u AFK_ORCA_BIN HOME="$1" AFK_STATE_DIR="$2" "$ROOT/bin/agent-flow-kit" status --json 2>/dev/null \
    | jq -r '.extra.claude_statusline.state // "MISSING"') || true
}
vis2_wrapper="$ROOT/adapters/claude/statusline.sh"
# Everything except the owned command and the hook groups must be byte-equal.
vis2_owner_view() { jq -S 'del(.hooks, .statusLine.command)' "$1"; }

# enroll on a host that already has ccstatusline: wrapped, prior saved, record written
v2h="$TMP/vis2-home-a"; v2s="$TMP/vis2-state-a"; mkdir -p "$v2h/.claude"
jq -nc '{model:"opus",statusLine:{type:"command",command:"bunx -y ccstatusline-usage@latest",padding:2,refreshInterval:60},permissions:{allow:["Bash(ls)"]}}' >"$v2h/.claude/settings.json"
cp "$v2h/.claude/settings.json" "$TMP/vis2-a-before.json"
eq "never-enrolled host reports NOT_INSTALLED" "$(vis2_status "$v2h" "$v2s")" CLAUDE_STATUSLINE_NOT_INSTALLED
vis2_mgr "$v2h" "$v2s" install claude >/dev/null || no "vis2 install with ccstatusline"
eq "vis2 wrapper is the status line command" "$(jq -r .statusLine.command "$v2h/.claude/settings.json")" "$vis2_wrapper"
eq "vis2 prior keeps the owner's command" "$(jq -r .value.command "$v2s/adapters/claude-prior.json")" "bunx -y ccstatusline-usage@latest"
[[ -f "$v2s/adapters/claude.json" ]] && ok || no "vis2 record written"
if diff <(vis2_owner_view "$TMP/vis2-a-before.json") <(vis2_owner_view "$v2h/.claude/settings.json") >/dev/null; then ok; else no "vis2 install changed keys other than the command and hooks"; fi
eq "vis2 no env key is ever written" "$(jq 'has("env")' "$v2h/.claude/settings.json")" false
eq "wired host reports COMPOSED" "$(vis2_status "$v2h" "$v2s")" CLAUDE_STATUSLINE_COMPOSED

# enroll twice: nothing changes
v2sum="$(cksum "$v2h/.claude/settings.json" "$v2s/adapters/claude.json" "$v2s/adapters/claude-prior.json")"
vis2_mgr "$v2h" "$v2s" install claude >/dev/null || no "vis2 second install"
eq "vis2 second install changes no file" "$(cksum "$v2h/.claude/settings.json" "$v2s/adapters/claude.json" "$v2s/adapters/claude-prior.json")" "$v2sum"

# This proves the reinstall after a script change leaves the prior and settings unchanged;
# update's in-place overwrite of the script follows because the wiring stores a path.
# update on an enrolled host: the installed scripts are refreshed in place and
# the owner's saved prior is untouched (the wiring points at a path, not a copy)
v2rt="$TMP/vis2-runtime"; mkdir -p "$v2rt"; cp -R "$ROOT/adapters/." "$v2rt/"; mkdir -p "$v2rt/bin"; cp "$ROOT/bin/afk-session-start" "$v2rt/bin/"
v2h2="$TMP/vis2-home-b"; v2s2="$TMP/vis2-state-b"; mkdir -p "$v2h2/.claude"
jq -nc '{statusLine:{type:"command",command:"owner-tool",padding:1}}' >"$v2h2/.claude/settings.json"
"$v2rt/manage.sh" install claude --home "$v2h2" --state-dir "$v2s2" --adapter-root "$v2rt" >/dev/null || no "vis2 runtime install"
v2prior="$(cksum <"$v2s2/adapters/claude-prior.json")"; v2set="$(cksum <"$v2h2/.claude/settings.json")"
printf '# refreshed by update\n' >>"$v2rt/claude/statusline.sh"
"$v2rt/manage.sh" install claude --home "$v2h2" --state-dir "$v2s2" --adapter-root "$v2rt" >/dev/null || no "vis2 post-update reinstall"
eq "vis2 update keeps the saved prior" "$(cksum <"$v2s2/adapters/claude-prior.json")" "$v2prior"
eq "vis2 update keeps settings.json" "$(cksum <"$v2h2/.claude/settings.json")" "$v2set"
[[ "$(tail -n1 "$v2rt/claude/statusline.sh")" == '# refreshed by update' ]] && ok || no "vis2 refreshed script is what settings points at"

# enroll with no statusLine at all: the wrapper is created
v2h3="$TMP/vis2-home-c"; v2s3="$TMP/vis2-state-c"; mkdir -p "$v2h3/.claude"; printf '{"model":"opus"}\n' >"$v2h3/.claude/settings.json"
vis2_mgr "$v2h3" "$v2s3" install claude >/dev/null || no "vis2 install without statusLine"
eq "vis2 wrapper created from nothing" "$(jq -r .statusLine.command "$v2h3/.claude/settings.json")" "$vis2_wrapper"
eq "vis2 unrelated key survives" "$(jq -r .model "$v2h3/.claude/settings.json")" opus

# the owner's tool overwrites the wrapper: status says so, install refuses, adopt recovers
jq '.statusLine={type:"command",command:"ccstatusline-configurator-output",padding:4,refreshInterval:9}' "$v2h/.claude/settings.json" >"$TMP/vis2-over.json"
mv "$TMP/vis2-over.json" "$v2h/.claude/settings.json"
eq "overwritten wrapper reports OVERWRITTEN" "$(vis2_status "$v2h" "$v2s")" CLAUDE_STATUSLINE_OVERWRITTEN
set +e; vis2_mgr "$v2h" "$v2s" install claude >/dev/null 2>&1; v2rc=$?; set -e
eq "plain install still refuses an overwritten wrapper" "$v2rc" 3
cp "$v2h/.claude/settings.json" "$TMP/vis2-over-before.json"
vis2_mgr "$v2h" "$v2s" install claude --adopt-current >/dev/null || no "vis2 adopt-current"
eq "adopt re-points at the wrapper" "$(jq -r .statusLine.command "$v2h/.claude/settings.json")" "$vis2_wrapper"
eq "adopt keeps padding" "$(jq -r .statusLine.padding "$v2h/.claude/settings.json")" 4
eq "adopt keeps refreshInterval" "$(jq -r .statusLine.refreshInterval "$v2h/.claude/settings.json")" 9
eq "adopt saves the NEW command as the prior" "$(jq -r .value.command "$v2s/adapters/claude-prior.json")" ccstatusline-configurator-output
if diff <(vis2_owner_view "$TMP/vis2-over-before.json") <(vis2_owner_view "$v2h/.claude/settings.json") >/dev/null; then ok; else no "vis2 adopt changed keys other than the command"; fi
eq "vis2 adopt writes no env key" "$(jq 'has("env")' "$v2h/.claude/settings.json")" false
eq "adopt backs up the old prior" "$(jq -r .value.command "$(find "$v2h/.config/agent-flow-kit/backups" -name 'claude-prior.*.json' | head -n1)")" "bunx -y ccstatusline-usage@latest"
eq "adopted host reports COMPOSED" "$(vis2_status "$v2h" "$v2s")" CLAUDE_STATUSLINE_COMPOSED
v2sum="$(cksum "$v2h/.claude/settings.json" "$v2s/adapters/claude.json" "$v2s/adapters/claude-prior.json")"
vis2_mgr "$v2h" "$v2s" install claude --adopt-current >/dev/null || no "vis2 second adopt"
eq "adopt is idempotent" "$(cksum "$v2h/.claude/settings.json" "$v2s/adapters/claude.json" "$v2s/adapters/claude-prior.json")" "$v2sum"
vis2_mgr "$v2h" "$v2s" install claude >/dev/null || no "vis2 install after adopt"
vis2_mgr "$v2h" "$v2s" remove claude >/dev/null || no "vis2 remove after adopt"
eq "remove after adopt restores the adopted owner command" "$(jq -r .statusLine.command "$v2h/.claude/settings.json")" ccstatusline-configurator-output

# adopt refuses a missing or malformed statusLine and changes nothing
for v2case in missing malformed; do
  v2h4="$TMP/vis2-home-$v2case"; v2s4="$TMP/vis2-state-$v2case"; mkdir -p "$v2h4/.claude"; printf '{"model":"opus"}\n' >"$v2h4/.claude/settings.json"
  vis2_mgr "$v2h4" "$v2s4" install claude >/dev/null || no "vis2 install for $v2case"
  if [[ "$v2case" == missing ]]; then jq 'del(.statusLine)' "$v2h4/.claude/settings.json" >"$TMP/vis2-m.json"
  else jq '.statusLine="just a string"' "$v2h4/.claude/settings.json" >"$TMP/vis2-m.json"; fi
  mv "$TMP/vis2-m.json" "$v2h4/.claude/settings.json"; v2sum="$(cksum "$v2h4/.claude/settings.json" "$v2s4/adapters/claude-prior.json")"
  set +e; v2err="$(vis2_mgr "$v2h4" "$v2s4" install claude --adopt-current 2>&1 >/dev/null)"; v2rc=$?; set -e
  eq "adopt refuses a $v2case statusLine" "$v2rc" 3
  [[ "$v2err" == *STATUSLINE_UNUSABLE* ]] && ok || no "adopt names the $v2case refusal"
  eq "refused adopt changes nothing ($v2case)" "$(cksum "$v2h4/.claude/settings.json" "$v2s4/adapters/claude-prior.json")" "$v2sum"
done
# adopt never chains an AFK wrapper, from this or any other runtime root
for v2wrap in "/other/home/.agents/skills/afk-runtime/claude/statusline.sh" "/opt/x/claude/statusline.sh"; do
  v2h5="$TMP/vis2-home-chain"; v2s5="$TMP/vis2-state-chain"; rm -rf "$v2h5" "$v2s5"; mkdir -p "$v2h5/.claude"
  printf '{"statusLine":{"type":"command","command":"owner"}}\n' >"$v2h5/.claude/settings.json"
  vis2_mgr "$v2h5" "$v2s5" install claude >/dev/null || no "vis2 install for chain"
  jq --arg c "$v2wrap" '.statusLine.command=$c' "$v2h5/.claude/settings.json" >"$TMP/vis2-c.json"; mv "$TMP/vis2-c.json" "$v2h5/.claude/settings.json"
  v2sum="$(cksum "$v2h5/.claude/settings.json" "$v2s5/adapters/claude-prior.json" "$v2s5/adapters/claude.json")"
  set +e; v2err="$(vis2_mgr "$v2h5" "$v2s5" install claude --adopt-current 2>&1 >/dev/null)"; v2rc=$?; set -e
  eq "adopt refuses to chain a wrapper ($v2wrap)" "$v2rc" 3
  [[ "$v2err" == *ADOPT_WOULD_CHAIN_WRAPPER* ]] && ok || no "adopt names the chain refusal ($v2wrap)"
  eq "refused chain changes nothing ($v2wrap)" "$(cksum "$v2h5/.claude/settings.json" "$v2s5/adapters/claude-prior.json" "$v2s5/adapters/claude.json")" "$v2sum"
done
set +e; vis2_mgr "$TMP/vis2-home-none" "$TMP/vis2-state-none" install codex --adopt-current >/dev/null 2>&1; v2rc=$?; set -e
eq "adopt-current is refused for other adapters" "$v2rc" 2
# status is read-only
vis2_mgr "$v2h" "$v2s" install claude >/dev/null || no "vis2 reinstall for the read-only check"
v2sum="$(cksum "$v2h/.claude/settings.json" "$v2s/adapters/claude.json")"; vis2_status "$v2h" "$v2s" >/dev/null
eq "status never writes the wiring" "$(cksum "$v2h/.claude/settings.json" "$v2s/adapters/claude.json")" "$v2sum"
# ===== end AFK-VIS-2 =====

printf '%s\n' "$pass passed, $fail failed"
(( fail == 0 ))
