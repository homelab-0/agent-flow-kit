# agent-flow-kit lifecycle contract

The documented, versioned machine contract for the lifecycle entry point
(`bin/agent-flow-kit`). Automation reads this document and the `schema`
subcommand; it never parses human output.

Result schema version: **1.0**
Supported lifecycle schema major: **1**
Supported state schema major: **1**
Supported execution-stamp schema major: **1**
Supported validator contract major: **1**
Supported target wiring major: **1**
Supported orchestration state major: **1**
Supported dispatch watch schema major: **1**

Machine-code meaning does not change inside a schema major version. New states,
reason codes and fields may be added; existing ones do not silently change
meaning.

Every vocabulary in this document appears in a `machine-checkable` block. The
deterministic gates compare each block against the corresponding array emitted
by `agent-flow-kit schema`, element for element, so this document cannot drift
away from the executable that implements it.

## Scope of this increment

| Command | Behaviour |
|---|---|
| `status` | Read-only installed state, ownership, drift, adaptations, source eligibility, target wiring, orchestration summary, dispatch-monitor summary, readiness scopes. Writes nothing. Probes nothing external unless `--live` is requested. |
| `adopt --inspect` | Inspect-only adoption analysis. Reports a disposition and changes nothing. |
| `adopt` | The adoption transaction: establishes durable ownership at the identities already installed, verifies offline, then commits the manifest. |
| `update` | Deterministic convergence for an adopted host: plan, backup, journal, write, verify, commit — or refuse. |
| `verify` | Verification of installed state against the applied-state manifest. Observes and proves; never repairs. Offline unless `--live` is requested. |
| `monitor` | The durable worker-completion watch and the provenance-bound release of the resources a settled worker owned. One bounded pass per invocation; read-only without an action verb. |
| `schema` | Emits this contract's vocabularies as JSON. |

`--plan` turns `adopt` or `update` into a computation: it emits the complete
plan and writes nothing at all.

<!-- machine-checkable: commands -->
```
status
adopt --inspect
adopt
update
verify
monitor
schema
```
<!-- end -->

`status` and `verify` accept `--live`, `--synthetic-route`, `--stamp <path>`
and `--target <id>`. Everything else on the surface is deterministic and
offline: without `--live`, no lifecycle command executes another program, opens
a socket, authenticates anywhere, or creates a temporary file.

Default `status`, `adopt --inspect`, `verify`, `monitor` without an action verb
and every `--plan` invocation are pure functions of local state. They emit no
timestamp, so two runs over unchanged state produce byte-identical machine
output — which is what makes idempotence testable rather than asserted. A live
run does emit observation timestamps, because an external observation without
one is not evidence.

## Command output

Both renderings derive from one normalized model. `--json` prints the document;
human output is projected from that same document, so the two cannot drift. The
projection is complete: every component, target, adaptation, finding, readiness
scope, live fact, environment record, orchestration field, dispatch record,
plan entry, operation step and verification check in the document appears in
the human rendering, with its state and its reason.

```
{
  "schema_version": "1.0",
  "kind": "lifecycle_result",
  "command": "update",
  "operation": {"id": ..., "mutating": true, "result": ..., ...},
  "checkout":  {...},
  "installed": {...},
  "source_eligibility": {...},
  "readiness": {...},
  "live_facts": {...},
  "orchestration": {...},
  "dispatch_monitor": {...},
  "environment": [...],
  "components": [...],
  "targets": [...],
  "adaptations": [...],
  "findings": [...],
  "extra": {"plan": {...}, "verification": {...}, "adoption": {...}},
  "overall": {"state": "...", "exit_code": 0},
  "next_safe_action": "..."
}
```

A result that does not present exactly this shape is never printed and never
becomes an exit code: assembly failure is an internal failure (exit 1), because
a partially built model is precisely the "claimed" state this product refuses.

### `checkout`

Repository identity is **not** the directory name. It is the checkout's root
commit (`identity_method: "root_commit"`), combined with a readable
`lifecycle/kit.json` declaring `kit_id: "agent-flow-kit"`. A checkout that
cannot produce both is `SOURCE_REPOSITORY_UNIDENTIFIED`.

`lifecycle/kit.json` is a **complete recognized shape or it is nothing**. It
must declare, with these types:

| Member | Requirement |
|---|---|
| `kit_id` | non-empty string |
| `lifecycle_schema_version` | string `<major>.<minor>` |
| `state_schema_version` | string `<major>.<minor>` |
| `default_branch` | non-empty string |
| `managed_inputs` | non-empty array of relative, non-empty strings without newline or tab, never absolute, never containing a `..` segment |

A declaration that parses but is incomplete is `SOURCE_DECLARATION_INCOMPLETE`;
one that does not parse is `SOURCE_DECLARATION_UNREADABLE`. Both block mutation.
Partially honouring a declaration is worse than refusing it: a missing
`managed_inputs` would make every uncommitted change invisible to dirty-source
detection, and a missing `default_branch` would make every branch canonical.

`checkout.declaration` reports `ABSENT`, `UNREADABLE`, `INCOMPLETE` or
`COMPLETE`. `managed_inputs` is carried through as an array end to end, so a
declared path containing a space stays one path.

A `lifecycle_schema_version` whose **major** differs from the supported major —
in either direction — is `SOURCE_LIFECYCLE_SCHEMA_INCOMPATIBLE`. A newer major
may mean anything; an older major means the fields this executable reads had a
different meaning.

### `installed`

`adopted` is true only when a state manifest exists, presents a supported
schema, **and** presents the complete recognized manifest shape:

| Member | Requirement |
|---|---|
| `state_schema_version` | string `<major>.<minor>` |
| `applied_revision` | 40-character lowercase hex |
| `repository.identity` | non-empty string |
| `components` | object; every value has non-empty `identity`, `ownership` and `path` |
| `adaptations` | array |
| `targets` | array; every element has non-empty `id` and `path` |

The shape is validated **before** the manifest is treated as adopted and before
any field of a recognized older schema is interpreted. A manifest that fails is
`STATE_MANIFEST_SHAPE_INVALID` and requires an owner.

The manifest and journal paths are themselves guarded: each must be a regular
file whose parent chain stays inside the declared state directory. A redirected
or wrongly typed path is `STATE_MANIFEST_PATH_UNSAFE` /
`OPERATION_JOURNAL_PATH_UNSAFE`.

Kit state is not user content. Every mutating command creates the declared
state directory at `0700` and writes the manifest, the journal and the lock
owner record at `0600`, through one temporary name and one rename — the journal
in particular is read back as recovery authority, so it is not left at whatever
umask the invoking shell happened to carry. Read-only commands never create or
change any of it.

`journal_state` is `NONE`, `COMMITTED`, `OPEN`, `UNREADABLE` or `UNSAFE`.
Anything other than `NONE` or `COMMITTED` makes the installation `INTERRUPTED`
rather than stably healthy: an unreadable journal proves nothing was completed.

`lock_state` is `NONE` or `HELD`. A held lock means another lifecycle operation
is mutating this installation right now, so read-only status reports
`INTERRUPTED` and a **transient** blocking finding rather than a stable healthy
result. Status only observes the lock; it never takes one.

A lock carries an owner record naming the host identity, the boot identity, the
pid and that process's start identity — the four facts that make "is that
process still running?" decidable — and an **incarnation**, a value unique to
that one acquisition, which makes "is this still the same lock?" decidable too.
A mutating command refuses with `CONCURRENT_OPERATION_IN_PROGRESS` only when the
owner is proven **live**. An owner this host can prove is gone — a pid that no
longer exists, a pid now belonging to a different process, or a lock taken
before this host booted — is reclaimed, and the reclamation is reported as
`OPERATION_LOCK_RECLAIMED`. Anything else — a lock taken on another host, an
owner record that is **present** and incomplete, unparseable or written in an
unknown schema, a record naming no usable incarnation, or a host that cannot
answer the liveness question — is neither waited on nor reclaimed: it refuses
with `OPERATION_LOCK_OWNER_UNVERIFIABLE` and names the lock directory the owner
must remove.

Taking a lock is two steps that cannot be one: the directory appears atomically,
and the owner record appears inside it an instant later. A lock that exists and
carries **no owner record at all** is therefore not one of the conditions above
— it is a lock in the middle of being taken. An acquisition waits for the record
to appear, boundedly, and judges again; the wait belongs to the acquisition as a
whole rather than to each look, so the ceiling holds however often the lock
changes hands underneath it. A lock that still carries no record when that wait
is spent is refused as unjudgeable exactly like the others, and the refusal says
what was actually established — that no record appeared while the lock was
watched — rather than claiming a certainty the budget cannot buy: the budget
belongs to the acquisition, so an acquisition that already spent it on an
earlier lock refuses on what it saw, not on a full watch of this one. Every
other unjudgeable record is a diagnosis rather than a moment and is refused at
once, without waiting. Read-only paths never
wait: `status` reports the lock as `HELD` and moves on.

A record is installed by renaming one complete temporary file onto its name, so
a partial, empty or half-written record is never observable: a read of it
returns a whole record or nothing at all. A record that cannot be read
**because it is no longer there** — released or reclaimed between the moment it
was found and the moment it was read — is therefore not an unparseable record
either: it is the same moment as a lock still being published, and it is waited
on and judged again on the same budget.

The two are told apart by **one** observation. The record is read once and
judged on the bytes that read returned: bytes that were read and do not parse
are a diagnosis, and no bytes are the moment. Asking the filesystem a second
time would be asking about a second instant — long enough for a successor to
take the freed path and publish a valid record under the same name, which the
second look would then report as damage and refuse, telling an owner to remove
a lock a live process holds.

Observing a lock does not authorize removing it. Both destructive steps are
single-winner and are decided on the incarnation, not on the observation:

- **Reclamation.** A process that judges a lock abandoned must first win an
  arbitration marker named for the exact incarnation it judged, linked into the
  lock directory itself; `link` refuses an existing name, so exactly one
  process holds it. The winner re-judges the record from scratch, proves the
  incarnation has not moved, renames the directory aside, and proves that what
  it moved is the incarnation it judged before removing anything. A process
  that loses the marker, or whose incarnation has moved, touches nothing — so a
  stale observation can never delete a successor's live lock. A marker left by
  a reclaimer that died is itself judged by these rules and recovered. The
  marker lives inside the lock directory, so the winner's rename carries it
  away: a loser that finds the marker **gone** has observed that handover, not
  a reclaimer it cannot judge. It refuses nothing and removes nothing — it
  looks again, and finds either a free lock path or the successor that now
  holds it. The reclamation is reported by the process that performed it, at
  the moment the abandoned lock is destroyed — not by the acquisition that
  follows it. The mkdir on the freed path can be lost to a contender, and a
  reclaimer that only reported itself when it won that race would destroy
  another process's lock in silence, while the contender that took the freed
  path reclaimed nothing and has nothing to report. Exactly one
  `OPERATION_LOCK_RECLAIMED` is reported for each abandoned lock destroyed,
  whether the run that destroyed it goes on to converge or to refuse.
- **Release.** A process removes only the exact incarnation it installed. It
  re-reads the record, renames the directory to a private name, proves the
  record it moved is still its own, and removes only that. A former owner whose
  lock was reclaimed underneath it removes nothing.

The release happens the moment the owning process can no longer write — on an
ordinary run immediately after the transaction settles, and on an interrupted
run at exit through the `EXIT` trap, whose release is an idempotent no-op when
the ordinary release already ran — and never earlier than that moment. A
command asked to stop — `SIGINT`, `SIGTERM`, `SIGHUP`, or any other signal that
would otherwise terminate this process on its own (`SIGUSR1`, `SIGUSR2`,
`SIGALRM`, `SIGPIPE`) — therefore **terminates**, rather than cleaning up and
returning to what it was doing, and it terminates only once the write it was
running has finished. Both halves are the same guarantee: a cleanup that
returned would hand the lock to the next contender while this process was still
inside its transaction, and a signal nothing handled would hand it back at the
instant the shell died, with the copy it had already started still running.
Either way two processes would be writing one installation with neither of them
dead. Such a run exits `128 +` the signal number and produces no result
document, because it reached no result. `SIGQUIT` is deliberately not in that
set: it is ignored outright, so it interrupts no transaction and can free no
lock.

The same `EXIT` boundary removes the validator fixture directory an explicit
live evaluation may have created. That directory, under the system temporary
directory, is the only path outside the declared state directory this
executable ever creates, and a run that dies mid-probe must not leave it behind.

A process that dies without running its cleanup at all — `SIGKILL`, an OOM
kill, a power loss — leaves its lock exactly where it was, and that lock is what
reclamation is for. Reclamation clears it whenever the record it left behind can
be judged, so a killed run does not leave an installation busy. It cannot clear
one case: a death inside the publication window, after the lock directory
appears and before the owner record appears inside it. That lock carries no
record to judge, so it is refused as unjudgeable rather than reclaimed, and the
installation stays busy until the operator confirms nothing is running and
removes the named lock directory by hand.

### `source_eligibility`

Reported in its own scope. An ineligible checkout blocks mutation and never
turns a separately verified installation into `BROKEN` or `NOT_READY`.

`revision_relation` is `SAME`, `AHEAD`, `BEHIND`, `DIVERGED`, `UNREACHABLE` or
`NOT_EVALUATED`. `explicit_intent` records whether
`--allow-noncanonical-source` or `--allow-rollback` was supplied.

