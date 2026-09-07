---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-PORT-1.6.md.stamp.json
persona: dev
gates:
  - "bash tests/lifecycle-tests.sh"
  - "bash tests/run-tests.sh"
  - "git diff --check"
max_cycles: 3
---

### Story 1.6: Worker Feedback and PM Course-Correction Envelope

As an agent-flow-kit fleet operator,
I want workers to escalate structured findings in thin results and the PM to course-correct only inside an explicit recorded authority envelope with hard budgets,
So that discovered ambiguity, hidden scope, and conflicts pivot the plan instead of stalling or overreaching, while human design authority stays intact.

**Acceptance Criteria:**

**Given** a worker discovers a condition it cannot resolve inside its assigned scope
**When** it returns its thin result
**Then** the result carries a structured escalation from a documented stable-code registry — starting set `AC_AMBIGUOUS`, `SCOPE_LARGER`, `DEPENDENCY_FOUND`, `SPEC_CONFLICTS_CODE`, `NEEDS_DECISION` — with bounded evidence references
**And** pass/fail alone is no longer the only expressible outcome.

**Given** the escalation registry
**When** it is documented and versioned
**Then** it also carries the Story 1.5 context signals so thin results have one structured escalation channel
**And** codes are additive within a schema major version and never silently change meaning, matching the frozen FR-72–77 machine-contract discipline.

**Given** an escalation whose resolution is inside the PM envelope
**When** the PM acts alone
**Then** the action is one of: clarifying an acceptance criterion without changing its intent; splitting a story while preserving its total approved scope; reordering or deferring stories within the epic; re-routing, retrying, or adding a helper worker within declared budgets; or spending within declared budgets
**And** the escalation resolves without a human turn, with any helper worker PM-dispatched through the normal route/stamp path — never worker-originated subdelegation.

**Given** an escalation whose resolution would change the epic goal or approved scope, change an architecture decision or invariant, drop or rewrite an acceptance criterion, or exceed any declared budget
**When** the PM evaluates it
**Then** the story enters loud `NEEDS_HUMAN` with the escalation evidence attached
**And** the PM never takes any of those actions alone.

**Given** a `NEEDS_DECISION` escalation
**When** the PM routes it
**Then** the envelope test decides: a decision inside the envelope is taken and recorded by the PM, a decision outside it escalates to `NEEDS_HUMAN`
**And** the decision and its routing rationale are recorded either way.

**Given** it is ambiguous whether an action is inside the envelope
**When** the PM evaluates the escalation
**Then** the ambiguity resolves to `NEEDS_HUMAN`
**And** the envelope fails closed rather than expanding by interpretation.

**Given** a story and its epic
**When** orchestration begins
**Then** explicit machine-readable budgets exist for at least fix/review cycle count, cost class, and wall time, with documented defaults where not declared (accepted story defaults: 3 fix/review cycles, 2 continuation workers, 24 hours active orchestration wall time; cost class is the stamped funding class with no upgrade authority)
**And** budget declarations are readable by automation without prose parsing, and the epic budget includes PM continuation count (Story 1.5, FR-126).

**Given** any declared budget is exceeded
**When** the boundary is crossed
**Then** work on that story stops and escalates loudly with the budget evidence
**And** there is no automatic cycling past a budget and no resumption without a recorded human decision.

**Given** the PM takes any envelope action
**When** the action completes
**Then** the story record captures the triggering escalation code, the action taken, the rationale, and the budget state at the time of the action
**And** an unrecorded envelope action is a defect.

**Given** the whole course-correction mechanism
**When** its authority is examined
**Then** the PM refines only within approved scope and never redefines it
**And** human design authority over goals, scope, architecture, invariants, and acceptance criteria is preserved end to end.

**Given** a review finding raised inside a fix/review loop
**When** the convergence policy evaluates whether it blocks a cycle
**Then** it blocks only when all three hold — it violates a frozen requirement, it is reproduced, and it is reachable by one ordinary operator action — with the three-part evaluation recorded per finding with evidence
**And** a finding failing any part is below-bar for cycle-triggering purposes without being dispositioned away.

**Given** a story whose review policy (route-class declared, FR-117) requires review
**When** its first implementation review runs
**Then** that first review is a full adversarial sweep, and subsequent reviews inside the loop are scoped to the diff of the fix under review
**And** previously dispositioned territory is not re-opened absent a new above-bar blocker visible in that diff.

