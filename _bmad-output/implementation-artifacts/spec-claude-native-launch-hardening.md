---
title: 'Claude native launch hardening and offline evidence qualification'
type: 'feature'
created: '2026-09-13'
status: 'done'
route: 'dispatch'
review_loop_iteration: 0
baseline_commit: '32e94cc5e0b1c6991aabe1942c4f701b7e9c526e'
context:
  - '_bmad-output/planning-artifacts/epics.md'
  - 'docs/LIFECYCLE-CONTRACT.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** AFK's Claude launch sanitizer controls ambient environment state, but file-backed Claude settings can still be malformed or declare behavior-changing fallback, provider, context, compaction, or output controls. AFK also lacks a deterministic way to qualify a completed Claude JSON envelope against caller-declared provider/model/window expectations without making another provider call.

**Approach:** Fail closed before terminal creation when Claude settings are unreadable, malformed, or contain effective redirect/substitution controls, including a file-borne fallback declaration. Keep the frozen Claude child environment unchanged. Add a standalone offline verifier that validates supplied result metadata against explicit caller-owned expectations and reports bounded facts without consulting credentials, the network, a harness, ACP, or deployment state.

## Boundaries & Constraints

**Always:** Preserve the stamped route, catalog model selection, existing native-versus-gateway launch-class guard, exact frozen native `env -i HOME/PATH/USER/LANG/TERM` allowlist, approved HOME/PATH, prompt-as-data channel, permission/tool/MCP restrictions, and secret-free artifacts. Scan every supported settings layer before terminal creation, reject invalid JSON, and reject settings capable of changing fallback/model resolution, provider/auth routing, context/compaction, or output limits. Permit inert user defaults such as top-level `model` and `effortLevel` only when explicit validated CLI arguments remain conclusive and regression-tested. The verifier must enumerate every `modelUsage` entry, use exact keys or an explicit alias-to-resolved binding, require the primary exactly once, accept only explicitly allowed auxiliary models, require the declared provider and positive numeric context window for every accepted entry, compare windows with a caller-supplied task requirement plus separately supplied headroom, ignore cost, and produce deterministic versioned JSON with stable reason codes. Provider liveness, quota/exhaustion, subscription identity, and paid extra-usage state must be `NOT_EVALUATED`.

**Never:** Let product tests or qualification/evidence collection launch Claude or any other model; perform negative-auth, credential, network, ACP, or prox-ops probes; read/copy/export credentials; infer the primary model from ordering, token volume, model family, cost, or a lone entry; classify an observed Haiku entry as auxiliary without caller declaration; derive headroom or context guarantees; turn result-envelope observations into route/catalog authority; add runtime fallback or rerouting; widen tools, permissions, MCP, shell inheritance, or credential exposure; alter ACP or prox-ops files; install, publish, deploy, or activate anything. A separately router-authorized development or review worker may edit/review AFK under the normal BMAD process, but that worker is implementation labor, not qualification evidence, and must not exercise the changed Claude launch path.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|---------------|----------------------------|----------------|
| Compatible launch construction | Valid supported settings plus explicit model/effort | Existing native and gateway command recipes remain unchanged | No provider process is started by tests |
| Unsafe settings | Malformed/unreadable JSON or an effective redirect/substitution key in any supported layer | Refusal occurs before terminal creation | Existing configuration-error exit contract and actionable file/key detail |
| Qualified envelope | Exact or explicitly bound primary, declared provider, allowed auxiliaries, adequate positive windows | Versioned JSON verdict `QUALIFIED`; external billing/auth facts remain `NOT_EVALUATED` | Cost fields do not affect the verdict |
| Ambiguous model evidence | Missing/duplicate primary, unresolved alias, or undeclared extra model | Versioned JSON verdict `REFUSED` | Stable specific reason code; never guess |
| Invalid provider/window evidence | Missing/wrong provider, malformed `modelUsage`, nonnumeric/nonpositive window, or window below the explicit floor | Versioned JSON verdict `REFUSED` | Stable specific reason code and bounded observed/expected fields |

## Compatibility Disposition

The exact candidate fallback control is `CLAUDE_CODE_NO_MODEL_FALLBACK=1`. Claude Code 2.1.268's installed executable recognizes that name and emits a refusal stating that model substitution is disabled. It does not appear in that version's `--help` output or Anthropic's current public environment-variable reference; the public CLI documents `--fallback-model` as an opt-in but exposes no supported negative counterpart. The executable is current-version implementation evidence, not an authoritative stable interface.

