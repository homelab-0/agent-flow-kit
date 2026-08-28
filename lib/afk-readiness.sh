#!/usr/bin/env bash
# afk-readiness.sh — scoped execution readiness: what can actually run here,
# proven at the narrowest scope each dependency invalidates.
#
# This file is SOURCED, never executed, and like every other lifecycle library
# it does not set -e: each evaluation reports through a state and a stable
# reason code, and a probe that cannot answer says so rather than aborting the
# run and leaving the caller with half a result.
#
# Four scopes are produced independently (FR-47):
#
#   HOST_EXECUTION_READY   can this host execute approved work at all
#   NEW_WORK_READY         can a fresh route be obtained from the router
#   TARGET_READY(<id>)     is one registered BMAD target's wiring resolvable
#   ROUTE_READY(<stamp>)   can THIS accepted decision be launched here
#
# They are deliberately not chained into a single flag. A router outage narrows
# NEW_WORK_READY and nothing else; one incompatible target blocks only the
# routes that need it; one unavailable harness blocks only the routes that
# selected it. Collapsing any of those into one boolean is how an outage in a
# component nobody needed becomes an outage of the whole host.
#
# Two evaluation modes, and the boundary between them is "does answering this
# question require running another program or touching the network":
#
#   default   Filesystem and declaration facts only: installed integrity,
#             executable RESOLUTION, target wiring, the orchestration-state
#             bridge, and every deterministic property of a supplied execution
#             stamp. No process is executed, no socket is opened, no temporary
#             file is created, and nothing is written anywhere.
#   --live    Adds bounded, non-mutating probes: Orca capability, the validator
#             contract and its offline fixture suite, native harness
#             capability and authentication CLASS, and router reachability.
#
# Executing a third-party executable is treated as an external observation, not
# as a locally knowable fact: a harness binary is an agent client that can
# create state under HOME and can consume provider tokens, and a validator is a
# separate product with its own contract and its own failure modes. FR-83's
# "locally discoverable capabilities" is therefore satisfied by resolution plus
# this kit's declared capability contract, and anything that needs a dependency
# to RUN is gated behind explicit live mode. This is called out here because it
# is the one place the implementation had to choose a reading of the contract.
#
# Nothing here is launch authorization. Every live fact carries
# launch_authoritative=false and a declared freshness bound; the canonical
# dispatch path revalidates every execution-critical fact immediately before
# launch (FR-95).
#
# shellcheck disable=SC2034,SC2154
# The AFK_RD_*/AFK_R_* result-model inputs are declared here and read by
# afk_build_result and afk_render_human in afk-common.sh; the lifecycle files
# are always sourced together and `set -u` in the entry point is the real guard
# against an unset read.

if [[ -n "${AFK_READINESS_SOURCED:-}" ]]; then
  return 0
fi
AFK_READINESS_SOURCED=1

# --- declared capability contracts (FR-66) ----------------------------------
#
# These describe what THIS executor can drive. They are not routing policy: the
# router and its catalog remain the sole authority for which harness, profile,
# funding class and placement a task may use (FR-65). Runtime observation can
# only ever REMOVE availability here; it never adds an authority the catalog
# did not grant.

AFK_SUPPORTED_STAMP_SCHEMA_MAJOR="1"
AFK_SUPPORTED_VALIDATOR_CONTRACT_MAJOR="1"
AFK_SUPPORTED_TARGET_WIRING_MAJOR="1"
AFK_SUPPORTED_ORCH_STATE_MAJOR="1"

# Harnesses this kit knows how to launch. Both are first class and both are
# individually optional (FR-52): one healthy complete path is enough for the
# host, and an unavailable harness blocks only the routes that selected it.
AFK_APPROVED_HARNESSES="claude
codex"

# The Orca capabilities a supervised launch actually depends on (FR-68).
AFK_REQUIRED_ORCA_CAPABILITIES="worktree-ownership
visible-worker-launch
argument-environment-transport
provider-runtime
session-process-isolation"

# The closed effort vocabulary the launch contract can carry through.
AFK_SUPPORTED_EFFORTS="low
medium
high
xhigh"

# Environment names that, when set, are known to be able to select a metered or
# redirected path for a harness whose route was approved for native
# subscription funding (FR-62). PRESENCE is the signal; no value is ever read.
AFK_CLAUDE_FUNDING_CONFLICT_VARS="ANTHROPIC_API_KEY
ANTHROPIC_AUTH_TOKEN
ANTHROPIC_BASE_URL
CLAUDE_CONFIG_DIR"
AFK_CODEX_FUNDING_CONFLICT_VARS="OPENAI_API_KEY
CODEX_API_KEY
OPENAI_BASE_URL"

# --- declared local configuration -------------------------------------------
# Assigned to a default only when the caller left them empty, exactly like the
# declared paths in afk-common.sh, so a lib sourced on its own never reads an
# unset variable.

AFK_ORCA_BIN="${AFK_ORCA_BIN:-orca}"
AFK_CLAUDE_BIN="${AFK_CLAUDE_BIN:-claude}"
AFK_CODEX_BIN="${AFK_CODEX_BIN:-codex}"
AFK_VALIDATOR_BIN="${AFK_VALIDATOR_BIN:-agent-stamp-validate}"
AFK_CURL_BIN="${AFK_CURL_BIN:-curl}"
AFK_ROUTER_TOKEN_ENV="${AFK_ROUTER_TOKEN_ENV:-AGENT_ROUTER_TOKEN}"

# The orchestration state document is CONSUMED, never produced (FR-90). The
# lifecycle neither creates nor repairs it.
AFK_ORCH_STATE="${AFK_ORCH_STATE:-${AFK_STATE_DIR:+$AFK_STATE_DIR/orchestration.json}}"

# Claude records workspace trust per directory in its own user-owned project
# state. The lifecycle READS that record for a selected path and reports one
# that is awaiting the protected prompt. It never edits that database, never
# automates acceptance, and never proposes prompt-skipping as a workaround.
AFK_CLAUDE_TRUST_DB="${AFK_CLAUDE_TRUST_DB:-${HOME:+$HOME/.claude.json}}"

# Bounded probe budget. A probe that cannot be bounded on this host is reported
# as unbounded rather than run as if it were bounded.
AFK_LIVE_TIMEOUT_MS="${AFK_LIVE_TIMEOUT_MS:-5000}"
# How long a live observation may be considered current. It is metadata on the
# observation, never a licence to reuse it as authorization.
AFK_LIVE_FRESHNESS_S="${AFK_LIVE_FRESHNESS_S:-300}"

# --- run inputs (assigned by bin/agent-flow-kit) ----------------------------

AFK_LIVE_MODE="${AFK_LIVE_MODE:-false}"
AFK_SYNTHETIC_ROUTE="${AFK_SYNTHETIC_ROUTE:-false}"
AFK_STAMP_FILE="${AFK_STAMP_FILE:-}"
AFK_ROUTE_TARGET="${AFK_ROUTE_TARGET:-}"

# --- accumulated readiness state --------------------------------------------
#
# AFK_R_ORCHESTRATION is a result-model input like AFK_R_READINESS and
# AFK_R_LIVE, and it is declared beside the engine that produces it for the
# same reason AFK_JOURNAL_STATE is declared beside the journal reader.

AFK_LIVE_ENTRIES=""
AFK_RD_TARGET_ENTRIES=""
AFK_R_ORCHESTRATION='{"state": "NOT_AVAILABLE", "evaluated": false, "reason": "ORCHESTRATION_STATE_NOT_AVAILABLE", "session": null, "parent": null, "workers": null}'

AFK_RD_HOST_STATE="NOT_EVALUATED";    AFK_RD_HOST_REASON="LIVE_PROBE_NOT_REQUESTED"
AFK_RD_NEWWORK_STATE="NOT_EVALUATED"; AFK_RD_NEWWORK_REASON="LIVE_PROBE_NOT_REQUESTED"
AFK_RD_TARGET_STATE="NOT_EVALUATED";  AFK_RD_TARGET_REASON="TARGET_READINESS_NOT_EVALUATED"
AFK_RD_ROUTE_STATE="OUT_OF_SCOPE";    AFK_RD_ROUTE_REASON="NO_EXECUTION_STAMP_SUPPLIED"

# Per-dependency verdicts, consumed by the aggregation step. Each is TRUE,
# FALSE, UNAVAILABLE or NOT_EVALUATED.
AFK_RD_ORCA="NOT_EVALUATED"
AFK_RD_VALIDATOR="NOT_EVALUATED"
AFK_RD_CLAUDE_PATH="NOT_EVALUATED"
AFK_RD_CODEX_PATH="NOT_EVALUATED"
AFK_RD_ROUTER="NOT_EVALUATED"

# Whether a transient live dependency was observed unavailable during this run.
# It is the difference between "we proved not-ready" and "we could not look".
AFK_RD_LIVE_UNAVAILABLE="false"

AFK_PROBE_OUT=""
AFK_PROBE_PARSE_OUT=""
AFK_PROBE_RC=0
AFK_PROBE_STATUS=""
AFK_PROBE_UNBOUNDED_REPORTED="false"

AFK_TW_STATE=""; AFK_TW_REASON=""; AFK_TW_SEVERITY=""; AFK_TW_DETAIL=""; AFK_TW_IDENTITY=""

AFK_STAMP_JSON="{}"
AFK_STAMP_PRESENT="false"
AFK_STAMP_HARNESS=""
AFK_STAMP_PROFILE=""
AFK_STAMP_EFFORT=""
AFK_STAMP_PLACEMENT_REQUIRED="false"
AFK_STAMP_COST_CLASS=""
AFK_STAMP_METERED="false"
AFK_STAMP_IDENTITY=""

AFK_VALIDATOR_FIXTURE_DIR=""

afk_readiness_reset() {
  AFK_LIVE_ENTRIES=""
  AFK_RD_TARGET_ENTRIES=""
  AFK_R_ORCHESTRATION='{"state": "NOT_AVAILABLE", "evaluated": false, "reason": "ORCHESTRATION_STATE_NOT_AVAILABLE", "session": null, "parent": null, "workers": null}'
  AFK_RD_HOST_STATE="NOT_EVALUATED";    AFK_RD_HOST_REASON="LIVE_PROBE_NOT_REQUESTED"
  AFK_RD_NEWWORK_STATE="NOT_EVALUATED"; AFK_RD_NEWWORK_REASON="LIVE_PROBE_NOT_REQUESTED"
  AFK_RD_TARGET_STATE="NOT_EVALUATED";  AFK_RD_TARGET_REASON="TARGET_READINESS_NOT_EVALUATED"
  AFK_RD_ROUTE_STATE="OUT_OF_SCOPE";    AFK_RD_ROUTE_REASON="NO_EXECUTION_STAMP_SUPPLIED"
  AFK_RD_ORCA="NOT_EVALUATED"
  AFK_RD_VALIDATOR="NOT_EVALUATED"
  AFK_RD_CLAUDE_PATH="NOT_EVALUATED"
  AFK_RD_CODEX_PATH="NOT_EVALUATED"
  AFK_RD_ROUTER="NOT_EVALUATED"
  AFK_RD_LIVE_UNAVAILABLE="false"
  AFK_PROBE_UNBOUNDED_REPORTED="false"
  AFK_PROBE_OUT=""; AFK_PROBE_PARSE_OUT=""
  AFK_STAMP_JSON="{}"; AFK_STAMP_PRESENT="false"
  AFK_STAMP_HARNESS=""; AFK_STAMP_PROFILE=""; AFK_STAMP_EFFORT=""
  AFK_STAMP_PLACEMENT_REQUIRED="false"; AFK_STAMP_COST_CLASS=""
  AFK_STAMP_METERED="false"; AFK_STAMP_IDENTITY=""
}

# --- the published readiness reason vocabulary ------------------------------
#
# Co-located with the engine that emits them: a code, the sentence that
# explains it and the action that resolves it are added in one place, and
# afk_reason_message/afk_reason_action in afk-common.sh consult these hooks
# before their own table. Both hooks print nothing for a code they do not own,
# which keeps a single "unknown code" fallback rather than two competing ones.

afk_readiness_reason_codes() {
  cat <<'CODES'
EXECUTABLE_RESOLVED
EXECUTABLE_NOT_RESOLVED
PROBE_BOUND_UNAVAILABLE
NO_TARGET_REGISTERED
TARGET_SCOPE_PARTIAL
TARGET_WIRING_UNRECOGNIZED
TARGET_WIRING_SCHEMA_INCOMPATIBLE
TARGET_WIRING_MALFORMED
TARGET_WIRING_OWNERSHIP_AMBIGUOUS
TARGET_WIRING_PROVEN
TARGET_PERSONA_UNRESOLVED
TARGET_TEMPLATE_UNRESOLVED
ORCHESTRATION_STATE_NOT_AVAILABLE
ORCHESTRATION_STATE_UNREADABLE
ORCHESTRATION_STATE_SCHEMA_UNSUPPORTED
ORCHESTRATION_STATE_AVAILABLE
ORCHESTRATION_SESSION_INACTIVE
ORCHESTRATION_NEEDS_HUMAN
ORCA_NOT_RESOLVED
ORCA_PROBE_FAILED
ORCA_PROBE_TIMED_OUT
ORCA_RUNTIME_REACHABLE
ORCA_CAPABILITY_UNPROVEN
ORCA_CAPABILITY_INCOMPATIBLE
ORCA_CAPABILITY_PROVEN
VALIDATOR_NOT_RESOLVED
VALIDATOR_CONTRACT_UNREADABLE
VALIDATOR_CONTRACT_INCOMPATIBLE
VALIDATOR_CONTRACT_PROVEN
VALIDATOR_FIXTURE_FAILED
VALIDATOR_VERDICT_UNAVAILABLE
VALIDATOR_ANTI_VACUITY_FAILED
VALIDATOR_FIXTURES_PROVEN
HARNESS_NOT_RESOLVED
HARNESS_CAPABILITY_UNPROVEN
HARNESS_CAPABILITY_PROVEN
AUTH_NATIVE_SUBSCRIPTION
AUTH_MODE_UNSUPPORTED
AUTH_REQUIRED
AUTH_STATUS_UNPROVEN
NO_SELECTED_WORKSPACE
WORKSPACE_TRUST_ESTABLISHED
WORKSPACE_TRUST_REQUIRED
WORKSPACE_TRUST_UNPROVEN
ROUTER_ENDPOINT_NOT_DECLARED
ROUTER_TRANSPORT_UNTRUSTED
ROUTER_AUTH_MISSING
ROUTER_UNREACHABLE
ROUTER_TIMED_OUT
ROUTER_API_SHAPE_UNSUPPORTED
ROUTER_AVAILABLE
ROUTER_CATALOG_COMPATIBLE
ROUTER_CATALOG_INCOMPATIBLE
NO_APPROVED_HARNESS_PATH
HOST_EXECUTION_READY_PROVEN
INSTALLED_INTEGRITY_NOT_PROVEN
STAMP_UNREADABLE
STAMP_SHAPE_INVALID
STAMP_EXPIRED
STAMP_VALIDATION_FAILED
STAMP_VALIDATION_UNPROVEN
ROUTE_PROFILE_UNSUPPORTED
ROUTE_FUNDING_CONFLICT
ROUTE_TARGET_UNRESOLVED
ROUTE_HARNESS_UNAVAILABLE
ROUTE_READY_PROVEN
PLACEMENT_NOT_A_LIFECYCLE_CONCERN
LIVE_OBSERVATION_NOT_LAUNCH_AUTHORITY
CODES
}

