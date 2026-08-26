# Reconciliation Report — Stories 1.5/1.6/1.7 Refinement vs Frozen Stories 1.1–1.4

Produced 2026-08-26 during the separate PLAN session designated for post-1.4 refinement (per the coordinator ruling of 2026-08-26). Interactive planning only: no activation, no dispatch, nothing frozen. Updated the same day after owner rulings on the two original flags and four additions (convergence policy, workflow-resolution reading, persona spike, PM context budget).

## Verdict

No frozen requirement was changed. Stories 1.5, 1.6, and the 1.7 spike are post-baseline additions that consume frozen contracts without modifying them; every deliverable in this session is a new file or a purely additive edit outside frozen text. Every flagged item is ruled: T13 (settled/DONE), T5 (context-budget field ownership), the threshold/budget defaults, and T30 ("Delta §10" interpretation confirmed and closed) — all recorded below. No owner checks remain open.

**Stories 1.5, 1.6, 1.7 and PRD addendum FR-96–126 / NFR-13–15 FROZEN — owner-approved 2026-08-26. Sequenced after Story 1.4; 1.7 may run in parallel with 1.3. Outside the `AGENT-FLOW-KIT PORTABILITY GREEN` verdict.**

## Owner Rulings Recorded (2026-08-26)

1. **Settled/DONE (was flag T13): frozen 1.3 semantics kept — option 1.** No clarification recorded anywhere. Result immutability and resource accounting remain separate concerns; "accounting mandatory before proceeding" is the mechanism. No change to any file.
2. **Context-budget field (was flag T5): Story 1.5 ownership confirmed.** Story 1.5 owns both the usage observation and the budget-state field. No retrofit to frozen 1.3.
3. **Thresholds and budgets: accepted as declared policy defaults.** 60% sizing risk / 70% checkpoint / 85% continuation / 2-continuation cap; story budgets 3 cycles / 2 continuations / 24h wall time; cost class = stamped funding class. All addendum, story, and epics text updated from "proposed" to accepted; values remain owner-tunable as policy edits. *(Freeze review round 1 revised the pre-dispatch refusal threshold from 100% of the window to the continuation threshold — default 85% — since a payload already past the continuation point cannot complete work.)*

## Freeze Review Round 1 (2026-08-26) — seven owner edits applied

1. **FR-98:** pre-dispatch refusal threshold moved from 100% of the stamped window to the continuation threshold (default 85%); 60% remains the sizing-risk marker.
2. **FR-121:** PM window source hierarchy defined — stamp if the PM session was routed; else the harness adapter's reported window; else `NOT_EVALUATED` with the FR-104 phase-boundary checkpoint fallback. The ORCH PM is human-started in Orca and not necessarily stamped (touchpoint T32).
3. **FR-124/125:** PM continuation is always loud `NEEDS_HUMAN` carrying a ready-to-use resume instruction; the human starts the successor PM in Orca; the kit gains no authority to launch PM sessions; automatic successor launch added as an explicit non-goal.
4. **FR-113/116:** the full-sweep requirement now applies "where review policy (FR-117) requires review"; "clean full sweep" added as a loop exit condition.
5. **FR-102:** FR-97 sizing applies to continuation dispatches, with the continuation artifact counted in the payload.
6. **FR-101:** the outgoing worker stops "at the next safe point (declared phase boundary)".
7. **FR-107:** helper workers are PM-dispatched through the normal route/stamp path — never worker-originated subdelegation.

Plus the requested numbering note: FR numbering reflects addition order (FR-121–126 sit under Capability 5 by design). Story files 1.5/1.6, the epics block, and this report were updated to match; frozen files remain untouched (re-verified below).

## Inputs and Authority

- Frozen PRD: `prd.md` (95 FR / 33 AC / 12 NFR, status final, baseline frozen)
- Frozen epic breakdown: `_bmad-output/planning-artifacts/epics.md` Stories 1.1–1.4
- Frozen story files: `AFK-PORT-1.1.md` – `AFK-PORT-1.4.md` (1.2 currently in a re-freeze cycle; scope treated as fixed)
- Backlog design item: `follow-on-worker-subdelegation.md`
- Standing coordinator rulings recorded at the 1.2 freeze (routing via `/route` in PLAN, stamp refresh never local substitution, `/place` at dispatch, rolling `check --wait` is the defect 1.3 replaces, post-1.4 refinement in a separate PLAN session)

