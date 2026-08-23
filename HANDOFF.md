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
- Design intent, so adaptations stay on-mission: PM plans epics → describes each
  story to the central router (`POST /v1/route`) → a human accepts or
  deliberately overrides the recommendation → the decision is frozen into an
  immutable execution stamp → dispatch.sh places (when required), validates the
  stamp fail-closed, and launches a persona-injected worker in a visible Orca
  worktree/terminal → deterministic gates → review gates → PR → post-PR triage
  loop → PM merges under guardrails. Humans decide: protected paths, promotions,
  bypasses, true secrets, and every route.
- The router is the SOLE routing authority. There is no local routing table, no
  tier lookup and no runtime fallback chain any more. Re-routing means a new
  `/v1/route` call and a new stamp, made by a planning session with a human in
  the loop — never a decision dispatch makes on its own.

## Phase 0 — preflight (report, fix nothing except yq)

1. `command -v yq jq curl claude codex orca agent-stamp-validate op bunx uvx` —
   note missing. yq must be mikefarah v4+ (installing yq to a PATH dir IS yours
   to do if absent). `agent-stamp-validate` is built from the control-plane repo
   (`services/agent-router`); without it dispatch cannot validate a stamp and
   will refuse every launch, which is the correct behaviour, not a workaround
   to route around.
2. Auth MODE — **not liveness.** `claude auth status` (expect `authMethod:
   claude.ai`, `apiProvider: firstParty`); `codex doctor` (auth section).
   These report what kind of credential record EXISTS. They do NOT prove it
   still works: on the validated host `codex login status` reported "Logged in
   using ChatGPT" (exit 0) for two stores that both failed on the first real
   turn with a spent refresh token. **Never gate a launch on a status command** —
   it will wave a dead session straight into a run. The honest options are a
   real trivial turn, or accepting the auth failure at launch. Missing or
   API-key-mode logins → needs-owner (interactive; login is never automated,
   never scripted, and OAuth material is never copied between stores or hosts).
3. `env | grep -c OP_SERVICE_ACCOUNT_TOKEN` — a 1Password service-account token
   machine-wide makes `op read`/`op run` promptless (this is what makes secret-
   dependent gates autonomous). If absent: needs-owner — "export the existing
   service-account token via an untracked env file sourced by the shell rc"
   (reference: `~/.op-agent-env` + one rc line; on nix-managed hosts the rc line
   goes in the flake, the env file stays untracked).
4. `env | grep -i ANTHROPIC_API_KEY` must be empty. Same for `CLAUDE_CONFIG_DIR`:
   dispatch fails closed on a non-default value, because only Claude's DEFAULT
   store under the approved HOME is a validated launch path.
5. `orca status --json`. **Orca is required, not optional.** Dispatch refuses to
   launch from anywhere that is not an Orca-managed worktree: a worker with no
   worktree card and no terminal tab is invisible, and an invisible worker is
   not a supervised one. There is no headless degradation mode.
6. Router reachability: `curl -sS -o /dev/null -w '%{http_code}\n' \
   -H "Authorization: Bearer $AGENT_ROUTER_TOKEN" <router>/v1/status`.
   The caller token comes from the owner's secret store and is NEVER written
   into any file in this kit — `subscriptions.yaml` names the environment
   variable, never its value.

