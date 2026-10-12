#!/usr/bin/env bash
# afk-paperclip-report.sh — `agent-flow-kit paperclip-report`: the PM's only
# way to write to Paperclip (AFK-PC-3a, AD-7/AD-8). See docs/PAPERCLIP.md.
#
# Reuses afk_pc_uuid_ok, afk_pc_spool_dir, afk_pc_load_config,
# afk_pc_final_intent_valid (from lib/afk-paperclip.sh),
# afk_pm_registry_lookup (from lib/afk-pm-registry.sh), and, for a final,
# afk_pce_readiness and afk_pce_common_dir (from lib/afk-paperclip-
# evidence.sh), which must be sourced before a call. This file is SOURCED,
# never executed.

if [[ -n "${AFK_PAPERCLIP_REPORT_SOURCED:-}" ]]; then
  return 0
fi
AFK_PAPERCLIP_REPORT_SOURCED=1

AFK_PCR_QID_RE='^[a-z0-9-]{1,32}$'

afk_pcr_emit_refusal() { # <reason> <json_mode>
  if [[ "$2" == true ]]; then
    jq -nc --arg r "$1" '{result:$r}'
  else
    printf 'agent-flow-kit paperclip-report: %s\n' "$1"
  fi
}

# afk_pcr_new_uuid -- a fresh id shaped like afk_pc_uuid_ok expects.
afk_pcr_new_uuid() {
  local u=""
  [[ -r /proc/sys/kernel/random/uuid ]] && u="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)"
  if ! afk_pc_uuid_ok "$u"; then
    local hex; hex="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    [[ ${#hex} -eq 32 ]] || return 1
    u="${hex:0:8}-${hex:8:4}-${hex:12:4}-${hex:16:4}-${hex:20:12}"
  fi
  afk_pc_uuid_ok "$u" && printf '%s' "$u"
}

# afk_pcr_lock <lockdir> -- the kit's portable mkdir lock (no flock), spun
# rather than refused, so two concurrent writers serialize instead of racing.
# Bounded so a genuinely stuck lock is a reported failure, never a hang; a
# retry that times out here never removes the lock -- only the staleness
# check below (dead or reused holder PID) does that.
#
# AC-3: records its holder (PID plus command) the same way the poll lock has
# since #74 (afk_pcs_lock_is_stale / afk_pcs_lock_stale_reap, lib/afk-
# paperclip-start.sh), reused here rather than reinvented, with the holder
# pattern set to this command instead of paperclip-poll. The reap itself is
# already serialised there (a `.reap` sub-lock), so a live holder is never
# touched by a concurrent reaper. Retried on a slower cadence than the mkdir
# spin so a busy lock isn't stat(2)-hammered every 20 ms.
AFK_PCR_LOCK_STALE_INTERVAL_SECONDS="${AFK_PCR_LOCK_STALE_INTERVAL_SECONDS:-30}"
AFK_PCR_HELD_LOCK=""
afk_pcr_lock() {
  local dir="$1" waited=0
  while ! mkdir "$dir" 2>/dev/null; do
    if (( waited % 100 == 0 )) && declare -F afk_pcs_lock_stale_reap >/dev/null 2>&1 && \
       afk_pcs_lock_stale_reap "$dir" "$AFK_PCR_LOCK_STALE_INTERVAL_SECONDS" "paperclip-report|paperclip-poll" && \
       mkdir "$dir" 2>/dev/null; then
      declare -F afk_warn >/dev/null 2>&1 && afk_warn "PAPERCLIP_LOCK_STALE: reaped a spool lock left by a dead writer"
      break
    fi
    sleep 0.02
    waited=$((waited + 1))
    (( waited > 500 )) && return 1
  done
  AFK_PCR_HELD_LOCK="$dir"
  printf '%s %s\n' "$$" "$(date +%s)" >"$dir/owner" 2>/dev/null || true
  trap '[[ -n "$AFK_PCR_HELD_LOCK" ]] && { rm -f "$AFK_PCR_HELD_LOCK/owner" 2>/dev/null; rmdir "$AFK_PCR_HELD_LOCK" 2>/dev/null; }; declare -F afk_release_on_exit >/dev/null && afk_release_on_exit' EXIT
  return 0
}
afk_pcr_unlock() { rm -f "$1/owner" 2>/dev/null; rmdir "$1" 2>/dev/null || true; AFK_PCR_HELD_LOCK=""; }

