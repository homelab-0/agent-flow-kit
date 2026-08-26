---
title: Agent Flow Kit Portability and Maintenance
status: final
baseline: frozen
created: 2026-08-24
updated: 2026-08-24
---

# Agent Flow Kit Portability and Maintenance

## Product Vision

Make agent-flow-kit a portable, opt-in, safely maintainable product across representative Orca development hosts. A supported host must be able to explain whether its installation is known, current, recognizably stale, intentionally adapted, unexpectedly drifted, or broken; converge safely toward canonical Git state when deterministic; and make a trustworthy assertion that it is ready to participate in the approved Orca/BMAD orchestration workflow.

The product favors explicit ownership, fail-safe behavior, recoverability, and actionable diagnostics over clever automation. A ready verdict must be meaningful enough that approved orchestration can proceed without a manual installation audit.

## Increment Boundary

This increment provides four product capabilities:

1. Installed state, ownership, and drift
2. Safe lifecycle and convergence
3. Compatibility, dependency, and execution readiness
4. Lifecycle/operator visibility

Real-host portability and execution proof is the acceptance track across those capabilities, not a separate product subsystem.

This increment does not include centralized fleet management, background reconciliation, dashboards, AI Control Plane development, router or catalog policy changes, Kubernetes work, GPU onboarding, local-agent, model lifecycle, secrets management, automatic installation or upgrading of Claude Code or Codex, support for additional harnesses, or unrelated orchestration enhancements.

## Architecture and Authority Boundaries

The authoritative workflow is Human → Orca → BMAD PM → agent-flow-kit → fresh specialized workers. Orca is the normal front door and execution environment; agent-flow-kit turns explicitly approved work into visible disposable-worker execution without duplicating resource intelligence.

- **Orca owns** coding-agent execution and host selection, worktrees and branches, terminals, process lifecycle and supervision, session identity/state, execution environment, provider endpoints, native credential/session material, secret isolation, and worker concurrency. The lifecycle may validate required Orca capabilities but shall not replace Orca as process or session manager.
- **BMAD owns** methodology, interactive planning, specialized personas, story semantics, acceptance criteria, and task-role selection. `PLAN` and explicitly invoked `ORCH` are separate modes; BMAD presence or lifecycle maintenance never activates autonomous execution.
- **agent-flow-kit owns** autonomous delegation of approved work, disposable-worker orchestration, persona injection and handoff, deterministic gates, retry/fallback control flow, thin results, PM-oriented review/PR automation, Orca-visible dispatch, normalized local orchestration state, and this increment's lifecycle management of kit-owned artifacts.
- **agent-router owns** task-to-resource recommendation, approved CLI/model relationships, capability profiles, effort, funding/entitlement recommendations, placement policy, and live placement. Runtime state may remove availability but may not create legal routes.
- **prox-ops owns** infrastructure-as-code, Kubernetes, KServe, gateway/router deployment, secrets/identity infrastructure, observability, and the Git-managed resource/model catalog. It is an infrastructure repository, not the workflow's product boundary.

The coding-agent host selected by Orca and physical inference/GPU placement selected through the control plane are independent. The lifecycle shall not depend on a development host having a GPU or implement GPU discovery, VRAM measurement, heartbeats, model/cache lifecycle, inference runtime installation, or physical placement.

Native Claude/Codex subscription credentials remain in Orca-launched native sessions and shall not enter lifecycle manifests or router requests. The portable dependency direction is agent-flow-kit → compatible installed AI Control Plane client/validator, not agent-flow-kit → prox-ops source tree.

Reconciliation authority order is: frozen PRD product rulings → architecture invariants and responsibility boundaries → proven EPIC-035 behavior → current agent-flow-kit implementation → PR #5 evidence.

## Feature Requirements

### 1. Installed State, Ownership, and Drift

#### Inventory and Ownership

- **FR-1:** The lifecycle shall identify the canonical checked-out kit revision and the last successfully applied or adopted revision.
- **FR-2:** The lifecycle shall inventory installed kit components, registered target BMAD repositories, and expected integrity or version metadata where appropriate.
- **FR-3:** Every inventoried component or managed region shall have an explicit ownership classification, including managed copy, managed or merged section, machine-local configuration, target-project wiring, or external native-runtime state as applicable.
- **FR-4:** The local state manifest shall contain no secrets and shall not act as a routing, provider, model, catalog, or placement authority.
- **FR-5:** Each host shall manage and report its own installed state without requiring centralized fleet inventory, remote state collection, or a fleet service.