Independence is about **reporting**, not about permission: every mutating
operation records a canonical revision, so `adopt` and `update` refuse on an
ineligible source (exit 4) while installed integrity keeps its own state and
`verify` keeps proving installed content without a source at all.

<!-- machine-checkable: source_states -->
```
ELIGIBLE
SOURCE_INELIGIBLE
```
<!-- end -->

### `readiness`

Each scope carries `state`, `evaluated`, `reason` and `evidence_provenance`.
The four execution scopes are produced **independently**, and a dependency
failure blocks only the narrowest scope it invalidates.

| Scope | State vocabulary | Behaviour |
|---|---|---|
| `INSTALLED_INTEGRITY` | an overall state | Evaluated offline from hashes and path structure. |
| `MUTATION_SOURCE_ELIGIBLE` | `TRUE` / `FALSE` | Evaluated from Git state. |
| `HOST_EXECUTION_READY` | a readiness state | `NOT_EVALUATED` without `--live`. With `--live`: `TRUE` only when installed integrity is proven, Orca is usable, a compatible validator is usable, and at least one complete centrally approved harness path is usable. |
| `NEW_WORK_READY` | a readiness state | `NOT_EVALUATED` without `--live`. With `--live`: requires the router **in addition to** host readiness. |
| `TARGET_READY` | a readiness state | Evaluated offline per registered target. `PARTIAL` when some targets resolve and some do not. Per-target verdicts are carried in `readiness.TARGET_READY.targets[]`. |
| `ROUTE_READY` | a readiness state | `OUT_OF_SCOPE` without `--stamp`. With `--stamp`: `FALSE` on any deterministic refusal; `NOT_EVALUATED` offline once the deterministic checks pass, because the validator verdict is a live fact; `TRUE` only under `--live` with every authority answered. |

<!-- machine-checkable: readiness_scopes -->
```
INSTALLED_INTEGRITY
MUTATION_SOURCE_ELIGIBLE
HOST_EXECUTION_READY
NEW_WORK_READY
TARGET_READY
ROUTE_READY
```
<!-- end -->

<!-- machine-checkable: readiness_states -->
```
TRUE
FALSE
PARTIAL
UNAVAILABLE
NOT_EVALUATED
OUT_OF_SCOPE
```
<!-- end -->

Four distinct conditions are representable and are never collapsed: an
evaluated false result, a field outside the command's scope (`OUT_OF_SCOPE`), a
temporarily unavailable observation (`UNAVAILABLE`), and a probe that was not
performed (`NOT_EVALUATED`).

`HOST_EXECUTION_READY`, `NEW_WORK_READY` and `ROUTE_READY` each carry
`launch_authoritative: false`, and `ROUTE_READY` also carries
`placement_selected: false`. Neither value is ever anything else: readiness is
diagnostic evidence about one instant, and the canonical dispatch path
revalidates every execution-critical fact immediately before launch.

#### Independence, in the cases that matter

- **Router outage.** The router narrows `NEW_WORK_READY` and nothing else.
  `HOST_EXECUTION_READY` may remain `TRUE`, installed state is not `BROKEN`,
  and no local route is invented in the router's place. Router availability is
  never an implicit host-execution prerequisite.
- **One incompatible target.** `TARGET_READY:A` is `FALSE` while
  `TARGET_READY:B` stays `TRUE`. Neither target poisons the host, and the
  aggregate reports `PARTIAL` rather than pretending one boolean describes a
  set of independent repositories.
- **One unavailable harness.** Claude Code and Codex are first class and
  individually optional. The host stays execution-ready through the other
  complete approved path, and the unavailable harness is reported on its own.
  Neither harness is ever globally mandatory.
- **An unavailable harness a route selected.** `ROUTE_READY` is `FALSE` and the
  launch is blocked. No other harness, model, profile, host or funding path is
  ever substituted: only a fresh central decision changes the answer.

### `live_facts`

Every external fact this lifecycle knows about is present on every run, seeded
`NOT_EVALUATED` before anything is probed, so a key never simply disappears
because a probe took an early return:

`orca_executable`, `validator_executable`, `claude_executable`,
`codex_executable`, `orca_runtime`, `orca_capability`, `validator_contract`,
`validator_fixtures`, `claude_capability`, `codex_capability`,
`claude_native_session`, `codex_native_session`, `claude_workspace_trust`,
`router_status`, `router_catalog_provenance`, `router_synthetic_route`,
`route_placement`, `route_authority`.

Each carries:

```
{"state": ..., "evaluated": bool, "reason": ...,
 "observed_at": ..., "timeout_ms": ..., "freshness_seconds": ...,
 "evidence_provenance": ..., "transient": bool,
 "launch_authoritative": false, "detail": ...}
```

<!-- machine-checkable: live_fact_states -->
```
PRESENT
ABSENT
AVAILABLE
UNAVAILABLE
COMPATIBLE
INCOMPATIBLE
UNKNOWN
NOT_EVALUATED
OUT_OF_SCOPE
```
<!-- end -->

Executable **resolution** is a filesystem fact and is evaluated on every run;
it carries no `observed_at`, because there is no external party whose answer
could go stale. Everything that requires a dependency to **run** — an Orca
status probe, the validator contract and fixtures, harness capability and auth,
the router — is an external observation and happens only under `--live`.

That boundary is deliberate. A harness binary is an agent client that can create
state under `HOME` and can consume provider tokens, and a validator is a
separate product with its own contract; "locally discoverable capability" is
satisfied by resolution plus this kit's declared capability contract, and
anything beyond that is a live probe.

#### What a live probe may and may not do

Every live probe is bounded by a declared timeout, is non-mutating, is
timestamped, records its evidence source and freshness window, and is
explicitly non-authoritative for launch. A host that cannot bound a probe
reports `PROBE_BOUND_UNAVAILABLE` rather than running an unbounded probe as if
it were a bounded one.

No live probe logs in, creates a worker, changes a BMAD repository, runs
implementation work, consumes inference tokens where a safe status probe
exists, creates placement, mutates production work, changes external authority,
or enables a metered fallback. A transient live observation is never persisted
into the applied-state manifest: the manifest carries identities, declared
paths and revisions, and nothing else.

`--synthetic-route` is a second, separate opt-in on top of `--live`. It asks
the router for one harmless recommendation; it stamps nothing, launches nothing
and spends no provider token. It never happens merely because live mode was
requested.

#### Orca

Orca readiness is a read-only status probe plus an **explicit capability
contract** — preferred over a version-only assumption, because a version number
has to be interpreted while a capability list is the dependency answering for
itself. The required capabilities are `worktree-ownership`,
`visible-worker-launch`, `argument-environment-transport`, `provider-runtime`
and `session-process-isolation`.

Routine readiness never creates a disposable worker to report ready. Readiness
that manufactures a worker is not readiness, it is work.

#### The validator and its offline fixtures

The kit does not decide whether a stamp is valid; it decides whether the thing
that decides is usable, and it records the validator's machine-readable
contract without reimplementing its policy.

A live evaluation materializes a fixture set under the system temporary
directory and asks the validator for a verdict on each: one known-valid stamp,
one expired, one tampered, one whose catalog provenance does not match, and one
carrying an incompatible field. The known-valid fixture must be accepted.

Only an exit status of exactly **1** is the validator's policy answer. A
validator that could not start, timed out, or fell over on the document has not
refused anything: that is `VALIDATOR_VERDICT_UNAVAILABLE`, a transient live
condition which makes the run exit 5 rather than 3. Reading an unanswerable
dependency as a refusal would turn "we could not look" into a proven verdict,
and the two need different actions from an operator.

The **anti-vacuity** control is the point: a validator that accepts *every*
negative fixture is `VALIDATOR_ANTI_VACUITY_FAILED` and blocks host readiness.
Which individual refusals are correct is not judged here — that would be
reimplementing validator policy on the wrong side of the boundary. A negative
fixture that went unanswered is not counted as a rejection either, because a
silence is not a proof.

#### Harnesses, authentication and funding

Harness readiness proves executable resolution, then the invocation
capabilities the frozen launch contract actually uses, then the authentication
**class** through the harness's own safe native status mechanism. No credential
value is read, copied, persisted or displayed at any point.

| Auth classification | Meaning |
|---|---|
| `AUTH_NATIVE_SUBSCRIPTION` | The funding class the approved paths are stamped for. |
| `AUTH_MODE_UNSUPPORTED` | An API-key session: a legitimate funding class, but not the one a subscription route was approved for. |
| `AUTH_REQUIRED` | No usable session. Reported as actionable; automatic login never happens. |
| `AUTH_STATUS_UNPROVEN` | The status could not be classified safely. |

A newer harness version whose required capabilities are all positively proven
stays ready. Inability to prove invocation, permission or subscription-auth
semantics makes that harness path not ready.

**Metered-path conflicts are per route, never global.** For a route approved for
native subscription funding, the presence of a name that is known to be able to
redirect or meter that harness — `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
`ANTHROPIC_BASE_URL`, `CLAUDE_CONFIG_DIR` for Claude Code; `OPENAI_API_KEY`,
`CODEX_API_KEY`, `OPENAI_BASE_URL` for Codex — blocks that route with
`ROUTE_FUNDING_CONFLICT` and nothing else. Presence of the NAME is the signal;
the value is never inspected, persisted or emitted.

A stamp whose funding class is explicitly metered or API-backed is not subject
to that check: credential shape alone is never treated as proof that every
API-backed path is forbidden. Compatibility follows the central funding and
entitlement contract carried by the stamp.

#### Claude Code workspace trust

Claude Code saves workspace trust per directory in its own user-owned project
state. When a route names a worker path, readiness reads that record and
reports a path awaiting the protected prompt as `WORKSPACE_TRUST_REQUIRED` —
an owner action that blocks that route loudly and is never presented as
launchable.

The lifecycle never edits that database, never accepts the prompt on a human's
behalf, and never uses non-interactive prompt skipping as a workaround. Reading
the record starts no process and opens no socket, so it happens whenever a route
names a path, live mode or not.

A Claude route whose workspace path cannot be determined at all — because the
target binding it would come from did not resolve — reports
`NO_SELECTED_WORKSPACE` rather than leaving the fact at its unprobed seed.
"No workspace was selected" and "the probe was not requested" are different
sentences, and a protected human decision must not disappear out of a route's
readiness by being described with the wrong one.

### `orchestration`

A bounded, read-only summary of normalized orchestration state, **consumed**
rather than owned:

```
{"state": "ACTIVE|INACTIVE|NOT_AVAILABLE", "evaluated": bool, "reason": ...,
 "session": {"mode": "PLAN|ORCH|WORKER", "phase": ..., "task": ...,
             "needs_human": bool},
 "parent":  {"role": ..., "id": ...},
 "workers": {"available": N, "by_state": {...}}}
```

<!-- machine-checkable: orchestration_states -->
```
ACTIVE
INACTIVE
NOT_AVAILABLE
```
<!-- end -->

<!-- machine-checkable: orchestration_modes -->
```
PLAN
ORCH
WORKER
```
<!-- end -->

The lifecycle never reconstructs this state from terminals, transcripts or
logs, never repairs it, and never becomes its owner. Only the members listed
above are carried through; a state document is someone else's territory and
must not become an arbitrary passthrough for content this contract has never
declared.

`parent` is generic. `parent = PM` is one arrangement of a supervised session,
not the shape of the model, and nothing here implements worker-originated
delegation.

A missing document reports `NOT_AVAILABLE` and emits no finding at all: absent
orchestration state is a normal condition and must never make ordinary
lifecycle or host readiness fail. An unreadable document or an unsupported
schema major warns inside its own scope. An active session waiting on a human
is reported **loudly** as `ORCHESTRATION_NEEDS_HUMAN` with `owner_action`
severity and no blocked scope: it is an owner action, and it is not a defect of
this installation.

### `dispatch_monitor`

The durable worker-completion watch, summarized read-only on every command:

```
{"state": "NOT_AVAILABLE|IDLE|WATCHING|NEEDS_HUMAN", "evaluated": bool,
 "reason": ...,
 "counts": {"total": N, "watching": N, "completed": N, "settled": N,
            "degraded": N, "unreadable": N},
 "pending_deliveries": N,
 "retained": {"terminals": N, "worktrees": N,
              "local_branches": N, "remote_branches": N},
 "dispatches": [{"id": ..., "state": ..., "acknowledged": bool,
                 "fault": ..., "cleanup": {...}}],
 "required_action": ...}
