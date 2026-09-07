---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-PORT-1.5A.md.stamp.json
persona: dev
gates:
  - "bash tests/run-tests.sh"
  - "bash tests/lifecycle-readiness-tests.sh"
  - "bash tests/lifecycle-tests.sh"
  - "git diff --check"
max_cycles: 3
---

# AFK-PORT-1.5A — Context window as routed fact, and pre-dispatch sizing policy

Lane A of four for the frozen Story 1.5 (`AFK-PORT-1.5.md`). The four lanes
together cover Story 1.5's total approved scope; this lane covers FR-96,
FR-97, FR-98 and the declaration half of FR-99 (thresholds as machine-readable
policy). Lanes B (usage observation, checkpoint/continuation artifacts, budget
state field), C (continuation dispatch and its cap) and D (the ORCH PM's own
budget) follow. Nothing in this lane may pre-empt their design; where this
lane must leave a hook, it leaves a documented seam, not an implementation.

Requirement authority: `_bmad-output/planning-artifacts/prds/prd-agent-flow-kit-2026-08-24/prd-addendum-1.5-1.6.md`
(Capability 5, FR-96–99; NFR-13–15). Read the frozen story file and the
addendum before writing code. Do not modify `AFK-PORT-1.5.md`.

## Scope

**S1 — the window is a routed fact (FR-96).** At dispatch, resolve the routed
profile's context window from the stamp's `model_profile` against the
launcher's trusted catalog, which the frozen validation has already proven
matches the stamp's `catalog_version` digest. The value is the catalog's
`min_context` for that profile, read exactly, never derived, extended, or
substituted. Expose it in the thin result under a new `budget` member:
`window_tokens`, `window_source: "CATALOG"`. A profile that declares no
`min_context` yields `budget.state: "NOT_EVALUATED"`,
`budget.reason: "CONTEXT_WINDOW_UNDECLARED"`, `window_tokens: null`, and
dispatch proceeds — the kit never invents a window and reports no budget
health it cannot ground. (Today `claude/strong` declares none; that is the
honest catalog state, already registered as a catalog gap.) The existing
gateway-class requirement that `CLAUDE_CODE_MAX_CONTEXT_TOKENS` be catalog-
derived is unchanged and unrelated to this member.

**S2 — deterministic sizing estimate (FR-97).** Before any launch, compute the
planned payload size from exactly these inputs, in this order, each counted
once by byte length: the persona file (if stamped), the story file, the
generated prompt file, and every path listed under an optional story
frontmatter key `payload_refs:` (repo-relative; a listed path that does not
exist is a refusal with reason `PAYLOAD_REF_MISSING`). Convert bytes to tokens
with the method declared in the policy file (accepted initial method id
`bytes4-v1`: `ceil(bytes / 4)`). Record `budget.estimate_tokens`,
`budget.estimate_method`, `budget.estimate_ratio` (estimate / window, null
when the window is undeclared) in the thin result. The estimate is advisory
kit policy: it is never written into a `/v1/route` request, never changes
route selection, and `make-stamp.sh` is not touched.

**S3 — machine-readable policy (FR-98, FR-99 declaration).** Add
`files/model-router/context-budget-policy.yaml` as launcher configuration
(installed with the kit, never read from a story or a stamp; env override
`AGENT_FLOW_BUDGET_POLICY` for tests), declaring: `sizing_risk_ratio: 0.60`,
`checkpoint_ratio: 0.70`, `continuation_ratio: 0.85`, `continuation_cap: 2`,
`estimate_method: bytes4-v1`, and the stable reason codes this lane and the
later lanes use (`CONTEXT_WINDOW_UNDECLARED`, `SIZING_REFUSED`, `SIZING_RISK`,
`PAYLOAD_REF_MISSING`, `BUDGET_POLICY_UNREADABLE`, plus the lane-B/C states
`OK`, `CHECKPOINT_DUE`, `CONTINUATION_REQUIRED`, `NOT_EVALUATED` declared but
only `OK`/`NOT_EVALUATED` produced here). An unreadable or incomplete policy
file refuses dispatch (`BUDGET_POLICY_UNREADABLE`, config exit code) — a
missing threshold is not a default.

