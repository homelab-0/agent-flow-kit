#!/usr/bin/env bash
# A1 — a terminal Orca is not currently listing is reported RELEASED without a
# durable close ever being requested, the Dispatch is SETTLED, and the tab comes
# back on the next Orca listing with no watch record left that could release it.
#
# Frozen text under attack:
#   AFK-PORT-1.3.md, "Required Worker-Terminal Cleanup Contract":
#     "Terminal closure must be durable across Orca disconnect/reconnect and
#      provider-session discovery. A completed worker must not reappear as a
#      newly resumed Claude/Codex tab merely because its transcript remains in
#      session history. Cleanup must record or request Orca's supported durable
#      close intent; killing the current PTY alone is insufficient."
#   docs/LIFECYCLE-CONTRACT.md, provenance-bound cleanup table, Terminal row:
#     "Released only when AFK-owned, and Orca reports it IDLE or EXITED. A
#      durable close is requested and its absence is re-observed."
#
# Code under attack: lib/afk-monitor.sh:713-714
#     case "$tstatus" in
#       ABSENT)  printf 'REMOVED TERMINAL_RELEASED'; return 0 ;;
# ABSENT is neither IDLE nor EXITED, and this branch returns before
# afk_monitor_terminal_release is ever called.

. "$(dirname -- "${BASH_SOURCE[0]}")/lib-dispatch-fixture.sh"

head1 "A1 — ABSENT is read as proof of release, with no durable close requested"

new_scenario a1-ghost

# The terminal exists as a provider session Orca will rediscover, but Orca is
# not listing it at this instant: the daemon restarted, or the tab was killed
# without a durable close. Nothing is added to the stub's listing yet.
register "$(descriptor d-ghost TASK-A1 term-ghost - - - - - false false false)"
say "registered d-ghost owning terminal term-ghost"
if terminal_listed term-ghost; then fails "fixture wrong: term-ghost should not be listed yet"; fi
say "orca does not currently list term-ghost (ABSENT)"

deliver del-ghost d-ghost worker_done done
run_afk monitor --json --cleanup --live
CLEAN_RC="$RUN_RC"

say "cleanup.terminal      = $(rec d-ghost '.cleanup.terminal')"
say "dispatch state        = $(rec d-ghost '.state')"
say "cleanup.complete      = $(rec d-ghost '.cleanup.complete')"
say "monitor exit code     = $CLEAN_RC"
say "durable close intents = [$(tr '\n' ' ' < "$STUB_CLOSED")]"

[[ "$(rec d-ghost '.cleanup.terminal')" == "REMOVED" ]] \
  || fails "not reproduced: terminal disposition is not REMOVED"
[[ "$(rec d-ghost '.state')" == "SETTLED" ]] \
  || fails "not reproduced: the Dispatch did not settle"
if grep -q -x -F -- "term-ghost" "$STUB_CLOSED" 2>/dev/null; then
  fails "not reproduced: a durable close WAS requested for term-ghost"
else
  say "CONFIRMED: term-ghost was reported RELEASED and no durable close was ever requested"
fi

# Orca reconnects and rediscovers the session it still holds in its history.
head1 "A1 — the reconnect"
terminal_add term-ghost IDLE
if terminal_listed term-ghost; then
  say "CONFIRMED: after the reconnect Orca lists term-ghost again"
else
  fails "not reproduced: the tab did not come back"
fi

run_afk monitor --json --cleanup --live
say "second pass exit code            = $RUN_RC"
say "second pass dispatch state       = $(rec d-ghost '.state')"
say "second pass cleanup.terminal     = $(rec d-ghost '.cleanup.terminal')"
say "dispatch_monitor.retained.terminals = $(jget '.dispatch_monitor.retained.terminals')"
say "dispatch_monitor.state           = $(jget '.dispatch_monitor.state')"

if terminal_listed term-ghost; then
  say "CONFIRMED: the resurrected tab is still there after a second cleanup pass"
else
  fails "not reproduced: the second pass released it after all"
fi
[[ "$(jget '.dispatch_monitor.retained.terminals')" == "0" ]] \
  || fails "not reproduced: the resurrected terminal IS counted as retained"
[[ "$RUN_RC" == "0" ]] \
  || fails "not reproduced: the pass did not report success over the orphaned tab"
say "CONFIRMED: a SETTLED Dispatch owns nothing, so no later pass can ever release it,"
say "           the retained-terminal count is 0, and the pass exits 0 claiming every"
say "           watched Dispatch is accounted for."

# --- the control: the same flow with a terminal Orca IS listing -------------
head1 "A1 control — an IDLE terminal really does get a durable close"
new_scenario a1-live
terminal_add term-live IDLE
register "$(descriptor d-live TASK-A1b term-live - - - - - false false false)"
deliver del-live d-live worker_done done
run_afk monitor --json --cleanup --live
say "cleanup.terminal      = $(rec d-live '.cleanup.terminal')"
say "durable close intents = [$(tr '\n' ' ' < "$STUB_CLOSED")]"
if grep -q -x -F -- "term-live" "$STUB_CLOSED" 2>/dev/null; then
  say "CONTROL HOLDS: the IDLE path requests the durable close, so the ABSENT path"
  say "               skipping it is a real difference and not a broken fixture."
else
  fails "control broken: the IDLE path did not request a durable close either"
fi
if terminal_listed term-live; then
  fails "control broken: the durably closed tab is still listed"
fi

head1 "verdict"
if (( VERDICT == 0 )); then
  printf '  DEFECT REPRODUCED (A1)\n'
else
  printf '  NOT REPRODUCED (A1)\n'
fi
exit "$VERDICT"
