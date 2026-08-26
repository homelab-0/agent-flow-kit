---
linear:
stamp: _bmad-output/implementation-artifacts/AFK-PORT-1.1.md.stamp.json
persona: dev
gates:
  - "bash tests/lifecycle-tests.sh"
  - "bash tests/run-tests.sh"
  - "git diff --check"
max_cycles: 3
---

### Story 1.1: Understand Installed State Safely

As an agent-flow-kit fleet operator,
I want a deterministic read-only lifecycle foundation that explains installed ownership, revision, adaptation, drift, and source eligibility,
So that I can understand a legacy or managed host without mutating or trusting ambiguous state.

**Acceptance Criteria:**

**Given** a canonical agent-flow-kit checkout
**When** the lifecycle entrypoint evaluates it
**Then** it identifies the repository deterministically, records the exact checkout revision, validates lifecycle/state schema compatibility, and distinguishes eligible from ineligible mutation sources
**And** uncommitted managed inputs, unexpected revisions, downgrade conditions, unknown schemas, and noncanonical source selection receive stable states and reason codes without changing Git.

**Given** an installed revision that verifies as healthy and a checkout that is ineligible as an update source
**When** status runs
**Then** installed and execution integrity remain independently reportable as healthy
**And** mutation-source eligibility is blocked with its own stable reason without changing installed readiness to `BROKEN` or `NOT_READY`.

**Given** an installed or legacy host
**When** read-only status runs
**Then** it inventories every known component, registered BMAD target, canonical revision, applied/adopted revision, ownership class, integrity identity, and adaptation record
**And** it classifies current, update available, local adaptation, local drift, unknown/legacy, broken, source ineligible, interrupted, unavailable, incompatible, and not-evaluated states only where deterministically knowable from local evidence.

**Given** a network- or authentication-dependent fact such as current router or native provider-session availability
**When** default status runs without explicit live evaluation
**Then** the fact reports `NOT_EVALUATED` with reason `LIVE_PROBE_NOT_REQUESTED`
**And** status performs no router, provider-authentication, or other external live probe.

**Given** machine-, project-, user-, or native-runtime-owned state
**When** status compares hosts or canonical content
**Then** declared local differences are classified as legitimate adaptation or external state
**And** no heuristic or LLM judgment is used.

**Given** a variation inside otherwise kit-owned territory
**When** no valid registered adaptation matches its component, location, expected shape, and disposition
**Then** the variation is `LOCAL_DRIFT`
**And** a stale adaptation record cannot legitimize it.

**Given** an unknown or legacy installation
**When** inspect-only adoption analysis runs
**Then** it reports only `AUTO_ADOPTABLE`, `APPROVAL_REQUIRED`, or `REFUSED` as applicable
**And** no manifest is created, no revision advances, no ownership claim becomes durable, and no shared/global content changes until Story 1.2 completes a successful adoption transaction.

**Given** a managed destination path
**When** the lifecycle reads or hashes it
**Then** path type, containment, and symlink boundaries are validated
**And** unexpected redirection outside declared ownership fails closed.

**Given** status is run repeatedly
**When** no external state changes
**Then** filesystem, Git, runtime, authentication, router, and orchestration state remain unchanged
**And** normalized results are stable.

**Given** machine-readable output is requested
**When** status completes
**Then** it emits a documented versioned schema derived from the same normalized model as human output
**And** automation can distinguish state, reason, ownership, severity, blocked scope, mutation safety, owner action, evidence provenance, expected/observed identifiers, and not-evaluated versus unavailable without parsing prose.

**Given** lifecycle output or installed-state metadata is produced
**When** authentication or local configuration is inspected
**Then** no secret value, credential content, authorization header, or arbitrary user-owned content is emitted or persisted
**And** an anti-vacuity test proves a known sentinel secret would reach the result path without redaction but never appears in emitted output.

**Given** the Story 1.1 implementation
**When** its isolated deterministic gates run
**Then** tests cover repository identity, clean and dirty managed inputs, legacy recognition, every ownership/state branch, registered-adaptation validation, malformed schemas, path/symlink escape, side-effect-free repeated status, healthy installed state with dirty source, router not probed, repeated auto-adoptable analysis without mutation, secret-redaction anti-vacuity, JSON schema stability, and coarse exit semantics
**And** existing frozen orchestration tests remain green.

