---
name: model-router
description: >
  Subscription-aware model, provider, and effort routing for agent work. Use this
  skill whenever planning epics or stories with BMAD, writing hand-off prompts,
  creating or updating story files, or whenever the question "which model / provider /
  effort should run this task" comes up — even implicitly. Also use it when the user
  says route, dispatch, hand off, spawn a dev, or asks what a task should run on.
  Always consult subscriptions.yaml (in this skill folder, or the path in
  $SUBSCRIPTIONS_FILE) before recommending; never route from memory.
---

# Model Router

You are deciding, per task, which provider + model + effort should execute it — at
planning time, with the human in the loop. The decision gets stamped into the story's
frontmatter so dispatch is mechanical later. Runtime improvisation is a bug.

## Workflow

0. **Pool temperature check.** At the START of each planning session (once per epic,
   not per story), run `scripts/usage-check.sh` and factor the printed guidance into
   provider picks. Claude reports real session/weekly numbers; codex and devin have
   no headless usage surface — their exhaustion is handled reactively by dispatch.sh
   fallbacks. If claude weekly is hot, shift per the thresholds the script prints.

1. **Read the registry.** Load `subscriptions.yaml`. The providers listed there are
   the ONLY legal routing targets. If a task would genuinely benefit from a provider
   that is not in the registry, say so in one sentence of prose — never put an
   unowned provider in a `route:` block.

2. **Classify the task on four axes:**
   - **Ambiguity** — is the spec airtight, or will the agent make judgment calls?
   - **Blast radius** — how bad is a wrong-but-plausible result? (touches auth/data
     model/public API = high)
   - **Context size** — how much code must be held in mind at once?
   - **Volume** — is this one task or one of many near-identical ones?

3. **Map to a tier:**

   | Signal | Tier |
   |---|---|
   | High ambiguity OR high blast radius OR cross-cutting architecture | `frontier` / `strong` |
   | Clear spec, normal implementation, moderate context | `standard` |
   | Mechanical, repetitive, low blast radius, high volume | `fast` |
   | Review of a completed story | `strong` (see review rules) |

4. **Pick provider within the tier:**
   - Start from `routing.default_provider`.
   - Apply `routing.strengths` if a listed strength matches the task.
   - Apply `routing.budget_rules` (Fable guard, pool headroom, volume-to-fast-tier).
   - **Reviews:** honor `review_diversity` — if both providers cover the tier, the
     reviewer runs on the other provider from the author, and always in a fresh
     session. Never assign review to the session that wrote the code.
   - When torn between two options, pick the cheaper tier and note the upgrade
     trigger ("bump to opus if cycle 1 fails gates").

5. **Pick effort** (Claude: `low|medium|high|xhigh`; codex analog is
   `model_reasoning_effort`):
   - `fast` tier → low/medium (Haiku ignores effort entirely)
   - `standard` implementation → high
   - `strong/frontier` planning and review → xhigh
   - Prefer raising effort over raising model when the failure mode was "skipped a
     file / didn't run the tests"; prefer raising model when it "had everything and
     still got it wrong".

6. **Emit the route block** into the story frontmatter, plus a one-line rationale in
   the story body (rationale is for Josh, not for the dev agent):

```yaml
route:
  provider: claude
  cli: claude
  model: sonnet
  effort: high
  agent: bmad-dev
  fallback: [openai/gpt-codex]
gates:
  - "pnpm test"
  - "pnpm lint"
max_cycles: 3
```

`cli` must match the provider's `cli:` in the registry. `fallback` comes from
`routing.fallbacks` for the chosen provider/model. `gates` are the exact commands
that define done — copy them from the story's acceptance criteria, never invent them.

