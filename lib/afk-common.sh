#!/usr/bin/env bash
# afk-common.sh — primitives shared by every agent-flow-kit lifecycle command.
#
# This file is SOURCED, never executed.
#
# It deliberately does NOT set -e. Every function here reports failure through
# its exit status and a stable reason code, and the callers branch on that. A
# lifecycle that aborts mid-evaluation on an unexpected non-zero cannot produce
# the normalized result the machine contract promises, and a half-written
# result is exactly the "claimed" state this product exists to refuse.
#
# Nothing in this file writes outside a caller-supplied path: the primitives
# are read-only, including the rendering path, which never spills a temporary
# file. The only file in the lifecycle that writes to a managed destination is
# afk-mutate.sh.

if [[ -n "${AFK_COMMON_SOURCED:-}" ]]; then
  return 0
fi
AFK_COMMON_SOURCED=1

# --- frozen contract constants ---------------------------------------------

AFK_RESULT_SCHEMA_VERSION="1.0"
AFK_SUPPORTED_LIFECYCLE_SCHEMA_MAJOR="1"
AFK_SUPPORTED_STATE_SCHEMA_MAJOR="1"

# Coarse, stable exit semantics (FR-77). These meanings never change inside a
# result schema major version.
AFK_EXIT_OK=0                # requested scope succeeded (incl. WARNINGS/ADAPTATION)
AFK_EXIT_USAGE=1             # command, internal, or usage failure
AFK_EXIT_OWNER_ACTION=2      # owner action or conflict
AFK_EXIT_NOT_READY=3         # deterministic not-ready / verification failure
AFK_EXIT_SOURCE_REFUSED=4    # source or precondition refusal
AFK_EXIT_LIVE_UNAVAILABLE=5  # live dependency unavailable or timed out

# --- declared local configuration -------------------------------------------
# Declared here so every sourced file can read them, and so a lib sourced on its
# own (the deterministic gate does exactly that) never reads an unset variable.
# bin/agent-flow-kit assigns the real values after sourcing; each assignment
# below preserves an already-set value.

AFK_KIT_ROOT="${AFK_KIT_ROOT:-}"
AFK_STATE_DIR="${AFK_STATE_DIR:-}"
AFK_MANIFEST="${AFK_MANIFEST:-}"
AFK_JOURNAL="${AFK_JOURNAL:-}"
AFK_LOCK_DIR="${AFK_LOCK_DIR:-}"
AFK_BACKUP_ROOT="${AFK_BACKUP_ROOT:-}"
AFK_STAGE_ROOT="${AFK_STAGE_ROOT:-}"
AFK_SKILLS_HOME="${AFK_SKILLS_HOME:-}"
AFK_CLAUDE_HOME="${AFK_CLAUDE_HOME:-}"
AFK_CODEX_HOME="${AFK_CODEX_HOME:-}"

# The managed-section markers. Full-line, exact, and cardinality-checked: a
# duplicated or unterminated marker is malformed, never "best effort".
afk_section_marker_begin() { printf '# >>> agent-flow-kit managed section: %s >>>' "$1"; }
afk_section_marker_end()   { printf '# <<< agent-flow-kit managed section: %s <<<' "$1"; }

# --- small helpers ----------------------------------------------------------

afk_warn() { printf 'agent-flow-kit: %s\n' "$*" >&2; }

afk_have() { command -v "$1" >/dev/null 2>&1; }

afk_require_tools() {
  local missing="" t
  for t in git jq find sed grep awk wc tr sort readlink head tail cat cp mv; do
    if ! afk_have "$t"; then missing="$missing $t"; fi
  done
  if ! afk_have sha256sum && ! afk_have shasum; then
    missing="$missing sha256sum|shasum"
  fi
  if [[ -n "$missing" ]]; then
    afk_warn "missing required tools:$missing"
    return 1
  fi
  return 0
}

# A declared list is comma-separated and compared as exact path components.
# A declared directory excludes that directory's bounded subtree (`item/...`),
# but never a lookalike prefix such as `item-backup`. Word splitting is never
# used: spaces and glob characters remain literal path bytes (FR-93).
afk_excluded() { # <relative-path> <comma-separated exclusions>
  local rel="$1" list="${2:-}" item
  local -a items=()
  [[ -n "$list" ]] || return 1
  IFS=',' read -r -a items <<< "$list"
  for item in "${items[@]}"; do
    if [[ "$item" == "$rel" || "$rel" == "$item/"* ]]; then return 0; fi
  done
  return 1
}

