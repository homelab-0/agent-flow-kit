# AFK-PORT-1.2 — independent adversarial review after the F6 concurrency fix

- Mode: WORKER · Persona: BMAD DEV (Amelia / Senior Software Engineer)
- persona_source: `.agents/skills/bmad-agent-dev/SKILL.md` + resolved `customize.toml`
- Identity (recomputed independently):
  `{ sha256sum .agents/skills/bmad-agent-dev/SKILL.md; sha256sum .agents/skills/bmad-agent-dev/customize.toml; } | sha256sum`
  = `07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee` — **matches expected, fail-closed check passed**
- Scope: read-only. No repository file, test, story record or traceability entry was modified.
- Primary target: the operation lock protocol in `lib/afk-mutate.sh` (not a gate rerun).

## Verdict

**One Story 1.2-owned finding. Not clean.**

The F6 fix itself is sound. Every destructive path I attacked held: mutual exclusion
was never violated in any reproduction, no successor lock was ever destroyed by a
predecessor or a losing reclaimer, and no residue survived any race I drove.

The defect is in the **acquisition** path, not the reclaim or release paths the F6
fix rewrote: under ordinary concurrency the loser is given the wrong refusal, and
that refusal's operator guidance instructs the operator to delete a **live** lock.

---

## FINDING F6-R1 — a concurrent contender is told to delete a live owner's lock

**File:** `lib/afk-mutate.sh:497` (`afk_lock_acquire`), with the guidance decided at
`lib/afk-commands.sh:524-528` (`afk_lock_refusal` rc=3).
**Severity:** owner-action correctness / operator safety. Not a mutual-exclusion break.

### The mechanism

`afk_lock_take` publishes ownership in two steps that are not atomic together:

```
mkdir -- "$AFK_LOCK_DIR"            # the atomic test-and-set
chmod 700 -- "$AFK_LOCK_DIR"
afk_state_file_write "$AFK_LOCK_DIR/owner.json" "$record"   # the record appears HERE
```

Between those, the lock directory exists and carries no owner record.
`afk_lock_judge_record` returns `UNKNOWN|the lock carries no owner record|`, and
`afk_lock_acquire` handles `UNKNOWN` with an **immediate `return 3`**:

```
afk_lock_evaluate
case "$AFK_LOCK_OWNER_STATE" in
  LIVE) return 1 ;;
  DEAD) : ;;
  *)    return 3 ;;     # <-- no retry, even though the loop allows four
esac
```

The bounded four-attempt retry loop that exists directly above is never entered for
this state, although this is precisely a transient state that resolves on its own
within one file write.

`afk_lock_refusal 3` then emits:

> `OPERATION_LOCK_OWNER_UNVERIFIABLE`
> "Confirm no lifecycle operation is running on this installation, then **remove
> `<lock>` by hand**. No mutation was attempted."

An operator who follows that guidance while the winner is still mutating deletes a
live owner's lock — which is exactly the two-owners-one-installation state F6 exists
to prevent. The module header states the design intent this violates verbatim:
*"Failing closed is right; failing closed with untrue guidance and no way out is not."*

### The window is not narrow

`afk_state_file_write` forks `dirname`, `chmod` and `mv`. Measured on this host,
20 iterations:

```
mkdir_us=7171  publish_window_us=17419
mkdir_us=9381  publish_window_us=19662
mkdir_us=7743  publish_window_us=17981
mkdir_us=7311  publish_window_us=17328
mkdir_us=9217  publish_window_us=18803
mean_publish_window_us=18892      # ~19 ms
```

### Reproductions (throwaway HOME, real processes, no repository writes)

**Library level — 12 processes released from one barrier against a clean lock path:**
```
1  rc=0        (winner)
11 rc=3        (every loser: OPERATION_LOCK_OWNER_UNVERIFIABLE)
peak concurrent owners = 1        identity_ok=true        residue: none
```

