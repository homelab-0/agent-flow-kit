# AFK-PORT-1.2-F6-R10-POSTFIX-REVIEW — independent adversarial review

- **Reviewer:** BMAD DEV (Amelia), fifth independent review session on Story 1.2. No prior session resumed; every prior conclusion treated as a claim to attack.
- **Persona proof:** `{ sha256sum .agents/skills/bmad-agent-dev/SKILL.md; sha256sum .agents/skills/bmad-agent-dev/customize.toml; } | sha256sum`
  = `07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee` — **exact match**, fail-closed satisfied.
- **Route:** launched under `_bmad-output/implementation-artifacts/AFK-PORT-1.2-F6-R10-POSTFIX-REVIEW.stamp.json` (claude / claude/strong / high / subscription, metered=false, validated). Not substituted locally.
- **Contract:** READ-ONLY. No repository file modified. All scratch work under `mktemp` roots and the session scratchpad. Tree-unmodified proof at the end.
- **Subject:** the uncommitted F6-R10 signal-handling fix in the `story/afk-port-1.2` working tree at `6f9a68c`.

---

## VERDICT: **NOT CLEAN** — one blocker

Findings are classified against the convergence-control policy Josh ruled during this cycle (exploitability bar: violates a frozen requirement **and** reproduced **and** reachable by one ordinary operator action; a signal inside a 3-instruction race does not qualify). Applying that bar deliberately demoted two findings I would otherwise have escalated.

- **1 blocker** — `SIGHUP` still frees the lock while the transaction is writing (FR-92 mutual exclusion). Verified one-line remedy.
- **5 below the bar** → residual registry / hardening backlog, itemised at the end.

The fix itself is right. `EXIT`-only release with terminating signal handlers is the correct shape, I verified the bash semantics it silently depends on, and I could not break any of the five signal-landing cases it claims. The gap is coverage of one more signal, not design. Per the cycle-cap rule, no fix should be dispatched on this without Josh's explicit go — the exploitability assessment he needs for that call is below.

---

## BLOCKER — `SIGHUP` still frees the lock while the transaction is still writing

This is the F6-R10 defect class itself, unfixed, on a third signal.

### The bash semantics the fix depends on

Measured directly (`probe3.sh`: a shell holding the lock, with a 4-second foreground child standing in for an in-flight managed write):

| signal | handler runs | in-flight child completed first? | rc |
|---|---|---|---|
| `TERM` (trapped) | 3.41 s after the signal | **yes** — deferred until the child finished | 143 |
| `INT` (trapped) | 3.41 s after the signal | **yes** — deferred | 130 |
| `HUP` (untrapped) | **0.001 s after the signal** | **no** — child still running | 129 |

Bash defers a *trapped* signal until the foreground command completes. That deferral is precisely what makes this fix safe: by the time `afk_release_on_exit` runs, the last external write has already finished. Bash does **not** defer an untrapped fatal signal — it runs the `EXIT` trap immediately and dies. So `SIGHUP` reaches the release while a descendant write is still outstanding.

Residual risk 1 asserts the opposite ("dies by default action — SIGKILL shape, lock survives"). The lock does not survive. It is released, immediately, mid-write.

### Reproduced end to end on the delivered tree

`attackD.sh` — a real `agent-flow-kit update` parked with a pending managed-tree copy in a live child:

```
[D-TERM] 1s after TERM: shell alive=yes  lock=HELD    contender not attempted (correct)
[D-INT ] 1s after INT : shell alive=yes  lock=HELD    contender not attempted (correct)
[D-HUP ] 1s after HUP : shell alive=no   lock=FREED
[D-HUP ] contender: *** ACQUIRED-ALONGSIDE-THE-PENDING-WRITER *** result=RECOVERED
```

A second real `agent-flow-kit update` took the freed lock and ran a full recovery rollback of the installation while the first run's write was still pending. Two owners, one installation.

### Exploitability assessment (the honest version)

I tested both `SIGHUP` delivery shapes, because they are not equivalent (`attackL.sh`):

| delivery | shell | pending writer | lock | verdict |
|---|---|---|---|---|
| **whole process group** — a real terminal hangup, SSH drop, logout | dies | **also dies** | freed | **benign.** Nothing survives to write. Equivalent to a clean interrupted death; the next run recovers. |
| **shell pid only** — `kill -HUP <pid>`, `pkill -HUP agent-flow-kit`, a supervisor signalling just the main pid | dies | **survives** | freed | **FR-92 violation.** Contender acquires and rolls back while the writer is still going. |

So the most common hangup shape is *not* the exploit. The exploit needs `SIGHUP` delivered to the shell alone. Against the bar:

- **(a) frozen requirement** — yes. FR-92 mutual exclusion; two processes mutating one installation with neither dead.
- **(b) reproduced** — yes, deterministically, end to end, on the delivered tree.
- **(c) reachable** — yes, but narrower than I first assumed. `kill -HUP <pid>` / `pkill -HUP` is one ordinary operator action, and a process supervisor that signals only the main pid does it unattended. The vulnerable window is the **entire write phase** (seconds), not a 3-instruction race — which is the distinction the bar draws.

It clears the bar, though less decisively than the Ctrl-C case that motivated this cycle. A reasonable reading could park it in the residual registry instead; that is Josh's call.

**My recommendation: fix it.** Not because the risk is large, but because the cost is near zero and it closes the class. One line, in a file already being changed, using the idiom the fix already established — and I verified it rather than proposing it (`attackE.sh`, scratch copy):

```
trap 'afk_terminate_on_signal 129' HUP
```

```
[remedy] 1s after HUP: shell alive=yes  lock=HELD   contender not attempted (correct)
[remedy] shell rc=129;  journal=IN_PROGRESS;  next run: RECOVERED;  run after: CONVERGED
```

Trapping `HUP` converts it to the same deferred-termination shape as `TERM`: the shell waits for the in-flight write, releases at `EXIT`, exits 129, leaves the journal for recovery. If it is fixed, one contract sentence goes with it (below).

**Scope note.** Every terminating signal that is *not* trapped shares this shape. Measured: `HUP` 129, `PIPE` 141, `USR1` 138 all run the `EXIT` trap with the child still running; `QUIT` was harmless in this configuration. Only `HUP` is practically reachable while the lock is held — `SIGPIPE` cannot be, because nothing in the transaction writes to stdout (every `printf` between `afk_lock_acquire` and `afk_lock_release` sits inside a command substitution, `afk_warn` goes to stderr, and the only stdout write is the final emit, after the release). Worth fixing as a class rather than as one signal.

### Contract text that goes with it

`docs/LIFECYCLE-CONTRACT.md`, transaction step 2, added by this fix:

> "It is given back when the owning process exits and never while that process can still write, so an interrupted command ends rather than continuing unlocked."

Falsified by the pid-only `SIGHUP` case: the interrupted command does not end — its in-flight write continues, unlocked. This sentence is only true once `HUP` is trapped.

---

## What I attacked and could not break

