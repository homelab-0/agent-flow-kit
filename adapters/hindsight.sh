#!/bin/bash -p
# Readiness boundary for the installed Hindsight coding-agent integration.
# AFK never calls a recall/history command, copies a credential, or installs a
# second hook/plugin. Native hooks remain the sole recall/retain integration.
# shellcheck disable=SC2016 # jq programs intentionally use jq variables
set -uo pipefail
# Exported functions outrank both builtins and absolute PATH resolution in Bash.
# No caller-provided function is part of this adapter's executable trust base.
builtin mapfile -t _afk_imported_functions < <(builtin compgen -A function)
for _afk_imported_function in "${_afk_imported_functions[@]}"; do
  builtin unset -f -- "$_afk_imported_function"
done
builtin unset _afk_imported_functions _afk_imported_function
PATH=/usr/bin:/bin
export PATH
builtin hash -r
mode="${1:-off}"; repo="${2:-$PWD}"
case "$mode" in advisory|required|blind|off) : ;; *) exit 2 ;; esac
STATE_DIR="${AFK_STATE_DIR:-${XDG_STATE_HOME:-${HOME:+$HOME/.local/state}}/agent-flow-kit}"
runtime="${HINDSIGHT_CODING_AGENTS_HOME:-${HOME:+$HOME/.hindsight/coding-agents}}"
config="${HINDSIGHT_CONFIG:-${HOME:+$HOME/.hindsight/coding-agent.json}}"
readonly HINDSIGHT_PACKAGE='@vectorize-io/hindsight-coding-agents'
readonly HINDSIGHT_VERSION='0.6.0'
readonly HINDSIGHT_STAGED_INTEGRITY='sha512-gtCLrTdb1O/27SXH1InwnUUa6xXnuGEcVtSsf47eD8vcnVGmPd5c2RhtjANqPu+gNzp5RYUtpS2z7GHoKxyCkA=='
readonly HINDSIGHT_PACKAGE_JSON_SHA256='ff387e6b003248be6f80adb6ef9da9d57e86693ba1519dc15f9e14b487050dc4'
readonly HINDSIGHT_STATUS_SHA256='271c60fcf0caf4b55972144da1ced9442f4f414e8b2ff71a98d326cb42d45958'
integrity_dir=""
BOOTSTRAP_OWNER=0
BOOTSTRAP_ROOT_OWNER=0
readonly UID_MAP_FILE='/proc/self/uid_map'
# Candidate qualification runs this adapter inside a single-ID user namespace:
# the invoking identity has a one-entry mapping while fixed host system mounts
# appear as overflow uid 65534. Accept that representation only when the kernel
# uid map proves the exact confinement shape; a user-owned tree remains mapped
# to the invoking uid and is rejected.
if [[ -n "${EUID:-}" && -r "$UID_MAP_FILE" ]]; then
  uid_map_rows=0 uid_map_matches=0 uid_map_valid=true
  while read -r namespace_uid host_uid uid_range uid_map_extra ||
      [[ -n "${namespace_uid:-}${host_uid:-}${uid_range:-}${uid_map_extra:-}" ]]; do
    uid_map_rows=$((uid_map_rows + 1))
    if [[ ! "$namespace_uid" =~ ^[0-9]+$ || ! "$host_uid" =~ ^[0-9]+$ ||
          ! "$uid_range" =~ ^[0-9]+$ || -n "$uid_map_extra" ]]; then
      uid_map_valid=false
      continue
    fi
    if [[ "$namespace_uid" == "$EUID" && "$host_uid" == 0 && "$uid_range" == 1 ]]; then
      uid_map_matches=$((uid_map_matches + 1))
    fi
  done < "$UID_MAP_FILE"
  [[ "$uid_map_valid" == true ]] || exit 1
  if (( uid_map_matches > 0 )); then
    (( uid_map_rows == 1 && uid_map_matches == 1 )) || exit 1
    BOOTSTRAP_OWNER=65534
    BOOTSTRAP_ROOT_OWNER="$EUID"
  fi
fi

case "${OSTYPE:-}" in
  linux*)
    readonly REALPATH_BIN='/usr/bin/realpath' STAT_BIN='/usr/bin/stat'
    readonly -a JQ_CANDIDATES=(/usr/bin/jq)
    readonly ENV_BIN='/usr/bin/env' CP_BIN='/usr/bin/cp' CHMOD_BIN='/usr/bin/chmod'
    readonly MKTEMP_BIN='/usr/bin/mktemp' ID_BIN='/usr/bin/id' RM_BIN='/usr/bin/rm'
    readonly MKDIR_BIN='/usr/bin/mkdir' MV_BIN='/usr/bin/mv'
    readonly STAT_STYLE='gnu'
    ;;
  darwin*)
    readonly REALPATH_BIN='/usr/bin/realpath' STAT_BIN='/usr/bin/stat'
    readonly -a JQ_CANDIDATES=(/usr/bin/jq /opt/homebrew/bin/jq /usr/local/bin/jq)
    readonly ENV_BIN='/usr/bin/env' CP_BIN='/bin/cp' CHMOD_BIN='/bin/chmod'
    readonly MKTEMP_BIN='/usr/bin/mktemp' ID_BIN='/usr/bin/id' RM_BIN='/bin/rm'
    readonly MKDIR_BIN='/bin/mkdir' MV_BIN='/bin/mv'
    readonly STAT_STYLE='bsd'
    ;;
  *) exit 1 ;;
esac

bootstrap_stat() {
  if [[ "$STAT_STYLE" == gnu ]]; then "$STAT_BIN" -c "$1" "$2"
  else "$STAT_BIN" -f "$1" "$2"; fi
}

bootstrap_trusted_tool() {
  local requested="$1" resolved owner expected_owner permissions cursor parent
  [[ "$requested" == /* && -e "$requested" ]] || return 1
  resolved="$("$REALPATH_BIN" -e -- "$requested" 2>/dev/null)" || return 1
  [[ -f "$resolved" && -x "$resolved" ]] || return 1
  cursor="$resolved"
  while :; do
    owner="$(bootstrap_stat %u "$cursor" 2>/dev/null)" || return 1
    if [[ "$STAT_STYLE" == gnu ]]; then
      permissions="$(bootstrap_stat %a "$cursor" 2>/dev/null)" || return 1
    else
      permissions="$(bootstrap_stat %Lp "$cursor" 2>/dev/null)" || return 1
    fi
    expected_owner="$BOOTSTRAP_OWNER"
    [[ "$cursor" == / ]] && expected_owner="$BOOTSTRAP_ROOT_OWNER"
    [[ "$owner" == "$expected_owner" && "$permissions" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$permissions & 8#22) == 0 )) || return 1
    [[ "$cursor" == / ]] && { printf '%s\n' "$resolved"; return 0; }
    parent="${cursor%/*}"; [[ -n "$parent" ]] || parent=/
    cursor="$parent"
  done
}

disabled_result() {
  local disabled="$STATE_DIR/hindsight/disabled.json" tmp
  tmp="${disabled}.tmp.$$"
  "$MKDIR_EXEC" -p -- "${disabled%/*}" || exit 1
  printf '{"disabled":true,"bankId":"afk-disabled"}\n' >"$tmp"
  "$CHMOD_EXEC" 600 "$tmp" || exit 1
  "$MV_EXEC" -f -- "$tmp" "$disabled" || exit 1
  "$JQ_EXEC" -nc --arg m "$mode" --arg p "$repo" --arg c "$disabled" \
    '{schema:"afk-memory-context/2",mode:$m,state:"DISABLED",project:$p,
      native_integration:"BYPASSED_BY_SUPPORTED_CONFIG",
      environment:{HINDSIGHT_CONFIG:$c,HINDSIGHT_DISABLED:"true"},
      recall:[],retain:[],authoritative_evidence:true}'
}

bootstrap_trusted_tool "$REALPATH_BIN" >/dev/null || exit 1
bootstrap_trusted_tool "$STAT_BIN" >/dev/null || exit 1
JQ_EXEC=""
for jq_candidate in "${JQ_CANDIDATES[@]}"; do
  JQ_EXEC="$(bootstrap_trusted_tool "$jq_candidate" 2>/dev/null)" || continue
  break
done
[[ -n "$JQ_EXEC" ]] || exit 1
CHMOD_EXEC="$(bootstrap_trusted_tool "$CHMOD_BIN")" || exit 1
MKDIR_EXEC="$(bootstrap_trusted_tool "$MKDIR_BIN")" || exit 1
MV_EXEC="$(bootstrap_trusted_tool "$MV_BIN")" || exit 1
if [[ "$mode" == blind || "$mode" == off ]]; then disabled_result; exit 0; fi

ENV_EXEC="$(bootstrap_trusted_tool "$ENV_BIN")" || exit 1
CP_EXEC="$(bootstrap_trusted_tool "$CP_BIN")" || exit 1
MKTEMP_EXEC="$(bootstrap_trusted_tool "$MKTEMP_BIN")" || exit 1
ID_EXEC="$(bootstrap_trusted_tool "$ID_BIN")" || exit 1
RM_EXEC="$(bootstrap_trusted_tool "$RM_BIN")" || exit 1

fail_result() {
  local reason="$1"
  "$JQ_EXEC" -nc --arg m "$mode" --arg p "$repo" --arg r "$reason" \
    '{schema:"afk-memory-context/2",mode:$m,state:"NOT_EVALUATED",reason:$r,
      project:$p,native_integration:"NOT_MUTATED",recall:[],retain:[],authoritative_evidence:true}'
  [[ "$mode" == advisory ]]
}

owned_runtime_path() {
  local path="$1" owner
  [[ ! -L "$path" ]] || return 1
  owner="$(bootstrap_stat %u "$path" 2>/dev/null)" || return 1
  [[ "$owner" == "$("$ID_EXEC" -u)" ]]
}

# shellcheck disable=SC2329 # invoked indirectly by the EXIT trap below
cleanup_integrity_dir() {
  [[ "$integrity_dir" == /tmp/afk-hindsight-integrity.* && -d "$integrity_dir" ]] \
    || return 0
  "$RM_EXEC" -rf -- "$integrity_dir"
  integrity_dir=""
}

trusted_tool() {
  local requested resolved
  for requested in "$@"; do
    resolved="$(bootstrap_trusted_tool "$requested" 2>/dev/null)" || continue
    printf '%s\n' "$resolved"
    return 0
  done
  return 1
}

sha256_file() {
  local digest hash_output
  if [[ "$HASH_STYLE" == sha256sum ]]; then
    hash_output="$("$HASH_BIN" "$1")" || return 1
  else
    hash_output="$("$HASH_BIN" -a 256 "$1")" || return 1
  fi
  digest="${hash_output%% *}"
  [[ "$digest" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
  printf '%s\n' "${digest,,}"
}

[[ -n "$runtime" && "$runtime" == /* && -d "$runtime" && -d "$runtime/dist" &&
   -f "$runtime/package.json" && -f "$runtime/dist/status.js" ]] \
  || { fail_result MEMORY_RUNTIME_NOT_INSTALLED; exit; }
runtime_parent="${runtime%/*}"; runtime_base="${runtime##*/}"
requested_runtime="$runtime"
resolved_parent="$(cd -P -- "$runtime_parent" 2>/dev/null && pwd -P)"
resolved_runtime="$resolved_parent/$runtime_base"
[[ -n "$requested_runtime" && "$requested_runtime" == "$resolved_runtime" ]] \
  || { fail_result MEMORY_RUNTIME_UNQUALIFIED; exit; }
for trusted_path in "$runtime" "$runtime/dist" "$runtime/package.json" \
    "$runtime/dist/status.js"; do
  owned_runtime_path "$trusted_path" || { fail_result MEMORY_RUNTIME_UNQUALIFIED; exit; }
done
package="$("$JQ_EXEC" -r '.name // ""' "$runtime/package.json" 2>/dev/null)"
version="$("$JQ_EXEC" -r '.version // ""' "$runtime/package.json" 2>/dev/null)"
[[ "$package" == "$HINDSIGHT_PACKAGE" && "$version" == "$HINDSIGHT_VERSION" ]] \
  || { fail_result MEMORY_RUNTIME_UNQUALIFIED; exit; }
[[ -r "$config" ]] || { fail_result MEMORY_CONFIG_NOT_FOUND; exit; }
# Select only public routing fields. apiToken is neither selected nor copied.
shape="$("$JQ_EXEC" -c '{apiUrl:(.apiUrl // ""),bankId:(.bankId // "")}' "$config" 2>/dev/null)" \
  || { fail_result MEMORY_CONFIG_INVALID; exit; }
"$JQ_EXEC" -e '(.apiUrl|type)=="string" and (.apiUrl|test("^https?://[^/]+"))
  and (.bankId|type)=="string" and (.bankId|test("^[A-Za-z0-9][A-Za-z0-9._:-]*$"))' <<<"$shape" >/dev/null \
  || { fail_result MEMORY_CONFIG_INVALID; exit; }

node_bin="$(trusted_tool /usr/bin/node /usr/local/bin/node /opt/homebrew/bin/node)" \
  || { fail_result MEMORY_RUNTIME_UNQUALIFIED; exit; }
npm_bin="$(trusted_tool /usr/bin/npm /usr/local/bin/npm /opt/homebrew/bin/npm)" \
  || { fail_result MEMORY_RUNTIME_UNQUALIFIED; exit; }
bound="$(trusted_tool /usr/bin/timeout /usr/local/bin/gtimeout /opt/homebrew/bin/gtimeout)" \
  || { fail_result MEMORY_STATUS_UNAVAILABLE; exit; }
if HASH_BIN="$(trusted_tool /usr/bin/sha256sum /usr/local/bin/sha256sum /opt/homebrew/bin/sha256sum)"; then
  HASH_STYLE=sha256sum
else
  HASH_BIN="$(trusted_tool /usr/bin/shasum /usr/local/bin/shasum /opt/homebrew/bin/shasum)" \
    || { fail_result MEMORY_RUNTIME_UNQUALIFIED; exit; }
  HASH_STYLE=shasum
fi

# Re-pack the staged runtime itself without scripts or network access. AFK pins
# the deterministic installed subset identity, so deleting npm's transient npx
# cache cannot invalidate a correct staged copy. Exact consumed-file hashes and
# private-copy execution close the metadata-only and validation/use gaps. This
# does not claim to reconstruct the upstream tarball's artifact identity.
integrity_dir="$("$MKTEMP_EXEC" -d /tmp/afk-hindsight-integrity.XXXXXX 2>/dev/null || true)"
[[ -n "$integrity_dir" ]] || { fail_result MEMORY_RUNTIME_UNQUALIFIED; exit; }
trap cleanup_integrity_dir EXIT
"$MKDIR_EXEC" -m 700 "$integrity_dir/home" \
  || { fail_result MEMORY_RUNTIME_UNQUALIFIED; exit; }
: >"$integrity_dir/user.npmrc"; : >"$integrity_dir/global.npmrc"
tool_path="${node_bin%/*}:${npm_bin%/*}:/usr/bin:/bin"
package_audit="$($bound 8 "$ENV_EXEC" -i PATH="$tool_path" LANG=C HOME="$integrity_dir" \
  npm_config_userconfig="$integrity_dir/user.npmrc" \
  npm_config_globalconfig="$integrity_dir/global.npmrc" \
  npm_config_cache="$integrity_dir/npm-cache" npm_config_offline=true \
  npm_config_update_notifier=false npm_config_audit=false npm_config_fund=false \
  "$npm_bin" pack --ignore-scripts --dry-run --json "$runtime" 2>/dev/null)" \
  || { fail_result MEMORY_RUNTIME_UNQUALIFIED; exit; }
"$JQ_EXEC" -e --arg name "$HINDSIGHT_PACKAGE" --arg version "$HINDSIGHT_VERSION" \
  --arg integrity "$HINDSIGHT_STAGED_INTEGRITY" '
    type=="array" and length==1 and .[0].name==$name and
    .[0].version==$version and .[0].integrity==$integrity
  ' <<<"$package_audit" >/dev/null 2>&1 \
  || { fail_result MEMORY_RUNTIME_UNQUALIFIED; exit; }
[[ "$(sha256_file "$runtime/package.json" 2>/dev/null || true)" == "$HINDSIGHT_PACKAGE_JSON_SHA256" ]] \
  || { fail_result MEMORY_RUNTIME_UNQUALIFIED; exit; }
"$CP_EXEC" "$runtime/dist/status.js" "$integrity_dir/status.mjs" \
  || { fail_result MEMORY_RUNTIME_UNQUALIFIED; exit; }
"$CHMOD_EXEC" 500 "$integrity_dir/status.mjs" \
  || { fail_result MEMORY_RUNTIME_UNQUALIFIED; exit; }
[[ "$(sha256_file "$integrity_dir/status.mjs" 2>/dev/null || true)" == "$HINDSIGHT_STATUS_SHA256" ]] \
  || { fail_result MEMORY_RUNTIME_UNQUALIFIED; exit; }

status="$($bound 8 "$ENV_EXEC" -i PATH="$tool_path" LANG=C HOME="$integrity_dir/home" \
  "$node_bin" "$integrity_dir/status.mjs" --repo "$repo" --config "$config" 2>/dev/null)" \
  || { fail_result MEMORY_STATUS_UNAVAILABLE; exit; }
"$JQ_EXEC" -e 'type=="object" and (.bank|type)=="string" and (.chatDocs|type)=="number"
  and (.pagesCount|type)=="number" and (.synced|type)=="boolean"' <<<"$status" >/dev/null \
  || { fail_result MEMORY_STATUS_INVALID; exit; }
# Native output is untrusted data. Publish only the four status members AFK's
# memory contract owns, even when the native process returns additional fields.
status="$("$JQ_EXEC" -c '{bank,chatDocs,pagesCount,synced}' <<<"$status")" \
  || { fail_result MEMORY_STATUS_INVALID; exit; }
state="READY"; reason="MEMORY_READY"; rc=0
if [[ "$("$JQ_EXEC" -r .synced <<<"$status")" != true ]]; then
  state="DEGRADED"; reason="MEMORY_NOT_SYNCED"; [[ "$mode" == advisory ]] || rc=1
fi
"$JQ_EXEC" -nc --arg m "$mode" --arg p "$repo" --arg s "$state" --arg r "$reason" \
  --arg v "$version" --argjson native "$status" \
  '{schema:"afk-memory-context/2",mode:$m,state:$s,reason:$r,project:$p,
    package:"@vectorize-io/hindsight-coding-agents",version:$v,
    native_integration:"NOT_MUTATED",status:$native,recall:[],retain:[],authoritative_evidence:true}'
exit "$rc"