## Phase 1 — install the model-router kit

    cp -r files/model-router ~/.agents/skills/model-router
    ln -s ~/.agents/skills/model-router ~/.claude/skills/model-router   # if absent
    chmod +x ~/.agents/skills/model-router/scripts/*.sh

Scripts shipped: `dispatch.sh` (validate → place → Orca-visible launch → gates →
thin result), `make-stamp.sh` (accepted `/v1/route` decision → immutable stamp),
`usage-check.sh` (observability only), `github-health.sh`.

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

## Phase 4 — point the launcher at the control plane

`files/model-router/subscriptions.yaml` is no longer a routing registry. It is
LAUNCHER CONFIGURATION: where the router lives, which env var carries the caller
token, which trusted catalog the stamp validator loads, and which local binary
implements each harness. Nothing in it names a harness, a model or an effort for
a task, and nothing may be added that does.

1. `launcher.router_endpoint` — confirm it resolves from this machine.
2. `launcher.caller_token_env` — confirm the named variable is populated in the
   owner's shell (same untracked-env-file pattern as the 1Password token). NEVER
   write the token itself into the file.
3. `launcher.catalog_path` — the trusted catalog DOCUMENT (not the ConfigMap
   wrapper) that `agent-stamp-validate` loads. This is trusted policy material
   and is always installer configuration: it is never accepted from a stamp or
   from stdin, because a workload must not choose its own policy authority.
   `AGENT_STAMP_VALIDATE_CATALOG_PATH` overrides it.
4. `launcher.harness_binaries` — confirm each named binary exists on PATH.
   Model IDs are NOT configured here any more; the physical model behind a
   profile comes from the catalog, and moves by catalog PR underneath a stable
   profile name.
5. Run `scripts/usage-check.sh` and include output in the report. It is
   observability only and emits no routing guidance; a degraded collector is
   graceful and expected — report, don't hack.

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
       # stamp: path to the immutable ExecutionStamp written by make-stamp.sh from
       # an accepted POST /v1/route decision. Defaults to <story>.md.stamp.json.
       # The stamp's property set is CLOSED — persona, gates and cycle policy have
       # no home in it and live out here as siblings.
       stamp:
       # persona = BMAD persona injected at dispatch: dev (default) | qa
       # (validation stories) | tech-writer | quick-flow-solo-dev | analyst.
       # The named file MUST exist under the launcher's agent_dir or dispatch
       # refuses — persona injection never silently no-ops.
       persona: dev
       # gates: the exact commands that define done. An EMPTY list is INVALID:
       # it cannot tell done from claimed-done, and dispatch refuses to run.
       gates:
         - "<real command>"
       max_cycles: 3
       ---

   There is no `route:` block and no `local_gpu:` pre-assessment. Routing lives
   in the stamp; dispatch REFUSES a story that still carries a `route:` block
   rather than ignoring it, because a stale local route block that looks
   authoritative is worse than none. Local-GPU work is expressed as the
   catalog's local profiles plus `placement_policy`, resolved late by
   `/v1/place` — not as a human-stamped hint.

2. Personas: dispatch.sh injects `<launcher.agent_dir>/<persona>.md` (default
   `_bmad/bmm/agents` — the same path this phase creates; a mismatch here used
   to make persona injection a silent no-op). If the repo uses the skills
   layout, create `_bmad/bmm/agents/` with symlinks to the installed
   `bmad-agent-*` SKILL.md files. Verify at least `dev.md` resolves. Missing
   personas (e.g. qa) → needs-owner: dispatch will fail loudly rather than run
   the wrong persona and report success.
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

1. **Kit self-tests (no network, no harness launch):** `tests/run-tests.sh` from
   the kit checkout. It shellchecks every script, asserts the generated harness
   commands against both frozen launch contracts, and drives dispatch.sh through
   every refusal path with stubbed orca/validator/router binaries. All green is
   the bar; investigate any failure before installing.
2. **Router round-trip (read-only):** POST a throwaway RouteRequest and inspect
   the recommendation without stamping it:
   `curl -sS -X POST "$ROUTER/v1/route" -H "Authorization: Bearer $AGENT_ROUTER_TOKEN"
    -H 'Content-Type: application/json' -d '{"story_id":"SMOKE-1","title":"smoke",
    "ambiguity":"low","blast_radius":"low","context_size":12000,"volume_hint":"low",
    "tags":["docs"]}' | jq .`
   Expect an ExecutionProfile with harness/model_profile/effort/expires_at.
   All four classification axes are shown deliberately: `ambiguity` and
   `blast_radius` are required, `context_size` and `volume_hint` are optional,
   and a smoke test that exercises only the required pair leaves the two signals
   most likely to be mis-filled untested.
3. **Stamp round-trip:** run the same request through
   `scripts/make-stamp.sh --request <f> --out /tmp/smoke.stamp.json --check`.
   Expect a closed stamp whose `expires_at` is byte-identical to the response's,
   and an advisory validator verdict.
4. **Dispatch smoke:** only inside a real Orca worktree, with a real stamp and a
   real gate. Do NOT invent a story with `gates: []` — dispatch refuses it by
   design, and that refusal is itself worth observing once.
5. `scripts/usage-check.sh` and `scripts/github-health.sh` full runs.

## Final report (always produce)

Per phase: done / adapted (how) / skipped / needs-owner. End with a kickoff prompt
for the owner's first PM session on this machine, adapted to a real epic in the
target repo: declare the epic home (tracker vs local), router-stamped stories +
trailing validation story with project-appropriate physical flows, routing table
for approval before dispatch, one story at a time (visible Orca dispatch if
available), merge authority + triage loop + PR language law per CLAUDE.md.
