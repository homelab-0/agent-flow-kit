---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-SPIKE-LOCAL-CLAUDE-EXIT-FIX-1.md.stamp.json
persona: dev
gates:
  - "git diff --check"
max_cycles: 1
---

# AFK-SPIKE-LOCAL-CLAUDE-EXIT-FIX-1: Incorporate the late field envelopes

The first spike commit `831564e44d8ac01c247853b44b1da28962ff2948`
completed before the coordinator discovered that the two original zero-byte
result files later became valid success envelopes. This correction is evidence
only. Run no more gateway cells.

## Authoritative new evidence

Read these files in the surviving ai-control-plane worktrees without editing
that repository:

- `/home/devbox/orca/workspaces/ai-control-plane/story-4-6-registry-proposal/_bmad-output/implementation-artifacts/stories/story-4.6-registry-proposal-contract.md.claude-result.json`
  — sha256 `03965bc7b687a4b0df5369528f40cc524c155e530bd042f3628bf35a23401898`,
  `result/success`, 142 turns, `duration_ms: 5604632`.
- `/home/devbox/orca/workspaces/ai-control-plane/story-4-4a-identity/_bmad-output/implementation-artifacts/stories/story-4.4a-identity-contract.md.claude-result.json`
  — sha256 `8993d1feeaa64d380b257f8c6b6518bbe5b4c40c1b7002a30e45bc63846f3635`,
  `result/success`, 106 turns, `duration_ms: 5743774`.

The dispatcher stopped waiting at 5,400,000 ms. The harnesses therefore
completed about 3m25s and 5m44s after the timeout, respectively. Their late
envelopes prove that `json` did terminate and that the processes continued
running after dispatch returned 2. They do not prove when the final model event
occurred relative to process exit.

## Required corrections

1. Add a secret-free retained summary under the spike evidence bundle. Record
   source path, source sha256, observed size/mtime, selected envelope fields,
   timeout delta, and what follows from them. Do not copy full result prose or
   any credential/environment material.
2. Correct `INDEX.md`, `FINDINGS.md`, `FIX-SCOPE.md`, and the parent story's
   Dev Agent Record. Remove claims that the field sessions stopped generating,
   never produced terminal envelopes, never exited, or require a larger
   reproduction spike. The narrow cause is a 90-minute timeout/106–142-turn
   workload mismatch, compounded by `json` buffering and by the launched
   process surviving the dispatch timeout.
3. Preserve the four-cell result: neither output format caused a failure, and
   `stream-json` exposes incremental events plus final-call usage.
4. Replace the proposed follow-up scope with three explicit queue items:

   - **Frozen launch/adapter update:** combine the already approved `Edit`
     addition with `stream-json --verbose` for both claude launch classes,
     parse exactly one terminal `result` event fail-closed, use the last
     assistant event for final-context usage, retain malformed/truncated and
     no-result refusal tests, and coordinate the exact launch text with
     ai-control-plane. This improves observability and fixes the earlier usage
     limitation; do not claim it makes long sessions finish sooner.
   - **Timeout fencing:** on launch timeout, stop/fence only the exact
     launcher-owned terminal/process before returning dispatch exit 2; prove no
     late process, envelope, or post-timeout write survives. Never remove a
     worktree, never infer success, and keep the refusal wording.
   - **Output-shaped planning:** add planner guidance/route metadata based on
     expected deliverables and likely turn volume rather than changing the
     input-byte budget's meaning. The field evidence supports avoiding large
     multi-document local stories; it does not support a universal numeric
     output-token threshold yet.

5. State sequencing: the frozen launch/adapter update first (one coordinated
   command-text amendment), timeout fencing second, output-shaped planning
   third. The opencode spike follows these urgent fixes.
6. Add a correction note to every earlier conclusion that changed; do not hide
   the original bounded-cell outcome.

## Acceptance criteria

- **AC-1:** Every corrected field claim cites the retained late-envelope
  summary and its source digest.
- **AC-2:** The verdict says both field sessions exited successfully after the
  dispatcher timeout and quantifies each overrun.
- **AC-3:** `json` buffering is identified as progress blindness, not the
  termination cause; `stream-json` is not described as a speed or exit fix.
- **AC-4:** Timeout fencing and stream parsing remain fail-closed. File state,
  silence, or a non-empty redirect never becomes completion.
- **AC-5:** The three implementation queue items are independently testable,
  ordered, and include the cross-repo launch-contract obligation.
- **AC-6:** No live calls, product changes, ai-control-plane edits, raw field
  envelopes, secrets, or attribution trailers. `git diff --check` passes.

## Editing and commit rules

Use `apply_patch` for every repository file edit. Do not use Python, `sed -i`,
heredocs, or shell redirection to edit files. One correction commit only; do
not push or open a PR. Update the parent story's Dev Agent Record with this
correction and disclose the first attempt's file-edit-method deviation.

## Dev Agent Record

### Outcome

