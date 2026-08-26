# AFK-PORT-1.2-F6-R11-FIX — worker_done evidence (retained by PM)

- **Run:** run_09474acba864 · **Task:** task_7053e6cc2ac2 · **Dispatch:** ctx_082762db541f
- **Worker terminal:** term_7a450051-193e-43e7-a06e-467b25b10d4e (fresh session)
- **Message:** msg_65f85467dda8 (delivery_11cfb49203b6, sequence 169), sent 2026-08-26T04:05:54Z
- **Outcome:** succeeded
- **Authorization:** Josh, "Decision 1 = FIX" (one bounded cycle; no auto-cycling) — dispatched from the retained brief `AFK-PORT-1.2-F6-R11-FIX-BRIEF.md`
- **Stamped route:** claude / claude-strong / high / subscription, metered=false (stamp validated; not substituted)
- **Persona proof:** identity sha256:07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee — matched, fail-closed
- **Files modified:** bin/agent-flow-kit, docs/LIFECYCLE-CONTRACT.md, tests/lifecycle-mutation-tests.sh, story record, traceability — **lib/ tripwire never fired; no intersection with merged #6–#8 surface**

## Per-signal decisions (matrix verified, not re-derived)

- **HUP → trapped (129)** — the reachable one; untrapped, bash ran the EXIT trap AT ONCE mid-`cp`, the lock came back under a live write and a contender acquired.
- **USR1 (138), USR2 (140), ALRM (142) → trapped** — not naturally reachable, but free, and completes the invariant.
- **PIPE (141) → trapped, deliberately** — non-reachability is a property of lib/ code this file doesn't own; one future `>&2` in a transaction would reopen it silently. Cost taken knowingly at the final emit.
- **QUIT → NOT trapped** — re-measured (SIG_DFL reset in a fresh session; shell still survived): bash's ignore is real. Trapping would newly kill runs that today complete. Pinned by regression R11f so it stays a decision, not an accident.
- Both handlers now disarm the whole trapped set (second signal of any kind cannot re-enter cleanup).

## Contract corrections (3)

1. Transaction step 2 — now true, and covers a write the process STARTED, not just the process.
2. Release paragraph — "Neither path leaves an installation permanently busy" replaced with the truth, naming the publication-window exception (B1, mechanism deliberately not fixed).
3. Exit-code prose widened from "SIGINT or SIGTERM … 130 and 143" to the actual trapped set; machine-checkable exit_codes block untouched.

## Regressions + anti-vacuity

Section 12, **102 assertions** (R11a–e: 19 per trapped signal; R11f QUIT: 7). Pid-only delivery via existing `sig_launch`, no setsid. Discriminator read WHILE the writer is parked (shell alive, exact incarnation held, contender refused). Baseline = current R10-fixed tree with the five traps removed: **FIXED 133/0 ×4 (1 solo + 3 concurrent); BASELINE 93/40 ×3 with a byte-identical failure set (8 per signal × 5, none in R11f).**

## Test-infrastructure finding (fixed in the test, not papered over)

First gate run failed 6 R11a assertions on a *correct* tree: the driver ran under `nohup`, which sets SIGHUP to IGNORE — an inherited SIG_IGN cannot be trapped, so the kit's HUP trap was silently a no-op. Signature: only HUP failed. Fix: `sig_deliverable()` probes `trap -p` and SKIPs loudly when a signal cannot be delivered. Verified both ways (nohup → 114/0 + one loud skip; normal → 133/0). Final gate probes all eight dispositions: all trappable, zero skips.

## Gates (verified from log files)

lifecycle 443/0 rc0 (440s) · mutation SOLO **577/0** rc0, 0 skipped (1658s) · mutation ×3 concurrent loaded **577/0** each (1217s wall) · concurrency ×2 207/0 rc0 · run-tests 231/0 rc0, shellcheck genuinely executing, all clean (2174s) · git diff --check clean · no flake across 8 mutation + 2 run-tests runs.

## Out of scope — registered in the Cycle 10 hardening-backlog block, not fixed

B1 (publication-window brick — remedy needs merged lib/afk-mutate.sh, impossible in this surface), N1 (aside leak), N2 (signal inside EXIT trap pre-disarm), N3 (signalled reclaimer unreported), N5 (file mode).

## Residual risks handed to the diff-scoped reviewer

1. USR1/USR2 exit statuses are Linux numbering (138/140); macOS would be 158/159 while README claims macOS proven — safety unaffected, reporting only; **wants a ruling** (PM: registering as a Story 1.4 portability item).
2. Section 11 lacks the deliverability guard (out of this cycle's surface).
3. R11f asserts bash's own QUIT disposition — an intended alarm if bash changes.
4. "Still alive" observation is a bounded 2s poll, justified.
5. Section 12 adds ~4.5 min; mutation gate is now run-tests' long pole.
6. R11f exceeds the brief's letter (deliberate, pins the non-trap decision).
