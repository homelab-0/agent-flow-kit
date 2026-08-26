# AFK-PORT-1.2-F6-R11-FIX — dispatch brief (fresh BMAD DEV, stamped route)

Authorised by Josh 2026-08-25 after the F6-R10 post-fix review returned NOT CLEAN with one
blocker. **One bounded cycle.** No auto-cycling. Story 1.3 still waits.

## Routing

```yaml
route:
  provider: claude
  cli: claude
  model: opus
  effort: high
  agent: bmad-agent-dev
  fallback: [openai/gpt-5.6-sol]
gates:
  - "tests/lifecycle-tests.sh"
  - "bash tests/lifecycle-mutation-tests.sh          # solo AND >=3 concurrent loaded runs"
  - "tests/lifecycle-concurrency-tests.sh            # x2"
  - "tests/run-tests.sh"
  - "git diff --check"
max_cycles: 1
local_gpu: red
```

- **Model** — strong tier: the operation lock is safety-critical (FR-92 mutual exclusion) and a
  plausible-but-wrong change here is exactly what rounds R1–R10 chased. `fable-5` is blocked by
  the registry budget rule (epic planning / architecture / escalated reviews only); flagging the
  tension rather than breaking the rule. Opus is the right call regardless — the hard analysis
  is already done and handed over below.
