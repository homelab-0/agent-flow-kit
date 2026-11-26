# afk: the standalone route

`afk` is AFK's second route, alongside the [factory](FACTORY.md). You run it at a terminal. It picks the best agent CLI installed on this machine for what you're asking, and starts that CLI with the right model and effort. It routes the same way the factory does, on:

- the benchmark score for the kind of work
- how much is left in each subscription pool, from live usage where the provider reports it and recent activity otherwise
- cost: free and local models win quick tasks

It supports `claude`, `codex`, `opencode`, `grok` and `agy` (Antigravity). Only the installed ones are considered.

## Use

```
afk                                  # interactive session, task guessed as coding
afk "make the settings page responsive"   # interactive, starts with that prompt
afk -p "what does lib/afk-cli.sh do?"     # one answer printed, then exit
afk --explain "refactor the parser"       # what it would pick, and the best per CLI
```

The session itself is the chosen CLI's own interface. `afk` prints one line saying what it picked and why, then hands the terminal over.

| Option | Meaning |
|---|---|
| `-p`, `--print` | one-shot. The prompt comes from the arguments or from stdin. If the CLI fails to start, or reports a sign-in, quota, rate-limit or model error, the pool is marked and the next best CLI answers, up to three tries. |
| `--task <kind>` | `coding` (default), `quick`, `complex`, `review`, `architecture`, `webdev`, `research`, `security`. Without it, the kind is guessed from the prompt's words; `--explain` says when it guessed. |
| `--prefer <mode>` | `balanced` (default), `cheap` (free and local first), `best` (the strongest model for the kind) |
| `--harness <cli>` | only this CLI. With `-p`, a failure is reported, not moved elsewhere. |
| `--model <id>` | this model. With `--harness`, the router isn't consulted at all. |
| `--effort <level>` | `low`, `medium` or `high`, where the CLI supports it |
| `--repo <dir>` | whose `.afk/config.json` router settings apply (default: the current directory) |
| `--explain`, `--dry-run` | show the decision and the best route per installed CLI; start nothing |
| `--json` | machine-readable output for `--explain` and `-p` |
| `--yolo` | let the CLI act without asking, using that CLI's own skip-permissions flag. Off by default. |
| `--pass <arg>` | pass one argument to the CLI unchanged; repeat it for more, e.g. `afk --harness claude --pass --continue`. For opencode, a model flag (`-m`, `--model`) can't be passed this way; use `--model`, so the plan-login check sees it. |
| `--` | ends the options: everything after it is the prompt, even if it starts with a dash |
| `--launch-plan --route <json> [--mode interactive\|print]` | print the launch plan for a route chosen elsewhere (`afk-launch-plan/1`: argv, environment, answer format) and start nothing. `--route -` reads the route from stdin, so it stays off the command line. Front ends use this. |

Reviews never go to a free or local model, the same reviewer floor the factory uses.

## Plan logins and gateways

A plan login is only ever used by its own vendor's CLI. Claude's plan is used only in `claude`, ChatGPT's only in `codex`, SuperGrok's only in `grok`, and Antigravity's only in `agy`. AFK never routes a plan model through a gateway or a third-party CLI; opencode, for instance, only gets its own free models. This rule applies in the factory as well.

A gateway route, such as a local model behind LiteLLM, is launched only for `claude`, and in a way that keeps your Claude login away from the gateway:

- `ANTHROPIC_BASE_URL` points at the gateway (`AFK_LITELLM_BASE_URL`).
- `ANTHROPIC_AUTH_TOKEN` is copied from the gateway key variable: `AFK_GATEWAY_KEY`, or the variable named in `AFK_GATEWAY_KEY_ENV`. AFK never prints the key.
- The Claude config directory is separate, so the plan login isn't loaded.

With no gateway address or key, the route isn't launched, and AFK says what to set.

## How usage is counted

Sessions started through `afk` count against their pool automatically. The router reads each CLI's own session files and, for Claude, the live usage API. A one-shot failure marks the pool for a while, the same as in the factory: a day for a sign-in problem, an hour for quota, fifteen minutes otherwise.

## Install

