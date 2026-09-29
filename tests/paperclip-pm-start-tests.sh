#!/usr/bin/env bash
# paperclip-pm-start-tests.sh — the isolated deterministic gate for
# AFK-PC-2b: PM-start classification (lib/afk-paperclip-start.sh, the hook in
# lib/afk-paperclip.sh) and `agent-flow-kit paperclip-timer`.
#
# No network, no real harness, no real systemd unit: op, curl, orca,
# systemctl and readiness are all stubs (orca/systemctl on PATH, readiness via
# AFK_PCS_READINESS_BIN), following the pattern in tests/paperclip-poll-tests.sh.
#
# Usage: tests/paperclip-pm-start-tests.sh
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

if bash -n "$KIT_ROOT/lib/afk-paperclip-start.sh"; then ok "bash -n lib/afk-paperclip-start.sh"
else bad "bash -n lib/afk-paperclip-start.sh"; fi

STUBS="$TMPROOT/stubs"; mkdir -p "$STUBS"

cat >"$STUBS/op" <<'SH'
#!/usr/bin/env bash
# op succeeds only with a service-account token, like the real one.
[[ "$1" == read && -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]] || exit 2
[[ "$2" == op://test/agent1 ]] && { printf 'KEY-AGENT1\n'; exit 0; }
exit 1
SH

cat >"$STUBS/curl" <<'SH'
#!/usr/bin/env bash
method="GET"; n=$#; args=("$@")
for ((i = 0; i < n; i++)); do [[ "${args[$i]}" == -X ]] && method="${args[$((i + 1))]}"; done
url="${args[$((n - 1))]}"
tmp="${url#*://}"; path="/${tmp#*/}"
printf '%s %s\n' "$method" "$path" >>"$CURL_STUB_LOG"
for ((i = 0; i < n; i++)); do
  if [[ "${args[$i]}" == --data-binary && "${args[$((i + 1))]}" == @/dev/fd/* ]]; then
    cat "${args[$((i + 1))]#@}" >>"$CURL_STUB_BODYLOG"; printf '\n---\n' >>"$CURL_STUB_BODYLOG"
  fi
done
key="${method}_${path#/}"; key="${key//\//_}"
f="$CURL_STUB_FIXTURES/$key"
[[ -f "$f" ]] || f="$CURL_STUB_FIXTURES/DEFAULT"
if [[ ! -f "$f" ]]; then printf '000'; exit 0; fi
code="$(head -1 "$f")"; tail -n +2 "$f"; printf '%s' "$code"
SH

# orca — worktree show, terminal list (bare and --worktree), terminal create.
# No launch, no real terminal: every response is a fixture this test controls.
cat >"$STUBS/orca" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "worktree show") cat "$ORCA_WT_FILE" ;;
  "terminal list")
    if [[ "${3:-}" == --worktree ]]; then cat "$ORCA_TERMLIST_WT_FILE"; else cat "$ORCA_TERMLIST_FILE"; fi ;;
  "terminal create")
    printf '%s\n' "$*" >>"$ORCA_CREATE_LOG"
    printf '{"result":{"terminal":{"handle":"term-created-1"}}}' ;;
  *) exit 1 ;;
esac
SH

# systemctl — enable/disable/is-enabled/is-active/daemon-reload, logged only.
cat >"$STUBS/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$SYSTEMCTL_LOG"
case "$*" in
  *is-enabled*) printf '%s\n' "${SYSTEMCTL_ENABLED:-enabled}"; exit 0 ;;
  *is-active*) printf '%s\n' "${SYSTEMCTL_ACTIVE:-active}"; exit 0 ;;
  # The user manager's environment, which the unit inherits.
  *show-environment*) [[ -n "${SYSTEMCTL_SHOWENV:-}" ]] && cat "$SYSTEMCTL_SHOWENV"; exit 0 ;;
  *) exit 0 ;;
esac
SH

# readiness — a stub binary standing in for `agent-flow-kit status --json`
# (AFK_PCS_READINESS_BIN). Never the real kit.
cat >"$STUBS/readiness" <<'SH'
#!/usr/bin/env bash
if [[ "${READINESS_OK:-true}" == true ]]; then printf '{"readiness":{"INSTALLED_INTEGRITY":{"state":"READY"}}}'; exit 0; fi
if [[ "${READINESS_OK}" == integrity ]]; then printf '{"readiness":{"INSTALLED_INTEGRITY":{"state":"NOT_READY","reason":"INTEGRITY_DRIFT"}}}'; exit 0; fi
printf '{"route":{"reason":"%s"}}' "${READINESS_REASON:-NOT_READY}"; exit 3
SH
# harness — stands in for claude when the real bootstrap adapter execs it;
# records the argv it was given, one argument per line.
cat >"$STUBS/harness" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$HARNESS_ARGV_LOG"
SH
chmod +x "$STUBS"/*

COMPANY="cccccccc-cccc-cccc-cccc-cccccccccccc"
BOARD="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
AGENT1="11111111-1111-1111-1111-111111111111"
ISSUE1="e1111111-1111-1111-1111-111111111111"
PROJ1="aaaaaaaa-0000-4000-8000-000000000001"

# new_scenario <name> — fresh HOME, fixtures, git repo and Orca fixtures.
new_scenario() {
  SCEN="$TMPROOT/$1"; mkdir -p "$SCEN"
  HOME="$SCEN/home"; mkdir -p "$HOME"
  STATE="$HOME/.local/state/agent-flow-kit"
  FIXDIR="$SCEN/fixtures"; mkdir -p "$FIXDIR"
  CONFIG="$SCEN/paperclip.json"
  LOG="$SCEN/curl.log"; BODYLOG="$SCEN/curl.bodies"; SYSTEMCTL_LOG="$SCEN/systemctl.log"
  ORCA_CREATE_LOG="$SCEN/orca-create.log"
  : >"$LOG"; : >"$BODYLOG"; : >"$SYSTEMCTL_LOG"; : >"$ORCA_CREATE_LOG"
  REPO="$SCEN/repo"; git init -q "$REPO"
  git -C "$REPO" config user.email t@test; git -C "$REPO" config user.name t
  : >"$REPO/f"; mkdir -p "$REPO/.afk"; printf 'bash tests/run-tests.sh\n' >"$REPO/.afk/gates-allowlist"
  git -C "$REPO" -c commit.gpgsign=false add f .afk/gates-allowlist
  git -C "$REPO" -c commit.gpgsign=false commit -qm init >/dev/null
  ORCA_WT_FILE="$SCEN/orca-wt.json"
  jq -nc --arg p "$REPO" '{result:{worktree:{id:"wt-1", path:$p}}}' >"$ORCA_WT_FILE"
  ORCA_TERMLIST_FILE="$SCEN/orca-termlist.json"
  printf '{"result":{"terminals":[]}}' >"$ORCA_TERMLIST_FILE"
  ORCA_TERMLIST_WT_FILE="$SCEN/orca-termlist-wt.json"
  printf '{"result":{"terminals":[]}}' >"$ORCA_TERMLIST_WT_FILE"
  REPO_ABS="$(cd "$REPO" && pwd -P)"
}

write_config() { # <extra-json-merge>
  jq -n --arg api "https://paperclip.test" --arg co "$COMPANY" --arg bu "$BOARD" --arg hl "test-host" \
    --arg a "$AGENT1" --arg r "$REPO" --arg p "$PROJ1" --argjson extra "${1:-\{\}}" \
    '{schema: "afk-paperclip-config/2", api_url: $api, company_id: $co, board_user_id: $bu,
      host: {label: $hl, agent_id: $a, key_ref: "op://test/agent1"},
      projects: [{paperclip_project_id:$p, slug:"proj", repo_path:$r, harness:"claude", max_active_issues:1}]}
     * $extra' >"$CONFIG"
  route GET "/api/projects/$PROJ1" 200 "{\"id\":\"$PROJ1\",\"name\":\"Proj\",\"archivedAt\":null,\"codebase\":{\"repoUrl\":null}}"
}

RC=0 OUT_TEXT=""
run_afk() { # <cmd> [args...]
  local out err
  out="$(env -i PATH="$STUBS:$PATH" HOME="${HOME:-$SCEN/home}" LANG=C \
    AFK_STATE_DIR="$STATE" AFK_PAPERCLIP_CONFIG="$CONFIG" \
    AFK_OP_BIN="$STUBS/op" AFK_CURL_BIN="$STUBS/curl" AFK_ORCA_BIN="$STUBS/orca" OP_SERVICE_ACCOUNT_TOKEN=test-op-token \
    AFK_PCS_READINESS_BIN="$STUBS/readiness" READINESS_OK="${READINESS_OK:-true}" READINESS_REASON="${READINESS_REASON:-}" \
    CURL_STUB_LOG="$LOG" CURL_STUB_BODYLOG="$BODYLOG" CURL_STUB_FIXTURES="$FIXDIR" \
    ORCA_WT_FILE="$ORCA_WT_FILE" ORCA_TERMLIST_FILE="$ORCA_TERMLIST_FILE" ORCA_TERMLIST_WT_FILE="$ORCA_TERMLIST_WT_FILE" \
    ORCA_CREATE_LOG="$ORCA_CREATE_LOG" SYSTEMCTL_LOG="$SYSTEMCTL_LOG" ${SYSTEMCTL_SHOWENV:+SYSTEMCTL_SHOWENV="$SYSTEMCTL_SHOWENV"} \
    SYSTEMCTL_ENABLED="${SYSTEMCTL_ENABLED:-enabled}" SYSTEMCTL_ACTIVE="${SYSTEMCTL_ACTIVE:-active}" \
    AFK_PCT_SYSTEMD_DIR="$SCEN/systemd-user" \
    bash "$AFK" "$@" 2>"$SCEN/err")"
  RC=$?
  err="$(cat "$SCEN/err")"
  OUT_TEXT="$out"$'\n'"$err"
}

route() { # <method> <path> <code> [<body>]
  local key="${1}_${2#/}"; key="${key//\//_}"
  { printf '%s\n' "$3"; [[ -n "${4:-}" ]] && printf '%s\n' "$4"; } >"$FIXDIR/$key"
}

issue_route() { # <status> <created_by>
  route GET "/api/issues/$ISSUE1" 200 \
    "{\"status\":\"$1\",\"identifier\":\"PROJ-1\",\"title\":\"T\",\"description\":\"D\",\"updatedAt\":\"2026-01-01T00:00:00Z\",\"createdByUserId\":\"$2\",\"projectId\":\"$PROJ1\"}"
}

do_pass() { # a full claim-side pass adopting ISSUE1 fresh
  route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
  route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
  route GET "/api/issues/$ISSUE1/active-run" 200 '{"id":"run-1"}'
  route POST "/api/issues/$ISSUE1/comments" 201 '{}'
  route PATCH "/api/issues/$ISSUE1" 200 '{}'
  run_afk paperclip-poll --json
}

# ============================================================================
head1 "1. none + Josh-created -> exactly one terminal create"
# ============================================================================
new_scenario none_josh
write_config '{"pm_start_enabled":true}'
issue_route in_progress "$BOARD"
do_pass
assert_eq "none+Josh: pass exit 0" "$RC" "0"
assert_eq "none+Josh: exactly one terminal create" "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" "1"
INTENT_FILE="$STATE/paperclip/pm-start-intents/proj.json"
assert_contains "none+Josh: fixed instruction text present" "$(cat "$INTENT_FILE")" "You are the BMAD PM for project proj"
assert_contains "none+Josh: the started PM is told to take by --slug" "$(cat "$INTENT_FILE")" "paperclip-take --slug proj"
assert_contains "none+Josh: the terminal title names the slug" "$(cat "$ORCA_CREATE_LOG")" "PM proj (paperclip)"
assert_absent "none+Josh: no issue title in the create argv" "$(cat "$ORCA_CREATE_LOG")" "T\""
assert_absent "none+Josh: no issue description in the create argv" "$(cat "$ORCA_CREATE_LOG")" "\"D\""
INTENT_FILE="$STATE/paperclip/pm-start-intents/proj.json"
assert_absent "none+Josh: no issue title in the bootstrap intent" "$(cat "$INTENT_FILE" 2>/dev/null)" "\"T\""
assert_absent "none+Josh: no issue description in the bootstrap intent" "$(cat "$INTENT_FILE" 2>/dev/null)" "\"D\""
LEDGER="$STATE/paperclip/ledger.json"
assert_eq "none+Josh: ledger records the terminal" "$(jq -r --arg id "$ISSUE1" '.pm_started[$id].terminal' "$LEDGER")" "term-created-1"
# The real adapter validates the intent the lib wrote (the fixed text is
# rebuilt and byte-compared there), so the two copies can never drift.
run_adapter() { # <intent-file>
  (cd "$REPO_ABS" && env -i PATH="$STUBS:$PATH" HOME="$SCEN/home" LANG=C ORCA_TERMINAL_HANDLE=term-created-1 \
    AFK_ORCA_BIN="$STUBS/orca" ORCA_WT_FILE="$ORCA_WT_FILE" AFK_CLAUDE_BIN="$STUBS/harness" HARNESS_ARGV_LOG="$SCEN/harness.argv" \
    bash "$KIT_ROOT/adapters/orca-pm-bootstrap.sh" --intent "$1" >/dev/null 2>&1)
}
: >"$SCEN/harness.argv"
run_adapter "$INTENT_FILE"; ARC=$?
assert_eq "none+Josh: the real adapter accepts the lib-written intent" "$ARC" "0"
assert_contains "  ...and starts the harness with the fixed --slug instruction" "$(cat "$SCEN/harness.argv")" "paperclip-take --slug proj"
assert_eq "  ...the intent names the slug under the key slug" "$(jq -r '"\(.schema) \(.slug) \(has("project"))"' "$INTENT_FILE")" \
  "afk-pm-bootstrap-first-start-intent/2 proj false"
jq '.resume_instruction |= sub("--slug"; "--project")' "$INTENT_FILE" >"$SCEN/edited-intent.json"
: >"$SCEN/harness.argv"
run_adapter "$SCEN/edited-intent.json"; ARC=$?
assert_eq "  ...an intent whose text differs from the lib's is refused" "$ARC|$(cat "$SCEN/harness.argv")" "1|"
assert_eq "none+Josh: pm_started records the slug" "$(jq -r --arg id "$ISSUE1" '.pm_started[$id] | "\(.slug) \(has("project"))"' "$LEDGER")" "proj false"
assert_eq "none+Josh: ledger counts one start today" "$(jq -r '.pm_starts | to_entries[0].value' "$LEDGER")" "1"

# ============================================================================
head1 "2. live -> no create"
# ============================================================================
new_scenario live_state
write_config '{"pm_start_enabled":true}'
scope_key() { printf 'terminal-%s' "$(printf 'terminal\0%s' "$1" | sha256sum | awk '{print $1}')"; }
SK="$(scope_key term-live-1)"
mkdir -p "$STATE/pm/scopes/$SK"
REPO_ABS="$(cd "$REPO" && pwd -P)"
jq -nc --arg t term-live-1 --arg s sess-1 --arg wp "$REPO_ABS" \
  '{schema:"afk-pm-ownership/2", owned:true, terminal:$t, session:$s, harness:"claude", worktree:{path:$wp}}' \
  >"$STATE/pm/scopes/$SK/ownership.json"
printf '{"result":{"terminals":[{"handle":"term-live-1","connected":true,"orphaned":false}]}}' >"$ORCA_TERMLIST_FILE"
issue_route in_progress "$BOARD"
do_pass
assert_eq "live: no terminal create" "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" "0"

# ============================================================================
head1 "3. ambiguous -> waiting text + one out-of-band issue"
# ============================================================================
new_scenario ambiguous_state
write_config '{"pm_start_enabled":true}'
SK1="$(scope_key term-amb-1)"; SK2="$(scope_key term-amb-2)"
mkdir -p "$STATE/pm/scopes/$SK1" "$STATE/pm/scopes/$SK2"
jq -nc --arg t term-amb-1 --arg s s1 --arg wp "$REPO_ABS" \
  '{schema:"afk-pm-ownership/2", owned:true, terminal:$t, session:$s, harness:"claude", worktree:{path:$wp}}' \
  >"$STATE/pm/scopes/$SK1/ownership.json"
jq -nc --arg t term-amb-2 --arg s s2 --arg wp "$REPO_ABS" \
  '{schema:"afk-pm-ownership/2", owned:true, terminal:$t, session:$s, harness:"claude", worktree:{path:$wp}}' \
  >"$STATE/pm/scopes/$SK2/ownership.json"
printf '{"result":{"terminals":[{"handle":"term-amb-1","connected":true,"orphaned":false},{"handle":"term-amb-2","connected":true,"orphaned":false}]}}' \
  >"$ORCA_TERMLIST_FILE"
route POST "/api/companies/$COMPANY/issues" 201 '{"id":"newissue-1"}'
issue_route in_progress "$BOARD"
do_pass
assert_eq "ambiguous: no terminal create" "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" "0"
assert_eq "ambiguous: one out-of-band issue created" "$(grep -c "^POST /api/companies/$COMPANY/issues$" "$LOG")" "1"
LEDGER="$STATE/paperclip/ledger.json"
assert_contains "ambiguous: waiting-for-Josh text recorded" \
  "$(jq -r --arg id "$ISSUE1" '.issues[$id].action_text' "$LEDGER")" "Waiting for Josh: PM state unclear on test-host"

# ============================================================================
head1 "4. Jarvis-created needs approval, then an exact Josh comment starts it"
# ============================================================================
new_scenario needs_approval
write_config "$(jq -nc --arg cv aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa '{pm_start_enabled:true, interim_comment_approval:{paperclip_commit:$cv}}')"
route GET /api/health 200 '{"commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
JARVIS="88888888-8888-8888-8888-888888888888"
issue_route blocked "$JARVIS" # not the board -> creator gate fails
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
mkdir -p "$STATE/paperclip"
jq -n --arg a "$AGENT1" --arg id "$ISSUE1" \
  '{issues: {($id): {host_agent_id: $a, paperclip_project_id: "aaaaaaaa-0000-4000-8000-000000000001", slug: "proj", identifier: "PROJ-1", state: "pending_claim", since: "2026-01-01T00:00:00Z"}},
    stranded_reported: [], drain_tampered_reported: false, last_successful_pass: null}' \
  >"$STATE/paperclip/ledger.json"
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"blocked\",\"identifier\":\"PROJ-1\",\"title\":\"T\",\"description\":\"D\",\"createdByUserId\":\"$JARVIS\",\"projectId\":\"$PROJ1\",\"unblockDescriptor\":{\"owner\":{\"agentId\":\"$AGENT1\"},\"action\":\"paused\"}}"
route GET "/api/issues/$ISSUE1/comments" 200 '[]'
route POST "/api/issues/$ISSUE1/comments" 201 '{}'
run_afk paperclip-poll --json
assert_eq "jarvis-created: no terminal create" "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" "0"
assert_eq "jarvis-created: exactly one question comment" \
  "$(grep -c 'Reply exactly: approve start PROJ-1' "$BODYLOG")" "1"
run_afk paperclip-poll --json
assert_eq "jarvis-created: no second question comment" \
  "$(grep -c 'Reply exactly: approve start PROJ-1' "$BODYLOG")" "1"

# Now an exact Josh approval comment arrives.
route GET "/api/issues/$ISSUE1/comments" 200 \
  "[{\"id\":\"c0000000-0000-0000-0000-00000000000a\",\"body\":\"approve start PROJ-1\",\"authorUserId\":\"$BOARD\",\"authorAgentId\":null,\"createdAt\":\"2026-02-01T00:00:00Z\"}]"
run_afk paperclip-poll --json
assert_eq "approved: exactly one terminal create" "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" "1"
# The harness has since retitled its terminal and has not registered yet:
# the registry still says `none` and no title matches. Still one start.
run_afk paperclip-poll --json
assert_eq "approved: a later pass never starts a second PM" "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" "1"

# The stop flag holds every start, even an approved one.
new_scenario approved_but_stopped
write_config "$(jq -nc --arg cv aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa '{pm_start_enabled:true, interim_comment_approval:{paperclip_commit:$cv}}')"
route GET /api/health 200 '{"commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
mkdir -p "$STATE/paperclip" "$HOME/.config/agent-flow-kit/paperclip"
: >"$HOME/.config/agent-flow-kit/paperclip/stop"
jq -n --arg a "$AGENT1" --arg id "$ISSUE1" \
  '{issues: {($id): {host_agent_id: $a, paperclip_project_id: "aaaaaaaa-0000-4000-8000-000000000001", slug: "proj", identifier: "PROJ-1", state: "pending_claim", since: "2026-01-01T00:00:00Z"}},
    stranded_reported: [], drain_tampered_reported: false, last_successful_pass: null}' \
  >"$STATE/paperclip/ledger.json"
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"blocked\",\"identifier\":\"PROJ-1\",\"title\":\"T\",\"description\":\"D\",\"createdByUserId\":\"$BOARD\",\"projectId\":\"$PROJ1\",\"unblockDescriptor\":{\"owner\":{\"agentId\":\"$AGENT1\"},\"action\":\"paused\"}}"
route GET "/api/issues/$ISSUE1/comments" 200 '[]'
route POST "/api/issues/$ISSUE1/comments" 201 '{}'
run_afk paperclip-poll --json
assert_eq "stopped: no terminal create" "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" "0"

# ============================================================================
head1 "5. Attestation absent -> APPROVAL_INTERIM_UNATTESTED, no start"
# ============================================================================
new_scenario unattested
write_config '{"pm_start_enabled":true}' # no interim_comment_approval at all
JARVIS="88888888-8888-8888-8888-888888888888"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
mkdir -p "$STATE/paperclip"
jq -n --arg a "$AGENT1" --arg id "$ISSUE1" \
  '{issues: {($id): {host_agent_id: $a, paperclip_project_id: "aaaaaaaa-0000-4000-8000-000000000001", slug: "proj", identifier: "PROJ-1", state: "pending_claim", since: "2026-01-01T00:00:00Z"}},
    stranded_reported: [], drain_tampered_reported: false, last_successful_pass: null}' \
  >"$STATE/paperclip/ledger.json"
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"blocked\",\"identifier\":\"PROJ-1\",\"title\":\"T\",\"description\":\"D\",\"createdByUserId\":\"$JARVIS\",\"projectId\":\"$PROJ1\",\"unblockDescriptor\":{\"owner\":{\"agentId\":\"$AGENT1\"},\"action\":\"paused\"}}"
route GET "/api/issues/$ISSUE1/comments" 200 \
  "[{\"id\":\"c0000000-0000-0000-0000-00000000000a\",\"body\":\"approve start PROJ-1\",\"authorUserId\":\"$BOARD\",\"authorAgentId\":null,\"createdAt\":\"2026-02-01T00:00:00Z\"}]"
route POST "/api/issues/$ISSUE1/comments" 201 '{}'
run_afk paperclip-poll --json
assert_eq "unattested: no terminal create" "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" "0"
assert_contains "unattested: result names the reason" "$OUT_TEXT" "APPROVAL_INTERIM_UNATTESTED"

# ============================================================================
head1 "5b. AC-6: a stale/mismatched or unreachable health commit refuses, fail-closed"
# ============================================================================
new_scenario commit_mismatch
write_config "$(jq -nc --arg cv aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa '{pm_start_enabled:true, interim_comment_approval:{paperclip_commit:$cv}}')"
route GET /api/health 200 '{"commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}' # deployed commit has moved past the interim attestation
JARVIS="88888888-8888-8888-8888-888888888888"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
mkdir -p "$STATE/paperclip"
jq -n --arg a "$AGENT1" --arg id "$ISSUE1" \
  '{issues: {($id): {host_agent_id: $a, paperclip_project_id: "aaaaaaaa-0000-4000-8000-000000000001", slug: "proj", identifier: "PROJ-1", state: "pending_claim", since: "2026-01-01T00:00:00Z"}},
    stranded_reported: [], drain_tampered_reported: false, last_successful_pass: null}' \
  >"$STATE/paperclip/ledger.json"
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"blocked\",\"identifier\":\"PROJ-1\",\"title\":\"T\",\"description\":\"D\",\"createdByUserId\":\"$JARVIS\",\"projectId\":\"$PROJ1\",\"unblockDescriptor\":{\"owner\":{\"agentId\":\"$AGENT1\"},\"action\":\"paused\"}}"
route GET "/api/issues/$ISSUE1/comments" 200 \
  "[{\"id\":\"c0000000-0000-0000-0000-00000000000a\",\"body\":\"approve start PROJ-1\",\"authorUserId\":\"$BOARD\",\"authorAgentId\":null,\"createdAt\":\"2026-02-01T00:00:00Z\"}]"
route POST "/api/issues/$ISSUE1/comments" 201 '{}'
run_afk paperclip-poll --json
assert_eq "mismatched commit: no terminal create" "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" "0"
assert_contains "mismatched commit: result names the reason" "$OUT_TEXT" "APPROVAL_INTERIM_UNATTESTED"

new_scenario health_unreachable
write_config "$(jq -nc --arg cv aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa '{pm_start_enabled:true, interim_comment_approval:{paperclip_commit:$cv}}')"
# No /api/health fixture at all: the curl stub falls back to its DEFAULT (a
# transport-style 000), exactly like an unreachable health endpoint.
JARVIS="88888888-8888-8888-8888-888888888888"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
mkdir -p "$STATE/paperclip"
jq -n --arg a "$AGENT1" --arg id "$ISSUE1" \
  '{issues: {($id): {host_agent_id: $a, paperclip_project_id: "aaaaaaaa-0000-4000-8000-000000000001", slug: "proj", identifier: "PROJ-1", state: "pending_claim", since: "2026-01-01T00:00:00Z"}},
    stranded_reported: [], drain_tampered_reported: false, last_successful_pass: null}' \
  >"$STATE/paperclip/ledger.json"
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"blocked\",\"identifier\":\"PROJ-1\",\"title\":\"T\",\"description\":\"D\",\"createdByUserId\":\"$JARVIS\",\"projectId\":\"$PROJ1\",\"unblockDescriptor\":{\"owner\":{\"agentId\":\"$AGENT1\"},\"action\":\"paused\"}}"
route GET "/api/issues/$ISSUE1/comments" 200 \
  "[{\"id\":\"c0000000-0000-0000-0000-00000000000a\",\"body\":\"approve start PROJ-1\",\"authorUserId\":\"$BOARD\",\"authorAgentId\":null,\"createdAt\":\"2026-02-01T00:00:00Z\"}]"
route POST "/api/issues/$ISSUE1/comments" 201 '{}'
run_afk paperclip-poll --json
assert_eq "health unreachable: no terminal create" "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" "0"
assert_contains "health unreachable: result names the reason" "$OUT_TEXT" "APPROVAL_INTERIM_UNATTESTED"

# ============================================================================
head1 "6. A different Josh comment never authorises a start"
# ============================================================================
new_scenario josh_wrong_text
write_config "$(jq -nc --arg cv aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa '{pm_start_enabled:true, interim_comment_approval:{paperclip_commit:$cv}}')"
route GET /api/health 200 '{"commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
JARVIS="88888888-8888-8888-8888-888888888888"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
mkdir -p "$STATE/paperclip"
jq -n --arg a "$AGENT1" --arg id "$ISSUE1" \
  '{issues: {($id): {host_agent_id: $a, paperclip_project_id: "aaaaaaaa-0000-4000-8000-000000000001", slug: "proj", identifier: "PROJ-1", state: "pending_claim", since: "2026-01-01T00:00:00Z"}},
    stranded_reported: [], drain_tampered_reported: false, last_successful_pass: null}' \
  >"$STATE/paperclip/ledger.json"
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"blocked\",\"identifier\":\"PROJ-1\",\"title\":\"T\",\"description\":\"D\",\"createdByUserId\":\"$JARVIS\",\"projectId\":\"$PROJ1\",\"unblockDescriptor\":{\"owner\":{\"agentId\":\"$AGENT1\"},\"action\":\"paused\"}}"
route GET "/api/issues/$ISSUE1/comments" 200 \
  "[{\"id\":\"c0000000-0000-0000-0000-00000000000a\",\"body\":\"sounds good\",\"authorUserId\":\"$BOARD\",\"authorAgentId\":null,\"createdAt\":\"2026-02-01T00:00:00Z\"}]"
route POST "/api/issues/$ISSUE1/comments" 201 '{}'
run_afk paperclip-poll --json
assert_eq "wrong text: no terminal create" "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" "0"

# ============================================================================
head1 "7. Daily cap reached -> no create"
# ============================================================================
new_scenario cap_reached
write_config "$(jq -nc '{pm_start_enabled:true, pm_start_daily_cap:1}')"
mkdir -p "$STATE/paperclip"
TODAY="$(date -u +%Y-%m-%d)"
jq -nc --arg d "$TODAY" '{issues:{}, stranded_reported:[], drain_tampered_reported:false, last_successful_pass:null, pm_starts:{($d):1}}' \
  >"$STATE/paperclip/ledger.json"
issue_route in_progress "$BOARD"
do_pass
assert_eq "cap reached: no terminal create" "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" "0"
LEDGER="$STATE/paperclip/ledger.json"
assert_contains "cap reached: action text names the cap" \
  "$(jq -r --arg id "$ISSUE1" '.issues[$id].action_text' "$LEDGER")" "start cap reached"

# ============================================================================
head1 "8. Readiness failing -> no create, the code is carried"
# ============================================================================
new_scenario not_ready
write_config '{"pm_start_enabled":true}'
READINESS_OK=false READINESS_REASON=REPO_DIRTY
issue_route in_progress "$BOARD"
do_pass
READINESS_OK=true READINESS_REASON=
assert_eq "not ready: no terminal create" "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" "0"
LEDGER="$STATE/paperclip/ledger.json"
assert_contains "not ready: action text carries the code" \
  "$(jq -r --arg id "$ISSUE1" '.issues[$id].action_text' "$LEDGER")" "REPO_DIRTY"

new_scenario not_ready_exit0
write_config '{"pm_start_enabled":true}'
READINESS_OK=integrity
issue_route in_progress "$BOARD"
do_pass
READINESS_OK=true
assert_eq "not ready (exit 0): no terminal create" "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" "0"
assert_contains "not ready (exit 0): action text carries the code" \
  "$(jq -r --arg id "$ISSUE1" '.issues[$id].action_text' "$STATE/paperclip/ledger.json")" "INTEGRITY_DRIFT"

# ============================================================================
head1 "9. paperclip-timer install/status/remove"
# ============================================================================
new_scenario timer_linux
write_config '{}'
# The unit gets no token: the key must be readable from the op env file alone.
run_afk paperclip-timer --install --json
assert_eq "install without an op env file: refused" "$RC" "1"
assert_contains "install without an op env file: PAPERCLIP_VAULT_UNAVAILABLE" "$OUT_TEXT" "PAPERCLIP_VAULT_UNAVAILABLE"
assert_eq "install refused: no unit written" "$(test -e "$SCEN/systemd-user/afk-paperclip-poll.service" && echo yes || echo no)" "no"
run_afk paperclip-timer --status --json
assert_contains "status without an op env file: PAPERCLIP_VAULT_UNAVAILABLE" "$OUT_TEXT" "PAPERCLIP_VAULT_UNAVAILABLE"
printf 'OP_SERVICE_ACCOUNT_TOKEN=ops_FILE-TOKEN\n' >"$HOME/.op-agent-env"; chmod 600 "$HOME/.op-agent-env"
run_afk paperclip-timer --install --json
assert_eq "install: exit 0" "$RC" "0"
UNIT="$SCEN/systemd-user/afk-paperclip-poll.timer"
assert_eq "install: OnUnitActiveSec=90s" "$(grep -c '^OnUnitActiveSec=90s$' "$UNIT")" "1"
assert_eq "install: OnActiveSec=90s" "$(grep -c '^OnActiveSec=90s$' "$UNIT")" "1"
assert_eq "install: RandomizedDelaySec=15s" "$(grep -c '^RandomizedDelaySec=15s$' "$UNIT")" "1"
assert_eq "install: Persistent=false" "$(grep -c '^Persistent=false$' "$UNIT")" "1"
SVC="$SCEN/systemd-user/afk-paperclip-poll.service"
assert_absent "install: the service holds no secret" "$(cat "$SVC" "$UNIT")" "op://"
assert_absent "install: the service holds no key reference" "$(cat "$SVC" "$UNIT")" "KEY"
assert_absent "install: the service holds no token" "$(cat "$SVC" "$UNIT")" "FILE-TOKEN"
assert_absent "install: the service names no op env file" "$(cat "$SVC" "$UNIT")" "op-agent-env"

run_afk paperclip-timer --status --json
assert_contains "status: reports PAPERCLIP_POLLER_STALE with no pass yet" "$OUT_TEXT" "PAPERCLIP_POLLER_STALE"

mkdir -p "$STATE/paperclip"
jq -nc --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{issues:{}, stranded_reported:[], drain_tampered_reported:false, last_successful_pass:$t}' \
  >"$STATE/paperclip/ledger.json"
run_afk paperclip-timer --status --json
assert_absent "status: a fresh pass is not stale" "$OUT_TEXT" "PAPERCLIP_POLLER_STALE"

OLD="$(date -u -d '-1000 seconds' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1000S +%Y-%m-%dT%H:%M:%SZ)"
jq -nc --arg t "$OLD" '{issues:{}, stranded_reported:[], drain_tampered_reported:false, last_successful_pass:$t}' \
  >"$STATE/paperclip/ledger.json"
run_afk paperclip-timer --status --json
assert_contains "status: an old pass (>3 intervals) is stale" "$OUT_TEXT" "PAPERCLIP_POLLER_STALE"

run_afk paperclip-timer --remove --json
assert_eq "remove: exit 0" "$RC" "0"
assert_eq "remove: the timer unit is gone" "$(test -e "$UNIT" && echo yes || echo no)" "no"
assert_eq "remove: the service unit is gone" "$(test -e "$SVC" && echo yes || echo no)" "no"

# ============================================================================
head1 "9b. The timer check reads the key with the user manager's environment"
# ============================================================================
# mgr_scenario <name> -- a config, no default op env file, and a manager bin
# directory with bash, jq, stat and id but no op.
mgr_scenario() {
  new_scenario "$1"; write_config '{}'
  MGRBIN="$SCEN/mgrbin"; mkdir -p "$MGRBIN"
  for b in bash jq stat id; do ln -s "$(command -v "$b")" "$MGRBIN/$b"; done
  SYSTEMCTL_SHOWENV="$SCEN/showenv"
}
envfile600() { printf 'OP_SERVICE_ACCOUNT_TOKEN=ops_FILE-TOKEN\n' >"$1"; chmod 600 "$1"; }

mgr_scenario mgr_no_op
envfile600 "$HOME/.op-agent-env"
printf 'PATH=%s\n' "$MGRBIN" >"$SYSTEMCTL_SHOWENV"
run_afk paperclip-timer --status --json
assert_contains "the caller's AFK_OP_BIN does not count: no op on the manager PATH" "$OUT_TEXT" "PAPERCLIP_VAULT_UNAVAILABLE"
printf 'PATH=%s\nAFK_OP_BIN=%s\n' "$MGRBIN" "$STUBS/op" >"$SYSTEMCTL_SHOWENV"
run_afk paperclip-timer --status --json
assert_absent "the manager's AFK_OP_BIN counts" "$OUT_TEXT" "PAPERCLIP_VAULT_UNAVAILABLE"
assert_contains "the manager's AFK_OP_BIN: the check passed (only staleness left)" "$OUT_TEXT" "PAPERCLIP_POLLER_STALE"

mgr_scenario mgr_token
printf 'PATH=%s\nOP_SERVICE_ACCOUNT_TOKEN=ops_MGR-TOKEN\n' "$STUBS:/usr/bin:/bin" >"$SYSTEMCTL_SHOWENV"
run_afk paperclip-timer --install --json
assert_eq "a token in the manager's environment: install succeeds" "$RC" "0"
assert_absent "a manager token never lands in the unit" "$(cat "$SCEN/systemd-user/"* 2>/dev/null)" "MGR-TOKEN"
assert_absent "a manager token is never printed" "$OUT_TEXT" "MGR-TOKEN"

mgr_scenario mgr_env_file
envfile600 "$SCEN/mgr.env"
printf 'PATH=%s\nAFK_OP_ENV_FILE=%s\n' "$STUBS:/usr/bin:/bin" "$SCEN/mgr.env" >"$SYSTEMCTL_SHOWENV"
run_afk paperclip-timer --install --json
assert_eq "AFK_OP_ENV_FILE in the manager's environment: install succeeds" "$RC" "0"

mgr_scenario unit_cfg_env_file
envfile600 "$SCEN/cfg.env"
jq --arg f "$SCEN/cfg.env" '.host.op_env_file = $f' "$CONFIG" >"$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
printf 'PATH=%s\n' "$STUBS:/usr/bin:/bin" >"$SYSTEMCTL_SHOWENV"
run_afk paperclip-timer --install --json
assert_eq "host.op_env_file is honoured by the unit check" "$RC" "0"

mgr_scenario unit_symlink
envfile600 "$SCEN/target.env"; ln -s "$SCEN/target.env" "$HOME/.op-agent-env"
printf 'PATH=%s\n' "$STUBS:/usr/bin:/bin" >"$SYSTEMCTL_SHOWENV"
run_afk paperclip-timer --install --json
assert_eq "a symlink to a mode-600 env file is followed" "$RC" "0"
chmod 644 "$SCEN/target.env"
run_afk paperclip-timer --status --json
assert_contains "a symlink to a mode-644 env file is PAPERCLIP_OP_ENV_UNSAFE" "$OUT_TEXT" "PAPERCLIP_OP_ENV_UNSAFE"
SYSTEMCTL_SHOWENV=""

# ============================================================================
head1 "10. macOS refuses paperclip-timer"
# ============================================================================
new_scenario timer_mac
write_config '{}'
out="$(env -i PATH="$STUBS:$PATH" HOME="$HOME" LANG=C AFK_STATE_DIR="$STATE" AFK_PAPERCLIP_CONFIG="$CONFIG" \
  bash -c '
    uname() { echo Darwin; }
    export -f uname
    exec "'"$AFK"'" paperclip-timer --install --json
  ' 2>&1)"
assert_contains "macOS: install refused" "$out" "PAPERCLIP_TIMER_UNSUPPORTED_PLATFORM"

# ============================================================================
head1 "11. AC-7b: a stale poll lock is reaped and removed"
# ============================================================================
new_scenario stale_lock
write_config '{"pm_start_enabled":true}'
mkdir -p "$STATE/paperclip"
LOCKDIR="$STATE/paperclip/.lock"
mkdir -p "$LOCKDIR"
printf '999999 0\n' >"$LOCKDIR/owner" # a PID that is certainly not alive
touch -d '-1000 seconds' "$LOCKDIR" 2>/dev/null || touch -t "$(date -v-1000S +%Y%m%d%H%M.%S)" "$LOCKDIR"
issue_route in_progress "$BOARD"
do_pass
assert_eq "stale lock: the pass proceeds instead of reporting busy" "$RC" "0"
assert_absent "stale lock: PAPERCLIP_POLL_BUSY is not reported" "$OUT_TEXT" "PAPERCLIP_POLL_BUSY"

# An old lock whose owner is a live paperclip-poll is never reaped.
new_scenario live_lock
write_config '{"pm_start_enabled":true}'
mkdir -p "$STATE/paperclip/.lock"
bash -c 'sleep 30; :' paperclip-poll & LIVE_PID=$!
printf '%s 0\n' "$LIVE_PID" >"$STATE/paperclip/.lock/owner"
touch -d '-1000 seconds' "$STATE/paperclip/.lock"
issue_route in_progress "$BOARD"
do_pass
kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null
assert_contains "live lock: still busy" "$OUT_TEXT" "PAPERCLIP_POLL_BUSY"
assert_eq "live lock: the lock stays" "$([[ -d "$STATE/paperclip/.lock" ]] && echo yes)" "yes"

# A reused PID (alive, but not a paperclip-poll) does not pin the lock.
new_scenario reused_pid_lock
write_config '{"pm_start_enabled":true}'
mkdir -p "$STATE/paperclip/.lock"
sleep 30 & OTHER_PID=$!
printf '%s 0\n' "$OTHER_PID" >"$STATE/paperclip/.lock/owner"
touch -d '-1000 seconds' "$STATE/paperclip/.lock"
issue_route in_progress "$BOARD"
do_pass
kill "$OTHER_PID" 2>/dev/null; wait "$OTHER_PID" 2>/dev/null
assert_absent "reused pid: not busy" "$OUT_TEXT" "PAPERCLIP_POLL_BUSY"
assert_contains "reused pid: PAPERCLIP_LOCK_STALE reported" "$OUT_TEXT" "PAPERCLIP_LOCK_STALE"

# ============================================================================
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