## Deliverables Produced

| Deliverable | Path | Nature |
|---|---|---|
| PRD addendum (FR-96–126) | `prds/prd-agent-flow-kit-2026-08-24/prd-addendum-1.5-1.6.md` | new file (extended with FR-112–117 convergence policy, FR-118–120 spike, FR-121–126 PM context budget) |
| Story 1.5 | `_bmad-output/implementation-artifacts/AFK-PORT-1.5.md` | new file (extended with PM-context-budget ACs) |
| Story 1.6 | `_bmad-output/implementation-artifacts/AFK-PORT-1.6.md` | new file (extended with convergence-policy ACs) |
| Story 1.7 spike | `_bmad-output/implementation-artifacts/AFK-PORT-1.7.md` | new file |
| Epic breakdown update | `_bmad-output/planning-artifacts/epics.md` | additive block appended after Story 1.4; all frozen text above the block byte-identical |
| Subdelegation framing | `_bmad-output/planning-artifacts/follow-on-worker-subdelegation.md` | one paragraph added (2 inserted lines, 0 deletions); scope, authority contract, exclusions, and promotion gate unchanged |
| This report | `prds/prd-agent-flow-kit-2026-08-24/reconciliation-stories-1.5-1.6.md` | new file |

FR numbering continues from the frozen FR-95; FR-96–126 verified unclaimed across `_bmad-output/` and `docs/` before assignment.

## Clarification to Story 1.3: Settled/Released/DONE — PARTIAL; RULED 2026-08-26 (option 1, no change)

Requested clarification: *a dispatch is not SETTLED until terminal/worktree are accounted for; DONE implies released; the kit assigns DONE after cleanup; the PM never declares it.* Instruction: record only if already implied by the frozen 1.3 cleanup/completion-monitoring contract; otherwise flag without adding.

### Confirmed as already implied (no recording needed)

- **The PM never declares DONE; completion authority is Orca's.** Frozen: "Completion authority comes from the supervised Orca Task/Dispatch and its durable `worker_done` or escalation delivery. Terminal idleness, transcript text, provider session history, and tab state are not completion signals." (`AFK-PORT-1.3.md:181`) and "AFK reports a lifecycle/monitoring fault and does not manufacture `DONE`." (`AFK-PORT-1.3.md:194`); epics.md 1.3 AC: "completion is derived from Orca Task/Dispatch authority rather than terminal idleness, transcript text, session history, or tab state."
- **Resource accounting is mandatory before the coordinator proceeds, and unfinished cleanup stays loud.** Frozen: "…then account for every exact terminal, worktree, and branch owned by that worker before proceeding." (`AFK-PORT-1.3.md:172`) and "Failed cleanup never rewrites a successful implementation result, but it prevents the orchestration attempt from presenting resource cleanup as complete. Normalized state must expose retained terminal/worktree/branch counts and loud required action." (`AFK-PORT-1.3.md:204`)

### NOT implied — not added (ruling: frozen semantics kept)

- **"A dispatch is not SETTLED until terminal/worktree are accounted for."** The frozen vocabulary orders it the other way: settlement precedes accounting. "the coordinator must first retain the result/evidence and settle the Task/Dispatch, **then** account for every exact terminal, worktree, and branch" (`AFK-PORT-1.3.md:172`); cleanup targets "the **settled** Task/Dispatch" (`AFK-PORT-1.3.md:199`); "Before removing an AFK-owned worktree, prove the worker is **settled**" (`AFK-PORT-1.3.md:200`). Redefining SETTLED to follow resource accounting inverts frozen wording, not merely clarifies it.
- **"DONE implies released; the kit assigns DONE after cleanup."** Frozen text conditions DONE on a valid supervised completion delivery, not on cleanup, and "Failed cleanup never rewrites a successful implementation result" (`AFK-PORT-1.3.md:204`) implies the successful result stands — with loud retained-resource state — even when release has not completed. DONE-only-after-release is therefore a semantic change, not an implication.

### Options for the owner

