# AFK-PORT-1.7 — per-profile persona-mode recommendation

The rule is `scaffold/matrix.yaml`, applied mechanically and nothing else:

> `full` if every task passes in full mode with headroom >= 50% of window;
> `compact` if only compact passes those conditions; `unsuitable` otherwise.

Gate verdicts are the pre-declared deterministic gates, re-run independently
by `runner/run-cells.sh`. Raw counts are beside every verdict. Cells were run
once each; see `ANALYSIS.md` section 4 before treating any of this as stable.

## Verdicts

### `local-code-standard` (claude, qwen36-27b, window 65,536) — **unsuitable**

| mode | tasks passing | min headroom | headroom >= 50% |
|---|---|---|---|
| full | **1/3** (`lcs-full-T2`; T1, T3 FAIL) | 63,049 (96.2%) | yes |
| compact | **2/3** (`lcs-compact-T1`, `-T3`; T2 FAIL) | 65,003 (99.2%) | yes |
| none | 3/3 (not a rule input) | 65,068 (99.3%) | yes |

Headroom clears the 50% bar in every mode by a wide margin. Neither `full`
nor `compact` reaches all three tasks passing, so the rule returns
**unsuitable**. Note the profile passed 3/3 with no persona at all — the
rule's failing branch is a quality outcome, not a payload outcome.

### `local-general` (claude, qwen36-27b, window 65,536) — **unsuitable**

| mode | tasks passing | min headroom | headroom >= 50% |
|---|---|---|---|
| full | **1/3** (`lg-full-T2`, gate PASS on dispatch exit 3; T1, T3 FAIL) | 63,211 (96.5%) | yes |
| compact | **0/3** | 65,081 (99.3%) | yes |
| none | 1/3 (not a rule input) | 65,105 (99.3%) | yes |

Same headroom picture, worse gate outcomes: **unsuitable**.

This profile resolves to the same physical model, placement and window as
`local-code-standard`; the two verdicts agree, but the gap in the underlying
counts (2/9 vs 6/9) is run-to-run variance on one model, not evidence that
one profile is worse. Do not read these as two independent results.

### `claude/strong` (claude, claude-opus-5, window 1,000,000) — **full**

3/3 in full mode (`cs-full-T1/T2/T3`), 6-8 turns per cell, zero permission
denials, minimum headroom 997,410 tokens (99.7%). Both rule conditions met.
This is the vendor baseline for comparison, not a local profile.

### `openai/strong` (codex, gpt-5.6-sol) — **NOT_EVALUATED**

The three full-mode cells never reached the model: `codex exec` rejected the
persona-bearing prompt argument with a usage error, exit 2, in 8 seconds
(`os-full-T1/T2/T3`). Per NFR-14 this is an adapter gap reported as
`NOT_EVALUATED`; it did not block the claude cells. The codex adapter also
reports no context window, so the headroom condition is not computable for
any codex cell even in principle. The `none`-mode addendum passed 3/3
(`os-none-T1/T2/T3`), which shows the harness path is healthy and locates the
defect in persona injection. Re-run the full baseline after the adapter is
fixed.

## Summary

| profile | harness | verdict |
|---|---|---|
| `local-code-standard` | claude | **unsuitable** |
| `local-general` | claude | **unsuitable** |
| `claude/strong` | claude | **full** (baseline) |
| `openai/strong` | codex | **NOT_EVALUATED** (adapter gap) |

## What these verdicts do not authorize

**This records no prohibition.** The persona-independence contract in
`_bmad-output/planning-artifacts/follow-on-worker-subdelegation.md`
("Persona and resource independence") **stands unchanged**: local-model
execution remains a resource decision and not a persona decision, and a child
task still retains its required BMAD role semantics independently of the
routed resource. Nothing here removes persona semantics from anything, and
nothing here makes a local profile ineligible for any work.

`unsuitable` is the mechanical output of one rule over one unreplicated
matrix. It is not a routing input, a catalog change, or a launcher behaviour.
No route, profile, or catalog entry was created or modified by this spike.

Product adoption of a compact persona representation remains a **separate
explicit reconciliation**, exactly as the contract requires — a deliberate
compatibility and design decision, never a launcher shortcut. This bundle is
the evidence input to that reconciliation and to Story 1.5's sizing policy;
it is not the decision.

One caution for whoever holds that reconciliation: the failures this matrix
found are behavioural, not capacity (`ANALYSIS.md` sections 2 and 3). The
full persona payload never exceeded 3.79% of the local window, and the
dominant failure class — path resolution outside the worktree — appeared in
`none` mode too. Shrinking the persona is therefore not shown to fix what
actually failed here.
