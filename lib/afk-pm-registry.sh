#!/usr/bin/env bash
# afk-pm-registry.sh — "is there a live PM for this repo, and which terminal is
# it?" (AD-3, AD-7, review item F13), plus the PM's own notice verbs.
#
# This file is SOURCED, never executed, and (like every other lifecycle
# library) is independently sourceable: nothing here reads a variable it did
# not declare or receive as an argument.
#
# Never reap on uncertainty: an owner Orca cannot prove stale (AD-28 R5) is
# kept, so nothing is reaped and no second PM starts. Every scope key, session/claim key and notice
# id is validated before it is ever used in a path.

if [[ -n "${AFK_PM_REGISTRY_SOURCED:-}" ]]; then
  return 0
fi
AFK_PM_REGISTRY_SOURCED=1

# The one Orca resolver and bounded runner (AD-28 R1, R2).
# shellcheck source=lib/afk-orca.sh
# shellcheck disable=SC1091
declare -F afk_orca_run >/dev/null 2>&1 || . "$(dirname -- "${BASH_SOURCE[0]}")/afk-orca.sh"

# afk_scope_sha256 (the scope-key hash primitive) is defined by
# adapters/runtime-scope.sh, which this file reuses rather than
# re-implementing, so a "session" key here is bit-for-bit the same form the
# PM adapter already writes.
if ! declare -F afk_scope_sha256 >/dev/null 2>&1; then
  _afk_pmr_rs="${AFK_INSTALL_ROOT:-$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}/adapters/runtime-scope.sh"
  # shellcheck disable=SC1090,SC1091
  [[ -r "$_afk_pmr_rs" ]] && . "$_afk_pmr_rs"
  unset _afk_pmr_rs
fi

AFK_PMR_SCOPE_RE='^(terminal|session|worktree)-[0-9a-f]{64}$'
afk_pmr_scope_key_ok() { [[ "$1" =~ $AFK_PMR_SCOPE_RE ]]; }

# afk_pmr_claim_key_for_terminal <terminal-handle> -> "terminal-<sha256>"
# The one identity used to name a claimed-notices directory, for take, settle
# and reap alike, so a reaped owner's claimed notices are always found under
# the exact key that terminal would have claimed into.
afk_pmr_claim_key_for_terminal() {
  local digest
  [[ -n "$1" ]] || return 1
  declare -F afk_scope_sha256 >/dev/null 2>&1 || return 1
  digest="$(printf '%s\0%s' terminal "$1" | afk_scope_sha256)" || return 1
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf 'terminal-%s' "$digest"
}

afk_pmr_config_path() {
  printf '%s' "${AFK_PM_REGISTRY_CONFIG:-${HOME:-}/.config/agent-flow-kit/pm-registry.json}"
}

afk_pmr_handoff_timeout_min() {
  local path v
  path="$(afk_pmr_config_path)"
  if [[ -r "$path" ]]; then
    v="$(jq -r '.pm_handoff_timeout_min // empty' "$path" 2>/dev/null)"
    [[ "$v" =~ ^[1-9][0-9]*$ ]] && { printf '%s' "$v"; return 0; }
  fi
  printf '30'
}

# --- Orca liveness (AD-28 R5) -----------------------------------------------
# An owner is judged by afk_orca_terminal_state (lib/afk-orca.sh): the
# recorded identity tuple joined against the complete terminal list, the
# worktree ps agent rows, and the runtime id. Only `stale` is reapable;
# detached, disconnected and unknown owners are never reaped and never
# replaced. An ownership row without a tuple (afk-pm-ownership/2, written
# before tuples existed) reads as unknown until its own PM re-registers.
AFK_PMR_OWNER_SCHEMAS='["afk-pm-ownership/2","afk-pm-ownership/3"]'

afk_pmr_owner_state() { # <owner-json>: sets AFK_PMR_STATE and AFK_PMR_REASON
  # The join judges .identity.handle and reap acts on .terminal: a row where
  # they differ proves nothing about the terminal it names.
  if jq -e '.schema=="afk-pm-ownership/3" and .identity.handle==.terminal' <<<"$1" >/dev/null 2>&1; then
    afk_orca_terminal_state "$(jq -c '.identity // {}' <<<"$1")"
    AFK_PMR_STATE="$AFK_ORCA_TERMINAL_STATE"; AFK_PMR_REASON="$AFK_ORCA_TERMINAL_REASON"
  else
    AFK_PMR_STATE="unknown"; AFK_PMR_REASON="PM_IDENTITY_UNRECORDED"
  fi
  [[ "$AFK_PMR_STATE" != detached && "$AFK_PMR_STATE" != disconnected ]] || AFK_PMR_STATE="unknown"
}

