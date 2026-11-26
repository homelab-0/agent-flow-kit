# Development

## Layout

```text
cmd/afk/            the afk command: arguments, the Go engine paths, afk harness, afk bench
internal/cli/       command-line parsing
internal/harness/   the agent CLI registry: discovery, versions, sign-in, install methods
internal/router/    route selection, the benchmark catalog, pool probes
internal/core/      the Go engine: explain, launch plans, pools, -p
internal/oneshot/   -p: reading each CLI's answer, classifying failures, failover
internal/bench/     the benchmark sync and its daily refresh
internal/config/    config.toml (schema, precedence, comment-keeping edits), afk.lock, project settings
internal/statefile/ the lock and atomic write for the small state files
internal/tui/       the route card, Why panel, receipt and rating (Bubble Tea)
internal/launch/    starting a plan as a foreground child
internal/runrec/    run records
internal/gitstat/   files changed and commits for the receipt
internal/engine/    route, explain, launch-plan and pool types (the JSON contract)
```

## Build and test

```sh
go vet ./...
go test ./...
CGO_ENABLED=0 go build -o /tmp/afk ./cmd/afk
```

Tests run offline and never start a real agent CLI or contact a provider: CLIs are shell stubs in temporary directories, and network calls go to `httptest` servers.

## Parity fixtures

AFK started as a bash engine and lifecycle scripts, and the Go code was ported from them and checked against them. The bash code is gone; its last version is at the [`legacy-bash-final`](https://github.com/jlengelbrecht/agent-flow-kit/tree/legacy-bash-final) tag, for anyone who needs the old scripts. What it decided is kept as frozen fixtures, which can't be regenerated:

- **Routing**: `internal/router/testdata/golden.json` is the bash router's decision for every scenario in `scenarios.json`, with the pools in `probes.json` and the models in `discovered.json`. `TestGoldenMatchesBashRouter` requires the Go router to match every field. A new scenario needs its expected decision written by hand and checked.
- **Launch plans**: `internal/core/testdata/plans.json` holds the bash engine's plan for each case; `TestLaunchPlansMatchBash` compares them.
- **Pool probe**: `TestProbePoolsMatchesBashProbe` rebuilds a home directory the bash probe was run against and asserts its figures.
- **Benchmark sync**: `internal/bench/testdata/feeds` holds the leaderboard fixtures the bash sync's tests used, and `internal/bench` asserts the same scores. Run over the same base catalog and feeds, the two syncs write the same catalog apart from timestamps and the Artificial Analysis label.
- **One-shot answers**: `internal/oneshot/testdata` holds what each CLI prints in JSON mode for an answer and for the failures `-p` reacts to.

### Deliberate differences from the bash engine

The Go engine fixes some things the bash engine got wrong, so on these points the fixtures and the code disagree on purpose:

- Codex's sessions are read from `$CODEX_HOME/sessions` when set (and `AFK_CODEX_SESSIONS_DIR` first), for both rate limits and activity.
- Codex signed in with an API key is metered usage: its sessions don't count against the ChatGPT plan pool.
- A project's `.afk/config.json` can't set a gateway, metered models, free reviewers or security models at all, not even through its older `router` block.
- A restricted model (Mythos, Daybreak Blue) that one CLI lists unlocks it for that CLI's account only.
- "patch" counts as asking for a change when guessing the task.
- A signals file that doesn't fully decode is ignored whole; a zero or negative pool capacity is skipped.
- A Claude usage answer with no figures isn't taken as 0%; the cached answer is tied to the login it was made with.
- The newest Codex rate-limit reading wins by when it was recorded, the last usable record in each file counts, and very long lines are skipped instead of ending the read.
- A gateway that answers with an HTTP error is offline.
- Without a terminal, `afk` never waits for a rating.
- No plan-login policy: the bash engine kept each vendor's plan to its own CLI and OpenCode to its own free models, and never launched Pi. AFK routes to any installed CLI that is signed in to the model's plan, and launches Pi, in `-p` too. `golden.json` was recorded with those two rules removed from the bash router.
- `-p` never tries the same route twice in one run, even if the signals file couldn't be written; an `error` given as a plain string is read as the message.
- The benchmark sync doesn't read Artificial Analysis: it needs an API key, and AFK never sends one. Its receipt reports that feed as `not_used`. With the key unset the bash sync gave the same scores.

The parity fixtures don't cover these cases; each has its own test.

## Commit and PR conventions

- One concern per pull request, with tests.
- Conventional commit subjects (`feat(router): ...`, `fix(harness): ...`, `docs: ...`).
- Never commit secrets, and never let a test depend on a real login or a network call.
- Update the docs in `docs/` in the same pull request as the behaviour they describe.
