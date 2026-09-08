---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-PORT-1.5B.md.stamp.json
persona: dev
gates:
  - "bash tests/run-tests.sh"
  - "bash tests/lifecycle-readiness-tests.sh"
  - "bash tests/lifecycle-tests.sh"
  - "git diff --check"
max_cycles: 3
---

# AFK-PORT-1.5B — Usage observation, checkpoint and continuation artifacts, budget state

Lane B of four for the frozen Story 1.5 (`AFK-PORT-1.5.md`; authority: PRD
addendum Capability 5, FR-99 evaluation, FR-100, FR-101, FR-104, FR-105;
NFR-13–15). Lane A (merged, PR #30) provides the window, the sizing estimate,
the policy file with `checkpoint_ratio`, `continuation_ratio` and the budget
states declared, and the `budget` thin-result member. Lane C (continuation
dispatch, cap) and lane D (ORCH PM budget) follow; leave documented seams,
not implementations.

Budget for this lane INCLUDING tests and prose: ≤ 800 reviewable lines. Scope
was cut to fit; if you cannot fit, stop and disclose rather than absorb.

## Design ruling (coordinator, binding for this lane)

The frozen launch command texts stay byte-identical: no `stream-json` for
claude, no `--json` for codex. Consequences, all consistent with FR-104:
- Under `claude -p`, usage is observable only from the END-OF-RUN result
  envelope (`modelUsage[<model>]` and `usage`). Mid-run usage is
  `NOT_EVALUATED`. The harness adapter reports what it can, with provenance.
- Under `codex exec` without `--json`, usage is not observable at all: the
  codex adapter reports `NOT_EVALUATED` / `USAGE_UNOBSERVABLE`. It never
  becomes core fallback logic and never blocks the claude path.
- Mid-run checkpoint/continuation discipline is therefore DETERMINISTIC
  PHASE-BOUNDARY POLICY carried in the generated prompt: the worker
  checkpoints at declared boundaries regardless of usage, and stops with a
  continuation artifact at the next boundary when it judges it cannot finish
  or when the harness signals context pressure. The kit evaluates observed
  usage after the run and reconciles it with the worker's signal.

## Scope

**S1 — usage adapters (FR-104, NFR-13).** In `dispatch.sh`, a per-harness
usage reader: `claude` reads the retained result envelope and yields
`usage_tokens` (the last turn's `input_tokens + cache_read_input_tokens +
cache_creation_input_tokens` from `usage`, i.e. the context actually held at
the last request), `window_tokens` (`modelUsage[<model>].contextWindow`, used
ONLY as corroboration — the budget window remains the catalog's per lane A;
disagreement is recorded, never resolved by the kit), `provenance:
HARNESS_ENVELOPE`, `observed_at: END_OF_RUN`. `codex` yields
`NOT_EVALUATED` / `USAGE_UNOBSERVABLE`. No terminal or transcript reading.
Adapters are named functions per harness; the core calls one interface.

**S2 — post-run evaluation (FR-99).** With a catalog window and an observed
usage, `usage_ratio = usage/window` (parts per million, same arithmetic as
lane A) against the policy's `checkpoint_ratio` and `continuation_ratio`:
`budget.state` = `OK` | `CHECKPOINT_DUE` | `CONTINUATION_REQUIRED`, with
`budget.usage_tokens`, `budget.usage_ratio`, `budget.usage_provenance`,
`budget.observed_at`. Unobservable or undeclared → `NOT_EVALUATED` with the
reason (`USAGE_UNOBSERVABLE` / `CONTEXT_WINDOW_UNDECLARED`). A ratio at or
above the checkpoint threshold at end of run adds finding `HIGH_USAGE` to
`budget.findings` (the PM's story-sizing signal, FR-105).

**S3 — worker discipline in the prompt (FR-100, FR-101, FR-104 fallback).**
The generated prompt gains a fixed, launcher-owned paragraph (data, never
shell) naming: the checkpoint artifact path `<story>.checkpoint.json`, its
required members (`completed`, `current_state`, `remaining_acceptance`,
`next_steps`, `updated_at`, `schema: afk-checkpoint/1`), the declared phase
boundaries at which it MUST be written or refreshed (after reading the story;
after implementation and before gates; before reporting), the continuation
artifact path `<story>.continuation.json` (`schema: afk-continuation/1`;
checkpoint members plus `in_flight` and `unretired_findings`), and the rule:
if you cannot finish, stop at the next boundary, write the continuation
artifact, and print one line `CONTINUATION-REQUIRED: <one-line reason>` then
end your turn. Both artifacts are secret-free by rule and are redacted by the
kit's existing redaction on read (S4).

**S4 — artifact handling (FR-100, FR-101, FR-105).** After the run, the
launcher validates any present checkpoint/continuation artifact (schema id,
required members, JSON parse) through the same redaction rules as other
lifecycle output (the existing sentinel discipline applies: a secret-looking
value is never echoed into a result or log). A `CONTINUATION-REQUIRED:` line
with a valid artifact → `budget.state: CONTINUATION_REQUIRED`, thin-result
`status: continuation_required` (additive within the result schema major),
`budget.continuation_artifact` = path + sha256, and the story record gains
one dated line (locked, idempotent per cycle, reusing lane A's append).
A `CONTINUATION-REQUIRED:` line with a MISSING or UNPARSEABLE artifact → the
story enters loud `NEEDS_HUMAN` (`.blocked` marker, reason
`CONTINUATION_ARTIFACT_INVALID`, the existing needs-human exit) and no
result claims completion. Observed usage ≥ continuation threshold with gates
failed and no worker signal → `budget.state: CONTINUATION_REQUIRED` and
`status: continuation_required` as well (the kit never reports headroom it
cannot see, and never manufactures a completed result). Actual continuation
DISPATCH is lane C: this lane only produces the signal and the artifact.

**S5 — budget field on the kit's own state (FR-105).** The dispatch monitor's
watch record and the `status` rendering gain a bounded `context_budget`
member per watched dispatch (`OK` | `CHECKPOINT_DUE` | `CONTINUATION_REQUIRED`
| `NOT_EVALUATED`) sourced from the retained thin result on reconcile; the
contract documents it as introduced here with no retroactive requirement on
the frozen 1.3 deliverable. `NEEDS_HUMAN` for an invalid continuation
artifact surfaces through the existing monitor path.

**S6 — contract, schema, docs.** `docs/LIFECYCLE-CONTRACT.md` `## The context
budget` extended: adapters and provenance, phase boundaries, artifact
schemas, the two new statuses/reasons (`continuation_required`,
`CONTINUATION_ARTIFACT_INVALID`, `USAGE_UNOBSERVABLE`, `HIGH_USAGE`), the
`context_budget` watch member; reason codes added to the policy file's
declared list; `SKILL.md` one paragraph. Every sentence true of the code.

**S7 — tests (both harnesses).** `tests/run-tests.sh`: claude envelope
fixtures at ratios below/at/above both thresholds (boundary equality counts
as crossing); codex → `NOT_EVALUATED`; window disagreement recorded; the
prompt paragraph present and byte-stable; valid checkpoint accepted; invalid
or missing continuation artifact → `NEEDS_HUMAN` marker, no result claiming
done; valid continuation → `continuation_required` status + record line
(idempotent); redaction: a sentinel inside an artifact never reaches result,
log or marker; both frozen launch texts byte-identical (existing oracle).
`tests/lifecycle-dispatch-tests.sh`: watch record carries `context_budget`
after reconcile; `NEEDS_HUMAN` surfaces. `tests/lifecycle-readiness-tests.sh`:
`schema` lists the new status/reasons.

## Out of scope — hard stops

Continuation dispatch, the cap and its PM decision (lane C); the ORCH PM
budget (lane D); Story 1.6 registry codes beyond the reason-code discipline;
any change to the frozen launch command texts, `make-stamp.sh`, the
validator, the catalog, `/v1/route` requests; terminal or transcript reading;
retrofitting the frozen 1.3 orchestration document.

## Acceptance criteria

- **AC-1** claude usage from the envelope with provenance; codex
  `NOT_EVALUATED`; no scraping (S1, tests).
- **AC-2** post-run state from policy thresholds with boundary equality
  crossing; `HIGH_USAGE` finding at ≥ checkpoint (S2, tests).
- **AC-3** prompt paragraph names artifacts, members, boundaries and the
  stop rule; byte-stable; data never shell (S3, tests).
- **AC-4** valid continuation → `continuation_required` status, artifact
  identity recorded, story-record line; invalid/missing → loud `NEEDS_HUMAN`;
  never a manufactured completion (S4, tests).
- **AC-5** artifacts pass the kit's redaction; sentinel proof (S4, tests).
- **AC-6** `context_budget` on the watch record and `status` rendering;
  additive, no 1.3 retrofit (S5, tests).
- **AC-7** contract/schema/docs true of the code; policy reason list extended
  (S6).
- **AC-8** both harnesses exercised; frozen launch texts byte-identical (S7).
- **AC-9** gates green (concurrency aggregate the only tolerated red);
  reviewable diff ≤ 800 lines INCLUDING tests and docs, reported; record
  states seams left for lanes C/D.

## Dev Agent Record

Persona proof (BMAD dev, computed first): outer
`07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee`, intermediates
`b980cf2c…` (SKILL.md) and `f3f107f1…` (customize.toml) — match, no stop.

### Method choices

**How the window is resolved.** Unchanged from lane A: the catalog's
`min_context` for the stamped profile, read exactly, on every path. The claude
envelope's `modelUsage[<model>].contextWindow` is read only as
`window_reported_tokens`; where it disagrees the finding `WINDOW_DISAGREEMENT`
is recorded and the disagreement is left standing. Picking a winner between two
authorities would have made the kit a third one. The adapter resolves the
envelope key by the stamped native model, falling back to the single entry when
there is exactly one and to null otherwise — it never guesses which of several
models the run used.

**Estimate inputs.** Untouched. The pre-dispatch estimate, its inputs and its
`bytes4-v1` method are lane A's and were not reopened; observed usage is a
second, separately-labelled member beside it, never a correction to it.

**Refusal ordering.** Post-run work sits after the existing `NEEDS-HUMAN` exit
(a blocked worker's usage is not a budget verdict on the story) and before the
gates (an attempt that stopped at a phase boundary did not finish; gates over a
deliberately half-finished tree describe the stop, not the story). Inside the
block: checkpoint first (a finding at worst), then the continuation signal,
whose invalid-artifact path refuses with exit 3 and writes **no result
artifact** — the same shape the existing NEEDS-HUMAN path uses. Within the
artifact check the window is tested before usage: without a window nothing could
ever be evaluated, whatever the harness published.

**The one design change against my first draft.** My first cut let an
unobservable usage overwrite `budget.state` with `NOT_EVALUATED`. Running the
suite showed that regressing six of lane A's merged assertions, and lane A was
right: the pre-dispatch verdict is a real conclusion about a real estimate, and
replacing it reports *less* than the kit knows. Unobservability now lands in
`usage_provenance` and a new `usage_reason` member, and `CHECKPOINT_DUE` /
`CONTINUATION_REQUIRED` are reached only from a computed ratio or a worker's own
signal — never inferred. The frozen lane A behaviour is byte-for-byte intact.

**Record-append idempotence.** Lane A's `record_sizing_risk` was generalised to
`record_budget_line <story> <cycle> <code> <detail>` — same lock, same awk
insertion, same line format, with idempotence now keyed on **code plus cycle**
so one cycle can record both a sizing observation and a continuation and neither
suppresses the other. The concurrency race test was moved onto the new signature
unchanged.

**Artifact freshness.** A continuation artifact is deliberately *not* removed
before launch the way the result artifact is — lane C is meant to resume from
it. Freshness is proved by identity instead: the pre-launch sha256 is captured,
and a byte-identical artifact after the run is `ARTIFACT_STALE`. This is the one
place the design differs from the "remove stale artifacts first" habit, and the
reason is written into the contract.

**Redaction.** Only artifact *identity* (path + sha256) reaches the result, so
member values cannot leak by construction; validation verdicts come from a
closed vocabulary and never quote the offending value. The single piece of
worker free text that does reach a marker — the `CONTINUATION-REQUIRED:` reason
— goes through `artifact_redact` via the `BUDGET_REDACT_FN` indirection, mirror-
ing `lib/afk-common.sh`. The sentinel test has an explicit anti-vacuity control:
the worker's own words are asserted PRESENT in the marker, so the sentinel's
absence is attributable to the redactor rather than to an empty path.

### Files touched

- `files/model-router/scripts/dispatch.sh` — usage adapters, post-run
  evaluation, prompt discipline paragraph, artifact validation + redaction,
  `record_budget_line`, result members, `continuation_required` status/exit.
- `files/model-router/context-budget-policy.yaml` — five reason codes.
- `lib/afk-monitor.sh` — `result.context_budget` on the watch record (bounded on
  read) and `context_budget` in the `status` rendering.
- `lib/afk-commands.sh` — `budget_reason_codes` and `dispatch_result_statuses`
  in `schema` (the enum only, per the declared surface).
- `docs/LIFECYCLE-CONTRACT.md`, `files/model-router/SKILL.md` — S6 prose.
- `tests/run-tests.sh` (section 3d + a stub hook), `tests/lifecycle-dispatch-tests.sh`,
  `tests/lifecycle-readiness-tests.sh`, `tests/lifecycle-tests.sh` (one vocabulary
  key).

### Diff size

`git diff --stat master` excluding this story file: **800 insertions, 34
deletions across 10 files** — at the ≤ 800 budget, and 10 of the ≤ 25 file
budget. Scope was cut to reach it; see the deferrals below.

### Gates

Run from the worktree, in full, by me:

| gate | result |
|---|---|
| `bash tests/run-tests.sh` | **555 passed, 1 failed**, exit 1, 2633s — the single failure is the recorded concurrency aggregate below; every other section green, including the sub-gates it runs (mutation 577/0, readiness 286/0, dispatch 256/0) |
| `bash tests/lifecycle-tests.sh` | **478 passed, 0 failed**, exit 0, 467s |
| `bash tests/lifecycle-readiness-tests.sh` | **286 passed, 0 failed**, exit 0, 293s |
| `git diff --check` | clean, exit 0 |

`tests/lifecycle-dispatch-tests.sh` is not one of the four declared gates but
carries lane B's AC-6 test, so it was run too: **256 passed, 0 failed**.

**The one tolerated red, reported verbatim.** `tests/run-tests.sh` section 8:

```
8. Lifecycle concurrency gate — tests/lifecycle-concurrency-tests.sh
  FAIL lifecycle concurrency gate
        204 passed, 3 failed
```

Run directly to name its three sub-assertions:

```
  FAIL a contender that observed the window waits it out rather than refusing
  FAIL and reports the live owner it was waiting for
  FAIL so nothing it says can be read as 'this lock has no owner'
204 passed, 3 failed
```

Identical — same tally, same three assertions, same publication-window scenario
(section 10, "a lock caught mid-publication is waited on, not condemned") — to
the recorded pre-existing baseline reproduced on pristine master at 8a56eb5,
`_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.4-LV/coordinator-baseline-concurrency-master-8a56eb5.log`.
Nothing in this lane touches locking. It is the only red.

### Deferred, deliberately, and disclosed

- **No mid-run usage, and no `stream-json`.** Diagnosis: the launch texts are
  frozen and the lane's ruling is binding. The consequence is recorded as
  contract text rather than worked around.
- **Assertions cut to fit 800 lines.** Roughly twenty low-marginal-value
  assertions were removed from section 3d during trimming (redundant field
  echoes, a second above-threshold band sample, an unparseable-envelope case
  already covered by the missing-envelope one). Every AC keeps at least one
  falsifiable check; the cuts were duplicates, not coverage.
- **A checkpoint's *content* is validated for shape, not for usefulness.** A
  checkpoint whose `next_steps` is `[]` passes. Diagnosis: judging resumption
  quality needs the story's semantics, which the launcher does not have; the
  members are the contract, and lane C's resume is where emptiness will bite
  visibly.
- **`CHECKPOINT_DUE` produces no action of its own this lane.** It is a reported
  state; nothing re-dispatches or nudges on it. That is lane C's cap-and-dispatch
  work, and inventing half of it here would be the seam growing an implementation.

### Seams left for lanes C and D

- **Lane C (continuation dispatch, cap).** The signal, the validated artifact and
  its identity, the `continuation_required` status and the per-cycle story-record
  line all exist; `continuation_cap: 2` is declared in the policy file and is
  read by nothing yet. Lane C consumes `budget.continuation_artifact` and counts
  the recorded lines. Nothing in this lane dispatches, re-stamps or decides.
- **Lane D (ORCH PM budget).** `context_budget` on the watch record and in the
  `status` rendering is the member a PM view reads; the PM's own window-source
  hierarchy (FR-121) is untouched here.
- Story 1.6 registry codes were not read, cited or anticipated beyond the
  reason-code discipline this lane's own policy file declares.

### Commit

One commit, the tip of `jlengelbrecht/afk-port-1.5b`. Its SHA cannot be written
into the commit that carries this record, so it is reported in the worker_done
body instead. Nothing was pushed, no PR was opened, `master` was not touched.
No trailers of any kind were added; the environment appended none.

### Post-review fix cycle (AFK-PORT-1.5B-FIX)

One bounded cycle answering `evidence/AFK-PORT-1.5B-REVIEW/REVIEW.md` (NOT CLEAN:
one blocker, nine residuals). A fresh session that wrote neither the code nor the
review. Exactly the eight authorized items; the frozen launch command texts were
not touched.

| item | disposition |
|---|---|
| BLK-1 — the continuation reason was filtered by a 24-char pattern denylist | **fixed (F1)**, reviewer's option (a). `artifact_redact` and its `BUDGET_REDACT_FN` indirection are deleted; nothing else used them. The reason's CONTENT now reaches nothing — not the marker, not the log, not the result. `continuation_signal_summary` records `reason_given`, `reason_bytes` and `reason_words`, the last drawn from a closed vocabulary (`continuation_reason_word`) exactly as `afk_safe_diagnostic` does for argv. The stable `reason=CONTINUATION_ARTIFACT_INVALID` code is unchanged. |
| RES-1 — `CONTINUATION_REQUIRED` published beside `status: done` | **fixed (F2)**. A ratio-derived continuation state on a run whose gates passed and whose worker signalled nothing is demoted to what the checkpoint rule says about the same ratio (`CHECKPOINT_DUE`, or `OK`), and `HIGH_USAGE` carries the sizing observation. Only a state computed from a ratio is demoted; a worker's signal is never. Contract decision table gains the row. |
| RES-2 — an earlier cycle's checkpoint published as this cycle's | **fixed (F3)**. `CHECKPOINT_BEFORE` is captured pre-launch beside `CONTINUATION_BEFORE`; a byte-identical checkpoint afterwards is finding `CHECKPOINT_ARTIFACT_STALE` and publishes no `checkpoint_artifact` identity. A finding, not a refusal — consistent with how an invalid checkpoint is treated. |
| RES-3 — a `usage` object with no token member gave `usage_tokens: 0` | **fixed (F4)**. At least one of `input_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens` must be present; otherwise `USAGE_UNOBSERVABLE`. |
| RES-4 — the single-entry `modelUsage` fallback | **fixed (F4)**. Dropped. Corroboration is an exact key match on the routed model; where no key matches, `window_reported_tokens` is `null` and the finding is `WINDOW_UNCORROBORATED`. |
| RES-5 — the discipline paragraph omitted the harness-pressure trigger | **fixed (F5)**. "or when the harness signals context pressure" added; the paragraph is still byte-stable per story and still carries no threshold. |
| RES-6 — `^CONTINUATION-REQUIRED:` matched anywhere | **bounded and documented (F6)**, not changed. The line anchor mirrors the frozen `NEEDS-HUMAN` channel. The paragraph now tells the worker never to begin a line with the marker unless it is actually stopping, and the contract records the codex `--limit 5000` terminal tail as a known limitation. |
| RES-7 — an empty reason was accepted | **fixed (F5)**. An empty reason is an invalid signal and takes the existing refusal path: `NEEDS_HUMAN`, exit 3, no result artifact, `detail=SIGNAL_REASON_EMPTY`. |
| RES-8 — `needs_human` in `dispatch_result_statuses` | **documented (F7)**. The contract now states it is delivery-only: `afk-monitor.sh` gates on it and `dispatch.sh` deliberately writes no result on that path. The published list is the union a reader of either producer may meet; no rename, no schema-major change. |
| RES-9 — the unpublished-reason sweep did not see `budget.usage_reason` | **fixed (F7)**. The readiness suite's sweep now collects `.usage_reason?` alongside `.reason?` against the union of `reason_codes` and `budget_reason_codes`, with its own falsifiability control. |

Two reason codes are added to `context-budget-policy.yaml` and mirrored in
`schema`: `CHECKPOINT_ARTIFACT_STALE` and `WINDOW_UNCORROBORATED`.

#### Deferred, deliberately, and disclosed (this cycle)

- **The reviewer's one note on the disclosed items — an unparseable-envelope
  assertion in the suite** — was not added. Diagnosis: it is outside F1–F8, and
  the fix story's scope is exactly the eight items. The behaviour is covered
  (`USAGE_UNOBSERVABLE` for a truncated envelope, a bare string, `null`, an
  array and a top-level array); what is missing is a suite assertion, and it
  remains a one-line backlog item for whoever next opens section 3d.
- **`WINDOW_UNCORROBORATED` fires only where an observation was actually made**
  (`usage_provenance == HARNESS_ENVELOPE`). Diagnosis: a run that observed no
  usage has nothing to corroborate, and raising a corroboration failure for it
  would be a finding about an event that did not happen. The consequence is that
  `codex`, which observes nothing, never carries the finding.
- **The closed vocabulary is a judgement call, not a derived set.** Diagnosis:
  no vocabulary can be derived from the reasons workers have not yet written.
  It is deliberately small and drawn from the stop conditions the discipline
  paragraph itself names; a reason using none of it records
  `reason_words=none`, which is a true statement and not a degradation.

#### Gates (this cycle, run by the worker in this worktree)

| gate | result |
|---|---|
| `bash tests/lifecycle-tests.sh` | **478 passed, 0 failed** |
| `bash tests/lifecycle-readiness-tests.sh` | **290 passed, 0 failed** |
| `bash tests/lifecycle-dispatch-tests.sh` | **256 passed, 0 failed** |
| `git diff --check` | clean, exit 0 |
| `bash tests/run-tests.sh` | **590 passed, 1 failed** — the one red is the recorded flake |

The single red is the `lifecycle concurrency gate` aggregate, `204 passed, 3
failed`. Run directly, it names the same three sub-assertions as the recorded
baseline:

```
  FAIL a contender that observed the window waits it out rather than refusing
  FAIL and reports the live owner it was waiting for
  FAIL so nothing it says can be read as 'this lock has no owner'
204 passed, 3 failed
```

Same tally, same three assertions, same publication-window scenario as
`evidence/AFK-PORT-1.4-LV/coordinator-baseline-concurrency-master-8a56eb5.log`.
Nothing in this cycle touches locking. It is the only red. The suite's own
sections 6, 9 and 10 run the other three gates against this same tree and report
the tallies above.

Diff for this cycle: 368 insertions, 67 deletions across six files,
plus 79 lines of this story record.

#### Commit (this cycle)

One commit on `jlengelbrecht/afk-port-1.5b`, named files only, plain engineering
language, no trailers of any kind. A commit cannot carry its own hash, so the
SHA is reported in the worker_done body instead. Nothing pushed, no PR opened,
`master` untouched. Briefs, stamps and route artifacts are not committed.

### Coordinator log — merge (2026-09-07) **[MERGE LOGGED]**

- Lane B routed naturally to `{claude, local-code-standard, medium}` and was
  overridden to `claude/strong` under the owner's standing ruling (stamp
  `sha256:f9578304…`), the reason citing the lane's payload and the Story 1.7
  measurements of the natural route.
- Implementation worker succeeded (`54dfd14`; reviewable 800/34 across 10
  files, on budget); coordinator's independent five gates matched (286/0,
  256/0, 478/0, diff-check, run-tests 555/1 with the recorded concurrency
  aggregate the only red). Fresh-session adversarial + senior review
  (`evidence/AFK-PORT-1.5B-REVIEW/`): NOT CLEAN — one blocker (the
  continuation reason passed through a pattern denylist instead of the kit's
  closed-vocabulary redaction) and nine residuals. One bounded fix cycle
  (`AFK-PORT-1.5B-FIX`, `e2f3e92`) closed the blocker and seven residuals;
  a diff-scoped post-fix review (`evidence/AFK-PORT-1.5B-POSTFIX-REVIEW/`)
  verified every remedy, including a mutation test on the redaction
  assertions, and raised four low/informational residuals (RES-P1: the
  pre-existing `NEEDS-HUMAN:` channel still echoes worker text — backlog;
  RES-P2 sweep union; RES-P3 unreachable `OK` arm; RES-P4 a stale HEAD in
  the reviewer brief — process). Post-fix independent gates 290/0, 256/0,
  478/0, diff-check, 590/1.
- PR #32: GitGuardian flagged the redaction test's keyword sentinel
  (`password=Tr0ub4dor&3`, incident 37069849, TEST_FILE); verified a test
  sentinel, ignored as `test_credential` with an incident comment and a PR
  comment, re-scanned clean on a fresh push. Squash-merged to `master` as
  `6d1315f` under the owner's standing merge grant. Host kit updated through
  the Git channel c89b302 → 6d1315f, `CONVERGED`, installed adapter
  byte-identical (`evidence/AFK-PORT-1.5B/host-update-*.json`).

### External report and fix cycle (AFK-PORT-1.5B-FIX2)

**The report.** On 2026-09-07 the ai-control-plane PM ran the first natural-route
gateway-backed dispatch in that repository (story FU.1, `{claude,
local-code-standard}` → qwen36-27b, 83 turns, 41.6 minutes) and read back a thin
result that said the story needed a continuation. It did not. The usage adapter
had summed `usage.input_tokens + cache_read_input_tokens +
cache_creation_input_tokens` from the end-of-run envelope — 1,330,455 tokens —
and divided by the routed 65,536 window for a ratio of 20.30. Those members are
the total over every API call the run made, not the context its last call held.
The band said `CONTINUATION_REQUIRED`, `HIGH_USAGE` was added, and because the
gates had failed with no worker signal the status became
`continuation_required` with no checkpoint and no continuation artifact
anywhere: a PM acting on it would have re-dispatched a continuation from
nothing. The coordinator reproduced the same shape on this kit's own M4R smoke
envelope — 20 turns, ratio 3.8 on a run that occupied one window. Evidence:
`evidence/AFK-PORT-1.5B-FIX2/fu1-claude-result-envelope.json` and
`fu1-thin-result.json`; the envelope is now also a test fixture at
`tests/fixtures/claude-result-envelope-multiturn.json` (secret-free — the
`permission_denials` entries carry file paths only).

**The ruling (coordinator, binding): option (a), no contract change.** The
envelope publishes no per-turn or final-context figure, and the kit reads no
terminal and no transcript, so the honest move is to label the figure rather
than to change what is launched. Option (b) — `stream-json`, which would make
mid-run usage observable — was refused: it changes a frozen launch command
text. So a cumulative figure is now reported as information and never as
occupancy, and the gates decide the status.

**What changed.**

- `usage_adapter_claude` reads `num_turns` and reports `usage_scope`.
  `num_turns == 1` is `FINAL_CONTEXT`, the only scope a ratio is computed from;
  anything else — more turns, or an envelope with no turn count, which proves
  nothing about how many calls it summed — is `CUMULATIVE_RUN` with
  `usage_reason: USAGE_CUMULATIVE_ONLY` and `usage_ratio: null`. The figure is
  still published. `budget_evaluate_usage` returns on the cumulative path
  exactly as it does for an unobservable one: no band, no `HIGH_USAGE`, the
  pre-dispatch verdict left standing. `usage_scope` is an additive member of
  the thin result's `budget`.
- `status: continuation_required` is now published only from the worker's
  signal plus a valid artifact. The arm that set it from a usage band with the
  gates failed is gone; the band and `HIGH_USAGE` stand beside `gates_failed`
  as sizing notes. Lane B's demotion on a passing-gate run is unchanged.
- The generated prompt carries one launcher-owned sentence naming the worktree
  as the working directory and refusing absolute paths outside it. FU.1
  recorded 14 permission denials, every one an absolute path into the main
  checkout. Its only input is the directory dispatch resolved for itself.
- The cap marker's suggested `max_cycles` is the larger of the story's current
  limit and the cycle being authorised, so applying the remedy never lowers a
  limit; the contract states that `max_cycles` still bounds continuations the
  cap lets through. (Lane C post-fix review N4, N2.)
- `total_cost_usd` and `costUSD` are asserted absent from the launcher and from
  the thin result: the envelope's figure is a client-side estimate
  (`costBasis: "unknown"`) and on a `cost_class: free` route it is not money.
- Contract: the observed-usage section, the phase-boundary decision table (two
  rows changed, one added), the budget shape, the cap remedy and the
  working-directory sentence.

**Deferred, deliberately, and disclosed.**

- **The `Edit` tool in the frozen claude launch text.** FU.1's worker had no
  `Edit`, so every fix rewrote a whole file. Adding it changes a frozen launch
  command text and its byte-identity oracle, and it widens what a dispatched
  worker may do — an owner decision with contract evidence to update, out of
  scope here.
- **KServe cold start.** The gateway's first request on a cold pod pays a
  startup cost the router's placement decision does not model. That is a
  catalog/router matter, not a kit one; it is recorded here so the trail is not
  lost.
- **`evidence/AFK-PORT-1.5B-FIX2/external-report.md` does not exist.** The
  brief names it; only the two JSON artifacts were provisioned. The fix story
  carries the report's substance, so nothing was blocked — noted so a reader
  chasing the citation does not think a file went missing.
- **Fixture scope.** Only the FU.1 envelope was copied into `tests/fixtures/`.
  The M4R corroboration was the coordinator's own check and is cited, not
  re-fixtured.

**Record (worker).**

- Changes: `files/model-router/scripts/dispatch.sh`,
  `docs/LIFECYCLE-CONTRACT.md`, `tests/run-tests.sh`,
  `tests/fixtures/claude-result-envelope-multiturn.json`, this record.
- Fixtures: the FU.1 envelope through the adapter yields
  `scope: CUMULATIVE_RUN`, `reason: USAGE_CUMULATIVE_ONLY`,
  `usage_tokens: 1330455`, `usage_ratio: null`, no `HIGH_USAGE`, and the
  pre-dispatch state untouched; a single-turn envelope at 60000/65536 still
  evaluates to `CONTINUATION_REQUIRED` with `HIGH_USAGE`.
- Gates, run by the worker before the commit: `lifecycle-readiness-tests.sh`
  290/0, `lifecycle-dispatch-tests.sh` 256/0, `lifecycle-tests.sh` 478/0,
  `git diff --check` clean, and `run-tests.sh` last and once at 766 passed /
  1 failed — the one red being the recorded `lifecycle concurrency gate`
  aggregate (204 passed, 3 failed), which is the only tolerated red.
- One commit on `jlengelbrecht/afk-port-1.5b-fix2b`, branched from `master`
  @ `4b873ab`; the SHA is in the coordinator's log for this cycle. Nothing was
  pushed and no PR was opened. The brief, the stamp, the route artifacts and
  the FIX2 evidence directory are deliberately uncommitted — they belong to the
  coordinator's record lane, as in the lanes before this one.
