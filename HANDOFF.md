# HANDOFF: set up the agent flow on this machine

You are a Claude Code session (frontier model preferred) installing a portable
autonomous-development flow. It works with **any project that uses BMAD** — nothing
in it is tied to one product. Be idempotent — re-running must be safe. Verify before
acting; never guess. Where this machine differs from the reference environments
(Linux devbox, macOS nix-managed Mac mini — both proven), adapt and record the
difference in the final report.

## Ground rules (billing/safety invariants — never bend these)

- Files under `files/` are canonical and battle-tested. Install VERBATIM — they
  embed non-obvious fixes (binary-safe grep parsing, BSD/GNU portability, provider
  rate-limit schema quirks). Do not "improve" them.
- Never set or export `ANTHROPIC_API_KEY`; never use `--bare` when spawning claude.
  Either silently moves plan billing to metered API.
- GUI or interactive-login steps: do NOT attempt; collect for the report.
- Design intent, so adaptations stay on-mission: PM plans epics → stamps `route:`
  frontmatter per story via the model-router skill → dispatch.sh spawns
  persona-injected workers (claude/codex/devin) → deterministic gates → review
  gates → PR → post-PR triage loop → PM merges under guardrails. Humans decide:
  protected paths, promotions, bypasses, true secrets.

## Phase 0 — preflight (report, fix nothing except yq)

1. `command -v yq jq claude codex devin orca op bunx uvx` — note missing. yq must
   be mikefarah v4+ (installing yq to a PATH dir IS yours to do if absent).
2. Login state: `claude auth status`; `codex doctor` (auth section); `devin auth
   status`. Missing logins → needs-owner (interactive).
3. `env | grep -c OP_SERVICE_ACCOUNT_TOKEN` — a 1Password service-account token
   machine-wide makes `op read`/`op run` promptless (this is what makes secret-
   dependent gates autonomous). If absent: needs-owner — "export the existing
   service-account token via an untracked env file sourced by the shell rc"
   (reference: `~/.op-agent-env` + one rc line; on nix-managed hosts the rc line
   goes in the flake, the env file stays untracked).
4. `env | grep -i ANTHROPIC_API_KEY` must be empty.
5. `orca status --json` if orca exists. Orca enables visible dispatch (worktree
   cards + terminals) and simulator/emulator surfaces; the flow degrades to
   headless dispatch without it.

