# AFK-PORT-1.3 cycle 2 — worker_done evidence (retained by PM)

- **Run:** run_d3ce009d8e41 · **Task:** task_68a0c04fddb0 · **Dispatch:** ctx_f57f02724243
- **Worker terminal:** term_3e2a1cb1-986e-4a9d-8228-50015392f00c (fresh session, dispatch.sh least-privilege launch)
- **Outcome:** done — worker turn completed; independent launcher gates: lifecycle PASS · run-tests PASS · git diff --check PASS
- **Stamped route:** same immutable stamp as cycle 1 (digest sha256:31e65b15…, unexpired), re-validated 8/8 by dispatch.sh pre-launch. Persona proof 07ee71cf… unchanged, fail-closed.
- **Full worker report:** `AFK-PORT-1.3.md.claude-result.json` (.result), verbatim in-repo. Coordinator gate-evidence capture: `evidence/AFK-PORT-1.3-C2-gates/`.

## Worker outcomes against the cycle-2 brief

- **C2-A (fixed, test-side):** all three published-set sweeps shared one jq-semantics defect (`$s | index(.value.state)` evaluates the argument against index's INPUT); document shape already matched the contract. Fixed by binding first. Worker additionally found the SAME shape made a fourth sweep ("every reason code in a live result is published") silently vacuous — always index 0 against itself — fixed identically. All four sweeps now carry executable falsifiability controls (inject one out-of-set value, sweep must report exactly it).
- **Hidden fourth failure (fixed, product-side):** the C1 evidence tail truncated at 40 lines; the uncounted failure was `an uncheckable live dependency exits 5` — `afk_validator_verdict` mapped every non-zero validator exit to "rejected" (deterministic not-ready, exit 3) where the contract requires transient-unavailable, exit 5. Fixed: only validator exit 1 is a policy verdict; anything else → new `VALIDATOR_VERDICT_UNAVAILABLE`, transient, exit 5; an unanswered negative fixture is no longer a rejection.
- **C2-B (implemented per overrule):** new `lib/afk-monitor.sh` (~700 lines) + `monitor` command (`--register`, `--reconcile`, `--cleanup --live`): durable on-disk completion watch; completion authority only from a supervised delivery; retention→reconciliation→acknowledgement keyed by delivery_id (at-least-once, idempotent); heartbeat/terminal faults never manufacture results; provenance-bound worktree/branch cleanup failing closed; one bounded pass per invocation — no `--wait`, no rolling poll. New gate `tests/lifecycle-dispatch-tests.sh` covers every named regression from both required lists against real git repos and a stubbed Orca. Two flagged interpretations recorded in the DAR (review-dispatch non-duplication proven via effects; delivery transport modelled as durable inbox directory).
- **C2-C (correctly not implemented — frozen collision confirmed):** `tests/lifecycle-tests.sh:1431` enumerates `agent-stamp-validate` in the default-mode stub set, `:1448` asserts "no external binary was invoked" for default status, `:1454` asserts validator fixtures `NOT_EVALUATED` by default; the contract document states the same guarantee. Running fixtures by default fails all three frozen assertions. Fixtures remain behind `--live`; exact assertions recorded in the DAR under "Frozen-requirement collision". **Disposition: escalated to Josh with coordinator recommendation (see settlement report) — accept the implemented reading; register the AC-wording nuance in the residual registry.**

## Flags

- **Diff size now ~4,700 reviewable lines (~6× budget)**; recommended stacked split gains a fourth layer (dispatch monitor). Packaging remains Josh's freeze-time decision.
- Worker's self-named top risks for independent verification: shellcheck on `lib/afk-monitor.sh`; the dispatch gate's real `git worktree`/`branch -d`/`push --delete` usage; the schema↔document reason_codes comparison (40 new codes).
- Gates not executed by the worker (no shell — standing arrangement, stated plainly in the DAR); launcher ran them independently (all pass) and the coordinator captured full logs to evidence.
