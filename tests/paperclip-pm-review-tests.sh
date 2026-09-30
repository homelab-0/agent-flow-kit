#!/usr/bin/env bash
# Focused regression cases for the AFK-ORCA-3 PM-start review.
set -uo pipefail

KIT_ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT
PASS=0 FAIL=0
check() { # <label> <actual> <expected>
  if [[ "$2" == "$3" ]]; then printf 'PASS %s\n' "$1"; PASS=$((PASS + 1))
  else printf 'FAIL %s: expected %s, got %s\n' "$1" "$3" "$2"; FAIL=$((FAIL + 1)); fi
}

# Stub only the Orca boundary; use the real start and reconciliation functions.
afk_orca_run() {
  AFK_ORCA_CODE=OK
  case " $* " in
    *' pm-start-worktree -- worktree show '*)
      AFK_ORCA_OUT="$(jq -nc --arg p "$repo_path" '{result:{worktree:{id:"wt-1",path:$p}}}')" ;;
    *' pm-start-create -- terminal create '*)
      CREATE_CALLS=$((CREATE_CALLS + 1))
      case "$CREATE_MODE" in
        error) AFK_ORCA_CODE=ORCA_ERROR:runtime_unavailable; AFK_ORCA_OUT='{"ok":false,"error":{"code":"runtime_unavailable"}}'; return 1 ;;
        timeout) AFK_ORCA_CODE=ORCA_TIMEOUT; AFK_ORCA_OUT=''; return 1 ;;
      esac
      AFK_ORCA_OUT='{"result":{"terminal":{"handle":"created-b"}},"_meta":{"runtimeId":"rt-1"}}' ;;
    *' pm-start-reconcile-agents -- worktree ps '*)
      AFK_ORCA_OUT="$(jq -nc --argjson a "$PS_AGENTS" '{result:{worktrees:[{id:"wt-1",agents:$a}]},_meta:{runtimeId:"rt-1"}}')" ;;
    *) AFK_ORCA_CODE=ORCA_CLI_FAILED; AFK_ORCA_OUT=''; return 1 ;;
  esac
}
afk_orca_liveness_reset() { :; }
afk_orca_terminal_state() { AFK_ORCA_TERMINAL_STATE="$ROW_STATE"; AFK_ORCA_TERMINAL_REASON="$ROW_REASON"; }
afk_orca_list_state() {
  _AFK_ORCA_LV_RUNTIME="${LIST_RUNTIME:-rt-1}"
  _AFK_ORCA_LV_TERMINALS="$LIST_TERMINALS"
  return 0
}
afk_orca_identity() {
  local handle="$1"; [[ "$handle" == --bound ]] && handle="$3"
  IDENTITY_CALLS+="$handle "
  if [[ "${IDENTITY_MODE:-ok}" == fail || "${IDENTITY_MODE:-ok}" == stale ]]; then
    AFK_ORCA_IDENTITY=''
    if [[ "$IDENTITY_MODE" == stale ]]; then
      AFK_ORCA_CODE=ORCA_ERROR:terminal_handle_stale
      AFK_ORCA_OUT="$(jq -nc --arg rt "${SHOW_RUNTIME:-rt-1}" '{_meta:{runtimeId:$rt}}')"
    fi
    return 1
  fi
  AFK_ORCA_IDENTITY="$(jq -nc --arg h "$handle" '{handle:$h,runtime_id:"rt-1",worktree_id:"wt-1",tab_id:("tab-"+$h),leaf_id:("leaf-"+$h),agent_type:"claude"}')"
}
afk_pc_create_issue() { printf x >>"$REPORT_FILE"; printf '201\n{"id":"need-human"}'; }
afk_scope_sha256() { sha256sum | cut -d' ' -f1; }
afk_state_file_write() {
  if [[ "${FAIL_CANDIDATE_WRITE:-false}" == true && "$1" == "$ledger_path" ]] &&
     jq -e '.pm_started[]?.candidate.handle' <<<"$2" >/dev/null 2>&1; then return 1; fi
  mkdir -p "$(dirname -- "$1")"; printf '%s\n' "$2" >"$1"
}
. "$KIT_ROOT/lib/afk-paperclip-start.sh"
AFK_ORCA_LIST_LIMIT=1000

