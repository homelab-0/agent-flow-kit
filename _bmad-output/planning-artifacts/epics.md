---
stepsCompleted: [1, 2, 3, 4]
inputDocuments:
  - "_bmad-output/planning-artifacts/prds/prd-agent-flow-kit-2026-08-24/prd.md"
  - "_bmad-output/planning-artifacts/prds/prd-agent-flow-kit-2026-08-24/addendum.md"
  - "_bmad-output/planning-artifacts/prds/prd-agent-flow-kit-2026-08-24/reconciliation-report.md"
---

# agent-flow-kit - Epic Breakdown

## Overview

This document decomposes the frozen portability and maintenance baseline into implementable stories. The PRD is requirement authority; the addendum is implementation guidance only.

## Requirements Inventory

### Functional Requirements

FR-1: The lifecycle shall identify the canonical checked-out kit revision and the last successfully applied or adopted revision.
FR-2: The lifecycle shall inventory installed kit components, registered target BMAD repositories, and expected integrity or version metadata where appropriate.
FR-3: Every inventoried component or managed region shall have an explicit ownership classification, including managed copy, managed or merged section, machine-local configuration, target-project wiring, or external native-runtime state as applicable.
FR-4: The local state manifest shall contain no secrets and shall not act as a routing, provider, model, catalog, or placement authority.
FR-5: Each host shall manage and report its own installed state without requiring centralized fleet inventory, remote state collection, or a fleet service.
FR-6: A local difference shall be classified as a known adaptation only when it is deterministically explained by a declared ownership rule or an explicit registered adaptation. Heuristic or LLM judgment shall not establish legitimacy.
FR-7: Differences in schema-declared machine-owned, project-owned, user-owned, or external-runtime regions shall be reported as `LOCAL_ADAPTATION` or external state as appropriate, not kit drift, without requiring one-off approval for each value change.
FR-8: A variation inside otherwise kit-owned territory shall require a secret-free registered adaptation identifying the component, affected path or section, reason or type, expected local shape or hash where appropriate, and update disposition.
FR-9: Any unexplained difference in kit-owned territory shall be reported as `LOCAL_DRIFT`. Managed-copy differences and managed-section edits are drift unless covered by an explicit adaptation; content outside managed sections remains user-owned.
FR-10: Legacy or unknown adoption shall begin inspect-only. The lifecycle may auto-adopt only when ownership and equivalence are mechanically provable and adoption records an established baseline without modifying user-owned content.
FR-11: Auto-adoption may cover exact current or recognized-prior canonical content, unambiguous matching managed sections, schema-declared local fields, exact recognized target wiring, and other cases where adoption only records already-proven state.
FR-12: When ownership overlaps, shared content would change, recognizable wiring is locally modified, multiple interpretations exist, old artifacts require replacement, or a local modification must become an exception, the lifecycle shall present a deterministic plan for owner approval before mutation.
FR-13: An adoption plan shall show current state, proposed ownership, proposed modifications, preserved local content, recovery protection, and resulting managed state. Approval grants authority only for that plan.
FR-14: The lifecycle shall refuse with `NEEDS_OWNER` when it cannot safely distinguish ownership, would overwrite unexplained edits, would capture secrets or native credential/session state, would weaken policy or security boundaries, would cross into router/catalog or infrastructure authority, lacks a safe compatibility path, or cannot preserve or recover a destructive shared-file change.
FR-15: Component state shall distinguish at least `CURRENT`, `LOCAL_ADAPTATION`, `UPDATE_AVAILABLE`, `LOCAL_DRIFT`, `BROKEN`, and `UNKNOWN` or legacy-unadopted state.
FR-16: Overall readiness shall distinguish at least `READY`, `READY_WITH_ADAPTATION`, `READY_WITH_WARNINGS`, `NOT_READY`, and `NEEDS_OWNER`, while retaining every component-level result and required action.
FR-17: `CURRENT` execution-critical components yield `READY`; verified intentional adaptation yields `READY_WITH_ADAPTATION`; a compatible stale revision or noncritical issue yields `READY_WITH_WARNINGS` unless compatibility metadata mandates migration.
FR-18: Missing, malformed, partial, inconsistent, or deterministically failing required components yield `NOT_READY`. Unresolved execution-critical drift or ownership ambiguity yields `NEEDS_OWNER` and blocks orchestration readiness.
FR-19: Noncritical managed drift may yield `READY_WITH_WARNINGS`, but update shall still refuse to overwrite it until reconciled.
FR-20: Dependency availability shall be reported separately from ownership drift. A missing mandatory dependency makes orchestration `NOT_READY`; an unavailable optional harness may disable only that harness when another approved route remains executable.
FR-21: Readiness shall aggregate to the strongest applicable condition within each readiness scope without hiding component detail. A failure scoped to one target, route, harness, or live operation shall not poison unrelated scopes. Reporting shall not invent fallback routing or resource authority.
FR-22: The product shall provide one obvious lifecycle entry point with coherent read-only status, ownership-establishing adoption, deterministic update or synchronization, and read-only verification behaviors. Exact command names remain a design decision.
FR-23: Every mutating operation shall compute and validate its complete deterministic plan before its first managed write. Provably safe, conflict-free operations may apply unattended; human approval is required only when the plan crosses an ambiguity or ownership boundary.
FR-24: `status` shall be side-effect free and report source and applied revisions, installed components, ownership and state, known update availability, drift and adaptations, dependency and readiness findings, and the next safe action without mutating filesystem, Git, runtime, authentication, or orchestration state.
FR-25: Adoption shall inspect first; classify the operation as auto-adopt, approval-required, or refuse; reconcile only within granted authority; verify the result; and establish the initial managed-state manifest only after successful completion.
FR-26: Synchronization or update shall never silently claim unknown files. For an adopted host, it shall compare the eligible source and applied revisions, compute the whole change plan, refuse unresolved conflicts, preserve declared local state, update recognized managed content, verify the result, and advance applied state only after complete success.
FR-27: `verify` shall observe and prove the declared installed state without repairing it. It shall check component presence, managed integrity or sections, declared adaptations, manifest consistency, target wiring, mandatory dependency compatibility, and applicable safe router or validator readiness.
FR-28: Lifecycle operations shall not activate orchestration or mutate external authority owned by Orca, native runtimes, or agent-router.
FR-29: A mutating operation shall accept source content only from a checkout whose repository identity, exact commit, managed input set, and lifecycle compatibility are deterministically known. Directory naming alone is insufficient evidence of identity.
FR-30: Uncommitted content in any canonical managed-source path shall block mutation. Dirt provably outside the input set may warn without blocking, but shall never influence installed output. A conservative clean-checkout requirement is acceptable for the first increment.
FR-31: Status and verification may run from detached or unexpected revisions. Ordinary unattended update shall require a recognized canonical or default-branch source; applying a detached, non-default, older, or otherwise noncanonical revision requires explicit source-selection or rollback intent.
FR-32: The resulting state shall record the exact commit applied. An older source shall never be treated as an ordinary update, and downgrade or rollback shall require explicit intent plus compatible migration metadata.
FR-33: Lifecycle and state schema versions shall be explicit and machine-readable. Recognized current schemas may proceed; recognized older schemas may migrate under declared rules; unknown newer major schemas shall refuse; supported legacy baselines shall use explicit migration or adoption paths; arbitrary unrecognized shapes shall yield `NEEDS_OWNER`.
FR-34: The lifecycle shall consume an operator- or agent-selected Git revision and shall not fetch, pull, merge, rebase, switch branches, or otherwise select Git state in this increment. It may safely report upstream divergence when deterministically knowable.
FR-35: Source eligibility and installed execution readiness shall remain distinct dimensions. An ineligible checkout shall block update without making a separately verified installed revision `BROKEN`; an eligible checkout shall not imply that installed automation is ready.
FR-36: Managed copies that still match their recognized applied canonical state may be deterministically replaced by eligible target canonical content. Unexplained differences shall block replacement.
FR-37: Content outside a managed section shall remain user-owned and be preserved byte-for-byte except for explicitly contracted unavoidable formatting behavior.
FR-38: A managed section matching its recognized applied or valid migratable canonical revision may be deterministically replaced with the target section. A registered adaptation shall follow its declared disposition. Any unexplained edit inside the section shall yield `LOCAL_DRIFT` and `NEEDS_OWNER`.
FR-39: The lifecycle shall not use free-form or LLM merging to resolve managed-content conflicts.
FR-40: Preflight shall cover every planned component, ownership and source expectation, local adaptation, conflict, directory and permission prerequisite, migration, recovery requirement, and expected final state before mutation begins.
FR-41: Before its first write, a mutating operation shall initialize secret-free recovery evidence identifying the operation, previous and target revisions, planned components, pre-mutation state, and required backups; it shall then record completed mutations as the operation advances.
FR-42: On failure, the lifecycle shall automatically restore and verify pre-operation filesystem state for changes it made when deterministic restoration is possible. Non-transactional effects shall be reported truthfully; incomplete restoration yields `BROKEN` or `NEEDS_OWNER` with component evidence and recovery instructions.
FR-43: The last successfully applied revision shall advance only after every planned mutation and final deterministic verification and consistency check succeeds. A diagnosed partial state is never successful convergence.
FR-44: Final applied-state metadata shall be committed as the last operation and in a manner that prevents partial state from claiming the target revision.
FR-45: A subsequent lifecycle invocation shall detect an incomplete operation before new mutation. It shall prefer deterministic rollback for this increment; otherwise it shall stop with `NEEDS_OWNER`. Safe resume is not required.
FR-46: Reapplying an already-applied eligible revision to an unchanged installation shall be a stable, non-destructive no-op with no installation churn.
FR-91: Every mutation plan shall bind to the exact source inputs, destination observations, manifest state, and approved adaptation records used to compute it. The lifecycle shall revalidate that binding immediately before mutation and fail if relevant state changed.
FR-92: Concurrent mutating lifecycle operations for the same installation shall be prevented or deterministically serialized. Read-only operations shall not report a transient in-progress state as a stable healthy result.
FR-93: Before reading, hashing, backing up, or replacing a managed destination, the lifecycle shall validate its path type and containment and shall refuse unexpected symlinks or path redirection that could escape the declared ownership boundary.
FR-94: Registered adaptations shall be revalidated against their declared expected shape and disposition during status, update preflight, and verification. A stale or mismatched adaptation record shall not legitimize new drift.
FR-47: Readiness shall be reported at distinct scopes: `HOST_EXECUTION_READY`, `NEW_WORK_READY`, `TARGET_READY(target_repo)`, and `ROUTE_READY(execution_stamp)`. A dependency failure shall block the narrowest scope it invalidates.
FR-48: A host may be reported execution-ready only when the installed kit verifies and live evaluation proves Orca usable, a compatible validator/client usable, and at least one centrally approved harness execution path locally usable. Offline evaluation shall report unevaluated live dependencies rather than asserting host execution readiness.
FR-49: A specific execution shall additionally require ready target BMAD wiring, host compatibility with the accepted route, a usable selected harness, and successful final stamp validation.
FR-50: Fresh routing shall require central router availability. Router unavailability shall make `NEW_WORK_READY` false without necessarily invalidating an already accepted, unexpired stamp that can still pass all validator, catalog, provenance, and policy requirements without rerouting.
FR-51: Target BMAD readiness shall be repository-scoped. An incompatible target shall not make unrelated targets globally unavailable, but shall block every execution for which its required persona, templates, contracts, or policy wiring cannot resolve.
FR-52: Claude Code and Codex shall be first-class but individually optional harnesses. One unavailable harness shall not block host execution when another complete centrally approved path is healthy; it shall block every accepted route that specifically selects the unavailable harness.
FR-53: The kit shall never substitute a different local harness or resource for an accepted route. It shall require a fresh central decision, another compatible host, or owner intervention.
FR-54: Execution-critical readiness shall require more than binary or file presence and shall prove the deepest safe property available without performing a real implementation task. Routine verification remains non-destructive; real worker creation belongs to acceptance testing unless a dependency exposes a safe dry-run contract.
FR-55: Orca readiness shall verify availability, a supported version or capability contract, runtime reachability, visible-worker or orchestration capability, and required launch fields. Routine verification shall not create disposable workers solely to report ready.
FR-56: Target BMAD readiness shall mechanically verify recognized project structure, compatible wiring/schema, resolvable PM and worker personas, referenced templates/files, integrity of managed wiring, and absence of unresolved ownership ambiguity.
FR-57: Router live-readiness shall verify reachability, trusted transport, required authentication, status response, API shape, and compatible catalog/schema/provenance. An explicitly requested live mode may use a harmless synthetic route request; offline installation verification shall not require router availability.
FR-58: Validator/client readiness shall verify executable/interface availability, compatible contract versions, a known-valid fixture, rejection of tampered evidence, rejection of expired or incompatible evidence, catalog/provenance semantics, and recordable executable identity. At least one negative test shall prevent an always-success validator from passing.
FR-59: An explicitly requested live verification may validate a harmless fresh route/stamp against the deployed control plane without launching provider work.
FR-60: Claude Code and Codex readiness shall verify executable resolution, supported invocation capabilities, safe native authentication status where available, required selection/permission semantics, and absence of configuration that would silently redirect the approved path.
FR-61: Authentication verification shall use safe native status or capability mechanisms where available and shall not read, copy, persist, or display credential values. Expired or unusable sessions shall report an actionable harness-unavailable state and shall never trigger automatic login.
FR-62: For currently approved native-subscription execution paths, readiness shall detect known environment, auth-mode, provider, or base-URL conditions that would select an unauthorized metered path, without inspecting credential values. The affected route shall be not ready and shall not spill over automatically.
FR-63: Future explicitly authorized API-backed entitlements may be modeled separately; credential shape alone shall not be treated as universal proof of funding class.
FR-64: An executable path shall be the intersection of router-approved execution profile, kit-supported launch contract, observed host capabilities, compatible target BMAD wiring, and a valid final stamp.
FR-65: Router/catalog authority shall own legal harness/profile relationships, model/profile legality, entitlement or funding class, placement requirements, catalog provenance, expiry, and resource policy. Runtime observation may remove availability but shall not add authority.
FR-66: agent-flow-kit shall own declarations for lifecycle state schemas, supported BMAD wiring contracts, supported execution-stamp and validator contracts, required Orca launch capabilities, and harness invocation features it can execute. These declarations describe executor capability, not routing policy.
FR-67: The validator/client shall expose machine-readable identity and supported contract, stamp-schema, catalog, and provenance semantics. The kit shall check and record that contract without reimplementing validator policy.
FR-68: Orca compatibility shall prefer explicit capabilities plus version information over version-only assumptions, including worktree ownership, visible worker launch, explicit argument/environment transport, provider runtime, and session/process isolation.
FR-69: BMAD targets shall expose or permit deterministic recognition of BMAD integration, agent-flow-kit wiring, and persona/template resolution contracts. Mere directory presence shall not prove compatibility.
FR-70: Harness compatibility shall prefer verified capabilities over unnecessarily narrow version allowlists. A newer version with positively verified required capabilities may be ready with warning; inability to prove invocation, permission, or subscription-auth semantics shall make that harness path not ready.
FR-71: Unknown compatibility affecting stamp/validator semantics, central route interpretation, selected harness/model invocation, security or permission posture, funding/auth mode, Orca launch semantics, target persona/wiring, or deterministic gates shall block the affected route. Noncritical informational uncertainty may remain ready with an explicit bounded warning.
FR-72: Human-readable and machine-readable lifecycle output shall derive from one normalized result model. Machine output shall use a documented, versioned schema with stable state codes, reason codes, blocking scopes, and exit semantics; automation shall not parse human prose.
FR-73: The machine contract shall represent, where relevant, schema version, command, operation identity, checkout and applied revisions, source eligibility, host and new-work readiness, target identity/readiness, overall state, and component results. It shall distinguish an evaluated false result, a field outside the command's scope, a temporarily unavailable observation, and a probe that was not performed.
FR-74: Stable machine states shall cover the Capability 1 states plus operation-specific distinctions including source ineligible, interrupted update, not evaluated, unavailable, and incompatible. Machine-code meaning shall not silently change within a schema major version.
FR-75: Every nontrivial warning or block shall include a documented stable reason code sufficient for automation to distinguish managed drift, source ineligibility, dependency unavailability or incompatibility, target wiring failure, harness auth/support failure, metered fallback, owner approval, and other actionable causes.
FR-76: Automation shall be able to determine affected component, ownership class, state, reason, severity, blocked readiness scope, owner-action requirement, transience, mutation safety, and requested-operation success without prose parsing.
FR-77: Exit codes shall remain coarse and stable: success with no requested-scope block; owner action/conflict; deterministic not-ready or verification failure; source/precondition refusal; live dependency unavailable or timed out; and command/internal/usage failure. `READY_WITH_WARNINGS` and `READY_WITH_ADAPTATION` count as success.
FR-78: Each warning or failure shall explain what is wrong, why it matters, which authority owns it, and what can safely happen next through component, ownership, state, reason, severity, blocking scope, expected/observed evidence, impact, owner, required action, and recovery guidance as applicable.
FR-79: Managed-state evidence shall prefer bounded identifiers such as revisions, hashes, section identities, contract versions, and wiring versions over raw file dumps.
FR-80: Results shall identify useful evidence provenance such as hash comparison, file structure, version probe, capability probe, auth-status probe, router status, validator fixture, BMAD resolution, or operation journal.
FR-81: Lifecycle output shall never emit credentials, tokens, secret values or contents, authorization headers, or credential-store contents. It may report safe auth state, credential source category, conflicting variable names, and redacted presence without exposing values.
FR-82: Paths may be reported when useful for remediation, but arbitrary user-owned or sensitive configuration content shall not be emitted by default. Machine output shall not become a secret-exfiltration surface.
FR-83: Ordinary status and verification shall default to deterministic offline evaluation of installed state, source/applied revisions, ownership, managed integrity, local configuration shape, target structure, locally discoverable capabilities, validator offline fixtures, and operation recovery state.
FR-84: External facts not tested offline shall report `NOT_EVALUATED` rather than ready.
FR-85: An explicit live mode may add bounded safe router, validator/control-plane, native harness auth, Orca, and other readiness probes. Live probes shall use bounded timeouts, avoid implementation work and provider-token consumption where safe probes exist, never log in automatically, never activate metered fallback, and never mutate external authority.
FR-86: Live timeout or outage shall report `UNAVAILABLE` or timeout distinctly from deterministic failure, including observation time and timeout metadata. It shall affect only the relevant live readiness scope and shall not make verified installed state `BROKEN`.
FR-87: Transient live observations shall not be persisted into the durable installation manifest as installed-state truth.
FR-88: Acceptance shall prove lifecycle adoption and update preserve existing Orca-visible workers, `PLAN`/`ORCH`/`WORKER` resolution, persona/task/route/phase/gate information, loud `NEEDS HUMAN`, and agent-flow-kit/Orca ownership of orchestration state.
FR-89: When normalized current orchestration state exists, lifecycle output shall expose a bounded read-only summary covering active/inactive/unknown state, mode, phase, task, and needs-human status, plus already-available worker counts where practical.
FR-90: The lifecycle shall consume normalized orchestration state without heuristically reconstructing it from terminals or logs and without becoming its owner. Missing state shall report not available and shall not make ordinary lifecycle readiness fail.
FR-95: Live results shall bind to the target, route/stamp, and observed dependency identities evaluated. A later launch shall not reuse them as proof when the stamp expired, the target changed, required capability state changed, or the observation exceeded its declared freshness.

