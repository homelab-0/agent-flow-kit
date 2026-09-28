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
Neither makes a network call. `interim_comment_approval.paperclip_commit`,
when present, must be 40 lowercase hex characters or config load itself
refuses with `PAPERCLIP_CONFIG_INVALID`.

### Migrating from `paperclip_version`

An older config's `paperclip_version` field is no longer read by the PM-start
approval gate; an unmigrated config now always returns
`APPROVAL_INTERIM_UNATTESTED` and the caller never auto-starts a PM. Replace
it with `interim_comment_approval.paperclip_commit`, set to the exact commit
`GET /api/health` reports (`afk_pc_health_commit`) -- a short SHA does not
match the full SHA the endpoint returns:

```json
{
  "interim_comment_approval": {
    "paperclip_commit": "4a1b2c3d4e5f60718293a4b5c6d7e8f9a0b1c2d3"
  }
}
```

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

## `paperclip-report` — the PM's only way to write (AFK-PC-3a)

The PM never holds a Paperclip key and never touches the poller's spool or
status files directly (AD-7/AD-8). `agent-flow-kit paperclip-report` is the
one command that writes there, and it enforces ordering, closure and who's
allowed to:

- **Caller.** The verb resolves the issue's project from the poller ledger
  (`$AFK_STATE_DIR/paperclip/ledger.json`, `issues[<id>].project`), then that
  project's `repo_path` from the paperclip config. The caller must be the
  registry's live owner (or the named handoff successor) for that repo — the
  same check as `paperclip-take`, via `ORCA_TERMINAL_HANDLE`. Otherwise it
  refuses with `PAPERCLIP_NOT_OWNER`. An unknown issue id, or one not in the
  ledger, refuses with `PAPERCLIP_ISSUE_UNKNOWN`.
- **`paperclip-report --issue <id> --comment-file <path>`**,
  **`--issue <id> --question <qid> --comment-file <path>`**, or
  **`--issue <id> --final in_review|done --comment-file <path>`**: the body
  is always read from a file, at most 16 KiB and valid UTF-8, never from an
  argument. `qid` matches `^[a-z0-9-]{1,32}$`. The verb writes
  `{id, kind, body[, question_id | status]}` to
  `spool/<issue-id>/.tmp/<uuid>.json`, then publishes it with a no-clobber
  rename to `spool/<issue-id>/<seq>.json` — the same layout
  `paperclip-poll`'s report cycle reads (see above). `seq` is zero-padded to
  8 digits and comes from a per-issue counter file
  (`spool/<issue-id>/.seq`), incremented under the kit's portable `mkdir`
  lock, never a directory listing. After a `final` entry is published, any
  further entry for that issue refuses with `PAPERCLIP_SPOOL_CLOSED`; a
  `final` also refuses with `COST_EVENTS_PENDING` while the ledger lists a
  pending cost result for the issue.
- **`paperclip-report --issue <id> --status "<text>" [--story k/n]`**: writes
  `status/<issue-id>.json` atomically as
  `{schema:"afk-paperclip-status/1", text, story, version, updated_at}`,
  incrementing `version`. `text` is at most 120 characters, a single line,
  and free of control characters. It never touches the spool.
- Human mode prints one line — the entry's seq, or the status version;
  `--json` prints `{result, issue, seq|version}`. The body is never printed,
  in either mode.

## Plans and Josh's approval of record (AFK-PC-3b)

Nothing from a Paperclip issue is stamped or dispatched until Josh approves
the exact plan he saw. Until native approvals ship (PC-8), the approval of
record is Josh's own comment `approve <digest8>` on the open plan question.

- **`paperclip-plan --issue <id> --plan-file <path> [--json]`** (owner only,
  same check and body-file rules as `paperclip-report`). The file is JSON
  `{schema:"afk-paperclip-plan/1", repo, base, stories:[{id, title, size,
  lane, files:[…], gates:[…]}]}`. `repo` must equal the configured
  `repo_path` for the issue's project; each `id` matches
  `^HOM-[0-9]+\.S[0-9]+$` with the issue's own identifier as its prefix; ids
  are unique; there is at least one story; no field may contain a control
  character (`PLAN_INVALID`, `PLAN_REPO_MISMATCH`).
