#!/usr/bin/env bash
# orca-resolver-tests.sh — lib/afk-orca.sh: the one Orca resolver and bounded
# runner (AD-28 R1, R2). Stubs only, except (g), which runs the host's real
# ~/.local/bin/orca-ide --version when it exists and is skipped otherwise.
# SC2016: the single-quoted snippets run in a child shell and must stay literal.
# shellcheck disable=SC2016
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/lib/afk-orca.sh"
TMP="$(mktemp -d)"; trap 'rm -rf -- "$TMP"' EXIT
pass=0; fail=0; skip=0
ok() { pass=$((pass + 1)); }
no() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }
eq() { if [[ "$2" == "$3" ]]; then ok; else no "$1 expected=$3 got=$2"; fi; }
absent() { if [[ ! -e "$2" ]]; then ok; else no "$1: $2 exists"; fi; }

H="$TMP/home"; mkdir -p "$H/.local/bin" "$H/.config/agent-flow-kit"
CFG="$H/.config/agent-flow-kit/host.json"
BASE_PATH="/usr/local/bin:/usr/bin:/bin"

# stub <path> <name>: a well-behaved Orca CLI. It counts --version calls, logs
# argv, TERM, stdin and the two remote-runtime variables, and answers per
# STUB_MODE.
stub() {
  cat >"$1" <<STUB
#!/bin/bash
if [[ "\${1:-}" == --version ]]; then
  printf 'v\n' >>"$TMP/$2.versions"; printf '1.4.216\n'; exit 0
fi
printf '%s\n' "\$*" >>"$TMP/$2.argv"
printf 'TERM=%s ENV=%s PAIR=%s STDIN=%s\n' "\${TERM:-}" "\${ORCA_ENVIRONMENT:-unset}" \
  "\${ORCA_PAIRING_CODE:-unset}" "\$(cat)" >"$TMP/$2.env"
case "\${STUB_MODE:-ok}" in
  ok)        printf '{"ok":true,"result":{"terminals":[{"handle":"a"}],"totalCount":1,"truncated":false}}\n' ;;
  envelope)  printf '{"ok":false,"error":{"code":"terminal_handle_stale"}}\n'; exit 1 ;;
  fail)      exit 3 ;;
  usage)     printf 'Usage: orca <command>\n'; exit 1 ;;
  truncated) printf '{"ok":true,"result":{"terminals":[],"truncated":true}}\n' ;;
  partial)   printf '{"ok":true,"result":{"terminals":[{"handle":"a"}],"totalCount":5,"truncated":false}}\n' ;;
  rc124)     exit 124 ;;
esac
STUB
  chmod +x "$1"
}

# in_shell <env assignments...> -- <code>: a clean process with only the
# given environment, the library sourced, then <code>.
in_shell() {
  local -a vars=()
  while [[ "$1" != -- ]]; do vars+=("$1"); shift; done; shift
  env -i HOME="$H" PATH="$BASE_PATH" TMP="$TMP" "${vars[@]}" bash -c ". '$LIB'; $1"
}

