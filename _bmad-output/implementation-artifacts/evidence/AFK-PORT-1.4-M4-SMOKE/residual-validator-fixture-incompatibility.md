# Residual: readiness validator fixture incompatible with the stricter validator build

Found 2026-08-29 during the post-C3 ROUTE_READY re-evaluation (state advanced
from ROUTE_HARNESS_UNAVAILABLE — the C3 fix proven live, codex_native_session
AVAILABLE/AUTH_NATIVE_SUBSCRIPTION — to STAMP_VALIDATION_UNPROVEN).

Root cause (coordinator reproduction, verbatim):
`afk_validator_fixtures_write` mints its known-valid fixture stamp with the
placeholder `catalog_version: "sha256:fixture"`. The installed
agent-stamp-validate build now enforces input shape and answers:
`agent-stamp-validate: malformed stamp: catalog_version must match ^sha256:[0-9a-f]{64}$` (exit 2).
Exit 2 is correctly read by the kit as "validator did not answer" →
`validator_fixtures: UNAVAILABLE — VALIDATOR_VERDICT_UNAVAILABLE (transient)`
→ HOST_EXECUTION_READY blocked → ROUTE_READY(stamp) FALSE —
STAMP_VALIDATION_UNPROVEN.

Classification: kit fixture defect (Story 1.3 surface) exposed by validator
evolution; REAL stamp validation is unaffected (the same binary validated
every real stamp this story against the real catalog). Post-budget: RECORDED,
NOT FIXED per the coordinator's declared post-budget policy. Hardening item:
mint fixture stamps with a well-formed digest (e.g. the sha256 of the fixture
catalog file, which is also what the digest check compares against).

Consequence carried into the smoke evidence: the readiness surface honestly
reports the validator-fixture leg UNAVAILABLE; the smoke's actual prelaunch
stamp validation runs the real validator against the real catalog and stamp.
