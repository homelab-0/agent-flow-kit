---
title: 'AFK Runtime Experience Across Harnesses'
type: 'feature'
created: '2026-09-14'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: '64d357fb4db5b82633e6b979d7b1bb7a5d7c0e65'
context:
  - 'docs/LIFECYCLE-CONTRACT.md'
  - '_bmad-output/planning-artifacts/epics-block-1.8.md'
  - '_bmad-output/planning-artifacts/prds/prd-agent-flow-kit-2026-08-24/prd-addendum-1.8.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** AFK agents are running, but the operator cannot see consistent live state across harnesses; PM continuation is manual, worker pressure is learned too late, onboarding is fragmented, and each VM requires manual source updates.

**Approach:** Establish one AFK runtime contract with a visible status surface and adapter registry, then use it for safe PM/worker continuation, harness onboarding, and transactional fleet convergence. Deliver the renderer and current adapters first so visible value lands before deeper automation.

## Boundaries & Constraints

**Always:** Support Claude Code, Codex, and OpenCode as first-class coding harnesses; preserve Hermes as the remote human front door, not a worker/router. One normalized, versioned AFK state document drives all presentations. Show AFK role, task, phase, model/harness, context pressure, workers, owner action, update state, and subscription/reset data when an adapter can authoritatively observe it; render `NOT_EVALUATED`, `UNAVAILABLE`, or `STALE` otherwise. Context thresholds come from declared policy and actual model-window authority. A PM handoff is durable and idempotent: checkpoint, launch exactly one successor in Orca, receive successor acknowledgement, reconcile ownership, then durably close only the proven old terminal. Worker pressure reaches its owning PM through durable monitor messages and resumes through canonical continuation dispatch. Onboarding and updates preserve local config, hooks, skills, Hindsight, and credential references without reading, copying, or syncing secrets. Updates use a single host lock, immutable revision, clean forward ancestry, plan/verify/apply/rollback, offline fallback, and canary-to-wave rollout. Current files, route stamps, approvals, and gate evidence outrank memory.

**Never:** Invent context or billing figures; scrape transcripts for authority; let a renderer mutate orchestration; start duplicate successors; close an unowned/active terminal before acknowledged handoff; overwrite dirty/user-managed files; automatically use rollback/noncanonical bypasses; make Hermes select routes or create workers; make Hindsight an approval, review, or routing authority; modify ACP or prox-ops from this AFK task. ACP interface needs are requests to its PM.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Visible session | Supported harness with fresh AFK state | Compact native bar/card from the shared renderer | Missing fields are explicit, never blank or guessed |
| PM pressure | PM crosses continuation threshold | One successor receives the durable handoff; old terminal closes after ACK | Replay finds the same transition; failure leaves old PM visible and recoverable |
| Worker pressure | Worker crosses threshold at a phase boundary | Durable escalation reaches owning PM and next canonical cycle resumes | Unobservable usage checkpoints conservatively and reports why |
| Fleet update | New eligible canonical revision | One locked, verified transaction converges managed files | Dirt, divergence, outage, failed gates, or ambiguous plan stops and keeps last good revision |
| New harness | Declared adapter capabilities and local binding | Onboarding installs only supported integrations and reports qualification | Detection alone never advertises launchability |

</frozen-after-approval>

## Code Map

- `lib/afk-commands.sh` -- status document, PM budget, checkpoint, and reconciliation.
- `lib/afk-monitor.sh` -- durable worker messages and owned terminal cleanup.
- `files/model-router/scripts/dispatch.sh` -- routed launch, usage adapters, and continuation cycles.
- `lifecycle/kit.json` and `lib/afk-{source,inventory,plan,mutate}.sh` -- managed onboarding/update transaction.
- `files/model-router/harness-bindings.yaml` and `files/model-router/scripts/harness-inventory.sh` -- port the proven OpenCode registry work onto current master.
- `adapters/` -- shared status renderer plus Claude, Codex, OpenCode, and Hermes presentation/observation registrations.
- `tests/` -- contract, adapter, continuity, mutation, outage, and replay coverage.

