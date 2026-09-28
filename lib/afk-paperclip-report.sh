#!/usr/bin/env bash
# afk-paperclip-report.sh — `agent-flow-kit paperclip-report`: the PM's only
# way to write to Paperclip (AFK-PC-3a, AD-7/AD-8). See docs/PAPERCLIP.md.
#
# Reuses afk_pc_uuid_ok, afk_pc_spool_dir, afk_pc_load_config (from
# lib/afk-paperclip.sh) and afk_pm_registry_lookup (from
# lib/afk-pm-registry.sh), which must already be sourced. This file is
# SOURCED, never executed.

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
# Bounded so a genuinely stuck lock is a reported failure, never a hang.
# A held lock is also released on EXIT, which the entry point's signal
# handlers reach by exiting: an interrupted writer never strands the lock and
# wedges every later write for the issue. The entry point's own EXIT handler
# is chained, not replaced.
AFK_PCR_HELD_LOCK=""
afk_pcr_lock() {
  local dir="$1" waited=0
  while ! mkdir "$dir" 2>/dev/null; do
    sleep 0.02
    waited=$((waited + 1))
    (( waited > 500 )) && return 1
  done
  AFK_PCR_HELD_LOCK="$dir"
  trap '[[ -n "$AFK_PCR_HELD_LOCK" ]] && rmdir "$AFK_PCR_HELD_LOCK" 2>/dev/null; declare -F afk_release_on_exit >/dev/null && afk_release_on_exit' EXIT
  return 0
}
afk_pcr_unlock() { rmdir "$1" 2>/dev/null || true; AFK_PCR_HELD_LOCK=""; }

# afk_pcr_owner_repo <issue-id> -- sets AFK_PCR_REPO_PATH on success. Resolves
# the project from the poller ledger, then the repo from the paperclip
# config's agents list — the same source paperclip-take reads. A direct call
# (never `$(...)`): AFK_PCR_REFUSAL is set on failure and must reach the
# caller's shell, not a subshell.
afk_pcr_owner_repo() {
  local id="$1" ledger_path="$AFK_STATE_DIR/paperclip/ledger.json" ledger="" project
  AFK_PCR_REPO_PATH=""
  [[ -r "$ledger_path" ]] && ledger="$(jq -c '.' "$ledger_path" 2>/dev/null)"
  [[ -n "$ledger" ]] || ledger='{"issues":{}}'
  project="$(jq -r --arg id "$id" '.issues[$id].project // empty' <<<"$ledger")"
  [[ -n "$project" ]] || { AFK_PCR_REFUSAL="PAPERCLIP_ISSUE_UNKNOWN"; return 1; }
  if ! afk_pc_load_config; then AFK_PCR_REFUSAL="$AFK_PC_REFUSAL"; return 1; fi
  AFK_PCR_REPO_PATH="$(jq -r --arg p "$project" '[.agents[] | select(.project==$p)][0].repo_path // empty' <<<"$AFK_PC_CFG")"
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
    live)
      [[ "$terminal" == "$(jq -r .owner.terminal <<<"$lookup")" ]] && claim_terminal="$terminal" ;;
    handoff_in_progress | handoff_stalled)
      local succ; succ="$(jq -r '.handoff.successor.terminal // empty' <<<"$lookup")"
      [[ -n "$succ" && "$terminal" == "$succ" ]] && claim_terminal="$terminal" ;;
  esac
  [[ -n "$claim_terminal" ]] || { AFK_PCR_REFUSAL="PAPERCLIP_NOT_OWNER"; return 1; }
  return 0
}

