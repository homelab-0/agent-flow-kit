# Subscription pools

A pool is one source of model usage: a plan login, a free tier, or a gateway. AFK shows how much of each plan is left in its current window (five hours or a week) **only when the plan's own CLI reported it**, and uses that to spread work across your plans. When no CLI has reported a figure, AFK shows `usage unknown`. It never estimates one.

| Pool | Feeds |
|---|---|
| `anthropic-max` | `claude` (Claude Pro/Max) |
| `openai-plus` | `codex` (ChatGPT plans) |
| `antigravity-pool` | `agy` |
| `xai-grok` | `grok` |
| `opencode-free` | `opencode` free models |
| `litellm-local` | a model gateway, see [gateways](gateways.md) |

AFK doesn't know which tier of a plan you pay for, and doesn't guess. The Usage tab names a plan in general ("Claude plan", "Grok plan") and adds the tier only when the CLI itself reported it, as Codex does ("ChatGPT plan · pro").

A reported figure is as old as the last time the CLI reported it. When that is more than 15 minutes ago AFK says so beside it (`read 3h ago` on the route card, a line under the plan on the Usage tab, and in `afk pools`), so an old reading is not taken for the plan's state right now.

## How usage is measured

A pool has a usage figure only from the provider's own report:

- **Codex**: Codex's own app server (`codex app-server`, asked for `account/rateLimits/read`), which gives the plan, each usage window with its reset time, and the credit balance. It starts no session and spends nothing. Codex also writes its limits into its session files (`rollout-*.jsonl` under `$CODEX_HOME/sessions`); AFK reads those too and uses whichever reading is newer.
- **Claude**: `claude auth status` gives the plan name. Usage comes from the `rate_limit_event` that Claude Code prints in its stream-json output, which `afk -p` asks for (`--output-format stream-json --verbose`). It has the plan's utilization per window (five-hour and weekly; overage windows don't count) and when each resets. AFK keeps the last reading in `~/.config/afk/state/plan-usage.json` and uses it until its window resets, for at most 12 hours. Claude Code has no command that prints usage, so the figure is as of the last `afk -p` run on Claude; the route card says `measured (last -p)` and names the fuller window (5h or weekly). If Claude refused the call, the limit it named counts as full until the reset time Claude gave.
- **Grok**: `grok usage` answers only while Grok's background service runs, so there is no figure from the CLI. The pool says so: `usage unknown (Grok shows plan usage only inside grok, with /usage)`.
- **Antigravity**: its own `/usage` command, run in print mode (`agy -p /usage --output-format json`). agy answers a slash command itself, so no prompt reaches a model: the answer has a turn count of 0, no conversation and no tokens. It lists each group of models (Gemini, and Claude and GPT) with what is left of its weekly and 5-hour windows. The pool shows the fullest window of any group. If an answer ever shows that a turn ran, AFK stops running the command on that install and says so. agy before 1.1.11 is not asked.
- **Anything else**: `usage unknown`.

AFK never sends a prompt to find out usage and never guesses. It opens a login file for usage only for a CLI you turned the vendor usage lookup on for (below); otherwise never.

### The vendor usage lookup

Claude Code and Grok have no way to print plan usage outside a run. Their vendors do answer it to the login the CLI saved, which is how each CLI's own usage screen gets it. You can let AFK ask the same way, one CLI at a time:

```toml
[harness.claude]
vendor_usage = true
```

or on the Config tab (`harness.claude.vendor_usage`, `harness.grok.vendor_usage`), where enter flips the switch. Turning one on shows the warning first and takes one more enter. It is off by default, because a vendor's terms may not allow another tool to use its CLI's login. That is yours to weigh.

With it on, AFK reads the access token from the CLI's login file, sends one request to the vendor's own host (`api.anthropic.com` for Claude, `cli-chat-proxy.grok.com` for Grok), and drops the token. It never stores, prints, refreshes or rewrites a login, and follows no redirect. An expired login is left for the CLI to renew: the pool says to open the CLI once. The figure shows as `reported by the vendor's usage service`, with extra usage when the vendor reports it. The CLI's own sources are still tried first, and a newer reading from a run wins.

On macOS Claude Code keeps its login in the keychain, which AFK doesn't open, so the Claude lookup gives no figure there yet. An unknown plan still routes; its usage just doesn't count for or against it. When a CLI reports usage beyond the plan's windows (Codex's credit balance), the pool shows it as `extra usage`.

