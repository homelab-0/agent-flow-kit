# Worker brief — AFK-PORT-1.4-LV (fresh claude session, Orca-supervised)

You are a dispatched WORKER under Orca supervision, in your own Orca worktree
of `agent-flow-kit` branched from `master` @ `8a56eb5`. Route/stamp (natural
router decision, no override): `{claude, claude/strong, effort high}`,
`_bmad-output/implementation-artifacts/AFK-PORT-1.4-LV.md.stamp.json`,
digest `sha256:ce0840d2fa88f08ffa4610f5a9f92eb7771eb9aa295226ecc1ef7b8709570a52`,
validated fail-closed by the coordinator immediately before your launch.

## Persona (fail-closed)

BMAD DEV persona from `.agents/skills/bmad-agent-dev/SKILL.md` +
`customize.toml`. Compute the proof FIRST and state it in your first message
(expect the OUTER hash `07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee`;
the intermediates are `b980cf2c…` for SKILL.md alone and `f3f107f1…` for
customize.toml alone; a mismatch = STOP and report):

```
{ sha256sum .agents/skills/bmad-agent-dev/SKILL.md; sha256sum .agents/skills/bmad-agent-dev/customize.toml; } | sha256sum
```

## Task

**The story file is the scope. Read it fully first:**
`_bmad-output/implementation-artifacts/AFK-PORT-1.4-LV.md` (in this worktree).
It names the authority documents, the validated contract, the launch-class
discriminator, the credential-conveyance constraints, the exact file surface,
eight acceptance criteria and the out-of-scope hard stops. This brief adds
only the operating rules below; it does not restate the spec.

Read order before writing any code: the story; catalog 1.6.0
`profiles.local-code-standard.notes` and `profiles."minimax/strong".notes`
(`~/.local/share/agent-flow-kit/catalogs/agent-router-1.6.0.yaml`);
`files/model-router/scripts/dispatch.sh` end to end; `tests/run-tests.sh`
sections 2 and 3/3b; `lib/afk-readiness.sh` around `afk_launch_contract_reason`
and its call site; the matching block of `tests/lifecycle-readiness-tests.sh`;
the launch-contract paragraph of `docs/LIFECYCLE-CONTRACT.md`.

You HAVE a shell. Use it: run each gate yourself and paste the tallies into
the Dev Agent Record. Budget: `tests/run-tests.sh` takes roughly 36 minutes
on this host; run it last, once, after the other three suites are green.
Invoke suites as `bash tests/<file>` (never rely on exec bits).

## Hard rules

- Stay inside the story's declared file surface. Anything else you believe
  needs changing goes into the record under "Deferred, deliberately, and
  disclosed" with a diagnosis — never fixed silently.
- The native `{claude, claude/strong}` command text must be byte-identical
  before and after; the existing test that pins it is your oracle.
- No secret VALUE in any file, log, command text, title, test output or
  message. Use a sentinel in tests. The fleet's real credential is not
  available in this session and you do not need it: everything you build is
  proven against stubs. Do not attempt a live launch against the gateway.
- Do not read, cite or anticipate Stories 1.5–1.8 material anywhere under
  `_bmad-output/` (embargoed). The MiniMax pair stays refused.
- Git: work on this worktree's branch. You may make commits on it with plain
  engineering-language messages (no AI attribution, no tool banners, no
  internal process vocabulary). NEVER push, never open a PR, never touch
  `master`, never run `git add .` — add named files only. Do not commit
  the `AFK-PORT-1.4-LV-BRIEF.md`, the stamp, or any `.attempt1.*` artifact;
  they are coordinator-retained and travel via the record PR later. The
  story file `AFK-PORT-1.4-LV.md` (with your record) IS part of your commit.
- Any decision that genuinely needs the owner: write it in the record, send
  it in your worker_done body as `NEEDS-HUMAN: <question>`, and stop. The
  no-shell arrangement does not apply to you and is not such a decision.

## Record (in the story file's Dev Agent Record)

State: the conveyance mechanism you chose and why (or why you rejected the
recommended shape); files touched; the final diff size (`git diff --stat
master...HEAD` added+changed lines and file count, against the ≤ 800 / ≤ 25
budget); per-gate tallies and wall time; anything deferred with diagnosis;
the commit SHA(s) on your branch.

## Completion — VERIFIED send (hard requirement)

Send worker_done via the injected mechanism with your --dispatch-capability
token, APPENDING --json. Then verify: capture the send's exit code
(`echo $?`) and the JSON's ok/message-id. If output is empty or ok is not
true, capture stderr (rerun with 2>&1), report the failure in a second
attempt's body, and only end your turn after a send whose JSON result you
have verified and whose message id you state in your final line. Keep your
--dispatch-capability token in any resend.
Outcome `succeeded` iff all five gates pass in this worktree and every AC is
addressed in the record; otherwise `failed` with the exact failing assertion
names, verbatim.
