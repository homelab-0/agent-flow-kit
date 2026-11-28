# The control panel

The control panel is AFK's full-screen management view. The tabs run across the top with their number keys (`1 Route  2 Harnesses  3 Benchmarks  4 Skills  5 MCP  6 Usage  7 Config`), the open one underlined; under them a line says what the tab is for, and the bottom row shows the tab's keys and the panel's own.

Open it from the composer (plain `afk`): on an empty input press `2` to `7`, or type `/harnesses`, `/bench`, `/skills`, `/mcp`, `/usage` or `/config`. `1` or `esc` takes you back to the composer. `afk status` opens it on its own, on the Usage tab (`afk status --tab bench` picks another), and there `1`, `esc` or `q` quits.

| Key | Does |
|---|---|
| `1`–`7`, `tab` / `shift+tab` | switch tabs (`1` is Route) |
| `↑` `↓` or `j` `k` | pick a row |
| `/` | filter the tab's rows by name: type, then `↵` to keep the filter or `esc` to clear it. Each tab keeps its own filter, and `esc` clears it before it leaves the panel. |
| `ctrl+p` or `:` | the command palette: go to a tab, update every CLI or one, sign in to one, update AFK, sync benchmarks, edit `config.toml`. Type to narrow it, `↑` `↓` to pick, `↵` to run, `esc` to close |
| `r` | load the tab again |
| `q` | quit |

Nothing changes until you press an action key. Each action runs the matching `afk` command in the terminal, then the tab reloads.

## Harnesses

Every agent CLI AFK supports, in two groups: installed and not installed. Each installed one shows its logo, version and sign-in, with a dot for the sign-in state:

- green `signed in` (or the plan name): the CLI's own status command said so
- half `login on disk`: a login file exists, but the CLI has no status command, so AFK can't confirm it still works (AFK never reads what's in it)
- red `signed out` or `expired`
- hollow `not reported`

On a screen 96 columns or wider the selected CLI's details sit beside the list, otherwise under it: its version, how it was installed and where, its sign-in, what it can be routed to (`plan`, `gw` for the model gateway, `local` for a [local engine](local-models.md)), how much of its plan is left as the CLI reports it (`not reported` when it doesn't), the models it runs and the command that updates it.

`D` runs a discovery now (`afk harness scan`): AFK looks for every CLI again and asks each for its sign-in, plan, models and usage. The line above the list says whether auto discovery is on, and `A` turns it on or off (the `discovery.auto` setting, also on the Config tab). With it on, AFK asks a CLI again when its last answer is five minutes old; with it off, the last answer stays until the next `D`.

`u` updates the selected CLI (`afk harness update`), `U` updates every installed CLI that has something newer (`afk harness update --all`), `l` signs in (`afk harness login`), `d` runs `afk harness doctor`.

## Benchmarks

Which models score best for each kind of task, where the scores come from, and why AFK picks what it picks. It has three views; `[` and `]` switch between them, and `←` `→` switch the kind of task.

