---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-PORT-1.5C-REVIEW.md.stamp.json
persona: dev
gates:
  - "bash tests/lifecycle-readiness-tests.sh"
  - "git diff --check"
max_cycles: 1
---

# AFK-PORT-1.5C-REVIEW — adversarial + senior review of Story 1.5 lane C (fresh session)

You are a fresh session; you did not write this code. Review branch
`jlengelbrecht/afk-port-1.5c` (commit `88c24b6`) against `master` @
`e76cb95`, in the worktree you are launched in. Spec:
`_bmad-output/implementation-artifacts/AFK-PORT-1.5C.md` (design ruling,
S1–S7, AC-1–8, hard stops) and the worker's Dev Agent Record. Authority:
`AFK-PORT-1.5.md` (frozen), PRD addendum Capability 5 (FR-102, FR-103),
NFR-13–15. Lanes A and B are the baseline (`AFK-PORT-1.5A.md`,
`AFK-PORT-1.5B.md` records and their review directories); do not re-open
dispositioned territory absent a new above-bar blocker visible in this diff.

Two lenses, both required: adversarial and senior.

## Attack, in priority order

1. **No new launch path, no substitution.** Both frozen launch command
   builders byte-identical to master's (source and compare); a continuation
   cycle reaches placement, fail-closed revalidation, the launch guard and
   the launch exactly as an ordinary cycle; grep for any route/profile/harness
   field being set from anything but the stamp.
2. **Same stamp, expired stamp.** An expired or invalidated stamp on a
   continuation cycle refuses with the validator's reason plus
   `CONTINUATION_STAMP_REFRESH_REQUIRED`, names the central `/v1/route`
   refresh in the marker, and leaves the stamp byte-identical; nothing
   re-stamps or re-routes locally.
3. **Artifact into prompt and estimate.** The continuation artifact's content
   enters the prompt as DATA under the fixed heading (no shell), and is
   counted in the lane A estimate so a large artifact can trip the sizing
   refusal (prove it); a missing/invalid artifact after a
   `continuation_required` cycle takes the `NEEDS_HUMAN` path with no result;
   an ordinary cycle is untouched; a cycle whose artifact belongs to a
   different story or a non-adjacent cycle.
4. **The cap.** Deterministic count from retained per-cycle results
   (`<story>.result.c<n>.json`); exactly `continuation_cap` continuations
   proceed; the next refuses (`CONTINUATION-CAP:` marker,
   `reason=CONTINUATION_CAP_REACHED`, count, cap, exact frontmatter shape),
   nothing placed or launched; a `continuation_decision:` naming the RIGHT
   cycle authorises it, the wrong cycle or a malformed decision does not;
   stale result files from another story or cycle cannot inflate or deflate
   the count; `REPEATED_CONTINUATION` on every continuation.
5. **Record chain.** `record_budget_line` idempotence keyed on code + cycle
   still holds under the race test; the chain line carries trigger, usage
   and artifact sha.
6. **Settlement.** `lib/afk-monitor.sh` byte-identical to master (the worker
   asserts it — verify, and verify the assertion is non-vacuous); a
   continuation cycle's thin result and watch record settle through the
   existing path with `context_budget` as lane B defined.
7. **Harness agnosticism, docs, hygiene.** No CLI name in core logic; both
   harnesses exercised; contract/SKILL/policy true of the code; diff inside
   the declared surface (~695/6 reported); commit plain, no trailers;
   `git diff --check` clean.

## Rules

Blocker bar (frozen convergence policy): (a) violates a frozen requirement
or a story AC, (b) reproduced, (c) reachable by natural occurrence or one
ordinary operator action; else residual. Do NOT modify product code, tests,
docs, records or git state. Write ONLY under
`_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.5C-REVIEW/`
(`REVIEW.md` + attack scripts with controls; scratch under `/tmp`). You may
run the readiness, dispatch and lifecycle suites and `git diff --check`; NOT
`tests/run-tests.sh` (the coordinator's chain is running in this worktree).
No secrets. No Story 1.6/1.8 material.

## Report shape (`REVIEW.md`)

1. Verdict line first: `AFK-PORT-1.5C REVIEW: CLEAN` or
   `AFK-PORT-1.5C REVIEW: NOT CLEAN — <n> blocker(s)`.
2. Blockers: id, AC/requirement, reproduction, reachability, minimal fix.
3. Residuals: id, severity, assessment, recommendation, plus your view on
   each disclosed item in the worker's record.
4. AC-by-AC coverage table (AC-1…AC-8) with evidence checked.
5. Gate tallies you ran, with wall times.

## Dev Agent Record

(reviewer fills in)
