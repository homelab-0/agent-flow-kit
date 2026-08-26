# AFK-PORT-1.1 Routed Execution Blocker

Current reason code: `RESOLVED`

Cleared reason code: `HOST_DISPATCH_PREREQUISITES_MISSING`

Observed: 2026-08-24 on the current Orca development host.

## Required chain

Four-axis classification → central `POST /v1/route` → accepted immutable stamp → final validation → fresh Orca-visible worker.

## Evidence

- Story and route request were prepared without selecting a harness or model locally.
- `make-stamp.sh --request ... --check` failed closed before network access: `AGENT_ROUTER_TOKEN` was empty.
- A fresh Orca-visible terminal performed presence-only checks and reported:
  - `ROUTER_TOKEN=absent`
  - `VALIDATOR=absent`
  - `CATALOG=absent`
- No secret value was read or printed.
- No stamp was created.
- No worktree or worker was dispatched.
- No direct Claude/Codex launch, local routing-table fallback, stamp mutation, or provider substitution was attempted.
- The host's approved untracked secret bootstrap (`~/.op-agent-env`) is present and exposes only `OP_SERVICE_ACCOUNT_TOKEN`; variable names were inspected without reading values.
- The 1Password service account is usable, but its accessible `develop` vault contains no item or field reference for `AGENT_ROUTER_TOKEN` or agent-router credentials.
- No environment, environment.d file, or system/user service configuration on the host provides an established `AGENT_ROUTER_TOKEN` injection path.
- The repository search found no local prox-ops checkout or trusted installed `agent-stamp-validate` artifact/catalog. Provisioning these was not attempted after the credential prerequisite proved owner-blocked.

## Bootstrap resolution

- Owner provisioned the existing authorized caller credential as the concealed `credential` field of 1Password item `develop/caller-token`.
- The token was injected only into child-process environments through the approved 1Password mechanism; presence was verified without displaying or persisting its value.
- Authenticated `GET /v1/status` returned HTTP 200.
- `agent-stamp-validate` was built without source changes from prox-ops commit `0e16ab57a3fcf99a8c69b86e19a4d8b26b57f2e9` and installed at `~/.local/bin/agent-stamp-validate`.
- The exact catalog document was extracted from that commit's Git-managed ConfigMap data and installed at `~/.local/share/agent-flow-kit/catalogs/agent-router-1.3.0.yaml`.
- Local and live catalog versions matched: `sha256:2fd681e0e988bf6be94b8923b1485a0aa174a4e66aec580a2d383c764b60e229`.
- Validator contract checks passed: valid fixture exit 0 with all eight checks passing; known policy-invalid fixture exit 1; malformed input exit 2.
- Orca status remained healthy.

`HOST_DISPATCH_PREREQUISITES_MISSING` is therefore cleared.

## Current routing blocker

The preserved, unchanged `AFK-PORT-1.1.route-request.json` was submitted to central `POST /v1/route`. The router returned HTTP 409:

- code: `no_eligible_profile`
- obligation: `re-plan`
- meaning: no approved harness/model-profile pairing satisfies the request against the current catalog.

No stamp was minted and no worker was launched. The PM did not relax constraints, select a harness/model/profile, edit the catalog, or use a fallback.

### Eligibility-layer diagnosis

The preserved request carries:

- `ambiguity: medium`
- `blast_radius: high`
- `context_size: 32000`
- `tags: [security, tests]`
- `touched_paths: [bin/agent-flow-kit, lib/, docs/, tests/lifecycle-tests.sh, tests/run-tests.sh]`
- `volume_hint: low`
- no explicit `placement_policy` (the router would resolve the catalog default only after profile eligibility)

`blast_radius: high` selects the router's strong band. The selectable strong-band pairs are `claude/strong` and `openai/strong`; both currently declare `min_context: null`. The routing contract states that a profile with a null guarantee cannot satisfy any explicit `context_size`. Therefore `context_size: 32000` eliminates both selectable strong candidates. `minimax/strong` is independently non-selectable. The security/tests tags do not forbid the two selectable strong profiles, and physical placement is not consulted at this stage.

No frozen Story 1.1 acceptance criterion or requirement specifies a 32,000-token minimum execution context. The value is therefore an over-conservative planning estimate, not a genuine minimum-context requirement. A valid re-plan may correct that inaccurate metadata; it must not lower or remove a genuine task requirement merely to force a route.

### Authorized re-plan

The owner authorized a new request artifact, `AFK-PORT-1.1.route-request.replanned.json`, which omits `context_size` and changes no genuine task signal. Absence means Story 1.1 has no known hard context-floor requirement. This corrects inaccurate planning metadata in response to the router's explicit `re-plan` obligation; it does not weaken a product or safety requirement.

The original request and its HTTP 409 outcome remain retained as evidence.

## Previous owner action — completed

Create or authorize an existing router caller credential in the owner's approved secret store and expose it to the Orca worker environment as `AGENT_ROUTER_TOKEN`, without placing the value in tracked files, lifecycle state, BMAD artifacts, or evidence.

After that owner action, provisioning may continue with:

1. a compatible existing `agent-stamp-validate` executable,
2. `AGENT_STAMP_VALIDATE_CATALOG_PATH` pointing to the trusted catalog document,
3. authenticated `/v1/status` and local-catalog provenance matching, and
4. the preserved route request at `AFK-PORT-1.1.route-request.json`.

After those prerequisites exist, rerun the existing route request, inspect/accept the natural recommendation, mint the immutable stamp, and dispatch Story 1.1 visibly through Orca.

This blocker is a host provisioning prerequisite. It is not a PRD amendment and not the final portability verdict.

No credential was minted, copied from another host, displayed, logged, or persisted by this inspection.

## Historical resolution requirement

Routing authority required the request to be re-planned or the authoritative catalog/policy to change. The owner subsequently authorized the bounded metadata correction recorded below.

## Resolution result

The owner authorized correcting the inaccurate planning-only `context_size` metadata by omitting it in a separately retained replanned request. Central `/v1/route` naturally returned `claude / claude/strong / high`, subscription-backed and non-metered, with `placement_required: false` and no override. The immutable stamp passed all eight final checks immediately before launch. Orca created visible terminal `term_295c39d1-7e05-42a7-8f0c-1b3a6406d91b`; cycle 1 exited successfully and the dispatcher independently passed all three frozen gates.

The prior routing blocker is resolved. The original request, replanned request, immutable stamp, worker result, and dispatcher result remain retained.
