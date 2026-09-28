#!/usr/bin/env bash
# afk-plan.sh — the complete deterministic mutation plan.
#
# This file is SOURCED, never executed, and it WRITES NOTHING. Computing a plan
# is a read-only act by construction: every function here observes, compares
# declared ownership rules and bounded identifiers, and returns a decision. The
# first managed write happens in afk-mutate.sh, and only ever from a plan that
# was computed here and revalidated immediately beforehand.
#
# Three things this file exists to keep apart:
#
#   the PLAN     — what would be done to every declared component, complete
#                  before the first write (FR-23, FR-40).
#   the BINDING  — the exact inputs the plan was computed from: source
#                  revision, canonical identities, destination observations,
#                  manifest state, adaptation records (FR-91).
#   the IDENTITY — a stable digest over both. An approval authorizes exactly
#                  one identity, so any change to any bound input produces a
#                  different plan that the old approval does not cover.
#
# The declared component inventory (afk-inventory.sh) is a DEPENDENCY of this
# file, not an optional companion: without it there is nothing to enumerate, and
# a binding computed over nothing would be a plan bound to nothing. That case is
# a failure here, never an empty binding — see afk_plan_binding_compute.
#
# shellcheck disable=SC2034,SC2154
# The AFK_OB_* observation outputs and the AFK_PLAN_* accumulators are written
# here and read by afk-mutate.sh and afk-commands.sh; the lifecycle files are
# always sourced together, and `set -u` in the entry point is the real guard.

if [[ -n "${AFK_PLAN_SOURCED:-}" ]]; then
  return 0
fi
AFK_PLAN_SOURCED=1

AFK_PLAN_SCHEMA_VERSION="1.0"

# --- plan accumulators ------------------------------------------------------

AFK_PLAN_ENTRIES=""          # ndjson, one object per declared component
AFK_PLAN_BINDING_ENTRIES=""  # ndjson, one object per declared component
AFK_PLAN_JSON="{}"
AFK_PLAN_BINDING="{}"
AFK_PLAN_IDENTITY=""
AFK_PLAN_DISPOSITION="NO_CHANGE"   # NO_CHANGE | MUTATION_REQUIRED | APPROVAL_REQUIRED | REFUSED
AFK_PLAN_MUTATIONS=0
AFK_PLAN_APPROVALS=0
AFK_PLAN_CONFLICTS=0
AFK_PLAN_COMMAND=""
AFK_PLAN_GLOBAL_REFUSAL=""

afk_plan_actions() {
  printf 'NONE\nINSTALL\nREPLACE\nPRESERVE\nCLAIM\nBLOCKED\n'
}

afk_plan_dispositions() {
  printf 'NO_CHANGE\nMUTATION_REQUIRED\nAPPROVAL_REQUIRED\nREFUSED\n'
}

# The strongest applicable disposition wins, and a weaker one can never
# downgrade it: one refused component refuses the plan.
afk_plan_note_disposition() { # <disposition>
  case "$1" in
    REFUSED)
      AFK_PLAN_DISPOSITION="REFUSED" ;;
    APPROVAL_REQUIRED)
      if [[ "$AFK_PLAN_DISPOSITION" != "REFUSED" ]]; then
        AFK_PLAN_DISPOSITION="APPROVAL_REQUIRED"
      fi ;;
    MUTATION_REQUIRED)
      case "$AFK_PLAN_DISPOSITION" in
        REFUSED|APPROVAL_REQUIRED) : ;;
        *) AFK_PLAN_DISPOSITION="MUTATION_REQUIRED" ;;
      esac ;;
    *) : ;;
  esac
}

# --- observation ------------------------------------------------------------
#
# One function observes one component completely: its path guard, its declared
# type, its bounded destination identity, the canonical identity it would be
# converged to, the identity the manifest records, and the registered
# adaptation that explains a difference. Everything downstream branches on
# these values and never re-reads the filesystem for itself, so the plan and
# the binding describe the same observation.

AFK_OB_ID=""
AFK_OB_OWNERSHIP=""
AFK_OB_DEST=""
AFK_OB_SREL=""
AFK_OB_EXTRA=""
AFK_OB_CRITICAL="false"
AFK_OB_WANT=""
AFK_OB_CONTAINER=""
AFK_OB_TARGET_ROOT=""
AFK_OB_GUARD=""
AFK_OB_OBSERVED=""
AFK_OB_CANONICAL=""
AFK_OB_APPLIED=""
AFK_OB_ADAPT=""
AFK_OB_DISPOSITION=""
AFK_OB_ESCAPE=""
AFK_OB_SECTION_RC=0

# One filesystem pass, two consumers (FR-91).
#
# The binding and the plan are two projections of the SAME observation. When
# each computed its own, a change landing between the two passes produced a
# plan whose expected_destination_identity disagreed with the binding's
# observed_identity for that component — and since the journal records the
# binding as pre-mutation evidence while the pre-write guard compares against
# the plan, the two halves of the safety argument would describe different
# moments. Revalidation could not see it either: it compares binding to
# binding. So the observation is captured once, cached, and replayed.

AFK_OB_CACHE=""   # ndjson, one complete observation record per component

