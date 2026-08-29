# Worker brief — AFK-PORT-1.4-M2A-ADOPT (fresh codex session)

You are a dispatched WORKER under Orca supervision. Route/stamp:
`_bmad-output/implementation-artifacts/AFK-PORT-1.4-M2A-ADOPT.stamp.json`.

## Persona (fail-closed)

BMAD DEV persona from `.agents/skills/bmad-agent-dev/SKILL.md` + `customize.toml`;
compute the proof first (expect
`07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee`; mismatch = STOP):

```
{ sha256sum .agents/skills/bmad-agent-dev/SKILL.md; sha256sum .agents/skills/bmad-agent-dev/customize.toml; } | sha256sum
```

## Task — adoption at the stale revision (PRIMARY host, Josh-authorized M2)

Target: the CANONICAL checkout `/home/devbox/repos/jlengelbrecht/agent-flow-kit`,
now positioned by the coordinator at `master` @
`bd9d9fb028149b0f381e44de965955230d2b45cd` (the host's true stale revision).
Use THAT checkout's own binary for every lifecycle command
(`/home/devbox/repos/jlengelbrecht/agent-flow-kit/bin/agent-flow-kit`) — the
stale host adopts with its own stale kit.

Evidence dir (create, in THIS story worktree):
`_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.4-M2A-ADOPT/`

Ordered steps — capture raw stdout, stderr, and exit status of every command:

1. Verify the checkout: `git -C <canonical> rev-parse --abbrev-ref HEAD` must
   be `master` and HEAD must be `bd9d9fb…`; else STOP and report.
2. `status --json` → `status-pre.json`. Confirm the source-eligibility
   refusal from the baseline is gone (branch now canonical). Any remaining
   source ineligibility = STOP and report verbatim.
3. `adopt --inspect --json` → `adopt-inspect.json`. Record the disposition.
4. `adopt --plan --json` → `adopt-plan.json`. HARD STOP-CONDITION: read every
   planned action; if ANY touches content the plan does not classify as
   kit-owned/managed (or lists a preserved/user-owned path as a write
   target), STOP the lane and report — do not approve.
5. Preservation BEFORE snapshot → `preservation-before.txt`: sha256 of every
   path the plan lists as preserved/machine-local/user-owned (and the five
   untracked `_bmad-output` files listed in the coordinator's
   `AFK-PORT-1.4-M2-GIT-CHANNEL/operator-git-before.txt`).
6. Approve + execute the adoption exactly as the kit's plan/approve contract
   directs, passing the plan's own identity to `--approve-plan`. Authority:
   Josh's M2 go delegated plan approval to the coordinator; record the
   approval actor string
   `coordinator (delegated by Josh M2 go, 2026-08-27)` in your evidence
   beside the plan identity. Capture the full transaction output →
   `adopt-execute.json` / `.stderr` / `.exit-status`.
7. Preservation AFTER snapshot → `preservation-after.txt` (same path set;
   byte-identical hashes required — any difference is a finding, reported
   not fixed).
8. `status --json` → `status-post.json`; `verify --json` → `verify-post.json`
   (offline). Expected: adopted, applied revision recorded, integrity READY;
   quote the actual machine states verbatim in `classification.md` with one
   verdict line: `ADOPTION: <verbatim outcome> — AMBIGUITY: none|<items>`.

## Hard rules

- The ONLY mutation permitted is the kit's own adoption transaction. No update.
  No git writes anywhere. No edits outside your evidence directory.
- Any refusal, error, or ambiguity: capture verbatim, STOP the lane, report.
  Never retry a refused transaction with permissive flags
  (--allow-noncanonical-source / --allow-rollback are FORBIDDEN).
- No secrets (values) in any output. No Story 1.5–1.8 material.

## Completion — VERIFIED send (hard requirement)

Send worker_done via the injected mechanism with your --dispatch-capability
token, APPENDING --json. Then verify: capture the send's exit code
(`echo $?`) and the JSON's ok/message-id. If output is empty or ok is not
true, capture stderr (rerun with 2>&1), report the failure in a second
attempt's body, and only end your turn after a send whose JSON result you
have verified and whose message id you state in your final line.
Outcome `succeeded` iff adoption committed and preservation hashes match.
