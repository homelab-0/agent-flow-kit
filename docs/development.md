# Development

## Layout

```text
cmd/afk/            the afk command: arguments, the Go engine paths, afk harness
internal/cli/       command-line parsing
internal/harness/   the agent CLI registry: discovery, versions, sign-in, install methods
internal/router/    route selection, the benchmark catalog, pool probes
internal/core/      the Go engine: explain, launch plans, pools
internal/tui/       the route card, Why panel, receipt and rating (Bubble Tea)
internal/launch/    starting a plan as a foreground child
internal/runrec/    run records
internal/gitstat/   files changed and commits for the receipt
internal/engine/    route and plan types, and the client for the bash engine
bin/, lib/          the bash engine and the legacy lifecycle kit
```

## Build and test

```sh
go vet ./...
go test ./...
CGO_ENABLED=0 go build -o /tmp/afk ./cmd/afk
```

Tests run offline and never start a real agent CLI or contact a provider: CLIs are shell stubs in temporary directories, and network calls go to `httptest` servers.

## Parity with the bash engine

While the bash engine still exists, the Go engine is checked against it:

- **Routing**: [`internal/router/testdata/gen-golden.sh`](../internal/router/testdata/gen-golden.sh) runs the bash router over every scenario in `scenarios.json`, with the pools in `probes.json` and the models in `discovered.json`, and writes `golden.json`. `TestGoldenMatchesBashRouter` requires the Go router to match every field. Add a scenario, rerun the script (needs `bash` and `jq`), and commit both files.
- **Launch plans**: `internal/core/testdata/plans.json` holds the bash engine's plan for each case; `TestLaunchPlansMatchBash` compares them.
- **Pool probe**: `TestProbePoolsMatchesBashProbe` rebuilds a home directory the bash probe was run against and asserts its figures.

### Deliberate differences from the bash engine

The Go engine fixes some things the bash engine gets wrong, so on these points the two disagree on purpose:

- Codex's sessions are read from `$CODEX_HOME/sessions` when set (and `AFK_CODEX_SESSIONS_DIR` first), for both rate limits and activity. The Orca `codex-accounts` directories are not read.
- Codex signed in with an API key is metered usage: its sessions don't count against the ChatGPT plan pool.
- A project's `.afk/config.json` can set the gateway only when the project is listed in `trusted_repos`.
- A restricted model (Mythos, Daybreak Blue) that one CLI lists unlocks it for that CLI's account only.
- "patch" counts as asking for a change when guessing the task.
- A signals file that doesn't fully decode is ignored whole; a zero or negative pool capacity is skipped.
- A Claude usage answer with no figures isn't taken as 0%; the cached answer is tied to the login it was made with.
- The newest Codex rate-limit reading wins by when it was recorded, the last usable record in each file counts, and very long lines are skipped instead of ending the read.
- A gateway that answers with an HTTP error is offline.
- Without a terminal, `afk` never waits for a rating.

The parity fixtures don't cover these cases; each has its own test.

## Commit and PR conventions

- One concern per pull request, with tests.
- Conventional commit subjects (`feat(router): ...`, `fix(harness): ...`, `docs: ...`).
- Never commit secrets, and never let a test depend on a real login or a network call.
- Update the docs in `docs/` in the same pull request as the behaviour they describe.
