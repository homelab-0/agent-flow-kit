#!/usr/bin/env bash
# run-tests.sh — fixture-driven proof that the rewired dispatcher does what the
# frozen contracts say, without a live BMAD run and without launching a harness.
#
# Two layers:
#   UNIT        — dispatch.sh is sourced (its main() is guarded), and the pure
#                 builders are called directly. This is where the generated
#                 terminal command text is asserted on.
#   INTEGRATION — dispatch.sh is RUN against a temporary worktree with stubbed
#                 orca / agent-stamp-validate / curl / claude binaries on PATH.
#                 Every refusal path is reached for real, and its exit code is
#                 the assertion.
#
# The lifecycle surface has its own isolated gates — tests/lifecycle-tests.sh
# for the read-only half, tests/lifecycle-mutation-tests.sh for the destructive
# half, and tests/lifecycle-concurrency-tests.sh for the operation lock under
# real contention. Sections 6, 7 and 8 aggregate them here so one command still
# answers "is the kit green".
#
# Usage: tests/run-tests.sh
# Exit:  0 all passed, 1 any failure.

# SC2016 is disabled file-wide ON PURPOSE: many needles here are single-quoted
# '$HOME' / '$(' / '$?' strings that MUST stay literal. Expanding them is
# precisely the bug these assertions exist to catch.
# shellcheck disable=SC2016

set -uo pipefail

KIT_ROOT="/home/devbox/repos/jlengelbrecht/agent-flow-kit"
DISPATCH="$KIT_ROOT/files/model-router/scripts/dispatch.sh"
MAKE_STAMP="$KIT_ROOT/files/model-router/scripts/make-stamp.sh"
USAGE_CHECK="$KIT_ROOT/files/model-router/scripts/usage-check.sh"
GH_HEALTH="$KIT_ROOT/files/model-router/scripts/github-health.sh"

TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT
WORK_OLD="$TMPROOT/old"

PASS=0 FAIL=0 SKIPPED=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  {
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  if [[ -n "${2:-}" ]]; then printf '        %s\n' "$2"; fi
  FAIL=$((FAIL+1))
}
head1(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; SKIPPED=$((SKIPPED+1)); }

