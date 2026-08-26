---
title: PRD Addendum — Context Budgeting/Continuation, Worker Feedback/PM Envelope, and Persona Payload Spike
status: frozen
baseline: post-baseline addition, frozen 2026-08-26; the frozen 95 FR / 33 AC / 12 NFR portability baseline is unchanged
created: 2026-08-26
updated: 2026-08-26
---

# PRD Addendum — Stories 1.5, 1.6, and 1.7

**Stories 1.5, 1.6, 1.7 and PRD addendum FR-96–126 / NFR-13–15 FROZEN — owner-approved 2026-08-26. Sequenced after Story 1.4; 1.7 may run in parallel with 1.3. Outside the `AGENT-FLOW-KIT PORTABILITY GREEN` verdict.**

This addendum extends the frozen PRD (`prd.md`) with three post-baseline items: two capabilities (Stories 1.5 and 1.6) and one bounded evidence-only spike (Story 1.7). It does not modify any frozen FR, AC, or NFR, does not enter the `AGENT-FLOW-KIT PORTABILITY GREEN` verdict for Stories 1.1–1.4, and inherits every architecture and authority boundary of the frozen PRD unchanged. FR numbering continues from the frozen baseline's FR-95 and reflects addition order, not document order — FR-121–126 sit under Capability 5 by design. All threshold and budget values below are accepted declared policy defaults (owner-accepted 2026-08-26), expressed as machine-readable policy; tuning a value is a policy edit, not a requirement change.

## Capability 5: Context Budgeting and Continuation (Story 1.5)

**Problem:** a spawned worker must never silently exhaust its context window. Today nothing bounds a worker's context consumption, and exhaustion produces truncated, unreliable, or silently degraded work with no orchestration-visible signal.

### Budget Authority and Sizing

- **FR-96:** The execution stamp shall carry the routed profile's context window exactly as declared by the router catalog. The kit shall treat this value as a read-only routed fact: it shall not derive, override, extend, or substitute a window, and this capability shall create no new router authority. When the catalog declares no window for the routed profile, the stamp carries none and context budgeting for that dispatch reports `NOT_EVALUATED`; the kit shall never invent a window.
- **FR-97:** Before dispatch, the kit shall compute a deterministic, documented sizing estimate of the planned worker payload — persona material, story file, referenced templates and files, and handoff content — and compare it against the stamped context window. The estimate is advisory kit-side policy: it shall NOT be sent to `/route` as a hard `context_size` minimum, shall not alter route selection, and shall not become a routing input of any kind.
- **FR-98:** Pre-dispatch sizing actions (accepted defaults): an estimate at or above the continuation threshold (default 85% of the stamped window) shall refuse dispatch fail-closed and report a story-sizing finding to the PM — a payload already past the continuation point cannot complete work; an estimate at or above 60% shall permit dispatch while recording a sizing-risk finding in the story record. Refusal is a planning outcome, not a routing outcome.

### Usage Thresholds and Actions

- **FR-99:** During execution, worker context usage shall be evaluated against declared thresholds with these accepted defaults: at or above 70% of the stamped window, a checkpoint is required; at or above 85%, continuation is required. Threshold values shall be machine-readable declared policy with stable reason codes, not code constants discoverable only by reading the implementation.
- **FR-100:** A required checkpoint shall produce or refresh a durable, secret-free checkpoint artifact sufficient to resume the story: completed work, current state, remaining acceptance criteria, and next planned steps. Checkpoint content shall follow the same redaction rules as all lifecycle and orchestration output.
- **FR-101:** When continuation is required, the outgoing worker shall stop at the next safe point (declared phase boundary), produce a compact continuation artifact (checkpoint content plus in-flight state and any unretired findings), and return a thin result carrying a continuation-required signal. Silent continued execution toward exhaustion shall not occur.

### Continuation Worker

