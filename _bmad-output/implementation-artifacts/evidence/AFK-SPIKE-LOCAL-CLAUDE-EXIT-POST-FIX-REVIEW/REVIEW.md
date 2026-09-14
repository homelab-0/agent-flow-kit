# AFK-SPIKE-LOCAL-CLAUDE-EXIT — post-fix review

Fresh session, delta-scoped. Reviewed commit `544bb84` against the three
blockers and eight advisories in
`evidence/AFK-SPIKE-LOCAL-CLAUDE-EXIT-REVIEW/REVIEW.md`. No live gateway call
was made and no product, test, catalog or registry file was touched. Every
number below was recomputed from the retained streams or read out of the code
at the cited line; nothing was taken from the correction story's prose.

Persona: `.agents/skills/bmad-agent-dev/SKILL.md` + `customize.toml`.

```
$ { sha256sum .agents/skills/bmad-agent-dev/SKILL.md; \
    sha256sum .agents/skills/bmad-agent-dev/customize.toml; } | sha256sum
4cdff719c4f3042532520611f7106d80393173004355e6a83771b366c3efc7f9  -
```

Matches the expected outer hash; intermediates `0bc44690…` and `ab52d884…`.

## Verdict

**AFK-SPIKE-LOCAL-CLAUDE-EXIT POST-FIX REVIEW: CLEAN**

All three blockers are closed with the observed facts, not with a restatement.
Every advisory is incorporated. The queue is unchanged in content and order,
the retained evidence is byte-identical, and the gate passes. Four advisories
follow; none of them changes the queued work, and one of them is an
over-claim in the correction story's own acceptance line rather than a defect
in the specification it produced.

## Check 1 — the assistant-event usage shape, recomputed

Recomputed from `sessions/cell-2-stream-json/stdout.redacted.jsonl` and
`sessions/cell-4-stream-json-multiturn/stdout.redacted.jsonl`.

| Measurement | Cell 2 | Cell 4 |
| --- | --- | --- |
| Stream lines | 51 | 258 |
| Event types | 45 `system`, 4 `assistant`, 1 `user`, 1 `result` | 216 `system`, 28 `assistant`, 13 `user`, 1 `result` |
| `usage \| has("cache_creation_input_tokens")` over assistant events | `false` ×4 | `false` ×28 |
| Distinct assistant-event `usage` objects | 2 | 14 |
| `cache_creation*` occurrences in the whole stream | 1 `cache_creation`, 1 `cache_creation_input_tokens` (both inside the terminal `result`) | same |
| `output_tokens` over assistant events | `0` ×4 | `0` ×28 |
| Last assistant `usage` | 94 + 15,040 → 15,134 | 275 + 17,567 → 17,842 |

The corrected `FIX-SCOPE.md` states exactly this: absent, not `null`; present
only on the terminal envelope; 28/14 and 4/2 for the repeated-event counts; the
last assistant event selected, never summed. All of it reproduces. The
`output_tokens: 0` claim that explains why the evidence could not have caught
blocker 2 also reproduces, in every assistant event of both cells.

Retained-evidence integrity: every `stdout_redacted_sha256` and
`stderr_redacted_sha256` in all four `meta.json` files still matches
`sha256sum` of the committed file. `544bb84` touches no file under `sessions/`.

## Check 2 — the occupancy formula

Every formula that tells an implementer what to compute now names the shipped
member set and excludes output tokens:

- `FIX-SCOPE.md:48-49` (the answer), `:52-62` (the correction and why the
  evidence could not settle it), `:135-137` (queue item 1's rule), `:200-206`
  (the parsing boundary).
- `FINDINGS.md:171-173` and its `:175-185` correction note.
- The parent story's AC-5 line and its FIX-2 correction record.

That set is what `usage_adapter_claude` actually sums, and the rationale quoted
against it is real: `files/model-router/scripts/dispatch.sh:842` opens the
comment block that ends "adding them would inflate any ratio against a window
they never occupied", and the shipped `jq` body below it sums the same three
members. The queue no longer redecides it.

One exception survives, recorded as advisory B1: the bundle's *cumulative*
figures are still four-member sums. This is not a prescriptive formula and it
changes no finding's direction, so it does not block.

## Check 3 — the `FINAL_CONTEXT` switch and its downstream surface

Item 1 now carries a "Budget semantics this changes — name it, do not let it
ride along" paragraph stating that a valid multi-turn stream must report
`scope: FINAL_CONTEXT` rather than `CUMULATIVE_RUN` / `USAGE_CUMULATIVE_ONLY`,
that this is the switch deciding whether a ratio is computed at all, and that
budget-band evaluation and PM readiness therefore begin running for the runs
they are currently withheld from. The paragraph immediately after preserves
cumulative-only behaviour for a `json` envelope and for any stream with no
readable per-call assistant usage: still `CUMULATIVE_RUN`, still published as
information, still never divided by a window. Two acceptance criteria assert
both halves.

Every named consumer resolves in the tree:

| Cited | Verified |
| --- | --- |
| `dispatch.sh:842-845` | The output-token exclusion rationale; `FINAL_CONTEXT` gated on `num_turns == 1` in the comment block below it. |
| `tests/run-tests.sh:1766-1772` | The multi-turn `CUMULATIVE_RUN USAGE_CUMULATIVE_ONLY` assertion closes at `:1771`. |
| `tests/run-tests.sh:1788-1800` | The four budget assertions (`no ratio`, cumulative label, verdict `OK`, no `HIGH_USAGE`) sit at `:1790-1797`, with the `FINAL_CONTEXT` control at `:1802`. |
| `tests/lifecycle-readiness-tests.sh:1489-1490`, `:1520` | The `PM_USAGE_CUMULATIVE_ONLY` readiness case and the loop that reuses it. |
| `lib/afk-commands.sh:526` | The `PM_USAGE_CUMULATIVE_ONLY` reason/remedy row. |

Each cited range contains the assertion it claims; the two `run-tests.sh`
ranges are a line or two wider than the assertions themselves, which is the
right direction for a "expected surface" list.

## Check 4 — the JSONL boundary

All three properties are stated, and stated as refusals rather than as
tolerances:

- "Every nonempty stdout line must parse as exactly one JSON object. A line
  that does not parse poisons the stream: the launch is refused" — with the
  explicit prohibition on skipping a malformed line because a later line parses
  as a valid `result`. This replaces the previous "a line that does not parse is
  skipped".
- "Zero terminal `result` events and more than one terminal `result` event are
  both malformed streams, refused the same way."
- "The parser selects the **last** assistant event carrying usage and must never
  sum message-level usage across events; summing double-counts" — sourced to the
  28/14 and 4/2 counts recomputed in check 1.

Truncation keeps its previous meaning: no parseable `result` means no thin
result, no gates, exit 2, and truncation is never read as success.

## Check 5 — the fixture list

Seven fixtures, and they cover the eight required shapes:

| Required | Fixture |
| --- | --- |
| Observed absent cache-creation member | 1 (also the `result/success` case) |
| Explicit null | 2 |
| Repeated assistant events for one message | 3 |
| Success | 1 |
| Error | 4 (`is_error: true`) |
| Truncation (and zero result events) | 5 |
| Malformed input | 6 (refused, not skipped) |
| Multiple results | 7 |

Fixture 1 is the observed shape and is named as primary; fixture 3 is written
so that a summing implementation fails it. The only surviving
`cache_creation_input_tokens: null` string in the bundle is fixture 2, which is
where it belongs.

## Check 6 — item 2's fenced partial stream

The four required properties are present and correctly conditioned. The partial
stream is left in place as diagnostic evidence "but only once the exact
launcher-owned process is confirmed stopped, since a file a live process is
still appending to has no stable content to preserve"; from that point content
and mtime must remain stable; "Never remove a worktree" survives untouched in
Bounds that do not move; and the stream "can never yield a thin success result
— it is the truncated case item 1 already refuses". The acceptance test now
covers both disk states and adds a refusal test on the retained partial stream.

## Check 7 — advisory accuracy

Recomputed where a number was involved.

- **A1, turn/duration pairing.** Corrected to 142 turns / 93 minutes for 4.6 and
  106 turns / 96 minutes for 4.4a, in both `FINDINGS.md:80` and
  `LATE-ENVELOPES.md`. Against the retained table: 4.6 is 142 turns and
  5,604,632 ms = 93.41 min; 4.4a is 106 turns and 5,743,774 ms = 95.73 min. The
  new pairing is the right one.
- **A2, `EXPERIMENT.md`.** An "Appended correction pointers" section at the end;
  the diff is additions only, nothing above line 120 changed, and the section
  says so. It points at `LATE-ENVELOPES.md` and explains why the retargeting
  decision is unaffected — the sessions were longer than believed, not shorter,
  which is the correct direction of the argument.
- **A3, the parent H1.** Now "sessions reported as never exiting", with a note
  directly under it that no non-exit was found. It can no longer be quoted as an
  assertion.
- **A4, the non-API bound.** 5,604,632 − 5,587,388 = 17,244 and
  5,743,774 − 5,731,151 = 12,623. Both figures correct. The prose does not
  overstate: it says this bounds in-harness idle, notes the envelope carries
  totals rather than a timeline and measures only the harness's own lifetime,
  and leaves final-event-to-exit timing `NOT_TESTED`.
- **A5, redaction.** `INDEX.md` states the filter was not retained and that
  redaction is not independently reproducible, and connects it to the
  absent-member finding specifically. No filter was reconstructed. See advisory
  B3 for one phrase in it.
- **A6, item 3.** Now labelled "weak, qualitative evidence from two successful
  long runs", with field run 4.4 named as the largest deliverable set and
  shortest run, marked explicitly non-comparable rather than a counterexample,
  and no numeric threshold introduced. The 4.4 exit-1 on `rapid_refill_breaker`
  is consistent with `FINDINGS.md:145`; the deliverable count comes from the
  external reports and is not independently checkable from this bundle, which
  the qualification already accounts for.
- **A7, repeated events.** Covered by fixture 3 and by the selection rule in the
  boundary section; counts verified in check 1.
- **A8, item 1/item 2 interaction.** Stated in item 2 under its own heading,
  including the reason it is stated at all.

## Check 8 — queue, scope and gate

- `FIX-SCOPE.md` still carries exactly three queue items in the same order:
  the combined `Edit` + stream-observability amendment, timeout fencing, then
  output-shaped planning. The Sequencing and Deliberately-out-of-scope sections
  are untouched by this commit.
- `544bb84` changes seven files, all under
  `_bmad-output/implementation-artifacts/`: two story files and five bundle
  documents. Nothing under `files/`, `lib/`, `tests/`, `docs/`, the catalog or
  the registry.
- No source evidence changed: zero paths under `sessions/`, and all eight
  retained-stream digests still match.
- `git diff --name-only origin/master..HEAD` has no path outside
  `_bmad-output/implementation-artifacts/`.
- The commit message is plain engineering language: no trailers, no
  `Co-Authored-By`, no session link, no tool banner.
- `git diff --check` — exit 0, no output.

## Advisory findings

**B1 — the cumulative figures are still four-member sums, and the correction
story claims otherwise.** `FIX-2.md` required correction 2 says "Remove every
proposed formula that includes output tokens", and its acceptance line reports
"every proposed output-inclusive formula removed". Every *prescriptive* formula
was. These were not:

| Where | Published | Adapter's three-member set |
| --- | --- | --- |
| `LATE-ENVELOPES.md:49-51`, row "Sum read as occupancy" | 2,301,235 and 1,433,412; 35.1× and 21.9× | 2,277,622 (34.8×) and 1,407,404 (21.5×) |
| `FINDINGS.md:162-167`, "Envelope cumulative sum" column | 30,173 / 30,192 / 333,985 / 236,349 | 30,046 / 30,050 / 331,717 / 234,843 |
| `FIX-SCOPE.md:64-67`, `:100-101` | "30,192 and 236,349", "333,985, five times", "22–35× in the field" | 30,050 and 234,843; 331,717, 5.06×; 21.5–34.8× |

Two consequences, both small. The `FINDINGS.md:162` table sets a four-member
cumulative column beside a three-member final-call column under one window, so
the two halves of the comparison no longer use the same arithmetic. And a row
literally headed "Sum read as occupancy" reads an envelope as occupancy using a
member set the adapter does not use — while the fix's whole point is that the
member set is not this bundle's to redecide.

Not a blocker: no implementer computes anything from these numbers, every
prescriptive formula is correct, and no finding's direction moves (5.10× → 5.06×,
35.1× → 34.8×, 21.9× → 21.5×). Closing it is arithmetic plus one edit to the
FIX-2 acceptance line, which currently over-claims.

