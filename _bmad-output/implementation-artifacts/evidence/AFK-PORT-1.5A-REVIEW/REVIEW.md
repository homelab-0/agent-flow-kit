# AFK-PORT-1.5A REVIEW: CLEAN

Adversarial + senior review of Story 1.5 lane A, branch
`jlengelbrecht/afk-port-1.5a` (`3b588c9` implementation, `daa00e9` record)
against `master`, in the lane A worktree. Fresh session; I did not write this
code.

Persona proof (BMAD dev, outer hash):
`07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee` — matched
the expected value before any review work started.

**No blocker.** Nothing I reproduced clears the frozen bar — a violation of a
frozen requirement or a story AC, reproduced, reachable by natural occurrence
or one ordinary operator action. Nine residuals follow, ranked; the first two
are worth fixing before lanes B and C build on this surface, and I say for each
one exactly why it stopped short of blocking rather than leaving that implicit.

The change is, in the main, unusually well grounded. The window really is read
from the catalog and nowhere else, the estimate really is deterministic and
enumerated, the thresholds really do live only in the policy document, the
refusal really does come before every external effect, and both frozen launch
texts really are byte-identical. I proved each of those independently rather
than reading the suite's word for it.

Scripts and raw output: this directory (`attack-01` … `attack-10`), all
self-contained and re-runnable, each with a control that would fail if the
probe stopped measuring anything. Where a first pass of one of my own scripts
was wrong I say so rather than quietly deleting it.

---

## Blockers

None.

---

## Residuals

### R1 — the story-record append is an unlocked read-modify-write. Severity: high. Fix now.

`record_sizing_risk` (`files/model-router/scripts/dispatch.sh:721`) rewrites the
whole story: awk to a temp file, then `cat "$tmp" > "$story"` to preserve the
inode. There is no lock, and `dispatch.sh` has no single-instance guard of any
kind — `grep -nE 'flock|lockfile|\.lock' files/model-router/scripts/dispatch.sh`
returns nothing. Two dispatches of the same story that reach the risk band
together interleave: one truncates while the other is still reading.

Reproduction — `attack-05b-record-race.sh`, with a serial control that passes:

```
  PASS 5b CONTROL: serial calls give one line per distinct cycle
  PASS 5b CONTROL: serial calls preserve the body
     (info) 2-way concurrent cycles, 30 trials: lost-update in 29, story CONTENT damaged in 3
     (info) 8-way concurrent cycles, 30 trials: lost-update in 30, story CONTENT damaged in 15
```

The last 8-way trial left the story file **empty**. Lost findings are the mild
outcome; losing the frontmatter and the body is the real one, and this change is
the first thing in `dispatch.sh` that writes to the story file at all — before
it the launcher only ever read one.

Why this is not a blocker: no AC names atomicity, AC-5's idempotence holds under
serial execution (proved exhaustively in `attack-05-record-append.sh`), and the
collision window is roughly a millisecond inside a multi-second dispatch, so it
needs two launches fired at the same instant rather than one ordinary operator
action. What would move it over the line: any orchestration path that retries a
dispatch without first confirming the previous one is dead.

Minimal fix: take an exclusive lock around the read-modify-write, e.g.
`exec {lk}<"$story"; flock -x "$lk"` before the `grep`/`awk` and release after
the `cat`. That keeps the inode-preserving write and costs four lines.

### R2 — `payload_refs` escapes the worktree with `../`, and the contract implies it cannot. Severity: medium. Fix now.

`budget_payload_paths` resolves each entry as `realpath "$PWD/$ref"` and then
tests only `-f` and `-r` (`dispatch.sh:666`). Nothing constrains the result to
`$PWD`. A story declaring `payload_refs: [../outside.txt]` dispatches happily and
counts a file the sandboxed worker cannot read.

Reproduction — `attack-04-payload-and-window.sh`:

```
     (info) ../outside.txt: exit=0 estimate=1160 (baseline story ~153)
  FAIL 4: a payload_ref that ESCAPES the worktree is counted, not refused
```

The estimate went from 153 to 1160 tokens, so the out-of-tree 4000-byte file was
counted in full. Absolute paths, directories, dangling names and dangling
symlinks all refuse correctly — `..` is the one hole.

