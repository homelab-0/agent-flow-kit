# Worker brief — AFK-SPIKE-LOCAL-CLAUDE-EXIT

You are a supervised WORKER in the existing clean Orca worktree
`afk-port-1.5d`, now on branch
`jlengelbrecht/afk-spike-local-claude-exit` from `origin/master` at
`f47c52f15ab76f45f9a1fe0a19f858e8305bf7a0`.

Route/stamp: `{claude, claude/strong, effort medium}` under Josh's standing
implementation-prefers-claude ruling. The natural
`{claude, local-code-standard}` response is retained beside the override; it
is the defective system under test, not the worker route. Stamp:
`_bmad-output/implementation-artifacts/AFK-SPIKE-LOCAL-CLAUDE-EXIT.md.stamp.json`.

## Persona

Activate the BMAD DEV persona from `.agents/skills/bmad-agent-dev/SKILL.md`
and its customization. Before any task work, compute:

```bash
{ sha256sum .agents/skills/bmad-agent-dev/SKILL.md; sha256sum .agents/skills/bmad-agent-dev/customize.toml; } | sha256sum
```

The expected outer hash is
`4cdff719c4f3042532520611f7106d80393173004355e6a83771b366c3efc7f9`.
Mismatch means stop and report it.

## Task

Read and execute exactly:
`_bmad-output/implementation-artifacts/AFK-SPIKE-LOCAL-CLAUDE-EXIT.md`.
This is evidence-only live diagnosis. Predeclare the controlled matrix, run
at most four 10-minute cells, stop early on a demonstrated controlled pair,
and produce the indexed evidence bundle plus `FIX-SCOPE.md`.

The gateway credential reference is
`op://develop/agw-claude-code/password`. Resolve it only for the child process
after disabling xtrace. The coordinator environment has an authenticated
1Password CLI. Never print the resolved value, never persist it, never put it
in argv, and never set or export `ANTHROPIC_API_KEY`. Do not use a metered
provider. If safe resolution or a local placement cannot be established,
record that blocker and stop.

The frozen command in `files/model-router/scripts/dispatch.sh` and the
external field report are inputs, not code to edit. Preserve fail-closed
semantics: file appearance is observation only, never completion.

## Hard rules

- No production, test, policy, catalog, registry, contract, installed-kit, or
  ai-control-plane edits.
- No full 5400-second kit dispatch. Direct canaries only, with an outer
  10-minute timeout each.
- No environment dumps, authorization headers, raw credentials, or unredacted
  streams in retained artifacts or messages.
- Do not commit this brief, the stamp, route request, or route responses.
- Make one commit containing only the story's evidence bundle and the story's
  completed Dev Agent Record. Plain engineering-language subject; no trailers,
  AI attribution, session links, or tool banners. Do not push or open a PR.
- Run `git diff --check` and report its exact result.
- Anything outside scope goes in `FIX-SCOPE.md`; do not implement it.

## Completion

Send `worker_done` through the injected orchestration mechanism with
`--dispatch-capability` and `--json`. Verify success and include the returned
message id, commit id, live-cell verdict, and gate result. On send failure,
capture stderr and retry once with the same capability. End only after a
verified send or a specific blocker report.