`afk` ships in the AFK runtime's `bin` directory, next to `agent-flow-kit`; `agent-flow-kit agent` is the same command. To put it on your PATH:

```
ln -s ~/.agents/skills/afk-runtime/bin/afk ~/.local/bin/afk
```

## The route card (preview)

A Go front end for `afk` is being built in `cmd/afk`. It is not installed as `afk` yet; build it to try it:

```
CGO_ENABLED=0 go build -o ~/.local/bin/afk-next ./cmd/afk
afk-next "fix the flaky renovate test"
```

At a terminal it shows a route card before anything starts: the chosen CLI, model and effort, why it was chosen, how much of its 5-hour pool is left, and the best route for every other installed CLI.

| Key | Does |
|---|---|
| `↵` | start the selected route |
| `↑` `↓` or `j` `k` | pick another row |
| `tab` | change the effort, within what that CLI supports |
| `e` | edit the prompt and route again |
| `y` `y` | yolo: the CLI acts without asking (press twice; a red tag shows it is on) |
| `?` | why this route: benchmark, pool, cost and effort |
| `esc` | cancel; nothing is started |

`--yes` (or `-y`) skips the card and starts the router's choice. `w` (where) only offers this terminal for now, and `m` (model picker) is not there yet.

The CLI runs as a child of `afk-next` and owns the terminal while it runs. When it exits, `afk-next` prints a receipt (exit status, time, pool before and after, files changed and commits when you're in a git repository) and asks how it went: `1` solved, `2` partly, `3` wrong pick, `↵` skip. Each session is saved to `~/.config/afk/state/runs/<id>.json`. Values it can't know show as `n/e`, never as zero.

Routing, pool usage and launch plans run in Go (`internal/router`, `internal/core`), so the card, `--explain` (text and `--json`) and `--launch-plan` need no bash. They give the same answers as `agent-flow-kit agent`: the Go router is checked against the bash router on 104 fixed scenarios, every launch plan against the bash plans, and the pool probe against the bash probe on the same home. Without a terminal there is no card; the choice is started directly, as the bash `afk` does.

Only `-p` still runs `agent-flow-kit agent`, until its failover is ported. It finds the engine through `$AFK_ENGINE`, then next to itself, then on PATH. `AFK_BACKEND=bash` sends every call to the bash engine, as before. Animation is off with `NO_COLOR`, `TERM=dumb` or `AFK_MOTION=off`.

Not yet in Go: the daily benchmark sync from the public leaderboards (the Go router uses `~/.config/afk/benchmarks.json` when the bash engine has synced it, and the built-in catalog otherwise) and the model lists the CLIs report (`~/.config/afk/discovered-models.json`, read when present).

## Installed CLIs

```
afk-next harness            # the agent CLIs on this machine
afk-next harness --all      # also the supported ones that are not installed
afk-next harness --json     # schema afk-harnesses/3
```

This runs in Go and needs no bash engine. AFK knows claude, codex, opencode, grok, agy, gemini, copilot, cursor (`cursor-agent`), kiro (`kiro-cli`), qwen, kimi, pi and devin; each one is a single entry in `internal/harness/registry.go`. For every installed CLI it shows the version (each CLI is asked for `--version`, five seconds at most, all in parallel), how it was installed (mise, npm, bun, pnpm, Homebrew, uv, pipx, cargo or self-managed) with the command that updates it (also shown in the table), the effort levels it takes, and whether it looks signed in.

The sign-in check looks for a login on disk. For Claude, Codex and a few others it opens the credential file to see which login fields are set, but it never decodes, prints, logs or stores a token's value. A file AFK can't read shows as `unknown`, not signed out. It can't prove the login still works. Where AFK has no reliable check for a CLI, or the login lives in the macOS Keychain, it says `unknown`. `AFK_HARNESS_BIN_DIR` makes that directory the only place CLIs are looked for.

## Not yet

- Switching model in the middle of a session. That needs `afk` to proxy the model API through LiteLLM rather than start a CLI.
- A Hermes adapter.
- Handing a session to another CLI when its pool runs out mid-session.
- Recording session outcomes in Langfuse for the learning loop shared with the factory.