- **Gate allowlist.** Read only as `git -C <repo> show <base-commit>:.afk/gates-allowlist`
  (the base resolved with `rev-parse --verify`, else `PLAN_BASE_UNKNOWN`),
  never from a worktree, so a branch or working-tree edit cannot widen it.
  One exact command per line; blank or whitespace-only lines and lines
  whose first byte is `#` are ignored. An indented `#` line is an entry, and
  entries are byte-exact (a CRLF line keeps its CR and matches nothing). No file (or not a regular file) at the base: `GATE_ALLOWLIST_MISSING`.
  An empty `gates` list, or any gate not byte-equal to a line:
  `GATE_NOT_ALLOWLISTED`, naming the story and the gate.
- **Digest.** The verb renders a deterministic markdown body from the
  validated fields only (unknown keys are dropped): the repo name and path,
  the base, and per story its id, title, size, lane, files, and every gate
  verbatim in a fenced block. **`digest` is the lowercase hex sha256 of
  exactly the UTF-8 bytes of that rendered body, every line ending in LF,
  including the LF after the closing fence of the last story, and nothing
  else.** `digest8` is its first 8 hex characters. The posted comment is
  that body, one blank line, then the footer `plan <digest8>` and
  ``Reply exactly `approve <digest8>` to approve, or `reject <digest8>`.``
  **The footer (and the blank line before it, and the poller's
  `<!-- afk-entry -->` marker) is never part of the digest input.** The same
  JSON content always gives the same digest, whatever its key order or
  whitespace.
- **Publish.** Under `plans/.<id>.lock` the verb first deletes
  `approvals/<id>.json` and `plans/<id>.json` (a re-plan revokes any earlier
  approval, F1). It then (1) writes `plans/<id>.json` atomically:
  `{schema:"afk-paperclip-plan-record/1", state:"pending_publish", digest,
  digest8, question_id, body_sha256 (sha256 of the raw plan file), repo,
  base, base_commit, stories, posted_seq:null, created_at}`; (2) publishes
  the comment as a spool `question` entry with `question_id =
  plan-<digest8>` through the `paperclip-report` writer function; (3)
  rewrites the record atomically with `state:"posted"` and `posted_seq`. The
  poller can therefore never send a plan question with no record behind it.
  If (1) fails nothing is published; if (2) fails the pending record is
  removed and the writer's refusal is returned; if (3) fails the verb
  writes a `pending_publish` record that carries `posted_seq` and refuses
  with `PAPERCLIP_REGISTRY_WRITE_FAILED` naming `digest8` and `seq`. Prints
  `plan <digest8> (seq N)`, or `{result, issue, digest, digest8,
  question_id, seq}` with `--json`.
- **Approval (poller).** When the poller sends a `question` entry it records
  `question_seq` and Paperclip's `createdAt` for that comment
  (`question_sent_at`, absent when the response did not carry one). On an
  issue in `waiting_human` with `question_id = plan-<digest8>`, a comment
  that passes the Josh test and whose body, trimmed of surrounding
  whitespace, is **exactly** `approve <digest8>` writes
  `approvals/<id>.json` = `{schema:"afk-paperclip-approval/1", kind:"plan",
  digest, digest8, comment_id, comment_created_at, decided_at,
  paperclip_commit}` and an `approval_granted` notice, only when all of
  these hold: the plan file's `digest8`/`question_id` match, its `state` is
  `posted` or `pending_publish`, and its `posted_seq` is a number equal to
  the recorded `question_seq` (else `APPROVAL_PLAN_MISMATCH`); the comment was created after
  `question_sent_at` (else, or if unknown, `APPROVAL_BEFORE_PLAN`); the
  config has `interim_comment_approval: {attested_on, paperclip_commit}`
  and an unauthenticated `GET /api/health` returns `commit` equal to
  `paperclip_commit` (else, including any health failure,
  `APPROVAL_INTERIM_UNATTESTED`). The record is written under the plan
  lock after re-checking the plan digest, state and seq. A refusal writes
  an `approval_refused` notice carrying `reason` and a local action line;
  never a record. `reject <digest8>` withdraws an approval of that same plan
  under the plan lock and then writes an `approval_rejected` notice. If the
  lock cannot be taken or the approval cannot be removed, it writes an
  `approval_withdraw_failed` notice carrying `reason`
  (`PAPERCLIP_LOCK_TIMEOUT` or `APPROVAL_WRITE_FAILED`) and a local action
  line instead, and the approval stays. Any other Josh comment is a
  plain `human_commented` notice and never approves.
