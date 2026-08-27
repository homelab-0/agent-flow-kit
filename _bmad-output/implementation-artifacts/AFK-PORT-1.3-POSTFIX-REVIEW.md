---
linear:
stamp: AFK-PORT-1.3-POSTFIX-REVIEW.md.stamp.json
persona: dev
gates:
  - "bash tests/lifecycle-tests.sh"
  - "bash tests/run-tests.sh"
  - "git diff --check"
max_cycles: 1
---

# AFK-PORT-1.3 — DIFF-SCOPED POST-FIX REVIEW (review-only, fresh session)

You are a fresh reviewer. You neither wrote nor previously reviewed this code.
The story already had its one full adversarial sweep
(`evidence/AFK-PORT-1.3-FULL-REVIEW.md`, NOT CLEAN, 4 blockers) and one
authorized fix cycle (`AFK-PORT-1.3-FIX.md`, its outcomes in the story file's
"Cycle 3 (fix)" record and `evidence/AFK-PORT-1.3-C3.worker-done.md`). This
review is DELTA-SCOPED per the standing convergence policy: attack ONLY the
cycle-3 changed surface and its named interaction points. Prior scenarios are
pinned by their regressions; do not re-sweep the whole story.

**REVIEW-ONLY CONTRACT (hard):** Read/Glob/Grep/Write; modify nothing. Your
only writes are new files: the report at
`evidence/AFK-PORT-1.3-POSTFIX-REVIEW.md` and optional new attack scripts under
`evidence/AFK-PORT-1.3-POSTFIX-REVIEW-attack/`. No shell: express attacks as
runnable scripts with predicted observables and self-deciding verdicts plus
controls, exactly as the full-review scripts did. The coordinator executes
them and re-runs all gates independently.

## The delta under review (~250 lines across 6 files)

1. `lib/afk-monitor.sh` — B1 (ABSENT|IDLE|EXITED unified cleanup arm with
   unconditional durable-close request), B3 (latch split:
   `AFK_MON_PASS_NEEDS_HUMAN` vs derived `AFK_MON_NEEDS_HUMAN`), B4 (new
   `afk_monitor_git_remote` bounding wrapper).
2. `lib/afk-readiness.sh:~1605-1643` — B2 (fail-closed
   `ROUTE_TARGET_UNRESOLVED` at zero/ambiguous target arity; workspace-trust
   decoupled from tpath; `NO_SELECTED_WORKSPACE` revived).
3. `docs/LIFECYCLE-CONTRACT.md` — terminal row, both ABSENT readings, bounded
   remote observations, target-arity rule.
4. `tests/lifecycle-dispatch-tests.sh` — ghost + IDLE control, stalled-remote +
   answering control, two recovery assertions, flag-split unit assertion.
5. `tests/lifecycle-readiness-tests.sh` — six-row `targetarity` matrix.
6. `tests/lifecycle-tests.sh:~1721-1729` — de-vacuated published-reason sweeps
   with falsifiability controls.

Read the full-review blocker sections (B1–B4) first so you attack the remedy
against the original defect, not in the abstract. The coordinator has already
executed the four original attack scripts post-fix: all flipped to
NOT REPRODUCED with controls holding — do not re-derive that; attack what the
scripts do NOT cover.

## What to attack

1. **Remedy completeness, per blocker:** does each fix close the defect
   CLASS or only the reproduced instance? For B1: what happens on a durable
   close that itself fails or times out; can the re-observation see a stale
   listing; is the settled-record early-return (`afk_monitor_cleanup_record`)
   still able to strand anything? For B2: any remaining path where `tpath`
   is empty yet ROUTE_READY stays TRUE; `--target` naming an unregistered id;
   interaction with the `--synthetic-route` path. For B3: any OTHER latch-like
   derived state with the same never-cleared shape in the monitor; does the
   split preserve exit 2 for every genuinely-unresolved case the contract
   names? For B4: the wrapper's timeout arithmetic, its failure-vs-timeout
   discrimination, whether any other external call in the monitor bypasses it
   (grep for bare `git`/`curl`/network calls in lib/afk-monitor.sh).
2. **New-blocker check (the stop rule):** any defect the fix ITSELF
   introduced, anywhere the delta touches. A behavioral regression in a
   previously-green path is a blocker even if the original four are fixed.
3. **Anti-vacuity of the new regressions:** for each new test (ghost,
   stalled-remote, recovery assertions, flag-split, targetarity rows 3/4/6,
   the two sweep controls), verify it discriminates — it must fail on the
   pre-fix logic. The Dev Agent Record argues this; check the arguments
   against the code, not the record's word.
4. **Contract truthfulness:** every sentence the fix added or rewrote in
   `docs/LIFECYCLE-CONTRACT.md` must be true of the code as it now stands —
   and no OLD sentence elsewhere in the doc is made false by the delta
   (search for other mentions of ABSENT, remote deletion, NEEDS_HUMAN exit
   semantics, target resolution).
5. **The B3 deviation:** the worker split the latch instead of the brief's
   bare reset, arguing a bare reset breaks `monitor --register <bad>` exit 2.
   Judge whether the split is sound and whether the derived flag can still go
   stale across the two summarize calls in one `afk_cmd_monitor` pass.
6. **The `timeout(1)` dependency disclosure:** confirm the no-timeout path
   really reports `PROBE_BOUND_UNAVAILABLE` + retains, and that the two
   section-5 assertions the record says now depend on timeout skip loudly
   rather than pass vacuously without it.

## Blocker bar (unchanged, bind your verdict to it)

Blocker = violates a frozen requirement + reproduced (your script) + reachable
(natural or one ordinary operator action). Everything else → non-blocking
register with class and file:line. The residual registry items (N2–N12 minus
absorbed) are already dispositioned — do not re-raise them unless the delta
made one WORSE.

## Report format (`evidence/AFK-PORT-1.3-POSTFIX-REVIEW.md`)

1. Verdict: `CLEAN` or `NOT CLEAN — <n> blocker(s)` (delta-scoped meaning: no
   blocker in the changed surface or its interactions).
2. Per-blocker: reproduction script, frozen text, reachability, remedy sketch.
3. Non-blocking register (delta-scoped).
4. Remedy-completeness verdict per B1–B4 and the B3-deviation judgment.
5. Anti-vacuity verdicts for the new regressions.
6. What you did not get to, plainly.

Target effort: a standard delta review, not a second full sweep. State your
verdict plainly in your final message.
