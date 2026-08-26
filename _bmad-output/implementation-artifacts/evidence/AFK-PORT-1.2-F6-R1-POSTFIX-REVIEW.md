# AFK-PORT-1.2 — independent adversarial review of the F6-R1 publication-window fix

- Mode: WORKER (dispatched) · read-only · repository `/home/devbox/repos/jlengelbrecht/agent-flow-kit`
- requested_persona: `dev` · resolved persona: **BMAD DEV (Amelia, Senior Software Engineer)**
- persona_source: `.agents/skills/bmad-agent-dev/SKILL.md` + resolved `customize.toml`
- Identity proof (recomputed in this session):
  `{ sha256sum .agents/skills/bmad-agent-dev/SKILL.md; sha256sum .agents/skills/bmad-agent-dev/customize.toml; } | sha256sum`
  = `07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee` — **matches expected; fail-closed check passed**
- Route: as stamped (`claude` / `claude/strong` / high effort / subscription, metered=false). Not substituted.
- Fresh reviewer: no prior Story 1.2 session was resumed and no previous reviewer's conclusion was reused.
  Every claim below was reproduced in this session, in `mktemp` roots outside the repository.

---

## Verdict

**NOT CLEAN for Story 1.2.** Two Story 1.2-owned blockers.

The F6-R1 fix itself is correct, well-bounded and genuinely regression-covered — I attacked it directly
and could not break it. But the defect F6-R1 named is a *class*, not a single site, and the fix closed
exactly one of its three reachable sites. The other two are still live, still produce
`OPERATION_LOCK_OWNER_UNVERIFIABLE` with **"remove `<lock>` by hand"**, and I reproduced one of them with
the real `agent-flow-kit update` binary at **12 out of 256 (4.7%)** of ordinary contended runs, with a
successor provably holding the lock at that instant.

