<!-- OMEGA:BEGIN — managed by omega setup, do not edit this block -->
## Memory (OMEGA)

You have OMEGA persistent memory. At session start:
1. Call `omega_welcome()` for context briefing
2. Call `omega_protocol()` for your operating instructions — it's your coordination playbook
3. Follow the protocol it returns

Quick reference (protocol has full details):
- `[MEMORY]`/`[HANDOFF]`/`[COORD]` blocks from hooks = ground truth
- Before non-trivial tasks: `omega_query()` for prior context
- After completing tasks: `omega_store(content, "decision")` for key outcomes
- User says "remember": `omega_store(text, "user_preference")`
- Context getting full: `omega_checkpoint` to save state
- Load user context: `omega_profile()` after welcome/protocol
- Before architecture decisions: `omega_reflect(action="evolution", topic=<domain>)` to check prior thinking
- After `omega_store`: check `omega_memory(similar)` and link related memories to build the knowledge graph

### Multi-Agent Coordination
- Check `omega_inbox()` for unread peer messages early in sessions
- Announce intent: `omega_intent_announce(description="<goal>")` before starting work
- Before editing shared files: `omega_file_check(file_path=...)` for conflicts
- After significant work: `omega_task_complete(task_id=..., result="summary")`
- Before deploy/force-push: `omega_action_check()` then `omega_action_claim()` (atomic gate)
- Never `git add .` — always `git add <specific files>`

If OMEGA is unavailable, use basic coordination:
- Before state changes: check `git log` and ask before deploying
- Never send emails, post tweets, or take externally-visible actions without explicit approval
- Commit only files you modified; `git add <files>` never `git add .`
- After tasks: store decisions with `omega_store()`
<!-- OMEGA:END -->

## Local GPU delegation (junior-dev protocol)

A self-hosted qwen36-27b (homelab GPU, LiteLLM) is available for offloading scoped coding
work to save cloud tokens. Treat it as a **junior dev**: it drafts, it never ships.
Evaluation + recommendation matrix: `_bmad-output/planning-artifacts/qwen36-local-model-evaluation-2026-07-10.md`
(GlycemicGPT repo). Delegation tool: `~/.claude/local-model/delegate.sh`.

### When to consider delegating (assess at task pickup)
- GREEN: unit tests for existing pure code; bug fixes pinned by a failing test/error output;
  mechanical refactors; boilerplate per an existing pattern; first-pass review triage;
  long-file comprehension. Small surgical stories (1-2 files, clear acceptance criteria).
- RED — never delegate: safety-critical code (dosing, alert floor, ingestion mappers,
  `safety_validation.py`), architecture/design, cross-cutting changes, CI/dependency changes,
  anything needing project invariants it cannot see.

### Protocol (the human does nothing different — YOU drive)
0. VERDICT BANNER (required, chat only — never in commits/PRs): when picking up each
   task/story, make the FIRST line of your response the delegation verdict so it is
   impossible to miss:
   `🖥️ Local GPU → 🟢 GREEN — delegable, asking below`
   `🖥️ Local GPU → 🟡 YELLOW — <short reason>, delegating with tight brief / driving myself`
   `🖥️ Local GPU → 🔴 RED — <short reason>, cloud drives`
   While a delegation runs, prefix status updates with `⚡`; when reporting its outcome,
   lead with `🖥️ GPU draft: <ok/failed> in <time> — review found <N> findings`.
1. When a task/story qualifies as GREEN, ask the user ONCE via AskUserQuestion:
   "This looks delegable to the local GPU (est. cloud-token saving). Delegate?" Respect a "no"
   without re-asking for that task. If the user has expressed a standing preference, honor it.