# afk_pcr_owner_repo <issue-id> -- sets AFK_PCR_REPO_PATH on success. Resolves
# the issue's pinned slug from the poller ledger, then the repo from that
# slug's projects[] row in the paperclip config -- the same source
# paperclip-take reads, never the issue's live projectId (AD-23). A direct
# call (never `$(...)`): AFK_PCR_REFUSAL is set on failure and must reach the
# caller's shell, not a subshell.
afk_pcr_owner_repo() {
  local id="$1" ledger_path="$AFK_STATE_DIR/paperclip/ledger.json" ledger="" slug
  AFK_PCR_REPO_PATH=""
  [[ -r "$ledger_path" ]] && ledger="$(jq -c '.' "$ledger_path" 2>/dev/null)"
  [[ -n "$ledger" ]] || ledger='{"issues":{}}'
  slug="$(jq -r --arg id "$id" '.issues[$id].slug // empty' <<<"$ledger")"
  [[ -n "$slug" ]] || { AFK_PCR_REFUSAL="PAPERCLIP_ISSUE_UNKNOWN"; return 1; }
  if ! afk_pc_load_config; then AFK_PCR_REFUSAL="$AFK_PC_REFUSAL"; return 1; fi
  AFK_PCR_REPO_PATH="$(jq -r '.repo_path // empty' <<<"$(afk_pc_project_row "$slug")")"
  [[ -n "$AFK_PCR_REPO_PATH" ]] || { AFK_PCR_REFUSAL="PAPERCLIP_ISSUE_UNKNOWN"; return 1; }
  return 0
}

# afk_pcr_require_owner <repo_path> -- AC-1: the same live-owner/handoff-
# successor check as paperclip-take, via ORCA_TERMINAL_HANDLE.
afk_pcr_require_owner() {
  local repo_path="$1" terminal lookup state claim_terminal=""
  terminal="${ORCA_TERMINAL_HANDLE:-}"
  [[ -n "$terminal" ]] || { AFK_PCR_REFUSAL="PAPERCLIP_NOT_OWNER"; return 1; }
  lookup="$(afk_pm_registry_lookup "$repo_path")"
  state="$(jq -r .state <<<"$lookup")"
  case "$state" in
    live | unknown)
      afk_pmr_caller_owns "$lookup" "$terminal" && claim_terminal="$terminal" ;;
    handoff_in_progress | handoff_stalled)
      local succ; succ="$(jq -r '.handoff.successor.terminal // empty' <<<"$lookup")"
      [[ -n "$succ" && "$terminal" == "$succ" ]] &&
        jq -e '.handoff.state|IN("SUCCESSOR_LAUNCHED","ACKED")' <<<"$lookup" >/dev/null 2>&1 && claim_terminal="$terminal" ;;
  esac
  [[ -n "$claim_terminal" ]] || { AFK_PCR_REFUSAL="PAPERCLIP_NOT_OWNER"; return 1; }
  return 0
}

