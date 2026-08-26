---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-PORT-1.2.md.stamp.json
persona: dev
gates:
  - "bash tests/lifecycle-tests.sh"
  - "bash tests/run-tests.sh"
  - "git diff --check"
max_cycles: 3
---

### Story 1.2: Converge Managed State Without Losing Local Work

As an agent-flow-kit fleet operator,
I want adoption and update to converge managed artifacts transactionally while preserving declared local ownership,
So that I can maintain a host unattended when safe and receive an actionable refusal when owner judgment is required.

**Acceptance Criteria:**

**Given** any mutating lifecycle request
**When** adoption or update begins
**Then** the lifecycle computes the complete deterministic plan before its first managed write
**And** the plan covers every component, ownership class, source and destination identity, adaptation, conflict, permission prerequisite, migration, backup, recovery action, and expected final state.

**Given** a computed plan bound to source revision, source artifact identities, destination identities, manifest/applied state, adaptation records, and ownership/path observations
**When** execution reaches the mutation boundary
**Then** all bound inputs are revalidated immediately before the first managed write
**And** any material change makes the plan stale and stops execution without silently recomputing under an earlier approval.

**Given** a multi-component mutation has begun
**When** a safety-critical component prerequisite could have changed
**Then** path containment, symlink resolution, expected destination identity, and other relevant guards are revalidated immediately before that component's write
**And** a mismatch stops the transaction and triggers rollback of prior managed/user-state mutations where deterministic.

**Given** multiple mutation requests for the same installation
**When** they overlap
**Then** they are prevented or deterministically serialized
**And** read-only status does not report an in-progress installation as stably healthy.

**Given** a legacy installation classified by Story 1.1
**When** adoption is mechanically proven and non-destructive
**Then** it may auto-adopt and converge without interactive approval
**And** durable ownership and applied revision are recorded only after complete reconciliation and offline verification.

**Given** legacy content that crosses an ambiguity or ownership boundary
**When** adoption is requested
**Then** the lifecycle emits a deterministic plan with a stable identity/digest covering current state, proposed ownership, modifications, preserved content, recovery protection, and resulting state
**And** owner approval authorizes only that exact unchanged plan.

**Given** an approved adoption plan
**When** any authority-relevant input changes
**Then** the approval is invalidated and does not transfer to a recomputed plan
**And** the lifecycle requires fresh approval rather than silently regenerating and continuing.

**Given** adoption cannot distinguish ownership, preserve content, avoid credentials, maintain security/spend/routing boundaries, or recover a destructive shared-file change
**When** preflight evaluates it
**Then** the operation refuses with `NEEDS_OWNER` and performs no mutation.

**Given** an adopted host and eligible canonical checkout
**When** update runs
**Then** recognized managed copies and sections converge deterministically
**And** Git fetching, pulling, branch switching, route selection, orchestration activation, and external-authority mutation remain outside the operation.

**Given** a managed copy or managed section matching its recognized applied state
**When** canonical content advances compatibly
**Then** the lifecycle replaces only kit-owned content
**And** preserves machine-local configuration, target-project content, and content outside managed sections according to declared ownership.

**Given** content outside a managed section
**When** the managed section is upgraded
**Then** outside content is preserved byte-for-byte under the documented contract
**And** tests include leading/trailing content, missing final newline, supported line endings, duplicate or malformed markers, and boundary cases.

**Given** a managed component with unexplained drift, malformed markers, path redirection, or a stale adaptation record
**When** adoption or update is requested
**Then** replacement is blocked before the affected write
**And** free-form or LLM conflict merging is never attempted.

**Given** an explicitly registered adaptation
**When** update preflight runs
**Then** its component, location, expected shape, and disposition are revalidated
**And** the operation preserves, reevaluates, or requires owner review exactly as declared.

**Given** a mutation is ready to execute
**When** its first write occurs
**Then** a secret-free recovery journal and required backups already exist
**And** the journal identifies the operation, prior and target revisions, immutable plan identity, pre-mutation evidence, and completed steps as execution advances.

**Given** a lifecycle-managed write fails
**When** deterministic restoration is possible
**Then** all managed installation and user state changed by the attempted convergence is restored and restoration is verified
**And** the last successfully applied revision remains unchanged while secret-free diagnostic evidence may be retained.

**Given** restoration cannot complete or a non-transactional effect cannot be reversed
**When** failure handling completes
**Then** the installation reports `BROKEN` or `NEEDS_OWNER` with exact component evidence and recovery guidance
**And** partial state is never reported as successful convergence.

**Given** all planned mutations complete
**When** final local verification runs
**Then** every resulting managed copy, managed section, adaptation, target wiring structure, manifest invariant, lifecycle schema, and applied hash is checked without router, native-auth, Orca-worker, route, stamp, or other live-service dependency
**And** the applied-state manifest becomes the final durable authority transition only after verification succeeds.

**Given** the applied-state manifest has committed the target revision
**When** transaction housekeeping runs
**Then** the journal may be marked committed and temporary recovery metadata may be cleaned
**And** housekeeping cannot alter the meaning of the committed installation state.

**Given** an operation is interrupted before authority commit
**When** the next lifecycle command runs
**Then** it detects the incomplete journal before any new mutation
**And** deterministically rolls back when possible or stops with `NEEDS_OWNER`; resumable transactions are not required.

**Given** an unchanged installation already at the eligible revision
**When** update runs again
**Then** the plan contains no required mutation, hashes and applied revision remain unchanged, and the filesystem experiences no churn.

**Given** verification is requested after adoption or update
**When** Story 1.2 offline verify runs
**Then** it observes and proves installed-state integrity without repairing, probing live services, or activating orchestration
**And** live execution readiness remains for Story 1.3.

**Given** Story 1.2 destructive-path gates
**When** they run in isolated temporary homes
**Then** they cover managed-section insertion and upgrade, outside-content preservation, legacy transformations, immutable approval-plan invalidation, drift refusal, adaptation revalidation, symlink attack, concurrent mutation, backup/rollback, injected mid-operation failure, interrupted-operation recovery, false-applied-revision prevention, and idempotent no-op behavior
**And** no representative real-user state is touched.

**Requirements covered:** FR-22–28, FR-36–46, FR-91–94; AC-7–12, AC-28–30; NFR-1–10 and NFR-12.

## Implementation Constraints

- Frozen PRD: _bmad-output/planning-artifacts/prds/prd-agent-flow-kit-2026-08-24/prd.md
- PR #5 is a donor/reference only; use reconcile-pr5.md as the migration map.
- Work from canonical master in this fresh story worktree.
- Do not broaden into router, catalog, prox-ops, Kubernetes, GPU, or control-plane product work.
- Do not weaken a frozen requirement to fit donor code or a bounded retry cycle.

## Dev Agent Record

### Story status — FROZEN (PM declaration, 2026-08-25)

**Story 1.2 FROZEN — IMPLEMENTED + VERIFIED.** The cycle-8 independent
adversarial review (`AFK-PORT-1.2-F6-R4R9-POSTFIX-REVIEW`, a fresh session
distinct from every implementer and prior reviewer) returned CLEAN — zero
Story 1.2-owned blockers — with all required gates green under its own rerun:
lifecycle 443/0, concurrency 207/0 ×3, mutation 414/0 on 5-of-5 loaded runs
(plus 30 parallel load suites), run-tests 231/0 with the shellcheck sub-gate
proven to genuinely execute, `git diff --check` clean, and exact per-fix
anti-vacuity discrimination. Verdict evidence:
`evidence/AFK-PORT-1.2-F6-R4R9-POSTFIX-REVIEW.worker-done.md` (full report and
raw attack/gate material beside it). Seven non-blocking residuals and three
method findings are documented there; none blocks the freeze. Story 1.3 was
not started.

**Frozen revision:** commit `94f81b8af56b40a489b32c647a22f9fbee75f16c`
(branch `story/afk-port-1.2`, local only — not pushed pending the packaging
decision).

**Freeze superseded:** `94f81b8` is superseded by
`0079ff6034efdcb94f0c6b030145c09404ea20b6` after F6-R10 (signal-handler lock
release, cycle 9) and F6-R11 (untrapped-HUP immediate EXIT-trap release, cycle
10) — both independently reviewed; see traceability.md for the full record.
History retained.

**Superseded by cycle 9 (2026-08-25).** An external PR review found a blocker
in that frozen revision — F6-R10, the signal handler that released the
operation lock and let the interrupted process carry on writing — and the PM
confirmed it against the tree. Cycle 9 below fixes it and pins it with
regressions. The working tree is therefore no longer the commit this block
describes, and whether the freeze is restored is the PM's decision after
independent review; nothing in cycle 9 decides it. Everything above records
what was true at `94f81b8`.

**And by cycle 10 (2026-08-25).** The independent post-fix review of cycle 9
returned NOT CLEAN with one blocker — F6-R11, the terminating signals cycle 9
left untrapped, which hand the lock back at the instant the shell dies while
the write it started is still running. The PM authorised one bounded cycle for
it. Cycle 10 is the current state of the working tree; cycle 9's description
below is what was true before it.

### Cycle 10 — F6-R11 (the terminating signals that were never trapped)

- Status: **cycle 10 implemented, not frozen.** Scope was the single blocker
  the F6-R10 post-fix review returned, authorised by the PM as one bounded
  cycle. Whether this restores the freeze is the PM's call after independent
  diff-scoped review; nothing here declares it. Story 1.3 was not started.

**F6-R11 — an untrapped terminating signal frees the lock under a live write.**
`bin/agent-flow-kit`, the trap wiring again, from the other side. Cycle 9 fixed
the case where the process **handles** a signal and carries on writing. It left
the case where the process handles nothing. An untrapped fatal signal does not
wait for the command bash is running: bash runs the `EXIT` trap — which is the
release — and then dies at once. The command it was running is a real write,
and that child is still alive and still copying when the lock comes back. A
contender arriving in that window takes the installation from under a write
that has not finished. Two owners, one installation, with the first one's write
still in flight — the same FR-92 violation cycle 9 closed, reached through the
door cycle 9 left open.

`SIGHUP` is the one that is naturally reachable: `kill -HUP <pid>`, `pkill
-HUP`, a supervisor signalling the main pid. The delivery **shape** is the
whole of it — a terminal hangup signals the process *group*, which kills the
writer along with the shell and is benign; only the pid-only shape reaches the
shell alone and leaves the writer running.

Fixed by extending the same idiom to every signal that terminates this process
by default and can be delivered to it alone:

```
AFK_TRAPPED_SIGNALS=(INT TERM HUP USR1 USR2 ALRM PIPE)

trap 'afk_release_on_exit' EXIT
trap 'afk_terminate_on_signal 130' INT
trap 'afk_terminate_on_signal 143' TERM
trap 'afk_terminate_on_signal 129' HUP
trap 'afk_terminate_on_signal 138' USR1
trap 'afk_terminate_on_signal 140' USR2
trap 'afk_terminate_on_signal 142' ALRM
trap 'afk_terminate_on_signal 141' PIPE
```

Trapping is what closes the hole: a trapped signal is **deferred** until the
running command returns, so the exit — and therefore the release — cannot
happen while a child of this process can still write. Both handlers now disarm
the whole set rather than `INT TERM` alone, so a second signal of any kind
cannot re-enter a cleanup already under way and leave the release half-done.
Nothing in `lib/` was touched, and nothing else in `bin/agent-flow-kit` moved.

**Per-signal decision, and why each one.** The measured behaviour was verified
independently of the review that reported it, against a real `agent-flow-kit
update` parked mid-write with the writer still running:

| signal | untrapped behaviour | decision |
|---|---|---|
| `HUP` | shell dies at once, `EXIT` releases, contender **acquires alongside the live writer**, rc 129 | **trapped** — naturally reachable (supervisor, `pkill`, operator with the pid) |
| `USR1` | same, rc 138 | trapped — not reachable through any convention this tool takes part in, but free, and an invariant stated as "no terminating signal frees the lock under a live writer" should not have holes an auditor has to re-derive |
| `USR2` | same, rc 140 | trapped — same reason |
| `ALRM` | same, rc 142 | trapped — same reason; nothing in the tool sets an alarm |
| `PIPE` | same, rc 141 | trapped — a deliberate decision, not a freebie; see below |
| `QUIT` | shell **survives**, the run continues and completes, rc 0 | **deliberately NOT trapped** — see below |

