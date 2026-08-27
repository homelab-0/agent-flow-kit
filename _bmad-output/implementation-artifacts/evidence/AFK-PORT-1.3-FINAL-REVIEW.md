# AFK-PORT-1.3 — final diff-scoped review (review-only, fresh session)

## 1. Verdict

**CLEAN.**

No blocker in the cycle-4 delta. P1 and P2 each close their class within the
scope the cycle was given; the `timeout` deviation is **sound**; I found no
previously-green path the delta broke.

Non-blocking register: 7 entries, all delta-scoped or delta-adjacent. One of
them (F1) is a contract-truthfulness item that wants an explicit coordinator
ruling before freeze, and I left a runnable script for it.

Scope: the ~210-line cycle-4 delta across `lib/afk-monitor.sh`,
`bin/agent-flow-kit`, `docs/LIFECYCLE-CONTRACT.md`,
`tests/lifecycle-dispatch-tests.sh`, `tests/run-tests.sh`, and their named
interaction points. Prior scenarios were not re-swept; I took the coordinator's
post-cycle-4 oracle results (P1/P2 NOT REPRODUCED, A1–A4 still NOT REPRODUCED,
controls holding, launcher and coordinator gate runs green) as established.

I had Read/Glob/Grep/Write and **no shell**. I executed nothing — see §5.

---

## 2. Blockers

None.

For the record, the two things I most expected to find and did not:

- **A close outcome still discarded somewhere.** There is exactly one call site
  for `afk_monitor_terminal_release` (`lib/afk-monitor.sh:852`) and its status
  is consumed. No other path in the tree calls it.
- **An external observation in the monitor pass off the strict path.** There
  are five, and all five are wrapped: the listing (`:443`) and the durable
  close (`:477`) through `afk_monitor_probe_strict`, the three remote-branch
  calls (`:993`, `:1008`, `:1009`) through `afk_monitor_git_remote`. Every
  other `git` invocation in the file (`:902`, `:912`, `:916`, `:944`, `:953`,
  `:965`, `:966`) is a local-repository operation that opens no transport. And
  a monitor pass cannot smuggle in a readiness probe: `bin/agent-flow-kit:439`
  moves `--live` onto `AFK_MONITOR_LIVE` and sets `AFK_LIVE_MODE=false` before
  the command runs, so `afk_readiness_evaluate`'s live block
  (`lib/afk-readiness.sh:1831-1837`) is not entered.

---

## 3. Non-blocking register (delta-scoped)

Class in brackets, with file:line and the text it presses on.

**F1 [docs] `docs/LIFECYCLE-CONTRACT.md:658-659` — the new sentence points at a
divergence the document does not contain.** The added text reads "This is
stricter than the live probes, whose own reading of a missing bound is stated
above". Nothing above states a warn-and-run reading; what is stated above is
`:421-423`, frozen: "A host that cannot bound a probe reports
`PROBE_BOUND_UNAVAILABLE` rather than running an unbounded probe as if it were a
bounded one." `afk_probe_run` (`lib/afk-readiness.sh:472-484`) reports it and
then runs the call anyway, so `:421-423` is still untrue of every readiness
probe — the last place in the kit where an external observation can outrun its
bound. The delta did not create that gap and was explicitly forbidden from
touching it (`AFK-PORT-1.3-FIX2.md`, "Out of scope"), and it did not worsen the
code. What it did do is make the document assert that the split is written down
when it is not, which is a step past the pre-existing tension the post-fix
review registered. **Recommended ruling, either way is honest:** amend
`:421-423` to state the readiness reading explicitly (bounded where a bound
exists; reported and run where none does), or make the readiness probes strict
too. Evidence:
`evidence/AFK-PORT-1.3-FINAL-REVIEW-attack/R1-readiness-probe-unbounded.sh`
(attacks `status --live`, not the monitor; controls included; exits 0
CONFIRMED / 1 NOT CONFIRMED / 2 inconclusive). It is written blind like
everything else here.