# afk_pcr_body_read <path> -- sets AFK_PCR_BODY on success (never printed
# elsewhere): at most 16 KiB on disk, no embedded NUL, valid UTF-8, read from
# a file, never an argument. A direct call (never `$(...)`), for the same
# reason as above.
#
# The open, the regular-file re-check and the bounded read all happen inside
# one `timeout`-bounded subshell, against one descriptor it opens exactly
# once -- never the path again. This is what closes the window a plain `-f`
# check followed by a separate `exec` cannot: a path swapped for a FIFO after
# the initial check (or a FIFO racing back in) blocks the open() syscall
# itself, not just the read, and only a wall-clock timeout around the whole
# open+read recovers from that. `timeout` kills the subshell's process group
# so a would-be blocked open or read never wedges the caller.
AFK_PCR_BODY_READ_TIMEOUT="${AFK_PCR_BODY_READ_TIMEOUT:-5}"
afk_pcr_body_read() {
  local path="$1" tmp size size_no_nul body bound=""
  AFK_PCR_BODY=""
  # GNU timeout, or coreutils' gtimeout on macOS; with neither, the read
  # cannot be bounded, so it is refused rather than risked unbounded.
  if command -v timeout >/dev/null 2>&1; then bound=timeout
  elif command -v gtimeout >/dev/null 2>&1; then bound=gtimeout
  else AFK_PCR_REFUSAL="PAPERCLIP_BODY_UNREADABLE"; return 1
  fi
  # A regular file only, checked by name first so an obviously bad path (a
  # FIFO already sitting there, a missing file) is refused without ever
  # opening it.
  [[ -n "$path" && -f "$path" && -r "$path" ]] || { AFK_PCR_REFUSAL="PAPERCLIP_BODY_UNREADABLE"; return 1; }
  tmp="$(mktemp 2>/dev/null)" || { AFK_PCR_REFUSAL="PAPERCLIP_BODY_UNREADABLE"; return 1; }
  if ! "$bound" "$AFK_PCR_BODY_READ_TIMEOUT" bash -c '
        exec {fd}<"$1" 2>/dev/null || exit 1
        [[ -f "/dev/fd/$fd" ]] || exit 1
        head -c 16385 <&"$fd"
      ' _ "$path" >"$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    AFK_PCR_REFUSAL="PAPERCLIP_BODY_UNREADABLE"; return 1
  fi
  local LC_ALL=C
  size="$(wc -c <"$tmp")"; size="${size//[[:space:]]/}"
  size_no_nul="$(tr -d '\000' <"$tmp" | wc -c)"; size_no_nul="${size_no_nul//[[:space:]]/}"
  if [[ "$size" != "$size_no_nul" ]]; then
    rm -f -- "$tmp"
    AFK_PCR_REFUSAL="PAPERCLIP_BODY_INVALID"; return 1
  fi
  (( size >= 0 && size <= 16384 )) || { rm -f -- "$tmp"; AFK_PCR_REFUSAL="PAPERCLIP_BODY_TOO_LARGE"; return 1; }
  IFS= read -r -d '' body <"$tmp"
  rm -f -- "$tmp"
  if ! printf '%s' "$body" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
    AFK_PCR_REFUSAL="PAPERCLIP_BODY_INVALID"; return 1
  fi
  AFK_PCR_BODY="$body"
  return 0
}

afk_pcr_emit_not_ready() { # <reasons-json> <json_mode>
  if [[ "$2" == true ]]; then
    jq -nc --argjson r "$1" '{result:"FINAL_NOT_READY", reasons:$r}'
  else
    printf 'agent-flow-kit paperclip-report: FINAL_NOT_READY: %s\n' "$(jq -r 'join(" ")' <<<"$1")"
  fi
}

# afk_pcr_ledger_row <issue> -- the issue's poller ledger row, compact; empty
# when the ledger or the row is unreadable. Reads only.
afk_pcr_ledger_row() {
  local lp="$AFK_STATE_DIR/paperclip/ledger.json"
  [[ -r "$lp" ]] || return 0
  jq -c --arg id "$1" '.issues[$id] | objects' "$lp" 2>/dev/null
}

# afk_pcr_final_outstanding <ledger-row> -- 0 while the row holds a /2 final
# intent, in any state, or the cleanup of a withdrawn one. The spool stays
# closed to every entry until the poller's withdrawal cleanup clears it.
afk_pcr_final_outstanding() {
  jq -e '(.final_intent // null) != null or (.final_withdraw_cleanup // null) != null' \
    <<<"${1:-null}" >/dev/null 2>&1
}

