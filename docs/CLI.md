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
| `--pass <arg>` | pass one argument to the CLI unchanged; repeat it for more, e.g. `afk --harness claude --pass --continue` |
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

## Not yet

- Switching model in the middle of a session. That needs `afk` to proxy the model API through LiteLLM rather than start a CLI.
- A Hermes adapter.
- Handing a session to another CLI when its pool runs out mid-session.
- Recording session outcomes in Langfuse for the learning loop shared with the factory.