## Tasks & Acceptance

**Execution:**
- [x] Extend the status schema and build the bounded shared renderer/cache with declared timing policy.
- [ ] Add idempotent Claude, Codex, OpenCode, and Hermes presentation adapters; Claude, Codex, and OpenCode now have live Orca canary evidence in addition to contract-backed offline integrations, while Hermes's live surface is not yet qualified.
- [x] Port the current OpenCode binding/inventory implementation without its unrelated divergent history; expose capability-qualified harness inventory to onboarding while keeping router activation contract-gated.
- [x] Add harness-native context observations and durable exact ownership for PM and worker sessions; numeric Claude pressure and conservative Codex/OpenCode compaction boundaries are fixture-proven.
- [x] Replace human-only PM continuation with a persisted `OBSERVED → CHECKPOINTED → SUCCESSOR_LAUNCHED → ACKED → OLD_CLOSED` state machine; wire worker threshold messages to canonical continuation dispatch.
- [x] Harden PM replacement continuity across repeated generations: persist a generation-specific create attempt before invoking Orca, never reissue while its outcome is ambiguous, recover only from attributable/idempotent evidence, and consume or generation-key completed replacement journals once a durable successor receipt exists.
- [x] Apply the same repeated-generation continuity contract to routed worker continuations: persist a generation/source-bound create attempt before Orca create, block visible and lagging ambiguous outcomes, and consume completed replacement journals with crash-replayable evidence so later worker deaths can advance independently.
- [x] Add a host-scoped release reconciler and cheap session-start freshness check using existing lifecycle plan/apply/rollback machinery.
- [ ] Reconcile Hindsight and obsolete OMEGA guidance: story/dispatcher `memory_mode` enforcement and the isolated blind/off boundary are implemented and fixture-proven; actual Orca-launched coding-agent recall/retain and outage behavior still require live qualification.
- [ ] Update operator/onboarding docs and add offline fixtures plus live Orca qualification matrices for each installed harness; offline fixtures exist, while live visual qualification remains `NOT_EVALUATED`.

**Acceptance Criteria:**
- Given any onboarded supported harness, when an AFK session starts, then the operator sees a compact AFK status surface within the declared render budget and stale/unavailable data is unmistakable.
- Given PM or worker context pressure, when the policy threshold is crossed, then the durable handoff completes exactly once without lost work, duplicate launch, or premature terminal closure.
- Given a clean eligible update, when the host reconciler runs, then managed AFK components advance transactionally while machine-local settings and secrets remain untouched; unsafe or offline states retain the last good version and report a reason.
- Given a fresh/repeated onboarding run, when harness capabilities are inspected, then supported adapters converge without duplication and unsupported capabilities remain explicit.
- Given a blind review, when memory context is prepared, then implementation conclusions and prior review findings are excluded while authoritative project evidence remains available.

## Implementation Notes

- Added a versioned adapter registry, cache-only renderer plus background publisher, explicit stale/unavailable states, and native presentation entry points for Claude Code and Codex. Live Orca canaries verified Claude's composed status command and Codex's supported native footer plus first-turn SessionStart publication. OpenCode's supported event/toast plugin API was also verified live; no persistent OpenCode custom status line is claimed. Hermes remains unqualified because it is not installed on this VM.
- Default runtime caches are isolated by exact Orca terminal (or canonical working directory outside Orca), and PM ownership is isolated by worktree while remaining shared across successor terminals. Explicit launcher paths remain authoritative.
- Added reversible adapter installation, strict OpenCode capability inventory and route binding validation, and lifecycle-managed distribution of the runtime adapter tree.
- Added durable PM succession with transition identity, acknowledgement-bound ownership transfer, and proven old-terminal closure. Claude numeric pressure reaches an exactly bound PM at the next prompt boundary; routed-worker and Codex/OpenCode compaction pressure produces one durable canonical-continuation signal without giving adapters launch authority.
- Hardened replacement recovery with generation-numbered internal launch receipts, source-bound create-attempt records written before Orca create, and replay-safe completed-journal consumption. Ambiguous visible or lagging post-create states now remain blocked; a durable successor receipt replays without duplication and permits a later terminal death to advance to the next generation.
- Applied the same generation contract to routed worker continuations. Replacement attempts are durable before Orca create, completed close journals are consumed through a marker-first/marker-last cleanup, and a partial cleanup or pre-ledger crash replays from exact local evidence without duplicate launch.
- Added locked immutable-revision release reconciliation, offline freshness reporting, a native Hindsight readiness helper, dispatcher-enforced `advisory|required|blind|off` modes, and an isolated blind/off boundary. Live coding-agent memory qualification remains open and is not replaced by fixtures.
- Formal review hardened the startup gate, adapter reconvergence, candidate qualification/last-good retention, OpenCode result and memory paths, cache-only render budget, PM checkpoint locking, exact threshold validation, and shell/argument boundaries. The review did not widen Hermes into a worker or make fixtures substitute for its separate deployed bridge qualification.
- Kept ACP and prox-ops outside this implementation boundary; the related external-product follow-ups are recorded separately as withdrawn by ACP.