afk_observation_capture() {
  AFK_OB_CACHE="${AFK_OB_CACHE}$(jq -nc \
    --arg id "$AFK_OB_ID" --arg ownership "$AFK_OB_OWNERSHIP" --arg dest "$AFK_OB_DEST" \
    --arg srel "$AFK_OB_SREL" --arg extra "$AFK_OB_EXTRA" --arg critical "$AFK_OB_CRITICAL" \
    --arg want "$AFK_OB_WANT" --arg container "$AFK_OB_CONTAINER" \
    --arg target_root "$AFK_OB_TARGET_ROOT" --arg guard "$AFK_OB_GUARD" \
    --arg observed "$AFK_OB_OBSERVED" --arg canonical "$AFK_OB_CANONICAL" \
    --arg applied "$AFK_OB_APPLIED" --arg adapt "$AFK_OB_ADAPT" \
    --arg disposition "$AFK_OB_DISPOSITION" --arg escape "$AFK_OB_ESCAPE" \
    --arg section_rc "$AFK_OB_SECTION_RC" \
    '{id: $id, ownership: $ownership, dest: $dest, srel: $srel, extra: $extra,
      critical: $critical, want: $want, container: $container,
      target_root: $target_root, guard: $guard, observed: $observed,
      canonical: $canonical, applied: $applied, adapt: $adapt,
      disposition: $disposition, escape: $escape, section_rc: $section_rc}')"$'\n'
}

# Replay a captured observation into the AFK_OB_* globals. Every field is a
# string in the cache, so an empty value round-trips as an empty line rather
# than as the four characters "null".
afk_observation_restore() { # <component-id>
  local rec
  rec="$(printf '%s' "$AFK_OB_CACHE" | jq -c --arg id "$1" 'select(.id == $id)' 2>/dev/null | head -n 1)"
  [[ -n "$rec" ]] || return 1
  {
    IFS= read -r AFK_OB_ID || return 1
    IFS= read -r AFK_OB_OWNERSHIP
    IFS= read -r AFK_OB_DEST
    IFS= read -r AFK_OB_SREL
    IFS= read -r AFK_OB_EXTRA
    IFS= read -r AFK_OB_CRITICAL
    IFS= read -r AFK_OB_WANT
    IFS= read -r AFK_OB_CONTAINER
    IFS= read -r AFK_OB_TARGET_ROOT
    IFS= read -r AFK_OB_GUARD
    IFS= read -r AFK_OB_OBSERVED
    IFS= read -r AFK_OB_CANONICAL
    IFS= read -r AFK_OB_APPLIED
    IFS= read -r AFK_OB_ADAPT
    IFS= read -r AFK_OB_DISPOSITION
    IFS= read -r AFK_OB_ESCAPE
    IFS= read -r AFK_OB_SECTION_RC
  } < <(printf '%s' "$rec" | jq -r '.id, .ownership, .dest, .srel, .extra, .critical,
                                    .want, .container, .target_root, .guard, .observed,
                                    .canonical, .applied, .adapt, .disposition, .escape,
                                    .section_rc')
  [[ "$AFK_OB_ID" == "$1" ]] || return 1
  return 0
}

afk_observe_component() { # <declared row>
  local id ownership skind srel dkind dpath extra critical container target_root
  local resolved rc

  IFS='|' read -r id ownership skind srel dkind dpath extra critical container target_root <<< "$1"

  AFK_OB_ID="$id"; AFK_OB_OWNERSHIP="$ownership"; AFK_OB_DEST="$dpath"
  AFK_OB_SREL="$srel"; AFK_OB_EXTRA="$extra"; AFK_OB_CRITICAL="$critical"
  AFK_OB_CONTAINER="$container"; AFK_OB_TARGET_ROOT="$target_root"
  AFK_OB_GUARD=""; AFK_OB_OBSERVED=""; AFK_OB_CANONICAL=""; AFK_OB_APPLIED=""
  AFK_OB_ADAPT=""; AFK_OB_DISPOSITION=""; AFK_OB_ESCAPE=""; AFK_OB_SECTION_RC=0

  case "$dkind" in
    dir)  AFK_OB_WANT="dir" ;;
    link) AFK_OB_WANT="link" ;;
    *)    AFK_OB_WANT="file" ;;
  esac

  afk_path_guard_v AFK_OB_GUARD "$dpath" "$AFK_OB_WANT" "$target_root" "$container"
  afk_manifest_component_identity_v AFK_OB_APPLIED "$id"

  # The canonical side is read whether or not the destination is safe: a plan
  # has to be able to say "this is what the target would be" even when it also
  # has to say "and this destination cannot be touched".
  case "$ownership" in
    MANAGED_COPY_TREE) AFK_OB_CANONICAL="$(afk_tree_identity "$AFK_KIT_ROOT/$srel" "$extra")" ;;
    MANAGED_COPY_FILE) afk_sha256_file_v AFK_OB_CANONICAL "$AFK_KIT_ROOT/$srel" ;;
    MANAGED_SECTION)   AFK_OB_CANONICAL="$(afk_file_payload_identity "$AFK_KIT_ROOT/$srel")" ;;
    MANAGED_LINK)
      if afk_realpath_v resolved "$extra"; then AFK_OB_CANONICAL="link:$resolved"; fi ;;
    *) AFK_OB_CANONICAL="" ;;
  esac

  if [[ "$AFK_OB_GUARD" != "PATH_OK" ]]; then
    return 0
  fi

  case "$ownership" in
    MANAGED_COPY_TREE)
      AFK_OB_ESCAPE="$(afk_tree_find_escaping_symlink "$dpath")"
      if [[ -z "$AFK_OB_ESCAPE" ]]; then
        AFK_OB_OBSERVED="$(afk_tree_identity "$dpath" "$extra")"
      fi ;;
    MANAGED_COPY_FILE|MACHINE_LOCAL)
      afk_sha256_file_v AFK_OB_OBSERVED "$dpath" ;;
    MANAGED_SECTION)
      AFK_OB_OBSERVED="$(afk_section_identity "$dpath" "$extra")"
      rc=$?
      AFK_OB_SECTION_RC="$rc"
      if (( rc != 0 )); then AFK_OB_OBSERVED=""; fi ;;
    MANAGED_LINK)
      if [[ ! -e "$dpath" ]]; then
        AFK_OB_OBSERVED=""
      elif afk_realpath_v resolved "$dpath"; then
        AFK_OB_OBSERVED="link:$resolved"
      fi ;;
  esac

  if [[ -n "$AFK_OB_OBSERVED" ]]; then
    AFK_OB_ADAPT="$(afk_adaptation_match "$id" "$AFK_OB_OBSERVED")" || AFK_OB_ADAPT=""
    if [[ -n "$AFK_OB_ADAPT" ]]; then
      AFK_OB_DISPOSITION="$(afk_adaptation_disposition "$AFK_OB_ADAPT")" || AFK_OB_DISPOSITION=""
      [[ -n "$AFK_OB_DISPOSITION" ]] || AFK_OB_DISPOSITION="PRESERVE"
    fi
  fi
  return 0
}

