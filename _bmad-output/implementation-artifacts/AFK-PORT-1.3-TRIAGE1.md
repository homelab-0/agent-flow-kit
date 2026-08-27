---
linear:
stamp: AFK-PORT-1.3-TRIAGE1.md.stamp.json
persona: dev
gates:
  - "bash tests/lifecycle-tests.sh"
  - "bash tests/run-tests.sh"
  - "git diff --check"
max_cycles: 1
---

# AFK-PORT-1.3-TRIAGE1 — PR-triage fix round (fresh session, Josh-authorized)

External review (Devin) on the published PR chain found one verified real
defect and re-surfaced one registered residual; Josh authorized fixing both in
one bounded round. **Exactly the two items below plus record work.** The story
is otherwise frozen at `cfcf9b5`; a superseding freeze revision will be
recorded by the coordinator after verification.

## T1 — persist the per-dispatch heartbeat window (verified defect)

`lib/afk-monitor.sh`: registration reads the descriptor's `.heartbeat_seconds`
(`:522`) and uses it for the initial `heartbeat_deadline_epoch` (`:542`) but
never stores it on the watch record; the heartbeat branch of delivery
reconciliation (`:645-660`, refresh at `:650`) recomputes the deadline from the
global `AFK_MONITOR_HEARTBEAT_SECONDS`. A dispatch registered with a
longer-than-default window is falsely flagged `WORKER_HEARTBEAT_EXPIRED`
(spurious loud NEEDS_HUMAN — the B3 harm class); a shorter one silently loses
its tight monitoring.

Fix exactly as the finding sketches: persist the resolved window on the record
at registration (a `heartbeat_seconds` field), use the stored value when
refreshing `heartbeat_deadline_epoch` during reconciliation, fall back to
`AFK_MONITOR_HEARTBEAT_SECONDS` only when the record carries none (records
written before this change must keep working — that fallback is the
compatibility path, say so in a comment only if the code cannot say it).

Regression (dispatch gate): register a dispatch with a non-default window
(e.g. 3× default), deliver a heartbeat, and assert the refreshed deadline
reflects the declared window, not the default; control: a record with no
stored window still refreshes with the default. Anti-vacuity: the first
assertion must fail on the current tree.

## T2 — counted skips in the readiness suite (residual N3, now authorized)

`tests/lifecycle-readiness-tests.sh:47`: `skip()` prints and counts nothing,
so the summary (`N passed, M failed`) reports green with skipped checks
invisible — the exact defect cycle 4 fixed in the dispatch suite. Apply the
same pattern: counted `skip()`, summary as `N passed, M failed, K skipped` on
the LAST line (run-tests' `tail -1` must carry it), no behavior change to any
check. Do not touch `tests/run-tests.sh` aggregation beyond what the dispatch
suite's integration already established (its handling is in place; final-review
F2's aggregate-level gaps stay registered, not fixed).

## Record work

Story file Dev Agent Record, new "PR-triage round 1" block: both fixes,
anti-vacuity reasoning, gates-not-executed statement, diff size. Residual
registry: mark N3 fixed-by-triage-1; add the heartbeat finding as
fixed-external-finding (source: Devin review, PR #16). Do not alter the
coordinator freeze record; the superseding revision is the coordinator's to
write.

## Out of scope — hard stops

- Everything else: F2's aggregate gaps, all other residuals, any file not
  named above. `lib/afk-plan.sh`, `lib/afk-mutate.sh`, the 1.2 surface.
- No new vocabulary; `WORKER_HEARTBEAT_EXPIRED` semantics unchanged (a TRUE
  expiry still fires exactly as today).
- The recovered-heartbeat-stays-degraded behavior is INTENTIONAL (fail-loud,
  confirmed disposition) — do not "fix" it.