### NonFunctional Requirements

NFR-1: All ownership, drift, compatibility, and convergence decisions shall be deterministic and reproducible from declared state and machine-readable contracts.
NFR-2: Mutating operations shall fail closed on ambiguous authority and shall not make destructive guesses.
NFR-3: State transitions and retained evidence shall never claim successful convergence before complete deterministic verification.
NFR-4: Installation lifecycle behavior shall remain separate from orchestration activation and from router, Orca, BMAD, and native-runtime authority.
NFR-5: Manifests, journals, output, logs, and evidence shall not persist or disclose personal provider credentials or secret values.
NFR-6: Native subscription authentication shall remain native, and unauthorized metered execution or credential-mode substitution shall fail closed.
NFR-7: Diagnostic detail shall remain actionable without exposing arbitrary user-owned file contents by default.
NFR-8: Lifecycle behavior shall not depend on paths, layouts, host identity, or assumptions unique to the implementation machine unless represented as declared local configuration.
NFR-9: Git commit identity may represent kit revision for this increment, while lifecycle and installed-state schemas remain explicitly versioned and migratable.
NFR-10: Repeated read-only operations shall be side-effect free, and repeated convergence at current state shall be stable and non-destructive.
NFR-11: Every blocking or warning outcome shall be attributable to a component, authority, stable reason, evidence source, affected scope, and safe next action.
NFR-12: Offline installation integrity, update source eligibility, and live external availability shall remain independently observable.

