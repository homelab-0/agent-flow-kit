# Command line

```text
afk [options] [prompt...]          start an interactive session (route card)
afk -p [options] prompt...         print one answer and exit
afk --explain [options] [prompt]   show the choice and the alternatives
afk --launch-plan --route <json>   print the launch plan for a route
afk harness [--all] [--json]       the agent CLIs found on this machine
afk harness doctor|login|add|update|remove <name>   check, sign in, install
afk harness update --all            update every installed CLI with something newer
afk bench sync [--json]            refresh the benchmark catalog now
afk skills status|sync|diff|keep|restore|enable|disable|new   your skills in every CLI
afk mcp status|sync|test|keep|restore|enable|disable|edit|path   your MCP servers in every CLI
afk status [--tab <tab>]           the control panel on its own
afk update [--check] [-y] [--dry-run]   update afk itself, the way it was installed
afk config get|set|edit|path|migrate   your settings (config.toml)
afk trust add|list|remove [dir]    where yolo may run
afk pools [--json]                 each pool's state, what's left, and its pacing
afk pools clear [pool...]          forget recorded pool failures
afk --help
```

A prompt that starts with the word `harness`, `bench`, `config`, `trust`, `pools`, `skills`, `mcp` or `status` needs `--` before it.

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

## `afk pools`

`afk pools` lists each plan and gateway pool: its state and, when its CLI reported one, how much is left and where that figure came from (`usage unknown` otherwise; AFK never estimates). Under a measured pool whose window is 5 hours or a week, a second line says where its window is heading (or that it is too early in the window to say) at the rate so far, and how much [plan pacing](../guides/routing.md#plan-pacing) moves routing because of it. `--json` prints the [pools document](json.md#pools-afk-router-pools5), with every figure and each pool's `pacing`.

## `afk pools clear`

`afk pools clear [<pool>...]` forgets the recorded failures for the named pools, so routing uses them again at once. With no pool named it clears every pool mark and every model mark. Takes `--dry-run` and `--json` (`{"cleared": [...], "dry_run": ..., "signals": "<path>"}`; models are listed as `model:<id>`). See [failure signals](../guides/pools.md#failure-signals).

## `afk config`

See [afk config](configuration.md#afk-config): `path`, `get`, `set`, `edit` and `migrate`. Every subcommand takes `--json` except `edit`, and `set` and `migrate` take `--dry-run`. Exit status: 0 done, 1 the file doesn't validate or couldn't be written, 2 a usage error.

## `afk bench sync`

Refreshes `~/.config/afk/benchmarks.json` from the public leaderboards; see [refreshing the catalog](benchmark-catalog.md#refreshing-it).

| Option | Meaning |
|---|---|
| `--json` | print the receipt, schema `afk-benchmark-sync/3` |

It exits 0 when at least one leaderboard was read, 3 when none was reachable (the previous catalog is kept), and 1 when the catalog could not be written.

## `afk skills`

See [Skills](../guides/skills.md#commands). `status` and `sync` take `--json` (schemas `afk-skills/1` and `afk-skills-sync/1`), and `sync` takes `--dry-run`. Exit status: 0 done, 1 a change failed (everything it made was put back), 2 a usage error.

## `afk mcp`

See [MCP servers](../guides/mcp.md#commands). `status`, `sync` and `test` take `--json` (schemas `afk-mcp/1`, `afk-mcp-sync/1` and `afk-mcp-test/1`), and `sync` takes `--dry-run`. Exit status: 0 done, 1 a change or test failed (a failed sync puts every file back), 2 a usage error.

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
| 130 | cancelled on the route card of `afk "prompt"`, left the composer before running anything, or `-p` interrupted |

After an interactive session AFK goes back to its composer instead of exiting; leaving it after at least one session exits 0. With `--yes`, `afk` exits with the CLI's own exit code as soon as the CLI ends.
