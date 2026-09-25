# Transactional release updates

AFK's release client follows one immutable trust path:

- remote: `ssh://git@github.com/jlengelbrecht/agent-flow-kit.git`
- ref: `refs/heads/master`
- repository root: `d74e7f9542cfe2731e09a0ff5c5e1b4cf325062f`

Those values are compiled into `bin/afk-release-reconcile`. The adjacent
`lifecycle/release-policy.json` must repeat them exactly or the client refuses
to run. Neither command-line flags nor environment variables can replace a
trust anchor.

## Deploy key (required)

The kit repository is private. Before this change the trust anchor was the
HTTPS URL, and the client strips every credential helper, so auto-update could
not fetch a private repository: every host reported
`FETCH_UNAVAILABLE_NO_PROVEN_LAST_GOOD` and never wrote `releases/current.json`.

Hosts now authenticate with a read-only SSH deploy key for this one repository,
held in the vault. It is the only credential the client uses. The fetch, and
only the fetch, adds one `GIT_SSH_COMMAND` to the otherwise empty Git
environment:

```sh
/usr/bin/ssh -F /dev/null -i <key> -o IdentitiesOnly=yes -o IdentityAgent=none \
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile=<runtime>/bin/afk-release-known-hosts \
  -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no \
  -o PreferredAuthentications=publickey -o BatchMode=yes -o ConnectTimeout=10
```

No ssh agent, user or system ssh config, user `known_hosts`, or credential
helper is consulted.

- **Key path.** `AFK_RELEASE_DEPLOY_KEY`, defaulting to
  `~/.config/agent-flow-kit/deploy-key/agent-flow-kit_ed25519`. It must be a
  regular file (not a symlink) owned by the user with mode `0600`, and must not
  sit inside the installed runtime or the release state directory; both checks
  compare fully resolved paths, so a symlinked parent or `..` cannot hide it
  there. Every
  directory above it, up to `$HOME` (or `/` for a key outside `$HOME`), must be
  owned by the user or root and must not be group- or world-writable. The
  client reads the key in place through ssh and never copies, hashes, or logs
  it.
- **Distinct refusals.** A missing, unreadable, linked, or wrongly-moded key,
  or one under an unsafe directory, yields `DEPLOY_KEY_UNAVAILABLE` before any
  network attempt, so "no key" is never confused with `FETCH_UNAVAILABLE`
  (offline). A missing ssh binary or pinned host-key file yields
  `RELEASE_TRANSPORT_UNAVAILABLE`. A key path or pinned host-key path holding
  whitespace, `'`, `"`, `\`, `%`, or `#` yields `SSH_OPTION_PATH_UNSAFE`
  before any fetch, because OpenSSH re-parses those characters inside option
  values; move the key (or the runtime) to a plain path. When the fetch itself fails, its stderr goes
  to a private scratch file in the release state, is matched against fixed
  strings, and is deleted; the raw text is never recorded:
  - `Host key verification failed` or `REMOTE HOST IDENTIFICATION HAS CHANGED`
    gives `HOST_KEY_MISMATCH`. The server did not present a pinned GitHub key.
    That can be a GitHub host-key rotation, or it can be interception. It needs
    owner attention: compare against GitHub's published fingerprints before
    changing anything.
  - `Permission denied (publickey)` gives `DEPLOY_KEY_REJECTED`: GitHub refused
    the key. It was probably removed from the repository's deploy keys, or the
    host holds the wrong key.
  - `ERROR: Repository not found.` gives `REPOSITORY_ACCESS_DENIED`: the key
    authenticated but cannot read the repository. The key may be registered on
    a different repository, or the repository was renamed or removed.
  - Any other failure stays `FETCH_UNAVAILABLE`.

  With a proven last-good release, `--apply` still retains it under any of
  these reasons.
- **Existing mirrors.** A mirror created by the HTTPS-anchored client has its
  stored origin rewritten to the SSH anchor on the next fetch. Only that exact
  legacy value is migrated; any other stored origin is still refused as
  `RELEASE_MIRROR_UNTRUSTED`.

### Enrolling a host (once)

Run one line from the host's kit checkout, with that host's own 1Password
reference:

```sh
git pull --ff-only && bin/agent-flow-kit update && bin/agent-flow-kit enroll-auto-update --key-ref <ref>
```

| Host | `<ref>` |
| --- | --- |
| devbox, Mac | `op://develop/afk-release-deploy-key/notesPlain` |
| cachyos | `op://AI-Access/afk-release-key/notesPlain` |

