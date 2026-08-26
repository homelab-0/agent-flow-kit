---
linear:
stamp: AFK-PORT-1.3.md.stamp.json
persona: dev
gates:
  - "bash tests/lifecycle-tests.sh"
  - "bash tests/run-tests.sh"
  - "git diff --check"
max_cycles: 3
---

### Story 1.3: Prove Execution Readiness Without Crossing Authority Boundaries

As an agent-flow-kit fleet operator,
I want scoped offline and live readiness evidence for Orca, BMAD targets, validation, routing, and native harnesses,
So that I can know exactly which approved work can execute without hiding outages, substituting routes, exposing credentials, or causing metered spend.

**Acceptance Criteria:**

**Given** lifecycle readiness is evaluated
**When** normalized results are produced
**Then** they independently represent `HOST_EXECUTION_READY`, `NEW_WORK_READY`, `TARGET_READY(target_repo)`, and `ROUTE_READY(execution_stamp)`
**And** a failure blocks only the narrowest scope it invalidates.

**Given** Orca, validator/client, and at least one complete centrally approved harness path are usable while the router is temporarily unavailable
**When** live readiness aggregates
**Then** `HOST_EXECUTION_READY` may remain true while `NEW_WORK_READY` is false
**And** router availability is never an implicit host-execution prerequisite.

**Given** target A is incompatible and target B is compatible
**When** target and host readiness aggregate
**Then** `TARGET_READY(A)` is false and `TARGET_READY(B)` remains true
**And** neither target globally poisons an otherwise healthy host.

**Given** default status or verify
**When** no explicit live mode is requested
**Then** locally knowable installation, binary, version, capability, target-structure, validator-fixture, and orchestration-state facts are evaluated
**And** network-, provider-auth-, router-, and other live-dependent facts remain `NOT_EVALUATED`.

**Given** explicit live mode
**When** external readiness probes run
**Then** each probe is bounded, non-mutating, timestamped, and associated with timeout, evidence source, freshness, and a non-launch-authoritative disposition
**And** it never logs in, creates workers, changes BMAD repositories, runs implementation, consumes inference tokens when a safe status probe exists, creates placement, mutates production work, changes external authority, or enables metered fallback.

**Given** a verified installation
**When** live readiness is evaluated
**Then** `HOST_EXECUTION_READY` is true only if Orca, a compatible validator/client, and at least one centrally approved harness execution path are usable
**And** offline evaluation never asserts live host readiness.

**Given** Orca is unavailable or incompatible
**When** live readiness runs
**Then** host execution is not ready while installation integrity remains independently reportable
**And** status, adoption, update, and offline verification remain usable.

**Given** Orca is available
**When** its readiness is checked
**Then** the lifecycle verifies supported capability/version contracts for worktree ownership, visible worker launch, argument/environment transport, provider runtime, and session/process isolation
**And** routine readiness does not create a disposable worker unless Orca exposes a safe explicit dry-run.

**Given** a registered BMAD target
**When** target readiness is evaluated
**Then** recognized project and wiring schemas, PM and worker personas, referenced templates/files, managed wiring integrity, and ownership ambiguity are resolved mechanically
**And** failure affects only that target and routes requiring it.

**Given** the central router is unreachable or times out
**When** live readiness runs
**Then** `NEW_WORK_READY` becomes false with transient `UNAVAILABLE` evidence
**And** installed state is not `BROKEN`, host readiness is not automatically revoked, and no local route is invented.

**Given** an accepted, unexpired execution stamp that does not require rerouting
**When** the router is temporarily unavailable
**Then** route readiness may continue only if the compatible validator can prove catalog, provenance, expiry, funding, and policy requirements locally
**And** any requirement for a fresh route blocks launch.

**Given** router live-readiness is explicitly requested
**When** safe probes run
**Then** DNS, trusted TLS, required authentication, `/v1/status`, API shape, and catalog/schema/provenance compatibility are checked
**And** a harmless synthetic `/v1/route` may run only in explicit live mode without launching or spending provider tokens.

**Given** validator/client readiness is evaluated
**When** offline fixtures run
**Then** executable identity, supported contract versions, a known-valid fixture, tampered evidence, expired evidence, incompatible evidence, and catalog/provenance semantics are tested
**And** an always-success validator fails the anti-vacuity check without the lifecycle reimplementing validator policy.

**Given** Claude Code or Codex is configured
**When** local and live harness readiness runs
**Then** executable resolution, supported invocation/model/effort/permission capabilities, and safe native subscription authentication are classified without reading or displaying credentials
**And** stale authentication reports `AUTH_REQUIRED` without automatic login.

**Given** one harness is unavailable and another complete centrally approved path is usable
**When** host readiness aggregates
**Then** the host may remain execution-ready with the unavailable harness reported independently
**And** both harnesses are never globally mandatory.

**Given** an accepted route selects an unavailable harness or unsupported profile
**When** route readiness evaluates it
**Then** `ROUTE_READY` is false and launch is blocked
**And** the lifecycle never substitutes another harness, model, profile, host, or funding path.

**Given** a route approved for native subscription funding
**When** readiness inspects the selected harness environment and auth mode
**Then** known API-key, provider, base-URL, or auth-selection conditions that would cause unauthorized metered execution block only the affected route
**And** no credential value is inspected, persisted, or emitted.

**Given** a future explicitly authorized API-backed entitlement
**When** route readiness evaluates it
**Then** compatibility follows its central funding/entitlement contract
**And** credential shape alone is not treated as proof that every API-backed path is forbidden.

**Given** compatibility is evaluated
**When** authoritative contracts are intersected
**Then** usable execution equals router-approved profile ∩ kit-supported launch contract ∩ host capabilities ∩ compatible BMAD target ∩ valid final stamp
**And** the kit records/checks validator and Orca contracts without duplicating their policy.

**Given** a newer component version
**When** all safety-critical required capabilities are positively proven
**Then** it may remain ready with a bounded warning
**And** unknown stamp, validator, route, funding/auth, permission, Orca launch, persona/wiring, selected-harness, or deterministic-gate semantics block the affected route.

**Given** a route is semantically ready on the coding host
**When** readiness is recorded
**Then** no physical inference placement is selected, persisted, added to the immutable stamp, or assumed reusable
**And** any required placement remains an ephemeral per-attempt dispatch concern.

**Given** a successful live-readiness observation at time T1
**When** launch is later considered at T2
**Then** the observation remains diagnostic evidence only and never reusable launch authorization
**And** execution-critical facts are revalidated through the canonical dispatch path immediately before launch.

**Given** normalized orchestration state exists
**When** lifecycle output renders it
**Then** it exposes only a bounded read-only summary of `ACTIVE`/`INACTIVE`/`NOT_AVAILABLE`, `PLAN`/`ORCH`/`WORKER`, phase, task, loud `NEEDS_HUMAN`, and already-available worker counts
**And** it consumes rather than reconstructs or owns that state.
**And** its parent identity and child-count representation is generic rather than hard-coded to `parent = PM`, without implementing worker-originated delegation in this story.

**Given** no normalized orchestration state or no active session
**When** lifecycle status runs
**Then** orchestration reports not available or inactive as appropriate
**And** ordinary lifecycle or host readiness does not fail solely for that reason.

**Given** existing orchestration regression gates
**When** Story 1.3 completes
**Then** Orca-visible workers, mode/persona/task/route/phase/gate data, loud `NEEDS HUMAN`, late placement ownership, and session-state ownership remain intact
**And** no dashboard, terminal scraper, router session registry, or broader control-plane feature is introduced.

**Given** Story 1.3 deterministic tests
**When** offline and stubbed live table-driven suites run
**Then** they cover host/new-work independence, target isolation, optional-harness aggregation, exact-route refusal, router timeout isolation, validator anti-vacuity, native-auth classifications, route/funding-scoped environment conflicts, live timeout/freshness/non-authority, placement exclusion, orchestration bridge states, JSON/human parity, redaction, and stable exit semantics
**And** Story 1.1, Story 1.2, and frozen orchestration gates remain green.

