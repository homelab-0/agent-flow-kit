# Paperclip integration (`agent-flow-kit paperclip-poll`)

One deterministic poller per host holds the host agent's one Paperclip key
and is the only thing on that host that writes to Paperclip. It runs one
bounded pass at a time: no loop, no sleep, no wait. It claims and classifies
issues, and drains the spool of queued PM status back to Paperclip (the
report cycle, below).

## Config

`${AFK_PAPERCLIP_CONFIG:-$HOME/.config/agent-flow-kit/paperclip.json}`, schema
`afk-paperclip-config/2` (AD-23):

```json
{
  "schema": "afk-paperclip-config/2",
  "api_url": "https://paperclip.example",
  "company_id": "<uuid>",
  "board_user_id": "emXp8Svi8ncWyL1EORTkRNQYjFjCdQon",
  "host": {
    "label": "devbox",
    "agent_id": "<uuid>",
    "key_ref": "op://vault/item/field"
  },
  "maintenance_issue_id": "<uuid, optional>",
  "projects": [
    {
      "paperclip_project_id": "<uuid>",
      "slug": "agent-flow-kit",
      "repo_path": "/home/user/repo",
      "harness": "claude",
      "max_active_issues": 1,
      "merge": "human"
    }
  ]
}
```

Field rules:

- `host` is the host's one Paperclip agent and its one key reference. Adding
  or removing a project never creates, rotates or retires a key.
- `projects[]` is keyed by the Paperclip project id. Every entry needs a
  unique `paperclip_project_id`, a unique `slug`, and a `repo_path` that is
  absolute and points at a distinct repository (compared by
  `git rev-parse --git-common-dir`, so two paths into one repo count as one).
  Zero projects is valid: every issue then self-blocks as unmapped.
- `slug` matches `^[a-z0-9-]{1,40}$` and names every path, notice directory,
  intent file and terminal title. `claimed`, `settled` and `unreturned` are
  reserved. Paperclip's project name never reaches a path.
- `harness` is `claude`, `codex` or `opencode`. `max_active_issues` is an
  integer from 1 to 999 (default 1). `merge` is `human` (default) or `pm`.
