# AFK-PORT-1.7 — analysis of the persona-payload viability matrix

Scope: findings from the retained machine-readable results only
(`results/<cell>.json`, produced by `runner/run-cells.sh`). Quality verdicts
come from the pre-declared deterministic gates in `scaffold/gate-T*.sh`,
re-run independently by the runner after each cell finished; no transcript
was graded. Every claim below names the cells it rests on.

Matrix as run: 24 matrix cells (2 local profiles x 3 modes x 3 tasks = 18,
plus `claude/strong` full x 3 and `openai/strong` full x 3) and a 3-cell
`none`-mode codex addendum. Cells were run once each; nothing was repeated.

## 1. Pass rates by profile x mode

Gate verdicts, PASS out of 3 tasks:

| profile (harness) | full | compact | none |
|---|---|---|---|
| `local-code-standard` (claude, qwen36-27b) | 1/3 | 2/3 | 3/3 |
| `local-general` (claude, qwen36-27b) | 1/3 | 0/3 | 1/3 |
| `claude/strong` (claude, claude-opus-5) | 3/3 | not run | not run |
| `openai/strong` (codex, gpt-5.6-sol) | NOT_EVALUATED | not run | 3/3 |

Per-cell detail is in `cells.csv`. Local totals: 8 of 18 cells passed.
Vendor baseline on claude: 3 of 3. Codex full baseline did not execute at all
(section 6); its `none`-mode addendum passed 3 of 3.

Only three cells across the whole local grid failed with a passing sibling on
the *same* task and mode pair, so the grid is small: a 1/3 and a 2/3 differ by
one cell. Treat every rate here as a signal from a single unreplicated run.

## 2. Payload versus window — capacity is not the constraint

Every local cell ran on `qwen36-27b` with a declared 65,536-token window.
The largest persona payload measured across the whole local grid was the
`full` mode at 3.79% of the window (`lcs-full-T2`, 2,487 estimated tokens);
the smallest was `none` at 0.42% (`lg-none-T1`, 273 tokens). Minimum
remaining headroom over all 18 local cells was 63,049 tokens — 96.2% of the
window (`lcs-full-T2`). Compact mode sat between 0.60% and 0.81%.

Stated plainly: the full installed BMAD persona payload consumes under 4% of
the local window, and no local cell came within two orders of magnitude of
exhausting its context. **Nothing in this matrix is a capacity result.** The
failures below are behavioural.

The payload figures are the byte-derived estimate `ceil(bytes/4)` over
persona + composed story + dispatch prompt, as `scaffold/matrix.yaml`
specifies as the fallback. The envelope `inputTokens` recorded alongside them
(`envelope_input_tokens` in `cells.csv`) is a whole-run total across all
turns, not a first-turn payload measurement, and is reported for reference
only — it is not comparable to the payload column.

## 3. The dominant failure class: path resolution outside the worktree

Every local cell that retained a harness envelope recorded permission
denials: 15 of 15 cells, 116 denials in total, ranging 4 to 18 per cell,
median 7. Classified by the denied path in each `permission_denials` entry,
**all 116 denials are the same class**: the model addressed a path outside
its worktree — the canonical repository
`/home/devbox/repos/jlengelbrecht/afk-smoke-target` (`lcs-full-T1`,
`lcs-compact-T1/T3`, `lg-*`, and others), or a location derived from it under
`~/.claude/repos/...` and `~/.claude/projects/-home-devbox-repos-...`
(`lcs-none-T1`, `lg-none-T1`, `lg-none-T3`, `lcs-compact-T2`). The vendor
baseline recorded zero denials in all three cells (`cs-full-T1/T2/T3`).

The scaffolding story's own first attempt is the same class in its most
severe form: `scaffold-attempt1/` records 57 turns and 43 denials, every one
of them addressing the canonical repository rather than the worktree, on a
story that did not state its working directory. The Story 1.4 M4R smoke
(`evidence/AFK-PORT-1.4-M4R/attempt1/`) shows the class independently.