Three statements are affected. The refusal message itself says the entry "is not
a readable file under $PWD", which is the predicate the accept path does not
actually apply. The code comment above the function says an entry that does not
resolve "THERE" refuses. The Dev Agent Record says "a path the worker could not
read is not a path the estimate counts", which is the claim this disproves. The
contract's own wording — "repo-relative to the worktree that bounds the worker's
sandbox" — describes the base rather than promising containment, which is why I
call this a doc-implication defect and not a clean AC-8 violation.

Reachable by one ordinary operator action: writing `../shared/template.md` in a
story is a normal thing for a person to try. It stayed a residual because the
consequence is a wrong estimate and a misleading sentence, not a contract or
safety break, and because the estimate is advisory by design.

Minimal fix: `main()` already has exactly the right idiom for this, applied to
`$STORY` at `dispatch.sh:821` —

```bash
case "$rp" in "$(realpath "$PWD")"/*) ;; *) die "PAYLOAD_REF_MISSING: ..." ;; esac
```

Reusing it in `budget_payload_paths` makes the message true and the two
containment rules the same rule.

### R3 — `SIZING_REFUSED` is a declared reason code that no artifact ever carries, and the omission is not disclosed. Severity: medium. Fix now.

The policy document declares `SIZING_REFUSED` as a stable reason code and the
contract republishes it. In the launcher the string exists only inside the shell
variable name `EX_SIZING_REFUSED` (`dispatch.sh:58`, `dispatch.sh:992`). The
refusal writes a marker typed `STORY-SIZING:` and exits 8; the code itself
reaches no marker, no result and no log line.

Reproduction — `attack-08-docs-truth.sh`:

```
     (info) SIZING_REFUSED occurrences in dispatch.sh: 2
     (info) 58:readonly EX_SIZING_REFUSED=8|992:      exit "$EX_SIZING_REFUSED"|
  FAIL 8: SIZING_REFUSED is a DECLARED reason code that no artifact ever carries
```

So automation that was told to read stable reason codes has to parse the exit
code or the marker prefix instead, which is the coupling the reason-code
discipline exists to avoid. The Dev Agent Record carefully discloses
`CHECKPOINT_DUE` and `CONTINUATION_REQUIRED` as declared-never-produced because
they belong to later lanes; `SIZING_REFUSED` belongs to THIS lane and its
absence is not disclosed anywhere.

Not a blocker: AC-4 asks for exit 8 and a `STORY-SIZING:` marker and gets both,
and no AC requires the code in the artifact.

Minimal fix: add `reason=SIZING_REFUSED` to the marker's first line. One word,
and the declaration becomes true.

### R4 — a fenced `## ` line inside the Dev Agent Record ends the section scan early. Severity: low. Backlog.

The awk in `record_sizing_risk` treats any line matching `^## ` as the next
heading, including one inside a fenced code block. The finding is then inserted
mid-section instead of at the end, which is only a placement wobble — no content
is lost and idempotence still holds.

Reproduction — `attack-05-record-append.sh`:

```
     (info) fenced-heading case: budget line 10, fenced ## line 12
  FAIL 5f: a '## ' line inside a code fence is treated as the next heading
```

Not triggered by this story's own record, whose fenced blocks contain no `## `
line. Worth fixing whenever the append is touched for R1; not worth a commit of
its own.

Everything else about the append is right, and I tried hard to break it: inode
preserved, permissions preserved (`0640` survived), frontmatter and the gates
list byte-identical, insertion at the end of the section and before the next
heading, a missing heading created rather than the finding dropped, a file with
no trailing newline handled, `cycle 1` not confused with `cycle 10`, and three
re-runs of one cycle leaving one line.

### R5 — the policy document is validated by shape, not by value. Severity: low. Backlog.

`budget_policy_missing_keys` checks that `continuation_cap` is present but never
that it is a number, and checks `budget_states` only by count (`== 4`) and
`reason_codes` only by count (`>= 5`). Probes in
`attack-02-refusal-ordering.sh`:

```
     (probe) continuation_cap: banana     exit=0
     (probe) budget_states renamed x4     exit=0
```