**Requirements covered:** FR-1–21, FR-24, FR-29–35, FR-72–84, FR-91, FR-93–94; NFR-1–12 where applicable.

## Implementation Constraints

- Frozen PRD: _bmad-output/planning-artifacts/prds/prd-agent-flow-kit-2026-08-24/prd.md
- PR #5 is a donor/reference only; use reconcile-pr5.md as the migration map.
- Work from canonical master in this fresh story worktree.
- Do not broaden into router, catalog, prox-ops, Kubernetes, GPU, or control-plane product work.
- Do not weaken a frozen requirement to fit donor code or a bounded retry cycle.

## Dev Agent Record

- Status: **FROZEN — IMPLEMENTED + VERIFIED.** The one cycle-2 containment
  reason-code failure was corrected at its root. The cycle-3 dispatcher then
  independently passed `bash tests/lifecycle-tests.sh`,
  `bash tests/run-tests.sh`, and `git diff --check`.

## Cycle 3

### The defect

`tests/lifecycle-tests.sh:307` — `guard: an unresolvable declared boundary fails
closed`:

```sh
afk_path_guard "$U/tree/a.txt" file "" "$U/no-such-container"
```

Expected `PATH_BOUNDARY_UNRESOLVABLE`, observed `PATH_PARENT_ESCAPES_BOUNDARY`.

### Root cause

`afk_realpath` is deliberately lenient about a path whose FINAL segment does not
exist: it canonicalises the parent chain with `cd -P` and appends the basename.
That leniency is correct for a **destination** — a managed destination is
legitimately allowed to be absent, and its containment still has to be judged
before `PATH_ABSENT` means anything — but `afk_path_guard` was using the same
function to resolve a **boundary**.

So a declared boundary that did not exist resolved "successfully" to a
synthesized path, and every real destination then failed the `afk_is_within`
comparison against it. The guard reported `PATH_PARENT_ESCAPES_BOUNDARY`: it
blamed the destination for being redirected when the actual fact was that the
declared territory was not there at all. Two distinct facts collapsed into one
reason code, and the one it collapsed into was the wrong one — it accuses the
host of a redirection that never happened.

This is the Story 1.1 semantic defect the cycle-2 record classified it as, not a
test expectation to relax: FR-93 fails closed either way, but the stable reason
code is the part automation acts on, and "your path was redirected" and "your
declared boundary does not exist" call for different owner actions.

### The correction

`lib/afk-common.sh` gains `afk_resolve_boundary`, the boundary-side counterpart
to `afk_realpath`:

```sh
afk_resolve_boundary() { # <declared-boundary>
  local resolved
  resolved="$(afk_realpath "$1")" || return 1
  [[ -d "$resolved" ]] || return 1
  printf '%s\n' "$resolved"
}
```

A declared ownership boundary is territory, not a destination: it has to resolve
to an **existing directory** before anything can be proven to sit inside it. A
boundary that is absent, or that resolves to a regular file (which contains
nothing), is `PATH_BOUNDARY_UNRESOLVABLE`. Only a boundary that resolves can be
escaped, so `PATH_PARENT_ESCAPES_BOUNDARY` now means exactly what it says.

`afk_path_guard` uses it for BOTH boundaries — the container root the
destination must live under and the target root a link may point into — because
both are declared territory and both carry the same reason code. Both are
resolved before either is compared against, so an unprovable boundary can never
be mistaken for a destination that escaped one.

The `PATH_BOUNDARY_UNRESOLVABLE` message text is sharpened to "...could not be
resolved to an existing directory...". The reason-code vocabulary itself is
unchanged, so the `schema` ↔ contract element-for-element comparison in the gate
is unaffected.

### Blast radius, checked statically

Every call site of `afk_path_guard` was re-read and every boundary it can be
handed was traced:

| Call site | Boundaries | Effect |
|---|---|---|
| `afk-inventory.sh:139` (state manifest) | `afk_state_boundary` → the declared state dir, or the manifest's own parent | Reached only when the manifest path exists, so the boundary is an existing directory. Unchanged. |
| `afk-inventory.sh:217` (operation journal) | same | Same. Unchanged. |
| `afk-inventory.sh:465` (components) | declared `container_root` / `target_root` | See below. |
| `afk-commands.sh:267` (adoption analysis) | same declared roots | Same as components. |

