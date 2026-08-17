# HANDOFF: recreate the model-router + autonomous BMAD flow on this Mac

You are a Claude Code session (Fable) setting up Josh's routing/dispatch flow on his
Mac (the machine hosting the `ios-unofficial` repo). This flow is already live on the
Linux devbox; this bundle carries the canonical files. Be idempotent — re-running must
be safe. Verify before acting; never guess. Where this Mac differs from the devbox,
adapt and note the difference in the final report.

## Ground rules (identical to the devbox — these are billing/safety invariants)

- Files under `files/` are canonical, battle-tested copies from the devbox. Install
  them VERBATIM — they contain non-obvious bug fixes (binary-safe grep parsing,
  codex rate-limit schema handling). Do not "improve" them.
- Never set or export `ANTHROPIC_API_KEY`; never use `--bare` when spawning claude.
  Either silently moves plan billing to metered API.
- Anything needing a GUI or interactive login: do NOT attempt; collect for the report.
- The flow's design intent, so your adaptations stay on-mission: PM plans epics and
  stamps `route:` frontmatter via the model-router skill → dispatch.sh spawns
  persona-injected workers (claude/codex/devin) → deterministic gates → review gates →
  PR → post-PR triage loop → PM merges under guardrails. Human gates: protected
  paths, promotions, bypasses, true secrets.

## Phase 0 — preflight (report, fix nothing)

1. `command -v yq jq claude codex devin orca op bunx` — note missing. yq must be
   mikefarah v4+ (install to a PATH dir if missing — that one IS yours to fix).
2. `claude auth status`; codex login state (`codex doctor` auth section); `devin auth
   status`. Missing logins = needs-Josh (interactive).
3. `env | grep -c OP_SERVICE_ACCOUNT_TOKEN` — the devbox has a 1Password service
   account env-wide, which makes `op run`/`op read` promptless (Sentry-gate class
   autonomy). If absent here: flag needs-Josh — "export the same OP service-account
   token machine-wide" (he has it; do not create a new one).
4. `env | grep -i ANTHROPIC_API_KEY` must be empty.
5. `orca status --json` if orca exists (Orca-visible dispatch is preferred but the
   flow works without it — dispatch.sh is Orca-independent).

## Phase 1 — install the model-router kit

Canonical location + claude symlink (universal-skills convention, codex reads it too):

    cp -r files/model-router ~/.agents/skills/model-router
    ln -s ~/.agents/skills/model-router ~/.claude/skills/model-router   # if not present
    chmod +x ~/.agents/skills/model-router/scripts/*.sh

If a model-router dir already exists, diff first; newest devbox copy wins unless Josh
customized something (his edits win — flag conflicts).

## Phase 2 — Orca skills (only if orca present)

    orca skills install --skill orca-cli --skill orchestration
    orca skills get orchestration --full   # verify

## Phase 3 — truth up the registry + usage-check for THIS machine

`subscriptions.yaml` is account-level (same subscriptions) — model IDs and devin org
id carry over. But verify and adapt the machine-specific parts:

1. Codex model IDs: check this Mac's codex models cache (`find ~/.codex ~/Library
   -name models_cache.json 2>/dev/null` — macOS paths differ; on the devbox an
   Orca-managed CODEX_HOME held it). Confirm `gpt-5.6-sol` / `gpt-5.6-luna` exist;
   fix if the lineup moved.
2. `devin models list` — confirm the registered IDs (swe-1-7, swe-1-7-medium,
   gemini-3-7-flash-high, kimi-k3-high, deepseek-v4-flash-high) still exist.
3. `usage-check.sh` machine adaptations (edit ONLY these):
   - claude collector needs `bunx` + the `ccstatusline-usage` package (Josh's
     statusline). If bun is absent on this Mac, install it or mark claude usage
     UNKNOWN — do not break the script.
   - codex collector: the sessions glob includes a Linux Orca path
     (`~/.config/orca/codex-accounts/*/home`). Find this Mac's CODEX_HOME
     (`codex doctor` prints it) and fix the glob.
   - devin collector: org id `org-fcb0104a5e5a4468b2f6fe97a4b4f3cf` is account-level
     — unchanged. Requires `op` (service account) for the 1P item
     `op://develop/Devin Analytics/credential`; if no OP token yet, it degrades
     gracefully — fine.
   - The `local-qwen36-27b` subcontractor entry: the GPU lives on the homelab LAN and
     `~/.claude/local-model/delegate.sh` does NOT exist on this Mac. Leave the
     registry entry (it documents the option) but add one line to its `constraints`
     noting "not installed on this host". Only claude drivers on the devbox delegate.
