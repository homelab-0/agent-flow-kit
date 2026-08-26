# PR #5 implementation-evidence reconciliation

Evaluated snapshot: `refs/remotes/origin/pr-5-readonly` at `5ce5f8431595df4349c70d9f93f29054360e72a5` (the supplied SHA text differs, but this is the resolved read-only ref). Baseline authority is, in order: frozen PRD rulings; architecture invariants/owner boundaries; proven EPIC-035 behavior; existing kit; this PR. Classifications describe mechanisms, not requirement changes.

## Counts

| Class | Count |
|---|---:|
| REUSE | 9 |
| ADAPT | 11 |
| CONFLICT | 6 |
| GAP | 12 |
| OUT_OF_SCOPE | 2 |

## REUSE

1. **Single lifecycle entrypoint and coherent verb set.** `status`, `adopt`, `update`, and `verify` are exposed through one executable, with Git pull explicitly external (`bin/agent-flow-kit:27-40`, `bin/agent-flow-kit:89-96`). This cleanly supports FR-22 and FR-34 as a command spine.

2. **Explicit artifact ownership mechanisms.** The state distinguishes managed copies, managed sections, links, machine-local configuration, and target wiring (`lib/legacy.sh:114-124`). This is a sound starting representation for FR-2 through FR-4.

3. **Deterministic managed-section extraction.** Marker cardinality is checked and payload hashing is deterministic (`lib/core.sh:52-63`, `lib/core.sh:142-147`). The mechanism supports FR-9 and FR-38 without free-form merging.

4. **Preservation of content outside managed sections.** Replacement rewrites the bounded section and retains surrounding lines (`lib/core.sh:65-96`); tests independently retain Claude and Codex user notes (`tests/lifecycle-tests.sh:106-127`). This satisfies the core FR-37 preservation behavior.

5. **Machine-local configuration survives managed-tree replacement.** `subscriptions.yaml` is excluded from canonical tree hashing and copied into the staged tree (`lib/core.sh:135-141`, `lib/legacy.sh:67-79`); tests prove a local override survives (`tests/lifecycle-tests.sh:106-127`). This is reusable for ownership-class adaptation under FR-7.

6. **Exact historical-content adoption.** Legacy trees and policy payloads are compared to reachable Git history rather than judged heuristically (`lib/legacy.sh:1-35`, `lib/legacy.sh:50-64`). The legacy fixture proves known canonical content can be adopted and unknown edits refused (`tests/lifecycle-tests.sh:139-162`). This cleanly implements part of FR-10 and FR-11.

7. **Whole-set drift preflight before ordinary update writes.** All currently known managed artifacts and links are checked before `apply_update` is called (`lib/install.sh:86-108`, `bin/agent-flow-kit:65`). A drift fixture proves refusal leaves the edited file and applied revision unchanged (`tests/lifecycle-tests.sh:129-137`). This is useful toward FR-23, FR-26, and FR-40.

8. **Stable no-op on an unchanged revision.** `apply_update` writes nothing when source hashes, revision, and target registration are unchanged (`lib/install.sh:111-126`); the HOME fingerprint test proves no churn (`tests/lifecycle-tests.sh:97-104`). This cleanly supports FR-46.

9. **Validator boundary avoids a prox-ops source checkout.** Configuration resolves an installed validator executable and trusted catalog path (`lib/status.sh:57-69`), while the contract explicitly rejects cloning/building prox-ops (`docs/FLEET-LIFECYCLE.md:205-219`). This respects the external client/validator boundary in FR-67 and the architecture supplement.

## ADAPT

1. **Manifest schema is a useful seed but incomplete.** It records schema version, applied SHA, component hashes, local config, and targets (`lib/legacy.sh:97-125`), but lacks installed component version/contract detail, registered exceptions, migration metadata, operation history, and explicit ownership for all inventory required by FR-1 through FR-8 and FR-33.

2. **Source eligibility is only partially proven.** The implementation checks Git-worktree presence and tracked dirt (`lib/install.sh:1-9`, `lib/core.sh:132-138`) but does not verify repository origin/identity, default/canonical branch intent, untracked managed inputs, lifecycle compatibility, or a pinned source input set. Adapt for FR-29 through FR-33 and FR-35.

3. **Forward-descendant enforcement lacks explicit noncanonical and rollback modes.** A non-descendant is always refused (`lib/install.sh:90-95`), while the PRD permits explicit selected test revisions and compatible rollback intent. Retain the safe default, add the frozen explicit-intent paths from FR-31 and FR-32.

4. **Adoption is binary rather than three-tier.** `preflight_adopt` either accepts exact recognizable content or returns failure (`lib/install.sh:11-51`); it has no normalized AUTO-ADOPT / APPROVAL-REQUIRED / REFUSE plan or approval scoped to a plan. Adapt for FR-12 through FR-14 and FR-25.

5. **Update staging is component-local, not operation-transactional.** Trees use stage/backup/rename (`lib/legacy.sh:67-79`) and files use temp/rename (`lib/core.sh:65-96`), but earlier successful component swaps remain if a later component fails. Adapt into the complete journal, rollback, final verification, and commit-point contract in FR-40 through FR-45.

6. **Manifest rename is atomic only at the final file level.** `write_state` uses temp plus rename (`lib/legacy.sh:97-125`), but `apply_update` does not verify the complete installed result before that write (`lib/install.sh:111-126`). Adapt so final verification succeeds before applied revision advances under FR-43 and FR-44.

7. **Target wiring probe is a narrow structural prototype.** It checks one of two template paths, four frontmatter keys, retired `route:`, and DEV persona presence (`lib/legacy.sh:137-152`). It must become a versioned BMAD/kit wiring contract with persona/template resolution and ownership integrity for FR-51, FR-56, and FR-69.

8. **Validator compatibility probe is superficial.** It only searches `--help` output for two options (`lib/status.sh:64-69`). Retain executable discovery, but add machine contract identity plus valid, tampered, expired, incompatible, catalog, and provenance fixtures required by FR-58 and FR-67.

9. **Harness probes stop at binary presence.** Both configured binaries are checked with `command -v` (`lib/status.sh:70-73`). Adapt to native auth status, invocation/model/effort/permission capability, redirect detection, and route-specific availability under FR-54 and FR-60 through FR-63.

10. **Orca probe stops at executable presence.** `orca` is included in a generic command loop (`lib/status.sh:53`). Adapt to capability/version, visible-worker fields, environment transport, and isolation contracts under FR-55 and FR-68 without assuming Orca process ownership.

11. **Fixture suite establishes useful mechanics but not the frozen safety matrix.** It covers clean adoption, no-op, preservation, drift refusal, legacy proof, missing validator, and bad target (`tests/lifecycle-tests.sh:89-191`). Extend the test approach for managed-section drift, approval plans, journal interruption, injected mid-operation rollback, schema migration, secret-safe JSON, and the complete AC-28 fixture progression.

## CONFLICT

1. **Read-only status can mutate Git state.** `status --fetch` executes `git fetch` (`lib/status.sh:7-9`; documented at `docs/FLEET-LIFECYCLE.md:21-24`). This directly conflicts with FR-24 and FR-34, which prohibit status/lifecycle from fetching or selecting Git state.

2. **Verify defaults live instead of offline.** The CLI defines `verify --offline`, and absent that flag performs router I/O (`bin/agent-flow-kit:32-38`, `lib/status.sh:80-83`). FR-83 through FR-86 require ordinary status/verify to default offline and external probes to require explicit live mode.

3. **Both Claude and Codex are globally mandatory.** Missing either binary sets the single verification failure (`lib/status.sh:70-73`). This conflicts with FR-47, FR-48, and FR-52: harnesses are individually optional, host execution may remain ready through one complete approved path, and route readiness is harness-specific.

4. **Router outage is classified as BROKEN installation.** Any non-200 or timeout emits `BROKEN` and fails the undifferentiated verify (`lib/status.sh:80-85`). This conflicts with FR-50 and FR-86: router availability narrows `NEW_WORK_READY`; transient live unavailability must not corrupt installation integrity.

5. **Dirty checkout makes verification fail globally.** `cmd_verify` treats checkout dirt as `LOCAL_DRIFT` and failure (`bin/agent-flow-kit:66-73`), and `verify_installation` also demands applied SHA equal current checkout (`lib/status.sh:48-53`). This conflicts with FR-35 and NFR-12, which separate installed execution readiness from source eligibility.

6. **Blanket native-environment rejection overrides scoped execution semantics.** Any `ANTHROPIC_API_KEY` or `CLAUDE_CONFIG_DIR` presence marks the single host verification `BROKEN` (`lib/status.sh:78-79`), even when Codex is the only selected/healthy path or Orca intentionally supplies a native session environment. This conflicts with Orca's environment/auth ownership and FR-47, FR-52, FR-62, and FR-63; spend-safety must block the affected approved path based on actual auth/funding selection, not collapse credential shape into global authority.

## GAP

1. **No documented versioned machine-readable result contract.** Output is prose lines and `--json` does not exist (`bin/agent-flow-kit:27-41`, `lib/status.sh:1-45`). FR-72 through FR-82 require normalized JSON, stable states/reasons/scopes, evidence provenance, redaction rules, and coarse exit semantics.

