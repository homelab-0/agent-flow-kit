#!/usr/bin/env bash
# afk-tooling.sh — Centralized & Per-Project Skills and MCP Tooling Manager
# with Paperclip Studio Auto-Bridge & 100% Standalone Local Fallback.
#
# Three-Tier Configuration Precedence (highest to lowest):
#   1. `repo-override`: Explicit CLI flags or `<repo>/.afk/config.json` `.tooling`
#      (with `source == "repo-override"`), plus repo-committed `.mcp.json` / BMAD skills.
#   2. `paperclip-central`: When connected to Paperclip, central MCP gateway/servers
#      (`afk-fleet-tooling` `mcp.json`) and attached `desiredSkills` in Paperclip's
#      Skills Studio automatically sync across all local harnesses & worktrees.
#   3. `standalone-local`: When running AFK standalone without Paperclip, falls back
#      cleanly to `~/.config/afk/tooling.json` (`litellm` gateway or `standalone` stdio/http).

if [[ -n "${AFK_TOOLING_SOURCED:-}" ]]; then
  return 0
fi
AFK_TOOLING_SOURCED=1

afk_tooling_registry_path() {
  if [[ -n "${AFK_TOOLING_REGISTRY_FILE:-}" ]]; then
    printf '%s\n' "$AFK_TOOLING_REGISTRY_FILE"
    return 0
  fi
  if [[ -n "${AFK_PAPERCLIP_CONFIG:-}" ]]; then
    local pc_dir
    pc_dir="$(dirname -- "$AFK_PAPERCLIP_CONFIG")"
    if [[ "$pc_dir" != "${HOME:-/tmp}/.config/afk" ]]; then
      printf '%s/tooling.json\n' "$pc_dir"
      return 0
    fi
  fi
  printf '%s\n' "${HOME:-/tmp}/.config/afk/tooling.json"
}

afk_tooling_paperclip_skills_dir() {
  if [[ -n "${AFK_PAPERCLIP_SKILLS_DIR:-}" ]]; then
    printf '%s\n' "$AFK_PAPERCLIP_SKILLS_DIR"
    return 0
  fi
  if [[ -n "${AFK_PAPERCLIP_CONFIG:-}" ]]; then
    local pc_dir
    pc_dir="$(dirname -- "$AFK_PAPERCLIP_CONFIG")"
    if [[ "$pc_dir" != "${HOME:-/tmp}/.config/afk" ]]; then
      printf '%s/paperclip-skills\n' "$pc_dir"
      return 0
    fi
  fi
  printf '%s\n' "${HOME:-/tmp}/.config/afk/paperclip-skills"
}

# Permission bits a new file gets under the current umask (e.g. 644).
_afk_tooling_default_mode() {
  printf '%o\n' $(( 0666 & ~$(umask) ))
}

# _afk_tooling_write_json <dest> <content> [private] [<tmp_dir>]
# Replaces <dest> with <content> only when <content> is a JSON object. The
# temp name comes from mktemp because every job is a background subshell of
# one poll process, so `$$` is the same in all of them and a `.tmp.$$` name
# is shared. mktemp creates the file 0600; `private` keeps it that way for
# files that can hold MCP headers or env (bearer tokens).
# <tmp_dir> puts the temp file there instead of next to <dest>. Files written
# into a job worktree use the job directory: a temp left in the worktree by a
# kill is not covered by any ignore rule, and `git add -A` would commit it
# with its tokens.
_afk_tooling_write_json() {
  local dest="$1" content="$2" mode="${3:-}" tmp_dir="${4:-}" tmp
  jq -e 'type == "object"' <<<"$content" >/dev/null 2>&1 || return 1
  if [[ -n "$tmp_dir" ]]; then
    tmp="$(mktemp "${tmp_dir}/$(basename -- "$dest").XXXXXX" 2>/dev/null)" || return 1
  else
    tmp="$(mktemp "${dest}.XXXXXX" 2>/dev/null)" || return 1
  fi
  if ! printf '%s\n' "$content" > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if [[ "$mode" != "private" ]] && ! chmod "$(_afk_tooling_default_mode)" "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
  return 0
}

# _afk_tooling_lock <lock_dir> / _afk_tooling_unlock <lock_dir>
# Serializes a read-modify-write between concurrent jobs. mkdir is atomic and,
# unlike flock, exists on macOS. A holder that died leaves the directory
# behind, so one older than AFK_TOOLING_LOCK_STALE_SEC (default 60), or dated
# in the future, is taken over. The wait is bounded by
# AFK_TOOLING_LOCK_WAIT_SEC (default 90, longer than the stale age so a dead
# holder delays a job instead of failing it).
#
# The holder writes an owner token into the lock, and unlock removes the lock
# only while that token is still its own: a holder that ran past the stale age
# and lost the lock must not release the lock of the job that took it over.
# Lock and unlock must run in the same shell, because the token is kept in
# this map; every caller in this file does that.
declare -gA _AFK_TOOLING_LOCK_TOKENS=()

# _afk_tooling_lock_is_stale <dir> <stale_sec>
_afk_tooling_lock_is_stale() {
  local mtime now
  mtime="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || printf '0')"
  now="$(date +%s)"
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
  (( mtime > 0 )) || return 1
  # A future mtime (clock step, copied directory) would otherwise make every
  # caller wait out the full bound until the clock catches up.
  (( now - mtime > $2 || mtime > now + 1 ))
}

# _afk_tooling_lock_reap <lock_dir> <stale_sec>
# Removes a stale lock. Only one waiter at a time may judge and remove it,
# and it looks again once it is alone: without that, a waiter that saw the
# stale lock could remove the fresh lock another waiter had just taken in its
# place, and both would be inside at once.
_afk_tooling_lock_reap() {
  local lock="$1" stale="$2" reap="$1.reap" rc=1
  if ! mkdir -- "$reap" 2>/dev/null; then
    # A waiter killed inside this section leaves the directory behind.
    if [[ -d "$reap" ]] && _afk_tooling_lock_is_stale "$reap" "$stale"; then
      rmdir -- "$reap" 2>/dev/null || true
    fi
    return 1
  fi
  if [[ -d "$lock" ]] && _afk_tooling_lock_is_stale "$lock" "$stale"; then
    rm -f -- "$lock/owner"
    rmdir -- "$lock" 2>/dev/null && rc=0
  fi
  rmdir -- "$reap" 2>/dev/null || true
  return "$rc"
}

_afk_tooling_lock() {
  local lock="$1" stale="${AFK_TOOLING_LOCK_STALE_SEC:-60}" wait_sec="${AFK_TOOLING_LOCK_WAIT_SEC:-90}"
  local tries=0 max_tries missing=0 token
  [[ "$stale" =~ ^[0-9]+$ ]] || stale=60
  [[ "$wait_sec" =~ ^[0-9]+$ ]] || wait_sec=90
  max_tries=$(( wait_sec * 10 ))
  # Jobs are subshells of one process, so $$ is shared; $BASHPID is not.
  token="${BASHPID:-$$}.${RANDOM}${RANDOM}"
  while ! mkdir -- "$lock" 2>/dev/null; do
    (( tries >= max_tries )) && return 1
    tries=$(( tries + 1 ))
    if [[ ! -d "$lock" ]]; then
      # Either it was released between the two checks, or the parent
      # directory cannot hold a lock at all; do not spin on the latter.
      missing=$(( missing + 1 ))
      (( missing > 20 )) && return 1
      continue
    fi
    missing=0
    if _afk_tooling_lock_is_stale "$lock" "$stale" && _afk_tooling_lock_reap "$lock" "$stale"; then
      continue
    fi
    sleep 0.1
  done
  if ! printf '%s\n' "$token" > "$lock/owner" 2>/dev/null; then
    rm -f -- "$lock/owner"
    rmdir -- "$lock" 2>/dev/null || true
    return 1
  fi
  _AFK_TOOLING_LOCK_TOKENS[$lock]="$token"
  return 0
}

_afk_tooling_unlock() {
  local lock="$1" mine owner
  mine="${_AFK_TOOLING_LOCK_TOKENS[$lock]:-}"
  _AFK_TOOLING_LOCK_TOKENS[$lock]=""
  [[ -n "$mine" ]] || return 0
  owner="$(cat -- "$lock/owner" 2>/dev/null || true)"
  # Taken over as stale: the lock there now belongs to another job.
  [[ "$owner" == "$mine" ]] || return 0
  rm -f -- "$lock/owner"
  rmdir -- "$lock" 2>/dev/null || true
}

_afk_tooling_registry_lock() {
  local reg_file
  reg_file="$(afk_tooling_registry_path)"
  mkdir -p "$(dirname -- "$reg_file")"
  if ! _afk_tooling_lock "${reg_file}.afk-lock"; then
    printf 'afk-tooling: could not lock %s; registry left unchanged\n' "$reg_file" >&2
    return 1
  fi
}

_afk_tooling_registry_unlock() {
  _afk_tooling_unlock "$(afk_tooling_registry_path).afk-lock"
}

_afk_tooling_default_registry() {
  jq -cn '{
    schema: "afk-tooling-registry/1",
    default_mcp_mode: "standalone",
    litellm_mcp_url: null,
    mcp_servers: {},
    skills: {},
    paperclip_central: null
  }'
}

afk_tooling_load_registry() {
  local reg_file content
  reg_file="$(afk_tooling_registry_path)"
  if [[ -f "$reg_file" ]]; then
    content="$(cat -- "$reg_file" 2>/dev/null || true)"
    if jq -es 'length == 1 and (.[0] | type == "object")' <<<"$content" >/dev/null 2>&1; then
      printf '%s\n' "$content"
      return 0
    fi
    # An empty or damaged file must not switch tooling off for good: every
    # caller feeds this to `jq --argjson`, which fails on anything else.
    printf 'afk-tooling: %s is not a JSON object; using an empty registry\n' "$reg_file" >&2
  fi
  _afk_tooling_default_registry
}

# afk_tooling_save_registry <content>
# Returns non-zero, leaving the file as it was, unless <content> is a JSON
# object. Callers that read, change and save hold _afk_tooling_registry_lock.
afk_tooling_save_registry() {
  local content="$1"
  local reg_file
  reg_file="$(afk_tooling_registry_path)"
  mkdir -p "$(dirname -- "$reg_file")"
  if ! _afk_tooling_write_json "$reg_file" "$content" private; then
    printf 'afk-tooling: refused to save %s: content is not a JSON object or the write failed\n' "$reg_file" >&2
    return 1
  fi
}

# afk_tooling_register_mcp <name> <transport:stdio|http|sse> <target_cmd_or_url> [<args_csv>] [<description>]
afk_tooling_register_mcp() {
  local name="$1" transport="${2:-stdio}" target="$3" args_csv="${4:-}" desc="${5:-}"
  local reg args_json="[]" save_rc=0
  if [[ -n "$args_csv" ]]; then
    args_json="$(printf '%s' "$args_csv" | jq -Rc 'split(",") | map(select(length > 0))')"
  fi
  _afk_tooling_registry_lock || return 1
  reg="$(afk_tooling_load_registry)"
  reg="$(jq -c \
    --arg n "$name" \
    --arg tr "$transport" \
    --arg tg "$target" \
    --arg d "$desc" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson ar "$args_json" \
    '.mcp_servers[$n] = (
      if $tr == "stdio" then
        {name: $n, transport: "stdio", command: $tg, args: $ar, description: $d, source: "local", updated_at: $ts}
      else
        {name: $n, transport: $tr, url: $tg, description: $d, source: "local", updated_at: $ts}
      end
    )' <<<"$reg")"
  afk_tooling_save_registry "$reg" || save_rc=1
  _afk_tooling_registry_unlock
  (( save_rc == 0 )) || return 1
  jq -c --arg n "$name" '.mcp_servers[$n]' <<<"$reg"
}

