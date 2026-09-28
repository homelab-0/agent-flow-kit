# agent-flow-kit

A portable autonomous development flow for **any project that uses BMAD**, driven by
a central routing control plane. One PM session plans epics and describes each story
to the router; a human accepts or deliberately overrides the recommendation; the
decision is frozen into an immutable execution stamp; disposable worker sessions
(Claude Code, Codex, and OpenCode) execute them in visible Orca worktrees with BMAD personas
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

For the cross-harness status, continuation, onboarding, update, and live
qualification contract, see [`docs/RUNTIME-EXPERIENCE.md`](docs/RUNTIME-EXPERIENCE.md).

- `HANDOFF.md` — executable setup instructions for a fresh agent on a new machine.
  Idempotent; presentation adapts across Linux/macOS, while automatic release
  reconciliation is currently qualified only on Linux.
- `bin/agent-flow-kit` — the lifecycle entry point. Explains what is installed on a
  host, who owns it, which revision it came from, what has drifted, whether this
  checkout is eligible to change it — and converges it when it is.
- `lib/afk-*.sh` — the lifecycle implementation: primitives, source eligibility,
  the declared component/ownership model, the command surface, the mutation plan
  and the transaction (lock, journal, backups, rollback, verify, commit).
- `lifecycle/kit.json` — the source declaration: kit identity, schema versions,
  canonical branch and the managed input set.
- `docs/LIFECYCLE-CONTRACT.md` — the documented, versioned machine contract:
  states, reason codes, ownership classes, evidence provenance, plan and
  operation vocabularies, exit semantics. Every vocabulary in it is
  machine-checked against `agent-flow-kit schema`.
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
- `tests/run-tests.sh` — the aggregate gate: shellcheck, contract conformance,
  refusal-path proofs, and both lifecycle gates below. Runs offline with stubbed
  orca/validator/router binaries; launches no harness. Before doing any work it
  takes a host-wide lock (`${XDG_RUNTIME_DIR:-/tmp}/agent-flow-kit-test-suite.lock`,
  `AFK_TEST_LOCK=off` to disable, `AFK_TEST_LOCK_TIMEOUT=<s>` to bound the wait) so
  two full runs on one machine never overlap; it prints each child suite's wall
  time and the run's total, with a `BUDGET` warning (never a failing exit) over
  240s per suite or 720s total.
- `tests/runner-lock-tests.sh` — hermetic gate for that lock: contention, the
  printed holder line, the timeout, stale-lock reclaim, `AFK_TEST_LOCK=off`, and
  the nested child not re-taking it.
- `tests/lifecycle-tests.sh` — the read-only lifecycle gate: ownership, drift,
  adaptation, source eligibility, path/symlink refusal, redaction anti-vacuity,
  schema stability and exit semantics, all against throwaway homes and checkouts.
- `tests/lifecycle-mutation-tests.sh` — the destructive-path gate: managed-section
  insertion and upgrade, byte-for-byte preservation of user-owned content, plan
  identity and approval invalidation, drift refusal, adaptation dispositions,
  symlink attack, concurrent mutation, backup/rollback, injected mid-operation
  failure, interruption recovery and idempotent no-op — every one of them in an
  isolated temporary HOME. Takes the same host-wide lock as `run-tests.sh` when
  run standalone; skips it when launched as that script's child (already held).
- `files/humanizer/` — prose de-AI-ification skill, REQUIRED for the PR language
  law (no AI attribution, no internal-methodology vocabulary in public text)
- `files/claude-global-CLAUDE.md` — the policy layer to merge into a machine's
  `~/.claude/CLAUDE.md`: the route→stamp→validate→place sequence, PM policy, epic
  source declaration, merge authority + post-PR triage loop, PR language/size/health
  discipline
- `files/codex-AGENTS.md` — same policies, pointer form, for Codex-launched PMs

## Understanding a host

    bash bin/agent-flow-kit status              # human-readable
    bash bin/agent-flow-kit status --json       # the machine contract
    bash bin/agent-flow-kit adopt --inspect     # what adoption would do; changes nothing
    bash bin/agent-flow-kit verify              # prove the installed state, offline
    bash bin/agent-flow-kit schema              # the published vocabularies

`status`, `adopt --inspect` and `verify` are pure functions of local state: they
write nothing, contact nothing external, and return byte-identical output for
unchanged state. Network- and auth-dependent facts report `NOT_EVALUATED`; they are
never optimistically called ready. `verify` observes and proves — it never repairs.

## Changing a host

    bash bin/agent-flow-kit adopt --plan        # the complete plan; writes nothing
    bash bin/agent-flow-kit adopt               # establish ownership, then verify
    bash bin/agent-flow-kit update --plan       # what convergence would do
    bash bin/agent-flow-kit update              # converge, or refuse

Both mutating verbs compute their complete plan before the first write, hold an
exclusive lock, back up what they will touch, journal their intent, write, verify
the result offline, and only then commit the applied-state manifest. A failure
restores what it changed and proves the restoration; the applied revision moves
only after everything succeeded.

Adoption establishes ownership at the identities already installed — it never
overwrites content by adopting it. Update replaces only kit-owned content that
still matches its recognized applied state: unexplained drift, a redirected path,
malformed section markers or an adaptation that asks for review all refuse the
whole plan rather than converging part of it. Content outside a managed section,
declared machine-local configuration and target-project content are preserved.

A plan that crosses an ambiguity or ownership boundary prints a stable identity and
authorizes nothing until you approve exactly that plan:

    bash bin/agent-flow-kit adopt --approve-plan sha256:<identity>

The identity covers every input the plan was computed from, so an approval never
carries over to a plan recomputed after anything changed.

The lifecycle transaction never changes a development clone: it does not pull,
reset, stash, merge, rebase, clean, or switch the user's branch. The separate
release client maintains its own bare mirror and isolated candidate checkout from
AFK's fixed public `master` ref, then hands an immutable revision to that lifecycle
transaction.

Exit codes are coarse and stable: `0` the requested scope succeeded, `1` a command,
internal or usage failure, `2` owner action or conflict, `3` deterministic
not-ready, `4` a source or precondition refusal, `5` a live dependency unavailable.

## Update discipline

This repo is the release channel between machines. After initial enrollment on
Linux, `afk-session-start` checks the fixed public `master` ref before harness work,
qualifies a clean isolated candidate, applies the exact approved lifecycle plan,
verifies it, and composes the installed harness adapter. Repeated starts use a
locally re-proven last-good release during the check interval; an outage is explicit
and can continue only from that verified last-good state. No agent needs to `git
pull` its working clone. macOS keeps the status/context surfaces but omits the
blocking auto-update hook until its candidate sandbox is qualified; an explicit
start leaves recorded last-good untouched and refuses with
`MACOS_SANDBOX_PENDING`. See
[`docs/RELEASE-UPDATE.md`](docs/RELEASE-UPDATE.md).

Keep files portable (BSD+GNU), and keep machine-specific facts in machine-local
notes rather than canonical files. Never commit or synchronize secrets:
credentials remain in their native stores (including 1Password delivery) and AFK
records only non-secret state and references.
