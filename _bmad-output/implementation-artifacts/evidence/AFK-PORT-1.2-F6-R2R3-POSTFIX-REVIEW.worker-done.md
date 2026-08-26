# AFK-PORT-1.2-F6-R2R3-POSTFIX-REVIEW — worker_done evidence (retained by PM)

- **Run:** run_09474acba864
- **Task:** task_b2f45fc1fc94
- **Dispatch:** ctx_dcb1738cc857
- **Reviewer terminal:** term_e81e4689-7975-4d0d-81ac-be52ba1aba3c (fresh third-distinct session)
- **Message:** msg_8e44aa57315b (delivery_44ae34c98092, sequence 115)
- **Sent:** 2026-08-25T09:35:31Z
- **Outcome:** succeeded (review completed; verdict NOT CLEAN)
- **Stamped route:** claude / claude/strong / high / subscription, metered=false (stamp validated 8/8; not substituted)
- **Persona proof:** requested=dev, resolved=BMAD DEV (Amelia), identity sha256:07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee — matched, fail-closed
- **Read-only contract:** honoured — HEAD 15a97baf unchanged, git status byte-identical to pre-review snapshot, no repo file touched
- **Full report retained at:** `evidence/AFK-PORT-1.2-F6-R2R3-POSTFIX-REVIEW.md` (attack scripts under `-attack/`, gate logs under `-gates/`; the 25MB reconstructed pre-fix trees were left in reviewer scratch, not retained)

## Verdict

**NOT CLEAN for Story 1.2 — two Story 1.2-owned blockers.** The F6-R2/F6-R3 fixes are correct at their own sites and held under direct attack; mutual exclusion was never broken and no successor lock was ever destroyed in any attack.

### BLOCKER F6-R4 — the F6-R3 discriminator, raced

`lib/afk-mutate.sh:305-317` decides gone-vs-unparseable with ONE stat taken AFTER the failed read — it asks "is a record there now", not "is the record I read still there". Deterministic repro (`attack/A4b-discriminator-race.sh`): rc=3, owner_detail "the lock owner record could not be parsed" with a LIVE successor provably holding the lock → OPERATION_LOCK_OWNER_UNVERIFIABLE + remove-by-hand — the exact harm F6-R1/R2/R3 were fixed for. Occurs naturally: 6 "could not be parsed" verdicts in 40,000 adversarial evaluate calls, ZERO of them true. Falsifies LIFECYCLE-CONTRACT.md:196. Reviewer's suggested local fix: read once (cat), decide from those bytes — no second observation to race.

### BLOCKER F6-R9 — silent reclamation; a required gate is red

`bash tests/run-tests.sh` = 229 passed / 1 FAILED rc=1 (embedded mutation gate 389/1 on "F6 the abandoned lock is still reclaimed exactly once", tests/lifecycle-mutation-tests.sh:1721, scenario f6contend4; 2 failures in 5 runs under load, 390/0 idle). Root cause forced deterministically (`attack/A9b-silent-reclaim-forced.sh`): afk_lock_reclaim renames the abandoned lock aside, removes it, then loses afk_lock_take to a contender and returns 3 — AFK_LOCK_RECLAIMED is only set on rc 0, so the abandoned lock is destroyed and nobody emits OPERATION_LOCK_RECLAIMED. Contradicts lib/afk-commands.sh:733-735 and LIFECYCLE-CONTRACT.md:167-169. Pre-existing (not introduced by R2/R3) but Story 1.2-owned; the freeze cannot rest on a gate failing 2-in-5.

## Non-blockers (all reproduced)

- **F6-R5**: afk_lock_evaluate's `[[ -e ]]` then `[[ ! -d ]]` pair is the same vanished-record class (undisclosed) — 0 occurrences in 100,000 adversarial observations; cheap repair: treat a lock no longer there as NONE.
- **F6-R6**: the 4-attempt ceiling can be exhausted into rc 3 with detail "pid N is no longer running" — UNVERIFIABLE for a provably dead owner; untruthful, not unsafe (5 of 40 acquisitions under a vanish adversary).
- **F6-R8**: restore guard `[[ -e DIR ]] || mv` is not atomic; mv onto an existing directory NESTS — residue only, mutual exclusion unaffected.
- Contract sentences LIFECYCLE-CONTRACT.md:185 and :196 overstate what is proven.
- A CLI-level deterministic F6-R2 regression IS constructible (attack/A7) though the fix report claimed otherwise; library coverage sufficient today — recommends adding the fixture.

## Residual-risk dispositions (of the fix report's five)

1. R2 spends an acquisition attempt — ACCEPTABLE-DOCUMENTED (bounded, worst 1306 ms; exhaustion yields untruthful-not-unsafe F6-R6; the dangerous composition could not be produced end-to-end in 22 tuned attempts).
2. One-stat discriminator — **BLOCKER** (F6-R4).
3. jq-coupling of F6-R3 fixtures — ACCEPTABLE-DOCUMENTED, fail loudly.
4. No CLI-level F6-R2 detector — ACCEPTABLE-DOCUMENTED, but the stated reason is wrong (fixture constructible via the marker judge's jq fork).
5. shellcheck sub-gate — ACCEPTABLE-DOCUMENTED but FAILING THAT WAY ON THIS HOST: shellcheck absent from PATH, nix fallback errors, gate prints PASS from empty stdout. Reviewer verified independently with ShellCheck 0.11.0: all 12 scripts genuinely clean. The verdict is true; the gate did not establish it.

## Defect-class sweep

Nine observe-then-act sites classified across lib/afk-mutate.sh (plus lock-touching lines of afk-common.sh/afk-commands.sh): two FIXED (R2, R3-site), one fixed-but-racy-repair (F6-R4), one unfixed undisclosed member (F6-R5), two racy-but-residue-only restore guards (F6-R8), rest safe/class-correct. F6-R1 interactions handled; the shared budget being spent across LOCKS (not per lock) is the one interaction noted (residual 1).

## Prior scenarios, anti-vacuity, gates

- All thirteen prior F6 scenarios + F6-R1 window suite: no regression (concurrency 174/0 twice, incl. under load; independent 8×10-way contention: peak owners always 1, 0 residue).
- Anti-vacuity: confirmed; discrimination reproduces exactly the fix report's numbers (174/0 vs 169/5 / 169/5 / 164/10; f6vanishrecord 13/0 vs 7/6).
- Gates rerun: lifecycle 443/0 rc0; mutation 390/0 idle but 389/1 rc1 in 2 of 5 runs under load (F6-R9); concurrency 174/0 rc0 ×2; run-tests 229/1 rc1 (F6-R9); git diff --check clean; shellcheck independently clean 12/12.

## PM disposition

Story 1.2 is NOT frozen. A bounded fresh fixer cycle for F6-R4 + F6-R9 (with contract-line truth alignment) is required, followed by a fresh independent review.
