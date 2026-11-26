# Command line

```text
afk [options] [prompt...]          start an interactive session (route card)
afk -p [options] prompt...         print one answer and exit
afk --explain [options] [prompt]   show the choice and the alternatives
afk --launch-plan --route <json>   print the launch plan for a route
afk harness [--all] [--json]       the agent CLIs found on this machine
afk bench sync [--json]            refresh the benchmark catalog now
afk --help
```

A prompt that starts with the word `harness` or `bench` needs `--` before it.

## Options

| Option | Meaning |
|---|---|
| `-p`, `--print` | one-shot: run headless and print the answer; see [print mode](../guides/print-mode.md) |
| `--prompt <text>` | the prompt, in addition to (after) any words on the command line |
| `--task <kind>` | `coding` (default), `quick`, `complex`, `review`, `architecture`, `webdev`, `research`, `security`; guessed from the prompt when not given |
| `--prefer <mode>` | `balanced` (default), `cheap`, `best` |
| `--harness <cli>` | only this CLI: `claude`, `codex`, `opencode`, `grok`, `agy`, `pi` |
| `--model <id>` | this model; without `--harness`, the CLI that serves it is looked up |
| `--effort <level>` | `low`, `medium` or `high` |
| `--repo <dir>` | the project whose `.afk/config.json` applies (default: the current directory); the CLI still starts in the current directory |
| `--explain`, `--dry-run` | show the decision; start nothing |
| `--json` | machine-readable output for `--explain` and `-p` |
| `--yolo` | let the CLI act without asking; see [permissions](../guides/permissions.md) |
| `--pass <arg>` | pass one argument to the CLI unchanged; repeat for more. For opencode, a model can't be passed this way |
| `-y`, `--yes` | skip the route card and start the pick |
| `--launch-plan` | print a launch plan; with `--route <json or ->` and `--mode interactive\|print` |
| `--` | everything after it is the prompt, even if it starts with a dash |
| `-h`, `--help` | the help |

Options that take a value also accept `--option=value`.

## `afk harness`

| Option | Meaning |
|---|---|
| `--all`, `-a` | also list supported CLIs that are not installed |
| `--json` | machine-readable output, schema `afk-harnesses/3` |

## `afk bench sync`

Refreshes `~/.config/afk/benchmarks.json` from the public leaderboards; see [refreshing the catalog](benchmark-catalog.md#refreshing-it).

| Option | Meaning |
|---|---|
| `--json` | print the receipt, schema `afk-benchmark-sync/3` |

It exits 0 when at least one leaderboard was read, 3 when none was reachable (the previous catalog is kept), and 1 when the catalog could not be written.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | done |
| 1 | an internal failure |
| 2 | a usage error: unknown option, bad value, a model served by more than one CLI |
| 3 | the CLI asked for isn't installed, or none is |
| 4 | nothing usable for this task, or the route can't be launched |
| 5 | `-p`: every attempt failed |
| 127 | the CLI couldn't be started |
| 130 | cancelled on the route card, or `-p` interrupted |

After an interactive session, `afk` exits with the CLI's own exit code.