`PATH_ABSENT` is tested before any boundary is resolved, so a destination that
does not exist still short-circuits and a pristine host is untouched by this
change. For the six components whose container and target roots are the same
declared root, an existing destination implies an existing root, so nothing
moves.

The one component whose target root lives in a different tree from its
destination is `model-router-claude-link` (`$AFK_CLAUDE_HOME/skills/model-router`
pointing into `$AFK_SKILLS_HOME`). If the skills home is absent while the link
exists, this now reports `PATH_BOUNDARY_UNRESOLVABLE` where it previously
reported `PATH_UNRESOLVABLE_SYMLINK` (the dangling link failed a step later) or,
where `~/.agents` existed but `~/.agents/skills` did not, `PATH_OK` on a link
into territory that is not there. Both are `BROKEN`, both fail closed, and the
new code is the more accurate of the two: the boundary is what cannot be proven.
No scenario in the gate exercises that host shape — `install_kit` always creates
`.agents/skills` — so no existing assertion depends on either old answer.

The two assertions that pin the distinction from both sides
(`tests/lifecycle-tests.sh:303-308`) now both hold: `$U/container` exists and is
escaped by a symlinked parent → `PATH_PARENT_ESCAPES_BOUNDARY`;
`$U/no-such-container` does not exist → `PATH_BOUNDARY_UNRESOLVABLE`. Every other
direct `afk_path_guard` call in the gate (lines 283-306) passes an empty boundary
or an existing directory, and the end-to-end scenario at line 1301 (`.claude/skills`
moved out and symlinked) keeps a real `.claude` container, so it still resolves and
still reports the parent escape.

### What was deliberately not changed

- **`tests/lifecycle-tests.sh`** — the failing assertion already encoded the
  correct contract, and its neighbour at line 304 already pins the opposite
  case, so the distinction is falsifiable from both directions without new
  assertions. The `-d` predicate is exercised true by every passing scenario and
  false by line 308; a boundary that exists as a regular file takes the same
  predicate, not a separate branch. Rewriting a 1,700-line gate by hand to add a
  redundant assertion is transcription risk against a suite that currently
  proves 439 other things.
- **`docs/LIFECYCLE-CONTRACT.md`** — the containment section already states that
  "an unresolvable path, parent or boundary fails closed rather than being read"
  and lists both codes in its `machine-checkable` block. The prose was accurate
  before this change and is accurate after it, and the vocabulary the gate
  compares element-for-element is untouched.
- Everything else: no mutation surface, no live readiness, no router, catalog,
  prox-ops, Kubernetes, GPU or control-plane work. `update` and `verify` still
  refuse rather than partially implement, so the Story 1.2 and 1.3 boundaries
  stay intact.

### Cycle 3 diff size

One file, `lib/afk-common.sh`: one new six-line function, two call-site
substitutions inside `afk_path_guard`, one reason message sharpened, and the
comments that explain why `afk_realpath` and `afk_resolve_boundary` are
different functions. Roughly 25 changed lines. Well inside the reviewable
budget; the cycle-1/2 total for the whole story is recorded below and unchanged.

### Cycle 3 gates

**Not run by this session.** This worker was launched with the least-privilege
tool set (`Read,Glob,Grep,Write`) and has no shell, so
`bash tests/lifecycle-tests.sh`, `bash tests/run-tests.sh` and
`git diff --check` could not be executed here. The dispatcher re-runs them
independently after this session exits; that run is the arbiter, not this
record.

What was verified statically instead:

- Every `afk_path_guard` call site and every boundary value reachable at it, as
  tabled above.
- Every direct `afk_path_guard` assertion in the gate re-read against the new
  behaviour.
- No test or document pins the `PATH_BOUNDARY_UNRESOLVABLE` message text
  (grepped); the gate compares reason-code LISTS, which are unchanged.
- No trailing whitespace introduced (grepped `[ \t]+$` over the file), so
  `git diff --check` has nothing new to find. `lib/` is untracked at the time of
  writing, so that gate covers `README.md` and `tests/run-tests.sh`, neither of
  which this cycle touched.