# afk_pcr_spool_drained <issue> <ledger-row> -- 0 when no live entry is
# queued and no send is in flight. A final behind a queued entry would stop
# the poller's drain with the issue left in_progress (AFK-PC-DELIVERY-L3 D1).
afk_pcr_spool_drained() {
  [[ -z "$(afk_pc_spool_files "$1")" ]] &&
    ! jq -e '(.sending // null) != null' <<<"${2:-null}" >/dev/null 2>&1
}

# The ledger fields a readiness answer or a final's payload depends on. The
# producer reads them before readiness and again under the lock; any change
# refuses READINESS_CHANGED rather than publishing a stale answer.
AFK_PCR_FENCE='{state, identifier, question_id, question_seq, question_reply, sending,
  pending_final, final_delivery_hold, final_intent, final_withdraw_cleanup}'

# afk_pcr_final_prepare <json_mode> <issue> <body> <dir> <commit> -- the
# producer's unlocked half (AFK-PC-DELIVERY-L3): a drained spool, then the
# full shared readiness reader for the physical <dir> at <commit>, peeled to a
# full commit id, with ambient GIT_* unset. Only a ready answer becomes an
# entry: kind final_intent, schema /2, the ready evidence, tree, plan digest
# and paths, reviewer board_user_id, status in_review. Writes nothing. Sets
# AFK_PCR_FINAL_{ENTRY,MARKER,FENCE} or prints its own refusal; a direct
# call (never `$(...)`).
afk_pcr_final_prepare() {
  local json_mode="$1" id="$2" body="$3" dir="$4" commit="$5" row r eid
  AFK_PCR_FINAL_ENTRY="" AFK_PCR_FINAL_MARKER="" AFK_PCR_FINAL_FENCE=""
  row="$(afk_pcr_ledger_row "$id")"
  afk_pcr_spool_drained "$id" "$row" || { afk_pcr_emit_refusal "PAPERCLIP_SPOOL_NOT_DRAINED" "$json_mode"; return 2; }
  AFK_PCR_FINAL_FENCE="$(jq -cS "$AFK_PCR_FENCE" <<<"${row:-null}" 2>/dev/null)"
  r="$(unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
         GIT_ALTERNATE_OBJECT_DIRECTORIES
       p="$(CDPATH='' cd -- "$dir" 2>/dev/null && pwd -P)" || p="$dir"
       c="$(git -C "$p" rev-parse -q --verify "$commit^{commit}" 2>/dev/null)" || c=""
       o="$(afk_pce_readiness "$id" "$p" "${c:-$commit}" 2>/dev/null)" || exit 1
       jq -c --arg d "$p" --arg cd "$(afk_pce_common_dir "$p")" --arg c "$c" \
         '. + {dir:$d, common_dir:$cd, commit:$c}' <<<"$o")" || r=""
  if ! jq -e 'type == "object" and (.ready | type) == "boolean" and (.reasons | type) == "array"' <<<"$r" >/dev/null 2>&1; then
    afk_pcr_emit_not_ready '["READINESS_UNAVAILABLE"]' "$json_mode"; return 2
  fi
  if [[ "$(jq -r .ready <<<"$r")" != true ]]; then
    afk_pcr_emit_not_ready "$(jq -c '[.reasons[] | strings] | if length == 0 then ["READINESS_NOT_READY"] else . end' <<<"$r")" "$json_mode"
    return 2
  fi
  eid="$(afk_pcr_new_uuid)" || { afk_pcr_emit_refusal "PAPERCLIP_REGISTRY_WRITE_FAILED" "$json_mode"; return 1; }
  AFK_PCR_FINAL_ENTRY="$(jq -c --arg e "$eid" --arg i "$id" --arg b "$body" --argjson row "${row:-null}" \
    --arg u "$(jq -r '.board_user_id // empty | strings' <<<"${AFK_PC_CFG:-null}" 2>/dev/null)" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{id:$e, kind:"final_intent", schema:"afk-paperclip-final/2", issue:$i, identifier:($row.identifier // null),
      plan_digest, evidence_set_sha256, tree, commit, dir, common_dir, status:"in_review",
      reviewer_user_id:$u, body:$b, published_at:$at}' <<<"$r" 2>/dev/null)"
  # The poller's own validator: an entry it would dead-letter is never written.
  if ! afk_pc_final_intent_valid "$AFK_PCR_FINAL_ENTRY" "$id"; then
    AFK_PCR_FINAL_ENTRY=""
    afk_pcr_emit_refusal "PAPERCLIP_FINAL_INTENT_INVALID" "$json_mode"; return 2
  fi
  AFK_PCR_FINAL_MARKER="$(jq -c '{schema, entry_id:.id, issue, evidence_set_sha256}' <<<"$AFK_PCR_FINAL_ENTRY")"
  return 0
}

