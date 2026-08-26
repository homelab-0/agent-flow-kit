# Handoff — agent-flow-kit portability increment, Story 1.2 frozen

Date: 2026-08-25 · Prepared by: BMAD PM session (coordinator takeover of Orca run `run_09474acba864`)
Purpose: directional-alignment check. Everything below is done and evidenced; nothing here is a proposal except the "Open questions" section.

## Where the increment stands

- **Story 1.1** (read-only lifecycle evaluation): frozen previously; unchanged this session.
- **Story 1.2** (Converge Managed State Without Losing Local Work — the transactional mutation path with the operation lock): **FROZEN — IMPLEMENTED + VERIFIED** as of 2026-08-25, on a CLEAN independent review verdict with all gates green.
- **Stories 1.3 / 1.4**: not started, deliberately — the handoff boundary was "stop before Story 1.3."
- Nothing is committed/pushed/PR'd. The whole increment lives in the working tree on `master` (HEAD `15a97ba`), as it did at session start. Packaging/commit strategy is an open question below.

## What this session did (coordinator view)

This was a PM/coordinator session. It wrote no code itself; it ran bounded fixer/reviewer cycles, each worker a **fresh session** (never an implementer reviewing its own work, never a reviewer fixing its own findings), each **centrally routed** (`POST /v1/route`, natural recommendation accepted every time — claude / claude-strong / effort high, subscription, metered=false, zero overrides), each decision **frozen into an immutable stamp** validated 8/8 by `agent-stamp-validate` before launch, each worker **Orca-supervised** (task + dispatch + authoritative `worker_done`, terminals released with transcripts archived after evidence retention). BMAD DEV persona (Amelia) resolution was proven fail-closed by identity hash in every worker.

### The defect campaign: one defect class, hunted to convergence

Everything this session fixed is one class in the Story 1.2 operation lock: **an observe-then-act race where a record seen to exist and then found gone was read as a permanent diagnosis instead of a transient moment — producing OPERATION_LOCK_OWNER_UNVERIFIABLE with "remove the lock by hand" guidance for a lock a live owner actually held.** Mutual exclusion was never broken by any of these; the harm was untruthful diagnosis + unsafe operator guidance.

