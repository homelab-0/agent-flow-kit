#!/usr/bin/env bash
# afk-paperclip-plan.sh — `paperclip-plan` and `paperclip-approval`, and the
# poller's interim `approve <digest8>` hook (AFK-PC-3b, AD-4/AD-9/AD-16). See
# docs/PAPERCLIP.md. Reuses lib/afk-paperclip.sh and lib/afk-paperclip-
# report.sh, which must already be sourced. SOURCED, never executed.

if [[ -n "${AFK_PAPERCLIP_PLAN_SOURCED:-}" ]]; then
  return 0
fi
AFK_PAPERCLIP_PLAN_SOURCED=1

afk_pcp_emit() { # <json_mode> <result> [<extra-json>] -- a refusal
  local x="${3:-}"; [[ -n "$x" ]] || x='{}'
  if [[ "$1" == true ]]; then
    jq -nc --arg r "$2" --argjson x "$x" '{result:$r} + $x'
  else
    jq -r --arg r "$2" '([$r] + [.[] | tostring]) | join(": ") | "agent-flow-kit paperclip-plan: " + .' <<<"$x"
  fi
}

afk_pcp_sha256() { local d; d="$(afk_sha256_stdin)" || return 1; printf '%s' "${d#sha256:}"; }

# afk_pcp_render <plan-json> -- the canonical body (AC-3). Every line ends in
# LF; the digest is sha256 of exactly these bytes. The footer is not here.
afk_pcp_render() {
  jq -r '
    "# AFK plan", "",
    "- Repo: `\(.repo | split("/") | last)` (`\(.repo)`)",
    "- Base: `\(.base)`",
    (.stories[] | "", "## \(.id): \(.title)", "",
      "- Size: \(.size)", "- Lane: \(.lane)", "- Files:",
      (if (.files | length) == 0 then "  - (none)" else (.files[] | "  - `\(.)`") end),
      "- Gates:", "", "```", .gates[], "```")' <<<"$1"
}

# afk_pcp_validate <plan-json> <repo_path> <identifier> -- prints "ok" or a
# reason. Control characters are refused in every field, so no value can add
# lines (a fake footer, a fence break) to the body Josh reads.
afk_pcp_validate() {
  jq -r --arg repo "$2" --arg ident "$3" '
    def s: type == "string" and length > 0 and (test("[[:cntrl:]]") | not);
    if type != "object" or .schema != "afk-paperclip-plan/1" then "PLAN_INVALID"
    elif .repo != $repo then "PLAN_REPO_MISMATCH"
    elif ((.base | s) and (.base | test("^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$"))) | not then "PLAN_BASE_UNKNOWN"
    elif (.stories | type) != "array" or (.stories | length) == 0 then "PLAN_INVALID"
    elif ([.stories[] | type == "object"
            and (.id | s) and (.id | test("^HOM-[0-9]+\\.S[0-9]+$")) and ((.id | split(".S")[0]) == $ident)
            and (.title | s) and (.size | s) and (.lane | s)
            and (.files | type) == "array" and all(.files[]; s)
            and (.gates | type) == "array" and all(.gates[]; s)] | all) | not then "PLAN_INVALID"
    elif ([.stories[].id] | length) != ([.stories[].id] | unique | length) then "PLAN_INVALID"
    else "ok" end' <<<"$1" 2>/dev/null || printf 'PLAN_INVALID'
}

# afk_pcp_check_gates <json_mode> <plan-json> <repo> <base-commit> -- AC-2.
# The allowlist is read from the base commit's tree only (`git show`), never
# from a worktree, so a branch edit cannot widen what a plan may run.
afk_pcp_check_gates() {
  local json_mode="$1" plan="$2" repo="$3" base="$4" allow line sid gate
  local -A allowed=()
  if [[ "$(git -C "$repo" cat-file -t "$base:.afk/gates-allowlist" 2>/dev/null)" != blob ]] ||
     ! allow="$(git -C "$repo" show "$base:.afk/gates-allowlist" 2>/dev/null)"; then
    afk_pcp_emit "$json_mode" GATE_ALLOWLIST_MISSING; return 1
  fi
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    allowed["$line"]=1
  done <<<"$allow"
  while IFS= read -r line; do
    sid="${line%%$'\x01'*}"; gate="${line#*$'\x01'}"
    if [[ -z "$gate" || -z "${allowed[$gate]+x}" ]]; then
      afk_pcp_emit "$json_mode" GATE_NOT_ALLOWLISTED "$(jq -nc --arg s "$sid" --arg g "$gate" '{story:$s, gate:$g}')"
      return 1
    fi
  done < <(jq -r '.stories[] | .id as $i | (if (.gates | length) == 0 then "" else .gates[] end) | "\($i)\u0001\(.)"' <<<"$plan")
  return 0
}

# afk_cmd_paperclip_plan <json_mode> <issue> <plan_file> -- AC-1..AC-4.
afk_cmd_paperclip_plan() {
  local json_mode="$1" id="$2" plan_file="$3" plan reason identifier base_commit
  AFK_PCR_REFUSAL=""
  afk_pc_uuid_ok "$id" || { afk_pcp_emit "$json_mode" PAPERCLIP_ISSUE_UNKNOWN; return 4; }
  afk_pcr_owner_repo "$id" || { afk_pcp_emit "$json_mode" "$AFK_PCR_REFUSAL"; return 4; }
  local repo="$AFK_PCR_REPO_PATH"
  afk_pcr_require_owner "$repo" || { afk_pcp_emit "$json_mode" "$AFK_PCR_REFUSAL"; return 2; }
  afk_pcr_body_read "$plan_file" || { afk_pcp_emit "$json_mode" "$AFK_PCR_REFUSAL"; return 4; }
  local raw="$AFK_PCR_BODY"
  plan="$(jq -c '.' <<<"$raw" 2>/dev/null)" || plan=""
  [[ -n "$plan" ]] || { afk_pcp_emit "$json_mode" PLAN_INVALID; return 4; }
  identifier="$(jq -r --arg id "$id" '.issues[$id].identifier // empty' "$AFK_STATE_DIR/paperclip/ledger.json" 2>/dev/null)"
  reason="$(afk_pcp_validate "$plan" "$repo" "$identifier")"
  [[ "$reason" == ok ]] || { afk_pcp_emit "$json_mode" "$reason"; return 4; }
  local base; base="$(jq -r '.base' <<<"$plan")"
  base_commit="$(git -C "$repo" rev-parse --verify --quiet "$base^{commit}" 2>/dev/null)"
  [[ "$base_commit" =~ ^[0-9a-f]{40,64}$ ]] || { afk_pcp_emit "$json_mode" PLAN_BASE_UNKNOWN; return 4; }
  afk_pcp_check_gates "$json_mode" "$plan" "$repo" "$base_commit" || return 4

  # Only the fields the body shows are kept: nothing unrendered rides along.
  plan="$(jq -c '{schema, repo, base, stories: [.stories[] | {id, title, size, lane, files, gates}]}' <<<"$plan")"
  local body digest digest8 qid body_sha
  body="$(afk_pcp_render "$plan")"$'\n'
  digest="$(printf '%s' "$body" | afk_pcp_sha256)"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { afk_pcp_emit "$json_mode" PAPERCLIP_REGISTRY_WRITE_FAILED; return 1; }
  digest8="${digest:0:8}"; qid="plan-$digest8"
  body_sha="$(printf '%s' "$raw" | afk_pcp_sha256)"

  local plans="$AFK_STATE_DIR/paperclip/plans" approvals="$AFK_STATE_DIR/paperclip/approvals"
  afk_state_dir_ensure "$plans/.tmp" || { afk_pcp_emit "$json_mode" PAPERCLIP_REGISTRY_WRITE_FAILED; return 1; }
  local lock="$plans/.$id.lock"
  afk_pcr_lock "$lock" || { afk_pcp_emit "$json_mode" PAPERCLIP_LOCK_TIMEOUT; return 1; }
  # F1: revoke first. Both the old approval and the old plan go before the
  # new question is published, so no failure below can leave an approval
  # standing for anything but the plan Josh is now being shown.
  if ! rm -f -- "$approvals/$id.json" "$plans/$id.json" 2>/dev/null ||
     [[ -e "$approvals/$id.json" || -e "$plans/$id.json" ]]; then
    afk_pcr_unlock "$lock"; afk_pcp_emit "$json_mode" PAPERCLIP_REGISTRY_WRITE_FAILED; return 1
  fi
  local cfile="$plans/.tmp/$id.comment" ofile="$plans/.tmp/$id.out" rc=0 seq
  afk_state_file_write "$cfile" \
    "${body}"$'\n'"plan $digest8"$'\n'"Reply exactly \`approve $digest8\` to approve, or \`reject $digest8\`." || rc=1
  # PC-3a's writer, called directly (never in a subshell) so its lock trap
  # and ordering are the ones every other spool entry uses.
  (( rc == 0 )) && { afk_pcr_report_entry true "$id" "$cfile" "$qid" "" >"$ofile" || rc=$?; }
  AFK_PCR_HELD_LOCK="$lock" # the writer's own unlock cleared it
  seq="$(jq -r '.seq // empty' "$ofile" 2>/dev/null)"
  if (( rc != 0 )) || ! [[ "$seq" =~ ^[0-9]+$ ]]; then
    reason="$(jq -r '.result // empty' "$ofile" 2>/dev/null)"
    rm -f -- "$cfile" "$ofile"; afk_pcr_unlock "$lock"
    afk_pcp_emit "$json_mode" "${reason:-PAPERCLIP_REGISTRY_WRITE_FAILED}"; return "${rc/#0/1}"
  fi
  rm -f -- "$cfile" "$ofile"
  local rec
  rec="$(jq -nc --argjson p "$plan" --arg d "$digest" --arg q "$qid" --arg bs "$body_sha" \
    --arg bc "$base_commit" --argjson seq "$seq" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema:"afk-paperclip-plan-record/1", digest:$d, digest8:$d[0:8], question_id:$q, body_sha256:$bs,
      repo:$p.repo, base:$p.base, base_commit:$bc, stories:$p.stories, posted_seq:$seq, created_at:$at}')"
  afk_state_file_write "$plans/$id.json" "$rec" || rc=1
  afk_pcr_unlock "$lock"
  (( rc == 0 )) || { afk_pcp_emit "$json_mode" PAPERCLIP_REGISTRY_WRITE_FAILED; return 1; }
  if [[ "$json_mode" == true ]]; then
    jq -nc --arg id "$id" --arg d "$digest" --arg q "$qid" --argjson seq "$seq" \
      '{result:"ok", issue:$id, digest:$d, digest8:$d[0:8], question_id:$q, seq:$seq}'
  else
    printf 'plan %s (seq %s)\n' "$digest8" "$seq"
  fi
}

# afk_pcp_attested <approval-commit-or-empty> -- AC-6 config half: the
# interim path's attestation is configured, and (when given) names the same
# Paperclip build an approval was made under. Sets AFK_PCP_COMMIT.
afk_pcp_attested() {
  local on
  AFK_PCP_COMMIT=""
  on="$(jq -r '.interim_comment_approval.attested_on // empty | strings' <<<"$AFK_PC_CFG" 2>/dev/null)"
  AFK_PCP_COMMIT="$(jq -r '.interim_comment_approval.paperclip_commit // empty | strings' <<<"$AFK_PC_CFG" 2>/dev/null)"
  [[ -n "$on" && "$AFK_PCP_COMMIT" =~ ^[0-9a-f]{7,64}$ ]] || return 1
  [[ -z "${1:-}" || "$1" == "$AFK_PCP_COMMIT" ]]
}

# afk_pcp_on_josh_comment <comment-json> <comment-id> <created-at> -- AC-5/6.
# The poller's hook for a comment that already passed the Josh test. Returns
# 1 when the comment is not a plan decision (the caller writes the plain
# human_commented notice), 0 when it was handled here. Reads the poller's
# api_url/id/identifier/project/agent_id/repo_path/harness/prev_state/qid/
# ledger locals and appends to `actions`, like afk_pc_strand.
afk_pcp_on_josh_comment() {
  local LC_ALL=C body verb d8 plans="$AFK_STATE_DIR/paperclip/plans"
  [[ "$prev_state" == waiting_human && "$qid" == plan-* ]] || return 1
  body="$(jq -r '.body | strings' <<<"$1" 2>/dev/null)"
  body="${body#"${body%%[![:space:]]*}"}"; body="${body%"${body##*[![:space:]]}"}"
  [[ "$body" =~ ^(approve|reject)\ ([0-9a-f]{8})$ ]] || return 1
  verb="${BASH_REMATCH[1]}"; d8="${BASH_REMATCH[2]}"
  [[ "$qid" == "plan-$d8" ]] || return 1
  local x reason="" plan="" digest lock="$plans/.$id.lock" rec
  x="$(jq -nc --arg c "$2" --arg ca "$3" --arg q "$qid" '{comment_id:$c, created_at:$ca, question_id:$q}')"
  [[ -r "$plans/$id.json" ]] && plan="$(jq -c '.' "$plans/$id.json" 2>/dev/null)"
  digest="$(jq -r '.digest // empty' <<<"${plan:-null}")"
  if [[ "$verb" == reject ]]; then
    # A reject also withdraws an earlier approval of this same plan.
    if [[ -n "$digest" && -e "$AFK_STATE_DIR/paperclip/approvals/$id.json" ]] && afk_pc_spool_lock "$lock"; then
      [[ "$(jq -r '.digest // empty' "$AFK_STATE_DIR/paperclip/approvals/$id.json" 2>/dev/null)" == "$digest" ]] &&
        rm -f -- "$AFK_STATE_DIR/paperclip/approvals/$id.json"
      afk_pc_spool_unlock "$lock"
    fi
    afk_pc_notice "$project" "$id" "$identifier" "$agent_id" "$repo_path" "$harness" approval_rejected "$x"
    actions="$(jq -c --arg t "approval_rejected: $identifier" '. + [$t]' <<<"$actions")"
    return 0
  fi
  local sent_seq sent_at
  sent_seq="$(jq -r --arg id "$id" '.issues[$id].question_seq // empty' <<<"$ledger")"
  sent_at="$(jq -r --arg id "$id" '.issues[$id].question_sent_at // empty' <<<"$ledger")"
  if [[ -z "$plan" || ! "$digest" =~ ^[0-9a-f]{64}$ || "${digest:0:8}" != "$d8" ||
        "$(jq -r '.question_id' <<<"$plan")" != "$qid" || -z "$sent_seq" || "$(jq -r '.posted_seq' <<<"$plan")" != "$sent_seq" ]]; then
    reason=APPROVAL_PLAN_MISMATCH
  elif [[ -z "$sent_at" || -z "$3" || ! "$3" > "$sent_at" ]]; then
    reason=APPROVAL_BEFORE_PLAN
  elif ! afk_pcp_attested ""; then
    reason=APPROVAL_INTERIM_UNATTESTED
  else
    local hr; hr="$(afk_pc_curl GET "$api_url/api/health" "" "")"
    [[ "${hr%%$'\n'*}" == 200 && "$(jq -r '.commit // empty | strings' <<<"${hr#*$'\n'}" 2>/dev/null)" == "$AFK_PCP_COMMIT" ]] ||
      reason=APPROVAL_INTERIM_UNATTESTED
  fi
  if [[ -z "$reason" ]]; then
    reason=APPROVAL_WRITE_FAILED
    if afk_pc_spool_lock "$lock"; then
      # Re-checked under the plan lock: a re-plan that landed meanwhile wins.
      if [[ "$(jq -r '.digest // empty' "$plans/$id.json" 2>/dev/null)" == "$digest" ]]; then
        rec="$(jq -nc --arg d "$digest" --arg c "$2" --arg ca "$3" --arg pc "$AFK_PCP_COMMIT" \
          --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          '{schema:"afk-paperclip-approval/1", kind:"plan", digest:$d, digest8:$d[0:8], comment_id:$c,
            comment_created_at:$ca, decided_at:$at, paperclip_commit:$pc}')"
        afk_state_file_write "$AFK_STATE_DIR/paperclip/approvals/$id.json" "$rec" && reason=""
      else
        reason=APPROVAL_PLAN_MISMATCH
      fi
      afk_pc_spool_unlock "$lock"
    fi
  fi
  if [[ -n "$reason" ]]; then
    afk_pc_notice "$project" "$id" "$identifier" "$agent_id" "$repo_path" "$harness" approval_refused \
      "$(jq -c --arg r "$reason" '. + {reason:$r}' <<<"$x")"
    actions="$(jq -c --arg t "$reason: $identifier" '. + [$t]' <<<"$actions")"
    return 0
  fi
  afk_pc_notice "$project" "$id" "$identifier" "$agent_id" "$repo_path" "$harness" approval_granted \
    "$(jq -c --arg d "$digest" '. + {digest:$d, digest8:$d[0:8]}' <<<"$x")"
  actions="$(jq -c --arg t "approval_granted: $identifier" '. + [$t]' <<<"$actions")"
  return 0
}

# afk_cmd_paperclip_approval <json_mode> <issue> -- AC-7, read-only.
afk_cmd_paperclip_approval() {
  local json_mode="$1" id="$2" plan_d="" appr="" reason=APPROVED approved=false
  afk_pc_uuid_ok "$id" || { afk_pcp_emit "$json_mode" PAPERCLIP_ISSUE_UNKNOWN; return 4; }
  plan_d="$(jq -r '.digest // empty' "$AFK_STATE_DIR/paperclip/plans/$id.json" 2>/dev/null)"
  appr="$(jq -c 'select(.kind == "plan")' "$AFK_STATE_DIR/paperclip/approvals/$id.json" 2>/dev/null)"
  if ! [[ "$plan_d" =~ ^[0-9a-f]{64}$ ]]; then plan_d=""; reason=NO_PLAN
  elif [[ -z "$appr" ]]; then reason=NOT_APPROVED
  elif [[ "$(jq -r '.digest // empty' <<<"$appr")" != "$plan_d" ]]; then reason=PLAN_CHANGED
  elif ! afk_pc_load_config || ! afk_pcp_attested "$(jq -r '.paperclip_commit // "-"' <<<"$appr")"; then
    reason=APPROVAL_INTERIM_UNATTESTED
  else approved=true; fi
  if [[ "$json_mode" == true ]]; then
    jq -nc --argjson a "$approved" --arg d "$plan_d" --arg r "$reason" \
      '{approved:$a, digest:(if $d == "" then null else $d end), digest8:(if $d == "" then null else $d[0:8] end), reason:$r}'
  else
    printf '%s %s\n' "$([[ "$approved" == true ]] && printf approved || printf 'not approved:')" "$reason"
  fi
  [[ "$approved" == true ]]
}