afk_readiness_reason_message() { # <reason> — empty for a code this file does not own
  case "$1" in
    EXECUTABLE_RESOLVED)          printf 'A declared dependency executable resolves on this host.' ;;
    EXECUTABLE_NOT_RESOLVED)      printf 'A declared dependency executable does not resolve on this host.' ;;
    PROBE_BOUND_UNAVAILABLE)      printf 'This host offers no way to bound an external probe, so the declared timeout could not be enforced.' ;;
    NO_TARGET_REGISTERED)         printf 'No BMAD target repository is registered, so there is no target wiring to resolve.' ;;
    TARGET_SCOPE_PARTIAL)         printf 'Some registered targets resolve and some do not; target readiness is per repository and is never collapsed into one answer.' ;;
    TARGET_WIRING_UNRECOGNIZED)   printf 'The target presents no recognized BMAD story-template layout, and directory presence is not evidence of compatibility.' ;;
    TARGET_WIRING_SCHEMA_INCOMPATIBLE) printf 'The target story template does not carry the agent-flow-kit wiring schema this executor supports.' ;;
    TARGET_WIRING_MALFORMED)      printf 'The target story template still carries a retired frontmatter key, so it produces stories dispatch refuses.' ;;
    TARGET_WIRING_OWNERSHIP_AMBIGUOUS) printf 'Two physical copies of the target wiring disagree, so neither can be treated as authoritative.' ;;
    TARGET_WIRING_PROVEN)         printf 'The target layout, wiring schema, personas and templates all resolve mechanically.' ;;
    TARGET_PERSONA_UNRESOLVED)    printf 'A required BMAD persona file does not resolve in the target, so persona injection would launch the wrong agent or nothing at all.' ;;
    TARGET_TEMPLATE_UNRESOLVED)   printf 'A recognized target story template exists but could not be resolved or read.' ;;
    ORCHESTRATION_STATE_NOT_AVAILABLE) printf 'No normalized orchestration state document exists, so no orchestration summary can be reported.' ;;
    ORCHESTRATION_STATE_UNREADABLE) printf 'The normalized orchestration state document exists but could not be parsed.' ;;
    ORCHESTRATION_STATE_SCHEMA_UNSUPPORTED) printf 'The orchestration state document declares a newer major schema than this lifecycle consumes.' ;;
    ORCHESTRATION_STATE_AVAILABLE) printf 'A normalized orchestration state document was consumed and an orchestration session is active.' ;;
    ORCHESTRATION_SESSION_INACTIVE) printf 'A normalized orchestration state document was consumed and reports no active session.' ;;
    ORCHESTRATION_NEEDS_HUMAN)    printf 'The supervised orchestration session is waiting on a human decision.' ;;
    ORCA_NOT_RESOLVED)            printf 'Orca does not resolve on this host, and a worker with no Orca worktree and no terminal tab is not a supervised worker.' ;;
    ORCA_PROBE_FAILED)            printf 'Orca is installed but its read-only status probe did not answer.' ;;
    ORCA_PROBE_TIMED_OUT)         printf 'Orca did not answer its read-only status probe inside the declared timeout.' ;;
    ORCA_RUNTIME_REACHABLE)       printf 'The Orca runtime answered a bounded read-only status probe.' ;;
    ORCA_CAPABILITY_UNPROVEN)     printf 'Orca offers no explicit capability contract, so the launch capabilities a supervised worker depends on cannot be proven.' ;;
    ORCA_CAPABILITY_INCOMPATIBLE) printf 'Orca does not declare every launch capability a supervised, visible worker depends on.' ;;
    ORCA_CAPABILITY_PROVEN)       printf 'Orca declares every launch capability a supervised, visible worker depends on.' ;;
    VALIDATOR_NOT_RESOLVED)       printf 'The execution-stamp validator does not resolve on this host, so no stamp can be proven before a launch.' ;;
    VALIDATOR_CONTRACT_UNREADABLE) printf 'The validator offers no machine-readable identity and contract, so only its behaviour can be checked.' ;;
    VALIDATOR_CONTRACT_INCOMPATIBLE) printf 'The validator declares a newer stamp-schema major version than this executor records.' ;;
    VALIDATOR_CONTRACT_PROVEN)    printf 'The validator published a machine-readable contract this executor supports.' ;;
    VALIDATOR_FIXTURE_FAILED)     printf 'The validator did not accept a known-valid offline fixture, so its verdicts cannot be relied on.' ;;
    VALIDATOR_VERDICT_UNAVAILABLE) printf 'The validator could not deliver a verdict on an offline fixture, so its usability is temporarily unproven rather than refuted.' ;;
    VALIDATOR_ANTI_VACUITY_FAILED) printf 'The validator accepted every negative fixture, so it is an always-success validator and every refusal downstream would be a rubber stamp.' ;;
    VALIDATOR_FIXTURES_PROVEN)    printf 'The validator accepted the known-valid fixture and rejected at least one tampered, expired, incompatible or provenance-mismatched fixture.' ;;
    HARNESS_NOT_RESOLVED)         printf 'This harness does not resolve on this host; it is optional, so it blocks only the routes that select it.' ;;
    HARNESS_CAPABILITY_UNPROVEN)  printf 'This harness cannot prove the invocation capabilities the frozen launch contract uses.' ;;
    HARNESS_CAPABILITY_PROVEN)    printf 'This harness proves every invocation capability the frozen launch contract uses.' ;;
    AUTH_NATIVE_SUBSCRIPTION)     printf 'This harness reports a native subscription session, which is the funding class the approved paths are stamped for.' ;;
    AUTH_MODE_UNSUPPORTED)        printf 'This harness reports an API-key session rather than a native subscription session; that is a legitimate funding class, but not the one a subscription route was approved for.' ;;
    AUTH_REQUIRED)                printf 'This harness has no usable session and a human must log in; readiness never triggers an automatic login.' ;;
    AUTH_STATUS_UNPROVEN)         printf 'The harness auth status could not be classified through a safe native mechanism.' ;;
    NO_SELECTED_WORKSPACE)        printf 'No worker workspace path was selected, so no per-directory workspace-trust decision applies.' ;;
    WORKSPACE_TRUST_ESTABLISHED)  printf 'The selected worker path already carries an accepted workspace-trust decision.' ;;
    WORKSPACE_TRUST_REQUIRED)     printf 'The selected worker path is awaiting the protected workspace-trust prompt, which only a human may accept.' ;;
    WORKSPACE_TRUST_UNPROVEN)     printf 'The harness project state could not be read for the selected worker path, so its workspace-trust decision is unknown.' ;;
    ROUTER_ENDPOINT_NOT_DECLARED) printf 'No central router endpoint is declared, so fresh routing cannot be requested from this host.' ;;
    ROUTER_TRANSPORT_UNTRUSTED)   printf 'The declared router endpoint is not https, and a caller token on a plaintext channel is a leaked token.' ;;
    ROUTER_AUTH_MISSING)          printf 'The declared caller-token variable is not populated, so the router cannot be asked anything.' ;;
    ROUTER_UNREACHABLE)           printf 'The central router did not answer its status endpoint; this is a transient live observation, not a defect of the installation.' ;;
    ROUTER_TIMED_OUT)             printf 'The central router did not answer inside the declared timeout; this is a transient live observation, not a defect of the installation.' ;;
    ROUTER_API_SHAPE_UNSUPPORTED) printf 'The router answered with a document this executor does not recognize as the routing API.' ;;
    ROUTER_AVAILABLE)             printf 'The central router answered its status endpoint over trusted transport with the expected API shape.' ;;
    ROUTER_CATALOG_COMPATIBLE)    printf 'The router catalog provenance is compatible with what is being evaluated.' ;;
    ROUTER_CATALOG_INCOMPATIBLE)  printf 'The router now serves a different catalog version than the one this execution stamp was frozen against.' ;;
    NO_APPROVED_HARNESS_PATH)     printf 'No complete centrally approved harness execution path is usable on this host.' ;;
    HOST_EXECUTION_READY_PROVEN)  printf 'Orca, a compatible validator and at least one complete approved harness path are all usable here.' ;;
    INSTALLED_INTEGRITY_NOT_PROVEN) printf 'Installed integrity is not proven, so no live host readiness can be asserted on top of it.' ;;
    STAMP_UNREADABLE)             printf 'The supplied execution stamp could not be read as JSON.' ;;
    STAMP_SHAPE_INVALID)          printf 'The supplied execution stamp does not present the closed property set and required fields of a frozen routing decision.' ;;
    STAMP_EXPIRED)                printf 'The supplied execution stamp has passed its expiry, so it authorizes nothing and a fresh route is required.' ;;
    STAMP_VALIDATION_FAILED)      printf 'The compatible validator rejected this execution stamp.' ;;
    STAMP_VALIDATION_UNPROVEN)    printf 'No validator verdict could be obtained for this execution stamp, so route readiness is not asserted.' ;;
    ROUTE_PROFILE_UNSUPPORTED)    printf 'This kit has no validated launch contract for the stamped harness, profile and effort combination.' ;;
    ROUTE_FUNDING_CONFLICT)       printf 'An environment condition on this host could select an unauthorized metered or redirected path for a route approved for native subscription funding.' ;;
    ROUTE_TARGET_UNRESOLVED)      printf 'The BMAD target this route needs is not registered or its wiring does not resolve.' ;;
    ROUTE_HARNESS_UNAVAILABLE)    printf 'The harness this route selected is not usable here, and no other harness is ever substituted for it.' ;;
    ROUTE_READY_PROVEN)           printf 'Every authority this route depends on answered, and the route is semantically launchable on this host right now.' ;;
    PLACEMENT_NOT_A_LIFECYCLE_CONCERN) printf 'Physical inference placement is an ephemeral per-attempt dispatch concern; readiness selects none, persists none, and assumes none is reusable.' ;;
    LIVE_OBSERVATION_NOT_LAUNCH_AUTHORITY) printf 'A live observation is diagnostic evidence about one instant and is never reusable launch authorization.' ;;
    *) printf '' ;;
  esac
}

