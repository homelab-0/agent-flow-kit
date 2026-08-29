# Story 1.4 evidence bundle index

Generated at M5 assembly (2026-08-29). Machine-readable inventory: every directory below is one evidence set; per-set contents listed with sizes. The Mac leg bundle lives on git branch `evidence/afk-port-1.4-mac` (through `262585d`), indexed at the bottom.

## AFK-PORT-1.4-FLEET-DISCOVERY
Read-only fleet discovery: insufficient-visibility report that led to the host-pair ruling (AC-3 input)

- `PAIR-PROPOSAL.md` (3394 B)
- `candidates.json` (3894 B)

## AFK-PORT-1.4-M0-DISPATCH
M0 composed-dispatch receipts + the lost-worker_done incident chain and resolution (registered conditions 1 and 2 supporting evidence)

- `dispatch-show.discovery.json` (1157 B)
- `dispatch-show.gates.json` (1157 B)
- `incident-lost-worker-done.RESOLUTION.md` (1661 B)
- `incident-lost-worker-done.discovery-transcript.json` (40145 B)
- `incident-lost-worker-done.dispatch-show.json` (1157 B)
- `incident-lost-worker-done.mailbox-peek.json` (12650 B)
- `worker-show.discovery.json` (6163 B)
- `worker-show.gates.json` (6168 B)

## AFK-PORT-1.4-M0-GATES
M0 prerequisite gate sweep — all seven suites green (AC-1)

- `concurrency.log` (14614 B)
- `dispatch.log` (14687 B)
- `gate-status.tsv` (116 B)
- `git-diff-check.log` (0 B)
- `lifecycle.log` (28142 B)
- `mutation.log` (36221 B)
- `persona-proof.txt` (65 B)
- `readiness.log` (15260 B)
- `run-tests.log` (14915 B)
- `summary.json` (1808 B)

## AFK-PORT-1.4-M1-DISPATCH
(receipts)

- `dispatch-show.json` (1157 B)
- `worker-start-receipt.json` (1607 B)

## AFK-PORT-1.4-M1-PRIMARY-BASELINE
Primary host baseline + representativeness + pre-mutation lifecycle inspection (AC-4, AC-5)

- `adopt-inspect.exit-status` (2 B)
- `adopt-inspect.json` (13648 B)
- `adopt-inspect.stderr` (0 B)
- `baseline.json` (5430 B)
- `classification.md` (3168 B)
- `representativeness.md` (2172 B)
- `status.exit-status` (2 B)
- `status.json` (13052 B)
- `status.stderr` (0 B)
- `verify.exit-status` (2 B)
- `verify.json` (14439 B)
- `verify.stderr` (0 B)

## AFK-PORT-1.4-M2-GIT-CHANNEL
Operator git actions: stale repositioning, refused-then-completed pull with byte-identical collision proof, fix-delivery pulls (AC-6)

- `operator-git-after.txt` (436 B)
- `operator-git-before.txt` (771 B)
- `operator-git-log.md` (1495 B)
- `operator-git-pull.txt` (18257 B)
- `untracked-collision-backup/` (4 files)
- `untracked-collision-hashes.txt` (899 B)

## AFK-PORT-1.4-M2A-ADOPT
Adoption transaction at the stale revision: plan, approval, preservation, verification (AC-6/7)

