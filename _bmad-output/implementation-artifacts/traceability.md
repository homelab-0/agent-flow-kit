# Agent Flow Kit Portability Traceability

Frozen baseline: 95 FRs · 33 ACs · 12 NFRs

| Requirement range | Story | Implementation artifact | Deterministic test/evidence | Status |
|---|---|---|---|---|
| FR-1–21, FR-24, FR-29–35, FR-72–84, FR-91, FR-93–94 | AFK-PORT-1.1 | `bin/agent-flow-kit`, `lib/afk-{common,source,inventory,commands}.sh`, `lifecycle/kit.json`, `docs/LIFECYCLE-CONTRACT.md` | Routed cycle 3 after two-group adversarial review: `tests/lifecycle-tests.sh`, `tests/run-tests.sh`, `git diff --check` all independently passed | IMPLEMENTED + VERIFIED |
| FR-22–28, FR-36–46, FR-91–94 | AFK-PORT-1.2 | `lib/afk-{plan,mutate}.sh`, `lib/afk-{common,source,inventory,commands}.sh`, `docs/LIFECYCLE-CONTRACT.md` | `tests/lifecycle-mutation-tests.sh` (destructive temp-HOME suite: plan/approval binding, rollback, interruption recovery, idempotence, F1–F8 adversarial regressions, plus `f6window` / `f6contendclean` for the acquisition publication window, `f6vanishrecord` for a record released underneath the read of it, `f6markervanish` for the arbitration marker the winner's rename carried away, and `f6silentreclaim` for a reclamation whose take was lost), `tests/lifecycle-concurrency-tests.sh` (the operation lock under real barrier-synchronized contention, section 10 for the publication window, section 11 for a record seen and then found gone, section 12 for the single-observation discriminator and section 13 for a reclamation that is never silent, and `tests/lifecycle-mutation-tests.sh` section 11 for a lifecycle command interrupted by a signal at four chosen points in and around its transaction, and section 12 for every terminating signal delivered pid-only while a managed write is still in flight), `tests/lifecycle-tests.sh`, `tests/run-tests.sh`, `git diff --check` | IMPLEMENTED — adversarial findings F1–F8 fixed, F6 re-fixed for concurrency, F6-R1 fixed for acquisition guidance, F6-R2 and F6-R3 fixed for the two vanished-record mis-refusals, F6-R4 fixed by judging one observation, F6-R9 fixed so a reclamation is never silent, F6-R10 fixed so a signal never releases the lock while the process can still write, F6-R11 fixed so no terminating signal frees it under a write that is still running; awaiting independent verification |
| FR-47–90, FR-95 | AFK-PORT-1.3 | TBD by worker | readiness matrix; validator anti-vacuity; visibility regression | PLANNED |
| AC-1–33 | AFK-PORT-1.4 | retained acceptance bundle | two-host, Git-channel, real route/stamp/Orca smoke, cleanup | PLANNED |
| NFR-1–12 | AFK-PORT-1.1–1.4 | cross-cutting | story gates plus final traceability audit | PARTIAL — NFR-1, 5, 7, 8, 10, 11, 12 exercised by the Story 1.1 gate |

Final statuses are restricted to IMPLEMENTED + VERIFIED, ACCEPTANCE-ONLY + PROVEN, or EXPLICITLY BLOCKED.

Story 1.1 reached IMPLEMENTED + VERIFIED from the dispatcher's independent gate
results, not from the implementing session's assertion.

## Story 1.2 requirement notes

The eight findings from the independent adversarial review are each pinned by a
named regression in `tests/lifecycle-mutation-tests.sh` section 10. F6 was
re-opened by a later review as a concurrency finding — the single-process
diagnosis was right, the multi-process behaviour was not — and now carries its
own gate, `tests/lifecycle-concurrency-tests.sh`, which drives several real
processes onto one lock behind a barrier. A second independent review then
confirmed one further finding against that fix, F6-R1, in the **acquisition**
path rather than in the reclaim or release paths the cycle-4 fix rewrote. A
third review then established that F6-R1 was one site of a *class* — a record
observed to exist and then found gone being read as a permanent diagnosis
rather than a moment — and confirmed the two remaining sites, F6-R2 and F6-R3.
A fourth review confirmed that the F6-R3 repair had reintroduced the same harm
through a non-atomic discriminator (F6-R4) and that a pre-existing hole made
`run-tests.sh` red: a reclaimer that loses the take it earned destroys an
abandoned lock silently (F6-R9). Both are fixed in cycle 7; F6-R5 through F6-R8
are recorded as non-blocking residuals below.

A fifth independent review (cycle 8, `AFK-PORT-1.2-F6-R4R9-POSTFIX-REVIEW`,
2026-08-25) attacked the cycle-7 fixes from a fresh session and returned
**CLEAN: zero Story 1.2-owned blockers**. Both fixes held; the reviewer rebuilt
the two prior attack scripts that had gone vacuous against the fixed tree
(A4c hooking the read that now exists, A9d proving 15/15 exactly-once
reclamation versus 15/15 silent destruction reverted), confirmed exactly-once
reporting at 8-way contention and on all three CLI exits including the
interrupted-journal recovery exit, re-swept the observe-then-act class (no new
member introduced; one remaining member, S1, forced and shown to fail closed),
and reran every gate: lifecycle 443/0, concurrency 207/0 ×3, mutation 414/0 on
5-of-5 loaded runs plus 30 parallel load suites, run-tests 231/0 with the
shellcheck sub-gate proven to genuinely execute (six negative probes all fail
closed), `git diff --check` clean, and exact per-fix anti-vacuity
discrimination. Seven non-blockers and three method findings are recorded in
`evidence/AFK-PORT-1.2-F6-R4R9-POSTFIX-REVIEW.worker-done.md` and the full
report beside it — among them: the cycle-7 justification for leaving F6-R5
undone is refuted (a DEBUG trap is a deterministic interleaving point between
the two builtins) though the finding remains non-blocking at 0 occurrences in
100,000 natural observations, and the R9 mutation-gate discrimination floor is
410/4 rather than 409/5.

An external PR review then found a sixth finding against the frozen revision
itself, F6-R10, in a place none of the five reviews had attacked: not the lock
protocol but the trap that drives it. `trap 'afk_lock_release' EXIT INT TERM`
runs the handler and **resumes** the script on INT or TERM, so an interrupted
run released the lock and kept writing — a live owner holding nothing, with the
freed path open to a second writer. Every prior cycle had reasoned about a
process that died holding the lock; this is the opposite case. It is fixed in
cycle 9, with the section-11 regressions and the pre-fix reconstruction
recorded in the story file. The freeze below therefore describes commit
`94f81b8`, not the current tree.

The independent post-fix review of cycle 9 then found a seventh, F6-R11, in the
same trap wiring from the other side. Cycle 9 answered the signals it handled;
it left every terminating signal it did **not** handle — `SIGHUP` first among
them, reachable through any supervisor or `pkill` that signals the main pid —
to bash's default, which runs the `EXIT` trap and dies at once. The lock came
back at the instant the shell died, while the `cp` it had started was still
copying, and a contender took the installation from under it. Cycle 10 traps
the set and pins it with section 12, and corrects two contract sentences the
cycle 9 fix had made false.

**Story 1.2 FROZEN — IMPLEMENTED + VERIFIED** (PM declaration, 2026-08-25,
on the cycle-8 CLEAN verdict with all required gates green). Every fix/review
cycle ran as a fresh, centrally-routed, stamped, validated, Orca-supervised
session; no implementer reviewed its own work. Story 1.3 was not started.

**Frozen revision:** commit `94f81b8af56b40a489b32c647a22f9fbee75f16c`
(branch `story/afk-port-1.2`, local only — not pushed pending the packaging
decision). This is the tree the cycle-8 review verified, committed verbatim.

**Freeze superseded:** the `94f81b8` freeze is superseded by
`0079ff6034efdcb94f0c6b030145c09404ea20b6` after F6-R10 and F6-R11 (history
retained). External PR review found the INT/TERM trap released the lock and
resumed (F6-R10, cycle 9); the F6-R10 post-fix review measured that an
untrapped HUP fires the EXIT trap immediately under a live child (F6-R11,
cycle 10, authorized by Josh as one bounded cycle). Both fixed, each verified
by an independent review; the diff-scoped F6-R11 review verified the remedy,
anti-vacuity, and all gates, with one documentation-truth finding (the
corrected release sentence overstated "at exit, and at no earlier moment")
resolved by a PM prose correction under the pre-authorized docs/record-only
lane, validated by lifecycle 443/0, concurrency 207/0, shellcheck clean, and
the full aggregate gate. Two further report-only items joined the hardening
backlog: the whole-set signal disarm has no dedicated multi-signal regression,
and the mutation suite's skip() is invisible in the summary count. The macOS
signal-numbering contract nuance (USR1/USR2 report 138/140 on Linux, would be
158/159 on macOS) is registered in the Story 1.4 scope notes.

| Finding | Requirement pressure | Fix | Regression |
|---|---|---|---|
| F1 (critical) | FR-41, FR-42, FR-45, NFR-2 — "restoration is verified", "rolls back deterministically or stops with `NEEDS_OWNER`" | The recovery journal is evidence, never destructive authority. A recorded step is acted on only when the component is declared, the destination is the declared one, the journal agrees with itself, the guard passes, the backup directory resolves inside the declared backup root, and either a stored copy exists or the bound `observed_identity: null` matches that exact component and `INSTALL` binding. Journal schema bumped to `2.0` and other majors are refused. | F1a–F1g |
| F2 | FR-43, FR-44 — "the last successfully applied revision remains unchanged" | `applied_revision` advances only after the manifest commit succeeds; the attempted revision is reported separately as `target_revision`. | F2 |
| F3 | FR-44 + the contract's 40-hex `applied_revision` | The revision shape is a precondition checked in `afk_source_evaluate`, before any plan is authorized, with its own `SOURCE_REVISION_FORMAT_UNSUPPORTED` reason. | F3 |
| F4 | FR-37 — user-owned content is preserved | Managed writes replay the destination's mode (and ownership where permitted) onto the replacement before the atomic rename, and prove it afterwards; kit state files are written private to their owner. | F4 |
| F5 | FR-91 — the binding is the falsifiable half of the plan | One observation pass, cached, replayed into the plan loop, so the plan and the binding are one statement about one moment. | F5 |
| F6 | FR-92 — overlapping operations prevented, never interleaved | The lock carries host, boot, pid and process-start identity **plus an incarnation unique to the acquisition**. Live owner blocks; provably dead owner is reclaimed and reported; foreign, incomplete, unknown-schema, incarnation-less or unjudgeable fails closed with `OPERATION_LOCK_OWNER_UNVERIFIABLE` and truthful guidance. Reclamation is single-winner: an observer must win a `link`-claimed arbitration marker named for the exact incarnation it judged, re-prove the judgement under it, and prove after the rename-aside that what it moved is that incarnation — so a stale observation never removes a successor. Release removes only the exact incarnation the process installed. | F6 (dead / live / unknown / foreign), F6 concurrency (`tests/lifecycle-concurrency-tests.sh`, plus `f6contend2` / `f6contend4` / `f6contendlive` in the mutation gate) |
| F6-R1 | FR-92 + the contract's exhaustive enumeration of when each lock refusal applies | Taking a lock is two steps — `mkdir`, then the owner record — and a contender that observed the gap was refused with `OPERATION_LOCK_OWNER_UNVERIFIABLE`, whose owner action is "remove the lock by hand": untrue guidance that, if followed, deletes a live owner's lock. A lock carrying **no record at all** is now waited on boundedly (a budget spent across the whole acquisition, ~3s) and judged again; every other unjudgeable record is still refused at once, and a lock that never publishes still fails closed with a detail saying the record never appeared. A vanished lock and a `NONE` observation are likewise re-observed inside the same bounded loop instead of producing an untrue refusal. | `tests/lifecycle-concurrency-tests.sh` section 10 (a window held open with `publish-slowly` / `acquire-announced`; an ownerless window; a settled owner costing no wait; twelve contenders on a clean lock path) and the wait accounting added to all twelve `fail_closed_case` records; `f6window` and `f6contendclean` in the mutation gate |
| F6-R2 | FR-92 + the module's own invariant that a loser never touches the lock | The arbitration marker lives inside the lock directory, so the winning reclaimer's rename carries it away. A loser judging a marker that was already gone got `UNKNOWN`, fell into `afk_lock_reclaim`'s fail-closed arm and returned `2`, which the acquisition turned into `OPERATION_LOCK_OWNER_UNVERIFIABLE` and "remove the lock by hand" — while the successor held it (12 of 256 real `update` runs, 4.7%). A marker that is **gone** now returns `3` ("the situation moved — observe again"), which is what `afk_lock_marker_claim` already returns for the same state one instant earlier; a marker that is present and unjudgeable still returns `2`, instantly and with no wait. | `tests/lifecycle-concurrency-tests.sh` section 11: a real losing claim held still by `reclaim-marker-interleaved` / `acquire-marker-interleaved` while the lock directory is renamed away, at protocol level and through a whole acquisition with a live successor parked on the lock; plus a present-and-unreadable marker still failing closed at `publish_waits=0` |
| F6-R3 | FR-92 + the contract's enumeration of when each lock refusal applies | The owner record can be released or reclaimed between `[[ -f "$rec" ]]` and `jq` opening it. A read of a file that is gone yields nothing, which is what a malformed record yields, and the judge reported "the lock owner record could not be parsed" — refused at once with the same remove-by-hand guidance. `afk_state_file_write` installs a record by renaming one complete temporary file, so a torn record is not observable and a parse failure during a race can only mean the record was gone. The judge now re-tests the record after an empty read: gone is `$AFK_LOCK_NO_RECORD_DETAIL`, which the acquisition waits out; still there is still a diagnosis. | `tests/lifecycle-concurrency-tests.sh` section 11 (a `jq` ahead of the real one performs the release underneath exactly one read, at judge level and acquisition level) and `f6vanishrecord` in the mutation gate (the same instant through a real `agent-flow-kit update` on the recovery path, asserting no `OPERATION_LOCK_OWNER_UNVERIFIABLE` and no "remove" guidance) |
| F6-R4 | FR-92 + the contract's enumeration of when each lock refusal applies | The F6-R3 repair told "gone" from "damaged" with a **second** stat after the failed read, and two looks are two instants: a successor that took the freed path and published a valid record between them had that record reported as one that "could not be parsed" — `OPERATION_LOCK_OWNER_UNVERIFIABLE` and "remove the lock by hand" while a live owner held it (deterministic repro, plus 6 false verdicts and 0 true ones in 40 000 adversarial observations). The record is now read **once** and judged on the bytes that read returned: no bytes is the no-record moment, bytes that do not parse are the diagnosis. The only remaining pre-read test is a not-a-plain-file guard, whose race can produce the moment but never a diagnosis. | `tests/lifecycle-concurrency-tests.sh` section 12: a reader ahead of the real one performs the release and parks a REAL successor that publishes into the same name before the judge decides, at judge level and through a whole acquisition (which must report the LIVE successor, never "remove it"), plus a genuinely damaged record still refused at once at `publish_waits=0` |
| F6-R9 | FR-92 + `docs/LIFECYCLE-CONTRACT.md` "the reclamation is reported as `OPERATION_LOCK_RECLAIMED`" and `lib/afk-commands.sh` "reclaiming a lock is never silent" | `AFK_LOCK_RECLAIMED` was set by the **acquisition** on success, so a reclaimer that won the arbitration marker, proved the abandoned incarnation, renamed the lock aside and removed it — and then lost the `mkdir` to a contender — returned 3 and reported nothing, while the contender that took the freed path had reclaimed nothing and reported nothing either. An abandoned lock was destroyed and nobody said so (`f6contend4` failed 2 runs in 5 under load: 229/1 in `run-tests.sh`). The reclamation now reports itself where it happens — one line recorded per destroyed lock at the moment the destruction is proven — and `afk_lock_refusal` emits it too, so a run that reclaimed and then refused still reports the reclamation. | `tests/lifecycle-concurrency-tests.sh` section 13 (`reclaim-losing-take`: the real `afk_lock_take` runs and loses to a contender that took the path first; the destruction is still reported exactly once) and `f6silentreclaim` in the mutation gate (a real `agent-flow-kit update` loses the take through an external interposition on the aside record and still emits exactly one `OPERATION_LOCK_RECLAIMED` alongside its refusal) |
| F6-R10 | FR-92 + `docs/LIFECYCLE-CONTRACT.md` "at most one process owns the lock at any instant" | `bin/agent-flow-kit` wired release as `trap 'afk_lock_release' EXIT INT TERM`. A handler on INT or TERM that does not exit does not end anything — bash runs it and **resumes** the script — so a signal delivered mid-transaction released the lock and the same process went on writing, and the next `agent-flow-kit update` could take the freed path and mutate the same installation alongside it. Every earlier F6 finding was about a process that DIED holding the lock; this is the owner that lives on without it. Release now belongs to EXIT alone; INT and TERM have their own handlers that stop taking signals and exit `128 +` the signal number, which runs the EXIT trap — so the lock comes back at the one moment this process can no longer write, the run terminates through its own cleanup instead of continuing unlocked, and the journal is still left visible for recovery. | `tests/lifecycle-mutation-tests.sh` section 11 (61 assertions): R10a/R10b deliver TERM and INT inside the write phase through an interposer that parks the run on a real `cp`, park it a second time on the next call — reachable only by a resumed handler — and at that instant read the lock path and run a second real `update`; R10c signals before acquisition, R10d after the commit while the lock is still held, R10e after the ordinary release with a live successor's lock planted in the path. Anti-vacuity: on a reconstruction of the pre-fix trap wiring the section fails every run, with the second writer acquiring alongside the first and the installation left `UNRECOVERABLE`. |
| F6-R11 | FR-92 + `docs/LIFECYCLE-CONTRACT.md` "at most one process owns the lock at any instant" | Cycle 9 gave `INT` and `TERM` handlers that terminate, and left every other terminating signal untrapped. An untrapped fatal signal does not wait for the command bash is running: bash runs the `EXIT` trap — which is the release — and dies immediately, so the lock came back while the `cp` staging a managed tree was still running, and a second real `agent-flow-kit update` acquired it and rolled the installation back under the live write. `SIGHUP` is the reachable one (`kill -HUP <pid>`, `pkill -HUP`, a supervisor signalling the main pid); a process-group hangup is benign because the writer dies too, so only the pid-only shape exposes it. Every signal that terminates this process by default and can be delivered to it alone is now trapped — `HUP`, `USR1`, `USR2`, `ALRM`, `PIPE` alongside `INT` and `TERM` — because a trapped signal is deferred until the running command returns, so the exit, and therefore the release, cannot happen while a child of this process can still write. `SIGQUIT` is deliberately excluded: bash ignores it, so trapping it would newly kill runs that complete today. | `tests/lifecycle-mutation-tests.sh` section 12 (102 assertions): R11a–R11e deliver `HUP`/`USR1`/`USR2`/`ALRM`/`PIPE` pid-only inside the write phase and read the lock, the writer's liveness and a real contender **while the writer is still parked**; R11f delivers `QUIT` and asserts the run survives and converges, so adding a `QUIT` handler fails a gate. Anti-vacuity: with the five traps removed from the otherwise-fixed tree the section fails 40 assertions on every run, with the contender reporting `OPERATION_RECOVERED` against a writer that had not finished. |
| F7 | FR-91 | `afk_plan_revalidate` re-runs `afk_evaluate_journal`, so `journal_state` can actually falsify. | F7 |
| F8 | FR-41 | The journal is opened `PREPARING` naming its backup directory before that directory is filled, and housekeeping sweeps recovery material no journal names. | F8 |

Vocabulary added and published in all three places (`schema`, the contract
document's machine-checkable block, and the message/action tables):
`SOURCE_REVISION_FORMAT_UNSUPPORTED`, `OPERATION_JOURNAL_SCHEMA_UNSUPPORTED`,
`OPERATION_RECOVERY_AUTHORITY_INSUFFICIENT`,
`OPERATION_RECOVERY_VERIFICATION_FAILED`, `OPERATION_LOCK_OWNER_UNVERIFIABLE`,
`OPERATION_LOCK_RECLAIMED`, `DESTINATION_METADATA_NOT_PRESERVED`, plus the
`PREPARING` journal state.

## Story 1.1 requirement notes

- **FR-19 / FR-21 scoping.** A non-critical component's drift is a warning scoped to
  `MUTATION:<component>`; it refuses overwrite without making the host `NOT_READY`.
  Execution-critical drift is `owner_action` scoped to `INSTALLED_INTEGRITY`.
- **FR-35 independence.** Source findings never carry `INSTALLED_INTEGRITY`, so an
  ineligible checkout cannot move installed readiness. Proven directly by the
  "dirty" scenario.
- **FR-33 schema handling.** Newer major → refuse (`NEEDS_OWNER`); recognized older
  major → usable with `STATE_SCHEMA_MIGRATION_REQUIRED`; unparseable or shapeless →
  `STATE_SCHEMA_UNRECOGNIZED` (`NEEDS_OWNER`).
- **FR-84 offline default.** Every live fact reports `NOT_EVALUATED` /
  `LIVE_PROBE_NOT_REQUESTED`, proven by stubbing every external binary and asserting
  none was invoked. `ROUTE_READY` is `OUT_OF_SCOPE` instead, keeping the four-way
  distinction in FR-73 observable.
- **FR-91 (plan binding) is only partially in scope here.** Story 1.1 has no mutation
  plan to bind; what it contributes is the bound evidence set (expected/observed
  identities, ownership, adaptation records) the Story 1.2 plan will bind to and
  revalidate.