- `api_url` must be `https://`.
- `host.op_env_file` is optional and, when present, an absolute path. See
  [How the poller reads the key](#how-the-poller-reads-the-key).

Every id used in a file path (company, agent, maintenance issue, and every id
read back from a Paperclip response) is checked as a UUID before it is used
that way. `board_user_id` is never used in a file path; it is checked against
`^[A-Za-z0-9_-]{16,64}$` (a UUID also matches), since real Paperclip board
user ids are Better-Auth style ids, not UUIDs. `board_user_id` may never be
the literal string `board` or `local-board`. A missing config reports
`PAPERCLIP_NOT_CONFIGURED`; an invalid one reports `PAPERCLIP_CONFIG_INVALID`
or `PAPERCLIP_ID_INVALID`; a config without the v2 schema reports
`PAPERCLIP_CONFIG_SCHEMA_OLD` and is never read (see
[Migrating a v1 config](#migrating-a-v1-config)).
None of these makes a network call. `interim_comment_approval.paperclip_commit`,
when present, must be 40 lowercase hex characters or config load itself
refuses with `PAPERCLIP_CONFIG_INVALID`.

### How the poller reads the key

The poller reads `host.key_ref` with `op read`. If `OP_SERVICE_ACCOUNT_TOKEN`
is already in the environment, as in an interactive shell, `op` uses it. If
not, as under the systemd timer, the poller sources an op env file inside a
subshell for that one `op read`, so the token never enters the poller's own
environment and no other child sees it. The file is the first of
`host.op_env_file`, `$AFK_OP_ENV_FILE` and `$HOME/.op-agent-env`. It must be
a regular file owned by you, mode 600 or stricter (no group or other bits);
anything else is refused with `PAPERCLIP_OP_ENV_UNSAFE` and never sourced. The
file is opened once and checked and sourced through that open file, so
swapping the path after the check changes nothing. No file and no token is
`PAPERCLIP_VAULT_UNAVAILABLE`. Neither the file's contents nor the key are
ever printed.

The timer's unit carries the absolute `AFK_ORCA_BIN` path resolved at install
time, but no secret, key reference or env file path. Install checks the
binary's `--version` handshake under the user manager's environment. A failed
handshake refuses installation with `ORCA_CLI_NOT_RESOLVED`.
`paperclip-timer --status` and `paperclip-project list` repeat the key read
in the environment the unit gets: `env -i` with `HOME`, plus the user
manager's `PATH`, `OP_*`, `AFK_OP_ENV_FILE` and `AFK_OP_BIN` from
`systemctl --user show-environment`. A token or override that only your shell
carries does not count. The check covers the key read and Orca handshake.
Both commands report `PAPERCLIP_VAULT_UNAVAILABLE`,
`PAPERCLIP_OP_ENV_UNSAFE`, or `ORCA_CLI_NOT_RESOLVED` when the corresponding
check fails. `paperclip-timer --install` refuses with that code.

### Onboarding a project: `agent-flow-kit paperclip-project`

Create the Project in the Paperclip UI, then run one command on the host:

- **`paperclip-project add --project-id <uuid> --slug <s> --repo <abs-path>
  [--harness claude|codex|opencode] [--max-active n] [--merge human|pm]
  [--accept-mismatch] [--json]`** applies the loader's own checks (slug,
  absolute path, a git repo, a `.afk/gates-allowlist` on the default branch, a
  unique project id, slug and common-dir), then reads
  `GET /api/projects/<id>` with the host key. It refuses a project that is not
  readable (`PAPERCLIP_PROJECT_UNREADABLE`) or archived
  (`PAPERCLIP_PROJECT_ARCHIVED`). When the project has a `codebase.repoUrl`
  that differs from the repo's normalized `origin`, it prints both normalized
  forms and refuses with `PAPERCLIP_PROJECT_REPO_MISMATCH` unless
  `--accept-mismatch` is given; even then the poller still self-blocks the
  project's issues on the mismatch, and the command says so. The write is
  atomic (temp file, rename, mode 600), keeps every other field, and never
  writes to Paperclip.
- **`set --slug <s> [--harness] [--max-active] [--merge]`** changes fields.
- **`remove --slug <s>`** refuses with `PAPERCLIP_PROJECT_IN_USE` while a
  ledger issue pinned to the slug is not closed.
- **`list [--json]`** prints the table with a readiness column: the
  resolution result for the project itself (`ok` or the refusal code from the
  table below), computed with the host key.
- `--merge pm` on the agent-flow-kit repo is refused with
  `PAPERCLIP_MERGE_KIT_REPO` by `add`, `set` and at config load. The kit repo
  is the kit checkout's own git common-dir, or an origin equal (ignoring case)
  to the release repo in `lifecycle/release-policy.json`. A repo with no
  readable origin is refused too. A fork under another owner is not the kit
  repo. When the release policy cannot be read, `merge: pm` is refused with
  `PAPERCLIP_RELEASE_POLICY_UNREADABLE`.
- `remove` and `--migrate` treat a ledger file that exists but does not parse
  as held work and refuse.

### Migrating a v1 config

A v1 config (`agents[]`, one agent and key per project) is never read: the
poller and every verb refuse it with `PAPERCLIP_CONFIG_SCHEMA_OLD`. Convert it
once with **`agent-flow-kit paperclip-config --migrate --project-id <uuid>
[--slug <s>] [--json]`**:

- The single `agents[]` entry's `agent_id` and `key_ref` become
  `host.agent_id` and `host.key_ref`; `host_label` becomes `host.label`; its
  `project`, `repo_path`, `harness` and `max_active_issues` become one
  `projects[]` row. Other top-level fields are kept.
- `--project-id` is required because v1 never recorded a Paperclip project id.
  The slug is the lowercased v1 `project` when that is a valid slug; otherwise
  pass `--slug`.
- `pm_merge_allowed` is dropped, and the command says so.
- Refusals: more than one agent (`PAPERCLIP_MIGRATE_MULTI_AGENT`), any ledger
  issue that is not closed or any file under `notices/claimed/*/`
  (`PAPERCLIP_MIGRATE_STATE_HELD`), or a config that is already v2
  (`PAPERCLIP_MIGRATE_NOT_NEEDED`).
- The old file is copied next to the config as `paperclip.json.v1.<timestamp>`
  (mode 600) before the atomic replace, and the result must pass the loader
  first.
- Migration moves only the config. A pending notice under the old project
  name in `notices/`, and any `pm-start-intents/<slug>.<issue-id>.json`, are not renamed
  to the slug; with no open issues there should be none.

### Repairing a v2 config the loader refuses

The merge checks below refuse the whole config, not just one project row, so
the poller and every verb stop until the file is fixed. This fails closed on
purpose. `paperclip-project set` loads the config first, so it cannot repair
these rows, and `--migrate` handles only v1 files. Edit the config
(`~/.config/agent-flow-kit/paperclip.json`, mode 600) by hand, then run
`agent-flow-kit paperclip-project list` to confirm it loads:

- `PAPERCLIP_CONFIG_INVALID` naming `pm_merge_allowed`: delete that key
  wherever it appears. It never granted anything. Set merge per project with
  `paperclip-project set --slug <s> --merge human|pm` once the file loads.
- `PAPERCLIP_MERGE_KIT_REPO`: in the named `projects[<slug>]` row, set
  `"merge": "human"`. The agent-flow-kit repo, and any repo with no readable
  `origin`, can never be `pm`.
- `PAPERCLIP_RELEASE_POLICY_UNREADABLE`: the kit's
  `lifecycle/release-policy.json` (or `$AFK_RELEASE_POLICY`) is missing or
  unreadable. Repair the kit install. Until then, set `"merge": "human"` on
  every `pm` row so the other projects keep running.

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

## Projects

Two keys pick the work: the issue's assignee picks the host, and its
`projectId` picks the project. The repo always comes from this host's
`projects[]`, never from Paperclip text. Each pass reads the issue's live
`projectId` (`GET /api/issues/<id>`), then the project (`GET
/api/projects/<id>`), and resolves in this order:

| Case | Reason code | Outcome |
|---|---|---|
| `projectId` null or absent | `PAPERCLIP_PROJECT_MISSING` | self-block `Waiting for Josh: set a Project on <identifier>` |
| id not in this host's `projects[]` | `PAPERCLIP_PROJECT_UNMAPPED` | self-block `Waiting for Josh: project not set up on <host>; assign to a host that has it` |
| `GET /api/projects/<id>` not 200 | `PAPERCLIP_PROJECT_UNREADABLE` | no write; held as it was this pass and reported locally. A 404 on 3 consecutive passes becomes `PAPERCLIP_PROJECT_MISSING` |
| project `archivedAt` set | `PAPERCLIP_PROJECT_ARCHIVED` | self-block `Waiting for Josh: project archived` |
| `codebase.repoUrl` set and different from the repo's normalized `origin` | `PAPERCLIP_PROJECT_REPO_MISMATCH` | self-block `Waiting for Josh: project repo differs from <host>'s` |
| repo missing, not a git repo, no `.afk/gates-allowlist` on the default branch, or an unreadable `origin` while `repoUrl` is set | `PAPERCLIP_PROJECT_REPO_NOT_READY` | self-block `Waiting for Josh: <slug> repo not ready on <host> (<sub-code>)` |

The sub-code is `REPO_MISSING`, `NOT_A_GIT_REPO`, `ORIGIN_UNREADABLE` or
`GATES_ALLOWLIST_MISSING`. A refusal text ends with
` · <project id, first 8 hex> "<name>"`, the name control-stripped and cut to
32 characters; it is dropped, and then the reason cut, to stay within the
120-character limit. A long `REPO_NOT_READY` text can lose its sub-code in
Paperclip while the local report keeps it.

- **`waiting_setup`.** An issue that refuses is ledger state `waiting_setup`.
  It holds no slot, sends no notice, starts no PM and gets no claim comment;
  its report cycle is the self-block alone. It is re-resolved from the live
  `projectId` every pass and written only when the outcome changes. Once it
  resolves it is adopted as if new, in `since` order.
- **Pinning and `PROJECT_CHANGED`.** An adopted issue is pinned to its
  project id and slug at first adoption. If its live `projectId` later differs
  (null, another project, or the pinned project no longer on this host), the
  poller stops it: one `stopped` notice with reason `PROJECT_CHANGED` to the
  pinned slug, the slot is released, and the self-block reads `Stopped:
  project changed after claim; reassign to restart`.
- **Origin normalization.** `git remote get-url origin` is parsed in scp form
  (`user@host:path`) or URL form into `host/path`: the host is lowercased;
  `user@`, the port, a trailing `/` and one trailing `.git` are dropped. The
  path keeps its case, since a case difference is a different repository.
- **`paperclip-take --slug <slug>`** claims the notices for one configured
  slug. The old `--project` flag is refused with `PAPERCLIP_FLAG_RENAMED`,
  never aliased.
- **`status/<issue-id>.json` ownership.** `paperclip-report --status` writes
  it, and it owns the file's content. The poller deletes it in exactly one
  case: an issue re-adopted after it closed (`afk_pc_spool_reopen`), so that
  issue starts without its previous declaration. A stopped or `waiting_setup`
  issue keeps its file.

## Notices

Under `$AFK_STATE_DIR/paperclip/notices/<slug>/`, one file per event,
never rewritten: `claimed`, `promoted`, `human_commented`, `stopped`,
`stranded`. A `claimed` notice also writes a
`brief.<issue-id>.<epoch>.<counter>.md` with the issue title and
description. The notice is named `<epoch>.<counter>.<issue-id>.claimed.json`;
the counter keeps re-adoptions distinct and ordered within one second. A
`human_commented` notice writes a
`reply.<comment-id>.md` holding the comment body. Notices never carry Paperclip comment or issue text
beyond what those two file types already declare.

Before a claim comment is posted, the poller saves an issue ledger row with
`claim: intent` and a pending flag. It marks the comment confirmed only after
reading back the fixed claim body and marker from this host agent's comment.
The claimed notice and brief each have a full path in their ledger intent
before the file write. Replay uses that exact path even if `updatedAt`
changes. A definitely rejected claim POST clears its attempt flag for the
next pass; an ambiguous POST or failed read-back holds with an action line.

## Refusal and pause reasons

`PAPERCLIP_NOT_CONFIGURED`, `PAPERCLIP_CONFIG_INVALID`, `PAPERCLIP_ID_INVALID`,
`PAPERCLIP_VAULT_UNAVAILABLE`, `PAPERCLIP_OP_ENV_UNSAFE`, `PAPERCLIP_KEY_AGENT_MISMATCH`,
`PAPERCLIP_KEY_UNAUTHORIZED`, `PAPERCLIP_POLL_BUSY`, `PAPERCLIP_PAUSED`,
`PAPERCLIP_DRAIN_TAMPERED`, `PAPERCLIP_DRAIN_UNREADABLE`,
`PAPERCLIP_AUTHOR_UNVERIFIABLE`, `PAPERCLIP_SELF_BLOCK_FAILED`, `PAPERCLIP_UNREACHABLE`,
`PAPERCLIP_CREDENTIAL_REJECTED`, `PAPERCLIP_RATE_LIMITED`,
`PAPERCLIP_CONFIG_SCHEMA_OLD`, the `PAPERCLIP_PROJECT_*` codes in the table
under [Projects](#projects), and the `PAPERCLIP_MIGRATE_*`,
`PAPERCLIP_PROJECT_IN_USE` and `PAPERCLIP_MERGE_KIT_REPO` refusals of the
onboarding verbs.

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

When optional PM startup is enabled, each inbox pass retries a held start that
has no `pm_started` receipt (or has a definite `failed` receipt), after
rechecking the registry, approval, daily cap and readiness gates. An `intent`
without a receipt joins the recorded start; it never blindly creates another
terminal, and an `ended` start remains held. A PM-start hold such as
`queued: no PM (start held: ...)` stays as the self-block text until the PM
registry confirms a live PM, so an unresolved start does not trigger a report
wake on every timer pass. Ordinary queue text is
cleared when the issue is promoted to `working`.

The report sweep also retries held starts from the host's ledger after inbox
processing as defense in depth alongside the regular blocked-issue retry. It
checks only host-owned `working`, `queued`, and
`waiting_human` rows and shares the pass's one-start guard. A report-cycle
wakeup that overlaps an external wake during the brief, roughly ten-second
live-run interval before the poller self-blocks can be coalesced as the
poller's own run; that wake receives no acknowledgement comment and is
re-blocked by the report cycle.

The poller records the run id returned by its report-cycle wakeup. If that same
run appears in a later inbox sweep, it is treated as the poller's own run and
does not receive the Paperclip-wake acknowledgement comment. A different live
run remains a Paperclip-initiated wake and follows the normal acknowledgement
path.

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
A `429` keeps the entry and backs off for the rest of the pass. A
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
  `handoff_stalled`, `ambiguous`. A PM registration records the terminal's
  identity tuple (`handle`, `runtime_id`, `execution_host_id`,
  `worktree_id`, `tab_id`, `leaf_id`, `incarnation_id`, `agent_type`,
  `recorded_at`, from `terminal show` and `_meta.runtimeId`) in an
  `afk-pm-ownership/3` row when Orca can show the terminal. When it can't,
  the row stays `afk-pm-ownership/2`. The read runs inside the status line,
  so it is bounded to 2 s, and a failed read is retried at most once every
  `AFK_PM_IDENTITY_RETRY_SECONDS` (default 300). Liveness is a join of that tuple against the
  complete `terminal list`, the `worktree ps` agent rows and the runtime id,
  and each owner is in exactly one of five states:
  - **live**: listed with `connected: true` in the recorded runtime, and
    `worktree ps` shows an agent row whose `paneKey` is exactly
    `tab_id:leaf_id` with the registered agent type. Any agent state counts
    (`done` is idle at the prompt).
  - **detached**: listed but `orphaned: true`, or listed with no agent row
    (the agent exited to its shell, or its tab lost its pane). `orphaned`
    means "no pane in the current layout", not "dead". Reported as
    `unknown` with `PM_TERMINAL_DETACHED`.
  - **disconnected**: listed with `connected: false`. Reported as `unknown`
    with `PM_OWNER_DISCONNECTED`.
  - **stale**: in the same runtime, absent from a complete list **and**
    `terminal show` answers `terminal_handle_stale`. Only this state is
    reapable.
  - **unknown**: Orca can't be queried (`ORCA_UNAVAILABLE`), the list is
    incomplete (`ORCA_LIST_INCOMPLETE`), the runtime id differs
    (`PM_RUNTIME_MISMATCH`; an Orca update restarts the runtime and
    reissues every handle while the agents keep running), the terminal is
    absent without the stale proof (`PM_TERMINAL_UNPROVEN`), or the row has
    no usable tuple: an older `afk-pm-ownership/2` row, or a tuple whose
    handle isn't the row's `terminal` (`PM_IDENTITY_UNRECORDED`, until its
    own PM's next registration rewrites it).

  When no owner is live, any detached, disconnected or unknown owner makes
  the lookup `state: "unknown"`, with each owner and its `reason` named in
  `owners`: the repo stays busy and nothing starts. The `orca` field reports
  the list itself: `OK`, `ORCA_UNAVAILABLE` or `ORCA_LIST_INCOMPLETE`.
  **Never reap on uncertainty.**

  **Recovering an owner that stays `unknown`.** Two cases don't clear by
  themselves. `PM_RUNTIME_MISMATCH` persists after every Orca update or
  host reboot, whether the PM survived or not. `PM_IDENTITY_UNRECORDED`
  persists for a dead PM's old `/2` row, because only its own PM rewrites
  it. The kit never reaps either. The operator procedure:
  1. Find the scope in the lookup's `owners[]` (`scope`, `terminal`,
     `worktree.path`).
  2. Check whether an agent process still runs for that session: look in
     `worktree ps` for an agent row in that worktree, and in the harness's
     own session records (for Claude, `~/.claude/sessions/<pid>.json` with
     that session id and a live pid). A live PM can't re-register while its
     old `ownership.json` exists (`pm-start` refuses), so the steps below
     are the same for a live PM and a dead one. Only the last step differs.
  3. Remove that scope's `ownership.json` (and nothing else) from
     `$AFK_STATE_DIR/pm/scopes/<scope>/`.
  4. If the PM is alive, run `agent-flow-kit pm-start --harness <harness>`
     from that PM's own terminal straight away, so the poller never sees
     the repo without an owner. If it is dead, run `pm-start` from a new PM
     terminal, or let the poller start one.

  Before enabling the poller on a host, list the scopes whose rows are `/2`
  or carry an old `runtime_id`, and clear the dead ones this way.
  Re-binding an owner after a runtime change, and an operator-authorized
  reap, are planned separately.

  The PM handoff's successor and close adapters follow the same rule for the
  terminals they create and close: `orphaned` never counts as dead, and a
  close or a replacement is proven only by absence from the list plus
  `terminal_handle_stale`, both in the runtime recorded when the terminal
  was bound. A binding without a runtime id never proves a release.

  `handoff_in_progress`/`handoff_stalled`
  come from a scope's `handoff.json` in state `SUCCESSOR_LAUNCHED` or
  `ACKED`, aged against `pm_handoff_timeout_min` (default 30, from
  `~/.config/agent-flow-kit/pm-registry.json`). When more than one scope for
  the same repo has such a handoff in flight, the lookup never picks one by
  glob order: it reports `state: "ambiguous"` with `reason:
  "PM_HANDOFF_AMBIGUOUS"` and names every one of them in `handoffs`. `stale`
  always lists every owner proven stale.

- **`agent-flow-kit pm-registry-reap --scope <key> [--json]`**: re-proves
  staleness with a fresh join immediately before acting (refuses
  `PM_OWNER_LIVE`, `PM_OWNER_UNKNOWN` or `PM_HANDOFF_IN_PROGRESS`
  otherwise), atomically moves that scope's
  `ownership.json` to `pm/reaped/<scope>.<epoch>.json`, and returns every
  notice claimed under that owner's terminal back to `notices/<slug>/`.
  A notice that cannot be returned — an invalid or unknown project, or a
  same-named file already at the destination — is never left silently
  behind under the dead terminal's claim key: it is moved instead to
  `notices/unreturned/<scope>/`, unless that recovery location is itself
  already occupied by a same-named file, in which case the notice is left
  exactly where it was rather than overwriting anything. Either way it is
  named, by its source path, in the result's `stranded` array, and
  `notices_stranded` counts them; a nonzero count exits `3` even though the
  owner was reaped successfully.

- **`agent-flow-kit paperclip-take --slug <slug> [--json]`**: only the
  registry's live owner for that project's `repo_path` may call it (identity
  is `ORCA_TERMINAL_HANDLE`, checked against the owner's `terminal`; during a
  handoff, the named successor terminal may call it instead — anyone else
  gets `PAPERCLIP_HANDOFF_IN_PROGRESS`). The single `unknown` owner may
  also take from its own terminal, but only when it is unknown because its
  tab is detached (`PM_TERMINAL_DETACHED`: the PM is evidently running), its
  row has no tuple yet (`PM_IDENTITY_UNRECORDED`), or Orca can't be asked
  (`ORCA_UNAVAILABLE`, `ORCA_LIST_INCOMPLETE`). A caller with
  `ORCA_ENVIRONMENT` or `ORCA_PAIRING_CODE` set is a remote-runtime session
  and never qualifies. A disconnected or ambiguous
  owner never authorizes a take: `ORCA_TERMINAL_HANDLE` matching a
  disconnected owner's terminal, or a successor named in one of several
  ambiguous handoffs, both get `PAPERCLIP_NOT_OWNER`. Claims every notice under
  `notices/<slug>/` in order by an atomic `mv` into
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

- **Caller.** The verb resolves the issue's pinned slug from the poller ledger
  (`$AFK_STATE_DIR/paperclip/ledger.json`, `issues[<id>].slug`), then that
  project's `repo_path` from the config's `projects[]`. The caller must be the
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

## Route acceptance and dispatch's Paperclip checks (AFK-PC-4)

A Paperclip story carries `home: paperclip:HOM-<n>` and `paperclip_issue:
<uuid>` in its frontmatter, and its stamp's `task.story_id` matches
`^HOM-[0-9]+\.S[0-9]+$` with the same `HOM-<n>` prefix. Any one of those
markers makes it a Paperclip story; if they disagree, the answer is
`STORY_HOME_INVALID`.

- **Decision digest.** `sha256:` + the sha256 of what `jq -cS '{harness,
  model_profile, effort, cost_class, metered, catalog_version,
  task:{story_id: .task.story_id}}'` prints for the stamp, trailing LF
  included. It is defined once, in `lib/afk-accept.sh`. dispatch.sh does not
  recompute it; it asks `route-accept --verify`.
- **`route-accept --story <story.md> --kind human|override|pm-auto --actor
  <name> [--reason <text>] [--json]`** writes `<story>.acceptance.json`
  atomically: `{schema:"afk-acceptance/1", story_id, decision_digest, kind,
  actor, policy, reason, created_at}`. `STAMP_MISSING` if there is no stamp.
  `override` needs `--reason`. On a story with no Paperclip marker, `human`
  and `override` only record who accepted the route; they bypass nothing.
  On a Paperclip story only `pm-auto` is accepted: nothing ties a `human` or
  `override` record's free-text actor to Josh, and the record lives in the
  worker's worktree, so until native route approvals exist writing one is
  refused with `ACCEPTANCE_KIND_NOT_ALLOWED` (`HARD_EXCLUSION` when the stamp
  carries a hard-exclusion tag), exit 4, nothing written.
- **`pm-auto`** gets `policy: paperclip-free-lane`, and only when all of
  these hold, checked in this order: a Paperclip home
  (`PM_AUTO_NOT_PAPERCLIP`), `override: null` (`PM_AUTO_NOT_NATURAL`),
  `cost_class: free` and `metered: false` (`PM_AUTO_NOT_FREE`), no `security`,
  `iam`, `secrets`, `prod-iac` or `destructive-tools` tag, compared trimmed
  and case-folded (`HARD_EXCLUSION`; a stamp whose `task.tags` is not an
  array of strings is `STAMP_INVALID`), an approved plan (`PLAN_NOT_APPROVED`) that contains the story
  (`STORY_NOT_IN_PLAN`) with the same gates in the same order
  (`STORY_CONTRACT_MUTATED`). On `HARD_EXCLUSION` the PM declares `Stopped`
  or re-plans. That is never a question for Josh. `PM_AUTO_NOT_NATURAL` and
  `PM_AUTO_NOT_FREE` (a metered or other non-free route) mean `Waiting for
  Josh: route`, and the PM tells Josh in chat; dispatch refuses such a story
  until the route changes, since no acceptance it would honour exists for it.
  The plan refusals mean re-plan, or wait for the approval.
- **dispatch, every cycle.** Right after stamp validation and before any
  launch, dispatch.sh runs `agent-flow-kit route-accept --story <s> --verify
  --json` for a Paperclip story. The binary is `launcher.agent_flow_kit` or
  `$AGENT_FLOW_KIT_BIN`, and defaults to `agent-flow-kit`. Anything other
  than `ok` exits 4, prints the reason and writes `<story>.blocked`. The
  reasons are `ACCEPTANCE_MISSING`, `ACCEPTANCE_INVALID` (no
  `afk-acceptance/1` schema, kind or actor), `ACCEPTANCE_KIND_NOT_ALLOWED` (a
  `human` or `override` record, however it got there; `HARD_EXCLUSION` instead
  when the stamp is hard-excluded), `ACCEPTANCE_DIGEST_MISMATCH` (a
  re-route never inherits an acceptance), `PLAN_NOT_APPROVED`,
  `STORY_NOT_IN_PLAN`, `STORY_CONTRACT_MUTATED`, `STORY_HOME_INVALID`,
  `STAMP_INVALID`, and `ACCEPTANCE_UNCHECKABLE` when the answer can't be
  read. The `pm-auto` record is also re-judged against the current stamp's
  lane on every cycle (`PM_AUTO_NOT_NATURAL`, `PM_AUTO_NOT_FREE`,
  `HARD_EXCLUSION`), because the decision digest does not cover `override`
  or `task.tags`. Stories with no Paperclip marker never reach this check.
- **`.afk/` is protected on every home.** After the worker exits, next to
  the secret scan, any path under `.afk/` that changed since the cycle's
  base commit fails the cycle with `AFK_PROTECTED_PATH`. That covers
  committed, staged and untracked changes, ignored files, and moves out of
  `.afk/`. The paths are named, the gates are skipped, and a `.blocked`
  marker is written. If git cannot answer (the base commit is gone and there
  is no `HEAD`, or a `git diff` or `git ls-files` fails), the cycle fails the
  same way with `AFK_PROTECTED_PATH_UNCHECKABLE`; it never reads as clean.

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
the project's PM, using PC-2a's registry lookup for the project's `repo_path`:

- `live`: nothing starts; the PM pulls its own notices.
- `unknown`: nothing starts; an owner that isn't provably stale is kept.
  The self-block text reads `queued: PM state unknown (<reason>)` with the
  lookup's reason (for example `PM_RUNTIME_MISMATCH`), since a detached PM
  may still be running; see the recovery procedure above.
- `handoff_in_progress` / `ambiguous` / `handoff_stalled`: nothing starts;
  the self-block text says so, and an ambiguous/stalled registry state opens
  one out-of-band "NEEDS HUMAN" issue per repo (an `idempotencyKey`).
- Every listed stale owner is reaped with `pm-registry-reap` before deciding.
  The registry is looked up again after every reap attempt, including a
  refusal; the earlier lookup never authorizes a start.
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
`PM <slug> (paperclip)`, running `adapters/orca-pm-bootstrap.sh` with a
`afk-pm-bootstrap-first-start-intent/2` intent (a sibling of the handoff
intent, for a PM with no predecessor). The first instruction is fixed kit
text naming only `<slug>` (`^[a-z0-9-]{1,40}$`) and `<harness>` (the enum);
no Paperclip issue title, description or comment ever reaches the terminal,
the prompt, an argv, or the intent file. The Orca terminal nudge for a live
PM is not implemented (Orca has no foreground-process check; see AD-7).
The title is display text. Before `terminal create`, the poller saves the
issue-specific intent file (`pm-start-intents/<slug>.<issue-id>.json`) and a
`pm_started` ledger row naming it. After the create receipt, the row gains
the handle and create receipt's Orca runtime id, even when `terminal show`
cannot supply the identity tuple yet. A rejected `ORCA_ERROR:*` create is marked
retryable; the next pass can try again. A timeout, CLI failure or missing
handle is uncertain: the poller holds the start with
`queued: no PM (start unresolved: <code>)` and opens one NEEDS HUMAN issue
after three passes. A worktree agent join can record a candidate for the
operator, but cannot turn an unreceipted create into a confirmed PM.

A prior start blocks another PM in the repo while its terminal is live,
detached or unknown. Orca's positive same-runtime stale proof ends that row
and permits a **different issue** in the repo to start a PM. Each issue has
only one effected PM start: an ended row for that same issue stays held as
`queued: no PM (start held: PM_START_ENDED)` and opens one NEEDS HUMAN issue
after repeated passes. Only a definite create non-effect or an operator-set
`failed` row permits that issue to retry. A changed Orca runtime id is
**unknown** and never triggers an automatic restart. A prior row with a
handle but no identity is checked on that handle; a complete same-runtime
list plus `terminal_handle_stale` can prove it ended. For an unresolved row
or runtime change, stop the timer, inspect the row's `intent_file`, `terminal`,
`identity` and `candidate` in `paperclip/ledger.json`, and check Orca for
the terminal. If the PM exists, restore its exact handle and identity. For
an uncertain create, prove that no create took effect before marking the row
`state: "failed"`. For an ended row, confirm that no PM is running and make
an explicit operator decision before setting `failed` to permit a retry.
Remove the issue-specific intent file and restart the timer. Keep the ledger
backup until the next pass confirms the result.

## `agent-flow-kit paperclip-timer --install|--remove|--status [--json]`

Linux only: a systemd **user** service and timer running `paperclip-poll`
every 90s (`OnUnitActiveSec`/`OnActiveSec`, `RandomizedDelaySec=15s`,
`Persistent=false`). The unit holds no secret and no key reference; the
poller reads its config at run time. `--status` also reports
`PAPERCLIP_POLLER_STALE` when the ledger's `last_successful_pass` is older
than 3 intervals, and `PAPERCLIP_VAULT_UNAVAILABLE` or
`ORCA_CLI_NOT_RESOLVED` when the unit cannot read the key or run Orca;
`--install` refuses on the same check (see
[How the poller reads the key](#how-the-poller-reads-the-key)). macOS refuses with `PAPERCLIP_TIMER_UNSUPPORTED_PLATFORM`.

**Stale lock (AC-7b):** the poll lock (`paperclip/.lock`) now carries an
owner PID file. A lock older than 5 poll intervals whose owner PID is
provably dead is reaped (and the pass retried, or `--status` reports clean)
instead of reporting `PAPERCLIP_POLL_BUSY` forever after a `kill -9` or a
reboot.