- **Leaderboard**: the models you can reach, best first. Each row shows the routes that serve the model (up to three logos), its score as a bar, the basis (`measured`, `capped`, `estimate` or `stale`) and your own ratings of past runs (`✓` solved, `~` partly, `✗` wrong pick). The line above names the benchmark behind the scores. The bars start a little under the lowest score shown, and the header says where, so close scores look different. A box under the list shows what AFK would pick right now, its effective score with the points added to the benchmark, and the runner-up.
- **Sources**: where the scores come from: LMArena's boards, models.dev (context windows), your ratings, AFK's built-in estimates, SWE-bench Verified, Aider Polyglot, Artificial Analysis and any leaderboard you added (`·yours`), with what each measures, its weight and which tasks use it. The box shows the last sync (and how many of AFK's models the board matched), the setting behind it and its weight. `space` turns a source on or off, `w` sets its weight (`2`, or `0.5 review` for one task), `a` adds a leaderboard of your own (`my-evals https://example.com/board.json complex,review`), `t` reads one now and shows what it matched, and `x` twice removes one you added. See [blending several sources](../reference/benchmark-catalog.md#blending-several-sources).
- **Why AFK picks**: the best route on each CLI for the task, ranked by effective score, with the benchmark score and the adjustment. The box breaks the selected route's score down part by part: each source in a blended benchmark score with its weight, then plan headroom, pacing, your ratings, and the other rules the router applies.

`s` refreshes the catalog (`afk bench sync`).

## Usage

What is left on each plan, gateways and local models, and what ran. It has three views; `[` and `]` switch between them.

- **Plans**: a card per installed CLI's plan, with the week and the 5-hour window as the CLI reported them, as bars with the % left and when the window resets. A window the CLI hasn't reported says `unknown`, since AFK never estimates. A plan whose CLI listed its limits without a 5-hour one says `no limit on this plan`. Under that is the pace (where the window is heading at the rate so far, and whether AFK leans toward the plan because quota would go unused), the sign-in, and how many runs used it today. `←` `→` pick a plan. Plans a failed run set aside are listed under the cards with why and for how long, and `c` clears those marks.
- **Gateways & local models**: the model gateway (up or down, its models, the engine behind it from config) and every local inference engine found (Ollama, llama.cpp, vLLM and the rest), with its state, GPU and models. An engine without the Anthropic Messages API is listed as `no API · needs a gateway`.
- **Run history**: the last 50 sessions from the [run records](runs.md): when each started, the CLI, model and effort, where it ran, how long it took, how it ended and your rating. The selected run's box adds how much of the plan it used (before and after) and what it changed (files and commits).

The tab was called Runs before; `/runs` and `afk status --tab runs` still open it.

## Config

The settings in effect and the path of `config.toml`, in groups (Routing, Permissions, Gateways, Local models, Agent CLIs, Benchmarks) with plain names. Switches show as `● on` or `○ off`, and the selected setting's key, what it does and its values are shown beside the list (under it on a terminal narrower than 96 columns). Change a setting right here: select its row and press `↵`.

| Setting | `↵` does |
|---|---|
| `route.prefer`, `route.failover`, `permissions.default` | steps to the next value (`←` steps back) and saves it |
| `route.learn`, `route.pacing`, `route.prefer_free`, `route.allow_metered`, `route.allow_free_reviewers`, `bench.autosync` | switches it on or off and saves it |
| `gateway.<name>.*`, `gateway (add)` | see [gateways](#gateways) below |
| `trust.repos` | opens an input with the current folders, separated by commas; `↵` saves, `esc` cancels |

AFK writes `config.toml` itself (creating it the first time) and keeps the file's comments and order, exactly as `afk config set` does. A value the file can't take is refused and nothing is written. The row then shows the setting in effect; when an `AFK_*` variable or the project's `.afk/config.json` still decides it, the save says so.

### Gateways

Each `[gateway.<name>]` in `config.toml` has its rows here, and the `gateway (add)` row makes a new one:

1. On `gateway (add)` press `↵` and type a name and the address, for example `work https://gw.example:4000`.
2. On `gateway.work.key` press `↵` and type where its key is: `env:NAME`, `file:/path`, `op://vault/item`, `keychain:NAME` or `cmd:...`. AFK stores the reference, never the key, and refuses anything that isn't a reference.
3. `gateway.work.default` picks the gateway AFK routes to when there are several. `kind`, `engine` and `host` are labels for the route card.

`x` on any of a gateway's rows removes that gateway from the file (press it twice). The `gateway` row above them is the one in effect, which can also come from `AFK_LITELLM_BASE_URL`.

`local.engines` switches between `auto` (AFK looks at the usual ports on this machine) and `off`. The two `harness.<name>.vendor_usage` rows are switches too: turning one on shows what it does and what it risks, and takes one more `↵` (see [the vendor usage lookup](pools.md#the-vendor-usage-lookup)).

Rows shown dim (the gateway in effect) have no form here yet. `e` opens `config.toml` in your editor for those (`afk config edit`). Warnings from the file show at the bottom.

## Skills

Every central skill in every CLI, with drift shown per CLI. See [Skills](skills.md#the-skills-tab).

## MCP

Every server in `mcp.toml` in every CLI, with its tools and health from the last test, and the servers you added to a CLI yourself, ready to import with `i`. See [MCP servers](mcp.md#the-mcp-tab).
