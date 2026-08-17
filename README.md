# agent-flow-kit

A portable, subscription-aware autonomous development flow for **any project that
uses BMAD**. One PM session plans epics and stamps per-story routing decisions;
disposable worker sessions (Claude / Codex / Devin CLIs) execute them with BMAD
personas injected at spawn; deterministic gates verify; a post-PR triage loop works
every PR to clean; the PM merges under explicit guardrails. Humans decide only what
policy says humans decide.

Nothing here is project-specific: point the repo-wiring phase at any BMAD repo.
The only owner-specific file is the subscription registry (edit it for your own
plans and models).

## Contents

- `HANDOFF.md` — executable setup instructions for a fresh agent on a new machine.
  Idempotent; adapts per-OS (Linux/macOS both proven).
- `files/model-router/` — the routing skill:
  - `SKILL.md` — how routes get decided (tiering, persona selection, validation
    stories, capability checks, pool-temperature rules)
  - `subscriptions.yaml` — the registry: WHAT you can route to (edit for your subs)
  - `scripts/dispatch.sh` — spawns one persona-injected worker per story from its
    `route:` frontmatter; deterministic gates; thin result JSON
  - `scripts/usage-check.sh` — live pool temperature across providers
  - `scripts/github-health.sh` — platform-health gate (outage → hold, never batch)
- `files/humanizer/` — prose de-AI-ification skill, REQUIRED for the PR language
  law (no AI attribution, no internal-methodology vocabulary in public text)
- `files/claude-global-CLAUDE.md` — the policy layer to merge into a machine's
  `~/.claude/CLAUDE.md`: routing tables, PM policy, epic source declaration, merge
  authority + post-PR triage loop, PR language/size/health discipline
- `files/codex-AGENTS.md` — same policies, pointer form, for Codex-launched PMs

## Update discipline

This repo is the sync channel between machines. When the kit or policies evolve
anywhere, push here; pull everywhere else. Keep files portable (BSD+GNU); keep
machine-specific facts in machine-local notes, not in canonical files. Never
commit secrets — credentials live in 1Password, fetched at runtime via a
service account.
