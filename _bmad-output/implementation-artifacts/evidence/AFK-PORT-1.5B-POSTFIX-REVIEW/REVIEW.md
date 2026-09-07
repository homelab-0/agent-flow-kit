# AFK-PORT-1.5B-POSTFIX-REVIEW: CLEAN

Diff-scoped review of `e2f3e92` against its parent `54dfd14` on
`jlengelbrecht/afk-port-1.5b` — the bounded fix cycle `AFK-PORT-1.5B-FIX.md`
(F1–F8) answering `evidence/AFK-PORT-1.5B-REVIEW/REVIEW.md` (BLK-1,
RES-1…RES-9).

**Verdict: CLEAN — 0 blockers.** BLK-1 is fixed at the channel rather than at
the filter, and each of the nine residuals is either fixed or explicitly
bounded and documented. Four new residuals are recorded below; none meets the
blocker bar (a frozen requirement or an AC, reproduced, and reachable).

Persona proof (computed first, before any file was opened):
`{ sha256sum .agents/skills/bmad-agent-dev/SKILL.md; sha256sum
.agents/skills/bmad-agent-dev/customize.toml; } | sha256sum` →
`07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee` — matches
the expected OUTER hash.

Probes live beside this file and are runnable from the worktree
(`AFK_REVIEW_ROOT` defaults to the git toplevel). Every probe sources the real
`dispatch.sh` and calls the real functions; where a decision lives inline in
`main` rather than in a function, the probe prints the live source of the
branch it transcribes so the walk cannot drift from the code.

| probe | covers |
|---|---|
| `atk-f1-reason-channel.sh` | F1 / BLK-1 — the reason's content reaches nothing |
| `atk-f1-mutation.sh` | F1 anti-vacuity — the same sentinels under `54dfd14` |
| `atk-f2-precedence.sh` | F2 / RES-1 — the full signal × gates × ratio matrix |
| `atk-f3-checkpoint-freshness.sh` | F3 / RES-2 — checkpoint freshness |
| `atk-f4-adapter.sh` | F4 / RES-3, RES-4 — adapter honesty and corroboration |
| `atk-f5-f6-prompt-signal.sh` | F5 / RES-5, RES-7 and F6 / RES-6 |
| `atk-f7-sweep.sh` | F7 / RES-9 — the unpublished-reason sweep |
| `atk-surface-frozen.sh` | frozen launch texts, diff surface, commit hygiene |

---

## 2. Per item

### F1 / BLK-1 — the continuation reason never carries worker free text — **VERIFIED**

`artifact_redact` and the `BUDGET_REDACT_FN` indirection are gone from the
source, and nothing references them anywhere in the kit (the only remaining
hits are the review and record prose that describes their removal):

```
=== A. artifact_redact / BUDGET_REDACT_FN gone? ===
ABSENT artifact_redact
no references in dispatch.sh
```

The reason's content now reaches nothing. `dispatch.sh` reads the signal line
once (line 1474), derives `summary` from it (1477), and from then on only
`summary` travels — to the `.blocked` marker (1497) and to the log (1506).
There is no third use of `$signal`; the grep in the probe enumerates every
site. `record_budget_line` carries the artifact sha, not the reason.

Adversarial reasons, real function, real output:

```
hunter2                                        -> reason_given=true reason_bytes=7  reason_words=none
password=Tr0ub4dor&3                           -> reason_given=true reason_bytes=20 reason_words=none
xoxb-2f9a:8c1d-77aa-9e0f                       -> reason_given=true reason_bytes=24 reason_words=none
eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJhIjoxfQ.sig -> reason_given=true reason_bytes=51 reason_words=none
AKIAIOSFODNN7EXAMPLE                           -> reason_given=true reason_bytes=20 reason_words=none
context exhausted, the token was sk-live-9f2a… -> reason_given=true reason_bytes=57 reason_words=context
*                                              -> reason_given=true reason_bytes=1  reason_words=none
$(id)  /  `id`  /  ${PATH}                     -> reason_words=none  (no expansion, no execution)
```

What *is* recorded cannot encode the secret. `reason_given` is a boolean;
`reason_bytes` is a length; `reason_words` prints the **vocabulary term**, never
the caller's bytes — the input is lowercased and stripped to `[a-z]` in the
shell before the `case`, and the `case` echoes `$w` only on a literal match
against the eleven-plus-twelve closed set:

```
[Context,]  -> [context]     [c0ntext]  -> []
[CONTEXT]   -> [context]     [contextual] -> []
[con-text]  -> [context]     [hunter2]  -> []
```

