# AFK-PORT-1.2 — cycle 8: independent adversarial review of the F6-R4 / F6-R9 fixes

- Mode: WORKER (dispatched), READ-ONLY · repository `/home/devbox/repos/jlengelbrecht/agent-flow-kit`
- requested_persona: `dev` · resolved persona: **BMAD DEV (Amelia, Senior Software Engineer)**
- persona_source: `.agents/skills/bmad-agent-dev/SKILL.md` + resolved `customize.toml`
- Identity proof, recomputed in this session:
  `{ sha256sum .agents/skills/bmad-agent-dev/SKILL.md; sha256sum .agents/skills/bmad-agent-dev/customize.toml; } | sha256sum`
  = `07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee` — **matches expected; fail-closed check passed**
- Route: as stamped in `AFK-PORT-1.2-F6-R4R9-POSTFIX-REVIEW.stamp.json` (`claude` / `claude/strong` /
  effort high / subscription, metered=false). Not substituted.
- Fresh reviewer: no prior Story 1.2 session resumed. Every conclusion below was reproduced in this
  session; the prior cycles' claims were treated as claims to attack.
- Nothing was fixed, no traceability was updated, nothing was frozen. The PM owns those decisions.

---

## Verdict

**CLEAN for Story 1.2.** No Story 1.2-owned blocker survives. F6-R4 and F6-R9 are genuinely fixed,
discriminate against reconstructed pre-fix trees, and the gates are green — including the five loaded
mutation runs that were red in cycle 6.

Seven non-blockers are carried, all of the same defect class the series has been draining, all failing
closed (a refusal or a retry, never a wrong destruction). One of them falsifies a *justification* in the
fix report rather than the fix itself, and is called out as such below.

| | verdict |
|---|---|
| **F6-R4 — the raced discriminator** | **fixed and holds under attack.** My own forced reproduction (`A4c`) lands on the read the fixed code actually performs and cannot make the judge lie; the same attack reproduces the harm exactly on an R4-reverted tree. |
| **F6-R9 — the silent reclamation** | **fixed and holds under attack.** Forced lost-take: 15/15 exactly-once on the fixed tree, 15/15 **silent destruction** on an R9-reverted tree. Verified at library level, at N-way contention, and at the CLI on all three exits a mutating run has. |
| gate integrity (F6-R7) | **genuinely fixed.** Six negative probes — three of them mine — all fail closed. shellcheck really runs here (ShellCheck 0.11.0 via nix); 12/12 clean, verified independently. |
| contract truth | the three rewritten passages match the code I read and the behaviour I measured. |
| F6-R5 (`-e` / `! -d`) | **non-blocker — but the fix report's stated reason for leaving it is false.** A deterministic forced interleaving *does* exist (§4.1). |
| F6-R6 (exhaustion) | non-blocker — confirmed by construction; untruthful, never unsafe. |
| F6-R8 (restore guard) | non-blocker — **reproduced deterministically**; residue only, cleaned up by the holder's own release. |
| pre-read hazard guard | **confirmed harmless**, as the fixer claimed — every non-plain-file shape yields the no-record moment, never a diagnosis. |
| `cat` as a declared tool | acceptable-documented; one consistency nit (§4.4). |
| new class member introduced by R4/R9 | **none.** R4 removes an observation; R9 adds no filesystem observation at all. |
| remaining class member found | **S1** — `afk_lock_reclaim` throws away the incarnation the judge already returned and re-reads the record. Fails closed; free repair. |
| mutual exclusion | **never broken** — peak simultaneous published owners = 1 across every attack. |
| no successor lock destroyed | **confirmed** in every forced interleaving. |
| anti-vacuity | see §7 |
| tree left unmodified | **confirmed** (§8) |

---

## 1. F6-R4 — one observation, one verdict

### 1.1 The mandated rerun of `A4b` is a VACUOUS PASS, and had to be replaced

`A4b-discriminator-race.sh` interposes on **`jq`**, keyed on the record path being `jq`'s last argument.
The fixed judge does not pass the record path to `jq` at all — it reads with `cat` and pipes the bytes in.
Rerunning `A4b` unchanged on the fixed tree therefore reports a pass in which the hook never fired:

    rc=1  owner_state=LIVE  owner_detail=pid 2217893  publish_waits=0

The outcome is correct, but it is not evidence: nothing was interposed. **A reviewer who reran only `A4b`
and reported "F6-R4 holds" would be reporting a fixture that no longer reaches its target.** I rebuilt the
attack against the read the fixed code performs.

### 1.2 `A4c` — the same hazard, on the read that now exists

`attack/A4c-cat-discriminator-race.sh`. A `cat` ahead of the real one, on the one read of exactly
`$LOCK/owner.json`: it releases the lock underneath the read (rename away, remove — what a release or a
winning reclaimer does), lets a **real** `lockctl park` successor take the freed path and publish a **real**
record into the same name, and only then returns nothing — which is byte for byte what the real `cat`
returns for a name that is gone. Not one line of the judge is replaced.

    fixed tree:        hook fired: YES   rc=1  owner_state=LIVE  owner_detail=pid 2430640  publish_waits=1
                       -> PASS: reported the LIVE successor
    R4-reverted tree:  hook fired: YES   rc=3  owner_state=UNKNOWN
                       owner_detail=the lock owner record could not be parsed
                       -> FAIL: a live successor's valid record reported as damaged,
                          operator told to "remove the reported lock directory by hand"

The attack is anti-vacuous by its own construction: it prints whether the hook fired, and it reproduces the
exact F6-R4 harm on the reverted tree.

### 1.3 The judge attacked directly, across every shape a record path can take

`attack/A4d-judge-shapes.sh` — the verdict from `afk_lock_judge_record`, and what a whole acquisition then
does with it, including how much of the publication-wait budget it spends:

| record path | judge verdict | acquisition | budget spent |
|---|---|---|---|
| absent | no owner record | rc 3 refuse | 120 (full watch) |
| **present, garbage** | **could not be parsed** | rc 3 refuse | **0 — instant** |
| **present, truncated JSON** | **could not be parsed** | rc 3 refuse | **0 — instant** |
| present, whitespace only | could not be parsed | rc 3 refuse | 0 |
| valid JSON, wrong shape (`null`, `[1,2,3]`) | unknown schema | rc 3 refuse | 0 |
| present, **empty (0 bytes)** | no owner record | rc 3 refuse | 120 |
| present, unreadable (mode 000) | no owner record | rc 3 refuse | 120 |
| directory / fifo / symlink / dangling symlink | no owner record | rc 3 refuse | 120 |

**A genuinely present-and-malformed record still refuses instantly and truthfully** — `publish_waits=0` is
the proof that no latency is spent on a diagnosis. That is the mandated check, and it passes.

**Can any path say "could not be parsed" about bytes that were never read?** No. The only route to that
string is reached after `raw` is non-empty, and `raw` is exactly what `cat` printed. Stronger than the fix
report claims: `raw="$(cat -- "$rec")" || raw=""` **discards partial bytes on a failed read**, so even a
`cat` that emits some bytes and then errors produces the no-record moment, never a false damage claim.

**Partial reads are not constructible in the first place.** `afk_state_file_write` writes
`$path.afk-tmp` in a subshell and `mv -f`s it onto the name; the rename is skipped entirely if the write
fails. Records are whole or absent. The fix report's premise holds.

**Records replaced between the read and the verdict cannot change the verdict.** After the `cat`, the judge
touches the filesystem no further — every subsequent step is `jq` over the captured bytes. Verified by
reading `afk_lock_judge_record` end to end.

**Two behaviour deltas** introduced by the single-read rule, neither a blocker:
- a **0-byte** record and an **unreadable** record are now the no-record moment (budget spent, then
  refuse) where before they were an instant "could not be parsed". Same refusal, same safety, ~3 s later
  and less precisely worded. Neither is constructible by the library itself.
- `jq` stderr leaks on a shape-valid-but-wrong record (`[1,2,3]` → `Cannot index array with string`).
  Pre-existing and identical on the reverted tree; stdout JSON is unaffected.

### 1.4 The pre-read hazard guard — the fixer's residual 3, confirmed

`[[ ! -f "$rec" || -L "$rec" ]]` runs before the read. Every non-plain-file shape in the table above
resolves to the **no-record moment** — never to a diagnosis. Racing it can therefore only cost another
look, exactly as the fix report claims. **Confirmed, not merely accepted.**

---

## 2. F6-R9 — a reclamation reports itself

### 2.1 The mandated rerun of `A9b` cannot observe the fix

`A9b-silent-reclaim-forced.sh` reruns and still forces the interleaving it was built for (the contender
takes the freed path: `stolen`, and the abandoned record is destroyed). But the `reclaim` verb it calls
prints only `rc`, `inc` and `lock_inc_after` — **no reclamation field** — and the script's closing lines are
hardcoded prose asserting the pre-fix conclusion. It cannot distinguish a fixed tree from a broken one.
Replaced with a measuring version.

### 2.2 `A9d` — forced lost take, measured

