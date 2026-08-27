# AFK-PORT-1.3 — full adversarial review (review-only, fresh session)

## 1. Verdict

**NOT CLEAN — 4 blocker(s).**

Non-blocking register: 14 entries.

Scope reviewed: the whole Story 1.3 increment on this worktree (base master
`bd9d9fb`) — `lib/afk-readiness.sh` (1857 lines), `lib/afk-monitor.sh` (1094),
`bin/agent-flow-kit`, `lib/afk-commands.sh`, `lib/afk-common.sh`,
`lib/afk-inventory.sh`, `docs/LIFECYCLE-CONTRACT.md`,
`tests/lifecycle-readiness-tests.sh`, `tests/lifecycle-dispatch-tests.sh`,
`tests/lifecycle-tests.sh`, `tests/run-tests.sh`, and the C1/C2 gate evidence.

I had Read/Glob/Grep/Write and no shell. Every blocker is expressed as a
runnable script under
`evidence/AFK-PORT-1.3-FULL-REVIEW-attack/`, each of which decides its own
verdict and prints a control result. **A blocker whose script does not
reproduce is not established** — I could not execute them, and I would rather
be falsifiable than confident.

---

## 2. Blockers

### B1 — a terminal Orca is not currently listing is reported RELEASED, with no durable close ever requested

**Reproduction**

```
bash _bmad-output/implementation-artifacts/evidence/AFK-PORT-1.3-FULL-REVIEW-attack/A1-terminal-absent-no-durable-close.sh
```

Predicted observables: `cleanup.terminal == "REMOVED"`, dispatch `state ==
"SETTLED"`, exit 0, and the stub's durable-close ledger (`STUB_CLOSED`) does
**not** contain the handle. After the simulated reconnect the handle is listed
again, a second `monitor --cleanup --live` does nothing (a SETTLED Dispatch
owns nothing), `dispatch_monitor.retained.terminals == 0`, and the pass exits 0.
The control in the same script shows that the `IDLE` path *does* request the
durable close, so the difference is real rather than a stub artifact.

**Code**

`lib/afk-monitor.sh:712-732`:

```
tstatus="$(afk_monitor_terminal_status "$handle")"
case "$tstatus" in
  ABSENT)          printf 'REMOVED TERMINAL_RELEASED'; return 0 ;;
  ...
  IDLE|EXITED)     : ;;
  *)               printf 'NEEDS_OWNER TERMINAL_RELEASE_UNPROVEN'; return 0 ;;
esac
afk_monitor_terminal_release "$handle" || true
```

`ABSENT` returns before `afk_monitor_terminal_release` is ever reached.
`afk_monitor_terminal_status` (`lib/afk-monitor.sh:347-354`) returns `ABSENT`
for any handle not in the current `orca terminal list` output.

**Frozen text violated**

`AFK-PORT-1.3.md`, *Required Worker-Terminal Cleanup Contract*:

> Terminal closure must be durable across Orca disconnect/reconnect and
> provider-session discovery. A completed worker must not reappear as a newly
> resumed Claude/Codex tab merely because its transcript remains in session
> history. Cleanup must record or request Orca's supported durable close
> intent; killing the current PTY alone is insufficient.

`docs/LIFECYCLE-CONTRACT.md:678`, Terminal row of the provenance-bound cleanup
table:

> Released only when AFK-owned, and Orca reports it `IDLE` or `EXITED`. A
> **durable** close is requested and its absence is re-observed.

`ABSENT` is neither `IDLE` nor `EXITED`. The code adds a third acceptance case
the contract does not authorise, and it is exactly the case in which no durable
intent exists to be recorded.

**Reachability**

Natural, and arguably the common case rather than the edge one. `ABSENT` is
what the monitor sees whenever (a) Orca prunes finished terminals from
`terminal list` while keeping their sessions resumable — which is the entire
premise of the durable-close requirement; (b) the Orca daemon restarted and has
not yet rediscovered sessions; or (c) a human closed the worker tab in the UI
before settlement, which is one ordinary operator action. In every case the tab
returns on the next reconnect, the Dispatch is already `SETTLED`, and
`afk_monitor_cleanup_record` (`lib/afk-monitor.sh:897-901`) returns immediately
for a settled record — so no later pass can ever release it. The retained-
terminal counters skip settled records too
(`lib/afk-monitor.sh:1017`), so the orphan is invisible in
`dispatch_monitor.retained`.

The story's own gate cannot see this: every terminal in
`tests/lifecycle-dispatch-tests.sh` is added to the stub listing before
cleanup, so `ABSENT` is only ever reached in the *fault* sweep, never in the
cleanup path.

**Remedy sketch**

