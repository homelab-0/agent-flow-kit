#!/usr/bin/env bash
# afk-inventory.sh — the declared component model, the state manifest, the
# registered-adaptation contract, and deterministic ownership/state
# classification.
#
# Every classification in this file is a mechanical comparison of declared
# ownership rules and bounded identifiers. There is no heuristic and no
# judgement call: a difference is legitimate because an ownership rule or a
# valid registered adaptation says so, or it is LOCAL_DRIFT (FR-6, FR-9).
#
# Registered BMAD targets are INVENTORIED here (the manifest is read below) and
# RESOLVED in afk-readiness.sh, which is where target wiring, personas and
# templates are proven. Directory presence is not compatibility, so there is no
# presence-only target verdict in this file.
#
# Identity computations are read into a variable WITHOUT `|| var=""`. A helper
# that fails prints nothing, so the empty-string check below catches it; adding
# `||` would let an unrelated non-zero (a `find` that hit one unreadable
# subdirectory under pipefail) discard an identity that was computed correctly.
#
# shellcheck disable=SC2034,SC2154
# The C_*/F_* accumulators are written here and read by afk_c_emit/afk_f_emit
# in afk-common.sh, and the declared-path globals are assigned there and read
# here; the files are always sourced together, and `set -u` in the entry point
# is the real guard against an unset read.

if [[ -n "${AFK_INVENTORY_SOURCED:-}" ]]; then
  return 0
fi
AFK_INVENTORY_SOURCED=1

# --- the declared inventory -------------------------------------------------
#
#   id | ownership | source_kind | source_rel | dest_kind | dest_path |
#   extra | execution_critical | container_root | target_root
#
# extra means: comma-separated tree exclusions (MANAGED_COPY_TREE), the section
# id (MANAGED_SECTION), or the declared link target (MANAGED_LINK).
#
# container_root is the declared root the destination must LIVE under; a
# symlinked parent directory that moves it elsewhere fails closed. target_root
# is the declared root the destination may POINT into, or resolve to.
#
# execution_critical marks the components without which the approved dispatch
# path cannot run at all. A non-critical component's problem is scoped to
# itself (FR-21) and can still refuse to be overwritten (FR-19) without making
# the whole host NOT_READY.

afk_component_table() {
  cat <<EOF
afk-runtime-adapters|MANAGED_COPY_TREE|tree|adapters|dir|$AFK_SKILLS_HOME/afk-runtime|bin,lib,lifecycle|false|$AFK_SKILLS_HOME|$AFK_SKILLS_HOME
afk-runtime-bin|MANAGED_COPY_TREE|tree|bin|dir|$AFK_SKILLS_HOME/afk-runtime/bin||false|$AFK_SKILLS_HOME|$AFK_SKILLS_HOME
afk-runtime-lib|MANAGED_COPY_TREE|tree|lib|dir|$AFK_SKILLS_HOME/afk-runtime/lib||false|$AFK_SKILLS_HOME|$AFK_SKILLS_HOME
afk-runtime-release-policy|MANAGED_COPY_FILE|file|lifecycle/release-policy.json|file|$AFK_SKILLS_HOME/afk-runtime/lifecycle/release-policy.json||false|$AFK_SKILLS_HOME|$AFK_SKILLS_HOME
model-router|MANAGED_COPY_TREE|tree|files/model-router|dir|$AFK_SKILLS_HOME/model-router|subscriptions.yaml|true|$AFK_SKILLS_HOME|$AFK_SKILLS_HOME
model-router-config|MACHINE_LOCAL|none||file|$AFK_SKILLS_HOME/model-router/subscriptions.yaml||false|$AFK_SKILLS_HOME|$AFK_SKILLS_HOME
model-router-claude-link|MANAGED_LINK|none||link|$AFK_CLAUDE_HOME/skills/model-router|$AFK_SKILLS_HOME/model-router|true|$AFK_CLAUDE_HOME|$AFK_SKILLS_HOME
humanizer|MANAGED_COPY_TREE|tree|files/humanizer|dir|$AFK_SKILLS_HOME/humanizer||false|$AFK_SKILLS_HOME|$AFK_SKILLS_HOME
humanizer-claude-link|MANAGED_LINK|none||link|$AFK_CLAUDE_HOME/skills/humanizer|$AFK_SKILLS_HOME/humanizer|false|$AFK_CLAUDE_HOME|$AFK_SKILLS_HOME
claude-global-policy|MANAGED_SECTION|file|files/claude-global-CLAUDE.md|section|$AFK_CLAUDE_HOME/CLAUDE.md|claude-global-policy|true|$AFK_CLAUDE_HOME|$AFK_CLAUDE_HOME
codex-global-guidance|MANAGED_COPY_FILE|file|files/codex-AGENTS.md|file|$AFK_CODEX_HOME/AGENTS.md||false|$AFK_CODEX_HOME|$AFK_CODEX_HOME
EOF
}

# --- observation accounting (AD-19) -----------------------------------------
#
# Test-visible only: AFK_OBSERVATION_PASSES counts full-inventory passes in
# this process, and with AFK_TEST_OBSERVATION_LOG set every observation is
# appended there as "<point> [component]" so a suite can count them per verb.
# Neither ever reaches a result document.
AFK_OBSERVATION_PASSES=0
afk_observation_note() { # <point> [component]
  [[ -n "${2:-}" ]] || AFK_OBSERVATION_PASSES=$((AFK_OBSERVATION_PASSES + 1))
  [[ -z "${AFK_TEST_OBSERVATION_LOG:-}" ]] \
    || printf '%s%s\n' "$1" "${2:+ $2}" >> "$AFK_TEST_OBSERVATION_LOG" 2>/dev/null || true
}