**`SIGQUIT` is the trap in this task.** Bash ignores `SIGQUIT` outright, so
`Ctrl-\` during a transaction interrupts nothing today: the run carries on and
finishes. This was re-measured here rather than taken on trust, because the
obvious way to measure it — a background job — also inherits an ignored
`SIGQUIT` and would have produced the same answer for the wrong reason. With
the disposition explicitly reset to default in a fresh session, the shell still
survived and still exited 0. Adding a `QUIT` handler would therefore newly
**kill** runs that succeed today: an availability regression bought for no
safety at all, since a signal that never reaches the shell can never free the
lock. It is left alone on purpose, and R11f below fails the gate if anyone
adds it as a tidy-up.

**`SIGPIPE` was decided, not assumed.** It is proven *not* naturally reachable
while the lock is held: between `afk_lock_acquire` and `afk_lock_release` no
byte reaches stdout or stderr — the transaction's own `printf`s are captured in
command substitutions, `lib/afk-mutate.sh` contains no `afk_warn` and no `>&2`
at all, and the only stdout write is the final emit, after the release. It is
trapped anyway, for two reasons and against one cost. The reasons: that
non-reachability is a property of code in `lib/`, which this file does not own
and cannot enforce — one warning added inside a future transaction reopens it
silently; and an invariant with a documented exception is one a later reviewer
must re-derive. The cost: at the one point `SIGPIPE` really can fire — the
final emit into a closed pipe, `agent-flow-kit update --json | head -1` — a
silent signal death becomes a handler exit. It is the same `141` to any caller
reading `$?`, the lock is already released by then so the handler's release is
the idempotent no-op, and only a caller inspecting `WIFSIGNALED` could tell the
difference. That trade was taken knowingly.

**Contract truth — the two false sentences.** `docs/LIFECYCLE-CONTRACT.md`:

- **Transaction step 2** said the lock "is given back when the owning process
  exits and never while that process can still write". Pid-only `SIGHUP`
  falsified it; the trap makes it true, and the clause is now explicit that the
  bar covers a write the process *started* as well as the process itself.
- **The release paragraph** said "Neither path leaves an installation
  permanently busy", which was false for both named paths. A signal — or
  `SIGKILL` — inside the lock **publication window**, after the lock directory
  appears and before the owner record appears inside it, leaves a recordless
  lock that is unjudgeable rather than dead: it is never reclaimed, and every
  later mutating command refuses `OPERATION_LOCK_OWNER_UNVERIFIABLE` until an
  operator removes the directory by hand. The mechanism is **not** fixed here
  (that is B1, registered below); the sentence is. It now says what is actually
  true, names the exception, and names the remedy the tool itself reports. The
  same paragraph's signal list was widened from `SIGINT`/`SIGTERM` to the set
  the code actually traps, with `SIGQUIT`'s absence stated as a decision.
- **The exit-code section** carried the same under-statement the cycle 9 fix
  introduced — "a run stopped by `SIGINT` or `SIGTERM` … 130 and 143" — which
  after this change describes two of seven signals. It now says `128 +` the
  signal number for the whole set and names 130, 143 and 129 as the examples.
  Not one of the two reported sentences, but the same sentence made stale by
  this fix, and a contract has to be true as written.

The machine-checkable `exit_codes` block is untouched: 129/138/140/141/142 are
not result codes, exactly as 130 and 143 are not.

**Regressions — `tests/lifecycle-mutation-tests.sh` section 12.** Same
interposer machinery as section 11, and the same `sig_launch`, which already
produces the pid-only delivery shape the finding needs. **No `setsid`** — it is
not in the required-tool set, and it is not needed: `sig_launch` signals the
`exec`ed shell directly, which is the pid the lock records as its owner.

- **R11a–R11e** — `HUP`, `USR1`, `USR2`, `ALRM`, `PIPE` delivered pid-only
  inside the write phase, parked on the `cp` that stages a managed tree. The
  new discriminator is read **while the writer is still parked**: is the
  signalled shell still alive, is the lock still the exact incarnation it took,
  and is a second real `agent-flow-kit update` still refused. Then the park is
  released and the section 11 assertions follow — no second managed write, rc
  `128 +` the signal, lock gone only once the process is dead, no release
  residue, journal still `IN_PROGRESS`, applied revision unmoved, next run
  `RECOVERED` and the one after `CONVERGED`.
- **R11f** — `QUIT` delivered the same way. The run must **survive**, keep its
  lock, and converge on the revision it was asked for. This case exists so that
  adding a `QUIT` handler fails a gate instead of passing review as a tidy-up.

**The guard these cases needed, found by running them.** The first full gate run
of this cycle failed six R11a assertions on a tree that is correct — the run
under test finished normally instead of dying on `SIGHUP`. The cause was the
gate harness, not the kit: the run had been launched under `nohup`, which sets
`SIGHUP` to **ignore**, and an ignored disposition is inherited by every
descendant. Bash cannot trap a signal that was ignored on entry to the shell, so
`bin/agent-flow-kit`'s `trap ... HUP` was silently a no-op and `kill -HUP` did
nothing. Only `HUP` failed, which is the signature — `nohup` ignores that one
signal and nothing else.

Both possible silent outcomes are lies, so the case now refuses to be either.
`sig_deliverable` tries to install a handler in a subshell and asks `trap -p`
what actually took: a launcher that ignores the signal reports `trap -- ''`
rather than the handler. When a signal cannot be delivered the case prints a
warning and **skips**, in the same idiom `tests/run-tests.sh` uses for a host
with no shellcheck, rather than reporting the kit as broken for something the
kit did not do. Verified both ways on the final tree, in the scratch
harness described under anti-vacuity below: under `nohup` it is **114 / 0 with
one loud skip** and no failure, and launched normally it is the full **133 / 0**
— the difference is exactly R11a's 19 assertions. The gate run recorded below
probes all eight dispositions before it starts, every one of them was
trappable, and the mutation gate reports **zero skips**.

**Anti-vacuity.** The baseline for this cycle is the **current R10-fixed tree
with the new traps removed** — not the `94f81b8` freeze — reconstructed in
scratch: `AFK_TRAPPED_SIGNALS` back to `(INT TERM)` and the five new `trap`
lines deleted, with these tests unchanged.

Both trees were run through a scratch harness that keeps the suite's fixtures
and section 12 and drops sections 1–11, so a discrimination run costs about 4½
minutes instead of 28. Its totals carry 31 unit-level assertions that live
inside the fixture functions, so the harness numbers are 31 higher than section
12's own 102 — the comparison is between two runs of the same harness, and
every one of the 40 differences is an R11 assertion.

| tree | scratch harness (section 12 + 31 fixture assertions) |
|---|---|
| fixed | **133 / 0** — 4 runs (1 solo, 3 concurrent) |
| the five traps removed | **93 / 40** — 3 concurrent runs, byte-identical failure set each run |

The 40 failures are 8 per signal × 5 signals, and they name the harm exactly:
*the run does not die out from under the write it started*, *so the lock is not
handed back while that write is in flight*, *and it is still the exact lock the
writer took*, *a contender meeting the signalled writer is refused* (which on
the baseline reported `OPERATION_RECOVERED` — the contender took the freed lock
and rolled the installation back **while the first writer's `cp` was still
parked and about to write**), *with the owner-action exit*, *the journal stayed
visible for recovery*, and both recovery assertions. R11f passes on both trees,
as it must: it pins a decision, not a defect.

**Lessons for the record** (lessons, not acceptance criteria):

1. **Signal-delivery shapes belong on the review attack checklist.** Two
   independent variables decide whether a signal is dangerous, and cycle 9 got
   both wrong for `HUP`. Trapped vs untrapped changes bash's *deferral*: a
   trapped signal waits for the running command, an untrapped one runs `EXIT`
   and dies immediately. Pid-only vs process-group delivery changes whether the
   *writer* survives the signal that killed the shell. R10 shipped believing
   `HUP` was the `SIGKILL` shape (lock survives, reclamation handles it); it is
   the opposite — the lock is released and the writer lives.
2. **A signal's disposition is inherited from whatever launched the gate.**
   This is the third variable in the same family as lesson 1, and it bit this
   cycle for real: `nohup`, and any supervisor that ignores a signal, hands
   `SIG_IGN` to every descendant, and bash cannot trap what was ignored on
   entry. A signal test therefore has to verify it can ask its own question
   before it trusts the answer — otherwise the environment writes the verdict.
   Worth carrying into how CI invokes these suites, not just into review.
3. **CI budget: `tests/run-tests.sh` is roughly half an hour**, with the
   mutation suite about twenty minutes of it solo, on a 12-core host. The cycle
   9 record quoted only the ~3 minute section 11 figure, which under-budgets
   the gate by an order of magnitude. Section 12 adds roughly 4½ minutes on top.

**Hardening backlog — registered here, deliberately not fixed.** These join
F6-R5, F6-R6, F6-R8 and S1. No cycle was opened for any of them.

- **B1 — a signal inside the lock publication window bricks the installation.**
  Between the lock directory appearing and its owner record being published, a
  death leaves a recordless lock that is `UNKNOWN`, never `DEAD`, therefore
  never reclaimable: every later mutating command refuses
  `OPERATION_LOCK_OWNER_UNVERIFIABLE` until a human removes the directory.
  Reproduced. A real regression against pre-R10 behaviour, but it is a
  three-command race and sits below the exploitability bar the convergence
  policy sets. Remedy if it is ever picked up: `trap '' INT TERM` (and the rest
  of the set) around `afk_lock_take`, restored the moment the owner record is
  published. That touches `lib/afk-mutate.sh`, which is merged, so it cannot be
  done inside this cycle's surface at all.
- **N1 — release and stale asides leak.** `lock.released.<inc>` and
  `lock.stale.<inc>` are not covered by the sweep, which only reaches `op-*`
  under `$AFK_BACKUP_ROOT` / `$AFK_STAGE_ROOT`.
- **N2 — a signal inside the `EXIT` trap before it disarms abandons the
  release.** Bash will not re-enter `EXIT`. Fail-closed (the lock survives for
  reclamation) and practically unreachable; comment-worthy only.
- **N3 — a signalled reclaimer destroys an abandoned lock unreported**, which
  weakens F6-R9's "the reclaimer owns the report".
- **N5 — `tests/lifecycle-mutation-tests.sh` is mode `100644` at HEAD** while
  every sibling suite is `100755`. Pre-existing; the runner invokes it through
  `bash`, so no gate is affected.

**Cycle 10 gates — every gate rerun with no edit in flight, on a launcher
proven able to deliver all eight signals.**

| gate | result | rc | wall |
|---|---|---|---|
| `bash tests/lifecycle-tests.sh` | 443 passed, 0 failed | 0 | 440s |
| `bash tests/lifecycle-mutation-tests.sh`, solo | **577 passed, 0 failed** (475 as cycle 9 + 102 new), **0 skipped** | 0 | 1658s |
| `bash tests/lifecycle-mutation-tests.sh`, 3 runs under concurrent load | 577 passed, 0 failed — **3 of 3**, 0 skipped | 0 | 1217s wall for all three |
| `bash tests/lifecycle-concurrency-tests.sh` ×2 | 207 passed, 0 failed, both runs | 0 | 40s each |
| `bash tests/run-tests.sh` | 231 passed, 0 failed; shellcheck 0.11.0 genuinely ran (`nix`) and `agent-flow-kit` plus all six libs are clean | 0 | 2174s |
| `git diff --check` | clean, no output | 0 | — |

Section 12 contributes **102** assertions: 19 for each of R11a–R11e and 7 for
R11f. The one `SKIP` anywhere in `run-tests.sh` is the pre-existing live-router
chain, which needs `AGENT_ROUTER_URL`/`_TOKEN` and is unrelated to this change.
No flake was seen: eight full mutation-suite runs across this cycle (four on
the final tree in the harness, four in the gate) and two full `run-tests.sh`
runs agreed exactly.

**Residual risks for the diff-scoped reviewer.**

- **`USR1`/`USR2` exit statuses are Linux numbering.** 138 and 140 are `128 +
  10` and `128 + 12`; on macOS those signals are 30 and 31, so a signalled run
  there would report 138/140 where `128 +` the signal number means 158/159.
  `README.md` claims macOS is proven. The safety property is unaffected — the
  lock is held until the write finishes on either platform — and only the
  reported number is wrong. The literal idiom was kept because it is what the
  brief specified and what `INT`/`TERM` already use (130 and 143 are portable);
  making it portable would mean expanding `kill -l` at trap-install time. Worth
  a ruling; not fixed unilaterally inside a one-cycle bounded scope.
- **R11f depends on bash's own disposition for `SIGQUIT`, not on this code.**
  If a future bash stopped ignoring it, R11f would fail and the right answer
  would then be to trap `QUIT` after all. That is the intended alarm, but it is
  an assertion about the interpreter rather than about the kit.
- **The `alive` observation is a bounded 2-second poll.** A correct run cannot
  be waited out — it is blocked in the interposer's park until the test
  releases it — and the wrong behaviour appears within milliseconds, so the
  window is not a race. It is still a duration rather than a file, which is
  weaker than the `parked.N` discriminators section 11 uses.
- **Section 12 costs about 4½ minutes** and re-uses the section 11 interposer,
  so the mutation gate is now the long pole of `run-tests.sh` by a wide margin.
- **Section 11 has no deliverability guard.** `sig_deliverable` was added to
  the section 12 cases only, which are this cycle's surface. Section 11's INT
  and TERM cases are exposed to the same artifact — a launcher doing
  `trap '' INT TERM` around the gate would make them misreport exactly as R11a
  did — and `nohup` does not do that, which is why it has never fired. Left
  alone deliberately rather than widened inside a bounded cycle; a reviewer may
  reasonably rule the other way.
- **`SIGSTOP` is not addressed and cannot be.** A stopped owner holds the lock
  and is correctly reported live; that is the contract's answer, not a hole.

### Cycle 9 — F6-R10 (the signal handler that released the lock and carried on)

- Status: **cycle 9 implemented, not frozen.** Scope was the single blocker an
  external PR review raised against the frozen revision and the PM confirmed
  against the tree. Whether this re-opens or restores the freeze is the PM's
  call after independent review; nothing here declares it.

**F6-R10 — release belongs to EXIT.** `bin/agent-flow-kit`, the trap wiring.
The line was `trap 'afk_lock_release' EXIT INT TERM`. A handler on INT or TERM
that does not exit does not end anything: bash runs it and **resumes** the
script at the point the signal landed. So a signal delivered mid-transaction
released the operation lock and the same process went on writing — a live
owner, still inside its write phase, holding nothing. The next `agent-flow-kit
update` could take the freed path and mutate the same installation alongside
it. FR-92 is violated through a door none of F6, F6-R1..R9 could see: every one
of those was about a process that **died** holding the lock, where the lock
survives and reclamation is the answer. This is the opposite case — the owner
lives and the lock does not.

Fixed by giving each signal its own handler that terminates:

```
trap 'afk_release_on_exit' EXIT
trap 'afk_terminate_on_signal 130' INT
trap 'afk_terminate_on_signal 143' TERM
```

Only EXIT releases, so the lock comes back at the one moment this process can
no longer write. The signal handlers exit `128 +` the signal number, which runs
the EXIT trap: an interrupted run therefore ends through its own cleanup rather
than continuing unlocked, and it reports a status that cannot be mistaken for
one of the six result codes. Both handlers set `trap '' INT TERM` before doing
anything, so a second signal cannot re-enter a cleanup already under way and
leave the release half-done. Nothing else moved: `afk_lock_release` is
exact-incarnation and already idempotent, so the release the ordinary path
performs makes the trap's one a no-op rather than a second removal, and the
journal is still deliberately left where it is — recovery depends on it.

**Where each signal-landing case now ends.**

| the signal lands | what happens |
|---|---|
| before the lock is acquired | handler exits 143/130; the EXIT release finds nothing held and does nothing; no journal was opened and nothing was written |
| mid-transaction, before the commit | handler exits; EXIT releases the exact incarnation this run installed; the journal stays `IN_PROGRESS` and the backups stay, so the next command rolls the operation back and the applied revision never moved |
| during rollback | same path — the lock is released at exit; whatever the rollback had not finished is left with its journal and recovery material for the next command, exactly as an `UNRECOVERABLE` result leaves them |
| after the commit, during housekeeping | handler exits; EXIT releases; the committed manifest stands, because housekeeping cannot change what the commit means |
| after the ordinary release, in the post-steps | handler exits; the EXIT release is a no-op — it holds no incarnation, so a lock a successor has since taken is left strictly alone |

**Contract truth.** `docs/LIFECYCLE-CONTRACT.md`: the lock section now states
that release happens when the owning process exits and at no earlier moment,
and why an interrupted command must terminate rather than clean up and carry
on; the transaction's step 2 says the same in one clause; and the exit-code
section says plainly that a signalled run produces `128 +` the signal number
and no result document, which is not one of the six codes and must not be read
as one. The machine-checkable `exit_codes` block is untouched — 130 and 143 are
not result codes and adding them there would have been a lie the schema gate
would rightly have caught.

**Regressions — `tests/lifecycle-mutation-tests.sh` section 11, 61 assertions.**
The signal is delivered at a point the suite chooses rather than races for. A
test-only interposer is put on `PATH` ahead of one tool the transaction really
calls (`cp`, `git` or `jq`), and it parks the calling process on the invocation
the case is about, then becomes the real tool. Nothing in `bin/` or `lib/` is
modified to be observable, and every run under test is a real
`agent-flow-kit update` against a real installation under the suite's own
`mktemp` root.

- **R10a / R10b** — TERM and INT delivered inside the write phase (the `cp`
  that stages a managed tree, after the lock, after the journal, after the
  first write was recorded as attempted). A contender arriving while the writer
  is parked is refused with `CONCURRENT_OPERATION_IN_PROGRESS`, told to wait and
  never told to remove anything by hand. Then the signal: the interposer parks
  a **second** time on the next call to the same tool, which only a process
  that handled the signal and went back to work can reach. That second park is
  the whole discriminator — and when it is reached the suite reads the lock
  path at that instant and runs a second real `update`, so the finding is
  asserted as the harm itself rather than as a proxy for it. Post-fix the
  second park is never reached, the run exits 143/130, the lock is gone only
  once the process is dead, no release residue survives, the journal is still
  `IN_PROGRESS`, the applied revision never moved, and the next two commands
  `RECOVERED` then `CONVERGED`.
- **R10c** — TERM before the lock is acquired (parked on the first `git` call).
  Exits 143 having taken no lock, opened no journal and written nothing; the
  host tree is fingerprint-identical, and the following run converges normally.
- **R10d** — TERM after the authority transition, still holding the lock
  (parked on the `jq` that marks the journal committed). Exits 143, releases
  exactly once, and the committed revision stands.
- **R10e** — TERM after the ordinary release (parked on the `jq` that builds
  the result document). A **live** lock owned by another process is planted at
  that moment: the dying run's EXIT trap must leave it exactly where it is,
  which is the exactly-once/exact-incarnation property asserted against a real
  successor rather than against an empty path.

**Cycle 9 gates — every gate rerun with no edit in flight.**

| gate | result | rc |
|---|---|---|
| `bash tests/lifecycle-tests.sh` | 443 passed, 0 failed | 0 |
| `bash tests/lifecycle-mutation-tests.sh` | **475 passed, 0 failed** (414 as frozen + 61 new) | 0 |
| `bash tests/lifecycle-mutation-tests.sh`, 3 runs under concurrent load | 475 passed, 0 failed — **3 of 3** (three suites in parallel) | 0 |
| `bash tests/lifecycle-concurrency-tests.sh` | 207 passed, 0 failed — 3 runs after the final edit | 0 |
| `bash tests/run-tests.sh` | 231 passed, 0 failed; shellcheck 0.11.0 genuinely ran and `agent-flow-kit` is clean | 0 |
| the F6-R10 regressions, isolated | 61 passed, 0 failed — 3 runs | 0 |
| `git diff --check` | clean | 0 |

**Anti-vacuity.** A scratch reconstruction of the pre-fix trap wiring — a full
copy of the tree whose `bin/agent-flow-kit` is byte-identical to the frozen
revision's, with these tests unchanged — fails the section on every run:

| tree | F6-R10 section (3 runs each) |
|---|---|
| fixed | **61 / 0**, three times |
| pre-fix trap wiring reconstructed | **40 / 21**, three times — identical failure set each run |

On the pre-fix tree R10a and R10b fail on exactly the assertions that name the
hole: the process reached the write path again after the handler
(`SIG_PARKED2 = true`), the lock was `FREED-WHILE-WRITING` at that instant, and
a second real `agent-flow-kit update` **acquired it and mutated the same
installation alongside the first**. What that produced is the reason the
finding matters: the interrupted run exited 2 rather than 143, its journal was
left `ROLLBACK_INCOMPLETE`, and both following commands reported
`UNRECOVERABLE` — a corrupted installation needing its owner, from one
`Ctrl-C`.

**Residual risks for the reviewer.**

- `SIGHUP` is not trapped. A hung-up run dies by the default action without
  releasing, which is the `SIGKILL` shape: the lock survives and reclamation
  handles it. That is fail-closed, but it is a different interruption
  experience from INT/TERM and was left alone deliberately rather than
  overlooked.
- Terminating is one of two defensible answers. The other is to **defer** the
  signal to a transaction boundary so an interrupted update completes rather
  than leaving work for recovery. That would make `Ctrl-C` unresponsive during
  a write phase and is a larger behavioural change than the finding asks for;
  the required property — never continuing to write unlocked — is satisfied by
  either, and this cycle took the one the reviewer named.
- A signal that lands inside `afk_lock_release` itself, between the point it
  clears `AFK_LOCK_HELD` and the rename that removes the directory, leaves the
  lock on disk with its owner dead. That is the abandoned-lock state
  reclamation already exists for, so it fails closed — but it is the one path
  where a handled signal does not release.
- The interposer runs a `bash` wrapper per call to the tool it fronts, so R10d
  and R10e (which front `jq`) are the slowest scenarios in the mutation gate.
  The section costs roughly three minutes.
- The second park in R10a/R10b is unreachable on a correct tree, so the two
  assertions that inspect it are conditional by construction. They are proven
  to discriminate by the pre-fix reconstruction above, not by the fixed run.

### Cycle 7 — F6-R4 (the raced discriminator) and F6-R9 (the silent reclamation)

- Status: **cycle 7 implemented.** Scope was the two confirmed blockers in
  `_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.2-F6-R2R3-POSTFIX-REVIEW.md`,
  plus the two gate/contract items that review made mandatory: the shellcheck
  sub-gate that reported passes it never computed, and two contract sentences
  the review falsified. The story is **not** frozen by this cycle — the freeze
  is the PM's call after independent review.

**F6-R4 — one observation, one verdict.** `lib/afk-mutate.sh`,
`afk_lock_judge_record`. Cycle 6 told "the record is gone" apart from "the
record is damaged" by asking the filesystem a **second** time after the read
came back empty. Two looks are two instants, and the lock path is exactly where
a successor arrives between them: released, taken again, republished under the
same name. The second look then found a brand-new, perfectly valid record and
called it unparseable — `OPERATION_LOCK_OWNER_UNVERIFIABLE` and *"remove the
lock by hand"* against a lock a live successor was holding. The reviewer forced
it deterministically and measured it naturally: **6 "could not be parsed"
verdicts in 40 000 adversarial observations, zero of them true**.

Fixed by reading the record **once** and judging the bytes that read returned.
A record is installed by renaming one complete temporary file onto its name, so
the bytes are a whole record or there are none: no bytes is the no-record
moment the acquisition already waits out, and bytes that were read and do not
parse are the diagnosis they always were. The read is `cat -- "$rec"` rather
than `jq "$rec"` because the shell must hold the bytes to judge them; `cat` was
already an undeclared dependency of `lib/afk-common.sh`, and it is now in
`afk_require_tools`.

One test still runs before the read — `[[ ! -f "$rec" || -L "$rec" ]]` — and it
is deliberately **not** a discriminator: it refuses to read something that is
not a plain file, because reading a directory, a device or a fifo is a hazard
rather than a judgement. Racing it can only ever produce the no-record moment,
never a diagnosis, so the harm the finding describes is not reachable through
it.

**F6-R9 — a reclamation reports itself.** `lib/afk-mutate.sh`,
`afk_lock_reclaim` and `afk_lock_acquire`; `lib/afk-commands.sh`,
`afk_lock_refusal` and `afk_run_mutation`. `AFK_LOCK_RECLAIMED` was set by the
**acquisition** on success. So a reclaimer that won the arbitration marker,
re-proved the abandoned incarnation, renamed the lock directory aside, proved
what it had moved and removed it — and then lost the `mkdir` on the freed path
to a contender — returned 3 and said nothing, while the contender that won had
reclaimed nothing and had nothing to say either. An abandoned lock was
destroyed and nobody reported it, contradicting `lib/afk-commands.sh`'s own
*"reclaiming a lock is never silent"* and the contract's
`OPERATION_LOCK_RECLAIMED`. Under load it reddened the mandated gate:
`f6contend4` failed 2 runs in 5, and `run-tests.sh` was 229/1.

Fixed by moving the report to the destruction. `afk_lock_reclaim` records one
line per abandoned lock it destroys, at the point where the rename has already
taken the lock off its path and the aside has just been proven to be the
incarnation that was judged — before, and independently of, the take that
follows. `afk_lock_acquire` no longer claims the reclamation as its own; it
only resets the record at the start of an acquisition. One emission point,
`afk_lock_reclamation_findings`, is called from all three places a mutating run
can end after acquiring or trying to: the recovery branch, the converged
branch, and — new — `afk_lock_refusal`, so a run that destroyed an abandoned
lock and was then refused still reports what it removed. Exactly one finding
per destroyed lock; a run that destroyed nothing reports nothing.

**Gate integrity — the shellcheck sub-gate.** `tests/run-tests.sh` section 0
captured stdout only, discarded stderr and never inspected the exit status, so
a checker that failed to *start* produced empty stdout and was read as clean.
On this host that is exactly what happened: `shellcheck` is not on `PATH`, the
`nix run` fallback exits on a disabled experimental feature, and the gate
printed twelve `PASS shellcheck clean:` lines without shellcheck ever running.

The checker is now **proved to run before anything is checked with it**: each
candidate is asked for its version and must exit 0 and identify itself as
ShellCheck. `nix --extra-experimental-features "nix-command flakes" run
nixpkgs#shellcheck --` was added as a candidate, which is what makes the gate
genuinely execute on this host. Each file's verdict is then decided by the exit
status — 0 with no output is clean, 1 with output is findings, 1 with *no*
output means the checker did not run, and anything else is a checker that
delivered no verdict — and every one of those is a FAIL rather than a pass.
When no candidate can be made to run the gate SKIPs loudly: a banner saying
nothing was linted, one SKIP line per script, a skipped count in the summary,
and the line *"skipped checks computed no verdict — they are not passes"*.
shellcheck is still not required to be installed; honesty about its absence is.

