# AFK-PORT-1.2-F6-R11-POSTFIX-REVIEW — diff-scoped review (READ-ONLY)

- **Reviewer:** fresh BMAD DEV (Amelia), seventh distinct session on Story 1.2.
- **Persona proof:** `07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee` — matched, fail-closed gate passed.
- **Route provenance:** `AFK-PORT-1.2-F6-R11-POSTFIX-REVIEW.stamp.json` (claude / claude-strong / high, validated). No local substitution.
- **Tree reviewed:** branch `story/afk-port-1.2`, HEAD `6f9a68c`, uncommitted F6-R10+F6-R11 working tree. Nothing committed, nothing frozen, nothing fixed by this session.

## Verdict

**NOT CLEAN — one in-diff finding, documentation-truth class only.**

The remedy is correct and independently reproduced. The regressions are non-vacuous and
discriminate exactly as claimed. Every gate is green at the exact claimed counts. The one
finding is a **false clause in two of the three corrected contract passages** — the same defect
class this cycle was chartered to fix, at documentation severity: no code change is required, no
gate is affected, and no safety property is weakened. It sits **below the exploitability bar** the
convergence-control policy sets for a blocker; whether it warrants a cycle, a wording patch
folded into the freeze commit, or a backlog entry is the PM's call. **No auto-cycling was done.**

---

## Scope item 1 — the remedy

**VERIFIED.**

| claim | result |
|---|---|
| five signals into the disarm-and-exit idiom | `HUP/USR1/USR2/ALRM/PIPE` added to `AFK_TRAPPED_SIGNALS` and each given `afk_terminate_on_signal` (`bin/agent-flow-kit:353-372`) |
| whole-set disarm | both handlers open with `trap '' "${AFK_TRAPPED_SIGNALS[@]}"` — verified against the real kit under a 10-signal storm (below) |
| QUIT untrapped, pinned by R11f | absent from the array and from the trap list; R11f present |
| exit statuses | `kill -l` on this host: HUP 1, INT 2, USR1 10, USR2 12, PIPE 13, ALRM 14, TERM 15 → 129/130/138/140/141/142/143. All seven literals correct |
| EXIT-only release preserved | `afk_lock_release` is called from `bin/` only inside `afk_release_on_exit`, which is bound to `EXIT` alone |
| journal visibility preserved | no journal cleanup in either handler; every regression asserts `IN_PROGRESS` survives |

### The mechanism, verified independently of the suite

Bash's deferral rule is the whole fix, so I measured it directly rather than taking it on trust:

```
TRAPPED   handler fired at t=5.01s (after `sleep 5` returned), rc 129
UNTRAPPED EXIT trap fired at t=0.00s, shell dead at t=0.31s while `sleep` still ran, rc 129
```

Untrapped, the release runs immediately and the shell dies out from under the running command.
Trapped, it waits. That is exactly the ordering the invariant needs.

### Independent end-to-end pid-only SIGHUP reproduction

Written for this review — **not** reusing `sig_untrapped_case`. Own interposer, own observation
points, run against both trees:

```
FIXED     parked inside the staging copy: yes
          1s after pid-only HUP: shell alive=yes  lock=HELD-SAME-INCARNATION
                                 contender=CONCURRENT_OPERATION_IN_PROGRESS (REFUSED, rc 2)
          shell rc=129; journal=IN_PROGRESS; applied_revision moved=no
          next run: RECOVERED; run after: CONVERGED; lock residue: []

BASELINE  1s after pid-only HUP: shell alive=no   lock=FREED-UNDER-A-LIVE-WRITE
                                 contender=OPERATION_RECOVERED (rc 3)
          — the contender took the freed lock and rolled the installation back while the
            first writer's `cp` was still parked and about to write
```

This matches the brief's expected remedy line character for character. The defect is real and
the remedy closes it.

### Whole-set disarm — verified, and it has no regression of its own

Every section-12 case delivers exactly **one** signal, so the "a second signal of any kind cannot
re-enter cleanup" claim is untested by the suite. I tested it against the real kit: HUP followed
immediately by TERM, INT, USR1, USR2, ALRM, PIPE, HUP, TERM, INT.

