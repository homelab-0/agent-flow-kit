# AFK-PORT-1.5B REVIEW: NOT CLEAN — 1 blocker

Adversarial + senior review of Story 1.5 lane B, branch `jlengelbrecht/afk-port-1.5b`
@ `54dfd14` against `master` @ `ec83010`. Fresh session; I did not write this code.

Persona proof (BMAD dev, computed before anything else):
`07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee` — matches the
briefed OUTER hash, no stop.

Evidence: eight attack scripts beside this file, each with its own anti-vacuity
control. Run any of them from the worktree (`bash evidence/AFK-PORT-1.5B-REVIEW/atk-*.sh`);
they read the tree and write only under `${TMP:-/tmp}/rev1.5b`. Nothing in the
worktree was modified by this review.

| script | what it attacks |
|---|---|
| `atk-launch-texts.sh` | the frozen launch texts, built from master and from HEAD and diffed (attack 1) |
| `atk-prompt-paragraph.sh` | the prompt paragraph: shell injection, byte stability, volatility (attack 1) |
| `atk-usage.sh` | the usage adapters over fifteen envelope shapes, both harnesses, the threshold bands (attacks 2, 3) |
| `atk-status-matrix.sh` | the whole (worker signal × gates × budget state) status space (attack 3) |
| `atk-artifacts.sh` | schema validation, identity, the `ARTIFACT_STALE` freshness check (attack 4) |
| `atk-redact.sh` | `artifact_redact` against the kit's own redactor (attacks 4, 5) |
| `atk-record.sh` | `record_budget_line` idempotence, coexistence, the lane A race property (attack 6) |
| `atk-agnostic-size.sh` | harness agnosticism in the core, diff size, commit hygiene (attacks 8, 9) |

---

## 1. Blockers

### BLK-1 — the `CONTINUATION-REQUIRED:` reason is filtered by a pattern denylist, not by the kit's redaction discipline; a short credential reaches the `.blocked` marker and the dispatch log

**Requirement.** S4: artifact-derived text passes "through the same redaction rules
as other lifecycle output (the existing sentinel discipline applies: a secret-looking
value is never echoed into a result or log)". AC-5: "artifacts pass the kit's
redaction; sentinel proof". `docs/LIFECYCLE-CONTRACT.md` repeats the claim: the
artifacts "are held to the kit's redaction discipline on read", and the worker's
reason "passes through the redactor first".

**What the code does.** `files/model-router/scripts/dispatch.sh:921` introduces a
*new* redactor:

```
artifact_redact() { printf '%s' "$1" | sed -E 's/[A-Za-z0-9_./+-]{24,}/[REDACTED]/g'; }
```

That is a denylist keyed on a 24-character run of a restricted charset. The kit's
own redactor, `afk_redact_value` (`lib/afk-common.sh:458`), replaces the whole
value; the kit's own rule for *caller-supplied free text* is stricter still —
`afk_safe_diagnostic` (`lib/afk-common.sh:502`) echoes back only words from a
closed vocabulary, with the comment "a credential is not distinguishable from a
typo by shape". The new function inverts that discipline for the one channel in
this lane that carries untrusted worker free text.

**Reproduction** (`atk-redact.sh`, verbatim output):

```
--- CONTROL: the reviewed test's own sentinel (30 chars) ---
in : sk-live-9f2a4c7e1b8d3550aa11bb22cc33
out: leaked [REDACTED] here

--- ATTACK: real-world secrets under 24 chars, or broken by an excluded char ---
AKIAIOSFODNN7EXAMPLE       -> CONTINUATION-REQUIRED: auth failed with AKIAIOSFODNN7EXAMPLE
ghp_16C7e42F292c6912       -> CONTINUATION-REQUIRED: auth failed with ghp_16C7e42F292c6912
hunter2                    -> CONTINUATION-REQUIRED: auth failed with hunter2
password=Tr0ub4dor&3       -> CONTINUATION-REQUIRED: auth failed with password=Tr0ub4dor&3
xoxb-2f9a:8c1d-77aa-...    -> CONTINUATION-REQUIRED: auth failed with xoxb-2f9a:[REDACTED]

--- the kit's OWN redactor on the same values ---
AKIAIOSFODNN7EXAMPLE   -> [REDACTED]
hunter2                -> [REDACTED]
```