**Contract truth.** `docs/LIFECYCLE-CONTRACT.md`:

- The publication-window paragraph claimed a refusal is made only when
  *"nothing published it while it was watched"*. The budget is spent across an
  acquisition rather than per lock, so an acquisition that already spent it
  elsewhere can refuse a lock it barely watched — the reviewer produced an
  8 ms refusal against a live publication window. The sentence now says what
  the refusal actually establishes, and says plainly that the budget belongs to
  the acquisition.
- *"Only a record that is still there and still unreadable is a diagnosis"* was
  false for a record that was gone and replaced. The paragraph now states the
  single-observation rule directly, and why a second look is a second instant.
- The reclamation bullet now states that the report belongs to the process that
  destroyed the lock, at the moment it destroys it, and that exactly one
  `OPERATION_LOCK_RECLAIMED` is reported per destroyed lock whether the run
  goes on to converge or to refuse.

**Cycle 7 gates — every gate rerun with no edit in flight.**

| gate | result | rc |
|---|---|---|
| `bash tests/lifecycle-tests.sh` | 443 passed, 0 failed | 0 |
| `bash tests/lifecycle-concurrency-tests.sh` (3 runs after the final edit) | 207 passed, 0 failed each time | 0 |
| `bash tests/lifecycle-mutation-tests.sh`, **5 runs under concurrent load** (7 mutation suites in parallel, 12-core host) | 414 passed, 0 failed — **5 of 5** | 0 |
| `bash tests/run-tests.sh` | **231 passed, 0 failed** | 0 |
| shellcheck through the repaired sub-gate (ShellCheck 0.11.0 via nix) | all 12 shipped scripts clean | 0 |
| `git diff --check` | clean | 0 |

