#!/usr/bin/env bash
# afk-commands.sh — the command surface: read-only status, inspect-only
# adoption analysis, the adoption and update transactions, offline
# verification, and the published schema.
#
# `status`, `adopt --inspect`, `verify` and every `--plan` invocation write
# nothing at all: not a manifest, not a journal, not a lock, not a cache, not a
# temporary file. Only afk_run_mutation can reach afk-mutate.sh, and only after
# a complete plan has been computed, approved where required, and revalidated.
#
# shellcheck disable=SC2034
# The AFK_R_* result-model inputs are declared in afk-common.sh, assigned here
# and read by afk_build_result there; the lifecycle files are always sourced
# together and `set -u` is the real guard against an unset read.

if [[ -n "${AFK_COMMANDS_SOURCED:-}" ]]; then
  return 0
fi
AFK_COMMANDS_SOURCED=1

# Environment names whose PRESENCE is diagnostically useful. Values never leave
# afk_env_record; only the name, the presence flag and the redacted placeholder
# are reported (FR-81, FR-82).
AFK_ENV_NAMES=(
  ANTHROPIC_API_KEY
  CLAUDE_CONFIG_DIR
  AGENT_ROUTER_URL
  AGENT_ROUTER_TOKEN
  OP_SERVICE_ACCOUNT_TOKEN
  AGENT_STAMP_VALIDATE_CATALOG_PATH
)

afk_environment_json() {
  local name out=""
  for name in "${AFK_ENV_NAMES[@]}"; do
    out="${out}$(afk_env_record "$name")"$'\n'
  done
  printf '%s' "$out" | jq -sc '.'
}

# Nothing here is probed by default. Each fact carries the four-way distinction
# the machine contract promises: evaluated-false, out of scope, unavailable,
# and not performed (FR-73, FR-84).
afk_live_facts_json() {
  jq -nc '
    {state: "NOT_EVALUATED", evaluated: false, reason: "LIVE_PROBE_NOT_REQUESTED",
     observed_at: null, timeout_ms: null, evidence_provenance: null} as $np
    | {router_status: $np,
       router_catalog_provenance: $np,
       claude_native_session: $np,
       codex_native_session: $np,
       orca_runtime: $np,
       validator_contract: $np}'
}

afk_installed_integrity_state() {
  printf '%s' "$AFK_FINDINGS" | jq -sr '
    map(select(.blocked_scopes | index("INSTALLED_INTEGRITY"))) as $b
    | if   ($b | map(select(.severity == "owner_action")) | length) > 0 then "NEEDS_OWNER"
      elif ($b | map(select(.severity == "blocking"))     | length) > 0 then "NOT_READY"
      elif ($b | length) > 0 then "READY_WITH_WARNINGS"
      else "READY" end'
}

afk_readiness_json() {
  local integrity
  integrity="$(afk_installed_integrity_state)"
  jq -nc \
    --arg integrity "$integrity" \
    --argjson source_ok "$AFK_SRC_MUTATION_ALLOWED" \
    '{state: "NOT_EVALUATED", evaluated: false, reason: "LIVE_PROBE_NOT_REQUESTED",
      evidence_provenance: null} as $np
     | {INSTALLED_INTEGRITY: {state: $integrity, evaluated: true, reason: null,
                              evidence_provenance: "HASH_COMPARISON"},
        MUTATION_SOURCE_ELIGIBLE: {state: (if $source_ok then "TRUE" else "FALSE" end),
                                   evaluated: true,
                                   reason: (if $source_ok then null else "SOURCE_INELIGIBLE" end),
                                   evidence_provenance: "GIT_STATE"},
        HOST_EXECUTION_READY: $np,
        NEW_WORK_READY: $np,
        TARGET_READY: $np,
        ROUTE_READY: {state: "OUT_OF_SCOPE", evaluated: false,
                      reason: "NO_EXECUTION_STAMP_SUPPLIED", evidence_provenance: null}}'
}

# afk_evaluate_installation <allow-noncanonical> <allow-rollback>
# Shared read-only evaluation for every command.
afk_evaluate_installation() {
  local allow_noncanonical="$1" allow_rollback="$2" installed_state lock_state

  afk_result_reset
  afk_load_manifest
  afk_evaluate_journal
  afk_emit_manifest_findings
  afk_validate_adaptations
  afk_source_evaluate "$AFK_APPLIED_REVISION" "$AFK_MANIFEST_REPO_IDENTITY" \
    "$allow_noncanonical" "$allow_rollback"

  # An installation that another operation is actively mutating is not stably
  # healthy, and read-only status must not report it as such (FR-92). The lock
  # is only OBSERVED here: status acquires nothing. The finding is transient,
  # so automation can tell "wait and retry" from "an owner must decide".
  lock_state="$(afk_lock_state)"
  if [[ "$lock_state" == "HELD" && "$AFK_LOCK_HELD" != "true" ]]; then
    afk_add_finding "operation-lock" "KIT_STATE" "INTERRUPTED" "CONCURRENT_OPERATION_IN_PROGRESS" \
      "blocking" "INSTALLED_INTEGRITY,MUTATION_SOURCE" "OPERATION_JOURNAL" \
      "no operation in progress" "another operation holds the installation lock" "false" "true" ""
  fi

  afk_evaluate_components
  afk_evaluate_targets

  installed_state="$(afk_installed_state)"
  if [[ "$lock_state" == "HELD" && "$AFK_LOCK_HELD" != "true" ]]; then
    installed_state="INTERRUPTED"
  fi
  AFK_R_CHECKOUT="$(afk_checkout_json)"
  AFK_R_INSTALLED="$(afk_installed_json "$installed_state" \
    | jq -c --arg lock "$lock_state" '. + {lock_state: $lock}')"
  AFK_R_SOURCE="$(afk_source_json "$allow_noncanonical" "$allow_rollback")"
  AFK_R_READINESS="$(afk_readiness_json)"
  AFK_R_LIVE="$(afk_live_facts_json)"
  AFK_R_ENV="$(afk_environment_json)"
}

