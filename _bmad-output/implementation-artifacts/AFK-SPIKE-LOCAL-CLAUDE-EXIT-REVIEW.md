---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-SPIKE-LOCAL-CLAUDE-EXIT-REVIEW.md.stamp.json
persona: dev
gates:
  - "git diff --check"
max_cycles: 1
---

# AFK-SPIKE-LOCAL-CLAUDE-EXIT-REVIEW: Fresh-session evidence review

Review `origin/master..b6587b5` adversarially. This is an evidence and product-
decision review, not implementation. Write only the review report and this
story's Dev Agent Record.

## Required checks

1. Recompute both late source-envelope digests and independently extract
   `type`, `subtype`, `is_error`, `num_turns`, `duration_ms`, size and mtime.
   Confirm every retained value and timeout delta in `LATE-ENVELOPES.md`.
2. Sample all four live-cell metadata files and terminal events. Confirm the
   matrix totals, exits, turns, durations, declared-file counts and final-call
   usage claims.
3. Search the corrected parent story, `INDEX.md`, `FINDINGS.md` and
   `FIX-SCOPE.md` for stale assertions that either field process never exited,
   that `json` caused non-termination, or that `stream-json` is an exit/speed
   fix. Historical wording is allowed only when explicitly marked as corrected.
4. Test the causal statement: the field evidence proves a 5,400,000 ms timeout
   versus 5,604,632/5,743,774 ms successful runs, `json` progress blindness,
   and a late process/result surviving dispatch exit 2. It does not prove the
   timing between final model event and process exit.
5. Review the three queued fixes for independence, fail-closed acceptance and
   correct sequencing. The combined Edit/stream-json item must carry the
   ai-control-plane contract update; timeout fencing must target only the exact
   launcher-owned process/terminal and never a worktree; output-shaped planning
   must not invent a universal numeric threshold from two runs.
6. Confirm only implementation-artifact paths changed, raw field envelopes and
   secrets were not copied, source worktrees were not edited, and no AI
   attribution trailer exists.

## Deliverable and verdict

Write
`_bmad-output/implementation-artifacts/evidence/AFK-SPIKE-LOCAL-CLAUDE-EXIT-REVIEW/REVIEW.md`
with exact commands/evidence and one verdict:

- `AFK-SPIKE-LOCAL-CLAUDE-EXIT REVIEW: CLEAN`, or
- `AFK-SPIKE-LOCAL-CLAUDE-EXIT REVIEW: NOT CLEAN — <N> blockers`.

Separate blockers from advisory findings. A blocker is a false causal claim,
wrong source fact, unsafe completion/fencing proposal, secret exposure, missing
cross-repo obligation, or an acceptance gap that changes the queued work.

Run `git diff --check`. One review-artifact commit only, no product/evidence
rewrites, no push or PR, no trailers.

## Dev Agent Record

Fresh independent session; did not author the reviewed work. Reviewed
`origin/master..b6587b5` on branch `jlengelbrecht/afk-spike-local-claude-exit`.
Route `{claude, claude/strong, effort medium}`, stamp
`_bmad-output/implementation-artifacts/AFK-SPIKE-LOCAL-CLAUDE-EXIT-REVIEW.md.stamp.json`.
Persona proof (BMAD dev, outer hash):
`4cdff719c4f3042532520611f7106d80393173004355e6a83771b366c3efc7f9` — matched.

### Verdict

`AFK-SPIKE-LOCAL-CLAUDE-EXIT REVIEW: NOT CLEAN — 3 blockers`

All three sit in `FIX-SCOPE.md` item 1's specification of the queued
launch/adapter work. The field diagnosis, the four-cell result, the causal
restraint and the fail-closed rule all survive the review intact.

- **Blocker 1** — `cache_creation_input_tokens` is documented as "observed
  `null`" on the final assistant event; it is absent from all 28 assistant
  `usage` objects in cell 4 and appears only on the terminal envelope. The
  prescribed fixture tests the unobserved shape; the observed shape is
  untested. Wrong source fact plus an acceptance gap. The parent story's AC-5
  line repeats the error.
- **Blocker 2** — the occupancy formula `input + cache_read + output`
  contradicts the shipped `usage_adapter_claude`, which deliberately excludes
  output tokens and sums cache-creation instead (`dispatch.sh:842-845`). Item 1
  directs a rewrite of that function without flagging the reversal, and
  `FIX-SCOPE.md` is internally inconsistent (four members listed, three summed).
  The evidence cannot catch it: `output_tokens` is 0 in every observed assistant
  event, so both formulas give 15,134 and 17,842.
- **Blocker 3** — reading per-call usage flips multi-turn claude runs from
  `CUMULATIVE_RUN`/`USAGE_CUMULATIVE_ONLY` to `FINAL_CONTEXT`, which switches on
  ratio and band evaluation (`HIGH_USAGE`, `CONTINUATION_REQUIRED`) and the PM
  readiness remedy path. Item 1's expected surface names only `dispatch.sh` and
  new fixtures; existing assertions at `tests/run-tests.sh:1766-1806` and
  `tests/lifecycle-readiness-tests.sh:1489-1520` encode the current semantics.

Eight advisory findings (A1-A8) are recorded in the report: a reversed
turn/duration pairing in prose, an unmarked superseded figure in
`EXPERIMENT.md`, the parent story's uncorrected H1, evidence held more
conservatively than it needs to be on the timing question, a non-reproducible
redaction step, an n=2 inference in item 3, a missing fixture for the observed
multi-event-per-message shape, and an unstated interaction between items 1
and 2.

### Method

Facts were recomputed, not read. Both late envelopes were re-digested and
re-`stat`ed in place and every retained member re-extracted with `jq`; all four
cells' `meta.json` values were re-derived from their own retained streams
(digests, elapsed times, turn counts, terminal events, tool sequences, declared
files, cumulative and final-call sums); the 5,400,000 ms bound, exit code 2 and
the un-fenced timeout path were confirmed in `dispatch.sh` rather than taken
from prose. Exact commands and results are in the report.

### Deliverable

`_bmad-output/implementation-artifacts/evidence/AFK-SPIKE-LOCAL-CLAUDE-EXIT-REVIEW/REVIEW.md`

### Scope observed

Evidence-only. No reviewed artifact, product file, test, or source worktree was
edited; no gateway cell was run; no push or PR. This commit contains the review
report and this record.

### Gate

`git diff --check` — exit 0, no output.