The review's red assertion — `f6contend4`'s *"the abandoned lock is still reclaimed exactly once"*, which
failed 2 runs in 5 under load and made `run-tests.sh` 229/1 — passed 5 of 5 loaded runs here, and still fails
on an R9-reverted tree under the same load.

Anti-vacuity, on three reconstructed pre-fix trees in scratch space (each a full copy with exactly one
reviewed hunk reverted in `lib/afk-mutate.sh`, all parsing):

| tree | concurrency (3 runs each) | mutation |
|---|---|---|
| fixed | 207 / 0 | 414 / 0 (×5 under load) |
| F6-R4 reverted | 202 / 5 | 414 / 0 — control |
| F6-R9 reverted | 204 / 3 | 409 / 5 (twice) |
| both reverted | 199 / 8 | — |

Each reverted tree fails **only** its own fix's assertions, and every F6, F6-R1, F6-R2 and F6-R3 regression
stayed green on all four trees. Full detail, including the three negative probes of the repaired shellcheck
sub-gate and the residual risks, is in
`_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.2-F6-R4R9-FIX.worker-done.md`.

**Left documented, not fixed.** F6-R5 (`afk_lock_evaluate`'s `-e` / `! -d` pair — same class; no deterministic
forced interleaving exists between two adjacent shell builtins, and a deterministic regression was the
condition for taking an optional item), F6-R6 and F6-R8. F6-R7 is fixed as the gate-integrity item above, and
the review's residuals 3 and 4 are closed by the reader-agnostic hook and by `f6markervanish`.

**Diff size, cycle 7.** Roughly 210 changed lines: ~55 in `lib/` (the single read, the reclamation record and
its one emission point, `cat` in the required-tool set), ~10 in `docs/LIFECYCLE-CONTRACT.md`, ~95 in
`tests/run-tests.sh` (section 0 rewritten), and ~50 across the three test files plus the new lockctl verb.


### Cycle 6 — F6-R2 and F6-R3, the two neighbouring vanished-record mis-refusals

- Status: **cycle 6 implemented.** Scope was the two confirmed blockers in
  `_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.2-F6-R1-POSTFIX-REVIEW.md`
  and nothing else. Cycle 5 fixed one site of a defect *class*; the review
  proved the class had three reachable sites and closed one. These are the
  other two. No other Story 1.2 semantics were changed, and the story is not
  frozen by this cycle — the freeze is the PM's call after independent review.

**The class, stated once.** A record this protocol has already seen to exist
and then finds GONE is a *moment* — a release or a reclamation landing between
two observations — not a diagnosis. Every diagnosis carries
`OPERATION_LOCK_OWNER_UNVERIFIABLE` and its owner action *"Confirm no lifecycle
operation is running on this installation, then remove `<lock>` by hand"*, and
an operator who follows that during a handover deletes a successor's live lock.
Cycle 5 established the reading for the publication window; these two sites are
the same reading applied where the record disappears instead of not yet
existing.

**F6-R2 — the arbitration marker the winner's rename carried away.**
`lib/afk-mutate.sh`, `afk_lock_reclaim`, the `rc=1` arm of
`afk_lock_marker_claim`. The marker lives *inside* the lock directory, so the
winning reclaimer's `mv -- "$AFK_LOCK_DIR" "$aside"` takes it with it. A loser
whose `ln` failed a moment earlier judged a marker that was already gone, got
`UNKNOWN|the lock carries no owner record|`, fell into the `*)` arm, and
returned `2` — which `afk_lock_acquire` maps to `3`, i.e. the refusal above,
while the successor was taking the lock. The reviewer reproduced it at library
level (16 of 480 staggered acquisitions), by forced interleaving, and at the
CLI in **12 of 256 real `agent-flow-kit update` runs (4.7%)**, with the holder
proven alive and the lock proven present at the instant of each refusal.

Fixed by distinguishing the two `UNKNOWN`s that arm used to conflate: a marker
that is **gone** returns `3` ("the situation moved — observe again"), a marker
that is **still there and unjudgeable** still returns `2`. That is the same
distinction `afk_lock_marker_claim` already drew one instant earlier — it
returns `2`, which reclaim maps to `3`, when the marker has vanished before its
own `[[ -e "$marker" ]]` check — so the fix makes two adjacent observations of
one state agree instead of contradicting each other. The re-observation is
bounded by `afk_lock_acquire`'s existing four-attempt ceiling; no new budget,
no new state.

**F6-R3 — the owner record released underneath the read of it.**
`lib/afk-mutate.sh`, `afk_lock_judge_record`. Between `[[ -f "$rec" ]]` and
`jq` opening the file, a release or a reclamation can rename the directory
aside. `jq` gets ENOENT and exits non-zero with empty stdout — byte for byte
what a malformed record produces — and the judge reported *"the lock owner
record could not be parsed"*, a permanent diagnosis, refused instantly with the
same remove-by-hand guidance. Nothing was ever unparseable:
`afk_state_file_write` installs a record by renaming one complete temporary
file onto the name, so a torn or partial record is not observable. The
reviewer's discriminating probe settled it empirically — 4 of 4 "could not be
parsed" verdicts had the record **gone**, none present-and-malformed, none
present-and-valid.

Fixed by re-testing the record after a read that produced nothing: gone means
`$AFK_LOCK_NO_RECORD_DETAIL`, which the acquisition already knows how to wait
out; still there means the diagnosis stands, refused at once with no wait. A
`jq` that fails for an unrelated reason while the record is still present is
therefore still refused, unchanged and fail-closed.

**What was deliberately preserved.** Fail-closed refusal for permanently
unjudgeable records, still instant and still costing zero wait (a marker or a
record that is present and unreadable). Truthful bounded fail-closed when
nothing ever appears. Mutual exclusion, single-winner reclaim atomicity,
exact-incarnation release, the bounded total acquisition, and the cycle-5
publication-window semantics — every one of them re-asserted by the existing
suites, which are unchanged apart from additions.

**Contract alignment.** `docs/LIFECYCLE-CONTRACT.md` listed *"unparseable"*
among the conditions whose remedy is removing the lock by hand, and the
implementation reached that branch for a record that had simply been released.
Three amendments, all truthful-description rather than new promises: the
refusal enumeration now says an owner record that is **present** and
incomplete, unparseable or unknown-schema; a new paragraph states that a record
is installed by one rename, so a record that cannot be read *because it is no
longer there* is the same moment as a lock still being published and is waited
on rather than diagnosed; and the reclamation bullet now says a loser that
finds the marker **gone** has observed the handover, refuses nothing and looks
again.

**Regressions, and the proof they are not vacuous.** All of them are forced
interleavings, not races. The reviewer's note that `f6contendclean` passed on a
pre-fix tree in one of two runs was taken as an instruction: nothing added here
depends on winning a timing.

`tests/lifecycle-concurrency-tests.sh` section 11 — *"a record seen and then
found gone is a moment, not a verdict"*, 28 assertions (17 for F6-R2, 11 for
F6-R3):

- **F6-R2, protocol level.** `tests/lockctl-helper.sh` gains
  `reclaim-marker-interleaved`, which copies the real `afk_lock_marker_claim`
  out with `declare -f` and wraps it so a **lost** claim announces itself and
  stands still. The test then does exactly what the winner does — renames the
  lock directory away, taking the marker with it — and releases the loser into
  its judge. Not a line of the claim or the judge is a fixture's; only the
  timing is.
- **F6-R2, acquisition level.** `acquire-marker-interleaved` runs the same
  interleaving through a whole `afk_lock_acquire`, with a live successor parked
  on the lock at the end of it — the exact state the old refusal told an
  operator to delete.
- **F6-R2, fail-closed preserved.** A marker that is present and unreadable
  still refuses at once: `rc=3`, *"cannot be judged"*, `publish_waits=0`, lock
  byte-identical afterwards.
- **F6-R3, judge level and acquisition level.** A `jq` ahead of the real one on
  `PATH` performs the release — rename aside, then remove — underneath exactly
  one read of exactly the record being judged, then hands over to the real `jq`,
  which finds nothing. The judge's own code is untouched. Asserted: the verdict
  is *"the lock carries no owner record"*, never *"could not be parsed"*, and
  the acquisition takes the now-free lock instead of refusing one that no longer
  exists.

`tests/lifecycle-mutation-tests.sh` — `f6vanishrecord`, 13 assertions, the
operator-visible payload of F6-R3 through the real `agent-flow-kit update`. It
runs on the **recovery** path deliberately: an interrupted journal acquires the
lock with no pre-flight judgement of it, so the first read of the owner record
in the whole command is the acquisition's own, and the fixture needs no
knowledge of read ordering. The test asserts that exactly one read was
intercepted, that no `OPERATION_LOCK_OWNER_UNVERIFIABLE` finding appears, that
`next_safe_action` contains no *"remove"*, and that the recovery the lock was
guarding actually happens.

Anti-vacuity was proved against three reconstructed pre-fix trees — copies of
this tree outside the repository with the F6-R2 guard reverted, the F6-R3
recheck reverted, and both reverted — each carrying the new tests unchanged:

| tree | `lifecycle-concurrency-tests.sh` | `f6vanishrecord` (isolated) |
|---|---|---|
| fixed | 174 passed / 0 failed (3 of 3 runs) | 13 passed / 0 failed (3 of 3 runs) |
| F6-R2 reverted | 169 / **5** (3 of 3, identical failures) | 13 / 0 (3 of 3) — correctly untouched |
| F6-R3 reverted | 169 / **5** (3 of 3, identical failures) | 7 / **6** (3 of 3, identical failures) |
| both reverted | 164 / **10** (3 of 3, identical failures) | — |

Every failure is behavioural and every count is identical across all three runs
of every variant: these are deterministic detectors, and each defect's
regressions fail **only** when that defect is present.

**Gates — every one green, run in this order, with no edit in flight:**

    bash tests/lifecycle-tests.sh              443 passed,  0 failed    rc 0
    bash tests/lifecycle-mutation-tests.sh     390 passed,  0 failed    rc 0   (was 377; +13 = f6vanishrecord)
    bash tests/lifecycle-concurrency-tests.sh  174 passed,  0 failed    rc 0   (was 146; +28 = section 11)
    bash tests/run-tests.sh                    230 passed,  0 failed    rc 0
        shellcheck                             clean on all 12 shipped scripts
        embedded lifecycle gate                443 passed,  0 failed
        embedded mutation gate                 390 passed,  0 failed
        embedded concurrency gate              174 passed,  0 failed
        live control-plane chain               SKIP (opt-in, not configured)
    git diff --check                           clean, no output         rc 0

The new regressions, called out explicitly:

    F6-R2  tests/lifecycle-concurrency-tests.sh section 11 (17 assertions)
             "a loser whose marker was carried off by the winner observes again"
             "and says nothing about a reclaimer it could not judge"
             "an acquisition that lost the marker to a successor is told to wait"
             "naming the live owner that now holds the lock"
             "so no operator is ever told to remove a lock a live owner holds"
             + fail-closed-preserved and residue assertions
    F6-R3  tests/lifecycle-concurrency-tests.sh section 11 (11 assertions)
             "a record released mid-read is reported as a record that is not there"
             "never as a record that could not be parsed"
             "an acquisition whose lock was released mid-read takes the free path"
             "and never called the vanished record unparseable"
             "it releases its own incarnation cleanly afterwards"
           tests/lifecycle-mutation-tests.sh f6vanishrecord (13 assertions)
             "a record that is not there is not a record that could not be parsed"
             "so nobody is told to remove a lock that was just handed over"
             "the work the lock was guarding happens instead"

shellcheck was also invoked directly (`nix run nixpkgs#shellcheck` with the
experimental flags this host needs) over the seven lifecycle-surface scripts at
`--severity=warning --exclude=SC2034,SC2154` and the four router scripts at
default severity: clean, no output, rc 0. See the residual note below on why
that was done by hand rather than read off the sub-gate.

**Files changed this cycle:** `lib/afk-mutate.sh`,
`docs/LIFECYCLE-CONTRACT.md`, `tests/lockctl-helper.sh`,
`tests/lifecycle-concurrency-tests.sh`, `tests/lifecycle-mutation-tests.sh`,
`_bmad-output/implementation-artifacts/traceability.md`, and this record.

