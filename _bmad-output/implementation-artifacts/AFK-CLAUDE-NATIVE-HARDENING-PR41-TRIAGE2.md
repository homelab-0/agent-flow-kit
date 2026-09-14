---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-CLAUDE-NATIVE-HARDENING-PR41-TRIAGE2.md.stamp.override-derived.json
persona: dev
gates:
  - "bash tests/run-tests.sh"
  - "nix shell nixpkgs#shellcheck --command shellcheck files/model-router/scripts/dispatch.sh files/model-router/scripts/verify-claude-evidence.sh"
  - "git diff --check origin/master...HEAD"
max_cycles: 1
---

# AFK-CLAUDE-NATIVE-HARDENING-PR41-TRIAGE2: conflict and PR evidence round

PR #41 is open from `afk-claude-native-hardening` to `master`. Its current head
is the commit containing this task. GitHub reports one merge conflict in
`docs/LIFECYCLE-CONTRACT.md`. At task creation, `origin/master` was
`77553236def86550e504fcc4bf2981dc5ba055b8`; fetch it again at execution time
and use the fetched commit as the actual merge input.

The overlap is between this branch's offline Claude result-envelope
qualification contract and `master`'s newer PM-continuation contract. Work in
the isolated child branch created for this task. Merge the then-current
`origin/master` into the child branch without rebasing or force-pushing.
Resolve only the genuine overlap and preserve both complete logical sections.
Do not weaken, rewrite, reorder into incoherence, or silently drop either
contract. Remove all conflict markers.

After the merge, compare `origin/master...HEAD` and verify that the feature diff
still represents the approved Claude settings preflight and offline verifier
work. Conflict resolution authorizes no accidental product-code change. A
correction for a real CI or review finding may touch only the authorized file
surface below. Stop and report any needed expansion.

Run the declared gates. They are offline development checks. They do not prove
that a provider, subscription, router, ACP runtime, or deployment launch path
works. Do not invoke Claude, another Codex session, another model, the router,
ACP, or deployment runtime from tests or ad hoc qualification. This routed
worker is implementation labor, not launch-path qualification evidence.

If the gates pass, commit the merge resolution and any in-scope correction,
then push the child `HEAD` to `origin/afk-claude-native-hardening` without
force. Inspect PR #41 once after the push for current checks, review comments,
and threads. Evaluate every actual finding present in this round. Fix a valid
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
- `_bmad-output/implementation-artifacts/AFK-CLAUDE-NATIVE-HARDENING-PR41-TRIAGE1*`
- `_bmad-output/implementation-artifacts/AFK-CLAUDE-NATIVE-HARDENING-PR41-TRIAGE2*`
- `docs/LIFECYCLE-CONTRACT.md`
- `files/model-router/scripts/dispatch.sh`
- `files/model-router/scripts/verify-claude-evidence.sh`
- `tests/claude-evidence-tests.sh`
- `tests/fixtures/claude-evidence-expectations.json`
- `tests/fixtures/claude-evidence-result.json`
- `tests/run-tests.sh`

ACP and prox-ops are external, read-only dependencies. Do not change, push,
comment on, or prepare patches in either project.

## Return

Write the normal thin result with: merged `origin/master` commit, resolution
summary, commit and push ref, gate counts, final feature diff paths and size,
current PR check/review state, every finding disposition, and precise blockers.
Distinguish local gate success from unavailable external review evidence.

## Routing

- Stamp: `_bmad-output/implementation-artifacts/AFK-CLAUDE-NATIVE-HARDENING-PR41-TRIAGE2.md.stamp.override-derived.json` (digest `sha256:3182bbdedfe3db29943e45286e1ff9b6f6269de7631a9024ad99b7b265586fbb`)
- Router decision: `claude / claude/strong / high`, deliberately overridden to the router-returned first fallback `codex / openai/strong / high`
- Override: Josh approved after the local Claude context overflow and the frozen Claude adapter's missing shell/GitHub/MCP capabilities; full profile fields come from the router response fallback
- Placement: not required; vendor profile
- Persona: `dev`
- Gates: aggregate offline suite, Nix ShellCheck, and feature-range whitespace check
- Post-development validation: verify scope, gate evidence, PR mergeability, check/review truthfulness, and absence of merge/deployment actions