`enroll-auto-update --key-ref <op://…> [--key-file <path>]` is idempotent. It
reads the key with `op read` into a private scratch file and compares its
`ssh-keygen -l` fingerprint with `deploy_key_fingerprint` in
`lifecycle/release-policy.json` (the only place the fingerprint is declared).
On a match it installs the key at the key path above with mode `0600`; on a
mismatch, a value that is not a key, a missing `op`, an unreadable reference,
or something other than a regular file at the key path it refuses (exit 4,
`FINGERPRINT_MISMATCH`, `KEY_UNPARSEABLE`, `OP_UNAVAILABLE`,
`KEY_REF_UNREADABLE`, `KEY_PATH_OCCUPIED`) and installs nothing; the scratch
file is removed on every exit. A `--key-file` path with whitespace, quotes,
`\`, `%`, `#`, `$`, or control characters is refused before anything is read
(exit 1, `KEY_PATH_UNSAFE`). Before the key or any scheduler is touched it
checks that the runtime is installed: the release client (Linux) or the kit
command (macOS) is executable, and the policy and the pinned known-hosts file
exist; otherwise it refuses (exit 4, `NOT_READY`) and writes nothing. It then
installs and enables the scheduler, records the reference and the key path
(never the key) in `~/.config/agent-flow-kit/auto-update.json` only once the
scheduler is really enabled, runs the first attempt with that key under the
same 600-second `timeout` as the unit (`first_attempt=TIMED_OUT` when it
expires), and prints one `auto-update: ENROLLED …` line. If the scheduler
cannot be enabled it removes the units and the config and exits 5
(`SCHEDULER_UNAVAILABLE`); on macOS, when a previous agent was loaded, it puts
that agent and its config back instead. On a Linux re-enrollment it keeps the
config, restores the previous unit files, reloads, and restores the timer's
previous enabled and active state. If the reload itself failed, systemd never
saw the new units, so it only puts the files back. When any rollback step
fails it reports `ROLLBACK_FAILED` and names the step rather than claiming a
restore. The key's bytes are never printed, logged, or copied anywhere else.

On Linux, enrollment applies the release client's own key rule (every parent
directory owned by the user or root and not group- or world-writable, outside
the runtime and state trees) before reading the key, and the whole rule,
including mode `0600`, again before scheduling anything, so it never prints
`ENROLLED` for a key the client would refuse as `DEPLOY_KEY_UNAVAILABLE`.
`tests/auto-update-enroll-tests.sh` runs both implementations on the same
fixtures. Enrollment walks every parent first. If `~/.config/agent-flow-kit` is
the only failing directory, fails only the write-bit rule (a umask of `002`
leaves it `775`), is a real directory below `$HOME` rather than a symlink, and
is owned by you, enrollment removes group and world write from it and says so.
In every other case it changes nothing and refuses with exit 4 and
`KEY_PARENT_UNSAFE`:

- **A group- or world-writable directory.** The refusal prints the exact
  command to run, for example `chmod go-w -- '/home/you/.config'`. When
  `~/.config/agent-flow-kit` is writable too, the one command names both.
- **A directory owned by neither you nor root.** `chmod` cannot fix that.
  Choose another key path below directories you own with `--key-file`.
- **A symlinked `~/.config/agent-flow-kit`** with the key below it. Enrollment
  never changes permissions through a link. Make it a real directory or choose
  another `--key-file`.

`--check` and `--remove` are exclusive and refuse `--key-ref` and
`--key-file`. They, and `status`, use the key path enrollment recorded unless
`AFK_RELEASE_DEPLOY_KEY` is set.

- **Linux.** A systemd user service and timer
  (`~/.config/systemd/user/afk-release-reconcile.{service,timer}`) run the
  installed `afk-release-reconcile --apply` every `check_interval_seconds`
  (policy, default 900) with a 600-second start timeout and `Persistent=true`.
  If the user manager does not linger, the summary line says so and names
  `sudo loginctl enable-linger <user>`; the command never runs sudo itself.
- **macOS.** A launchd user agent
  (`~/Library/LaunchAgents/io.github.jlengelbrecht.agent-flow-kit.update-check.plist`)
  runs `agent-flow-kit enroll-auto-update --check` on the same interval, with
  a fixed `PATH` (`/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin`). The
  check reads the trusted ref with `git ls-remote` over the same pinned-key SSH
  transport, compares it with the applied revision, and records
  `UPDATE_AVAILABLE`, `CURRENT`, or `CHECK_FAILED` in
  `$AFK_STATE_DIR/auto-update-check.json`. It never applies; the human or an
  agent runs `agent-flow-kit update`. `MACOS_SANDBOX_PENDING` below is
  unchanged. Re-enrolling waits (bounded) for `launchctl bootout` to finish
  before `bootstrap`, and retries `bootstrap` up to three times.