# afk_pmr_caller_owns <lookup-json> <terminal>: the caller's own terminal is
# the owner. A live owner qualifies. So does the single unknown owner, but only
# when it is unknown because its tab lost its pane (a PM running this command
# is evidently running), because its row predates identity tuples, or because
# Orca can't be asked right now. A caller in a remote-runtime session never
# qualifies (AD-28 R3).
afk_pmr_caller_owns() {
  [[ -z "${ORCA_ENVIRONMENT:-}" && -z "${ORCA_PAIRING_CODE:-}" ]] || return 1
  jq -e --arg t "$2" '
    (.state=="live" and .owner.terminal==$t) or
    (.state=="unknown" and (.owners|length)==1 and .owners[0].terminal==$t and
     (.owners[0].reason|IN("PM_TERMINAL_DETACHED","PM_IDENTITY_UNRECORDED","ORCA_UNAVAILABLE","ORCA_LIST_INCOMPLETE")))' \
    <<<"$1" >/dev/null 2>&1
}

# Slugs become directory names under notices/: the AD-23 slug regex only, and
# never one of the kit's own claimed/settled/unreturned directories.
afk_pmr_slug_ok() {
  [[ "$1" =~ ^[a-z0-9-]{1,40}$ && "$1" != claimed && "$1" != settled && "$1" != unreturned ]]
}

