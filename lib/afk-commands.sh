#!/usr/bin/env bash
# afk-commands.sh — the command surface: read-only status, inspect-only
# adoption analysis, the adoption and update transactions, verification, the
# dispatch monitor, and the published schema.
#
# `status`, `adopt --inspect`, `verify`, `monitor` without an action verb and
# every `--plan` invocation write nothing at all: not a manifest, not a journal,
# not a lock, not a cache, not a temporary file. Only afk_run_mutation can reach
# afk-mutate.sh, and only after a complete plan has been computed, approved
# where required, and revalidated.
#
# Two exceptions, and both are declared ones: an explicitly requested live
# evaluation materializes validator fixtures under the system temporary
# directory and removes them again, and the dispatch monitor's action verbs
# write inside the declared state directory — its own watch records, retained
# results and traceability records, and nothing else. No live observation is
# ever persisted into the applied-state manifest (FR-87).
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
#
# The provider variables are here because their mere presence can select a
# metered or redirected execution path for a route approved for native
# subscription funding. Reporting the NAME is what makes that diagnosable;
# reading the value would be the thing this lifecycle refuses to do.
AFK_ENV_NAMES=(
  ANTHROPIC_API_KEY
  ANTHROPIC_AUTH_TOKEN
  ANTHROPIC_BASE_URL
  CLAUDE_CONFIG_DIR
  OPENAI_API_KEY
  OPENAI_BASE_URL
  CODEX_API_KEY
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

afk_installed_integrity_state() {
  printf '%s' "$AFK_FINDINGS" | jq -sr '
    map(select(.blocked_scopes | index("INSTALLED_INTEGRITY"))) as $b
    | if   ($b | map(select(.severity == "owner_action")) | length) > 0 then "NEEDS_OWNER"
      elif ($b | map(select(.severity == "blocking"))     | length) > 0 then "NOT_READY"
      elif ($b | length) > 0 then "READY_WITH_WARNINGS"
      else "READY" end'
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

  # Scoped readiness runs after component evaluation and never before it: the
  # host, target and route scopes are all judged against installed integrity,
  # and integrity is exactly what the component pass just established.
  afk_readiness_evaluate

  # The dispatch-monitor summary is a filesystem fact like installed integrity:
  # it reads the durable watch records, creates nothing, and never fails a
  # command. A host that has never dispatched a worker reports NOT_AVAILABLE.
  afk_monitor_summarize

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

# A readiness-scoped run answers the question it was ASKED. Default status is
# an installed-state question and keeps deriving its exit code from installed
# integrity; a run that requested live readiness or named an execution stamp
# put those scopes into scope, so their verdict decides the code (FR-77).
afk_apply_readiness_exit() {
  local code
  if [[ "$AFK_LIVE_MODE" != "true" && -z "$AFK_STAMP_FILE" ]]; then
    return 0
  fi
  code="$(afk_readiness_exit_code)"
  if [[ -n "$code" ]]; then
    AFK_R_FORCED_EXIT="$code"
  fi
  return 0
}

afk_cmd_status() { # <json-mode> <require-source> <allow-noncanonical> <allow-rollback>
  AFK_R_COMMAND="status"
  AFK_R_REQUIRE_SOURCE="$2"
  AFK_R_FORCED_EXIT=""
  AFK_R_NEXT_ACTION=""
  AFK_R_EXTRA="{}"
  AFK_R_OPERATION='{"id": null, "mutating": false}'
  afk_evaluate_installation "$3" "$4"
  afk_apply_readiness_exit
  afk_pm_apply
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

# --- the dispatch monitor ---------------------------------------------------
#
# One bounded pass per invocation, and never a blocking wait: the durable watch
# record is what survives a coordinator turn, so a completion that arrives while
# nobody is looking is consumed by the next pass rather than by a live poll.
#
# The requested scope is the monitor pass itself, so its verdict decides the
# exit code: an owner action when something is left that only a human can
# decide, and success when the pass settled everything it could.
afk_cmd_monitor() { # <json-mode>
  AFK_R_COMMAND="monitor"
  AFK_R_REQUIRE_SOURCE="false"
  AFK_R_FORCED_EXIT=""
  AFK_R_NEXT_ACTION=""
  AFK_R_EXTRA="{}"
  AFK_R_OPERATION='{"id": null, "mutating": false}'
  afk_evaluate_installation "false" "false"

  case "$AFK_MONITOR_MODE" in
    register)
      afk_monitor_register "$AFK_MONITOR_DESCRIPTOR" || true ;;
    reconcile)
      afk_monitor_reconcile
      afk_pm_reconcile ;;
    cleanup)
      # Settlement follows completion in one bounded pass: consuming the inbox
      # first is what makes a just-completed worker settlable in the same run.
      afk_monitor_reconcile
      afk_pm_reconcile
      afk_monitor_cleanup ;;
    *) : ;;
  esac

  # Recomputed after the action, so the reported counts describe the state the
  # pass left behind rather than the state it started from.
  afk_monitor_summarize
  AFK_R_FORCED_EXIT="$(afk_monitor_exit_code)"
  if [[ "$AFK_MON_NEEDS_HUMAN" == "true" ]]; then
    AFK_R_NEXT_ACTION="Resolve the reported dispatch-monitor findings: a degraded watch is never turned into a worker result, and a resource this pass could not prove it may release is retained."
  else
    AFK_R_NEXT_ACTION="No action required: every watched Dispatch is accounted for, and nothing was released that this host could not prove it owned."
  fi
  # Last, so an outstanding coordinator hand-over speaks over the watch summary:
  # the successor has to be started before any of it is acted on.
  afk_pm_apply
  afk_emit_result "$1"
}

