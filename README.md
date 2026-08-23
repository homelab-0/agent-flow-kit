# agent-flow-kit

A portable autonomous development flow for **any project that uses BMAD**, driven by
a central routing control plane. One PM session plans epics and describes each story
to the router; a human accepts or deliberately overrides the recommendation; the
decision is frozen into an immutable execution stamp; disposable worker sessions
(Claude / Codex CLIs) execute them in visible Orca worktrees with BMAD personas
injected at spawn; deterministic gates verify; a post-PR triage loop works every PR
to clean; the PM merges under explicit guardrails. Humans decide only what policy
says humans decide — and every route is one of those things.

**The router is the sole routing authority.** There is no local routing table, no
tier lookup and no runtime fallback chain: the kit owns delegation and control flow,
Orca owns worktrees/terminals/processes/native auth, and the router owns
recommendation and placement — never credentials or sessions.

Nothing here is project-specific: point the repo-wiring phase at any BMAD repo. The
only machine-specific file is the launcher config (router endpoint, caller-token env
var NAME, catalog path, harness binaries).

## Contents

- `HANDOFF.md` — executable setup instructions for a fresh agent on a new machine.
  Idempotent; adapts per-OS (Linux/macOS both proven).
- `files/model-router/` — the routing skill:
  - `SKILL.md` — how a task is described to `POST /v1/route`, how a recommendation
    is accepted or overridden, persona selection, validation stories
  - `subscriptions.yaml` — LAUNCHER CONFIG (endpoint, caller-token env name,
    catalog path, harness binaries). Not a routing registry; holds no secret.
  - `scripts/make-stamp.sh` — accepted route decision → immutable execution stamp
    (`expires_at` copied verbatim; overrides recorded pre-stamp, provenance only)
  - `scripts/dispatch.sh` — one worker attempt per story: place (when required) →
    validate the stamp fail-closed → launch in a visible Orca terminal under the
    frozen harness contract → deterministic gates → thin result JSON
  - `scripts/usage-check.sh` — pool temperature, observability only (no routing
    guidance)
  - `scripts/github-health.sh` — platform-health gate (outage → hold, never batch)
- `tests/run-tests.sh` — shellcheck + contract-conformance + refusal-path proofs.
  Runs offline with stubbed orca/validator/router binaries; launches no harness.
- `files/humanizer/` — prose de-AI-ification skill, REQUIRED for the PR language
  law (no AI attribution, no internal-methodology vocabulary in public text)
- `files/claude-global-CLAUDE.md` — the policy layer to merge into a machine's
  `~/.claude/CLAUDE.md`: the route→stamp→validate→place sequence, PM policy, epic
  source declaration, merge authority + post-PR triage loop, PR language/size/health
  discipline
- `files/codex-AGENTS.md` — same policies, pointer form, for Codex-launched PMs

## Update discipline

This repo is the sync channel between machines. When the kit or policies evolve
anywhere, push here; pull everywhere else. Keep files portable (BSD+GNU); keep
machine-specific facts in machine-local notes, not in canonical files. Never
commit secrets — credentials live in 1Password, fetched at runtime via a
service account.
