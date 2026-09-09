---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-SPIKE-LOCAL-CLAUDE-EXIT.md.stamp.json
persona: dev
gates:
  - "git diff --check"
max_cycles: 1
---

# AFK-SPIKE-LOCAL-CLAUDE-EXIT: Diagnose successful gateway sessions that never exit

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
| 4.6 | one document plus two schemas | all files written around 87 minutes; process never exited; launch timed out at 5400 seconds |
| 4.4a | one document plus one schema | all files written; process never exited; launch timed out at 5400 seconds |

For both non-exiting runs, `<story>.md.claude-result.json` existed but was
zero bytes. No `CLAUDE_EXIT` marker, thin result, or gate rerun followed.
`dispatch.sh` correctly returned `DISPATCH_EXIT=2` rather than guessing.

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

### Outcome

Four live cells, 337 seconds of gateway time against the 2400-second budget.
The primary hypothesis is NOT SUPPORTED and the reported non-exit was NOT
REPRODUCED. `--output-format json` terminated cleanly in the frozen gateway
shape at 2 turns (cell 1, 54s) and at 19 turns (cell 3, 157s), each with a
`result/success` envelope and exit 0. No outer timeout fired in any cell.

The collateral finding is solid: the terminal envelope's `usage` is cumulative
and reached 333,985 tokens against a 65,536-token window (cell 3), while
`stream-json`'s last `assistant` event exposes a real final-call occupancy —
17,842 of 65,536 (cell 4). That answers the earlier external report's usage
limitation. By elimination, context exhaustion near the window and long-session
transport behaviour survive as hypotheses; both are `NOT_TESTED`.

### Evidence

`_bmad-output/implementation-artifacts/evidence/AFK-SPIKE-LOCAL-CLAUDE-EXIT/`
— `INDEX.md`, `EXPERIMENT.md`, `FINDINGS.md`, `FIX-SCOPE.md`, `run-cell.sh`,
and `sessions/cell-{1..4}/`.

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
- **AC-3** — met. The result is stated as "not a deterministic property of the
  tuple", not as a protocol cause, and the non-reproduction is reported as a
  negative result rather than an acquittal.
- **AC-4** — met. `FIX-SCOPE.md` requires a parsed terminal event AND an
  observed process exit, both, and keeps exit 2 otherwise. Cell 3 is retained
  precisely because its declared files existed before its envelope did.
- **AC-5** — met for the usage change: `FIX-SCOPE.md` names the terminal event,
  exit semantics, JSONL parsing boundary, final-call usage members (including
  `cache_creation_input_tokens: null`), malformed and truncated stream
  behaviour, and five fixtures. `stream-json` is NOT recommended as a
  termination fix, because no termination differential was observed.
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
