# Pre-mutation lifecycle classification

All observations came from the canonical checkout at `/home/devbox/repos/jlengelbrecht/agent-flow-kit`. Commands were read-only; `adopt` was run only with `--inspect`.

## Probe results

| Probe | Exit | Machine classification |
|---|---:|---|
| `status --json` | 3 | Installed state is `UNKNOWN` / `INSTALLATION_NOT_ADOPTED`; `INSTALLED_INTEGRITY` is `NOT_READY`; mutation source is `FALSE` / `SOURCE_INELIGIBLE`. |
| `verify --json` | 3 | `manifest_present` is `FAIL` / `INSTALLATION_NOT_ADOPTED`; installation is `BROKEN` / `VERIFICATION_FAILED`; offline verification is not verified. |
| `adopt --inspect --json` | 2 | Adoption disposition is `REFUSED` / `ADOPTION_SOURCE_INELIGIBLE`; evidence is `SOURCE_DIRT_OUTSIDE_INPUT_SET,SOURCE_NONCANONICAL_BRANCH`; inspection performed no mutation and claimed no ownership. |

Raw stdout, stderr, and exit-status files accompany this record.

## Installed state and ownership

The applied-state manifest is absent. The machine reason is `INSTALLATION_NOT_ADOPTED`: “No agent-flow-kit state manifest exists, so no installed component has a proven owner or baseline.” Consequently the applied revision is unknown, durable ownership is unproven, and `ownership_claimed` is false.

Observed ownership classes are `MANAGED_COPY_TREE`, `MACHINE_LOCAL`, `MANAGED_LINK`, `MANAGED_SECTION`, `USER_OWNED`, and `MANAGED_COPY_FILE`. Component states include `UNKNOWN` / `NOT_ADOPTED`, `LOCAL_ADAPTATION` / `MACHINE_OWNED_REGION`, `UNKNOWN` / `MANAGED_SECTION_ABSENT`, and `EXTERNAL_STATE` / `USER_OWNED_REGION`.

## Source eligibility, drift, and adaptation

`MUTATION_SOURCE_ELIGIBLE` is `FALSE` with reason `SOURCE_INELIGIBLE`. The exact source findings are `ELIGIBLE` / `SOURCE_DIRT_OUTSIDE_INPUT_SET` and `SOURCE_INELIGIBLE` / `SOURCE_NONCANONICAL_BRANCH`.

The component comparison observes a model-router hash mismatch but classifies it `UNKNOWN` / `NOT_ADOPTED`, because no ownership baseline exists. The machine-local router configuration is `LOCAL_ADAPTATION` / `MACHINE_OWNED_REGION`. The lifecycle output contains no declared entries in `adaptations`; adoption inspection is `REFUSED`, did not advance an applied revision, did not create a manifest, and performed no mutation.

## Target wiring

The registered `targets` array is empty. The observed wiring components classify `model-router-claude-link` and `humanizer-claude-link` as `UNKNOWN` / `NOT_ADOPTED`; `claude-global-policy` as `UNKNOWN` / `MANAGED_SECTION_ABSENT`; the outside section as `EXTERNAL_STATE` / `USER_OWNED_REGION`; and `codex-global-guidance` as `UNKNOWN` / `NOT_ADOPTED`.

## Readiness scopes

- `INSTALLED_INTEGRITY`: `NOT_READY`.
- `MUTATION_SOURCE_ELIGIBLE`: `FALSE` / `SOURCE_INELIGIBLE`.
- `HOST_EXECUTION_READY`: `NOT_EVALUATED` / `LIVE_PROBE_NOT_REQUESTED`.
- `NEW_WORK_READY`: `NOT_EVALUATED` / `LIVE_PROBE_NOT_REQUESTED`.
- `TARGET_READY`: `NOT_EVALUATED` / `LIVE_PROBE_NOT_REQUESTED`.
- `ROUTE_READY`: `OUT_OF_SCOPE` / `NO_EXECUTION_STAMP_SUPPLIED`.

The unevaluated and out-of-scope readiness scopes are explicit machine classifications, not inferred readiness.

PRE-MUTATION AMBIGUITY: none
