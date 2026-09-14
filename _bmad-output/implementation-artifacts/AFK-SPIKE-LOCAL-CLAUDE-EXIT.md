---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-SPIKE-LOCAL-CLAUDE-EXIT.md.stamp.json
persona: dev
gates:
  - "git diff --check"
max_cycles: 1
---

# AFK-SPIKE-LOCAL-CLAUDE-EXIT: Diagnose gateway sessions reported as never exiting

> The title as filed read "successful gateway sessions that never exit". The
> diagnosis found no non-exit: both sessions ran to a normal end past the
> dispatch bound. The heading is worded so it cannot be quoted as asserting
> otherwise; see the correction below and
> `evidence/AFK-SPIKE-LOCAL-CLAUDE-EXIT/LATE-ENVELOPES.md`.

Raised from the ai-control-plane PM's second external report on 2026-09-08.
This is a bounded, evidence-only live diagnostic. It precedes the already
approved `Edit` tool change so that one proven launch-contract amendment can
be designed instead of changing the frozen command twice on speculation.

## Observed defect

All four reported runs used `{claude, local-code-standard}` with
`qwen36-27b` through `https://ai-gateway.homelab0.org` and kit revision
`e76cb95`:

| Story | Shape | Observed outcome |
| --- | --- | --- |
| FU.1 | four comment-line edits in two files | exited 0 after 42 minutes; incorrect whole-file rewrite; two of five gates failed |
| 4.4 | three documents plus four schemas | exited 1 after 30 minutes with `rapid_refill_breaker`; no files |
| 4.6 | one document plus two schemas | all files written; launch timed out at 5400 seconds; the session was still running and finished at 5,604,632 ms — corrected, see below |
| 4.4a | one document plus one schema | all files written; launch timed out at 5400 seconds; the session was still running and finished at 5,743,774 ms — corrected, see below |

For both timed-out runs, `<story>.md.claude-result.json` existed but was zero
bytes at the moment the dispatcher gave up. No `CLAUDE_EXIT` marker, thin
result, or gate rerun followed.
`dispatch.sh` correctly returned `DISPATCH_EXIT=2` rather than guessing.

> **Correction, 2026-09-09.** Rows 4.6 and 4.4a above are amended. As filed they
> read "all files written around 87 minutes; process never exited; launch timed
> out at 5400 seconds" and "all files written; process never exited; launch
> timed out at 5400 seconds". The "never exited" part is false: both processes
> ran to a normal end and wrote a `result/success` envelope into those same
> zero-byte files after the dispatcher had stopped waiting — 4.6 at 5,604,632 ms
> (142 turns), 4.4a at 5,743,774 ms (106 turns), 3m 24.6s and 5m 43.8s past the
> 5,400,000 ms bound. Evidence and digests:
> `evidence/AFK-SPIKE-LOCAL-CLAUDE-EXIT/LATE-ENVELOPES.md`. The refusal was
> still correct: at the moment it was made, no terminal event had been observed
> and the file was empty.

The earlier external report is separate. It established that
`--output-format json` exposes cumulative multi-turn usage rather than final
context occupancy. The approved follow-up from that report adds `Edit` to both
claude launch classes. Neither finding is a license to infer completion from
declared output files.

## Question

What exact condition keeps a successful gateway-backed `claude -p` session
from producing its result envelope and exiting, and what is the smallest
change that gives the launcher an observed, fail-closed terminal signal?

The primary hypothesis is that `--output-format json` waits for an event or
field the non-Anthropic endpoint does not provide. Test whether
`--output-format stream-json --verbose` terminates and exposes both a terminal
result event and final-call usage. Consider stdin redirection and the pinned
tool set only if output format does not explain the result.

## Live experiment protocol

Run on this host against the gateway-backed local profile. The gateway is
reachable and Claude Code is installed. Use the approved 1Password reference
for the gateway credential, resolve it only into the child process environment,
disable xtrace first, and never print or persist the value. Never set or export
`ANTHROPIC_API_KEY`.

