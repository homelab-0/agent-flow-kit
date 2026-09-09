# FINDINGS — AFK-SPIKE-LOCAL-CLAUDE-EXIT

Four live cells, 337 seconds of live gateway time against a 2400-second budget.
Every claim below cites a retained cell. Untested claims are labelled
`NOT_TESTED`.

## The three events, never conflated

Throughout this document:

- **stopped generating** — the endpoint returned its last token;
- **terminal envelope** — the CLI wrote a parseable terminal record to stdout;
- **observed exit** — the wrapper saw the process exit inside its outer bound.

The field reports describe runs where the first happened, the second did not,
and the third never came. That distinction is the whole subject.

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
negative result about the canary, not an acquittal of the field runs. It means
the cause lies in a dimension this canary did not reach, and the spike's
product recommendation must not rest on the output-format hypothesis.

## Hypotheses eliminated

- *`--output-format json` never terminates against a non-Anthropic endpoint.*
  Eliminated by cells 1 and 3.
- *The result file is zero bytes because the CLI writes nothing until an event
  the gateway withholds.* Eliminated: in cells 1 and 3 the redirect target held
  a complete, parseable envelope.
- *Multi-turn tool loops through the gateway cannot terminate.* Eliminated by
  cell 3 (19 turns) and cell 4 (14 turns).

## Hypotheses that survive — all `NOT_TESTED`

The four field runs ran 30, 42, 87 and >90 minutes. The longest cell here ran
157 seconds and peaked at roughly 17,800 tokens of final-call occupancy against
the 65,536-token window (cell 4). The canary therefore never approached the
conditions the field runs spent most of their time in. What remains open:

- **Context exhaustion and compaction near 65,536 tokens** `NOT_TESTED`. This
  is now the leading hypothesis by elimination and by the shape of the field
  data: every failing run was long enough to compact, none of the cells was.
- **Long-session transport behaviour** `NOT_TESTED` — gateway or proxy idle
  timeouts, keepalive expiry, or a half-open connection at tens of minutes,
  after which the CLI waits forever on a stream that will never resume.
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
`input_tokens + cache_read_input_tokens + output_tokens` is a real occupancy
figure inside the window. `stream-json` is the only retained format in which
that number is observable at all.

Note that cells 3 and 4 ran the identical prompt and reached different turn
counts (19 vs 14). The model is not deterministic at this temperature, so
per-cell turn counts are observations, not constants.

## What this means for the fail-closed rule

Nothing here justifies weakening it. All seven declared files existed in cell 3
well before the envelope appeared; had that run hung, file existence would have
been a false completion signal. `dispatch.sh` returning `DISPATCH_EXIT=2` on the
two field hangs was correct behaviour and remains correct.
