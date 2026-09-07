---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-PORT-1.5B-REVIEW.md.stamp.json
persona: dev
gates:
  - "bash tests/lifecycle-readiness-tests.sh"
  - "git diff --check"
max_cycles: 1
---

# AFK-PORT-1.5B-REVIEW — adversarial + senior review of Story 1.5 lane B (fresh session)

You are a fresh session; you did not write this code. Review branch
`jlengelbrecht/afk-port-1.5b` (commit `54dfd14`) against `master` @
`ec83010`, in the worktree you are launched in. Spec:
`_bmad-output/implementation-artifacts/AFK-PORT-1.5B.md` (design ruling,
S1–S7, AC-1–9, hard stops) and the worker's Dev Agent Record in that file.
Authority: `AFK-PORT-1.5.md` (frozen), PRD addendum Capability 5 (FR-99–101,
FR-104–105), NFR-13–15. Lane A's merged work is the baseline
(`AFK-PORT-1.5A.md` record; `evidence/AFK-PORT-1.5A-REVIEW/REVIEW.md` for
what was already attacked — do not re-open dispositioned territory absent a
new above-bar blocker visible in this diff).

Two lenses, both required: adversarial and senior.

## Attack, in priority order

1. **Frozen launch texts and the prompt paragraph.** Both builders
   byte-identical to master's for all classes (source and compare yourself).
   The new prompt paragraph is DATA: prove that no story/persona content and
   no launcher value can turn it into shell, and that it is byte-stable
   across runs of the same inputs.
2. **Usage adapters.** Claude: which envelope members feed `usage_tokens`,
   how the model key is chosen when `modelUsage` has zero, one or several
   entries, what happens on a missing/garbled envelope, on a window
   disagreement (`WINDOW_DISAGREEMENT` recorded, never resolved), and on a
   run that produced no result file. Codex: `NOT_EVALUATED` /
   `USAGE_UNOBSERVABLE` with no scraping — grep for any terminal/transcript
   read on the usage path.
3. **Post-run evaluation and precedence.** Ratios at exactly the thresholds;
   `HIGH_USAGE` at ≥ checkpoint; the rule that `CHECKPOINT_DUE` /
   `CONTINUATION_REQUIRED` are reached only from a computed ratio or a
   worker signal (never inferred from unobservability); that lane A's
   pre-dispatch verdict is never overwritten by post-run unobservability;
   the ordering post-`NEEDS-HUMAN`, pre-gates, and whether gates over a
   half-finished tree can ever produce `status: done`.
4. **Artifacts.** Schema validation (`afk-checkpoint/1`,
   `afk-continuation/1`), required members, unparseable JSON, a valid
   checkpoint with a missing continuation, the `ARTIFACT_STALE` identity
   check (pre-launch sha equal after run), a worker that prints
   `CONTINUATION-REQUIRED:` twice, or with an empty reason, or with a reason
   containing shell metacharacters or a secret-looking value (must be
   redacted through `artifact_redact` before any marker/log/result);
   confirm only identity (path + sha256) reaches the result.
5. **NEEDS_HUMAN path.** Invalid/missing continuation artifact → exit 3,
   `.blocked` marker with `CONTINUATION_ARTIFACT_INVALID`, NO result artifact,
   monitor surfaces it; and no path manufactures a completed result.
6. **Record append.** `record_budget_line` idempotence keyed on code + cycle;
   the lane A race test still holds on the new signature; sizing and
   continuation lines in one cycle coexist.
7. **Watch record / status.** `context_budget` on the watch record after
   reconcile, sourced from the retained thin result; bounded vocabulary;
   absent → `NOT_EVALUATED`; no retrofit of the frozen 1.3 orchestration
   document; `schema` lists the new status and reasons; contract
   machine-checkable blocks in sync with the code.
8. **Harness agnosticism.** No CLI name in core budget logic; adapters named
   per harness; both harnesses exercised.
9. **Docs truth, diff size, hygiene.** Every contract/SKILL/policy sentence
   true of the code; the reported 800/34 figure; commit message plain, no
   trailers; diff inside the declared surface; `git diff --check` clean.

## Rules

Blocker bar (frozen convergence policy): (a) violates a frozen requirement
or a story AC, (b) reproduced, (c) reachable by natural occurrence or one
ordinary operator action; else residual with severity + recommendation.
Do NOT modify product code, tests, docs or the story record. Write ONLY
under `_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.5B-REVIEW/`
(`REVIEW.md` + attack scripts with controls; scratch under `/tmp`). You may
run `bash tests/lifecycle-readiness-tests.sh`,
`bash tests/lifecycle-dispatch-tests.sh`, `bash tests/lifecycle-tests.sh`,
`git diff --check`. Do NOT run `tests/run-tests.sh` (the coordinator's chain
is running in this worktree). No secrets. No Story 1.6/1.8 material.

## Report shape (`REVIEW.md`)

1. Verdict line first: `AFK-PORT-1.5B REVIEW: CLEAN` or
   `AFK-PORT-1.5B REVIEW: NOT CLEAN — <n> blocker(s)`.
2. Blockers: id, AC/requirement, reproduction, reachability, minimal fix.
3. Residuals: id, severity, assessment, recommendation, plus your view on
   each disclosed item in the worker's record.
4. AC-by-AC coverage table (AC-1…AC-9) with evidence checked.
5. Gate tallies you ran, with wall times.

## Dev Agent Record

(reviewer fills in)
