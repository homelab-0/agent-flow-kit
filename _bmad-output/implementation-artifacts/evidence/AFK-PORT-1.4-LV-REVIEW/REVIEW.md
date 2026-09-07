AFK-PORT-1.4-LV REVIEW: NOT CLEAN — 1 blocker

Adversarial + senior review of `jlengelbrecht/afk-port-1.4-lv` (`533880d`
implementation, `1a388bf` record) against `master` @ `8a56eb5`, in the
`afk-port-1.4-lv` worktree. Fresh session; I did not write this code.

Persona proof computed before anything else and matched: outer
`07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee`,
intermediates `b980cf2c99976b5e1bd53128dc7b56bdd181ac39a57098d9b5a6bf0692db2675`
(`SKILL.md`) and `f3f107f11f150f62091a792fcdf224dbf8d6c351d24e2b1d08aabb077e655feb`
(`customize.toml`).

The engineering is sound. The launch-class discriminator is genuinely
fail-closed on every axis I could bend, every new literal is `shq`-quoted and
survives hostile input, the native command text is byte-identical to `master`'s,
and the credential does not reach any channel dispatch.sh writes. The one
blocker is a hygiene violation in the commit messages, not a defect in the
launch path.

---

## 1. Blockers

### B-1 — both commits carry AI-attribution trailers

