# AFK runtime experience

AFK exposes one read-only runtime view across Claude Code, Codex, OpenCode, and
Hermes. The coding harnesses are execution surfaces; Hermes is only the remote
human front door. Routing authority remains the router.

## Status surfaces

`adapters/render-status.sh --harness <harness>` reads only the normalized
lifecycle cache and projects the same fields for every harness: role,
task, phase, harness/model, context pressure, worker state, owner action, update
state, and subscription/reset data. `refresh-status-cache.sh` is the separate
slow producer: harness hooks/plugins start it in the background and it writes
atomically. A render never runs the known multi-second lifecycle status command.
Default cache paths are scoped by a hash of the exact Orca terminal handle; if
no handle is present they require a harness-provided session ID and are scoped
by that ID. Without either identity the adapter publishes no default cache.
The hash is a namespace, not authority. Explicit `AFK_STATUS_CACHE` and
`AFK_STATUS_CACHE_DIR` paths retain their declared meaning. This prevents two
concurrent harness sessions from exchanging model, context, or status data.
Missing evidence is printed as
`NOT_EVALUATED`, never inferred. The timing contract is declared in
`adapters/status-policy.json`: producers throttle refreshes to five seconds and
a cache is visibly `STALE` after 30 seconds. If no usable cache exists, the
renderer prints `AFK UNAVAILABLE[STATUS_UNAVAILABLE]`.

Every harness also feeds that same cache-only segment to a persistent Orca tab
title through `adapters/orca-title.sh`. This is a universal Orca surface, not a
harness-specific status API: Claude retains its status line, Codex retains its
native footer/session message, OpenCode retains its toast, and Hermes retains
its read-only card. Their existing events start the title publisher in the
background, so no additional or duplicate hook/plugin is installed.

The publisher runs only when Orca supplies a terminal handle and a managed
worktree marker. It uses bounded `terminal show` and `terminal rename` calls
that always carry that exact handle; it never lists terminals or falls back to
the active tab. Updates are serialized and throttled per handle (five seconds
by default), control characters are removed, and titles are limited to 120
Unicode code points. `STALE[...]` and `AFK UNAVAILABLE[...]` remain visible in
the title. The adapter reads no harness configuration or credential source.
Before its first rename it privately records the exact current title and a
durable ownership intent. Removal restores that title only while the current
title still equals AFK's last proven value. A user-edited title is treated as
ownership drift and is never overwritten or restored.

Install or remove a presentation with:

```sh
adapters/manage.sh install claude|codex|opencode|hermes
adapters/manage.sh remove claude|codex|opencode|hermes
```

Installation is repeatable and compositional. Claude's wrapper preserves the
entire prior `statusLine` object, feeds its command the original stdin exactly
once, and restores it on removal. On Linux, Claude also composes one synchronous
`SessionStart` update hook beside existing Hindsight and user hooks. Codex uses
the official native
`tui.status_line` items (`model-with-reasoning`, context, five-hour/weekly rate
limits, git branch, and task progress); its session-start hook also surfaces one
AFK-specific `systemMessage`. Its stable updater hook is ordered before that
publisher. Both harnesses point only to
`$AFK_SKILLS_HOME/afk-runtime/bin/afk-session-start`, use a bounded synchronous
hook on Linux, and remove only AFK's exact owned hook shapes. On macOS the
presentation and pressure hooks are installed, but the blocking auto-update
hook is deliberately omitted until AFK has a qualified Darwin candidate-sandbox
backend. The hook publishes only fields present in Codex
hook input, so AFK-specific context remains `NOT_EVALUATED`. OpenCode
registers one local plugin beside the existing Hindsight and Orca plugins. It
awaits one bounded stable-runtime reconcile before normal event callbacks on
Linux,
publishes message/session metadata, and shows an event-driven AFK toast. An
updater failure is a visible warning and refuses plugin startup, so an
unverified Linux session cannot continue through the AFK entrypoint. It is not
retried by later events because no callbacks are registered. On
macOS it skips that reconcile, shows `AFK UNAVAILABLE[MACOS_SANDBOX_PENDING]`,
and continues registering normal status events. OpenCode
v1 documents no persistent custom status-line API, so that surface is explicitly
not qualified. Removal filters only AFK's exact hook/plugin and restores the
prior native status-line value. Credential references are not changed.
Valid OpenCode JSON-with-comments is edited structurally while retaining owner
comments, trailing commas, ordering, and unrelated plugins. Removal restores
the exact pre-install bytes. Ambiguous or duplicate plugin members refuse with
`USER_CONFIG_UNREADABLE` or `USER_CONFIG_CONFLICT` rather than guessing.

