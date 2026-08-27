# AFK-PORT-1.3 full-review attack scripts

Runnable reproductions for the blockers in
`evidence/AFK-PORT-1.3-FULL-REVIEW.md`. The reviewer had no shell, so each
script is written to be executed verbatim by the coordinator and to decide its
own verdict rather than leaving the reader to interpret output.

Run from anywhere:

```
bash _bmad-output/implementation-artifacts/evidence/AFK-PORT-1.3-FULL-REVIEW-attack/A1-terminal-absent-no-durable-close.sh
bash _bmad-output/implementation-artifacts/evidence/AFK-PORT-1.3-FULL-REVIEW-attack/A2-route-ready-without-target.sh
bash _bmad-output/implementation-artifacts/evidence/AFK-PORT-1.3-FULL-REVIEW-attack/A3-stale-needs-human.sh
bash _bmad-output/implementation-artifacts/evidence/AFK-PORT-1.3-FULL-REVIEW-attack/A4-unbounded-remote-op.sh
```

Each script:

- builds its own throwaway `HOME`, checkout, Git repositories and stubbed
  dependencies under `mktemp -d`, and removes them on exit;
- touches no real `HOME`, no real installation, no network, no provider
  session and no real Orca;
- prints `DEFECT REPRODUCED` (exit 0) or `NOT REPRODUCED` (exit 1), and prints
  the control result that makes the reproduction falsifiable rather than a
  bare claim.

The Orca stub in `lib-dispatch-fixture.sh` is copied from
`tests/lifecycle-dispatch-tests.sh` unchanged, deliberately: A1 and A3 must be
reachable through the same model the story's own gate already accepts as a
faithful stand-in for Orca. A1 needs no extension to that stub at all — it
reaches the defect purely by not adding the handle to the stub's session list,
which is what Orca reports for a terminal it is not currently listing.

`KIT_ROOT` is derived from this file's location (four levels up). Override it
with `AFK_ATTACK_KIT_ROOT=/path/to/worktree` if the scripts are moved.
