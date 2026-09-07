# Worker brief — AFK-PORT-1.4-LV-FIX (fresh claude session, Orca-supervised)

You are a dispatched WORKER under Orca supervision, in the LV story worktree
(`afk-port-1.4-lv`, branch `jlengelbrecht/afk-port-1.4-lv`, HEAD `1a388bf`).
Route/stamp: `{claude, claude/strong, effort medium}` (recorded override of
the natural route under the owner's standing routing ruling),
`_bmad-output/implementation-artifacts/AFK-PORT-1.4-LV-FIX.md.stamp.json`,
digest `sha256:6e0a2894ae4f28d7344b5fe5d4767ec6898b82286d05e4b73e2bd2ad4727b60e`,
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

**The fix story is the scope. Read it fully first:**
`_bmad-output/implementation-artifacts/AFK-PORT-1.4-LV-FIX.md` — six items
(F1–F6), hard stops, and the known-flake rule for `run-tests.sh`. Then the
review it answers (`evidence/AFK-PORT-1.4-LV-REVIEW/REVIEW.md`) and the
parent story record (`AFK-PORT-1.4-LV.md`).

You have a shell. Run all three gates yourself (`bash tests/...`), paste the
tallies. Invoke suites as `bash tests/<file>`.

## Hard rules

- Exactly F1–F6. Nothing else, however tempting; disclose anything else under
  "Deferred, deliberately, and disclosed" in the fix story's record.
- Native `{claude, claude/strong}` command text byte-identical; the suite's
  byte-identity assertion and `attack-01` are your oracles.
- No secret VALUES anywhere; sentinels only. No live gateway launch. No
  Story 1.5–1.8 material.
- Git: ONE commit on this worktree's branch when done, named files only,
  plain engineering-language message with NO trailers of any kind (no
  Co-Authored-By, no session links, no tool banners — the repository's
  public-text rule forbids them; if your environment appends them anyway, say
  so in your record so the coordinator strips them at packaging). Never
  rewrite existing commits. Never push, never open a PR, never touch `master`.
  Do not commit the brief, stamps, route artifacts or evidence directories.
- A decision that genuinely needs the owner: record it, send
  `NEEDS-HUMAN: <question>` in your worker_done body, stop.

## Completion — VERIFIED send (hard requirement)

Send worker_done via the injected mechanism with your --dispatch-capability
token, APPENDING --json. Verify exit code and the JSON's ok/message-id; on
failure capture stderr, retry once with the same token; end your turn only
after a verified send whose message id you state in your final line.
Outcome per the fix story's gate rule: `succeeded` iff F1–F6 are done, the
other two gates are green, and the ONLY `run-tests.sh` failure is the recorded
concurrency aggregate with exactly its three known sub-assertions.
