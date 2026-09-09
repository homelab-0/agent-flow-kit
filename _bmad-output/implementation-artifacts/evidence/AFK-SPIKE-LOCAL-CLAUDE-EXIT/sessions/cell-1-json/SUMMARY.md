# Cell cell-1-json

Independent variable for this cell: `--output-format json`.

## Launch

Reproduces `build_claude_gateway_command` verbatim except that the persona
argument is absent in every cell (a held control) and the command is run under
an outer `timeout -k 10 600` instead of Orca's 5400-second launch. Command
shape is in `../../run-cell.sh`; the prompt is `prompt.txt`. The gateway
credential was resolved inside a command substitution with xtrace disabled and
appears in no argv, no file and no retained artifact.

| Field | Value |
| --- | --- |
| claude version | 2.1.266 (Claude Code) |
| requested model | qwen36-27b |
| served model (from the result envelope) | qwen36-27b |
| context window reported | 65536 |
| placement (verbatim `x-placement`) | cachyos-7900xtx |
| started (UTC) | 2026-09-09T01:52:49Z |
| ended (UTC) | 2026-09-09T01:53:43Z |
| elapsed | 54s |
| outer timeout | 600s |
| outer timeout fired | false |
| process exit status | 0 |
| stdout bytes / sha256 (raw, pre-redaction) | 1536 / cd7b5d03dfdf5af7f41fbbf501084874f61af342b18b57fa88d04d7c98fae277 |
| stderr bytes / sha256 (raw, pre-redaction) | 269 / 1b95d8519c36b423d9921f2104d3dca0e70fe42f48fdce8dffed2e2c284e94bf |
| stdout sha256 (redacted, committed) | b7cd89e9dd7e8ec0c37adc2802f0d0f37ba7fc7fd4bd7787c7ebf91b36dfd54b |
| stderr sha256 (redacted, committed) | 1b95d8519c36b423d9921f2104d3dca0e70fe42f48fdce8dffed2e2c284e94bf |
| declared files written | 1 |

## The three events, kept separate

1. The model stopped generating: yes.
2. The CLI emitted a terminal envelope: yes — `result/success`, `is_error: false`, `num_turns: 2`, result text `DONE`.
3. The wrapper observed process exit: yes, status 0; the outer timeout did not fire.

## Tool-call sequence

`(none observed in this output format)`

The `json` output format emits only the terminal envelope, so its tool-call
sequence is unobservable from retained stdout; that is a property of the
format, not of the session.

## Usage

Cumulative, from the terminal envelope: input 15007, output
127, cache-read 15039 — sum 30173 tokens
against a 65536-token window.

Final-call usage, from the last assistant event: NOT OBSERVABLE in this output format.

## Redaction

`stdout.redacted.jsonl` holds every assistant, user, and result event with
session and message identifiers replaced by `<redacted>`; per-token
`system/thinking_tokens` events are collapsed to their shape. No environment
dump, authorization header, or credential value was retained. `stderr.redacted.txt`
is the stderr verbatim; it contains two benign notices and no secrets.