Create every canary under
`_bmad-output/implementation-artifacts/evidence/AFK-SPIKE-LOCAL-CLAUDE-EXIT/sessions/`.
Use a tiny deterministic authoring prompt that writes one short declared file
inside its own cell directory and then reports completion. Keep the model,
effort, persona absence, permission mode, tool set, strict MCP setting, stdin,
gateway variables, placement, and prompt byte-identical between comparison
cells except for the one independent variable named by the cell.

Predeclare the matrix in `EXPERIMENT.md` before the first live run:

1. Current frozen shape: `--output-format json`, `< /dev/null`, and the current
   four-tool set. This is the baseline.
2. Same launch with only output changed to
   `--output-format stream-json --verbose`.
3. Only if cells 1–2 do not isolate the cause, test stdin behavior as one
   independent variable.
4. Only if still unresolved, test tool-set behavior as one independent
   variable. Do not add `Edit`; this spike must not pre-accept the queued
   contract change.

Maximum: four live cells, each with an outer 10-minute timeout. Stop early
when the causal condition is demonstrated by a controlled pair. A timeout is
evidence, not permission to infer success. Do not dispatch a kit story through
the known 5400-second path merely to reproduce the report.

For every cell retain a secret-free command shape, exact version/model and
served-model observations, start/end timestamps, outer-timeout result, process
exit status, stdout/stderr sizes and hashes, result-stream validity, tool-call
sequence, and declared-file state. Raw streams must be redacted before commit.
Never retain environment dumps, authorization headers, or credential values.

## Deliverables

All deliverables live under
`_bmad-output/implementation-artifacts/evidence/AFK-SPIKE-LOCAL-CLAUDE-EXIT/`:

1. `INDEX.md` — bundle index and concise verdict.
2. `EXPERIMENT.md` — predeclared matrix, controls, stop rule, and deviations.
3. `sessions/` — per-cell secret-free artifacts and summaries.
4. `FINDINGS.md` — supported cause, eliminated hypotheses, and what remains
   unknown. Explicitly distinguish “the model stopped generating” from “the
   CLI emitted a terminal envelope” and “the wrapper observed process exit.”
5. `FIX-SCOPE.md` — the smallest proposed implementation story, exact files
   and frozen contract surfaces expected to change, live acceptance test, and
   cross-repo amendment owed to ai-control-plane if applicable.

`FIX-SCOPE.md` must also answer:

- Does `stream-json` terminate where `json` does not?
- Does its last assistant/result event provide final-call context occupancy,
  thereby improving the earlier usage-adapter limitation?
- Can the launcher derive a thin result only from an observed terminal event
  and process status, without trusting output-file appearance?
- Should the approved `Edit` change be combined with the termination fix in
  one frozen-contract update, or remain separate?
- What output-shaped sizing guidance is justified by the four field reports,
  and what remains a separate hardening item rather than part of this fix?

## Acceptance criteria

- **AC-1:** At least one bounded current-shape live cell and its controlled
  comparison are retained, or an explicit environmental blocker is proven
  before any product recommendation is made.
- **AC-2:** Every live conclusion cites retained, secret-free evidence; every
  untested claim is labelled `NOT_TESTED`.
- **AC-3:** The result states the demonstrated cause at the narrowest supported
  level. Correlation is not reported as protocol causation.
- **AC-4:** The proposed fix preserves the existing fail-closed rule: no
  observed terminal signal means no thin result, no gates, and dispatch exit 2.
  File existence, declared-output completion, quiet time, and a non-empty
  redirect are never sufficient completion signals.
- **AC-5:** If `stream-json` is recommended, the evidence identifies the exact
  terminal event, exit semantics, parsing boundary, final-call usage members,
  malformed/truncated-stream behavior, and test fixture needed by the later
  implementation story.
- **AC-6:** No production code, test code, policy, catalog, registry, launch
  contract, installed kit, or ai-control-plane file changes. No metered spend.
- **AC-7:** The bundle is indexed, `git diff --check` passes, and committed
  artifacts contain no secrets or AI-attribution trailers.

## Hard stops

