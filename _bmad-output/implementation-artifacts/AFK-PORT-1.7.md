---
linear:
stamp: AFK-PORT-1.7.md.stamp.json
persona: dev
gates:
  - "bash tests/lifecycle-tests.sh"
  - "bash tests/run-tests.sh"
  - "git diff --check"
max_cycles: 3
---

### Story 1.7 (Spike): Persona Payload Viability on Local Profiles

As an agent-flow-kit fleet operator,
I want benchmark evidence of whether each selectable local profile can carry the full BMAD persona payload, a compact role contract, or no persona,
So that persona representation on constrained local resources becomes a deliberate, evidence-backed compatibility decision instead of a launcher shortcut or an unexamined prohibition.

This is a bounded evidence-only spike: it produces a recommendation artifact, not production code, and it records no prohibition.

**Acceptance Criteria:**

**Given** the router catalog's set of selectable local profiles
**When** the spike enumerates its benchmark matrix
**Then** every selectable local profile is covered in three persona modes — full installed BMAD persona payload, compact role contract, and no persona — plus a vendor-profile baseline captured for comparison on both Claude and Codex
**And** profiles come from the catalog as routed facts; the spike creates no routes, profiles, or catalog entries.

**Given** each profile-by-mode cell
**When** it is benchmarked
**Then** the retained evidence records persona payload tokens versus the profile's declared context window, remaining work-context headroom, and canary task quality judged against deterministic gates
**And** the evidence is machine-readable, indexed, and secret-free.

**Given** the canary tasks used for quality measurement
**When** they are defined
**Then** each declares its deterministic gate before any run and is disposable, secret-free, and free of production behavior changes
**And** quality verdicts come from the gates, not from reviewer impressions of transcripts.

**Given** spike benchmark executions
**When** they run
**Then** each is an explicit spike-class, centrally routed evaluation run with bounded spend
**And** no local substitution, metered fallback, or credential exposure occurs, and no production code or kit behavior changes.

**Given** all cells are benchmarked
**When** the spike concludes
**Then** it outputs a per-profile recommendation (`full` | `compact` | `unsuitable`) and a machine-readable threshold rule the kit can apply
**And** the recommendation artifact reaches the PM as the spike's compact result.

**Given** the persona-independence contract in `follow-on-worker-subdelegation.md`
**When** the spike's output is recorded
**Then** no prohibition is recorded and the contract is left unchanged
**And** product adoption of a compact persona representation remains a separate explicit reconciliation for which this spike is the evidence input.

**Given** the spike's place in sequencing
**When** downstream work consumes it
**Then** its output is an input to Story 1.5's sizing policy and prerequisite evidence for any subdelegation promotion
**And** the spike may run in parallel with Story 1.3 and never blocks or modifies frozen Stories 1.1–1.4.

**Given** Story 1.7 evidence
**When** the bundle is assembled
**Then** it contains the benchmark matrix definition, per-cell machine-readable results, gate inputs/outputs, the per-profile recommendations, and the threshold rule, with an index
**And** existing frozen gates remain green (the spike changes no production code, so gates prove non-interference).

**Requirements covered:** FR-118–120 and NFR-13–15 (PRD addendum `prd-addendum-1.5-1.6.md`); consumes the router catalog and central routing as read-only authority and the persona-independence contract without modifying it.

## Implementation Constraints

- Frozen PRD: _bmad-output/planning-artifacts/prds/prd-agent-flow-kit-2026-08-24/prd.md — unchanged by this story.
- Requirement authority for this story: _bmad-output/planning-artifacts/prds/prd-agent-flow-kit-2026-08-24/prd-addendum-1.5-1.6.md
- Evidence-only spike: no production code, no kit behavior change, no new routes/profiles/catalog entries, no router policy input.
- Sequencing: may run in parallel with Story 1.3; before the subdelegation follow-on (its promotion gate consumes this evidence); output feeds Story 1.5 sizing policy, which does not block on it. Not part of the frozen portability baseline or its GREEN verdict.
- Every benchmark run is centrally routed as an explicit spike-class evaluation with bounded spend; no local substitution, no metered fallback.
- Harness agnosticism (NFR-13–15): the vendor baseline runs on both Claude and Codex; benchmark harness mechanics live in per-harness adapters, and any acceptance test that exercises a harness runs on at least two approved harnesses. An adapter gap reports `NOT_EVALUATED` and never blocks the other harness's cells.
- The persona-independence contract (`follow-on-worker-subdelegation.md`, "Persona and resource independence") stands unchanged; the spike records evidence and recommendations, never a prohibition or a product decision.
- Do not broaden into router, catalog, prox-ops, Kubernetes, GPU, or control-plane product work.

## Dev Agent Record