# --- inspect-only adoption analysis (FR-10 through FR-14, FR-25) ------------

# afk_git_blob_identity <blob-object> <file|section>
# The same identity function the installed side uses, computed over history
# without materializing a working tree.
afk_git_blob_identity() {
  local obj="$1" kind="$2" content digest
  afk_git cat-file -e "$obj" 2>/dev/null || return 1
  if [[ "$kind" == "section" ]]; then
    content="$(afk_git cat-file blob "$obj" 2>/dev/null)" || return 1
    afk_normalized_identity_of_text "$content"
    return 0
  fi
  digest="$(afk_git cat-file blob "$obj" 2>/dev/null | afk_sha256_stdin)" || return 1
  [[ -n "$digest" ]] || return 1
  printf '%s\n' "$digest"
}

# afk_git_tree_identity_at <tree-object> [comma-separated relative exclusions]
# The managed-copy-tree identity of a historical revision, computed from Git
# objects. Paths inside a tree object are already relative to that tree, and
# the record format is byte-identical to the installed-side listing, so the two
# identities are comparable by construction.
afk_git_tree_identity_at() {
  local tree="$1" excl="${2:-}" out=""
  [[ -n "$tree" ]] || return 1
  out="$(
    listing=""
    while IFS= read -r -d '' record; do
      case "$record" in
        LSTREERC=0) break ;;
        LSTREERC=*) exit 1 ;;
      esac
      meta="${record%%$'\t'*}"
      rel="${record#*$'\t'}"
      mode="${meta%% *}"
      rest="${meta#* }"
      objtype="${rest%% *}"
      obj="${rest##* }"
      [[ "$objtype" == "blob" ]] || exit 1
      if afk_excluded "$rel" "$excl"; then continue; fi
      case "$mode" in
        120000)
          target="$(afk_git cat-file blob "$obj" 2>/dev/null)" || exit 1
          listing="${listing}L $(afk_encode_path "$target") $(afk_encode_path "$rel")"$'\n' ;;
        100644|100755)
          digest="$(afk_git cat-file blob "$obj" 2>/dev/null | afk_sha256_stdin)" || exit 1
          [[ -n "$digest" ]] || exit 1
          listing="${listing}F ${digest} $(afk_encode_path "$rel")"$'\n' ;;
        *) exit 1 ;;
      esac
    done < <(afk_git ls-tree -r -z "$tree" 2>/dev/null
             printf 'LSTREERC=%s\0' "$?")
    # An empty listing means the path carried no content at that revision. That
    # is not "an empty tree that happens to match"; it is nothing to compare.
    [[ -n "$listing" ]] || exit 1
    printf '%s' "$listing" | LC_ALL=C sort | afk_sha256_stdin
  )" || return 1
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# afk_recognized_prior_identity <source-rel> <observed> <file|section|tree> [exclusions]
#
# Walks the reachable history of that path and answers with the first revision
# whose canonical content has exactly the observed identity. There is no
# revision cutoff: a bound on how far back recognition looks is a bound on
# correctness, and a legacy host is precisely the case where the installed
# content is old. The walk is made finite by identity, not by count — each
# DISTINCT Git object is hashed once, so a long history of unrelated commits
# costs one rev-list, not one hash per commit.
afk_recognized_prior_identity() {
  local srel="$1" obs="$2" kind="$3" excl="${4:-}"
  local rev objsha id seen=""
  [[ -n "$srel" && -n "$obs" ]] || return 1
  while IFS= read -r rev; do
    [[ -n "$rev" ]] || continue
    objsha="$(afk_git rev-parse --verify --quiet "$rev:$srel" 2>/dev/null)" || continue
    [[ -n "$objsha" ]] || continue
    case "$seen" in
      *"$objsha"$'\n'*) continue ;;
    esac
    seen="${seen}${objsha}"$'\n'
    case "$kind" in
      tree)    id="$(afk_git_tree_identity_at "$objsha" "$excl")" || continue ;;
      section) id="$(afk_git_blob_identity "$objsha" section)" || continue ;;
      *)       id="$(afk_git_blob_identity "$objsha" file)" || continue ;;
    esac
    if [[ -n "$id" && "$id" == "$obs" ]]; then
      printf '%s\n' "$rev"
      return 0
    fi
  done < <(afk_git rev-list HEAD -- "$srel" 2>/dev/null)
  return 1
}

AFK_ADOPTION_ENTRIES=""
AFK_ADOPTION_DISPOSITION="AUTO_ADOPTABLE"

afk_adoption_note() { # <id> <classification> <reason> [evidence-detail]
  case "$2" in
    REFUSED)
      AFK_ADOPTION_DISPOSITION="REFUSED" ;;
    APPROVAL_REQUIRED)
      if [[ "$AFK_ADOPTION_DISPOSITION" != "REFUSED" ]]; then
        AFK_ADOPTION_DISPOSITION="APPROVAL_REQUIRED"
      fi ;;
    *) : ;;
  esac
  AFK_ADOPTION_ENTRIES="${AFK_ADOPTION_ENTRIES}$(jq -nc \
    --arg id "$1" --arg classification "$2" --arg reason "$3" --arg detail "${4:-}" \
    '{id: $id, classification: $classification,
      reason: (if $reason == "" then null else $reason end),
      evidence: (if $detail == "" then null else $detail end)}')"$'\n'
}