- `afk_resolve_boundary` assigns to a `local` on its own line rather than in the
  declaration, so the section-0 shellcheck pass (`--severity=warning`, `SC2034`
  and `SC2154` excluded) has no new finding to raise.

Expected result: `tests/lifecycle-tests.sh` 440 passed, 0 failed — the same 439
as cycle 2 plus the previously failing containment assertion.

### Cycle 2 gate evidence

- `tests/lifecycle-tests.sh`: **439 passed, 1 failed**.
- Failing assertion: `guard: an unresolvable declared boundary fails closed`.
- Expected stable reason: `PATH_BOUNDARY_UNRESOLVABLE`.
- Observed stable reason: `PATH_PARENT_ESCAPES_BOUNDARY`.
- Classification: **Story 1.1 semantic defect** (path/containment classification).
- Required correction: preserve the distinction between an unresolvable declared
  boundary and a resolvable boundary escaped by a destination parent; rerun the
  lifecycle and aggregate gates without expanding into mutation or live readiness.

### Implementation artifacts

| Path | Role |
|---|---|
| `bin/agent-flow-kit` | The single lifecycle entry point. `status`, `adopt --inspect`, `schema`; `adopt` without `--inspect`, `update` and `verify` are recognized and refuse rather than silently no-op. Options are validated per command; missing libraries and an undeclared HOME fail with stable messages. |
| `lib/afk-common.sh` | Primitives: bounded content identity (file/tree/section), portable realpath, declared-boundary resolution, path type/containment/parent-chain guards, managed-section extraction, the redaction boundary, the published reason vocabulary, the normalized result model, and the human renderer projected from it. |
| `lib/afk-source.sh` | Repository identity (root commit + a COMPLETE `lifecycle/kit.json`) and mutation-source eligibility. All read-only Git, `--no-optional-locks` where supported. |
| `lib/afk-inventory.sh` | The declared component/ownership/boundary table, state-manifest shape validation, the operation journal, registered-adaptation binding rules, and deterministic component classification. |
| `lib/afk-commands.sh` | Command surface: shared read-only evaluation, readiness scopes, live-fact placeholders, environment records, inspect-only adoption analysis (including history-based recognition), result validation and exit-code emission. |
| `lifecycle/kit.json` | The source declaration: kit identity, lifecycle/state schema versions, canonical branch, managed input set. |
| `docs/LIFECYCLE-CONTRACT.md` | The documented versioned machine contract. Every vocabulary now appears in a `machine-checkable` block that the gate compares element-for-element against `schema`. |
| `tests/lifecycle-tests.sh` | The isolated deterministic gate (14 sections). |
| `tests/run-tests.sh` | The aggregate gate: existing orchestration suite, plus lifecycle shellcheck (section 0) and the lifecycle gate (section 6). |
| `README.md` | Contents index, "Understanding a host", and the exit-code contract. |

### Cycle 2: how each review finding was addressed

1. **Exit-code contract restored** — `lib/afk-common.sh` now defines `0` success,
   `1` command/internal/usage, `2` owner action, `3` deterministic not-ready,
   `4` source/precondition refusal, `5` live unavailable. The codes are passed
   into the result assembler as arguments rather than hard-coded in jq, published
   through `schema`, documented in the contract, echoed in `--help` and the
   README, and asserted end to end in gate section 13.
2. **`lifecycle/kit.json` validated as a complete shape** — `kit_id`,
   `lifecycle_schema_version`, `state_schema_version`, `default_branch` and a
   non-empty `managed_inputs` of relative, newline-free, non-`..` paths. Missing
   or malformed → `SOURCE_DECLARATION_INCOMPLETE` / `SOURCE_DECLARATION_UNREADABLE`,
   both blocking. A lifecycle schema major that differs in EITHER direction is
   now incompatible.
3. **Managed inputs are an array end to end** — read into a bash array, passed to
   Git as separate pathspecs, emitted as a JSON array. A declared path containing
   a space stays one path (proven by a scenario that dirties it).
4. **Unreadable canonical identities are never `CURRENT`** — new
   `CANONICAL_IDENTITY_UNREADABLE`: matching the applied identity proves nothing
   when the canonical side could not be opened. Adoption refuses such a component
   instead of promoting it to "needs approval".
