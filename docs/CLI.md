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
| `--` | pass everything after it to the CLI unchanged, e.g. `afk --harness claude -- --continue` |

Reviews never go to a free or local model, the same reviewer floor the factory uses.

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