## Phase 1 — install the model-router kit

    cp -r files/model-router ~/.agents/skills/model-router
    ln -s ~/.agents/skills/model-router ~/.claude/skills/model-router   # if absent
    chmod +x ~/.agents/skills/model-router/scripts/*.sh

`~/.agents/skills` is the universal-skills home (codex reads it too); `~/.claude/
skills` entries are symlinks by convention. If a copy already exists, diff first —
the owner's local edits win; flag conflicts.

## Phase 2 — humanizer skill (required by the PR language law)

    cp -r files/humanizer ~/.agents/skills/humanizer      # if not already installed
    ln -s ~/.agents/skills/humanizer ~/.claude/skills/humanizer   # if absent

(Equivalent: `npx -y skills add blader/humanizer --skill humanizer --global`.)

## Phase 3 — Orca skills (only if orca present)

    orca skills install --skill orca-cli --skill orchestration
    orca skills get orchestration --full   # verify

## Phase 4 — truth up the registry + usage-check for THIS machine

`files/model-router/subscriptions.yaml` describes the OWNER's subscriptions —
account-level facts carry across machines; machine-level paths may not:

1. Codex model IDs: find this machine's codex models cache (`codex doctor` prints
   CODEX_HOME; Orca-managed homes live under `~/.config/orca/codex-accounts/*/home`
   on Linux, `~/Library/Application Support/orca/codex-accounts/*/home` on macOS —
   usage-check.sh already globs both). Confirm the registry's IDs still exist.
2. `devin models list` — confirm registered IDs (free-tier models especially).
3. usage-check.sh is BSD/GNU portable; the claude collector needs `bunx` +
   the owner's statusline usage package. Run it; if a collector degrades, that is
   graceful and expected — report, don't hack.
4. Local-model subcontractors (registry `subcontractors:` block): verify whether
   the referenced tooling exists on this host; if not, append a one-line
   "not installed on this host" note to its constraints. Free cloud models cover
   the free-drafts role where no local GPU exists.
5. Run `scripts/usage-check.sh` and include output in the report.

## Phase 5 — merge the global policies into ~/.claude/CLAUDE.md

`files/claude-global-CLAUDE.md` is the reference global CLAUDE.md. MERGE, never
overwrite — the machine may have its own content, and machine-specific blocks
owned by other tools (e.g. memory systems) must not be copied. Sections that MUST
land verbatim (they are the flow's law):

- "Model & effort routing (BMAD flow)" — incl. PM-session policy + handoff templates
- "Epic source declaration"
- "PM merge authority (ACTIVE)" — incl. Post-PR triage loop, PR language law,
  PR discipline (platform health + size)
- "Local GPU delegation" — append a host note if the delegate tooling is absent
  (free cloud models take the GREEN free-drafts role there)

## Phase 6 — codex global guidance

    cp files/codex-AGENTS.md ~/.codex/AGENTS.md
    # Also copy into the real CODEX_HOME if different (codex doctor shows it).

## Phase 7 — GitGuardian MCP (skip if the owner doesn't use GitGuardian)

Requires the op service account (Phase 0.3) and a GitGuardian PAT stored in
1Password (reference item: `op://develop/GitGuardian PAT/credential`):

    claude mcp add gitguardian --scope user -- sh -c 'GITGUARDIAN_PERSONAL_ACCESS_TOKEN="$(op read "op://develop/GitGuardian PAT/credential")" exec uvx --from git+https://github.com/GitGuardian/ggmcp.git gg-mcp-server'

Pre-warm the uvx build (dummy token, `--help`), then check `claude mcp list`. If op
is missing it will show Failed-to-connect until the token lands — that self-heals,
no re-registration needed.

## Phase 8 — repo wiring (repeat for EACH target BMAD repo on this machine)

1. Find the BMAD create-story template. Two layouts seen in the wild:
   - v6 tree: `_bmad/bmm/workflows/4-implementation/create-story/template.md`
   - v6 skills: `.agents/skills/bmad-create-story/template.md` (sometimes with a
     second physical copy under `.claude/skills/` — keep both in sync, or better,
     symlink one to the other)
   Add this frontmatter block at the top (adapt comments to the repo):

       ---
       # linear: the tracker issue this work implements. EMPTY = local-only epic:
       # the PM must NOT create or sync anything in the tracker for it.
       linear:
       # agent = BMAD persona injected at dispatch: dev (default) | qa (validation
       # stories — claude route only, needs MCP) | tech-writer | quick-flow-solo-dev
       route: {provider: , cli: , model: , effort: , agent: dev, fallback: []}
       # local_gpu: subcontractor pre-assessment (green|yellow|red); red if no
       # local delegate tooling on this host
       local_gpu:
       gates: []
       max_cycles: 3
       ---

2. Personas: dispatch.sh injects `$AGENT_DIR/<agent>.md` (default
   `_bmad/bmm/agents`). If the repo uses the skills layout, create
   `_bmad/bmm/agents/` with symlinks to the installed `bmad-agent-*` SKILL.md
   files. Verify at least `dev.md` resolves. Missing personas (e.g. qa) →
   needs-owner; validation stories run the dev persona meanwhile.
3. Validation surface — match the project, don't copy another project's choice:
   web app → Playwright MCP against the running stack; mobile → simulator/emulator
   (Orca's emulator surface if present); CLI/library → its real integration
   harness. Validation stories' ACs must name exact flows, never "test the feature".
4. **Merge-consequence check (required per repo):** determine what a merge to the
   default/sync branch actually DOES. Plain code repo → integration branch,
   deploys gated elsewhere → standard merge authority applies. **GitOps/IaC repo
   (Flux/Argo/Terraform auto-apply): merging IS deploying** — do not enable PM
   merge authority as-is; flag to the owner and record their choice in the repo's
   CLAUDE.md (options: merges always human; or PM merges only paths outside the
   auto-sync scope; or merges target a staging overlay/branch with promotion to
   the prod overlay kept human). Gates for such repos are schema/dry-run tools
   (kubeconform, kustomize build, helm template, `flux diff`/`terraform plan`),
   and validation stories verify against a staging/kind environment, never prod.
5. Do NOT create tracker artifacts, orchestration Runs, or dispatch real stories
   during setup.

## Phase 9 — smoke tests

1. Dispatch smoke: /tmp/router-smoke.md with
   `route: {provider: claude, cli: claude, model: haiku, agent: dev}`,
   `gates: ["true"]`, `max_cycles: 1`, body "Reply with the word ok." Run FROM the
   directory containing it (dispatch.sh refuses stories outside $PWD — worker
   sandboxes root at cwd). Expect exit 0, result.json status "done".
2. Free-model smoke (zero quota): `devin -p "Reply with only the word ok" --model
   swe-1-7-medium --respect-workspace-trust false`
3. `scripts/usage-check.sh` and `scripts/github-health.sh` full runs.

## Final report (always produce)

Per phase: done / adapted (how) / skipped / needs-owner. End with a kickoff prompt
for the owner's first PM session on this machine, adapted to a real epic in the
target repo: declare the epic home (tracker vs local), router-stamped stories +
trailing validation story with project-appropriate physical flows, routing table
for approval before dispatch, one story at a time (visible Orca dispatch if
available), merge authority + triage loop + PR language law per CLAUDE.md.