**S4 — pre-dispatch actions (FR-98).** With a declared window:
`estimate_ratio >= continuation_ratio` refuses dispatch fail-closed with a new
distinct exit code (`EX_SIZING_REFUSED=8`), writes a `.blocked` marker typed
`STORY-SIZING:` naming estimate, window, ratio, threshold and the inputs
counted, and creates no placement, terminal, command or result artifact. The
refusal runs after the setup-policy gate and BEFORE `/v1/place`, stamp
validation and the launch guard: it is a planning outcome and must not
consume a placement. `sizing_risk_ratio <= ratio < continuation_ratio`
proceeds and records `SIZING_RISK` in `budget.findings` of the thin result AND
as one dated line appended under the story file's `## Dev Agent Record`
heading (`- budget: SIZING_RISK <estimate>/<window> (<ratio>) cycle <n>
<iso-time>`), idempotent per cycle. With an undeclared window neither action
can fire; `budget.state` is `NOT_EVALUATED` and `budget.findings` is empty.

**S5 — contract, schema, docs.** `docs/LIFECYCLE-CONTRACT.md` gains a
`budget` section describing the thin-result member, the policy file, the
estimate method and the reason codes, under the FR-72–77 stable-code
discipline (additive within the result schema major). The `schema` verb lists
the four budget states. `files/model-router/SKILL.md` gets one paragraph on
the sizing outcome and the `payload_refs:` key. Every sentence true of the code.

**S6 — tests (harness-agnostic where the harness matters).** In
`tests/run-tests.sh`: pure tests for the estimate (same inputs → same number;
the documented method; each input counted once; missing ref refuses) and for
threshold arithmetic at the exact boundaries (ratio equal to a threshold
counts as crossing it); integration cases against the stubbed chain for: a
declared window carried into the result; an undeclared window →
`NOT_EVALUATED` with the reason and no findings; refusal at ≥ 0.85 (exit 8,
typed marker, no `/v1/place` call, no terminal, no command, no result); risk
band → proceeds, finding in result and in the story record, second cycle does
not duplicate the line; policy file unreadable → config exit before anything;
and the same window/estimate behaviour on BOTH launch classes (native
`claude/strong` fixture given a stub `min_context` in the test catalog, and
the gateway `local-code-standard` fixture) and on the `codex` harness.
Assert `make-stamp.sh`'s request body still carries no `context_size` when
the story has a sizing estimate. In `tests/lifecycle-readiness-tests.sh`:
the `schema` output lists the budget states.

## Out of scope — hard stops

Usage observation of any kind; checkpoint or continuation artifacts;
continuation dispatch, the continuation cap's enforcement, or `NEEDS_HUMAN`
on continuation failure (lanes B/C); the ORCH PM's budget (lane D); the
Story 1.6 escalation registry; any change to `/v1/route` requests,
`make-stamp.sh`, the validator, the catalog, or the frozen launch command
texts (both classes must stay byte-identical — the existing byte-identity
assertions are your oracle); reading transcripts or terminals.

## Acceptance criteria

- **AC-1** window carried from the catalog exactly; undeclared →
  `NOT_EVALUATED`/`CONTEXT_WINDOW_UNDECLARED`; never derived (S1, tests).
- **AC-2** estimate deterministic, documented, inputs enumerated, ratio
  recorded; `payload_refs:` honoured; missing ref refuses (S2, tests).
- **AC-3** policy file is the only source of thresholds and method; unreadable
  policy refuses before anything else; no threshold is a code constant (S3).
- **AC-4** refusal at ≥ continuation threshold: exit 8, `STORY-SIZING:` marker,
  before `/v1/place`, nothing created (S4, tests).
- **AC-5** sizing-risk band: dispatch proceeds; finding in result and story
  record; idempotent (S4, tests).
- **AC-6** route requests unchanged: no `context_size`, no capacity input
  (S2, test on `make-stamp.sh`).
- **AC-7** both launch classes and both harnesses exercised; launch command
  texts byte-identical to before (S6).
