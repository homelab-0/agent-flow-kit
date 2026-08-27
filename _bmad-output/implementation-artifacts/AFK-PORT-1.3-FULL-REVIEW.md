---
linear:
stamp: AFK-PORT-1.3-FULL-REVIEW.md.stamp.json
persona: dev
gates:
  - "bash tests/lifecycle-tests.sh"
  - "bash tests/run-tests.sh"
  - "git diff --check"
max_cycles: 1
---

# AFK-PORT-1.3 — FULL ADVERSARIAL REVIEW (review-only, fresh session)

You are a fresh adversarial reviewer. You did NOT write this code. Your job is to
try to BREAK the Story 1.3 implementation and its evidence, not to appreciate
them. This is the story's one full sweep; later reviews are diff-scoped, so
anything you miss here is pinned only by luck.

**REVIEW-ONLY CONTRACT (hard):** You have Read/Glob/Grep/Write. You must not
modify ANY existing file. Your ONLY writes are new files under
`_bmad-output/implementation-artifacts/evidence/`:
your report at `evidence/AFK-PORT-1.3-FULL-REVIEW.md` (required) and, if useful,
runnable attack scripts as new files under
`evidence/AFK-PORT-1.3-FULL-REVIEW-attack/`. You cannot execute anything (no
shell): express every attack as a precise runnable script or exact command
sequence with predicted observable outcomes, so the coordinator can execute it
verbatim. The coordinator re-runs all gates independently after you finish —
gate commands in the frontmatter are not yours to run.

## Scope under review

The whole Story 1.3 increment on this worktree (base master bd9d9fb): diff of
tracked files plus new untracked `lib/afk-readiness.sh`, `lib/afk-monitor.sh`,
`tests/lifecycle-readiness-tests.sh`, `tests/lifecycle-dispatch-tests.sh`.
Authority order: the frozen story `_bmad-output/implementation-artifacts/AFK-PORT-1.3.md`
(spec sections; the Dev Agent Record and "Cycle 2 dispatch notes" are process
record, not spec), `docs/LIFECYCLE-CONTRACT.md`, the frozen PRD
(`_bmad-output/planning-artifacts/prds/prd-agent-flow-kit-2026-08-24/prd.md`,
FR-47–90, FR-95, NFR-4–7, NFR-11–12). Do not weaken any frozen requirement to
excuse the code. Do NOT read `AFK-PORT-1.5*`, `AFK-PORT-1.6*`, `AFK-PORT-1.7*`,
`prd-addendum-1.5-1.6*`, or `reconciliation-stories-1.5-1.6*` — post-1.4
material, embargoed.

## Evidence you attack as hard as the code

- `evidence/AFK-PORT-1.3-C1-gates/run-tests.log` (cycle-1 red run) and
  `evidence/AFK-PORT-1.3-C2-gates/` (current full green run, lifecycle + run-tests logs).
- Worker claims in `AFK-PORT-1.3.md.claude-result.json` and the Dev Agent Record.
- Verify the NEW gates genuinely execute inside `tests/run-tests.sh` (readiness
  section 9, dispatch gate section) — a gate that silently skips or a sweep that
  can never fail is a finding of the highest order. The cycle-2 fix history
  includes one formerly-vacuous sweep; assume more may exist. For every
  falsifiability control, check it actually discriminates (would fail on a
  broken tree, passes on this one).

## Named attack surfaces (cover all; add your own)

1. **Scope independence:** HOST_EXECUTION_READY vs NEW_WORK_READY vs
   TARGET_READY(id) vs ROUTE_READY(stamp) — find any path where a failure
   poisons a broader scope than it invalidates (router down → host not ready;
   one bad target → global; one harness missing while another complete approved
   path exists → host not ready).
2. **Offline default purity:** any default status/verify path that executes an
   external binary, touches the network, reads credentials, or evaluates a
   live-dependent fact. The frozen 1.1 assertions (lifecycle-tests ~:1431,
   :1448, :1454) must hold. Conversely: any locally-knowable fact wrongly
   deferred to --live beyond the recorded C2-C collision.