```
shell alive=yes  lock=HELD-SAME-INCARNATION  contender refused (rc 2)
shell rc=130; journal=IN_PROGRESS; next run RECOVERED; run after CONVERGED; residue []
no stderr noise, exactly one exit, release performed once
```

The property holds. Note the exit status under a *mixed storm* is whichever handler bash runs
first (bash prioritises `SIGINT`), so rc was 130 rather than 129 — not a claimed property, and
not a defect. **REPORT-ONLY:** the disarm is a real invariant with no regression pinning it;
worth one case if the section is ever revisited.

---

## Scope item 2 — anti-vacuity

**VERIFIED — the claimed discrimination reproduces exactly.**

Baseline reconstructed in scratch per the brief: the current R10-fixed tree with
`AFK_TRAPPED_SIGNALS` back to `(INT TERM)` and the five new `trap` lines deleted, tests byte-
identical between the two trees (`cmp` clean).

| tree | runs | result |
|---|---|---|
| fixed | 2 concurrent, loaded | **102 / 0**, rc 0, 0 skips |
| five traps removed | 2 concurrent, loaded | **62 / 40**, rc 1, failure set **byte-identical** across both runs |
| fixed, launched under `nohup` | 1 | **83 / 0**, rc 0, **1 loud SKIP** |

My harness carries section 12 alone; the fix worker's carried 31 extra fixture-level assertions.
`133 − 31 = 102` and `93 − 31 = 62` — **the two harnesses agree exactly**, and the 40-failure
delta is identical.

Failure distribution on the baseline: **8 per signal × 5 signals = 40, none in R11f.** The eight
are precisely the ones that name the harm:

```
R11a the run does not die out from under the write it started
R11a so the lock is not handed back while that write is in flight
R11a and it is still the exact lock the writer took
R11a a contender meeting the signalled writer is refused
R11a with the owner-action exit
R11a the journal stayed visible for recovery
R11a the next run rolls the interrupted operation back
R11a and the one after it converges
```

R11f passes on both trees, as a decision-pin must.

---

## Scope item 3 — contract truth  ⚠ THE FINDING

Two of the three corrected passages carry a clause that is **false as written**.

### The false clause

`docs/LIFECYCLE-CONTRACT.md`, release paragraph:

> **The release happens when the owning process exits, and at no earlier moment.**

and transaction step 2:

> It is given back when the owning process **exits** — never while that process, or a write that
> process started, can still touch the installation —

On every ordinary run the lock is released **before** the process exits.
`lib/afk-commands.sh:733-734` is `afk_transaction_execute "$command" || true` immediately
followed by `afk_lock_release`; the process then goes on to build and emit the result document
and only exits afterwards. The suite proves it itself: **R10e** parks the run on the final-emit
`jq` and asserts `R10e it holds no lock there` — process alive, lock already gone. That assertion
**PASSED** in my solo gate run.

So the contract states a release that happens strictly later than it actually does.

**Severity: documentation only.** The clause over-states *when* the lock comes back, never
understates it — it claims the lock is held for longer than it is. The invariant readers actually
depend on is the second half of step 2's sentence ("never while that process, or a write that
process started, can still touch the installation"), which is **true** and is what the code
enforces. FR-92 mutual exclusion is unaffected. No code change is implied; the fix is a wording
correction to two sentences.

It is nonetheless the exact defect class this cycle was chartered to close — the R11 brief's own
words were "**The contract must be true as written**" — and it was **introduced by this diff**
(neither sentence exists at `HEAD`). That is why it is reported as a finding rather than a note.

The same diff's code comment agrees with reality and therefore disagrees with the contract:
`bin/agent-flow-kit` says of `SIGPIPE` "At the one point PIPE really can fire, the final emit into
a closed pipe, **the lock is already gone**". Code comment right, contract wrong.

### What IS true

- `SIGQUIT` is deliberately not in that set: it is ignored outright — **VERIFIED independently.**
  A non-interactive bash script sent `SIGQUIT` survived, ran to completion and exited 0. Trapping
  it would newly kill runs that succeed today. The non-trap decision is correct.