2. On yes: create/reuse a git worktree (never the main checkout), write a task brief to a file:
   scope, exact file paths, acceptance criteria, RELEVANT PROJECT SAFETY RULES pasted in
   (it invents plausible-but-wrong constants without them — e.g. glucose 20-500 mg/dL),
   and the verify commands. CONTEXT BUDGET: the server has a hard 65,536-token window and
   open-ended discovery blows it (a broad "look at src/routers/" brief died at turn 13).
   Name the exact SMALL template files to read and forbid broad exploration; also pass
   institutional constraints the files don't show (e.g. GLY-123: glucose reads go through
   the cgm_source funnel). Then run:
   `~/.claude/local-model/delegate.sh --dir <worktree> --task-file <brief> --verify '<cmd>' --label <short-name>`
   (auto-retries once with verify feedback; statusline shows "⚡ GPU: <label>" while running).
3. MANDATORY REVIEW — hard requirement, never skip: review the resulting diff yourself as a
   senior engineer (correctness, conventions, vibe-code smell, safety invariants, test
   meaningfulness), run the project's real gates, and fix findings yourself. The local model's
   output NEVER reaches a commit, PR, or the user unreviewed.
4. Escalation: if delegate.sh returns verify_failed/error after its retries, or review finds
   fundamental problems (wrong approach, invented APIs, safety violations) — take the task
   over and do it yourself. Max ONE delegation round per task after a failure; never
   ping-pong. Report to the user what was delegated, what the review found, and net outcome.
5. Never let the local model author commits/PRs (delegate.sh already blocks git commit/push/gh).

## Model & effort routing (BMAD flow)

Guidance for choosing which model/effort a session should run under, and what the BMAD PM
should recommend in dev handoffs. Cost order: local GPU (free) < Sonnet < Opus < Fable 5;
ultracode multiplies whatever model it runs on.

### Dev-session model, by story profile
- **Sonnet 5** — clear spec + contained blast radius: boilerplate-heavy stories, test
  authoring, mechanical refactors, single-module features with named files, doc updates.
  The dev-loop gates (adversarial review, CodeRabbit, CI) are the safety net.
- **Opus 4.8** — the default for standard senior work: multi-file features, debugging,
  integrations, moderately ambiguous specs. Fast mode (/fast) is Opus at faster output —
  good for long mechanical sessions.
- **Fable 5** — when a plausible-but-wrong answer is expensive: safety-critical paths
  (dosing, alert floor, ingestion mappers, safety_validation.py), architecture decisions,
  subtle concurrency (BLE, wear sync, coroutines), gnarly cross-cutting debugging,
  promotion-gate work, security-sensitive changes.
- **Local qwen36-27b** — never the driver; GREEN-profile subcontracted drafts under any
  cloud driver per the delegation protocol above.

### Ultracode / effort
- Ultracode = multi-agent orchestration; its value is INDEPENDENT VERIFICATION and
  COVERAGE (fan-out review, adversarial verify, wide research) — not smarter typing.
  Use for: pre-promotion reviews, deep audits, epic-level plan/alignment reviews,
  post-dev validation of safety-critical stories. Do NOT use for routine implementation,
  story bookkeeping, or handoff writing.
- Higher /effort raises reasoning depth within one agent — use for hard debugging or
  design turns; keep standard effort for routine turns.

### PM-session policy (epic-level: tracking, handoffs, validation)
- The PM works at EPIC altitude: what to do next, alignment, drift — it never drives
  single stories. Launch it on **Opus, standard effort**. Permanent ultracode on the PM
  burns tokens without adding alignment quality.
- EFFORT SELF-ASSESSMENT (first response when picking up an epic, and again per task):
  the PM cannot toggle its own session, but ultracode can be granted per-message by the
  user including the word "ultracode" in that prompt (or via /effort). So the PM must
  flag heavy turns BEFORE doing them, with a visible line:
  `🧭 Effort: this <alignment audit|promotion review> warrants ultracode — reply with
  "ultracode: go" for this step (or /effort), otherwise I'll do a standard pass`.
  Ultracode-worthy PM turns: epic-level alignment audits across many merged stories,
  promotion-readiness reviews, independent validation of safety-critical work. Routine
  turns (story writing, handoffs, status tracking) never warrant it — don't ask.
- PM DEV-HANDOFF TEMPLATE — every dev handoff prompt must end with a routing block:
  ```
  ## Routing
  - Dev model: <sonnet|opus|fable5> — <one-line why>
  - Effort: <standard|high|ultracode> — <one-line why, default standard>
  - Local-GPU pre-assessment: <🟢|🟡|🔴> — <one-line why>
  - Post-dev validation: <what the PM will check on return>
  ```
