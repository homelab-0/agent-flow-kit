#!/usr/bin/env bash
# afk-paperclip-hire.sh — Dynamic per-project agent hiring, stage assignment,
# context-replacement session reset, and idle agent removal in Paperclip.
#
# Reuses afk_pc_curl and afk_pc_read_key from lib/afk-paperclip.sh and
# afk_roster_discover from lib/afk-roster.sh. Never logs or prints a secret.
# This file is SOURCED, never executed.

# shellcheck disable=SC2034,SC2154
if [[ -n "${AFK_PAPERCLIP_HIRE_SOURCED:-}" ]]; then
  return 0
fi
AFK_PAPERCLIP_HIRE_SOURCED=1

declare -F afk_pc_curl >/dev/null 2>&1 || . "$(dirname -- "${BASH_SOURCE[0]}")/afk-paperclip.sh"
declare -F afk_roster_discover >/dev/null 2>&1 || . "$(dirname -- "${BASH_SOURCE[0]}")/afk-roster.sh"

afk_pch_ledger_path() {
  printf '%s/paperclip/hired-agents.json' "$AFK_STATE_DIR"
}

afk_pch_load_ledger() {
  local p
  p="$(afk_pch_ledger_path)"
  if [[ -f "$p" ]]; then
    cat "$p" 2>/dev/null || printf '{"schema":"afk-hired-agents/1","projects":{}}'
  else
    printf '{"schema":"afk-hired-agents/1","projects":{}}'
  fi
}

afk_pch_save_ledger() { # <json>
  local p dir tmp
  p="$(afk_pch_ledger_path)"
  dir="$(dirname -- "$p")"
  mkdir -p "$dir"
  chmod 700 "$dir" 2>/dev/null || true
  tmp="$p.tmp.$$"
  (umask 077 && printf '%s\n' "$1" > "$tmp") && mv "$tmp" "$p"
}

afk_pch_adapter_for_harness() { # <harness>
  case "${1:-claude}" in
    codex)    printf 'codex_local' ;;
    opencode) printf 'opencode_local' ;;
    *)        printf 'claude_local' ;;
  esac
}

