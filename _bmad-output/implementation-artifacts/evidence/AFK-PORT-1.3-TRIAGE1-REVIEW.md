# AFK-PORT-1.3-TRIAGE1 — diff-scoped review of the post-freeze triage round

## 1. Verdict

**CLEAN.**

No blocker in the triage delta. T1 fixes the class it names rather than the
instance — the persisted window is the only window any live path reads, and the
three sites that could disagree about a deadline do not. T2 is a reporting
change that changes no check and no verdict. I found no previously-green monitor
path the delta broke, and the "PR-triage round 1" record is accurate on every
claim I could check by reading, with one qualification (R4).

Non-blocking register: 8 entries. Three are delta-scoped (R1–R3), one is a
record-truthfulness qualification (R4), one is a coverage suggestion (R5), and
three are pre-existing or explicitly-out-of-scope items I am registering so they
are not rediscovered as new (R6–R8).

Scope: the `cfcf9b5..7d126fc` delta — about 75 reviewable lines across
`lib/afk-monitor.sh`, `tests/lifecycle-dispatch-tests.sh` and
`tests/lifecycle-readiness-tests.sh` — plus the interaction points the brief
names. I took as established, and did not re-derive: gates green on `7d126fc`
(run-tests 235/0, lifecycle 476/0) and the A3/P1/P2 oracle re-runs (NOT
REPRODUCED).

I had Read/Glob/Grep/Write and **no shell**. I executed nothing — see §6. The
blocker bar asks for a reproduction by my own script, and a reviewer who cannot
run a script cannot clear that bar; so the honest statement of this verdict is:
nothing in the delta is a frozen-requirement violation *on the face of the
source*, and the three scripts in
`evidence/AFK-PORT-1.3-TRIAGE1-REVIEW-attack/` exist so the coordinator can put
a run behind the register entries that most deserve one.

---

## 2. Blockers

None.

The two things I most expected to find and did not:

- **Another site still reading the process default where it should now read the
  record.** There are exactly three references to
  `AFK_MONITOR_HEARTBEAT_SECONDS` in the product: its definition
  (`lib/afk-monitor.sh:108`), the resolution at registration (`:524`), and the
  fallback at the refresh (`:656`). The expiry judge reads the record and
  nothing else (`:771-772`), and `heartbeat_deadline_epoch` is written in
  exactly two places (`:547`, `:660`) and read in exactly one (`:771`). There is
  no fourth opinion about when a Dispatch is late.
- **A jq edit that drops the rest of the record.** Every write after
  registration is an edit over the record that was just read — the fault setter
  (`:355`), the heartbeat arm (`:654-661`), the completion reconciliation
  (`:721-734`), and the cleanup disposition (`:1089-1095`). None reconstructs a
  record from a projection, so `heartbeat_seconds` survives
  `WATCHING → COMPLETED → SETTLED`, and the heartbeat arm cannot reach a
  non-heartbeat record: it returns at `:664`/`:670` before the shared retention
  path. `afk_monitor_summarize` projects a fixed shape (`:1203-1205`,
  `:1223-1236`), so the new field cannot leak into normalized output either.

---

## 3. Non-blocking register

Class in brackets, with `file:line` and the text it presses on.

