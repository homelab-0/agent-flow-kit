AFK-PORT-1.5D REVIEW: NOT CLEAN — 2 blocker(s)

Independent adversarial + senior review of `jlengelbrecht/afk-port-1.5d` at
`2b7b29fd3d2d149b65e427fd411f833bca5c86ab` against master
`32e94cc5e0b1c6991aabe1942c4f701b7e9c526e`. Persona proof
`4cdff719c4f3042532520611f7106d80393173004355e6a83771b366c3efc7f9`
(intermediates `0bc44690…` / `ab52d884…`) matches the brief exactly.

The lane is well built. The window hierarchy, the parts-per-million banding and
its boundary equality, the atomic owner-only write, the reconciliation step and
its idempotence, the absence of any launch path, and the 800-line budget all
hold under attack; I reproduced each of them rather than reading the tests. Both
blockers are in the same place: the two guards that are supposed to be the
*loud* ones — the credential refusal and the explicit-stamp refusal — each have
one narrow case where they go quiet, and one of the two goes quiet by
disclosing.

## Blockers

### B1 — a credential anywhere but the start of a value is accepted, then echoed verbatim

**Requirement.** S3: the verb writes "with the kit's redaction rules
(secret-looking values refused, not echoed)". Attack 3: "secret-looking
members/values are refused without disclosure". `docs/LIFECYCLE-CONTRACT.md`
(this diff, line 1517): "A secret-looking member is refused … and never reaches
a diagnostic."

**Defect.** `afk_pm_secret_bearing` (`lib/afk-commands.sh:745`) anchors four of
its five credential alternatives to the start of the string:

```
^(sk|rk)-…|^(ghp|gho|ghu|ghs|github_pat)_…|^xox[abprs]-…|^AKIA…|-----BEGIN … PRIVATE KEY-----
```

jq's `test` treats `^` as start-of-string here, so a credential is caught only
when it occupies offset 0 of a value. The fifth alternative, the PEM header,
carries no `^` and does match anywhere — so the pattern is inconsistent with
itself.

**Why this is the case that matters.** `resume_instruction` is defined by S3 as
"a ready-to-use command line for the human". A credential in a command line is
never at offset 0; it sits behind a flag. So the one member of the one artifact
most likely to carry a secret is exactly the member the check cannot see.

**Reproduction** (`B1-credential-anchoring.txt`, synthetic token shape):

```
resume_instruction = "ghp_SYNTHETICAAAAAAAAAAA"                        -> rc=4 REFUSED
resume_instruction = "claude --resume PM --token ghp_SYNTHETIC…"       -> rc=2 ACCEPTED
```

The accepted document is written to `pm/continuation.json`, and from then on
every `status` and every `monitor` pass prints it back:

```
next_safe_action: Start the successor ORCH PM session yourself in Orca, then run: claude --resume PM --token ghp_SYNTHETIC…
finding.detail:   resume_instruction: claude --resume PM --token ghp_SYNTHETIC…
```

— in the JSON result, in the finding detail, and in the human rendering. The
kit's other secret rules are fail-closed; this one fails open and then
publishes, which is the direction that costs something.

**Reachability.** One ordinary operator action: writing the continuation the
lane exists to produce, with the command line the contract asks for.

**Minimal fix.** Drop the four `^` anchors, or replace each with
`(^|[^A-Za-z0-9_-])`, so the token shapes match anywhere in a value as the PEM
alternative already does. `tests/lifecycle-tests.sh:1930` currently pins only
the offset-0 case (`note:"sk-$SENTINEL"`); add the embedded case beside it.

### B2 — an explicitly named unusable `--pm-stamp` is silently reclassified

**Requirement.** The story's binding design ruling: "an explicitly named stamp
is never silently ignored: an unresolvable one reports `PM_STAMP_UNUSABLE` and
evaluates nothing". Restated verbatim in the contract shipped in this same diff:
"A stamp named on the command line is **never silently ignored**". Attack 1:
"explicit unusable stamp reports `PM_STAMP_UNUSABLE` and never falls through".

**Defect.** In `afk_pm_apply` the stamp branch (`lib/afk-commands.sh:624-629`)
sets `reason="PM_STAMP_UNUSABLE"`, and the observation branch immediately after
it (`635-639`) overwrites `reason` unconditionally whenever the observation
carries no usage figure:

```bash
if [[ -n "$obs" ]]; then
  usage="$(… )"
  if [[ "$usage" == "null" ]]; then
    reason="$(… PM_USAGE_CUMULATIVE_ONLY … else "PM_USAGE_UNOBSERVABLE" …)"
  fi
fi
```

The arithmetic guard downstream still honours the stamp (`"$reason" !=
"PM_STAMP_UNUSABLE"`), and the window genuinely does not fall through — but the
guard is now testing a variable the observation branch has already erased, so it
protects nothing in exactly the cases where the reason was lost.

**Reproduction** (`B2-stamp-precedence.txt`, one malformed stamp, three
observations differing only in `usage_tokens`):

```
numeric usage           -> reason PM_STAMP_UNUSABLE          state NOT_EVALUATED
cumulative-only adapter -> reason PM_USAGE_CUMULATIVE_ONLY   state NOT_EVALUATED
no usage figure         -> reason PM_USAGE_UNOBSERVABLE      state NOT_EVALUATED
```

In the last two the operator is handed the wrong remedy — "Checkpoint at the
declared PM phase boundaries instead" — when the actual repair is "Fix the
supplied stamp or declare the trusted catalog through `AFK_ROUTER_CATALOG`". The
stamp they named is not mentioned at all.

**Reachability.** One ordinary operator action, and the likeliest one: the
cumulative-only observation is precisely what the contract tells an adapter to
write (`usage_tokens: null` with `PM_USAGE_CUMULATIVE_ONLY`), and Story 1.8's
statusline hook is the expected writer. `status --pm-stamp <stamp>` beside it is
the documented invocation.

**Why the gate missed it.** `tests/lifecycle-readiness-tests.sh:1528` exercises
both unusable-stamp shapes, but only ever with `pm_obs 999 150000` — a numeric
usage. The null-usage row is the untested half.

**Minimal fix.** Guard the overwrite:
`if [[ "$usage" == "null" && "$reason" != "PM_STAMP_UNUSABLE" ]]; then`.

## Residuals

Recorded, not blocking: each either fails closed, needs a non-ordinary action,
or is a reporting gap with nothing consuming it.

- **R1 — `pm/checkpoint.json` is never validated on read.** S3 says both
  artifacts are "validated on read"; only the continuation is. A file containing
  `CORRUPT NOT JSON AT ALL` is reported as a present `checkpoint_artifact` with a
  digest and no complaint (`R-residuals.txt`). Nothing consumes the checkpoint
  yet, so this is false assurance rather than wrong action — but it is the
  asymmetry a reader of the contract will not expect, and there is no
  `PM_CHECKPOINT_ARTIFACT_INVALID` in the vocabulary to report it with.
- **R2 — a member named `*_tokens` is refused as secret-bearing.**
  `afk_pm_secret_bearing` classifies JSON member names with
  `afk_env_classification`, which exists to classify *environment variable*
  names and matches `*TOKEN*`. So a `budget_state` recording `window_tokens` /
  `usage_tokens` — this lane's own `pm_budget` vocabulary, the obvious thing for
  a coordinator to checkpoint — is refused with exit 4 and told to "Remove the
  secret-bearing member", which is a false accusation. Fails closed, and the
  story's declared `budget_state` shape (cycles, continuations, PM continuation
  count) does not collide, so: residual. Worth a name-level exception for
  `*_tokens` alongside the shape check.
- **R3 — `PM_ARTIFACT_SECRET_BEARING` is published but produced by no path.**
  The contract says refusal is "with `PM_ARTIFACT_SECRET_BEARING` and exit code
  4"; the implementation warns in prose and exits 4 without the code and without
  a result document, so automation reading the published vocabulary can never
  observe it. The other nine PM codes all have producers.
- **R4 — `launcher.budget_policy` is never consulted.** `dispatch.sh:1501`
  resolves the policy as `$AGENT_FLOW_BUDGET_POLICY` → `.launcher.budget_policy`
  → installed default; `afk_pm_policy_ppm` reads the first and the third only,
  and the kit reads no launcher config at all. A host that declares the policy
  through the config — documented in the policy file's own header — bands its
  workers on one document and its coordinator on another, silently, because the
  shipped default is perfectly readable. The Dev Agent Record's claim that the
  policy is read "exactly as dispatch.sh reads it" is true only of the env
  branch. This is the one residual that fails *quietly*; the catalog got its own
  `AFK_ROUTER_CATALOG` knob for exactly this reason and the policy did not.