**Visible dispatch (default):** never run dispatch.sh as a bare background Bash
command — that makes the worker invisible to Orca. Instead: create the story's
worktree with `orca worktree create` (not raw `git worktree add`), open a terminal in
it with `orca terminal create`, `orca terminal rename` it to the story ID + route
(e.g. "GLY-180 dev sonnet"), then `orca terminal send` the dispatch.sh command and
`orca terminal wait` for exit. Josh watches the worktree card + terminal tab from the
app or mobile; the terminal streams the dispatch lifecycle (route, cycles, fallbacks,
gate results, result JSON). For full turn-by-turn agent visibility use the
orchestration path below instead.

**Dispatching through Orca orchestration:** this block maps 1:1 onto
`orca orchestration worker-start` — `route.cli` → `--agent`, `route.model` →
`--model`, `route.effort` → `--effort` (requires `--model`; Claude/Codex/Cursor
only, and not combinable with `--terminal`). On a failed dispatch that smells like
rate limiting, retry with `worker-start --retry-of <dispatchId>` using the next
entry in `route.fallback`. Load `orca skills get orchestration --full` before
mutating any orchestration state.

## Capability truth (is the other provider's model actually better?)

The `strengths` table is observations, not doctrine, and model quality shifts monthly.
When a routing decision is consequential AND contested (e.g. sol vs opus for a hard
implementation, picking a review model for a big diff), spend one web check on current
independent leaderboards — SWE-bench Verified, Aider polyglot, LiveBench, LMArena —
for the specific task family, then record what you learned as a DATED entry in the
registry's `strengths` table so the next session inherits it. Rules: never per-story
lookups for routine work; leaderboards inform the pick within a tier, they never
override budget rules or the claude-unique constraints (MCP/qa stories, safety-critical
paths stay claude regardless of leaderboard deltas).

## Persona selection (`agent` is a routing decision too)

BMAD ships specialized personas (`_bmad/bmm/agents/` in this repo; dispatch injects
the file named by `route.agent`). Stamp the persona per story type — `dev` is the
default, not the only answer:

| Story type | agent | Notes |
|---|---|---|
| Implementation, refactor, bug fix | `dev` | the default |
| Validation / physical testing story | `qa` | claude route ONLY (needs MCP — see below) |
| Docs, READMEs, user guides | `tech-writer` | pairs well with fast/free tiers |
| Tiny self-contained fix (1 file, clear AC) | `quick-flow-solo-dev` | |
| Research/analysis spike (no code ships) | `analyst` | |
| Design/architecture spike | `architect` | usually stays interactive with Josh, not dispatched |
| UX specification | `ux-designer` | |

`pm` and `sm` are planning-altitude personas — never dispatch targets.

## Validation stories (physical testing is its own dispatch)

Any story whose change has a physical surface — web UI, API runtime behavior, a
device/pairing flow — gets a **separate trailing validation story** in the epic:

- `agent: qa`, and **provider MUST be claude**: physical driving needs the MCP
  toolchain (Playwright browser driving, docker stack, Sentry) that only claude
  workers load. Emulator-driven mobile validation lives in the android repo's flow.
- The validating session is NEVER the implementing session (or its resume) — fresh
  context, different eyes; cross-check `review_diversity` where it applies.
- Its ACs name the exact flows to drive (pages, clicks, expected states), not
  "test the feature". Its gates are the real commands where scriptable.
- Findings do not get fixed in the validation story — they cycle back as re-dispatch
  of the implementing story (or a fix story), then validation re-runs.
- A story is not epic-done until its validation story is done. Unit tests in the
  implementing story do not substitute for the validation story on physical surfaces.

## Hard rules

- Never route to a provider absent from `subscriptions.yaml`.
- Never exceed the Fable budget rule; if a task deserves frontier and the budget rule
  blocks it, route `strong` and flag the tension to Josh in one line.
- Ask Josh before stamping the route ONLY when blast radius is critical (auth, data
  migrations, anything irreversible) — otherwise decide, stamp, and show the rationale.
- If the registry file is missing or unparsable, stop and say so. Do not route blind.
