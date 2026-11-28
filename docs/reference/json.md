# JSON formats

Every machine-readable output carries a `schema` field with a name and a version. A change that could break a reader gets a new version.

| Schema | Written by |
|---|---|
| `afk-route-explain/2` | `afk --explain --json` |
| `afk-launch-plan/1` | `afk --launch-plan` |
| `afk-harnesses/3` | `afk harness --json` |
| `afk-router-pools/5` | pool usage (used by the receipt) |
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

It also has `mode` (the [permission mode](../guides/permissions.md) asked for), `mode_source` (`flag`, `permissions.task.<kind>`, `permissions.default`, `project` or `default`) and `mode_by_harness`: for each installed CLI, the `mode` it runs that as and a `note` when it is stricter (an empty `mode` means the CLI can't run it at all).

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
| `entitlement_pool`, `pool_state`, `pool_used_pct`, `pool_headroom_pct` | the [pool](../guides/pools.md) and its state when routed. The two figures are `null` or absent unless the plan's CLI reported them |
| `pool_quota_source` | where the pool figures came from: `codex_rate_limits` or `claude_rate_limit_event` (reported by the CLI; the only sources with figures), `runtime_signal:<kind>`, `gateway_probe`, `unauthenticated` or `unknown` |
| `benchmark_name`, `benchmark_score`, `benchmark_basis`, `benchmark_live`, `benchmark_synced_at` | the score used and where it came from (`measured`, `capped`, `estimate` or `stale`) |
| `effective_score` | the score after adjustments; routes are ranked by it |
| `outcome_runs`, `outcome_adjustment` | when your ratings count for this route: how many, and the points they added or took away (absent otherwise) |
| `pacing`, `pacing_adjustment` | where the route's measured plan window is heading (below), and the points [plan pacing](../guides/routing.md#plan-pacing) moved the score (absent when pacing is off or moved nothing) |
| `window_tokens` | the model's context window |
| `router_source` | `afk-benchmarks`, or `afk-benchmarks+litellm` for a gateway model |
| `litellm_base_url` | the gateway, for a gateway route |
| `auth_alerts` | pools waiting for a sign-in, with the command to run |
| `reason` | one line explaining the pick |
| `cross_family_review` | for a review, whether the reviewer is from a different model family than the work it reviews |
| `specialist_domain` | set for a specialist model, for example `security` |

When nothing qualifies there is no route document: afk exits with code 4 and says why on stderr (see [when nothing qualifies](../guides/routing.md#when-nothing-qualifies)).

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
| `env_unset` | variables to remove: on any launch, the gateway key variables that are set (`AFK_GATEWAY_KEY`, the one `AFK_GATEWAY_KEY_ENV` names, each gateway's `key = "env:NAME"`); on a gateway launch, the Claude and Anthropic variables too |
| `cwd` | where to start it |
| `mode`, `mode_note` | the permission mode the CLI runs in, and why when it is stricter than the one asked for |
| `config_note` | for a one-shot run (or one without a terminal) outside a trusted repository: what happens to the settings that directory carries |
| `answer` | print mode only: `{"format":"json","file":null}` (the answer is on stdout) or, for Codex, `{"format":"text-file","file":"<path>"}` |

A refused plan is `{"schema":"afk-launch-plan/1","ok":false,"error":"<reason>"}`. See [scripting](../guides/scripting.md#applying-a-plan) for how to apply one.

## Harnesses (`afk-harnesses/3`)

```json
{ "schema": "afk-harnesses/3", "os": "linux", "checked_at": "2026-11-26T08:35:58Z", "harnesses": [ ... ] }
```

Each entry: `name`, `display`, `vendor`, `installed`, `healthy`, `problem`, `binary`, `resolved_path`, `version`, `install_method`, `package`, `update_command` (a list of words, never a shell string), `auth` (`authenticated`, `signed_out`, `unknown`, `not_installed`), `auth_note`, `login`, `efforts` (always a list), `effort_flag`. Without `--all`, only installed CLIs are listed.

## Pools (`afk-router-pools/5`)

`harnesses` (installed state per CLI, plus `litellm_gateway` with `online` and `models`), `auth_alerts`, `unavailable_models` (models set aside, with reason and time) and `pools`. Each pool: `pool_id`, `provider`, `cost_class`, `plan` (the plan name, only when the CLI reported one with its usage; AFK never guesses which plan you pay for), `state`, `used_pct` and `headroom_pct` (`null` unless the plan's CLI reported them), `quota_source` (`codex_rate_limits`, `claude_rate_limit_event`, `gateway_probe`, `local_probe`, `runtime_signal:<kind>`, `unauthenticated` or `unknown`), and when known `weekly_used_pct`, `five_hour_used_pct`, `resets_at`, `observed_at` (when the CLI reported the figure) and `window` (`5h` or `weekly`, the window the figure and reset are for; `other` for a length AFK doesn't project), `degraded_kind`, `degraded_reason`, `set_aside` and `set_aside_until` (a failed run, not a reading, is why the pool isn't used), and for a measured pool `pacing`: `window`, `resets_at`, `elapsed_pct`, `unused_at_reset_pct` or `runs_out_at` (the projection at the rate so far, when there is one) and `adjustment` (the points it gives routes on the pool with pacing on).

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
