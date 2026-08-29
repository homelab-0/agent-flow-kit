# AFK-PORT-1.4-M2C-LIVE classification

Sources: `status-live.json`, `verify-live.json`, and `status-live.txt`. Both JSON surfaces agree on every quotation below.

## Required scopes

- Installation integrity: `INSTALLED_INTEGRITY: READY` (`evaluated=true`, provenance `HASH_COMPARISON`). Installed state is `CURRENT`; journal is `COMMITTED`; lock is `NONE`; applied revision is `8a7cbc194fd56114d65c7dfd6a42106c807fb46b`.
- `HOST_EXECUTION_READY`: `FALSE` — `ORCA_NOT_RESOLVED` (`evaluated=true`, provenance `CAPABILITY_PROBE`, `launch_authoritative=false`). This scope is grounded as false, but its quoted reason conflicts with the same result's live facts; see Ambiguity.
- `NEW_WORK_READY`: `FALSE` — `ROUTER_ENDPOINT_NOT_DECLARED` (`evaluated=true`, provenance `ROUTER_STATUS`, `launch_authoritative=false`). This scope is grounded as false, but its quoted reason conflicts with the same result's environment and live facts; see Ambiguity.
- `TARGET_READY(repo)`: no repository target is registered. The grounded target-arity classification is `TARGET_READY: NOT_EVALUATED` — `NO_TARGET_REGISTERED`, with `targets: []` and `evaluated=false`.
- Validator readiness: executable `PRESENT` — `EXECUTABLE_RESOLVED`; contract `UNKNOWN` — `VALIDATOR_CONTRACT_UNREADABLE`; fixtures `UNAVAILABLE` — `VALIDATOR_VERDICT_UNAVAILABLE` (transient). The fixture failure blocks `HOST_EXECUTION_READY`.
- Harness readiness: Orca executable `PRESENT` — `EXECUTABLE_RESOLVED`, runtime `AVAILABLE` — `ORCA_RUNTIME_REACHABLE`, capability `UNKNOWN` — `ORCA_CAPABILITY_UNPROVEN`; Claude executable `PRESENT` — `EXECUTABLE_RESOLVED`, capability `INCOMPATIBLE` — `HARNESS_CAPABILITY_UNPROVEN`, native session `NOT_EVALUATED` — `HARNESS_CAPABILITY_UNPROVEN`; Codex executable `PRESENT` — `EXECUTABLE_RESOLVED`, capability `COMPATIBLE` — `HARNESS_CAPABILITY_PROVEN`, native session `UNKNOWN` — `AUTH_STATUS_UNPROVEN`.
- Funding/auth safety (MODE/CLASS words only): Claude auth class `NOT_EVALUATED` — `HARNESS_CAPABILITY_UNPROVEN`; Codex auth class `UNKNOWN` — `AUTH_STATUS_UNPROVEN`; route funding class `NOT_EVALUATED` — `NO_EXECUTION_STAMP_SUPPLIED`. No credential values are quoted or persisted.
- `ROUTE_READY`: `OUT_OF_SCOPE` — `NO_EXECUTION_STAMP_SUPPLIED`; `evaluated=false`, `execution_stamp=null`, `placement_selected=false`, `launch_authoritative=false`. Route authority and placement remain `NOT_EVALUATED` — `LIVE_PROBE_NOT_REQUESTED`. No stamp was supplied.

## Additional live classifications

- Router status: `INCOMPATIBLE` — `ROUTER_API_SHAPE_UNSUPPORTED`.
- Router catalog provenance: `NOT_EVALUATED` — `ROUTER_API_SHAPE_UNSUPPORTED`.
- Overall: `READY_WITH_WARNINGS` (exit code `5`).

## Ambiguity

1. `HOST_EXECUTION_READY` reports `ORCA_NOT_RESOLVED`, while `live_facts.orca_executable` reports `PRESENT` — `EXECUTABLE_RESOLVED` at `/home/devbox/.local/bin/orca-ide`. Independent live blockers are grounded (`ORCA_CAPABILITY_UNPROVEN` and `VALIDATOR_VERDICT_UNAVAILABLE`), but the readiness reason itself is stale or internally inconsistent.
2. `NEW_WORK_READY` reports `ROUTER_ENDPOINT_NOT_DECLARED`, while the environment record reports `AGENT_ROUTER_URL` present and `live_facts.router_status` was evaluated as `INCOMPATIBLE` — `ROUTER_API_SHAPE_UNSUPPORTED`. The false state is grounded, but the readiness reason is stale or internally inconsistent.

LIVE: READY_WITH_WARNINGS — AMBIGUITY: HOST_EXECUTION_READY reason conflicts with resolved `orca-ide`; NEW_WORK_READY reason conflicts with declared router endpoint and evaluated router response.