`attack/A9d-forced-lost-take.sh`, over the repo's own `reclaim-losing-take` verb (the **real**
`afk_lock_take` runs and really loses to a contender that took the path first):

    fixed tree     : rounds=15  exactly-once=15  silent=0  duplicated=0
                     sample: rc=3 reclaimed=true reports=1 stolen=stolen
                             detail='pid 3034421 is no longer running'
    R9-reverted    : rounds=15  exactly-once=0   silent=15 duplicated=0

Perfect discrimination. Every round is precondition-checked (the contender really stole the path, the
abandoned record really was destroyed) before its outcome is counted, so a fixture that stopped firing
would be reported, not silently counted as a pass.

### 2.3 `A9c` — N-way simultaneous reclaim

`attack/A9c-nway-reclaim.sh`, 8 real processes racing to reclaim one abandoned lock, 25 rounds:

    rounds=25 procs=8  total_reports=25 (expected 25)  violations=0

Exactly one reclamation report per destroyed lock across the whole fleet — never zero, never two — and
mutual exclusion never broken.

Reported honestly: **this test does not discriminate against the R9-reverted tree** (25/25 there too),
because in a natural race the reclaimer that destroys the lock almost always also wins the take that
follows. That is precisely why the forced fixture in §2.2 is the one that matters, and why the fixer
needed one.

### 2.4 Exactly-once across every reclaim outcome

- **reclaimer wins the take (rc 0)** — CLI probe §2.5(a): one finding.
- **reclaimer loses the take (rc 3)** — §2.2: one finding, 15/15.
- **reclaimer loses to a live owner (rc 1)** — the report is written before `afk_lock_take` is even called,
  so the rc cannot suppress it; `afk_lock_refusal` emits it on the rc-1 path.
- **N-way simultaneous** — §2.3: exactly one per destroyed lock.
- **reclaimer dies between destruction and report** — still silent. Unfixable in-process; the
  abandoned-marker rules are what recover it. Documented, agreed, non-blocker.
- **repeated reclaim in one acquisition** — two destructions produce two findings. That is what "one per
  destroyed lock" means, and it is the fix report's own residual 5. Correct.

**No double-report is constructible.** `afk_lock_reclamation_findings` has exactly two reachable call
paths per run, and they are mutually exclusive by control flow: the recovery branch
(`afk-commands.sh:606` refusal **or** `:609` direct) always `return`s, so the converged branch
(`:729` refusal **or** `:751` direct) is unreachable in the same process. `afk_lock_acquire` is called from
exactly those two sites and nowhere else, so its reset of `AFK_LOCK_RECLAIMED` cannot wipe a report
already earned. Verified by reading every call site.

### 2.5 CLI-level verification — including an exit no retained fixture covers