Treat `ABSENT` as unproven rather than as proof. Either request the durable
close unconditionally for an AFK-owned handle before judging (`ABSENT` then
falls through to the same request/re-observe pair as `IDLE|EXITED`), or fail
closed on `NEEDS_OWNER / TERMINAL_RELEASE_UNPROVEN` when the handle cannot be
observed at all — the same disposition the `*)` branch already gives an
unknown status. The first is preferable: a durable close for a handle Orca has
forgotten is a harmless no-op, and it records the intent that survives the
reconnect. Whichever is chosen, the cleanup path and
`afk_monitor_watch_sweep` should stop reading the same observation two
opposite ways (see N14).

---

### B2 — `ROUTE_READY` is TRUE with the "compatible BMAD target" leg never evaluated, and the workspace-trust decision disappears with it

**Reproduction**

```
bash _bmad-output/implementation-artifacts/evidence/AFK-PORT-1.3-FULL-REVIEW-attack/A2-route-ready-without-target.sh
```

The script writes one manifest and then rewrites **only** its `targets` array
between six otherwise byte-identical runs, so the registered-target arity is
the sole variable. Predicted observables:

| registered targets | `--target` | ROUTE_READY | exit |
|---|---|---|---|
| one wired | no | `TRUE` | 0 (control) |
| one **unwired** | no | `FALSE` / `ROUTE_TARGET_UNRESOLVED` | 3 (control) |
| wired **+** the same unwired one | no | `TRUE` / `ROUTE_READY_PROVEN` | **0** |
| none | no | `TRUE` | **0** |
| one wired, trust withheld | no | `FALSE` / `WORKSPACE_TRUST_REQUIRED` | 2 (control) |
| two targets, the **same** trust withheld | no | `TRUE`, zero `WORKSPACE_TRUST_REQUIRED` findings | **0** |

**Code**

`lib/afk-readiness.sh:1597-1632`:

```
if [[ -z "$reason" ]]; then
  target_id="$AFK_ROUTE_TARGET"
  if [[ -z "$target_id" ]]; then
    target_id="$(printf '%s' "$AFK_RD_TARGET_ENTRIES" | jq -sr \
      'if length == 1 then .[0].id else "" end')"
  fi
  if [[ -n "$target_id" ]]; then
    ... ROUTE_TARGET_UNRESOLVED / tpath="$(afk_target_path "$target_id")"
  fi                       # <- no else branch: 0 or >=2 targets skip everything
fi
...
if [[ -z "$reason" && "$AFK_STAMP_HARNESS" == "claude" && -n "$tpath" ]]; then
  afk_evaluate_workspace_trust "$tpath" ...
fi
```

With zero or two-or-more registered targets and no `--target`, `target_id` is
empty, the target check is skipped entirely, `tpath` stays empty, and the
workspace-trust evaluation guarded on it never runs. Nothing anywhere refuses
the ambiguity: `bin/agent-flow-kit:375-378` only refuses `--target` *without*
`--stamp`, never `--stamp` under an ambiguous target set.

**Frozen text violated**

`AFK-PORT-1.3.md` acceptance criteria:

> **Then** usable execution equals router-approved profile ∩ kit-supported
> launch contract ∩ host capabilities ∩ **compatible BMAD target** ∩ valid
> final stamp

`AFK-PORT-1.3.md`, *Observed Host Bootstrap / Autonomy Concern*:

> Story 1.3 must detect and report a selected Claude path that is awaiting
> workspace trust as an affected-harness/route readiness condition with loud
> `NEEDS_HUMAN`; it must not claim the route launchable

`docs/LIFECYCLE-CONTRACT.md:853` assigns the target leg to the target
repository with failure `ROUTE_TARGET_UNRESOLVED`; `:857-869` describe route
readiness as *the intersection of every authority*. An intersection with a
silently dropped operand is not that intersection.

**Reachability**

A manifest `targets` array with two entries is ordinary configuration — the
contract itself devotes a `PARTIAL` aggregate state and a whole independence
case to the multi-target host (`docs/LIFECYCLE-CONTRACT.md:357-361`), and
`tests/lifecycle-tests.sh:1400-1417` exercises exactly that shape. Running
`status --live --stamp <path>` without `--target` is one ordinary operator
action; the option is optional by design. The zero-target shape is reachable on
any host that has not registered a target yet.

The story's gate cannot see this either: `write_manifest` in
`tests/lifecycle-readiness-tests.sh:498-514` registers exactly one target, and
`--target` appears in the whole test tree only at
`tests/lifecycle-tests.sh:1845`, as a usage refusal. Every route scenario runs
at the one arity that hides the defect.

**Remedy sketch**

Make an unresolvable target binding fail closed rather than vanish. Two
targets and no `--target` is ownership ambiguity of exactly the kind
`TARGET_WIRING_OWNERSHIP_AMBIGUOUS` already refuses to guess at: either refuse
at the usage boundary (`--stamp` requires `--target` when the registered set is
not a singleton) or set `ROUTE_READY = FALSE / ROUTE_TARGET_UNRESOLVED` when
`target_id` cannot be determined. Zero registered targets should take the same
path. Whichever is chosen, the workspace-trust evaluation must not be reachable
only through a `tpath` that this code path can silently leave empty — consider
evaluating it from the route's declared worker path rather than from the target
path, and emitting `NO_SELECTED_WORKSPACE` when there genuinely is none (see
N5).