### Additional Requirements

- Preserve the Human → Orca → BMAD PM → agent-flow-kit → fresh specialized workers flow.
- Keep PLAN and explicitly activated ORCH modes separate; lifecycle commands never activate autonomous execution.
- Preserve ownership boundaries across Orca, BMAD, agent-flow-kit, agent-router, and prox-ops.
- Keep coding-agent host and inference/GPU host independent.
- Treat PR #5 only as a donor/reference using the REUSE / ADAPT / CONFLICT / GAP / OUT_OF_SCOPE migration map.
- Build successor work from current canonical master in fresh Orca-managed worktrees.
- Maintain traceability from every FR, AC, and NFR to story, artifact, test/evidence, and final status.
- Do not change frozen requirements for implementation convenience; amendments require a discovered contradiction/gap and recorded reconciliation.
- Real shared/global mutation follows isolated fixture proof and recovery gates.
- Completion requires implementation/review gates plus both-host, Git-channel, Orca smoke, and cleanup evidence.

### UX Design Requirements

No separate UX design contract applies. Lifecycle/operator visibility is specified directly in FR-72 through FR-90 and FR-95.

### FR Coverage Map

FR-1: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-2: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-3: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-4: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-5: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-6: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-7: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-8: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-9: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-10: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-11: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-12: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-13: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-14: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-15: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-16: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-17: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-18: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-19: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-20: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-21: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-22: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-23: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-24: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-25: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-26: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-27: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-28: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-29: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-30: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-31: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-32: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-33: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-34: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-35: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-36: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-37: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-38: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-39: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-40: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-41: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-42: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-43: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-44: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-45: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-46: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-47: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-48: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-49: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-50: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-51: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-52: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-53: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-54: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-55: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-56: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-57: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-58: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-59: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-60: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-61: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-62: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-63: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-64: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-65: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-66: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-67: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-68: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-69: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-70: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-71: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-72: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-73: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-74: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-75: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-76: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-77: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-78: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-79: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-80: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-81: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-82: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-83: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-84: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-85: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-86: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-87: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-88: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-89: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-90: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-91: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-92: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-93: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-94: Epic 1 - Trustworthy Portable Agent Execution Environment
FR-95: Epic 1 - Trustworthy Portable Agent Execution Environment