## Spec Change Log

- 2026-09-14: Implemented the runtime experience, marked execution tasks complete, recorded verification evidence, and moved the spec to review. The frozen intent block was not changed.
- 2026-09-14: Corrective audit returned the spec to in-progress, restored the released route-request contract by gating `available_bindings` off by default, replaced invented harness surfaces with native integrations, and reopened live/Hermes/memory-mode work that is not qualified.
- 2026-09-15: Live title inspection exposed host-global cache/PM defaults that could misattribute one session's model, context, or ownership to another. Defaults were split into terminal-scoped runtime caches and worktree-scoped PM state with concurrency coverage.
- 2026-09-15: Live Claude and Codex canaries exposed two reversible-install defects (empty hook-group ownership and an unsupported Codex footer item) plus a Codex absent-footer removal defect. The fixes preserve empty user hook groups, use Codex's supported `context-remaining` item, and remove an AFK-created empty `tui` table.
- 2026-09-15: The live OpenCode canary exposed its current nested model payload and sparse follow-up events. The adapter now normalizes `providerID`/`modelID` as strings and retains prior terminal-scoped observations when an idle/status event omits those fields.
- 2026-09-15: Corrected repeated PM replacement continuity: every replacement generation now records its create attempt before the external side effect, refuses ambiguous reissue, and consumes its completed close journal only after the exact next-generation receipt is durable.
- 2026-09-15: Ported the repeated-generation correction to worker continuation launch: ambiguous replacement effects now block visible and lagging replay, completed journals are crash-safely consumed, and later dead replacements advance to a new generation instead of selecting stale close evidence.

## Review Triage Log