afk_adopt_analyze() {
  local id ownership skind srel dkind dpath extra critical container target_root
  local guard rc want boundary observed canonical escape prior resolved

  AFK_ADOPTION_ENTRIES=""
  AFK_ADOPTION_DISPOSITION="AUTO_ADOPTABLE"

  # Global refusals: an analysis that cannot see canonical content, an
  # installation whose ownership is already established, or a checkout that is
  # not an eligible source has nothing safe to propose. Adoption records a
  # canonical revision, so it inherits source eligibility (FR-35 keeps the two
  # dimensions separate in REPORTING; it does not make an ineligible source
  # adoptable).
  if [[ "$AFK_MANIFEST_PRESENT" == "true" ]]; then
    if [[ "$AFK_ADOPTED" == "true" ]]; then
      afk_adoption_note "installation" "REFUSED" "ADOPTION_NOT_APPLICABLE_ALREADY_ADOPTED" "$AFK_MANIFEST"
    else
      afk_adoption_note "installation" "REFUSED" "$AFK_MANIFEST_REASON" "$AFK_MANIFEST"
    fi
    return 0
  fi
  if [[ -z "$AFK_CO_REPO_IDENTITY" || "$AFK_CO_KIT_ID" != "agent-flow-kit" ]]; then
    afk_adoption_note "installation" "REFUSED" "SOURCE_REPOSITORY_UNIDENTIFIED" "$AFK_KIT_ROOT"
    return 0
  fi
  if [[ "$AFK_SRC_MUTATION_ALLOWED" != "true" ]]; then
    afk_adoption_note "installation" "REFUSED" "ADOPTION_SOURCE_INELIGIBLE" "$AFK_SRC_REASONS"
    return 0
  fi

  while IFS='|' read -r id ownership skind srel dkind dpath extra critical container target_root; do
    [[ -n "$id" ]] || continue
    observed=""; canonical=""; prior=""

    case "$dkind" in
      dir)     want="dir";  boundary="$target_root" ;;
      file)    want="file"; boundary="$target_root" ;;
      section) want="file"; boundary="$target_root" ;;
      link)    want="link"; boundary="$target_root" ;;
      *)       want="file"; boundary="$target_root" ;;
    esac

    guard="$(afk_path_guard "$dpath" "$want" "$boundary" "$container")"
    rc=$?
    if (( rc != 0 )); then
      if [[ "$guard" == "PATH_ABSENT" ]]; then
        afk_adoption_note "$id" "NOT_INSTALLED" "PATH_ABSENT" "$dpath"
      else
        afk_adoption_note "$id" "REFUSED" "$guard" "$dpath"
      fi
      continue
    fi

    case "$ownership" in
      MACHINE_LOCAL)
        # A schema-declared machine-local field: adoption only records that it
        # is machine-owned and changes nothing about its content (FR-11).
        afk_adoption_note "$id" "AUTO_ADOPTABLE" "MACHINE_OWNED_REGION" "$dpath"
        continue ;;
      MANAGED_LINK)
        if [[ ! -e "$dpath" ]]; then
          afk_adoption_note "$id" "APPROVAL_REQUIRED" "LINK_TARGET_MISSING" "$dpath"
          continue
        fi
        if resolved="$(afk_realpath "$dpath")"; then observed="link:$resolved"; else observed=""; fi
        if resolved="$(afk_realpath "$extra")"; then canonical="link:$resolved"; else canonical=""; fi
        if [[ -z "$observed" ]]; then
          afk_adoption_note "$id" "REFUSED" "IDENTITY_UNREADABLE" "$dpath"
          continue
        fi
        if [[ -z "$canonical" ]]; then
          afk_adoption_note "$id" "REFUSED" "CANONICAL_IDENTITY_UNREADABLE" "$extra"
          continue
        fi
        if [[ "$observed" == "$canonical" ]]; then
          afk_adoption_note "$id" "AUTO_ADOPTABLE" "EXACT_RECOGNIZED_WIRING" "$observed"
        else
          afk_adoption_note "$id" "APPROVAL_REQUIRED" "LINK_TARGET_UNEXPECTED" "$observed"
        fi
        continue ;;
      MANAGED_COPY_TREE)
        escape="$(afk_tree_find_escaping_symlink "$dpath")"
        if [[ -n "$escape" ]]; then
          afk_adoption_note "$id" "REFUSED" "PATH_ESCAPES_OWNERSHIP_BOUNDARY" "$escape"
          continue
        fi
        observed="$(afk_tree_identity "$dpath" "$extra")"
        canonical="$(afk_tree_identity "$AFK_KIT_ROOT/$srel" "$extra")"
        ;;
      MANAGED_COPY_FILE)
        observed="$(afk_sha256_file "$dpath")"
        canonical="$(afk_sha256_file "$AFK_KIT_ROOT/$srel")"
        ;;
      MANAGED_SECTION)
        observed="$(afk_section_identity "$dpath" "$extra")"
        rc=$?
        canonical="$(afk_file_payload_identity "$AFK_KIT_ROOT/$srel")"
        if (( rc == 3 )); then
          afk_adoption_note "$id" "REFUSED" "MANAGED_SECTION_MARKERS_MALFORMED" "$dpath"
          continue
        fi
        if (( rc == 2 )); then
          afk_adoption_note "$id" "NOT_INSTALLED" "MANAGED_SECTION_ABSENT" "$dpath"
          continue
        fi
        ;;
    esac

    if [[ -z "$observed" ]]; then
      afk_adoption_note "$id" "REFUSED" "IDENTITY_UNREADABLE" "$dpath"
      continue
    fi
    # Without a readable canonical side there is no proof of anything: such a
    # component is refused, never quietly promoted to "needs approval".
    if [[ -z "$canonical" ]]; then
      afk_adoption_note "$id" "REFUSED" "CANONICAL_IDENTITY_UNREADABLE" "$AFK_KIT_ROOT/$srel"
      continue
    fi
    if [[ "$observed" == "$canonical" ]]; then
      afk_adoption_note "$id" "AUTO_ADOPTABLE" "EXACT_CANONICAL" "$observed"
      continue
    fi
    case "$ownership" in
      MANAGED_SECTION)   prior="$(afk_recognized_prior_identity "$srel" "$observed" section)" ;;
      MANAGED_COPY_FILE) prior="$(afk_recognized_prior_identity "$srel" "$observed" file)" ;;
      MANAGED_COPY_TREE) prior="$(afk_recognized_prior_identity "$srel" "$observed" tree "$extra")" ;;
      *)                 prior="" ;;
    esac
    if [[ -n "$prior" ]]; then
      afk_adoption_note "$id" "AUTO_ADOPTABLE" "RECOGNIZED_PRIOR_CANONICAL" "$prior"
    else
      afk_adoption_note "$id" "APPROVAL_REQUIRED" "UNRECOGNIZED_CONTENT" "$observed"
    fi
  done < <(afk_component_table)
}

