# FIX-SCOPE — the smallest implementation story this spike justifies

This spike did not reproduce the reported non-exit. The scope below is
therefore deliberately smaller than the spike was chartered to license: it
proposes the observability change the evidence does support, and it explicitly
refuses to propose a termination fix for a cause that has not been demonstrated.

## The five questions the story asks

### Does `stream-json` terminate where `json` does not?

No — because `json` terminated too. Cells 1 and 3 both produced a
`result/success` envelope and exit 0 under the frozen `--output-format json`
shape, at 2 and 19 turns. There is no observed case in this bundle of `json`
failing to terminate, so there is no differential to attribute to the format.
Any claim that `stream-json` fixes non-exit would be correlation reported as
protocol causation, which AC-3 forbids.

### Does its last assistant/result event provide final-call context occupancy?

Yes, and this is the one clearly supported improvement. In cells 2 and 4 the
final `assistant` event carries a per-call `usage` object; its
`input_tokens + cache_read_input_tokens + output_tokens` is 15,134 and 17,842
respectively, both inside the 65,536-token window. The terminal envelope's
`usage` for the same runs is cumulative across the session — 30,192 and 236,349
— and cell 3's is 333,985, five times the window. `stream-json` is the only
retained format in which a real occupancy number exists at all. This directly
answers the limitation the earlier external report raised.

### Can the launcher derive a thin result only from an observed terminal event and process status?

Yes, and it already can under `json`; `stream-json` does not weaken it. The
terminal condition is a parsed `{"type":"result"}` event AND an observed process
exit — both, never either. Absent both, the launcher writes no thin result, runs
no gates, and exits 2. Nothing in this bundle supports relaxing that: cell 3 had
all seven declared files on disk well before its envelope appeared, so file
existence would have been a false signal had that run hung.

### Should the approved `Edit` change be combined with the termination fix in one frozen-contract update?

They should stay separate, because there is no termination fix to combine with.
The `Edit` change is independently justified by the FU.1 whole-file-rewrite
report and should ship on its own. Bundling it with a speculative termination
change would put an unproven amendment inside an approved one.

### What output-shaped sizing guidance is justified by the four field reports?

Only this: the cumulative `usage` in the `json` envelope must never be read as
context occupancy, and any sizing rule that currently does is wrong by up to a
factor of five (cell 3). Everything else the field reports suggest about sizing
— that long sessions approach the 65,536-token window, that compaction near it
may be implicated in the hangs — is a separate hardening item. It is
`NOT_TESTED` here and must not enter a fix on the strength of this bundle.

## Proposed story A — adopt `stream-json` for the usage adapter only

Smallest change that the evidence supports.

**Intent.** Make final-call context occupancy observable, without changing what
the launcher treats as completion.

**Files expected to change.**

- `files/model-router/scripts/dispatch.sh` — `build_claude_gateway_command` and
  `build_claude_command` (the `--output-format` argument and the added
  `--verbose`); `usage_adapter_claude` (parse the last `assistant` event's
  per-call `usage` instead of summing the envelope); the result-file reader
  around `WORKER_TEXT` (read `.result` from the terminal event of a JSONL
  stream rather than a single object).
- `tests/` — new fixtures for the parsing boundary.

**Frozen contract surfaces affected.** The claude launch contract's output
argument, in both launch classes. This is a real contract amendment and owes
ai-control-plane a cross-repo note recording that both classes changed together
and why, so the two repositories do not drift on the launch shape.

**Live acceptance test.** Rerun cells 1-4 of this bundle's `run-cell.sh` under
the amended command and require, for every cell: a parsed terminal `result`
event, an observed process exit, and a final-call occupancy figure at or below
the declared window. A run producing files but no terminal event must still
yield exit 2.

**Parsing boundary the implementation must handle**, per AC-5:

- The terminal event is the single line where `.type == "result"`; its
  `.subtype` is `success` or an error subtype, and `.is_error` is the
  authoritative failure flag. `.result` carries the worker text.
- The stream is JSONL: one JSON object per line, in the observed order
  `system/hook_*`, `system/init`, many `system/thinking_tokens`, then
  interleaved `assistant` and `user` events, then exactly one `result`. Cell 4
  retained 258 events; 216 of them were `system`. The parser must tolerate
  volume and must not assume the result is the last line.
- Final-call usage members: `input_tokens`, `cache_read_input_tokens`,
  `cache_creation_input_tokens` (observed `null` here — must be treated as 0,
  not as absent-and-fatal), `output_tokens`, on the last `assistant` event
  carrying a `usage` object. The window comes from
  `.modelUsage["<model>"].contextWindow` on the result event (65,536 observed).
- Malformed or truncated stream: a line that does not parse is skipped, but a
  stream with **no** parseable `result` event is a launch that did not complete.
  It must produce no thin result, no gates, and exit 2 — identical to the
  current zero-byte-file behaviour. Truncation must never be read as success.
- Fixtures needed: a complete stream with a `result/success`; a stream with a
  result carrying `is_error: true`; a stream truncated mid-event with no result;
  a stream with an unparseable line before an otherwise valid result; a stream
  whose last assistant event has `cache_creation_input_tokens: null`.

## Deliberately out of scope

- Any change presented as fixing non-exit. `NOT_TESTED`; see FINDINGS.md.
- Adding `Edit` — ships separately as already approved.
- Softening the 5400-second refusal or inferring completion from declared files.
- Compaction and long-session transport hardening, which needs its own spike
  with a budget that can actually reach the 65,536-token window.

## Follow-up spike this one could not do

A bounded long-session probe that drives occupancy to the window and past a
compaction, and a transport probe holding a gateway stream idle for tens of
minutes. Either would need a budget well beyond four ten-minute cells, and
neither should be folded into an implementation story.
