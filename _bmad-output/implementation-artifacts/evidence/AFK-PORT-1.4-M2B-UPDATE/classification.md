# AFK-PORT-1.4-M2B-UPDATE classification

## Lane 1 — update-available detection

- Checkout: `master` at `8a7cbc194fd56114d65c7dfd6a42106c807fb46b`.
- Installed state: `UPDATE_AVAILABLE`.
- Machine reason: `CANONICAL_REVISION_AHEAD`.
- Applied revision before update: `bd9d9fb028149b0f381e44de965955230d2b45cd`.

## Lane 2 — update transaction

- Plan disposition: `MUTATION_REQUIRED`; required mutations: `3`; conflicts: `0`.
- Operation result: `CONVERGED`; reason: `VERIFICATION_PASSED`; operation: `op-c61f650b8a4086df`.
- Applied revision after verified commit: `8a7cbc194fd56114d65c7dfd6a42106c807fb46b`.
- Offline verification: `verified: true`; failures: `0`; checks: `11`.
- Preservation comparison: exit `0`; both preserved hashes byte-identical.

## Lane 3 — explicit live verification

- Overall exit: `5`.
- `INSTALLED_INTEGRITY`: `READY`.
- `HOST_EXECUTION_READY`: `FALSE`; reason: `ORCA_NOT_RESOLVED`.
- `NEW_WORK_READY`: `FALSE`; reason: `ROUTER_ENDPOINT_NOT_DECLARED`.
- `TARGET_READY`: `NOT_EVALUATED`; reason: `NO_TARGET_REGISTERED`.
- `ROUTE_READY`: `OUT_OF_SCOPE`; reason: `NO_EXECUTION_STAMP_SUPPLIED`.
- Validator live finding: `UNAVAILABLE`; reason: `VALIDATOR_VERDICT_UNAVAILABLE`.
- Claude harness finding: `INCOMPATIBLE`; reason: `HARNESS_CAPABILITY_UNPROVEN`.
- Codex auth finding: `UNKNOWN`; reason: `AUTH_STATUS_UNPROVEN`.
- Lane verdict: failed required live readiness; no repair attempted.

## Lane 4 — idempotence

- Plan disposition: `NO_CHANGE`; required mutations: `0`.
- Execute result: `NO_CHANGE`; reason: `PLAN_NO_CHANGE_REQUIRED`.
- Applied revision remained `8a7cbc194fd56114d65c7dfd6a42106c807fb46b`.
- Managed-component observed identity comparison: exit `0`, no diff.

## Lane 5 — drift canary

- Drift state: `LOCAL_DRIFT`; reason: `UNEXPLAINED_MANAGED_DIFFERENCE`; blocked scope: `MUTATION:humanizer`.
- Update-plan result: `PLAN_ONLY`; reason: `REFUSED`; disposition: `REFUSED`; exit: `2`.
- Canary after-refusal hash matched the modified hash, proving no overwrite.
- Restore comparison: `cmp_exit=0`; restored sha256: `aec2e1f4482f1e614d5001f3b2b958bca9a5ffd4d6b5117085897ba75ff816e7`.
- Post-restore offline verification: `verified: true`; failures: `0`; checks: `11`.

UPDATE: CONVERGED — IDEMPOTENCE: NO_CHANGE — DRIFT-REFUSAL: REFUSED — AMBIGUITY: none

Overall outcome: `failed` because Lane 3 did not meet the required live-readiness outcomes.
