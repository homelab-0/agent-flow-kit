---
linear:
stamp: AFK-PORT-1.8.md.stamp.json
persona: dev
gates:
  - "bash tests/lifecycle-tests.sh"
  - "bash tests/run-tests.sh"
  - "git diff --check"
max_cycles: 3
---

### Story 1.8: Orchestration Statusline Hook

As an agent-flow-kit fleet operator,
I want live orchestration state rendered inline in the terminal statusline bar I already watch, on both Claude and Codex,
So that mode, task, phase, worker health, and loud `NEEDS_HUMAN` are visible without opening a dashboard, polling a command, or leaving the prompt.

**Acceptance Criteria:**

**Given** the statusline hook needs orchestration state
**When** it acquires data
**Then** its only data source is the Story 1.3 `status` machine output — the versioned FR-72–77 JSON contract — obtained by invoking the read-only `status --json` command or by reading a hook-owned cache of that command's last output
**And** it never scrapes terminals or transcripts, opens a push channel, subscribes to events, registers a session, or writes orchestration state or authority of any kind, and it imposes no new output, emission, or field requirement on the frozen Story 1.3 deliverable.

**Given** the status JSON carries orchestration state
**When** the hook renders
**Then** it renders, inline and compact: MODE (`PLAN`|`ORCH`|`WORKER`), PERSONA, TASK (epic/story), CLI/MODEL, CONTEXT used/limit, PHASE, WORKERS (running/blocked/done), and a loud `NEEDS_HUMAN` indicator
**And** the frozen 1.3 orchestration bridge states (`ACTIVE`/`INACTIVE`/`NOT_AVAILABLE`) render compactly rather than being suppressed.

**Given** a field the status JSON reports as `NOT_EVALUATED`, or a field the consumed schema version does not carry at all
**When** the hook renders that field
**Then** it renders `NOT_EVALUATED` — never blank, never guessed, never filled from any other source
**And** this rule is general: ANY rendered field the shipped Story 1.3 contract does not carry renders `NOT_EVALUATED`, no rendered field is guaranteed present — including PERSONA and CLI/MODEL, which the frozen FR-89 bounded summary exposes only "where practical" — and the named examples (CONTEXT used/limit until the Story 1.5 FR-105 field appears in the consumed schema; worker sub-counts where the bounded summary carries only totals) are examples, not the closed set.

**Given** the `status` source is slow, unavailable, or returns unusable output
**When** the harness requests a statusline render
**Then** the hook completes within its declared render-time budget by rendering last-known values (marked stale once older than the declared staleness threshold) or an `UNAVAILABLE` marker when no usable last-known state exists
**And** the render budget is a hard ceiling: a render that would exceed it emits the fallback/last-known marker instead and never blocks the prompt; the hook never holds the bar open waiting, and all budget/threshold values are machine-readable declared policy with stable reason codes (accepted defaults, owner-accepted 2026-08-27: 250 ms render budget, 5 s refresh interval, 30 s staleness threshold).

**Given** the harness-agnosticism NFRs (NFR-13–15)
**When** the hook is structured
**Then** one shared JSON-contract consumer and one shared formatter reference no specific CLI, and per-harness adapters — a Claude adapter and a Codex adapter — own each harness's statusline registration, invocation, and emission conventions
**And** adding a harness means adding an adapter, never editing the core; a capability an adapter cannot provide reports `NOT_EVALUATED` per NFR-14 and never becomes harness-specific fallback in the core.

**Given** the same-redaction rule for all kit output
**When** hook output is produced
**Then** it derives only from status machine-contract fields and follows the frozen FR-81–82 redaction rules — no credentials, secret values, or non-contract content
**And** the hook-owned cache holds only that redacted contract output and is secret-free by construction.

**Given** the hook fails, is absent, or is removed
**When** orchestration, lifecycle, or harness operation proceeds
**Then** the only effect is a missing or degraded statusline segment — a broken hook degrades the bar, never the kit, the prompt, or any orchestration behavior
**And** the hook introduces no new routing, catalog, Orca, or BMAD authority and remains a read-only presentation surface.