- 2026-09-15 `carried` — **high / patch:** a PM replacement side effect could precede its durable receipt and duplicate on a lagging list. Generation-bound pre-create attempts now refuse visible and lagging ambiguity; the repeated-generation fixtures prove no duplicate.
- 2026-09-15 `carried` — **high / patch:** a completed PM replacement journal could poison the next generation. Completed journals are now consumed only after durable successor evidence, and the second-death/crash-replay fixtures pass.
- 2026-09-15 `carried` — **high / patch:** worker continuation replacement could reissue after a lost receipt. Worker launch now persists an exact generation/source-bound attempt before Orca create and refuses ambiguous replay.
- 2026-09-15 `carried` — **high / patch:** one fixed worker close journal could block later replacement generations. Marker-first/marker-last consumption and generation-specific journals now pass second-death and partial-cleanup replay fixtures.
- 2026-09-16 `R1-B01` — **high / patch:** native updater hooks had a 30-second outer deadline below the release client's possible fetch-plus-qualification time. The installed hook contract is now 120 seconds, schema-v2 records migrate atomically from 30 to 120, and runtime/session integration passes.
- 2026-09-16 `R1-B02` — **high / patch:** Linux OpenCode resolved updater failures and registered normal event handling from unverified state. Linux startup now rejects with a visible error; only the separately documented Darwin degraded path remains fail-open.
- 2026-09-16 `R1-B03` — **high / patch:** immediate group kill could skip the release client's descendant cleanup. OpenCode now sends TERM, waits for the reconciler's cleanup trap, then uses KILL only after the bounded grace period; timeout startup remains rejected.
- 2026-09-16 `R1-B04` — **high / patch:** pre-mutation candidate failures other than fetch outage blocked sessions despite a provable installed release. Trust, checkout, sandbox, qualification, and unsafe-plan failures now retain only a freshly re-proven last-good release; release-update is 152/152.
- 2026-09-16 `R1-B05` — **medium / patch:** the candidate-owned release test was syntax-checked but never executed. Qualification now runs the candidate's bounded, offline `--candidate-smoke` contract inside the sandbox; the trusted client still owns the exhaustive apply/rollback/locking suite.
- 2026-09-16 `R1-B06` — **high / patch:** candidate policy checks omitted timeout ranges, offline fallback, and rollout invariants. Candidate qualification now enforces the same closed invariants before execution or installation.
- 2026-09-16 `R1-B07` — **medium / patch:** native no-argument startup hooks did not reconverge existing adapter registrations after release changes. Session start now discovers only readable active AFK ownership records and runs the manager for each before launch; the executable gate matrix proves the call boundary.
- 2026-09-16 `R1-B08` — **medium / patch:** a sessionless OpenCode event could overwrite a terminal's session-bound model/context observation. Sessionless events now leave prior session state untouched; sparse-event integration remains green.
- 2026-09-16 `R1-B09` — **high / patch:** OpenCode exit-zero error envelopes could become `done`. The dispatcher now requires a nonempty object stream ending in the exact native `step_finish/step-finish/stop` shape and marks native error envelopes as harness errors.
- 2026-09-16 `R1-B10` — **high / patch:** recursive JSON string flattening could treat tool input or metadata as control output. The parser now extracts only authoritative text events; forged tool content cannot emit continuation or human-action markers.
- 2026-09-16 `R1-B11` — **high / patch:** the renderer declared a time budget without enforcing it and could block on a FIFO runtime path. All jq work is bounded by the declared budget and inputs must be regular files; stale and FIFO fixtures pass.
- 2026-09-16 `R1-B12` — **medium / patch:** Claude re-executed the preserved owner status command through different shell semantics and dropped it when no bounding tool existed. It now uses `/bin/sh -c`, preserves the owner command on an unbounded host, and passes a pipeline/redirection semantics fixture.
- 2026-09-16 `R1-B13` — **high / patch:** Claude/Codex continuation text beginning with `-` could become harness options. Bootstrap now inserts `--`; the `--dangerous` positional-data fixture passes.
- 2026-09-16 `R1-B14` — **medium / patch:** PM threshold parsing allowed reversed or above-one ratios. PM budgeting now requires `0 <= checkpoint < continuation <= 1`; reversed and 1.10 fixtures report `PM_BUDGET_POLICY_UNREADABLE`.
- 2026-09-16 `R1-B15` — **high / patch:** required Hindsight wiring accepted substring and commented-out matches. Claude/Codex hook commands must now equal audited paths and OpenCode JSONC is structurally parsed; substring and comment-only fixtures refuse.
- 2026-09-16 `R1-B16` — **high / patch:** a stale helper `READY` result was not bound to requested mode, repository, package/version, or native-integration disposition. All fields are now exact and three independent mismatch fixtures refuse.
- 2026-09-16 `R1-B17` — **high / patch:** the memory helper used PATH-selected Bash. It now executes through `/bin/bash -p` inside the scrubbed environment.
- 2026-09-16 `R1-B18` — **medium / patch:** inventory probed literal `codex` while dispatch could use a configured binary. Inventory now resolves the launcher contract/environment value before probing.
- 2026-09-16 `R1-B19` — **low / patch:** runtime documentation claimed valid JSONC was refused although the manager safely edits and restores it. The operator contract now describes the implemented structural JSONC path.
- 2026-09-16 `R1-B20` — **medium / patch:** HANDOFF preflight omitted load-bearing runtime dependencies. It now names sandbox, lock, parser, canonicalization, hash, and timeout requirements, including macOS `gtimeout`.
- 2026-09-16 `R1-B21` — **medium / patch:** ordinary user-owned Homebrew jq cannot satisfy the macOS privileged-tool proof. Startup continues to fail closed, while HANDOFF now explicitly requires a system-managed jq/toolchain instead of suggesting ordinary Homebrew ownership is qualified.
- 2026-09-16 `R1-E01` — **high / patch:** the generated OpenCode MiniMax model omitted a required output-capacity field; installed OpenCode 1.18.31 rejected the config. It now declares `{context:1000000,output:65536}` and the generated-config fixture passes.
- 2026-09-16 `R1-E02` — **high / patch:** required/advisory OpenCode memory launched with `--pure`, disabling the audited plugin. Memory-enabled launches now omit `--pure`; blind/off remain pure.
- 2026-09-16 `R1-E03` — **high / patch:** the same `--pure` defect also prevented OpenCode compaction events from reaching continuation handling. The enabled-plugin launch and pressure integration fixtures now pass.
- 2026-09-16 `R1-E04` — **high / patch:** a context event could consume another dispatch's retained result. Launch evidence now records and revalidates the exact dispatch ID and worker identity; cross-worker consumption refuses.
- 2026-09-16 `R1-E05` — **medium / patch:** dispatcher thresholds could be reversed or above one. Dispatch policy now requires `0 <= sizing_risk < checkpoint < continuation <= 1`; both invalid-policy fixtures refuse before launch.
- 2026-09-16 `R1-E06` — **medium / patch:** configured Codex binaries and inventory could diverge. Inventory now shares the launcher-configured binary resolution and no longer hardcodes `codex`.
- 2026-09-16 `R1-E07` — **high / patch:** `pm-checkpoint` could race a handoff digest check and write. The public command now holds the host lifecycle lock across validation and atomic write; lifecycle mutation paths retain the same singleton boundary.
- 2026-09-16 `R1-E08` — **high / patch:** runtime observations were displayed without an age check. The renderer now accepts only fresh `observed_at` values within policy staleness and otherwise falls back without presenting expired model/context data.
- 2026-09-16 `R1-E09` — **false:** the 250 ms declaration bounds cache-only status rendering, not release reconciliation or plugin construction. OpenCode must finish its separately bounded verified-start gate before registering event callbacks; allowing an unverified callback merely to meet render latency would violate the stronger startup contract.
- 2026-09-16 `R1-V01` — **high / patch:** no test exercised public `agent-flow-kit pm-start`. The runtime suite now invokes the installed CLI, asserts its exact registration intent, and validates the lifecycle result.
- 2026-09-16 `R1-V02` — **high / patch:** the Linux session launch gate was grep-tested but lacked negative execution cases. A table-driven integration matrix proves current/retained verified success and refuses unverified, failed-reconciler, and blocked cases before adapter or command effects.
- 2026-09-16 `R1-V03` — **medium / patch:** public schema and lifecycle docs omitted `pm-start` while operator instructions prescribed it. Both machine contract surfaces now include it and the schema/document equality gate passes.
- 2026-09-16 `R1-V04` — **low / patch:** runtime docs described canonical-working-directory fallback outside Orca, contradicting session-ID isolation. Documentation now matches the enforced session-scoped behavior.
- 2026-09-16 `R1-V05` — **low / patch:** freshness docs named source-vs-applied states the executable does not emit. Documentation now describes accepted-vs-applied comparison and its `ACCEPTED_LOCALLY`, `UNPROVEN`, `MISMATCH`, and `NOT_EVALUATED` vocabulary.