`cli/probe.sh` (the mutation suite's own preamble, my scenarios appended; scratch only):

    PROBE the run converged over the abandoned lock ......... CONVERGED
    PROBE and reported the destruction exactly once ......... 1
    PROBE naming the owner it proved was gone ............... "pid ..."
    PROBE the journal really is open ....................... IN_PROGRESS
    PROBE an abandoned lock was stranded alongside it ....... ok
    PROBE the recovery exit reports the destruction once .... 1
      [probe] result=RECOVERED reason=OPERATION_RECOVERED reclaimed=1
    39 passed, 0 failed

**(b) is the interesting one.** The retained `f6silentreclaim` exercises the *refusal* exit and the
retained suites exercise the *converged* exit; **no retained fixture drives a reclamation through the
interrupted-journal recovery branch**, which is a different `afk_lock_acquire` call site and a different
emission point. I checked it specifically because that branch emits its findings *before*
`afk_recover_interrupted`, and the converged branch's own comment warns that a re-evaluation rebuilds the
finding set from the filesystem and would wipe them. It holds: `afk_evaluate_installation` (the only caller
of `afk_result_reset`) is not reached between the emission and the emit on that path. **Confirmed by
construction, not by reading alone.**

### 2.6 The fixer's own extra finding — reporting inside `afk_lock_refusal`

Evaluated and **correct**. It is the change that makes rc-1 and rc-3 reclaimers report at all, it is placed
before the refusal's own findings so ordering is stable, and it cannot double-report (§2.4). The declared
consequence — consumers counting findings on a refusal see one more than before — is real and is the right
trade: a destroyed lock that goes unreported is the defect being fixed.

---

## 3. Interactions — the new judge and the new report against the older fixes

`attack/I2-interactions.sh`: real contenders acquiring the same lock at a barrier while an abandoned lock is
stranded underneath them **and** a record-level churner carries `owner.json` out of the lock and back
continuously — which is the F6-R2/R3 vanished-record moment and the F6-R1 publication window running
without pause, forced through the reclamation path at the same time.

    rounds=12 procs=5   (abandoned lock + record churn every round)
      abandoned locks stranded             : 12
      acquisitions that took the lock      : 1
      acquisitions reporting a reclamation : 1
      PEAK SIMULTANEOUS PUBLISHED OWNERS   : 1   -> mutual exclusion INTACT
      false 'could not be parsed'          : 0
      F6-R5 'not a directory' verdicts     : 0

One acquisition took the lock and it is the one that reported the reclamation; the rest refused after
spending their budget on a record that kept vanishing, which is the fail-closed outcome. Nothing was
destroyed by a loser.

*Method note, in the interest of not overclaiming:* my first version of this test used a churner that
renamed the whole **lock directory** away, and its "peak holders" number was meaningless — it was counting
acquisitions across a round rather than simultaneous ones, against an adversary that was deleting the mutex
itself. It is discarded; the numbers above come from the corrected fixture, which measures peak
**simultaneously published owners** through the repo's own `contend` verb.

The high-volume version of the same interaction is §4.1's natural-rate measurement.

---

## 4. Residual risks — explicit disposition

### 4.1 F6-R5 (`afk_lock_evaluate`'s `-e` / `! -d` pair) — **acceptable-documented, but the fix report's reason is FALSE**

The fix report leaves F6-R5 undone and states why:

> there is no deterministic forced interleaving available: both tests are shell builtins with no fork
> between them, so nothing external can be scheduled there, and forcing it would mean replacing the
> function under test.

**That is refuted.** A `DEBUG` trap is a scheduling point bash itself provides *between simple commands*,
and it needs no fork and replaces no line of `afk_lock_evaluate`. `attack/R5-debug-trap.sh`:

    a real lock is held, incarnation inc-3542216-...
    trap fired between the two tests: YES
    state=UNKNOWN
    detail=the lock path is not a directory
    ==> F6-R5 REPRODUCED DETERMINISTICALLY

A lock legitimately handed over between the two builtins is reported as a malformed lock path → UNKNOWN →
*"remove the lock directory by hand"*. Same class, same harm shape as everything this series has fixed.

This matters procedurally rather than technically: the fixer's own rule was *"a deterministic regression is
the condition for taking an optional item"*, and the condition **was** satisfiable. The finding's severity
is unchanged — it stays a **non-blocker**, because its natural rate is nil (below) and the outcome is a
refusal, never a destruction. But the recorded justification should not be carried forward as fact.

**Natural-rate re-measurement.** `A5b-natural-rate.sh`, 100 000 adversarial observations against a
faithful rename-installing adversary. My first pair of runs was executed while the box was carrying the
loaded mutation gates at load average ~11 and **produced 0 on both trees** — including the reverted one,
which should have misverdicted. That run reproduced nothing and is discarded as inconclusive rather than
reported as a pass. Rerun on a quiet box (load ~3):

| tree | 100 000 observations | F6-R4 misverdicts | F6-R5 `not a directory` |
|---|---|---|---|
| **fixed** | | **0** | **0** |
| **F6-R4 reverted** | | **10** — of which **1** had a valid successor record present afterwards | 0 |

The fixed tree is clean; the reverted tree misverdicts at ~1 in 10 000, and one of those ten is the
harmful shape — a live successor's valid record called damaged, the operator told to remove it by hand.
Cycle 6 measured 6 in 40 000, the same order of magnitude.

**F6-R5's natural rate is 0 in 100 000 on both trees**, which independently confirms the cycle-6 figure and
is why it stays a non-blocker despite the deterministic reproduction above.

### 4.2 F6-R6 (attempt-ceiling exhaustion) — **acceptable-documented, non-blocker**

Confirmed by construction (`attack/R6-exhaustion.sh`), with the reclamation forced to keep returning 3,
which is what a lock that keeps changing hands produces naturally:

    acquire rc=3
    owner_state=DEAD
    owner_detail=pid 2867969 is no longer running
    reason a run would report: OPERATION_LOCK_OWNER_UNVERIFIABLE
    action: Confirm no lifecycle operation is running ... then remove the reported lock
            directory by hand.

The kit has just proven the owner dead and reclaimable, and then tells an operator the owner cannot be
judged. **Untruthful, never unsafe** — the outcome is a refusal that destroys nothing. Unchanged from the
cycle-6 classification.

### 4.3 F6-R8 (nesting restore guard) — **acceptable-documented, non-blocker**

**Reproduced deterministically** (`attack/R8-nesting.sh`), again with a `DEBUG` trap scheduled between the
guard's test and its act, replacing no line of the guard:

    release rc=1  guard raced: YES
    lock path is a live contender's dir: yes
    stale directories NESTED inside the live lock: 1
    ==> lock/lock.released.inc-3706170-...   contents: lock.released.inc-... marker

Residue only, and self-limiting: the contender's own record survives untouched, mutual exclusion is intact,
and the nested directory is carried away by the contender's own release (which renames the whole lock
directory aside and removes it). Worth noting that this too has a deterministic reproduction available,
should a later cycle want a regression for it.

