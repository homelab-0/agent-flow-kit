---
title: Worker Subdelegation and Resource-Aware Helper Offload
status: backlog-design-item
baseline: follow-on; excluded from frozen AFK portability Stories 1.1-1.4
promotion_gate: explicit PRD reconciliation amendment or subsequent epic
created: 2026-08-24
---

# Worker Subdelegation and Resource-Aware Helper Offload

## Product outcome

A centrally routed BMAD worker can propose a bounded subordinate task and receive a thin result from a separately routed, stamped, supervised Orca child worker. This allows expensive subscription-backed worker context to be preserved when the central router determines that cheaper or local capacity is sufficient for bounded mechanical, research, or test-analysis work.

```text
BMAD PM · ORCH
  -> centrally routed BMAD worker
  -> worker proposes bounded subordinate task
  -> AFK requests a new central route
  -> independent immutable stamp
  -> supervised Orca child Task / Dispatch / Worker
  -> thin result returns to parent worker
```

The worker proposes the task. The router selects the execution resource. A worker never selects or invents a provider, model, physical GPU, entitlement, placement, or metered fallback.

Framing (added 2026-08-26 at Story 1.5/1.6 refinement): subdelegation is primarily a context-relief mechanism — the parent offloads summarization, bulk mechanical work, and triage so its own context budget is spent on the judgment work it was routed for — and it therefore depends on Story 1.5 (context budgeting and continuation), whose window, usage, and threshold signals are what would tell a parent that relief is warranted and bound what a child may consume. This framing changes nothing else in this document: the scope, authority contract, exclusions, and promotion gate above stand as written, and this item remains unscheduled backlog.

## Initial authority contract

- Child authority is a strict subset of or equal to the parent authority: `child authority <= parent authority`.
- Maximum delegation depth is one.
- Child concurrency is bounded.
- Every child receives an independent central route and immutable execution stamp.
- Delegation cannot expand task scope, repository authority, secrets, spend authority, permissions, or mutation authority.
- No silent metered spend or local routing fallback is permitted.
- Children cannot create the final independent review or delegate owner, architecture, merge, promotion, or freeze authority.
- The parent remains accountable for its assigned task, child output review, integration, and deterministic gates.
- Mutating child work must use the eventual approved Orca/worktree isolation contract. Concurrent uncontrolled edits in the parent's worktree are forbidden.
- Parent/child identity, lifecycle, cancellation, failure, cleanup, and thin-result provenance must be explicit and inspectable through Orca.

## Persona and resource independence

Local-model execution is a resource decision, not a persona decision. Do not assume local workers are persona-less. The child task must retain its required BMAD role semantics independently of the routed resource.

If a full installed BMAD persona payload proves infeasible on a constrained local model, evaluate a bounded persona representation as a separate compatibility/design decision. Removing persona semantics requires explicit reconciliation; it must not emerge as a launcher shortcut.

## Visibility and lifecycle implications

- The orchestration state model must support a generic parent identity rather than assuming every worker's parent is the PM.
- Parent, child, Task, Dispatch, Worker, persona, route, phase, state, child counts, and `NEEDS_HUMAN` must remain distinguishable.
- A child worker follows the same fresh-session and terminal-cleanup contract as other significant workers.
- Child failures return bounded evidence to the parent and cannot silently broaden fallback, retry, or mutation authority.

Story 1.3 may keep its normalized state representation forward-compatible with this hierarchy, but it must not implement worker-originated delegation in the current frozen increment.

## Historical design evidence

The existing local-GPU statusline behavior is historical evidence of resource-awareness intent. It does not prove that worker-originated delegation authority, central child routing, child stamps, or supervised child lifecycle currently exists.

## Explicit exclusions from the current increment

This item is not part of the frozen 95 FR / 33 AC / 12 NFR portability baseline and is not acceptance work for Stories 1.1-1.4. Promotion requires either:

1. an explicit reconciliation amendment to the frozen PRD; or
2. a subsequent epic with its own requirements, architecture reconciliation, routing, implementation stories, and acceptance evidence.

No route is stamped for this backlog item during capture.
