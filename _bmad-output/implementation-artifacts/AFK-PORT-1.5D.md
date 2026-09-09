---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-PORT-1.5D.md.stamp.json
persona: dev
gates:
  - "bash tests/run-tests.sh"
  - "bash tests/lifecycle-readiness-tests.sh"
  - "bash tests/lifecycle-dispatch-tests.sh"
  - "bash tests/lifecycle-tests.sh"
  - "git diff --check"
max_cycles: 3
---

# AFK-PORT-1.5D — The ORCH PM's own context budget

Lane D of four for the frozen Story 1.5 (`AFK-PORT-1.5.md`; authority: PRD
addendum Capability 5 "PM Context Budget", FR-121–FR-126; NFR-13–15). Lanes
A–C are merged: the policy file, the `budget` member, the artifacts, the
`context_budget` watch member and continuation cycles all exist. This lane
applies the same model to the coordinator session itself, which is human-
started in Orca and not necessarily stamped, and which the kit must never
launch.

Budget for this lane INCLUDING tests and prose: ≤ 800 reviewable lines.

## Design ruling (coordinator, binding)

The kit cannot measure a human-started interactive session's context itself
(explicit non-goal: "no automatic context-window measurement by the kit").
The PM's window and usage therefore arrive as PROVIDED observations through a
documented file contract that a harness adapter (or the human) writes, and
the kit evaluates, renders, and acts on them exactly as it does for workers.
The window source hierarchy is applied in order: a PM execution stamp
(`--pm-stamp`), else an adapter-reported window in the observation file, else
`NOT_EVALUATED` with the phase-boundary checkpoint fallback. PM continuation
is ALWAYS a loud `NEEDS_HUMAN`; the kit never launches a successor.

## Scope

**S1 — PM observation contract (FR-121, FR-104 reuse).** Under the declared
state directory: `pm/usage.json` (schema `afk-pm-usage/1`: `harness`,
`window_tokens` (nullable), `usage_tokens` (nullable), `provenance`
(`HARNESS_ADAPTER` | `HUMAN`), `observed_at`, `session` (an opaque id)). `usage_tokens` is the context held by the session at observation time (final-context occupancy), never a cumulative sum over calls; an adapter that can only report a cumulative figure reports `usage_tokens: null` with reason `PM_USAGE_CUMULATIVE_ONLY`.
Absent or unparseable → `NOT_EVALUATED` / `PM_USAGE_UNOBSERVABLE`. Provenance
is recorded, never inferred. (The Story 1.8 statusline hook is the expected
adapter writer for claude; that story is separate — this lane defines the
contract and accepts a hand-written file with `provenance: HUMAN`.)

**S2 — evaluation and rendering (FR-121).** `status --json` (and the human
rendering) gains a bounded `pm_budget` block: `window_tokens`,
`window_source` (`STAMP` | `ADAPTER` | `NOT_EVALUATED`), `usage_tokens`,
`usage_ratio`, `state` (`OK` | `CHECKPOINT_DUE` | `CONTINUATION_REQUIRED` |
`NOT_EVALUATED`), `reason`, `checkpoint_artifact`, `continuation_artifact`,
`needs_human`. Thresholds come ONLY from the policy file (`checkpoint_ratio`,
`continuation_ratio`), parts-per-million arithmetic and boundary equality as
lanes A/B. With `--pm-stamp <file>` the window is the catalog's `min_context`
for the stamped profile (validated via the existing stamp-shape checks);
else the observation's `window_tokens`; else `NOT_EVALUATED`.

**S3 — PM checkpoint and continuation artifacts (FR-124).** Schemas
`afk-pm-checkpoint/1` and `afk-pm-continuation/1` under `pm/`: `decisions`,
`envelope_actions` (an empty list is valid until Story 1.6 defines the
vocabulary), `open_escalations`, `budget_state` (per-story budget summary:
cycles, continuations, PM continuation count), `in_flight_dispatches` (ids
only — pointers, never bodies), `resume_instruction` (continuation only; a
ready-to-use command line for the human), `updated_at`. A new verb
`agent-flow-kit pm-checkpoint --write <json>` validates and writes the
artifact atomically with the kit's redaction rules (secret-looking values
refused, not echoed); `pm-checkpoint --continuation --write <json>` writes the
continuation artifact and sets the loud condition (S4). Both are secret-free
by rule and validated on read.