afk_adoption_json() {
  local entries
  entries="$(afk_ndjson_to_array "$AFK_ADOPTION_ENTRIES")"
  jq -nc --arg disposition "$AFK_ADOPTION_DISPOSITION" --argjson components "$entries" \
    '{disposition: $disposition,
      inspect_only: true,
      mutation_performed: false,
      manifest_created: false,
      applied_revision_advanced: false,
      ownership_claimed: false,
      components: $components,
      note: "Ownership becomes durable only through the adoption transaction: agent-flow-kit adopt."}'
}

# --- command entry points ---------------------------------------------------

afk_emit_result() { # <json-mode: true|false>  -> returns the contract exit code
  local doc code
  if ! doc="$(afk_build_result)"; then
    afk_warn "internal error: the normalized result could not be assembled; nothing is reported rather than reporting a partial state"
    return "$AFK_EXIT_USAGE"
  fi
  if ! afk_result_is_well_formed "$doc"; then
    afk_warn "internal error: the assembled result does not present the published schema shape"
    return "$AFK_EXIT_USAGE"
  fi
  code="$(printf '%s' "$doc" | jq -r '.overall.exit_code')"
  case "$code" in
    0|1|2|3|4|5) : ;;
    *)
      afk_warn "internal error: the assembled result carries an exit code outside the frozen contract"
      return "$AFK_EXIT_USAGE" ;;
  esac
  if [[ "$1" == "true" ]]; then
    printf '%s' "$doc" | jq -S '.' || return "$AFK_EXIT_USAGE"
  else
    afk_render_human "$doc"
  fi
  return "$code"
}

afk_cmd_status() { # <json-mode> <require-source> <allow-noncanonical> <allow-rollback>
  AFK_R_COMMAND="status"
  AFK_R_REQUIRE_SOURCE="$2"
  AFK_R_FORCED_EXIT=""
  AFK_R_NEXT_ACTION=""
  AFK_R_EXTRA="{}"
  AFK_R_OPERATION='{"id": null, "mutating": false}'
  afk_evaluate_installation "$3" "$4"
  afk_emit_result "$1"
}

afk_cmd_adopt_inspect() { # <json-mode> <allow-noncanonical> <allow-rollback>
  AFK_R_COMMAND="adopt --inspect"
  AFK_R_REQUIRE_SOURCE="false"
  AFK_R_NEXT_ACTION=""
  AFK_R_OPERATION='{"id": null, "mutating": false}'
  afk_evaluate_installation "$2" "$3"
  afk_adopt_analyze
  AFK_R_EXTRA="$(jq -nc --argjson adoption "$(afk_adoption_json)" '{adoption: $adoption}')"
  # The requested scope is the adoption analysis, so the exit code answers that
  # question rather than the installation's overall readiness (FR-77).
  if [[ "$AFK_ADOPTION_DISPOSITION" == "AUTO_ADOPTABLE" ]]; then
    AFK_R_FORCED_EXIT="$AFK_EXIT_OK"
  else
    AFK_R_FORCED_EXIT="$AFK_EXIT_OWNER_ACTION"
  fi
  afk_emit_result "$1"
}

# --- offline verification ---------------------------------------------------

afk_cmd_verify() { # <json-mode>
  local verified="false"
  AFK_R_COMMAND="verify"
  AFK_R_REQUIRE_SOURCE="false"
  AFK_R_FORCED_EXIT=""
  AFK_R_NEXT_ACTION=""
  AFK_R_OPERATION='{"id": null, "mutating": false}'
  AFK_VERIFY_OWN_OPERATION=""
  afk_evaluate_installation "false" "false"

  if [[ "$AFK_ADOPTED" != "true" ]]; then
    # There is no declared installed state to prove. `status` already carries
    # the finding that says so; verification reports it as unverified rather
    # than inventing a baseline to measure against.
    AFK_VERIFY_ENTRIES=""; AFK_VERIFY_CHECKS=0; AFK_VERIFY_FAILURES=0; AFK_VERIFY_WARNINGS=0
    afk_verify_note "state-manifest" "manifest_present" "FAIL" \
      "${AFK_MANIFEST_REASON:-INSTALLATION_NOT_ADOPTED}" "an established manifest" "none"
  elif afk_verify_against_manifest "$AFK_MANIFEST_JSON" "$AFK_APPLIED_REVISION"; then
    verified="true"
  fi

  AFK_R_EXTRA="$(jq -nc --argjson verification "$(afk_verification_json "$verified")" \
    '{verification: $verification}')"

  if [[ "$verified" == "true" ]]; then
    AFK_R_NEXT_ACTION="No action required: the installed state was proven against the applied revision, offline."
  else
    # Verification failure is a deterministic not-ready fact, and it is
    # reported as a finding so it drives the same overall state machine every
    # other blocking fact does. Nothing was repaired on the way.
    afk_add_finding "installation" "KIT_STATE" "BROKEN" "VERIFICATION_FAILED" \
      "blocking" "INSTALLED_INTEGRITY,HOST_EXECUTION_READY" "HASH_COMPARISON" \
      "0 failing checks" "$AFK_VERIFY_FAILURES failing checks" "false" "false" ""
    AFK_R_READINESS="$(afk_readiness_json)"
  fi
  afk_emit_result "$1"
}

