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

### Post-review fix cycle (AFK-PORT-1.5C-FIX)

One bounded cycle answering `evidence/AFK-PORT-1.5C-REVIEW/REVIEW.md`. Fresh
session; it did not write the reviewed code and did not write the review.

Persona proof, computed first and fail-closed:
`{ sha256sum .agents/skills/bmad-agent-dev/SKILL.md; sha256sum
.agents/skills/bmad-agent-dev/customize.toml; } | sha256sum` →
`07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee`. Match.

#### Dispositions

| item | disposition |
|---|---|
| **B1** the cap gate is unreachable at the shipped defaults, and the marker's remedy does not unblock the cycle | **Fixed, both halves.** The continuation detection and the cap gate now run BEFORE the story's own `max_cycles` check, so a capped story gets the typed `CONTINUATION-CAP:` refusal rather than an untyped per-story limit; `max_cycles` still applies to whatever the cap lets through. The marker's suggested frontmatter now carries `max_cycles: <the cycle being authorised>` beside `continuation_decision:`, and the contract and SKILL paragraphs say why both keys are needed. |
| **B2** the cap is not enforced: re-dispatching a cycle number grants extra continuations and deflates the count | **Fixed.** The count moved to an append-only ledger, `<story>.continuations.json` (`afk-continuation-ledger/1`), one entry per continuation LAUNCH, appended under the story's own exclusive lock immediately before the launch and never rewritten or pruned. The consumed count is its length, whatever cycle numbers it holds, so nothing a later run does can deflate it. A cycle with a ledger entry, and a continuation cycle that already published a retained result, refuse fail-closed with `reason=CYCLE_ALREADY_RETAINED` before placement, naming the next free cycle — so the bypass launches nothing and the retained result it would have overwritten survives. |
| **R1** `continuation_decision.cycle` must be a JSON number | **Fixed.** The comparison is `(.cycle \| tonumber?)`, so `cycle: "4"` authorises cycle 4, and the recorded decision normalises it back to a number. The marker's example stays unquoted. |
| **R2** nothing binds a continuation artifact to its story | **Fixed, additively.** The prompt asks the worker for `story_id` (the story file's basename without its extension); the schema id does not move. A present-and-different id is refused on the existing loud path with `detail=STORY_MISMATCH`, on both the consuming and the producing side; an absent one is accepted and reported as the finding `CONTINUATION_ARTIFACT_UNBOUND`. No marker ever quotes the id it read. |
| **R3** a continuation refused by sizing leaves no record line | **Fixed.** The sizing refusal on a continuation cycle appends one dated `CONTINUATION_REFUSED` line through `record_budget_line`, carrying the cycle it would have continued and estimate/window/ratio. It is appended after the estimate, so the estimate stays deterministic across a re-dispatch. |
| **R4** the retained series is unbounded | **Documented as load-bearing.** The contract now says in so many words that the retained per-cycle results and the ledger are never pruned because the chain and the cap are counted from them. |

#### Changes

- `files/model-router/scripts/dispatch.sh` — `with_story_lock` extracted so the
  ledger append and the record append share one critical section on one inode;
  the ledger helpers, `story_id_of`, `continuation_story_verdict`,
  `next_free_cycle` and `refuse_cycle_retained` added; `continuations_consumed`
  is now the ledger's length; the continuation block moved ahead of the
  `max_cycles` check; `CONTINUATION_REFUSED` on the sizing path; the ledger
  appended immediately before `orca_launch`.
- `files/model-router/context-budget-policy.yaml` — three reason codes declared
  (`CONTINUATION_REFUSED`, `CONTINUATION_ARTIFACT_UNBOUND`,
  `CYCLE_ALREADY_RETAINED`) and the `continuation_cap` comment corrected to say
  where the count comes from.
- `lib/afk-commands.sh` — the same three codes published by `schema`.
- `docs/LIFECYCLE-CONTRACT.md`, `files/model-router/SKILL.md` — the ledger, the
  cap-before-`max_cycles` ordering, both keys in the remedy, the `story_id`
  binding, the sizing record line, and the unpruned series as load-bearing.
- `tests/run-tests.sh` — section 3e gains the shipped-defaults cases, the
  marker's remedy applied verbatim out of the marker text, its control, the
  ledger written by a real launch, the bypass and its two controls, the quoted
  cycle, the three binding cases and the sizing record line; two existing cases
  were re-pointed at the cycles they now describe.

The frozen launch command texts and `lib/afk-monitor.sh` are byte-identical;
the suite's own oracles for both still pass.

#### Gates

| gate | exit | tally |
|---|---|---|
| `bash tests/lifecycle-dispatch-tests.sh` | 0 | 256 passed, 0 failed |
| `bash tests/lifecycle-readiness-tests.sh` | 0 | 290 passed, 0 failed |
| `bash tests/lifecycle-tests.sh` | 0 | 478 passed, 0 failed |
| `git diff --check` | 0 | clean |
| `bash tests/run-tests.sh` | 1 | 729 passed, **1 failed** |

The one red is the recorded known flake and nothing else: `lifecycle
concurrency gate`, whose own aggregate is 204 passed / 3 failed. Its three
assertions are the publication-window triple — `a contender that observed the
window waits it out rather than refusing` (expected 1, got 3), `and reports the
live owner it was waiting for` (expected LIVE, got UNKNOWN), `so nothing it says
can be read as 'this lock has no owner'` (expected 0, got 1). Reproduced by
running `tests/lifecycle-concurrency-tests.sh` on its own; nothing in this lane
touches the operation lock. Every other section of the suite is green, including
the whole of 3d and 3e.

#### Deferred, deliberately, and disclosed

- **`CYCLE_ALREADY_RETAINED` is scoped to continuation cycles, not to every
  cycle.** F2 reads literally as "any cycle number with a retained result is
  never re-run in place". Implemented that way it refuses the ordinary
  re-dispatch that the rest of the kit documents and the suite exercises
  throughout — a stamp refresh, a dead terminal, a flaked gate — and 20+
  existing section-3 assertions fail on stories the suite legitimately
  re-dispatches at the same cycle. Diagnosis: the defect B2 describes is a
  CONTINUATION being re-run, and the deflation half is closed by the count
  moving to the ledger, not by the guard. So the guard is: any cycle with a
  ledger entry, plus a continuation cycle that already published a retained
  result. That closes the bypass and the deflation with no false refusals; an
  ordinary re-dispatch cannot move the cap, because the cap no longer reads the
  result it rewrites.
- **The reviewer's `attack-03` section A and `attack-05` section A baselines no
  longer set up a capped story.** Both plant retained per-cycle results and no
  ledger, and F2 moved the count to the ledger, so a story planted that way now
  reads as having consumed nothing. Re-running those scripts unchanged shows
  cycle 4 proceeding (or refused by `max_cycles`) rather than the cap firing —
  a fixture that describes the old mechanism, not a behaviour that regressed.
  The suite covers the same two cases against the new mechanism: `defaults/absent`
  and `defaults/three` for B1, and `cap bypass` with both controls for B2. The
  evidence directory is out of scope for this cycle and was not touched.
- **Deleting the ledger resets the count.** The retained results still refuse a
  re-run of a continuation cycle, so a story cannot replay a cycle, but a story
  whose ledger file is removed reads as having consumed nothing. The old
  count-from-results had the mirror-image weakness and a worse one besides.
  Making the ledger tamper-evident is a real question and belongs to whoever
  owns the retention policy; it is out of scope here.
- **`story_id` is not required this cycle**, by F4's own instruction: an absent
  member is accepted and reported. Requiring it is a schema-major decision for
  lane D, and the finding is the seam that lane will read.
- **A single commit cannot carry its own hash**, so the commit SHA for this
  cycle is not recorded here; the coordinator records it.

### Coordinator log — merge (2026-09-08) **[MERGE LOGGED]**

- Lane C routed naturally to `{claude, local-code-standard, medium}` and was
  overridden to `claude/strong` under the owner's standing ruling (stamp
  `sha256:ea1922dc…`).
