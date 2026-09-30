#!/usr/bin/env bash
# afk-paperclip-start.sh — AFK-PC-2b: start the first PM for a Paperclip
# project when the registry says `none`, and the `paperclip-timer` verb. The
# project is always the issue's pinned slug and its projects[] row (AD-23).
#
# afk_pcs_start_pm is called from lib/afk-paperclip.sh's `claimed`-notice
# classification hook and reads/writes its caller's locals directly (api_url,
# key, id, identifier, slug, repo_path, harness, board_user_id, host_name,
# company_id, detail, ledger, actions) exactly like afk_pc_strand does. This
# file is SOURCED, never executed.

if [[ -n "${AFK_PAPERCLIP_START_SOURCED:-}" ]]; then
  return 0
fi
AFK_PAPERCLIP_START_SOURCED=1

# The one Orca resolver and bounded runner (AD-28 R1, R2).
# shellcheck source=lib/afk-orca.sh
# shellcheck disable=SC1091
declare -F afk_orca_run >/dev/null 2>&1 || . "$(dirname -- "${BASH_SOURCE[0]}")/afk-orca.sh"

AFK_PCT_UNIT="afk-paperclip-poll"

# --- opt-in gate, PM-start action text, and the classification decision -----
# pm_start_enabled defaults to false so a host that has not opted into
# AFK-PC-2b (including every existing paperclip-poll test fixture) sees no
# behaviour change at all: no registry lookup, no network call, no terminal.
afk_pcs_start_pm() {
  local enabled created_by lookup state
  enabled="$(jq -r '.pm_start_enabled // false' <<<"$AFK_PC_CFG" 2>/dev/null)"
  [[ "$enabled" == true ]] || return 0
  created_by="$(jq -r '.createdByUserId // empty' <<<"$detail" 2>/dev/null)"

  lookup="$(afk_pm_registry_lookup "$repo_path")" || return 0
  local -a stale_scopes=() ; local sk reaped=false
  mapfile -t stale_scopes < <(jq -r '.stale[]?.scope // empty' <<<"$lookup" 2>/dev/null)
  for sk in "${stale_scopes[@]:-}"; do
    [[ -n "$sk" ]] || continue
    declare -F afk_cmd_pm_registry_reap >/dev/null 2>&1 && afk_cmd_pm_registry_reap false "$sk" >/dev/null 2>&1 && reaped=true
  done
  [[ "$reaped" == true ]] && lookup="$(afk_pm_registry_lookup "$repo_path")"
  state="$(jq -r '.state' <<<"$lookup")"

  case "$state" in
    live) return 0 ;;
    handoff_in_progress)
      AFK_PCS_ACTION_OVERRIDE="queued: no PM (busy with handoff)"
      return 0 ;;
    ambiguous | handoff_stalled)
      AFK_PCS_ACTION_OVERRIDE="Waiting for Josh: PM state unclear on $host_name"
      afk_pcs_report_pm_state_ambiguous
      return 0 ;;
    none) : ;;
    unknown)
      # An owner that isn't provably stale keeps the repo busy; say why.
      local why; why="$(jq -r '.reason // empty' <<<"$lookup")"
      [[ "$why" =~ ^[A-Z0-9_]{1,64}$ ]] || why="PM_OWNER_UNKNOWN"
      AFK_PCS_ACTION_OVERRIDE="queued: PM state unknown ($why)"
      return 0 ;;
    *) return 0 ;;
  esac
  # At most one start per issue, ever (an approval authorises one start). A
  # started PM that has not registered yet still reads `none` here.
  jq -e --arg id "$id" '.pm_started[$id] != null' <<<"$ledger" >/dev/null 2>&1 && return 0

  # AC-2: the creator gate.
  if [[ -z "$created_by" || "$created_by" != "$board_user_id" ]]; then
    local approved=false
    AFK_PCS_APPROVAL_RESULT=""
    afk_pcs_approval_granted && approved=true
    if [[ "$approved" != true ]]; then
      AFK_PCS_ACTION_OVERRIDE="queued: no PM (needs approval to start)"
      [[ "$AFK_PCS_APPROVAL_RESULT" == "APPROVAL_INTERIM_UNATTESTED" ]] &&
        actions="$(jq -c --arg t "APPROVAL_INTERIM_UNATTESTED: $identifier" '. + [$t]' <<<"$actions")"
      afk_pcs_ask_once
      return 0
    fi
  fi

  # AC-3: the daily cap.
  local cap
  cap="$(jq -r '.pm_start_daily_cap // 3' <<<"$AFK_PC_CFG" 2>/dev/null)"
  [[ "$cap" =~ ^[0-9]+$ ]] || cap=3
  if ! afk_pcs_cap_ok "$cap"; then
    AFK_PCS_ACTION_OVERRIDE="queued: no PM (start cap reached)"
    return 0
  fi

  # AC-4: readiness first. Never auto-fix.
  local rd
  rd="$(afk_pcs_readiness_check "$repo_path")"
  if [[ "$rd" != ok ]]; then
    AFK_PCS_ACTION_OVERRIDE="queued: no PM (start refused: $rd)"
    return 0
  fi

  # AC-5: <slug>/<harness> are validated before they ever reach the fixed
  # instruction text.
  if ! afk_pc_slug_ok "$slug"; then
    AFK_PCS_ACTION_OVERRIDE="queued: no PM (start refused: PAPERCLIP_PROJECT_NAME_UNSAFE)"
    return 0
  fi
  case "$harness" in
    claude | codex | opencode) : ;;
    *)
      AFK_PCS_ACTION_OVERRIDE="queued: no PM (start refused: PAPERCLIP_HARNESS_INVALID)"
      return 0 ;;
  esac

  if afk_pcs_create_terminal; then
    afk_pcs_cap_record
    actions="$(jq -c --arg t "pm started: $identifier" '. + [$t]' <<<"$actions")"
  fi
  return 0
}