## Design Notes

The renderer is not a new authority: adapters publish normalized observations, AFK status resolves them with durable orchestration state, and each harness-specific surface only formats that document. Visual-first sequencing is: shared schema/renderer → Claude live bar → Codex/OpenCode adapters → Hermes remote card; later slices reuse the same contract rather than redesigning presentation.

## Verification

**Commands:**
- Focused standalone lifecycle, mutation, readiness, dispatch, and runtime-experience suites -- offline corrective gates.
- Adapter fixture tests with bounded clocks, fake installed trees, and isolated homes -- cache-only output, composition, native configuration, outage, and uninstall behavior.
- Live native harness canaries are not represented by fixtures. The universal Orca title was exercised against Orca 1.4.199 on the exact current terminal, including an exact restore. Claude Code 2.1.270, Codex 0.145.0, and OpenCode 1.18.31 were separately exercised in fresh Orca terminals; Hermes remains `NOT_EVALUATED` until its deployed integration canary runs.

**Results (through 2026-09-16):**

- 2026-09-16 formal-review hardening focused gates: runtime experience 477/477; worker memory/continuation 102/102; session-start integration 82/82; release update 152/152; lifecycle 503/503; readiness 363/363; native pressure 46/46; harness-start contract 4/4; session-gate contract 5/5; release-reconciler contract 5/5. `bash -n`, OpenCode `node --check`, `git diff --check`, and Nix ShellCheck over the changed production/test surface pass.
- OpenCode 1.18.31 `debug config` independently rejected the pre-review generated MiniMax model because `limit.output` was absent. The generated config now declares the validated context/output pair, and strict native JSONL termination/error/text fixtures pass.
- On 2026-09-16, one uninterrupted aggregate on the exact formal-review working tree completed with 912 passed and 0 failed. Captured component gates included lifecycle 503/503, lifecycle mutation 577/577, lifecycle concurrency 207/207, lifecycle readiness 363/363, lifecycle dispatch 298/298, runtime experience 477/477, Orca-visible status 20/20, worker memory/continuation 102/102, release update 152/152, session-start integration 82/82, native worker/PM pressure 46/46, and modular runtime contracts 31/31. The aggregate also passed ShellCheck for every shipped script and the offline Claude evidence verifier 147/147; the opt-in live control-plane chain remained intentionally skipped and no model was launched.

- Stable corrective runs: lifecycle 503 passed, 0 failed; isolated lifecycle mutation 577 passed, 0 failed; lifecycle concurrency 207 passed, 0 failed; lifecycle readiness 359 passed, 0 failed; lifecycle dispatch 287 passed, 0 failed.
- Focused runtime gates: runtime experience 80/80 after the Claude/Codex live-canary corrections; native worker/PM pressure 45/45; worker memory/continuation 46/46; session-start integration 43/43 after pinning OpenCode's live nested-model and sparse-idle shapes; Orca-visible status 20/20; release update 31/31. The terminal/worktree isolation change also passed lifecycle readiness 359/359.
- Repeated-generation continuity correction: runtime experience 173/173, worker memory/continuation 79/79, lifecycle dispatch 298/298, and native worker/PM pressure 45/45. Fixtures cover visible and lagging crash-before-receipt ambiguity, durable-receipt replay before the caller ledger, and a second death advancing from generation 1 to generation 2 with exactly one new create.
- Worker continuation parity correction: worker memory/continuation 88/88, runtime experience 173/173, lifecycle dispatch 298/298, and native worker/PM pressure 45/45. Added fixtures for visible and lagging post-create ambiguity, durable receipt replay before ledger append, second death/replacement, and interrupted consumed-marker cleanup.
- Route-contract fixtures passed for byte-preserving default omission of `available_bindings`, rejection of caller-supplied inventory, and explicit opt-in inventory attachment.
- ShellCheck (from Nix), `bash -n`, the OpenCode plugin's `node --check`, and staged/unstaged `git diff --check` all passed.
- The live universal Orca-title canary exposed and corrected the real `result.rename` receipt shape; after the fix, the AFK title appeared on the exact terminal and its prior title was restored exactly. The focused title suite remained 20/20 with the real receipt shape modeled.
- The Claude Code 2.1.270 canary ran the real SessionStart hook in a fresh Orca terminal, captured the Opus 5 one-million-token window in that terminal's scoped cache, and rendered AFK ahead of the pre-existing `ccstatusline-usage` output. Removal restored the user settings byte-for-byte. The first removal exposed an empty `PreCompact` ownership defect; the corrected installer now preserves all pre-existing empty hook groups.
- The Codex 0.145.0 canary verified the native footer with `gpt-5.6-sol high`, used/remaining context, weekly usage, branch, and task progress. Codex runs `SessionStart` on the first submitted turn rather than the empty TUI launch: that turn displayed the AFK system message and produced a terminal-scoped runtime observation containing the model and session ID. A separate update-reconcile hook failed closed because the canary source was intentionally noncanonical; the presentation publisher completed. Removal restored global hooks and config byte-for-byte after discarding canary-created hook trust, and a fresh Orca launch rematerialized the account profile without AFK hooks or footer entries.
- The OpenCode 1.18.31 canary preserved the installed Hindsight plugin, visibly rendered the AFK toast inside OpenCode, and captured `openai` / `gpt-6-astra`, the exact OpenCode session ID, and 18,433 observed turn tokens in the exact Orca-terminal cache. A subsequent sparse idle event retained those values. Removal restored `opencode.jsonc` byte-for-byte; the two canary-only OpenCode sessions were then deleted and their terminals closed.
- A concurrently edited aggregate run and a parallel-load mutation run were discarded; neither is used as acceptance evidence.
- One uninterrupted aggregate on exact commit `e10d4a824df0bb4ca92210f8f2102962c5bcd8de` passed 898 assertions with 0 failures, including every standalone count above. A later uninterrupted aggregate on exact commit `b42a1d57b4466265c2cbf542ee3a4910286e7cfe` also passed 898/898 after the Claude, Codex, and OpenCode live-canary corrections. Its component totals included lifecycle 503/503, mutation 577/577, concurrency 207/207, readiness 359/359, dispatch 287/287, runtime experience 80/80, Orca-visible status 20/20, worker memory/continuation 46/46, release update 31/31, session-start integration 43/43, and native pressure 45/45.
- The final integrated hardening tree at exact implementation commit `e588964bd2a3229f91bc569976e7d851c47d8fa9` completed one uninterrupted aggregate with 898 passed and 0 failed. Its captured component gates were lifecycle 503/503, mutation 577/577, concurrency 207/207, readiness 359/359, dispatch 298/298, runtime experience 472/472, Orca-visible status 20/20, worker memory/continuation 88/88, release update 152/152, session-start integration 68/68, and native pressure 46/46; the offline Claude evidence verifier was 147/147 and the opt-in live control-plane probe remained intentionally skipped. ShellCheck ran through Nix and passed every shipped script in the aggregate.
- A fresh read-only integrated review of `245b6a4..e588964` returned CLEAR PASS with no actionable findings. It independently checked the resolved Linux/Darwin schema-v3 installer behavior, PM and worker generation-bound replacement recovery, updater/bootstrap/Hindsight trust boundaries, all four harness presentation paths, and the final lint-intent corrections; its representative focused gates matched the integrated totals above.
- The bounded blind local-model review attempt is rejected as review evidence: its four declared gates passed, but the harness exited 1 with `is_error=true` after 34 turns because repeated autocompaction thrashed a 65,536-token window. It produced only an incomplete checkpoint and no findings. Three earlier sliced review artifacts are rejected for the same reason: their thin results said `done`, while their authoritative Claude envelopes reported `is_error=true` from context overflow or failed compaction. The production dispatcher now prevents that contradiction: passing repository gates cannot turn a nonzero harness exit, explicit harness error, or invalid Claude result envelope into `done`. Independent inspection confirmed the terminal-scoped runtime cache, worktree-scoped PM handoff, explicit overrides, and matching Bash/OpenCode canonical-worktree fallback; no failed-model conclusion was accepted.
- Claude, Codex, and OpenCode live presentation are qualified on this Ubuntu/Orca host at the named versions. Hermes is not installed here and its deployed runtime adapter contract remains unqualified.
