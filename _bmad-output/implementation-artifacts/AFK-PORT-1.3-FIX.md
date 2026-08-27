---
linear:
stamp: AFK-PORT-1.3-FIX.md.stamp.json
persona: dev
gates:
  - "bash tests/lifecycle-tests.sh"
  - "bash tests/run-tests.sh"
  - "git diff --check"
max_cycles: 1
---

# AFK-PORT-1.3-FIX — one bounded fix cycle (fresh session)

Authorized by Josh after the full adversarial sweep returned NOT CLEAN with four
reproduced blockers. **One cycle. Exactly the five items below.** Everything
else found by the review is already dispositioned: do not fix it, do not touch
it, except to add the residual-registry block described in item 6.

You are a fresh session; you did not write this code and you did not review it.
Read the review first: `_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.3-FULL-REVIEW.md`
(sections 2 and 3). The four blockers were each REPRODUCED by the coordinator
executing the reviewer's attack scripts in
`evidence/AFK-PORT-1.3-FULL-REVIEW-attack/` — the scripts and their controls
are your acceptance oracles: after your fix, each script must print
`NOT REPRODUCED` (exit 1) while its control still holds. You cannot execute
them (no shell); reason from their exact assertions and say so in the record.
The coordinator re-runs them and all gates independently.

## In scope — exactly this

### 1. B1 — ABSENT terminal must not count as released

`lib/afk-monitor.sh:712-732`: the `ABSENT)` arm returns
`REMOVED TERMINAL_RELEASED` without ever requesting the durable close.
Remedy (the reviewer's preferred shape, adopted): for an AFK-owned handle,
request the durable close **unconditionally** before judging — `ABSENT` falls
through to the same request/re-observe pair as `IDLE|EXITED`; a durable close
for a handle Orca has forgotten is a harmless no-op that records the intent.
Align `docs/LIFECYCLE-CONTRACT.md:678` (terminal row) so the contract sentence
stays true of the code. Resolve N14 alongside, minimally: decide what `ABSENT`
means in ONE place — the watch sweep's reading (`ABSENT` during watch = fault,
`WORKER_TERMINAL_EXITED_WITHOUT_DELIVERY`) stays; the cleanup reading becomes
"unproven until the durable close is requested and absence re-observed" — and
state both readings in the contract where the cleanup table already lives.
Regression: extend `tests/lifecycle-dispatch-tests.sh` with the A1 shape — a
settled dispatch whose handle is NOT in the stub listing: cleanup must request
the durable close (stub ledger contains the handle) before reporting REMOVED;
plus the control (IDLE path unchanged). Anti-vacuity: the new assertions must
fail on the current tree's logic.

### 2. B2 — an unresolvable target binding fails closed; trust check cannot vanish

`lib/afk-readiness.sh:1597-1632`: with zero or ≥2 registered targets and no
`--target`, the target leg and the workspace-trust evaluation are silently
skipped and `ROUTE_READY` can be TRUE. Remedy: when `target_id` cannot be
determined, set `ROUTE_READY = FALSE` with `ROUTE_TARGET_UNRESOLVED` (zero
targets and ambiguous-arity both take this path; ≥2 without `--target` is
ownership ambiguity — do not guess). Additionally make the workspace-trust
evaluation not reachable-only-through-`tpath`: when the route selects claude
and no workspace path can be determined, emit `NO_SELECTED_WORKSPACE` (this
revives the dead branch — N5 absorbed) rather than staying silent; when a
target path IS resolved, the trust evaluation runs exactly as today.
Do NOT change the usage boundary in `bin/agent-flow-kit` unless a refusal is
strictly required by the above; prefer the readiness-level fail-closed.
Regression: extend `tests/lifecycle-readiness-tests.sh` with the A2 matrix —
six runs varying only registered-target arity/trust: wired singleton TRUE;
unwired singleton FALSE/ROUTE_TARGET_UNRESOLVED; wired+unwired (no --target)
FALSE/ROUTE_TARGET_UNRESOLVED; zero targets FALSE/ROUTE_TARGET_UNRESOLVED;
wired singleton with trust withheld FALSE/WORKSPACE_TRUST_REQUIRED (exit 2);
two targets with the same trust withheld must NOT report TRUE-with-zero-findings.
Anti-vacuity: rows 3, 4 and 6 must fail on the current tree.