A policy declaring `continuation_cap: banana` loads cleanly and lane C inherits
it. Renaming a state to `BANANA` passes dispatch and is caught only later, by
the readiness suite's equality assertion against the schema verb. The Dev Agent
Record says the cap is "validated as present and well-formed" — present, yes;
well-formed, no. That sentence should either be corrected or the check tightened;
I would tighten the check, since the record's reasoning for validating it early
(lane B inherits a policy already proved loadable) is the right instinct.

Thresholds are also not checked for ordering. I probed
`sizing_risk_ratio: 0.90` with `continuation_ratio: 0.10` and dispatch accepted
it. The resulting behaviour is still fail-closed — the refusal is evaluated
first, so an inverted policy refuses more, never less — so I would leave this as
documented rather than add a rule.

### R6 — the risk line is written before the stamp is validated. Severity: low. Accept.

`attack-10-residue.sh` drives the validator to reject the stamp and the story
still carries a budget line:

```
     (info) stamp-invalid dispatch exit=4
  FAIL 10: a SIZING_RISK line is written into the story even though the launch was REFUSED at stamp validation
        - budget: SIZING_RISK 152/217 (0.700460) cycle 1 ...
```

I called this a FAIL in the script and then talked myself out of it: the sizing
observation is true of the story whether or not the launch proceeded, and the
ordering is a direct consequence of the deliberate, correct decision to size
before consuming a placement or a validation. Worth one sentence in the contract
so nobody reads a budget line as evidence that a worker ran.

### R7 — the refusal leaves the generated prompt file behind. Severity: low. Accept.

```
     (info) the refusal leaves a generated prompt file behind (530 bytes)
```

The marker's claim is "no command text was built", which is true; the prompt
file is not command text and it is needed to compute the estimate in the first
place. Harmless, and the stale `.blocked` marker IS cleared by a later
successful dispatch (asserted in `attack-10`). Noted only so a later reader is
not surprised by the file.

### R8 — the SKILL's `payload_refs` example names a path that does not exist. Severity: low. Backlog.

`files/model-router/SKILL.md` illustrates the key with
`contracts/agent-router/HARNESS-LAUNCH-claude.md`, which exists nowhere in the
repo. The surrounding frontmatter block is equally illustrative
(`STORY-041-3.md.stamp.json`, `pnpm test`), so this is not a false statement
about behaviour — but it is the one line in that block that looks like a real
kit path, and the same doc has just told the reader that a path which does not
exist refuses the dispatch. A clearly fictional example, or a real one, would
read better.

### R9 — `daa00e9`'s subject carries internal vocabulary. Severity: low. Fix at PR time.

"Record the commit SHA in the story's Dev Agent Record". No AI-attribution
trailers anywhere, which is right and was deliberate. The commit will be squashed
at PR time, so this costs nothing to fix then.

---

## The disclosed items in the worker's record

**The 947-line diff against the 800 budget.** I do not accept the argument that
"there is no split of this lane that leaves a lower layer meaningful on its own".
There is one, and it is the layer most worth reviewing alone: the policy document
(52), the pure arithmetic and the policy loader (~90), and the pure tests over
them (~120) — roughly 260 reviewable lines that stand up as a unit, because a
declared policy plus its parser plus boundary tests has a contract of its own and
is exactly where a subtle error would hide. The rest — dispatch integration,
integration tests and prose, ~690 lines — fits under the budget as a second
layer. The worker's premise, that a policy file with no reader is not
independently reviewable, is the wrong test: what makes a layer reviewable is
whether a human can judge it against a stated contract, not whether it is
already wired up.

That said, my recommendation is **accept the overrun for this lane**, not split
it now. The reviewable logic surface really is 301 lines; the overrun is 459
lines of tests and 185 of documentation and declared policy that S3, S5 and S6
each name explicitly; and re-cutting a finished, gate-green branch into a stack
buys a reviewer nothing they have not already been given. The worker's closing
observation is the valuable one and I would promote it from a footnote to an
action: the lane was scoped at 800 without counting the doc and test surface its
own acceptance criteria mandate. That is a planning fix for lanes B, C and D —
budget the tests and the prose when you scope the lane — not a PR-splitting fix
for this one.