2. **No registered-adaptation record or lifecycle.** The manifest supports only an ownership-class local file (`lib/legacy.sh:114-124`); there is no explicit exception with expected shape/hash and update disposition required by FR-8 and FR-38.

3. **No deterministic owner-approval plan.** Ambiguous adoption only prints errors (`lib/install.sh:26-43`) and cannot retain/show the complete proposed ownership, modifications, preservation, recovery, resulting state, or plan-scoped authority required by FR-12, FR-13, and FR-23.

4. **No operation journal, interruption detection, or whole-operation rollback.** There is no operation ID or durable pre-mutation record in `apply_adopt`, `apply_update`, or state handling (`lib/install.sh:54-126`, `lib/legacy.sh:97-125`). FR-41, FR-42, FR-45, AC-12, and AC-28 are absent.

5. **No concurrency or stale-plan guard.** Preflight hashes and subsequent writes are separate, unlocked phases (`lib/install.sh:86-126`). A concurrent lifecycle/user mutation can invalidate the plan without detection, contrary to the frozen complete deterministic plan and safe convergence contract.

6. **No scoped readiness model.** There are no independent `HOST_EXECUTION_READY`, `NEW_WORK_READY`, `TARGET_READY`, or `ROUTE_READY` results; one `bad` flag governs verification (`lib/status.sh:48-85`). FR-47 through FR-53 are not represented.

7. **No actual native subscription-auth proof for Claude or Codex.** Only binary presence and two Claude-related environment variables are checked (`lib/status.sh:70-79`). Expired sessions, Codex auth mode, provider redirects, route funding preservation, and no-metered-fallback proof from FR-60 through FR-63 are absent.

8. **No orchestration-state visibility bridge.** Lifecycle output does not consume normalized `PLAN` / `ORCH` / `WORKER`, phase, task, or `NEEDS HUMAN` state (`lib/status.sh:1-85`). FR-88 through FR-90 are absent; documentation merely restates invariants (`docs/FLEET-LIFECYCLE.md:221-237`).

9. **No live probe result semantics.** Router curl has no normalized timeout/transience/observed-at metadata, and other live probes are missing (`lib/status.sh:80-83`). FR-84 through FR-87 require explicit `NOT_EVALUATED`, `UNAVAILABLE`, timestamps, bounded scope, and no durable persistence.

10. **No real-host Git-channel acceptance evidence.** Tests operate entirely in temporary local repositories/HOMEs (`tests/lifecycle-tests.sh:4-6`, `tests/lifecycle-tests.sh:63-68`). AC-1 through AC-17 require two observed remote Orca hosts, a real PR/merge/pull/update channel, retained baseline/plans/results, preservation, idempotence, and real drift restoration evidence.

11. **No production orchestration smoke after lifecycle convergence.** Neither lifecycle tests nor CI execute PM → route → stamp → validator → Orca-visible worker → deterministic gate → PM (`tests/lifecycle-tests.sh:89-194`, `.github/workflows/tests.yml:37-44`). AC-18 through AC-27 are absent, including persona/harness/profile/funding/visibility evidence and cleanup.

12. **No final evidence bundle or verdict contract.** The PR adds no retained machine-readable acceptance index and cannot produce the AC-31 `AGENT-FLOW-KIT PORTABILITY GREEN/BLOCKED` evidence-backed verdict. Terminal test output is the only lifecycle evidence (`tests/lifecycle-tests.sh:193-194`).

## OUT_OF_SCOPE

1. **Lifecycle-owned remote-ref refresh.** The optional `--fetch` capability (`lib/status.sh:7-9`) is not merely unnecessary; Git synchronization remains operator/agent policy outside this increment. Remove from the increment rather than expanding it.

2. **Broad macOS qualification signal.** CI adds an Ubuntu/macOS matrix (`.github/workflows/tests.yml:12-44`). Cross-platform fixture execution is harmless engineering evidence, but formal broad OS certification is explicitly not an acceptance requirement; it must not substitute for the two real observed Orca hosts.

## Reconciliation conclusion

PR #5 is valuable evidence for deterministic hashing, ownership-class separation, exact historical adoption, bounded managed-section replacement, local-config preservation, drift refusal, and idempotence. It is not an acceptable requirements source and is not implementation-complete against the frozen PRD. The largest mismatches are its single undifferentiated readiness flag, prose-only output, live-by-default verify, Git-mutating status, both-harness requirement, weak compatibility probes, and absence of an operation journal/rollback and real-host acceptance evidence. The architecture ownership split is mostly respected in the distribution mechanics, but native environment/auth checks and readiness aggregation need correction so the kit validates executor capability without taking Orca or router authority.