## Epic List

### Epic 1: Trustworthy Portable Agent Execution Environment

An operator can inspect, adopt, safely update, verify, and prove an agent-flow-kit installation across representative Orca hosts without losing legitimate local state, weakening authority boundaries, or breaking autonomous execution.

**FRs covered:** FR-1 through FR-95

**NFRs covered:** NFR-1 through NFR-12

**Acceptance covered:** AC-1 through AC-33

## Epic 1: Trustworthy Portable Agent Execution Environment

An operator can inspect, adopt, safely update, verify, and prove an agent-flow-kit installation across representative Orca hosts without losing legitimate local state, weakening authority boundaries, or breaking autonomous execution.

### Story 1.1: Understand Installed State Safely

As an agent-flow-kit fleet operator,
I want a deterministic read-only lifecycle foundation that explains installed ownership, revision, adaptation, drift, and source eligibility,
So that I can understand a legacy or managed host without mutating or trusting ambiguous state.

**Acceptance Criteria:**

**Given** a canonical agent-flow-kit checkout
**When** the lifecycle entrypoint evaluates it
**Then** it identifies the repository deterministically, records the exact checkout revision, validates lifecycle/state schema compatibility, and distinguishes eligible from ineligible mutation sources
**And** uncommitted managed inputs, unexpected revisions, downgrade conditions, unknown schemas, and noncanonical source selection receive stable states and reason codes without changing Git.

**Given** an installed revision that verifies as healthy and a checkout that is ineligible as an update source
**When** status runs
**Then** installed and execution integrity remain independently reportable as healthy
**And** mutation-source eligibility is blocked with its own stable reason without changing installed readiness to `BROKEN` or `NOT_READY`.

**Given** an installed or legacy host
**When** read-only status runs
**Then** it inventories every known component, registered BMAD target, canonical revision, applied/adopted revision, ownership class, integrity identity, and adaptation record
**And** it classifies current, update available, local adaptation, local drift, unknown/legacy, broken, source ineligible, interrupted, unavailable, incompatible, and not-evaluated states only where deterministically knowable from local evidence.

**Given** a network- or authentication-dependent fact such as current router or native provider-session availability
**When** default status runs without explicit live evaluation
**Then** the fact reports `NOT_EVALUATED` with reason `LIVE_PROBE_NOT_REQUESTED`
**And** status performs no router, provider-authentication, or other external live probe.

**Given** machine-, project-, user-, or native-runtime-owned state
**When** status compares hosts or canonical content
**Then** declared local differences are classified as legitimate adaptation or external state
**And** no heuristic or LLM judgment is used.

**Given** a variation inside otherwise kit-owned territory
**When** no valid registered adaptation matches its component, location, expected shape, and disposition
**Then** the variation is `LOCAL_DRIFT`
**And** a stale adaptation record cannot legitimize it.

**Given** an unknown or legacy installation
**When** inspect-only adoption analysis runs
**Then** it reports only `AUTO_ADOPTABLE`, `APPROVAL_REQUIRED`, or `REFUSED` as applicable
**And** no manifest is created, no revision advances, no ownership claim becomes durable, and no shared/global content changes until Story 1.2 completes a successful adoption transaction.

**Given** a managed destination path
**When** the lifecycle reads or hashes it
**Then** path type, containment, and symlink boundaries are validated
**And** unexpected redirection outside declared ownership fails closed.

