# PRD and PR #5 Reconciliation Report

## Verdict

The frozen product rulings and authoritative architecture are compatible. Reconciliation required clarification and missing guards, not a change to the product direction. The PRD remains a draft pending normal finalization review.

PR #5 is valuable implementation evidence, but it is not merge-ready against this PRD. Its lifecycle foundation should be reused selectively and adapted; six material behaviors conflict with frozen requirements, and twelve required behavior groups remain absent.

## Authority Applied

1. Frozen product rulings in this PRD discovery
2. Architecture invariants and responsibility boundaries
3. Proven EPIC-035 behavior
4. Current agent-flow-kit implementation
5. PR #5 implementation evidence

The historical claim that route → stamp → validator → Orca remained unproven was rejected as stale; EPIC-035 Phase B supersedes it.

## Architecture Reconciliation

### Compatible Boundaries

- Human → Orca → BMAD PM → agent-flow-kit → fresh specialized workers remains the product flow.
- Orca retains coding-session execution, host, worktree, terminal, environment, credential, and process authority.
- BMAD retains methodology, personas, story semantics, acceptance criteria, and the PLAN/ORCH activation boundary.
- agent-flow-kit retains opt-in delegation/control flow and gains lifecycle authority only over declared kit-owned artifacts.
- agent-router remains the sole resource/model/funding/placement authority.
- prox-ops remains infrastructure and the current origin of a transitional validator bridge, not the portable product dependency.
- Coding-agent host and physical inference host remain independent.

### PRD Corrections Applied

- Made the full owner/responsibility matrix explicit near the front of the PRD.
- Moved real-host proof out of product features into a distinct acceptance track.
- Changed readiness aggregation to operate within each readiness scope rather than poisoning unrelated targets, harnesses, routes, or live operations.
- Clarified that offline verification cannot assert live host-execution readiness.
- Corrected recovery-journal wording so the journal initializes before mutation and records completed steps as they occur.
- Added plan freshness and source/destination revalidation to prevent stale-plan and TOCTOU mutation.
- Added serialization or exclusion for concurrent mutations.
- Added symlink/path-containment refusal at managed ownership boundaries.
- Added registered-adaptation revalidation so stale exception records cannot legitimize new drift.
- Added freshness binding for target, stamp, dependency identity, and live observations.
- Added acceptance handling for late-bound local placement when applicable and stamp expiry between validation and launch.
- Replaced the stale discovery placeholder with explicit reconciliation notes.

### Duplicates and Structural Issues

- Ownership and exclusion language was repeated across increment boundary, feature details, and the former architecture section. The architecture matrix is now the primary boundary statement; feature-level repetition remains only where it creates testable behavior.
- Acceptance was previously nested under “Feature Requirements,” obscuring that it validates the four capabilities rather than defining a fifth subsystem.
- Evidence requirements currently precede some flow details and may be reordered during final polish without changing content.
- Success metrics and architecture constraints should remain front-loaded during final polish.

### Remaining Architecture Work, Not Product Discovery

- Exact lifecycle command names and serialization formats
- Manifest and journal storage mechanisms
- Managed-section representation and update mechanics
- Compatibility metadata packaging and migration implementation
- Claude/Codex capability and native-auth probe adapters
- Orca capability-probe and normalized session-state adapter details
- Standalone AI Control Plane validator/client distribution contract
- Exact representative host selection after observed fleet inspection

These are downstream architecture or implementation decisions. They do not reopen the frozen capability set.

## PR #5 Evaluation

Evaluated source: GitHub PR #5, head `5ce5f8431595df434bffce34c306e69ed943c60fd`.

| Classification | Count | Disposition |
|---|---:|---|
| REUSE | 9 | Preserve foundations that satisfy the frozen behavior cleanly. |
| ADAPT | 11 | Retain useful mechanisms but change their contract or safety behavior. |
| CONFLICT | 6 | Do not merge unchanged; behavior violates frozen requirements. |
| GAP | 12 | Add required behavior absent from the branch. |
| OUT_OF_SCOPE | 2 | Remove or leave outside this increment's ownership. |

### REUSE

