---
linear:
stamp: AFK-PORT-1.4-LV.md.stamp.json
persona: dev
gates:
  - "bash tests/run-tests.sh"
  - "bash tests/lifecycle-readiness-tests.sh"
  - "bash tests/lifecycle-dispatch-tests.sh"
  - "bash tests/lifecycle-tests.sh"
  - "git diff --check"
max_cycles: 3
---

# AFK-PORT-1.4-LV — Gateway launch variant for local profiles on the `claude` harness

Story 1.4's frozen verdict is `AGENT-FLOW-KIT PORTABILITY BLOCKED` on exactly
one clause: the natural standard-band route `{claude, local-code-standard}` is
valid, routable and stamp-validatable, but the kit's launch adapter has no
validated way to start it, so PR #25's guard refuses it. This story gives the
adapter that validated way. When it merges, a natural-route smoke re-run (a
separate `qa` story, not this one) upgrades the verdict to GREEN.

Authorized by the verdict's own upgrade clause and Josh's go (2026-09-06).
Home: local (`_bmad-output/`); no Linear artifact.

## Authority for the launch path (read these; do not invent)

1. **Catalog 1.6.0, profile `local-code-standard`, field `notes`** — installed
   and digest-verified at
   `~/.local/share/agent-flow-kit/catalogs/agent-router-1.6.0.yaml`
   (`sha256:c4d49d9a…`, matching live `/v1/status`). That prose IS the validated
   launch contract for this pair (STORY-036-1 evidence, R1–R17). Read it in
   full before touching code. The same file's `minimax/strong.notes` shows the
   sibling shape.
2. The kit's existing frozen native launch in
   `files/model-router/scripts/dispatch.sh` (`build_claude_command`,
   `unsupported_launch_reason`, `resolve_approved_home`,
   `claude_settings_preflight`, `place_if_required`, `main`). The variant is a
   SECOND launch class beside it; the native class must not change by a byte.
3. `docs/LIFECYCLE-CONTRACT.md` ("This kit's launch contract covers …") and
   `lib/afk-readiness.sh` `afk_launch_contract_reason` — the kit's own
   declaration of what it can launch, mirrored in readiness.

The prox-ops document `contracts/agent-router/HARNESS-LAUNCH-claude.md`
(frozen 2026-08-23 for `{claude, claude/strong}` only) is NOT in this repo and
is NOT amended by this story. Its §7 allowlist sanitizer, §5 command shape,
§6 permission posture and §8 exit semantics are inherited unchanged by the
variant; the four redirection variables the variant sets are a per-process
exception the catalog validated, documented here in the kit. A prox-ops
contract amendment is a coordinator follow-up, not worker scope.

## The validated contract the variant implements

Set per-process, inside the `env -i` allowlist, on the harness subprocess only:

| Variable | Value | Source of the value |
|---|---|---|
| `ANTHROPIC_BASE_URL` | the gateway (`https://ai-gateway.homelab0.org` on this fleet) | LAUNCHER configuration (`launcher.gateway_endpoint` in `files/model-router/subscriptions.yaml`, env override `AGENT_FLOW_GATEWAY_URL`) — never the story, the stamp or the catalog; empty → refuse |
| `ANTHROPIC_AUTH_TOKEN` | the scoped agentgateway key | resolved at launch time from a launcher-configured REFERENCE (see "Credential conveyance"); never printed, never persisted, never in generated command text |
| `ANTHROPIC_MODEL` | `qwen36-27b` | the catalog's `profiles.<profile>.physical[0].model_id` — the same value `--model` already receives. REQUIRED, not optional: an unpinned session 403s at the gateway (R1/R2) |
| `ANTHROPIC_CUSTOM_HEADERS` | `x-placement: <value>` | the `.result.headers["x-placement"]` member of the `/v1/place` evidence dispatch.sh already fetches immediately before validation — copied VERBATIM, never composed (R6). Absent header → refuse before any terminal exists |
| `CLAUDE_CODE_MAX_CONTEXT_TOKENS` | `65536` for `local-code-standard` | the catalog's `profiles.<profile>.min_context` (the profile's real window; Claude Code otherwise assumes 200k and compacts too late, F3). Absent in the catalog → refuse |

