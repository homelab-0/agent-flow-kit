---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-PORT-1.5D-FIX-1.md.stamp.override-derived.json
persona: dev
gates:
  - "bash tests/lifecycle-readiness-tests.sh"
  - "bash tests/lifecycle-dispatch-tests.sh"
  - "bash tests/lifecycle-tests.sh"
  - "git diff --check"
max_cycles: 1
payload_refs:
  - _bmad-output/implementation-artifacts/evidence/AFK-PORT-1.5D-REVIEW/REVIEW.md
---

# AFK-PORT-1.5D-FIX-1 — close the two lane-D review blockers

Fix the two blocker findings from the independent review of commit
`2b7b29fd3d2d149b65e427fd411f833bca5c86ab` against base
`32e94cc5e0b1c6991aabe1942c4f701b7e9c526e`. Work only in the existing
`jlengelbrecht/afk-port-1.5d` worktree. The review report named in
`payload_refs` is binding evidence.

## Required changes

1. **B1 — embedded credential refusal.** Make `afk_pm_secret_bearing` detect
   every supported credential shape anywhere inside a string value, including
   a ready-to-use `resume_instruction` command line. Refuse before writing and
   never echo the submitted value. Add a regression row proving an embedded,
   synthetic credential shape is refused and the prior artifact remains
   byte-identical.
2. **B2 — explicit-stamp reason precedence.** When an explicitly named PM stamp
   is unusable, preserve `PM_STAMP_UNUSABLE` even when the observation has
   `usage_tokens: null` or reports `PM_USAGE_CUMULATIVE_ONLY`. Add regression
   rows for both null-usage cases and prove no adapter/window fallback occurs.
3. **Commit hygiene.** Amend the lane-D commit so the final branch contains one
   implementation commit above the fixed base, with no `Co-Authored-By`,
   `Claude-Session`, session URL, or agent-attribution trailer. Preserve the
   substantive commit message.

## Hard boundaries

- Do not address R1–R12 from the review; they are backlog candidates, not this
  fix cycle.
- Do not modify the contract or PM skill unless a blocker fix genuinely makes
  their current binding text inaccurate; prefer no documentation change.
- Do not modify dispatch, cleanup, routing, or worker-watch behavior.
- Final product diff against `32e94cc5e0b1c6991aabe1942c4f701b7e9c526e`
  must remain at or below 800 added+changed lines across the same eight product
  files. Trade or compress test lines if necessary; do not request an exception.
- Use synthetic token shapes only. Never inspect, write, or print a real secret.
- Do not run the aggregate `tests/run-tests.sh`; the exact pre-fix commit already
  has retained aggregate evidence (766 passed, one tolerated baseline
  concurrency aggregate red). Run only the declared gates.

## Acceptance criteria

- The review's B1 reproduction is refused with exit 4, leaves the prior
  artifact byte-identical, and no submitted credential-shaped value appears in
  JSON, findings, human output, or stderr.
- An explicit unusable PM stamp reports `PM_STAMP_UNUSABLE` for numeric,
  cumulative-only, and otherwise unobservable usage observations; state and
  window source remain `NOT_EVALUATED`, and no observation window is adopted.
- Existing offset-zero secret refusal and numeric-usage unusable-stamp coverage
  remain green.
- All four declared gates pass.
- `git diff --numstat 32e94cc...HEAD` confirms at most 800 added+changed product
  lines across the same eight product files, and `git diff --check` is clean.
- `git log -1 --format=%B` contains no prohibited attribution/session trailer.

## Dev Agent Record

Persona proof `4cdff719c4f3042532520611f7106d80393173004355e6a83771b366c3efc7f9`
(intermediates `0bc44690…` / `ab52d884…`) — matches the brief.

Amended commit: `f61b9da2079a8ea89869cd083744161f582628b8`, one commit above
`32e94cc5e0b1c6991aabe1942c4f701b7e9c526e`. Files modified in this fix cycle:
`lib/afk-commands.sh`, `tests/lifecycle-readiness-tests.sh`,
`tests/lifecycle-dispatch-tests.sh`, `tests/lifecycle-tests.sh`.

### B1 — a credential anywhere in a value

`afk_pm_secret_bearing` matched four of its five shapes only at offset 0. Each
`^` became `(^|[^A-Za-z0-9_-])`, so the token shapes now match anywhere in a
value as the PEM alternative already did, while the boundary class still keeps
`sk-` inside an ordinary word (`risk-management-…`) from being read as a
credential. One changed line; the refusal still runs before the shape check and
before any write, so the value reaches no diagnostic.

Regression row in `tests/lifecycle-tests.sh`, beside the offset-zero row that
stays: a continuation whose `resume_instruction` is
`claude --resume PM --token sk-$SENTINEL` is refused with exit 4, the sentinel
appears in neither the result document nor stderr, no `continuation.json` is
written, and the atomicity block that follows still finds the accepted
checkpoint byte-identical to `$GOOD`.

### B2 — explicit-stamp reason precedence

The observation branch overwrote `reason` unconditionally on a usage-free
observation, erasing the `PM_STAMP_UNUSABLE` the stamp branch had set — which
is the variable the downstream arithmetic guard tests. Guarded the overwrite:
`if [[ "$usage" == "null" && "$reason" != "PM_STAMP_UNUSABLE" ]]`. One changed
line; nothing else in the hierarchy moved.

The unusable-stamp loop in `tests/lifecycle-readiness-tests.sh` became a cross
product of the two unusable stamp shapes (unresolvable catalog, failing shape
check) against three observations (numeric usage, `usage_tokens: null` with
`PM_USAGE_CUMULATIVE_ONLY`, `usage_tokens: null` with no reason). All six rows
assert `reason PM_STAMP_UNUSABLE`, `state NOT_EVALUATED`, `window_source
NOT_EVALUATED` and `window_tokens null` — so no adapter or window fallback
occurs in any of them. Six rows × four assertions replaced the old two × three.

### Line budget

The product diff is exactly 800 added+deleted across the same eight files —
unchanged from the pre-fix figure, no exception requested. Both code fixes land
on lines lane D had already added, so they cost nothing; the ~15 lines the new
regression rows cost were traded back by compressing lane-D test lines only:
multi-line `jq -nc` fixtures folded onto fewer lines (`pm_obs`, `pm_doc`, the
two AC-1 observation fixtures, the PM stamp fixture, the dispatch continuation
fixture), three comment blocks shortened by a line each, two long assertions
joined, and the reason-table loop's debug `printf` dropped in favour of its
counter. No assertion, case or acceptance criterion was removed — check counts
went up, not down.

### Gates

| Gate | Result | Wall time |
|---|---|---|
| `bash tests/lifecycle-readiness-tests.sh` | 359 passed, 0 failed (rc 0) | 5m42s (342s) |
| `bash tests/lifecycle-dispatch-tests.sh` | 274 passed, 0 failed (rc 0) | 3m33s (213s) |
| `bash tests/lifecycle-tests.sh` | 503 passed, 0 failed (rc 0) | 7m43s (463s) |
| `git diff --check 32e94cc HEAD` | clean (rc 0) | — |

Readiness 341 → 359 (+18 from the B2 cross product), lifecycle 499 → 503 (+4
from the B1 row), dispatch unchanged at 274. The aggregate suite was not run,
per the story's hard boundary; its pre-fix evidence stands.

### Scope

R1–R12 untouched. No change to the contract, the PM skill, dispatch, cleanup,
routing or worker-watch behavior — `git diff --numstat` shows the same eight
product files at the same paths, and `bin/agent-flow-kit`,
`docs/LIFECYCLE-CONTRACT.md`, `files/model-router/SKILL.md` and
`lib/afk-common.sh` are byte-identical to the pre-fix commit. The commit body
carries no `Co-Authored-By`, `Claude-Session`, session URL or tool banner; its
substantive engineering message is preserved verbatim. Nothing pushed, no PR
opened. Only synthetic credential shapes were used — the existing
`afk-sentinel-secret-DO-NOT-EMIT-…` fixture — and no real secret was read,
written or printed.