# --- the mutating commands --------------------------------------------------
#
# One function drives both transactions, because the ordering constraints are
# identical and duplicating them is how two code paths end up with two
# different safety stories.

afk_mutation_finding() { # <reason> <severity> [detail]
  local state
  case "$1" in
    CONCURRENT_OPERATION_IN_PROGRESS|OPERATION_LOCK_UNAVAILABLE|OPERATION_RECOVERED|OPERATION_ROLLED_BACK|OPERATION_LOCK_RECLAIMED)
      state="INTERRUPTED" ;;
    OPERATION_ROLLBACK_INCOMPLETE|OPERATION_RECOVERY_AUTHORITY_INSUFFICIENT|OPERATION_RECOVERY_VERIFICATION_FAILED|OPERATION_JOURNAL_SCHEMA_UNSUPPORTED|OPERATION_LOCK_OWNER_UNVERIFIABLE)
      state="BROKEN" ;;
    *)
      state="INCOMPATIBLE" ;;
  esac
  afk_add_finding "operation" "KIT_STATE" "$state" "$1" "$2" \
    "MUTATION_SOURCE" "OPERATION_JOURNAL" "" "${3:-}" "false" "false" ""
}

# Reclaiming a lock is never silent: it is the one place the lifecycle removes
# something another process created. The reclaimer reports it whatever happens
# to the acquisition afterwards — the take it earned can still be lost to a
# contender, and that contender reclaimed nothing and has nothing to report.
# One finding per abandoned lock this process actually destroyed.
afk_lock_reclamation_findings() {
  local d
  [[ "$AFK_LOCK_RECLAIMED" == "true" ]] || return 0
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    afk_mutation_finding "OPERATION_LOCK_RECLAIMED" "warning" "$d"
  done <<<"$AFK_LOCK_RECLAIMED_DETAILS"
  return 0
}

# One refusal for every way the lock can be unavailable, so the reason and the
# guidance an operator reads are decided in exactly one place. Truthfulness is
# the point: "wait for the operation to finish" is only ever printed when there
# IS an operation that can finish.
afk_lock_refusal() { # <afk_lock_acquire rc> <json-mode>
  AFK_OP_RESULT="REFUSED"
  # Reported before the refusal itself: an acquisition that destroyed an
  # abandoned lock on its way to being refused still destroyed it.
  afk_lock_reclamation_findings
  case "$1" in
    1)
      AFK_OP_REASON="CONCURRENT_OPERATION_IN_PROGRESS"
      AFK_OP_DETAIL="$AFK_LOCK_OWNER_DETAIL"
      afk_mutation_finding "CONCURRENT_OPERATION_IN_PROGRESS" "owner_action" "$AFK_LOCK_OWNER_DETAIL"
      afk_mutation_emit "$2" "$AFK_EXIT_OWNER_ACTION" \
        "Wait for the operation in progress to finish, then re-run. No mutation was attempted." ;;
    3)
      AFK_OP_REASON="OPERATION_LOCK_OWNER_UNVERIFIABLE"
      AFK_OP_DETAIL="${AFK_LOCK_OWNER_DETAIL:-the lock owner could not be judged}"
      afk_mutation_finding "OPERATION_LOCK_OWNER_UNVERIFIABLE" "owner_action" \
        "$AFK_LOCK_DIR: ${AFK_LOCK_OWNER_DETAIL:-the lock owner could not be judged}"
      afk_mutation_emit "$2" "$AFK_EXIT_OWNER_ACTION" \
        "Confirm no lifecycle operation is running on this installation, then remove $AFK_LOCK_DIR by hand. No mutation was attempted." ;;
    *)
      AFK_OP_REASON="OPERATION_LOCK_UNAVAILABLE"
      afk_mutation_finding "OPERATION_LOCK_UNAVAILABLE" "owner_action" "$AFK_LOCK_DIR"
      afk_mutation_emit "$2" "$AFK_EXIT_OWNER_ACTION" "No mutation was attempted." ;;
  esac
  return $?
}

afk_mutation_emit() { # <json-mode> <exit-code> <next-action>
  local verified="false"
  case "$AFK_OP_RESULT" in
    CONVERGED|ADOPTED) verified="true" ;;
    *) : ;;
  esac
  AFK_R_FORCED_EXIT="$2"
  AFK_R_NEXT_ACTION="$3"
  AFK_R_OPERATION="$(afk_operation_json)"
  AFK_R_EXTRA="$(jq -nc --argjson plan "$AFK_PLAN_JSON" \
    --argjson verification "$(afk_verification_json "$verified")" \
    '{plan: $plan, verification: $verification}')"
  afk_emit_result "$1"
}

# afk_run_mutation <adopt|update> <json-mode> <plan-only> <approval>
#                  <allow-noncanonical> <allow-rollback>
afk_run_mutation() {
  local command="$1" json_mode="$2" plan_only="$3" approval="$4"
  local allow_noncanonical="$5" allow_rollback="$6"
  local rc refusal disposition
  local plan_snapshot verify_entries verify_checks verify_failures verify_warnings

  AFK_R_COMMAND="$command"
  AFK_R_REQUIRE_SOURCE="false"
  AFK_R_FORCED_EXIT=""
  AFK_R_NEXT_ACTION=""
  AFK_OP_RESULT=""
  AFK_OP_ID=""
  AFK_OP_REASON=""
  AFK_OP_DETAIL=""
  AFK_PLAN_COMMAND="$command"
  AFK_PLAN_JSON="{}"
  AFK_PLAN_IDENTITY=""
  AFK_VERIFY_ENTRIES=""; AFK_VERIFY_CHECKS=0; AFK_VERIFY_FAILURES=0; AFK_VERIFY_WARNINGS=0

  afk_evaluate_installation "$allow_noncanonical" "$allow_rollback"

  # --- an interrupted operation is resolved before any new mutation (FR-45)
  case "$AFK_JOURNAL_STATE" in
    OPEN|UNREADABLE|UNSAFE)
      if [[ "$plan_only" == "true" ]]; then
        AFK_OP_RESULT="REFUSED"
        AFK_OP_REASON="OPERATION_INTERRUPTED"
        afk_plan_compute "$command" || true
        afk_mutation_emit "$json_mode" "$AFK_EXIT_OWNER_ACTION" \
          "Resolve the interrupted operation before planning a new one."
        return $?
      fi
      rc=0
      afk_lock_acquire || rc=$?
      if (( rc != 0 )); then
        afk_lock_refusal "$rc" "$json_mode"
        return $?
      fi
      afk_lock_reclamation_findings
      if afk_recover_interrupted; then
        afk_lock_release
        AFK_OP_RESULT="RECOVERED"
        AFK_OP_REASON="OPERATION_RECOVERED"
        AFK_OP_DETAIL="$AFK_RECOVERY_DETAIL"
        afk_mutation_finding "OPERATION_RECOVERED" "warning" "$AFK_RECOVERY_DETAIL"
        afk_mutation_emit "$json_mode" "$AFK_EXIT_NOT_READY" \
          "An interrupted operation was rolled back and nothing new was attempted. Re-run the command."
        return $?
      fi
      afk_lock_release
      AFK_OP_RESULT="UNRECOVERABLE"
      AFK_OP_REASON="${AFK_RECOVERY_REASON:-OPERATION_ROLLBACK_INCOMPLETE}"
      AFK_OP_DETAIL="$AFK_RECOVERY_DETAIL"
      afk_mutation_finding "$AFK_OP_REASON" "owner_action" "$AFK_RECOVERY_DETAIL"
      afk_mutation_emit "$json_mode" "$AFK_EXIT_OWNER_ACTION" \
        "An interrupted operation could not be rolled back deterministically; its recovery material was kept." \
      ; return $? ;;
    *) : ;;
  esac

  # --- overlapping mutation requests are prevented, not interleaved (FR-92)
  #
  # Only an EXACT live owner refuses here. A lock whose owner this host can
  # prove is gone is reclaimed by afk_lock_acquire below, and one whose owner
  # cannot be judged refuses there with its own reason — deciding either of
  # those from the mere existence of a directory is what made a killed process
  # brick the installation permanently.
  if [[ "$plan_only" != "true" && "$(afk_lock_state)" == "HELD" ]]; then
    afk_lock_evaluate
    if [[ "$AFK_LOCK_OWNER_STATE" == "LIVE" ]]; then
      AFK_OP_RESULT="REFUSED"
      AFK_OP_REASON="CONCURRENT_OPERATION_IN_PROGRESS"
      afk_mutation_finding "CONCURRENT_OPERATION_IN_PROGRESS" "owner_action" "$AFK_LOCK_OWNER_DETAIL"
      afk_mutation_emit "$json_mode" "$AFK_EXIT_OWNER_ACTION" \
        "Wait for the operation in progress to finish, then re-run."
      return $?
    fi
  fi

  # --- the complete deterministic plan, before any write (FR-23, FR-40) ----
  afk_plan_compute "$command" || true
  disposition="$AFK_PLAN_DISPOSITION"
  refusal="$AFK_PLAN_GLOBAL_REFUSAL"

  if [[ "$plan_only" == "true" ]]; then
    AFK_OP_RESULT="PLAN_ONLY"
    AFK_OP_REASON="${refusal:-$disposition}"
    case "$disposition" in
      REFUSED)
        if [[ "$refusal" == "SOURCE_INELIGIBLE" ]]; then
          afk_mutation_emit "$json_mode" "$AFK_EXIT_SOURCE_REFUSED" \
            "This checkout is not an eligible mutation source, so no plan can be authorized from it."
        else
          afk_mutation_emit "$json_mode" "$AFK_EXIT_OWNER_ACTION" \
            "The plan is a refusal: resolve the blocked components above."
        fi ;;
      APPROVAL_REQUIRED)
        afk_mutation_emit "$json_mode" "$AFK_EXIT_OWNER_ACTION" \
          "Approve exactly this plan: re-run with --approve-plan $AFK_PLAN_IDENTITY" ;;
      *)
        afk_mutation_emit "$json_mode" "$AFK_EXIT_OK" \
          "This plan is safe to apply: re-run without --plan." ;;
    esac
    return $?
  fi

  # --- a refusal performs no mutation at all (NFR-2) -----------------------
  if [[ "$disposition" == "REFUSED" ]]; then
    AFK_OP_RESULT="REFUSED"
    AFK_OP_REASON="${refusal:-PLAN_COMPONENT_CONFLICT}"
    if [[ -z "$refusal" ]]; then
      afk_mutation_finding "PLAN_COMPONENT_CONFLICT" "owner_action" "$AFK_PLAN_CONFLICTS blocked components"
    fi
    if [[ "$refusal" == "SOURCE_INELIGIBLE" ]]; then
      afk_mutation_emit "$json_mode" "$AFK_EXIT_SOURCE_REFUSED" \
        "Make this checkout an eligible mutation source, then re-run. Nothing was changed."
    else
      afk_mutation_emit "$json_mode" "$AFK_EXIT_OWNER_ACTION" \
        "Resolve the blocked components above. Nothing was changed."
    fi
    return $?
  fi

  # --- an approval authorizes exactly one plan identity (FR-23, FR-91) -----
  if [[ -n "$approval" && "$approval" != "$AFK_PLAN_IDENTITY" ]]; then
    AFK_OP_RESULT="REFUSED"
    AFK_OP_REASON="PLAN_APPROVAL_MISMATCH"
    AFK_OP_DETAIL="the approved plan is not the plan this run computed"
    afk_mutation_finding "PLAN_APPROVAL_MISMATCH" "owner_action" "$AFK_PLAN_IDENTITY"
    afk_mutation_emit "$json_mode" "$AFK_EXIT_OWNER_ACTION" \
      "Review the plan above and approve its identity; an approval never transfers to a recomputed plan."
    return $?
  fi
  if [[ "$disposition" == "APPROVAL_REQUIRED" && -z "$approval" ]]; then
    AFK_OP_RESULT="APPROVAL_REQUIRED"
    AFK_OP_REASON="PLAN_APPROVAL_REQUIRED"
    afk_mutation_finding "PLAN_APPROVAL_REQUIRED" "owner_action" "$AFK_PLAN_IDENTITY"
    afk_mutation_emit "$json_mode" "$AFK_EXIT_OWNER_ACTION" \
      "Review the plan above, then re-run with --approve-plan $AFK_PLAN_IDENTITY"
    return $?
  fi

  # --- an unchanged installation is a no-op with no churn (FR-46) ----------
  # Adoption is the one exception: establishing ownership is itself the change,
  # so an adoption plan that claims nothing still has a manifest to commit.
  if [[ "$AFK_PLAN_MUTATIONS" == "0" && "$command" != "adopt" ]]; then
    AFK_OP_RESULT="NO_CHANGE"
    AFK_OP_REASON="PLAN_NO_CHANGE_REQUIRED"
    AFK_OP_APPLIED_REVISION="$AFK_APPLIED_REVISION"
    afk_mutation_emit "$json_mode" "$AFK_EXIT_OK" \
      "No action required: the installation already carries this revision, and nothing was written."
    return $?
  fi

  # --- the mutating phase --------------------------------------------------
  rc=0
  afk_lock_acquire || rc=$?
  if (( rc != 0 )); then
    afk_lock_refusal "$rc" "$json_mode"
    return $?
  fi

  afk_transaction_execute "$command" || true
  afk_lock_release

  # The installation is re-evaluated from the filesystem afterwards, so the
  # reported components describe the state that actually exists now rather than
  # the state the plan predicted. The plan and the pre-commit verification are
  # carried across that re-evaluation as the operation's own evidence.
  plan_snapshot="$AFK_PLAN_JSON"
  verify_entries="$AFK_VERIFY_ENTRIES"; verify_checks="$AFK_VERIFY_CHECKS"
  verify_failures="$AFK_VERIFY_FAILURES"; verify_warnings="$AFK_VERIFY_WARNINGS"
  afk_evaluate_installation "$allow_noncanonical" "$allow_rollback"
  AFK_PLAN_JSON="$plan_snapshot"
  AFK_VERIFY_ENTRIES="$verify_entries"; AFK_VERIFY_CHECKS="$verify_checks"
  AFK_VERIFY_FAILURES="$verify_failures"; AFK_VERIFY_WARNINGS="$verify_warnings"

  # Reported AFTER the re-evaluation, because that re-evaluation rebuilds the
  # finding set from the filesystem and a lock this run reclaimed is not a fact
  # the filesystem still holds.
  afk_lock_reclamation_findings

  case "$AFK_OP_RESULT" in
    CONVERGED)
      afk_mutation_emit "$json_mode" "$AFK_EXIT_OK" \
        "Convergence completed and was verified offline; the applied revision now records the target." ;;
    ADOPTED)
      afk_mutation_emit "$json_mode" "$AFK_EXIT_OK" \
        "Ownership is established and was verified offline; run update to converge recognized content." ;;
    STALE_PLAN)
      afk_mutation_finding "$AFK_OP_REASON" "owner_action" "$AFK_OP_DETAIL"
      afk_mutation_emit "$json_mode" "$AFK_EXIT_OWNER_ACTION" \
        "The plan went stale before its first write and nothing was changed. Re-run to compute a fresh plan." ;;
    ROLLED_BACK)
      afk_mutation_finding "OPERATION_ROLLED_BACK" "warning" "$AFK_OP_DETAIL"
      afk_mutation_emit "$json_mode" "$AFK_EXIT_NOT_READY" \
        "The operation failed, every change it made was restored and verified, and the applied revision did not move." ;;
    UNRECOVERABLE)
      afk_mutation_finding "OPERATION_ROLLBACK_INCOMPLETE" "owner_action" "$AFK_OP_DETAIL"
      afk_mutation_emit "$json_mode" "$AFK_EXIT_OWNER_ACTION" \
        "Restoration could not be completed. The recovery journal and backups were kept for the owner." ;;
    *)
      afk_mutation_finding "${AFK_OP_REASON:-PLAN_NOT_COMPUTABLE}" "owner_action" "$AFK_OP_DETAIL"
      afk_mutation_emit "$json_mode" "$AFK_EXIT_OWNER_ACTION" \
        "No mutation was completed. Nothing claims the target revision." ;;
  esac
  return $?
}

afk_cmd_schema() {
  local reasons types actions dispositions results
  reasons="$({ afk_reason_codes; afk_mutation_reason_codes; } \
    | jq -R -s -c 'split("\n") | map(select(length > 0))')" || return 1
  types="$(afk_adaptation_types | jq -R -s -c 'split("\n") | map(select(length > 0))')" || return 1
  actions="$(afk_plan_actions | jq -R -s -c 'split("\n") | map(select(length > 0))')" || return 1
  dispositions="$(afk_plan_dispositions | jq -R -s -c 'split("\n") | map(select(length > 0))')" || return 1
  results="$(afk_operation_results | jq -R -s -c 'split("\n") | map(select(length > 0))')" || return 1
  jq -nc \
    --arg result_schema "$AFK_RESULT_SCHEMA_VERSION" \
    --arg lifecycle_major "$AFK_SUPPORTED_LIFECYCLE_SCHEMA_MAJOR" \
    --arg state_major "$AFK_SUPPORTED_STATE_SCHEMA_MAJOR" \
    --argjson reason_codes "$reasons" \
    --argjson adaptation_types "$types" \
    --argjson plan_actions "$actions" \
    --argjson plan_dispositions "$dispositions" \
    --argjson operation_results "$results" \
    --arg e_ok "$AFK_EXIT_OK" \
    --arg e_usage "$AFK_EXIT_USAGE" \
    --arg e_owner "$AFK_EXIT_OWNER_ACTION" \
    --arg e_notready "$AFK_EXIT_NOT_READY" \
    --arg e_source "$AFK_EXIT_SOURCE_REFUSED" \
    --arg e_live "$AFK_EXIT_LIVE_UNAVAILABLE" \
    '{result_schema_version: $result_schema,
      supported_lifecycle_schema_major: $lifecycle_major,
      supported_state_schema_major: $state_major,
      commands: ["status", "adopt --inspect", "adopt", "update", "verify", "schema"],
      component_states: ["CURRENT", "UPDATE_AVAILABLE", "LOCAL_ADAPTATION", "LOCAL_DRIFT",
                         "EXTERNAL_STATE", "UNKNOWN", "BROKEN", "INCOMPATIBLE",
                         "MIGRATION_REQUIRED", "INTERRUPTED", "UNAVAILABLE", "NOT_EVALUATED",
                         "OUT_OF_SCOPE"],
      overall_states: ["READY", "READY_WITH_ADAPTATION", "READY_WITH_WARNINGS",
                       "NOT_READY", "NEEDS_OWNER"],
      source_states: ["ELIGIBLE", "SOURCE_INELIGIBLE"],
      ownership_classes: ["MANAGED_COPY_TREE", "MANAGED_COPY_FILE", "MANAGED_SECTION",
                          "MANAGED_LINK", "MACHINE_LOCAL", "USER_OWNED", "TARGET_WIRING",
                          "CANONICAL_SOURCE", "KIT_STATE", "REGISTERED_ADAPTATION"],
      severities: ["info", "warning", "owner_action", "blocking"],
      readiness_scopes: ["INSTALLED_INTEGRITY", "MUTATION_SOURCE_ELIGIBLE",
                         "HOST_EXECUTION_READY", "NEW_WORK_READY", "TARGET_READY",
                         "ROUTE_READY"],
      evidence_provenance: ["HASH_COMPARISON", "FILE_STRUCTURE", "PATH_STRUCTURE",
                            "GIT_STATE", "GIT_HISTORY", "MANIFEST_SCHEMA",
                            "OWNERSHIP_RULE", "ADAPTATION_RECORD", "OPERATION_JOURNAL"],
      adaptation_dispositions: ["PRESERVE", "REEVALUATE", "OWNER_REVIEW"],
      adaptation_types: $adaptation_types,
      adaptation_states: ["VALID_MATCHED", "STALE", "INVALID"],
      adoption_dispositions: ["AUTO_ADOPTABLE", "APPROVAL_REQUIRED", "REFUSED", "NOT_INSTALLED"],
      plan_actions: $plan_actions,
      plan_dispositions: $plan_dispositions,
      operation_results: $operation_results,
      journal_states: ["NONE", "PREPARING", "IN_PROGRESS", "ROLLING_BACK", "ROLLED_BACK",
                       "ROLLBACK_INCOMPLETE", "COMMITTED", "UNREADABLE", "UNSAFE"],
      verification_results: ["PASS", "FAIL", "WARN", "SKIP"],
      reason_codes: $reason_codes,
      exit_codes: ({}
        | .[$e_ok]       = "requested scope succeeded (includes READY_WITH_WARNINGS and READY_WITH_ADAPTATION)"
        | .[$e_usage]    = "command, internal, or usage failure"
        | .[$e_owner]    = "owner action or conflict"
        | .[$e_notready] = "deterministic not-ready or verification failure"
        | .[$e_source]   = "source or precondition refusal"
        | .[$e_live]     = "live dependency unavailable or timed out")}' | jq -S '.'
}