# afk_managed_tree_empty <dir> <comma-separated exclusions>
#
# True (0) when <dir> is a real directory that holds no file or symlink outside
# the declared exclusions — an empty scaffold that OWNS NOTHING. It is the exact
# discriminator FR-26 needs: an empty component root is not content a plan could
# be claiming, so it is treated as absent, while a root that CONTAINS even one
# non-excluded file is never mistaken for one this kit may write over. The find
# idiom mirrors afk_tree_identity, so "empty" here means the same thing the
# identity does: a listing with no records. A find that cannot complete fails
# closed (returns non-zero / "not empty"), because an unprovable tree must never
# read as safe to install into.
afk_managed_tree_empty() {
  local root="$1" excl="${2:-}" entry rel
  [[ -d "$root" && ! -L "$root" ]] || return 1
  while IFS= read -r -d '' entry; do
    case "$entry" in
      FINDRC=0) break ;;
      FINDRC=*) return 1 ;;
    esac
    rel="${entry#"$root"/}"
    if [[ "$rel" == "$entry" ]]; then rel="${entry##*/}"; fi
    afk_excluded "$rel" "$excl" && continue
    return 1
  done < <(find "$root" \( -type f -o -type l \) -print0 2>/dev/null
           printf 'FINDRC=%s\0' "$?")
  return 0
}

# --- the binding (FR-91) ----------------------------------------------------
#
# Recomputed identically at plan time and immediately before the first write.
# It is a pure function of observable state, so comparing the two answers the
# only question that matters at the mutation boundary: is this still the same
# installation the plan was computed for?

afk_manifest_state_identity() {
  local id
  if [[ ! -e "$AFK_MANIFEST" && ! -L "$AFK_MANIFEST" ]]; then
    printf 'absent'
    return 0
  fi
  if [[ ! -f "$AFK_MANIFEST" || -L "$AFK_MANIFEST" ]]; then
    printf 'unreadable'
    return 0
  fi
  if id="$(afk_sha256_file "$AFK_MANIFEST")" && [[ -n "$id" ]]; then
    printf '%s' "$id"
  else
    printf 'unreadable'
  fi
}

afk_plan_binding_compute() {
  local rows row entry entries="" adaptations manifest_identity
  local declared=0 bound=0

  AFK_PLAN_BINDING_ENTRIES=""
  AFK_PLAN_BINDING="{}"
  AFK_OB_CACHE=""
  manifest_identity="$(afk_manifest_state_identity)"

  # The declared inventory is materialized ONCE and counted before anything is
  # bound to it. An inventory that could not be read would otherwise produce an
  # EMPTY binding, and an empty binding is the one shape that can never be
  # falsified: it compares equal to itself at the mutation boundary no matter
  # how far the installation moved in between. So an inventory that cannot be
  # enumerated, or a component that cannot be bound, is a failure here — the
  # caller turns that into PLAN_NOT_COMPUTABLE and writes nothing.
  rows="$(afk_component_table)" || return 1
  [[ -n "$rows" ]] || return 1
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    declared=$((declared + 1))
  done <<< "$rows"
  (( declared > 0 )) || return 1

  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    afk_observe_component "$row"
    afk_observation_capture
    # One jq per binding document, not per entry (AD-20); the jq form stays
    # for any value afk_json_record does not take.
    afk_json_record entry component s "$AFK_OB_ID" path_observation s "$AFK_OB_GUARD" \
      observed_identity n "$AFK_OB_OBSERVED" canonical_identity n "$AFK_OB_CANONICAL" \
      applied_identity n "$AFK_OB_APPLIED" containment_escape n "$AFK_OB_ESCAPE" \
      section_status s "$AFK_OB_SECTION_RC" || entry="$(jq -nc \
      --arg component "$AFK_OB_ID" \
      --arg guard "$AFK_OB_GUARD" \
      --arg observed "$AFK_OB_OBSERVED" \
      --arg canonical "$AFK_OB_CANONICAL" \
      --arg applied "$AFK_OB_APPLIED" \
      --arg escape "$AFK_OB_ESCAPE" \
      --arg section_rc "$AFK_OB_SECTION_RC" \
      '{component: $component,
        path_observation: $guard,
        observed_identity: (if $observed == "" then null else $observed end),
        canonical_identity: (if $canonical == "" then null else $canonical end),
        applied_identity: (if $applied == "" then null else $applied end),
        containment_escape: (if $escape == "" then null else $escape end),
        section_status: $section_rc}')" || return 1
    [[ -n "$entry" ]] || return 1
    entries="${entries}${entry}"$'\n'
    bound=$((bound + 1))
  done <<< "$rows"
  (( bound == declared )) || return 1
  AFK_PLAN_BINDING_ENTRIES="$entries"

  # Adaptation records are bound by id, expected identity and disposition:
  # editing a record after a plan was approved must invalidate the approval.
  adaptations="$(printf '%s' "$AFK_ADAPT_RECORDS" \
    | jq -sc 'map({id, component, expected_identity, disposition, valid})' 2>/dev/null)" \
    || adaptations="[]"
  [[ -n "$adaptations" ]] || adaptations="[]"

  AFK_PLAN_BINDING="$(jq -nc \
    --arg revision "$AFK_CO_REVISION" \
    --arg identity "$AFK_CO_REPO_IDENTITY" \
    --arg manifest "$manifest_identity" \
    --arg applied_revision "$AFK_APPLIED_REVISION" \
    --arg journal "$AFK_JOURNAL_STATE" \
    --argjson components "$(afk_ndjson_to_array "$entries")" \
    --argjson adaptations "$adaptations" \
    '{source_revision: (if $revision == "" then null else $revision end),
      repository_identity: (if $identity == "" then null else $identity end),
      manifest_state_identity: $manifest,
      applied_revision: (if $applied_revision == "" then null else $applied_revision end),
      journal_state: $journal,
      components: $components,
      adaptations: $adaptations}')" || return 1
  return 0
}