4. Run `~/.agents/skills/model-router/scripts/usage-check.sh` and include its output
   in the report.

## Phase 4 — merge the global policies into this Mac's ~/.claude/CLAUDE.md

`files/claude-global-CLAUDE.md` is the devbox's full global CLAUDE.md. MERGE, don't
overwrite — this Mac's CLAUDE.md may have its own content. Sections that MUST land
here verbatim (they are the flow's law):

- "Model & effort routing (BMAD flow)" — dev-session model table, ultracode/effort,
  PM-session policy (incl. dev-handoff + reviewer-handoff templates)
- "Epic source declaration"
- "PM merge authority ... ACTIVE" INCLUDING the "Post-PR triage loop"
- "Local GPU delegation (junior-dev protocol)" — include but append a note that
  delegate.sh is devbox-only; on this Mac the GREEN-profile free-drafts role is
  covered by devin/swe-1-7 instead.

## Phase 5 — codex global guidance

    cp files/codex-AGENTS.md ~/.codex/AGENTS.md
    # If this Mac's codex uses a different CODEX_HOME (see codex doctor), copy there too.

## Phase 6 — GitGuardian MCP (user scope, secretless launch)

Requires op service account (Phase 0.3). If present:

    claude mcp add gitguardian --scope user -- sh -c 'GITGUARDIAN_PERSONAL_ACCESS_TOKEN="$(op read "op://develop/GitGuardian PAT/credential")" exec uvx --from git+https://github.com/GitGuardian/ggmcp.git gg-mcp-server'

Pre-warm (`uvx ... --help` with a dummy token), then verify `claude mcp list` shows
Connected. If no OP token: register anyway and note it will connect once the token
lands. Requires `uv`/`uvx` — install if missing.

## Phase 7 — repo wiring (ios-unofficial)

1. Find the BMAD create-story template — BMAD v6 layout is `_bmad/bmm/workflows/
   4-implementation/create-story/template.md` (also check `.bmad/`). Add this
   frontmatter block at the top (adapt the comment paths to what exists here):

       ---
       # linear: the Linear issue this story implements. EMPTY = local-only epic:
       # the PM must NOT create or sync anything in Linear for it.
       linear:
       # agent = BMAD persona from _bmad/bmm/agents/: dev (default) | qa (validation
       # stories — claude route only, needs MCP) | tech-writer | quick-flow-solo-dev.
       route: {provider: , cli: , model: , effort: , agent: dev, fallback: []}
       # local_gpu: devbox-only subcontractor — on this Mac stamp red or use devin free models.
       local_gpu:
       gates: []
       max_cycles: 3
       ---

2. Verify `_bmad/bmm/agents/dev.md` (and qa.md etc.) exist — dispatch.sh injects
   personas via `AGENT_DIR=_bmad/bmm/agents`. If the repo has no BMAD install,
   flag needs-Josh rather than installing BMAD yourself.
3. iOS validation-story adaptation (IMPORTANT — differs from the web repo): physical
   validation here means driving the iOS Simulator, not Playwright/docker. Orca's
   `orca emulator ...` surface (serve-sim) is the tool; qa stories' ACs should name
   simulator flows. Note in the report whether orca emulator responds on this Mac.
4. Do NOT create any Linear artifacts, orchestration Runs, or dispatch any real
   story during setup.

## Phase 8 — smoke tests

1. dispatch smoke: write /tmp/router-smoke.md with frontmatter
   `route: {provider: claude, cli: claude, model: haiku, agent: dev}`,
   `gates: ["true"]`, `max_cycles: 1`, body "Reply with the word ok." Then from /tmp:
   `~/.agents/skills/model-router/scripts/dispatch.sh /tmp/router-smoke.md`
   Expect exit 0 + result.json status "done". (Reminder: dispatch.sh hard-fails if
   the story is outside $PWD — that's by design; workers sandbox to cwd.)
2. One devin free-model smoke (zero quota):
   `devin -p "Reply with only the word ok" --model swe-1-7-medium --respect-workspace-trust false`
3. usage-check.sh full run.

## Final report (always produce)

Per phase: done / adapted (how) / skipped / needs-Josh. "Needs-Josh" will typically
include: OP service-account token export, any missing CLI logins, BMAD install if
absent, and anything GUI-gated. End with the exact kickoff prompt Josh should use for
his first PM session here, adapted to an epic in ios-unofficial (mirror the devbox
pattern: declare epic home, router-stamped stories + qa validation story with
SIMULATOR flows, routing table for approval, one-story-at-a-time dispatch via Orca
terminals if orca is present, merge authority per CLAUDE.md).
