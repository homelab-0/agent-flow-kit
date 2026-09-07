---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-PORT-1.5.md.stamp.json
persona: dev
gates:
  - "bash tests/lifecycle-tests.sh"
  - "bash tests/run-tests.sh"
  - "git diff --check"
max_cycles: 3
---

### Story 1.5: Context Budgeting and Continuation

As an agent-flow-kit fleet operator,
I want every dispatched worker to run inside a declared context budget with checkpointing and supervised continuation,
So that a worker never silently exhausts its context window and over-sized stories surface as planning findings instead of degraded work.

**Acceptance Criteria:**

**Given** an accepted route whose profile declares a context window in the router catalog
**When** the execution stamp is minted
**Then** the stamp carries that context window exactly as the catalog declares it
**And** the kit treats the value as read-only routed fact and never derives, overrides, extends, or substitutes a window.

**Given** an accepted route whose profile declares no context window
**When** the stamp is minted and the dispatch is budgeted
**Then** context budgeting for that dispatch reports `NOT_EVALUATED` with a stable reason
**And** the kit never invents a window and never reports budget health it cannot ground in the catalog value.

**Given** a story dispatch is being prepared
**When** the kit computes its pre-dispatch sizing estimate
**Then** the estimate deterministically covers the persona material, story file, referenced templates and files, and handoff content using a documented method
**And** the estimate is compared only against the stamped window as advisory kit policy — it is NOT sent to `/route` as a hard `context_size` minimum and does not alter route selection in any way.

**Given** the pre-dispatch estimate meets or exceeds the continuation threshold (accepted default: 85% of the stamped window)
**When** dispatch is requested
**Then** dispatch refuses fail-closed with a stable reason — a payload already past the continuation point cannot complete work
**And** a story-sizing finding is reported to the PM instead of launching a worker that cannot finish.

**Given** the pre-dispatch estimate crosses the sizing-risk threshold but not the refusal threshold (accepted threshold: 60%)
**When** dispatch proceeds
**Then** a sizing-risk finding is recorded in the story record
**And** the dispatch itself is not blocked.

**Given** a running worker whose context usage crosses the checkpoint threshold (accepted default: 70% of the stamped window)
**When** the budget policy evaluates usage
**Then** the worker is required to produce or refresh a durable, secret-free checkpoint artifact covering completed work, current state, remaining acceptance criteria, and next planned steps
**And** checkpoint content follows the same redaction rules as all other lifecycle and orchestration output.

**Given** a running worker whose context usage crosses the continuation threshold (accepted default: 85% of the stamped window)
**When** the budget policy evaluates usage
**Then** the worker stops at the next safe point (declared phase boundary), produces a compact continuation artifact (checkpoint content plus in-flight state and unretired findings), and returns a thin result carrying the continuation-required signal
**And** silent continued execution toward exhaustion never occurs.

**Given** a continuation-required thin result with a valid continuation artifact
**When** the continuation is dispatched
**Then** a fresh supervised Orca-visible worker launches for the same story under the same accepted stamp through the canonical dispatch path with the frozen prelaunch revalidation applied unchanged, and the pre-dispatch sizing estimate applies with the continuation artifact counted in the payload
**And** an expired or invalidated stamp follows the existing central `/route` refresh path and the kit never locally substitutes a harness, model, profile, or funding path.

**Given** a continuation worker completes or escalates
**When** it settles
**Then** the frozen Story 1.3 completion-watch, terminal-cleanup, and worktree/branch-accounting contracts apply to it without modification
**And** the continuation chain — trigger, usage evidence, continuation-artifact identity — is recorded in the story record.

**Given** a story has already consumed its continuation budget (accepted default: 2 continuations)
**When** a further continuation is required
**Then** dispatch of the third continuation requires an explicit PM decision recorded in the story record
**And** repeated continuation is simultaneously reported to the PM as a story-sizing finding.

**Given** context-usage observations
**When** the kit consumes them
**Then** they come from the harness and/or Orca as provided observations
**And** the kit never scrapes terminals or transcripts to reconstruct usage.

**Given** a harness that does not expose usable context-usage observations
**When** a worker runs under it
**Then** the budget reports `NOT_EVALUATED` and checkpoint discipline falls back to deterministic policy at declared phase boundaries
**And** the kit never assumes headroom it cannot observe.

**Given** normalized orchestration state is rendered
**When** a worker is under budget management
**Then** a bounded context-budget field is exposed (accepted values: `OK`, `CHECKPOINT_DUE`, `CONTINUATION_REQUIRED`, `NOT_EVALUATED`) alongside the existing state summary
**And** this field is introduced by Story 1.5 — it imposes no retroactive requirement on the frozen Story 1.3 deliverable.

**Given** a required continuation cannot proceed — a missing or unparseable continuation artifact, or a stamp that cannot be refreshed
**When** the failure is handled
**Then** the story enters loud `NEEDS_HUMAN` with actionable evidence
**And** the kit neither manufactures a completed result nor silently retries past the failure.

**Given** the ORCH PM session — human-started in Orca and not necessarily stamped
**When** its context budget is evaluated
**Then** the same window/usage/threshold model applies with the same accepted defaults (checkpoint at 70%, continuation at 85%), sourcing the window by hierarchy: the stamp if the PM session was routed, else the harness adapter's reported window, else `NOT_EVALUATED` with the phase-boundary checkpoint fallback
**And** the coordinator is never exempt from the budget discipline it enforces on workers.

**Given** the ORCH PM operates on in-flight work
**When** it consumes orchestration information
**Then** it consumes only thin results and completion-watcher events, handling pointers to worker transcripts, gate logs, and evidence bodies without reading the bodies
**And** a PM reading a worker transcript, gate log, or evidence body is a defect.