- The `SIGKILL` / publication-window paragraph is **true and correctly scoped**: it no longer
  claims "neither path leaves an installation permanently busy", it names the window, says the
  installation stays busy, and names the manual remedy. B1's mechanism is correctly left unfixed.
- The exit-code passage is true on this platform (see the macOS caveat under residual risk 1).
- The `SIGPIPE` non-reachability rationale is **factually verified**: `lib/afk-mutate.sh` contains
  **zero** `afk_warn` and **zero** `>&2`.
- The machine-checkable `exit_codes` block is **untouched** — confirmed against `HEAD`.

---

## Scope item 4 — the deliverability guard

**VERIFIED both ways.**

- Under `nohup`: `sig_deliverable HUP` correctly detects the inherited `SIG_IGN` and skips loudly.

```
  !! SIGHUP was ignored on entry to this suite, so nothing it starts can trap it
  SKIP R11a SIGHUP delivered pid-only inside the write phase — NOT RUN here
```

  Result `83 / 0` — exactly `102 − 19`, R11a's full assertion set, and **no false failure**.
- Launched normally: `102 / 0`, zero skips.
- Every gate run I performed reports **zero `SKIP` lines** in the mutation suite (`grep -c SKIP` = 0
  on the solo run and both loaded runs). I confirmed my launcher can deliver all eight signals
  before trusting any result: probed in the foreground shell, in a background shell, and in an
  `exec`'d child launched with `&` — all eight trappable in all three.

**REPORT-ONLY:** the mutation suite's `skip()` (pre-existing, line 44) increments no counter,
unlike `run-tests.sh`'s. A skip is therefore invisible in the `N passed, M failed` summary and
detectable only by the reduced total or by grepping the log. Worth a `SKIPPED` counter if the
suite is ever touched again.

---

## Scope item 5 — the six residual risks

| # | risk | disposition |
|---|---|---|
| 1 | `USR1`/`USR2` statuses are Linux numbering (138/140); macOS is 30/31 | **CONCUR, and elevate.** The regressions do *not* break on macOS — test and code hardcode the same literals, so they agree. What breaks is the **contract**: "it exits `128 +` the signal number" becomes false for those two signals on a platform `README.md` claims is proven. This is a contract-truth item, not only a portability nit. Report-only; PM registers for Story 1.4 as flagged. |
| 2 | section 11 has no deliverability guard | **CONCUR**, low. `nohup` ignores `HUP` only, so `INT`/`TERM` have never been exposed; a launcher doing `trap '' INT TERM` would make R10a/R10b misreport exactly as R11a did. Correctly left out of a bounded cycle. |
| 3 | R11f asserts bash's own `SIGQUIT` disposition | **CONCUR.** Independently verified that bash ignores it. It is an assertion about the interpreter, and that is the intended alarm — correctly documented as such. |
| 4 | "still alive" is a bounded 2s poll, not a file | **CONCUR**, and the asymmetry is favourable: a correct run cannot be waited out (it is blocked in the park), and the only way to observe `alive=false` is a genuine early death. A loaded host can therefore produce a **false pass on the baseline**, never a false failure on the fixed tree — an anti-vacuity weakness, not a gate flake. It did not fire: 40/40 on both baseline runs under real concurrent load. |
| 5 | section 12 costs ~4½ min; mutation is now the long pole | **CONCUR**, factual. My solo mutation run was 1644s (~27 min); `run-tests.sh` is dominated by it. |
| 6 | R11f exceeds the brief's letter | **CONCUR, no objection.** The brief told the implementer to decide `QUIT` explicitly and "say so in the record so the next reviewer does not helpfully add it". A regression that fails the gate if someone adds the handler is a stronger form of the same instruction. |

---

## Scope item 6 — brief compliance

**PASSES.**

- `lib/` **untouched** — tripwire never fired. The whole code surface shows exactly three modified
  files: `bin/agent-flow-kit`, `docs/LIFECYCLE-CONTRACT.md`, `tests/lifecycle-mutation-tests.sh`.