Per-LAUNCH semantics: the header is fixed at process start; a stale or withdrawn
placement degrades to the gateway's frozen default and is served (R10–R12); a
session never re-places itself. dispatch.sh already fetches placement fresh per
attempt, so nothing new is needed there beyond consuming the header.

Everything else stays exactly as the native launch: `env -i HOME PATH USER
LANG=C.UTF-8 TERM=dumb`, `claude -p "$(cat -- <promptFile>)" --model <id>
--effort <stamped> [--append-system-prompt-file <persona>] --permission-mode
acceptEdits --tools "Read,Glob,Grep,Write" --strict-mcp-config
--output-format json < /dev/null > <result>; echo "CLAUDE_EXIT=$?"`. No new
tool, no new permission, no new flag. The settings preflight still runs and
still refuses file-borne `env`/`apiKeyHelper`/`forceLoginMethod`/provider
redirections: the variant's redirection is per-process by design, and a
file-borne one would be an unvalidated second path.

## Launch-class discriminator (fail-closed, from the stamp plus the trusted catalog)

The adapter now has exactly TWO validated launch classes for `claude`:

- **Native subscription** (unchanged): `model_profile` in `claude/*` AND
  `entitlement_pool == anthropic-max` AND `placement_required != true`.
- **Gateway-backed local** (new): `harness == claude` AND the trusted
  catalog's `profiles.<profile>.hosting == local` AND
  `placement_required == true` AND the stamp's `entitlement_pool` is empty/null
  AND the stamp's `cost_class == free`.

Anything else is refused exactly as today, with today's wording (the tests
assert those strings): `{codex, local-code-standard}`, `{claude, minimax/strong,
minimax-max}`, `{claude, claude/strong}` on a non-native pool, a local profile
stamped with a vendor pool, an unknown profile. The discriminator reads the
STAMP and the launcher's TRUSTED catalog only — never the story, never a
runtime environment lookup.

## Credential conveyance — the one design decision you own

Constraints (all hard):

- The token VALUE must never appear in: generated command text, the Orca
  terminal title, dispatch.sh stdout/stderr, the prompt file, the result JSON,
  the `.blocked` marker, test output, or any file dispatch.sh writes.
- It is resolved at launch time and exists only in the harness subprocess's
  environment (and transiently in the shell that builds that environment).
- `files/model-router/subscriptions.yaml` may carry a NAME or a REFERENCE,
  never a value (rule 2 of that file). The existing `caller_token_env` pattern
  (an env-var NAME) is the precedent.
- Nothing is exported into the operator's shell and no global Claude
  configuration is rewritten (catalog notes, "credential isolation").

Observed facts you cannot test yourself (no shell): `orca terminal create`
accepts only `--worktree --title --command --focus --json` (an undocumented
`--environment` flag selects a saved Orca environment, not per-variable env);
the terminal's ambient environment is Orca's, not dispatch.sh's, so a value in
dispatch.sh's environment does NOT reach the terminal unless the command text
carries it — which is forbidden. The fleet's established secret mechanism is
the 1Password CLI: `op read op://<vault>/<item>/<field>`, authenticated by a
service-account token sourced from `~/.op-agent-env`.

