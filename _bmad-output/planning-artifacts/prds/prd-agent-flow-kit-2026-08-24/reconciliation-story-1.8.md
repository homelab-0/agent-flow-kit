# Reconciliation Report — Story 1.8 (Orchestration Statusline Hook) vs Frozen Scope

Produced 2026-08-27 in an interactive PLAN session. Interactive planning only: no activation, no dispatch, nothing frozen. Freeze is the owner's call.

## Verdict

No frozen requirement was changed. Story 1.8 is a post-baseline addition that consumes the frozen Story 1.3 status machine contract and the frozen NFR-13–15 harness-agnosticism NFRs without modifying either. Every deliverable in this session is a new file; no pre-existing frozen file was edited. Three interpretation rulings were made during drafting — each resolved *away from* frozen scope — and all owner rulings are recorded below.

**Story 1.8 and PRD addendum FR-127–132 FROZEN — owner-approved 2026-08-27. Binds under frozen NFR-13–15. May start immediately against the frozen Story 1.3 schema; live-on-host acceptance waits only on the #14–#18 merge. Not gated behind Story 1.4. Outside the `AGENT-FLOW-KIT PORTABILITY GREEN` verdict.**

## Owner Rulings Recorded (2026-08-27)

1. **T-1.8-1 confirmed:** hook-owned cache; no Story 1.3 state-file emission. Accepted as drafted.
2. **T-1.8-2 confirmed:** CONTEXT renders `NOT_EVALUATED` until Story 1.5's FR-105 field ships in the consumed schema. Accepted as drafted.
3. **T-1.8-3 confirmed:** summary fields absent from the shipped 1.3 contract render `NOT_EVALUATED`. Accepted as drafted.
4. **T-1.8-11 ruled IN-BOUNDS**, with a bright-line constraint added to the story and addendum: the hook is a formatter of fields the 1.3 status JSON already contains — it may not aggregate, poll multiple sources, scrape terminals, or derive state the command does not emit. Crossing that line makes it a dashboard and out of scope.
5. **Policy defaults accepted** (250 ms render budget / 5 s refresh / 30 s staleness), and strengthened from value to requirement in FR-129: the render budget is a hard ceiling — on exceeding it the hook emits a fallback/last-known marker and never blocks the prompt.
6. **Freeze vehicle decided:** a separate planning branch off master with its own PR, same pattern as PR #13 — not folded into any ORCH stack. The epics block depends on PR #13 being on master; this PR must not merge ahead of #13.

## Inputs and Authority

- Frozen PRD: `prd.md` (95 FR / 33 AC / 12 NFR, baseline frozen)
- Frozen Story 1.3 spec: `_bmad-output/implementation-artifacts/AFK-PORT-1.3.md` (status surface, machine contract, no-dashboard boundary, bridge states)
- Frozen 1.5–1.7 addendum: `prd-addendum-1.5-1.6.md` (FR-96–126, NFR-13–15, owner-approved 2026-08-26)
- Frozen lifecycle contract: `docs/LIFECYCLE-CONTRACT.md` (`status` purity, `--json` rendering)
- Story 1.3 delivery vehicle: the #14–#18 PR chain (per owner statement 2026-08-27)

FR numbering: FR-127–132 verified unclaimed across `_bmad-output/`, `docs/`, and the `planning/afk-1.5-1.7` branch before assignment (2026-08-27). No new NFRs introduced; NFR-13–15 bind directly.

## Freeze Review Round 1 (2026-08-27) — one owner edit applied

1. **FR-128 and the matching AC generalized:** the `NOT_EVALUATED` rule is general — ANY field the shipped Story 1.3 contract does not carry renders `NOT_EVALUATED`, and no rendered field is guaranteed present, including PERSONA and CLI/MODEL (FR-89 "where practical" fields). CONTEXT and worker sub-counts are named examples, not the closed set. Applied to `prd-addendum-1.8.md` (FR-128), `AFK-PORT-1.8.md` (AC 3), and `epics-block-1.8.md`.
2. **Frontmatter confirmed:** the empty `linear:` in `AFK-PORT-1.8.md` is intentional — the epic is local-homed under `_bmad-output/`, and local-homed story frontmatter carries an empty `linear:` (same as frozen `AFK-PORT-1.3.md`–`1.7.md`); no Linear artifacts are created for it.

Everything else in both documents accepted as presented. The owner read the full T-1.8-1–11 touchpoint set and declared the freeze the same day.

## Interpretation Rulings (drafting rationale — owner-confirmed 2026-08-27, see rulings above)