### 4.4 `cat` as a declared tool dependency — **acceptable-documented**

`afk_require_tools` now lists `cat`, which was already used unconditionally. One consistency nit, not a
defect: `mkdir`, `rm`, `ln` and `chmod` are used unconditionally **on the lock path itself** and remain
undeclared, so the list is now inconsistent rather than complete. Harmless in practice — coreutils ships
them together — and out of Story 1.2's scope.

### 4.5 The pre-read hazard guard — **confirmed harmless** (§1.4)

### 4.6 Two findings for two destroyed locks — **correct, not a residual**

That is the definition of "exactly one per destroyed lock". Agreed with the fix report.

### 4.7 A reclaimer killed between destruction and report — **acceptable-documented**

Out of reach of any in-process report. The abandoned-marker rules recover it. Agreed.

---

## 5. Gate integrity — the shellcheck sub-gate, negative-probed independently

**shellcheck genuinely runs on this host.** Section 0, executed standalone:

    PASS shellcheck runs here: nix 0.11.0
    PASS shellcheck clean: dispatch.sh / make-stamp.sh / usage-check.sh / github-health.sh
    PASS shellcheck clean: agent-flow-kit / afk-common.sh / afk-source.sh / afk-inventory.sh
                           afk-commands.sh / afk-plan.sh / afk-mutate.sh / lockctl-helper.sh
    13 passed, 0 failed

**12/12 shipped scripts clean, confirmed independently.**

Six negative probes against a scratch copy of section 0 — the first two reproduce the fixer's, the last
three are mine:

| probe | result |
|---|---|
| P1 no shellcheck, no nix on PATH | `0 passed, 0 failed, 12 skipped` + *"skipped checks computed no verdict — they are not passes"* |
| P2 nix present, refusing the experimental feature (**the live pre-fix case**) | same — SKIP loudly |
| P3 checker identifies itself, then exits 1 with no findings | `1 passed, 12 failed` — *"checker exited 1 with no findings — it did not run"* |
| **P4 (mine)** checker exits **0** but prints findings | `1 passed, 12 failed` — *"exit 0 but the checker still reported"* |
| **P5 (mine)** checker crashes (exit 2) on every file | `1 passed, 12 failed` — *"checker exited 2"* |
| **P6 (mine)** impostor exits 0 on `--version` but does not identify as ShellCheck | `0 passed, 0 failed, 12 skipped` — not accepted, falls through |

**A PASS now proves execution.** The one boundary worth stating plainly: a binary that *identifies itself
as ShellCheck and then exits 0 silently on every file* would still pass vacuously. That is an actively
lying checker, not a checker that failed to start, and it is outside what this gate can or should detect.
F6-R7 is closed.

---

## 6. Defect-class sweep — every observe-then-act site on the lock path

Re-swept `lib/afk-mutate.sh` in full, plus every lock-touching line of `afk-common.sh` and
`afk-commands.sh`.

**No new class member was introduced by R4 or R9.** R4 *removes* an observation (the second stat is gone);
R9 adds no filesystem observation at all — it moves a shell assignment earlier and reads only shell state
at emission time.

