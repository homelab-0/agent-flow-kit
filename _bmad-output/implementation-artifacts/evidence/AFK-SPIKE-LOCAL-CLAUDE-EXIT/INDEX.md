# AFK-SPIKE-LOCAL-CLAUDE-EXIT — evidence bundle

Bounded live diagnosis of gateway-backed `claude -p` sessions reported to finish
their work and outrun their launch bound. Four live cells, 337 seconds of
gateway time against a 2400-second budget, run 2026-09-09 on devbox against
`https://ai-gateway.homelab0.org`, model `qwen36-27b`, placement
`cachyos-7900xtx`, Claude Code 2.1.266.

> **Correction, 2026-09-09.** This bundle was first written and committed at
> `831564e` while the two field runs' `<story>.md.claude-result.json` files were
> believed to be permanently zero bytes. They are not: both later became
> complete `result/success` envelopes. The verdict, `FINDINGS.md`, `FIX-SCOPE.md`
> and the parent story's record are corrected below and cite
> `LATE-ENVELOPES.md` (sources sha256 `03965bc7…` and `8993d1fe…`). The
> four-cell live result is unchanged; only the reading of the field runs is.

## Verdict

**The field sessions did not fail to exit.** Both reported non-exiting runs ran
to a normal end and wrote a `result/success` envelope after the dispatcher had
stopped waiting: story 4.6 at 5,604,632 ms (142 turns), 3m 24.6s past the
5,400,000 ms bound, and story 4.4a at 5,743,774 ms (106 turns), 5m 43.8s past
it (`LATE-ENVELOPES.md`). The defect is a workload/timeout mismatch — a
90-minute bound against 93- and 96-minute sessions — compounded by two things:
`--output-format json` emits nothing until the end, so the dispatcher had no
progress signal and saw only a zero-byte file; and the launched process
survived the timeout, kept calling the gateway, and wrote to that file after
dispatch had already returned 2.

The output-format hypothesis is **still not supported** as a termination cause,
and the four live cells stand exactly as run. `--output-format json` terminated
cleanly at 2 turns (cell 1, 54s) and at 19 turns (cell 3, 157s), with a
`result/success` envelope and exit 0 each time, so neither format caused a
failure. `json`'s cost is progress blindness, not termination.

One collateral finding is solid and useful: the terminal envelope's `usage` is
cumulative across the session and reached 333,985 tokens against a
65,536-token window (cell 3), while `stream-json`'s last `assistant` event
carries a real final-call occupancy — 17,842 of 65,536 in cell 4. That answers
the earlier external report's usage limitation.

Context exhaustion and compaction near the window, and long-session transport
behaviour, remain untested. They are no longer needed to explain the field
reports — the late envelopes do that — and both stay `NOT_TESTED`; neither may
be used to justify a change.

The fail-closed rule stands unchanged: no observed terminal event and process
exit means no thin result, no gates, dispatch exit 2. Cell 3 had all seven
declared files on disk before its envelope appeared, which is exactly why file
existence is never a completion signal — and the two late field envelopes make
the same point from the other side, since at the moment the dispatcher gave up
the file on disk was still zero bytes. Returning exit 2 was correct in both
runs and stays correct.

## Contents

| Path | What it holds |
| --- | --- |
| `EXPERIMENT.md` | The matrix predeclared before the first live run, the held controls, the stop rule, and Deviation 1 (cells 3-4 retargeted). |
| `LATE-ENVELOPES.md` | Retained secret-free metadata for the two field result envelopes that arrived after the dispatch timeout, with their source digests and what does and does not follow from them. |
| `FINDINGS.md` | Supported conclusion, eliminated hypotheses, and every open question labelled `NOT_TESTED`. |
| `FIX-SCOPE.md` | The smallest implementation story the evidence supports, with the parsing boundary, usage members, malformed-stream behaviour, and fixtures the later story needs. |
| `run-cell.sh` | The canary runner. Reproduces `build_claude_gateway_command` directly under a 10-minute outer timeout; runs no kit dispatch and edits nothing the kit owns. |
| `sessions/cell-1-json/` | Baseline: frozen `--output-format json`, tiny prompt. |
| `sessions/cell-2-stream-json/` | `--output-format stream-json --verbose`, otherwise identical to cell 1. |
| `sessions/cell-3-json-multiturn/` | Frozen `json`, multi-turn prompt. |
| `sessions/cell-4-stream-json-multiturn/` | `stream-json --verbose`, same multi-turn prompt as cell 3. |

Each cell directory holds `SUMMARY.md` (the readable record), `meta.json`
(machine-readable observations), `prompt.txt`, `placement-evidence.json`,
`versions.txt`, `stdout.redacted.jsonl`, `stderr.redacted.txt`, and `work/`
(the files the session actually wrote).

## Results at a glance

| Cell | Output format | Turns | Elapsed | Exit | Terminal envelope | Files written | Final-call occupancy |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `json` | 2 | 54s | 0 | `result/success` | 1 | not observable |
| 2 | `stream-json --verbose` | 2 | 13s | 0 | `result/success` | 1 | 15,134 / 65,536 |
| 3 | `json` | 19 | 157s | 0 | `result/success` | 7 | not observable |
| 4 | `stream-json --verbose` | 14 | 113s | 0 | `result/success` | 7 | 17,842 / 65,536 |

No outer timeout fired in any cell.

## Secret handling

The gateway credential was resolved from `op://develop/agw-claude-code/password`
inside a command substitution with xtrace disabled, into the child process only.
`ANTHROPIC_API_KEY` was never set or exported. No credential value, authorization
header, or environment dump appears in any retained artifact. Raw stdout/stderr
were redacted before commit — session and message identifiers replaced,
per-token `system` events collapsed — and the pre-redaction byte sizes and
sha256 of every stream are recorded in each cell's `meta.json` and `SUMMARY.md`.