assert_eq()       { if [[ "$2" == "$3"    ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing substring: $3"; fi; }
assert_absent()   { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "should NOT contain: $3"; fi; }
assert_no_file()    { if [[ -f "$2" ]]; then bad "$1" "file exists: $2"; else ok "$1"; fi; }
assert_empty_file() { if [[ -s "$2" ]]; then bad "$1" "non-empty: $2"; else ok "$1"; fi; }

# ===========================================================================
head1 "0. shellcheck — every script the kit ships"
# ===========================================================================

# A sub-gate that cannot run must say so. The previous form captured stdout
# only, discarded stderr and never looked at the exit status, so a checker that
# failed to START — `nix run` refusing a disabled experimental feature is the
# live example — produced empty stdout and was read as "clean". Twelve scripts
# were reported checked by a checker that never executed.
#
# So the checker is PROVED to run before anything is checked with it: it is
# asked for its version and must exit 0 and identify itself. What it then says
# about each file is decided by its exit status, not by whether it happened to
# print something. shellcheck is not required to be installed; it is required
# that the gate never claims a result it did not compute.

SC_CMD=()
SC_VERSION=""
SC_WHY=""

sc_probe() { # <command word>...
  local out rc
  out="$("$@" --version 2>&1)"; rc=$?
  if (( rc != 0 )); then
    SC_WHY="$1 exited $rc: $(head -1 <<<"$out")"; return 1
  fi
  if [[ "$out" != *ShellCheck* ]]; then
    SC_WHY="$1 answered --version without identifying as ShellCheck"; return 1
  fi
  SC_VERSION="$(awk -F': *' '/^version:/ {print $2; exit}' <<<"$out")"
  return 0
}

if command -v shellcheck >/dev/null && sc_probe shellcheck; then
  SC_CMD=(shellcheck)
elif command -v nix >/dev/null &&
     sc_probe nix --extra-experimental-features "nix-command flakes" run nixpkgs#shellcheck --; then
  SC_CMD=(nix --extra-experimental-features "nix-command flakes" run nixpkgs#shellcheck --)
elif command -v nix >/dev/null && sc_probe nix run nixpkgs#shellcheck --; then
  SC_CMD=(nix run nixpkgs#shellcheck --)
fi

# One file, one verdict, decided by the checker's exit status:
#   0 with no output  the file is clean
#   1 with output     the file has findings   -> FAIL, findings shown
#   anything else     the checker did not deliver a verdict -> FAIL, never PASS
sc_check() { # <path> [extra checker args...]
  local f="$1"; shift
  local errf="$TMPROOT/shellcheck.err" out rc
  out="$("${SC_CMD[@]}" -s bash "$@" "$f" 2>"$errf")"; rc=$?
  local base; base="$(basename "$f")"
  case "$rc" in
    0)
      if [[ -n "$out" ]]; then
        bad "shellcheck clean: $base" "exit 0 but the checker still reported: $(head -1 <<<"$out")"
      else
        ok "shellcheck clean: $base"
      fi ;;
    1)
      if [[ -z "$out" ]]; then
        bad "shellcheck ran: $base" "checker exited 1 with no findings — it did not run: $(head -1 "$errf")"
      else
        bad "shellcheck clean: $base" "$(head -5 <<<"$out")"
      fi ;;
    *)
      bad "shellcheck ran: $base" "checker exited $rc: $(head -1 "$errf")" ;;
  esac
}

SC_SCRIPTS=("$DISPATCH" "$MAKE_STAMP" "$USAGE_CHECK" "$GH_HEALTH")
# The lifecycle surface. Checked at warning level and above, with two codes
# excluded for a structural reason rather than a stylistic one: the lifecycle
# files are always sourced together and share one result model, so a variable
# assigned in afk-common.sh and read in afk-inventory.sh looks unused (SC2034)
# or unassigned (SC2154) to a single-file analysis. `set -u` in the entry point
# is the real guard against an unset read.
SC_LIFECYCLE=("$KIT_ROOT/bin/agent-flow-kit" "$KIT_ROOT/lib/afk-common.sh" \
              "$KIT_ROOT/lib/afk-source.sh" "$KIT_ROOT/lib/afk-inventory.sh" \
              "$KIT_ROOT/lib/afk-commands.sh" "$KIT_ROOT/lib/afk-plan.sh" \
              "$KIT_ROOT/lib/afk-mutate.sh" "$KIT_ROOT/tests/lockctl-helper.sh")

if (( ${#SC_CMD[@]} > 0 )); then
  ok "shellcheck runs here: ${SC_CMD[0]} ${SC_VERSION:-(version not reported)}"
  for s in "${SC_SCRIPTS[@]}"; do
    [[ -f "$s" ]] || continue
    sc_check "$s"
  done
  for s in "${SC_LIFECYCLE[@]}"; do
    [[ -f "$s" ]] || continue
    sc_check "$s" --severity=warning --exclude=SC2034,SC2154
  done
else
  printf '  \033[33m!! shellcheck did not run on this host: %s\033[0m\n' \
    "${SC_WHY:-no shellcheck and no nix on PATH}"
  printf '  \033[33m!! nothing below section 0 was linted; this gate reports NOTHING, not clean\033[0m\n'
  for s in "${SC_SCRIPTS[@]}" "${SC_LIFECYCLE[@]}"; do
    [[ -f "$s" ]] || continue
    skip "shellcheck NOT RUN: $(basename "$s")"
  done
fi
if (( SKIPPED > 0 )); then
  printf '\n\033[1m%d passed, %d failed, %d skipped\033[0m\n' "$PASS" "$FAIL" "$SKIPPED"
  printf '\033[33mskipped checks computed no verdict — they are not passes\033[0m\n'
else
  printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
fi
(( FAIL == 0 )) || exit 1
