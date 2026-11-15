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

AFK_PCH_EMPTY_LEDGER='{"schema":"afk-hired-agents/1","projects":{}}'
# A writer holds the ledger lock for a few milliseconds, so a lock this old
# belongs to a process that was killed while holding it.
AFK_PCH_LOCK_STALE_S="${AFK_PCH_LOCK_STALE_S:-60}"
# Longer than the stale age, so a waiter always outlives a dead holder's lock.
AFK_PCH_LOCK_WAIT_S="${AFK_PCH_LOCK_WAIT_S:-90}"
[[ "$AFK_PCH_LOCK_STALE_S" =~ ^[0-9]+$ ]] || AFK_PCH_LOCK_STALE_S=60
[[ "$AFK_PCH_LOCK_WAIT_S" =~ ^[0-9]+$ ]] || AFK_PCH_LOCK_WAIT_S=90

afk_pch_ledger_valid() { # <json>
  [[ -n "${1:-}" ]] && jq -e '(.projects | type) == "object"' <<<"$1" >/dev/null 2>&1
}

# An empty or unreadable file loads as the empty ledger. Passing the damaged
# text on would make every later jq update fail and save nothing useful.
afk_pch_load_ledger() {
  local p raw=""
  p="$(afk_pch_ledger_path)"
  if [[ -f "$p" ]] && raw="$(cat "$p" 2>/dev/null)" && afk_pch_ledger_valid "$raw"; then
    printf '%s' "$raw"
  else
    printf '%s' "$AFK_PCH_EMPTY_LEDGER"
  fi
}

# Under the lock, before a write: a ledger file that exists and does not read
# back is moved aside, so the write that follows does not replace every other
# project's entries with one. One more read first rides out a passing failure.
_afk_pch_ledger_set_aside_if_bad() {
  local p raw
  p="$(afk_pch_ledger_path)"
  [[ -s "$p" ]] || return 0
  raw="$(cat "$p" 2>/dev/null)" && afk_pch_ledger_valid "$raw" && return 0
  sleep 0.2 2>/dev/null || sleep 1
  raw="$(cat "$p" 2>/dev/null)" && afk_pch_ledger_valid "$raw" && return 0
  mv -f -- "$p" "$p.corrupt.$(date -u +%Y%m%dT%H%M%SZ)" 2>/dev/null || true
  afk_warn "hired-agents ledger could not be read and was set aside; agents are adopted again by name"
  return 0
}

# Refuses anything that is not a ledger, so a failed jq step upstream keeps
# the file already on disk. Each writer gets its own temp file: jobs forked
# from one poll process share $$.
afk_pch_save_ledger() { # <json>
  local p dir tmp
  afk_pch_ledger_valid "${1:-}" || return 1
  p="$(afk_pch_ledger_path)"
  dir="$(dirname -- "$p")"
  mkdir -p "$dir" || return 1
  chmod 700 "$dir" 2>/dev/null || true
  tmp="$(mktemp "${p}.tmp.XXXXXX")" || return 1
  if printf '%s\n' "$1" > "$tmp" && mv -f "$tmp" "$p"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

_afk_pch_mtime() { # <path> -- GNU stat, then BSD stat
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# Removes a lock (or breaker) directory older than the stale age. Only the
# process that creates the breaker directory may do this, and it looks at the
# lock again once inside: otherwise two waiters could both judge the same lock
# stale and the slower one would remove the lock the faster one just took.
_afk_pch_break_stale_lock() { # <lock_dir>
  local lock="$1" breaker="$1.break" mtime now
  now="$(date +%s)"
  if ! mkdir "$breaker" 2>/dev/null; then
    mtime="$(_afk_pch_mtime "$breaker")"
    if [[ "$mtime" =~ ^[0-9]+$ ]] && (( now - mtime > AFK_PCH_LOCK_STALE_S )); then
      rmdir "$breaker" 2>/dev/null
    fi
    return 0
  fi
  mtime="$(_afk_pch_mtime "$lock")"
  if [[ "$mtime" =~ ^[0-9]+$ ]] && (( now - mtime > AFK_PCH_LOCK_STALE_S )); then
    rmdir "$lock" 2>/dev/null
  fi
  rmdir "$breaker" 2>/dev/null
  return 0
}

# mkdir is atomic on every filesystem and needs no flock, which macOS lacks.
# Returns non-zero when the lock is still held after the bounded wait.
afk_pch_lock_ledger() {
  local p lock start=$SECONDS tries=0 missing=0
  p="$(afk_pch_ledger_path)"
  lock="$p.lock"
  mkdir -p "$(dirname -- "$p")" 2>/dev/null || return 1
  until mkdir "$lock" 2>/dev/null; do
    # mkdir also fails on a read-only or full disk, or when the path is a
    # file. Only an existing lock directory is worth waiting for; anything
    # else would cost the full wait on every write. The holder can also have
    # released it between the two checks, so a missing lock is tried again a
    # few times before the write is given up.
    if [[ ! -d "$lock" ]]; then
      (( missing++ < 20 )) || return 1
      continue
    fi
    # Look for a dead holder on the first miss and then about once a second.
    (( tries++ % 20 == 0 )) && _afk_pch_break_stale_lock "$lock"
    if (( SECONDS - start >= AFK_PCH_LOCK_WAIT_S )); then
      return 1
    fi
    sleep 0.05 2>/dev/null || sleep 1
  done
}

afk_pch_unlock_ledger() {
  rmdir "$(afk_pch_ledger_path).lock" 2>/dev/null || true
}

# afk_pch_update_ledger <jq_filter> [<jq args>...]
# Re-reads the ledger under the lock, applies the filter and writes the result.
# Callers finish their HTTP calls first: the lock is never held across one, and
# the re-read is what keeps another job's entries.
afk_pch_update_ledger() {
  local filter="$1" cur new rc=1
  shift
  afk_pch_lock_ledger || return 1
  _afk_pch_ledger_set_aside_if_bad
  cur="$(afk_pch_load_ledger)"
  if new="$(jq -c "$@" "$filter" <<<"$cur")" && afk_pch_save_ledger "$new"; then
    rc=0
  fi
  afk_pch_unlock_ledger
  return "$rc"
}

afk_pch_adapter_for_harness() { # <harness>
  case "${1:-claude}" in
    codex)    printf 'codex_local' ;;
    opencode) printf 'opencode_local' ;;
    pi)       printf 'pi_local' ;;
    agy)      printf 'gemini_local' ;;
    *)        printf 'claude_local' ;;
  esac
}