# afk_pcs_approval_granted -- AC-2. Reads api_url/key/id/board_user_id/
# AFK_PC_CFG from the caller. Sets AFK_PCS_APPROVAL_RESULT on refusal.
#
# AC-6 (unify with PC-3b's plan approval): the attestation compares
# `interim_comment_approval.paperclip_commit` against the deployed commit
# from `GET /api/health` (afk_pc_health_commit, lib/afk-paperclip.sh), never
# a locally-declared `paperclip_version`. A health check that fails, times
# out or returns no commit is the same fail-closed refusal as a missing
# attestation -- never treated as "attested".
afk_pcs_approval_granted() {
  local interim interim_commit deployed_commit attested=false resp body found=false c
  interim="$(jq -c '.interim_comment_approval // empty' <<<"$AFK_PC_CFG" 2>/dev/null)"
  if [[ -n "$interim" && "$interim" != null ]]; then
    interim_commit="$(jq -r '.paperclip_commit // empty' <<<"$interim")"
    if [[ -n "$interim_commit" ]]; then
      deployed_commit="$(afk_pc_health_commit "$api_url" "$key")" || deployed_commit=""
      [[ -n "$deployed_commit" && "$interim_commit" == "$deployed_commit" ]] && attested=true
    fi
  fi
  if [[ "$attested" != true ]]; then
    AFK_PCS_APPROVAL_RESULT="APPROVAL_INTERIM_UNATTESTED"
    return 1
  fi
  resp="$(afk_pc_curl GET "$api_url/api/issues/$id/comments" "$key" "")"
  [[ "${resp%%$'\n'*}" == 2?? ]] || return 1
  body="${resp#*$'\n'}"
  jq -e 'type=="array"' <<<"$body" >/dev/null 2>&1 || return 1
  while IFS= read -r c; do
    [[ -n "$c" ]] || continue
    afk_pc_is_josh_comment "$c" "$board_user_id" || continue
    [[ "$(jq -r '.body // empty' <<<"$c")" == "approve start $identifier" ]] && { found=true; break; }
  done < <(jq -c '.[]' <<<"$body")
  [[ "$found" == true ]]
}

# afk_pcs_ask_once -- the ONE question comment (AC-2). Reads/writes `ledger`.
afk_pcs_ask_once() {
  local already r
  already="$(jq -r --arg id "$id" '.issues[$id].pm_start_asked // false' <<<"$ledger" 2>/dev/null)"
  [[ "$already" == true ]] && return 0
  r="$(afk_pc_comment "$api_url" "$id" "$key" "" "Reply exactly: approve start $identifier")"
  [[ "${r%%$'\n'*}" == 2?? ]] && ledger="$(jq -c --arg id "$id" '.issues[$id].pm_start_asked = true' <<<"$ledger")"
}