# afk_pcr_body_read <path> -- sets AFK_PCR_BODY on success (never printed
# elsewhere): at most 16 KiB on disk and valid UTF-8, read from a file, never
# an argument. A direct call (never `$(...)`), for the same reason as above.
#
# Opens the path exactly once, then does every check (regular file, size,
# UTF-8) and the content read against that one descriptor. A caller that can
# replace the path between the initial `-f` check and the open (or race it
# for a FIFO/device) cannot redirect what gets read or hang the command: the
# descriptor is re-verified after the open, and the read below is bounded so
# even a would-be device fd cannot block indefinitely.
afk_pcr_body_read() {
  local path="$1" fd size body
  AFK_PCR_BODY=""
  # A regular file only, checked by name first so an obviously bad path (a
  # FIFO already sitting there, a missing file) is refused without ever
  # opening it.
  [[ -n "$path" && -f "$path" && -r "$path" ]] || { AFK_PCR_REFUSAL="PAPERCLIP_BODY_UNREADABLE"; return 1; }
  if ! exec {fd}<"$path" 2>/dev/null; then
    AFK_PCR_REFUSAL="PAPERCLIP_BODY_UNREADABLE"; return 1
  fi
  # Re-check the opened descriptor itself, not the path again: this is what
  # closes the window where the path was swapped for a FIFO or device
  # between the check above and this open.
  if [[ ! -f "/dev/fd/$fd" ]]; then
    exec {fd}<&-
    AFK_PCR_REFUSAL="PAPERCLIP_BODY_UNREADABLE"; return 1
  fi
  # Bounded read of one byte past the limit, from the fd only: never the
  # path again. `read -r -d ''` (via process substitution) preserves
  # trailing newlines that a bare command substitution would strip.
  IFS= read -r -d '' body < <(head -c 16385 <&"$fd"; printf '\0')
  exec {fd}<&-
  local LC_ALL=C
  size=${#body}
  (( size >= 0 && size <= 16384 )) || { AFK_PCR_REFUSAL="PAPERCLIP_BODY_TOO_LARGE"; return 1; }
  if ! printf '%s' "$body" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
    AFK_PCR_REFUSAL="PAPERCLIP_BODY_INVALID"; return 1
  fi
  AFK_PCR_BODY="$body"
  return 0
}

# afk_pcr_report_entry <json_mode> <issue> <comment_file> <question_id> <final>
# AC-2/AC-3: publish one spool entry under a locked per-issue counter.
afk_pcr_report_entry() {
  local json_mode="$1" id="$2" comment_file="$3" qid="$4" final="$5"
  local spool_dir; spool_dir="$(afk_pc_spool_dir "$id")"
  local final_marker="$spool_dir/.final"

  if [[ -n "$qid" ]]; then
    [[ "$qid" =~ $AFK_PCR_QID_RE ]] || { afk_pcr_emit_refusal "PAPERCLIP_QUESTION_ID_INVALID" "$json_mode"; return 4; }
  fi
  if [[ -n "$final" ]]; then
    case "$final" in in_review | done) ;; *)
      afk_pcr_emit_refusal "PAPERCLIP_FINAL_STATUS_INVALID" "$json_mode"; return 4 ;;
    esac
  fi
  [[ -e "$final_marker" ]] && { afk_pcr_emit_refusal "PAPERCLIP_SPOOL_CLOSED" "$json_mode"; return 2; }

  if [[ -n "$final" ]]; then
    local ledger_path="$AFK_STATE_DIR/paperclip/ledger.json" ledger="" pending
    [[ -r "$ledger_path" ]] && ledger="$(jq -c '.' "$ledger_path" 2>/dev/null)"
    [[ -n "$ledger" ]] || ledger='{"issues":{}}'
    pending="$(jq -r --arg id "$id" '((.issues[$id].pending_cost_results // []) | length) > 0' <<<"$ledger")"
    [[ "$pending" == true ]] && { afk_pcr_emit_refusal "COST_EVENTS_PENDING" "$json_mode"; return 2; }
  fi

  afk_pcr_body_read "$comment_file" || { afk_pcr_emit_refusal "$AFK_PCR_REFUSAL" "$json_mode"; return 4; }
  local body="$AFK_PCR_BODY"

  afk_state_dir_ensure "$spool_dir" || { afk_pcr_emit_refusal "PAPERCLIP_REGISTRY_WRITE_FAILED" "$json_mode"; return 1; }
  local lockdir="$spool_dir/.seq.lock"
  afk_pcr_lock "$lockdir" || { afk_pcr_emit_refusal "PAPERCLIP_LOCK_TIMEOUT" "$json_mode"; return 1; }
  if [[ -e "$final_marker" ]]; then
    afk_pcr_unlock "$lockdir"
    afk_pcr_emit_refusal "PAPERCLIP_SPOOL_CLOSED" "$json_mode"
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
  eid="$(afk_pcr_new_uuid)" || rc=1
  local kind entry
  if (( rc == 0 )); then
    if [[ -n "$final" ]]; then
      kind=final
      entry="$(jq -nc --arg id "$eid" --arg k "$kind" --arg b "$body" --arg s "$final" \
        '{id:$id, kind:$k, body:$b, status:$s}')"
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
  if (( rc == 0 )) && [[ "$kind" == final ]]; then
    afk_state_file_write "$final_marker" "$final" || rc=1
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
#                          <final> <status_text> <story>
afk_cmd_paperclip_report() {
  local json_mode="$1" id="$2" comment_file="$3" qid="$4" final="$5" status_text="$6" story="$7"
  AFK_PCR_REFUSAL=""

  afk_pc_uuid_ok "$id" || { afk_pcr_emit_refusal "PAPERCLIP_ISSUE_UNKNOWN" "$json_mode"; return 4; }

  afk_pcr_owner_repo "$id" || { afk_pcr_emit_refusal "$AFK_PCR_REFUSAL" "$json_mode"; return 4; }

  afk_pcr_require_owner "$AFK_PCR_REPO_PATH" || { afk_pcr_emit_refusal "$AFK_PCR_REFUSAL" "$json_mode"; return 2; }

  if [[ -n "$status_text" ]]; then
    afk_pcr_report_status "$json_mode" "$id" "$status_text" "$story"
    return $?
  fi
  afk_pcr_report_entry "$json_mode" "$id" "$comment_file" "$qid" "$final"
}