1. **Keep frozen semantics** (completion/DONE distinct from released; release tracked as the separate loud accounting state the frozen contract already requires). No change anywhere; the drafted 1.5/1.6 already assume this.
2. **Amend frozen 1.3 wording** via a recorded reconciliation amendment (reopens frozen scope — requires explicit owner authority; not done here).
3. **Layer the stricter vocabulary post-baseline** (e.g., a `RELEASED`-inclusive settlement state added by a post-1.4 story or the hardening backlog) without touching frozen text.

**RULED 2026-08-26: option 1.** Frozen semantics kept; no clarification recorded. The drafted stories already assumed this.

## Reading Recorded: Persona + Workflow Resolution in Frozen 1.3 — IMPLIED

Question: does frozen "persona resolution/injection" already imply that the kit resolves the BMAD workflow/command the worker executes (dev-story, review, etc.) from the story's declared type — with the PM never hand-typing BMAD commands into workers?

**Verdict: implied — recorded as a reading, not a change.** The chain:

- The frozen ownership matrix gives the kit "**persona injection and handoff**" (`prd.md:36`) — the handoff *is* the executable instruction the worker receives — while BMAD owns "methodology, … story semantics, acceptance criteria, and **task-role selection**" (`prd.md:35`), which the frozen story format expresses as the story's declared `persona:` frontmatter field. Kit composes; BMAD declares.
- Frozen 1.3 names the dispatch "**Story 1.3's permanent composed dispatch**" with a "persona-bound terminal Orca-owned from creation through release" (`AFK-PORT-1.3.md:176`), and the interim mechanism is described as "custom persona/model composition" (`AFK-PORT-1.3.md:173`) — composition is the kit's act.
- AC-22 requires evidence of "**requested and resolved** DEV persona" (`prd.md:238`) and FR-56 requires targets to expose "resolvable PM and worker personas, referenced templates/files" mechanically — a requested→resolved mapping performed by the dispatch machinery, not a human.
- The frozen flow gives the PM no channel into worker terminals at all: workers are fresh sessions the kit launches via Orca, the PM's interface is approved stories in and thin results out, and the frozen completion-monitoring contract explicitly removes PM-in-the-loop interaction with worker sessions.

Caveat stated honestly: the literal words "workflow" and "command" do not appear in the frozen resolution language; the reading rests on handoff-composition ownership. It requires no frozen change under any interpretation, and Stories 1.5–1.7 are drafted consistently with it (the kit resolves persona + workflow from story type; the PM never hand-types commands into workers).

## Touchpoint Register

Dispositions: **CONSUMED-UNCHANGED** (new story relies on the frozen contract exactly as written), **INTRODUCED-BY-NEW-STORY** (new behavior owned entirely by a post-baseline story), **RULED** (was flagged; owner decision recorded above).

### Against Story 1.1

| # | Frozen touchpoint | How 1.5/1.6 touch it | Disposition |
|---|---|---|---|
| T1 | Lifecycle state/reason-code and machine-contract discipline (FR-15/16, FR-72–77; 1.1 JSON-schema AC) | New escalation/budget codes live in the orchestration thin-result/state registries, additive within a schema major version; no lifecycle installed-state code is added, removed, or redefined | CONSUMED-UNCHANGED |
| T2 | `NOT_EVALUATED` philosophy (FR-84; 1.1 live-probe AC) | Reused verbatim for missing catalog window and unobservable usage (FR-96, FR-104) | CONSUMED-UNCHANGED |
| T3 | Redaction and secret-free output (FR-81–82; 1.1 anti-vacuity AC) | Checkpoint and continuation artifacts explicitly adopt the same rules (FR-100) | CONSUMED-UNCHANGED |

### Against Story 1.2

| # | Frozen touchpoint | How 1.5/1.6 touch it | Disposition |
|---|---|---|---|
| T4 | Transactional convergence, plan binding, journal, rollback (FR-22–46, FR-91–94) | No touchpoint: checkpoint/continuation artifacts are orchestration artifacts, not lifecycle-managed content; no transaction semantics change. The 1.2 re-freeze cycle was not entered: this session made zero edits to `AFK-PORT-1.2.md` (its current working-tree diff is one pre-existing, purely additive Dev Agent Record hunk starting at line 156 belonging to the in-flight F6-R10/R11 cycle; story and AC text, lines 1–137, are untouched) | CONSUMED-UNCHANGED |