- Do not edit `files/`, `lib/`, `docs/`, `tests/`, the installed skill tree,
  catalog or subscription data.
- Do not soften the 5400-second refusal or synthesize completion from files.
- Do not add `Edit`, implement stream parsing, or update either repository's
  frozen contract in this spike.
- Do not expose credential values in terminal output, artifacts, command-line
  arguments, process listings, commits, or messages.
- If safe credential resolution or local placement cannot be established,
  record the blocker and stop without substituting a metered provider.

## Dev Agent Record

### Correction, 2026-09-09 (AFK-SPIKE-LOCAL-CLAUDE-EXIT-FIX-1)

The first pass was committed at `831564e` before the coordinator discovered
that the two field runs' zero-byte `<story>.md.claude-result.json` files had
since become complete `result/success` envelopes. This record is corrected in
place; the four-cell live result is unchanged and nothing about it is hidden.

**What changed.** The field sessions did not fail to exit. Story 4.6 finished
142 turns in 5,604,632 ms and story 4.4a 106 turns in 5,743,774 ms, each
writing a `result/success` envelope with `is_error: false` — 3m 24.6s and
5m 43.8s past the 5,400,000 ms dispatch bound. The narrow cause is a
workload/timeout mismatch: a 90-minute bound against 93- and 96-minute
sessions. Two things compounded it — `--output-format json` writes nothing
until the end, so the dispatcher had no progress signal and saw an empty file;
and the launched process survived the timeout, kept calling the gateway, and
wrote to a path the launcher had abandoned. `json` buffering is progress
blindness, not a termination cause, and `stream-json` is not a speed or exit
fix. When the last model event occurred relative to process exit is
`NOT_TESTED`.

**Where it is recorded.** `evidence/AFK-SPIKE-LOCAL-CLAUDE-EXIT/LATE-ENVELOPES.md`
holds the retained secret-free metadata and the source digests
(`03965bc7b687a4b0df5369528f40cc524c155e530bd042f3628bf35a23401898` and
`8993d1feeaa64d380b257f8c6b6518bbe5b4c40c1b7002a30e45bc63846f3635`). Correction
banners and marked passages are in `INDEX.md`, `FINDINGS.md` and `FIX-SCOPE.md`.
No ai-control-plane file was modified and no result prose, identifier, or
credential material was copied.

**Scope replaced.** `FIX-SCOPE.md`'s single narrow story plus a larger
reproduction spike is withdrawn — the reproduction spike is unnecessary — and
replaced by three ordered, independently testable queue items: the frozen
launch/adapter update (one coordinated `Edit` + `stream-json --verbose`
amendment owed to ai-control-plane), timeout fencing, then output-shaped
planning. The opencode spike follows all three.

**First-attempt deviation disclosed.** The first pass's editing-method rule was
not honoured: files in the `831564e` bundle were produced with shell
redirection and heredocs rather than `apply_patch`. This correction pass used
structured single-file patch edits only — no `sed -i`, heredocs, shell
redirection, or Python touched a repository file.

**Gate.** `git diff --check` — exit 0, no output.

### Correction, 2026-09-09 (AFK-SPIKE-LOCAL-CLAUDE-EXIT-FIX-2)

A fresh-session adversarial review
(`evidence/AFK-SPIKE-LOCAL-CLAUDE-EXIT-REVIEW/REVIEW.md`) returned
`NOT CLEAN — 3 blockers`. It found the field diagnosis, the four-cell result and
the fail-closed rule intact and recomputed every retained number successfully;
all three blockers sat in `FIX-SCOPE.md` item 1's specification of the work to
be queued. This pass corrects the specification. No recorded raw fact changed,
no live cell was rerun, and no product, catalog, registry, contract or test file
was touched.

**Blocker 1 — the assistant-event `usage` shape.** The spec said
`cache_creation_input_tokens` was observed as `null`. It is absent from all 28
assistant events in cell 4 and all 4 in cell 2, appearing only on the terminal
envelope. Absent and `null` take different branches in a parser, and the
prescribed fixture exercised only the shape never observed. Corrected: the
parser treats absent or explicit-null as zero, with fixtures for both and absent
as the primary case.