5. **Complete manifest shape validated before adoption is believed** —
   `applied_revision` (40 hex), `repository.identity`, every component's
   `identity`/`ownership`/`path`, `adaptations`, `targets`. Failure is
   `STATE_MANIFEST_SHAPE_INVALID`, owner-action, never adopted. Ten malformed
   shapes are covered.
6. **Adaptations are bound tightly enough to be falsifiable** — unique `id`,
   declared component, the type its ownership class can have, that component's
   declared location (`<dest>` or `<dest>#<section-id>`), a well-formed
   `expected_identity`, and a supported disposition. Four new reason codes.
7. **Containment and type guards on parent chains and kit state** — the guard now
   resolves the parent chain against a declared container root, so a symlinked
   parent directory fails closed; the manifest and journal paths are guarded the
   same way, and an unexpected/unreadable journal is `INTERRUPTED`, not "no
   journal".
8. **Tree identities fail on unreadable members and encode names** — a failed
   scan or unreadable member yields NO identity (the component is
   `IDENTITY_UNREADABLE`), filenames and link targets are reversibly encoded so a
   newline cannot forge a record, and exclusions are matched by exact string
   equality rather than word splitting or globbing.
9. **Adoption honours source eligibility and recognizes prior canonical trees** —
   an ineligible source refuses with `ADOPTION_SOURCE_INELIGIBLE`; recognition
   walks the full reachable history for files, sections AND managed copy trees,
   with no revision cutoff. Historical tree identities are computed from Git
   objects using the same record format as the installed side, and the walk
   terminates on distinct object identity rather than a count.
10. **Entry point hardened** — per-command option validation, `--dry-run` removed,
    caller-supplied text echoed only when it is in the closed command/option
    vocabulary, missing libraries and an undeclared HOME normalized to stable
    messages and exit 1.
11. **Result assembly is validated before it is trusted** — assembly failure and
    any document that does not present the published shape are internal failures
    (exit 1); the exit code is checked against the frozen set before it is
    returned or anything is rendered.
12. **The vocabulary is published and machine-checked** — `schema` emits the
    complete reason-code list, adaptation types/states and exact exit meanings;
    the contract document carries the same lists in `machine-checkable` blocks;
    the gate compares them element-for-element, and separately proves every code
    carries a specific message and action rather than a fallback string.
13. **Side-effect proofs strengthened** — the fingerprint now covers directories,
    permission bits and ownership as well as content; Git refs, reachable objects,
    HEAD and porcelain status are asserted; a first-ever run on a pristine host is
    checked on its own; every declared root plus the state directory is covered.
14. **Redaction anti-vacuity broadened** — every reported variable is proven to
    reach the result path unredacted and to be redacted by the shipped redactor;
    each secret source is also checked alone; human, machine, usage-error,
    unknown-command, missing-library and undeclared-HOME paths are all checked;
    evidence values are asserted bounded and single-line.
15. **Projection and vocabulary equality are proven, not sampled** — every
    component, finding, target, readiness scope, live fact, environment name and
    header field in the document is asserted present in the human rendering, for
    both `status` and `adopt --inspect`.
16. **Missing branches covered** — absent managed inputs, divergent revisions,
    unexpected in-boundary link targets, symlinked parent directories, malformed
    journal paths/types, adaptation location/type/shape/duplicate mismatches, an
    unreadable managed member, and an older-major source schema.
17. **Gates aggregated** — `tests/run-tests.sh` now shellchecks the lifecycle
    scripts and runs the lifecycle gate in its own process as section 6, with the
    existing orchestration suite untouched.

### Design decisions worth reviewing

- **Repository identity is the checkout's root commit plus a complete, readable
  `lifecycle/kit.json`.** Directory naming is explicitly not evidence, and a test
  builds an impostor directory literally named `agent-flow-kit` to prove it.
- **A declared boundary must resolve to an existing directory; a destination need
  not.** `afk_realpath` stays lenient about an absent final segment because a
  managed destination is allowed to be absent, and `afk_resolve_boundary` is
  strict because territory that is not there cannot contain anything. Keeping
  them as two functions is what keeps `PATH_BOUNDARY_UNRESOLVABLE` and
  `PATH_PARENT_ESCAPES_BOUNDARY` distinct facts.
