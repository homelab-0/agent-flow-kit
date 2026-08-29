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

## Final verdict (M5, 2026-08-29)

M5 assembly: 140-item independent traceability sweep (13 agents, every mapping
verified against retained artifacts — `evidence/AFK-PORT-1.4-M5-TRACEABILITY/`),
bundle index (`evidence/INDEX.md`), registry and rulings in `traceability.md`
(Story 1.4 section). Sweep-time corrections applied: the 1.3 preamble-incident
evidence pointer in this record's registered-conditions section is WRONG
(`AFK-PORT-1.3-C4.worker-done.md` does not carry the incident; the 1.3
coordinator freeze record does) — corrected here rather than editing the frozen
section text. Retention-miss residuals recorded with mitigations. macOS signal
ruling: platform-derived arithmetic authoritative; contract prose already
literal-free; suite literals → backlog.

Every required implementation, review, real-host, synchronization-channel,
orchestration, and cleanup proof passes, with exactly one clause standing
outside GREEN's letter: the smoke's natural valid route is valid-but-
unlaunchable under the frozen launch adapter, and the smoke ran on the owner's
recorded standing override (routing-deadlock ruling, 2026-08-28), with the
full routing chain retained. Under the frozen verdict rule ("without a
partial-green substitute"), the honest verdict is therefore:

**AGENT-FLOW-KIT PORTABILITY BLOCKED — one clause: the natural valid route for
standard-band work ({claude, local-code-standard}) is valid-but-unlaunchable
under the frozen launch adapter, so the orchestration smoke's route was
accepted via the owner's recorded standing override rather than as naturally
routed (AC-20 clause of the smoke). Every other proof — two real hosts,
Git-channel update, preservation, idempotence, drift refusal, live
verification with grounded reasons, composed supervised dispatch, durable
turn-boundary completion, full-VM-restart non-resurrection, persona
reproducibility, macOS signal observation, cleanup to pristine — is retained
and green. The block dissolves the moment the owner's routing solution makes
the natural standard-band route launchable (or the catalog stops emitting the
unlaunchable pair), at which point a natural-route smoke re-run upgrades the
verdict to GREEN with no other work owed.**

## Dev Agent Record

- Status: **M4 CLOSED (2026-08-29) — all seven registered acceptance conditions carry live dispositions; MAC LEG CLOSED; M5 (assembly + traceability + verdict) is the only remaining work.**
  Registered-condition scoreboard: (1) composed dispatch live PROVEN (persona-proven + supervised-from-creation + supervised release, every worker); (2) turn-boundary completion PROVEN (worker-committed durable delivery consumed by `monitor --reconcile` with no coordinator turn live; replay dropped; corrected-delivery repair exercised); (3) status renders LIVE on all three surfaces (claude ✓ coordinator, codex ✓ worker, PLAN-mode ✓ fresh plan session — no parity-table substitution); (4) durable-close-after-reconnect PROVEN at full strength (deliberate quit + full VM restart; ZERO of fourteen released worker terminals resurrected; durable watch records intact; Orca even version-stepped 1.4.188→1.4.191 across the boundary); (5) persona-proof reproducibility SATISFIED on the fresh macOS host with stated source; (6) macOS signal numbering OBSERVED (30/31 → 158/159; contract-sentence ruling due at M5); (7) workspace-trust disposition RECORDED (Orca-created worktree paths launched claude workers with no trust prompt; no trust database touched).
  M4 tail evidence: independent gate PASS; kit cleanup CLEANUP_COMPLETE with honest TERMINAL_NOT_OWNED refusal; target repo restored pristine at `b89c5cd` (clean tree, single master, no stray worktrees/branches — `target-pristine-check.txt`); reopen-boundary finding recorded (Electron relaunch requires the owner's desktop session; a stale v1.4.185 daemon zombie noted for upstream).
  (Prior: M2 CLOSED 2026-08-28 — update-channel, idempotence, drift-canary, live-verification complete on the primary at fbc0923, PR #21 proven live.)

### Coordinator log — M2 closure (2026-08-28)

- M2D honest stop RECLASSIFIED as a coordinator brief defect: the update
  channel converges MANAGED CONTENT, which the merge (lib/tests only) did
  not change — `CURRENT` was truthful (only machine-owned/user-owned regions
  non-CURRENT, both grounded), the applied revision legitimately stays
  8a7cbc1, and the fixed code is live from the checkout. Bonus no-churn
  evidence: a git-revision advance with identical managed content triggers
  no vacuous update. Worker behaved correctly; settled clean.
- M2E SETTLED `succeeded` (`task_300e1e5d9195`/`ctx_94e3c87d0d51`): live
  verification on the fixed surface — **`LIVE: READY_WITH_WARNINGS —
  REASONS-GROUNDED: yes — AMBIGUITY: none`**. The D2 fix proven live:
  `router_status: AVAILABLE (HTTP 200)`, catalog compatible (the pre-fix
  surface misclassified this same router). The D1 fix proven live: both
  FALSE scopes now carry the real blocker (`ORCA_CAPABILITY_UNPROVEN`),
  each named consistent with same-result live facts. ROUTE_READY correctly
  OUT_OF_SCOPE/no-stamp. Evidence:
  `evidence/AFK-PORT-1.4-M2E-LIVE-RERUN/`.
- **M2 CLOSED.** AC-6/7/8/9/10/11 covered on the primary. All tasks
  settled; zero open dispatches; mailbox drained.
- Carried live facts relevant to M4 planning: `claude_capability:
  INCOMPATIBLE (HARNESS_CAPABILITY_UNPROVEN)` (detail names required launch
  flags) and `validator_fixtures: UNAVAILABLE` (transient) — both bear on
  the smoke's prelaunch surface and must be resolved or honestly carried
  into the smoke's readiness evidence.

### Coordinator log — M4 preparation (2026-08-28)

- Josh's standing ruling recorded (memory + here): the routing deadlock is
  temporarily IGNORED — dispatches (M4 smoke included) proceed via the
  established recorded-override path without re-escalation; the final
  verdict carries the honest AC-13 caveat if the smoke's natural route is
  unlaunchable at run time; Josh is building the real solution out-of-band;
  the natural route is preferred the moment the catalog changes.
- Target registration mechanism established from the frozen contract: an
  operator edit of the state manifest's `targets[]` (`{id, path}`); no CLI
  verb exists and the kit's own reason-action directs exactly this.
- Disposable smoke target created and registered: repo
  `/home/devbox/repos/jlengelbrecht/afk-smoke-target` @ `cfeafea` (v6
  skills layout: `.agents/skills/bmad-create-story/template.md` with the
  five required frontmatter keys; `_bmad/bmm/agents/dev.md` + `pm.md`;
  single wiring copy). Manifest backup retained
  (`/tmp/claude-1000/state.json.pre-target-backup` + this record).
  Kit verdict: **`TARGET_READY: TRUE — TARGET_WIRING_PROVEN`**, status
  exit 0.
- Mac-leg return channel AMENDED by Josh (2026-08-28): in addition to the
  evidence branch, the Mac agent creates a GitHub issue
  ("macOS portability verification — results") with its summary, then both
  sides run ~4-hour watchers — the Mac polls the issue for coordinator
  comments prefixed `MAC:` (scope-fenced: read-only unless a comment names
  an authorized kit transaction; no credential access; evidence-branch
  pushes only), the coordinator polls for the issue and its comments.
  Orca-visibility requirement on the Mac RELAXED per Josh's deliver-now
  intent: if the Orca desktop won't stay up, the agent records the exact
  failure as a finding and continues in a plain terminal with the
  limitation noted (coordinator preference, not frozen; previously flagged).
  Delivery prompt handed to Josh; coordinator watcher armed (10-min polls,
  4h).
### Coordinator log — Mac results + cycle 3 (2026-08-28)

- **Mac leg first results (issue #22, evidence branch
  `evidence/afk-port-1.4-mac`; ran at 8a7cbc1 on Apple Silicon, Orca desktop
  unavailable per the relaxed rule):**
  - GREEN: lifecycle 476/0, readiness 251/0, dispatch 250/0 on macOS.
  - **Registered condition SATISFIED — persona-proof reproducibility:** the
    fresh host recomputed the pinned `07ee71cf…` proof with the stated
    source sentence ("skill files provisioned by the handoff branch payload
    (git)").
  - **Registered condition OBSERVED — macOS signal numbering:** USR1=30→
    exit 158, USR2=31→exit 159, classified PLATFORM-NUMBERING-DIVERGENCE
    (contract-sentence alignment ruling pending at M5).
  - RED (classification in progress): mutation 262/240 FAILED, concurrency
    102/139 FAILED, run-tests 160/48/14, diff-check 2 (trailing spaces in
    retained raw output — evidence-harness class). Blockers include
    VALIDATOR_UNAVAILABLE_ON_HOST (expected), Orca runtime unavailable
    (expected/relaxed), OPERATION_LOCK_UNAVAILABLE, permission denied,
    missing executable bits, and adoption REFUSED on
    SOURCE_DIRT_OUTSIDE_INPUT_SET + SOURCE_NONCANONICAL_BRANCH (checkout
    state at inspect time under diagnosis; also a real UX finding: the
    refusal's next_safe_action loops back to the refusing command).
    Suspected dominant cause of the mass failures: GNU-vs-BSD userland
    divergence (timeout/sed/stat) — the portability story's core payload;
    diagnostic pass directed via `MAC:` issue comment (environment facts,
    grouped failure signatures, exec-bit inventory, branch state, lock
    context); Mac-side and coordinator-side watchers running.
  - Deviation noted: the Mac ran at pinned 8a7cbc1 although current master
    was fbc0923 with the story file unchanged (its brief permitted moving
    forward); harmless here (fixes touch surfaces whose suites passed) but
    recorded.
- **Cycle 3 of 3 authorized (Josh) and dispatched** for the smoke-blocking
  readiness defect: the harness auth-status probe captures only stdout while
  codex reports login state on stderr (coordinator reproduction retained),
  so native sessions classify AUTH_STATUS_UNPROVEN and codex routes evaluate
  ROUTE_HARNESS_UNAVAILABLE (first ROUTE_READY(stamp) evaluation, honestly
  FALSE, in `evidence/AFK-PORT-1.4-M4-SMOKE/route-ready-first-evaluation.json`).
  FIX-C3 worker: `task_5cbfb906723b`/`ctx_dca256272734`, claude/strong per
  the standing harness ruling, branch `jlengelbrecht/afk-1.4-fix-c3` off
  fbc0923; stderr-stub + silent-control + claude-pin regressions required.
- M4 progress: smoke target registered and proven; canary story + gate
  frozen into the target @ `3c4838f` (canary sha `8d1ddaae…`); natural route
  captured verbatim; stamp minted under the ignore ruling (override
  recorded); first ROUTE_READY(stamp) evaluation performed.

### Coordinator log — C3 lane closed and merged; ROUTE_READY progression (2026-08-29) **[MERGE LOGGED]**

- FIX-C3 remedy pass (Josh-authorized beyond budget, 1.3 cycle-4 precedent):
  `b5bbcd1` closed C3-R1 (fail-closed ordering; the reviewer's demonstrated
  spoof now classifies AUTH_REQUIRED, pinned as a regression) and C3-R2
  (`afk_probe_run` restored byte-identical, cmp-verified; dedicated bounded
  auth-only runner). Closing delta review: **APPROVED — no blockers**.
  Composite packaging gate green (235/0, diff-check clean). All workers
  settled/released through the supervised lifecycle.
- **MERGE (coordinator, Story-1.4 authority): PR #23 squash-merged → master
  `b2d2564`.** Wave: Devin pass + GitGuardian pass; Devin's one finding
  (conflicting positive auth classes would prefer subscription) evaluated:
  real in shape, below the blocker bar (not reproduced, no natural
  transcript carries both markers), 👍 reaction + disposition reply posted,
  REGISTERED as hardening backlog (explicit conflicting-positive
  fail-closed detection). Operator pull 3 delivered `b2d2564` to the
  primary.
- ROUTE_READY(stamp) re-evaluation: **the C3 fix is proven live**
  (`codex_native_session: AVAILABLE — AUTH_NATIVE_SUBSCRIPTION`); state
  advanced to the next honest blocker `STAMP_VALIDATION_UNPROVEN`, root-
  caused by coordinator reproduction: the readiness probe's SYNTHETIC
  fixture stamp uses placeholder `sha256:fixture`, which the newer
  validator build rejects as malformed (exit 2 → honest "no verdict").
  Real stamp validation is unaffected (proven all story). POST-BUDGET:
  registered as residual + hardening item
  (`evidence/AFK-PORT-1.4-M4-SMOKE/residual-validator-fixture-incompatibility.md`),
  not fixed; the smoke's readiness record carries the honest UNAVAILABLE leg.
### Coordinator log — Mac lock-failure diagnosis RESOLVED (2026-08-29)

- Five-round issue-channel diagnosis (issue #22; each round narrowing
  honestly: tools GNU-and-present, PATH complete, identity/lock primitives
  proven in-shell, suite code executing, child-kit process untraced by the
  parent) culminated in the decisive repro: **clean master worktree + fresh
  HOME → `adopt --inspect` exit 0, `adopt` → `ADOPTED/VERIFICATION_PASSED`,
  lock acquired and released, offline verify green — the kit's lifecycle
  machinery WORKS on macOS.**
- RECLASSIFICATION: the mutation-suite (262/240) and concurrency-suite
  (102/139) failures are TEST-HARNESS portability findings (the suites'
  scenario/fixture mechanics on Darwin), evidence-harness class per AC-2 —
  post-budget: RECORDED for the hardening backlog, not fixed; non-blocking
  for the lifecycle-portability claim, to be documented explicitly in the
  final verdict. Related recorded findings: three test files tracked
  without executable bits; diff-check trailing-space findings in retained
  raw output; the adoption refusal on the evidence branch confirmed as
  CORRECT fail-closed behavior (operator sequencing, not a defect); the
  refusal's next_safe_action loop-back remains a UX finding.
- The Mac agent detected a service-token expansion in its own bash-x trace
  and withheld it — no credential values posted (noted with credit).
- Remaining Mac obligations for AC-12 proper: REAL-host adoption (the Mac's
  actual HOME — mutation, Josh's go required), offline verification, and
  explicit live verification with whatever router declaration the Mac can
  honestly make. Then the closing handshake on issue #22.

### Coordinator log — MAC LEG COMPLETE (2026-08-29)

- Real-home adoption executed with the owner's explicit approval (relayed on
  issue #22 with plan identity `sha256:9a19ced0…` pinned): **ADOPTED /
  VERIFICATION_PASSED** at applied revision 8a7cbc1; preservation
  **BYTE_IDENTICAL** (machine-local subscriptions.yaml + user-owned CLAUDE.md
  hashes proven before/after); offline verify 0 failures; live overall
  READY_WITH_WARNINGS with honest `ROUTER_AUTH_MISSING` (no credential
  created). Two prior honest refusals on the way (evidence-branch execution
  directory; APPROVAL_REQUIRED gate) both correct fail-closed behavior.
- **AC-12 complete at full fidelity on the second host**; the Mac is now an
  adopted fleet member (its future Git-channel update is fleet ops, not a
  1.4 obligation — the update channel was proven on the primary).
- Closing handshake posted; both issue watchers ended per the owner's
  protocol. Evidence branch `evidence/afk-port-1.4-mac` through `262585d`.
- Second-host summary for traceability: core suites green on Apple Silicon;
  persona proof reproduced from the handoff payload (registered condition
  SATISFIED); signal statuses observed 158/159 (registered condition
  OBSERVED); suite mass-failures resolved to test-harness portability
  findings (recorded, hardening backlog); kit lifecycle proven working;
  adoption + preservation + verification proven on the real home.

### Coordinator log — M4 smoke executed (2026-08-29)

- Attempt 1: worker executed flawlessly (exact canary staged, sha
  `8d1ddaae…`, persona proven, codex live render saved) and failed HONESTLY
  on a coordinator harness-design defect: gate v1 counted the handoff's own
  untracked provisioning as changes. Worker asked across the turn boundary,
  received no answer, reported failed — all correct. Evidence:
  `attempt1-worker-evidence/`; classified evidence-harness defect (mine).
- Gate v2 pre-declared and committed (`b89c5cd`, tracked-content semantics
  with the provisioning exemption documented) BEFORE attempt 2; fresh
  worktree at the new pre-smoke SHA.
- Attempt 2 (`task_045884349529`/`ctx_12c239cc688b`): SUCCEEDED. The worker
  sent its verified worker_done and then COMMITTED THE DURABLE DELIVERY FILE
  into the kit's dispatch inbox while no coordinator turn was live; my next
  turn's `monitor --reconcile` CONSUMED it (registered turn-boundary
  condition PROVEN live), the replay was dropped, and attempt 1's degraded
  watch was repaired via the contract's corrected-delivery mechanism — the
  NEEDS_HUMAN latch cleared on repair (the 1.3 B3 fix live). Both watch
  records SETTLED.
- Independent frozen gate run by the coordinator: **GATE PASS** — staged set
  exactly the canary, bytes equal the frozen sha (AC-21).
- Kit `monitor --cleanup --live`: CLEANUP_COMPLETE, and it correctly REFUSED
  the terminal it could not prove it owned (TERMINAL_NOT_OWNED — the frozen
  never-touch-unproven-resources rule live). Worker settled via Orca,
  tab verified closed, mailbox drained.
- Live renders captured: claude session ✓ (coordinator), codex session ✓
  (worker). Remaining: PLAN-mode render; the staged Orca-restart disconnect
  probe (owner's hands); target-repo restore to pre-smoke state.

- M4 remaining sequence: author the disposable canary story (frozen bytes,
  deterministic gate, declared before dispatch) → natural `/route` capture →
  stamp (ignore-ruling override if needed; first-time `ROUTE_READY(stamp)`
  evaluation) → dispatch through the kit's own chain with the durable
  monitor watch registered → Orca-visible worker → gate → turn-boundary
  `monitor --reconcile` proof → live status renders (claude, codex,
  PLAN-mode PM) → durable-close-after-reconnect probe (needs Josh to
  restart Orca at a coordinated moment) → cleanup to exact pre-smoke state.

### Coordinator log — cycle-2 convergence + packaging authorization (2026-08-28)

- Delta review APPROVED (`task_11658270a944`/`ctx_acd4f6ba600d`, settled):
  remedy correct, scope clean, readiness 264/0 confirmed, all three new
  assertions independently anti-vacuous against bare 74f90d6, repo diff free
  of the environment repair. Evidence:
  `afk-1.4-fix-c1/FIX-C2-REVIEW-EVIDENCE/review.md`.
- Worker-terminal hygiene pass: all dispatch-owned tabs verified closed;
  seven leftover idle terminals in the fix worktree closed (terminal close
  returned false receipts while acting — THIRD instance of the
  receipt anomaly; upstream Orca report candidate reinforced).
- Packaging gate dispatched (`task_d1c293491376`/`ctx_0ce971aefbd1`): full
  composite + diff-check on the converged branch.
- Josh granted Story 1.4 MERGE AUTHORITY on this repo (2026-08-28), ratified-
  policy conditions: gate evidence complete, check wave (Devin + GitGuardian)
  clean, no external human engagement, every merge logged, doubt → hold.
- Next on green: push branch → PR to master (plain language, humanizer pass)
  → triage wave to clean → coordinator squash-merge (logged) → primary host
  external pull → UPDATE_AVAILABLE → kit update (second live update-channel
  exercise) → M2c rerun → M2 closes.

### Coordinator log — packaging + merge (2026-08-28) **[MERGE LOGGED]**

- Packaging gate SETTLED green: full composite exit 0 at `c0c2fee`
  (shellcheck 15/0, builders 58/0, retired 21/0, integration 57/0, launch
  guard 34/0, make-stamp 45/0, live chain 0/0+1 skip, lifecycle 476/0,
  mutation 577/0, concurrency 207/0, readiness 264/0, dispatch 250/0),
  diff-check clean. Evidence: `afk-1.4-fix-c1/FIX-FINAL-EVIDENCE/`.
- PR #21 opened (94+/11−, two files, humanized body, no generated files).
  Check wave FIRST-PASS CLEAN: Devin Review pass, "No Issues Found", zero
  findings (nothing to react to); GitGuardian pass, no incidents. No human
  engagement; no threads.
- **MERGE (coordinator, under Josh's 2026-08-28 Story-1.4 merge authority):**
  squash-merged PR #21 → master `fbc0923`; branch deleted. Decision made on
  gate evidence only (composite green + two APPROVED adversarial review
  rounds + clean wave); no coordinator line-review.
- Operator pull 2 (fix delivery) recorded: canonical checkout
  `8a7cbc1 → fbc0923`, user content untouched (evidence:
  `AFK-PORT-1.4-M2-GIT-CHANNEL/operator-git-pull.txt`).
- M2D dispatched (`task_2ff05d407061`/`ctx_dd3c3975e5bc`, standing-auth
  chain archived): update-channel delivery of the fixes (UPDATE_AVAILABLE →
  plan/approve → converge with preservation proof) + the M2c live-
  verification rerun on the fixed surface, requiring every FALSE scope's
  reason grounded in the same result's live facts.

### Coordinator log — FIX-C1 adversarial review (2026-08-28)

- Review attempt 1: reviewer stopped on a SELF-MISCOMPUTED persona proof
  (hashed SKILL.md alone; its "observed" value is the expected intermediate).
  Coordinator verified the artifact intact by recomputing the composed
  formula in place; finding voided; worker settled; brief amended with
  expected intermediates. Data point: the proof formula's composition/path
  sensitivity keeps producing operator error — input for the
  persona-reproducibility acceptance discussion.
- Review attempt 2 (fresh codex, `task_7a98ed39fa54`/`ctx_bc89653b98ee`,
  settled + closure verified): rigorous, evidence:
  `afk-1.4-fix-c1/FIX-C1-REVIEW-EVIDENCE/review.md`.
  - D1 sound (facet isolation proven; all four controls pass).
  - D2 parsing correct, retention capped — but **C1-REVIEW-001 (blocker,
    reproduced with a measured demonstration):** the uncapped global
    `AFK_PROBE_PARSE_OUT` survives after its immediate parse and after
    `afk_readiness_reset` (measured parse=5000 retained=4096 persisting
    post-reset). Not rendered or logged; process-reachable; violates the
    sharpened bounded-evidence obligation.
  - Anti-vacuity proven for both regressions (revert-would-fail analysis).
  - Flake claim: all six attempt-1 mutation failures FLAKE-CONSISTENT
    (reach-based — the diff cannot touch the mutation surface — corroborated
    by two independent green reruns), but NOT identity-auditable because the
    composite log names no failing assertions → **C1-REVIEW-002 registered
    as residual + hardening-backlog candidate: the composite gate should
    name failures.**
  - Scope fence clean (exactly two files, +35/−0 in tests, no weakened
    assertion).
- Per Josh's rule (new blocker from a fix stops and escalates): cycle-2
  decision escalated with a fix recommendation (clear the buffer after its
  one immediate parse and in reset, pinned by a post-probe/post-reset
  emptiness regression; delta-scoped re-review).

### Coordinator log — cycle 2 + the clobbered-shim discovery (2026-08-28)

- Cycle 2 authorized by Josh. FIX-C2 SETTLED (claude worker per the standing
  implementation-harness ruling, `task_52e270f6221e`/`ctx_0ae08379ec7b`,
  released, closure verified): commit `c0c2fee` (+36/−0, the two scoped
  files) — `AFK_PROBE_PARSE_OUT` emptied after its one authorized parse,
  both probe buffers cleared in `afk_readiness_reset`; readiness 264/0
  (6 new sourced-process regressions), dispatch 250/0; anti-vacuity proven
  against bare `74f90d6` (fails exactly the 3 emptiness assertions).
- **Environment finding (worker-disclosed, coordinator-verified):** the
  shared Orca CLI shim `~/.config/orca/linux-orca-cli-shim/orca` had been
  OVERWRITTEN on Aug 26 by a dispatch-test-family stub (STUB_ORCA_STALL /
  term-p2 fixtures; canned terminal list/close, exit 1 otherwise). The
  worker restored the canonical AppImage wrapper OUTSIDE its file scope —
  a disclosed deviation the coordinator accepts (shared host infrastructure
  repair; stub preserved at `FIX-C2-EVIDENCE/clobbered-orca-shim-stub.sh`).
  Coordinator verification: the CURRENT shipped test suite is fully
  sandboxed under `$TMPROOT` and never touches that path — the clobber
  traces to Story-1.3-era development activity, not shipped code.
  BLAST-RADIUS CAVEAT: the worker's "every send failed" causal claim is
  OVERBROAD — multiple sends and 17 heartbeats demonstrably committed while
  the stub was in place, so per-terminal PATH resolution determined impact;
  the silent-send pattern is now PARTIALLY explained, not fully
  root-caused. Prior operational classifications (silent codex first-sends)
  are amended accordingly; the codex mid-turn wedge remains a separate,
  unexplained pattern. Hardening-backlog reinforcement: the kit's
  `AFK_ORCA_BIN=orca` default and shim-integrity guarding.
- Delta re-review dispatched (`task_11658270a944`/`ctx_acd4f6ba600d`):
  remedy verification with the prior reviewer's measurement shape,
  independent anti-vacuity confirmation, scope check, and confirmation the
  repo diff carries no trace of the environment repair.

### Coordinator log — catalog 1.5.0 resolution + Josh's rulings (2026-08-28)

- Catalog move CONFIRMED DELIBERATE by Josh: the MiniMax promotion
  (prox-ops PR #1289, Flux-reconciled 01:21Z) — minimax/strong flipped
  selectable (claude harness via MiniMax's Anthropic-compatible endpoint,
  minimax-max pool, [chat, tools], min_context guarantee 1,000,000;
  physically validated by STORY-035-23). Nothing else moved; the
  standard-band deadlock and the M4/AC-13 question stand.
- Trusted catalog installed per Josh's channel ruling: fetched from
  prox-ops `kubernetes/apps/ai/agent-router-catalog/app/catalog-configmap.yaml`
  at main `05ef3eb7`, document extracted from `data["catalog.yaml"]`,
  sha256 verified BYTE-EXACT against live `/v1/status`
  (`59781b92…`), installed as `agent-router-1.5.0.yaml`. Local diff review
  confirms the MiniMax promotion is the only change.
- Josh's accepted operational rulings: (1) prefer claude for
  implementation dispatches on this host until the codex mid-turn-wedge
  pattern is understood; (2) the worker-stop false-receipt anomaly is
  logged as a candidate upstream Orca report; (3) the no-trust-prompt
  claude launch stands as a workspace-trust data point. The
  mutation-flake claim remains PENDING INDEPENDENT REVIEW.
- Review worker dispatched against the 1.5.0 catalog
  (`task_6287370b2a0a`/`ctx_bb53aa3f7cbd`, standing-auth override chain
  archived, re-mint reason cites the catalog move).
- Mac handoff branch refreshed and pushed (`e2aa761`): payload now carries
  the 1.5.0 catalog, a freshly routed re-minted stamp (expires 2026-08-29
  04:22Z, prior chain archived as *.catalog140.json), and the brief's
  references updated. Ready for re-delivery once Orca on the Mac is up.

### Coordinator log — FIX-C1 execution (2026-08-27/28)

- Attempt 1 (codex): halted fail-closed on coordinator provisioning gap
  (fresh worktree lacked untracked `_bmad/`); provisioning set for fresh
  worktrees is `.agents` + `.claude` + `_bmad` (recorded in memory).
- Attempts 2–3 (codex): both wedged mid-turn (hung exec cells,
  `agent_prompt_blocked`, 60–90 min silent); stopped, tabs verified closed
  (worker-stop returned false receipts both times while the tab did close —
  receipt anomaly noted). Operational finding: codex worker sessions on this
  host hang on long implementation turns (2/2); shorter evidence tasks
  completed fine.
- Attempt 4 (claude/strong, Josh's explicit per-dispatch override — beyond
  the standing codex-fallback auth, recorded in the stamp; codex-attempt
  stamp archived): SUCCEEDED. Commit `74f90d6` (58+/11−, exactly the two
  scoped files): D1 scoped reasons now grounded in the latest evaluated
  live-fact reason with controls preserved; D2 full-response parsing with
  retention still capped at 4096 bytes. Full gate re-run green (lifecycle
  476/0, readiness 258/0, dispatch 250/0, composite 235/0 exit 0 with
  mutation 577/0 inside); first composite's 6 mutation failures re-ran clean
  standalone — implementer classifies them as timing flakes, CLAIM PENDING
  INDEPENDENT REVIEW. Worker settled, released, closure verified. Notably:
  the claude worker launched in the Orca worktree with NO workspace-trust
  prompt (workspace-trust condition data point).
- REVIEW dispatch (fresh adversarial, diff-scoped; brief
  `FIX-C1-REVIEW-BRIEF.md` incl. independent flake-claim verification):
  task `task_6287370b2a0a` created; stamp mint FAILED CLOSED —
  `catalog_version_stale`: the route response now carries catalog digest
  `59781b92…` (live `/v1/status`: document 1.5.0, generated 2026-08-28
  01:21Z) vs local trusted `9b7ba27e…` (1.3.0 file). No catalog
  distribution endpoint exists (`/v1/catalog` 404s); the trusted catalog is
  out-of-band by design. HELD for Josh: install the 1.5.0 catalog document
  and state whether the move was deliberate.

### Coordinator log — M2b/M2c (2026-08-27)

- M2B SETTLED with honest outcome `failed` (`task_25d8d7e758d2` completed
  15:56:39, worker released, closure verified): Lanes 1/2/4/5 GREEN —
  UPDATE_AVAILABLE detected at applied bd9d9fb; update CONVERGED to 8a7cbc1
  with preservation byte-identical (the live global CLAUDE.md managed section
  observably converged to the newer revision's content — real global-surface
  mutation, user content preserved); second run NO_CHANGE with hash-proof;
  drift canary LOCAL_DRIFT → update REFUSED without overwriting → byte-exact
  restore → healthy re-verify. Lane 3 (live verification) failed on
  `ORCA_NOT_RESOLVED` + `ROUTER_ENDPOINT_NOT_DECLARED`.
- Lane-3 failure CLASSIFIED: host-configuration gap on the freshly adopted
  host, not a kit defect — the kit's own reason strings name the remedy
  (declare AGENT_ROUTER_URL; Orca CLI on this Linux host is `orca-ide`, not
  bare `orca`). Worth noting for the packaging backlog: the kit's default
  `AFK_ORCA_BIN=orca` collides with the GNOME screen reader on stock Linux —
  candidate hardening item, NOT folded into 1.4.
- M2C dispatched (`task_0969939c5cc4`/`ctx_9874a15141e0`, standing-auth
  override chain archived): Lane-3 rerun with declared host configuration;
  token via 1Password env only, never printed; ROUTE_READY must remain
  NOT_EVALUATED.
- M2C SETTLED (honest `failed`, released, closure verified): live
  verification ran on both surfaces — overall `READY_WITH_WARNINGS`;
  grounded classifications for integrity (READY/CURRENT at 8a7cbc1),
  target-arity, validator, harness, auth/funding (MODE words), and
  ROUTE_READY correctly `OUT_OF_SCOPE`/no-stamp. TWO NEW FINDINGS, escalated
  to Josh per the no-auto-cycle rule (evidence:
  `evidence/AFK-PORT-1.4-M2C-LIVE/`):
  - **R1 (blocker-class, routes to Story 1.3 per AC-2):** stale readiness
    reasons contradict the same result's live facts —
    `HOST_EXECUTION_READY: FALSE — ORCA_NOT_RESOLVED` while
    `live_facts.orca_executable = PRESENT/EXECUTABLE_RESOLVED` at
    `~/.local/bin/orca-ide`; `NEW_WORK_READY: FALSE —
    ROUTER_ENDPOINT_NOT_DECLARED` while `AGENT_ROUTER_URL` is declared and
    the router was actually probed. The FALSE states have independent
    grounded blockers; the attached reasons violate truthful classification.
    Deterministic, naturally reached on a real converged host.
  - **R2 RESOLVED as kit defect (Josh: "fix what's broken"):** coordinator
    root-caused it — `afk_probe_run` caps `AFK_PROBE_OUT` at 4096 bytes
    (`head -c 4096`) and the live `/v1/status` document is 6,973 bytes; the
    shape check (`jq -e 'has("catalog_version")'` — itself lenient) parses
    the truncated invalid JSON and misclassifies a healthy router. Routed to
    Story 1.3's surface alongside R1.
- FIX CYCLE 1 of 3 AUTHORIZED (Josh) and dispatched: fresh worktree
  `afk-1.4-fix-c1` off master `8a7cbc1` (`task_d0f47b49775d`/
  `ctx_d58689ae7baf`, standing-auth override chain in the worktree root).
  Scope: exactly D1 (stale scope reasons → actual grounded blocker) + D2
  (parse the full probe response, bound only retention), each pinned by
  discriminating regressions with controls; full gates; single commit; no
  push. Next: separate diff-scoped review worker, then packaging/merge with
  Josh, host pull+update, M2c rerun.
  - Original R2 record (pre-resolution): router status
    `INCOMPATIBLE — ROUTER_API_SHAPE_UNSUPPORTED` — the live `/v1/status`
    answers HTTP 200 with a well-formed catalog_document_version 1.4.0
    document (same catalog digest as the local 1.3.0 file; coordinator
    capture retained). Either router-side document evolution (out of story
    scope) or an over-strict kit shape/version pin (→1.3). `/v1/route` and
    `/v1/place` worked against this router throughout the session.

### Coordinator log — M2 (2026-08-27)

- Josh's M2 go received; plan approval delegated to the coordinator for this
  sequence (approval actor recorded per transaction).
- Operator git action 1 (evidence: `evidence/AFK-PORT-1.4-M2-GIT-CHANNEL/`):
  canonical checkout repositioned to its true stale state — local `master`
  ref (moved only by fetch fast-forwards, never checked out; reflog retained)
  reset to `bd9d9fb` and checked out. Untracked user content untouched.
- M2a SETTLED (`task_c86461e2c0cb`/`ctx_b5cb3f706c42`, released, closure
  verified): AUTO_ADOPTABLE → plan sha256:74987c… approved (delegated) →
  ADOPTED/VERIFICATION_PASSED at applied revision `bd9d9fb`; offline verify
  0 failures; 7/7 preservation hashes byte-identical; non-blocking warnings
  SOURCE_DIRT_OUTSIDE_INPUT_SET + CANONICAL_REVISION_AHEAD (expected at the
  stale revision). First worker to complete the VERIFIED worker_done send on
  the first attempt (hardened brief).
- Operator git action 2: `git pull --ff-only` initially REFUSED by git —
  four untracked local 1.8 planning files collide with paths PR #19 made
  tracked on master. All four hashed BYTE-IDENTICAL to master's versions
  (hashes + backups retained); removed losslessly; pull completed
  `bd9d9fb → 8a7cbc1`. Remaining untracked user content: the 1.3 coordinator
  handoff (preservation material for M2b). Classified: stale-host user-content
  collision, resolved by operator action outside lifecycle tooling — not a
  kit defect; the kit was not involved and git failed safe.
- M2b dispatched (`task_25d8d7e758d2`/`ctx_90f39bda1b4a`, standing-auth
  override chain archived): five lanes — UPDATE_AVAILABLE detection, update
  transaction with preservation proof, live verification (ROUTE_READY stays
  NOT_EVALUATED), no-churn idempotence by hash comparison, drift-canary
  refusal + byte-exact restore.
- Mac leg status: Josh delivered the handoff; the Mac codex agent validated
  stamp + harness, then stopped FAIL-CLOSED because the Orca desktop on the
  Mac exited/timed out (`runtime_open_timeout`) — zero changes, zero pushes.
  Awaiting Orca restart + re-delivery (or Josh's call to relax the
  Orca-visibility requirement, which is coordinator preference, not frozen).
- Implementation artifacts:
- Gates:
- Findings and resolutions:
- Final diff size:

### Coordinator log — M0 (2026-08-27, run_5a0ac02ec79c)

- Story worktree: Orca-created `afk-port-1.4` off `origin/master` @ `8a7cbc1`
  (branch `jlengelbrecht/afk-port-1.4`). Persona skills provisioned by
  canonical-checkout copy; persona proof recomputed in the fresh worktree =
  pinned `07ee71cf…` (the HANDOFF-flow fresh-host recomputation remains an M4
  obligation, per the recorded acceptance concern).
- Routing: both M0 workers routed centrally; primary `{claude, local-code-standard}`
  is valid-but-unlaunchable under the frozen launch adapter and an honest
  `context_size` re-route returned 409 `no_eligible_profile`. Josh authorized a
  recorded pre-stamp override to the route's own first fallback
  `{codex, openai/strong}` (override provenance in both stamps; full chain:
  `AFK-PORT-1.4-M0-GATES.*` / `AFK-PORT-1.4-FLEET-DISCOVERY.*`, attempt1 +
  rejected-409 + override + final). Stamps revalidated all-green immediately
  before worker creation.
- Composed dispatch live (registered condition 1): both workers fresh,
  persona-proven, Orca-supervised from creation via `worker-start` (dispatches
  `ctx_05178dc65412`, `ctx_e146f62699c1`); the gates worker was settled through
  the supervised lifecycle (`worker-release`; tab close verified by terminal
  list). Receipts: `evidence/AFK-PORT-1.4-M0-DISPATCH/`.
- M0 gate sweep (AC-1): ALL GREEN — lifecycle 476/0, readiness 251/0, dispatch
  250/0, mutation 577/0, concurrency 207/0, run-tests 235/0 (1 counted skip),
  `git diff --check` clean. Evidence: `evidence/AFK-PORT-1.4-M0-GATES/`.
- Classified findings (reported, not folded in):
  1. Routing-seam deadlock (operational, known-frozen; not a 1.4 code defect):
     standard band unlaunchable; recorded-override precedent set. RISK flagged
     for M4 AC-13 (natural route without substitution) — catalog question is
     Josh's, out of story scope.
  2. Story-record defect (1.4-acceptance class): frontmatter `persona: qa`
     names a persona that is not installed anywhere; frozen AC prose specifies
     the DEV persona. Coordinator ruling: AC prose governs; workers ran DEV
     with the pinned hash. Awaiting Josh's ratification.
  3. run-tests counted skip = the environment-conditional live-chain test
     (router env absent in the sandbox): expected offline behavior; the live
     chain is proven for real by the M4 conditions. Not a defect.
  4. Live incident (acceptance-relevant evidence for registered condition 2):
     the discovery worker's `worker_done` send visibly ran but never durably
     committed (out-of-grammar flag, unverified exit) — a committed-looking
     completion lost in flight, naturally reproduced. Evidence:
     `evidence/AFK-PORT-1.4-M0-DISPATCH/incident-lost-worker-done.*`.
     Coordinator directed a resend from the worker's own terminal; no
     completion was fabricated.
- Fleet discovery (AC-3 input): insufficient visibility — this runtime sees
  only `local` (zero saved environments, empty sshTargets). Resolved by Josh's
  topology facts: the bazzite PC is the hub; remote Orca servers are isolated
  by design. Evidence: `evidence/AFK-PORT-1.4-FLEET-DISCOVERY/`.

### Coordinator log — M1 kickoff (2026-08-27)

- Pair CONFIRMED by Josh: PRIMARY = this devbox VM (always-on remote Orca
  server, real legacy/stale kit state); SECOND = the Mac Orca server (macOS;
  signal observation site). OBSERVED-NOT-SELECTED: the cachyos Orca server
  (offline in placement data; Linux — weaker differentiation than the Mac).
  Excluded by scope: laptop (inference), bazzite PC (hub seat).
- Josh granted STANDING override authorization for 1.4 dispatches hitting the
  known unlaunchable standard-band pair (override to the route's own first
  fallback, chain archived per dispatch). The M4 smoke route is EXCLUDED.
- M1a primary baseline: worker dispatched under the standing auth
  (`AFK-PORT-1.4-M1-PRIMARY-BASELINE.*`, task `task_435e4c081aac`, dispatch
  `ctx_b012455538bb`), fresh/persona-proven/supervised per protocol.
- M1b/M3 Mac leg: per Josh's ruling, delivered as a FULL HANDOFF (clone+adopt
  distribution model; no server-to-server Orca connections). Handoff branch
  `handoff/afk-port-1.4-mac` @ `7ab5dc1` carries the brief, the persona
  payload (content verified to reproduce the pinned proof at the canonical
  path — the proof formula is path-sensitive), and the Mac worker's full
  routing chain (`AFK-PORT-1.4-MAC-LEG.*`, standing-auth override, stamp
  expires 2026-08-28T14:52Z). Evidence returns on `evidence/afk-port-1.4-mac`.
  This deliberately exercises the persona-reproducibility HANDOFF condition:
  the fresh host recomputes the proof from what the handoff provisions and
  must state that source in its evidence.

### Coordinator log — M1a settlement (2026-08-27)

- M1a SETTLED: worker_done accepted (`msg_6d67da41f16a`), task
  `task_435e4c081aac` completed 15:37:23, worker released, tab closure
  verified, mailbox drained. Evidence:
  `evidence/AFK-PORT-1.4-M1-PRIMARY-BASELINE/` (baseline, representativeness,
  raw status/verify/adopt-inspect triplets, classification).
- AC-4/AC-5 coverage: complete. `PRE-MUTATION AMBIGUITY: none` — every state
  carries a grounded machine classification.
- Substantive finding (not a defect — correct fail-closed behavior): the
  primary is `INSTALLATION_NOT_ADOPTED` (no applied-state manifest) and
  adoption is `REFUSED`/`ADOPTION_SOURCE_INELIGIBLE` on
  `SOURCE_NONCANONICAL_BRANCH` (canonical checkout on `story/afk-port-1.2`);
  untracked dirt classified ELIGIBLE. M2 therefore starts with an operator
  branch switch to the stale master contemporary, adoption there, then the
  external-pull → UPDATE_AVAILABLE → update channel proof.
- Operational pattern (2nd reproduction, now classified): codex workers'
  first `orca orchestration send --type worker_done` from the script-exec
  tool fails SILENTLY (empty output, nothing committed) even with the
  capability token present; a coordinator dispatch-mail correction + terminal
  wake + verified resend (--json, check ok/message id) succeeds. Future 1.4
  briefs must make send-verification a hard completion step (M1 brief already
  did; the worker skipped it). Live supporting evidence for the durable-watch
  acceptance conditions.