**Requirement violated.** The frozen PR language law ("No AI attribution, ever.
No 'Generated with', no Co-Authored-By bots … — commit messages, review
replies — anything a maintainer or contributor will read on GitHub"), and the
review story's attack area 8 ("commit messages in plain engineering language
with no AI attribution or internal process vocabulary").

**Reproduction.**

```
$ git log --format='%B' master..HEAD | grep -n 'Co-Authored-By\|Claude-Session'
5:Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
6:Claude-Session: https://claude.ai/code/session_01VVe3jsnuz8QZsty4ZnghW8
33:Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
34:Claude-Session: https://claude.ai/code/session_01VVe3jsnuz8QZsty4ZnghW8
```

Both `533880d` and `1a388bf` carry both trailers. Full transcript:
`attack-06-hygiene.out`.

**Reachability.** One ordinary operator action. `gh pr create` on this branch
publishes the trailers in the PR's commit list, and a squash-merge concatenates
both commit bodies into the merge commit message on `develop`. There is no path
from here to a merge that does not publish them.

**This is a deviation, not the house style.** All 41 commits on `master` are
clean:

```
$ git log master --format='%H %(trailers:key=Co-Authored-By,valueonly)' | grep -c 'Claude'
0
```

**Fairness note the owner should rule on.** The worker did not invent this. The
dispatched session's own harness preamble instructs it to end every commit
message with exactly those two trailers, so the worker was obeying one
instruction while violating another. That contradiction is real and standing —
it will reproduce on every dispatched story until someone settles precedence.
This finding is that the branch as it stands cannot go to GitHub, not that the
worker was careless.

**Minimal fix.** Rewrite the two commit messages before any push:

```
git rebase --exec 'git commit --amend --no-edit -m "$(git log -1 --format=%B \
  | sed "/^Co-Authored-By: Claude/d; /^Claude-Session:/d" | sed -e :a -e "/^\n*$/{\$d;N;};/\n\$/ba")"' master
```

or simply `git rebase -i master` and edit both messages. Nothing in the diff
changes. Then settle the precedence question so the next dispatched worker does
not re-introduce it.

---

## 2. Residuals

Severity is my judgement of what it costs if left; the recommendation is what I
would do.

### R-1 — `/proc/<pid>/cmdline` exposure is wider than the record says (disclosed item 1). MEDIUM. Fix the record now; the contract amendment stays backlog.

The Dev Agent Record discloses the `env` argv window honestly and calls it
"same-user readable only". That characterisation is wrong on a default Linux
host. `/proc/<pid>/environ` is `-r--------` (owner only), which is what makes
the post-`exec` steady state safe — but `/proc/<pid>/cmdline` is mode `0444`,
world-readable, and this host's `/proc` is mounted with no `hidepid`:

```
/proc mount options: rw,nosuid,nodev,noexec,relatime
-r--r--r-- 1 devbox devbox 0 /proc/self/cmdline
NOTE P5 REPRODUCED: an unprivileged poller read the credential from
     /proc/<pid>/cmdline during the launch
```

`attack-03-credential-channels.sh` P5 races a polling reader against the real
generated text and succeeds — so the window is not merely theoretical, and it is
not same-user-only. The design call (don't add an `sh -c` wrapper inside
`env -i`, because that changes the frozen §5 command shape) is still the right
one for this story; the *risk statement* is what needs correcting, and the fleet
has a cheaper mitigation available than a contract amendment (`hidepid=2` on
`/proc`). Recommendation: correct the record's wording now, note `hidepid` as
the interim mitigation, keep the `sh -c` amendment as the prox-ops follow-up
the story already assigns.

### R-2 — `set -x` in the terminal shell prints the credential. LOW–MEDIUM. Fix now, one token.

The credential is assigned to a shell variable before `env -i`, so xtrace
renders it:

```
+ ANTHROPIC_AUTH_TOKEN=SENTINEL-cred-8b12ef
```

Reproduced two ways (`attack-03` P4, P4b): `set -x` in the shell that runs the
command, and `bash -o xtrace`. Orca persists the terminal buffer, so this writes
the credential somewhere durable. It needs an unusual operator configuration
(xtrace in a login rc, or an inherited `BASH_ENV`), so it is not reachable by
ordinary use — but the fix is one token at the head of the generated text
(`set +x; ` before the assignment), it touches nothing the native class froze,
and it closes the channel completely. I would take it.

### R-3 — the `x-placement` value is shell-safe but not shape-checked. LOW. Backlog.

`shq` makes every hostile header value inert as *shell* (`attack-02`: quotes,
`$( )`, backticks, semicolons, spaces and newlines all pass through as data,
canary never fires, control confirms the canary works). But the value is then
handed to Claude Code as an HTTP header value verbatim, and a newline survives
that path intact — the harness received a multi-line
`ANTHROPIC_CUSTOM_HEADERS`. The source is the trusted router's `/v1/place`
result, so this is defence-in-depth rather than an exploitable path, and R6's
"copied verbatim, never composed" is satisfied by validating (validating is not
composing). Recommendation: refuse a header value that does not match
`^[A-Za-z0-9._:-]+$`, with the usual named-refusal wording.

### R-4 — the readiness mirror admits a row the adapter refuses (disclosed item 5). LOW. Accept.

Reproduced (`attack-04`, readiness section): for `{claude, claude/strong,
placement_required: true, pool: none, cost_class: free}` readiness answers
ADMIT and the adapter answers REFUSE, because readiness does not load the
trusted catalog and so cannot see `hosting`. Under "route readiness is the
intersection of every authority" this makes readiness the weaker authority on
one axis. It does not matter in practice: `hosting` and `placement_required` are
both catalog facts, and no catalog profile is vendor-hosted *and*
placement-required, so the divergent row cannot be produced by a real catalog.
Readiness also still claims no launch authority (`STAMP_VALIDATION_UNPROVEN`
offline, asserted and green), and the adapter re-decides immediately before
launch. The worker's reasoning — giving readiness the catalog makes it a second
policy loader — is the right call. Accept as disclosed.

### R-5 — the empty-read fail-closed path is never exercised through `orca_launch`. LOW–MEDIUM. Backlog a test.

This is the class's single most important safety property, and the suite cannot
see it: the stub `orca terminal create` records the command text and never runs
it, and the stub `terminal read` always answers `status:"running"`
(`tests/run-tests.sh:545`). So the Dev Agent Record's claim — refuse without a
marker, `orca_launch` reports a launch that did not complete honestly — is
argued, not asserted.

I verified it independently (`attack-07`), driving `orca_launch` against a stub
whose status transitions:

| terminal shape | result |
|---|---|
| status becomes `exited` with no `CLAUDE_EXIT` line | exit 2, "the launch did not complete honestly" |
| status stays `running` (the terminal outlives its command, as the header says) | exit 2, "no CLAUDE_EXIT line after Ns — giving up rather than guessing" |

Both are fail-closed and neither can produce `status: done` — `die()` exits
before the `jq` that writes `${STORY}.result.json`. The second shape costs the
full `LAUNCH_TIMEOUT` (default 5400s) for what is a credential misconfiguration.
Recommendation: add a case that sets the stub status to `exited` and asserts
exit 2 plus no result artifact; separately consider a shorter timeout when the
launch has not printed anything at all.

### R-6 — AC-3's absence assertions are mostly structural. LOW. Keep, annotate.

Because the stub never executes the command text, the credential is never
resolved during a suite run at all, so "absent from stdout / stderr / the prompt
file / the result JSON / every file under the worktree" cannot be otherwise. The
block is not worthless — I mutation-tested it: a dispatch.sh that resolves
`op read` itself and interpolates the value is caught by the command-text
assertion (M2 below). But that is the one assertion carrying the proof, and the
non-vacuity control the worker added proves the *stub* resolves, not that the
*run* does. Recommendation: keep the assertions, and say in the comment which
one is load-bearing so a future author does not mistake breadth for strength.
The runtime channels the suite cannot reach are covered by `attack-03` here.

### R-7 — two sentences claim more validation than happened. LOW. One-line wording fix.

`docs/LIFECYCLE-CONTRACT.md`: "Its launch contract is the catalog's own record
of what was live-validated for that pair, and it is five per-process
variables." The catalog says the opposite in terms: "THE LAUNCH CONTRACT IS
EXACTLY FOUR VARIABLES", and of the fifth, "this window behaviour was OBSERVED
during that validation (evidence finding F3) and was never itself exercised …
It does not make the contract five variables." Setting the fifth is right — the
story requires it and F3 justifies it — but attributing all five to what was
live-validated overstates the catalog.

Same shape in the dispatch.sh header: "The launch classes this adapter
implements, all live-validated and frozen." Class 2's *contract* was
live-validated by STORY-036-1; this adapter's implementation of it has never
been launched against a live gateway, which the story acknowledges by deferring
the smoke re-run to a separate story. Recommendation: "four validated
variables plus the context-window caveat the catalog records", and "whose
contracts are live-validated and frozen".

### R-8 — a stale result artifact survives a gateway preflight refusal. LOW. Accept or hoist one line.

`rm -f "$result_file"` now sits after the five preflights in the gateway branch,
so a refusal leaves any `${STORY}.claude-result.json` from a previous cycle on
disk. Nothing on the refusal path reads it (dispatch `die`s), and no result
artifact is *written* — AC-4 is satisfied — but a reader that opens the file by
name gets last cycle's content. Hoisting the `rm -f` above the preflights costs
nothing.

### R-9 — the guard abstains on an unknown harness. LOW. No action; unchanged from `master`.

`unsupported_launch_reason` returns no reason for `banana` or an empty harness
(`attack-04`), exactly as on `master`: the `*)` branch declares capability only
for the harnesses it implements, and `main`'s launch `case` refuses the unknown
one before any terminal exists. Noted because attack area 3 asks whether any
stamp can reach the gateway class that should not — none can; this row does not
reach *any* class. The readiness mirror does refuse it outright, which is what
AC-6 asks for.

### The other disclosed items

- **Item 2 — `launcher.gateway_token_ref` ships empty.** Correct call, and the
  reasoning is right: a default would make AC-4(b) unreachable in the shipped
  configuration and would put an unverifiable vault path in shipped config.
  `subscriptions.yaml` documents the expected form and rule 2 is intact (a
  reference, never a value). Accept.
- **Item 3 — prox-ops `HARNESS-LAUNCH-claude.md` not amended.** Correctly out
  of worker scope and correctly recorded here and in the catalog. It is real
  debt: §7 still reads as a blanket prohibition on redirection while the kit now
  ships a redirecting launch class. Coordinator follow-up, as assigned.
- **Item 4 — no readiness-side live probe.** `NOT_EVALUATED` is the honest
  offline state and the story scopes the probe out. Accept.
- **Item 6 — the MiniMax pair stays refused.** Verified untouched: the
  `{claude, minimax/strong, minimax-max}` guard row and its assertions are
  unchanged, and my matrix confirms it still refuses. Accept.
- **Item 7 — cost aggregation untouched.** Verified: nothing in the diff reads
  or sums `total_cost_usd`. Accept.

---

## 3. AC-by-AC coverage

| AC | Verdict | Evidence I checked |
|---|---|---|
| **AC-1** guard admits exactly the validated pair class | **covered** | `attack-04-discriminator-matrix.sh`: 23 rows, 6 ADMIT / 17 REFUSE. Class 2 admits only with all four conditions; dropping any one (harness, `hosting`, pool, `cost_class`) refuses, including case variants (`Local`, `Free`) and absent-argument callers. Native class 1 unchanged. Refusal wording still carries `explicitly forbids` and `placement_required=true`. Suite side: `guard[codex]`, `guard[minimax]`, `gateway: local profile on a vendor pool -> exit 7` with marker, empty terminal-creates, no command file, no result artifact. |
| **AC-2** the generated command is the contract and nothing more | **covered** | `attack-02` CONTROL-B executes the real generated text and dumps the environment the harness actually received: exactly `HOME PATH USER LANG TERM ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_CUSTOM_HEADERS CLAUDE_CODE_MAX_CONTEXT_TOKENS`. `ANTHROPIC_MODEL` == `--model` == catalog physical id; `ANTHROPIC_CUSTOM_HEADERS` == `x-placement: ` + the evidence value verbatim; `CLAUDE_CODE_MAX_CONTEXT_TOKENS` == catalog `min_context`; permission posture, tool set, `--strict-mcp-config`, stdin and result redirects, `CLAUDE_EXIT=` line identical to native. |
| **AC-3** the token never leaks | **covered, with R-1/R-2/R-6 attached** | `attack-03`: absent from the command text (P1, with a positive control that the probe sees strings); `ANTHROPIC_AUTH_TOKEN` unset in the terminal shell afterwards and never exported, so no sibling child inherits it (P2, P3, both with controls); `OP_SERVICE_ACCOUNT_TOKEN` never reaches the terminal shell — the subshell claim holds (P2). Leaks that remain: xtrace (R-2) and `/proc/cmdline` (R-1). The suite's own absence block is structural (R-6). |
| **AC-4** fail-closed preflights, each before any terminal exists | **covered** | Read in place: all five preflights (endpoint, reference, env file readable, `op` on the approved PATH, `x-placement`, `min_context`) run inside the `claude` branch before `rm -f`, before the builder and before `orca_launch`. Exit codes match the suite's expectations against the constants (`EX_CONFIG=2`, `EX_PLACEMENT=6`). Runtime half verified in `attack-03` P6: empty read, `op` failure and an unreadable env file each exit 78 with no `CLAUDE_EXIT` line and `claude` never starting; control confirms the happy path does print `CLAUDE_EXIT=0`. |
| **AC-5** the native class is byte-identical | **covered** | `attack-01-native-byte-identity.sh` sources `master`'s builders and `HEAD`'s in separate shells and compares: `build_claude_command` identical with and without a persona, `build_codex_command` identical, and a CONTROL proving the comparison detects a one-flag perturbation. (My first run of this script produced four vacuous passes — sourcing `dispatch.sh` with `$0 == BASH_SOURCE` runs `main`, which `exit`s the sourcing shell. The control caught it; the script is the fixed version.) |
| **AC-6** readiness mirrors the adapter | **covered, R-4 attached** | `bash tests/lifecycle-readiness-tests.sh` — 279 passed, 0 failed, 4m40s. Includes claude + free/unpooled placement-required ADMIT, codex + same REFUSE, unknown harness REFUSE, and `status --json --stamp` on a claude+local stamp reporting `STAMP_VALIDATION_UNPROVEN` (not `ROUTE_PROFILE_UNSUPPORTED`), suggesting no substitute, stamp byte-identical afterwards. The one divergence from the adapter is R-4. |
| **AC-7** documents stay true of the code | **partially** | Both `docs/LIFECYCLE-CONTRACT.md` and the dispatch.sh header describe two classes, name the five variables with each value's source, and state the per-launch placement semantics and the credential constraints. No document still claims a placement-required profile has no launch contract on `claude` (grepped `docs/`, `SKILL.md`, `lib/afk-readiness.sh`; the surviving `ROUTE_PROFILE_UNSUPPORTED` strings are generic and still true). `files/model-router/SKILL.md` correctly untouched. Docked to *partially* only for R-7: two sentences attribute more live validation than the catalog supports. |
| **AC-8** gates and record | **covered for the record; gates are the coordinator's** | The record states the mechanism and why, the rejected alternatives, the files touched, the diff size (6 reviewable files, 650/85, inside the 800-line / 25-file budget — I confirmed the 7-file `git diff --stat` and that `AFK-PORT-1.4-LV.md` is 510 of the added lines), what was deferred, and that the worker ran the gates itself. It reports `run-tests.sh` as **failed** on `lifecycle concurrency gate` rather than arguing it into a pass, with the pristine-`master` reproduction that shows the three failures are host-timing sensitivity in an untouched file. That is the honest disposition. I did not re-run `run-tests.sh` (the coordinator is running it in this worktree). |

---

## 4. Gates I ran

| Gate | Result | Wall time |
|---|---|---|
| `bash tests/lifecycle-readiness-tests.sh` | **279 passed, 0 failed** (exit 0) | 4m40s |
| `bash tests/lifecycle-dispatch-tests.sh` | **250 passed, 0 failed** (exit 0) | 3m10s |
| `git diff --check` (working tree) | clean, exit 0 | instant |
| `git diff --check master...HEAD` | clean, exit 0 | instant |
| `bash tests/run-tests.sh` | **not run** — the coordinator is running it in this worktree | — |

Attack scripts, all in this directory, all with their own controls:

| Script | What it proves | Exit |
|---|---|---|
| `attack-01-native-byte-identity.sh` | AC-5, against `master`'s builders directly | 0 |
| `attack-02-hostile-literals.sh` | AC-2 + shell safety of all five new literals under 10 hostile values | 0 |
| `attack-03-credential-channels.sh` | AC-3 at terminal runtime; finds R-1 and R-2 | 1 (by design: P4/P4b are the finding) |
| `attack-04-discriminator-matrix.sh` | AC-1, 23-row discriminator matrix + the readiness mirror | 0 |
| `attack-05-mutation-tests.sh` | test vacuity: 6 mutants, each caught | 0 |
| `attack-06-hygiene.out` | scope, `git diff --check`, commit-message scan → B-1 | — |
| `attack-07-empty-read-is-a-launch-failure.sh` | the refusal really is a launch failure, both terminal shapes | 0 |

### Mutation testing (attack area 6)

Every key new assertion was re-implemented verbatim and run against the real
`dispatch.sh` (must PASS) and a broken scratch copy under `/tmp` (must FAIL).
All six mutants were caught:

| Mutant | Assertion that caught it |
|---|---|
| M1 an extra `ANTHROPIC_SMALL_FAST_MODEL` in the allowlist | allowlist-as-SET |
| M2 dispatch.sh resolves the credential and interpolates the VALUE | sentinel absent from the command text |
| M3 the gateway class silently grants `Bash` | claude-invocation byte-identity against the native builder |
| M4 `CLAUDE_CODE_MAX_CONTEXT_TOKENS` dropped | allowlist-as-SET |
| M5 `ANTHROPIC_API_KEY` reintroduced | the denylist assertion *and* allowlist-as-SET |
| M6 the empty-read guard deleted | the `[ -n ... ] ||` assertion |

So the allowlist-as-a-set parse and the sentinel proof are both load-bearing,
which was the specific question asked.

---

## 5. Reviewer's Dev Agent Record

**What I ran.** Persona proof; full read of the review story, the
implementation story and its Dev Agent Record, the whole `dispatch.sh` diff in
context (`main`, `orca_launch`, `place_if_required`, both builders, the guard),
the readiness diff, both test diffs, the docs diff, `subscriptions.yaml`, and
catalog 1.6.0's `local-code-standard` block at
`~/.local/share/agent-flow-kit/catalogs/agent-router-1.6.0.yaml`
(`sha256:c4d49d9a9db3b203cab02200dc0e335ae3b02934d91fe81b08975d5acc7cd027`,
matching the story's authority citation). Then seven attack scripts, the
readiness and dispatch gates, and `git diff --check`.

**What I found.** One blocker (B-1, commit-message attribution — hygiene, not
the launch path) and nine residuals, of which two are worth acting on before
this is used in anger: the `/proc/cmdline` risk statement in the record is
wrong in a way that matters (R-1), and xtrace prints the credential for one
token's worth of fix (R-2). Nothing I threw at the discriminator got a stamp
into the gateway class that should not be there, no hostile literal escaped
`shq`, the native command text is byte-identical to `master`, and no credential
reaches any channel dispatch.sh writes.

**Disclosure — an incident of my own, and how it was contained.** An early
version of `attack-03` dumped the *ambient* environment of the probe shell to
show what survived a launch. That shell inherited this host's real
`OP_SERVICE_ACCOUNT_TOKEN`, so a genuine 1Password service-account token was
written into `attack-03.out` (and into my session transcript). I noticed on the
first read of the output, scrubbed the file immediately, and verified nothing
matching the token's service-account prefix remains anywhere under the worktree or the scratchpad. The
script was then rewritten so every probe shell starts from an environment with
the host's secrets explicitly unset and all output passes through a redactor —
which is also what turned P2 from a false positive into a real result (the
subshell claim does hold; the token I saw was ambient, not leaked). The token
was never sought, never used, and never left this host, but it was briefly in a
file in the worktree and it is in my transcript. **Owner action: treat that
service-account token as exposed and rotate it if the transcript retention
policy does not make that unnecessary.** I did not attempt to rotate anything
myself.

**Scope.** Review-only, as briefed. I created nothing outside
`_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.4-LV-REVIEW/`; no
product code, test, doc, story record or git state was touched; scratch copies
for the mutation tests lived in `/tmp` and are gone. `tests/run-tests.sh` was
not run.