# --- plan entries -----------------------------------------------------------

afk_plan_entry() { # <action> <reason> <target-identity> <final-state> <requires-approval> <backup-required>
  local action="$1" reason="$2" target="$3" final="$4" approval="$5" backup="$6"

  case "$action" in
    REPLACE|INSTALL|CLAIM) AFK_PLAN_MUTATIONS=$((AFK_PLAN_MUTATIONS + 1)) ;;
    BLOCKED)               AFK_PLAN_CONFLICTS=$((AFK_PLAN_CONFLICTS + 1)) ;;
    *) : ;;
  esac
  if [[ "$approval" == "true" ]]; then AFK_PLAN_APPROVALS=$((AFK_PLAN_APPROVALS + 1)); fi

  AFK_PLAN_ENTRIES="${AFK_PLAN_ENTRIES}$(jq -nc \
    --arg component "$AFK_OB_ID" \
    --arg ownership "$AFK_OB_OWNERSHIP" \
    --arg action "$action" \
    --arg reason "$reason" \
    --arg destination "$AFK_OB_DEST" \
    --arg source "$AFK_OB_SREL" \
    --arg expected_type "$AFK_OB_WANT" \
    --arg container "$AFK_OB_CONTAINER" \
    --arg target_root "$AFK_OB_TARGET_ROOT" \
    --arg extra "$AFK_OB_EXTRA" \
    --arg observed "$AFK_OB_OBSERVED" \
    --arg applied "$AFK_OB_APPLIED" \
    --arg canonical "$AFK_OB_CANONICAL" \
    --arg target "$target" \
    --arg adaptation "$AFK_OB_ADAPT" \
    --arg disposition "$AFK_OB_DISPOSITION" \
    --arg final "$final" \
    --arg critical "$AFK_OB_CRITICAL" \
    --arg approval "$approval" \
    --arg backup "$backup" \
    '{component: $component,
      ownership: $ownership,
      action: $action,
      reason: (if $reason == "" then null else $reason end),
      destination: $destination,
      source: (if $source == "" then null else $source end),
      guard: {expected_type: $expected_type,
              container_root: (if $container == "" then null else $container end),
              target_root: (if $target_root == "" then null else $target_root end),
              declared_extra: (if $extra == "" then null else $extra end)},
      expected_destination_identity: (if $observed == "" then null else $observed end),
      applied_identity: (if $applied == "" then null else $applied end),
      canonical_identity: (if $canonical == "" then null else $canonical end),
      target_identity: (if $target == "" then null else $target end),
      adaptation: (if $adaptation == "" then null else $adaptation end),
      adaptation_disposition: (if $disposition == "" then null else $disposition end),
      execution_critical: ($critical == "true"),
      requires_approval: ($approval == "true"),
      backup_required: ($backup == "true"),
      expected_final_state: $final}')"$'\n'
}

# --- the update plan (FR-26, FR-36, FR-38, FR-39) ---------------------------
#
# Every branch here is a mechanical comparison. There is no merge, no
# heuristic, and no model judgement: content converges because its recognized
# applied state says it may, or the component is BLOCKED and an owner decides.

