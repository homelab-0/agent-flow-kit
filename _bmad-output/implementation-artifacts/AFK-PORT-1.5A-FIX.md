---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-PORT-1.5A-FIX.md.stamp.json
persona: dev
gates:
  - "bash tests/run-tests.sh"
  - "bash tests/lifecycle-readiness-tests.sh"
  - "bash tests/lifecycle-tests.sh"
  - "git diff --check"
max_cycles: 1
---

# AFK-PORT-1.5A-FIX — one bounded post-review fix cycle (fresh session)

Authorized by the coordinator after the independent review
(`evidence/AFK-PORT-1.5A-REVIEW/REVIEW.md`, verdict CLEAN, 9 residuals; the
reviewer's scripts `attack-04`, `attack-05b`, `attack-08` are your oracles).
**One cycle. Exactly the six items below.** Everything else in the review is
dispositioned: R4/R5/R8-beyond-F4 backlog, R6/R7 accepted, R9 handled at
squash. You are a fresh session; you did not write this code or the review.

## In scope — exactly this

### F1 — R1: lock the story-record append (high)

`record_sizing_risk` in `files/model-router/scripts/dispatch.sh` is an
unlocked read-modify-write of the story file; the reviewer's
`attack-05b-record-race.sh` shows lost updates in 29/30 two-way trials and an
EMPTIED story file under 8-way contention. Take an exclusive lock around the
read-modify-write (the reviewer's shape: open a descriptor on the story,
`flock -x` it before the grep/awk, release after the inode-preserving `cat`),
keeping idempotence-per-cycle and inode/permission preservation. Add a test:
N concurrent appends of distinct cycles yield exactly N lines and an intact
body (run the reviewer's script logic as the assertion, with its serial
control).

### F2 — R2: confine `payload_refs` to the worktree (medium)

`budget_payload_paths` resolves `realpath "$PWD/$ref"` and tests only `-f`/
`-r`, so `../outside.txt` is counted. Apply the same containment rule `main()`
already applies to `$STORY` (resolved path must be under `realpath "$PWD"`);
outside → refuse with `PAYLOAD_REF_MISSING` (config exit, before anything).
Make the refusal message, the code comment and the Dev Agent Record sentence
true. Add the `..` case to the AC-2 tests (and keep the absolute/dir/dangling
cases).

### F3 — R3: carry `SIZING_REFUSED` where the discipline says (medium)

The declared reason code appears in no artifact. Put `reason=SIZING_REFUSED`
on the `STORY-SIZING:` marker's first line and in the dispatch log line for
the refusal; assert both in the AC-4 test. (No result artifact is written on
refusal — that stays.)

### F4 — R8: the SKILL example path

`files/model-router/SKILL.md`'s `payload_refs:` example names a path that does
not exist; point it at a real file in this repository or mark it as
illustrative in the same sentence.

### F5 — the one-word doc↔schema loop closure

Add `budget_states` to the machine-checkable key list in
`tests/lifecycle-tests.sh` so the contract block and the `schema` verb are
compared by the suite that owns that loop (the worker deferred this as outside
its surface; it is in yours for this cycle only).

### F6 — post-review registry (record work, same story file)

Append `### Post-review fix cycle (AFK-PORT-1.5A-FIX)` to the Dev Agent Record
of `AFK-PORT-1.5A.md` listing R1–R9 with dispositions (R1 fixed F1, R2 fixed
F2, R3 fixed F3, R4 backlog, R5 backlog, R6 accepted, R7 accepted, R8 fixed
F4, R9 squash), the reviewer's diff-size opinion (overrun accepted for this
lane; budget tests and prose when scoping lanes B–D — a planning action), and
your own record: changes, gate tallies, commit SHA.

## Out of scope — hard stops

Any other change to `dispatch.sh`, the policy file, the contract beyond the
sentences F2/F3 make true, lanes B/C/D, Story 1.6/1.8 material, rewriting
existing commits.

## Gates and the known flake

Run all four gates yourself; `run-tests.sh` (~42 min) last, once. Its only
tolerated red is the recorded `lifecycle concurrency gate` aggregate (204/3,
the three publication-window assertions reproduced on pristine master —
`evidence/AFK-PORT-1.4-LV/coordinator-baseline-concurrency-master-8a56eb5.log`).
Outcome `succeeded` iff F1–F6 are done, the other three gates are green, and
that aggregate is the ONLY red. Any other red is `failed`, named verbatim.

## Dev Agent Record

(worker fills in)