**S4 — loud continuation (FR-124, FR-125).** When `pm_budget.state` is
`CONTINUATION_REQUIRED` (from an observation ratio) or a continuation
artifact exists that no successor has reconciled, `status` reports
`ORCHESTRATION_NEEDS_HUMAN`-class finding `PM_CONTINUATION_REQUIRED` with
`owner_action` severity, the artifact identity (path + sha256) and the
`resume_instruction` verbatim; `next_safe_action` tells the human to start
the successor ORCH PM in Orca. The kit exposes NO verb that launches a
session; a test asserts no `orca terminal create`/`worker-start` call exists
on any PM path.

**S5 — successor reconciliation (FR-125).** `monitor --reconcile` (the frozen
restart/reconnect path, consumed unchanged for workers) gains one additive
step: if a PM continuation artifact exists, validate it, record
`pm/continuation.reconciled.json` (successor session id from the observation
file or `--session`, at, artifact sha) and clear the `PM_CONTINUATION_REQUIRED`
condition; increment the PM continuation count in `pm/budget-state.json`
(FR-126 input to the Story 1.6 epic budget). In-flight worker watches are
untouched by any of this (assert).

**S6 — discipline documented where the PM reads (FR-122, FR-123).**
`files/model-router/SKILL.md` gains a "Coordinator context budget" section:
thin consumption only (pointers, never bodies — reading a transcript, gate log
or evidence body is a defect), no polling held open inside a PM turn (the
durable watch is the mechanism), checkpoint at declared PM phase boundaries
(story dispatched, worker settled, PR merged, lane closed) when usage is
unobservable, and the exact resume instruction shape. `docs/LIFECYCLE-CONTRACT.md`
documents the `pm/` contract, the `pm_budget` block, the finding, and the
reconciliation step.

**S7 — tests.** `tests/lifecycle-readiness-tests.sh` (status rendering):
window hierarchy — stamp branch, adapter branch, `NOT_EVALUATED` branch;
thresholds at the boundaries; unobservable usage; `pm_budget` shape.
`tests/lifecycle-dispatch-tests.sh` (monitor): continuation artifact →
finding + resume instruction; successor reconcile clears it and increments
the count; worker watches untouched; no PM-session launch path (grep-level
plus behavioural). `tests/lifecycle-tests.sh`: `pm-checkpoint` write/validate,
redaction refusal with a sentinel, atomicity. Schema blocks in the contract
in sync with the `schema` verb.

## Out of scope — hard stops

Launching any session; measuring context itself; the Story 1.8 statusline
hook (separate frozen story); Story 1.6's envelope vocabulary (leave
`envelope_actions` as an opaque list); any change to `dispatch.sh`'s worker
budget behaviour, the frozen launch texts, `make-stamp.sh`, the validator or
the catalog; retrofitting the frozen 1.3 orchestration document.

## Acceptance criteria

- **AC-1** observation contract accepted/refused as specified; provenance
  recorded (S1, tests).
- **AC-2** `pm_budget` rendered with the three-branch window hierarchy and
  policy thresholds (S2, tests).
- **AC-3** PM checkpoint/continuation artifacts validated, redacted, atomic
  (S3, tests).
- **AC-4** loud `PM_CONTINUATION_REQUIRED` with resume instruction; no
  launch path exists (S4, tests).
- **AC-5** successor reconcile clears the condition, records provenance,
  counts the continuation; worker watches untouched (S5, tests).
- **AC-6** discipline documented in the PM-facing skill and the contract (S6).
- **AC-7** gates green (concurrency aggregate the only tolerated red); diff
  ≤ 800 reviewable lines including tests and docs; record names the seam
  left for Story 1.6 (envelope vocabulary, epic budget).

## Dev Agent Record

**Method and precedence choices.**