**Given** a finding in the same defect class as an already-dispositioned finding but with narrower reach
**When** the convergence policy routes it
**Then** it enters the residual registry with a recorded reason instead of triggering a new cycle
**And** the registry is part of the story record, is presented at freeze/owner review, and never marks a frozen requirement satisfied.

**Given** a fix introduces a NEW above-bar blocker
**When** the loop evaluates the fix
**Then** the loop stops and escalates loudly as a design fault
**And** another cycle is not triggered.

**Given** the fix/review loop is running under the cycle budget
**When** exit is evaluated
**Then** exit occurs exactly on a clean full sweep, a clean diff-scoped review, or cycle-budget exhaustion with only below-bar residuals remaining
**And** cycle-budget exhaustion with an above-bar blocker outstanding stops and escalates and is never reported as convergence.

**Given** stories arriving on different route classes
**When** the review requirement is determined
**Then** it follows declared machine-readable policy that may vary by route class — locally routed work may require a full adversarial review where subscription-routed work may not
**And** the review policy in force is recorded in the story record.

**Given** Story 1.6 deterministic tests
**When** its isolated suites run
**Then** they cover each starting escalation code round-tripping through a thin result, registry stability and additive versioning, every autonomous envelope action, every `NEEDS_HUMAN`-mandatory action refusing autonomous handling, the `NEEDS_DECISION` envelope test in both directions, envelope-ambiguity fail-closed behavior, budget declaration and defaults, each budget type stopping and escalating on excess, no-auto-cycling past budgets, complete audit-record capture, the three-part blocker bar in every combination, diff-scoping after the first sweep, residual-registry routing and freeze presentation, new-blocker loop stop, all three exit conditions and the never-converged exhaustion case, and route-class review policy selection including the no-review-required branch
**And** Story 1.1–1.3, Story 1.5, and frozen orchestration gates remain green.

**Requirements covered:** FR-106–117 and NFR-13–15 (PRD addendum `prd-addendum-1.5-1.6.md`); consumes the frozen Story 1.3 thin-result delivery, completion-watch, and loud `NEEDS_HUMAN` contracts and the Story 1.5 escalation-channel signals and PM-continuation budget input (FR-126) without modifying frozen requirements.

## Implementation Constraints

- Frozen PRD: _bmad-output/planning-artifacts/prds/prd-agent-flow-kit-2026-08-24/prd.md — unchanged by this story.
- Requirement authority for this story: _bmad-output/planning-artifacts/prds/prd-agent-flow-kit-2026-08-24/prd-addendum-1.5-1.6.md
- Sequenced strictly after Story 1.5; not part of the frozen portability baseline or its GREEN verdict.
- Budget defaults are owner-accepted (2026-08-26); the starting escalation-code set stands as the initial registry. Refining values or adding codes is additive policy/registry work, not a requirement change. Removing or redefining a code is a requirement change and needs owner disposition.
- The envelope grants no new authority anywhere: routing stays central, scope/architecture/AC changes stay human, and `max_cycles` in story frontmatter remains the fix/review cycle budget this story makes an explicitly enforced, escalating boundary.
- The convergence policy (FR-112–117) binds to that same cycle budget: the blocker bar governs what triggers a cycle, never whether a frozen requirement is satisfied; residuals defer findings to owner review — they do not dismiss them. Route-class review policy is declared configuration, not per-story judgment.
- Harness agnosticism (NFR-13–15): the escalation registry, envelope rules, budgets, and convergence policy reference no specific CLI; anything harness-specific stays in per-harness adapters. An adapter gap reports `NOT_EVALUATED` — never core fallback logic, never a block on other harnesses. Any acceptance test that exercises a harness runs on at least two approved harnesses.
- Do not broaden into router, catalog, prox-ops, Kubernetes, GPU, or control-plane product work.
- Worker-originated subdelegation remains out of scope (see follow-on-worker-subdelegation.md).

## Dev Agent Record

- Status: **FROZEN — owner-approved 2026-08-26.** Stories 1.5, 1.6, 1.7 and PRD addendum FR-96–126 / NFR-13–15 frozen together. Sequenced after Story 1.4; 1.7 may run in parallel with 1.3. Outside the `AGENT-FLOW-KIT PORTABILITY GREEN` verdict.
- Implementation artifacts:
- Gates:
- Findings and resolutions:
- Final diff size:
