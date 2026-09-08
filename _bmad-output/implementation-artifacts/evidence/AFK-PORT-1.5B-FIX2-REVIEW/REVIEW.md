# AFK-PORT-1.5B-FIX2-REVIEW: CLEAN

Diff-scoped review of commit `ffc2b2e` on `jlengelbrecht/afk-port-1.5b-fix2b`
against `master` @ `4b873ab`. Five files, +430/-34. No blockers. Six residual
notes and one brief/record discrepancy are recorded in §3; none of them reaches
the bar (none is exploitable by a real dispatch, and none makes a published
fact wrong).

Persona proof (BMAD dev SKILL.md + customize.toml, outer):
`07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee` — matched.
Stamp `AFK-PORT-1.5B-FIX2-REVIEW.md.stamp.json`, digest
`sha256:9ba50a5dd1d591b40ee3b14b09930fc6f5a436cb0b762ab686217a2041a1b2e4`.

Every probe below was run against BOTH the source under review and a scratch
copy of `master`'s `dispatch.sh` (`/tmp/afk-rev/dispatch-master.sh`, from
`git show 4b873ab:`), so each claim has its own control. Probe scripts and raw
output are beside this file. Nothing outside this directory was written.

---

## 2. Per item

### F1 — cumulative usage is informational, never occupancy: **VERIFIED**

Probe: `probe-f1-adapter.sh` sources the chosen `dispatch.sh`, feeds three
envelopes through `harness_usage_observation` → `budget_evaluate_usage` with
the shipped 0.70/0.85 ratios and a 65,536 window, and prints the resulting
`BUDGET_*` globals. Output in `probe-f1-output.txt`:

```
### UNDER REVIEW ffc2b2e
FU.1 83-turn        | scope=CUMULATIVE_RUN ratio=null reason=USAGE_CUMULATIVE_ONLY state=NOT_EVALUATED findings=[]           tokens=1330455
same totals turns=1 | scope=FINAL_CONTEXT  ratio=20.301132 reason=null            state=CONTINUATION_REQUIRED findings=[HIGH_USAGE] tokens=1330455
num_turns absent    | scope=CUMULATIVE_RUN ratio=null reason=USAGE_CUMULATIVE_ONLY state=NOT_EVALUATED findings=[]           tokens=1330455

### CONTROL master 4b873ab
FU.1 83-turn        | scope=<unset> ratio=20.301132 state=CONTINUATION_REQUIRED findings=[HIGH_USAGE]
same totals turns=1 | scope=<unset> ratio=20.301132 state=CONTINUATION_REQUIRED findings=[HIGH_USAGE]
num_turns absent    | scope=<unset> ratio=20.301132 state=CONTINUATION_REQUIRED findings=[HIGH_USAGE]
```

- The real 83-turn fixture yields `usage_scope: CUMULATIVE_RUN`,
  `usage_ratio: null`, `usage_reason: USAGE_CUMULATIVE_ONLY`, no `HIGH_USAGE`,
  and the pre-dispatch state untouched. The cumulative figure (1,330,455 =
  194,941 input + 1,135,514 cache-read, checked against the fixture) is still
  published.
- The `HIGH_USAGE` proof the story asked for: the SAME totals with `num_turns`
  mutated to 1 do produce the ratio, the band and the finding. So the finding
  is asserted from `FINAL_CONTEXT` and from nothing else — the only thing that
  changed between those two rows is the scope.
- An envelope with no turn count fails closed to `CUMULATIVE_RUN`.
- Anti-vacuity: master reproduces the reported defect on all three rows —
  20.301132, `CONTINUATION_REQUIRED`, `HIGH_USAGE` — including on the
  single-turn row, where it is right for the wrong reason. The new assertions
  (`ratio ""`, state left at `OK`, `assert_absent HIGH_USAGE`) therefore fail
  against master's adapter. This is the unit-level equivalent of the suite's
  new block; `tests/run-tests.sh` itself was not run (coordinator's chain).
- The fixture is byte-identical to the provisioned evidence envelope
  (`sha256:79794a42…` on both `tests/fixtures/claude-result-envelope-multiturn.json`
  and `evidence/AFK-PORT-1.5B-FIX2/fu1-claude-result-envelope.json`).

### F2 — gates decide the status; a continuation needs an artifact: **VERIFIED**

Walked live from the fixed source (`probe-f2-f4-f6.txt`). `RESULT_STATUS` has
exactly three assignment sites:

```
2017:  RESULT_STATUS=""
2057:    RESULT_STATUS="continuation_required"
2104:  RESULT_STATUS="$([[ $GATES_OK == true ]] && echo 'done' || echo 'gates_failed')"
```

Site 2057 is inside the `CONTINUATION-REQUIRED:` signal branch, downstream of
`artifact_verdict == VALID`, the freshness check against `CONTINUATION_BEFORE`,
and `continuation_story_verdict` — and `BUDGET_CONTINUATION_JSON` is set from
the artifact on the line above it, so a `continuation_required` status cannot
be published without an artifact identity beside it. Every other row falls to
2104, which reads only `GATES_OK`. No `BUDGET_STATE` value reaches either.
The one arm that used to bridge them is gone:

```
gates region, RESULT_STATUS="continuation_required" assignments
  UNDER REVIEW : 0     (the new matrix test asserts 0)
  CONTROL master: 1
```

Ratio-derived states do not touch the status: the surviving band arm at 2089
only demotes `BUDGET_STATE` on a passing-gate run (lane B's F2, unchanged), and
the failing-gate arm at 2101 now logs and does nothing else. Contract table
matches — the "usage ≥ continuation_ratio, gates failed" row now reads
`status: gates_failed` with `budget.state: CONTINUATION_REQUIRED` and
`HIGH_USAGE`, and a new row covers the cumulative case.

The FU.1 artifact is the defect in the record it fixes:
`fu1-thin-result.json` carries `"status":"continuation_required"` with
`"continuation_artifact":null`.

### F3 — the prompt names the working directory: **VERIFIED**

Probe `probe-f3-worktree-paragraph.sh` (output `probe-f3-output.txt`):

```
text  : ~The repository root is the current working directory /wt/some worktree; use relative paths,~and absolute paths outside it are refused.
stable: yes                       (two calls, same root, byte-identical)
bound : yes (differs by root)
inputs: 0 story/persona references in the function body
callsite:     worker_worktree_paragraph "$(realpath "$PWD")"
cd in launcher: 0 occurrences
CONTROL master: worker_worktree_paragraph: ABSENT
```

It names the absolute directory and the relative-path rule, is byte-stable for
a given root, and its only argument is `realpath "$PWD"` — the launcher's own
resolved directory. `dispatch.sh` contains no `cd`/`pushd`/`popd`, so `$PWD` at
prompt-assembly time is the directory dispatch was invoked in, which is the
same root every relative story path already resolves against. Nothing from the
story frontmatter or the persona file reaches the function.

Corroboration for the motive: the fixture's `permission_denials` are 14 entries,
every one an absolute `Read` into `/home/devbox/repos/jlengelbrecht/ai-control-plane…`
rather than the worktree.

### F4 — cost is never spend: **VERIFIED** (a guard, not a repair)

```
total_cost_usd|costUSD occurrences in the launcher
  UNDER REVIEW : 0
  CONTROL master: 0
cost-ish scalar paths in fu1-thin-result.json: (none)
```

Grep and behaviour agree, and the contract now says so in prose. Note this item
never regressed — master already read neither figure — so the test is a
characterization guard rather than a fix. That is what the story asked for
("assert"), so it is verified as written; §3.4 records the one way the
behavioural half of it could misfire.

### F5 — the cap marker never lowers `max_cycles`: **VERIFIED**

Probe `probe-f5-cap-marker.sh` calls `refuse_continuation_cap` directly
(`probe-f5-output.txt`):

```
                              UNDER REVIEW      CONTROL master
story max_cycles=8,  cycle 4  -> max_cycles: 8  -> max_cycles: 4   <-- the defect
story max_cycles=3,  cycle 4  -> max_cycles: 4  -> max_cycles: 4
story max_cycles="", cycle 4  -> max_cycles: 4  -> max_cycles: 4
story max_cycles=abc, cycle 4 -> max_cycles: 4  -> max_cycles: 4
marker states the rule        -> yes            -> NO
```

max(existing, authorised cycle), with a non-numeric limit falling back to the
cycle. The launcher passes the story's own value (`"$MAX_CYCLES"`, line 1636),
which is `fm '.max_cycles'` defaulted to 3. The arithmetic is errexit-safe: the
failing `(( limit < cycle ))` is a non-final command in an `&&` list, verified
empirically under `set -euo pipefail`.

`max_cycles` still bounds continuations under the cap: the cap gate (1636)
exits before the limit check (1646), so a continuation the cap lets through is
still refused by `(( CYCLE <= MAX_CYCLES ))`. The contract states it, and the
new `s-c-mc` case exercises it end-to-end.

### F6 — registry: **VERIFIED**

`### External report and fix cycle (AFK-PORT-1.5B-FIX2)` at
`_bmad-output/implementation-artifacts/AFK-PORT-1.5B.md:423`. It carries the
report, the binding ruling with option (b) refused and why, what changed per
item, and four disclosed deferrals — the `Edit` tool as an owner decision, the
KServe cold start as a catalog/router matter, the missing
`evidence/…/external-report.md` the brief named, and the un-fixtured M4R
corroboration. The Dev Agent Record's own gate tallies are reproduced in §4.

### Frozen texts and surface: **VERIFIED**

- `lib/afk-monitor.sh`: zero diff lines against master.
- Both frozen launch command texts live at `dispatch.sh:128–199`; the lowest
  hunk in the diff starts at line 833, so neither text — nor the tool set — is
  touched. Confirmed by hunk header enumeration in `probe-housekeeping.txt`.
- Diff surface is exactly the fix story's five files: `dispatch.sh`,
  `LIFECYCLE-CONTRACT.md`, `run-tests.sh`, the new fixture, and the 1.5B record.
- Fixture is secret-free: no hit for key/token/JWT/PEM/bearer/`password=`/
  `secret=` patterns. What it does carry is another repository's transcript
  text, a `session_id`/`uuid` pair and host absolute paths — identifiers, not
  credentials (§3.5).
- Commit message is plain prose, no `Co-Authored-By`, no tool banner, no
  session link, no BMAD vocabulary.
- `git diff --check 4b873ab..HEAD`: clean, exit 0.

---

## 3. New blockers and residuals

**Blockers: none.**

Residuals, all below the bar:

1. **The status matrix test asserts against its own transcription.**
   `status_matrix_row` in `run-tests.sh` re-implements the launcher's final
   two lines inside the test and then walks 16 rows against that copy, so the
   16-row property cannot fail while `dispatch.sh` drifts. What gives the block
   teeth is the companion source check (`grep -c 'RESULT_STATUS="continuation_required"'`
   over the gates region must be 0), which does fail against master — but it is
   a literal-string grep: `RESULT_STATUS='continuation_required'` or a composed
   value would evade it. The regression row itself is covered live by the
   `silent exhaustion` end-to-end case, which is why this is a note about test
   strength rather than a finding.

2. **Post-run occupancy is now unobservable for any real dispatch.** A
   dispatched story run is multi-turn by construction, so `FINAL_CONTEXT` — and
   with it every usage-derived `CHECKPOINT_DUE`, `CONTINUATION_REQUIRED` and
   `HIGH_USAGE` — is practically unreachable in production; the surviving path
   is the pre-dispatch estimate. That is the intended price of the binding
   ruling (a false signal removed, no false signal substituted) and the
   contract says `FINAL_CONTEXT` is the only occupancy it can honestly observe.
   It does not say plainly that the observation is therefore informational on
   every real run. Worth one sentence for whoever next reads FR-105 and wonders
   why `HIGH_USAGE` never fires.

3. **`num_turns` semantics are the harness's and undeclared.** The kit now
   depends on `num_turns == 1` meaning exactly one API call. That holds for the
   fixture and is the fail-closed direction (any doubt → `CUMULATIVE_RUN`), and
   the contract states the assumption — but a harness change to how turns are
   counted would silently move the boundary.

4. **The F4 behavioural assertion can false-positive on gate text.**
   `jq 'paths(scalars)' "$BR" | grep -qiE 'cost|usd|spend|price'` matches
   scalar PATHS, and the thin result's `gates` object is keyed by the gate
   command strings themselves. A story whose gate command contained the word
   "cost" would fail a test about cost never being published. Harmless inside
   the suite's own fixtures; it is a latent flake in a test, not a product
   defect.

5. **The fixture embeds a foreign repository's transcript.**
   `tests/fixtures/claude-result-envelope-multiturn.json` carries FU.1's full
   `result` text (another repo's story status, file names, a recovery script),
   a `session_id`/`uuid`, and 14 host absolute paths. No credential, and the
   coordinator's exact-match check stands; recorded only because a committed
   fixture is a durable copy of another project's working notes.

6. **`max_cycles` written with a leading zero.** `^[0-9]+$` accepts `08`, and
   `(( 08 < 4 ))` then errors on the base ("value too great for base") and
   prints to stderr; the comparison is skipped and the story's value is used
   verbatim. Under errexit this does not abort, and for `08` the result is
   still correct — but `max_cycles: 09` refused on cycle 10 would emit a marker
   whose suggestion does not reach the cycle. YAML would read those as octal
   anyway; noted for completeness only.

**One discrepancy between the brief and the tree** (not a finding against the
diff): the reviewer brief names worktree HEAD `daa00e9`. Actual HEAD is
`ffc2b2e`, which is what the review story scopes and what I reviewed.
`daa00e9` exists in the object store on no branch — its parent is `3b588c9`,
pre-dating the `#35` merge, so it is an earlier lineage's tip, not this fix.
Flagging so the coordinator's record does not carry the wrong SHA.

---

## 4. Gate tallies I ran

| Gate | Result |
|---|---|
| `bash tests/lifecycle-readiness-tests.sh` | **290 passed, 0 failed** (exit 0) |
| `bash tests/lifecycle-dispatch-tests.sh` | **256 passed, 0 failed** (exit 0) |
| `bash tests/lifecycle-tests.sh` | **478 passed, 0 failed** (exit 0) |
| `git diff --check 4b873ab..HEAD` | clean (exit 0) |
| `bash tests/run-tests.sh` | **not run** — the coordinator's chain owns it in this worktree. Its new assertions were exercised at unit level against both sources instead (F1, F2, F5 above). |

Raw output: `gates.txt`.

The worker's own Dev Agent Record reports the same three suites at 290/0,
256/0 and 478/0, plus `run-tests.sh` at 766 passed / 1 failed with the recorded
`lifecycle concurrency gate` aggregate (204/3) as the only red. My independent
runs corroborate the three I was permitted to run.

---

## Dev Agent Record

Reviewer session, `{claude, claude/strong, effort medium}`, stamp digest
`sha256:9ba50a5d…`. Review-only: the five probe files and this report under
`evidence/AFK-PORT-1.5B-FIX2-REVIEW/` are the only writes; scratch (master's
`dispatch.sh`, gate logs, mutated envelopes) under `/tmp/afk-rev/`. No product
code, test, doc, story record or git state was touched, and `tests/run-tests.sh`
was not run.