**Deliberately not done:** this session did not merge, route, freeze or review
its own work, did not start Story 1.3, touched no retained evidence file, and
changed nothing outside F6-R2 and F6-R3.

**Residual risks worth a reviewer's attention:**

- **F6-R2's re-observation spends an acquisition attempt, not a wait slice.**
  A vanished marker returns `3`, which consumes one of `afk_lock_acquire`'s
  four attempts rather than one of the publication budget's 120 slices. That is
  deliberate — the marker's disappearance is resolved by looking at the lock
  again, not by waiting for a file — but it means an adversary that can strand
  and remove markers faster than four attempts can drive an acquisition to the
  loop's exhausted tail. The guidance there is truthful and safe
  (`OPERATION_LOCK_UNAVAILABLE`, *"No mutation was attempted"*, or a refusal
  naming a live owner), and this is the same family as the reviewer's O-3.
- **F6-R3's discriminator is one `stat` after the failed read.** If a whole
  release-and-republish landed between `jq`'s failure and that recheck, the
  recheck would see a present record and report *"could not be parsed"* — a
  moment mis-called permanent, the mirror of the defect just fixed. That needs
  two adjacent syscalls to straddle an entire handover. A `jq` that fails for an
  unrelated reason (a fork failure under memory pressure, say) while the record
  is still there is likewise still reported as unparseable: conservative,
  fail-closed, and unchanged from before this cycle.
- **The F6-R3 fixtures are coupled to `jq` being what reads the record.** That
  coupling is deliberate and buys determinism where a race would only buy a
  probability, and it fails loudly rather than vacuously: the concurrency-level
  tests assert the lock is actually gone afterwards, and `f6vanishrecord`
  asserts that exactly one read was intercepted. If the implementation ever
  stops shelling out to `jq` for that read, these tests fail rather than pass.
- **`f6vanishrecord` runs on the recovery path for a structural reason.** The
  ordinary mutation path judges the lock once before acquiring it (the
  `CONCURRENT_OPERATION_IN_PROGRESS` pre-flight in `afk_run_mutation`), so a
  fixture that intercepts "the first read" there lands on the pre-flight rather
  than on the acquisition and passes without exercising anything. The recovery
  path acquires with no prior judgement, which removes the ordering question
  entirely. A CLI-level detector for **F6-R2** has no such path available —
  nothing external runs between `afk_lock_marker_claim`'s `[[ -e ]]` and
  `afk_lock_judge_record`'s `[[ -f ]]`, so there is no interposition point — and
  F6-R2 is therefore pinned at library level only. The reviewer's own CLI
  reproduction of it was probabilistic (12 of 256); reproducing that in a gate
  would repeat the `f6contendclean` weakness rather than fix it.
- **The `shellcheck` sub-gate in `tests/run-tests.sh` can pass without running
  shellcheck.** It discards the tool's stderr and treats empty stdout as clean,
  so a `nix run nixpkgs#shellcheck` that fails to start (as it does on this host
  without `nix-command` enabled) reports twelve clean scripts. Not touched here
  — it is not this cycle's finding — but the shellcheck evidence recorded above
  was produced by invoking shellcheck directly with the experimental flags, not
  by trusting that sub-gate.
- Every observation the postfix review left open (O-1 through O-5) is
  untouched, and F6-R1's own residuals stand as recorded in cycle 5.


### Cycle 5 — F6-R1, the acquisition publication window

- Status: **cycle 5 implemented.** Scope was the single confirmed finding
  F6-R1 from
  `_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.2-F6-INDEPENDENT-REVIEW.md`
  and nothing else. Cycle 4 made the two destructive steps single-winner and
  that held under every attack the review drove; the defect was one step
  earlier, in **acquisition**, and it is an owner-guidance defect rather than a
  mutual-exclusion one. No other Story 1.2 semantics were changed, and the
  story is not frozen by this cycle.

**The defect, precisely.** `afk_lock_take` publishes ownership in two steps
that cannot be one: `mkdir` is the atomic test-and-set, and the owner record
appears inside the directory a moment later. In between, the lock exists and
carries no record. `afk_lock_judge_record` correctly returned `UNKNOWN`, and
`afk_lock_acquire` handled every `UNKNOWN` with an immediate `return 3` —
outside the bounded retry loop directly above it, even though this is the one
`UNKNOWN` that resolves itself within one file write.

`afk_lock_refusal 3` then emitted `OPERATION_LOCK_OWNER_UNVERIFIABLE`, whose
owner action is *"Confirm no lifecycle operation is running on this
installation, then remove `<lock>` by hand."* An operator who followed that
while the winner was mutating would delete a live owner's lock — the
two-owners-one-installation state the whole protocol exists to prevent. It was
also a documented-contract deviation: a lock a live winner is mid-way through
publishing is none of the five conditions `docs/LIFECYCLE-CONTRACT.md`
enumerates for that refusal.

The cycle-4 record disclosed this as a residual risk but understated it twice,
and the review is right on both counts. The window was measured at ~19 ms on
this host, not "narrow": it was reproduced as **100% of library-level losers**
(11 of 11 in a 12-way race) and **50% of command-level losers** (5 of 10
two-process rounds), which is the ordinary case — two terminals, two CI jobs, a
retry loop — not an exotic one. And the disclosure described it as a wrong
*reason*; it did not say that the guidance attached to that reason instructs
the removal of a lock a live operation is holding.

**The fix: wait for the record, do not condemn the lock.** The state is a
moment rather than a diagnosis, so it belongs inside a bounded wait rather than
in the immediate-refusal branch:

- `AFK_LOCK_NO_RECORD_DETAIL` names that one detail string once, so the judge
  that produces it and the acquisition that recognizes it cannot drift apart.
- `afk_lock_evaluate_settled` judges the lock and, **only** while the state is
  `UNKNOWN` *and* the detail is exactly "the lock carries no owner record",
  pauses and judges again. Every other unjudgeable record — unparseable,
  unknown schema, incomplete, no usable incarnation, a host that cannot answer,
  a lock path that is not a directory — is returned at once, so a genuinely
  undiagnosable lock costs no latency at all.
- The budget (`AFK_LOCK_PUBLISH_WAIT_SLICES` = 120 observations ~20 ms apart,
  a ceiling of roughly three seconds) is spent across the **whole acquisition**,
  not per attempt, so the ceiling holds however often the lock changes hands
  underneath the caller. `afk_lock_pause` probes once whether this host's
  `sleep` accepts a fraction — `sleep` is not in `afk_require_tools` — and
  counts a bounded arithmetic loop instead where it does not. It is never an
  unbounded spin.
- When the budget is spent the detail becomes "…and none appeared while it was
  waited on" and the refusal is made exactly as before. Fail-closed is
  preserved for a permanently ownerless lock, and by then "remove it by hand"
  is a report rather than a guess: nothing published that lock while it was
  watched.
- Two adjacent acquisition mis-refusals from the same window are corrected with
  it, because both hand a contender an untrue answer about a lock that is
  simply changing hands: a lock that **vanished** between the failed `mkdir` and
  the existence check no longer returns `2`
  (`OPERATION_LOCK_UNAVAILABLE` — "the lock could not be established", for a
  lock that is free), and a `NONE` observation no longer falls into the
  `UNKNOWN` branch. Both now observe again inside the same bounded four-attempt
  loop, and the post-loop resolution is unchanged.

Read-only paths are untouched: `afk_lock_state` and `status` still only report
`HELD` or `NONE` and never wait. `afk_lock_evaluate`, `afk_lock_judge_record`,
`afk_lock_reclaim` and `afk_lock_release` are byte-for-byte unchanged apart
from the shared detail constant, so mutual exclusion, atomic stale reclaim,
exact-incarnation release and the arbitration marker are exactly the cycle-4
protocol the review found sound.

**The regressions — every one of them fails on the pre-fix tree.** The review's
central point was that no gate constructed this state, so the new tests
construct it deliberately instead of racing for it.

`tests/lifecycle-concurrency-tests.sh` section 10, driven by two new
`tests/lockctl-helper.sh` verbs — `publish-slowly`, which performs the two real
steps of `afk_lock_take` with the window held open and the record still written
by the library, and `acquire-announced`, which announces the instant before it
observes:

- a contender that observes the open window **waits it out and then refuses for
  the live owner it found** (`rc=1`), having actually spent wait budget on it,
  and says nothing that reads as "this lock has no owner";
- the winner's lock is untouched throughout and still releases cleanly, leaving
  no residue;
- a window **nobody is publishing into** — the directory a process killed
  between `mkdir` and the record leaves behind, i.e. permanently incomplete
  owner metadata — still fails closed with `rc=3`, only after the wait is
  spent, saying the record never appeared, with the lock left byte-identical
  and nothing reclaimed;
- a fully published live owner costs **zero** wait, so the budget is a window
  and not a tax;
- **twelve contenders released from one barrier onto a clean lock path**: never
  more than one owner, not one of them told the lock has no owner, every
  outcome either ownership or a live owner to wait for, no lock and no residue
  afterwards.

`fail_closed_case` now also asserts the wait accounting for all twelve
malformed-metadata cases: the ownerless lock is the only one allowed to spend
budget, and the other eleven must refuse with none spent.

`tests/lifecycle-mutation-tests.sh` adds the same two properties at the command
level:

- `f6window` — a live process holds the publication window open while a real
  `agent-flow-kit update` contends. The contender is observed **inside** the
  wait rather than merely slow to arrive (a waiting acquisition pauses in a
  `sleep` child, which is a fact this host can read out of `/proc`, instead of a
  duration the test would have to guess), it is still there when the winner
  finally publishes, and it then reports `CONCURRENT_OPERATION_IN_PROGRESS`,
  never `OPERATION_LOCK_OWNER_UNVERIFIABLE`. Its `next_safe_action` is asserted
  to say "Wait for the operation" and asserted **not** to contain "remove" —
  the operator-safety property stated directly. Nothing is written and no
  journal is opened.
- `f6contendclean` — eight real `update` processes released from one barrier
  against an installation with **no pre-existing lock**, the ordinary case no
  gate constructed. Exactly one converges, not one contender reports
  `OPERATION_LOCK_OWNER_UNVERIFIABLE` or `OPERATION_LOCK_UNAVAILABLE`, nothing
  is reclaimed because nothing was abandoned, no lock or residue survives, and
  the installation verifies afterwards.

**Pre-fix falsification (run in this session).** With the cycle-4
`afk_lock_acquire` restored and nothing else changed:
`tests/lifecycle-concurrency-tests.sh` → **128 passed, 18 failed**, and the
`f6window` scenario → **6 failed**, reproducibly across three consecutive runs
each. With the fix in place both are green, also across repeated runs.

**Cycle 5 gate evidence — run in this session, on this worktree:**

```
bash tests/lifecycle-tests.sh              443 passed, 0 failed   (rc 0)
bash tests/lifecycle-mutation-tests.sh     377 passed, 0 failed   (rc 0)
    356 in cycle 4 + the 21 new command-level assertions
    (f6window 10, f6contendclean 11)
bash tests/lifecycle-concurrency-tests.sh  146 passed, 0 failed   (rc 0)
    107 in cycle 4 + 39 new (section 10, plus the wait accounting on all
    twelve fail_closed_case records); re-run 3 more times end to end,
    0 failures and no stderr on every run
bash tests/run-tests.sh                    230 passed, 0 failed   (rc 0)
    including: shellcheck clean on bin/agent-flow-kit, all six lib/afk-*.sh
                                    and tests/lockctl-helper.sh
               lifecycle gate             443 passed, 0 failed
               lifecycle mutation gate    377 passed, 0 failed
               lifecycle concurrency gate 146 passed, 0 failed
               live control-plane chain   SKIP (opt-in, not configured)
git diff --check                           clean, no output       (rc 0)
grep -nP '[ \t]+$' across every changed file   0 hits
```

As in cycle 4, `git diff --check` covers only tracked files and `lib/`,
`docs/` and the `tests/lifecycle-*.sh` files are still untracked on this
branch, so trailing whitespace was checked directly across every file this
cycle changed.

One caution learned the hard way and worth passing on: bash re-reads a script
from disk as it executes it, so editing a suite file while that suite is
running corrupts the run. An intermediate concurrency-gate run in this session
reported `58 passed, 0 failed` with `unbound variable` noise on stderr for
exactly that reason. Every number above comes from a run with no edit in
flight, and the three clean re-runs confirm it.

**Files changed this cycle:** `lib/afk-mutate.sh`,
`docs/LIFECYCLE-CONTRACT.md`, `tests/lifecycle-concurrency-tests.sh`,
`tests/lockctl-helper.sh`, `tests/lifecycle-mutation-tests.sh`,
`_bmad-output/implementation-artifacts/traceability.md`, and this record.

**Deliberately not done:** this session did not merge, route, freeze or review
its own work, did not start Story 1.3, and changed nothing outside F6-R1.

**Residual risks worth a reviewer's attention:**

- A lock directory that is genuinely ownerless — left by a process killed
  between `mkdir` and the record — now costs every mutating command roughly
  three seconds before it refuses, where it used to refuse instantly. That is
  the price of making the removal advice true, it is bounded, it is paid once
  per invocation, and no other unjudgeable lock pays it. A reviewer who thinks
  three seconds is the wrong number is arguing about `AFK_LOCK_PUBLISH_WAIT_SLICES`,
  not about the shape of the fix.
