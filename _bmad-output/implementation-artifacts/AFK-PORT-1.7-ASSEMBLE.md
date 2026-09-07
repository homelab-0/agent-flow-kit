---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-PORT-1.7-ASSEMBLE.md.stamp.json
persona: analyst
gates:
  - "git diff --check"
  - "bash tests/lifecycle-tests.sh"
max_cycles: 2
---

# AFK-PORT-1.7-ASSEMBLE — assemble the spike's evidence bundle, recommendations and threshold rule

The benchmark matrix of the frozen Story 1.7 (`AFK-PORT-1.7.md`, read it and
its authority `prd-addendum-1.5-1.6.md` Capability 7 and NFR-13–15) has been
RUN by the coordinator through the kit's canonical dispatch path. Your job is
evidence assembly and analysis only: no production code, no kit behaviour
change, no new routes/profiles/catalog entries, no prohibition recorded.

## Inputs (all under `_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.7/`)

- `scaffold/` — matrix definition (`matrix.yaml`), the three persona payloads
  (`dev-full.md` = the installed BMAD DEV skill + customization verbatim;
  `dev-compact.md` = 446-byte role contract; mode `none` = no persona key),
  the three canary task bodies and their pre-declared deterministic gates.
- `results/<cell>.json` — one machine-readable result per cell (harness,
  profile, mode, task, gate verdict + line, dispatch exit, override provenance,
  window tokens, payload bytes/tokens estimate (`bytes4`), ratio, headroom,
  harness envelope where available: turns, duration, permission denials,
  per-model context window and token counts); `results/<cell>/` — the cell's
  composed story, prompt, route request/response(/override), stamp,
  dispatch log, claude result envelope, thin result, terminal buffer.
- `runner/run-cells.sh` — how cells were composed, routed, stamped,
  dispatched, measured and cleaned up (read it; cite it).
- `scaffold-attempt1/` — the scaffolding story's own failed attempt on the
  natural local route (57 turns, 43 denials, every path resolved to the
  canonical repository instead of the worktree); attempt 2 succeeded on
  claude/strong. This is spike evidence in its own right.
- The Story 1.4 M4R smoke (`evidence/AFK-PORT-1.4-M4R/attempt1/`) shows the
  same failure class on the natural route before the cell stories were
  amended to state the working directory.

Matrix as run: profiles `local-code-standard` and `local-general` (both
`qwen36-27b`, window 65536) × modes {full, compact, none} × tasks {T1, T2,
T3} = 18 local cells; vendor baseline `claude/strong` (claude) full × 3
tasks; `openai/strong` (codex) full × 3 tasks FAILED AT LAUNCH — the codex
adapter prepends the persona to the prompt argument and `dev-full.md` begins
with `---`, which `codex exec` parses as an option (usage error, exit 2). Per
NFR-14 that is an adapter gap: those cells are `NOT_EVALUATED`, and a
`none`-mode codex addendum (3 cells) was run instead; treat the codex full
baseline as NOT_EVALUATED with the defect named.

## Deliverables (write ONLY under `evidence/AFK-PORT-1.7/` and the record)

1. `cells.csv` — one row per cell: cell, harness, profile, mode, task, gate,
   dispatch_exit, turns, denials, payload_tokens_est, envelope_input_tokens
   (if any), window_tokens, ratio, headroom, wall_seconds, override, note.
2. `ANALYSIS.md` — findings grounded ONLY in the retained data, each with the
   cells it rests on: pass rates by profile × mode; payload vs window (all
   local payloads are a small fraction of 65536 — say so plainly, so the
   result is about behaviour, not capacity); the dominant failure class
   (path resolution outside the worktree → permission denials → the model
   stops asking for permission), its frequency, and that adding the working
   directory to the story helped but did not eliminate it; run-to-run
   variance on the SAME physical model between the two local profiles (they
   differ only in name; note that as variance, not a profile property, and
   that cells were not repeated); the cell that passed its gate yet printed
   `NEEDS-HUMAN:`; the vendor baseline (claude/strong 3/3, few turns, zero
   denials); the codex adapter defect. No reviewer impressions of
   transcripts: gates decide quality.
3. `RECOMMENDATION.md` — per profile, `full` | `compact` | `unsuitable` with
   the rule from `matrix.yaml` applied mechanically (full requires every task
   passing in full mode with headroom ≥ 50%; compact requires the same in
   compact mode; else unsuitable), the raw pass counts beside the verdict,
   and an explicit statement that this records NO prohibition: the
   persona-independence contract in
   `_bmad-output/planning-artifacts/follow-on-worker-subdelegation.md`
   stands unchanged, and product adoption of a compact representation is a
   separate reconciliation for which this is the evidence input.
4. `threshold-rule.yaml` — a machine-readable rule the kit could apply
   (schema `afk-persona-threshold-rule/1`): inputs `window_tokens`,
   `persona_payload_tokens`, `gate_pass_rate_by_mode`; outputs a persona mode
   per profile; encode the matrix rule plus a payload-ratio guard
   (persona ≤ 5% of window) and a quality floor (pass rate ≥ 2/3 on the
   canaries). Also state what the rule CANNOT see (behavioural failures the
   canaries surfaced) so it is applied as advisory, consistent with Story
   1.5's sizing policy being advisory.
5. `INDEX.md` — bundle index: every file above, the scaffold, the runner,
   results, attempt-1 evidence, with one line each and the canonical cell
   count (24 matrix + 3 addendum).
6. The Dev Agent Record of `_bmad-output/implementation-artifacts/AFK-PORT-1.7.md`:
   Implementation artifacts (the bundle), Gates (yours; the coordinator's
   independent kit gates prove non-interference separately), Findings and
   resolutions (the three findings for the hardening registry: working
   directory in the dispatch prompt; codex prompt leading-dash defect; a
   NEEDS-HUMAN-on-success handling note), Final diff size (record-only).

## Hard rules

No edits outside the deliverables. No secret values (the evidence is already
secret-free; keep it so). Gates decide quality; do not grade transcripts.
Numbers only from the JSON. Commit on your branch, named files, plain
message, no trailers; never push, never PR.

## Dev Agent Record

(worker fills in)