**Requirements covered:** FR-47–90, FR-95; AC-13, AC-18, AC-20–24, AC-32–33 where implementation support precedes Story 1.4 proof; NFR-4–7 and NFR-11–12.

## Implementation Constraints

- Frozen PRD: _bmad-output/planning-artifacts/prds/prd-agent-flow-kit-2026-08-24/prd.md
- PR #5 is a donor/reference only; use reconcile-pr5.md as the migration map.
- Work from canonical master in this fresh story worktree.
- Do not broaden into router, catalog, prox-ops, Kubernetes, GPU, or control-plane product work.
- Do not weaken a frozen requirement to fit donor code or a bounded retry cycle.

## Observed Host Bootstrap / Autonomy Concern

- On 2026-08-24, Claude Code 2.1.241 presented its protected workspace-trust prompt when the supervised Story 1.2 review worker first launched from `/home/devbox/repos/jlengelbrecht/agent-flow-kit`. The owner explicitly accepted the prompt; Claude now records `hasTrustDialogAccepted: true` for that exact project path in its user-owned project state.
- This is not a Story 1.2 transaction defect and is not authority for AFK to edit Claude's project-state database, automate prompt acceptance, use non-interactive prompt skipping as a workaround, or weaken Claude permissions.
- Claude's supported model saves trust per directory. No supported ancestor-directory, wildcard, or Orca-worktree-root trust mechanism was found. Consequently, a fresh worker launched from the already-trusted canonical path should not repeat the prompt, while an externally generated Orca worktree at a new path may require a separate one-time human trust decision.
- Story 1.3 must detect and report a selected Claude path that is awaiting workspace trust as an affected-harness/route readiness condition with loud `NEEDS_HUMAN`; it must not claim the route launchable or accept the prompt. Exact state/reason names remain implementation-level under the frozen machine contract.
- Operationally, host bootstrap may establish trust once for stable canonical worker paths through Claude's interactive protected prompt. Path reuse is not a substitute for a worktree when isolation is required.

## Required Worker-Terminal Cleanup Contract

- Every significant implementation or review role starts in a fresh agent session. A completed session is never reused as the next implementation worker or post-fix reviewer.
- After an accepted `worker_done`, the coordinator must first retain the result/evidence and settle the Task/Dispatch, then account for every exact terminal, worktree, and branch owned by that worker before proceeding.
- Orca-owned worker terminals must be released through the supervised worker lifecycle so Orca closes them. A temporarily external terminal used for custom persona/model composition must be explicitly closed after Orca proves its Dispatch settled and confirms it is not active, awaiting an answer, ambiguous, or taken over by the user.
- Terminal closure must be durable across Orca disconnect/reconnect and provider-session discovery. A completed worker must not reappear as a newly resumed Claude/Codex tab merely because its transcript remains in session history. Cleanup must record or request Orca's supported durable close intent; killing the current PTY alone is insufficient.
- PM/coordinator terminals, active workers, pending-question workers, ambiguous terminals, and user-taken-over terminals must never be closed by generic cleanup.
- Story 1.3's permanent composed dispatch should make the persona-bound terminal Orca-owned from creation through release. Terminal cleanup, reconnect-safe non-resurrection, and the absence of unbounded completed-worker tabs are part of the dispatch regression contract, not optional UI housekeeping.

## Required Worker-Completion Monitoring Contract

