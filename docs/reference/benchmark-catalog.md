# Benchmark catalog

The router scores models from a catalog of candidates: each model a CLI can run, with a benchmark score per kind of work.

## Which catalog is used

1. `AFK_ROUTER_BENCHMARKS_FILE`, when set.
2. `~/.config/afk/benchmarks.json`, when it exists with the current schema. The bash engine's daily sync writes it from public leaderboards.
3. The catalog built into `afk` ([`internal/router/benchmarks.json`](../../internal/router/benchmarks.json)).

> **Planned:** `afk bench` to choose which public boards to trust (LMArena, SWE-bench, models.dev, Artificial Analysis), override a model's score for a task, tune how much headroom and cost weigh, and optionally feed your own run ratings back in. The sync moves into the Go binary.

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
| `scoped_quota` | `fable`: skipped when the Fable weekly quota is 90% used |
| `is_bridged_oauth` | a third-party CLI using a vendor login |
| `benchmarks` | per task class: `score`, `benchmark` (its name) and, when synced, `basis`, `synced_at`, `synced_epoch`, `live` |

### Task classes

`coding_standard`, `coding_complex`, `coding_review`, `architecture`, `webdev`, `research`, `security`, `frontier_synthesis`. A model without a score for a class falls back to its `coding_complex` score, then to 75.

### Score basis

| Basis | Meaning |
|---|---|
| `measured` | read from a public leaderboard by a recent sync |
| `capped` | the board was reachable and doesn't list the model |
| `estimate` | a fixed catalog figure, never measured |
| `stale` | a measurement older than two weeks |