A=e1111111-1111-1111-1111-111111111111
B=e2222222-2222-2222-2222-222222222222
reset_case() {
  local name="$1"
  AFK_STATE_DIR="$TMPROOT/$name/state"; repo_path="$TMPROOT/$name/repo"
  mkdir -p "$repo_path" "$AFK_STATE_DIR/paperclip"
  ledger_path="$AFK_STATE_DIR/paperclip/ledger.json"
  ledger='{"pm_started":{}}'; afk_state_file_write "$ledger_path" "$ledger"
  id="$B"; slug=proj; harness=claude; identifier=PROJ-2
  api_url=https://paperclip.test; key=secret; company_id=cccccccc-cccc-cccc-cccc-cccccccccccc
  board_user_id=board; AFK_KIT_ROOT="$KIT_ROOT"; AFK_PM_BOOTSTRAP_BIN=/bin/true
  AFK_PCS_ACTION_OVERRIDE=''; CREATE_CALLS=0; REPORT_CALLS=0; IDENTITY_CALLS=''
  REPORT_FILE="$TMPROOT/$name/reports"; : >"$REPORT_FILE"
  CREATE_MODE=ok; PS_AGENTS='[]'; LIST_TERMINALS='[]'
  ROW_STATE=live; ROW_REASON=null
  IDENTITY_MODE=ok
  SHOW_RUNTIME=rt-1; LIST_RUNTIME=rt-1
  FAIL_CANDIDATE_WRITE=false
}
prior_row() {
  local intent="$AFK_STATE_DIR/paperclip/pm-start-intents/proj.$A.json"
  afk_state_file_write "$intent" "$(jq -nc --arg p "$repo_path" '{worktree:{id:"wt-1",path:$p}}')"
  ledger="$(jq -c --arg a "$A" --arg p "$repo_path" --arg f "$intent" \
    '.pm_started[$a]={state:"created",repo:$p,slug:"proj",harness:"claude",terminal:"old-a",intent_file:$f,
      identity:{handle:"old-a",runtime_id:"rt-1",worktree_id:"wt-1",tab_id:"tab-old-a",leaf_id:"leaf-old-a",agent_type:"claude"}}' <<<"$ledger")"
  afk_state_file_write "$ledger_path" "$ledger"
}

reset_case prior_stale; prior_row; ROW_STATE=stale; ROW_REASON=PM_TERMINAL_STALE
afk_pcs_create_terminal || true
check 'H1 stale prior row ends and B starts' "$(jq -r --arg a "$A" --arg b "$B" '.pm_started[$a].state + "/" + (.pm_started[$b].state // "missing")' <<<"$ledger")" ended/created
check 'H1 stale prior row permits one create' "$CREATE_CALLS" 1
reset_case prior_handle_only; prior_row
ledger="$(jq -c --arg a "$A" '.pm_started[$a].identity = null | .pm_started[$a].runtime_id = "rt-1"' <<<"$ledger")"
afk_state_file_write "$ledger_path" "$ledger"
ROW_STATE=stale; ROW_REASON=PM_TERMINAL_STALE
afk_pcs_create_terminal || true
check 'N1 prior handle-only row is resolved on its handle' "$IDENTITY_CALLS" 'old-a created-b '
check 'N1 prior handle-only stale row ends and next issue starts' \
  "$(jq -r --arg a "$A" --arg b "$B" '.pm_started[$a].state + "/" + (.pm_started[$b].state // "missing")' <<<"$ledger")" ended/created
check 'N1 prior handle-only row does not escalate' "$(wc -c <"$REPORT_FILE" | tr -d ' ')" 0
reset_case prior_handle_stale_show; prior_row
ledger="$(jq -c --arg a "$A" '.pm_started[$a].identity = null | .pm_started[$a].runtime_id = "rt-1"' <<<"$ledger")"
afk_state_file_write "$ledger_path" "$ledger"
IDENTITY_MODE=stale
afk_pcs_create_terminal || true
check 'N1 same-runtime stale show and absent handle end prior row' \
  "$(jq -r --arg a "$A" --arg b "$B" '.pm_started[$a].state + "/" + (.pm_started[$b].state // "missing")' <<<"$ledger")" ended/created
check 'N1 stale proof uses a complete list' "$IDENTITY_CALLS" 'old-a created-b '
reset_case prior_handle_new_runtime; prior_row
ledger="$(jq -c --arg a "$A" '.pm_started[$a].identity = null | .pm_started[$a].runtime_id = "rt-1"' <<<"$ledger")"
afk_state_file_write "$ledger_path" "$ledger"
IDENTITY_MODE=stale; SHOW_RUNTIME=rt-2; LIST_RUNTIME=rt-2
afk_pcs_create_terminal || true
check 'N1 changed runtime never authorizes a new start' "$CREATE_CALLS" 0
check 'N1 changed runtime is visibly unknown' "$AFK_PCS_ACTION_OVERRIDE" \
  'queued: no PM (start held: PM_RUNTIME_MISMATCH)'

