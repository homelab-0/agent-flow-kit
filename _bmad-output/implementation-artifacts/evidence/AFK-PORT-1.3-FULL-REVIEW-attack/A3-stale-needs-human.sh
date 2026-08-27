#!/usr/bin/env bash
# A3 — the monitor's NEEDS_HUMAN flag is latched by the pre-action summary and
# never cleared, so a pass that RESOLVES the only fault still reports
# NEEDS_HUMAN and still exits 2 — over a document whose own counts say nothing
# is degraded and whose every Dispatch carries fault: null.
#
# Frozen text under attack:
#   docs/LIFECYCLE-CONTRACT.md, "Exit codes":
#     "For monitor the requested scope is the pass itself: it exits 2 when
#      something is left that only a human can decide, and 0 when the pass
#      accounted for every watched Dispatch."
#   docs/LIFECYCLE-CONTRACT.md, dispatch_monitor state vocabulary: NEEDS_HUMAN
#      is a state of the watch, not a memory of one.
#
# Code under attack:
#   lib/afk-commands.sh:472  afk_evaluate_installation -> afk_monitor_summarize
#                            (pre-action; latches AFK_MON_NEEDS_HUMAN=true)
#   lib/afk-commands.sh:489  afk_monitor_summarize (post-action; only ever SETS
#                            the flag, never clears it — lib/afk-monitor.sh:975)
#   lib/afk-monitor.sh:130   afk_monitor_reset() would clear it and is dead code:
#                            it is defined and never called anywhere in the tree.

. "$(dirname -- "${BASH_SOURCE[0]}")/lib-dispatch-fixture.sh"

head1 "A3 — a fault the pass repaired still makes the pass an owner action"

new_scenario a3
register "$(descriptor d-rec TASK-A3 - - - - - - false false false)"

# A delivery carrying no result status: loud, degraded, recoverable — exactly
# the frozen "a completion result that cannot be parsed remains unacknowledged
# and recoverable" case.
mkdir -p "$INBOX"
jq -nc '{schema_version: "1.0", delivery_id: "del-bad", dispatch_id: "d-rec",
         kind: "worker_done", result: {summary: "no status anywhere"}}' \
  > "$INBOX/del-bad.json"
run_afk monitor --json --reconcile
say "baseline: dispatch state   = $(rec d-rec '.state')"
say "baseline: fault            = $(rec d-rec '.fault')"
say "baseline: exit code        = $RUN_RC   (correctly 2)"
[[ "$(rec d-rec '.state')" == "MONITOR_DEGRADED" ]] \
  || fails "fixture wrong: the delivery did not degrade the watch"
[[ "$RUN_RC" == "2" ]] || fails "fixture wrong: the degraded pass did not exit 2"

# The owner corrects the delivery. The next pass repairs the Dispatch fully.
rm -f "$INBOX/del-bad.json"
deliver del-good d-rec worker_done done
run_afk monitor --json --reconcile
RECOVERED_JSON="$RUN_OUT"; RECOVERED_RC="$RUN_RC"

head1 "A3 — what the repairing pass reports"
say "dispatch state                     = $(rec d-rec '.state')"
say "fault                              = $(rec d-rec '.fault')"
say "result.status                      = $(rec d-rec '.result.status')"
say "result.needs_human                 = $(rec d-rec '.result.needs_human')"
say "dispatch_monitor.state             = $(jget '.dispatch_monitor.state')"
say "dispatch_monitor.reason            = $(jget '.dispatch_monitor.reason')"
say "dispatch_monitor.counts.degraded   = $(jget '.dispatch_monitor.counts.degraded')"
say "dispatch_monitor.counts.unreadable = $(jget '.dispatch_monitor.counts.unreadable')"
say "dispatch_monitor.counts.completed  = $(jget '.dispatch_monitor.counts.completed')"
say "dispatch_monitor.pending_deliveries= $(jget '.dispatch_monitor.pending_deliveries')"
say "faults still on any dispatch       = $(jget '[.dispatch_monitor.dispatches[] | select(.fault != null)] | length')"
say "exit code                          = $RECOVERED_RC"

[[ "$(rec d-rec '.state')" == "COMPLETED" ]] \
  || fails "not reproduced: the corrected delivery did not complete the Dispatch"
[[ "$(rec d-rec '.fault')" == "null" ]] \
  || fails "not reproduced: a fault is genuinely still recorded"
[[ "$(jget '.dispatch_monitor.state')" == "NEEDS_HUMAN" ]] \
  || fails "not reproduced: the summary does not claim NEEDS_HUMAN"
[[ "$(jget '.dispatch_monitor.counts.degraded')" == "0" ]] \
  || fails "not reproduced: something really is degraded"
[[ "$RECOVERED_RC" == "2" ]] \
  || fails "not reproduced: the repairing pass did not exit 2"
say "CONFIRMED: NEEDS_HUMAN / reason MONITOR_DEGRADED / exit 2, over a document in"
say "           which nothing is degraded, nothing is unreadable, nothing is pending"
say "           and no Dispatch carries a fault."

# --- the control: the same on-disk state, read by a fresh process ----------
head1 "A3 control — the identical state, one process later"
run_afk monitor --json
say "read-only pass: dispatch_monitor.state = $(jget '.dispatch_monitor.state')"
say "read-only pass: exit code              = $RUN_RC"
if [[ "$(jget '.dispatch_monitor.state')" == "NEEDS_HUMAN" ]]; then
  fails "control broken: the state really does need a human"
else
  say "CONTROL HOLDS: nothing on disk changed between the two runs, and the next"
  say "               process reports $(jget '.dispatch_monitor.state') and exit $RUN_RC."
  say "               The difference is only whether the SAME process had earlier"
  say "               observed the fault it then repaired — i.e. a stale in-process flag."
fi

head1 "verdict"
if (( VERDICT == 0 )); then
  printf '  DEFECT REPRODUCED (A3)\n'
else
  printf '  NOT REPRODUCED (A3)\n'
fi
exit "$VERDICT"