# afk_pcs_cap_ok/record -- AC-3, one counter per host per UTC day in `ledger`.
afk_pcs_cap_ok() { # <cap>
  local cap="$1" today count
  today="$(date -u +%Y-%m-%d)"
  count="$(jq -r --arg d "$today" '.pm_starts[$d] // 0' <<<"$ledger" 2>/dev/null)"
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  (( count < cap ))
}

afk_pcs_cap_record() {
  local today; today="$(date -u +%Y-%m-%d)"
  ledger="$(jq -c --arg d "$today" '.pm_starts[$d] = ((.pm_starts[$d] // 0) + 1)' <<<"$ledger")"
}

# afk_pcs_report_pm_state_ambiguous -- AC-1: one out-of-band issue, idempotent
# per repo (an `idempotencyKey`), reads/writes `ledger`.
afk_pcs_report_pm_state_ambiguous() {
  local rhash already r
  rhash="$(printf '%s' "$repo_path" | afk_scope_sha256 2>/dev/null)"
  [[ -n "$rhash" ]] || return 0
  already="$(jq -r --arg h "$rhash" '.pm_state_reported[$h] // false' <<<"$ledger" 2>/dev/null)"
  [[ "$already" == true ]] && return 0
  r="$(afk_pc_create_issue "$api_url" "$key" "$company_id" \
    "NEEDS HUMAN: PM state unclear for a Paperclip project" "$board_user_id" \
    "The PM registry lookup for this project's repo is ambiguous or its handoff is stalled. Resolve manually before a PM can start." \
    "afk-pmstate-$rhash")"
  [[ "${r%%$'\n'*}" == 2?? ]] && ledger="$(jq -c --arg h "$rhash" '.pm_state_reported[$h] = true' <<<"$ledger")"
}

