# AFK-PORT-1.5C-POSTFIX-REVIEW: CLEAN

Diff-scoped post-fix review of `b7c16c2` against its parent `88c24b6` on
`jlengelbrecht/afk-port-1.5c`, in the lane A worktree. Fresh session; I did not
write this code, did not write the fix, and did not write the review it answers.

Persona proof, computed first and fail-closed:
`{ sha256sum .agents/skills/bmad-agent-dev/SKILL.md; sha256sum
.agents/skills/bmad-agent-dev/customize.toml; } | sha256sum` →
`07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee`, the OUTER
hash the brief expects. Match.

Everything below was reproduced by running the real `dispatch.sh`. The probe
scripts live beside this file; `harness-lib.sh` and `fixtures2.sh` are verbatim
slices of `tests/run-tests.sh` (preamble 30–56, stubs/fixtures 658–840, and the
3e helper definitions), regenerable with `regen-harness.sh`, so the probes drive
the same launcher the suite does without borrowing a single one of its verdicts.
Every case carries its own control. `tests/run-tests.sh` was NOT run — the
coordinator's chain owns it in this worktree. Nothing outside this directory was
modified; the first reviewer's evidence directory hashes the same before and
after my re-runs of its scripts.

Both blockers are closed, and closed at the right layer. B1 was answered by
moving the gate rather than only by editing the marker text, which is the
larger of the two remedies the first review offered and the one that makes the
typed refusal the refusal a capped story actually gets. B2 was answered by
making the count a fact about windows that were spent instead of an inference
from files the next run rewrites — the ledger is appended after every gate that
could still refuse, so an entry means a terminal existed. The `deferred and
disclosed` section of the Dev Agent Record is accurate: I checked each of its
four claims and each holds, including the one it volunteers against itself.

One item is PARTIAL: F5's record line is delivered correctly, but the
determinism sentence written into the contract and the code comment beside it is
false. It is a documentation defect with no safety consequence, so it does not
reach the blocker bar.

---

## Per item

### F1 / B1 — the cap gate is reachable, and its remedy works — **VERIFIED**

`probe-01-f1-cap-before-maxcycles.sh` / `probe-01.log`, 25 passed, 0 failed.
The scenario is built the way a real pair of launches builds it — two ledger
entries — rather than by planting results.

At `max_cycles` absent and at `max_cycles: 3`:

```
  [max_cycles absent] exit=3
  PASS defaults/absent: by the CAP gate, typed      (CONTINUATION-CAP: reason=CONTINUATION_CAP_REACHED)
  PASS defaults/absent: carrying the count          (count=2)
  PASS defaults/absent: carrying the cap            (cap=2)
  PASS defaults/absent: not the untyped max_cycles message
  PASS defaults/absent: nothing launched / nothing placed
  [max_cycles three]  exit=3   — identical
```

The remedy is lifted out of the live marker with `sed` and dedented, never
retyped, and the only edits are the `<placeholder>` substitutions the marker
itself asks for:

```
continuation_decision:
  cycle: 4
  actor: <who decided>
  at: <RFC3339 timestamp>
  reason: <why one more continuation is the right call>
max_cycles: 4
```

→ `PASS remedy: the authorised cycle proceeds` (exit 0),
`PASS remedy: and the decision is recorded` (`continuation_decision.cycle` = 4).

Both controls hold. The decision **alone** is still refused at the shipped
defaults (`max_cycles (3) exceeded`, nothing launched) — which is exactly why
the marker has to print both keys — and `max_cycles` still bounds what the cap
lets through: an authorised cycle 4 on a story that declares `max_cycles: 3` is
refused by the per-story limit.

Adversarially: pasting the block verbatim onto a story that **already** declares
`max_cycles: 8` produces a duplicate frontmatter key. `yq` takes the last, so
the dispatch still proceeds (exit 0) — the paste is not broken, though it
silently lowers the story's own limit from 8 to 4. The marker's prose says
"leave a larger value alone", the block it prints does not. Cosmetic; recorded
as residual N4.