**Given** status is run repeatedly
**When** no external state changes
**Then** filesystem, Git, runtime, authentication, router, and orchestration state remain unchanged
**And** normalized results are stable.

**Given** machine-readable output is requested
**When** status completes
**Then** it emits a documented versioned schema derived from the same normalized model as human output
**And** automation can distinguish state, reason, ownership, severity, blocked scope, mutation safety, owner action, evidence provenance, expected/observed identifiers, and not-evaluated versus unavailable without parsing prose.

**Given** lifecycle output or installed-state metadata is produced
**When** authentication or local configuration is inspected
**Then** no secret value, credential content, authorization header, or arbitrary user-owned content is emitted or persisted
**And** an anti-vacuity test proves a known sentinel secret would reach the result path without redaction but never appears in emitted output.

**Given** the Story 1.1 implementation
**When** its isolated deterministic gates run
**Then** tests cover repository identity, clean and dirty managed inputs, legacy recognition, every ownership/state branch, registered-adaptation validation, malformed schemas, path/symlink escape, side-effect-free repeated status, healthy installed state with dirty source, router not probed, repeated auto-adoptable analysis without mutation, secret-redaction anti-vacuity, JSON schema stability, and coarse exit semantics
**And** existing frozen orchestration tests remain green.

**Requirements covered:** FR-1–21, FR-24, FR-29–35, FR-72–84, FR-91, FR-93–94; NFR-1–12 where applicable.

### Story 1.2: Converge Managed State Without Losing Local Work

As an agent-flow-kit fleet operator,
I want adoption and update to converge managed artifacts transactionally while preserving declared local ownership,
So that I can maintain a host unattended when safe and receive an actionable refusal when owner judgment is required.

**Acceptance Criteria:**

**Given** any mutating lifecycle request
**When** adoption or update begins
**Then** the lifecycle computes the complete deterministic plan before its first managed write
**And** the plan covers every component, ownership class, source and destination identity, adaptation, conflict, permission prerequisite, migration, backup, recovery action, and expected final state.

**Given** a computed plan bound to source revision, source artifact identities, destination identities, manifest/applied state, adaptation records, and ownership/path observations
**When** execution reaches the mutation boundary
**Then** all bound inputs are revalidated immediately before the first managed write
**And** any material change makes the plan stale and stops execution without silently recomputing under an earlier approval.

**Given** a multi-component mutation has begun
**When** a safety-critical component prerequisite could have changed
**Then** path containment, symlink resolution, expected destination identity, and other relevant guards are revalidated immediately before that component's write
**And** a mismatch stops the transaction and triggers rollback of prior managed/user-state mutations where deterministic.

**Given** multiple mutation requests for the same installation
**When** they overlap
**Then** they are prevented or deterministically serialized
**And** read-only status does not report an in-progress installation as stably healthy.

**Given** a legacy installation classified by Story 1.1
**When** adoption is mechanically proven and non-destructive
**Then** it may auto-adopt and converge without interactive approval
**And** durable ownership and applied revision are recorded only after complete reconciliation and offline verification.

**Given** legacy content that crosses an ambiguity or ownership boundary
**When** adoption is requested
**Then** the lifecycle emits a deterministic plan with a stable identity/digest covering current state, proposed ownership, modifications, preserved content, recovery protection, and resulting state
**And** owner approval authorizes only that exact unchanged plan.

**Given** an approved adoption plan
**When** any authority-relevant input changes
**Then** the approval is invalidated and does not transfer to a recomputed plan
**And** the lifecycle requires fresh approval rather than silently regenerating and continuing.

**Given** adoption cannot distinguish ownership, preserve content, avoid credentials, maintain security/spend/routing boundaries, or recover a destructive shared-file change
**When** preflight evaluates it
**Then** the operation refuses with `NEEDS_OWNER` and performs no mutation.

**Given** an adopted host and eligible canonical checkout
**When** update runs
**Then** recognized managed copies and sections converge deterministically
**And** Git fetching, pulling, branch switching, route selection, orchestration activation, and external-authority mutation remain outside the operation.

**Given** a managed copy or managed section matching its recognized applied state
**When** canonical content advances compatibly
**Then** the lifecycle replaces only kit-owned content
**And** preserves machine-local configuration, target-project content, and content outside managed sections according to declared ownership.

**Given** content outside a managed section
**When** the managed section is upgraded
**Then** outside content is preserved byte-for-byte under the documented contract
**And** tests include leading/trailing content, missing final newline, supported line endings, duplicate or malformed markers, and boundary cases.

**Given** a managed component with unexplained drift, malformed markers, path redirection, or a stale adaptation record
**When** adoption or update is requested
**Then** replacement is blocked before the affected write
**And** free-form or LLM conflict merging is never attempted.

**Given** an explicitly registered adaptation
**When** update preflight runs
**Then** its component, location, expected shape, and disposition are revalidated
**And** the operation preserves, reevaluates, or requires owner review exactly as declared.

**Given** a mutation is ready to execute
**When** its first write occurs
**Then** a secret-free recovery journal and required backups already exist
**And** the journal identifies the operation, prior and target revisions, immutable plan identity, pre-mutation evidence, and completed steps as execution advances.

**Given** a lifecycle-managed write fails
**When** deterministic restoration is possible
**Then** all managed installation and user state changed by the attempted convergence is restored and restoration is verified
**And** the last successfully applied revision remains unchanged while secret-free diagnostic evidence may be retained.

**Given** restoration cannot complete or a non-transactional effect cannot be reversed
**When** failure handling completes
**Then** the installation reports `BROKEN` or `NEEDS_OWNER` with exact component evidence and recovery guidance
**And** partial state is never reported as successful convergence.

**Given** all planned mutations complete
**When** final local verification runs
**Then** every resulting managed copy, managed section, adaptation, target wiring structure, manifest invariant, lifecycle schema, and applied hash is checked without router, native-auth, Orca-worker, route, stamp, or other live-service dependency
**And** the applied-state manifest becomes the final durable authority transition only after verification succeeds.

**Given** the applied-state manifest has committed the target revision
**When** transaction housekeeping runs
**Then** the journal may be marked committed and temporary recovery metadata may be cleaned
**And** housekeeping cannot alter the meaning of the committed installation state.

**Given** an operation is interrupted before authority commit
**When** the next lifecycle command runs
**Then** it detects the incomplete journal before any new mutation
**And** deterministically rolls back when possible or stops with `NEEDS_OWNER`; resumable transactions are not required.

**Given** an unchanged installation already at the eligible revision
**When** update runs again
**Then** the plan contains no required mutation, hashes and applied revision remain unchanged, and the filesystem experiences no churn.

**Given** verification is requested after adoption or update
**When** Story 1.2 offline verify runs
**Then** it observes and proves installed-state integrity without repairing, probing live services, or activating orchestration
**And** live execution readiness remains for Story 1.3.

**Given** Story 1.2 destructive-path gates
**When** they run in isolated temporary homes
**Then** they cover managed-section insertion and upgrade, outside-content preservation, legacy transformations, immutable approval-plan invalidation, drift refusal, adaptation revalidation, symlink attack, concurrent mutation, backup/rollback, injected mid-operation failure, interrupted-operation recovery, false-applied-revision prevention, and idempotent no-op behavior
**And** no representative real-user state is touched.

**Requirements covered:** FR-22–28, FR-36–46, FR-91–94; AC-7–12, AC-28–30; NFR-1–10 and NFR-12.

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
**And** settled AFK-owned worker terminals remain closed across Orca reconnect, while active or user-owned sessions are preserved
**And** cleanup safely accounts for AFK-owned worktrees and local/remote topic branches after settlement or PR merge without deleting unowned, protected, ambiguous, unmerged, or uniquely committed branches
**And** every supervised dispatch establishes a durable completion watch that consumes and idempotently reconciles `worker_done`/escalation deliveries across PM turn boundaries, coordinator restart, and Orca reconnect without waiting for another human prompt
**And** completion is derived from Orca Task/Dispatch authority rather than terminal idleness, transcript text, session history, or tab state
**And** no dashboard, terminal scraper, router session registry, broad branch sweeper, or broader control-plane feature is introduced.

**Given** Story 1.3 deterministic tests
**When** offline and stubbed live table-driven suites run
**Then** they cover host/new-work independence, target isolation, optional-harness aggregation, exact-route refusal, router timeout isolation, validator anti-vacuity, native-auth classifications, route/funding-scoped environment conflicts, live timeout/freshness/non-authority, placement exclusion, orchestration bridge states, JSON/human parity, redaction, and stable exit semantics
**And** Story 1.1, Story 1.2, and frozen orchestration gates remain green.

**Requirements covered:** FR-47–90, FR-95; AC-13, AC-18, AC-20–24, AC-32–33 where implementation support precedes Story 1.4 proof; NFR-4–7 and NFR-11–12.

### Story 1.4: Prove Portability Across Real Orca Hosts

As an agent-flow-kit fleet operator,
I want retained real-host evidence that lifecycle updates preserve local state and still execute the approved autonomous workflow,
So that portability is proven by the actual fleet rather than inferred from fixture tests or CI.

**Acceptance Criteria:**

**Given** Stories 1.1–1.3 are implemented, reviewed, and green
**When** Story 1.4 begins
**Then** all isolated destructive-path, rollback, interruption, drift, concurrency, symlink, approval-invalidation, readiness, redaction, and orchestration-regression gates pass first
**And** no real-user mutation begins while those prerequisite gates are red.

**Given** Story 1.4 discovers a defect
**When** the defect is classified
**Then** state/ownership/status defects return to Story 1.1, mutation/rollback/adoption defects return to Story 1.2, readiness/compatibility defects return to Story 1.3, and only evidence-harness defects remain in Story 1.4
**And** fixes follow the normal implementation/review cycle before every materially affected acceptance proof reruns.

**Given** the observed Orca fleet
**When** representative hosts are selected
**Then** the primary is the current always-on remote host if it has meaningful legacy/stale state, otherwise the stalest qualifying active host
**And** the second is a distinct remote Orca host with evidence of at least two material differences in revision age, installation layout, harness state, target wiring, Orca configuration, path layout, or naturally available OS.

**Given** each selected host
**When** its baseline is captured
**Then** retained evidence identifies host, OS/architecture, relevant paths/layout, Git branch/SHA, installed/applied revision, ownership state, target BMAD wiring, harness classifications, Orca readiness, validator readiness, router readiness, observation time, and result-schema version
**And** the bundle explicitly records the dimensions that make the pair representative without retaining secrets.

**Given** the primary legacy/stale host
**When** its pre-mutation lifecycle is inspected
**Then** machine-readable status and offline verification truthfully classify installed state, ownership, source eligibility, drift/adaptation, target wiring, and readiness scopes
**And** any ambiguity blocks mutation before real-user state changes.

**Given** the reviewed and green successor implementation PR containing Stories 1.1–1.3
**When** the supported update channel is exercised
**Then** evidence retains its real merge SHA under applicable merge authority, the stale real host's external Git pull, detected `UPDATE_AVAILABLE`, lifecycle update, and verification
**And** no additional dummy product change is required and lifecycle tooling itself does not fetch, pull, switch, or merge Git state.

**Given** a safe primary-host update plan
**When** update executes
**Then** canonical managed components converge and the applied revision advances only after complete offline verification
**And** machine-local configuration, content outside managed global sections, target-project-owned content, and registered adaptations survive with before/after proof.

**Given** primary convergence succeeds before the smoke obtains a stamp
**When** offline and explicit live verification run
**Then** installation integrity, `HOST_EXECUTION_READY`, `NEW_WORK_READY`, `TARGET_READY(repo)`, validator readiness, harness readiness, and funding/auth safety are reported at their correct scopes
**And** `ROUTE_READY(execution_stamp)` remains `NOT_EVALUATED` until an actual accepted stamp exists.

**Given** the primary host is current
**When** update runs again
**Then** the retained second plan contains no required mutations, applied revision and managed hashes remain unchanged, local state remains unchanged, and the operation exits successfully
**And** `CURRENT` text alone is insufficient without no-churn evidence.

**Given** a harmless dedicated or disposable kit-owned real-host artifact
**When** a non-secret managed drift canary is introduced after backup
**Then** status reports `LOCAL_DRIFT` with stable reason and blocking scope, update refuses, and the lifecycle does not overwrite the canary
**And** exact restoration returns verification to healthy state.

**Given** the real-host drift test
**When** selecting the canary
**Then** it never targets credentials, auth/session files, tokens, access-critical shell/login files, unrelated user content, active BMAD work, or router/catalog authority
**And** any managed-section canary is inactive, trivially reversible, backed up, and restored byte-for-byte.

**Given** isolated forced-failure evidence
**When** update from revision A toward B is interrupted or fails
**Then** applied revision remains A, managed/user state restores or reports explicit non-success, and recovered A verifies
**And** no real-host fault injection is required to reproven already-covered destructive mechanics.

**Given** the second representative host
**When** status, adoption or update as appropriate, offline verification, and explicit live verification run
**Then** it proves lifecycle portability against the recorded distinct layout/configuration
**And** any host-specific defect blocks Story 1.4 until fixed by its owning story and relevant host proofs rerun.

**Given** the primary converged host and an already-wired BMAD target repository
**When** the orchestration acceptance smoke is prepared
**Then** it defines a disposable approved BMAD DEV story that creates exactly one tracked canary file with a frozen byte sequence
**And** it changes no production behavior or dependencies, uses no secrets or infrastructure, requires no merge, and declares its deterministic gate before dispatch.

**Given** the acceptance story
**When** central `/route` evaluates it
**Then** the natural valid route is accepted without locally preselecting or substituting harness, model, profile, effort, funding class, fallback, host, or placement
**And** evidence retains classification, route response, catalog/provenance, entitlement/funding, fallback, and accepted decision.

**Given** the accepted route
**When** its immutable stamp is minted
**Then** evidence retains stamp content, digest, expiry, provenance, and null override when applicable
**And** exact `ROUTE_READY(stamp)` is evaluated for the first time without mutating the stamped logical decision.

**Given** the accepted route requires local inference
**When** each dispatch attempt begins
**Then** physical placement is resolved late and retained only as ephemeral attempt evidence
**And** no placement is persisted into the immutable stamp or reused without revalidation.

**Given** dispatch is about to launch
**When** prelaunch checks run
**Then** stamp/catalog/provenance/expiry, selected harness availability/auth, funding mode, target wiring, validator contract, Orca capability, and route semantics are revalidated immediately
**And** any expiry or material change fails closed before worker creation.

**Given** prelaunch validation succeeds
**When** agent-flow-kit dispatches the story
**Then** Orca creates a fresh visible worktree, terminal/worker, and session using the exact selected harness/profile and resolved BMAD DEV persona
**And** hidden background execution does not qualify.

**Given** the worker is visible in Orca
**When** execution proceeds
**Then** retained independent evidence identifies worktree, worker/terminal ID, title, parent PM association where available, fresh context, `WORKER`/DEV state, phase, selected harness/profile, and loud `NEEDS_HUMAN` behavior
**And** route, stamp, dispatcher, and normalized worker state agree without substitution.

**Given** native subscription-backed execution
**When** the worker launches
**Then** evidence records safe auth-mode and funding-contract verdicts without credential values
**And** no unauthorized API-key/provider override, automatic login, or metered fallback occurs.

**Given** the worker reports completion
**When** the independent frozen gate runs
**Then** the changed-file set equals exactly the canary path, file bytes/hash equal the expected frozen value, and diff validation passes
**And** gate inputs, expected values, output, and exit status are retained independently of the worker's assertion.

**Given** the gate succeeds
**When** the worker returns its result
**Then** a compact result reaches the PM and completion is recognized
**And** the smoke proves PM → route → stamp → validation → optional late placement → Orca-visible worker → deterministic gate → result.

**Given** smoke evidence is captured outside the disposable target state
**When** cleanup runs
**Then** the worker completes/stops, disposable Orca worktree and branch are removed as appropriate, the target repository equals its exact pre-smoke state, and no evidence file, log, canary, branch, worktree, untracked artifact, or lifecycle/global drift remains there
**And** only the separate secret-free acceptance bundle is retained.

**Given** all Story 1.4 flows
**When** the evidence bundle is assembled
**Then** it contains indexed machine-readable baselines, host-diversity facts, plans, operation/journal identities, hashes, preservation proof, idempotence proof, drift refusal/restoration, offline/live readiness, Git-channel proof, two-host proof, orchestration proof, gate proof, and cleanup proof
**And** terminal scrollback alone is insufficient.

**Given** final traceability review
**When** every frozen FR, AC, and NFR is checked
**Then** each maps to a story, implementation artifact, deterministic test/evidence, and final status of `IMPLEMENTED + VERIFIED`, `ACCEPTANCE-ONLY + PROVEN`, or `EXPLICITLY BLOCKED`
**And** nothing disappears between the frozen PRD and evidence.

**Given** every required implementation, review, real-host, synchronization-channel, orchestration, and cleanup proof passes
**When** the PM issues the final verdict
**Then** it returns `AGENT-FLOW-KIT PORTABILITY GREEN`
**And** otherwise returns `AGENT-FLOW-KIT PORTABILITY BLOCKED — <specific evidence-backed reason>` without a partial-green substitute.

**Requirements covered:** AC-1–33; verification of all FR-1–95 and NFR-1–12; no new lifecycle, transaction, compatibility, routing, placement, or orchestration semantics beyond minimum frozen evidence hooks.

## Post-Baseline Additions (Stories 1.5–1.7) — NOT part of the frozen baseline

Everything above this heading is the frozen 95 FR / 33 AC / 12 NFR portability baseline and is unchanged. The stories below are post-baseline additions: they do not enter the `AGENT-FLOW-KIT PORTABILITY GREEN` verdict, add no requirement to Stories 1.1–1.4, and take their requirement authority from the PRD addendum `prds/prd-agent-flow-kit-2026-08-24/prd-addendum-1.5-1.6.md` (FR-96–126 and the cross-cutting harness-agnosticism NFR-13–15, numbering continued from the frozen FR-95/NFR-12). Stories 1.5 and 1.6 are sequenced strictly after Story 1.4; Story 1.7 is an evidence-only spike that may run in parallel with Story 1.3 and must complete before any subdelegation promotion. Threshold and budget defaults were owner-accepted 2026-08-26 as declared policy. **Stories 1.5, 1.6, 1.7 and PRD addendum FR-96–126 / NFR-13–15 FROZEN — owner-approved 2026-08-26. Sequenced after Story 1.4; 1.7 may run in parallel with 1.3. Outside the `AGENT-FLOW-KIT PORTABILITY GREEN` verdict.**

### Post-Baseline FR Coverage

FR-96–105, FR-121–126: Story 1.5 - Context Budgeting and Continuation
FR-106–117: Story 1.6 - Worker Feedback and PM Course-Correction Envelope
FR-118–120: Story 1.7 (Spike) - Persona Payload Viability on Local Profiles
FR-127–132: Story 1.8 - Orchestration Statusline Hook

### Story 1.5: Context Budgeting and Continuation

As an agent-flow-kit fleet operator,
I want every dispatched worker to run inside a declared context budget with checkpointing and supervised continuation,
So that a worker never silently exhausts its context window and over-sized stories surface as planning findings instead of degraded work.

Summary of scope (full acceptance criteria in `_bmad-output/implementation-artifacts/AFK-PORT-1.5.md`):