#### Adaptation and Drift

- **FR-6:** A local difference shall be classified as a known adaptation only when it is deterministically explained by a declared ownership rule or an explicit registered adaptation. Heuristic or LLM judgment shall not establish legitimacy.
- **FR-7:** Differences in schema-declared machine-owned, project-owned, user-owned, or external-runtime regions shall be reported as `LOCAL_ADAPTATION` or external state as appropriate, not kit drift, without requiring one-off approval for each value change.
- **FR-8:** A variation inside otherwise kit-owned territory shall require a secret-free registered adaptation identifying the component, affected path or section, reason or type, expected local shape or hash where appropriate, and update disposition.
- **FR-9:** Any unexplained difference in kit-owned territory shall be reported as `LOCAL_DRIFT`. Managed-copy differences and managed-section edits are drift unless covered by an explicit adaptation; content outside managed sections remains user-owned.

#### Legacy Adoption Authority

- **FR-10:** Legacy or unknown adoption shall begin inspect-only. The lifecycle may auto-adopt only when ownership and equivalence are mechanically provable and adoption records an established baseline without modifying user-owned content.
- **FR-11:** Auto-adoption may cover exact current or recognized-prior canonical content, unambiguous matching managed sections, schema-declared local fields, exact recognized target wiring, and other cases where adoption only records already-proven state.
- **FR-12:** When ownership overlaps, shared content would change, recognizable wiring is locally modified, multiple interpretations exist, old artifacts require replacement, or a local modification must become an exception, the lifecycle shall present a deterministic plan for owner approval before mutation.
- **FR-13:** An adoption plan shall show current state, proposed ownership, proposed modifications, preserved local content, recovery protection, and resulting managed state. Approval grants authority only for that plan.
- **FR-14:** The lifecycle shall refuse with `NEEDS_OWNER` when it cannot safely distinguish ownership, would overwrite unexplained edits, would capture secrets or native credential/session state, would weaken policy or security boundaries, would cross into router/catalog or infrastructure authority, lacks a safe compatibility path, or cannot preserve or recover a destructive shared-file change.

#### State and Readiness

- **FR-15:** Component state shall distinguish at least `CURRENT`, `LOCAL_ADAPTATION`, `UPDATE_AVAILABLE`, `LOCAL_DRIFT`, `BROKEN`, and `UNKNOWN` or legacy-unadopted state.
- **FR-16:** Overall readiness shall distinguish at least `READY`, `READY_WITH_ADAPTATION`, `READY_WITH_WARNINGS`, `NOT_READY`, and `NEEDS_OWNER`, while retaining every component-level result and required action.
- **FR-17:** `CURRENT` execution-critical components yield `READY`; verified intentional adaptation yields `READY_WITH_ADAPTATION`; a compatible stale revision or noncritical issue yields `READY_WITH_WARNINGS` unless compatibility metadata mandates migration.
- **FR-18:** Missing, malformed, partial, inconsistent, or deterministically failing required components yield `NOT_READY`. Unresolved execution-critical drift or ownership ambiguity yields `NEEDS_OWNER` and blocks orchestration readiness.
- **FR-19:** Noncritical managed drift may yield `READY_WITH_WARNINGS`, but update shall still refuse to overwrite it until reconciled.
- **FR-20:** Dependency availability shall be reported separately from ownership drift. A missing mandatory dependency makes orchestration `NOT_READY`; an unavailable optional harness may disable only that harness when another approved route remains executable.
- **FR-21:** Readiness shall aggregate to the strongest applicable condition within each readiness scope without hiding component detail. A failure scoped to one target, route, harness, or live operation shall not poison unrelated scopes. Reporting shall not invent fallback routing or resource authority.

### 2. Safe Lifecycle and Convergence

#### Operation Semantics