# afk_pch_hire_role <api_url> <key> <company_id> <host_agent_id> <slug> <repo_path> <harness> <role_json> [<source_issue_id>]
# Ensures one project-specific role is hired and active in Paperclip.
# Prints the updated ledger entry JSON on stdout.
afk_pch_hire_role() {
  local api_url="$1" key="$2" company_id="$3" host_agent_id="$4"
  local slug="$5" repo_path="$6" harness="$7" role_json="$8" issue_id="${9:-}"

  local role persona pc_role title icon skill_path caps adapter_type agent_name
  role="$(jq -r '.role' <<<"$role_json")"
  persona="$(jq -r '.persona_name' <<<"$role_json")"
  pc_role="$(jq -r '.paperclip_role' <<<"$role_json")"
  title="$(jq -r '.title' <<<"$role_json")"
  icon="$(jq -r '.icon' <<<"$role_json")"
  skill_path="$(jq -r '.skill_path' <<<"$role_json")"
  caps="$(jq -r '.capabilities' <<<"$role_json")"
  adapter_type="$(afk_pch_adapter_for_harness "$harness")"
  agent_name="${slug}-${role}"

  local ledger existing_id existing_state
  ledger="$(afk_pch_load_ledger)"
  existing_id="$(jq -r --arg s "$slug" --arg r "$role" '.projects[$s].agents[$r].agent_id // empty' <<<"$ledger" 2>/dev/null)"
  existing_state="$(jq -r --arg s "$slug" --arg r "$role" '.projects[$s].agents[$r].state // empty' <<<"$ledger" 2>/dev/null)"

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # If already hired and paused, resume it in Paperclip.
  if [[ -n "$existing_id" && "$existing_id" != local-* && "$existing_state" == "paused" && -n "$api_url" && -n "$key" ]]; then
    afk_pc_curl POST "$api_url/api/agents/$existing_id/resume" "$key" "" '{}' >/dev/null 2>&1 || true
    existing_state="active"
  fi

  # If not yet hired in Paperclip (or previously local/terminated), adopt an existing
  # Paperclip agent with the same name or submit a hire request when credentials are present.
  if [[ -z "$existing_id" || "$existing_id" == local-* || "$existing_state" == "terminated" ]]; then
    if [[ -n "$api_url" && -n "$key" && -n "$company_id" ]]; then
      local list_resp list_code list_body found_id found_status
      list_resp="$(afk_pc_curl GET "$api_url/api/companies/$company_id/agents" "$key" "")"
      list_code="${list_resp%%$'\n'*}"
      list_body="${list_resp#*$'\n'}"
      if [[ "$list_code" == 2?? ]]; then
        found_id="$(jq -r --arg n "$agent_name" '[.[] | select(.name == $n and .status != "terminated")][0].id // empty' <<<"$list_body" 2>/dev/null)"
        found_status="$(jq -r --arg n "$agent_name" '[.[] | select(.name == $n and .status != "terminated")][0].status // empty' <<<"$list_body" 2>/dev/null)"
        if [[ -n "$found_id" ]]; then
          existing_id="$found_id"
          if [[ "$found_status" == "paused" ]]; then
            afk_pc_curl POST "$api_url/api/agents/$existing_id/resume" "$key" "" '{}' >/dev/null 2>&1 || true
          fi
          existing_state="active"
        fi
      fi
      if [[ -z "$existing_id" || "$existing_id" == local-* || "$existing_state" == "terminated" ]]; then
        local hire_body resp code body hired_id valid_issue=""
        if [[ "$issue_id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
          valid_issue="$issue_id"
        fi
        hire_body="$(jq -cn \
          --arg name "$agent_name" \
          --arg role "$pc_role" \
          --arg title "$slug — $title" \
          --arg icon "$icon" \
          --arg reportsTo "$host_agent_id" \
          --arg caps "$caps" \
          --arg adapter "$adapter_type" \
          --arg issue "$valid_issue" \
          '{
            name: $name,
            role: $role,
            title: $title,
            icon: $icon,
            reportsTo: $reportsTo,
            capabilities: $caps,
            adapterType: $adapter,
            adapterConfig: {},
            runtimeConfig: {heartbeat: {enabled: false, wakeOnDemand: false, intervalSec: 0}}
          } + (if $issue != "" then {sourceIssueId: $issue} else {} end)')"
        resp="$(afk_pc_curl POST "$api_url/api/companies/$company_id/agent-hires" "$key" "" "$hire_body")"
        code="${resp%%$'\n'*}"
        body="${resp#*$'\n'}"
        if [[ "$code" == 2?? ]]; then
          hired_id="$(jq -r '.agent.id // .id // empty' <<<"$body" 2>/dev/null)"
          if [[ -n "$hired_id" ]]; then
            existing_id="$hired_id"
            existing_state="active"
          fi
        fi
      fi
    fi
    # When running offline or if Paperclip returns pending approval without an immediate agent id,
    # assign a deterministic local tracking id so local factory orchestration never blocks.
    if [[ -z "$existing_id" ]]; then
      existing_id="local-${slug}-${role}"
      existing_state="active_local"
    fi
  fi

  local entry
  entry="$(jq -cn \
    --arg id "$existing_id" \
    --arg name "$agent_name" \
    --arg role "$role" \
    --arg persona "$persona" \
    --arg title "$title" \
    --arg state "${existing_state:-active}" \
    --arg skill "$skill_path" \
    --arg now "$now" \
    '{
      agent_id: $id,
      name: $name,
      role: $role,
      persona_name: $persona,
      title: $title,
      state: $state,
      skill_path: $skill,
      generation: 1,
      updated_at: $now
    }')"

  ledger="$(jq -c \
    --arg s "$slug" \
    --arg repo "$repo_path" \
    --arg r "$role" \
    --argjson e "$entry" \
    '.projects[$s].repo_path = $repo | .projects[$s].agents[$r] = ((.projects[$s].agents[$r] // {}) * $e)' <<<"$ledger")"
  afk_pch_save_ledger "$ledger"
  printf '%s\n' "$entry"
}