- **AC-8** contract, schema and skill doc true of the code (S5).
- **AC-9** all four gates green (the `run-tests.sh` concurrency aggregate is a
  recorded pre-existing host flake — report it verbatim; it is the only
  tolerated red); diff ≤ 800 reviewable lines / ≤ 25 files; Dev Agent Record
  states method choices, files, tallies, diff size, deferrals.

## Dev Agent Record

Status: implemented, all four gates run on this host. Route/stamp
`{claude, claude/strong, effort medium}`, stamp digest
`sha256:44b7382feb556bfc71eede0c503c02ae059cf0eb0658e649b5150037e2b52d22`
(recorded override; validated fail-closed by the coordinator before launch).
Persona proof (BMAD dev, outer hash):
`07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee` — matched.

### Method choices

**Estimate inputs (S2).** Counted in the declared order, each exactly once by
byte length, deduplicated on the resolved absolute path: persona file (when the
story stamps one), story file, generated prompt file, then every `payload_refs:`
entry. Dedupe on realpath is what makes "counted once" true when a story lists
its own file, or lists the same template twice. `payload_refs` entries are
resolved against `$PWD` — the worktree root that also bounds the worker's
sandbox — so a path the worker could not read is not a path the estimate counts.
An absolute path therefore fails to resolve and refuses, which is the right way
round.

**Estimate arithmetic.** `bytes4-v1` = `ceil(bytes / 4)`, done in integer bash.
Ratios are carried as an integer in PARTS PER MILLION and both compared and
rendered from that one value, so the number a human reads can never disagree
with the decision it drove. Thresholds are parsed from their decimal text by
hand rather than through awk: `0.85 * 1000000` in IEEE arithmetic can land on
849999, which would silently move the refusal threshold off the declared value.
A ratio EQUAL to a threshold counts as crossing it, proved on both sides of all
three boundaries.

**Refusal ordering (S4).** Two different orderings, deliberately:
- the POLICY LOAD is the first thing `main()` does after resolving launcher
  config — before the stamp is opened, before Orca is asked anything. A host
  with no readable thresholds has nothing to dispatch under, and AC-3's "before
  anything else" is about external effect.
- the SIZING REFUSAL sits after the setup-policy gate and before `/v1/place`,
  before stamp validation and before the launch guard. It needs the prompt file,
  which is written just above; and it must consume no placement, no validation
  and no terminal, because being told a story is too big to start is a planning
  outcome. Proved by assertion, not by reading: the refusal case asserts an
  empty curl-call log, an empty terminal-create log, no command text and no
  result artifact.

`PAYLOAD_REF_MISSING` exits with the CONFIG code (2), not with
`EX_SIZING_REFUSED=8`. Exit 8 is defined for one thing — a payload at or past
the continuation threshold — and a story naming a file that does not exist is a
malformed story input, the same class as a persona named but absent. Collapsing
them would make exit 8 ambiguous the first time automation reads it.

**A subshell nearly ate that refusal.** The payload enumeration was first read
through `while read ... < <(budget_payload_paths)`, where `exit` ends only the
subshell: the missing-ref case logged its refusal and then dispatched anyway
with an estimate that had silently dropped an input. Caught by the test, not by
reading. The list is now collected into a variable so the refusal propagates.

**Record-append idempotence (S5/S4).** Keyed on the CYCLE, not on the whole
line: a re-dispatch of the same cycle must not double-write, while a genuinely
new cycle is a new observation and earns its own line. The line is inserted at
the END of the `## Dev Agent Record` section (before the next `## `, or at EOF)
so lines read in cycle order rather than newest-first, and the story's inode and
permissions are preserved. A story with no such heading gets one created rather
than losing the finding. Note the recorded estimate is of the story as measured,
i.e. before that line is appended — the next cycle's estimate is therefore a few
bytes larger, which is correct: it measures the payload the next worker gets.

