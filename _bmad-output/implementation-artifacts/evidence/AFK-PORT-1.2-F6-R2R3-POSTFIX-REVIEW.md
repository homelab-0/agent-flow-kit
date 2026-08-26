# AFK-PORT-1.2 — independent adversarial review of the F6-R2 / F6-R3 vanished-record fixes

- Mode: WORKER (dispatched) · **read-only** · repository `/home/devbox/repos/jlengelbrecht/agent-flow-kit`
- requested_persona: `dev` · resolved persona: **BMAD DEV (Amelia, Senior Software Engineer)**
- persona_source: `.agents/skills/bmad-agent-dev/SKILL.md` + resolved `customize.toml`
- Identity proof, recomputed in this session:
  `{ sha256sum .agents/skills/bmad-agent-dev/SKILL.md; sha256sum .agents/skills/bmad-agent-dev/customize.toml; } | sha256sum`
  = `07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee` — **matches expected; fail-closed check passed**
- Route: as stamped (`claude` / `claude/strong` / effort high / subscription, metered=false). Not substituted.
- Fresh reviewer: no prior Story 1.2 session resumed, no prior reviewer's conclusion reused. Every claim below
  was reproduced in this session under `mktemp` roots and a scratchpad outside the repository.

---

## Verdict

**NOT CLEAN for Story 1.2 — two blockers.**

The two fixes under review are correct, well-bounded, genuinely regression-covered, and I could not break
either of them at the site it addresses. Liveness was not traded away, retry did not become unbounded, and
mutual exclusion held through every attack. Two things block the freeze anyway.

**F6-R4.** The F6-R3 fix installs a **non-atomic discriminator**, and racing it reproduces exactly the harm
the whole F6 series exists to remove: an operator told to *remove the lock by hand* while a **live successor
provably holds it**. Same defect class, at the site the fix touched.

**F6-R9.** `bash tests/run-tests.sh` is **red on this tree** — 229 passed, 1 failed, rc 1 — and reproducibly
so: the mutation gate failed 2 of 5 runs on `F6 the abandoned lock is still reclaimed exactly once`. The
cause is real, not a fixture artifact: a reclaimer that destroys an abandoned lock and then loses the take
reports nothing, contradicting the contract's own "a reclamation is never silent". Pre-existing rather than
introduced here, but Story 1.2-owned, and a story cannot be frozen on a gate that is not green.

| | verdict |
|---|---|
| F6-R2 (marker carried away → `return 3`) | **holds under attack** — reproduced independently, discriminates against pre-fix |
| F6-R3 (record re-tested after an empty read) | **holds at the site**, but see F6-R4 |
| **F6-R4 — the R3 discriminator raced** | **Story 1.2-owned BLOCKER** — deterministic repro + 6 natural occurrences in 40 000 observations |
| F6-R5 — `afk_lock_evaluate` `-e`/`-d` pair | non-blocker (class member, no reproduction in 100 000 observations) |
| F6-R6 — exhaustion classified `OPERATION_LOCK_OWNER_UNVERIFIABLE` for a **provably dead** owner | non-blocker (untruthful, not unsafe) |
| F6-R7 — the shellcheck sub-gate is **vacuous on this host right now** | non-blocker (verified clean independently) |
| F6-R8 — racy restore guard can nest a stale dir inside a live lock | non-blocker (residue only) |
| **F6-R9 — silent reclamation; `run-tests.sh` red 229/1** | **Story 1.2-owned BLOCKER** — deterministic repro; gate failed 2 of 5 runs |
| new regressions | **anti-vacuous** — 169/5, 169/5, 164/10 on three reconstructed pre-fix trees |
| mutual exclusion | **never broken** — peak simultaneous owners = 1 across every attack |
| gates | lifecycle 443/0, concurrency 174/0, mutation 390/0 idle but **389/1 under load**, **run-tests 229/1 rc 1**, `git diff --check` clean |
| tree left unmodified | **confirmed** |

---

## 1. The two fixed sites, attacked directly

