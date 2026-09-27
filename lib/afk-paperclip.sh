#!/usr/bin/env bash
# afk-paperclip.sh — `agent-flow-kit paperclip-poll`: the claim-side pass.
#
# One deterministic poller per host holds every project agent's Paperclip key
# and is the only thing that writes to Paperclip. See docs/PAPERCLIP.md.
#
# Every Paperclip HTTP call goes through afk_pc_curl, which owns the auth
# header: the key is passed to curl on a file descriptor
# (`-H @<(printf ...)`), never as a literal argument, never exported, never
# logged. This file is SOURCED, never executed.

if [[ -n "${AFK_PAPERCLIP_SOURCED:-}" ]]; then
  return 0
fi
AFK_PAPERCLIP_SOURCED=1

AFK_PC_UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
AFK_PC_OP="${AFK_OP_BIN:-op}"
AFK_PC_CURL="${AFK_CURL_BIN:-curl}"

afk_pc_uuid_ok() { [[ "$1" =~ $AFK_PC_UUID_RE ]]; }

afk_pc_config_path() {
  printf '%s' "${AFK_PAPERCLIP_CONFIG:-${HOME:-}/.config/agent-flow-kit/paperclip.json}"
}

# --- the one HTTP entry point (AC-2, quality bar) ---------------------------
# afk_pc_curl <method> <url> <key> <run-id-or-empty> [<body-json>]
# stdout: "<3-digit status, or empty on a transport failure>\n<response body>".
# This is deliberately NOT communicated through a global variable: every call
# site captures this function's output via command substitution, which forks
# a subshell in bash, so a global assigned *inside* afk_pc_curl never reaches
# the caller. Callers split the one line of output themselves with parameter
# expansion (no subshell) to recover the status and the body. Never inline:
# the Authorization header (and the request body, which can carry no secret
# but follows the same mechanism) is read by curl from a file descriptor this
# function opens itself with `exec {fd}<`, not from `@<(...)` written inline
# in the args array. A process substitution built in one statement and only
# consumed in a later one is not guaranteed to still be open by the time it's
# used — this bites across a command-substitution boundary in particular,
# which is exactly how every caller invokes this function. `exec {fd}<` opens
# a descriptor that lives until this function closes it, which survives that
# boundary.
afk_pc_curl() {
  local method="$1" url="$2" key="$3" run="$4" body="${5:-}"
  local -a args=(-sS --connect-timeout 5 --max-time 20 -X "$method" -w '%{http_code}')
  local hfd bfd
  exec {hfd}< <(printf 'Authorization: Bearer %s' "$key")
  args+=(-H "@/dev/fd/$hfd")
  [[ -n "$run" ]] && args+=(-H "X-Paperclip-Run-Id: $run")
  if [[ -n "$body" ]]; then
    exec {bfd}< <(printf '%s' "$body")
    args+=(-H 'Content-Type: application/json' --data-binary "@/dev/fd/$bfd")
  fi
  local raw rc=0
  raw="$("$AFK_PC_CURL" "${args[@]}" "$url" 2>/dev/null)" || rc=1
  exec {hfd}<&-
  [[ -n "${bfd:-}" ]] && exec {bfd}<&-
  if (( rc != 0 )); then
    printf '\n'
    return 1
  fi
  printf '%s\n%s' "${raw: -3}" "${raw:0:${#raw}-3}"
}

afk_pc_comment() { # <api_url> <issue_id> <key> <run_id> <body>
  local b; b="$(jq -nc --arg b "$5" '{body:$b}')"
  afk_pc_curl POST "$1/api/issues/$2/comments" "$3" "$4" "$b"
}

afk_pc_self_block() { # <api_url> <issue_id> <key> <run_id> <agent_id> <action_text> [<clear_blockers:true|false>]
  local b
  if [[ "${7:-false}" == true ]]; then
    b="$(jq -nc --arg a "$5" --arg t "$6" \
      '{status:"blocked", unblockDescriptor:{owner:{agentId:$a}, action:$t}, blockedByIssueIds:[]}')"
  else
    b="$(jq -nc --arg a "$5" --arg t "$6" \
      '{status:"blocked", unblockDescriptor:{owner:{agentId:$a}, action:$t}}')"
  fi
  afk_pc_curl PATCH "$1/api/issues/$2" "$3" "$4" "$b" >/dev/null
}

