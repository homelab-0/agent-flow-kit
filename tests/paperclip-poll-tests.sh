#!/usr/bin/env bash
# paperclip-poll-tests.sh — the isolated deterministic gate for
# `agent-flow-kit paperclip-poll` (lib/afk-paperclip.sh).
#
# No network: op and curl are stubs on PATH, following the pattern in
# tests/auto-update-enroll-tests.sh. The curl stub serves fixture JSON by
# method and path and logs argv (never the key) and request bodies.
#
# Usage: tests/paperclip-poll-tests.sh
# Exit:  0 all passed, 1 any failure.

set -uo pipefail

KIT_ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
AFK="$KIT_ROOT/bin/agent-flow-kit"
TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT

PASS=0 FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; FAIL=$((FAIL + 1)); }
head1() { printf '\n\033[1m%s\033[0m\n' "$1"; }
assert_eq()       { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing substring: $3 in: $2"; fi; }
assert_absent()   { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "should NOT contain: $3"; fi; }
assert_missing()  { if [[ -e "$2" ]]; then bad "$1" "exists: $2"; else ok "$1"; fi; }

STUBS="$TMPROOT/stubs"; mkdir -p "$STUBS"

cat >"$STUBS/op" <<'SH'
#!/usr/bin/env bash
[[ "$1" == read ]] || exit 2
case "$2" in
  op://test/agent1) printf 'KEY-AGENT1-SECRET-VALUE\n' ;;
  op://test/agent2) printf 'KEY-AGENT2-SECRET-VALUE\n' ;;
  *) exit 1 ;;
esac
SH

cat >"$STUBS/curl" <<'SH'
#!/usr/bin/env bash
method="GET"
n=$#
args=("$@")
for ((i = 0; i < n; i++)); do
  [[ "${args[$i]}" == -X ]] && method="${args[$((i + 1))]}"