- **FR-102:** A continuation shall be executed by a fresh supervised worker for the same story under the same accepted stamp, launched through the canonical dispatch path with the frozen prelaunch revalidation applied unchanged. An expired or invalidated stamp shall follow the existing refresh path through central `/route`; the kit shall never locally substitute a harness, model, profile, or funding path to continue work. The FR-97 pre-dispatch sizing estimate applies to continuation dispatches, with the continuation artifact counted in the payload. The continuation worker consumes the continuation artifact, is Orca-visible, and is settled exactly like any worker: the frozen completion-watch, terminal-cleanup, and worktree/branch-accounting contracts apply without modification.
- **FR-103:** Each continuation shall be recorded in the story record with its trigger, usage evidence, and continuation-artifact identity. Accepted default: after two continuations on one story, a third requires an explicit PM decision recorded in the story record before dispatch.

### Usage Provenance and Signals

- **FR-104:** Context-usage observations shall be provided by the harness and/or Orca; the kit consumes them and shall not scrape terminals or transcripts to reconstruct usage. When usage is not observably available for a harness, the budget shall report `NOT_EVALUATED`, the checkpoint discipline shall fall back to deterministic policy (checkpoint at declared phase boundaries), and the kit shall never report budget health it cannot observe.
- **FR-105:** Worker context-budget state shall be exposed as a bounded field in the normalized orchestration state consumed by lifecycle visibility (accepted values: `OK`, `CHECKPOINT_DUE`, `CONTINUATION_REQUIRED`, `NOT_EVALUATED`), with loud `NEEDS_HUMAN` when a required continuation cannot proceed — for example a missing or unparseable continuation artifact, or a stamp that cannot be refreshed. This field is introduced by this capability; it is not retroactively required of the frozen Story 1.3 deliverable. Repeated high usage — a continuation event, or checkpoint thresholds crossed across multiple stories of an epic — shall additionally be reported to the PM as a story-sizing finding, making over-sized stories a planning signal rather than a silent execution risk.

### PM Context Budget (ORCH Coordinator)

The coordinator's own context is in scope: the ORCH PM must not silently exhaust its window any more than a worker may.

- **FR-121:** The same window/usage/threshold model shall apply to the ORCH PM session, with the same accepted threshold defaults (checkpoint at 70%, continuation at 85%) as declared policy. The PM window source hierarchy is: the stamp, if the PM session was routed; otherwise the harness adapter's reported window; otherwise `NOT_EVALUATED` with the FR-104 phase-boundary checkpoint fallback. The ORCH PM is human-started in Orca and is not necessarily stamped.
- **FR-122:** The ORCH PM shall consume only thin results and completion-watcher events. It shall never read worker transcripts, gate logs, or evidence bodies — it handles pointers to them only. A PM reading such a body is a defect.
- **FR-123:** Completion watchers shall deliver events to the PM without requiring a live PM turn, consuming the frozen Story 1.3 completion-monitoring contract unchanged. Polling loops held open inside a PM turn are prohibited.
- **FR-124:** At the PM checkpoint threshold, the PM shall write a compact epic-level continuation artifact covering decisions, envelope actions, open escalations, and budget state. At the PM continuation threshold, the PM shall stop dispatching new work, leave in-flight workers under their durable watchers, and raise loud `NEEDS_HUMAN` carrying a ready-to-use resume instruction — PM continuation is always loud `NEEDS_HUMAN`.
- **FR-125:** The successor is a fresh ORCH PM session started by the human in Orca; the kit gains no authority to launch PM sessions, and automatic successor launch is an explicit non-goal. The successor reconciles from normalized orchestration state and the continuation artifact, consuming the frozen Story 1.3 restart/reconnect reconciliation contract unchanged. In-flight workers are never orphaned by a PM handoff because completion authority is Orca's Task/Dispatch, not the PM's turn; the `NEEDS_HUMAN` condition persists until a successor session has reconciled.
- **FR-126:** PM continuation count shall be part of the epic budget declared under FR-109.

### Ownership

The kit owns budgeting policy, thresholds, checkpoint/continuation orchestration, and the sizing estimate — for workers and for the ORCH PM session alike. The harness and Orca own usage measurement. The router catalog owns the context-window value, carried via the stamp. No authority moves between components.

## Capability 6: Worker Feedback and PM Course-Correction Envelope (Story 1.6)

**Problem:** thin results are effectively pass/fail. A worker that discovers ambiguity, hidden scope, or a spec/code conflict has no structured way to say so, and the PM has no defined authority envelope within which to course-correct without a human — so it must either stall or overreach.

### Structured Escalation Vocabulary

- **FR-106:** Thin results shall support a structured escalation vocabulary with stable, documented codes. Starting set: `AC_AMBIGUOUS`, `SCOPE_LARGER`, `DEPENDENCY_FOUND`, `SPEC_CONFLICTS_CODE`, `NEEDS_DECISION`. The vocabulary shall live in a documented registry that also carries the Story 1.5 context signals (checkpoint-due, continuation-required) so thin results have one structured escalation channel. Every escalation shall carry bounded evidence references. Codes are additive within a schema major version; their meaning shall not silently change — matching the frozen machine-contract discipline of FR-72 through FR-77.

### PM Envelope

- **FR-107:** On receiving an escalation, the PM may act alone only within this envelope: clarify an acceptance criterion without changing its intent; split a story while preserving its total approved scope; reorder or defer stories within the epic; re-route, retry, or add a helper worker within declared budgets; and spend within declared budgets. Helper workers are PM-dispatched through the normal route/stamp path — this is not worker-originated subdelegation. An action within the envelope resolves the escalation without a human turn.
- **FR-108:** These actions shall always require loud `NEEDS_HUMAN` and shall never be taken by the PM alone: changing the epic goal or approved scope; changing an architecture decision or invariant; dropping or rewriting an acceptance criterion; and exceeding any declared budget. A `NEEDS_DECISION` escalation is routed through the same envelope test: the PM decides and records it when the decision is inside the envelope, and escalates it otherwise.

### Budgets

- **FR-109:** Every story and epic shall carry explicit machine-readable budgets covering at least fix/review cycle count, cost class, and wall time, with documented defaults applying where not declared (accepted story defaults: 3 fix/review cycles, 2 continuation workers, 24 hours of active orchestration wall time; cost class is the stamped funding class with no upgrade authority). Exceeding any budget stops work on that story and escalates with evidence; there is no automatic cycling past a budget, and budget-exceeded work shall not resume without a recorded human decision.

### Audit and Design Authority

- **FR-110:** Every envelope action the PM takes shall be recorded in the story record with the triggering escalation code, the action taken, the rationale, and the budget state at the time of the action. An unrecorded envelope action is a defect.
- **FR-111:** Human design authority is preserved: the PM refines within approved scope and never redefines it. When it is ambiguous whether an action is inside the envelope, the ambiguity resolves to `NEEDS_HUMAN` — the envelope fails closed.

### Convergence Policy for Fix/Review Loops

The fix/review loop shall converge under an explicit policy bound to the FR-109 cycle budget (the existing 3-cycle default stands), so review cycles terminate by rule rather than by reviewer appetite.

- **FR-112:** A review finding shall block a fix/review cycle only when all three hold: it violates a frozen requirement; it is reproduced; and it is reachable by one ordinary operator action. The three-part evaluation shall be recorded per finding with evidence; a finding failing any part is below-bar for cycle-triggering purposes.
- **FR-113:** Where review policy (FR-117) requires review, the first review of a story's implementation shall be a full adversarial sweep. Subsequent reviews within the loop shall be scoped to the diff of the fix under review and shall not re-open previously dispositioned territory absent a new above-bar blocker visible in that diff.
- **FR-114:** A same-class narrower finding — the same defect class as an already-dispositioned finding, with narrower reach — shall be recorded in a residual registry with a recorded reason instead of triggering a new cycle. The registry is part of the story record and shall be presented at freeze/owner review; a registry entry never marks a frozen requirement satisfied and never dispositions the finding itself — it defers it to owner review.
- **FR-115:** A fix that introduces a NEW above-bar blocker shall stop the loop and escalate loudly as a design fault rather than triggering another cycle.
- **FR-116:** Loop exit shall be exactly one of: a clean full sweep; a clean diff-scoped review; or cycle-budget exhaustion with only below-bar residuals remaining. Cycle-budget exhaustion with an above-bar blocker outstanding stops and escalates under FR-109 and is never reported as convergence.
- **FR-117:** The review requirement for a story may vary by route class as declared machine-readable policy — for example, locally routed work may require a full adversarial review where subscription-routed work may not — and the review policy in force shall be recorded in the story record.

