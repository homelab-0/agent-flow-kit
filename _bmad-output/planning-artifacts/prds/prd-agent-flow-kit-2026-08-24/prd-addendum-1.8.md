---
title: PRD Addendum — Orchestration Statusline Hook
status: frozen
baseline: post-baseline addition, frozen 2026-08-27; the frozen 95 FR / 33 AC / 12 NFR portability baseline and the frozen FR-96–126 / NFR-13–15 addendum are unchanged
created: 2026-08-27
updated: 2026-08-27
---

# PRD Addendum — Story 1.8

**Story 1.8 and PRD addendum FR-127–132 FROZEN — owner-approved 2026-08-27. Binds under frozen NFR-13–15. May start immediately against the frozen Story 1.3 schema; live-on-host acceptance waits only on the #14–#18 merge. Not gated behind Story 1.4. Outside the `AGENT-FLOW-KIT PORTABILITY GREEN` verdict. Freeze vehicle: own planning branch/PR off master (pattern of PR #13); must not merge ahead of #13.**

This addendum extends the frozen PRD (`prd.md`) and the frozen 1.5–1.7 addendum (`prd-addendum-1.5-1.6.md`) with one post-baseline capability. It does not modify any frozen FR, AC, or NFR, does not enter the `AGENT-FLOW-KIT PORTABILITY GREEN` verdict for Stories 1.1–1.4, and inherits every architecture and authority boundary of the frozen PRD unchanged. FR numbering continues from the frozen addendum's FR-126; FR-127–132 were verified unclaimed across `_bmad-output/`, `docs/`, and the `planning/afk-1.5-1.7` branch before assignment (2026-08-27). No new NFRs are introduced: the frozen harness-agnosticism NFR-13–15 bind this capability directly. All time-budget and threshold values below are accepted declared-policy defaults (owner-accepted 2026-08-27), expressed as machine-readable policy; tuning a value is a policy edit, not a requirement change.

## Capability 8: Orchestration Statusline Hook (Story 1.8)

**Problem:** live orchestration state — mode, task, phase, worker health, `NEEDS_HUMAN` — is visible only by running `status` or watching Orca. The operator already watches a terminal statusline bar (ccstatusline-style); orchestration state should render there, inline, on both approved harnesses, without adding a dashboard, a push channel, or any new authority.

### Data Source and Boundary

- **FR-127:** The statusline hook shall consume the Story 1.3 `status` machine output — the versioned FR-72–77 JSON contract — as its only data source, either by invoking the read-only `status --json` command or by reading a hook-owned cache of that command's last output. The hook is pull-only: it shall never scrape terminals or transcripts, open a push channel, subscribe to events, register a session, or write orchestration state or authority of any kind. It imposes no new output, emission, or field requirement on the frozen Story 1.3 deliverable — the frozen contract defines `status` as pure and read-only with `--json` printing the normalized document, and this capability consumes exactly that surface. The frozen Story 1.3 no-dashboard/no-push boundary stands unchanged. Bright-line dashboard boundary (owner-ruled 2026-08-27): the hook is a formatter of fields the Story 1.3 status JSON already contains — it shall not aggregate, poll multiple sources, scrape terminals, or derive state the command does not emit; crossing that line makes it a dashboard and out of scope.

### Rendered Fields

- **FR-128:** The hook shall render, inline and compact: MODE (`PLAN`|`ORCH`|`WORKER`), PERSONA, TASK (epic/story), CLI/MODEL, CONTEXT used/limit, PHASE, WORKERS (running/blocked/done), and a loud `NEEDS_HUMAN` indicator, along with a compact rendering of the frozen 1.3 orchestration bridge states (`ACTIVE`/`INACTIVE`/`NOT_AVAILABLE`). A field the status JSON reports as `NOT_EVALUATED`, and a field the consumed schema version does not carry at all, shall render `NOT_EVALUATED` — never blank, never guessed, never filled from any other source. This rule is general: ANY rendered field the shipped Story 1.3 contract does not carry renders `NOT_EVALUATED`, and no rendered field is guaranteed present by this capability — including PERSONA and CLI/MODEL, which the frozen FR-89 bounded summary exposes only "where practical" and which must be able to render `NOT_EVALUATED` like any other field. Named examples, not a closed set: CONTEXT used/limit until the Story 1.5 FR-105 context-budget field appears in the consumed schema (FR-105 is explicitly not retroactive on frozen 1.3), and worker sub-counts where the bounded summary carries only totals.

