# AFK-PORT-1.3 cycle 3 (authorized fix) — worker_done evidence (retained by PM)

- **Run:** run_d3ce009d8e41 · **Task:** task_61de0ddc07f4 · **Dispatch:** ctx_afde5e13036c
- **Worker terminal:** term_72943ba9-dcef-418c-9d79-a7d8604ddca1 (fresh session, dispatch.sh least-privilege launch)
- **Authorization:** Josh — "Fix B1–B4 + N1, one cycle"; C2-C ruled "accept --live reading" (both recorded in the story file)
- **Outcome:** done — launcher gates: lifecycle PASS · run-tests PASS · git diff --check PASS
- **Stamped route:** claude / claude/strong / high, subscription, metered=false; stamp digest sha256:f7ce0f80…, validated 8/8 pre-launch. Persona proof 07ee71cf… fail-closed.
- **Blocker verification (coordinator-executed, post-fix):** all four attack scripts flipped to **NOT REPRODUCED** with every control still holding (A1 IDLE-durable-close control, A2 arity-1 + trust controls, A3 next-process control, A4 answering-transport control). Outputs retained in the session scratchpad and summarized here; pre-fix runs all reproduced.
- **Full worker report:** `AFK-PORT-1.3-FIX.md.claude-result.json` (.result), verbatim in-repo. Coordinator gate evidence: `evidence/AFK-PORT-1.3-C3-gates/` (run-tests, lifecycle, diff-check artifact — N13 closed).

## Fixes as implemented (worker summary)

- **B1:** `ABSENT|IDLE|EXITED` share one cleanup arm; durable close requested unconditionally for AFK-owned handles before judging; both ABSENT readings stated at their code sites (N14 resolved); contract terminal row aligned.
- **B2:** undeterminable target binding → `ROUTE_TARGET_UNRESOLVED` fail-closed (zero and ambiguous arity); workspace-trust evaluation decoupled from `tpath`, `NO_SELECTED_WORKSPACE` emitted when no workspace determinable (N5 absorbed); usage boundary untouched per brief.
- **B3 (justified deviation from the brief's first-choice remedy):** latch split into `AFK_MON_PASS_NEEDS_HUMAN` (what the pass could not resolve) and derived `AFK_MON_NEEDS_HUMAN` set from it at the top of summarize — a bare reset would have made `monitor --register <bad>` exit 0, which the gate pins at 2. `afk_monitor_reset` remains dead (N8 explicitly still open, registered).
- **B4:** new `afk_monitor_git_remote` bounds all three remote calls (probe-runner timeout, `GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS`, `BatchMode=yes`); no bounding tool → `PROBE_BOUND_UNAVAILABLE`, call not run; timeout/failure → `NEEDS_OWNER`, never a false "deleted". New host dependency `timeout(1)` disclosed.
- **N1:** both published-reason sweeps bind-first with executable falsifiability controls; outcome unknown until gates ran — launcher run passed, coordinator full log capture in C3-gates.
- **Residual registry** (N2–N4, N6, N7, N9–N12; N5/N14 absorbed; N8 open) and the C2-C ruling recorded verbatim in the story file.

## Flags

- Cycle-3 diff ≈250 reviewable lines; story total ≈4,950 (~6× PR budget) — packaging flag stands for Josh at freeze.
- Gates not executed by the worker (no shell; standing arrangement, stated in the record); launcher and coordinator runs are the arbiters.