### 3. B3 — the NEEDS_HUMAN latch clears at each summarize

`lib/afk-monitor.sh:975-1082` + `lib/afk-commands.sh:465-497`: reset the
derived state at the top of `afk_monitor_summarize` (call `afk_monitor_reset`
or reset `AFK_MON_NEEDS_HUMAN="false"` there — this also un-deadens N8's dead
function if you use it), so the summary describes the state it just read.
Findings already accumulated in `AFK_FINDINGS` stay — only derived state and
exit code follow the post-action reading. Regression: in the existing recovery
scenario (`tests/lifecycle-dispatch-tests.sh:439-443`), add the missing
assertions — the repairing pass's `RUN_RC` is 0 and `.dispatch_monitor.state`
is `WATCHING` (per the A3 predicted observables). Anti-vacuity: both fail today.

### 4. B4 — the three remote git calls become bounded and non-interactive

`lib/afk-monitor.sh:857, :869, :870`: route `git ls-remote` (×2) and
`git push --delete` through the same bounding the probe runner provides —
either `afk_probe_run` (they are external observations) or the identical
`timeout` mechanism with `GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS=/bin/true` and
`GIT_SSH_COMMAND` carrying `BatchMode=yes` for the duration. On a host where no
bounding tool exists, report `PROBE_BOUND_UNAVAILABLE` and leave the remote
branch `NEEDS_OWNER` (already the fail-closed disposition). A timed-out remote
observation is `NEEDS_OWNER` with the retained-remote reporting, never a hang
and never a false "deleted". Regression: extend the dispatch gate with a
stalled-transport remote (the A4 fixture shape): the cleanup pass returns
within the bound and reports NEEDS_OWNER; control: an answering transport still
completes the disposition. Anti-vacuity: the stalled case hangs (fails) today.

### 5. N1 — the two vacuous published-reason sweeps become falsifiable

`tests/lifecycle-tests.sh:1721-1723` and `:1727-1729`: same jq-semantics defect
cycle 2 fixed in the readiness gate (`$pub | index(.)` — the array finds
itself). Fix by binding first, and add the same executable falsifiability
control the readiness gate carries (inject one out-of-set value, sweep reports
exactly it). **This may turn the gate genuinely red.** If it does, what it
catches is a REAL pre-existing publication gap: fix the publication side only
if the gap is inside this story's added vocabulary; if the gap is in
pre-existing vocabulary, do NOT widen scope — record the exact unpublished
codes under "Deferred, deliberately, and disclosed" in the Dev Agent Record
and leave the sweep's newly-red assertion in place only if it is red for
pre-1.3 reasons you must then enumerate to the coordinator via the record
(the coordinator will escalate; do not silently re-vacuate the sweep).

### 6. Residual registry (record work, same story file)

