# AFK-PORT-1.2-F6-R1-POSTFIX-REVIEW — worker_done evidence (retained by PM)

- **Run:** run_09474acba864
- **Task:** task_dc35df3b17b1
- **Dispatch:** ctx_246c7f91d4bb
- **Reviewer terminal:** term_64013f42-454c-405b-a302-6745e3435830 (fresh session; not the implementer, not any prior reviewer)
- **Message:** msg_922db05e9a01 (delivery_978ab0db8d8e, sequence 95)
- **Sent:** 2026-08-25T05:41:14Z
- **Outcome:** succeeded (review completed; verdict NOT CLEAN)
- **Stamped route:** claude / claude-strong / high / subscription, metered=false (stamp: AFK-PORT-1.2-F6-R1-POSTFIX-REVIEW.stamp.json, validated 8/8)
- **Persona proof:** requested=dev, resolved=BMAD DEV (Amelia), identity sha256:07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee — matched, fail-closed
- **Read-only contract:** honoured — tree provably unmodified (git status snapshot identical, HEAD 15a97ba, git diff --check clean)
- **Full report retained at:** `evidence/AFK-PORT-1.2-F6-R1-POSTFIX-REVIEW.md` (raw reproductions under `evidence/AFK-PORT-1.2-F6-R1-POSTFIX-REVIEW-raw/`, gate logs under `evidence/AFK-PORT-1.2-F6-R1-POSTFIX-REVIEW-gates/`)

## Subject

NOT CLEAN: F6-R1 fix holds, but two more sites of the same defect class are live (one at 4.7% of real CLI runs)

## Verdict summary

**NOT CLEAN for Story 1.2 — two Story 1.2-owned blockers.**

The F6-R1 fix itself HELD under direct attack: window forced open with publish-slowly/acquire-announced, 8 contenders inside it all got rc=1 CONCURRENT with owner_state=LIVE and no remove guidance, zero residue; never-publishing lock fails closed boundedly at exactly publish_waits=120 (~3.5s) with truthful detail; permanently-unjudgeable records cost publish_waits=0; the budget cannot be raised from the environment nor starved (max 629ms/9 waits under a lock-churning adversary); non-fractional-sleep fallback stays bounded; read-only paths never wait; all thirteen retained F6 scenarios re-attacked and held (incl. 25 rounds × 10-way simultaneous reclaim, 1 winner/round, zero residue).

### BLOCKER F6-R2 (implementer's self-reported residual — CONFIRMED)

A lost arbitration marker vanishing between `afk_lock_marker_claim`'s existence check and `afk_lock_reclaim`'s judge makes reclaim return 2 and acquire return 3, emitting OPERATION_LOCK_OWNER_UNVERIFIABLE + "remove <lock> by hand" while a successor holds the lock. Reproduced: library level (16/480 staggered acquisitions, each with holder alive and lock present carrying the reclaimer's incarnation), forced interleaving, and real CLI — 12 of 256 `agent-flow-kit update` runs (4.7%, 9 of 16 rounds) whose JSON contains both "another operation holds the installation lock" and "then remove .../lock by hand".

**Reviewer judgment: Story 1.2-owned blocker, NOT acceptable documented residual** — it satisfies the same acceptance criterion F6-R1 was accepted under (untrue guidance to delete a live lock), breaks the module header's invariant ("a loser never touches the directory") via the operator's hands, deviates from LIFECYCLE-CONTRACT.md:165-185 exactly as F6-R1 did, and reproduces at 4.7% of contended CLI runs.

### BLOCKER F6-R3 (NEW, undisclosed, same class)

The owner record vanishing between the `[[ -f ]]` test and the `jq` read in `afk_lock_judge_record` is mis-diagnosed as "the lock owner record could not be parsed" — refused instantly with the same remove-by-hand guidance. Reproduced with a live successor holding the lock; isolated away from reclaim entirely (take/release loop as the only writer, 3000 observations, one hit). `afk_state_file_write` is tmp+atomic `mv -f`, so a torn record is impossible; a discriminating probe confirmed 4/4 parse verdicts had the record GONE immediately after — never present-and-malformed, never present-and-valid. Also: the contract still lists "unparseable" among remove-by-hand conditions while the implementation reaches that branch for a record that was never unparseable.

### Suggested fix direction (reviewer's, non-binding)

Both fixes are small and follow the design this cycle already established: treat a vanished marker/record as a moment — return 3 "observe again" / `$AFK_LOCK_NO_RECORD_DETAIL` — rather than a diagnosis.

## Anti-vacuity verdict on the F6-R1 regressions

Genuine. Pre-fix reconstructed tree (72-line publication-window block removed, evaluate_settled calls reverted): concurrency 128/18 deterministically 3/3 runs vs 146/0 fixed; mutation 370/7 and 371/6 vs 377/0 fixed; f6window failed 6-for-6 pre-fix. Honest qualification: f6contendclean is a probabilistic detector (passed once on the pre-fix tree), and 11 of the 18 concurrency failures are publish_waits accounting assertions a budget-less tree cannot satisfy by construction — f6window is what actually pins the behaviour.

## Gate results (rerun independently by the reviewer)

- lifecycle 443 passed / 0 failed, rc 0
- mutation 377 / 0, rc 0
- concurrency 146 / 0, rc 0
- run-tests 230 / 0, rc 0 (shellcheck clean on all 12 shipped scripts; embedded gates 443/0, 377/0, 146/0; live control-plane chain SKIP — opt-in, not configured)
- git diff --check clean, rc 0

## PM disposition

Story 1.2 is NOT frozen. Another bounded fresh fixer/reviewer cycle is required for F6-R2 + F6-R3.
