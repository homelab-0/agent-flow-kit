# Security and privacy

AFK sits between you and agent CLIs that hold your plan logins, so it is built to read as little as it needs and never to hand a login to anyone else.

## Your CLIs, your choice

AFK doesn't decide which CLI you may use with which login; whether a setup suits a provider's terms is between you and the provider. AFK no longer detects which vendor plan OpenCode or Pi is signed in to, because that is written only inside their credential files, which AFK never opens. So they are not mapped to vendor plans automatically: OpenCode is routed on its own free models, and Pi isn't matched to a plan pool.

## Credential safety

These hold for every route, pinned or not, and are checked again when a launch plan is built:

- **A plan login never goes through a gateway.** A gateway route runs `claude` with the gateway's own key, from a separate config directory, with every Claude and Anthropic variable unset, so your plan login isn't loaded or sent.
- **A CLI doesn't get your gateway key in its environment.** AFK removes `AFK_GATEWAY_KEY`, the variable `AFK_GATEWAY_KEY_ENV` names and each gateway's `key = "env:NAME"` variable from the environment of every CLI it starts, so a command the agent runs can't read a key that works on every model behind your gateway. A gateway launch still gets its key, as `ANTHROPIC_AUTH_TOKEN`. A vendor's own variables (`OPENAI_API_KEY` and the like) are left alone: the CLI may need them. Set `AFK_KEEP_SECRETS=1` to turn this off, for example when a CLI calls `afk` itself and needs to launch gateway routes.
- **The gateway key comes from a plain variable that is not a vendor credential**, so AFK never picks up a plan token from a vendor's own variables. The check is on the variable's name: put only a gateway-issued key in it.
- **The gateway address comes from you**, never from a repository: the environment or your own `config.toml` (or the older `router.json`). A repository you clone can't send your gateway key to its own server. Its `.afk/config.json` can set only `route.prefer`, `route.prefer_free` and a stricter `permissions.default`; a gateway, a key, metered models, free reviewers, security models, an install, telemetry or a looser mode is ignored with a warning naming the key, including in the older `router` block and for a project you trust.
- **The gateway key goes only to a gateway address you configured.** A route that names another address is refused, whichever variable holds the key. A gateway on plain `http://` to what looks like a public host gets a warning, not a block. AFK judges that from the address as written and doesn't look the name up, so a bare name such as `gateway` never warns, even if it points somewhere public.
- **Gateway addresses in run records and messages are trimmed** to scheme, host and path: user info, the query string and the fragment are dropped, since some gateways take a key there.
- **Secrets in config are references** (`env:NAME`, `file:`, `cmd:`, `op://`, `keychain:`), never values. A value that isn't one is refused without being repeated, and AFK resolves a reference only when the secret is used, never writing or printing it. `afk config migrate` won't copy a gateway address that carries user info.

## A repository's own CLI settings

Most agent CLIs load settings from the directory they run in: hooks, permission rules, environment variables, MCP servers. Started in a terminal they ask whether you trust the folder first. Started one-shot (`afk -p`), or with no terminal, they don't ask: Claude Code, for one, runs a project's hooks straight away.

So for a one-shot run, or one without a terminal, outside a [trusted repository](guides/permissions.md):

- **Claude Code** is started with `--setting-sources user`, so it loads `~/.claude` and nothing from the directory. Its hooks, permission rules and environment don't apply.
- **Codex** needs nothing: it reads a project's config only for a project you trusted in Codex. That was checked on Codex 0.172.0; on an older Codex, set `project_config = "unknown"` in a [manifest override](reference/harness-manifests.md) to get AFK's note back.
- **OpenCode, Grok, Antigravity and Pi** have no flag AFK knows for this, so AFK starts them and says it couldn't keep the directory's settings out.

AFK prints one line on stderr for Claude Code and for the CLIs without such a flag, and the launch plan carries it as `config_note`. Codex gets no line. `afk trust add <repo>` lets Claude Code and those other CLIs load a repository's own settings in these runs, as well as allowing yolo there. It doesn't change Codex, which goes by the projects you trusted in Codex itself. Instruction files such as `CLAUDE.md` and `AGENTS.md` are still read: they are text for the model, not settings.

## AFK never opens a credential file, with one exception you turn on

AFK checks that each CLI's login file **exists and is larger than 4 bytes** (bigger than the empty `{}` a CLI can leave behind when you sign out), and when it last changed. A smaller file counts as signed out. It never opens one, so no token is ever read, sent, stored or printed. That includes Claude's `~/.claude/.credentials.json`, Codex's `auth.json`, and the login files of Grok, OpenCode, Pi, Devin, Gemini and Qwen. Where a CLI has a sign-in status command of its own (`claude auth status`, `codex login status`), AFK runs it and takes its exit code as the answer, ahead of the file check; the output is dropped unread. To tell whether Codex uses the ChatGPT plan or an API key, AFK runs Codex's own `codex login status` and looks only for those words.

