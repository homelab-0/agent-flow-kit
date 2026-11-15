#!/usr/bin/env bash
# One headless PM reply on a Paperclip issue assigned to the host.
set -uo pipefail
KIT_ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0
ok() { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; FAIL=$((FAIL+1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }

export AFK_STATE_DIR="$TMP/state"
export AFK_CURL_BIN="$TMP/curl"
mkdir -p "$AFK_STATE_DIR" "$TMP/bin" "$TMP/repo/.agents/skills/bmad-agent-pm"
printf '# PM\nSpeak plainly. Do not start a build.\n' > "$TMP/repo/.agents/skills/bmad-agent-pm/SKILL.md"

cat > "$AFK_CURL_BIN" <<'SH'
#!/usr/bin/env bash
method="GET"; url=""; data=""
while (($#)); do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data|--data-binary|--data-raw|-d)
      if [[ "${2:-}" == @* ]]; then data="$(cat -- "${2#@}" 2>/dev/null || true)"; else data="${2:-}"; fi
      shift 2 ;;
    http*://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
mkdir -p "$AFK_CHAT_LOG_DIR"
jq -cn --arg m "$method" --arg u "$url" --arg d "$data" \
  '{method:$m, url:$u, body:(try ($d|fromjson) catch $d)}' >> "$AFK_CHAT_LOG_DIR/requests.jsonl"
if [[ "$method $url" == GET*"/issues?projectId="* ]]; then
  printf '%s200' "$(cat "$AFK_CHAT_LOG_DIR/issues.json")"
elif [[ "$method $url" == GET*"/comments" ]]; then
  printf '%s200' "$(cat "$AFK_CHAT_LOG_DIR/comments.json")"
elif [[ "$method $url" == POST*"/comments" ]]; then
  printf '{"ok":true}201'
else
  printf '{"ok":true}200'
fi
SH
chmod +x "$AFK_CURL_BIN"
export AFK_CHAT_LOG_DIR="$TMP/log"
mkdir -p "$AFK_CHAT_LOG_DIR"
: > "$AFK_CHAT_LOG_DIR/requests.jsonl"

ISSUE="11111111-1111-4111-8111-111111111111"
HOST="479f0f09-ee4a-4b31-902b-b662d906f41b"
BOARD="user-board"
CID="22222222-2222-4222-8222-222222222222"
printf '[{"id":"%s","status":"backlog","assigneeAgentId":"%s","title":"Scope the export"}]\n' "$ISSUE" "$HOST" > "$AFK_CHAT_LOG_DIR/issues.json"
printf '[{"id":"%s","createdAt":"2026-11-12T18:00:00Z","authorAgentId":null,"authorUserId":"%s","body":"Who is this export for?"}]\n' "$CID" "$BOARD" > "$AFK_CHAT_LOG_DIR/comments.json"

cat > "$TMP/runner.sh" <<'SH'
#!/usr/bin/env bash
printf 'ran %s\n' "$3" >> "$AFK_CHAT_LOG_DIR/runner.log"
printf 'The export audience is still undecided. Tell me who reads it.\n' > "$2"
SH
chmod +x "$TMP/runner.sh"

# shellcheck disable=SC1091
. "$KIT_ROOT/lib/afk-paperclip.sh"
export AFK_PC_PM_RUNNER="$TMP/runner.sh"

afk_pc_pm_chat_scan_project "https://paperclip.example" "test-key" "company" "project" \
  "$HOST" "$BOARD" "spektacle" "$TMP/repo"
assert_eq "A board comment gets one PM reply" \
  "$(jq -r 'select(.method=="POST" and (.url|endswith("/comments"))) | .body.body' "$AFK_CHAT_LOG_DIR/requests.jsonl")" \
  "The export audience is still undecided. Tell me who reads it."
assert_eq "The runner saw the project PM skill" \
  "$(grep -c 'bmad-agent-pm/SKILL.md' "$AFK_CHAT_LOG_DIR/runner.log")" "1"

afk_pc_pm_chat_scan_project "https://paperclip.example" "test-key" "company" "project" \
  "$HOST" "$BOARD" "spektacle" "$TMP/repo"
assert_eq "The same comment is not answered twice" \
  "$(grep -c . "$AFK_CHAT_LOG_DIR/runner.log")" "1"

# An in-progress factory job suppresses the chat.
ISSUE2="33333333-3333-4333-8333-333333333333"
CID2="44444444-4444-4444-8444-444444444444"
mkdir -p "$TMP/repo/.afk/jobs/job-live"
printf '{"issue_id":"%s","stage":"build"}\n' "$ISSUE2" > "$TMP/repo/.afk/jobs/job-live/job.json"
printf '[{"id":"%s","status":"todo","assigneeAgentId":"%s","title":"Build"}]\n' "$ISSUE2" "$HOST" > "$AFK_CHAT_LOG_DIR/issues.json"
printf '[{"id":"%s","createdAt":"2026-11-12T18:05:00Z","authorAgentId":null,"authorUserId":"%s","body":"Wait, there is a blocker."}]\n' "$CID2" "$BOARD" > "$AFK_CHAT_LOG_DIR/comments.json"
: > "$AFK_CHAT_LOG_DIR/runner.log"
afk_pc_pm_chat_scan_project "https://paperclip.example" "test-key" "company" "project" \
  "$HOST" "$BOARD" "spektacle" "$TMP/repo"
assert_eq "A running factory job does not get a planning reply" \
  "$(wc -c < "$AFK_CHAT_LOG_DIR/runner.log" | tr -d ' ')" "0"

# A backlog issue with only a description, and no comments, is the opening question.
ISSUE3="55555555-5555-4555-8555-555555555555"
printf '[{"id":"%s","status":"backlog","assigneeAgentId":"%s","title":"What is scoped?","description":"What epics exist?"}]\n' \
  "$ISSUE3" "$HOST" > "$AFK_CHAT_LOG_DIR/issues.json"
printf '[]\n' > "$AFK_CHAT_LOG_DIR/comments.json"
: > "$AFK_CHAT_LOG_DIR/runner.log"
: > "$AFK_CHAT_LOG_DIR/requests.jsonl"
afk_pc_pm_chat_scan_project "https://paperclip.example" "test-key" "company" "project" \
  "$HOST" "$BOARD" "spektacle" "$TMP/repo"
assert_eq "The issue description is the opening question when there are no comments" \
  "$(jq -r 'select(.method=="POST" and (.url|endswith("/comments"))) | .body.body' "$AFK_CHAT_LOG_DIR/requests.jsonl")" \
  "The export audience is still undecided. Tell me who reads it."

# Messaging the host moves a backlog card to in_progress. That comment still gets a reply.
ISSUE4="66666666-6666-4666-8666-666666666666"
CID4="77777777-7777-4777-8777-777777777777"
rm -rf "$AFK_STATE_DIR/paperclip/pm-chat"
printf '[{"id":"%s","status":"in_progress","assigneeAgentId":"%s","title":"Follow up","description":"old"}]\n' \
  "$ISSUE4" "$HOST" > "$AFK_CHAT_LOG_DIR/issues.json"
printf '[{"id":"%s","createdAt":"2026-11-13T12:08:00Z","authorAgentId":null,"authorUserId":"%s","body":"Have we broken those into stories?"}]\n' \
  "$CID4" "$BOARD" > "$AFK_CHAT_LOG_DIR/comments.json"
: > "$AFK_CHAT_LOG_DIR/runner.log"
: > "$AFK_CHAT_LOG_DIR/requests.jsonl"
afk_pc_pm_chat_scan_project "https://paperclip.example" "test-key" "company" "project" \
  "$HOST" "$BOARD" "spektacle" "$TMP/repo"
assert_eq "A follow-up that moved the card to in progress still gets a PM reply" \
  "$(jq -r 'select(.method=="POST" and (.url|endswith("/comments"))) | .body.body' "$AFK_CHAT_LOG_DIR/requests.jsonl")" \
  "The export audience is still undecided. Tell me who reads it."

# @spektacle-dev on a Done card routes to the dev skill, not the PM skill.
mkdir -p "$TMP/repo/.agents/skills/bmad-agent-dev" "$AFK_STATE_DIR/paperclip"
printf '# Dev\nAnswer as the developer. Do not start a build.\n' > "$TMP/repo/.agents/skills/bmad-agent-dev/SKILL.md"
DEV_ID="88888888-8888-4888-8888-888888888888"
cat > "$AFK_STATE_DIR/paperclip/hired-agents.json" <<JSON
{"schema":"afk-hired-agents/1","projects":{"spektacle":{"agents":{"dev":{"agent_id":"$DEV_ID","name":"spektacle-dev","role":"dev","persona_name":"Amelia"}}}}}
JSON
ISSUE5="99999999-9999-4999-8999-999999999999"
CID5="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
printf '[{"id":"%s","status":"done","assigneeAgentId":"%s","title":"Done card","description":"old"}]\n' \
  "$ISSUE5" "$HOST" > "$AFK_CHAT_LOG_DIR/issues.json"
printf '[{"id":"%s","createdAt":"2026-11-13T12:10:00Z","authorAgentId":null,"authorUserId":"%s","body":"@spektacle-dev what does the check script reject?"}]\n' \
  "$CID5" "$BOARD" > "$AFK_CHAT_LOG_DIR/comments.json"
: > "$AFK_CHAT_LOG_DIR/runner.log"
: > "$AFK_CHAT_LOG_DIR/requests.jsonl"
afk_pc_pm_chat_scan_project "https://paperclip.example" "test-key" "company" "project" \
  "$HOST" "$BOARD" "spektacle" "$TMP/repo"
assert_eq "An @ mention on a done card routes to that agent skill" \
  "$(grep -c 'bmad-agent-dev/SKILL.md' "$AFK_CHAT_LOG_DIR/runner.log")" "1"

# A second comment is the same conversation. The prompt carries the earlier one.
ISSUE6="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
CID6A="cccccccc-cccc-4ccc-8ccc-cccccccccccc"
CID6B="dddddddd-dddd-4ddd-8ddd-dddddddddddd"
rm -rf "$AFK_STATE_DIR/paperclip/pm-chat"
printf '[{"id":"%s","status":"backlog","assigneeAgentId":"%s","title":"Export"}]\n' \
  "$ISSUE6" "$HOST" > "$AFK_CHAT_LOG_DIR/issues.json"
printf '[{"id":"%s","createdAt":"2026-11-13T12:00:00Z","authorAgentId":null,"authorUserId":"%s","body":"The audience is operators."},{"id":"%s","createdAt":"2026-11-13T12:20:00Z","authorAgentId":null,"authorUserId":"%s","body":"What should we name the export?"}]\n' \
  "$CID6A" "$BOARD" "$CID6B" "$BOARD" > "$AFK_CHAT_LOG_DIR/comments.json"
: > "$AFK_CHAT_LOG_DIR/runner.log"
: > "$AFK_CHAT_LOG_DIR/requests.jsonl"
afk_pc_pm_chat_scan_project "https://paperclip.example" "test-key" "company" "project" \
  "$HOST" "$BOARD" "spektacle" "$TMP/repo"
PROMPT6="$AFK_STATE_DIR/paperclip/pm-chat/$ISSUE6/$CID6B.prompt.md"
assert_eq "A second planning comment includes the earlier comment" \
  "$(grep -c 'The audience is operators.' "$PROMPT6"):$(grep -c 'What should we name the export?' "$PROMPT6"):$(grep -c agent-hires "$AFK_CHAT_LOG_DIR/requests.jsonl")" \
  "1:1:0"

# The default runner, with a stub claude: where it runs and what it may use.
STUB="$TMP/stub-claude"; mkdir -p "$STUB"
cat > "$STUB/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PWD" > "$AFK_CHAT_LOG_DIR/claude.cwd"
printf '%s\n' "$@" > "$AFK_CHAT_LOG_DIR/claude.args"
if [[ -n "${STUB_CLAUDE_ERROR:-}" ]]; then
  printf '{"is_error":true,"result":"Credit balance is too low"}\n'
else
  printf '{"is_error":false,"result":"A planning answer."}\n'
fi
SH
chmod +x "$STUB/claude"
printf 'prompt\n' > "$TMP/p.md"
PATH="$STUB:$PATH" afk_pc_pm_chat_run_default "$TMP/p.md" "$TMP/out.md" "$TMP/repo"; RC=$?
ARGS="$(tr '\n' ' ' < "$AFK_CHAT_LOG_DIR/claude.args")"
assert_eq "The default planning reply runs inside the project checkout and returns its answer" \
  "$RC:$(cat "$AFK_CHAT_LOG_DIR/claude.cwd"):$(cat "$TMP/out.md")" "0:$TMP/repo:A planning answer."
assert_eq "It runs restricted: read-only tools, no MCP servers, nobody to grant permissions, no saved session" \
  "$(for f in '--restricted' '--tools Read,Grep,Glob' '--strict-mcp-config' '--permission-prompts none' '--no-session-persistence'; do [[ "$ARGS" == *"$f"* ]] && printf y || printf n; done)" "yyyyy"
rm -f "$TMP/out.md"
STUB_CLAUDE_ERROR=1 PATH="$STUB:$PATH" afk_pc_pm_chat_run_default "$TMP/p.md" "$TMP/out.md" "$TMP/repo"; RC=$?
assert_eq "An error result is never written out as a reply" "$RC:$([[ -s "$TMP/out.md" ]] && printf written || printf none)" "1:none"
assert_eq "Without a project checkout no model is run" \
  "$(PATH="$STUB:$PATH" afk_pc_pm_chat_run_default "$TMP/p.md" "$TMP/out2.md" "$TMP/no-such-repo"; printf '%s' "$?")" "1"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
