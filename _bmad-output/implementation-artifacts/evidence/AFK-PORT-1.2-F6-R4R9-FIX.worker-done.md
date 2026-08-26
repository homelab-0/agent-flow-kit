# AFK-PORT-1.2 — cycle 7: F6-R4 (the raced discriminator) and F6-R9 (the silent reclamation)

- Mode: WORKER (dispatched) · repository `/home/devbox/repos/jlengelbrecht/agent-flow-kit`
- requested_persona: `dev` · resolved persona: **BMAD DEV (Amelia, Senior Software Engineer)**
- persona_source: `.agents/skills/bmad-agent-dev/SKILL.md` + resolved `customize.toml`
- Identity proof, recomputed in this session:
  `{ sha256sum .agents/skills/bmad-agent-dev/SKILL.md; sha256sum .agents/skills/bmad-agent-dev/customize.toml; } | sha256sum`
  = `07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee` — **matches expected; fail-closed check passed**
- Route: as stamped in `AFK-PORT-1.2-F6-R4R9-FIX.stamp.json` (`claude` / `claude/strong` / effort high /
  subscription, metered=false). Not substituted.
- Fresh implementer: no prior Story 1.2 session resumed. The reviewer's reproductions in
  `AFK-PORT-1.2-F6-R2R3-POSTFIX-REVIEW.md` were the specification; no retained evidence file was modified.
- The story is **not frozen** by this cycle. Story 1.3 was not started.

---

## What changed

### 1. F6-R4 (blocker) — one observation, one verdict

`lib/afk-mutate.sh`, `afk_lock_judge_record`.

Cycle 6 told "the record is gone" apart from "the record is damaged" with a **second** stat after the read
came back empty. Two looks are two instants, and the lock path is exactly where a successor arrives between
them. The reviewer forced it deterministically (`attack/A4b`) and measured it naturally: **6 "could not be
parsed" verdicts in 40 000 observations, zero of them true**.

The record is now read **once** and judged on the bytes that read returned:

    if [[ ! -f "$rec" || -L "$rec" ]]; then ... no-record moment ... fi
    raw="$(cat -- "$rec" 2>/dev/null)" || raw=""
    [[ -n "$raw" ]] || { ... no-record moment ... }
    doc="$(printf '%s' "$raw" | jq -c '.' 2>/dev/null)" || doc=""
    [[ -n "$doc" ]] || { ... "could not be parsed" ... }

A record is installed by renaming one complete temporary file onto its name, so the bytes are a whole record
or there are none. No bytes is the moment the acquisition already waits out; bytes that were read and do not
parse are the diagnosis they always were. The read moved from `jq "$rec"` to `cat -- "$rec"` because the
shell has to hold the bytes to judge them; `cat` was already an undeclared dependency of
`lib/afk-common.sh:442`, and is now declared in `afk_require_tools`.

The one surviving pre-read test is **not** a discriminator: it refuses to read something that is not a plain
file, because reading a directory, a device or a fifo is a hazard rather than a judgement. Racing it can only
produce the no-record moment, never a diagnosis, so the harm the finding describes is unreachable through it.

### 2. F6-R9 (blocker) — a reclamation reports itself

`lib/afk-mutate.sh` (`afk_lock_reclaim`, `afk_lock_acquire`) and `lib/afk-commands.sh`
(`afk_lock_reclamation_findings`, `afk_lock_refusal`, `afk_run_mutation`).

`AFK_LOCK_RECLAIMED` was set by the **acquisition** on success, so a reclaimer that won the marker, re-proved
the abandoned incarnation, renamed the lock aside, proved what it moved, removed it — and then lost the
`mkdir` on the freed path — returned 3 and said nothing, while the contender that won had reclaimed nothing
and had nothing to say either.

The report now belongs to the destruction. `afk_lock_reclaim` records one line per abandoned lock it
destroys, at the point where the rename has already taken the lock off its path and the aside has just been
proven to be the incarnation that was judged — before, and independently of, the take that follows.
`afk_lock_acquire` only resets that record at the start of an acquisition. One emission point,
`afk_lock_reclamation_findings`, is called from all three places a mutating run can end after acquiring or
trying to: the recovery branch, the converged branch, and — new — `afk_lock_refusal`. A run that destroyed an
abandoned lock and was then refused now reports what it removed. Exactly one finding per destroyed lock; a
run that destroyed nothing reports nothing.

