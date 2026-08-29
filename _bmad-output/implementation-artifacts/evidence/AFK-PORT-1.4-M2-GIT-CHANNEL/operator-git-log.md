# M2 operator git actions — canonical checkout (primary host)

Performed by the coordinator (Josh's M2 go, 2026-08-27), OUTSIDE lifecycle
tooling per the frozen constraint that the kit never fetches, pulls, switches,
or merges Git state.

## Action 1 — position the checkout at the host's true stale state (pre-adoption)

- Found: working tree on `story/afk-port-1.2` @ `2475bf2` since before the 1.3
  merges (HEAD reflog); local `master` ref at `8a7cbc1` but moved ONLY by
  `fetch origin master:master` fast-forwards (master reflog in
  `operator-git-before.txt`) — never checked out on this host. The host's true
  stale contemporary is `bd9d9fb` (master@{2}, the pre-1.3 merged increment).
- Done: `git branch -f master bd9d9fb…` then `git switch master` — the
  working tree now sits at the genuinely stale revision the host actually
  lived at. Untracked user content untouched (5 files, listed in
  `operator-git-after.txt` — these are preservation-proof material for the
  update).
- Transparency note: the forward-moved local ref was a fetch artifact; this
  repositioning reconstructs the host's real stale position rather than
  manufacturing staleness. Both facts and the reflog are retained.

## Action 2 — the external Git pull (AFTER adoption at the stale revision)

To be executed and recorded here only after M2a adoption commits:
`git pull` fast-forward from `bd9d9fb` to the successor merge SHA `8a7cbc1`
(ancestry verified: bd9d9fb is an ancestor of 8a7cbc1).
