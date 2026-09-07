# Worker brief — AFK-PORT-1.7-ASSEMBLE (fresh claude session, Orca-supervised)

You are a dispatched WORKER under Orca supervision, in your own Orca worktree
of `agent-flow-kit` branched from `master` @ `39fd66c`. Route/stamp:
`{claude, claude/strong, effort medium}` (recorded override of the natural
route; the override reason in the stamp cites this spike's own measurements),
`_bmad-output/implementation-artifacts/AFK-PORT-1.7-ASSEMBLE.md.stamp.json`,
digest `sha256:83b2356ac00fba4e45389b1b8c31f33024245d8dc9e78ce8ba86781d8305e1a1`,
validated fail-closed by the coordinator immediately before your launch.

## Persona (fail-closed)

BMAD ANALYST persona from `.agents/skills/bmad-agent-analyst/SKILL.md` +
`customize.toml`. Compute the proof FIRST and state it in your first message
(expect the OUTER hash
`4baeaab8ee79002d72a41cf4c6a321d67aef40fd1ba4afe0fb777ad809c34031`;
mismatch = STOP):

```
{ sha256sum .agents/skills/bmad-agent-analyst/SKILL.md; sha256sum .agents/skills/bmad-agent-analyst/customize.toml; } | sha256sum
```

## Task

**The lane story is the scope. Read it fully first:**
`_bmad-output/implementation-artifacts/AFK-PORT-1.7-ASSEMBLE.md` — inputs,
six deliverables, hard rules. The evidence directory
`_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.7/` is provisioned
into this worktree (untracked; you commit it as part of your deliverable
together with the files you write there and the story record). The cell
count is 24 matrix cells plus 3 codex `none`-mode addendum cells.

You have a shell. Run `git diff --check` and `bash tests/lifecycle-tests.sh`
(the spike changes no product code; the gate proves non-interference) and
paste the tallies.

## Hard rules

- Numbers come only from `results/*.json`; gates decide quality; no
  transcript grading. Say what the data cannot show.
- No prohibition, no product decision: recommendations plus an explicit
  statement that the persona-independence contract stands unchanged.
- No secret values. No edits outside the deliverables and the story record.
- Git: ONE commit on this branch with named files (the evidence directory,
  your deliverables, `AFK-PORT-1.7.md`), plain engineering-language message,
  NO trailers of any kind. Never push, never PR, never touch `master`. Do
  not commit the brief, the ASSEMBLE stamp or the ASSEMBLE story.
- A decision that genuinely needs the owner: `NEEDS-HUMAN: <question>` in
  your worker_done body, then stop.

## Completion — VERIFIED send (hard requirement)

Send worker_done via the injected mechanism with your --dispatch-capability
token, APPENDING --json. Verify exit code and the JSON's ok/message-id; on
failure capture stderr and retry once with the same token; end your turn only
after a verified send whose message id you state in your final line. Put the
per-profile recommendations in the worker_done body. Outcome `succeeded` iff
all six deliverables exist, the record is filled, and both gates are green.