### Bounded, Non-Blocking Render

- **FR-129:** The hook shall complete every render within a declared render-time budget, and that budget is a hard ceiling, not a target: a render that would exceed it shall emit the fallback/last-known (or `UNAVAILABLE`) marker instead and shall never block the prompt. When `status` is slow, unavailable, or unusable, the hook shall degrade to last-known values — marked stale once older than a declared staleness threshold — or to an `UNAVAILABLE` marker when no usable last-known state exists. It shall never hold the bar open waiting. Budget, refresh, and staleness values shall be machine-readable declared policy with stable reason codes (accepted defaults, owner-accepted 2026-08-27: 250 ms render budget, 5 s refresh interval, 30 s staleness threshold), not code constants discoverable only by reading the implementation.

### Harness Agnosticism

- **FR-130:** Per NFR-13–15: one shared JSON-contract consumer and one shared formatter shall reference no specific CLI. Per-harness adapters — a Claude adapter and a Codex adapter — shall own each harness's statusline registration, invocation, and emission conventions. Adding a harness shall mean adding an adapter, never editing the core; a capability an adapter cannot provide reports `NOT_EVALUATED` (NFR-14) and never becomes harness-specific fallback in the core. Registration mechanics are adapter-level implementation detail and must be owner-visible and cleanly removable.

### Redaction

- **FR-131:** Hook output shall derive only from status machine-contract fields and shall follow the same redaction rules as all kit output (frozen FR-81–82): no credentials, secret values, or non-contract content. The hook-owned cache shall hold only that redacted contract output and is secret-free by construction.

### Authority and Isolation

- **FR-132:** The hook shall introduce no new routing, catalog, Orca, or BMAD authority and shall remain a read-only presentation surface. Hook failure, absence, or removal shall have zero effect on orchestration, lifecycle, or harness operation beyond a missing or degraded statusline segment — a broken hook degrades the bar, never the kit or the prompt. The hook shall never become a launch, completion, or orchestration signal source.

## Dependency and Sequencing

Requires the Story 1.3 `status` command/JSON contract to exist on the host, which lands when the #14–#18 chain merges. The hook and its adapters can be built and unit-tested now against the frozen 1.3 JSON schema and fixtures; the live-on-host render is the one acceptance step that waits on the merge. NOT gated behind Story 1.4. Outside the `AGENT-FLOW-KIT PORTABILITY GREEN` verdict. Any acceptance test that exercises a harness runs on at least two approved harnesses (NFR-15).

## Explicit Non-Goals

- No change to any frozen FR, AC, NFR, to the Stories 1.1–1.4 acceptance track or its GREEN verdict, or to the frozen 1.5–1.7 addendum.
- No dashboard, terminal scraper, push channel, event subscription, session registry, or fleet view — the frozen Story 1.3 boundary stands. No aggregation, multi-source polling, or derivation of state the `status` command does not emit: the hook is a formatter of existing status-JSON fields, and crossing that line makes it a dashboard and out of scope (owner-ruled 2026-08-27).
- No new router, catalog, Orca, BMAD, or native-runtime authority; no routing-input changes.
- No retroactive requirement on frozen Story 1.3: absent fields render `NOT_EVALUATED`; widening the bounded summary is a separate post-1.3 additive change through normal planning.
- No context-usage measurement by the hook itself: CONTEXT renders only what the consumed schema carries (Story 1.5's field, when it lands).
