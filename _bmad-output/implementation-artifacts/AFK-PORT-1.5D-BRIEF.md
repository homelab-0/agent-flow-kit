# Worker brief — AFK-PORT-1.5D (fresh claude session, Orca-supervised)

You are a dispatched WORKER under Orca supervision, in your own top-level
Orca worktree of `agent-flow-kit` branched from `master` at `32e94cc`.

## Persona (fail-closed)

Load and follow the BMAD DEV persona from
`.agents/skills/bmad-agent-dev/SKILL.md` plus its resolved customization.
Compute the proof first and state it in your first message; mismatch means stop:

```bash
{ sha256sum .agents/skills/bmad-agent-dev/SKILL.md; sha256sum .agents/skills/bmad-agent-dev/customize.toml; } | sha256sum
```

Expected outer hash:
`4cdff719c4f3042532520611f7106d80393173004355e6a83771b366c3efc7f9`.
Expected intermediates: `0bc44690f0dc7fdeaabd763efd3ead4b2e8bb8b3a8d5437140605a544b39bb1f`
and `ab52d8840427e10d5956b592c34e63edc77ebdafd7b54ce60da11cf67ed72ced`.

## Task

The lane story is the scope. Read it fully first:
`_bmad-output/implementation-artifacts/AFK-PORT-1.5D.md` (design ruling,
S1–S7, AC-1–AC-7, and hard stops). Then read only the directly relevant
authorities it names: the frozen Story 1.5, the PRD addendum Capability 5 and
NFR-13–NFR-15, the merged lane A–C records, the existing context-budget policy,
status/monitor/command implementation, PM-facing model-router skill, lifecycle
contract, and named tests.

Implement lane D completely. The kit accepts a PROVIDED final-context
observation; it does not measure or launch the PM. Preserve worker dispatch and
watch behavior. Thresholds come only from the policy file. Keep
`envelope_actions` opaque for Story 1.6 and leave Story 1.8's adapter writer out
of scope.

You have a shell and Edit. Run every frontmatter gate yourself and record exact
tallies and wall times. `tests/run-tests.sh` takes roughly 43 minutes on this
host; run it last and once. The only tolerated red is the reproduced baseline
aggregate `lifecycle concurrency gate`, with exactly 204 passed / 3 failed in
the publication-window scenario. Anything else is failure.

## Hard rules

- Stay inside the route-declared file surface. If a necessary path is missing,
  stop and ask rather than silently expand scope.
- Reviewable diff must be at most 800 lines including tests and prose, and at
  most 25 files. Cut scope and report if the approved lane cannot fit.
- Do not edit `dispatch.sh`, `make-stamp.sh`, the validator, catalog, routing
  requests, frozen launch text, the Story 1.8 hook, or Story 1.6 vocabulary.
- PM continuation is always human-started and loud. No PM path may call
  `orca terminal create`, `worker-start`, or any equivalent launcher.
- PM artifact writes must be validated, atomic, and subject to the existing
  redaction rules. Never echo or retain secret-looking values.
- Thin consumption only: pointers and bounded summaries, never transcripts or
  evidence bodies in coordinator state.
- Commit on this worktree's branch only. Use plain engineering-language commit
  messages with no AI attribution, `Co-Authored-By`, session links, tool banners,
  or BMAD vocabulary. Never push, open a PR, or touch `master`.
- Do not commit this brief, route request/response files, stamp, attempt files,
  or generated gate logs. The lane story with its Dev Agent Record is part of
  the implementation commit.
- For a genuine owner decision, ask through the injected Orca lifecycle and
  stop. Do not invent authority.

## Dev Agent Record

In the lane story, record method choices, schema/precedence decisions, files
touched, the final reviewable diff size against the 800-line/25-file limits,
per-gate tallies and wall times, the exact tolerated baseline if seen,
deferrals with diagnosis, and the commit SHA.

## Completion

Send `worker_done` exactly once through the injected Orca mechanism, with the
explicit outcome and files modified. Report `succeeded` only if AC-1–AC-7 are
addressed, all short gates are green, and the full gate is green except for the
single exact tolerated concurrency aggregate. End your turn after the verified
send.

## Routing

- Stamp: `_bmad-output/implementation-artifacts/AFK-PORT-1.5D.md.stamp.json`
  (`sha256:dcaf4d8c5ea1415746d93601824a6a523d96f9d6eaf9d681675c603c09364b80`)
- Router decision: `claude / claude/strong / medium` — overridden under Josh's
  standing implementation-prefers-claude ruling; natural recommendation
  `claude / local-code-standard / medium` is retained beside the stamp.
- Override: Josh's standing ruling; Story 1.7 measured the natural profile at
  6/9 on trivial canaries with a path-resolution failure class, and lane D is
  cross-cutting lifecycle work under an 800-line budget. The refreshed route
  includes `bin/agent-flow-kit` and `lib/afk-common.sh` in the declared surface.
- Placement: not required; vendor-hosted subscription profile.
- Persona: `dev`; the persona proof above must match.
- Gates: `bash tests/run-tests.sh`; `bash tests/lifecycle-readiness-tests.sh`;
  `bash tests/lifecycle-dispatch-tests.sh`; `bash tests/lifecycle-tests.sh`;
  `git diff --check`.
- Post-dev validation: coordinator checks AC coverage, declared-surface scope,
  diff budget, exact gate evidence, baseline-only red, commit hygiene, and
  retained artifacts before sending the change to an independent reviewer.
