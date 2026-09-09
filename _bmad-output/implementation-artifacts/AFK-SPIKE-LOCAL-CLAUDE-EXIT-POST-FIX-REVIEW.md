---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-SPIKE-LOCAL-CLAUDE-EXIT-POST-FIX-REVIEW.md.stamp.json
persona: dev
gates:
  - "git diff --check"
max_cycles: 1
---

# AFK-SPIKE-LOCAL-CLAUDE-EXIT: Post-fix review

Fresh-session, delta-scoped review of commit `544bb84` against the three
blockers and eight advisories recorded in
`evidence/AFK-SPIKE-LOCAL-CLAUDE-EXIT-REVIEW/REVIEW.md`.

## Required checks

1. Recompute the assistant-event usage shape and repeated-event counts from the
   retained cell-2 and cell-4 JSONL streams.
2. Confirm every non-historical proposed occupancy formula is exactly
   `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`, with
   output tokens excluded.
3. Confirm item 1 explicitly changes a valid multi-turn stream observation to
   `FINAL_CONTEXT`, names the budget/readiness consumers and assertions, and
   preserves cumulative-only behavior for cumulative inputs.
4. Confirm every nonempty malformed JSONL line poisons the stream; zero or
   multiple result events refuse; repeated assistant content-block events are
   not summed.
5. Confirm the fixture list covers the observed absent cache-creation member,
   explicit null, repeated assistant events, success, error, truncation,
   malformed input, and multiple results.
6. Confirm item 2 leaves a fenced partial stream in place only after the exact
   launcher-owned process is stopped, freezes its content/mtime, never removes
   the worktree, and never infers success.
7. Confirm advisory corrections are accurate and do not overstate evidence.
8. Confirm the three-item queue and order remain intact, all changes are under
   `_bmad-output/implementation-artifacts/`, no source evidence changed, and
   `git diff --check` passes.

Write the full review to
`evidence/AFK-SPIKE-LOCAL-CLAUDE-EXIT-POST-FIX-REVIEW/REVIEW.md`. The verdict
must be exactly `CLEAN` or `NOT CLEAN — N blockers`, with blockers separated
from advisories.

## Dev Agent Record

Fresh independent session. Review only: no gateway call, no live cell rerun, no
product, contract, test, catalog or registry file touched. The only repository
changes are this story and the new report, both written with the structured
`Write`/`Edit` tools.

Persona verified before starting —
`{ sha256sum SKILL.md; sha256sum customize.toml; } | sha256sum` returns
`4cdff719c4f3042532520611f7106d80393173004355e6a83771b366c3efc7f9`, the hash the
brief expects.

**Verdict: CLEAN.** All three blockers closed against the observed facts; all
eight advisories incorporated; four new advisories recorded, none of which
changes the queued work.

### Report

`evidence/AFK-SPIKE-LOCAL-CLAUDE-EXIT-POST-FIX-REVIEW/REVIEW.md`

### Required checks

| # | Check | Result |
| --- | --- | --- |
| 1 | Usage shape and repeated-event counts recomputed from cells 2 and 4 | Pass — 4/28 assistant events, `has("cache_creation_input_tokens")` false in all 32, 2/14 distinct usages, `output_tokens: 0` throughout, 15,134 and 17,842 reproduce |
| 2 | Every non-historical proposed occupancy formula is the three-member set | Pass for every prescriptive formula; the bundle's cumulative figures are still four-member sums (advisory B1) |
| 3 | `FINAL_CONTEXT` switch, named consumers, cumulative behaviour preserved | Pass — all five cited code locations resolve |
| 4 | Malformed line poisons the stream; zero/multiple results refuse; no summing | Pass |
| 5 | Fixture coverage | Pass — seven fixtures cover all eight required shapes |
| 6 | Fenced partial stream: stopped process first, frozen, worktree kept, never success | Pass |
| 7 | Advisory corrections accurate, not overstated | Pass — A1's pairing and A4's 17,244 / 12,623 recomputed; one clause flagged as B3 |
| 8 | Queue intact, scope, no evidence changed, `git diff --check` | Pass — three items in order, seven files all under `_bmad-output/implementation-artifacts/`, zero `sessions/` paths, all eight stream digests still match |

### Advisories raised

- **B1** — cumulative figures (2,301,235 / 1,433,412 / 333,985 / 236,349 and the
  35.1×, 21.9×, 5.10× ratios) still include `output_tokens`, so the FIX-2
  acceptance line "every proposed output-inclusive formula removed" over-claims.
  Direction of every finding is unaffected.
- **B2** — `lib/afk-commands.sh:638` is a second `PM_USAGE_CUMULATIVE_ONLY`
  consumer and is missing from the expected surface.
- **B3** — `INDEX.md`'s claim that the recorded digests "establish that the
  committed streams are the ones that were redacted" is one clause stronger than
  the provenance supports.
- **B4** — the two `tests/run-tests.sh` ranges bracket their assertions loosely.

### Gate

`git diff --check` — exit 0, no output.