afk_plan_component_update() {
  local ownership="$AFK_OB_OWNERSHIP"

  if [[ "$ownership" == "MACHINE_LOCAL" ]]; then
    afk_plan_entry PRESERVE MACHINE_OWNED_REGION "" "LOCAL_ADAPTATION" false false
    return 0
  fi

  if [[ "$AFK_OB_GUARD" != "PATH_OK" ]]; then
    if [[ "$AFK_OB_GUARD" == "PATH_ABSENT" ]]; then
      if [[ -n "$AFK_OB_APPLIED" ]]; then
        # Recorded as owned and gone: replacing it would silently reinstall
        # over whatever removed it, which is a decision, not a convergence.
        afk_plan_note_disposition REFUSED
        afk_plan_entry BLOCKED COMPONENT_MISSING "$AFK_OB_CANONICAL" "BROKEN" false false
      elif [[ -z "$AFK_OB_CANONICAL" ]]; then
        afk_plan_note_disposition REFUSED
        afk_plan_entry BLOCKED CANONICAL_IDENTITY_UNREADABLE "" "UNKNOWN" false false
      else
        # Nothing exists and nothing is owned: creating it overwrites nothing.
        afk_plan_note_disposition MUTATION_REQUIRED
        afk_plan_entry INSTALL COMPONENT_NOT_INSTALLED "$AFK_OB_CANONICAL" "CURRENT" false false
      fi
      return 0
    fi
    afk_plan_note_disposition REFUSED
    afk_plan_entry BLOCKED "$AFK_OB_GUARD" "$AFK_OB_CANONICAL" "BROKEN" false false
    return 0
  fi

  if [[ -n "$AFK_OB_ESCAPE" ]]; then
    afk_plan_note_disposition REFUSED
    afk_plan_entry BLOCKED PATH_ESCAPES_OWNERSHIP_BOUNDARY "$AFK_OB_CANONICAL" "BROKEN" false false
    return 0
  fi

  if [[ "$ownership" == "MANAGED_SECTION" ]]; then
    if (( AFK_OB_SECTION_RC == 3 )); then
      afk_plan_note_disposition REFUSED
      afk_plan_entry BLOCKED MANAGED_SECTION_MARKERS_MALFORMED "$AFK_OB_CANONICAL" "BROKEN" false false
      return 0
    fi
    if (( AFK_OB_SECTION_RC == 2 )); then
      if [[ -n "$AFK_OB_APPLIED" ]]; then
        afk_plan_note_disposition REFUSED
        afk_plan_entry BLOCKED MANAGED_SECTION_ABSENT "$AFK_OB_CANONICAL" "BROKEN" false false
      elif [[ -z "$AFK_OB_CANONICAL" ]]; then
        afk_plan_note_disposition REFUSED
        afk_plan_entry BLOCKED CANONICAL_IDENTITY_UNREADABLE "" "UNKNOWN" false false
      else
        # Insertion appends a bounded section; every existing byte is kept.
        afk_plan_note_disposition MUTATION_REQUIRED
        afk_plan_entry INSTALL MANAGED_SECTION_ABSENT "$AFK_OB_CANONICAL" "CURRENT" false true
      fi
      return 0
    fi
  fi

  if [[ -z "$AFK_OB_OBSERVED" ]]; then
    afk_plan_note_disposition REFUSED
    afk_plan_entry BLOCKED IDENTITY_UNREADABLE "$AFK_OB_CANONICAL" "BROKEN" false false
    return 0
  fi
  if [[ -z "$AFK_OB_CANONICAL" ]]; then
    afk_plan_note_disposition REFUSED
    afk_plan_entry BLOCKED CANONICAL_IDENTITY_UNREADABLE "" "UNKNOWN" false false
    return 0
  fi
  if [[ "$AFK_OB_OBSERVED" == "$AFK_OB_CANONICAL" ]]; then
    afk_plan_entry NONE "" "$AFK_OB_CANONICAL" "CURRENT" false false
    return 0
  fi

  # A valid registered adaptation is consulted BEFORE the applied-identity
  # comparison. An explicit exception has to survive the case where the
  # adapted content is also what the manifest last recorded — otherwise an
  # ownership record could quietly overrule the owner's own declaration.
  if [[ -n "$AFK_OB_ADAPT" ]]; then
    case "$AFK_OB_DISPOSITION" in
      PRESERVE)
        afk_plan_entry PRESERVE REGISTERED_ADAPTATION "$AFK_OB_OBSERVED" "LOCAL_ADAPTATION" false false
        return 0 ;;
      REEVALUATE)
        # Declared as "reconsider me when canonical no longer matches". That
        # condition holds right now, and resolving it is the owner's call, not
        # a merge.
        afk_plan_note_disposition REFUSED
        afk_plan_entry BLOCKED ADAPTATION_REEVALUATION_REQUIRED "$AFK_OB_CANONICAL" "LOCAL_ADAPTATION" false false
        return 0 ;;
      OWNER_REVIEW)
        afk_plan_note_disposition REFUSED
        afk_plan_entry BLOCKED ADAPTATION_OWNER_REVIEW "$AFK_OB_CANONICAL" "LOCAL_ADAPTATION" false false
        return 0 ;;
      *)
        afk_plan_note_disposition REFUSED
        afk_plan_entry BLOCKED ADAPTATION_INVALID_DISPOSITION "$AFK_OB_CANONICAL" "LOCAL_ADAPTATION" false false
        return 0 ;;
    esac
  fi

  if [[ -z "$AFK_OB_APPLIED" ]]; then
    # An empty component root owns no content. It is the leftover an earlier
    # operation left when it created a shared parent directory and then aborted
    # (AFK-LC-1, the 2026-09-17 shape): present, unrecorded, holding no file.
    # Owning nothing, it is PATH_ABSENT-equivalent — installing into it
    # overwrites nothing — so it is planned as an INSTALL rather than refused as
    # COMPONENT_NOT_RECORDED, and a single stray directory can no longer block
    # every later plan. The reason names it as not-installed (distinct from a
    # recorded-and-gone COMPONENT_MISSING above), and the guard below still
    # holds: a root that CONTAINS even one non-excluded file is never emptied of
    # meaning here — it falls through to COMPONENT_NOT_RECORDED, exactly as
    # FR-26 requires, because that content is not this kit's to claim.
    if [[ "$ownership" == "MANAGED_COPY_TREE" ]] \
       && afk_managed_tree_empty "$AFK_OB_DEST" "$AFK_OB_EXTRA"; then
      afk_plan_note_disposition MUTATION_REQUIRED
      afk_plan_entry INSTALL COMPONENT_NOT_INSTALLED "$AFK_OB_CANONICAL" "CURRENT" false false
      return 0
    fi
    # Installed, differing from canonical, and owned by nobody. Claiming it
    # here would be exactly the silent claim FR-26 forbids.
    afk_plan_note_disposition REFUSED
    afk_plan_entry BLOCKED COMPONENT_NOT_RECORDED "$AFK_OB_CANONICAL" "UNKNOWN" false false
    return 0
  fi
  if [[ "$AFK_OB_OBSERVED" == "$AFK_OB_APPLIED" ]]; then
    afk_plan_note_disposition MUTATION_REQUIRED
    afk_plan_entry REPLACE CANONICAL_REVISION_AHEAD "$AFK_OB_CANONICAL" "CURRENT" false true
    return 0
  fi

  afk_plan_note_disposition REFUSED
  if [[ "$ownership" == "MANAGED_LINK" ]]; then
    afk_plan_entry BLOCKED LINK_TARGET_UNEXPECTED "$AFK_OB_CANONICAL" "LOCAL_DRIFT" false false
  else
    afk_plan_entry BLOCKED UNEXPLAINED_MANAGED_DIFFERENCE "$AFK_OB_CANONICAL" "LOCAL_DRIFT" false false
  fi
}

# --- the adoption plan (FR-12, FR-13, FR-25) --------------------------------
#
# Adoption establishes OWNERSHIP; it converges nothing. Content is recorded at
# the identity it already has, so nothing a legacy host holds is overwritten by
# the act of adopting it. What happens to recognized-but-old content afterwards
# is an ordinary update, with its own plan, backups and rollback.

afk_plan_component_adopt() {
  local ownership="$AFK_OB_OWNERSHIP" prior=""

  if [[ "$ownership" == "MACHINE_LOCAL" ]]; then
    if [[ "$AFK_OB_GUARD" != "PATH_OK" ]]; then
      afk_plan_entry NONE PATH_ABSENT "" "UNKNOWN" false false
      return 0
    fi
    afk_plan_entry CLAIM MACHINE_OWNED_REGION "$AFK_OB_OBSERVED" "LOCAL_ADAPTATION" false false
    return 0
  fi

  if [[ "$AFK_OB_GUARD" != "PATH_OK" ]]; then
    if [[ "$AFK_OB_GUARD" == "PATH_ABSENT" ]]; then
      # Not installed: adoption claims nothing and refuses nothing. Update
      # installs it later, under its own plan.
      afk_plan_entry NONE PATH_ABSENT "" "UNKNOWN" false false
      return 0
    fi
    afk_plan_note_disposition REFUSED
    afk_plan_entry BLOCKED "$AFK_OB_GUARD" "" "BROKEN" false false
    return 0
  fi

  if [[ -n "$AFK_OB_ESCAPE" ]]; then
    afk_plan_note_disposition REFUSED
    afk_plan_entry BLOCKED PATH_ESCAPES_OWNERSHIP_BOUNDARY "" "BROKEN" false false
    return 0
  fi

  if [[ "$ownership" == "MANAGED_SECTION" ]]; then
    if (( AFK_OB_SECTION_RC == 3 )); then
      afk_plan_note_disposition REFUSED
      afk_plan_entry BLOCKED MANAGED_SECTION_MARKERS_MALFORMED "" "BROKEN" false false
      return 0
    fi
    if (( AFK_OB_SECTION_RC == 2 )); then
      afk_plan_entry NONE MANAGED_SECTION_ABSENT "" "UNKNOWN" false false
      return 0
    fi
  fi

  if [[ -z "$AFK_OB_OBSERVED" ]]; then
    afk_plan_note_disposition REFUSED
    afk_plan_entry BLOCKED IDENTITY_UNREADABLE "" "BROKEN" false false
    return 0
  fi
  if [[ -z "$AFK_OB_CANONICAL" ]]; then
    afk_plan_note_disposition REFUSED
    afk_plan_entry BLOCKED CANONICAL_IDENTITY_UNREADABLE "" "UNKNOWN" false false
    return 0
  fi
  if [[ "$AFK_OB_OBSERVED" == "$AFK_OB_CANONICAL" ]]; then
    afk_plan_note_disposition MUTATION_REQUIRED
    if [[ "$ownership" == "MANAGED_LINK" ]]; then
      afk_plan_entry CLAIM EXACT_RECOGNIZED_WIRING "$AFK_OB_OBSERVED" "CURRENT" false false
    else
      afk_plan_entry CLAIM EXACT_CANONICAL "$AFK_OB_OBSERVED" "CURRENT" false false
    fi
    return 0
  fi

  case "$ownership" in
    MANAGED_SECTION)   prior="$(afk_recognized_prior_identity "$AFK_OB_SREL" "$AFK_OB_OBSERVED" section)" ;;
    MANAGED_COPY_FILE) prior="$(afk_recognized_prior_identity "$AFK_OB_SREL" "$AFK_OB_OBSERVED" file)" ;;
    MANAGED_COPY_TREE) prior="$(afk_recognized_prior_identity "$AFK_OB_SREL" "$AFK_OB_OBSERVED" tree "$AFK_OB_EXTRA")" ;;
    *)                 prior="" ;;
  esac
  if [[ -n "$prior" ]]; then
    afk_plan_note_disposition MUTATION_REQUIRED
    afk_plan_entry CLAIM RECOGNIZED_PRIOR_CANONICAL "$AFK_OB_OBSERVED" "UPDATE_AVAILABLE" false false
    return 0
  fi

  # Ownership cannot be proven mechanically. The content is preserved exactly
  # as it is either way; what needs an owner is the claim itself.
  afk_plan_note_disposition APPROVAL_REQUIRED
  if [[ "$ownership" == "MANAGED_LINK" ]]; then
    afk_plan_entry CLAIM LINK_TARGET_UNEXPECTED "$AFK_OB_OBSERVED" "UPDATE_AVAILABLE" true false
  else
    afk_plan_entry CLAIM UNRECOGNIZED_CONTENT "$AFK_OB_OBSERVED" "UPDATE_AVAILABLE" true false
  fi
}

# --- plan assembly ----------------------------------------------------------

afk_plan_compute() { # <adopt|update>
  local command="$1" row

  AFK_PLAN_COMMAND="$command"
  AFK_PLAN_ENTRIES=""
  AFK_PLAN_JSON="{}"
  AFK_PLAN_IDENTITY=""
  AFK_PLAN_DISPOSITION="NO_CHANGE"
  AFK_PLAN_MUTATIONS=0
  AFK_PLAN_APPROVALS=0
  AFK_PLAN_CONFLICTS=0
  AFK_PLAN_GLOBAL_REFUSAL=""

  # --- refusals that make every per-component question moot ----------------
  if [[ "$AFK_SRC_MUTATION_ALLOWED" != "true" ]]; then
    AFK_PLAN_GLOBAL_REFUSAL="SOURCE_INELIGIBLE"
  elif [[ "$command" == "update" ]]; then
    if [[ "$AFK_ADOPTED" != "true" ]]; then
      if [[ "$AFK_MANIFEST_PRESENT" == "true" && -n "$AFK_MANIFEST_REASON" ]]; then
        AFK_PLAN_GLOBAL_REFUSAL="$AFK_MANIFEST_REASON"
      else
        AFK_PLAN_GLOBAL_REFUSAL="INSTALLATION_NOT_ADOPTED"
      fi
    elif [[ -n "$AFK_MANIFEST_REASON" ]]; then
      # A recognized older schema is readable but must be migrated under its
      # declared rules before anything is written through it.
      AFK_PLAN_GLOBAL_REFUSAL="$AFK_MANIFEST_REASON"
    elif [[ "$AFK_MANIFEST_REPO_IDENTITY" != "$AFK_CO_REPO_IDENTITY" ]]; then
      AFK_PLAN_GLOBAL_REFUSAL="SOURCE_REPOSITORY_MISMATCH"
    fi
  else
    if [[ "$AFK_ADOPTED" == "true" ]]; then
      AFK_PLAN_GLOBAL_REFUSAL="ADOPTION_NOT_APPLICABLE_ALREADY_ADOPTED"
    elif [[ "$AFK_MANIFEST_PRESENT" == "true" ]]; then
      AFK_PLAN_GLOBAL_REFUSAL="${AFK_MANIFEST_REASON:-STATE_MANIFEST_SHAPE_INVALID}"
    elif [[ -z "$AFK_CO_REPO_IDENTITY" || "$AFK_CO_KIT_ID" != "agent-flow-kit" ]]; then
      AFK_PLAN_GLOBAL_REFUSAL="SOURCE_REPOSITORY_UNIDENTIFIED"
    fi
  fi
  if [[ -z "$AFK_PLAN_GLOBAL_REFUSAL" ]]; then
    case "$AFK_JOURNAL_STATE" in
      OPEN|UNREADABLE|UNSAFE) AFK_PLAN_GLOBAL_REFUSAL="OPERATION_INTERRUPTED" ;;
      *) : ;;
    esac
  fi
  # An invalid adaptation record cannot be reasoned about, and a plan computed
  # around one would be a plan around a record nobody can falsify.
  if [[ -z "$AFK_PLAN_GLOBAL_REFUSAL" ]]; then
    if printf '%s' "$AFK_ADAPT_RECORDS" | jq -se 'map(select(.valid | not)) | length > 0' >/dev/null 2>&1; then
      AFK_PLAN_GLOBAL_REFUSAL="ADAPTATION_MALFORMED"
    fi
  fi

  if ! afk_plan_binding_compute; then
    AFK_PLAN_GLOBAL_REFUSAL="${AFK_PLAN_GLOBAL_REFUSAL:-PLAN_NOT_COMPUTABLE}"
    AFK_PLAN_DISPOSITION="REFUSED"
    afk_plan_finalize
    return 1
  fi

  if [[ -n "$AFK_PLAN_GLOBAL_REFUSAL" ]]; then
    AFK_PLAN_DISPOSITION="REFUSED"
  else
    while IFS= read -r row; do
      [[ -n "$row" ]] || continue
      # The binding just observed this component. Replaying that observation is
      # what makes the plan and the binding one coherent statement about one
      # moment; re-reading the filesystem here would reopen the window the
      # binding exists to close.
      if ! afk_observation_restore "${row%%|*}"; then
        AFK_PLAN_GLOBAL_REFUSAL="PLAN_NOT_COMPUTABLE"
        AFK_PLAN_DISPOSITION="REFUSED"
        AFK_PLAN_ENTRIES=""
        AFK_PLAN_MUTATIONS=0; AFK_PLAN_APPROVALS=0; AFK_PLAN_CONFLICTS=0
        break
      fi
      if [[ "$command" == "adopt" ]]; then
        afk_plan_component_adopt
      else
        afk_plan_component_update
      fi
    done < <(afk_component_table)
  fi

  afk_plan_finalize
}