---

### B3 — a monitor pass that repairs the only fault still reports `NEEDS_HUMAN` and still exits 2

**Reproduction**

```
bash _bmad-output/implementation-artifacts/evidence/AFK-PORT-1.3-FULL-REVIEW-attack/A3-stale-needs-human.sh
```

Predicted observables on the repairing pass: record `state == "COMPLETED"`,
`fault == null`, `result.status == "done"`, `counts.degraded == 0`,
`counts.unreadable == 0`, `pending_deliveries == 0`, no dispatch carrying a
fault — and yet `dispatch_monitor.state == "NEEDS_HUMAN"`,
`dispatch_monitor.reason == "MONITOR_DEGRADED"`, exit **2**. The control is the
sharp part: the *next* process, reading the identical unchanged on-disk state,
reports `WATCHING` and exits 0.

**Code**

`AFK_MON_NEEDS_HUMAN` is a latch. `afk_monitor_summarize`
(`lib/afk-monitor.sh:975-1082`) only ever sets it to `"true"` — at `:998`,
`:1009`, `:1012`, `:1015`, `:1079` — and never clears it.
`afk_cmd_monitor` (`lib/afk-commands.sh:465-497`) calls it **twice**:

```
afk_evaluate_installation "false" "false"   # :472 -> afk_monitor_summarize (pre-action)
case "$AFK_MONITOR_MODE" in ... esac        # :474-485 the action that repairs the fault
afk_monitor_summarize                       # :489 post-action; flag already latched
AFK_R_FORCED_EXIT="$(afk_monitor_exit_code)"  # :490 -> 2
```

`afk_monitor_reset` (`lib/afk-monitor.sh:130-137`) is the function that would
clear it, and it is never called anywhere in the tree (see N8).

**Frozen text violated**

`docs/LIFECYCLE-CONTRACT.md:1640-1642`:

> For `monitor` the requested scope is the pass itself: it exits 2 when
> something is left that only a human can decide, and 0 when the pass accounted
> for every watched Dispatch.

and the `monitor_states` vocabulary (`:582-589`), in which `NEEDS_HUMAN` is a
state of the watch, not a memory of a state the same process already repaired.
The emitted document is internally contradictory: `state: "NEEDS_HUMAN"`,
`reason: "MONITOR_DEGRADED"`, `counts.degraded: 0`.

**Reachability**

It is the recovery flow the frozen story requires:

> A completion result that cannot be retained or parsed remains
> unacknowledged/recoverable and becomes loud `NEEDS_HUMAN` rather than
> disappearing.

The pass that consumes the corrected delivery is the pass that mis-reports. It
also fires for any `--register` or `--cleanup` pass run on a host that carries
one degraded record alongside healthy ones, once that record is repaired.

The gate stops one assertion short of catching it:
`tests/lifecycle-dispatch-tests.sh:439-443` asserts the recovered record's
state, fault and status, and asserts neither `RUN_RC` nor
`.dispatch_monitor.state` for that pass — the only pass in the suite where
they would disagree.

**Impact direction and remedy sketch**

This fails loud, not open — it manufactures an owner action rather than hiding
one. It is still a blocker because a scheduler driving `monitor` (the whole
point of the bounded-pass design) reads exit 2 as "stop and fetch a human", so
one transient parse fault makes every subsequent pass in that process look
blocked. Remedy: call `afk_monitor_reset` — or at minimum reset
`AFK_MON_NEEDS_HUMAN="false"` — at the top of `afk_monitor_summarize`, so the
summary describes the state it just read rather than the union of everything
the process has seen. Note that findings accumulated by the earlier pass stay
in `AFK_FINDINGS` by design; only the derived state and exit code need to
follow the post-action reading. Add the missing `RUN_RC` /
`dispatch_monitor.state` assertions to the recovery case so the fix is pinned.

---

### B4 — the "one bounded pass" reaches the network through unbounded `git` calls

**Reproduction**

```
bash _bmad-output/implementation-artifacts/evidence/AFK-PORT-1.3-FULL-REVIEW-attack/A4-unbounded-remote-op.sh
```

Predicted observables: `monitor --json --cleanup --live` against a record whose
remote sits behind a stalled transport does not return; the script's external
`timeout 20` kills it (exit 124). The control — the same fixture, the same
record, a transport that answers immediately — returns promptly. The script
skips honestly with exit 2 if `timeout(1)` is absent.

**Code**

`lib/afk-monitor.sh:857, :869, :870`:

```
left="$(git -C "$repo" ls-remote --heads "$remote" "$br" 2>/dev/null)" || left="unreadable"
...
git -C "$repo" push "$remote" --delete "$br" >/dev/null 2>&1 || true
left="$(git -C "$repo" ls-remote --heads "$remote" "$br" 2>/dev/null)" || left="unreadable"
```

None of the three goes through `afk_probe_run` (`lib/afk-readiness.sh:462-497`),
which is the function that exists precisely so that "bounded, non-mutating,
timestamped" is a property of one place rather than of each caller remembering.
The monitor's *Orca* observations do use it (`lib/afk-monitor.sh:335`, `:360`).
The remote-branch disposition is reached whenever the watch record carries a
branch name, a remote name and an existing repo — independently of every other
disposition (`lib/afk-monitor.sh:842-877`).

**Frozen text violated**

`AFK-PORT-1.3.md`, *Required Worker-Completion Monitoring Contract*:

> The completion monitor must be bounded and event-driven or use bounded
> polling/backoff; it must not require an indefinitely live LLM turn or create
> an unbounded busy loop.

`docs/LIFECYCLE-CONTRACT.md:628-631`:

> `monitor` performs exactly one bounded pass per invocation. … Nothing here
> blocks, and nothing here can spin.

`docs/LIFECYCLE-CONTRACT.md:421-424`:

> A host that cannot bound a probe reports `PROBE_BOUND_UNAVAILABLE` rather
> than running an unbounded probe as if it were a bounded one.

The lifecycle has no code path that could report `PROBE_BOUND_UNAVAILABLE` for
these calls, because they never ask.

**Reachability**

A worker branch pushed to a real remote, then a dropped VPN, an expired SSH
agent, a stalled proxy or a black-holed host — all natural. The
credential-prompt shape is worse and needs no network fault at all:
`GIT_TERMINAL_PROMPT` is unset by default, so an https remote with expired
credentials makes `git` block on an interactive username prompt *inside the
settlement pass*. The attack script pins `GIT_TERMINAL_PROMPT=0` so the
reproduction measures only the deterministic half.

This is the same failure the story exists to eliminate, arrived at from the
other side: the coordinator is again stuck inside a pass that will not return.

**Remedy sketch**

