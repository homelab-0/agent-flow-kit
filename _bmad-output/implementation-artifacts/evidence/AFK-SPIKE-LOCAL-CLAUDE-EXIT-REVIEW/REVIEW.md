# AFK-SPIKE-LOCAL-CLAUDE-EXIT — fresh-session adversarial review

Independent session. Reviewed `origin/master..b6587b5` on branch
`jlengelbrecht/afk-spike-local-claude-exit`. Every number below was recomputed
from the source files and the retained streams; nothing was accepted from the
bundle's prose.

Persona: `.agents/skills/bmad-agent-dev/SKILL.md` + `customize.toml`.

```
$ { sha256sum .agents/skills/bmad-agent-dev/SKILL.md; \
    sha256sum .agents/skills/bmad-agent-dev/customize.toml; } | sha256sum
4cdff719c4f3042532520611f7106d80393173004355e6a83771b366c3efc7f9  -
```

Matches the expected outer hash. Intermediates
`0bc44690f0dc7fdeaabd763efd3ead4b2e8bb8b3a8d5437140605a544b39bb1f` and
`ab52d8840427e10d5956b592c34e63edc77ebdafd7b54ce60da11cf67ed72ced` match too.

## Verdict

**AFK-SPIKE-LOCAL-CLAUDE-EXIT REVIEW: NOT CLEAN — 3 blockers**

The evidence is sound and the causal reasoning is right. All three blockers sit
in `FIX-SCOPE.md` item 1, where the spec handed to the implementer misstates one
observed fact, prescribes a formula that reverses a settled decision in the code
it tells you to rewrite, and omits the downstream surface that decision feeds.
None of them touches the field diagnosis, the four-cell result, or the
fail-closed rule — all of which survive the review intact.

## Check 1 — the two late source envelopes

Both files were read in place in the ai-control-plane worktrees and not
modified. `git -C <worktree> status --porcelain` reports only untracked
`_bmad-output/` and `_bmad/` in each; nothing is staged or dirty.

```
$ sha256sum <4.6 envelope>
03965bc7b687a4b0df5369528f40cc524c155e530bd042f3628bf35a23401898
$ sha256sum <4.4a envelope>
8993d1feeaa64d380b257f8c6b6518bbe5b4c40c1b7002a30e45bc63846f3635
$ stat -c 'size=%s mtime=%y'
size=6213 mtime=2026-09-08 14:42:31.392385525 -0400
size=4313 mtime=2026-09-08 16:13:59.425581685 -0400
```

Digests, sizes and mtimes match `LATE-ENVELOPES.md` exactly. `jq -s length` is
1 for each — a single envelope, not a stream, as claimed.

Independently extracted, every retained value confirmed:

| Field | 4.6 recomputed | 4.4a recomputed | Bundle | 
| --- | --- | --- | --- |
| `type` / `subtype` / `is_error` | `result` / `success` / `false` | `result` / `success` / `false` | matches |
| `num_turns` | 142 | 106 | matches |
| `duration_ms` | 5,604,632 | 5,743,774 | matches |
| `duration_api_ms` | 5,587,388 | 5,731,151 | matches |
| `modelUsage` key / `contextWindow` / `maxOutputTokens` | `qwen36-27b` / 65,536 / 32,000 | same | matches |
| `permission_denials` (array length) | 8 | 10 | matches |
| `usage` input / cache-read / cache-creation / output | 304,999 / 1,972,623 / 0 / 23,613 | 273,338 / 1,134,066 / 0 / 26,008 | matches |
| sum read as occupancy | 2,301,235 | 1,433,412 | matches |

Derived values recomputed: 2,301,235 ÷ 65,536 = 35.11 (`35.1×` ✓);
1,433,412 ÷ 65,536 = 21.87 (`21.9×` ✓). Timeout deltas against 5,400,000 ms:
204,632 ms = 3m 24.632s and 343,774 ms = 5m 43.774s — both as stated. Wall
times 93m 24.6s and 95m 43.8s ✓. `duration_api_ms` fractions 99.692% and
99.780%, printed as 99.7% and 99.8% ✓.

The 5,400,000 ms bound is real and sourced:
`files/model-router/scripts/dispatch.sh:1491` defaults
`launcher.launch_timeout_seconds` to `5400`, and `orca_launch` (line 355) dies
with `EX_CONFIG`, which is `2` (line 52). The bundle's "dispatch returned exit
2" is verified, not asserted.

