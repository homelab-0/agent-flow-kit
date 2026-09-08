---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-PORT-1.5C-FIX.md.stamp.json
persona: dev
gates:
  - "bash tests/run-tests.sh"
  - "bash tests/lifecycle-readiness-tests.sh"
  - "bash tests/lifecycle-dispatch-tests.sh"
  - "bash tests/lifecycle-tests.sh"
  - "git diff --check"
max_cycles: 1
---

# AFK-PORT-1.5C-FIX — one bounded post-review fix cycle (fresh session)

Authorized by the coordinator after the independent review
(`evidence/AFK-PORT-1.5C-REVIEW/REVIEW.md`: NOT CLEAN — 2 blockers, 4
residuals; its scripts `attack-03-cap-vs-maxcycles-and-agnosticism.sh` and
`attack-05-cap-bypass.sh` are your oracles). **One cycle. Exactly the seven
items below.** You are a fresh session; you did not write the code or the
review. Frozen launch command texts stay byte-identical; `lib/afk-monitor.sh`
stays byte-identical.

## In scope — exactly this

### F1 — B1: the cap gate is reachable and its remedy works

Run the continuation-cap gate BEFORE the `max_cycles` check, so a capped
story gets the typed `CONTINUATION-CAP:` refusal, not the untyped
`max_cycles` message. Make the marker's suggested frontmatter block carry
BOTH the `continuation_decision:` and the `max_cycles:` value the authorised
cycle needs (computed: the cycle being authorised), and say so in the contract
section and the SKILL paragraph. Test: at the shipped defaults (`max_cycles`
absent and `max_cycles: 3`) the third continuation is refused with the typed
marker, and applying the marker's block VERBATIM lets the authorised cycle
proceed (the reviewer's section A/B shape, plus its control).

### F2 — B2: the cap counts every hand-over ever consumed, and cycles are never re-run in place

Replace the count-from-overwritable-results with an APPEND-ONLY ledger
`<story>.continuations.json` (schema `afk-continuation-ledger/1`: one entry
per continuation LAUNCH — cycle, from_cycle, artifact_sha256, trigger, at,
decision (nullable)), written under the same exclusive lock as the record
append immediately before the launch, never rewritten or pruned. The
consumed count is the ledger length regardless of cycle numbers. A cycle
number that already has a retained result (`<story>.result.c<n>.json`) or a
ledger entry is never re-run in place: dispatching it refuses fail-closed
with `reason=CYCLE_ALREADY_RETAINED` (`NEEDS_HUMAN` exit, `.blocked` marker
naming the next free cycle), before placement — a continuation is always the
next cycle. Retained results are therefore never overwritten. Tests: the
reviewer's bypass (re-dispatch cycle 3 after the cap refused cycle 4 →
refused, no launch), the deflation (count unchanged), the control (cycles 4
and 5 still refused without a decision), and the happy path (two
continuations proceed, ledger has two entries, the third refuses).

### F3 — R1: the decision's `cycle` accepts a numeric string

Compare with `tonumber?` so `cycle: "4"` authorises cycle 4; the marker
example stays unquoted. Test both spellings.

### F4 — R2: the continuation artifact names its story

The prompt paragraph asks the worker to include `story_id` (the story file's
basename without extension) in the continuation artifact; the launcher
validates it when present and treats a mismatch as invalid (`NEEDS_HUMAN`,
`CONTINUATION_ARTIFACT_INVALID`, reason detail `STORY_MISMATCH`); an absent
`story_id` is accepted this cycle (additive, schema stays `afk-continuation/1`)
and recorded as finding `CONTINUATION_ARTIFACT_UNBOUND`. Test mismatch,
match, absent.

### F5 — R3: a continuation refused by sizing leaves a record line

After the sizing refusal on a continuation cycle, append one dated line
(code `CONTINUATION_REFUSED`, detail: from cycle, estimate/window/ratio)
through `record_budget_line`, keeping the estimate itself deterministic
(the line is appended after the estimate, as today). Test it.

### F6 — R4: document the unpruned series as load-bearing

One sentence in the contract: the retained per-cycle results and the ledger
are never pruned because the cap is counted from them.

### F7 — post-review registry (record work)

Append `### Post-review fix cycle (AFK-PORT-1.5C-FIX)` to the Dev Agent Record
of `AFK-PORT-1.5C.md` listing B1, B2, R1–R4 with dispositions, then your own
record: changes, gate tallies, commit SHA (say a single commit cannot carry
its own hash; the coordinator records it).

## Out of scope — hard stops

Lane D; any change to the frozen launch command texts, `lib/afk-monitor.sh`,
`make-stamp.sh`, the validator, the catalog; rewriting existing commits; the
reviewer's evidence directory.

## Gates and the known flake

Run all five gates yourself; `run-tests.sh` (~45 min) last, once. Its only
tolerated red is the recorded `lifecycle concurrency gate` aggregate (204/3,
publication-window assertions reproduced on pristine master). Outcome
`succeeded` iff F1–F7 are done, the other four gates are green, and that
aggregate is the ONLY red; anything else is `failed`, named verbatim.

## Dev Agent Record

(worker fills in)