```

<!-- machine-checkable: monitor_states -->
```
NOT_AVAILABLE
IDLE
WATCHING
NEEDS_HUMAN
```
<!-- end -->

<!-- machine-checkable: dispatch_states -->
```
WATCHING
COMPLETED
SETTLED
MONITOR_DEGRADED
```
<!-- end -->

<!-- machine-checkable: cleanup_dispositions -->
```
PENDING
REMOVED
RETAINED
NOT_APPLICABLE
NEEDS_OWNER
```
<!-- end -->

The summary is a filesystem fact: it creates no directory, writes no file, and
never fails a command. A host that has never dispatched a supervised worker
reports `NOT_AVAILABLE`.

The summary describes the state the pass it belongs to actually read. `monitor`
summarizes once before its action and once after it, and the second reading is
allowed to disagree with the first: a pass that consumed the corrected delivery
for the only degraded Dispatch on the host reports `WATCHING` and exits 0, not
the `NEEDS_HUMAN` it would have reported a moment earlier. What the pass itself
could not resolve — a descriptor it refused, a delivery naming no Dispatch, a
resource it would not release — leaves no mark in the watch set for a later
reading to recover, so it is carried across the pass and still decides the
verdict.

## The dispatch monitor

A coordinator that launches a worker and then relies on a later human message
to make it look again is not an orchestration loop. The completion arrives
while nobody is watching, and the terminal, worktree and branch stay behind
because the moment they could have been released passed unobserved. The watch
therefore lives on disk under the declared state directory:

| Path | Contents |
|---|---|
| `dispatch/watch/<dispatch_id>.json` | The durable record of one supervised Dispatch. Written before control is yielded; survives coordinator turns, coordinator restarts and Orca disconnects. |
| `dispatch/inbox/<delivery_id>.json` | Completion deliveries the supervised transport committed. Consumed by a later invocation, never lost because nobody was listening. |
| `dispatch/results/<dispatch_id>.*` | The retained compact result and its traceability record, kept **outside** the worktree that produced them. |

`monitor` performs exactly one bounded pass per invocation. There is no
`--wait`, no rolling poll and no long-lived turn: the record carries the
declared poll interval and backoff ceiling so a scheduler outside this process
can drive the next pass. Nothing here blocks, and nothing here can spin.

Every observation the pass makes outside this host is bounded by the same
declared timeout the live probes use, and none of them can ask a human
anything: the Orca listing, the durable close, and the remote-branch
observations alike. An unbounded call would make "one bounded pass" untrue of
the pass that mattered most — the one settling a worker over a transport that
stopped answering. A host that cannot enforce that bound does not get the call
run unbounded either: the observation is refused, reported as
`PROBE_BOUND_UNAVAILABLE`, and whatever it could not decide is retained on
`NEEDS_OWNER`. This is stricter than the live readiness probes, which on a host
without a bounding tool report `PROBE_BOUND_UNAVAILABLE` once and then run the
observation unbounded rather than refusing it — and deliberately so: a
readiness probe that outruns its bound costs time, while a settlement
observation that outruns its bound is the hang this engine exists to remove.

### Completion authority

Only a supervised `worker_done` or `escalation` delivery completes a worker.
Terminal idleness, an exited process, transcript text, provider session history
and tab state are diagnostic observations: each of them is equally true of a
worker that failed, was killed, or never started, so none of them may
manufacture a result.

| Observation | Outcome |
|---|---|
| `worker_done` delivered | Retained, reconciled, acknowledged. `COMPLETED`. |
| `escalation` delivered | Retained and reconciled. `COMPLETED` with `needs_human`, and its resources stay retained. |
| Heartbeat window expired | `MONITOR_DEGRADED` / `WORKER_HEARTBEAT_EXPIRED`. Never a result. |
| Terminal exited or absent with no delivery | `MONITOR_DEGRADED` / `WORKER_TERMINAL_EXITED_WITHOUT_DELIVERY`. Never a result. |
| Delivery unreadable, or its result unparseable | Retained unacknowledged and loud. Recoverable: a corrected delivery reconciles on the next pass. |
| Result could not be retained | Not acknowledged. `RESULT_NOT_RETAINED`, and the delivery stays on disk. |

A delivery never creates a Dispatch. One that names a Dispatch this host holds
no watch record for is `DISPATCH_UNKNOWN`, stays on disk, and stays loud.

### At-least-once, idempotent

Delivery is at-least-once, so the same `worker_done` can arrive twice: after an
Orca disconnect that dropped the acknowledgement, or after a coordinator
restart. The order is **retention, reconciliation, then acknowledgement** — an
acknowledgement that outran retention is how a completion disappears.

Every effect is keyed by `delivery_id`. A replay is recognized and dropped as
`DELIVERY_REPLAY_IGNORED`: it cannot schedule settlement twice, cannot write a
second traceability record, and cannot repeat a cleanup that already happened.
A coordinator that restarts with one completed unacknowledged Dispatch and one
active Dispatch reconciles the first and leaves the second exactly as it was.

### Provenance-bound cleanup

A resource is a cleanup candidate only because a watch record proves AFK created
it for that exact Dispatch. Nothing is swept by age, by name, or by looking like
scratch: a coordinator's own terminal, a user's branch, a protected branch and a
legacy worktree carry no provenance here and are unreachable by this code.

`monitor --cleanup` requires `--live`, because deciding whether a terminal may
be closed — and proving it closed — is an external observation.

| Resource | Released only when | Otherwise |
|---|---|---|
| Terminal | AFK-owned, and a **durable** close was requested for it, the request itself was accepted, and its absence re-observed afterwards. `IDLE`, `EXITED` and `ABSENT` all reach that request, and all three consume its outcome. | `ACTIVE`, `AWAITING_ANSWER`, `AMBIGUOUS` and `USER_TAKEOVER` are retained untouched. A close that was refused, a close that could not be bounded, and an absence that could not be re-observed are all unproven closures: `NEEDS_OWNER`. |
| Worktree | AFK-owned, its worker settled, its terminal released, its result retained outside it, and `git status` clean. Removal goes through Git's own worktree bookkeeping. | Retained `WORKTREE_RETAINED_DIRTY` or `WORKTREE_RETAINED_UNSETTLED`. A path that cannot be removed as a worktree is one this code has not proven it created: it is retained, never recursively deleted. |
| Local branch | AFK-owned, not protected, its worktree removed, and its commits proven reachable from the expected base — with either a merged pull request or an explicit disposable flag. | `BRANCH_RETAINED_UNIQUE_COMMITS` (unique or unpushed work fails closed), `BRANCH_RETAINED_UNMERGED`, `BRANCH_RETAINED_PROTECTED`, `BRANCH_NOT_OWNED`. |
| Remote branch | The record carries an explicit `remote_delete_authorized` **and** a merged pull request, the local branch is already gone, and both the observation before the deletion and the re-observation after it completed inside the declared bound. | `REMOTE_BRANCH_RETAINED_UNAUTHORIZED`, reported with the owner action. A remote observation that could not complete proves nothing either way and is `NEEDS_OWNER`. This host never broadens its own repository authority. |

**What `ABSENT` means, in both places that read it.** `ABSENT` is one
observation — Orca is not listing that handle at this instant — and the two
readers of it say what it proves for their own question rather than each
assuming its own answer:

- the **watch sweep** reads it as a monitoring fault. A watched worker whose tab
  is gone with no supervised delivery has an unknown outcome, never a
  completion: `WORKER_TERMINAL_EXITED_WITHOUT_DELIVERY`.
- **cleanup** reads it as unproven. A handle Orca has forgotten may still be a
  resumable provider session — which is the entire premise of the durable close
  — so absence alone is never proof of release. Cleanup requests the durable
  close first and re-observes afterwards, exactly as it does for an idle
  terminal, and the request's own outcome is part of the evidence. For an
  absent handle it is the only part that carries any: the re-observation
  afterwards repeats what was already true before the request, whether the close
  succeeded, failed, or was refused outright. Whether Orca will close a handle
  it is no longer listing is a property of that daemon and is never assumed
  here — an Orca that refuses leaves the terminal `NEEDS_OWNER`, because a close
  that failed and a terminal that is nonetheless gone is still an unproven
  closure. Skipping the request altogether is how a settled Dispatch comes to
  own nothing while its tab comes back on the next reconnect.

Each disposition is reported independently as `REMOVED`, `RETAINED`,
`NOT_APPLICABLE` or `NEEDS_OWNER`, and ambiguity fails closed on `NEEDS_OWNER`
rather than deleting. A Dispatch whose four dispositions are all terminal
becomes `SETTLED`; repeating cleanup on a settled Dispatch does nothing and
recreates nothing.

Failed cleanup never rewrites a successful implementation result. It does
prevent the attempt from presenting resource cleanup as complete: the retained
terminal, worktree and branch counts stay in `dispatch_monitor.retained`, and
the required action stays loud.

A pre-existing branch or worktree with no AFK provenance is report-only
inventory for a separate owner-approved plan. It is never a deletion target of
worker settlement, and this code has no path that could make it one.

### `environment`

Presence and classification only:

```
{"name": "AGENT_ROUTER_TOKEN", "present": true,
 "classification": "SECRET_BEARING", "value": "[REDACTED]", "value_emitted": false}
```

No credential value, token, secret, authorization header or credential-store
content is ever emitted or persisted — including into the operation journal and
the applied-state manifest, which carry identities, declared paths and
revisions and nothing else.

Caller-supplied text is treated the same way: an unrecognized command or option
is echoed back only when it is in the closed command/option vocabulary, and is
otherwise replaced with a placeholder, so a mistyped credential on the command
line cannot land in a usage diagnostic. The VALUES of `--approve-plan`,
`--stamp`, `--target` and `--register` are never echoed either.

## Ownership classes

| Class | Meaning |
|---|---|
| `MANAGED_COPY_TREE` | A directory the kit owns wholesale, minus declared machine-owned members. |
| `MANAGED_COPY_FILE` | A single file the kit owns wholesale. |
| `MANAGED_SECTION` | A marker-bounded region inside a shared file; content outside it is user-owned. |
| `MANAGED_LINK` | A symlink the kit owns, with a declared target. |
| `MACHINE_LOCAL` | Declared machine-owned configuration. Local values are legitimate by ownership rule and never require per-value approval. |
| `USER_OWNED` | Content outside a managed section. Inventoried by shape only, never by content, never compared. |
| `TARGET_WIRING` | A registered BMAD target repository. |
| `CANONICAL_SOURCE` | The source checkout itself. |
| `KIT_STATE` | The state manifest, the operation journal, the operation lock and the durable dispatch watch. |
| `REGISTERED_ADAPTATION` | An explicit adaptation record. |

<!-- machine-checkable: ownership_classes -->
```
MANAGED_COPY_TREE
MANAGED_COPY_FILE
MANAGED_SECTION
MANAGED_LINK
MACHINE_LOCAL
USER_OWNED
TARGET_WIRING
CANONICAL_SOURCE
KIT_STATE
REGISTERED_ADAPTATION
```
<!-- end -->

### Declared components

| Component | Ownership | Destination | Container root | Execution critical |
|---|---|---|---|---|
| `model-router` | `MANAGED_COPY_TREE` | `$AFK_SKILLS_HOME/model-router` (excluding `subscriptions.yaml`) | `$AFK_SKILLS_HOME` | yes |
| `model-router-config` | `MACHINE_LOCAL` | `$AFK_SKILLS_HOME/model-router/subscriptions.yaml` | `$AFK_SKILLS_HOME` | no |
| `model-router-claude-link` | `MANAGED_LINK` | `$AFK_CLAUDE_HOME/skills/model-router` → `$AFK_SKILLS_HOME/model-router` | `$AFK_CLAUDE_HOME` | yes |
| `humanizer` | `MANAGED_COPY_TREE` | `$AFK_SKILLS_HOME/humanizer` | `$AFK_SKILLS_HOME` | no |
| `humanizer-claude-link` | `MANAGED_LINK` | `$AFK_CLAUDE_HOME/skills/humanizer` → `$AFK_SKILLS_HOME/humanizer` | `$AFK_CLAUDE_HOME` | no |
| `claude-global-policy` | `MANAGED_SECTION` | `$AFK_CLAUDE_HOME/CLAUDE.md` | `$AFK_CLAUDE_HOME` | yes |
| `codex-global-guidance` | `MANAGED_COPY_FILE` | `$AFK_CODEX_HOME/AGENTS.md` | `$AFK_CODEX_HOME` | no |

A non-critical component's problem is scoped to itself: it can refuse to be
overwritten without making the whole host `NOT_READY`.

### Managed section markers

```
# >>> agent-flow-kit managed section: <id> >>>
...payload...
# <<< agent-flow-kit managed section: <id> <<<
```

Markers must appear exactly once each, as complete newline-terminated lines, in
that order. Duplicated, unterminated or out-of-order markers are
`MANAGED_SECTION_MARKERS_MALFORMED`; boundaries are never guessed and such a
file is never written to. A line that merely resembles a marker but carries
extra bytes — a trailing carriage return, for instance — is not a marker, and
is treated as ordinary user content.

**Contracted normalization.** A section payload identity ignores a missing
final newline and trailing blank lines. Both sides of every comparison are
normalized identically, so an editor that "fixes" the end of a file cannot
manufacture drift. Nothing else about the bytes is normalized.

**Preservation contract (FR-37).** Everything outside the markers is user-owned
and is preserved **byte for byte** across a section upgrade: the bytes before
the begin marker and the bytes after the end marker are copied verbatim,
including CRLF line endings and a missing final newline. The write is rejected
if that is not what happened.

There is exactly one contracted formatting exception, and it applies only when
a section is being **inserted** into a file that has none: if the file does not
end with a newline, one is added before the begin marker, because a marker that
is not a whole line is not a marker. Insertion appends; no existing byte moves.

## Registered BMAD targets

Directory presence is not compatibility. A registered target is resolved
mechanically, on every run, entirely from the filesystem, and each verdict is
scoped to `TARGET_READY:<id>`.

<!-- machine-checkable: target_states -->
```
READY
INCOMPATIBLE
BROKEN
NOT_EVALUATED
```
<!-- end -->

The recognized layouts are the v6 tree
(`_bmad/bmm/workflows/4-implementation/create-story/template.md`) and the v6
skills layout (`.agents/skills/bmad-create-story/template.md`, optionally
mirrored under `.claude/skills/`). Resolution proceeds in order and fails
closed at the first unmet condition:

| Check | Failure |
|---|---|
| The target path exists | `TARGET_PATH_MISSING` |
| A recognized story template exists and resolves to a readable file | `TARGET_TEMPLATE_UNRESOLVED` |
| No second physical copy of the wiring disagrees with the first | `TARGET_WIRING_OWNERSHIP_AMBIGUOUS` |
| Some recognized layout is present at all | `TARGET_WIRING_UNRECOGNIZED` |
| The template carries `linear`, `stamp`, `persona`, `gates` and `max_cycles` | `TARGET_WIRING_SCHEMA_INCOMPATIBLE` |
| The template carries no retired `route` or `local_gpu` key | `TARGET_WIRING_MALFORMED` |
| `_bmad/bmm/agents/dev.md` and `pm.md` exist and resolve to readable files | `TARGET_PERSONA_UNRESOLVED` |

All met is `TARGET_WIRING_PROVEN`, and the wiring identity of the resolved
template is reported as bounded evidence.

Two copies of the wiring that disagree are ownership ambiguity, not a tie to
break: guessing which one dispatch will read is exactly the decision this
lifecycle refuses to make by itself.

## The execution stamp and route readiness

`--stamp <path>` puts one accepted routing decision into scope. `--target <id>`
binds that route to one registered target; when exactly one target is
registered it is used without being named.

Any other arity is a binding this lifecycle will not guess at. Two or more
registered targets with no `--target` is ownership ambiguity of exactly the kind
the wiring rules already refuse to resolve, and a host with none registered has
nowhere to dispatch the route into: both are `ROUTE_TARGET_UNRESOLVED`, and the
route is `FALSE`. Naming the target resolves it — the operator decides, not the
lifecycle. The target is an operand of the intersection below, and an operand
that cannot be determined fails the route closed rather than dropping out of it:
an intersection that quietly loses a leg would report a route launchable with
that leg never evaluated, and would take the workspace-trust decision that hangs
off the bound path out with it.

An execution stamp is a **closed** document. Its property set is
`harness`, `model_profile`, `effort`, `cost_class`, `entitlement_pool`,
`metered`, `placement_policy`, `placement_required`, `catalog_version`,
`catalog_document_version`, `expires_at`, `task`, `override`, `created_at`;
anything else, or a missing required member, is `STAMP_SHAPE_INVALID`.

Route readiness is the **intersection** of every authority, and each is
evaluated by its own owner:

| Dimension | Owner | Failure |
|---|---|---|
| Catalog legality, funding class, placement policy, provenance, expiry | router / catalog / validator | `STAMP_VALIDATION_FAILED` |
| Expiry, deterministically | this kit | `STAMP_EXPIRED` |
| Launch contract for {harness, profile, effort} | this kit | `ROUTE_PROFILE_UNSUPPORTED` |
| Metered-path conditions for a subscription route | this host's environment | `ROUTE_FUNDING_CONFLICT` |
| The target BMAD wiring the route needs | the target repository | `ROUTE_TARGET_UNRESOLVED` |
| The selected harness being usable | the harness | `ROUTE_HARNESS_UNAVAILABLE` |
| Workspace trust for the selected path | a human | `WORKSPACE_TRUST_REQUIRED` |
| Host execution readiness | this host | `NO_APPROVED_HARNESS_PATH` |

This kit's launch contract covers two classes, both at effort `low`, `medium`,
`high` or `xhigh`.

**Native vendor subscription execution**, on `claude` and on `codex`: the
harness vendor's own profile family funded by its own entitlement pool
(`claude/*` on `anthropic-max`, `openai/*` on `openai-plus`), vendor-hosted, so
`placement_required` is false. Their frozen contracts forbid every endpoint,
base-URL, provider and model redirection the CLIs expose.

**Gateway-backed local execution**, on `claude` only: a profile the trusted
catalog marks `hosting: local`, carrying `placement_required: true`, drawing on
no entitlement pool, at `cost_class: free`. Its launch contract is the catalog's
own record for that pair: four live-validated variables, plus the
context-window variable the catalog records as observed during that validation
(evidence finding F3) rather than exercised by it. All five are set inside the
launch's `env -i` allowlist, on the harness subprocess and nowhere else:

| Variable | Value | Where the value comes from |
|---|---|---|
| `ANTHROPIC_BASE_URL` | the gateway's Anthropic-compatible endpoint | launcher configuration (`launcher.gateway_endpoint`, or `AGENT_FLOW_GATEWAY_URL`) |
| `ANTHROPIC_AUTH_TOKEN` | the scoped gateway key, as a bearer header | resolved at launch time from a launcher-configured REFERENCE (`launcher.gateway_token_ref`); never a value in config, never in command text, a title, a log or a file |
| `ANTHROPIC_MODEL` | the profile's physical model id | the trusted catalog. Required, not optional: an unpinned session is refused at the gateway |
| `ANTHROPIC_CUSTOM_HEADERS` | `x-placement: <value>` | copied verbatim from the `headers` object of the `POST /v1/place` result fetched for this attempt; never composed |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | the profile's real window | the trusted catalog's `min_context`. Absent, the harness assumes 200000 tokens and compacts far too late for the model |

No API key is set on either class, no file-borne redirection is accepted (the
settings preflight still refuses `env`, `apiKeyHelper`, `forceLoginMethod` and
provider redirections in any settings layer), and nothing is exported into the
operator's shell.

**Placement is per launch, not per turn.** `ANTHROPIC_CUSTOM_HEADERS` is fixed
when the harness process starts and cannot be refreshed while it runs, so one
session pins one placement for its whole life; a session never re-places
itself. Evidence is fetched fresh immediately before each attempt. A stale or
withdrawn placement degrades to the gateway's frozen headerless default and is
served — it costs latency, not correctness — so relaunching is how a long
session is re-placed, and nothing breaks if it is not.

Anything outside those two classes is refused before any command text exists.
The refusal names the mismatch, writes a marker a human can read, and never
substitutes a harness, model, profile or funding path for the one that was
stamped.

**Placement is never a lifecycle concern.** No physical inference placement is
selected, persisted, added to the immutable stamp or assumed reusable here.
Where a route requires placement it stays an ephemeral per-attempt dispatch
concern, and `readiness.ROUTE_READY.placement_selected` is `false` on every
path.

**An observation is never authorization.** A successful live observation at T1
is diagnostic evidence about T1. It is not reusable at T2, it is not recorded
as a launch grant, and the canonical dispatch path revalidates every
execution-critical fact immediately before launch.

**An accepted stamp survives a router outage.** When the router is unavailable
but the stamp is unexpired and requires no rerouting, route readiness may
continue on what a compatible validator can prove locally. Any requirement for
a fresh route blocks the launch instead.

## The context budget

A routed profile's context window is a **routed fact**, and the trusted catalog
is its only source. The launcher reads the catalog's `min_context` for the
stamped `model_profile` — the same document, at the same `catalog_version` the
frozen validation already proved the stamp against — and uses that value
exactly. It is never derived from a model id, never extended, never rounded and
never substituted, and the stamp is never asked for it.

A profile that declares no `min_context` has no window, and the kit says so
rather than inventing one: the budget is `NOT_EVALUATED` with the reason
`CONTEXT_WINDOW_UNDECLARED`, `window_tokens` is null, no threshold can fire, and
dispatch proceeds. Reporting budget health that is not grounded in a catalog
value would be worse than reporting none. (`claude/strong` declares none today;
that is the honest catalog state and is registered as a catalog gap.)

This is unrelated to the gateway class's `CLAUDE_CODE_MAX_CONTEXT_TOKENS`, which
is set on the harness subprocess and is unchanged.

### The declared policy

Every threshold and the estimate method live in one machine-readable document,
`files/model-router/context-budget-policy.yaml`, installed with the kit as
**launcher configuration** — read from the launcher's own path
(`launcher.budget_policy`, or `$AGENT_FLOW_BUDGET_POLICY`), never from a story
and never from a stamp. It declares `estimate_method`, `sizing_risk_ratio`,
`checkpoint_ratio`, `continuation_ratio`, `continuation_cap`, the stable reason
codes — including `CONTINUATION_CAP_REACHED`,
`CONTINUATION_STAMP_REFRESH_REQUIRED`, `REPEATED_CONTINUATION`,
`CONTINUATION_REFUSED`, `CONTINUATION_ARTIFACT_UNBOUND` and
`CYCLE_ALREADY_RETAINED` — and the budget states.

There is no threshold constant in the launcher. A policy document that is
unreadable, unparseable or missing a key refuses dispatch with
`BUDGET_POLICY_UNREADABLE` and the config exit code, before any placement,
terminal or artifact exists — a missing threshold is not a default.

### The pre-dispatch sizing estimate

Before any launch, the launcher estimates the planned worker payload from
exactly these inputs, in this order, each counted once by byte length:

1. the persona file, when the story stamps one;
2. the story file;
3. the generated prompt file;
4. every path declared under the story's optional `payload_refs:` frontmatter
   key, repo-relative to the worktree that bounds the worker's sandbox.

Bytes become tokens by the method the policy declares. The accepted initial
method id is `bytes4-v1`: `ceil(bytes / 4)`. A `payload_refs` entry that does
not resolve to a readable file refuses with `PAYLOAD_REF_MISSING`; an estimate
that silently dropped part of the payload would under-report exactly when it
matters.

The estimate is **advisory kit policy**. It is never written into a `/v1/route`
request as a `context_size` minimum or any other capacity input, it never alters
route selection, and stamping is untouched by it.

### Pre-dispatch actions

With a declared window, `estimate / window` is compared against the declared
ratios. A ratio **equal** to a threshold counts as crossing it.

| Band | Action |
|---|---|
| ratio ≥ `continuation_ratio` | dispatch is REFUSED fail-closed with exit code 8 and a `${STORY}.blocked` marker typed `STORY-SIZING:` |
| `sizing_risk_ratio` ≤ ratio < `continuation_ratio` | dispatch proceeds; `SIZING_RISK` is recorded in the thin result and appended once per cycle to the story's `## Dev Agent Record` |
| ratio < `sizing_risk_ratio` | dispatch proceeds, no finding |

The refusal is a **planning outcome, not a routing one**. It runs after the
repository setup-policy gate and before `POST /v1/place`, before stamp
validation and before the launch-contract guard, so a story that was too big to
start consumes no placement, no validation, no terminal, no command text and no
result artifact. The marker names the estimate, the window, the ratio, the
threshold and every input counted. No route is modified and no substitute is
chosen; re-routing to a larger window means a new `/v1/route` call and a new
stamp, exactly as everywhere else.

With an undeclared window neither action can fire.

### The budget member of the thin result

```
"budget": {"state": ..., "reason": ...|null,
           "window_tokens": N|null, "window_source": "CATALOG",
           "estimate_tokens": N, "estimate_method": ...,
           "estimate_ratio": N|null,
           "usage_tokens": N|null, "usage_ratio": N|null,
           "usage_provenance": "HARNESS_ENVELOPE"|"NOT_EVALUATED",
           "usage_scope": "FINAL_CONTEXT"|"CUMULATIVE_RUN"|null,
           "usage_reason": ...|null, "observed_at": "END_OF_RUN"|null,
           "window_reported_tokens": N|null,
           "checkpoint_artifact": {"path":..., "sha256":...}|null,
           "continuation_artifact": {"path":..., "sha256":...}|null,
           "continuation_of": {"cycle":N, "artifact_sha256":..., "trigger":...,
                               "usage_tokens":N|null, "usage_ratio":N|null}|null,
           "continuation_decision": {"cycle":N, "actor":..., "at":..., "reason":...}|null,
           "findings": [...]}
```

`window_source` names the authority consulted, which is the catalog on every
path — including the path where it declares nothing. The member is additive
within the result schema major, and its codes follow the same stable-code
discipline as every other reason code in this contract.

<!-- machine-checkable: budget_states -->
```
OK
CHECKPOINT_DUE
CONTINUATION_REQUIRED
NOT_EVALUATED
```
<!-- end -->

Pre-dispatch produces only `OK` and `NOT_EVALUATED`. `CHECKPOINT_DUE` and
`CONTINUATION_REQUIRED` come from the post-run evaluation below.

### Observed usage, and who may observe it

Usage observations are **provided by the harness**: the kit reads what a harness
publishes and never reconstructs a number from a terminal buffer or a
transcript. Each approved harness has a named adapter, the core calls one
interface, and adding a harness means adding an adapter.

Under its frozen launch text `claude` publishes one end-of-run result envelope
(`--output-format json`), so its adapter reports `usage_tokens` from that
envelope's `usage` — input plus cache reads plus cache creation — with
`usage_provenance: HARNESS_ENVELOPE` and `observed_at: END_OF_RUN`.

**What that figure measures is `usage_scope`, and only one scope is
occupancy.** The envelope's `usage` members are the SUM over every API call the
run made, not the context its final call held, and the envelope publishes the
call count in `num_turns`. So:

- `num_turns == 1` — the envelope *is* that one call's context.
  `usage_scope: FINAL_CONTEXT`, and the ratio is computed from it.
- anything else — more turns, or an envelope that publishes no turn count and
  therefore proves nothing about how many calls it summed —
  `usage_scope: CUMULATIVE_RUN`, `usage_reason: USAGE_CUMULATIVE_ONLY`,
  `usage_ratio: null`. The figure is still published, as information about the
  run's total consumption; it is never divided by a window.

A cumulative observation evaluates to nothing, on exactly the path an
unobservable one takes: no band, no `HIGH_USAGE`, and the pre-dispatch verdict
left standing. `CHECKPOINT_DUE`, `CONTINUATION_REQUIRED` and `HIGH_USAGE` are
asserted **only from a `FINAL_CONTEXT` measurement** — which is what "the run
*ended* at or past `checkpoint_ratio`" has always meant, and now says. Dividing
a cumulative total is how an 83-turn run that never occupied more than one
window reported a ratio of 20.30 against it.

The envelope carries no per-turn or final-context figure of its own, and the
kit reads no terminal and no transcript, so `FINAL_CONTEXT` is the only
occupancy this contract can honestly observe. `codex exec` runs without `--json` and publishes
nothing machine-readable, so its adapter reports `NOT_EVALUATED`, reason
`USAGE_UNOBSERVABLE`. Neither launch command text changes to make usage
observable; both are frozen. So under `claude` there is no mid-run usage to
read, and `NOT_EVALUATED` on `codex` is an answer rather than a gap the core
compensates for: it never becomes fallback logic and never blocks the other
harness.

The envelope also carries the model's own `contextWindow`, recorded as
`window_reported_tokens` for **corroboration only**, and read by an **exact
match** on the routed model's key in `modelUsage` — the harness names its own
models, so a key that does not match is a different model and corroborating
against it would produce a disagreement about a model that did not run the turn.
Where no key matches, `window_reported_tokens` is `null` and the finding is
`WINDOW_UNCORROBORATED`. The budget window is the catalog's on every path; a
disagreement between the two is recorded as `WINDOW_DISAGREEMENT` and left
standing, because resolving two authorities by preferring one is how a kit
starts inventing routed facts.

The envelope also carries `total_cost_usd`, and each `modelUsage` entry a
`costUSD`. **Neither is read, and no cost figure reaches a thin result or any
kit aggregate.** The number is the client's own estimate — the envelope labels
its own basis `costBasis: "unknown"` — and on a `cost_class: free` route it is
not money at all. What a run cost is a question for whoever owns the funding
path; publishing an estimate beside routed facts would make it look like one.

A `usage` object that carries **none** of `input_tokens`,
`cache_read_input_tokens` or `cache_creation_input_tokens` is a run whose
context was never published, not a run that used none: the adapter reports
`USAGE_UNOBSERVABLE` rather than `usage_tokens: 0`.

### Phase-boundary discipline
`usage / window` is compared against the declared ratios by the same
parts-per-million arithmetic the pre-dispatch estimate uses, and a ratio
**equal** to a threshold counts as crossing it: at or above `continuation_ratio`
the state is `CONTINUATION_REQUIRED`, at or above `checkpoint_ratio`
`CHECKPOINT_DUE`, below both `OK`.

At or above `checkpoint_ratio` the finding `HIGH_USAGE` is added: a run that
*ended* that close to its window was sized too close to it — a planning signal
for the PM, not a fact about one attempt.

`CONTINUATION_REQUIRED` is a statement about **unfinished** work. A ratio in
the continuation band at the end of a run whose gates passed, and whose worker
signalled nothing, is a sizing observation instead: the state is `CHECKPOINT_DUE`
(or `OK`, per the checkpoint rule applied to the same ratio) and the `HIGH_USAGE`
finding carries the observation.

**A ratio never sets the result `status`.** `status: continuation_required`
says there is a hand-over to resume FROM, so it is published only when the
worker signalled `CONTINUATION-REQUIRED:` and left a valid continuation
artifact whose identity the result carries. The gates decide every other
attempt: failed is `gates_failed`, passed is `done`. A `budget.state` of
`CONTINUATION_REQUIRED` — now reachable only from a `FINAL_CONTEXT`
measurement — stands beside that status as a sizing note, with `HIGH_USAGE`,
and changes nothing about it. The rule exists because the alternative shipped:
a status set from a band alone published `continuation_required` with no
checkpoint and no continuation artifact anywhere, and a PM reading it would
re-dispatch a continuation from nothing.

An observation that cannot be evaluated — no usage published, or no declared
window — **does not overwrite `state`**: the pre-dispatch verdict is a real
conclusion about a real estimate, and replacing it with `NOT_EVALUATED` would
report less than the kit knows. It goes to `usage_reason`
(`USAGE_UNOBSERVABLE`, or `CONTEXT_WINDOW_UNDECLARED` where the window is what
is missing) beside `usage_provenance: NOT_EVALUATED`. `CHECKPOINT_DUE` and
`CONTINUATION_REQUIRED` are therefore reached only from a computed ratio or a
worker's own continuation signal, never inferred.

The generated prompt also names the directory the worker is standing in: one
launcher-owned sentence saying that the repository root is the current working
directory `<absolute worktree path>`, that paths should be relative to it, and
that absolute paths outside it are refused. The story is mirrored into a
worktree and states paths relative to a root it never names, so a worker
reasoning from the repository it remembers reaches into the main checkout and
is denied — 14 times on the run this rule comes from. Its only input is the
directory the launcher resolved for itself: neither the story nor the persona
can alter it, and it is byte-stable for a given worktree.

Because mid-run usage is not observable under either frozen launch text, the
checkpoint discipline cannot be driven by usage. It is **deterministic policy**,
carried to the worker as a fixed launcher-owned paragraph in the generated
prompt — data written into the prompt file, never shell source, and byte-stable
for a given story. It names the declared phase boundaries — after reading the
story, after implementation and before the gates, and before reporting — at
which the worker writes or refreshes `<story>.checkpoint.json`
(`schema: afk-checkpoint/1`, with `completed`, `current_state`,
`remaining_acceptance`, `next_steps`, `updated_at`). If the worker judges it
cannot finish, it stops at the **next** boundary, writes
`<story>.continuation.json` (`schema: afk-continuation/1`; the checkpoint
members plus `in_flight` and `unretired_findings`) and prints one line
`CONTINUATION-REQUIRED: <reason>`. Continued execution toward exhaustion is not
a permitted outcome.

Both artifacts are secret-free by rule and are held to the kit's redaction
discipline on read. Only their identity — path and `sha256` — reaches the thin
result: no member value is ever copied into a result, a log or a marker, and
validation verdicts come from a closed vocabulary and never quote the offending
value. The worker's continuation reason is **caller-supplied free text and is
never echoed at all** — a credential is not distinguishable from a typo by
shape, so no pattern filter is applied to it. What the marker and the log record
is `reason_given`, `reason_bytes`, and `reason_words`: the words of the reason
that appear in a closed vocabulary, the same discipline `afk_safe_diagnostic`
applies to caller-supplied arguments. A `CONTINUATION-REQUIRED:` line with an
empty reason is not a signal a human can act on: it is refused on the same path
as invalid evidence, with `detail=SIGNAL_REASON_EMPTY`.

The signal is matched line-anchored (`^CONTINUATION-REQUIRED:`), mirroring the
frozen `NEEDS-HUMAN:` channel, so a worker that begins a line with the marker
while explaining that it did *not* need it is read as having signalled; the
prompt paragraph tells the worker not to. **Known limitation:** for `codex` the
worker text is the terminal tail read with `--limit 5000`, so on a chatty run
the signal can scroll out of view and the run reports its gate outcome instead.
Neither is fixed by this capability; both are recorded here.

| what the launcher finds | what it does |
|---|---|
| a valid checkpoint | records `checkpoint_artifact` identity |
| a checkpoint that does not validate | finding `CHECKPOINT_ARTIFACT_INVALID`; the attempt is **not** refused — a checkpoint is a resumption aid, not a completion claim |
| a checkpoint byte-identical to the one the attempt started with | finding `CHECKPOINT_ARTIFACT_STALE`; no `checkpoint_artifact` identity is published, because this worker did not write it |
| `CONTINUATION-REQUIRED:` with a valid, freshly written continuation | `budget.state: CONTINUATION_REQUIRED`, `status: continuation_required`, `continuation_artifact` identity, and one dated line in the story's `## Dev Agent Record`, idempotent per cycle |
| `CONTINUATION-REQUIRED:` with a missing, unparseable, schema-mismatched, member-short or byte-unchanged artifact | loud `NEEDS_HUMAN`: a `${STORY}.blocked` marker with reason `CONTINUATION_ARTIFACT_INVALID`, exit code 3, and **no result artifact at all** |
| usage ≥ `continuation_ratio`, gates failed, no worker signal | `status: gates_failed` with `budget.state: CONTINUATION_REQUIRED` and finding `HIGH_USAGE` — the band is a sizing note; there is no artifact, so there is no hand-over to resume from |
| usage ≥ `continuation_ratio`, gates **passed**, no worker signal | `status: done` with `budget.state: CHECKPOINT_DUE` and finding `HIGH_USAGE` — a finished run is sized, not continued |
| a cumulative (multi-turn) usage figure, whatever its size | no ratio, no band, no `HIGH_USAGE`: `usage_scope: CUMULATIVE_RUN`, `usage_reason: USAGE_CUMULATIVE_ONLY`, and the status is the gates' |

Neither lifecycle artifact is deleted before a launch the way the result
artifact is, because the next cycle is meant to resume from them; freshness is
proved by identity instead — the sha of each is captured before the launch, and
a byte-identical file afterwards was not written by this worker. `continuation_required` is additive within the
result schema major and exits as unfinished work (exit code 1), not a completion.

### Continuation cycles, the cap, and the decision key

A continuation is the **next cycle of the same story under the same accepted
stamp**, launched through `dispatch.sh` exactly as any cycle is: setup gate,
pre-dispatch sizing, `POST /v1/place`, fail-closed revalidation, launch guard,
launch, gates, thin result. There is no second entry point and no local
substitution of harness, model, profile or funding, and neither frozen launch
command text changes. What a continuation changes is what the launcher puts
into the prompt and what it refuses before launching.

`${STORY}.result.json` is overwritten every cycle, so from this capability on
the launcher also retains one copy per cycle at `${STORY}.result.c<n>.json`,
written immediately after the thin result. The continuation **chain** — which
cycle a continuation continues — is derived from those retained copies and from
nothing else: no counter is stored, and nothing a workload can edit is
consulted. The **cap** is counted from the ledger below.

Neither series is ever pruned, and that is load-bearing rather than tidy: the
retained per-cycle results and the continuation ledger are the only evidence the
chain and the cap exist at all, so deleting either would make a story's spent
continuations uncountable and hand it back windows it had already used.

**A continuation cycle is run once.** A cycle that has an entry in the
continuation ledger, and a cycle that is itself a continuation and already has a
retained result, are settled: dispatching either again refuses fail-closed with a
`${STORY}.blocked` marker carrying `reason=CYCLE_ALREADY_RETAINED`, the cycle and
the next free cycle number, and exit code 3 — before placement, validation or any
terminal. Re-running one would spend a second window under a number that has
already spent one and overwrite the evidence the chain is read from, which is
exactly how a story could hand itself back a continuation it had already
consumed. A continuation is always the NEXT cycle.

Re-dispatching an **ordinary** cycle is unaffected, and remains the documented
recovery from a stamp refresh, a dead terminal or a flaked gate. It cannot move
the cap, which is counted from the ledger and not from the result it rewrites.
Likewise, an attempt that refused *before* it launched — a stamp refusal, a cap
refusal, a sizing refusal — leaves neither a result nor a ledger entry, so
"re-dispatch this same cycle" still means what those markers say it means.

Cycle *n* is a **continuation** when the most recent prior cycle that left a
retained result carries `status: continuation_required`. A cycle with no such
prior result is an ordinary cycle, and a continuation artifact left over from an
older chain does not make one. When the prior cycle did hand over, its evidence
is required rather than optional: a missing, unparseable, schema-mismatched or
member-short `${STORY}.continuation.json` refuses on the existing loud
`NEEDS_HUMAN` path with reason `CONTINUATION_ARTIFACT_INVALID` and exit code 3,
before anything is placed or launched. The artifact also names the story it
belongs to. `story_id` — the story file's basename without its extension — is an
additive member of `afk-continuation/1`: the schema id does not move, an
artifact that carries it and names a **different** story is refused on that same
path with detail `STORY_MISMATCH`, and an artifact that omits it is accepted and
reported as the finding `CONTINUATION_ARTIFACT_UNBOUND`, because nothing then
binds a file found by path to this story — there is nothing to resume from, and
running anyway would silently restart the story under a stamp and a cap that
both believe it is being continued.

On a continuation the launcher:

1. **counts the artifact in the pre-dispatch estimate.** Its content is written
   into the generated prompt, which is already a declared payload input, so it
   is counted through the prompt exactly once. Counting the file a second time
   would over-report the one input a continuation adds and refuse stories that
   would have fitted; the refusal marker still names the artifact and its byte
   length, as a sub-line of the input it travels inside. The refusal and risk
   thresholds are unchanged and apply to the larger payload as they would to any
   other.
2. **writes the artifact's content into the prompt as data**, under the fixed
   heading `Continuation from cycle <n-1>`, after the persona and story
   instructions and before the budget paragraph. It is data on the prompt's data
   channel like the story is, never shell source, and the story remains the
   authority wherever the two disagree.
3. **records `budget.continuation_of`** — `{cycle, artifact_sha256, trigger,
   usage_tokens, usage_ratio}` — where `trigger` is `WORKER_SIGNAL` when the
   prior cycle published a continuation artifact identity and `USAGE_BAND` when
   the kit reached the status from observed usage with the gates failed.
4. **adds the finding `REPEATED_CONTINUATION`** and appends one dated
   `CONTINUATION` line to the story's `## Dev Agent Record` through the same
   locked, per-cycle-idempotent append `SIZING_RISK` uses, carrying the cycle
   continued from, the artifact sha, the trigger and the usage evidence — so
   trigger → usage → artifact identity is one readable chain in the story.

The stamp is untouched. The frozen prelaunch revalidation runs on a continuation
exactly as it runs on any cycle, and a stamp that fails it is refused with the
validator's own exit code and reason. What a continuation adds is a
`${STORY}.blocked` marker typed `CONTINUATION-STAMP:` carrying
`reason=CONTINUATION_STAMP_REFRESH_REQUIRED` beside `validator_reason=<the
validator's code>`, saying that the planner must call `POST /v1/route` again and
mint a new stamp with `make-stamp.sh`. A continuation is never launched under a
locally minted or locally edited stamp — that would be a routing decision taken
after acceptance, and half-finished work makes it more tempting, not more
permissible.

**The cap.** `continuation_cap` in the declared policy bounds how many
continuation cycles one story may consume. The count is the **length of the
story's continuation ledger**, `${STORY}.continuations.json`, regardless of the
cycle numbers in it.

The ledger declares `schema: afk-continuation-ledger/1` and carries one entry
per continuation **launch** — `{cycle, from_cycle, artifact_sha256, trigger, at,
decision}`, where `decision` is the recorded authorisation or `null`. Each entry
is appended under the same exclusive lock on the story that the record append
holds, immediately before the launch and after everything that could still
refuse the attempt, so an entry exists if and only if a continuation window was
actually spent. It is never rewritten and never pruned. A ledger that does not
parse, or that does not carry the declared schema id, refuses the dispatch: the
cap is counted from it, and a count that cannot be read is not a count of zero.

The first cycle's hand-over is not a consumption and is not counted — it never
was, because no continuation had yet been launched for it.

**The cap is decided before the story's own `max_cycles`.** `max_cycles` is a
per-story cycle limit that says nothing about continuations; a capped story
refused by it first would get an untyped message with no marker, no count, no
cap and no way to authorise the cycle, and at the shipped default of 3 that is
what a story handing over twice would get. The cap gate runs first, and
`max_cycles` still applies to whatever it lets through — which is why the cap
marker's suggested frontmatter carries both keys.

At the cap the next continuation refuses fail-closed with a `${STORY}.blocked`
marker typed `CONTINUATION-CAP:` carrying `reason=CONTINUATION_CAP_REACHED`, the
count, the cap and the exact frontmatter that would authorise the cycle, and
exit code 3. Nothing is placed, validated or launched and no result is written.
It refuses in the same place, and for the same kind of reason, as an oversized
story: a story that keeps needing another window is a planning finding.

A continuation refused by the **sizing** gate instead — its payload, the
artifact included, is at or past `continuation_ratio` — leaves the ordinary
`STORY-SIZING:` marker and, additionally, one dated `CONTINUATION_REFUSED` line
in the story's `## Dev Agent Record`, carrying the cycle it would have continued
and the estimate, window and ratio. Without it a PM reading only the record
could not see that the hand-over had been attempted and turned away. The line is
appended after the estimate, so the story's own bytes are the same on a
re-dispatch of that cycle as they were on the first and the estimate stays
deterministic.

A human authorises one more continuation by recording the decision in the
story's own frontmatter:

```yaml
continuation_decision:
  cycle: 4              # the ONE cycle this authorises
  actor: <who decided>
  at: <RFC3339>
  reason: <why one more continuation is the right call>
max_cycles: 4           # the story's own cycle limit must reach it too
```

The `max_cycles` the cap marker suggests is the **larger** of the story's
current limit and the cycle being authorised, so applying the block never
lowers a limit the story already carries: a story allowed 8 cycles and refused
at the cap on cycle 4 is offered 8, not 4. `max_cycles` keeps bounding
continuations that the cap lets through — the two limits are independent, and
the cap gate running first does not retire the other one.

Every member is required and the recorded cycle must be the cycle being run: a
decision does not carry forward to a later one. The cycle is compared as a
number however it was written, so `cycle: "4"` authorises cycle 4 rather than
silently authorising nothing. An authorised cycle proceeds and
records the decision verbatim in `budget.continuation_decision`.
`REPEATED_CONTINUATION` is added to **every** continuation, authorised or not —
the finding is the PM's story-sizing signal, not a complaint about the cap.

Settlement is unchanged. A continuation worker is a fresh Orca-visible terminal
exactly like any cycle, and the frozen Story 1.3 completion-watch, terminal
cleanup and worktree/branch accounting contracts apply unmodified; the monitor
reads `result.context_budget` from a continuation cycle's thin result exactly as
it reads any other.

### The context budget on the dispatch monitor

A watch record reconciled from a completion carries `result.context_budget`, and
the `status` rendering carries `context_budget` per watched Dispatch — one of the
four declared budget states, **bounded on read**: a delivery is worker-shaped
input, and a state outside the published four is not a fifth state but an
unobserved one, so it reads `NOT_EVALUATED`. The member is introduced by this
capability and is **not retroactively required** of the frozen Story 1.3
deliverable; a record written before it existed reads `NOT_EVALUATED` too, and a
continuation that cannot proceed surfaces as `NEEDS_HUMAN` through the existing
monitor path unchanged.

<!-- machine-checkable: dispatch_result_statuses -->
```
done
gates_failed
continuation_required
needs_human
```
<!-- end -->

The first three are the statuses a thin result artifact carries. `needs_human`
is **delivery-only**: it is the status a delivery reports and `afk-monitor.sh`
gates on, and it is exactly the path on which `dispatch.sh` deliberately writes
no result artifact at all. The list is the union a reader of either producer may
meet, which is what the vocabulary is for; no thin result will ever be found
carrying `needs_human`.

## Compatibility declarations

The router and its catalog own legal harness/profile relationships, model and
profile legality, entitlement or funding class, placement requirements, catalog
provenance, expiry and resource policy. Runtime observation may **remove**
availability; it never adds authority.

This kit owns, and publishes through `schema`, only executor capability: the
lifecycle and state schema majors it implements, the execution-stamp and
validator contract majors it records, the BMAD wiring major it supports, the
orchestration state major it consumes, the dispatch watch major it owns, the
Orca launch capabilities it requires, and the harnesses and invocation features
it can drive.

<!-- machine-checkable: approved_harnesses -->
```
claude
codex
```
<!-- end -->

## Path type, containment and symlink boundaries

Before any managed destination is read, hashed, backed up or replaced:

- the destination must exist and be the **declared type** (file, directory or
  symlink);
- its **parent chain** is resolved, and must stay inside the component's
  declared container root — a symlinked parent directory that moves a managed
  path elsewhere is `PATH_PARENT_ESCAPES_BOUNDARY`;
- a declared managed **link** must resolve inside its declared target root;
- an unresolvable path, parent or boundary fails closed rather than being read.

The same guards apply to kit state: the manifest and the journal.

These guards run **twice** in a mutating operation: once while the plan is
computed, and again immediately before the write of the component they protect.
A symlink planted between two writes of the same transaction is caught by the
second check, which stops the transaction and rolls back.

## Identity evidence

Evidence is bounded identifiers, never file dumps:

- tree identity: sorted listing of files (`sha256`) and symlinks (encoded
  target), hashed as one document, excluding declared machine-owned members
- file identity: `sha256:` of the bytes
- section identity: `sha256:` of the normalized payload
- link identity: `link:<resolved absolute target>`
- user-owned region: a line count, never content
- target wiring identity: `sha256:` of the resolved story template's payload
- execution stamp identity: `sha256:` of the stamp document's bytes
- retained worker result identity: `sha256:` of the retained result document

A tree identity **fails** rather than under-reporting: an unreadable member, an
unreadable subdirectory or a failed scan produces no identity at all, and the
component is reported `BROKEN` / `IDENTITY_UNREADABLE`. Filenames, link targets
and declared exclusions are encoded so that a name containing a newline or a
tab cannot forge, merge or hide a record; declared exclusions are matched by
exact string equality, never by word splitting or globbing.

When the **canonical** side cannot be read, the component is
`CANONICAL_IDENTITY_UNREADABLE` — never `CURRENT`, and never adoptable.
Matching the applied identity proves nothing about currency when nobody could
open the content it would be compared with.

A live probe's stdout is diagnostic input, not evidence: it is truncated before
it is read, and only a classification derived from it ever reaches the result.

<!-- machine-checkable: evidence_provenance -->
```
HASH_COMPARISON
FILE_STRUCTURE
PATH_STRUCTURE
GIT_STATE
GIT_HISTORY
MANIFEST_SCHEMA
OWNERSHIP_RULE
ADAPTATION_RECORD
OPERATION_JOURNAL
VERSION_PROBE
CAPABILITY_PROBE
AUTH_STATUS_PROBE
ROUTER_STATUS
VALIDATOR_FIXTURE
BMAD_RESOLUTION
```
<!-- end -->

## States

<!-- machine-checkable: component_states -->
```
CURRENT
UPDATE_AVAILABLE
LOCAL_ADAPTATION
LOCAL_DRIFT
EXTERNAL_STATE
UNKNOWN
BROKEN
INCOMPATIBLE
MIGRATION_REQUIRED
INTERRUPTED
UNAVAILABLE
NOT_EVALUATED
OUT_OF_SCOPE
```
<!-- end -->

<!-- machine-checkable: overall_states -->
```
READY
READY_WITH_ADAPTATION
READY_WITH_WARNINGS
NOT_READY
NEEDS_OWNER
```
<!-- end -->

Classification is mechanical:

| Observation | State |
|---|---|
| observed == applied == canonical | `CURRENT` |
| observed == applied, canonical differs | `UPDATE_AVAILABLE` |
| observed == applied, canonical unreadable | `UNKNOWN` (`CANONICAL_IDENTITY_UNREADABLE`) |
| observed != applied, valid registered adaptation matches observed | `LOCAL_ADAPTATION` |
| observed != applied, no ownership rule and no valid adaptation | `LOCAL_DRIFT` |
| declared machine-owned destination | `LOCAL_ADAPTATION` (`MACHINE_OWNED_REGION`) |
| content outside a managed section | `EXTERNAL_STATE` (`USER_OWNED_REGION`) |
| no manifest, or manifest records no identity | `UNKNOWN` |
| absent, unreadable, redirected or malformed | `BROKEN` |

No heuristic and no model judgement participates in any of these decisions.

<!-- machine-checkable: severities -->
```
info
warning
owner_action
blocking
```
<!-- end -->

## Registered adaptations

An adaptation record legitimizes a difference only when it is bound tightly
enough to be falsifiable. Every one of these must hold:

| Binding | Rule |
|---|---|
| `id` | present, and unique across the manifest |
| `component` | a component this lifecycle declares |
| `type` | the type that component's ownership class can have |
| `location` | the component's declared location — its destination path, or `<destination>#<section-id>` for a managed section |
| `expected_identity` | well formed for the type: `sha256:<64 hex>`, or `link:<absolute path>` for `link-target` |
| `disposition` | `PRESERVE`, `REEVALUATE` or `OWNER_REVIEW` |
| `reason` | present, non-empty |

<!-- machine-checkable: adaptation_types -->
```
tree-content
file-content
section-payload
link-target
```
<!-- end -->

<!-- machine-checkable: adaptation_dispositions -->
```
PRESERVE
REEVALUATE
OWNER_REVIEW
```
<!-- end -->

Records are revalidated on every evaluation — status, update preflight and
verification alike:

<!-- machine-checkable: adaptation_states -->
```
VALID_MATCHED
STALE
INVALID
```
<!-- end -->

| Record state | Meaning |
|---|---|
| `VALID_MATCHED` | `expected_identity` equals what was observed; the difference is legitimate. |
| `STALE` | The record no longer matches what is installed. It legitimizes nothing, and the difference is `LOCAL_DRIFT`. |
| `INVALID` | Any binding above is unmet. It legitimizes nothing, and no plan is computed around it. |

What each disposition means to a mutating operation:

| Disposition | Update behaviour |
|---|---|
| `PRESERVE` | The component is left exactly as it is. The manifest keeps recording the canonical **baseline** identity, not the adapted bytes, so the record goes on explaining the difference instead of quietly becoming the thing the next update replaces. |
| `REEVALUATE` | The operation stops with `ADAPTATION_REEVALUATION_REQUIRED` once canonical content no longer matches the adapted content: the owner reconsiders the exception. |
| `OWNER_REVIEW` | The operation stops with `ADAPTATION_OWNER_REVIEW`. |

A valid adaptation is consulted **before** the applied-identity comparison, so
an explicit exception can never be overruled by the coincidence that the
adapted bytes are also what the manifest last recorded.

Adaptation records are secret-free by contract: they carry identities, not
content.

## Mutation plans

Every mutating operation computes its complete plan before its first managed
write, and the plan covers **every declared component** — including the ones it
will not touch.

```
{"plan_schema_version": "1.0", "command": "update",
 "plan_identity": "sha256:...", "disposition": "MUTATION_REQUIRED",
 "refusal_reason": null, "prior_revision": ..., "target_revision": ...,
 "required_mutations": 2, "approvals_required": 0, "conflicts": 0,
 "binding": {...},
 "components": [{"component": ..., "ownership": ..., "action": ...,
                 "reason": ..., "destination": ..., "source": ...,
                 "guard": {"expected_type": ..., "container_root": ...,
                           "target_root": ..., "declared_extra": ...},
                 "expected_destination_identity": ..., "applied_identity": ...,
                 "canonical_identity": ..., "target_identity": ...,
                 "adaptation": ..., "adaptation_disposition": ...,
                 "execution_critical": bool, "requires_approval": bool,
                 "backup_required": bool, "expected_final_state": ...}]}
```

<!-- machine-checkable: plan_actions -->
```
NONE
INSTALL
REPLACE
PRESERVE
CLAIM
BLOCKED
```
<!-- end -->

| Action | Meaning |
|---|---|
| `NONE` | Already at the target identity. Nothing is written. |
| `INSTALL` | The destination does not exist and nothing owns it, so creating it overwrites nothing. |
| `REPLACE` | The destination still matches its recognized applied state, so kit-owned content may be replaced deterministically. |
| `PRESERVE` | Declared machine-local state, or a `PRESERVE` adaptation. Never written. |
| `CLAIM` | Adoption records ownership of what is already installed. No content changes. |
| `BLOCKED` | A conflict. One blocked component refuses the whole plan: convergence is never partial. |

<!-- machine-checkable: plan_dispositions -->
```
NO_CHANGE
MUTATION_REQUIRED
APPROVAL_REQUIRED
REFUSED
```
<!-- end -->

### Plan identity, binding and approval

`binding` records the exact inputs the plan was computed from: the source
revision and repository identity, the manifest's own content identity, the
applied revision, the journal state, every component's path observation and
observed/canonical/applied identities, and every adaptation record's id,
expected identity and disposition.

`plan_identity` is the `sha256` of the sorted plan document **including its
binding**. Two consequences follow, and both are deliberate:

- The identity is stable: recomputing a plan over unchanged state produces the
  same identity, byte for byte.
- The identity moves the moment **any** bound input moves. An approval names
  one identity, so an approval never transfers to a plan recomputed after a
  change (`PLAN_APPROVAL_MISMATCH`). There is no "approve and hope".

A plan whose disposition is `APPROVAL_REQUIRED` authorizes nothing on its own:
the operation stops with `PLAN_APPROVAL_REQUIRED` and prints the identity to
approve. `--approve-plan <identity>` authorizes exactly that plan.

Immediately before the first managed write, the binding is recomputed and
compared. Any material difference is `PLAN_STALE_SOURCE_CHANGED`,
`PLAN_STALE_MANIFEST_CHANGED` or `PLAN_STALE_DESTINATION_CHANGED`, and
execution stops without silently recomputing under the earlier approval.

## The mutation transaction

Order is the contract:

1. An interrupted operation from a previous run is resolved **first** — rolled
   back deterministically, or stopped with `NEEDS_OWNER`. No new mutation
   begins over an unresolved one.
2. The installation lock is taken (`mkdir`, atomic) and stamped with an
   incarnation no other acquisition can carry. Overlapping mutating operations
   are prevented, never interleaved: at most one process owns the lock at any
   instant, whatever the contention. It is given back once the transaction has
   settled — immediately afterward on an ordinary run, at exit on an
   interrupted one — never while that process, or a write that process started,
   can still touch the installation — so an interrupted command ends rather
   than continuing unlocked. Refusals, plans and read-only commands never take
   it.
3. The plan binding is revalidated.
4. The journal is opened in `PREPARING` and names this operation's backup
   directory **before** that directory is filled, so recovery material never
   exists without a record that references it. Every required backup is then
   made and the journal moves to `IN_PROGRESS` — all of it before the first
   managed write.
5. Each component is written after its own guards and expected identity are
   revalidated, and each write is proven to have produced the identity the plan
   predicted — including the destination's own mode and ownership, which belong
   to the host owner and are preserved across the atomic rename that replaces
   the content. An unintended change is `DESTINATION_METADATA_NOT_PRESERVED`
   and is treated exactly like a change to the bytes outside a managed section.
6. If anything fails, every change made by the operation is restored **and the
   restoration is verified** by recomputing identities. `applied_revision`
   does not move: it names the revision this host has actually applied on every
   path, and the revision the operation was attempting is reported separately
   as `target_revision`.
7. The complete result is verified offline.
8. Only then is the applied-state manifest committed, by a single atomic
   rename, and only then does `applied_revision` advance.
9. Housekeeping — marking the journal committed, removing this operation's
   temporary recovery material and sweeping recovery material no journal names
   — happens after the commit and cannot change what the commit means.

```
{"id": "op-<...>", "command": "update", "mutating": true,
 "result": ..., "reason": ..., "detail": ..., "plan_identity": ...,
 "mutation_performed": bool, "applied_state_committed": bool,
 "rollback_state": "NOT_REQUIRED|IN_PROGRESS|COMPLETE|INCOMPLETE",
 "prior_revision": ..., "applied_revision": ..., "target_revision": ...,
 "completed_steps": [{"component": ..., "action": ..., "result": ...}]}
```

<!-- machine-checkable: operation_results -->
```
NO_CHANGE
CONVERGED
ADOPTED
PLAN_ONLY
APPROVAL_REQUIRED
REFUSED
STALE_PLAN
ROLLED_BACK
UNRECOVERABLE
RECOVERED
```
<!-- end -->

### The recovery journal

The journal is secret-free by construction: identities, declared paths,
revisions, the immutable plan identity, the pre-mutation observations and the
steps completed so far. Intent is recorded **before** the write it describes,
so a process killed between a write and its journal entry still leaves the
record that makes rollback possible.

The journal is read back as the authority for what an interrupted operation may
undo, so it carries `journal_schema_version` and a major version this
executable does not implement is **refused**, not interpreted
(`OPERATION_JOURNAL_SCHEMA_UNSUPPORTED`). Schema `2.x` requires `pre_mutation`
and `plan.components`, because a recorded destination is evidence that a path
was being touched and is never on its own authority to change or remove it.

A recorded step is acted on only when every one of these holds:

- the component id is declared by the **current** inventory, and the recorded
  destination is that component's declared destination;
- the journal agrees with itself — its `plan` entry and its `pre_mutation`
  entry name the same destination and the same expected identity;
- the destination passes the same containment and symlink guard a managed write
  passes;
- the backup directory named by the journal is inside the declared backup root
  and exists;
- and **either** a stored copy exists for that component, **or** the bound
  pre-mutation observation records that the destination held nothing and the
  step is the `INSTALL` that created it. `observed_identity: null` authorizes
  removal only when matched to that exact component and that exact operation
  binding.

Every restoration is verified by recomputing the identity from the filesystem,
by the same predicate the in-process rollback uses. A missing backup, an
undeclared component, a contradictory or incomplete record, a failed guard or a
failed verification stops with `NEEDS_OWNER` and keeps the journal and every
backup as the owner's recovery material. Nothing falls through to removal.

<!-- machine-checkable: journal_states -->
```
NONE
PREPARING
IN_PROGRESS
ROLLING_BACK
ROLLED_BACK
ROLLBACK_INCOMPLETE
COMMITTED
UNREADABLE
UNSAFE
```
<!-- end -->

Resumable transactions are explicitly **not** required in this increment. The
next lifecycle command detects an incomplete journal before any new mutation
and prefers deterministic rollback; what cannot be rolled back deterministically
stops with `NEEDS_OWNER` and keeps its journal and backups as the owner's
recovery material.

### Adoption is not convergence

Adoption establishes **ownership**; it converges nothing. Content is recorded at
the identity it already has, so nothing a legacy host holds is overwritten by
the act of adopting it:

- content byte-identical to current canonical content, a link already resolving
  to its declared target, and schema-declared machine-local fields adopt
  unattended;
- content byte-identical to a **reachable prior canonical revision** adopts
  unattended and is then reported `UPDATE_AVAILABLE`, so an ordinary `update`
  converges it under its own plan, backups and rollback;
- anything else requires an approved plan, because what needs a decision is the
  ownership claim itself;
- an ambiguous, redirected, unreadable or malformed destination refuses.

## Verification

`verify` observes and proves. It never repairs and never activates
orchestration. The same function is the final gate before any applied-state
manifest is committed, so a convergence can never be committed on weaker
evidence than a verification demands.

```
{"verified": bool, "offline": true, "repaired": false,
 "live_probes_performed": false, "checks_run": N, "failures": N, "warnings": N,
 "checks": [{"subject": ..., "check": ..., "result": ...,
             "reason": ..., "evidence": {...}}]}
```

<!-- machine-checkable: verification_results -->
```
PASS
FAIL
WARN
SKIP
```
<!-- end -->

Checks: manifest invariants and applied hash, state schema compatibility, no
open operation, no operation in progress, every declared component's integrity
against its recorded identity (with a valid adaptation as the one legitimate
difference), machine-local preservation, and every adaptation record. Target
wiring, the orchestration bridge, the dispatch-monitor summary and the
readiness scopes are reported beside the verification through the same
normalized model, and a target that does not resolve warns inside its own scope
without failing the verification.

Verification failure is reported as a blocking finding, so it drives the same
overall state machine every other blocking fact does — and nothing is repaired
on the way.

## Reason codes

Every nontrivial warning or block carries one. This is the complete published
vocabulary, and `agent-flow-kit schema` emits exactly this list:

<!-- machine-checkable: reason_codes -->
```
INSTALLATION_NOT_ADOPTED
STATE_SCHEMA_UNRECOGNIZED
STATE_SCHEMA_UNKNOWN_MAJOR
STATE_SCHEMA_MIGRATION_REQUIRED
STATE_MANIFEST_SHAPE_INVALID
STATE_MANIFEST_PATH_UNSAFE
STATE_MANIFEST_WRITE_FAILED
OPERATION_INTERRUPTED
OPERATION_JOURNAL_UNREADABLE
OPERATION_JOURNAL_PATH_UNSAFE
OPERATION_ROLLED_BACK
OPERATION_ROLLBACK_INCOMPLETE
OPERATION_RECOVERED
OPERATION_LOCK_UNAVAILABLE
CONCURRENT_OPERATION_IN_PROGRESS
SOURCE_NOT_A_GIT_CHECKOUT
SOURCE_REPOSITORY_UNIDENTIFIED
SOURCE_REPOSITORY_MISMATCH
SOURCE_DECLARATION_UNREADABLE
SOURCE_DECLARATION_INCOMPLETE
SOURCE_MANAGED_INPUT_MISSING
SOURCE_MANAGED_INPUT_DIRTY
SOURCE_DIRT_OUTSIDE_INPUT_SET
SOURCE_DETACHED_HEAD
SOURCE_NONCANONICAL_BRANCH
SOURCE_DOWNGRADE_REQUIRES_INTENT
SOURCE_REVISION_UNEXPECTED
APPLIED_REVISION_UNREACHABLE
SOURCE_LIFECYCLE_SCHEMA_INCOMPATIBLE
SOURCE_INELIGIBLE
COMPONENT_MISSING
COMPONENT_NOT_RECORDED
COMPONENT_NOT_INSTALLED
CANONICAL_REVISION_AHEAD
CANONICAL_IDENTITY_UNREADABLE
UNEXPLAINED_MANAGED_DIFFERENCE
REGISTERED_ADAPTATION
ADAPTATION_OWNER_REVIEW
ADAPTATION_REEVALUATION_REQUIRED
ADAPTATION_STALE
ADAPTATION_MALFORMED
ADAPTATION_DUPLICATE_ID
ADAPTATION_UNKNOWN_COMPONENT
ADAPTATION_INVALID_DISPOSITION
ADAPTATION_TYPE_MISMATCH
ADAPTATION_LOCATION_MISMATCH
ADAPTATION_EXPECTED_SHAPE_INVALID
ADAPTATION_TARGET_UNOBSERVABLE
MACHINE_OWNED_REGION
USER_OWNED_REGION
NOT_ADOPTED
IDENTITY_UNREADABLE
LINK_TARGET_MISSING
LINK_TARGET_UNEXPECTED
MANAGED_SECTION_ABSENT
MANAGED_SECTION_MARKERS_MALFORMED
OUTSIDE_CONTENT_NOT_PRESERVED
TARGET_PATH_MISSING
PATH_ABSENT
PATH_UNEXPECTED_SYMLINK
PATH_NOT_A_SYMLINK
PATH_TYPE_MISMATCH
PATH_UNRESOLVABLE_SYMLINK
PATH_ESCAPES_OWNERSHIP_BOUNDARY
PATH_PARENT_UNRESOLVABLE
PATH_PARENT_ESCAPES_BOUNDARY
PATH_BOUNDARY_UNRESOLVABLE
PERMISSION_PREREQUISITE_UNMET
BACKUP_PREREQUISITE_UNMET
MANAGED_WRITE_FAILED
POST_WRITE_IDENTITY_MISMATCH
PLAN_NO_CHANGE_REQUIRED
PLAN_NOT_COMPUTABLE
PLAN_STALE_SOURCE_CHANGED
PLAN_STALE_MANIFEST_CHANGED
PLAN_STALE_DESTINATION_CHANGED
PLAN_APPROVAL_REQUIRED
PLAN_APPROVAL_MISMATCH
PLAN_COMPONENT_CONFLICT
VERIFICATION_PASSED
VERIFICATION_FAILED
LIVE_PROBE_NOT_REQUESTED
NO_EXECUTION_STAMP_SUPPLIED
TARGET_READINESS_NOT_EVALUATED
EXACT_CANONICAL
RECOGNIZED_PRIOR_CANONICAL
EXACT_RECOGNIZED_WIRING
UNRECOGNIZED_CONTENT
ADOPTION_NOT_APPLICABLE_ALREADY_ADOPTED
ADOPTION_SOURCE_INELIGIBLE
SOURCE_REVISION_FORMAT_UNSUPPORTED
OPERATION_JOURNAL_SCHEMA_UNSUPPORTED
OPERATION_RECOVERY_AUTHORITY_INSUFFICIENT
OPERATION_RECOVERY_VERIFICATION_FAILED
OPERATION_LOCK_OWNER_UNVERIFIABLE
OPERATION_LOCK_RECLAIMED
DESTINATION_METADATA_NOT_PRESERVED
EXECUTABLE_RESOLVED
EXECUTABLE_NOT_RESOLVED
PROBE_BOUND_UNAVAILABLE
NO_TARGET_REGISTERED
TARGET_SCOPE_PARTIAL
TARGET_WIRING_UNRECOGNIZED
TARGET_WIRING_SCHEMA_INCOMPATIBLE
TARGET_WIRING_MALFORMED
TARGET_WIRING_OWNERSHIP_AMBIGUOUS
TARGET_WIRING_PROVEN
TARGET_PERSONA_UNRESOLVED
TARGET_TEMPLATE_UNRESOLVED
ORCHESTRATION_STATE_NOT_AVAILABLE
ORCHESTRATION_STATE_UNREADABLE
ORCHESTRATION_STATE_SCHEMA_UNSUPPORTED
ORCHESTRATION_STATE_AVAILABLE
ORCHESTRATION_SESSION_INACTIVE
ORCHESTRATION_NEEDS_HUMAN
ORCA_NOT_RESOLVED
ORCA_PROBE_FAILED
ORCA_PROBE_TIMED_OUT
ORCA_RUNTIME_REACHABLE
ORCA_CAPABILITY_UNPROVEN
ORCA_CAPABILITY_INCOMPATIBLE
ORCA_CAPABILITY_PROVEN
VALIDATOR_NOT_RESOLVED
VALIDATOR_CONTRACT_UNREADABLE
VALIDATOR_CONTRACT_INCOMPATIBLE
VALIDATOR_CONTRACT_PROVEN
VALIDATOR_FIXTURE_FAILED
VALIDATOR_VERDICT_UNAVAILABLE
VALIDATOR_ANTI_VACUITY_FAILED
VALIDATOR_FIXTURES_PROVEN
HARNESS_NOT_RESOLVED
HARNESS_CAPABILITY_UNPROVEN
HARNESS_CAPABILITY_PROVEN
AUTH_NATIVE_SUBSCRIPTION
AUTH_MODE_UNSUPPORTED
AUTH_REQUIRED
AUTH_STATUS_UNPROVEN
NO_SELECTED_WORKSPACE
WORKSPACE_TRUST_ESTABLISHED
WORKSPACE_TRUST_REQUIRED
WORKSPACE_TRUST_UNPROVEN
ROUTER_ENDPOINT_NOT_DECLARED
ROUTER_TRANSPORT_UNTRUSTED
ROUTER_AUTH_MISSING
ROUTER_UNREACHABLE
ROUTER_TIMED_OUT
ROUTER_API_SHAPE_UNSUPPORTED
ROUTER_AVAILABLE
ROUTER_CATALOG_COMPATIBLE
ROUTER_CATALOG_INCOMPATIBLE
NO_APPROVED_HARNESS_PATH
HOST_EXECUTION_READY_PROVEN
INSTALLED_INTEGRITY_NOT_PROVEN
STAMP_UNREADABLE
STAMP_SHAPE_INVALID
STAMP_EXPIRED
STAMP_VALIDATION_FAILED
STAMP_VALIDATION_UNPROVEN
ROUTE_PROFILE_UNSUPPORTED
ROUTE_FUNDING_CONFLICT
ROUTE_TARGET_UNRESOLVED
ROUTE_HARNESS_UNAVAILABLE
ROUTE_READY_PROVEN
PLACEMENT_NOT_A_LIFECYCLE_CONCERN
LIVE_OBSERVATION_NOT_LAUNCH_AUTHORITY
DISPATCH_WATCH_NOT_AVAILABLE
DISPATCH_WATCH_IDLE
DISPATCH_WATCH_ACTIVE
DISPATCH_WATCH_REGISTERED
DISPATCH_DESCRIPTOR_INVALID
DISPATCH_RECORD_UNREADABLE
DISPATCH_RECORD_SCHEMA_UNSUPPORTED
DISPATCH_UNKNOWN
DELIVERY_UNREADABLE
DELIVERY_REPLAY_IGNORED
WORKER_DONE_RETAINED
WORKER_ESCALATION_RETAINED
RESULT_NOT_RETAINED
RESULT_UNPARSEABLE
WORKER_HEARTBEAT_EXPIRED
WORKER_TERMINAL_EXITED_WITHOUT_DELIVERY
MONITOR_DEGRADED
TERMINAL_RELEASED
TERMINAL_RELEASE_UNPROVEN
TERMINAL_RETAINED_ACTIVE
TERMINAL_RETAINED_AWAITING_ANSWER
TERMINAL_RETAINED_AMBIGUOUS
TERMINAL_RETAINED_USER_TAKEOVER
TERMINAL_NOT_OWNED
WORKTREE_REMOVED
WORKTREE_RETAINED_UNSETTLED
WORKTREE_RETAINED_DIRTY
WORKTREE_NOT_OWNED
BRANCH_DELETED
BRANCH_RETAINED_UNMERGED
BRANCH_RETAINED_UNIQUE_COMMITS
BRANCH_RETAINED_PROTECTED
BRANCH_RETAINED_WORKTREE_PRESENT
BRANCH_NOT_OWNED
REMOTE_BRANCH_DELETED
REMOTE_BRANCH_ABSENT
REMOTE_BRANCH_RETAINED_UNAUTHORIZED
CLEANUP_NEEDS_OWNER
CLEANUP_COMPLETE
```
<!-- end -->

Every code carries a specific message, a specific impact and a specific
required action; the gates prove none of them falls back to a generic string.

## Findings

Every finding answers what is wrong, why it matters, who owns it and what can
safely happen next:

```
{"component": ..., "ownership": ..., "state": ..., "reason": ...,
 "severity": "info|warning|owner_action|blocking",
 "blocked_scopes": [...], "owner": "agent-flow-kit",
 "owner_action_required": bool, "mutation_safe": bool, "transient": bool,
 "evidence": {"provenance": ..., "expected": ..., "observed": ...},
 "message": ..., "impact": ..., "required_action": ..., "detail": ...}
```

`blocked_scopes` uses the readiness-scope names plus `MUTATION_SOURCE`,
`MUTATION:<component>` and `TARGET_READY:<target>`. Only findings that block
`INSTALLED_INTEGRITY` can drive the overall state to `NOT_READY` or
`NEEDS_OWNER`. A transient live observation sets `transient: true`, which is
how automation tells "retry later" from "an owner must decide".

Dispatch-monitor findings block no readiness scope at all. A worker that needs a
human and a resource that could not be released are owner actions about
orchestration, not defects of this installation: they are loud, they set the
`monitor` command's own exit code, and they never make `status` report the
installation `NOT_READY`.

## Adoption analysis

`adopt --inspect` adds `extra.adoption`:

```
{"disposition": "AUTO_ADOPTABLE|APPROVAL_REQUIRED|REFUSED",
 "inspect_only": true, "mutation_performed": false, "manifest_created": false,
 "applied_revision_advanced": false, "ownership_claimed": false,
 "components": [{"id": ..., "classification": ..., "reason": ..., "evidence": ...}]}
```

<!-- machine-checkable: adoption_dispositions -->
```
AUTO_ADOPTABLE
APPROVAL_REQUIRED
REFUSED
NOT_INSTALLED
```
<!-- end -->

The aggregate is the strongest of the per-component classifications: any
refusal refuses; otherwise any approval requirement requires approval.

Prior-canonical recognition walks the full reachable history of the declared
source path, for single files, managed sections **and** managed copy trees.
There is no revision cutoff: a bound on how far back recognition looks is a
bound on correctness, and a legacy host is exactly the case where the installed
content is old. The walk terminates on identity, not on a count — each distinct
Git object is hashed once, and historical tree identities are computed from Git
objects with the same record format the installed side uses, so the two are
comparable by construction.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Requested scope succeeded. `READY_WITH_WARNINGS`, `READY_WITH_ADAPTATION`, a computable plan, a verified installation and a no-op update all count as success. |
| 1 | Command, internal or usage failure. Includes an unknown command, an option the command does not accept, a missing library, an undeclared destination, and any failure to assemble a well-formed result. |
| 2 | Owner action or conflict. A refused plan, a required or mismatched approval, a stale plan, a concurrent operation, a failure whose restoration could not complete, a route awaiting a human workspace-trust decision, and a monitor pass that left something only a human can decide. |
| 3 | Deterministic not-ready or verification failure. A rolled-back operation and a recovered interruption land here: nothing claims the target revision. So does a readiness scope this run put in scope and proved false. |
| 4 | Source or precondition refusal. An ineligible mutation source, or `status --require-source-eligible` on one. |
| 5 | Live dependency unavailable or timed out. Produced only by a run that requested live readiness and could not look. |

<!-- machine-checkable: exit_codes -->
```
0 requested scope succeeded (includes READY_WITH_WARNINGS and READY_WITH_ADAPTATION)
1 command, internal, or usage failure
2 owner action or conflict
3 deterministic not-ready or verification failure
4 source or precondition refusal
5 live dependency unavailable or timed out
```
<!-- end -->

For `adopt --inspect` the requested scope is the analysis itself:
`AUTO_ADOPTABLE` exits 0, `APPROVAL_REQUIRED` and `REFUSED` exit 2, regardless
of the installation's overall readiness.

For `monitor` the requested scope is the pass itself: it exits 2 when something
is left that only a human can decide, and 0 when the pass accounted for every
watched Dispatch. "Left" is decided on what the pass read after its own action,
so a fault it repaired is not carried into its verdict.

A run that requests `--live` or names a `--stamp` puts those scopes into scope,
so their verdict decides the exit code. A default `status` remains an
installed-state question and keeps deriving its code from installed integrity:
adding a readiness scope to the output never changes what an existing caller's
exit code means.

These are the codes a lifecycle command produces from a result. A run stopped
by a signal produces none: it exits `128 +` the signal number — 130 for
`SIGINT`, 143 for `SIGTERM`, 129 for `SIGHUP`, and the same arithmetic for
every other signal the lock section names — and emits no result document. That
is not one of the codes above and must not be read as one: nothing was decided,
and the installation is left in whatever state the interruption reached, with
its journal intact for the next command to resolve.

## Guarantees this contract makes

- `status`, `adopt --inspect`, `verify`, `monitor` without an action verb and
  every `--plan` invocation mutate no filesystem, Git, runtime, authentication,
  router or orchestration state.
- Without `--live` no lifecycle command executes another program, opens a
  socket, authenticates anywhere or creates a temporary file.
- The lifecycle never fetches, pulls, merges, rebases or switches Git state,
  and never activates orchestration or mutates external authority.
- No live probe logs in, creates a worker, changes a BMAD repository, runs
  implementation, creates placement, or enables a metered path; every one is
  bounded, timestamped and non-authoritative for launch.
- No free-form or model-driven merging resolves any managed-content question.
- Path type, containment and symlink boundaries — including parent chains —
  are validated before a managed destination is read, hashed, backed up or
  replaced, and again immediately before its own write.
- A mutation that cannot be completed and verified never advances the applied
  revision, and partial state is never reported as successful convergence.
- Content outside a managed section, declared machine-local configuration and
  target-project content are preserved.
- Source eligibility, installed integrity, host execution readiness, new-work
  readiness, per-target readiness and per-route readiness are independent
  dimensions and are independently observable.
- No route is ever substituted, retargeted or extended locally, and no live
  observation is ever recorded as launch authorization.
- A worker is completed only by a supervised completion delivery. Terminal
  idleness, an exited process and session history never manufacture a result,
  and a monitoring fault is always reported as a monitoring fault.
- Completion delivery is at-least-once and its handling is idempotent: a replay
  cannot duplicate settlement, traceability or cleanup, and nothing is
  acknowledged before it has been retained and reconciled.
- Cleanup is provenance-bound. A terminal, worktree or branch is released only
  because a durable record proves this host created it for that exact Dispatch;
  ambiguity fails closed, and unowned, protected and default resources are
  report-only inventory.
- Every observation a monitor pass makes outside this host is bounded and
  non-interactive, or is refused and reported rather than made unbounded, so
  one bounded pass stays one bounded pass whatever the transport does.
- No secret value, credential content or authorization header is emitted or
  persisted, on any path, including diagnostics, failure paths, the journal
  and the manifest.
