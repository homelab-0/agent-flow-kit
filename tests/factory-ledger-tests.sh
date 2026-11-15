#!/usr/bin/env bash
# factory-ledger-tests.sh — Hermetic tests for the two ledgers the AFK Software
# Factory keeps while several jobs run at once:
#   1. hired-agents.json under concurrent writers (lib/afk-paperclip-hire.sh)
#   2. the same ledger after a bad update or a damaged file
#   3. generation kept across repeated hiring
#   4. large issue documents
#   5. hiring that waits for approval, and hiring after a failed agent list
#   6. Paperclip status codes on state-changing calls
#   7. the per-job context ledger (lib/afk-roster.sh)
#   8. roles chosen from the intake agent's surface list
# No network: every HTTP call goes to a stub curl through AFK_CURL_BIN.

set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0 FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s (%s)\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
head1(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi
}

export HOME="$TMPROOT/home"
export AFK_STATE_DIR="$HOME/.local/state/agent-flow-kit"
export AFK_PAPERCLIP_CONFIG="$HOME/.config/agent-flow-kit/paperclip.json"
# Document bodies pass through a temp file. Keeping TMPDIR inside the test
# root lets a test see whether one was left behind.
export TMPDIR="$TMPROOT/tmp"
mkdir -p "$HOME/.config/agent-flow-kit" "$AFK_STATE_DIR" "$TMPDIR"
unset PAPERCLIP_RUN_ID AFK_PCH_LOCK_STALE_S AFK_PCH_LOCK_WAIT_S

LEDGER="$AFK_STATE_DIR/paperclip/hired-agents.json"
REPO="$TMPROOT/repo"
mkdir -p "$REPO"

API="https://paperclip.example"
KEY="test-key"
COMPANY="4ffcc005-8076-4062-b72e-e4f2d899ecb0"
HOST_AGENT="479f0f09-ee4a-4b31-902b-b662d906f41b"
ISSUE="11111111-2222-4333-8444-666666666666"
REAL_ID="a1111111-2222-4333-8444-555555555555"

# --- stub curl ---------------------------------------------------------------
# Logs "<METHOD> <url>" per request. An answer is "<body><3-digit status>",
# read from $STUB_STATE/<name> when that file exists.
STUB_BIN="$TMPROOT/bin"
export STUB_STATE="$TMPROOT/stub-state"
export STUB_LOG="$TMPROOT/curl.log"
mkdir -p "$STUB_BIN" "$STUB_STATE"

cat > "$STUB_BIN/curl" <<'CURL'
#!/usr/bin/env bash
method="GET" url="" data=""
while (($#)); do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data-binary) data="$(cat -- "${2#@}" 2>/dev/null || true)"; shift 2 ;;
    http*://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s %s\n' "$method" "$url" >> "$STUB_LOG"
answer() { # <name> <default>
  if [[ -f "$STUB_STATE/$1" ]]; then cat "$STUB_STATE/$1"; else printf '%s' "$2"; fi
}
case "$method $url" in
  "GET "*"/api/companies/"*"/agents")
    [[ -f "$STUB_STATE/list-exit" ]] && exit "$(cat "$STUB_STATE/list-exit")"
    [[ -f "$STUB_STATE/list-delay" ]] && sleep "$(cat "$STUB_STATE/list-delay")"
    if [[ -f "$STUB_STATE/list-hold" ]]; then
      for _ in $(seq 1 200); do
        [[ -f "$STUB_STATE/list-release" ]] && break
        sleep 0.05
      done
    fi
    answer list '[]200' ;;
  "POST "*"/api/companies/"*"/agent-hires")
    answer hire '{"agent":{"id":"a1111111-2222-4333-8444-555555555555","status":"active"}}201' ;;
  "POST "*"/api/agents/"*"/resume")
    answer resume '{"ok":true}200' ;;
  "PATCH "*"/api/agents/"*)
    answer agent-patch '{"ok":true}200' ;;
  "PATCH "*"/api/issues/"*)
    answer issue-patch '{"ok":true}200' ;;
  "GET "*"/api/issues/"*"/documents/"*)
    printf '{"error":"not_found"}404' ;;
  "PUT "*"/api/issues/"*"/documents/"*)
    printf '%s' "$data" > "$STUB_STATE/last-put-body"
    printf '{"id":"d1111111-2222-4333-8444-555555555555","key":"plan","latestRevisionId":"f1111111-2222-4333-8444-555555555555","latestRevisionNumber":1}200' ;;
  *)
    printf '{"ok":true}200' ;;
esac
CURL
chmod +x "$STUB_BIN/curl"

export AFK_CURL_BIN="$STUB_BIN/curl"
# shellcheck disable=SC1091
source "$KIT_ROOT/lib/afk-paperclip-hire.sh"

reset_state() {
  rm -rf "$AFK_STATE_DIR/paperclip"
  rm -f "$STUB_STATE"/* "$STUB_LOG"
  : > "$STUB_LOG"
}
requests() { grep -c -- "$1" "$STUB_LOG" || true; } # <pattern>
online_team() { # <slug> <roles_csv>
  afk_pch_ensure_project_team "$1" "$REPO" claude "$2" "$ISSUE" "$API" "$KEY" "$COMPANY" "$HOST_AGENT"
}
offline_team() { # <slug> <roles_csv>
  afk_pch_ensure_project_team "$1" "$REPO" claude "$2"
}

# ============================================================================
head1 "1. Concurrent jobs write one hired-agents ledger"
# ============================================================================

# Each hire reads the ledger, waits on a slow agent list, then writes. Every
# job has read the ledger before any of them writes it.
reset_state
printf '0.3' > "$STUB_STATE/list-delay"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  ( online_team "slow$i" pm >/dev/null 2>&1 ) &
done
wait
assert_eq "Twelve jobs hiring at once behind a slow agent list are all in the ledger, with no temp or lock file left" \
  "$(jq -r '[.projects[].agents.pm.agent_id] | length' "$LEDGER" 2>/dev/null):$(ls -A "$AFK_STATE_DIR/paperclip" | tr '\n' ' ')" \
  "12:hired-agents.json "

# No HTTP here, so the jobs collide on the read, update and write itself.
reset_state
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  ( offline_team "burst$i" pm,dev >/dev/null 2>&1 ) &
done
wait
assert_eq "Twelve offline jobs hiring two roles each at once leave twenty-four agents in a valid ledger" \
  "$(jq -r '[.projects[].agents[]] | length' "$LEDGER" 2>/dev/null):$(ls -A "$AFK_STATE_DIR/paperclip" | tr '\n' ' ')" \
  "24:hired-agents.json "

# One job is held inside its agent list call, which then fails, while another
# job records the real agent for the same role.
reset_state
: > "$STUB_STATE/list-hold"
printf '%s' '{"error":"boom"}500' > "$STUB_STATE/list"
printf '%s' '{"error":"boom"}500' > "$STUB_STATE/hire"
( online_team race dev >/dev/null 2>&1 ) &
RACE_PID=$!
for _ in $(seq 1 200); do
  grep -q 'GET .*/agents' "$STUB_LOG" && break
  sleep 0.05
done
afk_pch_save_ledger "$(jq -cn --arg id "$REAL_ID" \
  '{schema: "afk-hired-agents/1", projects: {race: {agents: {dev: {agent_id: $id, name: "race-dev", role: "dev", state: "active", generation: 3}}}}}')"
: > "$STUB_STATE/list-release"
wait "$RACE_PID"
assert_eq "A hire that fell back to a placeholder keeps the real agent id and generation another job recorded meanwhile" \
  "$(jq -r '.projects.race.agents.dev | "\(.agent_id):\(.state):\(.generation)"' "$LEDGER" 2>/dev/null)" \
  "$REAL_ID:active:3"

reset_state
mkdir -p "$LEDGER.lock"
touch -t 202001010000 "$LEDGER.lock"
AFK_PCH_LOCK_WAIT_S=5 offline_team stale pm >/dev/null 2>&1
assert_eq "A lock left behind by a killed process is taken over and then released" \
  "$(jq -r '.projects.stale.agents.pm.agent_id' "$LEDGER" 2>/dev/null):$([[ -d "$LEDGER.lock" ]] && echo held || echo free)" \
  "local-stale-pm:free"

reset_state
offline_team held pm >/dev/null
HELD_BEFORE="$(cat "$LEDGER")"
mkdir "$LEDGER.lock"
HELD_RC=0
AFK_PCH_LOCK_WAIT_S=1 afk_pch_assign_stage held dev "" "" >/dev/null 2>&1 || HELD_RC=$?
assert_eq "A writer that cannot get a held lock gives up without writing and without removing the lock" \
  "$HELD_RC:$([[ "$(cat "$LEDGER")" == "$HELD_BEFORE" ]] && echo unchanged || echo changed):$([[ -d "$LEDGER.lock" ]] && echo held || echo free)" \
  "1:unchanged:held"
rmdir "$LEDGER.lock" 2>/dev/null || true

# ============================================================================
head1 "2. A bad update or a damaged file does not wipe the ledger"
# ============================================================================

reset_state
offline_team keep pm,dev >/dev/null
afk_pch_replace_agent_session keep pm "" >/dev/null 2>&1
assert_eq "A replacement with an empty generation leaves the ledger as it was" \
  "$(jq -r '.projects.keep.agents | keys | join(",")' "$LEDGER" 2>/dev/null)" \
  "dev,pm"

afk_pch_replace_agent_session keep pm "two" >/dev/null 2>&1
assert_eq "A replacement with a generation that is not a number leaves the ledger as it was" \
  "$(jq -r '.projects.keep.agents.pm | "\(.agent_id):\(.generation)"' "$LEDGER" 2>/dev/null)" \
  "local-keep-pm:1"

SAVE_BEFORE="$(cat "$LEDGER")"
SAVE_RCS=""
for bad_content in "" "[]" '{"projects":null}' '{"schema":"afk-hired-agents/1"'; do
  if afk_pch_save_ledger "$bad_content" 2>/dev/null; then SAVE_RCS+="0"; else SAVE_RCS+="1"; fi
done
assert_eq "Saving refuses empty text, a non-object, a null projects field and cut-off JSON, and keeps the file" \
  "$SAVE_RCS:$([[ "$(cat "$LEDGER")" == "$SAVE_BEFORE" ]] && echo unchanged || echo changed)" \
  "1111:unchanged"

printf '\n' > "$LEDGER"
offline_team blank pm >/dev/null 2>&1
assert_eq "A blank ledger file is repaired by the next hire" \
  "$(jq -r '.projects.blank.agents.pm.agent_id' "$LEDGER" 2>/dev/null)" \
  "local-blank-pm"

printf '{"schema":"afk-hired-agents/1","projects":{"cut":' > "$LEDGER"
assert_eq "A ledger file holding cut-off JSON loads as the empty ledger" \
  "$(afk_pch_load_ledger | jq -c '.projects' 2>/dev/null)" \
  "{}"

printf '{"schema":"afk-hired-agents/1","projects":null}\n' > "$LEDGER"
assert_eq "A ledger file whose projects field is not an object loads as the empty ledger" \
  "$(afk_pch_load_ledger | jq -c '.projects' 2>/dev/null)" \
  "{}"

# ============================================================================
head1 "3. Hiring again keeps a replaced role's generation"
# ============================================================================

reset_state
offline_team gen pm,dev >/dev/null
afk_pch_replace_agent_session gen dev 2
GEN_SECOND="$(offline_team gen pm,dev)"
assert_eq "A second ensure-team call keeps generation 2 in the ledger and in the entry it prints" \
  "$(jq -r '.projects.gen.agents.dev.generation' "$LEDGER"):$(jq -r '.[] | select(.role == "dev") | .generation' <<<"$GEN_SECOND")" \
  "2:2"

# ============================================================================
head1 "4. Large issue documents"
# ============================================================================

reset_state
head -c 300000 /dev/zero | tr '\0' 'a' > "$TMPROOT/report-300k.md"
DOC_OUT="$(afk_pch_upsert_document "$API" "$KEY" "run-1" "$ISSUE" "review-report" "Review report" "$TMPROOT/report-300k.md" 2>/dev/null)"
assert_eq "A 300 KB document is sent with its whole body and no temp file is left" \
  "$(jq -r '.body | length' "$STUB_STATE/last-put-body" 2>/dev/null):$(jq -r '.latestRevisionNumber' <<<"$DOC_OUT" 2>/dev/null):$(find "$TMPDIR" -name 'afk-pch-doc.*' | wc -l | tr -d ' ')" \
  "300000:1:0"

reset_state
head -c 600000 /dev/zero | tr '\0' 'b' > "$TMPROOT/report-600k.md"
afk_pch_upsert_document "$API" "$KEY" "run-1" "$ISSUE" "review-report" "Review report" "$TMPROOT/report-600k.md" >/dev/null 2>&1
assert_eq "A document over the size cap is cut to 500000 bytes and still sent" \
  "$(jq -r '.body | length' "$STUB_STATE/last-put-body" 2>/dev/null)" \
  "500000"

reset_state
printf '# Small report\n' > "$TMPROOT/report-small.md"
(
  # Fails only the jq call that builds the document body.
  jq() {
    local a
    for a in "$@"; do
      [[ "$a" == "--rawfile" || "$a" == "Small report" || "$a" == "# Small report" ]] && return 1
    done
    command jq "$@"
  }
  afk_pch_upsert_document "$API" "$KEY" "run-1" "$ISSUE" "review-report" "Small report" "$TMPROOT/report-small.md" >/dev/null 2>&1
)
assert_eq "No document request is sent when its body could not be built" \
  "$(requests '^PUT ')" \
  "0"

# ============================================================================
head1 "5. Hiring that waits for approval, and hiring after a failed agent list"
# ============================================================================

reset_state
printf '%s' '{"approval":{"id":"ap-1","status":"pending"}}202' > "$STUB_STATE/hire"
online_team pend pm >/dev/null
assert_eq "A hire accepted without an agent id is recorded as pending with the time it was asked for" \
  "$(jq -r '.projects.pend.agents.pm | "\(.status):\(.agent_id):\(.pending_since | type)"' "$LEDGER")" \
  "pending:local-pend-pm:string"

online_team pend pm >/dev/null
offline_team pend pm >/dev/null
online_team pend pm >/dev/null
assert_eq "A pending hire is not posted again by later ensure-team calls" \
  "$(requests 'POST .*/agent-hires'):$(jq -r '.projects.pend.agents.pm.status' "$LEDGER")" \
  "1:pending"

printf '[{"id":"%s","name":"pend-pm","status":"idle"}]200' "$REAL_ID" > "$STUB_STATE/list"
online_team pend pm >/dev/null
assert_eq "A pending hire takes the real agent id once the agent is listed, without another hire request" \
  "$(jq -r '.projects.pend.agents.pm | "\(.agent_id):\(.state):\(.status // "none"):\(has("pending_since"))"' "$LEDGER"):$(requests 'POST .*/agent-hires')" \
  "$REAL_ID:active:none:false:1"

reset_state
printf '%s' '{"error":"boom"}500' > "$STUB_STATE/list"
online_team listfail pm >/dev/null
POSTS_AFTER_500="$(requests 'POST .*/agent-hires')"
rm -f "$STUB_STATE/list"
printf '7' > "$STUB_STATE/list-exit"
online_team listfail pm >/dev/null
POSTS_AFTER_TIMEOUT="$(requests 'POST .*/agent-hires')"
rm -f "$STUB_STATE/list-exit"
online_team listfail pm >/dev/null
assert_eq "No hire is posted after a failed or timed-out agent list, and one is posted once the list answers" \
  "$POSTS_AFTER_500:$POSTS_AFTER_TIMEOUT:$(requests 'POST .*/agent-hires'):$(jq -r '.projects.listfail.agents.pm.agent_id' "$LEDGER")" \
  "0:0:1:$REAL_ID"

# ============================================================================
head1 "6. Paperclip status codes on state-changing calls"
# ============================================================================

reset_state
printf '%s' '{"error":"conflict"}409' > "$STUB_STATE/issue-patch"
FINISH_REJECTED=0
afk_pch_finish_issue fin dev "$ISSUE" "$API" "$KEY" "run-1" >/dev/null 2>&1 || FINISH_REJECTED=$?
rm -f "$STUB_STATE/issue-patch"
FINISH_ACCEPTED=0
afk_pch_finish_issue fin dev "$ISSUE" "$API" "$KEY" "run-1" >/dev/null 2>&1 || FINISH_ACCEPTED=$?
assert_eq "Finishing an issue fails when Paperclip rejects the change and succeeds when it accepts it" \
  "$FINISH_REJECTED:$FINISH_ACCEPTED" \
  "1:0"

reset_state
online_team stage pm >/dev/null
printf '%s' '{"error":"conflict"}409' > "$STUB_STATE/issue-patch"
STAGE_RC=0
afk_pch_assign_stage stage pm "$ISSUE" "" "$API" "$KEY" "run-1" >/dev/null 2>&1 || STAGE_RC=$?
assert_eq "Assigning a stage reports Paperclip refusing the move to in progress (status 2), and still records the active role" \
  "$STAGE_RC:$(jq -r '.projects.stage.active_role' "$LEDGER")" \
  "2:pm"

reset_state
online_team swap dev >/dev/null
printf '%s' '{"error":"unavailable"}503' > "$STUB_STATE/resume"
afk_pch_replace_agent_session swap dev 2 "" "context threshold reached" "$API" "$KEY" "run-1" >/dev/null 2>&1
assert_eq "A replacement whose pause works and whose resume fails records the agent as paused at the new generation" \
  "$(jq -r '.projects.swap.agents.dev | "\(.state):\(.generation)"' "$LEDGER")" \
  "paused:2"

rm -f "$STUB_STATE/resume"
online_team swap dev >/dev/null
assert_eq "The next hire pass resumes an agent that a replacement left paused" \
  "$(jq -r '.projects.swap.agents.dev | "\(.state):\(.generation)"' "$LEDGER"):$(requests 'POST .*/resume')" \
  "active:2:2"

# ============================================================================
head1 "7. Per-job context ledger"
# ============================================================================

JOB="$TMPROOT/job-text"
afk_roster_record_and_check_context "$JOB" dev 150k 200000 >/dev/null 2>&1
assert_eq "A token count that is not a number leaves a valid context ledger and no temp file" \
  "$(jq -r '.agents.dev | "\(.role):\(.used_tokens)"' "$JOB/context-ledger.json" 2>/dev/null):$(ls -A "$JOB" | tr '\n' ' ')" \
  "dev:0:context-ledger.json "

JOB="$TMPROOT/job-cap"
for _ in 1 2 3; do
  afk_roster_record_and_check_context "$JOB" dev 170000 200000 >/dev/null 2>&1
done
afk_roster_record_and_check_context "$JOB" dev "n/a" 200000 >/dev/null 2>&1
CAP_OUT="$(afk_roster_record_and_check_context "$JOB" dev 170000 200000 2>/dev/null)"
assert_eq "The replacement cap still trips after a token count that is not a number" \
  "$(jq -r '"\(.action):\(.replacements)"' <<<"$CAP_OUT" 2>/dev/null)" \
  "replacement_cap_reached:3"

JOB="$TMPROOT/job-window"
WINDOW_OUT="$(afk_roster_record_and_check_context "$JOB" dev 100000 0 2>/dev/null)"
assert_eq "A zero window is recorded as the default window it was evaluated against" \
  "$(jq -r '.window_tokens' <<<"$WINDOW_OUT" 2>/dev/null):$(jq -r '.agents.dev.window_tokens' "$JOB/context-ledger.json" 2>/dev/null)" \
  "200000:200000"

JOB="$TMPROOT/job-damaged"
mkdir -p "$JOB"
printf '\n' > "$JOB/context-ledger.json"
afk_roster_record_and_check_context "$JOB" dev 1000 200000 >/dev/null 2>&1
assert_eq "An empty context ledger file is rebuilt by the next record" \
  "$(jq -r '.agents.dev.used_tokens' "$JOB/context-ledger.json" 2>/dev/null)" \
  "1000"

JOB="$TMPROOT/job-octal"
afk_roster_record_and_check_context "$JOB" dev 08 0200000 >/dev/null 2>&1
assert_eq "Token counts written with a leading zero are read as decimal" \
  "$(jq -r '.agents.dev | "\(.used_tokens):\(.window_tokens)"' "$JOB/context-ledger.json" 2>/dev/null)" \
  "8:200000"

# ============================================================================
head1 "8. Roles chosen from the intake agent's surface list"
# ============================================================================

assert_eq "Surfaces in mixed case with spaces staff the architect and the UX designer" \
  "$(afk_roster_roles_for_job low "code, UI, Security")" \
  "pm,dev,reviewer,approver,architect,ux-designer"
# shellcheck disable=SC2016
assert_eq "Surfaces wrapped in backticks or asterisks staff the analyst, the architect and the UX designer" \
  "$(afk_roster_roles_for_job low '`Research`, **Architecture**, *Frontend*')" \
  "pm,dev,reviewer,approver,analyst,architect,ux-designer"

# ---------------------------------------------------------------- review fixes
reset_state
mkdir -p "$(dirname "$LEDGER")"; printf 'not a ledger' > "$(dirname "$LEDGER")/hired-agents.json.lock"
T0=$SECONDS
afk_pch_update_ledger '.x = 1' >/dev/null 2>&1; LRC=$?
assert_eq "A lock path that can never be a lock fails the write at once instead of waiting it out" \
  "$LRC:$(( SECONDS - T0 < 10 ))" "1:1"
rm -f "$(dirname "$LEDGER")/hired-agents.json.lock"

reset_state
mkdir -p "$(dirname "$LEDGER")"
printf '{"schema":"afk-hired-agents/1","projects":{"alpha":{"agents":{}},"beta":{"agents":{}}}' > "$LEDGER"   # cut off
afk_pch_update_ledger '.projects.gamma = {agents:{}}' >/dev/null 2>&1
assert_eq "A ledger that cannot be read is set aside before a write, not silently replaced" \
  "$(find "$(dirname "$LEDGER")" -maxdepth 1 -name 'hired-agents.json.corrupt.*' | wc -l | tr -d ' '):$(jq -r '.projects | keys | join(",")' "$LEDGER")" "1:gamma"

reset_state
OLD_PENDING='{"schema":"afk-hired-agents/1","projects":{"p":{"agents":{"pm":{"agent_id":"local-p-pm","status":"pending","pending_since":"2020-01-01T00:00:00Z"},"dev":{"agent_id":"local-p-dev","status":"pending","pending_since":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}}}}}'
assert_eq "A pending hire expires after six hours; a recent one still counts" \
  "[$(_afk_pch_live_pending "$OLD_PENDING" p pm)]:$([[ -n "$(_afk_pch_live_pending "$OLD_PENDING" p dev)" ]] && printf live || printf gone)" "[]:live"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
