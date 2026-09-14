---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-PORT-1.5D-FIX-2.md.stamp.override-derived.json
persona: dev
gates:
  - "bash tests/lifecycle-readiness-tests.sh"
  - "bash tests/lifecycle-dispatch-tests.sh"
  - "bash tests/lifecycle-tests.sh"
  - "git diff --check"
max_cycles: 1
---

# AFK-PORT-1.5D-FIX-2 — restore the fix cycle's declared path boundary

Correct the completed B1/B2 fix commit `f61b9da2079a8ea89869cd083744161f582628b8`
without changing either blocker fix or its regression coverage.

## Required correction

1. Restore `tests/lifecycle-dispatch-tests.sh` byte-for-byte to its state at
   pre-fix commit `2b7b29fd3d2d149b65e427fd411f833bca5c86ab`.
2. Recover the resulting three product-budget lines only by mechanical folding
   inside the lane-D additions in `tests/lifecycle-readiness-tests.sh` and/or
   `tests/lifecycle-tests.sh`. Do not remove or weaken a case, assertion,
   diagnostic, or acceptance criterion.
3. Amend the existing lane-D commit again. Keep one commit above base and keep
   its attribution/session-free message unchanged.

## Acceptance criteria

- `git diff 2b7b29f HEAD -- tests/lifecycle-dispatch-tests.sh` is empty.
- The B1 and B2 code lines in `lib/afk-commands.sh` are byte-identical to
  `f61b9da`, and their new regression matrix/row remain present.
- Product diff against `32e94cc` is at most 800 added+changed lines across the
  same eight files; no exception.
- All four declared gates pass.
- The branch remains exactly one clean, attribution-free commit above base.

## Hard boundaries

- Product edits are restricted to the three named test files. The dispatch file
  may only be restored; all line recovery must occur in readiness/lifecycle.
- Do not touch `lib/afk-commands.sh`, docs, skills, binaries, routing, dispatch
  behavior, worker watches, residuals R1–R12, or any other product path.
- Do not run the aggregate suite, push, or open a PR.

## Dev Agent Record

### What changed

- `tests/lifecycle-dispatch-tests.sh` restored byte-for-byte to `2b7b29f`.
  `git diff 2b7b29f HEAD -- tests/lifecycle-dispatch-tests.sh` is empty.
- Three lines recovered inside the lane-D block of
  `tests/lifecycle-readiness-tests.sh` by joining backslash continuations only
  (the `BAD` accumulator condition, the duplicate-code assertion, and the
  `pm-checkpoint` command assertion). No case, assertion, diagnostic or
  acceptance criterion was removed or weakened; the folded lines are 103-137
  characters against a file that already carries lines up to 216.
- Nothing else touched: `git status` over `bin docs files lib tests` was empty
  after the amend, and `git diff f61b9da HEAD -- lib/afk-commands.sh` is empty,
  so both blocker fixes and their regression matrix/row stand unchanged.

### Budget

Product diff against `32e94cc`, the eight product files: 793 added, 7 deleted,
800 added+changed — the same figure as before the correction.

| file | + | - |
| --- | --- | --- |
| bin/agent-flow-kit | 59 | 4 |
| docs/LIFECYCLE-CONTRACT.md | 87 | 0 |
| files/model-router/SKILL.md | 26 | 0 |
| lib/afk-commands.sh | 315 | 3 |
| lib/afk-common.sh | 18 | 0 |
| tests/lifecycle-dispatch-tests.sh | 74 | 0 |
| tests/lifecycle-readiness-tests.sh | 137 | 0 |
| tests/lifecycle-tests.sh | 77 | 0 |

### Gates

| gate | result |
| --- | --- |
| `bash tests/lifecycle-readiness-tests.sh` | 359 passed, 0 failed (rc 0) |
| `bash tests/lifecycle-dispatch-tests.sh` | 274 passed, 0 failed (rc 0) |
| `bash tests/lifecycle-tests.sh` | 503 passed, 0 failed (rc 0) |
| `git diff --check` | clean (rc 0) |

### Commit

Amended in place: `da1c7bf`, one commit above `32e94cc`, message unchanged and
free of attribution or session lines. No push, no PR, aggregate suite not run.