done
url="${args[$((n - 1))]}"
tmp="${url#*://}"
path="/${tmp#*/}"
printf '%s %s\n' "$method" "$path" >>"$CURL_STUB_LOG"
printf '%s\n' "$*" >>"$CURL_STUB_LOG.argv" # the full argv, as ps would show it
# curl reads a header/body from a file with the `@<path>` syntax (afk_pc_curl
# passes `-H @<(...)` / `--data-binary @<(...)`), so the argument to match is
# `@/dev/fd/N`, not `/dev/fd/N` bare.
for ((i = 0; i < n; i++)); do
  if [[ "${args[$i]}" == -H && "${args[$((i + 1))]}" == @/dev/fd/* ]]; then
    hv="$(cat "${args[$((i + 1))]#@}" 2>/dev/null)"
    case "$hv" in
      Authorization:*) printf '%s\n' "${hv#Authorization: Bearer }" >>"$CURL_STUB_KEYLOG" ;;
    esac
  fi
  if [[ "${args[$i]}" == --data-binary && "${args[$((i + 1))]}" == @/dev/fd/* ]]; then
    cat "${args[$((i + 1))]#@}" >>"$CURL_STUB_BODYLOG"
    printf '\n---\n' >>"$CURL_STUB_BODYLOG"
  fi
done
key="${method}_${path#/}"; key="${key//\//_}"
f="$CURL_STUB_FIXTURES/$key"
# route_nth: a per-route call counter picks "<key>.<n>" for the n-th call.
cnt="$(( $(cat "$CURL_STUB_FIXTURES/.n_$key" 2>/dev/null || printf 0) + 1 ))"
printf '%s' "$cnt" >"$CURL_STUB_FIXTURES/.n_$key"
[[ -f "$f.$cnt" ]] && f="$f.$cnt"
[[ -f "$f" ]] || f="$CURL_STUB_FIXTURES/DEFAULT"
if [[ ! -f "$f" ]]; then printf '000'; exit 0; fi
code="$(head -1 "$f")"
[[ "$code" == NETFAIL ]] && exit 7
tail -n +2 "$f"
printf '%s' "$code"
SH
chmod +x "$STUBS"/*

# route <method> <path> <code> [<body>] — install one fixture response.
route() {
  local key="${1}_${2#/}"; key="${key//\//_}"
  { printf '%s\n' "$3"; [[ -n "${4:-}" ]] && printf '%s\n' "$4"; } >"$FIXDIR/$key"
}

# route_nth <method> <path> <n> <code> [<body>] — override only the n-th call.
route_nth() {
  local key="${1}_${2#/}"; key="${key//\//_}"
  { printf '%s\n' "$4"; [[ -n "${5:-}" ]] && printf '%s\n' "$5"; } >"$FIXDIR/$key.$3"
}

# new_scenario <name> — fresh HOME, fixtures and logs; sets CONFIG, LOG, etc.
new_scenario() {
  SCEN="$TMPROOT/$1"; mkdir -p "$SCEN"
  HOME="$SCEN/home"; mkdir -p "$HOME"
  STATE="$HOME/.local/state/agent-flow-kit"
  FIXDIR="$SCEN/fixtures"; mkdir -p "$FIXDIR"
  CONFIG="$SCEN/paperclip.json"
  LOG="$SCEN/curl.log"; KEYLOG="$SCEN/curl.keys"; BODYLOG="$SCEN/curl.bodies"
  : >"$LOG"; : >"$KEYLOG"; : >"$BODYLOG"
}

RC=0 OUT_TEXT=""
run_afk() { # [--json]
  local out err
  local -a extra=()
  [[ -n "${1:-}" ]] && extra=("$1")
  out="$(env -i PATH="$STUBS:$PATH" HOME="$HOME" LANG=C \
    AFK_STATE_DIR="$STATE" AFK_PAPERCLIP_CONFIG="$CONFIG" \
    AFK_OP_BIN="$STUBS/op" AFK_CURL_BIN="$STUBS/curl" \
    CURL_STUB_LOG="$LOG" CURL_STUB_KEYLOG="$KEYLOG" CURL_STUB_BODYLOG="$BODYLOG" CURL_STUB_FIXTURES="$FIXDIR" \
    bash ${AFK_XTRACE:+-x} "$AFK" paperclip-poll "${extra[@]}" 2>"$SCEN/err")"
  RC=$?
  err="$(cat "$SCEN/err")"
  OUT_TEXT="$out"$'\n'"$err"
}

COMPANY="cccccccc-cccc-cccc-cccc-cccccccccccc"
BOARD="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
AGENT1="11111111-1111-1111-1111-111111111111"
AGENT2="22222222-2222-2222-2222-222222222222"
MAINT="dddddddd-dddd-dddd-dddd-dddddddddddd"
STRANGER="99999999-9999-9999-9999-999999999999"

write_config() { # <agents-json>
  jq -n --arg api "https://paperclip.test" --arg co "$COMPANY" --arg bu "$BOARD" \
    --arg hl "test-host" --argjson agents "$1" \
    '{api_url: $api, company_id: $co, board_user_id: $bu, host_label: $hl, agents: $agents}' \
    >"$CONFIG"
}

write_config_maint() { # <agents-json> <maint-id>
  jq -n --arg api "https://paperclip.test" --arg co "$COMPANY" --arg bu "$BOARD" \
    --arg hl "test-host" --arg mi "$2" --argjson agents "$1" \
    '{api_url: $api, company_id: $co, board_user_id: $bu, host_label: $hl, maintenance_issue_id: $mi, agents: $agents}' \
    >"$CONFIG"
}

agent_json() { # <agent_id> <key_ref> <project> <repo> [max_active]
  jq -nc --arg a "$1" --arg k "$2" --arg p "$3" --arg r "$4" --argjson m "${5:-1}" \
    '{agent_id:$a, key_ref:$k, project:$p, repo_path:$r, harness:"claude", max_active_issues:$m}'
}

# ============================================================================
head1 "0. bash -n"
# ============================================================================
if bash -n "$KIT_ROOT/lib/afk-paperclip.sh"; then ok "bash -n lib/afk-paperclip.sh"
else bad "bash -n lib/afk-paperclip.sh"; fi

# ============================================================================
head1 "1. Config (AC-1)"
# ============================================================================
new_scenario cfg_missing
run_afk
assert_eq "missing config: non-zero exit" "$RC" "1"
assert_eq "missing config: no request made" "$(cat "$LOG" 2>/dev/null)" ""
assert_contains "missing config: reason" "$OUT_TEXT" "PAPERCLIP_NOT_CONFIGURED"

new_scenario cfg_bad_uuid
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo)" '[$a]')"
jq '.company_id = "not-a-uuid"' "$CONFIG" >"$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
run_afk
assert_eq "bad company_id: non-zero exit" "$RC" "1"
assert_eq "bad company_id: no request made" "$(cat "$LOG" 2>/dev/null)" ""
assert_contains "bad company_id: reason" "$OUT_TEXT" "PAPERCLIP_ID_INVALID"

new_scenario cfg_board_literal
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo)" '[$a]')"
jq '.board_user_id = "board"' "$CONFIG" >"$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
run_afk
assert_contains "board_user_id 'board' refused" "$OUT_TEXT" "PAPERCLIP_ID_INVALID"

new_scenario cfg_duplicate
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo)" '[$a, $a]')"
run_afk
assert_contains "duplicate agent_id refused" "$OUT_TEXT" "PAPERCLIP_CONFIG_INVALID"

new_scenario cfg_http_url
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo)" '[$a]')"
jq '.api_url = "http://paperclip.test"' "$CONFIG" >"$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
run_afk
assert_eq "non-https api_url: non-zero exit" "$RC" "1"
assert_eq "non-https api_url: no request made" "$(cat "$LOG" 2>/dev/null)" ""
assert_contains "non-https api_url refused" "$OUT_TEXT" "PAPERCLIP_CONFIG_INVALID"

# ============================================================================
head1 "2. Key handling (AC-2)"
# ============================================================================
new_scenario key_unreadable
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/badref proj /repo)" '[$a]')"
run_afk --json
assert_contains "unreadable key -> PAPERCLIP_VAULT_UNAVAILABLE" "$OUT_TEXT" "PAPERCLIP_VAULT_UNAVAILABLE"
assert_eq "unreadable key: no HTTP call for that agent" "$(cat "$LOG" 2>/dev/null)" ""

new_scenario key_mismatch
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo)" '[$a]')"
route GET /api/agents/me 200 '{"id":"22222222-2222-2222-2222-222222222222"}'
run_afk --json
assert_contains "agent/key mismatch reason" "$OUT_TEXT" "PAPERCLIP_KEY_AGENT_MISMATCH"

new_scenario key_ambiguous_me
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo)" '[$a]')"
route GET /api/agents/me 503 ''
run_afk --json
assert_contains "ambiguous /me -> unreachable, never a credential refusal" "$OUT_TEXT" "unreachable"
assert_absent "ambiguous /me is never reported as a credential refusal" "$OUT_TEXT" "MISMATCH"

new_scenario key_never_logged
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET /api/agents/me/inbox-lite 200 '[]'
run_afk --json
assert_absent "the key never appears in the request log" "$(cat "$LOG")" "KEY-AGENT1-SECRET-VALUE"
assert_absent "the key never appears in stdout/stderr" "$OUT_TEXT" "KEY-AGENT1-SECRET-VALUE"
assert_absent "the key never appears in the ledger" "$(cat "$STATE/paperclip/ledger.json" 2>/dev/null)" "KEY-AGENT1-SECRET-VALUE"
assert_contains "the key WAS actually sent (control on the assertion above)" "$(cat "$KEYLOG")" "KEY-AGENT1-SECRET-VALUE"

# Same, through a full adoption (argv, notices, brief) and under `bash -x`.
new_scenario key_never_logged_xtrace
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET /api/agents/me/inbox-lite 200 '[{"id":"e1111111-1111-1111-1111-111111111111"}]'
route GET /api/issues/e1111111-1111-1111-1111-111111111111 200 \
  '{"status":"in_progress","identifier":"PROJ-1","title":"T","description":"D","updatedAt":"2026-01-01T00:00:00Z"}'
route GET /api/issues/e1111111-1111-1111-1111-111111111111/active-run 200 '{"id":"run-1"}'
route POST /api/issues/e1111111-1111-1111-1111-111111111111/comments 201 '{}'
route PATCH /api/issues/e1111111-1111-1111-1111-111111111111 200 '{}'
AFK_XTRACE=1 run_afk --json
assert_contains "xtrace: the pass really ran (control)" "$(cat "$STATE"/paperclip/notices/proj/*.claimed.json 2>/dev/null)" "claimed"
assert_absent "the key never appears in any curl argv" "$(cat "$LOG.argv")" "KEY-AGENT1-SECRET-VALUE"
assert_absent "the key never appears under bash -x" "$OUT_TEXT" "KEY-AGENT1-SECRET-VALUE"
assert_eq "the key never appears in any state file" "$(grep -rl KEY-AGENT1-SECRET-VALUE "$STATE" 2>/dev/null)" ""

# ============================================================================
head1 "3. Lock (AC-3)"
# ============================================================================
new_scenario lock_busy
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo)" '[$a]')"
mkdir -p "$STATE/paperclip/.lock"
run_afk
assert_eq "lock held: exit 0 (busy is not a failure)" "$RC" "0"
assert_contains "lock held: reason" "$OUT_TEXT" "PAPERCLIP_POLL_BUSY"
assert_eq "lock held: no request made" "$(cat "$LOG" 2>/dev/null)" ""

new_scenario lock_quote_path
STATE="$SCEN/ho'me/.local/state/agent-flow-kit"; mkdir -p "$STATE"
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET "/api/agents/me/inbox-lite" 200 '[]'
run_afk --json
assert_eq "a single quote in the state path does not break the pass" "$RC" "0"
assert_missing "the lock dir is released even with a quote in its path" "$STATE/paperclip/.lock"

# ============================================================================
head1 "4. Fresh adoption, capacity and re-adoption (AC-5a)"
# ============================================================================
ISSUE1="e1111111-1111-1111-1111-111111111111"
ISSUE2="e2222222-2222-2222-2222-222222222222"

new_scenario fresh_adopt
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"in_progress\",\"identifier\":\"PROJ-1\",\"title\":\"T\",\"description\":\"D\",\"updatedAt\":\"2026-01-01T00:00:00Z\"}"
route GET "/api/issues/$ISSUE1/active-run" 200 '{"id":"run-1"}'
route POST "/api/issues/$ISSUE1/comments" 201 '{}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
run_afk --json
assert_eq "fresh adoption: exit 0" "$RC" "0"
assert_eq "fresh adoption: exactly one claim comment" "$(grep -c 'claimed by AFK PM' "$BODYLOG")" "1"
assert_eq "fresh adoption: exactly one self-block PATCH" "$(grep -c "^PATCH /api/issues/$ISSUE1$" "$LOG")" "1"
NOTICE_DIR="$STATE/paperclip/notices/proj"
assert_eq "fresh adoption: one claimed notice" "$(find "$NOTICE_DIR" -name '*.claimed.json' 2>/dev/null | wc -l | tr -d ' ')" "1"
assert_eq "fresh adoption: one brief" "$(find "$NOTICE_DIR" -name 'brief.*' 2>/dev/null | wc -l | tr -d ' ')" "1"
assert_contains "brief has no Paperclip-only leak beyond title/description" "$(cat "$NOTICE_DIR"/brief.* 2>/dev/null)" "D"

new_scenario brief_no_digits_in_updated_at
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"in_progress\",\"identifier\":\"PROJ-1\",\"title\":\"T\",\"description\":\"D\",\"updatedAt\":\"unknown\"}"
route GET "/api/issues/$ISSUE1/active-run" 200 '{"id":"run-1"}'
route POST "/api/issues/$ISSUE1/comments" 201 '{}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
run_afk --json
NOTICE_DIR="$STATE/paperclip/notices/proj"
assert_missing "an updatedAt with no digits never writes brief.<id>..md" "$NOTICE_DIR/brief.$ISSUE1..md"
assert_eq "an updatedAt with no digits still writes exactly one brief" \
  "$(find "$NOTICE_DIR" -name 'brief.*' 2>/dev/null | wc -l | tr -d ' ')" "1"

# Re-adopt: same issue reappears in_progress with a run this poller never
# requested (an unrequested run). No second comment.
run_afk --json
assert_eq "re-adopt: still exactly one claim comment total" "$(grep -c 'claimed by AFK PM' "$BODYLOG")" "1"
assert_eq "re-adopt: a second self-block PATCH was sent" "$(grep -c "^PATCH /api/issues/$ISSUE1$" "$LOG")" "2"

# Second issue, same agent, max_active_issues=1 -> queued.
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"},{\"id\":\"$ISSUE2\"}]"
route GET "/api/issues/$ISSUE2" 200 \
  "{\"status\":\"in_progress\",\"identifier\":\"PROJ-2\",\"title\":\"T2\",\"description\":\"D2\",\"updatedAt\":\"2026-01-01T00:00:00Z\"}"
route GET "/api/issues/$ISSUE2/active-run" 200 '{"id":"run-2"}'
route POST "/api/issues/$ISSUE2/comments" 201 '{}'
run_afk --json
LEDGER="$STATE/paperclip/ledger.json"
assert_eq "capacity: second issue is queued" "$(jq -r --arg id "$ISSUE2" '.issues[$id].state' "$LEDGER")" "queued"
assert_contains "capacity: queued action names the working issue" \
  "$(jq -r --arg id "$ISSUE2" '.issues[$id].action_text' "$LEDGER")" "PROJ-1"
assert_eq "capacity: first issue stays working" "$(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$LEDGER")" "working"

# ============================================================================
head1 "5. Promotion and the Josh test (AC-5b, AC-8)"
# ============================================================================
new_scenario promote_and_josh
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
mkdir -p "$STATE/paperclip"
jq -n --arg a "$AGENT1" --arg id "$ISSUE1" \
  '{issues: {($id): {agent_id: $a, project: "proj", identifier: "PROJ-1", state: "working", since: "2026-01-01T00:00:00Z", action_text: "AFK host is working on this"}},
    stranded_reported: [], drain_tampered_reported: false, last_successful_pass: null}' \
  >"$STATE/paperclip/ledger.json"
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"blocked\",\"identifier\":\"PROJ-1\",\"unblockDescriptor\":{\"owner\":{\"agentId\":\"$AGENT1\"},\"action\":\"AFK host is working on this\"}}"
route GET "/api/issues/$ISSUE1/comments" 200 \
  "[{\"id\":\"c0000000-0000-0000-0000-00000000000a\",\"body\":\"go ahead\",\"authorUserId\":\"$BOARD\",\"authorAgentId\":null,\"createdAt\":\"2026-02-01T00:00:00Z\"},
    {\"id\":\"c0000000-0000-0000-0000-00000000000b\",\"body\":\"x\",\"authorUserId\":\"$BOARD\",\"authorAgentId\":\"$AGENT2\",\"createdAt\":\"2026-02-01T00:00:01Z\"},
    {\"id\":\"c0000000-0000-0000-0000-00000000000c\",\"body\":\"y\",\"authorUserId\":\"$BOARD\",\"createdAt\":\"2026-02-01T00:00:02Z\"}]"
run_afk --json
NOTICE_DIR="$STATE/paperclip/notices/proj"
assert_eq "Josh comment -> exactly one human_commented notice" \
  "$(find "$NOTICE_DIR" -name '*.human_commented.json' 2>/dev/null | wc -l | tr -d ' ')" "1"
assert_eq "Josh comment -> the reply file carries the comment body" \
  "$(cat "$NOTICE_DIR/reply.c0000000-0000-0000-0000-00000000000a.md" 2>/dev/null)" "go ahead"
assert_missing "an agent-authored comment with Josh's userId writes no notice" "$NOTICE_DIR/reply.c0000000-0000-0000-0000-00000000000b.md"
assert_missing "a missing authorAgentId key writes no notice" "$NOTICE_DIR/reply.c0000000-0000-0000-0000-00000000000c.md"
assert_contains "a missing authorAgentId key reports unverifiable" "$OUT_TEXT" "PAPERCLIP_AUTHOR_UNVERIFIABLE"

# ============================================================================
head1 "6. held_by_board and stranding (AC-5b2, AC-5c)"
# ============================================================================
new_scenario board_hold
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
mkdir -p "$STATE/paperclip"
jq -n --arg a "$AGENT1" --arg id "$ISSUE1" \
  '{issues: {($id): {agent_id: $a, project: "proj", identifier: "PROJ-1", state: "working", since: "2026-01-01T00:00:00Z", action_text: "AFK host is working on this"}},
    stranded_reported: [], drain_tampered_reported: false, last_successful_pass: null}' \
  >"$STATE/paperclip/ledger.json"
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"blocked\",\"identifier\":\"PROJ-1\",\"unblockDescriptor\":{\"owner\":{\"userId\":\"$BOARD\"},\"action\":\"waiting\"}}"
run_afk --json
LEDGER="$STATE/paperclip/ledger.json"
assert_eq "board hold -> held_by_board" "$(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$LEDGER")" "held_by_board"
assert_eq "board hold creates no recovery issue" "$(grep -c "^POST /api/companies/" "$LOG")" "0"

new_scenario stranded
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
mkdir -p "$STATE/paperclip"
jq -n --arg a "$AGENT1" --arg id "$ISSUE1" \
  '{issues: {($id): {agent_id: $a, project: "proj", identifier: "PROJ-1", state: "working", since: "2026-01-01T00:00:00Z", action_text: "AFK host is working on this"}},
    stranded_reported: [], drain_tampered_reported: false, last_successful_pass: null}' \
  >"$STATE/paperclip/ledger.json"
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"blocked\",\"identifier\":\"PROJ-1\",\"unblockDescriptor\":{\"owner\":{\"agentId\":\"$STRANGER\"},\"action\":\"x\"}}"
route POST "/api/companies/$COMPANY/issues" 201 '{"id":"f0000000-0000-0000-0000-000000000001"}'
run_afk --json
LEDGER="$STATE/paperclip/ledger.json"
assert_eq "stranded issue: state" "$(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$LEDGER")" "stranded"
assert_eq "stranded issue: exactly one out-of-band issue" "$(grep -c "^POST /api/companies/$COMPANY/issues$" "$LOG")" "1"
assert_eq "stranded issue: recovery issue id recorded" "$(jq -r --arg id "$ISSUE1" '.issues[$id].recovery_issue_id' "$LEDGER")" "f0000000-0000-0000-0000-000000000001"
assert_contains "the out-of-band issue body carries the idempotencyKey" "$(cat "$BODYLOG")" "\"idempotencyKey\":\"afk-recovery-$ISSUE1\""

# stranded twice: still blocked by the stranger on the next pass -> no 2nd issue.
run_afk --json
assert_eq "stranded twice: still exactly one out-of-band issue" "$(grep -c "^POST /api/companies/$COMPANY/issues$" "$LOG")" "1"

# re-adopted: back to in_progress -> recovery issue set to done in the same pass.
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"in_progress\",\"identifier\":\"PROJ-1\",\"title\":\"T\",\"description\":\"D\",\"updatedAt\":\"2026-01-01T00:00:00Z\"}"
route GET "/api/issues/$ISSUE1/active-run" 200 '{"id":"run-1"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
route PATCH "/api/issues/f0000000-0000-0000-0000-000000000001" 200 '{}'
run_afk --json
assert_eq "re-adopted stranded issue: recovery issue set to done" "$(grep -c "^PATCH /api/issues/f0000000-0000-0000-0000-000000000001$" "$LOG")" "1"
assert_eq "re-adopted stranded issue: back to working" "$(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$STATE/paperclip/ledger.json")" "working"

# A failed create is not "reported": the next pass retries under the same key.
new_scenario stranded_create_fails
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
mkdir -p "$STATE/paperclip"
jq -n --arg a "$AGENT1" --arg id "$ISSUE1" \
  '{issues: {($id): {agent_id: $a, project: "proj", identifier: "PROJ-1", state: "working", since: "x", action_text: "y"}},
    stranded_reported: [], drain_tampered_reported: false, last_successful_pass: null}' >"$STATE/paperclip/ledger.json"
route GET /api/agents/me/inbox-lite 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 "{\"status\":\"blocked\",\"identifier\":\"PROJ-1\",\"unblockDescriptor\":{\"owner\":{\"agentId\":\"$STRANGER\"}}}"
route POST "/api/companies/$COMPANY/issues" NETFAIL
run_afk --json
assert_eq "failed recovery create: not marked reported" "$(jq -c '.stranded_reported' "$STATE/paperclip/ledger.json")" "[]"
route POST "/api/companies/$COMPANY/issues" 200 '{"id":"f0000000-0000-0000-0000-000000000009"}'
run_afk --json
assert_eq "failed recovery create: retried and reported on the next pass" "$(jq -r '.stranded_reported | length' "$STATE/paperclip/ledger.json")" "1"

# ============================================================================
head1 "7. Closed issues (AC-5d)"
# ============================================================================
new_scenario closed
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
mkdir -p "$STATE/paperclip"
jq -n --arg a "$AGENT1" --arg id "$ISSUE1" \
  '{issues: {($id): {agent_id: $a, project: "proj", identifier: "PROJ-1", state: "working", since: "2026-01-01T00:00:00Z", action_text: "AFK host is working on this"}},
    stranded_reported: [], drain_tampered_reported: false, last_successful_pass: null}' \
  >"$STATE/paperclip/ledger.json"
route GET "/api/agents/me/inbox-lite" 200 '[]'
run_afk --json
assert_eq "closed: ledger state" "$(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$STATE/paperclip/ledger.json")" "closed"
assert_eq "closed: one stopped notice" \
  "$(find "$STATE/paperclip/notices/proj" -name '*.stopped.json' 2>/dev/null | wc -l | tr -d ' ')" "1"

new_scenario close_and_new_same_pass
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
mkdir -p "$STATE/paperclip"
jq -n --arg a "$AGENT1" --arg id "$ISSUE1" \
  '{issues: {($id): {agent_id: $a, project: "proj", identifier: "PROJ-1", state: "working", since: "2026-01-01T00:00:00Z", action_text: "AFK host is working on this"}},
    stranded_reported: [], drain_tampered_reported: false, last_successful_pass: null}' \
  >"$STATE/paperclip/ledger.json"
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"},{\"id\":\"$ISSUE2\"}]"
route GET "/api/issues/$ISSUE1" 200 '{"status":"done","identifier":"PROJ-1"}'
route GET "/api/issues/$ISSUE2" 200 \
  "{\"status\":\"in_progress\",\"identifier\":\"PROJ-2\",\"title\":\"T2\",\"description\":\"D2\",\"updatedAt\":\"2026-01-01T00:00:00Z\"}"
route GET "/api/issues/$ISSUE2/active-run" 200 '{"id":"run-2"}'
route POST "/api/issues/$ISSUE2/comments" 201 '{}'
route PATCH "/api/issues/$ISSUE2" 200 '{}'
run_afk --json
LEDGER="$STATE/paperclip/ledger.json"
assert_eq "same-pass close: issue1 is closed" "$(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$LEDGER")" "closed"
assert_eq "same-pass close frees the slot: the new issue is working, not queued" \
  "$(jq -r --arg id "$ISSUE2" '.issues[$id].state' "$LEDGER")" "working"

new_scenario orphan_self_block
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"blocked\",\"identifier\":\"PROJ-1\",\"unblockDescriptor\":{\"owner\":{\"agentId\":\"$AGENT1\"},\"action\":\"stale\"}}"
route GET "/api/issues/$ISSUE1/comments" 200 '[]'
run_afk --json
LEDGER="$STATE/paperclip/ledger.json"
assert_eq "an orphaned self-block with no prior ledger entry creates none" \
  "$(jq -r --arg id "$ISSUE1" '.issues[$id] // "MISSING"' "$LEDGER")" "MISSING"

# ============================================================================
head1 "8. Stop flag and drain (AC-9)"
# ============================================================================
new_scenario stop_flag
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
mkdir -p "$HOME/.config/agent-flow-kit/paperclip"; : >"$HOME/.config/agent-flow-kit/paperclip/stop"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"in_progress\",\"identifier\":\"PROJ-1\",\"title\":\"T\",\"description\":\"D\",\"updatedAt\":\"2026-01-01T00:00:00Z\"}"
route GET "/api/issues/$ISSUE1/active-run" 200 '{"id":"run-1"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
run_afk --json
assert_contains "stop flag -> pass reports paused" "$OUT_TEXT" "PAPERCLIP_PAUSED"
assert_eq "stop flag: unrequested run is re-blocked with no comment" "$(grep -c 'claimed by AFK PM' "$BODYLOG")" "0"
assert_eq "stop flag: self-block sent" "$(grep -c "^PATCH /api/issues/$ISSUE1$" "$LOG")" "1"
assert_contains "stop flag: action text is Stopped" "$(cat "$BODYLOG")" "Stopped"
assert_eq "stop flag: no comment of any kind" "$(grep -c "^POST /api/issues/$ISSUE1/comments$" "$LOG")" "0"

new_scenario drain_unreadable
write_config_maint "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')" "$MAINT"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET "/api/issues/$MAINT" NETFAIL
route GET "/api/agents/me/inbox-lite" 200 '[]'
run_afk --json
assert_contains "drain unreadable -> paused" "$OUT_TEXT" "PAPERCLIP_PAUSED"

new_scenario drain_tampered
write_config_maint "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')" "$MAINT"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET "/api/issues/$MAINT" 200 \
  "{\"status\":\"in_progress\",\"assigneeUserId\":\"$AGENT2\",\"assigneeAgentId\":null}"
route POST "/api/companies/$COMPANY/issues" 201 '{"id":"tamper-report"}'
route GET "/api/agents/me/inbox-lite" 200 '[]'
run_afk --json
assert_eq "tampered drain: not treated as paused" "$(grep -c PAPERCLIP_PAUSED <<<"$OUT_TEXT")" "0"
assert_eq "tampered drain: exactly one out-of-band report" "$(grep -c "^POST /api/companies/$COMPANY/issues$" "$LOG")" "1"
run_afk --json
assert_eq "tampered drain reported only once across passes" "$(grep -c "^POST /api/companies/$COMPANY/issues$" "$LOG")" "1"

# ============================================================================
head1 "9. Two agents: one fails, the other still runs (AC-2)"
# ============================================================================
new_scenario two_agents
write_config "$(jq -nc \
  --argjson a1 "$(agent_json "$AGENT1" op://test/badref proj1 /repo1)" \
  --argjson a2 "$(agent_json "$AGENT2" op://test/agent2 proj2 /repo2)" \
  '[$a1, $a2]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT2\"}"
route GET "/api/agents/me/inbox-lite" 200 '[]'
run_afk --json
assert_contains "agent1 vault-unavailable reported" "$OUT_TEXT" "PAPERCLIP_VAULT_UNAVAILABLE"
assert_eq "agent2 still completed and the ledger was written" "$RC" "0"
assert_contains "agent2's key was used" "$(cat "$KEYLOG")" "KEY-AGENT2-SECRET-VALUE"

# ============================================================================
head1 "10. Unreachable pass (AC-3)"
# ============================================================================
new_scenario unreachable
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo)" '[$a]')"
route GET /api/agents/me NETFAIL
run_afk --json
assert_eq "unreachable: non-zero exit" "$RC" "1"
assert_missing "unreachable: ledger was not written" "$STATE/paperclip/ledger.json"

# ============================================================================
head1 "11. Paperclip-initiated wakes (AC-5a amendment)"
# ============================================================================
wake_scenario() { # <name> <wake-reason-json-or-empty>
  new_scenario "$1"
  write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
  route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
  mkdir -p "$STATE/paperclip"
  jq -n --arg a "$AGENT1" --arg id "$ISSUE1" \
    '{issues: {($id): {agent_id: $a, project: "proj", identifier: "PROJ-1", state: "working", since: "2026-01-01T00:00:00Z", action_text: "AFK host is working on this"}},
      stranded_reported: [], drain_tampered_reported: false, last_successful_pass: null}' \
    >"$STATE/paperclip/ledger.json"
  route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
  route GET "/api/issues/$ISSUE1" 200 \
    "{\"status\":\"in_progress\",\"identifier\":\"PROJ-1\",\"title\":\"T\",\"description\":\"D\",\"updatedAt\":\"2026-01-01T00:00:00Z\"}"
  route GET "/api/issues/$ISSUE1/active-run" 200 "{\"id\":\"run-1\",\"contextSnapshot\":$2}"
  route POST "/api/issues/$ISSUE1/comments" 201 '{}'
  route PATCH "/api/issues/$ISSUE1" 200 '{}'
  run_afk --json
}

wake_scenario wake_other_reason '{"wakeReason":"approval_approved"}'
assert_eq "a wake on a held issue: exactly one acknowledgment comment" \
  "$(grep -c 'AFK host acknowledged' "$BODYLOG")" "1"
assert_contains "the acknowledgment names the wake reason" "$(cat "$BODYLOG")" "approval_approved"
assert_eq "a wake on a held issue: exactly one re-block" "$(grep -c "^PATCH /api/issues/$ISSUE1$" "$LOG")" "1"
assert_absent "a non-issue_blockers_resolved wake carries no blockedByIssueIds" "$(cat "$BODYLOG")" "blockedByIssueIds"

wake_scenario wake_blockers_resolved '{"wakeReason":"issue_blockers_resolved"}'
assert_contains "an issue_blockers_resolved wake: the re-block clears blockedByIssueIds" \
  "$(cat "$BODYLOG")" '"blockedByIssueIds":[]'

mkdir -p "$TMPROOT/wake_paused_blockers/home/.config/agent-flow-kit/paperclip"
: >"$TMPROOT/wake_paused_blockers/home/.config/agent-flow-kit/paperclip/stop"
wake_scenario wake_paused_blockers '{"wakeReason":"issue_blockers_resolved"}'
assert_contains "paused issue_blockers_resolved wake: still clears blockedByIssueIds" "$(cat "$BODYLOG")" '"blockedByIssueIds":[]'
assert_eq "paused wake keeps the ledger state" "$(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$STATE/paperclip/ledger.json")" "working"

new_scenario self_block_fails
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET /api/agents/me/inbox-lite 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 '{"status":"in_progress","identifier":"PROJ-1","title":"T","description":"D","updatedAt":"x"}'
route GET "/api/issues/$ISSUE1/active-run" 200 '{"id":"run-1"}'
route POST "/api/issues/$ISSUE1/comments" 201 '{}'
route PATCH "/api/issues/$ISSUE1" 500 '{}'
run_afk --json
assert_contains "a failed self-block is reported, never silent" "$OUT_TEXT" "PAPERCLIP_SELF_BLOCK_FAILED"

new_scenario no_live_run
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET /api/agents/me/inbox-lite 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 '{"status":"in_progress","identifier":"PROJ-1","title":"T","description":"D","updatedAt":"x"}'
route GET "/api/issues/$ISSUE1/active-run" 200 'null'
run_afk --json
assert_eq "no live run: nothing is written to Paperclip" "$(grep -c -e '^POST' -e '^PATCH' "$LOG")" "0"
assert_missing "no live run: no claimed notice" "$STATE/paperclip/notices/proj"

new_scenario inbox_not_array
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
mkdir -p "$STATE/paperclip"
jq -n --arg a "$AGENT1" --arg id "$ISSUE1" \
  '{issues: {($id): {agent_id: $a, project: "proj", identifier: "PROJ-1", state: "working", since: "x", action_text: "y"}},
    stranded_reported: [], drain_tampered_reported: false, last_successful_pass: null}' >"$STATE/paperclip/ledger.json"
route GET /api/agents/me/inbox-lite 200 '{"error":"unexpected shape"}'
run_afk --json
assert_eq "a non-array inbox never closes ledger issues" "$(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$STATE/paperclip/ledger.json")" "working"
assert_eq "a non-array inbox: non-zero exit, nothing completed" "$RC" "1"

# ============================================================================
head1 "12. Drain: board-actor check on the last status change (AC-9 amendment)"
# ============================================================================
new_scenario drain_agent_actor
write_config_maint "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')" "$MAINT"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET "/api/issues/$MAINT" 200 \
  "{\"status\":\"in_progress\",\"assigneeUserId\":\"$BOARD\",\"assigneeAgentId\":null}"
route GET "/api/issues/$MAINT/activity" 200 \
  "[{\"action\":\"issue.updated\",\"createdAt\":\"2026-01-01T00:00:00Z\",\"actorType\":\"agent\",\"actorId\":\"$AGENT1\",\"details\":{\"changes\":{\"status\":\"in_progress\"}}}]"
route POST "/api/companies/$COMPANY/issues" 201 '{"id":"tamper-report-2"}'
route GET "/api/agents/me/inbox-lite" 200 '[]'
run_afk --json
assert_eq "drain by an agent actor: not treated as paused" "$(grep -c PAPERCLIP_PAUSED <<<"$OUT_TEXT")" "0"
assert_contains "drain by an agent actor: tampered" "$OUT_TEXT" "PAPERCLIP_DRAIN_TAMPERED"

new_scenario drain_board_actor
write_config_maint "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')" "$MAINT"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET "/api/issues/$MAINT" 200 \
  "{\"status\":\"in_progress\",\"assigneeUserId\":\"$BOARD\",\"assigneeAgentId\":null}"
route GET "/api/issues/$MAINT/activity" 200 \
  "[{\"action\":\"issue.updated\",\"createdAt\":\"2026-01-01T00:00:00Z\",\"actorType\":\"user\",\"actorId\":\"$BOARD\",\"details\":{\"changes\":{\"status\":\"in_progress\"}}}]"
route GET "/api/agents/me/inbox-lite" 200 '[]'
run_afk --json
assert_contains "drain by the board actor: paused" "$OUT_TEXT" "PAPERCLIP_PAUSED"
assert_eq "drain by the board actor: no tamper report" "$(grep -c "^POST /api/companies/$COMPANY/issues$" "$LOG")" "0"

# ============================================================================
head1 "13. Board recovery via activeRecoveryAction (AC-5 amendment, prox-ops V2)"
# ============================================================================
# unblockDescriptor is never trusted for stranding: each scenario below
# carries our own stale self-block descriptor (owner.agentId == us), and the
# verdict comes only from activeRecoveryAction on the plain issue detail.
recovery_scenario() { # <name> <activeRecoveryAction-json-or-null> <descriptor-json>
  new_scenario "$1"
  write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
  route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
  mkdir -p "$STATE/paperclip"
  jq -n --arg a "$AGENT1" --arg id "$ISSUE1" \
    '{issues: {($id): {agent_id: $a, project: "proj", identifier: "PROJ-1", state: "working", since: "2026-01-01T00:00:00Z", action_text: "AFK host is working on this"}},
      stranded_reported: [], drain_tampered_reported: false, last_successful_pass: null}' \
    >"$STATE/paperclip/ledger.json"
  route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
  route GET "/api/issues/$ISSUE1" 200 \
    "{\"status\":\"blocked\",\"identifier\":\"PROJ-1\",\"unblockDescriptor\":$3,\"activeRecoveryAction\":$2,\"successfulRunHandoff\":{\"state\":\"stale-should-be-ignored\"}}"
  route POST "/api/companies/$COMPANY/issues" 201 '{"id":"f0000000-0000-0000-0000-000000000002"}'
  route GET "/api/issues/$ISSUE1/comments" 200 '[]'
  run_afk --json
}

STALE_SELF_BLOCK_DESCRIPTOR="{\"owner\":{\"agentId\":\"$AGENT1\"},\"action\":\"AFK host is working on this\"}"
BOARD_DESCRIPTOR="{\"owner\":{\"userId\":\"$BOARD\"},\"action\":\"waiting\"}"

recovery_scenario recovery_active_board \
  '{"status":"active","ownerType":"board","kind":"unrelated_kind","cause":"unrelated_cause"}' \
  "$STALE_SELF_BLOCK_DESCRIPTOR"
assert_eq "an active board recovery strands, even with our own stale self-block descriptor" \
  "$(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$STATE/paperclip/ledger.json")" "stranded"
assert_eq "the recovery strand opens exactly one out-of-band issue" \
  "$(grep -c "^POST /api/companies/$COMPANY/issues$" "$LOG")" "1"
assert_contains "the recovery strand's out-of-band issue carries the idempotencyKey" \
  "$(cat "$BODYLOG")" "\"idempotencyKey\":\"afk-recovery-$ISSUE1\""

recovery_scenario recovery_null_board_descriptor null "$BOARD_DESCRIPTOR"
assert_eq "a null activeRecoveryAction with a board-owned descriptor is held_by_board" \
  "$(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$STATE/paperclip/ledger.json")" "held_by_board"
assert_eq "held_by_board creates no recovery issue" "$(grep -c "^POST /api/companies/$COMPANY/issues$" "$LOG")" "0"

recovery_scenario recovery_inactive_status '{"status":"resolved","ownerType":"board"}' "$STALE_SELF_BLOCK_DESCRIPTOR"
assert_absent "an activeRecoveryAction with a non-active status is never stranded" \
  "$(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$STATE/paperclip/ledger.json")" "stranded"

# ============================================================================
head1 "14. The report cycle (PC-1b AC-1..AC-10)"
# ============================================================================
# seed_working <issue_id> <identifier> <state> [<extra-json>] — a ledger with
# one issue this agent already holds, action_text_applied pre-set so a cycle
# only fires because the test wants it to (a queued spool or a status change).
seed_working() {
  local xtra="${4:-}"; [[ -n "$xtra" ]] || xtra='{}'
  mkdir -p "$STATE/paperclip"
  jq -n --arg a "$AGENT1" --arg id "$1" --arg ident "$2" --arg st "$3" --argjson extra "$xtra" \
    '{issues: {($id): ({agent_id:$a, project:"proj", identifier:$ident, state:$st, since:"2026-01-01T00:00:00Z",
        action_text:"AFK host is working on this", action_text_applied:"AFK host is working on this"} + $extra)},
      stranded_reported: [], drain_tampered_reported: false, last_successful_pass: null}' \
    >"$STATE/paperclip/ledger.json"
}
write_spool() { # <issue_id> <seq> <json>
  local dir="$STATE/paperclip/spool/$1"; mkdir -p "$dir"
  printf '%s' "$3" >"$dir/$2.json"
}
E1="c1111111-1111-1111-1111-111111111111"
E2="c2222222-2222-2222-2222-222222222222"
E3="c3333333-3333-3333-3333-333333333333"

new_scenario cycle_three_entries
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 working
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-cyc"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
route POST "/api/issues/$ISSUE1/comments" 201 '{}'
write_spool "$ISSUE1" 001 "{\"id\":\"$E1\",\"kind\":\"comment\",\"body\":\"one\"}"
write_spool "$ISSUE1" 002 "{\"id\":\"$E2\",\"kind\":\"comment\",\"body\":\"two\"}"
write_spool "$ISSUE1" 003 "{\"id\":\"$E3\",\"kind\":\"comment\",\"body\":\"three\"}"
run_afk --json
assert_eq "3 entries: exactly 3 comments posted" "$(grep -c "^POST /api/issues/$ISSUE1/comments$" "$LOG")" "3"
assert_eq "3 entries: posted in order (first marker before the last)" \
  "$(awk -v a="afk-entry:$E1" -v b="afk-entry:$E3" 'index($0,a){print NR": "a} index($0,b){print NR": "b}' "$BODYLOG" | head -1 | grep -c "$E1")" "1"
assert_eq "3 entries: re-blocked (in_progress + final self-block)" "$(grep -c "^PATCH /api/issues/$ISSUE1$" "$LOG")" "2"
assert_eq "3 entries: spool emptied" "$(find "$STATE/paperclip/spool/$ISSUE1" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" "0"

new_scenario cycle_lock_held_skips
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 working
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-lock"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
route POST "/api/issues/$ISSUE1/comments" 201 '{}'
write_spool "$ISSUE1" 001 "{\"id\":\"$E1\",\"kind\":\"comment\",\"body\":\"held\"}"
# A writer (paperclip-report) still holding .seq.lock: the reader must skip
# this issue's spool for the pass rather than list or delete anything.
mkdir -p "$STATE/paperclip/spool/$ISSUE1/.seq.lock"
run_afk --json
assert_eq "lock held: no comment posted" "$(grep -c "^POST /api/issues/$ISSUE1/comments$" "$LOG")" "0"
assert_eq "lock held: the entry is untouched, not deleted" \
  "$(find "$STATE/paperclip/spool/$ISSUE1" -maxdepth 1 -name '001.json' 2>/dev/null | wc -l | tr -d ' ')" "1"
rmdir "$STATE/paperclip/spool/$ISSUE1/.seq.lock"

new_scenario cycle_final_then_dead
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 working
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-fin"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
route POST "/api/issues/$ISSUE1/comments" 201 '{}'
write_spool "$ISSUE1" 001 "{\"id\":\"$E1\",\"kind\":\"comment\",\"body\":\"one\"}"
write_spool "$ISSUE1" 002 "{\"id\":\"$E2\",\"kind\":\"final\",\"status\":\"done\",\"body\":\"done now\"}"
write_spool "$ISSUE1" 003 "{\"id\":\"$E3\",\"kind\":\"comment\",\"body\":\"too late\"}"
run_afk --json
assert_eq "final: ledger closed" "$(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$STATE/paperclip/ledger.json")" "closed"
assert_missing "final: the final entry itself is gone" "$STATE/paperclip/spool/$ISSUE1/002.json"
assert_eq "final: the later entry moved to dead/" "$(find "$STATE/paperclip/spool/$ISSUE1/dead" -name '003.json' 2>/dev/null | wc -l | tr -d ' ')" "1"

new_scenario cycle_question
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 working
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-q"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
route POST "/api/issues/$ISSUE1/comments" 201 '{}'
write_spool "$ISSUE1" 001 "{\"id\":\"$E1\",\"kind\":\"question\",\"question_id\":\"q7\",\"body\":\"pick a color?\"}"
run_afk --json
assert_eq "question: ledger state waiting_human" "$(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$STATE/paperclip/ledger.json")" "waiting_human"
assert_contains "question: self-block text names the question id" "$(cat "$BODYLOG")" "waiting on q7"

new_scenario cycle_stuck_sending_blocks_final
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 working \
  "{\"sending\":{\"entry_id\":\"$E1\",\"issue_id\":\"$ISSUE1\",\"at\":\"2026-01-01T00:00:00Z\"}}"
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1/comments" 200 '[]'
route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-stuck"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
route POST "/api/issues/$ISSUE1/comments" NETFAIL
write_spool "$ISSUE1" 001 "{\"id\":\"$E1\",\"kind\":\"comment\",\"body\":\"stuck\"}"
write_spool "$ISSUE1" 002 "{\"id\":\"$E2\",\"kind\":\"final\",\"status\":\"done\",\"body\":\"done\"}"
run_afk --json
assert_eq "stuck sending: still not closed" "$(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$STATE/paperclip/ledger.json")" "working"
assert_eq "stuck sending: the final entry was never sent" "$(find "$STATE/paperclip/spool/$ISSUE1" -maxdepth 1 -name '002.json' 2>/dev/null | wc -l | tr -d ' ')" "1"

new_scenario cycle_404_drops_issue
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 working
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-404"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
route POST "/api/issues/$ISSUE1/comments" 404 '{}'
write_spool "$ISSUE1" 001 "{\"id\":\"$E1\",\"kind\":\"comment\",\"body\":\"gone\"}"
run_afk --json
assert_eq "404: the issue is dropped (closed)" "$(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$STATE/paperclip/ledger.json")" "closed"
assert_eq "404: its entry moved to dead/" "$(find "$STATE/paperclip/spool/$ISSUE1/dead" -name '001.json' 2>/dev/null | wc -l | tr -d ' ')" "1"

new_scenario cycle_429_keeps_entry
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 working
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-429"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
route POST "/api/issues/$ISSUE1/comments" 429 '{}'
write_spool "$ISSUE1" 001 "{\"id\":\"$E1\",\"kind\":\"comment\",\"body\":\"slow down\"}"
run_afk --json
assert_eq "429: the entry is kept" "$(find "$STATE/paperclip/spool/$ISSUE1" -maxdepth 1 -name '001.json' 2>/dev/null | wc -l | tr -d ' ')" "1"
assert_contains "429: reported as rate limited" "$OUT_TEXT" "PAPERCLIP_RATE_LIMITED"

new_scenario cycle_500_readback_found
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 working
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-500"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
route POST "/api/issues/$ISSUE1/comments" 500 '{}'
route GET "/api/issues/$ISSUE1/comments" 200 "[{\"authorAgentId\":\"$AGENT1\",\"body\":\"one\\n\\n<!-- afk-entry:$E1 -->\"}]"
write_spool "$ISSUE1" 001 "{\"id\":\"$E1\",\"kind\":\"comment\",\"body\":\"one\"}"
run_afk --json
assert_eq "500 + marker found: counted as sent" \
  "$(find "$STATE/paperclip/spool/$ISSUE1" -maxdepth 1 -name '001.json' 2>/dev/null | wc -l | tr -d ' ')" "0"
assert_eq "500 + marker found: exactly one POST, no duplicate" "$(grep -c "^POST /api/issues/$ISSUE1/comments$" "$LOG")" "1"

new_scenario cycle_500_readback_not_found
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 working
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-500b"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
route POST "/api/issues/$ISSUE1/comments" 500 '{}'
route GET "/api/issues/$ISSUE1/comments" 200 '[]'
write_spool "$ISSUE1" 001 "{\"id\":\"$E1\",\"kind\":\"comment\",\"body\":\"one\"}"
run_afk --json
assert_eq "500 + no marker: the entry stays" "$(find "$STATE/paperclip/spool/$ISSUE1" -maxdepth 1 -name '001.json' 2>/dev/null | wc -l | tr -d ' ')" "1"
# Next pass: Paperclip now accepts it -> exactly one more POST, not two.
route POST "/api/issues/$ISSUE1/comments" 201 '{}'
run_afk --json
assert_eq "500 + no marker: re-posted exactly once on the next pass" "$(grep -c "^POST /api/issues/$ISSUE1/comments$" "$LOG")" "2"
assert_missing "the entry is finally gone" "$STATE/paperclip/spool/$ISSUE1/001.json"

new_scenario cycle_422_dead_rest_continue
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 working
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-fail"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
route POST "/api/issues/$ISSUE1/comments" 422 '{}'
route_nth POST "/api/issues/$ISSUE1/comments" 2 201 '{}'
write_spool "$ISSUE1" 001 "{\"id\":\"$E1\",\"kind\":\"comment\",\"body\":\"bad\"}"
write_spool "$ISSUE1" 002 "{\"id\":\"$E2\",\"kind\":\"comment\",\"body\":\"fine\"}"
run_afk --json
assert_eq "422: entry moved to dead/" "$(find "$STATE/paperclip/spool/$ISSUE1/dead" -name '001.json' 2>/dev/null | wc -l | tr -d ' ')" "1"
assert_missing "422: the next entry still went out" "$STATE/paperclip/spool/$ISSUE1/002.json"
assert_eq "422: still re-blocked (in_progress + self-block)" "$(grep -c "^PATCH /api/issues/$ISSUE1$" "$LOG")" "2"

new_scenario cycle_no_run_leaves_spool
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 working
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route POST "/api/agents/$AGENT1/wakeup" 202 '{}'
write_spool "$ISSUE1" 001 "{\"id\":\"$E1\",\"kind\":\"comment\",\"body\":\"x\"}"
run_afk --json
assert_eq "no run: no PATCH at all" "$(grep -c "^PATCH /api/issues/$ISSUE1$" "$LOG")" "0"
assert_eq "no run: the spool is untouched" "$(find "$STATE/paperclip/spool/$ISSUE1" -maxdepth 1 -name '001.json' 2>/dev/null | wc -l | tr -d ' ')" "1"

new_scenario cycle_403_credential
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 working
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route POST "/api/agents/$AGENT1/wakeup" 403 '{}'
write_spool "$ISSUE1" 001 "{\"id\":\"$E1\",\"kind\":\"comment\",\"body\":\"x\"}"
run_afk --json
assert_contains "403: credential reason" "$OUT_TEXT" "PAPERCLIP_CREDENTIAL_REJECTED"
assert_eq "403: nothing posted" "$(grep -c "^POST /api/issues/$ISSUE1/comments$" "$LOG")" "0"

new_scenario cycle_paused_nothing_touched
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
mkdir -p "$HOME/.config/agent-flow-kit/paperclip"; : >"$HOME/.config/agent-flow-kit/paperclip/stop"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 working
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
write_spool "$ISSUE1" 001 "{\"id\":\"$E1\",\"kind\":\"comment\",\"body\":\"x\"}"
run_afk --json
assert_eq "paused: no wakeup, no post, no delete" "$(grep -c -e '^POST' -e '^PATCH' "$LOG")" "0"
assert_eq "paused: the spool entry is untouched" "$(find "$STATE/paperclip/spool/$ISSUE1" -maxdepth 1 -name '001.json' 2>/dev/null | wc -l | tr -d ' ')" "1"

new_scenario cycle_stranded_held
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 stranded
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
write_spool "$ISSUE1" 001 "{\"id\":\"$E1\",\"kind\":\"comment\",\"body\":\"x\"}"
run_afk --json
assert_eq "stranded: no wakeup for that issue" "$(grep -c "^POST /api/agents/$AGENT1/wakeup$" "$LOG")" "0"
assert_eq "stranded: spool held" "$(find "$STATE/paperclip/spool/$ISSUE1" -maxdepth 1 -name '001.json' 2>/dev/null | wc -l | tr -d ' ')" "1"

new_scenario cycle_junk_ignored
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 working
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
mkdir -p "$STATE/paperclip/spool/$ISSUE1/.tmp"
printf 'junk' >"$STATE/paperclip/spool/$ISSUE1/.tmp/leftover"
printf 'junk' >"$STATE/paperclip/spool/$ISSUE1/notanentry.txt"
run_afk --json
assert_eq "junk names: no cycle ran (no spool, no text change)" "$(grep -c "^POST /api/agents/$AGENT1/wakeup$" "$LOG")" "0"

new_scenario cycle_key_never_logged
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 working
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-key"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
route POST "/api/issues/$ISSUE1/comments" 201 '{}'
write_spool "$ISSUE1" 001 "{\"id\":\"$E1\",\"kind\":\"comment\",\"body\":\"x\"}"
run_afk --json
assert_absent "report cycle: the key never appears in any logged argv" "$(cat "$LOG.argv")" "KEY-AGENT1-SECRET-VALUE"
assert_absent "report cycle: the key never appears in the ledger" "$(cat "$STATE/paperclip/ledger.json")" "KEY-AGENT1-SECRET-VALUE"

# ============================================================================
head1 "15. Adopted while paused (AC-10)"
# ============================================================================
new_scenario adopt_while_paused_then_unpause
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
mkdir -p "$HOME/.config/agent-flow-kit/paperclip"; : >"$HOME/.config/agent-flow-kit/paperclip/stop"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"in_progress\",\"identifier\":\"PROJ-1\",\"title\":\"T\",\"description\":\"D\",\"updatedAt\":\"2026-01-01T00:00:00Z\"}"
route GET "/api/issues/$ISSUE1/active-run" 200 '{"id":"run-1"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
run_afk --json
LEDGER="$STATE/paperclip/ledger.json"
assert_eq "adopted while paused: pending_claim, not working" "$(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$LEDGER")" "pending_claim"
assert_eq "adopted while paused: no claim comment yet" "$(grep -c 'claimed by AFK PM' "$BODYLOG")" "0"
assert_missing "adopted while paused: no claimed notice yet" "$STATE/paperclip/notices/proj"

rm -f "$HOME/.config/agent-flow-kit/paperclip/stop"
route GET "/api/issues/$ISSUE1/active-run" 200 '{"id":"run-2"}'
run_afk --json
assert_eq "unpaused: exactly one claim comment" "$(grep -c 'claimed by AFK PM' "$BODYLOG")" "1"
NOTICE_DIR="$STATE/paperclip/notices/proj"
assert_eq "unpaused: exactly one claimed notice" "$(find "$NOTICE_DIR" -name '*.claimed.json' 2>/dev/null | wc -l | tr -d ' ')" "1"
assert_eq "unpaused: exactly one brief" "$(find "$NOTICE_DIR" -name 'brief.*' 2>/dev/null | wc -l | tr -d ' ')" "1"
assert_eq "unpaused: the issue is now working" "$(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$LEDGER")" "working"

# ============================================================================
head1 "16. Report-cycle hardening (PC-1b review)"
# ============================================================================
# cycle_base <name> — one working issue, a run, and 200 PATCHes by default.
cycle_base() {
  new_scenario "$1"
  write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
  route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
  seed_working "$ISSUE1" PROJ-1 working "${2:-}"
  route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
  route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-h"}'
  route PATCH "/api/issues/$ISSUE1" 200 '{}'
}
patches() { grep -c "^PATCH /api/issues/$ISSUE1$" "$LOG"; }
last_patch_blocked() { awk 'BEGIN{RS="\n---\n"} /"status"/{l=$0} END{print l}' "$BODYLOG" | grep -c '"status":"blocked"'; }

cycle_base cycle_403_after_in_progress
route POST "/api/issues/$ISSUE1/comments" 403 '{}'
write_spool "$ISSUE1" 001 "{\"id\":\"$E1\",\"kind\":\"comment\",\"body\":\"x\"}"
run_afk --json
assert_contains "403 after in_progress: credential reason" "$OUT_TEXT" "PAPERCLIP_CREDENTIAL_REJECTED"
assert_eq "403 after in_progress: self-block still attempted" "$(patches)" "2"
assert_eq "403 after in_progress: the last PATCH is a block" "$(last_patch_blocked)" "1"

cycle_base cycle_in_progress_timeout
route PATCH "/api/issues/$ISSUE1" NETFAIL
write_spool "$ISSUE1" 001 "{\"id\":\"$E1\",\"kind\":\"comment\",\"body\":\"x\"}"
run_afk --json
assert_eq "in_progress timeout: a self-block follows it" "$(patches)" "2"
assert_eq "in_progress timeout: nothing posted" "$(grep -c "^POST /api/issues/$ISSUE1/comments$" "$LOG")" "0"

cycle_base cycle_readback_unavailable \
  "{\"sending\":{\"entry_id\":\"$E1\",\"issue_id\":\"$ISSUE1\",\"at\":\"2026-01-01T00:00:00Z\"}}"
route GET "/api/issues/$ISSUE1/comments" 500 '{}'
route POST "/api/issues/$ISSUE1/comments" 201 '{}'
write_spool "$ISSUE1" 001 "{\"id\":\"$E1\",\"kind\":\"comment\",\"body\":\"x\"}"
run_afk --json
assert_eq "read-back failed: never re-posted blind" "$(grep -c "^POST /api/issues/$ISSUE1/comments$" "$LOG")" "0"
assert_eq "read-back failed: sending kept" "$(jq -r --arg id "$ISSUE1" '.issues[$id].sending.entry_id' "$STATE/paperclip/ledger.json")" "$E1"

cycle_base cycle_marker_from_stranger
route POST "/api/issues/$ISSUE1/comments" 500 '{}'
route GET "/api/issues/$ISSUE1/comments" 200 "[{\"authorUserId\":\"$STRANGER\",\"body\":\"<!-- afk-entry:$E1 -->\"}]"
write_spool "$ISSUE1" 001 "{\"id\":\"$E1\",\"kind\":\"comment\",\"body\":\"x\"}"
run_afk --json
assert_eq "a marker someone else posted never counts as sent" "$(find "$STATE/paperclip/spool/$ISSUE1" -maxdepth 1 -name '001.json' | wc -l | tr -d ' ')" "1"

cycle_base cycle_final_patch_fails
route POST "/api/issues/$ISSUE1/comments" 201 '{}'
route_nth PATCH "/api/issues/$ISSUE1" 2 500 '{}'
write_spool "$ISSUE1" 001 "{\"id\":\"$E1\",\"kind\":\"final\",\"status\":\"in_review\",\"body\":\"done\"}"
run_afk --json
assert_eq "final PATCH failed: not closed yet" "$(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$STATE/paperclip/ledger.json")" "working"
assert_eq "final PATCH failed: self-blocked instead" "$(last_patch_blocked)" "1"
run_afk --json
assert_eq "final PATCH retried next pass: closed" "$(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$STATE/paperclip/ledger.json")" "closed"
assert_eq "final PATCH retried: the comment was not re-posted" "$(grep -c "^POST /api/issues/$ISSUE1/comments$" "$LOG")" "1"
assert_contains "final PATCH retried: in_review applied" "$(cat "$BODYLOG")" '{"status":"in_review"}'

cycle_base cycle_bad_kind_and_status
route POST "/api/issues/$ISSUE1/comments" 201 '{}'
write_spool "$ISSUE1" 001 "{\"id\":\"$E1\",\"kind\":\"cost\",\"body\":\"x\"}"
write_spool "$ISSUE1" 002 "{\"id\":\"$E2\",\"kind\":\"final\",\"status\":\"cancelled\",\"body\":\"x\"}"
run_afk --json
assert_eq "unknown kind and bad final status: nothing posted" "$(grep -c "^POST /api/issues/$ISSUE1/comments$" "$LOG")" "0"
assert_eq "unknown kind and bad final status: both dead" "$(find "$STATE/paperclip/spool/$ISSUE1/dead" -name '*.json' | wc -l | tr -d ' ')" "2"

new_scenario adopt_while_paused_then_unpause_blocked
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
mkdir -p "$HOME/.config/agent-flow-kit/paperclip"; : >"$HOME/.config/agent-flow-kit/paperclip/stop"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"in_progress\",\"identifier\":\"PROJ-1\",\"title\":\"T\",\"description\":\"D\",\"updatedAt\":\"2026-01-01T00:00:00Z\"}"
route GET "/api/issues/$ISSUE1/active-run" 200 '{"id":"run-1"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
run_afk --json
rm -f "$HOME/.config/agent-flow-kit/paperclip/stop"
# The realistic second pass: the paused self-block stuck, so it is blocked.
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"blocked\",\"identifier\":\"PROJ-1\",\"title\":\"T\",\"description\":\"D\",\"updatedAt\":\"2026-01-01T00:00:00Z\",\"unblockDescriptor\":{\"owner\":{\"agentId\":\"$AGENT1\"}}}"
route GET "/api/issues/$ISSUE1/comments" 200 '[]'
route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-2"}'
route POST "/api/issues/$ISSUE1/comments" 201 '{}'
run_afk --json
run_afk --json
NOTICE_DIR="$STATE/paperclip/notices/proj"
assert_eq "unpaused (blocked): working" "$(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$STATE/paperclip/ledger.json")" "working"
assert_eq "unpaused (blocked): exactly one claim comment over two passes" "$(grep -c 'claimed by AFK PM' "$BODYLOG")" "1"
assert_eq "unpaused (blocked): exactly one claimed notice" "$(find "$NOTICE_DIR" -name '*.claimed.json' 2>/dev/null | wc -l | tr -d ' ')" "1"
assert_eq "unpaused (blocked): exactly one brief" "$(find "$NOTICE_DIR" -name 'brief.*' 2>/dev/null | wc -l | tr -d ' ')" "1"

# ============================================================================
head1 "17. Plan approval of record (PC-3b AC-5, AC-6)"
# ============================================================================
PD="$(printf 'a%.0s' {1..8})$(printf '0%.0s' {1..56})"; PD8="${PD:0:8}"
PCOMMIT="d554c4789ed3930f8a53ac9fdf6503b3187097da"
PATT="{\"attested_on\":\"2026-09-27\",\"paperclip_commit\":\"$PCOMMIT\"}"
# plan_scenario <name> <comments-json> [<interim-json|none>] [<health code>] [<health body>]
# Overrides via the environment: PQID (the ledger's open question id), PSENT
# (question_sent_at as JSON, e.g. null) and PSEQ (the plan file's posted_seq).
plan_scenario() {
  local qid="${PQID:-plan-$PD8}" sent="${PSENT:-\"2026-03-01T00:00:00.000Z\"}"
  new_scenario "$1"
  write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
  if [[ "${3:-}" != none ]]; then
    jq --argjson i "${3:-$PATT}" \
      '.interim_comment_approval = $i' "$CONFIG" >"$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  fi
  seed_working "$ISSUE1" HOM-12 waiting_human \
    "{\"question_id\":\"$qid\",\"question_seq\":3,\"question_sent_at\":$sent,\"action_text_applied\":\"waiting on $qid\"}"
  mkdir -p "$STATE/paperclip/plans"
  jq -nc --arg d "$PD" --argjson seq "${PSEQ:-3}" \
    '{schema:"afk-paperclip-plan-record/1", digest:$d, digest8:$d[0:8], question_id:("plan-" + $d[0:8]), posted_seq:$seq}' \
    >"$STATE/paperclip/plans/$ISSUE1.json"
  route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
  route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
  route GET "/api/issues/$ISSUE1" 200 \
    "{\"status\":\"blocked\",\"identifier\":\"HOM-12\",\"unblockDescriptor\":{\"owner\":{\"agentId\":\"$AGENT1\"}}}"
  route GET "/api/issues/$ISSUE1/comments" 200 "$2"
  route GET /api/health "${4:-200}" "${5:-{\"commit\":\"$PCOMMIT\"\}}"
  run_afk --json
  APPROVAL="$STATE/paperclip/approvals/$ISSUE1.json"; NOTICE_DIR="$STATE/paperclip/notices/proj"
}
jc() { # <id-suffix> <body> [<createdAt>] [<authorAgentId-json>]
  jq -nc --arg id "c0000000-0000-0000-0000-00000000000$1" --arg b "$2" --arg c "${3:-2026-03-02T00:00:00.000Z}" \
    --arg u "$BOARD" --argjson ag "${4:-null}" '{id:$id, body:$b, authorUserId:$u, authorAgentId:$ag, createdAt:$c}'
}
notices() { find "$NOTICE_DIR" -name "*.$1.json" 2>/dev/null | wc -l | tr -d ' '; }

plan_scenario appr_exact "[$(jc 1 "  approve $PD8"$'\n')]"
assert_eq "exact approve <d8> from Josh -> an approval record of the plan digest" "$(jq -r '.kind + " " + .digest' "$APPROVAL" 2>/dev/null)" "plan $PD"
assert_eq "  ...and one approval_granted notice" "$(notices approval_granted)" "1"
assert_eq "  ...the health check carries no key" "$(grep 'api/health' "$LOG.argv" | grep -c '@/dev/fd')" "0"

plan_scenario appr_variants "[$(jc 1 "approve 0bad0bad"), $(jc 2 "approve $PD8 please"), $(jc 3 "Approve $PD8"), $(jc 4 "APPROVE ${PD8^^}")]"
assert_missing "wrong digest8, extra words, or case changes -> no record" "$APPROVAL"
assert_eq "  ...each stays a plain human comment (reply file)" "$(find "$NOTICE_DIR" -name 'reply.*.md' | wc -l | tr -d ' ')" "4"

plan_scenario appr_agent "[$(jc 1 "approve $PD8" "" "\"$AGENT2\"")]"
assert_missing "an agent's comment carrying Josh's user id -> no record" "$APPROVAL"

plan_scenario appr_reject "[$(jc 1 "reject $PD8")]"
assert_missing "reject <d8> -> no record" "$APPROVAL"
assert_eq "  ...an approval_rejected notice" "$(notices approval_rejected)" "1"

plan_scenario appr_early "[$(jc 1 "approve $PD8" 2026-02-01T00:00:00.000Z)]"
assert_missing "a comment older than the plan's send -> no record" "$APPROVAL"
assert_contains "  ...reported" "$OUT_TEXT" "APPROVAL_BEFORE_PLAN"

plan_scenario appr_unattested "[$(jc 1 "approve $PD8")]" none
assert_missing "no attestation config -> no record" "$APPROVAL"
assert_contains "  ...APPROVAL_INTERIM_UNATTESTED reported" "$OUT_TEXT" "APPROVAL_INTERIM_UNATTESTED: HOM-12"
assert_eq "  ...and a notice" "$(grep -l APPROVAL_INTERIM_UNATTESTED "$NOTICE_DIR"/*.approval_refused.json 2>/dev/null | wc -l | tr -d ' ')" "1"

plan_scenario appr_mismatch "[$(jc 1 "approve $PD8")]" "" 200 '{"commit":"0000000000000000000000000000000000000000"}'
assert_missing "health commit mismatched -> no record" "$APPROVAL"
assert_contains "  ...unattested" "$OUT_TEXT" "APPROVAL_INTERIM_UNATTESTED"

plan_scenario appr_health_down "[$(jc 1 "approve $PD8")]" "" NETFAIL
assert_missing "health unreachable -> no record (fail closed)" "$APPROVAL"

plan_scenario appr_unverifiable "[$(jc 1 "approve $PD8" | jq -c 'del(.authorAgentId)')]"
assert_missing "a comment with no authorAgentId key at all -> no record" "$APPROVAL"
assert_contains "  ...reported unverifiable" "$OUT_TEXT" "PAPERCLIP_AUTHOR_UNVERIFIABLE"

PSEQ=2 plan_scenario appr_seq_mismatch "[$(jc 1 "approve $PD8")]"
assert_missing "plan file posted_seq != the sent question_seq -> no record" "$APPROVAL"
assert_contains "  ...APPROVAL_PLAN_MISMATCH" "$OUT_TEXT" "APPROVAL_PLAN_MISMATCH"

PSENT=null plan_scenario appr_sent_unknown "[$(jc 1 "approve $PD8")]"
assert_missing "question_sent_at unknown -> no record" "$APPROVAL"
assert_contains "  ...APPROVAL_BEFORE_PLAN" "$OUT_TEXT" "APPROVAL_BEFORE_PLAN"

PQID=q7 plan_scenario appr_other_question "[$(jc 1 "approve $PD8")]"
assert_missing "approve <d8> while a non-plan question is open -> no record" "$APPROVAL"
assert_eq "  ...it stays a plain human comment" "$(find "$NOTICE_DIR" -name 'reply.*.md' | wc -l | tr -d ' ')" "1"

plan_scenario appr_zero_width "[$(jc 1 "approve $PD8"$'​'), $(jc 2 "approve $PD8"$'\r\n')]"
assert_eq "a zero-width char after the digest is not an approval; CRLF is trimmed and is" \
  "$(jq -r .comment_id "$APPROVAL" 2>/dev/null)" "c0000000-0000-0000-0000-000000000002"

new_scenario question_send_recorded
write_config "$(jq -nc --argjson a "$(agent_json "$AGENT1" op://test/agent1 proj /repo 1)" '[$a]')"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" HOM-12 working
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-q"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
route POST "/api/issues/$ISSUE1/comments" 201 '{"createdAt":"2026-03-01T00:00:00.000Z"}'
write_spool "$ISSUE1" 00000005 "{\"id\":\"$E1\",\"kind\":\"question\",\"question_id\":\"plan-$PD8\",\"body\":\"plan\"}"
run_afk --json
assert_eq "a sent question records its seq and Paperclip's createdAt" \
  "$(jq -r --arg id "$ISSUE1" '.issues[$id] | "\(.question_seq) \(.question_sent_at)"' "$STATE/paperclip/ledger.json")" "5 2026-03-01T00:00:00.000Z"

# ===========================================================================
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
