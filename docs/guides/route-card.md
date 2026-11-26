# The route card

Run `afk` with a prompt at a terminal and AFK shows the route card before anything starts:

```sh
afk "make the settings page responsive"
```

<p align="center"><img src="../assets/route-card.png" alt="The route card" width="640"></p>

The top box is the pick: the CLI, model and effort, the kind of task (and whether AFK guessed it), why this route, and how much of its 5-hour pool is left. Below it is the best route on every other installed CLI, with its model, effort, score, pool headroom and cost.

## Keys

| Key | Does |
|---|---|
| `↵` | start the selected route |
| `↑` `↓` or `j` `k` | pick another row |
| `tab` | step through the effort levels that CLI accepts |
| `e` | edit the prompt; `↵` routes it again, `esc` goes back |
| `y` `y` | yolo: the CLI acts without asking (press twice; a red tag shows it is on, `y` again turns it off). Only in a [trusted](permissions.md#yolo-stays-deliberate) git repository; an interactive OpenCode session keeps its own prompts. The box shows the [permission mode](permissions.md) when it isn't `ask`, and a line when the selected CLI runs a stricter one |
| `?` | the Why panel; `?` again closes it |
| `esc` or `ctrl+c` | cancel; nothing is started (exit code 130) |

`w` (where to run) only offers this terminal for now, and `m` (a model picker) is not there yet; both say so when pressed.

`-y` or `--yes` skips the card and starts the router's pick.

## The Why panel

`?` shows the reasoning behind the selected row:

<p align="center"><img src="../assets/why.png" alt="The Why panel" width="640"></p>

- **task class**: the benchmark class the task is scored on, with the stage and risk it came from
- **benchmark**: the score used and its basis: `measured` (read from a public board), `capped`, `estimate` (a catalog figure) or `stale` (a measurement older than two weeks)
- **pool factor**: how much of the 5-hour window is left, and the pool state
- **cost class**: subscription, free, local or metered
- **effort**: the effort and, when it was raised, why
- **effective**: the final score the routes are ranked by

## When a route can't start

If the chosen route can't be launched (for example a gateway route with no key set), the card says why. `r` retries, `↵` starts the next best route when there is one, `esc` cancels. If routing itself fails or times out, `r` routes again.

## During the session

The chosen CLI runs as a child of `afk` and owns the terminal: you are in its own interface, with nothing wrapped around it. AFK waits until it exits.

## The receipt

When the CLI exits, Esc comes back with a receipt:

<p align="center"><img src="../assets/receipt.png" alt="The receipt" width="640"></p>

- exit status and how long the session took
- the pool's headroom before and after
- files changed and commits, when you were in a git repository

Values AFK can't know show as `n/e`, never as zero. Then it asks how it went: `1` solved, `2` partly, `3` wrong pick, `↵` to skip. The answer is saved with the [run record](runs.md).

## Narrow and plain terminals

Below 40 columns, or with `TERM=dumb`, there is no card: AFK prints one line with its pick and starts it, then a plain receipt and the rating question. Without a terminal at all (a pipe, a redirect or a script), it starts the pick the same way, prints the receipt to stderr, and never waits for a rating; the run is saved without one.

Colour and animation follow your terminal: `NO_COLOR`, `TERM=dumb` or `AFK_MOTION=off` turn animation off, and over SSH the card redraws less often.