**R1 [behaviour, delta] `lib/afk-monitor.sh:657-660` — a declared window of `0`
is now a permanent opt-out from `WORKER_HEARTBEAT_EXPIRED`, where before the
delta it was only an opt-out until the first heartbeat.** Registration has
always read `0` as "no deadline" (`:547`), and the delta made the refresh agree
with it (`:660`). Pre-triage, the refresh recomputed from the process default
regardless, so a Dispatch registered with `heartbeat_seconds: 0` acquired a
1800-second deadline the moment its first heartbeat landed and could then
expire. Post-triage it never can: the sweep only judges records whose deadline
is `> 0` (`:772-773`). The story's out-of-scope section says
"`WORKER_HEARTBEAT_EXPIRED` semantics unchanged (a TRUE expiry still fires
exactly as today)" — for this one input class that is not quite true, and the
change is in the direction of *less* monitoring. **Why it is not a blocker:**
nothing in the kit writes a descriptor at all, and nothing anywhere sets
`heartbeat_seconds` (`grep` over `lib/`, `bin/`, `files/` finds only the monitor
and the gate), so reaching it takes a hand-written descriptor that explicitly
declares `0`. The delta also made the two halves *consistent*, which is the
better of the two available inconsistencies. **Recommended ruling:** either
refuse `0` at registration (a window of none is not a window), or state in the
contract that `0` is the declared opt-out and let it be one. Evidence:
`T1b-antivacuity-two-trees.sh` part C runs the same descriptor against both
trees and prints the divergence; `T1a-window-class-matrix.sh` case `0` shows
what it persists.

**R2 [robustness, delta-adjacent] `lib/afk-monitor.sh:656` — the fallback
argument is evaluated even when the fallback is not used, and it is the one
value on this path that is never validated.** `AFK_MONITOR_HEARTBEAT_SECONDS` is
a declared operator knob (`bin/agent-flow-kit:255`). Registration normalizes a
malformed one to `1800` (`:526-528`); the refresh passes it straight into
`jq --argjson default_hb` (`:656`), which is parsed *before* the program runs.
So `AFK_MONITOR_HEARTBEAT_SECONDS=30m` — a units typo, the plausible one — makes
every heartbeat refresh fail, including for records that carry their own window
and would never consult the fallback; each one then drifts to its deadline and
reports `WORKER_HEARTBEAT_EXPIRED` with nobody late. That is the B3 spurious
loud-`NEEDS_HUMAN` class T1 exists to remove, arrived at from the other
direction. **Why it is not a blocker:** the failure is loud and recoverable, not
silent — the record is not written, the delivery stays in the inbox for the next
pass, the run reports `RESULT_NOT_RETAINED` and exits owner-action — and the
reachability is unchanged by the delta: the pre-triage arm passed the same
variable the same way. The delta did, however, turn this value from "the answer"
into "the fallback", which makes an unvalidated hard failure over it harder to
justify. **Fix is one line:** reuse the `case` at `:523-528` before the jq call.
Evidence: `T1a-window-class-matrix.sh` part B, including the record-carries-its-
own-window case.

**R3 [robustness] `lib/afk-monitor.sh:523-528` vs `:534-537` — digits-only is not
the same as JSON-numeric, and the finding that results names the wrong thing.**
A descriptor carrying `"heartbeat_seconds": "0800"` (or `"007"`) passes the
shell guard, which only rejects non-digits, and then breaks `--argjson hb`, so
the record-building jq never runs. The registration fails closed, which is
right, but it reports `RESULT_NOT_RETAINED` with "a writable dispatch watch
directory / unwritable" (`:572-574`) — it blames the filesystem for a descriptor
defect, and the operator who wrote the descriptor gets sent to look at the disk.
Same class as R2 and the same one-line neighbourhood. Evidence:
`T1a-window-class-matrix.sh` case `"0800"`.

**R4 [record truthfulness] `AFK-PORT-1.3.md:253-257` — "the zero case is
preserved on both paths" is true of registration and not of the pre-triage
refresh.** The sentence is accurate as written about the two *current* paths
agreeing; read as the reassurance it is placed to give ("nothing about expiry
changed"), it is missing R1. One sentence in the superseding freeze revision
closes it. Nothing else in the record needs amendment — see §5.

**R5 [coverage] `tests/lifecycle-dispatch-tests.sh:478-520` — the new scenarios
pin the two points the fix was written for and nothing either side of them.** A
declared window of `0` (R1) and a malformed process default (R2) are both
one-scenario checks in the same section, and both are exactly the kind of thing
that regresses silently the next time this arithmetic is touched. Not a demand:
the round was bounded to two items and this is the third.

**R6 [pre-existing, out of delta] `lib/afk-monitor.sh:661` — `processed_deliveries`
grows without bound on the heartbeat path.** Every heartbeat appends its
delivery id, and heartbeats are the only delivery kind that repeats. The array
is what makes replay handling exactly-once, so it cannot simply be dropped, but
a Dispatch that heartbeats for a week carries a week of ids in the record it
rewrites on every beat. Untouched by the delta; registered because T1 is what
makes long-lived watches behave well enough to become common.

**R7 [pre-existing, out of delta] `lib/afk-monitor.sh:345-352` — `afk_monitor_now`
returns `0` when `date` fails, and a record registered under that condition is
already expired.** `heartbeat_deadline_epoch` would be `0 + hb`, a 1970 instant,
which the next sweep with a working clock reads as long past (`:773`). The
triage record's clock-independence argument for the new assertions
(`AFK-PORT-1.3.md:315-321`) is correct on its own terms — both fields come from
one reading, so the *delta* is the window either way — and this is a different
question about the same helper.

**R8 [consistency, out of scope by instruction] `tests/run-tests.sh:1119-1124` —
the aggregator prints its two summary lines in the opposite order to the two
suites.** The suites print the sentence and then the counts, precisely so that
`tail -1` carries the counts (`tests/lifecycle-readiness-tests.sh:1265-1270`,
`tests/lifecycle-dispatch-tests.sh:1211-1216`, aggregated at
`tests/run-tests.sh:1086-1087`). `run-tests.sh` itself prints the counts and
then the sentence, so its own last line is prose. Harmless today — nothing in
this repository tails `run-tests.sh`, there are no files under
`.github/workflows/`, and no `*.yml` in the tree mentions the suites or a
summary line — and a one-line fix if that changes. Registered together with the
half of F2 the round was told to leave alone: a child suite's skips still do not
move the aggregator's own `SKIPPED`, because `:1086-1087` records the child's
summary as the *text* of an `ok`. Evidence: `T2-skip-summary.sh` part A prints
all three blocks' behaviour side by side.

---

## 4. What I attacked and found sound

### 4.1 T1 — the class, not the instance

- **Every reader of the window.** Three references to
  `AFK_MONITOR_HEARTBEAT_SECONDS` (`:108`, `:524`, `:656`), two writers of
  `heartbeat_deadline_epoch` (`:547`, `:660`), one reader (`:771`). The expiry
  judge at `:771` was the specific site the brief asked about: it reads
  `.heartbeat_deadline_epoch` from the record, never the environment, and that
  was already true before the delta. Nothing else in the tree computes a
  heartbeat deadline.
- **Stored windows that are `0`, negative, fractional or non-numeric.** The
  guard at `:523-525` rejects anything with a non-digit, so a negative or
  fractional descriptor value falls to the global and a negative window can
  never reach the record. `0` reaches it and means "no deadline" — that is R1,
  the one input the guard deliberately admits. A record whose
  `heartbeat_seconds` is a *string* (only reachable by hand-editing the record)
  fails the `type == "number"` test at `:657` and takes the legacy path, which
  is the fail-safe direction.
- **The legacy fallback meeting the `hb == 0` case.** A pre-delta record carries
  no window and gets the process default on refresh — byte-for-byte the
  pre-delta behaviour, including for a Dispatch that had originally declared
  `0`. So the compatibility path is a genuine no-op for existing state, and the
  only behaviour change on that path is R1's, which needs a *new* registration
  to reach.
- **Sweep versus refresh disagreeing about the same record.** They cannot,
  within a pass: `afk_monitor_reconcile` drains every delivery first and sweeps
  afterwards (`:812-816`), each step reading the record fresh from disk, so a
  heartbeat that arrives just before its deadline rescues the record in the same
  pass rather than racing a judgement that already happened. The sweep's `now`
  (`:761`) is taken after the deliveries are consumed, so it is never earlier
  than the refresh's (`:655`).
- **Schema compatibility in both directions.** `afk_monitor_record_read`
  validates only the schema major (`:326-329`), so the added field needs no
  version bump; and an *older* kit reading a *newer* record simply ignores
  `heartbeat_seconds` and refreshes from its own default, which is the pre-delta
  behaviour rather than a corruption. Rolling back the library does not strand
  the records it wrote.

### 4.2 T1 — regression honesty

The two scenarios discriminate for the stated reason, by construction:

- `heartbeat-window` (`tests/lifecycle-dispatch-tests.sh:487-506`) registers
  with `3 ×` the default and asserts the persisted field, the first deadline,
  and — the decisive one — that `heartbeat_deadline_epoch - last_heartbeat_epoch`
  after a delivered heartbeat is the declared window and *is not* the default
  (`:497-500`). Against the pre-triage product those three assertions read
  `null`, `1800` and `1800`. The discrimination is a difference in the product
  rather than in the fixture because `DEFAULT_HB` is read from the sourced
  library (`:483`) rather than hard-coded, so an operator who exports a
  different default moves the suite and the child process together; and the
  `assert_ne` at `:485` is the guard against the one arrangement that would make
  the decisive `assert_ne` vacuous — a default of `0`, where the declared window
  would equal it.
- `heartbeat-window-legacy` (`:510-520`) passes on both trees, which is what a
  control is for. The record says so plainly rather than claiming two
  discriminators.
- The pre-existing expiry scenario (`:462-476`) forces `heartbeat_deadline_epoch`
  to `1` with a jq edit that preserves the rest of the record, so the new field
  does not touch it and it still exercises exactly the sweep.
- **Caveat, stated as a limit rather than a doubt:** I verified this by reading
  both products, not by running the old one. `T1b-antivacuity-two-trees.sh`
  builds the pre-triage tree with `git archive` plus one `git show` and runs the
  suite against both; it needs a shell, and its result — not this paragraph — is
  the evidence.

### 4.3 T2 — counted skips

- **No check changed behaviour.** The only mechanism change is inside `skip()`
  (`tests/lifecycle-readiness-tests.sh:53`), which now increments a counter and
  prints the same text. The suite has exactly the two skip sites the record
  names — the `date(1)` dialect probe (`:149-153`) and the router-timeout
  scenario (`:712-725`) — and both are `else` branches of pre-existing
  capability probes, so no `ok`/`bad` call site became a `skip` and the pass
  count cannot have moved on a host that skips nothing.
- **The summary survives `tail -1`.** The sentence prints first and the counts
  second (`:1265-1270`), so the last line is the counts, which is what
  `tests/run-tests.sh:1086-1087` records. The block is identical in shape to the
  dispatch gate's (`tests/lifecycle-dispatch-tests.sh:1211-1216`), which is the
  executable precedent the round was told to follow.
- **Exit semantics are unchanged.** `(( FAIL == 0 )) || exit 1` (`:1271`) is
  untouched: a skip is visible, counted, and still not a failure. That is the
  intended reading — the fix was to N3's *invisibility*, not to what the gate
  decides — and it means a host missing `timeout(1)` still produces a green
  readiness gate with the skip legible in the text. The half that would change a
  verdict lives in the aggregator and is registered (R8, F2).
- `tests/run-tests.sh` is consistent with having been left alone: its readiness
  block (`:1084-1094`) is the same shape as the other four aggregation blocks.

### 4.4 New regressions in previously-green paths

None found. In addition to the record-integrity argument in §2:

- The heartbeat arm is entered only for `kind == "heartbeat"` (`:650`) and
  returns before the retention path (`:664`, `:670`), so `worker_done` and
  `escalation` records cannot be touched by the edited expression. The replay
  guard (`:639-647`) runs before the `case`, so a duplicated heartbeat is still
  dropped without a second refresh.
- A heartbeat that arrives after the record is already `MONITOR_DEGRADED`
  refreshes the deadline without clearing `state` or `fault`. That is the
  confirmed "recovered heartbeat stays degraded" disposition, and the delta
  preserves it — the arm sets three fields and none of them is `state`.
- `afk_monitor_records` (`:312-315`) and the shellcheck file list
  (`tests/run-tests.sh:126-138`) are unchanged by the delta; the list covers
  `lib/afk-monitor.sh`, which is the only product file the round touched.
- The stray `lib/afk-monitor.sh.t1a` the worker flagged for the coordinator is
  gone from the worktree.

---

## 5. Does the "PR-triage round 1" record match the code?

Yes, with R4 as the single qualification. Checked claim by claim:

| Claim (`AFK-PORT-1.3.md`) | Verdict |
|---|---|
| `:239-246` the pre-delta defect and its two harm directions | Consistent with both products as I read them; `T1b` decides it by running |
| `:247-252` the record carries the window, the refresh falls back only when it carries no number | True — `:546-547`, `:657-658` |
| `:253-257` the zero case preserved on both paths, expiry semantics untouched, no vocabulary added | Vocabulary and sweep untouched (`:771-783`, no new reason code); the zero claim is R4 |
| `:258-270` what the two scenarios assert, and why the fixture cannot go vacuous | True — `tests/lifecycle-dispatch-tests.sh:483-520` |
| `:271-278` anti-vacuity: two assertions fail pre-triage, the control passes on both | Consistent by reading; unexecuted by anyone so far (`T1b`) |
| `:283-295` T2's shape, two skip sites, no check changed | True — `:53`, `:149-153`, `:712-725`, `:1265-1270` |
| `:296-298` `run-tests.sh` not touched | Consistent: its readiness block matches the other four; I could not diff without a shell |
| `:299-306` T2 anti-vacuity stated as a reporting change | Honest, and the right form for a change no assertion flips |
| `:310-314` gates not executed in that session | Matches the constraint I am under too |
| `:322-326` `DEFAULT_HB` comes from the sourced library, so an exported default agrees in both processes | True — the suite sources the library (`:73`), and `run_afk` uses `env` without `-i`, so an exported value reaches the child as well |
| `:330-336` the stray `.t1a` file | Real, and already cleaned up |
| `:345-354` diff size, 4 files, ~75 reviewable lines | Consistent with what I read |

---

## 6. What I did not get to, plainly

- **I executed nothing.** No gate, no script, no output. This session has
  Read/Glob/Grep/Write and no shell, and the review-only contract forbids
  modifying anything in any case. The frontmatter gates
  (`bash tests/lifecycle-tests.sh`, `bash tests/run-tests.sh`,
  `git diff --check`) were **not run by me**; the coordinator's independent run
  is the arbiter. The only gate-adjacent thing available from here was reading
  the changed regions for trailing whitespace, which is not the same as having
  run `git diff --check`.
- **The three scripts are unexecuted and were written blind.** They support
  register entries, not blockers. `T1b` is the one I would run first: it is the
  only thing that turns the record's anti-vacuity paragraph from a reading into
  a result, and it needs nothing but the two revisions.
- **I did not diff the delta mechanically.** With no shell I could not run
  `git diff cfcf9b5..7d126fc`; I reconstructed the pre-state from the triage
  brief, the worker's record and the current source. Every claim in §4 about
  *what the code does now* is from the source; claims about *what it did before*
  are reconstruction, and are marked as such where they carry weight (R1, §4.2).
- **I did not re-run or re-derive the oracles.** A3, P1 and P2 were taken as
  established per the brief.
- **Delta scope respected, so:** the cleanup arm, the settlement path, the
  readiness library, `lib/afk-plan.sh`, `lib/afk-mutate.sh`, the 1.2 surface and
  the mutation/concurrency gates were not reviewed. I read
  `afk_monitor_cleanup_record` and `afk_monitor_summarize` only far enough to
  establish that neither drops the new field. A regression the delta smuggled
  under one of those would not have been seen — though the delta touches ten
  lines of one function and one field of one record, which bounds that risk
  about as tightly as it can be bounded.
- **No shellcheck.** The delta introduces no new shell variable in the library
  (the change is inside two jq programs plus one record field); the gate's file
  list covers `lib/afk-monitor.sh` and does not cover the test suites, which is
  pre-existing.
- **I did not judge packaging or the freeze revision.** Both are the
  coordinator's.

---

## Dev Agent Record (this review session)

The review-only contract forbids modifying any existing file, including the
story file, so this section stands in for a Dev Agent Record entry there; the
coordinator may transcribe it. This follows the precedent set by
`evidence/AFK-PORT-1.3-FINAL-REVIEW.md:362-366`.

- **Session:** fresh reviewer, Read/Glob/Grep/Write, no shell, no Edit. Nothing
  in the delta was written by me.
- **Read:** the review brief; `AFK-PORT-1.3-TRIAGE1.md`; the "PR-triage round 1"
  record and the residual registries in `AFK-PORT-1.3.md`;
  `lib/afk-monitor.sh` (configuration block, `afk_monitor_records`,
  `afk_monitor_record_read`/`_write`, `afk_monitor_now`, `afk_monitor_fault`,
  `afk_monitor_register`, `afk_monitor_reconcile_delivery`,
  `afk_monitor_watch_sweep`, `afk_monitor_reconcile`,
  `afk_monitor_cleanup_record`, `afk_monitor_summarize`, and a whole-file sweep
  for every heartbeat reference); `bin/agent-flow-kit` (the declared environment
  and the option boundary); `tests/lifecycle-dispatch-tests.sh` (header,
  helpers, the Orca stub, section 4 in full, the summary block);
  `tests/lifecycle-readiness-tests.sh` (header, counters, both skip sites, the
  summary block); `tests/run-tests.sh` (the shellcheck list, all five
  aggregation blocks, its own summary); `evidence/AFK-PORT-1.3-FINAL-REVIEW.md`
  for house form.
- **Written (new files only):** this report, and three scripts under
  `evidence/AFK-PORT-1.3-TRIAGE1-REVIEW-attack/` —
  `T1a-window-class-matrix.sh` (the window input class through the real cli, plus
  the operator-knob asymmetry; evidence for R1–R3),
  `T1b-antivacuity-two-trees.sh` (the shipped scenarios against the pre-triage
  library, plus the `0`-window divergence; evidence for §4.2 and R1),
  `T2-skip-summary.sh` (the shipped summary blocks replayed, plus the readiness
  gate on a host with no `timeout(1)`; evidence for §4.3 and R8). All three are
  read-only against the checkout, build their world under `mktemp`, and carry
  controls that make an inconclusive verdict distinguishable from a real one.
- **Gates:** not run — no shell in this session; see §6.
- **Verdict:** CLEAN. 0 blockers, 8 non-blocking entries (R1–R3 delta-scoped,
  R4 a record qualification, R5 coverage, R6–R8 pre-existing or out of scope).

---

## Coordinator verification (PM, appended after executing the three scripts)

- **T1b (anti-vacuity, two trees): HELD** — the `heartbeat-window` regression
  fails on the pre-fix tree for exactly the stated reason; the legacy control
  passes on both trees; the pre-existing expiry scenario is unaffected.
- **T1a (window-class matrix): HELD with one divergence, failing LOUD** — a
  malformed global `AFK_MONITOR_HEARTBEAT_SECONDS` stops the refresh with
  exit 2 and the delivery retained in the inbox even for a record that
  declared its own window, because the jq fallback argument is evaluated
  whether or not it is used. No silent wrong deadline exists. **Register
  amendment:** the affected entry (R2 class) now reads "a misconfigured
  global blocks the refresh loudly for ALL records, own-window included; one
  line of reuse from the registration resolution closes it" — registered,
  not fixed, below the bar (operator misconfiguration; loud and recoverable).
- **T2 (skip summary): HELD** — the counted skip reaches the aggregator's
  last line, the summary is byte-identical when nothing skips, and a skip
  changes no verdict; run-tests' own aggregate skip count remains registered
  as F2 (out of scope this round, see R8).

Verdict **CLEAN stands with runs behind it.** Script outputs retained in the
session scratchpad; verdicts summarized here.
