---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-PORT-1.5A-REVIEW.md.stamp.json
persona: dev
gates:
  - "bash tests/lifecycle-readiness-tests.sh"
  - "git diff --check"
max_cycles: 1
---

# AFK-PORT-1.5A-REVIEW — adversarial + senior review of Story 1.5 lane A (fresh session)

You are a fresh session; you did not write this code. Review branch
`jlengelbrecht/afk-port-1.5a` (commits `3b588c9` implementation, `daa00e9`
record) against `master` @ `39fd66c`, in the worktree you are launched in.
Spec: `_bmad-output/implementation-artifacts/AFK-PORT-1.5A.md` (S1–S6,
AC-1–9, hard stops) and the worker's Dev Agent Record in that file, which
discloses its method choices and a diff-size overrun. Requirement authority:
`AFK-PORT-1.5.md` (frozen) and the PRD addendum Capability 5 (FR-96–99).

Two lenses, both required: adversarial (break it) and senior (right,
minimal, true to the frozen contracts, harness-agnostic).

## Attack, in priority order

1. **The frozen launch texts.** Both launch command builders must produce
   byte-identical output to master's for every class (native claude, gateway
   claude, codex). Source master's and HEAD's builders in separate shells and
   compare yourself; then judge whether the new suite oracle is non-vacuous.
2. **Refusal ordering and side effects.** Prove that a ≥ 0.85 estimate creates
   no placement call, no validation call, no terminal, no command text, no
   result artifact, and exits 8 with a `STORY-SIZING:` marker; prove that the
   policy-unreadable case refuses before the stamp is opened. Then try to
   reach a launch with a bad policy (missing key, non-numeric threshold,
   thresholds out of order, ratio strings like `.85`, `85%`, `0.850`).
3. **Arithmetic at the edges.** Ratios exactly at 0.60 and 0.85; window 0 or
   null; estimate 0; huge payloads; `payload_refs` with duplicates, symlinks,
   directories, a path outside the worktree, an absolute path, a missing
   path (must refuse, config exit); the dedupe-on-realpath claim.
4. **Window resolution.** Only the trusted catalog at the stamp's
   `catalog_version`; never the stamp; a profile with no `min_context` →
   `NOT_EVALUATED` + `CONTEXT_WINDOW_UNDECLARED`, dispatch proceeds, no
   findings; the gateway class's `CLAUDE_CODE_MAX_CONTEXT_TOKENS` untouched.
5. **Record append.** Idempotent per cycle, appended inside the Dev Agent
   Record section, inode/permissions preserved, story without the heading;
   a story whose Dev Agent Record is the LAST section vs. followed by
   another `## ` heading; concurrent cycles; whitespace at EOF; does the
   append ever alter frontmatter or the gates list.
6. **Route requests untouched.** `make-stamp.sh` request body carries no
   `context_size`/capacity input after this change; assert with the real
   script against a stub router.
7. **Harness agnosticism.** No CLI name inside the policy file, the estimate,
   the thresholds or the reason codes; adapters only where the harness
   matters; both harnesses and both launch classes exercised by the suite.
8. **Docs truth and diff size.** `docs/LIFECYCLE-CONTRACT.md` `## The context
   budget`, the `budget_states` machine-checkable block, `SKILL.md`, the
   policy file comments: every sentence true of the code. Then your own
   independent opinion on the disclosed 947-line reviewable diff against the
   800 budget: is there a split that leaves each layer independently
   reviewable, or is the worker's "no meaningful lower layer" argument right?
9. **Hygiene.** Diff inside the declared surface (the committed gate logs
   under `evidence/AFK-PORT-1.5A/` are generated; say whether they belong in
   the code PR); commit messages plain, no trailers; no stray files;
   `git diff --check` clean.

## Rules

Blocker bar (frozen convergence policy): blocks only if (a) violates a frozen
requirement or a story AC, (b) you reproduced it, (c) reachable by natural
occurrence or one ordinary operator action; else residual with severity and
recommendation. Do NOT modify product code, tests, docs or the story record.
Write ONLY under `_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.5A-REVIEW/`
(`REVIEW.md` plus attack scripts with controls; scratch copies under `/tmp`).
You may run `bash tests/lifecycle-readiness-tests.sh`,
`bash tests/lifecycle-tests.sh` and `git diff --check`. Do NOT run
`tests/run-tests.sh` (the coordinator is running the full chain in this
worktree — do not disturb it). No secrets. No Story 1.6/1.8 material.

## Report shape (`REVIEW.md`)

1. Verdict line first: `AFK-PORT-1.5A REVIEW: CLEAN` or
   `AFK-PORT-1.5A REVIEW: NOT CLEAN — <n> blocker(s)`.
2. Blockers: id, AC/requirement, exact reproduction (script + output),
   reachability, minimal fix.
3. Residuals: id, severity, assessment, recommendation (fix-now / backlog /
   accept), including your view on each disclosed item in the worker's record.
4. AC-by-AC coverage table (AC-1…AC-9) with evidence checked.
5. Gate tallies you ran, with wall times.

## Dev Agent Record

(reviewer fills in)
