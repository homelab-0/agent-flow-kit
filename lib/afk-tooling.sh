#!/usr/bin/env bash
# afk-tooling.sh — Centralized & Per-Project Skills and MCP Tooling Manager.
#
# Supports two first-class operating modes for MCP & Skills:
#   1. `litellm` (Gateway Mode): Centralizes MCP servers behind a LiteLLM MCP
#      gateway (`<litellm_base_url>/mcp`), allowing each project to enable only
#      the MCP toolsets it needs without spawning duplicate stdio daemons or
#      scattering credentials across harnesses.
#   2. `standalone` (Per-Project Native Mode): For users without LiteLLM, AFK
#      maintains a central catalog (`~/.config/afk/tooling.json` & central
#      skills directory) and materializes per-project `.mcp.json` + `.agents/skills/`
#      so every harness (`claude`, `agy`, `codex`, `opencode`, `pi`) sees the
#      exact skills and MCP servers configured for that repository.

if [[ -n "${AFK_TOOLING_SOURCED:-}" ]]; then
  return 0
fi
AFK_TOOLING_SOURCED=1

afk_tooling_registry_path() {
  if [[ -n "${AFK_TOOLING_REGISTRY_FILE:-}" ]]; then
    printf '%s\n' "$AFK_TOOLING_REGISTRY_FILE"
    return 0
  fi
  printf '%s\n' "${HOME:-/tmp}/.config/afk/tooling.json"
}

afk_tooling_load_registry() {
  local reg_file
  reg_file="$(afk_tooling_registry_path)"
  if [[ -f "$reg_file" ]]; then
    cat -- "$reg_file"
  else
    jq -cn '{
      schema: "afk-tooling-registry/1",
      default_mcp_mode: "standalone",
      litellm_mcp_url: null,
      mcp_servers: {},
      skills: {}
    }'
  fi
}

afk_tooling_save_registry() {
  local content="$1"
  local reg_file
  reg_file="$(afk_tooling_registry_path)"
  mkdir -p "$(dirname -- "$reg_file")"
  printf '%s\n' "$content" > "${reg_file}.tmp.$$" && mv "${reg_file}.tmp.$$" "$reg_file"
}

# afk_tooling_register_mcp <name> <transport:stdio|http|sse> <target_cmd_or_url> [<args_csv>] [<description>]
afk_tooling_register_mcp() {
  local name="$1" transport="${2:-stdio}" target="$3" args_csv="${4:-}" desc="${5:-}"
  local reg args_json="[]"
  reg="$(afk_tooling_load_registry)"
  if [[ -n "$args_csv" ]]; then
    args_json="$(printf '%s' "$args_csv" | jq -Rc 'split(",") | map(select(length > 0))')"
  fi
  reg="$(jq -c \
    --arg n "$name" \
    --arg tr "$transport" \
    --arg tg "$target" \
    --arg d "$desc" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson ar "$args_json" \
    '.mcp_servers[$n] = (
      if $tr == "stdio" then
        {name: $n, transport: "stdio", command: $tg, args: $ar, description: $d, updated_at: $ts}
      else
        {name: $n, transport: $tr, url: $tg, description: $d, updated_at: $ts}
      end
    )' <<<"$reg")"
  afk_tooling_save_registry "$reg"
  jq -c --arg n "$name" '.mcp_servers[$n]' <<<"$reg"
}