Hermes presentation uses `adapters/hermes/status-card.sh`. When invoked inside
an Orca-managed Hermes terminal it schedules the same persistent tab-title
publisher and returns the existing read-only JSON card; outside Orca it only
returns the card. A remote launcher may opt into
`$AFK_SKILLS_HOME/afk-runtime/hermes/session-start.sh -- hermes`, implemented by
`adapters/hermes/session-start.sh`, which delegates to the installed stable
updater before entering its supplied command. That is a wrapper entry contract,
not a native-hook claim. Hermes is not installed on the qualification host, so
its native installation contract remains unqualified and `manage.sh install
hermes` continues to report `HARNESS_NOT_INSTALLED`.

`files/model-router/scripts/harness-inventory.sh` emits a bounded, non-secret
capability inventory. Detection is informational. A harness becomes launchable
only when its exact binding is declared by
`files/model-router/harness-bindings.yaml`, supported by the dispatcher, and
accepted by the routed stamp. The released `POST /v1/route` request remains
unchanged by default. Inventory is attached only after explicit capability
negotiation with `AFK_ROUTE_AVAILABLE_BINDINGS_CONTRACT=1`; the default is off.

## Durable continuation

`agent-flow-kit pm-continue --json` advances one persisted transition through:

```text
OBSERVED -> CHECKPOINTED -> SUCCESSOR_LAUNCHED -> ACKED -> OLD_CLOSED
```

The continuation artifact digest is the transition identity. Replaying the
command reuses that transition and cannot launch a second successor. The old
terminal remains visible until a successor acknowledgement names the same
transition and session, ownership is reconciled, and the closer proves the old
terminal absent. Worker threshold notices are durable files under the dispatch
monitor state; their continuation mode is `canonical`, so a later monitor pass
cannot invent a route or bypass the normal dispatch contract.

PM ownership defaults to a worktree-scoped directory below
`$AFK_STATE_DIR/pm/scopes`. A successor terminal in the same worktree therefore
shares the handoff, while another worktree cannot overwrite or claim it.
`AFK_PM_DIR` remains the explicit override for launchers that already provide a
stronger project/run namespace.

Claude's status-line input supplies an authoritative used percentage and window
size. AFK compares that observation with the frozen thresholds: a routed worker
publishes `CHECKPOINT_DUE` or `CONTINUATION_REQUIRED` once per dispatch/state,
while an exactly bound PM receives its continuation instruction at the next
`UserPromptSubmit` boundary. Codex does not expose equivalent numeric hook data,
so its native `PreCompact` plus compact `SessionStart` events form the
conservative handoff boundary. OpenCode uses
`experimental.session.compacting` and `session.compacted` for the same purpose.
These bridges publish pressure or instructions only; they cannot route, launch,
or close a session. Missing, malformed, stale, or ambiguously bound evidence is
a no-op rather than an invented context estimate.

## Host updates

`bin/afk-session-freshness` is the cheap, non-authoritative offline observation.
It compares the locally accepted revision with the applied revision and reports
`ACCEPTED_LOCALLY`, `UNPROVEN`, `MISMATCH`, or `NOT_EVALUATED`; it never fetches
and therefore cannot claim that the remote source is current.

