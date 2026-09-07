---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-PORT-1.5B.md.stamp.json
persona: dev
gates:
  - "bash tests/run-tests.sh"
  - "bash tests/lifecycle-readiness-tests.sh"
  - "bash tests/lifecycle-tests.sh"
  - "git diff --check"
max_cycles: 3
---

# AFK-PORT-1.5B — Usage observation, checkpoint and continuation artifacts, budget state

Lane B of four for the frozen Story 1.5 (`AFK-PORT-1.5.md`; authority: PRD
addendum Capability 5, FR-99 evaluation, FR-100, FR-101, FR-104, FR-105;
NFR-13–15). Lane A (merged, PR #30) provides the window, the sizing estimate,
the policy file with `checkpoint_ratio`, `continuation_ratio` and the budget
states declared, and the `budget` thin-result member. Lane C (continuation
dispatch, cap) and lane D (ORCH PM budget) follow; leave documented seams,
not implementations.

Budget for this lane INCLUDING tests and prose: ≤ 800 reviewable lines. Scope
was cut to fit; if you cannot fit, stop and disclose rather than absorb.

## Design ruling (coordinator, binding for this lane)

The frozen launch command texts stay byte-identical: no `stream-json` for
claude, no `--json` for codex. Consequences, all consistent with FR-104:
- Under `claude -p`, usage is observable only from the END-OF-RUN result
  envelope (`modelUsage[<model>]` and `usage`). Mid-run usage is
  `NOT_EVALUATED`. The harness adapter reports what it can, with provenance.
- Under `codex exec` without `--json`, usage is not observable at all: the
  codex adapter reports `NOT_EVALUATED` / `USAGE_UNOBSERVABLE`. It never
  becomes core fallback logic and never blocks the claude path.
- Mid-run checkpoint/continuation discipline is therefore DETERMINISTIC
  PHASE-BOUNDARY POLICY carried in the generated prompt: the worker
  checkpoints at declared boundaries regardless of usage, and stops with a
  continuation artifact at the next boundary when it judges it cannot finish
  or when the harness signals context pressure. The kit evaluates observed
  usage after the run and reconciles it with the worker's signal.

## Scope

**S1 — usage adapters (FR-104, NFR-13).** In `dispatch.sh`, a per-harness
usage reader: `claude` reads the retained result envelope and yields
`usage_tokens` (the last turn's `input_tokens + cache_read_input_tokens +
cache_creation_input_tokens` from `usage`, i.e. the context actually held at
the last request), `window_tokens` (`modelUsage[<model>].contextWindow`, used
ONLY as corroboration — the budget window remains the catalog's per lane A;
disagreement is recorded, never resolved by the kit), `provenance:
HARNESS_ENVELOPE`, `observed_at: END_OF_RUN`. `codex` yields
`NOT_EVALUATED` / `USAGE_UNOBSERVABLE`. No terminal or transcript reading.
Adapters are named functions per harness; the core calls one interface.

**S2 — post-run evaluation (FR-99).** With a catalog window and an observed
usage, `usage_ratio = usage/window` (parts per million, same arithmetic as
lane A) against the policy's `checkpoint_ratio` and `continuation_ratio`:
`budget.state` = `OK` | `CHECKPOINT_DUE` | `CONTINUATION_REQUIRED`, with
`budget.usage_tokens`, `budget.usage_ratio`, `budget.usage_provenance`,
`budget.observed_at`. Unobservable or undeclared → `NOT_EVALUATED` with the
reason (`USAGE_UNOBSERVABLE` / `CONTEXT_WINDOW_UNDECLARED`). A ratio at or
above the checkpoint threshold at end of run adds finding `HIGH_USAGE` to
`budget.findings` (the PM's story-sizing signal, FR-105).

**S3 — worker discipline in the prompt (FR-100, FR-101, FR-104 fallback).**
The generated prompt gains a fixed, launcher-owned paragraph (data, never
shell) naming: the checkpoint artifact path `<story>.checkpoint.json`, its
required members (`completed`, `current_state`, `remaining_acceptance`,
`next_steps`, `updated_at`, `schema: afk-checkpoint/1`), the declared phase
boundaries at which it MUST be written or refreshed (after reading the story;
after implementation and before gates; before reporting), the continuation
artifact path `<story>.continuation.json` (`schema: afk-continuation/1`;
checkpoint members plus `in_flight` and `unretired_findings`), and the rule:
if you cannot finish, stop at the next boundary, write the continuation
artifact, and print one line `CONTINUATION-REQUIRED: <one-line reason>` then
end your turn. Both artifacts are secret-free by rule and are redacted by the
kit's existing redaction on read (S4).

**S4 — artifact handling (FR-100, FR-101, FR-105).** After the run, the
launcher validates any present checkpoint/continuation artifact (schema id,
required members, JSON parse) through the same redaction rules as other
lifecycle output (the existing sentinel discipline applies: a secret-looking
value is never echoed into a result or log). A `CONTINUATION-REQUIRED:` line
with a valid artifact → `budget.state: CONTINUATION_REQUIRED`, thin-result
`status: continuation_required` (additive within the result schema major),
`budget.continuation_artifact` = path + sha256, and the story record gains
one dated line (locked, idempotent per cycle, reusing lane A's append).
A `CONTINUATION-REQUIRED:` line with a MISSING or UNPARSEABLE artifact → the
story enters loud `NEEDS_HUMAN` (`.blocked` marker, reason
`CONTINUATION_ARTIFACT_INVALID`, the existing needs-human exit) and no
result claims completion. Observed usage ≥ continuation threshold with gates
failed and no worker signal → `budget.state: CONTINUATION_REQUIRED` and
`status: continuation_required` as well (the kit never reports headroom it
cannot see, and never manufactures a completed result). Actual continuation
DISPATCH is lane C: this lane only produces the signal and the artifact.

**S5 — budget field on the kit's own state (FR-105).** The dispatch monitor's
watch record and the `status` rendering gain a bounded `context_budget`
member per watched dispatch (`OK` | `CHECKPOINT_DUE` | `CONTINUATION_REQUIRED`
| `NOT_EVALUATED`) sourced from the retained thin result on reconcile; the
contract documents it as introduced here with no retroactive requirement on
the frozen 1.3 deliverable. `NEEDS_HUMAN` for an invalid continuation
artifact surfaces through the existing monitor path.

**S6 — contract, schema, docs.** `docs/LIFECYCLE-CONTRACT.md` `## The context
budget` extended: adapters and provenance, phase boundaries, artifact
schemas, the two new statuses/reasons (`continuation_required`,
`CONTINUATION_ARTIFACT_INVALID`, `USAGE_UNOBSERVABLE`, `HIGH_USAGE`), the
`context_budget` watch member; reason codes added to the policy file's
declared list; `SKILL.md` one paragraph. Every sentence true of the code.

**S7 — tests (both harnesses).** `tests/run-tests.sh`: claude envelope
fixtures at ratios below/at/above both thresholds (boundary equality counts
as crossing); codex → `NOT_EVALUATED`; window disagreement recorded; the
prompt paragraph present and byte-stable; valid checkpoint accepted; invalid
or missing continuation artifact → `NEEDS_HUMAN` marker, no result claiming
done; valid continuation → `continuation_required` status + record line
(idempotent); redaction: a sentinel inside an artifact never reaches result,
log or marker; both frozen launch texts byte-identical (existing oracle).
`tests/lifecycle-dispatch-tests.sh`: watch record carries `context_budget`
after reconcile; `NEEDS_HUMAN` surfaces. `tests/lifecycle-readiness-tests.sh`:
`schema` lists the new status/reasons.

## Out of scope — hard stops

Continuation dispatch, the cap and its PM decision (lane C); the ORCH PM
budget (lane D); Story 1.6 registry codes beyond the reason-code discipline;
any change to the frozen launch command texts, `make-stamp.sh`, the
validator, the catalog, `/v1/route` requests; terminal or transcript reading;
retrofitting the frozen 1.3 orchestration document.

## Acceptance criteria

- **AC-1** claude usage from the envelope with provenance; codex
  `NOT_EVALUATED`; no scraping (S1, tests).
- **AC-2** post-run state from policy thresholds with boundary equality
  crossing; `HIGH_USAGE` finding at ≥ checkpoint (S2, tests).
- **AC-3** prompt paragraph names artifacts, members, boundaries and the
  stop rule; byte-stable; data never shell (S3, tests).
- **AC-4** valid continuation → `continuation_required` status, artifact
  identity recorded, story-record line; invalid/missing → loud `NEEDS_HUMAN`;
  never a manufactured completion (S4, tests).
- **AC-5** artifacts pass the kit's redaction; sentinel proof (S4, tests).
- **AC-6** `context_budget` on the watch record and `status` rendering;
  additive, no 1.3 retrofit (S5, tests).
- **AC-7** contract/schema/docs true of the code; policy reason list extended
  (S6).
- **AC-8** both harnesses exercised; frozen launch texts byte-identical (S7).
- **AC-9** gates green (concurrency aggregate the only tolerated red);
  reviewable diff ≤ 800 lines INCLUDING tests and docs, reported; record
  states seams left for lanes C/D.

## Dev Agent Record

(worker fills in)
