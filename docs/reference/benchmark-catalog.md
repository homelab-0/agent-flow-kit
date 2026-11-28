# Benchmark catalog

The router scores models from a catalog of candidates: each model a CLI can run, with a benchmark score per kind of work.

## Which catalog is used

1. `AFK_ROUTER_BENCHMARKS_FILE`, when set.
2. `~/.config/afk/benchmarks.json`, when it exists with the current schema. [`afk bench sync`](#refreshing-it) writes it from public leaderboards.
3. The catalog built into `afk` ([`internal/router/benchmarks.json`](../../internal/router/benchmarks.json)).

> **Planned:** overriding a model's score for a task, and tuning how much headroom and cost weigh.

## Refreshing it

`afk bench sync` rescores the built-in catalog from public data and writes `~/.config/afk/benchmarks.json`:

| Feed | Gives |
|---|---|
| LMArena agent leaderboard | `coding_complex`, `coding_review`, and the agent half of `architecture` |
| LMArena webdev leaderboard | `webdev` |
| LMArena text leaderboard | `research`, and the reasoning half of `architecture` |
| models.dev | `window_tokens` |
| SWE-bench Verified (on by default) | `coding_complex`, `coding_standard`, `coding_review`: the share of 500 real GitHub issues solved, a model's best result across agents |
| Aider Polyglot (on by default) | `coding_standard`, `coding_complex`: the share of 225 coding exercises passed in six languages |
| Artificial Analysis (off by default) | `research`, `frontier_synthesis`, `architecture`: its Intelligence Index. Needs your own free key in `ARTIFICIAL_ANALYSIS_API_KEY`; the data is credited to [artificialanalysis.ai](https://artificialanalysis.ai) |
| your own sources | the tasks you give each one |

Every other score keeps its fixed estimate. Requests are plain HTTPS GETs. The only key AFK ever sends is one you gave a source yourself (Artificial Analysis, or `--key` on your own), read from the environment variable you named at the moment of the sync, sent only to that source's host, and never written anywhere.

Public boards are slow to add new models. A board that doesn't list a model adds nothing for it: it isn't capped or marked down for that, as it is on the LMArena boards. `afk bench sync` says how many of AFK's models each source matched (`swebench: live synced (80 models, 0 matched)`), so you can tell a board that scores your models from one that doesn't list them yet.

How a board becomes a score:

- A candidate's `arena_match` is compared whole with each row's model name, ignoring case, punctuation and an effort suffix such as `(Max)` or `(High, thinking)`. The best-ranked row wins. A partial name never matches, so `Grok 4.5` can't take the row of `Grok 4.7`.
- Rank 1 scores 98 on the agent board and 97.5 on the others, 0.9 less per rank, never below 80. `architecture` is 60% agent rank and 40% reasoning rank.
- A model a reachable board doesn't list is held to the score of the rank after the board's last (basis `capped`), so an unranked model can't outscore a ranked one on a guess.
- Security specialists are never rescored from a general board, and `frontier_only` models keep their fixed coding scores.
- When a board is unreachable, the scores it gave last time are carried for 14 days (`AFK_BENCHMARK_CARRY_SEC`), then fall back to the estimates. A score carried for a model whose `arena_match` has since changed is dropped.
- When no board is reachable, an existing catalog is left exactly as it is.

On Linux, macOS and other Unix systems, `afk` also refreshes the catalog by itself: when it routes and the catalog is missing, has no measured score, or is more than a day old (`AFK_BENCHMARK_TTL_SEC`), it starts `afk bench sync` in the background and routes with the catalog it has. A failed refresh is retried no sooner than 15 minutes later (`AFK_BENCHMARK_RETRY_SEC`). `AFK_SKIP_BENCHMARK_AUTOSYNC=1`, or naming your own catalog in `AFK_ROUTER_BENCHMARKS_FILE`, turns this off. On other systems there is no background refresh: run `afk bench sync` yourself to keep the catalog current.

## Blending several sources

When more than one source scores the same model for the same kind of task, its score for that task is their weighted average. Each source's place on its own board becomes a score the way LMArena's ranks do (97.5 for #1, 0.9 less per rank, never below 80), so boards measured in different units (a percentage, an Elo, an index) average on one scale. Every weight is 1 unless `bench.weights.<task>.<source>` says otherwise (`afk bench weight`, or `w` on the Sources view); a weight of 0 leaves the source out.

- An estimate is never averaged with a measurement: a measured score replaces it.
- The entry keeps each part (`parts`: the source, its rank and raw result, its score and weight), and a route shows them as `benchmark_parts`; **Why AFK picks** in the Benchmarks tab lists them.
- When a source is unreachable, the part it gave last time is carried for the same 14 days, marked `carried`.

## Your own sources

Any leaderboard published as JSON, YAML or CSV, at an `https://` URL or in a file, can be added:

```sh
afk bench source add my-evals https://example.com/board.json complex,review
```

AFK reads it once, finds the list of records and the fields holding each model's name and score, and shows what it matched before saving:

```toml
[bench.custom.my-evals]
url = "https://example.com/board.json"
tasks = ["coding_complex", "coding_review"]
rows = "results"           # dotted path; leaderboards[name=Verified].results picks one list element
model = "model"            # field with the model's name (dotted for nested fields)
score = "score"            # field with its result; a "71%" string is read as 71
# lower = true             # when a smaller result is better
# weight = 1
# key = "env:MY_EVALS_KEY" # an API key, by environment variable only
# key_header = "x-api-key"
```

A model's names are matched loosely: case, punctuation, word order, an effort suffix, a date and `preview`/`latest` are ignored, so `Claude 4.5 Opus`, `claude-opus-4-5` and `Claude Opus 4.5 (high)` are one model. Every word must still match, so `Grok 4.5` never takes the row of `Grok 4.7`. Where a board lists a model more than once, its best result counts. In the control panel, `a` on the Sources view adds one, `t` tests it and `x` removes it.

For offline use and tests, `AFK_BENCHMARK_FEED_DIR` reads each feed from a file in that directory instead (`lmarena-agent.json`, `lmarena-webdev.json`, `lmarena-text.json`, `models-dev.json`, and `source-<id>.json`, `.yml` or `.csv` for each other source).

## Format (`afk-benchmark-catalog/3`)

```json
{
  "schema": "afk-benchmark-catalog/3",
  "updated_at": "...",
  "entitlement_pools": {
    "anthropic-max": { "provider": "Anthropic", "cost_class": "subscription" }
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