# afk_tooling_register_skill <name> <source_dir> [<description>] [<source_tag>]
afk_tooling_register_skill() {
  local name="$1" src_dir="$2" desc="${3:-}" src_tag="${4:-local}"
  local abs_src
  abs_src="$(cd -P -- "$src_dir" 2>/dev/null && pwd -P)" || {
    printf 'afk_tooling_register_skill: invalid skill directory: %s\n' "$src_dir" >&2
    return 1
  }
  if [[ -z "$desc" && -f "$abs_src/SKILL.md" ]]; then
    desc="$(sed -n 's/^description:[[:space:]]*//p' "$abs_src/SKILL.md" 2>/dev/null | head -n 1 | tr -d '"' || true)"
  fi
  local reg save_rc=0
  _afk_tooling_registry_lock || return 1
  reg="$(afk_tooling_load_registry)"
  reg="$(jq -c \
    --arg n "$name" \
    --arg p "$abs_src" \
    --arg d "$desc" \
    --arg st "$src_tag" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.skills[$n] = {name: $n, path: $p, description: $d, source: $st, updated_at: $ts}' <<<"$reg")"
  afk_tooling_save_registry "$reg" || save_rc=1
  _afk_tooling_registry_unlock
  (( save_rc == 0 )) || return 1
  jq -c --arg n "$name" '.skills[$n]' <<<"$reg"
}

