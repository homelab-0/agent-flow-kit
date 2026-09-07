---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-PORT-1.5A.md.stamp.json
persona: dev
gates:
  - "bash tests/run-tests.sh"
  - "bash tests/lifecycle-readiness-tests.sh"
  - "bash tests/lifecycle-tests.sh"
  - "git diff --check"
max_cycles: 3
---

# AFK-PORT-1.5A — Context window as routed fact, and pre-dispatch sizing policy

Lane A of four for the frozen Story 1.5 (`AFK-PORT-1.5.md`). The four lanes
together cover Story 1.5's total approved scope; this lane covers FR-96,
FR-97, FR-98 and the declaration half of FR-99 (thresholds as machine-readable
policy). Lanes B (usage observation, checkpoint/continuation artifacts, budget
state field), C (continuation dispatch and its cap) and D (the ORCH PM's own
budget) follow. Nothing in this lane may pre-empt their design; where this
lane must leave a hook, it leaves a documented seam, not an implementation.

Requirement authority: `_bmad-output/planning-artifacts/prds/prd-agent-flow-kit-2026-08-24/prd-addendum-1.5-1.6.md`
(Capability 5, FR-96–99; NFR-13–15). Read the frozen story file and the
addendum before writing code. Do not modify `AFK-PORT-1.5.md`.

## Scope

**S1 — the window is a routed fact (FR-96).** At dispatch, resolve the routed
profile's context window from the stamp's `model_profile` against the
launcher's trusted catalog, which the frozen validation has already proven
matches the stamp's `catalog_version` digest. The value is the catalog's
`min_context` for that profile, read exactly, never derived, extended, or
substituted. Expose it in the thin result under a new `budget` member:
`window_tokens`, `window_source: "CATALOG"`. A profile that declares no
`min_context` yields `budget.state: "NOT_EVALUATED"`,
`budget.reason: "CONTEXT_WINDOW_UNDECLARED"`, `window_tokens: null`, and
dispatch proceeds — the kit never invents a window and reports no budget
health it cannot ground. (Today `claude/strong` declares none; that is the
honest catalog state, already registered as a catalog gap.) The existing
gateway-class requirement that `CLAUDE_CODE_MAX_CONTEXT_TOKENS` be catalog-
derived is unchanged and unrelated to this member.

**S2 — deterministic sizing estimate (FR-97).** Before any launch, compute the
planned payload size from exactly these inputs, in this order, each counted
once by byte length: the persona file (if stamped), the story file, the
generated prompt file, and every path listed under an optional story
frontmatter key `payload_refs:` (repo-relative; a listed path that does not
exist is a refusal with reason `PAYLOAD_REF_MISSING`). Convert bytes to tokens
with the method declared in the policy file (accepted initial method id
`bytes4-v1`: `ceil(bytes / 4)`). Record `budget.estimate_tokens`,
`budget.estimate_method`, `budget.estimate_ratio` (estimate / window, null
when the window is undeclared) in the thin result. The estimate is advisory
kit policy: it is never written into a `/v1/route` request, never changes
route selection, and `make-stamp.sh` is not touched.

**S3 — machine-readable policy (FR-98, FR-99 declaration).** Add
`files/model-router/context-budget-policy.yaml` as launcher configuration
(installed with the kit, never read from a story or a stamp; env override
`AGENT_FLOW_BUDGET_POLICY` for tests), declaring: `sizing_risk_ratio: 0.60`,
`checkpoint_ratio: 0.70`, `continuation_ratio: 0.85`, `continuation_cap: 2`,
`estimate_method: bytes4-v1`, and the stable reason codes this lane and the
later lanes use (`CONTEXT_WINDOW_UNDECLARED`, `SIZING_REFUSED`, `SIZING_RISK`,
`PAYLOAD_REF_MISSING`, `BUDGET_POLICY_UNREADABLE`, plus the lane-B/C states
`OK`, `CHECKPOINT_DUE`, `CONTINUATION_REQUIRED`, `NOT_EVALUATED` declared but
only `OK`/`NOT_EVALUATED` produced here). An unreadable or incomplete policy
file refuses dispatch (`BUDGET_POLICY_UNREADABLE`, config exit code) — a
missing threshold is not a default.

