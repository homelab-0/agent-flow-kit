AFK-PORT-1.5D POST-FIX REVIEW: CLEAN

Independent closure review of exact commit
`da1c7bf1448898a6d36bacf7eaae0949bdadfb53` against base
`32e94cc5e0b1c6991aabe1942c4f701b7e9c526e`. I authored no lane-D code and no
fix. Persona proof
`4cdff719c4f3042532520611f7106d80393173004355e6a83771b366c3efc7f9`
(intermediates `0bc44690…` for `SKILL.md`, `ab52d884…` for `customize.toml`) —
computed here, matches the brief.

Both blockers are closed. I reproduced each one against the fixed code, and
then reproduced each against a scratch copy of the tree with only the two fixed
lines reverted, so the closure is demonstrated rather than asserted and the two
new regression rows are demonstrably load-bearing. The fix is two lines of
product code; nothing else in `lib/`, `bin/`, the contract or the skill moved.
The path boundary fix-2 was dispatched for holds: `tests/lifecycle-dispatch-tests.sh`
is byte-identical to `2b7b29f`. The budget is exactly at 800, the branch is one
attribution-free commit above base, and all four declared gates are green.

## Blocker closure

### B1 — a credential anywhere in a value is refused, and never echoed

Evidence: `B1-embedded-credential.txt`, `regression-rows-non-vacuity.txt`.

Every supported family, placed behind a flag rather than at offset 0, is now
refused with exit 4 before anything is written: `sk-`, `rk-`, `ghp_`, `gho_`,
`ghu_`, `ghs_`, `github_pat_`, `xoxb-`, `AKIA`, and the PEM header that always
matched anywhere. The other ordinary separators are covered too — a value after
`=`, an env-prefixed command line, a credential inside a URL after `:`. In every
case the submitted value appears in neither the JSON result, the finding detail,
the human rendering nor stderr; `pm/continuation.json` is not created; the
already-accepted `pm/checkpoint.json` is byte-identical afterwards; and no
`.afk-tmp` residue is left under `pm/`. The human-mode refusal prints one
sentence that names no value.

The boundary class keeps ordinary text out of the credential branch:
`risk-management-framework-v2` and `a-task-management-system-note` are still
accepted, so the widening did not turn every hyphenated word into a secret.

Non-vacuity: with the pre-fix pattern restored in a `/tmp` copy, the exact value
the new regression row submits is accepted with exit 2, `continuation.json` is
written, and the value comes back twice — once in `next_safe_action` and once in
the finding detail. That is the original B1, reproduced on demand.

### B2 — an explicitly named unusable stamp keeps its reason

Evidence: `B2-stamp-precedence.txt`, `regression-rows-non-vacuity.txt`.

Both unusable stamp shapes (a well-formed stamp whose profile the catalog cannot
resolve, and a stamp that fails the shape check) against all three usage shapes
(numeric, `usage_tokens: null` with `PM_USAGE_CUMULATIVE_ONLY`, and
`usage_tokens: null` with no reason) give six rows of
`reason=PM_STAMP_UNUSABLE`, `state=NOT_EVALUATED`, `window_tokens=null`,
`window_source=NOT_EVALUATED`. The observation carried a different window (999)
throughout, so "no adapter fallback" is proved rather than coincidental. A
`--pm-stamp` pointing at a path that does not exist behaves the same way. The
human rendering now names `PM_STAMP_UNUSABLE`, so the operator is pointed at the
stamp and the catalog instead of at a checkpoint they cannot take.

The guard does not over-apply, which is the risk a `!=` on a shared variable
carries. Without a stamp, a cumulative-only observation still reports
`PM_USAGE_CUMULATIVE_ONLY` and a usage-free one `PM_USAGE_UNOBSERVABLE`, both
banding off the adapter window. With a *usable* stamp the same two observations
keep their own reasons with `window_source=STAMP`, and numeric usage still runs
the arithmetic (`150000/200000` → `CHECKPOINT_DUE`, ratio `0.750000`). Boundary
equality is untouched: 699999 `OK`, 700000 `CHECKPOINT_DUE`, 849999
`CHECKPOINT_DUE`, 850000 `CONTINUATION_REQUIRED`.

Non-vacuity: pre-fix, the two null-usage rows report
`PM_USAGE_CUMULATIVE_ONLY` and `PM_USAGE_UNOBSERVABLE` — the reason the new rows
assert against.

## The changes themselves

Minimal, and confined. `git diff 2b7b29f da1c7bf` is 2 changed lines in
`lib/afk-commands.sh` plus the two test files:

- the four `^` anchors became `(^|[^A-Za-z0-9_-])`, matching the PEM
  alternative's existing anywhere-semantics;
- the observation branch's overwrite gained `&& "$reason" != "PM_STAMP_UNUSABLE"`,
  which is the same variable the downstream arithmetic guard already tested.

Existing coverage is retained, not traded: the offset-zero row
(`note:"sk-$SENTINEL"`) still stands beside the new embedded row, and the
numeric-usage unusable-stamp case survives as one of the six cross-product rows.
The B2 loop grew from 2×3 assertions to 6×4 and added `window_source`, which is
the assertion that closes the fallback question directly. Both new blocks fail
against the pre-fix code, so neither is decorative.

`tests/lifecycle-readiness-tests.sh` also lost one debug `printf` inside the
reason-table sweep (disclosed in the fix-1 record's line-budget section); the
assertion it fed still runs, but a future failure will report a count without
naming the offending code. Recorded below, not blocking.

## Scope, budget and commit

Evidence: `residuals-and-ac-recheck.txt`.

- `git diff 2b7b29f da1c7bf -- tests/lifecycle-dispatch-tests.sh` is empty:
  byte-identical, as fix-2 was dispatched to restore.
- Product diff against base: 793 added, 7 deleted, 800 added+changed across
  exactly the eight declared files. No ninth product path. The only other
  changed file is the lane story itself.
- `docs/LIFECYCLE-CONTRACT.md`, `files/model-router/SKILL.md`,
  `bin/agent-flow-kit` and `lib/afk-common.sh` are byte-identical to the pre-fix
  commit, so the documentation the previous review read is the documentation
  that shipped.
- Hard stops untouched: no `dispatch.sh`, `make-stamp.sh`, validator, catalog,
  `afk-monitor.sh` or `afk-mutate.sh` in the changed-file list.
- One commit above base, authored and committed by
  `jlengelbrecht <jlengelbrecht96@gmail.com>`, message free of
  `Co-Authored-By`, `Claude-Session`, session URLs and tool banners. The
  worktree carries no tracked modifications.

## Acceptance criteria

| AC | Verdict | Evidence |
|---|---|---|
| AC-1 observation contract; provenance recorded | pass | Unparseable, provenance-less and unread-schema observations each land `NOT_EVALUATED` / `PM_USAGE_UNOBSERVABLE` with no window adopted; adapter and cumulative-only branches reproduced in the B2 matrix. |
| AC-2 `pm_budget`, three-branch hierarchy, policy thresholds | pass | STAMP / ADAPTER / `NOT_EVALUATED` all reached; boundary equality exact at 699999/700000 and 849999/850000; B2 no longer erases the stamp's reason. |
| AC-3 artifacts validated, redacted, atomic | pass | Ten families refused at an embedded boundary plus three separator shapes, none echoed, accepted artifact byte-identical, no temp residue. B1 closed. |
| AC-4 loud `PM_CONTINUATION_REQUIRED`; no launch path | pass | Owner-action finding carries the resume instruction verbatim, `next_safe_action` sends the human to Orca, exit 2; no launcher call appears on any added line of `bin/` or `lib/`. |
| AC-5 reconcile clears, records, counts; watches untouched | pass | Successor `PM-2` recorded with the artifact digest, count 0→1, replay left it at 1, condition cleared. |
| AC-6 documented in the skill and the contract | pass (R3 stands) | Both documents byte-identical to the reviewed pre-fix state; the contract's reason block still matches `afk_pm_reason_codes` exactly. |
| AC-7 gates green; ≤ 800 lines; 1.6 seam named | pass | Four declared gates green below; 800 added+changed over the eight files; `git diff --check` clean. |

## Residual disposition

R1–R12 from the first review were neither silently changed nor promoted into
this fix. I re-ran the ones with a runtime signature rather than trusting the
diff: R1 (a corrupt `pm/checkpoint.json` still reads back as a present artifact
with a digest and no complaint), R2 (`budget_state` carrying `window_tokens` /
`usage_tokens` is still refused as secret-bearing), R3 (a secret refusal still
exits 4 with no result document and no `PM_ARTIFACT_SECRET_BEARING` on the
wire), R4 (the kit still reads no launcher config), R5 (`AFK_PM_SESSION`
exported still fails `status` with exit 1 and is still absent from the usage
block), and R12 (a `transcript` and an `evidence_body` are still accepted and
written verbatim). R6–R11 live in code byte-identical to the reviewed commit —
`afk_pm_reconcile` still writes a fresh `budget-state.json` rather than merging.

Four new items, all below the blocker bar:

- **N1 — a credential glued directly to `-`, `_` or an alphanumeric is still
  accepted.** `--token-sk-…`, `--token_sk-…`, `PREFIXghp_…` and `-x-AKIA…` pass
  the shape check, because the new boundary class excludes exactly those
  characters. Every ordinary way a command line separates a flag from its value
  — space, `=`, `:`, `/`, a quote, start-of-string — is covered, so this needs a
  command line no operator writes. Reproduced, requirement-relevant, but not
  ordinarily reachable: residual, not a blocker. Worth a line in the backlog
  beside R2, since the two are the same trade-off from opposite sides.
- **N2 — the widened pattern widens the false accusations too.** A decision
  reading `adopted the sk-management-of-risk plan` or
  `see rk-review-of-the-quarter notes` is now refused with exit 4 and told to
  remove a secret-bearing member. Fails closed and loud, so it costs a
  coordinator a retry rather than a leak — the same class as R2, and the same
  fix would serve both.
- **N3 — the reason-table sweep lost its per-code diagnostic.** Disclosed in
  fix-1. A future failure reports `BAD` as a count, not the code that caused it.
- **N4 — an expired but well-shaped PM stamp still resolves a window.**
  `--pm-stamp` with `expires_at: 2020-01-01` gives `window_source=STAMP` and
  bands normally. The contract binds this branch to "the same stamp-shape check
  every other stamp gets", and expiry is the validator's refusal rather than the
  shape check's, so this is consistent with what shipped — recorded because a
  reader of `pm_budget` may assume more freshness than the member carries.

## Gates

Evidence: `gates.txt`. Run at `da1c7bf`, sequentially, in this worktree.

| Gate | Result | Wall time |
|---|---|---|
| `bash tests/lifecycle-readiness-tests.sh` | 359 passed, 0 failed (rc 0) | 343s |
| `bash tests/lifecycle-dispatch-tests.sh` | 274 passed, 0 failed (rc 0) | 214s |
| `bash tests/lifecycle-tests.sh` | 503 passed, 0 failed (rc 0) | 464s |
| `git diff --check 32e94cc da1c7bf` | clean (rc 0) | — |

The aggregate suite was not run. Adversarial probes ran against
`bin/agent-flow-kit` directly, outside the suites, on throwaway HOMEs under
`/tmp`: the ten token families, three separator shapes and four glued shapes for
B1; the six-row stamp matrix plus eight adjacent stamp/observation shapes for
B2; the residual and acceptance-criteria re-runs; and the pre-fix simulation.
Synthetic token shapes only — no real credential was read, written or printed,
and nothing outside this evidence directory and the review story's Dev Agent
Record was modified.