- The wait is a duration, so it is a heuristic about how long publication takes,
  not a proof. A host under extreme load could in principle exceed the ceiling
  and produce the old refusal — but only after having watched the lock for
  three seconds, which is a far stronger basis for the guidance than the
  instant judgement it replaces. Removing the heuristic entirely would mean
  making `mkdir` and the record one atomic step, which is a different lock
  protocol and out of this finding's scope.
- `afk_lock_pause` uses `sleep`, which is not in `afk_require_tools`. A host
  without it, or with a `sleep` that refuses a fractional argument, falls back
  to a bounded arithmetic loop whose slice length is host-dependent, so the
  three-second ceiling is approximate there. Correctness does not depend on the
  slice length; only the ceiling does.
- `f6window` reads `/proc/<pid>/task/<pid>/children` to prove the contender is
  inside the wait rather than slow to arrive. That is deliberate white-box
  coupling to `afk_lock_pause`'s use of `sleep`: it buys a deterministic
  assertion in place of a guessed duration, and it fails loudly rather than
  passing vacuously if that coupling breaks. The library-level equivalents in
  `tests/lifecycle-concurrency-tests.sh` are timing-free and prove the same
  property without it.
- **One further mis-refusal of the same family, observed but deliberately NOT
  fixed here. Superseded by cycle 6 (F6-R2), which fixed it.** `afk_lock_reclaim` judges an arbitration marker it lost the
  claim to; if that marker vanishes between the `[[ -e "$marker" ]]` check in
  `afk_lock_marker_claim` and the judge that follows — which is what its holder
  completing the reclamation looks like — the marker is judged UNKNOWN, reclaim
  returns 2 and the acquisition returns 3, so a loser can again be told to
  remove a lock a successor may hold live. The window is two stats wide rather
  than the ~19 ms of F6-R1, it lives in the reclaim path this cycle was told to
  preserve, and it is outside the confirmed finding, so it is reported rather
  than changed. If a reviewer wants it closed, the shape is small: that
  sub-case is "the situation moved", i.e. reclaim's `3`, not its `2`. Until
  then the crowd-on-one-abandoned-lock scenario in
  `tests/lifecycle-concurrency-tests.sh` section 1 stays deliberately
  permissive about *which* refusal a loser gets, and its comment now says so.
- The three secondary observations in the review (O-1, the non-exiting
  `trap ... EXIT INT TERM` in `bin/agent-flow-kit:301`; O-2, uncollected
  `lock.stale.*` / `lock.released.*` aside residue; O-3, a trailing slash on a
  declared `AFK_LOCK_DIR` breaking release) were **not** in this cycle's scope
  and are untouched. O-1 in particular is the one worth a decision: the review
  reports it as unverified at CLI level, and it is a mutual-exclusion question
  rather than a guidance one.

### Cycle 4 — F6 re-opened as a concurrency finding

- Status: **cycle 4 implemented.** Scope was F6 and nothing else. The cycle-3
  diagnosis of F6 was right about a single process and wrong about several:
  the lock could name its owner and judge it, but the two destructive steps —
  reclaiming an abandoned lock and releasing a held one — were decided on an
  observation rather than on the thing observed, so two processes could both
  end up believing they owned the installation. No other Story 1.2 semantics
  were changed.

**The two defects, precisely.**

*Reclamation was not single-winner.* `afk_lock_acquire` evaluated the owner,
found it dead, and then renamed the lock directory aside. Nothing tied those
two steps together. Two processes that both judged the same abandoned lock both
proceeded: the first renamed it aside and installed its own lock; the second
then renamed *that fresh, live lock* aside, removed it and installed its own.
Both returned 0. **Two owners, one installation**, and the rest of the
transaction — journal, backups, managed writes — ran interleaved underneath
them. The `.stale.$$` target name made this more likely, not less: it is
per-process, so it never collided and never refused anyone.

*Release was not ownership-scoped.* `afk_lock_release` removed
`$AFK_LOCK_DIR` on the strength of one boolean, `AFK_LOCK_HELD`. A process
whose lock had been reclaimed underneath it — by the race above, or by an
operator — deleted whatever was at the lock path, which by then was the live
lock of whoever came next. The predecessor's cleanup unlocked the successor.

**The fix: decide on the incarnation, not on the observation.**

The owner record gains an `incarnation` — a value unique to one acquisition,
`inc-<pid>-<hex>`, drawn from `/proc/sys/kernel/random/uuid` or `/dev/urandom`.
It answers a question the four identity facts could not: *is this still the same
lock I looked at?* The lock schema moved to `2.0`; a record in any other schema,
or with no usable incarnation, is `UNKNOWN` and fails closed rather than being
interpreted. The token is shape-checked before it is ever used, because it
becomes part of a path name.

- **Reclamation** (`afk_lock_reclaim`). An observer that judges a lock
  abandoned must first win an arbitration marker named for the exact
  incarnation it judged — `reclaim.<incarnation>.json`, placed with `link`,
  which refuses an existing name atomically, and staged complete so it is never
  seen half-written. Holding it, the reclaimer **re-judges the record from
  scratch**: the caller's observation is not evidence. Only if the record is
  still DEAD and still that incarnation does it rename the directory aside, and
  it then proves that what it moved carries that incarnation before removing
  anything. A loser touches nothing. A live successor, a foreign successor or
  simply a different incarnation all end the attempt without a write.
- **Release** (`afk_lock_release`). A process re-reads the record, refuses
  unless the incarnation is the one it installed, renames the directory to a
  name only it could have produced, proves again that what it moved is its own,
  and only then removes it. A former owner removes nothing.

Neither path observes a stale lock and then removes and recreates it: the
observation and the removal are separated by a claim exactly one process can
hold. The marker lives *inside* the directory it arbitrates, so a completed
reclamation carries it away and leaves no residue; a marker left behind by a
reclaimer that died is judged by the same liveness rules as an owner — a live
reclaimer is waited on with `CONCURRENT_OPERATION_IN_PROGRESS`, a dead one is
discarded by a single-winner rename and the acquisition starts over. That
matters: the fix for a permanent lock must not introduce a permanent lock.

`afk_lock_owner_record` now **fails** instead of writing a `complete: false`
record. A host that cannot state its own host, boot or process-start identity
refuses to take a lock (`OPERATION_LOCK_UNAVAILABLE`) rather than publishing an
owner nobody can ever judge.

**The regressions.** The lock's contract is the one part of this lifecycle no
single-process test can falsify, so it has its own gate:
`tests/lifecycle-concurrency-tests.sh`, driving real processes through
`tests/lockctl-helper.sh` and released together by a real barrier — each child
announces itself and spins on a go file; nothing waits on a sleep long enough
to look like a rendezvous. It pins: two contenders on one abandoned lock
produce exactly one acquirer, exactly one reported reclamation and never more
than one published owner; eight contenders never produce two owners and leave
no residue; a former owner's release cannot remove a successor, and a release
quoting a malformed incarnation is refused before it names a directory; a pid
that is running with a different start identity is a recycled pid, not the
owner; a lock from an earlier boot is reclaimable and one from another host is
not; twelve varieties of missing, partial, unparseable, wrong-schema or
path-shaped metadata each fail closed *and* leave the lock byte-identical; an
active owner is never reclaimed, even by a reclamation aimed straight at its
incarnation; reclaiming the same stale incarnation twice is idempotent; and an
abandoned arbitration marker is recovered while a live one is waited on.

The new gate is aggregated by `tests/run-tests.sh` as section 8, alongside the
read-only and mutation gates, so the story's declared gate list still runs it
without change: one command still answers "is the kit green".

The interleaving that produced the bug is forced rather than raced for: an
observer is stopped at the exact stale-observation/reclamation boundary, a
successor takes the lock and stays alive holding it, and only then is the
observer allowed to act on what it saw. It must not acquire, the successor's
lock must be untouched, and the successor's own release must still succeed.

At the command level, `tests/lifecycle-mutation-tests.sh` gains `f6contend2`,
`f6contend4` and `f6contendlive`: whole `agent-flow-kit update` processes
released together against one installation carrying one abandoned lock. Exactly
one converges, the abandoned lock is reclaimed exactly once, no contender
reports a result outside the lock's vocabulary, the installation verifies
afterwards, and no `lock.stale.*`, `lock.released.*` or `.afk-reclaim.*`
residue survives. Against a *live* owner, none of them mutates and the tree is
byte-identical. The existing F6 fixtures no longer hand-roll a record: they take
the schema, the incarnation and the identity fields from the library itself, so
a fixture cannot drift from what the lock actually writes.

**Cycle 4 gate evidence — run in this session, on this worktree:**

```
bash tests/lifecycle-tests.sh              443 passed, 0 failed   (rc 0)
bash tests/lifecycle-mutation-tests.sh    356 passed, 0 failed   (rc 0)
bash tests/lifecycle-concurrency-tests.sh 107 passed, 0 failed   (rc 0)
    re-run 14 times end to end (one of them inside tests/run-tests.sh),
    0 failures on every run
bash tests/run-tests.sh                   230 passed, 0 failed   (rc 0)
    including: lifecycle gate             443 passed, 0 failed
               lifecycle mutation gate    356 passed, 0 failed
               lifecycle concurrency gate 107 passed, 0 failed
               shellcheck clean on bin/agent-flow-kit, all six lib/afk-*.sh
               and tests/lockctl-helper.sh
git diff --check                          clean (rc 0)
grep -nP '[ \t]+$' across every changed file   0 hits
```

`git diff --check` covers only tracked files, and `lib/`, `docs/` and the
`tests/lifecycle-*.sh` files are still untracked on this branch, so trailing
whitespace was additionally checked directly across every file this cycle
changed.

**Files changed this cycle:** `lib/afk-mutate.sh`,
`docs/LIFECYCLE-CONTRACT.md`, `tests/lifecycle-concurrency-tests.sh` (new),
`tests/lockctl-helper.sh` (new), `tests/lifecycle-mutation-tests.sh`,
`tests/run-tests.sh`,
`_bmad-output/implementation-artifacts/traceability.md`, and this record.

**Deliberately not done:** this session did not merge, route, freeze or review
its own work, and changed nothing outside F6.

**Residual risks worth a reviewer's attention:**

- The acquisition path is now strictly fail-closed on self-identity: a host
  that cannot produce a host identity, a boot identity, its own process-start
  identity or an incarnation cannot take a lock at all, so every mutating
  command there refuses with `OPERATION_LOCK_UNAVAILABLE`. Cycle 3 would have
  taken the lock with an incomplete record and only failed the *next* process.
  This is the safer direction and the one the finding asks for, but it is
  strictly less available on a host without procfs, without `ps`, or without a
  randomness source.
- The arbitration marker is a hard link, so the state directory must be one
  filesystem — it is, by construction, since the marker is staged inside
  `$AFK_STATE_DIR` and linked into the lock directory beneath it. A state
  directory assembled across a mount boundary would make every reclamation fail
  to claim and report `OPERATION_LOCK_OWNER_UNVERIFIABLE`: fail-closed, but
  opaque.
- `afk_lock_acquire` retries a bounded four times when the lock changes hands
  underneath it. A pathologically contended installation can exhaust that and
  refuse a caller that would have succeeded on a fifth look. The refusal is
  truthful and re-running succeeds; an unbounded retry was rejected because it
  turns contention into a hang.
- Two contenders can still both refuse in the window between `mkdir` of the
  lock directory and the publication of its owner record inside it: a reader
  that lands there sees a lock with no record and fails closed. That is
  correct — at most one owner is never violated — but it means a loser's
  refusal is occasionally `OPERATION_LOCK_OWNER_UNVERIFIABLE` rather than
  `CONCURRENT_OPERATION_IN_PROGRESS`. The concurrency gate accepts either
  refusal and asserts the ownership count instead.
  **Superseded by cycle 5 (F6-R1).** The independent review measured this
  window at ~19 ms and reproduced it as 100% of library-level losers and 50%
  of command-level losers — not "narrow" and not "occasional" — and showed
  that the refusal it produces carries guidance to remove a lock a live owner
  is holding. It is fixed above, and the gate no longer accepts either
  refusal.
- The multiprocess regressions are genuinely concurrent, so they are the most
  schedule-sensitive tests in the kit. They were run repeatedly rather than
  once; the assertions are ownership counts and residue, not orderings, which
  is what keeps them deterministic.

### Cycle 3 — the accepted adversarial findings F1–F8

- Status: **cycle 3 implemented.** All eight findings from the independent
  adversarial review are fixed in the lifecycle rather than argued away, and
  each has a named regression in `tests/lifecycle-mutation-tests.sh` section
  10. No transactional invariant was relaxed; three of the fixes tighten a
  contract the review found stated but not enforced.

**F1 (CRITICAL) — the recovery journal was destructive authority.**
`afk_recover_interrupted` replayed `completed_steps[].destination` verbatim and,
finding no stored copy, treated "restore" as "remove". A state-directory
cleanup that emptied `backups/op-XXXX/` while leaving the directory, or a
journal naming a path the inventory no longer declares, turned the next
ordinary `update` into an unbounded `rm -rf` — reported as `RECOVERED`, with
the journal then closed and the evidence deleted behind it.

