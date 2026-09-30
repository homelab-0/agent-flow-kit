#!/usr/bin/env bash
# Focused regression cases for claim replay and artifact paths.
set -uo pipefail
KIT_ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT
PASS=0 FAIL=0
check() {
  if [[ "$2" == "$3" ]]; then printf 'PASS %s\n' "$1"; PASS=$((PASS + 1))
  else printf 'FAIL %s: expected %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL + 1)); fi
}
afk_state_dir_ensure() { mkdir -p "$1"; }
afk_state_file_write() { mkdir -p "$(dirname -- "$1")"; printf '%s\n' "$2" >"$1"; }
afk_orca_bin() { :; } # the claim helpers never run Orca
. "$KIT_ROOT/lib/afk-paperclip.sh"
afk_pc_curl() { printf '200\n'; cat "$COMMENTS_FILE"; }
afk_pc_comment() {
  printf '%s\n' "$POST_STATUS" >>"$POST_LOG"
  if [[ "$POST_STATUS" == 201 && "${POST_PERSIST:-true}" == true ]]; then
    jq -c --arg b "$5" --arg a "$agent_id" '. + [{body:$b,authorAgentId:$a}]' "$COMMENTS_FILE" >"$COMMENTS_FILE.tmp"
    mv "$COMMENTS_FILE.tmp" "$COMMENTS_FILE"
  fi
  printf '%s\n{}' "$POST_STATUS"
}

id=e1111111-1111-1111-1111-111111111111
agent_id=11111111-1111-1111-1111-111111111111
api_url=https://paperclip.test; key=secret; host_name=test-host
slug=proj; identifier=PROJ-1; repo_path=/test/repo; harness=claude
title=Title; desc=Description; updated=2026-01-01T00:00:00Z; run_id="run-1"
reset_case() {
  local name="$1"
  AFK_STATE_DIR="$TMPROOT/$name/state"
  ledger_path="$AFK_STATE_DIR/paperclip/ledger.json"
  ledger="$(jq -nc --arg id "$id" '{issues:{($id):{since:"2026-01-01T00:00:00Z"}}}')"
  afk_state_file_write "$ledger_path" "$ledger"
  COMMENTS_FILE="$TMPROOT/$name/comments.json"; printf '[]\n' >"$COMMENTS_FILE"
  POST_LOG="$TMPROOT/$name/posts"; : >"$POST_LOG"
  POST_STATUS=201; POST_PERSIST=true; actions='[]'; AFK_PC_ABORT=false
}

reset_case definite_failure
POST_STATUS=409; afk_pc_claim_comment || true
check 'M1 definite rejection clears attempt' "$(jq -r --arg id "$id" '.issues[$id].claim_attempted // false' <<<"$ledger")" false
POST_STATUS=201; afk_pc_claim_comment || true
check 'M1 retry posts once successfully' "$(jq 'length' "$COMMENTS_FILE")" 1
check 'M1 retry has two attempts' "$(wc -l <"$POST_LOG" | tr -d ' ')" 2

reset_case ambiguous_failure
POST_STATUS=500; afk_pc_claim_comment || true
POST_STATUS=201; afk_pc_claim_comment || true
check 'M1 ambiguous 500 never blindly reposts' "$(wc -l <"$POST_LOG" | tr -d ' ')" 1
present=no; [[ "$actions" == *'claim read-back unresolved, held'* ]] && present=yes
check 'M1 ambiguous hold is visible' "$present" yes

reset_case posted_readback_unresolved
POST_STATUS=201; POST_PERSIST=false
if afk_pc_claim_comment; then held=no; else held=yes; fi
check 'review unresolved post-POST read-back returns nonzero' "$held" yes
check 'review unresolved claim remains intent' \
  "$(jq -r --arg id "$id" '.issues[$id].claim' <<<"$ledger")" intent
check 'review unresolved claim keeps the attempt receipt' \
  "$(jq -r --arg id "$id" '.issues[$id].claim_attempted' <<<"$ledger")" true

reset_case before_post_kill
ledger="$(jq -c --arg id "$id" '.issues[$id] |= (. + {claim:"intent",claim_attempted:true,claim_comment_pending:true})' <<<"$ledger")"
afk_state_file_write "$ledger_path" "$ledger"
afk_pc_claim_comment || true
check 'M1 killed before POST holds without a second POST' "$(wc -l <"$POST_LOG" | tr -d ' ')" 0
present=no; [[ "$actions" == *'claim read-back unresolved, held'* ]] && present=yes
check 'M1 killed before POST gives an action line' "$present" yes

reset_case artifact_path
afk_pc_claim_artifacts
old_notice="$(jq -r --arg id "$id" '.issues[$id].claimed_notice_path' <<<"$ledger")"
old_brief="$(jq -r --arg id "$id" '.issues[$id].claimed_brief_path' <<<"$ledger")"
check 'M2 notice path is written' "$([[ -f "$old_notice" ]] && echo yes)" yes
check 'M2 brief path is written' "$([[ -f "$old_brief" ]] && echo yes)" yes
# Simulate a crash after journaling but before either file write, then a later
# Paperclip update. Replay must use the paths in the journal, not updatedAt.
rm -f "$old_notice" "$old_brief"
ledger="$(jq -c --arg id "$id" '.issues[$id].claimed_notice="intent" | .issues[$id].claimed_brief="intent"' <<<"$ledger")"
afk_state_file_write "$ledger_path" "$ledger"
updated=2026-02-02T00:00:00Z
afk_pc_claim_artifacts
check 'M2 notice replay uses its journaled path' "$(jq -r --arg id "$id" '.issues[$id].claimed_notice_path' <<<"$ledger")" "$old_notice"
check 'M2 brief replay uses its journaled path' "$(jq -r --arg id "$id" '.issues[$id].claimed_brief_path' <<<"$ledger")" "$old_brief"
check 'M2 replay writes the journaled notice' "$([[ -f "$old_notice" ]] && echo yes)" yes
check 'M2 replay writes the journaled brief' "$([[ -f "$old_brief" ]] && echo yes)" yes
# A second adoption of the same issue must get a distinct, later basename.
ledger="$(jq -c --arg id "$id" '.issues[$id] |= del(.claimed_notice,.claimed_notice_path,.claimed_brief,.claimed_brief_path)' <<<"$ledger")"
afk_state_file_write "$ledger_path" "$ledger"
afk_pc_claim_artifacts
new_notice="$(jq -r --arg id "$id" '.issues[$id].claimed_notice_path' <<<"$ledger")"
new_brief="$(jq -r --arg id "$id" '.issues[$id].claimed_brief_path' <<<"$ledger")"
check 'M2 readoption chooses a new notice basename' "$([[ "$new_notice" != "$old_notice" ]] && echo yes)" yes
check 'M2 readoption chooses a new brief basename' "$([[ "$new_brief" != "$old_brief" ]] && echo yes)" yes
check 'M2 new notice sorts after old' "$([[ "${new_notice##*/}" > "${old_notice##*/}" ]] && echo yes)" yes
same_epoch="$(jq -r --arg id "$id" '.issues[$id].claimed_notice_epoch' <<<"$ledger")"
check 'M2 same-second claim sorts after stopped notice' \
  "$([[ "${new_notice##*/}" > "$same_epoch.$id.stopped.json" ]] && echo yes)" yes

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
