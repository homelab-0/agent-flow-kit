# Epics.md block — Story 1.8 (integration note)

**Story 1.8 and PRD addendum FR-127–132 FROZEN — owner-approved 2026-08-27.** This file is the staging source for the epics.md integration: the block below appends to `_bmad-output/planning-artifacts/epics.md` immediately after the Story 1.7 block inside the existing "Post-Baseline Additions" section (which currently lives on `planning/afk-1.5-1.7`, PR #13 — this checkout's epics.md predates that block). Additionally, one line is added to that section's "Post-Baseline FR Coverage" list:

```
FR-127–132: Story 1.8 - Orchestration Statusline Hook
```

All frozen text — the baseline above the post-baseline heading and the frozen 1.5–1.7 blocks — remains byte-identical. Everything below the rule is the block verbatim.

---

### Story 1.8: Orchestration Statusline Hook

**Story 1.8 and PRD addendum FR-127–132 FROZEN — owner-approved 2026-08-27. Binds under frozen NFR-13–15. May start immediately against the frozen Story 1.3 schema; live-on-host acceptance waits only on the #14–#18 merge. Not gated behind Story 1.4. Outside the `AGENT-FLOW-KIT PORTABILITY GREEN` verdict.**

As an agent-flow-kit fleet operator,
I want live orchestration state rendered inline in the terminal statusline bar I already watch, on both Claude and Codex,
So that mode, task, phase, worker health, and loud `NEEDS_HUMAN` are visible without opening a dashboard, polling a command, or leaving the prompt.

Summary of scope (full acceptance criteria in `_bmad-output/implementation-artifacts/AFK-PORT-1.8.md`):

- The hook's only data source is the frozen Story 1.3 `status` machine output (the FR-72–77 versioned JSON contract), obtained by invoking the read-only `status --json` command or reading a hook-owned cache of its last output. Pull-only: no terminal scraping, no push channel, no event subscription, no session registry, no orchestration writes — the frozen 1.3 no-dashboard/no-push boundary stands unchanged, and no new output, emission, or field requirement lands on frozen 1.3. Bright-line boundary (owner-ruled 2026-08-27): the hook is a formatter of fields the status JSON already contains — no aggregation, no multi-source polling, no deriving state the command does not emit; crossing that line makes it a dashboard and out of scope.
- Renders inline and compact: MODE (`PLAN`|`ORCH`|`WORKER`), PERSONA, TASK (epic/story), CLI/MODEL, CONTEXT used/limit, PHASE, WORKERS (running/blocked/done), loud `NEEDS_HUMAN`, and the 1.3 bridge states (`ACTIVE`/`INACTIVE`/`NOT_AVAILABLE`). Fields reported `NOT_EVALUATED` render `NOT_EVALUATED`, never blank or guessed — and the rule is general: ANY field the shipped 1.3 contract does not carry renders `NOT_EVALUATED`, no field is guaranteed present (PERSONA and CLI/MODEL are FR-89 "where practical" fields like any other), with CONTEXT until Story 1.5's FR-105 field lands and worker sub-counts beyond the bounded summary as named examples, not the closed set.
- Bounded and non-blocking: the declared render-time budget is a hard ceiling — a render that would exceed it emits the fallback/last-known marker instead and never blocks the prompt; slow/unavailable `status` degrades to last-known values with a staleness marker or an `UNAVAILABLE` marker; the hook never holds the bar open. Accepted declared-policy defaults (owner-accepted 2026-08-27): 250 ms render budget, 5 s refresh, 30 s staleness.
- Harness-agnostic per NFR-13–15: one shared JSON-contract consumer and formatter referencing no CLI; Claude and Codex adapters own registration/invocation/emission; adding a harness = adding an adapter. Adapter gaps report `NOT_EVALUATED`, never core fallback. Harness-exercising acceptance tests run on both approved harnesses.
- Secret-free: output derives only from status contract fields under the frozen FR-81–82 redaction rules; the hook-owned cache is secret-free by construction.
- No new routing, catalog, Orca, or BMAD authority; read-only presentation only. A broken, absent, or removed hook degrades the bar, never the kit, the prompt, or orchestration.
- Dependency, stated plainly: requires the Story 1.3 `status` command/JSON contract on the host, landing when the #14–#18 chain merges. Buildable and unit-testable now against the frozen 1.3 schema and fixtures; the live-on-host render is the one step that waits. NOT gated behind Story 1.4; outside the `AGENT-FLOW-KIT PORTABILITY GREEN` verdict.

**Requirements covered:** FR-127–132 (PRD addendum `prds/prd-agent-flow-kit-2026-08-24/prd-addendum-1.8.md`) and NFR-13–15 (frozen addendum); consumes the frozen Story 1.3 status machine contract (FR-72–77, FR-81–84, FR-88–89) as read-only authority without modifying it.
