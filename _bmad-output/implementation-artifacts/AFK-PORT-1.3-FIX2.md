---
linear:
stamp: AFK-PORT-1.3-FIX2.md.stamp.json
persona: dev
gates:
  - "bash tests/lifecycle-tests.sh"
  - "bash tests/run-tests.sh"
  - "git diff --check"
max_cycles: 1
---

# AFK-PORT-1.3-FIX2 — final authorized cycle (fresh session)

Authorized by Josh beyond the story's 3-cycle budget, after the diff-scoped
post-fix review (`evidence/AFK-PORT-1.3-POSTFIX-REVIEW.md`) found two
reproduced remedy-completeness blockers in the cycle-3 delta. **One cycle.
Exactly the three items below plus the record work.** Read the review's P1 and
P2 sections first; the coordinator reproduced both with the scripts in
`evidence/AFK-PORT-1.3-POSTFIX-REVIEW-attack/` (controls held).

Acceptance oracles, all coordinator-executed after you finish: P1 and P2
scripts must flip to NOT REPRODUCED with their controls holding, the four
original full-review scripts (A1–A4) must STAY NOT REPRODUCED, and all gates
must pass. You have no shell; reason from the scripts' assertions and say so.

## In scope — exactly this

### 1. P1 — the ABSENT arm consumes the durable close's own outcome

`lib/afk-monitor.sh:812-824`: for a pre-status of `ABSENT`, absence-after-close
is a tautology; the close request's exit status is the only discriminating
evidence and `|| true` discards it. Remedy (reviewer's simpler-and-safer form,
adopted): consume the release call's status for ALL THREE states — a failed
close is `NEEDS_OWNER TERMINAL_RELEASE_UNPROVEN` even if the handle is gone
from the listing ("a close that failed and a terminal that is nonetheless gone
is still an unproven closure"). Keep the re-observation for `IDLE`/`EXITED` as
today. Align the contract's terminal-row/no-op sentences
(`docs/LIFECYCLE-CONTRACT.md:702, :719-721`) so they describe checked behavior,
not an assumption about Orca. Gate: teach the dispatch-suite Orca stub to
REFUSE a close for a handle it is not listing (the current stub bakes in the
assumption), add the A1-shape regression variant where the close FAILS for an
absent handle → `NEEDS_OWNER`, keep the success-path control. Anti-vacuity:
the new assertion must fail on the current tree.

### 2. P2 — the monitor's two Orca observations take the strict bounding policy

`lib/afk-monitor.sh:412` (`terminal list`) and `:445` (`terminal close
--durable`) run through `afk_probe_run`, which on a host without `timeout(1)`
warns and runs UNBOUNDED — while `docs/LIFECYCLE-CONTRACT.md:650-655` (written
by cycle 3) asserts all pass observations are bounded, and the frozen
`:421-423` and "nothing here blocks" sentences require it. Remedy (reviewer's
"real one", adopted): give these two calls `afk_monitor_git_remote`'s policy —
a strict mode (shared strict wrapper or an explicit strict flag on
`afk_probe_run`; do not change `afk_probe_run`'s default behavior for
readiness probes, whose warn-and-run reading is documented and out of scope) —
no bounding tool → `PROBE_BOUND_UNAVAILABLE`, the call is NOT run, the
terminal disposition is `TERMINAL_RELEASE_UNPROVEN` / `NEEDS_OWNER`. The
contract sentence at `:650-655` then stays as written because it becomes true.
Per the review's D3 pointer: add `timeout` to `afk_require_tools`
(`lib/afk-common.sh:67`) so the operator learns from the tool, not a stalled
pass — if that hard requirement turns any frozen Story 1.1/1.2 gate assertion
red, do NOT weaken the assertion: scope the requirement to the monitor/live
paths instead and record the tension in the Dev Agent Record.

### 3. D2 — the stalled-remote regression must not pass vacuously without timeout(1)

`tests/lifecycle-dispatch-tests.sh:604-628`: on a host without `timeout(1)`
every assertion currently holds for the wrong reason (the wrapper refuses
before calling). Make the scenario discriminate: probe for the bounding tool
and either skip LOUDLY (counted and printed in the summary line, per the
run-tests precedent that "skipped checks computed no verdict") or assert the
refusal path explicitly as its own labeled case, with the stalled-transport
case running only where it can actually stall. Extend the same loud-skip
handling to the new P2 regression you add: stalled-Orca-without-bound must not
silently pass.

Regression for P2 itself: the P2 attack shape — no `timeout(1)` on PATH,
stalled Orca stub → the pass returns within its own bound and reports
`PROBE_BOUND_UNAVAILABLE` + `TERMINAL_RELEASE_UNPROVEN`/`NEEDS_OWNER`;
control: same stub with `timeout` present → bounded observation runs and the
normal dispositions apply. Anti-vacuity: the no-timeout case must fail (hang or
wrong disposition) on the current tree.

### 4. Record work

Under "Cycle 4 (fix)" in the story's Dev Agent Record: per-item changes,
anti-vacuity reasoning, gates-not-executed statement, updated diff size.
Register the review's remaining delta-scoped non-blocking findings (D1 and the
rest of D3–D8 as listed in the review's register) in the residual registry
block, marked registered-not-fixed — except what items 1–3 explicitly absorb
(mark those absorbed).

## Out of scope — hard stops

- `lib/afk-plan.sh`, `lib/afk-mutate.sh`, the Story 1.2 lock/signal surface,
  and `afk_probe_run`'s default warn-and-run behavior for readiness probes.
- Every other residual item (N-series and D-series) beyond the named
  absorptions.
- No new vocabulary; reuse `PROBE_BOUND_UNAVAILABLE`,
  `TERMINAL_RELEASE_UNPROVEN`, `NEEDS_OWNER`, `CLEANUP_NEEDS_OWNER`.
- Do not restructure for diff size.
