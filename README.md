# agent-flow-kit

A portable autonomous development flow for **any BMAD project**, driven by the central AI Control Plane and executed through visible Orca workers.

The routing boundary is unchanged: `/v1/route` is the sole routing authority; the accepted decision is frozen into an immutable stamp; placement is late-bound per attempt; `agent-stamp-validate` checks the final stamp immediately before launch; Orca owns worktrees, terminals, processes, sessions, and native provider authentication; deterministic gates decide whether work is done.

## Fleet lifecycle

GitHub is the synchronization authority. Existing Orca development hosts keep a normal clone of this repository and converge their installed automation from that checkout.

```bash
cd agent-flow-kit

# Inspect checkout/install drift. Add --fetch to refresh the upstream ref.
./bin/agent-flow-kit status --fetch

# First adoption, including safe adoption of a known stale canonical install.
./bin/agent-flow-kit adopt

# Register/verify an already-wired BMAD target repository.
./bin/agent-flow-kit adopt --target /path/to/bmad-project

# After a PR is merged here:
git pull
./bin/agent-flow-kit update
./bin/agent-flow-kit verify
```

`update` is intentionally not `git pull`: Git remains the distribution mechanism and the lifecycle command only reconciles the current checked-out revision. Re-running `update` when current is a no-op.

## Ownership model

The lifecycle distinguishes four kinds of installed state:

- **Managed copy** — `model-router` canonical content (excluding its launcher config) and `humanizer`. If the installed canonical hash differs from the last applied hash, update refuses instead of overwriting it.
- **Managed section** — the agent-flow-kit policy blocks inside `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`. Deterministic markers let updates replace only kit-owned content and preserve unrelated machine/user content.
- **Machine-local configuration** — `~/.agents/skills/model-router/subscriptions.yaml`. It is seeded on first adoption and then preserved byte-for-byte across canonical updates. It may name endpoint/path/env-var/binary facts but contains no secrets and is not a routing authority.
- **Target-repo wiring** — BMAD story template/persona wiring belongs to each target repository. The kit records target paths and verifies the frozen `stamp`/`persona`/non-empty-gates/cycle surface separately from global installation.

The Claude skill links are recorded as managed links. Details and state schema are in [`docs/FLEET-LIFECYCLE.md`](docs/FLEET-LIFECYCLE.md).

## Installed-state and drift

The default state file is:

```text
${XDG_STATE_HOME:-~/.local/state}/agent-flow-kit/state.json
```

It records the last successfully applied kit revision, installed component ownership modes, expected canonical hashes, machine-local config path, and registered BMAD repositories. It stores no credentials or routing policy.

`status` reports component-level conditions including `CURRENT`, `UPDATE_AVAILABLE`, `LOCAL_DRIFT`, `LOCAL_ADAPTATION`, `NEEDS_OWNER`, `BROKEN`, and `UNKNOWN`/legacy state. A legacy install with no manifest is only auto-adopted when its managed bytes exactly match a canonical revision reachable in this repository's Git history.

## Contents

- `bin/agent-flow-kit` — the single lifecycle entrypoint: `status`, `adopt`, `update`, `verify`.
- `HANDOFF.md` — Claude/Codex-neutral adoption and target-wiring runbook built around the lifecycle entrypoint.
- `docs/FLEET-LIFECYCLE.md` — ownership, manifest, drift, validator boundary, and update semantics.
- `files/model-router/` — route/stamp/validate/place/dispatch skill and runtime scripts.
- `files/humanizer/` — required prose humanizer skill used by the PR language policy.
- `files/claude-global-CLAUDE.md` — canonical Claude policy source; only the flow-owned policy payload is installed.
- `files/codex-AGENTS.md` — canonical Codex policy source installed as a managed section.
- `tests/run-tests.sh` — frozen route/stamp/dispatch contract and refusal-path tests.
- `tests/lifecycle-tests.sh` — fleet lifecycle/drift/update tests.

## Tests

```bash
tests/run-tests.sh
tests/lifecycle-tests.sh
```

The first suite preserves the 35.27A orchestration contracts. The second suite proves first adoption, stale-known legacy adoption, update detection, safe managed-copy/managed-section updates, local-config preservation, target detection, failed-update behavior, drift refusal, idempotence, and missing validator/client reporting.

## Validator/client boundary

`agent-flow-kit` consumes `agent-stamp-validate` as an external AI Control Plane client/validator artifact. It does **not** clone prox-ops or compile router source as part of adoption/update. For the current POC, an existing fleet-installed validator is supported when it exposes the frozen `--catalog` + `--stamp` CLI contract; absence or incompatible CLI shape is surfaced as `NEEDS_OWNER`. Packaging/versioning that binary belongs to the future standalone AI Control Plane release process.

## Update discipline

This repository is the canonical automation distribution channel. Merge here, pull on fleet hosts, then run `update` and `verify`. Keep machine-specific facts in the machine-local launcher config, keep secrets out of this repository and the manifest, and never use fleet synchronization as an excuse to alter routing, validation, billing, or Orca authority boundaries.