**F2 [method] `tests/run-tests.sh:1006`, `:1119-1124` — the skip count does not
survive the aggregate.** The dispatch suite's ordering is right and the reason
the record gives for it is right: the counts stay on the LAST line
(`tests/lifecycle-dispatch-tests.sh:1160-1165`, prose above, counts below), so
`tail -1` at `run-tests.sh:1109` surfaces `N passed, M failed, K skipped` inside
the aggregate's `ok` line. Three gaps above that line:

- `run-tests.sh` never adds a child suite's skips to its own `SKIPPED`, so its
  summary reads `N passed, 0 failed` while a child skipped K checks. The count
  is visible only in the body text of one `ok` line.
- `run-tests.sh:1006` prints a `SKIP` for the live chain with a bare `printf`
  instead of the counted `skip()` at `:49`. On any host without
  `AGENT_ROUTER_URL` — the default, and this host — the aggregate's own summary
  already under-reports by one before any child is considered.
- The aggregate prints its counts line *before* the prose line (`:1120-1121`),
  the inverse of the ordering the dispatch suite deliberately adopted, so
  `run-tests.sh`'s own last line in skip mode is prose. Nothing tails
  `run-tests.sh` today, so this costs nothing now; it would be the first thing
  to break if anything ever did.

Answering the question as asked: a skipped section 8 or a skipped
`stalled-remote` **cannot** masquerade as a pass inside the dispatch suite, and
**can** vanish from the aggregate's final counts line. Not a blocker — the SKIP
lines and the child's own summary are both in the retained log.

**F3 [method] `tests/lifecycle-dispatch-tests.sh:1003-1005` — the sandbox
self-check does not cover what it is protecting.** The sweep requires
`bash jq git find sed grep awk sort head tail date mktemp` in `$NOBIN`, but
`afk_require_tools` (`lib/afk-common.sh:67`) also needs `wc tr readlink cat cp
mv` and one of `sha256sum|shasum`. A mirror gap in one of those makes all four
section-8 cases fail as product failures instead of becoming the single counted
skip the check exists to produce — the exact misleading-red the record names as
this cycle's least portable piece. Likelihood is low (the mirror symlinks every
`PATH` entry), and the remedy is to drive the sweep from the same list
`afk_require_tools` uses.

