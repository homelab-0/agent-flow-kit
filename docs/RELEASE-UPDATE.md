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

### One-time host provisioning

1. Take the private key for the `agent-flow-kit` read-only deploy key from the
   vault. Never commit it or place it under `$AFK_SKILLS_HOME`.
2. Install it with the right mode from the start:

   ```sh
   install -d -m 700 ~/.config/agent-flow-kit/deploy-key
   (umask 077; <read the key from the vault> \
     >~/.config/agent-flow-kit/deploy-key/agent-flow-kit_ed25519)
   chmod 600 ~/.config/agent-flow-kit/deploy-key/agent-flow-kit_ed25519
   ```

3. Run `$AFK_SKILLS_HOME/afk-runtime/bin/afk-release-reconcile --plan --force-check`
   and confirm the reason is no longer `DEPLOY_KEY_UNAVAILABLE` or
   `FETCH_UNAVAILABLE_NO_PROVEN_LAST_GOOD`.

To rotate the deploy key, add the new public key to the repository's deploy
keys, replace the file on each host (same path, mode `0600`), confirm a
`--plan --force-check` succeeds, then delete the old deploy key on GitHub.

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