The fix separates evidence from authority. `afk_restore_component` takes an
explicit `removal-authorized` argument and **fails** rather than deleting when
it is absent; the fall-through `rm -rf` is gone. Recovery assembles authority
from facts that must all agree: a supported journal schema, a component the
*current* inventory declares, the declared destination, a journal that agrees
with itself (its `plan` entry and its `pre_mutation` entry name the same
destination and the same expected identity), the same containment/symlink guard
a managed write passes, a backup directory whose *resolved* path is inside the
declared backup root, and either a stored copy or a bound `observed_identity`
of null matched to that exact component and that exact `INSTALL` binding.
Restoration is then verified by `afk_restoration_verified` — the same predicate
the in-process rollback uses, so recovery can never settle for weaker evidence
than a rollback. Every refusal keeps the journal and every backup.

The journal schema moved to `2.0` because the required structure changed:
`pre_mutation` and `plan.components` are now load-bearing. Schema `1.x` is
refused with `OPERATION_JOURNAL_SCHEMA_UNSUPPORTED` rather than interpreted —
a v1 journal is exactly the shape whose destinations cannot be authorized.

**F2 — `applied_revision` named the target on failure paths.** It is now
assigned only after `afk_manifest_commit` succeeds, and
`afk_transaction_finish_failure` resets it to the prior revision as a second
guard. The revision the operation was attempting is reported separately as
`operation.target_revision`, published in the contract and projected into human
output.

**F3 — a revision-format precondition enforced only after the writes.** The
40-hex shape is checked in `afk_source_evaluate`, before any plan is
authorized, with its own `SOURCE_REVISION_FORMAT_UNSUPPORTED` reason. A sha256
checkout now refuses with a diagnosis that names the cause, having taken no
lock, opened no journal and created no backup — proven by the F3 regression,
which skips itself on a Git too old to create such a repository.

**F4 — a managed write widened a mode the owner had set.** The writers replay
the destination's mode (and ownership where the process is permitted) onto the
replacement *before* the atomic rename, and `afk_component_apply` proves the
result on both sides exactly as it proves the bytes outside a managed section;
a mismatch is `DESTINATION_METADATA_NOT_PRESERVED` and rolls back. Inode
identity is deliberately not asserted — the atomic rename is the property worth
keeping, and hard-link preservation is not something this lifecycle promises.
Kit state files (manifest, journal, lock owner record) are written through one
helper at `0600` inside a `0700` state directory.

**F5 — the plan and its binding were two filesystem passes.** The observation
is captured once in `afk_plan_binding_compute` and replayed into the plan loop
by `afk_observation_restore`, so `expected_destination_identity` and
`observed_identity` cannot describe different moments. A restore that cannot
find its component refuses the plan as `PLAN_NOT_COMPUTABLE`.

**F6 — a lock left by a killed process was permanent and undiagnosable.** The
lock carries an owner record naming host identity, boot identity, pid and that
process's start identity. An exact live owner blocks with
`CONCURRENT_OPERATION_IN_PROGRESS`; an owner this host can prove is gone (pid
absent, pid recycled, or a lock taken before this boot) is reclaimed by an
atomic rename-aside and reported as `OPERATION_LOCK_RECLAIMED`; a foreign,
incomplete or unjudgeable owner fails closed with
`OPERATION_LOCK_OWNER_UNVERIFIABLE` and names the directory the owner must
remove. The published guidance is now true on every branch.

**F7 — `journal_state` could not falsify.** `afk_plan_revalidate` re-runs
`afk_evaluate_journal` alongside the manifest and adaptation re-reads, with the
finding accumulators saved and restored, and a journal that moved is
`PLAN_STALE_MANIFEST_CHANGED`.

**F8 — backups orphaned by a crash before the journal.** The journal is opened
in `PREPARING` naming its backup directory *before* that directory is filled,
so an operation killed inside the backup loop leaves a record that closes it
and reclaims the material. Housekeeping sweeps `op-*` entries under the backup
and stage roots that the surviving journal does not name.

**Cycle 3 gate evidence — run in this session, on this worktree:**

```
bash tests/lifecycle-tests.sh            443 passed, 0 failed   (rc 0)
bash tests/lifecycle-mutation-tests.sh   336 passed, 0 failed   (rc 0)
bash tests/run-tests.sh                  228 passed, 0 failed   (rc 0)
    including: lifecycle gate           443 passed, 0 failed
               lifecycle mutation gate  336 passed, 0 failed
               shellcheck clean on bin/agent-flow-kit and all six lib/afk-*.sh
git diff --check                         clean (rc 0)
```

`git diff --check` covers only tracked files, and `lib/`, `docs/`,
`tests/lifecycle-*.sh` are still untracked on this branch, so trailing
whitespace was additionally checked directly with `grep -nP '[ \t]+$'` across
every file this cycle changed: zero hits.

The mutation gate grew from 259 to 336 assertions: section 10 adds the F1–F8
regressions, the F1 unit layer now proves that an unauthorized removal fails
and leaves the destination byte-identical, and the pre-existing recovery and
concurrency fixtures were migrated (journal schema `2.0` with real bound
identities; a lock held by a provably live owner). The F3 regression skips
itself, visibly, on a Git that cannot create a sha256 repository.

**Files changed this cycle:** `lib/afk-common.sh`, `lib/afk-source.sh`,
`lib/afk-plan.sh`, `lib/afk-mutate.sh`, `lib/afk-commands.sh`,
`docs/LIFECYCLE-CONTRACT.md`, `tests/lifecycle-mutation-tests.sh`,
`_bmad-output/implementation-artifacts/traceability.md`, and this record.

**Deliberately not done:** this session did not merge, route, or review its own
work. The `/tmp` review reports and their `repro*.sh` scripts were read as
evidence only; every reproduction that mattered was re-expressed as a
repository regression, and no test depends on a path under `/tmp`.

**Residual risks worth a reviewer's attention:**

- The lock's liveness proof is strongest on Linux (`/proc/<pid>/stat`
  starttime). On a host with neither procfs nor `ps`, `afk_process_start_identity`
  returns ambiguous, the owner is `UNKNOWN`, and every lock refuses with
  `OPERATION_LOCK_OWNER_UNVERIFIABLE` — fail-closed, but more manual than on
  Linux. The F6 regressions derive their fixtures from the library's own
  identity functions, so they follow whatever the host supports.
- Ownership preservation is captured and compared, and replayed only where the
  process is permitted to do it. A case where a managed write would change the
  owner is reported rather than attempted; it is not silently repaired.
- `afk_metadata_of` prefers `stat`; the `ls -ldn` fallback compares the symbolic
  mode column, which some systems decorate with an ACL or security-context
  marker. On such a host without `stat`, an unrelated xattr difference could
  read as a metadata change (fail-closed, but a false refusal).

### Cycle 2 and earlier

- Status: **cycle 2 implemented.** All four deterministic failures from the
  cycle-1 dispatcher run are diagnosed and fixed. Two of them were incorrect
  assertions in the new gate rather than defects in the lifecycle; one was a
  missing dependency in the gate's unit layer *plus* a real fail-open in
  `afk_plan_binding_compute`; one was a jq scoping error in the gate. No
  transactional invariant was relaxed, and no frozen requirement was traded for
  a green gate — where the fix was "the assertion was wrong", the replacement
  assertion pins the same invariant more tightly than the original did.

### Cycle 1 gate evidence (the dispatcher run this cycle answers)

- `bash tests/lifecycle-tests.sh`: PASS.
- `bash tests/run-tests.sh`: FAIL because
  `tests/lifecycle-mutation-tests.sh` reported **259 passed, 4 failed**.
- `git diff --check`: PASS.

### Cycle 2: the four failures

**Failure 1 — "plan-only computation unexpectedly found `journal.json`".**
Diagnosis: the plan path did not write it. The scenario runs `adopt_host`
first, and a *successfully committed* transaction deliberately leaves its
journal on disk marked `COMMITTED` (contract step 9: housekeeping marks the
journal committed; `afk_journal_mark_committed` rewrites the state, it does not
delete the file). Sections 3, 7 and 8 of this same gate assert that behaviour
directly, so `assert_no_file` on an adopted host was asserting the opposite of
the contract three other sections pin.

Fix, in two parts, both strictly stronger than the assertion they replace:

- A new pristine-host check runs *before* adoption: `adopt --plan --json` on a
  host the lifecycle has never touched must exit 0 and leave
  `$HOME/.local/state/agent-flow-kit` non-existent — no manifest, no journal,
  no lock, not even the state directory. That is the real "planning writes
  nothing" invariant, and absence is the right question there.
- On the adopted host the check becomes identity-based: a new
  `journal_fingerprint` helper hashes the journal (or reports `absent`), and
  the assertion is that computing a plan does not MOVE it, plus that the
  journal present is the closed `COMMITTED` one adoption left. A byte-identical
  journal is a stronger claim than "no file": it also rules out a plan that
  opened and closed one.

**Failure 2 — `afk_component_table: command not found`, an empty component
binding, and a binding that did not change when a managed destination did.**
Two independent defects, and the second is the serious one.

- The gate's UNIT layer sourced `afk-common.sh`, `afk-plan.sh` and
  `afk-mutate.sh` but not `afk-inventory.sh`, which is where the declared
  component table lives. `afk_plan_binding_compute` therefore enumerated
  nothing, and the subsequent `jq` died in its own subshell on the (also
  inventory-owned) unset `AFK_APPLIED_REVISION` — which is why the binding came
  out empty rather than merely short. The gate now sources the inventory, with
  a comment saying it is a dependency and not a companion.
- The library fail-open behind it: `afk_plan_binding_compute` was willing to
  RETURN an empty binding. An empty binding is the one shape that can never be
  falsified — it compares equal to itself at the mutation boundary no matter
  how far the installation moved in between, so a plan bound to nothing would
  have passed revalidation and reached the writers. It now materializes the
  declared table once, fails if the table cannot be read or is empty, requires
  one bound entry per declared row, and fails if any entry cannot be built. The
  caller turns that into `PLAN_NOT_COMPUTABLE`/`REFUSED`, so nothing is
  written. This is the "complete and falsifiable in every supported invocation
  path" half of the failure, and it is a real change to the product, not to the
  test.
- The gate gained the matching anti-vacuity control: the binding must cover all
  7 declared components and every entry must carry its path observation, both
  asserted BEFORE the stability comparison. Those two assertions are what would
  have caught this in cycle 1 instead of an assert_ne three lines later.

**Failure 3 — "a drift-refused update left a journal".** Same root cause as
failure 1: the journal on disk was adoption's `COMMITTED` journal, not one the
refused update opened. The refusal path returns from `afk_run_mutation` before
the lock is taken and long before `afk_journal_write` is reachable, so nothing
was opened — which is exactly what the requirement demands and what the
assertion could not see. The assertion now captures the journal fingerprint
immediately after adoption and asserts the refused update left it byte-identical.

**Failure 4 — `Cannot index array with string "operation"`.** The normalized
result shape is right; the assertion was wrong. In jq the argument to `index()`
is evaluated against `index()`'s own input, so `$pub | index(.operation.result)`
asks for `.operation` OF THE PUBLISHED ARRAY — hence the error. The `operation`
member is an object in `afk_operation_json`, in the contract document's
operation block, in the human projection and in the two shape assertions
directly above the failing one, so code, schema, human output and documentation
were already aligned and none of them changed.

The same jq mistake was present, silently, in three neighbouring assertions:
`$pub | index(.)` asks whether the published array contains ITSELF, which is
always true, so "every reason code an update emits is published", "every plan
action is published" and "every finding state is inside the component-state
vocabulary" were passing vacuously. All four now bind the needle to a variable
first. They also report the offending values (`unique | join(",")`) instead of
a count, so a future failure names what is unpublished; and a new control
asserts the update really emitted reason codes to check, so the membership test
can never again pass because there was nothing to test.

### Implementation artifacts

| Path | Role |
|---|---|
| `lib/afk-plan.sh` | The complete deterministic plan, its binding, its stable identity, and the revalidation performed at the mutation boundary. Writes nothing. **Cycle 2:** `afk_plan_binding_compute` fails closed instead of returning an incomplete binding. |
| `lib/afk-mutate.sh` | The only file that writes to a managed destination: lock, journal, backups, the four writers, post-write proof, rollback with verified restoration, interrupted-operation recovery, offline verification, and the single manifest commit. Unchanged in cycle 2. |
| `lib/afk-commands.sh` | `afk_run_mutation` (one driver for both transactions), `afk_cmd_verify`, lock observation in the shared evaluation, and the plan/operation/verification vocabularies in `schema`. Unchanged in cycle 2. |
| `lib/afk-common.sh` | The declared lock/backup/stage paths, the mutation reason messages and actions, `operation`/`next_safe_action` overrides in the result model, and the human projection of plan, operation and verification. Unchanged in cycle 2. |
| `bin/agent-flow-kit` | `adopt`, `update` and `verify`; `--plan` and `--approve-plan <identity>` as per-command options; the lock released on INT/TERM as well as EXIT. Unchanged in cycle 2. |
| `docs/LIFECYCLE-CONTRACT.md` | The mutation half of the contract: plan shape and identity, approval semantics, transaction order, journal states, preservation contract, verification, and six machine-checkable vocabularies. Unchanged in cycle 2 (see "deferred" below). |
| `tests/lifecycle-mutation-tests.sh` | The destructive-path gate (11 sections), entirely in throwaway HOMEs and checkouts. **Cycle 2:** sources the inventory, adds `journal_fingerprint`, adds the pristine-host and binding-coverage controls, and corrects the four jq membership assertions. |
| `tests/lifecycle-tests.sh` | Section 13 updated in cycle 1: the mutating verbs are implemented now, so what it pins is their coarse exit codes on a healthy host and that they still write nothing there. Unchanged in cycle 2. |
| `tests/run-tests.sh` | Section 0 shellchecks the two new libraries; section 7 runs the mutation gate in its own process. Unchanged in cycle 2. |
| `README.md` | "Understanding a host" split from "Changing a host". Unchanged in cycle 2. |

