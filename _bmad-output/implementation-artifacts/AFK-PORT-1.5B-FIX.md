---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-PORT-1.5B-FIX.md.stamp.json
persona: dev
gates:
  - "bash tests/run-tests.sh"
  - "bash tests/lifecycle-readiness-tests.sh"
  - "bash tests/lifecycle-dispatch-tests.sh"
  - "bash tests/lifecycle-tests.sh"
  - "git diff --check"
max_cycles: 1
---

# AFK-PORT-1.5B-FIX — one bounded post-review fix cycle (fresh session)

Authorized by the coordinator after the independent review
(`evidence/AFK-PORT-1.5B-REVIEW/REVIEW.md`: NOT CLEAN — 1 blocker, 9
residuals; its scripts `atk-redact.sh`, `atk-status-matrix.sh`,
`atk-artifacts.sh`, `atk-usage.sh` are your oracles). **One cycle. Exactly
the eight items below.** You are a fresh session; you did not write the code
or the review. Frozen launch command texts stay byte-identical.

## In scope — exactly this

### F1 — BLK-1: the continuation reason never carries worker free text (blocker)

`artifact_redact` is a 24-character pattern denylist; the kit's own discipline
for caller-supplied free text is the closed vocabulary of `afk_safe_diagnostic`
(`lib/afk-common.sh`). Adopt the reviewer's option (a): the
`CONTINUATION-REQUIRED:` reason's CONTENT never reaches the marker, the log or
the result. Record only that a reason was given and its byte length (and, if
you want a human hint, a closed-vocabulary word set as `afk_safe_diagnostic`
does). Keep the stable code (`reason=CONTINUATION_ARTIFACT_INVALID` on the
refusal path; `CONTINUATION_REQUIRED` state otherwise). Delete
`artifact_redact` if nothing else needs it. Tests: the AC-5 block gains
sentinels that are SHORT (`hunter2`), keyword-adjacent (`password=Tr0ub4dor&3`)
and broken by `:`/`=`, and asserts none reach marker, log or result; keep the
anti-vacuity control by asserting the byte length is recorded instead of the
words.

### F2 — RES-1: a finished run is never `CONTINUATION_REQUIRED`

When gates pass and the worker gave no continuation signal, an end-of-run
ratio at or above the continuation threshold maps to `budget.state: OK` (or
`CHECKPOINT_DUE` per the checkpoint rule) plus the `HIGH_USAGE` finding — a
sizing observation, not a continuation. `CONTINUATION_REQUIRED` is reached
only from the worker's signal or from a ratio on an UNFINISHED run (gates
failed). Add the row to the contract's decision table and assert the full
matrix (`atk-status-matrix.sh` is the shape).

### F3 — RES-2: checkpoint freshness

Capture the checkpoint artifact's pre-launch sha like the continuation one;
a byte-identical checkpoint after the run is not this cycle's: record finding
`CHECKPOINT_ARTIFACT_STALE` and do not publish it as `checkpoint_artifact`.
Test it.

### F4 — RES-3 and RES-4: the claude adapter reports only what it saw

A `usage` object lacking all three token members (`input_tokens`,
`cache_read_input_tokens`, `cache_creation_input_tokens`) is
`USAGE_UNOBSERVABLE`, never `usage_tokens: 0`. Window corroboration uses an
EXACT `modelUsage` key match only; drop the single-entry fallback; when no key
matches, record `WINDOW_UNCORROBORATED` (finding) and `window_reported_tokens:
null`. Tests for both.

### F5 — RES-5 and RES-7: the discipline paragraph and the signal

Add the ruling's second trigger to the prompt paragraph ("or when the harness
signals context pressure"), byte-stable. A `CONTINUATION-REQUIRED:` line with
an empty reason is an invalid signal: take the existing invalid-artifact path
(`NEEDS_HUMAN`, no result). Tests for both.

### F6 — RES-6 (bounded): anchor and document

Keep the `^CONTINUATION-REQUIRED:` line-anchored match (it mirrors the frozen
`NEEDS-HUMAN` channel) but make the paragraph tell the worker never to quote
the marker, and document in the contract that the codex terminal tail is
bounded (`--limit 5000`) so a signal can scroll out on a chatty run — recorded
as a known limitation, not fixed here.

### F7 — RES-8 and RES-9: contract and sweep hygiene

Document `needs_human` in the contract's `dispatch_result_statuses` block as a
delivery-only status (or move it to the delivery block if the machine-checkable
structure allows without a schema-major change), and add `budget.usage_reason`
to the readiness suite's unpublished-reason sweep so every emitted reason is
published.

### F8 — post-review registry (record work)

Append `### Post-review fix cycle (AFK-PORT-1.5B-FIX)` to the Dev Agent Record
of `AFK-PORT-1.5B.md` listing BLK-1 and RES-1…RES-9 with dispositions, then
your own record: changes, gate tallies, commit SHA (a single commit cannot
carry its own hash — say so; the coordinator records it).

## Out of scope — hard stops

Lane C/D work; any change to the frozen launch command texts, `make-stamp.sh`,
the validator, the catalog; rewriting existing commits; the reviewer's
evidence directory (coordinator-retained).

## Gates and the known flake

Run all five gates yourself; `run-tests.sh` (~45 min) last, once. Its only
tolerated red is the recorded `lifecycle concurrency gate` aggregate (204/3,
publication-window assertions reproduced on pristine master). Outcome
`succeeded` iff F1–F8 are done, the other four gates are green, and that
aggregate is the ONLY red; anything else is `failed`, named verbatim.

## Dev Agent Record

(worker fills in)
