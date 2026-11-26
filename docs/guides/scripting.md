# Scripting AFK

Two commands give scripts and other front ends AFK's decisions without starting anything.

## `--explain --json`: the decision

```sh
afk --explain --json "fix the flaky retry test"
```

One JSON object (schema `afk-route-explain/1`): the task and whether it was guessed, the preference, the chosen route, and `by_harness`, the best route on each installed CLI sorted by score. Each route is complete, so a front end can launch any row it offers. See [JSON formats](../reference/json.md#explain-afk-route-explain1).

The same options as an interactive run apply: `--task`, `--prefer`, `--harness`, `--model`, `--effort`, `--repo`. With `--harness` and `--model` together the choice is pinned and `by_harness` is empty.

## `--launch-plan`: how to start a route

```sh
afk --explain --json "fix it" | jq -c .choice \
  | afk --launch-plan --route - --mode interactive -- "fix it"
```

Prints the launch plan (schema `afk-launch-plan/1`) for a route chosen elsewhere: the exact argv, the environment to set, copy and unset, the working directory, and where a one-shot answer will be. Nothing is started.

- `--route -` reads the route from stdin, so it never appears on a command line (a gateway address can carry user info). `--route '<json>'` also works.
- `--mode interactive` (default) or `--mode print`. A print plan needs a prompt.
- `--yolo` and `--pass <arg>` (repeatable) apply as they would to a launch.

A route that would send a plan login through a gateway is refused with `{"ok":false,"error":"..."}` and exit code 4. Any other route is planned as asked: which CLI runs which model is your choice.

### Applying a plan

To start a plan yourself, build the environment in this order:

1. read each `env_from` source variable from your environment (before anything is unset);
2. unset every name in `env_unset`;
3. set every `env_set` value (create `CLAUDE_CONFIG_DIR` with mode 700 if it's set);
4. set each `env_from` target to the value read in step 1.

Then run `argv` in `cwd`. Refuse to start if an `env_from` source is empty or names a vendor credential variable. `internal/launch` implements this for the Go front end.