**The committed gate logs.** Five files, 2136 lines of machine-generated test
output under `evidence/AFK-PORT-1.5A/`. Asked whether they belong in the code
PR: on their merits, no — nobody will read them again and the Dev Agent Record
already carries the tallies. But every prior story in this repo has committed
its evidence the same way (`evidence/AFK-PORT-1.2-*`, `-1.3-*`, `-1.4-*`), the
worker excluded them from its diff-size arithmetic and labelled them generated,
and breaking a convention unilaterally inside a story is worse than following
one. Keep them; raise the convention separately if anyone wants it changed.

**The first `run-tests.sh` run, kept as `gate-run-tests-run1-testbug.log`.**
Reporting a void run rather than deleting it is the right instinct, and the
diagnosis is correct: an AC-6 grep that forbade `/v1/route` anywhere in
`dispatch.sh` was exactly the vacuous-grep failure the suite's own `code_of`
comment warns about. I verified the replacement is stronger, not weaker — it
now checks what the code CALLS. `attack-07` reproduces that independently: the
only `curl` target in the file is `/v1/place`, `context_size` appears nowhere,
and a real `make-stamp.sh` round trip against a stub router POSTs
`["ambiguity","blast_radius","story_id","summary","tags","title","volume_hint"]`
and nothing else.

**The subshell that nearly ate the `PAYLOAD_REF_MISSING` refusal.** Disclosed,
fixed, and I confirmed the fix holds: five different malformed-ref shapes all
refuse with exit 2, no placement call, no terminal and no result.

**The deferred `budget_states` entry in `tests/lifecycle-tests.sh`.** The premise
checks out — the doc↔schema sync loop is there and simply does not list
`budget_states` yet, and the assertion went where S6 put it instead. Genuinely a
one-word follow-up.

**`checkpoint_ratio`, `continuation_cap`, `CHECKPOINT_DUE` and
`CONTINUATION_REQUIRED` declared but unused.** Correct call, correctly disclosed,
and I confirmed the launcher never produces a lane-B/C state. See R5 for the one
place the disclosure overstates what is validated.

---

## AC-by-AC coverage

| AC | Verdict | Evidence I checked myself |
|---|---|---|
| **AC-1** window from the catalog exactly; undeclared → `NOT_EVALUATED`/`CONTEXT_WINDOW_UNDECLARED`; never derived | met | `attack-04`: a stamp carrying `min_context: 999999` is ignored and the catalog's `123456` wins; `window_source` is `CATALOG` on every path; undeclared → `NOT_EVALUATED`, null window, null ratio, empty findings, dispatch proceeds, nothing appended to the story. Degenerate `min_context` (`0`, `-1`, `"0"`, `notanumber`, `0.5`) fails closed at exit 5 rather than becoming a healthy budget (`attack-03`). |
| **AC-2** estimate deterministic, documented, inputs enumerated, ratio recorded; `payload_refs` honoured; missing ref refuses | met, with R2 | `attack-04`: four equal-length fixtures isolate the payload difference — dup=1162, one-ref-plus-empty=1162, two distinct refs=2162 (+1000 tokens = exactly 4000 bytes), file+symlink-to-it=1162. Dedupe is on the resolved path. Missing ref, directory, absolute path, dangling name and dangling symlink all refuse with `PAYLOAD_REF_MISSING`, exit 2, no placement, no terminal, no result. `../` escape is R2. |
| **AC-3** policy is the only source of thresholds and method; unreadable policy refuses before anything else; no threshold is a code constant | met, with R5 | `attack-02`: missing, unparseable and empty policies all refuse at exit 2 with the stamp never opened and no placement or terminal. Twelve mutations — every missing key, non-numeric thresholds, `.85`, `85%`, an undeclared method, short `budget_states`, short `reason_codes` — every one refused; none reached a launch. `attack-07`: no decimal or ppm threshold constant survives comment-stripping in `dispatch.sh`. |
| **AC-4** refusal at ≥ continuation: exit 8, `STORY-SIZING:` marker, before `/v1/place`, nothing created | met | `attack-02` on the `placement_required` profile, which is the case that would expose a mis-ordering: exit 8, typed marker naming estimate/window/ratio/threshold/inputs, empty curl log, empty terminal log, no command text, no result — and the stamp validator never invoked at all. A control run first proves the same fixture does call `/v1/place` when it is not refused. |
| **AC-5** risk band proceeds; finding in result and story record; idempotent | met, with R1 and R4 | `attack-06` drives the estimate to exactly 600000, 700000 and 850000 tokens against a 1000000-token window, so the ratio lands on the ppm boundary rather than near it: 0.850000 refuses, 0.849999 does not and is still `SIZING_RISK`, 0.600000 fires the finding, 0.599999 fires nothing and appends nothing. `attack-05` covers placement, ordering, inode, permissions, frontmatter, EOF and cycle keying. |
| **AC-6** route requests unchanged: no `context_size`, no capacity input | met | `attack-07`: `make-stamp.sh` and the stamp schema untouched by the diff; `context_size` absent from `dispatch.sh` entirely; the only `curl` target is `/v1/place`; and a real `make-stamp.sh` round trip against a stub router POSTs seven keys, none matching `context|window|budget|capacity|token|size`. |
| **AC-7** both launch classes and both harnesses; launch texts byte-identical | met | `attack-01`: master's builders and HEAD's sourced in separate shells and compared across all four efforts for all three classes — 24 comparisons, all identical, against both `master` and the branch base. Three controls prove the comparison can see a difference (perturbed effort, perturbed model, perturbed gateway window). `dispatch.sh` has zero deleted lines. `attack-04` confirms `CLAUDE_CODE_MAX_CONTEXT_TOKENS=65536` is still the catalog's and that neither "estimate" nor "SIZING" appears in the launch text. Codex exercised in `attack-03`/`attack-04` fixtures. |
| **AC-8** contract, schema and skill doc true of the code | met, with R3 and R8 | `attack-08`: the contract's machine-checkable block, the `schema` verb in `lib/afk-commands.sh` and the policy document declare the same four states, and the LIVE `agent-flow-kit schema` output agrees. The documented `budget` member keys are exactly the eight the launcher emits. Every band, the exit code, the ordering claim and the marker contents check out. `SIZING_REFUSED` is R3; the example path is R8. |
| **AC-9** four gates green (concurrency aggregate the only tolerated red); diff ≤ 800 lines / ≤ 25 files; record complete | met on files, over on lines (disclosed), gates below | `attack-09`: reviewable diff is `+947 / -3` across 7 files, which matches the record's own figures exactly; nothing outside the declared surface; no AI-attribution trailers in either commit; `git diff --check` clean on both the branch range and the working tree. My assessment of the overrun is above. |

**Suite oracle, judged rather than assumed.** The byte-identity block the worker
moved from evidence into `tests/run-tests.sh` is non-vacuous: it fails loudly if
master's builder produces nothing, it carries a perturbed-effort control, and it
reports SKIP rather than PASS when there is no `master` ref. It compares against
`master`, which still holds the pre-change `dispatch.sh` (`git diff 39fd66c
master -- files/model-router/scripts/dispatch.sh` is empty), so the comparison is
meaningful today. It is worth knowing that this oracle silently weakens the day
`master` gains the change it is comparing against — after this branch merges, the
block compares the file to itself and passes for free. That is not a defect in
this PR; it is a property of the oracle that whoever merges it should be aware of.

---

## Gates

| Gate | Result | Wall time | Whose run |
|---|---|---|---|
| `git diff --check` (branch range and working tree) | **clean, exit 0** | — | mine, `attack-09` |
| `bash tests/lifecycle-readiness-tests.sh` | **281 passed, 0 failed** | ~5m | the coordinator's chain in this worktree at this HEAD, log read not re-run |
| `bash tests/lifecycle-tests.sh` | **476 passed, 0 failed** | ~8m | same |
| `bash tests/run-tests.sh` | not read — still in flight during this review | — | the coordinator's; I did not touch it |
| my own attack scripts (11 files) | **239 passed, 10 failed** | ~30m total | mine |

**Why I did not run the two suite gates myself.** The coordinator's gate chain
was executing `tests/run-tests.sh` in this worktree throughout the review, and
it had not yet reached section 8, the lifecycle concurrency gate — the suite
whose three known reds are timing-sensitive. Running two more suites in parallel
would have added CPU load to a timing-sensitive authoritative run for no
information: both suites are inside that same chain, at this same HEAD, and both
had already completed green in it. I read their tallies and attribute them to
the coordinator's run rather than claim them as mine. If an independent re-run
is wanted, it should happen after the chain settles and it is a two-command job.

**The ten failures in my own scripts**, so none of them is mistaken for an
extra finding. Seven are real and are already reported above: R1 twice (the
2-way and the 8-way race), R2 twice (the escape itself in `attack-04` and the
contract wording it contradicts in `attack-08`), R3, R4, and R6 — which I
argued myself out of after writing it. The other three are artefacts of my own
fixtures, kept rather than deleted because a reviewer's scripts should show
their working: two in `attack-03`, where the fixture story was small enough
(152 tokens) that one token of window moves the ratio by nearly 0.005, so it
can approach a ppm boundary but never land on it; and one in `attack-06`, where
later probes share a fixture story that earlier probes had already appended to.
The `attack-03` artefact is precisely why `attack-06` exists: it pads the
payload until the estimate is exactly 850000, 700000 and 600000 tokens against
a 1000000-token window, which is the only way the equality case is tested
rather than approximated. A first version of the boundary probe also lived in
`attack-02` and was wrong in a worse way — it applied one story's estimate to a
different story on a different profile — so that block now says so and points
at `attack-06` instead of pretending it never happened.

Raw output for every script is committed alongside it as `raw-<script>.log`.

---

## Dev Agent Record

Reviewer: fresh claude session under Orca supervision, lane A worktree
`afk-port-1.5a` at `daa00e9`. Route/stamp `{claude, claude/strong, effort
medium}`, stamp
`_bmad-output/implementation-artifacts/AFK-PORT-1.5A-REVIEW.md.stamp.json`,
digest
`sha256:90f61f6c657c7aeee0487ec8d0cab2bca8e6dfb5c0a30b8e1f0a0a85c931f2b5`,
validated fail-closed by the coordinator before launch. Persona proof computed
first and matched.

Review-only, as instructed. I modified no product code, no test, no doc, no
story record and no git state. One note on that: the review story
`AFK-PORT-1.5A-REVIEW.md` carries its own `## Dev Agent Record (reviewer fills
in)` section, and the dispatch brief says to write `REVIEW.md` plus attack
scripts and change nothing else. I followed the brief and put this record here
instead of editing that file; say the word if you would rather it were stamped
into the review story too.

 `git status --porcelain` shows nothing outside
this directory. I did not run `tests/run-tests.sh`. Scratch copies of the
launcher and every fixture worktree live under `/tmp`; nothing under the
worktree was deleted or rewritten.

Files written, all under
`_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.5A-REVIEW/`:

| File | What it proves |
|---|---|
| `REVIEW.md` | this report |
| `attack-harness.sh` | my own stubs — worktree, catalog, Orca, validator, curl, `op` — independent of `tests/run-tests.sh`, so a bug in the story's own suite cannot hide behind it |
| `attack-01-launch-texts.sh` | 24 byte-identity comparisons across three classes and four efforts, with three controls |
| `attack-02-refusal-ordering.sh` | refusal side effects on the placement-required profile; 12 policy mutations; 5 acceptance probes |
| `attack-03-arithmetic-edges.sh` | degenerate windows, pure-function edges, a large payload |
| `attack-04-payload-and-window.sh` | `payload_refs` dedupe and refusals; window resolution; the gateway class |
| `attack-05-record-append.sh` | append placement, idempotence, inode, permissions, frontmatter, EOF |
| `attack-05b-record-race.sh` | R1, quantified over 60 trials with a serial control |
| `attack-06-exact-boundary.sh` | the ppm boundaries hit exactly, not approximately |
| `attack-07-agnostic-and-route.sh` | harness agnosticism and AC-6, including a real `make-stamp.sh` round trip |
| `attack-08-docs-truth.sh` | doc ↔ schema ↔ policy ↔ code agreement |
| `attack-09-hygiene.sh` | file surface, diff size, commit hygiene, `git diff --check`, oracle non-vacuity |
| `attack-10-residue.sh` | leftover artifacts and pre-validation record writes |
| `raw-attack-*.log` | the raw output of each script as I ran it |

Recommendation: land it. Fix R1 before lanes B and C build on the record-append
surface, and fold R2 and R3 in at the same time — together they are about a
dozen lines and they make three sentences true that are currently only nearly
true.
