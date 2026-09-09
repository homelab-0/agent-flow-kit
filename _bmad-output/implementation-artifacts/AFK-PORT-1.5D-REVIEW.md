---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-PORT-1.5D-REVIEW.md.stamp.json
persona: dev
gates:
  - "bash tests/lifecycle-readiness-tests.sh"
  - "bash tests/lifecycle-dispatch-tests.sh"
  - "bash tests/lifecycle-tests.sh"
  - "git diff --check"
max_cycles: 1
---

# AFK-PORT-1.5D-REVIEW — independent adversarial + senior review

You are a fresh session and did not write this code. Review branch
`jlengelbrecht/afk-port-1.5d`, exact commit
`2b7b29fd3d2d149b65e427fd411f833bca5c86ab`, against `master` at
`32e94cc5e0b1c6991aabe1942c4f701b7e9c526e`. The binding spec is
`AFK-PORT-1.5D.md` (S1–S7, AC-1–AC-7, design ruling and hard stops), with the
frozen Story 1.5 and the named Capability 5 requirements as authority.

Use both adversarial and senior-engineering lenses. Review the full product
diff, not just the tests that pass.

## Attacks, in priority order

1. **Provided observation and window authority.** Malformed/absent/cumulative
   observations fail closed; provenance is never inferred; explicit usable
   stamp wins, explicit unusable stamp reports `PM_STAMP_UNUSABLE` and never
   falls through; adapter and `NOT_EVALUATED` branches are reachable.
2. **Policy arithmetic.** Thresholds have no hidden constant, use parts per
   million, and equality crosses both boundaries. An unreadable policy is loud.
3. **Artifacts.** Both schemas are closed enough to enforce thin state;
   dispatch ids are strings, secret-looking members/values are refused without
   disclosure, writes are atomic and owner-only, and invalid reads do not
   create or clear a condition.
4. **Loud handoff, no launcher.** Ratio or outstanding continuation produces
   one owner-action finding with path, digest and verbatim resume instruction;
   the operator is sent to Orca. Prove no PM path launches a session, directly
   or indirectly.
5. **Reconciliation and isolation.** A human-started successor is recorded from
   the declared source, count increments exactly once, replay is idempotent,
   and active worker watches/deliveries/resources are byte-identical.
6. **Contract, vocabulary, hygiene.** JSON and human shapes agree; every reason
   has one specific message/action; docs and the PM-facing skill match the code;
   no Story 1.6 vocabulary or Story 1.8 adapter appeared; forbidden paths and
   frozen launch text are unchanged; the product diff is exactly 800 lines over
   eight declared files and the commit has no attribution trailers.

## Rules

The blocker bar is conjunctive: a finding must violate a binding requirement or
AC, be reproduced, and be reachable naturally or through one ordinary operator
action. Otherwise record it as residual. Do not modify product code, tests,
docs, the lane-D story, or git state. Write only under
`_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.5D-REVIEW/` and the
Dev Agent Record below. Scratch work belongs under `/tmp`. Do not run the full
aggregate suite; the coordinator already retained its 2,662-second evidence.
No secrets and no external side effects.

## Report shape

Write `evidence/AFK-PORT-1.5D-REVIEW/REVIEW.md` with:

1. `AFK-PORT-1.5D REVIEW: CLEAN` or
   `AFK-PORT-1.5D REVIEW: NOT CLEAN — <n> blocker(s)` as the first line.
2. Blockers with requirement, reproduction, reachability and minimal fix.
3. Residuals and disclosed-item assessments.
4. An AC-1–AC-7 evidence table.
5. Gate/probe tallies and wall times.

## Dev Agent Record

**Verdict.** `AFK-PORT-1.5D REVIEW: NOT CLEAN — 2 blockers.` Report:
`evidence/AFK-PORT-1.5D-REVIEW/REVIEW.md`.

**Persona proof.** Outer
`4cdff719c4f3042532520611f7106d80393173004355e6a83771b366c3efc7f9`, intermediates
`0bc44690f0dc7fdeaabd763efd3ead4b2e8bb8b3a8d5437140605a544b39bb1f` and
`ab52d8840427e10d5956b592c34e63edc77ebdafd7b54ce60da11cf67ed72ced` — all three
match the brief. Worktree at `2b7b29f`, compared with `32e94cc`.

**Blockers.**

- **B1** `afk_pm_secret_bearing` anchors four of its five credential shapes to
  offset 0, so a credential embedded in a value is accepted — and
  `resume_instruction`, a command line by contract, is the member where a
  credential can never be at offset 0. The accepted artifact is then echoed
  verbatim in `next_safe_action`, the finding detail, the JSON result and the
  human rendering on every `status` and `monitor`. Against S3 and attack 3, and
  it fails open rather than closed. Fix: drop the `^` anchors.
- **B2** In `afk_pm_apply` the observation branch overwrites
  `reason="PM_STAMP_UNUSABLE"` whenever the observation reports no usage figure,
  so an explicitly named unusable stamp is reported as `PM_USAGE_UNOBSERVABLE`
  or `PM_USAGE_CUMULATIVE_ONLY` with the wrong remedy. Against the story's
  binding design ruling and the contract text shipped in this same diff. Fix:
  guard the overwrite on `"$reason" != "PM_STAMP_UNUSABLE"`.

Both are untested rows inside cases the suites do cover, which is why 1,114
green assertions did not catch them.

**Residuals.** Twelve, in the report: checkpoint never validated on read (R1);
`*_tokens` member names falsely refused (R2); `PM_ARTIFACT_SECRET_BEARING`
published with no producer (R3); `launcher.budget_policy` never consulted, the
one residual that fails quietly (R4); `AFK_PM_SESSION` read but undeclared (R5);
`pm/budget-state.json` replaced rather than merged (R6); threshold ppm computed
in awk rather than by exact parse (R7); quoted policy scalar unreadable (R8);
`window_source` vocabularies disjoint across the two budget blocks (R9);
`next_safe_action` precedence on monitor (R10); attribution trailers to keep out
of the squash message (R11); artifact schemas open to fat members (R12).

**What holds.** The window hierarchy's three branches, boundary equality at
699999/700000 and 849999/850000, the atomic 0600 write and byte-identical disk
after refusal, reconciliation with correct provenance and idempotent replay,
worker watches structurally untouched, no launch path on any PM line, the eight
declared files, exactly 800 added+changed lines, and a clean `git diff --check`.

**Gates.** `lifecycle-readiness` 341/0, `lifecycle-dispatch` 274/0,
`lifecycle` 499/0, `git diff --check` clean — all rc 0. The aggregate suite was
not run, per the brief.

**Limits observed.** No product code, test, doc, lane-D story or git state was
modified; writes are confined to `evidence/AFK-PORT-1.5D-REVIEW/` and this
record. Probes ran on throwaway HOMEs under the session scratchpad with
synthetic token shapes only; no real credential was used, written or printed.