- Merged surface #6–#8 (`README.md`, `lifecycle/kit.json`, all six `lib/*.sh`) — **no intersection.**
- Out-of-scope items **registered, not fixed**: B1, N1, N2, N3, N5 all appear in the Cycle 10
  hardening-backlog block with no code change behind them. Verified B1's remedy would need
  `lib/afk-mutate.sh`, which is merged — correctly deferred.
- **No commits.** `HEAD` is still `6f9a68c`.
- Machine-checkable `exit_codes` block untouched, as instructed.
- Both required lessons recorded as lessons, not acceptance criteria. (The record carries three;
  the extra one — signal dispositions are inherited from the launcher — is earned, it bit this
  cycle for real.)

---

## Gates — rerun in full by me

| gate | result | rc | wall |
|---|---|---|---|
| `bash tests/lifecycle-tests.sh` | **443 passed, 0 failed** | 0 | 277s |
| `bash tests/lifecycle-mutation-tests.sh`, **solo** | **577 passed, 0 failed, 0 skipped** | 0 | 1644s |
| `bash tests/lifecycle-mutation-tests.sh`, **2 concurrent loaded** | **577 passed, 0 failed, 0 skipped** — both | 0 | run concurrently with the anti-vacuity matrix |
| `bash tests/lifecycle-concurrency-tests.sh` ×2 | **207 passed, 0 failed** — both | 0 | 27s each |
| `bash tests/run-tests.sh` | **231 passed, 0 failed** — shellcheck genuinely ran (nix 0.11.0), `agent-flow-kit` + all six libs + `lockctl-helper.sh` clean; embedded gates reported 443/0, 577/0, 207/0 | 0 | 2144s |
| `git diff --check` | clean, no output | 0 | — |

Anti-vacuity harness (extra, beyond the required gates): fixed 102/0 ×2, baseline 62/40 ×2,
nohup 83/0+1 skip ×1.

The only `SKIP` anywhere in `run-tests.sh` is the pre-existing live-router chain (`AGENT_ROUTER_URL`/`_TOKEN`), unrelated to this change.

**No flake observed** across 4 full mutation-suite runs, 2 concurrency runs, 5 harness runs and
2 independent end-to-end reproductions (plus the storm test). Counts agreed exactly every time.

---

## Read-only proof

All five files the fix touched are **byte-identical** before and after this review:

```
bin/agent-flow-kit                                  OK
docs/LIFECYCLE-CONTRACT.md                          OK
tests/lifecycle-mutation-tests.sh                   OK
_bmad-output/implementation-artifacts/AFK-PORT-1.2.md   OK
_bmad-output/implementation-artifacts/traceability.md   OK
```

`HEAD` unchanged at `6f9a68c`. `git diff --check` clean. Everything I ran lives under the session
scratchpad; nothing was written into the repository by this session.

**Disclosure — `git status` is NOT identical to the pre-review snapshot, and none of it is mine.**
During the review the working tree gained PM-authored planning artifacts:
`_bmad-output/planning-artifacts/epics.md` and `follow-on-worker-subdelegation.md` modified;
`AFK-PORT-1.5.md`, `AFK-PORT-1.6.md`, `AFK-PORT-1.7.md`, `prd-addendum-1.5-1.6.md` and
`reconciliation-stories-1.5-1.6.md` added. All are outside the reviewed surface. Confirmed
directly: `git status --porcelain -- . ':(exclude)_bmad-output'` returns exactly the three
reviewed code/doc files and nothing else.

---

## REPORT-ONLY observations (outside the diff — no action taken)

1. **`bin/agent-flow-kit:296-297`**, unchanged at `HEAD` and left in place, still says a killed
   command "cannot leave an installation looking permanently busy" — the identical claim the R11
   fix just corrected in the contract, and B1 falsifies it. Pre-existing, comment-only, and it is
   the immediate lead-in to the changed block, so a reader lands on it first.
2. **The whole-set disarm has no regression** (see scope item 1).
3. **`skip()` in the mutation suite tracks no counter** (see scope item 4).
4. **N5 confirmed**: `tests/lifecycle-mutation-tests.sh` is mode `100644` while its siblings are
   `100755`. Pre-existing, no gate affected. Already registered.