reset_case receipt_runtime; IDENTITY_MODE=fail; afk_pcs_create_terminal || true
check 'N1 create receipt runtime persists when show fails' \
  "$(jq -r --arg b "$B" '.pm_started[$b].runtime_id // empty' <<<"$ledger")" rt-1
check 'N1 create receipt identity remains null on show failure' \
  "$(jq -r --arg b "$B" '.pm_started[$b].identity | tostring' <<<"$ledger")" null

reset_case same_issue_stale; id="$A"; prior_row; ROW_STATE=stale; ROW_REASON=PM_TERMINAL_STALE
afk_pcs_existing_start || true
afk_pcs_create_terminal || true
check 'N2 same-issue stale row ends without a new create' "$CREATE_CALLS" 0
check 'N2 same-issue ended row has held reason' "$AFK_PCS_ACTION_OVERRIDE" \
  'queued: no PM (start held: PM_START_ENDED)'
check 'N2 same-issue ended row keeps its row' "$(jq -r --arg a "$A" '.pm_started[$a].state' <<<"$ledger")" ended
for _ in 1 2 3; do afk_pcs_existing_start || true; done
check 'N2 ended row opens one NEEDS HUMAN path' "$(wc -c <"$REPORT_FILE" | tr -d ' ')" 1
for verdict in live detached unknown; do
  reset_case "prior_$verdict"; prior_row; ROW_STATE="$verdict"
  case "$verdict" in live) ROW_REASON=PM_OWNER_LIVE ;; detached) ROW_REASON=PM_TERMINAL_DETACHED ;; unknown) ROW_REASON=PM_RUNTIME_MISMATCH ;; esac
  afk_pcs_create_terminal || true
  check "H1 $verdict prior row blocks create" "$CREATE_CALLS" 0
  present=no; [[ "$AFK_PCS_ACTION_OVERRIDE" == *"$ROW_REASON"* ]] && present=yes
  check "H1 $verdict hold has reason" "$present" yes
done

reset_case definite_error; CREATE_MODE=error; afk_pcs_create_terminal || true
check 'H2 definite error is retryable' "$(jq -r --arg b "$B" '.pm_started[$b].state' <<<"$ledger")" failed
CREATE_MODE=ok; afk_pcs_create_terminal || true
check 'H2 healthy retry creates once' "$(jq -r --arg b "$B" '.pm_started[$b].state' <<<"$ledger")" created
check 'H2 retry attempts are exactly two' "$CREATE_CALLS" 2

reset_case uncertain; CREATE_MODE=timeout; afk_pcs_create_terminal || true
check 'H2 timeout is visible' "$AFK_PCS_ACTION_OVERRIDE" 'queued: no PM (start unresolved: ORCA_TIMEOUT)'
CREATE_MODE=ok
for _ in 1 2 3; do afk_pcs_existing_start || true; done
check 'H2 timeout never creates again' "$CREATE_CALLS" 1
check 'H2 timeout opens one repair issue' "$(wc -c <"$REPORT_FILE" | tr -d ' ')" 1

reset_case no_intent
ledger="$(jq -nc --arg b "$B" --arg p "$repo_path" --arg f "$AFK_STATE_DIR/paperclip/pm-start-intents/proj.$B.json" \
  '{pm_started:{($b):{state:"intent",repo:$p,slug:"proj",harness:"claude",terminal:null,identity:null,intent_file:$f}}}')"
afk_state_file_write "$ledger_path" "$ledger"
if afk_pcs_existing_start; then resumed=no; else resumed=yes; fi
check 'H2 row without intent file resumes' "$resumed" yes

reset_case handle_only
ledger="$(jq -nc --arg b "$B" --arg p "$repo_path" '{pm_started:{($b):{state:"created",repo:$p,slug:"proj",harness:"claude",terminal:"returned-handle",identity:null}}}')"
afk_state_file_write "$ledger_path" "$ledger"
afk_pcs_existing_start || true
check 'M4 handle receipt is never replaced by a different join' "$(jq -r --arg b "$B" '.pm_started[$b].terminal' <<<"$ledger")" returned-handle
check 'M4 identity is read only from receipt handle' "$IDENTITY_CALLS" 'returned-handle '