reset_config() { rm -f -- "$CFG" "$TMP"/*.versions "$TMP"/*.argv "$TMP"/*.env; }

stub "$TMP/host-orca" host
stub "$TMP/cli-orca" cli
stub "$TMP/afk-orca" afk
stub "$H/.local/bin/orca-ide" default

# --- (d) the resolution order across all four sources ------------------------
reset_config
printf '{"orca_bin":"%s"}\n' "$TMP/host-orca" >"$CFG"
all=(ORCA_CLI_COMMAND="$TMP/cli-orca" AFK_ORCA_BIN="$TMP/afk-orca")
eq "(d) host.orca_bin wins over every other source" "$(in_shell "${all[@]}" -- afk_orca_bin)" "$TMP/host-orca"
printf '{"other":true}\n' >"$CFG"
eq "(d) a host.json without orca_bin falls to ORCA_CLI_COMMAND" "$(in_shell "${all[@]}" -- afk_orca_bin)" "$TMP/cli-orca"
rm -f -- "$CFG"
eq "(d) no host.json: ORCA_CLI_COMMAND" "$(in_shell "${all[@]}" -- afk_orca_bin)" "$TMP/cli-orca"
eq "(d) then AFK_ORCA_BIN" "$(in_shell AFK_ORCA_BIN="$TMP/afk-orca" -- afk_orca_bin)" "$TMP/afk-orca"
eq "(d) a relative ORCA_CLI_COMMAND is skipped, never run" \
  "$(in_shell ORCA_CLI_COMMAND=orca AFK_ORCA_BIN="$TMP/afk-orca" -- afk_orca_bin)" "$TMP/afk-orca"
eq "(d) then the platform default" "$(in_shell AFK_ORCA_BIN=orca-ide -- afk_orca_bin)" "$H/.local/bin/orca-ide"
reset_config; printf '{"orca_bin":"orca-ide"}\n' >"$CFG"
eq "(d) a relative host.orca_bin refuses, with no fallthrough" \
  "$(in_shell "${all[@]}" -- 'afk_orca_bin; printf "%s" "$AFK_ORCA_CODE"')" "ORCA_CLI_NOT_RESOLVED"
printf 'not json' >"$CFG"
eq "(d) an unreadable host.json refuses" \
  "$(in_shell "${all[@]}" -- 'afk_orca_bin; printf "%s" "$AFK_ORCA_CODE"')" "ORCA_CLI_NOT_RESOLVED"
absent "(d) no refused resolution ran the next candidate" "$TMP/cli.versions"

# --- (c) a candidate that fails --version: ORCA_CLI_NOT_RESOLVED, no fallthrough
reset_config
printf '#!/bin/bash\nprintf "orca 46.1\\n"\n' >"$TMP/not-orca"; chmod +x "$TMP/not-orca"
printf '#!/bin/bash\nexit 1\n' >"$TMP/broken-orca"; chmod +x "$TMP/broken-orca"
for bad in not-orca broken-orca; do
  printf '{"orca_bin":"%s"}\n' "$TMP/$bad" >"$CFG"
  eq "(c) $bad is not resolved" \
    "$(in_shell "${all[@]}" -- 'afk_orca_run t -- terminal list; printf "%s:%s" "$?" "$AFK_ORCA_CODE"')" "1:ORCA_CLI_NOT_RESOLVED"
done
absent "(c) ORCA_CLI_COMMAND was never tried after the chosen candidate failed" "$TMP/cli.versions"
absent "(c) AFK_ORCA_BIN was never tried either" "$TMP/afk.versions"
absent "(c) nor the platform default" "$TMP/default.versions"

# --- (b) a program named orca first on PATH is never executed ----------------
reset_config
mkdir -p "$TMP/fakebin"
cat >"$TMP/fakebin/orca" <<PY
#!/usr/bin/env python3
open("$TMP/python-orca-ran", "w").write("ran")
PY
chmod +x "$TMP/fakebin/orca"
eq "(b) with PATH's orca first, the default orca-ide is used" \
  "$(env -i HOME="$H" PATH="$TMP/fakebin:$BASE_PATH" TMP="$TMP" bash -c ". '$LIB'; afk_orca_run t -- terminal list && printf OK")" "OK"
eq "(b) bare ORCA_CLI_COMMAND=orca is ignored" \
  "$(env -i HOME="$H" PATH="$TMP/fakebin:$BASE_PATH" TMP="$TMP" ORCA_CLI_COMMAND=orca AFK_ORCA_BIN=orca \
    bash -c ". '$LIB'; afk_orca_bin")" "$H/.local/bin/orca-ide"
mv "$H/.local/bin/orca-ide" "$TMP/orca-ide.aside"
eq "(b) with no default either, it refuses rather than use PATH" \
  "$(env -i HOME="$H" PATH="$TMP/fakebin:$BASE_PATH" TMP="$TMP" bash -c ". '$LIB'; afk_orca_run t -- status; printf %s \"\$AFK_ORCA_CODE\"")" \
  "ORCA_CLI_NOT_RESOLVED"
mv "$TMP/orca-ide.aside" "$H/.local/bin/orca-ide"
absent "(b) the PATH orca never ran" "$TMP/python-orca-ran"

# --- (a) a stub that ignores SIGTERM is killed inside bound + grace ----------
cat >"$TMP/hang-orca" <<STUB
#!/bin/bash
[[ "\${1:-}" == --version ]] && { printf '1.4.216\n'; exit 0; }
trap '' TERM
sleep 60 & printf '%s %s\n' "\$\$" "\$!" >"$TMP/hang.pids"
wait
STUB
chmod +x "$TMP/hang-orca"
start="$(date +%s%N)"
got="$(in_shell ORCA_CLI_COMMAND="$TMP/hang-orca" AFK_ORCA_GRACE_SECONDS=1 -- \
  'afk_orca_run --bound 1 t -- terminal list; printf "%s" "$AFK_ORCA_CODE"')"
elapsed_ms=$(( ($(date +%s%N) - start) / 1000000 ))
eq "(a) a TERM-ignoring hang is ORCA_TIMEOUT" "$got" "ORCA_TIMEOUT"
if (( elapsed_ms < 3500 )); then ok; else no "(a) took ${elapsed_ms}ms, bound 1s + grace 1s"; fi
alive=""
read -r -a hang_pids <"$TMP/hang.pids" 2>/dev/null || hang_pids=()
for p in "${hang_pids[@]}"; do kill -0 "$p" 2>/dev/null && alive="$alive $p"; done
eq "(a) the stub and its child are gone" "$alive" ""
printf '#!/bin/bash\ntrap "" TERM\nsleep 60\n' >"$TMP/hang-version"; chmod +x "$TMP/hang-version"
start="$(date +%s%N)"
got="$(in_shell ORCA_CLI_COMMAND="$TMP/hang-version" AFK_ORCA_TIMEOUT_SECONDS=1 AFK_ORCA_GRACE_SECONDS=1 -- \
  'afk_orca_bin; printf "%s" "$AFK_ORCA_CODE"')"
elapsed_ms=$(( ($(date +%s%N) - start) / 1000000 ))
eq "(a) a hanging --version is not resolved" "$got" "ORCA_CLI_NOT_RESOLVED"
if (( elapsed_ms < 3500 )); then ok; else no "(a) verification took ${elapsed_ms}ms"; fi

# --- (e) the fixed classification --------------------------------------------
reset_config
cls() { in_shell ORCA_CLI_COMMAND="$TMP/cli-orca" STUB_MODE="$1" -- \
  'afk_orca_run t -- terminal list; printf "%s|%s|%s" "$?" "$AFK_ORCA_CODE" "$AFK_ORCA_RC"'; }
eq "(e) ok" "$(cls ok)" "0|OK|0"
eq "(e) an ok:false envelope" "$(cls envelope)" "1|ORCA_ERROR:terminal_handle_stale|1"
eq "(e) the envelope reaches the caller" \
  "$(in_shell ORCA_CLI_COMMAND="$TMP/cli-orca" STUB_MODE=envelope -- 'afk_orca_run t -- terminal show; jq -r .error.code <<<"$AFK_ORCA_OUT"')" \
  "terminal_handle_stale"
eq "(e) non-zero, no output" "$(cls fail)" "1|ORCA_CLI_FAILED|3"
eq "(e) non-zero, usage text" "$(cls usage)" "1|ORCA_CLI_FAILED|1"
eq "(e) truncated:true" "$(cls truncated)" "1|ORCA_LIST_INCOMPLETE|0"
eq "(e) totalCount > length" "$(cls partial)" "1|ORCA_LIST_INCOMPLETE|0"
eq "(e) exit 124" "$(cls rc124)" "1|ORCA_TIMEOUT|124"
eq "(e) stdout on success" \
  "$(in_shell ORCA_CLI_COMMAND="$TMP/cli-orca" -- 'afk_orca_run t -- terminal list; jq -r ".result.terminals[0].handle" <<<"$AFK_ORCA_OUT"')" "a"
reset_config
in_shell ORCA_CLI_COMMAND="$TMP/cli-orca" -- 'afk_orca_run t -- terminal list; afk_orca_run t -- worktree show --json; afk_orca_run t -- status' >/dev/null
eq "(e) --json is added once, and kept once" "$(cat "$TMP/cli.argv")" "terminal list --json
worktree show --json
status --json"
eq "(e) --version ran once for three calls in one process" "$(wc -l <"$TMP/cli.versions" | tr -d ' ')" "1"
eq "(e) a cached verdict is never inherited from the environment" \
  "$(in_shell _AFK_ORCA_STATE=OK _AFK_ORCA_PATH=/bin/false ORCA_CLI_COMMAND="$TMP/cli-orca" -- afk_orca_bin)" "$TMP/cli-orca"
eq "(e) a malformed call is refused" \
  "$(in_shell ORCA_CLI_COMMAND="$TMP/cli-orca" -- 'afk_orca_run "Bad Purpose" -- status; printf %s $?')" "2"

# --- (f) remote-runtime variables are stripped; stdin and TERM are fixed ------
reset_config
printf 'fed\n' | in_shell ORCA_CLI_COMMAND="$TMP/cli-orca" ORCA_ENVIRONMENT=thin-client ORCA_PAIRING_CODE=1234 TERM=xterm -- \
  'afk_orca_run t -- status' >/dev/null
eq "(f) ORCA_ENVIRONMENT and ORCA_PAIRING_CODE are unset, stdin is empty, TERM=dumb" \
  "$(cat "$TMP/cli.env")" "TERM=dumb ENV=unset PAIR=unset STDIN="
in_shell ORCA_CLI_COMMAND="$TMP/cli-orca" ORCA_ENVIRONMENT=thin-client -- 'afk_orca_run --environment t -- status' >/dev/null
eq "(f) --environment keeps them deliberately" "$(cat "$TMP/cli.env")" "TERM=dumb ENV=thin-client PAIR=unset STDIN="
reset_config; mkdir -p "$TMP/nobound"
for tool in jq env uname cat; do ln -s "$(command -v "$tool")" "$TMP/nobound/$tool"; done
eq "(f) no timeout or gtimeout: PROBE_BOUND_UNAVAILABLE, never unbounded" \
  "$(env -i HOME="$H" PATH="$TMP/nobound" TMP="$TMP" ORCA_CLI_COMMAND="$TMP/cli-orca" \
    /bin/bash -c ". '$LIB'; afk_orca_run t -- status; printf %s \"\$AFK_ORCA_CODE\"")" "PROBE_BOUND_UNAVAILABLE"
absent "(f) the unbounded call never ran" "$TMP/cli.argv"

# --- bound plus grace never exceeds 60 s (AD-28 R2) ---------------------------
reset_config; mkdir -p "$TMP/tlog"
cat >"$TMP/tlog/timeout" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >>"$TMP/timeout.args"
exec "$(command -v timeout)" "\$@"
STUB
chmod +x "$TMP/tlog/timeout"
env -i HOME="$H" PATH="$TMP/tlog:$BASE_PATH" TMP="$TMP" ORCA_CLI_COMMAND="$TMP/cli-orca" \
  AFK_ORCA_GRACE_SECONDS=10 AFK_ORCA_TIMEOUT_SECONDS=60 \
  bash -c ". '$LIB'; afk_orca_run t -- status; afk_orca_run --bound 60 t -- status" >/dev/null
eq "the handshake and both calls are clamped to bound 50 with grace 10" \
  "$(awk '{print $2, $3}' "$TMP/timeout.args" | sort | uniq -c | awk '{print $1, $2, $3}')" "3 10 50"
eq "an explicit --bound 60 is clamped too" \
  "$(in_shell ORCA_CLI_COMMAND="$TMP/cli-orca" AFK_ORCA_GRACE_SECONDS=10 AFK_ORCA_TRACE=1 -- \
    'afk_orca_run --bound 60 t -- status 2>&1 >/dev/null' 2>&1 | grep -o 'bound=[0-9]* grace=[0-9]*')" "bound=50 grace=10"

# --- (h) identity tuple and the liveness join (AD-28 R4, R5) -----------------
# A stub whose answers come from files, shaped like Orca 1.4.216/217 output
# (orca-model.md section 4, OQ-4): the list and ps carry _meta.runtimeId, and
# an unknown handle is the terminal_handle_stale envelope with exit 1.
cat >"$TMP/lv-orca" <<'STUB'
#!/bin/bash
[[ "${1:-}" == --version ]] && { echo 1.4.217; exit 0; }
printf '%s\n' "$*" >>"$LV/argv"
case "$1 $2" in
  "terminal list") cat "$LV/list" ;;
  "worktree ps") cat "$LV/ps" ;;
  "terminal show") cat "$LV/show"; exit "$(cat "$LV/show.rc" 2>/dev/null || echo 0)" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TMP/lv-orca"
LV="$TMP/lv"; mkdir -p "$LV"
RA=runtime-a
TUPLE='{"handle":"term_pm","runtime_id":"runtime-a","tab_id":"tab-1","leaf_id":"leaf-1","agent_type":"claude"}'
lv_list() { # <runtime> <terminals-json> [truncated]
  jq -nc --arg rt "$1" --argjson t "$2" --argjson tr "${3:-false}" \
    '{ok:true,result:{terminals:$t,totalCount:($t|length),truncated:$tr},_meta:{runtimeId:$rt}}' >"$LV/list"
}
lv_term() { # <connected> <orphaned>
  jq -nc --argjson c "$1" --argjson o "$2" \
    '[{handle:"term_pm",connected:$c,orphaned:$o,tabId:"tab-1",leafId:"leaf-1"}]'
}
lv_ps() { # <runtime> <agents-json>
  jq -nc --arg rt "$1" --argjson a "$2" \
    '{ok:true,result:{worktrees:[{path:"/w",agents:$a}],totalCount:1,truncated:false},_meta:{runtimeId:$rt}}' >"$LV/ps"
}
lv_row() { # <paneKey> <state>
  jq -nc --arg p "$1" --arg s "$2" \
    '[{paneKey:$p,state:$s,agentType:"claude",prompt:"SECRET-PROMPT",lastAssistantMessage:"SECRET-REPLY"}]'
}
lv_stale_show() { # <runtime>
  jq -nc --arg rt "$1" '{ok:false,error:{code:"terminal_handle_stale",message:"terminal_handle_stale"},_meta:{runtimeId:$rt}}' >"$LV/show"
  echo 1 >"$LV/show.rc"
}
lv() { # [tuple] -> "state reason"
  rm -f "$LV/argv"
  env -i HOME="$H" PATH="$BASE_PATH" LV="$LV" ORCA_CLI_COMMAND="$TMP/lv-orca" \
    bash -c '. "$1"; afk_orca_terminal_state "$2"; printf "%s %s" "$AFK_ORCA_TERMINAL_STATE" "$AFK_ORCA_TERMINAL_REASON"' _ "$LIB" "${1:-$TUPLE}"
}
reset_config
lv_list "$RA" "$(lv_term true false)"; lv_ps "$RA" "$(lv_row tab-1:leaf-1 "done")"
eq "(h) an idle PM (done row) is live" "$(lv)" "live null"
eq "(h) the list call pages explicitly" "$(grep -c -- '^terminal list --limit 1000 --json$' "$LV/argv")" "1"
lv_ps "$RA" "$(lv_row tab-1:leaf-1 waiting)"
eq "(h) a PM at a permission prompt (waiting row) is live" "$(lv)" "live null"
lv_list "$RA" "$(lv_term true true)"; lv_ps "$RA" "$(lv_row tab-1:leaf-1 working)"
eq "(h) a working PM that is orphaned:true is detached, never stale" "$(lv)" "detached PM_TERMINAL_DETACHED"
lv_list "$RA" "$(lv_term true false)"; lv_ps "$RA" '[]'
eq "(h) a listed PM whose agent row is gone (exited to shell) is detached" "$(lv)" "detached PM_TERMINAL_DETACHED"
lv_ps "$RA" "$(lv_row pty:3:pty:3 working)"
eq "(h) a re-attached pty:N:pty:N pane key never matches a UUID pane" "$(lv)" "detached PM_TERMINAL_DETACHED"
lv_ps "$RA" "$(jq -c '.[0].agentType="codex"' <<<"$(lv_row tab-1:leaf-1 "done")")"
eq "(h) a row of another agent type is not the registered PM" "$(lv)" "detached PM_TERMINAL_DETACHED"
lv_ps runtime-b "$(lv_row tab-1:leaf-1 "done")"
eq "(h) agent rows from another runtime are never joined" "$(lv)" "unknown ORCA_UNAVAILABLE"
lv_list "$RA" "$(lv_term false false)"
eq "(h) connected:false is disconnected" "$(lv)" "disconnected PM_OWNER_DISCONNECTED"
lv_list "$RA" '[]'; lv_stale_show "$RA"
eq "(h) absent from a complete list plus terminal_handle_stale is stale" "$(lv)" "stale PM_TERMINAL_STALE"
lv_stale_show runtime-b
eq "(h) a stale answer from another runtime proves nothing" "$(lv)" "unknown PM_TERMINAL_UNPROVEN"
echo '{"ok":false,"error":{"code":"runtime_unavailable"}}' >"$LV/show"
eq "(h) absent with any other show answer is unknown" "$(lv)" "unknown PM_TERMINAL_UNPROVEN"
lv_list "$RA" '[]' true; lv_stale_show "$RA"
eq "(h) absent from a truncated list is unknown" "$(lv)" "unknown ORCA_LIST_INCOMPLETE"
lv_list runtime-b '[]'
eq "(h) absent after a runtime change is unknown, never stale" "$(lv)" "unknown PM_RUNTIME_MISMATCH"
absent "(h) ...and terminal show is never asked for a foreign handle" "$(grep -l '^terminal show' "$LV/argv" 2>/dev/null)"
echo '{"ok":true,"result":{"terminals":[]}}' >"$LV/list"
eq "(h) a list without a runtime id is unknown" "$(lv)" "unknown ORCA_UNAVAILABLE"
echo 'not json' >"$LV/list"
eq "(h) an unparsable list is unknown" "$(lv)" "unknown ORCA_UNAVAILABLE"
eq "(h) a tuple without a pane is unknown" "$(lv '{"handle":"term_pm","runtime_id":"runtime-a"}')" "unknown PM_IDENTITY_UNRECORDED"
jq -nc '{ok:true,result:{terminal:{handle:"term_pm",tabId:"tab-1",leafId:"leaf-1",incarnationId:"inc-1",
  executionHostId:"local",worktreeId:"wt-1",connected:true,orphaned:false,preview:"SECRET"}},_meta:{runtimeId:"runtime-a"}}' >"$LV/show"
echo 0 >"$LV/show.rc"
eq "(h) the identity tuple comes from terminal show and the runtime id" \
  "$(env -i HOME="$H" PATH="$BASE_PATH" LV="$LV" ORCA_CLI_COMMAND="$TMP/lv-orca" \
    bash -c '. "$1"; afk_orca_identity term_pm claude && jq -c "del(.recorded_at)" <<<"$AFK_ORCA_IDENTITY"' _ "$LIB")" \
  '{"handle":"term_pm","runtime_id":"runtime-a","execution_host_id":"local","worktree_id":"wt-1","tab_id":"tab-1","leaf_id":"leaf-1","incarnation_id":"inc-1","agent_type":"claude"}'
jq '.result.terminal.tabId=null' "$LV/show" >"$LV/show.tmp" && mv "$LV/show.tmp" "$LV/show"
eq "(h) no tuple without a pane" \
  "$(env -i HOME="$H" PATH="$BASE_PATH" LV="$LV" ORCA_CLI_COMMAND="$TMP/lv-orca" \
    bash -c '. "$1"; afk_orca_identity term_pm claude; printf "%s|%s" "$?" "$AFK_ORCA_IDENTITY"' _ "$LIB")" "1|"
lv_list "$RA" "$(lv_term true false)"; lv_ps "$RA" "$(lv_row tab-1:leaf-1 working)"
eq "(h) worktree ps text never survives the join" \
  "$(env -i HOME="$H" PATH="$BASE_PATH" LV="$LV" ORCA_CLI_COMMAND="$TMP/lv-orca" \
    bash -c '. "$1"; afk_orca_terminal_state "$2"; set | grep -c -e "SECRET-""PROMPT" -e "SECRET-""REPLY"' _ "$LIB" "$TUPLE")" "0"

# --- (g) the real CLI under the systemd user manager's PATH ------------------
if [[ -x "${HOME:-/nonexistent}/.local/bin/orca-ide" && ! -e "$HOME/.config/agent-flow-kit/host.json" ]]; then
  sys_path="$(systemctl --user show-environment 2>/dev/null | sed -n 's/^PATH=//p')"
  [[ -n "$sys_path" ]] || sys_path="/usr/bin:/bin"
  eq "(g) the real CLI resolves under the systemd PATH" \
    "$(env -i HOME="$HOME" PATH="$sys_path" bash -c ". '$LIB'; afk_orca_bin")" "$HOME/.local/bin/orca-ide"
else
  printf 'SKIP (g) no ~/.local/bin/orca-ide on this host (or a host.json chooses another)\n'
  skip=$((skip + 1))
fi

printf '%s passed, %s failed, %s skipped\n' "$pass" "$fail" "$skip"
((fail == 0))