- `adopt-execute.exit-status` (2 B)
- `adopt-execute.json` (28980 B)
- `adopt-execute.stderr` (0 B)
- `adopt-inspect.exit-status` (2 B)
- `adopt-inspect.json` (14099 B)
- `adopt-inspect.stderr` (0 B)
- `adopt-plan.exit-status` (2 B)
- `adopt-plan.json` (23963 B)
- `adopt-plan.stderr` (0 B)
- `approval.txt` (368 B)
- `classification.md` (1125 B)
- `preservation-after.exit-status` (2 B)
- `preservation-after.stderr` (0 B)
- `preservation-after.txt` (1154 B)
- `preservation-before.exit-status` (2 B)
- `preservation-before.stderr` (0 B)
- `preservation-before.txt` (1154 B)
- `preservation-compare.exit-status` (2 B)
- `status-post.exit-status` (2 B)
- `status-post.json` (13501 B)
- `status-post.stderr` (0 B)
- `status-pre.exit-status` (2 B)
- `status-pre.json` (12160 B)
- `status-pre.stderr` (0 B)
- `verify-branch.exit-status` (2 B)
- `verify-branch.stderr` (0 B)
- `verify-branch.stdout` (7 B)
- `verify-head.exit-status` (2 B)
- `verify-head.stderr` (0 B)
- `verify-head.stdout` (41 B)
- `verify-post.exit-status` (2 B)
- `verify-post.json` (17282 B)
- `verify-post.stderr` (0 B)
- `worker-done.exit-status` (2 B)
- `worker-done.json` (1754 B)
- `worker-done.stderr` (0 B)

## AFK-PORT-1.4-M2A-ADOPT-DISPATCH
M2A dispatch receipts

- `dispatch-show.json` (1157 B)
- `worker-start-receipt.json` (1607 B)

## AFK-PORT-1.4-M2B-UPDATE
Update-channel proof: UPDATE_AVAILABLE, convergence with preservation, idempotence hash-proof, drift canary refuse/restore (AC-6..11)

- `approval.txt` (393 B)
- `canary-after-refusal.exit-status` (2 B)
- `canary-after-refusal.sha256` (113 B)
- `canary-after-refusal.stderr` (0 B)
- `canary-backup/` (1 files)
- `canary-backup-sha.exit-status` (2 B)
- `canary-backup-sha.stderr` (0 B)
- `canary-backup.exit-status` (2 B)
- `canary-backup.sha256` (273 B)
- `canary-backup.stderr` (0 B)
- `canary-modified.exit-status` (2 B)
- `canary-modified.sha256` (113 B)
- `canary-modified.stderr` (0 B)
- `canary-restore-copy.exit-status` (2 B)
- `canary-restore.exit-status` (2 B)
- `canary-restore.stderr` (0 B)
- `canary-restore.txt` (284 B)
- `canary-selection.md` (497 B)
- `classification.md` (2417 B)
- `drift-refusal.exit-status` (2 B)
- `drift-refusal.json` (31660 B)
- `drift-refusal.stderr` (0 B)
- `drift-status.exit-status` (2 B)
- `drift-status.json` (18878 B)
- `drift-status.stderr` (0 B)
- `idempotence-execute.exit-status` (2 B)
- `idempotence-execute.json` (30623 B)
- `idempotence-execute.stderr` (0 B)
- `idempotence-hashes.after.txt` (657 B)
- `idempotence-hashes.attempt1.exit-status` (2 B)
- `idempotence-hashes.attempt1.stderr` (0 B)
- `idempotence-hashes.attempt1.txt` (50 B)
- `idempotence-hashes.before.txt` (657 B)
- `idempotence-hashes.exit-status` (2 B)
- `idempotence-hashes.stderr` (0 B)
- `idempotence-hashes.txt` (1332 B)
- `idempotence-plan.exit-status` (2 B)
- `idempotence-plan.json` (30567 B)
- `idempotence-plan.stderr` (0 B)
- `idempotence-status-after.exit-status` (2 B)
- `idempotence-status-after.json` (17826 B)
- `idempotence-status-after.stderr` (0 B)
- `live-verification-human.exit-status` (2 B)
- `live-verification-human.stderr` (0 B)
- `live-verification.exit-status` (2 B)
- `live-verification.json` (23261 B)
- `live-verification.stderr` (0 B)
- `live-verification.txt` (13216 B)
- `post-restore-verify.exit-status` (2 B)
- `post-restore-verify.json` (21766 B)
- `post-restore-verify.stderr` (0 B)
- `preservation-after.exit-status` (2 B)
- `preservation-after.stderr` (0 B)
- `preservation-after.txt` (314 B)
- `preservation-before.attempt1.exit-status` (2 B)
- `preservation-before.attempt1.stderr` (112 B)
- `preservation-before.attempt1.txt` (126 B)
- `preservation-before.exit-status` (2 B)
- `preservation-before.stderr` (0 B)
- `preservation-before.txt` (314 B)
- `preservation-compare.exit-status` (2 B)
- `preservation-compare.stderr` (0 B)
- `preservation-compare.stdout` (0 B)
- `status-post.exit-status` (2 B)
- `status-post.json` (17826 B)
- `status-post.stderr` (0 B)
- `status-pre.exit-status` (2 B)
- `status-pre.json` (19900 B)
- `status-pre.stderr` (0 B)
- `update-execute.exit-status` (2 B)
- `update-execute.json` (34654 B)
- `update-execute.stderr` (0 B)
- `update-plan.exit-status` (2 B)
- `update-plan.json` (32405 B)
- `update-plan.stderr` (0 B)
- `verify-branch.exit-status` (2 B)
- `verify-branch.stderr` (0 B)
- `verify-branch.stdout` (7 B)
- `verify-head.exit-status` (2 B)
- `verify-head.stderr` (0 B)
- `verify-head.stdout` (41 B)
- `verify-post.exit-status` (2 B)
- `verify-post.json` (21766 B)
- `verify-post.stderr` (0 B)
- `worker-done.attempt1.exit-status` (2 B)
- `worker-done.attempt1.json` (0 B)
- `worker-done.attempt1.stderr` (0 B)
- `worker-done.exit-status` (2 B)
- `worker-done.json` (1759 B)
- `worker-done.stderr` (0 B)

## AFK-PORT-1.4-M2B-UPDATE-DISPATCH
M2B dispatch receipts

- `dispatch-show.json` (1157 B)
- `worker-start-receipt.json` (1607 B)

## AFK-PORT-1.4-M2C-LIVE
Live verification exposing the R1/R2 readiness defects + the coordinator router-status capture (fix-cycle motivation)

- `classification.md` (3601 B)
- `host-config.md` (417 B)
- `router-v1-status.coordinator-capture.json` (6973 B)
- `status-live.json` (23438 B)
- `status-live.txt` (13413 B)
- `verify-live.json` (27378 B)

## AFK-PORT-1.4-M2C-LIVE-DISPATCH
M2C dispatch receipts

- `worker-start-receipt.json` (1607 B)

## AFK-PORT-1.4-M2D-UPDATE-RERUN
Honest CURRENT stop — no-vacuous-update evidence (coordinator brief defect classified)

- `classification.md` (1410 B)
- `status-pre.exit-status` (2 B)
- `status-pre.json` (17827 B)
- `status-pre.stderr` (0 B)
- `worker-done.exit-status` (2 B)
- `worker-done.json` (2135 B)
- `worker-done.stderr` (0 B)

## AFK-PORT-1.4-M2E-LIVE-RERUN
Live verification on the fixed surface: REASONS-GROUNDED yes, AMBIGUITY none (M2 closure)

- `classification.md` (3616 B)
- `host-config.md` (197 B)
- `status-live-json.exit` (2 B)
- `status-live-json.stderr` (0 B)
- `status-live-json.stdout` (22564 B)
- `status-live-text.exit` (2 B)
- `status-live-text.stderr` (0 B)
- `status-live-text.stdout` (12913 B)
- `verify-live-json.exit` (2 B)
- `verify-live-json.stderr` (0 B)
- `verify-live-json.stdout` (26504 B)

## AFK-PORT-1.4-M4-SMOKE
The acceptance smoke: routing chain (natural + override + stamps incl. expired/archived), ROUTE_READY evaluations, monitor register/reconcile/replay/corrected-delivery chain, independent gate, cleanup, restart probe terminal lists, all three live status renders, attempt-1 worker evidence