afk_readiness_reason_action() { # <reason> — empty for a code this file does not own
  case "$1" in
    EXECUTABLE_RESOLVED|ORCA_RUNTIME_REACHABLE|ORCA_CAPABILITY_PROVEN|VALIDATOR_CONTRACT_PROVEN|VALIDATOR_FIXTURES_PROVEN|HARNESS_CAPABILITY_PROVEN|AUTH_NATIVE_SUBSCRIPTION|WORKSPACE_TRUST_ESTABLISHED|ROUTER_AVAILABLE|ROUTER_CATALOG_COMPATIBLE|HOST_EXECUTION_READY_PROVEN|TARGET_WIRING_PROVEN|ROUTE_READY_PROVEN|ORCHESTRATION_STATE_AVAILABLE|NO_SELECTED_WORKSPACE) \
                                  printf 'No action required.' ;;
    EXECUTABLE_NOT_RESOLVED)      printf 'Install the dependency, or point the lifecycle at it through its declared configuration variable.' ;;
    PROBE_BOUND_UNAVAILABLE)      printf 'Install a timeout utility so external probes can be bounded, or run live readiness on a host that has one.' ;;
    NO_TARGET_REGISTERED)         printf 'Register the BMAD target repositories this host dispatches into.' ;;
    TARGET_SCOPE_PARTIAL)         printf 'Read the per-target verdicts above; only the failing targets need attention.' ;;
    TARGET_WIRING_UNRECOGNIZED)   printf 'Wire the target repository for agent-flow-kit: add the story-template frontmatter block and the persona directory.' ;;
    TARGET_WIRING_SCHEMA_INCOMPATIBLE) printf 'Add the missing frontmatter keys to the target story template.' ;;
    TARGET_WIRING_MALFORMED)      printf 'Remove the retired frontmatter key from the target story template; routing lives in the stamp.' ;;
    TARGET_WIRING_OWNERSHIP_AMBIGUOUS) printf 'Make the duplicated wiring copies identical, or replace one with a symlink to the other.' ;;
    TARGET_PERSONA_UNRESOLVED)    printf 'Create or repoint the missing persona file under the target persona directory.' ;;
    TARGET_TEMPLATE_UNRESOLVED)   printf 'Restore or repoint the target story template so it resolves to a readable file.' ;;
    ORCHESTRATION_STATE_NOT_AVAILABLE|ORCHESTRATION_SESSION_INACTIVE) \
                                  printf 'No action required: orchestration state is owned elsewhere and its absence never blocks lifecycle readiness.' ;;
    ORCHESTRATION_STATE_UNREADABLE|ORCHESTRATION_STATE_SCHEMA_UNSUPPORTED) \
                                  printf 'Ask the orchestration owner to repair or downgrade the state document; the lifecycle consumes it and never rewrites it.' ;;
    ORCHESTRATION_NEEDS_HUMAN)    printf 'Answer the pending question in the supervised orchestration session.' ;;
    ORCA_NOT_RESOLVED)            printf 'Install Orca, or point the lifecycle at it with AFK_ORCA_BIN. There is no headless degradation mode.' ;;
    ORCA_PROBE_FAILED|ORCA_PROBE_TIMED_OUT) \
                                  printf 'Check that the Orca runtime is up, then re-run the live evaluation.' ;;
    ORCA_CAPABILITY_UNPROVEN|ORCA_CAPABILITY_INCOMPATIBLE) \
                                  printf 'Install an Orca version that declares the required launch capabilities explicitly.' ;;
    VALIDATOR_NOT_RESOLVED)       printf 'Install agent-stamp-validate from the control-plane repository, or point the lifecycle at it with AFK_VALIDATOR_BIN.' ;;
    VALIDATOR_CONTRACT_UNREADABLE) printf 'No action required for readiness; the fixture suite is the behavioural proof that actually decides.' ;;
    VALIDATOR_CONTRACT_INCOMPATIBLE) printf 'Install a lifecycle executable that records the validator stamp-schema major version.' ;;
    VALIDATOR_FIXTURE_FAILED)     printf 'Investigate the validator installation and its trusted catalog; a validator that rejects a known-valid fixture cannot gate a launch.' ;;
    VALIDATOR_VERDICT_UNAVAILABLE) printf 'Retry later, then investigate the validator installation: an unanswerable validator is a transient live condition, never a proven refusal.' ;;
    VALIDATOR_ANTI_VACUITY_FAILED) printf 'Replace the validator: an always-success validator must never gate a launch.' ;;
    HARNESS_NOT_RESOLVED)         printf 'Install this harness if a route selects it; leaving it absent is a valid host configuration.' ;;
    HARNESS_CAPABILITY_UNPROVEN)  printf 'Install a harness version that offers the invocation capabilities the launch contract uses.' ;;
    AUTH_MODE_UNSUPPORTED)        printf 'Log this harness in to its native subscription, or route the work through a funding class this session actually carries.' ;;
    AUTH_REQUIRED)                printf 'Log in interactively with the harness CLI; the lifecycle never logs in for you.' ;;
    AUTH_STATUS_UNPROVEN)         printf 'Check the harness auth status by hand; readiness will not guess a session state.' ;;
    WORKSPACE_TRUST_REQUIRED)     printf 'Open the selected path in the harness once and accept the workspace-trust prompt yourself; the lifecycle must never accept it or bypass it.' ;;
    WORKSPACE_TRUST_UNPROVEN)     printf 'Check the workspace-trust state by hand for the selected path.' ;;
    ROUTER_ENDPOINT_NOT_DECLARED) printf 'Declare AGENT_ROUTER_URL, then re-run the live evaluation.' ;;
    ROUTER_TRANSPORT_UNTRUSTED)   printf 'Point AGENT_ROUTER_URL at the https endpoint; never send a caller token over plaintext.' ;;
    ROUTER_AUTH_MISSING)          printf 'Populate the declared caller-token variable from the owner secret store; its value is never written into this kit.' ;;
    ROUTER_UNREACHABLE|ROUTER_TIMED_OUT) \
                                  printf 'Retry later: this is a transient outage, it narrows new-work readiness only, and no local route is ever invented in its place.' ;;
    ROUTER_API_SHAPE_UNSUPPORTED) printf 'Confirm AGENT_ROUTER_URL points at the agent router rather than another service on the same host.' ;;
    ROUTER_CATALOG_INCOMPATIBLE)  printf 'Obtain a fresh route against the current catalog if the stamped decision is affected by the catalog move.' ;;
    NO_APPROVED_HARNESS_PATH)     printf 'Make at least one approved harness usable here: install it and give it a native session.' ;;
    INSTALLED_INTEGRITY_NOT_PROVEN) printf 'Resolve the installed-integrity findings first; live readiness is never asserted over an unproven installation.' ;;
    STAMP_UNREADABLE|STAMP_SHAPE_INVALID) \
                                  printf 'Re-create the stamp from an accepted route decision with make-stamp.sh.' ;;
    STAMP_EXPIRED)                printf 'Obtain a fresh route decision and stamp it; an expired decision is never extended locally.' ;;
    STAMP_VALIDATION_FAILED)      printf 'Read the validator verdict and re-route; the lifecycle never overrides a validator refusal.' ;;
    STAMP_VALIDATION_UNPROVEN)    printf 'Make a compatible validator usable on this host, then re-run the live evaluation.' ;;
    ROUTE_PROFILE_UNSUPPORTED)    printf 'Re-route to a harness and profile this kit has a validated launch contract for; no substitution is made here.' ;;
    ROUTE_FUNDING_CONFLICT)       printf 'Unset the reported variable for the dispatching environment, or re-route to a funding class that matches it. Only the affected route is blocked.' ;;
    ROUTE_TARGET_UNRESOLVED)      printf 'Resolve the target wiring findings for the target this route needs.' ;;
    ROUTE_HARNESS_UNAVAILABLE)    printf 'Make the selected harness usable, or obtain a fresh central decision for a harness that is.' ;;
    PLACEMENT_NOT_A_LIFECYCLE_CONCERN|LIVE_OBSERVATION_NOT_LAUNCH_AUTHORITY) \
                                  printf 'No action required: dispatch resolves this per attempt, immediately before launch.' ;;
    *) printf '' ;;
  esac
}

# --- small shared helpers ---------------------------------------------------

afk_list_contains() { # <needle> <newline-separated list>
  [[ -n "${1:-}" && -n "${2:-}" ]] || return 1
  printf '%s\n' "$2" | grep -q -x -F -- "$1"
}

# A UTC observation time, second resolution. Called ONLY on a live path: an
# offline evaluation emits no timestamp at all, which is what keeps two default
# runs over unchanged state byte-identical.
afk_now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'UNKNOWN'; }

afk_harness_binary() { # <harness>
  case "$1" in
    claude) printf '%s' "$AFK_CLAUDE_BIN" ;;
    codex)  printf '%s' "$AFK_CODEX_BIN" ;;
    *)      printf '' ;;
  esac
}

# --- the bounded probe runner (FR-85) ---------------------------------------
#
# Every external observation goes through here, so "bounded, non-mutating,
# timestamped" is a property of one function rather than of each caller
# remembering. A host without a bounding tool does not get an unbounded probe
# pretending to be a bounded one: the probe still runs, and the run reports
# that its bound could not be enforced.

afk_probe_timeout_seconds() {
  local ms="$AFK_LIVE_TIMEOUT_MS" s
  case "$ms" in ''|*[!0-9]*) ms=5000 ;; esac
  s=$(( (ms + 999) / 1000 ))
  if (( s < 1 )); then s=1; fi
  printf '%s' "$s"
}

# afk_probe_run <argv...>
# Sets AFK_PROBE_STATUS to NOT_RESOLVED, TIMEOUT, OK or NONZERO, AFK_PROBE_RC
# to the observed status, AFK_PROBE_PARSE_OUT to complete stdout for immediate
# parsing, and AFK_PROBE_OUT to at most 4096 bytes of retained evidence.
# Returns 0 only for AFK_PROBE_STATUS=OK.
afk_probe_run() {
  local secs out rc
  AFK_PROBE_OUT=""; AFK_PROBE_PARSE_OUT=""; AFK_PROBE_RC=0; AFK_PROBE_STATUS=""
  if [[ $# -lt 1 || -z "${1:-}" ]]; then
    AFK_PROBE_STATUS="NOT_RESOLVED"; return 1
  fi
  if ! afk_have "$1" && [[ ! -x "$1" ]]; then
    AFK_PROBE_STATUS="NOT_RESOLVED"; return 1
  fi
  secs="$(afk_probe_timeout_seconds)"
  if afk_have timeout; then
    out="$(timeout "$secs" "$@" 2>/dev/null)"
    rc=$?
  else
    if [[ "$AFK_PROBE_UNBOUNDED_REPORTED" != "true" ]]; then
      AFK_PROBE_UNBOUNDED_REPORTED="true"
      afk_add_finding "live-probe" "KIT_STATE" "UNKNOWN" "PROBE_BOUND_UNAVAILABLE" \
        "warning" "" "CAPABILITY_PROBE" "a bounded probe" "no timeout tool on this host" \
        "true" "true" ""
    fi
    out="$("$@" 2>/dev/null)"
    rc=$?
  fi
  AFK_PROBE_RC=$rc
  # Parse the complete response during this one bounded pass. Retained evidence
  # remains capped at 4096 bytes and is never a dependency transcript.
  AFK_PROBE_PARSE_OUT="$out"
  AFK_PROBE_OUT="$(printf '%s' "$out" | head -c 4096)"
  if (( rc == 124 )); then
    AFK_PROBE_STATUS="TIMEOUT"; return 1
  fi
  if (( rc != 0 )); then
    AFK_PROBE_STATUS="NONZERO"; return 1
  fi
  AFK_PROBE_STATUS="OK"
  return 0
}

# --- the live-fact record ---------------------------------------------------
#
# One shape for every external observation, so automation can treat them
# uniformly: what was observed, when, under what bound, from what evidence,
# how long it may be considered current, and — always — that it authorizes no
# launch (FR-84, FR-86, FR-95).

afk_live_fact() { # <key> <state> <reason> <provenance> <evaluated> [transient] [detail]
  local key="$1" state="$2" reason="$3" prov="$4" evaluated="$5"
  local transient="${6:-false}" detail="${7:-}"
  local observed_at="" timeout_ms="" freshness=""
  # A filesystem or declaration fact carries no observation time, no timeout
  # and no freshness window: there is no external party whose answer could go
  # stale, and emitting a timestamp there would make two identical offline runs
  # differ for no reason anyone could act on.
  case "$prov" in
    ""|PATH_STRUCTURE|FILE_STRUCTURE|OWNERSHIP_RULE) : ;;
    *)
      if [[ "$evaluated" == "true" ]]; then
        observed_at="$(afk_now_utc)"
        timeout_ms="$AFK_LIVE_TIMEOUT_MS"
        freshness="$AFK_LIVE_FRESHNESS_S"
      fi ;;
  esac
  AFK_LIVE_ENTRIES="${AFK_LIVE_ENTRIES}$(jq -nc \
    --arg key "$key" --arg state "$state" --arg reason "$reason" --arg prov "$prov" \
    --arg evaluated "$evaluated" --arg transient "$transient" --arg detail "$detail" \
    --arg observed_at "$observed_at" --arg timeout_ms "$timeout_ms" --arg freshness "$freshness" \
    '{key: $key,
      fact: {state: $state,
             evaluated: ($evaluated == "true"),
             reason: $reason,
             observed_at: (if $observed_at == "" then null else $observed_at end),
             timeout_ms: (if $timeout_ms == "" then null else ($timeout_ms | tonumber) end),
             freshness_seconds: (if $freshness == "" then null else ($freshness | tonumber) end),
             evidence_provenance: (if $prov == "" then null else $prov end),
             transient: ($transient == "true"),
             launch_authoritative: false,
             detail: (if $detail == "" then null else $detail end)}}')"$'\n'
}

# Every external fact this lifecycle knows about. All of them are seeded
# NOT_EVALUATED before anything runs, so a key never simply disappears because
# a probe took an early return: a missing key and an unprobed one are
# indistinguishable to automation, and only one of them is honest.
afk_live_facts_declared() {
  printf '%s\n' \
    router_status \
    router_catalog_provenance \
    router_synthetic_route \
    claude_native_session \
    codex_native_session \
    claude_capability \
    codex_capability \
    claude_workspace_trust \
    orca_runtime \
    orca_capability \
    validator_contract \
    validator_fixtures \
    route_placement \
    route_authority
}

afk_live_facts_json() {
  local out
  # `add` merges left to right, so a probe's answer replaces the NOT_EVALUATED
  # seed for the same key and the last word on a fact is the one reported.
  out="$(printf '%s' "$AFK_LIVE_ENTRIES" | jq -sc 'map({(.key): .fact}) | add // {}')" || return 1
  printf '%s' "$out"
}

afk_live_fact_reason() { # <key> -> latest grounded reason, if evaluated
  printf '%s' "$AFK_LIVE_ENTRIES" | jq -sr --arg key "$1" \
    'map(select(.key == $key and .fact.evaluated)) | last | .fact.reason // empty'
}

# --- executable resolution (offline, no process is started) -----------------

