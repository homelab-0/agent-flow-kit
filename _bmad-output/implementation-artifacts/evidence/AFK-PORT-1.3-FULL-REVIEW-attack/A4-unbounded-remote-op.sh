#!/usr/bin/env bash
# A4 — the "one bounded pass" reaches the network through git(1) without any
# bound at all: `git ls-remote` and `git push --delete` in the cleanup path do
# not go through afk_probe_run, carry no timeout, and block the whole monitor
# pass for as long as the transport does.
#
# Frozen text under attack:
#   AFK-PORT-1.3.md, "Required Worker-Completion Monitoring Contract":
#     "The completion monitor must be bounded and event-driven or use bounded
#      polling/backoff; it must not require an indefinitely live LLM turn or
#      create an unbounded busy loop."
#   docs/LIFECYCLE-CONTRACT.md, "The dispatch monitor":
#     "`monitor` performs exactly one bounded pass per invocation. ... Nothing
#      here blocks, and nothing here can spin."
#   docs/LIFECYCLE-CONTRACT.md, live probes: "A host that cannot bound a probe
#      reports PROBE_BOUND_UNAVAILABLE rather than running an unbounded probe as
#      if it were a bounded one."
#
# Code under attack: lib/afk-monitor.sh:857, :869, :870
#     left="$(git -C "$repo" ls-remote --heads "$remote" "$br" 2>/dev/null)"
#     git -C "$repo" push "$remote" --delete "$br" >/dev/null 2>&1
#     left="$(git -C "$repo" ls-remote --heads "$remote" "$br" 2>/dev/null)"
# Compare lib/afk-monitor.sh:335 and :360, where the Orca observations DO go
# through the bounded runner.

. "$(dirname -- "${BASH_SOURCE[0]}")/lib-dispatch-fixture.sh"

if ! command -v timeout >/dev/null 2>&1; then
  printf '  SKIPPED: no timeout(1) on this host to bound the observation with.\n'
  printf '  (That is the tool the monitor itself does not use here.)\n'
  exit 2
fi

BOUND=20   # seconds we allow the "one bounded pass" before calling it unbounded

# A transport that accepts the connection and then does nothing, which is what a
# dropped VPN, a black-holed host or a stalled proxy looks like to git.
SLOWSSH="$TMPROOT/slow-ssh"
printf '#!/bin/sh\nexec sleep 600\n' > "$SLOWSSH"; chmod +x "$SLOWSSH"
FASTSSH="$TMPROOT/fast-ssh"
printf '#!/bin/sh\nexit 255\n' > "$FASTSSH"; chmod +x "$FASTSSH"

head1 "A4 — a stalled remote stops the bounded pass from being bounded"

new_scenario a4
REPO="$TMPROOT/repo-a4"
new_repo "$REPO"
git -C "$REPO" branch topic-hang >/dev/null 2>&1
git -C "$REPO" remote add origin "ssh://nowhere.invalid/x.git" >/dev/null 2>&1

register "$(descriptor d-hang TASK-A4 - - topic-hang "$REPO" master origin false false false)"
deliver del-hang d-hang worker_done done
say "registered d-hang: local branch topic-hang, remote 'origin' over a stalled transport"

run_pass() { # <ssh command> -> prints "<rc> <elapsed seconds>"
  local ssh_cmd="$1" start end rc
  start="$(date +%s)"
  timeout "$BOUND" env PATH="$BIN:$PATH" HOME="$HOMEDIR" \
    XDG_STATE_HOME="$HOMEDIR/.local/state" AFK_KIT_ROOT="$CHECKOUT" \
    STUB_TERMS="$STUB_TERMS" STUB_CLOSED="$STUB_CLOSED" \
    GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="$ssh_cmd" \
    bash "$AFK" monitor --json --cleanup --live </dev/null >/dev/null 2>&1
  rc=$?
  end="$(date +%s)"
  printf '%s %s' "$rc" "$(( end - start ))"
}

read -r HANG_RC HANG_S <<<"$(run_pass "$SLOWSSH")"
say "stalled transport: exit code $HANG_RC after ${HANG_S}s (bound was ${BOUND}s)"
if [[ "$HANG_RC" == "124" ]]; then
  say "CONFIRMED: the pass did not return. exit 124 is timeout(1) killing it, not"
  say "           the lifecycle refusing an unbounded operation — the lifecycle has"
  say "           no code path here that could refuse one."
else
  fails "not reproduced: the pass returned by itself with exit $HANG_RC"
fi

head1 "A4 control — the same pass when the transport answers"
read -r FAST_RC FAST_S <<<"$(run_pass "$FASTSSH")"
say "failing-fast transport: exit code $FAST_RC after ${FAST_S}s"
if [[ "$FAST_RC" != "124" ]] && (( FAST_S < BOUND )); then
  say "CONTROL HOLDS: the same fixture, the same command and the same record return"
  say "               promptly once the transport answers, so the hang above is the"
  say "               unbounded git call and not the fixture."
else
  fails "control broken: the fast transport did not return either"
fi

head1 "note"
say "The same three unbounded calls also run under an interactive credential"
say "prompt: with GIT_TERMINAL_PROMPT unset (its default) an https remote whose"
say "credentials expired makes git block on a username prompt inside the"
say "settlement pass. This script pins GIT_TERMINAL_PROMPT=0 so the reproduction"
say "measures only the transport stall, which is the deterministic half."

head1 "verdict"
if (( VERDICT == 0 )); then
  printf '  DEFECT REPRODUCED (A4)\n'
else
  printf '  NOT REPRODUCED (A4)\n'
fi
exit "$VERDICT"
