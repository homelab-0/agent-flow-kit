# One-shot answers (`-p`)

`afk -p` runs the chosen CLI headless, prints its answer, and exits. It's for scripts, editors and quick questions.

```sh
afk -p "what does internal/router/select.go do?"
echo "summarise this" | afk -p --task research
afk -p --json "list the TODOs in cmd/"
```

The prompt comes from the arguments, or from stdin when there are none. The CLI runs with stdin closed, in the current directory, and nothing is recorded as a [run](runs.md). The composer runs a task the same way when you press `↵` (see [running a task here](route-card.md#running-a-task-here)), and there each turn is recorded.

## Failover

If the CLI can't be started, exits with an error, or reports one in its JSON, AFK asks the router again and tries the next best route, up to three attempts. What the failure says decides what happens next:

- a sign-in, quota or rate-limit failure [sets the pool aside](pools.md#failure-signals), so the router picks from another pool;
- a model the provider refuses ("model not found", "no access") is set aside on its own for an hour;
- any other failure keeps the rest of this run away from that CLI.

The first two are written to the signals file, so the next `afk` run (and the route card) avoids them too. A route this run already tried is never tried again.

Every route runs in the same working copy; there are no separate worktrees yet. If a route edited files before it failed, the next route starts from those edits, and in a git repository AFK says so on stderr:

```text
afk: claude/opus failed (pool); trying codex / sol
afk: claude/opus left 3 changed files in the working copy; codex / sol starts from them
```

The count covers files changed since the run began: files that were already modified and didn't change again aren't counted. Set `route.failover = "none"` (below) when a half-finished edit shouldn't be handed on.

The run stops when:

- a CLI answers;
- `--harness` or `--model` was given: a failure is reported, not moved elsewhere (it is still recorded for the router);
- three routes have failed;
- no other installed CLI can do the task;
- you press Ctrl-C (the CLI is interrupted and `afk` exits with 130).

### Choosing where a failed run may go

Failover can send your prompt, and what the CLI reads from the project, to a different vendor than the first route's. That is the point of it, and each move is announced on stderr, but in a script nobody may be reading. `route.failover` in your `config.toml` (or `AFK_ROUTER_FAILOVER`) sets the limit:

| Value | A failed run |
|---|---|
| `any` (default) | goes to the next best route, on any CLI |
| `same-pool` | tries another model on the same CLI and plan, so the prompt reaches no other account; a gateway model on the same CLI counts as another pool |
| `none` | is reported, as with `--harness` or `--model` |

A project's `.afk/config.json` can't set it. Failures are recorded for the router whatever the setting.

Each CLI is run with JSON output, so errors reported with exit code 0 are still caught. Codex writes its answer to a temporary file, which AFK reads and removes.

## Output

Plain: the answer on stdout; a line on stderr for each failover (`afk: claude/sonnet failed (pool); trying codex / gpt-6.1-sol`) and, when every attempt failed, the reason.

With `--json`, one line:

```json
{"ok":true,"harness":"claude","model":"sonnet","effort":"medium","attempts":1,"output":"..."}
```

or, when every attempt failed:

```json
{"ok":false,"tried":"claude/sonnet, codex/gpt-6.1-sol","exit":1,"error":"..."}
```

`effort` is `null` when the CLI's default was used. `error` is the last failure's text, at most 600 bytes. The line has no `schema` field; its shape is the one above.

Exit code 0 means an answer was printed; 5 means every attempt failed; 2, 3 and 4 are the usual usage, not-installed and no-route errors before anything ran. See [exit codes](../reference/cli.md#exit-codes).