### Against Story 1.3

| # | Frozen touchpoint | How 1.5/1.6 touch it | Disposition |
|---|---|---|---|
| T5 | Bounded read-only normalized-state summary (FR-89–90; 1.3 AC) | 1.5 introduces a context-budget field (`OK`/`CHECKPOINT_DUE`/`CONTINUATION_REQUIRED`/`NOT_EVALUATED`) on the producer side. **Finding: no `CONTEXT` status field exists anywhere in frozen 1.3, epics.md, or the repo** — the tasking premise "1.3's CONTEXT status field" is not grounded in frozen text. The draft resolves this conservatively: 1.5 owns the field; frozen 1.3 carries no retroactive requirement | RULED 2026-08-26 — Story 1.5 ownership confirmed; no retrofit to 1.3 |
| T6 | Loud `NEEDS_HUMAN` (1.3 contract; PRD FR-88) | Reused for continuation-cannot-proceed (1.5) and out-of-envelope escalations plus budget excess (1.6) | CONSUMED-UNCHANGED |
| T7 | Durable completion watch, at-least-once idempotent `worker_done` (`AFK-PORT-1.3.md:180–195`) | Continuation workers and helper workers settle through it exactly as written | CONSUMED-UNCHANGED |
| T8 | Terminal/worktree/branch cleanup contract (`AFK-PORT-1.3.md:169–213`) | Applies to continuation workers without modification | CONSUMED-UNCHANGED |
| T9 | Stamp validation before launch; refresh via central `/route`; `/place` at dispatch; never local substitution (1.3 ACs; FR-53; coordinator rulings) | 1.5 "same stamp" continuation is explicitly conditioned on the frozen prelaunch revalidation; expired stamps take the existing central refresh path (FR-102) | CONSUMED-UNCHANGED |
| T10 | Thin results as the worker return channel (PRD architecture matrix; 1.3/1.4 ACs) | 1.6 adds a structured escalation registry to the thin-result payload — additive schema evolution under the FR-72–77 discipline; existing pass/fail semantics unchanged | INTRODUCED-BY-1.5/1.6 |
| T11 | No terminal scraping or heuristic state reconstruction (FR-90; 1.3 AC) | 1.5 usage provenance is harness/Orca observations only (FR-104) | CONSUMED-UNCHANGED |
| T12 | `max_cycles: 3` story frontmatter; convergence-control ruling (auto-cycle human-gated) | 1.6 makes the cycle budget an explicitly enforced, escalating boundary; frozen stories' values and behavior are unchanged | INTRODUCED-BY-1.5/1.6 |
| T13 | Settled/DONE vocabulary (`AFK-PORT-1.3.md:172,181,194,199–204`) | Clarification analysis above: partially implied; not-implied parts not recorded | RULED 2026-08-26 — option 1, frozen semantics kept |
| T20 | Completion-monitoring contract: watch survives PM turn boundaries, delivery without a live turn, no in-turn polling (`AFK-PORT-1.3.md:180–187`) | 1.5's PM context budget (FR-123) consumes it verbatim for watcher delivery to the PM; the prohibited in-turn polling loop is exactly the rolling `check --wait` defect 1.3 already replaces | CONSUMED-UNCHANGED |
| T21 | Restart/reconnect reconciliation: enumerate non-settled Dispatches, consume pending deliveries, reconcile before new work (`AFK-PORT-1.3.md:182`) | 1.5's PM continuation (FR-125) is a fresh ORCH PM session reconciling through exactly this contract plus the epic-level continuation artifact; no modification | CONSUMED-UNCHANGED |
| T22 | Completion authority is Orca's Task/Dispatch, not the PM turn (`AFK-PORT-1.3.md:181`) | Grounds 1.5's guarantee that a PM handoff never orphans in-flight workers (FR-125): their watchers and completion authority are independent of any PM session | CONSUMED-UNCHANGED |
| T23 | Thin results and bounded evidence (PRD architecture matrix; FR-79 bounded identifiers) | 1.5's PM consumption diet (FR-122: thin results + watcher events only, pointers to transcripts/gate logs/evidence bodies) strengthens kit-side discipline in the same direction as frozen FR-79; no frozen output contract changes | INTRODUCED-BY-NEW-STORY |
| T32 | Frozen "Human → Orca → BMAD PM → agent-flow-kit → fresh specialized workers" flow (`prd.md:32`); Orca owns "session identity/state" and "process lifecycle and supervision" (`prd.md:34`) | The ORCH PM is **human-started in Orca** under the frozen flow and is not necessarily routed/stamped — FR-121's window hierarchy (stamp → adapter-reported window → `NOT_EVALUATED`) respects that instead of assuming a stamp. FR-124/125 keep the human at the front door: PM continuation is always loud `NEEDS_HUMAN` with a ready-to-use resume instruction, the human starts the successor in Orca, and the kit gains no authority to launch PM sessions (automatic successor launch is an explicit non-goal). No frozen authority moves | CONSUMED-UNCHANGED |