afk_pc_create_issue() { # <api_url> <key> <company_id> <title> <assignee> <description> [<idempotency_key>]
  local b idem="${7:-}"
  b="$(jq -nc --arg t "$4" --arg a "$5" --arg d "$6" --arg idem "$idem" \
    '{title:$t, status:"todo", assigneeUserId:$a, description:$d}
     + (if $idem == "" then {} else {idempotencyKey:$idem} end)')"
  afk_pc_curl POST "$1/api/companies/$3/issues" "$2" "" "$b"
}

# afk_pc_strand <api_url> <key> <company_id> <board_user_id> <id> <identifier>
#               <agent_id> <project> <repo_path> <harness>
# AC-5c: mark stranded and, exactly once per issue, open the out-of-band
# recovery issue. Reads and writes the caller's `ledger`/`actions` locals
# directly (dynamic scoping — this must be a direct call, never `$(...)`).
afk_pc_strand() {
  ledger="$(jq -c --arg id "$5" '.issues[$id].state = "stranded"' <<<"$ledger")"
  local already; already="$(jq --arg id "$5" '.stranded_reported | index($id) != null' <<<"$ledger")"
  if [[ "$already" != true ]]; then
    local create_resp create_body newid
    create_resp="$(afk_pc_create_issue "$1" "$2" "$3" "NEEDS HUMAN: resolve recovery on $6" \
      "$4" "Open $6 and set Status to Todo." "afk-recovery-$5")"
    create_body="${create_resp#*$'\n'}"
    newid="$(jq -r '.id // empty' <<<"$create_body")"
    ledger="$(jq -c --arg id "$5" '.stranded_reported += [$id]' <<<"$ledger")"
    [[ -n "$newid" ]] && ledger="$(jq -c --arg id "$5" --arg rid "$newid" '.issues[$id].recovery_issue_id = $rid' <<<"$ledger")"
    afk_pc_notice "$8" "$5" "$6" "$7" "$9" "${10}" stranded
    actions="$(jq -c --arg t "stranded: $6" '. + [$t]' <<<"$actions")"
  fi
}