Route the three calls through `afk_probe_run` (they are external observations
by the contract's own definition), or at minimum wrap them in the same
`timeout` the runner uses and set `GIT_TERMINAL_PROMPT=0`,
`GIT_ASKPASS=/bin/true`, `GIT_SSH_COMMAND` with `BatchMode=yes` for the
duration. A call that cannot be bounded on this host should report
`PROBE_BOUND_UNAVAILABLE` and leave the remote branch `NEEDS_OWNER`, which is
already the fail-closed disposition for an unprovable remote deletion.

---

## 3. Non-blocking register

Class in brackets. Each entry names the exact location and the frozen text it
presses on.

**N1 [method] `tests/lifecycle-tests.sh:1721-1723` and `:1727-1729` — two
published-reason sweeps that can never fail.** Both evaluate
`select(($pub | index(.)) == null)`. jq evaluates the argument of `index()`
against the *input* of `index()`, so `.` is `$pub` itself; an array searching
for itself always finds itself at index 0, `== null` is never true, and the
sweep selects nothing. They are green because they guard nothing. This is the
same defect C2-A fixed in the readiness gate; the Dev Agent Record recorded
these two and left them, which is the correct process. Corroborated by the
cycle-1 evidence: `AFK-PORT-1.3-C1-gates/run-tests.log:289` shows the
identically-shaped readiness sweep passing while its three siblings errored.
Remedy: bind first (`. as $r | select(($pub | index($r)) == null)`) and add the
falsifiability control the readiness gate now carries. Note this may turn the
gate red — that is the point, and the outcome is currently unknown.

**N2 [method] `tests/lifecycle-tests.sh:1696-1700` — the three vocabularies this
story added are the three the drift gate does not check.**
`monitor_states`, `dispatch_states` and `cleanup_dispositions` are declared as
`machine-checkable` blocks in `docs/LIFECYCLE-CONTRACT.md:582-608` and
published by `afk_cmd_schema` (`lib/afk-commands.sh:888-890`), but they are
absent from the `for key in ...` list that compares schema against document
element for element. The document's own promise (`:20-23`) that "this document
cannot drift away from the executable" is unenforced for them. The dispatch
gate's section 8 checks emitted values against the *schema* arrays, which does
not close this. (`plan_actions`, `plan_dispositions`, `journal_states`,
`operation_results`, `verification_results` are missing too, but they predate
this story.)

**N3 [method] skipped sub-gate checks are invisible in the retained evidence.**
`tests/lifecycle-readiness-tests.sh:47` defines `skip()` as a printf that
increments nothing, and the suite's summary (`:1157`) prints only
`N passed, M failed`. `tests/run-tests.sh:1086-1088` surfaces only that tail
line when the sub-gate succeeds, discarding the body. So
`AFK-PORT-1.3-C2-gates/run-tests.log:263` — `231 passed, 0 failed` — cannot
distinguish a router-timeout scenario that ran from one that skipped
(`tests/lifecycle-readiness-tests.sh:697-710`, skipped when `timeout(1)` is
absent), nor an epoch check that skipped (`:143-147`). `tests/run-tests.sh`
itself was deliberately taught this lesson (`:1119-1122`: "skipped checks
computed no verdict — they are not passes"); the two new sub-gates were not.
Remedy: count skips in both new suites, print them in the summary line, and
have run-tests fail or loudly flag a sub-gate that reports any.

**N4 [behavior] `lib/afk-readiness.sh:1452-1454, :1487-1488, :1521-1523` — the
router caller token is passed on argv.** `-H "Authorization: Bearer
${!token_name}"` puts the bearer token in `/proc/<pid>/cmdline`, world-readable
by default on Linux, for the duration of each probe. `docs/LIFECYCLE-CONTRACT.md:707-710`
says no "authorization header … is ever emitted or persisted"; the surrounding
text is about result documents and persisted state, so this is a reading the
coordinator should rule on rather than one I will assert. The kit is otherwise
careful here (`env -i` sanitizers in the dispatcher, `[REDACTED]` in the
environment section), which makes the argv path stand out. Remedy: feed the
header to curl on stdin (`-K -` or `--header @-`), or write it into a 0600 file
in the fixture directory that the EXIT boundary already removes.

**N5 [behavior] `lib/afk-readiness.sh:1016-1021` — `NO_SELECTED_WORKSPACE` is
unreachable published vocabulary.** `afk_evaluate_workspace_trust` has an
empty-path branch that emits it, but its only call site (`:1628-1632`) is
guarded on `-n "$tpath"`, so the branch is dead. Every "no workspace selected"
case instead reports the seeded `LIVE_PROBE_NOT_REQUESTED`, which says
something different. `docs/LIFECYCLE-CONTRACT.md:1483` publishes the code and
the gate at `tests/lifecycle-readiness-tests.sh:69-78` proves it carries a
message and an action — a vocabulary entry that is fully documented and never
emitted. Interacts with B2.

**N6 [method] `verify --live`, `verify --stamp` and `--synthetic-route` under
`--live` have no coverage anywhere.** A grep of `tests/` finds
`--synthetic-route` only at `tests/lifecycle-tests.sh:1843`, as the usage
refusal, and `verify` never with `--live` or `--stamp`. The synthetic-route
path (`lib/afk-readiness.sh:1520-1534`) is the kit's only authenticated POST to
the router and is named explicitly in a frozen AC ("a harmless synthetic
`/v1/route` may run only in explicit live mode without launching or spending
provider tokens"). `afk_cmd_verify`'s new invocation-derived `offline` /
`live_probes_performed` flags (`lib/afk-commands.sh:526-529`) are likewise
untested. All three are cheap to cover with the stubs the readiness gate
already builds.

**N7 [method] two of the six required completion-monitor regressions are
approximated rather than tested.** (a) `RESULT_NOT_RETAINED` — the frozen
"a completion result that cannot be **retained**" half — has no scenario; only
`RESULT_UNPARSEABLE` does (`tests/lifecycle-dispatch-tests.sh:424-443`). The
retention-failure branch (`lib/afk-monitor.sh:575-583`), which is the one that
proves acknowledgement never outruns retention, is unexercised. (b) "a replayed
`worker_done` … cannot repeat a cleanup that already happened"
(`docs/LIFECYCLE-CONTRACT.md:660-662`) is proven by a repeat-*cleanup* test
with no replay involved (`:516-521`) plus counter assertions on a replay with
no cleanup involved (`:359-373`); no scenario replays a delivery *after*
cleanup has settled the Dispatch. That composition is worth one scenario,
because it is the one that would exercise `.state = "COMPLETED"` being written
back over `SETTLED` by `lib/afk-monitor.sh:597`. Separately, the "coordinator
restart with one **completed unacknowledged** Dispatch" case (`:375-387`) uses
a Dispatch that section 2 already acknowledged; the shape is close but not the
frozen one.

**N8 [behavior] `lib/afk-monitor.sh:130-137` — `afk_monitor_reset` is dead
code.** Defined, never called (grep of the whole tree finds only the
definition). It is also the fix for B3. shellcheck at `--severity=warning` does
not report an unused function, so the lint gate cannot catch this class.

**N9 [behavior] the monitor's writes take no lock.** `monitor --register`,
`--reconcile` and `--cleanup` write kit state, and
`afk_evaluate_installation` only *observes* a held lock
(`lib/afk-commands.sh:85-90`). Two concurrent `monitor --reconcile` passes can
both read a record whose `processed_deliveries` is empty, both retain, and the
second write supersede the first. Nothing is duplicated today because the
effects are content-idempotent (`settlement.scheduled_count` and
`traceability.records` are `if > 0 then keep`, `lib/afk-monitor.sh:602-606`,
and the traceability record is written by content, `:587-591`) — but the
at-least-once/idempotence guarantee then rests on the shape of two jq
expressions rather than on mutual exclusion, which is not how the rest of this
kit argues its concurrency. Worth either a lock or an explicit sentence in the
contract saying the guarantee is content-keyed and why that is sufficient.

**N10 [docs] `lib/afk-common.sh:67` — `afk_require_tools` does not require
`date` or `mktemp`.** Both are new hard dependencies: `afk_now_utc`,
`afk_epoch_of_utc` (`lib/afk-readiness.sh:432, :909`), `afk_monitor_now`
(`lib/afk-monitor.sh:313`) and `afk_validator_fixture_dir_create`
(`lib/afk-readiness.sh:1113`). Without them the code degrades into
`UNKNOWN` timestamps, epoch `0` (which disables every heartbeat deadline) and
`VALIDATOR_FIXTURE_FAILED`, none of which says "this host is missing a tool".

**N11 [behavior] `dispatch_monitor.dispatches[]` is rendered but its parity is
unproven.** `lib/afk-common.sh:1179-1185` renders each dispatch's id, state,
fault and cleanup into human output; the only projection sweep that touches
dispatch data (`tests/lifecycle-readiness-tests.sh:1076`) checks
`.dispatch_monitor.state` and `.reason` and nothing else, and the dispatch gate
does no human-parity check at all. `docs/LIFECYCLE-CONTRACT.md:66-71` promises
"every … dispatch record … appears in the human rendering, with its state and
its reason."

**N12 [behavior] `ROUTER_CATALOG_INCOMPATIBLE` never reaches route readiness.**
`lib/afk-readiness.sh:1506-1512` emits it as a warning with an empty
`blocked_scopes`, and `afk_evaluate_route_readiness` never consults it. This is
defensible — `docs/LIFECYCLE-CONTRACT.md:849` assigns catalog provenance to the
validator, which does hold the stamp's frozen catalog version — but the frozen
AC "unknown stamp, validator, route, funding/auth, permission, Orca launch,
persona/wiring, selected-harness, or deterministic-gate semantics block the
affected route" makes it worth an explicit coordinator ruling rather than an
implicit one. It is also untested: no scenario sets `STUB_ROUTER_CATALOG` to a
value that disagrees with the stamp, despite the stub supporting it
(`tests/lifecycle-readiness-tests.sh:437`).

**N13 [method] one of the three declared gates has no retained evidence.**
`evidence/AFK-PORT-1.3-C2-gates/` contains `run-tests.log` and `lifecycle.log`
only; `git diff --check` produced no artifact. It is a cheap gate and a cheap
artifact.

**N14 [behavior] the same Orca observation is read two opposite ways.**
`afk_monitor_watch_sweep` (`lib/afk-monitor.sh:662-671`) treats `ABSENT` as a
monitoring **fault** — `WORKER_TERMINAL_EXITED_WITHOUT_DELIVERY`, loud, never a
result — while `afk_monitor_cleanup_terminal` (`:714`) treats the identical
observation as proof of **successful release**. One of the two is wrong about
what `ABSENT` means. Registered separately from B1 because it also matters if
B1's remedy is scoped narrowly: whatever `ABSENT` is decided to mean, both
readers should say so.

---

## 4. Evidence attacks performed, and their outcomes

**Are the new gates genuinely wired into `tests/run-tests.sh`?** Yes.
Sections 9 (`:1084-1094`) and 10 (`:1106-1116`) run each sub-gate in its own
process, branch on its **exit status**, surface its tail on failure, and
`bad` if the file is missing — so a deleted or renamed sub-gate fails the
aggregate rather than disappearing. Both sub-gates end with
`(( FAIL == 0 )) || exit 1` (`lifecycle-readiness-tests.sh:1158`,
`lifecycle-dispatch-tests.sh:759`), so a failing assertion really does
propagate. **Genuine.** The one hole is skip accounting — N3.

**Do the four falsifiability controls in the readiness gate discriminate?**
Yes, and they are built the right way round.
`tests/lifecycle-readiness-tests.sh:1100-1142` factors each sweep into a named
function, runs it over the live document expecting `0`, then runs the *same
function* over a copy with one out-of-set value injected expecting exactly `1`.
Each sweep binds the tested value to a jq variable first
(`. as $st | select(($s | index($st)) == null)`), which is precisely the fix
for the C2-A defect. A sweep that stopped discriminating would fail its own
control. **Genuine, and the strongest part of this increment's test design.**
The dispatch gate carries the same shape at `:734-743`.

**Does the monitor gate's non-resurrection proof discriminate?** Yes.
`tests/lifecycle-dispatch-tests.sh:691-705` asserts the released tab stays
absent *and* then closes a second tab without `--durable` and asserts it comes
back. Without that control the assertion would be an accident of a forgetful
stub. **Genuine.** It is also what makes B1 legible: the gate proves the
durable path works and never exercises the path that skips it.

**Do the C1/C2 logs say what the Dev Agent Record claims?** Yes, on every point
I could check.
- `AFK-PORT-1.3-C1-gates/run-tests.log:262-305`: readiness gate `215 passed, 4
  failed`, aggregate `232 passed, 1 failed`, lifecycle/mutation/concurrency all
  green. The 40-line tail shows only **three** failures (`:291`, `:294`,
  `:297`), exactly as recorded — the fourth is above the cut. The record's
  account of the missing fourth failure is therefore verifiable only against
  the code, and it is: the exit-5 mapping it describes is present at
  `lib/afk-readiness.sh:1162-1170` and pinned at
  `tests/lifecycle-readiness-tests.sh:863-872`.
- `:289` shows `every reason code in a live result is published` **passing** in
  the red run, corroborating the record's claim that this fourth sweep was
  vacuous rather than broken.
- `AFK-PORT-1.3-C2-gates/run-tests.log`: shellcheck ran and identified itself
  (`nix 0.11.0`), all fourteen files clean including both new libraries;
  lifecycle 474/0, mutation 577/0, concurrency 207/0, readiness 231/0, dispatch
  182/0, aggregate 235/0. **Consistent.** What it cannot show is whether any
  sub-gate check skipped (N3), and it carries no `git diff --check` artifact
  (N13).

**Do the worker's claims in the Dev Agent Record hold?** The cycle-2 record is
unusually honest and I found no false claim in it. Spot checks that held:
`afk_evaluate_targets` is genuinely gone from `lib/afk-inventory.sh` with no
dangling caller; `AFK_VALIDATOR_FIXTURE_DIR` is force-initialised to `""` at
source time (`lib/afk-readiness.sh:183`) rather than from the environment, so
the EXIT-boundary `rm -rf` cannot be aimed by a caller — a detail the record
does not claim but which an attacker would try first; the reason vocabulary is
split three ways with no collisions and every code carries a message and an
action, proven by the gates themselves. The record's two self-reported
discoveries (the `:1721`/`:1727` sweeps and the `dispatch_monitor` reporting
asymmetry) are both real; the first is N1, the second I judge deliberate and
correct (an unreadable dispatch record is not an installation-integrity
defect) — the reporting asymmetry is worth documenting in the contract, not
changing.

**Attacks that found nothing, recorded so the coordinator knows they were
tried.** Default-mode purity: `afk_readiness_evaluate`
(`lib/afk-readiness.sh:1805-1831`) starts no external process off the `--live`
branch — executable resolution is `command -v`, target wiring and the
orchestration bridge are filesystem reads, and the only default-mode fact with
a non-exempt provenance would be a validator one, which does not run. Timestamp
suppression is enforced by provenance class (`:514-522`), so the byte-stable
default output survives `--stamp`. Path-fragment injection through
`dispatch_id`: refused by `afk_dispatch_id_is_safe`
(`lib/afk-monitor.sh:271-278`) before any path is built, and the gate tests
`../escape`, `a/b`, `a..b`. Option-value echo: `afk_safe_diagnostic`
(`lib/afk-common.sh:502-515`) is a closed vocabulary and `--register`'s value
follows the same rule as `--stamp`. Recursive delete in cleanup: there is none
— the worktree goes through `git worktree remove` or is retained. `monitor
--live` correctly does **not** switch on the readiness probes
(`bin/agent-flow-kit:420-421`). Metered fallback, login, worker creation and
placement persistence: no code path creates any of them.

---

## 5. Judgment-call review

**C2-C — the frozen-requirement collision (validator fixtures stay behind
`--live`). Sound, and the collision is larger than recorded.**

The exact assertions the record names are real and I verified them:
`tests/lifecycle-tests.sh:1431` enumerates `agent-stamp-validate` in the stub
set whose every member records its own invocation; `:1448` asserts a default
`status --json` invoked none of them; `:1454` asserts
`validator_fixtures` is `NOT_EVALUATED` on the same run. Running the validator
against local fixtures in default mode would fail both.

Two things the record does not say, and the coordinator should weigh:

1. The collision is with **three** frozen texts, not one.
   `docs/LIFECYCLE-CONTRACT.md:53-55` promises that without `--live` no
   lifecycle command "executes another program, opens a socket, authenticates
   anywhere, **or creates a temporary file**" — and the fixture suite needs
   `mktemp -d` (`lib/afk-readiness.sh:1113`). `:1660-1664` repeats it in the
   guarantees list. So implementing the ruling literally costs the temp-file
   guarantee as well as the no-external-binary one.
2. It would also cost the **byte-stable default output** guarantee
   (`:57-62`) unless the default-mode fixture path is made to emit no
   `observed_at`, which means classing a validator run as a non-observation —
   the exact thing the boundary at `:405-415` argues it is not.

I judge the worker's disposition correct on the process: it refused to weaken a
frozen assertion, refused to silently revert, recorded the exact lines, and
escalated. I judge the substance correct too — "locally knowable" is a poor
description of starting a separate product's binary that writes to a temp
directory. My recommendation to the coordinator is to resolve this at the level
of the frozen text rather than the code: either amend the AC's reading of
"validator-fixture facts" to mean *the fixture set is materialisable and the
validator resolves*, which default mode can genuinely answer offline, or accept
all three contract amendments knowingly and in one edit. What should not happen
is a code change that leaves three contract sentences describing a command that
no longer exists.

**Monitor interpretation 1 — "must not duplicate review dispatch" proven
through the effects a replay must not repeat. Sound.** Nothing in Story 1.3
launches a reviewer, so a duplicate launch is genuinely unobservable here, and
`settlement.scheduled_count`, `traceability.records` and the count of
traceability files on disk are the right proxies for the idempotence that would
prevent one. The gap is not in the reasoning but in the coverage — see N7(b):
the third effect the frozen text names, "cannot repeat a cleanup that already
happened", is not proven by any test that involves a replay. I would ask for
that one scenario before accepting the interpretation as fully discharged.

**Monitor interpretation 2 — the delivery transport modelled as a durable inbox
directory. Sound, and correctly bounded.** It is the smallest construct that
makes "at-least-once, survives a disconnect, consumed by a later invocation"
real and testable without this story growing a client for an Orca API it does
not otherwise touch, and the record is right that the reconciliation semantics
are unchanged if only the reader moves. Two observations for the coordinator:
the inbox is an **unauthenticated write surface** — any process that can write
into the state directory can inject a `worker_done` and cause AFK to retain a
result and schedule settlement for a worker that never ran; the state
directory's `0700` mode is the whole trust boundary, and the contract should
say so explicitly rather than leaving it implied. And `afk_monitor_records` /
`afk_monitor_deliveries` (`lib/afk-monitor.sh:280-288`) read the directory with
`find -maxdepth 1 -type f`, so the pass is bounded by the directory's size —
fine today, but there is no cap and no oldest-first ordering, which is worth a
line if a stuck delivery can accumulate.

---

## 6. What I did not get to, plainly

- **I executed nothing.** No gate was run, no script was run, no output was
  observed. Everything above is derived from reading the source. The four
  blockers stand or fall on the attack scripts, which the coordinator must run;
  I have tried to make each one decide its own verdict and carry its own
  control so a non-reproduction is unambiguous.
- **The attack scripts themselves are unexecuted.** They were written blind. If
  one fails for a fixture reason rather than a product reason, the finding it
  carries is still argued from the cited source lines and should be judged on
  those, but it is not *reproduced* in the sense the blocker bar requires until
  the script runs.
- **Story 1.2's frozen surface was not independently re-attacked.** I read
  `lib/afk-plan.sh` and `lib/afk-mutate.sh` only where this diff touches them,
  and `tests/lifecycle-mutation-tests.sh` and
  `tests/lifecycle-concurrency-tests.sh` not at all. The shared EXIT-boundary
  change was reviewed by reading `bin/agent-flow-kit:497-517` and
  `afk_validator_fixture_dir_remove`: the ordering (lock release, then fixture
  removal) is safe because the fixture directory is not the installation, and
  the removal cannot be aimed by a caller. I did not verify that the lock
  contract itself still holds under contention.
- **`tests/lifecycle-tests.sh` was read only in the regions this story
  touched** — sections 8, 9, 10, 12 and 13. Sections 1-7 and 11 were not read,
  so a regression this diff sneaks under one of them would not have been seen.
- **No FR-by-FR trace against the frozen PRD.** I worked from the story's
  acceptance criteria and `docs/LIFECYCLE-CONTRACT.md`. The FR numbers cited
  throughout the new code's comments (FR-47, FR-52, FR-62, FR-83, FR-95 and
  ~30 others) were **not** checked against the PRD text; a comment citing the
  wrong FR would have passed unnoticed.
- **Human output was reviewed structurally only** — I read `afk_render_human`'s
  new projections but never saw rendered output, so anything about layout,
  truncation or encoding in practice is unexamined.
- **shellcheck and whitespace: not checked.** The C2 evidence says clean; I
  could not confirm it, and my findings suggest no new lint-visible code.
- **The C2 numbers were not recomputed.** I checked the logs for internal
  consistency and for what they can hide, not for arithmetic.
- **Packaging.** The ~4,700-line diff-size flag is the worker's and it is
  correctly raised; I did not re-derive the count and I have no view to add
  beyond noting that the four blockers all live in the two layers the worker's
  own suggested split would separate (offline readiness; the dispatch monitor),
  which is mild evidence for the split.
