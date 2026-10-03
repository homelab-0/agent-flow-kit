---
name: model-router
description: >
  Routing and dispatch for agent work through the central control plane. Use this
  skill whenever planning epics or stories with BMAD, writing hand-off prompts,
  creating or updating story files, or whenever the question "which harness /
  model / effort should run this task" comes up — even implicitly. Also use it
  when the user says route, dispatch, hand off, spawn a dev, or asks what a task
  should run on. The decision comes from POST /v1/route; never route from memory,
  and never re-derive a route from a local table.
---

# Model Router

You are preparing, per task, the SIGNALS that let the central router decide which
harness, model profile and effort should execute it — then accepting that
decision with the human in the loop, and freezing it into an immutable execution
stamp so dispatch is mechanical later.

**You no longer choose the route.** `POST /v1/route` does. Your job is to
describe the task honestly, accept or deliberately override the recommendation,
and stamp it. Runtime improvisation was always a bug; local routing tables are
now one too.

## The chain

```
four-axis classification
  → POST /v1/route              (the router recommends)
  → human accepts, or deliberately overrides with a recorded reason
  → make-stamp.sh               (immutable stamp; expires_at copied verbatim)
  → dispatch.sh
      → POST /v1/place          (only when placement_required)
      → agent-stamp-validate    (fail-closed, immediately before launch)
      → Orca worktree + terminal, harness launched under the stamped decision
      → deterministic gates
      → <story>.result.json     (thin artifact the PM reads)
```

Every link is load-bearing. There is no shortcut past any of them, and adding one
is how this flow stops meaning anything.

## Workflow

### 1. Classify the task on four axes

These are the same four axes as before. What changed is where they go: they are
now ROUTER INPUTS, not lookups into a tier table you own.

| Axis | RouteRequest field | Values |
|---|---|---|
| Ambiguity — is the spec airtight, or will the agent make judgment calls? | `ambiguity` | `low` \| `medium` \| `high` |
| Blast radius — how bad is a wrong-but-plausible result? | `blast_radius` | `low` \| `medium` \| `high` \| `critical` |
| Context size — how much must be held in mind at once? | `context_size` | integer tokens |
| Volume — one task, or one of many near-identical ones? | `volume_hint` | `low` \| `medium` \| `high` |

Corroborate blast radius with `touched_paths`. A story claiming low risk while
naming an auth directory is claiming something its paths do not support, and the
router reads both.

### 2. Tag the task — five tags are load-bearing

`tags` are mostly descriptive, but five are HARD EXCLUSIONS that appear in a
profile's catalog `forbidden_for` list: **`security`, `iam`, `secrets`,
`prod-iac`, `destructive-tools`**. A match excludes a profile no matter how well
it otherwise fits, and no human override can bypass it.

**The trap: `iac` is not `prod-iac`.** Tag production infrastructure work
`prod-iac` if you mean the exclusion to fire. `docs`, `tests`, `iac` are
ordinary signals.

Tags are also stamped into `task.tags` and re-checked at dispatch, so a stamp
cannot quietly describe a tamer task than the one that was routed.

### 3. Call the router

```bash
cat > /tmp/route-req.json <<'JSON'
{
  "story_id": "STORY-041-3",
  "title": "Add the missing LAN DNS record for the gateway hostname",
  "summary": "One manifest, one test. The hostname does not resolve without a --resolve override.",
  "touched_paths": ["kubernetes/apps/network/"],
  "ambiguity": "low",
  "blast_radius": "low",
  "context_size": 12000,
  "volume_hint": "low",
  "tags": ["iac"],
  "repo": "prox-ops",
  "requester": "bmad-pm"
}
JSON

scripts/make-stamp.sh --request /tmp/route-req.json \
  --out .../STORY-041-3.md.stamp.json --check
```

`make-stamp.sh` POSTs the request, shows you the recommendation, and writes the
stamp. `--check` runs the validator once as an ADVISORY early warning — it is not
the final validation, and dispatch re-validates immediately before every launch.

Notes on the request shape:

- The shape is CLOSED. There is no field for a caller-named `harness` or
  `model_profile`, and there is not going to be one: a caller cannot use this
  endpoint to tell the router what answer to return.
- `allow_metered` defaults to false and **the default is the whole control.**
  Setting it does not authorize anything; it asks the router to consider a
  billable candidate, and only an authenticated caller that independently holds
  spend authority gets one. Setting it automatically after a `metered_denied` is
  removing the control while leaving the paperwork in place. Do not.