afk_plan_finalize() {
  local doc digest

  doc="$(jq -nc \
    --arg schema "$AFK_PLAN_SCHEMA_VERSION" \
    --arg command "$AFK_PLAN_COMMAND" \
    --arg disposition "$AFK_PLAN_DISPOSITION" \
    --arg refusal "$AFK_PLAN_GLOBAL_REFUSAL" \
    --arg mutations "$AFK_PLAN_MUTATIONS" \
    --arg approvals "$AFK_PLAN_APPROVALS" \
    --arg conflicts "$AFK_PLAN_CONFLICTS" \
    --arg prior "$AFK_APPLIED_REVISION" \
    --arg target "$AFK_CO_REVISION" \
    --argjson binding "$AFK_PLAN_BINDING" \
    --argjson components "$(afk_ndjson_to_array "$AFK_PLAN_ENTRIES")" \
    '{plan_schema_version: $schema,
      command: $command,
      disposition: $disposition,
      refusal_reason: (if $refusal == "" then null else $refusal end),
      prior_revision: (if $prior == "" then null else $prior end),
      target_revision: (if $target == "" then null else $target end),
      required_mutations: ($mutations | tonumber),
      approvals_required: ($approvals | tonumber),
      conflicts: ($conflicts | tonumber),
      binding: $binding,
      components: $components}')" || return 1
  [[ -n "$doc" ]] || return 1

  # The identity covers the plan AND its binding, sorted, so it is stable
  # across runs and moves the moment any authority-relevant input moves.
  digest="$(printf '%s' "$doc" | jq -S -c '.' | afk_sha256_stdin)" || return 1
  [[ -n "$digest" ]] || return 1
  AFK_PLAN_IDENTITY="$digest"

  AFK_PLAN_JSON="$(printf '%s' "$doc" | jq -c --arg id "$digest" '. + {plan_identity: $id}')" || return 1
  [[ -n "$AFK_PLAN_JSON" ]] || return 1
  return 0
}

# --- revalidation at the mutation boundary (FR-91) --------------------------
#
# Recompute the binding and compare. A material change makes the plan STALE and
# stops execution: it is never silently recomputed under an earlier approval.

AFK_PLAN_STALE_REASON=""
AFK_PLAN_STALE_DETAIL=""

afk_plan_revalidate() {
  local before="$AFK_PLAN_BINDING" after diff_component
  local saved_findings="$AFK_FINDINGS" saved_adaptations="$AFK_ADAPTATIONS"

  AFK_PLAN_STALE_REASON=""
  AFK_PLAN_STALE_DETAIL=""

  # The manifest, the adaptation records AND the journal are re-read from disk
  # rather than trusted from the earlier evaluation. A bound input that is
  # never recomputed compares equal to itself by construction, which is the
  # one shape a falsifiable binding must not contain: journal_state was
  # exactly that until it was re-evaluated here. Revalidation must not add
  # findings to the result model, so the accumulators are restored afterwards.
  afk_load_manifest
  afk_validate_adaptations
  afk_evaluate_journal
  AFK_FINDINGS="$saved_findings"
  AFK_ADAPTATIONS="$saved_adaptations"

  if ! afk_plan_binding_compute; then
    AFK_PLAN_STALE_REASON="PLAN_NOT_COMPUTABLE"
    return 1
  fi
  after="$AFK_PLAN_BINDING"

  if [[ "$before" == "$after" ]]; then
    return 0
  fi

  if [[ "$(printf '%s' "$before" | jq -r '.source_revision')" \
     != "$(printf '%s' "$after"  | jq -r '.source_revision')" ]] \
  || [[ "$(printf '%s' "$before" | jq -r '.repository_identity')" \
     != "$(printf '%s' "$after"  | jq -r '.repository_identity')" ]]; then
    AFK_PLAN_STALE_REASON="PLAN_STALE_SOURCE_CHANGED"
    return 1
  fi
  if [[ "$(printf '%s' "$before" | jq -r '.manifest_state_identity')" \
     != "$(printf '%s' "$after"  | jq -r '.manifest_state_identity')" ]] \
  || [[ "$(printf '%s' "$before" | jq -r '.journal_state')" \
     != "$(printf '%s' "$after"  | jq -r '.journal_state')" ]] \
  || [[ "$(printf '%s' "$before" | jq -c '.adaptations')" \
     != "$(printf '%s' "$after"  | jq -c '.adaptations')" ]]; then
    AFK_PLAN_STALE_REASON="PLAN_STALE_MANIFEST_CHANGED"
    return 1
  fi
  diff_component="$(jq -nr --argjson a "$before" --argjson b "$after" \
    '[$a.components[] as $x | ($b.components[] | select(.component == $x.component))
      | select(. != $x) | .component] | (.[0] // "")' 2>/dev/null)" || diff_component=""
  AFK_PLAN_STALE_DETAIL="$diff_component"
  AFK_PLAN_STALE_REASON="PLAN_STALE_DESTINATION_CHANGED"
  return 1
}
