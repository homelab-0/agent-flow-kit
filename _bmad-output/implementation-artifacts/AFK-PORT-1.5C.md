---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-PORT-1.5C.md.stamp.json
persona: dev
gates:
  - "bash tests/run-tests.sh"
  - "bash tests/lifecycle-readiness-tests.sh"
  - "bash tests/lifecycle-dispatch-tests.sh"
  - "bash tests/lifecycle-tests.sh"
  - "git diff --check"
max_cycles: 3
---

# AFK-PORT-1.5C — Continuation dispatch, the continuation cap, and settlement

Lane C of four for the frozen Story 1.5 (`AFK-PORT-1.5.md`; authority: PRD
addendum Capability 5, FR-102, FR-103; NFR-13–15). Lanes A and B are merged
(PRs #30, #32): the adapter has the window, the sizing estimate, the policy
file (`continuation_cap: 2`), the `budget` member, the checkpoint and
continuation artifacts (`afk-checkpoint/1`, `afk-continuation/1`), the
`continuation_required` status and the `context_budget` watch member. This
lane makes a continuation actually RUN. Lane D (ORCH PM budget) follows.

Budget for this lane INCLUDING tests and prose: ≤ 800 reviewable lines.

## Design ruling (coordinator, binding)

A continuation is the NEXT CYCLE of the same story under the SAME accepted
stamp, launched through `dispatch.sh` exactly as any cycle is (setup gate,
placement, fail-closed revalidation, launch guard, launch, gates, thin
result) — no new entry point, no new launch path, no local substitution of
harness, model, profile or funding. The frozen launch command texts stay
byte-identical. What changes is what the launcher puts into the prompt and
what it refuses before launching.

## Scope

**S1 — continuation-aware cycle (FR-102).** When `dispatch.sh <story> <n>`
starts and a valid `<story>.continuation.json` exists whose recorded cycle is
`n-1` (or the most recent prior cycle) and whose thin result for that cycle
was `continuation_required`, the cycle is a CONTINUATION: the launcher (a)
counts the artifact in the pre-dispatch sizing estimate (lane A's inputs plus
the artifact; the refusal and risk thresholds apply unchanged), (b) writes the
artifact's content into the generated prompt as data under a fixed heading
("Continuation from cycle n-1"), after the persona/story instructions and
before the budget paragraph, and (c) records `budget.continuation_of`
(`{cycle, artifact_sha256, trigger, usage_tokens, usage_ratio}`) in the thin
result. A cycle with no valid artifact is an ordinary cycle. A cycle whose
prior result was `continuation_required` but whose artifact is missing or
invalid refuses with the existing loud `NEEDS_HUMAN` path
(`CONTINUATION_ARTIFACT_INVALID`).

**S2 — same stamp, revalidated (FR-102).** No change to stamp handling: the
frozen prelaunch revalidation already runs every cycle. Make the refusal for
an expired or invalidated stamp on a continuation cycle say, in the `.blocked`
marker, that the continuation needs a fresh central `/v1/route` decision and
a new stamp minted by the planner (never a local substitute), and record
`CONTINUATION_STAMP_REFRESH_REQUIRED` as the reason beside the validator's
own reason. Test the expired-stamp continuation.

**S3 — the cap (FR-103).** Count prior continuations of this story
deterministically from the retained per-cycle thin results
(`<story>.result.json` is overwritten per cycle today — so retain one
`<story>.result.c<n>.json` per cycle from this lane on, and count
`continuation_required` results). When the count equals the policy's
`continuation_cap`, the next continuation cycle refuses unless the story
carries an explicit recorded PM decision: a frontmatter key
`continuation_decision:` with `{cycle, actor, at, reason}` naming the cycle
being authorised. Refusal is fail-closed with a `.blocked` marker typed
`CONTINUATION-CAP:` carrying `reason=CONTINUATION_CAP_REACHED`, the count, the
cap, and the exact frontmatter shape to add; nothing is placed or launched.
An authorised third continuation proceeds and records the decision in
`budget.continuation_decision`. Every continuation (authorised or not) adds
the finding `REPEATED_CONTINUATION` to the thin result — the story-sizing
signal to the PM.

**S4 — record chain (FR-103).** Each continuation cycle appends one dated
line under the story's Dev Agent Record via lane A's locked, idempotent
`record_budget_line` (code `CONTINUATION`, detail: from cycle, artifact sha,
trigger, usage), so the chain trigger → usage evidence → artifact identity
is readable in the story.

**S5 — settlement unchanged (FR-102).** A continuation worker is a fresh
Orca-visible terminal exactly like any cycle; the frozen Story 1.3
completion-watch, terminal-cleanup and worktree/branch-accounting contracts
apply unmodified. Prove by test that a continuation cycle's thin result and
watch record are settled by the existing monitor path with `context_budget`
sourced as lane B defined, and that nothing in `lib/afk-monitor.sh` needed to
change (if it did, stop and disclose).

**S6 — contract, schema, docs.** `docs/LIFECYCLE-CONTRACT.md` `## The context
budget` extended: the continuation cycle, the per-cycle result retention, the
cap and the decision key, the reason codes (`CONTINUATION_CAP_REACHED`,
`CONTINUATION_STAMP_REFRESH_REQUIRED`, `REPEATED_CONTINUATION`); policy file
reason list extended; `SKILL.md` one paragraph on how a planner authorises a
third continuation and refreshes a stamp.

**S7 — tests (both harnesses, both launch classes where the class matters).**
`tests/run-tests.sh`: a continuation cycle consumes a valid artifact into the
prompt and the estimate; the artifact pushing the estimate past the refusal
threshold refuses (lane A path); missing/invalid artifact after a
`continuation_required` cycle → `NEEDS_HUMAN`; ordinary cycle unaffected;
per-cycle result retention; cap: two continuations proceed, the third refuses
with the typed marker, the third with a `continuation_decision:` proceeds and
records it; `REPEATED_CONTINUATION` finding present; expired stamp on a
continuation → refused with the refresh reason, no substitution, stamp
byte-identical afterwards; record chain lines idempotent. Frozen launch
texts byte-identical (existing oracle).

## Out of scope — hard stops

The ORCH PM budget (lane D); any automatic re-route or re-stamp by the kit
(the planner refreshes); changes to `make-stamp.sh`, the validator, the
catalog, `/v1/route` requests, or the frozen launch command texts; Story
1.6 registry codes beyond the reason-code discipline; any change to
`lib/afk-monitor.sh` unless disclosed as unavoidable.

## Acceptance criteria

- **AC-1** continuation cycle consumes the artifact into prompt and estimate
  and records `continuation_of` (S1, tests).
- **AC-2** same stamp, revalidated; expired → refusal naming the refresh path;
  never a local substitute (S2, tests).
- **AC-3** cap enforced deterministically from retained per-cycle results;
  third continuation refuses without, proceeds with, a recorded PM decision
  (S3, tests).
- **AC-4** `REPEATED_CONTINUATION` finding on every continuation (S3, tests).
- **AC-5** record chain lines present and idempotent (S4, tests).
- **AC-6** settlement through the unmodified 1.3 contracts (S5, tests).
- **AC-7** contract/schema/docs true of the code (S6).
- **AC-8** gates green (concurrency aggregate the only tolerated red); diff
  ≤ 800 reviewable lines including tests and docs; record states seams left
  for lane D.

## Dev Agent Record

### Persona proof (fail-closed, computed first)

`sha256sum SKILL.md` `b980cf2c99976b5e1bd53128dc7b56bdd181ac39a57098d9b5a6bf0692db2675`,
`sha256sum customize.toml` `f3f107f11f150f62091a792fcdf224dbf8d6c351d24e2b1d08aabb077e655feb`,
OUTER `07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee` — all
three as the brief expects.

### Method choices

**How the window is resolved.** Unchanged from lane A: the trusted catalog's
`min_context` for the stamped profile, read exactly. Nothing in this lane reads,
derives or substitutes a window, and `continuation_cap` is the only new value
read — from the policy document, validated as a whole number, with no default in
code (a policy whose cap is missing or malformed refuses with
`BUDGET_POLICY_UNREADABLE`, exactly as a missing threshold does).

**Estimate inputs.** The continuation artifact is counted **through the generated
prompt**, which carries its content verbatim and is already a declared payload
input. Enumerating the file a second time would double-count the one input a
continuation adds and refuse stories that would have fitted, so the payload path
list is unchanged and the refusal marker names the artifact as a sub-line of the
input it travels inside. This is a deliberate reading of S1(a) — "lane A's inputs
plus the artifact" is satisfied by the artifact's bytes entering the estimate
exactly once; the test proves the cycle-2 estimate exceeds the cycle-1 estimate
by at least the artifact's bytes/4, and the refusal test proves the artifact can
push a story past the threshold on lane A's unchanged path.

**Refusal ordering.** Continuation detection and the cap gate run immediately
after the persona resolution and **before** the prompt is written, the estimate
is computed, `/v1/place` is called, the stamp is revalidated and the launch guard
runs. A story that has spent its continuations, or that handed over without
leaving evidence, is a planning outcome exactly as an oversized story is, so it
consumes no placement, no validation, no terminal, no command text and no result
artifact. The sizing refusal keeps its own place (after the setup gate), so on a
continuation the order is: continuation detection → cap → prompt → sizing →
record line → placement → revalidation → launch guard → launch.

**No new exit codes.** `CONTINUATION_ARTIFACT_INVALID` (pre-launch) and
`CONTINUATION_CAP_REACHED` both exit `EX_NEEDS_HUMAN` (3) with a `.blocked`
marker — they are precisely "the work is blocked and needs a human", which is
what that code and that marker already mean to the monitor. The stamp refusal
keeps the validator's own remapped exit (4 or 5) unchanged and only adds the
marker, because the refusal is the validator's and inventing a code for it would
hide whose refusal it was. Nothing new had to be published in the CLI exit-code
vocabulary as a result.

**How the cap is counted.** From the retained per-cycle thin results and nothing
else. The predicate is both members: a prior cycle counts when its result is
`continuation_required` **and** carries `budget.continuation_of` — i.e. it was
itself a cycle that consumed a hand-over. The first cycle's hand-over is not a
consumption; counting it would fire the cap one cycle early and only one
continuation would ever proceed, which contradicts AC-3 ("two continuations
proceed, the third refuses"). S3 says "count `continuation_required` results";
this is that count with the predicate spelled out, and it is disclosed here
because it is a reading rather than a transcription.

**Record-append idempotence.** Lane A's `record_budget_line` unchanged, keyed on
`(code, cycle)` under the story's own flock. `CONTINUATION` is a distinct code
from `SIZING_RISK`, so a cycle that produces both records both, and a re-dispatch
of the same cycle records neither twice (proved). The append is placed **after**
the sizing estimate so the story's own byte length is identical on a re-dispatch
of a cycle as it was on the first — otherwise the estimate would drift between
two dispatches of the same cycle.

**Trigger vocabulary.** `budget.continuation_of.trigger` is `WORKER_SIGNAL` when
the prior cycle published a continuation-artifact identity, `USAGE_BAND` when the
kit reached `continuation_required` from observed usage with the gates failed.
Closed, and derived from the prior cycle's own retained result.

### Files touched

| file | why |
|---|---|
| `files/model-router/scripts/dispatch.sh` | continuation detection, the cap gate, the prompt section, the estimate sub-line, `continuation_of` / `continuation_decision`, per-cycle result retention, the two refusal markers |
| `files/model-router/context-budget-policy.yaml` | three new reason codes; `continuation_cap` comment made true of the code |
| `lib/afk-commands.sh` | the `schema` enum only — the same three codes |
| `docs/LIFECYCLE-CONTRACT.md` | `## The context budget`: new "Continuation cycles, the cap, and the decision key" subsection; the two new `budget` members; the policy's reason list |
| `files/model-router/SKILL.md` | one paragraph on authorising a third continuation and refreshing a stamp |
| `tests/run-tests.sh` | new section 3e |

`lib/afk-monitor.sh` is **byte-identical to master** and a test asserts it (S5):
settlement needed no change at all.

### Diff size

`git diff --stat master...HEAD`, excluding this story file:
`6 files changed, 695 insertions(+), 6 deletions(-)` — **701 reviewable lines
across 6 files**, including tests and prose, against the ≤ 800 line / ≤ 25 file
budget. Nothing was cut to fit; the one thing deliberately not absorbed is
lane D, which the story puts out of scope anyway.

### Gates

All five run on this host, by me, in this worktree.

| gate | exit | wall | tally |
|---|---|---|---|
| `bash tests/lifecycle-readiness-tests.sh` | 0 | 279s | 290 passed, 0 failed |
| `bash tests/lifecycle-dispatch-tests.sh` | 0 | 201s | 256 passed, 0 failed |
| `bash tests/lifecycle-tests.sh` | 0 | 480s | 478 passed, 0 failed |
| `git diff --check` | 0 | — | clean |
| `bash tests/run-tests.sh` | **1** | 2590s | **669 passed, 1 failed** |

The single red is the recorded pre-existing aggregate and nothing else. Its own
sections: `0` shellcheck green, `1`–`3b` green, `3c`/`3d` (lanes A and B) green,
`3e` (this lane, new) green, `4`/`5` green, `6` lifecycle 478/0, `7` mutation
577/0, `9` readiness 290/0, `10` dispatch 256/0. Section `8`:

```
8. Lifecycle concurrency gate — tests/lifecycle-concurrency-tests.sh
  FAIL lifecycle concurrency gate
        204 passed, 3 failed
```

Run directly, `tests/lifecycle-concurrency-tests.sh` exits 1 with exactly the
three known publication-window sub-assertions, verbatim:

```
  FAIL a contender that observed the window waits it out rather than refusing
        expected '1', got '3'
  FAIL and reports the live owner it was waiting for
        expected 'LIVE', got 'UNKNOWN'
  FAIL so nothing it says can be read as 'this lock has no owner'
        expected '0', got '1'

204 passed, 3 failed
```

This is the aggregate the brief records as reproduced on pristine master
(`evidence/AFK-PORT-1.4-LV/coordinator-baseline-concurrency-master-8a56eb5.log`,
which is not present in this worktree — the count and the three sub-assertions
are what I can attest to from here). Nothing in this lane touches the operation
lock, and the failure is in a suite whose surface this lane does not enter.

**Section 3e, the new one (all green):** the ordinary cycle is unaffected with a
stray artifact on disk, with no prior result at all, and after a prior cycle that
finished; per-cycle results are retained and identical to what the cycle
published; a real hand-over is consumed into the prompt (fixed heading, artifact
content, ordered between the story and budget paragraphs) and into the estimate;
`continuation_of` carries cycle, digest, trigger and the prior cycle's usage;
`REPEATED_CONTINUATION` fires; the record chain line is present, complete and
idempotent across a re-dispatch of the same cycle; the artifact can push the
estimate past the refusal threshold on lane A's unchanged path, and the marker
names it and says where it was counted; a hand-over with a missing or
schema-mismatched artifact is a loud pre-launch `NEEDS-HUMAN` that places and
launches nothing; two continuations proceed and the third refuses with the typed
`CONTINUATION-CAP:` marker, which the recorded `continuation_decision` then
authorises — and a decision naming an earlier cycle does not carry forward; an
expired stamp on a continuation refuses with the validator's own exit and the
refresh marker, the stamp byte-identical afterwards, with a control proving the
same continuation launches on a valid stamp; and `lib/afk-monitor.sh` is proved
byte-identical to master.

### Deferred, deliberately, and disclosed

- **The ORCH PM budget (lane D) is untouched**, as the story's hard stops
  require. The seams left for it: `budget.continuation_of` and
  `budget.continuation_decision` in the thin result, the `REPEATED_CONTINUATION`
  finding, the retained `<story>.result.c<n>.json` series, and the
  `CONTINUATION` lines in the story record — all of which are readable without
  loading a transcript, which is what the PM lane will need.
- **No `/v1/route`, `make-stamp.sh`, validator or catalog change**, and neither
  frozen launch command text moved a byte (the suite's existing byte-identity
  oracle against master's own builders still passes).
- **No `context_size` anywhere in the launcher** — the existing AC-6 grep still
  passes, so the continuation estimate cannot become a routing input either.
- **No threshold constant in code**; the existing source grep for `0.6/0.7/0.85`
  in non-comment lines still passes, and `continuation_cap` is read from the
  policy with no fallback.
- **Retained results are never pruned.** A long-lived story accumulates one small
  JSON per cycle. Pruning them would make the cap countable-from-nothing, so it
  is left out on purpose; if the accumulation ever matters it is a retention
  policy question for the owner, not a launcher change.
- **The `continuation_decision` key is not validated against a person.** It
  records who decided, not that they were entitled to; the kit has no identity
  authority and inventing one here would be worse than recording the claim.
- **AC numbering.** The brief asks for AC-1–9; this story declares AC-1–8. All
  eight are addressed. Flagged rather than silently reconciled.