Adding this variable would violate the ACP-frozen native recipe's positive requirement that zero `ANTHROPIC_*` or `CLAUDE_*` variables enter the child. It is therefore a new launch-contract variant, not conforming preflight hardening. This spec does not add, activate, or claim qualification for it. AFK may use it only after explicit ACP PM acceptance and a coordinated contract version/amendment; that future decision is outside this checkpoint. Malformed-settings refusal and detection of file-borne `fallbackModel` remain conforming preflight changes because they run before terminal creation and do not alter the child recipe.

</frozen-after-approval>

## Code Map

- `files/model-router/scripts/dispatch.sh` -- Claude command builders and settings preflight executed before terminal creation.
- `files/model-router/scripts/verify-claude-evidence.sh` -- new offline, side-effect-free envelope qualification entry point.
- `tests/run-tests.sh` -- aggregate launcher regression suite and test entry point.
- `tests/claude-evidence-tests.sh` -- focused offline verifier contract gate invoked by the aggregate suite.
- `tests/fixtures/` -- secret-free Claude envelope and verifier-expectation fixtures.
- `docs/LIFECYCLE-CONTRACT.md` -- public evidence semantics, limits, and reason-code contract.

## Tasks & Acceptance

**Execution:**
- [x] `files/model-router/scripts/dispatch.sh` -- make settings parsing and file-borne redirect/substitution detection fail closed before terminal creation while leaving both frozen Claude command builders unchanged.
- [x] `files/model-router/scripts/verify-claude-evidence.sh` -- implement deterministic offline qualification from a result file and explicit expectations file.
- [x] `tests/run-tests.sh`, `tests/claude-evidence-tests.sh`, `tests/fixtures/` -- cover exact sanitized command state, supported inert defaults, every settings layer/refusal class, verifier happy paths, and anti-vacuity failures.
- [x] `docs/LIFECYCLE-CONTRACT.md` -- document verifier inputs, outputs, authority limits, and `NOT_EVALUATED` fields.

**Acceptance Criteria:**
- Given either Claude launch class, when its command is constructed, then its existing environment allowlist and all launch restrictions remain unchanged; no candidate fallback variable is present.
- Given any supported settings layer that cannot be safely parsed or contains an effective redirect/substitution control, when dispatch preflight runs, then no terminal/result artifact is created and the refusal names the responsible file or key.
- Given only local fixture files, when the verifier runs, then it makes no external access, returns deterministic machine JSON, and distinguishes qualified, ambiguous, malformed, provider-mismatched, unexpected-model, and insufficient-window evidence.
- Given any verifier outcome, then subscription liveness, quota/exhaustion, and paid extra usage are never claimed as established facts.

## Implementation Notes

- Josh authorized this PM session to finish the preserved AFK draft as a one-task direct-completion exception. The natural route stamp was catalog-valid but not dispatchable by AFK's validated adapters; the attempted override stamp was policy-invalid. Neither stamp was dispatched, and no development worker or model process was started.
- Claude's native and gateway command builders remain byte-identical to their prior recipes. `CLAUDE_CODE_NO_MODEL_FALLBACK` was not added; the launch-contract variant remains deferred to ACP-owned compatibility work.
- Settings preflight now fails closed on unreadable, malformed, non-object, or behavior-changing settings across user, project, local, and managed layers before terminal creation.
- The verifier is local-file-only and reports billing, subscription, quota, exhaustion, and paid extra usage as `NOT_EVALUATED`. Max extra usage remains unverified.
- Final offline gates: verifier `147 passed, 0 failed`; aggregate `839 passed, 0 failed` (lifecycle 478, mutation 577, concurrency 207, readiness 290, dispatch 256). The opt-in live control-plane chain was skipped.

## Spec Change Log

- 2026-09-13: Josh authorized recording `tests/claude-evidence-tests.sh` in the non-frozen code map and completing the preserved draft directly under the bounded offline scope.

## Review Triage Log

