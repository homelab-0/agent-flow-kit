# FIX-SCOPE — the implementation queue this spike justifies

> **Correction, 2026-09-09.** The original version of this file was written at
> `831564e` on the belief that the field runs never terminated and that their
> cause was undemonstrated. Both premises were wrong: the two runs produced
> `result/success` envelopes 3m 24.6s and 5m 43.8s after the dispatcher stopped
> waiting (`LATE-ENVELOPES.md`, sources sha256 `03965bc7…` and `8993d1fe…`).
> It originally proposed one narrow story plus a larger reproduction spike; the
> reproduction spike is withdrawn as unnecessary and the scope is replaced by
> the three ordered queue items below. Every earlier answer that changed is
> marked **Corrected**. The four-cell live result is unchanged.

The four live cells still did not reproduce a non-exit, because there was no
non-exit to reproduce. What they did establish stands: neither output format
caused a failure, and `stream-json` exposes incremental events plus a real
final-call usage figure that `json` does not.

## The five questions the story asks

### Does `stream-json` terminate where `json` does not?

No — because `json` terminated too, in the cells and in the field. Cells 1 and
3 both produced a `result/success` envelope and exit 0 under the frozen
`--output-format json` shape, at 2 and 19 turns, and both field runs did the
same at 106 and 142 turns. There is no observed case anywhere in this bundle of
`json` failing to terminate, so there is no differential to attribute to the
format. Any claim that `stream-json` fixes non-exit, or shortens a session,
would be correlation reported as protocol causation, which AC-3 forbids.

What `json` does cost is **progress blindness**: it writes nothing to the
redirect target until the end, so a 90-minute session is indistinguishable from
a hung one for 90 minutes. That is an observability defect, and it is the one
`stream-json` fixes.

### Does its last assistant/result event provide final-call context occupancy?

Yes, and this is the clearest supported improvement. In cells 2 and 4 the final
`assistant` event carries a per-call `usage` object; its
`input_tokens + cache_read_input_tokens + output_tokens` is 15,134 and 17,842
respectively, both inside the 65,536-token window. The terminal envelope's
`usage` for the same runs is cumulative across the session — 30,192 and 236,349
— and cell 3's is 333,985, five times the window. The field envelopes are worse
still: 2,301,235 and 1,433,412, or 35× and 22× the window. `stream-json` is the
only retained format in which a real occupancy number exists at all. This
directly answers the limitation the earlier external report raised.

### Can the launcher derive a thin result only from an observed terminal event and process status?

Yes, and it already can under `json`; `stream-json` does not weaken it. The
terminal condition is a parsed `{"type":"result"}` event AND an observed process
exit — both, never either. Absent both, the launcher writes no thin result, runs
no gates, and exits 2. Nothing in this bundle supports relaxing that. Cell 3 had
all seven declared files on disk well before its envelope appeared, so file
existence would have been a false signal had that run hung; and in the field the
redirect target was zero bytes at the moment of refusal, so the refusal was
right on the evidence it had. A file that fills in later is not a completion
signal the launcher missed — it is a process the launcher failed to fence.

### Should the approved `Edit` change be combined with the termination fix in one frozen-contract update?

**Corrected — yes, combine them.** The original answer was "keep them separate,
because there is no termination fix to combine with." There still is no
termination fix, but there is now a justified observability amendment to the
same two launch classes, and shipping it separately would mean amending the
frozen claude launch contract twice within one queue — exactly what the parent
spike was chartered to avoid. `Edit` and `--output-format stream-json --verbose`
go into one coordinated command-text amendment, negotiated once with
ai-control-plane.

### What output-shaped sizing guidance is justified by the four field reports?

**Corrected and narrowed.** Two things, no more.

First, the cumulative `usage` in the `json` envelope must never be read as
context occupancy; any sizing rule that does is wrong by 5× in the canary and
by 22–35× in the field.

Second, deliverable shape predicts turn volume, and turn volume is what ran the
field sessions past their bound: 142 turns for one document plus two schemas,
106 for one document plus one schema. That supports planner guidance about
expected deliverables — and specifically about avoiding large multi-document
local stories — expressed as route metadata. It does **not** support a universal
numeric output-token threshold; nothing here measures one. The input-byte
budget keeps the meaning it already has.

Compaction near the window and long-session transport behaviour remain
`NOT_TESTED` and must not enter any fix on the strength of this bundle.

## Implementation queue

Three items, independently testable, in this order. The opencode spike follows
all three; these are the urgent ones.

### 1. Frozen launch/adapter update — one coordinated amendment

**Intent.** Make sessions observable while running and make final-call occupancy
readable, without changing what the launcher treats as completion. This does not
make long sessions finish sooner and must not be described as if it did.

**Change.** In both claude launch classes, combine the already approved `Edit`
addition with `--output-format stream-json --verbose`, and:

- parse exactly one terminal `result` event, fail-closed;
- use the last assistant event carrying a `usage` object for final-call
  occupancy;
- keep malformed/truncated-stream and no-result refusal behaviour.

**Files expected to change.**

- `files/model-router/scripts/dispatch.sh` — `build_claude_gateway_command` and
  `build_claude_command` (the `--output-format` argument, the added `--verbose`,
  the added `Edit` tool); `usage_adapter_claude` (parse the last `assistant`
  event's per-call `usage` instead of summing the envelope); the result-file
  reader around `WORKER_TEXT` (read `.result` from the terminal event of a JSONL
  stream rather than a single object).
- `tests/` — new fixtures for the parsing boundary.

**Frozen contract surfaces affected.** The claude launch contract's output
argument and tool set, in both launch classes. This is a real contract
amendment and owes ai-control-plane a cross-repo note recording the exact
amended launch text, that both classes changed together, and why — one
negotiation, not two, so the repositories do not drift on the launch shape.
The amendment does not ship until that text is agreed on both sides.

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
- Two or more `result` events is a malformed stream, not a choice to make.

**Fixtures.** A complete stream with a `result/success`; a stream with a result
carrying `is_error: true`; a stream truncated mid-event with no result; a stream
with an unparseable line before an otherwise valid result; a stream whose last
assistant event has `cache_creation_input_tokens: null`.

**Acceptance test.** Rerun cells 1–4 of this bundle's `run-cell.sh` under the
amended command and require, for every cell: a parsed terminal `result` event,
an observed process exit, and a final-call occupancy figure at or below the
declared window. A run producing files but no terminal event must still yield
exit 2.

### 2. Timeout fencing

**Intent.** When a launch times out, nothing of that launch may survive the
refusal. The field runs prove the current gap: after `dispatch.sh` returned
exit 2 at 5,400,000 ms, both processes kept running, kept calling the gateway,
and wrote a result envelope minutes later into a file the launcher had
abandoned. A subsequent reader — human or tool — finds a `result/success` on
disk for a run that was recorded as failed.

**Change.** On launch timeout, stop and fence the exact launcher-owned
terminal/process before returning dispatch exit 2, then prove no late process,
envelope, or post-timeout write survives.

**Bounds that do not move.** Never remove a worktree. Never infer success from
anything found after a timeout. Keep the refusal wording as it is — this item
changes cleanup, not the verdict.

**Acceptance test.** A launch driven past its bound leaves no live descendant
process attributable to the launcher, and the result path's content and mtime
are unchanged when re-examined after the harness would otherwise have finished.

### 3. Output-shaped planning

**Intent.** Let the planner see that deliverable shape predicts turn volume, so
a story is not routed into a bound it cannot finish inside.

**Change.** Planner guidance and route metadata keyed on expected deliverables
and likely turn volume. The field data is the anchor: 142 turns and 93 minutes
for one document plus two schemas, 106 turns and 96 minutes for one document
plus one schema. The supported guidance is to avoid large multi-document local
stories.

**Bounds.** This does not change the input-byte budget's meaning, and it
introduces no universal numeric output-token threshold — the evidence does not
support one yet.

**Acceptance test.** A story with a multi-document deliverable set is flagged at
planning time, and the flag cites deliverable count and expected turn volume
rather than an output-token number.

## Sequencing

1. **Frozen launch/adapter update** — first, because it is a contract amendment
   that must be negotiated with ai-control-plane once, and because it is what
   makes a running session observable at all.
2. **Timeout fencing** — second. It is independent of the launch text, and it
   closes the live correctness gap the late envelopes exposed.
3. **Output-shaped planning** — third. It reduces how often the bound is
   reached; it is not a correctness fix.

The opencode spike follows these three.

## Deliberately out of scope

- Any change presented as fixing non-exit, or as making long sessions finish
  sooner. There is no non-exit; the sessions finished.
- Raising, lowering, or softening the 5400-second bound in this queue. Item 3
  reduces the demand on it; changing the number is a separate decision with its
  own evidence.
- Inferring completion from declared files, quiet time, or a non-empty redirect.
- Compaction and long-session transport hardening. Both are `NOT_TESTED` and
  neither is needed to explain the field reports.