### 3. Gate integrity — the shellcheck sub-gate is fail-closed

`tests/run-tests.sh` section 0 captured stdout only, discarded stderr and never inspected the exit status. On
this host `shellcheck` is absent and `nix run` exits on a disabled experimental feature, so the gate printed
twelve `PASS shellcheck clean:` lines without shellcheck ever running.

The checker is now proved to run before anything is checked with it — each candidate is asked for its version
and must exit 0 and identify itself as ShellCheck — and
`nix --extra-experimental-features "nix-command flakes" run nixpkgs#shellcheck --` was added as a candidate,
which is what makes the gate genuinely execute here. Each file's verdict is decided by the exit status:
0 with no output is clean; 1 with output is findings; **1 with no output means the checker did not run**;
anything else is a checker that delivered no verdict. All three of the last are FAIL. When no candidate can
be made to run, the gate SKIPs loudly — a banner, one SKIP line per script, a skipped count in the summary,
and `skipped checks computed no verdict — they are not passes`. shellcheck is still not required to be
installed.

Three negative probes were run against a truncated copy of section 0 in scratch space:

| probe | result |
|---|---|
| no `shellcheck`, no `nix` on PATH | `0 passed, 0 failed, 12 skipped` + banner. No vacuous pass. |
| `nix` present but refusing the experimental feature (**the live pre-fix case**) | same: SKIP-loudly, naming the reason |
| a checker that identifies itself, then exits 1 with no findings | `1 passed, 12 failed` — every file FAILs with "checker exited 1 with no findings — it did not run" |

The gate now runs for real on this host (ShellCheck 0.11.0 via nix) and immediately caught a genuine SC2120
in this cycle's own new fixture, which was fixed.

### 4. Contract truth — `docs/LIFECYCLE-CONTRACT.md`

- The publication-window paragraph claimed a refusal is made only when *"nothing published it while it was
  watched"*. The budget is spent across an acquisition rather than per lock, so an acquisition that already
  spent it elsewhere can refuse a lock it barely watched (the reviewer produced an 8 ms refusal against a live
  window). The sentence now says what the refusal actually establishes, and that the budget belongs to the
  acquisition.
- *"Only a record that is still there and still unreadable is a diagnosis"* was false for a record that was
  gone and replaced. The paragraph now states the single-observation rule and why a second look is a second
  instant.
- The reclamation bullet now states that the report belongs to the process that destroyed the lock, at the
  moment it destroys it, and that exactly one `OPERATION_LOCK_RECLAIMED` is reported per destroyed lock
  whether the run converges or refuses.

---

## Optional items

| # | item | taken? |
|---|---|---|
| 5 | F6-R5 — `afk_lock_evaluate`'s `[[ -e ]]` / `[[ ! -d ]]` pair | **left documented** (below) |
| 6 | the CLI-level deterministic F6-R2 detector the review proved constructible | **taken** — `f6markervanish` |

**F6-R5, and why it was left.** The cheap repair the reviewer suggests is to test `-d` first and use `-e`
only to tell "gone" from "the wrong kind of thing", which flips the racy outcome from a false diagnosis to
`NONE`. The task made a deterministic regression the condition for taking an optional item, and there is no
deterministic forced interleaving available: both tests are shell builtins with no fork between them, so
nothing external can be scheduled there, and forcing it would mean replacing the function under test. The
reviewer measured **0 occurrences in 100 000 adversarial observations**. Recommended for a cycle that can
carry a library-level fixture for it; it is not fixed here and should not be assumed fixed.

**F6-R2 at the CLI (`f6markervanish`).** The marker's judge *reads* the marker, and that read is a fork, so
the handover is landed from outside with no in-process interception: a reader ahead of the real one renames
the whole lock directory away — which is exactly what the winning reclaimer does, carrying the marker inside
it — on the one read of that marker. A real `agent-flow-kit update` must then CONVERGE rather than refuse
with `OPERATION_LOCK_OWNER_UNVERIFIABLE` and "remove … by hand". This closes the review's residual 4.

---

## Regressions added

