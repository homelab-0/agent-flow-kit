# FINDINGS — AFK-SPIKE-LOCAL-CLAUDE-EXIT

Four live cells, 337 seconds of live gateway time against a 2400-second budget.
Every claim below cites a retained cell. Untested claims are labelled
`NOT_TESTED`.

> **Correction, 2026-09-09.** Written first at `831564e` on the belief that the
> two field runs never produced a terminal envelope. Both did, after the
> dispatcher stopped waiting; see `LATE-ENVELOPES.md` (sources sha256
> `03965bc7…` and `8993d1fe…`). Corrected statements are marked below. Nothing
> about the four live cells changes.

## The three events, never conflated

Throughout this document:

- **stopped generating** — the endpoint returned its last token;
- **terminal envelope** — the CLI wrote a parseable terminal record to stdout;
- **observed exit** — the wrapper saw the process exit inside its outer bound.

**Corrected.** This document originally said the field reports describe runs
where the first happened, the second did not, and the third never came. That
was wrong about the second and third. In both timed-out field runs the CLI
did write a parseable terminal envelope and the process did exit — just after
the dispatcher had stopped observing. What the dispatcher lacked was not a
terminal event but the patience and the progress signal to see it
(`LATE-ENVELOPES.md`).

The three-way distinction still matters, because the third event is *observed*
exit: an exit the wrapper is no longer watching for is, to the wrapper,
indistinguishable from no exit at all. Whether the first event preceded the
second by minutes or milliseconds in those runs is `NOT_TESTED` — the envelope
carries totals, not a timeline.

## What the cells did

| Cell | Output format | Prompt | Turns | Elapsed | Exit | Terminal envelope | Declared files |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `json` (frozen shape) | tiny, 1 file | 2 | 54s | 0 | `result/success` | 1 |
| 2 | `stream-json --verbose` | tiny, 1 file | 2 | 13s | 0 | `result/success` | 1 |
| 3 | `json` (frozen shape) | multi-turn, 7 files | 19 | 157s | 0 | `result/success` | 7 |
| 4 | `stream-json --verbose` | multi-turn, 7 files | 14 | 113s | 0 | `result/success` | 7 |

No outer timeout fired in any cell. Every cell produced all three events.

## Supported conclusion

**The primary hypothesis is not supported.** `--output-format json` does not
wait for an event or field the gateway endpoint fails to provide — not at 2
turns (cell 1) and not at 19 turns (cell 3). Under the frozen gateway launch
shape, held byte-identical except for the output format, `json` terminated
exactly as `stream-json` did.

**Stated at the narrowest level the evidence supports:** non-termination is not
a deterministic property of the tuple {`--output-format json`, this gateway,
`qwen36-27b`, the four-tool set, `< /dev/null`, `acceptEdits`,
`--strict-mcp-config`, `CLAUDE_CODE_MAX_CONTEXT_TOKENS=65536`}. A session using
that exact tuple can and does emit its result envelope and exit.

**The reported defect was not reproduced** inside the bounded budget. That is a
negative result about the canary, and the spike's product recommendation must
not rest on the output-format hypothesis.

## The field cause, from the late envelopes

**Corrected.** This section replaces the original claim that the cause "lies in
a dimension this canary did not reach". It does not; the late envelopes name it.

Both field runs reported as never exiting produced a complete
`{"type":"result","subtype":"success","is_error":false}` envelope and ran to a
normal end (`LATE-ENVELOPES.md`, sources sha256 `03965bc7…` and `8993d1fe…`):

| Run | Turns | `duration_ms` | Overrun past the 5,400,000 ms bound |
| --- | --- | --- | --- |
| 4.6 | 142 | 5,604,632 (93m 24.6s) | 204,632 ms — 3m 24.6s |
| 4.4a | 106 | 5,743,774 (95m 43.8s) | 343,774 ms — 5m 43.8s |

Stated at the narrowest level the evidence supports, the cause is a
**workload/timeout mismatch**: a 90-minute launch bound against sessions that
needed 142 turns and 93 minutes (4.6) and 106 turns and 96 minutes (4.4a) to
finish their declared work. Two things compounded it.

- **`json` buffering is progress blindness, not the termination cause.** Under
  `--output-format json` nothing reaches the redirect target until the end, so
  for 90 minutes the dispatcher saw a zero-byte file and could not tell a
  working session from a hung one. The envelope did arrive. Cells 1 and 3
  independently show `json` terminating. No claim that `stream-json` would have
  made either run finish sooner, or exit where it otherwise would not, is
  supported by anything in this bundle.
- **The launched process survived the dispatch timeout.** After `dispatch.sh`
  returned exit 2 at 5,400,000 ms, the process kept running, kept calling the
  gateway, and later wrote to a path the launcher had already abandoned.
  `duration_api_ms` is 99.7% and 99.8% of `duration_ms`, so that time was spent
  in model and tool round-trips, not idling.

One bound is worth stating, because it sharpens the `NOT_TESTED` label rather
than weakening it: `duration_ms − duration_api_ms` is 17,244 ms for 4.6 and
12,623 ms for 4.4a, so within each harness's own measured lifetime there was at
most ~17 s and ~13 s of non-API time in total. That is evidence against "the
model stopped generating long before the process exited". It still does not
timestamp the last model event against process exit — the envelope carries
totals, not a timeline, and it measures only the harness's own lifetime — so
final-event-to-exit timing remains `NOT_TESTED`.

What this does **not** establish: when the last model event occurred relative
to process exit (`NOT_TESTED`); that any smaller bound would have sufficed; or
that these runs share a cause with FU.1's whole-file rewrites.

