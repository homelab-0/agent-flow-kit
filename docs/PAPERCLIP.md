# Paperclip integration (`agent-flow-kit paperclip-poll`)

One deterministic poller per host holds every project agent's Paperclip key
and is the only thing on that host that writes to Paperclip. It runs one
bounded pass at a time: no loop, no sleep, no wait. It claims and classifies
issues, and drains the spool of queued PM status back to Paperclip (the
report cycle, below).

## Config

`${AFK_PAPERCLIP_CONFIG:-$HOME/.config/agent-flow-kit/paperclip.json}`:

```json
{
  "api_url": "https://paperclip.example",
  "company_id": "<uuid>",
  "board_user_id": "<uuid>",
  "host_label": "devbox",
  "maintenance_issue_id": "<uuid, optional>",
  "agents": [
    {
      "agent_id": "<uuid>",
      "key_ref": "op://vault/item/field",
      "project": "agent-flow-kit",
      "repo_path": "/home/user/repo",
      "harness": "claude",
      "max_active_issues": 1
    }
  ]
}
```

Every id (company, board user, agent, maintenance issue, and every id read
back from a Paperclip response) is checked as a UUID before it is used in a
file path. `board_user_id` may never be the literal string `board` or
`local-board`. A missing config reports `PAPERCLIP_NOT_CONFIGURED`; an
invalid one reports `PAPERCLIP_CONFIG_INVALID` or `PAPERCLIP_ID_INVALID`.
Neither makes a network call.

## Notices

Under `$AFK_STATE_DIR/paperclip/notices/<project>/`, one file per event,
never rewritten: `claimed`, `promoted`, `human_commented`, `stopped`,
`stranded`. A `claimed` notice also writes a
`brief.<issue-id>.<updatedAt digits>.md` with the issue title and
description; if the issue's `updatedAt` has no digits, the digits fall back
to the current epoch. A `human_commented` notice writes a
`reply.<comment-id>.md` holding the comment body. Notices never carry Paperclip comment or issue text
beyond what those two file types already declare.

## Refusal and pause reasons

`PAPERCLIP_NOT_CONFIGURED`, `PAPERCLIP_CONFIG_INVALID`, `PAPERCLIP_ID_INVALID`,
`PAPERCLIP_VAULT_UNAVAILABLE`, `PAPERCLIP_KEY_AGENT_MISMATCH`,
`PAPERCLIP_KEY_UNAUTHORIZED`, `PAPERCLIP_POLL_BUSY`, `PAPERCLIP_PAUSED`,
`PAPERCLIP_DRAIN_TAMPERED`, `PAPERCLIP_DRAIN_UNREADABLE`,
`PAPERCLIP_AUTHOR_UNVERIFIABLE`, `PAPERCLIP_SELF_BLOCK_FAILED`, `PAPERCLIP_UNREACHABLE`,
`PAPERCLIP_CREDENTIAL_REJECTED`, `PAPERCLIP_RATE_LIMITED`.

## The report cycle and the spool (`agent-flow-kit paperclip-poll`, AFK-PC-1b)

The PM never holds a Paperclip key. It drops progress, questions and its
final result into a per-issue spool, and the same poller pass drains it:

```
$AFK_STATE_DIR/paperclip/spool/<issue-id>/<seq>.json
```

`seq` is a zero-padded integer; entries are sent strictly in ascending order.
Only a `<digits>.json` name is a live entry — `.tmp/` and anything else is
ignored. Each entry is one of:

```json
{"id":"<uuid>", "kind":"comment", "body":"…"}
{"id":"<uuid>", "kind":"question", "question_id":"<short id>", "body":"…"}
{"id":"<uuid>", "kind":"final", "status":"in_review"|"done", "body":"…"}
```

For a ledger issue this agent holds (`working` or `waiting_human`), a cycle
runs when the spool has entries, or when the declared action text has
changed since the last self-block. The cycle: take a run (wakeup), `PATCH`
in_progress, post every entry in order, then either the final status (a
`final` entry) or a self-block with the composed text — never leaving the
issue in_progress.

Every posted comment body carries a trailing marker line,
`<!-- afk-entry:<entry id> -->`. A 201 deletes the spool file. On an
ambiguous outcome (timeout, 5xx, or no status), the comments are read back
for the marker: found means sent (delete and continue); not found leaves the
file in place for the next pass. A `sending` marker is written to the ledger
before every POST, and a leftover one from a crashed pass is resolved by the
same read-back before anything else is posted, so no entry is ever posted
twice on the strength of a guess. Only comments authored by the poller's own
agent count as a match, and a read-back that itself fails holds every entry
for that issue until the next pass. An entry with an unknown `kind`, a
`final` status other than `in_review`/`done`, or a `question` without a
short `question_id` goes to `dead/` unposted. If a `final` comment lands but
its status PATCH fails, the status is kept in the ledger as `pending_final`
and retried on the next pass without re-posting the comment.

A `422`/`400` moves that one entry to `spool/<issue-id>/dead/` with a
`.reason` file and continues with the rest. A `404`/`410` drops the whole
issue from the ledger and moves everything left in its spool to `dead/`,
the same place a closed issue's spool ends up once it is no longer held.
A `429` keeps the entry and backs off for the rest of that agent's pass. A
`409` leaves the entry for the next pass. None of this runs while paused or
draining, and a `stranded` issue's spool is simply held.