# --- the coordinator's own context budget -----------------------------------
#
# The kit cannot measure a human-started session's context and never tries: the
# PM's window and usage arrive as a PROVIDED observation under the declared state
# directory, judged by the arithmetic a worker's usage gets against thresholds
# that exist only in the declared policy. Nothing here starts a session.

AFK_PM_DIR="${AFK_PM_DIR:-${AFK_STATE_DIR:+$AFK_STATE_DIR/pm}}"
AFK_PM_STAMP_FILE="${AFK_PM_STAMP_FILE:-}"
AFK_PM_SESSION="${AFK_PM_SESSION:-}"
AFK_PM_NEEDS_HUMAN="false"
AFK_PM_RESUME=""
AFK_PM_CONT_SCHEMA="afk-pm-continuation/1"

# The third reason-vocabulary extension hook, on the same terms as the readiness
# and monitor halves — but declared as DATA, because a code, the sentence that
# explains it and the action that resolves it are one fact in three parts, and
# three parallel case statements are three places for them to drift apart.
afk_pm_reason_table() {
  cat <<'CODES'
PM_USAGE_UNOBSERVABLE|No readable coordinator usage observation exists, so the PM context budget is not evaluated rather than assumed healthy.|Checkpoint at the declared PM phase boundaries instead: with no observation the boundary is the only budget signal there is.
PM_USAGE_CUMULATIVE_ONLY|The adapter could report only a cumulative total over the session calls, which is not the context the session holds, so no ratio is computed from it.|Read the figure as total consumption for sizing and keep checkpointing at phase boundaries; do not treat it as occupancy.
PM_WINDOW_UNDECLARED|No PM execution stamp was supplied and the observation declares no window, so there is nothing to measure occupancy against.|Supply the coordinator window through --pm-stamp, or have the adapter report window_tokens in the observation.
PM_STAMP_UNUSABLE|A PM execution stamp was supplied explicitly but its shape or its catalog window could not be resolved, so the budget reports nothing rather than measuring against a different authority.|Fix the supplied stamp or declare the trusted catalog through AFK_ROUTER_CATALOG; a stamp passed explicitly is never silently ignored.
PM_BUDGET_POLICY_UNREADABLE|The declared context-budget policy could not be read or is missing a threshold, and a missing threshold is never a default.|Repair the declared context-budget policy document; tuning a threshold is a policy edit and the kit carries no fallback value.
PM_CHECKPOINT_DUE|The coordinator session occupies at or past the declared checkpoint ratio of its window.|Write the coordinator checkpoint now: agent-flow-kit pm-checkpoint --write <json>
PM_CONTINUATION_REQUIRED|The coordinator session must hand over to a successor: a continuation artifact is outstanding, or occupancy is at or past the declared continuation ratio.|Start the successor ORCH PM session yourself in Orca with the resume instruction the artifact carries; this kit launches no session.
PM_CONTINUATION_RECONCILED|A successor coordinator session consumed the outstanding continuation artifact, so the hand-over is accounted for.|No action required: the successor is bound to the artifact it consumed.
PM_CONTINUATION_ARTIFACT_INVALID|A PM continuation artifact is present but does not validate, so nothing can be proven to have been handed over.|Inspect the artifact by hand and rewrite it through pm-checkpoint --continuation; an unreadable hand-over is never treated as one.
PM_ARTIFACT_SECRET_BEARING|A submitted PM artifact carries a secret-looking member, and a coordinator artifact is secret-free by rule.|Remove the secret-bearing member and resubmit; the refused value was never echoed and nothing was written.
CODES
}