- Implementation worker succeeded (`88c24b6`; reviewable 695/6 across 6
  files, on budget; `lib/afk-monitor.sh` byte-identical and asserted);
  coordinator's independent five gates matched (290/0, 256/0, 478/0,
  diff-check, run-tests 669/1 with the recorded concurrency aggregate the
  only red). Fresh-session adversarial + senior review
  (`evidence/AFK-PORT-1.5C-REVIEW/`): NOT CLEAN — two blockers (the cap gate
  unreachable behind `max_cycles` with an incomplete marker remedy; a cap
  bypass by re-dispatching an earlier cycle number that also deflated the
  count) and four residuals. One bounded fix cycle (`AFK-PORT-1.5C-FIX`,
  `b7c16c2`) closed all six with an append-only continuation ledger and a
  refusal to re-run a retained cycle; a diff-scoped post-fix review
  (`evidence/AFK-PORT-1.5C-POSTFIX-REVIEW/`) verified every remedy from real
  launches, showed the first reviewer's now-failing scripts to be setup
  artefacts of the retired counting mechanism, and raised five low residuals
  (N1 deleting the ledger resets the count; N2 a continuation under the cap
  still meets the untyped `max_cycles`; N3 launch guard not re-checked under
  the lock; N4 the marker's block can lower a larger `max_cycles`; N5
  decision wording) — N4/N2 folded into the queued usage-adapter fix cycle,
  the rest to the registry. Post-fix independent gates 290/0, 256/0, 478/0,
  diff-check, 729/1.