1. **T-1.8-1 — "emitted state file" = hook-owned cache, not a 1.3 emission.** The intent statement offered "invokes the command (or reads its emitted state file)". Verified against the frozen contract: `docs/LIFECYCLE-CONTRACT.md` defines `status` as pure/read-only with `--json` *printing* the normalized document — no persistent emitted state file exists in the frozen 1.3 surface. Requiring one would be a retroactive requirement on frozen 1.3. FR-127 therefore reads the fast path as a **hook-owned cache of the last `status --json` output**, imposing nothing on 1.3. If the owner instead wants `status` to emit a state file, that is a separate post-1.3 additive change requiring its own reconciliation — not part of Story 1.8 as drafted.
2. **T-1.8-2 — CONTEXT used/limit sources from Story 1.5's field, renders `NOT_EVALUATED` until then.** The frozen 1.3 bounded summary (FR-89; `AFK-PORT-1.3.md` orchestration-bridge AC) carries no context-usage field; FR-105 (frozen addendum) introduces the context-budget field in Story 1.5 and is explicitly "not retroactively required of the frozen Story 1.3 deliverable." FR-128 renders CONTEXT from the consumed schema when present and `NOT_EVALUATED` otherwise. No retrofit to 1.3; no measurement by the hook itself.
3. **T-1.8-3 — field availability is bounded by the shipped 1.3 contract.** FR-89 exposes "already-available worker counts where practical"; the frozen bounded summary names state/mode/phase/task/needs-human/worker-counts, while PERSONA, CLI/MODEL, and running/blocked/done sub-counts depend on what the shipped machine contract carries (FR-88 preserves persona/task/route/phase/gate data in orchestration state, but the summary's exact field set is implementation-level under the frozen contract). Discipline: the hook renders what the schema carries; absent fields render `NOT_EVALUATED`; widening the bounded summary is a post-1.3 additive change through normal planning, never a Story 1.8 requirement on frozen 1.3.

## Touchpoints Against Frozen Scope

| # | Frozen surface | Story 1.8 relationship | Verdict |
|---|---|---|---|
| T-1.8-4 | Story 1.3 no-dashboard boundary: "no dashboard, terminal scraper, router session registry, or broader control-plane feature" (`AFK-PORT-1.3.md`) | The hook is a pull-only render of the existing bounded read-only summary inside the operator's existing terminal bar: no registry, no push, no scrape, no new pane or process holding state authority | Consistent — boundary stands unchanged (FR-127, non-goals) |
| T-1.8-5 | FR-72–77 machine contract: versioned schema, stable codes, no prose parsing | The hook is a schema-consuming automation client: it parses machine output only, tolerates schema versioning, and distinguishes evaluated-false / out-of-scope / unavailable / not-performed per FR-73 | Consumes unchanged (FR-127, FR-128) |
| T-1.8-6 | FR-81–82 redaction; NFR-5 | Hook output and cache derive only from already-redacted contract fields | Inherits unchanged (FR-131) |
| T-1.8-7 | FR-83–84 offline default / `NOT_EVALUATED` | The hook's `NOT_EVALUATED`-never-guess render discipline is the presentation-layer image of FR-84 | Consistent (FR-128) |
| T-1.8-8 | FR-88–89 orchestration bridge: bounded read-only summary, consume-not-own | The hook consumes the summary one hop further downstream and likewise never reconstructs or owns state | Consumes unchanged (FR-127, FR-132) |
| T-1.8-9 | NFR-13–15 harness agnosticism (frozen 2026-08-26) | Core formatter references no CLI; Claude + Codex adapters; adapter gap → `NOT_EVALUATED`; add harness = add adapter; two-harness acceptance tests | Binds directly; no new NFR needed (FR-130) |
| T-1.8-10 | Stories 1.5/1.6 sequencing ("strictly after Story 1.4") | Story 1.8 is NOT in that chain: it may start immediately against the frozen 1.3 schema; only its live-on-host acceptance waits on the #14–#18 merge; not gated behind 1.4 | No sequencing conflict; outside `AGENT-FLOW-KIT PORTABILITY GREEN` |
| T-1.8-11 | Frozen PRD non-goals: "no dashboards … no unrelated orchestration enhancements" (`prd.md`) | A statusline segment is bounded presentation of existing state, not fleet management or a dashboard; recorded here so the owner rules the classification explicitly at freeze | Judged in-bounds; owner confirms at freeze |

## Deliverables Produced (all new files; no frozen file edited)

| Deliverable | Path | Nature |
|---|---|---|
| Story 1.8 | `_bmad-output/implementation-artifacts/AFK-PORT-1.8.md` | new file, status drafted |
| PRD addendum (FR-127–132) | `prds/prd-agent-flow-kit-2026-08-24/prd-addendum-1.8.md` | new file, status draft |
| Epics block (staged) | `_bmad-output/planning-artifacts/epics-block-1.8.md` | new staging file; appends to epics.md post-baseline section at freeze (frozen text byte-identical) |
| This report | `prds/prd-agent-flow-kit-2026-08-24/reconciliation-story-1.8.md` | new file |

## Open Items for the Owner (freeze gate)

None. Freeze review completed and **ACCEPTED 2026-08-27**; the owner read the full T-1.8-1–11 touchpoint set and declared the freeze. Packaging per the decided vehicle: planning branch off master (`planning/afk-1.8`), the four Story 1.8 files plus the epics.md integration committed by explicit path, own PR held behind PR #13. Story 1.8 reaches an executor only via an explicit orchestration go; it may run parallel to Story 1.4 once the 1.3 chain is on master. No ORCH PM briefing until that go.
