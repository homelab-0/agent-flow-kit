# Worker brief — AFK-PORT-1.4-M2B-UPDATE (fresh codex session)

You are a dispatched WORKER under Orca supervision. Route/stamp:
`_bmad-output/implementation-artifacts/AFK-PORT-1.4-M2B-UPDATE.stamp.json`.

## Persona (fail-closed)

BMAD DEV persona; compute the proof first (expect
`07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee`; mismatch = STOP):

```
{ sha256sum .agents/skills/bmad-agent-dev/SKILL.md; sha256sum .agents/skills/bmad-agent-dev/customize.toml; } | sha256sum
```

## Context

The PRIMARY host was adopted at stale `bd9d9fb…` (M2A evidence) and the
coordinator then performed the external pull: the canonical checkout
`/home/devbox/repos/jlengelbrecht/agent-flow-kit` is now `master` @
`8a7cbc194fd56114d65c7dfd6a42106c807fb46b` while the applied revision is still
`bd9d9fb…`. Use THAT checkout's own binary
(`/home/devbox/repos/jlengelbrecht/agent-flow-kit/bin/agent-flow-kit`) for
every lifecycle command.

Evidence dir (create, in THIS story worktree):
`_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.4-M2B-UPDATE/`
Capture raw stdout/stderr/exit-status triplets for every command.

## Ordered lanes

### Lane 1 — update-available detection (AC-6)

1. Verify checkout: branch `master`, HEAD `8a7cbc1…`; else STOP.
2. `status --json` → `status-pre.json`. Required: installed state
   `UPDATE_AVAILABLE` with a grounded machine reason; applied revision still
   `bd9d9fb…`. Anything else = STOP and report verbatim.

### Lane 2 — the update transaction (AC-7)

3. `update --plan --json` → `update-plan.json`. HARD STOP-CONDITION: any
   planned write outside content the plan classifies as kit-owned/managed, or
   targeting a preserved/user-owned path, or targeting
   `_bmad-output/implementation-artifacts/AFK-PORT-1.3-COORDINATOR-HANDOFF.md`
   (known machine-local user content) = STOP, do not approve.
4. Preservation BEFORE → `preservation-before.txt`: sha256 of every path the
   plan lists as preserved/machine-local/user-owned, every declared
   adaptation/machine-owned region from the M2A record, and the untracked
   coordinator-handoff file above.
5. Approve + execute exactly per the kit's plan/approve contract (plan's own
   identity to `--approve-plan`; approval actor string
   `coordinator (delegated by Josh M2 go, 2026-08-27)` recorded beside it).
   Capture the full transaction including operation/journal identities →
   `update-execute.json`.
6. Post: `status --json` → `status-post.json` (applied revision must now be
   `8a7cbc1…` and must have advanced only after the transaction's complete
   offline verification — quote the machine evidence of that ordering);
   `verify --json` → `verify-post.json` (offline; failures must be 0).
7. Preservation AFTER → `preservation-after.txt`; byte-identical to BEFORE
   for every preserved path (differences = finding, reported not fixed).

### Lane 3 — explicit live verification (AC-8)

8. Run the kit's live verification surface (`status --live --json` and/or
   `verify --live --json` as the CLI offers) → `live-verification.json` plus
   the human-rendered output → `live-verification.txt`. Required at their
   correct scopes: installation integrity, `HOST_EXECUTION_READY`,
   `NEW_WORK_READY`, `TARGET_READY(repo)` (or its grounded
   NOT_EVALUATED/target-arity classification if no target is registered —
   quote it), validator readiness, harness readiness, funding/auth safety as
   MODE/CLASS words. `ROUTE_READY` MUST remain `NOT_EVALUATED` /
   no-stamp-supplied — supplying any stamp is forbidden in this lane.

### Lane 4 — idempotence (AC-9)

9. `update --plan --json` again → `idempotence-plan.json`: required, a plan
   with NO required mutations.
10. `update --json` again → `idempotence-execute.json`: exit success; then
    prove no churn: applied revision unchanged, managed-component hashes
    unchanged (capture the hash set before/after this second run →
    `idempotence-hashes.txt`), local state unchanged. `CURRENT` prose alone
    is insufficient — the hash comparison is the proof.

### Lane 5 — drift canary (AC-10, AC-11)

11. Select the canary: a kit-owned MANAGED file from the update plan's managed
    set — never credentials, auth/session files, tokens, shell/login files,
    user content, active BMAD work, or router/catalog authority. Record the
    selection and why it satisfies the frozen constraints
    (`canary-selection.md`). It must be inactive-safe, trivially reversible.
12. Back it up byte-exact (`canary-backup/` + sha256), then introduce a
    non-secret, clearly-labeled modification (e.g. append a comment line
    `# AFK-PORT-1.4 drift canary <UTC timestamp>`).
13. `status --json` → `drift-status.json`: required `LOCAL_DRIFT` with a
    stable reason and its blocking scope.
14. `update --plan --json` (and `update --json` if the plan stage does not
    already refuse) → `drift-refusal.json`: the lifecycle must REFUSE and
    must NOT overwrite the canary — capture the canary's hash after the
    refusal to prove non-overwrite.
15. Restore byte-for-byte from backup; verify sha256 equality →
    `canary-restore.txt`; then `verify --json` → `post-restore-verify.json`
    (healthy again, failures 0).

### Classification

`classification.md`: every lane's machine states quoted verbatim; verdict
lines:
`UPDATE: <verbatim> — IDEMPOTENCE: <verbatim> — DRIFT-REFUSAL: <verbatim> — AMBIGUITY: none|<items>`.

## Hard rules

- Mutations only through the kit's own transactions plus the enumerated canary
  steps (backup/modify/restore of the one selected file). No permissive flags
  (`--allow-noncanonical-source`/`--allow-rollback` FORBIDDEN). No git writes.
  Any refusal outside Lane 5's expected refusal, any error, any ambiguity:
  capture verbatim, STOP the lane, report.
- If ANY lane stops, later lanes that depend on it do not run; independent
  evidence capture still completes.
- No secrets (values) anywhere. No Story 1.5–1.8 material.

## Completion — VERIFIED send (hard requirement)

worker_done via the injected mechanism with your --dispatch-capability token,
appending --json; verify exit code + ok:true + message id and state the
message id in your final line. Outcome `succeeded` iff Lanes 1–5 all
completed with their required outcomes and preservation/restore hashes match.
Body: the four verdict lines + evidence path.
