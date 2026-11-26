# Security and privacy

AFK sits between you and agent CLIs that hold your plan logins, so it is built to read as little as it needs and to keep logins where they belong.

## The login rules

These hold for every route, pinned or not, and are checked again when a launch plan is built:

- **A plan login is used only by its own vendor's CLI.** Claude's plan only by `claude`, ChatGPT's only by `codex`, SuperGrok's only by `grok`, Antigravity's only by `agy`. A third-party CLI never runs a vendor plan model: OpenCode runs only its own free models, and Pi is not launched with a plan.
- **A plan login never goes through a gateway.** A gateway route runs `claude` with the gateway's own key, from a separate config directory, with every Claude and Anthropic variable unset, so your plan login isn't loaded or sent.
- **The gateway key comes from a plain variable that is not a vendor credential**, so a plan token can't be passed off as a gateway key.

## What AFK reads

| What | Why | How much |
|---|---|---|
| Each CLI's credential file | to show whether it looks signed in | only whether a login field is present; token fields are not decoded |
| Claude's credential file | to ask Anthropic for your plan usage | the access token, sent only to Anthropic's usage endpoint, never stored or printed |
| Codex's session files | its rate-limit figures | the last line that mentions `rate_limits` in recent rollout files |
| Session folders of each CLI | recent activity per pool | file names and modification times, not contents |
| OpenCode's and Pi's auth files | which vendor plans they are signed in to | provider names and login types only |
| `<cli> --version` | whether a CLI is installed and working | the version text, capped at 4 KiB |
| `.afk/config.json` in your project | routing settings | the `router` block |

## What AFK writes

Caches, signals and run records under `~/.config/afk/` (see [configuration](reference/configuration.md#files-afk-keeps)). None of them hold a token. The Claude usage cache is mode 600. Run records keep a gateway's host but drop any user info in its address.

AFK does not change your CLIs' own settings. Yolo applies to one launch and is never written into a CLI's config.

## What AFK sends

- Anthropic's usage endpoint, with your Claude login, at most every two minutes while routing.
- The gateway you configured, for its model list.

Nothing else leaves your machine: no telemetry, no analytics.

## Reporting a security issue

Please don't open a public issue for a vulnerability. Use GitHub's private vulnerability reporting on this repository.
