---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-SPIKE-LOCAL-CLAUDE-EXIT-FIX-2.md.stamp.json
persona: dev
gates:
  - "git diff --check"
max_cycles: 1
---

# AFK-SPIKE-LOCAL-CLAUDE-EXIT-FIX-2: Close the adversarial-review blockers

The fresh-session review in
`evidence/AFK-SPIKE-LOCAL-CLAUDE-EXIT-REVIEW/REVIEW.md` found the diagnosis and
retained evidence sound, but found three blockers in the proposed
launch/adapter implementation scope. This is a documentation-only correction.
Run no gateway cells and change no production, catalog, registry, contract, or
test file.

## Required corrections

1. Correct the assistant-event shape. In both retained stream cells,
   `cache_creation_input_tokens` is absent from every assistant-event `usage`
   object; it is not present with a `null` value. State that the parser must
   treat an absent or explicit-null optional cache-creation member as zero, and
   require fixtures for both shapes, with absent as the observed primary case.
2. Preserve the settled occupancy formula exactly:
   `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`.
   `output_tokens` remains excluded because it is not context carried into the
   next turn. Remove every proposed formula that includes output tokens.
3. Name the budget-semantics effect of the adapter change. A valid multi-turn
   stream with per-call usage from its last assistant event becomes
   `scope: FINAL_CONTEXT`, not `CUMULATIVE_RUN`; budget-band evaluation and PM
   readiness therefore run for that observation. Add the affected contract,
   command/readiness consumers, and assertions to the expected implementation
   surface and acceptance criteria. Keep cumulative-envelope behavior intact
   for inputs that provide only cumulative usage.
4. Tighten the JSONL boundary: every nonempty stdout line must parse as one
   JSON object. Any malformed line, truncation, zero terminal `result` events,
   or more than one terminal `result` event poisons the stream and refuses
   completion. A malformed line may not be skipped merely because a later
   result parses.
5. Cover repeated assistant events for one model message. The parser selects
   the last assistant event carrying usage; it never sums repeated
   message-level usage across content-block events. Add a fixture that would
   catch double counting.

## Advisory cleanup to incorporate

- Correct the reversed turn/duration prose pairing: 142 turns corresponds to
  about 93 minutes; 106 turns corresponds to about 96 minutes.
- Append (do not rewrite) a correction pointer to the predeclared
  `EXPERIMENT.md` where its superseded 30–87 minute range appears.
- Change the parent story heading so it cannot be quoted as asserting that the
  sessions never exited.
- Record that `duration_ms - duration_api_ms` is 17,244 ms and 12,623 ms. This
  bounds total non-API time but still does not timestamp the last model event,
  so final-event-to-exit timing remains `NOT_TESTED`.
- State the redaction limitation honestly: the filter itself was not retained,
  so preservation of omitted fields is not independently reproducible from the
  bundle. Do not invent a filter after the fact.
- Qualify output-shape guidance as weak, qualitative evidence from two
  successful long runs, with the aborted larger 4.4 run explicitly noted as
  non-comparable. Do not introduce a numeric threshold.
- Specify the interaction between items 1 and 2: timeout fencing leaves the
  partial JSONL file in place as diagnostic evidence, but only after the exact
  launcher-owned process is confirmed stopped. Its content and mtime must then
  remain stable, and it can never yield a thin success result.

## Acceptance criteria

- [ ] The three review blockers are corrected without changing any recorded
      raw fact or rerunning a live cell.
- [ ] The implementation queue still has three independently testable items in
      this order: combined `Edit` + stream observability/final-context usage;
      exact-launch timeout fencing; qualitative output-shaped planning.
- [ ] Item 1 explicitly preserves the existing occupancy member set, switches
      valid multi-turn stream observations to `FINAL_CONTEXT`, names downstream
      budget/readiness effects, and fails closed on any malformed stream line.
- [ ] Fixtures cover absent and null cache-creation members, repeated assistant
      events, success, `is_error: true`, truncation/no-result, malformed input,
      and multiple result events.
- [ ] Item 2 explicitly preserves a stopped partial stream as immutable
      diagnostic evidence and never infers success from it.
- [ ] The corrected parent story self-assessment and the fix scope agree.
- [ ] All edits remain under `_bmad-output/implementation-artifacts/`.
- [ ] `git diff --check` passes.

## Dev Agent Record