| | verdict |
|---|---|
| F6-R1 (the fix under review) | **holds under attack** — see "What the fix does correctly" |
| F6-R2 lost arbitration marker (implementer's self-reported residual) | **Story 1.2-owned BLOCKER** — reproduced, library and CLI |
| F6-R3 owner record vanishes between the existence test and the read | **Story 1.2-owned BLOCKER** — reproduced, library level, undisclosed |
| new F6-R1 regressions | **anti-vacuous** (18 concurrency + 7 mutation failures on a reconstructed pre-fix tree, deterministic) |
| all gates | **green** — 443 / 377 / 146 / 230, all 0 failed, `git diff --check` clean |
| tree left unmodified | **confirmed** — `git status --short` identical, HEAD unchanged, no repo file newer than this session's first scratch write |

---

## What the fix does correctly (attacked, held)

`AFK_LOCK_PUBLISH_WAIT_SLICE=0.02` / `AFK_LOCK_PUBLISH_WAIT_SLICES=120`, spent across a whole
acquisition in `afk_lock_evaluate_settled` (`lib/afk-mutate.sh:556`), consumed only from
`afk_lock_acquire` (`lib/afk-mutate.sh:575`).

1. **Window forced open, 8 contenders raced through it** (`lockctl publish-slowly` + 8 ×
   `acquire-announced`, all 8 provably inside the window before the winner published):

       owner: inc=inc-38658-… rc=0 published, released=true
       c1..c8: rc=1  owner_state=LIVE  owner_detail="pid 38658"  publish_waits=11–12
       residue: none

   Eight for eight got `CONCURRENT_OPERATION_IN_PROGRESS`. Not one saw "no owner record", not one was
   told to remove anything.

2. **A lock that never publishes still fails closed, truthfully and boundedly:**

       elapsed_ms=3557  rc=3  publish_waits=120
       owner_detail="the lock carries no owner record and none appeared while it was waited on"
       lock left exactly where it was; reclaimed=false

3. **Permanently unjudgeable records cost zero latency** — no wait tax:

       not JSON / {} / future schema  → publish_waits=0, ~120 ms (process startup only)
       foreign host                   → publish_waits=0, FOREIGN, lock left intact

4. **The budget cannot be extended or starved into unbounded behaviour.**
   Environment override attempt (`AFK_LOCK_PUBLISH_WAIT_SLICES=100000 AFK_LOCK_PUBLISH_SLICES_LEFT=100000
   AFK_LOCK_PUBLISH_WAIT_SLICE=5`) changed nothing: still `publish_waits=120`, 3596 ms. The variables are
   assigned unconditionally at source time, so no environment value reaches them.
   Under an adversary churning an ownerless lock directory in and out of existence in a tight loop,
   12 acquisitions: max wall clock **629 ms**, max waits **9** — the four-attempt ceiling in
   `afk_lock_acquire` plus the shared budget hold.

5. **The fallback for a `sleep` that refuses fractions is bounded and still adequate.** With a
   fraction-refusing `sleep` shimmed onto `PATH`: still `publish_waits=120`, 4661 ms, and a contender
   held inside a real window still waited it out and returned `rc=1 LIVE` (`publish_waits=4`).

6. **Read-only paths pay nothing.** `verify` judges nothing (`afk_lock_state` existence check only,
   `lib/afk-mutate.sh:1063`); `status`/`verify` against an ownerless lock returned in 1.3 s / 2.3 s —
   baseline command cost, no 3 s wait. `afk_lock_evaluate_settled` is called from `afk_lock_acquire`
   and nowhere else.

7. **Everything the retained F6 review listed as holding, still holds** (re-attacked independently):

   | scenario | result |
   |---|---|
   | 25 rounds × 10-way simultaneous reclaim of one stale lock | 25 × rc=0 (exactly one winner per round), 225 × rc=1, peak owners **1** every round, **zero residue** |
   | former owner releases after a successor acquired | `rc=1 released=false`, successor's incarnation intact |
   | release claiming a bogus incarnation | `rc=1 released=false`, lock intact |
   | repeated reclaim of an already-reclaimed incarnation | `rc=0`, then `rc=3`, `rc=3` — never double-reclaims |
   | owner SIGKILLed holding the lock | next acquire `rc=0 reclaimed=true` "pid N is no longer running", zero residue |
   | reclaimer SIGKILLed holding the arbitration marker | abandoned marker recovered, `rc=0 reclaimed=true`, zero residue |
   | pid-reuse shape (real pid 1, wrong start identity) | `DEAD` — "pid 1 belongs to a different process now" |
   | boot mismatch / host mismatch | `DEAD` (reclaimed) / `FOREIGN` (`rc=3`, record byte-identical afterwards) |
   | identity moves between observation and reclaim | observer `rc=3`, successor untouched |
   | lock path is a symlink to `/etc` / a regular file | `UNKNOWN` "the lock path is not a directory", `rc=3`, target untouched |
   | contender SIGKILLed inside the bounded wait | winner's window untouched, publishes and releases normally, zero residue |
   | 256 real `agent-flow-kit update` runs, 16 rounds | exactly 1 convergence per round, no lock left behind, no residue, `verify` true in every round |

---

## BLOCKER F6-R2 — a loser is told to remove a live successor's lock when the arbitration marker vanishes

**File:** `lib/afk-mutate.sh:426` (`afk_lock_reclaim`), the `rc=1` branch of `afk_lock_marker_claim`;
guidance decided at `lib/afk-commands.sh:512-528` (`afk_lock_refusal` rc=3).
This is the residual the implementer self-reported and asked the reviewer to judge.

### Mechanism

`afk_lock_marker_claim` returns 1 when `ln` fails **and** the marker still exists. `afk_lock_reclaim`
then re-reads that marker to decide what the competing reclaimer is:

```
1) judged="$(afk_lock_judge_record "$marker")"
   case "$state" in
     LIVE) … return 1 ;;            # safe: CONCURRENT_OPERATION_IN_PROGRESS
     DEAD) discard; return 3 ;;     # safe: observe again
     *)    AFK_LOCK_OWNER_DETAIL="a reclamation of this lock was started by a process
                                   that cannot be judged"
           return 2 ;;              # -> afk_lock_acquire returns 3
   esac
```

The marker lives **inside** the lock directory, so the winning reclaimer's
`mv -- "$AFK_LOCK_DIR" "$aside"` takes it away — and the winner's very next act is `afk_lock_take`.
A loser whose `ln` failed a moment before that rename judges a marker that is already gone,
`afk_lock_judge_record` returns `UNKNOWN|the lock carries no owner record|`, and the `*)` arm fires.
`afk_lock_acquire` maps `2 → return 3`, and `afk_lock_refusal 3` emits
`OPERATION_LOCK_OWNER_UNVERIFIABLE` with **"Confirm no lifecycle operation is running on this
installation, then remove `<lock>` by hand."** — while the successor holds it.

This is the *same* defect F6-R1 named, on the neighbouring path, with the same operator consequence.
The fix does not reach it: `afk_lock_evaluate_settled` matches only the exact detail
`$AFK_LOCK_NO_RECORD_DETAIL` on `$AFK_LOCK_DIR/owner.json`, and `afk_lock_reclaim` judges the marker
directly, never through the settled wait.

### Reproduction — real concurrency, library level

Stale lock, one live reclaimer parked holding it, 16 contenders arriving on a stagger of 0–80 ms
(the arrival pattern a same-instant barrier cannot produce), 30 rounds = 480 acquisitions:

    total_acquisitions=480   rc=0: 22   rc=1: 442   rc=3: 16
    told_to_remove_a_live_lock = 16

with, per refusal, the holder proven alive and the lock proven present:

    ROUND 27 c12  rc=3  owner_state=DEAD  publish_waits=0
      owner_detail="a reclamation of this lock was started by a process that cannot be judged"
      holder_process_alive=yes  lock=present  owner_inc=inc-276497-ba93c1d4aae44

A second staggered run (30 rounds × 16, no parked holder) produced 21 rc=3 out of 480: 14 with this
detail and 7 with the F6-R3 detail below.

### Reproduction — the real CLI

16 rounds × 16 staggered `agent-flow-kit update --json` processes against a real installation carrying
one abandoned lock:

    TOTAL=256  converged=16  concurrent=228  unverifiable=12  unavailable=0  told_to_remove=12

All 12 carry this exact payload:

```json
{"reason":"OPERATION_LOCK_OWNER_UNVERIFIABLE",
 "next":"Confirm no lifecycle operation is running on this installation, then remove
         …/.local/state/agent-flow-kit/lock by hand. No mutation was attempted.",
 "ev":["another operation holds the installation lock",
       "…/lock: a reclamation of this lock was started by a process that cannot be judged"]}
```

12 of 256 real update runs (**4.7%**), in 9 of 16 rounds. Note the evidence array is self-contradicting:
it says "another operation holds the installation lock" and then tells the operator to delete it.

### Forced-interleaving confirmation

With the marker removed between the claim and the judge (the exact effect of the winner's rename):

    reclaim_rc=2  owner_detail="a reclamation of this lock was started by a process that cannot be judged"
    acquire_rc=3  → OPERATION_LOCK_OWNER_UNVERIFIABLE / "remove …/lock by hand"
    lock_present_after=yes

### Judgment — is this Story 1.2-owned?

**Yes. Story 1.2-owned blocker.** The story's own acceptance frame decides it, three ways:

- **Same acceptance criterion, not a new one.** F6-R1 was accepted as a Story 1.2 defect because a
  contender was given untrue guidance to remove a live lock. F6-R2 gives *the identical guidance* in
  *the identical situation*. If F6-R1 was in scope, F6-R2 is in scope; nothing distinguishes them but
  which function reads the missing file.
- **The module's own stated invariant.** `lib/afk-mutate.sh` header: *"A loser never touches the
  directory, so it can never delete a successor's live lock."* The code keeps that promise; the
  **guidance** breaks it, by making the operator the loser's hands.
- **The contract deviates the same way.** `docs/LIFECYCLE-CONTRACT.md:165-185` was amended by this very
  fix to say a lock carrying no record is *"a lock in the middle of being taken"* — a moment, not a
  diagnosis — and that "remove it by hand" is only true advice once the wait is spent. A marker that
  vanished is the same kind of moment, and it is refused at once with that advice attached.

It is **not** acceptable documented residual behaviour: it is reproducible at 4.7% of contended CLI runs,
not a theoretical window, and the consequence is the two-owners-one-installation state the whole F6
protocol exists to prevent.

The shape of the fix is small and belongs to the same design the F6-R1 fix already established: in
`afk_lock_reclaim`, a marker whose judge says `UNKNOWN` with `$AFK_LOCK_NO_RECORD_DETAIL` (i.e. gone,
not undiagnosable) is a moment — `return 3` ("observe again") rather than `return 2`. Reporting only;
no change was made.

---

## BLOCKER F6-R3 — the same class again: the owner record vanishes between the existence test and the read

**File:** `lib/afk-mutate.sh:299-306` (`afk_lock_judge_record`). **Not disclosed by the implementer.**

### Mechanism

```
if [[ ! -f "$rec" || -L "$rec" ]]; then  UNKNOWN|the lock carries no owner record| ; fi
doc="$(jq -c '.' "$rec" 2>/dev/null)" || doc=""
if [[ -z "$doc" ]]; then                 UNKNOWN|the lock owner record could not be parsed| ; fi
```

Between the `[[ -f ]]` test and `jq` opening the file, a legitimate release or reclaim can rename the
lock directory aside. `jq` gets ENOENT, exits non-zero with empty stdout, and the judge reports
**"the lock owner record could not be parsed"** — a diagnosis, immediately refusable, immediately
`return 3` in `afk_lock_acquire`, immediately "remove `<lock>` by hand".

Nothing was unparseable. `afk_state_file_write` (`lib/afk-common.sh:348-361`) writes a temp file and
installs it with `mv -f` inside the same directory, so `owner.json` is **never** observable as partial,
empty or malformed. A parse failure during a race can only mean the record was no longer there.

### Reproduction — isolated from the reclaim path entirely

One process doing nothing but `afk_lock_take; afk_lock_release` in a loop (so the only writer is the
library and every record it writes is valid JSON, atomically installed); one observer calling
`afk_lock_evaluate` 3000 times:

    3000 observations
      2957  NONE|
        30  UNKNOWN|the lock carries no owner record          <- the publication window (now waited on)
        12  LIVE|pid N
         1  UNKNOWN|the lock owner record could not be parsed <- F6-R3

### Discriminating a vanish from any other `jq` failure

The observer above re-checks the record the instant it renders a "could not be parsed" verdict.
Two runs of 6000 observations each:

    parse_verdicts=2  record_gone_right_after=2  record_present_and_VALID=0  record_present_and_malformed=0
    parse_verdicts=2  record_gone_right_after=2  record_present_and_VALID=0  record_present_and_malformed=0

Four for four, the record was **gone**. Never present-and-malformed (which would mean a torn write, which
the atomic install rules out), never present-and-valid (which would mean `jq` failed for an unrelated
reason such as a fork failure under load). The state being diagnosed as "unparseable" is a lock that was
legitimately released or reclaimed a microsecond earlier.

### Reproduction — with a live successor holding the lock

From the staggered A5 run (30 rounds × 16 contenders against a stale lock with a parked reclaimer):

    ROUND 27 c14  rc=3  owner_state=UNKNOWN  publish_waits=1
      owner_detail="the lock owner record could not be parsed"
      holder_process_alive=yes  lock=present  owner_inc=inc-276497-ba93c1d4aae44
    ROUND 27 c15  (identical)

Seven further instances in the 480-acquisition staggered run. It did not surface in the 256-run CLI
sample, so its CLI rate is lower than F6-R2's — but the operator consequence when it does fire is
identical, and the state it reports is provably a moment rather than a diagnosis.

### Judgment — Story 1.2-owned?

**Yes. Story 1.2-owned blocker**, for the same three reasons as F6-R2, plus one specific to it: the
contract text amended by this fix (`docs/LIFECYCLE-CONTRACT.md:170-172`) still lists an *"unparseable"*
owner record among the conditions whose remedy is "remove the lock directory by hand". The
implementation reaches that branch for a record that was never unparseable, so the contract's own
enumeration is being satisfied by a state it does not describe — the precise argument the retained F6
review used to classify F6-R1 as a contract deviation.

The fix direction mirrors the accepted one: an ENOENT on the read is `$AFK_LOCK_NO_RECORD_DETAIL`
(a moment the acquisition already knows how to wait out), not "could not be parsed".

---

## Anti-vacuity of the new F6-R1 regressions

I reconstructed the pre-fix module in a scratch copy of the tree (outside the repository): the whole
`--- the publication window ---` block deleted (72 lines: the budget variables, `afk_lock_pause`,
`afk_lock_evaluate_settled`), `AFK_LOCK_PUBLISH_SLICES_LEFT` initialisation removed from
`afk_lock_acquire`, and the two `afk_lock_evaluate_settled` calls restored to `afk_lock_evaluate` —
i.e. exactly the code the retained F6 review quoted.

    tests/lifecycle-concurrency-tests.sh   pre-fix: 128 passed, 18 failed   (3/3 runs, identical)
                                            fixed:  146 passed,  0 failed
    tests/lifecycle-mutation-tests.sh      pre-fix: 370 passed,  7 failed  (run 1)
                                           pre-fix: 371 passed,  6 failed  (run 2)
                                            fixed:  377 passed,  0 failed

**Verdict: anti-vacuous.** The mutation failures are all behavioural and all in the new scenarios:

    F6 a contender inside the window is observed waiting, not refusing
    F6 and it is still there when the winner finally publishes
    F6 and then refuses for the owner it actually found
    F6 never for a lock it could not judge
    F6 so no contender is ever told to remove a lock a live owner holds
    F6 and it is told to wait for the operation instead
    F6 and not one of them is told the lock has no owner        (f6contendclean)

Two honest qualifications.

**The `f6contendclean` assertion is a probabilistic detector, not a deterministic one.** On the pre-fix
tree it failed in run 1 and *passed* in run 2 — eight real contenders released from one barrier can all
miss the ~19 ms window. That is why the implementer reported 6 pre-fix failures and I saw 7. It does not
weaken the suite: `f6window` fails 6-for-6 on both pre-fix runs because it holds the window open
deliberately instead of racing for it, and that is what pins the behaviour. Worth knowing if anyone
later uses `f6contendclean` alone as the regression's proof.

On the concurrency count: 11 of the 18 pre-fix failures are the
`publish_waits == 0` accounting assertions, which a tree with no budget variable cannot satisfy by
construction. They are meaningful assertions **on the fixed tree** (they pin "no latency tax on a
decided answer", which I verified independently) but they are not what proves the fix. The seven that
do are behavioural: the contender waits, reports `LIVE`, never says "no owner record", the refusal says
the record never appeared, and the twelve-way clean-path crowd is never told the lock has no owner.
The `f6window` scenario is particularly well built — it holds the window open with library-written
bytes and observes the contender waiting through `/proc`, rather than hoping for a timing.

---

## Independent gate reruns (this session, this checkout)

    bash tests/lifecycle-tests.sh              443 passed,  0 failed    rc 0
    bash tests/lifecycle-mutation-tests.sh     377 passed,  0 failed    rc 0
    bash tests/lifecycle-concurrency-tests.sh  146 passed,  0 failed    rc 0
    bash tests/run-tests.sh                    230 passed,  0 failed    rc 0
        shellcheck                             clean on all 12 shipped scripts
        embedded lifecycle gate                443 passed,  0 failed
        embedded mutation gate                 377 passed,  0 failed
        embedded concurrency gate              146 passed,  0 failed
        live control-plane chain               SKIP (opt-in, not configured)
    git diff --check                           clean, no output         rc 0

Every count reproduces the cycle-5 record. **The gates are green and both findings are real** — F6-R2
and F6-R3 live in states no gate constructs, exactly as F6-R1 did before it.

Why the gates miss them: every lock race in the suites releases its contenders from a single barrier
(`contend_update`, `barrier_wait_ready`), so all contenders reach `ln` inside the first milliseconds of
the marker's ~40 ms lifetime and all of them correctly see it `LIVE`. Both new findings need a
contender arriving *late* in that lifetime. My staggered arrivals (0–90 ms) are the missing pattern;
a barrier cannot produce them, and no gate has one.

---

## Non-blocking observations

- **O-1 — a partially-spent budget crosses lock generations.** The budget is per-acquisition by design
  (documented in both the module and the contract), so slices spent watching one ownerless generation
  are unavailable to a later one. Under a synthetic adversary replacing an ownerless lock every ~0.9 s,
  acquisitions ended at `publish_waits=120` with *"none appeared while it was waited on"* — true of the
  generations actually watched, slightly stronger than the contract's "nothing published it while it was
  watched" reads. Requires ~150 consecutive real handoffs to matter. Design trade, not a defect.
- **O-2 — `AFK_LOCK_PUBLISH_SLICES_LEFT` is initialised only in `afk_lock_acquire`.** Any future caller
  of `afk_lock_evaluate_settled` that forgets to seed it gets a zero budget and, with it, the untrue
  detail *"and none appeared while it was waited on"* for a wait that never happened. Not reachable
  today (one call site), but the trap is one line deep.
- **O-3 — a pathological churn adversary can produce `OPERATION_LOCK_UNAVAILABLE`.** 2 of 12
  acquisitions against a lock being created and destroyed in a tight loop exhausted the four-attempt
  ceiling and returned rc=2. Guidance is safe ("No mutation was attempted"), reachable only under a
  synthetic adversary.
- **O-4 — orphan aside-directory residue is still never collected** (`lock.stale.<inc>` /
  `lock.released.<inc>` from a process killed between rename and `rm -rf`). Unchanged from the retained
  review; harmless, unbounded in `$AFK_STATE_DIR`.
- **O-5 — `trap 'afk_lock_release' EXIT INT TERM` (`bin/agent-flow-kit:301`) does not exit.** Carried
  forward from the retained review; I did not re-attack it and it is outside the F6-R1 fix surface.

---

## Repository state

    pre-review  git status --short : M README.md, M tests/run-tests.sh, ?? .agents/ .claude/
                _bmad-output/ _bmad/ bin/ docs/ lib/ lifecycle/ tests/lifecycle-concurrency-tests.sh
                tests/lifecycle-mutation-tests.sh tests/lifecycle-tests.sh tests/lockctl-helper.sh
    post-review git status --short : identical, field for field, to the snapshot above; HEAD unchanged
                                   at 15a97baf1303d4e76dc29aa6417badd27e449675
    newer-than-session-start scan  : no repository file outside .git is newer than this review's first
                                   scratch artifact (the three AFK-PORT-1.2-F6-R1-POSTFIX-REVIEW.*.json
                                   route stamps are PM-written at 00:45-00:46, before this session)
    git diff --check               : clean

No repository file — source, test, doc, story record, traceability or evidence — was created, modified
or deleted by this review. Story 1.3 was not started. All reproductions ran under `mktemp -d` roots
outside the repository; the pre-fix reconstruction was made in a scratch copy of the tree, never in it.
Findings are reported only: nothing was fixed, no traceability was updated, the story was not frozen.
