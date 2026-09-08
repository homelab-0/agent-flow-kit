---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-PORT-1.5B-FIX2.md.stamp.json
persona: dev
gates:
  - "bash tests/run-tests.sh"
  - "bash tests/lifecycle-readiness-tests.sh"
  - "bash tests/lifecycle-dispatch-tests.sh"
  - "bash tests/lifecycle-tests.sh"
  - "git diff --check"
max_cycles: 1
---

# AFK-PORT-1.5B-FIX2 — the usage adapter measured the wrong quantity (externally reported)

Reported 2026-09-07 by the ai-control-plane PM from the first natural-route
gateway-backed dispatch in that repository (story FU.1, `{claude,
local-code-standard}` → qwen36-27b, 83 turns, 41.6 min). Evidence provisioned
into this worktree at `_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.5B-FIX2/`:
`fu1-claude-result-envelope.json` (the `claude -p --output-format json`
envelope) and `fu1-thin-result.json` (what `dispatch.sh` wrote from it).
Corroborated by the coordinator on the kit's own M4R smoke envelope (20
turns): the same adapter would report ratio 3.8 on a run that occupied one
window.

**One cycle. Exactly the six items below.** You are a fresh session. Frozen
launch command texts and `lib/afk-monitor.sh` stay byte-identical.

## The defect

`usage_adapter_claude` sums `usage.input_tokens + cache_read_input_tokens +
cache_creation_input_tokens` from the END-OF-RUN envelope and divides by the
catalog window. Those members are the SUM over every API call in the run,
not the context of the final call. FU.1: `1,330,455 / 65,536 = 20.30` →
`budget.state: CONTINUATION_REQUIRED`, `HIGH_USAGE`, and — because the
gates had failed and no worker signal existed — thin-result `status:
continuation_required` with NO checkpoint or continuation artifact. A PM
reading the status would re-dispatch a continuation from nothing.

## Design ruling (coordinator, binding): option (a), no contract change

The envelope carries no per-turn or final-context figure, and the kit reads
no terminal or transcript. Therefore:

### F1 — cumulative usage is informational, never occupancy

When `num_turns > 1`, the adapter reports the cumulative figure as
`usage_tokens` with `usage_provenance: HARNESS_ENVELOPE`,
`usage_scope: CUMULATIVE_RUN`, `usage_reason: USAGE_CUMULATIVE_ONLY`, and
`usage_ratio: null`; `budget.state` from usage is `NOT_EVALUATED` for that
reason (lane A's pre-dispatch verdict stands as before). When
`num_turns == 1` the envelope IS the single call's context: report
`usage_scope: FINAL_CONTEXT` and evaluate the ratio as today. `HIGH_USAGE`
and any threshold state are asserted ONLY from a `FINAL_CONTEXT`
measurement; document that the policy's "the run ENDED at or past
checkpoint_ratio" means exactly that. Add the fixture test: feed the FU.1
envelope through the adapter and assert `usage_ratio` is null, scope
`CUMULATIVE_RUN`, no `HIGH_USAGE`, state `NOT_EVALUATED`; feed a
single-turn envelope and assert a ratio. Keep the fixtures under
`tests/fixtures/` (copy the FU.1 envelope there; it is secret-free — the
coordinator checked by exact match).

### F2 — gates decide the status; a continuation needs an artifact

`status: continuation_required` is set ONLY when the worker signalled
`CONTINUATION-REQUIRED:` with a valid continuation artifact. A ratio-derived
`CONTINUATION_REQUIRED` (now only reachable from a `FINAL_CONTEXT`
measurement) never changes the status: gates failed → `gates_failed`, gates
passed → `done` (lane B's F2 demotion still applies), with the budget state
and findings beside it as sizing notes. Update the contract's decision table
and the matrix test (`atk-status-matrix.sh` shape) so no row publishes
`continuation_required` without an artifact identity.

### F3 — the prompt names the working directory

Add one launcher-owned sentence to the generated prompt (data, byte-stable):
the repository root is the current working directory `<absolute worktree
path>`; use relative paths; absolute paths outside it are refused. (Registry
item 20; FU.1 recorded 14 denials against the main checkout's absolute
path.) Assert it is present and that the story/persona cannot alter it.

### F4 — cost is never spend

Assert (test + one contract sentence) that `total_cost_usd` from the
envelope is not carried into the thin result or any kit aggregate: the
envelope's figure is a client-side estimate (`costBasis: unknown`) and on a
`cost_class: free` path it is not money.

### F5 — lane C carry-over: the cap marker never lowers `max_cycles`

From the lane C post-fix review (N4, N2): the `CONTINUATION-CAP:` marker's
suggested `max_cycles:` is the larger of the story's existing value and the
cycle being authorised, so applying it never lowers a limit; and the contract
states plainly that `max_cycles` still bounds continuations under the cap.
Test both.

### F6 — registry (record work)

Append `### External report and fix cycle (AFK-PORT-1.5B-FIX2)` to the Dev
Agent Record of `AFK-PORT-1.5B.md`: the report, the ruling (option (a)), the
Edit-tool recommendation deferred to the owner (out of scope here), the
KServe cold-start note as a catalog/router matter, then your record:
changes, fixture results, gate tallies, commit SHA note.

## Out of scope — hard stops

Option (b) (`stream-json`) or any change to the frozen launch command texts,
including the tool set (`Edit` is an owner decision with contract evidence
to update); `lib/afk-monitor.sh`; lanes C/D; the catalog; scraping.

## Gates and the known flake

Run all five gates yourself; `run-tests.sh` last, once; its only tolerated
red is the recorded `lifecycle concurrency gate` aggregate (204/3). Outcome
`succeeded` iff F1–F6 are done, the other four gates are green, and that
aggregate is the ONLY red.

## Dev Agent Record

(worker fills in)
