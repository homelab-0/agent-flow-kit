# AFK-PORT-1.2-F6-R10-POSTFIX-REVIEW — worker_done evidence (retained by PM)

- **Run:** run_09474acba864 · **Task:** task_55910528c8a5 · **Dispatch:** ctx_c9904744cbf6
- **Reviewer terminal:** term_1bf4d8ef-42f5-4165-a057-6d827a4c4d52 (fresh fifth-distinct review session)
- **Message:** msg_a07d2dae19a3 (delivery_3e6d484bbe67, sequence 152), sent 2026-08-25T19:48:24Z
- **Outcome:** succeeded — **verdict NOT CLEAN: exactly 1 blocker (F6-R11, SIGHUP), 5 findings below the exploitability bar**
- **Persona proof:** identity hash matched, fail-closed; route as stamped, not substituted
- **Read-only proof:** tree byte-identical before/after (sha256 of all five modified files + git status), HEAD 6f9a68c, nothing committed
- **Full report:** `evidence/AFK-PORT-1.2-F6-R10-POSTFIX-REVIEW.md`

## The blocker — F6-R11 (SIGHUP releases the lock mid-write)

Residual risk 1's premise is DISPROVEN by measurement: bash runs the EXIT trap on an untrapped fatal signal IMMEDIATELY (0.001s, child still running), unlike trapped INT/TERM which defer until the in-flight command finishes (3.41s). So an untrapped HUP does not behave like SIGKILL — it releases the lock mid-write. Reproduced: pid-only HUP (`kill -HUP <pid>`, pkill, a supervisor signalling the main pid) leaves the writer alive with the lock freed; a second real update ACQUIRED alongside the pending writer and rolled the installation back under it — FR-92 violated. (Whole-process-group HUP — a real terminal hangup — is benign; the writer dies too.)

**Exploitability-bar assessment:** CLEARS the bar — `pkill -HUP` is one ordinary operator action and the window is the entire write phase.

**Remedy, verified by the reviewer (not merely proposed):** `trap 'afk_terminate_on_signal 129' HUP` — with it: lock stays HELD, contender refused, rc 129, journal preserved, next run RECOVERED then CONVERGED. Plus the transaction-step-2 contract sentence it falsifies.

## Below the bar (residual registry, per the convergence policy)

1. A signal in the lock publication window now permanently bricks the installation with OPERATION_LOCK_OWNER_UNVERIFIABLE (pre-fix build was harmless there) — a three-command race the bar excludes; falsifies the new "Neither path leaves an installation permanently busy" sentence.
2. lock.released/lock.stale asides leak — housekeeping sweep only covers backup and stage op-* dirs.
3. A signal inside the EXIT trap before it disarms abandons the release (fail-closed; reclamation recovers it).
4. A signalled reclaimer destroys an abandoned lock unreported (F6-R9-adjacent, signal-shaped).
5. tests/lifecycle-mutation-tests.sh is mode 100644 (pre-existing; runner uses bash, no gate affected).

## Residual-risk dispositions

1 DISPROVEN → escalated as F6-R11 · 2 ACCEPTED (right design call) · 3 CONFIRMED fail-closed (no successor lock removable) · 4 CONFIRMED accurate · 5 CONFIRMED (the conditional assertions do discriminate).

## Gates (all rerun by the reviewer)

lifecycle 443/0 · mutation 475/0 solo and 3-of-3 loaded (section 11: 61/0 under load) · concurrency 207/0 ×2 · run-tests 231/0 (shellcheck genuinely clean) · git diff --check clean · anti-vacuity independently reproduced (pre-fix rebuild: 454/21 with exactly the claimed 21-failure set).

## PM disposition

Per the convergence-control policy (cycle cap active): NO cycle dispatched. Decision escalated to Josh — accept F6-R11 into the residual registry vs authorize the verified one-line fix + two contract-sentence corrections + a HUP regression, followed by a delta-scoped review.