Everything below was reproduced independently, against the working tree as delivered, with my own harness and interposer (not the suite's).

| # | case | result |
|---|---|---|
| 1 | `TERM` / `INT` mid-write | Lock stays `HELD` until the in-flight child finishes; contender refused; rc 143/130; journal `IN_PROGRESS`; next run `RECOVERED` → `CONVERGED`. **Clean.** |
| 2 | Signal during **rollback** (the recovery run) | rc 143; lock released; journal preserved; no residue; next run `RECOVERED` → `CONVERGED`. **Clean.** (`attackJ.sh`) |
| 3 | Signal **before acquisition** | Nothing held, nothing written, no journal opened, rc 143. **Clean.** |
| 4 | Signal **after commit, still holding** | Released exactly once; committed revision stands. **Clean.** |
| 5 | Signal **after the ordinary release**, live successor lock planted | Successor untouched — release is exact-incarnation. **Clean.** |
| 6 | **Signal storms** — 6× `TERM` + 6× `INT` interleaved, 3 runs | Handler ran exactly once, release ran exactly once, rc 130, every run. Disarm-first works. (`probe1.sh`) |
| 7 | Contender signalled **inside the F6-R1 publication-window wait** | rc 130; the planted lock it was waiting on was **not** removed. A loser removes nothing. **Clean.** (`attackG`) |
| 8 | **Reclaimer signalled mid-reclaim** (winner side) | rc 143; no successor lock removed; installation usable; next run `CONVERGED`. Two non-blocker consequences below. (`attackK`) |
| 9 | New-defect sweep: `exec` paths, background jobs, subshell traps, other traps in `lib/` | None exist. No lock is ever taken in a subshell; no `exec`; the only traps in shipped code are the three under review. `set -u` aborts still route through `EXIT`. **Clean.** |
| 10 | Exit-semantics truth | `TERM` → rc 143, **0 bytes on stdout**, no result document, silent stderr; `INT` → rc 130, same. The machine-checkable `exit_codes` block is untouched (0 hits in the diff); the six result codes 0–5 are unchanged. **Contract matches observed behavior.** (`attackI`) |
| 11 | Prior F6-R1..R9 semantics | All three suites fully green on the delivered tree — see gates. No regression. |

---

## Disposition of the five residual risks

**1. Untrapped `SIGHUP` — "dies by default action (SIGKILL shape — lock survives, reclamation handles it, fail-closed)."**
**DISPROVEN, escalated to Blocker 1.** The premise is wrong: bash runs the `EXIT` trap on an untrapped fatal `SIGHUP`. The lock does not survive — it is released, immediately, with the transaction's write still in flight. This is the opposite of the `SIGKILL` shape, and it is the F6-R10 defect, not a milder cousin of it.

**2. Terminating rather than deferring the signal to a transaction boundary — "a deliberate choice."**
**ACCEPTED.** Deferring to a boundary would make the tool unstoppable for the length of a transaction and would reintroduce the resumed-handler shape that caused F6-R10 in the first place. Terminate-and-leave-the-journal is the right call, and I verified it recovers cleanly from mid-write (case 1), mid-rollback (case 2) and post-commit (case 4). No change wanted.

**3. Signal inside `afk_lock_release` between clearing `AFK_LOCK_HELD` and the rename.**
**CONFIRMED and correctly characterized — fail-closed, no successor lock ever removed.** The release renames only onto a name carrying its own incarnation, re-reads the moved directory before removing it, and restores onto an empty name if the identity does not match; a former owner whose lock was reclaimed underneath it removes nothing. R10e (live successor planted) and my case 7 both hold. One addition the risk does not mention, filed as N1 below: when the signal lands *after* the rename, the `lock.released.<inc>` directory leaks permanently.

**4. Section 11 is the slowest part of the gate (~3 min).**
**CONFIRMED and accurate.** Measured: section 11 took **128 s** even with three copies of the suite running concurrently. Its waits are 180 s ceilings a correct run never approaches. Worth pairing with the number that actually matters for CI budgeting, which the note does not give: the whole mutation suite is **~20.6 min solo** on a 12-core host. Not a defect.

**5. The two conditional-by-construction assertions in R10a/R10b.**
**CONFIRMED as described, and they do discriminate — via the first assertion of the trio, not on their own.** `SIG_LOCK_AT_PARK2` and `SIG_CONTENDER_AT_PARK2` are initialised to `not-reached` and only take a real value when the second park is reached. On a correct tree they are structurally unfalsifiable. What discriminates is the assertion immediately above them (`SIG_PARKED2 == false`), which is genuinely falsifiable and is the real gate; the other two are diagnostic amplifiers that fire only once the real gate has already failed. That is a sound construction, but the trio should not be counted as three independent checks. Anti-vacuity verdict below.

---

## Anti-vacuity verdict: **the 61 regressions are genuine and non-vacuous — independently reproduced**

I rebuilt the pre-fix binary myself rather than trusting the fixer's reconstruction: a full copy of the working tree into scratch, with only the trap block reverted to `trap 'afk_lock_release' EXIT INT TERM` and every other byte — `lib/`, the tests, the contract — left identical. Then I ran the whole mutation suite against it.

| build | suite total | section 11 |
|---|---|---|
| fixed (delivered tree) | **475 passed, 0 failed**, rc 0 | 61 passed, 0 failed |
| pre-fix reconstruction | **454 passed, 21 failed**, rc 1 | 40 passed, **21 failed** |

**21 failures, matching the fixer's claimed set exactly** — R10a ×7, R10b ×7, R10c ×5, R10d ×1, R10e ×1. The two assertions residual risk 5 flags as conditional-by-construction fired with real values, not `not-reached`:

```
FAIL R10a so the lock was never freed while the writer could still write
      should not equal 'FREED-WHILE-WRITING'
FAIL R10a and no second writer could take the installation from under it
      should not equal 'ACQUIRED-ALONGSIDE-THE-WRITER'
```

They discriminate. The tests are not vacuous, and they pin the reported harm end to end rather than merely asserting the new trap wiring exists.

One qualification, already noted under residual risk 5: those two only reach a real value once the trio's first assertion has already failed. Count the trio as one falsifiable check with two diagnostics, not three independent checks.

---

## New-defect sweep

Beyond the two blockers, the rewiring introduced nothing. Checked specifically:

- **No `exec` anywhere in `bin/` or `lib/`** — nothing replaces the shell image and escapes the `EXIT` trap.
- **No background jobs** in shipped code.
- **No subshell holds the lock.** `afk_lock_acquire` / `afk_lock_release` run only in the main shell; command substitutions reset traps, but none of them owns lock state, so the reset is harmless.
- **No other `trap`** in `bin/` or `lib/` — the three under review are the only ones.
- **`set -u` aborts** still route through `EXIT`, which is what the trap is for. (`set -e` is not in effect; `set -uo pipefail` only.)
- **Exit status is preserved** through the `EXIT` trap: 143 / 130 observed, and 0 on clean runs.
- **`trap '' INT TERM` in the handlers is inherited by cleanup children** (`mv`, `rm`, `jq`) — correct, a Ctrl-C during cleanup cannot half-kill the release.

### Below the bar — residual registry / hardening backlog

**B1 — a signal in the lock publication window bricks the installation permanently.** *(new regression; below the bar on reachability)*
`afk_lock_take` is `mkdir` → `chmod 700` → `afk_state_file_write owner.json`. A signal between the `mkdir` and the record leaves a lock directory carrying no owner record. `afk_lock_judge_record` returns `UNKNOWN`, `afk_lock_evaluate_settled` waits it out and still cannot judge it, `afk_lock_acquire` refuses rc 3 — forever. Reclamation cannot help: it acts on `DEAD`, and a recordless lock is never `DEAD`.

Reproduced on the delivered tree (`attackA.sh`, parked at the `chmod 700` of the lock directory, then `SIGTERM`):

```
lock dir exists? yes; owner.json? NO      victim rc=143
next run:  rc=2 REFUSED / OPERATION_LOCK_OWNER_UNVERIFIABLE
           "...remove <lock> by hand. No mutation was attempted."
run after: rc=2 REFUSED / OPERATION_LOCK_OWNER_UNVERIFIABLE   (permanent)
```

On my pre-fix reconstruction the same signal was **harmless** (`victim rc=0`, run finished, `next run: CONVERGED`) — because pre-fix the tool absorbed the signal, which is the bug being fixed. So this is a genuine new failure mode: Ctrl-C now reaches a state only `SIGKILL` could reach before.

**Against the bar it does not block.** The window is three external command spawns — order of a millisecond in a multi-second run — which is exactly the "signal inside a 3-instruction window during a race" the policy excludes. No data loss, no corruption, and the "remove it by hand" guidance is true and safe because the owner really is dead. Remedy if it is ever picked up: `trap '' INT TERM` before the `mkdir`, restored after the record is published — the same two lines as `afk_release_on_exit`.

**B2 — the Release paragraph's closing sentence is false.** *(documentation; below the bar)*
`docs/LIFECYCLE-CONTRACT.md` line ~246, added by this fix: *"Neither path leaves an installation permanently busy."* B1 falsifies it for the `SIGINT`/`SIGTERM` path, and it is equally false for the `SIGKILL` path named in the same sentence. Untrue availability claim rather than untrue destructive guidance, so it sits below the bar — but if the contract is reopened for the `HUP` fix, correct this in the same pass rather than freezing a sentence that is not true.

**N1 — `lock.released.<inc>` and `lock.stale.<inc>` leak permanently.**
`afk_sweep_orphan_recovery_material` sweeps only `op-*` under `$AFK_BACKUP_ROOT` and `$AFK_STAGE_ROOT`. Nothing ever sweeps the lock asides. A death between the aside rename and the `rm -rf` leaves the directory — with its owner record inside — forever. Observed in three separate probes (C1, RR3, K). Harmless to correctness (it does not sit on the lock path, so acquisition is unaffected) but unbounded, and the suite's own `lock_residue()` helper asserts these are empty on clean paths, so the invariant is clearly intended. Pre-existing (`SIGKILL` reaches it); the fix widens reachability to `INT`/`TERM`.

**N2 — a signal in the `EXIT` trap before it disarms abandons the release entirely.**
`afk_release_on_exit` disarms `INT`/`TERM` as its first statement, but a signal delivered in the instant *before* that builtin runs enters `afk_terminate_on_signal`, which calls `exit` — and bash does not re-enter an `EXIT` trap that is already running. Demonstrated (`probe2.sh`): `EXIT-enter` logged, then `SIG 130`, then nothing — `disarmed` and `RELEASED` never ran. Fail-closed: the lock stays with a complete record for a dead pid, so the next run judges it `DEAD` and reclaims it. Practically unreachable on the mutating paths, because `afk_run_mutation` already released the lock before the shell exits, and on the signalled path `INT`/`TERM` are already `SIG_IGN` when the `EXIT` trap starts. Worth a comment, not a change.

**N3 — a signalled reclaimer destroys an abandoned lock and reports nothing.**
Verified (`attackK`): a run that reclaims a dead lock and is then signalled anywhere in the rest of its transaction exits 143 with no result document, so the reclamation — "the one place the lifecycle removes something another process created" — goes unreported. The next run sees a clean installation and `CONVERGED` with zero findings. Nothing is misled (the destroyed lock's owner really was dead) and it follows directly from the contract's new "produces no result document", but F6-R9's stated invariant is that the reclaimer owns the report. Newly reachable: pre-fix the run resumed and did report. Worth one sentence in the contract, not a mechanism change.

**N4 — the terminating-signal class, not just `HUP`.** See the scope note under Blocker 1.

**N5 — pre-existing, out of scope for this fix.** `tests/lifecycle-mutation-tests.sh` is mode `100644` at `HEAD` while every sibling suite is `100755`. `tests/run-tests.sh` invokes it as `bash "$MUTATION_TESTS"`, so no gate is affected, but it cannot be run directly the way its own usage line (`Usage: tests/lifecycle-mutation-tests.sh`) says. Predates this change — flagging it so it is not mistaken for fix fallout.

---

## Gates — all rerun by me on the delivered tree, exact counts

| gate | result | rc |
|---|---|---|
| `tests/lifecycle-tests.sh` | **443 passed, 0 failed** | 0 |
| `tests/lifecycle-mutation-tests.sh` — solo | **475 passed, 0 failed** (414 as frozen + 61 new); 1237 s | 0 |
| `tests/lifecycle-mutation-tests.sh` — loaded ×3 (three copies concurrent, 12-core host) | **475 / 0**, **475 / 0**, **475 / 0** | 0, 0, 0 |
| section 11 in isolation, under that 3× load | 61 passed, 0 failed; **128 s** | — |
| `tests/lifecycle-concurrency-tests.sh` — run 1 | **207 passed, 0 failed** | 0 |
| `tests/lifecycle-concurrency-tests.sh` — run 2 | **207 passed, 0 failed** | 0 |
| `tests/run-tests.sh` | **231 passed, 0 failed**; 1888 s | 0 |
| ↳ shellcheck | genuinely running (nix 0.11.0); clean on `agent-flow-kit` and all six `lib/*.sh` | — |
| ↳ aggregated gates | lifecycle 443/0, mutation 475/0, concurrency 207/0 | — |
| `git diff --check` | clean, no output | 0 |
| pre-fix reconstruction (anti-vacuity, scratch only) | **454 passed, 21 failed** | 1 |

Every number the fixer reported, I reproduced. No flakes across 5 full mutation-suite runs (1 solo + 3 loaded + 1 inside `run-tests`), including under deliberate concurrency.

Note for CI budgeting, since the residual-risk note gives only the section-11 figure: the mutation suite is ~20.6 min solo and `run-tests.sh` ~31.5 min on a 12-core host.

---

## Tree-unmodified proof

`sha256` of the five modified files, before any of my work and after all of it:

```
571b28cafbce59b80cafd4acc3b33920c52ca671b5d46470a49323c366dcc4e6  bin/agent-flow-kit
92c1e2836a57ccd5c6fb941ce818c10e8bc385213472f2049215f3b89d9a8629  docs/LIFECYCLE-CONTRACT.md
d7721eac4b9ef0d0dfa89513889a023caa8fd02076b99100c9eec8ac2e1a3bab  tests/lifecycle-mutation-tests.sh
abf322c185b0b26b3153fd606eee7572d22cc3351382a8cc12b10a8294dc74f5  _bmad-output/implementation-artifacts/AFK-PORT-1.2.md
6994e32b97a0d71032d782adb5d0728bf3203640e0cab0abb743785a5e5cc64e  _bmad-output/implementation-artifacts/traceability.md
```

`diff` of the before/after hash files: **identical, 5/5**. `diff` of the before/after `git status --short`: **identical** (same 5 modified, same 7 untracked). `git diff --check`: clean, rc 0. `HEAD` unchanged at `6f9a68c`. Nothing committed, nothing staged, no branch touched.

All my work — the pre-fix reconstruction, the `HUP`-trapped remedy copy, the probes, the interposer harness and every scenario — lived under `mktemp` roots and the session scratchpad.

---

## What the PM owns

I fixed nothing and froze nothing. Per the cycle-cap rule, this returns to Josh as a decision, not a dispatch:

1. **The `SIGHUP` blocker** — accept into the residual registry, or authorise the one-line fix (`trap 'afk_terminate_on_signal 129' HUP`, verified) plus the two contract-sentence corrections. My recommendation is to fix, on cost rather than risk.
2. **Five items below the bar** (B1, B2, N1–N5) — residual registry / hardening backlog, no cycle.
3. **Everything else on this fix is sound.** All five signal-landing cases hold, the 61 regressions are genuine and independently proven non-vacuous, every gate is green with no flakes, and prior F6-R1..R9 semantics are intact.