- `placement_policy` is optional; omitted means the catalog default. The router
  may not widen it — asking for `cluster-only` gets `cluster-only` or an explicit
  failure, never a workstation.

### 4. Accept, or override deliberately

The response is a RECOMMENDATION, not an instruction. Accept it and stamp it, or
override it — but an override is a human decision that gets written down:

```bash
scripts/make-stamp.sh --request /tmp/route-req.json --out <stamp> \
  --override-harness codex --override-profile openai/strong \
  --override-actor josh --override-reason "cross-provider review of a claude-authored diff"
```

The entitlement pool follows the overridden profile, read from the trusted
catalog rather than copied from the recommendation. An override that would need a
pool choice (the profile has zero or several entitlements), or whose profile or
harness/profile pair the catalog does not list, is refused; a metered profile is
refused unless the route request itself carried `allow_metered: true`.

`placement_required` follows the overridden profile too: the trusted catalog's
`hosting` class decides it (`vendor` is false, `local` is true), so a local
recommendation overridden to a vendor profile is not stamped as needing
placement, and the reverse is. `placement_policy` is the router's, kept
verbatim; it is never widened or replaced by a default. An override is refused
when the route response's `placement_policy` is not a non-empty string (for
any final profile, vendor included), when the final profile's hosting is
missing or anything other than `vendor` or
`local`, or when it is local and the catalog does not define the policy or the
policy admits none of the profile's physical placements. Such an override needs
a new route decision, not a different stamp. The stamp still carries no physical
placement; dispatch resolves that per attempt.

An override may bypass ROUTER SCORING ONLY. It never bypasses `forbidden_for`,
entitlement and billing restrictions, metered-spend authorization, or capability
and placement constraints. The override record is audit provenance; the final
stamped fields are validated on their own merits, and an override that produces a
combination the router itself could never have emitted fails validation exactly
as if the router had proposed it. The override is provenance only and grants no
bypass.

Ask the human before stamping when blast radius is `critical` (auth, data
migrations, anything irreversible). Otherwise decide, stamp, and show the
rationale in one line.

### 5. Write the story frontmatter

The stamp is a separate, immutable JSON document. Frontmatter carries only what
lives OUTSIDE the closed stamp — the stamp's property set is closed and has no
home for persona, gates or cycle policy, and must not grow one:

```yaml
---
linear:
# path to the immutable ExecutionStamp; defaults to <story>.md.stamp.json
stamp: STORY-041-3.md.stamp.json
# BMAD persona injected at dispatch. Named file must exist under the launcher's
# agent_dir or dispatch REFUSES — persona injection never silently no-ops.
persona: dev
# Worker-memory policy. Legacy stories with no field default to advisory; all
# newly planned stories declare one of advisory|required|blind|off explicitly.
memory_mode: advisory
# The exact commands that define done. Copy them from the acceptance criteria,
# never invent them. An EMPTY gate list is invalid: it cannot distinguish done
# from claimed-done, and dispatch refuses to run without one.
gates:
  - "pnpm test"
  - "pnpm lint"
max_cycles: 3
# OPTIONAL. Extra files the worker's payload will carry — templates, contracts,
# a continuation artifact. Repo-relative, and counted by the pre-dispatch
# sizing estimate below. A path that does not exist, or that escapes the
# worktree the worker is sandboxed to, REFUSES the dispatch
# (PAYLOAD_REF_MISSING) rather than being skipped.
payload_refs:
  - docs/LIFECYCLE-CONTRACT.md
---
```

**Every story's template also carries a `Test runtime impact:` line**, right
under its title, before the Epic line: the seconds a story adds to or removes
from the gates, and which suite. PM planning check (AD-18): a story projected
to add more than 60s of gate time needs either a stated reason in that line or
an offsetting saving named in the same story or a companion one — an unstated
60s+ addition is a planning gap, not a nitpick. `run-tests.sh` reports each
suite's actual wall time and the run's total against a BUDGET warning at
dispatch time, so drift from what the story projected shows up immediately.

There is no `route:` block any more, and no `local_gpu:` pre-assessment.
dispatch.sh refuses a story that still carries a `route:` block rather than
silently ignoring it, because a stale local route block that looks authoritative
is worse than none.

Placement is not stamped by you either. `placement_policy` and
`placement_required` come from the router inside the stamp (an override
re-derives only `placement_required`, as above); the physical
placement is resolved late, per attempt, by dispatch.

**Story sizing is checked before the launch, and it can refuse.** dispatch reads
the routed profile's context window from the trusted catalog — exactly, never
derived — and estimates the payload it is about to hand the worker: the persona
file, the story, the generated prompt and every `payload_refs:` path, each
counted once. Thresholds and the estimate method come from the declared policy
document `context-budget-policy.yaml`, never from a constant in code and never
from your story.

