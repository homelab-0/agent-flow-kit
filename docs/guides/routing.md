# How routing works

For every task AFK asks one question: of the models the installed CLIs can run right now, which is the best fit for this kind of work, given how much is left on each plan and what it costs? The answer is one route: a CLI, a model and an effort.

Routing runs locally in the `afk` binary and takes a fraction of a second. Nothing is sent anywhere except the usage checks described in [pools](pools.md).

## 1. The kind of task

Every route starts from a task kind. Give it with `--task`, or let AFK guess from the prompt.

| Task | Guessed from words like | Scored as |
|---|---|---|
| `coding` (default) | anything else | standard coding |
| `quick` | rename, typo, format, lint, bump, small, one-liner, comment | standard coding, free and local models first |
| `complex` | refactor, migrate, rewrite, debug, race condition, deadlock, performance, optimise, concurrency, memory leak | complex coding |
| `review` | review, audit, look over, critique | code review |
| `architecture` | architect, design doc, system design, plan out, roadmap, PRD, spec out | architecture |
| `webdev` | CSS, HTML, frontend, React, Vue, Svelte, Tailwind, UI, UX, component, responsive | web development |
| `research` | research, compare, explain, what is, why does, how does, summarise, investigate | research |
| `security` | security, vulnerability, CVE, exploit, threat model, pentest, XSS, CSRF, SQL/command/prompt injection, secret leak | security review |

Words match at the start of a word, so "optimizing" counts as optimise. A prompt that asks for a change (fix, patch, add, implement, write, build, create, make, update, change, remove, delete, port, wire) is never taken as research. `--explain` tells you when the kind was guessed.

## 2. Your preference

`--prefer` shifts the balance:

- `balanced` (default): best score for the work, weighed against pool headroom.
- `cheap`: free and local models first. `quick` tasks always behave this way.
- `best`: the strongest model the kind allows (treated as high-risk work). Ignored for `quick`.

## 3. Who may take the work

A model is only considered when all of these hold:

- Its CLI is installed and answers `--version`.
- Its pool isn't exhausted (90% or more used), offline, or waiting for a sign-in.
- The model hasn't failed recently with "not found" or "no access" (it is set aside for an hour).
- **The CLI can reach the model.** A plan model on another vendor's CLI (OpenCode or Pi with a Claude, ChatGPT or xAI plan, say) counts only when that CLI is signed in to the plan. Which CLIs you use with which logins is up to you; AFK doesn't police it.
- **A plan never goes through a gateway.** This is credential safety: a gateway is someone else's server, so gateway routes run only on `claude`, with the gateway's own key and your plan login kept out (see [gateways](gateways.md)). A gateway model counts only while the gateway is up and lists it.
- **Reviews never go to a free or local model**, unless a project opts in (`allow_free_reviewers`).
- Metered pay-per-token API models are skipped unless allowed (`allow_metered_api`).
- Specialist security models are considered only when you are entitled to them (`security_models`).
- With `--harness`, only that CLI.

## 4. The score

Each remaining model starts from its benchmark score for the task class (see the [benchmark catalog](../reference/benchmark-catalog.md)) and is adjusted:

| Adjustment | Amount |
|---|---|
| Pool headroom | + headroom % × 0.02 (up to +2) |
| Pool size left | + min(sessions left in the 5-hour window, 60) × 0.025 (up to +1.5) |
| Pool in warning (75–90% used), low or medium risk | −15 |
| Free model, low-risk coding or research, when cheap is preferred or every plan is under pressure | +14 |
| Local or gateway model, low-risk coding or research | +6.5 |
| Frontier-only model (kept for the hardest work) on anything less | −6 |
| Specialist security model: on security work / on anything else | +4 / −15 |
| A third-party CLI using a vendor login | −0.5 |
| Your ratings of this CLI and model on this task class (below) | −8 to +6 |
| [Plan pacing](#plan-pacing): a measured window heading for a reset with quota unused, or running out before its reset | −4 to +4 |

### Your ratings

When a session ends, the receipt asks how it went: solved, partly, or wrong pick. Those ratings count toward the score of that CLI and model on that task class, once there are at least 2 of them:

- solved is 1, partly is ½, and wrong pick is 0. A success rate of 60% leaves the score as it is.
- The effect grows with the number of ratings: weight n / (n + 4), times 20 points per unit of success rate above or below 60%. It is capped at +6 and −8, so ratings steer between models that are close but don't override the benchmarks.
- Only the newest 30 ratings per route count, and none older than 180 days.
- Skipped ratings, one-shot runs (they have no receipt) and a wrong pick on a route you pinned yourself don't count.

`--explain` shows the effect in `outcome_runs` and `outcome_adjustment`, and in the reason line (`your ratings: 4 solved, 1 partly, 0 wrong pick of 5; +3.3`). Set `route.learn = false` (or `AFK_ROUTER_LEARN=0`) to route on benchmarks only. A project can't change it.

### Plan pacing

A flat-rate window that resets with quota left is quota you paid for and didn't use, and one that runs dry before its reset stops your work. When a pool's figure is measured (Codex, and Claude after an `afk -p` run), AFK projects where the window ends at the rate used so far:

- **Heading for unused quota**: routes on that plan gain up to +4, more the closer the reset and the more would be lost (full weight at half the window unused).
- **Running out before the reset**: routes on that plan lose up to −4, more the longer the plan would sit empty.
- Nothing is projected in the first 10% of a window, for an estimated pool, or for a spent one (its state already rules it out).

`afk pools` shows the projection per pool (`weekly window resets in 9h with ~58% unused at this rate`). `--explain` adds it to the reason line (`pacing: ...; +3.8`), and `--explain --json` has `pacing` and `pacing_adjustment`. Set `route.pacing = false` (or `AFK_ROUTER_PACING=0`) to keep the projection on show without it moving scores. A project can't change it.

The highest effective score wins; ties keep catalog order. `--explain` prints the effective score for the pick and the best route on each installed CLI.

## 5. The effort

Effort starts from the task class and is clamped to what the chosen CLI supports:

- `low`-risk coding and research: medium
- complex coding, architecture, security, or anything high-risk: high
- critical work: xhigh
- otherwise: the model's own default from the catalog

When the exact level isn't supported, AFK takes the nearest one, the higher one on a tie. `--effort` (or `tab` on the route card) overrides it.

## Pinning

- `--harness <cli>`: route among that CLI's models only.
- `--model <id>`: use this model. Without `--harness`, AFK looks up which installed CLI serves it; if more than one does, it asks you to choose.
- `--harness` and `--model` together skip the router entirely.

## When nothing qualifies

If no model passes the rules, AFK says the router found no usable model for the task and exits with code 4, rather than starting something that would fail or showing made-up numbers. The message names each plan that was set aside and why, for example:

```text
afk: the router found no usable model for this task on claude; anthropic-max is exhausted (100% used, runtime_signal:quota): a run failed with "429 Too Many Requests"; if that was wrong, run: afk pools clear anthropic-max. To use a set-aside plan anyway, pin it with --harness and --model
```

A pool waiting for a sign-in gets the sign-in command instead. Pinning a route with `--harness` and `--model` skips the router, so you can still use a plan AFK thinks is spent.

## Project settings

A project can tune routing in `.afk/config.json` (`--repo <dir>` picks which project). See [configuration](../reference/configuration.md#project-settings).
