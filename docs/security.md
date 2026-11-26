# Security and privacy

AFK sits between you and agent CLIs that hold your plan logins, so it is built to read as little as it needs and never to hand a login to anyone else.

## Your CLIs, your choice

AFK doesn't decide which CLI you may use with which login. If you have signed OpenCode or Pi in to a Claude, ChatGPT or other plan, AFK can route to it; whether that suits the provider's terms is between you and the provider. AFK only offers a plan model on another vendor's CLI when that CLI is actually signed in to the plan, because otherwise it couldn't run.

## Credential safety

These hold for every route, pinned or not, and are checked again when a launch plan is built:

- **A plan login never goes through a gateway.** A gateway route runs `claude` with the gateway's own key, from a separate config directory, with every Claude and Anthropic variable unset, so your plan login isn't loaded or sent.
- **The gateway key comes from a plain variable that is not a vendor credential**, so AFK never picks up a plan token from a vendor's own variables. The check is on the variable's name: put only a gateway-issued key in it.
- **The gateway address comes from you**, not from a repository: the environment, your own `~/.config/afk/router.json`, or a project you listed in `trusted_repos`. A repository you clone can't send your gateway key to its own server.

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
