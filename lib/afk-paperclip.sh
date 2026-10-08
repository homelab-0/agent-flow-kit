#!/usr/bin/env bash
# afk-paperclip.sh — `agent-flow-kit paperclip-poll`: the claim-side pass.
#
# One deterministic poller per host holds the host's one Paperclip agent key
# (AD-23) and is the only thing that writes to Paperclip. The issue's
# projectId picks the repo through the host's projects[] table. See
# docs/PAPERCLIP.md (§Config, §Projects).
#
# Every Paperclip HTTP call goes through afk_pc_curl, which owns the auth
# header: the key is passed to curl on a file descriptor
# (`-H @<(printf ...)`), never as a literal argument, never exported, never
# logged. This file is SOURCED, never executed.

if [[ -n "${AFK_PAPERCLIP_SOURCED:-}" ]]; then
  return 0
fi
AFK_PAPERCLIP_SOURCED=1

declare -F afk_orca_bin >/dev/null 2>&1 || . "$(dirname -- "${BASH_SOURCE[0]}")/afk-orca.sh"

AFK_PC_UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
# board_user_id isn't a UUID for real Paperclip accounts (Better-Auth style
# ids, e.g. "emXp8Svi8ncWyL1EORTkRNQYjFjCdQon"). A UUID still matches this.
AFK_PC_USER_ID_RE='^[A-Za-z0-9_-]{16,64}$'
AFK_PC_OP="${AFK_OP_BIN:-op}"
AFK_PC_CURL="${AFK_CURL_BIN:-curl}"

afk_pc_uuid_ok() { [[ "$1" =~ $AFK_PC_UUID_RE ]]; }
afk_pc_user_id_ok() { [[ "$1" =~ $AFK_PC_USER_ID_RE ]]; }
# A slug names every path, notice directory, intent file and terminal title
# (AD-23). The kit's own directories under notices/ are never a slug.
afk_pc_slug_ok() {
  [[ "$1" =~ ^[a-z0-9-]{1,40}$ && "$1" != claimed && "$1" != settled && "$1" != unreturned ]]
}

afk_pc_config_path() {
  printf '%s' "${AFK_PAPERCLIP_CONFIG:-${HOME:-}/.config/agent-flow-kit/paperclip.json}"
}

# --- the host key read (docs/PAPERCLIP.md §How the poller reads the key) -----
# afk_pc_op_env_file -- host.op_env_file, else $AFK_OP_ENV_FILE, else
# $HOME/.op-agent-env.
afk_pc_op_env_file() {
  local f=""
  [[ -n "${AFK_PC_CFG:-}" ]] && f="$(jq -r '.host.op_env_file // empty' <<<"$AFK_PC_CFG" 2>/dev/null)"
  printf '%s' "${f:-${AFK_OP_ENV_FILE:-${HOME:-}/.op-agent-env}}"
}