`con-text → context` is the only surprise and it is not a leak: the output is
the vocabulary term. The upper bound on what a hostile reason can push through
this channel is *which* of ~23 fixed English words it contained.

**Anti-vacuity, by mutation against the previous commit.** The old
`artifact_redact` restored in a scratch copy of `54dfd14`, fed the same
sentinels the new AC-5 block asserts absent:

```
sentinel=hunter2                    -> LEAKS      (new assert_absent would FAIL here)
sentinel=password=Tr0ub4dor&3       -> LEAKS      (new assert_absent would FAIL here)
sentinel=xoxb-2f9a:8c1d-77aa-9e0f   -> LEAKS      (new assert_absent would FAIL here)
sentinel=sk-live-9f2a4c7e1b8d3550…  -> masked by the 24-char denylist
```

Three of the four new sentinels fail against the parent commit, so the new
assertions are load-bearing and not satisfied by an absent code path. The
suite's own controls are honest too: it asserts `reason_given=true`,
the *exact* byte length of the sentinel-bearing reason, and
`reason_words=context` — all three derived from the very line asserted absent.

### F2 / RES-1 — a finished run is never `CONTINUATION_REQUIRED` — **VERIFIED**

Conditionals re-transcribed from the live source (printed by the probe) and
walked over all 28 rows of signal × gates × ratio, with the shipped thresholds
(checkpoint 700000 ppm, continuation 850000 ppm):

```
sig=no  gates=pass usage=850000       status=done                  budget.state=CHECKPOINT_DUE        findings=[HIGH_USAGE]
sig=no  gates=pass usage=999999       status=done                  budget.state=CHECKPOINT_DUE        findings=[HIGH_USAGE]
sig=no  gates=fail usage=849999       status=gates_failed          budget.state=CHECKPOINT_DUE        findings=[HIGH_USAGE]
sig=no  gates=fail usage=850000       status=continuation_required budget.state=CONTINUATION_REQUIRED findings=[HIGH_USAGE]
sig=yes gates=pass usage=100000       status=continuation_required budget.state=CONTINUATION_REQUIRED findings=[]
sig=yes gates=pass usage=999999       status=continuation_required budget.state=CONTINUATION_REQUIRED findings=[HIGH_USAGE]
…
MATRIX: no violation
```

- No row publishes `CONTINUATION_REQUIRED` beside `status: done`.
- A worker signal is never demoted: all 14 `sig=yes` rows keep
  `CONTINUATION_REQUIRED`, because the demotion is guarded on
  `-z "$RESULT_STATUS"`.
- The demotion is bounded to a state *computed from a ratio* and lands on what
  the checkpoint rule says about the same ratio; the boundary rows (699999 /
  700000 / 849999 / 850000) all sit where the thresholds put them.
- The contract table carries both rows (`LIFECYCLE-CONTRACT.md:1196-1197`),
  and the prose rule is stated at 1137-1142.

### F3 / RES-2 — checkpoint freshness — **VERIFIED**

`CHECKPOINT_BEFORE` is captured pre-launch beside `CONTINUATION_BEFORE`
(dispatch.sh:1243-1245) and compared after the run (1453-1458). Walked over
real files with the real `artifact_verdict` / `sha256_of` / `artifact_identity_json`:

```
CONTROL cycle1: first checkpoint (nothing before)     verdict=VALID                     published=yes findings=[]
cycle2: identical file after the run                  verdict=CHECKPOINT_ARTIFACT_STALE published=no  findings=[CHECKPOINT_ARTIFACT_STALE]
CONTROL cycle2': a freshly written checkpoint         verdict=VALID                     published=yes findings=[]
CONTROL: an unchanged INVALID checkpoint              verdict=ARTIFACT_SCHEMA_MISMATCH  published=no  findings=[CHECKPOINT_ARTIFACT_INVALID]
```

A stale checkpoint is a finding and not a refusal — consistent with the
existing treatment of an invalid one — and no `checkpoint_artifact` identity is
published for a file this worker did not write. The fourth row is the control
that matters: staleness is checked only *after* validity, so an invalid
checkpoint is still reported as invalid rather than being masked as stale. The
code is published in `context-budget-policy.yaml:48` and mirrored in
`lib/afk-commands.sh:893`.

### F4 / RES-3, RES-4 — the adapter reports only what it saw — **VERIFIED**

Observability:

```
usage:{output_tokens:9999}  -> USAGE_UNOBSERVABLE, usage_tokens null
usage:{} / absent / null / a string -> USAGE_UNOBSERVABLE
CONTROLS: input_tokens only -> 7   cache_read only -> 42   cache_creation only -> 5
CONTROL: a genuine input_tokens:0 -> HARNESS_ENVELOPE, usage_tokens 0
```

The last control is the one that proves the fix is not a blunt "reject zero":
a *published* zero is still an observation, while a `usage` object carrying
none of the three members is not.

Corroboration:

```
one non-matching modelUsage entry, asking for opus  -> window_tokens null
CONTROL: the matching key IS read                   -> window_tokens 200000
two entries, exact key present                      -> 200000
two entries, no key match                           -> null
no modelUsage at all                                -> null
single-entry fallback still in the source?  ABSENT — no single-entry fallback
```

`WINDOW_UNCORROBORATED` is raised exactly where an observation happened but no
window came back, and is bounded away from runs that observed nothing:

```
observed, no window                 -> findings=[WINDOW_UNCORROBORATED]
CONTROL: agreeing window            -> findings=[]
CONTROL: disagreeing window         -> findings=[WINDOW_DISAGREEMENT]
CONTROL: codex (nothing observed)   -> findings=[]
CONTROL: unobservable claude        -> findings=[]
```

The contract states both rules (1111-1128) and the code is published.

### F5 / RES-5, RES-7 — the paragraph and the empty signal — **VERIFIED**

The paragraph carries the harness-pressure trigger (it wraps across a line, so
it reads *"or when the harness signals\ncontext pressure"* — the suite's needle
`"or when the harness signals"` is the correct one), is byte-stable across
calls for the same story (sha256
`d218c8764c60fff8f438538d985a6aa91660904c452a03bf51ca0bcae19c92d6` for
`/wt/S.md`), and is still parameterised by the story path. It still names no
threshold.

An empty reason takes the invalid-signal path *before* the evidence is read:

```
[CONTINUATION-REQUIRED:]              -> reason_given=false … verdict=SIGNAL_REASON_EMPTY
[CONTINUATION-REQUIRED: ]             -> reason_given=false … verdict=SIGNAL_REASON_EMPTY
[CONTINUATION-REQUIRED:   <tab> ]     -> reason_given=false … verdict=SIGNAL_REASON_EMPTY
[CONTINUATION-REQUIRED: out of room]  -> reason_given=true reason_bytes=11 (evidence is checked)
```

Whitespace-only is treated as empty, which is right. On that path `dispatch.sh`
writes the `.blocked` marker with `detail=SIGNAL_REASON_EMPTY`, renames the
terminal, and dies with `EX_NEEDS_HUMAN` — **no result artifact at all**, which
the suite asserts with `assert_no_file`.

### F6 / RES-6 — anchored and documented — **VERIFIED**

The `^CONTINUATION-REQUIRED:` anchor is unchanged, as authorized. The paragraph
now says *"never begin a line with it unless you are actually stopping, because
a line that starts with it is read as the signal whatever the rest of the line
says"*, and the contract records the bounded codex tail as a known limitation
(`LIFECYCLE-CONTRACT.md:1181-1187`), matching the actual read
(`dispatch.sh:342`, `--limit 5000`). Recorded, not fixed — which is what the
fix story authorized.

### F7 / RES-8, RES-9 — contract and sweep hygiene — **VERIFIED**

`needs_human` is documented as delivery-only at `LIFECYCLE-CONTRACT.md:1226-1232`,
naming both the producer that reports it and the path on which `dispatch.sh`
deliberately writes no result. No rename, no schema-major change — the right
call.

The readiness sweep now collects `.usage_reason?` alongside `.reason?`, with its
own falsifiability control:

```
published usage_reason   -> unpublished=0
invented  usage_reason   -> unpublished=1
CONTROL invented .reason -> unpublished=1
```

### F8 — post-review registry — **VERIFIED**

`AFK-PORT-1.5B.md` gains `### Post-review fix cycle (AFK-PORT-1.5B-FIX)` with a
disposition for BLK-1 and each of RES-1…RES-9, a "Deferred, deliberately, and
disclosed" section naming three items with diagnoses, and the cycle's gate
tallies. The record states plainly that a commit cannot carry its own hash and
leaves the SHA to the coordinator.

### Frozen texts and surface — **VERIFIED**

```
build_claude_command     master=d5d6a372d026 head=d5d6a372d026  IDENTICAL
build_codex_command      master=5380eefd876a head=5380eefd876a  IDENTICAL
```

Diff surface is seven files, all inside the fix story's declared surface:
`AFK-PORT-1.5B.md`, `docs/LIFECYCLE-CONTRACT.md`,
`files/model-router/context-budget-policy.yaml`,
`files/model-router/scripts/dispatch.sh`, `lib/afk-commands.sh`,
`tests/lifecycle-readiness-tests.sh`, `tests/run-tests.sh`. No lane C/D file,
no `make-stamp.sh`, no validator, no catalog.

Commit message is plain prose with no trailers, no AI attribution and no
internal-process vocabulary. `git diff --check` is clean on the working tree
and over `master...HEAD`.

---

## 3. New blockers and residuals

**New blockers: none.** Nothing in this diff meets the bar (a frozen
requirement or an AC, reproduced, and reachable).

### RES-P1 — the `NEEDS-HUMAN:` channel still writes worker free text verbatim (low, pre-existing, out of diff scope)

`dispatch.sh:1425` writes the worker's own `NEEDS-HUMAN:` line into
`${STORY}.blocked` unfiltered. This is the frozen channel the
`CONTINUATION-REQUIRED:` anchor was deliberately made to mirror, it is
untouched by this diff, and the discipline paragraph tells the worker its
artifacts must be secret-free — but the F1 argument (a credential is not
distinguishable from a typo by shape) applies to it word for word. Recorded for
the coordinator as the natural next place for the same treatment, not as a
finding against this cycle.

### RES-P2 — the sweep union weakens the readiness `.reason` check (low)

`PUB_ALL_REASONS` is the union of both vocabularies and is applied to both
members, so a *budget* code appearing in a readiness `.reason` now passes a
sweep that would previously have caught it:

```
readiness .reason = HIGH_USAGE (a BUDGET code) -> unpublished=0
  under the pre-fix set it would be            -> 1
```

The suite documents the trade-off in its own comment ("the sweep asks whether
the kit published the code, not which producer emitted it"), and the sweep's
real job — catching an *unpublished* code — is intact and controlled. Sweeping
each member against its own set would close it without cost.

### RES-P3 — the `OK` arm of the F2 demotion is unreachable under the shipped policy (informational)

`load_budget_policy` does not assert `checkpoint_ratio <= continuation_ratio`,
so the demotion's `else BUDGET_STATE="OK"` arm exists to be correct under a
policy that inverts them. With the shipped 0.70 / 0.85 it can never be taken.
Defensive rather than wrong; noted so a later reader does not mistake it for a
live path.

### RES-P4 — the reviewer brief names a HEAD this worktree does not have (informational, process)

The brief states HEAD `daa00e9`; the worktree is at `e2f3e92` on
`jlengelbrecht/afk-port-1.5b`, which *is* the commit the review story names as
its scope. The review was performed against `e2f3e92` vs `54dfd14` as the story
specifies. Flagged so the coordinator can correct the brief's provenance line.

---

## 4. Gate tallies (run by this reviewer, in this worktree)

| gate | result |
|---|---|
| `bash tests/lifecycle-readiness-tests.sh` | **290 passed, 0 failed** (exit 0) |
| `bash tests/lifecycle-dispatch-tests.sh` | **256 passed, 0 failed** (exit 0) |
| `bash tests/lifecycle-tests.sh` | **478 passed, 0 failed** (exit 0) |
| `git diff --check` | clean, exit 0 (working tree and `master...HEAD`) |
| `bash tests/run-tests.sh` | **not run** — the coordinator's gate chain owns it in this worktree |

Nothing outside
`_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.5B-POSTFIX-REVIEW/`
was created or modified; `git status --porcelain` shows no tracked file
changed and no new untracked path beyond this directory. Scratch work was done
under `/tmp` and removed by the probes that made it.

## Dev Agent Record

Reviewer: fresh claude session, BMAD dev persona, route `{claude, claude/strong,
effort medium}`, stamp
`_bmad-output/implementation-artifacts/AFK-PORT-1.5B-POSTFIX-REVIEW.md.stamp.json`
(digest `sha256:f85e85a47b75eae733d40bcbfc9b77be51a0f3faff31034f12bd2937c175427a`).
Persona proof computed before any file was read and matched the expected outer
hash. Review-only: no product code, test, doc, record or git state was touched.
Eight probe scripts written, each with its controls; the F1 finding was checked
for anti-vacuity by restoring the parent commit's behaviour in a scratch copy.