## Hypotheses eliminated

- *`--output-format json` never terminates against a non-Anthropic endpoint.*
  Eliminated by cells 1 and 3.
- *The result file is zero bytes because the CLI writes nothing until an event
  the gateway withholds.* Eliminated: in cells 1 and 3 the redirect target held
  a complete, parseable envelope. The field files were zero bytes for a simpler
  reason — `json` buffers everything to the end, and the dispatcher looked
  before the end. Both later filled in (`LATE-ENVELOPES.md`).
- *The field sessions stopped generating without ever producing a terminal
  envelope, or never exited.* Eliminated by the two late envelopes: both are
  `result/success` with `is_error: false`, and both processes ran to completion.
- *Multi-turn tool loops through the gateway cannot terminate.* Eliminated by
  cell 3 (19 turns) and cell 4 (14 turns).

## Hypotheses that survive — all `NOT_TESTED`

**Corrected.** These were originally framed as the surviving explanations for
the field reports, reached by elimination. They are not needed for that any
more — the late envelopes explain the reports — so nothing below is a leading
hypothesis. Each remains an untested property of long gateway sessions, worth
knowing and still forbidden as justification for any change.

The four field runs ran 30, 42, 93 and 96 minutes. The longest cell here ran
157 seconds and peaked at roughly 17,800 tokens of final-call occupancy against
the 65,536-token window (cell 4). The canary therefore never approached the
conditions the field runs spent most of their time in. What remains open:

- **Context exhaustion and compaction near 65,536 tokens** `NOT_TESTED`. Every
  field run was long enough to compact and none of the cells was, so the
  behaviour is unobserved here. It is no longer implicated in the non-exit
  reports, which have a demonstrated cause.
- **Long-session transport behaviour** `NOT_TESTED` — gateway or proxy idle
  timeouts, keepalive expiry, or a half-open connection at tens of minutes.
  Both field runs sustained a session past 90 minutes and finished, which is
  evidence against a hard transport ceiling at that scale but not a test of one.
- **`rapid_refill_breaker`** `NOT_TESTED`. Story 4.4 exited 1 with it; nothing
  here exercised it.
- **stdin redirection** `NOT_TESTED`. Predeclared cell 3 was retargeted; see
  EXPERIMENT.md Deviation 1.
- **Tool-set composition** `NOT_TESTED`. Predeclared cell 4 was retargeted.
  `Edit` was deliberately not added.
- **Whether the field runs' whole-file-rewrite behaviour (FU.1) shares a cause
  with non-exit** `NOT_TESTED`.

## A confirmed collateral finding: cumulative vs final-call usage

The earlier external report's usage limitation reproduces exactly, and
`stream-json` resolves it.

The terminal envelope's `usage` is **cumulative across all calls in the
session**, and at multi-turn scale it exceeds the context window outright:

| Cell | Envelope cumulative sum | Window | Final-call occupancy from the last assistant event |
| --- | --- | --- | --- |
| 1 | 30,173 | 65,536 | not observable in `json` |
| 2 | 30,192 | 65,536 | 15,134 |
| 3 | 333,985 | 65,536 | not observable in `json` |
| 4 | 236,349 | 65,536 | 17,842 |

Cell 3's cumulative sum is five times the window. Read as occupancy it is
nonsense; that is the defect the earlier report named. In cells 2 and 4 the
last `assistant` event carries a per-call `usage` object whose
`input_tokens + cache_read_input_tokens + cache_creation_input_tokens` is a real
occupancy figure inside the window. `stream-json` is the only retained format in
which that number is observable at all.

**Corrected, post-review.** This sentence previously summed `output_tokens` in
place of `cache_creation_input_tokens`. The member set above is the one
`usage_adapter_claude` already uses, and output tokens stay excluded because
they are not context the next turn carries. The figures do not move: every
assistant event in both stream cells reports `output_tokens: 0`, so 15,134 and
17,842 hold either way — which is exactly why the observation could not settle
the question and why the member set is not this bundle's to redecide. Note also
that `cache_creation_input_tokens` is **absent** from those assistant-event
`usage` objects, not present as `null`; it appears only on the terminal
envelope. An absent optional member reads as zero.

The two field envelopes confirm this at field scale, and far more starkly. Read
as occupancy, story 4.6's envelope `usage` sums to 2,301,235 and story 4.4a's to
1,433,412 — 35× and 22× the 65,536-token window each envelope itself declares in
`modelUsage["qwen36-27b"].contextWindow` (`LATE-ENVELOPES.md`). Cell 3's 5× was
the mild case.

Note that cells 3 and 4 ran the identical prompt and reached different turn
counts (19 vs 14). The model is not deterministic at this temperature, so
per-cell turn counts are observations, not constants.

## What this means for the fail-closed rule

Nothing here justifies weakening it. All seven declared files existed in cell 3
well before the envelope appeared; had that run hung, file existence would have
been a false completion signal. `dispatch.sh` returning `DISPATCH_EXIT=2` on the
two timed-out field runs was correct behaviour and remains correct: at the
moment it decided, no terminal event had been observed and the redirect target
was zero bytes. That the envelope arrived minutes later does not retroactively
make silence a completion signal — it makes the *bound* the thing that was
wrong, which is what the queue in `FIX-SCOPE.md` addresses.

It does surface a second problem the original bundle could not see: the
abandoned process outlived the refusal and kept writing. A launcher that has
declared a run failed must leave nothing behind that a later reader could
mistake for a result. That is the timeout-fencing item.