**Blocker 2 — the occupancy formula.** The spec prescribed
`input_tokens + cache_read_input_tokens + output_tokens`, reversing the
documented decision in the very function it directed the implementer to rewrite
(`dispatch.sh:842-845`), which excludes output tokens as context no next turn
carries. The evidence could not have caught it: `output_tokens` is `0` in every
observed assistant event, so 15,134 and 17,842 hold under either formula.
Corrected in `FIX-SCOPE.md` and `FINDINGS.md` to the shipped member set —
`input_tokens + cache_read_input_tokens + cache_creation_input_tokens` — with
the internal three-versus-four inconsistency resolved.

**Blocker 3 — the flipped `scope` and its downstream surface.** Reading per-call
usage makes a valid multi-turn stream `FINAL_CONTEXT` rather than
`CUMULATIVE_RUN`/`USAGE_CUMULATIVE_ONLY`, which is the switch deciding whether a
ratio is computed at all — so budget-band evaluation and PM readiness begin
running for runs currently withheld from them. Item 1 was sized as a parsing
change. Corrected: the budget-semantics effect is named, and
`tests/run-tests.sh:1766-1772` and `:1788-1800`,
`tests/lifecycle-readiness-tests.sh:1489-1490` and `:1520`, and
`lib/afk-commands.sh:526` are added to the expected surface, with acceptance
criteria for both the new `FINAL_CONTEXT` path and the unchanged
cumulative-envelope path.

**Also tightened.** The JSONL boundary now refuses any nonempty line that does
not parse (no skipping past a malformed line to a later valid result), and zero
or more than one terminal `result` event. A fixture covers repeated assistant
events for one model message, so an implementation that sums instead of
selecting the last is caught. The fixture list is seven.

**Advisory items incorporated.** The reversed turn/duration pairing is corrected
(142 turns / 93 minutes for 4.6; 106 turns / 96 minutes for 4.4a). `EXPERIMENT.md`
gains an appended correction pointer for its superseded 30-87 minute range, with
its predeclaration left unedited. This heading no longer asserts a non-exit.
`duration_ms − duration_api_ms` — 17,244 ms and 12,623 ms — is recorded as a
bound on in-harness idle that still does not date the last model event, so
final-event-to-exit timing stays `NOT_TESTED`. `INDEX.md` states that the
redaction filter was not retained, so redaction is not independently
reproducible from the bundle; no filter was invented after the fact. Item 3's
output-shape guidance is qualified as weak, qualitative evidence from two
successful long runs, with the aborted larger 4.4 run noted as non-comparable
and no numeric threshold introduced. Items 1 and 2 are stated to interact: a
fenced run leaves its partial JSONL in place as diagnostic evidence, but only
after the launcher-owned process is confirmed stopped, and it can never yield a
thin success result.

**Queue unchanged.** Still three independently testable items in the same order:
the combined `Edit` + stream observability / final-context usage amendment,
timeout fencing, then output-shaped planning.

**Gate.** `git diff --check` — exit 0, no output.

### Outcome

Four live cells, 337 seconds of gateway time against the 2400-second budget.
The primary hypothesis is NOT SUPPORTED: `--output-format json` terminated
cleanly in the frozen gateway shape at 2 turns (cell 1, 54s) and at 19 turns
(cell 3, 157s), each with a `result/success` envelope and exit 0, and no outer
timeout fired in any cell. Neither output format caused a failure. The reported
non-exit was NOT REPRODUCED in the canary — and, per the correction above, was
not a non-exit: both field sessions exited successfully after the dispatcher
timeout.

The collateral finding is solid: the terminal envelope's `usage` is cumulative
and reached 331,717 occupancy-member tokens against a 65,536-token window (cell 3), while
`stream-json`'s last `assistant` event exposes a real final-call occupancy —
17,842 of 65,536 (cell 4). That answers the earlier external report's usage
limitation, and the field envelopes confirm it at 34.8× and 21.5× the window.
Context exhaustion near the window and long-session transport behaviour remain
`NOT_TESTED`; neither is needed to explain the field reports any more.

