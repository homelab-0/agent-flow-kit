# Agent Flow Kit Portability Traceability

Frozen baseline: 95 FRs · 33 ACs · 12 NFRs

| Requirement range | Story | Implementation artifact | Deterministic test/evidence | Status |
|---|---|---|---|---|
| FR-1–21, FR-24, FR-29–35, FR-72–84, FR-91, FR-93–94 | AFK-PORT-1.1 | `bin/agent-flow-kit`, `lib/afk-{common,source,inventory,commands}.sh`, `lifecycle/kit.json`, `docs/LIFECYCLE-CONTRACT.md` | Routed cycle 3 after two-group adversarial review: `tests/lifecycle-tests.sh`, `tests/run-tests.sh`, `git diff --check` all independently passed | IMPLEMENTED + VERIFIED |
| FR-22–28, FR-36–46, FR-91–94 | AFK-PORT-1.2 | `lib/afk-{plan,mutate}.sh`, `lib/afk-{common,source,inventory,commands}.sh`, `docs/LIFECYCLE-CONTRACT.md` | `tests/lifecycle-mutation-tests.sh` (destructive temp-HOME suite: plan/approval binding, rollback, interruption recovery, idempotence, F1–F8 adversarial regressions, plus `f6window` / `f6contendclean` for the acquisition publication window, `f6vanishrecord` for a record released underneath the read of it, `f6markervanish` for the arbitration marker the winner's rename carried away, and `f6silentreclaim` for a reclamation whose take was lost), `tests/lifecycle-concurrency-tests.sh` (the operation lock under real barrier-synchronized contention, section 10 for the publication window, section 11 for a record seen and then found gone, section 12 for the single-observation discriminator and section 13 for a reclamation that is never silent, and `tests/lifecycle-mutation-tests.sh` section 11 for a lifecycle command interrupted by a signal at four chosen points in and around its transaction, and section 12 for every terminating signal delivered pid-only while a managed write is still in flight), `tests/lifecycle-tests.sh`, `tests/run-tests.sh`, `git diff --check` | IMPLEMENTED — adversarial findings F1–F8 fixed, F6 re-fixed for concurrency, F6-R1 fixed for acquisition guidance, F6-R2 and F6-R3 fixed for the two vanished-record mis-refusals, F6-R4 fixed by judging one observation, F6-R9 fixed so a reclamation is never silent, F6-R10 fixed so a signal never releases the lock while the process can still write, F6-R11 fixed so no terminating signal frees it under a write that is still running; FROZEN — IMPLEMENTED + VERIFIED at superseding freeze `0079ff6` (eleven review rounds; final gates independently green) 
| FR-47–90, FR-95 | AFK-PORT-1.3 | `lib/afk-readiness.sh`, `lib/afk-monitor.sh`, `bin/agent-flow-kit`, `lib/afk-common.sh` | `tests/lifecycle-readiness-tests.sh`, `tests/lifecycle-dispatch-tests.sh`, full composite; converged 2026-08-26 (superseding freeze `7d126fc`), post-freeze triage T1/T2; 1.4 live acceptance layered on top | IMPLEMENTED + VERIFIED |
| AC-1–33 | AFK-PORT-1.4 | retained acceptance bundle (`evidence/INDEX.md`; Mac branch `evidence/afk-port-1.4-mac`) | two real hosts, Git channel, real route/stamp/Orca smoke, durable-watch turn boundary, restart probe, cleanup — 140-item ultracode sweep in `evidence/AFK-PORT-1.4-M5-TRACEABILITY/traceability-sweep.json` | ACCEPTANCE-ONLY + PROVEN (32) / EXPLICITLY BLOCKED (AC-20 natural-route clause) — see Story 1.4 section |
| NFR-1–12 | AFK-PORT-1.1–1.4 | cross-cutting | story gates plus the 1.4 final traceability sweep (12/12 verified) | IMPLEMENTED + VERIFIED |

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

## Story 1.3 — Prove Execution Readiness Without Crossing Authority Boundaries

Converged 2026-08-26 (superseding freeze 7d126fc after one authorized PR-triage round; see the story file) on worktree `afk-port-1.3` (base master `bd9d9fb`), four
cycles + three independent reviews, final verdict CLEAN. Full narrative in the
story file's coordinator freeze record; per-dispatch provenance in
`AFK-PORT-1.3*.route-request/response/stamp.json`; worker_done evidence and
review reports under `evidence/`.

| Finding | Requirement pressure | Fix | Regression |
|---|---|---|---|
| B1 | Frozen worker-terminal cleanup contract — durable close intent must be requested/recorded | `ABSENT` no longer accepted as proof of release; unified `ABSENT\|IDLE\|EXITED` arm requests the durable close before judging | `ghost` + IDLE control (dispatch gate) |
| B2 | Route readiness = intersection incl. compatible BMAD target; workspace-trust NEEDS_HUMAN | Undeterminable target binding fails closed `ROUTE_TARGET_UNRESOLVED`; trust check decoupled from target path; `NO_SELECTED_WORKSPACE` revived | six-row `targetarity` matrix (readiness gate) |
| B3 | `monitor` exit semantics — exit 2 only when something is left for a human | NEEDS_HUMAN latch split into per-pass and derived flags; summary describes the state just read | recovery-pass `RUN_RC`/state assertions |
| B4 | Bounded completion monitor — no unbounded external call | Remote git observations bounded + non-interactive via `afk_monitor_git_remote`; no tool → `PROBE_BOUND_UNAVAILABLE`/`NEEDS_OWNER` | `stalled-remote` + answering control |
| P1 | Same cleanup contract (class remainder of B1) | Durable-close call status consumed for all three states; refused close is `NEEDS_OWNER TERMINAL_RELEASE_UNPROVEN`; stub models refusal | `ghost-refused` + `idle-refused` control |
| P2 | "One bounded pass" + frozen probe-bound rule (class remainder of B4) | Monitor's Orca listing + durable close moved to strict bounding (`afk_monitor_probe_strict`); bounding tool declared on live runs | dispatch-gate section 8 (PATH sandbox, attack + 3 controls) |
| N1 | Gate integrity — published-reason sweeps must be falsifiable | Two vacuous jq sweeps bind-first with executable falsifiability controls | the controls themselves |
| F1 | Contract truthfulness | Cross-reference sentence made true inline (docs lane); readiness-probe bound divergence REGISTERED with R1 evidence, not fixed | lifecycle contract-comparison assertions |

Hardening backlog additions (registered, unscheduled): readiness-probe strict
bounding (R1), durable-close capability gating (F4), F2/F3/F5/F6/F7, D1/D5–D8,
N2–N4/N6/N7/N9–N12, N8 (dead `afk_monitor_reset`), plus the inherited 1.2 set.

Backlog candidate (Josh, 2026-08-27, post-1.4 integration — outside frozen
1.3): a statusline hook (ccstatusline-style) that consumes `agent-flow-kit
status --json` and renders orchestration state inline on both the Claude and
Codex status bars — MODE (PLAN/ORCH/WORKER), phase, task, worker counts, and
loud NEEDS_HUMAN. Pull-side consumer of the 1.3 bridge; introduces no scraper
or control-plane surface. Story 1.4's live-render acceptance condition is the
natural proving ground: a live PLAN-mode render and a populated statusline are
the same demonstration.

## Story 1.5 — Context Budgeting and Continuation (IN PROGRESS; lanes A, B and C merged; D and an external-report fix queued)

Split into four sequential lanes by the coordinator (total scope preserved;
FR coverage: A = FR-96–98 + FR-99 declaration; B = FR-99 evaluation, FR-100,
FR-101, FR-104, FR-105; C = FR-102–103; D = FR-121–126). **Lane A merged**
(PR #30, `c89b302`): window read from the trusted catalog at the stamp's
catalog version, deterministic `bytes4-v1` sizing estimate over persona +
story + prompt + `payload_refs`, thresholds only in
`files/model-router/context-budget-policy.yaml`, fail-closed sizing refusal
before placement (exit 8, `STORY-SIZING:` marker, `reason=SIZING_REFUSED`),
sizing-risk finding in the thin result and the story record (locked,
idempotent per cycle), contract `## The context budget` + `budget_states`.
Review CLEAN with nine residuals; R1–R3, R8 fixed on the branch; R4 (fenced
`## ` inside the record ends the section scan), R5 (policy validated by
shape not value) → backlog items 23–24; R6/R7 accepted. Diff 1080/800
accepted by the owner as one PR. Story 1.5 frontmatter stamp path made
repo-relative (Devin PR #13 note).

**Lane B merged** (PR #32, `6d1315f`): per-harness usage adapters (claude from
the end-of-run envelope with provenance and window corroboration on an exact
key; codex `NOT_EVALUATED`), post-run evaluation against the checkpoint and
continuation thresholds with `HIGH_USAGE`, a launcher-owned prompt paragraph
declaring checkpoint/continuation artifacts and phase boundaries, artifact
validation with freshness by pre-launch sha, `continuation_required` status,
loud `NEEDS_HUMAN` on an invalid signal, no worker free text in any artifact,
and the `context_budget` watch member. Review NOT CLEAN (redaction blocker) →
fix cycle → diff-scoped post-fix review CLEAN. Registry adds: (25) the
pre-existing `NEEDS-HUMAN:` channel echoes worker free text verbatim — apply
the same closed-vocabulary discipline; (26) readiness unpublished-reason sweep
union weakens the `.reason` check; (27) codex terminal tail is bounded
(`--limit 5000`) so a signal can scroll out; (28) GitGuardian flags redaction
test sentinels (incident 37069849 ignored as test credential).

**Lane C merged** (PR #34, `e207314`, 2026-09-08): a continuation runs as the
next cycle of the same story under the same revalidated stamp through the
canonical path; the artifact enters the prompt as data and the sizing
estimate; an expired stamp refuses naming the central refresh; the cap counts
from an append-only ledger (`<story>.continuations.json`) with a typed refusal
whose marker carries the complete remedy (`continuation_decision:` +
`max_cycles:`); retained cycles are never re-run in place; the chain lands in
the story record; `lib/afk-monitor.sh` untouched. Review NOT CLEAN (two cap
blockers) → fix cycle → diff-scoped post-fix review CLEAN. Registry adds:
(29) deleting the ledger resets the count (operator action on state); (30)
a continuation under the cap still meets the untyped `max_cycles`; (31) the
launch guard is not re-checked under the lock; (32) the cap marker's
suggested `max_cycles` can lower a larger existing value — queued in the
external-report fix; (33) EXTERNAL REPORT (ai-control-plane PM, 2026-09-07):
lane B's claude usage adapter divides the envelope's CUMULATIVE token sum by
the window (ratio 20.3 on an 83-turn run; 3.8 on the kit's own 20-turn
smoke) and a ratio-derived state overwrote a gates-failed status — fix
`AFK-PORT-1.5B-FIX2` queued (multi-turn usage informational, status by gates,
continuation only with an artifact, working directory named in the prompt,
cost never spend); (34) owner-approved follow-up: add `Edit` to the frozen
tool set for both claude classes, queued after lane D with a coordinated
contract update in ai-control-plane.

**External-report fix merged** (PR #36, `f9bffe0`, 2026-09-08): the claude
usage adapter divided the envelope's CUMULATIVE token totals by the context
window (ratio 20.3 on an 83-turn run in ai-control-plane; 3.8 on the kit's own
20-turn smoke) and the resulting state overwrote a gates-failed outcome as
`continuation_required` with no artifact. Fixed under the frozen envelope
(option (a)): multi-turn usage is informational (`CUMULATIVE_RUN`, null ratio,
`USAGE_CUMULATIVE_ONLY`), single-turn keeps `FINAL_CONTEXT` and its ratio,
thresholds and `HIGH_USAGE` only from a final-context measurement, gates decide
the status, the prompt names the absolute working directory, cost is never
spend, and the cap marker never lowers `max_cycles`. Reported envelope
committed as `tests/fixtures/claude-result-envelope-multiturn.json`. Registry
adds: (35) removing an Orca worktree while a worker is active in the same
repository destroyed the live worktree and SIGKILLed its agent (~1h of
uncommitted work lost) and dropped the coordinator's Run binding — never
remove a worktree while the repository has a live worker; (36) `Edit` in the
frozen claude tool set is owner-approved and queued after lane D.

## Story 1.7 (Spike) — Persona Payload Viability on Local Profiles (COMPLETE 2026-09-07)

Evidence-only spike, run after Josh's go on the 1.5–1.7 set. Bundle:
`evidence/AFK-PORT-1.7/` (index `INDEX.md`; 27 cells; matrix, persona
payloads, canary gates declared before any run; per-cell machine-readable
results; analysis; recommendations; threshold rule). Per-profile
recommendations by the declared rule applied mechanically:
`local-code-standard` unsuitable (full 1/3, compact 2/3, none 3/3),
`local-general` unsuitable (full 1/3, compact 0/3, none 1/3; same physical
model — variance, cells run once), `claude/strong` full (3/3),
`openai/strong` NOT_EVALUATED (adapter defect; none-mode addendum 3/3). All
local payloads < 4% of the 65,536 window: the result is behavioural, not
capacity. No prohibition recorded; the persona-independence contract stands.
Registry adds: (19) codex prompt positional-argument defect (`---` parsed as
an option); (20) dispatch prompt should state the absolute working directory;
(21) gate-pass-with-NEEDS-HUMAN precedence; (22) workspace-trust stall and
bypassed permissions on supervised interactive launches.

## Story 1.4 — Prove Portability Across Real Orca Hosts (CLOSED 2026-08-29; verdict upgraded to GREEN 2026-09-07)

Full per-requirement verification: `evidence/AFK-PORT-1.4-M5-TRACEABILITY/traceability-sweep.json`
(140 items, produced by a 13-agent independent verification sweep; every mapping
checked against the actual retained artifact, not the story record's claim).
Counts: 107 IMPLEMENTED + VERIFIED · 29 ACCEPTANCE-ONLY + PROVEN ·
1 EXPLICITLY BLOCKED · 3 sweep-time gaps, all three discharged at M5 assembly:

- AC-14-class bundle index: `evidence/INDEX.md` (this assembly).
- AC-21-class stamp-validation retention: launch-moment JSON not retained
  (recorded retention miss); session record + post-hoc validation of the same
  unexpired stamp retained (`AFK-PORT-1.4-M5-TRACEABILITY/smoke-stamp-posthoc-validation.json`).
- AC-31/32/33 closure: this section, the index, and the verdict in
  `AFK-PORT-1.4.md` discharge them.

**EXPLICITLY BLOCKED — one clause.** The smoke's natural valid route
(`{claude, local-code-standard}`) is valid-but-unlaunchable under the frozen
launch adapter (the standard-band routing deadlock, documented since M0), so
the smoke ran on the owner's recorded standing override to the route's own
first fallback. Every other element of that AC (classification, route response,
catalog provenance, entitlement, fallback, accepted decision, stamp, first-time
ROUTE_READY evaluation) is retained and proven. Resolution path: the owner's
out-of-band routing solution; the moment the catalog changes, the natural route
is preferred.

**Registered acceptance conditions (from the 1.3 freeze) — final dispositions:**
composed dispatch live PROVEN; turn-boundary durable completion PROVEN
(worker-committed delivery consumed by `monitor --reconcile` with no
coordinator turn live; replay dropped; corrected-delivery repair exercised);
live status renders captured on claude, codex, and PLAN-mode surfaces
(codex-render session provenance rests on the dispatch record's files-modified
listing — recorded); durable-close-after-reconnect PROVEN at full strength
(deliberate app quit plus a full VM restart; zero of fourteen released worker
terminals resurrected; durable watch records intact); persona-proof
reproducibility SATISFIED on the fresh macOS host with the source sentence
retained; macOS signal numbering OBSERVED (USR1=30→158, USR2=31→159) with the
M5 RULING: the contract's platform-derived arithmetic (`128 +` the signal
number) is authoritative and its prose already carries no platform literal —
the Linux literals live only in the mutation suite and are a recorded
test-harness portability backlog item; workspace-trust disposition RECORDED
(Orca-created worktree paths launched claude workers with no trust prompt;
no trust database touched; evidence: FIX-C1 attempt-4 and smoke worker-start
receipts).

**Caveat / residual / hardening-backlog registry (verdict-bearing):**
1. AC-20 natural-route caveat (above) — the verdict's one qualification.
2. Retention misses (evidence-harness, this story): smoke attempt-2
   worker-side artifacts; launch-moment stamp-validation JSON; the /tmp
   manifest backup (VM restart) — mitigations and surviving proofs listed in
   `evidence/INDEX.md`.
3. Stamp override provenance: `override.original` in override-derived stamps
   is self-referential (make-stamp received the pre-derived response); the
   true natural decision is retained beside each stamp as
   `*.route-response.natural.json` — cross-file chain intact; make-stamp
   usage-pattern backlog item.
4. Readiness validator fixture uses a placeholder digest the stricter
   validator build rejects (real stamp validation unaffected) —
   `evidence/AFK-PORT-1.4-M4-SMOKE/residual-validator-fixture-incompatibility.md`.
5. Devin PR#23 finding: conflicting positive auth classes prefer subscription
   — below blocker bar, dispositioned on the PR, backlog.
6. C1-REVIEW-002: composite gate does not name failing mutation tests —
   backlog (flake classification was reach-based).
7. macOS test-harness portability findings: mutation/concurrency suite
   scenario mechanics fail on Darwin while the kit's lifecycle works
   (adoption/verify proven live); three test files tracked without exec bits;
   trailing-space diff-check findings in retained raw output — backlog.
8. Operational upstream notes: codex mid-turn wedge pattern (2/2 long
   implementation turns), worker-stop/terminal-close false receipts (3×),
   Orca Electron relaunch requires the owner's desktop session, stale
   v1.4.185 daemon zombie, `AFK_ORCA_BIN=orca` default vs GNOME screen
   reader, kit `next_safe_action` loops back to the refusing command on
   ADOPTION_SOURCE_INELIGIBLE.
9. Story-record corrections at M5: the 1.3 preamble-incident pointer
   (`AFK-PORT-1.3-C4.worker-done.md`) was wrong — the incident's source is
   the 1.3 coordinator freeze record; corrected here.

**Superseding verdict (M4R, 2026-09-07): AGENT-FLOW-KIT PORTABILITY GREEN.**
The one clause of the frozen M5 verdict is discharged: with `AFK-PORT-1.4-LV`
merged and applied to the host through the Git channel (applied revision
`8a7cbc1` → `2db1747`, `CONVERGED`), the natural standard-band route
`{claude, local-code-standard}` was accepted as routed (null override), placed
at launch (`kserve-a5000`), validated, launched through the gateway-backed
class, completed (`CLAUDE_EXIT=0`), and passed its frozen gate under
independent re-run (canary sha `8d1ddaae…`). Attempt 1 failed its gate on
executor behaviour (the local model wrote to an invented absolute path and was
refused) and is retained with its diagnosis; attempt 2 ran under pre-declared,
committed scaffolding (gate v3 without the staging requirement; story naming
the relative path) and passed. Full chain and cleanup under
`evidence/AFK-PORT-1.4-M4R/`; the frozen M5 text is unchanged. New registry
items: (15) readiness `claude_capability` probe keys on `claude --help` text
and reports `INCOMPATIBLE` on 2.1.263 because `--append-system-prompt-file`
is no longer listed although it works; (16) readiness `orca_capability` probe
calls an `orca capabilities` verb the current Orca CLI no longer has, so
`HOST_EXECUTION_READY` reports `ORCA_CAPABILITY_UNPROVEN` while launches
succeed — both make the live `ROUTE_READY` evaluation of a valid natural stamp
report `FALSE` for reasons unrelated to the route; (17) batch workers do not
commit a durable completion delivery, so the kit's watch needs a
coordinator-written corrected delivery to settle (mechanism proven here);
(18) the local model's tendency to invent absolute paths outside the worktree
under the least-privilege posture — story scaffolding must name relative
paths explicitly.

**Post-close addition (2026-09-07) — launch variant merged, verdict unchanged.**
`AFK-PORT-1.4-LV` (gateway-backed launch class for local profiles on the
`claude` harness) merged to `master` as `db610fe` (PR #26) under owner-granted
merge authority, with a fresh-session adversarial + senior review, one bounded
fix cycle, and the coordinator's independent gate runs on record
(`AFK-PORT-1.4-LV.md`, `evidence/AFK-PORT-1.4-LV*/`). This removes the
adapter-side half of the one blocking clause: `{claude, local-code-standard}`
is now natively launchable through the validated catalog-1.6.0 gateway path.
The frozen verdict is NOT edited and remains `AGENT-FLOW-KIT PORTABILITY
BLOCKED` until the natural-route smoke re-run records the superseding GREEN
entry; that run is blocked on the gateway credential being reachable from the
executing host. New registry items: (10) `env` argv window is world-readable
absent `hidepid` — interim fleet mitigation `hidepid=2`, contract amendment
(wrapper shell) owed to prox-ops; (11) `x-placement` header value not
shape-checked (defence in depth); (12) launch timeout not shortened for a
launch that printed nothing; (13) `tests/lifecycle-concurrency-tests.sh`
host-timing flake (3 assertions, publication-window rendezvous) reproduced
on pristine `master`; (14) catalog gap: `claude/strong` declares no
`min_context`, so any explicit `context_size` routes away from it.

**Second host:** the Mac is an ADOPTED fleet member (real-home adoption,
owner-approved plan `sha256:9a19ced0…`, preservation byte-identical, offline
verify clean, honest live state). Its future updates ride the proven Git
channel.