# --- config (AC-1) -----------------------------------------------------------
# On success: AFK_PC_CFG is a compact JSON document. On failure: AFK_PC_REFUSAL
# is a reason code and no network call has been made.
afk_pc_load_config() {
  local path cfg n i agent_id key_ref project repo_path harness
  local api_url company_id board_user_id host_label maint
  AFK_PC_REFUSAL=""
  path="$(afk_pc_config_path)"
  if [[ ! -r "$path" ]]; then AFK_PC_REFUSAL="PAPERCLIP_NOT_CONFIGURED"; return 1; fi
  cfg="$(jq -c '.' "$path" 2>/dev/null)" || { AFK_PC_REFUSAL="PAPERCLIP_CONFIG_INVALID"; return 1; }

  api_url="$(jq -r '.api_url // empty' <<<"$cfg")"
  company_id="$(jq -r '.company_id // empty' <<<"$cfg")"
  board_user_id="$(jq -r '.board_user_id // empty' <<<"$cfg")"
  host_label="$(jq -r '.host_label // empty' <<<"$cfg")"
  maint="$(jq -r '.maintenance_issue_id // empty' <<<"$cfg")"
  if [[ -z "$api_url" || -z "$company_id" || -z "$board_user_id" || -z "$host_label" ]]; then
    AFK_PC_REFUSAL="PAPERCLIP_CONFIG_INVALID"; return 1
  fi
  if [[ "$board_user_id" == board || "$board_user_id" == local-board ]]; then
    AFK_PC_REFUSAL="PAPERCLIP_ID_INVALID"; return 1
  fi
  if ! afk_pc_uuid_ok "$company_id" || ! afk_pc_uuid_ok "$board_user_id"; then
    AFK_PC_REFUSAL="PAPERCLIP_ID_INVALID"; return 1
  fi
  if [[ -n "$maint" ]] && ! afk_pc_uuid_ok "$maint"; then
    AFK_PC_REFUSAL="PAPERCLIP_ID_INVALID"; return 1
  fi

  n="$(jq '.agents | if type == "array" then length else -1 end' <<<"$cfg")"
  if [[ "$n" -le 0 ]]; then AFK_PC_REFUSAL="PAPERCLIP_CONFIG_INVALID"; return 1; fi

  local -A seen_agents=() seen_repos=()
  for ((i = 0; i < n; i++)); do
    agent_id="$(jq -r ".agents[$i].agent_id // empty" <<<"$cfg")"
    key_ref="$(jq -r ".agents[$i].key_ref // empty" <<<"$cfg")"
    project="$(jq -r ".agents[$i].project // empty" <<<"$cfg")"
    repo_path="$(jq -r ".agents[$i].repo_path // empty" <<<"$cfg")"
    harness="$(jq -r ".agents[$i].harness // empty" <<<"$cfg")"
    if [[ -z "$agent_id" || -z "$key_ref" || -z "$project" || -z "$repo_path" || -z "$harness" ]]; then
      AFK_PC_REFUSAL="PAPERCLIP_CONFIG_INVALID"; return 1
    fi
    if ! afk_pc_uuid_ok "$agent_id"; then AFK_PC_REFUSAL="PAPERCLIP_ID_INVALID"; return 1; fi
    [[ "$repo_path" == /* ]] || { AFK_PC_REFUSAL="PAPERCLIP_CONFIG_INVALID"; return 1; }
    case "$harness" in claude | codex | opencode) ;; *) AFK_PC_REFUSAL="PAPERCLIP_CONFIG_INVALID"; return 1 ;; esac
    if [[ -n "${seen_agents[$agent_id]:-}" || -n "${seen_repos[$repo_path]:-}" ]]; then
      AFK_PC_REFUSAL="PAPERCLIP_CONFIG_INVALID"; return 1
    fi
    seen_agents[$agent_id]=1; seen_repos[$repo_path]=1
  done

  AFK_PC_CFG="$cfg"
  return 0
}

# --- notices (AC-6) ----------------------------------------------------------
afk_pc_notice() { # <project> <issue_id> <identifier> <agent_id> <repo_path> <harness> <event> [<extra-json>]
  local dir="$AFK_STATE_DIR/paperclip/notices/$1" epoch payload extra="${8:-}"
  [[ -n "$extra" ]] || extra='{}'
  afk_state_dir_ensure "$dir"
  epoch="$(date +%s)"
  payload="$(jq -nc --arg id "$2" --arg identifier "$3" --arg agent "$4" --arg project "$1" \
    --arg repo "$5" --arg harness "$6" --arg event "$7" \
    --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson extra "$extra" \
    '{id: $id, identifier: $identifier, agent_id: $agent, project: $project,
      repo_path: $repo, harness: $harness, event: $event, time: $time} + $extra')"
  afk_state_file_write "$dir/$epoch.$2.$7.json" "$payload"
}

afk_pc_brief() { # <project> <issue_id> <updated_at> <title> <description>
  local dir="$AFK_STATE_DIR/paperclip/notices/$1" digits
  afk_state_dir_ensure "$dir"
  digits="$(tr -cd '0-9' <<<"$3")"
  afk_state_file_write "$dir/brief.$2.$digits.md" "# $4"$'\n\n'"$5"
}

afk_pc_reply() { # <project> <comment_id> <body>
  local dir="$AFK_STATE_DIR/paperclip/notices/$1"
  afk_state_dir_ensure "$dir"
  afk_state_file_write "$dir/reply.$2.md" "$3"
}

# --- action text (AC-7) ------------------------------------------------------
afk_pc_action_text() { # <pause-kind: none|stopped|maintenance> <queued-behind-or-empty> <status-file> <prev-action-or-empty>
  case "$1" in
    stopped) printf 'Stopped'; return 0 ;;
    maintenance) printf 'paused for Paperclip maintenance'; return 0 ;;
  esac
  [[ -n "$2" ]] && { printf 'queued behind %s' "$2"; return 0; }
  if [[ -r "$3" ]]; then
    local t; t="$(jq -r '.text // empty' "$3" 2>/dev/null)"
    [[ -n "$t" ]] && { printf '%s' "$t"; return 0; }
  fi
  if [[ -n "$4" && "$4" != null ]]; then printf '%s' "$4"; return 0; fi
  printf 'AFK host is working on this'
}

# --- the Josh test (AC-8) ----------------------------------------------------
# 0: a Josh comment. 1: not Josh. 2: unverifiable (no authorAgentId key at all).
afk_pc_is_josh_comment() { # <comment-json> <board_user_id>
  local author has_key agent_val
  has_key="$(jq 'has("authorAgentId")' <<<"$1")"
  [[ "$has_key" == "true" ]] || return 2
  author="$(jq -r '.authorUserId // empty' <<<"$1")"
  agent_val="$(jq -r '.authorAgentId' <<<"$1")"
  [[ "$author" == "$2" && "$agent_val" == null ]] && return 0
  return 1
}

# --- the pass (AC-3..AC-10) ---------------------------------------------------
afk_cmd_paperclip_poll() { # <json_mode>
  local json_mode="$1"
  if ! afk_pc_load_config; then
    afk_pc_emit_refusal "$AFK_PC_REFUSAL" "$json_mode"
    return 1
  fi

  local api_url company_id board_user_id host_label maint
  api_url="$(jq -r '.api_url' <<<"$AFK_PC_CFG")"
  company_id="$(jq -r '.company_id' <<<"$AFK_PC_CFG")"
  board_user_id="$(jq -r '.board_user_id' <<<"$AFK_PC_CFG")"
  host_label="$(jq -r '.host_label' <<<"$AFK_PC_CFG")"
  maint="$(jq -r '.maintenance_issue_id // empty' <<<"$AFK_PC_CFG")"

  local pc_dir="$AFK_STATE_DIR/paperclip"
  afk_state_dir_ensure "$pc_dir"
  local lockdir="$pc_dir/.lock"
  if ! mkdir "$lockdir" 2>/dev/null; then
    afk_pc_emit_refusal "PAPERCLIP_POLL_BUSY" "$json_mode"
    return 0
  fi
  # shellcheck disable=SC2064
  trap "rmdir '$lockdir' 2>/dev/null" EXIT

  local ledger_path="$pc_dir/ledger.json" ledger=""
  if [[ -r "$ledger_path" ]]; then
    ledger="$(jq -c '.' "$ledger_path" 2>/dev/null)" || ledger=""
  fi
  [[ -n "$ledger" ]] || ledger='{"issues":{},"stranded_reported":[],"drain_tampered_reported":false,"last_successful_pass":null}'

  local stop_flag="${HOME:-}/.config/agent-flow-kit/paperclip/stop"
  local pause_kind=none author_unverifiable_reported=false
  [[ -e "$stop_flag" ]] && pause_kind=stopped

  local pause_computed=false any_agent_ok=false agents_json="[]" n i
  n="$(jq '.agents | length' <<<"$AFK_PC_CFG")"

  for ((i = 0; i < n; i++)); do
    local agent_id key_ref project repo_path harness max_active key result actions="[]"
    agent_id="$(jq -r ".agents[$i].agent_id" <<<"$AFK_PC_CFG")"
    key_ref="$(jq -r ".agents[$i].key_ref" <<<"$AFK_PC_CFG")"
    project="$(jq -r ".agents[$i].project" <<<"$AFK_PC_CFG")"
    repo_path="$(jq -r ".agents[$i].repo_path" <<<"$AFK_PC_CFG")"
    harness="$(jq -r ".agents[$i].harness" <<<"$AFK_PC_CFG")"
    max_active="$(jq -r ".agents[$i].max_active_issues // 1" <<<"$AFK_PC_CFG")"

    key="$("$AFK_PC_OP" read "$key_ref" 2>/dev/null)"
    if [[ -z "$key" ]]; then
      agents_json="$(jq -c --arg a "$agent_id" '. + [{agent_id:$a, result:"PAPERCLIP_VAULT_UNAVAILABLE", actions:[]}]' <<<"$agents_json")"
      continue
    fi

    local me_resp me_body me_http
    me_resp="$(afk_pc_curl GET "$api_url/api/agents/me" "$key" "")"
    me_http="${me_resp%%$'\n'*}"; me_body="${me_resp#*$'\n'}"
    if [[ -z "$me_http" || "$me_http" == 5* ]]; then
      agents_json="$(jq -c --arg a "$agent_id" '. + [{agent_id:$a, result:"unreachable", actions:[]}]' <<<"$agents_json")"
      key=""
      continue
    fi
    if [[ "$me_http" == 401 || "$me_http" == 403 ]]; then
      agents_json="$(jq -c --arg a "$agent_id" '. + [{agent_id:$a, result:"PAPERCLIP_KEY_UNAUTHORIZED", actions:[]}]' <<<"$agents_json")"
      key=""
      continue
    fi
    if [[ "$me_http" != 200 ]]; then
      agents_json="$(jq -c --arg a "$agent_id" '. + [{agent_id:$a, result:"unreachable", actions:[]}]' <<<"$agents_json")"
      key=""
      continue
    fi
    local me_id; me_id="$(jq -r '.id // empty' <<<"$me_body")"
    if [[ "$me_id" != "$agent_id" ]]; then
      agents_json="$(jq -c --arg a "$agent_id" '. + [{agent_id:$a, result:"PAPERCLIP_KEY_AGENT_MISMATCH", actions:[]}]' <<<"$agents_json")"
      key=""
      continue
    fi

    if [[ "$pause_computed" == false ]]; then
      pause_computed=true
      afk_pc_compute_pause "$api_url" "$key" "$maint" "$board_user_id" "$company_id" "$pause_kind"
      pause_kind="$AFK_PC_PAUSE_KIND"
    fi

    any_agent_ok=true
    result=completed
    local inbox_resp inbox_http inbox_body ids used_slots working_id status_file_dir
    inbox_resp="$(afk_pc_curl GET "$api_url/api/agents/me/inbox-lite" "$key" "")"
    inbox_http="${inbox_resp%%$'\n'*}"; inbox_body="${inbox_resp#*$'\n'}"
    if [[ -z "$inbox_http" || "$inbox_http" != 200 ]]; then
      agents_json="$(jq -c --arg a "$agent_id" '. + [{agent_id:$a, result:"unreachable", actions:[]}]' <<<"$agents_json")"
      key=""
      continue
    fi
    mapfile -t ids < <(jq -r '.[].id' <<<"$inbox_body")
    used_slots="$(jq --arg a "$agent_id" '[.issues[] | select(.agent_id == $a and .state == "working")] | length' <<<"$ledger")"
    working_id="$(jq -r --arg a "$agent_id" '[.issues[] | select(.agent_id == $a and .state == "working")][0].identifier // empty' <<<"$ledger")"
    status_file_dir="$AFK_STATE_DIR/paperclip/status"

    # AC-5d: ledger issues for this agent no longer present in the inbox.
    local closed_ids; mapfile -t closed_ids < <(jq -r --arg a "$agent_id" \
      --argjson present "$(printf '%s\n' "${ids[@]:-}" | jq -R -s -c 'split("\n") | map(select(length > 0))')" \
      '.issues | to_entries[] | select(.value.agent_id == $a and (.value.state != "closed") and ([.key] - $present | length) == 1) | .key' \
      <<<"$ledger")
    local cid
    for cid in "${closed_ids[@]:-}"; do
      [[ -n "$cid" ]] || continue
      local cidentifier; cidentifier="$(jq -r --arg id "$cid" '.issues[$id].identifier // empty' <<<"$ledger")"
      ledger="$(jq -c --arg id "$cid" '.issues[$id].state = "closed"' <<<"$ledger")"
      afk_pc_notice "$project" "$cid" "$cidentifier" "$agent_id" "$repo_path" "$harness" stopped
      actions="$(jq -c --arg t "stopped: $cidentifier" '. + [$t]' <<<"$actions")"
    done

    local id
    for id in "${ids[@]:-}"; do
      [[ -n "$id" ]] || continue
      afk_pc_uuid_ok "$id" || continue
      local detail_resp detail dhttp
      detail_resp="$(afk_pc_curl GET "$api_url/api/issues/$id" "$key" "")"
      dhttp="${detail_resp%%$'\n'*}"; detail="${detail_resp#*$'\n'}"
      [[ "$dhttp" == 200 ]] || continue
      local status identifier title desc updated owner_agent owner_user prev
      status="$(jq -r '.status' <<<"$detail")"
      identifier="$(jq -r '.identifier' <<<"$detail")"
      title="$(jq -r '.title' <<<"$detail")"
      desc="$(jq -r '.description' <<<"$detail")"
      updated="$(jq -r '.updatedAt' <<<"$detail")"
      owner_agent="$(jq -r '.unblockDescriptor.owner.agentId // empty' <<<"$detail")"
      owner_user="$(jq -r '.unblockDescriptor.owner.userId // empty' <<<"$detail")"
      prev="$(jq -c --arg id "$id" '.issues[$id] // empty' <<<"$ledger")"

      case "$status" in
        in_progress)
          local run_resp run_body run_id action new_state was_stranded
          run_resp="$(afk_pc_curl GET "$api_url/api/issues/$id/active-run" "$key" "")"
          run_body="${run_resp#*$'\n'}"
          run_id="$(jq -r '.id // empty' <<<"$run_body")"
          was_stranded="false"
          [[ -n "$prev" && "$(jq -r '.state' <<<"$prev")" == stranded ]] && was_stranded="true"

          if [[ "$pause_kind" != none ]]; then
            action="$(afk_pc_action_text "$pause_kind" "" "" "")"
            new_state="working"
            afk_pc_self_block "$api_url" "$id" "$key" "$run_id" "$agent_id" "$action"
            actions="$(jq -c --arg t "paused: $identifier" '. + [$t]' <<<"$actions")"
          elif [[ -z "$prev" ]]; then
            afk_pc_comment "$api_url" "$id" "$key" "$run_id" "claimed by AFK PM ($host_label)" >/dev/null
            afk_pc_notice "$project" "$id" "$identifier" "$agent_id" "$repo_path" "$harness" claimed
            afk_pc_brief "$project" "$id" "$updated" "$title" "$desc"
            if (( used_slots >= max_active )); then
              new_state="queued"
              action="$(afk_pc_action_text none "$working_id" "" "")"
            else
              new_state="working"
              action="$(afk_pc_action_text none "" "" "")"
              used_slots=$((used_slots + 1))
              working_id="$identifier"
            fi
            afk_pc_self_block "$api_url" "$id" "$key" "$run_id" "$agent_id" "$action"
            actions="$(jq -c --arg t "claimed: $identifier" '. + [$t]' <<<"$actions")"
          else
            # AC-5a: an existing ledger entry plus a live in_progress status
            # is a Paperclip-initiated wake (issue_children_completed,
            # issue_blockers_resolved, approval_approved, or any other
            # reason) — Paperclip auto-started this run, we never requested
            # it. Handle exactly like a report cycle: one short
            # acknowledgment comment naming the reason, then re-self-block.
            local prior_state queued_behind="" wake_reason clear_blockers=false
            prior_state="$(jq -r '.state' <<<"$prev")"
            wake_reason="$(jq -r '.contextSnapshot.wakeReason // .contextSnapshot.reason // empty' <<<"$run_body")"
            afk_pc_comment "$api_url" "$id" "$key" "$run_id" \
              "AFK host acknowledged: ${wake_reason:-a Paperclip wake}" >/dev/null
            if [[ "$prior_state" == working ]]; then
              new_state="working"
            elif (( used_slots >= max_active )); then
              new_state="queued"
              queued_behind="$working_id"
            else
              new_state="working"
              used_slots=$((used_slots + 1))
              working_id="$identifier"
            fi
            action="$(afk_pc_action_text none "$queued_behind" "$status_file_dir/$id.json" "$(jq -r '.action_text' <<<"$prev")")"
            # AC-5a: an issue_blockers_resolved wake must clear
            # blockedByIssueIds on the re-block, or Paperclip reads it as
            # "blockers restored" and sends a second wake into recovery.
            [[ "$wake_reason" == issue_blockers_resolved ]] && clear_blockers=true
            afk_pc_self_block "$api_url" "$id" "$key" "$run_id" "$agent_id" "$action" "$clear_blockers"
            actions="$(jq -c --arg t "wake acknowledged: $identifier" '. + [$t]' <<<"$actions")"
          fi

          local since; since="$(jq -r 'if .since then .since else empty end' <<<"$prev")"
          [[ -n "$since" ]] || since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          ledger="$(jq -c --arg id "$id" --arg a "$agent_id" --arg p "$project" --arg ident "$identifier" \
            --arg st "$new_state" --arg since "$since" --arg act "$action" \
            '.issues[$id] = ((.issues[$id] // {}) + {agent_id:$a, project:$p, identifier:$ident, state:$st, since:$since, action_text:$act})' \
            <<<"$ledger")"

          if [[ "$was_stranded" == true ]]; then
            local recid; recid="$(jq -r --arg id "$id" '.issues[$id].recovery_issue_id // empty' <<<"$ledger")"
            [[ -n "$recid" ]] && afk_pc_curl PATCH "$api_url/api/issues/$recid" "$key" "" '{"status":"done"}' >/dev/null
          fi
          ;;
        blocked)
          # AC-5 (V2, amended by prox-ops live test): unblockDescriptor is
          # unreliable (null in one case, a stale self-block text in
          # another) and is never used to decide stranding. The plain issue
          # detail already fetched above (never /recovery-actions, which can
          # resolve recoveries as a side effect) carries the authority
          # instead: an issue is under board recovery iff
          # activeRecoveryAction != null && .status == "active" &&
          # .ownerType == "board". `kind`/`cause` are not matched, and
          # successfulRunHandoff.state is not read (it persists after
          # resolution). This is checked first and, when true, strands the
          # issue whatever the descriptor says, provided the ledger holds it.
          local rec_status rec_owner recovery_active=false
          rec_status="$(jq -r '.activeRecoveryAction.status // empty' <<<"$detail")"
          rec_owner="$(jq -r '.activeRecoveryAction.ownerType // empty' <<<"$detail")"
          [[ "$rec_status" == active && "$rec_owner" == board ]] && recovery_active=true

          if [[ "$recovery_active" == true ]]; then
            if [[ -n "$prev" ]]; then
              afk_pc_strand "$api_url" "$key" "$company_id" "$board_user_id" "$id" "$identifier" \
                "$agent_id" "$project" "$repo_path" "$harness"
            fi
          elif [[ -n "$owner_agent" && "$owner_agent" == "$agent_id" ]]; then
            local prev_state qid comments_resp comments_body
            prev_state="$(jq -r '.state // empty' <<<"$prev")"
            qid="$(jq -r '.question_id // empty' <<<"$prev")"
            local since; since="$(jq -r '.since // empty' <<<"$prev")"

            comments_resp="$(afk_pc_curl GET "$api_url/api/issues/$id/comments" "$key" "")"
            comments_body="${comments_resp#*$'\n'}"
            local newest_since="$since" c ccreated
            while IFS= read -r c; do
              [[ -n "$c" ]] || continue
              ccreated="$(jq -r '.createdAt // empty' <<<"$c")"
              [[ -z "$since" || "$ccreated" > "$since" ]] || continue
              afk_pc_is_josh_comment "$c" "$board_user_id"; local rc=$?
              if (( rc == 2 )); then
                if [[ "$author_unverifiable_reported" == false ]]; then
                  author_unverifiable_reported=true
                  actions="$(jq -c '. + ["PAPERCLIP_AUTHOR_UNVERIFIABLE"]' <<<"$actions")"
                fi
              elif (( rc == 0 )); then
                local cid2; cid2="$(jq -r '.id' <<<"$c")"
                afk_pc_notice "$project" "$id" "$identifier" "$agent_id" "$repo_path" "$harness" human_commented \
                  "$(jq -nc --arg cid "$cid2" --arg ca "$ccreated" --arg q "${qid:-}" \
                    'if $q == "" then {comment_id:$cid, created_at:$ca, open_question_id:null} else {comment_id:$cid, created_at:$ca, open_question_id:$q} end')"
                afk_pc_reply "$project" "$cid2" "Reply to $identifier"
                actions="$(jq -c --arg t "human_commented: $identifier" '. + [$t]' <<<"$actions")"
              fi
              [[ -z "$newest_since" || "$ccreated" > "$newest_since" ]] && newest_since="$ccreated"
            done < <(jq -c '.[]' <<<"$comments_body")

            local final_state="$prev_state"
            if [[ "$prev_state" == queued && "$used_slots" -lt "$max_active" ]]; then
              final_state="working"
              used_slots=$((used_slots + 1))
              working_id="$identifier"
              afk_pc_notice "$project" "$id" "$identifier" "$agent_id" "$repo_path" "$harness" promoted
              actions="$(jq -c --arg t "promoted: $identifier" '. + [$t]' <<<"$actions")"
            fi
            ledger="$(jq -c --arg id "$id" --arg st "$final_state" --arg since "${newest_since:-$since}" \
              '.issues[$id].state = $st | .issues[$id].since = $since' <<<"$ledger")"
          elif [[ -n "$owner_user" && "$owner_user" == "$board_user_id" ]]; then
            ledger="$(jq -c --arg id "$id" '.issues[$id].state = "held_by_board"' <<<"$ledger")"
          else
            local prev_state; prev_state="$(jq -r '.state // empty' <<<"$prev")"
            if [[ -n "$prev" && ( "$prev_state" == working || "$prev_state" == queued || "$prev_state" == waiting_human ) ]]; then
              afk_pc_strand "$api_url" "$key" "$company_id" "$board_user_id" "$id" "$identifier" \
                "$agent_id" "$project" "$repo_path" "$harness"
            fi
          fi
          ;;
        cancelled | done)
          if [[ -n "$prev" ]]; then
            ledger="$(jq -c --arg id "$id" '.issues[$id].state = "closed"' <<<"$ledger")"
            afk_pc_notice "$project" "$id" "$identifier" "$agent_id" "$repo_path" "$harness" stopped
            actions="$(jq -c --arg t "stopped: $identifier" '. + [$t]' <<<"$actions")"
          fi
          ;;
        *) : ;; # todo (AC-5e): leave it alone.
      esac
    done

    key=""
    agents_json="$(jq -c --arg a "$agent_id" --arg r "$result" --argjson acts "$actions" \
      '. + [{agent_id:$a, result:$r, actions:$acts}]' <<<"$agents_json")"
  done

  # AC-3: exit non-zero when nothing completed, and leave the ledger
  # untouched. But the per-agent reasons (vault-unavailable, key mismatch, an
  # individual agent unreachable, ...) are never discarded in favor of one
  # blanket message — agents_json already carries them, so it's still
  # reported below rather than swapped for afk_pc_emit_refusal.
  local ledger_counts="{}" overall="completed"
  if [[ "$any_agent_ok" == false ]]; then
    overall="PAPERCLIP_UNREACHABLE"
  else
    ledger="$(jq -c --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.last_successful_pass = $t' <<<"$ledger")"
    afk_state_file_write "$ledger_path" "$ledger"
    ledger_counts="$(jq -c '[.issues[].state] | reduce .[] as $s ({}; .[$s] = (.[$s] // 0) + 1)' <<<"$ledger")"
    [[ "$pause_kind" != none ]] && overall="PAPERCLIP_PAUSED"
  fi

  if [[ "$json_mode" == true ]]; then
    jq -nc --arg r "$overall" --argjson agents "$agents_json" --argjson lc "$ledger_counts" \
      '{result: $r, agents: $agents, ledger_counts: $lc}'
  else
    while IFS= read -r line; do printf '%s\n' "$line"; done < <(
      jq -r '.agents[] | "\(.agent_id): \(.result)", (.actions[]? | "  " + .)' \
        <<<"$(jq -nc --argjson agents "$agents_json" '{agents:$agents}')"
    )
    printf 'paperclip-poll: %s\n' "$overall"
  fi
  [[ "$any_agent_ok" == true ]] || return 1
  return 0
}

# afk_pc_compute_pause <api_url> <key> <maintenance_issue_id> <board_user_id> <company_id> <initial-pause-kind>
# Sets AFK_PC_PAUSE_KIND (none|stopped|maintenance). Computed once per pass
# with the first agent to present a usable key (AC-9).
afk_pc_compute_pause() {
  AFK_PC_PAUSE_KIND="$6"
  if [[ "$AFK_PC_PAUSE_KIND" == stopped ]]; then return 0; fi
  [[ -n "$3" ]] || { AFK_PC_PAUSE_KIND=none; return 0; }
  local resp body http
  resp="$(afk_pc_curl GET "$1/api/issues/$3" "$2" "")"
  http="${resp%%$'\n'*}"; body="${resp#*$'\n'}"
  if [[ -z "$http" || "$http" != 200 ]]; then
    AFK_PC_PAUSE_KIND=maintenance
    actions="$(jq -c '. + ["PAPERCLIP_DRAIN_UNREADABLE"]' <<<"$actions")"
    return 0
  fi
  local status assignee assignee_agent
  status="$(jq -r '.status // empty' <<<"$body")"
  if [[ "$status" != in_progress ]]; then AFK_PC_PAUSE_KIND=none; return 0; fi
  assignee="$(jq -r '.assigneeUserId // empty' <<<"$body")"
  assignee_agent="$(jq -r '.assigneeAgentId // empty' <<<"$body")"
  local tampered=false
  if [[ "$assignee" == "$4" && -z "$assignee_agent" ]]; then
    # AC-9: the drain also counts only while the last status change came from
    # a board actor. GET .../activity needs no run.
    local act_resp act_body act_http actor_type actor_id
    act_resp="$(afk_pc_curl GET "$1/api/issues/$3/activity" "$2" "")"
    act_http="${act_resp%%$'\n'*}"; act_body="${act_resp#*$'\n'}"
    if [[ "$act_http" == 200 ]]; then
      actor_type="$(jq -r '[.[] | select(.details.changes.status != null)] | sort_by(.createdAt) | last | .actorType // empty' <<<"$act_body")"
      actor_id="$(jq -r '[.[] | select(.details.changes.status != null)] | sort_by(.createdAt) | last | .actorId // empty' <<<"$act_body")"
      if [[ "$actor_type" == user && "$actor_id" == "$4" ]]; then
        AFK_PC_PAUSE_KIND=maintenance
      else
        tampered=true
      fi
    else
      tampered=true
    fi
  else
    tampered=true
  fi
  if [[ "$tampered" == true ]]; then
    AFK_PC_PAUSE_KIND=none
    local reported; reported="$(jq -r '.drain_tampered_reported // false' <<<"$ledger" 2>/dev/null)"
    if [[ "$reported" != true ]]; then
      afk_pc_create_issue "$1" "$2" "$5" "NEEDS HUMAN: drain issue tampered" "$4" \
        "The maintenance issue's assignee is not the board; drain is being ignored." >/dev/null
      ledger="$(jq -c '.drain_tampered_reported = true' <<<"$ledger")"
    fi
    actions="$(jq -c '. + ["PAPERCLIP_DRAIN_TAMPERED"]' <<<"$actions")"
  fi
}

afk_pc_emit_refusal() { # <reason> <json_mode>
  if [[ "$2" == true ]]; then
    jq -nc --arg r "$1" '{result: $r, agents: [], ledger_counts: {}}'
  else
    printf 'agent-flow-kit paperclip-poll: %s\n' "$1"
  fi
}