### Evidence

`_bmad-output/implementation-artifacts/evidence/AFK-SPIKE-LOCAL-CLAUDE-EXIT/`
— `INDEX.md`, `EXPERIMENT.md`, `FINDINGS.md`, `FIX-SCOPE.md`,
`LATE-ENVELOPES.md`, `run-cell.sh`, and `sessions/cell-{1..4}/`.

| Cell | Output format | Turns | Elapsed | Exit | Terminal envelope | Files |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `json` (frozen) | 2 | 54s | 0 | `result/success` | 1 |
| 2 | `stream-json --verbose` | 2 | 13s | 0 | `result/success` | 1 |
| 3 | `json` (frozen) | 19 | 157s | 0 | `result/success` | 7 |
| 4 | `stream-json --verbose` | 14 | 113s | 0 | `result/success` | 7 |

### Deviation

Predeclared cells 3 and 4 (stdin, tool set) were retargeted to a controlled
output-format pair at a higher turn count, because cells 1-2 showed the format
hypothesis could not explain a non-exit the baseline never produced. Recorded
in `EXPERIMENT.md` Deviation 1. Stdin and tool set are `NOT_TESTED`.

### Acceptance criteria

- **AC-1** — met. Cell 1 is the bounded current-shape cell; cell 2 is its
  controlled comparison. Cells 3 and 4 are a second controlled pair.
- **AC-2** — met. Every conclusion cites a retained cell; open questions are
  labelled `NOT_TESTED` in `FINDINGS.md` and `FIX-SCOPE.md`.
- **AC-3** — met, and narrowed by the correction. The cell result is stated as
  "not a deterministic property of the tuple", not as a protocol cause. The
  field cause is now stated at its own narrowest level — a workload/timeout
  mismatch compounded by `json` buffering and by the process surviving the
  timeout — with `json` buffering named as progress blindness rather than a
  termination cause, and `stream-json` claimed as neither a speed nor an exit
  fix.
- **AC-4** — met. `FIX-SCOPE.md` requires a parsed terminal event AND an
  observed process exit, both, and keeps exit 2 otherwise. Cell 3 is retained
  precisely because its declared files existed before its envelope did.
- **AC-5** — met for the usage change: `FIX-SCOPE.md` names the terminal event,
  exit semantics, JSONL parsing boundary, final-call usage members, malformed
  and truncated stream behaviour, and seven fixtures. The usage members are
  `input_tokens`, `cache_read_input_tokens` and `cache_creation_input_tokens` —
  the adapter's existing set, with `output_tokens` excluded because it is not
  context the next turn carries. `cache_creation_input_tokens` is **absent**
  from every observed assistant-event `usage` object, not `null`; the parser
  treats absent or explicit-null as zero and both shapes have fixtures. The
  fixtures also cover repeated assistant events for one message, so a summing
  implementation is caught. Reading per-call usage makes a valid multi-turn
  stream `scope: FINAL_CONTEXT` rather than `CUMULATIVE_RUN`, which turns on
  budget-band evaluation and changes PM readiness reporting for those runs;
  `FIX-SCOPE.md` names that surface and asserts it. `stream-json` is NOT
  recommended as a
  termination fix, because no termination differential was observed and the
  field sessions terminated too. It is recommended for observability, combined
  with the approved `Edit` addition in one coordinated launch-contract
  amendment owed to ai-control-plane.
- **AC-6** — met. Nothing under `files/`, `lib/`, `docs/`, `tests/`, the
  installed kit, the catalog, or ai-control-plane was modified. No metered
  provider was used; `ANTHROPIC_API_KEY` was never set or exported.
- **AC-7** — met. The bundle is indexed, `git diff --check` produced no output
  and exit 0, and no committed artifact carries a secret or an AI-attribution
  trailer.

### Gate

`git diff --check` — exit 0, no output.

### Diff size

Evidence bundle plus this record. Generated session artifacts
(`stdout.redacted.jsonl`, `meta.json`, `placement-evidence.json`, `work/`) are
captured output, not authored code.
