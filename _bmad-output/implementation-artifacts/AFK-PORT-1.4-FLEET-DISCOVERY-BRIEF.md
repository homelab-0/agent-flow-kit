# Worker brief — AFK-PORT-1.4-FLEET-DISCOVERY (fresh codex session, read-only)

You are a dispatched WORKER under Orca supervision. Route/stamp:
`_bmad-output/implementation-artifacts/AFK-PORT-1.4-FLEET-DISCOVERY.stamp.json`
(codex, openai/strong, effort medium, Josh-authorized override recorded).

## Persona (fail-closed)

Activate the BMAD DEV persona from `.agents/skills/bmad-agent-dev/SKILL.md` +
`customize.toml`. Compute the persona proof before starting:

```
{ sha256sum .agents/skills/bmad-agent-dev/SKILL.md; sha256sum .agents/skills/bmad-agent-dev/customize.toml; } | sha256sum
```

Expected: `07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee`.
Mismatch = STOP and report failure.

## Task — read-only Orca fleet discovery (Story 1.4 AC-3 input)

Goal: propose the two representative hosts for the Story 1.4 portability proof.
Selection law (frozen AC-3):

- PRIMARY: the current always-on remote host if it carries meaningful
  legacy/stale agent-flow-kit state; otherwise the stalest qualifying active host.
- SECOND: a distinct remote Orca host with evidence of at least TWO material
  differences vs the primary in: revision age, installation layout, harness
  state, target wiring, Orca configuration, path layout, or naturally
  available OS.
- One host is expected to be macOS. The laptop (inference host) is OUT OF
  SCOPE and must be excluded even if visible.

Observation surface — READ-ONLY, bounded:
- The Orca CLI is `orca-ide`. Useful read-only calls: `orca-ide status --json`,
  `orca-ide worktree list --json`, `orca-ide terminal list --json`, and any
  read-only listing of connected servers / saved environments the CLI offers
  (check `orca-ide --help` and subcommand help; remote workers use
  `--on <saved-environment>`, so a saved-environment listing likely exists).
- Local Orca configuration under `~/.config/orca/` may name known
  hosts/environments — read, never modify.
- You may NOT: ssh anywhere, mutate any Orca state, create/close terminals or
  worktrees, run agent-flow-kit lifecycle commands against any host, or
  retain any credential value, token, or secret in your output.

Deliverables (create the dir):
`_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.4-FLEET-DISCOVERY/`
- `candidates.json` — every observed candidate host: identifier, reachability,
  OS/arch if observable, Orca connection kind, and whatever
  revision/layout/harness facts were observable from here, each fact tagged
  with its provenance (which command/file showed it).
- `PAIR-PROPOSAL.md` — the recommended pair, the representativeness dimensions
  satisfied (which ≥2 material differences, with evidence pointers), what
  could NOT be observed from this host, and what the coordinator must verify
  on-host during baseline capture.

If fleet visibility from this host is insufficient to propose a pair, say
exactly that: report what was observable, what is missing, and what access
would be needed. Do NOT guess or invent hosts.

## Hard rules

- Strictly read-only outside your evidence directory.
- Do not read or act on any Story 1.5, 1.6, 1.7, or 1.8 material.
- No git operations, no lifecycle mutations, no secrets in output.

## Completion

Report via the injected Orca worker_done mechanism: outcome `succeeded` if the
deliverables exist (a well-supported pair proposal OR a precise
insufficient-visibility report), else `failed`. Body: the proposed pair (or the
visibility gap) in five lines or fewer + evidence paths.