- **R5 — `AFK_PM_SESSION` is read from the environment but undeclared.** It is
  seeded from the environment in `lib/afk-commands.sh:514` but is absent from
  the usage block's environment list (which gained `AFK_PM_DIR` and
  `AFK_ROUTER_CATALOG`). Exported, it turns every non-reconcile command,
  `status` included, into a usage failure via the `--session` guard in
  `bin/agent-flow-kit:445`. Not ordinary — nothing documents the variable — so
  residual, but either document it or stop reading it from the environment.
- **R6 — reconcile replaces `pm/budget-state.json` wholesale.**
  `afk_pm_reconcile` writes a fresh `{schema, pm_continuations, updated_at}`
  rather than merging, so any member a later writer adds is dropped on the next
  reconcile. Nothing else writes the file today; it is the Story 1.6 seam, and
  worth a note there.
- **R7 — threshold arithmetic differs in kind from lane A/B.**
  `afk_pm_policy_ppm` computes parts per million in awk (`(r * 1000000) + 0.5`);
  `budget_threshold_ppm` in `dispatch.sh` parses the decimal by hand precisely
  because "0.85 * 1000000 can land on 849999". They agree for every ratio of six
  decimals or fewer, including the shipped 0.70/0.85, which I checked at the
  boundary; beyond six decimals the rounding and dispatch's truncation to six
  digits can differ by one ppm. Cosmetic today, and the +0.5 is the right guard —
  but the comment claiming identical arithmetic overstates it.
- **R8 — a quoted policy scalar is unreadable to the kit and readable to
  dispatch.** `checkpoint_ratio: "0.70"` gives `PM_BUDGET_POLICY_UNREADABLE`
  while `yq` accepts it. Loud, so safe.
- **R9 — `window_source` carries disjoint vocabularies.** `CATALOG` in the
  worker `budget` block, `STAMP|ADAPTER|NOT_EVALUATED` in `pm_budget`. Both are
  documented; a consumer reading the member generically has to know which block
  it came from.
- **R10 — `afk_pm_apply` overwrites `next_safe_action` on monitor.** A pass with
  both a degraded worker watch and an outstanding hand-over reports only the PM
  action. Deliberate and commented ("so an outstanding coordinator hand-over
  speaks over the watch summary"); both findings survive, only the single-line
  action is replaced. Recorded because it is a real precedence choice a reader
  should know was made on purpose.
- **R12 — the artifact schemas are open.** `afk_pm_artifact_valid` checks the
  six required members and constrains `in_flight_dispatches` to strings, but
  accepts any additional member. A submission carrying a top-level `transcript`
  and `evidence_body`, plus a gate log nested inside `decisions`, is accepted
  and written verbatim (`R-residuals.txt`). This answers attack 3's "closed
  enough to enforce thin state" with a qualified no: S3 asked for ids-only on
  `in_flight_dispatches` and got it, but the contract's broader promise — "never
  transcripts or evidence bodies" — is enforced on one member out of six, and
  thin consumption stays a discipline the skill asks for rather than a rule the
  verb applies.
- **R11 — hygiene, for the merge rather than the branch.** `2b7b29f` carries
  `Co-Authored-By: Claude Opus 5` and `Claude-Session:` trailers. Every merged
  commit on master is attribution-free (they carry only a `Size:` trailer), so
  the convention is enforced at squash time; keep the trailers out of the squash
  message. No code change, no fix worker.

## Disclosed items, assessed

The Dev Agent Record's own disclosures hold up:

- **The 902 → 800 compression.** I checked the compressed structures rather than
  taking the claim: the reason table is one `code|message|action` data block read
  by three accessors, the option parse shares one arm, the human rendering is a
  single `afk_render_q` projection, and the test cases are case tables. No
  acceptance criterion or test case is missing as a result — coverage is genuinely
  wide, and the two blockers are untested *rows* inside cases that are present,
  not absent cases.
- **Why `lib/afk-monitor.sh` needed no edit.** Confirmed: the reconcile step is
  called from `afk_cmd_monitor`, not from inside `afk_monitor_reconcile`, and
  `git diff --stat` shows the file untouched. "Worker watches untouched" is
  structural here, not merely asserted.
- **The tolerated aggregate red.** Out of scope for this review by the brief. I
  did not run `tests/run-tests.sh` and take no position on it beyond noting that
  `lib/afk-mutate.sh` is untouched by this lane.
- **Surface expansion mid-story.** `bin/agent-flow-kit` and `lib/afk-common.sh`
  were re-stamped before being edited; the stamp on record
  (`sha256:11b0e3f5…` for the reviewer, the lane's own attempt-2 stamp for the
  implementation) is consistent with the eight files in the diff.

## AC evidence

| AC | Verdict | Evidence |
|---|---|---|
| AC-1 observation contract; provenance recorded | **pass** | Absent, unparseable, provenance-less, wrong-schema, adapter and cumulative-only all reproduced independently; each lands `NOT_EVALUATED` with its own reason, and a document declaring no provenance is malformed rather than assumed `HUMAN`. |
| AC-2 `pm_budget`, three-branch hierarchy, policy thresholds | **pass with B2** | STAMP (catalog `min_context`), ADAPTER and `NOT_EVALUATED` branches all reached; boundaries exact at 699999/700000 and 849999/850000; unreadable policy gives `PM_BUDGET_POLICY_UNREADABLE` and bands nothing. B2 is the reason code in one corner of the stamp branch, not the hierarchy itself. |
| AC-3 artifacts validated, redacted, atomic | **fail (B1)** | Validation, `in_flight_dispatches` string-only enforcement, 0600 mode, atomic `mv`, byte-identical disk after four separate refusals and no `.afk-tmp` left behind: all confirmed. Redaction is where it fails — B1, with R2 and R3 alongside. |
| AC-4 loud `PM_CONTINUATION_REQUIRED`; no launch path | **pass** | Owner-action finding carries path + `sha256:` digest + the instruction verbatim; `next_safe_action` sends the human to Orca; exit raised to 2 and never lowering a 3 or 4. I grepped every added line of `lib/` and `bin/` for `terminal create`, `worker-start`, `orca`, `exec`, `eval`, `nohup` — the only hit is the word "Orca" inside the reason table's prose. |
| AC-5 reconcile clears, records, counts; watches untouched | **pass** | Successor recorded from `--session` and from the observation, digest bound, count 0→1, replay left it at 1, condition cleared, invalid artifact reconciled by nothing and counted nothing. The step reads and writes only under `pm/`. |
| AC-6 documented in the skill and the contract | **pass with R3** | `files/model-router/SKILL.md` gains the five discipline rules including the exact resume shape; `docs/LIFECYCLE-CONTRACT.md` documents the `pm/` contract, the block, the finding and the reconciliation, and its reason-code block matches `afk_pm_reason_table` exactly. R3 is the one sentence that outruns the code. |
| AC-7 gates green; ≤ 800 lines; 1.6 seam named | **pass** | Three focused gates green (below); product diff exactly 800 added+changed over exactly the eight declared files; `git diff --check` clean; hard stops verified untouched by `git diff --stat`; `envelope_actions` opaque and `pm_continuations` unconsumed, both named in the record. |

## Gates and probes

| Gate | Result | Wall time |
|---|---|---|
| `bash tests/lifecycle-readiness-tests.sh` | 341 passed, 0 failed (rc 0) | ~330s (not separately instrumented) |
| `bash tests/lifecycle-dispatch-tests.sh` | 274 passed, 0 failed (rc 0) | ~245s (from log timestamps) |
| `bash tests/lifecycle-tests.sh` | 499 passed, 0 failed (rc 0) | 460s (measured) |
| `git diff --check 32e94cc 2b7b29f` | clean (rc 0) | — |

Adversarial probes run against `bin/agent-flow-kit` directly, outside the
suites, on throwaway HOMEs under the session scratchpad: roughly fifty invocations across
observation shapes, the window hierarchy, threshold boundaries, artifact
validation, secret refusal, atomicity, reconciliation and replay. Evidence:
`B1-credential-anchoring.txt`, `B2-stamp-precedence.txt`, `R-residuals.txt`.
Synthetic token shapes only; no real credential was used, written or printed.
The aggregate suite was not run.
