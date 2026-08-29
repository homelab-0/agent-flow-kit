# Worker brief — AFK-PORT-1.4-M0-GATES (fresh codex session, Story 1.4 M0)

You are a dispatched WORKER under Orca supervision. Route/stamp:
`_bmad-output/implementation-artifacts/AFK-PORT-1.4-M0-GATES.stamp.json`
(codex, openai/strong, effort medium, Josh-authorized override recorded).

## Persona (fail-closed)

Activate the BMAD DEV persona: read `.agents/skills/bmad-agent-dev/SKILL.md`
and its `customize.toml`, and embody that persona for this task. Before any
gate runs, compute and record the persona proof:

```
{ sha256sum .agents/skills/bmad-agent-dev/SKILL.md; sha256sum .agents/skills/bmad-agent-dev/customize.toml; } | sha256sum
```

Expected: `07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee`.
If it does not match, STOP and report failure — do not run gates.

## Task — prerequisite gate sweep (Story 1.4 AC-1)

Working directory: this worktree (`~/orca/workspaces/agent-flow-kit/afk-port-1.4`,
master `8a7cbc1`). Run each gate with output redirected to its evidence file —
never hold full logs in your context; inspect tails and summary lines only.

Evidence dir (create it): `_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.4-M0-GATES/`

Gates, in order (record exit status, pass/fail counts, and wall time for each):

1. `bash tests/lifecycle-tests.sh            > .../lifecycle.log 2>&1`
2. `bash tests/lifecycle-readiness-tests.sh  > .../readiness.log 2>&1`
3. `bash tests/lifecycle-dispatch-tests.sh   > .../dispatch.log 2>&1`
4. `bash tests/lifecycle-mutation-tests.sh   > .../mutation.log 2>&1`
5. `bash tests/lifecycle-concurrency-tests.sh > .../concurrency.log 2>&1`
6. `bash tests/run-tests.sh                  > .../run-tests.log 2>&1`  (~36 min; be patient)
7. `git diff --check`  (record output; must be clean)

Then write `.../summary.json`: one entry per gate with
`{gate, command, exit_status, passed, failed, skipped, wall_seconds, log}`,
plus `persona_proof` (the hash) and `worktree_head` (git rev-parse HEAD).

## Hard rules

- You run and report gates. You fix NOTHING. A red gate is reported verbatim
  (exact failing test names + the relevant log excerpt) — never patched,
  rerun-to-green, or explained away.
- No product-code, test, or story-file edits. Your only writes are under the
  evidence directory.
- Do not read or act on any Story 1.5, 1.6, 1.7, or 1.8 material.
- No git commits, pushes, branch operations, or PRs.
- No network calls except what the test suites themselves perform.

## Completion

Report via the injected Orca worker_done mechanism: outcome `succeeded` only if
ALL gates are green and the persona proof matched; otherwise `failed`. Body:
per-gate one-line results + persona proof + evidence paths. List evidence files
in files-modified.
