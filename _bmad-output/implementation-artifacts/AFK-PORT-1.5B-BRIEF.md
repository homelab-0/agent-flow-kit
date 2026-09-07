# Worker brief — AFK-PORT-1.5B (fresh claude session, Orca-supervised)

You are a dispatched WORKER under Orca supervision, in your own Orca worktree
of `agent-flow-kit` branched from `master` @ `ec83010`. Route/stamp:
`{claude, claude/strong, effort medium}` (recorded override of the natural
route under the owner's standing ruling; the override reason in the stamp is
itself a story-sizing finding you may cite),
`_bmad-output/implementation-artifacts/AFK-PORT-1.5B.md.stamp.json`,
digest `sha256:f9578304f8667adc0475f35af7bc070ae00ccd90273c76dfe6748fe84bc315cb`,
validated fail-closed by the coordinator immediately before your launch.

## Persona (fail-closed)

BMAD DEV persona from `.agents/skills/bmad-agent-dev/SKILL.md` + `customize.toml`.
Compute the proof FIRST and state it in your first message (expect the OUTER
hash `07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee`;
intermediates `b980cf2c…` and `f3f107f1…`; mismatch = STOP):

```
{ sha256sum .agents/skills/bmad-agent-dev/SKILL.md; sha256sum .agents/skills/bmad-agent-dev/customize.toml; } | sha256sum
```

## Task

**The lane story is the scope. Read it fully first:**
`_bmad-output/implementation-artifacts/AFK-PORT-1.5B.md` (S1–S7, AC-1–9,
hard stops). Then its authorities: the frozen `AFK-PORT-1.5.md` (do not edit it), the PRD addendum Capability 5 and NFR-13–15, lane A's merged work (`AFK-PORT-1.5A.md` record, `files/model-router/context-budget-policy.yaml`, the `budget` member in `dispatch.sh`), and the existing adapter end to end. Both launch command texts must stay byte-identical — the suite's byte-identity oracle is yours. The lane's DESIGN RULING section is binding: end-of-run usage only, codex NOT_EVALUATED, phase-boundary discipline in the prompt.

You have a shell. Run all four gates yourself, paste the tallies.
`tests/run-tests.sh` takes ~42 minutes on this host and exits 1 on ONE
recorded pre-existing aggregate (`lifecycle concurrency gate`, 204/3 in the
publication-window scenario — reproduced on pristine master, evidence
`evidence/AFK-PORT-1.4-LV/coordinator-baseline-concurrency-master-8a56eb5.log`).
Report it verbatim; it is the only tolerated red. Run it last, once.

## Hard rules

- Stay inside the story's declared file surface (S6 names the doc surfaces; `lib/afk-monitor.sh` only for the `context_budget` watch member; `lib/afk-commands.sh` only for the `schema` enum). Disclose anything else
  under "Deferred, deliberately, and disclosed" with a diagnosis.
- Thresholds live ONLY in the policy file. No threshold constant in code. Reviewable diff ≤ 800 lines INCLUDING tests and prose — cut scope and disclose rather than absorb.
- No `/v1/route` request change, no `make-stamp.sh` change, no validator or
  catalog change, no change to either frozen launch command text.
- No secret VALUES anywhere; the credential path of the gateway class is not
  yours to touch.
- Do not read, cite or anticipate Story 1.6 or 1.8 material beyond the
  reason-code discipline the lane names; lanes B/C/D are seams, not work.
- Git: commit on this worktree's branch only, named files, plain
  engineering-language messages, NO trailers of any kind (no Co-Authored-By,
  no session links, no tool banners; if your environment appends them, say so
  in the record so the coordinator strips them). Never push, never PR, never
  touch `master`. Do not commit the brief, stamp, route artifacts or
  `.attempt*` files; the lane story with your record IS part of the commit.
- A decision that genuinely needs the owner: record it, send
  `NEEDS-HUMAN: <question>` in your worker_done body, stop.

## Record (in the lane story's Dev Agent Record)

Method choices (estimate inputs, refusal ordering, record-append idempotence,
how the window is resolved), files touched, final reviewable diff size
(`git diff --stat master...HEAD`, excluding the story file) against ≤ 800 /
≤ 25, per-gate tallies and wall time, deferrals with diagnosis, commit SHA.

## Completion — VERIFIED send (hard requirement)

Send worker_done via the injected mechanism with your --dispatch-capability
token, APPENDING --json. Verify exit code and the JSON's ok/message-id; on
failure capture stderr, retry once with the same token; end your turn only
after a verified send whose message id you state in your final line.
Outcome `succeeded` iff AC-1–9 are addressed, the other three gates are
green, and the ONLY `run-tests.sh` failure is the recorded concurrency
aggregate with exactly its three known sub-assertions.