### F2 / B2 — the ledger, and cycles that are never re-run — **VERIFIED**

`probe-02-f2-ledger-and-bypass.sh` / `probe-02.log`, 48 passed, 2 deliberate
failures (residuals N1 and N2, below — both assertions I wrote to make a
disclosed weakness visible, not remedies that were missed).

*Happy path, from real launches.* No ledger exists before the first
continuation. Cycle 2 launches → `[2]`. Cycle 3 launches → `[2,3]`. Cycle 4 is
refused, typed, `count=2`, and the ledger is unmoved by the refusal:

```
{"schema":"afk-continuation-ledger/1","entries":[
  {"cycle":2,"from_cycle":1,"artifact_sha256":"sha256:e817ec…","trigger":"WORKER_SIGNAL","at":"…","decision":null},
  {"cycle":3,"from_cycle":2,"artifact_sha256":"sha256:e817ec…","trigger":"USAGE_BAND","at":"…","decision":null}]}
```

*The bypass.* Re-dispatching the previous cycle number — the first reviewer's
attack-05 B — is refused: `exit=3  terminals launched=0`, marker
`NEEDS-HUMAN: reason=CYCLE_ALREADY_RETAINED cycle=3 next_free_cycle=4`, nothing
placed, ledger unmoved, and three repeats are refused identically.

*The deflation, attempted.* Cycle 3's retained result is byte-identical before
and after the attempted re-dispatch, so the count cannot go down. Both of
attack-05's controls now hold: cycles 4 and 5 are still refused at the cap.

*The count is the length.* Two ledger entries numbered 900 and 901 on a story
dispatched at cycle 41 reach the cap and are counted as 2; the control — one
entry — is under the cap and proceeds, and that launch appends the second entry.

*Unreadable is not empty.* Four malformed ledgers (`not json`, wrong schema id,
no schema id, a bare array) each refuse with `NEEDS_HUMAN` and the message "a
count that cannot be read is not a count of zero", nothing launched. The
control, a well-formed empty ledger, proceeds.

*The entry means a window.* A stamp refusal (validator exit 1, reached after the
cap gate and before the launch) writes **no** ledger at all.

*The control that matters most.* An **ordinary** cycle re-dispatches unchanged
and writes no ledger entry, so the documented recovery from a stamp refresh, a
dead terminal or a flaked gate still works. The scoping decision the Dev Agent
Record discloses is the right one, and I verified the reasoning rather than
accepting it: an ordinary re-dispatch cannot move the cap because the cap no
longer reads the result it rewrites.

### F3 / R1 — the decision's `cycle` as a number — **VERIFIED**

`probe-03-f3-f4-f5.sh` / `probe-03.log`. `4`, `"4"` and `'4'` each authorise
cycle 4, and each is recorded as JSON type `number` with value `4`. Five
controls do **not** authorise and are refused at the cap with the typed marker:
`5`, `"5"`, `"four"`, `null`, `true`. `null | tonumber?` and `true | tonumber?`
both yield empty rather than a spurious match, which is what makes the absent
case behave.

### F4 / R2 — the artifact names its story — **VERIFIED**

Match → consumed (exit 0) and nothing reported as unbound. Mismatch → exit 3 on
the existing loud path, `reason=CONTINUATION_ARTIFACT_INVALID
detail=STORY_MISMATCH`, no result artifact, nothing placed, nothing launched, no
ledger entry — and the marker never quotes the id it read
(`assert_absent … "some-other-story"` passes). Absent → accepted and reported as
`CONTINUATION_ARTIFACT_UNBOUND` in `budget.findings`.

Adversarially, `story_id: null` and `story_id: ""` are both treated as absent
rather than as a mismatch — a hand-over that says nothing is not a hand-over
that lies. And the prompt asks the worker for the value the launcher actually
compares against: the generated prompt contains, literally,
`story_id, which is\n"p3-prompt"` for story `p3-prompt.md`.

### F5 / R3 — the sizing refusal leaves a record line — **PARTIAL**

The line itself is right:

```
- budget: CONTINUATION_REFUSED from cycle 2 670/619 (1.082390) cycle 3 2026-09-08T03:13:07Z
```

exactly one of them, inside `## Dev Agent Record`, on a refusal that placed
nothing, launched nothing and left the ledger unmoved. The control holds: an
**ordinary** cycle refused by sizing writes no such line.

What is not verified is the sentence the fix wrote about it. Both the contract
(`docs/LIFECYCLE-CONTRACT.md`) and the comment at `dispatch.sh:1731-1737` claim
the line is appended after the estimate "so the story's own bytes are the same
on a re-dispatch of that cycle as they were on the first and the estimate stays
deterministic". The story file is itself a counted payload input
(`budget_payload_paths`, `dispatch.sh:677`), so appending the line grows it:

```
  attempt 1: estimate 670
  attempt 2: estimate 693
  attempt 3: estimate 693
```

The reasoning behind the placement is sound and I would keep it — the append
cannot influence *its own* estimate, and `record_budget_line` is idempotent on
`(code, cycle)`, so the estimate settles from the second attempt on. But the
claim as written is about re-dispatch, and across a re-dispatch it is false. The
drift is one record line ÷ 4 ≈ 23 tokens and can only ever push the ratio
**up**, so it cannot turn a refusal into a launch; the refusal is stable
(exit 8 on every attempt) and the line is still written exactly once. Below the
blocker bar, but it is a contract sentence that is not true of the code, which
is the class AC-7 is about. The honest fix is one sentence: the append is after
the estimate so it cannot affect the estimate it reports, and a re-dispatch of
the same cycle re-estimates a story that is one line longer.

### F6 / R4 — the unpruned series documented as load-bearing — **VERIFIED**

`probe-04.log`. The contract says "Neither series is ever pruned, and that is
load-bearing rather than tidy", and says why — deleting either "would make a
story's spent continuations uncountable and hand it back windows it had already
used". The ledger schema id appears in the contract; the policy's
`continuation_cap` comment now names `<story>.continuations.json` as the count.

### F7 — the post-review registry — **VERIFIED**

`### Post-review fix cycle (AFK-PORT-1.5C-FIX)` is present in
`AFK-PORT-1.5C.md`'s Dev Agent Record with a disposition row for each of B1, B2,
R1–R4, the changes, the gate table, the disclosures, and the statement that a
single commit cannot carry its own hash. I checked each disposition against the
code rather than reading it: all six are accurate, and the four disclosures are
accurate too, including the one that volunteers the ledger-deletion weakness
(N1 below) against itself.

### Frozen texts and surface — **VERIFIED**

- `lib/afk-monitor.sh` byte-identical to `master` (`2d92988128be15fb…`), and the
  comparison is non-vacuous: a one-line mutation hashes differently.
- All three frozen launch command texts emitted by **both sides' builders** for
  identical inputs and compared: `build_claude_command`,
  `build_claude_gateway_command`, `build_codex_command` — byte-identical. The
  control fires: a perturbed `effort` IS detected as different.
- Seven changed files, every one inside the fix story's declared surface. The
  reviewer's evidence directory, `make-stamp.sh`, the catalog and
  `lib/afk-monitor.sh` are untouched.
- Commit plain: no `Co-Authored-By`, no `Generated with`, no `Claude-Session`,
  no `claude.ai/code`, no 🤖, and no internal vocabulary in the message.
- `git diff --check` clean, both on the range and on the working tree.
- 762 added / 110 deleted across 7 files for this commit.

### Disposition of the first reviewer's now-failing scripts

Re-run unchanged (`rerun-attack-03.log`, `rerun-attack-05.log`) and diagnosed
with the markers printed (`probe-05-old-attack-dispositions.sh` /
`probe-05.log`, 11 passed, 0 failed). **Every remaining failure is a setup
artefact of the retired count-from-results mechanism. None is a regression.**

Both scripts plant per-cycle results and write no ledger at all
(`assert_no_file "the setup writes no ledger at all"` passes), and the cap is
now the ledger's length, so a story planted that way has consumed nothing.