| Cycle | What happened | Outcome |
|---|---|---|
| F6-R1 fix (inherited in-flight) | Acquisition now waits out the transient mkdir→owner.json publication window inside a bounded budget (~3s) instead of condemning the lock | Succeeded; gates green |
| Review #1 (fresh) | Attacked the fix — it held — but confirmed the implementer's self-reported residual (**F6-R2**, vanished arbitration marker → wrong refusal, reproduced at 4.7% of real contended CLI runs) and found a new same-class site (**F6-R3**, record vanishing between existence test and jq read reported as "unparseable") | NOT CLEAN |
| F6-R2R3 fix | Both sites now treat gone-as-a-moment (re-observe inside the same bounded budget); contract doc aligned; deterministic forced-interleaving regressions, anti-vacuity proven on reconstructed pre-fix trees with per-fix discrimination | Succeeded; gates green |
| Review #2 (fresh) | The R2/R3 fixes held at their sites — but the R3 repair's own discriminator raced (**F6-R4**: a *second* stat after the failed read can report a live successor's record as damaged), and a **pre-existing** hole surfaced (**F6-R9**: a reclaimer that destroys an abandoned lock then loses the take reports nothing — "reclamation is never silent" violated; made the required run-tests gate red 229/1, load-sensitive 2-in-5) | NOT CLEAN |
| F6-R4R9 fix | R4: record read **once**, judged on those bytes — no second observation to race. R9: reclamation reports at the destruction itself, exactly once, on every exit including losing the take. Plus: shellcheck sub-gate made fail-closed (it had been printing PASS without shellcheck ever running on this host — once genuinely running it immediately caught a real SC2120 in the cycle's own fixture), three falsified contract passages rewritten, and a CLI-level F6-R2 detector added | Succeeded; mutation gate 414/0 at 5-of-5 **under load** (the pre-fix red condition) |
| Review #3 (fresh, freeze-gating) | **CLEAN — zero Story 1.2-owned blockers.** Rebuilt both prior attack scripts after catching them passing vacuously on the fixed tree; proved exactly-once reclamation 15/15 vs 15/15 silent when reverted, at 8-way contention, and on all three CLI exits; re-swept the class (no new member introduced; one remaining member S1 forced and shown to fail closed); reran all gates independently | CLEAN → freeze |

### Final gate state (as independently rerun by the freeze-gating reviewer)

lifecycle 443/0 · concurrency 207/0 ×3 · mutation 414/0 on 5-of-5 loaded runs (+30 parallel load suites) · run-tests 231/0 (shellcheck genuinely executing, 12/12 clean) · `git diff --check` clean · exact per-fix anti-vacuity discrimination reproduced.

### Documented, deliberately-not-fixed residuals (all judged non-blocking by independent review)

- **F6-R5**: evaluate's `-e`/`-d` pair is the same class; 0 occurrences in 100,000 adversarial observations. Note: the fixer's justification for leaving it ("no deterministic interleaving exists between two adjacent builtins") was **refuted** by the final reviewer (a DEBUG trap interleaves them deterministically) — the finding stays non-blocking, but that justification must not be carried forward.
- **F6-R6**: the 4-attempt ceiling can be exhausted into an untruthful (not unsafe) "unverifiable" detail for a provably dead owner.
- **F6-R8**: a non-atomic restore guard can nest a stale dir inside a successor's lock — residue only.
- **S1**: reclaim re-reads a record whose incarnation the judge already returned (variable literally named `unused_inc`) — forced, fails closed.
- Three method findings on the fix cycle's own claims (e.g. the R9 discrimination floor is 410/4, not 409/5).

These are candidates for a small hardening story if we ever want the class fully extinct; none blocks Story 1.2.

## Evidence trail (all retained in-repo)

- `_bmad-output/implementation-artifacts/evidence/` — every review report (with runnable attack scripts and raw gate logs), every `worker_done` verbatim, per-cycle PM validation notes.
- `_bmad-output/implementation-artifacts/AFK-PORT-1.2-*.route-request/response/stamp.json` — the full routing provenance chain for all five dispatches this session.
- `AFK-PORT-1.2.md` Dev Agent Record + `traceability.md` — freeze declaration, cycle narratives, and the F1–F9 findings table mapping every fix to requirement pressure and named regressions.

## Process observations worth aligning on

1. **The adversarial-review loop earned its cost.** Three consecutive reviews each found real, reproducible defects the implementing session had honestly missed — including a defect *introduced by a fix* (F6-R4) and a *vacuous attack script* that would have silently passed a broken tree. The convergence pattern was healthy: each finding was a strictly narrower member of the same class.
2. **Gate integrity mattered as much as code**: a sub-gate printing PASS without running, and regression scripts that went vacuous against the fixed tree, were both caught only because reviewers were mandated to attack the evidence, not just the code.
3. **Central routing behaved**: five identical natural recommendations, no overrides needed, no metered spend, stamps validated 8/8 every time.
4. Suites grew from 443/377/146/230 to 443/414/207/231 assertions across the campaign.

## Open questions for the project (the alignment check)

1. **Packaging**: Story 1.2's cumulative diff is well beyond the 800-line reviewable budget (Story 1.1 was too). The story record already sketches a clean stacked split (plan → transaction → command surface → contract → gate). Do we commit/PR now as a stacked chain, or continue accumulating until the epic boundary?
2. **Hardening story**: do we want a small trailing story to extinguish the residual class members (F6-R5/R6/R8, S1), or accept them as documented?
3. **Story 1.3 kickoff**: ready to dispatch when directed — same routing/supervision discipline. Nothing has been started.
4. **Epic home**: this increment is tracked local-only (`_bmad-output/`); confirm it stays local-homed (no Linear artifacts were created).