**Given** completion watchers established under the frozen Story 1.3 completion-monitoring contract
**When** worker events are delivered to the PM
**Then** delivery requires no live PM turn and the frozen contract is consumed unchanged
**And** a polling loop held open inside a PM turn is prohibited.

**Given** the PM crosses its checkpoint threshold
**When** budget policy evaluates PM usage
**Then** the PM writes a compact epic-level continuation artifact covering decisions, envelope actions, open escalations, and budget state
**And** the artifact follows the same durability and redaction rules as worker checkpoint artifacts.

**Given** the PM crosses its continuation threshold
**When** it hands off
**Then** it stops dispatching new work, leaves in-flight workers under their durable watchers, and raises loud `NEEDS_HUMAN` carrying a ready-to-use resume instruction — PM continuation is always loud `NEEDS_HUMAN`
**And** in-flight workers are never orphaned, because completion authority is Orca's Task/Dispatch rather than the PM's turn.

**Given** the human starts the successor ORCH PM session in Orca
**When** the successor comes up
**Then** it reconciles from normalized orchestration state and the continuation artifact through the frozen Story 1.3 restart/reconnect reconciliation, consumed unchanged, and the `NEEDS_HUMAN` condition clears only on successful reconciliation
**And** the kit never launches a PM session itself — automatic successor launch is an explicit non-goal — and PM continuation count is recorded against the epic budget declared under Story 1.6.

**Given** Story 1.5 deterministic tests
**When** its isolated suites run
**Then** they cover window-carrying stamps, missing-window `NOT_EVALUATED`, deterministic sizing estimates, pre-dispatch refusal and sizing-risk thresholds, checkpoint and continuation threshold actions, continuation-artifact production and consumption, same-stamp revalidated continuation dispatch, expired-stamp refresh routing, continuation settlement under the frozen cleanup/completion contracts, continuation-budget exhaustion, unobservable-usage fallback, normalized-state budget field, continuation-failure `NEEDS_HUMAN`, PM budget application under each window-source-hierarchy branch (routed stamp, adapter-reported window, `NOT_EVALUATED` fallback), PM thin-consumption discipline, watcher delivery without a live PM turn, PM checkpoint/continuation artifacts, the always-`NEEDS_HUMAN` continuation handoff with its resume instruction, human-started successor reconciliation clearing the condition, and refusal of any kit-side PM-session launch
**And** Story 1.1–1.3 gates and frozen orchestration gates remain green.

**Requirements covered:** FR-96–105, FR-121–126, and NFR-13–15 (PRD addendum `prd-addendum-1.5-1.6.md`); depends on the frozen Story 1.3 normalized orchestration state, completion-watch, restart/reconnect reconciliation, cleanup, and loud `NEEDS_HUMAN` contracts without modifying them.

## Implementation Constraints

- Frozen PRD: _bmad-output/planning-artifacts/prds/prd-agent-flow-kit-2026-08-24/prd.md — unchanged by this story.
- Requirement authority for this story: _bmad-output/planning-artifacts/prds/prd-agent-flow-kit-2026-08-24/prd-addendum-1.5-1.6.md
- Sequenced strictly after Story 1.4; not part of the frozen portability baseline or its GREEN verdict.
- All thresholds (60% sizing risk, refusal at the continuation threshold, 70% checkpoint, 85% continuation, 2-continuation cap) are owner-accepted defaults (2026-08-26, refusal threshold revised at freeze review) expressed as declared machine-readable policy; changing a value is a policy edit, not a requirement change.
- The router catalog is the sole source of the context window; the sizing estimate is never a routing input. Do not add `context_size` or any capacity constraint to `/route` requests.
- Continuation dispatch goes through the canonical dispatch path: frozen prelaunch revalidation, `/place` at dispatch only, no local substitution. Expired stamps refresh via central `/route` per the standing coordinator ruling.
- The context-budget status field is introduced here, in the state the kit already owns as producer; do not modify the frozen Story 1.3 story file or reopen its deliverable.
- The PM context budget consumes the frozen Story 1.3 completion-monitoring and restart/reconnect reconciliation contracts unchanged. Polling held open inside a PM turn (the rolling `check --wait` pattern) is the defect Story 1.3 replaces and remains prohibited here. The ORCH PM is human-started in Orca; the kit never launches PM sessions, and PM continuation is always a loud `NEEDS_HUMAN` handoff to the human.
- Harness agnosticism (NFR-13–15): budgeting policy, thresholds, the sizing estimate, and the budget-state field reference no specific CLI; context-usage observation is a per-harness adapter concern. An adapter that cannot observe usage reports `NOT_EVALUATED` (never core fallback logic, never blocking other harnesses). Any acceptance test that exercises a harness runs on at least two approved harnesses.
- Story 1.7's per-profile persona-payload evidence is an input to the sizing-estimate policy when available; Story 1.5 does not block on it.
- Do not broaden into router, catalog, prox-ops, Kubernetes, GPU, or control-plane product work.
- Worker-originated subdelegation remains out of scope (see follow-on-worker-subdelegation.md; it depends on this story but is not scheduled by it).

## Dev Agent Record

- Status: **FROZEN — owner-approved 2026-08-26.** Stories 1.5, 1.6, 1.7 and PRD addendum FR-96–126 / NFR-13–15 frozen together. Sequenced after Story 1.4; 1.7 may run in parallel with 1.3. Outside the `AGENT-FLOW-KIT PORTABILITY GREEN` verdict.
- Implementation artifacts:
- Gates:
- Findings and resolutions:
- Final diff size:
