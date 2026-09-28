#!/usr/bin/env bash
# afk-accept.sh — `route-accept`: the acceptance record for a stamped route,
# and the Paperclip dispatch preconditions `--verify` answers for dispatch.sh
# (AFK-PC-4, AD-9/AD-16, F1/F17/F23). See docs/PAPERCLIP.md. Needs
# lib/afk-paperclip.sh and lib/afk-paperclip-plan.sh. SOURCED, never executed.

if [[ -n "${AFK_ACCEPT_SOURCED:-}" ]]; then
  return 0
fi
AFK_ACCEPT_SOURCED=1

AFK_ACCEPT_HARD_EXCLUSIONS='["security","iam","secrets","prod-iac","destructive-tools"]'

# afk_accept_decision_digest <stamp> -- AC-2, the ONE definition: sha256 of
# the compact, key-sorted projection jq prints (its trailing LF included).
# dispatch.sh never recomputes it; it asks `route-accept --verify`.
afk_accept_decision_digest() {
  local j d
  j="$(jq -cS '{harness, model_profile, effort, cost_class, metered, catalog_version, task:{story_id: .task.story_id}}' "$1" 2>/dev/null)" || return 1
  d="$(printf '%s\n' "$j" | afk_sha256_stdin)" || return 1
  [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]] && printf '%s' "$d"
}

afk_accept_emit() { # <json_mode> <result> [<extra-json>]
  local x="${3:-}"; [[ -n "$x" ]] || x='{}'
  if [[ "$1" == true ]]; then
    jq -nc --arg r "$2" --argjson x "$x" '{result:$r} + $x'
  elif [[ "$2" == ok ]]; then
    jq -r '"accepted \(.kind // "verified") \(.story_id) \(.decision_digest)"' <<<"$x"
  else
    printf 'agent-flow-kit route-accept: %s\n' "$2"
  fi
}

# afk_accept_load <story> -- reads the story frontmatter and its stamp. Sets
# AFK_ACC_{PAPERCLIP,ISSUE,GATES,STAMP_JSON,SID,DIGEST}, or AFK_ACC_REASON.
# Any Paperclip marker (home, issue, or a HOM- story id) makes the story a
# Paperclip story, and then all three must be present and agree (AC-1).
afk_accept_load() {
  local story="$1" fm home stamp
  AFK_ACC_REASON="" AFK_ACC_PAPERCLIP=false
  fm="$(yq --front-matter=extract -o=json -I=0 '.' "$story" 2>/dev/null)"
  if [[ ! -f "$story" ]] || ! jq -e 'type == "object"' <<<"$fm" >/dev/null 2>&1; then
    AFK_ACC_REASON=STORY_UNREADABLE; return 1
  fi
  home="$(jq -r '.home // "" | strings' <<<"$fm")"
  AFK_ACC_ISSUE="$(jq -r '.paperclip_issue // "" | strings' <<<"$fm")"
  AFK_ACC_GATES="$(jq -c '.gates // []' <<<"$fm")"
  stamp="$(jq -r '.stamp // "" | strings' <<<"$fm")"; stamp="${stamp:-$story.stamp.json}"
  [[ -f "$stamp" ]] || { AFK_ACC_REASON=STAMP_MISSING; return 1; }
  # Exactly one JSON object whose task.tags (when present) is an array of
  # strings: the hard-exclusion check below matches tags one by one, and a
  # tags value of any other shape would slip past it as "no tag matched".
  AFK_ACC_STAMP_JSON="$(jq -c 'select(type == "object")' "$stamp" 2>/dev/null)"
  AFK_ACC_DIGEST="$(afk_accept_decision_digest "$stamp")"
  [[ -n "$AFK_ACC_STAMP_JSON" && -n "$AFK_ACC_DIGEST" && "$AFK_ACC_STAMP_JSON" != *$'\n'* ]] &&
    jq -e '(.task.tags // []) | type == "array" and all(type == "string")' <<<"$AFK_ACC_STAMP_JSON" >/dev/null 2>&1 ||
    { AFK_ACC_REASON=STAMP_INVALID; return 1; }
  AFK_ACC_SID="$(jq -r '.task.story_id // "" | strings' <<<"$AFK_ACC_STAMP_JSON")"
  if [[ "$home" == paperclip:* || -n "$AFK_ACC_ISSUE" || "$AFK_ACC_SID" == HOM-* ]]; then
    AFK_ACC_PAPERCLIP=true
    if ! [[ "$home" =~ ^paperclip:(HOM-[0-9]+)$ && "$AFK_ACC_SID" =~ ^HOM-[0-9]+\.S[0-9]+$ &&
            "${AFK_ACC_SID%%.S*}" == "${home#paperclip:}" ]] || ! afk_pc_uuid_ok "$AFK_ACC_ISSUE"; then
      AFK_ACC_REASON=STORY_HOME_INVALID; return 1
    fi
  fi
  return 0
}

# afk_accept_plan_check -- prints ok, PLAN_NOT_APPROVED, STORY_NOT_IN_PLAN or
# STORY_CONTRACT_MUTATED. The plan story is read only from the record whose
# digest the approval just confirmed, so a re-plan between the two reads
# cannot slip a different plan's gates in.
afk_accept_plan_check() {
  local appr d story
  appr="$(afk_cmd_paperclip_approval true "$AFK_ACC_ISSUE" 2>/dev/null)" || { printf PLAN_NOT_APPROVED; return 0; }
  d="$(jq -r 'select(.approved == true) | .digest // empty' <<<"$appr" 2>/dev/null)"
  [[ "$d" =~ ^[0-9a-f]{64}$ ]] || { printf PLAN_NOT_APPROVED; return 0; }
  story="$(jq -c --arg d "$d" --arg s "$AFK_ACC_SID" 'select(.digest == $d) | [.stories[]? | select(.id == $s)] | first // empty' \
    "$AFK_STATE_DIR/paperclip/plans/$AFK_ACC_ISSUE.json" 2>/dev/null)"
  [[ -n "$story" ]] || { printf STORY_NOT_IN_PLAN; return 0; }
  jq -e --argjson g "$AFK_ACC_GATES" '.gates == $g' <<<"$story" >/dev/null 2>&1 || { printf STORY_CONTRACT_MUTATED; return 0; }
  printf ok
}

# afk_accept_lane_reason -- the free-lane conditions on the CURRENT stamp:
# natural, free, no hard-exclusion tag (compared trimmed and case-folded, so
# "Security" or " iam " is still the exclusion). Prints ok or the reason.
afk_accept_lane_reason() {
  jq -e '.override == null' <<<"$AFK_ACC_STAMP_JSON" >/dev/null || { printf PM_AUTO_NOT_NATURAL; return 0; }
  jq -e '.cost_class == "free" and .metered == false' <<<"$AFK_ACC_STAMP_JSON" >/dev/null || { printf PM_AUTO_NOT_FREE; return 0; }
  afk_accept_hard_excluded && { printf HARD_EXCLUSION; return 0; }
  printf ok
}

# afk_accept_hard_excluded -- true when the current stamp carries a
# hard-exclusion tag.
afk_accept_hard_excluded() {
  ! jq -e --argjson x "$AFK_ACCEPT_HARD_EXCLUSIONS" \
    '[.task.tags[]? | ascii_downcase | gsub("^\\s+|\\s+$"; "") | select(. as $t | $x | index($t))] | length == 0' \
    <<<"$AFK_ACC_STAMP_JSON" >/dev/null
}

# afk_accept_kind_reason <kind> -- a Paperclip story accepts only pm-auto.
# Nothing ties a human or override record's free-text actor to Josh, and the
# record sits in the worker's worktree, so until native route approvals exist
# such a record is refused: HARD_EXCLUSION when the stamp is hard-excluded
# (never a question for Josh), ACCEPTANCE_KIND_NOT_ALLOWED otherwise.
afk_accept_kind_reason() {
  [[ "$1" == pm-auto ]] && { printf ok; return 0; }
  afk_accept_hard_excluded && { printf HARD_EXCLUSION; return 0; }
  printf ACCEPTANCE_KIND_NOT_ALLOWED
}