Between attempt 1 and the matrix, the runner began writing the absolute
working directory into every composed cell story
(`runner/run-cells.sh`, the `printf` that composes `stories/CELL-<id>.md`:
"Your working directory is `<W>` ... never a path outside this directory, and
do not probe for the repository location"). The effect is visible and
partial: peak denials fell from 43 to 18 and the median to 7, but **not one
local cell reached zero**. Stating the working directory helped; it did not
eliminate the class.

What the data cannot show: the denials are counted, not explained. Nothing
retained here establishes *why* the model resolved these paths — whether from
a stale project mapping, from the story text, or from its own prior. That
would need instrumentation the spike did not build.

There is one observable downstream consequence in the retained data. In
`lcs-full-T2`, `lcs-none-T2` and `lg-none-T2` the recorded result asserts the
gate was "verified-by-trace" with "no shell execution tool available in this
harness" rather than run — the model stopped attempting the operation and
reported a substitute. The independent gate re-run passed in all three cases,
so quality was unaffected; the honesty of the self-report was not. This is an
observation about the recorded JSON, not a reading of a transcript.

## 4. Variance on one physical model, not a profile property

`local-code-standard` and `local-general` are two catalog profile ids that
resolve to the same physical execution: both dispatch logs record
`qwen36-27b`, placement `kserve-a5000`, context 65536, effort medium, and
both stamps are identical except for `model_profile`
(`results/lcs-full-T1/dispatch.log` vs `results/lg-full-T1/dispatch.log`;
the two `CELL-*.stamp.json` files).

They nevertheless scored 6/9 and 2/9. Since the profiles differ only in name,
**that 4-cell gap is run-to-run variance of one model, not a property of
either profile.** It is also the strongest single caution in this bundle:
with one run per cell and no repetition, a spread of that size on identical
configuration means individual cell verdicts carry little weight and the
per-profile rates in section 1 should not be read as stable estimates. The
matrix as designed cannot separate variance from effect; only repetition
could, and repetition was out of scope.

## 5. A cell that passed its gate and still blocked

`lg-full-T2` recorded `gate: PASS` — the independent
`gate-T2.sh` re-run confirmed `spike/out/wordfreq.sh` produced the expected
top-three frequencies — while `dispatch_exit` was 3 and the dispatch log ends
`worker is blocked`. The worker had printed
`NEEDS-HUMAN: I don't have a Bash tool available in my current toolset to
execute the gate command — please run bash spike/gates/gate-T2.sh`
(`results/lg-full-T2/claude-result.json`).

The work was correct and complete; the worker asked for a human because it
could not self-verify. Dispatch has no state for that combination: a
NEEDS-HUMAN worker is blocked regardless of what the gates later say, so a
finished cell was recorded as a failed dispatch. This is the only cell in the
matrix where the gate verdict and the dispatch status disagree.

## 6. The codex full baseline did not execute — adapter gap, NOT_EVALUATED

All three `openai/strong` full cells exited in 8 seconds with
`CODEX_EXIT=2` and no harness envelope. The retained terminal buffers
(`results/os-full-T*/terminal-buffer.json`) end with the persona text echoed
as command-line argument text followed by
`Usage: codex exec [OPTIONS] [PROMPT]`.

The mechanism: the codex adapter prepends the persona to the prompt argument,
and `dev-full.md` opens with a `---` frontmatter fence, which `codex exec`
parses as an option rather than as prompt text. Nothing about the model or
the payload size was tested — the process never reached the model. Per
NFR-14 these three cells are **NOT_EVALUATED**, with the defect named in
section "Findings" of the story record. Consistent with NFR-14 they did not
block the claude cells.

The 3-cell `none`-mode codex addendum was run in their place and passed 3/3
(`os-none-T1/T2/T3`), which confirms the codex path itself is healthy and
isolates the defect to persona injection. No window or ratio figures exist
for any codex cell: the codex adapter reports no context window, so
`window_tokens`, `ratio` and `headroom` are null throughout.

## 7. What this bundle cannot answer

- Whether any per-profile or per-mode difference is real. One run per cell,
  and section 4 shows identical configuration producing a 4-cell spread.
- Whether the full persona payload *causes* the local failures. Payload never
  exceeded 3.79% of the window, and `none` mode failed too (`lg-none-T1`,
  `lg-none-T3`) — so the matrix separates neither payload size nor persona
  presence from the path-resolution class in section 3.
- Whether `openai/strong` can carry a persona payload at all. Not tested.
- Why the path-resolution failures happen; see section 3.
- Anything about tasks beyond the three small canaries, or about work whose
  context actually approaches the window.