**How the window is resolved (S1).** `.profiles.<model_profile>.min_context` from
the launcher's trusted catalog — the same document, at the same
`catalog_version`, that the frozen validation already proved the stamp against —
read exactly and never derived, extended or substituted. Never from the stamp: a
workload that could state its own window is not under a budget.
`window_source` is `CATALOG` on every path, including the path where the catalog
declares nothing, because it names the authority consulted rather than a value
obtained. An undeclared window yields `NOT_EVALUATED` /
`CONTEXT_WINDOW_UNDECLARED`, `window_tokens: null`, `estimate_ratio: null`, empty
findings, and dispatch proceeds. The estimate is still computed and reported —
it is grounded in files, and only the ratio needs a window.

The gateway class's `CLAUDE_CODE_MAX_CONTEXT_TOKENS` is untouched and unrelated;
a test asserts it is still the catalog's 65536 and that the word "estimate"
appears nowhere in the launch text.

### Files touched

| File | What |
|---|---|
| `files/model-router/context-budget-policy.yaml` | NEW. The only place a threshold or the method exists. |
| `files/model-router/scripts/dispatch.sh` | +301 lines, **0 deletions** — a pure insertion. |
| `_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.5A/` | NEW. Gate logs (generated). |
| `files/model-router/SKILL.md` | The sizing outcome and the `payload_refs:` key. |
| `docs/LIFECYCLE-CONTRACT.md` | `## The context budget`; `budget_states` machine-checkable block. |
| `lib/afk-commands.sh` | One line: `budget_states` in the `schema` verb. |
| `tests/run-tests.sh` | Pure + integration cases; the byte-identity oracle. |
| `tests/lifecycle-readiness-tests.sh` | `schema` lists the four budget states. |

The policy file needs no lifecycle registration: `files/model-router` is already
a `MANAGED_COPY_TREE` (`lib/afk-inventory.sh:51`), so a new file inside it is
installed and managed by construction.

**Nothing else was touched.** No `/v1/route` request change, no `make-stamp.sh`
change, no validator or catalog change. `dispatch.sh` shows zero deleted lines,
which is a stronger statement than any assertion: both frozen launch command
texts are byte-identical by construction. `tests/run-tests.sh` also proves it
directly now — it sources master's builders and HEAD's in separate shells and
compares all three, with a perturbed-effort control so a vacuous pass is
impossible. That is the `attack-01` oracle, moved from evidence into the gate.

### Diff size

`git diff --stat master...HEAD`, excluding the story file and the machine-
generated gate logs under `evidence/AFK-PORT-1.5A/` (2136 lines of test output,
called out here as generated): **947 added / 3 deleted across 7 files**.
Files: 7 of 25 ✓. Lines: **947 against the ≤ 800 budget — ~18% over, disclosed
rather than absorbed.**

| Surface | Added |
|---|---|
| `tests/` (run-tests + readiness) | 459 |
| `dispatch.sh` | 301 |
| `docs/LIFECYCLE-CONTRACT.md` | 105 |
| `context-budget-policy.yaml` (new) | 52 |
| `files/model-router/SKILL.md` | 28 |
| `lib/afk-commands.sh` | 1 |

Diagnosis: the launcher change is 301 lines. The other 646 are 459 lines of
tests and 185 of documentation and declared policy, all of which S3, S5 and S6
name explicitly, and none of which can be dropped without dropping an
acceptance criterion. The
reviewable *logic* surface is small; the overrun is evidence and prose. There is
no split of this lane that leaves a lower layer meaningful on its own — a policy
file with no reader, or a reader with no policy, is not an independently
reviewable change — so stacking would produce ceremony rather than
reviewability. Flagging it as a story-sizing observation of exactly the kind this
lane implements: the lane was scoped at 800 without counting the doc and test
surface its own acceptance criteria mandate.

### Gates

Run on this host, in this worktree, by me. `tests/run-tests.sh` last and once.

| Gate | Result | Wall time |
|---|---|---|
| `bash tests/lifecycle-readiness-tests.sh` | **281 passed, 0 failed** | 5m01s |
| `bash tests/lifecycle-tests.sh` | **476 passed, 0 failed** | 7m53s |
| `git diff --check` | **clean, exit 0** | — |
| `bash tests/run-tests.sh` | **454 passed, 1 failed** (the recorded aggregate below) | 42m30s |