| # | site | shape | direction of failure | disposition |
|---|---|---|---|---|
| **S1** | `afk_lock_reclaim:492-495` — judge, then **re-read** the record with `afk_lock_incarnation_at` | observe-then-observe at the one place the kit destroys another process's lock | **fails closed** | **non-blocker, free repair** |
| S2 | `afk_lock_evaluate` `-e` then `! -d` | test-then-test | false diagnosis → refusal | F6-R5, §4.1 |
| S3 | `afk_lock_release:689` / `afk_lock_reclaim:527` restore guard `[[ -e ]] \|\| mv` | test-then-act | nested residue | F6-R8, §4.3 |
| S4 | `afk_lock_release:684` incarnation proof before the `mv` | observe-then-act | a live owner is never judged dead by a reclaimer, so unreachable | benign |
| S5 | `afk_lock_reclaim:514` `[[ -e "$aside" ]]` then `mv` | test-then-act | `aside` is this process's own unique incarnation — uncollidable | benign |
| S6 | `afk_run_mutation:638` `afk_lock_state` then `afk_lock_evaluate` | observe-then-observe | lock gone → NONE → falls through to acquire | benign |
| S7 | `afk_lock_judge_record` pre-read `-f`/`-L` guard | test-then-read | no-record moment only | **confirmed harmless**, §1.4 |
| S8 | `afk_lock_acquire` `[[ ! -e ]]` after a failed take | observe-then-loop | retry | benign |
| S9 | `afk_lock_marker_claim` `[[ -e "$marker" ]]` after a failed `ln` | observe-after-act | rc 2 → caller's `*)` → observe again | benign |

### S1 — the one remaining class member worth naming

`afk_lock_reclaim` calls the judge, reads its three fields into `state`, `detail` and a variable **literally
named `unused_inc`** — and then throws that incarnation away and asks the filesystem for it again:

    judged="$(afk_lock_judge_record "$AFK_LOCK_DIR/owner.json")"
    IFS='|' read -r state detail unused_inc <<<"$judged"
    if [[ "$state" != "DEAD" ]] ||
       [[ "$(afk_lock_incarnation_at "$AFK_LOCK_DIR/owner.json" 2>/dev/null)" != "$stale_inc" ]]; then

Two looks, two instants — the exact shape F6-R4 was about, surviving in the function F6-R9 edited.

Forced (`attack/S1-second-observation.sh`, a real successor's record published between the two looks):

    interposed between the judge and the re-read: YES
    afk_lock_reclaim rc=3   (observe again)
    successor's lock still intact        : YES
    reclamation reported                 : false
    residue                              : 0
    ==> FAILS CLOSED

It can only ever cost a retry: incarnations are unique per acquisition, so a *newer* record can never match
`stale_inc`, and the mismatch branch removes the marker and returns 3. **Not a blocker.** The repair is free
and needs no new observation — the judge already returned exactly this value, and for a `DEAD` verdict it
has already passed `afk_lock_incarnation_valid`. Recommended for a later cycle; not Story 1.2-blocking.

---

## 7. No regression in the retained scenarios

The concurrency gate ran all thirteen sections, including the two new ones, with **207 passed, 0 failed**
on three separate runs:

    1. PROTOCOL — at most one owner, under a barrier
    2. PROTOCOL — a stale observation never grants ownership
    3. PROTOCOL — a former owner releases only what it installed
    4. PROTOCOL — an owner that is alive is never reclaimed
    5. RECORD   — a pid that was recycled is not its own former owner
    6. RECORD   — a reboot is decidable, another host is not
    7. RECORD   — missing, partial or unreadable metadata fails closed
    8. PROTOCOL — a reclaimer killed mid-reclamation does not brick the lock
    9. RECORD   — the incarnation this kit writes is unique and well shaped
   10. PROTOCOL — a lock caught mid-publication is waited on, not condemned   (F6-R1 window suite)
   11. PROTOCOL — a record seen and then found gone is a moment, not a verdict (F6-R2/R3)
   12. PROTOCOL — one observation, one verdict (the discriminator)            (F6-R4, new)
   13. PROTOCOL — a reclamation is never silent                               (F6-R9, new)

- **Mutual exclusion never broke** — §1 of the gate, plus peak = 1 in every attack I ran.
- **No successor lock was ever destroyed** — forced in `A4c`, `S1` and `I2`; intact every time.
- **Liveness is intact** — stale locks are still reclaimed (§4, §8 of the gate, and the CLI probes), and a
  live reclaimer still yields rc 1 (§4).
- The mutation gate carries **88 F6 assertions**, and the assertion that was red in cycle 6 —
  *"F6 the abandoned lock is still reclaimed exactly once"* — **passes under load** on every run.

---

## 8. Anti-vacuity — the new regressions on reconstructed pre-fix trees

Three full copies of the checkout under `mktemp`, each with exactly one reviewed hunk reverted in
`lib/afk-mutate.sh` and nothing else. I reconstructed the pre-fix hunks myself from the cycle-6 review's
quoted code rather than copying the fixer's trees; each diff is a single hunk (9, 8 and 17 changed lines
respectively) and all three parse under `bash -n`.

### 8.1 Concurrency gate