# afk_pch_hire_role <api_url> <key> <company_id> <host_agent_id> <slug> <repo_path> <harness> <role_json> [<source_issue_id>]
# Ensures one project-specific role is hired and active in Paperclip.
# Prints the updated ledger entry JSON on stdout. A hire that Paperclip accepted
# without an agent id is recorded with status "pending" and pending_since, and
# is not posted again: later calls only look for the agent in the agent list.
# Returns non-zero when the ledger could not be written.
# _afk_pch_live_pending <ledger> <slug> <role> -> pending_since, or nothing
# A pending hire older than AFK_PCH_PENDING_EXPIRE_S (default 6 hours) no
# longer counts: the request was refused or lost and may be sent again.
_afk_pch_live_pending() {
  local exp="${AFK_PCH_PENDING_EXPIRE_S:-21600}"
  [[ "$exp" =~ ^[0-9]+$ ]] || exp=21600
  jq -r --arg s "$2" --arg r "$3" --argjson now "$(date -u +%s)" --argjson exp "$exp" '
    .projects[$s].agents[$r] // {} | select(.status == "pending")
    | (.pending_since // "") as $ps
    | (try ($ps | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch 0) as $ep
    | if ($now - $ep) < $exp then ($ps | if . == "" then "unknown" else . end) else empty end' <<<"$1" 2>/dev/null || true
}

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

  local ledger existing_id existing_state pending_since
  ledger="$(afk_pch_load_ledger)"
  existing_id="$(jq -r --arg s "$slug" --arg r "$role" '.projects[$s].agents[$r].agent_id // empty' <<<"$ledger" 2>/dev/null)"
  existing_state="$(jq -r --arg s "$slug" --arg r "$role" '.projects[$s].agents[$r].state // empty' <<<"$ledger" 2>/dev/null)"
  # Set while a hire request waits for approval in Paperclip. It stops the
  # request being posted again on every later call.
  # A request that has waited longer than the expiry was refused or lost,
  # and is posted again.
  pending_since="$(_afk_pch_live_pending "$ledger" "$slug" "$role")"

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
      local list_resp list_code list_body found_id="" found_status="" listed=false
      list_resp="$(afk_pc_curl GET "$api_url/api/companies/$company_id/agents" "$key" "")"
      list_code="${list_resp%%$'\n'*}"
      list_body="${list_resp#*$'\n'}"
      if [[ "$list_code" == 2?? ]]; then
        listed=true
        found_id="$(jq -r --arg n "$agent_name" '[.[] | select(.name == $n and .status != "terminated")][0].id // empty' <<<"$list_body" 2>/dev/null)"
        found_status="$(jq -r --arg n "$agent_name" '[.[] | select(.name == $n and .status != "terminated")][0].status // empty' <<<"$list_body" 2>/dev/null)"
        if [[ -n "$found_id" ]]; then
          existing_id="$found_id"
          if [[ "$found_status" == "paused" ]]; then
            afk_pc_curl POST "$api_url/api/agents/$existing_id/resume" "$key" "" '{}' >/dev/null 2>&1 || true
          fi
          existing_state="active"
          pending_since=""
        fi
      fi
      # Post a hire only when the list answered and showed no agent of this
      # name, and no earlier request is still waiting. A failed list says
      # nothing about whether the agent exists, so that pass posts nothing.
      if [[ "$listed" == true && -z "$found_id" && -z "$pending_since" ]]; then
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
        # Claim the hire before sending it. Two jobs of one project reach this
        # point together; the second sees the claim and does not post.
        local claimed=false
        if afk_pch_lock_ledger; then
          _afk_pch_ledger_set_aside_if_bad
          if [[ -z "$(_afk_pch_live_pending "$(afk_pch_load_ledger)" "$slug" "$role")" ]]; then
            afk_pch_save_ledger "$(jq -c --arg s "$slug" --arg r "$role" --arg n "$agent_name" --arg now "$now" '
              .projects[$s].agents[$r] = ((.projects[$s].agents[$r] // {name: $n, role: $r, agent_id: ("local-" + $s + "-" + $r), state: "active_local"})
                + {status: "pending", pending_since: $now})' <<<"$(afk_pch_load_ledger)")" && claimed=true
          fi
          afk_pch_unlock_ledger
        fi
        resp=""; code=""
        [[ "$claimed" == true ]] && resp="$(afk_pc_curl POST "$api_url/api/companies/$company_id/agent-hires" "$key" "" "$hire_body")"
        code="${resp%%$'\n'*}"
        body="${resp#*$'\n'}"
        [[ "$claimed" == true ]] || pending_since="$now"
        if [[ "$code" == 2?? ]]; then
          hired_id="$(jq -r '.agent.id // .id // empty' <<<"$body" 2>/dev/null)"
          if [[ -n "$hired_id" ]]; then
            existing_id="$hired_id"
            existing_state="active"
          else
            # Accepted without an agent id: the hire is waiting for approval.
            pending_since="$now"
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

  # The HTTP calls are done. Take the lock, read the ledger again and merge
  # this role into what is there now, so a job that wrote in the meantime
  # keeps its entries.
  local entry new locked=false rc=0
  if afk_pch_lock_ledger; then
    locked=true
    _afk_pch_ledger_set_aside_if_bad
    ledger="$(afk_pch_load_ledger)"
  else
    rc=1
  fi
  # The generation belongs to the context-replacement path, so hiring keeps
  # the one on record and starts at 1 only for a role it has not seen. A real
  # agent id that another job recorded since the first read is kept over a
  # placeholder from this one.
  entry="$(jq -c \
    --arg s "$slug" \
    --arg id "$existing_id" \
    --arg name "$agent_name" \
    --arg role "$role" \
    --arg persona "$persona" \
    --arg title "$title" \
    --arg state "${existing_state:-active}" \
    --arg skill "$skill_path" \
    --arg pending "$pending_since" \
    --arg now "$now" \
    '(.projects[$s].agents[$role] // {}) as $cur
    | (($id | startswith("local-"))
       and ($cur.agent_id | type) == "string"
       and ($cur.agent_id | startswith("local-") | not)
       and $cur.state != "terminated") as $keep
    | {
      agent_id: (if $keep then $cur.agent_id else $id end),
      name: $name,
      role: $role,
      persona_name: $persona,
      title: $title,
      state: (if $keep then ($cur.state // $state) else $state end),
      skill_path: $skill,
      generation: (if ($cur.generation | type) == "number" then $cur.generation else 1 end),
      updated_at: $now
    } + (if $pending != "" and ($keep | not) then {status: "pending", pending_since: $pending} else {} end)' <<<"$ledger")"

  if [[ "$locked" == true ]]; then
    if new="$(jq -c \
      --arg s "$slug" \
      --arg repo "$repo_path" \
      --arg r "$role" \
      --argjson e "$entry" \
      '.projects[$s].repo_path = $repo
      | .projects[$s].agents[$r] = (((.projects[$s].agents[$r] // {}) | del(.status, .pending_since)) * $e)' <<<"$ledger")" \
      && afk_pch_save_ledger "$new"; then
      :
    else
      rc=1
    fi
    afk_pch_unlock_ledger
  fi
  printf '%s\n' "$entry"
  return "$rc"
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
    [[ -n "$h" ]] || continue
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

# Standing project roles stay on the board as idle. Specialist roles are hired
# for one stage and paused when that stage ends. Neither path terminates them:
# a paused or terminated core agent disappears from the next assignment.
afk_pch_role_is_core() { # <role>
  case "${1:-}" in
    pm|dev|reviewer|approver) return 0 ;;
    *) return 1 ;;
  esac
}

afk_pch_keys_dir() {
  printf '%s/paperclip/keys' "$AFK_STATE_DIR"
}

# Prints the per-agent bearer key when the file exists and is owner-only.
# A group- or world-readable file is ignored so a loose key cannot be used.
afk_pch_read_agent_key() { # <agent_id>
  local id="${1:-}" f mode k
  [[ "$id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || return 0
  f="$(afk_pch_keys_dir)/${id}.key"
  [[ -f "$f" && ! -L "$f" ]] || return 0
  mode="$(stat -c '%a' -- "$f" 2>/dev/null || true)"
  [[ "$mode" == "600" || "$mode" == "400" ]] || return 0
  k="$(head -n 1 -- "$f" | tr -d '\r\n')"
  [[ -n "$k" ]] || return 0
  printf '%s' "$k"
}

afk_pch_agent_id() { # <slug> <role>
  local ledger
  ledger="$(afk_pch_load_ledger)"
  jq -r --arg s "$1" --arg r "$2" '.projects[$s].agents[$r].agent_id // empty' <<<"$ledger" 2>/dev/null || true
}

# Host key reassigns the issue (CEO/manager checkout authority). When a
# per-agent key exists it is used for that role's comments and documents so
# Paperclip records the hired agent as the author.
afk_pch_key_for_role() { # <slug> <role> <host_key>
  local aid akey
  aid="$(afk_pch_agent_id "$1" "$2")"
  akey="$(afk_pch_read_agent_key "$aid")"
  if [[ -n "$akey" ]]; then
    printf '%s' "$akey"
  else
    printf '%s' "${3:-}"
  fi
}

afk_pch_project_agent_ids_json() { # <slug>
  local ledger
  ledger="$(afk_pch_load_ledger)"
  jq -c --arg s "$1" '
    [.projects[$s].agents // {} | .[].agent_id // empty
     | select(. != "" and (startswith("local-") | not))]
  ' <<<"$ledger" 2>/dev/null || printf '[]'
}

afk_pch_role_for_agent_id() { # <slug> <agent_id>
  local ledger aid="${2:-}"
  [[ -n "$aid" ]] || return 0
  ledger="$(afk_pch_load_ledger)"
  jq -r --arg s "$1" --arg a "$aid" '
    .projects[$s].agents // {} | to_entries[] | select(.value.agent_id == $a) | .key
  ' <<<"$ledger" 2>/dev/null | head -n 1
}

# Markdown attribution used when comments still ride the host bearer key.
# Paperclip sets authorAgentId from the key, so the header is the visible persona.
afk_pch_persona_header() { # <slug> <role>
  local slug="$1" role="$2" ledger persona aid
  ledger="$(afk_pch_load_ledger)"
  persona="$(jq -r --arg s "$slug" --arg r "$role" '.projects[$s].agents[$r].persona_name // empty' <<<"$ledger" 2>/dev/null)"
  aid="$(jq -r --arg s "$slug" --arg r "$role" '.projects[$s].agents[$r].agent_id // empty' <<<"$ledger" 2>/dev/null)"
  [[ -n "$persona" || -n "$aid" ]] || return 0
  [[ -n "$persona" ]] || persona="$role"
  if [[ "$aid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    printf '### [%s — %s %s](agent://%s)' "$persona" "$slug" "$role" "$aid"
  else
    printf '### %s — %s %s' "$persona" "$slug" "$role"
  fi
}

afk_pch_comment_as_role() { # <api_url> <issue_id> <host_key> <run_id> <slug> <role> <body>
  local api_url="$1" issue_id="$2" host_key="$3" run_id="$4" slug="$5" role="$6" body="$7"
  local use_key header
  [[ -n "$api_url" && -n "$host_key" && -n "$issue_id" && -n "$body" ]] || return 0
  use_key="$(afk_pch_key_for_role "$slug" "$role" "$host_key")"
  if [[ "$use_key" == "$host_key" ]]; then
    header="$(afk_pch_persona_header "$slug" "$role" 2>/dev/null || true)"
    if [[ -n "$header" ]]; then
      body="$(printf '%s\n\n%s' "$header" "$body")"
    fi
  fi
  afk_pc_comment "$api_url" "$issue_id" "$use_key" "$run_id" "$body"
}

# Marks an issue done without changing assigneeAgentId. Paperclip cancels the
# host heartbeat run when the assignee changes, and the host cannot wake the
# project agent. The role is named in the comment, not by taking the checkout.
afk_pch_finish_issue() { # <slug> <role> <issue_id> <api_url> <host_key> <run_id>
  local slug="$1" role="$2" issue_id="${3:-}" api_url="${4:-}" key="${5:-}" run_id="${6:-}"
  [[ -n "$api_url" && -n "$key" && -n "$issue_id" ]] || return 0
  # afk_pc_curl succeeds on any HTTP answer. A rejected PATCH leaves the issue
  # open, so the caller must be able to tell.
  local resp
  resp="$(afk_pc_curl PATCH "$api_url/api/issues/$issue_id" "$key" "$run_id" '{"status":"done"}')"
  printf '%s' "$resp"
  [[ "${resp%%$'\n'*}" == 2?? ]]
}

# afk_pch_assign_stage <slug> <role> <issue_id> <stage_summary> [<api_url>] [<key>] [<run_id>]
# Updates the active role in the local hiring ledger and, when Paperclip API
# credentials are supplied, moves the Kanban assignee to that role's agent,
# keeps the issue in_progress, and posts a stage note. Comments and later
# document writes use the role key when one has been minted; otherwise the
# host key is used and the note carries a persona header.
afk_pch_assign_stage() {
  local slug="$1" role="$2" issue_id="${3:-}" summary="${4:-}" api_url="${5:-}" key="${6:-}" run_id="${7:-${PAPERCLIP_RUN_ID:-}}"
  local now rc=0
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  afk_pch_update_ledger \
    '.projects[$s].active_role = $r | .projects[$s].active_issue = $i | .projects[$s].updated_at = $now' \
    --arg s "$slug" --arg r "$role" --arg i "$issue_id" --arg now "$now" || rc=1

  if [[ -n "$api_url" && -n "$key" && -n "$issue_id" ]]; then
    # Keep the host checkout. Paperclip cancels a queued host run when
    # assigneeAgentId moves to the project agent, and the host cannot wake
    # that agent. The role is attributed in the comment instead.
    local resp
    resp="$(afk_pc_curl PATCH "$api_url/api/issues/$issue_id" "$key" "$run_id" '{"status":"in_progress"}' 2>/dev/null)"
    # The stage note is still posted, but a rejected status change is reported.
    # 2 means Paperclip did not take it: the board cannot see the stage.
    [[ "${resp%%$'\n'*}" == 2?? ]] || rc=2
    if [[ -n "$summary" ]]; then
      afk_pch_comment_as_role "$api_url" "$issue_id" "$key" "$run_id" "$slug" "$role" "$summary" >/dev/null 2>&1 || true
    fi
  fi
  return "$rc"
}

# afk_pch_replace_agent_session <slug> <role> <new_gen> <issue_id> <reason> [<api_url>] [<key>] [<run_id>]
# Resets the Paperclip runtime session for an agent that hit its context threshold
# and records the replacement generation in the ledger.
afk_pch_replace_agent_session() {
  local slug="$1" role="$2" new_gen="$3" issue_id="${4:-}" reason="${5:-context threshold reached}"
  local api_url="${6:-}" key="${7:-}" run_id="${8:-${PAPERCLIP_RUN_ID:-}}"
  # A generation that is not a number would make jq fail on --argjson. The
  # caller has not said which generation starts, so nothing is changed.
  [[ "$new_gen" =~ ^[0-9]+$ ]] || return 1
  new_gen=$((10#$new_gen))
  local ledger agent_id persona
  ledger="$(afk_pch_load_ledger)"
  agent_id="$(jq -r --arg s "$slug" --arg r "$role" '.projects[$s].agents[$r].agent_id // empty' <<<"$ledger" 2>/dev/null)"
  persona="$(jq -r --arg s "$slug" --arg r "$role" '.projects[$s].agents[$r].persona_name // $r' <<<"$ledger" 2>/dev/null)"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # confirmed_state is the last agent status Paperclip accepted. It stays
  # empty offline or when neither call went through, and the ledger state is
  # then left alone. A pause that worked followed by a resume that did not
  # is recorded as paused, which the next hire pass resumes.
  local confirmed_state="" resp rc=0
  if [[ -n "$api_url" && -n "$key" && -n "$agent_id" && "$agent_id" != local-* ]]; then
    resp="$(afk_pc_curl POST "$api_url/api/agents/$agent_id/runtime-state/reset-session" "$key" "$run_id" '{}' 2>/dev/null)"
    [[ "${resp%%$'\n'*}" == 2?? ]] || rc=1
    resp="$(afk_pc_curl PATCH "$api_url/api/agents/$agent_id" "$key" "$run_id" '{"status":"paused"}' 2>/dev/null)"
    if [[ "${resp%%$'\n'*}" == 2?? ]]; then confirmed_state="paused"; else rc=1; fi
    resp="$(afk_pc_curl POST "$api_url/api/agents/$agent_id/resume" "$key" "$run_id" '{}' 2>/dev/null)"
    if [[ "${resp%%$'\n'*}" == 2?? ]]; then confirmed_state="active"; else rc=1; fi
  fi

  afk_pch_update_ledger \
    '.projects[$s].agents[$r].generation = $g
     | .projects[$s].agents[$r].updated_at = $now
     | if $st != "" then .projects[$s].agents[$r].state = $st else . end' \
    --arg s "$slug" --arg r "$role" --arg now "$now" --arg st "$confirmed_state" --argjson g "$new_gen" || rc=1

  if [[ -n "$api_url" && -n "$key" && -n "$issue_id" ]]; then
    afk_pc_comment "$api_url" "$issue_id" "$key" "$run_id" \
      "AFK replaced project agent \`${slug}-${role}\` (${persona}) with fresh generation ${new_gen} (${reason}). Continuing from checkpoint." >/dev/null 2>&1 || true
  fi
  return "$rc"
}

# afk_pch_retire_project_agents <slug> [<roles_csv_or_all>] [<api_url>] [<key>]
# Releases project agents when work completes. Core roles (pm, dev, reviewer,
# approver) stay idle so the board can assign them the next issue. Specialist
# roles (analyst, architect, ux-designer) are paused. Agents are never terminated.
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
  local now r aid new_state retired="[]" patch
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for r in "${roles[@]:-}"; do
    [[ -n "$r" ]] || continue
    aid="$(jq -r --arg s "$slug" --arg r "$r" '.projects[$s].agents[$r].agent_id // empty' <<<"$ledger" 2>/dev/null)"
    [[ -n "$aid" ]] || continue
    if afk_pch_role_is_core "$r"; then
      new_state="idle"
    else
      new_state="paused"
    fi
    if [[ -n "$api_url" && -n "$key" && "$aid" != local-* ]]; then
      local resp code
      patch="$(jq -cn --arg st "$new_state" '{status:$st}')"
      resp="$(afk_pc_curl PATCH "$api_url/api/agents/$aid" "$key" "" "$patch")"
      code="${resp%%$'\n'*}"
      if [[ "$code" != 2?? && "$new_state" == "paused" ]]; then
        afk_pc_curl POST "$api_url/api/agents/$aid/pause" "$key" "" '{}' >/dev/null 2>&1 || true
      fi
    fi
    retired="$(jq -c --arg r "$r" --arg id "$aid" --arg st "$new_state" '. + [{role:$r, agent_id:$id, state:$st}]' <<<"$retired")"
  done
  # Every HTTP call is done. Apply all the state changes in one locked update
  # of the ledger as it is now, not of the copy read before the calls.
  local all=false rc=0
  [[ "$target_roles" == "all" ]] && all=true
  afk_pch_update_ledger \
    'reduce $changes[] as $c (.;
       .projects[$s].agents[$c.role].state = $c.state
       | .projects[$s].agents[$c.role].updated_at = $now)
     | if $all then .projects[$s].active_role = null | .projects[$s].active_issue = null else . end' \
    --arg s "$slug" --arg now "$now" --argjson changes "$retired" --argjson all "$all" || rc=1
  printf '%s\n' "$retired"
  return "$rc"
}

# _afk_pch_is_uuid <val>
_afk_pch_is_uuid() {
  [[ "${1:-}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# afk_pch_check_budget <api_url> <key> <agent_id>
# Queries Paperclip's live agent budget & monthly spend (Paperclip v2026.1106.0).
# Returns JSON: {ok, state: unlimited|ok|soft_warn|hard_stop|offline, budget_cents, spent_cents, utilization_pct, agent_status}
afk_pch_check_budget() {
  local api_url="${1:-}" key="${2:-}" agent_id="${3:-}"
  if [[ -z "$api_url" || -z "$key" || -z "$agent_id" ]]; then
    printf '{"ok":true,"state":"offline","budget_cents":0,"spent_cents":0,"utilization_pct":0,"agent_status":"local"}\n'
    return 0
  fi
  local resp code body
  resp="$(afk_pc_curl GET "$api_url/api/agents/$agent_id" "$key" "")"
  code="${resp%%$'\n'*}"
  body="${resp#*$'\n'}"
  if [[ "$code" != 2?? ]]; then
    printf '{"ok":true,"state":"offline","budget_cents":0,"spent_cents":0,"utilization_pct":0,"agent_status":"unreachable"}\n'
    return 0
  fi
  jq -cn --argjson a "$body" '
    ($a.budgetMonthlyCents // 0) as $b
    | ($a.spentMonthlyCents // 0) as $s
    | ($a.status // "idle") as $st
    | (if $b <= 0 then 0 else (($s * 100) / $b | floor) end) as $pct
    | (if $b <= 0 then "unlimited"
       elif $s >= $b then "hard_stop"
       elif $pct >= 80 then "soft_warn"
       else "ok" end) as $bstate
    | {
        ok: ($bstate != "hard_stop"),
        state: $bstate,
        budget_cents: $b,
        spent_cents: $s,
        utilization_pct: $pct,
        agent_status: $st
      }
  '
}

# afk_pch_report_cost_event <api_url> <key> <company_id> <host_agent_id> <issue_id> <project_id> <run_id> <billing_code> <provider> <biller> <billing_type> <model> <in_tok> <cached_in_tok> <out_tok> <cost_cents> <idem_key>
# Posts granular per-stage token & cost telemetry to POST /api/companies/{companyId}/cost-events.
# Note: Paperclip enforces req.actor.agentId === body.agentId for agent bearer keys,
# so agentId is always host_agent_id while billingCode encodes project/stage/role.
afk_pch_report_cost_event() {
  local api_url="${1:-}" key="${2:-}" company_id="${3:-}" host_agent_id="${4:-}"
  local issue_id="${5:-}" project_id="${6:-}" run_id="${7:-}" billing_code="${8:-}"
  # Two statements: inside one `local`, "$provider" is still the caller's
  # value (or empty), so the biller default was not this call's provider.
  local provider="${9:-anthropic}"
  local biller="${10:-$provider}" billing_type="${11:-subscription_included}"
  local model="${12:-sonnet}" in_tok="${13:-0}" cached_tok="${14:-0}" out_tok="${15:-0}"
  local cost_cents="${16:-0}" idem_key="${17:-}"

  [[ -n "$api_url" && -n "$key" && -n "$company_id" ]] && _afk_pch_is_uuid "$host_agent_id" || return 0
  local v_issue="" v_proj="" v_run=""
  _afk_pch_is_uuid "$issue_id" && v_issue="$issue_id"
  _afk_pch_is_uuid "$project_id" && v_proj="$project_id"
  _afk_pch_is_uuid "$run_id" && v_run="$run_id"
  [[ "$in_tok" =~ ^[0-9]+$ ]] || in_tok=0
  [[ "$cached_tok" =~ ^[0-9]+$ ]] || cached_tok=0
  [[ "$out_tok" =~ ^[0-9]+$ ]] || out_tok=0
  [[ "$cost_cents" =~ ^[0-9]+$ ]] || cost_cents=0

  local occurred_at payload resp code body
  occurred_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  payload="$(jq -cn \
    --arg aid "$host_agent_id" \
    --arg iss "$v_issue" \
    --arg prj "$v_proj" \
    --arg rid "$v_run" \
    --arg bc "${billing_code:0:100}" \
    --arg prov "${provider:0:50}" \
    --arg bil "${biller:0:50}" \
    --arg btype "$billing_type" \
    --arg mod "${model:0:100}" \
    --arg idem "${idem_key:0:200}" \
    --arg occ "$occurred_at" \
    --argjson it "$in_tok" \
    --argjson ct "$cached_tok" \
    --argjson ot "$out_tok" \
    --argjson cc "$cost_cents" \
    '{
      agentId: $aid,
      provider: $prov,
      biller: $bil,
      billingType: $btype,
      costStatus: "reported",
      model: $mod,
      inputTokens: $it,
      cachedInputTokens: $ct,
      outputTokens: $ot,
      costCents: $cc,
      occurredAt: $occ
    }
    + (if $iss != "" then {issueId: $iss} else {} end)
    + (if $prj != "" then {projectId: $prj} else {} end)
    + (if $rid != "" then {heartbeatRunId: $rid} else {} end)
    + (if $bc != "" then {billingCode: $bc} else {} end)
    + (if $idem != "" then {idempotencyKey: $idem} else {} end)')"
  resp="$(afk_pc_curl POST "$api_url/api/companies/$company_id/cost-events" "$key" "$run_id" "$payload")"
  code="${resp%%$'\n'*}"
  body="${resp#*$'\n'}"
  [[ "$code" == 2?? ]] && printf '%s\n' "$body"
  return 0
}

# afk_pch_upsert_document <api_url> <key> <run_id> <issue_id> <doc_key> <title> <file_path> [<change_summary>]
# Upserts a keyed, revisioned Paperclip Issue Document (e.g. "plan", "ux-design",
# "review-report", "merge-decision") via PUT /api/issues/{id}/documents/{key}.
afk_pch_upsert_document() {
  local api_url="${1:-}" key="${2:-}" run_id="${3:-}" issue_id="${4:-}"
  local doc_key="${5:-}" title="${6:-}" file_path="${7:-}" change_summary="${8:-Updated by AFK Software Factory}"
  [[ -n "$api_url" && -n "$key" && -n "$issue_id" && -n "$doc_key" && -f "$file_path" ]] || return 0
  _afk_pch_is_uuid "$issue_id" || return 0

  local get_resp get_code get_body base_rev=""
  get_resp="$(afk_pc_curl GET "$api_url/api/issues/$issue_id/documents/$doc_key" "$key" "")"
  get_code="${get_resp%%$'\n'*}"
  get_body="${get_resp#*$'\n'}"
  if [[ "$get_code" == 200 ]]; then
    base_rev="$(jq -r '.latestRevisionId // empty' <<<"$get_body" 2>/dev/null || true)"
  fi

  local content content_file payload put_resp put_code put_body
  content="$(head -c 500000 -- "$file_path" 2>/dev/null || true)"
  [[ -n "$content" ]] || return 0
  # The capped text goes to jq through a file. One argv string is limited to
  # about 128 KB on Linux, and a review report can be larger than that.
  content_file="$(mktemp "${TMPDIR:-/tmp}/afk-pch-doc.XXXXXX")" || return 1
  printf '%s' "$content" > "$content_file"
  payload="$(jq -cn \
    --arg t "${title:0:200}" \
    --rawfile b "$content_file" \
    --arg cs "${change_summary:0:500}" \
    --arg rev "$base_rev" \
    '{
      title: $t,
      format: "markdown",
      body: $b,
      changeSummary: $cs
    } + (if $rev != "" then {baseRevisionId: $rev} else {} end)')" || payload=""
  rm -f "$content_file"
  # No body means the PUT would go out empty, so it is not sent.
  [[ -n "$payload" ]] || return 1
  put_resp="$(afk_pc_curl PUT "$api_url/api/issues/$issue_id/documents/$doc_key" "$key" "$run_id" "$payload")"
  put_code="${put_resp%%$'\n'*}"
  put_body="${put_resp#*$'\n'}"
  if [[ "$put_code" == 2?? ]]; then
    jq -c '{id: .id, key: .key, latestRevisionId: .latestRevisionId, latestRevisionNumber: .latestRevisionNumber}' <<<"$put_body" 2>/dev/null || true
  fi
  return 0
}

# afk_pch_request_confirmation <api_url> <key> <run_id> <issue_id> <board_user_id> <idem_key> <title> <summary> <prompt> <details_md> [<doc_json>]
# Creates a structured interactive confirmation card on the issue thread
# (`POST /api/issues/{id}/interactions`) addressed to the human board user.
afk_pch_request_confirmation() {
  local api_url="${1:-}" key="${2:-}" run_id="${3:-}" issue_id="${4:-}"
  local board_user_id="${5:-}" idem_key="${6:-}" title="${7:-}" summary="${8:-}"
  local prompt="${9:-}" details_md="${10:-}" doc_json="${11:-}"
  [[ -n "$api_url" && -n "$key" && -n "$issue_id" ]] && _afk_pch_is_uuid "$issue_id" || return 0

  local target_json="null"
  if [[ -n "$doc_json" ]] && jq -e '.id != null and .latestRevisionId != null' <<<"$doc_json" >/dev/null 2>&1; then
    target_json="$(jq -cn --arg iid "$issue_id" --argjson d "$doc_json" '{
      type: "issue_document",
      issueId: $iid,
      documentId: $d.id,
      key: $d.key,
      revisionId: $d.latestRevisionId,
      revisionNumber: ($d.latestRevisionNumber // 1)
    }')"
  fi

  local accept_label="${12:-Approve & merge}" reject_label="${13:-Request changes}"
  local payload resp code body
  payload="$(jq -cn \
    --arg u "$board_user_id" \
    --arg idem "${idem_key:0:200}" \
    --arg ttl "${title:0:200}" \
    --arg sum "${summary:0:2000}" \
    --arg pr "${prompt:0:2000}" \
    --arg det "${details_md:0:50000}" \
    --arg acc "${accept_label:0:80}" \
    --arg rej "${reject_label:0:80}" \
    --argjson tgt "$target_json" \
    '{
      kind: "request_confirmation",
      resolverPolicy: "human_only",
      continuationPolicy: "wake_assignee",
      title: $ttl,
      summary: $sum,
      payload: ({
        version: 1,
        prompt: $pr,
        acceptLabel: $acc,
        rejectLabel: $rej,
        rejectRequiresReason: true,
        rejectReasonLabel: "What needs to change?",
        detailsMarkdown: $det,
        supersedeOnUserComment: true
      } + (if $tgt != null then {target: $tgt} else {} end))
    }
    + (if $u != "" then {addresseeUserId: $u} else {} end)
    + (if $idem != "" then {idempotencyKey: $idem} else {} end)')"
  resp="$(afk_pc_curl POST "$api_url/api/issues/$issue_id/interactions" "$key" "$run_id" "$payload")"
  code="${resp%%$'\n'*}"
  body="${resp#*$'\n'}"
  if [[ "$code" == 2?? ]]; then
    jq -c '(.interaction // .)' <<<"$body" 2>/dev/null || true
  fi
  return 0
}

# afk_pch_ask_user_questions <api_url> <key> <run_id> <issue_id> <board_user_id> <idem_key> <title> <questions_json>
# Posts a Paperclip ask_user_questions card. <questions_json> is a JSON array of
# {id, prompt, answerMode, required, options?}. Open questions use answerMode
# "text" and carry no options. Prints the interaction object on success.
afk_pch_ask_user_questions() {
  local api_url="${1:-}" key="${2:-}" run_id="${3:-}" issue_id="${4:-}"
  local board_user_id="${5:-}" idem_key="${6:-}" title="${7:-}" questions_json="${8:-[]}"
  [[ -n "$api_url" && -n "$key" && -n "$issue_id" ]] && _afk_pch_is_uuid "$issue_id" || return 0
  jq -e 'type == "array" and length > 0' <<<"$questions_json" >/dev/null 2>&1 || return 0

  local payload resp code body
  payload="$(jq -cn \
    --arg u "$board_user_id" \
    --arg idem "${idem_key:0:200}" \
    --arg ttl "${title:0:200}" \
    --argjson qs "$questions_json" \
    '{
      kind: "ask_user_questions",
      resolverPolicy: "human_only",
      continuationPolicy: "wake_assignee",
      title: $ttl,
      payload: {
        version: 1,
        questionSet: {
          schema: "paperclip.question_set.v1",
          questions: $qs
        }
      }
    }
    + (if $u != "" then {addresseeUserId: $u} else {} end)
    + (if $idem != "" then {idempotencyKey: $idem} else {} end)')"
  resp="$(afk_pc_curl POST "$api_url/api/issues/$issue_id/interactions" "$key" "$run_id" "$payload")"
  code="${resp%%$'\n'*}"
  body="${resp#*$'\n'}"
  if [[ "$code" == 2?? ]]; then
    jq -c '(.interaction // .)' <<<"$body" 2>/dev/null || true
  fi
  return 0
}

# afk_pch_create_child_issue <api_url> <key> <company_id> <parent_id> <project_id> <assignee_agent_id> <title> <description> <idem_key>
# Opens one implementation issue under a confirmed PRD. Prints the created issue JSON.
afk_pch_create_child_issue() {
  local api_url="${1:-}" key="${2:-}" company_id="${3:-}" parent_id="${4:-}"
  local project_id="${5:-}" assignee="${6:-}" title="${7:-}" description="${8:-}" idem_key="${9:-}"
  [[ -n "$api_url" && -n "$key" && -n "$company_id" && -n "$parent_id" ]] || return 0
  _afk_pch_is_uuid "$parent_id" || return 0
  local v_proj="" v_agent=""
  _afk_pch_is_uuid "$project_id" && v_proj="$project_id"
  _afk_pch_is_uuid "$assignee" && v_agent="$assignee"
  local payload resp code body
  payload="$(jq -cn \
    --arg t "${title:0:300}" \
    --arg d "${description:0:8000}" \
    --arg p "$parent_id" \
    --arg prj "$v_proj" \
    --arg a "$v_agent" \
    --arg idem "${idem_key:0:200}" \
    '{
      title: $t,
      description: $d,
      status: "todo",
      parentId: $p
    }
    + (if $prj != "" then {projectId: $prj} else {} end)
    + (if $a != "" then {assigneeAgentId: $a} else {} end)
    + (if $idem != "" then {idempotencyKey: $idem} else {} end)')"
  resp="$(afk_pc_curl POST "$api_url/api/companies/$company_id/issues" "$key" "" "$payload")"
  code="${resp%%$'\n'*}"
  body="${resp#*$'\n'}"
  if [[ "$code" == 2?? ]]; then
    printf '%s\n' "$body"
  fi
  return 0
}

# afk_pch_register_commit_work_product <api_url> <key> <run_id> <issue_id> <project_id> <commit_sha> <branch> <title> <summary> <status> <review_state>
# Registers or updates a first-class git commit Work Product on the Paperclip issue
# (`POST /api/issues/{id}/work-products`).
afk_pch_register_commit_work_product() {
  local api_url="${1:-}" key="${2:-}" run_id="${3:-}" issue_id="${4:-}"
  local project_id="${5:-}" commit_sha="${6:-}" branch="${7:-}" title="${8:-}"
  local summary="${9:-}" status="${10:-merged}" review_state="${11:-approved}"
  [[ -n "$api_url" && -n "$key" && -n "$issue_id" && -n "$commit_sha" ]] && _afk_pch_is_uuid "$issue_id" || return 0

  local v_proj=""
  _afk_pch_is_uuid "$project_id" && v_proj="$project_id"
  local payload resp code body
  payload="$(jq -cn \
    --arg prj "$v_proj" \
    --arg sha "${commit_sha:0:120}" \
    --arg br "$branch" \
    --arg ttl "${title:0:500}" \
    --arg sum "${summary:0:4000}" \
    --arg st "$status" \
    --arg rs "$review_state" \
    '{
      type: "commit",
      provider: "git",
      externalId: $sha,
      title: $ttl,
      status: $st,
      reviewState: $rs,
      isPrimary: true,
      summary: $sum,
      metadata: {
        branch: $br,
        commitSha: $sha
      }
    } + (if $prj != "" then {projectId: $prj} else {} end)')"
  resp="$(afk_pc_curl POST "$api_url/api/issues/$issue_id/work-products" "$key" "$run_id" "$payload")"
  code="${resp%%$'\n'*}"
  body="${resp#*$'\n'}"
  if [[ "$code" == 2?? ]]; then
    jq -c '.' <<<"$body" 2>/dev/null || true
  fi
  return 0
}
