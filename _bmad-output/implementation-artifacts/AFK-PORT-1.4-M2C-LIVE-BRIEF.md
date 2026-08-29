# Worker brief — AFK-PORT-1.4-M2C-LIVE (fresh codex session)

You are a dispatched WORKER under Orca supervision. Route/stamp:
`_bmad-output/implementation-artifacts/AFK-PORT-1.4-M2C-LIVE.stamp.json`.

## Persona (fail-closed)

BMAD DEV persona; compute the proof first (expect
`07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee`; mismatch = STOP):

```
{ sha256sum .agents/skills/bmad-agent-dev/SKILL.md; sha256sum .agents/skills/bmad-agent-dev/customize.toml; } | sha256sum
```

## Context

M2B converged the primary host to `8a7cbc1` (UPDATE: CONVERGED, IDEMPOTENCE:
NO_CHANGE, DRIFT-REFUSAL: REFUSED). Its Lane 3 (explicit live verification)
failed honestly on two HOST-CONFIGURATION gaps: no declared router endpoint
(`ROUTER_ENDPOINT_NOT_DECLARED`) and an unresolvable Orca CLI
(`ORCA_NOT_RESOLVED` — this Linux host's CLI is `orca-ide`, not `orca`).
This lane re-runs live verification with the host configuration declared.

## Task — Lane 3 rerun: explicit live verification (AC-8)

Evidence dir (create): `_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.4-M2C-LIVE/`

1. Declare the host configuration in your shell (values are host facts, not
   secrets — except the token, which you must obtain and never print):

   ```
   export AGENT_ROUTER_URL=https://agent-router.homelab0.org
   source ~/.op-agent-env
   export AGENT_ROUTER_TOKEN=$(op read "op://develop/caller-token/credential")
   export AFK_ORCA_BIN=orca-ide
   ```

   Record (in `host-config.md`) WHICH variables were declared and their
   values — EXCEPT the token: for it record only "obtained via 1Password
   service account; never echoed or persisted". Never write the token to any
   file, log, or evidence.
2. From the canonical checkout
   (`/home/devbox/repos/jlengelbrecht/agent-flow-kit`, its own
   `bin/agent-flow-kit`): run the live verification surface —
   `status --live --json` → `status-live.json` and
   `verify --live --json` → `verify-live.json` (raw triplets), plus the
   human-rendered `status --live` output → `status-live.txt`.
3. Required at correct scopes, quoted verbatim in `classification.md`:
   installation integrity, `HOST_EXECUTION_READY`, `NEW_WORK_READY`,
   `TARGET_READY(repo)` (or its grounded target-arity classification),
   validator readiness, harness readiness, funding/auth safety (MODE/CLASS
   words only), and `ROUTE_READY` REMAINING `NOT_EVALUATED` /
   no-stamp-supplied — passing any stamp is forbidden.
4. Verdict line: `LIVE: <verbatim overall state> — AMBIGUITY: none|<items>`.
   Any state you cannot ground in the JSON = ambiguity, reported not resolved.

## Hard rules

- Read-only everywhere except your evidence directory: no lifecycle mutation,
  no update, no adopt, no git writes. The live probes themselves are the
  kit's own bounded probes — let the kit run them; do not probe services
  directly yourself.
- Never print or persist the router token. No Story 1.5–1.8 material.

## Completion — VERIFIED send (hard requirement)

worker_done with your --dispatch-capability token + --json; verify exit code,
ok:true, message id; state the message id in your final line. Outcome
`succeeded` iff both live surfaces ran and every required scope has a grounded
classification (an honest NOT_READY with a grounded reason is still
`succeeded` — report it; only missing/ambiguous classifications are failure).