**F4 [behavior] `lib/afk-monitor.sh:852-863` — the remaining member of P1's
class, and no local observation discriminates it.** An Orca that accepts
`terminal close --handle H --durable --json` with exit 0, ignores `--durable`,
and closes the tab non-durably produces: close accepted, handle absent on
re-observation, `REMOVED TERMINAL_RELEASED`, `SETTLED` — and the tab returns on
the next reconnect, which is precisely the harm B1/P1 exist to prevent. The
contract is honest about this (`:708` says the request "was **accepted**", which
is exactly what the code checks), and the story's frozen requirement is worded
as request-or-record ("Cleanup must record or request Orca's supported durable
close intent"), so this is not a violation. It is the honest limit of what the
current evidence can prove. Worth a ruling on whether the durable close should
be gated on the capability list `afk_probe_orca` already reads
(`lib/afk-readiness.sh:1078`) rather than on the flag being accepted — that
would close it without a new external observation. Registered, not fixed.

**F5 [docs] `lib/afk-readiness.sh:459-461` — vocabulary drift on
`AFK_PROBE_STATUS`.** The probe runner's header documents four values
(`NOT_RESOLVED`, `TIMEOUT`, `OK`, `NONZERO`); `afk_monitor_probe_strict`
(`lib/afk-monitor.sh:392`) now assigns a fifth, `BOUND_UNAVAILABLE`, documented
only at the monitor wrapper. No reader is affected — no monitor call site reads
`AFK_PROBE_STATUS` after a strict call, and the value never reaches emitted
output — so this is drift, not a defect. One line in the readiness header fixes
it.

**F6 [docs] `docs/LIFECYCLE-CONTRACT.md:650-652` — "none of them can ask a
human anything" is enforced for three of the five calls.** `afk_monitor_git_remote`
sets `GIT_TERMINAL_PROMPT=0`, `GIT_ASKPASS`, `SSH_ASKPASS` and `BatchMode=yes`
(`:416-418`). The two Orca calls inherit the caller's stdin and carry no
equivalent, so an Orca that prompted would be *killed by the bound* rather than
prevented from asking. This is cycle-3 text that cycle 4 did not touch, and
cycle 4 strictly improved the situation (before it, the same prompt on a
no-`timeout` host had no bound at all). Registered because item 5 of the brief
asks whether every sentence in this region is true of the code, and this half of
one sentence is true only by consequence.

**F7 [method] `tests/lifecycle-dispatch-tests.sh` sections 5-7 — the delta
widens how red a host without `timeout(1)` goes.** Correct and deliberate, but
worth stating because it is a delta consequence the record describes only for
the product: with the strict wrapper, a no-`timeout` host loads no Orca listing
at all, so every terminal reads `UNKNOWN` and every terminal disposition is
`NEEDS_OWNER`. Every scenario asserting `.cleanup.terminal == "REMOVED"` or
`.state == "SETTLED"` (`d-merged`, `d-unauth`, `ghost`, `ghost-control`,
`idle-refused`'s listing assertion is unaffected) now fails there, where before
cycle 4 the unbounded listing succeeded and they passed. D2's loud-skip
treatment was applied to the remote-branch scenarios only, per the brief. The
suite still fails loudly rather than vacuously, so nothing lies; the honest
follow-up is the same counted skip for the terminal-releasing scenarios, which
this cycle was not asked for. Irrelevant on the gate host, which has `timeout`.

Residual registry D1, D5, D6, D7, D8 and the open N-series: re-checked as
unchanged by the cycle-4 delta and not re-raised. D5 in particular is worth one
sentence — the strict wrapper only changes *whether* the mid-pass reload is
attempted, not the `|| true` that swallows its failure, so the "one transient
listing failure downgrades the rest of the pass" shape is exactly as it was.
D2, D3 and D4 are absorbed as the record claims: D2 by the `stalled-remote`
split and the counted skip, D4 by `STUB_CLOSE_FAILS` (which leaves mode `0` the
default, so every pre-existing scenario is byte-for-byte unchanged), D3 by the
declaration in `bin/agent-flow-kit` with the deviation judged in §4.

---

## 4. Remedy completeness and the deviation

### P1 — COMPLETE

The class is "a close outcome that decides nothing decides the arm anyway", and
it is closed:

- The release call's status is consumed for all three states that reach it
  (`lib/afk-monitor.sh:852-854`), the reviewer's simpler-and-safer form, so a
  failed close is `NEEDS_OWNER TERMINAL_RELEASE_UNPROVEN` whether or not the
  handle is gone.
- The accepted-then-relisted case still fails closed (`:857-863`): the reload
  runs, the handle is found, `NEEDS_OWNER`. So does accepted-then-unreadable —
  a failed reload leaves `AFK_MON_TERMINALS_LOADED=false`, `afk_monitor_terminal_status`
  prints `UNKNOWN` (`:464-466`), and `UNKNOWN != ABSENT` takes the same
  `NEEDS_OWNER` exit. There is no path from a non-`OK` close to `REMOVED`.
- A refusal that never reaches the daemon is covered too: `afk_probe_run`
  returns `NOT_RESOLVED` for an unresolvable `AFK_ORCA_BIN` (`:465-470`), which
  is non-zero, which is `NEEDS_OWNER`.
- The four human-in-the-loop arms and the `*)` fallback are untouched, so
  nothing previously retained is now released.
- `STUB_CLOSE_FAILS` models the three daemon behaviours honestly and the shapes
  are the real ones: mode `1` is "no such terminal" for a handle Orca is not
  listing (which the stub decides with its own `is_listed`, the same filter the
  listing uses, so the fixture cannot disagree with itself), mode `2` is a build
  with no `--durable`. Mode `0` is the default and is passed explicitly through
  `run_afk`'s `env`, so no scenario inherits a stale value.
- `ghost-refused` discriminates for the reason the record claims: on the
  pre-cycle-4 tree the `|| true` swallows the refusal, the absent handle is
  still absent, and the disposition is `REMOVED` / `SETTLED` / exit 0 /
  `retained.terminals == 0` — four failed assertions. I checked the two
  assertions it rests on against the code rather than the record:
  `count_findings TERMINAL_RELEASE_UNPROVEN == 1` follows from
  `afk_monitor_cleanup_record:1066-1074` emitting one finding per disposition,
  and `retained.terminals == 1` from `afk_monitor_summarize:1167-1173`, which
  counts a non-`SETTLED` record whose terminal disposition is neither `REMOVED`
  nor `NOT_APPLICABLE`. `idle-refused` is correctly labelled a control.

Remaining class member that cannot be closed by any local observation: **F4**.

### P2 — COMPLETE for the monitor pass

- Five external observations, five wrapped calls, enumerated in §2 with the
  grep that establishes there is no sixth.
- The timeout arithmetic is shared honestly, not re-implemented:
  `afk_monitor_probe_strict` (`:390-397`) checks for the tool and then
  **delegates to `afk_probe_run`**, so `afk_probe_timeout_seconds` —
  `(ms+999)/1000` with a 1 s floor — is computed in exactly one place and the
  monitor cannot drift from the probes. `afk_monitor_git_remote` calls the same
  function directly. No second arithmetic exists.
- `afk_monitor_bound_unavailable` shares `AFK_PROBE_UNBOUNDED_REPORTED` with
  the probe runner and reads it with a `:-false` default, so it is correct
  whether or not the readiness library reset it, and a pass reports the missing
  bound exactly once however many observations refuse. That is what makes
  section 8's `PROBE_BOUND_UNAVAILABLE == 1` and the `stalled-remote` refusal
  case's `== 1` both correct rather than accidentally correct.
- The readiness/monitor policy split is stated in the contract, and stated
  **almost** truthfully — `:650-661` is now true of the monitor, and `:1757-1759`
  ("or is refused and reported rather than made unbounded") is what makes the
  end-of-document guarantee true rather than aspirational. The exception is the
  cross-reference at `:658-659`: **F1**.
- Section 8 is a real regression, not a decorative one. The sandbox differs from
  the host PATH in one entry; the outer `"$REAL_TIMEOUT" 45` is invoked by
  absolute path so the sandbox cannot disarm it; `orca` resolves to the stall
  stub because `STALLBIN` is prepended, and the stub is derived from the suite's
  own file with `tail -n +2` so the durable-closure model cannot drift between
  them; registration happens outside the sandbox through the ordinary
  `run_afk`, which is right, because registration is not a live operation. On
  the pre-cycle-4 tree `orca-unbounded` does not return and the elapsed, `!= 124`
  and disposition assertions fail together, and `orca-answering-unbounded`
  discriminates independently of any stall. Controls A and C pass on both trees,
  as controls should.

### The deviation — SOUND

`timeout` is **declared and announced on the live paths**
(`bin/agent-flow-kit:137-142`, called at `:409`) rather than hard-required in
`afk_require_tools`. Judged on the merits:

- **The strongest argument is one the worker made only implicitly.** The frozen
  contract *defines a behaviour* for a host that cannot bound an observation:
  `:421-423` says such a host reports `PROBE_BOUND_UNAVAILABLE`, `:655-658` says
  the settlement pass refuses and retains on `NEEDS_OWNER`, and
  `PROBE_BOUND_UNAVAILABLE` is published vocabulary
  (`docs/LIFECYCLE-CONTRACT.md:1508`). A hard requirement in `afk_require_tools`
  would make that behaviour and that code **unreachable** — the same dead-published-vocabulary
  defect this story already treated as real when it fixed
  `NO_SELECTED_WORKSPACE` (N5). You cannot both require the tool and report its
  absence.
- The worker's three stated collisions check out. `afk_require_tools` runs for
  every command at `:406`, before the dispatch at `:411`, so the hard form
  refuses `status`, `adopt`, `update`, `verify` and `schema` on a host where all
  five are entirely computable — a behavioural regression on paths this cycle
  had no business touching, and one that cuts against the story's own "offline
  evaluation still works" acceptance criteria. Making it fatal only for
  `monitor --cleanup --live` would make the brief's own required P2 regression
  unreachable: item 3 asks that regression to assert the pass **returns** with
  `PROBE_BOUND_UNAVAILABLE` + `TERMINAL_RELEASE_UNPROVEN`/`NEEDS_OWNER`, which
  cannot happen if the command refuses at the usage boundary. The brief is
  internally in tension here, and the worker resolved it in favour of the
  frozen-contract behaviour over a `docs`-class pointer, which is the right
  ordering.
- **Operator experience: yes, loud enough.** The warning fires before the pass
  rather than after it, on every `--live` invocation (`AFK_LIVE_MODE` is still
  true at `:409`; the monitor's demotion to `AFK_MONITOR_LIVE` happens later, at
  `:439-440`), it goes to stderr so it never corrupts `--json` stdout, and it
  names both the tool and what the run will do instead. The one shape that
  loses it is `... --live 2>/dev/null`, and that operator still gets the
  `PROBE_BOUND_UNAVAILABLE` finding in the document and exit 2. D3's ask — "so
  the operator learns from the tool, not a stalled pass" — is met.
- It breaks nothing: no suite asserts an empty stderr. The three
  stderr assertions in the tree (`tests/lifecycle-tests.sh:1496`, `:1537`,
  `:1543`, `tests/lifecycle-readiness-tests.sh:1166`) are `assert_absent`
  against a sentinel, not emptiness, and this host has `timeout` so the line is
  not emitted during the gates anyway.

**One thing for the coordinator to record accurately rather than approve
silently:** this is a deviation from the brief's *fallback* as well as from its
first choice. The fallback's trigger was "if that hard requirement turns any
frozen Story 1.1/1.2 gate assertion red" — which was never shown — and its
instruction was to *scope the requirement*, not to replace a requirement with an
announcement. The worker disclosed all of this plainly and its reasons are
better than the trigger the brief named, so my judgment is sound-and-accept; it
should go in the record as an accepted deviation, not as compliance.

### New-regression check — nothing found

- **The IDLE/EXITED meaning change is real and is safe.** A transiently-failing
  close on a terminal that is nonetheless gone was `REMOVED` before cycle 4 and
  is `NEEDS_OWNER` now. No pinned scenario changes meaning, because before D4 no
  scenario could express a failing close at all (the stub succeeded
  unconditionally), and mode `0` keeps that behaviour as the default. The
  direction is fail-closed, and `idle-refused` pins it.
- The cascade is intended, not silent: a non-`REMOVED` terminal retains the
  worktree (`:886-888`) and therefore the branch and the remote. Every section-8
  and section-7 descriptor uses `-` for the other three resources, so those
  scenarios' `NOT_APPLICABLE` dispositions and their `COMPLETED`/`SETTLED`
  assertions are unaffected by the cascade.
- Scenario isolation holds for the new sections: `new_scenario` gives each a
  fresh `HOME` and therefore a fresh watch, and the terminals section 8 adds to
  the shared stub listing cannot reach section 9, which registers into its own
  `HOME` before building `MON_JSON`.
- `STUB_CLOSE_FAILS` is reset to `0` after both new section-7 scenarios, and
  `run_sandboxed` pins it to `0` explicitly, so section 8 cannot inherit a
  refusal.
- `afk_declare_bounding_tool` is a pure addition with an early return on the
  non-live path; nothing offline changes.

---

## 5. What I did not get to, plainly

- **I executed nothing.** No gate, no script, no output. This session has
  Read/Glob/Grep/Write and no shell, and the review-only contract forbids
  modifying anything in any case. The frontmatter gates
  (`bash tests/lifecycle-tests.sh`, `bash tests/run-tests.sh`,
  `git diff --check`) were **not run by me**; the coordinator's independent run
  is the arbiter. The one gate-adjacent check available from here: a trailing-whitespace
  sweep over every `*.sh`, `bin/agent-flow-kit` and
  `docs/LIFECYCLE-CONTRACT.md` returns zero matches, which is consistent with
  `git diff --check` passing and is not the same as having run it.
- **`R1-readiness-probe-unbounded.sh` is unexecuted and was written blind.** It
  supports a non-blocking register entry, not a blocker; if it fails for a
  fixture reason the F1 finding still stands on the cited source lines, since
  F1's core is a statement about the document that can be checked by reading.
- **I did not re-run or re-derive the six oracle scripts.** I took the
  coordinator's post-cycle-4 results as given, per the brief.
- **I did not verify the cycle-3 N1 sweeps' live outcome**, or any other gate
  result. Whether the two now-falsifiable published-reason sweeps are green over
  a real status and adoption document is still decided by the run, not by me.
- **No shellcheck.** The three new functions (`afk_monitor_bound_unavailable`,
  `afk_monitor_probe_strict`, `afk_declare_bounding_tool`) read clean to me —
  quoting, `local` declarations, no new unassigned variable beyond the
  `SC2034,SC2154` exclusions the libraries already carry — but I could not run
  the linter, and it is not one of this story's gates in any case.
- **Delta scope respected, so:** Story 1.1/1.2 surfaces, the mutation and
  concurrency gates, `lib/afk-plan.sh`, `lib/afk-mutate.sh`, the readiness
  library outside `afk_probe_run` and `afk_probe_orca`, rendered human output,
  and an FR-by-FR trace against the frozen PRD were all left alone. A regression
  the delta sneaks under one of those would not have been seen. I did read
  enough of `lib/afk-commands.sh` and `bin/agent-flow-kit` to establish that a
  monitor pass makes no readiness probe, because P2's completeness depends on
  it.
- **I did not judge packaging.** The ~5,160-line story total and the split
  suggestion are the worker's flag and stand for the coordinator. I note only
  that cycle 4 is the third consecutive cycle whose findings land in the
  dispatch-monitor layer, which is further evidence for splitting that layer out
  rather than against it.

---

## Dev Agent Record (this review session)

The review-only contract forbids modifying any existing file, including the
story file, so this section stands in for a Dev Agent Record entry there; the
coordinator may transcribe it.

- **Session:** fresh reviewer, Read/Glob/Grep/Write, no shell, no Edit.
- **Read:** the review brief; `AFK-PORT-1.3.md` (story, cycle-4 record and both
  residual registries); `AFK-PORT-1.3-FIX2.md`;
  `evidence/AFK-PORT-1.3-POSTFIX-REVIEW.md`;
  `evidence/AFK-PORT-1.3-POSTFIX-REVIEW-attack/P2-orca-observation-unbounded.sh`;
  `lib/afk-monitor.sh` (the wrapper block, the terminal observation, the cleanup
  arm, `afk_monitor_cleanup_record`, `afk_monitor_summarize`,
  `afk_monitor_exit_code`, and a whole-file sweep for external calls);
  `lib/afk-readiness.sh` (`afk_probe_run`, `afk_probe_timeout_seconds`,
  `afk_probe_orca`, `afk_readiness_evaluate`, route readiness, aggregation);
  `lib/afk-commands.sh` (`afk_evaluate_installation`, `afk_cmd_monitor`);
  `lib/afk-common.sh` (`afk_warn`, `afk_have`, `afk_require_tools`);
  `bin/agent-flow-kit` (option boundary, `afk_declare_bounding_tool`, dispatch);
  `docs/LIFECYCLE-CONTRACT.md` (probes, monitor, provenance-bound cleanup, the
  `ABSENT` paragraph, the reason vocabulary, the end-of-document guarantees);
  `tests/lifecycle-dispatch-tests.sh` (helpers, the stub, sections 5, 7, 8, 9
  and the closing sweeps); `tests/run-tests.sh` (the five aggregation blocks and
  the summary); the skip helpers in the other three suites.
- **Written (new files only):** this report and
  `evidence/AFK-PORT-1.3-FINAL-REVIEW-attack/R1-readiness-probe-unbounded.sh`.
- **Gates:** not run — no shell in this session; see §5.
- **Verdict:** CLEAN. 0 blockers, 7 non-blocking entries. P1 COMPLETE, P2
  COMPLETE for the monitor pass, the `timeout` deviation SOUND and to be
  recorded as an accepted deviation from the brief's fallback.