Each CLI is asked through [its own module](harnesses.md#what-afk-asks-each-cli), and the answer is reused for five minutes (`~/.config/afk/state/accounts.json`).

A [failure signal](#failure-signals) from a real run sets a pool aside for a while. That is a state, not a figure: the pool shows as set aside, with no percentage made up for it.

Which plan Codex uses (ChatGPT or an API key) comes from `codex login status`; when it can't answer, Codex is bound to neither rather than guessed. Claude's and Codex's folders follow `CLAUDE_CONFIG_DIR` and `CODEX_HOME` when they are set. Which vendor plans OpenCode or Pi are signed in to is written only inside their credential files, so AFK doesn't count them against those plans: OpenCode draws on its own free pool. If Claude's or Codex's own status command says it is signed out, or Grok or Antigravity (which have no status command) is installed with no login on disk, that plan's pool is offline, shows `not signed in`, and AFK says which sign-in command to run. Being installed is not being signed in.

## Pool states

| State | Reported use | Effect on routing |
|---|---|---|
| `available` | under 75%, or unknown | normal |
| `warning` | 75–90% | −15 on low and medium-risk work, so other plans take it |
| `exhausted` | 90% or more, or set aside by a failed run | not used |
| `auth_required` | a sign-in failure was recorded | not used; AFK prints the sign-in command |
| `offline` | the gateway is down, OpenCode isn't installed, or the plan's CLI isn't signed in | not used |

## Failure signals

When a CLI fails in a way that says something about its pool, the failure is recorded in `~/.config/afk/pool-signals.json` and the pool is set aside for a while:

| Failure | Set aside for |
|---|---|
| sign-in (401, revoked or expired token, not logged in) | 24 hours, or until you sign in again |
| quota or rate limit (429, usage limit, out of credits) | 1 hour |
| anything else | 15 minutes |

Only error text is read: the CLI's error document, its stderr, and stdout that isn't JSON. An answer the model gave is never read for failure words, so an answer about HTTP 429 doesn't set a pool aside. Status codes count only as status codes: on their own, after `HTTP`, `status`, `code`, `error` or `api`, or with their reason phrase (`429 Too Many Requests`). A line number such as `line 1401` or `main.go:429` doesn't count. An overloaded provider (529) moves the run to another route, and sets the pool aside only for the 15-minute transient time.

A pool set aside this way has `set_aside` (and `set_aside_until`, when the mark ends by itself) in `afk pools --json`. The Usage tab shows it under the plan as "set aside after a run failed with …, for another 42m", not as a usage figure. If a mark is wrong, or you've just signed in again, press `c` on the Usage tab, or run `afk pools clear <pool>` (or `afk pools clear` for all).

A model that a provider refuses ("not found", "no access") is set aside on its own for an hour, without affecting the rest of its pool.

Signals are written by one-shot runs (`afk -p`) today, under a short lock so runs that fail at the same time don't lose each other's marks. A truncated or hand-edited signals file is ignored rather than breaking routing.

## Seeing it

`afk pools` lists every pool with its state and, when its CLI reported one, how much is left and how that was found; otherwise `usage unknown`, `not signed in` or `set aside by a failed run`. Under a measured pool with a 5-hour or weekly window it shows where the window is heading at the rate so far, projected from when the reading was taken (in the first 10% of a window it says it is too early), for example `weekly window resets in 9h with ~58% unused at this rate` or `5h window runs out 16:40 at this rate, before it resets in 3h`, and, with [plan pacing](routing.md#plan-pacing) on, how much that moves routing. `afk pools --json` prints the [pools document](../reference/json.md#pools-afk-router-pools5), with `pacing` per pool.

`afk --explain` shows each route's pool, its state and its headroom when reported (`usage unknown` otherwise); `--explain --json` has every figure, with the source in `pool_quota_source`. The receipt shows the pool before and after a session only when both are reported readings.

In the TUI, the status line under the input shows each route's logo with `NN% left` or `usage unknown`, and the Usage tab lists each plan's 5-hour and weekly figures the same way.

## Privacy

Sign-in checks never open a credential file: they look only at whether login files exist, their size and when they changed. The only thing that reads a login is the vendor usage lookup, for a CLI you turned it on for. See [security and privacy](../security.md).