### Against Story 1.4

| # | Frozen touchpoint | How 1.5/1.6 touch it | Disposition |
|---|---|---|---|
| T14 | `AGENT-FLOW-KIT PORTABILITY GREEN` verdict scope (1.4 final AC) | 1.5/1.6 are explicitly outside the verdict; no new acceptance obligation was added to 1.4 | CONSUMED-UNCHANGED |
| T15 | Sequencing and defect-return rules (1.4 first AC) | 1.5/1.6 sequenced strictly after 1.4 in epics.md; 1.1–1.3 prerequisite gating untouched | CONSUMED-UNCHANGED |

### Against the frozen PRD

| # | Frozen touchpoint | How 1.5/1.6 touch it | Disposition |
|---|---|---|---|
| T16 | Increment boundary: no router or catalog policy changes; FR-65 router/catalog authority | FR-96 reads the catalog's context window via the stamp as a read-only routed fact; FR-97 explicitly bars the sizing estimate from `/route` inputs. Dispatch refusal on sizing is kit-owned control flow (the authority the PRD already assigns agent-flow-kit), not routing policy | CONSUMED-UNCHANGED |
| T17 | FR-53 / NFR-6: no local substitution, no metered fallback | Restated as binding constraints in FR-102 and the 1.6 cost-class budget (stamped funding class, no upgrade authority) | CONSUMED-UNCHANGED |
| T18 | Architecture authority matrix | New ownership split maps cleanly: kit owns budgeting policy and continuation orchestration, harness/Orca own usage measurement, router owns the window value; no authority moves | CONSUMED-UNCHANGED |

### Convergence policy (Story 1.6, FR-112–117) vs frozen review discipline

| # | Frozen touchpoint | How the convergence policy touches it | Disposition |
|---|---|---|---|
| T24 | "Do not weaken a frozen requirement to fit donor code or a bounded retry cycle" (Implementation Constraints of every frozen story) | The blocker bar (violates frozen requirement AND reproduced AND reachable by one ordinary operator action) governs what triggers a *cycle*, never whether a frozen requirement is *satisfied*. Below-bar findings enter the residual registry with recorded reason and are presented at freeze/owner review — deferred to the owner, never dismissed, and never marked satisfied. Budget exhaustion with an above-bar blocker outstanding is never reported as convergence | CONSUMED-UNCHANGED |
| T25 | `max_cycles: 3` frontmatter across frozen stories; convergence-control coordinator policy (exploitability bar, delta-scoped re-reviews, human-gated auto-cycling) | FR-112–117 codify that standing coordinator policy as declared machine-readable requirements bound to the existing 3-cycle budget; frozen stories' values and text unchanged | INTRODUCED-BY-NEW-STORY |
| T26 | Frozen three-role separation (PM never line-reviews; adversarial + senior review gates) | Route-class review policy (FR-117) varies *which* reviews are required per declared policy; it never removes the independent-review principle for work that policy requires it for, and the policy in force is recorded per story | INTRODUCED-BY-NEW-STORY |

### Spike 1.7 vs frozen and backlog contracts

