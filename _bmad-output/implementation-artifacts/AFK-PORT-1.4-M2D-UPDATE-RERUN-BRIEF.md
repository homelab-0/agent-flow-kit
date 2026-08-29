# Worker brief — AFK-PORT-1.4-M2D-UPDATE-RERUN (fresh codex session)

Dispatched WORKER under Orca supervision; stamp
`AFK-PORT-1.4-M2D-UPDATE-RERUN.stamp.json`.

## Persona (fail-closed)

BMAD DEV persona. Proof = OUTER hash of the two sha256sum lines:
`{ sha256sum .agents/skills/bmad-agent-dev/SKILL.md; sha256sum .agents/skills/bmad-agent-dev/customize.toml; } | sha256sum`
Expected OUTER `07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee`.
Mismatch = STOP.

## Context

The primary host is adopted at applied revision `8a7cbc1`; the coordinator
pulled the canonical checkout (`/home/devbox/repos/jlengelbrecht/agent-flow-kit`)
to master `fbc0923` (the merged readiness fixes, PR #21). Use that checkout's
own `bin/agent-flow-kit` for every lifecycle command.

Evidence dir (create): `_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.4-M2D-UPDATE-RERUN/`
Raw stdout/stderr/exit triplets for every command.

## Lanes

1. **Update delivery (second live update-channel exercise).**
   `status --json` → must report `UPDATE_AVAILABLE` (applied 8a7cbc1 vs
   checkout fbc0923). `update --plan --json` → HARD STOP on any write target
   the plan does not classify kit-owned/managed. Preservation before/after
   hashes for every preserved path (including the untracked
   `AFK-PORT-1.3-COORDINATOR-HANDOFF.md` and
   `follow-on-managed-coordinator-report-style.md` user files). Approve with
   the plan's own identity (approval actor:
   `coordinator (delegated by Josh M2 go, continuation for fix delivery, 2026-08-28)`),
   execute, then `status --json` (applied revision must be fbc0923) and
   `verify --json` (0 failures).
2. **Live verification rerun (M2C rerun, the fixed surface).**
   Declare host config exactly:
   `export AGENT_ROUTER_URL=https://agent-router.homelab0.org`;
   `source ~/.op-agent-env; export AGENT_ROUTER_TOKEN=$(op read "op://develop/caller-token/credential")`
   (never print/persist the token); `export AFK_ORCA_BIN=orca-ide`.
   Run `status --live --json` and `verify --live --json` + the rendered
   `status --live` text. Required in `classification.md`, quoted verbatim:
   installation integrity, HOST_EXECUTION_READY, NEW_WORK_READY,
   TARGET_READY (or grounded target-arity), validator readiness, harness
   readiness, funding/auth (MODE words), ROUTE_READY remaining
   NOT_EVALUATED/no-stamp. CRITICALLY: for every FALSE scope, confirm the
   attached reason is consistent with the same result's live facts (the
   defect the fixes addressed). Verdict line:
   `LIVE: <overall> — REASONS-GROUNDED: yes|no — AMBIGUITY: none|<items>`.

## Hard rules

Mutations only via the kit's update transaction. No permissive flags. Any
refusal/error/ambiguity: capture verbatim, STOP the lane, report. No secrets.
No Story 1.5–1.8 material.

## Completion — VERIFIED send

worker_done with --dispatch-capability token + --json; verify ok:true +
message id; state the id last. Outcome `succeeded` iff the update converged
with preservation intact AND the live rerun produced grounded classifications
for every required scope (honest FALSE states with grounded reasons count as
success; contradictory reasons or ambiguity = failed).