- One lifecycle entry point with status/adopt/update/verify structure (`bin/agent-flow-kit`).
- Managed-copy, managed-section, machine-local, managed-link, and target-wiring foundations.
- Git-history matching for exact recognized legacy content.
- Hash-based managed drift refusal before ordinary replacement.
- Preservation of machine-local launcher configuration and content outside managed policy sections.
- Exact applied Git commit recording and temporary-file state replacement.
- Stable no-op intent and fixture coverage for current-state update.
- Transitional installed validator/client boundary instead of cloning prox-ops.
- Preserved frozen routing, stamp, placement, Orca, native-auth, and visible-worker invariants in documentation and regression CI.

### ADAPT

- Expand repository/source eligibility beyond “Git worktree plus expected directories” to recognized identity, managed-input cleanliness including untracked inputs, branch/source-selection intent, and schema compatibility.
- Replace the current auto-adopt-or-refuse behavior with all three required tiers: auto-adopt, deterministic approval plan, and refuse.
- Add an explicit registered-adaptation model for exceptions inside otherwise managed territory.
- Make managed-section preservation byte-contract behavior explicit and safe across missing trailing newline, duplicate markers, and path/symlink boundaries.
- Replace version/presence-only dependency checks with capability contracts and scoped readiness.
- Strengthen validator proof from help-text inspection to compatible identity plus positive and negative fixtures.
- Separate target wiring schema detection from one historical template path and DEV-only existence checks.
- Turn per-artifact staging into a whole-operation journal, deterministic rollback, interruption detection, and final verification before applied-state commit.
- Separate compatible stale installation readiness from newer checkout/update availability.
- Expand spend-safety inspection to the selected route and harness while preserving explicitly authorized future funding classes.
- Retain fixture and CI scaffolding but extend it to all isolated destructive-path and anti-vacuity requirements.

### CONFLICT

- `status --fetch` mutates Git remote state, violating strictly read-only status and the explicit rule that lifecycle does not fetch or pull.
- Verification is live by default and uses `--offline` to opt out; the PRD requires offline default and explicit live evaluation.
- Both Claude and Codex are globally mandatory; the PRD makes them individually optional and route-specific.
- Router timeout/non-200 is labeled `BROKEN`; it must be transient live unavailability scoped to new-work readiness, not installed corruption.
- Dirty checkout is labeled local installation drift and poisons verification; source eligibility and installed execution readiness must remain separate.
- Blanket environment rejection is not route/funding aware and can incorrectly reject an explicitly authorized future entitlement; only unauthorized deviation from the accepted funding/auth contract must block.

### GAPS

- Versioned normalized JSON result schema, stable reason codes, blocking scopes, and exit contract
- Explicit lifecycle/state compatibility metadata and migrations
- Registered adaptation records and revalidation
- Approval-required adoption plans with bounded authority
- Complete operation plans retained before mutation
- Whole-operation journal, rollback, interruption recovery, and commit-after-final-verification semantics
- Scoped host/new-work/target/route readiness
- Native subscription-auth usability and harness capability proof
- Non-vacuous validator positive/negative checks
- Read-only bridge to normalized orchestration state and visibility regression evidence
- Two-real-host evidence bundle and real PR→merge→pull→update proof
- Full routed, stamped, validated, Orca-visible worker acceptance smoke and cleanup

### OUT_OF_SCOPE

- Fetching remote refs as part of lifecycle status
- Any lifecycle behavior that grows into external authority management rather than validating externally owned capabilities

## Review Findings Retained

- Adversarial review: `review-adversarial.md` — 23 findings
- Edge-case review: `review-edge-case.md` — 14 unhandled paths
- Structure review: `review-structure.md` — 8 findings
- Prose review: `review-prose.md` — 11 findings
- Detailed PR #5 classification: `reconcile-pr5.md`

Editorial findings remain suggestions for the final polish pass; they do not alter frozen product content without owner disposition.

## Planning Gate

Implementation planning should not treat PR #5 as an accepted baseline. It may use the REUSE and ADAPT categories as candidate implementation inputs only after the PRD completes final review and the downstream architecture resolves the remaining mechanism decisions.