| ID | Verdict / route | Evidence |
|----|-----------------|----------|
| BH-1 | medium / patch | `claude_settings_preflight` runs before `result_file` assignment and removal, so a settings refusal leaves `${STORY}.claude-result.json` from a prior cycle. |
| BH-2 | false / reject | The verifier qualifies bounded provider/model/window observations, not task success; neither the frozen intent nor documented verdict claims the worker result succeeded. |
| BH-3 | medium / patch | `jq -e .` labels valid JSON `false` and `null` as invalid JSON, violating the stable structural-refusal contract. |
| BH-4 | medium / patch | `jq` accepts a stream and the evaluator uses only element zero, so more than one top-level JSON value is not refused. |
| BH-5 | false / reject | Qualification operates on parsed JSON object entries; duplicate textual member names do not survive as multiple entries. The representable duplicate identity case—bound alias plus resolved key—is explicitly refused and tested. |
| BH-6 | medium / patch | Without a binding, the contract treats `primary_model` as the exact key; absence must be `PRIMARY_MODEL_MISSING`, not an inferred alias/binding diagnosis. |
| BH-7 | medium / patch | A valid non-object result reaches object field access and collapses to `RESULT_EVALUATION_FAILED` instead of the promised malformed-evidence reason. |
| BH-8 | low / reject | jq's unsafe-integer range can round unrealistic token declarations, but callers own both expectations and the fix adds guards for a state not met in ordinary use. |
| BH-9 | low / reject | A FIFO at a fixed settings path is skipped by `-f` and might later block Claude, but this hostile filesystem state is not an everyday case and the fix adds a new guard. |
| BH-10 | low / reject | Concurrent replacement between settings checks and launch is theoretically real, but requires a narrow same-account race and an immutable-launch snapshot would add substantial complexity. |
| BH-11 | maybe-false / defer | AFK supports macOS, but the checkout does not establish that this Claude version consumes the asserted macOS managed-settings path; authoritative current path evidence would settle it. |
| BH-12 | medium / patch | `chmod 000` remains readable to root, so the unreadable-settings assertion fails in privileged CI instead of proving the refusal; the test must detect that prerequisite and report a bounded skip. |
| EC-1 | medium / patch | Multiple top-level settings objects can pass the last-value jq status even though the path is not one valid settings document. |
| EC-2 | low / reject | Replacement between the two settings jq calls can expose a raw jq exit, but requires a narrow concurrent mutation and snapshotting adds complexity disproportionate to ordinary use. |
| EC-3 | low / reject | Replacement after preflight can change what Claude reads, but the same-account timing race is unlikely and no compatible immutable-settings launch mechanism is established. |
| EC-4 | medium / patch | The actual call order confirms settings refusal precedes stale Claude-result removal. |
| EC-5 | medium / patch | The verifier accepts readable FIFOs and devices, so a caller can block it indefinitely despite the interface requiring input files. |
| EC-6 | low / reject | Input replacement between validation and evaluation is possible, but the caller already owns both local files and exploiting the narrow race adds no authority; snapshotting is more than a direct correction. |
| EC-7 | medium / patch | Multi-document verifier inputs are accepted and only the first value is evaluated. |
| EC-8 | false / reject | A `QUALIFIED` verdict is explicitly evidence qualification, not a claim that the task result succeeded; `is_error` is outside the declared facts. |
| EC-9 | medium / patch | Non-object result roots produce a generic evaluation failure rather than `MODEL_USAGE_MALFORMED`. |
| EC-10 | false / reject | Textual duplicate names are one parsed object member, while two representable primary identities are already counted and refused. |
| EC-11 | low / reject | Values beyond jq's exact numeric range are unrealistic caller-owned token declarations; the risk is negligible and additional range guards are not justified for everyday use. |
| EC-12 | medium / patch | The no-binding missing-primary path is confirmed to emit the alias-oriented reason even though the public contract treats the declared value as exact. |
| EC-13 | medium / patch | `[.external_facts[] == "NOT_EVALUATED"] | all` is true for an empty object, so deleting every required fact would leave the gate green. |
| EC-14 | medium / patch | The unreadable-settings test has no privilege prerequisite; under root, `chmod 000` does not make the file unreadable and the expected refusal is not reached. |
| VG-1 | medium / patch | Pre-verified: helper tests pass a synthetic home directly, while the real dispatch test only exercises project settings; a wrong approved-home caller path would escape the gate. |
| VG-2 | medium / patch | Pre-verified: no test asserts `schema_version`, `kind`, or representative evidence counts, so an incompatible machine envelope can pass all current tests. |
| VG-3 | medium / patch | Pre-verified: zero, negative, fractional, missing, and nonnumeric expectation-token constraints have no refusal coverage. |
| VG-4 | medium / patch | Pre-verified: provider-negative tests mutate only the auxiliary entry, leaving primary-provider validation unguarded. |
| VG-5 | medium / patch | Pre-verified: context-window negative tests mutate only the primary entry, leaving allowed-auxiliary validation unguarded. |
| VG-6 | medium / patch | The additional finding is confirmed: the settings integration test checks the thin result name and never seeds the stale Claude-result filename. |

## Design Notes

Settings preflight is preventative authority; the offline verifier is historical corroboration. They deliberately remain separate. A caller may supply an exact primary key or an explicit alias binding, but the verifier must not manufacture that binding from Claude output. The context floor is arithmetic over two explicit caller inputs, while the catalog remains the only routing authority for a profile's promised window.

## Verification

**Commands:**
- `bash tests/run-tests.sh` -- all launcher and verifier cases pass with non-vacuous assertions.
- `shellcheck files/model-router/scripts/dispatch.sh files/model-router/scripts/verify-claude-evidence.sh` -- no findings.
- `git diff --check` -- no whitespace errors.