**B2 — `lib/afk-commands.sh:638` is a `PM_USAGE_CUMULATIVE_ONLY` consumer and is
not in the expected surface.** The expected-surface list names the reason table
at `:526`. Line 638 also branches on the code, mapping an adapter reason into
the PM observation. Behaviourally the adapter simply stops emitting the reason
for stream-fed runs, so nothing there needs to change — but the list is meant to
be the surface an implementer greps, and one of the two sites is missing from
it.

**B3 — one phrase in `INDEX.md`'s redaction limitation is stronger than the
provenance it rests on.** It says the recorded pre- and post-redaction digests
"establish that the committed streams are the ones that were redacted". Both
digests were produced by the same unretained step, so they establish internal
consistency of that step's own record, not the relation between raw and
committed content. The sentences on either side concede exactly the right thing
— no third party can reproduce the redaction — so this is one clause, not the
paragraph.

**B4 — the two `tests/run-tests.sh` ranges are approximate.** `:1766-1772`
brackets an assertion that runs `:1769-1771`, and `:1788-1800` brackets
assertions at `:1790-1797` plus the setup above them. Both contain what they
claim and err wide, which is the harmless direction; worth knowing only because
line numbers in a queued spec drift.

## What this pass got right, recorded because the verdict is CLEAN

- Blocker 1 was closed with the observed shape rather than by adding `null` to a
  list: absent is named as primary, the `null` variant is kept as a second
  fixture, and the counts backing it recompute exactly.
- Blocker 2 was closed by restoring the shipped member set *and* by saying why
  the evidence could not have caught the error, which is the part that stops the
  same mistake being made again from the same numbers.
- Blocker 3 was closed by naming the behaviour change as intended rather than by
  narrowing the change to avoid it, with the cumulative path explicitly
  preserved and both halves given acceptance criteria.
- The strict-parse rule is a genuine tightening beyond what the review asked
  for, and it is the right default for a fail-closed launcher.
- `EXPERIMENT.md` was appended to, not edited. The predeclaration survives.
- No recorded raw fact changed, no live cell was rerun, and the retained streams
  are byte-identical to what the first review verified.
