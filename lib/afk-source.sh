#!/usr/bin/env bash
# afk-source.sh — repository identity and mutation-source eligibility.
#
# Source eligibility and installed execution readiness are DIFFERENT dimensions
# (FR-35). Everything in this file therefore reports into its own scope
# (MUTATION_SOURCE) and never into INSTALLED_INTEGRITY: a checkout that is
# unusable as an update source must not be able to turn a separately verified
# installation into BROKEN or NOT_READY.
#
# Nothing here fetches, pulls, merges, rebases or switches Git state (FR-34).
# Every Git invocation is a read, and `--no-optional-locks` is used where the
# installed Git supports it so that even the index stat cache is left alone.
#
# shellcheck disable=SC2034
# The C_*/F_* result-model accumulators and several AFK_* globals are written
# here and read by afk-common.sh, which is sourced alongside this file. Under
# `set -u` a genuinely unset variable is a hard runtime error, so the static
# "assigned but never used" heuristic adds nothing here.

if [[ -n "${AFK_SOURCE_SOURCED:-}" ]]; then
  return 0
fi
AFK_SOURCE_SOURCED=1

AFK_CO_REVISION=""
AFK_CO_BRANCH=""
AFK_CO_DETACHED="false"
AFK_CO_REPO_IDENTITY=""
AFK_CO_KIT_ID=""
AFK_CO_LIFECYCLE_SCHEMA=""
AFK_CO_STATE_SCHEMA=""
AFK_CO_DEFAULT_BRANCH=""
AFK_CO_MANAGED_INPUTS=()
AFK_CO_DECLARATION="ABSENT"   # ABSENT | UNREADABLE | INCOMPLETE | COMPLETE
AFK_CO_IS_GIT="false"

AFK_SRC_MUTATION_ALLOWED="true"
AFK_SRC_STATE="ELIGIBLE"
AFK_SRC_REASONS=""
AFK_SRC_REVISION_RELATION="NOT_EVALUATED"

# Redefined by afk_git_init once the checkout's Git capabilities are known.
afk_git() { git -C "$AFK_KIT_ROOT" "$@"; }

afk_git_init() {
  if git --no-optional-locks -C "$AFK_KIT_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    afk_git() { git --no-optional-locks -C "$AFK_KIT_ROOT" "$@"; }
  else
    afk_git() { git -C "$AFK_KIT_ROOT" "$@"; }
  fi
}

afk_src_reason_add() { # <reason> <blocks: true|false>
  AFK_SRC_REASONS="${AFK_SRC_REASONS}${AFK_SRC_REASONS:+,}$1"
  if [[ "$2" == "true" ]]; then
    AFK_SRC_MUTATION_ALLOWED="false"
    AFK_SRC_STATE="SOURCE_INELIGIBLE"
  fi
}

afk_src_finding() { # <reason> <blocks> [expected] [observed]
  afk_src_reason_add "$1" "$2"
  afk_add_finding "" "CANONICAL_SOURCE" "$AFK_SRC_STATE" "$1" "warning" \
    "MUTATION_SOURCE" "GIT_STATE" "${3:-}" "${4:-}" "false" "false" ""
}

# afk_rev_relation <applied> <head>
afk_rev_relation() {
  local a="$1" h="$2"
  if [[ -z "$a" || -z "$h" ]]; then printf 'NOT_EVALUATED\n'; return 0; fi
  if [[ "$a" == "$h" ]]; then printf 'SAME\n'; return 0; fi
  if ! afk_git cat-file -e "${a}^{commit}" 2>/dev/null; then printf 'UNREACHABLE\n'; return 0; fi
  if afk_git merge-base --is-ancestor "$a" "$h" >/dev/null 2>&1; then printf 'AHEAD\n'; return 0; fi
  if afk_git merge-base --is-ancestor "$h" "$a" >/dev/null 2>&1; then printf 'BEHIND\n'; return 0; fi
  printf 'DIVERGED\n'
}

# --- the source declaration (FR-29) -----------------------------------------
#
# lifecycle/kit.json is a complete recognized shape or it is nothing. A partial
# declaration cannot be "mostly honoured": a missing managed-input list would
# silently make every uncommitted change invisible to dirty-source detection,
# and a missing default branch would silently make every branch canonical.

afk_declaration_is_complete() { # <path>
  jq -e '
    (type == "object")
    and (.kit_id | type == "string") and (.kit_id | length > 0)
    and (.lifecycle_schema_version | type == "string")
    and (.lifecycle_schema_version | test("^[0-9]+\\.[0-9]+$"))
    and (.state_schema_version | type == "string")
    and (.state_schema_version | test("^[0-9]+\\.[0-9]+$"))
    and (.default_branch | type == "string") and (.default_branch | length > 0)
    and (.managed_inputs | type == "array") and (.managed_inputs | length > 0)
    and (all(.managed_inputs[];
             (type == "string") and (length > 0)
             and ((test("[\\n\\t]")) | not)
             and ((startswith("/")) | not)
             and ((test("(^|/)\\.\\.(/|$)")) | not)))
  ' "$1" >/dev/null 2>&1
}

afk_read_declaration() { # <path>
  local decl="$1" item
  AFK_CO_KIT_ID=""; AFK_CO_LIFECYCLE_SCHEMA=""; AFK_CO_STATE_SCHEMA=""
  AFK_CO_DEFAULT_BRANCH=""; AFK_CO_MANAGED_INPUTS=(); AFK_CO_DECLARATION="ABSENT"

  [[ -f "$decl" ]] || return 0
  if ! jq -e '.' "$decl" >/dev/null 2>&1; then
    AFK_CO_DECLARATION="UNREADABLE"
    return 0
  fi
  if ! afk_declaration_is_complete "$decl"; then
    AFK_CO_DECLARATION="INCOMPLETE"
    # Read what is readable so the checkout record still reports the evidence.
    AFK_CO_KIT_ID="$(jq -r 'if (.kit_id | type) == "string" then .kit_id else "" end' "$decl" 2>/dev/null)"
    AFK_CO_LIFECYCLE_SCHEMA="$(jq -r 'if (.lifecycle_schema_version | type) == "string" then .lifecycle_schema_version else "" end' "$decl" 2>/dev/null)"
    return 0
  fi

  AFK_CO_DECLARATION="COMPLETE"
  AFK_CO_KIT_ID="$(jq -r '.kit_id' "$decl")"
  AFK_CO_LIFECYCLE_SCHEMA="$(jq -r '.lifecycle_schema_version' "$decl")"
  AFK_CO_STATE_SCHEMA="$(jq -r '.state_schema_version' "$decl")"
  AFK_CO_DEFAULT_BRANCH="$(jq -r '.default_branch' "$decl")"
  # Newlines and tabs are rejected by the completeness check above, so a
  # line-delimited read cannot split or merge a declared path, and spaces
  # inside a path are preserved exactly.
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    AFK_CO_MANAGED_INPUTS+=("$item")
  done < <(jq -r '.managed_inputs[]' "$decl" 2>/dev/null)
  return 0
}