| tree | result | matches the fix report's claim |
|---|---|---|
| fixed | **207 passed, 0 failed** (×3 runs) | yes |
| F6-R4 reverted | **202 passed, 5 failed** | yes — exactly 202/5 |
| F6-R9 reverted | **204 passed, 3 failed** | yes — exactly 204/3 |
| both reverted | **199 passed, 8 failed** | yes — exactly 199/8 |

**The discrimination is exact — each reverted tree fails only its own assertions:**

    R4 reverted (5):
      a record read once and found gone is reported as a record that is not there
        expected 'the lock carries no owner record', got 'the lock owner record could not be parsed'
      never as a record that could not be parsed, whatever arrived afterwards      expected 0, got 1
      an acquisition that read a vanished record while a successor published waits expected 1, got 3
      naming the live owner that now holds the lock                                expected LIVE, got UNKNOWN
      and never calls the successor's valid record unparseable                     expected 0, got 1

    R9 reverted (3):
      and the destruction is reported even though the take was lost                expected true, got false
      exactly once, for the one lock that was destroyed                            expected 1, got 0
      naming the owner it proved was gone                             missing substring: no longer running

5 + 3 = 8, and the both-reverted tree fails exactly those eight. **No assertion fires on the wrong revert,
and none is a coincidence of count.** The fix report's per-fix discrimination claim is confirmed
independently.

### 8.2 Mutation gate under load

The mutation gate does not discriminate F6-R4 at all (no mutation assertion depends on it) — the fix
report says so, and my runs agree. It discriminates F6-R9 only **under load**, which is why the cycle-6
failure was 2-in-5 rather than deterministic.

---

## 9. Gate results — every gate rerun in this session, on the unmodified tree

| gate | result | rc |
|---|---|---|
| `bash tests/lifecycle-tests.sh` | **443 passed, 0 failed** | 0 |
| `bash tests/lifecycle-concurrency-tests.sh` (3 runs) | **207 passed, 0 failed** every time | 0 ×3 |
| `bash tests/lifecycle-mutation-tests.sh` — **5 runs UNDER CONCURRENT LOAD** (6 further mutation suites in parallel per run, 12-core host) | **414 passed, 0 failed — 5 of 5** | 0 ×5 |
| `bash tests/run-tests.sh` | **231 passed, 0 failed** (section 0 executed shellcheck for real: 13/13) | 0 |
| shellcheck via the repaired sub-gate (ShellCheck 0.11.0 through nix) | **12/12 shipped scripts clean** | 0 |
| `git diff --check` | clean, no output | 0 |

**The cycle-6 blocker is gone.** `f6contend4`'s *"F6 the abandoned lock is still reclaimed exactly once"* —
which failed 2 runs in 5 under load in cycle 6 and made `run-tests.sh` 229/1 — **passes in all five of my
loaded runs**, and `run-tests.sh` is 231/0.

Load note, for honesty about conditions: runs 1, 2, 4 and 5 executed at load average ~11-14, which is the
profile the fix report used. **Run 3 executed at load average up to 52**, because I briefly had the
anti-vacuity suites running concurrently as well. It passed 414/0 anyway; that makes it stronger evidence
than the mandate asks for, not weaker, and it is reported here rather than quietly dropped.
Fourteen R9-reverted mutation runs under load in this session (2 measured + 12 parallel load suites):

| result | count | which assertions |
|---|---|---|
| **410 passed, 4 failed** | 10 | the four deterministic `f6silentreclaim` assertions |
| **409 passed, 5 failed** | 2 | the same four **plus** `f6contend4`'s *"F6 the abandoned lock is still reclaimed exactly once"* |

The four that always fail:

    F6 a reclamation that lost the take is still reported        expected 'true', got 'false'
    F6 exactly once, for the one abandoned lock it destroyed     expected '1', got '0'
    F6 the reclamation report says what it destroyed             should not equal ''
    F6 naming the owner it proved was gone                       missing substring: pid

**The fix report's "409/5" is reproduced, but it is not reproducible on demand.** The deterministic floor
is **410/4**; the fifth assertion — the one that was red in cycle 6 — is load-sensitive and fired in **2 of
14** runs here, against cycle 6's 2-in-5. That is a refinement of the fixer's claim rather than a
contradiction: `f6contend4` is exactly the intermittent detector, which is why the deterministic
`f6silentreclaim` fixture had to be added. A future cycle should quote 410/4 as the R9 discrimination floor.

On the fixed tree, across 5 measured loaded runs plus 30 parallel load suites: **414/0, every single one.**

---

## 10. Findings, classified

### Story 1.2-owned blockers

**None.** No blocker survives this review.

### Non-blockers (all pre-existing class members; none introduced by R4 or R9)