reset_case unproven_candidate
intent="$AFK_STATE_DIR/paperclip/pm-start-intents/proj.$B.json"
afk_state_file_write "$intent" "$(jq -nc --arg p "$repo_path" '{worktree:{id:"wt-1",path:$p}}')"
ledger="$(jq -nc --arg b "$B" --arg p "$repo_path" --arg f "$intent" '{pm_started:{($b):{state:"intent",repo:$p,slug:"proj",harness:"claude",terminal:null,identity:null,intent_file:$f}}}')"
afk_state_file_write "$ledger_path" "$ledger"
PS_AGENTS='[{"paneKey":"tab-interactive:leaf-interactive","agentType":"claude"}]'
LIST_TERMINALS='[{"handle":"interactive","connected":true,"orphaned":false}]'
afk_pcs_existing_start || true
check 'M4 unique interactive join remains a candidate' "$(jq -r --arg b "$B" '.pm_started[$b].state + "/" + (.pm_started[$b].terminal|tostring)' <<<"$ledger")" intent/null
check 'M4 candidate is recorded for operator review' "$(jq -r --arg b "$B" '.pm_started[$b].candidate.handle // empty' <<<"$ledger")" interactive

reset_case candidate_write_failure
intent="$AFK_STATE_DIR/paperclip/pm-start-intents/proj.$B.json"
afk_state_file_write "$intent" "$(jq -nc --arg p "$repo_path" '{worktree:{id:"wt-1",path:$p}}')"
ledger="$(jq -nc --arg b "$B" --arg p "$repo_path" --arg f "$intent" '{pm_started:{($b):{state:"intent",repo:$p,slug:"proj",harness:"claude",terminal:null,identity:null,intent_file:$f}}}')"
afk_state_file_write "$ledger_path" "$ledger"
PS_AGENTS='[{"paneKey":"tab-interactive:leaf-interactive","agentType":"claude"}]'
LIST_TERMINALS='[{"handle":"interactive","connected":true,"orphaned":false}]'
FAIL_CANDIDATE_WRITE=true
if afk_pcs_existing_start; then held=yes; else held=no; fi
check 'review candidate write failure holds the start' "$held" yes
check 'review candidate write failure preserves its reason' "$AFK_PCS_ACTION_OVERRIDE" \
  'queued: no PM (start held: PM_LEDGER_WRITE_FAILED)'

reset_case symlink_repo
real_repo="$repo_path"; repo_path="$TMPROOT/symlink_repo/link"
ln -s "$real_repo" "$repo_path"
intent="$AFK_STATE_DIR/paperclip/pm-start-intents/proj.$B.json"
afk_state_file_write "$intent" "$(jq -nc --arg p "$real_repo" '{worktree:{id:"wt-1",path:$p}}')"
ledger="$(jq -nc --arg b "$B" --arg p "$repo_path" --arg f "$intent" '{pm_started:{($b):{state:"intent",repo:$p,slug:"proj",harness:"claude",terminal:null,identity:null,intent_file:$f}}}')"
afk_state_file_write "$ledger_path" "$ledger"
PS_AGENTS='[{"paneKey":"tab-interactive:leaf-interactive","agentType":"claude"}]'
LIST_TERMINALS='[{"handle":"interactive","connected":true,"orphaned":false}]'
afk_pcs_existing_start || true
check 'review symlink repo reaches the candidate join' \
  "$(jq -r --arg b "$B" '.pm_started[$b].candidate.handle // empty' <<<"$ledger")" interactive
check 'review symlink repo is not an intent mismatch' \
  "$([[ "$AFK_PCS_ACTION_OVERRIDE" == *PM_INTENT_MISMATCH* ]] && echo yes || echo no)" no

reset_case owned_candidate
intent="$AFK_STATE_DIR/paperclip/pm-start-intents/proj.$B.json"
afk_state_file_write "$intent" "$(jq -nc --arg p "$repo_path" '{worktree:{id:"wt-1",path:$p}}')"
ledger="$(jq -nc --arg b "$B" --arg p "$repo_path" --arg f "$intent" '{pm_started:{($b):{state:"intent",repo:$p,slug:"proj",harness:"claude",terminal:null,identity:null,intent_file:$f}}}')"
afk_state_file_write "$ledger_path" "$ledger"
PS_AGENTS='[{"paneKey":"tab-interactive:leaf-interactive","agentType":"claude"}]'
LIST_TERMINALS='[{"handle":"interactive","connected":true,"orphaned":false}]'
mkdir -p "$AFK_STATE_DIR/pm/scopes/owned"
printf '{"owned":true,"terminal":"interactive"}\n' >"$AFK_STATE_DIR/pm/scopes/owned/ownership.json"
afk_pcs_existing_start || true
check 'M4 registry-owned terminal is excluded from candidates' "$(jq -r --arg b "$B" '.pm_started[$b].candidate.handle // empty' <<<"$ledger")" ''

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
