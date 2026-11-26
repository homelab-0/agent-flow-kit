# One-shot answers (`-p`)

`afk -p` runs the chosen CLI headless, prints its answer, and exits. It's for scripts, editors and quick questions.

```sh
afk -p "what does internal/router/select.go do?"
echo "summarise this" | afk -p --task research
afk -p --json "list the TODOs in cmd/"
```

> `-p` still runs on the bash engine in this repository while its failover is ported to Go. It needs `AFK_ENGINE` set; see [install](../getting-started/install.md#one-shot-answers--p).

The prompt comes from the arguments, or from stdin when there are none.

## Failover

If the CLI fails to start, or reports a sign-in, quota, rate-limit or model error, AFK tries the next best route, up to three attempts:

- a sign-in, quota or rate-limit failure [sets the pool aside](pools.md#failure-signals) for the router;
- a model refused by the provider is set aside for an hour;
- any other failure keeps this run away from that CLI.

With `--harness` or `--model`, a failure is reported, not moved elsewhere.

Each CLI is run with JSON output, so errors reported with exit code 0 are still caught.

## Output

Plain: the answer on stdout; AFK's notes about the route and any failover on stderr.

With `--json`, one line:

```json
{"ok":true,"harness":"claude","model":"sonnet","effort":"medium","attempts":1,"output":"..."}
```

or, when every attempt failed:

```json
{"ok":false,"tried":"claude/sonnet, codex/gpt-6.1-sol","exit":1,"error":"..."}
```

Exit code 0 means an answer was printed; 5 means every attempt failed. See [exit codes](../reference/cli.md#exit-codes).