- PR #34 squash-merged to `master` as `e207314` under the owner's standing
  merge grant (GitGuardian clean; Devin skipped; zero comments). Host kit
  update through the Git channel: the first plan reported `LOCAL_DRIFT` on
  the model-router tree — a peer coordinator had configured the installed
  `subscriptions.yaml` (gateway credential reference and a catalog path) and
  left a backup file beside it; the kit moved the stray backup out of the
  managed tree into its own backups directory, classified the configured file
  as a local adaptation, and converged 6d1315f → e207314 with the peer's
  settings preserved (`evidence/AFK-PORT-1.5C/host-update-*.json`). Installed
  adapter byte-identical to the repository.
- The session was resumed mid-packaging; the post-fix `run-tests.sh` process
  survived the resume and its tally was harvested from the log.

### Coordinator log — merge (2026-09-08) **[MERGE LOGGED]**

- Lane C routed naturally to `{claude, local-code-standard, medium}` and was
  overridden to `claude/strong` under the owner's standing ruling (stamp
  `sha256:ea1922dc…`).
- Implementation worker succeeded (`88c24b6`; reviewable 695/6 across 6
  files; `lib/afk-monitor.sh` byte-identical, asserted); coordinator's
  independent five gates matched (290/0, 256/0, 478/0, diff-check,
  run-tests 669/1 with the recorded concurrency aggregate the only red).
  Fresh-session adversarial + senior review (`evidence/AFK-PORT-1.5C-REVIEW/`):
  NOT CLEAN — two blockers (the cap gate hidden behind `max_cycles` with an
  incomplete marker remedy; a cap bypass by re-dispatching an earlier cycle
  that also deflated the count) and four residuals. One bounded fix cycle
  (`AFK-PORT-1.5C-FIX`, `b7c16c2`: cap gate before `max_cycles`, complete
  marker remedy, append-only continuation ledger, `CYCLE_ALREADY_RETAINED`,
  numeric-string decision, artifact bound to its story, sizing-refused record
  line, unpruned series documented). Diff-scoped post-fix review
  (`evidence/AFK-PORT-1.5C-POSTFIX-REVIEW/`): CLEAN, every remedy verified
  from real launches; the first reviewer's now-failing scripts shown to be
  setup artefacts of the retired count-from-results mechanism; five new low
  residuals N1–N5 recorded (N4, the marker block lowering a larger
  `max_cycles`, folded into `AFK-PORT-1.5B-FIX2`). Post-fix independent
  gates 290/0, 256/0, 478/0, diff-check, 729/1.
- PR #34 squash-merged to `master` as `e207314` under the standing merge
  grant (GitGuardian clean; Devin skipped; zero comments). Host kit update
  first REFUSED on `LOCAL_DRIFT`: a stray `subscriptions.yaml.2026-08-16.bak`
  left in the managed tree by another PM session's config edit (their
  `catalog_path` change is a legitimate machine-owned adaptation); the
  coordinator moved the backup out of the managed tree, re-planned, and the
  update `CONVERGED` 6d1315f → e207314, verify `CURRENT`
  (`evidence/AFK-PORT-1.5C/host-update-*.json`).
