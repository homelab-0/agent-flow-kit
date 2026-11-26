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
   - **Codex**: the rate limits Codex writes into its own session files (`rollout-*.jsonl` under `$CODEX_HOME/sessions`, by default `~/.codex/sessions`). The newest reading wins, by when it was recorded. No network call.
3. **Recent activity**: session files each CLI wrote in the last 5 hours (for OpenCode, under its `storage/` folder; a sign-in rewriting its `auth.json` isn't activity), against the pool's capacity, capped at 98%. This is an estimate, and the route card and `--explain` say so (`estimated`). Claude's pool is always estimated this way: Anthropic's usage figures can only be read with your Claude login, and AFK never opens it. A rate-limit or quota failure from a real run still sets the pool aside (below). Codex sessions count against the ChatGPT plan only when Codex is signed in with the plan; with an API key they are metered usage, not plan usage.

Which plan Codex uses (ChatGPT or an API key) comes from `codex login status`; when it can't answer, Codex's sessions aren't counted against any pool rather than guessed. Claude's and Codex's folders follow `CLAUDE_CONFIG_DIR` and `CODEX_HOME` when they are set. Which vendor plans OpenCode or Pi are signed in to is written only inside their credential files, so AFK doesn't count them against those plans: OpenCode draws on its own free pool. If Grok is installed but no login for xAI exists anywhere, `xai-grok` is offline and AFK says to run `grok login`.

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

Signals are written by one-shot runs (`afk -p`) today, under a short lock so runs that fail at the same time don't lose each other's marks. A truncated or hand-edited signals file is ignored rather than breaking routing.

## Seeing it

`afk --explain` shows each route's pool, headroom, state and, for an estimate, `estimated from recent sessions`; `--explain --json` has every figure, with the source in `pool_quota_source`. The receipt shows the pool before and after a session.

## Privacy

AFK never opens a credential file: sign-in checks look only at whether login files exist, their size and when they changed. Activity counting looks only at file names and times, not contents. See [security and privacy](../security.md).
