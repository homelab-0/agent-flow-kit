# Reviewer brief — AFK-PORT-1.4-LV-REVIEW (fresh claude session, Orca-supervised)

You are a dispatched REVIEWER under Orca supervision, launched in the LV
story worktree (`afk-port-1.4-lv`, branch `jlengelbrecht/afk-port-1.4-lv`, HEAD
`1a388bf`). Route/stamp (natural router decision, no override):
`{claude, claude/strong, effort high}`,
`_bmad-output/implementation-artifacts/AFK-PORT-1.4-LV-REVIEW.md.stamp.json`,
digest `sha256:42aeed1c93572ab517201fa549282cb122d02f77fbd26b18317083beda438680`,
validated fail-closed by the coordinator immediately before your launch.

## Persona (fail-closed)

BMAD DEV persona from `.agents/skills/bmad-agent-dev/SKILL.md` + `customize.toml`.
Compute the proof FIRST and state it in your first message (expect the OUTER
hash `07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee`;
intermediates `b980cf2c…` and `f3f107f1…`; mismatch = STOP):

```
{ sha256sum .agents/skills/bmad-agent-dev/SKILL.md; sha256sum .agents/skills/bmad-agent-dev/customize.toml; } | sha256sum
```

## Task

**The review story is the scope. Read it fully first:**
`_bmad-output/implementation-artifacts/AFK-PORT-1.4-LV-REVIEW.md`. It lists
the eight attack areas, the blocker bar, the write-only evidence directory,
and the report shape. Do not modify product code, tests, docs, the story
record or git state. A coordinator gate chain (including the 42-minute
`run-tests.sh`) is running in this worktree right now — do not run
`run-tests.sh`, and do not delete or rewrite anything under the worktree.

## Completion — VERIFIED send (hard requirement)

Send worker_done via the injected mechanism with your --dispatch-capability
token, APPENDING --json. Verify the exit code and the JSON's ok/message-id;
if empty or not ok, capture stderr and retry once, keeping the token; only end
your turn after a send whose message id you state in your final line. Put the
verdict line of `REVIEW.md` first in the worker_done body. Outcome
`succeeded` iff `REVIEW.md` is complete per the report shape (a NOT CLEAN
verdict is still a succeeded review).
