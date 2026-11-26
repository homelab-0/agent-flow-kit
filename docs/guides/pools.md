# Subscription pools

A pool is one source of model usage: a plan login, a free tier, or a gateway. AFK tracks how much of each is left in the current 5-hour window and uses it to spread work across your plans.

| Pool | Feeds | Default 5-hour capacity |
|---|---|---|
| `anthropic-max` | `claude` (Claude Pro/Max) | 60 sessions |
| `openai-plus` | `codex` (ChatGPT plans) | 40 |
| `antigravity-pool` | `agy` | 50 |
| `xai-grok` | `grok` (SuperGrok) | 50 |
| `opencode-free` | `opencode` free models | 200 |
| `litellm-local` | a model gateway, see [gateways](gateways.md) | 9999 |

Capacities come from the [benchmark catalog](../reference/benchmark-catalog.md).

## How usage is measured

For each pool AFK takes the best source available, in this order:

1. **A recent failure signal** (below), while it is still in force.
2. **The provider's own figure**:
   - **Claude**: Anthropic's usage endpoint for your plan login, the same figures Claude Code shows. AFK takes the larger of the 5-hour and weekly use; the Fable weekly quota is tracked separately. The answer is cached for two minutes.
   - **Codex**: the rate limits Codex writes into its own session files (`rollout-*.jsonl` under `$CODEX_HOME/sessions`, by default `~/.codex/sessions`). The newest reading wins, by when it was recorded. No network call.
3. **Recent activity**: session files each CLI wrote in the last 5 hours, against the pool's capacity, capped at 98%. Codex sessions count against the ChatGPT plan only when Codex is signed in with the plan; with an API key they are metered usage, not plan usage.

A third-party CLI signed in with a vendor plan shares that plan's pool: for example OpenCode signed in with xAI counts against `xai-grok`. If Grok is installed but no login for xAI exists anywhere, `xai-grok` is offline and AFK says to run `grok login`.

## Pool states

| State | Used | Effect on routing |
|---|---|---|
| `available` | under 75% | normal |
| `warning` | 75–90% | −15 on low and medium-risk work, so other plans take it |
| `exhausted` | 90% or more | not used |
| `auth_required` | a sign-in failure was recorded | not used; AFK prints the sign-in command |
| `offline` | the gateway is down, or OpenCode isn't installed | not used |

## Failure signals

When a CLI fails in a way that says something about its pool, the failure is recorded in `~/.config/afk/pool-signals.json` and the pool is set aside for a while:

| Failure | Set aside for |
|---|---|
| sign-in (401, revoked or expired token, not logged in) | 24 hours, or until you sign in again |
| quota or rate limit (429, usage limit, out of credits) | 1 hour |
| anything else | 15 minutes |

A model that a provider refuses ("not found", "no access") is set aside on its own for an hour, without affecting the rest of its pool.

Signals are written by one-shot runs (`afk -p`) today. A truncated or hand-edited signals file is ignored rather than breaking routing.

## Seeing it

`afk --explain` shows each route's pool, headroom and state; `--explain --json` has every figure. The receipt shows the pool before and after a session.

## Privacy

The Claude check reads your Claude login to make the request and sends it only to Anthropic's own endpoint. The cache file (`~/.config/afk/live-quota-cache.json`, mode 600) holds usage percentages and a hash that identifies the login's current version (so a new login is never shown the old one's figures), never a token. Activity counting looks only at file names and times, not contents. See [security and privacy](../security.md).
