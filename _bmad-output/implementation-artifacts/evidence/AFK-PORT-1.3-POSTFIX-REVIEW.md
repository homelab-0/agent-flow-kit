# AFK-PORT-1.3 — diff-scoped post-fix review (review-only, fresh session)

## 1. Verdict

**NOT CLEAN — 2 blocker(s).**

Delta-scoped meaning: two blockers inside the cycle-3 changed surface. Both are
*remedy-completeness* failures rather than new regressions — B1 and B4 each
closed the reproduced instance and left a narrower path to the same frozen harm
open, and in B4's case the fix's own new contract sentence asserts that path is
closed.

Non-blocking register: 8 entries.

Scope: the ~250-line cycle-3 delta across `lib/afk-monitor.sh`,
`lib/afk-readiness.sh:1597-1643`, `docs/LIFECYCLE-CONTRACT.md`,
`tests/lifecycle-dispatch-tests.sh`, `tests/lifecycle-readiness-tests.sh`,
`tests/lifecycle-tests.sh:1719-1748`, and their named interaction points. Prior
scenarios were not re-swept.

I had Read/Glob/Grep/Write and **no shell**. Both blockers are expressed as
runnable scripts under
`evidence/AFK-PORT-1.3-POSTFIX-REVIEW-attack/`; each decides its own verdict,
carries controls, and exits `0` REPRODUCED / `1` NOT REPRODUCED / `2`
inconclusive. **A blocker whose script does not reproduce is not established.**

---

## 2. Blockers

### P1 — a durable close that FAILS still reports the terminal `RELEASED`, because for an `ABSENT` handle the re-observation was already true before the request

**Reproduction**

```
bash _bmad-output/implementation-artifacts/evidence/AFK-PORT-1.3-POSTFIX-REVIEW-attack/P1-absent-close-unproven.sh
```

Predicted observables on the attack run: `cleanup.terminal == "REMOVED"`, record
`state == "SETTLED"`, exit `0`, `dispatch_monitor.retained.terminals == 0`, and
the stub's durable-close ledger does **not** contain `term-ghost` — because the
close was refused. After the simulated reconnect the handle is listed again, and
a second `monitor --cleanup --live` does nothing (a `SETTLED` Dispatch owns
nothing). Control A: the identical fixture with a close that succeeds records the
intent and the tab does not come back. Control B: the same refusal at `IDLE`
fails closed on `NEEDS_OWNER` / `COMPLETED`.

**Code**

`lib/afk-monitor.sh:812-824`:

```
    ABSENT|IDLE|EXITED) : ;;
    *)               printf 'NEEDS_OWNER TERMINAL_RELEASE_UNPROVEN'; return 0 ;;
  esac
  afk_monitor_terminal_release "$handle" || true
  afk_monitor_terminals_load || true
  tstatus="$(afk_monitor_terminal_status "$handle")"
  if [[ "$tstatus" == "ABSENT" ]]; then
    printf 'REMOVED TERMINAL_RELEASED'
```

The unified arm is right, and for `IDLE`/`EXITED` the re-observation is real
evidence: the handle *was* listed, so its disappearance is caused by the close.
For `ABSENT` it is a tautology — the handle was not listed before the request, so
it is not listed after it whether the close succeeded, failed, or was rejected
outright. The one observation that could discriminate is the close request's own
exit status, and `|| true` at `:815` discards it. `afk_monitor_cleanup_record`
(`:1000-1004`) then returns immediately for the `SETTLED` record it produced, so
no later pass can revisit it, and the retained counters skip settled records
(`:1128`), so the orphan is invisible in `dispatch_monitor.retained`.

**Frozen text violated**

`docs/LIFECYCLE-CONTRACT.md:702` (Terminal row, as rewritten by this fix):

> Released only when … a **durable** close was requested for it and its absence
> re-observed afterwards. … An unproven closure is `NEEDS_OWNER`.

and `:719-721`, added by this fix:

> A durable close for a terminal Orca no longer lists is a harmless no-op that
> **records the intent**; skipping it is how a settled Dispatch comes to own
> nothing while its tab comes back on the next reconnect.

That sentence is an assumption about Orca that the code never checks. When the
request fails, no intent is recorded and the closure is unproven — and the code
reports `REMOVED`. The story's *Required Worker-Terminal Cleanup Contract* is the
same requirement from the other side:

> Cleanup must record or request Orca's supported durable close intent; killing
> the current PTY alone is insufficient.

**Reachability**

Natural, and it needs no network fault:

- An Orca that errors when asked to close a handle it is not listing — which is
  precisely the `ABSENT` case, i.e. the case this arm exists for.
- An installed Orca that does not support `--durable` (the flag is passed
  unconditionally at `:445`). Every close then fails; `IDLE`/`EXITED` correctly
  fail closed because the handle is still listed on re-observation, and `ABSENT`
  alone converts a *total* failure of the durable-close mechanism into a
  release. The asymmetry is the tell.
- Any transient close rejection — permission, provider-session error — on a
  daemon still healthy enough to answer `terminal list`. (If the daemon is *not*
  healthy, `afk_monitor_terminals_load` fails, status is `UNKNOWN`, and the code
  correctly fails closed. The reachable window is exactly "list works, close
  does not".)

The gate cannot see it: the suite's Orca stub
(`tests/lifecycle-dispatch-tests.sh:200-216`) succeeds on every close, for any
handle, listed or not — it bakes in the assumption the code takes on faith.

**Remedy sketch**

For the `ABSENT` arm the close's own outcome is the only new evidence, so consume
it: keep the release call's status (`if ! afk_monitor_terminal_release "$handle";
then printf 'NEEDS_OWNER TERMINAL_RELEASE_UNPROVEN'; return 0; fi`) at least when
the pre-status was `ABSENT`. `IDLE`/`EXITED` may keep `|| true` because their
re-observation still discriminates, but consuming the status for all three is
simpler and strictly safer — a close that failed and a terminal that is
nonetheless gone is still an unproven closure. Whichever is chosen, teach the
gate's stub to refuse a close for a handle it is not listing, or the regression
will keep passing on the assumption instead of on the behaviour.

---

### P2 — the pass is still unbounded through its two Orca observations on a host without `timeout(1)`, and the fix's new contract sentence says it is not

**Reproduction**

```
bash _bmad-output/implementation-artifacts/evidence/AFK-PORT-1.3-POSTFIX-REVIEW-attack/P2-orca-observation-unbounded.sh
```

Predicted observables: with a PATH sandbox that differs from the host's own PATH
in exactly one entry — `timeout(1)` removed — `monitor --json --cleanup --live`
against a stalled Orca does not return, and the script's external `timeout 45`
kills it (exit 124). Control A (same stalled Orca, `timeout` on PATH) returns in
seconds with `NEEDS_OWNER` and exit 2. Control B (no `timeout`, an Orca that
answers) returns promptly, which is what proves the sandbox PATH is complete
enough to run the kit.

**Code**

`afk_monitor_git_remote` (`lib/afk-monitor.sh:373-401`) is strict, and correctly
so: no bounding tool → `PROBE_BOUND_UNAVAILABLE`, the call is not run, the
disposition is `NEEDS_OWNER`. The pass's other two external observations do not
share that policy:

- `lib/afk-monitor.sh:412` — `afk_probe_run "$AFK_ORCA_BIN" terminal list --json`
- `lib/afk-monitor.sh:445` — `afk_probe_run "$AFK_ORCA_BIN" terminal close --handle … --durable --json`

`afk_probe_run` (`lib/afk-readiness.sh:472-484`) warns once and then **runs the
call unbounded**:

```
  if afk_have timeout; then
    out="$(timeout "$secs" "$@" 2>/dev/null)"
  else
    …PROBE_BOUND_UNAVAILABLE…
    out="$("$@" 2>/dev/null)"
```

That is a considered, documented reading for *readiness probes* (the code says so
at `:446-448`), and the cycle-3 record acknowledges the divergence explicitly
("stricter than `afk_probe_run`, which runs unbounded and warns — deliberately").
But the monitor carries a stronger guarantee than readiness does, and the fix
wrote a new sentence claiming it holds for all three:

**Frozen text violated**

`docs/LIFECYCLE-CONTRACT.md:650-655`, **added by this fix**:

> Every observation the pass makes outside this host is bounded by the same
> declared timeout the live probes use, and none of them can ask a human
> anything: the Orca listing, the durable close, and the remote-branch
> observations alike. An unbounded call would make "one bounded pass" untrue of
> the pass that mattered most — the one settling a worker over a transport that
> stopped answering.

`docs/LIFECYCLE-CONTRACT.md:645-648` (frozen): "`monitor` performs exactly one
bounded pass per invocation. … Nothing here blocks, and nothing here can spin."

`docs/LIFECYCLE-CONTRACT.md:421-423` (frozen): "A host that cannot bound a probe
reports `PROBE_BOUND_UNAVAILABLE` rather than running an unbounded probe as if it
were a bounded one."

`AFK-PORT-1.3.md`, *Required Worker-Completion Monitoring Contract*: "The
completion monitor must be bounded … it must not require an indefinitely live LLM
turn or create an unbounded busy loop."

**Reachability**

A host without coreutils `timeout(1)` — macOS without coreutils installed, and
minimal containers, are the ordinary cases — plus an Orca daemon that accepts the
request and stalls. `afk_require_tools` (`lib/afk-common.sh:67`) does not require
`timeout`, nothing refuses `--live` without it, and the only signal is a
`warning`-severity finding buried in the result document. This is B4's harm
arriving through the door B4 did not name: the coordinator is again stuck inside
a pass that will not return.

**Remedy sketch**

Two honest ways out, and they are not equivalent. The cheap one is to narrow the
new sentence to the calls that are actually strict — but that leaves the monitor
genuinely able to hang and leaves `:421-423` describing something the kit does
not do. The real one is to make the monitor's two Orca calls take
`afk_monitor_git_remote`'s policy: a shared strict wrapper (or a
`AFK_PROBE_STRICT` flag on `afk_probe_run`) that reports
`PROBE_BOUND_UNAVAILABLE` and does not run, so an unbounded host gets
`TERMINAL_RELEASE_UNPROVEN` / `NEEDS_OWNER` for every terminal instead of a hang.
That also makes the frozen `:421-423` sentence true of the monitor for the first
time. Either way, add `timeout` to `afk_require_tools` (see D3) so the operator
learns this from the tool rather than from a stalled pass.

---

## 3. Non-blocking register (delta-scoped)

Class in brackets, with file:line and the text it presses on.

**D1 [behavior] `lib/afk-monitor.sh:394-399` vs `:954-978` — the wrapper's
failure-vs-timeout discrimination is computed and thrown away.**
`afk_monitor_git_remote` sets `AFK_MON_GIT_STATUS` to `TIMEOUT`, `NONZERO`,
`BOUND_UNAVAILABLE` or `OK`, and **no caller ever reads it** (grep of the tree
finds only the assignments). Both remote-branch call sites branch on the return
code alone, so a stalled transport, a rejected push and a host that cannot bound
the call are all reported as `NEEDS_OWNER` / `CLEANUP_NEEDS_OWNER` with nothing
to tell them apart. The dispositions are contract-correct — `:705` says an
observation that could not complete "proves nothing either way" — so this is
diagnostic loss, not a wrong answer. `BOUND_UNAVAILABLE` is the exception: it
does surface, through the shared `PROBE_BOUND_UNAVAILABLE` finding.

**D2 [method] `tests/lifecycle-dispatch-tests.sh:604-628` — the `stalled-remote`
regression passes vacuously on a host without `timeout(1)`.** There the wrapper
refuses before making the call, so the pass returns fast, the disposition is
`NEEDS_OWNER`, the finding count is 1, the state is `COMPLETED`, the retained
count is 1 and the exit is 2 — every assertion in the scenario holds for a reason
that has nothing to do with bounding a stalled transport. It is not silent
overall: `answering-remote` (`:644`), `d-merged`'s `REMOTE_BRANCH_DELETED` and
`d-unauth`'s `RETAINED` all fail on such a host, so the suite goes red. But it
goes red without naming the cause, and nothing asserts the tool is present.
Remedy: skip the bounding scenario loudly when `timeout` is absent (and count the
skip — N3), or assert the dependency once at suite start.

**D3 [docs] `lib/afk-common.sh:67` — N10 got worse.** `afk_require_tools` still
omits `timeout`, which the delta made load-bearing for every remote-branch
disposition and for the whole boundedness claim (P2). Registered as a
*worsening* of N10 (`date`, `mktemp`) rather than a new entry.

**D4 [method] `tests/lifecycle-dispatch-tests.sh:200-216` — the Orca stub cannot
express a failed close.** `terminal close` succeeds for every handle, listed or
not, so the fixture asserts the assumption in `docs/LIFECYCLE-CONTRACT.md:719-721`
rather than testing it. This is what makes P1 invisible to the gate; it is
registered separately because it stays worth fixing whatever the coordinator
decides about P1.

**D5 [behavior] `lib/afk-monitor.sh:818` — one transient listing failure
downgrades the rest of the pass.** The mid-pass `afk_monitor_terminals_load ||
true` sets `AFK_MON_TERMINALS_LOADED=false` on failure, and nothing reloads it,
so every *subsequent* Dispatch in the same cleanup pass sees `UNKNOWN` and takes
the `*)` arm → `NEEDS_OWNER TERMINAL_RELEASE_UNPROVEN`. Fail-closed and
recoverable on the next pass, so not a blocker. Pre-existing in shape; the new
`ABSENT` arm widens how often the reload is reached.

**D6 [behavior] `lib/afk-readiness.sh:1639-1643` — a new finding in a path that
previously emitted none.** The trust evaluation now runs for every Claude route,
including one that already carries a reason. The only shape where that changes
observable output is `ROUTE_HARNESS_UNAVAILABLE` (set at `:1626`, *after* `tpath`
was resolved): such a route now also emits a `WORKSPACE_TRUST_REQUIRED`
`owner_action` finding scoped to `ROUTE_READY`. The exit class is unaffected —
`afk_readiness_exit_code` (`:1848-1867`) keys off `AFK_RD_ROUTE_REASON`, not
findings, and `overall.state` only consults findings blocking
`INSTALLED_INTEGRITY` (`lib/afk-common.sh:1006-1011`) — so the Dev Agent Record's
claim ("no refusal changes its code or its exit class because of this") holds. No
test covers the combination.

**D7 [behavior] `docs/LIFECYCLE-CONTRACT.md:729-732` — "the required action stays
loud" is true only of the pass that did the cleanup.** A *later* read-only pass
over a record left with `NEEDS_OWNER` dispositions reports `state: "WATCHING"`,
`required_action: null` and exit 0, while `dispatch_monitor.retained.*` still
counts the resources: `afk_monitor_summarize` derives its verdict from record
state, `fault` and `result.needs_human` (`:1115-1127`) and never from
`.cleanup.*`. Identical before and after the fix — the pass latch was equally
per-process — so the delta did **not** make it worse. Registered because the
split makes the derived verdict the sole carrier of loudness, which puts the gap
one step closer to the surface.

**D8 [method] `lib/afk-monitor.sh:143-144, :605, :701` — `AFK_MON_REPLAYS` and
`AFK_MON_CONSUMED` are incremented and never read.** Pre-existing dead counters;
noted only because `afk_monitor_reset` now resets them alongside the two flags
that do matter, which reads as if they were part of the verdict. Related to N8,
which the record correctly leaves open (`afk_monitor_reset` is still called from
no product code — only from `tests/lifecycle-dispatch-tests.sh:124,135`).

Residual registry N2, N3, N4, N6, N7, N9, N11, N12, N13: re-checked as
unchanged by the delta and not re-raised. N2 in particular is still open —
`monitor_states`, `dispatch_states` and `cleanup_dispositions` remain absent from
the drift loop at `tests/lifecycle-tests.sh:1696-1700`.

---

## 4. Remedy completeness, per blocker

**B1 — PARTIAL.** The unified arm is the right shape and the reproduced instance
is closed: `ABSENT` no longer returns before the release call, both readings of
`ABSENT` are now stated at their code sites and in the contract (N14 genuinely
resolved), and the four human-in-the-loop states plus the `*)` fallback are
untouched, so nothing previously retained is now released. What is not closed is
the *class*: the arm decides on a re-observation that carries no information for
`ABSENT`, and discards the only evidence that does. See **P1**. The settled-record
early return (`:1000-1004`) is unchanged and correct in itself — it is idempotence
— but it is what makes a wrong `REMOVED` permanent, which is why P1's harm has no
later recovery. A stale listing is not a risk: the re-observation reloads.

**B2 — COMPLETE.** I could not find a remaining path where `tpath` is empty and
`ROUTE_READY` stays `TRUE`: `tpath` is a `local` initialised to `""` (`:1541`)
and is assigned only inside the branch that also leaves `reason` empty
(`:1611-1616`), so empty `tpath` and a ready route are now mutually exclusive.
`--target` naming an unregistered id fails `afk_target_registered`, and a
registered-but-unwired one fails `afk_target_ready`; both give
`ROUTE_TARGET_UNRESOLVED` (row 4 of the matrix pins the second). Zero and ≥2
arity take the same path. The usage boundary
(`bin/agent-flow-kit:375-378`) is untouched as the brief required. The
`--synthetic-route` path is a router probe on a different axis
(`lib/afk-readiness.sh:1520-1534`): it neither reads the target binding nor is
gated by it, so there is no interaction — it remains an explicit opt-in that
requires `--live` (`bin/agent-flow-kit:371-374`) and is still untested (N6,
unchanged). `NO_SELECTED_WORKSPACE` is now genuinely emitted (N5 absorbed), and
the reading is defensible: with no bound path there is no per-directory trust
decision to report, and the route is `FALSE` regardless, so the frozen "must not
claim the route launchable" holds.

**B3 — COMPLETE, and the deviation is sound.** See §4a.

**B4 — PARTIAL.** For the three calls B4 named the fix is complete and better
than the brief asked: one wrapper, the probe runner's own bound
(`afk_probe_timeout_seconds`, 1 s floor, `(ms+999)/1000` — correct arithmetic and
never 0), `GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS`, `SSH_ASKPASS`, `BatchMode=yes`
appended to whatever `GIT_SSH_COMMAND` the caller had, stdout truncated to 4 KiB,
`rc=$?` captured correctly after the command substitution, `124` discriminated as
`TIMEOUT`, everything else as `NONZERO`, and a failure of any kind kept away from
a false "deleted" — the pre-deletion `ls-remote` is what makes the post-deletion
re-observation informative, which is exactly the property P1 shows the terminal
path lacks. A grep of `lib/afk-monitor.sh` finds no bare network call: the other
`git` invocations (`:863`, `:873`, `:877`, `:905`, `:914`, `:926-927`) are all
local-repository operations. But two external calls in the same pass — the Orca
listing and the durable close — go through `afk_probe_run`, which is not strict.
See **P2**. Failure-vs-timeout discrimination is computed and unused (D1).

### 4a. Judgment on the B3 deviation

**Sound, and better than the brief's first choice.** The reasoning the worker
gives is correct and I verified it: a bare reset at the top of
`afk_monitor_summarize` would clear the refusal recorded by
`afk_monitor_register` (`:462`, `:472`) — nothing about a refused descriptor is
written to the watch set, so the post-action reading is clean — and
`monitor --register <bad>` would exit 0 where
`tests/lifecycle-dispatch-tests.sh:347` pins 2, correctly.

The split is safe under the check that matters: **no assignment to
`AFK_MON_NEEDS_HUMAN` survives outside `afk_monitor_summarize`.** Every one of
the 18 action sites goes through `afk_monitor_needs_human` (`:164-167`), which
sets both flags; the only direct assignments (`:1109`, `:1120`, `:1123`,
`:1126`, `:1190`) are inside `summarize` and all execute *after* the reset at
`:1090`. So the reset can erase nothing that a later reading cannot recover.

The derived flag cannot go stale across the two summarize calls, in either
direction: the post-action call re-derives from scratch (`:1090` then the record
loop), so the second reading may disagree with the first — which is the whole
point — and the pass flag is monotone, so nothing the pass could not resolve is
lost. All three unresolved cases the contract names at `:626-628` are pass facts
and keep exit 2: a refused descriptor (`:462`, pinned at test `:347`), a delivery
naming no Dispatch (`:578`, pinned at `:493`), a resource not released (`:1037`,
pinned at `:507`). `afk_evaluate_installation` calls `summarize` on every command
(`lib/afk-commands.sh:102`), so the reset runs on non-monitor commands too — with
no effect, since only `afk_cmd_monitor` consults `afk_monitor_exit_code`.

N8 stays honestly open: `afk_monitor_reset` is still called from no product code.

---

## 5. Anti-vacuity of the new regressions

Checked against the code, not against the record's word.

| Regression | Verdict |
|---|---|
| `ghost` (dispatch `:815-836`) | **Discriminates.** Pre-fix, `ABSENT` returned at the old `:714` before `afk_monitor_terminal_release` was ever called, so `STUB_CLOSED` would not contain `term-ghost` and the ledger assertion (`:821-826`) fails. The other three assertions pass on both trees by design. Blind spot: the stub cannot express a failed close (D4), which is why it cannot see P1. |
| `ghost-control` (`:838-847`) | **Control, correctly labelled.** Passes on both trees; it exists to show the `IDLE` path is unchanged. |
| `stalled-remote` (`:604-628`) | **Discriminates on a host with `timeout(1)`** — pre-fix the pass did not return at all and the elapsed assertion fails. **Vacuous without it** (D2). |
| `answering-remote` (`:633-651`) | **Control, and a real one.** It fails if the lifecycle simply stopped looking at remotes, which is the failure mode the stalled assertion alone could not distinguish. |
| recovery assertions (`:478-484`) | **Discriminate.** The repairing pass is a fresh process; pre-fix its pre-action `afk_evaluate_installation` read the record while `state == "MONITOR_DEGRADED"` and latched, so `RUN_RC` would be 2 and `.dispatch_monitor.state` `NEEDS_HUMAN` over a document whose own `counts.degraded` is 0. `counts.degraded == 0` and the fault sweep pass on both trees, exactly as the record says. |
| flag split (`:124-135`) | **Discriminates.** `assert_eq "a derived verdict does not survive the next reading" … "false"` fails pre-fix, where `summarize` only ever set the flag. Correctly pinned to an empty fixture watch dir (`:119-122`) so it never reads the developer's own state, and the reset at `:1090` precedes the "no watch dir" early return, so the assertion holds for the right reason either way. |
| `targetarity` rows 3, 5, 6b (`readiness :1010-1061`) | **Discriminate.** Pre-fix all three reported `TRUE` with exit 0 because the target leg was skipped, and the trust fact kept its `LIVE_PROBE_NOT_REQUESTED` seed. |
| `targetarity` rows 1, 2, 4 | **Controls.** Row 2 shows an unwired target blocks on its own, so its disappearance in row 3 is a product difference; row 4's `--target target-b` half passes on both trees, as a named-target control. |
| N1 sweeps + controls (`lifecycle-tests :1729-1748`) | **Discriminate.** `. as $r \| select(($pub \| index($r)) == null)` is the correct bind-first form, and each sweep is followed by the same expression over a copy with one injected out-of-set value asserted to report exactly 1 — which reports 0 on the old `index(.)` form, so the control fails pre-fix. jq creates `.readiness.ROUTE_READY` on the adoption document if it is absent, so the second control is well formed. **Whether the two live sweeps themselves come back green is still unknown** — the record flags this as the cycle's only genuinely unknown outcome and I could not run them. |

---

## 6. Contract truthfulness

Every sentence the fix added or rewrote, checked against the code as it stands:

- `:702` Terminal row, `:707-718` the two readings of `ABSENT` — **true**, and the
  `ABSENT` paragraph is a genuine improvement over the two-opposite-readings state
  N14 described.
- `:719-721` "a harmless no-op that **records the intent**" — **not true as
  written**: nothing checks that it did (P1).
- `:650-655` every external observation of the pass is bounded — **not true on a
  host without `timeout(1)`** (P2).
- `:874-887` target arity and the intersection operand — **true** of
  `lib/afk-readiness.sh:1605-1617`.
- `:518-523` `NO_SELECTED_WORKSPACE` — **true** of `:1016-1021` and `:1639-1643`.
- `:621-629` the summary describes the reading it belongs to, and what the pass
  could not resolve is carried across — **true**, and precise about the split.
- `:705` the remote-branch row, including "both the observation before the
  deletion and the re-observation after it completed inside the declared bound" —
  **true**.

Old sentences checked for being made false by the delta: `:1671` (exit 2 covers
"a monitor pass that left something only a human can decide") still true; the
`monitor_states` vocabulary at `:594` still matches; `:729-732` unchanged in truth
value (D7); `:394` `ABSENT` in the checkout-declaration vocabulary is a different
vocabulary and is unaffected; `:421-423` was already in tension with
`afk_probe_run` before this cycle and the delta neither fixed nor worsened it,
except by asserting the opposite at `:650-655`.

---

## 7. The `timeout(1)` dependency disclosure

Confirmed on both halves of the question:

- **The no-timeout path really does report and retain.** `afk_monitor_git_remote`
  (`:376-385`) checks `afk_have timeout` first, emits `PROBE_BOUND_UNAVAILABLE`
  once per run (sharing `AFK_PROBE_UNBOUNDED_REPORTED` with the probe runner, so
  no duplicate finding), returns 1 **without running the call**, and both call
  sites turn that into `NEEDS_OWNER CLEANUP_NEEDS_OWNER`. No deletion, no false
  "deleted".
- **The two section-5 assertions the record names fail loudly, they do not pass
  vacuously.** On a host with no `timeout`, `d-merged`'s `REMOTE_BRANCH_DELETED`
  and `d-unauth`'s `RETAINED` both become `NEEDS_OWNER`, so both assertions fail
  and the gate goes red. They do not *skip* — nothing in the dispatch suite has a
  skip mechanism — but they do not lie either. The genuinely vacuous one is
  `stalled-remote` itself (D2), which the record does not mention.
- The disclosure is incomplete in one respect: it does not say that the same
  missing tool leaves the *Orca* half of the pass unbounded (P2), and
  `afk_require_tools` was not updated (D3).

---

## 8. What I did not get to, plainly

- **I executed nothing.** No gate, no script, no output. Everything above is read
  from the source. The frontmatter gates (`bash tests/lifecycle-tests.sh`,
  `bash tests/run-tests.sh`, `git diff --check`) were **not run by me** — this
  session has Read/Glob/Grep/Write and no shell, and the review-only contract
  forbids me to modify anything in any case. The coordinator's independent run is
  the arbiter. The one gate-adjacent check I could make from here: a regex sweep
  for trailing whitespace across every `*.sh` and `*.md` in the tree returns zero
  matches, which is consistent with `git diff --check` passing, and is not the
  same as having run it.
- **Both attack scripts are unexecuted and were written blind.** If one fails for
  a fixture reason rather than a product reason, the finding it carries still
  stands on the cited source lines, but it is not *reproduced* in the sense the
  blocker bar requires until the script runs. P2's PATH sandbox is the more
  fragile of the two; it exits 2 rather than claiming a reproduction if either
  control misbehaves.
- **I did not re-run or re-derive the four original attack scripts.** I took the
  coordinator's post-fix NOT-REPRODUCED results as given, per the brief.
- **I did not verify the N1 sweeps' live outcome.** Whether the two now-falsifiable
  published-reason sweeps come back green over a real status and adoption document
  is unknowable without running them; it remains the cycle's highest-risk unknown
  and the gates decide it.
- **No shellcheck.** The new `afk_monitor_git_remote` and the readiness edits read
  clean to me (quoting, `local` declarations, `rc=$?` placement), but I could not
  run the linter.
- **Delta scope respected, so:** Story 1.1/1.2 surfaces, the mutation and
  concurrency gates, `tests/lifecycle-tests.sh` outside sections 12-13, rendered
  human output, and an FR-by-FR trace against the frozen PRD were all left alone.
  A regression the delta sneaks under one of those would not have been seen.
- **I did not judge packaging.** The ~4,950-line story total and the split
  suggestion are the worker's flag and stand for the coordinator; I note only that
  both of my blockers live in the dispatch-monitor layer, which is mild further
  evidence for the split the worker proposed.

---

## Dev Agent Record (this review session)

The review-only contract in the story brief forbids modifying any existing file,
including the story file, so this section stands in for a Dev Agent Record entry
there; the coordinator may transcribe it.

- **Session:** fresh reviewer, Read/Glob/Grep/Write, no shell, no Edit.
- **Read:** the story brief; `evidence/AFK-PORT-1.3-FULL-REVIEW.md` (B1-B4 and the
  14-entry register); `evidence/AFK-PORT-1.3-C3.worker-done.md`;
  `AFK-PORT-1.3.md` cycle-3 record and residual registry; `lib/afk-monitor.sh`
  (whole file); `lib/afk-readiness.sh` (probe runner, workspace trust, target
  helpers, route readiness, exit code); `lib/afk-commands.sh` (`afk_cmd_monitor`,
  installation evaluation); `lib/afk-common.sh` (exit vocabulary, result
  assembly, `afk_require_tools`); `bin/agent-flow-kit` option boundary;
  `docs/LIFECYCLE-CONTRACT.md` (dispatch monitor, cleanup, route/target, trust,
  probes, exit codes); the new and amended regressions in all three test suites.
- **Written (new files only):** this report and two attack scripts under
  `evidence/AFK-PORT-1.3-POSTFIX-REVIEW-attack/`.
- **Gates:** not run — no shell in this session; see §8.
- **Verdict:** NOT CLEAN — 2 blockers (P1, P2), 8 non-blocking entries; B2 and B3
  judged complete, B3's deviation judged sound.