A payload already at or past the continuation threshold refuses with exit 8 and
a `STORY-SIZING:` marker, before any placement or terminal exists — a story that
starts past the point where a worker would have to hand over cannot finish, and
that is a planning finding, not a routing one. Split the story, trim what the
payload declares, or route it to a profile with a larger window (a new
`/v1/route` call and a new stamp — never an edit to the one you have). In the
band below that, dispatch proceeds and writes one `SIZING_RISK` line into the
story's Dev Agent Record so the size shows up in the record instead of only in
the outcome. A profile whose catalog entry declares no window reports
`NOT_EVALUATED`: the kit never invents one.

The estimate is advisory kit policy. It is not sent to `/v1/route`, it is not a
`context_size` minimum, and it changes no route.

**After the run, the budget is what the harness actually published.** `claude`
publishes one end-of-run result envelope, so its usage adapter reads that and
nothing else — the kit scrapes no terminal and no transcript — and reports
`HARNESS_ENVELOPE` / `END_OF_RUN`; `codex exec` and the frozen OpenCode JSONL
launch publish no qualified current-occupancy field, so their adapters report
`NOT_EVALUATED` / `USAGE_UNOBSERVABLE`. That honest absence never becomes a
made-up estimate or fallback logic in the core. Mid-run usage being
unobservable on those paths, the checkpoint discipline is deterministic instead: the generated
prompt tells the worker to write `<story>.checkpoint.json` at declared phase
boundaries, and to stop at the next boundary with `<story>.continuation.json`
and one `CONTINUATION-REQUIRED:` line when it cannot finish. A valid
continuation gives the thin result `status: continuation_required`; a signalled
continuation with a missing, unparseable or stale artifact is a loud
`NEEDS-HUMAN` and writes no result at all.

**A continuation is the next cycle of the same story, under the same stamp.**
Dispatch the same story again with `dispatch.sh <story> --cycle <next>`: it consumes
`<story>.continuation.json` into the prompt and the estimate, records
`budget.continuation_of`, and adds `REPEATED_CONTINUATION` — a story that needed
a second window was sized for one it did not have. Two things need you. If the
stamp has expired or been invalidated, the refusal names
`CONTINUATION_STAMP_REFRESH_REQUIRED`: call `POST /v1/route` again, accept, and
mint a NEW stamp with `make-stamp.sh` — never edit or locally substitute the one
you have, however half-finished the work is. And when the story has consumed
`continuation_cap` continuations, the next one refuses with
`CONTINUATION_CAP_REACHED`; split the story, or authorise exactly one more cycle
by recording the decision in the story's frontmatter, which the refusal marker
prints verbatim:

```yaml
continuation_decision:
  cycle: 4              # the ONE cycle this authorises; it does not carry forward
  actor: <who decided>
  at: <RFC3339>
  reason: <why one more continuation is the right call>
max_cycles: 4           # the story's own cycle limit, which must reach that cycle
```

Both keys, because they are two different limits. `continuation_decision` is the
policy authorisation; `max_cycles` is the story's own per-story cycle limit and
defaults to 3, so an authorised cycle 4 is still refused by it unless the story
raises it. The cap is counted from the story's append-only continuation ledger
`<story>.continuations.json`, one entry per continuation launched, so it does not
matter which cycle numbers were used — and a continuation cycle is never re-run
in place: dispatch one again and you get `CYCLE_ALREADY_RETAINED` naming the next
free cycle. Re-dispatching an ordinary cycle is unchanged.

### 6. Dispatch — visibly, through Orca

Orca owns worktrees, terminals, processes and native harness auth. The kit owns
delegation and control flow. The router owns recommendation and placement, and
never credentials or sessions.

```bash
orca worktree create --repo id:<repoId> --name <story> --parent-worktree worktree:<caller> --json
# mirror the story + its stamp into the new worktree (the sandboxed worker's
# root is its cwd; a story outside it is unreadable to the worker)
cd <worktreePath>
scripts/dispatch.sh <story>.md 1
```

dispatch.sh takes it from there and does the rest in code: it checks the repo
setup policy, fetches placement when the stamp requires it, runs the validator
fail-closed, creates and titles the Orca terminal running the frozen harness
command, harvests the in-band `CLAUDE_EXIT=`/`CODEX_EXIT=` line, re-runs the
gates independently, and writes the thin result.

Two things worth knowing about that path:

- **`orca terminal wait --for exit` does not fire.** The terminal outlives its
  command, so the in-band exit line is the only reliable completion signal. This
  was measured on both harnesses, not assumed.
- **A zero exit means the turn completed, not that the task succeeded.** The
  gates are the arbiter, always, and they are re-run independently of anything
  the worker claims.

Never run dispatch.sh as a bare background Bash command: that makes the worker
invisible to Orca, and dispatch refuses to launch from a directory that is not an
Orca-managed worktree for exactly that reason.

## Persona selection (still yours — it is not a routing decision)

Persona is a BMAD concern, not a router concern: the closed ExecutionStamp has no
field for it, and it travels as a sibling `persona:` key.

| Story type | persona | Notes |
|---|---|---|
| Implementation, refactor, bug fix | `dev` | the default |
| Validation / physical testing story | `qa` | needs the MCP toolchain — see below |
| Docs, READMEs, user guides | `tech-writer` | |
| Tiny self-contained fix (1 file, clear AC) | `quick-flow-solo-dev` | |
| Research/analysis spike (no code ships) | `analyst` | |
| Design/architecture spike | `architect` | usually stays interactive, not dispatched |
| UX specification | `ux-designer` | |

`pm` and `sm` are planning-altitude personas — never dispatch targets.

The persona file must exist at `<agent_dir>/<persona>.md`. If it does not,
dispatch fails loudly rather than launching a worker with no persona and
reporting success; a silent no-op here produced workers that looked routed and
were not.

## Validation stories (physical testing is its own dispatch)

Any story whose change has a physical surface — web UI, API runtime behavior, a
device/pairing flow — gets a **separate trailing validation story** in the epic:

- `persona: qa`. Physical driving needs the MCP toolchain, which constrains which
  harness can do it; describe that constraint in the story `summary` and let the
  router account for it rather than hard-coding a harness yourself.
- The validating session is NEVER the implementing session (or its resume).
- Its ACs name the exact flows to drive (pages, clicks, expected states), not
  "test the feature". Its gates are the real commands where scriptable.
- Findings do not get fixed in the validation story — they cycle back as a
  re-dispatch of the implementing story (or a fix story), then validation re-runs.
- A story is not epic-done until its validation story is done.

## Cycles, retries and rate limits

- Each retry cycle re-validates the **same** stamp. Expiry is real: a stamp that
  has aged out fails `not_expired` and the launch is refused. That is the
  intended behaviour, not a bug to work around.
- A NEW stamp — meaning a fresh `/v1/route` call — is required when the stamp has
  expired, or when the human genuinely wants a different route.
- **A rate-limited pool is not a local decision any more.** The old fallback
  chain re-routed at runtime with no stamp, no expiry and no validation, and
  detected exhaustion by grepping the model's own output, which a worker could
  simply say. If a pool is hot, that is a planning-session conversation ending in
  a new `/v1/route` call — not something dispatch does behind your back.

## Coordinator context budget

Your own window is a resource like any other, and nothing measures it for you.

- **Thin consumption only.** Read pointers and bounded summaries: a worker's
  thin result, a watch record, a story's Dev Agent Record. Opening a transcript,
  a gate log or an evidence body into a coordinator turn is a defect, not
  thoroughness — the worker already summarized it, and that summary is what the
  hand-over carries.
- **Never hold a poll open inside a turn.** `agent-flow-kit monitor --reconcile`
  is one bounded pass that consumes whatever arrived while nobody was looking.
  A loop that waits for a worker spends your window on nothing.
- **Checkpoint at phase boundaries** — story dispatched, worker settled, PR
  merged, lane closed. When usage is unobservable the boundary is the only
  budget signal there is, so it is the discipline rather than a fallback:
  `agent-flow-kit pm-checkpoint --write <json>`.
- **Publish the observation if your harness can.** With `pm/usage.json` present
  the kit bands your occupancy as it bands a worker's and says `CHECKPOINT_DUE`
  before you find out the hard way. `usage_tokens` is the context the session is
  HOLDING, not a running total over calls.
- **Hand over deliberately, and start the successor yourself.** At the
  continuation ratio write the artifact with `pm-checkpoint --continuation`,
  including a `resume_instruction` the next session can run as-is. The kit will
  not start a session for you: it makes the condition loud and hands you the
  command. The successor clears it with `monitor --reconcile --session <id>`.

## Hard rules

- Never assert a route from memory, from a local table, or from a previous
  story's stamp. Call `/v1/route`.
- Never edit a stamp. Re-stamp from a new route decision instead.
- Never copy a stamp between stories: `task.story_id` and `task.tags` are
  re-checked at validation, and a borrowed stamp is a stamp for a different task.
