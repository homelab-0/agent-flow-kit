# AFK-PORT-1.5C REVIEW: NOT CLEAN — 2 blockers

Adversarial + senior review of Story 1.5 lane C, branch
`jlengelbrecht/afk-port-1.5c` @ `88c24b6` against `master` @ `e76cb95`, in the
lane A worktree. Fresh session; I did not write this code.

Persona proof (computed first, fail-closed):
`{ sha256sum .agents/skills/bmad-agent-dev/SKILL.md; sha256sum
.agents/skills/bmad-agent-dev/customize.toml; } | sha256sum` →
`07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee`, the OUTER
hash the brief expects. Match.

Everything below was reproduced by running the real `dispatch.sh`. The attack
scripts live beside this file; `harness-lib.sh` is the section-3 stub rig
extracted verbatim from `tests/run-tests.sh` (lines 30–56 and 658–840, no
assertions, regenerable with `regen-harness.sh`), so the attacks drive the same
launcher the suite does without borrowing any of its verdicts. Every case
carries its own control. `tests/run-tests.sh` was NOT run — the coordinator's
chain owns it in this worktree. Nothing outside this directory was modified.

The engineering in this lane is strong. The launch path really is untouched,
the artifact really is data, the refusal markers really do say what would
unblock them, and the record chain survives thirty concurrent writers. Both
blockers are in one place: the cap is the one control in this lane that a human
is supposed to be unable to walk past, and it can be walked past.

---

## Blockers

### B1 — the cap gate is unreachable at the shipped defaults, and the marker's own remedy does not unblock the cycle

**AC / requirement.** AC-3 (`third continuation refuses without, proceeds with, a
recorded PM decision`); S3 (`the exact frontmatter shape to add`); FR-103.

**Reproduction** (`attack-03-cap-vs-maxcycles-and-agnosticism.sh`, section A;
log `attack-03.log`).

`continuation_cap: 2`, so the cycle the cap is about is cycle 4. `MAX_CYCLES`
defaults to `3` (`dispatch.sh:1317`) and is checked at `dispatch.sh:1331` —
**before** continuation detection and the cap gate at `dispatch.sh:1392–1447`.
On a story that declares no `max_cycles` (or the `max_cycles: 3` that this
lane's own story files use):

```
  [default max_cycles] exit=3
  stderr: dispatch: max_cycles (3) exceeded — escalate to human
  FAIL the cap gate is REACHED at the shipped default max_cycles
        refused earlier by max_cycles; no CONTINUATION-CAP marker was written
```

The story is refused with an untyped message, no `.blocked` marker, no
`CONTINUATION_CAP_REACHED`, no count, no cap, and no frontmatter shape. Then the
second half of AC-3 fails outright: adding the `continuation_decision:` block
**exactly as the marker prints it** does not let the authorised cycle proceed.

```
  FAIL the marker's remedy, applied verbatim, lets the authorised cycle proceed
        expected '0', got '3'
  stderr: dispatch: max_cycles (3) exceeded — escalate to human
  PASS control: the SAME story with max_cycles: 9 proceeds
```

The control is the load-bearing half: the identical story, identical decision
block, `max_cycles: 9` — exit 0. So the authorisation mechanism works; it is
simply unreachable behind a limit nobody is told about. `max_cycles` appears
nowhere in the marker, nowhere in the new `### Continuation cycles, the cap, and
the decision key` contract section, and nowhere in the SKILL paragraph
(`attack-03.log`, "no mention anywhere"). Section 3e never sees it: every
`cont_story` fixture is written with `max_cycles: 8` (`tests/run-tests.sh:2155`).

**Reachability.** Natural occurrence. Any story that hands over twice under the
shipped defaults. The refusal a human then gets is the pre-existing max_cycles
message, and the one documented remedy for it does not work.

**Minimal fix.** Make the cap marker's frontmatter block also carry the
`max_cycles:` the authorised cycle needs, and say so in the contract and SKILL
paragraphs; or run the cap gate before the `max_cycles` check so the typed
refusal is the one a capped story gets. The marker text is the smaller change
and stays inside this lane's surface.

### B2 — the cap is not enforced: re-dispatching a cycle number both grants extra continuations and deflates the count

**AC / requirement.** AC-3 (`cap enforced deterministically from retained
per-cycle results`); S3 (`exactly continuation_cap continuations proceed; the
next refuses`); FR-103.

**Reproduction** (`attack-05-cap-bypass.sh`; log `attack-05.log`). A story that
has just been refused at the cap for cycle 4:

```
A. the cap fires at cycle 4 (baseline)
  PASS cycle 4 is refused at the cap
  PASS with the typed marker
B. the operator now re-dispatches the PREVIOUS cycle number instead
  exit=0  terminals launched=1
  FAIL a story refused at the cap cannot get another window by re-running an earlier cycle number
        cycle 3 re-dispatched as a continuation and LAUNCHED, with no recorded decision
  continuation_of: {"cycle":2,...,"trigger":"WORKER_SIGNAL",...}
  findings:        ["REPEATED_CONTINUATION"]
  decision:        null
  --- and it can be repeated indefinitely ---
    repeat 1: exit=0   repeat 2: exit=0   repeat 3: exit=0
C. CONTROL — the cap still holds for the cycle it was computed for
  FAIL control: cycle 4 is still refused   expected '3', got '0'
  FAIL control: cycle 5 is refused too     expected '3', got '0'
```

Two distinct defects, one root cause — `continuations_consumed`
(`dispatch.sh:1058–1069`) counts only cycles **strictly below** the cycle being
run, and only those whose retained result is `continuation_required` **and**
carries `budget.continuation_of`:

1. *Bypass.* `dispatch.sh <story> 3` after the cap refused cycle 4 is a full
   continuation: placement, revalidation, launch guard, launch, a real window —
   counted against nothing, authorised by nothing. Unbounded.
2. *Deflation.* That re-run overwrites `<story>.result.c3.json`. Its new status
   is `done`, which the predicate does not count, so the consumed count drops
   from 2 to 1 — and cycle 4, refused a moment earlier, now proceeds with no
   decision at all (section C). A cycle that consumed a hand-over erases the
   fact that it consumed one as soon as it is re-run.

**Reachability.** One ordinary operator action, and one the launcher's own
refusal marker instructs: `refuse_continuation_stamp` ends with "re-dispatch
this same cycle" (`dispatch.sh:1179`). Re-dispatching a cycle number is the
documented recovery from a stamp refresh, a dead terminal, or a flaked gate —
and on any cycle that had handed over it silently returns a continuation to the
story's budget. Nothing in the result, the marker or the story record says the
count moved.

**Minimal fix.** Count over **every** retained cycle, not only those below the
current one, and predicate on `budget.continuation_of != null` alone — a cycle
that consumed a hand-over consumed one whether or not it handed over again, and
whether or not it is being re-run. (A re-dispatch of a capped cycle then needs
the same recorded decision every other capped cycle needs, which is the
behaviour S3 describes.) The disclosed reasoning in the Dev Agent Record for the
two-member predicate is sound for the *first* cycle's hand-over — that case is
handled by cycle 1 never carrying `continuation_of`, so dropping the status
conjunct does not reintroduce the early-fire it was defending against.

---

## Residuals

- **R1 — `continuation_decision.cycle` must be a JSON number.** `select(.cycle ==
  $c)` (`dispatch.sh:1091`) compares against `--argjson`, so a PM who writes
  `cycle: "4"` gets a silent non-authorisation with no diagnostic — the same
  refusal as no decision at all. *Recommendation:* accept `(.cycle|tonumber?)`,
  or say "unquoted" in the marker. Low severity; the marker's own example is
  unquoted.
- **R2 — nothing binds a continuation artifact to its story.** The artifact is
  found by path (`${STORY}.continuation.json`) and validated against
  `afk-continuation/1`, which carries no story identity. An artifact copied from
  another story into this path is consumed as this story's hand-over. Needs a
  deliberate copy, so it is below the bar; it is worth a member in the schema
  when lane D touches it.
- **R3 — a continuation refused by sizing leaves no `CONTINUATION` record line.**
  The append is deliberately after the estimate (`dispatch.sh:1550–1561`), so a
  refusal at `EX_SIZING_REFUSED` writes the marker but nothing in the story
  record. The reasoning (a deterministic re-dispatch estimate) is right and I
  would keep it; the PM reading only the record will not see that a continuation
  was attempted. Note it for lane D.
- **R4 — the retained series is unbounded.** Agreed with the worker's disclosure:
  pruning would make the cap countable-from-nothing. With B2's fix the series
  becomes load-bearing for correctness, not just for reading, which strengthens
  the case for leaving it unpruned.

### On each item the worker disclosed

- **Estimate counted through the prompt, not enumerated twice** — agreed, and
  verified rather than taken on trust: the continuation estimate exceeds the
  ordinary one by at least the artifact's bytes/4, an 800 KB artifact trips the
  refusal on lane A's unchanged path at `EX_SIZING_REFUSED` (8), and the marker
  names the artifact as an `of which` sub-line (`attack-02.log`, section B).
  S1(a) is satisfied.
- **Refusal ordering** — verified: on a cap refusal and on an invalid-artifact
  refusal nothing is placed, validated, launched, and no result is written
  (`attack-02.log` C and D). Correct, and the right place for it.
- **No new exit codes** — agreed. Reusing `EX_NEEDS_HUMAN` for both pre-launch
  refusals and leaving the validator's own 4/5 alone keeps whose refusal it was
  visible.
- **The cap predicate ("a reading rather than a transcription")** — this is the
  one I disagree with, and it is B2. The defence of not counting cycle 1's
  hand-over is right; the `status` conjunct is not what achieves it.
- **Record-append idempotence keyed on (code, cycle)** — verified under real
  contention: 30 concurrent appends, exactly one line, story uncorrupted,
  frontmatter still parses, and both controls (different cycle, different code)
  append (`attack-04.log` A).
- **`lib/afk-monitor.sh` byte-identical** — verified, and the suite's assertion
  is non-vacuous: it detects a one-line mutation and fails closed when the master
  side is unreadable (`attack-04.log` B).
- **`continuation_decision` not validated against a person** — agreed. Recording
  the claim is the honest thing; the kit has no identity authority.
- **AC numbering (brief says 1–9, story declares 1–8)** — the brief's nine items
  are attack areas, not ACs. Flagging rather than reconciling was right; nothing
  is missing.

---

## AC-by-AC coverage

| AC | verdict | evidence checked |
|---|---|---|
| AC-1 continuation consumes artifact into prompt and estimate, records `continuation_of` | **PASS** | `attack-02.log` B: fixed heading `Continuation from cycle 1`, artifact content in the prompt, heading ordered before the budget paragraph, `continuation_of` carries cycle/sha/trigger/usage, estimate delta ≥ bytes/4, 800 KB artifact refuses at exit 8 with the `of which` sub-line; `attack-03.log` C: content reaches the prompt and nothing else — no shell execution, not in the command text, the result, the record line or stderr |
| AC-2 same stamp, revalidated; expired → refusal naming the refresh path; never a local substitute | **PASS** | `attack-02.log` F: exit 4 (the validator's own), `CONTINUATION-STAMP:` marker with `reason=CONTINUATION_STAMP_REFRESH_REQUIRED` and `validator_reason=stamp_expired`, names `/v1/route` and `make-stamp.sh`, stamp byte-identical afterwards, nothing launched, no result; controls: the same cycle launches on a valid stamp, an ordinary cycle gets no continuation marker. `attack-01.log`: no route field assigned in added code |
| AC-3 cap enforced deterministically; third refuses without / proceeds with a decision | **FAIL — B1, B2** | `attack-02.log` D proves the happy path (2 proceed, 3rd refuses with the typed marker, a right-cycle decision authorises, a wrong-cycle or malformed one does not, another story's chain is irrelevant). `attack-03.log` A and `attack-05.log` prove it is unreachable at the shipped defaults and bypassable/deflatable by re-dispatching a cycle number |
| AC-4 `REPEATED_CONTINUATION` on every continuation | **PASS** | `attack-02.log` B and D (authorised cycle included); `attack-03.log` B (codex) |
| AC-5 record chain present and idempotent | **PASS** | `attack-02.log` B (line carries trigger, usage and sha) and G (re-dispatch of the same cycle adds nothing, a new continuation cycle does); `attack-04.log` A (30-way race) |
| AC-6 settlement through the unmodified 1.3 contracts | **PASS** | `attack-04.log` B (`lib/afk-monitor.sh` byte-identical, assertion non-vacuous, fails closed); `attack-06.log` (a continuation cycle's thin result is the ordinary shape, the monitor's own bounding expression reads it, the retained copy is identical, a fresh Orca terminal per cycle); `tests/lifecycle-dispatch-tests.sh` 256/0 |
| AC-7 contract/schema/docs true of the code | **PASS with B1's gap** | `attack-03.log` D: all three reason codes declared in the policy, `afk-commands.sh`, the contract and the launcher; no threshold constant, no `continuation_cap` fallback, no `context_size` in the launcher. The contract's claims about ordering, the prompt heading, the estimate and settlement were each checked against behaviour, not read. The one untrue-by-omission item is B1 |
| AC-8 gates green, diff ≤ 800 lines, lane-D seams recorded | **PASS** | `attack-04.log` C: 6 files, all inside the declared surface, 701 added+changed reviewable lines, `git diff --check` clean, commit plain (no trailers, no AI attribution, no internal vocabulary); no secret material added. Lane-D seams are recorded in the Dev Agent Record and I verified the four named artefacts exist |

---

## Gates I ran, with wall times

| gate | exit | wall | tally |
|---|---|---|---|
| `bash tests/lifecycle-dispatch-tests.sh` | 0 | ~200s | 256 passed, 0 failed |
| `bash tests/lifecycle-readiness-tests.sh` |  0 | 275s | 290 passed, 0 failed |
| `git diff --check` | 0 | — | clean |
| `attack-01-launch-byte-identity.sh` | 0 | 1s | 4 builders byte-identical + 3 controls |
| `attack-02-continuation-and-cap.sh` | 0 | ~600s | 58 passed, 0 failed |
| `attack-03-cap-vs-maxcycles-and-agnosticism.sh` | 1 | ~70s | 29 passed, **3 failed** (all B1) |
| `attack-04-record-race-settlement-hygiene.sh` | 0 | ~5s | 14 passed, 0 failed |
| `attack-05-cap-bypass.sh` | 1 | ~60s | 2 passed, **3 failed** (all B2) |
| `attack-06-settlement.sh` | 0 | ~10s | 5 passed, 0 failed |

`tests/run-tests.sh` was not run: the coordinator's gate chain owns it in this
worktree. The worker's recorded aggregate (669/1, the known
publication-window concurrency triple) is unchallenged by anything I found —
nothing in this lane touches the operation lock.