The section 3d sentinel is `sk-live-9f2a4c7e1b8d3550aa11bb22cc33` — 30 characters
of exactly the charset the regex covers. It is the one shape the redactor catches,
so the AC-5 test passes over a filter that misses an AWS access key id (20 chars),
a truncated GitHub token, any passphrase, and the tail of any value whose leading
run is broken by `:` or `=`.

**Reachability.** One ordinary occurrence. The reviewed test's own anti-vacuity
control proves the channel is live and unfiltered end to end: "redaction CONTROL:
the worker's own words do reach the marker" asserts the raw text
`stopping, the token was` is PRESENT in `${STORY}.blocked`. The same run also puts
the reason on stderr (`log "budget: $signal"`, `dispatch.sh:1424`). A worker that
stops because an auth call failed and names the credential in its one-line reason
— the exact case a redactor on this path exists for — writes it to a marker file
and to the dispatch log. No adversarial input is required; the worker need only be
imprecise once.

**Minimal fix.** Do not pattern-match untrusted free text. Either (a) route the
reason through the closed-vocabulary discipline — record that a reason was given
and its length, not its content, keeping the stable `reason=CONTINUATION_ARTIFACT_INVALID`
code that automation actually reads; or (b) if a human-readable reason is wanted,
keep `artifact_redact` but make it fail closed on anything token-shaped: lower the
run length to ~8, add `:=` and the remaining base64/JWT characters to the class,
and redact any word adjacent to a credential keyword (`token`, `key`, `secret`,
`password`, `bearer`). (a) is the one that matches what the contract already
claims. Either way the AC-5 test needs a second sentinel that is short and one
that is broken by an excluded character, or the test keeps certifying the gap.

---

## 2. Residuals

### RES-1 — HIGH — `budget.state: CONTINUATION_REQUIRED` is published beside `status: done` on a run whose gates passed

`atk-status-matrix.sh` walks the whole decision space (the three conditionals are
transcribed verbatim from `dispatch.sh:1441,1446,1511`, and the script prints those
source lines first so the transcription is checkable). One row is uncovered by the
contract's table:

```
signal=no  gates=true  budget.state=CONTINUATION_REQUIRED  -> status=done  exit=0
```

Reachable by a run that ends at 180000/200000 tokens and passes its gates:
`budget_evaluate_usage` sets `CONTINUATION_REQUIRED` from the ratio alone, and the
status logic (correctly) reports `done`. The thin result then says the story is
finished and that a continuation is required, and `afk_monitor_reconcile_delivery`
projects `context_budget: CONTINUATION_REQUIRED` onto a COMPLETED, settled Dispatch
— which is precisely the member lane D's PM view is being built to read.

This is not a manufactured completion (the gates really passed), so it is not a
blocker. But it hands lane C/D an incoherent input on the first day they consume it.
**Recommendation:** an end-of-run ratio is a *sizing* observation, and there is
already a finding for that. Either map "≥ continuation ratio at end of run with a
finished story" to `OK` + `HIGH_USAGE`, or gate the state assignment on the run
being unfinished — and say in the contract table which it is.

### RES-2 — MEDIUM — a checkpoint left by an earlier cycle is reported as this cycle's `checkpoint_artifact`

The continuation artifact gets a freshness proof: `CONTINUATION_BEFORE` is captured
pre-launch (`dispatch.sh:1183`) and a byte-identical artifact after the run is
`ARTIFACT_STALE`. The checkpoint gets neither treatment — no pre-launch sha, no
removal (only `result_file` is removed, `dispatch.sh:1291`). So a cycle-2 attempt
whose worker never wrote a checkpoint still publishes cycle-1's file as
`budget.checkpoint_artifact`, with a sha that vouches for content this attempt did
not produce. The record's own rationale for the continuation check ("an artifact
byte-identical to the one that was already there was not written by this worker")
applies verbatim here. Confirmed in `atk-artifacts.sh`; `CHECKPOINT_BEFORE` occurs
zero times in the file. **Recommendation:** capture the checkpoint sha alongside the
continuation one and record `CHECKPOINT_ARTIFACT_STALE` as a finding — a finding,
not a refusal, consistent with how an invalid checkpoint is already treated.

### RES-3 — MEDIUM — a `usage` object carrying no input or cache member yields a confident `usage_tokens: 0`

`atk-usage.sh`, case "output_tokens ONLY (no input at all)":

```
{"usage":{"output_tokens":9999}} -> usage_tokens 0, provenance HARNESS_ENVELOPE, observed_at END_OF_RUN
```

