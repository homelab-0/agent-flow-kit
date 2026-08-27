# AFK-PORT-1.3 cycle 4 (final authorized fix) — worker_done evidence (retained by PM)

- **Run:** run_d3ce009d8e41 · **Task:** task_17d780cd9a58 · **Dispatch:** ctx_24e240b0e75c
- **Worker terminal:** term_ebcf11e4-636e-4c81-bdb8-8e5da6723dc0 (fresh session, dispatch.sh least-privilege launch; tab foregrounded per Josh's visibility ruling)
- **Authorization:** Josh — over-budget cycle 4, "fix P1+P2 (+D2 companion)"
- **Outcome:** done — launcher gates: lifecycle PASS · run-tests PASS · git diff --check PASS
- **Stamped route:** claude / claude/strong / high, subscription, metered=false; stamp digest sha256:396ac383…, validated 8/8 pre-launch (fresh /v1/route, natural acceptance). Persona proof 07ee71cf… fail-closed.
- **Oracle verification (coordinator-executed post-fix):** P1 and P2 attack scripts flipped to **NOT REPRODUCED** (P1's failed-close control predicted NEEDS_OWNER correctly; P2's no-timeout pass returned on its own in 3s); **A1–A4 all remain NOT REPRODUCED** — no regression of the cycle-3 fixes. Outputs retained in the session scratchpad and summarized here.
- **Full worker report:** `AFK-PORT-1.3-FIX2.md.claude-result.json` (.result), verbatim in-repo. Coordinator gate evidence: `evidence/AFK-PORT-1.3-C4-gates/`.

## Fixes as implemented (worker summary)

- **P1:** the durable-close call's status is consumed for all of ABSENT/IDLE/EXITED — a refused close is `NEEDS_OWNER TERMINAL_RELEASE_UNPROVEN` even when the handle is unlisted; contract Terminal row now requires the request to have been *accepted*, and the ABSENT no-op assumption sentence replaced with what the code checks. Stub gained `STUB_CLOSE_FAILS` modes; `ghost-refused` regression + `idle-refused` control.
- **P2:** new `afk_monitor_probe_strict` (no warn-and-run fallback) for the monitor's terminal-list and durable-close observations; `afk_probe_run`'s readiness default untouched; contract §monitor sentences now true. New dispatch-suite section 8: PATH sandbox differing by exactly `timeout`, stall-capable stub, attack + three controls under an outer bound.
- **D2:** dispatch gate gained counted `skip()` with `N passed, M failed, K skipped` on the last line (survives run-tests' tail aggregation); stalled-remote split into host-independent dispositions + explicit refusal case; section 8 degrades to one named skip when the sandbox can't build.
- **Deviation (flagged for final review):** the brief's "add `timeout` to `afk_require_tools`" was implemented as *declared and announced, not fatal* (`afk_declare_bounding_tool`, live runs only). Worker's argument: the hard form collides with this same brief — `afk_require_tools` gates every command including offline ones; a fatal live-scoped form would either remove the readiness probes' out-of-scope warn-and-run reading or make item 3's required P2 assertions unreachable. Registered as D3-absorbed-with-deviation.

## Flags

- Cycle-4 delta within the fix surface; story cumulative ~5,000+ reviewable lines — packaging flag stands.
- Gates not executed by the worker (no shell; standing arrangement); launcher + coordinator runs are the arbiters.
- Worker's self-named risks for the independent run: the section-8 PATH mirror (degrades to counted skip), `ghost-refused`'s stub dependence, shellcheck on the three new functions.