- **FR-22:** The product shall provide one obvious lifecycle entry point with coherent read-only status, ownership-establishing adoption, deterministic update or synchronization, and read-only verification behaviors. Exact command names remain a design decision.
- **FR-23:** Every mutating operation shall compute and validate its complete deterministic plan before its first managed write. Provably safe, conflict-free operations may apply unattended; human approval is required only when the plan crosses an ambiguity or ownership boundary.
- **FR-24:** `status` shall be side-effect free and report source and applied revisions, installed components, ownership and state, known update availability, drift and adaptations, dependency and readiness findings, and the next safe action without mutating filesystem, Git, runtime, authentication, or orchestration state.
- **FR-25:** Adoption shall inspect first; classify the operation as auto-adopt, approval-required, or refuse; reconcile only within granted authority; verify the result; and establish the initial managed-state manifest only after successful completion.
- **FR-26:** Synchronization or update shall never silently claim unknown files. For an adopted host, it shall compare the eligible source and applied revisions, compute the whole change plan, refuse unresolved conflicts, preserve declared local state, update recognized managed content, verify the result, and advance applied state only after complete success.
- **FR-27:** `verify` shall observe and prove the declared installed state without repairing it. It shall check component presence, managed integrity or sections, declared adaptations, manifest consistency, target wiring, mandatory dependency compatibility, and applicable safe router or validator readiness.
- **FR-28:** Lifecycle operations shall not activate orchestration or mutate external authority owned by Orca, native runtimes, or agent-router.

#### Canonical Source Eligibility

- **FR-29:** A mutating operation shall accept source content only from a checkout whose repository identity, exact commit, managed input set, and lifecycle compatibility are deterministically known. Directory naming alone is insufficient evidence of identity.
- **FR-30:** Uncommitted content in any canonical managed-source path shall block mutation. Dirt provably outside the input set may warn without blocking, but shall never influence installed output. A conservative clean-checkout requirement is acceptable for the first increment.
- **FR-31:** Status and verification may run from detached or unexpected revisions. Ordinary unattended update shall require a recognized canonical or default-branch source; applying a detached, non-default, older, or otherwise noncanonical revision requires explicit source-selection or rollback intent.
- **FR-32:** The resulting state shall record the exact commit applied. An older source shall never be treated as an ordinary update, and downgrade or rollback shall require explicit intent plus compatible migration metadata.
- **FR-33:** Lifecycle and state schema versions shall be explicit and machine-readable. Recognized current schemas may proceed; recognized older schemas may migrate under declared rules; unknown newer major schemas shall refuse; supported legacy baselines shall use explicit migration or adoption paths; arbitrary unrecognized shapes shall yield `NEEDS_OWNER`.
- **FR-34:** The lifecycle shall consume an operator- or agent-selected Git revision and shall not fetch, pull, merge, rebase, switch branches, or otherwise select Git state in this increment. It may safely report upstream divergence when deterministically knowable.
- **FR-35:** Source eligibility and installed execution readiness shall remain distinct dimensions. An ineligible checkout shall block update without making a separately verified installed revision `BROKEN`; an eligible checkout shall not imply that installed automation is ready.

#### Managed Content Convergence

- **FR-36:** Managed copies that still match their recognized applied canonical state may be deterministically replaced by eligible target canonical content. Unexplained differences shall block replacement.
- **FR-37:** Content outside a managed section shall remain user-owned and be preserved byte-for-byte except for explicitly contracted unavoidable formatting behavior.
- **FR-38:** A managed section matching its recognized applied or valid migratable canonical revision may be deterministically replaced with the target section. A registered adaptation shall follow its declared disposition. Any unexplained edit inside the section shall yield `LOCAL_DRIFT` and `NEEDS_OWNER`.
- **FR-39:** The lifecycle shall not use free-form or LLM merging to resolve managed-content conflicts.

#### Failure, Recovery, and Commit Point

- **FR-40:** Preflight shall cover every planned component, ownership and source expectation, local adaptation, conflict, directory and permission prerequisite, migration, recovery requirement, and expected final state before mutation begins.
- **FR-41:** Before its first write, a mutating operation shall initialize secret-free recovery evidence identifying the operation, previous and target revisions, planned components, pre-mutation state, and required backups; it shall then record completed mutations as the operation advances.
- **FR-42:** On failure, the lifecycle shall automatically restore and verify pre-operation filesystem state for changes it made when deterministic restoration is possible. Non-transactional effects shall be reported truthfully; incomplete restoration yields `BROKEN` or `NEEDS_OWNER` with component evidence and recovery instructions.
- **FR-43:** The last successfully applied revision shall advance only after every planned mutation and final deterministic verification and consistency check succeeds. A diagnosed partial state is never successful convergence.
- **FR-44:** Final applied-state metadata shall be committed as the last operation and in a manner that prevents partial state from claiming the target revision.
- **FR-45:** A subsequent lifecycle invocation shall detect an incomplete operation before new mutation. It shall prefer deterministic rollback for this increment; otherwise it shall stop with `NEEDS_OWNER`. Safe resume is not required.
- **FR-46:** Reapplying an already-applied eligible revision to an unchanged installation shall be a stable, non-destructive no-op with no installation churn.
- **FR-91:** Every mutation plan shall bind to the exact source inputs, destination observations, manifest state, and approved adaptation records used to compute it. The lifecycle shall revalidate that binding immediately before mutation and fail if relevant state changed.
- **FR-92:** Concurrent mutating lifecycle operations for the same installation shall be prevented or deterministically serialized. Read-only operations shall not report a transient in-progress state as a stable healthy result.
- **FR-93:** Before reading, hashing, backing up, or replacing a managed destination, the lifecycle shall validate its path type and containment and shall refuse unexpected symlinks or path redirection that could escape the declared ownership boundary.
- **FR-94:** Registered adaptations shall be revalidated against their declared expected shape and disposition during status, update preflight, and verification. A stale or mismatched adaptation record shall not legitimize new drift.

### 3. Compatibility, Dependency, and Execution Readiness

#### Scoped Readiness

- **FR-47:** Readiness shall be reported at distinct scopes: `HOST_EXECUTION_READY`, `NEW_WORK_READY`, `TARGET_READY(target_repo)`, and `ROUTE_READY(execution_stamp)`. A dependency failure shall block the narrowest scope it invalidates.
- **FR-48:** A host may be reported execution-ready only when the installed kit verifies and live evaluation proves Orca usable, a compatible validator/client usable, and at least one centrally approved harness execution path locally usable. Offline evaluation shall report unevaluated live dependencies rather than asserting host execution readiness.
- **FR-49:** A specific execution shall additionally require ready target BMAD wiring, host compatibility with the accepted route, a usable selected harness, and successful final stamp validation.
- **FR-50:** Fresh routing shall require central router availability. Router unavailability shall make `NEW_WORK_READY` false without necessarily invalidating an already accepted, unexpired stamp that can still pass all validator, catalog, provenance, and policy requirements without rerouting.
- **FR-51:** Target BMAD readiness shall be repository-scoped. An incompatible target shall not make unrelated targets globally unavailable, but shall block every execution for which its required persona, templates, contracts, or policy wiring cannot resolve.
- **FR-52:** Claude Code and Codex shall be first-class but individually optional harnesses. One unavailable harness shall not block host execution when another complete centrally approved path is healthy; it shall block every accepted route that specifically selects the unavailable harness.
- **FR-53:** The kit shall never substitute a different local harness or resource for an accepted route. It shall require a fresh central decision, another compatible host, or owner intervention.

#### Routine Proof Depth

- **FR-54:** Execution-critical readiness shall require more than binary or file presence and shall prove the deepest safe property available without performing a real implementation task. Routine verification remains non-destructive; real worker creation belongs to acceptance testing unless a dependency exposes a safe dry-run contract.
- **FR-55:** Orca readiness shall verify availability, a supported version or capability contract, runtime reachability, visible-worker or orchestration capability, and required launch fields. Routine verification shall not create disposable workers solely to report ready.
- **FR-56:** Target BMAD readiness shall mechanically verify recognized project structure, compatible wiring/schema, resolvable PM and worker personas, referenced templates/files, integrity of managed wiring, and absence of unresolved ownership ambiguity.
- **FR-57:** Router live-readiness shall verify reachability, trusted transport, required authentication, status response, API shape, and compatible catalog/schema/provenance. An explicitly requested live mode may use a harmless synthetic route request; offline installation verification shall not require router availability.
- **FR-58:** Validator/client readiness shall verify executable/interface availability, compatible contract versions, a known-valid fixture, rejection of tampered evidence, rejection of expired or incompatible evidence, catalog/provenance semantics, and recordable executable identity. At least one negative test shall prevent an always-success validator from passing.
- **FR-59:** An explicitly requested live verification may validate a harmless fresh route/stamp against the deployed control plane without launching provider work.
- **FR-60:** Claude Code and Codex readiness shall verify executable resolution, supported invocation capabilities, safe native authentication status where available, required selection/permission semantics, and absence of configuration that would silently redirect the approved path.
- **FR-61:** Authentication verification shall use safe native status or capability mechanisms where available and shall not read, copy, persist, or display credential values. Expired or unusable sessions shall report an actionable harness-unavailable state and shall never trigger automatic login.
- **FR-62:** For currently approved native-subscription execution paths, readiness shall detect known environment, auth-mode, provider, or base-URL conditions that would select an unauthorized metered path, without inspecting credential values. The affected route shall be not ready and shall not spill over automatically.
- **FR-63:** Future explicitly authorized API-backed entitlements may be modeled separately; credential shape alone shall not be treated as universal proof of funding class.

#### Compatibility Authority

- **FR-64:** An executable path shall be the intersection of router-approved execution profile, kit-supported launch contract, observed host capabilities, compatible target BMAD wiring, and a valid final stamp.
- **FR-65:** Router/catalog authority shall own legal harness/profile relationships, model/profile legality, entitlement or funding class, placement requirements, catalog provenance, expiry, and resource policy. Runtime observation may remove availability but shall not add authority.
- **FR-66:** agent-flow-kit shall own declarations for lifecycle state schemas, supported BMAD wiring contracts, supported execution-stamp and validator contracts, required Orca launch capabilities, and harness invocation features it can execute. These declarations describe executor capability, not routing policy.
- **FR-67:** The validator/client shall expose machine-readable identity and supported contract, stamp-schema, catalog, and provenance semantics. The kit shall check and record that contract without reimplementing validator policy.
- **FR-68:** Orca compatibility shall prefer explicit capabilities plus version information over version-only assumptions, including worktree ownership, visible worker launch, explicit argument/environment transport, provider runtime, and session/process isolation.
- **FR-69:** BMAD targets shall expose or permit deterministic recognition of BMAD integration, agent-flow-kit wiring, and persona/template resolution contracts. Mere directory presence shall not prove compatibility.
- **FR-70:** Harness compatibility shall prefer verified capabilities over unnecessarily narrow version allowlists. A newer version with positively verified required capabilities may be ready with warning; inability to prove invocation, permission, or subscription-auth semantics shall make that harness path not ready.
- **FR-71:** Unknown compatibility affecting stamp/validator semantics, central route interpretation, selected harness/model invocation, security or permission posture, funding/auth mode, Orca launch semantics, target persona/wiring, or deterministic gates shall block the affected route. Noncritical informational uncertainty may remain ready with an explicit bounded warning.

The existing `agent-stamp-validate` bridge may remain a supported transitional dependency. The long-term contract is an externally distributed compatible AI Control Plane validator/client, not a prox-ops source checkout.

This increment does not install or upgrade Claude Code or Codex, manage subscription credentials, change router policy, add harnesses, manage models or GPUs, solve the local-code-standard launch compatibility gap, or package the final standalone AI Control Plane client.

### 4. Lifecycle/Operator Visibility

#### Normalized Output Contract

- **FR-72:** Human-readable and machine-readable lifecycle output shall derive from one normalized result model. Machine output shall use a documented, versioned schema with stable state codes, reason codes, blocking scopes, and exit semantics; automation shall not parse human prose.
- **FR-73:** The machine contract shall represent, where relevant, schema version, command, operation identity, checkout and applied revisions, source eligibility, host and new-work readiness, target identity/readiness, overall state, and component results. It shall distinguish an evaluated false result, a field outside the command's scope, a temporarily unavailable observation, and a probe that was not performed.
- **FR-74:** Stable machine states shall cover the Capability 1 states plus operation-specific distinctions including source ineligible, interrupted update, not evaluated, unavailable, and incompatible. Machine-code meaning shall not silently change within a schema major version.
- **FR-75:** Every nontrivial warning or block shall include a documented stable reason code sufficient for automation to distinguish managed drift, source ineligibility, dependency unavailability or incompatibility, target wiring failure, harness auth/support failure, metered fallback, owner approval, and other actionable causes.
- **FR-76:** Automation shall be able to determine affected component, ownership class, state, reason, severity, blocked readiness scope, owner-action requirement, transience, mutation safety, and requested-operation success without prose parsing.
- **FR-77:** Exit codes shall remain coarse and stable: success with no requested-scope block; owner action/conflict; deterministic not-ready or verification failure; source/precondition refusal; live dependency unavailable or timed out; and command/internal/usage failure. `READY_WITH_WARNINGS` and `READY_WITH_ADAPTATION` count as success.

#### Actionability, Evidence, and Redaction

- **FR-78:** Each warning or failure shall explain what is wrong, why it matters, which authority owns it, and what can safely happen next through component, ownership, state, reason, severity, blocking scope, expected/observed evidence, impact, owner, required action, and recovery guidance as applicable.
- **FR-79:** Managed-state evidence shall prefer bounded identifiers such as revisions, hashes, section identities, contract versions, and wiring versions over raw file dumps.
- **FR-80:** Results shall identify useful evidence provenance such as hash comparison, file structure, version probe, capability probe, auth-status probe, router status, validator fixture, BMAD resolution, or operation journal.
- **FR-81:** Lifecycle output shall never emit credentials, tokens, secret values or contents, authorization headers, or credential-store contents. It may report safe auth state, credential source category, conflicting variable names, and redacted presence without exposing values.
- **FR-82:** Paths may be reported when useful for remediation, but arbitrary user-owned or sensitive configuration content shall not be emitted by default. Machine output shall not become a secret-exfiltration surface.

#### Offline and Live Evaluation

- **FR-83:** Ordinary status and verification shall default to deterministic offline evaluation of installed state, source/applied revisions, ownership, managed integrity, local configuration shape, target structure, locally discoverable capabilities, validator offline fixtures, and operation recovery state.
- **FR-84:** External facts not tested offline shall report `NOT_EVALUATED` rather than ready.
- **FR-85:** An explicit live mode may add bounded safe router, validator/control-plane, native harness auth, Orca, and other readiness probes. Live probes shall use bounded timeouts, avoid implementation work and provider-token consumption where safe probes exist, never log in automatically, never activate metered fallback, and never mutate external authority.
- **FR-86:** Live timeout or outage shall report `UNAVAILABLE` or timeout distinctly from deterministic failure, including observation time and timeout metadata. It shall affect only the relevant live readiness scope and shall not make verified installed state `BROKEN`.
- **FR-87:** Transient live observations shall not be persisted into the durable installation manifest as installed-state truth.

#### Existing Orchestration Visibility Bridge

- **FR-88:** Acceptance shall prove lifecycle adoption and update preserve existing Orca-visible workers, `PLAN`/`ORCH`/`WORKER` resolution, persona/task/route/phase/gate information, loud `NEEDS HUMAN`, and agent-flow-kit/Orca ownership of orchestration state.
- **FR-89:** When normalized current orchestration state exists, lifecycle output shall expose a bounded read-only summary covering active/inactive/unknown state, mode, phase, task, and needs-human status, plus already-available worker counts where practical.
- **FR-90:** The lifecycle shall consume normalized orchestration state without heuristically reconstructing it from terminals or logs and without becoming its owner. Missing state shall report not available and shall not make ordinary lifecycle readiness fail.
- **FR-95:** Live results shall bind to the target, route/stamp, and observed dependency identities evaluated. A later launch shall not reuse them as proof when the stamp expired, the target changed, required capability state changed, or the observation exceeded its declared freshness.

This increment does not add dashboards, web UI, centralized fleet/session state, terminal scraping, historical telemetry, fleet topology, enhanced route or placement visualization, a router-owned session registry, or major statusline redesign.

## Acceptance Track: Real-Host Portability and Execution Proof

#### Representative Hosts

- **AC-1:** Acceptance shall use two real existing remote Orca development hosts selected from observed fleet state. The laptop, Bazzite 5090, Cachy, and GPU hosts solely by virtue of their GPUs are not required.
- **AC-2:** The primary host shall be the current always-on remote Orca host when it has meaningful legacy/stale state; otherwise use the stalest active qualifying host. It must have an existing pre-lifecycle installation, real global policy/state, operational Orca, an existing or historical BMAD target, at least one usable approved harness path, and enough legacy state to exercise adoption or migration.
- **AC-3:** The second host shall be a distinct machine and differ in at least two meaningful portability dimensions such as installation age or layout, harness availability/auth state, BMAD target wiring, Orca layout, paths, or naturally available OS/distribution.
- **AC-4:** A portability defect on the second host keeps the capability blocked until fixed through the normal implementation/review cycle and relevant host proofs rerun.

#### Retained Evidence

- **AC-5:** Each evidence item shall identify host, observation time, command or action, checkout revision, applied revision, and result-schema version without retaining secrets.
- **AC-6:** Each host shall retain baseline identity, OS/architecture, relevant layout, Git state, installed/applied revision when known, machine-readable status and verify results, ownership classification, target wiring, harness availability, and Orca/validator/router readiness.
- **AC-7:** Every mutation shall retain its normalized complete plan, including source and prior revisions, components, ownership, proposed mutations, preserved adaptations, conflicts/refusals, and recovery protections.
- **AC-8:** Convergence evidence shall retain operation identity/result, before/after managed hashes and section identities, final applied revision, and final machine-readable status and verification.
- **AC-9:** Preservation evidence shall prove non-secret machine-local configuration, content outside managed global sections, and project-owned target content survived, preferring hashes and bounded structure.
- **AC-10:** Idempotence evidence shall include a second computed plan and update result proving no required mutation, unchanged applied revision and managed hashes, unchanged local state, and successful exit.
- **AC-11:** A harmless managed drift canary shall prove recognized-good hash, injected drift, `LOCAL_DRIFT`, stable reason, owner/blocking scope, update refusal without overwrite, exact restoration, and healthy verification.
- **AC-12:** An isolated forced-failure proof shall show attempted A→B update failure leaves the applied revision at A, restores or explicitly diagnoses state, and verifies recovered A.
- **AC-13:** Offline evidence shall cover lifecycle integrity, managed artifacts, BMAD resolution, validator fixtures, and local capabilities. Live evidence shall cover router transport/API, validator/control-plane compatibility, Orca capability, native harness auth classification, and funding/spend safety while distinguishing outage from installation failure.
- **AC-14:** The retained evidence bundle shall contain machine-readable artifacts and a concise index in the project evidence area; terminal scrollback alone is insufficient.

#### Primary and Second Host Flows

- **AC-15:** The primary flow shall execute: inspect legacy/stale host → baseline status → ownership classification → adoption if required → canonical Git change via real PR/merge → external Git pull → update availability → update → offline verify → live verify → current/execution-ready → idempotent second update → drift refusal/restoration.
- **AC-16:** The second flow shall execute: inspect → status → adoption or update as appropriate → offline verify → live verify.
- **AC-17:** The update channel proof shall retain the canonical PR, merge SHA, stale-host pull, update, and verification. Lifecycle tooling itself does not perform the Git pull.

#### Full Orchestration Smoke

- **AC-18:** After convergence, the primary host shall execute one disposable, pre-approved BMAD DEV acceptance story through PM → central route → accepted stamp → immediate validation → fresh Orca-visible worker → selected harness/profile → deterministic gate → compact result → PM completion.
- **AC-19:** The smoke task shall create exactly one tracked canary file with a frozen byte sequence, change no production behavior or dependencies, contain no secrets or infrastructure changes, and require no merge.
- **AC-20:** Routing evidence shall retain classification, response, harness, profile, effort, funding class, fallback, catalog/provenance, and accepted decision. The natural valid route shall be used without local harness substitution.
- **AC-21:** Stamp evidence shall retain immutable accepted content, digest, expiry, provenance, and null override when no override occurs; validation shall rerun immediately before launch.
- **AC-32:** If the accepted execution uses local inference, evidence shall prove physical placement was resolved late, close to each launch attempt, without changing the accepted logical route. If local inference is not selected, placement shall be reported as not applicable.
- **AC-33:** A stamp or validated launch condition that expires or changes between validation and worker start shall fail closed and shall not create the worker.
- **AC-22:** Independent launch/session evidence shall prove requested and resolved DEV persona and normalized `WORKER`/DEV state. Route, stamp, dispatcher, and normalized worker state shall agree on the selected harness/profile.
- **AC-23:** Pre-launch evidence shall prove usable native subscription state, no unauthorized provider/API-key override, preserved route funding class, and no authorized or used metered fallback without exposing credentials.
- **AC-24:** Orca evidence shall identify the fresh visible worktree, terminal/worker, title, PM association where available, worker state, and fresh session/context. Hidden background execution does not qualify.
- **AC-25:** A frozen independent gate shall prove the changed-file set is exactly the canary path, bytes/hash equal the expected value, and diff validation passes. Gate inputs, expected values, result, and exit shall be retained.
- **AC-26:** Acceptance requires worker success, gate success, compact result return, and PM recognition of completion.
- **AC-27:** Cleanup shall stop/complete the worker, remove the disposable Orca worktree and branch as appropriate, restore the target repository exactly, prove no canary remains, and prove no lifecycle/global drift was introduced while retaining only evidence.

#### Safety Progression and Final Verdict

- **AC-28:** Destructive or shared-global mechanisms shall first pass isolated temporary-HOME tests for managed-section insertion/upgrade, outside-content preservation, drift refusal, backup/rollback, injected failure, interruption recovery, and legacy adoption transformations.
- **AC-29:** Real host mutation may proceed only after fixture gates pass, complete preflight succeeds, ownership is classified, recovery material exists, and unexplained drift is absent.
- **AC-30:** Real drift injection shall use a harmless dedicated or disposable kit-owned artifact where possible. It shall never target credentials, auth/session files, tokens, access-critical shell/login files, unrelated user content, active product work, or router/catalog authority.
- **AC-31:** `AGENT-FLOW-KIT PORTABILITY GREEN` requires all isolated safety, primary convergence, preservation, drift refusal, idempotence, revision-commit safety, second-host, offline/live readiness, Git-channel, full orchestration-smoke, and cleanup proofs to pass. Otherwise the verdict is `AGENT-FLOW-KIT PORTABILITY BLOCKED` with a specific evidence-backed reason.

Acceptance does not require every fleet host, laptop adoption, GPU-host inclusion solely because GPUs exist, soak tests, broad heterogeneous-OS certification, or a formal release qualification matrix.

## Success Metrics and Counter-Metrics

- Two distinct representative remote Orca hosts complete their required acceptance flows with retained machine-readable evidence.
- Zero unexplained loss or mutation of machine-local, project-owned, or user-owned content.
- Zero false advancement of applied revision after failed or interrupted mutation.
- Zero secret values captured in manifests, lifecycle output, logs, or evidence bundles.
- Zero unauthorized metered fallback or local substitution of centrally accepted execution decisions.
- The second update on converged state requires zero mutations and causes zero content churn.
- One lifecycle-updated primary host completes the full production orchestration smoke and deterministic gate.

Counter-metrics: speed of update, number of automated mutations, number of supported operating systems, number of harnesses, fleet coverage, dashboard richness, and reduced owner prompts are not success measures when achieved by weakening ownership, safety, evidence, or authority boundaries.

## Non-Functional Requirements

### Safety and Integrity

- **NFR-1:** All ownership, drift, compatibility, and convergence decisions shall be deterministic and reproducible from declared state and machine-readable contracts.
- **NFR-2:** Mutating operations shall fail closed on ambiguous authority and shall not make destructive guesses.
- **NFR-3:** State transitions and retained evidence shall never claim successful convergence before complete deterministic verification.
- **NFR-4:** Installation lifecycle behavior shall remain separate from orchestration activation and from router, Orca, BMAD, and native-runtime authority.

### Security and Spend Control

- **NFR-5:** Manifests, journals, output, logs, and evidence shall not persist or disclose personal provider credentials or secret values.
- **NFR-6:** Native subscription authentication shall remain native, and unauthorized metered execution or credential-mode substitution shall fail closed.
- **NFR-7:** Diagnostic detail shall remain actionable without exposing arbitrary user-owned file contents by default.

### Portability and Maintainability

- **NFR-8:** Lifecycle behavior shall not depend on paths, layouts, host identity, or assumptions unique to the implementation machine unless represented as declared local configuration.
- **NFR-9:** Git commit identity may represent kit revision for this increment, while lifecycle and installed-state schemas remain explicitly versioned and migratable.
- **NFR-10:** Repeated read-only operations shall be side-effect free, and repeated convergence at current state shall be stable and non-destructive.

### Diagnosability

- **NFR-11:** Every blocking or warning outcome shall be attributable to a component, authority, stable reason, evidence source, affected scope, and safe next action.
- **NFR-12:** Offline installation integrity, update source eligibility, and live external availability shall remain independently observable.

## Reconciliation Notes

The route → stamp → validator → Orca loop is proven by EPIC-035 Phase B. Historical source-pack statements describing that loop as unproven are superseded and are not current product gaps.