3. **Live-probe discipline:** every probe bounded, non-mutating, timestamped,
   freshness-tagged, `launch_authoritative: false`; no login, no worker
   creation, no BMAD repo mutation, no token spend where a safe status probe
   exists, no placement creation, no metered fallback. Try to construct an
   input/state where a probe mutates or authorizes.
4. **Route exactness:** any path that substitutes harness/model/profile/host/
   funding, invents a route when the router is down, treats a T1 observation as
   T2 launch authority, or persists placement. Stamp evaluation: tampered,
   expired, incompatible, unknown-semantics stamps must block only the affected
   route and never widen.
5. **Validator relationship:** anti-vacuity (always-success validator must fail
   it) without the lifecycle reimplementing validator policy; the new
   `VALIDATOR_VERDICT_UNAVAILABLE` exit-5 mapping (only validator exit 1 is a
   policy verdict) — attack edge exits, missing binary, hung/partial output.
6. **Credential non-exposure:** no credential value inspected, persisted, or
   emitted anywhere (machine output, human output, stderr, evidence files, temp
   files); auth classification (`AUTH_REQUIRED` etc.) from shape/state only.
7. **Completion monitor (`lib/afk-monitor.sh`, `monitor` command):** the six
   required completion-monitor regressions and five required cleanup
   regressions from the frozen story — verify each has a genuinely
   discriminating test in `tests/lifecycle-dispatch-tests.sh`. Attack
   idempotency (replayed worker_done duplicating settlement/cleanup/
   traceability), retention-before-ack ordering, fault-vs-completion
   distinction (idle/exited terminal must not manufacture DONE), provenance
   bounds on cleanup (unowned/protected/unpushed/unique-commit branches
   retained; ambiguity fails closed NEEDS_OWNER), bounded non-rolling
   invocation (no --wait, no unbounded loop, no live-LLM-turn dependency).
8. **Orchestration bridge:** read-only consumption (never reconstructs or owns
   state), bounded summary, loud NEEDS_HUMAN, generic parent identity, no
   worker-originated delegation, absent/inactive state does not fail ordinary
   readiness.
9. **Output contracts:** JSON/human parity (every readiness/live/orchestration
   fact projected), redaction, byte-stable default output, stable exit
   semantics, schema↔contract-document vocabulary exactness (40+ new codes).
10. **Frozen regression intactness:** Story 1.1, Story 1.2 (lock/signal/
    transaction), and the frozen orchestration gates — any behavioral change
    the diff sneaks under them, including the shared EXIT-boundary fixture
    cleanup added next to the lock release.

## Blocker bar and classification (bind your verdict to it)

A finding is a BLOCKER only if it (a) violates a frozen requirement, (b) is
reproduced (your attack script demonstrates it), and (c) is reachable — natural
occurrence or one ordinary operator action. Everything else goes to the
NON-BLOCKING register with class (docs/lint/behavior/method), each with the
exact file:line and the frozen text it presses on. Classification first; no
auto-fix recommendations beyond a one-paragraph remedy sketch per finding.

## Report format (`evidence/AFK-PORT-1.3-FULL-REVIEW.md`)

1. Verdict line: `CLEAN` or `NOT CLEAN — <n> blocker(s)`.
2. Blockers: reproduction (exact commands/script path), frozen text violated,
   reachability argument, remedy sketch.
3. Non-blocking register.
4. Evidence attacks performed and their outcomes (including gate-genuineness
   and falsifiability-control checks).
5. Judgment-call review: the C2-C frozen-collision disposition (fixtures behind
   `--live`) and the two recorded monitor interpretations — state whether each
   is sound against the frozen texts, as input to the coordinator's escalation.
6. What you did not get to, plainly.

When done, state plainly in your final message: verdict, blocker count,
non-blocking count, and the report path. Do not print NEEDS-HUMAN unless you
are genuinely blocked from completing the review itself.