### F6-R2 — the arbitration marker the winner's rename carried away

Reproduced independently (`attack/A1-marker-vanish.sh`), not by reading their fixture: a real losing
`afk_lock_marker_claim` held still between the claim and the judge, the lock directory renamed away by hand
(exactly what the winning reclaimer does), then released:

    fixed tree   : rc=3   owner_detail=(empty)
    R2-reverted  : rc=2   owner_detail=a reclamation of this lock was started by a process that cannot be judged

`rc=3` is "observe again"; `rc=2` becomes `OPERATION_LOCK_OWNER_UNVERIFIABLE` + "remove … by hand".
The fix does what it claims and the discrimination is exact.

**No liveness was traded for it** (`attack/A2-liveness.sh`, five scenarios):

    A2.1 plain stale lock                    rc=0 reclaimed=true  publish_waits=0  666 ms   residue 0
    A2.2 stale lock + abandoned marker       rc=0 reclaimed=true  publish_waits=0  1163 ms
    A2.3 marker present and unparseable      rc=3 "…cannot be judged"  publish_waits=0  379 ms  tree byte-identical
    A2.4 marker present, unknown schema      rc=3 "…cannot be judged"  publish_waits=0  349 ms
    A2.5 marker held by a LIVE reclaimer     rc=1 "an abandoned lock is already being reclaimed by pid …"

A permanently unjudgeable marker still refuses **instantly** (`publish_waits=0`) and truthfully, and touches
nothing. A genuinely dead lock is still reclaimed. The fix did not buy liveness with mis-refusal, and it did
not buy correctness with latency.

### F6-R3 — the owner record released underneath the read of it

The site is correct: after an empty `jq` read the record is re-tested, and a record that is gone is reported
as `the lock carries no owner record` rather than `could not be parsed`. Reverting it fails five concurrency
assertions (below). Attacked at the site, it held.

---

## 2. BLOCKER — F6-R4: the discriminator is not atomic, and racing it re-creates the F6-R1 harm

`lib/afk-mutate.sh:299-317`. After the read comes back empty the judge asks **one stat**:

    doc="$(jq -c '.' "$rec" 2>/dev/null)" || doc=""
    if [[ -z "$doc" ]]; then
      if [[ ! -f "$rec" || -L "$rec" ]]; then          # <-- a SECOND, later observation
        printf 'UNKNOWN|%s|' "$AFK_LOCK_NO_RECORD_DETAIL"; return 0
      fi
      printf 'UNKNOWN|the lock owner record could not be parsed|'; return 0
    fi

The stat does not ask whether *the record that was read* is still there — only whether *a* record is there
now. If the record was released between the test and the read (the very state F6-R3 fixes) **and a successor
publishes into the same name before the stat**, the judge reports the successor's brand-new, perfectly valid
record as one that "could not be parsed".

**Deterministic reproduction** (`attack/A4b-discriminator-race.sh`) — a `jq` ahead of the real one performs
the release and lets a real `lockctl park` successor take and publish the lock, then returns nothing, which
is byte for byte what the real `jq` returns for a name that is gone. Not a line of the judge is replaced:

    rc=3
    owner_state=UNKNOWN
    owner_detail=the lock owner record could not be parsed
    publish_waits=0
    a LIVE successor holds the lock: pid=3662602 alive=yes

`afk_lock_acquire` maps `UNKNOWN` to rc 3; `afk_lock_refusal` (`lib/afk-commands.sh:521-527`) turns rc 3 into
`OPERATION_LOCK_OWNER_UNVERIFIABLE` and

    "Confirm no lifecycle operation is running on this installation, then remove <lock> by hand."

An operator who follows that while the successor is mutating produces the two-owners-one-installation state
the protocol exists to prevent. This is the identical harm profile as F6-R1, F6-R2 and F6-R3 — all three of
which were called Story 1.2-owned blockers on this evidence.

