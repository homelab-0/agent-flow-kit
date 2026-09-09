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

> **Second correction, 2026-09-09 (post-review).** The fresh-session adversarial
> review (`evidence/AFK-SPIKE-LOCAL-CLAUDE-EXIT-REVIEW/REVIEW.md`) returned NOT
> CLEAN with three blockers, all in item 1's specification of what the
> implementer should compute and change: the assistant-event `usage` shape was
> misstated, the occupancy formula reversed a settled decision in the function
> item 1 rewrites, and the `scope`/budget surface that decision feeds was
> missing. All three are corrected below, together with the review's advisory
> findings. No recorded raw fact changed and no live cell was rerun; the
> corrections are to the specification only.

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
`input_tokens + cache_read_input_tokens + cache_creation_input_tokens` is 15,134
and 17,842 respectively, both inside the 65,536-token window.

**Corrected (blocker 2).** Earlier versions of this line summed `output_tokens`
instead of `cache_creation_input_tokens`. That reverses a settled decision in
`usage_adapter_claude` itself (`files/model-router/scripts/dispatch.sh:842-845`):
output tokens are not context the next turn carries, so adding them inflates any
ratio against a window they never occupied. The occupancy member set is
`input_tokens + cache_read_input_tokens + cache_creation_input_tokens`, exactly
as the shipped adapter computes it, and this queue does not change it. The two
figures are unaffected — `output_tokens` is `0` in every assistant event in both
stream cells, so 15,134 and 17,842 are identical under either formula, which is
precisely why the evidence could not have caught the error. Changing the member
set would be its own decision, needing its own rationale and its own evidence;
nothing in this bundle bears on it.

The terminal envelope's settled occupancy-member sum for the same runs is
cumulative across the session — 30,050 and 234,843 — and cell 3's is 331,717,
5.06 times the window. The field envelopes are worse still: 2,277,622 and
1,407,404, or 34.8× and 21.5× the window. `stream-json` is the
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
context occupancy; any sizing rule that does is wrong by 5.06× in the canary and
by 21.5–34.8× in the field.

Second, deliverable shape predicts turn volume, and turn volume is what ran the
field sessions past their bound: 142 turns for one document plus two schemas,
106 for one document plus one schema. That supports planner guidance about
expected deliverables — and specifically about avoiding large multi-document
local stories — expressed as route metadata. It does **not** support a universal
numeric output-token threshold; nothing here measures one. The input-byte
budget keeps the meaning it already has.

This second point is **weak, qualitative evidence from two successful long
runs** and must be read as such. Field run 4.4 had the largest deliverable set
of the four — three documents plus four schemas — and ran only 30 minutes before
exiting 1 on `rapid_refill_breaker`. It aborted for an unrelated reason, so it
is explicitly non-comparable rather than a counterexample, but it is why the
guidance stays a planner-facing prompt rather than a rule, and why no numeric
threshold follows from it.

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
  occupancy, keeping the adapter's existing member set unchanged;
- keep malformed/truncated-stream and no-result refusal behaviour.

**Budget semantics this changes — name it, do not let it ride along.** Reading
per-call usage from the last assistant event makes a valid multi-turn stream a
genuinely final-context measurement, so `usage_adapter_claude` must report
`scope: FINAL_CONTEXT` for it, not `CUMULATIVE_RUN` with reason
`USAGE_CUMULATIVE_ONLY`. Today `FINAL_CONTEXT` is reached only when
`num_turns == 1`. That switch is not cosmetic: it is what decides whether a
ratio is computed at all, so budget-band evaluation and PM readiness begin
running for exactly the multi-turn gateway runs they are currently withheld
from. That is the intended outcome, and it is a behavioural change with its own
acceptance criteria below.

Cumulative-envelope behaviour is untouched for every input that provides only
cumulative usage: a `json` envelope, or a stream from which no per-call
assistant usage can be read, still reports `CUMULATIVE_RUN` with
`USAGE_CUMULATIVE_ONLY`, still publishes the figure as information, and is still
never divided by a window.

**Files expected to change.**

- `files/model-router/scripts/dispatch.sh` — `build_claude_gateway_command` and
  `build_claude_command` (the `--output-format` argument, the added `--verbose`,
  the added `Edit` tool); `usage_adapter_claude` (parse the last `assistant`
  event's per-call `usage` instead of summing the envelope, and set `scope`
  accordingly); the result-file reader around `WORKER_TEXT` (read `.result` from
  the terminal event of a JSONL stream rather than a single object).
- `tests/run-tests.sh` — the scope and budget assertions that encode the current
  semantics: `:1769-1771` (a multi-turn envelope yields
  `CUMULATIVE_RUN USAGE_CUMULATIVE_ONLY`) and `:1788-1800` (that a cumulative
  figure yields no ratio, no band, no `HIGH_USAGE`, and leaves the pre-dispatch
  verdict `OK`, against the `FINAL_CONTEXT` control immediately below). These
  stay as they are for cumulative-only inputs and gain a stream-fed case.