- **`paperclip-approval --issue <id> [--json]`** is read-only:
  `{approved, digest, digest8, reason}`. `approved` is true (exit 0, reason
  `APPROVED`) only when `approvals/<id>.json` exists and its digest equals
  the current `plans/<id>.json` digest and the configured attestation still
  names the `paperclip_commit` the approval was made under. Otherwise (exit
  1) `NO_PLAN`, `NOT_APPROVED`, `PLAN_CHANGED` or
  `APPROVAL_INTERIM_UNATTESTED`.

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

## Starting the first PM (AFK-PC-2b)

Opt-in via `pm_start_enabled: true` in `paperclip.json` (default off, so an
existing install sees no behaviour change). When set, every pass that finds
an issue self-blocked and owned by this host re-evaluates whether to start
the project's PM, using PC-2a's registry lookup for the agent's `repo_path`:

- `live`: nothing starts; the PM pulls its own notices.
- `handoff_in_progress` / `ambiguous` / `handoff_stalled`: nothing starts;
  the self-block text says so, and an ambiguous/stalled registry state opens
  one out-of-band "NEEDS HUMAN" issue per repo (an `idempotencyKey`).
- Every listed stale owner is reaped with `pm-registry-reap` before deciding.
- `none`: subject to the creator gate (`createdByUserId == board_user_id`,
  else one `Reply exactly: approve start <identifier>` question comment and
  an exact matching Josh reply — gated on `interim_comment_approval` present
  and its `paperclip_commit` matching the deployed commit from
  `GET /api/health` (`afk_pc_health_commit`, shared with the plan-approval
  check), else `APPROVAL_INTERIM_UNATTESTED`; a failed or unreachable health
  check is the same fail-closed refusal), the daily cap (`pm_start_daily_cap`,
  default 3, per host per UTC day), and the kit's own readiness check
  (`AFK_PCS_READINESS_BIN`, defaulting to `agent-flow-kit status --json`
  against the repo) — never auto-fixed.

A start creates exactly one visible Orca terminal titled
`PM <project> (paperclip)`, running `adapters/orca-pm-bootstrap.sh` with a
`afk-pm-bootstrap-first-start-intent/1` intent (a sibling of the handoff
intent, for a PM with no predecessor). The first instruction is fixed kit
text naming only `<project>` (`^[a-z0-9-]+$`) and `<harness>` (the enum);
no Paperclip issue title, description or comment ever reaches the terminal,
the prompt, an argv, or the intent file. The Orca terminal nudge for a live
PM is not implemented (Orca has no foreground-process check; see AD-7).

## `agent-flow-kit paperclip-timer --install|--remove|--status [--json]`

Linux only: a systemd **user** service and timer running `paperclip-poll`
every 90s (`OnUnitActiveSec`/`OnActiveSec`, `RandomizedDelaySec=15s`,
`Persistent=false`). The unit holds no secret and no key reference; the
poller reads its config at run time. `--status` also reports
`PAPERCLIP_POLLER_STALE` when the ledger's `last_successful_pass` is older
than 3 intervals. macOS refuses with `PAPERCLIP_TIMER_UNSUPPORTED_PLATFORM`.

**Stale lock (AC-7b):** the poll lock (`paperclip/.lock`) now carries an
owner PID file. A lock older than 5 poll intervals whose owner PID is
provably dead is reaped (and the pass retried, or `--status` reports clean)
instead of reporting `PAPERCLIP_POLL_BUSY` forever after a `kill -9` or a
reboot.