afk_pm_reason_codes()   { afk_pm_reason_table | cut -d '|' -f 1; }
# Both print nothing for a code they do not own, keeping the unknown-code
# fallback in afk-common.sh the single answer to one.
afk_pm_reason_message() { afk_pm_reason_table | awk -F '|' -v c="$1" '$1 == c { print $2 }'; }
afk_pm_reason_action()  { afk_pm_reason_table | awk -F '|' -v c="$1" '$1 == c { print $3 }'; }

# The declared policy, read from the launcher's own path exactly as dispatch.sh
# reads it. Unreadable or missing the key fails; nothing substitutes a number.
afk_pm_policy_ppm() { # <threshold key> -> parts per million
  local pol line value
  pol="${AGENT_FLOW_BUDGET_POLICY:-${AFK_SKILLS_HOME:+$AFK_SKILLS_HOME/model-router/context-budget-policy.yaml}}"
  [[ -n "$pol" && -r "$pol" ]] || return 1
  line="$(grep -E "^${1}:[[:space:]]+[0-9]+(\.[0-9]+)?[[:space:]]*(#.*)?$" "$pol" 2>/dev/null | head -1)"
  [[ -n "$line" ]] || return 1
  value="${line#*:}"; value="${value%%#*}"; value="${value//[[:space:]]/}"
  awk -v r="$value" 'BEGIN { printf "%d", (r * 1000000) + 0.5 }'
}

# A stamped profile's window is the trusted catalog's min_context, read from the
# catalog the launcher declares. The kit holds no catalog and invents no window.
afk_pm_catalog_window() { # <model profile> -> token count
  local catalog window
  catalog="${AFK_ROUTER_CATALOG:-${AGENT_STAMP_VALIDATE_CATALOG_PATH:-}}"
  [[ -n "$catalog" && -r "$catalog" ]] || return 1
  window="$(awk -v want="$1" '
    /^profiles:[[:space:]]*$/ { inp = 1; next }
    inp && /^[^[:space:]]/  { inp = 0 }
    !inp                    { next }
    { line = $0; sub(/[[:space:]]*#.*$/, "", line) }
    line ~ /^  "?[^:]+"?:[[:space:]]*$/ {
      key = line; sub(/^  "?/, "", key); sub(/"?:[[:space:]]*$/, "", key)
      cur = (key == want); next }
    cur && line ~ /^[[:space:]]+min_context:[[:space:]]*[0-9]+[[:space:]]*$/ {
      sub(/^[^:]*:[[:space:]]*/, "", line); gsub(/[[:space:]]/, "", line)
      print line; exit }' "$catalog" 2>/dev/null)"
  [[ "$window" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s' "$window"
}

# Provenance is RECORDED, never inferred: a document that declares none is
# malformed, not a hand-written observation by default.
afk_pm_observation() {
  [[ -n "$AFK_PM_DIR" && -f "$AFK_PM_DIR/usage.json" ]] || return 1
  jq -ce 'def str: type == "string" and (length > 0);
    select((type == "object") and (.schema == "afk-pm-usage/1") and (.harness | str)
      and (.window_tokens | type == "number" or type == "null")
      and (.usage_tokens  | type == "number" or type == "null")
      and (.provenance | . == "HARNESS_ADAPTER" or . == "HUMAN")
      and (.observed_at | str) and (.session | str))' \
    "$AFK_PM_DIR/usage.json" 2>/dev/null
}

# The one shape both artifacts present; `continuation` adds the instruction the
# human is handed. Validates a submission and reads one back.
afk_pm_artifact_valid() { # <document> <schema> <continuation: true|false>
  printf '%s' "$1" | jq -ce --arg schema "$2" --arg cont "$3" '
    def str: type == "string" and (length > 0);
    select((type == "object") and (.schema == $schema)
      and ([.decisions, .envelope_actions, .open_escalations, .in_flight_dispatches]
           | all(type == "array"))
      and (.budget_state | type == "object")
      and ([.in_flight_dispatches[] | select(type != "string")] | length == 0)
      and (.updated_at | str)
      and (if $cont == "true" then (.resume_instruction | str) else true end))' 2>/dev/null
}

afk_pm_identity() { # <path> -> {path, sha256} or null
  [[ -n "${1:-}" && -f "$1" ]] || { printf 'null'; return 0; }
  jq -nc --arg p "$1" --arg s "$(afk_sha256_file "$1")" '{path: $p, sha256: $s}'
}

# The window hierarchy is applied IN ORDER, and a stamp named on the command
# line is never silently ignored: one that cannot be resolved reports itself
# unusable rather than falling through to another authority, because the caller
# who named it asked for THAT window and no other. The loud condition follows
# from the same pass: an owner action naming the artifact by path and digest and
# carrying the resume instruction verbatim, because the human starts the
# successor and no verb here can.
afk_pm_apply() {
  local obs="" window="" src="NOT_EVALUATED" usage="null" ratio="null"
  local state="NOT_EVALUATED" reason="PM_USAGE_UNOBSERVABLE"
  local ck cont ppm profile doc sha rec cont_id

  AFK_PM_NEEDS_HUMAN="false"; AFK_PM_RESUME=""
  obs="$(afk_pm_observation)" || obs=""

  if [[ -n "$AFK_PM_STAMP_FILE" ]]; then
    if [[ -f "$AFK_PM_STAMP_FILE" ]] && afk_stamp_shape_is_valid "$AFK_PM_STAMP_FILE"; then
      profile="$(jq -r '.model_profile' "$AFK_PM_STAMP_FILE" 2>/dev/null)" || profile=""
      window="$(afk_pm_catalog_window "$profile")" || window=""
    fi
    if [[ -n "$window" ]]; then src="STAMP"; else reason="PM_STAMP_UNUSABLE"; fi
  elif [[ -n "$obs" ]]; then
    window="$(printf '%s' "$obs" | jq -r 'if (.window_tokens | type == "number") and (.window_tokens > 0) then (.window_tokens | floor) else "" end')"
    if [[ -n "$window" ]]; then src="ADAPTER"; else reason="PM_WINDOW_UNDECLARED"; fi
  fi

  if [[ -n "$obs" ]]; then
    usage="$(printf '%s' "$obs" | jq -r 'if (.usage_tokens | type == "number") and (.usage_tokens >= 0) then (.usage_tokens | floor) else "null" end')"
    if [[ "$usage" == "null" && "$reason" != "PM_STAMP_UNUSABLE" ]]; then
      reason="$(printf '%s' "$obs" | jq -r 'if .reason == "PM_USAGE_CUMULATIVE_ONLY" then "PM_USAGE_CUMULATIVE_ONLY" else "PM_USAGE_UNOBSERVABLE" end')"
    fi
  fi

  # The same parts-per-million arithmetic and boundary equality as a worker's.
  if [[ -n "$window" && "$usage" != "null" && "$reason" != "PM_STAMP_UNUSABLE" ]]; then
    if ck="$(afk_pm_policy_ppm checkpoint_ratio)" && cont="$(afk_pm_policy_ppm continuation_ratio)" \
       && [[ -n "$ck" && -n "$cont" ]]; then
      ppm=$(( usage * 1000000 / window ))
      ratio="$(awk -v p="$ppm" 'BEGIN { printf "%.6f", p / 1000000 }')"
      if   (( ppm >= cont )); then state="CONTINUATION_REQUIRED"; reason="PM_CONTINUATION_REQUIRED"
      elif (( ppm >= ck ));   then state="CHECKPOINT_DUE";        reason="PM_CHECKPOINT_DUE"
      else state="OK"; reason="null"; fi
    else
      reason="PM_BUDGET_POLICY_UNREADABLE"
    fi
  fi

  # An outstanding hand-over is loud on its own evidence, whatever a ratio says:
  # the artifact validates and no successor has reconciled THAT artifact.
  cont_id="$(afk_pm_identity "${AFK_PM_DIR:+$AFK_PM_DIR/continuation.json}")"
  if [[ -n "$AFK_PM_DIR" && -f "$AFK_PM_DIR/continuation.json" ]]; then
    doc="$(afk_pm_artifact_valid "$(cat "$AFK_PM_DIR/continuation.json" 2>/dev/null)" "$AFK_PM_CONT_SCHEMA" true)" || doc=""
    if [[ -z "$doc" ]]; then
      state="NOT_EVALUATED"; reason="PM_CONTINUATION_ARTIFACT_INVALID"
    else
      sha="$(afk_sha256_file "$AFK_PM_DIR/continuation.json")"
      rec="$(jq -r '.artifact_sha256 // ""' "$AFK_PM_DIR/continuation.reconciled.json" 2>/dev/null)" || rec=""
      if [[ "$rec" != "$sha" ]]; then
        AFK_PM_RESUME="$(printf '%s' "$doc" | jq -r '.resume_instruction')"
        state="CONTINUATION_REQUIRED"; reason="PM_CONTINUATION_REQUIRED"
      fi
    fi
  fi
  case "$reason" in
    PM_CONTINUATION_REQUIRED|PM_CONTINUATION_ARTIFACT_INVALID) AFK_PM_NEEDS_HUMAN="true" ;;
  esac

  AFK_R_EXTRA="$(jq -nc --argjson window "${window:-null}" --arg src "$src" \
    --argjson usage "$usage" --argjson ratio "$ratio" --arg state "$state" \
    --arg reason "$reason" --argjson continuation "$cont_id" \
    --argjson checkpoint "$(afk_pm_identity "${AFK_PM_DIR:+$AFK_PM_DIR/checkpoint.json}")" \
    --arg needs_human "$AFK_PM_NEEDS_HUMAN" --argjson base "$AFK_R_EXTRA" \
    '$base + {pm_budget: {window_tokens: $window, window_source: $src,
      usage_tokens: $usage, usage_ratio: $ratio, state: $state,
      reason: (if $reason == "null" then null else $reason end),
      checkpoint_artifact: $checkpoint, continuation_artifact: $continuation,
      needs_human: ($needs_human == "true")}}')" || return 0
  [[ "$AFK_PM_NEEDS_HUMAN" == "true" ]] || return 0

  afk_add_finding "orchestration" "KIT_STATE" "EXTERNAL_STATE" "$reason" \
    "owner_action" "NEW_WORK_READY" "FILE_STRUCTURE" \
    "no outstanding coordinator hand-over" \
    "$(printf '%s' "$cont_id" | jq -r 'if . == null then "an occupancy at or past the declared continuation ratio" else "\(.path) \(.sha256)" end')" \
    "true" "false" \
    "$(if [[ -n "$AFK_PM_RESUME" ]]; then printf 'resume_instruction: %s' "$AFK_PM_RESUME"; else printf 'no valid continuation artifact carries a resume instruction'; fi)"

  if [[ -z "$AFK_R_FORCED_EXIT" || "$AFK_R_FORCED_EXIT" == "$AFK_EXIT_OK" ]]; then
    AFK_R_FORCED_EXIT="$AFK_EXIT_OWNER_ACTION"
  fi
  if [[ -n "$AFK_PM_RESUME" ]]; then
    AFK_R_NEXT_ACTION="Start the successor ORCH PM session yourself in Orca, then run: $AFK_PM_RESUME"
  else
    AFK_R_NEXT_ACTION="Write the coordinator continuation artifact (agent-flow-kit pm-checkpoint --continuation --write <json>) and start the successor ORCH PM session yourself in Orca."
  fi
  return 0
}

# One additive step on the reconcile pass, reading and writing only under pm/ —
# no watch record, delivery or worker resource is touched, which is what leaves
# an in-flight watch unaffected by a coordinator hand-over.
afk_pm_reconcile() {
  local doc sha session count now
  [[ -n "$AFK_PM_DIR" && -f "$AFK_PM_DIR/continuation.json" ]] || return 0
  doc="$(afk_pm_artifact_valid "$(cat "$AFK_PM_DIR/continuation.json" 2>/dev/null)" "$AFK_PM_CONT_SCHEMA" true)" || doc=""
  # An artifact that does not validate is reconciled by nothing. Reporting it is
  # the evaluation's job, which runs on this same pass: a step that raised its
  # own finding beside that one would report the single condition twice.
  [[ -n "$doc" ]] || return 0
  sha="$(afk_sha256_file "$AFK_PM_DIR/continuation.json")"
  [[ "$(jq -r '.artifact_sha256 // ""' "$AFK_PM_DIR/continuation.reconciled.json" 2>/dev/null)" != "$sha" ]] || return 0

  session="$AFK_PM_SESSION"
  [[ -n "$session" ]] || session="$(afk_pm_observation | jq -r '.session // ""' 2>/dev/null)" || session=""
  count="$(jq -r '.pm_continuations // 0' "$AFK_PM_DIR/budget-state.json" 2>/dev/null)"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  count=$(( count + 1 ))
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  afk_state_file_write "$AFK_PM_DIR/continuation.reconciled.json" \
    "$(jq -nc --arg sha "$sha" --arg s "$session" --arg at "$now" \
       '{schema: "afk-pm-continuation-reconciled/1", artifact_sha256: $sha,
         successor_session: (if $s == "" then null else $s end), reconciled_at: $at}')" || return 0
  afk_state_file_write "$AFK_PM_DIR/budget-state.json" \
    "$(jq -nc --argjson n "$count" --arg at "$now" \
       '{schema: "afk-pm-budget-state/1", pm_continuations: $n, updated_at: $at}')" || return 0

  afk_add_finding "orchestration" "KIT_STATE" "EXTERNAL_STATE" \
    "PM_CONTINUATION_RECONCILED" "info" "" "FILE_STRUCTURE" \
    "an outstanding coordinator hand-over" "reconciled by ${session:-an unnamed successor session}" \
    "true" "false" "pm_continuations=$count"
  return 0
}

# Secret-free BY RULE, decided before anything is written, and the value is never
# echoed: the member NAME's classification decides the first branch, and the
# second is a shape match whose subject is never printed.
afk_pm_secret_bearing() { # <document> -> 0 when it must be refused
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if [[ "$(afk_env_classification "$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')")" == "SECRET_BEARING" ]]; then
      return 0
    fi
  done < <(printf '%s' "$1" | jq -r '[paths | .[] | select(type == "string")] | unique[]' 2>/dev/null)
  printf '%s' "$1" | jq -e --arg p '(^|[^A-Za-z0-9_-])(sk|rk)-[A-Za-z0-9_-]{12,}|(^|[^A-Za-z0-9_-])(ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9_]{12,}|(^|[^A-Za-z0-9_-])xox[abprs]-[A-Za-z0-9-]{10,}|(^|[^A-Za-z0-9_-])AKIA[0-9A-Z]{12,}|-----BEGIN [A-Z ]*PRIVATE KEY-----' \
    '[.. | strings | select(test($p))] | length > 0' >/dev/null 2>&1
}

# Validated first, then settled through the kit's atomic state writer, so a
# refused submission leaves what is on disk byte-identical, never half-replaced.
afk_cmd_pm_checkpoint() { # <json-mode> <submitted path> <continuation: true|false>
  local json_mode="$1" path="$2" continuation="$3" schema target doc
  AFK_R_COMMAND="pm-checkpoint"
  AFK_R_REQUIRE_SOURCE="false"; AFK_R_FORCED_EXIT=""; AFK_R_NEXT_ACTION=""
  AFK_R_EXTRA="{}"; AFK_R_OPERATION='{"id": null, "mutating": false}'

  if [[ -z "$AFK_PM_DIR" ]]; then
    afk_warn "no state directory is declared, so there is nowhere a coordinator artifact could be written"
    return "$AFK_EXIT_USAGE"
  fi
  if [[ "$continuation" == "true" ]]; then
    schema="$AFK_PM_CONT_SCHEMA"; target="$AFK_PM_DIR/continuation.json"
  else
    schema="afk-pm-checkpoint/1"; target="$AFK_PM_DIR/checkpoint.json"
  fi

  if [[ ! -f "$path" ]] || ! doc="$(jq -c '.' "$path" 2>/dev/null)" || [[ -z "$doc" ]]; then
    afk_warn "the submitted coordinator artifact could not be read as JSON; nothing was written"
    return "$AFK_EXIT_USAGE"
  fi
  # Refused BEFORE the shape check and before any write, so a secret cannot
  # reach a diagnostic on its way to being rejected for some other reason.
  if afk_pm_secret_bearing "$doc"; then
    afk_warn "refused: the submitted coordinator artifact carries a secret-looking member. A PM artifact is secret-free by rule, the value reached no diagnostic, and nothing was written."
    return "$AFK_EXIT_SOURCE_REFUSED"
  fi
  # A document declaring a different schema is a document about something else.
  case "$(printf '%s' "$doc" | jq -r '.schema // ""')" in
    ""|"$schema") doc="$(printf '%s' "$doc" | jq -c --arg s "$schema" '.schema = $s')" ;;
    *) doc="" ;;
  esac
  if [[ -n "$doc" ]]; then doc="$(afk_pm_artifact_valid "$doc" "$schema" "$continuation")" || doc=""; fi
  if [[ -z "$doc" ]]; then
    afk_warn "the submitted coordinator artifact does not present the required shape; nothing was written"
    return "$AFK_EXIT_USAGE"
  fi
  if ! afk_state_file_write "$target" "$doc"; then
    afk_warn "the coordinator artifact could not be settled in the declared state directory"
    return "$AFK_EXIT_USAGE"
  fi

  # The requested scope is the artifact, so its verdict decides the exit code:
  # a host that has not been adopted has no bearing on whether the coordinator's
  # own hand-over validated and was written. afk_pm_apply raises it to the
  # owner-action code when what was written is an outstanding hand-over.
  afk_evaluate_installation "false" "false"
  AFK_R_FORCED_EXIT="$AFK_EXIT_OK"
  afk_pm_apply
  afk_emit_result "$json_mode"
}

# --- verification -----------------------------------------------------------

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

  # The verification CHECKS are hash comparisons and are offline whatever else
  # the run did — but the RUN is not, once live readiness was requested, and a
  # document that said otherwise would be describing a command that did not
  # happen. So the two flags report this invocation rather than the check kind.
  AFK_R_EXTRA="$(afk_verification_json "$verified" \
    | jq -c --arg live "$AFK_LIVE_MODE" \
        '{verification: (. + {offline: ($live != "true"),
                              live_probes_performed: ($live == "true")})}')"

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
  afk_apply_readiness_exit
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
  reasons="$({ afk_reason_codes; afk_mutation_reason_codes; afk_readiness_reason_codes; afk_monitor_reason_codes; afk_pm_reason_codes; } \
    | jq -R -s -c 'split("\n") | map(select(length > 0))')" || return 1
  types="$(afk_adaptation_types | jq -R -s -c 'split("\n") | map(select(length > 0))')" || return 1
  actions="$(afk_plan_actions | jq -R -s -c 'split("\n") | map(select(length > 0))')" || return 1
  dispositions="$(afk_plan_dispositions | jq -R -s -c 'split("\n") | map(select(length > 0))')" || return 1
  results="$(afk_operation_results | jq -R -s -c 'split("\n") | map(select(length > 0))')" || return 1
  jq -nc \
    --arg result_schema "$AFK_RESULT_SCHEMA_VERSION" \
    --arg lifecycle_major "$AFK_SUPPORTED_LIFECYCLE_SCHEMA_MAJOR" \
    --arg state_major "$AFK_SUPPORTED_STATE_SCHEMA_MAJOR" \
    --arg stamp_major "$AFK_SUPPORTED_STAMP_SCHEMA_MAJOR" \
    --arg validator_major "$AFK_SUPPORTED_VALIDATOR_CONTRACT_MAJOR" \
    --arg wiring_major "$AFK_SUPPORTED_TARGET_WIRING_MAJOR" \
    --arg orch_major "$AFK_SUPPORTED_ORCH_STATE_MAJOR" \
    --arg dispatch_major "$AFK_SUPPORTED_DISPATCH_SCHEMA_MAJOR" \
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
      supported_stamp_schema_major: $stamp_major,
      supported_validator_contract_major: $validator_major,
      supported_target_wiring_major: $wiring_major,
      supported_orchestration_state_major: $orch_major,
      supported_dispatch_schema_major: $dispatch_major,
      commands: ["status", "adopt --inspect", "adopt", "update", "verify", "monitor",
                 "pm-checkpoint", "schema"],
      component_states: ["CURRENT", "UPDATE_AVAILABLE", "LOCAL_ADAPTATION", "LOCAL_DRIFT",
                         "EXTERNAL_STATE", "UNKNOWN", "BROKEN", "INCOMPATIBLE",
                         "MIGRATION_REQUIRED", "INTERRUPTED", "UNAVAILABLE", "NOT_EVALUATED",
                         "OUT_OF_SCOPE"],
      overall_states: ["READY", "READY_WITH_ADAPTATION", "READY_WITH_WARNINGS",
                       "NOT_READY", "NEEDS_OWNER"],
      readiness_states: ["TRUE", "FALSE", "PARTIAL", "UNAVAILABLE", "NOT_EVALUATED",
                         "OUT_OF_SCOPE"],
      target_states: ["READY", "INCOMPATIBLE", "BROKEN", "NOT_EVALUATED"],
      live_fact_states: ["PRESENT", "ABSENT", "AVAILABLE", "UNAVAILABLE", "COMPATIBLE",
                         "INCOMPATIBLE", "UNKNOWN", "NOT_EVALUATED", "OUT_OF_SCOPE"],
      orchestration_states: ["ACTIVE", "INACTIVE", "NOT_AVAILABLE"],
      orchestration_modes: ["PLAN", "ORCH", "WORKER"],
      monitor_states: ["NOT_AVAILABLE", "IDLE", "WATCHING", "NEEDS_HUMAN"],
      budget_states: ["OK", "CHECKPOINT_DUE", "CONTINUATION_REQUIRED", "NOT_EVALUATED"],
      budget_reason_codes: ["CONTEXT_WINDOW_UNDECLARED", "SIZING_REFUSED", "SIZING_RISK",
                            "PAYLOAD_REF_MISSING", "BUDGET_POLICY_UNREADABLE",
                            "USAGE_UNOBSERVABLE", "HIGH_USAGE", "WINDOW_DISAGREEMENT",
                            "CHECKPOINT_ARTIFACT_INVALID", "CHECKPOINT_ARTIFACT_STALE",
                            "CONTINUATION_ARTIFACT_INVALID", "WINDOW_UNCORROBORATED",
                            "CONTINUATION_CAP_REACHED", "REPEATED_CONTINUATION",
                            "CONTINUATION_STAMP_REFRESH_REQUIRED", "CONTINUATION_REFUSED",
                            "CONTINUATION_ARTIFACT_UNBOUND", "CYCLE_ALREADY_RETAINED"],
      dispatch_result_statuses: ["done", "gates_failed", "continuation_required",
                                 "needs_human"],
      dispatch_states: ["WATCHING", "COMPLETED", "SETTLED", "MONITOR_DEGRADED"],
      cleanup_dispositions: ["PENDING", "REMOVED", "RETAINED", "NOT_APPLICABLE", "NEEDS_OWNER"],
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
                            "OWNERSHIP_RULE", "ADAPTATION_RECORD", "OPERATION_JOURNAL",
                            "VERSION_PROBE", "CAPABILITY_PROBE", "AUTH_STATUS_PROBE",
                            "ROUTER_STATUS", "VALIDATOR_FIXTURE", "BMAD_RESOLUTION"],
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
      approved_harnesses: ["claude", "codex"],
      reason_codes: $reason_codes,
      exit_codes: ({}
        | .[$e_ok]       = "requested scope succeeded (includes READY_WITH_WARNINGS and READY_WITH_ADAPTATION)"
        | .[$e_usage]    = "command, internal, or usage failure"
        | .[$e_owner]    = "owner action or conflict"
        | .[$e_notready] = "deterministic not-ready or verification failure"
        | .[$e_source]   = "source or precondition refusal"
        | .[$e_live]     = "live dependency unavailable or timed out")}' | jq -S '.'
}