- `tests/lifecycle-readiness-tests.sh` — the readiness rows that depend on
  `PM_USAGE_CUMULATIVE_ONLY`, `:1489-1490` and `:1520`.
- `lib/afk-commands.sh:526` and `:638` — the operator-facing
  `PM_USAGE_CUMULATIVE_ONLY` reason row and the observation-to-reason mapping,
  if either no longer describes when the code is now reached.
- `tests/` — new fixtures for the parsing boundary (listed below).

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
- **Every nonempty stdout line must parse as exactly one JSON object.** A line
  that does not parse poisons the stream: the launch is refused. A malformed
  line may **not** be skipped merely because a later line parses as a valid
  `result` — a stream the parser could not read in full is a stream whose
  completeness it cannot vouch for.
- Occupancy is read from the last `assistant` event carrying a `usage` object,
  and its members are `input_tokens`, `cache_read_input_tokens` and
  `cache_creation_input_tokens` — the adapter's existing set, summed exactly as
  `usage_adapter_claude` sums them today. `output_tokens` is present on the
  event and is deliberately excluded: it is not context the next turn carries.
  The window comes from `.modelUsage["<model>"].contextWindow` on the result
  event (65,536 observed).
- **Corrected (blocker 1).** `cache_creation_input_tokens` is **absent** from
  every assistant-event `usage` object observed — all 28 in cell 4 and all 4 in
  cell 2 lack the key entirely; it appears exactly once in the whole 258-event
  stream, inside the terminal `result` event's cumulative `usage`. Earlier
  versions of this file said it was observed as `null`, which was never seen and
  is a different branch in `jq`, in `has()`, and in most typed decoders. The
  parser must treat an **absent or explicit-null** optional cache-creation
  member as zero, and both shapes need fixtures, with **absent** as the observed
  primary case.
- **Repeated assistant events for one model message.** `assistant` events are
  emitted one per content block and repeat the same message-level `usage`: cell
  4's 28 assistant events carry 14 distinct usage objects, cell 2's 4 carry 2.
  The parser selects the **last** assistant event carrying usage and must never
  sum message-level usage across events; summing double-counts.
- Truncated stream: a stream with **no** parseable `result` event is a launch
  that did not complete. It must produce no thin result, no gates, and exit 2 —
  identical to the current zero-byte-file behaviour. Truncation must never be
  read as success.
- Zero terminal `result` events and more than one terminal `result` event are
  both malformed streams, refused the same way. Two results is not a choice to
  make between them.

**Fixtures.** Seven, covering every boundary above:

1. A complete stream with a `result/success`, whose assistant-event `usage`
   objects **omit** `cache_creation_input_tokens` — the observed shape.
2. The same with an explicit `cache_creation_input_tokens: null`, to prove both
   branches resolve to zero.
3. A stream whose final model message emits **two** assistant events repeating
   one message-level `usage` — an implementation that sums instead of selecting
   the last event fails this one.
4. A stream with a result carrying `is_error: true`.
5. A stream truncated mid-event with no result.
6. A stream with an unparseable line before an otherwise valid result — refused,
   not skipped.
7. A stream carrying two `result` events — refused.

**Acceptance test.** Rerun cells 1–4 of this bundle's `run-cell.sh` under the
amended command and require, for every cell: a parsed terminal `result` event,
an observed process exit, and a final-call occupancy figure at or below the
declared window, summed over the adapter's existing member set. A run producing
files but no terminal event must still yield exit 2. In addition:

- A valid multi-turn `stream-json` run reports `scope: FINAL_CONTEXT` with no
  `USAGE_CUMULATIVE_ONLY` reason, and the budget half evaluates it: a ratio is
  computed, a band is asserted, and the readiness path stops reporting
  `PM_USAGE_CUMULATIVE_ONLY` for that observation.
- A `json` envelope, and any stream with no readable per-call assistant usage,
  still reports `CUMULATIVE_RUN` / `USAGE_CUMULATIVE_ONLY`, still yields no
  ratio and no band, and still leaves the pre-dispatch verdict where lane A put
  it.

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

**Interaction with item 1 — stated, because item 2 is otherwise billed as
independent.** Item 1 turns the redirect target from a file that stays empty
until the end into one written continuously, so after item 2 fences a timed-out
run what sits on disk is a **truncated JSONL stream**, not the zero-byte file
today's behaviour leaves. That partial stream is **left in place** as diagnostic
evidence — it is the most informative thing a timed-out run produces — but only
once the exact launcher-owned process is confirmed stopped, since a file a live
process is still appending to has no stable content to preserve. From that point
its content and mtime must remain stable. It can never yield a thin success
result: it is the truncated case item 1 already refuses, so no parseable
terminal `result` means no thin result, no gates, exit 2.

**Acceptance test.** A launch driven past its bound leaves no live descendant
process attributable to the launcher, and the result path's content and mtime
are unchanged when re-examined after the harness would otherwise have finished —
whether that path holds a zero-byte file or a truncated stream. Feeding the
retained partial stream back through the reader yields refusal and exit 2.

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