# Helper to scan a skills directory into JSON array [{name, path, scope, is_bmad}]
_afk_tooling_scan_skills_dir() {
  local dir="$1" scope="$2"
  [[ -d "$dir" ]] || { printf '[]\n'; return 0; }
  local items="[]" d sname is_bmad
  for d in "$dir"/*; do
    [[ -d "$d" && -f "$d/SKILL.md" ]] || continue
    sname="$(basename -- "$d")"
    is_bmad=false
    [[ "$sname" == bmad-* ]] && is_bmad=true
    items="$(jq -c --arg n "$sname" --arg p "$d" --arg sc "$scope" --argjson bm "$is_bmad" \
      '. + [{name: $n, path: $p, scope: $sc, is_bmad: $bm}]' <<<"$items")"
  done
  printf '%s\n' "$items"
}

# Helper to scan MCP server names from standard project/host config files
_afk_tooling_scan_mcp_file() {
  local file="$1" format="$2" scope="$3"
  [[ -f "$file" ]] || { printf '[]\n'; return 0; }
  case "$format" in
    mcp_json)
      jq -c --arg sc "$scope" --arg src "$file" '
        [ (.mcpServers // {}) | to_entries[] | {
            name: .key,
            transport: (if .value.url then (.value.type // "http") else "stdio" end),
            scope: $sc,
            source: $src,
            via_litellm: (((.value.url // "") | test("litellm|/mcp")) or ((.value.headers["x-litellm-mcp"] // "") != ""))
          } ]
      ' "$file" 2>/dev/null || printf '[]\n'
      ;;
    opencode_json)
      jq -c --arg sc "$scope" --arg src "$file" '
        [ (.mcp // {}) | to_entries[] | {
            name: .key,
            transport: (.value.type // "local"),
            scope: $sc,
            source: $src,
            via_litellm: ((.value.url // "") | test("litellm|/mcp"))
          } ]
      ' "$file" 2>/dev/null || printf '[]\n'
      ;;
    *)
      printf '[]\n'
      ;;
  esac
}

# _afk_tooling_project_cfg <abs_repo>
# Prints the repo's .afk/config.json, or {} when there is none. An empty or
# unparseable file also prints {} but returns 1 so the caller can warn:
# passed on as it is, it makes `jq --argjson` fail and the job silently runs
# with no tooling at all.
_afk_tooling_project_cfg() {
  local abs_repo="${1:-}" content
  if [[ -z "$abs_repo" || ! -f "$abs_repo/.afk/config.json" ]]; then
    printf '{}\n'
    return 0
  fi
  content="$(cat -- "$abs_repo/.afk/config.json" 2>/dev/null || true)"
  if jq -es 'length == 1 and (.[0] | type == "object")' <<<"$content" >/dev/null 2>&1; then
    printf '%s\n' "$content"
    return 0
  fi
  printf '{}\n'
  return 1
}

# _afk_tooling_url_origin <url>
# Prints scheme://host[:port] only. Server URLs can carry a token in the
# path, query string or userinfo, so logs never get the full URL.
_afk_tooling_url_origin() {
  local url="$1" scheme="" rest
  rest="$url"
  if [[ "$url" == *"://"* ]]; then
    scheme="${url%%://*}://"
    rest="${url#*://}"
  fi
  rest="${rest%%[/?#]*}"
  rest="${rest##*@}"
  printf '%s%s\n' "$scheme" "$rest"
}

# _afk_tooling_resolve_effective <repo_path> [<cli_mode>] [<cli_mcp_csv>] [<cli_skills_csv>] [<cli_litellm_url>] [<slug>]
# Resolves effective {config_source, mcp_mode, litellm_mcp_url, enabled_mcp, enabled_skills, paperclip_central}
# using strict 3-tier precedence:
#   CLI / Repo Override (.afk/config.json) > Paperclip Central Studio > Standalone Local Registry
_afk_tooling_resolve_effective() {
  local abs_repo="${1:-}" cli_mode="${2:-}" cli_mcp="${3:-}" cli_skills="${4:-}" cli_lurl="${5:-}" slug="${6:-}"
  local reg proj_cfg="{}"
  reg="$(afk_tooling_load_registry)"
  proj_cfg="$(_afk_tooling_project_cfg "$abs_repo")" \
    || printf 'afk-tooling: ignoring %s/.afk/config.json: it is not a JSON object\n' "$abs_repo" >&2

  local cli_mcp_arr="null" cli_skills_arr="null"
  if [[ -n "$cli_mcp" ]]; then
    cli_mcp_arr="$(printf '%s' "$cli_mcp" | jq -Rc 'split(",") | map(select(length > 0))')"
  fi
  if [[ -n "$cli_skills" ]]; then
    cli_skills_arr="$(printf '%s' "$cli_skills" | jq -Rc 'split(",") | map(select(length > 0))')"
  fi

  jq -cn \
    --arg cmode "$cli_mode" \
    --arg clurl "$cli_lurl" \
    --arg env_lurl "${AFK_LITELLM_BASE_URL:-}" \
    --arg slug "$slug" \
    --argjson cmcp "$cli_mcp_arr" \
    --argjson csk "$cli_skills_arr" \
    --argjson cfg "$proj_cfg" \
    --argjson reg "$reg" \
    '
    ($cfg.tooling // null) as $rt
    | ($reg.paperclip_central // null) as $pc
    | (($cmode != "") or ($clurl != "") or ($cmcp != null) or ($csk != null)) as $has_cli
    | (($rt != null) and (($rt.source // "repo-override") == "repo-override")) as $has_repo_ovr
    | (
        if $has_cli or $has_repo_ovr then "repo-override"
        elif $pc != null then "paperclip-central"
        else "standalone-local"
        end
      ) as $src
    | (
        if $clurl != "" then $clurl
        elif $env_lurl != "" then $env_lurl
        elif $has_repo_ovr and (($rt.litellm_mcp_url // "") != "") then $rt.litellm_mcp_url
        elif ($cfg.router.litellm_base_url // "") != "" then $cfg.router.litellm_base_url
        elif ($pc != null) and (($pc.litellm_mcp_url // "") != "") then $pc.litellm_mcp_url
        else ($reg.litellm_mcp_url // "")
        end
      ) as $lurl
    | (
        if $cmode != "" then $cmode
        elif $has_repo_ovr and (($rt.mcp_mode // "") != "") then $rt.mcp_mode
        elif ($pc != null) and (($pc.mcp_mode // "") != "") then
          (if ($pc.mcp_mode == "standalone") and ($lurl != "") and (($pc.litellm_mcp_url // "") != "") then "litellm" else $pc.mcp_mode end)
        elif $lurl != "" then "litellm"
        else ($reg.default_mcp_mode // "standalone")
        end
      ) as $mode
    | (
        if $cmcp != null then $cmcp
        elif $has_repo_ovr then ($rt.enabled_mcp // [])
        elif $pc != null then ($pc.enabled_mcp // [])
        else ($rt.enabled_mcp // [])
        end
      ) as $emcp
    | (
        if $pc != null then
          (($pc.source_skill // "afk-fleet-tooling") as $carrier |
           (
             ($pc.enabled_skills // [])
             + [ ($pc.desired_skills // [])[] | select(. != $carrier) ]
             + (if $slug != "" then [ (($pc.agent_desired_skills // {})[$slug] // [])[] | select(. != $carrier) ] else [] end)
           ) | map(select(type == "string" and length > 0)) | unique)
        else []
        end
      ) as $pc_skills
    | (
        if $csk != null then $csk
        elif $has_repo_ovr then ($rt.enabled_skills // [])
        elif $pc != null then $pc_skills
        else ($rt.enabled_skills // [])
        end
      ) as $eskills
    | {
        config_source: $src,
        mcp_mode: $mode,
        litellm_mcp_url: (if $lurl == "" then null else $lurl end),
        enabled_mcp: $emcp,
        enabled_skills: $eskills,
        paperclip_central: $pc
      }
    '
}

# _afk_tooling_render_mcp_doc <existing_mcp_doc> <mcp_mode> <litellm_url> <mcp_arr_json> <reg_json>
# Prints JSON {doc: <mcp.json object>, synced_mcp: [<names>]}
_afk_tooling_render_mcp_doc() {
  local existing_doc="${1:-}" mcp_mode="$2" litellm_url="$3" mcp_arr="$4" reg="$5"
  [[ -n "$existing_doc" ]] || existing_doc="{}"
  local base_gw="${litellm_url%/}"
  [[ -n "$base_gw" ]] || base_gw="http://localhost:4000"

  jq -cn \
    --arg mode "$mcp_mode" \
    --arg gw "$base_gw" \
    --argjson doc "$existing_doc" \
    --argjson names "$mcp_arr" \
    --argjson reg "$reg" \
    '
    if $mode == "litellm" then
      (
        [ $names[] as $n
          | ($reg.mcp_servers[$n] // null) as $srv
          | {
              key: $n,
              value: (
                if ($srv != null) and (($srv.source // "") == "paperclip") and (($srv.url // "") != "") then
                  ({type: ($srv.transport // "http"), url: $srv.url}
                   + (if ($srv.headers // null) != null then {headers: $srv.headers} else {} end))
                else
                  {
                    type: "http",
                    url: ($gw + "/mcp/" + $n),
                    headers: {"x-litellm-mcp": "true"}
                  }
                end
              )
            }
        ] | from_entries
      ) as $entries
      | {
          doc: ($doc | .mcpServers = ((.mcpServers // {}) + $entries)),
          synced_mcp: $names
        }
    else
      (
        [ $names[] as $n
          | ($reg.mcp_servers[$n] // null)
          | select(. != null)
          | {
              key: $n,
              value: (
                if .transport == "stdio" then
                  ({command: .command, args: (.args // [])}
                   + (if (.env // null) != null then {env: .env} else {} end))
                else
                  ({type: .transport, url: .url}
                   + (if (.headers // null) != null then {headers: .headers} else {} end))
                end
              )
            }
        ]
      ) as $pairs
      | {
          doc: ($doc | .mcpServers = ((.mcpServers // {}) + ($pairs | from_entries))),
          synced_mcp: [ $pairs[].key ]
        }
    end
    '
}

# _afk_tooling_render_opencode_doc <existing_oc_doc> <mcp_json_doc>
# Translates `.mcpServers` entries into OpenCode `opencode.json` `.mcp` format.
_afk_tooling_render_opencode_doc() {
  local existing_oc="${1:-}" mcp_doc="${2:-}"
  [[ -n "$existing_oc" ]] || existing_oc="{}"
  [[ -n "$mcp_doc" ]] || mcp_doc="{}"
  jq -cn \
    --argjson oc "$existing_oc" \
    --argjson mdoc "$mcp_doc" \
    '
    (
      [ ($mdoc.mcpServers // {}) | to_entries[] | {
          key: .key,
          value: (
            if (.value.url // "") != "" then
              ({type: "remote", url: .value.url, enabled: true}
               + (if (.value.headers // null) != null then {headers: .value.headers} else {} end))
            else
              ({type: "local", command: ([.value.command] + (.value.args // [])), enabled: true}
               + (if (.value.environment // .value.env // null) != null then {environment: (.value.environment // .value.env)} else {} end))
            end
          )
        } ] | from_entries
    ) as $entries
    | ($oc | .mcp = ((.mcp // {}) + $entries))
    '
}

# afk_tooling_discover [<repo_path>] [<slug>]
# Discovers all project-level and centralized/host-level Skills and MCP servers,
# plus the active 3-tier config source (`repo-override` | `paperclip-central` | `standalone-local`).
afk_tooling_discover() {
  local repo="${1:-}" slug="${2:-}" abs_repo=""
  if [[ -n "$repo" && -d "$repo" ]]; then
    abs_repo="$(cd -P -- "$repo" 2>/dev/null && pwd -P)" || abs_repo=""
  fi

  local reg eff config_source mcp_mode litellm_url pc_central
  reg="$(afk_tooling_load_registry)"
  eff="$(_afk_tooling_resolve_effective "$abs_repo" "" "" "" "" "$slug")"
  config_source="$(jq -r '.config_source' <<<"$eff")"
  mcp_mode="$(jq -r '.mcp_mode' <<<"$eff")"
  litellm_url="$(jq -r '.litellm_mcp_url // empty' <<<"$eff")"
  pc_central="$(jq -c '.paperclip_central // null' <<<"$eff")"

  # 1. Project skills
  local proj_skills="[]"
  if [[ -n "$abs_repo" ]]; then
    local ps1 ps2
    ps1="$(_afk_tooling_scan_skills_dir "$abs_repo/.agents/skills" "project")"
    ps2="$(_afk_tooling_scan_skills_dir "$abs_repo/.claude/skills" "project-claude")"
    proj_skills="$(jq -cs '.[0] + .[1] | unique_by(.name)' <(printf '%s' "$ps1") <(printf '%s' "$ps2"))"
  fi

  # 2. Host / central skills
  local host_skills="[]"
  if [[ -z "${AFK_TOOLING_HERMETIC:-}" ]]; then
    local hs1 hs2 hs3 pc_sdir
    pc_sdir="$(afk_tooling_paperclip_skills_dir)"
    hs1="$(_afk_tooling_scan_skills_dir "$HOME/.agents/skills" "host-global")"
    hs2="$(_afk_tooling_scan_skills_dir "$HOME/.config/afk/skills" "afk-central")"
    hs3="$(_afk_tooling_scan_skills_dir "$pc_sdir" "paperclip-store")"
    host_skills="$(jq -cs '.[0] + .[1] + .[2] | unique_by(.name)' <(printf '%s' "$hs1") <(printf '%s' "$hs2") <(printf '%s' "$hs3"))"
  fi

  # 3. Project MCP servers
  local proj_mcp="[]"
  if [[ -n "$abs_repo" ]]; then
    local pm1 pm2 pm3
    pm1="$(_afk_tooling_scan_mcp_file "$abs_repo/.mcp.json" "mcp_json" "project")"
    pm2="$(_afk_tooling_scan_mcp_file "$abs_repo/.cursor/mcp.json" "mcp_json" "project-cursor")"
    pm3="$(_afk_tooling_scan_mcp_file "$abs_repo/opencode.json" "opencode_json" "project-opencode")"
    proj_mcp="$(jq -cs '.[0] + .[1] + .[2] | unique_by(.name)' <(printf '%s' "$pm1") <(printf '%s' "$pm2") <(printf '%s' "$pm3"))"
  fi

  # 4. Host MCP servers (Antigravity MCP dirs + Claude global MCPs)
  local host_mcp="[]"
  if [[ -z "${AFK_TOOLING_HERMETIC:-}" ]]; then
    local agy_mcp="[]" d mname
    if [[ -d "$HOME/.gemini/antigravity-cli/mcp" ]]; then
      for d in "$HOME/.gemini/antigravity-cli/mcp"/*; do
        [[ -d "$d" ]] || continue
        mname="$(basename -- "$d")"
        agy_mcp="$(jq -c --arg n "$mname" --arg p "$d" '. + [{name: $n, transport: "agy-managed", scope: "host-agy", source: $p, via_litellm: false}]' <<<"$agy_mcp")"
      done
    fi
    local cl_mcp="[]"
    cl_mcp="$(_afk_tooling_scan_mcp_file "$HOME/.claude.json" "mcp_json" "host-claude")"
    host_mcp="$(jq -cs '.[0] + .[1] | unique_by(.name)' <(printf '%s' "$agy_mcp") <(printf '%s' "$cl_mcp"))"
  fi

  jq -cn \
    --arg repo "$abs_repo" \
    --arg src "$config_source" \
    --arg mode "$mcp_mode" \
    --arg lurl "$litellm_url" \
    --argjson eff "$eff" \
    --argjson pc "$pc_central" \
    --argjson pskills "$proj_skills" \
    --argjson hskills "$host_skills" \
    --argjson pmcp "$proj_mcp" \
    --argjson hmcp "$host_mcp" \
    --argjson reg "$reg" \
    '{
      schema: "afk-tooling-inventory/1",
      repo_path: (if $repo == "" then null else $repo end),
      config_source: $src,
      mcp_mode: $mode,
      litellm_mcp_url: (if $lurl == "" then null else $lurl end),
      effective_enabled_mcp: $eff.enabled_mcp,
      effective_enabled_skills: $eff.enabled_skills,
      paperclip_central: $pc,
      project: {
        skills_count: ($pskills | length),
        non_bmad_skills_count: ([ $pskills[] | select(.is_bmad | not) ] | length),
        skills: $pskills,
        mcp_count: ($pmcp | length),
        mcp_servers: $pmcp
      },
      host: {
        skills_count: ($hskills | length),
        skills: $hskills,
        mcp_count: ($hmcp | length),
        mcp_servers: $hmcp
      },
      central_catalog: {
        mcp_servers: ($reg.mcp_servers | keys),
        skills: ($reg.skills | keys)
      }
    }'
}

# The result every failed sync prints: same keys as a success, ok:false.
_afk_tooling_sync_fail() {
  jq -cn --arg e "$1" '{schema:"afk-paperclip-skills-sync/1", ok:false, error:$e, synced_count:0, skipped_bundled_count:0, synced_skills:[]}'
}

# afk_tooling_sync_paperclip_skills [<api_url>] [<key>] [<company_id>] [<host_agent_id>]
# Pulls the Paperclip Company Skills Store (`GET /api/companies/{companyId}/skills`
# and `/files?path=...`, Paperclip v2026.1106.0+) plus agent `desiredSkills` into AFK:
#   - Automatically skips Paperclip's internal read-only `bundled/paperclip-core` skills
#     (`paperclip`, `complain`, `first-task`, `agentmail`, etc.) UNLESS explicitly attached
#     to an AFK agent via `desiredSkills`.
#   - Extracts central MCP gateway/server configuration from Studio `mcp.json` / `tooling.json`
#     (such as `afk-fleet-tooling`) into `reg.paperclip_central` + `reg.mcp_servers`.
afk_tooling_sync_paperclip_skills() {
  local api_url="${1:-}" key="${2:-}" company_id="${3:-}" host_agent_id="${4:-}"
  declare -F afk_pc_curl >/dev/null 2>&1 || . "$(dirname -- "${BASH_SOURCE[0]}")/afk-paperclip.sh"

  local pc_cfg="" save_rc=0
  if [[ -z "$api_url" || -z "$company_id" || -z "$key" || -z "$host_agent_id" ]]; then
    local pc_cfg_path key_ref
    pc_cfg_path="$(afk_pc_config_path)"
    if [[ -f "$pc_cfg_path" ]]; then
      pc_cfg="$(cat -- "$pc_cfg_path" 2>/dev/null || true)"
      [[ -n "$api_url" ]] || api_url="$(jq -r '.api_url // empty' <<<"$pc_cfg" 2>/dev/null)"
      [[ -n "$company_id" ]] || company_id="$(jq -r '.company_id // empty' <<<"$pc_cfg" 2>/dev/null)"
      [[ -n "$host_agent_id" ]] || host_agent_id="$(jq -r '.host.agent_id // empty' <<<"$pc_cfg" 2>/dev/null)"
      if [[ -z "$key" ]]; then
        key_ref="$(jq -r '.host.key_ref // empty' <<<"$pc_cfg" 2>/dev/null)"
        if [[ -n "$key_ref" ]]; then
          # shellcheck disable=SC2034 # read by afk_pc_read_key (lib/afk-paperclip.sh)
          AFK_PC_CFG="$pc_cfg"
          key="$(afk_pc_read_key "$key_ref" 2>/dev/null || true)"
        fi
      fi
    fi
  fi

  if [[ -z "$api_url" || -z "$company_id" || -z "$key" ]]; then
    jq -cn '{schema:"afk-paperclip-skills-sync/1", ok:false, error:"PAPERCLIP_NOT_CONFIGURED", synced_count:0, skipped_bundled_count:0, synced_skills:[]}'
    return 1
  fi

  # 1. Inspect desiredSkills attached to the AFK host agent & any active hired project agents
  local host_desired_refs="[]" host_desired_slugs="[]" agent_desired_map="{}" all_desired_refs="[]"
  if [[ -n "$host_agent_id" ]]; then
    local ha_resp ha_code ha_body
    ha_resp="$(afk_pc_curl GET "$api_url/api/agents/$host_agent_id/skills" "$key" "")"
    ha_code="${ha_resp%%$'\n'*}"
    ha_body="${ha_resp#*$'\n'}"
    # A failed lookup is not "nothing attached". Carrying on would delete the
    # bundled skills this agent wants and save the empty answer as the new
    # snapshot, so stop here and keep the previous one.
    if [[ "$ha_code" != 2?? ]] || ! jq -e 'type == "object"' <<<"$ha_body" >/dev/null 2>&1; then
      _afk_tooling_sync_fail "AGENT_SKILLS_HTTP_${ha_code:-000}"
      return 1
    fi
    host_desired_refs="$(jq -c '
      (
        [ (.desiredSkills // [])[] | tostring, (tostring | split("/") | last) ]
        + [ (.desiredSkillEntries // [])[] | (.slug // empty), (.key // empty), (.id // empty) ]
      ) | map(select(length > 0)) | unique
    ' <<<"$ha_body" 2>/dev/null || printf '[]')"
    host_desired_slugs="$(jq -c '
      (
        [ (.desiredSkills // [])[] | tostring | split("/") | last ]
        + [ (.desiredSkillEntries // [])[] | (.slug // empty) ]
      ) | map(select(length > 0)) | unique
    ' <<<"$ha_body" 2>/dev/null || printf '[]')"
  fi

  if declare -F afk_pch_load_ledger >/dev/null 2>&1; then
    local ledger_json
    ledger_json="$(afk_pch_load_ledger 2>/dev/null || printf '{}')"
    local -a hired_pairs=()
    # The ledger keeps each agent's lifecycle in `state` (`status` only marks
    # a hire waiting for approval). Idle agents keep their skills; paused and
    # terminated ones do not run. A `local-*` id is a placeholder for an agent
    # Paperclip never created, so there is nothing to ask about.
    mapfile -t hired_pairs < <(jq -r '
      (.projects // {}) | to_entries[] as $p
      | ($p.value.agents // {}) | to_entries[]
      | select(((.value.state // "") == "active" or (.value.state // "") == "idle")
               and ((.value.agent_id // "") | type == "string")
               and (.value.agent_id // "") != ""
               and ((.value.agent_id // "") | startswith("local-") | not))
      | "\($p.key)|\(.value.agent_id)"
    ' <<<"$ledger_json" 2>/dev/null || true)
    local hp p_slug p_aid pa_resp pa_code pa_body p_slugs p_refs
    for hp in "${hired_pairs[@]:-}"; do
      [[ -n "$hp" ]] || continue
      p_slug="${hp%%|*}"
      p_aid="${hp#*|}"
      [[ "$p_aid" =~ ^[A-Za-z0-9_-]+$ ]] || continue
      pa_resp="$(afk_pc_curl GET "$api_url/api/agents/$p_aid/skills" "$key" "")"
      pa_code="${pa_resp%%$'\n'*}"
      pa_body="${pa_resp#*$'\n'}"
      # An agent Paperclip no longer knows has no skills to sync; that is an
      # answer, not a failed lookup.
      [[ "$pa_code" == "404" ]] && continue
      # Same rule as the host agent above: an unanswered lookup aborts.
      if [[ "$pa_code" != 2?? ]] || ! jq -e 'type == "object"' <<<"$pa_body" >/dev/null 2>&1; then
        _afk_tooling_sync_fail "AGENT_SKILLS_HTTP_${pa_code:-000}"
        return 1
      fi
      p_slugs="$(jq -c '([ (.desiredSkills // [])[] | tostring | split("/") | last ] + [ (.desiredSkillEntries // [])[] | (.slug // empty) ]) | map(select(length > 0)) | unique' <<<"$pa_body" 2>/dev/null || printf '[]')"
      p_refs="$(jq -c '([ (.desiredSkills // [])[] | tostring, (tostring | split("/") | last) ] + [ (.desiredSkillEntries // [])[] | (.slug // empty), (.key // empty), (.id // empty) ]) | map(select(length > 0)) | unique' <<<"$pa_body" 2>/dev/null || printf '[]')"
      agent_desired_map="$(jq -c --arg s "$p_slug" --argjson sl "$p_slugs" '.[$s] = (((.[$s] // []) + $sl) | unique)' <<<"$agent_desired_map")"
      all_desired_refs="$(jq -c --argjson r "$p_refs" '(. + $r) | unique' <<<"$all_desired_refs")"
    done
  fi
  all_desired_refs="$(jq -c --argjson hr "$host_desired_refs" '(. + $hr) | unique' <<<"$all_desired_refs")"

  # 2. Fetch Company Skills inventory
  local resp code body
  resp="$(afk_pc_curl GET "$api_url/api/companies/$company_id/skills" "$key" "")"
  code="${resp%%$'\n'*}"
  body="${resp#*$'\n'}"
  if [[ "$code" != 2?? ]] || ! jq -e 'type == "array"' <<<"$body" >/dev/null 2>&1; then
    jq -cn --arg c "$code" '{schema:"afk-paperclip-skills-sync/1", ok:false, error:("HTTP_" + $c), synced_count:0, skipped_bundled_count:0, synced_skills:[]}'
    return 1
  fi

  local dest_root dest_real stage
  dest_root="$(afk_tooling_paperclip_skills_dir)"
  mkdir -p "$dest_root"
  dest_real="$(cd -P -- "$dest_root" 2>/dev/null && pwd -P)" || dest_real="$dest_root"
  # Staging directories left by a sync that was killed. A running sync's own
  # is minutes old at most, so only old ones are removed.
  find "$dest_root" -mindepth 1 -maxdepth 1 -type d -name '.staging.*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true
  # Every skill is fetched into a staging directory, and the store and the
  # registry change only once all fetches are in and every bundle parsed. A
  # sync that stops part way therefore leaves both as they were, and a file
  # removed upstream cannot linger in the store and fail later syncs.
  if ! stage="$(mktemp -d "$dest_root/.staging.XXXXXX" 2>/dev/null)"; then
    _afk_tooling_sync_fail "SKILLS_STORE_UNWRITABLE"
    return 1
  fi

  local synced="[]" skipped_bundled=0 central_source="" central_mode="" central_lurl="" central_mcp="[]" central_skills="[]"
  local bundle_servers="{}" skill_entries="{}" entry_ts
  local row sid sslug skey sdesc is_bundled is_desired fpath enc_path f_resp f_code f_body f_content sdir live_dir
  local -a rows=()
  entry_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  mapfile -t rows < <(jq -c '.[] | select((.slug // "") != "")' <<<"$body" 2>/dev/null)

  for row in "${rows[@]:-}"; do
    [[ -n "$row" ]] || continue
    sid="$(jq -r '.id // empty' <<<"$row")"
    sslug="$(jq -r '.slug // empty' <<<"$row")"
    skey="$(jq -r '.key // empty' <<<"$row")"
    sdesc="$(jq -r '.description // ""' <<<"$row")"
    # The slug becomes a directory name under the skills store. No leading
    # dot: `.` and `..` would write this row's files into the store itself or
    # its parent, where the registry lives.
    [[ "$sslug" =~ ^[a-zA-Z0-9_-][a-zA-Z0-9._-]*$ && -n "$sid" ]] || continue

    is_bundled="$(jq -r '
      if (((.folderPath // "") | startswith("bundled/"))
          or ((.sourceLabel // "") == "Paperclip bundled")
          or ((.key // "") | startswith("paperclipai/paperclip/")))
      then "true" else "false" end
    ' <<<"$row")"
    is_desired="$(jq -r --arg id "$sid" --arg sl "$sslug" --arg ky "$skey" '
      if any(.[]; . == $id or . == $sl or . == $ky) then "true" else "false" end
    ' <<<"$all_desired_refs")"

    # Its store directory goes with the prune at the end, like any skill
    # that was not synced.
    if [[ "$is_bundled" == "true" && "$is_desired" != "true" ]]; then
      skipped_bundled=$((skipped_bundled + 1))
      continue
    fi

    sdir="$stage/$sslug"
    live_dir="$dest_root/$sslug"
    # Skill files can carry MCP headers or env from Studio (bearer tokens),
    # so everything in the store is written owner-only.
    ( umask 077; mkdir -p "$sdir" )

    local -a fpaths=()
    mapfile -t fpaths < <(jq -r '(.fileInventory // [{path:"SKILL.md"}])[]?.path // empty' <<<"$row" 2>/dev/null)
    (( ${#fpaths[@]} > 0 )) || fpaths=("SKILL.md")
    if [[ "$sslug" == "afk-fleet-tooling" ]]; then
      local has_mcp_f=false fp_chk
      for fp_chk in "${fpaths[@]}"; do
        [[ "$fp_chk" == "mcp.json" ]] && has_mcp_f=true
      done
      [[ "$has_mcp_f" == "true" ]] || fpaths+=("mcp.json")
    fi

    for fpath in "${fpaths[@]}"; do
      [[ -n "$fpath" && "$fpath" != *".."* && "$fpath" != /* ]] || continue
      enc_path="$(jq -rn --arg v "$fpath" '$v | @uri')"
      f_resp="$(afk_pc_curl GET "$api_url/api/companies/$company_id/skills/$sid/files?path=$enc_path" "$key" "")"
      f_code="${f_resp%%$'\n'*}"
      f_body="${f_resp#*$'\n'}"
      f_content=""
      if [[ "$f_code" == 2?? ]]; then
        f_content="$(jq -r '.content // empty' <<<"$f_body" 2>/dev/null || true)"
      fi
      if [[ -n "$f_content" ]]; then
        if ! ( umask 077; mkdir -p "$(dirname -- "$sdir/$fpath")" && printf '%s\n' "$f_content" > "$sdir/$fpath" ); then
          rm -rf -- "$stage"
          _afk_tooling_sync_fail "SKILLS_STORE_UNWRITABLE"
          return 1
        fi
      elif [[ "$f_code" != "404" && -f "$live_dir/$fpath" ]]; then
        # A file that could not be fetched this time keeps its previous copy;
        # a 404 means it is gone upstream, so it is not carried over.
        ( umask 077; mkdir -p "$(dirname -- "$sdir/$fpath")" && cp -- "$live_dir/$fpath" "$sdir/$fpath" ) 2>/dev/null || true
      fi
    done

    if [[ -f "$sdir/SKILL.md" ]]; then
      if [[ -z "$sdesc" ]]; then
        sdesc="$(sed -n 's/^description:[[:space:]]*//p' "$sdir/SKILL.md" 2>/dev/null | head -n 1 | tr -d '"' || true)"
      fi
      skill_entries="$(jq -c --arg n "$sslug" --arg p "$dest_real/$sslug" --arg d "$sdesc" --arg ts "$entry_ts" \
        '.[$n] = {name: $n, path: $p, description: $d, source: "paperclip", updated_at: $ts}' <<<"$skill_entries")"
      synced="$(jq -c --arg s "$sslug" --arg id "$sid" --arg p "$live_dir" '. + [{slug:$s, skill_id:$id, path:$p}]' <<<"$synced")"
    fi

    # Extract Central MCP / Tooling bundle if skill ships mcp.json, .mcp.json, or tooling.json
    local cfg_cand=""
    for cfg_cand in "$sdir/mcp.json" "$sdir/.mcp.json" "$sdir/tooling.json"; do
      [[ -f "$cfg_cand" ]] || continue
      if jq -e 'type == "object"' "$cfg_cand" >/dev/null 2>&1; then
        local now_iso parsed_bundle
        now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        parsed_bundle="$(jq -cn \
          --slurpfile b "$cfg_cand" \
          --arg ts "$now_iso" \
          '
          ($b[0]) as $doc
          | (($doc.mcpServers // $doc.mcp_servers // $doc.mcp // {}) | if type == "object" then . else {} end) as $srvs
          | (
              [ $srvs | to_entries[] | {
                  key: .key,
                  value: (
                    if (.value.url // "") != "" then
                      ({
                        name: .key,
                        transport: (if (.value.type // "") == "sse" then "sse" else "http" end),
                        url: .value.url,
                        description: (.value.description // "Synced from Paperclip Studio"),
                        source: "paperclip",
                        updated_at: $ts
                      } + (if (.value.headers // null) != null then {headers: .value.headers} else {} end))
                    else
                      ({
                        name: .key,
                        transport: "stdio",
                        command: (if (.value.command | type) == "array" then (.value.command[0] // "") else (.value.command // "") end),
                        args: (if (.value.command | type) == "array" then (.value.command[1:] // []) else (.value.args // []) end),
                        description: (.value.description // "Synced from Paperclip Studio"),
                        source: "paperclip",
                        updated_at: $ts
                      } + (if (.value.env // .value.environment // null) != null then {env: (.value.env // .value.environment)} else {} end))
                    end
                  )
                } ] | from_entries
            ) as $norm_srvs
          | (
              if ($doc.litellm_mcp_url // "") != "" then $doc.litellm_mcp_url
              else
                ([ $srvs | to_entries[] | .value.url // empty | select(test("litellm|/mcp$")) ][0] // ""
                 | sub("/mcp/?$"; ""))
              end
            ) as $det_lurl
          | (
              if ($doc.mcp_mode // "") != "" then $doc.mcp_mode
              elif $det_lurl != "" and (($srvs | length) == 0) then "litellm"
              elif ($srvs | length) > 0 and ([ $norm_srvs[] | select(.transport != "stdio") ] | length) > 0 and $det_lurl != "" then "litellm"
              else "standalone"
              end
            ) as $det_mode
          | (
              if ($doc.enabled_mcp | type) == "array" then $doc.enabled_mcp
              else ($srvs | keys)
              end
            ) as $det_emcp
          | (
              if ($doc.enabled_skills | type) == "array" then $doc.enabled_skills
              else []
              end
            ) as $det_eskills
          | {
              servers: $norm_srvs,
              mcp_mode: $det_mode,
              litellm_mcp_url: $det_lurl,
              enabled_mcp: $det_emcp,
              enabled_skills: $det_eskills
            }
          ' 2>/dev/null || true)"
        # The filter fails on shapes it does not know (a server given as a
        # string, say) and then prints nothing. Saving that would empty the
        # registry, so the sync stops before anything is applied.
        if ! jq -e '(.servers | type == "object") and (.enabled_mcp | type == "array") and (.enabled_skills | type == "array")' <<<"$parsed_bundle" >/dev/null 2>&1; then
          printf 'afk-tooling: %s of Studio skill %s is not a usable tooling bundle (each MCP server must be an object); sync aborted, the skills store and the registry were not changed\n' "$(basename -- "$cfg_cand")" "$sslug" >&2
          rm -rf -- "$stage"
          _afk_tooling_sync_fail "INVALID_TOOLING_BUNDLE"
          return 1
        fi
        bundle_servers="$(jq -c --argjson pb "$parsed_bundle" '. + $pb.servers' <<<"$bundle_servers")"

        if [[ -z "$central_source" || "$sslug" == "afk-fleet-tooling" ]]; then
          central_source="$sslug"
          central_mode="$(jq -r '.mcp_mode' <<<"$parsed_bundle")"
          central_lurl="$(jq -r '.litellm_mcp_url // empty' <<<"$parsed_bundle")"
        fi
        central_mcp="$(jq -cn --argjson a "$central_mcp" --argjson b "$(jq -c '.enabled_mcp' <<<"$parsed_bundle")" '($a + $b) | unique')"
        central_skills="$(jq -cn --argjson a "$central_skills" --argjson b "$(jq -c '.enabled_skills' <<<"$parsed_bundle")" '($a + $b) | unique')"
        break
      fi
    done
  done

  # 3. Apply: one registry save, then the store. Both happen under the
  # registry lock so two syncs never swap the same skill directory at once.
  # The save comes first so a save that fails leaves the store untouched, and
  # the prune comes last so a saved registry never points at a directory that
  # was just deleted.
  local reg now_iso now_ep stale_dir stale_name s_slug store_rc=0
  local -a synced_slugs=()
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  now_ep="$(date -u +%s)"
  if ! _afk_tooling_registry_lock; then
    rm -rf -- "$stage"
    _afk_tooling_sync_fail "REGISTRY_LOCK_TIMEOUT"
    return 1
  fi
  save_rc=0
  reg="$(afk_tooling_load_registry)"
  reg="$(jq -c \
    --arg ts "$now_iso" \
    --arg root "$dest_root/" \
    --argjson synced_items "$synced" \
    --argjson ep "$now_ep" \
    --arg cid "$company_id" \
    --arg src "$central_source" \
    --arg mode "${central_mode:-standalone}" \
    --arg lurl "$central_lurl" \
    --argjson emcp "$central_mcp" \
    --argjson esk "$central_skills" \
    --argjson dsk "$host_desired_slugs" \
    --argjson adsk "$agent_desired_map" \
    --argjson bsrv "$bundle_servers" \
    --argjson sent "$skill_entries" \
    '
    .mcp_servers = ((.mcp_servers // {}) + $bsrv)
    | .skills = ((.skills // {}) + $sent)
    | .skills |= with_entries(
      . as $e
      | select(
          ((($e.value.source // "") != "paperclip") and ((($e.value.path // "") | startswith($root)) | not))
          or any($synced_items[]; .slug == $e.key)
        )
    )
    | .paperclip_central = {
      synced_at: $ts,
      synced_epoch: $ep,
      company_id: $cid,
      source_skill: (if $src == "" then null else $src end),
      mcp_mode: $mode,
      litellm_mcp_url: (if $lurl == "" then null else $lurl end),
      enabled_mcp: $emcp,
      enabled_skills: $esk,
      desired_skills: $dsk,
      agent_desired_skills: $adsk
    }' <<<"$reg")"
  afk_tooling_save_registry "$reg" || save_rc=1
  if (( save_rc != 0 )); then
    _afk_tooling_registry_unlock
    rm -rf -- "$stage"
    printf 'afk-tooling: could not save the registry; sync aborted, the skills store and the registry were not changed\n' >&2
    _afk_tooling_sync_fail "REGISTRY_SAVE_FAILED"
    return 1
  fi
  mapfile -t synced_slugs < <(jq -r '.[].slug' <<<"$synced" 2>/dev/null)
  for s_slug in "${synced_slugs[@]:-}"; do
    [[ -n "$s_slug" && -d "$stage/$s_slug" ]] || continue
    # Never move the new copy while the old one is still in place: mv would
    # put it inside the old directory instead of replacing it.
    if [[ -e "$dest_root/$s_slug" || -L "$dest_root/$s_slug" ]] \
       && ! mv -- "$dest_root/$s_slug" "$stage/.old.$s_slug" 2>/dev/null; then
      store_rc=1
      continue
    fi
    mv -- "$stage/$s_slug" "$dest_root/$s_slug" 2>/dev/null || store_rc=1
  done
  for stale_dir in "$dest_root"/*; do
    [[ -d "$stale_dir" ]] || continue
    stale_name="$(basename -- "$stale_dir")"
    if ! jq -e --arg s "$stale_name" 'any(.[]; .slug == $s)' <<<"$synced" >/dev/null 2>&1; then
      rm -rf "${dest_root:?}/$stale_name" 2>/dev/null || true
    fi
  done
  _afk_tooling_registry_unlock
  rm -rf -- "$stage"
  if (( store_rc != 0 )); then
    printf 'afk-tooling: the registry was saved, but some skills in %s could not be replaced\n' "$dest_root" >&2
    _afk_tooling_sync_fail "SKILLS_STORE_UPDATE_FAILED"
    return 1
  fi

  jq -cn \
    --arg cid "$company_id" \
    --arg root "$dest_root" \
    --arg csrc "$central_source" \
    --argjson skipped "$skipped_bundled" \
    --argjson items "$synced" \
    '{
      schema: "afk-paperclip-skills-sync/1",
      ok: true,
      company_id: $cid,
      skills_dir: $root,
      synced_count: ($items | length),
      skipped_bundled_count: $skipped,
      central_mcp_synced: ($csrc != ""),
      central_source_skill: (if $csrc == "" then null else $csrc end),
      synced_skills: $items
    }'
}

# Where the last automatic sync attempt is recorded: a small file next to the
# registry, so recording a failure never rewrites the registry itself.
_afk_tooling_sync_status_path() {
  printf '%s.sync-status.json\n' "$(afk_tooling_registry_path)"
}

# _afk_tooling_note_job_warning <job_dir> <line>: appends <line> to the job's
# tooling-warnings.log once.
_afk_tooling_note_job_warning() {
  [[ -n "$1" && -d "$1" ]] || return 0
  grep -qxF -- "$2" "$1/tooling-warnings.log" 2>/dev/null || printf '%s\n' "$2" >> "$1/tooling-warnings.log"
}

# afk_tooling_ensure_paperclip_synced [<ttl_sec>] [<job_dir>]
# TTL auto-sync helper: no-op in standalone mode (when Paperclip is not configured)
# or when `.paperclip_central` was synced within <ttl_sec> (default 300s).
# A failed attempt is recorded (last_attempt_epoch, last_error) and not retried
# for AFK_TOOLING_RETRY_SEC (default 300), so a broken Studio does not cost
# every job a full sync. With <job_dir>, the failure is written to that job's
# tooling-warnings.log, because the job then runs on the previous snapshot.
# shellcheck disable=SC2120 # both arguments are optional; the factory passes neither
afk_tooling_ensure_paperclip_synced() {
  local ttl="${1:-${AFK_PAPERCLIP_TOOLING_TTL_SEC:-300}}" job_dir="${2:-}"
  local retry="${AFK_TOOLING_RETRY_SEC:-300}"
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=300
  [[ "$retry" =~ ^[0-9]+$ ]] || retry=300
  [[ -z "${AFK_TOOLING_HERMETIC:-}" ]] || return 0
  declare -F afk_pc_config_path >/dev/null 2>&1 || . "$(dirname -- "${BASH_SOURCE[0]}")/afk-paperclip.sh"
  local pc_cfg_path
  pc_cfg_path="$(afk_pc_config_path)"
  [[ -f "$pc_cfg_path" ]] || return 0

  local reg last_ep now_ep status_file status="{}" last_try last_err
  reg="$(afk_tooling_load_registry)"
  last_ep="$(jq -r '.paperclip_central.synced_epoch // 0' <<<"$reg" 2>/dev/null || printf '0')"
  now_ep="$(date -u +%s)"
  if [[ "$last_ep" =~ ^[0-9]+$ ]] && (( last_ep > 0 && (now_ep - last_ep) < ttl )); then
    return 0
  fi

  status_file="$(_afk_tooling_sync_status_path)"
  if [[ -f "$status_file" ]]; then
    status="$(jq -c 'if type == "object" then . else {} end' "$status_file" 2>/dev/null || printf '{}')"
  fi
  last_try="$(jq -r '.last_attempt_epoch // 0 | tostring' <<<"$status" 2>/dev/null || printf '0')"
  last_err="$(jq -r '.last_error // empty' <<<"$status" 2>/dev/null || true)"
  if [[ -n "$last_err" && "$last_try" =~ ^[0-9]+$ ]] && (( last_try <= now_ep && now_ep - last_try < retry )); then
    _afk_tooling_note_job_warning "$job_dir" "Paperclip tooling sync failed recently ($last_err); this job uses the previous tooling snapshot"
    return 0
  fi

  local out err_code err_text err="" sync_rc=0
  out="$(afk_tooling_sync_paperclip_skills 2>&1)" || sync_rc=$?
  if (( sync_rc != 0 )); then
    err_code="$(printf '%s\n' "$out" | jq -rR 'fromjson? | objects | .error // empty' 2>/dev/null | tail -n 1)"
    err_text="$(printf '%s\n' "$out" | grep -v '^{' | head -n 1)"
    err="${err_code:-SYNC_FAILED}${err_text:+: $err_text}"
    err="${err:0:300}"
    _afk_tooling_note_job_warning "$job_dir" "Paperclip tooling sync failed ($err); this job uses the previous tooling snapshot"
  fi
  mkdir -p "$(dirname -- "$status_file")" 2>/dev/null || true
  _afk_tooling_write_json "$status_file" \
    "$(jq -cn --argjson ep "$now_ep" --arg e "$err" '{last_attempt_epoch: $ep, last_error: (if $e == "" then null else $e end)}')" \
    private || true
  return 0
}

# afk_tooling_sync_project <repo_path> [<mcp_mode>] [<mcp_csv>] [<skills_csv>] [<litellm_url>] [<slug>]
# Provisions per-project MCP servers and centralized skills into <repo_path>:
#   - Inherits Paperclip central config automatically when no CLI/repo override is set,
#     or uses standalone `~/.config/afk/tooling.json` when running without Paperclip.
#   - Never overwrites repo-local BMAD (`bmad-*`) skills.
afk_tooling_sync_project() {
  local repo="$1" cli_mode="${2:-}" mcp_csv="${3:-}" skills_csv="${4:-}" litellm_arg="${5:-}" slug="${6:-}"
  local abs_repo
  abs_repo="$(cd -P -- "$repo" 2>/dev/null && pwd -P)" || {
    printf 'afk_tooling_sync_project: invalid repository path: %s\n' "$repo" >&2
    return 1
  }

  local has_explicit_cli=false
  if [[ -n "$cli_mode" || -n "$mcp_csv" || -n "$skills_csv" || -n "$litellm_arg" ]]; then
    has_explicit_cli=true
  else
    afk_tooling_ensure_paperclip_synced
  fi

  local reg eff cfg_file="$abs_repo/.afk/config.json" cfg="{}"
  # An empty config counts as {}. One that has content but does not parse is
  # the user's to fix: rewriting it below would discard whatever is in it.
  if ! cfg="$(_afk_tooling_project_cfg "$abs_repo")" && grep -q '[^[:space:]]' "$cfg_file" 2>/dev/null; then
    printf 'afk_tooling_sync_project: %s is not a JSON object; fix or remove it (nothing was changed)\n' "$cfg_file" >&2
    return 1
  fi
  eff="$(_afk_tooling_resolve_effective "$abs_repo" "$cli_mode" "$mcp_csv" "$skills_csv" "$litellm_arg" "$slug")"
  reg="$(afk_tooling_load_registry)"
  if ! jq -e 'type == "object"' <<<"$eff" >/dev/null 2>&1; then
    printf 'afk_tooling_sync_project: could not resolve the tooling configuration for %s (nothing was changed)\n' "$abs_repo" >&2
    return 1
  fi

  local config_source mcp_mode litellm_url mcp_arr skills_arr
  config_source="$(jq -r '.config_source' <<<"$eff")"
  [[ "$has_explicit_cli" == "true" ]] && config_source="repo-override"
  mcp_mode="$(jq -r '.mcp_mode' <<<"$eff")"
  litellm_url="$(jq -r '.litellm_mcp_url // empty' <<<"$eff")"
  mcp_arr="$(jq -c '.enabled_mcp // []' <<<"$eff")"
  skills_arr="$(jq -c '.enabled_skills // []' <<<"$eff")"

  # Update .afk/config.json tooling block
  cfg="$(jq \
    --arg src "$config_source" \
    --arg mode "$mcp_mode" \
    --arg lurl "$litellm_url" \
    --argjson em "$mcp_arr" \
    --argjson es "$skills_arr" \
    '.tooling = ((.tooling // {}) + {
      source: $src,
      mcp_mode: $mode,
      litellm_mcp_url: (if $lurl == "" then null else $lurl end),
      enabled_mcp: $em,
      enabled_skills: $es
    })' <<<"$cfg")"

  # Render <repo>/.mcp.json when at least one MCP server is enabled. Both
  # documents are built and checked before either file is written: an existing
  # .mcp.json that does not parse (a `//` comment is enough) makes the render
  # print nothing, and redirecting that into the file used to truncate it.
  local mcp_len synced_mcp="[]" mcp_out=""
  mcp_len="$(jq -r 'length' <<<"$mcp_arr")"
  if (( mcp_len > 0 )); then
    local mcp_doc="{}" rendered
    if [[ -f "$abs_repo/.mcp.json" ]]; then
      mcp_doc="$(cat -- "$abs_repo/.mcp.json" 2>/dev/null || printf '{}')"
    fi
    rendered="$(_afk_tooling_render_mcp_doc "$mcp_doc" "$mcp_mode" "$litellm_url" "$mcp_arr" "$reg" 2>/dev/null || true)"
    if ! jq -e '(.doc | type == "object") and (.synced_mcp | type == "array")' <<<"$rendered" >/dev/null 2>&1; then
      printf 'afk_tooling_sync_project: could not merge MCP servers into %s (is it valid JSON?); the file was left untouched\n' "$abs_repo/.mcp.json" >&2
      return 1
    fi
    mcp_out="$(jq '.doc' <<<"$rendered")"
    synced_mcp="$(jq -c '.synced_mcp' <<<"$rendered")"
  fi

  mkdir -p "$abs_repo/.afk"
  if ! _afk_tooling_write_json "$cfg_file" "$cfg"; then
    printf 'afk_tooling_sync_project: could not write %s\n' "$cfg_file" >&2
    return 1
  fi
  # .mcp.json carries the registry's MCP headers and env, so it stays 0600.
  if [[ -n "$mcp_out" ]] && ! _afk_tooling_write_json "$abs_repo/.mcp.json" "$mcp_out" private; then
    printf 'afk_tooling_sync_project: could not write %s; the file was left untouched\n' "$abs_repo/.mcp.json" >&2
    return 1
  fi

  # Provision enabled central skills into <repo>/.agents/skills/<skill> (preserving repo BMAD skills)
  local synced_skills="[]" s_name s_src
  local -a s_list=()
  mapfile -t s_list < <(jq -r '.[]' <<<"$skills_arr" 2>/dev/null || true)
  for s_name in "${s_list[@]:-}"; do
    [[ -n "$s_name" && "$s_name" != bmad-* ]] || continue
    # Only a directory this function created (it carries the marker) is ever
    # replaced. Anything else there is the user's own skill, whether or not
    # git tracks it, and is left alone.
    if [[ -d "$abs_repo/.agents/skills/$s_name" && ! -f "$abs_repo/.agents/skills/$s_name/.afk-managed-skill" ]]; then
      # Said out loud: a copy an older kit made has no marker either, and it
      # would otherwise go stale with no sign of why.
      printf 'afk_tooling_sync_project: left %s alone: it has no .afk-managed-skill marker, so it is treated as your own skill (delete it to let the kit manage it)\n' "$abs_repo/.agents/skills/$s_name" >&2
      continue
    fi
    s_src="$(jq -r --arg n "$s_name" '.skills[$n].path // empty' <<<"$reg" 2>/dev/null)"
    if [[ -n "$s_src" && -d "$s_src" ]]; then
      mkdir -p "$abs_repo/.agents/skills"
      rm -rf "${abs_repo}/.agents/skills/${s_name}"
      cp -R "$s_src" "${abs_repo}/.agents/skills/${s_name}"
      printf 'managed-by=afk-tooling\n' > "${abs_repo}/.agents/skills/${s_name}/.afk-managed-skill"
      synced_skills="$(jq -c --arg n "$s_name" '. + [$n]' <<<"$synced_skills")"
    fi
  done

  jq -cn \
    --arg repo "$abs_repo" \
    --arg src "$config_source" \
    --arg mode "$mcp_mode" \
    --arg lurl "$litellm_url" \
    --argjson mcp "$synced_mcp" \
    --argjson sk "$synced_skills" \
    '{
      schema: "afk-tooling-sync/1",
      repo_path: $repo,
      config_source: $src,
      mcp_mode: $mode,
      litellm_mcp_url: (if $lurl == "" then null else $lurl end),
      synced_mcp_servers: $mcp,
      synced_skills: $sk
    }'
}

# _afk_tooling_exclude_rewrite <excl_file> <job_id> <eph_file> <add_block:true|false>
# Drops this job's block from the shared `info/exclude` and, when asked,
# appends a fresh one built from <eph_file>. Every worktree of a repo shares
# this one file and several jobs edit it at once, so the whole rewrite runs
# under a lock and lands through a temp file.
#
# A block is only removed whole when its END marker is there. If the END is
# missing (a job died mid-write, someone edited the file) the lines after the
# BEGIN may be the user's own: skipping stops at the next marker of any job
# or at end of file, and only lines this job is known to have written (the
# paths in <eph_file>) are dropped.
_afk_tooling_exclude_rewrite() {
  local excl_file="$1" job_id="$2" eph_file="$3" add_block="${4:-false}"
  local lock="${excl_file}.afk-lock" tmp rel_p rc=0
  _afk_tooling_lock "$lock" || return 1
  if [[ "$add_block" != "true" ]] && ! grep -qF "AFK-EPHEMERAL:$job_id" "$excl_file" 2>/dev/null; then
    _afk_tooling_unlock "$lock"
    return 0
  fi
  if ! tmp="$(mktemp "${excl_file}.XXXXXX" 2>/dev/null)"; then
    _afk_tooling_unlock "$lock"
    return 1
  fi
  if [[ -f "$excl_file" ]]; then
    AFK_EXCL_BEGIN="# BEGIN AFK-EPHEMERAL:$job_id" AFK_EXCL_END="# END AFK-EPHEMERAL:$job_id" AFK_EXCL_EPH="$eph_file" awk '
      BEGIN {
        b = ENVIRON["AFK_EXCL_BEGIN"]; e = ENVIRON["AFK_EXCL_END"]; f = ENVIRON["AFK_EXCL_EPH"]
        if (f != "") { while ((getline line < f) > 0) { if (line != "") own["/" line] = 1 } }
      }
      function keep_foreign(   i) {
        for (i = 1; i <= n; i++) { if (!(buf[i] in own)) print buf[i] }
        n = 0
      }
      skip && $0 == e { skip = 0; n = 0; next }
      skip && /^# (BEGIN|END) AFK-EPHEMERAL:/ { keep_foreign(); skip = 0 }
      $0 == b { skip = 1; n = 0; next }
      $0 == e { next }
      skip { buf[++n] = $0; next }
      { print }
      END { if (skip) keep_foreign() }
    ' "$excl_file" > "$tmp" || rc=1
  fi
  if (( rc == 0 )) && [[ "$add_block" == "true" ]]; then
    {
      printf '# BEGIN AFK-EPHEMERAL:%s\n' "$job_id"
      while IFS= read -r rel_p; do
        [[ -n "$rel_p" ]] && printf '/%s\n' "$rel_p"
      done < "$eph_file"
      printf '# END AFK-EPHEMERAL:%s\n' "$job_id"
    } >> "$tmp" || rc=1
  fi
  if (( rc == 0 )); then
    # mktemp made the file 0600; give it the mode a plain redirect would.
    chmod "$(_afk_tooling_default_mode)" "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$excl_file" || rc=1
  fi
  (( rc == 0 )) || rm -f -- "$tmp"
  _afk_tooling_unlock "$lock"
  return "$rc"
}

# afk_tooling_prepare_worktree <repo_path> <wt_dir> <job_dir> [<slug>]
# Auto-bridges Paperclip central MCPs + desiredSkills (or standalone tooling) into an
# ephemeral Factory job worktree while excluding all newly created files from Git so
# zero `.mcp.json`, `opencode.json`, or `.agents/skills/` diff pollution ever lands on `main`.
afk_tooling_prepare_worktree() {
  local repo="$1" wt_dir="$2" job_dir="$3" slug="${4:-}"
  [[ -d "$wt_dir" && -d "$job_dir" ]] || return 0

  afk_tooling_ensure_paperclip_synced "" "$job_dir"

  local abs_repo eff reg mcp_mode litellm_url mcp_arr skills_arr warn_line
  abs_repo="$(cd -P -- "$repo" 2>/dev/null && pwd -P)" || abs_repo="$repo"
  # The job still gets its central tooling when the project config is empty
  # or broken, but the operator has to be able to see that it was ignored.
  if ! _afk_tooling_project_cfg "$abs_repo" >/dev/null; then
    warn_line="ignored $abs_repo/.afk/config.json: it is not a JSON object, so its tooling overrides do not apply"
    grep -qxF "$warn_line" "$job_dir/tooling-warnings.log" 2>/dev/null \
      || printf '%s\n' "$warn_line" >> "$job_dir/tooling-warnings.log"
  fi
  eff="$(_afk_tooling_resolve_effective "$abs_repo" "" "" "" "" "$slug" 2>/dev/null)"
  reg="$(afk_tooling_load_registry)"
  if ! jq -e 'type == "object"' <<<"$eff" >/dev/null 2>&1; then
    printf 'could not resolve the tooling configuration; no MCP servers or skills were provided to this job\n' >> "$job_dir/tooling-warnings.log"
    return 0
  fi
  mcp_mode="$(jq -r '.mcp_mode' <<<"$eff")"
  litellm_url="$(jq -r '.litellm_mcp_url // empty' <<<"$eff")"
  mcp_arr="$(jq -c '.enabled_mcp // []' <<<"$eff")"
  skills_arr="$(jq -c '.enabled_skills // []' <<<"$eff")"

  local eph_file="$job_dir/.ephemeral-tooling-paths"
  touch "$eph_file"

  local mcp_len
  mcp_len="$(jq -r 'length' <<<"$mcp_arr")"
  if (( mcp_len > 0 )); then
    # Materialize .mcp.json (Claude, Antigravity, Grok, Codex) ONLY if not already tracked/present in repo
    local mcp_tracked=false
    if [[ -d "$wt_dir/.git" || -f "$wt_dir/.git" ]] && git -C "$wt_dir" ls-files --error-unmatch ".mcp.json" >/dev/null 2>&1; then
      mcp_tracked=true
    fi
    if [[ "$mcp_tracked" == "false" ]] && { [[ ! -f "$wt_dir/.mcp.json" ]] || grep -qxF ".mcp.json" "$eph_file" 2>/dev/null; }; then
      local rendered mcp_doc_str
      rendered="$(_afk_tooling_render_mcp_doc "{}" "$mcp_mode" "$litellm_url" "$mcp_arr" "$reg")"
      if (( $(jq -r '.synced_mcp | length' <<<"$rendered") > 0 )); then
        mcp_doc_str="$(jq '.doc' <<<"$rendered")"
        # In live CLI harness runs, drop unreachable HTTP/SSE MCP endpoints so offline gateways never break CLI harness startup
        if [[ "${AFK_FACTORY_LIVE_HARNESS:-0}" == "1" && -z "${AFK_FACTORY_AGENT_RUNNER:-}" && "${AFK_CURL_BIN:-curl}" == "curl" ]]; then
          local -a http_pairs=()
          mapfile -t http_pairs < <(jq -r '(.mcpServers // {}) | to_entries[] | select((.value.url // "") != "") | "\(.key)|\(.value.url)"' <<<"$mcp_doc_str" 2>/dev/null || true)
          local hp s_key s_url
          for hp in "${http_pairs[@]:-}"; do
            [[ -n "$hp" ]] || continue
            s_key="${hp%%|*}"
            s_url="${hp#*|}"
            if ! curl -sS -o /dev/null --connect-timeout 2 --max-time 3 "$s_url" >/dev/null 2>&1; then
              mcp_doc_str="$(jq --arg k "$s_key" 'del(.mcpServers[$k])' <<<"$mcp_doc_str")"
              printf 'skipped unreachable HTTP MCP server %s (%s)\n' "$s_key" "$(_afk_tooling_url_origin "$s_url")" >> "$job_dir/tooling-warnings.log"
            fi
          done
        fi
        # Both files can carry MCP headers and env from Studio (bearer
        # tokens), so they are written 0600 whatever the umask is.
        if (( $(jq -r '(.mcpServers // {}) | length' <<<"$mcp_doc_str") > 0 )) \
           && _afk_tooling_write_json "$wt_dir/.mcp.json" "$mcp_doc_str" private "$job_dir"; then
          grep -qxF ".mcp.json" "$eph_file" 2>/dev/null || printf '.mcp.json\n' >> "$eph_file"

          # Also materialize opencode.json for OpenCode harness if not already present/tracked
          local oc_tracked=false
          if [[ -d "$wt_dir/.git" || -f "$wt_dir/.git" ]] && git -C "$wt_dir" ls-files --error-unmatch "opencode.json" >/dev/null 2>&1; then
            oc_tracked=true
          fi
          if [[ "$oc_tracked" == "false" ]] && { [[ ! -f "$wt_dir/opencode.json" ]] || grep -qxF "opencode.json" "$eph_file" 2>/dev/null; }; then
            if _afk_tooling_write_json "$wt_dir/opencode.json" "$(_afk_tooling_render_opencode_doc "{}" "$mcp_doc_str")" private "$job_dir"; then
              grep -qxF "opencode.json" "$eph_file" 2>/dev/null || printf 'opencode.json\n' >> "$eph_file"
            fi
          fi
        fi
      fi
    fi
  fi

  # Materialize enabled skills into <wt_dir>/.agents/skills/<skill> without touching repo-committed/BMAD skills
  local s_name s_src rel_s
  local -a s_list=()
  mapfile -t s_list < <(jq -r '.[]' <<<"$skills_arr" 2>/dev/null || true)
  for s_name in "${s_list[@]:-}"; do
    [[ -n "$s_name" && "$s_name" != bmad-* ]] || continue
    rel_s=".agents/skills/$s_name"
    if [[ -d "$wt_dir/$rel_s" ]] && ! grep -qxF "$rel_s" "$eph_file" 2>/dev/null; then
      continue
    fi
    s_src="$(jq -r --arg n "$s_name" '.skills[$n].path // empty' <<<"$reg" 2>/dev/null)"
    if [[ -n "$s_src" && -d "$s_src" ]]; then
      mkdir -p "$wt_dir/.agents/skills"
      rm -rf "${wt_dir:?}/$rel_s"
      cp -R "$s_src" "$wt_dir/$rel_s"
      grep -qxF "$rel_s" "$eph_file" 2>/dev/null || printf '%s\n' "$rel_s" >> "$eph_file"
    fi
  done

  # Register job-scoped git info/exclude block so `git status` and `git add .` ignore ephemeral paths
  if [[ -s "$eph_file" ]] && { [[ -d "$wt_dir/.git" ]] || [[ -f "$wt_dir/.git" ]]; }; then
    local common_git excl_file job_id
    job_id="$(basename -- "$job_dir")"
    common_git="$(git -C "$wt_dir" rev-parse --git-common-dir 2>/dev/null || true)"
    [[ -n "$common_git" && "$common_git" != /* ]] && common_git="$wt_dir/$common_git"
    if [[ -n "$common_git" ]]; then
      mkdir -p "$common_git/info"
      excl_file="$common_git/info/exclude"
      _afk_tooling_exclude_rewrite "$excl_file" "$job_id" "$eph_file" true \
        || printf 'could not update %s; the materialized tooling files may show up as untracked\n' "$excl_file" >> "$job_dir/tooling-warnings.log"
    fi
  fi
  return 0
}

# afk_tooling_unstage_ephemeral <wt_dir> <job_dir>
# Defensive guard executed right before/after build commit: ensures no ephemeral
# `.mcp.json`, `opencode.json`, or `.agents/skills/*` is ever staged in the index.
afk_tooling_unstage_ephemeral() {
  local wt_dir="$1" job_dir="$2"
  local eph_file="$job_dir/.ephemeral-tooling-paths"
  [[ -s "$eph_file" ]] || return 0
  [[ -d "$wt_dir/.git" || -f "$wt_dir/.git" ]] || return 0
  local rel_p
  while IFS= read -r rel_p; do
    [[ -n "$rel_p" ]] || continue
    git -C "$wt_dir" rm -rf --cached --ignore-unmatch -- "$rel_p" >/dev/null 2>&1 || true
  done < "$eph_file"
  return 0
}

# afk_tooling_cleanup_worktree <repo_path> <wt_dir> <job_dir>
# Removes the untracked ephemeral files this job materialized in <wt_dir>, then the
# job-scoped `# BEGIN AFK-EPHEMERAL:<job_id>` block from git `info/exclude`.
afk_tooling_cleanup_worktree() {
  local repo="$1" wt_dir="$2" job_dir="$3"
  local eph_file="$job_dir/.ephemeral-tooling-paths"
  local job_id
  job_id="$(basename -- "$job_dir")"

  # The files go first, in every worktree and not only when the job ran in
  # the base checkout: once the ignore block is gone a leftover .mcp.json is
  # an ordinary untracked file and the next `git add -A` there stages it.
  local clean_rc=0
  if [[ -s "$eph_file" && -d "$wt_dir" ]]; then
    local rel_p
    while IFS= read -r rel_p; do
      [[ -n "$rel_p" ]] || continue
      # The list is written by prepare_worktree, but it is read back from
      # disk and fed to rm -rf. Only the names prepare_worktree writes are
      # accepted, nothing is removed through a symlink, and nothing git
      # tracks is removed.
      if ! _afk_tooling_ephemeral_path_ok "$wt_dir" "$rel_p"; then
        printf 'afk-tooling: not removing %s listed in %s: it is not a path this kit materializes\n' "$rel_p" "$eph_file" >&2
        continue
      fi
      if git -C "$wt_dir" ls-files --error-unmatch -- "$rel_p" >/dev/null 2>&1; then
        continue
      fi
      rm -rf "${wt_dir:?}/$rel_p" || clean_rc=1
    done < "$eph_file"
  fi

  if [[ -d "$repo/.git" || -f "$repo/.git" ]]; then
    local common_git excl_file
    common_git="$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null || true)"
    [[ -n "$common_git" && "$common_git" != /* ]] && common_git="$repo/$common_git"
    excl_file="$common_git/info/exclude"
    if [[ -n "$common_git" && -f "$excl_file" ]]; then
      _afk_tooling_exclude_rewrite "$excl_file" "$job_id" "$eph_file" false || clean_rc=1
    fi
  fi
  # The list has been acted on; a second cleanup must not act on it again.
  # It is kept when something failed, because a retry needs it, and the
  # exclude rewrite above uses it to recognise this job's lines.
  if (( clean_rc == 0 )) && [[ -s "$eph_file" ]]; then
    : > "$eph_file" 2>/dev/null || true
  fi
  return 0
}

# _afk_tooling_ephemeral_path_ok <wt_dir> <rel_path>
# True for the paths prepare_worktree materializes (.mcp.json, opencode.json,
# .agents/skills/<name>) when no part of the path inside <wt_dir> is a
# symlink.
_afk_tooling_ephemeral_path_ok() {
  local wt="$1" rel="$2" seg
  case "$rel" in
    .mcp.json|opencode.json)
      [[ ! -L "$wt/$rel" ]] ;;
    .agents/skills/*)
      seg="${rel#.agents/skills/}"
      [[ -n "$seg" && "$seg" != */* && "$seg" != "." && "$seg" != ".." ]] || return 1
      [[ ! -L "$wt/.agents" && ! -L "$wt/.agents/skills" && ! -L "$wt/$rel" ]] ;;
    *)
      return 1 ;;
  esac
}

# afk_tooling_publish_paperclip [<mcp_mode>] [<litellm_url>] [<mcp_csv>] [<skills_csv>] [<skill_slug>] [<force:true|false>]
# Publishes or updates the editable `afk-fleet-tooling` Studio bundle (`SKILL.md` + `mcp.json`)
# directly inside Paperclip's **Skills -> My Skills** Studio, attaches it to the AFK host agent,
# and synchronizes the local AFK registry immediately.
# Refuses to publish when there is nothing to publish, unless <force> is true or
# AFK_TOOLING_PUBLISH_FORCE=1.
afk_tooling_publish_paperclip() {
  local cli_mode="${1:-}" cli_lurl="${2:-}" cli_mcp="${3:-}" cli_skills="${4:-}" skill_slug="${5:-afk-fleet-tooling}"
  local force="${6:-${AFK_TOOLING_PUBLISH_FORCE:-}}"
  declare -F afk_pc_curl >/dev/null 2>&1 || . "$(dirname -- "${BASH_SOURCE[0]}")/afk-paperclip.sh"

  local pc_cfg_path pc_cfg="" api_url="" company_id="" host_agent_id="" key="" key_ref=""
  pc_cfg_path="$(afk_pc_config_path)"
  if [[ -f "$pc_cfg_path" ]]; then
    pc_cfg="$(cat -- "$pc_cfg_path" 2>/dev/null || true)"
    api_url="$(jq -r '.api_url // empty' <<<"$pc_cfg" 2>/dev/null)"
    company_id="$(jq -r '.company_id // empty' <<<"$pc_cfg" 2>/dev/null)"
    host_agent_id="$(jq -r '.host.agent_id // empty' <<<"$pc_cfg" 2>/dev/null)"
    key_ref="$(jq -r '.host.key_ref // empty' <<<"$pc_cfg" 2>/dev/null)"
    if [[ -n "$key_ref" ]]; then
      # shellcheck disable=SC2034 # read by afk_pc_read_key (lib/afk-paperclip.sh)
      AFK_PC_CFG="$pc_cfg"
      key="$(afk_pc_read_key "$key_ref" 2>/dev/null || true)"
    fi
  fi

  if [[ -z "$api_url" || -z "$company_id" || -z "$key" ]]; then
    jq -cn '{schema:"afk-paperclip-tooling-publish/1", ok:false, error:"PAPERCLIP_NOT_CONFIGURED"}'
    return 1
  fi

  local reg eff mcp_mode litellm_url mcp_arr skills_arr mcp_servers_doc
  reg="$(afk_tooling_load_registry)"
  eff="$(_afk_tooling_resolve_effective "" "$cli_mode" "$cli_mcp" "$cli_skills" "$cli_lurl" "")"
  if ! jq -e 'type == "object"' <<<"$eff" >/dev/null 2>&1; then
    printf 'afk_tooling_publish_paperclip: could not resolve the local tooling configuration; nothing was published\n' >&2
    jq -cn '{schema:"afk-paperclip-tooling-publish/1", ok:false, error:"LOCAL_CONFIG_UNRESOLVED"}'
    return 1
  fi
  mcp_mode="$(jq -r '.mcp_mode' <<<"$eff")"
  litellm_url="$(jq -r '.litellm_mcp_url // empty' <<<"$eff")"
  mcp_arr="$(jq -c '.enabled_mcp // []' <<<"$eff")"
  skills_arr="$(jq -c '.enabled_skills // []' <<<"$eff")"
  mcp_servers_doc="$(jq -c '
    [ (.mcp_servers // {}) | to_entries[] | select((.value.source // "") == "paperclip" or (.value.source // "") == "local") | {
        key: .key,
        value: (
          if .value.transport == "stdio" then
            ({command: .value.command, args: (.value.args // [])}
             + (if (.value.env // null) != null then {env: .value.env} else {} end))
          else
            ({type: .value.transport, url: .value.url}
             + (if (.value.headers // null) != null then {headers: .value.headers} else {} end))
          end
        )
      } ] | from_entries
  ' <<<"$reg")"

  # Publishing replaces the Studio mcp.json that every host syncs from; it is
  # not merged with what is there. A host that has never synced or registered
  # anything would replace the fleet's configuration with an empty one, so
  # that takes an explicit force.
  if [[ "$force" != "1" && "$force" != "true" ]] \
     && ! jq -en --argjson m "$mcp_arr" --argjson s "$skills_arr" --argjson d "$mcp_servers_doc" \
          '(($m | length) + ($s | length) + ($d | length)) > 0' >/dev/null 2>&1; then
    printf 'afk_tooling_publish_paperclip: the local registry has nothing to publish (no enabled MCP servers, no server definitions, no skills), and publishing would overwrite the Studio mcp.json with an empty one. Sync first (afk factory tooling --sync-paperclip-skills), or set AFK_TOOLING_PUBLISH_FORCE=1 to publish the empty configuration anyway.\n' >&2
    jq -cn '{schema:"afk-paperclip-tooling-publish/1", ok:false, error:"EMPTY_LOCAL_REGISTRY"}'
    return 1
  fi

  local mcp_json_pretty skill_md
  mcp_json_pretty="$(jq -n \
    --arg mode "$mcp_mode" \
    --arg lurl "$litellm_url" \
    --argjson emcp "$mcp_arr" \
    --argjson esk "$skills_arr" \
    --argjson srvs "$mcp_servers_doc" \
    '{
      schema: "afk-paperclip-fleet-tooling/1",
      mcp_mode: $mode,
      litellm_mcp_url: (if $lurl == "" then null else $lurl end),
      enabled_mcp: $emcp,
      enabled_skills: $esk,
      mcpServers: $srvs
    }')"

  skill_md="$(cat <<EOF
---
name: ${skill_slug}
description: Central MCP Gateway (LiteLLM / custom MCP servers) and shared skill configuration synced automatically to AFK harnesses
---

# AFK Fleet Tooling & Central MCP Gateway

This Studio bundle is your **single central configuration** in Paperclip for all local AFK harnesses (\`claude\`, \`agy\`, \`grok\`, \`codex\`, \`opencode\`, \`pi\`).

## How to Configure Once in Paperclip UI

Open **\`mcp.json\`** in the left file list of this Studio view and edit:

1. **LiteLLM MCP Gateway Mode (Recommended):**
   - Set \`"mcp_mode": "litellm"\`
   - Set \`"litellm_mcp_url": "http://gateway.example.com:4000"\` (your LiteLLM base URL)
   - List active MCP toolsets in \`"enabled_mcp": ["postgres-ro", "github"]\`
2. **Custom / Pasted MCP Servers:**
   - Or paste any standard \`"mcpServers": { ... }\` JSON block directly into \`mcp.json\` (use environment variable placeholders like \`"\${LITELLM_MCP_API_KEY}"\` for headers/tokens rather than raw secrets).
3. **Shared Fleet Skills:**
   - Either add skill slugs to \`"enabled_skills"\` in \`mcp.json\`, **or** attach any skill from **Skills -> Discover / My Skills** directly to **\`AFK - ubuntu-dev\`** (fleet-wide) or to a project agent (e.g. \`spektacle-dev\`).

## Precedence & Standalone Fallback

- **Repo Override (\`.afk/config.json\`)** $\\rightarrow$ **Paperclip Central (\`${skill_slug}\`)** $\\rightarrow$ **Standalone Host (\`~/.config/afk/tooling.json\`)**.
- AFK refreshes this bundle automatically during \`afk factory poll\` and \`afk factory run\` without polluting project Git commits.
EOF
)"

  # Check if skill already exists in Paperclip Company Skills
  local list_resp list_code list_body sid="" created=false
  list_resp="$(afk_pc_curl GET "$api_url/api/companies/$company_id/skills" "$key" "")"
  list_code="${list_resp%%$'\n'*}"
  list_body="${list_resp#*$'\n'}"
  if [[ "$list_code" == 2?? ]] && jq -e 'type == "array"' <<<"$list_body" >/dev/null 2>&1; then
    sid="$(jq -r --arg s "$skill_slug" '[ .[] | select(.slug == $s) ][0].id // empty' <<<"$list_body")"
  fi

  if [[ -z "$sid" ]]; then
    local create_payload c_resp c_code c_body
    create_payload="$(jq -cn \
      --arg n "AFK Fleet Tooling & MCP Gateway" \
      --arg s "$skill_slug" \
      --arg d "Central MCP Gateway (LiteLLM / custom MCP servers) and shared skill configuration synced automatically to AFK harnesses" \
      --arg md "$skill_md" \
      '{name: $n, slug: $s, description: $d, markdown: $md}')"
    c_resp="$(afk_pc_curl POST "$api_url/api/companies/$company_id/skills" "$key" "" "$create_payload")"
    c_code="${c_resp%%$'\n'*}"
    c_body="${c_resp#*$'\n'}"
    if [[ "$c_code" != 2?? ]]; then
      jq -cn --arg c "$c_code" '{schema:"afk-paperclip-tooling-publish/1", ok:false, error:("CREATE_SKILL_HTTP_" + $c)}'
      return 1
    fi
    sid="$(jq -r '.id // empty' <<<"$c_body")"
    created=true
  else
    local md_payload
    md_payload="$(jq -cn --arg c "$skill_md" '{path: "SKILL.md", content: $c}')"
    afk_pc_curl PATCH "$api_url/api/companies/$company_id/skills/$sid/files" "$key" "" "$md_payload" >/dev/null 2>&1 || true
  fi

  local mcp_payload p_resp p_code
  mcp_payload="$(jq -cn --arg c "$mcp_json_pretty" '{path: "mcp.json", content: $c}')"
  p_resp="$(afk_pc_curl PATCH "$api_url/api/companies/$company_id/skills/$sid/files" "$key" "" "$mcp_payload")"
  p_code="${p_resp%%$'\n'*}"
  if [[ "$p_code" != 2?? ]]; then
    jq -cn --arg c "$p_code" --arg id "$sid" '{schema:"afk-paperclip-tooling-publish/1", ok:false, skill_id:$id, error:("PATCH_MCP_JSON_HTTP_" + $c)}'
    return 1
  fi

  local attached=false
  if [[ -n "$host_agent_id" ]]; then
    local attach_payload a_resp a_code
    attach_payload="$(jq -cn --arg s "$skill_slug" '{mode: "add", desiredSkills: [$s]}')"
    a_resp="$(afk_pc_curl POST "$api_url/api/agents/$host_agent_id/skills/sync" "$key" "" "$attach_payload")"
    a_code="${a_resp%%$'\n'*}"
    [[ "$a_code" == 2?? ]] && attached=true
  fi

  afk_tooling_sync_paperclip_skills "$api_url" "$key" "$company_id" "$host_agent_id" >/dev/null 2>&1 || true

  jq -cn \
    --arg cid "$company_id" \
    --arg id "$sid" \
    --arg s "$skill_slug" \
    --arg aid "$host_agent_id" \
    --arg mode "$mcp_mode" \
    --arg lurl "$litellm_url" \
    --argjson cr "$created" \
    --argjson att "$attached" \
    --argjson emcp "$mcp_arr" \
    --argjson esk "$skills_arr" \
    '{
      schema: "afk-paperclip-tooling-publish/1",
      ok: true,
      company_id: $cid,
      skill_id: $id,
      skill_slug: $s,
      created: $cr,
      attached_to_host_agent: $att,
      host_agent_id: (if $aid == "" then null else $aid end),
      mcp_mode: $mode,
      litellm_mcp_url: (if $lurl == "" then null else $lurl end),
      enabled_mcp: $emcp,
      enabled_skills: $esk
    }'
}