- SEPARATE REVIEWER HANDOFF (three-role flow) — the PM must NOT line-review code
  itself. For stories that meet ANY of: safety-critical paths touched, large/multi-module
  diff, promotion-bound, or the dev session self-reported difficulties — the PM produces
  a REVIEWER handoff prompt for a fresh session (bmad dev persona or /code-review),
  with its own model recommendation (reviewer model >= implementer model; Fable 5 for
  safety-critical). Template ending:
  ```
  ## Reviewer routing
  - Review model: <opus|fable5> — <why>; ultracode if promotion-bound
  - Focus: <specific risk areas the PM wants pressure on>
  - Return: a completed-work summary (AC coverage, findings + resolutions, gate evidence)
  ```
  For ordinary stories the dev loop's own gates (adversarial + senior review, CodeRabbit,
  CI) suffice — do not spin a third session for every story; that is ceremony, not rigor.
- PM validation on return (dev summary or reviewer summary): check AC coverage, scope
  drift vs the epic, and gate evidence — alignment only, never code line-review.

### Epic source declaration (single source of truth per epic)
Every epic declares its home at kickoff — Josh states it, or the PM asks ONCE before
creating stories: `linear:<project or parent issue>` OR `local:<path under _bmad-output/>`.
That home is the only tracker for the epic; never mix:
- **Linear-homed epic**: issues seeded/synced per the flow (status, PR attach, verdict
  comments). Story frontmatter carries the issue ID in `linear:`.
- **Local-homed epic** (internal/not-yet-public work): lives entirely in _bmad-output/;
  story `linear:` stays EMPTY and the PM must NOT create issues, comments, or any
  Linear artifact for it — no leaks of internal scoping into Linear. Tracking updates
  go to the local epic file / PROGRESS.md instead.
- Promotion between homes (e.g. a local epic goes public in Linear) happens only when
  Josh explicitly says so; the PM may suggest it but never does it unprompted.
- Dispatch, routing, gates, and merge policy are identical for both homes — the home
  only changes where tracking state is written.

### PM merge authority (story PRs → develop) — ratified 2026-08-16, ACTIVE
Status: **active** (Josh skipped dry-run 2026-08-16 — the flow is autonomous by
design; stacking unmerged PRs loses the value).

The PM may squash-merge a story PR into develop ON ITS OWN iff ALL hold:
- Story was PM-planned with stamped route + gates; the diff stays inside the story's
  declared file surface (any scope drift → hold).
- No protected paths touched — these ALWAYS escalate to Josh: dosing/insulin logic,
  alert floor, ingestion mappers, safety_validation.py, auth, data migrations, CI
  workflow files, dependency/lockfile changes, CODEOWNERS/governance.
- Full gate evidence on record: automated checks, adversarial + senior reviews with
  findings fixed, CodeRabbit clean and every comment replied, security review clean,
  Sentry gate where warranted.
- CI green, no unresolved review threads, no external human engagement on the PR
  (external engagement → confirm-before-acting rule applies).
- The merge decision is made on GATE EVIDENCE only — the PM never line-reviews the
  diff to justify a merge (three-role separation stands).
- Squash-merge, develop only. NEVER main, promotion PRs, releases, or --admin.
  Promotions to prod remain Josh's decision, always.
- **Ideal state before any merge decision: PR fully clean — CI green including
  CodeRabbit and the Sentry gate — THEN the PM decides.** Engineer toward clean:
  fix what's fixable, re-run flaky checks, resolve CodeRabbit threads.
- **Bypass is never the PM's button.** If a merge would require the branch-protection
  bypass (CI red for reasons outside the change — known path-gate artifacts, stuck
  required checks, documented flakes), the PM does NOT merge: it diagnoses WHY each
  red check is red, confirms it's genuinely unrelated to the change, and escalates
  to Josh with that diagnosis and a merge recommendation — Josh presses bypass.
  Aim to make this rare; a bypass request without a per-check diagnosis is a bug.