# afk_tooling_register_skill <name> <source_dir> [<description>]
afk_tooling_register_skill() {
  local name="$1" src_dir="$2" desc="${3:-}"
  local abs_src
  abs_src="$(cd -P -- "$src_dir" 2>/dev/null && pwd -P)" || {
    printf 'afk_tooling_register_skill: invalid skill directory: %s\n' "$src_dir" >&2
    return 1
  }
  if [[ -z "$desc" && -f "$abs_src/SKILL.md" ]]; then
    desc="$(sed -n 's/^description:[[:space:]]*//p' "$abs_src/SKILL.md" 2>/dev/null | head -n 1 | tr -d '"' || true)"
  fi
  local reg
  reg="$(afk_tooling_load_registry)"
  reg="$(jq -c \
    --arg n "$name" \
    --arg p "$abs_src" \
    --arg d "$desc" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.skills[$n] = {name: $n, path: $p, description: $d, updated_at: $ts}' <<<"$reg")"
  afk_tooling_save_registry "$reg"
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

# afk_tooling_discover [<repo_path>]
# Discovers all project-level and centralized/host-level Skills and MCP servers,
# plus the active MCP architecture mode (`litellm` vs `standalone`).
afk_tooling_discover() {
  local repo="${1:-}" abs_repo=""
  if [[ -n "$repo" && -d "$repo" ]]; then
    abs_repo="$(cd -P -- "$repo" 2>/dev/null && pwd -P)" || abs_repo=""
  fi

  local reg proj_cfg="{}"
  reg="$(afk_tooling_load_registry)"
  if [[ -n "$abs_repo" && -f "$abs_repo/.afk/config.json" ]]; then
    proj_cfg="$(cat -- "$abs_repo/.afk/config.json" 2>/dev/null || printf '{}')"
  fi

  local litellm_url mcp_mode
  litellm_url="${AFK_LITELLM_BASE_URL:-$(jq -r '.tooling.litellm_mcp_url // .router.litellm_base_url // empty' <<<"$proj_cfg" 2>/dev/null)}"
  [[ -n "$litellm_url" ]] || litellm_url="$(jq -r '.litellm_mcp_url // empty' <<<"$reg" 2>/dev/null)"
  mcp_mode="$(jq -r '.tooling.mcp_mode // empty' <<<"$proj_cfg" 2>/dev/null)"
  if [[ -z "$mcp_mode" ]]; then
    if [[ -n "$litellm_url" ]]; then
      mcp_mode="litellm"
    else
      mcp_mode="$(jq -r '.default_mcp_mode // "standalone"' <<<"$reg" 2>/dev/null)"
    fi
  fi

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
    local hs1 hs2
    hs1="$(_afk_tooling_scan_skills_dir "$HOME/.agents/skills" "host-global")"
    hs2="$(_afk_tooling_scan_skills_dir "$HOME/.config/afk/skills" "afk-central")"
    host_skills="$(jq -cs '.[0] + .[1] | unique_by(.name)' <(printf '%s' "$hs1") <(printf '%s' "$hs2"))"
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
    --arg mode "$mcp_mode" \
    --arg lurl "$litellm_url" \
    --argjson pskills "$proj_skills" \
    --argjson hskills "$host_skills" \
    --argjson pmcp "$proj_mcp" \
    --argjson hmcp "$host_mcp" \
    --argjson reg "$reg" \
    '{
      schema: "afk-tooling-inventory/1",
      repo_path: (if $repo == "" then null else $repo end),
      mcp_mode: $mode,
      litellm_mcp_url: (if $lurl == "" then null else $lurl end),
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

# afk_tooling_sync_project <repo_path> <mcp_mode:litellm|standalone> <mcp_csv> <skills_csv> [<litellm_url>]
# Provisions per-project MCP servers and centralized skills into <repo_path>:
#   - When mcp_mode=="litellm": writes `.mcp.json` pointing enabled MCP toolsets
#     to LiteLLM's centralized MCP gateway (`<litellm_url>/mcp/<server>` or `/mcp`).
#   - When mcp_mode=="standalone": materializes native stdio/http definitions from
#     AFK's central registry (`~/.config/afk/tooling.json`) into `<repo>/.mcp.json`
#     so Claude, Antigravity, OpenCode, and Codex work without LiteLLM.
#   - Symlinks/installs enabled centralized skills into `<repo>/.agents/skills/<name>`.
afk_tooling_sync_project() {
  local repo="$1" mcp_mode="${2:-standalone}" mcp_csv="${3:-}" skills_csv="${4:-}" litellm_arg="${5:-}"
  local abs_repo
  abs_repo="$(cd -P -- "$repo" 2>/dev/null && pwd -P)" || {
    printf 'afk_tooling_sync_project: invalid repository path: %s\n' "$repo" >&2
    return 1
  }

  local reg cfg_file="$abs_repo/.afk/config.json" cfg="{}"
  reg="$(afk_tooling_load_registry)"
  mkdir -p "$abs_repo/.afk"
  [[ -f "$cfg_file" ]] && cfg="$(cat -- "$cfg_file" 2>/dev/null || printf '{}')"

  local litellm_url="$litellm_arg"
  [[ -n "$litellm_url" ]] || litellm_url="${AFK_LITELLM_BASE_URL:-$(jq -r '.tooling.litellm_mcp_url // .router.litellm_base_url // empty' <<<"$cfg" 2>/dev/null)}"
  [[ -n "$litellm_url" ]] || litellm_url="$(jq -r '.litellm_mcp_url // empty' <<<"$reg" 2>/dev/null)"

  local mcp_arr="[]" skills_arr="[]"
  if [[ -n "$mcp_csv" ]]; then
    mcp_arr="$(printf '%s' "$mcp_csv" | jq -Rc 'split(",") | map(select(length > 0))')"
  else
    mcp_arr="$(jq -c '.tooling.enabled_mcp // []' <<<"$cfg" 2>/dev/null || printf '[]')"
  fi
  if [[ -n "$skills_csv" ]]; then
    skills_arr="$(printf '%s' "$skills_csv" | jq -Rc 'split(",") | map(select(length > 0))')"
  else
    skills_arr="$(jq -c '.tooling.enabled_skills // []' <<<"$cfg" 2>/dev/null || printf '[]')"
  fi

  # Update .afk/config.json tooling block
  cfg="$(jq \
    --arg mode "$mcp_mode" \
    --arg lurl "$litellm_url" \
    --argjson em "$mcp_arr" \
    --argjson es "$skills_arr" \
    '.tooling = ((.tooling // {}) + {
      mcp_mode: $mode,
      litellm_mcp_url: (if $lurl == "" then null else $lurl end),
      enabled_mcp: $em,
      enabled_skills: $es
    })' <<<"$cfg")"
  printf '%s\n' "$cfg" > "${cfg_file}.tmp.$$" && mv "${cfg_file}.tmp.$$" "$cfg_file"

  # Render <repo>/.mcp.json when at least one MCP server is enabled
  local mcp_len synced_mcp="[]"
  mcp_len="$(jq -r 'length' <<<"$mcp_arr")"
  if (( mcp_len > 0 )); then
    local mcp_doc="{}"
    if [[ -f "$abs_repo/.mcp.json" ]]; then
      mcp_doc="$(cat -- "$abs_repo/.mcp.json" 2>/dev/null || printf '{}')"
    fi
    if [[ "$mcp_mode" == "litellm" ]]; then
      local base_gw="${litellm_url%/}"
      [[ -n "$base_gw" ]] || base_gw="http://localhost:4000"
      mcp_doc="$(jq \
        --arg gw "$base_gw" \
        --argjson names "$mcp_arr" \
        '.mcpServers = ((.mcpServers // {}) + (
          $names | map({
            key: .,
            value: {
              type: "http",
              url: ($gw + "/mcp/" + .),
              headers: {"x-litellm-mcp": "true"}
            }
          }) | from_entries
        ))' <<<"$mcp_doc")"
      synced_mcp="$mcp_arr"
    else
      mcp_doc="$(jq \
        --argjson reg "$reg" \
        --argjson names "$mcp_arr" \
        '.mcpServers = ((.mcpServers // {}) + (
          [ $names[] as $n | ($reg.mcp_servers[$n] // null) | select(. != null) | {
              key: $n,
              value: (
                if .transport == "stdio" then
                  {command: .command, args: (.args // [])}
                else
                  {type: .transport, url: .url}
                end
              )
            } ] | from_entries
        ))' <<<"$mcp_doc")"
      synced_mcp="$(jq -c --argjson reg "$reg" '[ .[] | select($reg.mcp_servers[.] != null) ]' <<<"$mcp_arr")"
    fi
    printf '%s\n' "$mcp_doc" > "$abs_repo/.mcp.json"
  fi

  # Provision enabled central skills into <repo>/.agents/skills/<skill>
  local synced_skills="[]" s_name s_src
  local -a s_list=()
  mapfile -t s_list < <(jq -r '.[]' <<<"$skills_arr" 2>/dev/null || true)
  for s_name in "${s_list[@]:-}"; do
    [[ -n "$s_name" ]] || continue
    s_src="$(jq -r --arg n "$s_name" '.skills[$n].path // empty' <<<"$reg" 2>/dev/null)"
    if [[ -n "$s_src" && -d "$s_src" ]]; then
      mkdir -p "$abs_repo/.agents/skills"
      rm -rf "${abs_repo}/.agents/skills/${s_name}"
      cp -R "$s_src" "${abs_repo}/.agents/skills/${s_name}"
      synced_skills="$(jq -c --arg n "$s_name" '. + [$n]' <<<"$synced_skills")"
    fi
  done

  jq -cn \
    --arg repo "$abs_repo" \
    --arg mode "$mcp_mode" \
    --arg lurl "$litellm_url" \
    --argjson mcp "$synced_mcp" \
    --argjson sk "$synced_skills" \
    '{
      schema: "afk-tooling-sync/1",
      repo_path: $repo,
      mcp_mode: $mode,
      litellm_mcp_url: (if $lurl == "" then null else $lurl end),
      synced_mcp_servers: $mcp,
      synced_skills: $sk
    }'
}
