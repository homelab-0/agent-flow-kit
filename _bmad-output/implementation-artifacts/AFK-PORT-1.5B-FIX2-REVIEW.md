---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-PORT-1.5B-FIX2-REVIEW.md.stamp.json
persona: dev
gates:
  - "bash tests/lifecycle-readiness-tests.sh"
  - "git diff --check"
max_cycles: 1
---

# AFK-PORT-1.5B-FIX2-REVIEW — diff-scoped review of the usage-adapter fix (fresh session)

You are a fresh session. Scope is the DIFF of commit `ffc2b2e` on branch
`jlengelbrecht/afk-port-1.5b-fix2b` against `master` @ `4b873ab` — the fix
cycle `AFK-PORT-1.5B-FIX2.md` (F1–F6) answering an external report
(`evidence/AFK-PORT-1.5B-FIX2/fu1-*.json`, and the handoff text in
`AFK-HANDOFF-usage-adapter-and-local-tools-2026-09-07.md` if present).
Diff-scoped: verify each remedy and the anti-vacuity of each new test; do
not re-open dispositioned territory absent a NEW above-bar blocker visible
in this diff.

## Verify, per item

- **F1.** Feed `tests/fixtures/claude-result-envelope-multiturn.json` (83
  turns) through the adapter yourself: `usage_scope: CUMULATIVE_RUN`,
  `usage_ratio: null`, `usage_reason: USAGE_CUMULATIVE_ONLY`, no `HIGH_USAGE`,
  budget state `NOT_EVALUATED` from usage while lane A's pre-dispatch verdict
  stands. Feed a single-turn envelope: `FINAL_CONTEXT` and a ratio. Prove the
  policy's `HIGH_USAGE` is asserted only from `FINAL_CONTEXT` (mutate a
  fixture to num_turns 1 with the same totals and show the ratio then
  appears). Confirm the new tests fail against `master`'s adapter
  (scratch copy).
- **F2.** Walk the status matrix live from the fixed source: no row yields
  `status: continuation_required` without a valid worker artifact; ratio-
  derived states never change the status; gates decide `done` vs
  `gates_failed`; contract table matches.
- **F3.** The generated prompt names the absolute working directory and the
  relative-path rule; byte-stable; the story/persona cannot alter it.
- **F4.** `total_cost_usd`/`costUSD` never reach the thin result or any kit
  aggregate (grep + behavioural).
- **F5.** The `CONTINUATION-CAP:` marker's suggested `max_cycles` is
  max(existing, authorised cycle); contract says `max_cycles` still bounds
  continuations under the cap.
- **F6.** Registry section present in `AFK-PORT-1.5B.md`.
- **Frozen texts and surface.** Both launch texts and `lib/afk-monitor.sh`
  byte-identical to `master`; diff inside the fix story's surface (the
  fixture under `tests/fixtures/` is secret-free — check by pattern); commit
  plain, no trailers; `git diff --check` clean.

## Rules

Blocker bar as before. Do NOT modify product code, tests, docs, records or
git state. Write ONLY under
`_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.5B-FIX2-REVIEW/`
(`REVIEW.md` + probe scripts with controls; scratch under `/tmp`). You may
run the readiness, dispatch and lifecycle suites and `git diff --check`;
NOT `tests/run-tests.sh` (the coordinator's chain is running here). No
secrets.

## Report shape (`REVIEW.md`)

1. `AFK-PORT-1.5B-FIX2-REVIEW: CLEAN` or `NOT CLEAN — <n> blocker(s)`.
2. Per item F1–F6: VERIFIED / PARTIAL / NOT VERIFIED with probe and output.
3. New blockers/residuals.
4. Gate tallies you ran.

## Dev Agent Record

(reviewer fills in)