## Capability 7 (Spike): Persona Payload Viability on Local Profiles (Story 1.7)

**Problem:** whether a constrained local profile can carry the full installed BMAD persona payload, a compact role contract, or no persona at all is currently unknown — and the persona-independence contract (`follow-on-worker-subdelegation.md`) already requires that any bounded persona representation be evaluated as a deliberate compatibility/design decision, not emerge as a launcher shortcut. This spike produces that evidence. It records no prohibition.

- **FR-118:** The spike shall be evidence-only: no production code, no kit behavior change, and no new routes, profiles, or catalog entries. Benchmark executions shall be explicit spike-class centrally routed evaluation runs with bounded spend; no local substitution and no metered fallback.
- **FR-119:** The benchmark matrix shall cover every selectable local profile in the router catalog crossed with three persona modes — full installed BMAD persona payload, compact role contract, and no persona — plus a vendor-profile baseline for comparison. Each cell shall record, machine-readably and secret-free: persona payload tokens versus the profile's declared context window, remaining work-context headroom, and canary task quality judged against deterministic gates.
- **FR-120:** The spike's output shall be a per-profile recommendation (`full` | `compact` | `unsuitable`) and a machine-readable threshold rule the kit can apply. The output is an input to Story 1.5 sizing policy and prerequisite evidence for subdelegation promotion. Product adoption of a compact persona representation remains a separate explicit reconciliation per the persona-independence contract, which this spike leaves unchanged.

## Cross-Cutting Non-Functional Requirement: Harness Agnosticism (Stories 1.5–1.7)

agent-flow-kit is harness-agnostic. NFR numbering continues from the frozen baseline's NFR-12. These NFRs bind every capability in this addendum; for frozen Stories 1.1–1.4 they are a reading of what the frozen requirements already hold (FR-20–21, FR-52, FR-60, FR-66, FR-70, FR-84), not a change — see the reconciliation report.

- **NFR-13:** Core kit logic — normalized state, policy, thresholds, budgets, and the escalation vocabulary — shall reference no specific CLI. All harness-specific behavior, including context-usage observation, persona/workflow injection, status rendering, and session control, shall live in per-harness adapters, one per router-approved harness.
- **NFR-14:** A capability an adapter cannot provide shall report `NOT_EVALUATED`. It shall never become harness-specific fallback logic in the core and shall never block other harnesses.
- **NFR-15:** Adding a harness shall mean adding an adapter, never editing the core. Any Story 1.5–1.7 acceptance test that exercises a harness shall run on at least two approved harnesses, and Story 1.7's vendor baseline shall run on both Claude and Codex.

## Explicit Non-Goals

- No change to any frozen FR, AC, NFR, or to the Stories 1.1–1.4 acceptance track or its GREEN verdict.
- No new router, catalog, Orca, BMAD, or native-runtime authority; no routing-input changes.
- No worker-originated subdelegation (see `follow-on-worker-subdelegation.md`; it depends on Story 1.5 but is neither expanded nor scheduled by this addendum).
- No terminal scraping, dashboards, or fleet/session registries.
- No automatic context-window measurement by the kit itself.
- No automatic launch of successor PM sessions: the kit never launches an ORCH PM session; the human starts the successor in Orca.