- **Source eligibility never feeds `INSTALLED_INTEGRITY`.** Source findings carry
  `blocked_scopes: ["MUTATION_SOURCE"]` only, and the gate asserts that property
  over all source findings rather than spot-checking one. Adoption is the one
  place eligibility is a precondition — it records a canonical revision — and it
  says so with its own reason code.
- **Human output is projected from the emitted JSON document**, and the gate
  proves the projection is complete rather than sampling three substrings.
- **No timestamps anywhere in the result.** Status is a pure function of local
  state, which is what makes byte-identical repeat output assertable.
- **The redactor is indirected through `AFK_REDACT_FN`, assigned unconditionally
  at source time**, so an exported variable cannot select a bypass while a sourced
  test can substitute an identity redactor and prove the sentinel really does
  reach the result path.
- **Caller-supplied text is echoed only from a closed vocabulary.** A credential
  mistyped onto the command line is shape-indistinguishable from a typo, so
  unknown arguments are replaced with a placeholder and the usage text carries
  the actual information.
- **Contracted normalization** for section payloads: a missing final newline and
  trailing blank lines do not move the identity, applied identically to both sides
  of every comparison. Nothing else about the bytes is normalized.
- **`set -e` is deliberately not used** in the lifecycle scripts: a half-built
  normalized result is exactly the "claimed" state the product exists to refuse.
  Failures are reported through exit status and stable reason codes — and the
  result is now validated before it is printed or turned into an exit code.

### Gates (cycle 2 record)

**Not run by that session** either, for the same least-privilege reason.

What the gate output should be read against:

- `tests/lifecycle-tests.sh` builds throwaway Git checkouts and throwaway `HOME`s
  under `mktemp -d` and touches no real host state. It needs `git`, `jq`, `find`,
  `sed`, `grep`, `awk`, `wc`, `tr`, `sort`, `readlink`, `comm` and `sha256sum`
  (or `shasum`).
- `tests/run-tests.sh` sections 0–5 are unchanged in behaviour; section 0 gains a
  second shellcheck loop over `bin/agent-flow-kit` and `lib/afk-*.sh`, and a new
  section 6 runs the lifecycle gate in a separate process. The lifecycle scripts
  are checked at `--severity=warning` with `SC2034,SC2154` excluded: the four
  files are always sourced together and share one result model, so a variable
  assigned in one and read in another looks unused or unassigned to a single-file
  analysis. That exclusion is a structural fact, not a way to quiet a real
  finding — and `set -u` in the entry point is the real guard.
- `git diff --check` covers whitespace in tracked changes. `README.md` and
  `tests/run-tests.sh` are the tracked files this story modified; everything else
  under `bin/`, `lib/`, `lifecycle/`, `docs/` and `tests/lifecycle-tests.sh` is
  new.
- `bin/agent-flow-kit` was created by a tool that cannot set the executable bit.
  It is invoked as `bash bin/agent-flow-kit` throughout the tests and the README.
  `chmod +x bin/agent-flow-kit` is a one-line follow-up that changes no behaviour.

### Findings and resolutions

- **The exit-code renumbering is a behaviour change**, and it is the one place
  where cycle 2 followed the review over the previous implementation. FR-77
  fixes the classes and their coarseness but assigns no numbers, so both
  numberings satisfied the frozen requirement; the review named a specific
  mapping, so that mapping is now implemented, published and asserted in one
  place each. If the reviewer's mapping was itself a mistake, this is the change
  to revisit — nothing else depends on the numbers.
- Adoption now inherits source eligibility. That is a deliberate reading of
  FR-35: the two dimensions stay independent in REPORTING (installed integrity
  keeps its own state and its own scope), but an adoption that records a
  canonical revision cannot be performed from a checkout that is not eligible to
  be one.
- Adaptation records in the manifest now require `type` and a declared
  `location`; records written against the cycle-1 shape (component + free-form
  location, no type) are `INVALID` rather than silently honoured. Nothing has
  written such a record yet — the adoption transaction that would is Story 1.2 —
  so there is no migration to perform, but it is a contract change worth noting.
- Scope held across all three cycles: no router, catalog, prox-ops, Kubernetes,
  GPU or control-plane work. `update` and `verify` are still refused rather than
  partially implemented, so the Story 1.2 and 1.3 boundaries stay intact.

### Final diff size