**It is not only forcible, it occurs naturally.** `attack/A5b-natural-rate.sh` runs `afk_lock_evaluate`
40 000 times against an adversary that takes and hands over the lock as fast as it can, publishing the record
**by rename** exactly as `afk_state_file_write` does, so no torn read is possible and every verdict below is
the discriminator race and nothing else:

    iterations=40000  could_not_be_parsed=6
      valid record present immediately afterwards : 1
      still unparseable                            : 0     <-- not one verdict was true
      gone again                                   : 5
    "the lock path is not a directory" : 0

Six "could not be parsed" verdicts, **zero of them true**. No record was ever damaged in that run.

**Why it is a blocker and not a documented residual.** The fix report discloses it as residual risk 2 ("the
discriminator is one stat after the failed read"), but a disclosed defect that still emits remove-by-hand
guidance for a live lock is the same thing F6-R2 and F6-R3 were, and a sound fix is small and local: read the
record **once** and decide from that read alone, e.g.

    doc_raw="$(cat -- "$rec" 2>/dev/null)"      # one read; missing and empty collapse correctly
    [[ -n "$doc_raw" ]] || { printf 'UNKNOWN|%s|' "$AFK_LOCK_NO_RECORD_DETAIL"; return 0; }
    doc="$(printf '%s' "$doc_raw" | jq -c '.' 2>/dev/null)" || doc=""
    [[ -n "$doc" ]] || { printf 'UNKNOWN|the lock owner record could not be parsed|'; return 0; }

Bytes that were read and do not parse are genuinely unparseable; no bytes means the record was not there.
No second observation, so nothing to race. (Fix not applied — this review is read-only.)

**Contract text this falsifies.** `docs/LIFECYCLE-CONTRACT.md:196` — "Only a record that is still there and
still unreadable is a diagnosis." As written, a record that is *gone and replaced* is also diagnosed.

---

## 3. Boundedness, and residual risk 1 (R2 spends an attempt, not a wait slice)

**Bounded — yes.** `afk_lock_acquire` increments `attempt` at the top of every iteration, so every path that
returns 3 from `afk_lock_reclaim` costs one of four attempts and cannot loop. Under an adversary that
rebuilds a dead lock carrying a losing marker and carries the whole directory away, forever
(`attack/A3-bounded.sh`, 40 real acquisitions):

    worst wall clock 1306 ms; every acquisition terminated; residue 0
    rc=0 n=7   rc=2 n=27   rc=3 n=6

**Can it be starved into a wrong classification? Partly — and the wrong classification is untruthful rather
than unsafe.** Five of those six rc=3 results carried:

    detail: pid 3855785 is no longer running

i.e. `OPERATION_LOCK_OWNER_UNVERIFIABLE` — whose reason text is *"An installation lock exists whose owner
cannot be proven either alive or dead on this host"* (`lib/afk-common.sh:739`) — carrying a detail that
proves the owner **is** dead. That is the four-attempt ceiling being exhausted, and F6-R2's `return 3` makes
it more reachable, because a vanished marker now spends an attempt and continues instead of returning at
once. The guidance (remove the lock by hand) is safe here: the owner is provably dead every time it is
emitted. Logged as **F6-R6**, non-blocker.

The other 27 landed on the post-loop `NONE → take fails → return 2` path: `OPERATION_LOCK_UNAVAILABLE` with
the guidance *"Check that the declared state directory is writable, then re-run"* — misleading for a merely
busy installation, and pre-existing rather than introduced here. Non-blocker.

**The dangerous form of starvation — a live publication window refused with a spent budget — exists as a
mechanism but I could not reach it end to end.**

- `attack/A6a.sh` proves `AFK_LOCK_PUBLISH_SLICES_LEFT` can reach **0 while the wait loop exits normally**,
  so an acquisition can continue with no budget left: at delays 0.045–0.065 s the loop exited `state=DEAD
  slices_left=0`.
- `attack/A6-budget-starve.sh` (b) proves what such an acquisition then does to a real publication window
  held open by a live process: verdict in **8 ms**, `the lock carries no owner record and none appeared
  while it was waited on` → rc 3 → remove-by-hand, against a lock whose owner published
  `pid 3894069 … LIVE` an instant later. That falsifies `docs/LIFECYCLE-CONTRACT.md:185` — *"by then nothing
  published it while it was watched — which is what makes 'remove it by hand' true advice"*.
- Composing the two through the real `afk_lock_acquire` with no injected budget **failed**:
  `attack/A6c.sh` (6 tuned delays), `attack/A6d.sh` (3 delays, with the lock directory provably replaced —
  different inodes) and `attack/A6e.sh` (13 delays, scanning the exhaustion boundary with a 6 ms
  disappearance window) produced **0 hits**; every one of the 22 acquisitions spent the full ~3.4–4.1 s
  budget before refusing.

**Disposition of residual risk 1: acceptable-documented**, with the correction that the contract's
justification sentence at line 185 is not true in general — it is true of every acquisition I could actually
construct.

---

## 4. Residual risks 2–5, explicitly

| # | residual risk (fix report) | disposition | evidence |
|---|---|---|---|
| 1 | R2's re-observation spends an acquisition attempt, not a wait slice | **acceptable-documented** — bounded (worst 1306 ms / 40 acquisitions); exhaustion produces an untruthful-but-safe classification (F6-R6) | §3, `A3`, `A6a`, `A6b`, `A6c/d/e` |
| 2 | the discriminator is one stat after the failed read | **BLOCKER — F6-R4** | §2, `A4b`, `A5b` |
| 3 | the F6-R3 fixtures are coupled to `jq` being the reader | **acceptable-documented — they fail loudly** | below |
| 4 | no deterministic CLI-level detector exists for F6-R2 | **acceptable-documented, but the stated reason is wrong** | below |
| 5 | the shellcheck sub-gate can report clean when shellcheck fails to start | **acceptable-documented — F6-R7; it is failing that way on this host right now** | below |

### Residual 3 — do the jq-coupled fixtures fail loudly or vacuously?

Loudly, in both gates, and by construction:

- mutation `f6vanishrecord` pins the read count first:
  `assert_eq "F6 the release landed on the one read of the record this path makes" "$(wc -l < "$SC/released" || printf 0)" "1"`.
  If the shim never fires — because the reader is no longer `jq`, or the read order changed — the log file
  does not exist, the assertion compares `0` to `1` and fails. It cannot pass vacuously.
- concurrency §11 asserts `assert_no_file "the release lands underneath the read" "$LOCK"` **before** it
  asserts the detail; a shim that never fired leaves the lock in place and that assertion fails.

The fixtures are also honest about what they replace: both exec the real `jq` and both guard against
self-recursion. Nothing in the judge is stubbed.

### Residual 4 — the missing CLI-level F6-R2 detector

The fix report's *reason* is too narrow. It is true that nothing external runs between
`afk_lock_marker_claim`'s `[[ -e "$marker" ]]` and `afk_lock_judge_record`'s `[[ ! -f "$rec" ]]`. But the
marker's judge reads the marker **with `jq`**, and that fork is a real external window on the same path. A
`jq` ahead of the real one, keyed to the marker, reaches F6-R2's branch with **no in-process interception at
all** (`attack/A7-external-r2-detector.sh`):

    fixed tree  : fired=yes  rc=0  reclaimed=false  (the freed lock is simply taken)
    R2-reverted : fired=yes  rc=3  owner_detail=a reclamation of this lock was started by a process that cannot be judged

That is a deterministic, external, fully CLI-composable detector — the same shape `f6vanishrecord` already
uses for F6-R3. Recommendation: add it; the cost is one fixture. The *conclusion* (library-level coverage is
sufficient today) still stands, because concurrency §11b already asserts the whole `afk_lock_acquire`
outcome an operator would be handed, and the rc→reason mapping is covered by the mutation gate. Non-blocker.

### Residual 5 — F6-R7: the shellcheck sub-gate is vacuous on this host **right now**

`tests/run-tests.sh:60-88` picks `nix run nixpkgs#shellcheck --` when `shellcheck` is not on `PATH`, captures
only stdout, discards stderr, and never inspects the exit status. On this host:

    $ nix run nixpkgs#shellcheck -- --version
    error: experimental Nix feature 'nix-command' is disabled; …

    $ out="$(nix run nixpkgs#shellcheck -- -s bash --severity=warning --exclude=SC2034,SC2154 lib/afk-mutate.sh 2>/dev/null)"
    captured_stdout_len=0  -> the sub-gate would call this CLEAN

and `tests/run-tests.sh` duly printed **twelve** `PASS shellcheck clean:` lines this run without shellcheck
ever having executed. This is not a hypothetical: section 0 of the gate is currently reporting a result it
did not compute.

**I ran the check independently** with ShellCheck 0.11.0 (`nix --extra-experimental-features "nix-command
flakes" run nixpkgs#shellcheck`), at the gate's own severities:

    bin/agent-flow-kit            CLEAN      lib/afk-plan.sh          CLEAN
    lib/afk-common.sh             CLEAN      lib/afk-mutate.sh        CLEAN
    lib/afk-source.sh             CLEAN      tests/lockctl-helper.sh  CLEAN
    lib/afk-inventory.sh          CLEAN      dispatch.sh              CLEAN
    lib/afk-commands.sh           CLEAN      make-stamp.sh            CLEAN
    tests/run-tests.sh            CLEAN      usage-check.sh           CLEAN
                                             github-health.sh         CLEAN

So the verdict the gate reported is **true** — but it was not established by the gate. The one-line repair is
to capture the status and fail when the checker did not run (`shellcheck` exits 0 clean / 1 with findings;
anything else, or a non-zero status with empty output, is a gate failure). Non-blocker for Story 1.2's
behaviour; a real hole in its evidence chain.

---

## 5. Defect-class sweep — every observe-then-act pair in the lock protocol

Swept `lib/afk-mutate.sh` in full plus every lock-touching line in `lib/afk-common.sh` and
`lib/afk-commands.sh` (`afk_lock_state` existence checks, `afk_lock_refusal`, the two `afk_lock_acquire`
call sites, the `verify` note at `afk-mutate.sh:1090`). Nothing outside `afk-mutate.sh` judges a record.

| site | pair | verdict |
|---|---|---|
| `afk_lock_judge_record:301` | `[[ -f ]]` → `jq` | **fixed (F6-R3)**, but the repair's own discriminator races — **F6-R4** |
| `afk_lock_reclaim:444` | marker judged UNKNOWN/no-record | **fixed (F6-R2)** |
| `afk_lock_marker_claim:415` | `ln` fails → `[[ -e "$marker" ]]` | class-correct: returns 2, reclaim maps it to "observe again". Note it also swallows a genuine failure (unwritable `AFK_STATE_DIR`, no incarnation) into the same 3, which then reports as an unjudgeable **owner**. Cosmetic, non-blocker |
| `afk_lock_evaluate:369-374` | `[[ -e DIR ]]` → `[[ ! -d DIR ]]` | **class member, unfixed and undisclosed — F6-R5.** If the directory is carried away between the two stats the verdict is `the lock path is not a directory` → UNKNOWN → rc 3 → remove-by-hand for a lock that is gone or has a successor. Two adjacent builtins with no fork between them; **0 occurrences in 100 000 adversarial observations** (`A5`, `A5b`). Non-blocker, but it is the same reading the contract says applies "every neighbouring place", and the cheap repair is to treat a lock that is no longer there as `NONE` |
| `afk_lock_incarnation_at:269` | `[[ -f ]]` → `jq` | safe: a vanished record yields a non-match, and every caller treats a non-match as "leave it alone" |
| `afk_lock_reclaim:503` / `afk_lock_release:660` | `[[ ! -e "$aside" ]]` → `mv` | safe: the destination is this process's own incarnation |
| `afk_lock_reclaim:509` / `afk_lock_release:662` | `[[ -e "$AFK_LOCK_DIR" ]] \|\| mv -- "$aside" "$AFK_LOCK_DIR"` | **F6-R8, non-blocker.** The guard is not atomic with the `mv`, and `mv dir existing_dir` **nests** rather than fails (verified). A successor taking the lock in that window gets a stale directory nested inside its own. Bounded residue, judged fields unaffected, mutual exclusion unaffected — the successor's release removes the whole tree |
| `afk_lock_acquire:612` | `[[ ! -e DIR ]] → continue` | class-correct |
| `afk_lock_state` / `verify` | existence only | correct — read-only paths still judge nothing and wait for nothing |

**Interaction with the F6-R1 publication window.** Vanish-during-the-wait is handled: the wait loop
re-evaluates and leaves on `NONE`/`DEAD`/`LIVE`. Publication-during-a-vanish-re-observation is handled: a
`return 3` re-enters `afk_lock_take` and then `afk_lock_evaluate_settled`, which waits the window out on the
shared budget. The one interaction that does bite is the shared budget itself (§3): the budget is spent
across *locks*, not across one lock, so a refusal's justification can refer to time spent watching a
different directory.

---

## 6. Re-attack of the retained F6 scenarios and the F6-R1 suite

All thirteen retained scenarios plus the F6-R1 publication-window suite are exercised by
`tests/lifecycle-concurrency-tests.sh`, which passed **174/0** on the fixed tree. Independently of the gate:

- **Mutual exclusion under N-way contention** (`attack/A8-mutex.sh`): 8 rounds × 10 real contending
  processes released by a barrier, with an abandoned lock seeded into every second round and an abandoned
  marker into every fourth — **peak simultaneous published owners = 1**, always; 8 winners, 72 × rc=1
  (`CONCURRENT_OPERATION_IN_PROGRESS`), 4 reclamations, **0 residue directories**, and no owner ever observed
  a foreign incarnation on disk while holding.
- **Stale reclaim, N-way reclaim, abandoned marker recovery, live-reclaimer arbitration, exact-incarnation
  release, boot/host mismatch, PID-reuse-shaped identity** — re-driven in `A2`, `A3`, `A7`, `A8`; every
  outcome matched the contract. No regression found.
- **No attack in this review ever produced two live owners or destroyed a successor's lock.**

---

## 7. Anti-vacuity

Three pre-fix trees reconstructed **in scratch space only** (`trees/prefix-r2`, `trees/prefix-r3`,
`trees/prefix-both`), each a full copy of the checkout with exactly the reviewed hunk removed from
`lib/afk-mutate.sh` and nothing else; all three parse (`bash -n`).

    concurrency gate, fixed tree      174 passed,  0 failed   rc=0
    concurrency gate, R2 reverted     169 passed,  5 failed   rc=1
    concurrency gate, R3 reverted     169 passed,  5 failed   rc=1
    concurrency gate, both reverted   164 passed, 10 failed   rc=1

The discrimination is exact — each reverted tree fails **only** its own five assertions:

    R2 reverted: "a loser whose marker was carried off by the winner observes again" (3 vs 2)
                 "and says nothing about a reclaimer it could not judge"
                 "an acquisition that lost the marker to a successor is told to wait" (1 vs 3)
                 "naming the live owner that now holds the lock" (LIVE vs DEAD)
                 "so no operator is ever told to remove a lock a live owner holds"
    R3 reverted: "a record released mid-read is reported as a record that is not there"
                 "never as a record that could not be parsed"
                 "an acquisition whose lock was released mid-read takes the free path" (0 vs 3)
                 "and never called the vanished record unparseable"
                 "it releases its own incarnation cleanly afterwards"

These reproduce the fix report's 174/0, 169/5, 169/5, 164/10 exactly. **Anti-vacuity verdict: the new
regressions genuinely fail on pre-fix logic, and they discriminate between the two fixes.**

The mutation gate's `f6vanishrecord` was discriminated the same way, on a full R3-reverted tree:

    mutation gate, fixed tree     390 passed, 0 failed   rc=0
    mutation gate, R3 reverted    384 passed, 6 failed   rc=1   (f6vanishrecord 13 -> 7/6)

    FAIL F6 a record that is not there is not a record that could not be parsed  (false vs true)
    FAIL F6 so nobody is told to remove a lock that was just handed over         (false vs true)
    FAIL F6 the work the lock was guarding happens instead                       (RECOVERED vs REFUSED)
    FAIL F6 which is the deterministic not-ready exit                            (3 vs 2)
    FAIL F6 the interrupted destination is back at its pre-operation content
    FAIL F6 the journal is closed                                                (COMMITTED vs IN_PROGRESS)

That is the fix report's claimed 13 → 7/6, reproduced, and it is the CLI-level proof that the F6-R3 fix is
load-bearing: without it the real `agent-flow-kit update` refuses a handed-over lock and leaves the
interrupted operation unrecovered.

---

## 8. BLOCKER — F6-R9: a reclamation that is silent, and a required gate that is red

`bash tests/run-tests.sh` **failed on this tree**: `229 passed, 1 failed`, `rc=1`. The failure is the mutation
gate reporting `389 passed, 1 failed`, on:

    FAIL F6 the abandoned lock is still reclaimed exactly once
          expected '1', got '0'

(`tests/lifecycle-mutation-tests.sh:1721`, scenario `f6contend4` — four real `agent-flow-kit update`
processes racing one abandoned lock.) It is **not** a one-off: across five runs of the mutation gate on the
unmodified fixed tree it failed **twice** (inside `run-tests.sh`, and in one of three concurrent runs), always
on that same assertion, always `1` vs `0`. Standalone on an idle machine it passes 390/0. It is load-sensitive,
not random.

**The cause is a real contract violation, not a fixture artifact.** `afk_lock_reclaim`
(`lib/afk-mutate.sh:513-517`) renames the abandoned lock aside, proves it is the incarnation it judged,
removes it — and only then tries to take the lock:

    rc=3
    if afk_lock_take; then rc=0; fi
    rm -rf -- "$aside"
    return "$rc"

`AFK_LOCK_RECLAIMED` is set by `afk_lock_acquire` **only on rc 0**. So a reclaimer that wins the arbitration,
destroys another process's lock, and then loses the `mkdir` to a contender returns 3, reports nothing, and
the contender that wins converges with `AFK_LOCK_RECLAIMED=false`. Nobody emits `OPERATION_LOCK_RECLAIMED`.

**Forced deterministically** (`attack/A9b-silent-reclaim-forced.sh` — a shim that steals the lock path in the
window between the rename and the take, using only a `PATH` interposition):

    rc=3
    another contender took the lock path first : stolen
    the abandoned incarnation's record is gone : YES
    stale residue left behind                  : 0

The abandoned lock is gone; the return code says "observe again"; no reclamation is reported. That
contradicts, in the same words, both

- `lib/afk-commands.sh:733-735` — *"Reclaiming a lock is never silent: it is the one place the lifecycle
  removes something another process created."*
- `docs/LIFECYCLE-CONTRACT.md:167-169` — an abandoned owner *"is reclaimed, and the reclamation is reported
  as `OPERATION_LOCK_RECLAIMED`."*

At the library level under ordinary contention it is rare (0 of 30 rounds × 8 contenders,
`attack/A9-silent-reclaim.sh`); through the real CLI, where contenders arrive at the mutating acquire
seconds apart, it fires often enough to redden the gate ~40 % of the time under load.

Safety is **not** affected: exactly one contender still converged in every observed case, mutual exclusion
held, and no residue was left. What is affected is the story's own evidence: a mandated gate is not
deterministically green, and an operator can be handed a successful update that silently deleted another
process's lock. The narrow repair is to set the reclaimed flag on the *reclamation*, not on the subsequent
acquisition — carry it out of `afk_lock_reclaim` on rc 3 as well, or have the loser re-report it. (Not
applied — this review is read-only.)

This finding is **pre-existing rather than introduced by F6-R2/F6-R3**, but it is Story 1.2-owned, it is
what makes `run-tests.sh` red today, and a freeze cannot rest on a gate that fails two runs in five.

---

## 9. Gate results — every gate rerun in this session

| gate | result | rc |
|---|---|---|
| `bash tests/lifecycle-tests.sh` | **443 passed, 0 failed** | 0 |
| `bash tests/lifecycle-mutation-tests.sh` | **390 passed, 0 failed** (idle) — but **389/1 in 2 of 5 runs** under load, see F6-R9 | 0 / 1 |
| `bash tests/lifecycle-concurrency-tests.sh` | **174 passed, 0 failed** (twice, incl. once under load) | 0 |
| `bash tests/run-tests.sh` | **229 passed, 1 failed** — F6-R9 | **1** |
| `git diff --check` | clean, no output | 0 |
| shellcheck, run independently (ShellCheck 0.11.0) | all 12 shipped scripts clean at the gate's own severities | 0 |

Anti-vacuity runs (scratch trees only):

| tree | concurrency | mutation |
|---|---|---|
| fixed | 174 / 0 | 390 / 0 |
| F6-R2 reverted | 169 / 5 | — |
| F6-R3 reverted | 169 / 5 | 384 / 6 (`f6vanishrecord` 13 → 7/6) |
| both reverted | 164 / 10 | — |

The fix report's counts (443 / 390 / 174 / 230-0, and 174-0 / 169-5 / 169-5 / 164-10, 13-0 / 7-6 / 13-0)
reproduce **except** `run-tests.sh`, which is 229/1 here for the reason in §8.

---

## 10. Read-only contract — tree unmodified

    $ git rev-parse HEAD
    15a97baf1303d4e76dc29aa6417badd27e449675          (unchanged from the pre-review snapshot)

    $ diff pre-review-status.txt post-review-status.txt
    IDENTICAL

    $ git diff --check
    (no output, rc 0)

    $ find . -path ./.git -prune -o -newer <first scratch write> -type f -print
    (nothing)

No repository file was created, modified or removed. Every reproduction, forced interleaving and
reconstructed pre-fix tree lives under `mktemp` roots or under
`/tmp/claude-1000/.../scratchpad/`. Nothing was fixed, no traceability was updated, nothing was frozen,
Story 1.3 was not started.

---

## 11. What the PM has to decide

**Blockers (Story 1.2-owned):**

1. **F6-R4** — the F6-R3 discriminator is a second, later observation, so a record that was released and
   immediately republished is diagnosed as unparseable, producing `OPERATION_LOCK_OWNER_UNVERIFIABLE` and
   "remove the lock by hand" **while a live successor holds it**. Deterministic repro + 6 naturally occurring
   false verdicts in 40 000 observations, none of them true. Local fix available (read once, decide from that
   read).
2. **F6-R9** — `bash tests/run-tests.sh` is **red** (229/1, rc 1) on this tree, twice in five mutation-gate
   runs, because a reclaimer that loses the take after destroying the abandoned lock reports nothing,
   contradicting the contract's "a reclamation is never silent".

**Non-blockers, recorded:** F6-R5 (`afk_lock_evaluate`'s `-e`/`-d` pair, same class, no reproduction in
100 000 observations), F6-R6 (exhaustion reports `owner cannot be proven alive or dead` while carrying a
detail proving it dead), F6-R7 (the shellcheck sub-gate is currently reporting twelve passes without running
shellcheck — the verdict is true, but the gate did not establish it), F6-R8 (the racy restore guard can nest
a stale directory inside a live owner's lock; residue only), plus two contract sentences that overstate what
is proven (`LIFECYCLE-CONTRACT.md:185` and `:196`).

**What held under attack:** F6-R2 and F6-R3 at their own sites; liveness (stale locks still reclaimed,
unjudgeable markers still refused instantly at `publish_waits=0`); boundedness (worst 1306 ms across 40
acquisitions under a permanent vanish adversary; no unbounded retry anywhere); mutual exclusion (peak
simultaneous owners = 1 in every attack, 80 contending processes, 0 residue); and the anti-vacuity of every
new regression.