afk_resolve_executable() { # <binary> -> prints the resolved path
  local b="$1" p
  [[ -n "$b" ]] || return 1
  if [[ "$b" == */* ]]; then
    [[ -x "$b" ]] || return 1
    printf '%s' "$b"
    return 0
  fi
  p="$(command -v "$b" 2>/dev/null)" || return 1
  [[ -n "$p" ]] || return 1
  printf '%s' "$p"
}

afk_evaluate_executables() {
  local name bin resolved
  for name in orca validator claude codex; do
    case "$name" in
      orca)      bin="$AFK_ORCA_BIN" ;;
      validator) bin="$AFK_VALIDATOR_BIN" ;;
      claude)    bin="$AFK_CLAUDE_BIN" ;;
      codex)     bin="$AFK_CODEX_BIN" ;;
      *)         bin="" ;;
    esac
    if resolved="$(afk_resolve_executable "$bin")"; then
      afk_live_fact "${name}_executable" "PRESENT" "EXECUTABLE_RESOLVED" "PATH_STRUCTURE" "true" "false" "$resolved"
    else
      afk_live_fact "${name}_executable" "ABSENT" "EXECUTABLE_NOT_RESOLVED" "PATH_STRUCTURE" "true" "false" "$bin"
    fi
  done
}

afk_executable_state() { # <name> -> PRESENT|ABSENT
  printf '%s' "$AFK_LIVE_ENTRIES" | jq -sr --arg k "${1}_executable" \
    'map(select(.key == $k)) | if length > 0 then .[-1].fact.state else "ABSENT" end'
}

# --- registered BMAD target wiring (offline, mechanical) --------------------
#
# Directory presence is not compatibility (FR-69). A target is ready when its
# recognized layout, its wiring schema, its personas and its templates all
# resolve mechanically, and when no second physical copy of the wiring
# disagrees with the first. Every failure is scoped to TARGET_READY:<id>: one
# unusable target never makes an unrelated target or the host unavailable.

afk_target_template_candidates() { # <target path>
  printf '%s\n' \
    "$1/_bmad/bmm/workflows/4-implementation/create-story/template.md" \
    "$1/.agents/skills/bmad-create-story/template.md" \
    "$1/.claude/skills/bmad-create-story/template.md"
}

# The frontmatter block of a story template: everything between the first line
# that is exactly `---` and the next one. Read as SHAPE, never as content.
afk_target_frontmatter() { # <template path>
  awk 'NR == 1 && $0 != "---" { exit }
       NR == 1 { inb = 1; next }
       inb && $0 == "---" { exit }
       inb { print }' "$1" 2>/dev/null
}

afk_target_frontmatter_has_key() { # <frontmatter text> <key>
  printf '%s\n' "$1" | grep -q -E "^[[:space:]]*$2:"
}

afk_target_wiring_evaluate() { # <target path>
  local p="$1" tmpl="" candidate found="" layout="" fm="" key
  local first_identity="" identity="" resolved agents_dir

  AFK_TW_STATE="BROKEN"; AFK_TW_REASON=""; AFK_TW_SEVERITY="warning"
  AFK_TW_DETAIL=""; AFK_TW_IDENTITY=""

  if [[ ! -d "$p" ]]; then
    AFK_TW_REASON="TARGET_PATH_MISSING"; AFK_TW_DETAIL="absent"
    return 1
  fi

  # --- recognized layout, and no disagreeing second copy -------------------
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    [[ -e "$candidate" ]] || continue
    if ! resolved="$(afk_realpath "$candidate")" || [[ ! -f "$resolved" ]]; then
      AFK_TW_STATE="BROKEN"; AFK_TW_REASON="TARGET_TEMPLATE_UNRESOLVED"
      AFK_TW_DETAIL="a recognized template does not resolve"
      return 1
    fi
    identity="$(afk_file_payload_identity "$resolved")"
    if [[ -z "$identity" ]]; then
      AFK_TW_STATE="BROKEN"; AFK_TW_REASON="TARGET_TEMPLATE_UNRESOLVED"
      AFK_TW_DETAIL="a recognized template could not be read"
      return 1
    fi
    if [[ -z "$found" ]]; then
      found="$candidate"; tmpl="$resolved"; first_identity="$identity"
      case "$candidate" in
        */_bmad/bmm/workflows/*) layout="bmad-v6-tree" ;;
        *)                       layout="bmad-v6-skills" ;;
      esac
    elif [[ "$identity" != "$first_identity" ]]; then
      # Two physical copies of the same wiring that do not agree: neither can
      # be called authoritative, and guessing which one dispatch will read is
      # exactly the ownership ambiguity FR-56 refuses to resolve by itself.
      AFK_TW_STATE="INCOMPATIBLE"; AFK_TW_REASON="TARGET_WIRING_OWNERSHIP_AMBIGUOUS"
      AFK_TW_DETAIL="two wiring copies disagree"
      return 1
    fi
  done < <(afk_target_template_candidates "$p")

  if [[ -z "$found" ]]; then
    AFK_TW_STATE="INCOMPATIBLE"; AFK_TW_REASON="TARGET_WIRING_UNRECOGNIZED"
    AFK_TW_DETAIL="no recognized story template"
    return 1
  fi
  AFK_TW_IDENTITY="$first_identity"

  # --- the wiring schema this executor supports ---------------------------
  fm="$(afk_target_frontmatter "$tmpl")"
  if [[ -z "$fm" ]]; then
    AFK_TW_STATE="INCOMPATIBLE"; AFK_TW_REASON="TARGET_WIRING_SCHEMA_INCOMPATIBLE"
    AFK_TW_DETAIL="no frontmatter block"
    return 1
  fi
  for key in linear stamp persona gates max_cycles; do
    if ! afk_target_frontmatter_has_key "$fm" "$key"; then
      AFK_TW_STATE="INCOMPATIBLE"; AFK_TW_REASON="TARGET_WIRING_SCHEMA_INCOMPATIBLE"
      AFK_TW_DETAIL="missing frontmatter key: $key"
      return 1
    fi
  done
  # A retired key that still LOOKS authoritative is worse than none: dispatch
  # refuses a story carrying one, so a target that still emits one is wired to
  # produce stories that cannot run.
  for key in route local_gpu; do
    if afk_target_frontmatter_has_key "$fm" "$key"; then
      AFK_TW_STATE="INCOMPATIBLE"; AFK_TW_REASON="TARGET_WIRING_MALFORMED"
      AFK_TW_DETAIL="retired frontmatter key: $key"
      return 1
    fi
  done

  # --- personas resolve, including through the skills-layout symlinks ------
  agents_dir="$p/_bmad/bmm/agents"
  if [[ ! -d "$agents_dir" ]]; then
    AFK_TW_STATE="INCOMPATIBLE"; AFK_TW_REASON="TARGET_PERSONA_UNRESOLVED"
    AFK_TW_DETAIL="no persona directory"
    return 1
  fi
  for key in dev pm; do
    if [[ ! -e "$agents_dir/$key.md" ]] \
       || ! resolved="$(afk_realpath "$agents_dir/$key.md")" || [[ ! -f "$resolved" ]]; then
      AFK_TW_STATE="INCOMPATIBLE"; AFK_TW_REASON="TARGET_PERSONA_UNRESOLVED"
      AFK_TW_DETAIL="persona does not resolve: $key"
      return 1
    fi
  done

  AFK_TW_STATE="READY"; AFK_TW_REASON="TARGET_WIRING_PROVEN"; AFK_TW_SEVERITY="info"
  AFK_TW_DETAIL="$layout"
  return 0
}

afk_evaluate_target_readiness() {
  local n i tid tpath ready=0 total=0 blocked=0

  AFK_RD_TARGET_ENTRIES=""
  n="$(printf '%s' "$AFK_MANIFEST_JSON" | jq -r '(.targets // []) | length')"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac

  for (( i = 0; i < n; i++ )); do
    tid="$(printf '%s' "$AFK_MANIFEST_JSON" | jq -r ".targets[$i].id // \"\"")"
    tpath="$(printf '%s' "$AFK_MANIFEST_JSON" | jq -r ".targets[$i].path // \"\"")"
    [[ -n "$tid" ]] || continue
    total=$((total + 1))

    afk_target_wiring_evaluate "$tpath"
    if [[ "$AFK_TW_STATE" == "READY" ]]; then
      ready=$((ready + 1))
      afk_add_target "$tid" "$tpath" "READY" "$AFK_TW_REASON" "info" ""
    else
      blocked=$((blocked + 1))
      afk_add_target "$tid" "$tpath" "$AFK_TW_STATE" "$AFK_TW_REASON" "warning" "TARGET_READY:$tid"
      afk_add_finding "$tid" "TARGET_WIRING" "$AFK_TW_STATE" "$AFK_TW_REASON" \
        "warning" "TARGET_READY:$tid" "BMAD_RESOLUTION" \
        "resolvable agent-flow-kit wiring" "$AFK_TW_DETAIL" "false" "false" "$tpath"
    fi
    AFK_RD_TARGET_ENTRIES="${AFK_RD_TARGET_ENTRIES}$(jq -nc \
      --arg id "$tid" --arg path "$tpath" --arg state "$AFK_TW_STATE" \
      --arg reason "$AFK_TW_REASON" --arg identity "$AFK_TW_IDENTITY" --arg detail "$AFK_TW_DETAIL" \
      '{id: $id, path: $path,
        state: (if $state == "READY" then "TRUE" else "FALSE" end),
        wiring_state: $state,
        reason: $reason,
        wiring_identity: (if $identity == "" then null else $identity end),
        detail: (if $detail == "" then null else $detail end)}')"$'\n'
  done

  if (( total == 0 )); then
    AFK_RD_TARGET_STATE="NOT_EVALUATED"
    AFK_RD_TARGET_REASON="NO_TARGET_REGISTERED"
  elif (( blocked == 0 )); then
    AFK_RD_TARGET_STATE="TRUE"
    AFK_RD_TARGET_REASON="TARGET_WIRING_PROVEN"
  elif (( ready > 0 )); then
    # Deliberately not FALSE: some targets are usable and some are not, and a
    # single boolean over a set of independent repositories is exactly the
    # collapse FR-51 forbids. The per-target verdicts are the answer.
    AFK_RD_TARGET_STATE="PARTIAL"
    AFK_RD_TARGET_REASON="TARGET_SCOPE_PARTIAL"
  else
    AFK_RD_TARGET_STATE="FALSE"
    AFK_RD_TARGET_REASON="TARGET_WIRING_UNRECOGNIZED"
  fi
}

afk_target_ready() { # <target id> -> 0 when that target proved ready
  local got
  got="$(printf '%s' "$AFK_RD_TARGET_ENTRIES" | jq -sr --arg id "$1" \
    'map(select(.id == $id)) | if length > 0 then .[0].state else "MISSING" end')"
  [[ "$got" == "TRUE" ]]
}

afk_target_registered() { # <target id>
  local got
  got="$(printf '%s' "$AFK_RD_TARGET_ENTRIES" | jq -sr --arg id "$1" \
    'map(select(.id == $id)) | length')"
  [[ "$got" != "0" ]]
}

afk_target_path() { # <target id>
  printf '%s' "$AFK_RD_TARGET_ENTRIES" | jq -sr --arg id "$1" \
    'map(select(.id == $id)) | if length > 0 then .[0].path else "" end'
}

# --- the orchestration-state bridge (FR-88 through FR-90) -------------------
#
# Read-only, bounded, and CONSUMED rather than owned. The lifecycle never
# reconstructs this from terminals, transcripts or logs, never repairs it, and
# never fails ordinary readiness because it is absent. Parent identity and
# child counts are represented generically: `parent = PM` is one arrangement of
# a supervised session, not the shape of the model, and nothing here implements
# worker-originated delegation.

afk_evaluate_orchestration() {
  local doc major state

  AFK_R_ORCHESTRATION="$(jq -nc '{state: "NOT_AVAILABLE", evaluated: false,
    reason: "ORCHESTRATION_STATE_NOT_AVAILABLE", session: null, parent: null, workers: null}')"

  [[ -n "$AFK_ORCH_STATE" ]] || return 0
  if [[ ! -e "$AFK_ORCH_STATE" && ! -L "$AFK_ORCH_STATE" ]]; then
    return 0
  fi
  if ! doc="$(jq -c '.' "$AFK_ORCH_STATE" 2>/dev/null)"; then
    AFK_R_ORCHESTRATION="$(jq -nc '{state: "NOT_AVAILABLE", evaluated: true,
      reason: "ORCHESTRATION_STATE_UNREADABLE", session: null, parent: null, workers: null}')"
    afk_add_finding "orchestration" "EXTERNAL_STATE" "UNKNOWN" "ORCHESTRATION_STATE_UNREADABLE" \
      "warning" "" "FILE_STRUCTURE" "normalized orchestration state" "unparseable" "true" "false" ""
    return 0
  fi
  major="$(printf '%s' "$doc" | jq -r 'if (.schema_version | type) == "string"
    then (.schema_version | split(".")[0]) else "" end')"
  if [[ -z "$major" || ! "$major" =~ ^[0-9]+$ ]] || (( major > AFK_SUPPORTED_ORCH_STATE_MAJOR )); then
    AFK_R_ORCHESTRATION="$(jq -nc '{state: "NOT_AVAILABLE", evaluated: true,
      reason: "ORCHESTRATION_STATE_SCHEMA_UNSUPPORTED", session: null, parent: null, workers: null}')"
    afk_add_finding "orchestration" "EXTERNAL_STATE" "INCOMPATIBLE" \
      "ORCHESTRATION_STATE_SCHEMA_UNSUPPORTED" "warning" "" "MANIFEST_SCHEMA" \
      "$AFK_SUPPORTED_ORCH_STATE_MAJOR.x" "${major:-unparseable}" "true" "false" ""
    return 0
  fi

  # A bounded summary of the members this contract publishes, and nothing else.
  # A state document is someone else's territory; copying it through wholesale
  # would make the lifecycle an arbitrary passthrough for content it has never
  # declared and cannot vouch for.
  AFK_R_ORCHESTRATION="$(printf '%s' "$doc" | jq -c '
    def enumval($v; $allowed; $fallback):
      if (($v | type) == "string") and (($allowed | index($v)) != null) then $v else $fallback end;
    {state: enumval(.session.state; ["ACTIVE", "INACTIVE"]; "NOT_AVAILABLE"),
     evaluated: true,
     reason: (if enumval(.session.state; ["ACTIVE"]; "") == "ACTIVE"
              then "ORCHESTRATION_STATE_AVAILABLE"
              else "ORCHESTRATION_SESSION_INACTIVE" end),
     session: {mode: enumval(.session.mode; ["PLAN", "ORCH", "WORKER"]; null),
               phase: (if (.session.phase | type) == "string" then .session.phase else null end),
               task: (if (.session.task | type) == "string" then .session.task else null end),
               needs_human: (.session.needs_human == true)},
     parent: {role: (if (.parent.role | type) == "string" then .parent.role else null end),
              id: (if (.parent.id | type) == "string" then .parent.id else null end)},
     workers: {available: (if (.workers.available | type) == "number" then .workers.available else 0 end),
               by_state: (if (.workers.by_state | type) == "object" then .workers.by_state else {} end)}}')"
  if [[ -z "$AFK_R_ORCHESTRATION" ]]; then
    AFK_R_ORCHESTRATION='{"state":"NOT_AVAILABLE","evaluated":true,"reason":"ORCHESTRATION_STATE_UNREADABLE","session":null,"parent":null,"workers":null}'
    return 0
  fi

  state="$(printf '%s' "$AFK_R_ORCHESTRATION" | jq -r '.state')"
  if [[ "$state" == "ACTIVE" ]] \
     && [[ "$(printf '%s' "$AFK_R_ORCHESTRATION" | jq -r '.session.needs_human')" == "true" ]]; then
    # Loud, and deliberately scoped to nothing: a supervised session waiting on
    # a human is an owner action, but it is not a defect of this installation
    # and must not make ordinary lifecycle or host readiness fail (FR-90).
    afk_add_finding "orchestration" "EXTERNAL_STATE" "EXTERNAL_STATE" "ORCHESTRATION_NEEDS_HUMAN" \
      "owner_action" "" "FILE_STRUCTURE" "no pending question" "NEEDS HUMAN" "true" "false" \
      "$(printf '%s' "$AFK_R_ORCHESTRATION" | jq -r '.session.task // "unnamed task"')"
  fi
  return 0
}

# --- the supplied execution stamp (offline, deterministic) ------------------
#
# Everything here is a property of the document plus this host's declarations.
# The validator remains the authority on catalog, provenance, expiry, funding
# and policy; the kit records and checks its contract without reimplementing
# its rules (FR-67).

AFK_STAMP_CLOSED_KEYS='["harness","model_profile","effort","cost_class","entitlement_pool","metered","placement_policy","placement_required","catalog_version","catalog_document_version","expires_at","task","override","created_at"]'

afk_stamp_shape_is_valid() { # <path>
  jq -e --argjson closed "$AFK_STAMP_CLOSED_KEYS" '
    (type == "object")
    and (.harness | type == "string") and (.harness | length > 0)
    and (.model_profile | type == "string") and (.model_profile | length > 0)
    and (.effort | type == "string") and (.effort | length > 0)
    and (.cost_class | type == "string") and (.cost_class | length > 0)
    and (.metered | type == "boolean")
    and (.placement_required | type == "boolean")
    and (.catalog_version | type == "string") and (.catalog_version | length > 0)
    and (.expires_at | type == "string")
    and (.expires_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and (.task | type == "object")
    and (.task.story_id | type == "string") and (.task.story_id | length > 0)
    and (([keys[]] - $closed) | length == 0)
  ' "$1" >/dev/null 2>&1
}

# Epoch seconds for an RFC3339 UTC instant, without depending on one date(1)
# dialect. Returns non-zero when neither dialect can read it, and the caller
# then reports the expiry as unproven rather than guessing at it.
afk_epoch_of_utc() { # <YYYY-MM-DDTHH:MM:SSZ>
  local s
  s="$(date -u -d "$1" +%s 2>/dev/null)" \
    || s="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null)" \
    || return 1
  [[ -n "$s" ]] || return 1
  printf '%s' "$s"
}

afk_load_stamp() {
  local j
  [[ -n "$AFK_STAMP_FILE" ]] || return 1
  if [[ ! -f "$AFK_STAMP_FILE" ]]; then
    AFK_RD_ROUTE_STATE="FALSE"; AFK_RD_ROUTE_REASON="STAMP_UNREADABLE"
    return 1
  fi
  if ! j="$(jq -c '.' "$AFK_STAMP_FILE" 2>/dev/null)"; then
    AFK_RD_ROUTE_STATE="FALSE"; AFK_RD_ROUTE_REASON="STAMP_UNREADABLE"
    return 1
  fi
  if ! afk_stamp_shape_is_valid "$AFK_STAMP_FILE"; then
    AFK_RD_ROUTE_STATE="FALSE"; AFK_RD_ROUTE_REASON="STAMP_SHAPE_INVALID"
    return 1
  fi
  AFK_STAMP_JSON="$j"
  AFK_STAMP_PRESENT="true"
  AFK_STAMP_HARNESS="$(printf '%s' "$j" | jq -r '.harness')"
  AFK_STAMP_PROFILE="$(printf '%s' "$j" | jq -r '.model_profile')"
  AFK_STAMP_EFFORT="$(printf '%s' "$j" | jq -r '.effort')"
  AFK_STAMP_COST_CLASS="$(printf '%s' "$j" | jq -r '.cost_class')"
  AFK_STAMP_METERED="$(printf '%s' "$j" | jq -r '.metered')"
  AFK_STAMP_PLACEMENT_REQUIRED="$(printf '%s' "$j" | jq -r '.placement_required')"
  AFK_STAMP_IDENTITY="$(afk_sha256_file "$AFK_STAMP_FILE")"
  return 0
}

# The kit's own launch-contract declaration, mirrored from the launch adapter.
# It answers only "can THIS executor drive that pair", never "is that pair
# allowed" — the catalog already answered the second question.
afk_launch_contract_reason() { # <harness> <profile> <placement_required>
  if ! afk_list_contains "$1" "$AFK_APPROVED_HARNESSES"; then
    printf 'no launch contract for harness %s' "$1"
    return 0
  fi
  if [[ "$3" == "true" ]]; then
    printf 'profile %s requires placement; the %s launch contract covers native vendor subscription execution only' \
      "$2" "$1"
    return 0
  fi
  printf ''
}

# --- funding and metered-path conflicts (FR-62, FR-63) ----------------------
#
# Presence of a NAME, never a value. Nothing is read, nothing is persisted, and
# nothing is emitted beyond the name and the redacted presence the environment
# section already publishes.

afk_funding_conflict_vars() { # <harness>
  case "$1" in
    claude) printf '%s\n' "$AFK_CLAUDE_FUNDING_CONFLICT_VARS" ;;
    codex)  printf '%s\n' "$AFK_CODEX_FUNDING_CONFLICT_VARS" ;;
    *)      printf '' ;;
  esac
}

# afk_route_funding_conflict <harness> <cost_class> <metered>
# Prints the conflicting variable names, one per line. Empty means no conflict.
afk_route_funding_conflict() {
  local harness="$1" cost_class="$2" metered="$3" name found=""
  # An explicitly authorized API-backed entitlement is a legitimate funding
  # class, so credential SHAPE alone is never treated as proof that every
  # API-backed path is forbidden (FR-63). Only a route approved for native
  # subscription funding can be endangered by a metered redirection.
  if [[ "$metered" == "true" || "$cost_class" == "metered" || "$cost_class" == "api" ]]; then
    return 0
  fi
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ -n "${!name-}" ]]; then found="${found}${name}"$'\n'; fi
  done < <(afk_funding_conflict_vars "$harness")
  printf '%s' "$found"
}

# --- harness workspace trust (offline) --------------------------------------
#
# Claude Code saves workspace trust per directory in its own user-owned project
# state. The lifecycle reads that record for the selected path and reports an
# awaiting-trust path as an affected-harness condition. It never edits that
# database, never automates acceptance, and never proposes prompt-skipping as a
# workaround: the prompt is a protected decision and the only supported answer
# is a human.

afk_claude_workspace_trusted() { # <absolute path> -> 0 trusted, 1 awaiting, 2 unknown
  local db="$AFK_CLAUDE_TRUST_DB" got
  [[ -n "$db" && -f "$db" && -n "$1" ]] || return 2
  got="$(jq -r --arg p "$1" '
    if ((.projects | type) == "object") and ((.projects[$p] | type) == "object")
    then (if .projects[$p].hasTrustDialogAccepted == true then "yes" else "no" end)
    else "unknown" end' "$db" 2>/dev/null)" || return 2
  case "$got" in
    yes) return 0 ;;
    no)  return 1 ;;
    *)   return 2 ;;
  esac
}

afk_evaluate_workspace_trust() { # <path or empty>
  local p="$1" rc
  if [[ -z "$p" ]]; then
    afk_live_fact "claude_workspace_trust" "NOT_EVALUATED" "NO_SELECTED_WORKSPACE" "FILE_STRUCTURE" "false" "false" ""
    return 0
  fi
  afk_claude_workspace_trusted "$p"
  rc=$?
  case "$rc" in
    0)
      afk_live_fact "claude_workspace_trust" "AVAILABLE" "WORKSPACE_TRUST_ESTABLISHED" "FILE_STRUCTURE" "true" "false" "$p"
      return 0 ;;
    1)
      afk_live_fact "claude_workspace_trust" "UNAVAILABLE" "WORKSPACE_TRUST_REQUIRED" "FILE_STRUCTURE" "true" "false" "$p"
      afk_add_finding "claude" "EXTERNAL_STATE" "UNAVAILABLE" "WORKSPACE_TRUST_REQUIRED" \
        "owner_action" "ROUTE_READY" "FILE_STRUCTURE" \
        "an accepted workspace-trust decision for this path" "awaiting the protected prompt" \
        "true" "false" "$p"
      return 1 ;;
    *)
      afk_live_fact "claude_workspace_trust" "UNKNOWN" "WORKSPACE_TRUST_UNPROVEN" "FILE_STRUCTURE" "true" "false" "$p"
      return 0 ;;
  esac
}

# --- live probes ------------------------------------------------------------

afk_probe_orca() {
  local bin="$AFK_ORCA_BIN" cap missing=""
  if [[ "$(afk_executable_state orca)" != "PRESENT" ]]; then
    AFK_RD_ORCA="FALSE"
    afk_live_fact "orca_runtime" "UNAVAILABLE" "ORCA_NOT_RESOLVED" "PATH_STRUCTURE" "true" "false" "$bin"
    afk_live_fact "orca_capability" "NOT_EVALUATED" "ORCA_NOT_RESOLVED" "PATH_STRUCTURE" "false" "false" ""
    afk_add_finding "orca" "EXTERNAL_STATE" "UNAVAILABLE" "ORCA_NOT_RESOLVED" \
      "blocking" "HOST_EXECUTION_READY" "PATH_STRUCTURE" "an executable orca" "absent" "true" "false" "$bin"
    return 1
  fi

  # Read-only runtime reachability. A disposable worker is never created to
  # answer this question (FR-55): routine readiness that manufactures a worker
  # is not readiness, it is work.
  if ! afk_probe_run "$bin" status --json; then
    AFK_RD_ORCA="UNAVAILABLE"; AFK_RD_LIVE_UNAVAILABLE="true"
    if [[ "$AFK_PROBE_STATUS" == "TIMEOUT" ]]; then
      afk_live_fact "orca_runtime" "UNAVAILABLE" "ORCA_PROBE_TIMED_OUT" "CAPABILITY_PROBE" "true" "true" ""
      afk_add_finding "orca" "EXTERNAL_STATE" "UNAVAILABLE" "ORCA_PROBE_TIMED_OUT" \
        "blocking" "HOST_EXECUTION_READY" "CAPABILITY_PROBE" \
        "a status response inside $AFK_LIVE_TIMEOUT_MS ms" "timed out" "true" "true" ""
    else
      afk_live_fact "orca_runtime" "UNAVAILABLE" "ORCA_PROBE_FAILED" "CAPABILITY_PROBE" "true" "true" "exit $AFK_PROBE_RC"
      afk_add_finding "orca" "EXTERNAL_STATE" "UNAVAILABLE" "ORCA_PROBE_FAILED" \
        "blocking" "HOST_EXECUTION_READY" "CAPABILITY_PROBE" \
        "a readable status response" "exit $AFK_PROBE_RC" "true" "true" ""
    fi
    afk_live_fact "orca_capability" "NOT_EVALUATED" "ORCA_PROBE_FAILED" "CAPABILITY_PROBE" "false" "true" ""
    return 1
  fi
  afk_live_fact "orca_runtime" "AVAILABLE" "ORCA_RUNTIME_REACHABLE" "CAPABILITY_PROBE" "true" "false" ""

  # Explicit capabilities are preferred over a version-only assumption (FR-68).
  # A version number that has to be interpreted is a guess about behaviour; a
  # capability list is the dependency answering for itself.
  if ! afk_probe_run "$bin" capabilities --json; then
    AFK_RD_ORCA="FALSE"
    afk_live_fact "orca_capability" "UNKNOWN" "ORCA_CAPABILITY_UNPROVEN" "CAPABILITY_PROBE" "true" "false" ""
    afk_add_finding "orca" "EXTERNAL_STATE" "UNKNOWN" "ORCA_CAPABILITY_UNPROVEN" \
      "blocking" "HOST_EXECUTION_READY" "CAPABILITY_PROBE" \
      "an explicit capability contract" "not offered" "true" "false" ""
    return 1
  fi
  while IFS= read -r cap; do
    [[ -n "$cap" ]] || continue
    if ! printf '%s' "$AFK_PROBE_OUT" | jq -e --arg c "$cap" \
         '((.capabilities // []) | index($c)) != null' >/dev/null 2>&1; then
      missing="${missing}${cap} "
    fi
  done <<< "$AFK_REQUIRED_ORCA_CAPABILITIES"
  if [[ -n "$missing" ]]; then
    AFK_RD_ORCA="FALSE"
    afk_live_fact "orca_capability" "INCOMPATIBLE" "ORCA_CAPABILITY_INCOMPATIBLE" "CAPABILITY_PROBE" "true" "false" "${missing% }"
    afk_add_finding "orca" "EXTERNAL_STATE" "INCOMPATIBLE" "ORCA_CAPABILITY_INCOMPATIBLE" \
      "blocking" "HOST_EXECUTION_READY" "CAPABILITY_PROBE" \
      "every required launch capability" "missing: ${missing% }" "true" "false" ""
    return 1
  fi
  AFK_RD_ORCA="TRUE"
  afk_live_fact "orca_capability" "COMPATIBLE" "ORCA_CAPABILITY_PROVEN" "CAPABILITY_PROBE" "true" "false" ""
  return 0
}

# --- the validator contract and its offline fixture suite (FR-58) -----------
#
# The kit does not decide whether a stamp is valid; it decides whether the
# thing that decides is usable. The negative fixtures are the point: a
# validator that answers "valid" to everything is worse than an absent one,
# because every refusal downstream would then be a rubber stamp.

afk_validator_fixture_dir_create() {
  local d
  d="$(mktemp -d 2>/dev/null)" || return 1
  [[ -n "$d" && -d "$d" ]] || return 1
  AFK_VALIDATOR_FIXTURE_DIR="$d"
  return 0
}

afk_validator_fixture_dir_remove() {
  # Only ever the exact directory this process created, never a caller-supplied
  # path and never a pattern.
  if [[ -n "$AFK_VALIDATOR_FIXTURE_DIR" && -d "$AFK_VALIDATOR_FIXTURE_DIR" ]]; then
    rm -rf -- "$AFK_VALIDATOR_FIXTURE_DIR"
  fi
  AFK_VALIDATOR_FIXTURE_DIR=""
}

afk_validator_fixtures_write() { # <dir>
  local d="$1"
  cat > "$d/catalog.yaml" <<'YAML' || return 1
schema_version: 1
profiles:
  "claude/strong":
    hosting: vendor
    physical:
      - model_id: "claude/opus"
        placement: null
YAML
  jq -n '{harness: "claude", model_profile: "claude/strong", effort: "high",
          cost_class: "subscription", entitlement_pool: "anthropic-max", metered: false,
          placement_policy: "prefer-warm-local", placement_required: false,
          catalog_version: "sha256:fixture", expires_at: "2099-01-01T00:00:00Z",
          task: {story_id: "AFK-READINESS-FIXTURE", tags: ["docs"]}, override: null}' \
    > "$d/valid.stamp.json" || return 1
  jq '.expires_at = "2000-01-01T00:00:00Z"' "$d/valid.stamp.json" > "$d/expired.stamp.json" || return 1
  jq '.model_profile = "claude/strong-TAMPERED"' "$d/valid.stamp.json" > "$d/tampered.stamp.json" || return 1
  jq '.catalog_version = "sha256:not-this-catalog"' "$d/valid.stamp.json" \
    > "$d/provenance.stamp.json" || return 1
  jq '.effort = "banana"' "$d/valid.stamp.json" > "$d/incompatible.stamp.json" || return 1
  return 0
}

# afk_validator_verdict <catalog> <stamp> -> 0 accepted, 1 rejected, 2 unusable
#
# Only an exit status of exactly 1 is the validator's POLICY answer. Anything
# else — it could not start, it timed out, it fell over on the document — is a
# dependency that did not answer, and reading that as a refusal would turn a
# temporarily unavailable validator into a proven verdict. The two are
# different facts with different exit semantics for the run.
afk_validator_verdict() {
  if afk_probe_run "$AFK_VALIDATOR_BIN" --catalog "$1" --stamp "$2"; then
    return 0
  fi
  if [[ "$AFK_PROBE_STATUS" == "NONZERO" ]] && (( AFK_PROBE_RC == 1 )); then
    return 1
  fi
  return 2
}

afk_probe_validator() {
  local d ver rc accepted_negatives=0 negatives=0 unanswered=0 name
  if [[ "$(afk_executable_state validator)" != "PRESENT" ]]; then
    AFK_RD_VALIDATOR="FALSE"
    afk_live_fact "validator_contract" "UNAVAILABLE" "VALIDATOR_NOT_RESOLVED" "PATH_STRUCTURE" "true" "false" "$AFK_VALIDATOR_BIN"
    afk_live_fact "validator_fixtures" "NOT_EVALUATED" "VALIDATOR_NOT_RESOLVED" "PATH_STRUCTURE" "false" "false" ""
    afk_add_finding "validator" "EXTERNAL_STATE" "UNAVAILABLE" "VALIDATOR_NOT_RESOLVED" \
      "blocking" "HOST_EXECUTION_READY" "PATH_STRUCTURE" \
      "an executable stamp validator" "absent" "true" "false" "$AFK_VALIDATOR_BIN"
    return 1
  fi

  # The machine-readable identity and supported contract, recorded rather than
  # reimplemented (FR-67).
  if afk_probe_run "$AFK_VALIDATOR_BIN" --contract; then
    ver="$(printf '%s' "$AFK_PROBE_OUT" | jq -r 'if (.stamp_schema_version | type) == "string"
      then (.stamp_schema_version | split(".")[0]) else "" end' 2>/dev/null)" || ver=""
    if [[ -n "$ver" && "$ver" =~ ^[0-9]+$ ]] && (( ver > AFK_SUPPORTED_VALIDATOR_CONTRACT_MAJOR )); then
      AFK_RD_VALIDATOR="FALSE"
      afk_live_fact "validator_contract" "INCOMPATIBLE" "VALIDATOR_CONTRACT_INCOMPATIBLE" "VALIDATOR_FIXTURE" "true" "false" "$ver"
      afk_live_fact "validator_fixtures" "NOT_EVALUATED" "VALIDATOR_CONTRACT_INCOMPATIBLE" "VALIDATOR_FIXTURE" "false" "false" ""
      afk_add_finding "validator" "EXTERNAL_STATE" "INCOMPATIBLE" "VALIDATOR_CONTRACT_INCOMPATIBLE" \
        "blocking" "HOST_EXECUTION_READY" "VALIDATOR_FIXTURE" \
        "$AFK_SUPPORTED_VALIDATOR_CONTRACT_MAJOR.x" "$ver" "true" "false" ""
      return 1
    fi
    afk_live_fact "validator_contract" "COMPATIBLE" "VALIDATOR_CONTRACT_PROVEN" "VALIDATOR_FIXTURE" "true" "false" "${ver:-unversioned}"
  else
    # No machine-readable contract at all is not fatal on its own: the fixture
    # suite below is the behavioural proof, and it is the one that matters.
    afk_live_fact "validator_contract" "UNKNOWN" "VALIDATOR_CONTRACT_UNREADABLE" "VALIDATOR_FIXTURE" "true" "false" ""
    afk_add_finding "validator" "EXTERNAL_STATE" "UNKNOWN" "VALIDATOR_CONTRACT_UNREADABLE" \
      "warning" "" "VALIDATOR_FIXTURE" "a machine-readable contract" "not offered" "true" "false" ""
  fi

  if ! afk_validator_fixture_dir_create || ! afk_validator_fixtures_write "$AFK_VALIDATOR_FIXTURE_DIR"; then
    afk_validator_fixture_dir_remove
    AFK_RD_VALIDATOR="FALSE"
    afk_live_fact "validator_fixtures" "UNKNOWN" "VALIDATOR_FIXTURE_FAILED" "VALIDATOR_FIXTURE" "true" "false" "fixtures could not be materialized"
    afk_add_finding "validator" "EXTERNAL_STATE" "UNKNOWN" "VALIDATOR_FIXTURE_FAILED" \
      "blocking" "HOST_EXECUTION_READY" "VALIDATOR_FIXTURE" \
      "a writable temporary directory" "unavailable" "true" "false" ""
    return 1
  fi
  d="$AFK_VALIDATOR_FIXTURE_DIR"

  afk_validator_verdict "$d/catalog.yaml" "$d/valid.stamp.json"
  rc=$?
  if (( rc == 2 )); then
    # The validator did not answer. That is a transient live condition, not a
    # refusal of the fixture, and the run's exit code has to say so.
    afk_validator_fixture_dir_remove
    AFK_RD_VALIDATOR="UNAVAILABLE"
    AFK_RD_LIVE_UNAVAILABLE="true"
    afk_live_fact "validator_fixtures" "UNAVAILABLE" "VALIDATOR_VERDICT_UNAVAILABLE" "VALIDATOR_FIXTURE" "true" "true" \
      "no verdict on the known-valid fixture"
    afk_add_finding "validator" "EXTERNAL_STATE" "UNAVAILABLE" "VALIDATOR_VERDICT_UNAVAILABLE" \
      "blocking" "HOST_EXECUTION_READY" "VALIDATOR_FIXTURE" \
      "a verdict on a known-valid fixture" "no verdict" "true" "true" ""
    return 1
  fi
  if (( rc != 0 )); then
    afk_validator_fixture_dir_remove
    AFK_RD_VALIDATOR="FALSE"
    afk_live_fact "validator_fixtures" "INCOMPATIBLE" "VALIDATOR_FIXTURE_FAILED" "VALIDATOR_FIXTURE" "true" "false" "known-valid fixture not accepted"
    afk_add_finding "validator" "EXTERNAL_STATE" "INCOMPATIBLE" "VALIDATOR_FIXTURE_FAILED" \
      "blocking" "HOST_EXECUTION_READY" "VALIDATOR_FIXTURE" \
      "a known-valid fixture accepted" "not accepted" "true" "false" ""
    return 1
  fi

  for name in expired tampered provenance incompatible; do
    negatives=$((negatives + 1))
    afk_validator_verdict "$d/catalog.yaml" "$d/$name.stamp.json"
    rc=$?
    if (( rc == 0 )); then
      accepted_negatives=$((accepted_negatives + 1))
    elif (( rc == 2 )); then
      unanswered=$((unanswered + 1))
    fi
  done
  afk_validator_fixture_dir_remove

  if (( unanswered > 0 )); then
    # A negative fixture nobody answered is not a rejection, so the anti-vacuity
    # control below would be counting a silence as a proof.
    AFK_RD_VALIDATOR="UNAVAILABLE"
    AFK_RD_LIVE_UNAVAILABLE="true"
    afk_live_fact "validator_fixtures" "UNAVAILABLE" "VALIDATOR_VERDICT_UNAVAILABLE" "VALIDATOR_FIXTURE" "true" "true" \
      "$unanswered of $negatives negative fixtures unanswered"
    afk_add_finding "validator" "EXTERNAL_STATE" "UNAVAILABLE" "VALIDATOR_VERDICT_UNAVAILABLE" \
      "blocking" "HOST_EXECUTION_READY" "VALIDATOR_FIXTURE" \
      "a verdict on every negative fixture" "$unanswered unanswered" "true" "true" ""
    return 1
  fi

  # The anti-vacuity control. An always-success validator accepts every one of
  # the negatives, and that is the only condition this check fails on: judging
  # WHICH refusals are correct would be reimplementing validator policy, which
  # FR-67 puts on the other side of the boundary.
  if (( negatives > 0 && accepted_negatives == negatives )); then
    AFK_RD_VALIDATOR="FALSE"
    afk_live_fact "validator_fixtures" "INCOMPATIBLE" "VALIDATOR_ANTI_VACUITY_FAILED" "VALIDATOR_FIXTURE" "true" "false" \
      "$accepted_negatives of $negatives negative fixtures accepted"
    afk_add_finding "validator" "EXTERNAL_STATE" "INCOMPATIBLE" "VALIDATOR_ANTI_VACUITY_FAILED" \
      "blocking" "HOST_EXECUTION_READY" "VALIDATOR_FIXTURE" \
      "at least one negative fixture rejected" "every negative fixture accepted" "true" "false" ""
    return 1
  fi

  AFK_RD_VALIDATOR="TRUE"
  afk_live_fact "validator_fixtures" "COMPATIBLE" "VALIDATOR_FIXTURES_PROVEN" "VALIDATOR_FIXTURE" "true" "false" \
    "$((negatives - accepted_negatives)) of $negatives negative fixtures rejected"
  return 0
}

# --- native harness readiness (FR-60, FR-61, FR-70) -------------------------

afk_harness_required_flags() { # <harness>
  case "$1" in
    claude) printf '%s\n' --model --permission-mode --append-system-prompt-file --strict-mcp-config ;;
    codex)  printf '%s\n' --sandbox --config exec ;;
    *)      printf '' ;;
  esac
}

afk_harness_auth_classification() { # <harness> <probe output>
  case "$1" in
    claude)
      case "$2" in
        *'claude.ai'*|*'firstParty'*|*'subscription'*)       printf 'NATIVE_SUBSCRIPTION' ;;
        *'apiKey'*|*'api_key'*|*'console.anthropic'*)        printf 'API_KEY' ;;
        *'Not logged in'*|*'not authenticated'*|*'expired'*) printf 'AUTH_REQUIRED' ;;
        *)                                                   printf 'UNKNOWN' ;;
      esac ;;
    codex)
      case "$2" in
        *'Logged in using ChatGPT'*|*'ChatGPT'*|*'chatgpt'*) printf 'NATIVE_SUBSCRIPTION' ;;
        *'API key'*|*'api key'*|*'apiKey'*)                  printf 'API_KEY' ;;
        *'Not logged in'*|*'not logged in'*|*'expired'*)     printf 'AUTH_REQUIRED' ;;
        *)                                                   printf 'UNKNOWN' ;;
      esac ;;
    *) printf 'UNKNOWN' ;;
  esac
}

# afk_probe_harness <harness> -> 0 when a complete approved path is usable
afk_probe_harness() {
  local h="$1" bin cap_key auth_key cls flag help_out missing=""
  bin="$(afk_harness_binary "$h")"
  cap_key="${h}_capability"
  auth_key="${h}_native_session"

  if [[ "$(afk_executable_state "$h")" != "PRESENT" ]]; then
    afk_live_fact "$cap_key" "UNAVAILABLE" "HARNESS_NOT_RESOLVED" "PATH_STRUCTURE" "true" "false" "$bin"
    afk_live_fact "$auth_key" "NOT_EVALUATED" "HARNESS_NOT_RESOLVED" "PATH_STRUCTURE" "false" "false" ""
    # Scoped to the harness, never to the host: another complete approved path
    # may well be healthy, and both harnesses are never globally mandatory.
    afk_add_finding "$h" "EXTERNAL_STATE" "UNAVAILABLE" "HARNESS_NOT_RESOLVED" \
      "warning" "" "PATH_STRUCTURE" "an executable $h" "absent" "true" "false" "$bin"
    return 1
  fi

  # Invocation capability: the flags the frozen launch contract actually uses.
  # A newer version whose required capabilities are all positively proven stays
  # ready; one that cannot prove them does not (FR-70).
  if ! afk_probe_run "$bin" --help; then
    afk_live_fact "$cap_key" "UNKNOWN" "HARNESS_CAPABILITY_UNPROVEN" "CAPABILITY_PROBE" "true" "false" "exit $AFK_PROBE_RC"
    afk_live_fact "$auth_key" "NOT_EVALUATED" "HARNESS_CAPABILITY_UNPROVEN" "CAPABILITY_PROBE" "false" "false" ""
    afk_add_finding "$h" "EXTERNAL_STATE" "UNKNOWN" "HARNESS_CAPABILITY_UNPROVEN" \
      "warning" "" "CAPABILITY_PROBE" "a readable invocation contract" "unreadable" "true" "false" ""
    return 1
  fi
  help_out="$AFK_PROBE_OUT"
  while IFS= read -r flag; do
    [[ -n "$flag" ]] || continue
    case "$help_out" in
      *"$flag"*) : ;;
      *) missing="${missing}${flag} " ;;
    esac
  done < <(afk_harness_required_flags "$h")
  if [[ -n "$missing" ]]; then
    afk_live_fact "$cap_key" "INCOMPATIBLE" "HARNESS_CAPABILITY_UNPROVEN" "CAPABILITY_PROBE" "true" "false" "${missing% }"
    afk_live_fact "$auth_key" "NOT_EVALUATED" "HARNESS_CAPABILITY_UNPROVEN" "CAPABILITY_PROBE" "false" "false" ""
    afk_add_finding "$h" "EXTERNAL_STATE" "INCOMPATIBLE" "HARNESS_CAPABILITY_UNPROVEN" \
      "warning" "" "CAPABILITY_PROBE" "every required invocation capability" \
      "missing: ${missing% }" "true" "false" ""
    return 1
  fi
  afk_live_fact "$cap_key" "COMPATIBLE" "HARNESS_CAPABILITY_PROVEN" "CAPABILITY_PROBE" "true" "false" ""

  # Authentication CLASS through the harness's own safe status mechanism. No
  # credential value is read, copied, persisted or displayed, and a stale
  # session is reported rather than refreshed: automatic login is never a
  # readiness action.
  case "$h" in
    claude) afk_probe_run "$bin" auth status ;;
    codex)  afk_probe_run "$bin" login status ;;
    *)      AFK_PROBE_STATUS="NOT_RESOLVED"; AFK_PROBE_OUT="" ;;
  esac
  if [[ "$AFK_PROBE_STATUS" == "TIMEOUT" ]]; then
    AFK_RD_LIVE_UNAVAILABLE="true"
    afk_live_fact "$auth_key" "UNAVAILABLE" "AUTH_STATUS_UNPROVEN" "AUTH_STATUS_PROBE" "true" "true" "timed out"
    afk_add_finding "$h" "EXTERNAL_STATE" "UNAVAILABLE" "AUTH_STATUS_UNPROVEN" \
      "warning" "" "AUTH_STATUS_PROBE" "a safe auth-status answer" "timed out" "true" "true" ""
    return 1
  fi
  cls="$(afk_harness_auth_classification "$h" "$AFK_PROBE_OUT")"
  if [[ "$AFK_PROBE_STATUS" != "OK" && "$cls" == "UNKNOWN" ]]; then
    cls="AUTH_REQUIRED"
  fi
  case "$cls" in
    NATIVE_SUBSCRIPTION)
      afk_live_fact "$auth_key" "AVAILABLE" "AUTH_NATIVE_SUBSCRIPTION" "AUTH_STATUS_PROBE" "true" "false" ""
      return 0 ;;
    API_KEY)
      # A credential record of a different funding class is not a defect on its
      # own; it becomes one only for a route approved for native subscription
      # funding, which is decided per route rather than globally (FR-63).
      afk_live_fact "$auth_key" "AVAILABLE" "AUTH_MODE_UNSUPPORTED" "AUTH_STATUS_PROBE" "true" "false" ""
      afk_add_finding "$h" "EXTERNAL_STATE" "EXTERNAL_STATE" "AUTH_MODE_UNSUPPORTED" \
        "warning" "" "AUTH_STATUS_PROBE" "a native subscription session" "an API-key session" \
        "true" "false" ""
      return 1 ;;
    AUTH_REQUIRED)
      afk_live_fact "$auth_key" "UNAVAILABLE" "AUTH_REQUIRED" "AUTH_STATUS_PROBE" "true" "false" ""
      afk_add_finding "$h" "EXTERNAL_STATE" "UNAVAILABLE" "AUTH_REQUIRED" \
        "owner_action" "" "AUTH_STATUS_PROBE" "a usable native session" "login required" \
        "true" "false" ""
      return 1 ;;
    *)
      afk_live_fact "$auth_key" "UNKNOWN" "AUTH_STATUS_UNPROVEN" "AUTH_STATUS_PROBE" "true" "false" ""
      afk_add_finding "$h" "EXTERNAL_STATE" "UNKNOWN" "AUTH_STATUS_UNPROVEN" \
        "warning" "" "AUTH_STATUS_PROBE" "a classifiable auth status" "unclassifiable" \
        "true" "false" ""
      return 1 ;;
  esac
}

# --- router live readiness (FR-57) ------------------------------------------

afk_probe_router() {
  local url token_name http body catalog stamp_catalog
  url="${AGENT_ROUTER_URL:-}"
  url="${url%/}"

  if [[ -z "$url" ]]; then
    AFK_RD_ROUTER="FALSE"
    afk_live_fact "router_status" "UNAVAILABLE" "ROUTER_ENDPOINT_NOT_DECLARED" "PATH_STRUCTURE" "true" "false" ""
    afk_live_fact "router_catalog_provenance" "NOT_EVALUATED" "ROUTER_ENDPOINT_NOT_DECLARED" "PATH_STRUCTURE" "false" "false" ""
    afk_add_finding "router" "EXTERNAL_STATE" "UNAVAILABLE" "ROUTER_ENDPOINT_NOT_DECLARED" \
      "warning" "NEW_WORK_READY" "PATH_STRUCTURE" "a declared router endpoint" "none" "true" "false" ""
    return 1
  fi
  # Trusted transport is a precondition, not a preference: a caller token on a
  # plaintext channel is a leaked token.
  case "$url" in
    https://*) : ;;
    *)
      AFK_RD_ROUTER="FALSE"
      afk_live_fact "router_status" "INCOMPATIBLE" "ROUTER_TRANSPORT_UNTRUSTED" "ROUTER_STATUS" "true" "false" ""
      afk_live_fact "router_catalog_provenance" "NOT_EVALUATED" "ROUTER_TRANSPORT_UNTRUSTED" "ROUTER_STATUS" "false" "false" ""
      afk_add_finding "router" "EXTERNAL_STATE" "INCOMPATIBLE" "ROUTER_TRANSPORT_UNTRUSTED" \
        "blocking" "NEW_WORK_READY" "ROUTER_STATUS" "https" "plaintext transport" "true" "false" ""
      return 1 ;;
  esac

  token_name="$AFK_ROUTER_TOKEN_ENV"
  if [[ -z "${!token_name-}" ]]; then
    AFK_RD_ROUTER="FALSE"
    afk_live_fact "router_status" "UNAVAILABLE" "ROUTER_AUTH_MISSING" "ROUTER_STATUS" "true" "false" "$token_name"
    afk_live_fact "router_catalog_provenance" "NOT_EVALUATED" "ROUTER_AUTH_MISSING" "ROUTER_STATUS" "false" "false" ""
    afk_add_finding "router" "EXTERNAL_STATE" "UNAVAILABLE" "ROUTER_AUTH_MISSING" \
      "owner_action" "NEW_WORK_READY" "ROUTER_STATUS" "a populated $token_name" "unset" "true" "false" ""
    return 1
  fi

  # Bounded, read-only and authenticated. The caller token reaches the
  # transport and nothing else: it is never assigned to a reported variable,
  # never written to a file, and never included in any evidence field.
  afk_probe_run "$AFK_CURL_BIN" -sS -o /dev/null -w '%{http_code}' \
    --max-time "$(afk_probe_timeout_seconds)" \
    -H "Authorization: Bearer ${!token_name}" "$url/v1/status"
  case "$AFK_PROBE_STATUS" in
    OK) http="$AFK_PROBE_OUT" ;;
    TIMEOUT)
      AFK_RD_ROUTER="UNAVAILABLE"; AFK_RD_LIVE_UNAVAILABLE="true"
      afk_live_fact "router_status" "UNAVAILABLE" "ROUTER_TIMED_OUT" "ROUTER_STATUS" "true" "true" ""
      afk_live_fact "router_catalog_provenance" "NOT_EVALUATED" "ROUTER_TIMED_OUT" "ROUTER_STATUS" "false" "true" ""
      # Transient and narrowly scoped. Installed integrity keeps its own state,
      # host readiness is not revoked, and no local route is invented (FR-50).
      afk_add_finding "router" "EXTERNAL_STATE" "UNAVAILABLE" "ROUTER_TIMED_OUT" \
        "blocking" "NEW_WORK_READY" "ROUTER_STATUS" \
        "a status response inside $AFK_LIVE_TIMEOUT_MS ms" "timed out" "true" "true" ""
      return 1 ;;
    *)
      AFK_RD_ROUTER="UNAVAILABLE"; AFK_RD_LIVE_UNAVAILABLE="true"
      afk_live_fact "router_status" "UNAVAILABLE" "ROUTER_UNREACHABLE" "ROUTER_STATUS" "true" "true" "exit $AFK_PROBE_RC"
      afk_live_fact "router_catalog_provenance" "NOT_EVALUATED" "ROUTER_UNREACHABLE" "ROUTER_STATUS" "false" "true" ""
      afk_add_finding "router" "EXTERNAL_STATE" "UNAVAILABLE" "ROUTER_UNREACHABLE" \
        "blocking" "NEW_WORK_READY" "ROUTER_STATUS" "a reachable status endpoint" \
        "unreachable" "true" "true" ""
      return 1 ;;
  esac

  if [[ "$http" != "200" ]]; then
    AFK_RD_ROUTER="UNAVAILABLE"; AFK_RD_LIVE_UNAVAILABLE="true"
    afk_live_fact "router_status" "UNAVAILABLE" "ROUTER_UNREACHABLE" "ROUTER_STATUS" "true" "true" "HTTP $http"
    afk_live_fact "router_catalog_provenance" "NOT_EVALUATED" "ROUTER_UNREACHABLE" "ROUTER_STATUS" "false" "true" ""
    afk_add_finding "router" "EXTERNAL_STATE" "UNAVAILABLE" "ROUTER_UNREACHABLE" \
      "blocking" "NEW_WORK_READY" "ROUTER_STATUS" "HTTP 200" "HTTP $http" "true" "true" ""
    return 1
  fi

  # API shape: a 200 from something that is not the router is not the router.
  afk_probe_run "$AFK_CURL_BIN" -sS --max-time "$(afk_probe_timeout_seconds)" \
    -H "Authorization: Bearer ${!token_name}" "$url/v1/status"
  body="$AFK_PROBE_PARSE_OUT"
  # The complete response lives exactly as long as this parse: once it is in
  # the function-local copy, only the capped AFK_PROBE_OUT evidence may stay
  # reachable after the classification returns.
  AFK_PROBE_PARSE_OUT=""
  if ! printf '%s' "$body" | jq -e 'type == "object" and has("catalog_version")' >/dev/null 2>&1; then
    AFK_RD_ROUTER="FALSE"
    afk_live_fact "router_status" "INCOMPATIBLE" "ROUTER_API_SHAPE_UNSUPPORTED" "ROUTER_STATUS" "true" "false" ""
    afk_live_fact "router_catalog_provenance" "NOT_EVALUATED" "ROUTER_API_SHAPE_UNSUPPORTED" "ROUTER_STATUS" "false" "false" ""
    afk_add_finding "router" "EXTERNAL_STATE" "INCOMPATIBLE" "ROUTER_API_SHAPE_UNSUPPORTED" \
      "blocking" "NEW_WORK_READY" "ROUTER_STATUS" "a status document carrying catalog_version" \
      "unrecognized shape" "true" "false" ""
    return 1
  fi
  afk_live_fact "router_status" "AVAILABLE" "ROUTER_AVAILABLE" "ROUTER_STATUS" "true" "false" "HTTP 200"

  catalog="$(printf '%s' "$body" | jq -r '.catalog_version // ""')"
  stamp_catalog=""
  if [[ "$AFK_STAMP_PRESENT" == "true" ]]; then
    stamp_catalog="$(printf '%s' "$AFK_STAMP_JSON" | jq -r '.catalog_version')"
  fi
  if [[ -n "$stamp_catalog" && -n "$catalog" && "$catalog" != "$stamp_catalog" ]]; then
    afk_live_fact "router_catalog_provenance" "INCOMPATIBLE" "ROUTER_CATALOG_INCOMPATIBLE" "ROUTER_STATUS" "true" "false" ""
    afk_add_finding "router" "EXTERNAL_STATE" "INCOMPATIBLE" "ROUTER_CATALOG_INCOMPATIBLE" \
      "warning" "" "ROUTER_STATUS" "$stamp_catalog" "$catalog" "true" "false" ""
  else
    afk_live_fact "router_catalog_provenance" "COMPATIBLE" "ROUTER_CATALOG_COMPATIBLE" "ROUTER_STATUS" "true" "false" ""
  fi

  AFK_RD_ROUTER="TRUE"

  # The synthetic route request is a second, explicitly requested opt-in. It
  # asks the router for a recommendation and stamps nothing, launches nothing
  # and spends no provider token — but it is still an authenticated POST, so it
  # never happens merely because live mode was requested.
  if [[ "$AFK_SYNTHETIC_ROUTE" == "true" ]]; then
    afk_probe_run "$AFK_CURL_BIN" -sS -o /dev/null -w '%{http_code}' \
      --max-time "$(afk_probe_timeout_seconds)" -X POST \
      -H "Authorization: Bearer ${!token_name}" -H 'Content-Type: application/json' \
      -d '{"story_id":"AFK-READINESS-SYNTHETIC","title":"readiness probe","ambiguity":"low","blast_radius":"low","tags":["docs"]}' \
      "$url/v1/route"
    if [[ "$AFK_PROBE_STATUS" == "OK" && "$AFK_PROBE_OUT" == "200" ]]; then
      afk_live_fact "router_synthetic_route" "AVAILABLE" "ROUTER_AVAILABLE" "ROUTER_STATUS" "true" "false" "no stamp was created"
    else
      afk_live_fact "router_synthetic_route" "UNAVAILABLE" "ROUTER_API_SHAPE_UNSUPPORTED" "ROUTER_STATUS" "true" "true" ""
      afk_add_finding "router" "EXTERNAL_STATE" "UNAVAILABLE" "ROUTER_API_SHAPE_UNSUPPORTED" \
        "warning" "NEW_WORK_READY" "ROUTER_STATUS" "a synthetic route recommendation" \
        "unavailable" "true" "true" ""
    fi
  fi
  return 0
}

# --- route readiness (FR-49, FR-53, FR-64, FR-95) ---------------------------

afk_evaluate_route_readiness() {
  local reason="" conflicts="" target_id="" tpath="" expiry epoch now harness_state
  local contract_reason rc

  if [[ -z "$AFK_STAMP_FILE" ]]; then
    AFK_RD_ROUTE_STATE="OUT_OF_SCOPE"
    AFK_RD_ROUTE_REASON="NO_EXECUTION_STAMP_SUPPLIED"
    return 0
  fi
  if ! afk_load_stamp; then
    # The supplied path is NOT echoed back: an option value is caller-supplied
    # text, and a mistyped credential on a command line must not land in a
    # diagnostic. The caller knows which stamp it named.
    afk_add_finding "execution-stamp" "EXTERNAL_STATE" "INCOMPATIBLE" "$AFK_RD_ROUTE_REASON" \
      "blocking" "ROUTE_READY" "FILE_STRUCTURE" "a well-formed execution stamp" \
      "unusable" "true" "false" ""
    return 1
  fi

  # No physical inference placement is selected, persisted, added to the stamp
  # or assumed reusable here. Where a route requires placement it stays an
  # ephemeral per-attempt dispatch concern, and readiness says exactly that.
  afk_live_fact "route_placement" "OUT_OF_SCOPE" "PLACEMENT_NOT_A_LIFECYCLE_CONCERN" "OWNERSHIP_RULE" "false" "false" \
    "placement_required=$AFK_STAMP_PLACEMENT_REQUIRED"
  # A successful observation at T1 is never authorization at T2.
  afk_live_fact "route_authority" "OUT_OF_SCOPE" "LIVE_OBSERVATION_NOT_LAUNCH_AUTHORITY" "OWNERSHIP_RULE" "false" "false" \
    "$AFK_STAMP_IDENTITY"

  # --- deterministic, offline properties of the decision -------------------
  expiry="$(printf '%s' "$AFK_STAMP_JSON" | jq -r '.expires_at')"
  if epoch="$(afk_epoch_of_utc "$expiry")" && now="$(date -u +%s 2>/dev/null)"; then
    if (( epoch <= now )); then
      reason="STAMP_EXPIRED"
    fi
  else
    reason="STAMP_VALIDATION_UNPROVEN"
  fi

  if [[ -z "$reason" ]] && ! afk_list_contains "$AFK_STAMP_EFFORT" "$AFK_SUPPORTED_EFFORTS"; then
    reason="ROUTE_PROFILE_UNSUPPORTED"
  fi
  if [[ -z "$reason" ]]; then
    contract_reason="$(afk_launch_contract_reason "$AFK_STAMP_HARNESS" "$AFK_STAMP_PROFILE" \
      "$AFK_STAMP_PLACEMENT_REQUIRED")"
    if [[ -n "$contract_reason" ]]; then
      reason="ROUTE_PROFILE_UNSUPPORTED"
    fi
  fi

  # --- funding: only the affected route, and never a credential value ------
  if [[ -z "$reason" ]]; then
    conflicts="$(afk_route_funding_conflict "$AFK_STAMP_HARNESS" "$AFK_STAMP_COST_CLASS" "$AFK_STAMP_METERED")"
    if [[ -n "$conflicts" ]]; then
      reason="ROUTE_FUNDING_CONFLICT"
    fi
  fi

  # --- the target this route needs -----------------------------------------
  #
  # The target is an OPERAND of the intersection, so a binding that cannot be
  # determined fails the route CLOSED rather than dropping out of the
  # intersection silently. Two registered targets with no `--target` is
  # ownership ambiguity of exactly the kind this lifecycle refuses to guess at,
  # and a host with none registered has nowhere to dispatch this route into;
  # both are ROUTE_TARGET_UNRESOLVED, and naming the target resolves either.
  if [[ -z "$reason" ]]; then
    target_id="$AFK_ROUTE_TARGET"
    if [[ -z "$target_id" ]]; then
      target_id="$(printf '%s' "$AFK_RD_TARGET_ENTRIES" | jq -sr \
        'if length == 1 then .[0].id else "" end')"
    fi
    if [[ -z "$target_id" ]] \
       || ! afk_target_registered "$target_id" || ! afk_target_ready "$target_id"; then
      reason="ROUTE_TARGET_UNRESOLVED"
    else
      tpath="$(afk_target_path "$target_id")"
    fi
  fi

  # --- the selected harness, when live evaluation looked at it -------------
  if [[ -z "$reason" && "$AFK_LIVE_MODE" == "true" ]]; then
    case "$AFK_STAMP_HARNESS" in
      claude) harness_state="$AFK_RD_CLAUDE_PATH" ;;
      codex)  harness_state="$AFK_RD_CODEX_PATH" ;;
      *)      harness_state="FALSE" ;;
    esac
    if [[ "$harness_state" != "TRUE" ]]; then
      reason="ROUTE_HARNESS_UNAVAILABLE"
    fi
  fi
  # The workspace-trust decision is a property of the selected path, so it is
  # evaluated whenever a Claude route is judged — in live mode or not, because
  # reading the harness's own project state starts no process and opens no
  # socket. It is evaluated even for a route that is already blocked: "no
  # workspace was selected" and "the probe was not requested" are different
  # sentences, and a fact that quietly keeps its unprobed seed is how a
  # protected human decision disappears out of a route's readiness. Only an
  # otherwise launchable route can be blocked BY the trust prompt; a route that
  # already carries a reason keeps the reason it has.
  if [[ "$AFK_STAMP_HARNESS" == "claude" ]]; then
    if ! afk_evaluate_workspace_trust "$tpath" && [[ -z "$reason" ]]; then
      reason="WORKSPACE_TRUST_REQUIRED"
    fi
  fi

  if [[ -n "$reason" ]]; then
    AFK_RD_ROUTE_STATE="FALSE"
    AFK_RD_ROUTE_REASON="$reason"
    # The kit never substitutes another harness, model, profile, host or
    # funding path for a blocked route: a fresh central decision is the only
    # thing that changes this answer. WORKSPACE_TRUST_REQUIRED already carries
    # its own loud owner-action finding and is not reported twice.
    if [[ "$reason" != "WORKSPACE_TRUST_REQUIRED" ]]; then
      afk_add_finding "execution-stamp" "EXTERNAL_STATE" "INCOMPATIBLE" "$reason" \
        "blocking" "ROUTE_READY" "VALIDATOR_FIXTURE" \
        "$AFK_STAMP_HARNESS $AFK_STAMP_PROFILE $AFK_STAMP_EFFORT" \
        "${conflicts//$'\n'/ }" "true" "false" "$AFK_STAMP_IDENTITY"
    fi
    return 1
  fi

  # --- the validator verdict is a live fact, never an offline assumption ---
  if [[ "$AFK_LIVE_MODE" != "true" ]]; then
    AFK_RD_ROUTE_STATE="NOT_EVALUATED"
    AFK_RD_ROUTE_REASON="STAMP_VALIDATION_UNPROVEN"
    return 0
  fi
  if [[ "$AFK_RD_VALIDATOR" != "TRUE" ]]; then
    AFK_RD_ROUTE_STATE="FALSE"
    AFK_RD_ROUTE_REASON="STAMP_VALIDATION_UNPROVEN"
    afk_add_finding "execution-stamp" "EXTERNAL_STATE" "UNKNOWN" "STAMP_VALIDATION_UNPROVEN" \
      "blocking" "ROUTE_READY" "VALIDATOR_FIXTURE" "a usable validator" \
      "validator verdict $AFK_RD_VALIDATOR" "true" "false" ""
    return 1
  fi
  # An accepted, unexpired stamp that needs no rerouting may continue through a
  # router outage — and only because the compatible validator can prove
  # catalog, provenance, expiry, funding and policy locally (FR-50).
  afk_probe_run "$AFK_VALIDATOR_BIN" --stamp "$AFK_STAMP_FILE"
  case "$AFK_PROBE_STATUS" in
    OK)      rc=0 ;;
    NONZERO) if (( AFK_PROBE_RC == 1 )); then rc=1; else rc=2; fi ;;
    *)       rc=2 ;;
  esac
  if (( rc == 1 )); then
    AFK_RD_ROUTE_STATE="FALSE"; AFK_RD_ROUTE_REASON="STAMP_VALIDATION_FAILED"
    afk_add_finding "execution-stamp" "EXTERNAL_STATE" "INCOMPATIBLE" "STAMP_VALIDATION_FAILED" \
      "blocking" "ROUTE_READY" "VALIDATOR_FIXTURE" "a valid stamp" "rejected" "true" "false" "$AFK_STAMP_IDENTITY"
    return 1
  fi
  if (( rc == 2 )); then
    AFK_RD_ROUTE_STATE="FALSE"; AFK_RD_ROUTE_REASON="STAMP_VALIDATION_UNPROVEN"
    AFK_RD_LIVE_UNAVAILABLE="true"
    afk_add_finding "execution-stamp" "EXTERNAL_STATE" "UNKNOWN" "STAMP_VALIDATION_UNPROVEN" \
      "blocking" "ROUTE_READY" "VALIDATOR_FIXTURE" "a validator verdict" "uncheckable" "true" "true" ""
    return 1
  fi

  if [[ "$AFK_RD_HOST_STATE" != "TRUE" ]]; then
    AFK_RD_ROUTE_STATE="FALSE"; AFK_RD_ROUTE_REASON="NO_APPROVED_HARNESS_PATH"
    return 1
  fi

  AFK_RD_ROUTE_STATE="TRUE"
  AFK_RD_ROUTE_REASON="ROUTE_READY_PROVEN"
  return 0
}

# --- aggregation ------------------------------------------------------------

afk_aggregate_host_readiness() {
  local integrity reason
  integrity="$(afk_installed_integrity_state)"

  if [[ "$AFK_LIVE_MODE" != "true" ]]; then
    # Offline evaluation NEVER asserts live host readiness, however healthy the
    # installation looks: the three dependencies it rests on were not looked
    # at, and "probably" is not a readiness state.
    AFK_RD_HOST_STATE="NOT_EVALUATED"
    AFK_RD_HOST_REASON="LIVE_PROBE_NOT_REQUESTED"
    AFK_RD_NEWWORK_STATE="NOT_EVALUATED"
    AFK_RD_NEWWORK_REASON="LIVE_PROBE_NOT_REQUESTED"
    return 0
  fi

  if [[ "$integrity" == "NOT_READY" || "$integrity" == "NEEDS_OWNER" ]]; then
    AFK_RD_HOST_STATE="FALSE"
    AFK_RD_HOST_REASON="INSTALLED_INTEGRITY_NOT_PROVEN"
  elif [[ "$AFK_RD_ORCA" != "TRUE" ]]; then
    AFK_RD_HOST_STATE="FALSE"
    reason="$(afk_live_fact_reason orca_capability)"
    [[ -n "$reason" ]] || reason="$(afk_live_fact_reason orca_runtime)"
    AFK_RD_HOST_REASON="${reason:-ORCA_NOT_RESOLVED}"
  elif [[ "$AFK_RD_VALIDATOR" != "TRUE" ]]; then
    AFK_RD_HOST_STATE="FALSE"
    reason="$(afk_live_fact_reason validator_fixtures)"
    [[ -n "$reason" ]] || reason="$(afk_live_fact_reason validator_contract)"
    AFK_RD_HOST_REASON="${reason:-VALIDATOR_NOT_RESOLVED}"
  elif [[ "$AFK_RD_CLAUDE_PATH" == "TRUE" || "$AFK_RD_CODEX_PATH" == "TRUE" ]]; then
    # One complete centrally approved path is the bar. The other harness is
    # reported independently and is never globally mandatory (FR-52).
    AFK_RD_HOST_STATE="TRUE"
    AFK_RD_HOST_REASON="HOST_EXECUTION_READY_PROVEN"
  else
    AFK_RD_HOST_STATE="FALSE"
    AFK_RD_HOST_REASON="NO_APPROVED_HARNESS_PATH"
    afk_add_finding "host" "EXTERNAL_STATE" "UNAVAILABLE" "NO_APPROVED_HARNESS_PATH" \
      "blocking" "HOST_EXECUTION_READY" "CAPABILITY_PROBE" \
      "at least one complete approved harness path" "none usable" "true" "false" ""
  fi

  # Router availability is a NEW_WORK prerequisite and never an implicit host
  # one. A host with a healthy Orca, validator and harness stays execution
  # ready through a router outage; only fresh routing stops.
  if [[ "$AFK_RD_ROUTER" == "TRUE" ]]; then
    if [[ "$AFK_RD_HOST_STATE" == "TRUE" ]]; then
      AFK_RD_NEWWORK_STATE="TRUE"; AFK_RD_NEWWORK_REASON="ROUTER_AVAILABLE"
    else
      AFK_RD_NEWWORK_STATE="FALSE"; AFK_RD_NEWWORK_REASON="$AFK_RD_HOST_REASON"
    fi
  else
    reason="$(afk_live_fact_reason router_status)"
    AFK_RD_NEWWORK_STATE="FALSE"
    AFK_RD_NEWWORK_REASON="${reason:-ROUTER_ENDPOINT_NOT_DECLARED}"
  fi
  return 0
}

# --- the readiness document -------------------------------------------------

afk_readiness_json() {
  local integrity targets
  integrity="$(afk_installed_integrity_state)"
  targets="$(printf '%s' "$AFK_RD_TARGET_ENTRIES" | jq -sc '.')"
  jq -nc \
    --arg integrity "$integrity" \
    --argjson source_ok "$AFK_SRC_MUTATION_ALLOWED" \
    --arg host_state "$AFK_RD_HOST_STATE" --arg host_reason "$AFK_RD_HOST_REASON" \
    --arg new_state "$AFK_RD_NEWWORK_STATE" --arg new_reason "$AFK_RD_NEWWORK_REASON" \
    --arg tgt_state "$AFK_RD_TARGET_STATE" --arg tgt_reason "$AFK_RD_TARGET_REASON" \
    --arg route_state "$AFK_RD_ROUTE_STATE" --arg route_reason "$AFK_RD_ROUTE_REASON" \
    --arg route_id "$AFK_STAMP_IDENTITY" \
    --argjson targets "$targets" \
    --arg live "$AFK_LIVE_MODE" \
    '{INSTALLED_INTEGRITY: {state: $integrity, evaluated: true, reason: null,
                            evidence_provenance: "HASH_COMPARISON"},
      MUTATION_SOURCE_ELIGIBLE: {state: (if $source_ok then "TRUE" else "FALSE" end),
                                 evaluated: true,
                                 reason: (if $source_ok then null else "SOURCE_INELIGIBLE" end),
                                 evidence_provenance: "GIT_STATE"},
      HOST_EXECUTION_READY: {state: $host_state,
                             evaluated: ($live == "true"),
                             reason: $host_reason,
                             evidence_provenance: (if $live == "true" then "CAPABILITY_PROBE" else null end),
                             launch_authoritative: false},
      NEW_WORK_READY: {state: $new_state,
                       evaluated: ($live == "true"),
                       reason: $new_reason,
                       evidence_provenance: (if $live == "true" then "ROUTER_STATUS" else null end),
                       launch_authoritative: false},
      TARGET_READY: {state: $tgt_state,
                     evaluated: (($targets | length) > 0),
                     reason: $tgt_reason,
                     evidence_provenance: (if ($targets | length) > 0 then "BMAD_RESOLUTION" else null end),
                     targets: $targets},
      ROUTE_READY: {state: $route_state,
                    evaluated: ($route_state != "OUT_OF_SCOPE"),
                    reason: $route_reason,
                    evidence_provenance: (if $route_state == "OUT_OF_SCOPE" then null else "VALIDATOR_FIXTURE" end),
                    execution_stamp: (if $route_id == "" then null else $route_id end),
                    launch_authoritative: false,
                    placement_selected: false}}'
}

# --- the one entry point ----------------------------------------------------
#
# Ordering matters and is not incidental: dependencies first, then aggregation,
# then the route — because a route is an intersection of everything above it
# (FR-64) and can only be answered once each input has answered for itself.

afk_readiness_evaluate() {
  local key
  afk_readiness_reset

  # Seed every declared external fact as unprobed BEFORE anything runs, so a
  # key never disappears because a probe took an early return.
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    afk_live_fact "$key" "NOT_EVALUATED" "LIVE_PROBE_NOT_REQUESTED" "" "false" "false" ""
  done < <(afk_live_facts_declared)

  afk_evaluate_executables
  afk_evaluate_target_readiness
  afk_evaluate_orchestration

  if [[ "$AFK_LIVE_MODE" == "true" ]]; then
    afk_probe_orca
    afk_probe_validator
    if afk_probe_harness claude; then AFK_RD_CLAUDE_PATH="TRUE"; else AFK_RD_CLAUDE_PATH="FALSE"; fi
    if afk_probe_harness codex;  then AFK_RD_CODEX_PATH="TRUE";  else AFK_RD_CODEX_PATH="FALSE"; fi
    afk_probe_router
  fi

  afk_aggregate_host_readiness
  afk_evaluate_route_readiness
  return 0
}

# The exit code for a readiness-scoped run. Deterministic not-ready and
# temporarily-unavailable are different answers and get different codes: an
# operator can retry one and must fix the other (FR-77, FR-86). An empty answer
# means this run has nothing to add to the installed-state verdict.
afk_readiness_exit_code() {
  local integrity
  integrity="$(afk_installed_integrity_state)"
  case "$integrity" in
    NEEDS_OWNER) printf '%s' "$AFK_EXIT_OWNER_ACTION"; return 0 ;;
    NOT_READY)   printf '%s' "$AFK_EXIT_NOT_READY"; return 0 ;;
  esac
  if [[ "$AFK_RD_LIVE_UNAVAILABLE" == "true" ]]; then
    printf '%s' "$AFK_EXIT_LIVE_UNAVAILABLE"; return 0
  fi
  if [[ "$AFK_RD_ROUTE_REASON" == "WORKSPACE_TRUST_REQUIRED" ]]; then
    printf '%s' "$AFK_EXIT_OWNER_ACTION"; return 0
  fi
  if [[ "$AFK_RD_ROUTE_STATE" == "FALSE" || "$AFK_RD_HOST_STATE" == "FALSE" \
        || "$AFK_RD_NEWWORK_STATE" == "FALSE" || "$AFK_RD_TARGET_STATE" == "FALSE" ]]; then
    printf '%s' "$AFK_EXIT_NOT_READY"; return 0
  fi
  printf ''
  return 0
}
