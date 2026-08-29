# Worker brief — AFK-PORT-1.4-M1-PRIMARY-BASELINE (fresh codex session)

You are a dispatched WORKER under Orca supervision. Route/stamp:
`_bmad-output/implementation-artifacts/AFK-PORT-1.4-M1-PRIMARY-BASELINE.stamp.json`.

## Persona (fail-closed)

Activate the BMAD DEV persona from `.agents/skills/bmad-agent-dev/SKILL.md` +
`customize.toml`; compute the persona proof first:

```
{ sha256sum .agents/skills/bmad-agent-dev/SKILL.md; sha256sum .agents/skills/bmad-agent-dev/customize.toml; } | sha256sum
```

Expected `07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee`;
mismatch = STOP and report failure.

## Task — PRIMARY host baseline + pre-mutation lifecycle inspection (AC-4, AC-5)

The PRIMARY portability host is THIS machine (the always-on devbox VM). Its
legacy installation is the canonical checkout at
`/home/devbox/repos/jlengelbrecht/agent-flow-kit` plus its installed state
(`~/.local/share/agent-flow-kit/`). You OBSERVE it; you mutate NOTHING there.

Evidence dir (create): `_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.4-M1-PRIMARY-BASELINE/`
(inside THIS story worktree, never inside the canonical checkout).

### 1. Host baseline (`baseline.json`, machine-readable, secret-free)

Capture with per-fact provenance (command or file that showed it):
host identity (hostname, virtualization if observable), OS + kernel + arch,
relevant path layout (canonical checkout path, installed-state dirs, story
worktree path, Orca workspace root), Git facts of the canonical checkout
(branch, HEAD SHA, dirty/untracked summary — counts and classes only, no
content), installed/applied kit revision (from the applied-state manifest if
present), ownership state, registered BMAD targets and wiring, harness
availability classifications (claude/codex present, auth MODE only — never
credential values), Orca runtime version + connection kind (this is a remote
Orca server; hub is a separate machine), validator presence
(`agent-stamp-validate` on PATH + catalog file identity/digest), router
endpoint reachability CLASS only (do not call authenticated endpoints),
observation timestamp (UTC), and `result_schema_version: "afk-port-1.4-baseline-v1"`.

### 2. Representativeness record (`representativeness.md`)

The selected pair and why, per frozen AC-3 (coordinator-supplied facts you must
record verbatim as coordinator-provenance, not verify):
- PRIMARY = this devbox VM: always-on remote Orca server carrying meaningful
  legacy/stale kit state — enumerate the observed staleness evidence (branch
  behind master, untracked tooling dirs, installed catalogs, etc.).
- SECOND = the Mac Orca server (macOS; ≥2 material differences: OS, path
  layout, install state; site of the signal-numbering observation).
- OBSERVED-NOT-SELECTED: a cachyos Orca server (placement data shows
  `cachyos-7900xtx` offline → not the always-on member; Linux like the
  primary → weaker second-host differentiation than the Mac).
- EXCLUDED by scope: the laptop (inference host); the bazzite PC (hub seat,
  not an always-on dev host).

### 3. Pre-mutation lifecycle inspection (AC-5) — read-only lifecycle surface

From the CANONICAL checkout (`cd /home/devbox/repos/jlengelbrecht/agent-flow-kit`),
run and capture raw JSON + exit status of each:
- `bin/agent-flow-kit status --json`      > `status.json`      (2> `status.stderr`)
- `bin/agent-flow-kit verify --json`      > `verify.json`      (2> `verify.stderr`)
- `bin/agent-flow-kit adopt --inspect --json` > `adopt-inspect.json` (2> `adopt-inspect.stderr`)

Then write `classification.md`: what the machine output truthfully classifies
for installed state, ownership, source eligibility, drift/adaptation, target
wiring, and readiness scopes — and one explicit verdict line:
`PRE-MUTATION AMBIGUITY: none` or `PRE-MUTATION AMBIGUITY: <exact items>`.
Any ambiguity you cannot ground in the JSON output IS ambiguity — report it,
do not resolve it. Quote reasons/states verbatim from the JSON; do not
paraphrase state names.

## Hard rules

- Read-only everywhere except your evidence directory. No lifecycle mutation
  (no adopt without --inspect, no update), no git writes anywhere, no secrets
  (values) in any output — auth/funding facts as MODE/CLASS words only.
- Do not read or act on Story 1.5–1.8 material.
- If a command errors, capture it verbatim and continue where independent;
  the classification must then list the gap.

## Completion

`worker_done` via the injected mechanism, using ONLY the flags the preamble
grammar supplies (keep your --dispatch-capability token; append --json and
verify ok:true + a message id before ending). Outcome `succeeded` iff all
three deliverable sets exist and the persona proof matched; the AMBIGUITY
verdict line goes in the body verbatim.