| # | finding | evidence | disposition |
|---|---|---|---|
| N1 | **The fix report's stated reason for leaving F6-R5 is false** — a deterministic forced interleaving does exist, via a `DEBUG` trap between the two builtins, replacing no line of the function | `attack/R5-debug-trap.sh` — reproduced | **acceptable-documented**, but the *reason* must not be carried forward as fact |
| N2 | F6-R5 itself — `-e` then `! -d`, a handed-over lock reported as a malformed lock path | as above; natural rate **0 in 100 000** | acceptable-documented |
| N3 | F6-R6 — exhaustion reports `OPERATION_LOCK_OWNER_UNVERIFIABLE` carrying a detail that proves the owner dead | `attack/R6-exhaustion.sh` — confirmed | acceptable-documented (untruthful, never unsafe) |
| N4 | F6-R8 — the restore guard nests a stale directory inside a live contender's lock | `attack/R8-nesting.sh` — reproduced deterministically | acceptable-documented (residue only, self-cleaning) |
| N5 | **S1** — `afk_lock_reclaim` discards the incarnation the judge already returned (`unused_inc`) and re-reads the record: a surviving observe-then-observe at the destruction site | `attack/S1-second-observation.sh` — **fails closed** | acceptable-documented; free repair recommended for a later cycle |
| N6 | Two behaviour deltas from the single-read rule: a 0-byte and an unreadable record are now the no-record moment (budget spent, then refuse) rather than an instant diagnosis | `attack/A4d-judge-shapes.sh` | acceptable — neither is constructible by the library; same refusal, same safety |
| N7 | `afk_require_tools` now declares `cat` while `mkdir`, `rm`, `ln`, `chmod` — all used unconditionally on the lock path — remain undeclared | read | acceptable (out of Story 1.2 scope) |

### Method findings about the retained evidence (not code defects)

| # | finding |
|---|---|
| M1 | **`A4b-discriminator-race.sh` is now a vacuous pass** on the fixed tree — it hooks `jq`, which the fixed judge no longer uses for the read. Rerunning it proves nothing; it needs retargeting to `cat` or retiring. |
| M2 | **`A9b-silent-reclaim-forced.sh` cannot observe the fix** — the `reclaim` verb it calls prints no reclamation field, and the script's conclusion is hardcoded prose. |
| M3 | The R9 mutation-gate discrimination floor is **410/4**, not 409/5; the fifth assertion is load-sensitive (2 of 14 runs here). |

---

## 11. Tree-unmodified proof

    git rev-parse HEAD              15a97baf1303d4e76dc29aa6417badd27e449675   (unchanged)
    git status --short              byte-identical to the pre-review snapshot
    git diff --check                clean, no output, rc 0
    find . -newermt <review start>  empty — nothing in the repository was written

Content hashes of every file this review could plausibly have touched, recorded after all work:

    1574c7ff166292ecbef9c960d11877e0fe52ac4cf669a0ff88f24d9028dd76b0  lib/afk-mutate.sh
    6f18568ebbe9f5f7aedd51bdf68551d8ff5db9d5d001217289255e3d4d189c05  lib/afk-commands.sh
    11830eed8d2d2b8468e3ddb2819ac6352191f7129ea2d14092bc6d37730a6061  lib/afk-common.sh
    aeaf9cf37c4120a3fc182d86b4d9a3d5b6568c17fa8d9de04c40593e23534b8e  docs/LIFECYCLE-CONTRACT.md
    cc79bc68e67e0c966b62fe6cb3d775ab2db27b4f51d8bf7a7ec0fd27c5a49e6c  tests/run-tests.sh
    ff2409e09c86bd808ac417f72cc445fb690653416f1b85dd73f1fbd644ba61a5  tests/lockctl-helper.sh
    bb3bb884760cc634fd0d56dcbd9aba53411535c3b91b2dfb29373ac701e7719c  tests/lifecycle-tests.sh
    e6a51c19513b5644062dc7c13374e813989b1bf6ae1dfba84b2b6a57c222025f  tests/lifecycle-mutation-tests.sh
    2ab59c577e6bfbab0606dc1e1dbfadb6f48287df6f4235fcadf2b1cd5ddda3c4  tests/lifecycle-concurrency-tests.sh

Every reproduction, forced interleaving, reconstructed pre-fix tree and probe harness lives under
`mktemp` roots or the session scratch directory. **No repository file was modified, and no evidence file
was touched.**

---

## 12. What I did not do

I fixed nothing, updated no traceability, and froze nothing. N1-N7 and M1-M3 are handed to the PM as
recorded findings, not as work in progress.