Recommended shape (adopt unless you find a defect in it, and say why in the
record): launcher config names the reference (`launcher.gateway_token_ref`,
e.g. `op://develop/agw-claude-code/credential`, env override
`AGENT_FLOW_GATEWAY_TOKEN_REF`) and the op environment file
(`launcher.op_env_file`, default `$HOME/.op-agent-env`); the generated command
text embeds only those two shell-safe LITERALS and resolves the value at
terminal runtime: `ANTHROPIC_AUTH_TOKEN="$(. <opEnvFile> && op read
<ref>)"` inside the `env -i` invocation, so the value is never in the text and
never on disk. dispatch.sh preflights that `op` is on the approved PATH and
that the reference is non-empty; an empty read at runtime must make the launch
fail closed (a `claude` started with an empty token is an unpinned native
session — exactly the wrong-provider hazard PR #25 exists to stop). If you
choose a different mechanism it must satisfy every constraint above and the
tests must prove it with a sentinel value.

## Scope — exact file surface (nothing outside it)

- `files/model-router/scripts/dispatch.sh` — the second class in
  `unsupported_launch_reason` (signature may grow to take the catalog hosting
  and cost class; call sites updated), a `build_claude_gateway_command`
  builder (or a parameterized `build_claude_command`; either way the native
  text is byte-identical), the launcher-config reads, the header/context/model
  resolution, the fail-closed preflights, header comments updated (the
  "launch contracts this adapter implements" block and the two documented
  refusal instances).
- `files/model-router/subscriptions.yaml` — the new launcher keys with the
  same "name/reference, never a value" comments; `gateway_endpoint` defaults
  to this fleet's gateway.
- `lib/afk-readiness.sh` — `afk_launch_contract_reason` mirrors the two
  classes truthfully (its signature may grow; the single call site at
  ~line 1652 updated). No live gateway or credential probe is added: that is a
  follow-up, and today's `NOT_EVALUATED` semantics are the honest state.
- `tests/run-tests.sh` — section 3b flips for `{claude, local-code-standard}`
  and gains the variant assertions (below); every other guard assertion,
  including the native command-text expectation, stays as it is.
- `tests/lifecycle-readiness-tests.sh` — the two `afk_launch_contract_reason`
  assertions and the `refuse_case "placement-required profile"` case are
  re-aimed (claude+local now launchable; keep the codex+local refusal and add
  a claude+local case that asserts the reason is NOT
  `ROUTE_PROFILE_UNSUPPORTED` and the stamp on disk is byte-identical).
- `docs/LIFECYCLE-CONTRACT.md` — the "This kit's launch contract covers …"
  paragraph and the readiness table row stay true of the code.
- `files/model-router/SKILL.md` — only if it states the native-only claim.
- `_bmad-output/implementation-artifacts/AFK-PORT-1.4-LV.md` — this file's
  Dev Agent Record.

Diff budget: ≤ 800 added+changed lines, ≤ 25 files (PR discipline). Report
the final size in the record.

## Acceptance criteria

**AC-1 (guard admits exactly the validated pair class).**
Given a stamp `{claude, local-code-standard, placement_required: true,
entitlement_pool: null, cost_class: free}` and a trusted catalog marking the
profile `hosting: local`, when dispatch runs, then `unsupported_launch_reason`
is empty, no `.blocked` marker is written, and the launch proceeds to the
builder. And `{codex, local-code-standard}`, `{claude, minimax/strong,
minimax-max}`, `{claude, claude/strong, minimax-max}`, `{claude, minimax/strong,
anthropic-max}` and `{claude, local-code-standard}` stamped with a vendor pool
are refused with exit 7, a `.blocked` marker and today's wording; no terminal
is created and no command is built for any refusal.

**AC-2 (the generated command is the contract and nothing more).**
Given the admitted stamp, when the command text is built, then the `env -i`
allowlist is exactly `HOME PATH USER LANG TERM ANTHROPIC_BASE_URL
ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_CUSTOM_HEADERS
CLAUDE_CODE_MAX_CONTEXT_TOKENS` (no other `ANTHROPIC_*` or `CLAUDE_*` name
appears); `ANTHROPIC_MODEL` and `--model` both equal the catalog physical
model id; `ANTHROPIC_CUSTOM_HEADERS` equals `x-placement: ` plus the
evidence's header value verbatim; `CLAUDE_CODE_MAX_CONTEXT_TOKENS` equals the
catalog `min_context`; `--effort` is the stamped effort; the permission
posture, tool set, `--strict-mcp-config`, stdin redirect, result-file
redirect and `CLAUDE_EXIT=` line are identical to the native command.

**AC-3 (the token never leaks).**
Given the integration harness sets the credential source to a sentinel string
(a stubbed `op` on PATH, or the equivalent for your mechanism), when a gateway
launch runs end-to-end against the stubs, then the sentinel is absent from the
captured command text, the terminal title, dispatch.sh stderr, the prompt
file, the result JSON and every file under the worktree — and the run
otherwise completes (`status: done` with the stubbed exit line).

**AC-4 (fail-closed preflights, each before any terminal exists).**
Given the admitted stamp, when (a) the gateway endpoint is unset, (b) the
credential reference is unset, (c) the placement evidence has no `x-placement`
header, or (d) the catalog profile has no `min_context`, then dispatch exits
with the config/placement exit code, names the missing item in stderr, creates
no terminal, builds no command and writes no result artifact.

**AC-5 (the native class is byte-identical).**
Given the existing native stamp fixtures, when the suites run, then every
existing native assertion passes unchanged, including the exact expected
command text for `{claude, claude/strong}` and the codex denylist text.

**AC-6 (readiness mirrors the adapter).**
`afk_launch_contract_reason` returns empty for claude + a placement-required
local profile and non-empty for codex + the same, and for an unknown harness;
`status --json --stamp <claude-local-stamp>` no longer reports
`ROUTE_PROFILE_UNSUPPORTED` for that stamp, suggests no substitute, and leaves
the stamp byte-identical.

**AC-7 (documents stay true of the code).**
`docs/LIFECYCLE-CONTRACT.md` and the dispatch.sh header describe two launch
classes for `claude`, name the five variables, say where each value comes
from, and state the per-launch placement semantics and the credential
constraints. No document still claims a placement-required profile has no
launch contract on `claude`.

**AC-8 (gates and record).**
All five frontmatter gates pass in a fresh worktree; the Dev Agent Record
states the conveyance mechanism chosen and why, the files touched, the diff
size, anything deferred (with diagnosis), and whether you executed the gates
yourself.

## Out of scope — hard stops

- The MiniMax variant (`{claude, minimax/strong}`): the owner has not decided;
  the guard keeps refusing it and its tests stay as they are.
- A readiness-side live probe of the gateway or the credential.
- Cost aggregation (Claude Code reports a non-zero `total_cost_usd` on the
  free local path, F4/R14 — do not add anything that sums it).
- `make-stamp.sh`, the validator, the catalog, `/v1/route`, `/v1/place`
  request shapes.
- The natural-route smoke re-run and the verdict upgrade (separate story).
- The prox-ops contract amendment.
- Any change to the frozen tool set or permission posture of workers.

## Worker constraints

You may or may not have a shell. If you do, run the gates and paste the
tallies. If you do not, write defensively for a first-run-blind environment,
reason from the tests' exact assertions, and say plainly in the record that
you did not execute the gates — the coordinator re-runs every gate
independently either way. Never print `NEEDS-HUMAN:` for the no-shell
arrangement; print it only for a decision that genuinely needs the owner.

## Dev Agent Record

Executed by a dispatched `dev`-persona worker in its own Orca worktree
(`afk-port-1.4-lv`), branched from `master` @ `8a56eb5`. Persona proof computed
first and matched: outer
`07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee`,
intermediates `b980cf2c…` (SKILL.md) and `f3f107f1…` (customize.toml).

### Credential conveyance — the mechanism chosen, and why

The story's recommended shape, adopted, with one addition it turned out to
need.

The generated command text carries two shell-safe literals and nothing else:
the 1Password reference (`launcher.gateway_token_ref`, env override
`AGENT_FLOW_GATEWAY_TOKEN_REF`) and the service-account env file
(`launcher.op_env_file`, env override `AGENT_FLOW_OP_ENV_FILE`, defaulting to
`<approved_home>/.op-agent-env`). The value is resolved by the terminal at
launch time:

```
ANTHROPIC_AUTH_TOKEN="$(. <opEnvFile> && op read <ref>)"; \
[ -n "$ANTHROPIC_AUTH_TOKEN" ] || { echo '…refusing…' >&2; exit 78; }; \
env -i … ANTHROPIC_AUTH_TOKEN="$ANTHROPIC_AUTH_TOKEN" … claude … ; \
echo "CLAUDE_EXIT=$?"; unset ANTHROPIC_AUTH_TOKEN
```

Three things about that shape are deliberate.

**The read happens in a command substitution, so the service-account token
stays in a subshell.** Sourcing the env file exports `OP_SERVICE_ACCOUNT_TOKEN`;
inside `$( )` that export dies with the subshell instead of persisting in the
terminal's own environment where a later command could inherit it.

**The empty-read check is a separate statement, which is why the assignment is
not written inline inside `env -i`.** The story requires an empty read to fail
closed, and an expression evaluated inside the `env -i` argument list cannot:
`env` would simply set an empty variable and exec claude anyway. Splitting it
lets the check run first. It refuses by exiting WITHOUT printing an exit
marker, so `orca_launch` reports a terminal that ended without a `CLAUDE_EXIT`
line — a launch that "did not complete honestly", exit 2. Emitting a synthetic
`CLAUDE_EXIT=78` would have been more legible but strictly worse: dispatch
gates on the gate commands, not on the harness exit, so a credential failure
whose gates happened to pass would have been recorded `status: done`.

**`unset` after the exit line** drops the resolved value from the terminal
shell, which outlives the command. It is placed after `echo "CLAUDE_EXIT=$?"`
so that line stays byte-identical to the native one.

Rejected alternatives: passing the value through `orca terminal create` (the
CLI takes no per-variable environment, and the only way in is the command text,
which is forbidden); resolving it in dispatch.sh and interpolating it (same
thing, plus it puts the value in dispatch's own environment); a wrapper
`sh -c` inside `env -i` that assigns the token in the sanitized child (keeps
the value out of `env`'s argv, but adds a shell to the frozen §5 command shape
and breaks AC-2's requirement that the allowlist carry `ANTHROPIC_AUTH_TOKEN`).

**Residual, disclosed:** for the microseconds between the shell expanding the
substitution and `env` exec'ing claude, the value is in `env`'s own argv and so
in `/proc/<pid>/cmdline`. After the exec the process image is claude's and the
value lives only in `/proc/<pid>/environ`, which is the point of the class and
is same-user readable only. The window is tiny and same-user, but it is not
nothing; closing it means the `sh -c` wrapper above, which is a change to the
frozen command shape and belongs to a prox-ops contract amendment rather than
to this story.

### Launch-class discriminator

`unsupported_launch_reason` grew two parameters — the trusted catalog's
`profiles.<profile>.hosting` and the stamp's `cost_class` — and now answers for
two classes. Class 1 (native) is evaluated first and is byte-for-byte the
condition it was. Class 2 requires all four of: harness `claude`, catalog
`hosting: local`, `placement_required: true`, empty/null `entitlement_pool`,
`cost_class: free`. Both new parameters default to empty, so a caller that has
not been updated fails the pair CLOSED rather than defaulting it open; that is
asserted directly.

Refusal wording: codex + a placement-required profile keeps the established
paragraph verbatim, because it is still exactly true of codex. claude + a
placement-required profile that misses a class-2 condition gets a new paragraph
that names the specific mismatch — the old one asserts claude has a native-only
contract, which is no longer true and would have been a lie in a marker a human
reads. Both still contain the strings the suites pin (`explicitly forbids`,
`placement_required=true`).

### Files touched

| File | What changed |
|---|---|
| `files/model-router/scripts/dispatch.sh` | `build_claude_gateway_command`; two-class `unsupported_launch_reason` (+2 params, call site updated); `approved_path_has`; catalog `hosting` and stamp `cost_class` reads; the five fail-closed preflights; the class branch in the claude launch case; header block and marker guidance rewritten |
| `files/model-router/subscriptions.yaml` | `launcher.gateway_endpoint` (defaults to this fleet's gateway), `launcher.gateway_token_ref` (empty; a REFERENCE, never a value), `launcher.op_env_file` (empty; a PATH) |
| `lib/afk-readiness.sh` | `afk_launch_contract_reason` mirrors both classes (+2 params); `AFK_STAMP_ENTITLEMENT_POOL` loaded, declared and reset; call site updated |
| `tests/run-tests.sh` | section 1 guard assertions re-aimed + per-condition refusals; the gateway builder's own unit block; section 3 fixtures (catalog `min_context`, stub `op`, env file, launcher env); section 3b flipped and extended |
| `tests/lifecycle-readiness-tests.sh` | the contract-reason assertions re-aimed; `write_stamp` made truthful about local funding; `refuse_case` split into codex+local and claude+local-on-a-vendor-pool; the claude+local stamp asserted no longer `ROUTE_PROFILE_UNSUPPORTED` |
| `docs/LIFECYCLE-CONTRACT.md` | the launch-contract paragraph replaced by the two classes, the five-variable table with each value's source, and the per-launch placement semantics |
| `_bmad-output/implementation-artifacts/AFK-PORT-1.4-LV.md` | this record |

`files/model-router/SKILL.md` is untouched: it makes no native-only claim (it
describes the dispatch sequence and forbids widening the launch posture, both
still true), so the story's "only if" did not trigger.

**Diff size** (`git diff --stat master...HEAD`): 7 files, 1148 added / 85
deleted. 498 of those added lines are this story file itself — the frozen spec
plus this record, a planning artifact rather than reviewable code. The
reviewable change is **6 files, 650 added / 85 deleted**, against a budget of
≤ 800 added+changed lines and ≤ 25 files. Per file: `dispatch.sh` 197/48,
`run-tests.sh` 326/20, `LIFECYCLE-CONTRACT.md` 41/5,
`lifecycle-readiness-tests.sh` 35/10, `subscriptions.yaml` 26/0,
`afk-readiness.sh` 25/2. No generated files.

### Acceptance criteria

- **AC-1** — `guard: {claude, local-code-standard} gateway-backed local pair is
  launchable`; `gateway: {claude, local-code-standard} launches (exit 0)`; no
  blocked marker. Refusals: `guard[codex]` (all seven marker assertions),
  `guard[minimax]`, the two belt-and-braces unit cases, and the new
  `gateway: local profile on a vendor pool -> exit 7` with its marker, empty
  terminal-creates, absent command file and absent result artifact.
- **AC-2** — the allowlist is asserted as a SET, not as substrings: the segment
  between `env -i ` and ` claude -p` is parsed for `NAME=` tokens and compared
  to the exact ten names, at the unit level and again on the command Orca was
  actually handed. Plus `ANTHROPIC_MODEL` == `--model` == the catalog physical
  id, `ANTHROPIC_CUSTOM_HEADERS` == `x-placement: ` + the stub place result's
  header verbatim, `CLAUDE_CODE_MAX_CONTEXT_TOKENS` == the catalog
  `min_context`, and the tail comparison below.
- **AC-3** — `GW_SENTINEL` is what the stubbed `op` returns. The test first
  proves the configured reference really resolves to it (so the absence
  assertions are not vacuous), then asserts it is absent from the command text,
  the terminal title, dispatch stdout and stderr, the prompt file, the result
  JSON, and from every file under the worktree and the stub state directory
  (`grep -rl`). The run itself finishes `status: done` with the stubbed exit
  line.
- **AC-4** — four cases, each asserting the exit code, the named missing item
  in stderr, an empty terminal-creates, no command file and no result artifact:
  endpoint unset → 2, credential reference unset → 2, place evidence without an
  `x-placement` header → 6, catalog profile without `min_context` → 2. A fifth
  preflight (an unreadable credential env file) and a sixth (`op` not on the
  approved PATH) are implemented for the same reason and refuse the same way;
  they are not separately asserted.
- **AC-5** — every native assertion is unchanged and passing, including the
  exact `{claude, claude/strong}` command text and the codex denylist text. The
  gateway command's claude invocation is additionally compared *byte for byte*
  against `build_claude_command` called with the same inputs
  (`gateway cmd: the claude invocation is byte-identical to the native one`),
  so the two builders cannot drift.
- **AC-6** — `claude + a free, unpooled placement-required profile is
  launchable`; codex + the same refused; unknown harness refused; and
  `status --json --stamp` on a claude+local stamp now reports
  `STAMP_VALIDATION_UNPROVEN`, not `ROUTE_PROFILE_UNSUPPORTED`, suggests no
  substitute, and leaves the stamp byte-identical.
- **AC-7** — `docs/LIFECYCLE-CONTRACT.md` and the dispatch.sh header both
  describe two classes, name the five variables and where each value comes
  from, and state the per-launch placement semantics and the credential
  constraints. No document still says a placement-required profile has no
  launch contract on `claude`.
- **AC-8** — all five gates executed in this worktree by this worker; tallies
  below.

### Gates — run by this worker, in this worktree

| Gate | Result | Wall time |
|---|---|---|
| `bash tests/lifecycle-readiness-tests.sh` | 279 passed, 0 failed | ~4m |
| `bash tests/lifecycle-dispatch-tests.sh` | 250 passed, 0 failed | 3m10s |
| `bash tests/lifecycle-tests.sh` | 476 passed, 0 failed | 7m37s |
| `git diff --check` | clean, exit 0 | instant |
| `bash tests/run-tests.sh` | **322 passed, 1 failed — exit 1** (see below) | 41m59s |

shellcheck ran via `nix run nixpkgs#shellcheck` (0.11.0) — no `shellcheck` on
this host's PATH, which is the path section 0 already handles. `dispatch.sh`
and `lib/afk-readiness.sh` are clean at the severities the suite uses.

#### The one failing gate, and what it is

`tests/run-tests.sh` exits 1 on a single aggregate assertion,
`lifecycle concurrency gate`, which reports the sub-suite's own tally:

```
FAIL lifecycle concurrency gate
     204 passed, 3 failed
```

Run standalone, `tests/lifecycle-concurrency-tests.sh` fails these three,
verbatim:

```
FAIL a contender that observed the window waits it out rather than refusing
     expected '1', got '3'
FAIL and reports the live owner it was waiting for
     expected 'LIVE', got 'UNKNOWN'
FAIL so nothing it says can be read as 'this lock has no owner'
     expected '0', got '1'
```

**They are not caused by this story, and this is checked rather than asserted.**
A fresh `git clone` of this repository at pristine `master` @ `8a56eb5`, on this
host, run in the scratchpad with no changes from this branch present, produces
the same `204 passed, 3 failed` with the same three assertion names and the
same expected/got values.

Diagnosis: the three sit in the operation-lock publication-window scenario
(`tests/lifecycle-concurrency-tests.sh` around line 500). It is a busy-wait
rendezvous — `burn_until_gone` spins a bounded loop to get the contender inside
its acquisition before the winner's window closes. On this host the contender
finishes first, so it never observes the open window and judges `UNKNOWN`
instead of `LIVE`. That is host-timing sensitivity in the test's rendezvous, in
a file this story does not touch (`lib/afk-mutate.sh`,
`tests/lockctl-helper.sh`, `tests/lifecycle-concurrency-tests.sh` are all
unmodified here).

Under the dispatch brief's rule — succeeded iff all five gates pass in this
worktree — this run is reported as **failed**, with the assertion names above,
rather than argued into a pass. Nothing in the launch-variant work is
implicated: every assertion in sections 0 through 5 of `run-tests.sh`, and both
of the suites this story actually changes, are green.

### Deferred, deliberately, and disclosed

1. **`env` argv exposure of the resolved credential** (diagnosed above). A
   microsecond-wide, same-user window before `exec`. Closing it needs a wrapper
   shell inside `env -i`, which changes the frozen §5 command shape and is a
   prox-ops contract question, not a kit change.
2. **`launcher.gateway_token_ref` ships empty**, so a fleet operator must fill
   in the vault reference before the first gateway launch. Shipping this
   fleet's reference as a default would make AC-4(b) unreachable in the default
   configuration and would put a vault path this repo cannot verify into
   shipped config; the endpoint is defaulted because the story says to, the
   reference is not because a reference is per-vault. `subscriptions.yaml`
   documents the expected form.
3. **The prox-ops contract `HARNESS-LAUNCH-claude.md` is not amended.** Its §7
   still reads as a blanket prohibition on redirection; the per-process
   exception is recorded here and in the catalog. The story assigns the
   amendment to the coordinator.
4. **No readiness-side live probe** of the gateway or the credential was added.
   `NOT_EVALUATED` remains the honest offline state, per the story's scope.
5. **Readiness checks three of the adapter's four class-2 conditions.** It does
   not load the trusted catalog, so it cannot check `hosting: local`; it can
   and does check harness, placement flag, pool and cost class. This makes
   readiness slightly optimistic for a hypothetical claude stamp that requires
   placement for a vendor-hosted profile — the adapter refuses it at dispatch.
   Giving readiness the catalog would make it a second policy loader, which is
   a larger design question than this story owns.
6. **The MiniMax pair stays refused**, untouched, tests unchanged.
7. **Cost aggregation** is untouched; nothing here sums `total_cost_usd`.

### Commits

Two commits on `jlengelbrecht/afk-port-1.4-lv`, forked from `master` @
`8a56eb5`: the implementation and this record, then a one-line follow-up that
fills in the implementation commit's SHA (a record cannot contain its own
hash). SHAs are listed in the second commit and in the completion message.
Nothing pushed, no PR opened, `master` untouched. The brief, the stamp and the
route artifacts are coordinator-retained and are deliberately not in the commit.