`LATE-ENVELOPES.md` retains counts and numeric members only. I confirmed the
source envelopes contain `session_id`, `uuid`, `result` prose and per-denial
`tool_use_id` values, and that none of them appear anywhere in the bundle.

## Check 2 — the four live cells

Every cell's `meta.json` was checked against its own retained stream.

| Cell | Format | Turns | Elapsed | Exit | Terminal envelope | Declared files | Final-call |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `json` | 2 | 54s | 0 | `result/success` | 1 (`canary.md`) | n/a |
| 2 | `stream-json --verbose` | 2 | 13s | 0 | `result/success` | 1 (`canary.md`) | 15,134 |
| 3 | `json` | 19 | 157s | 0 | `result/success` | 7 | n/a |
| 4 | `stream-json --verbose` | 14 | 113s | 0 | `result/success` | 7 | 17,842 |

- Elapsed times reproduce from the recorded UTC start/end pairs in all four
  cells (54, 13, 157, 113). They sum to 337 s, the figure `INDEX.md` claims
  against the 2400-second budget.
- `outer_timeout_fired` is `false` and `process_exit_status` is `0` in all four.
- Every `stdout_redacted_sha256` and `stderr_redacted_sha256` in `meta.json`
  matches `sha256sum` of the committed file. Stderr is byte-identical across all
  four cells (269 bytes, `1b95d851…`).
- Terminal envelopes parsed out of the retained streams carry exactly the
  `num_turns`, `is_error` and `usage` members `meta.json` records.
- `ls -1 <cell>/work | wc -l` returns 1, 1, 7, 7 — the declared-file counts.
- Cumulative sums recomputed: 30,173 / 30,192 / 333,985 / 236,349, matching the
  `FINDINGS.md` table. Cell 3's 333,985 ÷ 65,536 = 5.10 ("five times" ✓).
- Final-call figures recomputed from the last `assistant` event: cell 2
  15,040 + 94 + 0 = 15,134; cell 4 17,567 + 275 + 0 = 17,842. Both ✓, both
  inside the 65,536 window.
- Cell 4's tool-call sequence in `meta.json` reproduces exactly from the
  `tool_use` blocks in stream order: six `Write`, six `Read`, one `Write`.
- `wc -l` on cell 4's stream is 258; type counts are 216 `system`, 28
  `assistant`, 13 `user`, 1 `result` — the numbers `FIX-SCOPE.md` cites.
- Observed subtype order in cell 4 is `hook_started`, `hook_response`, `init`,
  then 211 `thinking_tokens`, matching the parsing-boundary description.

Secret handling holds. A scan for API-key-shaped strings, bearer headers and
`ANTHROPIC_API_KEY=` assignments across the bundle returns nothing. Session and
message identifiers in the retained streams are all `<redacted>`.
`placement-evidence.json` contains only status, model, placement, readiness,
TTL and a catalog digest.

One thing that looks like a contradiction and is not: the retained stderr says
"claude.ai connectors are disabled because ANTHROPIC_API_KEY **or another auth
source** is set". `run-cell.sh` launches under `env -i` passing
`ANTHROPIC_AUTH_TOKEN` only, so the warning is triggered by the auth token, not
by an API key. AC-6's "`ANTHROPIC_API_KEY` was never set or exported" stands.

## Check 3 — stale assertions

I searched the corrected parent story, `INDEX.md`, `FINDINGS.md` and
`FIX-SCOPE.md` for surviving claims that the field processes never exited, that
`json` caused non-termination, or that `stream-json` is an exit or speed fix.

Every match is either explicitly corrective, quotes the superseded wording
inside a correction banner, or refers to what the *reports* said rather than
asserting it. `FIX-SCOPE.md:211` and `FINDINGS.md:110` state the opposite of the
retracted claim. No file asserts `stream-json` fixes exit or speed; three
separate passages forbid it.

Two unmarked survivals, both advisory (A2, A3 below): the parent story's H1 and
`EXPERIMENT.md`.

## Check 4 — the causal statement

The statement holds at each of its four parts, and the bundle's restraint about
the fifth is correct.

- **The 5,400,000 ms bound versus 5,604,632 / 5,743,774 ms runs** — proved. The
  bound is in `dispatch.sh:1491`; the durations are in the envelopes.
- **`json` progress blindness** — supported, and correctly separated from
  termination. Cells 1 and 3 show `json` terminating at 2 and 19 turns; cell 1's
  retained stdout is a single object, so nothing reaches the redirect target
  before the end. The bundle never upgrades this to a termination cause.
