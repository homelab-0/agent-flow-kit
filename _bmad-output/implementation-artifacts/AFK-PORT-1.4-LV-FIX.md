---
linear:
stamp: AFK-PORT-1.4-LV-FIX.md.stamp.json
persona: dev
gates:
  - "bash tests/run-tests.sh"
  - "bash tests/lifecycle-readiness-tests.sh"
  - "git diff --check"
max_cycles: 1
---

# AFK-PORT-1.4-LV-FIX — one bounded post-review fix cycle (fresh session)

Authorized by the coordinator after the independent review
(`evidence/AFK-PORT-1.4-LV-REVIEW/REVIEW.md`, verdict NOT CLEAN — 1 blocker,
9 residuals). **One cycle. Exactly the six items below.** The blocker (B-1,
commit-message trailers) is handled by the coordinator at packaging, not by
you — do not rewrite history. Everything else the review found is already
dispositioned: do not fix it, do not touch it.

You are a fresh session; you did not write this code and you did not review
it. Read the review first (sections 1, 2 and the AC table), then the story
`AFK-PORT-1.4-LV.md` (spec + Dev Agent Record). The reviewer's attack scripts
in the evidence directory are your oracles where named.

## In scope — exactly this

### F1 — R-2: `set +x;` at the head of the gateway command text

`files/model-router/scripts/dispatch.sh`, the gateway builder: the generated
text assigns the resolved credential to a shell variable before `env -i`, so
an inherited xtrace (`set -x` in a login rc, `BASH_ENV`) renders the value into
the persisted terminal buffer (reproduced: `attack-03` P4/P4b). Prefix the
generated gateway command text with `set +x; ` before the assignment. The
native command text stays byte-identical (the byte-identity comparison in the
suite remains your oracle). Add an assertion in `tests/run-tests.sh` that the
gateway command text begins with `set +x;` and that the native text does not
change.

### F2 — R-8: no stale result artifact after a gateway preflight refusal

`rm -f "$result_file"` currently sits after the gateway preflights, so a
refusal leaves last cycle's `${STORY}.claude-result.json` on disk. Hoist the
removal above the preflights. Add a case to the AC-4 block: pre-create a stale
result file, trigger one refusal (endpoint unset), assert the stale file is
gone and no result artifact exists.

### F3 — R-5: the empty-read refusal is exercised through `orca_launch`

The suite's stub `terminal read` always answers `status:"running"`, so the
class's key safety property (a launch that ends without a `CLAUDE_EXIT` line
is reported as a launch failure, never `status: done`) is argued, not
asserted. Give the stub a way to report `exited` with no exit line (an env
knob the test sets), add one case that drives a gateway launch into it, and
assert: dispatch exit 2, stderr says the launch did not complete honestly, no
`${STORY}.result.json`. The reviewer's `attack-07` shows the shape.

### F4 — R-7: two sentences claim more validation than happened

- `docs/LIFECYCLE-CONTRACT.md`: replace "…live-validated for that pair, and it
  is five per-process variables" with wording that says four validated
  variables plus the context-window caveat the catalog records (F3 of
  STORY-036-1).
- `dispatch.sh` header: "The launch classes this adapter implements, all
  live-validated and frozen" → "whose contracts are live-validated and
  frozen" (this adapter's gateway implementation has not yet been launched
  against a live gateway; the smoke re-run is a separate story).

### F5 — R-1: correct the record's risk statement

In `AFK-PORT-1.4-LV.md`, Dev Agent Record, disclosed item 1 and the residual
paragraph under "Credential conveyance": the `env` argv window is NOT
same-user-only on a default Linux host — `/proc/<pid>/cmdline` is mode 0444
and this host's `/proc` mounts without `hidepid`; the reviewer's `attack-03`
P5 read the sentinel from another process's cmdline during the launch. State
that correctly, name `hidepid=2` on `/proc` as the interim fleet mitigation,
and keep the `sh -c` wrapper as the prox-ops contract amendment already
assigned to the coordinator. Do not change the code for this item.

### F6 — post-review registry (record work, same story file)

Append a section `### Post-review fix cycle (AFK-PORT-1.4-LV-FIX)` to the Dev
Agent Record of `AFK-PORT-1.4-LV.md` listing B-1 (coordinator, at packaging)
and R-1…R-9 with their dispositions: R-1 record corrected (F5), R-2 fixed
(F1), R-3 backlog, R-4 accepted, R-5 test added (F3), R-6 kept with a one-line
annotation in the test block saying the structural assertions are backed by
the reviewer's runtime proof (`attack-03`), R-7 fixed (F4), R-8 fixed (F2),
R-9 no action. Then your own record: what you changed, gate tallies, commit
SHA.

## Out of scope — hard stops

- Any other change to `dispatch.sh`, the readiness library, the catalog, the
  MiniMax pair, the discriminator, the credential mechanism itself.
- Rewriting existing commits or their messages (coordinator's job).
- R-3 shape-checking the header value; a readiness live probe; the prox-ops
  contract; the smoke re-run.

## Gates and the known flake

Run all three gates yourself and paste the tallies. `tests/run-tests.sh`
(~42 min) exits 1 on this host on ONE aggregate assertion, `lifecycle
concurrency gate` (204 passed, 3 failed: "a contender that observed the window
waits it out rather than refusing", "and reports the live owner it was waiting
for", "so nothing it says can be read as 'this lock has no owner'"). That is a
recorded pre-existing host-timing flake reproduced on pristine `master`
(`evidence/AFK-PORT-1.4-LV/coordinator-baseline-concurrency-master-8a56eb5.log`).
Report it verbatim. Outcome `succeeded` iff every other assertion in
`run-tests.sh` passes, the other two gates are green, and the ONLY failure is
that aggregate with exactly those three sub-assertions. Any other red is
`failed`, named verbatim.

## Dev Agent Record

(worker fills in)
