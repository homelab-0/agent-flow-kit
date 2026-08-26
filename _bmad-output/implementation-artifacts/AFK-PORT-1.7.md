---
linear:
stamp: AFK-PORT-1.7.md.stamp.json
persona: dev
gates:
  - "bash tests/lifecycle-tests.sh"
  - "bash tests/run-tests.sh"
  - "git diff --check"
max_cycles: 3
---

### Story 1.7 (Spike): Persona Payload Viability on Local Profiles

As an agent-flow-kit fleet operator,
I want benchmark evidence of whether each selectable local profile can carry the full BMAD persona payload, a compact role contract, or no persona,
So that persona representation on constrained local resources becomes a deliberate, evidence-backed compatibility decision instead of a launcher shortcut or an unexamined prohibition.

This is a bounded evidence-only spike: it produces a recommendation artifact, not production code, and it records no prohibition.

**Acceptance Criteria:**

**Given** the router catalog's set of selectable local profiles
**When** the spike enumerates its benchmark matrix
**Then** every selectable local profile is covered in three persona modes — full installed BMAD persona payload, compact role contract, and no persona — plus a vendor-profile baseline captured for comparison on both Claude and Codex
**And** profiles come from the catalog as routed facts; the spike creates no routes, profiles, or catalog entries.

**Given** each profile-by-mode cell
**When** it is benchmarked
**Then** the retained evidence records persona payload tokens versus the profile's declared context window, remaining work-context headroom, and canary task quality judged against deterministic gates
**And** the evidence is machine-readable, indexed, and secret-free.

**Given** the canary tasks used for quality measurement
**When** they are defined
**Then** each declares its deterministic gate before any run and is disposable, secret-free, and free of production behavior changes
**And** quality verdicts come from the gates, not from reviewer impressions of transcripts.

**Given** spike benchmark executions
**When** they run
**Then** each is an explicit spike-class, centrally routed evaluation run with bounded spend
**And** no local substitution, metered fallback, or credential exposure occurs, and no production code or kit behavior changes.

**Given** all cells are benchmarked
**When** the spike concludes
**Then** it outputs a per-profile recommendation (`full` | `compact` | `unsuitable`) and a machine-readable threshold rule the kit can apply
**And** the recommendation artifact reaches the PM as the spike's compact result.

**Given** the persona-independence contract in `follow-on-worker-subdelegation.md`
**When** the spike's output is recorded
**Then** no prohibition is recorded and the contract is left unchanged
**And** product adoption of a compact persona representation remains a separate explicit reconciliation for which this spike is the evidence input.

**Given** the spike's place in sequencing
**When** downstream work consumes it
**Then** its output is an input to Story 1.5's sizing policy and prerequisite evidence for any subdelegation promotion
**And** the spike may run in parallel with Story 1.3 and never blocks or modifies frozen Stories 1.1–1.4.

**Given** Story 1.7 evidence
**When** the bundle is assembled
**Then** it contains the benchmark matrix definition, per-cell machine-readable results, gate inputs/outputs, the per-profile recommendations, and the threshold rule, with an index
**And** existing frozen gates remain green (the spike changes no production code, so gates prove non-interference).

**Requirements covered:** FR-118–120 and NFR-13–15 (PRD addendum `prd-addendum-1.5-1.6.md`); consumes the router catalog and central routing as read-only authority and the persona-independence contract without modifying it.

## Implementation Constraints

- Frozen PRD: _bmad-output/planning-artifacts/prds/prd-agent-flow-kit-2026-08-24/prd.md — unchanged by this story.
- Requirement authority for this story: _bmad-output/planning-artifacts/prds/prd-agent-flow-kit-2026-08-24/prd-addendum-1.5-1.6.md
- Evidence-only spike: no production code, no kit behavior change, no new routes/profiles/catalog entries, no router policy input.
- Sequencing: may run in parallel with Story 1.3; before the subdelegation follow-on (its promotion gate consumes this evidence); output feeds Story 1.5 sizing policy, which does not block on it. Not part of the frozen portability baseline or its GREEN verdict.
- Every benchmark run is centrally routed as an explicit spike-class evaluation with bounded spend; no local substitution, no metered fallback.
- Harness agnosticism (NFR-13–15): the vendor baseline runs on both Claude and Codex; benchmark harness mechanics live in per-harness adapters, and any acceptance test that exercises a harness runs on at least two approved harnesses. An adapter gap reports `NOT_EVALUATED` and never blocks the other harness's cells.
- The persona-independence contract (`follow-on-worker-subdelegation.md`, "Persona and resource independence") stands unchanged; the spike records evidence and recommendations, never a prohibition or a product decision.
- Do not broaden into router, catalog, prox-ops, Kubernetes, GPU, or control-plane product work.

## Dev Agent Record

- Status: **FROZEN — owner-approved 2026-08-26.** Stories 1.5, 1.6, 1.7 and PRD addendum FR-96–126 / NFR-13–15 frozen together. Sequenced after Story 1.4; 1.7 may run in parallel with 1.3. Outside the `AGENT-FLOW-KIT PORTABILITY GREEN` verdict.
- Implementation artifacts:
- Gates:
- Findings and resolutions:
- Final diff size:
