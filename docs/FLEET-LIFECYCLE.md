# Fleet lifecycle and installed-state contract

## Purpose

`agent-flow-kit` is both the autonomous BMAD delegation layer and the canonical distribution source for that automation across the Orca development fleet. GitHub carries canonical changes between machines. The lifecycle reconciles a checked-out revision into installed global artifacts without becoming a second routing or policy authority.

The normal channel is:

```text
agent-flow-kit GitHub repo
        ↓ PR / merge
existing fleet clone
        ↓ git pull
./bin/agent-flow-kit update
        ↓
./bin/agent-flow-kit verify
```

## Commands

```text
status [--fetch] [--target PATH]
  Inspect source checkout, applied revision, component drift, local adaptation,
  and target wiring. --fetch refreshes the Git upstream ref before comparison.

adopt [--target PATH]
  First installation/adoption. Existing files are never blindly claimed: known
  stale canonical content may be proven against Git history and upgraded;
  unexplained content produces LOCAL_DRIFT/NEEDS_OWNER.

update [--target PATH]
  Reconcile an installed machine to the current checked-out revision. The
  command never performs git pull. Every managed component is preflighted
  against its previous expected hash before any canonical replacement occurs.

verify [--offline] [--target PATH]
  Verify installed-state integrity, local launcher prerequisites, validator/client
  availability and CLI compatibility, harness binaries, secret-env presence, and
  target wiring. Without --offline it also checks router /v1/status reachability.
```

## Ownership classification

### Managed copy: `model-router-core`

Source: `files/model-router/`

Destination: `~/.agents/skills/model-router/`

Everything under that tree is canonical **except `subscriptions.yaml`**. The hash therefore excludes `subscriptions.yaml`. This matters: the launcher config is deliberately machine-local and survives a managed-tree replacement.

On update:

1. Hash installed managed content and compare it with the manifest's previous canonical hash.
2. If it differs, report `LOCAL_DRIFT` and refuse the update.
3. If it matches, stage the new canonical tree, copy the existing local `subscriptions.yaml` into the stage, then swap the tree.

### Managed copy: `humanizer`

Source: `files/humanizer/`

Destination: `~/.agents/skills/humanizer/`

The complete tree is kit-owned. Unexpected added/removed/modified files change the tree hash and block replacement.

### Managed sections: Claude and Codex policy

Destinations:

```text
~/.claude/CLAUDE.md
~/.codex/AGENTS.md
```

The lifecycle owns only marked sections:

```text
<!-- AGENT-FLOW-KIT:CLAUDE-POLICY:BEGIN -->
...
<!-- AGENT-FLOW-KIT:CLAUDE-POLICY:END -->
```

and the corresponding Codex markers.

The Claude payload is deterministically extracted from the canonical policy source starting at `## Local GPU delegation (junior-dev protocol)` and continuing through the full `## Model & effort routing (BMAD flow)` section. That includes the epic-source and PM merge/triage policy while intentionally excluding unrelated machine-owned blocks such as OMEGA.

The manifest hashes only the managed payload. Update rewrites only between markers. Content before and after the markers is user/machine-owned and preserved.

### Machine-local configuration

Path:

```text
~/.agents/skills/model-router/subscriptions.yaml
```

Ownership mode: `machine_local_config`.

The canonical file is a seed/template. First adoption copies it only when no local file exists. Thereafter the installed file is preserved across updates. It may contain:

- router endpoint;
- caller-token environment variable **name**;
- trusted validator catalog path;
- agent/persona path;
- approved HOME/PATH launcher adaptations;
- harness executable paths.

It must not contain secrets and must not grow task-routing tables, model decisions, or entitlement policy.

### Managed links

The Claude skill entries are managed symbolic links to the universal skill installations. A link that points somewhere unexpected is `LOCAL_DRIFT`; the lifecycle does not follow it and create files inside the target.

### Target-repo wiring

Target repositories are explicitly separate from global installation. The state file stores registered paths with `mode: target_repo_wiring` and `status`/`verify` inspect them for:

- a recognized BMAD create-story template;
- `stamp:`;
- `persona:`;
- `gates:`;
- `max_cycles:`;
- absence of the retired active `route:` field;
- `_bmad/bmm/agents/dev.md` resolving.

The lifecycle does not guess how to edit an unknown project template, choose validation flows, or decide merge consequences. If wiring is missing or project-specific policy is unresolved, it reports `NEEDS_OWNER` and points the operator back to `HANDOFF.md`.