**Given** the Story 1.3 `status` command is not yet installed on the host (the #14–#18 chain has not merged)
**When** Story 1.8 is built and tested
**Then** the shared consumer, formatter, and both adapters are built and unit-tested against the frozen Story 1.3 machine-contract JSON schema and fixtures, including `NOT_EVALUATED`, stale, `UNAVAILABLE`, `NEEDS_HUMAN`, and bridge-state renders
**And** the live-on-host render is the one acceptance step that waits on the chain's merge, running the moment the 1.3 chain is installed on a host.

**Given** Story 1.8 acceptance tests that exercise a harness
**When** they run
**Then** they run on at least two approved harnesses (Claude and Codex) per NFR-15
**And** existing frozen gates remain green.

**Requirements covered:** FR-127–132 (PRD addendum `prd-addendum-1.8.md`) and NFR-13–15 (PRD addendum `prd-addendum-1.5-1.6.md`); consumes the frozen Story 1.3 status machine contract (FR-72–77, FR-81–84, FR-88–89) as read-only authority without modifying it.

## Implementation Constraints

- Frozen PRD: _bmad-output/planning-artifacts/prds/prd-agent-flow-kit-2026-08-24/prd.md — unchanged by this story.
- Requirement authority for this story: _bmad-output/planning-artifacts/prds/prd-agent-flow-kit-2026-08-24/prd-addendum-1.8.md; NFR-13–15 from prd-addendum-1.5-1.6.md bind unchanged.
- **Dependency, stated plainly:** this story requires the Story 1.3 `status` command/JSON contract to exist on the host, which lands when the #14–#18 chain merges. The hook and its adapters can be built and unit-tested now against the frozen 1.3 JSON schema and fixtures; the live-on-host render is the one step that waits on the merge.
- Sequencing: may start immediately (against the 1.3 schema); live acceptance runs the moment the 1.3 chain is installed on a host. NOT gated behind Story 1.4. Outside the `AGENT-FLOW-KIT PORTABILITY GREEN` verdict.
- Freeze vehicle (owner-decided 2026-08-27): separate planning branch off master with its own PR, same pattern as PR #13 — not folded into any ORCH stack. The epics block depends on PR #13 being on master; this PR must not merge ahead of #13.
- Pull-only: no push channel, no session registry, no terminal scraping, no dashboard — the frozen Story 1.3 no-dashboard/no-push boundary (`AFK-PORT-1.3.md` regression contract) stands unchanged.
- **Bright-line dashboard boundary (owner-ruled 2026-08-27, T-1.8-11):** the hook is a formatter of fields the Story 1.3 status JSON already contains — it may not aggregate, poll multiple sources, scrape terminals, or derive state the command does not emit. Crossing that line makes it a dashboard and out of scope.
- No new routing, catalog, Orca, or BMAD authority; no routing-input changes; the hook never becomes a launch, completion, or orchestration signal source.
- Field availability is bounded by what the shipped 1.3 machine contract carries (FR-89 exposes worker counts "where practical"); absent fields render `NOT_EVALUATED`. Widening the bounded summary is a post-1.3 additive change through normal planning — never a retroactive requirement on frozen 1.3.
- Harness statusline registration mechanics (Claude statusline configuration, Codex equivalent) are adapter-level implementation detail under NFR-13; registration must be owner-visible and cleanly removable.
- Do not broaden into router, catalog, prox-ops, Kubernetes, GPU, or control-plane product work.

## Dev Agent Record

- Status: **FROZEN — owner-approved 2026-08-27.** Story 1.8 and PRD addendum FR-127–132 frozen together; binds under frozen NFR-13–15. May start immediately against the frozen Story 1.3 schema; live-on-host acceptance waits only on the #14–#18 merge. Not gated behind Story 1.4. Outside the `AGENT-FLOW-KIT PORTABILITY GREEN` verdict. Rulings T-1.8-1–3 and T-1.8-11 owner-confirmed, policy defaults (250 ms / 5 s / 30 s) owner-accepted, FR-128 generalized in freeze review round 1 — all 2026-08-27.
- Implementation artifacts:
- Gates:
- Findings and resolutions:
- Final diff size:
