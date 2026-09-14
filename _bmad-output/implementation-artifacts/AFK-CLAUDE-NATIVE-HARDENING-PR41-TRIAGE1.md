---
linear:
stamp: AFK-CLAUDE-NATIVE-HARDENING-PR41-TRIAGE1.md.stamp.json
persona: dev
gates:
  - "bash tests/run-tests.sh"
  - "shellcheck files/model-router/scripts/dispatch.sh files/model-router/scripts/verify-claude-evidence.sh"
  - "git diff --check origin/master...HEAD"
max_cycles: 1
---

# AFK-CLAUDE-NATIVE-HARDENING-PR41-TRIAGE1 — conflict and PR evidence round

PR #41 is open from `afk-claude-native-hardening` to `master` at
`d34a2dc7292b13f84c4811063c9f1ca6a3d1eae8`. GitHub currently reports one
merge conflict in `docs/LIFECYCLE-CONTRACT.md`. `master` advanced to
`77553236def86550e504fcc4bf2981dc5ba055b8`; its newer PM-continuation contract
overlaps the location where this branch added the offline Claude evidence
qualification contract.

This is PR-triage round 1. Work in the isolated child branch created for this
task. Fetch `origin`, merge the then-current `origin/master` into the child
branch without rebasing or force-pushing, and resolve only the genuine overlap.
Preserve both complete logical sections: the branch's offline Claude
result-envelope qualification contract and `master`'s PM-continuation contract.
Do not weaken, rewrite, or silently drop either contract. Remove all conflict
markers and keep the surrounding document structure coherent.

After the merge, compare `origin/master...HEAD` and verify that the feature diff
still represents the approved Claude settings preflight and offline verifier
work. No accidental product-code changes are authorized by conflict resolution.
Changes needed for a real CI or review finding may touch only the original PR
surface listed below; otherwise stop and report the needed expansion.

Run the declared gates. They are offline qualification and development checks,
not evidence that any model-provider launch path works. Do not invoke Claude,
Codex, another model, the router, ACP, or deployment runtime from the tests or
from ad hoc qualification. This routed development session itself is
implementation labor and is not launch-path qualification evidence.

If the gates pass, commit the merge resolution and any in-scope correction,
then push the child `HEAD` to `origin/afk-claude-native-hardening` without force.
Inspect PR #41 once after the push for current checks, review comments, and
threads. Evaluate every actual finding present in this round. Fix a valid
finding within the declared surface or reply with a concise technical reason
when no change is warranted. React to every actual Devin inline finding as the
repository policy requires. Do not treat Devin's green status as a completed
review when its details say the full review was skipped, and do not invent a
CodeRabbit review when none exists.

Any public GitHub text must contain no automation attribution or internal
workflow vocabulary and must read as plain engineering prose. Do not merge the
PR, enable auto-merge, deploy, activate, publish artifacts, modify branch
protection, or bypass a check.

## Authorized file surface

- `_bmad-output/implementation-artifacts/AFK-CLAUDE-NATIVE-HARDENING-R2.stamp.json`
- `_bmad-output/implementation-artifacts/AFK-CLAUDE-NATIVE-HARDENING.md.stamp.json`
- `_bmad-output/implementation-artifacts/deferred-work.md`
- `_bmad-output/implementation-artifacts/spec-claude-native-launch-hardening.md`
- `_bmad-output/implementation-artifacts/AFK-CLAUDE-NATIVE-HARDENING-PR41-TRIAGE1.md`
- `_bmad-output/implementation-artifacts/AFK-CLAUDE-NATIVE-HARDENING-PR41-TRIAGE1.md.stamp.json`
- `_bmad-output/implementation-artifacts/AFK-CLAUDE-NATIVE-HARDENING-PR41-TRIAGE1.route-request.json`
- `docs/LIFECYCLE-CONTRACT.md`
- `files/model-router/scripts/dispatch.sh`
- `files/model-router/scripts/verify-claude-evidence.sh`
- `tests/claude-evidence-tests.sh`
- `tests/fixtures/claude-evidence-expectations.json`
- `tests/fixtures/claude-evidence-result.json`
- `tests/run-tests.sh`

ACP and prox-ops are external, read-only dependencies for this task. Do not
change, push, comment on, or prepare patches in either project.

## Return

Write the normal thin result with: merged `origin/master` commit, resolution
summary, commit and push ref, gate counts, final feature diff paths and size,
current PR check/review state, every finding disposition, and precise blockers.
Distinguish local gate success from unavailable external review evidence.