Evidence-only correction. No live gateway calls, no product changes, no
ai-control-plane edits. Both late envelopes were read in place and verified by
digest before use: `03965bc7b687a4b0df5369528f40cc524c155e530bd042f3628bf35a23401898`
(6,213 bytes, mtime 2026-09-08 14:42:31 -0400) and
`8993d1feeaa64d380b257f8c6b6518bbe5b4c40c1b7002a30e45bc63846f3635`
(4,313 bytes, mtime 2026-09-08 16:13:59 -0400) — both match the digests this
story declared.

### Corrected verdict

Both field sessions exited successfully after the dispatcher timeout. Story 4.6
finished 142 turns at `duration_ms` 5,604,632 (93m 24.6s), 204,632 ms — 3m 24.6s
— past the 5,400,000 ms bound; story 4.4a finished 106 turns at 5,743,774 ms
(95m 43.8s), 343,774 ms — 5m 43.8s — past it. Each wrote a single
`result/success` envelope with `is_error: false`. The narrow cause is a
workload/timeout mismatch, compounded by `json` buffering (progress blindness,
not a termination cause) and by the launched process surviving the dispatch
timeout and writing to an abandoned path. The four-cell result is preserved
intact: neither output format caused a failure, and `stream-json` exposes
incremental events plus final-call usage.

### Files changed

- `evidence/AFK-SPIKE-LOCAL-CLAUDE-EXIT/LATE-ENVELOPES.md` — new; retained
  secret-free metadata summary, source digests, timeout deltas, and what does
  and does not follow.
- `evidence/AFK-SPIKE-LOCAL-CLAUDE-EXIT/INDEX.md` — correction banner, corrected
  verdict, contents row.
- `evidence/AFK-SPIKE-LOCAL-CLAUDE-EXIT/FINDINGS.md` — correction banner, the
  corrected three-events passage, a new field-cause section, one more eliminated
  hypothesis, reframed open questions, field-scale cumulative-usage figures, and
  the fencing consequence.
- `evidence/AFK-SPIKE-LOCAL-CLAUDE-EXIT/FIX-SCOPE.md` — correction banner,
  corrected answers to questions 4 and 5, the three-item ordered queue with
  per-item acceptance tests, and the withdrawn reproduction spike.
- `AFK-SPIKE-LOCAL-CLAUDE-EXIT.md` — correction note under the observed-defect
  table, corrected Dev Agent Record, AC-3 and AC-5 updated, deviation disclosed.
- `AFK-SPIKE-LOCAL-CLAUDE-EXIT-FIX-1.md` — this record.

`EXPERIMENT.md` and `sessions/` are unchanged: the predeclared matrix and the
captured cell artifacts are the historical record of what was run.

### Implementation queue

1. Frozen launch/adapter update — `Edit` plus `--output-format stream-json
   --verbose` in both claude launch classes as one coordinated command-text
   amendment, with the cross-repo launch-contract note owed to ai-control-plane;
   exactly one terminal `result` event parsed fail-closed; last assistant event
   for final-context usage; malformed/truncated and no-result refusal tests
   retained.
2. Timeout fencing — stop/fence only the exact launcher-owned terminal/process
   before returning dispatch exit 2, and prove no late process, envelope, or
   post-timeout write survives. No worktree removal, no inferred success, refusal
   wording unchanged.
3. Output-shaped planning — planner guidance and route metadata keyed on expected
   deliverables and likely turn volume, not on a new output-token threshold; the
   input-byte budget keeps its meaning.

The opencode spike follows these three.

### Acceptance criteria

- **AC-1** — met. Every corrected field claim in `INDEX.md`, `FINDINGS.md`,
  `FIX-SCOPE.md` and the parent record cites `LATE-ENVELOPES.md`, which carries
  both source digests.
- **AC-2** — met. The verdict states both sessions exited successfully after the
  timeout and quantifies each overrun in milliseconds and in minutes and seconds.
- **AC-3** — met. `json` buffering is named as progress blindness in all four
  documents, and `stream-json` is stated in `FIX-SCOPE.md` and the queue as
  neither a speed nor an exit fix.
- **AC-4** — met. The terminal condition remains a parsed `result` event AND an
  observed process exit, both. `FINDINGS.md` and `FIX-SCOPE.md` state that the
  late file does not make silence a completion signal, and item 2 keeps the
  refusal wording and forbids inferring success from anything found after a
  timeout.
- **AC-5** — met. Three queue items, each with its own intent, bounds and
  acceptance test, in a stated order, with the cross-repo launch-contract
  obligation on item 1.
- **AC-6** — met. No live calls, no product changes, no ai-control-plane edits.
  No raw envelope, result prose, session/message/tool-use identifier, or
  credential material is retained — only numeric and enumerated fields, sizes,
  mtimes and digests. `git diff --check` exit 0, no output. No attribution
  trailers in any committed artifact.

### Deviation disclosed

The first attempt (`831564e`) did not honour the editing-method rule: its bundle
files were written with shell redirection and heredocs rather than `apply_patch`.
Disclosed in the parent story's record. This pass used structured single-file
patch edits only.

### Gate

`git diff --check` — exit 0, no output.
