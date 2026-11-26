# Subscription pools

A pool is one source of model usage: a plan login, a free tier, or a gateway. AFK tracks how much of each is left in the current window (five hours, or a week when that is all the CLI reports) and uses it to spread work across your plans.

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
   - **Codex**: the rate limits Codex writes into its own session files (`rollout-*.jsonl` under `$CODEX_HOME/sessions`, by default `~/.codex/sessions`), with each window's reset time. The newest reading wins, by when it was recorded. No network call.
   - **Claude**: the `rate_limit_event` that Claude Code prints in its stream-json output, which `afk -p` asks for (`--output-format stream-json --verbose`). It has the plan's utilization per window (five-hour and weekly; overage windows don't count) and when each resets. AFK keeps the last reading in `~/.config/afk/state/plan-usage.json` and uses it until its window resets, for at most 12 hours. Interactive Claude sessions don't print it, so the figure is as of the last `afk -p` run on Claude; the route card says `measured (last -p)` and names the fuller window (5h or weekly). If Claude refused the call, the limit it named counts as full until the reset time Claude gave. While a failed run's mark stands for the pool, the mark is what the card shows, not the reading. No login is read and nothing extra is sent.
3. **Recent activity**: session files each CLI wrote in the last 5 hours (for OpenCode, under its `storage/` folder; a sign-in rewriting its `auth.json` isn't activity), against the pool's capacity, capped at 98%. This is an estimate, and the route card and `--explain` say so (`estimated`). Claude falls back to it when there is no current reading; Grok and Antigravity always use it today (Grok's output reports only each call's tokens). A rate-limit or quota failure from a real run still sets the pool aside (below). Codex sessions count against the ChatGPT plan only when Codex is signed in with the plan; with an API key they are metered usage, not plan usage.

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

Only error text is read: the CLI's error document, its stderr, and stdout that isn't JSON. An answer the model gave is never read for failure words, so an answer about HTTP 429 doesn't set a pool aside. Status codes count only as status codes: on their own, after `HTTP`, `status`, `code`, `error` or `api`, or with their reason phrase (`429 Too Many Requests`). A line number such as `line 1401` or `main.go:429` doesn't count. An overloaded provider (529) moves the run to another route, and sets the pool aside only for the 15-minute transient time.

If a mark is wrong, or you've just signed in again, `afk pools clear <pool>` (or `afk pools clear` for all) removes it.

A model that a provider refuses ("not found", "no access") is set aside on its own for an hour, without affecting the rest of its pool.

Signals are written by one-shot runs (`afk -p`) today, under a short lock so runs that fail at the same time don't lose each other's marks. A truncated or hand-edited signals file is ignored rather than breaking routing.

## Seeing it

`afk --explain` shows each route's pool, headroom, state and, for an estimate, `estimated from recent sessions`; `--explain --json` has every figure, with the source in `pool_quota_source`. The receipt shows the pool before and after a session.

## Privacy

AFK never opens a credential file: sign-in checks look only at whether login files exist, their size and when they changed. Activity counting looks only at file names and times, not contents. See [security and privacy](../security.md).