- The execution stamp carries the routed profile's context window exactly as the router catalog declares it; the kit never derives or substitutes a window, and a missing catalog window reports `NOT_EVALUATED`. No new router authority.
- The kit computes a deterministic pre-dispatch sizing estimate of the worker payload against the stamped window as advisory policy; the estimate is never sent to `/route` as a hard `context_size` minimum and never alters route selection. Accepted defaults: an estimate at or above the continuation threshold (85%) refuses dispatch fail-closed with a story-sizing finding — a payload already past the continuation point cannot complete work; ≥ 60% records a sizing-risk finding. The same sizing applies to continuation dispatches, with the continuation artifact counted in the payload.
- Usage thresholds with actions (accepted defaults): ≥ 70% of window requires a durable secret-free checkpoint artifact; ≥ 85% requires continuation — the worker stops at the next safe point (declared phase boundary), produces a compact continuation artifact, and returns a continuation-required thin result.
- Continuation runs as a fresh supervised Orca-visible worker for the same story under the same accepted stamp through the canonical dispatch path with the frozen prelaunch revalidation unchanged; expired stamps refresh via central `/route`. Continuation workers settle under the frozen Story 1.3 completion-watch and cleanup contracts without modification. Accepted cap: 2 continuations, then explicit PM decision.
- Usage comes from the harness/Orca as provided observations — no terminal scraping; unobservable usage reports `NOT_EVALUATED` with deterministic phase-boundary checkpoint fallback.
- Normalized orchestration state gains a bounded context-budget field (`OK`/`CHECKPOINT_DUE`/`CONTINUATION_REQUIRED`/`NOT_EVALUATED`) introduced by this story, with loud `NEEDS_HUMAN` when continuation cannot proceed. Repeated high usage is reported to the PM as a story-sizing finding.
- The coordinator's own context is in scope: the same model applies to the ORCH PM, sourcing its window by hierarchy — stamp if the PM session was routed, else the harness adapter's reported window, else `NOT_EVALUATED` with phase-boundary checkpoint fallback (the ORCH PM is human-started in Orca and not necessarily stamped). The PM consumes only thin results and watcher events (pointers to transcripts/gate logs/evidence bodies — reading a body is a defect); watchers deliver without a live PM turn under the frozen 1.3 completion-monitoring contract; at checkpoint the PM writes a compact epic-level continuation artifact; at continuation it stops dispatching, leaves in-flight workers under their watchers, and raises loud `NEEDS_HUMAN` with a ready-to-use resume instruction — the human starts the successor ORCH PM in Orca, which reconciles via the frozen 1.3 restart/reconnect contract; the kit never launches PM sessions (automatic successor launch is an explicit non-goal); in-flight workers are never orphaned because completion authority is Orca's; PM continuation count is part of the 1.6 epic budget.

**Requirements covered:** FR-96–105, FR-121–126 (PRD addendum); depends on frozen Story 1.3 contracts without modifying them.

### Story 1.6: Worker Feedback and PM Course-Correction Envelope

As an agent-flow-kit fleet operator,
I want workers to escalate structured findings in thin results and the PM to course-correct only inside an explicit recorded authority envelope with hard budgets,
So that discovered ambiguity, hidden scope, and conflicts pivot the plan instead of stalling or overreaching, while human design authority stays intact.

Summary of scope (full acceptance criteria in `_bmad-output/implementation-artifacts/AFK-PORT-1.6.md`):

- Thin results carry a structured escalation vocabulary from a documented stable-code registry — starting set `AC_AMBIGUOUS`, `SCOPE_LARGER`, `DEPENDENCY_FOUND`, `SPEC_CONFLICTS_CODE`, `NEEDS_DECISION` — with bounded evidence; the registry also carries the Story 1.5 context signals and follows the frozen FR-72–77 stable-code discipline.
- PM envelope — actions the PM may take alone: clarify an AC without changing intent, split a story preserving total approved scope, reorder/defer within the epic, re-route/retry/add a helper within budget, spend within budget. Actions that always require loud `NEEDS_HUMAN`: change epic goal or approved scope, change architecture/invariant, drop or rewrite an AC, exceed any budget. `NEEDS_DECISION` routes through the same envelope test; envelope ambiguity fails closed to `NEEDS_HUMAN`.
- Explicit machine-readable budgets per story/epic: fix/review cycles, cost class, wall time (accepted story defaults: 3 cycles, 2 continuations, 24h active wall time; cost class = stamped funding class, no upgrade); the epic budget includes PM continuation count. Exceeding any budget stops and escalates — no auto-cycling.
- Convergence policy for fix/review loops, bound to the cycle budget: a finding blocks a cycle only if it violates a frozen requirement AND is reproduced AND is reachable by one ordinary operator action; where review policy requires review, the first review is a full adversarial sweep and subsequent reviews are diff-scoped; same-class narrower findings go to a residual registry with recorded reason (presented at freeze — deferred, never dismissed); a fix introducing a NEW blocker stops the loop and escalates as a design fault; exit = clean full sweep OR clean diff-scoped review OR budget exhausted with only below-bar residuals; review requirement may vary by route class as declared policy. Helper workers are PM-dispatched through the normal route/stamp path — never worker-originated subdelegation.
- Every envelope action is recorded in the story record with triggering code, action, rationale, and budget state; an unrecorded action is a defect. The PM refines within approved scope, never redefines it.

**Requirements covered:** FR-106–117 (PRD addendum); consumes frozen Story 1.3 thin-result and `NEEDS_HUMAN` contracts and Story 1.5 signals without modifying frozen requirements.

### Story 1.7 (Spike): Persona Payload Viability on Local Profiles

As an agent-flow-kit fleet operator,
I want benchmark evidence of whether each selectable local profile can carry the full BMAD persona payload, a compact role contract, or no persona,
So that persona representation on constrained local resources becomes a deliberate, evidence-backed compatibility decision instead of a launcher shortcut or an unexamined prohibition.

Summary of scope (full acceptance criteria in `_bmad-output/implementation-artifacts/AFK-PORT-1.7.md`):

- Bounded evidence-only spike: no production code, no kit behavior change, no new routes/profiles/catalog entries; every benchmark run is an explicit spike-class, centrally routed evaluation with bounded spend — no local substitution, no metered fallback.
- Matrix: every selectable local profile in the router catalog × {full installed BMAD persona payload, compact role contract, no persona}, plus a vendor-profile baseline. Per cell: payload tokens vs declared context window, remaining work-context headroom, and canary task quality against deterministic gates declared before any run.
- Output: per-profile recommendation (`full` | `compact` | `unsuitable`) plus a machine-readable threshold rule the kit can apply — an input to Story 1.5 sizing policy and prerequisite evidence for subdelegation promotion.
- Records no prohibition: the persona-independence contract in `follow-on-worker-subdelegation.md` stands unchanged; product adoption of a compact representation remains a separate explicit reconciliation.
- Sequencing: may run in parallel with Story 1.3; before the subdelegation follow-on; Story 1.5 consumes its output when available but does not block on it.

**Requirements covered:** FR-118–120 (PRD addendum); consumes the router catalog and central routing as read-only authority and the persona-independence contract without modifying it.

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
