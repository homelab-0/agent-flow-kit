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
| `afk-benchmark-sync/3` | `afk bench sync --json` |

The one exception is `afk -p --json`, whose one line keeps the shape it has always had, without a `schema` field; see [below](#one-shot-answer-afk--p---json).

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

Version 2 drops the routes' `role` and `memory_mode` fields that version 1 had. Version 1 is no longer read or written.

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

## One-shot answer (`afk -p --json`)

```json
{"ok":true,"harness":"codex","model":"gpt-6.1-sol","effort":"medium","attempts":2,"output":"..."}
{"ok":false,"tried":"claude/sonnet, codex/gpt-6.1-sol","exit":1,"error":"..."}
```

| Field | Meaning |
|---|---|
| `ok` | whether an answer was printed |
| `harness`, `model`, `effort` | the route that answered; `effort` is `null` for the CLI's default |
| `attempts` | how many routes were tried, at most 3 |
| `output` | the answer text |
| `tried` | every route tried, as `harness/model`, comma-separated in order |
| `exit` | the last CLI's exit status (1 when it exited 0 but its JSON reported an error, 127 when it could not be started) |
| `error` | the last failure's text, at most 600 bytes |

## Benchmark sync receipt (`afk-benchmark-sync/3`)

```json
{
  "schema": "afk-benchmark-sync/3",
  "result": "synced",
  "catalog_path": "/home/me/.config/afk/benchmarks.json",
  "synced_at": "2026-11-26T12:00:00Z",
  "candidates_count": 11,
  "live_scores": 23,
  "unmatched": ["opencode-grok-native"],
  "feeds": {
    "lmarena_agent": "live_synced (2026-11-11)",
    "lmarena_webdev": "live_synced (2026-11-11)",
    "lmarena_text": "offline",
    "swe_bench_official": "not_scored",
    "models_dev": "live_synced",
    "artificial_analysis": "not_used"
  }
}
```

| Field | Meaning |
|---|---|
| `result` | `synced` (at least one leaderboard read), `feeds_unavailable` (none reachable) or `error` (then only `reason`, `catalog_path` and possibly `synced_at` are given) |
| `candidates_count`, `live_scores` | candidates in the catalog now, and how many of their scores are measured |
| `unmatched` | general candidates the agent board did not list under their `arena_match` name |
| `feeds` | each feed: `live_synced` (with the board's date), `offline`, or `not_scored`/`not_used` for feeds AFK does not read. Artificial Analysis needs an API key, and AFK never sends one |

The catalog it writes also carries the same figures under `sync_receipt`, plus `estimated_scores` and `capped_scores`.

## Run record (`afk-run/1`)

See [run records](../guides/runs.md#whats-in-a-record).