**Library level — 15 independent 2-way races, clean lock path:**
```
15 rc=0   15 rc=3        peak concurrent owners = 1
```
`CONCURRENT_OPERATION_IN_PROGRESS` (rc=1) was returned **zero** times in 27 genuinely
concurrent acquisitions.

**Command level — 10 rounds of two real `agent-flow-kit update` processes, started
from one barrier against an installation with NO pre-existing lock:**
```
ROUNDS=10  CONVERGED=10  CONCURRENT=5  UNVERIFIABLE=5  OTHER=0
```
Exactly one converged per round (mutual exclusion holds), but **half the losers got
the wrong refusal**. Verbatim from a captured loser:

```json
{
  "result": "REFUSED",
  "reason": "OPERATION_LOCK_OWNER_UNVERIFIABLE",
  "next_safe_action": "Confirm no lifecycle operation is running on this installation, then remove .../agent-flow-kit/lock by hand. No mutation was attempted.",
  "findings": [{ "reason": "OPERATION_LOCK_OWNER_UNVERIFIABLE", "severity": "owner_action",
    "evidence": { "observed": ".../agent-flow-kit/lock: the lock carries no owner record" } }]
}
```

### Why the gates do not catch it

- `tests/lifecycle-mutation-tests.sh:1692` (`f6contendlive`) asserts all three
  contenders report `CONCURRENT_OPERATION_IN_PROGRESS`, but its lock is planted by
  `write_live_lock` — **fully published before the race starts**, so the window
  cannot open.
- `f6contend2` / `f6contend4` race an **abandoned** lock and assert only
  `unexpected_results == ""`, i.e. any lock-vocabulary reason is accepted.
- `tests/lifecycle-concurrency-tests.sh:179` asserts "every loser refused for a reason
  the lock has a name for" — deliberately blind to *which* reason.

No gate races two contenders from a **clean** lock path, which is the ordinary case
(two terminals, two CI jobs, a retry loop) and the only one that opens the window.

### It is also a documented-contract deviation

`docs/LIFECYCLE-CONTRACT.md:161-174` enumerates exhaustively when each refusal applies:

> A mutating command refuses with `CONCURRENT_OPERATION_IN_PROGRESS` only when the
> owner is proven **live**. [...] Anything else — a lock taken on another host, an
> incomplete, unparseable or unknown-schema owner record, a record naming no usable
> incarnation, or a host that cannot answer the liveness question — is neither waited
> on nor reclaimed: it refuses with `OPERATION_LOCK_OWNER_UNVERIFIABLE` and names the
> lock directory the owner must remove.

A lock a live winner is in the middle of publishing is **none of those five
conditions**. The state the implementation produces is outside the contract's
enumeration, and it lands in the branch whose documented remedy is to remove the
directory — while its owner is live and mutating.

### Story record accuracy

The cycle-4 record discloses this as a residual risk, but understates it in two ways
that matter to a reviewer deciding whether to freeze:
- "**narrow** window" / "**occasionally**" — measured at ~19 ms and reproduced as
  100% of library-level losers and 50% of command-level losers.
- The disclosure describes it as a wrong *reason*; it does not mention that the
  guidance attached to that reason tells the operator to remove a lock that a live
  operation is holding.

### Fix direction (not applied — read-only review)

The state is transient and self-resolving, so it belongs inside the existing bounded
retry rather than in the immediate-refusal branch: retry `UNKNOWN` when the detail is
specifically "the lock carries no owner record", and fall through to the current
`return 3` only after the four attempts are exhausted. That keeps the fail-closed
guarantee for a genuinely undiagnosable lock and keeps "remove it by hand" reserved
for locks where it is true.

---

## Secondary observations (not blocking, not Story 1.2 acceptance defects)