Add a "Full-review residual registry" block to the Dev Agent Record of
`_bmad-output/implementation-artifacts/AFK-PORT-1.3.md` listing N2, N3, N4, N6,
N7, N9, N10, N11, N12 (and N5/N8/N14 marked "absorbed by B2/B3/B1
respectively" if your fixes absorb them), each with its one-line description
and file:line from the review. These are registered, not fixed — do not
implement any of them. Also record the coordinator's C2-C ruling verbatim:
"Accepted: validator fixtures remain behind --live; 'validator-fixture facts'
in default mode means materialisability and validator resolution; AC-wording
nuance registered as residual."

## Out of scope — hard stops

- Any change to `lib/afk-plan.sh`, `lib/afk-mutate.sh`, or the Story 1.2 lock/
  signal/transaction surface: STOP and record instead.
- Any of N2–N12 beyond what items 1–5 explicitly absorb.
- No new vocabulary beyond `NO_SELECTED_WORKSPACE` (already published) and what
  item 4 reuses (`PROBE_BOUND_UNAVAILABLE`, `NEEDS_OWNER`); if a remedy seems
  to need a new reason code, prefer the existing fail-closed codes and record
  the tension.
- Do not restructure for diff size; the packaging flag is already recorded.

## Record

Record everything in the story's Dev Agent Record under a "Cycle 3 (fix)"
heading: per-item what changed, the anti-vacuity reasoning for each new
regression (which current-tree behavior it would catch), gates-not-executed
statement (standing arrangement), and updated final diff size.

## Dev Agent Record

The full record lives in `AFK-PORT-1.3.md` under **"Cycle 3 (fix)"**, as
instructed: per-item changes, the anti-vacuity reasoning for every new
regression, the gates-not-executed statement, the full-review residual registry
(item 6, including the C2-C ruling recorded verbatim), and the updated diff
size. This section is the short index into it.

- **Status:** all five in-scope items implemented, plus item 6's record work.
  **Gates not executed in this session** — Read/Glob/Grep/Write only, no shell.
  The attack scripts could not be run here either; each item's record states
  what the script asserts and why the fix inverts it while the control holds.
  The coordinator's independent run is the arbiter.

- **Files changed (6, none added):**
  - `lib/afk-monitor.sh` — B1 (`ABSENT` falls through to the durable-close
    request/re-observe pair, and both readings of `ABSENT` are stated at their
    code sites), B3 (`AFK_MON_PASS_NEEDS_HUMAN` split from the derived
    `AFK_MON_NEEDS_HUMAN`, which `afk_monitor_summarize` now sets from the pass
    flag before it reads anything), B4 (`afk_monitor_git_remote` bounds all
    three remote calls and makes them non-interactive).
  - `lib/afk-readiness.sh` — B2 (an undeterminable target binding is
    `ROUTE_TARGET_UNRESOLVED`; the Claude workspace-trust evaluation no longer
    hangs off a resolved `tpath` and emits `NO_SELECTED_WORKSPACE` when no
    workspace can be determined).
  - `docs/LIFECYCLE-CONTRACT.md` — the Terminal row of the cleanup table, the
    two readings of `ABSENT`, the bounded/non-interactive remote observations,
    the target-arity fail-closed rule, and the `NO_SELECTED_WORKSPACE` reading.
  - `tests/lifecycle-dispatch-tests.sh` — the A1 shape (`ghost`) with its
    IDLE-path control, the A4 shape (`stalled-remote`) with an answering-remote
    control, the two missing recovery-pass assertions from A3, and a unit
    assertion for the derived/pass split.
  - `tests/lifecycle-readiness-tests.sh` — the A2 six-row target-arity matrix
    with its two controls.
  - `tests/lifecycle-tests.sh` — N1: both published-reason sweeps bind first
    and each carries its own falsifiability control.

- **`bin/agent-flow-kit`, `lib/afk-commands.sh`, `lib/afk-common.sh`,
  `lib/afk-plan.sh`, `lib/afk-mutate.sh` and every Story 1.2 surface are
  untouched.** The usage boundary was not widened (item 2's instruction), and
  the B3 split was designed so the command layer and the exit-code function did
  not need to change: a bare reset there would have made
  `monitor --register <bad descriptor>` exit 0, which the gate pins at 2.

- **No new vocabulary.** Everything emitted is already published:
  `NO_SELECTED_WORKSPACE`, `ROUTE_TARGET_UNRESOLVED`, `PROBE_BOUND_UNAVAILABLE`,
  `CLEANUP_NEEDS_OWNER`, `TERMINAL_RELEASE_UNPROVEN`.

- **The one thing whose outcome is unknown from here:** item 5. The corrected
  sweeps have never actually been run against a status or adoption document.
  The record in `AFK-PORT-1.3.md` states the reasoning for expecting them green
  and the exact handling if they are not.

- **One new host dependency, stated plainly:** remote-branch dispositions now
  require `timeout(1)`. Without it the pass reports `PROBE_BOUND_UNAVAILABLE`
  and retains the remote branch rather than running an unbounded network call —
  which is what the contract already required of any probe that cannot be
  bounded.