Documentation-only correction pass. No gateway call was made, no live cell was
rerun, and no product, contract, test, catalog or registry file was modified.
Every edit was made with the structured `Edit` tool; no shell redirection,
heredoc, `sed -i`, Python or Perl touched a repository file.

Each review claim was recomputed from source before it was written down:
`jq 'select(.type=="assistant")|.message.usage|has("cache_creation_input_tokens")'`
over cell 4's retained stream returns `false` 28 times; the same stream carries
28 assistant events and 14 distinct message-level `usage` objects; the shipped
`usage_adapter_claude` sums `input_tokens + cache_read_input_tokens +
cache_creation_input_tokens` and gates `FINAL_CONTEXT` on `num_turns == 1`
(`files/model-router/scripts/dispatch.sh:842-845` and the `jq` body below it);
and the named assertions exist at `tests/run-tests.sh:1766-1772` and
`:1788-1800`, `tests/lifecycle-readiness-tests.sh:1489-1490` and `:1520`, and
`lib/afk-commands.sh:526`.

### Files changed

| File | Correction |
| --- | --- |
| `evidence/AFK-SPIKE-LOCAL-CLAUDE-EXIT/FIX-SCOPE.md` | Blockers 1-3, the strict JSONL boundary, repeated-assistant-event rule, seven fixtures, the item 1/item 2 interaction, and the qualified output-shape guidance. |
| `evidence/AFK-SPIKE-LOCAL-CLAUDE-EXIT/FINDINGS.md` | Occupancy member set, absent-not-null note, corrected turn/duration pairing, and the non-API time bound. |
| `evidence/AFK-SPIKE-LOCAL-CLAUDE-EXIT/LATE-ENVELOPES.md` | Corrected turn/duration pairing and the stated `duration_ms − duration_api_ms` bound. |
| `evidence/AFK-SPIKE-LOCAL-CLAUDE-EXIT/INDEX.md` | The redaction limitation stated honestly. |
| `evidence/AFK-SPIKE-LOCAL-CLAUDE-EXIT/EXPERIMENT.md` | Appended correction pointer for the superseded 30-87 minute range; predeclaration left unedited. |
| `AFK-SPIKE-LOCAL-CLAUDE-EXIT.md` | Heading reworded, AC-5 self-assessment corrected, FIX-2 record added. |
| `AFK-SPIKE-LOCAL-CLAUDE-EXIT-FIX-2.md` | This record. |

### Acceptance criteria

- **Three blockers corrected without changing a raw fact or rerunning a cell** —
  met. Blocker 1: absent, not `null`, with both shapes required as fixtures and
  absent as primary. Blocker 2: the settled member set
  `input_tokens + cache_read_input_tokens + cache_creation_input_tokens` restored
  in `FIX-SCOPE.md` and `FINDINGS.md`, `output_tokens` excluded, the
  three-versus-four inconsistency resolved, and every proposed output-inclusive
  formula and comparison removed. Blocker 3: the `FINAL_CONTEXT` switch, its budget and
  readiness consumers, and the affected assertions named in the expected surface
  and asserted in the acceptance criteria. The 15,134 and 17,842 figures are
  unchanged, as are all four cells and both envelopes.
- **Queue still three ordered items** — met: combined `Edit` + stream
  observability / final-context usage; exact-launch timeout fencing;
  qualitative output-shaped planning.
- **Item 1 preserves the member set, switches scope, names downstream effects,
  fails closed on malformed lines** — met; the boundary now also refuses zero
  and multiple terminal `result` events, and forbids skipping a malformed line
  because a later result parses.
- **Fixture coverage** — met, seven fixtures: absent cache-creation, null
  cache-creation, repeated assistant events, `result/success`, `is_error: true`,
  truncation with no result, a malformed line, and two result events.
- **Item 2 preserves a stopped partial stream as immutable evidence** — met, and
  conditioned on the launcher-owned process being confirmed stopped first; it
  can never yield a thin success result.
- **Parent story and fix scope agree** — met: AC-5 and the FIX-2 record state
  the same member set, the same fixture count, the same absent-not-null fact and
  the same scope change as `FIX-SCOPE.md`.
- **All edits under `_bmad-output/implementation-artifacts/`** — met.
  `git diff --name-only` lists only paths under that directory.
- **`git diff --check`** — passes, exit 0, no output.

### Gate

`git diff --check` — exit 0, no output.
