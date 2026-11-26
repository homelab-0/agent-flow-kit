# Command line

```text
afk [options] [prompt...]          start an interactive session (route card)
afk -p [options] prompt...         print one answer and exit
afk --explain [options] [prompt]   show the choice and the alternatives
afk --launch-plan --route <json>   print the launch plan for a route
afk harness [--all] [--json]       the agent CLIs found on this machine
afk harness doctor|login|add|update|remove <name>   check, sign in, install
afk bench sync [--json]            refresh the benchmark catalog now
afk config get|set|edit|path|migrate   your settings (config.toml)
afk trust add|list|remove [dir]    where yolo may run
afk --help
```

A prompt that starts with the word `harness`, `bench`, `config` or `trust` needs `--` before it.

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
| `--mode <mode>` | the [permission mode](../guides/permissions.md): `read-only`, `ask`, `edits`, `auto` or `yolo` |
| `--yolo` | the same as `--mode yolo`; only in a [trusted](../guides/permissions.md#yolo-stays-deliberate) git repository |
| `--pass <arg>` | pass one argument to the CLI unchanged; repeat for more. For opencode, a model can't be passed this way |
| `-y`, `--yes` | skip the route card and start the pick |
| `--launch-plan` | print a launch plan; with `--route <json or ->` and `--mode interactive\|print` (a permission-mode value of `--mode` sets the plan's mode) |
| `--` | everything after it is the prompt, even if it starts with a dash |
| `-h`, `--help` | the help |

Options that take a value also accept `--option=value`.

## `afk harness`

| Option | Meaning |
|---|---|
| `--all`, `-a` | also list supported CLIs that are not installed |
| `--json` | machine-readable output, schema `afk-harnesses/3` |

`afk harness doctor`, `login`, `add`, `update` and `remove` are described in [agent CLIs](../guides/harnesses.md#installing-and-updating-clis-from-afk). Their options: `--json`, `-y`/`--yes` (don't ask), `--dry-run` (show, run nothing), `--version <v>` (`add`), `--device` (`login`).

## `afk trust`

`afk trust add <dir>`, `afk trust list` and `afk trust remove <dir>`, each with `--json`; `add` and `remove` take `--dry-run`. See [yolo stays deliberate](../guides/permissions.md#yolo-stays-deliberate).

## `afk config`

See [afk config](configuration.md#afk-config): `path`, `get`, `set`, `edit` and `migrate`. Every subcommand takes `--json` except `edit`, and `set` and `migrate` take `--dry-run`. Exit status: 0 done, 1 the file doesn't validate or couldn't be written, 2 a usage error.

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
