# Global agent guidance (Josh's machines)

When acting as the BMAD PM — or any planning/routing role in the model-router flow —
from this CLI, the same skill and guardrails apply as in Claude Code:

- **Routing skill + registry:** `~/.agents/skills/model-router/` (SKILL.md,
  subscriptions.yaml, scripts/dispatch.sh, scripts/usage-check.sh). Read SKILL.md
  before stamping any `route:` frontmatter; run `scripts/usage-check.sh` at planning
  start. Never route to a provider absent from subscriptions.yaml.
- **Operating policies** live in `~/.claude/CLAUDE.md` (single source of truth,
  regardless of which CLI you run in) — read and follow these sections exactly:
  "PM-session policy", "Epic source declaration", "PM merge authority", and the
  "Local GPU delegation" protocol. Project instructions: the repo's `CLAUDE.md`.
- **Project memory index:** `~/.claude/projects/<project-slug>/memory/MEMORY.md`.
- **Billing invariants:** never export ANTHROPIC_API_KEY; never use `--bare` when
  spawning claude; dispatch workers only via the router's dispatch paths.
- **Merges:** follow the "PM merge authority" section verbatim — squash to develop
  only when fully clean (CI green incl. CodeRabbit + Sentry); bypass is never yours;
  protected paths and promotions always go to Josh.