### The vendor usage lookup

The one exception is the vendor usage lookup, which is off unless you turn it on for a CLI (`harness.<name>.vendor_usage = true` in `config.toml`, or the Config tab). It exists for Claude Code and Grok, which can't print plan usage outside a run.

With it on for a CLI, AFK:

- reads that CLI's login file (`~/.claude/.credentials.json`, `~/.grok/auth.json`) and takes the access token, the expiry and, for Grok, the user id. The refresh token is never read into a request;
- sends one `GET` with the token to the vendor's own usage address (`https://api.anthropic.com/api/oauth/usage`, `https://cli-chat-proxy.grok.com/v1/billing`), follows no redirect, and reads at most 1 MB back;
- keeps only the usage figures, the plan name and extra usage. The token is never written, cached, logged or put in an error message;
- never refreshes or rewrites the login. An expired or refused one is left for the CLI to renew.

A repository's `.afk/config.json` can't turn it on. These addresses are the ones each CLI's own usage screen calls; they are not a published API, so a vendor can change them, and a vendor's terms may not allow another tool to use its CLI's login. AFK says this before you turn the lookup on and leaves the choice to you.

## `afk serve` and API keys

[`afk serve`](guides/serve.md) is off until you run it, and listens on this machine only until you set `serve.listen`.

- Every call needs an AFK key. AFK stores a SHA-256 hash of each key (in `~/.local/state/afk/keys.json`, mode 600) and shows the key once; a key is 256 random bits and is compared in constant time.
- By default a call can only answer: its run is read-only, in an empty folder that is deleted afterwards, and loads no project settings. A key reaches a folder of yours only if you give it one with `--dir`.
- A CLI's own sign-in answers calls only while `serve.plan_runs` is on. AFK still never reads or forwards that sign-in: it starts the CLI, and the CLI uses its own login as it always does.
- Every key has rate limits from the start. They are a guard against accidents, yours to change.
- The API is plain HTTP. Beyond this machine, use a private network or a TLS proxy; `afk serve` warns when it starts on such an address.
- Calls are logged by key name, model, route and status. Prompts and answers are never logged or stored.
- A model name from a caller is checked before it becomes a command argument, and a prompt can never be read as an option.

## What AFK reads

| What | Why | How much |
|---|---|---|
| Each CLI's login file | to show whether it looks signed in, and to clear a sign-in signal after a new login | whether it exists, its size and its modification time; never its contents |
| A CLI's login file, only with its vendor usage lookup on | to ask the vendor for plan usage | the access token, its expiry and (Grok) the user id, for one request; nothing is kept |
| `agy -p /usage --output-format json` | Antigravity's plan usage | the groups and windows; a local command that runs no turn |
| `claude -p --input-format stream-json` with a `list_models` control request | the models your Claude plan has | the model names; no message is sent, so no turn runs |
| `codex login status` | whether Codex uses the ChatGPT plan or an API key | only the words "ChatGPT" or "API key"; the rest of the answer is dropped |
| Codex's session files | its rate-limit figures | the last line that mentions `rate_limits` in recent rollout files |
| Claude's output in `afk -p` runs | its plan usage | the `rate_limit_event`'s utilization, status and reset times; the answer is read as before |
| Session folders of each CLI | recent activity per pool | file names and modification times, not contents |
| `<cli> --version` | whether a CLI is installed and working | the version text, capped at 4 KiB |
| `~/.config/afk/config.toml` | your settings | the whole file; secrets in it are only references |
| `.afk/config.json` in your project | routing settings | `route.prefer`, `route.prefer_free`, `permissions.default` and the older `router.prefer_free_for_low_risk`; anything else is ignored with a warning |

## What AFK writes

Caches, signals and run records under `~/.config/afk/` (see [configuration](reference/configuration.md#files-afk-keeps)). None of them hold a token, but they can quote a prompt or a CLI's error text, so a new file is readable by you alone (mode 600; a file that already exists keeps its mode). Run records keep a gateway's host but drop any user info in its address.

AFK does not change your CLIs' own settings. Yolo applies to one launch and is never written into a CLI's config.

## What AFK sends

- The gateway you configured, for its model list.
- The public benchmark feeds (Hugging Face's dataset server for the LMArena leaderboards, and models.dev), when the benchmark catalog is refreshed: about once a day, or when you run `afk bench sync`. These are plain GETs with no key, token or identifier of yours.
- Your npm registry, when you run `afk harness add` or `update`: npm is run from a directory of AFK's own, so the registry is the one in your own npm settings, never one a repository's `.npmrc` names.

Nothing else leaves your machine: no telemetry, no analytics.

## Reporting a security issue

Please don't open a public issue for a vulnerability. Use GitHub's private vulnerability reporting on this repository.
