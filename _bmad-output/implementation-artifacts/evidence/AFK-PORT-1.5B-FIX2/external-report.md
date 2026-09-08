# Handoff: usage adapter mis-measures multi-turn claude runs; local workers need Edit

From: ai-control-plane PM session, 2026-09-07 late. Source run: the FIRST
natural-route gateway-backed local dispatch (story FU.1 in ai-control-plane,
`{claude, local-code-standard}` → qwen36-27b via ai-gateway, placement
kserve-a5000). Kit at e76cb95; installed dispatch.sh identical to HEAD.

Evidence in `evidence/`:
- `fu1-claude-result-envelope.json` — the `claude -p --output-format json`
  envelope the worker published (83 turns, 41.6 min).
- `fu1-thin-result.json` — the thin result dispatch wrote from it.

## 1. BUG — `usage_adapter_claude` reports cumulative run tokens as window occupancy

`files/model-router/scripts/dispatch.sh` ~L823-845 sums
`usage.input_tokens + cache_read_input_tokens + cache_creation_input_tokens`
from the end-of-run envelope and divides by the catalog window.

Observed: `usage 1,330,455 / window 65,536 = 20.301` → `BUDGET_STATE
CONTINUATION_REQUIRED`, finding `HIGH_USAGE`, thin result
`status: continuation_required`.

Why it is wrong: the envelope's `usage` (and `modelUsage.<model>.*`) is the
SUM over every API call in the run — 83 turns here — not the context of the
final call. A session cannot occupy 20 windows; it occupied ≤ 1 window 83
times. `modelUsage["qwen36-27b"].contextWindow` = 65536 is corroborated
correctly; only the numerator is the wrong quantity. Every multi-turn run on
any claude class will trip this, so the continuation lane is currently
unusable for real stories.

Constraints the fix must respect (LIFECYCLE-CONTRACT.md "Observed usage, and
who may observe it"): the kit scrapes no terminal and no transcript; the
end-of-run envelope is the only source under the frozen launch. The envelope
carries NO per-turn or final-context figure. Options I see — the agent
decides:
- (a) Under the frozen envelope: when `num_turns > 1`, report the cumulative
  figure as informational (`usage_tokens`, provenance HARNESS_ENVELOPE,
  a new reason such as `USAGE_CUMULATIVE_ONLY`) and set `usage_ratio: null`
  / `NOT_EVALUATED` rather than a window ratio. Honest, no contract change.
- (b) Contract change: `--output-format stream-json` and take the LAST
  assistant message's `usage` (input + cache_read + cache_creation of the
  final call = final context occupancy). Correct, but touches the frozen
  HARNESS-LAUNCH-claude contract and its evidence.
Acceptance: re-running the adapter on `fu1-claude-result-envelope.json`
never yields a `usage_ratio` > 1 presented as occupancy, and the policy
doc's `HIGH_USAGE` definition ("the run ENDED at or past checkpoint_ratio")
is only ever asserted from a per-window measurement.

### 1b. The state machine let the bogus ratio overwrite a gates-failed outcome
Dispatch log: `budget: usage reached the continuation band with gates failed
and no worker signal` → thin result `status: continuation_required` while
`gates` shows actionlint FAIL and the diff gate FAIL, and no checkpoint or
continuation artifact exists. A PM reading `status` alone would re-dispatch
this as a continuation. Gates failed should win; the budget finding is a
sizing note beside it, not the status. (See L1495-1545.)

## 2. RECOMMENDATION (owner decides) — add `Edit` to the frozen tool set

Both claude classes launch with `--tools "Read,Glob,Grep,Write"` (L130 native,
L183 gateway). With no Edit tool, every change is a whole-file rewrite. The
27B model rewrote a 130-line workflow from memory instead of copying it:
+132/−100 (triggers reordered, jobs renamed, `permissions:` blocks dropped)
for a 3-comment change. It edited the 40-line-context file correctly. Edit is
the same mutation class as Write under `acceptEdits`, so it widens nothing
about auth, provider or sandbox — but it IS a change to the frozen launch
text, so it needs the contract's evidence updated, not just the script.
Suggest applying it to both classes so the tool set stays one set.

## 3. Observations (no action required, recorded for the record)
- 14 `permission_denials`, all Read/Glob/Grep against
  `/home/devbox/repos/jlengelbrecht/ai-control-plane/...` — the MAIN checkout's
  absolute path, from inside an Orca worktree. The sandbox refused correctly.
  The model then reported "Read returned cached result from previous session".
  Cheap prompt hardening: state in the generated prompt that the repo root is
  the current directory and absolute paths must not be used.
- `total_cost_usd: 4.21` on a `cost_class: free` path is the CLI's client-side
  estimate (`costBasis: unknown`), per catalog R14. Verify nothing in the thin
  result or any aggregator treats it as spend.
- Timeline: launch 01:46:29Z, first file write 02:03:22Z, exit ~02:28Z.
  The A5000 KServe placement is scale-to-zero (~3 min to ready per the
  owner) and its readiness is `unknown` to the router (no heartbeat), so the
  policy picked it cold over a bazzite-5090 that reported the model cached.
  That is a catalog/router matter, not a kit one — noted so the agent does
  not chase it here.

## Routing (for the kit agent's session, not a stamped dispatch)
- Model: Opus, standard effort — a contained bash/jq fix with a clear
  reproduction; Fable only if option (b) reopens the launch contract.
- Gates: the kit's own test suite plus a fixture test that feeds
  `evidence/fu1-claude-result-envelope.json` through the adapter.
- Return: which option was taken, the fixture result, and whether the frozen
  contract text changed (if it did, ai-control-plane's
  `contracts/agent-router/HARNESS-LAUNCH-claude.md` needs the same change).