- Log every merge in the epic tracker for async audit; any doubt → hold and ask.

**Post-PR triage loop (REQUIRED between PR creation and any merge decision):**
Opening the PR starts a second review wave — CI, CodeRabbit's PR-level review
(broader context than its CLI), GitGuardian, Sentry checks. The PM must work this
wave to clean, never merge past it, and never line-triage it itself:
1. After PR creation, WAIT for all checks to complete (`gh pr checks --watch` or
   poll) and for CodeRabbit's PR review to post. No merge decision on pending checks.
2. If anything is red or has findings, dispatch ONE **PR-triage worker** per round
   (BMAD `dev` persona, claude route — it needs gh + the MCP toolchain; fresh
   session, not the PM). Its brief: evaluate every failure/finding and either fix
   it on the branch or justify it, specifically:
   - **CI failures**: diagnose real-vs-known-flake (check the CI-triage memories);
     real → fix + push; flake → document in a PR comment, rerun.
   - **CodeRabbit PR findings**: fix what's right; for what's wrong, reply with a
     short correcting comment — CodeRabbit LEARNS from replies, so every finding
     gets a reply either way (existing rule: reply to every CodeRabbit comment).
   - **GitGuardian**: verify true/false positive (precedent: tandem_password
     fixture was false) — the GitGuardian MCP server is installed user-scoped on
     this host (tools: list_incidents / get_incident / scan_secrets /
     manage_private_incident / manage_incident_comment). FALSE positive → the
     triage worker resolves/ignores the incident ITSELF via
     manage_private_incident, adds an incident comment with the justification,
     notes it in a PR comment, and re-requests the check — no human button.
     TRUE secret → stop, rotate, escalate to Josh immediately; never resolve a
     true hit without rotation.
   - **Sentry PR findings**: real → fix; and give thumbs-up/down feedback on each
     finding — Sentry learns from it exactly like CodeRabbit learns from replies.
3. Worker pushes fixes → checks re-run → repeat from step 1. Max 3 triage rounds,
   then escalate to Josh with a per-finding summary.
4. Only when ALL checks are green, every CodeRabbit thread is replied-to/resolved,
   and Sentry findings are dispositioned does the merge decision happen (or the
   protected-path escalation to Josh, with a "PR is clean" note attached).

**PR discipline: platform health + size (added 2026-08-17)**

*GitHub health gate.* Before creating a PR, merging, or starting any story whose
branch must fork from a not-yet-merged develop update, run
`~/.agents/skills/model-router/scripts/github-health.sh` (public status API, no
auth). Non-zero exit → HOLD all GitHub-side operations: park finished work on its
own story branch/worktree, poll roughly every 15 minutes, resume when operational.
An outage NEVER changes PR boundaries — do not keep implementing dependent stories
onto unmerged branches "to keep moving" unless explicitly opening a stacked-PR
chain (below). Batching multiple stories into one branch/PR because GitHub was
down is the failure mode this gate exists to prevent. Note the check judges the
overall indicator, not just the named components — a degraded component unrelated
to git/PR/Actions (e.g. Copilot) may be waived with a one-line note.

*PR sizing.* One PR = one story, always; squash-merge preserves that mapping.
Size budget for the REVIEWABLE diff — excluding generated files (committed
contracts, generated types, lockfiles), which must be called out as generated in
the PR body: beyond roughly **800 added+changed lines or 25 files**, do not ship
one PR. Split into a **stacked-PR chain** (GitHub stacked PRs / `gh stack`,
public preview) with each layer independently human-reviewable and ordered so
lower layers make sense alone; verify the gh stack tooling is available first and
fall back to sequential small PRs if not. A PR too large for a human to actually
review is UNACCEPTABLE regardless of tooling — if stacking can't restore
reviewability, the story was mis-scoped: stop and re-plan it with Josh instead of
shipping the blob. The PM estimates diff size at planning (oversized story =
split the story, not the PR after the fact); workers report final diff size in
the story's Dev Agent Record; the post-PR triage worker flags budget violations.
