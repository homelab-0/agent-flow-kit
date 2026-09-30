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
