---
linear:
stamp: AFK-PORT-1.4-LV-REVIEW.md.stamp.json
persona: dev
gates:
  - "bash tests/lifecycle-readiness-tests.sh"
  - "git diff --check"
max_cycles: 1
---

# AFK-PORT-1.4-LV-REVIEW — adversarial + senior review of the gateway launch variant (fresh session)

You are a fresh session. You did not write this code. You review the branch
`jlengelbrecht/afk-port-1.4-lv` (commits `533880d` implementation, `1a388bf`
record) against `master` @ `8a56eb5`, in the worktree you are launched in.
The spec is `_bmad-output/implementation-artifacts/AFK-PORT-1.4-LV.md`
(read the story body AND the worker's Dev Agent Record, which discloses seven
deferred/residual items). Authority for the launch path: catalog 1.6.0
`profiles.local-code-standard.notes`
(`~/.local/share/agent-flow-kit/catalogs/agent-router-1.6.0.yaml`).

Two lenses, both required: **adversarial** (try to break it) and **senior**
(is it right, minimal, and true to the frozen contracts).

## What to attack, in priority order

1. **Credential leakage — every channel.** The token value is resolved at
   terminal runtime via `$(. <opEnvFile> && op read <ref>)`. Prove or disprove
   that it can reach: generated command text, the terminal title, dispatch
   stdout/stderr, the prompt file, `.claude-result.json`, `.result.json`,
   `.blocked`, the story file, Orca's terminal buffer/transcript on the
   `CLAUDE_EXIT` path AND on every refusal path (empty read, `op` failure,
   unreadable env file), `set -x`/`PS4` inheritance in the terminal shell, the
   terminal shell's environment after the command (the `unset` is after the
   exit line — what about `OP_SERVICE_ACCOUNT_TOKEN` and the subshell claim?),
   `/proc/<pid>/cmdline` of `env` before exec (disclosed residual 1 — assess
   exploitability honestly: same-user only?). Use a sentinel, never a real
   credential; the real one is not available here and must not be sought.
2. **Fail-closed bypasses.** For each of the preflights (endpoint unset,
   reference unset, env file unreadable, `op` off the approved PATH, evidence
   without `x-placement`, catalog without `min_context`, empty read at
   runtime): can any be skipped, ordered after terminal creation, or turned
   into a native launch by accident? Is the empty-read refusal (exit without a
   `CLAUDE_EXIT` line) really reported as a launch failure and never as
   `status: done`?
3. **Discriminator.** Can any stamp reach the gateway class that should not
   (codex; a vendor-hosted profile with `placement_required: true`; a local
   profile on a vendor pool; `cost_class` mismatches; a catalog whose
   `hosting` is missing)? Both new parameters "default to empty and fail
   closed" — verify at every call site. Does the readiness mirror (residual 5:
   it cannot see `hosting`) create a decision that dispatch then contradicts,
   and does that matter under the frozen contract's "route readiness is the
   intersection of every authority"?
4. **Native byte-identity.** The `{claude, claude/strong}` command text and
   the codex command text must be unchanged. Diff the builders' outputs
   yourself against `master`'s builders (source both and compare), not only
   via the suite's pinned string.
5. **Shell-safety of the new literals.** `gateway_endpoint`,
   `gateway_token_ref`, `op_env_file`, the header value from `/v1/place`
   evidence, `min_context`: all must pass through `shq` (or be validated
   against a strict pattern) before entering command text. Craft hostile values
   (quotes, `$(...)`, newlines, a header value with a space or `;`) and show
   what the generated command does.
6. **Test vacuity.** The sentinel absence assertions, the allowlist-as-set
   parse, the byte-identity comparison — can each pass while the property is
   false? Mutation-test at least the sentinel proof and the allowlist parse
   (break the code deliberately in a scratch copy and confirm the assertion
   fails).
7. **Contract truth.** `docs/LIFECYCLE-CONTRACT.md`, the dispatch.sh header,
   `subscriptions.yaml` comments: every sentence true of the code? Anything
   claiming validation this story did not perform (no live gateway launch
   happened)?
8. **Scope and hygiene.** Diff inside the story's declared surface; commit
   messages in plain engineering language with no AI attribution or internal
   process vocabulary; no stray files; `git diff --check` clean.

## Rules

- Blocker bar (frozen convergence policy): a finding BLOCKS only if it
  (a) violates a frozen requirement or a story AC, (b) you reproduced it, and
  (c) it is reachable by natural occurrence or one ordinary operator action.
  Everything else is a residual with a severity and a recommendation.
- Do NOT modify product code, tests, docs or the story record. Write ONLY
  under `_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.4-LV-REVIEW/`:
  your report `REVIEW.md`, and any attack/repro scripts you ran (each with a
  control that shows the script itself works). Scratch copies for mutation
  tests go under `/tmp`, never in the worktree.
- You may run `bash tests/lifecycle-readiness-tests.sh`,
  `bash tests/lifecycle-dispatch-tests.sh`, `bash tests/lifecycle-tests.sh`
  and `git diff --check`. Do NOT run `tests/run-tests.sh` (≈42 min; the
  coordinator is running it independently in this worktree — do not disturb
  it). Do not touch `master`, do not push, no PR, no commits.
- No secret values anywhere. No Story 1.5–1.8 material.

## Report shape (`REVIEW.md`)

1. Verdict line first: `AFK-PORT-1.4-LV REVIEW: CLEAN` or
   `AFK-PORT-1.4-LV REVIEW: NOT CLEAN — <n> blocker(s)`.
2. Blockers: id, the AC/requirement violated, exact reproduction (script
   path + command + observed output), reachability argument, minimal fix
   recommendation.
3. Residuals: id, severity, one-paragraph assessment, recommendation
   (fix-now / backlog / accept), including your assessment of each of the
   seven disclosed items in the worker's record.
4. AC-by-AC coverage table (AC-1…AC-8): covered / partially / not, with the
   evidence you checked.
5. Gate tallies you ran, with wall times.

## Dev Agent Record

(reviewer fills in: what you ran, what you found, verified worker_done send)