An issue first adopted during a pause is recorded `pending_claim`, not
`working`, so the PM never hears about it mid-pause; the claim comment,
notice and brief are only sent on the first pass after the pause lifts.

## The PM registry and notice verbs

PM ownership (`adapters/pm-session.sh`) is recorded per worktree, under
`$AFK_STATE_DIR/pm/scopes/<worktree-key>/ownership.json`. A repo can have
several worktrees, and a PM terminal can die and leave its ownership record
behind. `lib/afk-pm-registry.sh` answers "is there a live PM for this repo,
and which terminal is it?" by scanning every scope whose `worktree.path`
resolves (via `git rev-parse --git-common-dir`) to the same repo, and gives
the poller (and any PM) a safe way to claim and settle notices so two
sessions never act on the same one.

- **`afk_pm_registry_lookup <repo_path>`** (library function): one JSON
  object, `state` one of `none`, `live`, `unknown`, `handoff_in_progress`,
  `handoff_stalled`, `ambiguous`. Liveness comes from `orca terminal list
  --json`, and a listed terminal falls into exactly one of three buckets:
  live (`connected: true`, `orphaned: false`), stale (absent from the list,
  or listed with `orphaned: true`), or disconnected (listed with
  `connected: false` and `orphaned: false`). A disconnected owner is neither
  live nor stale — it is never reaped, and it never satisfies
  `paperclip-take` either. When the only owner found is disconnected, the
  lookup reports `state: "unknown"` with `reason: "PM_OWNER_DISCONNECTED"`
  and names it in `owners`. If Orca cannot be queried at all, the `orca`
  field reports `ORCA_UNAVAILABLE` and every owner is treated as live —
  **never reap on uncertainty**. `handoff_in_progress`/`handoff_stalled`
  come from a scope's `handoff.json` in state `SUCCESSOR_LAUNCHED` or
  `ACKED`, aged against `pm_handoff_timeout_min` (default 30, from
  `~/.config/agent-flow-kit/pm-registry.json`). When more than one scope for
  the same repo has such a handoff in flight, the lookup never picks one by
  glob order: it reports `state: "ambiguous"` with `reason:
  "PM_HANDOFF_AMBIGUOUS"` and names every one of them in `handoffs`. `stale`
  always lists every owner found dead.

- **`agent-flow-kit pm-registry-reap --scope <key> [--json]`**: re-proves
  staleness itself (refuses `PM_OWNER_LIVE`, `PM_HANDOFF_IN_PROGRESS` or
  `ORCA_UNAVAILABLE` otherwise), atomically moves that scope's
  `ownership.json` to `pm/reaped/<scope>.<epoch>.json`, and returns every
  notice claimed under that owner's terminal back to `notices/<project>/`.
  A notice that cannot be returned — an invalid or unknown project, or a
  same-named file already at the destination — is never left silently
  behind under the dead terminal's claim key: it is moved instead to
  `notices/unreturned/<scope>/`, unless that recovery location is itself
  already occupied by a same-named file, in which case the notice is left
  exactly where it was rather than overwriting anything. Either way it is
  named, by its source path, in the result's `stranded` array, and
  `notices_stranded` counts them; a nonzero count exits `3` even though the
  owner was reaped successfully.

- **`agent-flow-kit paperclip-take --project <name> [--json]`**: only the
  registry's live owner for that project's `repo_path` may call it (identity
  is `ORCA_TERMINAL_HANDLE`, checked against the owner's `terminal`; during a
  handoff, the named successor terminal may call it instead — anyone else
  gets `PAPERCLIP_HANDOFF_IN_PROGRESS`). A disconnected or ambiguous owner
  never authorizes a take: `ORCA_TERMINAL_HANDLE` matching a disconnected
  owner's terminal, or a successor named in one of several ambiguous
  handoffs, both get `PAPERCLIP_NOT_OWNER`. Claims every notice under
  `notices/<project>/` in order by an atomic `mv` into
  `notices/claimed/<claim-key>/` before reading it, where `<claim-key>` is
  `terminal-<sha256 of the caller's terminal handle>` — the same key
  `pm-registry-reap` derives from a stale owner's `terminal`, so a reaped
  PM's claimed notices are always found. Prints each notice's brief/reply as
  a path, never a content.

- **`agent-flow-kit paperclip-settle --notice <id> [--json]`**: `<id>` is the
  notice's Paperclip issue id. Moves every matching notice claimed under the
  caller's own claim key to `notices/settled/`. Idempotent (a no-op exit 0
  when already settled); an unknown or foreign notice refuses with
  `PAPERCLIP_NOTICE_UNKNOWN`.

## The self-block model

While AFK works on an issue locally (outside Paperclip, in the real repo),
the poller holds it `blocked` with `unblockDescriptor.owner.agentId` set to
its own agent — the one Paperclip state that needs no live run and never
escalates. Every self-block is a `PATCH` carrying the poller's own declared
action text (AC-7): `Stopped`, `paused for Paperclip maintenance`, `queued
behind <identifier>`, the PM's declared status, or the last known text. A
human (via a comment from the board user) can unblock or redirect work
without ever taking the run; the poller notices the comment on its next pass
and, if capacity allows, promotes a queued issue back to `working`. Only
Josh (via the board account, verified by `authorUserId` and a present-but-null
`authorAgentId`) can answer a self-blocked question; anything else is either
ignored or, if unverifiable, reported and left untouched (fail-closed).
