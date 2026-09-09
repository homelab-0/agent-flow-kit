# Worker brief — AFK-PORT-1.5D-FIX-1 (fresh cloud session, Orca-supervised)

You are a dispatched worker under Orca supervision in the existing lane-D
worktree. The independent review has completed and its reviewer terminal has
been released. Do not remove or replace the worktree.

## Persona (fail closed)

Load and follow `.agents/skills/bmad-agent-dev/SKILL.md` plus its resolved
customization. Compute this proof before editing and state it in your first
message:

```bash
{ sha256sum .agents/skills/bmad-agent-dev/SKILL.md; sha256sum .agents/skills/bmad-agent-dev/customize.toml; } | sha256sum
```

Expected outer hash:
`4cdff719c4f3042532520611f7106d80393173004355e6a83771b366c3efc7f9`.
Expected intermediates: `0bc44690f0dc7fdeaabd763efd3ead4b2e8bb8b3a8d5437140605a544b39bb1f`
and `ab52d8840427e10d5956b592c34e63edc77ebdafd7b54ce60da11cf67ed72ced`.
Mismatch means stop and escalate.

## Task

Read `_bmad-output/implementation-artifacts/AFK-PORT-1.5D-FIX-1.md` fully,
then its payload review report. Close exactly B1 and B2 with the minimal code
changes and regression rows. Do not address review residuals R1–R12.

Preserve all lane-D acceptance behavior. The final product diff from base
`32e94cc5e0b1c6991aabe1942c4f701b7e9c526e` must remain within 800
added+changed lines across the same eight product files. The pre-fix diff is
exactly 800, so trade/compress test lines rather than requesting an exception.

Run the four gates from story frontmatter. Do not run the aggregate suite; its
pre-fix evidence is retained and the focused suites directly cover these
guards. Record exact tallies and wall times in the fix story's Dev Agent Record.

## Git and scope

- Amend the existing lane-D implementation commit so the branch finishes with
  one commit above base. Preserve its substantive engineering message but strip
  all AI attribution, `Co-Authored-By`, `Claude-Session`, session links, and tool
  banners. Do not push or open a PR.
- Product edits are restricted to `lib/afk-commands.sh`,
  `tests/lifecycle-readiness-tests.sh`, and `tests/lifecycle-tests.sh` unless a
  binding blocker cannot be fixed there; escalate before widening.
- The fix story may be updated only in its Dev Agent Record. Do not commit the
  fix/review briefs, evidence directory, route request/response, stamps, prompt,
  result, or generated gate logs.
- Use synthetic credential shapes only; never inspect or print a real secret.
- Do not touch dispatch, cleanup, routing, worker-watch behavior, contract text,
  PM skill text, or the twelve residuals.

## Completion

Send exactly one Orca `worker_done` after the amended commit exists and all
declared gates pass. Include the new SHA, files modified, final product line/file
count, gate tallies, and confirmation that the commit body is attribution-free.
If blocked, send one escalation and stop. End after the verified delivery.

## Routing

- Fresh natural route: `claude/local-code-standard`, medium, retained beside
  the stamp.
- Accepted override: `claude/strong`, medium, under Josh's standing
  implementation-prefers-claude ruling and the Story 1.7 6/9 finding.
- Placement: false; subscription pool `anthropic-max`; no metered spend.
- Stamp:
  `_bmad-output/implementation-artifacts/AFK-PORT-1.5D-FIX-1.md.stamp.override-derived.json`
  (`sha256:f67d5b9417ca4b93e2dff0eb8fd6660452b80673ab8e39dfa3f3760e4daec2a1`).
- Post-fix: the coordinator verifies boundaries and sends the exact amended
  commit to a fresh independent reviewer at least as strong as this worker.