# afk_pc_read_key <key_ref> -- prints the host key. Every host-key read goes
# through here. With no OP_SERVICE_ACCOUNT_TOKEN in the environment, the op
# env file is sourced in a subshell for this one `op read`, so the token never
# enters this process's environment or reaches any other child. The file is
# opened once, and owner, mode and type are checked on that open file before
# it is sourced from it, so a path swapped after the check is never read.
# Returns 1 for PAPERCLIP_VAULT_UNAVAILABLE, 2 for PAPERCLIP_OP_ENV_UNSAFE.
afk_pc_read_key() {
  local -; set +x
  local ref="$1" file meta key afk_pc_fd
  if [[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
    key="$("$AFK_PC_OP" read "$ref" 2>/dev/null)"
  else
    file="$(afk_pc_op_env_file)"
    [[ -f "$file" && -r "$file" ]] || return 1
    { exec {afk_pc_fd}<"$file"; } 2>/dev/null || return 1
    meta="$(stat -L -c '%a %u' -- "/dev/fd/$afk_pc_fd" 2>/dev/null || stat -L -f '%Lp %u' -- "/dev/fd/$afk_pc_fd" 2>/dev/null)"
    if [[ ! -f "/dev/fd/$afk_pc_fd" || ! "$meta" =~ ^([0-7]+)\ ([0-9]+)$ ]] || (( 8#${BASH_REMATCH[1]} & 8#077 )) ||
       [[ "${BASH_REMATCH[2]}" != "$(id -u)" ]]; then
      exec {afk_pc_fd}<&-
      printf '%s\n' "agent-flow-kit: PAPERCLIP_OP_ENV_UNSAFE: $file must be owned by you and mode 600 or stricter; not sourced" >&2
      return 2
    fi
    # shellcheck source=/dev/null
    key="$(set -a; . "/dev/fd/$afk_pc_fd" >/dev/null 2>&1; set +a; "$AFK_PC_OP" read "$ref" 2>/dev/null {afk_pc_fd}<&-)"
    exec {afk_pc_fd}<&-
  fi
  [[ -n "$key" ]] || return 1
  printf '%s\n' "$key"
}

# afk_pc_key_code <rc> -- the refusal code for an afk_pc_read_key status.
afk_pc_key_code() {
  case "$1" in 0) ;; 2) printf PAPERCLIP_OP_ENV_UNSAFE ;; *) printf PAPERCLIP_VAULT_UNAVAILABLE ;; esac
}

# afk_pc_unit_key_check -- reads the host key the way the systemd unit would.
# The unit inherits the user manager's environment, so the check starts from
# `env -i` with HOME and takes PATH and the key-source variables (OP_*,
# AFK_OP_ENV_FILE, AFK_OP_BIN) from `systemctl --user show-environment`. They
# reach the child on fd 3, never on a command line. A token or override that
# only the calling shell carries does not count. Prints nothing when the read
# works, else the refusal code. Needs AFK_PC_CFG; the key goes to /dev/null.
afk_pc_unit_key_check() {
  local lib orca_lib code bin
  lib="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/afk-paperclip.sh"
  orca_lib="$(dirname -- "$lib")/afk-orca.sh"
  # The installed unit receives this exact absolute path. Verify it again in
  # the manager's environment: a usable interactive shell is not sufficient.
  bin="$(afk_orca_bin 2>/dev/null)" || { printf ORCA_CLI_NOT_RESOLVED; return 0; }
  # shellcheck disable=SC2016
  code="$(env -i HOME="${HOME:-}" PATH="${PATH:-/usr/bin:/bin}" AFK_PC_CFG="$AFK_PC_CFG" AFK_ORCA_BIN="$bin" "${BASH:-bash}" -c '
      while IFS= read -r l; do
        [[ "$l" =~ ^(PATH|OP_[A-Za-z0-9_]+|AFK_OP_ENV_FILE|AFK_OP_BIN)= ]] && export "$l"
      done <&3
      exec 3<&-
      . "$1" || exit 1; afk_pc_read_key "$3" >/dev/null 2>&1
      key_rc=$?; if (( key_rc != 0 )); then afk_pc_key_code "$key_rc"; exit 0; fi
      . "$2" || exit 1
      afk_orca_bin >/dev/null || printf ORCA_CLI_NOT_RESOLVED' \
    _ "$lib" "$orca_lib" "$(jq -r '.host.key_ref' <<<"$AFK_PC_CFG")" \
    3< <(systemctl --user show-environment 2>/dev/null </dev/null) 2>/dev/null)" || code=PAPERCLIP_VAULT_UNAVAILABLE
  printf '%s' "$code"
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
  local -; set +x # never trace the key, whatever the caller's options
  local method="$1" url="$2" key="$3" run="$4" body="${5:-}"
  local -a args=(-sS --connect-timeout 5 --max-time 20 --proto '=https' -X "$method" -w '%{http_code}')
  local hfd="" bfd
  # An empty key is an unauthenticated call, allowed for GET /api/health
  # only. Any other endpoint with no key is refused here, before a request
  # is made, as a transport failure: a caller that lost its key can never
  # fall through to an unauthenticated read or write.
  if [[ -z "$key" ]]; then
    if [[ "$method" != GET || "$url" != */api/health ]]; then
      printf '\n'
      return 1
    fi
  else
    exec {hfd}< <(printf 'Authorization: Bearer %s' "$key")
    args+=(-H "@/dev/fd/$hfd")
  fi
  [[ -n "$run" ]] && args+=(-H "X-Paperclip-Run-Id: $run")
  if [[ -n "$body" ]]; then
    exec {bfd}< <(printf '%s' "$body")
    args+=(-H 'Content-Type: application/json' --data-binary "@/dev/fd/$bfd")
  fi
  local raw rc=0
  raw="$("$AFK_PC_CURL" "${args[@]}" "$url" 2>/dev/null)" || rc=1
  [[ -n "$hfd" ]] && exec {hfd}<&-
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

# afk_pc_health_commit <api_url> <key> -- the one place anything reads the
# deployed commit, used by every interim-approval attestation check (AC-6).
# Prints the commit on stdout and returns 0; any transport failure, non-2xx,
# unparseable body or empty commit is a failure with nothing printed --
# fail-closed, the same way a missing attestation already is.
afk_pc_health_commit() {
  local api_url="$1" key="$2" resp status body commit
  resp="$(afk_pc_curl GET "$api_url/api/health" "$key" "")"
  status="${resp%%$'\n'*}"
  [[ "$status" == 2?? ]] || return 1
  body="${resp#*$'\n'}"
  commit="$(jq -r '.commit // empty' <<<"$body" 2>/dev/null)"
  [[ -n "$commit" ]] || return 1
  printf '%s' "$commit"
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
  local r; r="$(afk_pc_curl PATCH "$1/api/issues/$2" "$3" "$4" "$b")"
  [[ "${r%%$'\n'*}" == 2?? ]] # non-zero unless Paperclip accepted the block
}

afk_pc_create_issue() { # <api_url> <key> <company_id> <title> <assignee> <description> [<idempotency_key>]
  local b idem="${7:-}"
  b="$(jq -nc --arg t "$4" --arg a "$5" --arg d "$6" --arg idem "$idem" \
    '{title:$t, status:"todo", assigneeUserId:$a, description:$d}
     + (if $idem == "" then {} else {idempotencyKey:$idem} end)')"
  afk_pc_curl POST "$1/api/companies/$3/issues" "$2" "" "$b"
}

# afk_pc_strand <api_url> <key> <company_id> <board_user_id> <id> <identifier>
#               <agent_id> <slug> <repo_path> <harness>
# AC-5c: mark stranded and, exactly once per issue, open the out-of-band
# recovery issue. Reads and writes the caller's `ledger`/`actions` locals
# directly (dynamic scoping — this must be a direct call, never `$(...)`).
afk_pc_strand() {
  afk_pc_hold "$5" stranded
  local already; already="$(jq --arg id "$5" '.stranded_reported | index($id) != null' <<<"$ledger")"
  if [[ "$already" != true ]]; then
    local create_resp create_body newid
    create_resp="$(afk_pc_create_issue "$1" "$2" "$3" "NEEDS HUMAN: resolve recovery on $6" \
      "$4" "Open $6 and set Status to Todo." "afk-recovery-$5")"
    # Only a created (or idempotently returned) issue counts as reported; a
    # timeout or error is retried next pass under the same idempotencyKey.
    if [[ "${create_resp%%$'\n'*}" != 2?? ]]; then
      actions="$(jq -c --arg t "stranded (recovery issue not created, retrying next pass): $6" '. + [$t]' <<<"$actions")"
      return 0
    fi
    create_body="${create_resp#*$'\n'}"
    newid="$(jq -r '.id // empty' <<<"$create_body" 2>/dev/null)"
    ledger="$(jq -c --arg id "$5" '.stranded_reported += [$id]' <<<"$ledger")"
    afk_pc_uuid_ok "$newid" && ledger="$(jq -c --arg id "$5" --arg rid "$newid" '.issues[$id].recovery_issue_id = $rid' <<<"$ledger")"
    afk_pc_notice "$8" "$5" "$6" "$7" "$9" "${10}" stranded
    actions="$(jq -c --arg t "stranded: $6" '. + [$t]' <<<"$actions")"
  fi
}

# afk_pc_hold <id> <stranded|held_by_board> -- the state a later resume
# restores (F7) is kept in resume_state; a second hold never overwrites it.
afk_pc_hold() {
  ledger="$(jq -c --arg id "$1" --arg st "$2" '.issues[$id] |=
    (if .state | IN("stranded", "held_by_board") then . else .resume_state = .state end | .state = $st)' <<<"$ledger")"
}

# afk_pc_reconcile <id> <identifier> -- AC-6 (P8b): a self-wake refused with
# execution_reconciliation_required. Paperclip will not let this host resume
# the issue, so it is parked as reconciliation_blocked, its slot released,
# its PM told `stopped`, and Josh gets one issue asking him to cancel and
# recreate it. Reads the pass locals like afk_pc_strand.
afk_pc_reconcile() {
  local row
  row="$(afk_pc_project_row "$(jq -r --arg id "$1" '.issues[$id].slug // empty' <<<"$ledger")")"
  ledger="$(jq -c --arg id "$1" '.issues[$id].state = "reconciliation_blocked" | del(.issues[$id].reblock_due)' <<<"$ledger")"
  [[ -n "$row" ]] && afk_pc_notice "$(jq -r .slug <<<"$row")" "$1" "$2" "$agent_id" \
    "$(jq -r .repo_path <<<"$row")" "$(jq -r .harness <<<"$row")" stopped '{"reason":"RECONCILIATION_REQUIRED"}'
  afk_pc_recon_issue "$1" "$2"
}

# afk_pc_recon_issue <id> <identifier> -- the one NEEDS HUMAN issue for a
# reconciliation_blocked issue; a failed create is retried next pass under
# the same idempotencyKey.
afk_pc_recon_issue() {
  [[ "$(jq -r --arg id "$1" '.issues[$id].recon_reported // false' <<<"$ledger")" == true ]] && return 0
  local r
  r="$(afk_pc_create_issue "$api_url" "$key" "$company_id" "NEEDS HUMAN: cancel $2 and recreate it" "$board_user_id" \
    "Paperclip refuses to let the AFK host $host_name resume $2 (execution_reconciliation_required). Setting it to Todo does not help. Cancel $2, create it again, and assign the new issue." \
    "afk-recon-$1")"
  [[ "${r%%$'\n'*}" == 2?? ]] && ledger="$(jq -c --arg id "$1" '.issues[$id].recon_reported = true' <<<"$ledger")"
}

# --- config (AC-1) -----------------------------------------------------------
# On success: AFK_PC_CFG is a compact JSON document. On failure: AFK_PC_REFUSAL
# is a reason code and no network call has been made.
afk_pc_load_config() {
  local path cfg n i pid slug repo_path harness merge max common
  local api_url company_id board_user_id host_name host_agent host_key maint
  AFK_PC_REFUSAL=""
  path="$(afk_pc_config_path)"
  if [[ ! -r "$path" ]]; then AFK_PC_REFUSAL="PAPERCLIP_NOT_CONFIGURED"; return 1; fi
  cfg="$(jq -c '.' "$path" 2>/dev/null)" || { AFK_PC_REFUSAL="PAPERCLIP_CONFIG_INVALID"; return 1; }
  # A v1 config (one agent and key per project, `agents[]`) is never read.
  # `paperclip-config --migrate` converts it; docs/PAPERCLIP.md §Config.
  if jq -e 'type == "object" and (has("agents") or (has("schema") | not))' >/dev/null 2>&1 <<<"$cfg"; then
    AFK_PC_REFUSAL="PAPERCLIP_CONFIG_SCHEMA_OLD"; return 1
  fi
  if [[ "$(jq -r '.schema // empty | strings' <<<"$cfg")" != "afk-paperclip-config/2" ]]; then
    AFK_PC_REFUSAL="PAPERCLIP_CONFIG_INVALID"; return 1
  fi
  # AD-25: the v1 pm_merge_allowed flag never granted anything; refuse it
  # wherever it appears so it cannot be read as a grant.
  if jq -e 'any(paths; .[-1] == "pm_merge_allowed")' >/dev/null 2>&1 <<<"$cfg"; then
    printf '%s\n' "agent-flow-kit: PAPERCLIP_CONFIG_INVALID: remove the pm_merge_allowed key from $path; set merge per project with 'agent-flow-kit paperclip-project set --slug <s> --merge human|pm'" >&2
    AFK_PC_REFUSAL="PAPERCLIP_CONFIG_INVALID"; return 1
  fi

  api_url="$(jq -r '.api_url // empty' <<<"$cfg")"
  company_id="$(jq -r '.company_id // empty' <<<"$cfg")"
  board_user_id="$(jq -r '.board_user_id // empty' <<<"$cfg")"
  host_name="$(jq -r '.host.label // empty | strings' <<<"$cfg")"
  host_agent="$(jq -r '.host.agent_id // empty | strings' <<<"$cfg")"
  host_key="$(jq -r '.host.key_ref // empty | strings' <<<"$cfg")"
  maint="$(jq -r '.maintenance_issue_id // empty' <<<"$cfg")"
  if [[ -z "$api_url" || -z "$company_id" || -z "$board_user_id" || -z "$host_name" || -z "$host_key" ]]; then
    AFK_PC_REFUSAL="PAPERCLIP_CONFIG_INVALID"; return 1
  fi
  # host.op_env_file is optional; when present it is an absolute path.
  if ! jq -e '.host.op_env_file | . == null or (type == "string" and startswith("/"))' >/dev/null 2>&1 <<<"$cfg"; then
    AFK_PC_REFUSAL="PAPERCLIP_CONFIG_INVALID"; return 1
  fi
  # The host key is sent as a bearer token to $api_url; refuse anything that
  # is not https:// so a typo or an edited config never sends it in cleartext.
  if [[ "$api_url" != https://* ]]; then
    AFK_PC_REFUSAL="PAPERCLIP_CONFIG_INVALID"; return 1
  fi
  if [[ "$board_user_id" == board || "$board_user_id" == local-board ]]; then
    AFK_PC_REFUSAL="PAPERCLIP_ID_INVALID"; return 1
  fi
  if ! afk_pc_uuid_ok "$company_id" || ! afk_pc_user_id_ok "$board_user_id" || ! afk_pc_uuid_ok "$host_agent"; then
    AFK_PC_REFUSAL="PAPERCLIP_ID_INVALID"; return 1
  fi
  if [[ -n "$maint" ]] && ! afk_pc_uuid_ok "$maint"; then
    AFK_PC_REFUSAL="PAPERCLIP_ID_INVALID"; return 1
  fi

  # AC-6: interim_comment_approval.paperclip_commit, when present, must be
  # the exact commit string GET /api/health reports (afk_pcs_approval_granted
  # compares it byte-for-byte) -- a short SHA or any non-hex value can never
  # match, so refuse it here instead of letting it silently fail-closed as
  # APPROVAL_INTERIM_UNATTESTED on every pass.
  local interim_commit
  interim_commit="$(jq -r '.interim_comment_approval.paperclip_commit // empty' <<<"$cfg")"
  if [[ -n "$interim_commit" ]] && ! [[ "$interim_commit" =~ ^[0-9a-f]{40}$ ]]; then
    AFK_PC_REFUSAL="PAPERCLIP_CONFIG_INVALID"; return 1
  fi

  # HA-2 (AD-24): host.intermittent (boolean, default false) and
  # host.max_active_issues (integer >= 1; default 2, or 1 when intermittent).
  # HA-5: docs/PAPERCLIP.md documents both fields.
  local intermittent host_max
  intermittent="$(jq -r '.host.intermittent | if . == null then "false" elif type == "boolean" then tostring else "bad" end' <<<"$cfg")"
  [[ "$intermittent" == true || "$intermittent" == false ]] || { AFK_PC_REFUSAL="PAPERCLIP_CONFIG_INVALID"; return 1; }
  host_max="$(jq -r '.host.max_active_issues | if . == null then "" elif type == "number" and . == floor then tostring else "bad" end' <<<"$cfg")"
  if [[ -z "$host_max" ]]; then
    host_max=2; [[ "$intermittent" == true ]] && host_max=1
  fi
  [[ "$host_max" =~ ^[1-9][0-9]{0,2}$ ]] || { AFK_PC_REFUSAL="PAPERCLIP_CONFIG_INVALID"; return 1; }
  # HA-4a (AD-26): host.adoption is "lease" (default) or "pull". Only read
  # here; HA-4b adds the command that switches it.
  # HA-5: docs/PAPERCLIP.md documents host.adoption and the heartbeat fields.
  local adoption
  adoption="$(jq -r '.host.adoption | if . == null then "lease" elif . == "lease" or . == "pull" then . else "bad" end' <<<"$cfg")"
  [[ "$adoption" != bad ]] || { AFK_PC_REFUSAL="PAPERCLIP_CONFIG_INVALID"; return 1; }

  # Zero projects is valid: every inbox issue then self-blocks as unmapped.
  n="$(jq '.projects // [] | if type == "array" then length else -1 end' <<<"$cfg")"
  if [[ "$n" -lt 0 ]]; then AFK_PC_REFUSAL="PAPERCLIP_CONFIG_INVALID"; return 1; fi

  local -A seen_ids=() seen_slugs=() seen_repos=()
  for ((i = 0; i < n; i++)); do
    IFS=$'\x1f' read -r pid slug repo_path harness max merge < <(jq -r --argjson i "$i" \
      '.projects[$i] | [(.paperclip_project_id // "" | strings), (.slug // "" | strings), (.repo_path // "" | strings),
        (.harness // "" | strings), (.max_active_issues // 1 | tostring), (.merge // "human" | tostring)] | map(gsub("[[:cntrl:]]"; "?")) | join("\u001f")' <<<"$cfg")
    if [[ -z "$pid" || -z "$repo_path" ]]; then AFK_PC_REFUSAL="PAPERCLIP_CONFIG_INVALID"; return 1; fi
    if ! afk_pc_uuid_ok "$pid"; then AFK_PC_REFUSAL="PAPERCLIP_ID_INVALID"; return 1; fi
    afk_pc_slug_ok "$slug" || { AFK_PC_REFUSAL="PAPERCLIP_CONFIG_INVALID"; return 1; }
    [[ "$repo_path" == /* ]] || { AFK_PC_REFUSAL="PAPERCLIP_CONFIG_INVALID"; return 1; }
    case "$harness" in claude | codex | opencode) ;; *) AFK_PC_REFUSAL="PAPERCLIP_CONFIG_INVALID"; return 1 ;; esac
    [[ "$max" =~ ^[1-9][0-9]{0,2}$ ]] || { AFK_PC_REFUSAL="PAPERCLIP_CONFIG_INVALID"; return 1; }
    case "$merge" in human | pm) ;; *) AFK_PC_REFUSAL="PAPERCLIP_CONFIG_INVALID"; return 1 ;; esac
    if [[ "$merge" == pm ]]; then
      AFK_PC_REFUSAL="$(afk_pc_kit_merge_code "$repo_path")"
      if [[ "$AFK_PC_REFUSAL" == PAPERCLIP_MERGE_KIT_REPO ]]; then
        printf '%s\n' "agent-flow-kit: PAPERCLIP_MERGE_KIT_REPO: projects[$slug] has merge: pm but $repo_path is the agent-flow-kit repo, or has no readable origin; edit $path and set merge to human" >&2
        return 1
      elif [[ -n "$AFK_PC_REFUSAL" ]]; then
        printf '%s\n' "agent-flow-kit: $AFK_PC_REFUSAL: projects[$slug] has merge: pm, but the kit's release policy (${AFK_RELEASE_POLICY:-${AFK_INSTALL_ROOT:-}/lifecycle/release-policy.json}) cannot be read, so merge: pm cannot be verified; repair the kit install, or edit $path and set merge to human" >&2
        return 1
      fi
    fi
    pid="${pid,,}"
    # Two paths into one repository (a linked worktree, a symlink) are the
    # same repo: compare git common-dirs. A path that is not a git repo yet
    # is allowed here; resolution refuses it per issue (REPO_NOT_READY).
    common="$(git -C "$repo_path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common="$repo_path"
    if [[ -n "${seen_ids[$pid]:-}" || -n "${seen_slugs[$slug]:-}" || -n "${seen_repos[$common]:-}" ]]; then
      AFK_PC_REFUSAL="PAPERCLIP_CONFIG_INVALID"; return 1
    fi
    seen_ids[$pid]=1; seen_slugs[$slug]=1; seen_repos[$common]=1
  done

  AFK_PC_CFG="$(jq -c '.projects = [(.projects // [])[] | .paperclip_project_id |= ascii_downcase
    | .max_active_issues = (.max_active_issues // 1) | .merge = (.merge // "human")]
    | .host.intermittent = ($i == "true") | .host.max_active_issues = ($m | tonumber) | .host.adoption = $ad' \
    --arg i "$intermittent" --arg m "$host_max" --arg ad "$adoption" <<<"$cfg")"
  return 0
}

# afk_pc_project_row <slug> -- the projects[] row for a pinned slug, or
# nothing. Every verb and the promotion path look the repo up this way.
afk_pc_project_row() {
  jq -c --arg s "$1" 'first(.projects[] | select(.slug == $s)) // empty' <<<"$AFK_PC_CFG"
}

# --- notices (AC-6) ----------------------------------------------------------
afk_pc_notice() { # <slug> <issue_id> <identifier> <host_agent_id> <repo_path> <harness> <event> [<extra-json>] [<chosen-path>]
  local dir="$AFK_STATE_DIR/paperclip/notices/$1" epoch payload extra="${8:-}" target="${9:-}"
  [[ -n "$extra" ]] || extra='{}'
  afk_pc_slug_ok "$1" || return 1 # never a path from anything but a config slug
  afk_state_dir_ensure "$dir"
  epoch="$(date +%s)"
  [[ -n "$target" ]] || target="$dir/$epoch.$2.$7.json"
  payload="$(jq -nc --arg id "$2" --arg identifier "$3" --arg agent "$4" --arg slug "$1" \
    --arg repo "$5" --arg harness "$6" --arg event "$7" \
    --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson extra "$extra" \
    '{id: $id, identifier: $identifier, host_agent_id: $agent, slug: $slug,
      repo_path: $repo, harness: $harness, event: $event, time: $time} + $extra')"
  afk_state_file_write "$target" "$payload"
}

afk_pc_brief() { # <slug> <issue_id> <updated_at> <title> <description> [<chosen-path>]
  local dir="$AFK_STATE_DIR/paperclip/notices/$1" digits target="${6:-}"
  afk_pc_slug_ok "$1" || return 1
  afk_state_dir_ensure "$dir"
  digits="$(tr -cd '0-9' <<<"$3")"
  # A stable fallback lets a killed pass find the same brief on replay.
  [[ -n "$digits" ]] || digits=0
  [[ -n "$target" ]] || target="$dir/brief.$2.$digits.md"
  afk_state_file_write "$target" "# $4"$'\n\n'"$5"
}

afk_pc_reply() { # <slug> <comment_id> <body>
  local dir="$AFK_STATE_DIR/paperclip/notices/$1"
  afk_pc_slug_ok "$1" || return 1
  afk_state_dir_ensure "$dir"
  afk_state_file_write "$dir/reply.$2.md" "$3"
}

# --- action text (AC-7, extended by PC-1b AC-2 and HA-1a AC-4) --------------
# Precedence (AD-7): Stopped > paused > PM state unclear (a start override) >
# setup refusal > waiting on <qid> > queued behind <id> (project) > queued:
# <host> busy (host) > declared status.
afk_pc_action_text() { # <pause-kind: none|stopped|maintenance> <queued-behind-or-empty> <status-file> <prev-action-or-empty> [<question-id-or-empty>] [<refusal-text-or-empty>] [<host-busy-text-or-empty>]
  case "$1" in
    stopped) printf 'Stopped'; return 0 ;;
    maintenance) printf 'paused for Paperclip maintenance'; return 0 ;;
  esac
  [[ -n "${6:-}" ]] && { printf '%s' "$6"; return 0; }
  [[ -n "${5:-}" ]] && { printf 'waiting on %s' "$5"; return 0; }
  [[ -n "$2" ]] && { printf 'queued behind %s' "$2"; return 0; }
  [[ -n "${7:-}" ]] && { printf '%s' "$7"; return 0; }
  if [[ -r "$3" ]]; then
    local t; t="$(jq -r '.text // empty' "$3" 2>/dev/null)"
    [[ -n "$t" ]] && { printf '%s' "$t"; return 0; }
  fi
  if [[ -n "$4" && "$4" != null ]]; then printf '%s' "$4"; return 0; fi
  printf 'AFK host is working on this'
}

# afk_pc_queue_text -- the AD-24 queued text for an issue that cannot take a
# slot: the project's own slot outranks the host cap. Prints nothing when
# neither limit is reached. Reads the caller's pass
# locals (used_slots_s, max_active, working_id, host_used, host_max, host_name).
afk_pc_queue_text() {
  local qb="" ht=""
  # No limit reached: no queued text, so a caller keeps the existing one.
  (( used_slots_s >= max_active || host_used >= host_max )) || return 0
  if (( used_slots_s >= max_active )); then qb="$working_id"
  else ht="$(printf 'queued: %s busy (%s/%s active)' "$host_name" "$host_used" "$host_max")"; fi
  afk_pc_action_text none "$qb" "" "" "" "" "$ht"
}

# --- project resolution (HA-1a, AD-23) ----------------------------------------
# afk_pc_origin_normalize <url> -- prints `host/path` or fails. scp form
# (user@host:path) and URL forms alike; the host is lowercased; user@, the
# port, a trailing / and one trailing .git are dropped. The path keeps its
# case: a case difference is a different repository.
afk_pc_origin_normalize() {
  local u="$1" host path
  if [[ "$u" =~ ^[A-Za-z][A-Za-z0-9+.-]*://([^/]+)(/.*)$ ]]; then
    host="${BASH_REMATCH[1]}"; path="${BASH_REMATCH[2]}"
    host="${host##*@}"
    if [[ "$host" == \[*\]* ]]; then host="${host%%]*}]"; else host="${host%%:*}"; fi
  elif [[ "$u" != *://* && "$u" =~ ^([^/:@]+@)?([^/:]+):(.+)$ ]]; then
    host="${BASH_REMATCH[2]}"; path="/${BASH_REMATCH[3]#/}"
  else
    return 1
  fi
  path="${path%/}"; path="${path%.git}"; path="${path#/}"
  [[ -n "$host" && -n "$path" && "$host" != *[[:space:][:cntrl:]]* && "$path" != *[[:cntrl:]]* ]] || return 1
  printf '%s/%s' "${host,,}" "$path"
}

# afk_pc_is_kit_repo <repo_path> -- 0 when the repo is agent-flow-kit itself
# (AD-25): the same git common-dir as this kit checkout, or an origin equal
# (ignoring case) to the release repo in lifecycle/release-policy.json
# (.trust.remote_url). A repo with no readable origin also returns 0, and an
# unreadable release policy returns 2, so `merge: pm` fails closed. 1 only
# when the repo is shown not to be the kit.
afk_pc_is_kit_repo() {
  local root="${AFK_INSTALL_ROOT:-}" policy kit_common="" common release origin
  policy="${AFK_RELEASE_POLICY:-$root/lifecycle/release-policy.json}"
  [[ -n "$root" ]] && kit_common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  [[ -n "$kit_common" && "$common" == "$kit_common" ]] && return 0
  release="$(afk_pc_origin_normalize "$(jq -r '.trust.remote_url // empty | strings' "$policy" 2>/dev/null)")" || return 2
  origin="$(afk_pc_origin_normalize "$(git -C "$1" remote get-url origin 2>/dev/null)")" || return 0
  [[ "${origin,,}" == "${release,,}" ]]
}

# afk_pc_kit_merge_code <repo_path> -- prints the refusal code for `merge: pm`
# on this repo (PAPERCLIP_MERGE_KIT_REPO or PAPERCLIP_RELEASE_POLICY_UNREADABLE),
# or nothing when pm is allowed.
afk_pc_kit_merge_code() {
  local rc=0
  afk_pc_is_kit_repo "$1" || rc=$?
  case "$rc" in
    0) printf PAPERCLIP_MERGE_KIT_REPO ;;
    2) printf PAPERCLIP_RELEASE_POLICY_UNREADABLE ;;
  esac
}

# afk_pc_repo_ready <repo_path> <repo_url-or-empty> -- prints "ok", or the
# REPO_NOT_READY sub-code, or "MISMATCH". The allowlist is read from the
# default branch's tree (`git show`), never from a worktree.
afk_pc_repo_ready() {
  local repo="$1" want="$2" top real ref origin norm
  [[ -d "$repo" ]] || { printf 'REPO_MISSING'; return 1; }
  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || top=""
  real="$(cd "$repo" 2>/dev/null && pwd -P)"
  [[ -n "$top" && "$(cd "$top" 2>/dev/null && pwd -P)" == "$real" ]] || { printf 'NOT_A_GIT_REPO'; return 1; }
  # AD-23 order: REPO_MISMATCH before REPO_NOT_READY, so a mapping to the
  # wrong local repo is reported as that, not as a missing allowlist there.
  if [[ -n "$want" ]]; then
    origin="$(git -C "$repo" remote get-url origin 2>/dev/null)" || origin=""
    norm="$(afk_pc_origin_normalize "$origin")" || { printf 'ORIGIN_UNREADABLE'; return 1; }
    [[ "$norm" == "$(afk_pc_origin_normalize "$want" 2>/dev/null)" ]] || { printf 'MISMATCH'; return 1; }
  fi
  ref="$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)" || ref=""
  [[ -n "$ref" ]] || ref=HEAD
  [[ "$(git -C "$repo" cat-file -t "$ref:.afk/gates-allowlist" 2>/dev/null)" == blob ]] ||
    { printf 'GATES_ALLOWLIST_MISSING'; return 1; }
  printf 'ok'
}

# afk_pc_refusal_text <reason> <project-id-or-empty> <name-or-empty> -- the
# AD-23 self-block text with its ` · <id8> "<name>"` tail. The whole text is
# held to 120 minus 13 (HA-4 appends the AD-27 ` · <host> HH:MMZ` suffix): the
# name is dropped first, then the reason itself is cut (ending in `…`) so the
# ` · <id8>` tail always fits.
afk_pc_refusal_text() {
  jq -rn --arg r "$1" --arg p "${2:0:8}" --arg n "$3" '
    (if $p == "" then 107 else 96 end) as $max
    | ("Waiting for Josh: " + $r) as $full
    | (if ($full | length) > $max then $full[0:$max - 1] + "…" else $full end) as $t
    | ($n | gsub("[[:cntrl:]\"]"; "") | .[0:32]) as $name
    | if $p == "" then $t
      elif $name != "" and ($t + " · " + $p + " \"" + $name + "\"" | length) <= 107 then $t + " · " + $p + " \"" + $name + "\""
      else $t + " · " + $p end'
}

# afk_pc_resolve <issue-detail-json> <identifier> -- AC-3. Resolves the
# issue's live projectId against this host's projects[] in the AD-23 order.
# Sets AFK_PC_RES (ok | a PAPERCLIP_PROJECT_* code), AFK_PC_RES_TEXT (the
# self-block text of a refusal), AFK_PC_RES_PID and AFK_PC_RES_ROW (the
# projects[] row, when mapped). Reads the caller's api_url/key/host_name/id,
# reads/writes its `ledger` (the consecutive-404 count, the last outcome per
# project) and appends to `actions`. A direct call, never $(...).
afk_pc_resolve() {
  local detail="$1" identifier="$2" pid name archived repo_url resp code body rd n
  AFK_PC_RES=""; AFK_PC_RES_TEXT=""; AFK_PC_RES_PID=""; AFK_PC_RES_ROW=""
  pid="$(jq -r '.projectId // empty | strings' <<<"$detail")"
  if [[ -z "$pid" ]]; then
    AFK_PC_RES=PAPERCLIP_PROJECT_MISSING
    AFK_PC_RES_TEXT="$(afk_pc_refusal_text "set a Project on $identifier" "" "")"
    return 0
  fi
  if ! afk_pc_uuid_ok "$pid"; then # never a path, never a lookup key
    AFK_PC_RES=PAPERCLIP_PROJECT_UNMAPPED
    AFK_PC_RES_TEXT="$(afk_pc_refusal_text "project not set up on $host_name; assign to a host that has it" "" "")"
    return 0
  fi
  pid="${pid,,}"; AFK_PC_RES_PID="$pid"
  AFK_PC_RES_ROW="$(jq -c --arg p "$pid" 'first(.projects[] | select(.paperclip_project_id == $p)) // empty' <<<"$AFK_PC_CFG")"
  if [[ -z "$AFK_PC_RES_ROW" ]]; then
    AFK_PC_RES=PAPERCLIP_PROJECT_UNMAPPED
    AFK_PC_RES_TEXT="$(afk_pc_refusal_text "project not set up on $host_name; assign to a host that has it" "$pid" "")"
    return 0
  fi
  resp="$(afk_pc_curl GET "$api_url/api/projects/$pid" "$key" "")"
  code="${resp%%$'\n'*}"; body="${resp#*$'\n'}"
  if [[ "$code" != 200 ]] || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$body"; then
    afk_pc_count_404 "$code"; n="$AFK_PC_404_N"
    if (( n >= 3 )); then
      AFK_PC_RES=PAPERCLIP_PROJECT_MISSING
      AFK_PC_RES_TEXT="$(afk_pc_refusal_text "set a Project on $identifier" "" "")"
      return 0
    fi
    AFK_PC_RES=PAPERCLIP_PROJECT_UNREADABLE
    actions="$(jq -c --arg t "PAPERCLIP_PROJECT_UNREADABLE (${code:-no response}), held: $identifier" '. + [$t]' <<<"$actions")"
    return 0
  fi
  afk_pc_count_404 200
  local slug_r repo_r
  IFS=$'\x1f' read -r name archived repo_url slug_r repo_r < <(jq -r --argjson r "$AFK_PC_RES_ROW" \
    'def str: if type == "string" then . else "" end;
     [(.name | str), (.archivedAt // "" | tostring), (.codebase.repoUrl | str), $r.slug, $r.repo_path]
     | map(gsub("[[:cntrl:]]"; "")) | join("\u001f")' <<<"$body")
  if [[ -n "$archived" ]]; then
    AFK_PC_RES=PAPERCLIP_PROJECT_ARCHIVED
    AFK_PC_RES_TEXT="$(afk_pc_refusal_text "project archived" "$pid" "$name")"
  else
    rd="$(afk_pc_repo_ready "$repo_r" "$repo_url")"
    case "$rd" in
      ok) AFK_PC_RES=ok ;;
      MISMATCH)
        AFK_PC_RES=PAPERCLIP_PROJECT_REPO_MISMATCH
        AFK_PC_RES_TEXT="$(afk_pc_refusal_text "project repo differs from $host_name's" "$pid" "$name")" ;;
      *)
        AFK_PC_RES=PAPERCLIP_PROJECT_REPO_NOT_READY
        AFK_PC_RES_TEXT="$(afk_pc_refusal_text "$slug_r repo not ready on $host_name ($rd)" "$pid" "$name")" ;;
    esac
  fi
  # F4: the project fields read above are agent-writable; a project flipping
  # between accepted and refused is reported once locally.
  local was now
  now=refused; [[ "$AFK_PC_RES" == ok ]] && now=accepted
  was="$(jq -r --arg p "$pid" '.project_outcome[$p] // empty' <<<"$ledger")"
  if [[ -n "$was" && "$was" != "$now" ]]; then
    actions="$(jq -c --arg t "PAPERCLIP_PROJECT_REFUSAL_CHANGED: ${pid:0:8} $now" '. + [$t]' <<<"$actions")"
  fi
  ledger="$(jq -c --arg p "$pid" --arg o "$now" '.project_outcome[$p] = $o' <<<"$ledger")"
  return 0
}

# --- the spool (PC-1b) --------------------------------------------------------
# Layout: $AFK_STATE_DIR/paperclip/spool/<issue-id>/<seq>.json, dead/ and
# unconfirmed/ siblings hold retired entries. Only <digits>.json is a live
# entry; .tmp/ and anything else is ignored (AC-8).
afk_pc_spool_dir() { printf '%s/paperclip/spool/%s' "$AFK_STATE_DIR" "$1"; }

afk_pc_spool_files() { # <issue_id> -- prints live entry basenames, seq order
  local dir; dir="$(afk_pc_spool_dir "$1")"
  [[ -d "$dir" ]] || return 0
  find "$dir" -maxdepth 1 -type f -name '*.json' -printf '%f\n' 2>/dev/null |
    grep -E '^[0-9]+\.json$' | sort -n
}

# afk_pc_spool_lock/unlock -- the same portable mkdir spin-lock the writer
# uses (afk_pcr_lock in lib/afk-paperclip-report.sh), kept self-contained
# here: afk_pc_report_cycle runs inside the poll run's own already-locked
# section, whose EXIT trap releases a different lock ($AFK_STATE_DIR/
# paperclip/.lock). The previous EXIT trap's exact command body (never the
# `trap -- '...' EXIT` registration itself, which would only re-arm it) is
# captured once and re-run from afk_pc_spool_exit_trap, so an interrupted
# holder still releases both locks, and a second, third, ... report cycle in
# the same process (one per issue) does not re-capture its own trap.
AFK_PC_SPOOL_HELD_LOCK=""
AFK_PC_SPOOL_PREV_EXIT_TRAP=""
AFK_PC_SPOOL_TRAP_CHAINED="false"
afk_pc_spool_exit_trap() {
  [[ -n "$AFK_PC_SPOOL_HELD_LOCK" ]] && { rm -f "$AFK_PC_SPOOL_HELD_LOCK/owner" 2>/dev/null; rmdir "$AFK_PC_SPOOL_HELD_LOCK" 2>/dev/null; }
  [[ -n "$AFK_PC_SPOOL_PREV_EXIT_TRAP" ]] && eval "$AFK_PC_SPOOL_PREV_EXIT_TRAP"
}
# AC-3: this lockdir is also `afk_pcr_lock`'s (lib/afk-paperclip-report.sh)
# spool `.seq.lock` -- the same directory, briefly held from this (reader)
# side too. Recording an owner here as well means a writer's stale-reap can
# tell a live reader from a dead one instead of only ever seeing an unowned
# lock and reaping it on age alone.
afk_pc_spool_lock() { # <lockdir>
  local dir="$1" waited=0
  while ! mkdir "$dir" 2>/dev/null; do
    if (( waited % 100 == 0 )) && declare -F afk_pcs_lock_stale_reap >/dev/null 2>&1 && \
       afk_pcs_lock_stale_reap "$dir" "${AFK_PCR_LOCK_STALE_INTERVAL_SECONDS:-30}" "paperclip-report|paperclip-poll" && \
       mkdir "$dir" 2>/dev/null; then
      declare -F afk_warn >/dev/null 2>&1 && afk_warn "PAPERCLIP_LOCK_STALE: reaped a spool lock left by a dead writer"
      break
    fi
    sleep 0.02
    waited=$((waited + 1))
    (( waited > 500 )) && return 1
  done
  AFK_PC_SPOOL_HELD_LOCK="$dir"
  printf '%s %s\n' "$$" "$(date +%s)" >"$dir/owner" 2>/dev/null || true
  if [[ "$AFK_PC_SPOOL_TRAP_CHAINED" != true ]]; then
    local prev; prev="$(trap -p EXIT)"
    if [[ -n "$prev" ]]; then
      prev="${prev#trap -- }"
      prev="${prev% EXIT}"
      eval "AFK_PC_SPOOL_PREV_EXIT_TRAP=$prev"
    fi
    AFK_PC_SPOOL_TRAP_CHAINED="true"
    trap 'afk_pc_spool_exit_trap' EXIT
  fi
  return 0
}
afk_pc_spool_unlock() { # <lockdir> -- deliberately leaves the chained trap
  rm -f "$1/owner" 2>/dev/null                # in place: at real process
  rmdir "$1" 2>/dev/null || true              # exit it rmdir's an already-
  AFK_PC_SPOOL_HELD_LOCK=""                   # gone dir (a no-op) and still
}                                              # runs the previous trap.

afk_pc_spool_dead() { # <issue_id> <entry-file-basename> <reason>
  local dir; dir="$(afk_pc_spool_dir "$1")/dead"
  afk_state_dir_ensure "$dir"
  mv -f -- "$(afk_pc_spool_dir "$1")/$2" "$dir/$2" 2>/dev/null
  printf '%s\n' "$3" >"$dir/$2.reason" 2>/dev/null
}

afk_pc_spool_dead_all() { # <issue_id> -- everything remaining, e.g. after a
  local dir f base                                # final or a closed issue.
  dir="$(afk_pc_spool_dir "$1")"
  [[ -d "$dir" ]] || return 0
  while IFS= read -r base; do
    [[ -n "$base" ]] || continue
    afk_pc_spool_dead "$1" "$base" "PAPERCLIP_ISSUE_CLOSED"
  done < <(afk_pc_spool_files "$1")
}

# afk_pc_spool_reopen <issue_id> -- an issue re-adopted after it closed:
# remove the spool's `.final` marker under the writer's lock, and the stale
# declared status. Entries already retired stay in dead/.
afk_pc_spool_reopen() {
  local dir; dir="$(afk_pc_spool_dir "$1")"
  if [[ -e "$dir/.final" ]] && afk_pc_spool_lock "$dir/.seq.lock"; then
    rm -f -- "$dir/.final"
    afk_pc_spool_unlock "$dir/.seq.lock"
  fi
  rm -f -- "$AFK_STATE_DIR/paperclip/status/$1.json"
}

# afk_pc_marker_seen <api_url> <key> <issue_id> <marker> <agent_id> -- AC-4
# read-back. 0: one of OUR comments carries the marker. 1: the comment list
# was read and none does. 2: the read-back itself failed, so nothing is known
# and the caller must not re-post (a failed read is never "not found").
# Only comments authored by this agent count, so a marker pasted by anyone
# else can never make an unsent entry look sent.
afk_pc_marker_seen() {
  local resp body; resp="$(afk_pc_curl GET "$1/api/issues/$3/comments" "$2" "")"
  [[ "${resp%%$'\n'*}" == 2?? ]] || return 2
  body="${resp#*$'\n'}"
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$body" || return 2
  jq -e --arg m "$4" --arg a "$5" \
    'any(.[]; (.authorAgentId // "") == $a and ((.body // "") | type == "string" and contains($m)))' \
    >/dev/null 2>&1 <<<"$body"
}

# The attempt flag is durable before POST. A missing read-back after an
# attempted POST is uncertainty, not permission to post again. Only a comment
# authored by this host agent clears pending, including after a killed pass.
afk_pc_claim_comment() {
  local marker body rc=0 attempted posted status outcome
  marker="claimed by AFK PM ($host_name)"$'\n\n'"<!-- afk-claim:$id -->"
  body="$marker"
  if ! jq -e --arg id "$id" '.issues[$id].claim != null' <<<"$ledger" >/dev/null; then
    ledger="$(jq -c --arg id "$id" '.issues[$id].claim = "intent" |
      .issues[$id].claim_comment_pending = true' <<<"$ledger")"
    afk_state_file_write "$ledger_path" "$ledger" || return 1
  fi
  attempted="$(jq -r --arg id "$id" '.issues[$id].claim_attempted // false' <<<"$ledger")"
  if [[ "$attempted" == true ]]; then
    afk_pc_marker_seen "$api_url" "$key" "$id" "$marker" "$agent_id" || rc=$?
    if (( rc == 0 )); then
      ledger="$(jq -c --arg id "$id" '.issues[$id].claim = "confirmed" |
        del(.issues[$id].claim_comment_pending)' <<<"$ledger")"
      afk_state_file_write "$ledger_path" "$ledger"
      return $?
    fi
    actions="$(jq -c --arg t "claim read-back unresolved, held: $identifier" '. + [$t]' <<<"$actions")"
    return 1
  fi
  ledger="$(jq -c --arg id "$id" '.issues[$id].claim_attempted = true' <<<"$ledger")"
  afk_state_file_write "$ledger_path" "$ledger" || return 1
  posted="$(afk_pc_comment "$api_url" "$id" "$key" "${run_id:-}" "$body")"
  status="${posted%%$'\n'*}"
  outcome="$(afk_pc_entry_outcome "$status")"
  case "$outcome" in
    credential | conflict | dead | backoff | gone)
      # The server rejected the POST. This is a known non-effect, so the
      # durable attempt may be cleared and the next pass may retry it.
      ledger="$(jq -c --arg id "$id" '.issues[$id].claim_attempted = false' <<<"$ledger")"
      afk_state_file_write "$ledger_path" "$ledger" || return 1
      actions="$(jq -c --arg t "claim POST rejected ($status), retrying: $identifier" '. + [$t]' <<<"$actions")"
      [[ "$outcome" == credential || "$outcome" == backoff ]] && AFK_PC_ABORT=true
      return 1 ;;
  esac
  rc=0
  afk_pc_marker_seen "$api_url" "$key" "$id" "$marker" "$agent_id" || rc=$?
  if (( rc == 0 )); then
    ledger="$(jq -c --arg id "$id" '.issues[$id].claim = "confirmed" |
      del(.issues[$id].claim_comment_pending)' <<<"$ledger")"
    afk_state_file_write "$ledger_path" "$ledger"
  else
    actions="$(jq -c --arg t "claim read-back unresolved, held: $identifier" '. + [$t]' <<<"$actions")"
    return 1
  fi
  return 0
}

# Both paths are chosen once and saved before their writes. The epoch and
# per-issue counter keep a re-adoption distinct and ordered even in one second.
afk_pc_claim_artifacts() {
  local notice_path brief_path epoch old_epoch counter serial dir
  dir="$AFK_STATE_DIR/paperclip/notices/$slug"
  if ! jq -e --arg id "$id" '.issues[$id].claimed_notice == "written"' <<<"$ledger" >/dev/null; then
    notice_path="$(jq -r --arg id "$id" '.issues[$id].claimed_notice_path // empty' <<<"$ledger")"
    if [[ -z "$notice_path" ]]; then
      epoch="$(date +%s)"
      old_epoch="$(jq -r --arg id "$id" '.issues[$id].claimed_notice_epoch // 0' <<<"$ledger")"
      [[ "$old_epoch" =~ ^[0-9]+$ ]] || old_epoch=0
      (( epoch < old_epoch )) && epoch="$old_epoch"
      counter="$(jq -r --arg id "$id" '.issues[$id].claim_artifact_counter // 0' <<<"$ledger")"
      [[ "$counter" =~ ^[0-9]+$ ]] || counter=0
      counter=$((counter + 1))
      serial="$(printf '%09d' "$counter")"
      # Issue ids are hexadecimal; the z prefix places a same-second new
      # claim after an earlier stopped notice in the PM's filename walk.
      notice_path="$dir/$epoch.z$serial.$id.claimed.json"
      ledger="$(jq -c --arg id "$id" --arg p "$notice_path" --argjson e "$epoch" --argjson c "$counter" \
        '.issues[$id] |= (. + {claimed_notice:"intent",claimed_notice_path:$p,claimed_notice_epoch:$e,claim_artifact_counter:$c})' <<<"$ledger")"
    else
      ledger="$(jq -c --arg id "$id" '.issues[$id].claimed_notice = "intent"' <<<"$ledger")"
    fi
    afk_state_file_write "$ledger_path" "$ledger" || return 1
    [[ -e "$notice_path" ]] || afk_pc_notice "$slug" "$id" "$identifier" "$agent_id" "$repo_path" "$harness" claimed '{}' "$notice_path" || return 1
    ledger="$(jq -c --arg id "$id" '.issues[$id].claimed_notice = "written"' <<<"$ledger")"
    afk_state_file_write "$ledger_path" "$ledger" || return 1
  fi
  if ! jq -e --arg id "$id" '.issues[$id].claimed_brief == "written"' <<<"$ledger" >/dev/null; then
    brief_path="$(jq -r --arg id "$id" '.issues[$id].claimed_brief_path // empty' <<<"$ledger")"
    if [[ -z "$brief_path" ]]; then
      epoch="$(jq -r --arg id "$id" '.issues[$id].claimed_notice_epoch // empty' <<<"$ledger")"
      counter="$(jq -r --arg id "$id" '.issues[$id].claim_artifact_counter // empty' <<<"$ledger")"
      [[ "$epoch" =~ ^[0-9]+$ && "$counter" =~ ^[0-9]+$ ]] || return 1
      serial="$(printf '%09d' "$counter")"
      brief_path="$dir/brief.$id.$epoch.$serial.md"
    fi
    ledger="$(jq -c --arg id "$id" --arg p "$brief_path" '.issues[$id].claimed_brief = "intent" |
      .issues[$id].claimed_brief_path = $p' <<<"$ledger")"
    afk_state_file_write "$ledger_path" "$ledger" || return 1
    [[ -e "$brief_path" ]] || afk_pc_brief "$slug" "$id" "$updated" "$title" "$desc" "$brief_path" || return 1
    ledger="$(jq -c --arg id "$id" '.issues[$id].claimed_brief = "written"' <<<"$ledger")"
    afk_state_file_write "$ledger_path" "$ledger" || return 1
  fi
}

# afk_pc_resolve_sending <issue_id> -- AC-4: a leftover `sending` from a
# crashed pass is resolved by read-back before anything else is posted. Reads
# and writes the caller's `ledger` local directly, like afk_pc_strand.
# Returns 1 when the read-back failed: `sending` stays, and the caller posts
# nothing for this issue this pass.
afk_pc_resolve_sending() { # <api_url> <key> <issue_id> <agent_id>
  local sending eid marker base rc=0
  sending="$(jq -c --arg id "$3" '.issues[$id].sending // empty' <<<"$ledger")"
  [[ -n "$sending" ]] || return 0
  eid="$(jq -r '.entry_id // empty' <<<"$sending")"
  marker="<!-- afk-entry:$eid -->"
  afk_pc_marker_seen "$1" "$2" "$3" "$marker" "$4" || rc=$?
  (( rc == 2 )) && return 1
  if (( rc == 0 )); then
    while IFS= read -r base; do
      [[ -n "$base" ]] || continue
      [[ "$(jq -r '.id // empty' "$(afk_pc_spool_dir "$3")/$base" 2>/dev/null)" == "$eid" ]] &&
        rm -f -- "$(afk_pc_spool_dir "$3")/$base"
    done < <(afk_pc_spool_files "$3")
  fi
  ledger="$(jq -c --arg id "$3" '.issues[$id].sending = null' <<<"$ledger")"
}

# afk_pc_entry_outcome <http-status> -- AC-5, applied to a single entry POST.
afk_pc_entry_outcome() {
  case "$1" in
    2??) printf 'ok' ;;
    401 | 403) printf 'credential' ;;
    409) printf 'conflict' ;;
    422 | 400) printf 'dead' ;;
    429) printf 'backoff' ;;
    404 | 410) printf 'gone' ;;
    *) printf 'ambiguous' ;; # 5xx or a blank/transport-failed status
  esac
}

# afk_pc_report_cycle <api_url> <key> <agent_id> <issue_id> <identifier>
#                      <status_file_dir>
# One report cycle (AC-1..AC-5, AC-10): wakeup, in_progress, drain the spool
# in order, then either the final status or a self-block. Reads/writes the
# caller's `ledger`/`actions` locals directly and sets AFK_PC_ABORT when the
# whole agent must stop for this pass (credential rejection or a rate limit).
# Keep only fixed, recognized fields from a final-status validation error.
# The response body is untrusted: arbitrary error text never reaches the
# ledger or operator output, even when it is valid JSON.
afk_pc_final_hold() { # <status> <body> <final_status> <run_id>
  local LC_ALL=C http_status="$1" body="$2" final_status="$3" run_id="$4"
  # Parse only complete JSON within a fixed byte limit. Truncating first
  # discards valid allowlisted fields that appear late in the response.
  (( ${#body} <= 65536 )) || body=""
  jq -nc --arg http "$http_status" --arg body "$body" --arg status "$final_status" --arg run "$run_id" '
    (try ($body | fromjson) catch {} | if type == "object" then . else {} end) as $error
    | ($error.code // (if ($error.error | type) == "object" then $error.error.code else null end)) as $code
    | ($error.missing_field // $error.missingField //
       (if ($error.details | type) == "object" then ($error.details.missing_field // $error.details.missingField) else null end)) as $field
    | ($error.requestId // $error.request_id // null) as $request
    | {status:$status, http_status:($http | tonumber), reason:"validation_rejected"}
    + (if $code == "invalid_issue_disposition" then {code:$code} else {} end)
    + (if $field == "review_path" then {missing_field:$field} else {} end)
    + (if ($request | type) == "string" and ($request | test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"))
       then {request_id:$request} else {} end)
    + (if ($run | test("^[A-Za-z0-9_-]{1,64}$")) then {run_id:$run} else {} end)'
}

afk_pc_report_cycle() {
  local api_url="$1" key="$2" agent_id="$3" id="$4" identifier="$5" status_file_dir="$6"
  AFK_PC_ABORT=false

  # A failed read-back of a leftover `sending` means nothing is known: post
  # nothing for this issue this pass rather than risk a duplicate.
  if ! afk_pc_resolve_sending "$api_url" "$key" "$id" "$agent_id"; then
    actions="$(jq -c --arg t "read-back unavailable, entries held: $identifier" '. + [$t]' <<<"$actions")"
    return 0
  fi

  # The writer publishes an entry (mv) and then still has to write .seq/
  # .final before it releases .seq.lock; take the same lock here for a short
  # snapshot so this pass never lists an entry the writer is still in the
  # middle of publishing. A lock that can't be taken skips this issue for
  # this pass rather than reading (and possibly deleting) anything.
  local spool_dir_for_lock; spool_dir_for_lock="$(afk_pc_spool_dir "$id")"
  # mkdir (no -p) for the lock itself fails outright, not just contends, when
  # this issue has never had a spool entry and the directory doesn't exist
  # yet: ensure it first so a claim-only issue with no spool history is
  # never mistaken for a held lock.
  afk_state_dir_ensure "$spool_dir_for_lock"
  local spool_lock="$spool_dir_for_lock/.seq.lock"
  if ! afk_pc_spool_lock "$spool_lock"; then
    actions="$(jq -c --arg t "spool lock unavailable, entries held: $identifier" '. + [$t]' <<<"$actions")"
    return 0
  fi
  local -a files=()
  mapfile -t files < <(afk_pc_spool_files "$id")
  afk_pc_spool_unlock "$spool_lock"
  local prev; prev="$(jq -c --arg id "$id" '.issues[$id] // empty' <<<"$ledger")"
  local state qid prev_applied action_text declared_text composed pending_final claim_pending fixed pm_start_state pm_confirmed held_final
  state="$(jq -r '.state // empty' <<<"$prev")"
  # A refused (waiting_setup) or project-changed (stopped) issue has no PM:
  # its cycle is the fixed self-block text alone, and nothing is drained.
  fixed="$(jq -r 'select(.state == "waiting_setup" or .state == "stopped") | .fixed_text // empty' <<<"$prev")"
  [[ -n "$fixed" ]] && files=()
  qid="$(jq -r '.question_id // empty' <<<"$prev")"
  prev_applied="$(jq -r '.action_text_applied // .action_text // empty' <<<"$prev")"
  action_text="$(jq -r '.action_text // empty' <<<"$prev")"
  pm_start_state="$(jq -r --arg id "$id" '.pm_started[$id].state // empty' <<<"$ledger")"
  pm_confirmed="$(jq -r --arg id "$id" '.issues[$id].pm_confirmed // false' <<<"$ledger")"
  declared_text="$prev_applied"
  [[ "$action_text" == *"no PM"* || "$action_text" == *"PM state"* ]] && declared_text="$action_text"
  # A promoted issue must not keep ordinary queue text, but a PM-start hold
  # remains the truthful status until a start receipt exists.
  local text_base="$declared_text"
  if [[ "$state" == working && "$declared_text" == queued* ]]; then
    if [[ "$pm_confirmed" == true || "$pm_start_state" == live ]]; then
      text_base=""
    elif [[ "$declared_text" == *"no PM"* || "$declared_text" == *"PM state"* ]]; then
      text_base="$declared_text"
    else
      text_base=""
    fi
  elif [[ "$state" == working && ( "$action_text" == *"no PM"* || "$action_text" == *"PM state"* ) &&
          "$action_text" != "$prev_applied" && "$pm_confirmed" != true ]]; then
    # A newly observed start hold is a declared change: send it once, then
    # action_text_applied records only the text the report cycle actually PATCHed.
    text_base="$action_text"
  fi
  # A final whose comment went out but whose status PATCH failed is retried
  # from the ledger: its spool file is already gone.
  pending_final="$(jq -r '.pending_final // empty' <<<"$prev")"
  held_final=false
  [[ -n "$pending_final" && "$(jq -r '.final_delivery_hold.status // empty' <<<"$prev")" == "$pending_final" ]] && held_final=true
  claim_pending="$(jq -r '.claim_comment_pending // false' <<<"$prev")"
  # An attempted claim is reconciled by the read-only issue sweep. It never
  # causes a self-wake merely to retry or re-check a possibly posted comment.
  [[ "$(jq -r '.claim_attempted // false' <<<"$prev")" == true ]] && claim_pending=false
  # HA-4a: a cycle the pass asked for (adopt, resume, nudge, strand repair)
  # runs even when nothing else changed.
  local due; due="$(jq -r '.reblock_due // empty' <<<"$prev")"
  if [[ -n "$fixed" ]]; then
    composed="$fixed"
  elif [[ "$state" == queued ]]; then
    composed="$(jq -r '.action_text // empty' <<<"$prev")"; [[ -n "$composed" ]] || composed="$prev_applied"
  elif [[ "$state" == waiting_human && -n "$qid" ]]; then
    composed="$(afk_pc_action_text none "" "" "$prev_applied" "$qid")"
  else
    composed="$(afk_pc_action_text none "" "$status_file_dir/$id.json" "$text_base")"
  fi

  if ! { (( ${#files[@]} > 0 )) || [[ "$composed" != "$prev_applied" || ( -n "$pending_final" && "$held_final" != true ) || "$claim_pending" == true || -n "$due" ]]; }; then
    [[ "$pm_confirmed" == true ]] && ledger="$(jq -c --arg id "$id" 'del(.issues[$id].pm_confirmed)' <<<"$ledger")"
    return 0
  fi

  local wr wh wb run_id
  wr="$(afk_pc_curl POST "$api_url/api/agents/$agent_id/wakeup" "$key" "" \
    "$(jq -nc --arg id "$id" '{source:"timer", payload:{issueId:$id}}')")"
  wh="${wr%%$'\n'*}"; wb="${wr#*$'\n'}"
  if [[ "$wh" == 401 || "$wh" == 403 ]]; then
    actions="$(jq -c --arg t "PAPERCLIP_CREDENTIAL_REJECTED: $identifier" '. + [$t]' <<<"$actions")"
    AFK_PC_ABORT=true; return
  fi
  # AC-6 (P8b): matched on the refusal's error code wherever the body
  # carries it; activeRecoveryAction is null in this case.
  if [[ "$wh" != 2?? ]] && jq -e '[.. | strings] | index("execution_reconciliation_required") != null' >/dev/null 2>&1 <<<"$wb"; then
    afk_pc_reconcile "$id" "$identifier"
    actions="$(jq -c --arg t "PAPERCLIP_RECONCILIATION_REQUIRED: $identifier" '. + [$t]' <<<"$actions")"
    return 0
  fi
  run_id="$(jq -r '.id // empty' <<<"$wb" 2>/dev/null)"
  if ! [[ "$run_id" =~ ^[A-Za-z0-9_-]+$ ]]; then # no run: the spool is untouched
    [[ -n "$due" ]] && actions="$(jq -c --arg t "self-wake returned no run, held: $identifier" '. + [$t]' <<<"$actions")"
    return 0
  fi
  ledger="$(jq -c --arg id "$id" --arg run "$run_id" '.issues[$id].last_self_wake_run_id = $run' <<<"$ledger")"

  local pr ph
  pr="$(afk_pc_curl PATCH "$api_url/api/issues/$id" "$key" "$run_id" '{"status":"in_progress"}')"
  ph="${pr%%$'\n'*}"
  if [[ "$ph" != 2?? ]]; then
    # A timeout or 5xx may still have applied in_progress: re-assert the
    # block before leaving (the invariant), whatever the reason.
    afk_pc_self_block "$api_url" "$id" "$key" "$run_id" "$agent_id" "${prev_applied:-$composed}" ||
      actions="$(jq -c --arg t "PAPERCLIP_SELF_BLOCK_FAILED: $identifier" '. + [$t]' <<<"$actions")"
    if [[ "$ph" == 401 || "$ph" == 403 ]]; then
      actions="$(jq -c --arg t "PAPERCLIP_CREDENTIAL_REJECTED: $identifier" '. + [$t]' <<<"$actions")"
      AFK_PC_ABORT=true; return
    fi
    actions="$(jq -c --arg t "report cycle could not reach in_progress, spool untouched: $identifier" '. + [$t]' <<<"$actions")"
    return 0
  fi

  # Invariant: from here on, every exit except a 404/410 (issue gone) goes
  # through the final status or the self-block below.
  local final_sent=false final_status="" stop=false cred=false storage_failed=false
  [[ -n "$pending_final" ]] && { final_sent=true; final_status="$pending_final"; }

  # AC-10: the claim comment for an issue adopted during a pause.
  if [[ "$claim_pending" == true ]]; then
    if ! afk_pc_claim_comment; then
      afk_pc_self_block "$api_url" "$id" "$key" "$run_id" "$agent_id" "$composed" ||
        actions="$(jq -c --arg t "PAPERCLIP_SELF_BLOCK_FAILED: $identifier" '. + [$t]' <<<"$actions")"
      return 0
    fi
  fi
  # F7: a resume says so once; the flag stays until the comment lands.
  if [[ "$due" == resume ]]; then
    local rsr; rsr="$(afk_pc_comment "$api_url" "$id" "$key" "$run_id" "resumed by AFK PM ($host_name)")"
    if [[ "${rsr%%$'\n'*}" == 2?? ]]; then
      due=resumed
      ledger="$(jq -c --arg id "$id" '.issues[$id].reblock_due = "nudge"' <<<"$ledger")"
    fi
  fi

  local f entry eid kind body marker outcome mrc q fs
  for f in "${files[@]:-}"; do
    [[ "$final_sent" == true ]] && break
    [[ -n "$f" ]] || continue
    entry="$(jq -c '.' "$(afk_pc_spool_dir "$id")/$f" 2>/dev/null)" || { afk_pc_spool_dead "$id" "$f" "PAPERCLIP_ENTRY_INVALID"; continue; }
    eid="$(jq -r '.id // empty' <<<"$entry" 2>/dev/null)"
    if ! afk_pc_uuid_ok "$eid"; then afk_pc_spool_dead "$id" "$f" "PAPERCLIP_ID_INVALID"; continue; fi
    kind="$(jq -r '.kind // empty' <<<"$entry")"
    body="$(jq -r '.body // empty' <<<"$entry")"
    q="$(jq -r '.question_id // empty' <<<"$entry")"
    fs="$(jq -r '.status // empty' <<<"$entry")"
    # Unknown kinds, a question without a sane id, and a final status other
    # than the two the contract allows are never posted.
    case "$kind" in
      comment) ;;
      question) [[ "$q" =~ ^[A-Za-z0-9._:-]{1,64}$ ]] || kind="" ;;
      final) [[ "$fs" == in_review || "$fs" == "done" ]] || kind="" ;;
      *) kind="" ;;
    esac
    if [[ -z "$kind" ]]; then afk_pc_spool_dead "$id" "$f" "PAPERCLIP_ENTRY_INVALID"; continue; fi
    marker="<!-- afk-entry:$eid -->"

    ledger="$(jq -c --arg id "$id" --arg eid "$eid" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.issues[$id].sending = {entry_id:$eid, issue_id:$id, at:$at}' <<<"$ledger")"
    afk_state_file_write "$ledger_path" "$ledger"

    local cr ch; cr="$(afk_pc_comment "$api_url" "$id" "$key" "$run_id" "$body"$'\n\n'"$marker")"
    ch="${cr%%$'\n'*}"
    outcome="$(afk_pc_entry_outcome "$ch")"
    if [[ "$outcome" == ambiguous ]]; then
      mrc=0; afk_pc_marker_seen "$api_url" "$key" "$id" "$marker" "$agent_id" || mrc=$?
      (( mrc == 0 )) && outcome=ok
    fi

    case "$outcome" in
      ok)
        rm -f -- "$(afk_pc_spool_dir "$id")/$f"
        ledger="$(jq -c --arg id "$id" '.issues[$id].sending = null' <<<"$ledger")"
        case "$kind" in
          question)
            # PC-3b: which entry asked, and Paperclip's own createdAt for it
            # (absent: unknown, and a plan approval is then refused).
            local q_at; q_at="$(jq -r '.createdAt // empty | strings' <<<"${cr#*$'\n'}" 2>/dev/null)"
            ledger="$(jq -c --arg id "$id" --arg q "$q" --arg at "$q_at" --argjson seq "$((10#${f%.json}))" \
              '.issues[$id].state = "waiting_human" | .issues[$id].question_id = $q | .issues[$id].question_seq = $seq
               | .issues[$id].question_sent_at = (if $at == "" then null else $at end)' <<<"$ledger")"
            ;;
          final)
            final_sent=true; final_status="$fs"
            ledger="$(jq -c --arg id "$id" --arg s "$fs" '.issues[$id].pending_final = $s' <<<"$ledger")"
            afk_state_file_write "$ledger_path" "$ledger"
            ;;
        esac
        ;;
      dead)
        afk_pc_spool_dead "$id" "$f" "PAPERCLIP_ENTRY_REJECTED"
        ledger="$(jq -c --arg id "$id" '.issues[$id].sending = null' <<<"$ledger")"
        ;;
      gone)
        ledger="$(jq -c --arg id "$id" '.issues[$id].state = "closed" | .issues[$id].sending = null' <<<"$ledger")"
        afk_pc_spool_dead_all "$id"
        actions="$(jq -c --arg t "stopped (404/410): $identifier" '. + [$t]' <<<"$actions")"
        return 0
        ;;
      credential)
        actions="$(jq -c --arg t "PAPERCLIP_CREDENTIAL_REJECTED: $identifier" '. + [$t]' <<<"$actions")"
        cred=true; stop=true
        ;;
      backoff)
        actions="$(jq -c --arg t "PAPERCLIP_RATE_LIMITED, kept: $identifier" '. + [$t]' <<<"$actions")"
        stop=true
        ;;
      conflict | ambiguous)
        stop=true
        ;;
    esac
    [[ "$stop" == true ]] && break
  done

  if [[ "$final_sent" == true && "$cred" == false && "$held_final" != true ]]; then
    local fr fh
    fr="$(afk_pc_curl PATCH "$api_url/api/issues/$id" "$key" "$run_id" "$(jq -nc --arg s "$final_status" '{status:$s}')")"
    fh="${fr%%$'\n'*}"
    if [[ "$fh" == 2?? ]]; then
      ledger="$(jq -c --arg id "$id" '.issues[$id].state = "closed" | del(.issues[$id].pending_final, .issues[$id].final_delivery_hold, .issues[$id].reblock_due)' <<<"$ledger")"
      afk_pc_spool_dead_all "$id"
      [[ "$due" == strand ]] && actions="$(jq -c --arg t "PAPERCLIP_STRAND_REPAIRED: $identifier" '. + [$t]' <<<"$actions")"
      actions="$(jq -c --arg t "final ($final_status): $identifier" '. + [$t]' <<<"$actions")"
      return 0
    fi
    # A 400/422 is a permanent validation rejection for this exact intent.
    # Persist the hold before re-blocking; a crash cannot re-enable retries.
    if [[ "$fh" == 400 || "$fh" == 422 ]]; then
      local hold diagnostic
      hold="$(afk_pc_final_hold "$fh" "${fr#*$'\n'}" "$final_status" "$run_id")"
      ledger="$(jq -c --arg id "$id" --argjson hold "$hold" '.issues[$id].final_delivery_hold = $hold' <<<"$ledger")"
      if ! afk_state_file_write "$ledger_path" "$ledger"; then
        AFK_PC_STORAGE_ERROR=true
        AFK_PC_ABORT=true
        actions="$(jq -c --arg t "PAPERCLIP_STORAGE_ERROR: final delivery hold was not saved for $identifier" '. + [$t]' <<<"$actions")"
        # The self-block below is remote and still owed (the invariant).
        storage_failed=true
      else
        diagnostic="PAPERCLIP_FINAL_DELIVERY_HELD ($fh"
        [[ "$(jq -r '.code // empty' <<<"$hold")" == invalid_issue_disposition ]] && diagnostic+=" invalid_issue_disposition"
        [[ "$(jq -r '.missing_field // empty' <<<"$hold")" == review_path ]] && diagnostic+=" missing review_path"
        diagnostic+="): $identifier"
        actions="$(jq -c --arg t "$diagnostic" '. + [$t]' <<<"$actions")"
      fi
    elif [[ "$fh" == 401 || "$fh" == 403 ]]; then
      cred=true
      actions="$(jq -c --arg t "PAPERCLIP_CREDENTIAL_REJECTED: $identifier" '. + [$t]' <<<"$actions")"
    else
      # Transport, rate-limit and conflict retain their retry behavior and
      # never acquire a validation hold.
      actions="$(jq -c --arg t "final status not applied, retrying next pass: $identifier" '. + [$t]' <<<"$actions")"
    fi
  fi

  # Recompute against the post-loop state: a question entry sent above may
  # have just moved this issue to waiting_human, and the self-block text must
  # reflect that in this same cycle, not the pre-loop state (AC-2).
  local post_state post_qid final_composed
  post_state="$(jq -r --arg id "$id" '.issues[$id].state // empty' <<<"$ledger")"
  post_qid="$(jq -r --arg id "$id" '.issues[$id].question_id // empty' <<<"$ledger")"
  if [[ -n "$fixed" ]]; then
    final_composed="$fixed"
  elif [[ "$post_state" == queued ]]; then
    final_composed="$(jq -r --arg id "$id" '.issues[$id].action_text // empty' <<<"$ledger")"; [[ -n "$final_composed" ]] || final_composed="$prev_applied"
  elif [[ "$post_state" == waiting_human && -n "$post_qid" ]]; then
    final_composed="$(afk_pc_action_text none "" "" "$prev_applied" "$post_qid")"
  else
    final_composed="$(afk_pc_action_text none "" "$status_file_dir/$id.json" "$text_base")"
  fi

  if afk_pc_self_block "$api_url" "$id" "$key" "$run_id" "$agent_id" "$final_composed"; then
    ledger="$(jq -c --arg id "$id" --arg t "$final_composed" --argjson keep "$([[ "$due" == resume ]] && echo true || echo false)" \
      '.issues[$id].action_text = $t | .issues[$id].action_text_applied = $t
       | del(.issues[$id].pm_confirmed)
       | if $keep then . else del(.issues[$id].reblock_due) end' <<<"$ledger")"
    [[ "$due" == strand ]] && actions="$(jq -c --arg t "PAPERCLIP_STRAND_REPAIRED: $identifier" '. + [$t]' <<<"$actions")"
  else
    actions="$(jq -c --arg t "PAPERCLIP_SELF_BLOCK_FAILED: $identifier" '. + [$t]' <<<"$actions")"
  fi
  [[ "$storage_failed" == true ]] && return 1
  [[ "$cred" == true ]] && { AFK_PC_ABORT=true; return; }
  actions="$(jq -c --arg t "report cycle: $identifier" '. + [$t]' <<<"$actions")"
}

# --- the Josh test (AC-8) ----------------------------------------------------
# 0: a Josh comment. 1: not Josh. 2: unverifiable (no authorAgentId key at all).
afk_pc_is_josh_comment() { # <comment-json> <board_user_id>
  local v
  # One typed jq test: a JSON null, not the string "null", and a string match.
  v="$(jq -r --arg b "$2" 'if (type != "object") or (has("authorAgentId") | not) then "unverifiable"
    elif .authorAgentId == null and .authorUserId == $b then "josh" else "other" end' <<<"$1" 2>/dev/null)"
  case "$v" in josh) return 0 ;; other) return 1 ;; *) return 2 ;; esac
}

# --- AFK-PC-2b: the PM-start classification hook -----------------------------
# Called at both `claimed`-notice sites and from the report-sweep retry below.
# Reads the caller's api_url/key/
# company_id/board_user_id/host_name/agent_id/id/identifier/slug/
# repo_path/harness/detail/ledger/actions locals directly, exactly like
# afk_pc_strand. Sets AFK_PCS_ACTION_OVERRIDE (empty when the normal action
# text stands) and never puts a Paperclip byte into a terminal, prompt, argv,
# or the bootstrap intent — see lib/afk-paperclip-start.sh.
afk_pc_maybe_start_pm() {
  AFK_PCS_ACTION_OVERRIDE=""
  declare -F afk_pcs_start_pm >/dev/null 2>&1 || return 0
  [[ -z "${pm_start_checked_this_pass[$id]:-}" ]] 2>/dev/null || return 0
  pm_start_checked_this_pass[$id]=1
  afk_pcs_start_pm
}

# Retry a reported PM hold using locals scoped to this helper so it cannot
# overwrite the report loop's current issue or project context.
afk_pc_retry_report_pm_start() { # <issue-id> <host-agent-id>
  local retry_id="$1" retry_agent="$2" issue_row issue_state issue_host issue_hold retry_cfg
  local id identifier slug repo_path harness detail start_row retry_status retry_assignee retry_owner retry_project retry_pin retry_recovery
  issue_row="$(jq -c --arg id "$retry_id" '.issues[$id] // {}' <<<"$ledger")"
  issue_state="$(jq -r '.state // empty' <<<"$issue_row")"
  issue_host="$(jq -r '.host_agent_id // empty' <<<"$issue_row")"
  issue_hold="$(jq -r '.action_text // .action_text_applied // empty' <<<"$issue_row")"
  case "$issue_state" in working | queued | waiting_human) : ;; *) return 0 ;; esac
  [[ "$issue_host" == "$retry_agent" ]] || return 0
  [[ "$issue_hold" == *"no PM"* || "$issue_hold" == *"PM state"* ]] || return 0
  [[ -z "${pm_start_checked_this_pass[$retry_id]:-}" ]] || return 0
  start_row="$(jq -r --arg id "$retry_id" '.pm_started[$id].state // empty' <<<"$ledger")"
  [[ "$start_row" != created && "$start_row" != live && "$start_row" != ended ]] || return 0

  id="$retry_id"
  identifier="$(jq -r '.identifier // empty' <<<"$issue_row")"
  held_start_authority[$id]=unknown
  local issue_resp; issue_resp="$(afk_pc_curl GET "$api_url/api/issues/$id" "$key" "")"
  [[ "${issue_resp%%$'\n'*}" == 2?? ]] || return 0
  detail="${issue_resp#*$'\n'}"
  retry_status="$(jq -r '.status // empty' <<<"$detail")"
  retry_assignee="$(jq -r '.assigneeAgentId // empty' <<<"$detail")"
  retry_owner="$(jq -r '.unblockDescriptor.owner.agentId // empty' <<<"$detail")"
  retry_project="$(jq -r '.projectId // empty | strings | ascii_downcase' <<<"$detail")"
  retry_pin="$(jq -r '.paperclip_project_id // empty | ascii_downcase' <<<"$issue_row")"
  retry_recovery="$(jq -r '.activeRecoveryAction | select(.status == "active" and .ownerType == "board") // empty' <<<"$detail")"
  [[ "$retry_status" =~ ^(todo|in_progress|blocked)$ ]] || { held_start_authority[$id]=ineligible; return 0; }
  [[ -z "$retry_assignee" || "$retry_assignee" == "$retry_agent" ]] || { held_start_authority[$id]=ineligible; return 0; }
  [[ -z "$retry_owner" || "$retry_owner" == "$retry_agent" ]] || { held_start_authority[$id]=ineligible; return 0; }
  [[ "$retry_assignee" == "$retry_agent" || "$retry_owner" == "$retry_agent" ]] || { held_start_authority[$id]=ineligible; return 0; }
  [[ -z "$retry_recovery" ]] || { held_start_authority[$id]=ineligible; return 0; }
  [[ -n "$retry_pin" && "$retry_project" == "$retry_pin" ]] || { held_start_authority[$id]=ineligible; return 0; }
  retry_cfg="$(jq -c --arg s "$(jq -r '.slug // empty' <<<"$issue_row")" --arg p "$retry_pin" \
    '.projects[] | select(.slug == $s and .paperclip_project_id == $p)' <<<"$AFK_PC_CFG")"
  [[ -n "$retry_cfg" ]] || { held_start_authority[$id]=ineligible; return 0; }
  held_start_authority[$id]=eligible
  [[ "$(jq -r '.pm_start_enabled // false' <<<"$AFK_PC_CFG")" == true ]] || return 0
  slug="$(jq -r '.slug' <<<"$retry_cfg")"
  repo_path="$(jq -r '.repo_path' <<<"$retry_cfg")"
  harness="$(jq -r '.harness' <<<"$retry_cfg")"
  local AFK_PCS_ACTION_OVERRIDE=""
  afk_pc_maybe_start_pm
  if [[ -n "$AFK_PCS_ACTION_OVERRIDE" ]]; then
    ledger="$(jq -c --arg id "$id" --arg t "$AFK_PCS_ACTION_OVERRIDE" \
      '.issues[$id].action_text = $t' <<<"$ledger")"
  fi
}

# --- shared by the pass's branches (HA-4a) -----------------------------------
# Each reads and writes the pass's locals directly, like afk_pc_strand, so
# each must be a direct call, never `$(...)`.

# afk_pc_ts_after <a> <b> -- 0 only when both are UTC instants written
# `YYYY-MM-DDTHH:MM:SS[.fraction]Z` and <a> is strictly later than <b>. A
# missing or unparseable time is never later (fail closed).
afk_pc_ts_after() {
  jq -en --arg a "$1" --arg b "$2" '
    def t: if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?Z$")
      then [((.[0:19] + "Z") | fromdateiso8601), ((.[20:] | rtrimstr("Z")) + "000000000" | .[0:9] | tonumber)]
      else null end;
    ($a | try t catch null) as $x | ($b | try t catch null) as $y
    | $x != null and $y != null and $x > $y' >/dev/null 2>&1
}

# afk_pc_record_reply <comment-id> <created-at> <body> -- a Josh comment the
# plan hook did not take answers the issue's latest question when that
# question is not a plan question and the comment was created strictly after
# it was sent. A decision-shaped body (trimmed, exactly `approve|reject
# <digest8>`) never answers one, whether or not the hook took it. The first
# such comment is kept as question_reply, bound to the question's id and seq;
# a newer question leaves it stale and is answered only by a reply of its
# own. Local metadata only: nothing is sent, no state or approval changes,
# and it means a reply arrived, not that the work was accepted.
afk_pc_record_reply() {
  local LC_ALL=C row next b="$3"
  b="${b#"${b%%[![:space:]]*}"}"; b="${b%"${b##*[![:space:]]}"}"
  [[ "$b" =~ ^(approve|reject)\ [0-9a-f]{8}$ ]] && return 0
  row="$(jq -c --arg id "$id" '.issues[$id] | objects' <<<"$ledger" 2>/dev/null)"
  [[ -n "$row" ]] || return 0
  jq -e '(.question_id | type == "string" and length > 0 and (startswith("plan-") | not))
    and (.question_seq | type == "number")
    and ((.question_reply | type) != "object" or .question_reply.question_id != .question_id
         or .question_reply.question_seq != .question_seq)' <<<"$row" >/dev/null 2>&1 || return 0
  afk_pc_ts_after "$2" "$(jq -r '.question_sent_at // empty | strings' <<<"$row")" || return 0
  next="$(jq -c --arg id "$id" --arg c "$1" --arg ca "$2" \
    '.issues[$id] |= (.question_reply = {question_id, question_seq, comment_id:$c, created_at:$ca})' <<<"$ledger" 2>/dev/null)" &&
    [[ -n "$next" ]] && ledger="$next"
  return 0
}

# afk_pc_scan_comments -- Josh's comments newer than `since` on an issue this
# host holds: a plan decision (PC-3b), or a human_commented notice and reply,
# which may also record the latest question's question_reply.
# Used by the blocked branch and the todo nudge (P6d); moves newest_since.
afk_pc_scan_comments() {
  local comments_resp comments_body c ccreated rc cid2
  comments_resp="$(afk_pc_curl GET "$api_url/api/issues/$id/comments" "$key" "")"
  comments_body="${comments_resp#*$'\n'}"
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    ccreated="$(jq -r '.createdAt // empty' <<<"$c")"
    [[ -z "$since" || "$ccreated" > "$since" ]] || continue
    rc=0; afk_pc_is_josh_comment "$c" "$board_user_id" || rc=$?
    if (( rc == 2 )); then
      if [[ "$author_unverifiable_reported" == false ]]; then
        author_unverifiable_reported=true
        actions="$(jq -c '. + ["PAPERCLIP_AUTHOR_UNVERIFIABLE"]' <<<"$actions")"
      fi
    elif (( rc == 0 )); then
      cid2="$(jq -r '.id // empty' <<<"$c")"
      afk_pc_uuid_ok "$cid2" || continue # AC-1: ids used in file paths
      # PC-3b: an exact `approve|reject <digest8>` on the open plan
      # question is decided there; anything else is a plain comment.
      if declare -F afk_pcp_on_josh_comment >/dev/null 2>&1 &&
         afk_pcp_on_josh_comment "$c" "$cid2" "$ccreated"; then
        [[ -z "$newest_since" || "$ccreated" > "$newest_since" ]] && newest_since="$ccreated"
        continue
      fi
      afk_pc_record_reply "$cid2" "$ccreated" "$(jq -r '.body | strings' <<<"$c" 2>/dev/null)"
      afk_pc_notice "$slug" "$id" "$identifier" "$agent_id" "$repo_path" "$harness" human_commented \
        "$(jq -nc --arg cid "$cid2" --arg ca "$ccreated" --arg q "${qid:-}" \
          'if $q == "" then {comment_id:$cid, created_at:$ca, open_question_id:null} else {comment_id:$cid, created_at:$ca, open_question_id:$q} end')"
      afk_pc_reply "$slug" "$cid2" "$(jq -r '.body // empty' <<<"$c")"
      actions="$(jq -c --arg t "human_commented: $identifier" '. + [$t]' <<<"$actions")"
    fi
    [[ -z "$newest_since" || "$ccreated" > "$newest_since" ]] && newest_since="$ccreated"
  done < <(jq -c '.[]' <<<"$comments_body" 2>/dev/null)
}

# afk_pc_pin_new -- F6: pin a freshly resolved issue to its project as
# pending_claim. Carry only ordering fields; claim receipts belong to one
# adoption and must be reset when a closed issue returns.
afk_pc_pin_new() {
  local since; since="$(jq -r --arg id "$id" '.issues[$id].since // empty' <<<"$ledger")"
  [[ -n "$since" ]] || since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ledger="$(jq -c --arg id "$id" --arg a "$agent_id" --arg s "$slug" --arg p "$resolved_pid" --arg ident "$identifier" \
    --arg t "$(afk_pc_action_text none "" "" "")" --arg since "$since" \
    '.issues[$id] = {host_agent_id:$a, paperclip_project_id:$p, slug:$s, identifier:$ident,
       since:$since, state:"pending_claim", action_text:$t,
       claimed_notice_epoch:(.issues[$id].claimed_notice_epoch // 0),
       claim_artifact_counter:(.issues[$id].claim_artifact_counter // 0)}' <<<"$ledger")"
}

# afk_pc_claim <set-queue-text:true|false> -- the claim of a pending_claim
# issue: claimed notice, brief, a slot or the queue (AD-24). Sets the
# caller's final_state; the claim comment goes out in the report cycle.
afk_pc_claim() {
  ledger="$(jq -c --arg id "$id" '.issues[$id].claim = "intent" |
    .issues[$id].claim_comment_pending = true' <<<"$ledger")"
  afk_state_file_write "$ledger_path" "$ledger" || return 1
  afk_pc_claim_artifacts || return 1
  if (( used_slots_s >= max_active || host_used >= host_max )); then
    final_state="queued"; newly_queued_ids+="$id"$'\n'
    [[ "$1" == true ]] && ledger="$(jq -c --arg id "$id" --arg t "$(afk_pc_queue_text)" \
      '.issues[$id].action_text = $t' <<<"$ledger")"
  else
    final_state="working"
    used_slots_s=$((used_slots_s + 1)); host_used=$((host_used + 1))
    working_id="$identifier"
  fi
  actions="$(jq -c --arg t "claimed: $identifier" '. + [$t]' <<<"$actions")"
}

# afk_pc_no_run <active-run response> -- 0 only for a clean "no run": 200 or
# 204 whose body is empty, null, or an object with no id at all. A malformed
# id, a body that isn't JSON, or any other status may hide a live run the
# host didn't start, so the caller holds instead.
afk_pc_no_run() {
  local h="${1%%$'\n'*}" b="${1#*$'\n'}"
  [[ "$h" == 200 || "$h" == 204 ]] || return 1
  [[ -z "${b//[[:space:]]/}" ]] && return 0
  jq -e 'type == "null" or (type == "object" and .id == null)' >/dev/null 2>&1 <<<"$b"
}

# afk_pc_close_recovery -- a resumed stranded issue's recovery issue is done.
afk_pc_close_recovery() {
  local recid rec_resp
  recid="$(jq -r --arg id "$id" '.issues[$id].recovery_issue_id // empty' <<<"$ledger")"
  afk_pc_uuid_ok "$recid" || return 0
  rec_resp="$(afk_pc_curl PATCH "$api_url/api/issues/$recid" "$key" "" '{"status":"done"}')"
  [[ "${rec_resp%%$'\n'*}" == 2?? ]] ||
    actions="$(jq -c --arg t "recovery issue for $identifier not closed (needs a run), left open" '. + [$t]' <<<"$actions")"
}

# --- the pass (AC-3..AC-10) ---------------------------------------------------
afk_cmd_paperclip_poll() { # <json_mode>
  local -; set +x # the key lives in locals below; never trace them
  local json_mode="$1"
  if ! afk_pc_load_config; then
    afk_pc_emit_refusal "$AFK_PC_REFUSAL" "$json_mode"
    return 1
  fi

  local api_url company_id board_user_id host_name maint agent_id key_ref adoption
  api_url="$(jq -r '.api_url' <<<"$AFK_PC_CFG")"
  company_id="$(jq -r '.company_id' <<<"$AFK_PC_CFG")"
  board_user_id="$(jq -r '.board_user_id' <<<"$AFK_PC_CFG")"
  host_name="$(jq -r '.host.label' <<<"$AFK_PC_CFG")"
  agent_id="$(jq -r '.host.agent_id' <<<"$AFK_PC_CFG")"
  key_ref="$(jq -r '.host.key_ref' <<<"$AFK_PC_CFG")"
  maint="$(jq -r '.maintenance_issue_id // empty' <<<"$AFK_PC_CFG")"
  adoption="$(jq -r '.host.adoption' <<<"$AFK_PC_CFG")"

  local pc_dir="$AFK_STATE_DIR/paperclip"
  afk_state_dir_ensure "$pc_dir"
  local lockdir="$pc_dir/.lock"
  if ! mkdir "$lockdir" 2>/dev/null; then
    # AC-7b: the lock carries no owner record before this story. A `kill -9`
    # or reboot leaves it forever busy, so a lock old enough (5x the poll
    # interval) whose owner PID is provably gone is reaped once, then retried.
    if ! { declare -F afk_pcs_lock_stale_reap >/dev/null 2>&1 &&
           afk_pcs_lock_stale_reap "$lockdir" "${AFK_PAPERCLIP_POLL_INTERVAL_SECONDS:-90}" &&
           mkdir "$lockdir" 2>/dev/null; }; then
      afk_pc_emit_refusal "PAPERCLIP_POLL_BUSY" "$json_mode"
      return 0
    fi
    afk_warn "PAPERCLIP_LOCK_STALE: reaped a poll lock left by a dead pass"
  fi
  printf '%s %s\n' "$$" "$(date +%s)" >"$lockdir/owner" 2>/dev/null || true
  # Chain the entry point's own EXIT handler rather than replacing it.
  # %q-quote the path: a bare single-quote wrap breaks if the state dir
  # itself ever contains a single quote.
  local lockdir_q; printf -v lockdir_q '%q' "$lockdir"
  # shellcheck disable=SC2064
  trap "rm -f $lockdir_q/owner 2>/dev/null; rmdir $lockdir_q 2>/dev/null; declare -F afk_release_on_exit >/dev/null && afk_release_on_exit" EXIT

  local ledger_path="$pc_dir/ledger.json" ledger=""
  if [[ -r "$ledger_path" ]]; then
    ledger="$(jq -c '.' "$ledger_path" 2>/dev/null)" || ledger=""
  fi
  [[ -n "$ledger" ]] || ledger='{"issues":{},"stranded_reported":[],"drain_tampered_reported":false,"last_successful_pass":null}'

  local stop_flag="${HOME:-}/.config/agent-flow-kit/paperclip/stop"
  local pause_kind=none author_unverifiable_reported=false
  [[ -e "$stop_flag" ]] && pause_kind=stopped

  # One host, one key (AD-23): read once, used for every project this host
  # serves. `while` runs once; an early `break` is a pass that did not
  # complete.
  local any_agent_ok=false result="" actions="[]" key="" AFK_PC_STORAGE_ERROR=false
  local stop_text="Stopped: project changed after claim; reassign to restart"
  while :; do
    key="$(afk_pc_read_key "$key_ref")" || { result="$(afk_pc_key_code $?)"; break; }

    local me_resp me_body me_http
    me_resp="$(afk_pc_curl GET "$api_url/api/agents/me" "$key" "")"
    me_http="${me_resp%%$'\n'*}"; me_body="${me_resp#*$'\n'}"
    if [[ "$me_http" == 401 || "$me_http" == 403 ]]; then result="PAPERCLIP_KEY_UNAUTHORIZED"; break; fi
    [[ "$me_http" == 200 ]] || { result="unreachable"; break; }
    if [[ "$(jq -r '.id // empty' <<<"$me_body")" != "$agent_id" ]]; then
      result="PAPERCLIP_KEY_AGENT_MISMATCH"; break
    fi
    # AD-26 (F2): the agent's heartbeat must match host.adoption on every
    # pass. A mismatch, or a /me without the fields, claims and writes
    # nothing. The poller never writes the agent's config.
    if ! jq -e --arg m "$adoption" '.runtimeConfig.heartbeat as $h | if $m == "pull"
         then $h.enabled == true and $h.intervalSec == 0 and $h.wakeOnDemand == false
         else $h.wakeOnDemand == true end' >/dev/null 2>&1 <<<"$me_body"; then
      result="PAPERCLIP_ADOPTION_MODE_MISMATCH"; break
    fi

    afk_pc_compute_pause "$api_url" "$key" "$maint" "$board_user_id" "$company_id" "$pause_kind"
    pause_kind="$AFK_PC_PAUSE_KIND"

    local inbox_resp inbox_http inbox_body ids status_file_dir
    inbox_resp="$(afk_pc_curl GET "$api_url/api/agents/me/inbox-lite" "$key" "")"
    inbox_http="${inbox_resp%%$'\n'*}"; inbox_body="${inbox_resp#*$'\n'}"
    # A non-array inbox must never read as "every ledger issue closed", and it
    # must never count as a completed pass either (AC-3). Any
    # PAPERCLIP_DRAIN_* action already queued (afk_pc_compute_pause) is
    # carried into the reported entry, not dropped.
    if [[ "$inbox_http" != 200 ]] || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$inbox_body"; then
      result="unreachable"; break
    fi
    any_agent_ok=true
    result=completed
    # A refused issue that resolves is adopted in `since` order: issues this
    # host already knows go first, oldest first; new ones keep inbox order.
    mapfile -t ids < <(printf '%s\n%s\n' "$inbox_body" "$ledger" | jq -rs \
      '.[1] as $l | [.[0][].id | strings] | to_entries | sort_by([($l.issues[.value].since // "~"), .key]) | .[].value')
    status_file_dir="$AFK_STATE_DIR/paperclip/status"

    local -A pm_start_checked_this_pass=() held_start_authority=()
    if [[ "$pause_kind" == none ]]; then
      # Retry held queued starts before inbox reconciliation can close an
      # issue omitted from inbox-lite. This path does not create a report cycle.
      local -a held_start_ids=()
      mapfile -t held_start_ids < <(jq -r --arg a "$agent_id" \
        '.issues | to_entries[] | select(.value.host_agent_id == $a and .value.state == "queued"
          and ((.value.action_text // .value.action_text_applied // "") | test("no PM|PM state"))) | .key' <<<"$ledger")
      local held_id
      for held_id in "${held_start_ids[@]:-}"; do
        [[ -n "$held_id" ]] || continue
        afk_pc_retry_report_pm_start "$held_id" "$agent_id"
      done
    fi

    # AC-5d: ledger issues no longer present in the inbox.
    local closed_ids; mapfile -t closed_ids < <(jq -r --arg a "$agent_id" \
      --argjson present "$(printf '%s\n' "${ids[@]:-}" | jq -R -s -c 'split("\n") | map(select(length > 0))')" \
      '.issues | to_entries[] | select(.value.host_agent_id == $a and (.value.state != "closed") and ([.key] - $present | length) == 1) | .key' \
      <<<"$ledger")
    local cid
    for cid in "${closed_ids[@]:-}"; do
      [[ -n "$cid" ]] || continue
      [[ "${held_start_authority[$cid]:-}" == eligible || "${held_start_authority[$cid]:-}" == unknown ]] && continue
      local cidentifier cstate crow
      cidentifier="$(jq -r --arg id "$cid" '.issues[$id].identifier // empty' <<<"$ledger")"
      cstate="$(jq -r --arg id "$cid" '.issues[$id].state // empty' <<<"$ledger")"
      ledger="$(jq -c --arg id "$cid" '.issues[$id].state = "closed"' <<<"$ledger")"
      # A refused or already-stopped issue has no PM to tell.
      if [[ "$cstate" != waiting_setup && "$cstate" != stopped && "$cstate" != reconciliation_blocked ]]; then
        crow="$(afk_pc_project_row "$(jq -r --arg id "$cid" '.issues[$id].slug // empty' <<<"$ledger")")"
        [[ -n "$crow" ]] && afk_pc_notice "$(jq -r .slug <<<"$crow")" "$cid" "$cidentifier" "$agent_id" \
          "$(jq -r .repo_path <<<"$crow")" "$(jq -r .harness <<<"$crow")" stopped
      fi
      # PC-1b AC-6: closed or no-longer-in-inbox issues never keep spool
      # entries around; frozen (deletes nothing) while paused, like everything else.
      [[ "$pause_kind" == none ]] && afk_pc_spool_dead_all "$cid"
      actions="$(jq -c --arg t "stopped: $cidentifier" '. + [$t]' <<<"$actions")"
    done

    # Slots are per project (max_active_issues on its row). Computed after
    # the closed-issue loop above, so an issue that just dropped out of the
    # inbox never counts as a held working slot for the issues below.
    # HA-2 (AD-24): `working` and `waiting_human` hold a slot; nothing else does.
    # host_used is the host-wide count against host.max_active_issues.
    local -A used_slots=() working_ids=() promotable=() claim_started_this_pass=()
    local newly_queued_ids=""
    local s_slug s_n s_w host_max host_used
    host_max="$(jq -r '.host.max_active_issues' <<<"$AFK_PC_CFG")"
    host_used="$(jq -r --arg a "$agent_id" '[.issues[] | select(.host_agent_id == $a and (.state | IN("working", "waiting_human")))] | length' <<<"$ledger")"
    while IFS=$'\x1f' read -r s_slug s_n s_w; do
      [[ -n "$s_slug" ]] || continue
      used_slots[$s_slug]="$s_n"; working_ids[$s_slug]="$s_w"
    done < <(jq -r --argjson c "$AFK_PC_CFG" --arg a "$agent_id" \
      '. as $l | $c.projects[].slug as $s | [$l.issues[] | select(.host_agent_id == $a and .slug == $s and (.state | IN("working", "waiting_human")))]
       | [$s, (length | tostring), (.[0].identifier // "" | gsub("[[:cntrl:]]"; ""))] | join("\u001f")' <<<"$ledger")

    local id
    for id in "${ids[@]:-}"; do
      [[ -n "$id" ]] || continue
      afk_pc_uuid_ok "$id" || continue
      local detail_resp detail dhttp
      detail_resp="$(afk_pc_curl GET "$api_url/api/issues/$id" "$key" "")"
      dhttp="${detail_resp%%$'\n'*}"; detail="${detail_resp#*$'\n'}"
      [[ "$dhttp" == 200 ]] || continue
      local status identifier title desc updated owner_agent owner_user prev prev_st
      status="$(jq -r '.status' <<<"$detail")"
      identifier="$(jq -r '.identifier' <<<"$detail")"
      title="$(jq -r '.title' <<<"$detail")"
      desc="$(jq -r '.description' <<<"$detail")"
      updated="$(jq -r '.updatedAt' <<<"$detail")"
      owner_agent="$(jq -r '.unblockDescriptor.owner.agentId // empty' <<<"$detail")"
      owner_user="$(jq -r '.unblockDescriptor.owner.userId // empty' <<<"$detail")"
      prev="$(jq -c --arg id "$id" '.issues[$id] // empty' <<<"$ledger")"
      if [[ -n "$prev" ]] && jq -e '.claim_comment_pending == true and .claim_attempted == true' \
          <<<"$prev" >/dev/null 2>&1; then
        afk_pc_claim_comment || true
        [[ "${AFK_PC_ABORT:-false}" == true ]] && break
        prev="$(jq -c --arg id "$id" '.issues[$id] // empty' <<<"$ledger")"
      fi

      # --- which project (AD-23): the pin, or a fresh resolution ------------
      # slug/repo_path/harness/max_active are what every notice, brief, PM
      # start and verb below reads. They come from the host's projects[] row
      # only, never from issue text or the project's name.
      local slug="" repo_path="" harness="" max_active=1 row="" pin_pid="" pin_slug="" live_pid="" resolved_pid="" fresh=false
      IFS=$'\x1f' read -r prev_st pin_pid pin_slug live_pid < <(jq -r --argjson p "${prev:-null}" \
        '[($p.state // ""), ($p.paperclip_project_id // ""), ($p.slug // ""), (.projectId // "" | strings | ascii_downcase)]
         | map(tostring | gsub("[[:cntrl:]]"; "")) | join("\u001f")' <<<"$detail")
      # AC-6: parked until the issue is closed or leaves this host (the
      # closed-issue sweep above); one local report per pass meanwhile.
      if [[ "$prev_st" == reconciliation_blocked ]]; then
        if [[ "$status" == cancelled || "$status" == "done" ]]; then
          ledger="$(jq -c --arg id "$id" '.issues[$id].state = "closed"' <<<"$ledger")"
        else
          afk_pc_recon_issue "$id" "$identifier"
          actions="$(jq -c --arg t "PAPERCLIP_RECONCILIATION_REQUIRED, held: $identifier" '. + [$t]' <<<"$actions")"
        fi
        continue
      fi
      if [[ -n "$pin_pid" && "$prev_st" != closed && "$prev_st" != stopped && "$prev_st" != waiting_setup ]]; then
        row="$(afk_pc_project_row "$pin_slug")"
        local changed=false
        if [[ "$status" != cancelled && "$status" != "done" ]]; then
          if [[ "$live_pid" != "$pin_pid" ]]; then
            changed=true
          else
            # A deleted project can leave a dangling id: three consecutive
            # 404s on the pinned project count as a change (F6, F11).
            local pr_resp; pr_resp="$(afk_pc_curl GET "$api_url/api/projects/$pin_pid" "$key" "")"
            afk_pc_count_404 "${pr_resp%%$'\n'*}"
            (( AFK_PC_404_N >= 3 )) && changed=true
          fi
        fi
        if [[ "$changed" == true ]]; then
          afk_pc_project_changed
          continue
        fi
        if [[ -z "$row" ]]; then
          actions="$(jq -c --arg t "PAPERCLIP_PROJECT_UNMAPPED (pinned project no longer on this host), held: $identifier" '. + [$t]' <<<"$actions")"
          continue
        fi
      elif [[ "$prev_st" == stopped ]]; then
        # Stopped for a project change: nothing more to do here until the
        # issue leaves this host. A Paperclip wake is re-blocked at once; the
        # report cycle otherwise keeps the stop text applied.
        [[ "$status" == cancelled || "$status" == "done" ]] &&
          ledger="$(jq -c --arg id "$id" '.issues[$id].state = "closed"' <<<"$ledger")"
        if [[ "$status" == in_progress ]]; then
          local sresp sr; sresp="$(afk_pc_curl GET "$api_url/api/issues/$id/active-run" "$key" "")"
          sr="$(jq -r '.id // empty' <<<"${sresp#*$'\n'}" 2>/dev/null)"
          if [[ "$sr" =~ ^[A-Za-z0-9_-]+$ ]]; then
            afk_pc_self_block "$api_url" "$id" "$key" "$sr" "$agent_id" "$stop_text" &&
              ledger="$(jq -c --arg id "$id" --arg t "$stop_text" '.issues[$id].action_text_applied = $t' <<<"$ledger")"
          elif afk_pc_no_run "$sresp"; then
            ledger="$(jq -c --arg id "$id" '.issues[$id].reblock_due //= "strand"' <<<"$ledger")"
          else
            actions="$(jq -c --arg t "active run unreadable, held: $identifier" '. + [$t]' <<<"$actions")"
          fi
        fi
        # A comment reopened it (P6d): put the stop text back.
        [[ "$status" == todo ]] && ledger="$(jq -c --arg id "$id" '.issues[$id].reblock_due //= "nudge"' <<<"$ledger")"
        continue
      elif [[ ( ( -z "$prev" || "$prev_st" == closed ) && ( "$status" == in_progress || ( "$adoption" == pull && "$status" == todo ) ) ) ||
              ( "$prev_st" == waiting_setup && "$status" =~ ^(in_progress|blocked|todo)$ ) ]]; then
        # A new issue (in pull mode also one still in todo, AC-3), a closed
        # one reassigned back to this host (a restart, re-pinned from
        # scratch), or a refused one: resolve the live projectId.
        afk_pc_resolve "$detail" "$identifier"
        [[ "$AFK_PC_RES" == PAPERCLIP_PROJECT_UNREADABLE ]] && continue # no write this pass
        if [[ "$AFK_PC_RES" != ok ]]; then
          afk_pc_waiting_setup
          # Never left in todo: the report cycle self-blocks it with the reason.
          [[ "$status" == todo ]] && ledger="$(jq -c --arg id "$id" '.issues[$id].reblock_due //= "setup"' <<<"$ledger")"
          continue
        fi
        row="$AFK_PC_RES_ROW"; resolved_pid="$AFK_PC_RES_PID"
        # A previously refused or closed issue that now resolves is adopted
        # as new: its row is replaced (only `since` carried over) where it is
        # actually adopted below. Until then the old row stays, so a pass that
        # cannot adopt it yet (no live run, a board hold) re-resolves it next time.
        if [[ -n "$prev" ]]; then
          fresh=true
          # A restart after a final: reopen the spool and drop the old declared
          # status, or the new PM's first report is refused as closed.
          [[ "$prev_st" == closed ]] && afk_pc_spool_reopen "$id"
          prev=""; prev_st=""
        fi
      elif [[ "$prev_st" == waiting_setup && ( "$status" == cancelled || "$status" == "done" ) ]]; then
        ledger="$(jq -c --arg id "$id" '.issues[$id].state = "closed"' <<<"$ledger")"
        continue
      fi
      if [[ -n "$row" ]]; then
        IFS=$'\x1f' read -r slug repo_path harness max_active < <(jq -r '[.slug, .repo_path, .harness, .max_active_issues] | map(tostring) | join("\u001f")' <<<"$row")
        [[ -n "$resolved_pid" ]] || resolved_pid="$pin_pid"
      elif [[ "$status" != todo ]]; then
        # No pin and nothing to resolve (a closed ledger row coming back, or
        # a v1-era row): never guess a project.
        [[ -n "$prev" && "$prev_st" != closed ]] &&
          actions="$(jq -c --arg t "PAPERCLIP_PROJECT_MISSING (no pin), held: $identifier" '. + [$t]' <<<"$actions")"
        continue
      fi
      local used_slots_s=0 working_id=""
      [[ -n "$slug" ]] && { used_slots_s="${used_slots[$slug]:-0}"; working_id="${working_ids[$slug]:-}"; }

      case "$status" in
        in_progress)
          local run_resp run_body run_id action new_state was_stranded
          run_resp="$(afk_pc_curl GET "$api_url/api/issues/$id/active-run" "$key" "")"
          run_body="${run_resp#*$'\n'}"
          run_id="$(jq -r '.id // empty' <<<"$run_body" 2>/dev/null)"
          # No live run (and a header value from Paperclip must be a plain
          # token). AC-5 (P8a): a run that ended while the issue it held is
          # still in_progress is never escalated, so an issue this host holds
          # is repaired by its own report cycle (self-wake, then the pending
          # final or the re-block), but only on a readable "no run": a failed
          # read may hide a run AFK didn't mint. A stranded or board-held issue
          # waits for Josh's Todo, the resume signal. Anything else is left.
          if ! [[ "$run_id" =~ ^[A-Za-z0-9_-]+$ ]]; then
            if [[ -n "$prev" ]] && ! afk_pc_no_run "$run_resp"; then
              actions="$(jq -c --arg t "active run unreadable, held: $identifier" '. + [$t]' <<<"$actions")"
            elif [[ -n "$prev" && "$prev_st" != stranded && "$prev_st" != held_by_board ]]; then
              ledger="$(jq -c --arg id "$id" '.issues[$id].reblock_due //= "strand"' <<<"$ledger")"
            else
              actions="$(jq -c --arg t "in_progress without a live run, left alone: $identifier" '. + [$t]' <<<"$actions")"
            fi
            continue
          fi
          local wake_reason clear_blockers=false own_self_wake=false
          wake_reason="$(jq -r '.contextSnapshot.wakeReason // .contextSnapshot.reason // empty' <<<"$run_body")"
          [[ "$run_id" == "$(jq -r '.last_self_wake_run_id // empty' <<<"$prev")" ]] && own_self_wake=true
          # AC-5a: an issue_blockers_resolved wake must clear blockedByIssueIds
          # on every re-block (paused or not), or Paperclip reads it as
          # "blockers restored" and sends a second wake into recovery.
          [[ "$wake_reason" == issue_blockers_resolved ]] && clear_blockers=true
          was_stranded="false"
          [[ "$prev_st" == stranded ]] && was_stranded="true"

          local prior_state_ip="$prev_st" resume_from=""
          # F7 in lease mode: Josh's Todo on a held issue arrives as this
          # wake, so the resume restores the interrupted state here too.
          if [[ "$prev_st" == stranded || "$prev_st" == held_by_board ]]; then
            resume_from="$(jq -r '.resume_state // empty' <<<"$prev")"
            [[ "$resume_from" == pending_claim ]] && prior_state_ip=pending_claim
          fi

          if [[ "$pause_kind" != none ]]; then
            action="$(afk_pc_action_text "$pause_kind" "" "" "")"
            # AC-10: a first-ever adoption during a pause/drain is recorded as
            # pending_claim, not working, so the PM never hears about it until
            # the first unpaused pass runs the real claim below.
            if [[ -z "$prev" ]]; then
              afk_pc_pin_new
              new_state="pending_claim"
            else
              new_state="$prior_state_ip"
            fi
            afk_pc_self_block "$api_url" "$id" "$key" "$run_id" "$agent_id" "$action" "$clear_blockers" ||
              actions="$(jq -c --arg t "PAPERCLIP_SELF_BLOCK_FAILED: $identifier" '. + [$t]' <<<"$actions")"
            actions="$(jq -c --arg t "paused: $identifier" '. + [$t]' <<<"$actions")"
          elif [[ -z "$prev" || "$prior_state_ip" == pending_claim ]]; then
            [[ -n "$prev" ]] || afk_pc_pin_new
            if ! afk_pc_claim_comment; then
              action="$(jq -r --arg id "$id" '.issues[$id].action_text // empty' <<<"$ledger")"
              afk_pc_self_block "$api_url" "$id" "$key" "$run_id" "$agent_id" "$action" ||
                actions="$(jq -c --arg t "PAPERCLIP_SELF_BLOCK_FAILED: $identifier" '. + [$t]' <<<"$actions")"
              [[ "${AFK_PC_ABORT:-false}" == true ]] && break
              continue
            fi
            claim_started_this_pass[$id]=1
            afk_pc_claim_artifacts || continue
            if (( used_slots_s >= max_active || host_used >= host_max )); then
              new_state="queued"; newly_queued_ids+="$id"$'\n'
              action="$(afk_pc_queue_text)"
            else
              new_state="working"
              action="$(afk_pc_action_text none "" "" "")"
              used_slots_s=$((used_slots_s + 1)); host_used=$((host_used + 1))
              working_id="$identifier"
            fi
            afk_pc_maybe_start_pm
            [[ -n "$AFK_PCS_ACTION_OVERRIDE" ]] && action="$AFK_PCS_ACTION_OVERRIDE"
            afk_pc_self_block "$api_url" "$id" "$key" "$run_id" "$agent_id" "$action" ||
              actions="$(jq -c --arg t "PAPERCLIP_SELF_BLOCK_FAILED: $identifier" '. + [$t]' <<<"$actions")"
            actions="$(jq -c --arg t "claimed: $identifier" '. + [$t]' <<<"$actions")"
          else
            # AC-5a: an existing ledger entry plus a live in_progress status
            # is a Paperclip-initiated wake (issue_children_completed,
            # issue_blockers_resolved, approval_approved, or any other
            # reason) — Paperclip auto-started this run, we never requested
            # it. Handle exactly like a report cycle: one short
            # acknowledgment comment naming the reason, then re-self-block.
            local prior_state queued_text=""
            prior_state="$prev_st"
            [[ "$resume_from" == queued ]] && prior_state=queued
            if [[ "$own_self_wake" != true ]]; then
              afk_pc_comment "$api_url" "$id" "$key" "$run_id" \
                "AFK host acknowledged: ${wake_reason:-a Paperclip wake}" >/dev/null
            fi
            if [[ "$resume_from" == working || "$resume_from" == waiting_human ]] &&
               ! (( used_slots_s >= max_active || host_used >= host_max )); then
              # The hold released its slot; the resume takes one again.
              new_state="$resume_from"
              used_slots_s=$((used_slots_s + 1)); host_used=$((host_used + 1))
              working_id="$identifier"
            elif [[ "$prior_state" == working || "$prior_state" == waiting_human ]]; then
              new_state="$prior_state"
            elif [[ "$prior_state" == queued ]]; then
              # Promotion is one FIFO sweep after this loop (AD-24).
              new_state="queued"; promotable[$id]=1
              queued_text="$(afk_pc_queue_text)"
              [[ -n "$queued_text" ]] || queued_text="$(jq -r '.action_text // empty' <<<"$prev")"
              [[ -n "$queued_text" ]] || queued_text="$(afk_pc_action_text none "" "" "")"
            elif (( used_slots_s >= max_active || host_used >= host_max )); then
              new_state="queued"; newly_queued_ids+="$id"$'\n'
              queued_text="$(afk_pc_queue_text)"
            else
              new_state="working"
              used_slots_s=$((used_slots_s + 1)); host_used=$((host_used + 1))
              working_id="$identifier"
            fi
            local wake_qid=""
            [[ "$new_state" == waiting_human ]] && wake_qid="$(jq -r '.question_id // empty' <<<"$prev")"
            action="$(afk_pc_action_text none "" "$status_file_dir/$id.json" "$(jq -r '.action_text' <<<"$prev")" "$wake_qid")"
            [[ "$new_state" == queued ]] && action="$queued_text"
            afk_pc_self_block "$api_url" "$id" "$key" "$run_id" "$agent_id" "$action" "$clear_blockers" ||
              actions="$(jq -c --arg t "PAPERCLIP_SELF_BLOCK_FAILED: $identifier" '. + [$t]' <<<"$actions")"
            [[ "$own_self_wake" == true ]] ||
              actions="$(jq -c --arg t "wake acknowledged: $identifier" '. + [$t]' <<<"$actions")"
          fi

          local since; since="$(jq -r 'if .since then .since else empty end' <<<"${prev:-null}")"
          [[ -n "$since" ]] || since="$(jq -r --arg id "$id" '.issues[$id].since // empty' <<<"$ledger")"
          [[ -n "$since" ]] || since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          # action_text_applied mirrors this self-block's text (PC-1b AC-2), so
          # the report cycle below only fires on a genuinely new declared
          # status or a queued spool entry, never on a text it just applied.
          # The project is pinned here, at first adoption (F6).
          ledger="$(jq -c --arg id "$id" --arg a "$agent_id" --arg s "$slug" --arg p "$resolved_pid" --arg ident "$identifier" \
            --arg st "$new_state" --arg since "$since" --arg act "$action" --argjson fresh "$fresh" \
            '.issues[$id] = ((.issues[$id] // {} | if $fresh then {since, claim, claim_attempted, claim_comment_pending, claimed_notice, claimed_notice_path, claimed_brief, claimed_brief_path, claimed_notice_epoch, claim_artifact_counter} else . end) + {host_agent_id:$a, paperclip_project_id:$p, slug:$s, identifier:$ident, state:$st, since:$since, action_text:$act, action_text_applied:$act}
               | del(.fixed_text, .refusal_code) | if .state | IN("stranded", "held_by_board") then . else del(.resume_state) end)' \
            <<<"$ledger")"

          [[ "$was_stranded" == true ]] && afk_pc_close_recovery
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

          # A refused issue that just resolved was self-blocked by this host
          # with no ledger pin yet: it is adopted below as if pending_claim.
          local adopting=false
          [[ -z "$prev" && -n "$resolved_pid" ]] && adopting=true

          if [[ "$recovery_active" == true ]]; then
            if [[ -n "$prev" ]]; then
              afk_pc_strand "$api_url" "$key" "$company_id" "$board_user_id" "$id" "$identifier" \
                "$agent_id" "$slug" "$repo_path" "$harness"
              if [[ "$prev_st" == working || "$prev_st" == waiting_human ]]; then
                (( used_slots_s > 0 )) && used_slots_s=$((used_slots_s - 1))
                (( host_used > 0 )) && host_used=$((host_used - 1))
                [[ "$working_id" == "$identifier" ]] && working_id=""
              fi
            fi
          elif [[ -n "$owner_agent" && "$owner_agent" == "$agent_id" ]]; then
            local prev_state qid
            prev_state="$prev_st"
            [[ "$adopting" == true ]] && prev_state=pending_claim
            qid="$(jq -r '.question_id // empty' <<<"${prev:-null}")"
            local since; since="$(jq -r '.since // empty' <<<"${prev:-null}")"

            # AFK-PC-2b: re-run the PM-start classification every pass this
            # issue stays self-blocked and owned by us, not only at the
            # moment it was first claimed — a later exact Josh approval
            # comment, or the registry finally reporting `none`, is decided
            # here on the pass that observes it.
            # Never while paused, stopped or draining, and never for an issue
            # this host has already stranded or closed.
            AFK_PCS_ACTION_OVERRIDE=""
            [[ "$adopting" == false && "$pause_kind" == none && "$prev_state" != stranded && "$prev_state" != closed ]] && afk_pc_maybe_start_pm
            [[ -n "$AFK_PCS_ACTION_OVERRIDE" ]] && ledger="$(jq -c --arg id "$id" --arg t "$AFK_PCS_ACTION_OVERRIDE" \
              '.issues[$id].action_text = $t' <<<"$ledger")"

            local newest_since="$since"
            [[ "$adopting" == false ]] && afk_pc_scan_comments

            # A queued issue is promoted by the FIFO sweep after this loop.
            local final_state="$prev_state"
            [[ "$prev_state" == queued ]] && promotable[$id]=1
            if [[ "$adopting" == true ]]; then
              # Pinned now, at first adoption (F6); pending_claim until the
              # first unpaused pass, exactly like an adoption during a pause.
              afk_pc_pin_new
              since="$(jq -r --arg id "$id" '.issues[$id].since' <<<"$ledger")"; newest_since="$since"
              prev="$(jq -c --arg id "$id" '.issues[$id]' <<<"$ledger")"
            fi
            # AC-10: adopted during a pause, the issue is now self-blocked, not
            # in_progress, so the claim happens here on the first unpaused
            # pass; the claim comment itself goes out in the report cycle.
            [[ "$prev_state" == pending_claim && "$pause_kind" == none ]] && afk_pc_claim "$adopting"
            # Never write into .issues[$id] when there is no prior entry: the
            # ledger was reset invalid, or a previous poller self-blocked this
            # issue without ever creating a ledger row. Writing anyway leaves
            # an orphan entry (state set, no host_agent_id/slug/identifier)
            # that every host_agent_id-filtered query silently ignores forever.
            [[ -n "$prev" ]] && ledger="$(jq -c --arg id "$id" --arg st "$final_state" --arg since "${newest_since:-$since}" \
              '.issues[$id].state = $st | .issues[$id].since = $since' <<<"$ledger")"
          elif [[ -n "$owner_user" && "$owner_user" == "$board_user_id" ]]; then
            [[ -n "$prev" ]] && afk_pc_hold "$id" held_by_board
          else
            # `stranded` too, so a recovery issue whose creation failed is retried
            # (afk_pc_strand itself keeps it to exactly one per issue).
            if [[ -n "$prev" && ( "$prev_st" == working || "$prev_st" == queued || "$prev_st" == waiting_human || "$prev_st" == stranded ) ]]; then
              afk_pc_strand "$api_url" "$key" "$company_id" "$board_user_id" "$id" "$identifier" \
                "$agent_id" "$slug" "$repo_path" "$harness"
              if [[ "$prev_st" == working || "$prev_st" == waiting_human ]]; then
                (( used_slots_s > 0 )) && used_slots_s=$((used_slots_s - 1))
                (( host_used > 0 )) && host_used=$((host_used - 1))
                [[ "$working_id" == "$identifier" ]] && working_id=""
              fi
            fi
          fi
          ;;
        cancelled | done)
          if [[ -n "$prev" ]]; then
            ledger="$(jq -c --arg id "$id" '.issues[$id].state = "closed"' <<<"$ledger")"
            afk_pc_notice "$slug" "$id" "$identifier" "$agent_id" "$repo_path" "$harness" stopped
            [[ "$pause_kind" == none ]] && afk_pc_spool_dead_all "$id"
            actions="$(jq -c --arg t "stopped: $identifier" '. + [$t]' <<<"$actions")"
            # A working slot closing mid-pass must free up immediately, or an
            # issue claimed later in this same pass sees a stale used_slots.
            if [[ "$prev_st" == working || "$prev_st" == waiting_human ]]; then
              (( used_slots_s > 0 )) && used_slots_s=$((used_slots_s - 1))
              (( host_used > 0 )) && host_used=$((host_used - 1))
              [[ "$working_id" == "$identifier" ]] && working_id=""
            fi
          fi
          ;;
        todo)
          # AD-26: pull adoption (AC-3) and a held issue back in todo (AC-4,
          # P6d). A todo issue runs no lease, so a paused pass leaves it for
          # the first unpaused one; a lease-mode issue this host never held
          # is left alone (AC-5e). Every write goes out in the issue's own
          # report cycle below: one self-wake, in_progress, the comment it
          # owes (claim or resume, never one for a nudge), then the block.
          [[ "$pause_kind" == none && "$prev_st" != closed ]] || continue
          if [[ -n "$prev" && -z "$slug" ]]; then
            actions="$(jq -c --arg t "PAPERCLIP_PROJECT_MISSING (no pin), held: $identifier" '. + [$t]' <<<"$actions")"
            continue
          fi
          local final_state="$prev_st"
          if [[ -z "$prev" ]]; then
            [[ -n "$resolved_pid" ]] || continue
            afk_pc_pin_new
            afk_pc_claim true
            ledger="$(jq -c --arg id "$id" --arg st "$final_state" '.issues[$id].state = $st' <<<"$ledger")"
          elif [[ "$prev_st" == pending_claim ]]; then
            afk_pc_claim false
            ledger="$(jq -c --arg id "$id" --arg st "$final_state" '.issues[$id].state = $st' <<<"$ledger")"
          elif [[ "$prev_st" == stranded || "$prev_st" == held_by_board ]]; then
            # F7: a resume restores the state the hold interrupted, keeping
            # since, the open question and the plan and approval records.
            local rs due=resume; rs="$(jq -r '.resume_state // empty' <<<"$prev")"
            if [[ "$rs" == pending_claim ]]; then
              afk_pc_claim false; due=nudge # held before its claim: claim it now
            elif [[ "$rs" == queued ]]; then
              final_state=queued; promotable[$id]=1
            elif (( used_slots_s >= max_active || host_used >= host_max )); then
              final_state=queued; newly_queued_ids+="$id"$'\n'
              ledger="$(jq -c --arg id "$id" --arg t "$(afk_pc_queue_text)" '.issues[$id].action_text = $t' <<<"$ledger")"
            else
              final_state=working; [[ "$rs" == waiting_human ]] && final_state=waiting_human
              used_slots_s=$((used_slots_s + 1)); host_used=$((host_used + 1))
              working_id="$identifier"
            fi
            ledger="$(jq -c --arg id "$id" --arg st "$final_state" --arg d "$due" \
              '.issues[$id] |= (.state = $st | .reblock_due = $d | del(.resume_state))' <<<"$ledger")"
            [[ "$prev_st" == stranded ]] && afk_pc_close_recovery
            actions="$(jq -c --arg t "resumed: $identifier" '. + [$t]' <<<"$actions")"
          else
            # P6d: Josh commented on a self-blocked issue and it reopened. Not
            # new work: scan the comments exactly as the blocked branch does,
            # then re-block. No comment, no claim, no move in the queue.
            local prev_state="$prev_st" qid since newest_since
            qid="$(jq -r '.question_id // empty' <<<"$prev")"
            since="$(jq -r '.since // empty' <<<"$prev")"; newest_since="$since"
            afk_pc_scan_comments
            [[ "$prev_st" == queued ]] && promotable[$id]=1
            ledger="$(jq -c --arg id "$id" --arg since "$newest_since" \
              '.issues[$id] |= ((if $since == "" then . else .since = $since end) | .reblock_due //= "nudge")' <<<"$ledger")"
            actions="$(jq -c --arg t "nudged: $identifier" '. + [$t]' <<<"$actions")"
          fi
          ;;
        *) : ;;
      esac
      [[ -n "$slug" ]] && { used_slots[$slug]="$used_slots_s"; working_ids[$slug]="$working_id"; }
    done

    # --- HA-2 (AD-24): FIFO promotion --------------------------------------
    # queued_at is set once, when an issue first enters `queued`, and dropped
    # when it leaves; `since` moves with every comment, so it only orders
    # entries that predate queued_at. A comment never sends an issue back.
    ledger="$(jq -c --arg a "$agent_id" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson n "$(jq -Rsc 'split("\n") | map(select(. != ""))' <<<"$newly_queued_ids")" \
      '.issues |= with_entries(if .value.host_agent_id != $a then .
         elif .value.state != "queued" then .value |= del(.queued_at)
         elif .value.queued_at == null and (.key | IN($n[])) then .value.queued_at = $now
         else . end)' <<<"$ledger")"
    # Oldest first; an issue is promoted only when its own project and the
    # host both have a free slot. No Paperclip field orders the queue.
    local q_id q_slug q_ident q_row q_max
    while IFS=$'\x1f' read -r q_id q_slug q_ident; do
      [[ -n "$q_id" && -n "${promotable[$q_id]:-}" ]] || continue
      (( host_used < host_max )) || break
      q_row="$(afk_pc_project_row "$q_slug")"
      [[ -n "$q_row" ]] || continue
      q_max="$(jq -r .max_active_issues <<<"$q_row")"
      (( ${used_slots[$q_slug]:-0} < q_max )) || continue
      used_slots[$q_slug]=$(( ${used_slots[$q_slug]:-0} + 1 )); host_used=$((host_used + 1))
      working_ids[$q_slug]="$q_ident"
      ledger="$(jq -c --arg id "$q_id" '.issues[$id].state = "working" | del(.issues[$id].queued_at)' <<<"$ledger")"
      afk_pc_notice "$q_slug" "$q_id" "$q_ident" "$agent_id" "$(jq -r .repo_path <<<"$q_row")" "$(jq -r .harness <<<"$q_row")" promoted
      actions="$(jq -c --arg t "promoted: $q_ident" '. + [$t]' <<<"$actions")"
    done < <(jq -r --arg a "$agent_id" '[.issues | to_entries[] | select(.value.host_agent_id == $a and .value.state == "queued")]
      | sort_by([.value.queued_at // .value.since // "", .key])[] | [.key, (.value.slug // ""), (.value.identifier // "" | gsub("[[:cntrl:]]"; ""))] | join("\u001f")' <<<"$ledger")

    # A queued issue's self-block text follows its reason (its project's slot,
    # or the host cap); the report cycle writes it only when it changed.
    local r_id r_slug r_row r_text
    while IFS=$'\x1f' read -r r_id r_slug; do
      [[ -n "$r_id" ]] || continue
      r_row="$(afk_pc_project_row "$r_slug")"; [[ -n "$r_row" ]] || continue
      used_slots_s="${used_slots[$r_slug]:-0}"; max_active="$(jq -r .max_active_issues <<<"$r_row")"
      working_id="${working_ids[$r_slug]:-}"
      r_text="$(afk_pc_queue_text)"
      if [[ "$r_text" == queued* ]]; then
        local current_text pm_state pm_live
        current_text="$(jq -r --arg id "$r_id" '.issues[$id].action_text // .issues[$id].action_text_applied // empty' <<<"$ledger")"
        pm_state="$(jq -r --arg id "$r_id" '.pm_started[$id].state // empty' <<<"$ledger")"
        pm_live="$(jq -r --arg id "$r_id" '.issues[$id].pm_confirmed // false' <<<"$ledger")"
        if [[ "$current_text" == *"no PM"* || "$current_text" == *"PM state"* ]] &&
           [[ "$pm_state" != live && "$pm_live" != true ]]; then
          continue
        fi
        ledger="$(jq -c --arg id "$r_id" --arg t "$r_text" '.issues[$id].action_text = $t' <<<"$ledger")"
      fi
    done < <(jq -r --arg a "$agent_id" '.issues | to_entries[] | select(.value.host_agent_id == $a and .value.state == "queued") | [.key, (.value.slug // "")] | join("\u001f")' <<<"$ledger")

    # --- HA-4a AC-7 (F3): native approvals are read, never waited for -------
    # Every pass, both modes, paused or not: a wake is never the trigger.
    # Acting on them stays with PC-8, which reads approvals_seen.
    local a_id a_ident a_resp
    while IFS=$'\x1f' read -r a_id a_ident; do
      [[ -n "$a_id" ]] || continue
      a_resp="$(afk_pc_curl GET "$api_url/api/issues/$a_id/approvals" "$key" "")"
      if [[ "${a_resp%%$'\n'*}" == 200 ]] && jq -e 'type == "array"' >/dev/null 2>&1 <<<"${a_resp#*$'\n'}"; then
        ledger="$(jq -c --arg id "$a_id" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson l "${a_resp#*$'\n'}" \
          '.issues[$id].approvals_seen = {at:$at, items:[$l[] | objects | {id, type, status} | map_values(strings)]}' <<<"$ledger")"
      else
        actions="$(jq -c --arg t "PAPERCLIP_APPROVALS_UNREADABLE, approvals not read: $a_ident" '. + [$t]' <<<"$actions")"
      fi
    done < <(jq -r --arg a "$agent_id" '.issues | to_entries[] | select(.value.host_agent_id == $a and .value.state == "waiting_human")
      | [.key, (.value.identifier // "" | gsub("[[:cntrl:]]"; ""))] | join("\u001f")' <<<"$ledger")

    # --- PC-1b: the report cycle (AC-1..AC-10) --------------------------------
    # Frozen while paused/draining (AC-6): no cycles, nothing deleted. Only
    # issues this host actually holds (working/waiting_human) drain a spool;
    # a refused (waiting_setup) or project-changed (stopped) issue gets only
    # its fixed self-block text, and an issue adopted while queued only its
    # claim comment. Stranded, pending_claim, held_by_board and closed are
    # untouched, unless the pass asked for a cycle (reblock_due, HA-4a).
    if [[ "$pause_kind" == none ]]; then
      local -a report_ids=()
      mapfile -t report_ids < <(jq -r --arg a "$agent_id" \
        '.issues | to_entries[] | select(.value.host_agent_id == $a and ((.value.state | IN("working", "waiting_human", "waiting_setup", "stopped"))
           or (.value.state == "queued" and ((.value.claim_comment_pending == true and .value.claim_attempted != true) or .value.action_text != .value.action_text_applied))
           or (.value.reblock_due != null and (.value.state | IN("closed", "reconciliation_blocked") | not)))) | .key' \
        <<<"$ledger")
      local rid
      for rid in "${report_ids[@]:-}"; do
        [[ -n "$rid" ]] || continue
        [[ -z "${claim_started_this_pass[$rid]:-}" ]] || continue
        AFK_PC_ABORT=false
        local r_ident; r_ident="$(jq -r --arg id "$rid" '.issues[$id].identifier // empty' <<<"$ledger")"
        # The report sweep is defense in depth for held starts that did not
        # reach the inbox start hook, and shares its pass-level one-start guard.
        afk_pc_retry_report_pm_start "$rid" "$agent_id"
        afk_pc_report_cycle "$api_url" "$key" "$agent_id" "$rid" "$r_ident" "$status_file_dir" || true
        [[ "$AFK_PC_ABORT" == true ]] && break
      done
    fi
    break
  done
  key=""
  [[ "$AFK_PC_STORAGE_ERROR" == true ]] && result="PAPERCLIP_STORAGE_ERROR"

  # AC-3: exit non-zero when nothing completed, and leave the ledger
  # untouched. The host's reason (vault-unavailable, key mismatch,
  # unreachable, ...) is still reported below rather than swapped for
  # afk_pc_emit_refusal.
  local ledger_counts="{}" overall="completed"
  if [[ "$AFK_PC_STORAGE_ERROR" == true ]]; then
    overall="PAPERCLIP_STORAGE_ERROR"
  elif [[ "$any_agent_ok" == false ]]; then
    overall="PAPERCLIP_UNREACHABLE"
    [[ "$result" == PAPERCLIP_ADOPTION_MODE_MISMATCH ]] && overall="$result"
  else
    ledger="$(jq -c --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.last_successful_pass = $t' <<<"$ledger")"
    if ! afk_state_file_write "$ledger_path" "$ledger"; then
      overall="PAPERCLIP_STORAGE_ERROR"
      result="PAPERCLIP_STORAGE_ERROR"
      actions="$(jq -c '. + ["PAPERCLIP_STORAGE_ERROR: poll ledger was not saved"]' <<<"$actions")"
    else
      ledger_counts="$(jq -c '[.issues[].state] | reduce .[] as $s ({}; .[$s] = (.[$s] // 0) + 1)' <<<"$ledger")"
    fi
    [[ "$pause_kind" != none && "$overall" == completed ]] && overall="PAPERCLIP_PAUSED"
  fi

  local agents_json
  agents_json="$(jq -nc --arg a "$agent_id" --arg r "$result" --argjson acts "$actions" '[{agent_id:$a, result:$r, actions:$acts}]')"

  if [[ "$json_mode" == true ]]; then
    jq -nc --arg r "$overall" --argjson agents "$agents_json" --argjson lc "$ledger_counts" \
      '{result: $r, agents: $agents, ledger_counts: $lc}'
  else
    while IFS= read -r line; do printf '%s\n' "$line"; done < <(
      jq -r '.[] | "\(.agent_id): \(.result)", (.actions[]? | "  " + .)' <<<"$agents_json"
    )
    printf 'paperclip-poll: %s\n' "$overall"
  fi
  [[ "$any_agent_ok" == true && "$overall" != PAPERCLIP_STORAGE_ERROR ]] || return 1
  return 0
}

# afk_pc_count_404 <http-status> -- F11: consecutive 404s on this issue's
# project, counted in the ledger across passes. Sets AFK_PC_404_N; any other
# status resets it. Reads the caller's `id`, reads/writes its `ledger`.
afk_pc_count_404() {
  AFK_PC_404_N=0
  if [[ "$1" == 404 ]]; then
    AFK_PC_404_N="$(jq -r --arg id "$id" '(.project_404[$id] // 0) + 1' <<<"$ledger")"
    ledger="$(jq -c --arg id "$id" --argjson n "$AFK_PC_404_N" '.project_404[$id] = $n' <<<"$ledger")"
  else
    ledger="$(jq -c --arg id "$id" 'del(.project_404[$id])' <<<"$ledger")"
  fi
}

# afk_pc_waiting_setup -- AC-4: record (or keep) a refused issue as
# `waiting_setup`. It holds no slot, writes no notice or brief, starts no PM
# and posts no claim comment; its report cycle is the self-block alone. The
# ledger is written only when the outcome (code or text) changes. Reads the
# caller's pass locals (id, identifier, prev, status, detail, pause_kind, ...).
afk_pc_waiting_setup() {
  local code="$AFK_PC_RES" text="$AFK_PC_RES_TEXT" since
  if [[ -n "$prev" && "$(jq -r '.refusal_code // empty' <<<"$prev")" == "$code" &&
        "$(jq -r '.fixed_text // empty' <<<"$prev")" == "$text" && "$status" != in_progress ]]; then
    return 0
  fi
  since="$(jq -r '.since // empty' <<<"${prev:-null}")"
  [[ -n "$since" ]] || since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ledger="$(jq -c --arg id "$id" --arg a "$agent_id" --arg ident "$identifier" --arg since "$since" \
    --arg c "$code" --arg t "$text" \
    '.issues[$id] = ((.issues[$id] // {} | {action_text_applied}) + {host_agent_id:$a, identifier:$ident,
       state:"waiting_setup", since:$since, refusal_code:$c, fixed_text:$t, action_text:$t})' <<<"$ledger")"
  actions="$(jq -c --arg t "waiting_setup ($code): $identifier" '. + [$t]' <<<"$actions")"
  if [[ "$status" == in_progress ]]; then
    # A live run is here now: block with it rather than waiting for the report cycle.
    local run_id wr
    wr="$(afk_pc_curl GET "$api_url/api/issues/$id/active-run" "$key" "")"
    run_id="$(jq -r '.id // empty' <<<"${wr#*$'\n'}" 2>/dev/null)"
    [[ "$run_id" =~ ^[A-Za-z0-9_-]+$ ]] || return 0
    local blk; blk="$(afk_pc_action_text "$pause_kind" "" "" "" "" "$text")"
    if afk_pc_self_block "$api_url" "$id" "$key" "$run_id" "$agent_id" "$blk"; then
      [[ "$pause_kind" == none ]] &&
        ledger="$(jq -c --arg id "$id" --arg t "$blk" '.issues[$id].action_text_applied = $t' <<<"$ledger")"
    else
      actions="$(jq -c --arg t "PAPERCLIP_SELF_BLOCK_FAILED: $identifier" '. + [$t]' <<<"$actions")"
    fi
  fi
}

# afk_pc_project_changed -- AC-6: the live projectId no longer matches the
# pin (null, another project, or the pinned project deleted). One `stopped`
# notice with PROJECT_CHANGED to the pinned slug's directory, the slot is
# released, and state `stopped` carries the fixed stop text. The self-block
# itself goes out from this issue's report cycle (the same pass unless
# paused); a later Paperclip wake is re-blocked by the pass's `stopped`
# branch. Reads the caller's pass locals.
afk_pc_project_changed() {
  local pslug prow
  pslug="$(jq -r '.slug // empty' <<<"$prev")"
  prow="$(afk_pc_project_row "$pslug")"
  afk_pc_notice "$pslug" "$id" "$identifier" "$agent_id" "$(jq -r '.repo_path // empty' <<<"${prow:-null}")" \
    "$(jq -r '.harness // empty' <<<"${prow:-null}")" stopped '{"reason":"PROJECT_CHANGED"}'
  if [[ ( "$prev_st" == working || "$prev_st" == waiting_human ) && -n "${used_slots[$pslug]:-}" ]]; then
    local u="${used_slots[$pslug]}"
    (( u > 0 )) && used_slots[$pslug]=$((u - 1))
    (( host_used > 0 )) && host_used=$((host_used - 1))
    [[ "${working_ids[$pslug]:-}" == "$identifier" ]] && working_ids[$pslug]=""
  fi
  ledger="$(jq -c --arg id "$id" --arg t "$stop_text" \
    '.issues[$id].state = "stopped" | .issues[$id].fixed_text = $t | .issues[$id].action_text = $t | .issues[$id].stop_reason = "PROJECT_CHANGED"' <<<"$ledger")"
  actions="$(jq -c --arg t "PROJECT_CHANGED, stopped: $identifier" '. + [$t]' <<<"$actions")"
}

# afk_pc_compute_pause <api_url> <key> <maintenance_issue_id> <board_user_id> <company_id> <initial-pause-kind>
# Sets AFK_PC_PAUSE_KIND (none|stopped|maintenance). Computed once per pass
# with the host key (AC-9, AD-23).
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
      local tr; tr="$(afk_pc_create_issue "$1" "$2" "$5" "NEEDS HUMAN: drain issue tampered" "$4" \
        "The maintenance issue's assignee is not the board; drain is being ignored.")"
      [[ "${tr%%$'\n'*}" == 2?? ]] && ledger="$(jq -c '.drain_tampered_reported = true' <<<"$ledger")"
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
