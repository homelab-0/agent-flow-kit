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

- Status: cycle 4 — the final authorized cycle (`AFK-PORT-1.3-FIX2.md`,
  authorized beyond the story's 3-cycle budget after the diff-scoped post-fix
  review) implemented; **gates not executed in this session** (see "Gates,
  cycle 4"). The cycle 1–3 records are kept below unchanged, because the
  coordinator's rulings are answers to them and they only make sense read
  together. One bounded PR-triage round followed the freeze
  (`AFK-PORT-1.3-TRIAGE1.md`, Josh-authorized, two items); its record is
  directly below and the freeze record itself was not touched — the superseding
  freeze revision is the coordinator's to write.

### PR-triage round 1 (post-freeze, Josh-authorized)

Scope was exactly the two items in `AFK-PORT-1.3-TRIAGE1.md` plus this record:
T1, the per-dispatch heartbeat window (a verified defect from the external
review of the published PR chain), and T2, counted skips in the readiness gate
(residual N3, now authorized). Nothing else was touched — not F2's
aggregate-level gaps, not any other residual, not `lib/afk-plan.sh`,
`lib/afk-mutate.sh` or the 1.2 surface.

**T1 — the resolved heartbeat window is persisted and refreshed from the record
(`lib/afk-monitor.sh`).**

- Registration already read `.heartbeat_seconds` from the descriptor and used it
  for the FIRST `heartbeat_deadline_epoch`, then discarded it. Every later
  refresh — the `heartbeat` arm of `afk_monitor_reconcile_delivery` — recomputed
  the deadline from the process-wide `AFK_MONITOR_HEARTBEAT_SECONDS`, so a
  Dispatch registered with a longer window than the default was flagged
  `WORKER_HEARTBEAT_EXPIRED` while its worker was still reporting on time (a
  spurious loud `NEEDS_HUMAN` — the B3 harm class), and one registered with a
  shorter window silently lost the tight monitoring it asked for.
- The watch record now carries `heartbeat_seconds`, written at registration from
  the same resolved value the first deadline uses. The refresh reads it from the
  record and falls back to `AFK_MONITOR_HEARTBEAT_SECONDS` only when the record
  carries no number — which is exactly the compatibility path for records
  written before this change, and is what the jq expression says
  (`if (.heartbeat_seconds | type) == "number" then … else $default_hb end`).
- The zero case is preserved on both paths: a window of `0` means no heartbeat
  deadline, so the refresh writes `0` rather than `now + 0`, matching
  registration. `WORKER_HEARTBEAT_EXPIRED` semantics are untouched — a TRUE
  expiry still fires exactly as before, through the same sweep, with the same
  code — and no vocabulary was added.
- Regression (`tests/lifecycle-dispatch-tests.sh` section 4, scenarios
  `heartbeat-window` and `heartbeat-window-legacy`): a Dispatch registered with
  three times the default window asserts that the window is persisted on the
  record, that the first deadline is one window away, and that after a delivered
  heartbeat `heartbeat_deadline_epoch - last_heartbeat_epoch` is the DECLARED
  window and is not the default — plus that the record stays `WATCHING` with no
  fault, no `WORKER_HEARTBEAT_EXPIRED` finding, the heartbeat consumed and the
  pass exiting 0. The control strips `heartbeat_seconds` from a freshly
  registered record, which is what a pre-change record looks like, and asserts
  the refresh still uses the default. The fixture's own window is asserted to
  differ from the default, so the case cannot go vacuous if the default ever
  changes. A `deliver_heartbeat` helper was added beside `deliver` because a
  heartbeat carries no result.
- **Anti-vacuity.** On the pre-triage tree the two decisive assertions fail: the
  refreshed delta is the default (1800) where the test requires the declared
  window (5400), and `.heartbeat_seconds` is absent from the record, so the
  persistence assertion reports `null`. The legacy control passes on both trees
  by construction — that is its job: it shows the fallback is still the default
  and that the first two assertions are a difference in the product rather than
  in the fixture. The pre-existing `heartbeat` expiry scenario is untouched and
  still passes on both trees.

**T2 — counted skips in the readiness gate
(`tests/lifecycle-readiness-tests.sh`).**

- `skip()` printed and counted nothing, so the summary reported `N passed, M
  failed` with skipped checks invisible — the defect cycle 4 fixed in the
  dispatch gate, applied here in the same shape: a `SKIPPED` counter, the same
  comment stating why a silent skip is indistinguishable from a pass, and a
  summary that becomes `N passed, M failed, K skipped` with the sentence
  "skipped checks computed no verdict — they are not passes" printed ABOVE it,
  so the counts stay on the LAST line and `tests/run-tests.sh`'s `tail -1`
  aggregation carries the skip count instead of swallowing it.
- No check changed behaviour. The suite has exactly two skip sites — the
  `date(1)` dialect probe and the router-timeout scenario without `timeout(1)` —
  and both still skip under exactly the same conditions and print the same text.
  The header comment gained the same two-sentence statement the dispatch gate
  carries.
- `tests/run-tests.sh` was NOT touched: its aggregation of this suite already
  handles the skip line, and final-review F2's aggregate-level gaps stay
  registered rather than fixed.
- **Anti-vacuity.** This one is a reporting change, so the honest statement is
  what it does rather than an assertion that flips: on a host with `timeout(1)`
  and a usable `date(1)` both suites skip nothing, `SKIPPED` stays 0 and the
  summary line is byte-identical to before, which is why no existing assertion
  moves. On a host missing either, the pre-triage tree printed `231 passed, 0
  failed` while a scenario had computed no verdict, and the post-triage tree
  prints the count and the sentence. The dispatch gate's identical mechanism
  (cycle 4 item 3) is the executable precedent.

**Gates, PR-triage round 1:**

- **Not executed here.** This worker session was granted Read/Glob/Grep/Write
  only; there is no shell tool in it, so `bash tests/lifecycle-tests.sh`,
  `bash tests/run-tests.sh` and `git diff --check` could not be run. Nothing in
  this record is a claim that any of them passed. The coordinator re-runs them
  independently and that run is the arbiter.
- Highest-risk areas for that re-run, in order:
  1. The two new dispatch scenarios. They assert on arithmetic over the record
     (`heartbeat_deadline_epoch - last_heartbeat_epoch`), which is exact because
     registration and the refresh each take one `date -u +%s` reading and write
     both fields from it; a host whose `date` fails would report `0` for the
     epoch on both sides and the delta would be the window regardless, so the
     assertions do not depend on the clock.
  2. `DEFAULT_HB` in the dispatch gate reads `AFK_MONITOR_HEARTBEAT_SECONDS`
     from the sourced library rather than hard-coding 1800, so an operator who
     exports a different default gets the same answer in the suite and in the
     child process. The declared window is three times it, and the suite asserts
     the two differ.
  3. shellcheck over `lib/afk-monitor.sh` — the only product change is inside an
     existing jq program plus one record field; no new shell variable is
     introduced.
- **Housekeeping the coordinator must finish:** an empty file
  `lib/afk-monitor.sh.t1a` exists in the worktree. It was created by a
  mis-targeted write at the start of this session, is zero bytes, is untracked,
  and could not be deleted from here (no shell, and the tool set has no delete).
  It is not referenced by anything and does not reach a gate — the shellcheck
  set is an explicit file list — but it must be removed before anything is
  committed.

**PR-triage residual registry.**

| # | Class | Location | Summary | Disposition |
|---|---|---|---|---|
| N3 | method | `tests/lifecycle-readiness-tests.sh` `skip()` and its summary | `skip()` incremented nothing and the summary printed only passed/failed, so retained evidence could not distinguish a scenario that ran from one that skipped. | **Fixed by triage 1** (item T2). The dispatch half was already done in cycle 4 item 3; N3 is now closed for both gates. |
| E1 | behavior | `lib/afk-monitor.sh` registration vs the `heartbeat` delivery arm | The per-dispatch heartbeat window was consumed at registration and discarded, so every refresh used the process default: a longer declared window expired early as a spurious `WORKER_HEARTBEAT_EXPIRED`, a shorter one stopped being enforced. | **Fixed external finding** (item T1). Source: Devin review of PR #16. |

**Diff size, PR-triage round 1:**

- 4 files modified, 0 added: `lib/afk-monitor.sh`,
  `tests/lifecycle-dispatch-tests.sh`, `tests/lifecycle-readiness-tests.sh`,
  and this story file.
- Roughly 75 added+changed reviewable lines outside this record: about 10 in the
  monitor library (the persisted field, the refresh expression and their
  comments), about 51 of new dispatch-gate coverage (the two scenarios and the
  heartbeat delivery helper), and about 12 in the readiness gate (the counter,
  the summary block and two comments).
- This is well inside the single-PR budget on its own; the story total is
  unchanged in character — roughly 5,235 added+changed reviewable lines — and
  the recommended stacked split is unchanged.

### Cycle 4 (fix)

Scope was exactly the three items in `AFK-PORT-1.3-FIX2.md` plus this record.
Nothing else from `evidence/AFK-PORT-1.3-POSTFIX-REVIEW.md` was implemented;
the rest is registered below and was deliberately not touched.

Both blockers were expressed by the reviewer as runnable scripts under
`evidence/AFK-PORT-1.3-POSTFIX-REVIEW-attack/` and reproduced by the
coordinator. This session has Read/Glob/Grep/Write and **no shell**, so neither
those scripts nor the gates could be executed here. Each item below therefore
states what the script asserts, why the change inverts that assertion while its
controls keep holding, and what the new regression would report on the
pre-cycle-4 tree; the coordinator's independent run is the arbiter.

**1. P1 — the `ABSENT` arm consumes the durable close's own outcome
(`lib/afk-monitor.sh`).**

- `afk_monitor_cleanup_terminal` no longer discards the release call's status.
  `afk_monitor_terminal_release "$handle" || true` became
  `if ! afk_monitor_terminal_release "$handle"; then printf 'NEEDS_OWNER
  TERMINAL_RELEASE_UNPROVEN'; return 0; fi`, and all three of `ABSENT`, `IDLE`
  and `EXITED` consume it — the reviewer's simpler-and-safer form, adopted as
  the brief directs. A close that failed and a terminal that is nonetheless
  gone is still an unproven closure.
- The re-observation is unchanged for every state that reaches it: the handle
  must be absent from a freshly reloaded listing before `REMOVED
  TERMINAL_RELEASED` is reported. For `IDLE` and `EXITED` that re-observation
  still carries information; for `ABSENT` it never did, which is the defect,
  and the close's own outcome is now what decides that arm.
- The four human-in-the-loop states and the `*)` fallback are untouched, so
  nothing that was retained before is released now, and nothing that was
  released before is retained except the case P1 names.
- `docs/LIFECYCLE-CONTRACT.md` — the Terminal row now says the request itself
  must have been **accepted** as well as re-observed, and names all three
  unproven shapes (a refused close, a close that could not be bounded, an
  absence that could not be re-observed). The `ABSENT` paragraph replaces the
  assumption "a harmless no-op that records the intent" with what the code
  actually checks: for an absent handle the re-observation repeats what was
  already true, whether Orca will close a handle it is not listing is a
  property of that daemon and is never assumed here, and skipping the request
  altogether remains the original harm.
- Gate (`tests/lifecycle-dispatch-tests.sh`): the Orca stub can now express a
  failed close, because the previous stub baked in exactly the assumption the
  code took on faith. `STUB_CLOSE_FAILS` selects `0` every close succeeds (the
  old behaviour, and the default, so every existing scenario is unchanged), `1`
  a close for a handle Orca is not listing is refused, `2` every close is
  refused. Two new section-7 scenarios: `ghost-refused` (the A1 shape with the
  close refused) asserts no durable intent was recorded, `cleanup.terminal ==
  NEEDS_OWNER`, one `TERMINAL_RELEASE_UNPROVEN` finding, the record stays
  `COMPLETED`, `retained.terminals == 1` and the pass exits 2; `idle-refused`
  is the control at a status where the re-observation does carry information,
  and fails closed there too. The success-path controls (`ghost`,
  `ghost-control`) are unchanged and still assert `REMOVED`.
- **Anti-vacuity.** On the pre-cycle-4 tree `ghost-refused` reports `REMOVED` /
  `SETTLED` / exit 0 / `retained.terminals == 0`, so four of its six assertions
  fail; the ledger assertion ("a refused close records no durable intent")
  passes on both trees, which is precisely what makes the disposition
  assertions the difference. `idle-refused` passes on both trees by
  construction — it is labelled a control, and its job is to show the refusal
  is not what the stub does everywhere.

**2. P2 — the monitor's two Orca observations take the strict bounding policy
(`lib/afk-monitor.sh`, `bin/agent-flow-kit`).**

- New `afk_monitor_probe_strict` is `afk_probe_run` minus its warn-and-run
  fallback: no bounding tool → `AFK_PROBE_STATUS=BOUND_UNAVAILABLE`, the
  `PROBE_BOUND_UNAVAILABLE` finding once per run, and the call is **not made**.
  `afk_monitor_terminals_load` (the listing) and `afk_monitor_terminal_release`
  (the durable close) now go through it. `afk_probe_run` itself is untouched:
  its warn-and-run reading belongs to the readiness probes, is documented where
  they are, and the brief puts it out of scope.
- The once-per-run reporting that `afk_monitor_git_remote` already carried is
  now one helper, `afk_monitor_bound_unavailable`, shared by both wrappers and
  still sharing `AFK_PROBE_UNBOUNDED_REPORTED` with the probe runner, so a run
  reports the missing bound exactly once however many observations refuse.
- Consequence, stated plainly: on a host with no `timeout(1)`, a
  `monitor --cleanup --live` pass loads no listing, every handle reads
  `UNKNOWN`, every terminal is `NEEDS_OWNER TERMINAL_RELEASE_UNPROVEN`, and the
  pass returns immediately instead of hanging inside the call. That is the
  disposition the contract already defines for an observation that proves
  nothing.
- `docs/LIFECYCLE-CONTRACT.md:650-655` stays as cycle 3 wrote it and becomes
  true; two sentences were added after it stating the refusal explicitly and
  why the monitor is stricter than the live probes. The guarantee list at the
  end of the document ("Every observation a monitor pass makes outside this
  host is bounded and non-interactive") gained "or is refused and reported
  rather than made unbounded", which is what makes that line true rather than
  aspirational.
- **D3 / the `timeout` requirement, and the tension it created — read this
  one.** The brief asked for `timeout` in `afk_require_tools`
  (`lib/afk-common.sh:67`) as a hard requirement, with an explicit fallback:
  scope it to the monitor/live paths if the hard form turns a frozen gate
  assertion red, and record the tension. The hard form collides with this same
  brief, not with a Story 1.1/1.2 assertion:
  - `afk_require_tools` runs for **every** command, including the offline ones
    that never bound anything, so requiring `timeout` there refuses `status`,
    `adopt`, `update`, `verify` and `schema` on a host where they are perfectly
    computable. That is a behavioural regression on a path this cycle has no
    business touching.
  - Making it fatal only for `--live` would remove the readiness probes'
    documented warn-and-run reading, which item 2 explicitly puts out of scope.
  - Making it fatal only for `monitor --cleanup --live` would make item 3's
    required P2 regression unreachable: the brief asks that regression to
    assert the pass **returns** and reports `PROBE_BOUND_UNAVAILABLE` plus
    `TERMINAL_RELEASE_UNPROVEN`/`NEEDS_OWNER`, which cannot happen if the
    command refuses at the usage boundary.
  So the requirement is **declared and announced, not fatal**, and it is
  scoped to the live paths as the fallback directs: `afk_declare_bounding_tool`
  in `bin/agent-flow-kit` runs immediately after `afk_require_tools`, and on a
  `--live` run without `timeout` it warns on stderr naming the tool and what
  the run will do instead. An operator now learns it from the command rather
  than from a warning buried in a result document, which is what D3 asked for,
  and every path keeps the answer the contract already defines for a host that
  cannot bound an observation. `afk_require_tools` itself is unchanged; a
  coordinator who wants the hard form must decide which of the three
  consequences above is acceptable, and that is a decision above this cycle.
  *(Second, smaller reason for the placement, stated so it is not mistaken for
  the first: this session has no shell and no editing tool, so every change is
  a whole-file rewrite. Retyping the 1,273-line `lib/afk-common.sh` for a
  five-line addition, with no way to run a gate afterwards, is a risk to a
  library every gate depends on. `bin/agent-flow-kit` is where the live scope
  is known and is the smaller surface.)*
- Gate: new `tests/lifecycle-dispatch-tests.sh` section 8, "The pass's Orca
  observations are bounded, or they are not made". It builds a PATH sandbox
  that mirrors this host's own PATH minus exactly one entry — `timeout(1)` — a
  one-entry directory that puts it back, and an Orca stub derived from the
  suite's own stub with one added property: it can accept the request and then
  say nothing for two minutes. Every run in the section is wrapped in an outer
  `timeout 45`, so a pass that does not return fails an assertion instead of
  hanging the gate. Four cases:
  - `orca-unbounded` (the attack shape): no bounding tool, stalled Orca. The
    pass returns in under 30 s, does not exit 124, reports exactly one
    `PROBE_BOUND_UNAVAILABLE` and one `TERMINAL_RELEASE_UNPROVEN`, the terminal
    is `NEEDS_OWNER`, the record stays `COMPLETED`, the pass exits 2, and the
    terminal is still listed afterwards because the close was never requested.
  - `orca-stalled-bounded` (control A): same stalled Orca with `timeout` on
    PATH. Returns under 30 s, reports **no** `PROBE_BOUND_UNAVAILABLE`, and
    fails closed on the timed-out listing — so the difference between this and
    the attack is the bound, not the sandbox and not the stub.
  - `orca-answering-unbounded` (control B): no bounding tool, an Orca that
    answers instantly. Still `NEEDS_OWNER`, still one
    `PROBE_BOUND_UNAVAILABLE`, terminal untouched — so the refusal is about the
    bound rather than about the stall.
  - `orca-answering-bounded` (control C): bound available and an Orca that
    answers. `REMOVED`, `SETTLED`, durable intent recorded — the normal
    dispositions, through the same sandbox.
- **Anti-vacuity.** On the pre-cycle-4 tree `orca-unbounded` does not return at
  all: `afk_probe_run` runs `orca terminal list` unbounded against a stub that
  sleeps for two minutes, the outer `timeout 45` kills it, and the elapsed
  assertion, the `!= 124` assertion and every disposition assertion fail
  together. `orca-answering-unbounded` also discriminates: on the old tree that
  Orca answers, the terminal is `REMOVED` and the pass exits 0, so the
  `NEEDS_OWNER` and `PROBE_BOUND_UNAVAILABLE` assertions fail. Controls A and C
  pass on both trees, which is what makes them controls.

**3. D2 — the stalled-remote regression no longer passes vacuously, and the
skip is loud (`tests/lifecycle-dispatch-tests.sh`).**

- The dispatch gate gains the `skip()` mechanism the run-tests aggregate
  already has (N3's shape, applied here): a skipped check is counted, printed
  in yellow, and the summary line becomes `N passed, M failed, K skipped` with
  the sentence "skipped checks computed no verdict — they are not passes"
  printed above it. The counts stay on the LAST line, because
  `tests/run-tests.sh:1109` aggregates this suite by its last line, so a skip
  in here surfaces in the aggregate rather than being swallowed by it.
- `stalled-remote` is split at the fact that decides it. The dispositions that
  are true of both readings — `NEEDS_OWNER`, one `CLEANUP_NEEDS_OWNER`, the
  record not settled, the retained remote counted, exit 2 — stay unconditional.
  The two assertions that are only meaningful with a bounding tool (the elapsed
  bound, and "the observation was bounded rather than refused", asserted as
  zero `PROBE_BOUND_UNAVAILABLE` findings) run only where `timeout(1)` exists.
  Without it the scenario asserts the refusal path explicitly as its own case —
  exactly one `PROBE_BOUND_UNAVAILABLE` — and then skips loudly, naming why:
  the wrapper refused before the call, so nothing here touched a stalled
  transport.
- `answering-remote` is its control and is skipped with it: without a bounding
  tool no remote observation is made at all, so `RETAINED` /
  `REMOTE_BRANCH_RETAINED_UNAUTHORIZED` is not something that host can produce.
  Asserting it there would be asserting a capability rather than a behaviour.
  Its one host-independent assertion — the remote branch is untouched — still
  runs unconditionally. This is a deliberate change from "fails loudly without
  naming the cause" to "skips loudly naming the cause"; the review's own remedy
  for D2 asked for the second.
- The same loud-skip handling covers the new section 8: if this host has no
  `timeout(1)` at all, or the PATH sandbox cannot be built (the sandbox still
  resolves `timeout`, or is missing a tool the kit needs), all four cases skip
  as one counted, named skip rather than reporting anything.
- Section 5's `d-merged` / `d-unauth` assertions are deliberately **not**
  gated. Cycle 3 disclosed that they depend on `timeout(1)`, they fail loudly
  rather than vacuously on a host without it, and the brief did not ask for
  them; changing them would be scope this cycle does not have.

**Gates, cycle 4:**

- **Not executed here.** This worker session was granted Read/Glob/Grep/Write
  only; there is no shell tool in it, so `bash tests/lifecycle-tests.sh`,
  `bash tests/run-tests.sh` and `git diff --check` could not be run, and
  neither could `P1-absent-close-unproven.sh`,
  `P2-orca-observation-unbounded.sh` or the four original attack scripts.
  Nothing in this record is a claim that any of them passed. The coordinator
  re-runs them independently and that run is the arbiter.
- Highest-risk areas for that re-run, in order:
  1. The new section 8 PATH sandbox. It symlinks every executable on this
     host's PATH except `timeout` into one directory; if that mirror misses
     something the kit needs, the section reports a fixture failure rather than
     a product failure. The self-check ("the sandbox still resolves timeout",
     and a required-tool sweep) turns that into a counted skip rather than a
     misleading red, but the mirror itself is the least portable thing this
     cycle added.
  2. `ghost-refused` — it depends on the stub's `is_listed` agreeing with the
     stub's own listing filter, including the "a recorded durable close hides
     the handle from every later listing" rule the suite already models.
  3. shellcheck over `lib/afk-monitor.sh` (two new small functions) and
     `bin/agent-flow-kit` (one new small function). Neither introduces a new
     variable that a single-file analysis could call unassigned beyond the
     SC2034/SC2154 exclusions the lifecycle set already carries.
  4. Everything cycle 3 flagged is unchanged and still applies, in particular
     the two now-falsifiable published-reason sweeps in
     `tests/lifecycle-tests.sh` section 12.
- One behaviour worth watching that is not a gate: on a `--live` run without
  `timeout(1)`, `bin/agent-flow-kit` now writes one line to **stderr**. Every
  suite here captures or discards stderr, and this host has `timeout`, so no
  assertion should see it — but a future suite that asserts an empty stderr on
  a live run would.

**Post-fix review residual registry (delta-scoped).** These are the entries
from `evidence/AFK-PORT-1.3-POSTFIX-REVIEW.md` section 3. Except where marked
absorbed, they are REGISTERED, not fixed: nothing below was implemented in this
cycle.

| # | Class | Location | Summary | Disposition |
|---|---|---|---|---|
| D1 | behavior | `lib/afk-monitor.sh:394-399` vs `:954-978` | `afk_monitor_git_remote` computes `AFK_MON_GIT_STATUS` (`TIMEOUT` / `NONZERO` / `BOUND_UNAVAILABLE` / `OK`) and no caller reads it, so a stalled transport, a rejected push and an unbounded host are all reported as `NEEDS_OWNER` with nothing to tell them apart. Diagnostic loss, not a wrong answer. | Registered, not fixed. |
| D2 | method | `tests/lifecycle-dispatch-tests.sh` `stalled-remote` | The bounding regression held for the wrong reason on a host without `timeout(1)`. | **Absorbed by item 3** — split into a bounded case and an explicit refusal case, with a counted loud skip. |
| D3 | docs | `lib/afk-common.sh:67` | `afk_require_tools` omits `timeout`, which the cycle-3 delta made load-bearing. | **Absorbed by item 2, with a deviation** — declared and announced on the live paths from `bin/agent-flow-kit` rather than made a hard requirement in `afk_require_tools`. The reasoning, and what a coordinator would have to accept to take the hard form, are under item 2. N10 (`date`, `mktemp`) stays open. |
| D4 | method | `tests/lifecycle-dispatch-tests.sh` Orca stub | The stub could not express a failed close, so the fixture asserted an assumption rather than a behaviour. | **Absorbed by item 1** — `STUB_CLOSE_FAILS` models all three daemon behaviours, default unchanged. |
| D5 | behavior | `lib/afk-monitor.sh` cleanup terminal arm | One transient listing failure mid-pass leaves `AFK_MON_TERMINALS_LOADED=false`, so every subsequent Dispatch in the same pass reads `UNKNOWN` and takes the fail-closed arm. Fail-closed and recoverable on the next pass. | Registered, not fixed. Unchanged by this cycle: the reload is still `|| true`, and the strict wrapper only changes whether the call is attempted. |
| D6 | behavior | `lib/afk-readiness.sh:1639-1643` | A `ROUTE_HARNESS_UNAVAILABLE` route now also emits a `WORKSPACE_TRUST_REQUIRED` `owner_action` finding scoped to `ROUTE_READY`. The exit class and `overall.state` are unaffected, and no test covers the combination. | Registered, not fixed. |
| D7 | behavior | `docs/LIFECYCLE-CONTRACT.md` "the required action stays loud" | A later read-only pass over a record left with `NEEDS_OWNER` dispositions reports `WATCHING` / `required_action: null` / exit 0 while `dispatch_monitor.retained.*` still counts the resources. Identical before and after cycle 3. | Registered, not fixed. |
| D8 | method | `lib/afk-monitor.sh` `AFK_MON_REPLAYS`, `AFK_MON_CONSUMED` | Incremented and never read; `afk_monitor_reset` resets them beside the two flags that do matter. Pre-existing dead counters, related to N8. | Registered, not fixed. |

The reviewer re-checked N2, N3, N4, N6, N7, N9, N11, N12 and N13 as unchanged
by the cycle-3 delta and did not re-raise them; this cycle did not touch them
either, except that N3's shape — a `skip()` that counts and a summary that says
so — is now implemented in the dispatch gate as part of item 3. *(N3's readiness
half was fixed in PR-triage round 1 above; N3 is closed.)*

**Final diff size, cycle 4:**

- 5 files modified, 0 added: `lib/afk-monitor.sh`, `bin/agent-flow-kit`,
  `docs/LIFECYCLE-CONTRACT.md`, `tests/lifecycle-dispatch-tests.sh`, and this
  story file.
- Roughly 210 added+changed reviewable lines: about 45 in the monitor library
  (the strict wrapper, the shared bound-unavailable helper, the terminal arm
  and its comments), about 20 in `bin/agent-flow-kit`, about 25 across the
  contract document, and about 120 of new gate coverage (the stub's close
  behaviour, `ghost-refused`, `idle-refused`, the four bounding cases in the
  new section 8, the `stalled-remote` split and the skip mechanism).
- **The story total is therefore roughly 5,160 added+changed reviewable lines,
  about six and a half times the ~800-line single-PR budget.** The cycle 1–3
  flags stand unchanged; nothing was restructured to shrink the diff, per the
  standing constraint. The suggested split is unchanged.

### Cycle 3 (fix)

Scope was exactly the five items in `AFK-PORT-1.3-FIX.md` plus this record.
Nothing else in the full review was implemented; everything else is registered
under "Full-review residual registry" below and was deliberately not touched.

The four blockers were reproduced by the coordinator running the reviewer's
attack scripts in `evidence/AFK-PORT-1.3-FULL-REVIEW-attack/`. This session has
Read/Glob/Grep/Write and no shell, so those scripts could not be executed here
either. Each item below therefore states what the script asserts and why the fix
inverts that assertion while its control keeps holding; the coordinator's
independent run is the arbiter.

**1. B1 — `ABSENT` is not proof of release (`lib/afk-monitor.sh`).**

- `afk_monitor_cleanup_terminal` no longer returns `REMOVED TERMINAL_RELEASED`
  from the `ABSENT` arm. `ABSENT`, `IDLE` and `EXITED` now share one arm and all
  three fall through to the same request/re-observe pair: request the durable
  close, reload the listing, and report `REMOVED` only if the handle is absent
  afterwards, `NEEDS_OWNER TERMINAL_RELEASE_UNPROVEN` if it is not. The four
  human-in-the-loop states (`ACTIVE`, `AWAITING_ANSWER`, `AMBIGUOUS`,
  `USER_TAKEOVER`) and the unknown `*)` fallback are unchanged, so nothing that
  was retained before is released now.
- Requesting a durable close for a handle Orca has forgotten is a harmless no-op
  that records the intent; skipping it is what left a `SETTLED` Dispatch owning
  nothing while its tab came back on the next reconnect.
  *(Superseded by cycle 4 item 1: the request's own outcome is now consumed,
  because "harmless no-op" was an assumption about Orca the code never checked.)*
- N14 resolved in one place rather than two. `ABSENT` means exactly "Orca is not
  listing this handle at this instant", and each reader now states what that
  proves for its own question: the watch sweep keeps reading it as
  `WORKER_TERMINAL_EXITED_WITHOUT_DELIVERY` (a monitoring fault, never a
  result), and cleanup reads it as unproven until the durable close is requested
  and the absence re-observed. Both readings are written down at their code
  sites and in `docs/LIFECYCLE-CONTRACT.md` where the cleanup table lives.
- `docs/LIFECYCLE-CONTRACT.md` — the Terminal row of the provenance-bound
  cleanup table now says what the code does ("a **durable** close was requested
  for it and its absence re-observed afterwards. `IDLE`, `EXITED` and `ABSENT`
  all reach that request"), and a new paragraph under the table states the two
  readings of `ABSENT` side by side.
- Regression (`tests/lifecycle-dispatch-tests.sh` section 7, scenario `ghost`):
  a settled dispatch whose handle was never added to the stub listing. It
  asserts the stub's durable-close ledger contains `term-ghost`, that the
  disposition is `REMOVED`, and that the Dispatch settled. Control
  (`ghost-control`): a listed `IDLE` terminal still gets its durable close and
  still reports `REMOVED`, so the assertion is a difference in the product
  rather than in the stub.
- **Anti-vacuity.** On the pre-fix tree `ABSENT` returned before
  `afk_monitor_terminal_release` was ever called, so `STUB_CLOSED` would not
  contain `term-ghost` and the ledger assertion fails. The other three
  assertions in that scenario pass on both trees by design — they are what makes
  the ledger assertion the ONLY difference. No existing cleanup scenario in the
  suite reached `ABSENT` at all (every terminal is added to the listing first),
  which is exactly why the gate could not see this before.

**2. B2 — an unresolvable target binding fails closed (`lib/afk-readiness.sh`).**

- `afk_evaluate_route_readiness`: `target_id` that cannot be determined is now
  `ROUTE_TARGET_UNRESOLVED` instead of skipping the target leg. Zero registered
  targets and two-or-more-without-`--target` take the same path; neither is
  guessed at, and naming the target with `--target` resolves either. The
  singleton case and an explicitly named target behave exactly as before.
- The usage boundary in `bin/agent-flow-kit` is untouched, per the fix brief:
  the refusal is at readiness level, so `--stamp` without `--target` on a
  multi-target host reports a blocked route rather than a usage error.
- The workspace-trust evaluation is no longer reachable only through a resolved
  `tpath`. It now runs for every Claude route; an empty path emits
  `NO_SELECTED_WORKSPACE` (previously dead published vocabulary — N5 absorbed)
  instead of leaving the fact at its `LIVE_PROBE_NOT_REQUESTED` seed. Only an
  otherwise-unblocked route can be blocked BY the trust prompt: the call cannot
  overwrite a reason the route already has, so no refusal changes its code or
  its exit class because of this.
- `docs/LIFECYCLE-CONTRACT.md` — the `--target` paragraph now states the
  fail-closed rule and why an operand of the intersection cannot be dropped; the
  workspace-trust section states the `NO_SELECTED_WORKSPACE` reading.
- Regression (`tests/lifecycle-readiness-tests.sh` section 5, scenario
  `targetarity`): six runs over one fixture host in which only the registered
  `targets` array (and, in the last pair, the trust record) changes —
  (1) one wired target → `TRUE`, exit 0; (2) one unwired target → `FALSE` /
  `ROUTE_TARGET_UNRESOLVED`, exit 3; (3) wired + unwired, no `--target` →
  `FALSE` / `ROUTE_TARGET_UNRESOLVED`, exit 3, `TARGET_READY` still `PARTIAL`;
  (4) `--target target-a` → `TRUE`, `--target target-b` →
  `ROUTE_TARGET_UNRESOLVED`; (5) zero targets → `FALSE` /
  `ROUTE_TARGET_UNRESOLVED` with `NO_TARGET_REGISTERED` on the target scope;
  (6) trust withheld at arity one → `WORKSPACE_TRUST_REQUIRED`, exit 2, and the
  same trust withheld with a second target registered is still `FALSE`, still
  not exit 0, with `claude_workspace_trust` reporting `NO_SELECTED_WORKSPACE`.
- **Anti-vacuity.** On the pre-fix tree rows 3, 5 and the second half of row 6
  all report `TRUE` with exit 0 (the target leg was skipped entirely), and the
  `NO_SELECTED_WORKSPACE` assertion reports `LIVE_PROBE_NOT_REQUESTED`. Rows 1,
  2 and 4 pass on both trees: they are the controls that show the same
  unresolvable target really does block the route when it is the only one, so
  its disappearance in row 3 is a product difference and not a fixture artifact.

**3. B3 — the `NEEDS_HUMAN` latch follows the reading it belongs to
(`lib/afk-monitor.sh`).**

- The flag is split in two, because it was answering two different questions.
  `AFK_MON_PASS_NEEDS_HUMAN` records what THIS pass did and could not resolve —
  a descriptor it refused, a delivery naming no Dispatch, a record it could not
  write, a resource it would not release — none of which leaves a mark in the
  watch set that a later reading could recover. `AFK_MON_NEEDS_HUMAN` is the
  DERIVED verdict and belongs to the reading `afk_monitor_summarize` just took:
  the first statement of that function now sets it from the pass flag, so the
  post-action summary can disagree with the pre-action one.
- Every action-site assignment became a call to `afk_monitor_needs_human`, which
  sets both. `afk_monitor_exit_code` and `lib/afk-commands.sh` are unchanged and
  did not need to be: the derived variable still carries the whole verdict at
  the moment either of them reads it.
- Why not a bare reset. Resetting `AFK_MON_NEEDS_HUMAN` at the top of
  `afk_monitor_summarize` and nothing else would have made
  `monitor --register <bad descriptor>` exit 0 — the descriptor was refused, no
  record was written, and the post-action reading of the watch set is therefore
  clean. `tests/lifecycle-dispatch-tests.sh` pins that case at exit 2 and it is
  right to: the pass ended with something only a human can decide. The split
  keeps that and still lets a repaired fault stop being reported.
- Regression: the existing recovery scenario (section 4, `unparseable`) gains
  the two assertions the review named — the repairing pass's `RUN_RC` is 0 and
  `.dispatch_monitor.state` is `WATCHING` — plus `counts.degraded == 0` and no
  dispatch carrying a fault, which is the internal contradiction the emitted
  document used to carry. Section 0 also asserts the split directly on the
  primitives (a derived verdict does not survive the next reading; a
  pass-recorded one does), with the watch/inbox directories pinned to an empty
  fixture directory so the unit block never reads the developer's own state.
- **Anti-vacuity.** Both new scenario assertions fail on the pre-fix tree: it
  reports `NEEDS_HUMAN` / `MONITOR_DEGRADED` and exits 2 on a pass whose own
  counts say nothing is degraded. `counts.degraded == 0` and the fault sweep
  pass on both trees — they are what makes the contradiction legible rather than
  a disagreement about what is on disk.

**4. B4 — the three remote git calls are bounded and non-interactive
(`lib/afk-monitor.sh`).**

- New `afk_monitor_git_remote` wraps all three (`ls-remote` before the delete,
  `push --delete`, `ls-remote` after it) in the same `timeout` bound
  `afk_probe_run` uses (`afk_probe_timeout_seconds`, from
  `AFK_LIVE_TIMEOUT_MS`), with `GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS=/bin/true`,
  `SSH_ASKPASS=/bin/true` and `-o BatchMode=yes` appended to whatever
  `GIT_SSH_COMMAND` the caller had. It sets `TIMEOUT`, `NONZERO`, `OK` or
  `BOUND_UNAVAILABLE` and truncates stdout to 4 KiB like the probe runner does.
- A host with no bounding tool reports `PROBE_BOUND_UNAVAILABLE` (once per run,
  sharing the probe runner's already-reported flag) and does NOT run the call:
  the remote branch is `NEEDS_OWNER`, which is already the fail-closed
  disposition for a remote deletion this host cannot prove. That is stricter
  than `afk_probe_run`, which runs unbounded and warns — deliberately, because
  the calls here can delete a branch.
  *(Cycle 4 item 2 extended the same policy to the two Orca observations, which
  is the half B4 did not name.)*
- A timed-out or failed observation is `NEEDS_OWNER CLEANUP_NEEDS_OWNER`, never
  a deletion and never a "deleted". The retained-remote reporting follows from
  that automatically: `dispatch_monitor.retained.remote_branches` counts any
  non-terminal disposition on a record carrying a remote.
- The order of the checks is unchanged — the existence observation still comes
  before the authorization check — so an unauthorized record still probes the
  remote, which is what makes the stalled-transport case reach the bound rather
  than short-circuiting on authority.
- No new vocabulary: `PROBE_BOUND_UNAVAILABLE`, `NEEDS_OWNER` and
  `CLEANUP_NEEDS_OWNER` are all already published.
- Regression (`tests/lifecycle-dispatch-tests.sh` section 5,
  `stalled-remote`): a record whose remote is `ssh://nowhere.invalid/x.git`
  behind a `GIT_SSH_COMMAND` that sleeps for two minutes. It asserts the pass
  returns in under 30 seconds, the remote disposition is `NEEDS_OWNER`, the
  Dispatch is not settled, the retained remote branch is counted, and the pass
  exits 2. Control (`answering-remote`): the same descriptor shape against a
  real local bare remote completes the disposition as `RETAINED` /
  `REMOTE_BRANCH_RETAINED_UNAUTHORIZED` with zero `CLEANUP_NEEDS_OWNER`
  findings, so the stalled case is not passing because the lifecycle simply
  stopped looking at remotes.
  *(Cycle 4 item 3 split both by whether this host can bound the call at all.)*
- **Anti-vacuity.** On the pre-fix tree the stalled case does not return at all
  — the reviewer's A4 script measures exactly this and its external `timeout 20`
  kills the pass — so the elapsed assertion fails (the fixture's own sleep bounds
  the damage at two minutes rather than ten). The disposition assertions fail
  with it, because there is no disposition until the call returns.
- **A new hard dependency, stated plainly:** remote-branch dispositions now
  require `timeout(1)`. A host without it reports `PROBE_BOUND_UNAVAILABLE` and
  retains every remote branch instead of deleting one it could not bound. Two
  existing section-5 assertions (`d-merged`'s `REMOTE_BRANCH_DELETED`, and
  `d-unauth`'s `RETAINED`) therefore also depend on `timeout(1)` on the gate
  host. The contract already required this: "a host that cannot bound a probe
  reports `PROBE_BOUND_UNAVAILABLE` rather than running an unbounded probe as if
  it were a bounded one."

**5. N1 — the two vacuous published-reason sweeps become falsifiable
(`tests/lifecycle-tests.sh`).**

- Both sweeps at section 12 are now one named function that binds the tested
  value to a jq variable first (`. as $r | select(($pub | index($r)) == null)`),
  and each is followed by the same executable control the readiness gate
  carries: the identical expression over a copy of the document with exactly one
  out-of-set value injected (`.readiness.ROUTE_READY.reason =
  "NOT_A_PUBLISHED_CODE"`) must report exactly `1`.
- **This may turn the gate red, and the outcome is unknown from here.** The
  sweeps were passing because they selected nothing, so nobody has ever seen
  what they say about a status document or an adoption document. Reasoning from
  the source rather than from a run: every `.reason` string reachable in those
  two documents comes from `afk_reason_codes`, `afk_mutation_reason_codes`,
  `afk_readiness_reason_codes` or `afk_monitor_reason_codes`, and `schema`
  publishes exactly the union of those four; the adoption reasons in particular
  (`EXACT_CANONICAL`, `RECOGNIZED_PRIOR_CANONICAL`, `EXACT_RECOGNIZED_WIRING`,
  `UNRECOGNIZED_CONTENT`, `MACHINE_OWNED_REGION`,
  `ADOPTION_NOT_APPLICABLE_ALREADY_ADOPTED`, `ADOPTION_SOURCE_INELIGIBLE`) are
  all in the base list. The equivalent corrected sweep already runs green over a
  live status document in the readiness gate and over a monitor document in the
  dispatch gate, which is the strongest evidence available without executing it.
  If it does come back red, what it caught is a real publication gap: see
  "Deferred, deliberately, and disclosed" below for how it must be handled.

**Gates, cycle 3:**

- **Not executed here.** This worker session was granted Read/Glob/Grep/Write
  only; there is no shell tool in it, so `bash tests/lifecycle-tests.sh`,
  `bash tests/run-tests.sh` and `git diff --check` could not be run, and neither
  could the four attack scripts. Nothing in this record is a claim that any of
  them passed. The standing arrangement holds: the coordinator re-runs them
  independently and that run is the arbiter.
- Highest-risk areas for that re-run, in order:
  1. `tests/lifecycle-tests.sh` section 12, the two newly falsifiable
     published-reason sweeps (item 5). They are the only change in this cycle
     whose outcome is genuinely unknown.
  2. `tests/lifecycle-dispatch-tests.sh` `stalled-remote` — it depends on
     `timeout(1)` bounding `git ls-remote` and on `git` honouring
     `GIT_SSH_COMMAND` for an `ssh://` remote. If the pass hangs, the fixture
     caps it at two minutes and the elapsed assertion fails loudly rather than
     stalling the suite.
  3. The readiness gate's `targetarity` scenario — six live-stubbed runs, and
     the only place `--target` is exercised as anything other than a usage
     refusal.
  4. shellcheck over `lib/afk-monitor.sh` (the new `afk_monitor_git_remote`) and
     `lib/afk-readiness.sh`.

**Full-review residual registry.** These are the non-blocking entries from
`evidence/AFK-PORT-1.3-FULL-REVIEW.md` section 3. They are REGISTERED, not
fixed: nothing below was implemented in this cycle.

| # | Class | Location | Summary | Disposition |
|---|---|---|---|---|
| N1 | method | `tests/lifecycle-tests.sh:1721-1723`, `:1727-1729` | Two published-reason sweeps that can never fail (`$pub \| index(.)` — the array finds itself). | **Fixed this cycle** (item 5). |
| N2 | method | `tests/lifecycle-tests.sh:1696-1700` | `monitor_states`, `dispatch_states` and `cleanup_dispositions` are declared machine-checkable and published by `schema`, but are absent from the drift gate's `for key in ...` list. (`plan_actions`, `plan_dispositions`, `journal_states`, `operation_results`, `verification_results` are missing too and predate this story.) | Registered. |
| N3 | method | `tests/lifecycle-readiness-tests.sh:47`, `:1157`; `tests/run-tests.sh:1086-1088` | `skip()` increments nothing and the summary prints only passed/failed, so retained evidence cannot distinguish a scenario that ran from one that skipped. | **Closed.** Dispatch gate in cycle 4 item 3; readiness gate in PR-triage round 1 item T2. |
| N4 | behavior | `lib/afk-readiness.sh:1452-1454, :1487-1488, :1521-1523` | The router caller token is passed on argv (`-H "Authorization: Bearer ..."`), so it is in `/proc/<pid>/cmdline` for the duration of each probe. Needs a coordinator reading of the contract's "never emitted or persisted". | Registered. |
| N5 | behavior | `lib/afk-readiness.sh:1016-1021` | `NO_SELECTED_WORKSPACE` was unreachable published vocabulary. | **Absorbed by B2** — the trust evaluation no longer runs only through a resolved `tpath`, and the code is emitted. |
| N6 | method | `tests/` | `verify --live`, `verify --stamp` and `--synthetic-route` under `--live` have no coverage anywhere; `afk_cmd_verify`'s invocation-derived `offline` / `live_probes_performed` flags are untested. | Registered. |
| N7 | method | `tests/lifecycle-dispatch-tests.sh:424-443`, `:359-373`, `:516-521`, `:375-387` | Two of the six required completion-monitor regressions are approximated: `RESULT_NOT_RETAINED` has no scenario (only `RESULT_UNPARSEABLE`), and "a replayed `worker_done` cannot repeat a cleanup that already happened" is proven by a repeat-cleanup test plus a replay test rather than by a replay after cleanup settled. The restart case uses an already-acknowledged Dispatch. | Registered. |
| N8 | behavior | `lib/afk-monitor.sh:130-137` | `afk_monitor_reset` is defined and never called by product code. | Registered, still open. This cycle did not use it: the derived/pass split (item 3) resets one variable at the top of `afk_monitor_summarize` rather than the whole engine, because clearing the terminal listing cache and the replay/consumed counters there would be wrong. The function is now exercised by the dispatch gate's unit block, so it is no longer entirely unreferenced, but nothing in the product calls it. |
| N9 | behavior | `lib/afk-monitor.sh`, `lib/afk-commands.sh:85-90` | The monitor's writes take no lock; two concurrent `--reconcile` passes are made safe by two content-idempotent jq expressions rather than by mutual exclusion. | Registered. |
| N10 | docs | `lib/afk-common.sh:67` | `afk_require_tools` does not require `date` or `mktemp`, both now hard dependencies. | Registered. *(The related `timeout` gap is D3, absorbed with a deviation in cycle 4 item 2; `date` and `mktemp` stay open.)* |
| N11 | behavior | `lib/afk-common.sh:1179-1185` | `dispatch_monitor.dispatches[]` is rendered into human output but no projection sweep proves the parity the contract promises. | Registered. |
| N12 | behavior | `lib/afk-readiness.sh:1506-1512` | `ROUTER_CATALOG_INCOMPATIBLE` is emitted as a warning with empty `blocked_scopes` and never reaches route readiness; untested. Defensible under the contract's catalog-provenance assignment, but worth an explicit ruling. | Registered. |
| N13 | method | `evidence/AFK-PORT-1.3-C2-gates/` | `git diff --check` produced no retained artifact. | Registered (coordinator-side evidence, not a code change). |
| N14 | behavior | `lib/afk-monitor.sh:662-671` vs `:714` | The same `ABSENT` observation was read two opposite ways. | **Absorbed by B1** — both readings are now stated explicitly, in the code and in the contract, and cleanup no longer treats absence as proof. |

**Coordinator's C2-C ruling, recorded verbatim as instructed:**

> Accepted: validator fixtures remain behind --live; 'validator-fixture facts'
> in default mode means materialisability and validator resolution; AC-wording
> nuance registered as residual.

**Deferred, deliberately, and disclosed:**

- Everything in the registry above marked "Registered". None of it was
  implemented, per the fix brief's hard stop.
- The outcome of item 5's now-falsifiable sweeps. If either reports a nonzero
  count, the unpublished codes it names must be read before anything is changed:
  a gap inside this story's added vocabulary is this story's to fix, and a gap
  in pre-existing vocabulary is not — in that case the sweep stays red and the
  exact codes go to the coordinator rather than the sweep being re-vacuated.
  This session cannot run it, so no code list can be given here.
- `lib/afk-plan.sh`, `lib/afk-mutate.sh` and the Story 1.2 lock/signal/
  transaction surface were not touched at all, as instructed.

**Final diff size, cycle 3:**

- 6 files modified, 0 added: `lib/afk-monitor.sh`, `lib/afk-readiness.sh`,
  `docs/LIFECYCLE-CONTRACT.md`, `tests/lifecycle-dispatch-tests.sh`,
  `tests/lifecycle-readiness-tests.sh`, `tests/lifecycle-tests.sh`.
- Roughly 250 added+changed reviewable lines: about 70 in the monitor library
  (the bounded git runner, the terminal arm, the flag split), about 20 in the
  readiness library, about 45 across the contract document, and about 115 of new
  gate coverage (`ghost` / `ghost-control`, `stalled-remote` /
  `answering-remote`, the recovery assertions, the six-row target-arity matrix,
  and the two sweep controls).
- **The story total is therefore roughly 4,950 added+changed reviewable lines,
  about six times the ~800-line single-PR budget.** The cycle-1 and cycle-2
  flags stand unchanged; nothing was restructured to shrink it. The suggested
  split is unchanged too, and the review's observation that all four blockers
  lived in the two layers that split would separate (offline readiness; the
  dispatch monitor) is mild evidence for it.

### Cycle 2

- **C2-A — the published-set sweeps (fixed).** All three failures were one
  defect, and it was in the TEST, not in the emitted document. jq evaluates the
  ARGUMENT of `index()` against the INPUT of `index()`, so
  `$s | index(.value.state)` asks the published ARRAY for a `.value` field:
  `Cannot index array with string "value"`. The document shape was already
  right — `readiness_states`, `live_fact_states` and `target_states` in
  `agent-flow-kit schema` match `docs/LIFECYCLE-CONTRACT.md` and match what the
  engine emits — so the fix binds the value to a jq variable first
  (`.value.state as $st | select(($s | index($st)) == null)`).
  - The same defect made a FOURTH sweep in that block vacuous rather than
    broken: `every reason code in a live result is published` evaluated
    `$pub | index(.)`, which is the published array searching for ITSELF,
    always finds it at index 0, and therefore never selected anything. It was
    passing while guarding nothing. Fixed the same way.
  - **Anti-vacuity, executable rather than argued.** Each of the four sweeps is
    now a named function and is followed by a falsifiability control that runs
    the same expression over a copy of the live document with one out-of-set
    value injected and requires it to report exactly that value
    (`the reason sweep still FAILS on an unpublished code`, and one each for
    readiness, live-fact and target states). A sweep that stops discriminating
    now fails its own control, so this class of defect cannot come back
    silently. `tests/lifecycle-dispatch-tests.sh` section 8 carries the same
    control for the monitor half.

- **The fourth failure the cycle-1 evidence counted but did not show.** The
  independent run reported `215 passed, 4 failed`, and the 40-line tail
  `tests/run-tests.sh` prints showed only three. The fourth was
  `tests/lifecycle-readiness-tests.sh` section 5, `and an uncheckable live
  dependency exits 5`, and it was a real product defect:
  `afk_validator_verdict` mapped EVERY non-zero validator exit to "rejected",
  so the `broken` stub (exit 2, "I could not answer") produced a deterministic
  not-ready and exit 3 where the frozen contract requires a transient
  live-unavailable and exit 5.
  - Fixed in `lib/afk-readiness.sh`: only an exit status of exactly 1 is the
    validator's policy answer. Anything else — could not start, timed out, fell
    over on the document — is `VALIDATOR_VERDICT_UNAVAILABLE`, a new published
    code that sets `AFK_RD_LIVE_UNAVAILABLE`, marks the live fact transient,
    and makes the run exit 5. A negative fixture that went unanswered is no
    longer counted as a rejection either, because the anti-vacuity control
    would then be counting a silence as a proof. The same one-versus-anything
    -else mapping is applied to the per-stamp validator call.
  - Section 4 of the readiness gate now pins both halves explicitly: `reject-all`
    is `VALIDATOR_FIXTURE_FAILED` with `transient=false`, `broken` is
    `VALIDATOR_VERDICT_UNAVAILABLE` with `transient=true` and exit 5.

- **C2-B — completion monitor and cleanup (implemented per the ruling).**
  - `lib/afk-monitor.sh` (new) — the durable watch. State lives on disk under
    the declared state directory (`dispatch/watch/`, `dispatch/inbox/`,
    `dispatch/results/`), never in a turn, so a completion that arrives while
    nobody is looking is consumed by the next pass. Completion authority is
    only a supervised `worker_done` or `escalation` delivery: a heartbeat that
    expires and a terminal that exited without one are MONITORING faults with
    their own codes and produce neither a successful nor a failed result.
    Delivery handling is retention → reconciliation → acknowledgement, keyed by
    `delivery_id`, so a replay after an Orca disconnect is recognized and
    dropped without scheduling settlement twice, writing a second traceability
    record, or repeating cleanup. Cleanup is provenance-bound: a terminal,
    worktree or branch is a candidate only because a watch record proves AFK
    created it for that exact Dispatch, every disposition is reported
    independently as `REMOVED`/`RETAINED`/`NOT_APPLICABLE`/`NEEDS_OWNER`, and
    ambiguity fails closed. There is no recursive delete anywhere in it: a
    worktree goes through Git's own worktree bookkeeping or it is retained.
  - `bin/agent-flow-kit` — the `monitor` command: read-only without an action
    verb, `--register <path>` to establish the watch before control is yielded,
    `--reconcile` to consume the inbox, `--cleanup` (requires `--live`) to
    release what a settled worker owned. One bounded pass per invocation:
    there is no `--wait`, no rolling poll and no long-lived turn, which is the
    defect this replaces. On `monitor`, `--live` authorizes the monitor's own
    bounded Orca observation only; it does not switch on the readiness probes.
  - `lib/afk-commands.sh` — `afk_cmd_monitor`; the read-only summary is
    computed on every command inside `afk_evaluate_installation`; `schema`
    publishes the monitor half of the reason vocabulary plus `monitor_states`,
    `dispatch_states`, `cleanup_dispositions` and the dispatch schema major.
  - `lib/afk-common.sh` — `dispatch_monitor` added to the normalized result
    document, its well-formedness check and the human projection; the reason
    dispatcher consults a monitor hook alongside the readiness one; `monitor`,
    `--register`, `--reconcile` and `--cleanup` added to the closed diagnostic
    vocabulary.
  - `tests/lifecycle-dispatch-tests.sh` (new gate, aggregated as run-tests
    section 10) — every named regression from both "Required … regressions"
    lists, against real local Git repositories and a stubbed Orca: completion
    after the turn yielded; replay after a disconnect; a coordinator restart
    with one completed and one active Dispatch; duplicate delivery not
    duplicating settlement, traceability or cleanup; a terminal gone without a
    delivery; a result that cannot be parsed staying unacknowledged and
    recovering on the next pass; a settled worker's tab absent after a
    reconnect; active / awaiting-answer / ambiguous / user-taken-over / unowned
    coordinator terminals never closed; a merged branch losing worktree and
    branch with authorized remote deletion evidenced separately; unmerged,
    unique-commit, protected and unowned branches retained with stable reasons;
    and repeated cleanup recreating nothing.
  - Boundaries held as frozen: normalized orchestration state is still only
    CONSUMED, there is no dashboard, no terminal scraper, no router session
    registry, no control-plane feature, and nothing implements
    worker-originated delegation.
  - Two modelling decisions worth the coordinator's eye, because they are
    interpretations rather than transcriptions:
    - "must not duplicate review dispatch" is proven through the effects a
      replay must not repeat — `settlement.scheduled_count` and
      `traceability.records` stay at 1, and exactly one traceability record
      exists on disk. Nothing in this story launches a reviewer, so a duplicate
      LAUNCH is not observable here; the idempotence that would prevent one is.
    - The delivery transport is modelled as a durable inbox directory that the
      supervised transport commits into. That is the smallest thing that makes
      "at-least-once, survives a disconnect, consumed by a later invocation"
      real and testable without this story growing a client for an Orca API it
      does not otherwise touch. If Orca's actual delivery mechanism differs,
      the reconciliation semantics are unchanged and only the reader moves.

- **C2-C — Frozen-requirement collision (fixtures stay behind `--live`).**
  Implementing the ruling literally turns a frozen assertion red, so per the
  ruling's own instruction it was NOT implemented and NOT silently reverted.
  The exact colliding assertion:
  - `tests/lifecycle-tests.sh:1431` enumerates `agent-stamp-validate` in the
    stub set whose every member records that it was invoked, and
    `tests/lifecycle-tests.sh:1448`
    `assert_no_file "no external binary was invoked" "$SC/live-probe-marker"`
    asserts that a DEFAULT `status --json` invoked none of them.
    `tests/lifecycle-tests.sh:1454` asserts `validator fixtures NOT_EVALUATED`
    on the same run.
  - Running the kit-trusted validator against local fixtures in default mode
    executes exactly that stubbed binary, so it would create the marker and
    fail 1448, and would move `validator_fixtures` off `NOT_EVALUATED` and fail
    1454. The same guarantee is stated in `docs/LIFECYCLE-CONTRACT.md`
    ("Without `--live` no lifecycle command executes another program") and in
    the frozen AC that default mode leaves live-dependent facts
    `NOT_EVALUATED`.
  - Disposition left to the coordinator. The change itself is small and local:
    move the `afk_probe_validator` call in `afk_readiness_evaluate` out of the
    `--live` branch, and adjust the section-9 assertions in
    `tests/lifecycle-tests.sh` plus the readiness gate's default-mode
    expectations. What it costs is the frozen no-external-binary guarantee for
    default `status`, which is not a cost this worker is authorized to pay.
    *(Resolved by the coordinator; the ruling is recorded verbatim in the
    cycle-3 record above.)*

- Gates, cycle 2:
  - **Not executed here.** This worker session was granted Read/Glob/Grep/Write
    only; there is no shell tool in it, so `bash tests/lifecycle-tests.sh`,
    `bash tests/run-tests.sh` and `git diff --check` could not be run. Nothing
    in this record is a claim that they passed — the coordinator's independent
    re-run is the arbiter, and this record exists so a red gate is diagnosed
    against stated intent rather than against a guess.
  - Highest-risk areas for that re-run, in order:
    1. shellcheck findings in `lib/afk-monitor.sh` (new, ~700 lines, linted at
       warning level with SC2034/SC2154 excluded like the rest of the
       lifecycle set).
    2. `tests/lifecycle-dispatch-tests.sh` — it drives real `git worktree`,
       `git branch -d`, `git push --delete` against local bare remotes. A Git
       version whose `worktree add -q` or `ls-remote` output differs would show
       up here first.
    3. The schema/contract-document vocabulary comparison in
       `tests/lifecycle-tests.sh` section 12: `reason_codes` now carries
       `VALIDATOR_VERDICT_UNAVAILABLE` plus 39 monitor codes, and `commands`
       carries `monitor`. That assertion fails loudly if a single code is in
       one list and not the other.
    4. The four falsifiability controls in the readiness gate: they are
       deliberately expected to report exactly 1, so a sweep that over-reports
       fails them rather than passing quietly.

- Discovered, recorded, NOT folded in (for coordinator classification):
  - `tests/lifecycle-tests.sh:1721` and `:1727` carry the same vacuous
    `index(.)` shape as the readiness sweep C2-A fixed — `$pub | index(.)` on
    the status and adoption results. They are green today because they select
    nothing, not because the vocabularies agree. They are in a gate this cycle
    did not otherwise need to touch, so they were left alone; the readiness and
    dispatch gates now cover the same property with working sweeps and their
    own controls. *(Registered by the full review as N1 and fixed in cycle 3.)*
  - `afk_monitor_summarize` reports an unreadable watch record through
    `dispatch_monitor.state = NEEDS_HUMAN` and emits no finding on the
    read-only path, so a plain `status` surfaces it in the summary but not in
    `findings`. That is deliberate — an unreadable dispatch record is not an
    installation-integrity defect — but it is a reporting asymmetry a reviewer
    may want to rule on.

- Final diff size, cycle 2:
  - 10 files: 2 added (`lib/afk-monitor.sh`,
    `tests/lifecycle-dispatch-tests.sh`), 8 modified.
  - Cycle 2 adds roughly 1,500 reviewable lines on top of cycle 1's ~3,200:
    about 700 for the monitor library, about 600 for its gate, and about 200
    across the contract document, the schema, the result model and the CLI.
  - **The story's total is now roughly 4,700 added+changed reviewable lines,
    about six times the ~800-line single-PR budget.** The cycle-1 flag stands
    and is now larger; per the standing constraint nothing was restructured to
    shrink it. The natural split has one more layer than it did: (1) contract
    vocabulary + schema + document, (2) offline readiness, (3) live probes,
    (4) the dispatch monitor and its cleanup — each with the slice of gate that
    proves it. That is a packaging decision and remains the coordinator's.

### Cycle 1

- Status: implemented — **gates not executed in this session** (see "Gates" below). Cycle 1 of 3.

- Implementation artifacts:
  - `lib/afk-readiness.sh` (new) — the scoped readiness engine. Declares this
    executor's capability contracts (approved harnesses, required Orca
    capabilities, closed effort set, supported stamp/validator/wiring/
    orchestration schema majors); the bounded probe runner; the uniform live-fact
    record (state, evaluated, reason, observed_at, timeout_ms,
    freshness_seconds, provenance, transient, `launch_authoritative: false`);
    offline executable resolution; mechanical BMAD target-wiring resolution; the
    read-only orchestration bridge; execution-stamp shape/expiry/launch-contract/
    funding evaluation; workspace-trust reporting; live Orca, validator-fixture,
    harness capability/auth and router probes; scope aggregation; and the
    readiness half of the published reason vocabulary with a message and a
    required action for every code.
  - `bin/agent-flow-kit` — sources the new library, adds `--live`,
    `--synthetic-route`, `--stamp <path>` and `--target <id>` to `status` and
    `verify` (with usage refusals for the combinations that mean nothing),
    declares the new configuration variables, and removes the validator fixture
    directory on the same `EXIT` boundary that releases the operation lock.
  - `lib/afk-common.sh` — `orchestration` added to the normalized result
    document, its well-formedness check and the human projection; readiness
    facts, per-target verdicts and the route summary rendered in human output;
    `afk_reason_message`/`afk_reason_action` consult a readiness extension hook
    before their own table so a code, its message and its action stay in one
    place; `--live`, `--synthetic-route`, `--stamp` and `--target` added to the
    closed diagnostic vocabulary.
  - `lib/afk-commands.sh` — readiness evaluated after component classification;
    `afk_apply_readiness_exit` makes a `--live`/`--stamp` run answer with the
    scope it was asked about; provider variables added to the presence-only
    environment report; `verify` reports `offline`/`live_probes_performed` for
    the invocation rather than hard-coding them; `schema` publishes the merged
    reason vocabulary plus `readiness_states`, `target_states`,
    `live_fact_states`, `orchestration_states`, `orchestration_modes`,
    `approved_harnesses` and the new evidence-provenance values.
  - `lib/afk-inventory.sh` — the presence-only `afk_evaluate_targets` removed;
    target resolution now belongs to the readiness engine, and directory
    presence is no longer a target verdict.
  - `docs/LIFECYCLE-CONTRACT.md` — the readiness scopes and their independence
    cases, live-probe limits, the Orca/validator/harness/router contracts, the
    target-wiring resolution table, the execution-stamp intersection table,
    placement exclusion and observation-is-not-authorization, the orchestration
    bridge, and the new machine-checkable vocabularies.
  - `tests/lifecycle-readiness-tests.sh` (new) — the Story 1.3 gate: unit
    matrices for the reason vocabulary, launch contract, funding conflicts,
    stamp shape and target wiring, plus seven stubbed-live scenario sections.
  - `tests/lifecycle-tests.sh` — section 8 rebuilt around a wired target, an
    unwired target and an absent target coexisting; section 12 extended with the
    `orchestration` key, live-fact field/authority checks and the new
    vocabularies; new usage-refusal cases in section 13.
  - `tests/run-tests.sh` — the new library added to the shellcheck set and the
    readiness gate aggregated as section 9.

- Gates:
  - **Not executed here.** This worker session was granted Read/Glob/Grep/Write
    only; there is no shell tool in it, so `bash tests/lifecycle-tests.sh`,
    `bash tests/run-tests.sh` and `git diff --check` could not be run. Nothing
    below is a claim that they passed — the coordinator's independent re-run is
    the arbiter, and this record exists so a red gate is diagnosed against
    stated intent rather than against a guess.
  - What each gate is expected to cover after this change:
    - `bash tests/lifecycle-tests.sh` — the read-only lifecycle surface,
      including the rebuilt target-scope section and the extended contract
      section.
    - `bash tests/run-tests.sh` — shellcheck over the lifecycle set (now
      including `lib/afk-readiness.sh`), the dispatcher suites, and the
      lifecycle, mutation, concurrency and readiness gates.
    - `git diff --check` — whitespace; no trailing whitespace or conflict
      markers were introduced deliberately.
  - Highest-risk areas for that re-run, in order: shellcheck findings in the new
    library; the human-projection assertions in section 12 and readiness section
    7 (every readiness, live-fact and orchestration value must appear in the
    rendered text); and the schema/contract-document vocabulary comparison,
    which fails loudly if a single reason code is in one list and not the other.

- Findings and resolutions:
  - **Default mode does not execute third-party binaries.** FR-83 lists
    "locally discoverable capabilities" and "validator offline fixtures" among
    default facts. Running a harness binary is not a locally knowable fact: it
    starts an agent client that can write under `HOME` and can consume provider
    tokens, and it would break the frozen "no external binary was invoked"
    guarantee of default `status`. Resolution, stated as an explicit assumption:
    default mode evaluates every fact obtainable without running another
    program (installation, executable resolution, target wiring, orchestration
    state, and every deterministic property of a supplied stamp), and anything
    needing a dependency to RUN — Orca, validator fixtures, harness capability
    and auth, the router — is gated behind `--live`. This is documented in both
    the library header and the contract document. If the intended reading was
    that validator fixtures run by default, that is a one-line change to
    `afk_readiness_evaluate` plus the section-9 stub assertions.
  - **Target readiness supersedes the presence-only verdict from Story 1.2.**
    `afk_evaluate_targets` reported `NOT_EVALUATED` for any existing directory.
    FR-69 says directory presence is not compatibility, so that verdict is gone
    and the lifecycle-tests section 8 assertion that depended on it was
    rewritten around the AC it actually belongs to (target A incompatible,
    target B compatible, neither poisoning the host). No requirement was
    weakened; a placeholder was replaced with the real check.
  - **An option value must never reach a diagnostic.** The first draft put the
    `--stamp` path into the finding detail for an unreadable stamp. A
    caller-supplied path can be a mistyped credential, and the contract says
    the values of `--approve-plan`, `--stamp` and `--target` are never echoed.
    Removed; the stamp is identified by its content hash once it is readable.
  - **`verify --live` must not claim it probed nothing.** `afk_verification_json`
    hard-codes `offline: true, live_probes_performed: false`, which is true of
    the checks and false of the run. `afk_cmd_verify` now sets both from the
    requested mode; the mutating callers are unaffected.
  - **Stub selection in the readiness gate cannot use `VAR=value func`.** Bash
    keeps such an assignment after a function call, so one scenario's stub would
    have silently configured the next. Stubs are named globals passed explicitly
    by `run_afk` and reset per scenario, and every provider variable the funding
    checks look at is pinned there too, so the suite answers the same on a
    developer machine that exports one.
  - **A router timeout cannot be asserted without a bounding tool.** The timeout
    scenario skips honestly when `timeout(1)` is absent rather than passing on a
    probe that was never bounded; the library reports
    `PROBE_BOUND_UNAVAILABLE` on such a host instead of pretending.
  - **Not implemented in this story, and deliberately so:** the
    worker-completion monitor, the terminal/worktree/branch cleanup contract and
    their regressions in the sections above describe the dispatch and
    orchestration surface, not the lifecycle readiness surface this story's ACs
    and FR-47–90/FR-95 cover. Nothing here creates a worker, a terminal, a
    worktree or a branch, so there was no cleanup or completion path to
    implement inside this scope. If those sections were meant to be Story 1.3
    deliverables rather than standing context, they need their own story: they
    are a dispatch/coordinator feature, not a readiness one.
    *(Overruled by the coordinator in cycle 2; implemented above.)*

- Final diff size:
  - 9 files: 2 added (`lib/afk-readiness.sh`,
    `tests/lifecycle-readiness-tests.sh`), 7 modified.
  - Roughly 3,200 added+changed reviewable lines, of which about 1,800 are the
    new readiness library and about 830 the new gate.
  - **This exceeds the ~800-line / 25-file single-PR budget by roughly four
    times.** It is not splittable after the fact along useful lines — the
    engine, the contract document and the gate are one coherent unit and each is
    unreviewable without the others — so the honest reading is that the story
    was scoped too large for one PR. Recommended split before shipping, as a
    stacked chain: (1) contract vocabulary + schema + document, (2) offline
    readiness (executables, target wiring, orchestration bridge, stamp shape),
    (3) live probes (Orca, validator fixtures, harness auth, router), each with
    the slice of the gate that proves it. That is a planning decision, so it is
    flagged rather than taken.

## Cycle 2 dispatch notes (coordinator — read before implementing)

Cycle 1 settled `gates_failed`. Independent gate run (evidence:
`evidence/AFK-PORT-1.3-C1-gates/run-tests.log`): lifecycle PASS, mutation 577/0,
concurrency 207/0, shellcheck clean, `git diff --check` clean; the ONLY red is
`tests/lifecycle-readiness-tests.sh` — 215 passed, 4 failed, which fails
run-tests section 9 (aggregate 232/1). Cycle 2 scope is exactly the items below.
No additions; discovered gaps are recorded in the Dev Agent Record and
classified by the coordinator, never folded in.

### C2-A (defect, must fix): the three published-set sweeps are shape-broken

All three failures are one defect. At `tests/lifecycle-readiness-tests.sh` line
~633 the sweep's jq expression indexes with a string where the actual JSON
carries an array (errors: `Cannot index array with string "value"`, twice, and
`Cannot index array with string "state"`), so the count comparison gets `''`
against expected `'0'`:

- `every readiness state is inside the published set`
- `every live-fact state is inside the published set`
- `every target state is inside the published set`

Determine which side is right against `docs/LIFECYCLE-CONTRACT.md` (the emitted
document shape or the test's path expression), align them, and keep the sweep
falsifiable: after the fix it must still FAIL when an out-of-set state is
injected — state the anti-vacuity reasoning in the Dev Agent Record (you cannot
execute it here; the coordinator re-runs independently).

### C2-B (coordinator ruling — in scope, must implement): completion monitor + cleanup

The cycle-1 judgment that the "Required Worker-Completion Monitoring Contract",
"AFK-owned worktree and branch cleanup" sections and their "Required …
regressions" are standing context is OVERRULED. The standing coordinator ruling
(binding, recorded pre-kickoff) is that the rolling `check --wait` polling
pattern is the completion-monitoring DEFECT Story 1.3 exists to replace; the
frozen story carries those sections as required contracts with named required
regressions. They are Story 1.3 deliverables. Implement them per the frozen
text: durable completion watch that survives turn boundaries and reconnect;
completion authority only from the supervised Task/Dispatch `worker_done`/
escalation delivery; at-least-once idempotent delivery handling (ack only after
retention + reconciliation; replay must not duplicate reviews, cleanup,
traceability updates or terminal closure); heartbeat expiry / monitor failure
distinct from completion (loud `NEEDS_HUMAN`/monitor-degraded, never an
invented result); bounded event-driven or bounded-polling/backoff watch;
provenance-bound terminal/worktree/branch cleanup that fails closed
(`NEEDS_OWNER`) on ambiguity and never touches unowned/protected/user branches;
plus every scenario in the two "Required … regressions" lists as deterministic
stubbed tests. Boundaries stay as frozen: consume normalized state, no
dashboard, no terminal scraper, no router session registry, no control-plane
feature, no worker-originated delegation.

### C2-C (coordinator ruling): validator offline fixtures belong to DEFAULT mode

The frozen AC text names "validator-fixture" facts among default-mode evaluated
facts, and the anti-vacuity AC begins "When offline fixtures run". Ruling:
default `status`/`verify` runs the kit-trusted validator against local fixtures
(no network, no tokens, no mutation outside temp scratch); harness/agent-client
binaries remain unexecuted by default. If implementing this turns a FROZEN
Story 1.1/1.2 gate assertion red (e.g. a "no external binary was invoked"
proof that enumerates the validator), do NOT weaken the frozen assertion and do
NOT silently revert: keep the fixtures behind `--live`, record the exact
colliding assertion in the Dev Agent Record under a "Frozen-requirement
collision" heading, and leave the disposition to the coordinator.

### Standing constraints (unchanged)

- Fix honestly; no test weakened to pass; prior scenarios stay pinned.
- The ~4× diff-size flag is recorded; do not restructure to shrink it —
  packaging is a later human decision.
- Gates cannot run in your session (no shell); say so plainly again in the
  record. The coordinator re-runs them independently after you finish.

## Coordinator freeze record (PM, 2026-08-26)

Story 1.3 converged over four implementation/fix cycles and three independent
reviews, every worker a fresh stamped session, no route ever substituted:

| Dispatch | Route (all natural /v1/route acceptances) | Outcome |
|---|---|---|
| Cycle 1 implement | claude/claude-strong/high, stamp 31e65b15 | gates_failed (one suite red) |
| Cycle 2 fix | same stamp, revalidated | done, all gates green |
| Full adversarial sweep | stamp 832a4464 | NOT CLEAN — 4 blockers (B1–B4), 14 non-blocking |
| Cycle 3 fix (Josh-authorized: B1–B4+N1) | stamp f7ce0f80 | done; all four attack oracles flipped NOT REPRODUCED |
| Diff-scoped post-fix review | stamp 59e02572 (attempt-1 local route archived, corrected re-route) | NOT CLEAN — P1, P2 (remedy-completeness), 8 non-blocking |
| Cycle 4 fix (Josh-authorized, over-budget: P1+P2+D2) | stamp 396ac383 | done; P1/P2 flipped, A1–A4 stable |
| Final diff-scoped review | stamp 81280bf0 | **CLEAN** — deviation judged sound, 7 non-blocking |

- **Gate state at freeze:** run-tests 235/0 (readiness 231/0, dispatch 182/0,
  mutation 577/0, concurrency 207/0, shellcheck clean), lifecycle 476/0,
  `git diff --check` clean — logs in `evidence/AFK-PORT-1.3-C4-gates/` plus the
  post-docs-fix lifecycle revalidation log.
- **Oracle state at freeze:** A1–A4, P1, P2 all NOT REPRODUCED with controls
  holding (coordinator-executed); R1 CONFIRMED as pre-existing residual
  evidence (readiness probes, below).
- **F1 (final review) resolved under the pre-authorized docs/record-only
  lane:** the cycle-4 cross-reference sentence in
  `docs/LIFECYCLE-CONTRACT.md` now states the readiness warn-and-run reading
  inline instead of claiming it is stated elsewhere. Validated by the lifecycle
  gate rerun + `git diff --check`. The underlying divergence — readiness
  probes still run unbounded where no bounding tool exists, so the frozen
  `PROBE_BOUND_UNAVAILABLE` sentence remains untrue of them — is REGISTERED to
  the hardening backlog with `R1-readiness-probe-unbounded.sh` as evidence,
  not silently fixed.
- **F4 registered (hardening backlog):** an Orca that accepts `--durable` and
  ignores it defeats the durable-close proof; candidate remedy is gating on the
  capability list the Orca probe already reads. F2/F3/F5/F6/F7 registered
  alongside; none blocks.
- **C2-C ruling (Josh):** validator fixtures remain behind `--live`;
  "validator-fixture facts" in default mode means materialisability and
  validator resolution. Recorded verbatim in the cycle-3 record.
- **Operational incidents (evidence, honest record):** (1) an Orca runtime
  restart mid-session silently lost a committed-looking worker_done — detected
  by reconnect reconciliation, re-sent as explicit recovery; (2) attaching
  `worker-start --terminal` to a batch dispatch.sh terminal bracket-pasted an
  agent preamble into the shell, auto-failed the Dispatch record, and starved
  the launcher's exit-marker watch for the final review (worker product was
  complete and verified on disk; task settled by explicit recovery). Both are
  live specimens of the defect classes this story's monitor/cleanup contracts
  address; both recorded in the worker-done evidence files.
- **Packaging:** cumulative reviewable diff ≈5,000 lines across 10 files —
  far beyond the single-PR budget. Recommended stacked split (per the cycle-1
  record plus the cycle-3 monitor layer): (1) contract vocabulary + schema +
  document, (2) offline readiness, (3) live probes, (4) dispatch monitor +
  cleanup. Decision is Josh's; nothing committed, pushed, or PR'd.

Status: **IMPLEMENTED + VERIFIED — freeze pending Josh's acceptance and
packaging decision.**

### Superseding freeze revision (PM, post-publication triage)

The `cfcf9b5` freeze is superseded by **`7d126fc5df9060061b72072ad32c9d9aaec96669`**
after one Josh-authorized PR-triage round: external review (Devin) on the
published chain found the per-dispatch heartbeat window was honored only for
the first deadline (E1, fixed with a discriminating regression + legacy
control) and re-surfaced residual N3 (readiness-suite skip counting, now fixed
to the dispatch-suite pattern). Gates green on the superseding tree (run-tests
235/0, lifecycle 476/0, diff-check clean); monitor oracles A3/P1/P2 re-verified
NOT REPRODUCED. The PR chain was rebuilt from the superseding tree with the
CLI entry point moved to the monitor layer (external layering finding), layer 5
byte-identical to this revision. All six external findings dispositioned with
replies and reactions; history retained.

**Freeze-scope boundary (required wording, Josh, freeze review).** The
composed-dispatch, turn-boundary completion delivery, cross-harness status
render, and durable-close-after-reconnect capabilities are IMPLEMENTED and
STUB-PROVEN in Story 1.3 (deterministic and stubbed suites, per the frozen
"where implementation support precedes Story 1.4 proof" clause). Their LIVE
proof is registered to Story 1.4 ("Acceptance Conditions Registered by Story
1.3" in `AFK-PORT-1.4.md`). "Story 1.3 FROZEN" is not a claim that any of
these four was demonstrated live.