# A reversible one-line encoding for a filename or link target. Every record in
# a tree listing is exactly one line, so a filename containing a newline or a
# tab cannot forge, merge or hide a neighbouring record (FR-79).
afk_encode_path() { # <raw>
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# --- content identity -------------------------------------------------------
# Bounded identifiers only (FR-79): the lifecycle compares hashes, never file
# dumps, so evidence can be emitted without becoming an exfiltration surface.

afk_sha256_stdin() {
  if afk_have sha256sum; then
    sha256sum | awk '{print "sha256:" $1}'
  elif afk_have shasum; then
    shasum -a 256 | awk '{print "sha256:" $1}'
  else
    return 1
  fi
}

afk_sha256_file() { # <path>
  [[ -f "$1" ]] || return 1
  afk_sha256_stdin < "$1"
}

afk_sha256_string() { printf '%s' "$1" | afk_sha256_stdin; }

# afk_tree_identity <absolute-root> [comma-separated relative exclusions]
# A deterministic identity for a managed copy tree: the sorted listing of every
# regular file (hashed) and every symlink (by encoded target), excluding
# declared machine-owned members, hashed as one document.
#
# It FAILS rather than under-reporting. An unreadable member, an unreadable
# subdirectory, or a failing scan produces no identity at all, because a tree
# identity computed over the part that happened to be readable is a confident
# claim about content nobody looked at.
afk_tree_identity() {
  local root="$1" excl="${2:-}" out=""
  [[ "$root" == /* ]] || return 1
  [[ -d "$root" ]] || return 1
  out="$(
    listing=""
    while IFS= read -r -d '' entry; do
      # find's own exit status arrives as the last NUL-terminated record. Every
      # real record is an absolute path, so the sentinel cannot be a filename.
      case "$entry" in
        FINDRC=0) break ;;
        FINDRC=*) exit 1 ;;
      esac
      rel="${entry#"$root"/}"
      if [[ "$rel" == "$entry" ]]; then rel="${entry##*/}"; fi
      if afk_excluded "$rel" "$excl"; then continue; fi
      if [[ -L "$entry" ]]; then
        target="$(readlink -- "$entry")" || exit 1
        listing="${listing}L $(afk_encode_path "$target") $(afk_encode_path "$rel")"$'\n'
      else
        digest="$(afk_sha256_file "$entry")" || exit 1
        [[ -n "$digest" ]] || exit 1
        listing="${listing}F ${digest} $(afk_encode_path "$rel")"$'\n'
      fi
    done < <(find "$root" \( -type f -o -type l \) -print0 2>/dev/null
             printf 'FINDRC=%s\0' "$?")
    printf '%s' "$listing" | LC_ALL=C sort | afk_sha256_stdin
  )" || return 1
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# --- path type, containment and symlink boundaries (FR-93) ------------------

# Portable realpath. `readlink -f` is GNU-only, so the link chain is resolved by
# hand; `cd -P` canonicalises the directory part on both GNU and BSD systems,
# which also means a symlink anywhere in the PARENT chain is resolved here.
#
# A path whose FINAL segment does not exist still canonicalises, because a
# managed destination is legitimately allowed to be absent and its containment
# still has to be judged. That leniency is correct for a destination and wrong
# for a boundary — see afk_resolve_boundary.
afk_realpath() { # <path>
  local p="$1" d b i=0 t
  d="$(dirname -- "$p")"
  b="$(basename -- "$p")"
  d="$(cd -P -- "$d" 2>/dev/null && pwd -P)" || return 1
  p="$d/$b"
  while [[ -L "$p" && $i -lt 40 ]]; do
    t="$(readlink -- "$p")" || return 1
    case "$t" in
      /*) p="$t" ;;
      *)  p="$(dirname -- "$p")/$t" ;;
    esac
    d="$(dirname -- "$p")"
    b="$(basename -- "$p")"
    d="$(cd -P -- "$d" 2>/dev/null && pwd -P)" || return 1
    p="$d/$b"
    i=$((i + 1))
  done
  if (( i >= 40 )); then return 1; fi
  if [[ -d "$p" ]]; then
    p="$(cd -P -- "$p" 2>/dev/null && pwd -P)" || return 1
  fi
  printf '%s\n' "$p"
}

afk_is_within() { # <child> <root>
  local child="$1" root="$2"
  [[ -n "$root" ]] || return 0
  [[ "$child" == "$root" || "$child" == "$root"/* ]]
}

# A declared ownership boundary is TERRITORY, not a destination: it has to be a
# real directory before anything can be proven to sit inside it. Canonicalising
# it with afk_realpath alone would accept a boundary that is not there, and
# every path would then appear to escape it — reporting a redirected
# destination when the truth is a missing boundary. Those are different facts
# with different reason codes, so they are kept apart here: a boundary that
# does not resolve to an existing directory is UNRESOLVABLE, and only a
# boundary that does resolve can be escaped.
afk_resolve_boundary() { # <declared-boundary>
  local resolved
  resolved="$(afk_realpath "$1")" || return 1
  [[ -d "$resolved" ]] || return 1
  printf '%s\n' "$resolved"
}

# afk_path_guard <path> <expected-type: file|dir|link>
#                <target-boundary-or-empty> <container-boundary-or-empty>
#
# Prints a stable reason code. Returns 0 only when the destination is safe to
# read, hash, back up or replace. Anything unexpected fails closed BEFORE the
# content is touched.
#
# Two boundaries, because two different things can be redirected:
#   container-boundary — where the destination itself must LIVE. Resolving the
#                        parent chain catches a symlinked parent directory that
#                        silently moves a managed path out of declared territory.
#   target-boundary    — where the destination may POINT, or resolve to.
#
# Both are resolved before either is compared against, so an unprovable
# boundary is never mistaken for a destination that escaped one.
afk_path_guard() {
  local p="$1" want="$2" boundary="${3:-}" container="${4:-}"
  local resolved="" parent="" rboundary="" rcontainer=""
  if [[ ! -e "$p" && ! -L "$p" ]]; then
    printf 'PATH_ABSENT\n'; return 1
  fi
  if [[ -n "$container" ]]; then
    rcontainer="$(afk_resolve_boundary "$container")" || { printf 'PATH_BOUNDARY_UNRESOLVABLE\n'; return 1; }
  fi
  if [[ -n "$boundary" ]]; then
    rboundary="$(afk_resolve_boundary "$boundary")" || { printf 'PATH_BOUNDARY_UNRESOLVABLE\n'; return 1; }
  fi
  parent="$(afk_realpath "$(dirname -- "$p")")" || { printf 'PATH_PARENT_UNRESOLVABLE\n'; return 1; }
  if [[ -n "$rcontainer" ]] && ! afk_is_within "$parent" "$rcontainer"; then
    printf 'PATH_PARENT_ESCAPES_BOUNDARY\n'; return 1
  fi
  if [[ -L "$p" ]]; then
    if [[ "$want" != "link" ]]; then
      printf 'PATH_UNEXPECTED_SYMLINK\n'; return 1
    fi
    resolved="$(afk_realpath "$p")" || { printf 'PATH_UNRESOLVABLE_SYMLINK\n'; return 1; }
    if [[ -n "$rboundary" ]] && ! afk_is_within "$resolved" "$rboundary"; then
      printf 'PATH_ESCAPES_OWNERSHIP_BOUNDARY\n'; return 1
    fi
    printf 'PATH_OK\n'; return 0
  fi
  if [[ "$want" == "link" ]]; then
    printf 'PATH_NOT_A_SYMLINK\n'; return 1
  fi
  case "$want" in
    file) [[ -f "$p" ]] || { printf 'PATH_TYPE_MISMATCH\n'; return 1; } ;;
    dir)  [[ -d "$p" ]] || { printf 'PATH_TYPE_MISMATCH\n'; return 1; } ;;
  esac
  resolved="$(afk_realpath "$p")" || { printf 'PATH_UNRESOLVABLE_SYMLINK\n'; return 1; }
  if [[ -n "$rboundary" ]] && ! afk_is_within "$resolved" "$rboundary"; then
    printf 'PATH_ESCAPES_OWNERSHIP_BOUNDARY\n'; return 1
  fi
  printf 'PATH_OK\n'; return 0
}

# --- destination metadata (FR-37) -------------------------------------------
#
# A managed write replaces a whole destination through an atomic rename, so the
# bytes that land are the canonical ones. The MODE is not canonical: it is a
# decision the host owner made about a file the lifecycle only partly owns
# (~/.claude/CLAUDE.md carries the owner's private notes around the managed
# section). A temporary file created through shell redirection carries the
# process umask, so renaming it over a 0600 destination would silently widen
# it. These helpers capture what the destination declares about itself, replay
# it onto the replacement BEFORE the rename, and give the caller a value it can
# compare on both sides — the same shape as the outside-bytes proof.
#
# Ownership is captured and compared, and is replayed only when this process is
# actually permitted to do it. A non-root process that renames its own
# temporary file over its own file does not change the owner, so the comparison
# holds; a case where it would change is exactly a case that must not pass
# silently, and it is reported rather than attempted.

afk_metadata_of() { # <path> -> "<mode> <uid> <gid>", empty when unobservable
  local out
  [[ -e "$1" && ! -L "$1" ]] || return 0
  # The numeric mode, never the rwx rendering: `ls -l` decorates that column
  # with an ACL or security-context marker on some systems, which would make an
  # unrelated xattr difference read as a mode change.
  out="$(stat -c '%a %u %g' -- "$1" 2>/dev/null)" \
    || out="$(stat -f '%OLp %u %g' -- "$1" 2>/dev/null)" \
    || out="$(ls -ldn -- "$1" 2>/dev/null | awk 'NR == 1 { print $1, $3, $4 }')" \
    || out=""
  [[ -n "$out" ]] || return 0
  printf '%s' "$out"
}

# afk_metadata_apply <reference-path> <target-path>
# Replay the reference destination's mode (and ownership where permitted) onto
# a replacement that has not been renamed into place yet. A reference that does
# not exist declares nothing, which is not an error: the replacement then keeps
# the restrictive mode its writer gave it.
afk_metadata_apply() {
  local ref="$1" target="$2"
  [[ -e "$ref" && ! -L "$ref" ]] || return 0
  [[ -e "$target" ]] || return 1
  chmod --reference="$ref" -- "$target" 2>/dev/null \
    || chmod "$(afk_mode_octal "$ref")" -- "$target" 2>/dev/null \
    || return 1
  # Best effort, and deliberately unchecked: a non-root process cannot give a
  # file away, and the caller proves the result rather than trusting this.
  chown --reference="$ref" -- "$target" 2>/dev/null || true
  return 0
}

afk_mode_octal() { # <path> -> e.g. 600
  local m
  m="$(stat -c '%a' -- "$1" 2>/dev/null)" || m="$(stat -f '%OLp' -- "$1" 2>/dev/null)" || m=""
  [[ -n "$m" ]] || return 1
  printf '%s' "$m"
}

# The kit's own state is not user content: it records what the lifecycle did
# and is read back as recovery authority, so it is created private to its owner
# rather than at whatever umask the invoking shell happened to carry.
afk_state_dir_ensure() { # <dir>
  [[ -n "$1" ]] || return 1
  mkdir -p -- "$1" 2>/dev/null || return 1
  chmod 700 -- "$1" 2>/dev/null || true
  return 0
}

# Write <content> to <path> through a temporary name and a single rename, at a
# mode the owner alone can read. Used for every kit state file.
afk_state_file_write() { # <path> <content>
  local path="$1" content="$2" tmp
  [[ -n "$path" ]] || return 1
  afk_state_dir_ensure "$(dirname -- "$path")" || return 1
  tmp="$path.afk-tmp"
  # The temporary name is written, never cleared first: a state writer that
  # removed whatever sits at that path would be deleting something it has not
  # looked at, and a redirect that cannot produce a regular file there is a
  # failure this function must report rather than clear out of the way.
  ( umask 077; printf '%s\n' "$content" > "$tmp" ) 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null; return 1; }
  chmod 600 -- "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$path" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null; return 1; }
  return 0
}

# afk_tree_find_escaping_symlink <root>
# Prints the first relative path whose symlink resolves outside <root>.
# Returns 0 when such an escape exists (i.e. the tree must not be hashed).
afk_tree_find_escaping_symlink() {
  local root="$1" resolved_root="" entry target
  resolved_root="$(afk_realpath "$root")" || return 1
  while IFS= read -r -d '' entry; do
    [[ -n "$entry" ]] || continue
    if ! target="$(afk_realpath "$entry")"; then
      afk_encode_path "${entry#"$root"/}"; printf '\n'
      return 0
    fi
    if ! afk_is_within "$target" "$resolved_root"; then
      afk_encode_path "${entry#"$root"/}"; printf '\n'
      return 0
    fi
  done < <(find "$root" -type l -print0 2>/dev/null)
  return 1
}

# --- managed sections -------------------------------------------------------

# afk_section_extract <file> <section-id>
# stdout: the payload lines strictly between the markers.
# return: 0 present, 2 absent, 3 malformed (bad cardinality or ordering).
afk_section_extract() {
  local file="$1" id="$2" b e nb ne bl el
  [[ -f "$file" ]] || return 2
  b="$(afk_section_marker_begin "$id")"
  e="$(afk_section_marker_end "$id")"
  nb="$(grep -a -c -x -F -- "$b" "$file" 2>/dev/null)" || nb=0
  ne="$(grep -a -c -x -F -- "$e" "$file" 2>/dev/null)" || ne=0
  [[ -n "$nb" ]] || nb=0
  [[ -n "$ne" ]] || ne=0
  if (( nb == 0 && ne == 0 )); then return 2; fi
  if (( nb != 1 || ne != 1 )); then return 3; fi
  bl="$(grep -a -n -x -F -- "$b" "$file" | head -1 | cut -d: -f1)"
  el="$(grep -a -n -x -F -- "$e" "$file" | head -1 | cut -d: -f1)"
  if (( el <= bl )); then return 3; fi
  if (( el - bl > 1 )); then
    sed -n "$((bl + 1)),$((el - 1))p" "$file"
  fi
  return 0
}

# afk_section_bounds <file> <section-id> -> "<begin-line> <end-line>"
afk_section_bounds() {
  local file="$1" id="$2" b e bl el
  b="$(afk_section_marker_begin "$id")"
  e="$(afk_section_marker_end "$id")"
  bl="$(grep -a -n -x -F -- "$b" "$file" 2>/dev/null | head -1 | cut -d: -f1)"
  el="$(grep -a -n -x -F -- "$e" "$file" 2>/dev/null | head -1 | cut -d: -f1)"
  [[ -n "$bl" && -n "$el" ]] || return 1
  printf '%s %s\n' "$bl" "$el"
}

# The one contracted normalization: a payload identity ignores a missing final
# newline and trailing blank lines, so an editor that "fixes" the end of a file
# cannot manufacture drift. Both sides of every section comparison go through
# the same normalization, so equality stays deterministic.
afk_normalized_identity_of_text() { # <text>
  if [[ -z "$1" ]]; then
    printf '' | afk_sha256_stdin
  else
    printf '%s\n' "$1" | afk_sha256_stdin
  fi
}

afk_section_identity() { # <file> <section-id>
  local payload rc
  payload="$(afk_section_extract "$1" "$2")"
  rc=$?
  if (( rc != 0 )); then return "$rc"; fi
  afk_normalized_identity_of_text "$payload"
}

afk_file_payload_identity() { # <path> — canonical side of a section comparison
  local content
  [[ -f "$1" ]] || return 1
  content="$(cat -- "$1")" || return 1
  afk_normalized_identity_of_text "$content"
}

# --- redaction (FR-81, FR-82) ----------------------------------------------
#
# afk_env_value is the ONLY place an environment value is materialized, and
# afk_env_record is the only thing that can put one near the result model. The
# redactor is indirected through AFK_REDACT_FN so the deterministic gate can
# substitute an identity redactor and prove the value really does reach this
# path — an anti-vacuity control that "the output happens not to contain it"
# cannot give on its own.
#
# AFK_REDACT_FN is assigned UNCONDITIONALLY here, never from the environment:
# an exported AFK_REDACT_FN must not be able to select a bypass at runtime.

afk_redact_value() { # <raw>
  if [[ -n "$1" ]]; then printf '[REDACTED]\n'; else printf '\n'; fi
}

AFK_REDACT_FN=afk_redact_value

afk_env_classification() { # <name>
  case "$1" in
    *TOKEN*|*SECRET*|*PASSWORD*|*CREDENTIAL*|*API_KEY*|*AUTHORIZATION*)
      printf 'SECRET_BEARING\n' ;;
    *)
      printf 'CONFIGURATION\n' ;;
  esac
}

afk_env_value() { # <name>
  local n="$1"
  printf '%s\n' "${!n-}"
}

afk_env_record() { # <name> -> one JSON object
  local n="$1" raw cls present red
  raw="$(afk_env_value "$n")"
  cls="$(afk_env_classification "$n")"
  if [[ -n "$raw" ]]; then present=true; else present=false; fi
  red="$("$AFK_REDACT_FN" "$raw")"
  jq -nc --arg name "$n" --argjson present "$present" --arg cls "$cls" --arg red "$red" \
    '{name: $name,
      present: $present,
      classification: $cls,
      value: (if $red == "" then null else $red end),
      value_emitted: false}'
}

# Caller-supplied text is diagnostic INPUT, never trusted content: a mistyped
# export puts a credential on the command line, and a credential is not
# distinguishable from a typo by shape. So only words from the closed command
# and option vocabulary are ever echoed back; everything else is replaced.
# The usage text printed alongside lists what the command does accept, which is
# the part that actually helps.
#
# The VALUES of --approve-plan, --stamp, --target and --register are
# deliberately not echoable either: they are positionally values, and the
# closed vocabulary is the only thing that ever reaches a diagnostic.
afk_safe_diagnostic() { # <raw>
  case "$1" in
    status|adopt|update|verify|schema|monitor|help|paperclip-poll)
      printf '%s' "$1" ;;
    -h|--help|--json|--inspect|--plan|--apply|--approve-plan|--require-source-eligible|--allow-noncanonical-source|--allow-rollback|--live|--synthetic-route|--stamp|--target|--register|--reconcile|--cleanup)
      printf '%s' "$1" ;;
    '')
      printf '<empty argument>' ;;
    -*)
      printf '<unrecognized option>' ;;
    *)
      printf '<unrecognized argument>' ;;
  esac
}

# --- normalized result model ------------------------------------------------
#
# Human and machine output are rendered from ONE accumulated model. The human
# renderer reads the same JSON document the --json flag prints, so the two can
# never drift apart.

AFK_COMPONENTS=""
AFK_FINDINGS=""
AFK_TARGETS=""
AFK_ADAPTATIONS=""

AFK_R_COMMAND=""
AFK_R_CHECKOUT="{}"
AFK_R_INSTALLED="{}"
AFK_R_SOURCE="{}"
AFK_R_READINESS="{}"
AFK_R_LIVE="{}"
AFK_R_ENV="[]"
AFK_R_EXTRA="{}"
AFK_R_OPERATION='{"id": null, "mutating": false}'
AFK_R_REQUIRE_SOURCE="false"
AFK_R_FORCED_EXIT=""
AFK_R_NEXT_ACTION=""

afk_result_reset() {
  AFK_COMPONENTS=""
  AFK_FINDINGS=""
  AFK_TARGETS=""
  AFK_ADAPTATIONS=""
}

afk_c_reset() {
  C_ID=""; C_OWNERSHIP=""; C_DEST=""; C_STATE=""; C_REASON=""
  C_SEVERITY="info"; C_SCOPES=""; C_PROVENANCE="HASH_COMPARISON"
  C_EXPECTED=""; C_OBSERVED=""; C_ADAPTATION=""; C_CRITICAL="false"
  C_MUTATION_SAFE="true"; C_DETAIL=""
}

afk_f_reset() {
  F_COMPONENT=""; F_OWNERSHIP=""; F_STATE=""; F_REASON=""; F_SEVERITY="warning"
  F_SCOPES=""; F_PROVENANCE="HASH_COMPARISON"; F_EXPECTED=""; F_OBSERVED=""
  F_MUTATION_SAFE="true"; F_TRANSIENT="false"; F_DETAIL=""
}

# --- the published reason vocabulary ---------------------------------------
#
# This list is the authority for the read-only half of the surface;
# afk_mutation_reason_codes in afk-mutate.sh is the authority for the mutating
# half, afk_readiness_reason_codes in afk-readiness.sh for the scoped readiness
# half, and afk_monitor_reason_codes in afk-monitor.sh for the dispatch watch
# and settlement half. `schema` publishes all four verbatim, the contract
# document repeats them in a machine-checkable block, and the deterministic
# gates prove they agree and that every code carries a real message and a real
# action.

afk_reason_codes() {
  cat <<'CODES'
INSTALLATION_NOT_ADOPTED
STATE_SCHEMA_UNRECOGNIZED
STATE_SCHEMA_UNKNOWN_MAJOR
STATE_SCHEMA_MIGRATION_REQUIRED
STATE_MANIFEST_SHAPE_INVALID
STATE_MANIFEST_PATH_UNSAFE
OPERATION_INTERRUPTED
OPERATION_JOURNAL_UNREADABLE
OPERATION_JOURNAL_PATH_UNSAFE
SOURCE_NOT_A_GIT_CHECKOUT
SOURCE_REPOSITORY_UNIDENTIFIED
SOURCE_REPOSITORY_MISMATCH
SOURCE_DECLARATION_UNREADABLE
SOURCE_DECLARATION_INCOMPLETE
SOURCE_MANAGED_INPUT_MISSING
SOURCE_MANAGED_INPUT_DIRTY
SOURCE_DIRT_OUTSIDE_INPUT_SET
SOURCE_DETACHED_HEAD
SOURCE_NONCANONICAL_BRANCH
SOURCE_DOWNGRADE_REQUIRES_INTENT
SOURCE_REVISION_UNEXPECTED
APPLIED_REVISION_UNREACHABLE
SOURCE_LIFECYCLE_SCHEMA_INCOMPATIBLE
SOURCE_REVISION_FORMAT_UNSUPPORTED
SOURCE_INELIGIBLE
COMPONENT_MISSING
COMPONENT_NOT_RECORDED
CANONICAL_REVISION_AHEAD
CANONICAL_IDENTITY_UNREADABLE
UNEXPLAINED_MANAGED_DIFFERENCE
REGISTERED_ADAPTATION
ADAPTATION_OWNER_REVIEW
ADAPTATION_STALE
ADAPTATION_MALFORMED
ADAPTATION_DUPLICATE_ID
ADAPTATION_UNKNOWN_COMPONENT
ADAPTATION_INVALID_DISPOSITION
ADAPTATION_TYPE_MISMATCH
ADAPTATION_LOCATION_MISMATCH
ADAPTATION_EXPECTED_SHAPE_INVALID
ADAPTATION_TARGET_UNOBSERVABLE
MACHINE_OWNED_REGION
USER_OWNED_REGION
NOT_ADOPTED
IDENTITY_UNREADABLE
LINK_TARGET_MISSING
LINK_TARGET_UNEXPECTED
MANAGED_SECTION_ABSENT
MANAGED_SECTION_MARKERS_MALFORMED
TARGET_PATH_MISSING
PATH_ABSENT
PATH_UNEXPECTED_SYMLINK
PATH_NOT_A_SYMLINK
PATH_TYPE_MISMATCH
PATH_UNRESOLVABLE_SYMLINK
PATH_ESCAPES_OWNERSHIP_BOUNDARY
PATH_PARENT_UNRESOLVABLE
PATH_PARENT_ESCAPES_BOUNDARY
PATH_BOUNDARY_UNRESOLVABLE
LIVE_PROBE_NOT_REQUESTED
NO_EXECUTION_STAMP_SUPPLIED
TARGET_READINESS_NOT_EVALUATED
EXACT_CANONICAL
RECOGNIZED_PRIOR_CANONICAL
EXACT_RECOGNIZED_WIRING
UNRECOGNIZED_CONTENT
ADOPTION_NOT_APPLICABLE_ALREADY_ADOPTED
ADOPTION_SOURCE_INELIGIBLE
CODES
}

AFK_REASON_FALLBACK='See the lifecycle contract for this reason code.'

# The readiness and dispatch-monitor halves of the vocabulary live with the
# engines that emit them, so a code, its message and its required action are
# added in one place. Each hook is consulted BEFORE the local table and prints
# nothing for a code it does not own, which keeps the fallback the single
# "unknown code" answer rather than several competing ones.
afk_reason_message() { # <reason>
  local ext
  if declare -F afk_readiness_reason_message >/dev/null 2>&1; then
    ext="$(afk_readiness_reason_message "$1")"
    if [[ -n "$ext" ]]; then printf '%s' "$ext"; return 0; fi
  fi
  if declare -F afk_monitor_reason_message >/dev/null 2>&1; then
    ext="$(afk_monitor_reason_message "$1")"
    if [[ -n "$ext" ]]; then printf '%s' "$ext"; return 0; fi
  fi
  if declare -F afk_pm_reason_message >/dev/null 2>&1; then
    ext="$(afk_pm_reason_message "$1")"
    if [[ -n "$ext" ]]; then printf '%s' "$ext"; return 0; fi
  fi
  case "$1" in
    INSTALLATION_NOT_ADOPTED)          printf 'No agent-flow-kit state manifest exists, so no installed component has a proven owner or baseline.' ;;
    STATE_SCHEMA_UNRECOGNIZED)         printf 'The state manifest does not present a recognizable versioned shape.' ;;
    STATE_SCHEMA_UNKNOWN_MAJOR)        printf 'The state manifest declares a newer major schema than this lifecycle understands.' ;;
    STATE_SCHEMA_MIGRATION_REQUIRED)   printf 'The state manifest uses a recognized older schema that must be migrated before mutation.' ;;
    STATE_MANIFEST_SHAPE_INVALID)      printf 'The state manifest is missing required members or presents them with the wrong type, so it cannot be read as an ownership record.' ;;
    STATE_MANIFEST_PATH_UNSAFE)        printf 'The state manifest path is redirected or is not a regular file inside the declared state directory.' ;;
    OPERATION_INTERRUPTED)             printf 'An operation journal is open, so the installation is mid-transaction rather than stably healthy.' ;;
    OPERATION_JOURNAL_UNREADABLE)      printf 'An operation journal exists but cannot be parsed, so no operation can be proven complete.' ;;
    OPERATION_JOURNAL_PATH_UNSAFE)     printf 'The operation journal path is redirected or is not a regular file inside the declared state directory.' ;;
    COMPONENT_MISSING)                 printf 'A component recorded in the manifest is absent from its managed destination.' ;;
    COMPONENT_NOT_RECORDED)            printf 'A component is installed but the manifest records no applied identity for it.' ;;
    CANONICAL_REVISION_AHEAD)          printf 'The canonical checkout carries newer content than the applied identity.' ;;
    CANONICAL_IDENTITY_UNREADABLE)     printf 'The canonical source content for this component could not be read, so nothing can be verified against it.' ;;
    UNEXPLAINED_MANAGED_DIFFERENCE)    printf 'Kit-owned content differs from its applied identity and no valid registered adaptation explains it.' ;;
    REGISTERED_ADAPTATION)             printf 'A registered adaptation explains this local difference.' ;;
    ADAPTATION_OWNER_REVIEW)           printf 'A registered adaptation declares the OWNER_REVIEW disposition, so convergence needs a decision.' ;;
    ADAPTATION_STALE)                  printf 'A registered adaptation no longer matches the shape it declares, so it legitimizes nothing.' ;;
    ADAPTATION_MALFORMED)              printf 'An adaptation record is missing required fields.' ;;
    ADAPTATION_DUPLICATE_ID)           printf 'Two adaptation records declare the same id, so neither identifies a single exception.' ;;
    ADAPTATION_UNKNOWN_COMPONENT)      printf 'An adaptation record names a component this lifecycle does not declare.' ;;
    ADAPTATION_INVALID_DISPOSITION)    printf 'An adaptation record declares an unsupported update disposition.' ;;
    ADAPTATION_TYPE_MISMATCH)          printf 'An adaptation record declares a type that does not belong to its component ownership class.' ;;
    ADAPTATION_LOCATION_MISMATCH)      printf 'An adaptation record declares a location that is not the declared location of its component.' ;;
    ADAPTATION_EXPECTED_SHAPE_INVALID) printf 'An adaptation record declares an expected identity that is not a well-formed identifier for its type.' ;;
    ADAPTATION_TARGET_UNOBSERVABLE)    printf 'An adaptation record cannot be revalidated because its component could not be observed.' ;;
    ADAPTATION_REEVALUATION_REQUIRED)  printf 'A registered adaptation declares the REEVALUATE disposition and its canonical content has moved, which is exactly the condition it declared it wanted to be reconsidered on.' ;;
    MACHINE_OWNED_REGION)              printf 'This destination is declared machine-owned, so local values are legitimate by ownership rule.' ;;
    USER_OWNED_REGION)                 printf 'Content outside the managed section is user-owned and is neither claimed nor compared.' ;;
    NOT_ADOPTED)                       printf 'Ownership of this destination has never been established.' ;;
    IDENTITY_UNREADABLE)               printf 'The managed destination could not be read to compute an identity.' ;;
    LINK_TARGET_MISSING)               printf 'A managed link resolves to a destination that does not exist.' ;;
    LINK_TARGET_UNEXPECTED)            printf 'A managed link resolves somewhere other than its declared target.' ;;
    MANAGED_SECTION_ABSENT)            printf 'The managed section is not present in its host file.' ;;
    MANAGED_SECTION_MARKERS_MALFORMED) printf 'The managed section markers are duplicated, unterminated, or out of order.' ;;
    PATH_ABSENT)                       printf 'The managed destination does not exist.' ;;
    PATH_UNEXPECTED_SYMLINK)           printf 'The managed destination is a symlink where a real file or directory is declared.' ;;
    PATH_NOT_A_SYMLINK)                printf 'A declared managed link is not a symlink.' ;;
    PATH_TYPE_MISMATCH)                printf 'The managed destination is not the declared path type.' ;;
    PATH_UNRESOLVABLE_SYMLINK)         printf 'A symlink on the managed path could not be resolved.' ;;
    PATH_ESCAPES_OWNERSHIP_BOUNDARY)   printf 'A symlink redirects the managed path outside its declared ownership boundary.' ;;
    PATH_PARENT_UNRESOLVABLE)          printf 'A directory on the managed path could not be resolved, so containment cannot be proven.' ;;
    PATH_PARENT_ESCAPES_BOUNDARY)      printf 'A parent directory of the managed path is redirected outside its declared ownership boundary.' ;;
    PATH_BOUNDARY_UNRESOLVABLE)        printf 'A declared ownership boundary could not be resolved to an existing directory, so containment cannot be proven.' ;;
    TARGET_PATH_MISSING)               printf 'A registered BMAD target path is absent.' ;;
    SOURCE_NOT_A_GIT_CHECKOUT)         printf 'The configured source is not a Git checkout, so no revision can be proven.' ;;
    SOURCE_REPOSITORY_UNIDENTIFIED)    printf 'The source presents no readable agent-flow-kit declaration; directory naming is not evidence of identity.' ;;
    SOURCE_REPOSITORY_MISMATCH)        printf 'The source repository identity differs from the identity this installation was adopted from.' ;;
    SOURCE_DECLARATION_UNREADABLE)     printf 'The source declaration lifecycle/kit.json is not readable JSON.' ;;
    SOURCE_DECLARATION_INCOMPLETE)     printf 'The source declaration does not present the complete recognized shape: kit identity, lifecycle and state schema versions, default branch and managed inputs.' ;;
    SOURCE_MANAGED_INPUT_MISSING)      printf 'A declared managed input path is absent from the source checkout.' ;;
    SOURCE_MANAGED_INPUT_DIRTY)        printf 'The source checkout has uncommitted content inside the declared managed input set.' ;;
    SOURCE_DIRT_OUTSIDE_INPUT_SET)     printf 'The source checkout is dirty outside the declared managed input set.' ;;
    SOURCE_DETACHED_HEAD)              printf 'The source checkout is on a detached HEAD rather than a recognized canonical branch.' ;;
    SOURCE_NONCANONICAL_BRANCH)        printf 'The source checkout is not on the declared canonical branch.' ;;
    SOURCE_DOWNGRADE_REQUIRES_INTENT)  printf 'The source revision is older than the applied revision, which is a rollback rather than an update.' ;;
    SOURCE_REVISION_UNEXPECTED)        printf 'The source revision neither contains nor descends from the applied revision.' ;;
    SOURCE_INELIGIBLE)                 printf 'This checkout is not currently eligible as a mutation source.' ;;
    APPLIED_REVISION_UNREACHABLE)      printf 'The applied revision is not reachable from this checkout, so no change can be computed.' ;;
    SOURCE_LIFECYCLE_SCHEMA_INCOMPATIBLE) printf 'The source declares a lifecycle schema major version this executable does not implement.' ;;
    SOURCE_REVISION_FORMAT_UNSUPPORTED) printf 'The source revision is not the 40-character lowercase hex object name this lifecycle records as an applied revision, so nothing computed from it could ever be committed.' ;;
    LIVE_PROBE_NOT_REQUESTED)          printf 'No live evaluation was requested, so this external fact was not probed.' ;;
    NO_EXECUTION_STAMP_SUPPLIED)       printf 'No execution stamp was supplied, so route readiness is outside this command scope.' ;;
    TARGET_READINESS_NOT_EVALUATED)    printf 'No registered BMAD target was evaluated for this scope.' ;;
    ADOPTION_NOT_APPLICABLE_ALREADY_ADOPTED) printf 'This installation already has an established manifest, so adoption analysis does not apply.' ;;
    ADOPTION_SOURCE_INELIGIBLE)        printf 'Adoption records a canonical revision, so an ineligible mutation source cannot be adopted from.' ;;
    UNRECOGNIZED_CONTENT)              printf 'Installed content matches no canonical or recognized prior revision, so ownership cannot be claimed mechanically.' ;;
    EXACT_CANONICAL)                   printf 'Installed content is byte-identical to current canonical content.' ;;
    RECOGNIZED_PRIOR_CANONICAL)        printf 'Installed content is byte-identical to a reachable prior canonical revision.' ;;
    EXACT_RECOGNIZED_WIRING)           printf 'The managed link already resolves exactly to its declared target.' ;;
    PLAN_NO_CHANGE_REQUIRED)           printf 'The computed plan requires no mutation: the installation already carries the target revision.' ;;
    PLAN_NOT_COMPUTABLE)               printf 'A complete deterministic plan could not be computed, so nothing was attempted.' ;;
    PLAN_STALE_SOURCE_CHANGED)         printf 'The canonical source moved between computing the plan and the mutation boundary, so the plan no longer describes this operation.' ;;
    PLAN_STALE_MANIFEST_CHANGED)       printf 'The installed-state manifest or a registered adaptation changed between computing the plan and the mutation boundary.' ;;
    PLAN_STALE_DESTINATION_CHANGED)    printf 'A managed destination changed between computing the plan and the write it was planned for.' ;;
    PLAN_APPROVAL_REQUIRED)            printf 'This plan crosses an ambiguity or ownership boundary, so it authorizes nothing until its exact identity is approved.' ;;
    PLAN_APPROVAL_MISMATCH)            printf 'The supplied approval names a different plan than the one just computed, so it does not authorize this operation.' ;;
    PLAN_COMPONENT_CONFLICT)           printf 'At least one component in the plan is blocked, and a partial convergence is never performed.' ;;
    COMPONENT_NOT_INSTALLED)           printf 'The declared destination does not exist, so there is nothing installed to own or compare.' ;;
    CONCURRENT_OPERATION_IN_PROGRESS)  printf 'Another lifecycle operation holds the installation lock, so this one is not started rather than interleaved with it.' ;;
    OPERATION_LOCK_UNAVAILABLE)        printf 'The installation lock could not be established, so no mutation was attempted.' ;;
    BACKUP_PREREQUISITE_UNMET)         printf 'The required recovery material could not be created, so no managed write was attempted.' ;;
    PERMISSION_PREREQUISITE_UNMET)     printf 'A declared destination directory is not writable, so the planned write cannot be performed transactionally.' ;;
    MANAGED_WRITE_FAILED)              printf 'A planned managed write failed, so the transaction was stopped and restored.' ;;
    POST_WRITE_IDENTITY_MISMATCH)      printf 'A completed write did not produce the identity the plan predicted, so the result is not the planned state.' ;;
    OUTSIDE_CONTENT_NOT_PRESERVED)     printf 'A managed-section write would not have preserved the user-owned content around it, so it was rejected.' ;;
    OPERATION_ROLLED_BACK)             printf 'The operation failed and every change it made was restored and verified; the applied revision did not move.' ;;
    OPERATION_ROLLBACK_INCOMPLETE)     printf 'The operation failed and restoration could not be completed, so the installation needs its owner.' ;;
    OPERATION_RECOVERED)               printf 'An interrupted operation was detected and deterministically rolled back before any new mutation.' ;;
    STATE_MANIFEST_WRITE_FAILED)       printf 'The applied-state manifest could not be committed, so the target revision was never claimed.' ;;
    DESTINATION_METADATA_NOT_PRESERVED) printf 'A managed write would not have preserved the destination file mode or ownership the host had set, so it was rejected.' ;;
    OPERATION_JOURNAL_SCHEMA_UNSUPPORTED) printf 'The recovery journal declares a schema major version this executable does not implement, so its records cannot be read as recovery authority.' ;;
    OPERATION_RECOVERY_AUTHORITY_INSUFFICIENT) printf 'The recovery journal does not prove what an interrupted step is authorized to restore, so the journal is treated as evidence rather than as authority to change anything.' ;;
    OPERATION_RECOVERY_VERIFICATION_FAILED) printf 'A restoration performed during interrupted-operation recovery could not be proven to have reproduced the recorded pre-mutation state.' ;;
    OPERATION_LOCK_OWNER_UNVERIFIABLE) printf 'An installation lock exists whose owner cannot be proven either alive or dead on this host, so it is neither waited on nor reclaimed.' ;;
    OPERATION_LOCK_RECLAIMED)          printf 'An installation lock was left by a process this host can prove is no longer running, so it was reclaimed before this operation.' ;;
    VERIFICATION_PASSED)               printf 'Offline verification proved the installed state against the applied-state manifest.' ;;
    VERIFICATION_FAILED)               printf 'Offline verification could not prove the installed state against the applied-state manifest.' ;;
    *)                                 printf '%s' "$AFK_REASON_FALLBACK" ;;
  esac
}

afk_reason_action() { # <reason>
  local ext
  if declare -F afk_readiness_reason_action >/dev/null 2>&1; then
    ext="$(afk_readiness_reason_action "$1")"
    if [[ -n "$ext" ]]; then printf '%s' "$ext"; return 0; fi
  fi
  if declare -F afk_monitor_reason_action >/dev/null 2>&1; then
    ext="$(afk_monitor_reason_action "$1")"
    if [[ -n "$ext" ]]; then printf '%s' "$ext"; return 0; fi
  fi
  if declare -F afk_pm_reason_action >/dev/null 2>&1; then
    ext="$(afk_pm_reason_action "$1")"
    if [[ -n "$ext" ]]; then printf '%s' "$ext"; return 0; fi
  fi
  case "$1" in
    INSTALLATION_NOT_ADOPTED)          printf 'Run: agent-flow-kit adopt --inspect' ;;
    STATE_SCHEMA_UNRECOGNIZED|STATE_SCHEMA_UNKNOWN_MAJOR|STATE_MANIFEST_SHAPE_INVALID) \
                                       printf 'Owner decision required: this manifest cannot be interpreted safely by this version.' ;;
    STATE_SCHEMA_MIGRATION_REQUIRED)   printf 'Migrate the manifest through the declared migration path before mutating.' ;;
    STATE_MANIFEST_PATH_UNSAFE|OPERATION_JOURNAL_PATH_UNSAFE) \
                                       printf 'Inspect the state directory by hand: the lifecycle refuses to read kit state through unexpected redirection.' ;;
    OPERATION_INTERRUPTED|OPERATION_JOURNAL_UNREADABLE) \
                                       printf 'Resolve the open operation journal before any new lifecycle mutation.' ;;
    COMPONENT_MISSING)                 printf 'Reinstall the component through the lifecycle rather than by hand.' ;;
    COMPONENT_NOT_RECORDED)            printf 'Re-establish ownership for this component through adoption.' ;;
    CANONICAL_REVISION_AHEAD)          printf 'Update from an eligible canonical checkout.' ;;
    CANONICAL_IDENTITY_UNREADABLE)     printf 'Restore the canonical source content, or point the lifecycle at a complete checkout.' ;;
    UNEXPLAINED_MANAGED_DIFFERENCE)    printf 'Restore the canonical content, or register the difference as an explicit adaptation.' ;;
    ADAPTATION_OWNER_REVIEW)           printf 'Review the declared adaptation and decide its disposition.' ;;
    ADAPTATION_REEVALUATION_REQUIRED)  printf 'Reevaluate the declared adaptation against the new canonical content, then update or withdraw the record.' ;;
    ADAPTATION_STALE|ADAPTATION_MALFORMED|ADAPTATION_DUPLICATE_ID|ADAPTATION_UNKNOWN_COMPONENT|ADAPTATION_INVALID_DISPOSITION|ADAPTATION_TYPE_MISMATCH|ADAPTATION_LOCATION_MISMATCH|ADAPTATION_EXPECTED_SHAPE_INVALID|ADAPTATION_TARGET_UNOBSERVABLE) \
                                       printf 'Correct or withdraw the adaptation record; it cannot legitimize a difference in its current form.' ;;
    PATH_UNEXPECTED_SYMLINK|PATH_ESCAPES_OWNERSHIP_BOUNDARY|PATH_UNRESOLVABLE_SYMLINK|PATH_NOT_A_SYMLINK|PATH_TYPE_MISMATCH|PATH_PARENT_ESCAPES_BOUNDARY|PATH_PARENT_UNRESOLVABLE|PATH_BOUNDARY_UNRESOLVABLE) \
                                       printf 'Inspect the path by hand: the lifecycle refuses to read or write through unexpected redirection.' ;;
    MANAGED_SECTION_MARKERS_MALFORMED) printf 'Repair the section markers by hand; the lifecycle never guesses section boundaries.' ;;
    MANAGED_SECTION_ABSENT)            printf 'Re-establish the managed section through the lifecycle.' ;;
    SOURCE_MANAGED_INPUT_DIRTY)        printf 'Commit or stash the managed-input changes before using this checkout as a mutation source.' ;;
    SOURCE_DIRT_OUTSIDE_INPUT_SET)     printf 'No action required for mutation; this dirt cannot influence installed output.' ;;
    SOURCE_DETACHED_HEAD|SOURCE_NONCANONICAL_BRANCH|SOURCE_REVISION_UNEXPECTED) \
                                       printf 'Select a canonical revision, or re-run with --allow-noncanonical-source to record explicit intent.' ;;
    SOURCE_DOWNGRADE_REQUIRES_INTENT)  printf 'Re-run with --allow-rollback to record explicit rollback intent.' ;;
    SOURCE_REPOSITORY_MISMATCH|SOURCE_REPOSITORY_UNIDENTIFIED|SOURCE_NOT_A_GIT_CHECKOUT|SOURCE_MANAGED_INPUT_MISSING|SOURCE_DECLARATION_UNREADABLE|SOURCE_DECLARATION_INCOMPLETE) \
                                       printf 'Point the lifecycle at a checkout whose repository identity and declaration are provable.' ;;
    SOURCE_LIFECYCLE_SCHEMA_INCOMPATIBLE) printf 'Install a lifecycle executable that implements the source schema major version.' ;;
    SOURCE_REVISION_FORMAT_UNSUPPORTED) printf 'Use a checkout whose object names are 40-character lowercase hex, or install a lifecycle executable that records this object format.' ;;
    SOURCE_INELIGIBLE)                 printf 'Make this checkout an eligible mutation source, then re-run the operation.' ;;
    TARGET_PATH_MISSING)               printf 'Re-register or restore the target repository path.' ;;
    LINK_TARGET_MISSING|LINK_TARGET_UNEXPECTED) printf 'Repoint the managed link at its declared target.' ;;
    ADOPTION_SOURCE_INELIGIBLE)        printf 'Make this checkout an eligible source, then re-run the adoption analysis.' ;;
    LIVE_PROBE_NOT_REQUESTED)          printf 'Re-run with --live to evaluate this external fact under a bounded, non-mutating probe.' ;;
    NO_EXECUTION_STAMP_SUPPLIED)       printf 'Re-run with --stamp <path> to evaluate route readiness for one accepted decision.' ;;
    TARGET_READINESS_NOT_EVALUATED)    printf 'Register a BMAD target in the state manifest to have its wiring evaluated.' ;;
    PLAN_NO_CHANGE_REQUIRED)           printf 'Nothing to do: the installation already carries this revision.' ;;
    PLAN_NOT_COMPUTABLE)               printf 'Resolve the findings above; a plan that cannot be computed is never approximated.' ;;
    PLAN_STALE_SOURCE_CHANGED|PLAN_STALE_MANIFEST_CHANGED|PLAN_STALE_DESTINATION_CHANGED) \
                                       printf 'Re-run the command: the plan is recomputed from current state, and an old approval never carries over.' ;;
    PLAN_APPROVAL_REQUIRED)            printf 'Review the plan, then re-run with --approve-plan <plan identity> to authorize exactly that plan.' ;;
    PLAN_APPROVAL_MISMATCH)            printf 'Review the newly computed plan and approve its identity; the previous approval is not transferable.' ;;
    PLAN_COMPONENT_CONFLICT)           printf 'Resolve the blocked components above; the lifecycle never converges part of a plan.' ;;
    COMPONENT_NOT_INSTALLED)           printf 'Run an update to install the component through the lifecycle.' ;;
    CONCURRENT_OPERATION_IN_PROGRESS)  printf 'Wait for the operation in progress to finish, then re-run.' ;;
    OPERATION_LOCK_UNAVAILABLE)        printf 'Check that the declared state directory is writable, then re-run.' ;;
    BACKUP_PREREQUISITE_UNMET)         printf 'Make the declared state directory writable so recovery material can be created before any write.' ;;
    PERMISSION_PREREQUISITE_UNMET)     printf 'Grant write access to the declared destination directory, then re-run.' ;;
    MANAGED_WRITE_FAILED|POST_WRITE_IDENTITY_MISMATCH|OUTSIDE_CONTENT_NOT_PRESERVED) \
                                       printf 'Re-run after resolving the reported component; the attempted change was restored.' ;;
    OPERATION_ROLLED_BACK)             printf 'Re-run once the reported cause is resolved; the installation is back at its previous state.' ;;
    OPERATION_ROLLBACK_INCOMPLETE)     printf 'Restore the listed components from the retained backup directory by hand before any further lifecycle operation.' ;;
    OPERATION_RECOVERED)               printf 'Re-run the command: the interrupted operation was rolled back and nothing new was attempted.' ;;
    STATE_MANIFEST_WRITE_FAILED)       printf 'Make the declared state directory writable, then re-run.' ;;
    DESTINATION_METADATA_NOT_PRESERVED) printf 'Re-run after resolving the reported component; the attempted change was restored and the destination kept the mode it had.' ;;
    OPERATION_JOURNAL_SCHEMA_UNSUPPORTED) printf 'Install a lifecycle executable that implements the journal schema major version, or resolve the interrupted operation by hand from the retained journal and backups.' ;;
    OPERATION_RECOVERY_AUTHORITY_INSUFFICIENT|OPERATION_RECOVERY_VERIFICATION_FAILED) \
                                       printf 'Restore the reported destinations by hand from the retained backup directory; the lifecycle never removes a path it cannot prove the interrupted operation created.' ;;
    OPERATION_LOCK_OWNER_UNVERIFIABLE) printf 'Confirm no lifecycle operation is running on this installation, then remove the reported lock directory by hand.' ;;
    OPERATION_LOCK_RECLAIMED)          printf 'No action required: the lock was proven abandoned before it was reclaimed.' ;;
    VERIFICATION_PASSED)               printf 'No action required.' ;;
    VERIFICATION_FAILED)               printf 'Resolve the failing checks above; verification never repairs what it observes.' ;;
    *)                                 printf 'No safe automatic action; see the lifecycle contract.' ;;
  esac
}

afk_reason_impact() { # <severity>
  case "$1" in
    owner_action) printf 'Blocks unattended convergence until an owner decides.' ;;
    blocking)     printf 'Blocks the reported readiness scope deterministically.' ;;
    warning)      printf 'Does not block the reported scope, but is worth acting on.' ;;
    *)            printf 'Informational.' ;;
  esac
}

afk_f_emit() {
  local json msg action impact
  msg="$(afk_reason_message "$F_REASON")"
  action="$(afk_reason_action "$F_REASON")"
  impact="$(afk_reason_impact "$F_SEVERITY")"
  json="$(jq -nc \
    --arg component "$F_COMPONENT" --arg ownership "$F_OWNERSHIP" --arg state "$F_STATE" \
    --arg reason "$F_REASON" --arg severity "$F_SEVERITY" --arg scopes "$F_SCOPES" \
    --arg prov "$F_PROVENANCE" --arg expected "$F_EXPECTED" --arg observed "$F_OBSERVED" \
    --arg mutsafe "$F_MUTATION_SAFE" --arg transient "$F_TRANSIENT" --arg detail "$F_DETAIL" \
    --arg msg "$msg" --arg action "$action" --arg impact "$impact" \
    '{component: (if $component == "" then null else $component end),
      ownership: (if $ownership == "" then null else $ownership end),
      state: $state,
      reason: $reason,
      severity: $severity,
      blocked_scopes: (if $scopes == "" then [] else ($scopes | split(",")) end),
      owner: "agent-flow-kit",
      owner_action_required: ($severity == "owner_action"),
      mutation_safe: ($mutsafe == "true"),
      transient: ($transient == "true"),
      evidence: {provenance: $prov,
                 expected: (if $expected == "" then null else $expected end),
                 observed: (if $observed == "" then null else $observed end)},
      message: $msg,
      impact: $impact,
      required_action: $action,
      detail: (if $detail == "" then null else $detail end)}')" || return 1
  AFK_FINDINGS="${AFK_FINDINGS}${json}"$'\n'
}

afk_add_finding() { # <component> <ownership> <state> <reason> <severity> <scopes> <provenance> [expected] [observed] [mutation_safe] [transient] [detail]
  afk_f_reset
  F_COMPONENT="$1"; F_OWNERSHIP="$2"; F_STATE="$3"; F_REASON="$4"
  F_SEVERITY="$5"; F_SCOPES="$6"; F_PROVENANCE="$7"
  F_EXPECTED="${8:-}"; F_OBSERVED="${9:-}"
  F_MUTATION_SAFE="${10:-true}"; F_TRANSIENT="${11:-false}"; F_DETAIL="${12:-}"
  afk_f_emit
}

afk_c_emit() {
  local json
  json="$(jq -nc \
    --arg id "$C_ID" --arg ownership "$C_OWNERSHIP" --arg dest "$C_DEST" \
    --arg state "$C_STATE" --arg reason "$C_REASON" --arg severity "$C_SEVERITY" \
    --arg scopes "$C_SCOPES" --arg prov "$C_PROVENANCE" --arg expected "$C_EXPECTED" \
    --arg observed "$C_OBSERVED" --arg adaptation "$C_ADAPTATION" --arg critical "$C_CRITICAL" \
    --arg mutsafe "$C_MUTATION_SAFE" --arg detail "$C_DETAIL" \
    '{id: $id,
      ownership: $ownership,
      destination: $dest,
      state: $state,
      reason: (if $reason == "" then null else $reason end),
      severity: $severity,
      blocked_scopes: (if $scopes == "" then [] else ($scopes | split(",")) end),
      owner: "agent-flow-kit",
      owner_action_required: ($severity == "owner_action"),
      mutation_safe: ($mutsafe == "true"),
      execution_critical: ($critical == "true"),
      transient: false,
      adaptation: (if $adaptation == "" then null else $adaptation end),
      evidence: {provenance: $prov,
                 expected: (if $expected == "" then null else $expected end),
                 observed: (if $observed == "" then null else $observed end)},
      detail: (if $detail == "" then null else $detail end)}')" || return 1
  AFK_COMPONENTS="${AFK_COMPONENTS}${json}"$'\n'
  if [[ "$C_SEVERITY" != "info" ]]; then
    afk_f_reset
    F_COMPONENT="$C_ID"; F_OWNERSHIP="$C_OWNERSHIP"; F_STATE="$C_STATE"; F_REASON="$C_REASON"
    F_SEVERITY="$C_SEVERITY"; F_SCOPES="$C_SCOPES"; F_PROVENANCE="$C_PROVENANCE"
    F_EXPECTED="$C_EXPECTED"; F_OBSERVED="$C_OBSERVED"; F_MUTATION_SAFE="$C_MUTATION_SAFE"
    F_DETAIL="$C_DETAIL"; F_TRANSIENT="false"
    afk_f_emit
  fi
}

afk_add_target() { # <id> <path> <state> <reason> <severity> <scopes>
  local json
  json="$(jq -nc --arg id "$1" --arg path "$2" --arg state "$3" --arg reason "$4" \
    --arg severity "$5" --arg scopes "$6" \
    '{id: $id,
      path: $path,
      ownership: "TARGET_WIRING",
      state: $state,
      reason: (if $reason == "" then null else $reason end),
      severity: $severity,
      blocked_scopes: (if $scopes == "" then [] else ($scopes | split(",")) end),
      owner: "agent-flow-kit"}')" || return 1
  AFK_TARGETS="${AFK_TARGETS}${json}"$'\n'
}

afk_add_adaptation() { # <json object>
  AFK_ADAPTATIONS="${AFK_ADAPTATIONS}${1}"$'\n'
}

afk_ndjson_to_array() { # <ndjson text>
  printf '%s' "$1" | jq -sc '.'
}

# afk_build_result — assemble the one normalized model and derive overall state,
# exit code and next safe action from it. Nothing downstream re-decides these.
#
# Inputs come from AFK_R_* globals so a caller never has to keep ten positional
# arguments in the right order. Every stage is checked: a partially assembled
# document is never printed and never becomes an exit code.
afk_build_result() {
  local components findings targets adaptations doc
  components="$(afk_ndjson_to_array "$AFK_COMPONENTS")" || return 1
  findings="$(afk_ndjson_to_array "$AFK_FINDINGS")" || return 1
  targets="$(afk_ndjson_to_array "$AFK_TARGETS")" || return 1
  adaptations="$(afk_ndjson_to_array "$AFK_ADAPTATIONS")" || return 1

  doc="$(jq -nc \
    --arg schema "$AFK_RESULT_SCHEMA_VERSION" \
    --arg command "$AFK_R_COMMAND" \
    --argjson operation "$AFK_R_OPERATION" \
    --argjson checkout "$AFK_R_CHECKOUT" \
    --argjson installed "$AFK_R_INSTALLED" \
    --argjson source "$AFK_R_SOURCE" \
    --argjson readiness "$AFK_R_READINESS" \
    --argjson live "$AFK_R_LIVE" \
    --argjson orchestration "$AFK_R_ORCHESTRATION" \
    --argjson dispatch "$AFK_R_DISPATCH" \
    --argjson env "$AFK_R_ENV" \
    --argjson extra "$AFK_R_EXTRA" \
    --argjson components "$components" \
    --argjson findings "$findings" \
    --argjson targets "$targets" \
    --argjson adaptations "$adaptations" \
    --arg require_source "$AFK_R_REQUIRE_SOURCE" \
    --arg forced_exit "$AFK_R_FORCED_EXIT" \
    --arg forced_action "$AFK_R_NEXT_ACTION" \
    --arg exit_ok "$AFK_EXIT_OK" \
    --arg exit_owner "$AFK_EXIT_OWNER_ACTION" \
    --arg exit_not_ready "$AFK_EXIT_NOT_READY" \
    --arg exit_source "$AFK_EXIT_SOURCE_REFUSED" \
    '
    {schema_version: $schema,
     kind: "lifecycle_result",
     command: $command,
     operation: $operation,
     checkout: $checkout,
     installed: $installed,
     source_eligibility: $source,
     readiness: $readiness,
     live_facts: $live,
     orchestration: $orchestration,
     dispatch_monitor: $dispatch,
     environment: $env,
     components: $components,
     targets: $targets,
     adaptations: $adaptations,
     findings: $findings,
     extra: $extra}
    | . as $r
    | ($r.findings | map(select(.blocked_scopes | index("INSTALLED_INTEGRITY")))) as $blk
    | (if   ($blk | map(select(.severity == "owner_action")) | length) > 0 then "NEEDS_OWNER"
       elif ($blk | map(select(.severity == "blocking"))     | length) > 0 then "NOT_READY"
       elif ($r.findings | map(select(.severity != "info")) | length) > 0 then "READY_WITH_WARNINGS"
       elif ($r.components | map(select(.state == "LOCAL_ADAPTATION" and .reason == "REGISTERED_ADAPTATION")) | length) > 0 then "READY_WITH_ADAPTATION"
       else "READY" end) as $state
    | .overall = {state: $state}
    | .overall.exit_code = (
        if   $forced_exit != "" then ($forced_exit | tonumber)
        elif $state == "NEEDS_OWNER" then ($exit_owner | tonumber)
        elif $state == "NOT_READY" then ($exit_not_ready | tonumber)
        elif ($require_source == "true" and .source_eligibility.mutation_allowed == false) then ($exit_source | tonumber)
        else ($exit_ok | tonumber) end)
    | .next_safe_action = (
        if   $forced_action != "" then $forced_action
        elif $state == "NEEDS_OWNER" then "Resolve the owner-action findings above; no mutating lifecycle operation is safe until they clear."
        elif .installed.adopted == false then "Run: agent-flow-kit adopt --inspect"
        elif $state == "NOT_READY" then "Repair the blocking components above; status changed nothing and is safe to re-run."
        elif ([.components[] | select(.state == "UPDATE_AVAILABLE")] | length) > 0 then
          (if .source_eligibility.mutation_allowed
             then "Canonical content is ahead: converge from this eligible checkout."
             else "Canonical content is ahead, but this checkout is not an eligible mutation source." end)
        else "No action required." end)
    ')" || return 1
  [[ -n "$doc" ]] || return 1
  printf '%s' "$doc"
}

# afk_result_is_well_formed <document> — the shape automation is promised.
# A document that fails this is an internal failure, never an exit code derived
# from a half-built model.
afk_result_is_well_formed() {
  local ok
  ok="$(printf '%s' "$1" | jq -r '
    if (type == "object")
       and (.kind == "lifecycle_result")
       and (.schema_version | type == "string")
       and (.command | type == "string")
       and (.operation | type == "object")
       and (.checkout | type == "object")
       and (.installed | type == "object")
       and (.source_eligibility | type == "object")
       and (.readiness | type == "object")
       and (.live_facts | type == "object")
       and (.orchestration | type == "object")
       and (.dispatch_monitor | type == "object")
       and (.environment | type == "array")
       and (.components | type == "array")
       and (.targets | type == "array")
       and (.adaptations | type == "array")
       and (.findings | type == "array")
       and (.overall | type == "object")
       and (.overall.state | type == "string")
       and (.overall.exit_code | type == "number")
       and (.next_safe_action | type == "string")
    then "yes" else "no" end' 2>/dev/null)" || return 1
  [[ "$ok" == "yes" ]]
}

# --- human rendering --------------------------------------------------------
#
# Rendered FROM the machine document, never alongside it (FR-72). Every part of
# the document that carries a decision is projected, so a reader of the human
# output and a reader of the JSON reach the same conclusions.

AFK_RENDER_DOC=""

afk_render_q() { printf '%s' "$AFK_RENDER_DOC" | jq "$@"; }

afk_render_human() { # <result-json-document>
  AFK_RENDER_DOC="$1"

  printf 'agent-flow-kit %s  (result schema %s)\n' \
    "$(afk_render_q -r '.command')" "$(afk_render_q -r '.schema_version')"
  printf '  checkout path     : %s\n' "$(afk_render_q -r '.checkout.path // "UNKNOWN"')"
  printf '  checkout revision : %s\n' "$(afk_render_q -r '.checkout.revision // "UNKNOWN"')"
  printf '  checkout branch   : %s\n' \
    "$(afk_render_q -r 'if .checkout.detached then "DETACHED" else (.checkout.branch // "UNKNOWN") end')"
  printf '  repository        : %s\n' "$(afk_render_q -r '.checkout.repository_identity // "UNIDENTIFIED"')"
  printf '  declaration       : %s\n' "$(afk_render_q -r '.checkout.declaration')"
  printf '  applied revision  : %s\n' "$(afk_render_q -r '.installed.applied_revision // "NONE"')"
  printf '  installed state   : %s\n' "$(afk_render_q -r '.installed.state')"
  printf '  adopted           : %s\n' "$(afk_render_q -r '.installed.adopted')"
  printf '  journal state     : %s\n' "$(afk_render_q -r '.installed.journal_state')"
  printf '  lock state        : %s\n' "$(afk_render_q -r '.installed.lock_state // "NONE"')"
  printf '  source eligibility: %s (mutation_allowed=%s, revision_relation=%s)\n' \
    "$(afk_render_q -r '.source_eligibility.state')" \
    "$(afk_render_q -r '.source_eligibility.mutation_allowed')" \
    "$(afk_render_q -r '.source_eligibility.revision_relation')"
  if [[ "$(afk_render_q -r '.source_eligibility.reasons | length')" != "0" ]]; then
    afk_render_q -r '.source_eligibility.reasons[] | "    source reason: \(.)"'
  fi

  printf '\n  components\n'
  afk_render_q -r '.components[] |
    "    \(.id)  [\(.ownership)]  \(.state)  \(.reason // "-")\n"
    + "      destination: \(.destination)\n"
    + "      expected=\(.evidence.expected // "-")  observed=\(.evidence.observed // "-")  provenance=\(.evidence.provenance)\n"
    + "      severity=\(.severity)  mutation_safe=\(.mutation_safe)  owner_action_required=\(.owner_action_required)  execution_critical=\(.execution_critical)\n"
    + "      blocked_scopes=\(.blocked_scopes | join(",") | if . == "" then "-" else . end)  adaptation=\(.adaptation // "-")  detail=\(.detail // "-")"'

  printf '\n  registered BMAD targets\n'
  if [[ "$(afk_render_q -r '.targets | length')" == "0" ]]; then
    printf '    (none registered)\n'
  else
    afk_render_q -r '.targets[] |
      "    \(.id)  \(.state)  \(.reason // "-")  \(.path)  blocked_scopes=\(.blocked_scopes | join(",") | if . == "" then "-" else . end)"'
  fi

  printf '\n  registered adaptations\n'
  if [[ "$(afk_render_q -r '.adaptations | length')" == "0" ]]; then
    printf '    (none registered)\n'
  else
    afk_render_q -r '.adaptations[] |
      "    \(.id)  \(.component)  \(.disposition)  \(.state)  \(.validation_reason // "-")"'
  fi

  printf '\n  readiness\n'
  afk_render_q -r '.readiness | to_entries[] |
    "    \(.key): \(.value.state)  evaluated=\(.value.evaluated)  reason=\(.value.reason // "-")"'
  if [[ "$(afk_render_q -r '.readiness.TARGET_READY.targets // [] | length')" != "0" ]]; then
    afk_render_q -r '.readiness.TARGET_READY.targets[] |
      "      TARGET_READY:\(.id) = \(.state)  \(.reason)  \(.path)  wiring=\(.wiring_identity // "-")  detail=\(.detail // "-")"'
  fi
  printf '    ROUTE_READY execution_stamp: %s (placement_selected=%s, launch_authoritative=%s)\n' \
    "$(afk_render_q -r '.readiness.ROUTE_READY.execution_stamp // "-"')" \
    "$(afk_render_q -r '.readiness.ROUTE_READY.placement_selected // false')" \
    "$(afk_render_q -r '.readiness.ROUTE_READY.launch_authoritative // false')"

  printf '\n  live facts (default evaluation performs no live probe)\n'
  afk_render_q -r '.live_facts | to_entries[] |
    "    \(.key): \(.value.state) (\(.value.reason))  evaluated=\(.value.evaluated)"
    + "  observed_at=\(.value.observed_at // "-")  timeout_ms=\(.value.timeout_ms // "-")"
    + "  freshness_s=\(.value.freshness_seconds // "-")  transient=\(.value.transient // false)"
    + "  launch_authoritative=\(.value.launch_authoritative // false)  detail=\(.value.detail // "-")"'

  printf '\n  orchestration (read-only summary; consumed, never owned)\n'
  printf '    state: %s (%s)  evaluated=%s\n' \
    "$(afk_render_q -r '.orchestration.state')" \
    "$(afk_render_q -r '.orchestration.reason')" \
    "$(afk_render_q -r '.orchestration.evaluated')"
  printf '    mode=%s phase=%s task=%s needs_human=%s\n' \
    "$(afk_render_q -r '.orchestration.session.mode // "-"')" \
    "$(afk_render_q -r '.orchestration.session.phase // "-"')" \
    "$(afk_render_q -r '.orchestration.session.task // "-"')" \
    "$(afk_render_q -r '.orchestration.session.needs_human // false')"
  printf '    parent=%s/%s  workers_available=%s\n' \
    "$(afk_render_q -r '.orchestration.parent.role // "-"')" \
    "$(afk_render_q -r '.orchestration.parent.id // "-"')" \
    "$(afk_render_q -r '.orchestration.workers.available // "-"')"
  if [[ "$(afk_render_q -r '.orchestration.workers.by_state // {} | length')" != "0" ]]; then
    afk_render_q -r '.orchestration.workers.by_state | to_entries[] |
      "      workers \(.key)=\(.value)"'
  fi

  printf '\n  dispatch monitor (durable completion watch; provenance-bound cleanup)\n'
  printf '    state: %s (%s)  evaluated=%s\n' \
    "$(afk_render_q -r '.dispatch_monitor.state')" \
    "$(afk_render_q -r '.dispatch_monitor.reason')" \
    "$(afk_render_q -r '.dispatch_monitor.evaluated')"
  printf '    dispatches total=%s watching=%s completed=%s settled=%s degraded=%s unreadable=%s\n' \
    "$(afk_render_q -r '.dispatch_monitor.counts.total // 0')" \
    "$(afk_render_q -r '.dispatch_monitor.counts.watching // 0')" \
    "$(afk_render_q -r '.dispatch_monitor.counts.completed // 0')" \
    "$(afk_render_q -r '.dispatch_monitor.counts.settled // 0')" \
    "$(afk_render_q -r '.dispatch_monitor.counts.degraded // 0')" \
    "$(afk_render_q -r '.dispatch_monitor.counts.unreadable // 0')"
  printf '    pending deliveries=%s  retained terminals=%s worktrees=%s local_branches=%s remote_branches=%s\n' \
    "$(afk_render_q -r '.dispatch_monitor.pending_deliveries // 0')" \
    "$(afk_render_q -r '.dispatch_monitor.retained.terminals // 0')" \
    "$(afk_render_q -r '.dispatch_monitor.retained.worktrees // 0')" \
    "$(afk_render_q -r '.dispatch_monitor.retained.local_branches // 0')" \
    "$(afk_render_q -r '.dispatch_monitor.retained.remote_branches // 0')"
  if [[ "$(afk_render_q -r '.dispatch_monitor.dispatches // [] | length')" != "0" ]]; then
    afk_render_q -r '.dispatch_monitor.dispatches[] |
      "      dispatch \(.id // "-"): \(.state)  acknowledged=\(.acknowledged)  fault=\(.fault // "-")\n"
      + "        cleanup terminal=\((.cleanup.terminal? // "-"))  worktree=\((.cleanup.worktree? // "-"))"
      + "  local_branch=\((.cleanup.local_branch? // "-"))  remote_branch=\((.cleanup.remote_branch? // "-"))"'
  fi
  printf '    required action: %s\n' "$(afk_render_q -r '.dispatch_monitor.required_action // "-"')"

  if [[ "$(afk_render_q -r 'if .extra.pm_budget then "y" else "n" end')" == "y" ]]; then
    printf '\n  coordinator context budget (a PROVIDED observation; the kit measures nothing and launches nothing)\n'
    afk_render_q -r '.extra.pm_budget |
      (def id: if . == null then "-" else "\(.path) \(.sha256)" end;
       "    state: \(.state) (\(.reason // "-"))  needs_human=\(.needs_human)\n"
       + "    window=\(.window_tokens // "-") (\(.window_source))"
       + "  usage=\(.usage_tokens // "-")  ratio=\(.usage_ratio // "-")\n"
       + "    checkpoint=\(.checkpoint_artifact | id)  continuation=\(.continuation_artifact | id)")'
  fi

  if [[ "$(afk_render_q -r 'if .extra.auto_update then "y" else "n" end')" == "y" ]]; then
    printf '\n  auto-update\n'
    afk_render_q -r '.extra.auto_update | (.last_result // {}) as $l |
      "    \(if .enrolled then "enrolled" else "not enrolled" end)  platform=\(.platform)  scheduler=\(.scheduler // "-")\n"
      + "    last result: \($l.state // "-") \($l.reason // "-")  at=\($l.at // "-")  health=\(.health // "-")"
      + (if .update_available then "\n    update available: \($l.remote_revision) (run: agent-flow-kit update)" else "" end)'
  fi

  printf '\n  environment (names and presence only; values are never emitted)\n'
  afk_render_q -r '.environment[] |
    "    \(.name): present=\(.present) [\(.classification)] value=\(.value // "-")"'

  if [[ "$(afk_render_q -r 'if .extra.adoption then "y" else "n" end')" == "y" ]]; then
    printf '\n  adoption analysis: %s (inspect-only, nothing was written)\n' \
      "$(afk_render_q -r '.extra.adoption.disposition')"
    printf '    mutation_performed=%s manifest_created=%s ownership_claimed=%s applied_revision_advanced=%s\n' \
      "$(afk_render_q -r '.extra.adoption.mutation_performed')" \
      "$(afk_render_q -r '.extra.adoption.manifest_created')" \
      "$(afk_render_q -r '.extra.adoption.ownership_claimed')" \
      "$(afk_render_q -r '.extra.adoption.applied_revision_advanced')"
    afk_render_q -r '.extra.adoption.components[] |
      "    \(.id)  \(.classification)  \(.reason // "-")  \(.evidence // "-")"'
  fi

  if [[ "$(afk_render_q -r 'if .extra.plan then "y" else "n" end')" == "y" ]]; then
    printf '\n  plan %s\n' "$(afk_render_q -r '.extra.plan.plan_identity')"
    printf '    disposition=%s required_mutations=%s conflicts=%s approvals_required=%s\n' \
      "$(afk_render_q -r '.extra.plan.disposition')" \
      "$(afk_render_q -r '.extra.plan.required_mutations')" \
      "$(afk_render_q -r '.extra.plan.conflicts')" \
      "$(afk_render_q -r '.extra.plan.approvals_required')"
    printf '    prior_revision=%s target_revision=%s refusal=%s\n' \
      "$(afk_render_q -r '.extra.plan.prior_revision // "NONE"')" \
      "$(afk_render_q -r '.extra.plan.target_revision // "NONE"')" \
      "$(afk_render_q -r '.extra.plan.refusal_reason // "-"')"
    afk_render_q -r '.extra.plan.components[] |
      "    \(.component)  \(.action)  \(.reason // "-")\n"
      + "      destination: \(.destination)\n"
      + "      expected=\(.expected_destination_identity // "-")  target=\(.target_identity // "-")  final_state=\(.expected_final_state)\n"
      + "      requires_approval=\(.requires_approval)  backup_required=\(.backup_required)"'
  fi

  if [[ "$(afk_render_q -r '.operation.mutating')" == "true" ]]; then
    printf '\n  operation %s\n' "$(afk_render_q -r '.operation.id // "NONE"')"
    printf '    result=%s reason=%s detail=%s\n' \
      "$(afk_render_q -r '.operation.result')" \
      "$(afk_render_q -r '.operation.reason // "-"')" \
      "$(afk_render_q -r '.operation.detail // "-"')"
    printf '    mutation_performed=%s applied_state_committed=%s rollback_state=%s\n' \
      "$(afk_render_q -r '.operation.mutation_performed')" \
      "$(afk_render_q -r '.operation.applied_state_committed')" \
      "$(afk_render_q -r '.operation.rollback_state')"
    printf '    prior_revision=%s applied_revision=%s target_revision=%s plan=%s\n' \
      "$(afk_render_q -r '.operation.prior_revision // "NONE"')" \
      "$(afk_render_q -r '.operation.applied_revision // "NONE"')" \
      "$(afk_render_q -r '.operation.target_revision // "NONE"')" \
      "$(afk_render_q -r '.operation.plan_identity // "-"')"
    if [[ "$(afk_render_q -r '.operation.completed_steps | length')" != "0" ]]; then
      afk_render_q -r '.operation.completed_steps[] |
        "    step: \(.component) \(.action) \(.result)"'
    fi
  fi

  if [[ "$(afk_render_q -r 'if .extra.verification then "y" else "n" end')" == "y" ]]; then
    printf '\n  offline verification: verified=%s (checks=%s failures=%s warnings=%s)\n' \
      "$(afk_render_q -r '.extra.verification.verified')" \
      "$(afk_render_q -r '.extra.verification.checks_run')" \
      "$(afk_render_q -r '.extra.verification.failures')" \
      "$(afk_render_q -r '.extra.verification.warnings')"
    printf '    offline=%s repaired=%s live_probes_performed=%s\n' \
      "$(afk_render_q -r '.extra.verification.offline')" \
      "$(afk_render_q -r '.extra.verification.repaired')" \
      "$(afk_render_q -r '.extra.verification.live_probes_performed')"
    afk_render_q -r '.extra.verification.checks[] |
      "    \(.subject)  \(.check)  \(.result)  \(.reason // "-")  expected=\(.evidence.expected // "-")  observed=\(.evidence.observed // "-")"'
  fi

  printf '\n  findings\n'
  if [[ "$(afk_render_q -r '.findings | length')" == "0" ]]; then
    printf '    (none)\n'
  else
    afk_render_q -r '.findings[] |
      "    [\(.severity)] \(.component // "installation") \(.reason)\n"
      + "      \(.message)\n"
      + "      impact: \(.impact)\n"
      + "      action: \(.required_action)\n"
      + "      blocked_scopes=\(.blocked_scopes | join(",") | if . == "" then "-" else . end)  mutation_safe=\(.mutation_safe)  transient=\(.transient)\n"
      + "      expected=\(.evidence.expected // "-")  observed=\(.evidence.observed // "-")  provenance=\(.evidence.provenance)"'
  fi

  printf '\n  overall           : %s\n' "$(afk_render_q -r '.overall.state')"
  printf '  exit code         : %s\n' "$(afk_render_q -r '.overall.exit_code')"
  printf '  next safe action  : %s\n' "$(afk_render_q -r '.next_safe_action')"
  AFK_RENDER_DOC=""
}
