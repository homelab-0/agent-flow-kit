# Reviewer brief — AFK-PORT-1.5A-REVIEW (fresh claude session, Orca-supervised)

You are a dispatched REVIEWER under Orca supervision, launched in the lane A
worktree (`afk-port-1.5a`, branch `jlengelbrecht/afk-port-1.5a`, HEAD
`daa00e9`). Route/stamp: `{claude, claude/strong, effort medium}` (recorded
override: reviewer model must be at least the implementer's),
`_bmad-output/implementation-artifacts/AFK-PORT-1.5A-REVIEW.md.stamp.json`,
digest `sha256:90f61f6c657c7aeee0487ec8d0cab2bca8e6dfb5c0a30b8e1f0a0a85c931f2b5`, validated fail-closed by the coordinator immediately
before your launch.

## Persona (fail-closed)

BMAD DEV persona from `.agents/skills/bmad-agent-dev/SKILL.md` + `customize.toml`.
Compute the proof FIRST and state it in your first message (expect the OUTER
hash `07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee`;
mismatch = STOP):

```
{ sha256sum .agents/skills/bmad-agent-dev/SKILL.md; sha256sum .agents/skills/bmad-agent-dev/customize.toml; } | sha256sum
```

## Task

**The review story is the scope. Read it fully first:**
`_bmad-output/implementation-artifacts/AFK-PORT-1.5A-REVIEW.md` (nine attack
areas, blocker bar, write-only evidence directory, report shape). Review-only:
do not modify product code, tests, docs, the story record or git state. A
coordinator gate chain (including the 42-minute `run-tests.sh`) is running in
this worktree — do not run `run-tests.sh`, do not delete or rewrite anything
under the worktree; scratch copies go under `/tmp`.

## Completion — VERIFIED send (hard requirement)

Send worker_done via the injected mechanism with your --dispatch-capability
token, APPENDING --json. Verify exit code and the JSON's ok/message-id; on
failure capture stderr and retry once with the same token; end your turn only
after a verified send whose message id you state in your final line. Put the
verdict line of `REVIEW.md` first in the worker_done body. Outcome
`succeeded` iff `REVIEW.md` is complete per the report shape (a NOT CLEAN
verdict is still a succeeded review).