- **A late process/result surviving dispatch exit 2** — proved, and the code
  path confirms the mechanism rather than merely being consistent with it.
  `orca_launch` at `dispatch.sh:353-355` calls `die` on deadline expiry and does
  nothing to the terminal or its child; the process is simply left running.
- **Timing between final model event and process exit** — correctly held
  `NOT_TESTED`. The envelopes carry totals, not a timeline; the field runs used
  `json`, which emits no per-event timestamps. (Note that the retained
  `stream-json` events *do* carry a `timestamp` field, so this is a property of
  the field format, not of the harness — worth knowing when item 1 lands.)

The bundle is, if anything, more conservative than its own evidence here — see
A4.

## Check 5 — the three queued fixes

Independence and sequencing are sound: item 1 is a contract amendment that must
be negotiated once, item 2 is orthogonal to the launch text, item 3 is a
planning change and correctly ranked last as a non-correctness item. The
required properties are present:

- The combined `Edit` + `stream-json --verbose` item **does** carry the
  ai-control-plane obligation, and states the amendment does not ship until the
  exact launch text is agreed on both sides. ✓
- Timeout fencing targets "the exact launcher-owned terminal/process", says
  "Never remove a worktree", and explicitly leaves the refusal verdict alone. ✓
  Its premise is verified against the code above.
- Output-shaped planning explicitly refuses a universal numeric output-token
  threshold and keeps the input-byte budget's meaning. ✓

The three blockers below are all in item 1's specification of *what the
implementer should compute and change*.

### BLOCKER 1 — `cache_creation_input_tokens` is absent, not `null`

`FIX-SCOPE.md` tells the implementer that the final-call usage members include
"`cache_creation_input_tokens` (observed `null` here — must be treated as 0, not
as absent-and-fatal)", and prescribes a fixture: "a stream whose last assistant
event has `cache_creation_input_tokens: null`". The parent story's AC-5
self-assessment repeats it: "final-call usage members (including
`cache_creation_input_tokens: null`)".

That is not what was observed. In cell 4, every one of the 28 `assistant` events
has a `usage` object that does **not contain the key at all**:

```
$ jq -c 'select(.type=="assistant")|.message.usage|has("cache_creation_input_tokens")' \
    sessions/cell-4-stream-json-multiturn/stdout.redacted.jsonl | sort | uniq -c
     28 false
$ grep -o 'cache_creation[a-z_]*' sessions/cell-4-stream-json-multiturn/stdout.redacted.jsonl \
    | sort | uniq -c
      1 cache_creation
      1 cache_creation_input_tokens
```

The only occurrence in the whole 258-event stream is inside the terminal
`result` event's cumulative `usage`. Cell 2 is the same shape. The redaction is
documented as replacing identifiers and collapsing `system/thinking_tokens`
events, and every assistant `usage` object is retained verbatim, so the absence
is a property of the stream and not of the redaction.

Why it blocks: the two shapes are not interchangeable to a parser. `null` and
absent take different branches in `jq`, in `has()`, and in most typed decoders,
and the prescribed fixture set exercises only the shape that was *never*
observed while leaving the shape that *always* occurs untested. An
implementation can pass all five declared fixtures and still fail on the first
real gateway stream. This is a wrong source fact and an acceptance gap that
changes the queued work.

Fix: state that the member is absent from the assistant-event `usage` object and
present only on the terminal envelope; require the fixture to be the observed
shape (key absent), and keep a `null` variant as an additional case rather than
the only one.

### BLOCKER 2 — the occupancy formula reverses a settled decision in the function it rewrites

`FIX-SCOPE.md`, `FINDINGS.md` and `INDEX.md` all define final-call occupancy as
`input_tokens + cache_read_input_tokens + output_tokens`, and item 1 directs the
implementer to change `usage_adapter_claude` to "parse the last `assistant`
event's per-call `usage` instead of summing the envelope".

The function being rewritten deliberately excludes output tokens, and says so
(`dispatch.sh:842-845`):

> usage_tokens is what the envelope's `usage` object publishes — input, cache
> reads and cache creation summed. Output tokens are not context the next turn
> carries, so adding them would inflate any ratio against a window they never
> occupied.

The shipped `jq` expression sums `input_tokens + cache_read_input_tokens +
cache_creation_input_tokens` — three members, no output. `FIX-SCOPE.md` asks for
a different three: input, cache-read and **output**, dropping cache-creation. It
is also internally inconsistent: its own "final-call usage members" bullet lists
four members including `cache_creation_input_tokens`, while its occupancy
formula names three and excludes it.