- The PM budget is evaluated by the KIT (`lib/afk-commands.sh`), not by the
  launcher: `dispatch.sh` is untouched, so worker dispatch and watch behaviour
  are byte-identical. The reconciliation step is called from `afk_cmd_monitor`'s
  reconcile/cleanup branch rather than from inside `afk_monitor_reconcile`, which
  is why `lib/afk-monitor.sh` needed no edit at all and why "worker watches
  untouched" is provable rather than merely asserted.
- **Window hierarchy** — `--pm-stamp` (catalog `min_context` for the stamped
  profile, after `afk_stamp_shape_is_valid`) → observation `window_tokens` →
  `NOT_EVALUATED`. Per the coordinator's ruling, an explicitly named stamp is
  never silently ignored: an unresolvable one reports `PM_STAMP_UNUSABLE` and
  evaluates nothing rather than falling through to the adapter branch.
- **Catalog access** — the kit holds no catalog and uses jq only, so the catalog
  path is read from the launcher's already-declared
  `AGENT_STAMP_VALIDATE_CATALOG_PATH` (or a new `AFK_ROUTER_CATALOG`), parsed
  with awk. No yq runtime dependency was added.
- **Thresholds** — read from the policy file with a strict scalar parse;
  unreadable or missing key gives `PM_BUDGET_POLICY_UNREADABLE`. No ratio
  constant exists in the kit. Banding is integer parts-per-million with boundary
  equality, matching lanes A/B.
- **Reason codes** — the ten PM codes are published through the kit's own
  `reason_codes` vocabulary via a third `afk_pm_reason_*` hook, NOT through
  `budget_reason_codes`. The readiness gate asserts
  `schema.budget_reason_codes == policy.reason_codes` exactly, and the policy
  file is launcher configuration outside this lane's surface; a finding reason
  belongs to the kit vocabulary regardless. `files/model-router/context-budget-policy.yaml`
  is therefore unchanged.
- **Redaction** — refusal is on member NAME classification (reusing
  `afk_env_classification`) plus a conservative credential-shape match on values.
  Refused before the shape check, so a secret cannot reach a diagnostic on its
  way to being rejected for another reason. Exit 4; the value is never echoed.
- **Exit codes** — `pm-checkpoint` forces the OK code before evaluation so its
  verdict answers its own scope (an unadopted host is irrelevant to whether the
  artifact validated), and `afk_pm_apply` raises it to the owner-action code when
  the result is an outstanding hand-over. On `status`/`monitor` the PM condition
  only raises an exit code of 0, never lowering an existing 3 or 4.

**Files touched (8).** `lib/afk-commands.sh` (PM engine, status/monitor wiring,
schema verb), `lib/afk-common.sh` (reason hook pair, `pm_budget` rendering),
`bin/agent-flow-kit` (`pm-checkpoint` verb, `--pm-stamp`/`--session`/`--write`/
`--continuation`, `AFK_PM_DIR`), `docs/LIFECYCLE-CONTRACT.md`,
`files/model-router/SKILL.md`, and the three named test suites.
`bin/agent-flow-kit` and `lib/afk-common.sh` were outside the original
`touched_paths`; work stopped and the coordinator re-routed and re-stamped with
the expanded surface before either was edited.

**Diff size.** 800 reviewable lines across 8 files, against the 800-line /
25-file budget. The first complete implementation measured 902; the 800 was
reached by structural compression only, with no acceptance criterion or test
case removed: the reason vocabulary became one `code|message|action` data table
read by three one-line accessors instead of three parallel case statements;
`afk_pm_evaluate` folded into `afk_pm_apply` (the block was being built and then
read back apart with jq); the observation, artifact and secret validators were
compacted with jq helper defs; the human rendering became one `afk_render_q`
projection like the components and findings blocks; the three value-taking
options share one parse arm; the readiness and artifact test cases became
case tables; and prose that restated the story was cut. Test coverage went up
during the pass, not down.

**Gates.** All run on the final source, the three focused suites first and
`tests/run-tests.sh` last and once.

| Gate | Result | Wall time |
|---|---|---|
| `bash tests/lifecycle-readiness-tests.sh` | 341 passed, 0 failed (rc 0) | 330s |
| `bash tests/lifecycle-dispatch-tests.sh` | 274 passed, 0 failed (rc 0) | 215s |
| `bash tests/lifecycle-tests.sh` | 499 passed, 0 failed (rc 0) | 461s |
| `bash tests/run-tests.sh` | 766 passed, 1 failed (rc 1) | 2662s |
| `git diff --check` | clean (rc 0) | — |

The single red is the tolerated baseline and nothing else: section 8's aggregate
`lifecycle concurrency gate` at **exactly 204 passed / 3 failed**. Running that
suite alone names the three as the lock publication-window scenario — "a
contender that observed the window waits it out rather than refusing" (1 vs 3),
"and reports the live owner it was waiting for" (`LIVE` vs `UNKNOWN`), and "so
nothing it says can be read as 'this lock has no owner'" (0 vs 1). All three sit
in the mutation/lock path — the registered exception `bin/agent-flow-kit` already
documents — and `lib/afk-mutate.sh` is untouched by this lane. Inside the full
run the lifecycle, readiness and dispatch sub-gates reported 499/0, 341/0 and
274/0 respectively.

Hard stops verified untouched: `dispatch.sh`, `make-stamp.sh`,
`context-budget-policy.yaml`, `lib/afk-monitor.sh`, `lib/afk-readiness.sh`,
`lib/afk-mutate.sh`, `lib/afk-plan.sh`, `lib/afk-inventory.sh`,
`lib/afk-source.sh`, `tests/run-tests.sh`, `lifecycle/kit.json`, and the frozen
`AFK-PORT-1.5.md`.

**Seam left for Story 1.6.** `envelope_actions` is an opaque list on both
artifacts and an empty one is valid — 1.6 defines the vocabulary and the
validator that reads it. `pm/budget-state.json` carries `pm_continuations` as
the epic-budget input (FR-126) and nothing consumes it yet. The Story 1.8
statusline hook remains the expected adapter writer for `pm/usage.json`; this
lane accepts a hand-written file with `provenance: HUMAN` and defines the
contract that hook will satisfy.

### Coordinator log — merge (2026-09-09) **[MERGE LOGGED]**

- Natural implementation routing returned
  `{claude, local-code-standard, medium}`. The coordinator applied the owner's
  standing `claude/strong` override because Story 1.7 measured the local
  profile at 6/9 with a path-resolution failure class. An initial local launch
  stopped before worker placement when the requested dev persona file was not
  installed; it performed no implementation work and spent no provider
  compute. The cloud attempt produced the complete lane.
- The first independent review was NOT CLEAN. B1 found that credential shapes
  inside `resume_instruction` were accepted and echoed unless they began the
  value. B2 found that a named unusable PM stamp lost
  `PM_STAMP_UNUSABLE` when usage was null. Twelve lower-severity residuals were
  retained. The first bounded fix closed both blockers but crossed its path
  boundary by compressing the worker-handoff test suite, so the coordinator
  rejected that scope drift. A second bounded correction restored that suite
  byte-for-byte and recovered the line budget only inside the declared
  readiness surface.
- Final product commit `da1c7bf` was one clean commit above base `32e94cc`,
  exactly 793 additions and 7 deletions across the eight declared product
  files. Post-fix independent review was CLEAN. It proved both new regression
  blocks load-bearing against a scratch copy with the two fixed lines reverted
  and reran readiness 359/0, worker handoff 274/0, lifecycle 503/0, and
  `git diff --check` clean. Four non-blocking residuals were registered: glued
  credential boundaries, widened false positives in prose, a weaker failure
  diagnostic in the reason sweep, and expired but well-shaped PM stamps still
  resolving a window.
- PR #38 squash-merged to `master` as `b35e0c2` under the standing merge grant.
  GitGuardian was clean, Devin reported its documented no-credit pass, and the
  PR had zero reviews, comments, or unresolved threads. CodeRabbit and Sentry
  did not attach to this repository or commit.
- The installed host kit converged `f9bffe0` → `b35e0c2` from the exact merged
  revision. Plan `sha256:1eb61228…` replaced only the managed model-router
  component, preserved the machine-owned `subscriptions.yaml` at its exact
  identity, and completed 11/11 offline verification checks. The final verify
  reports the installed revision `CURRENT`; evidence is retained in
  `evidence/AFK-PORT-1.5D/host-update-summary.md`.
