# Global agent guidance (Josh's machines)

When acting as the BMAD PM — or any planning/routing role in the model-router flow —
from this CLI, the same skill and guardrails apply as in Claude Code:

- **Routing skill:** `~/.agents/skills/model-router/` (SKILL.md,
  subscriptions.yaml, scripts/dispatch.sh, scripts/make-stamp.sh,
  scripts/usage-check.sh). Read SKILL.md before routing anything.
  **`POST /v1/route` is the sole routing authority.** You do not pick a harness,
  a model or an effort from a table; you describe the task on the four axes, call
  the router, accept or deliberately override the recommendation, and freeze it
  with `scripts/make-stamp.sh`. `subscriptions.yaml` is launcher configuration
  (endpoint, caller-token env NAME, catalog path, harness binaries) — not a
  routing registry, and never a place to put a secret.
- **The sequence is route → stamp → validate → place → launch.** dispatch.sh
  fetches placement when the stamp requires it, runs `agent-stamp-validate`
  fail-closed immediately before launch, and refuses on anything short of a
  clean verdict. There is no fallback chain: a re-route is a NEW `/v1/route`
  call and a NEW stamp, with a human in the loop.
- **Login/status commands are not liveness checks.** `codex login status` and
  `claude auth status` report what kind of credential record exists, not that it
  still works — one reported "Logged in using ChatGPT" for two stores that both
  failed on the first real turn. Never gate a launch on them.
- **Operating policies** live in `~/.claude/CLAUDE.md` (single source of truth,
  regardless of which CLI you run in) — read and follow these sections exactly:
  "PM-session policy", "Epic source declaration", "PM merge authority", and the
  "Local GPU delegation" protocol. Project instructions: the repo's `CLAUDE.md`.
- **Project memory index:** `~/.claude/projects/<project-slug>/memory/MEMORY.md`.
- **Billing invariants:** never export ANTHROPIC_API_KEY, OPENAI_API_KEY or
  CODEX_API_KEY into a launch environment; never use `--bare` when spawning
  claude (it disables the subscription path by construction); never `--full-auto`
  or any `--dangerously-*` flag on a worker. Dispatch workers ONLY through
  dispatch.sh — it is the single path, and every alternative shortcut bypasses
  stamp validation, the gates and the result artifact at once.
- **Merges:** follow the "PM merge authority" section verbatim — squash to develop
  only when fully clean (CI green incl. CodeRabbit + Sentry); bypass is never yours;
  protected paths and promotions always go to Josh.