| # | Touchpoint | How the spike touches it | Disposition |
|---|---|---|---|
| T27 | Persona-independence contract (`follow-on-worker-subdelegation.md`, "Persona and resource independence"): "If a full installed BMAD persona payload proves infeasible on a constrained local model, evaluate a bounded persona representation as a separate compatibility/design decision" | The spike **is** that anticipated evaluation, producing the evidence the contract requires; it records no prohibition and leaves the contract unchanged — product adoption of a compact representation remains a separate explicit reconciliation | CONSUMED-UNCHANGED |
| T28 | Router/catalog authority (FR-65); no local substitution (FR-53); no metered fallback (NFR-6) | Spike runs are explicit spike-class centrally routed evaluations with bounded spend; profiles are read from the catalog; nothing is created or substituted | CONSUMED-UNCHANGED |
| T29 | Frozen Stories 1.1–1.4 sequencing | Spike is evidence-only, may run in parallel with 1.3, and neither blocks nor modifies any frozen story; its output feeds 1.5 (non-blocking) and gates subdelegation promotion | CONSUMED-UNCHANGED |
| T30 | "Delta §10" (owner instruction: stands unchanged) | Owner confirmed 2026-08-26: "Delta §10" is the persona/resource-independence contract with explicit evaluation (not prohibition) for local payloads — the interpretation applied here. The contract stands unchanged | RULED 2026-08-26 — interpretation confirmed, closed |

### Cross-cutting: Harness Agnosticism (NFR-13–15) vs frozen 1.1–1.4

| # | Frozen touchpoint | Reading | Disposition |
|---|---|---|---|
| T31 | FR-20 (unavailable optional harness disables only that harness), FR-21 (failure blocks only its scope, never poisoning others), FR-52 ("Claude Code and Codex shall be first-class but individually optional harnesses"), FR-60/70 (per-harness capability verification; capability contracts over version allowlists), FR-66 (kit declares harness invocation features as executor capability, not policy), FR-84 (`NOT_EVALUATED` rather than ready), 1.3 AC "both harnesses are never globally mandatory" | **Frozen 1.1–1.4 already hold harness agnosticism** — harnesses are individually optional, capability-probed per harness, and scope-isolated, with unprovable facts reporting `NOT_EVALUATED`. NFR-13–15 give that stance its architectural form for 1.5–1.7 (core references no CLI; harness-specific behavior in per-harness adapters; adapter gaps report `NOT_EVALUATED` without core fallback or cross-harness blocking; adding a harness = adding an adapter; harness-exercising acceptance tests run on ≥2 approved harnesses, and 1.7's vendor baseline runs on both Claude and Codex). Recorded as a reading of the frozen baseline, not a change to it | CONSUMED-UNCHANGED (reading recorded) |

### Against the subdelegation backlog item

| # | Touchpoint | Change | Disposition |
|---|---|---|---|
| T19 | `follow-on-worker-subdelegation.md` | One framing paragraph added: subdelegation is primarily a context-relief mechanism and depends on Story 1.5. Scope, authority contract, exclusions, and promotion gate explicitly unchanged; still unscheduled backlog | Additive only |

## File-Level No-Change Confirmation

Verified via `git status`/`git diff` on 2026-08-26 in this session:

- `prd.md`, `AFK-PORT-1.1.md`, `AFK-PORT-1.3.md`, `AFK-PORT-1.4.md`: **no working-tree modification** — byte-identical to their committed frozen state.
- `AFK-PORT-1.2.md`: carries a pre-existing working-tree diff from the in-flight re-freeze cycle (one additive hunk from line 156, Dev Agent Record only; frozen story/AC text lines 1–137 untouched). **This session made no edit to this file.**
- `epics.md`: 60 insertions, 0 deletions — a single block appended after the final line of the frozen Story 1.4 section; all frozen text above the new heading is byte-identical.
- `follow-on-worker-subdelegation.md`: 2 insertions, 0 deletions — the framing paragraph only.
- All other deliverables are new files.

## Remaining Owner Items

None. All flagged items were ruled 2026-08-26 (T13 settled/DONE option 1; T5 context-budget field owned by 1.5; threshold/budget defaults accepted, refusal threshold revised in round 1; T30 "Delta §10" interpretation confirmed). Freeze review round 2 ACCEPTED: **Stories 1.5, 1.6, 1.7 and PRD addendum FR-96–126 / NFR-13–15 FROZEN — owner-approved 2026-08-26. Sequenced after Story 1.4; 1.7 may run in parallel with 1.3. Outside the `AGENT-FLOW-KIT PORTABILITY GREEN` verdict.** The 1.5–1.7 scope reaches the ORCH PM only via an explicit orchestration go after the 1.3 and 1.4 freezes.