**S4 — pre-dispatch actions (FR-98).** With a declared window:
`estimate_ratio >= continuation_ratio` refuses dispatch fail-closed with a new
distinct exit code (`EX_SIZING_REFUSED=8`), writes a `.blocked` marker typed
`STORY-SIZING:` naming estimate, window, ratio, threshold and the inputs
counted, and creates no placement, terminal, command or result artifact. The
refusal runs after the setup-policy gate and BEFORE `/v1/place`, stamp
validation and the launch guard: it is a planning outcome and must not
consume a placement. `sizing_risk_ratio <= ratio < continuation_ratio`
proceeds and records `SIZING_RISK` in `budget.findings` of the thin result AND
as one dated line appended under the story file's `## Dev Agent Record`
heading (`- budget: SIZING_RISK <estimate>/<window> (<ratio>) cycle <n>
<iso-time>`), idempotent per cycle. With an undeclared window neither action
can fire; `budget.state` is `NOT_EVALUATED` and `budget.findings` is empty.

**S5 — contract, schema, docs.** `docs/LIFECYCLE-CONTRACT.md` gains a
`budget` section describing the thin-result member, the policy file, the
estimate method and the reason codes, under the FR-72–77 stable-code
discipline (additive within the result schema major). The `schema` verb lists
the four budget states. `files/model-router/SKILL.md` gets one paragraph on
the sizing outcome and the `payload_refs:` key. Every sentence true of the code.

**S6 — tests (harness-agnostic where the harness matters).** In
`tests/run-tests.sh`: pure tests for the estimate (same inputs → same number;
the documented method; each input counted once; missing ref refuses) and for
threshold arithmetic at the exact boundaries (ratio equal to a threshold
counts as crossing it); integration cases against the stubbed chain for: a
declared window carried into the result; an undeclared window →
`NOT_EVALUATED` with the reason and no findings; refusal at ≥ 0.85 (exit 8,
typed marker, no `/v1/place` call, no terminal, no command, no result); risk
band → proceeds, finding in result and in the story record, second cycle does
not duplicate the line; policy file unreadable → config exit before anything;
and the same window/estimate behaviour on BOTH launch classes (native
`claude/strong` fixture given a stub `min_context` in the test catalog, and
the gateway `local-code-standard` fixture) and on the `codex` harness.
Assert `make-stamp.sh`'s request body still carries no `context_size` when
the story has a sizing estimate. In `tests/lifecycle-readiness-tests.sh`:
the `schema` output lists the budget states.

## Out of scope — hard stops

Usage observation of any kind; checkpoint or continuation artifacts;
continuation dispatch, the continuation cap's enforcement, or `NEEDS_HUMAN`
on continuation failure (lanes B/C); the ORCH PM's budget (lane D); the
Story 1.6 escalation registry; any change to `/v1/route` requests,
`make-stamp.sh`, the validator, the catalog, or the frozen launch command
texts (both classes must stay byte-identical — the existing byte-identity
assertions are your oracle); reading transcripts or terminals.

## Acceptance criteria

- **AC-1** window carried from the catalog exactly; undeclared →
  `NOT_EVALUATED`/`CONTEXT_WINDOW_UNDECLARED`; never derived (S1, tests).
- **AC-2** estimate deterministic, documented, inputs enumerated, ratio
  recorded; `payload_refs:` honoured; missing ref refuses (S2, tests).
- **AC-3** policy file is the only source of thresholds and method; unreadable
  policy refuses before anything else; no threshold is a code constant (S3).
- **AC-4** refusal at ≥ continuation threshold: exit 8, `STORY-SIZING:` marker,
  before `/v1/place`, nothing created (S4, tests).
- **AC-5** sizing-risk band: dispatch proceeds; finding in result and story
  record; idempotent (S4, tests).
- **AC-6** route requests unchanged: no `context_size`, no capacity input
  (S2, test on `make-stamp.sh`).
- **AC-7** both launch classes and both harnesses exercised; launch command
  texts byte-identical to before (S6).
- **AC-8** contract, schema and skill doc true of the code (S5).
- **AC-9** all four gates green (the `run-tests.sh` concurrency aggregate is a
  recorded pre-existing host flake — report it verbatim; it is the only
  tolerated red); diff ≤ 800 reviewable lines / ≤ 25 files; Dev Agent Record
  states method choices, files, tallies, diff size, deferrals.

## Dev Agent Record

(worker fills in)
