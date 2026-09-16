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

cp "$TMP/status.json" "$TMP/cache.json"; touch -d '@100' "$TMP/cache.json"
# The generated fixture expands this at runtime.
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nprintf invoked >"$AFK_SLOW_MARKER"\nsleep 1\n' >"$TMP/slow"; chmod +x "$TMP/slow"
out="$(AFK_SLOW_MARKER="$TMP/slow-marker" AFK_STATUS_BIN="$TMP/slow" "$ROOT/adapters/render-status.sh" --cache "$TMP/cache.json" --now 200 --harness claude)"
if [[ "$out" == STALE* ]]; then ok; else no "stale fallback"; fi
if [[ ! -e "$TMP/slow-marker" ]]; then ok; else no "renderer invoked slow producer"; fi
out="$(AFK_SLOW_MARKER="$TMP/slow-marker" AFK_STATUS_BIN="$TMP/slow" "$ROOT/adapters/render-status.sh" --cache "$TMP/missing.json" --now 200 --harness claude)"
eq "unavailable fallback" "$out" 'AFK UNAVAILABLE[STATUS_UNAVAILABLE]'
if [[ ! -e "$TMP/slow-marker" ]]; then ok; else no "unavailable renderer invoked producer"; fi

printf '%s\n' "$pass passed, $fail failed"
((fail == 0))