Why it blocks: an implementer following the spec literally will silently reverse
a documented, tested policy about what counts as occupancy, inside the one
function whose whole purpose is not to invent routed facts. The evidence cannot
catch the error, because `output_tokens` is `0` in every assistant event
observed in both stream cells — 15,134 and 17,842 are identical under either
formula. The spike therefore has no evidence bearing on the question it
implicitly re-decides.

Fix: either keep the adapter's existing member set and say so explicitly, or
raise the change as its own decision with its own rationale. Do not let it ride
along in a formula. Resolve the three-versus-four member inconsistency either
way.

### BLOCKER 3 — the adapter change flips `scope`, and the downstream surface is not in scope

Item 1's "Files expected to change" lists `dispatch.sh` (three sites) and
"`tests/` — new fixtures for the parsing boundary". That is not the full surface.

`usage_adapter_claude` publishes a `scope` field, and today it is
`FINAL_CONTEXT` only when `num_turns == 1`; every multi-turn run is
`CUMULATIVE_RUN` with reason `USAGE_CUMULATIVE_ONLY`. Reading per-call usage from
the last assistant event makes multi-turn runs genuinely final-context, so
`scope` becomes `FINAL_CONTEXT` for exactly the runs it is currently withheld
from. That is not cosmetic — it is the switch that decides whether a ratio is
computed at all:

- `tests/run-tests.sh:1766-1772` asserts a multi-turn envelope yields
  `CUMULATIVE_RUN USAGE_CUMULATIVE_ONLY`.
- `tests/run-tests.sh:1788-1800` asserts the cumulative figure yields **no**
  ratio, **no** band, **no** `HIGH_USAGE`, and leaves the pre-dispatch verdict at
  `OK`. The control immediately below asserts that a `FINAL_CONTEXT` measurement
  *does* evaluate, reaching `CONTINUATION_REQUIRED` and asserting `HIGH_USAGE`.
- `lib/afk-commands.sh:526` carries the operator-facing remedy text for
  `PM_USAGE_CUMULATIVE_ONLY`; `tests/lifecycle-readiness-tests.sh:1489-1490` and
  `:1520` assert the readiness rows that depend on it.

