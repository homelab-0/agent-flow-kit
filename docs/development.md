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

## Commit and PR conventions

- One concern per pull request, with tests.
- Conventional commit subjects (`feat(router): ...`, `fix(harness): ...`, `docs: ...`).
- Never commit secrets, and never let a test depend on a real login or a network call.
- Update the docs in `docs/` in the same pull request as the behaviour they describe.