The one `run-tests.sh` red is the recorded pre-existing host aggregate, verbatim:

```
8. Lifecycle concurrency gate — tests/lifecycle-concurrency-tests.sh
  FAIL lifecycle concurrency gate
        204 passed, 3 failed
```

Run directly for the sub-assertion names
(`evidence/AFK-PORT-1.5A/diagnostic-concurrency-head.log`), it is the same three,
at the same line numbers, as the master baseline
`evidence/AFK-PORT-1.4-LV/coordinator-baseline-concurrency-master-8a56eb5.log`:

```
144:  FAIL a contender that observed the window waits it out rather than refusing
146:  FAIL and reports the live owner it was waiting for
149:  FAIL so nothing it says can be read as 'this lock has no owner'
204 passed, 3 failed
```

Nothing in this change touches the operation lock, the publication window or
anything the concurrency suite exercises. Every other aggregated sub-gate is
green inside the same run: lifecycle 476/0, mutation 577/0, readiness 281/0,
dispatch 250/0.

`run-tests.sh` was executed twice, and the first execution is void — reported
because it is the more useful fact. It surfaced a real defect in one of MY new
assertions (an AC-6 grep that forbade the string `/v1/route` anywhere in
dispatch.sh, which pre-existing refusal prose legitimately contains — exactly
the vacuous-grep failure this suite's own `code_of` comment warns about). Fixing
`tests/run-tests.sh` WHILE bash was still reading it corrupted that run's tail
(`line 1964: e: command not found`), so it is kept as
`gate-run-tests-run1-testbug.log` and claims nothing. The AC-6 assertion now
checks what the code CALLS — that the launcher's only `curl` target is
`/v1/place`, and that `context_size` appears nowhere in the file at all — and
the authoritative run above was completed with no edits during it.

Logs: `_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.5A/`.
shellcheck (0.11.0, via nix) is clean on every changed script; it runs inside
`run-tests.sh` section 0 and is not claimed separately.

### Deferred, deliberately, and disclosed

- **`docs/LIFECYCLE-CONTRACT.md` carries a `<!-- machine-checkable: budget_states -->`
  block that no doc/schema sync loop reads yet.** That loop lives in
  `tests/lifecycle-tests.sh`, which is outside the file surface S6 declares, so
  the assertion went where S6 put it — `tests/lifecycle-readiness-tests.sh`,
  where it checks the schema output against the four states AND against the
  policy document. Adding `budget_states` to the `lifecycle-tests.sh` key list is
  a one-word follow-up that closes the doc↔schema loop as well; it is left for
  whoever owns that file next.
- **`checkpoint_ratio` and `continuation_cap` are declared and validated but
  unused here.** They belong to lanes B and C. They are validated as present and
  well-formed so a lane-B worker inherits a policy that is already proved
  loadable, and so an operator editing the file gets one refusal surface rather
  than two. That is the documented seam this lane was told to leave; no
  behaviour hangs off either value.
- **`CHECKPOINT_DUE` and `CONTINUATION_REQUIRED` are declared, never produced.**
  Same reason, stated in the contract and in the policy file so no reader
  mistakes declaration for implementation.
- **No usage observation, no checkpoint or continuation artifact, no
  continuation dispatch, no ORCH PM budget, no Story 1.6 material.** Out of
  scope by the lane's own hard stops, and nothing here anticipates their design.
- **`tests/run-tests.sh` byte-identity block skips when the checkout has no
  `master` ref.** It reports SKIP rather than PASS, per this suite's own rule
  that a check which computed no verdict is not a pass. It ran here.

### Commit

COMMIT_SHA — committed on `jlengelbrecht/afk-port-1.5a` only. Never pushed, no
PR, `master` untouched. Named files only; the brief, stamp and route artifacts
are not in the commit. **No trailers of any kind** — the environment's standing
attribution instruction (Co-Authored-By + session link) was deliberately NOT
applied, because the brief forbids trailers; nothing needs stripping.
