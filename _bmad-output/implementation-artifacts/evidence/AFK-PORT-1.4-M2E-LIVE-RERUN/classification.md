# AFK-PORT-1.4-M2E live classification

Source surfaces: `status --live --json`, `verify --live --json`, and rendered `status --live`, run from canonical checkout revision `fbc0923a2513beee5527afde57cd69c5600a735a`. Both JSON surfaces returned the same classifications and exit code `5`; stderr was empty for all three invocations.

## Required scopes and live grounding

- Installation integrity — verbatim rendered quote: `INSTALLED_INTEGRITY: READY  evaluated=true  reason=-`. JSON verbatim values: `"state": "READY"`, `"evidence_provenance": "HASH_COMPARISON"`. The rendered installation state is also `installed state   : CURRENT`.
- HOST_EXECUTION_READY — verbatim rendered quote: `HOST_EXECUTION_READY: FALSE  evaluated=true  reason=ORCA_CAPABILITY_UNPROVEN`. The attached reason is consistent with the same result's live facts: `orca_runtime: AVAILABLE (ORCA_RUNTIME_REACHABLE)` but `orca_capability: UNKNOWN (ORCA_CAPABILITY_UNPROVEN)`. The validator is an additional independently blocking live fact: `validator_fixtures: UNAVAILABLE (VALIDATOR_VERDICT_UNAVAILABLE)` with detail `no verdict on the known-valid fixture`.
- NEW_WORK_READY — verbatim rendered quote: `NEW_WORK_READY: FALSE  evaluated=true  reason=ORCA_CAPABILITY_UNPROVEN`. The attached reason is consistent with the same result's live facts: the router is available (`router_status: AVAILABLE (ROUTER_AVAILABLE)`, detail `HTTP 200`) and its catalog is compatible, but `orca_capability: UNKNOWN (ORCA_CAPABILITY_UNPROVEN)` prevents supervised worker launch capability from being proven.
- TARGET_READY / target arity — verbatim rendered quotes: `registered BMAD targets` / `(none registered)` and `TARGET_READY: NOT_EVALUATED  evaluated=false  reason=NO_TARGET_REGISTERED`. JSON confirms `"targets": []`. This is grounded non-evaluation, not FALSE.
- Validator readiness — verbatim live facts: `validator_executable: PRESENT (EXECUTABLE_RESOLVED)`, `validator_contract: UNKNOWN (VALIDATOR_CONTRACT_UNREADABLE)`, and `validator_fixtures: UNAVAILABLE (VALIDATOR_VERDICT_UNAVAILABLE)`. The last fact is transient and says `no verdict on the known-valid fixture`; it grounds the validator's HOST_EXECUTION_READY block.
- Harness readiness — verbatim live facts: `claude_capability: INCOMPATIBLE (HARNESS_CAPABILITY_UNPROVEN)` with detail `--model --permission-mode --append-system-prompt-file --strict-mcp-config`; `codex_capability: COMPATIBLE (HARNESS_CAPABILITY_PROVEN)`; and `claude_native_session: NOT_EVALUATED (HARNESS_CAPABILITY_UNPROVEN)`.
- Funding/auth (MODE words) — the no-stamp surface emits no funding mode and therefore makes no funding claim. Its auth classification is verbatim `codex_native_session: UNKNOWN (AUTH_STATUS_UNPROVEN)`; the finding says `The harness auth status could not be classified through a safe native mechanism.` This is consistent with a no-stamp, non-launch-authoritative result and is not promoted to a funded/authenticated mode.
- ROUTE_READY — verbatim rendered quotes: `ROUTE_READY: OUT_OF_SCOPE  evaluated=false  reason=NO_EXECUTION_STAMP_SUPPLIED` and `ROUTE_READY execution_stamp: - (placement_selected=false, launch_authoritative=false)`. Remaining route facts are verbatim `route_placement: NOT_EVALUATED (LIVE_PROBE_NOT_REQUESTED)` and `route_authority: NOT_EVALUATED (LIVE_PROBE_NOT_REQUESTED)`. This is the required no-stamp posture.

Every FALSE scope has a reason consistent with live facts in the same result. The two JSON runs differ only in observation timestamps, not classifications or grounding.

LIVE: READY_WITH_WARNINGS — REASONS-GROUNDED: yes — AMBIGUITY: none
