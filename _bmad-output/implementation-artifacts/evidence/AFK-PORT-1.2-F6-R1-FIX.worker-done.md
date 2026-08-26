# AFK-PORT-1.2-F6-R1-FIX — worker_done evidence (retained by PM)

- **Run:** run_09474acba864
- **Task:** task_7bb706826507
- **Dispatch:** ctx_cad29bb8a1df
- **Worker terminal:** term_2f42c45c-a282-44f8-8a60-122657e3f319
- **Message:** msg_5e3d06c0adcc (delivery_fe62ccfa5414, sequence 80)
- **Sent:** 2026-08-25T04:29:07Z
- **Outcome:** succeeded
- **Accepted route (stamped):** claude / claude-strong / opus / high effort / subscription, metered=false, placement not required, no override
- **Persona proof:** requested=dev, resolved=BMAD DEV (Amelia), identity sha256:07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee
- **Report path:** `_bmad-output/implementation-artifacts/AFK-PORT-1.2.md`
- **Files modified (declared):** lib/afk-mutate.sh, docs/LIFECYCLE-CONTRACT.md, tests/lifecycle-concurrency-tests.sh, tests/lifecycle-mutation-tests.sh, tests/lockctl-helper.sh, _bmad-output/implementation-artifacts/AFK-PORT-1.2.md, _bmad-output/implementation-artifacts/traceability.md

## Subject

F6-R1 fixed: mid-publication lock is waited on, not condemned

## Full report body (verbatim)

Persona resolved fail-closed (requested=dev, resolved=BMAD DEV (Amelia), sha256:07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee matched) and I implemented only F6-R1: afk_lock_acquire now waits out the transient 'lock carries no owner record' state inside a bounded budget (120 observations, ~3s, spent across the whole acquisition) instead of returning 3 and telling a contender to remove a lock a live winner is still publishing, while every other unjudgeable record still refuses instantly and a lock that never publishes still fails closed with a truthful 'none appeared while it was waited on' detail; the two adjacent same-window mis-refusals (a lock that vanished after the failed mkdir, and a NONE observation) now re-observe inside the same bounded loop. Regressions were added that genuinely fail on the pre-fix tree and pass on the fixed one, verified by reverting the lock module and re-running three times each: library-level concurrency section 10 (window held open with new lockctl verbs publish-slowly/acquire-announced, an ownerless window, a settled owner costing zero wait, twelve contenders on a clean lock path) plus wait accounting on all twelve fail_closed_case records went 128 passed/18 failed pre-fix to 146 passed/0 failed post-fix, and command-level f6window (a real agent-flow-kit update held inside the window, observed waiting via /proc, asserted to report CONCURRENT_OPERATION_IN_PROGRESS and never guidance containing 'remove') plus f6contendclean (eight real updates from one barrier on a clean lock path) went 6 failed pre-fix to 0 post-fix; nothing depends on /tmp beyond the suites' own mktemp roots. Final gates all green with no edit in flight: lifecycle 443/0, mutation 377/0, concurrency 146/0 (three extra clean re-runs, all 146/0), run-tests 230/0 with shellcheck clean, git diff --check clean and zero trailing-whitespace hits; Story 1.2 record and traceability describe the fix and evidence without freezing the story, Story 1.3 was not started, and the remaining risks are the ~3s cost on a genuinely ownerless lock, the wait being a bounded heuristic rather than an atomic publish, and one further same-family mis-refusal I observed but deliberately did not fix (a lost arbitration marker vanishing between its existence check and its judge makes reclaim return 2, so a loser can still be told to remove a lock a successor may hold) which is documented for the reviewer.

## PM validation notes (alignment only — no line review)

- Declared gate results: lifecycle 443/0, mutation 377/0, concurrency 146/0 (plus three clean re-runs), run-tests 230/0 with shellcheck clean, `git diff --check` clean. All six required gates covered, including the new F6-R1 regressions (proven anti-vacuous against a reconstructed pre-fix tree, three runs each way).
- Declared file surface matches the working tree; Story 1.3 not started; story not self-frozen — correct per cycle contract.
- **Open item handed to the independent reviewer:** residual same-family mis-refusal — a lost arbitration marker vanishing between its existence check and its judge makes reclaim return 2, so a loser can still be told to remove a lock a successor may hold. Reviewer must judge whether this is a Story 1.2-owned blocker.
