# Host-pair representativeness

## Frozen AC-3 selection

The following placement facts are recorded verbatim with coordinator provenance:

- PRIMARY = this devbox VM: always-on remote Orca server carrying meaningful legacy/stale kit state.
- SECOND = the Mac Orca server (macOS; ≥2 material differences: OS, path layout, install state; site of the signal-numbering observation).
- OBSERVED-NOT-SELECTED: a cachyos Orca server (placement data shows `cachyos-7900xtx` offline → not the always-on member; Linux like the primary → weaker second-host differentiation than the Mac).
- EXCLUDED by scope: the laptop (inference host); the bazzite PC (hub seat, not an always-on dev host).

Provenance: coordinator-supplied frozen AC-3 facts in `AFK-PORT-1.4-M1-PRIMARY-BASELINE-BRIEF.md`; these placement facts were not independently verified by this worker.

## Observed PRIMARY staleness evidence

- The canonical checkout is on `story/afk-port-1.2`, not its declared canonical branch `master`; it is 23 commits behind and 6 commits ahead of `master` (`git rev-list --left-right --count master...HEAD`).
- The canonical checkout has five untracked file entries and no tracked changes (`git status --porcelain=v1 -z`, aggregated without recording names or contents).
- Installed legacy material exists under `~/.local/share/agent-flow-kit/`, including an installed catalog, while `~/.local/state/agent-flow-kit/state.json` is absent (explicit path probes and catalog enumeration).
- Lifecycle inspection reports `INSTALLATION_NOT_ADOPTED`, `SOURCE_DIRT_OUTSIDE_INPUT_SET`, and `SOURCE_NONCANONICAL_BRANCH` (`status.json`, `verify.json`, and `adopt-inspect.json`).
- Installed component observations include `UNKNOWN` / `NOT_ADOPTED`, a `LOCAL_ADAPTATION` / `MACHINE_OWNED_REGION`, and `MANAGED_SECTION_ABSENT` (`status.json: components`).

This pair is representative because the PRIMARY exercises legacy/stale Linux installation and ownership recovery, while the SECOND adds macOS, materially different paths and install state, and the already observed signal-numbering case. The cachyos host would add less platform differentiation and is offline rather than always-on.