- A coordinator that dispatches a worker must establish a durable completion watch before yielding control. Launching a worker and relying on a later human message to make the PM poll Orca is not a valid orchestration loop.
- Completion authority comes from the supervised Orca Task/Dispatch and its durable `worker_done` or escalation delivery. Terminal idleness, transcript text, provider session history, and tab state are not completion signals.
- The watch must survive coordinator turn boundaries and Orca connection loss. On reconnect or coordinator restart, AFK must enumerate its non-settled Dispatches, consume pending deliveries, and reconcile Task/Dispatch state before launching more work.
- Delivery handling is at-least-once and idempotent. AFK acknowledges a `worker_done` only after the compact result and referenced evidence have been retained and the exact Task/Dispatch has been reconciled. A replay must not duplicate review dispatch, cleanup, traceability updates, or terminal closure.
- A completed worker must promptly transition from `WORKING` to a visible completed/blocked state, notify the coordinator/operator, and enter the settlement/cleanup path. The PM must not remain silently unaware while a durable completion message is pending.
- Heartbeat expiry and monitor failure are distinct from worker completion. They produce loud diagnosable `NEEDS_HUMAN`/monitor-degraded state without inventing a successful or failed worker result.
- The completion monitor must be bounded and event-driven or use bounded polling/backoff; it must not require an indefinitely live LLM turn or create an unbounded busy loop.

### Required completion-monitor regressions

- A worker completes after the coordinating LLM turn has yielded: the durable watcher consumes `worker_done`, retains the result, updates normalized counts/state, and schedules settlement without another human prompt.
- Orca disconnects after `worker_done` is committed but before acknowledgment: reconnect replays the delivery exactly once semantically and completion processing remains idempotent.
- The coordinator restarts with one completed unacknowledged Dispatch and one active Dispatch: it reconciles the completed worker and preserves the active worker.
- Duplicate/replayed `worker_done` cannot launch duplicate reviewers or repeat cleanup/traceability mutations.
- A terminal becomes idle or exits without a valid supervised completion delivery: AFK reports a lifecycle/monitoring fault and does not manufacture `DONE`.
- A completion result that cannot be retained or parsed remains unacknowledged/recoverable and becomes loud `NEEDS_HUMAN` rather than disappearing.

### AFK-owned worktree and branch cleanup

- Cleanup authority is provenance-bound. AFK may request and verify cleanup only for a worktree or branch that Orca/AFK can prove was created for the settled Task/Dispatch. It must never sweep or delete arbitrary user, legacy, default, protected, release, or otherwise unowned branches based on age or naming heuristics.
- Before removing an AFK-owned worktree, prove the worker is settled, evidence/results are retained outside it, no process still owns it, and the worktree has no unaccounted tracked or untracked changes. Ambiguity blocks cleanup with actionable `NEEDS_OWNER` evidence.
- An AFK-owned local branch may be deleted only after its worktree is removed and one of these is mechanically proven: its associated PR was merged and its commits are reachable from the expected base; or the branch was explicitly disposable and contains no unique work that requires preservation. Unpushed or unique commits fail closed.
- A remote branch may be deleted only when the associated PR state and repository authority explicitly permit it and AFK already has that operation authority. Otherwise cleanup reports the retained remote branch and required owner/repository action; it does not broaden GitHub authority.
- Cleanup after a merged PR must cover the local Orca worktree, the AFK-owned local branch, and—when authorized—the remote topic branch. Each disposition is independently reported as removed, retained with reason, not applicable, or `NEEDS_OWNER`.
- Failed cleanup never rewrites a successful implementation result, but it prevents the orchestration attempt from presenting resource cleanup as complete. Normalized state must expose retained terminal/worktree/branch counts and loud required action.
- Pre-existing unused branches without AFK provenance are report-only inventory candidates for a separate owner-approved cleanup plan. They are not deletion targets of routine worker settlement.

### Required cleanup regressions

- A settled persona-bound worker is released and its tab remains absent after an Orca connection-loss/reconnect simulation or supported equivalent recovery probe.
- An active, pending-question, ambiguous, or user-taken-over worker is never closed by cleanup.
- A merged AFK-owned topic branch with no unique commits loses its disposable worktree and local branch; authorized remote deletion is handled separately and evidenced.
- An unmerged branch, a branch with unpushed/unique commits, a protected/default branch, and an unowned legacy branch are retained with stable reasons.
- Repeating cleanup is idempotent and does not recreate terminals, worktrees, or branches.

## Dev Agent Record

- Status: planned
- Implementation artifacts:
- Gates:
- Findings and resolutions:
- Final diff size:
