---
linear:
stamp: AFK-PORT-1.4.md.stamp.json
persona: qa
gates:
  - "bash tests/lifecycle-tests.sh"
  - "bash tests/run-tests.sh"
  - "git diff --check"
max_cycles: 3
---

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
**And** recognition occurs through the durable Orca completion watch without requiring a new human prompt to make the PM poll
**And** a disconnect between durable `worker_done` commit and acknowledgment is replayed and reconciled idempotently without duplicate review, settlement, evidence, or cleanup actions.
**And** the smoke proves PM → route → stamp → validation → optional late placement → Orca-visible worker → deterministic gate → result.

**Given** smoke evidence is captured outside the disposable target state
**When** cleanup runs
**Then** the worker completes/stops, disposable Orca worktree and branch are removed as appropriate, the target repository equals its exact pre-smoke state, and no evidence file, log, canary, branch, worktree, untracked artifact, or lifecycle/global drift remains there
**And** the completed worker terminal remains absent through an Orca reconnect/recovery check rather than being automatically resumed from session history
**And** cleanup evidence distinguishes the AFK-owned worktree, local branch, and authorized remote-branch disposition without sweeping unrelated branches
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

## Implementation Constraints

- Frozen PRD: _bmad-output/planning-artifacts/prds/prd-agent-flow-kit-2026-08-24/prd.md
- PR #5 is a donor/reference only; use reconcile-pr5.md as the migration map.
- Work from canonical master in this fresh story worktree.
- Do not broaden into router, catalog, prox-ops, Kubernetes, GPU, or control-plane product work.
- Do not weaken a frozen requirement to fit donor code or a bounded retry cycle.

## Acceptance Concern: Persona-Proof Reproducibility (recorded at the 1.2 freeze)

- The Story 1.2 evidence chain proves worker persona identity by hashing
  `.agents/skills/bmad-agent-dev/SKILL.md` + resolved `customize.toml` from the
  repo-local tooling directories — which are untracked (and now gitignored).
  A fresh clone can verify the committed code and rerun every gate, but cannot
  recompute that persona identity proof from the repository alone.
- Story 1.4's fresh-host canary must be able to recompute the persona identity
  proof from what the host actually receives (the installed skill files the
  HANDOFF flow provisions), and the acceptance evidence must state which
  source satisfied it. Recorded 2026-08-25 by the PM at the Story 1.2 freeze;
  deliberately not a 1.2 change.

## Acceptance Concern: Signal Exit-Status Numbering (recorded at the F6-R11 cycle)

- The trapped terminating signals exit `128 + signal number` with Linux numbering
  hardcoded in tests and contract prose (USR1→138, USR2→140). On macOS those
  signals are 30/31, so the statuses would be 158/159 while the README claims
  macOS is proven. Safety property unaffected — only the reported number.
- Story 1.4's macOS validation must either observe the platform's own numbers or
  rule the Linux literals authoritative, and align the contract sentence either
  way. Recorded 2026-08-26 by the PM; deliberately not a 1.2 change.

## Observed Acceptance Constraint: Claude Workspace Trust

- Story 1.4 must retain whether the exact disposable Orca worktree path was already trusted, required an explicit one-time human trust decision, or could launch autonomously through a documented supported mechanism.
- Trust established for the canonical AFK checkout must not be presented as proof that a distinct generated Orca worktree is trusted. If Claude continues to require separate approval for each new external worktree path, record that as a concrete autonomy limitation and human intervention in the acceptance evidence.
- The acceptance harness must never edit Claude's trust database, script acceptance of the protected prompt, or use prompt-skipping/permission-bypass behavior to manufacture a green result.


## Acceptance Conditions Registered by Story 1.3 (recorded at the 1.3 freeze review)

Story 1.3's proof obligations were deterministic and stubbed by design
("where implementation support precedes Story 1.4 proof"). The following live
proofs are Story 1.4 acceptance conditions, each with its 1.3 evidence pointer:

- **Live composed dispatch — supervised Orca Dispatch/Worker and persona proof
  on the same worker.** 1.3 proves the contract in stubbed regressions
  (`tests/lifecycle-dispatch-tests.sh`); live, the 1.3 orchestration ran
  persona-proven workers under tracking-only dispatches, and the one attempt to
  attach supervision to a batch worker terminal failed (Orca injected an agent
  preamble and auto-failed the Dispatch — incident recorded in
  `evidence/AFK-PORT-1.3-C4.worker-done.md` and the coordinator freeze record).
  1.4 must demonstrate one worker that is simultaneously persona-proven,
  Orca-supervised from creation, and released through the supervised lifecycle.
- **Live completion delivery across a coordinator turn boundary on real Orca,
  with no in-turn wait.** Stub-proven by the monitor regressions (durable
  watcher, at-least-once idempotent reconciliation). Live motivating evidence:
  the 2026-08-26 Orca runtime restart silently lost a committed-looking
  worker_done, detected only by reconnect reconciliation (coordinator freeze
  record, "Operational incidents"). 1.4 must show `monitor --reconcile`
  consuming a real delivery committed while no coordinator turn was live.
- **Live status render on both Claude and Codex, including a PLAN-mode PM.**
  Story 1.4 must run the status surface live in a real Claude session, a real
  Codex session, and a PLAN-mode PM session, and retain the rendered output of
  each as acceptance evidence. A JSON/human parity table does not satisfy this
  condition: 1.3's table-driven parity and orchestration-bridge coverage
  (`tests/lifecycle-readiness-tests.sh`) is the implementation proof only; no
  live render was performed on any of the three surfaces this increment. A
  registered backlog candidate (statusline hook consuming the status JSON;
  see `traceability.md`) proves out naturally alongside this condition: a
  live PLAN-mode render and a populated statusline are the same
  demonstration.
- **Durable close with no resurrection across a real Orca
  disconnect/reconnect.** Stub-proven (non-resurrection regression with its
  discriminating control; B1/P1 fixes). Live supporting evidence: worker tabs
  closed before the 2026-08-26 app restart did not resurrect after it
  (terminal-list verifications in the settlement records). 1.4 must run the
  probe against a real reconnect on the acceptance host.

## Dev Agent Record

- Status: planned
- Implementation artifacts:
- Gates:
- Findings and resolutions:
- Final diff size:
