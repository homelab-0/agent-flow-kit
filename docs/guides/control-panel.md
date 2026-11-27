# The control panel

The control panel is AFK's full-screen management view. Tabs run across the top: Route, Harnesses, Benchmarks, Skills, MCP, Runs and Config.

Open it from the composer (plain `afk`): on an empty input press `2` to `7`, or type `/harnesses`, `/bench`, `/skills`, `/mcp`, `/runs` or `/config`. `1` or `esc` takes you back to the composer. `afk status` opens it on its own, on the Runs tab (`afk status --tab bench` picks another), and there `1`, `esc` or `q` quits.

| Key | Does |
|---|---|
| `1`–`7`, `tab` / `shift+tab` | switch tabs (`1` is Route) |
| `↑` `↓` or `j` `k` | pick a row |
| `/` | filter the tab's rows by name: type, then `↵` to keep the filter or `esc` to clear it. Each tab keeps its own filter, and `esc` clears it before it leaves the panel. |
| `r` | load the tab again |
| `q` | quit |

Nothing changes until you press an action key. Each action runs the matching `afk` command in the terminal, then the tab reloads.

## Harnesses

Every agent CLI AFK supports, installed ones first, with:

- its version
- its sign-in: `signed in` or `signed out` from the CLI's own status command where it has one, else `login on disk` (a login file exists; AFK never reads what's in it and can't confirm it still works)
- what it can be routed to: `plan`, `gw` (the model gateway), `local` (a [local engine](local-models.md))
- the command that updates it

The selected CLI shows its path, how it was installed, the models it runs and how much of its plan is left.

`u` updates it (`afk harness update`), `l` signs in (`afk harness login`), `d` runs `afk harness doctor`.

## Benchmarks

The models you can reach for one kind of task, best first. Each row shows:

- the routes that serve it, by logo
- the score as a bar
- the basis: `measured`, `capped`, `estimate` or `stale`
- your own ratings of past runs: `✓` solved, `~` partly, `✗` wrong pick

"Effective today" is the score each CLI's best route actually gets now, after plan headroom and cost. It is the number the route card ranks by.

`←` `→` switch the task kind. `s` refreshes the catalog (`afk bench sync`).

## Runs

- **Plans**: each installed CLI's plan, with what is left of the 5-hour window and the week as the CLI reported it (`unknown` when it hasn't: AFK never estimates), and its sign-in as on the Harnesses tab. A plan a failed run set aside says so, why, and for how long; `c` clears those marks.
- **Gateway and local engines**: the model gateway (up or down, its models, the engine behind it from config) and every local engine found, with its state and GPU.
- **Runs**: the last 15 sessions from the [run records](runs.md), with where they ran, the CLI, the outcome and how long they took.

## Config

The settings in effect and the path of `config.toml`. `e` opens it in your editor (`afk config edit`). Warnings from the file show at the bottom.

## Skills

Every central skill in every CLI, with drift shown per CLI. See [Skills](skills.md#the-skills-tab).

## MCP

Every server in `mcp.toml` in every CLI, with its tools and health from the last test. See [MCP servers](mcp.md#the-mcp-tab).