afk_managed_inputs_json() {
  if (( ${#AFK_CO_MANAGED_INPUTS[@]} == 0 )); then
    printf '[]'
    return 0
  fi
  printf '%s\n' "${AFK_CO_MANAGED_INPUTS[@]}" \
    | jq -R -s -c 'split("\n") | map(select(length > 0))'
}

# afk_source_evaluate <applied-revision> <manifest-repository-identity>
#                     <allow-noncanonical: true|false> <allow-rollback: true|false>
afk_source_evaluate() {
  local applied="$1" manifest_identity="$2" allow_noncanonical="$3" allow_rollback="$4"
  local decl root_commit dirty_all dirty_managed input p major

  AFK_CO_REVISION=""; AFK_CO_BRANCH=""; AFK_CO_DETACHED="false"
  AFK_CO_REPO_IDENTITY=""; AFK_CO_IS_GIT="false"
  AFK_SRC_MUTATION_ALLOWED="true"; AFK_SRC_STATE="ELIGIBLE"; AFK_SRC_REASONS=""
  AFK_SRC_REVISION_RELATION="NOT_EVALUATED"

  afk_git_init

  # --- Git facts first, so the exact revision is always reportable ----------
  if [[ "$(afk_git rev-parse --is-inside-work-tree 2>/dev/null)" == "true" ]]; then
    AFK_CO_IS_GIT="true"
    AFK_CO_REVISION="$(afk_git rev-parse HEAD 2>/dev/null)" || AFK_CO_REVISION=""
    AFK_CO_BRANCH="$(afk_git symbolic-ref --quiet --short HEAD 2>/dev/null)" || AFK_CO_BRANCH=""
    if [[ -z "$AFK_CO_BRANCH" ]]; then AFK_CO_DETACHED="true"; fi
    root_commit="$(afk_git rev-list --max-parents=0 HEAD 2>/dev/null | LC_ALL=C sort | tail -n1)" || root_commit=""
    if [[ -n "$root_commit" ]]; then
      AFK_CO_REPO_IDENTITY="rootcommit:$root_commit"
    fi
  fi

  # --- the source declaration, not the directory name (FR-29) ---------------
  decl="$AFK_KIT_ROOT/lifecycle/kit.json"
  afk_read_declaration "$decl"

  if [[ "$AFK_CO_IS_GIT" != "true" ]]; then
    afk_src_finding "SOURCE_NOT_A_GIT_CHECKOUT" "true" "git work tree" "none"
    return 0
  fi
  if [[ "$AFK_CO_DECLARATION" == "UNREADABLE" ]]; then
    afk_src_finding "SOURCE_DECLARATION_UNREADABLE" "true" "readable lifecycle/kit.json" "unparseable"
    return 0
  fi
  if [[ "$AFK_CO_KIT_ID" != "agent-flow-kit" || -z "$AFK_CO_REPO_IDENTITY" ]]; then
    afk_src_finding "SOURCE_REPOSITORY_UNIDENTIFIED" "true" \
      "kit_id=agent-flow-kit + rootcommit:<sha>" \
      "kit_id=${AFK_CO_KIT_ID:-none} + ${AFK_CO_REPO_IDENTITY:-no-root-commit}"
    return 0
  fi
  # --- the revision shape, BEFORE anything is planned from it (FR-44) ------
  #
  # The applied-state manifest records a 40-character lowercase hex object
  # name, and offline verification enforces that shape. Enforcing it only
  # there means a checkout whose object format this executable cannot record
  # (a sha256 repository, whose HEAD is 64 hex) computes a plan, takes the
  # lock, creates backups, opens a journal, performs every managed write and
  # only THEN fails at the verification gate — reporting VERIFICATION_FAILED,
  # which says nothing about the real cause. A precondition of the mutation is
  # checked before the mutation, in its own scope, with its own reason.
  if [[ -n "$AFK_CO_REVISION" && ! "$AFK_CO_REVISION" =~ ^[0-9a-f]{40}$ ]]; then
    afk_src_finding "SOURCE_REVISION_FORMAT_UNSUPPORTED" "true" \
      "40-character lowercase hex object name" "$AFK_CO_REVISION"
    return 0
  fi

  if [[ "$AFK_CO_DECLARATION" != "COMPLETE" ]]; then
    afk_src_finding "SOURCE_DECLARATION_INCOMPLETE" "true" \
      "kit_id, lifecycle_schema_version, state_schema_version, default_branch, managed_inputs" \
      "incomplete declaration"
    return 0
  fi

  # A lifecycle schema whose major version this executable does not implement
  # is refused in BOTH directions: a newer major may mean anything, and an
  # older major means fields this executable reads have a different meaning.
  major="${AFK_CO_LIFECYCLE_SCHEMA%%.*}"
  case "$major" in
    ''|*[!0-9]*)
      afk_src_finding "SOURCE_LIFECYCLE_SCHEMA_INCOMPATIBLE" "true" \
        "$AFK_SUPPORTED_LIFECYCLE_SCHEMA_MAJOR.x" "$AFK_CO_LIFECYCLE_SCHEMA" ;;
    *)
      if (( major != AFK_SUPPORTED_LIFECYCLE_SCHEMA_MAJOR )); then
        afk_src_finding "SOURCE_LIFECYCLE_SCHEMA_INCOMPATIBLE" "true" \
          "$AFK_SUPPORTED_LIFECYCLE_SCHEMA_MAJOR.x" "$AFK_CO_LIFECYCLE_SCHEMA"
      fi ;;
  esac

  for input in "${AFK_CO_MANAGED_INPUTS[@]}"; do
    p="$AFK_KIT_ROOT/$input"
    if [[ ! -e "$p" ]]; then
      afk_src_finding "SOURCE_MANAGED_INPUT_MISSING" "true" "$input" "absent"
    fi
  done

  if [[ -n "$manifest_identity" && "$manifest_identity" != "$AFK_CO_REPO_IDENTITY" ]]; then
    afk_src_finding "SOURCE_REPOSITORY_MISMATCH" "true" "$manifest_identity" "$AFK_CO_REPO_IDENTITY"
  fi

  # --- uncommitted content (FR-30) -----------------------------------------
  dirty_all="$(afk_git status --porcelain --untracked-files=all 2>/dev/null | wc -l | tr -d ' ')"
  [[ -n "$dirty_all" ]] || dirty_all=0
  dirty_managed=0
  if (( ${#AFK_CO_MANAGED_INPUTS[@]} > 0 )); then
    # Each declared input reaches Git as its own argument, so a path containing
    # a space stays one pathspec instead of becoming two.
    dirty_managed="$(afk_git status --porcelain --untracked-files=all \
                      -- "${AFK_CO_MANAGED_INPUTS[@]}" 2>/dev/null | wc -l | tr -d ' ')"
  fi
  [[ -n "$dirty_managed" ]] || dirty_managed=0
  if (( dirty_managed > 0 )); then
    afk_src_finding "SOURCE_MANAGED_INPUT_DIRTY" "true" \
      "0 uncommitted managed inputs" "$dirty_managed uncommitted managed inputs"
  fi
  if (( dirty_all > dirty_managed )); then
    afk_src_finding "SOURCE_DIRT_OUTSIDE_INPUT_SET" "false" \
      "0 uncommitted paths outside the input set" \
      "$((dirty_all - dirty_managed)) uncommitted paths outside the input set"
  fi

  # --- branch / revision selection (FR-31, FR-32) ---------------------------
  if [[ "$AFK_CO_DETACHED" == "true" ]]; then
    if [[ "$allow_noncanonical" == "true" ]]; then
      afk_src_reason_add "SOURCE_DETACHED_HEAD" "false"
    else
      afk_src_finding "SOURCE_DETACHED_HEAD" "true" "${AFK_CO_DEFAULT_BRANCH:-<default branch>}" "detached"
    fi
  elif [[ -n "$AFK_CO_DEFAULT_BRANCH" && "$AFK_CO_BRANCH" != "$AFK_CO_DEFAULT_BRANCH" ]]; then
    if [[ "$allow_noncanonical" == "true" ]]; then
      afk_src_reason_add "SOURCE_NONCANONICAL_BRANCH" "false"
    else
      afk_src_finding "SOURCE_NONCANONICAL_BRANCH" "true" "$AFK_CO_DEFAULT_BRANCH" "$AFK_CO_BRANCH"
    fi
  fi

  AFK_SRC_REVISION_RELATION="$(afk_rev_relation "$applied" "$AFK_CO_REVISION")"
  case "$AFK_SRC_REVISION_RELATION" in
    BEHIND)
      if [[ "$allow_rollback" == "true" ]]; then
        afk_src_reason_add "SOURCE_DOWNGRADE_REQUIRES_INTENT" "false"
      else
        afk_src_finding "SOURCE_DOWNGRADE_REQUIRES_INTENT" "true" "$applied" "$AFK_CO_REVISION"
      fi ;;
    DIVERGED)
      if [[ "$allow_noncanonical" == "true" ]]; then
        afk_src_reason_add "SOURCE_REVISION_UNEXPECTED" "false"
      else
        afk_src_finding "SOURCE_REVISION_UNEXPECTED" "true" "$applied" "$AFK_CO_REVISION"
      fi ;;
    UNREACHABLE)
      afk_src_finding "APPLIED_REVISION_UNREACHABLE" "true" "$applied" "not reachable from HEAD" ;;
    *) : ;;
  esac
  return 0
}

afk_checkout_json() {
  jq -nc \
    --arg revision "$AFK_CO_REVISION" \
    --arg branch "$AFK_CO_BRANCH" \
    --argjson detached "$AFK_CO_DETACHED" \
    --arg identity "$AFK_CO_REPO_IDENTITY" \
    --arg kit_id "$AFK_CO_KIT_ID" \
    --arg lifecycle_schema "$AFK_CO_LIFECYCLE_SCHEMA" \
    --arg state_schema "$AFK_CO_STATE_SCHEMA" \
    --arg default_branch "$AFK_CO_DEFAULT_BRANCH" \
    --arg declaration "$AFK_CO_DECLARATION" \
    --arg root "$AFK_KIT_ROOT" \
    --argjson inputs "$(afk_managed_inputs_json)" \
    '{path: $root,
      revision: (if $revision == "" then null else $revision end),
      branch: (if $branch == "" then null else $branch end),
      detached: $detached,
      repository_identity: (if $identity == "" then null else $identity end),
      identity_method: "root_commit",
      declaration: $declaration,
      kit_id: (if $kit_id == "" then null else $kit_id end),
      lifecycle_schema_version: (if $lifecycle_schema == "" then null else $lifecycle_schema end),
      state_schema_version: (if $state_schema == "" then null else $state_schema end),
      default_branch: (if $default_branch == "" then null else $default_branch end),
      managed_inputs: $inputs}'
}

afk_source_json() { # <allow-noncanonical> <allow-rollback>
  jq -nc \
    --arg state "$AFK_SRC_STATE" \
    --arg reasons "$AFK_SRC_REASONS" \
    --arg relation "$AFK_SRC_REVISION_RELATION" \
    --argjson allowed "$AFK_SRC_MUTATION_ALLOWED" \
    --arg noncanonical "$1" \
    --arg rollback "$2" \
    '{state: $state,
      mutation_allowed: $allowed,
      reasons: (if $reasons == "" then [] else ($reasons | split(",")) end),
      revision_relation: $relation,
      evidence_provenance: "GIT_STATE",
      explicit_intent: {allow_noncanonical_source: ($noncanonical == "true"),
                        allow_rollback: ($rollback == "true")}}'
}
