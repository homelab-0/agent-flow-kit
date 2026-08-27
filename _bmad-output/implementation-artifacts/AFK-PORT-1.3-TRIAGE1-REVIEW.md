---
linear:
stamp: AFK-PORT-1.3-TRIAGE1-REVIEW.md.stamp.json
persona: dev
gates:
  - "bash tests/lifecycle-tests.sh"
  - "bash tests/run-tests.sh"
  - "git diff --check"
max_cycles: 1
---

# AFK-PORT-1.3-TRIAGE1 — DIFF-SCOPED REVIEW (review-only, fresh session)

The freeze review found the post-`cfcf9b5` triage delta was verified by gates
and oracle re-runs but never reviewed by an independent session. You are that
review. Delta-scoped, standard effort: the triage-round diff only
(`cfcf9b5..7d126fc`, ~75 reviewable lines in `lib/afk-monitor.sh`,
`tests/lifecycle-dispatch-tests.sh`, `tests/lifecycle-readiness-tests.sh`),
plus its interaction points. Fresh session; you wrote none of it.

**REVIEW-ONLY (hard):** Read/Glob/Grep/Write; modify nothing. Only writes: the
report at `evidence/AFK-PORT-1.3-TRIAGE1-REVIEW.md` and optional new scripts
under `evidence/AFK-PORT-1.3-TRIAGE1-REVIEW-attack/` (self-deciding, with
controls; coordinator-executed). No shell.

Context established (do not re-derive): gates green on `7d126fc` (run-tests
235/0, lifecycle 476/0); monitor oracles A3/P1/P2 re-executed NOT REPRODUCED;
the triage worker's record is the "PR-triage round 1" block in the story file.

## What to attack

1. **T1 heartbeat-window fix:** registration persists `heartbeat_seconds`
   (`lib/afk-monitor.sh:~530-545`), reconciliation refreshes from the stored
   value with global fallback (`:~644-660`). Attack: the class, not the
   instance — any other site reading `AFK_MONITOR_HEARTBEAT_SECONDS` that
   should now read the record (grep all uses, including the expiry judge at
   `:~761`); a stored window of `0`/non-numeric/negative; the legacy-record
   fallback interacting with the `hb == 0` no-deadline case; whether the
   expiry sweep and the refresh can disagree about the same record.
2. **T1 regression honesty:** `heartbeat-window` + `heartbeat-window-legacy`
   in the dispatch gate — do they discriminate for the stated reason (the
   record claims the pre-fix tree fails the declared-window assertions)?
3. **T2 skip counting:** counted `skip()` + last-line
   `N passed, M failed, K skipped` in the readiness suite — verify no check
   changed behavior, the summary ordering survives run-tests' `tail -1`, and
   the exit semantics (`FAIL == 0`) are unchanged by skips.
4. **New-regression check:** anything the delta broke in previously-green
   monitor paths (the heartbeat branch shares the reconciliation function with
   worker_done handling — verify the jq edit cannot corrupt non-heartbeat
   records).
5. **Record truthfulness:** the "PR-triage round 1" claims against the code.

## Blocker bar (unchanged)

Frozen-requirement violation + reproduced (your script) + reachable. Verdict
`CLEAN` or `NOT CLEAN — <n> blocker(s)`; non-blocking register with class and
file:line; state plainly what you did not get to.