- `SMOKE-CANARY.md.stamp.expired1.json` (1144 B)
- `SMOKE-CANARY.md.stamp.json` (1063 B)
- `SMOKE-CANARY.route-request.json` (708 B)
- `SMOKE-CANARY.route-response.natural.expired1.json` (958 B)
- `SMOKE-CANARY.route-response.natural.json` (958 B)
- `SMOKE-CANARY.route-response.override.expired1.json` (1293 B)
- `SMOKE-CANARY.route-response.override.json` (1131 B)
- `SMOKE-CANARY.stamp.validation-at-mint.json` (1897 B)
- `attempt1-worker-evidence/` (3 files)
- `dispatch-show-at-launch.attempt2.json` (1161 B)
- `dispatch-show-at-launch.json` (1160 B)
- `gate-independent-run.txt` (233 B)
- `monitor-cleanup.json` (27458 B)
- `monitor-reconcile-1.json` (19154 B)
- `monitor-reconcile-1.stderr` (0 B)
- `monitor-reconcile-2.json` (21355 B)
- `monitor-reconcile-2.stderr` (0 B)
- `monitor-reconcile-3-replay.json` (19653 B)
- `monitor-reconcile-4-corrected.json` (20280 B)
- `monitor-register.attempt2.json` (20267 B)
- `monitor-register.json` (19933 B)
- `post-restart-terminal-list.json` (6454 B)
- `pre-restart-terminal-list.json` (41761 B)
- `reconnect-terminal-list.json` (23555 B)
- `residual-validator-fixture-incompatibility.md` (1596 B)
- `route-ready-first-evaluation.json` (24386 B)
- `route-ready-first-evaluation.stderr` (0 B)
- `route-ready-post-fix-evaluation.json` (23532 B)
- `route-ready-post-fix-evaluation.stderr` (0 B)
- `smoke-dispatch-descriptor.attempt2.json` (74 B)
- `smoke-dispatch-descriptor.json` (74 B)
- `status-render-claude-session.txt` (10487 B)
- `status-render-plan-mode-session.txt` (10708 B)
- `target-pristine-check.txt` (169 B)
- `worker-start-receipt.attempt2.json` (1611 B)
- `worker-start-receipt.json` (1610 B)

## AFK-PORT-1.4-M5-TRACEABILITY
M5: the 140-item ultracode traceability sweep, post-hoc stamp validation, target registration/deregistration states

- `smoke-stamp-posthoc-validation.json` (1897 B)
- `state.json.after-target-deregistration` (1547 B)
- `state.json.with-smoke-target` (1660 B)
- `traceability-sweep.json` (130954 B)

## Prior-story evidence (committed)

- `AFK-PORT-1.1*`, `AFK-PORT-1.2*`, `AFK-PORT-1.3*` sets: committed on master by their stories; statuses frozen per traceability.md.

## Mac leg (branch evidence/afk-port-1.4-mac @ 262585d)

- `evidence/AFK-PORT-1.4-MAC-LEG/`: baseline, gate logs (with the macOS signal observations), classification, secret scan, `real-adoption/` (inspect, plan take2, approved execution, preservation, offline+live verification).
- Coordination transcript: GitHub issue #22 (closed by the Mac agent at the handshake).

## Known retention misses (recorded residuals)

- Smoke attempt-2 worker-side artifacts (persona-proof.txt, its render, gate run log) were deleted with the worktree before copying; coordinator-side proofs retained (pre-dispatch persona hash in session record, independent gate rerun, dispatch receipts, worker_done body).
- The attempt-2 launch-moment stamp-validation JSON was not retained; the session record shows the check ran, and a post-hoc validation of the same unexpired stamp is at AFK-PORT-1.4-M5-TRACEABILITY/smoke-stamp-posthoc-validation.json.
- /tmp/claude-1000/state.json.pre-target-backup was lost to the VM restart; the with-target and after-deregistration manifest states are retained in the M5 set.
