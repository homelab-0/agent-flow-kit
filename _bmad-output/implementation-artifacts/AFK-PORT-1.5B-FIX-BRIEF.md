# Worker brief — AFK-PORT-1.5B-FIX (fresh claude session, Orca-supervised)

You are a dispatched WORKER under Orca supervision in the lane A worktree
(`afk-port-1.5b`, branch `jlengelbrecht/afk-port-1.5b`, HEAD `54dfd14`).
Route/stamp: `{claude, claude/strong, effort medium}` (recorded override under
the owner's standing ruling), stamp at
`_bmad-output/implementation-artifacts/AFK-PORT-1.5B-FIX.md.stamp.json`
(digest in the coordinator's record), validated fail-closed by the
coordinator immediately before your launch.

## Persona (fail-closed)

BMAD DEV persona from `.agents/skills/bmad-agent-dev/SKILL.md` + `customize.toml`.
Compute the proof FIRST and state it in your first message (expect the OUTER
hash `07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee`;
mismatch = STOP):

```
{ sha256sum .agents/skills/bmad-agent-dev/SKILL.md; sha256sum .agents/skills/bmad-agent-dev/customize.toml; } | sha256sum
```

## Task

**The fix story is the scope:** `_bmad-output/implementation-artifacts/AFK-PORT-1.5B-FIX.md`
(F1–F8, hard stops, the known-flake rule). Read the review it answers
(`evidence/AFK-PORT-1.5B-REVIEW/REVIEW.md` BLK-1, RES-1–RES-9, and the
disclosed-items section) and the lane story `AFK-PORT-1.5B.md` (spec + record).

You have a shell. Run all five gates yourself (`bash tests/<file>`), paste
tallies. The frozen launch command texts must stay byte-identical (the suite's
byte-identity oracle is yours).

## Hard rules

- Exactly F1–F8. Disclose anything else under "Deferred, deliberately, and
  disclosed" with a diagnosis.
- No secret values; no live gateway launches. No Story 1.6/1.8 material.
- Git: ONE commit on this branch, named files, plain engineering-language
  message with NO trailers of any kind (no Co-Authored-By, no session links,
  no tool banners); never rewrite existing commits; never push or PR; never
  touch `master`. Do not commit briefs, stamps or route artifacts.
- A decision that genuinely needs the owner: record it, `NEEDS-HUMAN:
  <question>` in your worker_done body, stop.

## Completion — VERIFIED send (hard requirement)

Send worker_done via the injected mechanism with your --dispatch-capability
token, APPENDING --json. Verify exit code and the JSON's ok/message-id; on
failure capture stderr and retry once with the same token; end your turn only
after a verified send whose message id you state in your final line. Outcome
per the fix story's gate rule.