# afk_accept_verify <story> -- AC-4, what dispatch.sh asks on every cycle.
# The record must be a well-formed acceptance for THIS stamp's digest and
# story id, and of kind pm-auto (a human or override record is refused, see
# afk_accept_kind_reason). The pm-auto record is re-judged against the current
# stamp's lane: the AC-2 digest does not cover override or task.tags, so a
# stamp that stopped being natural, free or non-excluded must not ride on an
# acceptance the PM wrote when it still was.
afk_accept_verify() {
  local acc="$1.acceptance.json" kind r
  [[ "$AFK_ACC_PAPERCLIP" == true ]] || { printf STORY_HOME_INVALID; return 0; }
  [[ -f "$acc" ]] || { printf ACCEPTANCE_MISSING; return 0; }
  kind="$(jq -r 'select(type == "object") | select(.schema == "afk-acceptance/1" and (.actor | type) == "string" and .actor != "")
                 | .kind | strings | select(. == "human" or . == "override" or . == "pm-auto")' "$acc" 2>/dev/null)"
  [[ "$kind" =~ ^(human|override|pm-auto)$ ]] || { printf ACCEPTANCE_INVALID; return 0; }
  jq -e --arg d "$AFK_ACC_DIGEST" --arg s "$AFK_ACC_SID" '.decision_digest == $d and .story_id == $s' "$acc" >/dev/null 2>&1 ||
    { printf ACCEPTANCE_DIGEST_MISMATCH; return 0; }
  r="$(afk_accept_kind_reason "$kind")"; [[ "$r" == ok ]] || { printf '%s' "$r"; return 0; }
  r="$(afk_accept_lane_reason)"; [[ "$r" == ok ]] || { printf '%s' "$r"; return 0; }
  afk_accept_plan_check
}

# afk_accept_pm_auto_reason -- AC-3, every condition, in the contract's order.
afk_accept_pm_auto_reason() {
  local r
  [[ "$AFK_ACC_PAPERCLIP" == true ]] || { printf PM_AUTO_NOT_PAPERCLIP; return 0; }
  r="$(afk_accept_lane_reason)"; [[ "$r" == ok ]] || { printf '%s' "$r"; return 0; }
  afk_accept_plan_check
}

# afk_cmd_route_accept <json_mode> <story> <kind> <actor> <reason> <verify>
afk_cmd_route_accept() {
  local json_mode="$1" story="$2" kind="$3" actor="$4" reason="$5" verify="$6" r policy="" rec tmp
  afk_accept_load "$story" || { afk_accept_emit "$json_mode" "$AFK_ACC_REASON"; return 4; }
  local x; x="$(jq -nc --arg s "$AFK_ACC_SID" --arg d "$AFK_ACC_DIGEST" '{story_id:$s, decision_digest:$d}')"
  if [[ "$verify" == true ]]; then
    r="$(afk_accept_verify "$story")"
    afk_accept_emit "$json_mode" "$r" "$x"
    [[ "$r" == ok ]] && return 0
    return 4
  fi
  if [[ "$AFK_ACC_PAPERCLIP" == true && "$kind" != pm-auto ]]; then
    r="$(afk_accept_kind_reason "$kind")"
    afk_accept_emit "$json_mode" "$r" "$x"; return 4
  fi
  if [[ "$kind" == pm-auto ]]; then
    r="$(afk_accept_pm_auto_reason)"
    [[ "$r" == ok ]] || { afk_accept_emit "$json_mode" "$r" "$x"; return 4; }
    policy=paperclip-free-lane
  fi
  rec="$(jq -nc --argjson x "$x" --arg k "$kind" --arg a "$actor" --arg p "$policy" --arg r "$reason" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema:"afk-acceptance/1", story_id:$x.story_id, decision_digest:$x.decision_digest, kind:$k, actor:$a,
      policy:(if $p == "" then null else $p end), reason:(if $r == "" then null else $r end), created_at:$at}')"
  tmp="$story.acceptance.json.tmp.$$"
  if ! printf '%s\n' "$rec" >"$tmp" 2>/dev/null || ! mv -f -- "$tmp" "$story.acceptance.json" 2>/dev/null; then
    rm -f -- "$tmp"; afk_accept_emit "$json_mode" ACCEPTANCE_WRITE_FAILED; return 1
  fi
  afk_accept_emit "$json_mode" ok "$(jq -c '{story_id, decision_digest, kind, policy}' <<<"$rec")"
}
