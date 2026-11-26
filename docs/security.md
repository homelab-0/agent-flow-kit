# Security and privacy

AFK sits between you and agent CLIs that hold your plan logins, so it is built to read as little as it needs and never to hand a login to anyone else.

## Your CLIs, your choice

AFK doesn't decide which CLI you may use with which login; whether a setup suits a provider's terms is between you and the provider. AFK no longer detects which vendor plan OpenCode or Pi is signed in to, because that is written only inside their credential files, which AFK never opens. So they are not mapped to vendor plans automatically: OpenCode is routed on its own free models, and Pi isn't matched to a plan pool.

## Credential safety

These hold for every route, pinned or not, and are checked again when a launch plan is built:

- **A plan login never goes through a gateway.** A gateway route runs `claude` with the gateway's own key, from a separate config directory, with every Claude and Anthropic variable unset, so your plan login isn't loaded or sent.
- **The gateway key comes from a plain variable that is not a vendor credential**, so AFK never picks up a plan token from a vendor's own variables. The check is on the variable's name: put only a gateway-issued key in it.
- **The gateway address comes from you**, never from a repository: the environment or your own `config.toml` (or the older `router.json`). A repository you clone can't send your gateway key to its own server. Its `.afk/config.json` can set only `route.prefer`, `route.prefer_free` and a stricter `permissions.default`; a gateway, a key, metered models, free reviewers, security models, an install, telemetry or a looser mode is ignored with a warning naming the key, including in the older `router` block and for a project you trust.
- **The gateway key goes only to a gateway address you configured.** A route that names another address is refused, whichever variable holds the key. A gateway on plain `http://` outside your machine or private network gets a warning, not a block.
- **Gateway addresses in run records and messages are trimmed** to scheme, host and path: user info, the query string and the fragment are dropped, since some gateways take a key there.
- **Secrets in config are references** (`env:NAME`, `file:`, `cmd:`, `op://`, `keychain:`), never values. A value that isn't one is refused without being repeated, and AFK resolves a reference only when the secret is used, never writing or printing it. `afk config migrate` won't copy a gateway address that carries user info.

## AFK never opens a credential file

AFK checks that each CLI's login file **exists and is larger than 4 bytes** (bigger than the empty `{}` a CLI can leave behind when you sign out), and when it last changed. A smaller file counts as signed out. It never opens one, so no token is ever read, sent, stored or printed. That includes Claude's `~/.claude/.credentials.json`, Codex's `auth.json`, and the login files of Grok, OpenCode, Pi, Devin, Gemini and Qwen. To tell whether Codex uses the ChatGPT plan or an API key, AFK runs Codex's own `codex login status` and looks only for those words.

## What AFK reads

| What | Why | How much |
|---|---|---|
| Each CLI's login file | to show whether it looks signed in, and to clear a sign-in signal after a new login | whether it exists, its size and its modification time; never its contents |
| `codex login status` | whether Codex uses the ChatGPT plan or an API key | only the words "ChatGPT" or "API key"; the rest of the answer is dropped |
| Codex's session files | its rate-limit figures | the last line that mentions `rate_limits` in recent rollout files |
| Session folders of each CLI | recent activity per pool | file names and modification times, not contents |
| `<cli> --version` | whether a CLI is installed and working | the version text, capped at 4 KiB |
| `~/.config/afk/config.toml` | your settings | the whole file; secrets in it are only references |
| `.afk/config.json` in your project | routing settings | `route.prefer`, `route.prefer_free`, `permissions.default` and the older `router.prefer_free_for_low_risk`; anything else is ignored with a warning |

## What AFK writes

Caches, signals and run records under `~/.config/afk/` (see [configuration](reference/configuration.md#files-afk-keeps)). None of them hold a token. Run records keep a gateway's host but drop any user info in its address.

AFK does not change your CLIs' own settings. Yolo applies to one launch and is never written into a CLI's config.

## What AFK sends

- The gateway you configured, for its model list.
- The public benchmark feeds (Hugging Face's dataset server for the LMArena leaderboards, and models.dev), when the benchmark catalog is refreshed: about once a day, or when you run `afk bench sync`. These are plain GETs with no key, token or identifier of yours.

Nothing else leaves your machine: no telemetry, no analytics.

## Reporting a security issue

Please don't open a public issue for a vulnerability. Use GitHub's private vulnerability reporting on this repository.
