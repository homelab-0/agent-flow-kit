# AFK-PORT-1.7 — evidence bundle index

Story 1.7 (spike): persona payload viability on local profiles. Evidence-only;
no production code and no kit behaviour change. Secret-free.

**Canonical cell count: 27 = 24 matrix cells + 3 addendum cells.**
The 24 matrix cells are 2 local profiles x 3 persona modes x 3 canary tasks
(18), plus the `claude/strong` full baseline x 3 tasks and the `openai/strong`
full baseline x 3 tasks. The `openai/strong` full cells are `NOT_EVALUATED`
(adapter gap, NFR-14); the 3 addendum cells are the codex `none`-mode run made
in their place.

Cell ids are `<profile-slug>-<mode>-<task>`, slugs
`lcs` = `local-code-standard`, `lg` = `local-general`,
`cs` = `claude/strong` (claude), `os` = `openai/strong` (codex).

## Analysis deliverables

| file | what it is |
|---|---|
| `cells.csv` | One row per cell: gate, dispatch exit, turns, denials, payload tokens, envelope input tokens, window, ratio, headroom, wall seconds, override, note. |
| `ANALYSIS.md` | Findings grounded only in the retained results, each naming its cells: pass rates, payload vs window, the path-resolution failure class, run-to-run variance, the gate-pass/NEEDS-HUMAN cell, the vendor baseline, the codex defect, and what the data cannot answer. |
| `RECOMMENDATION.md` | Per-profile `full` / `compact` / `unsuitable` from the `matrix.yaml` rule applied mechanically, with raw counts, and the statement that no prohibition is recorded and the persona-independence contract stands unchanged. |
| `threshold-rule.yaml` | Machine-readable advisory rule, schema `afk-persona-threshold-rule/1`: inputs, evaluation clauses, payload-ratio guard, quality floor, worked examples, and what the rule structurally cannot see. |
| `INDEX.md` | This file. |

## Matrix definition and canary inputs

| file | what it is |
|---|---|
| `scaffold/matrix.yaml` | The benchmark matrix: profiles, baselines, modes, tasks, how each measurement is derived, and the recommendation rule. |
| `scaffold/README.md` | How a cell is composed from a task body plus per-cell frontmatter. |
| `scaffold/dev-full.md` | Persona mode `full`: the installed BMAD DEV skill plus its customization, verbatim (7,944 bytes). |
| `scaffold/dev-compact.md` | Persona mode `compact`: the 446-byte role contract. Mode `none` has no persona key and no payload. |
| `scaffold/T1.md`, `T2.md`, `T3.md` | The three disposable canary task bodies. |
| `scaffold/gate-T1.sh`, `gate-T2.sh`, `gate-T3.sh` | The deterministic gates, declared before any run and re-run independently after each cell. |

## Runner

| file | what it is |
|---|---|
| `runner/run-cells.sh` | Coordinator evidence tooling, not product code: how each cell was composed, centrally routed through `/v1/route`, stamped (natural or recorded override), dispatched through the installed adapter, gated, measured into `results/<cell>.json`, and cleaned up. |

## Per-cell results

| path | what it is |
|---|---|
| `results/<cell>.json` | The machine-readable result: harness, profile, mode, task, gate verdict and line, dispatch exit, override provenance, window tokens, payload bytes and `bytes4` token estimate, ratio, headroom, harness envelope (turns, duration, permission denials, per-model context window and token counts) where the adapter supplied one, wall seconds. 27 files. |
| `results/<cell>/story.md` | The composed cell story, including the working-directory statement. |
| `results/<cell>/prompt.txt` | The dispatch prompt as sent. |
| `results/<cell>/route-request.json`, `route-response.json`, `route-response.override.json` | Routing provenance: what was asked, what the router decided naturally, and the recorded override where the cell had to run on a named profile. |
| `results/<cell>/CELL-<cell>.md.stamp.json`, `make-stamp.log` | The cell's immutable execution stamp and how it was made. |
| `results/<cell>/dispatch.log` | Stamp validation, placement resolution, launch class, harness exit, thin result. |
| `results/<cell>/claude-result.json` | The harness result envelope. In `lcs-full-T2`, `lcs-none-T2` and `lg-none-T2` this path holds a model-authored record instead, so no envelope was retained for those three cells. |
| `results/<cell>/result.json` | The dispatch thin result, where one was written. |
| `results/<cell>/terminal-buffer.json` | The cell terminal's retained output. Holds the `codex exec` usage error for the `os-full-*` cells. |

## Attempt-1 evidence (spike evidence in its own right)

| path | what it is |
|---|---|
| `scaffold-attempt1/` | The scaffolding story's failed first attempt on the natural local route: 57 turns, 43 permission denials, every path resolved to the canonical repository instead of the worktree. Attempt 2 succeeded on `claude/strong`. |
| `AFK-PORT-1.7-SCAFFOLD.route-request.json`, `.route-response.json`, `.route-response.override.json`, `.md.stamp.attempt1.json`, `.md.stamp.json` | Routing and stamp provenance for both scaffolding attempts. |
| `scaffold-attempt2-*.json` | Attempt 2's dispatch descriptor, worker start records and settled worker record. |
| `AFK-PORT-1.7-ASSEMBLE.route-request.json`, `.route-response.json`, `.route-response.override.json` | Routing provenance for this assembly task. |
| `../AFK-PORT-1.4-M4R/attempt1/` | Story 1.4's M4R smoke, showing the same path-resolution failure class independently, before cell stories stated their working directory. |