| old assertion | now | why |
|---|---|---|
| attack-03 A `the cap gate is REACHED at the shipped default max_cycles` | FAIL | setup artefact. Count is 0, so the cap does not fire and `max_cycles (3)` refuses with no marker. Planting a two-entry ledger on the **same story** produces `CONTINUATION-CAP: reason=CONTINUATION_CAP_REACHED count=2 cap=2 cycle=4` (probe-05), and probe-01 A proves it from real launches. |
| attack-03 A `the marker's remedy, applied verbatim, lets the authorised cycle proceed` | FAIL | setup artefact, twice. The cap never fired so no marker existed to lift a remedy from, and the script hard-codes the **old** remedy shape (decision only). Its own stderr shows the decision working — `continuation: authorised by a recorded decision (josh) for cycle 4` — and then `max_cycles (3)` refusing, which is precisely what the new marker's second key exists to prevent. probe-01 B lifts the block out of the live marker: exit 0. |
| attack-03 A `the cap marker or the docs mention the max_cycles interaction` | **now PASS** | fixed (the script's tally went 29→30 passed). |
| attack-05 A `cycle 4 is refused at the cap` / `with the typed marker` | FAIL | setup artefact. Empty ledger → cycle 4 launches (exit 0) and writes the story's first entry, `[4]`. |
| attack-05 B `a story refused at the cap cannot get another window by re-running an earlier cycle number` | **now PASS** | the defect is closed. In this setup it is closed by the retained-result half of the guard: `NEEDS-HUMAN: reason=CYCLE_ALREADY_RETAINED cycle=3 next_free_cycle=5`. All three repeats refused. |
| attack-05 C `control: cycle 4 is still refused` | **now PASS** | but by `CYCLE_ALREADY_RETAINED` (the ledger entry section A's launch wrote), not by the cap — worth stating, since the assertion's text says "at the cap". |
| attack-05 C `control: cycle 5 is refused too` | FAIL | setup artefact. The ledger holds one entry, so cycle 5 is genuinely the second continuation and under the cap of 2. probe-02 D reproduces the intended control from a real chain: cycles 4 and 5 both refused at the cap. |

The brief points at `evidence/AFK-PORT-1.5C-FIX/coordinator-postfix-*.out` for
the coordinator's own re-runs. That directory does not exist in this worktree,
so I re-ran both scripts myself and kept the logs here. The first reviewer's
directory is unmodified: `sha256sum …/AFK-PORT-1.5C-REVIEW/*.sh *.log |
sha256sum` is `b488ad3b84fd0d17e3fcec9ee7991a22620f1e547248cf620e2d2c2f99a26fe4`
before and after.

---

## New blockers

None.

## Residuals

- **N1 — deleting the ledger resets the count.** `probe-02` H: with the story
  capped and cycle 4 refused, removing `<story>.continuations.json` lets cycle 4
  launch (exit 0). The file sits in the worker's own sandbox, beside the
  checkpoint and continuation artifacts the worker is instructed to write. This
  is **disclosed** in the Dev Agent Record, is a deliberate act rather than an
  ordinary operator action, and is the mirror of the weakness the retained
  results already had — the old mechanism could be deflated *without* deleting
  anything, which is why B2 was a blocker and this is not. Tamper-evidence
  belongs with whoever owns the retention policy; it is a real lane-D question.
- **N2 — a continuation *under* the cap still meets the untyped `max_cycles`.**
  `probe-02` J: with `continuation_cap` raised to 9 and `max_cycles` at the
  shipped default, cycle 4 is refused by `max_cycles (3) exceeded` with **no
  marker written at all** — B1's shape, one gate further along. Not reachable at
  the shipped policy: with `continuation_cap: 2` the two continuations are
  cycles 2 and 3, both inside the default limit, and cycle 4 is the capped one
  that now gets the typed marker. It becomes reachable the moment someone raises
  the cap without raising `max_cycles`. The cheap answer is for the `max_cycles`
  refusal to write a marker of its own; that is outside this lane's surface.
- **N3 — the launch guard is read before the launch and not re-checked under the
  lock.** `probe-06-ledger-concurrency.sh`: three dispatches of the *same*
  continuation cycle started together all launch, and the ledger records
  `[2,2,2]` — three windows for one cycle, past a cap of 2. `LEDGER_ENTRIES` is
  read once at the top of `main()`; the append happens hundreds of lines later,
  immediately before `orca_launch`. The append itself is sound: the ledger still
  parses under its schema and there is exactly one entry per terminal actually
  created, so the count **over**-reports rather than deflating and the next
  dispatch refuses sooner — the failure direction is the safe one. It needs two
  simultaneous dispatches of the same story and cycle, which is not an ordinary
  operator action and is the same exposure an ordinary cycle already has, so it
  is below the bar. Closing it means re-checking `ledger_has_cycle` inside
  `with_story_lock` at the append.
- **N4 — the marker's block lowers an existing larger `max_cycles`.** `probe-01`
  E: the marker prints `max_cycles: <cycle>` unconditionally, so a verbatim paste
  onto a story declaring `max_cycles: 8` yields a duplicate key; `yq` takes the
  last and the dispatch proceeds, but the story's limit silently drops to 4. The
  marker's prose already says "leave a larger value alone" — the block does not.
  Cosmetic.
- **N5 — "records the decision verbatim" is no longer quite true.** The contract
  keeps that phrasing while F3 normalises `cycle` to a number, so a decision
  written `cycle: "4"` is recorded as `4`. The normalisation is right and the
  code comment says so; only the contract sentence lags. One word.

## Gates I ran, with wall times

| gate | exit | wall | tally |
|---|---|---|---|
| `bash tests/lifecycle-readiness-tests.sh` | 0 | ~275s | 290 passed, 0 failed |
| `bash tests/lifecycle-dispatch-tests.sh` | 0 | ~200s | 256 passed, 0 failed |
| `bash tests/lifecycle-tests.sh` | 0 | ~600s | 478 passed, 0 failed |
| `git diff --check` (range and working tree) | 0 | — | clean |
| `probe-01-f1-cap-before-maxcycles.sh` | 0 | ~50s | 25 passed, 0 failed |
| `probe-02-f2-ledger-and-bypass.sh` | 1 | ~180s | 48 passed, 2 failed (N1, N2 — deliberate) |
| `probe-03-f3-f4-f5.sh` | 1 | ~150s | 49 passed, 1 failed (F5 determinism — deliberate) |
| `probe-04-frozen-surface-hygiene.sh` | 0 | ~5s | 51 passed, 0 failed |
| `probe-05-old-attack-dispositions.sh` | 0 | ~40s | 11 passed, 0 failed |
| `probe-06-ledger-concurrency.sh` | 1 | ~30s | 5 passed, 1 failed (N3 — deliberate) |
| `attack-03…` re-run unchanged | 1 | ~70s | 30 passed, 2 failed (both setup artefacts) |
| `attack-05-cap-bypass.sh` re-run unchanged | 1 | ~60s | 2 passed, 3 failed (3 setup artefacts; its 2 passes are the closed defect) |

`tests/run-tests.sh` was not run: the coordinator's gate chain owns it in this
worktree. The fix's recorded aggregate (729/1, the known publication-window
concurrency triple) is unchallenged by anything I found — nothing in this diff
touches the operation lock.

## Dev Agent Record

Review-only. No product code, test, doc, story record or git state was
modified; the only files written are `REVIEW.md`, the six probe scripts,
`harness-lib.sh`, `fixtures2.sh`, `regen-harness.sh` and the logs, all under
`evidence/AFK-PORT-1.5C-POSTFIX-REVIEW/`. `tests/run-tests.sh` was not run.
Scratch work stayed in the harness's own `mktemp -d` roots.

One note on the brief: it names HEAD `daa00e9`, which exists in this repository
but is not an ancestor of this branch's HEAD. The branch HEAD is `b7c16c2`
("Count the continuation cap from an append-only ledger, and let a capped story
reach the refusal"), whose parent is `88c24b6` — the pair the review story names,
and the pair I reviewed.