### Design decisions worth reviewing

- **Adoption establishes ownership; it converges nothing.** Content is recorded
  at the identity it already has, so adopting a legacy host cannot overwrite
  anything. Recognized-but-old content is recorded, reported
  `UPDATE_AVAILABLE`, and converged later by an ordinary `update` with its own
  plan, backups and rollback. This is what makes "auto-adopt" safe enough to be
  unattended (FR-25) without it secretly being a convergence.
- **A journal is opened only at the mutation boundary, and a committed journal
  is kept.** Nothing before the first write can open one: every read-only
  command, every `--plan`, every refusal and every approval mismatch returns
  before the lock is taken. After a successful commit the journal stays on disk
  marked `COMMITTED`, which every readiness decision treats exactly like
  `NONE` — it is the record of the last completed operation, and deleting it
  would throw away the only evidence that the operation finished. This is what
  failures 1 and 3 were really about, and the gate now pins it as an identity
  rather than an absence.
- **An empty binding is a failure, never a binding.** The binding is the
  falsifiable half of the plan: it exists so that the mutation boundary can ask
  "is this still the same installation?". A binding covering zero components
  answers "yes" forever, so `afk_plan_binding_compute` now refuses to produce
  one and the plan becomes `PLAN_NOT_COMPUTABLE` instead.
- **The plan identity covers the plan AND its binding.** An approval therefore
  names one exact state of the world; any change to a bound input produces a
  different identity and the old approval stops authorizing anything
  (`PLAN_APPROVAL_MISMATCH`). There is no separate "approval token" to expire or
  forge — the digest *is* the authorization, and it is recomputed from scratch
  on every run.
- **A supplied `--approve-plan` that does not match is refused even when the
  new plan needs no approval.** The alternative — quietly proceeding because
  the recomputed plan happens to be auto-adoptable — is exactly the transfer of
  authority the requirement forbids.
- **A valid `PRESERVE` adaptation is consulted BEFORE the applied-identity
  comparison, and preserving one does not move the recorded baseline.** If the
  manifest recorded the adapted bytes, the next update would see
  `observed == applied` and replace them: the exception would have quietly
  become the thing that gets overwritten. The manifest keeps recording the
  canonical baseline and the adaptation record keeps explaining the difference,
  which is also why `verify` treats a matching adaptation as the one legitimate
  way installed content may differ from what is recorded.
- **`REEVALUATE` blocks rather than deciding.** It differs from `OWNER_REVIEW`
  only in its reason code and message, which is enough for automation to tell
  "your exception needs rethinking because canonical moved" from "you asked to
  be consulted". Neither disposition ever resolves a difference on its own.
- **One blocked component refuses the whole plan.** Convergence is never
  partial, so a host is never left half at revision A and half at revision B
  with no record of which is which.
- **The lock is taken only when a mutation is actually going to be attempted.**
  Every refusal, every `--plan`, and every read-only command stays completely
  write-free — which is what keeps "the first ever run on a pristine host
  creates nothing" true for the mutating verbs too, and keeps the no-op update
  churn-free (FR-46).
- **Restoration is verified, not assumed.** Rollback recomputes each restored
  destination's identity against the pre-mutation observation the plan bound,
  and a restoration that cannot be proven is `UNRECOVERABLE` with its journal
  and backups deliberately retained.
- **Backup presence is the record of what existed.** A destination with no
  stored copy is restored by removing what the operation created; nothing has
  to remember separately whether a component was created or replaced.
- **The same `afk_verify_against_manifest` is both the `verify` command and the
  pre-commit gate**, so a convergence can never be committed on weaker evidence
  than a verification demands.
- **Managed-section preservation is proven at write time, not just tested.**
  The writer compares the bytes outside the section before and after its own
  write and fails the component if they moved. Insertion is the one contracted
  exception (a single newline before the marker when the file did not end with
  one) and is checked against the backup rather than waived.
- **A marker line with extra bytes — a trailing CR, for instance — is not a
  marker.** CRLF content outside the section is preserved byte for byte; the
  kit's own markers are LF-terminated lines, and the contract says so.

### Findings and resolutions

1. **`update` and `verify` no longer refuse, so `tests/lifecycle-tests.sh`
   section 13 could not stay as written.** Four assertions there pinned Story
   1.1's temporary boundary (`update` exits 1 saying "Nothing was changed";
   `verify` exits 1 pointing at Story 1.2). FR-83 requires ordinary
   verification to *default* to offline evaluation, so making bare `verify`
   keep failing in order to preserve those assertions would have been
   contorting the product around a stale test. The block now pins what is
   actually contractual — each verb returns a coarse, stable code from the
   frozen set on a healthy host, and none of them writes anything there — and
   the rest of that 1,700-line gate is untouched.
2. **The destructive gate is a separate file.** `tests/lifecycle-tests.sh` is
   the read-only gate and stays that way; `tests/lifecycle-mutation-tests.sh`
   is the AC-28 fixture progression. Both run under `bash tests/run-tests.sh`
   (sections 6 and 7), and the read-only gate is also a story gate on its own.
3. **Injected mid-operation failure needed a defect the plan cannot see.** A
   permission or symlink trap set up before the run is caught at plan time, so
   it proves refusal, not rollback. The gate instead puts a symlink that
   escapes the managed tree into the *canonical source* of a later component:
   the source hashes fine, the copy lands, and the post-write containment check
   fails — a failure that genuinely occurs between two component writes. The
   first component's write is then rolled back and verified.
4. **`PLAN_STALE_*` cannot be reached end to end in a single process**, because
   nothing changes between the plan and the boundary check within one run. The
   gate proves the mechanism at the unit level instead: the binding covers
   every declared component, is stable over unchanged state, and moves the
   moment a managed destination moves — which is exactly the comparison the
   boundary performs. The approval half of the same requirement is proven end
   to end.
5. **`mutation_performed` is false for a pure adoption.** Adoption writes kit
   state, not managed destinations. `applied_state_committed` is the flag that
   says ownership became durable; the two are deliberately separate.
6. **Two of the four cycle-1 failures were the gate being wrong about the
   product, not the product being wrong.** That is worth stating plainly rather
   than burying: a gate assertion that contradicts three other sections of the
   same gate is a defect in the gate. Both were replaced with assertions that
   pin the underlying invariant more tightly (identity instead of absence, plus
   a pristine-host check where absence is genuinely the right question), so the
   correction did not cost coverage.
7. **A vacuous assertion is worse than a missing one**, because it reports
   PASS. Three membership assertions in section 10 were passing by construction
   and are now real; the same section gained a control that fails if there is
   nothing to check. See the deferred item below for the two identical
   instances that remain in the Story 1.1 gate.
8. **Scope held.** No router, catalog, prox-ops, Kubernetes, GPU or
   control-plane work. No live probe, no Git mutation, no orchestration
   activation. Live readiness vocabulary still reports `NOT_EVALUATED`, which
   is Story 1.3's surface.

### Deferred, deliberately, and disclosed

Both items below are real and neither is fixed in this cycle. The reason is the
same for both: this session has Read/Glob/Grep/**Write** only, and Write
replaces a whole file. Retyping a 1,700-line gate that currently PASSES, or a
900-line contract document whose machine-checkable blocks two gates compare
byte-for-byte against `schema` output, to change two lines and add two
sentences, risks far more than it fixes. Both are one-line edits for a session
with a patch tool.

1. **`tests/lifecycle-tests.sh` lines 1635 and 1639 carry the identical
   `($pub | index(.))` defect** fixed in the mutation gate: "every reason code
   in a status result is published" and "every reason code in an adoption
   result is published" currently pass vacuously. I traced the full reason
   universe by hand — every literal reason reaching `C_REASON`, `F_REASON`,
   `afk_add_target`, `afk_adoption_note` and `afk_src_finding` across
   `afk-inventory.sh`, `afk-commands.sh` and `afk-source.sh` — against
   `afk_reason_codes` + `afk_mutation_reason_codes`, and every one is
   published, so correcting these two lines should turn two vacuous passes into
   two real passes without changing the verdict.
2. **`docs/LIFECYCLE-CONTRACT.md` should say explicitly what failures 1 and 3
   turned on**: that a journal is opened only when an executable, conflict-free
   plan reaches the mutation boundary, and that a committed journal is kept on
   disk as the record of the last completed operation. Step 9 of the
   transaction order and the `journal_states` vocabulary imply it; the
   corrected assertions now depend on it, so it deserves a sentence of its own
   rather than an inference.

### Gates

**Not run by this session.** This worker was launched with the least-privilege
tool set (`Read,Glob,Grep,Write`) and has no shell, so
`bash tests/lifecycle-tests.sh`, `bash tests/run-tests.sh` and
`git diff --check` could not be executed here. The dispatcher re-runs them
independently after this session exits; that run is the arbiter, not this
record. Nothing below is a claimed pass.

What was verified statically instead, for the cycle-2 changes specifically:

- The failing jq filters were re-derived by hand against jq's scoping rule for
  `index(f)`, and each corrected filter was checked to produce `""` on the
  contract scenario's actual document: the reasons that update emits are
  `CANONICAL_REVISION_AHEAD`, `MACHINE_OWNED_REGION`, `USER_OWNED_REGION`,
  `LIVE_PROBE_NOT_REQUESTED`, `NO_EXECUTION_STAMP_SUPPLIED`,
  `TARGET_READINESS_NOT_EVALUATED` and `VERIFICATION_PASSED`, all published;
  the plan actions are `REPLACE`, `PRESERVE` and `NONE`, all published; the
  operation result is `CONVERGED`, published; and a clean convergence emits no
  findings, so the state check is trivially satisfied and the new non-empty
  control covers the vacuity risk that creates.
- The unit-layer sourcing change was traced against `set -u`: the empty binding
  in cycle 1 came from a command substitution dying on unset
  `AFK_APPLIED_REVISION` (a subshell death, which is why the suite survived to
  print its summary). Sourcing `afk-inventory.sh` supplies both the missing
  function and every manifest/journal global the binding reads, and its
  source-time side effects are plain initializations that the scenario layer
  overwrites anyway.
- The new fail-closed path in `afk_plan_binding_compute` was traced through
  both callers: `afk_plan_compute` turns a failure into
  `PLAN_NOT_COMPUTABLE` + `REFUSED` before any write, and `afk_plan_revalidate`
  turns it into a stale plan at the boundary. `AFK_PLAN_BINDING` is reset to
  `{}` on entry, which is valid JSON for `afk_plan_finalize`'s `--argjson`, and
  `afk_plan_revalidate` copies `before` before the reset happens.
- The journal-fingerprint assertions were traced against the code paths in the
  two scenarios: in `plan`, adoption commits and marks its journal `COMMITTED`,
  and the `--plan` invocation returns from `afk_run_mutation`'s plan-only branch
  without touching the lock or the journal; in `driftrefusal`, the refusal
  branch returns before `afk_lock_acquire`, so the file cannot have moved.
- The pristine-host check was traced to confirm nothing on the plan-only path
  calls `mkdir` on the state directory (`afk_lock_acquire` is the only caller,
  and it is not reached).
- New shell written for a first-run-blind environment: no `set -e`, no `tac`,
  no `mv -T`, no `readlink -f`; the two new loops use here-strings rather than
  process substitution, which keeps them in the current shell exactly as before.
- `--severity=warning --exclude=SC2034,SC2154` re-read against the changed
  region of `afk-plan.sh`: `rows`/`entry` are declared in the `local` line and
  assigned separately (no SC2155), every expansion is quoted, and the test
  files are not in the shellcheck set at all.
- No trailing whitespace introduced, so `git diff --check` has nothing new to
  find.

Expected gate result: `tests/lifecycle-mutation-tests.sh` at roughly 196
assertions (four replaced, five added), `tests/lifecycle-tests.sh` unchanged,
`tests/run-tests.sh` green with both aggregated sections.

### Final diff size

Cycle 1: two new libraries (~1,050 lines), one new gate (~900 lines), and edits
to `lib/afk-common.sh`, `lib/afk-commands.sh`, `bin/agent-flow-kit`,
`docs/LIFECYCLE-CONTRACT.md`, `tests/lifecycle-tests.sh` (one block),
`tests/run-tests.sh` (two hunks) and `README.md`.

Cycle 2 adds roughly 60 changed lines across two files: ~25 in
`lib/afk-plan.sh` (the fail-closed binding and its comment) and ~35 in
`tests/lifecycle-mutation-tests.sh` (the inventory source, `journal_fingerprint`,
the pristine-host and binding-coverage controls, and the four corrected
membership assertions).

Total remains roughly 2,400 new lines plus ~700 changed — above the 800-line
reviewable budget, as Story 1.1 also was. The surface splits cleanly for a
stacked chain if the PM wants it split: plan → transaction → command surface →
contract → gate, in that order, with each layer independently reviewable.