The adapter's guard is `($u | length) == 0`, so a `usage` object with *any* member
passes, and the three token members each default to `0`. The kit then publishes a
measured-looking `usage_ratio: 0.000000` and an `OK` state for a run whose context
it never observed — and suppresses `HIGH_USAGE` for it. Every other unobservable
shape in the matrix correctly returns `NOT_EVALUATED`; this one does not. Not a
blocker because a real `claude -p` envelope always carries `input_tokens`, so it is
not reachable today without an upstream shape change — but it is the one place the
adapter reports more than it saw, which is the property the whole lane is written
around. **Recommendation:** require at least one of the three members to be
present, else `USAGE_UNOBSERVABLE`.

### RES-4 — MEDIUM — the single-entry `modelUsage` fallback corroborates against whatever model happens to be there

`(($mu[$m].contextWindow) // (if ($mu|length)==1 then <the one entry> else null end))`.
Two consequences, both confirmed in `atk-usage.sh`: with one entry whose key does
not match the stamped model, the adapter adopts that model's window (`123` in the
fixture) and can then raise `WINDOW_DISAGREEMENT` against a model that did not run
the turn; and because `NATIVE_MODEL` is the catalog's id stripped of its provider
qualifier while `modelUsage` is keyed by the harness's own full model id, the exact
match will usually miss in production, leaving `window_reported_tokens: null`. The
contract advertises corroboration that will mostly be inert and can occasionally be
wrong. Harmless to the budget (the catalog window is always the divisor —
independently confirmed), but it puts a finding in the result that a reader will
chase. **Recommendation:** corroborate only on an exact key match; drop the
single-entry fallback, or record `WINDOW_UNCORROBORATED` for the non-matching case.

### RES-5 — LOW — the discipline paragraph omits the "harness signals context pressure" trigger

The binding design ruling says the worker stops "when it judges it cannot finish
**or when the harness signals context pressure**". The generated paragraph carries
only the first clause. S3's own enumeration is satisfied, so this is prose drift
rather than a missing AC, but the ruling's second trigger is the one a worker
cannot infer for itself. One sentence closes it.

### RES-6 — LOW — `^CONTINUATION-REQUIRED:` is matched anywhere in the worker's text

A worker that quotes the marker at the start of a line — including while explaining
that it did *not* need it — trips the refusal, and because no continuation artifact
exists the run exits 3 with a `.blocked` marker and **no result artifact**, on an
attempt that may have succeeded. This mirrors the pre-existing `^NEEDS-HUMAN:`
channel exactly and is dispositioned territory for that one; recording it because
the new path's consequence (no result at all) is heavier. Related: for `codex`,
`WORKER_TEXT` is the terminal tail read with `--limit 5000` (`dispatch.sh:342`), so
on a chatty run the signal can scroll out of view. Neither is a usage-path scrape —
AC-1 is about the usage adapters and they read no terminal, independently confirmed.

### RES-7 — LOW — `CONTINUATION-REQUIRED:` with an empty reason is accepted

The line is matched, `tail -1`'d and redacted, and an empty reason is recorded and
written to the marker without comment. Cheap to reject; nothing downstream breaks.

### RES-8 — LOW — `needs_human` is published in `dispatch_result_statuses` but no thin result ever carries it

`dispatch.sh` writes `done`, `gates_failed` or `continuation_required`; the
`needs_human` path deliberately writes no result at all. The value is real for a
*delivery* status (`afk-monitor.sh` gates on `$st == "needs_human"`), so the
published list is a union across two producers under a name that reads like one.
Not false, but a reader of the contract's machine-checkable block will look for a
producer that does not exist. Consider `needs_human` being documented as
delivery-only, or the key renamed.

### RES-9 — LOW — the readiness suite's unpublished-reason sweep does not see the new member

`unpublished_reasons` scans `.reason?`. `budget.usage_reason` is a new member with
its own vocabulary and escapes that guard. Both values currently assigned are
published, so this is a coverage gap rather than a defect.

### My view on each item the worker disclosed

| disclosed | my assessment |
|---|---|
| No mid-run usage, no `stream-json` | **Agree.** Follows from the binding ruling; both launch texts are byte-identical to master's across all four classes, independently rebuilt and diffed (`atk-launch-texts.sh`), and the consequence is recorded as contract text rather than worked around. Correct call. |
| ~20 assertions cut to reach 800 lines | **Agree, with one note.** Every AC keeps a falsifiable check. The cut "unparseable envelope" case is genuinely covered in behaviour — I exercised truncated JSON, a bare string, `null`, an array and a top-level array, all `USAGE_UNOBSERVABLE` — but only in my attack script, not in the suite. Worth one assertion when budget allows. |
| A checkpoint's content is validated for shape, not usefulness | **Agree, and stronger than stated.** `atk-artifacts.sh` shows an artifact whose every member is present but empty (`""`, `[]`) is `VALID`. Lane C must not assume a checkpoint it accepted is resumable. |
| `CHECKPOINT_DUE` produces no action this lane | **Agree.** Correct seam discipline; inventing half of lane C here would have been worse. |
| The design change (unobservability must not overwrite the pre-dispatch verdict) | **Agree, and verified.** With `pre=OK` and with `pre=NOT_EVALUATED`, an unobservable observation leaves `state` and `reason` untouched and lands in `usage_provenance` / `usage_reason`. Lane A's merged behaviour is intact. |
| `ARTIFACT_STALE` instead of pre-launch removal | **Agree for the continuation artifact; incomplete for the checkpoint** — see RES-2. |
| Redaction "mirroring `lib/afk-common.sh`" | **Disagree — see BLK-1.** The *indirection* mirrors it. The *rule* does not. |

---

## 3. AC-by-AC coverage

| AC | verdict | evidence I checked |
|---|---|---|
| **AC-1** claude usage from the envelope with provenance; codex `NOT_EVALUATED`; no scraping | **met** (RES-3, RES-4 noted) | `atk-usage.sh`: 15 envelope shapes. Sum is `input + cache_read + cache_creation` (1000 from 100/900/0), labelled `HARNESS_ENVELOPE` / `END_OF_RUN`. Missing file, empty file, garbled JSON, `usage` as string/array/empty-object, non-numeric members, top-level array → all `USAGE_UNOBSERVABLE`. codex and an unknown harness → `NOT_EVALUATED` / `USAGE_UNOBSERVABLE`. Grep over the adapters and the evaluator finds no terminal or transcript read; the control shows the same grep does find the pre-existing `WORKER_TEXT="$TERMINAL_TAIL"` at `dispatch.sh:1358`. |
| **AC-2** bands with boundary equality; `HIGH_USAGE` at ≥ checkpoint | **met** | `atk-usage.sh`, window 200000, cp 0.70 / cont 0.85: 139999→`OK`; 140000→`CHECKPOINT_DUE`+`HIGH_USAGE`; 169999→`CHECKPOINT_DUE`; 170000→`CONTINUATION_REQUIRED`+`HIGH_USAGE`; 240000→`CONTINUATION_REQUIRED`. Both boundaries cross on equality. Unobservable and undeclared-window paths leave the pre-dispatch state alone. Window disagreement recorded as a finding while the CATALOG window stays the divisor. |
| **AC-3** paragraph names artifacts, members, boundaries, stop rule; byte-stable; data never shell | **met** (RES-5) | `atk-prompt-paragraph.sh`: five injected story paths (`$(touch …)`, backticks, `;cmd;`, `${HOME}`, spaces) — the probe file is never created, and the path is echoed literally; the control confirms the probe fires under `eval`. 200 renders of the same input give one digest. No timestamp, no threshold, no observed number. Zero command-substitution or `eval` sites in the function body; the only input is the story path. |
| **AC-4** valid continuation → status + identity + record line; invalid/missing → loud `NEEDS_HUMAN`; never a manufactured completion | **met** (RES-1, RES-2, RES-6, RES-7) | `atk-artifacts.sh`: `VALID` / `ARTIFACT_MISSING` / `ARTIFACT_UNPARSEABLE` (empty, non-JSON, truncated, array, bare string, `null`) / `ARTIFACT_SCHEMA_MISMATCH` (a checkpoint offered as a continuation) / `ARTIFACT_MEMBER_MISSING` (member absent or `null`); the stale-identity truth table refuses a byte-unchanged artifact and passes a changed one. `atk-status-matrix.sh`: no combination reaches `status: done` after a worker signal, and the refusal path writes no result artifact. `atk-record.sh`: `SIZING_RISK` and `CONTINUATION_REQUIRED` coexist in one cycle at one line each, three cycles give three lines, the body is preserved. |
| **AC-5** artifacts pass the kit's redaction; sentinel proof | **NOT met — BLK-1** | Member values genuinely never leave the artifact: only `{path, sha256}` reaches the result, and probes for four distinct member values find no leak. The failure is the free-text channel: `artifact_redact` misses secrets under 24 characters or broken by an excluded character, while the suite's single 30-character sentinel certifies it. |
| **AC-6** `context_budget` on the watch record and `status`; additive, no 1.3 retrofit | **met** | Code read of `afk-monitor.sh:727-739, 1173, 1218`: bounded to the published four on read, `// "NOT_EVALUATED"` for a record written before the member existed, `MONITOR_DEGRADED` entries carry `NOT_EVALUATED`, and the `needs_human` projection is unchanged. Gate: `tests/lifecycle-dispatch-tests.sh` (below) carries the assertions, including the `BANANA` bounding case. |
| **AC-7** contract/schema/docs true of the code; policy reason list extended | **met with the BLK-1 exception** | Every contract sentence I checked holds — provenance labels, the corroboration-only window, boundary equality, "does not overwrite `state`", "only their identity reaches the thin result", the five-row launcher table, exit 1 for `continuation_required`, the bounded watch member. Two sentences do not: "held to the kit's redaction discipline on read" and "passes through the redactor first" overstate what `artifact_redact` does (BLK-1). Five reason codes added to the policy file and mirrored in `schema`; only `docs/LIFECYCLE-CONTRACT.md` is touched, so no frozen 1.3 orchestration document is retrofitted. RES-8 on `needs_human`. |
| **AC-8** both harnesses exercised; frozen launch texts byte-identical | **met** | `atk-launch-texts.sh` rebuilds all four classes (claude native with and without persona, claude gateway, codex) from master's `dispatch.sh` and from HEAD's and diffs them: identical, `sha256 af3c0a62…` both sides, with a seeded-change control proving the comparison is not blind. No `stream-json`, no codex `--json`. `atk-agnostic-size.sh`: zero CLI names inside the thirteen core budget functions; `claude`/`codex` appear only in the `harness_usage_observation` case arms and in the two named adapters. Both harnesses have an e2e case in the suite. |
| **AC-9** gates green (concurrency the only tolerated red); diff ≤ 800 lines, reported; lane C/D seams stated | **met** | Measured independently: **800 insertions, 34 deletions across 10 files** excluding the story file — exactly the record's figure, at the budget, 10 of the 25-file budget. Diff is inside the declared surface (11 paths, the eleventh being the story record itself). Commit message plain, zero trailer lines. `git diff --check` clean. Seams for lanes C and D are stated and, as far as this diff shows, empty: `continuation_cap: 2` is declared and read by nothing. My gate tallies below; I did not run `tests/run-tests.sh` and so did not independently reproduce the worker's 555/1 or its concurrency baseline claim. |

---

## 4. Gates I ran

Run from the worktree, alongside the coordinator's own chain.

| gate | result | wall time |
|---|---|---|
| `bash tests/lifecycle-readiness-tests.sh` | **286 passed, 0 failed**, exit 0 | 4m38s |
| `bash tests/lifecycle-dispatch-tests.sh` | **256 passed, 0 failed**, exit 0 | 3m27s |
| `git diff --check` | clean, exit 0 | — |
| `bash tests/run-tests.sh` | **not run** — the brief forbids it while the coordinator's chain holds this worktree | — |

The worker's reported `tests/run-tests.sh` red (section 8, lifecycle concurrency,
204/3) is therefore **not independently reproduced by me**. Nothing in this diff
touches locking, and the three named assertions are a publication-window scenario,
which is consistent with the recorded pre-existing baseline the record cites — but
that is an assessment from the diff, not a re-run.

## 5. Dev Agent Record (reviewer)

Review-only, as briefed. I modified no product code, no test, no doc and no story
record; I created only `REVIEW.md` and eight attack scripts under
`_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.5B-REVIEW/`. Scratch work
went to `/tmp/rev1.5b`. `tests/run-tests.sh` was not run.

Method: read the reviewer brief, then the review story, then the lane B story and
its Dev Agent Record, then the whole diff (`dispatch.sh` first, then monitor,
commands, policy, docs, tests). Every claim above is either quoted from the source
with a line number or produced by a script beside this file. Where a property could
not be reached without the section 3d harness — the end-to-end status decision — the
attack transcribes the conditionals verbatim and prints the source lines it
transcribed, so the transcription itself is checkable; that is weaker than an e2e
run and is labelled as such.

Convergence: one blocker, nine residuals, no re-opening of lane A's dispositioned
territory. I did not raise findings for the pre-existing `^NEEDS-HUMAN:` matching
shape, the `--limit 5000` terminal tail or the worker tool-set/gate tension beyond
the one line each needed to bound this lane's new consequences.
