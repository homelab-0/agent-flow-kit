#!/usr/bin/env bash
# afk-catalog-sync.sh — `agent-flow-kit catalog-sync`: follow the catalog the
# deployed agent-router trusts, as the prox-ops client manifest names it.
#
# The contract (prox-ops clients/agent-router/README.md): resolve the branch to
# one commit, fetch the manifest AND the catalog from that same commit, require
# schema prox-ops/agent-router-client/v1 (unknown fields are ignored), and
# require sha256(catalog) == catalog.digest. Any failure keeps the last
# verified catalog: current.yaml is only ever re-pointed at a verified file.
#
# The source is declared once, in lifecycle/release-policy.json
# (.catalog_source); AFK_RELEASE_POLICY replaces that file, for tests only. The
# repository is public, so no credential of any kind is sent: git and curl run
# from an empty environment with no user config, netrc or credential helper.

if [[ -n "${AFK_CATALOG_SYNC_SOURCED:-}" ]]; then
  return 0
fi
AFK_CATALOG_SYNC_SOURCED=1

AFK_CS_MANIFEST_SCHEMA="prox-ops/agent-router-client/v1"
declare -F afk_warn >/dev/null || afk_warn() { printf 'agent-flow-kit: %s\n' "$*" >&2; }

afk_cs_paths() {
  AFK_CS_POLICY="${AFK_RELEASE_POLICY:-$AFK_INSTALL_ROOT/lifecycle/release-policy.json}"
  AFK_CS_DIR="${HOME:+$HOME/.config/agent-flow-kit/trusted-catalogs}"
  AFK_CS_CURRENT="${AFK_CS_DIR:+$AFK_CS_DIR/current.yaml}"
  AFK_CS_STATE="$AFK_STATE_DIR/catalog/latest.json"
  AFK_CS_CONFIG="${AGENT_FLOW_CONFIG:-${SUBSCRIPTIONS_FILE:-${AFK_SKILLS_HOME:+$AFK_SKILLS_HOME/model-router/subscriptions.yaml}}}"
}

afk_cs_sha256() { # <file> -> sha256:<hex>
  local out
  out="$(sha256sum -- "$1" 2>/dev/null || shasum -a 256 -- "$1" 2>/dev/null)" || return 1
  out="${out%%[[:space:]]*}"
  [[ "$out" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf 'sha256:%s\n' "$out"
}

# The fixed directories git, curl and timeout are resolved from, and the only
# PATH a fetch sees; the caller's PATH never chooses a tool. The override
# exists for tests only (it points at stubs).
AFK_CS_TOOL_PATH="${AFK_CATALOG_SYNC_TOOL_PATH:-/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin}"

afk_cs_tool() { # <name...> -> the first absolute executable found in AFK_CS_TOOL_PATH
  local d n dirs
  IFS=: read -r -a dirs <<<"$AFK_CS_TOOL_PATH"
  for n in "$@"; do
    for d in "${dirs[@]}"; do
      [[ "$d" == /* && -f "$d/$n" && -x "$d/$n" ]] && { printf '%s\n' "$d/$n"; return 0; }
    done
  done
  return 1
}

# afk_cs_env — the empty environment every fetch starts from. HOME points
# nowhere, so neither ~/.gitconfig, ~/.netrc nor ~/.curlrc is read, and no
# system git config is read either (bin/afk-release-reconcile's trusted_git).
afk_cs_env() {
  env -i PATH="$AFK_CS_TOOL_PATH" HOME=/nonexistent LC_ALL=C GIT_TERMINAL_PROMPT=0 \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_COUNT=0 \
    GIT_SSL_NO_VERIFY=false GIT_HTTP_LOW_SPEED_LIMIT=1 GIT_HTTP_LOW_SPEED_TIME="$AFK_CS_TIMEOUT" "$@"
}

afk_cs_bounded() { # <command...> — under timeout(1) when this host has one
  if [[ -n "$AFK_CS_TIMEOUT_BIN" ]]; then afk_cs_env "$AFK_CS_TIMEOUT_BIN" "$AFK_CS_TIMEOUT" "$@"; else afk_cs_env "$@"; fi
}

afk_cs_fetch() { # <sha> <repo-relative path> <destination>
  afk_cs_env "$AFK_CS_CURL_BIN" -q -fsSL --proto '=https' --max-redirs 3 \
    --connect-timeout 10 --max-time "$AFK_CS_TIMEOUT" -o "$3" "$AFK_CS_RAW/$1/$2" </dev/null 2>/dev/null
}

# afk_cs_record <outcome> <reason> — the secret-free state file. The last
# verified sha/version/digest/time carry forward across failures, so status can
# tell a failing sync from a stale one.
afk_cs_record() {
  local now prev="{}" doc
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [[ -r "$AFK_CS_STATE" ]] && prev="$(jq -c 'if type == "object" then . else {} end' "$AFK_CS_STATE" 2>/dev/null || printf '{}')"
  doc="$(jq -n --argjson prev "$prev" --arg o "$1" --arg r "$2" --arg t "$now" \
    --arg sha "$AFK_CS_SHA" --arg v "$AFK_CS_VERSION" --arg d "$AFK_CS_DIGEST" --arg p "$AFK_CS_FILE" '
    def n: if . == "" then null else . end;
    {schema: "afk-catalog-sync/1", outcome: $o, reason: ($r | n), fetched_at: $t,
     source_sha: ($sha | n), document_version: ($v | n), digest: ($d | n)}
    + if $o == "FAILED" then {last_verified: ($prev.last_verified // null)}
      else {last_verified: {source_sha: $sha, document_version: $v, digest: $d, path: $p, at: $t}} end')" || return 1
  (umask 077 && mkdir -p -- "${AFK_CS_STATE%/*}" && printf '%s\n' "$doc" >"$AFK_CS_STATE.tmp.$$" \
    && mv -f -- "$AFK_CS_STATE.tmp.$$" "$AFK_CS_STATE")
}

afk_cs_fail() { # <reason> <detail>
  AFK_CS_OUTCOME=FAILED AFK_CS_REASON="$1"
  afk_warn "catalog-sync: $1: $2; current.yaml was left unchanged"
  return 1
}

# afk_cs_verify — contract steps 1-4 into $AFK_CS_TMP. Sets AFK_CS_SHA,
# AFK_CS_VERSION, AFK_CS_DIGEST and AFK_CS_PATH, or a named AFK_CS_REASON.
afk_cs_verify() {
  local repo branch manifest out doc
  repo="$(jq -r '.catalog_source.repository_url // empty' "$AFK_CS_POLICY" 2>/dev/null)"
  AFK_CS_RAW="$(jq -r '.catalog_source.raw_base_url // empty' "$AFK_CS_POLICY" 2>/dev/null)"
  branch="$(jq -r '.catalog_source.branch // empty' "$AFK_CS_POLICY" 2>/dev/null)"
  manifest="$(jq -r '.catalog_source.manifest_path // empty' "$AFK_CS_POLICY" 2>/dev/null)"
  AFK_CS_TIMEOUT="$(jq -r '.catalog_source.fetch_timeout_seconds // 20' "$AFK_CS_POLICY" 2>/dev/null)"
  [[ "$AFK_CS_TIMEOUT" =~ ^[0-9]+$ ]] && (( AFK_CS_TIMEOUT >= 1 && AFK_CS_TIMEOUT <= 300 )) || AFK_CS_TIMEOUT=20
  if [[ "$repo" != https://* || "$AFK_CS_RAW" != https://* || -z "$branch" || -z "$manifest" ]]; then
    afk_cs_fail SOURCE_UNDECLARED "the kit policy declares no complete catalog_source"; return 1
  fi
  if ! AFK_CS_GIT_BIN="$(afk_cs_tool git)" || ! AFK_CS_CURL_BIN="$(afk_cs_tool curl)"; then
    afk_cs_fail SOURCE_UNREACHABLE "git or curl is not installed in $AFK_CS_TOOL_PATH"; return 1
  fi
  AFK_CS_TIMEOUT_BIN="$(afk_cs_tool timeout gtimeout)" || AFK_CS_TIMEOUT_BIN=""
  out="$(afk_cs_bounded "$AFK_CS_GIT_BIN" -c credential.helper= -c http.sslVerify=true \
    ls-remote -- "$repo" "refs/heads/$branch" </dev/null 2>/dev/null)" \
    || { afk_cs_fail SOURCE_UNREACHABLE "git ls-remote $repo failed or timed out"; return 1; }
  # ls-remote's pattern matches any ref ENDING in refs/heads/<branch> (a branch
  # named a/refs/heads/main would match too), so only the exact ref counts.
  local ref_sha ref_name _rest
  while read -r ref_sha ref_name _rest; do
    if [[ "$ref_name" == "refs/heads/$branch" ]]; then AFK_CS_SHA="$ref_sha"; break; fi
  done <<<"$out"
  if ! [[ "$AFK_CS_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    AFK_CS_SHA=""; afk_cs_fail SOURCE_UNREACHABLE "refs/heads/$branch did not resolve to exactly one commit id"; return 1
  fi
  afk_cs_fetch "$AFK_CS_SHA" "$manifest" "$AFK_CS_TMP/manifest.json" \
    || { afk_cs_fail SOURCE_UNREACHABLE "the manifest could not be fetched at $AFK_CS_SHA"; return 1; }
  doc="$(jq -c 'select(type == "object")' "$AFK_CS_TMP/manifest.json" 2>/dev/null)"
  [[ -n "$doc" ]] || { afk_cs_fail MANIFEST_INVALID "the manifest is not a JSON object"; return 1; }
  if [[ "$(jq -r '.schema // "" | tostring' <<<"$doc")" != "$AFK_CS_MANIFEST_SCHEMA" ]]; then
    afk_cs_fail SCHEMA_UNSUPPORTED "the manifest schema is not $AFK_CS_MANIFEST_SCHEMA"; return 1
  fi
  AFK_CS_DIGEST="$(jq -r '.catalog.digest | strings' <<<"$doc" 2>/dev/null)"
  AFK_CS_PATH="$(jq -r '.catalog.path | strings' <<<"$doc" 2>/dev/null)"
  AFK_CS_VERSION="$(jq -r '.catalog.document_version | if type == "number" then tostring else strings end' <<<"$doc" 2>/dev/null)"
  if ! [[ "$AFK_CS_DIGEST" =~ ^sha256:[0-9a-f]{64}$ && "$AFK_CS_VERSION" =~ ^[A-Za-z0-9._-]{1,64}$ && -n "$AFK_CS_PATH" ]]; then
    AFK_CS_DIGEST="" AFK_CS_VERSION=""
    afk_cs_fail MANIFEST_INVALID "catalog.digest, catalog.path or catalog.document_version is missing or malformed"; return 1
  fi
  if [[ "$AFK_CS_PATH" == /* || "$AFK_CS_PATH" == *..* || "$AFK_CS_PATH" =~ [^A-Za-z0-9._/-] ]]; then
    afk_cs_fail PATH_REJECTED "catalog.path is absolute, climbs with .., or has characters outside [A-Za-z0-9._/-]"; return 1
  fi
  afk_cs_fetch "$AFK_CS_SHA" "$AFK_CS_PATH" "$AFK_CS_TMP/catalog.yaml" \
    || { afk_cs_fail SOURCE_UNREACHABLE "the catalog could not be fetched at $AFK_CS_SHA"; return 1; }
  if [[ "$(afk_cs_sha256 "$AFK_CS_TMP/catalog.yaml")" != "$AFK_CS_DIGEST" ]]; then
    afk_cs_fail DIGEST_MISMATCH "the fetched catalog does not hash to $AFK_CS_DIGEST"; return 1
  fi
}

# afk_cs_install — the verified file, 0444, by rename; then current.yaml, by
# renaming a fresh link over it. Existing digest-named files stay in place.
afk_cs_install() {
  local name="trusted-catalog-$AFK_CS_VERSION-${AFK_CS_DIGEST:7:12}.yaml"
  AFK_CS_FILE="$AFK_CS_DIR/$name"
  if [[ -L "$AFK_CS_DIR" ]] || ! (umask 022 && mkdir -p -- "$AFK_CS_DIR"); then
    afk_cs_fail INSTALL_FAILED "$AFK_CS_DIR is a symlink or could not be created"; return 1
  fi
  # mv -f onto a directory (or a link to one) would move the new link INTO it.
  if [[ -d "$AFK_CS_CURRENT" ]]; then
    afk_cs_fail INSTALL_FAILED "current.yaml is a directory or a link to one"; return 1
  fi
  # A directory (or any other non-regular file) at the digest-named path would
  # make the digest check below fail, and then mv -f would move the temp
  # catalog INTO it instead of replacing it — leaving current.yaml re-pointed
  # at that directory with no way back. Refuse before touching anything.
  if [[ -L "$AFK_CS_FILE" ]] || { [[ -e "$AFK_CS_FILE" ]] && [[ ! -f "$AFK_CS_FILE" ]]; }; then
    afk_cs_fail INSTALL_FAILED "$AFK_CS_FILE exists and is not a regular file"; return 1
  fi
  if [[ "$(afk_cs_sha256 "$AFK_CS_FILE" 2>/dev/null)" != "$AFK_CS_DIGEST" ]]; then
    cp -- "$AFK_CS_TMP/catalog.yaml" "$AFK_CS_DIR/.$name.tmp.$$" && chmod 0444 "$AFK_CS_DIR/.$name.tmp.$$" \
      && mv -f -- "$AFK_CS_DIR/.$name.tmp.$$" "$AFK_CS_FILE" \
      || { rm -f -- "$AFK_CS_DIR/.$name.tmp.$$"; afk_cs_fail INSTALL_FAILED "the catalog could not be written"; return 1; }
  fi
  local tmp=".current.tmp.$$"
  if ! { ln -s -- "$name" "$AFK_CS_DIR/$tmp" && mv -f -- "$AFK_CS_DIR/$tmp" "$AFK_CS_CURRENT" \
    && [[ "$(readlink -- "$AFK_CS_CURRENT" 2>/dev/null)" == "$name" ]] \
    && [[ "$(afk_cs_sha256 "$AFK_CS_CURRENT" 2>/dev/null)" == "$AFK_CS_DIGEST" ]]; }; then
    rm -f -- "$AFK_CS_DIR/$tmp"
    [[ -L "$AFK_CS_CURRENT/$tmp" ]] && rm -f -- "$AFK_CS_CURRENT/$tmp"
    afk_cs_fail INSTALL_FAILED "current.yaml could not be re-pointed at the verified file"; return 1
  fi
}

afk_cmd_catalog_sync() { # <check|apply> <json-mode>
  local mode="$1" json="$2" rc=0 current=""
  afk_cs_paths
  if [[ -z "${HOME:-}" || -z "$AFK_STATE_DIR" ]]; then
    afk_warn "catalog-sync: HOME is not set; nothing was changed"; return "${AFK_EXIT_USAGE:-1}"
  fi
  AFK_CS_SHA="" AFK_CS_VERSION="" AFK_CS_DIGEST="" AFK_CS_PATH="" AFK_CS_FILE=""
  AFK_CS_OUTCOME="" AFK_CS_REASON="" AFK_CS_GIT_BIN="" AFK_CS_CURL_BIN="" AFK_CS_TIMEOUT_BIN=""
  (umask 077 && mkdir -p -- "$AFK_STATE_DIR/catalog") || { afk_warn "catalog-sync: no state directory"; return 1; }
  AFK_CS_TMP="$(mktemp -d "$AFK_STATE_DIR/catalog/.fetch.XXXXXX")" || { afk_warn "catalog-sync: no scratch directory"; return 1; }
  if afk_cs_verify; then
    [[ -e "$AFK_CS_CURRENT" ]] && current="$(afk_cs_sha256 "$AFK_CS_CURRENT" 2>/dev/null)"
    if [[ "$current" == "$AFK_CS_DIGEST" ]]; then
      AFK_CS_OUTCOME=ALREADY_CURRENT
      AFK_CS_FILE="$(cd -P -- "$AFK_CS_DIR" 2>/dev/null && pwd -P)/$(readlink -- "$AFK_CS_CURRENT" 2>/dev/null || printf current.yaml)"
    elif [[ "$mode" == check ]]; then
      AFK_CS_OUTCOME=UPDATE_AVAILABLE
    elif afk_cs_install; then
      AFK_CS_OUTCOME=INSTALLED
    fi
  fi
  rm -rf -- "$AFK_CS_TMP"
  # --check records nothing; --apply records every outcome, failures included.
  if [[ "$mode" == apply ]]; then afk_cs_record "$AFK_CS_OUTCOME" "$AFK_CS_REASON" || afk_warn "catalog-sync: the state file could not be written"; fi
  if [[ "$AFK_CS_OUTCOME" == FAILED ]]; then
    rc="${AFK_EXIT_SOURCE_REFUSED:-4}"
    [[ "$AFK_CS_REASON" == SOURCE_UNREACHABLE ]] && rc="${AFK_EXIT_LIVE_UNAVAILABLE:-5}"
  fi
  if [[ "$json" == true ]]; then
    jq -n --arg o "$AFK_CS_OUTCOME" --arg r "$AFK_CS_REASON" --arg m "$mode" --arg sha "$AFK_CS_SHA" \
      --arg v "$AFK_CS_VERSION" --arg d "$AFK_CS_DIGEST" --arg f "$AFK_CS_FILE" --arg cur "$current" '
      def n: if . == "" then null else . end;
      {schema: "afk-catalog-sync-result/1", mode: $m, outcome: $o, reason: ($r | n), source_sha: ($sha | n),
       document_version: ($v | n), digest: ($d | n), path: ($f | n), current_digest: ($cur | n)}'
  else
    printf 'catalog-sync: %s%s source_sha=%s document_version=%s digest=%s%s\n' "$AFK_CS_OUTCOME" \
      "${AFK_CS_REASON:+ ($AFK_CS_REASON)}" "${AFK_CS_SHA:--}" "${AFK_CS_VERSION:--}" "${AFK_CS_DIGEST:--}" \
      "${AFK_CS_FILE:+ path=$AFK_CS_FILE}"
  fi
  return "$rc"
}

# --- resolution and status -----------------------------------------------------

afk_cs_config_path() { # launcher.catalog_path from the machine-local subscriptions.yaml
  local v=""
  [[ -n "$AFK_CS_CONFIG" && -r "$AFK_CS_CONFIG" ]] || return 0
  if command -v yq >/dev/null 2>&1; then
    v="$(yq -r '.launcher.catalog_path // ""' "$AFK_CS_CONFIG" 2>/dev/null)"
  else
    v="$(awk '/^launcher:/ { l = 1; next } /^[^[:space:]#]/ { l = 0 }
      l && /^  catalog_path:/ { sub(/^  catalog_path:[[:space:]]*/, ""); sub(/[[:space:]]+#.*$/, "")
        gsub(/^["\047]|["\047]$/, ""); print; exit }' "$AFK_CS_CONFIG" 2>/dev/null)"
  fi
  [[ "$v" == null ]] && v=""
  printf '%s' "$v"
}

# afk_catalog_status_json — which rule (dispatch.sh's resolve_catalog_path
# order) picks the catalog, what it hashes to, and the last sync.
afk_catalog_status_json() {
  local rule=none path="" cfg digest="" cur_digest="" cfg_digest="" state="null" findings="" now at epoch interval=900
  afk_cs_paths
  cfg="$(afk_cs_config_path)"
  if [[ -n "${AGENT_STAMP_VALIDATE_CATALOG_PATH:-}" ]]; then rule="env"; path="$AGENT_STAMP_VALIDATE_CATALOG_PATH"
  elif [[ -n "$cfg" ]]; then rule="config"; path="$cfg"
  elif [[ -n "$AFK_CS_CURRENT" && -e "$AFK_CS_CURRENT" ]]; then rule="synced"; path="$AFK_CS_CURRENT"; fi
  [[ -n "$path" && -f "$path" ]] && digest="$(afk_cs_sha256 "$path" 2>/dev/null)"
  [[ -n "$AFK_CS_CURRENT" && -e "$AFK_CS_CURRENT" ]] && cur_digest="$(afk_cs_sha256 "$AFK_CS_CURRENT" 2>/dev/null)"
  [[ -n "$cfg" && -f "$cfg" ]] && cfg_digest="$(afk_cs_sha256 "$cfg" 2>/dev/null)"
  [[ -r "$AFK_CS_STATE" ]] && state="$(jq -c 'select(type == "object")' "$AFK_CS_STATE" 2>/dev/null)"
  state="${state:-null}"
  [[ -z "$digest" ]] && findings+=" CATALOG_UNRESOLVED:error"
  # An environment value never leaves afk_env_record: the env rule reports its
  # name and the digest it resolves to, not the value.
  [[ "$rule" == env ]] && path=""
  [[ -n "$cfg" && -n "$cur_digest" && "$cfg_digest" != "$cur_digest" ]] && findings+=" CATALOG_PIN_SHADOWED:warning"
  at=""
  if [[ "$state" != null ]]; then
    [[ "$(jq -r '.outcome' <<<"$state")" == FAILED ]] && findings+=" CATALOG_SYNC_FAILED:warning"
    at="$(jq -r '.last_verified.at // empty' <<<"$state")"
  fi
  # No verified sync at all (a host that never synced) is stale too.
  declare -F afk_au_paths >/dev/null && { afk_au_paths; interval="$(afk_au_interval)"; }
  now="$(date -u +%s)"
  if [[ -z "$at" ]] || ! epoch="$(afk_au_epoch "$at" 2>/dev/null)" || (( now - epoch > interval * 3 )); then
    findings+=" CATALOG_SYNC_STALE:warning"
  fi
  jq -nc --arg rule "$rule" --arg path "$path" --arg d "$digest" --arg cur "$cur_digest" \
    --argjson state "$state" --arg f "$findings" '
    def n: if . == "" then null else . end;
    {resolved_by: (if $rule == "none" then null else $rule end), path: ($path | n), digest: ($d | n),
     current_digest: ($cur | n),
     last_sync: (if $state == null then null else {outcome: $state.outcome, reason: $state.reason, at: $state.fetched_at,
       last_verified_at: ($state.last_verified.at // null)} end),
     findings: [$f | splits(" ") | select(. != "") | split(":") | {code: .[0], severity: .[1]}]}'
}

afk_catalog_apply_status() {
  local cat
  cat="$(afk_catalog_status_json)" || return 0
  AFK_R_EXTRA="$(jq -nc --argjson base "$AFK_R_EXTRA" --argjson cat "$cat" '$base + {catalog: $cat}')" || return 0
}

afk_catalog_render_human() { # after the status document, from AFK_R_EXTRA
  jq -r '.catalog // empty | (.last_sync // {}) as $s |
    "\n  trusted catalog\n"
    + "    resolved_by=\(.resolved_by // "-")  path=\(.path // "-")\n"
    + "    digest=\(.digest // "-")  current.yaml=\(.current_digest // "-")\n"
    + "    last sync: \($s.outcome // "-") \($s.reason // "-")  at=\($s.at // "-")  verified_at=\($s.last_verified_at // "-")"
    + ([.findings[] | "\n    \(.severity): \(.code)"] | add // "")' <<<"$AFK_R_EXTRA" 2>/dev/null || true
}

# afk_catalog_scheduled — what a scheduler runs beside the release step. Its
# failure is logged and recorded in its own state file, never in the release
# result, and never fails the caller.
afk_catalog_scheduled() {
  afk_cmd_catalog_sync apply false || printf 'catalog-sync: failed (exit %s); the release result is unaffected\n' "$?"
  return 0
}
