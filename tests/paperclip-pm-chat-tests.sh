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
  "$(jq -r 'select(.method=="POST") | .body.body' "$AFK_CHAT_LOG_DIR/requests.jsonl")" \
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
  "$(jq -r 'select(.method=="POST") | .body.body' "$AFK_CHAT_LOG_DIR/requests.jsonl")" \
  "The export audience is still undecided. Tell me who reads it."

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
