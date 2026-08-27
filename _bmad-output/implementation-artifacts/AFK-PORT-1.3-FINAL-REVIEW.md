---
linear:
stamp: AFK-PORT-1.3-FINAL-REVIEW.md.stamp.json
persona: dev
gates:
  - "bash tests/lifecycle-tests.sh"
  - "bash tests/run-tests.sh"
  - "git diff --check"
max_cycles: 1
---

# AFK-PORT-1.3 — FINAL DIFF-SCOPED REVIEW (review-only, fresh session)

You are a fresh reviewer; you neither wrote nor previously reviewed any of this.
This is the freeze-gating review of the **cycle-4 delta only** — the story has
had its full sweep (`evidence/AFK-PORT-1.3-FULL-REVIEW.md`), one post-fix
review (`evidence/AFK-PORT-1.3-POSTFIX-REVIEW.md`), and two authorized fix
cycles whose records sit in the story file. Prior scenarios are pinned by their
regressions. Delta-scoped, standard effort — not a second sweep.

**REVIEW-ONLY CONTRACT (hard):** Read/Glob/Grep/Write; modify nothing. Only
writes: `evidence/AFK-PORT-1.3-FINAL-REVIEW.md` (report) and optional new
scripts under `evidence/AFK-PORT-1.3-FINAL-REVIEW-attack/`. No shell — attacks
are runnable self-deciding scripts with controls, coordinator-executed.

## The delta under review (cycle 4)

1. `lib/afk-monitor.sh` — consumed durable-close status for ABSENT/IDLE/EXITED;
   new `afk_monitor_probe_strict` + `afk_monitor_bound_unavailable` (also now
   used by `afk_monitor_git_remote`); the terminal-list and durable-close
   observations moved onto the strict path.
2. `bin/agent-flow-kit` — new `afk_declare_bounding_tool` announcement on live
   runs (the DEVIATION, below).
3. `docs/LIFECYCLE-CONTRACT.md` — Terminal row ("accepted"), ABSENT paragraph
   rewrite, monitor bounded-observation sentences.
4. `tests/lifecycle-dispatch-tests.sh` — `STUB_CLOSE_FAILS` stub modes,
   `ghost-refused` + `idle-refused`, counted `skip()` with a
   `passed/failed/skipped` last-line summary, stalled-remote split, new
   section 8 (PATH-sandbox no-timeout attack + three controls).
5. `tests/run-tests.sh` — aggregation of the above.

Context you take as established (do not re-derive): the coordinator executed
all six oracle scripts post-cycle-4 — P1/P2 NOT REPRODUCED, A1–A4 still NOT
REPRODUCED, controls holding; launcher and coordinator gate runs green (logs in
`evidence/AFK-PORT-1.3-C4-gates/`).

## What to attack

1. **Remedy completeness for P1/P2** — the same question the last review asked
   of cycle 3: does each fix close the CLASS? P1: is there any path where a
   close outcome is still discarded, or where `STUB_CLOSE_FAILS` doesn't model
   real Orca refusal shapes; can the accepted-then-relisted case still settle?
   P2: any remaining external observation in the monitor pass NOT on a strict
   path (grep the whole monitor); does `afk_monitor_probe_strict` share the
   probe runner's timeout arithmetic honestly; is the readiness/monitor policy
   split stated truthfully in the contract?
2. **The deviation:** `timeout` declared-and-announced instead of hard-required.
   Judge the worker's collision argument on its merits against the brief, the
   frozen "a host that cannot bound a probe reports PROBE_BOUND_UNAVAILABLE"
   rule, and operator experience (is the announcement loud enough that an
   operator learns before a live pass degrades?). If unsound, that is a
   finding; if sound, say so explicitly — the coordinator records your judgment
   as the disposition.
3. **New-regression check:** anything the cycle-4 delta broke in previously
   green paths, including the cleanup dispositions for IDLE/EXITED now that
   their close status is consumed (a transiently-failing close that would
   previously have released on true re-observed absence now fails closed — is
   any pinned scenario's meaning silently changed?).
4. **Skip accounting honesty:** the new counted skips — can a skipped section 8
   or stalled-remote still masquerade as full coverage anywhere run-tests
   surfaces results? Does the last-line summary survive every aggregation path?
5. **Contract truthfulness:** every added/rewritten sentence true of the code;
   no older sentence made false (search ABSENT, bounded, timeout, release,
   accepted across the doc).

## Blocker bar (unchanged)

Frozen-requirement violation + reproduced (your script) + reachable (natural or
one ordinary operator action). Non-blocking → register with class + file:line.
Registered residuals (N-series, D-series) are dispositioned; re-raise only if
this delta made one worse.

## Report format (`evidence/AFK-PORT-1.3-FINAL-REVIEW.md`)

1. Verdict: `CLEAN` or `NOT CLEAN — <n> blocker(s)`.
2. Blockers with reproduction/frozen-text/reachability/remedy.
3. Non-blocking register (delta-scoped).
4. P1/P2 remedy-completeness verdicts and the deviation judgment.
5. What you did not get to, plainly.

State the verdict plainly in your final message.