**O-1 — `trap 'afk_lock_release' EXIT INT TERM` (`bin/agent-flow-kit:301`) does not
exit.** A non-exiting bash trap resumes the script after the interrupted command.
Probed directly:
```
begin-transaction
[handler] afk_lock_release equivalent ran
STILL-MUTATING-AFTER-SIGNAL
```
A SIGINT/SIGTERM delivered during `afk_transaction_execute` therefore releases the
lock and lets the remainder of the transaction run unlocked, so a second process can
acquire and write the same destinations concurrently. I did not land a signal inside a
real transaction window, so this is reported as unverified-at-CLI-level, not as a
confirmed defect.

**O-2 — orphan aside-directory residue is never collected.** `lock.stale.<inc>` and
`lock.released.<inc>` left by a process killed between the rename and the `rm -rf`
survive every later acquire:
```
acquire with pre-existing residue: rc=0 reclaimed=true
residue after: [lock.released.inc-...  lock.stale.inc-...]
```
Harmless (incarnation-unique names never collide) but unbounded in `$AFK_STATE_DIR`.

**O-3 — `AFK_LOCK_DIR` with a trailing slash breaks release.** The aside names are
built as `$AFK_LOCK_DIR.released.$inc`, so a declared `.../lock/` puts the target
inside the lock itself; `mv` refuses and release returns 1 with the lock leaked
(`acquire: rc=0 released=false`, `lock` still present). Self-healing — the next run
reclaims it as DEAD — and only reachable through the documented env override.

---

## What held under attack (independent evidence)

| Scenario | Result |
|---|---|
| 10-way simultaneous reclaim of one stale lock | 1×rc=0, 9×rc=1, reclaimed exactly once, peak owners **1**, **zero residue** |
| Former owner releases after successor acquired | `rc=1 released=false`, successor's incarnation intact |
| Lock identity changes between observation and action | observer `rc=3`, successor untouched, `held=false` |
| Repeated reclaim of an already-reclaimed incarnation | `rc=0` then `rc=3`, `rc=3` — never double-reclaims |
| Process SIGKILLed holding the lock | next acquire `rc=0 reclaimed=true`, "pid N is no longer running" |
| Reclaimer SIGKILLed holding the arbitration marker | abandoned marker judged DEAD, discarded, `rc=0 reclaimed=true`, zero residue |
| PID-reuse-shaped identity (right pid, wrong start identity) | `DEAD` — "pid 1 belongs to a different process now" |
| Boot mismatch | `DEAD` — "taken before this host booted" |
| Host mismatch | `FOREIGN` → acquire `rc=3`, lock left intact, never reclaimed |
| Partial initialization (dir, no record) | `rc=3 UNKNOWN`, lock not silently removed |
| Malformed records (non-JSON, `{}`, wrong schema, non-numeric pid, `../../` incarnation) | all `UNKNOWN`, all `rc=3`, lock kept every time — no path injection |
| Lock path is a symlink / a regular file | `UNKNOWN`, `rc=3`, target left intact |

Arbitration-marker authority, exact-incarnation binding, the `link(2)` claim, the
rename-and-reverify sequence, and containment of the aside names all behaved as the
module header documents.

## Independent gate reruns

Run by me, in this session, on this checkout — not copied from the story record:

```
bash tests/lifecycle-tests.sh              443 passed, 0 failed   (rc 0)
bash tests/lifecycle-mutation-tests.sh     356 passed, 0 failed   (rc 0)
bash tests/lifecycle-concurrency-tests.sh  107 passed, 0 failed   (rc 0)
bash tests/run-tests.sh                    230 passed, 0 failed   (rc 0)
    embedded: lifecycle gate            443 passed, 0 failed
              lifecycle mutation gate   356 passed, 0 failed
              lifecycle concurrency gate 107 passed, 0 failed
              live control-plane chain  SKIP (opt-in, not configured)
git diff --check                           clean, no output       (rc 0)
```

Every count reproduces the cycle-4 record exactly. **The gates are green and the
finding is still real** — F6-R1 lives in a state no gate constructs.

## Repository state

Verified byte-identical at start and end (594 tracked+untracked files hashed).
All reproductions ran under `mktemp -d` throwaway HOMEs outside the repository.