# afk_pcs_readiness_check <repo_path> -- AC-4. Overridable for tests exactly
# like AFK_ORCA_BIN/AFK_PC_OP: prints "ok" or a refusal code.
afk_pcs_readiness_check() {
  local repo_path="$1" bin out rc=0 code
  bin="${AFK_PCS_READINESS_BIN:-$AFK_KIT_ROOT/bin/agent-flow-kit}"
  out="$(cd "$repo_path" 2>/dev/null && "$bin" status --json 2>/dev/null)"; rc=$?
  if (( rc != 0 )); then
    code="$(jq -r '.readiness.route.reason // .route.reason // .reason // empty' <<<"$out" 2>/dev/null)"
  else
    # Plain `status` exits 0 even when not ready (only --live/--stamp force an
    # exit code), so the readiness block itself is the answer. Unparseable is
    # a refusal, never a pass.
    code="$(jq -r 'if (.readiness|type) != "object" then "PAPERCLIP_START_READINESS_UNKNOWN"
      elif (.readiness.INSTALLED_INTEGRITY.state // "") != "READY" then (.readiness.INSTALLED_INTEGRITY.reason // "INSTALLED_INTEGRITY")
      else ([.readiness | to_entries[] | select(.key != "MUTATION_SOURCE_ELIGIBLE")
             | select((.value.state // "") | IN("FALSE","NOT_READY","NEEDS_OWNER")) | (.value.reason // .key)][0] // "")
      end' <<<"$out" 2>/dev/null)" || code="PAPERCLIP_START_READINESS_UNKNOWN"
    [[ -z "$code" ]] && { printf 'ok'; return 0; }
  fi
  [[ "$code" =~ ^[A-Z0-9_]+$ ]] || code="PAPERCLIP_START_READINESS_UNKNOWN"
  printf '%s' "$code"
  return 1
}

# afk_pcs_create_terminal -- AC-5. One visible Orca terminal, idempotent by
# title (never a second one for the same project). Reads repo_path/slug/
# harness/id from the caller; writes the start into `ledger` on success.
afk_pcs_create_terminal() {
  local shown observed_id observed_path title
  afk_orca_run pm-start-worktree -- worktree show --worktree "path:$repo_path" --json || return 1
  shown="$AFK_ORCA_OUT"
  observed_id="$(jq -r '.result.worktree.id // .result.id // .worktree.id // .id // empty' <<<"$shown" 2>/dev/null)"
  observed_path="$(jq -r '.result.worktree.path // .result.path // .worktree.path // .path // empty' <<<"$shown" 2>/dev/null)"
  observed_path="$(cd "$observed_path" 2>/dev/null && pwd -P || true)"
  [[ -n "$observed_id" && -n "$observed_path" ]] || return 1

  title="PM $slug (paperclip)"
  local listed count prior
  afk_orca_run --bound 5 pm-start-dedupe -- terminal list --worktree "id:$observed_id" --limit "$AFK_ORCA_LIST_LIMIT" --json || return 1
  listed="$AFK_ORCA_OUT"
  # ORCA-6: the title half of this dedupe goes (AD-28 R4).
  # The harness rewrites the terminal title once it runs, so the title alone
  # cannot prove "no PM started yet". Any terminal this host started for the
  # same repo that is still listed also blocks a second start.
  prior="$(jq -c --arg r "$repo_path" '[(.pm_started // {})[] | select(.repo == $r) | .terminal]' <<<"$ledger" 2>/dev/null)" || return 1
  count="$(jq -r --arg t "$title" --argjson h "$prior" \
    '[.result.terminals[]? | select(.title==$t or (.handle as $x | any($h[]; . == $x)))] | length' <<<"$listed" 2>/dev/null)"
  [[ "$count" =~ ^[0-9]+$ ]] || return 1
  (( count > 0 )) && return 1 # already visible: never start a second one

  local resume intent intent_file bootstrap command created terminal
  resume="You are the BMAD PM for project $slug. Register with \`agent-flow-kit pm-start --harness $harness\`, then run \`agent-flow-kit paperclip-take --slug $slug\` and read the brief file it names."
  intent="$(jq -nc --arg proj "$slug" --arg h "$harness" --arg wi "$observed_id" --arg wp "$observed_path" \
    --arg resume "$resume" \
    '{schema:"afk-pm-bootstrap-first-start-intent/2", slug:$proj, harness:$h,
      worktree:{id:$wi, path:$wp}, resume_instruction:$resume}')" || return 1
  intent_file="$AFK_STATE_DIR/paperclip/pm-start-intents/$slug.json"
  afk_state_file_write "$intent_file" "$intent" || return 1

  bootstrap="${AFK_PM_BOOTSTRAP_BIN:-$AFK_KIT_ROOT/adapters/orca-pm-bootstrap.sh}"
  [[ -x "$bootstrap" ]] || return 1
  printf -v command '%q --intent %q' "$bootstrap" "$intent_file"
  # ORCA-3: the ledger row is persisted before this create (AD-28 R6).
  afk_orca_run pm-start-create -- terminal create --worktree "id:$observed_id" --title "$title" --command "$command" --json || true
  created="$AFK_ORCA_OUT"
  terminal="$(jq -r '.result.terminal.handle // .handle // empty' <<<"$created" 2>/dev/null)"
  [[ -n "$terminal" ]] || return 1

  # The row carries the terminal's identity tuple (AD-28 R4), or null when
  # Orca can't show it yet; the handle alone still blocks a second start.
  local identity=null
  if afk_orca_identity "$terminal" "$harness"; then identity="$AFK_ORCA_IDENTITY"; fi
  ledger="$(jq -c --arg id "$id" --arg t "$terminal" --arg slug "$slug" --arg h "$harness" \
    --arg r "$repo_path" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson identity "$identity" \
    '.pm_started = ((.pm_started // {}) + {($id): {terminal:$t, slug:$slug, harness:$h, repo:$r, at:$at, identity:$identity}})' \
    <<<"$ledger")"
  return 0
}

# --- AC-7b: the stale-lock reap, shared by the pass and `--status` ----------
# `<lockdir>` carries no owner record until this story: the owner PID file
# written on take is the whole new mechanism, nothing else changes. Never
# reaps a lock that is merely young, and never reaps one whose owner PID is
# still alive.
afk_pcs_path_age() { # <path> -> seconds since mtime, or fails
  local mtime
  mtime="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null)" || return 1
  [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$(( $(date +%s) - mtime ))"
}

afk_pcs_lock_is_stale() { # <lockdir> <interval_seconds> [<holder_cmd_pattern>]
  local lockdir="$1" interval="$2" pattern="${3:-paperclip-poll}" age pid=""
  [[ -d "$lockdir" && ! -L "$lockdir" ]] || return 1
  age="$(afk_pcs_path_age "$lockdir")" || return 1
  (( age > interval * 5 )) || return 1
  [[ -f "$lockdir/owner" ]] && pid="$(awk '{print $1}' "$lockdir/owner" 2>/dev/null)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    # Alive. Only a reused PID (provably not the expected paperclip writer)
    # is stale; without /proc we cannot tell, so the lock stands.
    [[ -r "/proc/$pid/cmdline" ]] || return 1
    tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -Eq -- "$pattern" && return 1
  fi
  return 0
}

afk_pcs_lock_stale_reap() { # <lockdir> <interval_seconds> [<holder_cmd_pattern>]
  local lockdir="$1" interval="$2" pattern="${3:-paperclip-poll}" reaplock="$1.reap" age rc=1
  [[ "$interval" =~ ^[0-9]+$ ]] || interval=90
  # Serialise reapers: without this, a reaper that checked before a peer's
  # reap+mkdir would delete the peer's fresh, live lock. The staleness check
  # runs under the reap lock, so a peer's new lock is always seen as young.
  if ! mkdir "$reaplock" 2>/dev/null; then
    age="$(afk_pcs_path_age "$reaplock")" || return 1
    (( age > interval )) || return 1
    rmdir "$reaplock" 2>/dev/null; mkdir "$reaplock" 2>/dev/null || return 1
  fi
  afk_pcs_lock_is_stale "$lockdir" "$interval" "$pattern" && rm -rf -- "$lockdir" && rc=0
  rmdir "$reaplock" 2>/dev/null
  return "$rc"
}

# --- AC-7: agent-flow-kit paperclip-timer ------------------------------------
afk_pct_platform() {
  case "$(uname -s 2>/dev/null)" in
    Linux*) printf 'linux' ;;
    Darwin*) printf 'darwin' ;;
    *) printf 'unknown' ;;
  esac
}

afk_pct_systemd_dir() { printf '%s' "${AFK_PCT_SYSTEMD_DIR:-${HOME:-}/.config/systemd/user}"; }

afk_pct_service() {
  printf '%s\n' \
    '# Managed by agent-flow-kit paperclip-timer; re-run it rather than editing.' \
    '[Unit]' 'Description=agent-flow-kit Paperclip poll' '' \
    '[Service]' 'Type=oneshot' \
    "Environment=\"AFK_STATE_DIR=$(afk_au_sd "$AFK_STATE_DIR")\"" \
    "ExecStart=\"$(afk_au_sd "$AFK_KIT_ROOT")/bin/agent-flow-kit\" paperclip-poll"
}

afk_pct_timer() {
  printf '%s\n' \
    '# Managed by agent-flow-kit paperclip-timer; re-run it rather than editing.' \
    '[Unit]' 'Description=agent-flow-kit Paperclip poll timer' '' \
    '[Timer]' 'OnActiveSec=90s' 'OnUnitActiveSec=90s' 'RandomizedDelaySec=15s' 'Persistent=false' '' \
    '[Install]' 'WantedBy=timers.target'
}

afk_cmd_paperclip_timer() { # <json_mode> <action: install|remove|status>
  local json_mode="$1" action="$2" platform
  platform="$(afk_pct_platform)"

  if [[ "$action" == install || "$action" == status ]] && [[ "$platform" == darwin ]]; then
    afk_pc_emit_refusal "PAPERCLIP_TIMER_UNSUPPORTED_PLATFORM" "$json_mode"
    return 1
  fi

  case "$action" in
    install)
      if [[ "$platform" != linux ]]; then
        afk_pc_emit_refusal "PAPERCLIP_TIMER_UNSUPPORTED_PLATFORM" "$json_mode"
        return 1
      fi
      # The unit carries no secret, so the pass must be able to read the key
      # with only what the unit gives it.
      local code
      if ! afk_pc_load_config; then code="$AFK_PC_REFUSAL"; else code="$(afk_pc_unit_key_check)"; fi
      if [[ -n "$code" ]]; then afk_pc_emit_refusal "$code" "$json_mode"; return 1; fi
      local sysd_dir; sysd_dir="$(afk_pct_systemd_dir)"
      mkdir -p -- "$sysd_dir" 2>/dev/null || { afk_pc_emit_refusal "PAPERCLIP_TIMER_WRITE_FAILED" "$json_mode"; return 1; }
      afk_pct_service >"$sysd_dir/$AFK_PCT_UNIT.service" 2>/dev/null || { afk_pc_emit_refusal "PAPERCLIP_TIMER_WRITE_FAILED" "$json_mode"; return 1; }
      afk_pct_timer >"$sysd_dir/$AFK_PCT_UNIT.timer" 2>/dev/null || { afk_pc_emit_refusal "PAPERCLIP_TIMER_WRITE_FAILED" "$json_mode"; return 1; }
      systemctl --user daemon-reload >/dev/null 2>&1 </dev/null
      if ! systemctl --user enable --now "$AFK_PCT_UNIT.timer" >/dev/null 2>&1 </dev/null; then
        afk_pc_emit_refusal "PAPERCLIP_TIMER_ENABLE_FAILED" "$json_mode"
        return 1
      fi
      if [[ "$json_mode" == true ]]; then jq -nc '{result:"installed"}'; else printf 'paperclip-timer: installed\n'; fi
      return 0 ;;
    remove)
      local sysd_dir; sysd_dir="$(afk_pct_systemd_dir)"
      systemctl --user disable --now "$AFK_PCT_UNIT.timer" >/dev/null 2>&1 </dev/null || true
      rm -f -- "$sysd_dir/$AFK_PCT_UNIT.service" "$sysd_dir/$AFK_PCT_UNIT.timer"
      systemctl --user daemon-reload >/dev/null 2>&1 </dev/null || true
      if [[ "$json_mode" == true ]]; then jq -nc '{result:"removed"}'; else printf 'paperclip-timer: removed\n'; fi
      return 0 ;;
    status)
      local enabled active lockdir reaped="false" last_pass="" reason="" key_code
      if ! afk_pc_load_config; then key_code="$AFK_PC_REFUSAL"; else key_code="$(afk_pc_unit_key_check)"; fi
      enabled="$(systemctl --user is-enabled "$AFK_PCT_UNIT.timer" 2>/dev/null </dev/null)"
      active="$(systemctl --user is-active "$AFK_PCT_UNIT.timer" 2>/dev/null </dev/null)"
      lockdir="$AFK_STATE_DIR/paperclip/.lock"
      afk_pcs_lock_stale_reap "$lockdir" "${AFK_PAPERCLIP_POLL_INTERVAL_SECONDS:-90}" && reaped="true"
      last_pass="$(jq -r '.last_successful_pass // empty' "$AFK_STATE_DIR/paperclip/ledger.json" 2>/dev/null)"
      if [[ -n "$last_pass" ]]; then
        local epoch now
        epoch="$(afk_epoch_of_utc "$last_pass" 2>/dev/null)" || epoch=""
        now="$(date -u +%s)"
        if [[ -z "$epoch" ]] || (( now - epoch > 3 * ${AFK_PAPERCLIP_POLL_INTERVAL_SECONDS:-90} )); then
          reason="PAPERCLIP_POLLER_STALE"
        fi
      else
        reason="PAPERCLIP_POLLER_STALE"
      fi
      # A key the unit cannot read is the cause a stale pass would only hint at.
      [[ -n "$key_code" ]] && reason="$key_code"
      if [[ "$json_mode" == true ]]; then
        jq -nc --arg e "${enabled:-unknown}" --arg a "${active:-unknown}" \
          --arg lp "$last_pass" --arg r "$reason" --argjson sr "$reaped" \
          '{enabled:$e, active:$a, last_successful_pass:(if $lp=="" then null else $lp end),
            reason:(if $r=="" then null else $r end), lock_stale_reaped:$sr,
            lock:(if $sr then "PAPERCLIP_LOCK_STALE" else null end)}'
      else
        printf 'paperclip-timer: enabled=%s active=%s last_successful_pass=%s%s%s\n' \
          "${enabled:-unknown}" "${active:-unknown}" "${last_pass:-none}" "${reason:+ ($reason)}" \
          "$([[ "$reaped" == true ]] && printf ' (PAPERCLIP_LOCK_STALE: reaped)')"
      fi
      [[ -z "$reason" ]]
      return $? ;;
    *)
      afk_pc_emit_refusal "PAPERCLIP_TIMER_UNKNOWN_ACTION" "$json_mode"
      return 1 ;;
  esac
}