- Never widen the harness launch posture to make a task pass. If a task cannot
  complete under the frozen sandbox and tool set, that is a blocker to report.
- Never treat `claude auth status` or `codex login status` as liveness. They
  confirm what kind of credential record exists, not that it still works, and a
  preflight that gates on them will wave a dead session into a run.
- If the router is unreachable, stop and say so. Do not route blind, and do not
  fall back to a local table — there is no longer one to fall back to.

### Memory boundary

`memory_mode: advisory | required | blind | off` is launcher-owned story
frontmatter. It is deliberately outside the closed ExecutionStamp and never
enters `/v1/route`, placement, or stamp validation. Invalid values refuse
locally; an omitted field defaults to `advisory` only for legacy stories.

- `advisory` verifies the already-installed native Hindsight runtime and the
  selected harness's native wiring. A ready installation is used. Missing,
  unsynced, or unqualified memory is logged as an explicit advisory outage and
  the worker continues.
- `required` performs the same secret-free readiness and native-wiring proof
  before the harness starts. Failure writes `MEMORY_REQUIRED_UNAVAILABLE` and
  refuses the launch; it never degrades to advisory.
- `blind` and `off` are process boundaries. Every worker receives
  `HINDSIGHT_DISABLED=true` and a per-attempt, mode-600 `HINDSIGHT_CONFIG` whose
  complete content is `{"disabled":true,"bankId":"afk-disabled"}`. The native
  config and credentials are never read or copied.

Claude, Codex, and OpenCode receive the same memory environment. The helper
also defines the fail-closed Hermes answer, but Hermes remains a human front
door and is not dispatchable. AFK never installs or duplicates native
Hindsight hooks/plugins. OpenCode's ephemeral `--pure` config includes the
exact already-installed Hindsight plugin reference once for advisory/required,
and an explicit empty plugin list for blind/off.

Every frozen worker launch also receives `AFK_WORKER_IDENTITY`, `AFK_RUN_ID`,
`AFK_STORY_ID`, `AFK_STORY_PATH`, `AFK_CYCLE`, `AFK_DISPATCH_ID`, and
`AFK_OWNING_PM` (the durable `run:<id>` mailbox), plus
`AFK_DELEGATING_PM` for audit. A harness-native pressure hook/event can publish
while the worker is alive, after writing the phase checkpoint, with:

```bash
"$AFK_CONTEXT_EVENT_HOOK" --emit-context-event \
  --state CHECKPOINT_DUE --phase implementation \
  --used-tokens 120000 --window-tokens 200000
```

The hook first persists an immutable `afk-worker-context-event/1` bound to the
whole identity tuple, the actual worker terminal when available, the delegating
PM terminal, and the checkpoint's path/content digest. A `CHECKPOINT_DUE`
without a valid `afk-checkpoint/1` artifact refuses emission. The hook then
best-effort publishes the same payload from the actual worker terminal to the
owning Run mailbox (no terminal `--to` target), so PM rollover cannot strand it.
Both send and Run-ownership lookup use a small validated timeout through
`ORCA_CLI_COMMAND`/`AFK_ORCA_BIN`; a stalled CLI cannot consume the worker or
PM's remaining context. Publication failure does not erase the durable file. The current PM consumes a
file with `dispatch.sh --consume-context-event <event.json> --pm <its-terminal>`;
dispatch verifies with Orca that this terminal currently owns the same Run.
The old delegating terminal is audit evidence, never authorization. An atomic
`flock` plus a durable consumption receipt makes consumption exactly once
across PM rollover: receipt state is rechecked while the lock is held, and a
crashed PM releases the lock automatically for its successor. `CHECKPOINT_DUE` rechecks the checkpoint digest, records
`CHECKPOINT_ONLY`, and never launches anything.
`CONTINUATION_REQUIRED` is not launch authority by itself: the consumer first
requires the ordinary retained `continuation_required` result and valid,
story-bound continuation artifact, then invokes the one canonical next-cycle
path, `dispatch.sh <story> --cycle <cycle+1>`. Existing continuation ledger,
cap, same-stamp revalidation, and refusal semantics remain authoritative.

Codex/OpenCode current occupancy remains honestly unobservable until a
qualified native event supplies it. Their worker prompt therefore still
requires checkpoints after story-read, after implementation/before gates, and
before report. That deterministic phase-boundary discipline is active policy,
not a fabricated usage signal. Hindsight is always external context, never
routing, approval, review, or gate authority; current project artifacts win.