# afk_pch_ensure_project_team <slug> <repo_path> <harness> <roles_csv> [<issue_id>] [<api_url>] [<key>] [<company_id>] [<host_agent_id>]
# Discovers the project's roster (BMAD or Factory default) and hires/activates
# the requested roles in Paperclip.
afk_pch_ensure_project_team() {
  local slug="$1" repo_path="$2" harness="${3:-claude}" roles_csv="${4:-pm,dev,reviewer,approver}"
  local issue_id="${5:-}" api_url="${6:-}" key="${7:-}" company_id="${8:-}" host_agent_id="${9:-}"

  local roster
  roster="$(afk_roster_discover "$repo_path")" || return 1
  local -a req_roles=()
  IFS=, read -r -a req_roles <<<"$roles_csv"

  local r role_json hired_list="[]" h
  for r in "${req_roles[@]}"; do
    [[ -n "$r" ]] || continue
    role_json="$(jq -c --arg r "$r" '.agents[] | select(.role == $r)' <<<"$roster" 2>/dev/null)"
    [[ -n "$role_json" ]] || continue
    h="$(afk_pch_hire_role "$api_url" "$key" "$company_id" "$host_agent_id" "$slug" "$repo_path" "$harness" "$role_json" "$issue_id")"
    hired_list="$(jq -c --argjson item "$h" '. + [$item]' <<<"$hired_list")"
  done
  printf '%s\n' "$hired_list"
}

# afk_pch_ensure_run_id <api_url> <key> <host_agent_id> <issue_id>
# Resolves an active Paperclip heartbeat run_id for <issue_id> (required by
# Paperclip v2026.1012.0+ on issue PATCH and comment POST via X-Paperclip-Run-Id).
afk_pch_ensure_run_id() {
  local api_url="$1" key="$2" host_agent_id="${3:-}" issue_id="${4:-}"
  if [[ -n "${PAPERCLIP_RUN_ID:-}" ]]; then
    printf '%s' "$PAPERCLIP_RUN_ID"
    return 0
  fi
  [[ -n "$api_url" && -n "$key" && -n "$issue_id" ]] || return 0
  local ar ar_code ar_body rid=""
  ar="$(afk_pc_curl GET "$api_url/api/issues/$issue_id/active-run" "$key" "")"
  ar_code="${ar%%$'\n'*}"
  ar_body="${ar#*$'\n'}"
  if [[ "$ar_code" == 2?? ]]; then
    rid="$(jq -r '.id // empty' <<<"$ar_body" 2>/dev/null)"
  fi
  if [[ -z "$rid" || ! "$rid" =~ ^[A-Za-z0-9_-]+$ ]] && [[ -n "$host_agent_id" ]]; then
    local wr wr_code wr_body
    wr="$(afk_pc_curl POST "$api_url/api/agents/$host_agent_id/wakeup" "$key" "" \
      "$(jq -nc --arg id "$issue_id" '{source:"timer", payload:{issueId:$id}}')")"
    wr_code="${wr%%$'\n'*}"
    wr_body="${wr#*$'\n'}"
    if [[ "$wr_code" == 2?? ]]; then
      rid="$(jq -r '.id // empty' <<<"$wr_body" 2>/dev/null)"
    fi
  fi
  [[ "$rid" =~ ^[A-Za-z0-9_-]+$ ]] && printf '%s' "$rid"
  return 0
}

# afk_pch_assign_stage <slug> <role> <issue_id> <stage_summary> [<api_url>] [<key>] [<run_id>]
# Updates the active role in the local hiring ledger and, when Paperclip API
# credentials are supplied, ensures the issue is in_progress and posts a
# concise stage handoff note attributed to <run_id>.
afk_pch_assign_stage() {
  local slug="$1" role="$2" issue_id="${3:-}" summary="${4:-}" api_url="${5:-}" key="${6:-}" run_id="${7:-${PAPERCLIP_RUN_ID:-}}"
  local ledger
  ledger="$(afk_pch_load_ledger)"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ledger="$(jq -c --arg s "$slug" --arg r "$role" --arg i "$issue_id" --arg now "$now" \
    '.projects[$s].active_role = $r | .projects[$s].active_issue = $i | .projects[$s].updated_at = $now' <<<"$ledger")"
  afk_pch_save_ledger "$ledger"

  if [[ -n "$api_url" && -n "$key" && -n "$issue_id" ]]; then
    afk_pc_curl PATCH "$api_url/api/issues/$issue_id" "$key" "$run_id" '{"status":"in_progress"}' >/dev/null 2>&1 || true
    if [[ -n "$summary" ]]; then
      afk_pc_comment "$api_url" "$issue_id" "$key" "$run_id" "$summary" >/dev/null 2>&1 || true
    fi
  fi
}