- Status: **FROZEN — owner-approved 2026-08-26.** Stories 1.5, 1.6, 1.7 and PRD addendum FR-96–126 / NFR-13–15 frozen together. Sequenced after Story 1.4; 1.7 may run in parallel with 1.3. Outside the `AGENT-FLOW-KIT PORTABILITY GREEN` verdict.
- Implementation artifacts: the evidence bundle at
  `_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.7/`, indexed by
  its `INDEX.md`. Canonical cell count 27 = 24 matrix cells (2 local profiles
  x 3 persona modes x 3 canary tasks, plus `claude/strong` full x 3 and
  `openai/strong` full x 3) + 3 codex `none`-mode addendum cells.
  - `scaffold/` — `matrix.yaml` (profiles, baselines, modes, tasks,
    measurement derivations, the recommendation rule), the three persona
    payloads (`dev-full.md` 7,944 bytes; `dev-compact.md` 446 bytes; mode
    `none` carries no persona key), the three canary task bodies and their
    deterministic gates, declared before any run.
  - `runner/run-cells.sh` — coordinator evidence tooling, not product code:
    how each cell was composed, centrally routed through `/v1/route`, stamped
    (natural route or recorded override), dispatched through the installed
    adapter, gated independently, measured and cleaned up.
  - `results/<cell>.json` (27) and `results/<cell>/` — machine-readable
    per-cell results plus the composed story, prompt, route request/response
    /override, stamp, dispatch log, harness envelope, thin result and
    terminal buffer. Secret-free.
  - `cells.csv` — one row per cell across all measured dimensions.
  - `ANALYSIS.md` — findings grounded only in the retained JSON, each naming
    its cells.
  - `RECOMMENDATION.md` — per-profile `full` | `compact` | `unsuitable` from
    the `matrix.yaml` rule applied mechanically:
    `local-code-standard` **unsuitable** (full 1/3, compact 2/3),
    `local-general` **unsuitable** (full 1/3, compact 0/3),
    `claude/strong` **full** (3/3, baseline),
    `openai/strong` **NOT_EVALUATED** (adapter gap).
  - `threshold-rule.yaml` — advisory machine-readable rule, schema
    `afk-persona-threshold-rule/1`, with a 5% payload-ratio guard, a 2/3
    quality floor, worked examples, and an explicit list of what the rule
    cannot see.
  - `scaffold-attempt1/` — the scaffolding story's failed first attempt on the
    natural local route (57 turns, 43 denials), retained as spike evidence.
  This story records **no prohibition** and makes no product decision. The
  persona-independence contract in
  `_bmad-output/planning-artifacts/follow-on-worker-subdelegation.md`
  ("Persona and resource independence") stands unchanged. No route, profile,
  or catalog entry was created or modified.
- Gates:
  - `git diff --check` — **PASS** (exit 0), run in the assembly worktree.
  - `bash tests/lifecycle-tests.sh` — **PASS** (exit 0): 476 passed, 0 failed.
  The spike changes no product code, so these gates prove non-interference
  rather than new behaviour. Each benchmark cell additionally carried its own
  pre-declared gate (`scaffold/gate-T*.sh`), re-run independently by the
  runner after the cell finished; those verdicts are the quality data and are
  recorded per cell in `results/` and `cells.csv`. The coordinator's own kit
  gates are recorded separately.
- Findings and resolutions: three findings for the hardening registry. All
  three are observations from the retained evidence; none is fixed here, and
  none changes kit behaviour in this story.
  1. **Working directory in the dispatch prompt.** Every local cell that
     retained a harness envelope recorded permission denials — 15 of 15
     cells, 116 denials, range 4 to 18, median 7 — and every one of the 116
     is the same class: the model addressed a path outside its worktree,
     either the canonical repository or a location derived from it under
     `~/.claude/repos/...` or `~/.claude/projects/-home-devbox-repos-...`.
     The scaffolding story's first attempt (`scaffold-attempt1/`, 57 turns,
     43 denials) and the Story 1.4 M4R smoke show the same class. Writing the
     absolute working directory into the composed story cut the peak from 43
     to 18 and the median to 7 but eliminated it in no cell; the vendor
     baseline recorded zero denials in all three cells. **Resolution: none in
     this story** (evidence-only). Registered for hardening: the working
     directory belongs in the dispatch prompt as a first-class field, not as
     prose in a story body, and the residue after that change needs its own
     diagnosis — the retained data counts the denials but does not explain
     why the paths resolve where they do.
  2. **Codex prompt leading-dash defect.** All three `openai/strong` full
     cells exited in 8 seconds with `CODEX_EXIT=2` and no envelope; the
     retained terminal buffers end with the persona echoed as argument text
     followed by `Usage: codex exec [OPTIONS] [PROMPT]`. The codex adapter
     prepends the persona to the prompt argument, and `dev-full.md` opens
     with a `---` frontmatter fence, which `codex exec` parses as an option.
     The model was never reached, so nothing about payload or capability was
     tested. **Resolution: reported as `NOT_EVALUATED` per NFR-14**; the
     defect did not block the claude cells, and a 3-cell codex `none`-mode
     addendum was run in their place and passed 3/3, isolating the defect to
     persona injection. Registered for hardening in the codex adapter (pass
     the persona on stdin or after `--`, or otherwise stop leading-dash
     content being parsed as options); the full codex baseline should be
     re-run once fixed.
  3. **NEEDS-HUMAN on success has no handling.** In `lg-full-T2` the
     independent gate passed — the artifact was correct — while
     `dispatch_exit` was 3 and the dispatch log ends `worker is blocked`,
     because the worker printed
     `NEEDS-HUMAN: I don't have a Bash tool available ... please run bash
     spike/gates/gate-T2.sh`. It asked for a human only because it could not
     self-verify. Dispatch has no state for "blocked but the gates pass", so
     completed work was recorded as a failed dispatch; it is the only cell in
     the matrix where the gate verdict and the dispatch status disagree.
     **Resolution: none in this story.** Registered for hardening: settle a
     NEEDS-HUMAN worker against the independent gate verdict rather than on
     the signal alone, and distinguish "blocked on a decision" from "blocked
     on a missing capability".
  Data limitation, recorded but not a registry item: in `lcs-full-T2`,
  `lcs-none-T2` and `lg-none-T2` the harness envelope path
  `stories/<cell>.md.claude-result.json` holds a model-authored record
  instead of the adapter's envelope, so turns, denials and token counts are
  unavailable for those three cells. Byte-derived payload figures and the
  independent gate verdicts are unaffected. All three of those records assert
  the gate was "verified-by-trace" with no shell available rather than run;
  the independent re-run passed in each case.
