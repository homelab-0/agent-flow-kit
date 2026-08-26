# agent-flow-kit lifecycle contract

The documented, versioned machine contract for the lifecycle entry point
(`bin/agent-flow-kit`). Automation reads this document and the `schema`
subcommand; it never parses human output.

Result schema version: **1.0**
Supported lifecycle schema major: **1**
Supported state schema major: **1**

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
| `status` | Read-only installed state, ownership, drift, adaptations, source eligibility, readiness scopes. Writes nothing, probes nothing external. |
| `adopt --inspect` | Inspect-only adoption analysis. Reports a disposition and changes nothing. |
| `adopt` | The adoption transaction: establishes durable ownership at the identities already installed, verifies offline, then commits the manifest. |
| `update` | Deterministic convergence for an adopted host: plan, backup, journal, write, verify, commit — or refuse. |
| `verify` | Offline verification of installed state against the applied-state manifest. Observes and proves; never repairs. |
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
schema
```
<!-- end -->

Live readiness — router availability, provider sessions, Orca, validator
contracts — belongs to Story 1.3. Nothing in this increment performs a network
request, an authentication probe, or any other external call.

`status`, `adopt --inspect`, `verify` and every `--plan` invocation are pure
functions of local state. They emit no timestamp, so two runs over unchanged
state produce byte-identical machine output — which is what makes idempotence
testable rather than asserted.

## Command output

Both renderings derive from one normalized model. `--json` prints the document;
human output is projected from that same document, so the two cannot drift. The
projection is complete: every component, target, adaptation, finding, readiness
scope, live fact, environment record, plan entry, operation step and
verification check in the document appears in the human rendering, with its
state and its reason.

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

| Scope | Behaviour in this increment |
|---|---|
| `INSTALLED_INTEGRITY` | Evaluated offline from hashes and path structure. |
| `MUTATION_SOURCE_ELIGIBLE` | `TRUE` / `FALSE`, evaluated from Git state. |
| `HOST_EXECUTION_READY` | `NOT_EVALUATED` / `LIVE_PROBE_NOT_REQUESTED`. |
| `NEW_WORK_READY` | `NOT_EVALUATED` / `LIVE_PROBE_NOT_REQUESTED`. |
| `TARGET_READY` | `NOT_EVALUATED` / `LIVE_PROBE_NOT_REQUESTED`. |
| `ROUTE_READY` | `OUT_OF_SCOPE` / `NO_EXECUTION_STAMP_SUPPLIED`. |

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

Four distinct conditions are representable and are never collapsed: an
evaluated false result, a field outside the command's scope (`OUT_OF_SCOPE`), a
temporarily unavailable observation (`UNAVAILABLE`), and a probe that was not
performed (`NOT_EVALUATED`).

### `live_facts`

`router_status`, `router_catalog_provenance`, `claude_native_session`,
`codex_native_session`, `orca_runtime`, `validator_contract`.

Default evaluation performs **no** router request, no provider-authentication
probe and no other external call, so every one of these reports
`NOT_EVALUATED` with reason `LIVE_PROBE_NOT_REQUESTED`. Live evaluation is
Story 1.3.

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
line cannot land in a usage diagnostic. The VALUE of `--approve-plan` is never
echoed either.

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
| `KIT_STATE` | The state manifest, the operation journal and the operation lock. |
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

## Offline verification

`verify` observes and proves. It never repairs, never probes a live service and
never activates orchestration. The same function is the final gate before any
applied-state manifest is committed, so a convergence can never be committed on
weaker evidence than a verification demands.

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
difference), machine-local preservation, every adaptation record, and target
wiring **structure**. A missing target warns inside its own scope; proving
persona and template resolution is live readiness work and belongs to Story 1.3.

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
`NEEDS_OWNER`.

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
| 2 | Owner action or conflict. A refused plan, a required or mismatched approval, a stale plan, a concurrent operation, and a failure whose restoration could not complete. |
| 3 | Deterministic not-ready or verification failure. A rolled-back operation and a recovered interruption land here: nothing claims the target revision. |
| 4 | Source or precondition refusal. An ineligible mutation source, or `status --require-source-eligible` on one. |
| 5 | Live dependency unavailable or timed out. Not produced by this increment, which performs no live probe. |

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

These are the codes a lifecycle command produces from a result. A run stopped
by a signal produces none: it exits `128 +` the signal number — 130 for
`SIGINT`, 143 for `SIGTERM`, 129 for `SIGHUP`, and the same arithmetic for
every other signal the lock section names — and emits no result document. That
is not one of the codes above and must not be read as one: nothing was decided,
and the installation is left in whatever state the interruption reached, with
its journal intact for the next command to resolve.

## Guarantees this contract makes

- `status`, `adopt --inspect`, `verify` and every `--plan` invocation mutate no
  filesystem, Git, runtime, authentication, router or orchestration state.
- The lifecycle never fetches, pulls, merges, rebases or switches Git state,
  and never activates orchestration or mutates external authority.
- No free-form or model-driven merging resolves any managed-content question.
- Path type, containment and symlink boundaries — including parent chains —
  are validated before a managed destination is read, hashed, backed up or
  replaced, and again immediately before its own write.
- A mutation that cannot be completed and verified never advances the applied
  revision, and partial state is never reported as successful convergence.
- Content outside a managed section, declared machine-local configuration and
  target-project content are preserved.
- Source eligibility, installed integrity and live availability are
  independent dimensions and are independently observable.
- No secret value, credential content or authorization header is emitted or
  persisted, on any path, including diagnostics, failure paths, the journal
  and the manifest.
