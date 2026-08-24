# HANDOFF — adopt or update agent-flow-kit on this machine

This runbook is intentionally **Claude Code / Codex neutral**. The same repository and lifecycle are used regardless of which supported agent is driving the adoption session.

`agent-flow-kit` is the opt-in BMAD autonomous execution layer. Installing it does not automatically turn an interactive BMAD PM into an orchestration PM.

## Ground rules

- GitHub + the checked-out `agent-flow-kit` revision are the synchronization authority.
- `/v1/route` remains the sole routing authority. Do not add a local route table, model fallback chain, or task-to-provider rules during adoption.
- Never set/export `ANTHROPIC_API_KEY` for the Claude subscription path and never use `--bare` when spawning Claude.
- Native Claude/Codex authentication stays with the local CLI/Orca session. Never copy OAuth/session material between machines or send it to the router.
- `agent-stamp-validate` is required and fail-closed. Missing/incompatible validator means `NEEDS_OWNER`, not "use a different path."
- Orca is required for real worker dispatch. There is no hidden/headless success mode.
- Machine-local launcher configuration and unrelated user policy text are preserved. Unexplained edits to kit-owned bytes are never silently overwritten.

## Existing or new machine lifecycle

Start in the machine's normal `agent-flow-kit` clone:

```bash
cd /path/to/agent-flow-kit
./bin/agent-flow-kit status --fetch
```

For a machine that has never had first-class state (including an old handoff-installed machine):

```bash
git pull
./bin/agent-flow-kit adopt
```

`adopt` can safely claim a stale legacy managed copy only when its bytes match a canonical revision in this repository's Git history. If it reports `LOCAL_DRIFT` or `NEEDS_OWNER`, stop and inspect the named component; do not delete/overwrite it just to make the command pass.

For a machine already adopted under the lifecycle:

```bash
git pull
./bin/agent-flow-kit update
./bin/agent-flow-kit verify
```

Re-run `update` once more when proving idempotence. It should report `CURRENT no filesystem changes`.

## What the lifecycle installs

Global installation is deterministic:

```text
~/.agents/skills/model-router/     managed canonical content
  subscriptions.yaml              machine-local configuration (preserved)

~/.agents/skills/humanizer/        managed canonical tree

~/.claude/skills/model-router      managed symlink
~/.claude/skills/humanizer         managed symlink

~/.claude/CLAUDE.md                managed agent-flow-kit policy section only
~/.codex/AGENTS.md                 managed agent-flow-kit policy section only
```

Installed state is recorded in `${XDG_STATE_HOME:-~/.local/state}/agent-flow-kit/state.json`. It contains revision/hash/path metadata and registered target repos, never secrets.

See `docs/FLEET-LIFECYCLE.md` for the ownership and drift contract.

## Machine-local launcher configuration

Edit only the **installed** launcher config for host-specific facts:

```text
~/.agents/skills/model-router/subscriptions.yaml
```

Confirm:

1. `launcher.router_endpoint` resolves from the host.
2. `launcher.caller_token_env` names a populated environment variable; never put the token value in YAML.
3. `launcher.catalog_path` points at the trusted catalog document, or set `AGENT_STAMP_VALIDATE_CATALOG_PATH` outside the repo.
4. `launcher.stamp_validator` names the installed AI Control Plane validator/client artifact.
5. `launcher.harness_binaries` resolve to the approved Claude/Codex executables.
6. `launcher.agent_dir` matches the target BMAD persona location.

`subscriptions.yaml` is **not** a routing registry. Task harness/model/effort/entitlement choices come from `/v1/route` and nowhere else.

## Validator/client compatibility

The POC history built `agent-stamp-validate` from prox-ops, but adoption/update must not clone or compile prox-ops.

The supported boundary is:

```text
agent-flow-kit
  → compatible installed AI Control Plane validator/client
```

For this phase, `verify` accepts the existing binary when it exposes the frozen `--catalog` + `--stamp` interface and the trusted catalog is configured. Missing/incompatible is reported as owner action. Packaging/versioning moves to the standalone AI Control Plane release process later.

## Target BMAD repository wiring

Global adoption and project wiring are separate. To register and verify a target that is already wired:

```bash
./bin/agent-flow-kit adopt --target /path/to/project
# or later:
./bin/agent-flow-kit status --target /path/to/project
./bin/agent-flow-kit verify --target /path/to/project
```

The verifier expects one recognized BMAD create-story template:

```text
_bmad/bmm/workflows/4-implementation/create-story/template.md
.agents/skills/bmad-create-story/template.md
```

Its frontmatter must carry the current execution surface:

```yaml
---
linear:
stamp:
persona: dev
gates:
  - "<real deterministic command>"
max_cycles: 3
---
```

There is no active `route:` block and no `local_gpu:` pre-assessment. Routing lives in the immutable execution stamp; local placement is resolved late from the stamped logical profile/policy.

The target must also resolve at least:

```text
_bmad/bmm/agents/dev.md
```

If the repo uses the BMAD skill layout, create `_bmad/bmm/agents/` with project-appropriate symlinks to the installed `bmad-agent-*` skill files. Missing personas fail loudly at dispatch.

### Project-specific work that remains human/PM-aware

The lifecycle intentionally does **not** guess these details:

- the project's real validation surface (Playwright, simulator/emulator, integration harness, etc.);
- merge consequences;
- GitOps/IaC promotion policy;
- which validation stories are required.

For every target, determine what a merge to its default/integration branch does. If merge means deployment (Flux/Argo/Terraform auto-apply), normal PM merge authority must not be blindly enabled. Record the project's chosen merge/promotion rule in its policy file.

## Preflight/verify interpretation

`./bin/agent-flow-kit verify` checks installation integrity and local prerequisites, including:

- `jq`, mikefarah `yq` v4+, `curl`, and `orca`;
- external `agent-stamp-validate` presence and compatible CLI shape;
- trusted catalog path;
- configured Claude/Codex harness binaries;
- caller-token environment variable presence without persisting the value;
- `ANTHROPIC_API_KEY` absent;
- `CLAUDE_CONFIG_DIR` absent for the validated default-store launch contract;
- registered target wiring;
- router `/v1/status` reachability unless `--offline` is supplied.

Authentication status commands can describe the credential record but do not prove liveness. A real CLI turn is the only liveness proof; interactive login is never automated.

## Deterministic tests

From the kit checkout:

```bash
tests/run-tests.sh
tests/lifecycle-tests.sh
```

The first preserves route/stamp/validate/place/launch and refusal contracts. The second proves fleet adoption/update/drift semantics without touching a real home directory.

For a live read-only router/stamp chain, use the environment documented in `tests/run-tests.sh` (`AGENT_ROUTER_URL`, caller token, validator, trusted catalog). Do not manufacture routing inputs to obtain a preferred vendor/model.

## Post-merge fleet routine

After every accepted `agent-flow-kit` PR:

```bash
cd /path/to/agent-flow-kit
git pull
./bin/agent-flow-kit status
./bin/agent-flow-kit update
./bin/agent-flow-kit verify
```

If `status` or `update` reports `LOCAL_DRIFT`, preserve the evidence and resolve ownership deliberately. The update lifecycle is designed to hold rather than choose between canonical and unexplained local content.