# --- AC-1: lookup by git common-dir ------------------------------------------
# afk_pm_registry_lookup <repo_path> -> prints one JSON object on stdout.
afk_pm_registry_lookup() {
  local repo_path="$1" target_common d scope_key owner_file owner_doc owner_common
  local handoff_doc orca_state stale="[]"
  local -a candidates=() handoffs=() unknown=()
  target_common="$(git -C "$repo_path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || target_common=""
  if [[ -z "$target_common" ]]; then
    jq -nc '{state:"none",owner:null,owners:null,handoff:null,reason:null,orca:"OK",stale:[]}'
    return 0
  fi
  afk_orca_liveness_reset
  afk_orca_list_state || true
  orca_state="$AFK_ORCA_LIST_CODE"

  if [[ -d "${AFK_STATE_DIR:-}/pm/scopes" ]]; then
    for d in "$AFK_STATE_DIR/pm/scopes"/*/; do
      [[ -d "$d" ]] || continue
      scope_key="$(basename -- "$d")"
      afk_pmr_scope_key_ok "$scope_key" || continue
      owner_file="$d/ownership.json"
      [[ -f "$owner_file" ]] || continue
      owner_doc="$(jq -ce --argjson sc "$AFK_PMR_OWNER_SCHEMAS" 'select((.schema|IN($sc[])) and .owned==true and
        (.terminal|type)=="string" and (.terminal|length)>0 and
        (.worktree.path|type)=="string" and (.worktree.path|length)>0)' "$owner_file" 2>/dev/null)" || continue
      owner_common="$(git -C "$(jq -r .worktree.path <<<"$owner_doc")" \
        rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || continue
      [[ -n "$owner_common" && "$owner_common" == "$target_common" ]] || continue
      owner_doc="$(jq -c --arg sk "$scope_key" '. + {scope:$sk}' <<<"$owner_doc")"

      handoff_doc=""
      if [[ -f "$d/handoff.json" ]]; then
        handoff_doc="$(jq -ce 'select(.schema|IN("afk-pm-handoff/2","afk-pm-handoff/3"))' "$d/handoff.json" 2>/dev/null)" || handoff_doc=""
      fi
      if [[ -n "$handoff_doc" ]] && jq -e '.state=="SUCCESSOR_LAUNCHED" or .state=="ACKED"' <<<"$handoff_doc" >/dev/null 2>&1; then
        handoffs+=("$(jq -c --arg sk "$scope_key" '. + {scope:$sk}' <<<"$handoff_doc")")
        continue
      fi

      afk_pmr_owner_state "$owner_doc"
      case "$AFK_PMR_STATE" in
        stale) stale="$(jq -c --argjson o "$owner_doc" '. + [{scope:$o.scope,terminal:$o.terminal}]' <<<"$stale")" ;;
        live) candidates+=("$owner_doc") ;;
        *) unknown+=("$(jq -c --arg r "$AFK_PMR_REASON" '. + {reason:$r}' <<<"$owner_doc")") ;;
      esac
    done
  fi

  if (( ${#handoffs[@]} > 1 )); then
    local harr="[]" h
    for h in "${handoffs[@]}"; do
      harr="$(jq -c --argjson h "$h" \
        '. + [{scope:$h.scope,old:{terminal:$h.old.terminal},successor:{terminal:$h.successor.terminal}}]' <<<"$harr")"
    done
    jq -nc --argjson handoffs "$harr" --argjson stale "$stale" --arg orca "$orca_state" \
      '{state:"ambiguous",owner:null,owners:null,handoff:null,handoffs:$handoffs,
        reason:"PM_HANDOFF_AMBIGUOUS",orca:$orca,stale:$stale}'
    return 0
  fi

  if (( ${#handoffs[@]} == 1 )); then
    local h="${handoffs[0]}" upd h_epoch now_epoch state reason=null timeout_min
    upd="$(jq -r '.updated_at // .observed_at // empty' <<<"$h")"
    h_epoch="$(afk_epoch_of_utc "$upd" 2>/dev/null)" || h_epoch=""
    now_epoch="$(date -u +%s)"
    timeout_min="$(afk_pmr_handoff_timeout_min)"
    if [[ -n "$h_epoch" ]] && (( now_epoch - h_epoch > timeout_min * 60 )); then
      state="handoff_stalled"; reason='"PM_HANDOFF_STALLED"'
    else
      state="handoff_in_progress"
    fi
    jq -nc --arg st "$state" --argjson h "$h" --argjson reason "$reason" --argjson stale "$stale" --arg orca "$orca_state" \
      '{state:$st,owner:null,owners:null,handoff:$h,reason:$reason,orca:$orca,stale:$stale}'
    return 0
  fi

  local n=${#candidates[@]}
  if (( n == 0 )); then
    # Every owner that is not provably live or stale keeps the repo busy.
    if (( ${#unknown[@]} > 0 )); then
      local darr="[]" o
      for o in "${unknown[@]}"; do
        darr="$(jq -c --argjson o "$o" \
          '. + [{scope:$o.scope,terminal:$o.terminal,harness:$o.harness,session:$o.session,worktree:$o.worktree,reason:$o.reason}]' <<<"$darr")"
      done
      jq -nc --argjson owners "$darr" --argjson stale "$stale" --arg orca "$orca_state" \
        '{state:"unknown",owner:null,owners:$owners,handoff:null,reason:$owners[0].reason,orca:$orca,stale:$stale}'
      return 0
    fi
    jq -nc --argjson stale "$stale" --arg orca "$orca_state" \
      '{state:"none",owner:null,owners:null,handoff:null,reason:null,orca:$orca,stale:$stale}'
  elif (( n == 1 )); then
    jq -nc --argjson o "${candidates[0]}" --argjson stale "$stale" --arg orca "$orca_state" \
      '{state:"live",owner:{scope:$o.scope,terminal:$o.terminal,harness:$o.harness,session:$o.session,worktree:$o.worktree},
        owners:null,handoff:null,reason:null,orca:$orca,stale:$stale}'
  else
    local arr="[]" c
    for c in "${candidates[@]}"; do
      arr="$(jq -c --argjson c "$c" \
        '. + [{scope:$c.scope,terminal:$c.terminal,harness:$c.harness,session:$c.session,worktree:$c.worktree}]' <<<"$arr")"
    done
    jq -nc --argjson owners "$arr" --argjson stale "$stale" --arg orca "$orca_state" \
      '{state:"ambiguous",owner:null,owners:$owners,handoff:null,reason:null,orca:$orca,stale:$stale}'
  fi
}

afk_pmr_emit_refusal() { # <reason> <json_mode>
  if [[ "$2" == true ]]; then
    jq -nc --arg r "$1" '{result:$r}'
  else
    printf 'agent-flow-kit: %s\n' "$1"
  fi
}

# --- AC-3: pm-registry-reap ---------------------------------------------------
afk_cmd_pm_registry_reap() { # <json_mode> <scope_key>
  local json_mode="$1" scope_key="$2" dir owner_file owner_doc handoff_state terminal
  local claim_key epoch dest returned=0 f proj unreturned_dir udest
  local -a stranded=()
  afk_pmr_scope_key_ok "$scope_key" || { afk_pmr_emit_refusal "PM_SCOPE_INVALID" "$json_mode"; return 1; }
  dir="$AFK_STATE_DIR/pm/scopes/$scope_key"
  owner_file="$dir/ownership.json"
  [[ -f "$owner_file" ]] || { afk_pmr_emit_refusal "PM_SCOPE_EMPTY" "$json_mode"; return 4; }
  owner_doc="$(jq -ce --argjson sc "$AFK_PMR_OWNER_SCHEMAS" 'select((.schema|IN($sc[])) and .owned==true and
    (.terminal|type)=="string" and (.terminal|length)>0)' "$owner_file" 2>/dev/null)" \
    || { afk_pmr_emit_refusal "PM_SCOPE_EMPTY" "$json_mode"; return 4; }
  # Re-prove stale with a fresh join immediately before the reap.
  afk_orca_liveness_reset
  afk_pmr_owner_state "$owner_doc"
  case "$AFK_PMR_STATE" in
    stale) : ;;
    live) afk_pmr_emit_refusal "PM_OWNER_LIVE" "$json_mode"; return 2 ;;
    *) afk_pmr_emit_refusal "PM_OWNER_UNKNOWN" "$json_mode"; return 5 ;;
  esac
  terminal="$(jq -r .terminal <<<"$owner_doc")"

  epoch="$(date +%s)"
  afk_state_dir_ensure "$AFK_STATE_DIR/pm/reaped" || { afk_pmr_emit_refusal "PM_REGISTRY_WRITE_FAILED" "$json_mode"; return 1; }
  dest="$AFK_STATE_DIR/pm/reaped/$scope_key.$epoch.json"
  # Scopes are worktree-keyed, so a new PM or a handoff can land in this scope
  # while Orca was being asked. Re-check both right before the rename, and
  # verify what was actually moved; put it back if it is not what was judged.
  if [[ -f "$dir/handoff.json" ]]; then
    handoff_state="$(jq -r '.state // empty' "$dir/handoff.json" 2>/dev/null)"
    if [[ "$handoff_state" != "OLD_CLOSED" ]]; then
      afk_pmr_emit_refusal "PM_HANDOFF_IN_PROGRESS" "$json_mode"
      return 2
    fi
  fi
  [[ "$(jq -c . "$owner_file" 2>/dev/null)" == "$(jq -c . <<<"$owner_doc")" ]] \
    || { afk_pmr_emit_refusal "PM_OWNER_LIVE" "$json_mode"; return 2; }
  mv -n -- "$owner_file" "$dest" 2>/dev/null && [[ -f "$dest" ]] \
    || { afk_pmr_emit_refusal "PM_REGISTRY_WRITE_FAILED" "$json_mode"; return 1; }
  if [[ "$(jq -c . "$dest" 2>/dev/null)" != "$(jq -c . <<<"$owner_doc")" ]]; then
    mv -n -- "$dest" "$owner_file" 2>/dev/null
    afk_pmr_emit_refusal "PM_OWNER_LIVE" "$json_mode"
    return 2
  fi

  claim_key="$(afk_pmr_claim_key_for_terminal "$terminal" 2>/dev/null)" || claim_key=""
  unreturned_dir="$AFK_STATE_DIR/paperclip/notices/unreturned/$scope_key"
  if [[ -n "$claim_key" && -d "$AFK_STATE_DIR/paperclip/notices/claimed/$claim_key" ]]; then
    for f in "$AFK_STATE_DIR/paperclip/notices/claimed/$claim_key"/*; do
      [[ -f "$f" ]] || continue
      proj="$(jq -r '.slug // empty' "$f" 2>/dev/null)"
      if afk_pmr_slug_ok "$proj" \
         && afk_state_dir_ensure "$AFK_STATE_DIR/paperclip/notices/$proj" \
         && mv -n -- "$f" "$AFK_STATE_DIR/paperclip/notices/$proj/$(basename -- "$f")" 2>/dev/null \
         && [[ ! -e "$f" ]]; then
        returned=$((returned + 1))
        continue
      fi
      # Could not return this notice to its project (unknown/invalid project,
      # a state-dir write failure, or a same-name file already there). Never
      # leave it silently behind under the dead terminal's claim key: move it
      # to a deterministic, scope-keyed recovery location instead, unless a
      # duplicate already occupies that spot — then the source is left in
      # place (never overwritten) and just named in the report.
      udest="$unreturned_dir/$(basename -- "$f")"
      if [[ -e "$udest" ]]; then
        stranded+=("$(jq -nc --arg src "$f" --arg dest "$udest" \
          '{source:$src,recovered_to:null,reason:"duplicate destination"}')")
      elif afk_state_dir_ensure "$unreturned_dir" \
           && mv -n -- "$f" "$udest" 2>/dev/null && [[ ! -e "$f" ]]; then
        stranded+=("$(jq -nc --arg src "$f" --arg dest "$udest" \
          '{source:$src,recovered_to:$dest,reason:"project unreturnable"}')")
      else
        stranded+=("$(jq -nc --arg src "$f" \
          '{source:$src,recovered_to:null,reason:"recovery move failed"}')")
      fi
    done
  fi

  local stranded_json="[]" s
  for s in "${stranded[@]}"; do
    stranded_json="$(jq -c --argjson s "$s" '. + [$s]' <<<"$stranded_json")"
  done
  local stranded_n=${#stranded[@]}

  if [[ "$json_mode" == true ]]; then
    jq -nc --arg r "reaped" --arg s "$scope_key" --arg t "$terminal" --argjson n "$returned" \
      --argjson sn "$stranded_n" --argjson stranded "$stranded_json" \
      '{result:$r,scope:$s,terminal:$t,notices_returned:$n,notices_stranded:$sn,stranded:$stranded}'
  else
    printf 'pm-registry-reap: scope %s (terminal %s) reaped, %d notice(s) returned, %d stranded\n' \
      "$scope_key" "$terminal" "$returned" "$stranded_n"
    for s in "${stranded[@]}"; do
      printf '  stranded: %s\n' "$(jq -r '"\(.source) -> \(.recovered_to // "left in place")  (\(.reason))"' <<<"$s")"
    done
  fi
  (( stranded_n == 0 )) && return 0
  return 3
}

# --- AC-4: paperclip-take -----------------------------------------------------
afk_cmd_paperclip_take() { # <json_mode> <slug>
  local json_mode="$1" slug="$2" repo_path terminal lookup state claim_terminal claim_key
  local notices_dir claimed_dir out="[]" f base moved doc id event brief_path reply_path
  afk_pmr_slug_ok "$slug" || { afk_pmr_emit_refusal "PAPERCLIP_PROJECT_UNKNOWN" "$json_mode"; return 1; }
  if ! afk_pc_load_config; then
    afk_pmr_emit_refusal "$AFK_PC_REFUSAL" "$json_mode"
    return 4
  fi
  repo_path="$(jq -r '.repo_path // empty' <<<"$(afk_pc_project_row "$slug")")"
  [[ -n "$repo_path" ]] || { afk_pmr_emit_refusal "PAPERCLIP_PROJECT_UNKNOWN" "$json_mode"; return 4; }
  terminal="${ORCA_TERMINAL_HANDLE:-}"
  [[ -n "$terminal" ]] || { afk_pmr_emit_refusal "PAPERCLIP_NOT_OWNER" "$json_mode"; return 2; }

  lookup="$(afk_pm_registry_lookup "$repo_path")"
  state="$(jq -r .state <<<"$lookup")"
  claim_terminal=""
  case "$state" in
    live | unknown)
      afk_pmr_caller_owns "$lookup" "$terminal" && claim_terminal="$terminal" ;;
    handoff_in_progress | handoff_stalled)
      local succ; succ="$(jq -r '.handoff.successor.terminal // empty' <<<"$lookup")"
      if [[ -n "$succ" && "$terminal" == "$succ" ]]; then
        claim_terminal="$terminal"
      else
        afk_pmr_emit_refusal "PAPERCLIP_HANDOFF_IN_PROGRESS" "$json_mode"
        return 2
      fi ;;
  esac
  [[ -n "$claim_terminal" ]] || { afk_pmr_emit_refusal "PAPERCLIP_NOT_OWNER" "$json_mode"; return 2; }
  claim_key="$(afk_pmr_claim_key_for_terminal "$claim_terminal" 2>/dev/null)" \
    || { afk_pmr_emit_refusal "PAPERCLIP_NOT_OWNER" "$json_mode"; return 2; }

  notices_dir="$AFK_STATE_DIR/paperclip/notices/$slug"
  claimed_dir="$AFK_STATE_DIR/paperclip/notices/claimed/$claim_key"
  afk_state_dir_ensure "$claimed_dir" || { afk_pmr_emit_refusal "PAPERCLIP_REGISTRY_WRITE_FAILED" "$json_mode"; return 1; }

  if [[ -d "$notices_dir" ]]; then
    for f in "$notices_dir"/*.json; do
      [[ -f "$f" ]] || continue
      base="$(basename -- "$f")"
      moved="$claimed_dir/$base"
      mv -n -- "$f" "$moved" 2>/dev/null && [[ ! -e "$f" ]] || continue
      doc="$(jq -c . "$moved" 2>/dev/null)" || continue
      id="$(jq -r '.id // empty' <<<"$doc")"
      event="$(jq -r '.event // empty' <<<"$doc")"
      brief_path=null; reply_path=null
      if afk_pc_uuid_ok "$id"; then
        if [[ "$event" == claimed ]]; then
          local b; for b in "$notices_dir"/brief."$id".*.md; do
            [[ -f "$b" ]] && brief_path="$(jq -nc --arg p "$b" '$p')" && break
          done
        elif [[ "$event" == human_commented ]]; then
          local cid r; cid="$(jq -r '.comment_id // empty' <<<"$doc")"
          if afk_pc_uuid_ok "$cid"; then
            r="$notices_dir/reply.$cid.md"
            [[ -f "$r" ]] && reply_path="$(jq -nc --arg p "$r" '$p')"
          fi
        fi
      fi
      out="$(jq -c --arg id "$id" --arg ev "$event" --arg notice "$moved" \
        --argjson brief "$brief_path" --argjson reply "$reply_path" \
        '. + [{id:$id,event:$ev,notice:$notice,brief:$brief,reply:$reply}]' <<<"$out")"
    done
  fi

  if [[ "$json_mode" == true ]]; then
    printf '%s\n' "$out"
  else
    jq -r '.[] | "\(.event): \(.id)  notice=\(.notice)  brief=\(.brief // "-")  reply=\(.reply // "-")"' <<<"$out"
  fi
  return 0
}

# --- AC-5: paperclip-settle ---------------------------------------------------
afk_cmd_paperclip_settle() { # <json_mode> <notice_id>
  local json_mode="$1" notice_id="$2" claim_key settled_dir moved=0 f any=false
  afk_pc_uuid_ok "$notice_id" || { afk_pmr_emit_refusal "PAPERCLIP_NOTICE_UNKNOWN" "$json_mode"; return 4; }
  claim_key="$(afk_pmr_claim_key_for_terminal "${ORCA_TERMINAL_HANDLE:-}" 2>/dev/null)" || claim_key=""
  settled_dir="$AFK_STATE_DIR/paperclip/notices/settled"

  if [[ -n "$claim_key" && -d "$AFK_STATE_DIR/paperclip/notices/claimed/$claim_key" ]]; then
    for f in "$AFK_STATE_DIR/paperclip/notices/claimed/$claim_key"/*."$notice_id".*.json; do
      [[ -f "$f" ]] || continue
      afk_state_dir_ensure "$settled_dir" || continue
      mv -n -- "$f" "$settled_dir/$(basename -- "$f")" 2>/dev/null && [[ ! -e "$f" ]] && moved=$((moved + 1))
    done
  fi

  if (( moved == 0 )); then
    for f in "$settled_dir"/*."$notice_id".*.json; do
      [[ -f "$f" ]] && any=true
    done
    if [[ "$any" != true ]]; then
      afk_pmr_emit_refusal "PAPERCLIP_NOTICE_UNKNOWN" "$json_mode"
      return 4
    fi
  fi

  if [[ "$json_mode" == true ]]; then
    jq -nc --arg id "$notice_id" --argjson n "$moved" '{result:"settled",id:$id,moved:$n}'
  else
    printf 'paperclip-settle: %s (%d moved)\n' "$notice_id" "$moved"
  fi
  return 0
}