# afk_pch_replace_agent_session <slug> <role> <new_gen> <issue_id> <reason> [<api_url>] [<key>] [<run_id>]
# Resets the Paperclip runtime session for an agent that hit its context threshold
# and records the replacement generation in the ledger.
afk_pch_replace_agent_session() {
  local slug="$1" role="$2" new_gen="$3" issue_id="${4:-}" reason="${5:-context threshold reached}"
  local api_url="${6:-}" key="${7:-}" run_id="${8:-${PAPERCLIP_RUN_ID:-}}"
  local ledger agent_id persona
  ledger="$(afk_pch_load_ledger)"
  agent_id="$(jq -r --arg s "$slug" --arg r "$role" '.projects[$s].agents[$r].agent_id // empty' <<<"$ledger" 2>/dev/null)"
  persona="$(jq -r --arg s "$slug" --arg r "$role" '.projects[$s].agents[$r].persona_name // $r' <<<"$ledger" 2>/dev/null)"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  ledger="$(jq -c --arg s "$slug" --arg r "$role" --arg now "$now" --argjson g "$new_gen" \
    '.projects[$s].agents[$r].generation = $g | .projects[$s].agents[$r].updated_at = $now' <<<"$ledger")"
  afk_pch_save_ledger "$ledger"

  if [[ -n "$api_url" && -n "$key" ]]; then
    if [[ -n "$agent_id" && "$agent_id" != local-* ]]; then
      afk_pc_curl POST "$api_url/api/agents/$agent_id/runtime-state/reset-session" "$key" "$run_id" '{}' >/dev/null 2>&1 || true
      afk_pc_curl PATCH "$api_url/api/agents/$agent_id" "$key" "$run_id" '{"status":"paused"}' >/dev/null 2>&1 || true
      afk_pc_curl POST "$api_url/api/agents/$agent_id/resume" "$key" "$run_id" '{}' >/dev/null 2>&1 || true
    fi
    if [[ -n "$issue_id" ]]; then
      afk_pc_comment "$api_url" "$issue_id" "$key" "$run_id" \
        "AFK replaced project agent \`${slug}-${role}\` (${persona}) with fresh generation ${new_gen} (${reason}). Continuing from checkpoint." >/dev/null 2>&1 || true
    fi
  fi
}

# afk_pch_retire_project_agents <slug> [<roles_csv_or_all>] [<api_url>] [<key>]
# Retires/pauses project agents in Paperclip when work completes or specialist
# roles are no longer needed. Attempts /terminate first; falls back to PATCH
# status="paused" (or /pause) when using an agent key.
afk_pch_retire_project_agents() {
  local slug="$1" target_roles="${2:-all}" api_url="${3:-}" key="${4:-}"
  local ledger
  ledger="$(afk_pch_load_ledger)"
  local -a roles=()
  if [[ "$target_roles" == "all" ]]; then
    mapfile -t roles < <(jq -r --arg s "$slug" '.projects[$s].agents // {} | keys[]' <<<"$ledger" 2>/dev/null)
  else
    IFS=, read -r -a roles <<<"$target_roles"
  fi
  local now r aid resp code new_state retired="[]"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for r in "${roles[@]:-}"; do
    [[ -n "$r" ]] || continue
    aid="$(jq -r --arg s "$slug" --arg r "$r" '.projects[$s].agents[$r].agent_id // empty' <<<"$ledger" 2>/dev/null)"
    [[ -n "$aid" ]] || continue
    new_state="paused"
    if [[ -n "$api_url" && -n "$key" && "$aid" != local-* ]]; then
      resp="$(afk_pc_curl POST "$api_url/api/agents/$aid/terminate" "$key" "" '{}')"
      code="${resp%%$'\n'*}"
      if [[ "$code" == 2?? ]]; then
        new_state="terminated"
      else
        afk_pc_curl PATCH "$api_url/api/agents/$aid" "$key" "" '{"status":"paused"}' >/dev/null 2>&1 || \
          afk_pc_curl POST "$api_url/api/agents/$aid/pause" "$key" "" '{}' >/dev/null 2>&1 || true
        new_state="paused"
      fi
    fi
    ledger="$(jq -c --arg s "$slug" --arg r "$r" --arg st "$new_state" --arg now "$now" \
      '.projects[$s].agents[$r].state = $st | .projects[$s].agents[$r].updated_at = $now' <<<"$ledger")"
    retired="$(jq -c --arg r "$r" --arg id "$aid" --arg st "$new_state" '. + [{role:$r, agent_id:$id, state:$st}]' <<<"$retired")"
  done
  if [[ "$target_roles" == "all" ]]; then
    ledger="$(jq -c --arg s "$slug" '.projects[$s].active_role = null | .projects[$s].active_issue = null' <<<"$ledger")"
  fi
  afk_pch_save_ledger "$ledger"
  printf '%s\n' "$retired"
}