`agent-flow-kit status` reports whether the host is enrolled (asking
`systemctl --user is-enabled` or `launchctl print`, not the files) and the last
result (the release client's `releases/latest.json` on Linux, the check file
on macOS), including "update available: <revision>" only while that revision
differs from the applied one.
`agent-flow-kit enroll-auto-update --remove` removes the scheduler and the
config and leaves the key in place.

To rotate the deploy key, add the new public key to the repository's deploy
keys, update `deploy_key_fingerprint` in the policy and the vault item, ship a
release, re-run `enroll-auto-update` on each host, then delete the old deploy
key on GitHub.

### Pinned GitHub host keys

`bin/afk-release-known-hosts` ships GitHub's published `github.com` host keys
and is installed with the runtime `bin` tree. Current SHA256 fingerprints:

- ed25519: `SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU`
- ECDSA: `SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM`

`tests/release-reconciler-contract-tests.sh` checks the file against these
fingerprints. If GitHub rotates its host keys, the fetch fails closed with a
host-key mismatch (reported as `HOST_KEY_MISMATCH`). To rotate: take the new
keys from GitHub's published SSH key fingerprints page (or
`https://api.github.com/meta`), cross-check with `ssh-keygen -lf`, update
the file, the fingerprints above, and the contract test together, and ship a
release. Hosts that cannot fetch must be updated by a manual install.

## What an update does

`afk-release-reconcile --apply` creates an AFK-owned bare mirror below the
declared state directory, performs a bounded fetch of the exact trusted ref,
and resolves it to a commit. It rejects shallow or differently configured
mirrors, an unexpected root, incompatible lifecycle declarations, and any
candidate that is not a forward descendant of the installed revision.
Every Git invocation starts from a minimal clean environment; ambient work-tree,
index, object-directory, configuration, credential-helper, askpass, SSH, and
transport controls cannot redirect release reads, writes, or helper execution.

The client checks out the commit on `master` in a fresh isolated candidate
directory. It never pulls, resets, stashes, switches, cleans, or otherwise
changes the user's development clone. A candidate must pass its fast release
qualification inside the qualified Linux `bwrap` sandbox. The client then
snapshots the already-installed lifecycle driver and its fixed library set into
private release state. Before any copied driver is parsed or executed, the
client computes the complete private snapshot `bin` and `lib` tree identities
and requires exact matches with the accepted-release identities recorded in
`state.json`. Copy-time mutation and syntactically valid local drift are refused,
and a mismatched private snapshot is removed.
That trusted snapshot plans, applies, and verifies with
the clean candidate as canonical input; candidate lifecycle executables and
libraries are not run on the host before acceptance. Only a zero-approval,
zero-conflict `NO_CHANGE` or
`MUTATION_REQUIRED` plan with exact prior and target revisions is eligible.
The lifecycle engine then performs its normal plan/apply/verify transaction.
The release client does not use an approval bypass.

The approval is the plan's `extra.plan.plan_identity`, passed unchanged to
`update --json --approve-plan`. There is no `extra.plan.identity` field; a
script that reads one passes the string `null` and is refused with
`PLAN_APPROVAL_MISMATCH`. To reproduce the client by hand:

```sh
P="$(bin/agent-flow-kit update --json --plan)"
bin/agent-flow-kit update --json --approve-plan "$(jq -r .extra.plan.plan_identity <<<"$P")"
```

The lifecycle names an operation only when it takes its lock, so a no-change
result and any refusal decided before the lock carry `operation.id: null`. The
client accepts a null id only for `NO_CHANGE`, `REFUSED` and
`APPROVAL_REQUIRED`; any other result without an id is unreadable. A no-change
apply is verified and recorded in `releases/current.json` like a convergence,
and ends `CURRENT` / `ALREADY_CURRENT`. A refusal ends `RETAINED` /
`APPLY_REFUSED` (`STALE_PLAN`, `ROLLED_BACK` and `UNRECOVERABLE` keep their own
reasons), and the attempt record's `operation.reason` carries the lifecycle's
reason when it is one of the codes `afk_reason_codes` or
`afk_mutation_reason_codes` publish in the trusted driver; other text is never
recorded. `APPLY_RESULT_UNREADABLE` means the document itself could not be
read.

Examples:

```sh
bin/afk-release-reconcile --plan
bin/afk-release-reconcile --apply --cohort canary
```

Planning may refresh the AFK-owned mirror, candidate cache, and attempt log,
but cannot mutate installed lifecycle state. Applying records a candidate as
last-good only after lifecycle verification succeeds.

## Session and workflow start

Enrolled launchers should enter through the lifecycle-installed stable command
`$AFK_SKILLS_HOME/afk-runtime/bin/afk-session-start`. It reconciles before
running the requested command and can idempotently compose an adapter for the
harness being launched:

```sh
$AFK_SKILLS_HOME/afk-runtime/bin/afk-session-start --adapter claude -- claude
$AFK_SKILLS_HOME/afk-runtime/bin/afk-session-start --adapter codex -- codex
$AFK_SKILLS_HOME/afk-runtime/bin/afk-session-start --adapter opencode -- opencode
```

Adapter composition derives `manage.sh` from the installed session entrypoint's
canonical sibling runtime. Ambient `AFK_SKILLS_HOME` cannot redirect it; the
variable is rebound only for that verified installed runtime. Hook commands
never point into the candidate cache. The session, release, and Hindsight
entrypoints start with fixed privileged Bash and clear startup-file influence;
their bootstrap helpers use only validated system paths. A separately
canonicalized caller `PATH` is retained for the requested harness and adapter
tools, so relative `codex`, `opencode`, or user-installed `yq` commands still
work without joining the trusted bootstrap surface. On Linux, Claude and Codex each receive one synchronous,
30-second `SessionStart` command hook for that exact stable updater. Codex orders it
before AFK's session publisher; its pre-compact hook remains presentation-only.
Adapter installation writes these registrations but never executes the updater,
so composing an adapter cannot recursively start reconciliation. Repeated
composition verifies the owned hook shape and does not add another copy.

Existing unrelated Claude settings and Codex hooks—including Hindsight, Orca,
and user hooks—keep their relative order and are preserved on removal. A
conflicting owner-controlled field causes an owner-action failure; it is never
overwritten. If the stable updater later becomes unavailable, the native
synchronous hook fails visibly instead of falling through to an unverified
candidate. The updater does not inspect or copy secret files, environment
values, credentials, or command output into its attempt records.

OpenCode's single installed plugin awaits one bounded call to the same stable
updater on Linux when the plugin starts, before registering normal AFK event work. A
missing, failed, or timed-out updater produces an `AFK UNAVAILABLE[...]`
warning toast; updater output and environment values are not copied into that
message. Event callbacks do not rerun reconciliation.

Darwin currently has no qualified candidate-sandbox backend. Claude and Codex
still install their AFK presentation and context-pressure hooks but omit the
blocking release-reconcile hook. OpenCode emits
`AFK UNAVAILABLE[MACOS_SANDBOX_PENDING]`, skips startup reconciliation, and
continues normal status events. An explicit `afk-session-start` on macOS leaves
installed state unchanged, reports retention only when matching last-good and
applied revisions are actually recorded, refuses with the same reason, and
never synthesizes verification or runs unconfined candidate code. This is usable
degraded operation, not a macOS auto-update qualification claim.

Hermes is still a remote presentation-only surface and has no qualified native
hook on this host. A remote launcher may explicitly adopt the wrapper contract:

```sh
$AFK_SKILLS_HOME/afk-runtime/hermes/session-start.sh -- hermes
```

The wrapper delegates to the stable updater before the supplied command and
fails visibly if that installed entry is absent. This wrapper contract does not
change `manage.sh install hermes`: local native integration remains
`HARNESS_NOT_INSTALLED`/unqualified until it is tested on a Hermes host.

When the fetch is offline or times out, a session continues only if
`current.json` names the exact installed revision, its isolated checkout is
still clean, and that candidate's offline lifecycle verification succeeds.
The release result then says `RETAINED`, `FETCH_UNAVAILABLE`, and
`last_good_verified: true`. With no such proof, the session is blocked.

`afk-session-freshness` is deliberately cheaper and weaker: it only describes
local recorded state for prompts or status lines and always reports
`launch_authoritative: false`.

## Locking, attempts, and rollout meaning

One release-client lock serializes fetch, qualification, and reconciliation on
a Linux host. Its owner record binds host, boot, PID, process-start identity, a
random incarnation, and any ACTIVE child process group. A command is held behind
a start gate until that group is atomically published. A leader exit does not
clear the record while descendants survive, and a killed parent cannot make the
lock reclaimable until the recorded group is gone. A demonstrably dead
same-host owner can be recovered using an atomic arbitration marker; live,
foreign, incomplete, or ambiguous owners are retained for owner action.

Repeated session starts inside `check_interval_seconds` skip the network only
after re-proving the recorded last-good candidate against installed state.
`afk-release-reconcile --force-check --apply` bypasses that throttle.

Secret-free attempt summaries are written with mode `0600` below
`$AFK_STATE_DIR/releases/attempts`, with the latest summary at
`releases/latest.json`. `releases/current.json` is advanced only after a
verified success. Failure to persist a required attempt or latest summary is a
blocking reconciliation failure even when the underlying lifecycle operation
already completed; a later start must re-prove durable state before launching.

The `canary` and `wave` cohort names are honest observation metadata, not a
promotion gate. `rollout_authoritative` is always false and all enrolled hosts
automatically follow the same canonical ref. AFK does not claim that this
client provides centralized canary promotion.
