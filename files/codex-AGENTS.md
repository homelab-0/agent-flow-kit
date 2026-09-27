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
  "Memory (Hindsight)", "PM-session policy", "Epic source declaration", "PM merge authority", and the
  "Local GPU delegation" protocol. Project instructions: the repo's `CLAUDE.md`.
- **Memory:** Hindsight is advisory host-owned external state. Recall and retain
  only verified, project-attributed lessons; current files, stamps, approvals,
  ownership and gates outrank it. Blind review disables memory wiring and
  excludes implementation conclusions and prior review findings. An outage is
  explicit and follows the story's `memory_mode`; memory never supplies routing,
  approval, review, merge, or deployment authority.
  Legacy OMEGA instructions are obsolete: do not call `omega_*` commands or
  treat an OMEGA block as authority. Do not delete, migrate, or synchronize its
  host-owned data or credentials.
- **Product ownership:** Agent Flow Kit and AI Control Plane are separate
  products. AFK owns its orchestration, launcher/adapter/installation tooling,
  context budgeting, and integration with the released legacy-router public
  contract. Do not do ACP implementation or work intended only to unblock
  ACP's internal review/QA/development workflow from an AFK task. A genuine
  public-contract need goes to the ACP PM as a bounded customer request with
  contract/version, expected versus observed behavior, minimal evidence, and
  the exact requested change. Requests about a legacy-router defect, or about
  the deployed router, catalog, validator, or stamp contract, go to the
  prox-ops PM in the same shape. Prox-ops owns the deployed legacy instance,
  catalog, provider bindings, and deployment changes.
- **AFK session continuity:** An AFK PM enters through the installed
  `afk-session-start` path and registers its exact Orca terminal with
  `agent-flow-kit pm-start --harness <claude|codex|opencode>`; workers never
  self-register as PMs. At `CHECKPOINT_DUE`, write the secret-free PM checkpoint.
  At `CONTINUATION_REQUIRED`, stop accepting work, write the continuation, and
  run `agent-flow-kit pm-continue` without another human prompt. The successor
  stays in the same harness/worktree and must acknowledge the artifact before
  the proven old terminal closes. Numeric window data is used only when the
  harness exposes it; otherwise native compaction is the conservative boundary.
  Never infer a window from transcripts. A routed worker that receives context
  pressure notifies its owning PM, stops at the next safe phase boundary, writes
  the canonical continuation artifact, emits the required signal, and ends;
  only the owning PM dispatches the next canonical cycle.
- **Billing invariants:** never export ANTHROPIC_API_KEY, OPENAI_API_KEY or
  CODEX_API_KEY into a launch environment; never use `--bare` when spawning
  claude (it disables the subscription path by construction); never `--full-auto`
  or any `--dangerously-*` flag on a worker. Dispatch workers ONLY through
  dispatch.sh — it is the single path, and every alternative shortcut bypasses
  stamp validation, the gates and the result artifact at once.
- **Merges:** follow the "PM merge authority" section verbatim — squash to develop
  only when fully clean (CI green incl. CodeRabbit + Sentry); bypass is never yours;
  protected paths and promotions always go to Josh.