| name | where | what it forces | pre-fix |
|---|---|---|---|
| §12 "one observation, one verdict" (5 assertions) | `tests/lifecycle-concurrency-tests.sh` | the release lands underneath the read, a REAL successor takes the freed path and publishes a REAL record into the same name, and only then is the judge allowed to decide — at judge level and through a whole acquisition | fails 5/5 on an R4-reverted tree |
| §12 damaged-record control (4 assertions) | same | bytes that were read and do not parse are still a diagnosis at `publish_waits=0`, touching nothing | passes both ways (control) |
| §13 "a reclamation is never silent" (7 + 7 assertions) | `tests/lifecycle-concurrency-tests.sh`, new `reclaim-losing-take` verb in `tests/lockctl-helper.sh` | the real `afk_lock_take` runs and LOSES to a contender that took the path first; the destruction must still be reported, exactly once, naming what it destroyed | fails 3/3 on an R9-reverted tree |
| `f6silentreclaim` (11 assertions) | `tests/lifecycle-mutation-tests.sh` | a real `agent-flow-kit update` loses the take through an **external** interposition on the aside record (`lock.stale.<inc>/owner.json` exists only in that window) and must still emit exactly one `OPERATION_LOCK_RECLAIMED` alongside its refusal | fails 4/4 on an R9-reverted tree |
| `f6markervanish` (8 assertions) | `tests/lifecycle-mutation-tests.sh` | the arbitration marker carried away by the winner's rename, at the CLI, with no in-process interception | the review's `A7` shows R2-reverted refuses here |

**The existing F6-R2/R3 fixtures were made reader-agnostic** rather than retargeted: the hook is now
installed under **both** names a judge could read a record with (`jq` and `cat`), sharing one fired-flag, so
what they pin is the verdict and not which tool produced it. That also closes the review's residual 3. They
stayed green on every tree in this cycle, including the two reverted ones.

---

## Gate results — every gate rerun with no edit in flight

Raw logs retained in `AFK-PORT-1.2-F6-R4R9-FIX-gates/`.