So the change turns on budget-band evaluation for every multi-turn claude
gateway run, and changes what the PM readiness path reports for them. That may
well be the right outcome — it is arguably the point — but it is a behavioural
change to a lane the spike never names, against existing assertions that encode
the current semantics, and it is missing from the item's file list and from its
acceptance test (which only requires "a final-call occupancy figure at or below
the declared window").

Why it blocks: an acceptance gap that changes the queued work. Item 1 is sized
as a parsing change; it is a parsing change plus a budget-semantics change.

Fix: name `budget_evaluate_usage`'s consumers and the affected assertions in
`tests/run-tests.sh` and `tests/lifecycle-readiness-tests.sh` as expected
surface, and add an acceptance criterion stating what `scope` a multi-turn
stream-json run must now report and what the budget half is expected to do with
it.

## Check 6 — hygiene

- `git diff --name-only origin/master..b6587b5` returns 52 paths, all under
  `_bmad-output/implementation-artifacts/`. Nothing under `files/`, `lib/`,
  `docs/`, `tests/`, the installed kit, catalog or registry. AC-6 holds.
- No raw field envelope was copied. The two source files exist only in the
  ai-control-plane worktrees and are byte-identical to their recorded digests.
- Neither source worktree is modified.
- Both commit messages are plain engineering language with no trailers, no
  `Co-Authored-By`, no session link, no tool banner. The `Co-Authored-By`
  strings that `git grep` finds in the tree are prohibition text inside other
  stories' briefs, not attribution.
- `git diff --check` — exit 0, no output.

## Advisory findings

**A1 — reversed turn/duration pairing in prose.** `LATE-ENVELOPES.md` ("106- and
142-turn sessions that needed 93 and 96 minutes") and `FINDINGS.md:80` ("needed 106 and 142 turns and 93 and 96 minutes") pair the
turn counts ascending against the minutes ascending, but 106 turns is the 96-
minute run and 142 turns is the 93-minute one. Correct tables sit directly above
both sentences, and `FIX-SCOPE.md` pairs them correctly, so nothing downstream is
wrong — but the sentence as written inverts the relationship item 3 is built on.

**A2 — `EXPERIMENT.md` carries a superseded figure with no correction pointer.**
It says the field reports describe sessions of "30-87 minutes"; `FINDINGS.md`
says "30, 42, 93 and 96". The 87 was the pre-correction belief. `EXPERIMENT.md`
is append-only by design and `INDEX.md` labels it as predeclared, which is the
right instinct — but every other corrected file carries a banner and this one
does not, and check 3's rule is that historical wording be explicitly marked.
One appended line pointing at `LATE-ENVELOPES.md` would close it without editing
the predeclaration.

**A3 — the parent story's H1 still reads "sessions that never exit".** Unmarked,
26 lines above the correction banner that retracts it. The table rows below say
"corrected, see below", so a reader is not misled for long, but the title is the
one line most likely to be quoted alone.

**A4 — the bundle is more conservative than its own evidence about the timing
question.** `duration_ms − duration_api_ms` is 17,244 ms and 12,623 ms, so within
each harness's own measured lifetime there was at most ~17 s of non-API time in
total. That does not date the last model event against *process exit* — the
bundle is right that nothing here does — but it does bound in-harness idle
tightly enough to be evidence against "the model stopped generating long before
the process exited", which `FINDINGS.md` leaves as symmetric ignorance. Stating
the bound would make the `NOT_TESTED` label sharper, not weaker.

**A5 — the redaction step is not reproducible from the bundle.** `run-cell.sh`
captures `stdout.raw` but performs no redaction; the raw streams are not
retained. Pre- and post-redaction digests are both recorded, which is good
provenance, but no third party can verify that redaction preserved the fields
the findings rest on. Retaining the redaction filter (not its output) would
close this. It matters most for Blocker 1, where the finding is about a member's
absence.

**A6 — item 3's "deliverable shape predicts turn volume" is n=2, with an
unaddressed counterexample in the same four reports.** The anchor is 142
turns/one document + two schemas and 106 turns/one document + one schema. Field
run 4.4 had *three* documents plus *four* schemas and ran only 30 minutes before
exiting 1 on `rapid_refill_breaker`. It aborted for an unrelated reason, so it is
not a clean refutation — but it is the largest deliverable set in the set and the
shortest run, and item 3 does not mention it. The guidance is qualitative and the
bundle correctly refuses a numeric threshold, so this is a completeness note.

**A7 — the fixture list omits the observed multi-event-per-message shape.**
`assistant` events are emitted one per content block and repeat the same
message-level `usage`: cell 4's 28 assistant events carry 14 distinct message
usages, and cell 2's 4 carry 2. `FIX-SCOPE.md` says "the last assistant event",
which is correct and unambiguous — but an implementation that instead sums
across assistant events would double-count, and no fixture would catch it. Add a
fixture whose final model message emits two assistant events.

**A8 — items 1 and 2 interact, and item 2 is billed as independent.** Item 1
turns the redirect target from "empty until the end" into a file written
continuously. After item 2 fences a timed-out run, what sits on disk is a
truncated JSONL stream rather than the zero-byte file the current behaviour
leaves. Item 1's rule — no parseable `result` event means no thin result, no
gates, exit 2 — covers reading it, so the fail-closed outcome is safe. But item
2's acceptance test ("the result path's content and mtime are unchanged when
re-examined") is written against a file that, post-item-1, was being written up
to the moment of the kill. Say explicitly that a fenced run's partial stream is
the truncated case, and state whether it is left in place or removed.

## What survives the review unchanged

Recorded because a NOT CLEAN verdict should not obscure it:

- The field diagnosis is correct and now well sourced. Both sessions terminated
  normally past the bound; the workload/timeout mismatch is the narrow cause;
  `json` buffering is named as progress blindness and never as a termination
  cause; `stream-json` is claimed as neither a speed nor an exit fix. AC-3 is
  met.
- The four-cell live result stands exactly as run, and the negative result is
  reported as a negative result.
- The cumulative-versus-final-call usage finding is the real product of this
  spike and reproduces at field scale (35× and 22× the window).
- The fail-closed rule is not weakened anywhere. Cell 3's seven files existing
  before its envelope, and the field files being zero bytes at the moment of
  refusal, are used as the two-sided argument for keeping it.
- Secret handling and repository hygiene are clean.

Fixing the three blockers is a specification edit to `FIX-SCOPE.md` and the
parent story's AC-5 line. No evidence needs to be re-gathered and no live cell
needs to be re-run.