## Installed-state format

Default path:

```text
${XDG_STATE_HOME:-$HOME/.local/state}/agent-flow-kit/state.json
```

Shape:

```json
{
  "schema_version": 1,
  "kit": {
    "repo_root": "/path/to/agent-flow-kit",
    "last_applied_revision": "<git sha>"
  },
  "components": {
    "model-router-core": {
      "mode": "managed_copy",
      "destination": "...",
      "canonical_hash": "...",
      "excludes": ["subscriptions.yaml"]
    },
    "claude-policy": {
      "mode": "managed_section",
      "destination": "...",
      "canonical_hash": "..."
    }
  },
  "machine_local": {
    "model-router-launcher": {
      "mode": "machine_local_config",
      "path": ".../subscriptions.yaml"
    }
  },
  "targets": [
    {"path": "/path/to/project", "mode": "target_repo_wiring"}
  ]
}
```

The state file is written through a temporary file + rename. It stores hashes and local paths, never bearer tokens, OAuth material, provider credentials, or AI Control Plane catalog/routing policy.

## Status semantics

The exact strings are intentionally operator-readable:

- `CURRENT` — installed managed bytes match the last applied canonical hash.
- `UPDATE_AVAILABLE` — checkout/upstream or applied revision has a newer canonical state to reconcile.
- `LOCAL_DRIFT` — a kit-owned copy/section/link changed unexpectedly; update refuses.
- `LOCAL_ADAPTATION` — expected machine-local configuration exists and is intentionally not canonicalized.
- `NEEDS_OWNER` — deterministic convergence is impossible or an external prerequisite is absent.
- `BROKEN` — required installed structure/config is malformed or missing.
- `UNKNOWN` — no manifest exists; the machine may be fresh or a legacy install.

## Legacy adoption

A stale fleet machine may predate the manifest. The lifecycle must not equate "old" with "safe to overwrite."

For managed trees and legacy policy payloads, `adopt` searches reachable Git history and claims the installation only when the existing managed bytes exactly match a canonical historical revision. A harmless manual edit causes the historical proof to fail and adoption stops with evidence.

This gives us both properties needed for the real fleet:

```text
known stale canonical copy  → safe upgrade
unknown local modification  → hold, never overwrite
```

## Update and failure semantics

`update` first checks **all** currently managed components against the manifest. If any component has drift, no canonical component is intentionally rewritten and the manifest is not advanced.

Each tree/file replacement is staged and renamed. A failed/aborted update therefore remains diagnosable: the last successful manifest revision remains authoritative, and `status` exposes any bytes that no longer match it. The lifecycle does not invent a reconciliation choice for mixed/unknown state.

A checked-out revision must be a forward descendant of the last applied revision. Downgrades, branch jumps, or missing history require owner action rather than silently rolling fleet automation backward.

## Validator/client dependency boundary

The current POC validator implementation historically lives under prox-ops, but that source-tree relationship is not the portable product boundary.

`agent-flow-kit` consumes a compatible executable configured by `launcher.stamp_validator` (or `AGENT_STAMP_VALIDATE`). `verify` requires the current frozen CLI surface to expose `--catalog` and `--stamp`. It also requires the trusted catalog document to be supplied through machine-local configuration or `AGENT_STAMP_VALIDATE_CATALOG_PATH`.

The kit does not:

- clone prox-ops;
- compile router source during adoption/update;
- copy validator source into this repository;
- accept a catalog path from a workload/stamp;
- weaken/fallback around a missing validator.

A future standalone AI Control Plane release should publish/version this validator/client artifact and a compatibility contract. Until then, the existing fleet-installed binary is supported when its CLI contract matches; absence/incompatibility is `NEEDS_OWNER`.

## Frozen orchestration invariants

Fleet synchronization does not alter 35.27A behavior:

- central `/v1/route` remains the sole routing authority;
- accepted route becomes an immutable stamp;
- final validation remains immediately before launch;
- `/v1/place` remains late-bound per attempt;
- retry does not mutate harness/model/effort/provider;
- a stale/expired/changed route requires a new route/stamp;
- empty deterministic gates fail closed;
- Orca owns worktrees/terminals/process/session/native auth;
- kit owns delegation/control flow;
- router owns resource recommendation/placement;
- no silent metered API fallback;
- no credentials are passed to the router;
- workers remain Orca-visible.
