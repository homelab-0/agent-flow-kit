# Story 1.4 portability host pair — insufficient fleet visibility

## Result

Fleet visibility from this host is insufficient to propose a pair. No remote host identifiers were observable, so naming either the PRIMARY or SECOND host would be a guess and would violate the frozen AC-3 selection law.

## Observable fleet surface

- `orca-ide host list --json` returned only `local` (`this machine`, connection kind `local`).
- `orca-ide environment list --json` returned zero saved remote environments.
- `orca-ide terminal list --json` scoped all 13 visible terminals to `local` and reported no omitted host IDs.
- `orca-ide project setups --json` returned four setups, all with `hostId: local`; the agent-flow-kit setup is a ready `legacy-repo` at `/home/devbox/repos/jlengelbrecht/agent-flow-kit`.
- `orca-ide worktree list --json` exposed local agent-flow-kit state at head `2475bf22ccdb30b6aac472de55f08c45f39a770e`, branch `refs/heads/story/afk-port-1.2`.
- A field-selective read of `/home/devbox/.config/orca/profiles/local-default/orca-data.json` found empty `sshTargets`, empty `workspaceSessionsByHostId`, and `activeRuntimeEnvironmentId: null`.
- `/home/devbox/.config/orca/orca-devices.json` contains runtime/mobile pairing records, but neither is a targetable host or saved environment and neither supplies host OS/layout/revision evidence. The mobile/inference device is excluded by scope.

Structured facts and per-fact provenance are in `candidates.json` beside this report.

## Why no representative pair can be supported

The required PRIMARY depends on identifying the current always-on remote host and determining whether it carries meaningful legacy/stale agent-flow-kit state. Neither identity nor state is visible here.

The required SECOND must be a distinct remote Orca host with at least two evidenced material differences from PRIMARY. No second remote host is visible, and none of revision age, installation layout, harness state, target wiring, Orca configuration, path layout, or OS can be compared across remote hosts. The expected macOS member cannot be identified from the available evidence.

## Access needed

The coordinator needs fleet discovery from an Orca profile/runtime that has the remote hosts saved or connected. Read-only `orca-ide host list --json`, `environment list --json`, `project setups --json`, `worktree list --json`, and `terminal list --json` should be collected from that fleet-visible context; if saved-environment selectors are returned, the same read-only calls should be made with `--environment <selector>`.

## On-host baseline verification required

For every fleet-visible remote candidate, verify and record:

1. Host identity, reachability, OS, architecture, and whether it is the always-on remote host; explicitly exclude the laptop/inference host.
2. Agent-flow-kit revision/age and whether legacy or stale state is meaningful enough to select PRIMARY.
3. Installation and path layout, including repository/worktree roots and how Orca registered the project.
4. Harness state and target wiring without running lifecycle mutations.
5. Orca version/configuration and connection kind.
6. For SECOND, cite at least two material differences versus PRIMARY from the frozen dimensions before accepting the pair.

No SSH, worktree/terminal creation, lifecycle command, or other fleet mutation was performed during this discovery.
