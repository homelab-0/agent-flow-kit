# Worker brief — AFK-PORT-1.4-M2E-LIVE-RERUN (fresh codex session)

Dispatched WORKER under Orca supervision; stamp
`AFK-PORT-1.4-M2E-LIVE-RERUN.stamp.json`.

## Persona (fail-closed)

BMAD DEV persona. Proof = OUTER hash of the two sha256sum lines:
`{ sha256sum .agents/skills/bmad-agent-dev/SKILL.md; sha256sum .agents/skills/bmad-agent-dev/customize.toml; } | sha256sum`
Expected OUTER `07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee`.
Mismatch = STOP.

## Context

The primary host's canonical checkout
(`/home/devbox/repos/jlengelbrecht/agent-flow-kit`) is at master `fbc0923`
carrying the merged readiness fixes; the kit executes from the checkout, so
the fixed surface is live. Status truthfully reports CURRENT (managed content
unchanged by the merge — see the M2D evidence). This lane is the M2C rerun:
explicit live verification only. NO update, NO adopt, NO mutation anywhere.

Evidence dir (create): `_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.4-M2E-LIVE-RERUN/`

## Task

1. Declare host config exactly (record in host-config.md; never print or
   persist the token):
   `export AGENT_ROUTER_URL=https://agent-router.homelab0.org`
   `source ~/.op-agent-env; export AGENT_ROUTER_TOKEN=$(op read "op://develop/caller-token/credential")`
   `export AFK_ORCA_BIN=orca-ide`
2. From the canonical checkout, its own binary: `status --live --json`,
   `verify --live --json` (raw triplets) + rendered `status --live` text.
3. `classification.md`, verbatim quotes for: installation integrity,
   HOST_EXECUTION_READY, NEW_WORK_READY, TARGET_READY (or grounded
   target-arity), validator readiness, harness readiness, funding/auth (MODE
   words), ROUTE_READY remaining NOT_EVALUATED/no-stamp. For EVERY FALSE
   scope: confirm the attached reason is consistent with the same result's
   live facts and name the live fact that grounds it.
   Verdict line: `LIVE: <overall> — REASONS-GROUNDED: yes|no — AMBIGUITY: none|<items>`.

## Hard rules

Read-only outside your evidence dir. The kit's own bounded probes only. No
secrets in output. No Story 1.5–1.8 material.

## Completion — VERIFIED send

worker_done with --dispatch-capability token + --json; verify ok:true +
message id; state the id last. Outcome `succeeded` iff both surfaces ran and
every required scope is grounded (honest FALSE with a grounded reason =
success).
