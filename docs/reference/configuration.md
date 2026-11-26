# Configuration

AFK works with no configuration: it finds your CLIs, reads their pools and routes. Your settings live in one file, `~/.config/afk/config.toml`, which you can edit by hand or with [`afk config`](#afk-config).

## Where things are

| File | What |
|---|---|
| `~/.config/afk/config.toml` | your settings (`$XDG_CONFIG_HOME/afk/config.toml` when `XDG_CONFIG_HOME` is set; `AFK_CONFIG` names another file) |
| `~/.config/afk/afk.lock` | what AFK installed (see [afk.lock](#afklock)); beside `config.toml` |
| `~/.local/state/afk/` | where runtime state is moving (`$XDG_STATE_HOME/afk`); today's caches stay where they are, under `~/.config/afk/` (below) |
| `<project>/.afk/config.json` | the few [routing preferences a project may set](#what-a-project-can-set) |
| `~/.config/afk/router.json` | the older settings file, read only while `config.toml` doesn't exist (see [migrating](#migrating-from-routerjson)) |

`afk config path` prints them.

## Precedence

For each setting, the first of these that sets it wins:

1. a command-line flag (`--prefer`, `--harness`, `--model`, …)
2. the environment (the `AFK_*` variables [below](#environment-variables))
3. the project's `.afk/config.json`, for the keys a project may set
4. `config.toml` (or, while it doesn't exist, `router.json`)
5. the defaults

| Setting | Flag | Environment | Project | config.toml | Default |
|---|---|---|---|---|---|
| preference | `--prefer` | | `route.prefer` | `route.prefer` | `balanced` |
| free first for low-risk work | `--prefer cheap` | `AFK_ROUTER_PREFER_FREE` | `route.prefer_free`, `router.prefer_free_for_low_risk` | `route.prefer_free` | `false` |
| metered API models | | `AFK_ROUTER_ALLOW_METERED_API` | `router.allow_metered_api` | `route.allow_metered` | `false` |
| free reviewers | | `AFK_ROUTER_ALLOW_FREE_REVIEWERS` | `router.allow_free_reviewers` | `route.allow_free_reviewers` | `false` |
| security models | | `AFK_SECURITY_MODELS` | `router.security_models` | `route.security_models` | none |
| gateway | | `AFK_LITELLM_BASE_URL` | `router.litellm_base_url`, only for a [trusted](#trust) project, and only when you set no gateway | `[gateway.<name>]` | none |
| gateway key | | `AFK_GATEWAY_KEY_ENV` names the variable | never | `gateway.<name>.key` | `$AFK_GATEWAY_KEY` |
| daily catalog refresh | | `AFK_SKIP_BENCHMARK_AUTOSYNC=1` | never | `bench.autosync` | on |

The `router.*` keys in a project file are the older format; they keep working as before.

## config.toml

```toml
version = 1

[route]
prefer = "balanced"        # balanced | cheap | best
prefer_free = false        # free and local models first for low-risk work
allow_metered = false      # allow pay-per-token API models
allow_free_reviewers = false
security_models = ["mythos"]

[trust]
repos = ["/home/me/src/work-project"]

[gateway.work]
kind = "litellm"
url = "https://llm.example.com"
key = "env:LITELLM_KEY"    # a reference, never the key itself
default = true

[harness.grok]
enabled = false            # keep this CLI out of routing

[bench]
autosync = true

[bench.sources]
lmarena = { enabled = true }
modelsdev = { enabled = true }
```

`version = 1` is the schema version. A file without it is read as version 1, with a warning; a newer version is refused. A key AFK doesn't know is ignored with a warning naming its line. A value of the wrong type or outside its allowed values stops AFK with an error naming the file, the line and the key, for example `config.toml:4: route.prefer: "fast" is not one of balanced, cheap, best`.

### `[route]`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `prefer` | string | `balanced` | `balanced`, `cheap` (free and local first) or `best` (strongest model for the kind); `--prefer` wins |
| `prefer_free` | bool | `false` | prefer free and local models for low-risk work |
| `allow_metered` | bool | `false` | allow pay-per-token API models |
| `allow_free_reviewers` | bool | `false` | let free and local models take reviews |
| `security_models` | list | none | specialist security models you are entitled to (`mythos`, `daybreak-blue`, or `all`) |

### `[trust]`

| Key | Type | Meaning |
|---|---|---|
| `repos` | list | projects whose `.afk/config.json` may still name a gateway through the older `router.litellm_base_url`, used only when you set no gateway yourself |

### `[gateway.<name>]`

A model gateway; see [gateways](../guides/gateways.md). The one with `default = true` (or the only one) is used.

| Key | Type | Meaning |
|---|---|---|
| `url` | string | required; `http` or `https`, with no user info in it |
| `key` | string | a [secret reference](#secrets) to the gateway key; launching takes only `env:NAME` today |
| `kind` | string | `litellm`, `openrouter`, `portkey`, `agentgateway`, `envoy`, `kong`, `cloudflare`, `vercel`, `openai`, `anthropic`, `ollama`, `lmstudio`, `vllm`, `llamacpp` or `localai` (validated; not used for routing yet) |
| `formats` | list | `openai-chat`, `openai-responses`, `anthropic-messages` (validated; not used yet) |
| `cost` | string | `metered` or `free` (validated; not used yet) |
| `default` | bool | the gateway to use; at most one |

A gateway can only be set by you (here or in the environment), never by a cloned project, because AFK sends the gateway its key.

### `[harness.<name>]`

| Key | Type | Meaning |
|---|---|---|
| `enabled` | bool | `false` keeps that CLI (`claude`, `codex`, `opencode`, `grok`, `agy`, `pi`) out of routing |

### `[bench]`

| Key | Type | Default | Meaning |
|---|---|---|---|
| `autosync` | bool | `true` | the daily background refresh of the [benchmark catalog](benchmark-catalog.md#refreshing-it) |
| `sources.<name>.enabled` | bool | `true` | `lmarena` (the three LMArena boards) and `modelsdev` turn feeds off for `afk bench sync`; `swebench`, `artificialanalysis` and `own` are accepted for later |
| `weights.<task>.<source>` | number | | reserved: how much each source counts per kind of task; validated (not negative), not used yet |
| `override.<model>.<task>` | number | | reserved |

### Reserved sections

These are validated so a file written now keeps working, but AFK doesn't act on them yet:

| Section | Keys |
|---|---|
| `[permissions]` | `default` and `task.<kind>`: `read-only`, `ask`, `edits`, `auto` or `yolo`. Today every launch asks, unless you pass `--yolo` |
| `[serve]` | `listen`, `tls`, `plan_runs` |
| `[telemetry.<name>]` | `kind`, `endpoint`, `key` (a secret reference), `content` |
| `[source.<name>]` | `kind`, `repo`, `labels`, `task`, `mode` (a permission mode), `approve_plan` |

### Secrets

A key in config is always a reference to where the secret is, never the secret:

| Reference | Where |
|---|---|
| `env:NAME` | an environment variable |
| `file:/abs/path` | a file only you can read |
| `cmd:program args` | a command that prints it |
| `op://vault/item` | 1Password |
| `keychain:NAME` | the OS keychain |

A value that isn't a reference is refused, and the error never repeats it. AFK resolves a reference only at the moment the secret is used and never writes the value to disk or prints it; `afk config get` and every `--json` output show the reference. Launching a gateway route resolves `env:NAME` only so far: the launch plan names the variable and the value is copied when the CLI starts.

## What a project can set

A cloned repository is someone else's file, so its `.afk/config.json` may only make routing choices for itself:

```json
{
  "route": { "prefer": "cheap", "prefer_free": true },
  "permissions": { "default": "read-only" }
}
```

| Key | Meaning |
|---|---|
| `route.prefer` | as in config.toml |
| `route.prefer_free` | as in config.toml |
| `permissions.default` | a permission mode, taken only when it is stricter than yours (reserved, like `[permissions]`) |

Anything else (a gateway, a key, an install, telemetry, a work source, trust, a looser mode, other `route` keys) is ignored, and AFK prints a warning naming each key. AFK reads the file from the current directory, or from `--repo <dir>`.

The older `router` block is still read as before:

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

`litellm_base_url` there is used only when the project is listed in `trust.repos` (or `trusted_repos` in `router.json`) and you have set no gateway yourself.

## afk config

| Command | What it does |
|---|---|
| `afk config path [--json]` | prints where config.toml, afk.lock, the state directory and an old router.json are |
| `afk config get [key] [--json]` | a key's value and whether it came from config.toml or the default; with no key, the whole file. Secret references are shown as references |
| `afk config set <key> <value> [--dry-run] [--json]` | sets one key and prints the diff. Lists take commas (`afk config set trust.repos ~/a,~/b`). The new file is validated before it is written; comments, key order and spacing are kept. `--dry-run` shows the diff and writes nothing |
| `afk config edit` | opens a copy in `$VISUAL` or `$EDITOR` and saves it only if it validates |
| `afk config migrate [--dry-run] [--json]` | writes config.toml from the older settings (below) and shows the diff; `--dry-run` writes nothing |

Every write replaces the file atomically (a temporary file renamed into place) while holding a short lock, so two writers can't interleave.

## Migrating from router.json

While `config.toml` doesn't exist, `~/.config/afk/router.json` and the `AFK_*` variables work exactly as before. `afk config migrate` copies them into config.toml:

| From | To |
|---|---|
| `router.json` `litellm_base_url`, or `AFK_LITELLM_BASE_URL` | `[gateway.default]` with `kind = "litellm"`, `url`, `key = "env:AFK_GATEWAY_KEY"` (or the variable `AFK_GATEWAY_KEY_ENV` names), `default = true` |
| `router.json` `security_models`, or `AFK_SECURITY_MODELS` | `route.security_models` |
| `router.json` `trusted_repos` | `trust.repos` |
| `AFK_ROUTER_PREFER_FREE`, `AFK_ROUTER_ALLOW_METERED_API`, `AFK_ROUTER_ALLOW_FREE_REVIEWERS` | `route.prefer_free`, `route.allow_metered`, `route.allow_free_reviewers` |
| `AFK_SKIP_BENCHMARK_AUTOSYNC=1` | `bench.autosync = false` |

It reads no secret: the gateway key becomes a reference to the variable that holds it. A gateway address with user info in it (a credential) is not copied; the command says so. Keys config.toml already sets are kept. The old files are never deleted or changed; once config.toml exists, `router.json` is no longer read. The environment variables keep winning over the file.

## afk.lock

`afk.lock` records everything AFK installs, so a setup can be reproduced on another machine and an install undone exactly. AFK writes it; nothing installs yet in this version, so the file appears with the first installer.

```toml
version = 1

[[install]]
name = "pdf"
kind = "skill"                      # skill | mcp | tool | harness
version = "1.2.0"
source = "github:org/repo/skills/pdf@3f2a9c1"
integrity = "sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
harnesses = ["claude", "codex"]
installed_at = 2026-11-26T12:00:00Z
```

| Field | Meaning |
|---|---|
| `name`, `kind` | what it is; unique per kind |
| `version`, `source` | the exact version and where it came from, pinned (`npm:pkg@1.2.3`, `github:owner/repo@<commit>`, a local path) |
| `integrity` | `sha256-`, `sha384-` or `sha512-` with the base64 hash, as npm writes it |
| `harnesses` | the CLIs it was written into |
| `installed_at` | when |

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
| `AFK_CLAUDE_CREDS_FILE`, `AFK_CODEX_AUTH_FILE`, `AFK_GROK_AUTH_FILE`, `AFK_OPENCODE_AUTH_FILE`, `AFK_PI_AUTH_FILE` | check for a CLI's login file here instead of its default place (only that it exists and is larger than 4 bytes; it is never opened). Codex's defaults to `$CODEX_HOME/auth.json` when `CODEX_HOME` is set |
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
| `XDG_CONFIG_HOME` | the base for `afk/config.toml` and `afk/state/runs` |
| `XDG_STATE_HOME` | the base for `afk/` runtime state |
| `AFK_CONFIG` | use this config.toml instead |

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