`bin/afk-release-reconcile --plan` and `bin/afk-release-reconcile --apply` are
the Linux host-scoped reconciliation modes. The remote, ref, and trust root are
compiled into the client; there are no `--source` or `--revision` overrides. It
takes one release lock, fetches and qualifies an immutable revision in a
Linux `bwrap` sandbox, requires clean managed inputs and forward ancestry, then
uses a private snapshot of the already-installed lifecycle driver to plan,
apply, and verify candidate content. The snapshot is allowed only when its
complete copied `bin` and `lib` tree identities match the accepted release
identities recorded in lifecycle state; copy-time mutation and even a
syntactically valid local driver modification fail closed before parsing or
execution. Git receives a minimal clean environment,
and candidate lifecycle code is not executed on the host before acceptance.
The lock record keeps
an ACTIVE child process-group identity; the lock cannot be released or reclaimed
while a mutating descendant survives. A failed prerequisite or gate
retains the recorded last-good revision. Rollback remains the existing explicit
lifecycle operation; the reconciler never activates a bypass. Roll out first to
the declared canary and then by the waves in `lifecycle/release-policy.json`.

Darwin auto-update is not qualified. Claude and Codex omit the blocking updater
hook, and OpenCode does not spawn it. An explicit `afk-session-start` on macOS
refuses with `MACOS_SANDBOX_PENDING`, leaves installed state untouched, reports
retention only for matching recorded last-good/applied revisions, and never
invents verification or executes candidate code without confinement.

## Hindsight boundary

Session start, release reconciliation, and Hindsight enter through fixed
privileged Bash and do not load `BASH_ENV` or a `bash` found on caller `PATH`.
Session bootstrap tools stay on validated system paths, while a separately
canonicalized launch `PATH` remains available to relative harness commands and
adapter-owned tools. Adapter management is bound to the installed sibling
runtime rather than ambient `AFK_SKILLS_HOME`.

AFK does not implement recall/history itself and never installs duplicate
Hindsight hooks or plugins. It checks the installed
`@vectorize-io/hindsight-coding-agents@0.6.0` through its native
`dist/status.js`; `synced:false` is `MEMORY_NOT_SYNCED`, never ready. Blind/off
preparation emits an isolated `HINDSIGHT_CONFIG` plus `HINDSIGHT_DISABLED=true`
boundary containing no credential. Current files, route stamps, approvals, and
gate evidence remain authoritative. Story `memory_mode` is enforced by the
dispatcher as `advisory`, `required`, `blind`, or `off`; `required` fails closed
unless the native Hindsight status is ready, while `blind` and `off` enter the
isolated disabled boundary. Status execution uses a private temporary HOME and
an explicit config path. AFK pins the deterministic staged package and exact
consumed files; it does not claim to reconstruct the upstream npm tarball's
identity. Offline fixtures prove preparation and refusal
behavior. Actual Orca-launched coding-agent recall, retention, attribution, and
outage behavior remain unqualified until the live rows are exercised. OMEGA is
not part of the runtime contract and does not replace this boundary.

## Qualification matrix

The offline adapter fixtures run from `tests/runtime-experience-tests.sh`.
Live rows are intentionally evidence slots rather than claims; qualify only
harnesses installed on the host and record the resulting operation/transition
identities with the release evidence.

| Surface | Offline fixture | Live Orca canary |
|---|---|---|
| Claude Code | cache states; prior-command composition and exact restore | NOT_EVALUATED (live visual canary not run) |
| Codex | native item merge/restore; hook fields stay attributed | NOT_EVALUATED (live `/statusline` canary not run) |
| OpenCode | plugin merge/restore; event cache and toast contract | persistent custom bar unsupported; live toast NOT_EVALUATED |
| Hermes | `HARNESS_NOT_INSTALLED` on this VM | NOT_EVALUATED |
| Universal Orca title | exact-handle fake CLI; async throttle; sanitization; stale/unavailable; owned restore | Qualified on Orca 1.4.199: exact current terminal renamed and prior title restored |
| PM continuation | persisted replay fixture | one successor terminal; matching ACK; old terminal proven closed |
| Fleet release | offline/failure fixture retains last good | canary plan/apply/verify, then declared wave; no duplicate operation |
| Session-start integration | stable synchronous Claude/Codex hooks, ordering, preservation, OpenCode one-shot startup, and Hermes wrapper offline fixtures | live native hook/plugin execution NOT_EVALUATED |
| Context pressure | native event envelopes, exact PM/worker binding, dedupe, retry, and hook preservation | live native threshold/compaction handoff NOT_EVALUATED |
| Blind review | dispatcher-enforced isolated disabled config/env fixture | actual blind routed reviewer NOT_EVALUATED |