# afk_pcr_report_entry <json_mode> <issue> <comment_file> <question_id> <final>
#                      [<dir> <commit>]
# AC-2/AC-3: publish one spool entry under a locked per-issue counter. A
# final is only `in_review` with its worktree and handoff commit, and is
# published as a /2 final_intent followed by its strict marker.
afk_pcr_report_entry() {
  local json_mode="$1" id="$2" comment_file="$3" qid="$4" final="$5" dir="${6:-}" commit="${7:-}"
  local spool_dir; spool_dir="$(afk_pc_spool_dir "$id")"
  local final_marker="$spool_dir/.final"

  if [[ -n "$qid" ]]; then
    [[ "$qid" =~ $AFK_PCR_QID_RE ]] || { afk_pcr_emit_refusal "PAPERCLIP_QUESTION_ID_INVALID" "$json_mode"; return 4; }
  fi
  if [[ -n "$final" ]]; then
    # Josh completes the work in Paperclip: an agent `done` is never written.
    [[ "$final" == in_review ]] || { afk_pcr_emit_refusal "PAPERCLIP_FINAL_STATUS_INVALID" "$json_mode"; return 4; }
    [[ -n "$dir" && "$commit" =~ ^[0-9a-f]{7,64}$ ]] ||
      { afk_pcr_emit_refusal "FINAL_EVIDENCE_ARGS_REQUIRED" "$json_mode"; return 4; }
  fi
  [[ -e "$final_marker" ]] && { afk_pcr_emit_refusal "PAPERCLIP_SPOOL_CLOSED" "$json_mode"; return 2; }
  afk_pcr_final_outstanding "$(afk_pcr_ledger_row "$id")" &&
    { afk_pcr_emit_refusal "PAPERCLIP_SPOOL_CLOSED" "$json_mode"; return 2; }

  if [[ -n "$final" ]]; then
    local ledger_path="$AFK_STATE_DIR/paperclip/ledger.json" ledger="" pending
    [[ -r "$ledger_path" ]] && ledger="$(jq -c '.' "$ledger_path" 2>/dev/null)"
    [[ -n "$ledger" ]] || ledger='{"issues":{}}'
    pending="$(jq -r --arg id "$id" '((.issues[$id].pending_cost_results // []) | length) > 0' <<<"$ledger")"
    [[ "$pending" == true ]] && { afk_pcr_emit_refusal "COST_EVENTS_PENDING" "$json_mode"; return 2; }
  fi

  afk_pcr_body_read "$comment_file" || { afk_pcr_emit_refusal "$AFK_PCR_REFUSAL" "$json_mode"; return 4; }
  local body="$AFK_PCR_BODY"
  if [[ -n "$final" ]]; then
    afk_pcr_final_prepare "$json_mode" "$id" "$body" "$dir" "$commit" || return $?
  fi

  afk_state_dir_ensure "$spool_dir" || { afk_pcr_emit_refusal "PAPERCLIP_REGISTRY_WRITE_FAILED" "$json_mode"; return 1; }
  local lockdir="$spool_dir/.seq.lock"
  afk_pcr_lock "$lockdir" || { afk_pcr_emit_refusal "PAPERCLIP_LOCK_TIMEOUT" "$json_mode"; return 1; }
  local now_row why=""
  now_row="$(afk_pcr_ledger_row "$id")"
  if [[ -e "$final_marker" ]] || afk_pcr_final_outstanding "$now_row"; then
    why=PAPERCLIP_SPOOL_CLOSED
  elif [[ -n "$final" ]] && ! afk_pcr_spool_drained "$id" "$now_row"; then
    why=PAPERCLIP_SPOOL_NOT_DRAINED
  elif [[ -n "$final" && "$(jq -cS "$AFK_PCR_FENCE" <<<"${now_row:-null}" 2>/dev/null)" != "$AFK_PCR_FINAL_FENCE" ]]; then
    why=READINESS_CHANGED
  fi
  if [[ -n "$why" ]]; then
    afk_pcr_unlock "$lockdir"
    if [[ "$why" == READINESS_CHANGED ]]; then afk_pcr_emit_not_ready '["READINESS_CHANGED"]' "$json_mode"
    else afk_pcr_emit_refusal "$why" "$json_mode"; fi
    return 2
  fi

  local seq_file="$spool_dir/.seq" cur=0 seq
  [[ -r "$seq_file" ]] && cur="$(cat "$seq_file" 2>/dev/null)"
  [[ "$cur" =~ ^[0-9]+$ ]] || cur=0
  seq=$((10#$cur + 1))
  # A writer interrupted between its publish and its counter write leaves the
  # counter one behind a live entry; step past it rather than fail every later
  # write until the reader drains that entry.
  while [[ -e "$spool_dir/$(printf '%08d' "$seq").json" ]]; do seq=$((seq + 1)); done

  local eid rc=0
  if [[ -n "$final" ]]; then
    eid="$(jq -r .id <<<"$AFK_PCR_FINAL_ENTRY")"
  else
    eid="$(afk_pcr_new_uuid)" || rc=1
  fi
  local kind entry
  if (( rc == 0 )); then
    if [[ -n "$final" ]]; then
      kind=final_intent
      entry="$AFK_PCR_FINAL_ENTRY"
    elif [[ -n "$qid" ]]; then
      kind=question
      entry="$(jq -nc --arg id "$eid" --arg k "$kind" --arg b "$body" --arg q "$qid" \
        '{id:$id, kind:$k, body:$b, question_id:$q}')"
    else
      kind=comment
      entry="$(jq -nc --arg id "$eid" --arg k "$kind" --arg b "$body" '{id:$id, kind:$k, body:$b}')"
    fi
  fi

  local tmp_path="$spool_dir/.tmp/$eid.json"
  (( rc == 0 )) && { afk_state_dir_ensure "$spool_dir/.tmp" || rc=1; }
  (( rc == 0 )) && { afk_state_file_write "$tmp_path" "$entry" || rc=1; }

  local final_name final_path published=false
  printf -v final_name '%08d.json' "$seq"
  final_path="$spool_dir/$final_name"
  if (( rc == 0 )); then
    if mv -n -- "$tmp_path" "$final_path" 2>/dev/null && [[ ! -e "$tmp_path" ]]; then
      published=true
    else
      rc=1
      rm -f -- "$tmp_path" 2>/dev/null
    fi
  fi
  (( rc == 0 )) && { afk_state_file_write "$seq_file" "$seq" || rc=1; }
  # The marker comes last, never first: an entry without its marker is
  # withdrawn by the poller (FINAL_MARKER_MISSING), while a marker without an
  # entry would close the spool for good.
  if (( rc == 0 )) && [[ "$kind" == final_intent ]]; then
    afk_state_file_write "$final_marker" "$AFK_PCR_FINAL_MARKER" || rc=1
  fi

  # A later write (seq/final) failing after the entry was already published
  # would otherwise leave a live spool entry the reader can list before this
  # lock releases; remove exactly that entry, never anything else in the
  # spool.
  (( rc == 0 )) || { [[ "$published" == true ]] && rm -f -- "$final_path" 2>/dev/null; }
  afk_pcr_unlock "$lockdir"
  if (( rc != 0 )); then
    afk_pcr_emit_refusal "PAPERCLIP_REGISTRY_WRITE_FAILED" "$json_mode"
    return 1
  fi

  if [[ "$json_mode" == true ]]; then
    jq -nc --arg id "$id" --argjson seq "$seq" '{result:"ok", issue:$id, seq:$seq}'
  else
    printf '%s\n' "$seq"
  fi
  return 0
}

# afk_pcr_report_status <json_mode> <issue> <text> <story> -- AC-4: declared
# status, atomic, version-incrementing, independent of the spool.
afk_pcr_report_status() {
  local json_mode="$1" id="$2" text="$3" story="$4"
  (( ${#text} <= 120 )) || { afk_pcr_emit_refusal "PAPERCLIP_STATUS_INVALID" "$json_mode"; return 4; }
  [[ "$text" != *[[:cntrl:]]* ]] || { afk_pcr_emit_refusal "PAPERCLIP_STATUS_INVALID" "$json_mode"; return 4; }
  if [[ -n "$story" ]]; then
    [[ "$story" =~ ^[0-9]+/[0-9]+$ ]] || { afk_pcr_emit_refusal "PAPERCLIP_STATUS_INVALID" "$json_mode"; return 4; }
  fi

  local dir="$AFK_STATE_DIR/paperclip/status"
  afk_state_dir_ensure "$dir" || { afk_pcr_emit_refusal "PAPERCLIP_REGISTRY_WRITE_FAILED" "$json_mode"; return 1; }
  local path="$dir/$id.json" lockdir="$dir/.$id.lock"
  afk_pcr_lock "$lockdir" || { afk_pcr_emit_refusal "PAPERCLIP_LOCK_TIMEOUT" "$json_mode"; return 1; }

  local cur=0
  [[ -r "$path" ]] && cur="$(jq -r '.version // 0' "$path" 2>/dev/null)"
  [[ "$cur" =~ ^[0-9]+$ ]] || cur=0
  local version=$((cur + 1)) doc at
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  doc="$(jq -nc --arg text "$text" --arg story "${story:-}" --argjson version "$version" --arg at "$at" \
    '{schema:"afk-paperclip-status/1", text:$text, story:(if $story == "" then null else $story end),
      version:$version, updated_at:$at}')"

  local rc=0
  afk_state_file_write "$path" "$doc" || rc=1
  afk_pcr_unlock "$lockdir"
  if (( rc != 0 )); then
    afk_pcr_emit_refusal "PAPERCLIP_REGISTRY_WRITE_FAILED" "$json_mode"
    return 1
  fi

  if [[ "$json_mode" == true ]]; then
    jq -nc --arg id "$id" --argjson version "$version" '{result:"ok", issue:$id, version:$version}'
  else
    printf '%s\n' "$version"
  fi
  return 0
}

# afk_cmd_paperclip_report <json_mode> <issue> <comment_file> <question_id>
#                          <final> <status_text> <story> <dir> <commit>
afk_cmd_paperclip_report() {
  local json_mode="$1" id="$2" comment_file="$3" qid="$4" final="$5" status_text="$6" story="$7"
  local dir="${8:-}" commit="${9:-}"
  AFK_PCR_REFUSAL=""

  afk_pc_uuid_ok "$id" || { afk_pcr_emit_refusal "PAPERCLIP_ISSUE_UNKNOWN" "$json_mode"; return 4; }

  afk_pcr_owner_repo "$id" || { afk_pcr_emit_refusal "$AFK_PCR_REFUSAL" "$json_mode"; return 4; }

  afk_pcr_require_owner "$AFK_PCR_REPO_PATH" || { afk_pcr_emit_refusal "$AFK_PCR_REFUSAL" "$json_mode"; return 2; }

  if [[ -n "$status_text" ]]; then
    afk_pcr_report_status "$json_mode" "$id" "$status_text" "$story"
    return $?
  fi
  afk_pcr_report_entry "$json_mode" "$id" "$comment_file" "$qid" "$final" "$dir" "$commit"
}