- **Effort `high`, not `xhigh`** — per the convergence-control policy item 4 ("effort matches
  stakes; freeze-gating depth only when new invariant territory is touched"). Trapping more
  signals is the *same* invariant, already established. **Upgrade trigger:** bump to `xhigh` if
  cycle 1 fails gates or the signal set turns out not to enumerate cleanly. Do not escalate to
  `fable-5`.
- **Pool** — claude weekly at 42%, `<50%` = route normally. No pressure.
- **local_gpu: RED** — safety-critical concurrency on the lock; never delegate.

## In scope (exactly this)

### 1. Trap the remaining reachable terminating signals in `bin/agent-flow-kit`

Use the established idiom. `HUP` is mandatory:

```
trap 'afk_terminate_on_signal 129' HUP
```

**The reviewer already did the N4 reachability work empirically. Do not re-derive it — verify
it, then justify each signal in the Dev Agent Record.** Measured against a real
`agent-flow-kit update` parked mid-write with a live pending writer:

| signal | shell after | lock | contender | rc | verdict |
|---|---|---|---|---|---|
| **HUP**  | dies | **FREED** | **acquired alongside pending writer** | 129 | **TRAP — naturally reachable** (`kill -HUP <pid>`, `pkill -HUP`, supervisor signalling the main pid) |
| **USR1** | dies | **FREED** | **acquired alongside** | 138 | TRAP — not naturally reachable, but free and completes the invariant |
| **USR2** | dies | **FREED** | **acquired alongside** | 140 | TRAP — same justification |
| **ALRM** | dies | **FREED** | **acquired alongside** | 142 | TRAP — same justification (nothing in the tool sets an alarm) |
| **PIPE** | dies | **FREED** | **acquired alongside** | 141 | TRAP — **but read the caveat below** |
| **QUIT** | **survives** | HELD | n/a | 0 | **DO NOT TRAP — see the trap-trap below** |

**QUIT is the trap in this task.** Bash already ignores `SIGQUIT` here, so Ctrl-\ currently
*survives* a transaction. Adding a `QUIT` trap would newly make Ctrl-\ **kill** a run that today
completes — an availability regression bought for no safety gain. Leave it alone, and say so in
the record so the next reviewer does not "helpfully" add it.

**SIGPIPE caveat.** Proven **not naturally reachable** while the lock is held: zero bytes reach
stdout *or* stderr during the transaction (every `printf` between `afk_lock_acquire` and
`afk_lock_release` is inside a command substitution; `afk_warn` goes to stderr; the only stdout
write is the final emit, after the release). A real `update --json 2>&1 | head -c 1` completed
cleanly, lock gone, no residue. So trapping `PIPE` is defensive, not corrective — **and it
changes behavior at the final emit**: a closed stdout there would exit 141 through the handler
instead of dying silently. The lock is already released by then, so it is safe, but it is a
deliberate decision, not a freebie. Decide it explicitly and record the reasoning. Declining to
trap `PIPE` is an acceptable outcome if justified.

### 2. Correct both false contract sentences the R10 fix introduced

`docs/LIFECYCLE-CONTRACT.md`. **The contract must be true as written.**

- **Transaction step 2** — *"It is given back when the owning process exits and never while that
  process can still write, so an interrupted command ends rather than continuing unlocked."*
  Falsified today by pid-only `SIGHUP`. Trapping `HUP` makes it true; confirm the wording still
  matches behavior once the trap set is final.
- **Release paragraph, ~line 246 (B2)** — *"Neither path leaves an installation permanently
  busy."* False for **both** named paths: a signal (or `SIGKILL`) in the lock publication window
  leaves a recordless lock that is `UNKNOWN`, never `DEAD`, therefore unreclaimable, and refuses
  `OPERATION_LOCK_OWNER_UNVERIFIABLE` forever. Reproduced. **Do not fix the mechanism (that is
  B1, out of scope) — fix the sentence** so it stops claiming a guarantee the system does not
  make. Say what is actually true, including the publication-window exception.

Leave the machine-checkable `exit_codes` block untouched: 129/138/140/141/142 are not result
codes, exactly as 130/143 are not.

### 3. Add the pid-only SIGHUP scenario as a real section-11 regression

`tests/lifecycle-mutation-tests.sh`, section 11, in the existing R10 style.

- **Delivery shape is the whole point.** A whole-process-group HUP (real terminal hangup) is
  **benign** — the writer dies too. Only `kill -HUP "$VICTIM_PID"` (shell alone) exposes it. The
  suite's existing `sig_launch` already produces exactly this shape; **`setsid` is not needed and
  must not be introduced** (portability — it is not in the required-tool set).
- Assert the shape the R10 cases assert: no managed write after the signal, lock never
  `FREED-WHILE-WRITING`, no contender `ACQUIRED-ALONGSIDE-THE-WRITER`, rc **129**, journal stays
  `IN_PROGRESS`, applied revision unmoved, next run `RECOVERED` then `CONVERGED`, no residue.
- **Anti-vacuity is required.** Baseline for this cycle is the **current R10-fixed tree with HUP
  untrapped** (not `94f81b8`). Reconstruct it in scratch, show the new assertions FAIL there, and
  record the failure set. Add one case per additional signal you trap.

Expected reviewer-verified remedy behavior (reproduce this):

```
[remedy] 1s after HUP: shell alive=yes  lock=HELD   contender not attempted (correct)
[remedy] shell rc=129;  journal=IN_PROGRESS;  next run: RECOVERED;  run after: CONVERGED
```

### 4. Record two lessons in the story record — as lessons, NOT acceptance criteria

`_bmad-output/implementation-artifacts/AFK-PORT-1.2.md`:

1. **Signal-delivery shapes belong on the review attack checklist.** Trapped vs untrapped
   changes bash's deferral behavior, and pid-only vs process-group delivery changes whether a
   writer survives. R10 shipped believing HUP was the SIGKILL shape; it is the opposite.
2. **CI budget: `run-tests.sh` is ~31 min** (mutation suite ~20.6 min solo) on a 12-core host.
   The R10 record quoted only the ~3 min section-11 figure, which under-budgets by 10x.

## Out of scope — register, do not fix

Add to the hardening backlog alongside F6-R5 / R6 / R8 / S1. **No cycle.**

- **B1** — signal in the lock publication window bricks the installation permanently
  (`OPERATION_LOCK_OWNER_UNVERIFIABLE`). Real new regression vs pre-R10, but a three-command
  race, below the exploitability bar. Remedy if ever picked up: `trap '' INT TERM` around
  `afk_lock_take`, restored after the owner record publishes.
- **N1** — `lock.released.<inc>` / `lock.stale.<inc>` asides leak; the sweep covers only `op-*`
  under `$AFK_BACKUP_ROOT` / `$AFK_STAGE_ROOT`.
- **N3** — a signalled reclaimer destroys an abandoned lock unreported (weakens F6-R9's
  "reclaimer owns the report").
- **N5** — `tests/lifecycle-mutation-tests.sh` is mode `100644` at HEAD while every sibling suite
  is `100755`; pre-existing, runner uses `bash` so no gate is affected.
- **N2** — a signal in the EXIT trap before it disarms abandons the release (bash will not
  re-enter EXIT). Fail-closed, practically unreachable. Comment-worthy only.

## PRE-FLIGHT: merged-surface guard — already checked, and it PASSES

Josh's STOP rule is "confirm the fix touched no file in merged #6–#8". Pre-computed:

- **`origin/master` is `3d9ee8c`** with #6–#8 merged. **Local `master` is STALE at `15a97ba`** —
  fetch before doing anything with the stack.
- **Merged surface (#6–#8):** `README.md`, `lifecycle/kit.json`, `lib/afk-common.sh`,
  `lib/afk-inventory.sh`, `lib/afk-source.sh`, `lib/afk-plan.sh`, `lib/afk-mutate.sh`.
- **This fix's surface:** `bin/agent-flow-kit` (lands in #9), `docs/LIFECYCLE-CONTRACT.md` (#10),
  `tests/lifecycle-mutation-tests.sh` (#11), plus story records. **No intersection.**

> **TRIPWIRE:** every file under `lib/` is merged. If your change requires touching **any**
> `lib/*.sh`, **STOP and report before writing anything else** — that is Josh's explicit STOP
> condition. The reviewer-verified remedy needs `bin/agent-flow-kit` only, so this should not
> arise; if you think it does, you are solving a different problem than the authorised one.

## Gates — rerun all, exact counts and rc, no edit in flight

Baselines from the reviewer's independent runs on the current tree:

| gate | expected |
|---|---|
| `tests/lifecycle-tests.sh` | 443 / 0, rc 0 |
| mutation, solo | 475 / 0, rc 0 (+ your new cases) |
| mutation, ≥3 concurrent loaded runs | 475 / 0 each (+ new) |
| `tests/lifecycle-concurrency-tests.sh` ×2 | 207 / 0, rc 0 |
| `tests/run-tests.sh` | 231 / 0, rc 0; shellcheck clean on `agent-flow-kit` + all six libs |
| `git diff --check` | clean |

No flakes were observed across 5 full mutation-suite runs. A flake is a finding, not noise.

## Post-fix sequence (only if the diff-scoped review returns CLEAN)

1. Commit; new freeze SHA. Records state **"94f81b8 freeze superseded by `<sha>` after F6-R10"**,
   history retained.
2. Re-confirm the merged-surface guard against the final diff. If it touched anything in #6–#8 →
   **STOP and report before anything else.**
3. Rebuild #9–#12 (`stack-4-commands`, `stack-5-contract`, `stack-6-gates`, `stack-7-records`) to
   recompose to the new frozen tree; **re-prove tree equality**; then resume bottom-up merges
   under the existing rules.

## Review after this fix — separate fresh session, DIFF-SCOPED

```yaml
route:
  provider: claude
  cli: claude
  model: opus
  effort: high
  agent: bmad-agent-dev
```

Reviewer model ≥ implementer model, satisfied. `review_diversity` prefers cross-provider, but
safety-critical paths stay claude, the review is gate-heavy (~31 min of bash suites — a poor fit
for the small codex pool), and diversity is already carried by session count: this would be the
**seventh distinct session** on Story 1.2. Flagging the tension rather than hiding it.

**Scope: verify the remedy, verify the new regression's anti-vacuity, rerun all gates. NOT a
full adversarial sweep** (convergence-control policy item 3 — prior scenarios are pinned by their
regressions; the full adversarial review already happened). Findings outside the diff: **report
only, do not act**.

**Any new blocker from that review: STOP and report. No auto-cycling.**
