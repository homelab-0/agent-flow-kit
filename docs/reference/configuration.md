# Configuration

AFK works with no configuration: it finds your CLIs, reads their pools and routes. Settings exist for projects that want different routing, for gateways, and for tests.

> **Planned:** one config file, `~/.config/afk/config.toml`, managed with `afk config`, holding gateways, benchmark settings, permission modes, MCP servers and skills. The settings below keep working.

## Project settings

A project can tune routing in `.afk/config.json`. AFK reads it from the current directory, or from `--repo <dir>`.

```json
{
  "router": {
    "litellm_base_url": "http://gateway.local:4000",
    "prefer_free_for_low_risk": false,
    "allow_free_reviewers": false,
    "allow_metered_api": false,
    "security_models": ["mythos"]
  }
}
```

| Key | Default | Meaning |
|---|---|---|
| `litellm_base_url` | none | a model gateway; used only when the project is trusted (below); see [gateways](../guides/gateways.md) |
| `prefer_free_for_low_risk` | `false` | prefer free and local models for low-risk work, as `--prefer cheap` does |
| `allow_free_reviewers` | `false` | let free and local models take reviews |
| `allow_metered_api` | `false` | allow pay-per-token API models |
| `security_models` | none | specialist security models you are entitled to (`mythos`, `daybreak-blue`, or `all`) |

An environment variable with the same purpose (below) wins over the file.

### Your own settings: `~/.config/afk/router.json`

```json
{
  "litellm_base_url": "http://gateway.local:4000",
  "security_models": ["mythos"],
  "trusted_repos": ["/home/me/src/work-project"]
}
```

| Key | Meaning |
|---|---|
| `litellm_base_url` | your gateway, for every project |
| `security_models` | used when a project doesn't set its own |
| `trusted_repos` | projects whose `.afk/config.json` may name a gateway |

AFK sends your gateway key to the gateway when it launches a gateway route, so the gateway address must come from you: `AFK_LITELLM_BASE_URL`, then `litellm_base_url` here, then a project's own setting only if the project is listed in `trusted_repos`. A repository you clone can't point your key at its own server.

## Environment variables

### Routing

| Variable | Meaning |
|---|---|
| `AFK_LITELLM_BASE_URL` | the model gateway's base URL |
| `AFK_GATEWAY_KEY` | the gateway's key |
| `AFK_GATEWAY_KEY_ENV` | the name of another variable that holds the gateway key |
| `AFK_ROUTER_PREFER_FREE` | `1`/`true`: as `prefer_free_for_low_risk` |
| `AFK_ROUTER_ALLOW_FREE_REVIEWERS` | `1`/`true`: as `allow_free_reviewers` |
| `AFK_ROUTER_ALLOW_METERED_API` | `1`/`true`: as `allow_metered_api` |
| `AFK_SECURITY_MODELS` | comma-separated, as `security_models` |
| `AFK_ROUTER_BENCHMARKS_FILE` | use this benchmark catalog instead of the synced or built-in one |
| `AFK_DISCOVERED_MODELS_FILE` | read models the CLIs reported from this file |

### Discovery and pools

| Variable | Meaning |
|---|---|
| `AFK_HARNESS_BIN_DIR` | the only directory AFK looks in for CLIs |
| `AFK_ROUTER_BIN_CACHE_SEC` | how long a CLI's `--version` answer is remembered (default 300; `0` checks every time) |
| `AFK_ROUTER_BIN_FAIL_CACHE_SEC` | how long a failed answer is remembered (default 30) |
| `AFK_ROUTER_BIN_CACHE_FILE` | where those answers are kept |
| `AFK_ROUTER_SIGNALS_FILE` | where failure signals are kept |
| `AFK_CLAUDE_CREDS_FILE`, `AFK_CODEX_AUTH_FILE`, `AFK_GROK_AUTH_FILE`, `AFK_OPENCODE_AUTH_FILE`, `AFK_PI_AUTH_FILE` | check for a CLI's login file here instead of its default place (only that it exists; it is never opened) |
| `AFK_CODEX_SESSIONS_DIR` | read Codex's rate limits from here |
| `CLAUDE_CONFIG_DIR`, `CODEX_HOME` | honoured as the CLIs themselves honour them |
| `AFK_ROUTER_SIGNALS_FILE` | use this [signals file](../guides/pools.md#failure-signals) instead of `~/.config/afk/pool-signals.json` |

### Benchmark sync

| Variable | Meaning |
|---|---|
| `AFK_SKIP_BENCHMARK_AUTOSYNC=1` | don't refresh the catalog in the background |
| `AFK_BENCHMARK_TTL_SEC` | refresh a catalog older than this (default 86400, a day) |
| `AFK_BENCHMARK_RETRY_SEC` | wait this long after an attempt before another (default 900) |
| `AFK_BENCHMARK_CARRY_SEC` | keep a measured score this long while its board is unreachable (default 1209600, 14 days) |
| `AFK_BENCHMARK_FEED_DIR` | read the feeds from files in this directory instead of the network |

### Launching and display

| Variable | Meaning |
|---|---|
| `AFK_STATE_DIR` | where the separate Claude config for gateway routes lives (default `~/.local/state/agent-flow-kit`) |
| `NO_COLOR`, `TERM=dumb`, `AFK_MOTION=off` | no animation (and no colour for `NO_COLOR`) |
| `XDG_CONFIG_HOME` | the base for `afk/state/runs` |

## Files AFK keeps

| File | What |
|---|---|
| `~/.config/afk/state/runs/<id>.json` | [run records](../guides/runs.md) |
| `~/.config/afk/pool-signals.json` | [failure signals](../guides/pools.md#failure-signals) |
| `~/.config/afk/harness-bin-cache.json` | which CLIs answered `--version`, five minutes |
| `~/.config/afk/benchmarks.json` | the [synced benchmark catalog](benchmark-catalog.md#refreshing-it), used when present and current; `.sync-attempt` beside it marks the last attempt |
| `~/.config/afk/discovered-models.json` | models the CLIs reported, used when present |
| `~/.local/state/agent-flow-kit/gateway-claude/` | the separate Claude config for gateway routes |

All of them can be deleted; AFK recreates what it needs.
