# JSON formats

Every machine-readable output carries a `schema` field with a name and a version. A change that could break a reader gets a new version.

| Schema | Written by |
|---|---|
| `afk-route-explain/2` | `afk --explain --json` |
| `afk-launch-plan/1` | `afk --launch-plan` |
| `afk-harnesses/3` | `afk harness --json` |
| `afk-router-pools/3` | pool usage (used by the receipt) |
| `afk-run/1` | run records |
| `afk-benchmark-catalog/3` | the [benchmark catalog](benchmark-catalog.md) |

Fields AFK can't know are `null`, never zero.

## Explain (`afk-route-explain/2`)

```json
{
  "schema": "afk-route-explain/2",
  "task": "coding",
  "task_guessed": true,
  "prefer": "balanced",
  "choice": { "...": "a route" },
  "by_harness": [ { "...": "the best route on each installed CLI, highest score first" } ]
}
```

Version 2 drops the routes' `role` and `memory_mode` fields that version 1 had. `AFK_BACKEND=bash` still writes version 1.

With `--harness` and `--model` together, `choice` is a pinned route (`harness`, `model`, `effort`, `entitlement_pool: null`, `reason`, `pinned: true`) and `by_harness` is empty.

## Route

| Field | Meaning |
|---|---|
| `harness`, `model`, `canonical_model`, `model_family` | the CLI, the model as that CLI names it, and its vendor-neutral name and family |
| `candidate_id` | the catalog entry |
| `launch_class` | how it is launched, for example `claude-native` or `claude-gateway` |
| `effort`, `base_effort`, `effort_escalated`, `effort_reason`, `supported_efforts` | the effort chosen, before any escalation, why, and what the CLI accepts |
| `task_class`, `stage`, `risk`, `round` | what the task was scored as |
| `cost_class`, `is_free` | `subscription`, `free` or `api-metered` |
| `entitlement_pool`, `pool_state`, `pool_capacity_5h`, `pool_remaining_5h`, `pool_used_pct`, `pool_headroom_pct` | the [pool](../guides/pools.md) and its state when routed |
| `benchmark_name`, `benchmark_score`, `benchmark_basis`, `benchmark_live`, `benchmark_synced_at` | the score used and where it came from (`measured`, `capped`, `estimate` or `stale`) |
| `effective_score` | the score after adjustments; routes are ranked by it |
| `window_tokens` | the model's context window |
| `router_source` | `afk-benchmarks`, `afk-benchmarks+litellm` for a gateway model, or `fallback-default` |
| `litellm_base_url` | the gateway, for a gateway route |
| `auth_alerts` | pools waiting for a sign-in, with the command to run |
| `reason` | one line explaining the pick |
| `cross_family_review` | for a review, whether the reviewer is from a different model family than the work it reviews |
| `specialist_domain` | set for a specialist model, for example `security` |

A `fallback-default` route also has `no_eligible_candidate`, `candidates_considered`, `installed_harnesses` and `pool_states`, recording why nothing qualified.

## Launch plan (`afk-launch-plan/1`)

```json
{
  "schema": "afk-launch-plan/1",
  "ok": true,
  "argv": ["/usr/local/bin/claude", "--model", "sonnet", "--effort", "medium", "--", "fix it"],
  "env_set": {},
  "env_from": {},
  "env_unset": [],
  "cwd": "/home/me/project",
  "answer": null
}
```

| Field | Meaning |
|---|---|
| `argv` | the command, with the CLI's absolute path |
| `env_set` | variables to set |
| `env_from` | variables to copy at launch: target name → source variable name. Values are never in the plan |
| `env_unset` | variables to remove |
| `cwd` | where to start it |
| `answer` | print mode only: `{"format":"json","file":null}` (the answer is on stdout) or, for Codex, `{"format":"text-file","file":"<path>"}` |

A refused plan is `{"schema":"afk-launch-plan/1","ok":false,"error":"<reason>"}`. See [scripting](../guides/scripting.md#applying-a-plan) for how to apply one.

## Harnesses (`afk-harnesses/3`)

```json
{ "schema": "afk-harnesses/3", "os": "linux", "checked_at": "2026-11-26T08:35:58Z", "harnesses": [ ... ] }
```

Each entry: `name`, `display`, `vendor`, `installed`, `healthy`, `problem`, `binary`, `resolved_path`, `version`, `install_method`, `package`, `update_command` (a list of words, never a shell string), `auth` (`authenticated`, `signed_out`, `unknown`, `not_installed`), `auth_note`, `login`, `efforts` (always a list), `effort_flag`. Without `--all`, only installed CLIs are listed.

## Pools (`afk-router-pools/3`)

`harnesses` (installed state per CLI, plus `litellm_gateway` with `online` and `models`), `auth_alerts`, `unavailable_models` (models set aside, with reason and time) and `pools`. Each pool: `pool_id`, `provider`, `pool_tier`, `cost_class`, `state`, `capacity_5h`, `remaining_units_5h`, `used_pct`, `headroom_pct`, `quota_source` (`anthropic_oauth_api`, `codex_rate_limits`, `local_5h_activity`, `gateway_probe`, `runtime_signal:<kind>` or `unauthenticated`), and when known `weekly_used_pct`, `five_hour_used_pct`, `fable_weekly_used_pct`, `resets_at`, `degraded_kind`, `degraded_reason`.

## Run record (`afk-run/1`)

See [run records](../guides/runs.md#whats-in-a-record).