- Final diff size: 345 files changed, 9007 insertions(+), 3 deletions(-) — record-only.
  All of it is the evidence bundle (344 new files under
  `evidence/AFK-PORT-1.7/`, 308 of them per-cell result and provenance files)
  plus this Dev Agent Record. No product code, test, workflow, or
  configuration file is touched, which is what the two gates above confirm.

## Coordinator log (ORCH PM, 2026-09-07)

- Embargo lifted on Josh's "go" (2026-09-07). Spike run in parallel with
  Story 1.5 lane A, as the story allows.
- Scaffolding lane `AFK-PORT-1.7-SCAFFOLD` (disposable target
  `afk-smoke-target`, story + self-check gate declared and committed before
  dispatch at `3aad453`): attempt 1 on the NATURAL route
  `{claude, local-code-standard, medium}` through the installed adapter
  produced nothing — 57 turns, 43 permission denials, every Read/Write
  resolved to the canonical repository path instead of the Orca worktree
  (`evidence/AFK-PORT-1.7/scaffold-attempt1/`). Attempt 2 under a recorded
  override to `claude/strong` (stamp `sha256:03b533a6…`), supervised
  interactive worker: stalled twice on Claude Code's workspace-trust dialog
  for the new worktree (Orca `agent_prompt_stalled`); the coordinator
  accepted the dialog, recovered the task and attached the session. The
  worker delivered all ten files and reported honestly that its only gate
  red was a tracked template the coordinator had clobbered while provisioning
  `.agents` (coordinator defect; reverted; self-check `GATE PASS`);
  scaffolding committed to the target at `6e5ab98`.
- Matrix executed by the coordinator (`runner/run-cells.sh`), each cell a
  fresh Orca worktree, a `/v1/route` call, a stamp (natural for
  `local-code-standard`; recorded override for `local-general`,
  `claude/strong`, `openai/strong` — a spike cell must run on its named
  profile), the installed `dispatch.sh`, an independent gate, measurement,
  and cleanup. 24 matrix cells + 3 codex `none` addendum cells; all cell
  worktrees and terminals verified removed; evidence checked secret-free by
  exact match. Cells were run once each.
- Assembly lane `AFK-PORT-1.7-ASSEMBLE` (analyst persona, proof
  `4baeaab8…`; natural route `local-code-standard` overridden to
  `claude/strong` citing the matrix's own pass rates; stamp
  `sha256:83b2356a…`) produced the bundle (`INDEX.md`), `cells.csv`,
  `ANALYSIS.md`, `RECOMMENDATION.md`, `threshold-rule.yaml` and the record
  above. Coordinator validation: 27 rows, rule applied mechanically,
  no-prohibition statement present, threshold rule parses, codex full
  baseline `NOT_EVALUATED` with the adapter defect named.
- Hardening items raised by this spike (to the traceability registry):
  (19) the codex adapter passes the prompt as a positional argument and a
  persona file beginning with `---` is parsed as an option — terminate
  options with `--`; (20) the dispatch prompt should state the worker's
  absolute working directory (local models resolve to the canonical repo
  otherwise); (21) a worker that passes its gate yet prints `NEEDS-HUMAN:`
  is reported as blocked (exit 3) — decide precedence; (22) supervised
  interactive launches in a new worktree stall on the workspace-trust
  dialog, and Orca runs them with permissions bypassed — owner posture
  question.
- Verdict: Story 1.7 spike COMPLETE as an evidence-only deliverable. It
  records no prohibition; the persona-independence contract stands.