afk_component_row() { # <id> -> the declared row
  local id="$1" line
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    if [[ "${line%%|*}" == "$id" ]]; then
      printf '%s\n' "$line"
      return 0
    fi
  done < <(afk_component_table)
  return 1
}

afk_component_exists() { # <id>
  afk_component_row "$1" >/dev/null
}

# Exact, line-oriented membership. Never word splitting, never globbing.
afk_id_in_list() { # <id> <newline-separated list>
  [[ -n "$1" && -n "${2:-}" ]] || return 1
  printf '%s\n' "$2" | grep -q -x -F -- "$1"
}

# --- the state manifest -----------------------------------------------------

AFK_MANIFEST_PRESENT="false"
AFK_MANIFEST_USABLE="false"
AFK_MANIFEST_JSON="{}"
AFK_MANIFEST_REASON=""
AFK_APPLIED_REVISION=""
AFK_STATE_SCHEMA_VERSION=""
AFK_MANIFEST_REPO_IDENTITY=""
AFK_ADOPTED="false"

# The ownership boundary for a declared kit-state path. A path inside the
# declared state directory is bounded by it; an explicitly reconfigured path is
# bounded by its own declared parent. Either way the boundary is DECLARED, and
# a symlink that leaves it fails closed.
afk_state_boundary() { # <declared-path>
  local p="$1"
  if [[ -n "$AFK_STATE_DIR" && "$p" == "$AFK_STATE_DIR"/* ]]; then
    printf '%s' "$AFK_STATE_DIR"
  else
    dirname -- "$p"
  fi
}

# The complete recognized manifest shape. A manifest is an ownership record or
# it is nothing: interpreting half of one is how a lifecycle ends up claiming
# ownership it cannot prove.
afk_manifest_shape_is_valid() { # <path>
  jq -e '
    (type == "object")
    and (.applied_revision | type == "string")
    and (.applied_revision | test("^[0-9a-f]{40}$"))
    and (.repository | type == "object")
    and (.repository.identity | type == "string") and (.repository.identity | length > 0)
    and (.components | type == "object")
    and (all(.components[];
             (type == "object")
             and (.identity | type == "string") and (.identity | length > 0)
             and (.ownership | type == "string") and (.ownership | length > 0)
             and (.path | type == "string") and (.path | length > 0)))
    and (.adaptations | type == "array")
    and (.targets | type == "array")
    and (all(.targets[];
             (type == "object")
             and (.id | type == "string") and (.id | length > 0)
             and (.path | type == "string") and (.path | length > 0)))
  ' "$1" >/dev/null 2>&1
}

afk_load_manifest() {
  AFK_MANIFEST_PRESENT="false"; AFK_MANIFEST_USABLE="false"; AFK_MANIFEST_JSON="{}"
  AFK_MANIFEST_REASON=""; AFK_APPLIED_REVISION=""; AFK_STATE_SCHEMA_VERSION=""
  AFK_MANIFEST_REPO_IDENTITY=""; AFK_ADOPTED="false"

  if [[ ! -e "$AFK_MANIFEST" && ! -L "$AFK_MANIFEST" ]]; then
    AFK_MANIFEST_REASON="INSTALLATION_NOT_ADOPTED"
    return 0
  fi
  AFK_MANIFEST_PRESENT="true"
  local guard boundary j major
  boundary="$(afk_state_boundary "$AFK_MANIFEST")"
  afk_path_guard_v guard "$AFK_MANIFEST" file "$boundary" "$boundary"
  if [[ "$guard" != "PATH_OK" ]]; then
    AFK_MANIFEST_REASON="STATE_MANIFEST_PATH_UNSAFE"
    return 0
  fi
  if ! j="$(jq -c '.' "$AFK_MANIFEST" 2>/dev/null)"; then
    AFK_MANIFEST_REASON="STATE_SCHEMA_UNRECOGNIZED"
    return 0
  fi
  AFK_MANIFEST_JSON="$j"
  AFK_STATE_SCHEMA_VERSION="$(printf '%s' "$j" | jq -r 'if (.state_schema_version | type) == "string" then .state_schema_version else "" end')"
  if [[ ! "$AFK_STATE_SCHEMA_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
    AFK_MANIFEST_REASON="STATE_SCHEMA_UNRECOGNIZED"
    return 0
  fi
  major="${AFK_STATE_SCHEMA_VERSION%%.*}"
  if (( major > AFK_SUPPORTED_STATE_SCHEMA_MAJOR )); then
    AFK_MANIFEST_REASON="STATE_SCHEMA_UNKNOWN_MAJOR"
    return 0
  fi
  # The shape is validated BEFORE the manifest is treated as adopted, and
  # before any field of a recognized older schema is interpreted.
  if ! afk_manifest_shape_is_valid "$AFK_MANIFEST"; then
    AFK_MANIFEST_REASON="STATE_MANIFEST_SHAPE_INVALID"
    return 0
  fi
  if (( major < AFK_SUPPORTED_STATE_SCHEMA_MAJOR )); then
    AFK_MANIFEST_REASON="STATE_SCHEMA_MIGRATION_REQUIRED"
  fi
  AFK_APPLIED_REVISION="$(printf '%s' "$j" | jq -r '.applied_revision')"
  AFK_MANIFEST_REPO_IDENTITY="$(printf '%s' "$j" | jq -r '.repository.identity')"
  AFK_MANIFEST_USABLE="true"
  AFK_ADOPTED="true"
  return 0
}

afk_emit_manifest_findings() {
  if [[ "$AFK_ADOPTED" == "true" ]]; then
    if [[ -n "$AFK_MANIFEST_REASON" ]]; then
      afk_add_finding "state-manifest" "KIT_STATE" "MIGRATION_REQUIRED" "$AFK_MANIFEST_REASON" \
        "warning" "MUTATION_SOURCE" "MANIFEST_SCHEMA" \
        "$AFK_SUPPORTED_STATE_SCHEMA_MAJOR.x" "$AFK_STATE_SCHEMA_VERSION" "false" "false" ""
    fi
    return 0
  fi
  if [[ "$AFK_MANIFEST_PRESENT" != "true" ]]; then
    afk_add_finding "state-manifest" "KIT_STATE" "UNKNOWN" "INSTALLATION_NOT_ADOPTED" \
      "blocking" "INSTALLED_INTEGRITY,HOST_EXECUTION_READY" "FILE_STRUCTURE" \
      "$AFK_MANIFEST" "absent" "false" "false" ""
    return 0
  fi
  # Present but unusable: an unrecognized shape, a newer major, or a redirected
  # path is an owner decision, never a guess (FR-33).
  local provenance="MANIFEST_SCHEMA"
  if [[ "$AFK_MANIFEST_REASON" == "STATE_MANIFEST_PATH_UNSAFE" ]]; then
    provenance="PATH_STRUCTURE"
  fi
  afk_add_finding "state-manifest" "KIT_STATE" "INCOMPATIBLE" "$AFK_MANIFEST_REASON" \
    "owner_action" "INSTALLED_INTEGRITY,HOST_EXECUTION_READY,MUTATION_SOURCE" "$provenance" \
    "$AFK_SUPPORTED_STATE_SCHEMA_MAJOR.x" "${AFK_STATE_SCHEMA_VERSION:-unparseable}" "false" "false" ""
}

# The manifest is parsed ONCE into a component -> identity map (AD-20), keyed
# by the exact manifest text it was built from: any reassignment of
# AFK_MANIFEST_JSON rebuilds it, and the lock and every manifest write drop it
# explicitly. The map holds only what the per-call lookup below would answer.
# A manifest the lookup would ERROR on (a non-object where an object is
# indexed), one holding a NUL, or text that is not exactly one JSON document
# is never mapped: those keep the per-call jq,
# so its stderr and empty answer are exactly what they always were.
AFK_MANIFEST_MAP_SRC="" AFK_MANIFEST_MAP_STATE="none"
AFK_MANIFEST_MAP_KEYS=() AFK_MANIFEST_MAP_VALS=()
afk_manifest_map_invalidate() { AFK_MANIFEST_MAP_STATE="none"; AFK_MANIFEST_MAP_SRC=""; }

afk_manifest_map_build() {
  local code
  AFK_MANIFEST_MAP_KEYS=(); AFK_MANIFEST_MAP_VALS=()
  AFK_MANIFEST_MAP_SRC="$AFK_MANIFEST_JSON"; AFK_MANIFEST_MAP_STATE="unmapped"
  # Slurped, and mapped only when the text is exactly ONE document: the
  # per-call jq answers once per document, so anything else keeps it.
  code="$(printf '%s' "$AFK_MANIFEST_JSON" | jq -rs '
    if length != 1 then empty else .[0] end
    | .components as $c
    | if ($c | type) == "null" then "AFK_MANIFEST_MAP_KEYS=()", "AFK_MANIFEST_MAP_VALS=()"
      elif (($c | type) == "object") and all($c[]; type == "object" or type == "null")
         and ([$c | keys_unsorted[], (.[] | .identity? | strings)] | all(index("\u0000") == null))
      then "AFK_MANIFEST_MAP_KEYS=(" + ([$c | keys_unsorted[] | @sh] | join(" ")) + ")",
           "AFK_MANIFEST_MAP_VALS=(" + ([$c[] | if (.identity | type) == "string" then .identity else "" end | @sh] | join(" ")) + ")"
      else empty end' 2>/dev/null)" || return 0
  [[ -n "$code" ]] || return 0
  # @sh output is single-quoted words only; it is evaluated as two array
  # assignments, never as a command.
  eval "$code" || { AFK_MANIFEST_MAP_KEYS=(); AFK_MANIFEST_MAP_VALS=(); return 0; }
  (( ${#AFK_MANIFEST_MAP_KEYS[@]} == ${#AFK_MANIFEST_MAP_VALS[@]} )) && AFK_MANIFEST_MAP_STATE="mapped"
}

# afk_manifest_component_identity_v <var> <id> — the recorded identity, or "".
# Call it in the evaluating shell (not inside $(…)) so the map outlives it.
afk_manifest_component_identity_v() {
  local _mi _mv=""
  if [[ "$AFK_MANIFEST_MAP_STATE" == "none" || "$AFK_MANIFEST_MAP_SRC" != "$AFK_MANIFEST_JSON" ]]; then
    afk_manifest_map_build
  fi
  if [[ "$AFK_MANIFEST_MAP_STATE" != "mapped" ]]; then
    _mv="$(printf '%s' "$AFK_MANIFEST_JSON" | jq -r --arg id "$2" \
      'if (.components[$id].identity | type) == "string" then .components[$id].identity else "" end')"
  else
    for (( _mi = 0; _mi < ${#AFK_MANIFEST_MAP_KEYS[@]}; _mi++ )); do
      [[ "${AFK_MANIFEST_MAP_KEYS[_mi]}" == "$2" ]] || continue
      _mv="${AFK_MANIFEST_MAP_VALS[_mi]}"
      while [[ "$_mv" == *$'\n' ]]; do _mv="${_mv%$'\n'}"; done   # as $(jq -r …) strips
      break
    done
  fi
  printf -v "$1" '%s' "$_mv"
}

afk_manifest_component_identity() { # <id>
  local v
  if [[ "$AFK_MANIFEST_MAP_STATE" == "none" || "$AFK_MANIFEST_MAP_SRC" != "$AFK_MANIFEST_JSON" ]]; then
    afk_manifest_map_build
  fi
  if [[ "$AFK_MANIFEST_MAP_STATE" != "mapped" ]]; then
    # Unmapped: the per-call jq prints (and exits) exactly as it always did.
    printf '%s' "$AFK_MANIFEST_JSON" | jq -r --arg id "$1" \
      'if (.components[$id].identity | type) == "string" then .components[$id].identity else "" end'
    return
  fi
  local i
  v=""   # the raw value, trailing newlines included, as `jq -r` prints it
  for (( i = 0; i < ${#AFK_MANIFEST_MAP_KEYS[@]}; i++ )); do
    [[ "${AFK_MANIFEST_MAP_KEYS[i]}" == "$1" ]] && { v="${AFK_MANIFEST_MAP_VALS[i]}"; break; }
  done
  printf '%s\n' "$v"
}

# --- the operation journal (FR-92: an in-progress installation is not healthy)

AFK_JOURNAL_STATE="NONE"

afk_evaluate_journal() {
  AFK_JOURNAL_STATE="NONE"
  [[ -n "$AFK_JOURNAL" ]] || return 0
  if [[ ! -e "$AFK_JOURNAL" && ! -L "$AFK_JOURNAL" ]]; then return 0; fi

  local boundary guard st
  boundary="$(afk_state_boundary "$AFK_JOURNAL")"
  afk_path_guard_v guard "$AFK_JOURNAL" file "$boundary" "$boundary"
  if [[ "$guard" != "PATH_OK" ]]; then
    # A journal that is a directory, a symlink out of the state directory, or
    # any other unexpected type is not "no journal": it is a journal whose
    # content cannot be trusted, so the installation is not provably settled.
    AFK_JOURNAL_STATE="UNSAFE"
    afk_add_finding "operation-journal" "KIT_STATE" "BROKEN" "OPERATION_JOURNAL_PATH_UNSAFE" \
      "owner_action" "INSTALLED_INTEGRITY,MUTATION_SOURCE" "PATH_STRUCTURE" \
      "regular file inside the declared state directory" "$guard" "false" "false" ""
    return 0
  fi

  st="$(jq -r 'if (.state | type) == "string" then .state else "" end' "$AFK_JOURNAL" 2>/dev/null)"
  if [[ -z "$st" ]]; then
    AFK_JOURNAL_STATE="UNREADABLE"
    afk_add_finding "operation-journal" "KIT_STATE" "INTERRUPTED" "OPERATION_JOURNAL_UNREADABLE" \
      "owner_action" "INSTALLED_INTEGRITY,MUTATION_SOURCE" "OPERATION_JOURNAL" \
      "COMMITTED" "unreadable" "false" "false" ""
    return 0
  fi
  if [[ "$st" == "COMMITTED" ]]; then
    AFK_JOURNAL_STATE="COMMITTED"
    return 0
  fi
  AFK_JOURNAL_STATE="OPEN"
  afk_add_finding "operation-journal" "KIT_STATE" "INTERRUPTED" "OPERATION_INTERRUPTED" \
    "owner_action" "INSTALLED_INTEGRITY,MUTATION_SOURCE" "OPERATION_JOURNAL" \
    "COMMITTED" "$st" "false" "false" ""
}

# --- registered adaptations (FR-8, FR-94) -----------------------------------
#
# A record can only legitimize a difference when it is bound tightly enough to
# be falsifiable: a unique id, a component this lifecycle declares, the type
# that component's ownership class can actually have, that component's declared
# location, an expected identity in the right shape, and a supported update
# disposition. Anything looser legitimizes whatever happens to be there.

AFK_ADAPT_RECORDS=""

afk_adaptation_expected_type() { # <ownership>
  case "$1" in
    MANAGED_COPY_TREE) printf 'tree-content' ;;
    MANAGED_COPY_FILE) printf 'file-content' ;;
    MANAGED_SECTION)   printf 'section-payload' ;;
    MANAGED_LINK)      printf 'link-target' ;;
    *)                 printf '' ;;
  esac
}

afk_adaptation_types() {
  printf 'tree-content\nfile-content\nsection-payload\nlink-target\n'
}

afk_adaptation_declared_location() { # <ownership> <dest> <extra>
  if [[ "$1" == "MANAGED_SECTION" ]]; then
    printf '%s#%s' "$2" "$3"
  else
    printf '%s' "$2"
  fi
}

afk_identity_shape_ok() { # <type> <identity>
  case "$1" in
    link-target) [[ "$2" == link:/* ]] ;;
    *)           [[ "$2" =~ ^sha256:[0-9a-f]{64}$ ]] ;;
  esac
}

afk_validate_adaptations() {
  AFK_ADAPT_RECORDS=""
  local n i rec id comp loc typ why expected disp valid reason
  local seen_ids="" dup_ids=""
  local row ownership dest extra want_type want_loc

  n="$(printf '%s' "$AFK_MANIFEST_JSON" | jq -r '(.adaptations // []) | length')"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac

  # A duplicated id invalidates EVERY record carrying it, not merely the second
  # one: an id that names two exceptions names neither. The defect belongs to
  # the id, so it is reported once and each record is reported INVALID.
  dup_ids="$(printf '%s' "$AFK_MANIFEST_JSON" | jq -r '
    [(.adaptations // [])[] | select(type == "object")
     | select((.id | type) == "string") | .id]
    | group_by(.) | map(select(length > 1)) | map(.[0]) | .[]' 2>/dev/null)" || dup_ids=""

  for (( i = 0; i < n; i++ )); do
    rec="$(printf '%s' "$AFK_MANIFEST_JSON" | jq -c ".adaptations[$i]")"
    id="$(printf '%s' "$rec" | jq -r 'if (.id | type) == "string" then .id else "" end')"
    comp="$(printf '%s' "$rec" | jq -r 'if (.component | type) == "string" then .component else "" end')"
    loc="$(printf '%s' "$rec" | jq -r 'if (.location | type) == "string" then .location else "" end')"
    typ="$(printf '%s' "$rec" | jq -r 'if (.type | type) == "string" then .type else "" end')"
    why="$(printf '%s' "$rec" | jq -r 'if (.reason | type) == "string" then .reason else "" end')"
    expected="$(printf '%s' "$rec" | jq -r 'if (.expected_identity | type) == "string" then .expected_identity else "" end')"
    disp="$(printf '%s' "$rec" | jq -r 'if (.disposition | type) == "string" then .disposition else "" end')"
    valid="true"; reason=""

    if [[ -z "$id" || -z "$comp" || -z "$loc" || -z "$typ" || -z "$why" \
          || -z "$expected" || -z "$disp" ]]; then
      valid="false"; reason="ADAPTATION_MALFORMED"
    elif afk_id_in_list "$id" "$dup_ids"; then
      valid="false"; reason="ADAPTATION_DUPLICATE_ID"
    elif ! row="$(afk_component_row "$comp")"; then
      valid="false"; reason="ADAPTATION_UNKNOWN_COMPONENT"
    else
      ownership="$(printf '%s' "$row" | cut -d'|' -f2)"
      dest="$(printf '%s' "$row" | cut -d'|' -f6)"
      extra="$(printf '%s' "$row" | cut -d'|' -f7)"
      want_type="$(afk_adaptation_expected_type "$ownership")"
      want_loc="$(afk_adaptation_declared_location "$ownership" "$dest" "$extra")"
      case "$disp" in
        PRESERVE|REEVALUATE|OWNER_REVIEW) : ;;
        *) valid="false"; reason="ADAPTATION_INVALID_DISPOSITION" ;;
      esac
      if [[ "$valid" == "true" ]]; then
        if [[ -z "$want_type" || "$typ" != "$want_type" ]]; then
          valid="false"; reason="ADAPTATION_TYPE_MISMATCH"
        elif [[ "$loc" != "$want_loc" ]]; then
          valid="false"; reason="ADAPTATION_LOCATION_MISMATCH"
        elif ! afk_identity_shape_ok "$typ" "$expected"; then
          valid="false"; reason="ADAPTATION_EXPECTED_SHAPE_INVALID"
        fi
      fi
    fi

    AFK_ADAPT_RECORDS="${AFK_ADAPT_RECORDS}$(jq -nc \
      --arg id "$id" --arg component "$comp" --arg location "$loc" --arg type "$typ" \
      --arg reason "$why" --arg expected "$expected" --arg disposition "$disp" \
      --argjson valid "$valid" --arg vreason "$reason" \
      '{id: $id, component: $component, location: $location, type: $type,
        reason: $reason, expected_identity: $expected, disposition: $disposition,
        valid: $valid, validation_reason: (if $vreason == "" then null else $vreason end)}')"$'\n'

    if [[ "$valid" != "true" ]]; then
      afk_add_adaptation "$(jq -nc --arg id "$id" --arg component "$comp" \
        --arg disposition "$disp" --arg reason "$reason" \
        '{id: (if $id == "" then "<unnamed>" else $id end), component: $component,
          disposition: $disposition, state: "INVALID", validation_reason: $reason,
          evidence: {provenance: "MANIFEST_SCHEMA", expected: null, observed: null}}')"
      # One finding per duplicated id rather than one per record: every record
      # carrying it is already reported INVALID above.
      if [[ "$reason" != "ADAPTATION_DUPLICATE_ID" ]] || ! afk_id_in_list "$id" "$seen_ids"; then
        afk_add_finding "${comp:-adaptation}" "REGISTERED_ADAPTATION" "INCOMPATIBLE" "$reason" \
          "owner_action" "MUTATION_SOURCE" "MANIFEST_SCHEMA" "" "${id:-<unnamed>}" "false" "false" ""
      fi
    fi
    if [[ -n "$id" ]]; then seen_ids="${seen_ids}${id}"$'\n'; fi
  done
}

# afk_adaptation_match <component> <observed-identity> -> adaptation id
afk_adaptation_match() {
  local comp="$1" obs="$2" line got
  [[ -n "$obs" ]] || return 1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    got="$(printf '%s' "$line" | jq -r --arg c "$comp" --arg o "$obs" \
      'if (.valid and .component == $c and .expected_identity == $o) then .id else "" end')"
    if [[ -n "$got" ]]; then
      printf '%s\n' "$got"
      return 0
    fi
  done <<< "$AFK_ADAPT_RECORDS"
  return 1
}

afk_adaptation_disposition() { # <adaptation id>
  local line got
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    got="$(printf '%s' "$line" | jq -r --arg i "$1" 'if (.valid and .id == $i) then .disposition else "" end')"
    if [[ -n "$got" ]]; then printf '%s\n' "$got"; return 0; fi
  done <<< "$AFK_ADAPT_RECORDS"
  return 1
}

# Emit the final adaptation records for one component, revalidated against what
# was actually observed. A record whose declared shape no longer matches is
# STALE and legitimizes nothing (FR-94).
afk_emit_adaptations_for() { # <component> <observed-identity>
  local comp="$1" obs="$2" line keep rid rexp rdisp state
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    keep="$(printf '%s' "$line" | jq -r --arg c "$comp" \
      'if (.valid and .component == $c) then "y" else "" end')"
    [[ "$keep" == "y" ]] || continue
    rid="$(printf '%s' "$line" | jq -r '.id')"
    rexp="$(printf '%s' "$line" | jq -r '.expected_identity')"
    rdisp="$(printf '%s' "$line" | jq -r '.disposition')"
    if [[ -z "$obs" ]]; then
      state="STALE"
      afk_add_finding "$comp" "REGISTERED_ADAPTATION" "INCOMPATIBLE" "ADAPTATION_TARGET_UNOBSERVABLE" \
        "owner_action" "MUTATION_SOURCE" "HASH_COMPARISON" "$rexp" "unobservable" "false" "false" "$rid"
    elif [[ "$rexp" == "$obs" ]]; then
      state="VALID_MATCHED"
    else
      state="STALE"
      afk_add_finding "$comp" "REGISTERED_ADAPTATION" "INCOMPATIBLE" "ADAPTATION_STALE" \
        "owner_action" "MUTATION_SOURCE" "HASH_COMPARISON" "$rexp" "$obs" "false" "false" "$rid"
    fi
    afk_add_adaptation "$(jq -nc --arg id "$rid" --arg component "$comp" \
      --arg disposition "$rdisp" --arg expected "$rexp" --arg observed "$obs" --arg state "$state" \
      '{id: $id, component: $component, disposition: $disposition, state: $state,
        validation_reason: null,
        evidence: {provenance: "HASH_COMPARISON", expected: $expected,
                   observed: (if $observed == "" then null else $observed end)}}')"
  done <<< "$AFK_ADAPT_RECORDS"
  return 0
}

# --- component classification -----------------------------------------------

afk_component_scopes() { # <critical> <id>
  if [[ "$1" == "true" ]]; then
    printf 'INSTALLED_INTEGRITY,HOST_EXECUTION_READY,MUTATION:%s' "$2"
  else
    printf 'MUTATION:%s' "$2"
  fi
}

afk_component_fail() { # <critical> <id> <state> <reason> <provenance> [expected] [detail]
  C_STATE="$3"; C_REASON="$4"; C_PROVENANCE="$5"
  C_EXPECTED="${6:-}"; C_DETAIL="${7:-}"
  C_MUTATION_SAFE="false"
  C_SCOPES="$(afk_component_scopes "$1" "$2")"
  if [[ "$1" == "true" ]]; then C_SEVERITY="blocking"; else C_SEVERITY="warning"; fi
}

# afk_evaluate_components [report-point]
#
# Classifies the observation ledger (afk-plan.sh, AD-19). Without an argument
# it fills the ledger with one fresh pass (O1), which afk_plan_compute then
# binds rather than observing again. With a point (O4 after a committed
# operation, O2 after a plan went stale at revalidation), it reports from the
# ledger that point left, which describes the filesystem as it now is; any
# other ledger is never reused, and a fresh "report" pass is taken instead.
# The applied identity and the adaptation match are always read from the
# manifest and records loaded now, never from the ledger.
afk_evaluate_components() {
  local id ownership skind srel dkind dpath extra critical container target_root
  local guard rc observed canonical applied adapt_id disp escape point="O1"

  if [[ -n "${1:-}" ]]; then
    point="report"
    [[ "$AFK_OBL_STATE" == "complete" && "$AFK_OBL_POINT" == "$1" ]] && point=""
  fi
  if [[ -n "$point" ]]; then
    afk_observation_pass "$point" || return 0
  fi

  while IFS='|' read -r id ownership skind srel dkind dpath extra critical container target_root; do
    [[ -n "$id" ]] || continue
    afk_c_reset
    C_ID="$id"; C_OWNERSHIP="$ownership"; C_DEST="$dpath"; C_CRITICAL="$critical"
    observed=""; canonical=""; applied=""; adapt_id=""

    # --- path type, containment, symlink boundary: fail closed BEFORE reading
    if ! afk_observation_restore "$id"; then
      afk_component_fail "$critical" "$id" "BROKEN" "IDENTITY_UNREADABLE" "HASH_COMPARISON"
      afk_c_emit
      continue
    fi
    guard="$AFK_OB_GUARD"
    if [[ "$guard" != "PATH_OK" ]]; then
      if [[ "$guard" == "PATH_ABSENT" ]]; then
        afk_manifest_component_identity_v applied "$id"
        if [[ "$AFK_ADOPTED" == "true" && -n "$applied" ]]; then
          afk_component_fail "$critical" "$id" "BROKEN" "COMPONENT_MISSING" "PATH_STRUCTURE" "$applied"
        else
          C_STATE="UNKNOWN"; C_REASON="PATH_ABSENT"; C_SEVERITY="info"
          C_PROVENANCE="PATH_STRUCTURE"
        fi
      else
        afk_component_fail "$critical" "$id" "BROKEN" "$guard" "PATH_STRUCTURE"
      fi
      afk_c_emit
      afk_emit_adaptations_for "$id" ""
      continue
    fi

    # --- bounded identity of destination and canonical source ---------------
    observed="$AFK_OB_OBSERVED"; canonical="$AFK_OB_CANONICAL"
    case "$ownership" in
      MANAGED_COPY_TREE)
        escape="$AFK_OB_ESCAPE"
        if [[ -n "$escape" ]]; then
          afk_component_fail "$critical" "$id" "BROKEN" "PATH_ESCAPES_OWNERSHIP_BOUNDARY" \
            "PATH_STRUCTURE" "" "$escape"
          afk_c_emit
          afk_emit_adaptations_for "$id" ""
          continue
        fi
        ;;
      MANAGED_COPY_FILE) : ;;
      MANAGED_SECTION)
        rc="$AFK_OB_SECTION_RC"
        if (( rc == 3 )); then
          afk_component_fail "$critical" "$id" "BROKEN" "MANAGED_SECTION_MARKERS_MALFORMED" "FILE_STRUCTURE"
          afk_c_emit
          afk_emit_adaptations_for "$id" ""
          continue
        fi
        if (( rc == 2 )); then
          afk_manifest_component_identity_v applied "$id"
          if [[ "$AFK_ADOPTED" == "true" && -n "$applied" ]]; then
            afk_component_fail "$critical" "$id" "BROKEN" "MANAGED_SECTION_ABSENT" "FILE_STRUCTURE" "$applied"
          else
            C_STATE="UNKNOWN"; C_REASON="MANAGED_SECTION_ABSENT"; C_SEVERITY="info"
            C_PROVENANCE="FILE_STRUCTURE"
          fi
          afk_c_emit
          afk_emit_adaptations_for "$id" ""
          afk_emit_user_owned_region "$id" "$dpath" "$extra"
          continue
        fi
        ;;
      MANAGED_LINK)
        if [[ "$AFK_OB_LINK_MISSING" == "true" ]]; then
          afk_component_fail "$critical" "$id" "BROKEN" "LINK_TARGET_MISSING" "PATH_STRUCTURE"
          afk_c_emit
          afk_emit_adaptations_for "$id" ""
          continue
        fi
        C_PROVENANCE="PATH_STRUCTURE"
        ;;
      MACHINE_LOCAL) canonical="" ;;
    esac

    C_OBSERVED="$observed"
    if [[ -z "$observed" ]]; then
      afk_component_fail "$critical" "$id" "BROKEN" "IDENTITY_UNREADABLE" "$C_PROVENANCE"
      afk_c_emit
      afk_emit_adaptations_for "$id" ""
      continue
    fi

    # --- classification -----------------------------------------------------
    if [[ "$ownership" == "MACHINE_LOCAL" ]]; then
      # Declared machine-owned: local values are legitimate by ownership rule
      # and never require a per-value approval (FR-7).
      C_STATE="LOCAL_ADAPTATION"; C_REASON="MACHINE_OWNED_REGION"
      C_PROVENANCE="OWNERSHIP_RULE"; C_SEVERITY="info"
    elif [[ "$AFK_ADOPTED" != "true" ]]; then
      # Nothing is owned yet, so nothing can be drift. The canonical identity
      # is still reported as adoption evidence.
      C_STATE="UNKNOWN"; C_REASON="NOT_ADOPTED"; C_SEVERITY="info"
      C_EXPECTED="$canonical"
    else
      afk_manifest_component_identity_v applied "$id"
      C_EXPECTED="$applied"
      if [[ -z "$applied" ]]; then
        C_STATE="UNKNOWN"; C_REASON="COMPONENT_NOT_RECORDED"; C_MUTATION_SAFE="false"
        C_SEVERITY="warning"; C_SCOPES="MUTATION:$id"
      elif [[ "$observed" == "$applied" ]]; then
        if [[ -z "$canonical" ]]; then
          # Matching the applied identity proves nothing about currency when
          # the canonical side could not be read at all. CURRENT would be a
          # claim about content nobody could open.
          C_STATE="UNKNOWN"; C_REASON="CANONICAL_IDENTITY_UNREADABLE"
          C_SEVERITY="warning"; C_MUTATION_SAFE="false"; C_SCOPES="MUTATION:$id"
          C_DETAIL="canonical source: $AFK_KIT_ROOT/${srel:-<none declared>}"
        elif [[ "$canonical" == "$applied" ]]; then
          C_STATE="CURRENT"; C_SEVERITY="info"
        else
          C_STATE="UPDATE_AVAILABLE"; C_REASON="CANONICAL_REVISION_AHEAD"
          C_SEVERITY="warning"; C_DETAIL="canonical=$canonical"
        fi
      else
        adapt_id="$(afk_adaptation_match "$id" "$observed")"
        if [[ -n "$adapt_id" ]]; then
          disp="$(afk_adaptation_disposition "$adapt_id")"
          [[ -n "$disp" ]] || disp="PRESERVE"
          C_STATE="LOCAL_ADAPTATION"; C_REASON="REGISTERED_ADAPTATION"
          C_ADAPTATION="$adapt_id"; C_PROVENANCE="ADAPTATION_RECORD"
          if [[ "$disp" == "OWNER_REVIEW" ]]; then
            C_SEVERITY="warning"; C_MUTATION_SAFE="false"; C_SCOPES="MUTATION:$id"
            C_REASON="ADAPTATION_OWNER_REVIEW"
          else
            C_SEVERITY="info"
          fi
        else
          # Kit-owned territory, no ownership rule and no valid adaptation.
          C_STATE="LOCAL_DRIFT"; C_MUTATION_SAFE="false"
          if [[ "$ownership" == "MANAGED_LINK" ]]; then
            C_REASON="LINK_TARGET_UNEXPECTED"
          else
            C_REASON="UNEXPLAINED_MANAGED_DIFFERENCE"
          fi
          C_SCOPES="$(afk_component_scopes "$critical" "$id")"
          if [[ "$critical" == "true" ]]; then C_SEVERITY="owner_action"; else C_SEVERITY="warning"; fi
        fi
      fi
    fi

    afk_c_emit
    afk_emit_adaptations_for "$id" "$observed"
    if [[ "$ownership" == "MANAGED_SECTION" ]]; then
      afk_emit_user_owned_region "$id" "$dpath" "$extra"
    fi
  done < <(afk_component_table)
}

# Content outside a managed section stays user-owned: it is inventoried by
# shape only (a line count), never by content, and it is never kit drift.
afk_emit_user_owned_region() { # <component-id> <file> <section-id>
  local file="$2" section="$3" total bounds bl el outside
  [[ -f "$file" ]] || return 0
  total="$(wc -l < "$file" | tr -d ' ')"
  case "$total" in ''|*[!0-9]*) total=0 ;; esac
  outside="$total"
  if bounds="$(afk_section_bounds "$file" "$section")"; then
    bl="${bounds%% *}"
    el="${bounds##* }"
    outside=$(( total - (el - bl + 1) ))
    if (( outside < 0 )); then outside=0; fi
  fi
  afk_c_reset
  C_ID="$1:outside-section"
  C_OWNERSHIP="USER_OWNED"
  C_DEST="$file"
  C_STATE="EXTERNAL_STATE"
  C_REASON="USER_OWNED_REGION"
  C_SEVERITY="info"
  C_PROVENANCE="FILE_STRUCTURE"
  C_OBSERVED="$outside lines outside the managed section"
  C_MUTATION_SAFE="true"
  afk_c_emit
}

# --- installed-state summary ------------------------------------------------

afk_installed_state() {
  if [[ "$AFK_ADOPTED" != "true" ]]; then
    if [[ "$AFK_MANIFEST_PRESENT" == "true" ]]; then printf 'INCOMPATIBLE\n'; else printf 'UNKNOWN\n'; fi
    return 0
  fi
  case "$AFK_JOURNAL_STATE" in
    OPEN|UNREADABLE|UNSAFE) printf 'INTERRUPTED\n'; return 0 ;;
    *) : ;;
  esac
  printf '%s' "$AFK_COMPONENTS" | jq -sr '
    if   ([.[] | select(.state == "BROKEN" and .execution_critical)] | length) > 0 then "BROKEN"
    elif ([.[] | select(.state == "LOCAL_DRIFT")] | length) > 0 then "LOCAL_DRIFT"
    elif ([.[] | select(.state == "BROKEN")] | length) > 0 then "BROKEN"
    elif ([.[] | select(.state == "UPDATE_AVAILABLE")] | length) > 0 then "UPDATE_AVAILABLE"
    elif ([.[] | select(.state == "LOCAL_ADAPTATION" and .reason == "REGISTERED_ADAPTATION")] | length) > 0 then "LOCAL_ADAPTATION"
    elif ([.[] | select(.state == "UNKNOWN")] | length) > 0 then "UNKNOWN"
    else "CURRENT" end'
}

afk_installed_json() { # <installed-state>
  jq -nc \
    --arg state "$1" \
    --argjson adopted "$AFK_ADOPTED" \
    --arg applied "$AFK_APPLIED_REVISION" \
    --arg schema "$AFK_STATE_SCHEMA_VERSION" \
    --arg manifest "$AFK_MANIFEST" \
    --arg journal "$AFK_JOURNAL_STATE" \
    --arg identity "$AFK_MANIFEST_REPO_IDENTITY" \
    --arg reason "$AFK_MANIFEST_REASON" \
    '{state: $state,
      adopted: $adopted,
      applied_revision: (if $applied == "" then null else $applied end),
      state_schema_version: (if $schema == "" then null else $schema end),
      manifest_path: $manifest,
      manifest_reason: (if $reason == "" then null else $reason end),
      repository_identity: (if $identity == "" then null else $identity end),
      journal_state: $journal}'
}