Cycle 2 rewrote `lib/afk-common.sh`, `lib/afk-source.sh`, `lib/afk-inventory.sh`,
`lib/afk-commands.sh`, `bin/agent-flow-kit`, `docs/LIFECYCLE-CONTRACT.md`,
`tests/lifecycle-tests.sh` and `README.md`, and added two sections to
`tests/run-tests.sh`. Cycle 3 changed ~25 lines of `lib/afk-common.sh` only.

The whole story is roughly 4,200 lines new plus ~60 changed in the existing
suite — well above the 800-line reviewable budget, as recorded in cycle 1. The
reviewable surface still splits cleanly along the file boundaries (primitives →
source eligibility → inventory/classification → command surface → contract →
gate), and a stacked chain in that order would keep each layer independently
reviewable if the PM wants it split.

### Review Findings

- [x] [Review][Patch] Restore the frozen lifecycle exit-code contract: `1` usage/internal, `2` owner action, `3` deterministic not-ready, `4` source/precondition refusal, `5` live unavailable [lib/afk-common.sh]
- [x] [Review][Patch] Validate `lifecycle/kit.json` as a complete recognized shape and reject missing/older-incompatible schema, default branch, or managed-input declarations [lib/afk-source.sh]
- [x] [Review][Patch] Preserve managed-input paths as an array so whitespace cannot corrupt pathspecs, inventory output, or dirty-source detection [lib/afk-source.sh]
- [x] [Review][Patch] Treat missing or unreadable canonical source identities as broken/unverifiable rather than `CURRENT` or approval-eligible [lib/afk-inventory.sh]
- [x] [Review][Patch] Validate the complete installed-state manifest shape before treating it as adopted or interpreting older-schema fields [lib/afk-inventory.sh]
- [x] [Review][Patch] Bind registered adaptations to unique IDs, required type, declared location/section, expected shape, and disposition before they can legitimize drift [lib/afk-inventory.sh]
- [x] [Review][Patch] Apply containment/type guards to parent-symlink traversal, manifest and journal paths, and unexpected/broken journal path types before reading [lib/afk-common.sh]
- [x] [Review][Patch] Make tree identities fail on unreadable members and encode filenames, targets, and exclusions without newline or whitespace ambiguity [lib/afk-common.sh]
- [x] [Review][Patch] Make inspect-only adoption honor source ineligibility and recognize provable prior canonical managed-copy trees without an arbitrary 50-revision correctness cutoff [lib/afk-commands.sh]
- [x] [Review][Patch] Reject command-incompatible options, remove the undocumented `--dry-run` alias, redact caller-controlled usage diagnostics, and normalize missing-library/HOME failures [bin/agent-flow-kit]
- [x] [Review][Patch] Validate normalized-result assembly success and JSON shape before rendering or returning its exit code [lib/afk-commands.sh]
- [x] [Review][Patch] Publish the complete stable reason-code vocabulary and exact exit meanings through `schema`; align documentation vocabularies and clarify offline `verify` belongs to Story 1.2 [docs/LIFECYCLE-CONTRACT.md]
- [x] [Review][Patch] Strengthen read-only side-effect proofs to detect empty directories, modes/metadata, Git metadata, first-run effects, and all declared roots [tests/lifecycle-tests.sh]
- [x] [Review][Patch] Strengthen redaction anti-vacuity across executable success/error paths, human/machine output, individual secret sources, and bounded hash evidence [tests/lifecycle-tests.sh]
- [x] [Review][Patch] Prove complete human/JSON projection and exact schema/document vocabulary equality rather than substring samples [tests/lifecycle-tests.sh]
- [x] [Review][Patch] Add missing branch coverage for missing managed inputs, divergent revisions, unexpected in-boundary link targets, parent symlinks, malformed journal paths, and adaptation location/type mismatch [tests/lifecycle-tests.sh]
- [x] [Review][Patch] Integrate lifecycle tests and shellcheck into the canonical aggregate gate while preserving the existing orchestration regression suite [tests/run-tests.sh]
- [x] [Cycle 3][Gate] Keep an unresolvable declared boundary distinct from a resolvable boundary escaped by a destination parent: resolve boundaries through `afk_resolve_boundary`, which requires an existing directory [lib/afk-common.sh]
