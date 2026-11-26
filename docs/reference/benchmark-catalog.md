# Benchmark catalog

The router scores models from a catalog of candidates: each model a CLI can run, with a benchmark score per kind of work.

## Which catalog is used

1. `AFK_ROUTER_BENCHMARKS_FILE`, when set.
2. `~/.config/afk/benchmarks.json`, when it exists with the current schema. [`afk bench sync`](#refreshing-it) writes it from public leaderboards.
3. The catalog built into `afk` ([`internal/router/benchmarks.json`](../../internal/router/benchmarks.json)).

> **Planned:** more of `afk bench`: choosing which public boards to trust, overriding a model's score for a task, tuning how much headroom and cost weigh, and optionally feeding your own run ratings back in.

## Refreshing it

`afk bench sync` rescores the built-in catalog from public data and writes `~/.config/afk/benchmarks.json`:

| Feed | Gives |
|---|---|
| LMArena agent leaderboard | `coding_complex`, `coding_review`, and the agent half of `architecture` |
| LMArena webdev leaderboard | `webdev` |
| LMArena text leaderboard | `research`, and the reasoning half of `architecture` |
| models.dev | `window_tokens` |

Every other score keeps its fixed estimate. Requests are plain HTTPS GETs; no key or token is sent to any feed.

How a board becomes a score:

- A candidate's `arena_match` is compared whole with each row's model name, ignoring case, punctuation and an effort suffix such as `(Max)` or `(High, thinking)`. The best-ranked row wins. A partial name never matches, so `Grok 4.5` can't take the row of `Grok 4.7`.
- Rank 1 scores 98 on the agent board and 97.5 on the others, 0.9 less per rank, never below 80. `architecture` is 60% agent rank and 40% reasoning rank.
- A model a reachable board doesn't list is held to the score of the rank after the board's last (basis `capped`), so an unranked model can't outscore a ranked one on a guess.
- Security specialists are never rescored from a general board, and `frontier_only` models keep their fixed coding scores.
- When a board is unreachable, the scores it gave last time are carried for 14 days (`AFK_BENCHMARK_CARRY_SEC`), then fall back to the estimates. A score carried for a model whose `arena_match` has since changed is dropped.
- When no board is reachable, an existing catalog is left exactly as it is.

On Linux, macOS and other Unix systems, `afk` also refreshes the catalog by itself: when it routes and the catalog is missing, has no measured score, or is more than a day old (`AFK_BENCHMARK_TTL_SEC`), it starts `afk bench sync` in the background and routes with the catalog it has. A failed refresh is retried no sooner than 15 minutes later (`AFK_BENCHMARK_RETRY_SEC`). `AFK_SKIP_BENCHMARK_AUTOSYNC=1`, or naming your own catalog in `AFK_ROUTER_BENCHMARKS_FILE`, turns this off. On other systems there is no background refresh: run `afk bench sync` yourself to keep the catalog current.

For offline use and tests, `AFK_BENCHMARK_FEED_DIR` reads each feed from a file in that directory instead (`lmarena-agent.json`, `lmarena-webdev.json`, `lmarena-text.json`, `models-dev.json`).

## Format (`afk-benchmark-catalog/3`)

```json
{
  "schema": "afk-benchmark-catalog/3",
  "updated_at": "...",
  "entitlement_pools": {
    "anthropic-max": { "provider": "Anthropic", "cost_class": "subscription", "pool_tier": "max-20x", "five_hour_session_capacity": 60 }
  },
  "candidates": [
    {
      "id": "claude-sonnet-native",
      "harness": "claude",
      "launch_class": "claude-native",
      "entitlement_pool": "anthropic-max",
      "model": "sonnet",
      "canonical_model": "anthropic/claude-sonnet-5-5",
      "model_family": "anthropic",
      "tier": "standard",
      "effort": "medium",
      "supported_efforts": ["low", "medium", "high", "xhigh", "max"],
      "window_tokens": 1000000,
      "benchmarks": {
        "coding_standard": { "score": 95.0, "benchmark": "LMArena Agent" }
      }
    }
  ]
}
```

### Candidate fields

| Field | Meaning |
|---|---|
| `id` | unique id |
| `harness` | the CLI that runs it |
| `launch_class` | `<cli>-native`, or `<cli>-gateway` for a gateway model |
| `entitlement_pool` | the [pool](../guides/pools.md) it draws on |
| `cost_class` | optional; otherwise the pool's |
| `model`, `canonical_model`, `model_family` | the CLI's name for it, a vendor-neutral name, and the vendor |
| `tier` | `standard` for mid-tier models |
| `effort`, `supported_efforts` | its default effort and the levels its CLI accepts |
| `window_tokens` | context window |
| `requires_gateway` | a gateway model: a candidate only while the gateway lists it |
| `requires_entitlement` | `mythos` or `daybreak-blue`: only when you are entitled (`security_models`) |
| `specialist_domain` | `security`: preferred for security work, held back elsewhere |
| `frontier_only` | kept for the hardest work |
| `scoped_quota` | `fable`: a model with its own weekly quota. AFK can't see that quota without the Claude login, so it isn't checked; a quota failure from a run sets the pool aside |
| `is_bridged_oauth` | a third-party CLI using a vendor login |
| `arena_match`, `models_dev_provider`, `models_dev_id` | the names the sync looks the model up by |
| `benchmarks` | per task class: `score`, `benchmark` (its name) and, when synced, `basis`, `synced_at`, `synced_epoch`, `live`, and for a measured score `feed`, `rank`, `value` and `match` |

### Task classes

`coding_standard`, `coding_complex`, `coding_review`, `architecture`, `webdev`, `research`, `security`, `frontier_synthesis`. A model without a score for a class falls back to its `coding_complex` score, then to 75.

### Score basis

| Basis | Meaning |
|---|---|
| `measured` | read from a public leaderboard by a recent sync |
| `capped` | the board was reachable and doesn't list the model |
| `estimate` | a fixed catalog figure, never measured |
| `stale` | a measurement older than two weeks |
