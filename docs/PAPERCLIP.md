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
twice on the strength of a guess.

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