| gate | result | rc |
|---|---|---|
| `bash tests/lifecycle-tests.sh` | **443 passed, 0 failed** | 0 |
| `bash tests/lifecycle-concurrency-tests.sh` (3 runs after the final edit; 3 more before it) | **207 passed, 0 failed** every time | 0 |
| `bash tests/lifecycle-mutation-tests.sh` — **5 runs UNDER CONCURRENT LOAD** (7 mutation suites in parallel on a 12-core host) | **414 passed, 0 failed — 5 of 5** | 0 ×5 |
| `bash tests/run-tests.sh` | **231 passed, 0 failed** (was 229/1 in the review; 230/1 on the first run of this cycle, which is the repaired shellcheck sub-gate catching a real SC2120 in this cycle's own new fixture — fixed, then re-run) | 0 |
| shellcheck, through the repaired sub-gate (ShellCheck 0.11.0 via nix) | all 12 shipped scripts clean at the gate's own severities | 0 |
| `git diff --check` | clean, no output | 0 |

The F6-R9 blocker was that `f6contend4`'s *"the abandoned lock is still reclaimed exactly once"* failed 2 runs
in 5 under load and made `run-tests.sh` 229/1. On the fixed tree that assertion passed **5 of 5 loaded runs**,
and it still fails on an R9-reverted tree under the same load.

### Anti-vacuity — reconstructed pre-fix trees (scratch space only)

Three full copies of the checkout, each with exactly one reviewed hunk reverted in `lib/afk-mutate.sh` and
nothing else; all parse (`bash -n`).

| tree | concurrency gate (3 runs each) | mutation gate |
|---|---|---|
| fixed | **207 / 0** | **414 / 0** (×5 under load) |
| F6-R4 reverted (the second stat restored) | **202 / 5** | 414 / 0 — control: no mutation assertion discriminates R4 |
| F6-R9 reverted (`AFK_LOCK_RECLAIMED` back on acquire rc 0) | **204 / 3** | **409 / 5** (twice) |
| both reverted | **199 / 8** | — |

The discrimination is exact — each reverted tree fails **only** its own assertions:

    R4 reverted: "a record read once and found gone is reported as a record that is not there"
                 "never as a record that could not be parsed, whatever arrived afterwards"
                 "an acquisition that read a vanished record while a successor published waits"
                 "naming the live owner that now holds the lock"
                 "and never calls the successor's valid record unparseable"
    R9 reverted: "and the destruction is reported even though the take was lost"
                 "exactly once, for the one lock that was destroyed"
                 "naming the owner it proved was gone"
    R9 reverted, mutation gate:
                 "F6 the abandoned lock is still reclaimed exactly once"   <- the review's red assertion
                 "F6 a reclamation that lost the take is still reported"
                 "F6 exactly once, for the one abandoned lock it destroyed"
                 "F6 the reclamation report says what it destroyed"
                 "F6 naming the owner it proved was gone"

Every F6, F6-R1, F6-R2 and F6-R3 regression stayed green on all four trees.

---

## Residual risks for the next reviewer

1. **F6-R5 is not fixed.** `afk_lock_evaluate` still tests `-e` then `! -d`, so a lock carried away between
   the two is reported as `the lock path is not a directory` → UNKNOWN → remove-by-hand. Same class as
   everything this series has fixed; 0 occurrences in the reviewer's 100 000 observations; left because no
   deterministic regression is constructible between two adjacent builtins (see Optional items).
2. **F6-R6 and F6-R8 are untouched.** Exhaustion still reports `OPERATION_LOCK_OWNER_UNVERIFIABLE` while
   carrying a detail that proves the owner dead, and the restore guard in `afk_lock_reclaim` /
   `afk_lock_release` is still not atomic with its `mv`.
3. **The judge still makes one observation before its read** — `[[ ! -f "$rec" || -L "$rec" ]]`. It is a
   hazard guard, not a discriminator, and its race can only produce the no-record moment. Worth confirming
   independently that no path turns that moment into a diagnosis.
4. **`cat` is now a declared required tool.** It was already used unconditionally in `lib/afk-common.sh` and
   `lib/afk-mutate.sh`, so this declares an existing dependency rather than adding one — but it is a change to
   `afk_require_tools` and a host without `cat` now fails earlier and more loudly.
5. **One acquisition that destroys two abandoned locks emits two findings.** The record is a line per
   destruction, which is what "exactly one per destroyed lock" means; no gate constructs it, and a consumer
   that assumes at most one `OPERATION_LOCK_RECLAIMED` per run would see two.
6. **`afk_lock_refusal` now emits an extra finding** on refusal paths that reclaimed. Any consumer counting
   findings on a refusal sees one more than before. `unexpected_results` and every count assertion in the
   mutation gate were re-run against this.
7. **A reclaimer killed between the destruction and its report still reports nothing.** Process death is
   outside the reach of an in-process report; the abandoned-marker rules are what recover that case.
8. **The new fixtures depend on an external reader fork.** `f6silentreclaim` keys on
   `lock.stale.<incarnation>/owner.json` — a path that exists only in the window it targets — and the §12/§13
   fixtures shim both `jq` and `cat`. If a future change removes the fork, they fail loudly (the read-count
   pins and the `assert_file`/`stolen` preconditions fail first), never vacuously.

---

## Files modified

    lib/afk-mutate.sh                     F6-R4 single read; F6-R9 reclamation record
    lib/afk-commands.sh                   afk_lock_reclamation_findings; emitted from all three exits
    lib/afk-common.sh                     `cat` declared in afk_require_tools
    docs/LIFECYCLE-CONTRACT.md            three passages aligned with the fixed behaviour
    tests/run-tests.sh                    fail-closed shellcheck sub-gate; skipped count in the summary
    tests/lifecycle-concurrency-tests.sh  reader-agnostic hook; sections 12 and 13
    tests/lifecycle-mutation-tests.sh     reader-agnostic hook; f6silentreclaim; f6markervanish
    tests/lockctl-helper.sh               `reclaim-losing-take` verb
    _bmad-output/implementation-artifacts/AFK-PORT-1.2.md        cycle 7 record
    _bmad-output/implementation-artifacts/traceability.md        F6-R4 and F6-R9 rows

No commits, pushes or PRs. No retained evidence file was touched. Nothing outside `lib/`,
`docs/LIFECYCLE-CONTRACT.md`, `tests/` and the story artifacts was modified. Every reproduction, forced
interleaving and reconstructed pre-fix tree lives under `mktemp` roots or under the session scratchpad.
