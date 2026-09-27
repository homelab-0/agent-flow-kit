# Paperclip integration (`agent-flow-kit paperclip-poll`)

One deterministic poller per host holds every project agent's Paperclip key
and is the only thing on that host that writes to Paperclip. It runs one
bounded pass at a time: no loop, no sleep, no wait. The report cycle that
sends queued PM status back to Paperclip is a separate story (AFK-PC-1b);
this command only claims and classifies.

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
`stranded`. A `claimed` notice also writes a `brief.<issue-id>.<epoch>.md`
with the issue title and description. A `human_commented` notice writes a
`reply.<comment-id>.md`. Notices never carry Paperclip comment or issue text
beyond what those two file types already declare.

## Refusal and pause reasons

`PAPERCLIP_NOT_CONFIGURED`, `PAPERCLIP_CONFIG_INVALID`, `PAPERCLIP_ID_INVALID`,
`PAPERCLIP_VAULT_UNAVAILABLE`, `PAPERCLIP_KEY_AGENT_MISMATCH`,
`PAPERCLIP_KEY_UNAUTHORIZED`, `PAPERCLIP_POLL_BUSY`, `PAPERCLIP_PAUSED`,
`PAPERCLIP_DRAIN_TAMPERED`, `PAPERCLIP_DRAIN_UNREADABLE`,
`PAPERCLIP_AUTHOR_UNVERIFIABLE`, `PAPERCLIP_UNREACHABLE`.

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
