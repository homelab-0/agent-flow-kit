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

# op succeeds only with a service-account token, like the real one.
cat >"$STUBS/op" <<'SH'
#!/usr/bin/env bash
[[ "$1" == read && -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]] || exit 2
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
post_body=""
for ((i = 0; i < n; i++)); do
  [[ "${args[$i]}" == -X ]] && method="${args[$((i + 1))]}"
done
url="${args[$((n - 1))]}"
tmp="${url#*://}"
path="/${tmp#*/}"
printf '%s %s\n' "$method" "$path" >>"$CURL_STUB_LOG"
env >>"$CURL_STUB_LOG.env" # a child that is not op: it must never see the token
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
    post_body="$(cat "${args[$((i + 1))]#@}")"
    printf '%s\n---\n' "$post_body" >>"$CURL_STUB_BODYLOG"
  fi
done
key="${method}_${path#/}"; key="${key//\//_}"
f="$CURL_STUB_FIXTURES/$key"
claim_store="$CURL_STUB_FIXTURES/.claim_${path//\//_}"
# route_nth: a per-route call counter picks "<key>.<n>" for the n-th call.
cnt="$(( $(cat "$CURL_STUB_FIXTURES/.n_$key" 2>/dev/null || printf 0) + 1 ))"
printf '%s' "$cnt" >"$CURL_STUB_FIXTURES/.n_$key"
[[ -f "$f.$cnt" ]] && f="$f.$cnt"
[[ -f "$f" ]] || f="$CURL_STUB_FIXTURES/DEFAULT"
if [[ ! -f "$f" ]]; then
  if [[ "$method" == GET && "$path" == */comments && -f "$claim_store" ]]; then
    cat "$claim_store"; printf 200; exit 0
  fi
  printf '000'; exit 0
fi
code="$(head -1 "$f")"
[[ "$code" == NETFAIL ]] && exit 7
# Inject a failure at the durable hold write, after the final PATCH returns.
if [[ -f "$CURL_STUB_FIXTURES/.fail_hold_write" && "$method" == PATCH && "$code" == 422 ]]; then
  mkdir -p "$AFK_STATE_DIR/paperclip/ledger.json.afk-tmp"
fi
if [[ "$method" == POST && "$path" == */comments && "$code" == 2?? &&
      ! -f "$CURL_STUB_FIXTURES/.claim_readback_off" ]] &&
   jq -e '.body | strings | contains("<!-- afk-claim:")' <<<"$post_body" >/dev/null 2>&1; then
  [[ -f "$claim_store" ]] || printf '[]\n' >"$claim_store"
  claim_body="$(jq -r '.body' <<<"$post_body")"
  jq -c --arg b "$claim_body" --arg a "$CURL_STUB_AGENT" '. + [{body:$b,authorAgentId:$a}]' \
    "$claim_store" >"$claim_store.tmp" && mv "$claim_store.tmp" "$claim_store"
fi
# An issue detail with no projectId key gets the scenario's default project
# (write_config), so every fixture is in a mapped project unless it says
# otherwise; `"projectId": null` in a fixture is served as written.
if [[ "$method" == GET && "$path" == */comments && "$code" == 200 && -f "$claim_store" ]]; then
  jq -cs '.[0] + .[1]' <(tail -n +2 "$f") "$claim_store"
elif [[ "$method" == GET && "$path" =~ ^/api/issues/[0-9a-f-]{36}$ && -f "$CURL_STUB_FIXTURES/.default_project" ]] &&
   ! grep -q '"projectId"' "$f" && tail -n +2 "$f" | jq -e 'type == "object"' >/dev/null 2>&1; then
  tail -n +2 "$f" | jq -c --arg p "$(cat "$CURL_STUB_FIXTURES/.default_project")" '. + {projectId: $p}'
# A /me with no runtimeConfig key reports a lease-mode heartbeat (AD-26);
# `"runtimeConfig": null` in a fixture is served as written.
elif [[ "$method" == GET && "$path" == /api/agents/me ]] && ! grep -q '"runtimeConfig"' "$f" &&
     tail -n +2 "$f" | jq -e 'type == "object"' >/dev/null 2>&1; then
  tail -n +2 "$f" | jq -c '. + {runtimeConfig: {heartbeat: {enabled: true, intervalSec: 0, wakeOnDemand: true}}}'
else
  tail -n +2 "$f"
fi
printf '%s' "$code"
SH
# stat passes through to the real one. When $TMPROOT/stat-swap names
# "<replacement> <path>", the first stat of that path or of an open fd then
# moves the replacement over the path: a swap right after the check.
cat >"$STUBS/stat" <<SH
#!/usr/bin/env bash
$(command -v stat) "\$@"; rc=\$?
if read -r src dst 2>/dev/null <"$TMPROOT/stat-swap"; then
  for a in "\$@"; do
    if [[ "\$a" == /dev/fd/* || "\$a" == "\$dst" ]]; then rm -f "$TMPROOT/stat-swap"; mv -f "\$src" "\$dst"; break; fi
  done
fi
exit \$rc
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

# OPTOK: the token an interactive shell carries; empty models the timer's
# unit. OPENV: an op env file path passed as AFK_OP_ENV_FILE.
OPTOK="test-op-token" OPENV=""
RC=0 OUT_TEXT=""
run_afk() { # [--json]
  local out err
  local -a extra=()
  [[ -n "${1:-}" ]] && extra=("$1")
  out="$(env -i PATH="$STUBS:$PATH" HOME="$HOME" LANG=C \
    AFK_STATE_DIR="$STATE" AFK_PAPERCLIP_CONFIG="$CONFIG" \
    AFK_OP_BIN="$STUBS/op" AFK_CURL_BIN="$STUBS/curl" ${OPTOK:+OP_SERVICE_ACCOUNT_TOKEN="$OPTOK"} \
    ${OPENV:+AFK_OP_ENV_FILE="$OPENV"} \
    CURL_STUB_LOG="$LOG" CURL_STUB_KEYLOG="$KEYLOG" CURL_STUB_BODYLOG="$BODYLOG" CURL_STUB_FIXTURES="$FIXDIR" \
    CURL_STUB_AGENT="$AGENT1" \
    bash ${AFK_XTRACE:+-x} "$AFK" paperclip-poll "${extra[@]}" 2>"$SCEN/err")"
  RC=$?
  err="$(cat "$SCEN/err")"
  OUT_TEXT="$out"$'\n'"$err"
}

COMPANY="cccccccc-cccc-cccc-cccc-cccccccccccc"
# Real Paperclip board user ids are Better-Auth style ids, not UUIDs
# (AFK-PC-FIX-2) -- keep this fixture in that shape so the suite exercises
# the real format, not just a UUID that happens to also be a valid id.
BOARD="emXp8Svi8ncWyL1EORTkRNQYjFjCdQon"
AGENT1="11111111-1111-1111-1111-111111111111"
AGENT2="22222222-2222-2222-2222-222222222222"
MAINT="dddddddd-dddd-dddd-dddd-dddddddddddd"
STRANGER="99999999-9999-9999-9999-999999999999"

PROJ1="aaaaaaaa-0000-4000-8000-000000000001"
PROJ2="aaaaaaaa-0000-4000-8000-000000000002"

# mkrepo <path> -- a git repo whose default branch carries .afk/gates-allowlist,
# with an origin remote, so it resolves as ready (AD-23 REPO_NOT_READY).
mkrepo() {
  mkdir -p "$1"
  git -C "$1" init -q -b main
  mkdir -p "$1/.afk"; printf 'bash tests/run-tests.sh\n' >"$1/.afk/gates-allowlist"
  git -C "$1" add .afk/gates-allowlist
  git -C "$1" -c user.name=t -c user.email=t@t commit -qm init
  git -C "$1" remote add origin "git@github.com:test/${1##*/}.git"
}
REPO1="$TMPROOT/repos/repo1"; mkrepo "$REPO1"
REPO2="$TMPROOT/repos/repo2"; mkrepo "$REPO2"

proj_json() { # <project-id> <slug> <repo> [max_active]
  jq -nc --arg p "$1" --arg s "$2" --arg r "$3" --argjson m "${4:-1}" \
    '{paperclip_project_id:$p, slug:$s, repo_path:$r, harness:"claude", max_active_issues:$m}'
}

project_body() { # <project-id> <name> [<archivedAt>] [<repoUrl>]
  jq -nc --arg p "$1" --arg n "$2" --arg a "${3:-}" --arg u "${4:-}" \
    '{id:$p, name:$n, archivedAt:(if $a == "" then null else $a end),
      codebase:{repoUrl:(if $u == "" then null else $u end)}}'
}

# write_config [<projects-json-array>] -- a v2 host config (AD-23). The first
# project becomes the stub's default projectId for issue details, and every
# project is served as a live, unarchived project.
write_config() {
  local projects="${1:-[$(proj_json "$PROJ1" proj "$REPO1")]}" pid
  jq -n --arg api "https://paperclip.test" --arg co "$COMPANY" --arg bu "$BOARD" \
    --arg ag "$AGENT1" --argjson projects "$projects" \
    '{schema: "afk-paperclip-config/2", api_url: $api, company_id: $co, board_user_id: $bu,
      host: {label: "test-host", agent_id: $ag, key_ref: "op://test/agent1"}, projects: $projects}' \
    >"$CONFIG"
  jq -r '.[0].paperclip_project_id // empty' <<<"$projects" >"$FIXDIR/.default_project"
  [[ -s "$FIXDIR/.default_project" ]] || rm -f "$FIXDIR/.default_project"
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && route GET "/api/projects/$pid" 200 "$(project_body "$pid" "Project ${pid:0:8}")"
  done < <(jq -r '.[].paperclip_project_id' <<<"$projects")
}

write_config_maint() { # <maint-id> [<projects-json-array>]
  write_config "${2:-}"
  jq --arg mi "$1" '.maintenance_issue_id = $mi' "$CONFIG" >"$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
}

set_cfg() { jq "$1" "$CONFIG" >"$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"; }

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
write_config
jq '.company_id = "not-a-uuid"' "$CONFIG" >"$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
run_afk
assert_eq "bad company_id: non-zero exit" "$RC" "1"
assert_eq "bad company_id: no request made" "$(cat "$LOG" 2>/dev/null)" ""
assert_contains "bad company_id: reason" "$OUT_TEXT" "PAPERCLIP_ID_INVALID"

new_scenario cfg_board_literal
write_config
jq '.board_user_id = "board"' "$CONFIG" >"$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
run_afk
assert_contains "board_user_id 'board' refused" "$OUT_TEXT" "PAPERCLIP_ID_INVALID"

new_scenario cfg_board_real_format
write_config
jq '.board_user_id = "emXp8Svi8ncWyL1EORTkRNQYjFjCdQon"' "$CONFIG" >"$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET "/api/agents/me/inbox-lite" 200 "[]"
run_afk
assert_eq "board_user_id real-format id (32-char Better-Auth style) accepted" "$RC" "0"

new_scenario cfg_board_slash
write_config
jq '.board_user_id = "a/b"' "$CONFIG" >"$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
run_afk
assert_eq "board_user_id 'a/b': non-zero exit" "$RC" "1"
assert_eq "board_user_id 'a/b': no request made" "$(cat "$LOG" 2>/dev/null)" ""
assert_contains "board_user_id 'a/b' refused" "$OUT_TEXT" "PAPERCLIP_ID_INVALID"

new_scenario cfg_board_spaces
write_config
jq '.board_user_id = "has a space"' "$CONFIG" >"$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
run_afk
assert_eq "board_user_id with spaces: non-zero exit" "$RC" "1"
assert_eq "board_user_id with spaces: no request made" "$(cat "$LOG" 2>/dev/null)" ""
assert_contains "board_user_id with spaces refused" "$OUT_TEXT" "PAPERCLIP_ID_INVALID"

new_scenario cfg_duplicate
write_config "[$(proj_json "$PROJ1" proj "$REPO1"), $(proj_json "$PROJ1" proj2 "$REPO2")]"
run_afk
assert_contains "duplicate project id refused" "$OUT_TEXT" "PAPERCLIP_CONFIG_INVALID"

new_scenario cfg_http_url
write_config
jq '.api_url = "http://paperclip.test"' "$CONFIG" >"$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
run_afk
assert_eq "non-https api_url: non-zero exit" "$RC" "1"
assert_eq "non-https api_url: no request made" "$(cat "$LOG" 2>/dev/null)" ""
assert_contains "non-https api_url refused" "$OUT_TEXT" "PAPERCLIP_CONFIG_INVALID"

new_scenario cfg_paperclip_commit_short_sha
write_config
jq '.interim_comment_approval = {paperclip_commit: "4a1b2c3"}' "$CONFIG" >"$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
run_afk
assert_eq "short-SHA paperclip_commit: non-zero exit" "$RC" "1"
assert_eq "short-SHA paperclip_commit: no request made" "$(cat "$LOG" 2>/dev/null)" ""
assert_contains "short-SHA paperclip_commit refused" "$OUT_TEXT" "PAPERCLIP_CONFIG_INVALID"

new_scenario cfg_paperclip_commit_uppercase
write_config
jq '.interim_comment_approval = {paperclip_commit: "4A1B2C3D4E5F60718293A4B5C6D7E8F9A0B1C2D3"}' "$CONFIG" >"$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
run_afk
assert_contains "uppercase paperclip_commit refused" "$OUT_TEXT" "PAPERCLIP_CONFIG_INVALID"

new_scenario cfg_paperclip_commit_valid
write_config
jq '.interim_comment_approval = {paperclip_commit: "4a1b2c3d4e5f60718293a4b5c6d7e8f9a0b1c2d3"}' "$CONFIG" >"$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET /api/agents/me/inbox-lite 200 "[]"
run_afk
assert_eq "valid 40-hex paperclip_commit: config accepted" "$RC" "0"

# ============================================================================
head1 "2. Key handling (AC-2)"
# ============================================================================
new_scenario key_unreadable
write_config; set_cfg '.host.key_ref = "op://test/badref"'
run_afk --json
assert_contains "unreadable key -> PAPERCLIP_VAULT_UNAVAILABLE" "$OUT_TEXT" "PAPERCLIP_VAULT_UNAVAILABLE"
assert_eq "unreadable key: no HTTP call for that agent" "$(cat "$LOG" 2>/dev/null)" ""

new_scenario key_mismatch
write_config
route GET /api/agents/me 200 '{"id":"22222222-2222-2222-2222-222222222222"}'
run_afk --json
assert_contains "agent/key mismatch reason" "$OUT_TEXT" "PAPERCLIP_KEY_AGENT_MISMATCH"

new_scenario key_ambiguous_me
write_config
route GET /api/agents/me 503 ''
run_afk --json
assert_contains "ambiguous /me -> unreachable, never a credential refusal" "$OUT_TEXT" "unreachable"
assert_absent "ambiguous /me is never reported as a credential refusal" "$OUT_TEXT" "MISMATCH"

new_scenario key_never_logged
write_config
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET /api/agents/me/inbox-lite 200 '[]'
run_afk --json
assert_absent "the key never appears in the request log" "$(cat "$LOG")" "KEY-AGENT1-SECRET-VALUE"
assert_absent "the key never appears in stdout/stderr" "$OUT_TEXT" "KEY-AGENT1-SECRET-VALUE"
assert_absent "the key never appears in the ledger" "$(cat "$STATE/paperclip/ledger.json" 2>/dev/null)" "KEY-AGENT1-SECRET-VALUE"
assert_contains "the key WAS actually sent (control on the assertion above)" "$(cat "$KEYLOG")" "KEY-AGENT1-SECRET-VALUE"

# Same, through a full adoption (argv, notices, brief) and under `bash -x`.
new_scenario key_never_logged_xtrace
write_config
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
head1 "2b. The key without an interactive shell's token"
# ============================================================================
# key_scenario <name> -- a pass that reaches the inbox once the key is read.
key_scenario() {
  new_scenario "$1"; write_config
  route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
  route GET /api/agents/me/inbox-lite 200 '[]'
}
envfile() { # <path> <mode>
  mkdir -p "$(dirname "$1")"
  printf 'OP_SERVICE_ACCOUNT_TOKEN=ops_FILE-TOKEN-SECRET\n' >"$1"; chmod "$2" "$1"
}

key_scenario key_env_token
run_afk --json
assert_contains "token in the environment: the key is read" "$(cat "$KEYLOG")" "KEY-AGENT1-SECRET-VALUE"

key_scenario key_env_file
envfile "$HOME/.op-agent-env" 600
OPTOK="" AFK_XTRACE=1 run_afk --json
assert_contains "no token, mode-600 env file: the key is read" "$(cat "$KEYLOG")" "KEY-AGENT1-SECRET-VALUE"
assert_eq "no token, mode-600 env file: the pass completes" "$RC" "0"
assert_contains "control: curl's environment was recorded" "$(cat "$LOG.env")" "CURL_STUB_LOG="
assert_absent "the token never reaches a child that is not op" "$(cat "$LOG.env")" "FILE-TOKEN-SECRET"
assert_absent "the token never appears under bash -x" "$OUT_TEXT" "FILE-TOKEN-SECRET"

key_scenario key_env_file_644
envfile "$HOME/.op-agent-env" 644
printf 'touch %q\n' "$SCEN/sourced" >>"$HOME/.op-agent-env"
OPTOK="" run_afk --json
assert_contains "a mode-644 env file is refused" "$OUT_TEXT" "PAPERCLIP_OP_ENV_UNSAFE"
assert_missing "a mode-644 env file is never sourced" "$SCEN/sourced"
assert_absent "the refusal never prints the file's contents" "$OUT_TEXT" "FILE-TOKEN-SECRET"
assert_eq "a refused env file: no HTTP call" "$(cat "$LOG")" ""

key_scenario key_env_swap
envfile "$HOME/.op-agent-env" 600
printf 'OP_SERVICE_ACCOUNT_TOKEN=ops_SWAPPED\ntouch %q\n' "$SCEN/swapped-sourced" >"$SCEN/swap.env"; chmod 600 "$SCEN/swap.env"
printf '%s %s\n' "$SCEN/swap.env" "$HOME/.op-agent-env" >"$TMPROOT/stat-swap"
OPTOK="" run_afk --json
assert_missing "control: the path was swapped after the check" "$TMPROOT/stat-swap"
assert_missing "a file swapped in after the check is never sourced" "$SCEN/swapped-sourced"
assert_contains "the checked file is the one sourced: the key is read" "$(cat "$KEYLOG")" "KEY-AGENT1-SECRET-VALUE"

key_scenario key_env_missing
OPTOK="" run_afk --json
assert_contains "no token, no env file -> PAPERCLIP_VAULT_UNAVAILABLE" "$OUT_TEXT" "PAPERCLIP_VAULT_UNAVAILABLE"

key_scenario key_env_var
envfile "$SCEN/elsewhere.env" 600
OPTOK="" OPENV="$SCEN/elsewhere.env" run_afk --json
assert_contains "AFK_OP_ENV_FILE replaces the default path" "$(cat "$KEYLOG")" "KEY-AGENT1-SECRET-VALUE"

key_scenario key_env_override
envfile "$SCEN/elsewhere.env" 600
set_cfg ".host.op_env_file = \"$SCEN/elsewhere.env\""
OPTOK="" OPENV="$SCEN/nowhere.env" run_afk --json
assert_contains "host.op_env_file overrides the default" "$(cat "$KEYLOG")" "KEY-AGENT1-SECRET-VALUE"

key_scenario key_env_relative
set_cfg '.host.op_env_file = "relative/op.env"'
run_afk --json
assert_contains "a relative host.op_env_file is PAPERCLIP_CONFIG_INVALID" "$OUT_TEXT" "PAPERCLIP_CONFIG_INVALID"

# ============================================================================
head1 "3. Lock (AC-3)"
# ============================================================================
new_scenario lock_busy
write_config
mkdir -p "$STATE/paperclip/.lock"
run_afk
assert_eq "lock held: exit 0 (busy is not a failure)" "$RC" "0"
assert_contains "lock held: reason" "$OUT_TEXT" "PAPERCLIP_POLL_BUSY"
assert_eq "lock held: no request made" "$(cat "$LOG" 2>/dev/null)" ""

new_scenario lock_quote_path
STATE="$SCEN/ho'me/.local/state/agent-flow-kit"; mkdir -p "$STATE"
write_config
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
write_config
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
write_config
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
write_config
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
mkdir -p "$STATE/paperclip"
jq -n --arg a "$AGENT1" --arg id "$ISSUE1" \
  '{issues: {($id): {host_agent_id: $a, paperclip_project_id: "aaaaaaaa-0000-4000-8000-000000000001", slug: "proj", identifier: "PROJ-1", state: "working", since: "2026-01-01T00:00:00Z", action_text: "AFK host is working on this"}},
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
write_config
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
mkdir -p "$STATE/paperclip"
jq -n --arg a "$AGENT1" --arg id "$ISSUE1" \
  '{issues: {($id): {host_agent_id: $a, paperclip_project_id: "aaaaaaaa-0000-4000-8000-000000000001", slug: "proj", identifier: "PROJ-1", state: "working", since: "2026-01-01T00:00:00Z", action_text: "AFK host is working on this"}},
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
write_config
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
mkdir -p "$STATE/paperclip"
jq -n --arg a "$AGENT1" --arg id "$ISSUE1" \
  '{issues: {($id): {host_agent_id: $a, paperclip_project_id: "aaaaaaaa-0000-4000-8000-000000000001", slug: "proj", identifier: "PROJ-1", state: "working", since: "2026-01-01T00:00:00Z", action_text: "AFK host is working on this"}},
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
write_config
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
mkdir -p "$STATE/paperclip"
jq -n --arg a "$AGENT1" --arg id "$ISSUE1" \
  '{issues: {($id): {host_agent_id: $a, paperclip_project_id: "aaaaaaaa-0000-4000-8000-000000000001", slug: "proj", identifier: "PROJ-1", state: "working", since: "x", action_text: "y"}},
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
write_config
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
mkdir -p "$STATE/paperclip"
jq -n --arg a "$AGENT1" --arg id "$ISSUE1" \
  '{issues: {($id): {host_agent_id: $a, paperclip_project_id: "aaaaaaaa-0000-4000-8000-000000000001", slug: "proj", identifier: "PROJ-1", state: "working", since: "2026-01-01T00:00:00Z", action_text: "AFK host is working on this"}},
    stranded_reported: [], drain_tampered_reported: false, last_successful_pass: null}' \
  >"$STATE/paperclip/ledger.json"
route GET "/api/agents/me/inbox-lite" 200 '[]'
run_afk --json
assert_eq "closed: ledger state" "$(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$STATE/paperclip/ledger.json")" "closed"
assert_eq "closed: one stopped notice" \
  "$(find "$STATE/paperclip/notices/proj" -name '*.stopped.json' 2>/dev/null | wc -l | tr -d ' ')" "1"

new_scenario close_and_new_same_pass
write_config
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
mkdir -p "$STATE/paperclip"
jq -n --arg a "$AGENT1" --arg id "$ISSUE1" \
  '{issues: {($id): {host_agent_id: $a, paperclip_project_id: "aaaaaaaa-0000-4000-8000-000000000001", slug: "proj", identifier: "PROJ-1", state: "working", since: "2026-01-01T00:00:00Z", action_text: "AFK host is working on this"}},
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
write_config
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
write_config
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
write_config_maint "$MAINT"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET "/api/issues/$MAINT" NETFAIL
route GET "/api/agents/me/inbox-lite" 200 '[]'
run_afk --json
assert_contains "drain unreadable -> paused" "$OUT_TEXT" "PAPERCLIP_PAUSED"

new_scenario drain_tampered
write_config_maint "$MAINT"
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
head1 "9. One host key for every project (HA-1a AC-2)"
# ============================================================================
new_scenario one_host_key
write_config "[$(proj_json "$PROJ1" proj "$REPO1"), $(proj_json "$PROJ2" proj2 "$REPO2")]"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET "/api/agents/me/inbox-lite" 200 '[]'
run_afk --json
assert_eq "two projects, one host: pass completed" "$RC" "0"
assert_eq "the inbox is read once per pass, not once per project" "$(grep -c '^GET /api/agents/me/inbox-lite$' "$LOG")" "1"
assert_eq "only the host key was ever sent" "$(sort -u "$KEYLOG")" "KEY-AGENT1-SECRET-VALUE"

# ============================================================================
head1 "10. Unreachable pass (AC-3)"
# ============================================================================
new_scenario unreachable
write_config
route GET /api/agents/me NETFAIL
run_afk --json
assert_eq "unreachable: non-zero exit" "$RC" "1"
assert_missing "unreachable: ledger was not written" "$STATE/paperclip/ledger.json"

# ============================================================================
head1 "11. Paperclip-initiated wakes (AC-5a amendment)"
# ============================================================================
wake_scenario() { # <name> <wake-reason-json-or-empty>
  new_scenario "$1"
  write_config
  route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
  mkdir -p "$STATE/paperclip"
  jq -n --arg a "$AGENT1" --arg id "$ISSUE1" \
    '{issues: {($id): {host_agent_id: $a, paperclip_project_id: "aaaaaaaa-0000-4000-8000-000000000001", slug: "proj", identifier: "PROJ-1", state: "working", since: "2026-01-01T00:00:00Z", action_text: "AFK host is working on this"}},
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
write_config
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET /api/agents/me/inbox-lite 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 '{"status":"in_progress","identifier":"PROJ-1","title":"T","description":"D","updatedAt":"x"}'
route GET "/api/issues/$ISSUE1/active-run" 200 '{"id":"run-1"}'
route POST "/api/issues/$ISSUE1/comments" 201 '{}'
route PATCH "/api/issues/$ISSUE1" 500 '{}'
run_afk --json
assert_contains "a failed self-block is reported, never silent" "$OUT_TEXT" "PAPERCLIP_SELF_BLOCK_FAILED"

new_scenario no_live_run
write_config
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET /api/agents/me/inbox-lite 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 '{"status":"in_progress","identifier":"PROJ-1","title":"T","description":"D","updatedAt":"x"}'
route GET "/api/issues/$ISSUE1/active-run" 200 'null'
run_afk --json
assert_eq "no live run: nothing is written to Paperclip" "$(grep -c -e '^POST' -e '^PATCH' "$LOG")" "0"
assert_missing "no live run: no claimed notice" "$STATE/paperclip/notices/proj"

new_scenario inbox_not_array
write_config
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
mkdir -p "$STATE/paperclip"
jq -n --arg a "$AGENT1" --arg id "$ISSUE1" \
  '{issues: {($id): {host_agent_id: $a, paperclip_project_id: "aaaaaaaa-0000-4000-8000-000000000001", slug: "proj", identifier: "PROJ-1", state: "working", since: "x", action_text: "y"}},
    stranded_reported: [], drain_tampered_reported: false, last_successful_pass: null}' >"$STATE/paperclip/ledger.json"
route GET /api/agents/me/inbox-lite 200 '{"error":"unexpected shape"}'
run_afk --json
assert_eq "a non-array inbox never closes ledger issues" "$(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$STATE/paperclip/ledger.json")" "working"
assert_eq "a non-array inbox: non-zero exit, nothing completed" "$RC" "1"

# ============================================================================
head1 "12. Drain: board-actor check on the last status change (AC-9 amendment)"
# ============================================================================
new_scenario drain_agent_actor
write_config_maint "$MAINT"
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
write_config_maint "$MAINT"
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
  write_config
  route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
  mkdir -p "$STATE/paperclip"
  jq -n --arg a "$AGENT1" --arg id "$ISSUE1" \
    '{issues: {($id): {host_agent_id: $a, paperclip_project_id: "aaaaaaaa-0000-4000-8000-000000000001", slug: "proj", identifier: "PROJ-1", state: "working", since: "2026-01-01T00:00:00Z", action_text: "AFK host is working on this"}},
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
    '{issues: {($id): ({host_agent_id:$a, paperclip_project_id:"aaaaaaaa-0000-4000-8000-000000000001", slug:"proj", identifier:$ident, state:$st, since:"2026-01-01T00:00:00Z",
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
write_config
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
assert_eq "3 entries: AC5, no final_intent is ever produced on a legacy pass" \
  "$(jq -r --arg id "$ISSUE1" '.issues[$id].final_intent // "none"' "$STATE/paperclip/ledger.json")" "none"

new_scenario cycle_lock_held_skips
write_config
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
write_config
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

# A rejected final status is distinct from its already delivered comment.
# The hold survives a new process on every run_afk invocation and a changed
# progress text does not turn the held final into another PATCH.
hold_fixture_start=$SECONDS
new_scenario cycle_final_held
write_config
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 working
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-held"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
route_nth PATCH "/api/issues/$ISSUE1" 2 422 \
  '{"code":"invalid_issue_disposition","details":{"missing_field":"review_path"},"requestId":"123e4567-e89b-12d3-a456-426614174000"}'
route POST "/api/issues/$ISSUE1/comments" 201 '{}'
write_spool "$ISSUE1" 001 "{\"id\":\"$E1\",\"kind\":\"final\",\"status\":\"in_review\",\"body\":\"review ready\"}"
run_afk --json
assert_eq "held final: comment delivered once, issue open" \
  "$(grep -c "^POST /api/issues/$ISSUE1/comments$" "$LOG") $(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$STATE/paperclip/ledger.json")" "1 working"
assert_missing "held final: delivered comment left the spool" "$STATE/paperclip/spool/$ISSUE1/001.json"
assert_eq "held final: intent and diagnostic survive" \
  "$(jq -r --arg id "$ISSUE1" '.issues[$id] | [.pending_final, .final_delivery_hold.status, .final_delivery_hold.http_status, .final_delivery_hold.code, .final_delivery_hold.missing_field, .final_delivery_hold.request_id, .final_delivery_hold.run_id] | join(" ")' "$STATE/paperclip/ledger.json")" \
  "in_review in_review 422 invalid_issue_disposition review_path 123e4567-e89b-12d3-a456-426614174000 run-held"
assert_contains "held final: one actionable local diagnostic" "$OUT_TEXT" "PAPERCLIP_FINAL_DELIVERY_HELD (422 invalid_issue_disposition missing review_path): PROJ-1"
for pass in 1 2 3; do run_afk --json; done
assert_eq "held final: three quiet passes and restarts do not write" \
  "$(grep -c "^POST /api/agents/$AGENT1/wakeup$" "$LOG") $(grep -c "^PATCH /api/issues/$ISSUE1$" "$LOG") $(grep -c "^POST /api/issues/$ISSUE1/comments$" "$LOG")" "1 3 1"
assert_absent "held final: later pass has no repeated notice" "$OUT_TEXT" "PAPERCLIP_FINAL_DELIVERY_HELD"
mkdir -p "$STATE/paperclip/status"
printf '{"schema":"afk-paperclip-status/1","text":"new progress","version":2}\n' >"$STATE/paperclip/status/$ISSUE1.json"
run_afk --json
assert_eq "held final: changed progress never resends final PATCH" \
  "$(grep -c '"status":"in_review"' "$BODYLOG")" "1"

# Legacy pending_final remains retryable, and a transient final rejection
# keeps the existing retry path rather than installing a hold.
for failure in 500 429 NETFAIL; do
  new_scenario "cycle_final_transient_${failure}"
  write_config
  route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
  seed_working "$ISSUE1" PROJ-1 working '{"pending_final":"done"}'
  route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
  route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-retry"}'
  route PATCH "/api/issues/$ISSUE1" 200 '{}'
  route_nth PATCH "/api/issues/$ISSUE1" 2 "$failure" '{}'
  run_afk --json
  assert_eq "transient final $failure: no hold, intent retained" \
    "$(jq -r --arg id "$ISSUE1" '.issues[$id] | [.pending_final, (.final_delivery_hold // null)] | map(tostring) | join(" ")' "$STATE/paperclip/ledger.json")" "done null"
  if [[ "$failure" == 500 ]]; then
    run_afk --json
    assert_eq "transient final $failure: legacy retry succeeds and closes" \
      "$(jq -r --arg id "$ISSUE1" '.issues[$id] | [.state, (.pending_final // null)] | map(tostring) | join(" ")' "$STATE/paperclip/ledger.json")" "closed null"
  fi
done

new_scenario cycle_final_malformed
write_config
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 working '{"pending_final":"in_review"}'
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-bad"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
route_nth PATCH "/api/issues/$ISSUE1" 2 400 'SECRET-LIKE-ARBITRARY-TEXT'
run_afk --json
assert_eq "malformed final: status alone holds legacy intent" \
  "$(jq -r --arg id "$ISSUE1" '.issues[$id] | [.pending_final, .final_delivery_hold.http_status, .final_delivery_hold.reason] | join(" ")' "$STATE/paperclip/ledger.json")" \
  "in_review 400 validation_rejected"
assert_absent "malformed final: raw response absent from ledger" "$(cat "$STATE/paperclip/ledger.json")" "SECRET-LIKE-ARBITRARY-TEXT"
assert_absent "malformed final: raw response absent from operator output" "$OUT_TEXT" "SECRET-LIKE-ARBITRARY-TEXT"

new_scenario cycle_final_empty_body
write_config
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 working '{"pending_final":"in_review"}'
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-empty"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
route_nth PATCH "/api/issues/$ISSUE1" 2 422
run_afk --json
assert_eq "empty final response: status alone holds legacy intent" \
  "$(jq -r --arg id "$ISSUE1" '.issues[$id] | [.pending_final, .final_delivery_hold.http_status, .final_delivery_hold.reason] | join(" ")' "$STATE/paperclip/ledger.json")" \
  "in_review 422 validation_rejected"

new_scenario cycle_final_untrusted_json
write_config
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 working '{"pending_final":"in_review"}'
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-json"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
untrusted_error="$(jq -nc --arg secret 'SECRET-LIKE-ARBITRARY-TEXT' --arg credential 'sk_test_FAKE_CREDENTIAL_12345678901234567890' --arg long "$(printf 'x%.0s' {1..9000})" \
  '{code:"unrecognized", details:{missing_field:$secret}, requestId:$credential, message:($secret + "\\n" + $long)}')"
route_nth PATCH "/api/issues/$ISSUE1" 2 422 "$untrusted_error"
run_afk --json
assert_eq "untrusted JSON: only allowlisted metadata retained" \
  "$(jq -r --arg id "$ISSUE1" '.issues[$id].final_delivery_hold | keys | join(" ")' "$STATE/paperclip/ledger.json")" \
  "http_status reason run_id status"
assert_absent "untrusted JSON: arbitrary values absent from ledger" "$(cat "$STATE/paperclip/ledger.json")" "SECRET-LIKE-ARBITRARY-TEXT"
assert_absent "untrusted JSON: arbitrary values absent from output" "$OUT_TEXT" "SECRET-LIKE-ARBITRARY-TEXT"
assert_eq "credential-shaped request ID: hold omits unqualified correlation" \
  "$(jq -r --arg id "$ISSUE1" '.issues[$id].final_delivery_hold | has("request_id")' "$STATE/paperclip/ledger.json")" "false"
assert_absent "credential-shaped request ID: absent from ledger" \
  "$(cat "$STATE/paperclip/ledger.json")" "sk_test_FAKE_CREDENTIAL_12345678901234567890"
assert_absent "credential-shaped request ID: absent from output" "$OUT_TEXT" "sk_test_FAKE_CREDENTIAL_12345678901234567890"

new_scenario cycle_final_oversized_valid_json
write_config
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 working '{"pending_final":"in_review"}'
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-large"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
large_error="$(jq -nc --arg padding "$(printf 'x%.0s' {1..9000})" \
  '{padding:$padding, code:"invalid_issue_disposition", details:{missing_field:"review_path"}, requestId:"123e4567-e89b-12d3-a456-426614174000"}')"
route_nth PATCH "/api/issues/$ISSUE1" 2 422 "$large_error"
run_afk --json
assert_eq "oversized valid JSON: allowlisted fields survive" \
  "$(jq -r --arg id "$ISSUE1" '.issues[$id].final_delivery_hold | [.code, .missing_field, .request_id] | join(" ")' "$STATE/paperclip/ledger.json")" \
  "invalid_issue_disposition review_path 123e4567-e89b-12d3-a456-426614174000"
assert_absent "oversized valid JSON: padding not retained" "$(cat "$STATE/paperclip/ledger.json")$OUT_TEXT" "$(printf 'x%.0s' {1..100})"

new_scenario cycle_final_hold_write_failure
write_config
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 working '{"pending_final":"in_review"}'
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-fail"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
route_nth PATCH "/api/issues/$ISSUE1" 2 422 '{"code":"invalid_issue_disposition"}'
touch "$FIXDIR/.fail_hold_write"
run_afk --json
assert_eq "failed hold write: CLI fails" "$RC" "1"
assert_contains "failed hold write: explicit storage error" "$OUT_TEXT" "PAPERCLIP_STORAGE_ERROR"
assert_absent "failed hold write: no persisted-hold claim" "$OUT_TEXT" "PAPERCLIP_FINAL_DELIVERY_HELD"
assert_eq "failed hold write: pending intent remains without durable hold" \
  "$(jq -r --arg id "$ISSUE1" '[.issues[$id].pending_final, (.issues[$id].final_delivery_hold // null), .last_successful_pass] | map(tostring) | join(" ")' "$STATE/paperclip/ledger.json")" \
  "in_review null null"
assert_eq "failed hold write: self-block still attempted" "$(grep -c "^PATCH /api/issues/$ISSUE1$" "$LOG")" "3"
assert_eq "failed hold write: cleanup PATCH is blocked" \
  "$(awk 'BEGIN{RS="\n---\n"} {last=$0} END{print last}' "$BODYLOG" | jq -r '.status')" "blocked"
assert_eq "failed hold write: no final status re-send" "$(grep -c '"status":"in_review"' "$BODYLOG")" "1"

for rejected_status in 401 403 409; do
  new_scenario "cycle_final_${rejected_status}"
  write_config
  route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
  seed_working "$ISSUE1" PROJ-1 working '{"pending_final":"done"}'
  route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
  route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-other"}'
  route PATCH "/api/issues/$ISSUE1" 200 '{}'
  route_nth PATCH "/api/issues/$ISSUE1" 2 "$rejected_status" '{}'
  run_afk --json
  assert_eq "final $rejected_status: intent retained without validation hold" \
    "$(jq -r --arg id "$ISSUE1" '.issues[$id] | [.pending_final, (.final_delivery_hold // null)] | map(tostring) | join(" ")' "$STATE/paperclip/ledger.json")" "done null"
  if [[ "$rejected_status" == 401 || "$rejected_status" == 403 ]]; then
    assert_contains "final $rejected_status: credential stop reported" "$OUT_TEXT" "PAPERCLIP_CREDENTIAL_REJECTED"
  fi
done
for rejected_status in 401 403; do
  new_scenario "cycle_final_${rejected_status}_two_issues"
  write_config
  route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
  seed_working "$ISSUE1" PROJ-1 working '{"pending_final":"done"}'
  jq --arg first "$ISSUE1" --arg second "$ISSUE2" '.issues[$second] = (.issues[$first] | .identifier = "PROJ-2" | .pending_final = "done")' \
    "$STATE/paperclip/ledger.json" >"$STATE/paperclip/ledger.json.tmp" && mv "$STATE/paperclip/ledger.json.tmp" "$STATE/paperclip/ledger.json"
  route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"},{\"id\":\"$ISSUE2\"}]"
  route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-auth"}'
  route PATCH "/api/issues/$ISSUE1" 200 '{}'
  route_nth PATCH "/api/issues/$ISSUE1" 2 "$rejected_status" '{}'
  run_afk --json
  assert_contains "final $rejected_status: first issue reports credential rejection" "$OUT_TEXT" "PAPERCLIP_CREDENTIAL_REJECTED: PROJ-1"
  assert_eq "final $rejected_status: second issue receives no wake, PATCH or comment" \
    "$(grep -Ec "^(PATCH|POST) /api/issues/$ISSUE2(/comments)?$" "$LOG" || true)" "0"
  assert_eq "final $rejected_status: only first issue wakes" "$(grep -c "^POST /api/agents/$AGENT1/wakeup$" "$LOG")" "1"
done
printf '  held-final fixture runtime: %ss\n' "$((SECONDS - hold_fixture_start))"

new_scenario cycle_question
write_config
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
write_config
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
write_config
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
write_config
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
write_config
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
write_config
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
write_config
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
write_config
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 working
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route POST "/api/agents/$AGENT1/wakeup" 202 '{}'
write_spool "$ISSUE1" 001 "{\"id\":\"$E1\",\"kind\":\"comment\",\"body\":\"x\"}"
run_afk --json
assert_eq "no run: no PATCH at all" "$(grep -c "^PATCH /api/issues/$ISSUE1$" "$LOG")" "0"
assert_eq "no run: the spool is untouched" "$(find "$STATE/paperclip/spool/$ISSUE1" -maxdepth 1 -name '001.json' 2>/dev/null | wc -l | tr -d ' ')" "1"

new_scenario cycle_403_credential
write_config
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 working
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route POST "/api/agents/$AGENT1/wakeup" 403 '{}'
write_spool "$ISSUE1" 001 "{\"id\":\"$E1\",\"kind\":\"comment\",\"body\":\"x\"}"
run_afk --json
assert_contains "403: credential reason" "$OUT_TEXT" "PAPERCLIP_CREDENTIAL_REJECTED"
assert_eq "403: nothing posted" "$(grep -c "^POST /api/issues/$ISSUE1/comments$" "$LOG")" "0"

new_scenario cycle_paused_nothing_touched
write_config
mkdir -p "$HOME/.config/agent-flow-kit/paperclip"; : >"$HOME/.config/agent-flow-kit/paperclip/stop"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 working
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
write_spool "$ISSUE1" 001 "{\"id\":\"$E1\",\"kind\":\"comment\",\"body\":\"x\"}"
run_afk --json
assert_eq "paused: no wakeup, no post, no delete" "$(grep -c -e '^POST' -e '^PATCH' "$LOG")" "0"
assert_eq "paused: the spool entry is untouched" "$(find "$STATE/paperclip/spool/$ISSUE1" -maxdepth 1 -name '001.json' 2>/dev/null | wc -l | tr -d ' ')" "1"

new_scenario cycle_stranded_held
write_config
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 stranded
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
write_spool "$ISSUE1" 001 "{\"id\":\"$E1\",\"kind\":\"comment\",\"body\":\"x\"}"
run_afk --json
assert_eq "stranded: no wakeup for that issue" "$(grep -c "^POST /api/agents/$AGENT1/wakeup$" "$LOG")" "0"
assert_eq "stranded: spool held" "$(find "$STATE/paperclip/spool/$ISSUE1" -maxdepth 1 -name '001.json' 2>/dev/null | wc -l | tr -d ' ')" "1"

new_scenario cycle_junk_ignored
write_config
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
seed_working "$ISSUE1" PROJ-1 working
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
mkdir -p "$STATE/paperclip/spool/$ISSUE1/.tmp"
printf 'junk' >"$STATE/paperclip/spool/$ISSUE1/.tmp/leftover"
printf 'junk' >"$STATE/paperclip/spool/$ISSUE1/notanentry.txt"
run_afk --json
assert_eq "junk names: no cycle ran (no spool, no text change)" "$(grep -c "^POST /api/agents/$AGENT1/wakeup$" "$LOG")" "0"

new_scenario cycle_key_never_logged
write_config
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
write_config
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
route POST "/api/issues/$ISSUE1/comments" 201 '{}'
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
  write_config
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
write_config
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
# (question_sent_at as JSON, e.g. null), PSEQ (the plan file's posted_seq,
# JSON), PSTATE (its state, JSON; null omits it), PAPPR=1 (an approval of the
# plan already on file) and PLOCK=1 (the plan lock already held).
plan_scenario() {
  local qid="${PQID:-plan-$PD8}" sent="${PSENT:-\"2026-03-01T00:00:00.000Z\"}"
  new_scenario "$1"
  write_config
  if [[ "${3:-}" != none ]]; then
    jq --argjson i "${3:-$PATT}" \
      '.interim_comment_approval = $i' "$CONFIG" >"$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  fi
  seed_working "$ISSUE1" HOM-12 waiting_human \
    "{\"question_id\":\"$qid\",\"question_seq\":3,\"question_sent_at\":$sent,\"action_text_applied\":\"waiting on $qid\"}"
  mkdir -p "$STATE/paperclip/plans"
  jq -nc --arg d "$PD" --argjson seq "${PSEQ:-3}" --argjson st "${PSTATE:-\"posted\"}" \
    '{schema:"afk-paperclip-plan-record/1", digest:$d, digest8:$d[0:8], question_id:("plan-" + $d[0:8]), posted_seq:$seq}
     + (if $st == null then {} else {state:$st} end)' \
    >"$STATE/paperclip/plans/$ISSUE1.json"
  if [[ -n "${PAPPR:-}" ]]; then
    mkdir -p "$STATE/paperclip/approvals"
    jq -nc --arg d "$PD" '{schema:"afk-paperclip-approval/1", kind:"plan", digest:$d, digest8:$d[0:8]}' \
      >"$STATE/paperclip/approvals/$ISSUE1.json"
  fi
  [[ -n "${PLOCK:-}" ]] && mkdir -p "$STATE/paperclip/plans/.$ISSUE1.lock"
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

PSTATE='"pending_publish"' plan_scenario appr_pending_seq "[$(jc 1 "approve $PD8")]"
assert_eq "a pending_publish record carrying the sent seq -> approved" "$(jq -r .digest "$APPROVAL" 2>/dev/null)" "$PD"
PSTATE='"pending_publish"' PSEQ=null plan_scenario appr_pending_noseq "[$(jc 1 "approve $PD8")]"
assert_missing "a pending_publish record with no seq -> no record" "$APPROVAL"
assert_contains "  ...APPROVAL_PLAN_MISMATCH" "$OUT_TEXT" "APPROVAL_PLAN_MISMATCH"
PSTATE=null plan_scenario appr_no_state "[$(jc 1 "approve $PD8")]"
assert_missing "a plan record with no state -> no record" "$APPROVAL"
PSTATE='"withdrawn"' plan_scenario appr_other_state "[$(jc 1 "approve $PD8")]"
assert_missing "a plan record in any other state -> no record" "$APPROVAL"

PAPPR=1 plan_scenario appr_reject_withdraws "[$(jc 1 "reject $PD8")]"
assert_missing "reject <d8> withdraws an approval of the same plan" "$APPROVAL"
assert_eq "  ...then one approval_rejected notice" "$(notices approval_rejected)" "1"
PAPPR=1 PLOCK=1 plan_scenario appr_reject_locked "[$(jc 1 "reject $PD8")]"
assert_eq "reject while the plan lock is held -> the approval stays" "$(jq -r .digest "$APPROVAL" 2>/dev/null)" "$PD"
assert_eq "  ...no approval_rejected notice" "$(notices approval_rejected)" "0"
assert_eq "  ...an approval_withdraw_failed notice with the reason" \
  "$(jq -r .reason "$NOTICE_DIR"/*.approval_withdraw_failed.json 2>/dev/null)" "PAPERCLIP_LOCK_TIMEOUT"
assert_contains "  ...and a local action line" "$OUT_TEXT" "approval_withdraw_failed (PAPERCLIP_LOCK_TIMEOUT): HOM-12"

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
write_config
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

# ============================================================================
head1 "18. One host, many projects: config v2, resolution, pinning (HA-1a)"
# ============================================================================
# AD-18: a pass costs about a second here, so most cases share a pass: many
# issues in one inbox, each asserted on its own ledger row.
LEDGER_OF() { printf '%s' "$STATE/paperclip/ledger.json"; }
lget() { jq -r --arg id "$1" ".issues[\$id]${2:-.state} // empty" "$(LEDGER_OF)" 2>/dev/null; }
last_block() { # the action text of the last self-block PATCH body
  awk 'BEGIN { RS = "\n---\n" } /"unblockDescriptor"/ { last = $0 } END { print last }' "$BODYLOG" |
    jq -r '.unblockDescriptor.action // empty' 2>/dev/null
}
iid() { printf 'e%07d-1111-1111-1111-111111111111' "$1"; } # issue n
pid_n() { printf 'aaaaaaaa-0000-4000-8000-%012d' "$1"; }   # project n
# issue <n> <status> <projectId-json> [<title>] [<description>] -- one issue's routes.
issue() {
  local i; i="$(iid "$1")"
  route GET "/api/issues/$i" 200 "$(jq -nc --arg st "$2" --arg ident "PROJ-$1" --argjson p "$3" --arg t "${4:-T}" --arg d "${5:-D}" --arg a "$AGENT1" \
    '{status:$st, identifier:$ident, title:$t, description:$d, updatedAt:"2026-01-01T00:00:00Z", projectId:$p}
     + (if $st == "blocked" then {unblockDescriptor:{owner:{agentId:$a}}} else {} end)')"
  route GET "/api/issues/$i/active-run" 200 '{"id":"run-1"}'
  route GET "/api/issues/$i/comments" 200 '[]'
  route POST "/api/issues/$i/comments" 201 '{}'
  route PATCH "/api/issues/$i" 200 '{}'
}
inbox() { # <n>... -- the inbox, in this order
  local n ids=()
  for n in "$@"; do ids+=("{\"id\":\"$(iid "$n")\"}"); done
  route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
  route GET "/api/agents/me/inbox-lite" 200 "[$(IFS=,; printf '%s' "${ids[*]}")]"
  route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-r"}'
}
seed() { # <n> <state> <slug> <project-id> [<since>] -- add a ledger row
  mkdir -p "$STATE/paperclip"
  [[ -s "$(LEDGER_OF)" ]] || printf '{"issues":{},"stranded_reported":[]}' >"$(LEDGER_OF)"
  jq --arg id "$(iid "$1")" --arg st "$2" --arg s "$3" --arg p "$4" --arg a "$AGENT1" --arg ident "PROJ-$1" --arg since "${5:-2026-01-01T00:00:00Z}" \
    '.issues[$id] = {host_agent_id:$a, paperclip_project_id:$p, slug:$s, identifier:$ident, state:$st, since:$since,
       action_text:"AFK host is working on this", action_text_applied:"AFK host is working on this"}' \
    "$(LEDGER_OF)" >"$(LEDGER_OF).t" && mv "$(LEDGER_OF).t" "$(LEDGER_OF)"
}

# --- AC-1: the loader --------------------------------------------------------
cfg_refused() { # <name> <jq-edit> <reason>
  new_scenario "$1"; write_config; set_cfg "$2"; run_afk
  assert_eq "$1: non-zero exit" "$RC" "1"
  assert_eq "$1: no request made" "$(cat "$LOG")" ""
  assert_contains "$1: $3" "$OUT_TEXT" "$3"
}
cfg_refused cfg_v1_agents '. + {agents: [{agent_id: "x"}]}' PAPERCLIP_CONFIG_SCHEMA_OLD
cfg_refused cfg_no_schema 'del(.schema)' PAPERCLIP_CONFIG_SCHEMA_OLD
cfg_refused cfg_slug_upper '.projects[0].slug = "Proj"' PAPERCLIP_CONFIG_INVALID
cfg_refused cfg_slug_reserved '.projects[0].slug = "claimed"' PAPERCLIP_CONFIG_INVALID
cfg_refused cfg_slug_long ".projects[0].slug = \"$(printf 'a%.0s' {1..41})\"" PAPERCLIP_CONFIG_INVALID
cfg_refused cfg_repo_relative '.projects[0].repo_path = "repos/repo1"' PAPERCLIP_CONFIG_INVALID
cfg_refused cfg_harness '.projects[0].harness = "vim"' PAPERCLIP_CONFIG_INVALID
cfg_refused cfg_merge '.projects[0].merge = "auto"' PAPERCLIP_CONFIG_INVALID
cfg_refused cfg_pid_not_uuid '.projects[0].paperclip_project_id = "spektacle"' PAPERCLIP_ID_INVALID
cfg_refused cfg_host_agent_not_uuid '.host.agent_id = "afk-ubuntu"' PAPERCLIP_ID_INVALID

WT1="$TMPROOT/repos/repo1-wt"
git -C "$REPO1" worktree add -q "$WT1" -b wt-branch >/dev/null 2>&1
new_scenario cfg_same_repo_by_worktree
write_config "[$(proj_json "$PROJ1" proj "$REPO1"), $(proj_json "$PROJ2" proj2 "$WT1")]"
run_afk
assert_contains "a linked worktree of an onboarded repo is the same repo (common-dir)" "$OUT_TEXT" "PAPERCLIP_CONFIG_INVALID"

new_scenario cfg_zero_projects_nonrepo_ok
write_config '[]'
inbox 1; issue 1 in_progress "\"$PROJ1\""
run_afk --json
assert_eq "zero projects is a valid config" "$RC" "0"
assert_eq "zero projects: the issue waits for setup as unmapped" "$(lget "$(iid 1)" .refusal_code)" "PAPERCLIP_PROJECT_UNMAPPED"

# --- AC-3/4/5/8 in one pass: every refusal, a restart and two projects -------
NR="$TMPROOT/repos/no-allowlist"; mkdir -p "$NR"; git -C "$NR" init -q -b main
git -C "$NR" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
mkdir -p "$NR/.afk"; printf 'x\n' >"$NR/.afk/gates-allowlist" # worktree only, never committed
REPO4="$TMPROOT/repos/repo4"; mkrepo "$REPO4"
REPO5="$TMPROOT/repos/repo5"; mkrepo "$REPO5"
UNMAPPED_P="bbbbbbbb-0000-4000-8000-00000000000f"
new_scenario resolve_all
write_config "[$(proj_json "$(pid_n 1)" proj "$REPO1"), $(proj_json "$(pid_n 2)" proj2 "$REPO2"),
  $(proj_json "$(pid_n 3)" proj3 "$NR"), $(proj_json "$(pid_n 4)" proj4 "$REPO4"), $(proj_json "$(pid_n 5)" proj5 "$REPO5"),
  $(proj_json "$(pid_n 6)" proj6 "$TMPROOT/not-a-repo-yet")]"
route GET "/api/projects/$(pid_n 1)" 200 "$(project_body "$(pid_n 1)" "../../evil" "" "https://GitHub.com/test/repo1/")"
route GET "/api/projects/$(pid_n 3)" 200 "{\"id\":\"$(pid_n 3)\",\"name\":5,\"archivedAt\":null,\"codebase\":{\"repoUrl\":null}}"
route GET "/api/projects/$(pid_n 4)" 200 "$(project_body "$(pid_n 4)" "Four" "" "https://github.com/test/other-repo")"
route GET "/api/projects/$(pid_n 5)" 200 "$(project_body "$(pid_n 5)" "../../evil" "2026-09-01T00:00:00Z")"
seed 9 working proj "$(pid_n 1)" 2025-12-01T00:00:00Z            # holds proj's one slot
seed 8 closed proj3 "$UNMAPPED_P"; jq --arg id "$(iid 8)" '.issues[$id].fixed_text = "old"' "$(LEDGER_OF)" >"$(LEDGER_OF).t" && mv "$(LEDGER_OF).t" "$(LEDGER_OF)"
mkdir -p "$STATE/paperclip/spool/$(iid 8)" "$STATE/paperclip/status"
: >"$STATE/paperclip/spool/$(iid 8)/.final"; printf '{"text":"old status"}' >"$STATE/paperclip/status/$(iid 8).json"
inbox 9 1 2 3 4 5 6 7 8 10
issue 10 todo "\"$(pid_n 1)\""                                   # assigned, not started
issue 9 blocked "\"$(pid_n 1)\""
issue 1 in_progress "\"$(pid_n 1)\"" "Move this to proj2" "repo_path: $REPO2, slug proj2, project ../../escape"
issue 2 in_progress "\"$(pid_n 2)\""
issue 3 in_progress "\"$(pid_n 3)\""
issue 4 in_progress "\"$(pid_n 4)\""
issue 5 in_progress "\"$(pid_n 5)\""
issue 6 in_progress null
issue 7 in_progress "\"$UNMAPPED_P\""
issue 8 in_progress "\"$(pid_n 2)\""
run_afk --json
assert_eq "resolve_all: exit 0 (merge absent defaults to human; a not-yet-git repo_path loads)" "$RC" "0"
refused() { # <n> <code> <text>
  assert_eq "PROJ-$1: waiting_setup ($2)" "$(lget "$(iid "$1")") $(lget "$(iid "$1")" .refusal_code)" "waiting_setup $2"
  assert_eq "PROJ-$1: self-blocked with the AD-23 text" "$(lget "$(iid "$1")" .action_text_applied)" "$3"
  assert_eq "PROJ-$1: no pin" "$(lget "$(iid "$1")" '.slug')$(lget "$(iid "$1")" '.paperclip_project_id')" ""
}
refused 3 PAPERCLIP_PROJECT_REPO_NOT_READY 'Waiting for Josh: proj3 repo not ready on test-host (GATES_ALLOWLIST_MISSING) · aaaaaaaa'
assert_absent "a non-string project name shifts no field: no local path in the text" "$(lget "$(iid 3)" .action_text_applied)" "/"
assert_eq "a todo issue in the inbox is left alone, with nothing on stderr" "$(lget "$(iid 10)")|$(cat "$SCEN/err")" "|"
refused 4 PAPERCLIP_PROJECT_REPO_MISMATCH "Waiting for Josh: project repo differs from test-host's · aaaaaaaa \"Four\""
refused 5 PAPERCLIP_PROJECT_ARCHIVED 'Waiting for Josh: project archived · aaaaaaaa "../../evil"'
refused 6 PAPERCLIP_PROJECT_MISSING "Waiting for Josh: set a Project on PROJ-6"
refused 7 PAPERCLIP_PROJECT_UNMAPPED "Waiting for Josh: project not set up on test-host; assign to a host that has it · bbbbbbbb"
assert_contains "refusals are reported locally" "$OUT_TEXT" "waiting_setup (PAPERCLIP_PROJECT_MISSING): PROJ-6"
assert_eq "an unmapped project is never read" "$(grep -c "^GET /api/projects/$UNMAPPED_P" "$LOG")" "0"
assert_eq "a missing project reads nothing" "$(grep -c '^GET /api/projects/null' "$LOG")" "0"
assert_eq "refusals post no claim comment: only PROJ-1, PROJ-2 and PROJ-8 are claimed" "$(grep -c 'claimed by AFK PM' "$BODYLOG")" "3"
assert_eq "at cap, a new issue in proj queues; the unmapped one never does" "$(lget "$(iid 1)") $(lget "$(iid 7)")" "queued waiting_setup"
assert_absent "  ...and no refusal ever reads queued behind" "$(jq -r '[.issues[] | select(.state == "waiting_setup") | .action_text_applied] | join(" ")' "$(LEDGER_OF)")" "queued"
assert_eq "repoUrl in https form matches an scp-form origin: pinned to proj" "$(lget "$(iid 1)" '| "\(.slug) \(.paperclip_project_id)"')" "proj $(pid_n 1)"
assert_eq "two projects in one pass: PROJ-2 is in proj2, queued behind the older PROJ-8 (since order)" "$(lget "$(iid 2)") $(lget "$(iid 2)" .slug)" "queued proj2"
assert_eq "  ...its notice is under proj2 with proj2's repo" "$(jq -r .repo_path "$STATE"/paperclip/notices/proj2/*."$(iid 2)".claimed.json)" "$REPO2"
assert_eq "  ...PROJ-1's notice is under proj with proj's repo" "$(jq -r .repo_path "$STATE"/paperclip/notices/proj/*."$(iid 1)".claimed.json)" "$REPO1"
assert_eq "title/description naming another repo or slug change nothing" "$(ls "$STATE/paperclip/notices" | tr '\n' ' ')" "proj proj2 "
assert_eq "the project name never becomes a path" "$(find "$STATE" -path '*evil*' | wc -l | tr -d ' ')" "0"
assert_missing "no PM start intent for anything refused" "$STATE/paperclip/pm-start-intents"
n="$(cat "$STATE"/paperclip/notices/proj2/*."$(iid 2)".claimed.json)"
assert_eq "a notice carries slug and host_agent_id, not project or agent_id (AC-7)" \
  "$(jq -r '"\(.slug) \(.host_agent_id) \(has("project")) \(has("agent_id"))"' <<<"$n")" "proj2 $AGENT1 false false"
assert_eq "a closed issue reassigned back is a restart: re-pinned, nothing carried over" \
  "$(lget "$(iid 8)" '| "\(.state) \(.slug) \(.paperclip_project_id) \(.fixed_text)"')" "working proj2 $(pid_n 2) null"
assert_missing "  ...its spool is reopened (.final removed) so the new PM can report" "$STATE/paperclip/spool/$(iid 8)/.final"
assert_missing "  ...and the old declared status is dropped" "$STATE/paperclip/status/$(iid 8).json"

# --- AC-4: re-resolved each pass, written on change, adopted as new ----------
new_scenario res_waiting_then_resolves
write_config
inbox 1; issue 1 in_progress "\"$UNMAPPED_P\""
run_afk --json
p1="$(grep -c "^PATCH /api/issues/$(iid 1)$" "$LOG")"
issue 1 blocked "\"$UNMAPPED_P\""
run_afk --json
assert_eq "same refusal on the next pass: nothing written" "$(grep -c "^PATCH /api/issues/$(iid 1)$" "$LOG")" "$p1"
assert_eq "  ...and no wakeup" "$(grep -c '/wakeup$' "$LOG")" "0"
issue 1 blocked "\"$PROJ1\""
route GET "/api/projects/$PROJ1" 200 "$(project_body "$PROJ1" "Archived one" "2026-09-01T00:00:00Z")"
run_afk --json
assert_eq "a changed refusal is written (via a report cycle)" "$(grep -c '/wakeup$' "$LOG")" "1"
assert_contains "  ...with the new text" "$(last_block)" "project archived · aaaaaaaa"
route GET "/api/projects/$PROJ1" 200 "$(project_body "$PROJ1" "Proj")"
run_afk --json
assert_eq "the project flipping from refused to accepted is reported once" \
  "$(grep -o 'PAPERCLIP_PROJECT_REFUSAL_CHANGED: aaaaaaaa accepted' <<<"$OUT_TEXT" | wc -l | tr -d ' ')" "1"
assert_eq "resolved: adopted as working and pinned" "$(lget "$(iid 1)") $(lget "$(iid 1)" .slug)" "working proj"
assert_eq "resolved: one claimed notice" "$(find "$STATE/paperclip/notices/proj" -name '*.claimed.json' | wc -l | tr -d ' ')" "1"
assert_eq "resolved: one brief" "$(find "$STATE/paperclip/notices/proj" -name 'brief.*' | wc -l | tr -d ' ')" "1"
assert_eq "resolved: exactly one claim comment, only now" "$(grep -c 'claimed by AFK PM' "$BODYLOG")" "1"
assert_eq "resolved: the self-block no longer carries the refusal" "$(last_block)" "AFK host is working on this"
route GET "/api/projects/$PROJ1" 200 "$(project_body "$PROJ1" "Proj" "2026-09-01T00:00:00Z")"
issue 2 in_progress "\"$PROJ1\""; inbox 1 2
run_afk --json
assert_eq "accepted -> refused is reported exactly once" \
  "$(grep -o 'PAPERCLIP_PROJECT_REFUSAL_CHANGED: aaaaaaaa refused' <<<"$OUT_TEXT" | wc -l | tr -d ' ')" "1"

# A refused or closed issue that resolves on a pass where it can't be adopted
# yet (no live run) keeps its row, and is adopted once a run exists.
new_scenario res_resolves_without_run
write_config "[$(proj_json "$PROJ1" proj "$REPO1"), $(proj_json "$PROJ2" proj2 "$REPO2")]"
seed 1 waiting_setup proj "$PROJ1"; seed 2 closed proj2 "$PROJ2"
inbox 1 2; issue 1 in_progress "\"$PROJ1\""; issue 2 in_progress "\"$PROJ2\""
route GET "/api/issues/$(iid 1)/active-run" 200 '{}'; route GET "/api/issues/$(iid 2)/active-run" 200 '{}'
run_afk --json
assert_eq "no live run on the resolving pass: both rows are kept as they were" "$(lget "$(iid 1)") $(lget "$(iid 2)")" "waiting_setup closed"
route GET "/api/issues/$(iid 1)/active-run" 200 '{"id":"run-1"}'; route GET "/api/issues/$(iid 2)/active-run" 200 '{"id":"run-2"}'
run_afk --json
assert_eq "  ...and both are adopted once a run exists" "$(lget "$(iid 1)") $(lget "$(iid 2)")" "working working"
assert_eq "  ...each with a full, pinned row" "$(lget "$(iid 1)" '| "\(.host_agent_id) \(.slug)"') $(lget "$(iid 2)" .slug)" "$AGENT1 proj proj2"

# --- F11: unreadable is a hold; three consecutive 404s become MISSING --------
new_scenario res_unreadable
write_config "[$(proj_json "$PROJ1" proj "$REPO1"), $(proj_json "$PROJ2" proj2 "$REPO2")]"
inbox 1 2; issue 1 in_progress "\"$PROJ1\""; issue 2 in_progress "\"$PROJ2\""
route GET "/api/projects/$PROJ1" 404 ''
route GET "/api/projects/$PROJ2" 404 ''
route_nth GET "/api/projects/$PROJ2" 2 500 ''
run_afk --json; run_afk --json
assert_eq "404 then 404/500: no write at all" "$(grep -c "^PATCH\|^POST" "$LOG")" "0"
assert_eq "  ...and no ledger rows" "$(lget "$(iid 1)")$(lget "$(iid 2)")" ""
assert_contains "  ...reported locally" "$OUT_TEXT" "PAPERCLIP_PROJECT_UNREADABLE (500), held: PROJ-2"
run_afk --json
assert_eq "the third consecutive 404 becomes MISSING" "$(lget "$(iid 1)" .refusal_code)" "PAPERCLIP_PROJECT_MISSING"
assert_eq "a 500 in between resets the count: 404,500,404 still holds" "$(lget "$(iid 2)")" ""

# --- AC-4 text budget and AC-5 normalization (unit) ---------------------------
lib() { bash -c '. "$1/lib/afk-paperclip.sh"; "${@:2}"' _ "$KIT_ROOT" "$@"; }
assert_eq "control chars and quotes stripped, name cut to 32" \
  "$(lib afk_pc_refusal_text "project archived" "$PROJ1" $'A \x01very "long" project name that keeps going and going')" \
  'Waiting for Josh: project archived · aaaaaaaa "A very long project name that ke"'
t="$(lib afk_pc_refusal_text "$(printf 's%.0s' {1..40}) repo not ready on a-rather-long-host-label (GATES_ALLOWLIST_MISSING)" "$PROJ1" Spektacle)"
assert_eq "over the 120-13 budget the name is dropped, the id prefix stays" "${t##* · }" "aaaaaaaa"
assert_eq "  ...and the whole text fits 107 characters" "$(jq -rn --arg t "$t" '$t | length <= 107')" "true"
t="$(lib afk_pc_refusal_text "set a Project on $(printf 'X%.0s' {1..120})" "" "")"
assert_eq "a long text with no project tail is cut to 107 too" "$(jq -rn --arg t "$t" '$t | length <= 107 and endswith("…")')" "true"
assert_eq "scp form == URL form" "$(lib afk_pc_origin_normalize git@github.com:jlengelbrecht/Spektacle.git)" \
  "$(lib afk_pc_origin_normalize https://github.com/jlengelbrecht/Spektacle)"
assert_eq "host case, trailing slash" "$(lib afk_pc_origin_normalize https://GitHub.com/jlengelbrecht/Spektacle/)" "github.com/jlengelbrecht/Spektacle"
assert_eq "user@ and port dropped" "$(lib afk_pc_origin_normalize ssh://git@github.com:22/jlengelbrecht/Spektacle.git)" "github.com/jlengelbrecht/Spektacle"
assert_eq "a path case difference is a mismatch" "$(lib afk_pc_origin_normalize https://github.com/JLengelbrecht/spektacle)" "github.com/JLengelbrecht/spektacle"
if lib afk_pc_origin_normalize /srv/git/x.git >/dev/null; then bad "a local-path origin is not host/path"; else ok "a local-path origin is not host/path"; fi
if lib afk_pc_origin_normalize file:///srv/git/x.git >/dev/null; then bad "a file:// origin is not host/path"; else ok "a file:// origin is not host/path"; fi
mkdir -p "$TMPROOT/repos/plain-dir" "$REPO1/sub"
assert_eq "a plain directory is not a git repo" "$(lib afk_pc_repo_ready "$TMPROOT/repos/plain-dir" "")" "NOT_A_GIT_REPO"
assert_eq "a subdirectory of a repo is not the repo" "$(lib afk_pc_repo_ready "$REPO1/sub" "")" "NOT_A_GIT_REPO"
assert_eq "a missing repo_path" "$(lib afk_pc_repo_ready "$TMPROOT/repos/gone" "")" "REPO_MISSING"
NO_ORIGIN="$TMPROOT/repos/no-origin"; mkrepo "$NO_ORIGIN"; git -C "$NO_ORIGIN" remote remove origin
assert_eq "no origin while repoUrl is set" "$(lib afk_pc_repo_ready "$NO_ORIGIN" https://github.com/test/no-origin)" "ORIGIN_UNREADABLE"
assert_eq "no origin with repoUrl unset: the check is skipped" "$(lib afk_pc_repo_ready "$NO_ORIGIN" "")" "ok"
LOCAL_ORIGIN="$TMPROOT/repos/local-origin"; mkrepo "$LOCAL_ORIGIN"; git -C "$LOCAL_ORIGIN" remote set-url origin /srv/git/x.git
assert_eq "a local-path origin while repoUrl is set" "$(lib afk_pc_repo_ready "$LOCAL_ORIGIN" https://github.com/test/x)" "ORIGIN_UNREADABLE"
assert_eq "a local-path origin with repoUrl unset: skipped" "$(lib afk_pc_repo_ready "$LOCAL_ORIGIN" "")" "ok"
assert_eq "a path-case difference in repoUrl is a mismatch" "$(lib afk_pc_repo_ready "$REPO1" https://github.com/Test/repo1)" "MISMATCH"
NR2="$TMPROOT/repos/no-allowlist-2"; mkdir -p "$NR2"; git -C "$NR2" init -q -b main
git -C "$NR2" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init; git -C "$NR2" remote add origin git@github.com:test/nr2.git
assert_eq "wrong repo AND no allowlist: MISMATCH wins (AD-23 order)" "$(lib afk_pc_repo_ready "$NR2" https://github.com/test/other)" "MISMATCH"
assert_eq "  ...the right repo with no allowlist is NOT_READY" "$(lib afk_pc_repo_ready "$NR2" https://github.com/test/nr2)" "GATES_ALLOWLIST_MISSING"
assert_eq "a linked worktree resolves origin through the common-dir" "$(lib afk_pc_repo_ready "$WT1" https://github.com/test/repo1)" "ok"

# --- AC-6: pinning, all non-closed states in one scenario ---------------------
new_scenario pin_all
write_config "[$(proj_json "$PROJ1" proj "$REPO1"), $(proj_json "$PROJ2" proj2 "$REPO2"), $(proj_json "$(pid_n 3)" proj3 "$REPO4")]"
route GET "/api/projects/$(pid_n 3)" 404 ''
seed 1 working proj "$PROJ1" 2026-01-01T00:00:01Z
seed 2 queued proj "$PROJ1" 2026-01-01T00:00:02Z
seed 3 held_by_board proj "$PROJ1" 2026-01-01T00:00:03Z
seed 4 queued proj "$PROJ1" 2026-01-01T00:00:04Z
seed 5 working proj3 "$(pid_n 3)" 2026-01-01T00:00:05Z
seed 6 waiting_human proj "$PROJ1" 2026-01-01T00:00:06Z
seed 7 dep_waiting proj "$PROJ1" 2026-01-01T00:00:07Z
seed 8 pending_claim proj "$PROJ1" 2026-01-01T00:00:08Z
seed 9 stranded proj "$PROJ1" 2026-01-01T00:00:09Z
inbox 1 2 3 4 5 6 7 8 9
issue 6 blocked "\"$PROJ2\""; issue 7 blocked null; issue 8 blocked "\"$PROJ2\""; issue 9 blocked null
issue 1 blocked "\"$PROJ2\""          # moved to another mapped project
issue 2 blocked null                   # project cleared
issue 3 blocked null
issue 4 blocked "\"$PROJ1\""
route GET "/api/issues/$(iid 4)/comments" 200 \
  "[{\"id\":\"c0000000-0000-0000-0000-00000000000a\",\"body\":\"use proj2 at $REPO2\",\"authorUserId\":\"$BOARD\",\"authorAgentId\":null,\"createdAt\":\"2026-02-01T00:00:00Z\"}]"
issue 5 blocked "\"$(pid_n 3)\""       # the pinned project was deleted (404)
run_afk --json
for n in 1 2 3 6 7 8 9; do                # working queued held_by_board waiting_human dep_waiting pending_claim stranded
  assert_eq "PROJ-$n ($(jq -r --arg id "$(iid $n)" '.issues[$id].stop_reason // "?"' "$(LEDGER_OF)")): stopped" "$(lget "$(iid $n)")" "stopped"
  assert_eq "PROJ-$n: one stopped notice under the pinned slug with PROJECT_CHANGED" \
    "$(jq -r '"\(.reason) \(.slug)"' "$STATE"/paperclip/notices/proj/*."$(iid $n)".stopped.json 2>/dev/null)" "PROJECT_CHANGED proj"
done
assert_missing "nothing is written under the new project's slug" "$STATE/paperclip/notices/proj2"
assert_eq "the working slot is released: the queued issue is promoted" "$(lget "$(iid 4)")" "working"
assert_eq "  ...its promoted notice goes to its pinned slug" "$(ls "$STATE"/paperclip/notices/proj/*."$(iid 4)".promoted.json | wc -l | tr -d ' ')" "1"
assert_eq "a comment naming another repo or slug still lands under the pinned slug" \
  "$(ls "$STATE"/paperclip/notices/proj/*."$(iid 4)".human_commented.json | wc -l | tr -d ' ')" "1"
assert_eq "a deleted pinned project: held on the first 404" "$(lget "$(iid 5)")" "working"
assert_contains "stopped issues are self-blocked with the stop text" "$(cat "$BODYLOG")" "Stopped: project changed after claim; reassign to restart"
issue 1 in_progress null
route GET "/api/issues/$(iid 1)/active-run" 200 '{"id":"run-w"}'
: >"$BODYLOG"
run_afk --json
assert_eq "a Paperclip wake on a stopped issue is re-blocked with the stop text" "$(last_block)" "Stopped: project changed after claim; reassign to restart"
assert_eq "  ...it stays stopped, with no second notice" \
  "$(lget "$(iid 1)") $(ls "$STATE"/paperclip/notices/proj/*."$(iid 1)".stopped.json | wc -l | tr -d ' ')" "stopped 1"
run_afk --json
assert_eq "a deleted pinned project: stopped on the third consecutive 404" "$(lget "$(iid 5)") $(lget "$(iid 5)" .stop_reason)" "stopped PROJECT_CHANGED"

# ============================================================================
head1 "19. Capacity per project and per host, FIFO promotion (HA-2, AD-24)"
# ============================================================================
REPO3="$TMPROOT/repos/repo3"; mkrepo "$REPO3"
three_projects() { # proj, proj2 and proj3, all cap 1: no caller ever overrides proj's cap
  write_config "[$(proj_json "$(pid_n 1)" proj "$REPO1" 1), $(proj_json "$(pid_n 2)" proj2 "$REPO2"), $(proj_json "$(pid_n 3)" proj3 "$REPO3")]"
}

cfg_ok() { # <name> <jq-edit> -- the config loads and a pass completes
  new_scenario "$1"; three_projects; set_cfg "$2"; inbox; run_afk
  assert_eq "$1: loads" "$RC" "0"
}
cfg_ok cfg_host_cap_set '.host.max_active_issues = 5'
cfg_refused cfg_host_cap_zero '.host.max_active_issues = 0' PAPERCLIP_CONFIG_INVALID
cfg_refused cfg_host_cap_text '.host.max_active_issues = "2"' PAPERCLIP_CONFIG_INVALID
cfg_refused cfg_host_cap_fraction '.host.max_active_issues = 1.5' PAPERCLIP_CONFIG_INVALID
cfg_refused cfg_intermittent_text '.host.intermittent = "yes"' PAPERCLIP_CONFIG_INVALID

# AC-2/AC-4/AC-5: two projects adopt, a third queues on the host cap, and a
# second issue in a full project names that project's holder (it outranks the
# host text). A refused issue (waiting_setup) holds no slot.
new_scenario cap_adopt
three_projects
inbox 8 1 2 3 4
issue 8 in_progress "\"$UNMAPPED_P\""
issue 1 in_progress "\"$(pid_n 1)\""
issue 2 in_progress "\"$(pid_n 2)\""
issue 3 in_progress "\"$(pid_n 3)\""
issue 4 in_progress "\"$(pid_n 1)\""
run_afk --json
assert_eq "a refused issue holds no slot: both projects adopt (host 2/2)" "$(lget "$(iid 8)") $(lget "$(iid 1)") $(lget "$(iid 2)")" "waiting_setup working working"
assert_eq "a third project is queued on the host cap, with the exact text" "$(lget "$(iid 3)") $(lget "$(iid 3)" .action_text)" "queued queued: test-host busy (2/2 active)"
assert_eq "  ...and the text is what was sent to Paperclip" "$(grep -c 'queued: test-host busy (2/2 active)' "$BODYLOG")" "1"
CAP_ADOPT_LEDGER="$(LEDGER_OF)"
assert_eq "a second issue in a full project queues behind its holder, not on the host" "$(lget "$(iid 4)") $(lget "$(iid 4)" .action_text)" "queued queued behind PROJ-1"

# AC-3: a freed slot goes to the oldest queued issue whose project has room.
# PROJ-1 (proj) waits on a human and still holds proj's slot, so the older
# PROJ-5 is skipped; PROJ-6 (proj3) is next; the host is then full for PROJ-7.
new_scenario cap_fifo
three_projects
seed 1 waiting_human proj "$(pid_n 1)" 2025-12-01T00:00:00Z
seed 2 working proj2 "$(pid_n 2)" 2025-12-01T00:00:00Z
seed 5 queued proj "$(pid_n 1)" 2026-01-01T00:00:05Z
seed 7 queued proj2 "$(pid_n 2)" 2026-01-01T00:00:07Z
seed 6 queued proj3 "$(pid_n 3)" 2026-01-01T00:00:06Z
inbox 7 6 5 2 1
issue 1 blocked "\"$(pid_n 1)\""; issue 5 blocked "\"$(pid_n 1)\""
issue 6 blocked "\"$(pid_n 3)\""; issue 7 blocked "\"$(pid_n 2)\""
issue 2 cancelled "\"$(pid_n 2)\""
run_afk --json
assert_eq "waiting_human holds a slot: the older queued issue in that project is skipped" "$(lget "$(iid 1)") $(lget "$(iid 5)")" "waiting_human queued"
assert_eq "the oldest eligible issue is promoted, whatever the inbox order" "$(lget "$(iid 6)")" "working"
assert_eq "  ...with one promoted notice under its own slug" "$(ls "$STATE"/paperclip/notices/proj3/*."$(iid 6)".promoted.json | wc -l | tr -d ' ')" "1"
assert_eq "the host is full again (waiting_human + promoted): the last one stays queued" "$(lget "$(iid 7)")" "queued"
assert_eq "the closed issue's slot was released, so nothing else was promoted" "$(jq -r '[.issues[] | select(.state == "working" or .state == "waiting_human")] | length' "$(LEDGER_OF)")" "2"

# The queue is ordered by a fixed queued_at, not by `since`, which every
# handled comment moves forward: PROJ-5 (queued first) gets a new comment and
# must still be promoted ahead of PROJ-6.
new_scenario cap_fifo_comment
three_projects
seed 1 working proj "$(pid_n 1)" 2025-12-01T00:00:00Z
seed 2 working proj2 "$(pid_n 2)" 2025-12-01T00:00:00Z
seed 5 queued proj3 "$(pid_n 3)" 2026-01-01T00:00:05Z
seed 6 queued proj2 "$(pid_n 2)" 2026-01-01T00:00:06Z
jq --arg a "$(iid 5)" --arg b "$(iid 6)" '.issues[$a].queued_at = "2026-01-01T00:00:05Z" | .issues[$b].queued_at = "2026-01-01T00:00:06Z"' \
  "$(LEDGER_OF)" >"$(LEDGER_OF).t" && mv "$(LEDGER_OF).t" "$(LEDGER_OF)"
inbox 6 5 1 2
issue 1 blocked "\"$(pid_n 1)\""; issue 5 blocked "\"$(pid_n 3)\""; issue 6 blocked "\"$(pid_n 2)\""
issue 2 cancelled "\"$(pid_n 2)\""
route GET "/api/issues/$(iid 5)/comments" 200 \
  "[{\"id\":\"c0000000-0000-0000-0000-00000000000a\",\"body\":\"still there?\",\"authorUserId\":\"$BOARD\",\"authorAgentId\":null,\"createdAt\":\"2026-03-01T00:00:00Z\"}]"
run_afk --json
assert_eq "a comment on the older queued issue does not send it to the back" "$(lget "$(iid 5)") $(lget "$(iid 6)")" "working queued"
assert_eq "  ...its comment was handled (since moved past the other issue's)" "$(lget "$(iid 5)" .since)" "2026-03-01T00:00:00Z"
assert_eq "queued_at is dropped on promotion and kept while queued" "$(lget "$(iid 5)" '.queued_at // "none"') $(lget "$(iid 6)" .queued_at)" "none 2026-01-01T00:00:06Z"

# A newly queued issue gets queued_at once; a stopped one loses it.
assert_eq "an issue queued in cap_adopt has a queued_at" "$(jq -r --arg id "$(iid 3)" '.issues[$id].queued_at != null' "$CAP_ADOPT_LEDGER")" "true"

# The queued text follows the reason. PROJ-3 queued because the host was full;
# once PROJ-2 is gone the host has room but PROJ-1 still holds proj's slot, so
# the text changes to name it -- written once, then left alone.
new_scenario cap_text_refresh
three_projects
seed 1 working proj "$(pid_n 1)" 2025-12-01T00:00:00Z
seed 2 working proj2 "$(pid_n 2)" 2025-12-01T00:00:00Z
seed 3 queued proj "$(pid_n 1)" 2026-01-01T00:00:03Z
jq --arg id "$(iid 3)" '.issues[$id] += {action_text: "queued: test-host busy (2/2 active)", action_text_applied: "queued: test-host busy (2/2 active)"}' \
  "$(LEDGER_OF)" >"$(LEDGER_OF).t" && mv "$(LEDGER_OF).t" "$(LEDGER_OF)"
inbox 1 2 3
issue 1 blocked "\"$(pid_n 1)\""; issue 2 cancelled "\"$(pid_n 2)\""; issue 3 blocked "\"$(pid_n 1)\""
run_afk --json
assert_eq "the reason changed from host-full to project-full: the text is rewritten" "$(last_block)" "queued behind PROJ-1"
assert_eq "  ...in the ledger too, and the issue stays queued" "$(lget "$(iid 3)") $(lget "$(iid 3)" .action_text_applied)" "queued queued behind PROJ-1"
p3="$(grep -c "^PATCH /api/issues/$(iid 3)$" "$LOG")"
run_afk --json
assert_eq "nothing changed on the next pass: no second write for it" "$(grep -c "^PATCH /api/issues/$(iid 3)$" "$LOG")" "$p3"

# F1: a promoted issue must not keep the queued text it was blocked with.
new_scenario cap_promoted_text
three_projects
seed 1 working proj "$(pid_n 1)" 2025-12-01T00:00:00Z
seed 5 queued proj "$(pid_n 1)" 2026-01-01T00:00:05Z
jq --arg id "$(iid 5)" '.issues[$id] += {queued_at: "2026-01-01T00:00:05Z", action_text: "queued behind PROJ-1", action_text_applied: "queued behind PROJ-1"}' \
  "$(LEDGER_OF)" >"$(LEDGER_OF).t" && mv "$(LEDGER_OF).t" "$(LEDGER_OF)"
inbox 1 5
issue 1 cancelled "\"$(pid_n 1)\""; issue 5 blocked "\"$(pid_n 1)\""
run_afk --json
assert_eq "the promoted issue is rewritten to the working text, in Paperclip and in the ledger" \
  "$(lget "$(iid 5)") $(last_block) $(lget "$(iid 5)" .action_text_applied)" "working AFK host is working on this AFK host is working on this"
p5="$(grep -c "^PATCH /api/issues/$(iid 5)$" "$LOG")"
run_afk --json
assert_eq "  ...and only once" "$(grep -c "^PATCH /api/issues/$(iid 5)$" "$LOG")" "$p5"

# Wake path (F2): PROJ-3 is queued behind PROJ-1 and stays so, with the
# project text; PROJ-4 (free project, free host) is promoted and is never
# blocked with a "busy" text.
new_scenario cap_wake
three_projects
seed 1 working proj "$(pid_n 1)" 2025-12-01T00:00:00Z
seed 3 queued proj "$(pid_n 1)" 2026-01-01T00:00:03Z
seed 4 queued proj3 "$(pid_n 3)" 2026-01-01T00:00:04Z
inbox 1 3 4
issue 1 blocked "\"$(pid_n 1)\""; issue 3 in_progress "\"$(pid_n 1)\""; issue 4 in_progress "\"$(pid_n 3)\""
run_afk --json
assert_eq "a wake on a queued issue in a full project keeps the project text" "$(lget "$(iid 3)") $(lget "$(iid 3)" .action_text)" "queued queued behind PROJ-1"
assert_eq "a wake on a queued issue with room is promoted" "$(lget "$(iid 4)")" "working"
assert_absent "  ...and no busy text is ever sent for it" "$(cat "$BODYLOG")" "busy ("
assert_absent "  ...and no self-block ever carries an empty action" "$(cat "$BODYLOG")" '"action":""'
assert_eq "  ...its ledger text is not a queued text" "$(lget "$(iid 4)" .action_text_applied)" "AFK host is working on this"

# A legacy queued row has no action_text: a wake on it with room never sends
# the literal "null" as the self-block text.
new_scenario cap_wake_legacy
three_projects
seed 4 queued proj3 "$(pid_n 3)" 2026-01-01T00:00:04Z
jq --arg id "$(iid 4)" 'del(.issues[$id].action_text, .issues[$id].action_text_applied)' "$(LEDGER_OF)" >"$(LEDGER_OF).t" && mv "$(LEDGER_OF).t" "$(LEDGER_OF)"
inbox 4
issue 4 in_progress "\"$(pid_n 3)\""
run_afk --json
assert_absent "a wake on a legacy queued row without action_text never sends null" "$(cat "$BODYLOG")" '"action":"null"'
assert_eq "  ...it falls to the default text" "$(lget "$(iid 4)") $(lget "$(iid 4)" .action_text_applied)" "working AFK host is working on this"

# F3: PROJ-3 (pending_claim, the oldest ledger row, so handled first) queues
# on the host cap, then PROJ-2 closes later in the same pass. PROJ-3 is not
# promoted this pass, and no text may claim the host is at 1/2.
new_scenario cap_text_same_pass
three_projects
seed 3 pending_claim proj3 "$(pid_n 3)" 2025-11-01T00:00:03Z
seed 1 working proj "$(pid_n 1)" 2025-12-01T00:00:00Z
seed 2 working proj2 "$(pid_n 2)" 2025-12-02T00:00:00Z
inbox 3 1 2
issue 3 blocked "\"$(pid_n 3)\""; issue 1 blocked "\"$(pid_n 1)\""; issue 2 cancelled "\"$(pid_n 2)\""
run_afk --json
assert_eq "PROJ-3 queued on the host cap this pass, and is promoted only on the next" "$(lget "$(iid 3)")" "queued"
assert_absent "  ...and no busy text with n below the cap is written when a slot frees mid-pass" "$(lget "$(iid 3)" .action_text)$(cat "$BODYLOG")" "busy ("

# The pending_claim path honours the host cap.
new_scenario cap_pending_claim
three_projects
seed 1 working proj "$(pid_n 1)" 2025-12-01T00:00:00Z
seed 2 working proj2 "$(pid_n 2)" 2025-12-01T00:00:00Z
seed 3 pending_claim proj3 "$(pid_n 3)" 2026-01-01T00:00:03Z
inbox 1 2 3
issue 1 blocked "\"$(pid_n 1)\""; issue 2 blocked "\"$(pid_n 2)\""; issue 3 blocked "\"$(pid_n 3)\""
run_afk --json
assert_eq "a pending_claim issue is queued on the host cap, not started" "$(lget "$(iid 3)") $(lget "$(iid 3)" .action_text)" "queued queued: test-host busy (2/2 active)"

# A legacy queued entry has no queued_at: it falls back to since. PROJ-6 is older
# but has the higher id, so key order alone would pick PROJ-5.
new_scenario cap_legacy_queued
three_projects
seed 1 working proj "$(pid_n 1)" 2025-12-01T00:00:00Z
seed 5 queued proj3 "$(pid_n 3)" 2026-01-01T00:00:05Z
seed 6 queued proj2 "$(pid_n 2)" 2026-01-01T00:00:03Z
inbox 5 6 1
issue 1 blocked "\"$(pid_n 1)\""; issue 5 blocked "\"$(pid_n 3)\""; issue 6 blocked "\"$(pid_n 2)\""
run_afk --json
assert_eq "a queued entry without queued_at is ordered by since" "$(lget "$(iid 6)") $(lget "$(iid 5)")" "working queued"

# waiting_human holds a slot, so it must release the host slot at every site
# that ends it: closed, stranded (foreign owner and board recovery) and a
# changed project. PROJ-4 (proj3) is queued only because the host is full.
release_case() { # <name> <how>
  new_scenario "$1"
  three_projects
  seed 1 waiting_human proj "$(pid_n 1)" 2025-12-01T00:00:00Z
  seed 2 working proj2 "$(pid_n 2)" 2025-12-01T00:00:00Z
  seed 4 queued proj3 "$(pid_n 3)" 2026-01-01T00:00:04Z
  inbox 1 2 4
  issue 2 blocked "\"$(pid_n 2)\""; issue 4 blocked "\"$(pid_n 3)\""
  case "$2" in
    closed) issue 1 cancelled "\"$(pid_n 1)\"" ;;
    project) issue 1 blocked "\"$(pid_n 3)\"" ;;
    stranger)
      issue 1 blocked "\"$(pid_n 1)\""
      route GET "/api/issues/$(iid 1)" 200 "{\"status\":\"blocked\",\"identifier\":\"PROJ-1\",\"projectId\":\"$(pid_n 1)\",\"unblockDescriptor\":{\"owner\":{\"agentId\":\"$STRANGER\"}}}"
      route POST "/api/companies/$COMPANY/issues" 201 '{"id":"f0000000-0000-0000-0000-000000000001"}' ;;
    recovery)
      issue 1 blocked "\"$(pid_n 1)\""
      route GET "/api/issues/$(iid 1)" 200 "{\"status\":\"blocked\",\"identifier\":\"PROJ-1\",\"projectId\":\"$(pid_n 1)\",\"unblockDescriptor\":{\"owner\":{\"agentId\":\"$AGENT1\"}},\"activeRecoveryAction\":{\"status\":\"active\",\"ownerType\":\"board\"}}"
      route POST "/api/companies/$COMPANY/issues" 201 '{"id":"f0000000-0000-0000-0000-000000000001"}' ;;
  esac
  run_afk --json
  assert_eq "waiting_human released at the $2 site: the queued issue is promoted (host 2/2 -> 1/2)" \
    "$(lget "$(iid 1)") $(lget "$(iid 4)")" "$3 working"
}
release_case rel_closed closed closed
release_case rel_project project stopped
release_case rel_stranger stranger stranded
release_case rel_recovery recovery stranded

# AC-1: an intermittent host defaults to one slot.
new_scenario cap_intermittent
three_projects
set_cfg '.host.intermittent = true'
inbox 1 2
issue 1 in_progress "\"$(pid_n 1)\""
issue 2 in_progress "\"$(pid_n 2)\""
run_afk --json
assert_eq "an intermittent host defaults to 1: the second project queues on the host" "$(lget "$(iid 1)") $(lget "$(iid 2)") $(lget "$(iid 2)" .action_text)" "working queued queued: test-host busy (1/1 active)"

new_scenario cap_intermittent_explicit
three_projects
set_cfg '.host.intermittent = true | .host.max_active_issues = 2'
inbox 1 2
issue 1 in_progress "\"$(pid_n 1)\""
issue 2 in_progress "\"$(pid_n 2)\""
run_afk --json
assert_eq "an explicit host.max_active_issues wins over the intermittent default" "$(lget "$(iid 1)") $(lget "$(iid 2)")" "working working"

# ============================================================================
head1 "20. Pull adoption, resume, nudge, strand repair, reconciliation (HA-4a, AD-26)"
# ============================================================================
PULL_HB='{"enabled":true,"intervalSec":0,"wakeOnDemand":false}'
me_hb() { route GET /api/agents/me 200 "{\"id\":\"$AGENT1\",\"runtimeConfig\":${1:-null}}"; }
pull_mode() { set_cfg '.host.adoption = "pull"'; me_hb "{\"heartbeat\":$PULL_HB}"; }
posts_to() { grep -c "^POST /api/issues/$1/comments$" "$LOG"; }
lset() { jq --arg id "$(iid "$1")" ".issues[\$id] += $2" "$(LEDGER_OF)" >"$(LEDGER_OF).t" && mv "$(LEDGER_OF).t" "$(LEDGER_OF)"; }

# AC-1, AC-2: the value is validated at load and the agent's heartbeat is
# checked against it on every pass, in each direction.
cfg_refused cfg_adoption_bad '.host.adoption = "push"' PAPERCLIP_CONFIG_INVALID
mode_mismatch() { # <name> <adoption> <runtimeConfig-json>
  new_scenario "$1"; three_projects; inbox 1; issue 1 in_progress "\"$(pid_n 1)\""
  set_cfg ".host.adoption = \"$2\""; me_hb "$3"
  run_afk --json
  assert_eq "$1: the pass ends with PAPERCLIP_ADOPTION_MODE_MISMATCH" "$RC $(jq -r '.result + " " + .agents[0].result' <<<"$OUT_TEXT" 2>/dev/null | head -1)" \
    "1 PAPERCLIP_ADOPTION_MODE_MISMATCH PAPERCLIP_ADOPTION_MODE_MISMATCH"
  assert_eq "$1: nothing claimed, nothing written, the inbox never read" \
    "$(grep -c -e '^POST' -e '^PATCH' -e 'inbox-lite' "$LOG")$(lget "$(iid 1)")" "0"
}
mode_mismatch mode_lease_vs_pull lease "{\"heartbeat\":$PULL_HB}"
mode_mismatch mode_pull_vs_lease pull '{"heartbeat":{"enabled":true,"intervalSec":0,"wakeOnDemand":true}}'
mode_mismatch mode_pull_interval pull '{"heartbeat":{"enabled":true,"intervalSec":300,"wakeOnDemand":false}}'
mode_mismatch mode_no_fields pull null
mode_mismatch mode_lease_no_fields lease null

# AC-3: a todo issue is adopted by the host's own cycle: self-wake with the
# issueId, in_progress, the claim comment, then the self-block. A second issue
# in the same project queues; one this host can't take ends self-blocked with
# its reason, never left in todo. A second pass (now blocked) claims nothing new.
new_scenario pull_adopt
three_projects
inbox 1 8 4
pull_mode
issue 1 todo "\"$(pid_n 1)\""; issue 8 todo "\"$UNMAPPED_P\""; issue 4 todo "\"$(pid_n 1)\""
run_afk --json
assert_eq "pull: adopted, queued behind it, refused" "$(lget "$(iid 1)") $(lget "$(iid 4)") $(lget "$(iid 8)")" "working queued waiting_setup"
assert_contains "pull: the self-wake names the issue" "$(cat "$BODYLOG")" "{\"source\":\"timer\",\"payload\":{\"issueId\":\"$(iid 1)\"}}"
assert_eq "pull: in_progress, claim comment, self-block, in that order" \
  "$(grep -e "/api/issues/$(iid 1)" "$LOG" | grep -v -e '^GET' | tr '\n' '|')" \
  "PATCH /api/issues/$(iid 1)|POST /api/issues/$(iid 1)/comments|PATCH /api/issues/$(iid 1)|"
assert_eq "pull: one claim comment each for the adopted and the queued issue, none for the refused" \
  "$(posts_to "$(iid 1)") $(posts_to "$(iid 4)") $(posts_to "$(iid 8)")" "1 1 0"
assert_eq "pull: the refused issue is self-blocked with its reason" \
  "$(grep -c "^PATCH /api/issues/$(iid 8)$" "$LOG") $([[ "$(lget "$(iid 8)" .action_text_applied)" == "$(lget "$(iid 8)" .fixed_text)" ]] && echo same) $(lget "$(iid 8)" .fixed_text | cut -c1-17)" \
  "2 same Waiting for Josh:"
assert_eq "pull: the queued issue carries the queue text" "$(lget "$(iid 4)" .action_text_applied)" "queued behind PROJ-1"
: >"$LOG"
issue 1 blocked "\"$(pid_n 1)\""; issue 4 blocked "\"$(pid_n 1)\""; issue 8 blocked "\"$UNMAPPED_P\""
run_afk --json
assert_eq "pull, second pass: no new claim, nothing written" "$(grep -c -e '^POST' -e '^PATCH' "$LOG")" "0"

# AC-3 (lease regression): a lease host still leaves an unheld todo alone.
new_scenario lease_todo
three_projects; inbox 1; issue 1 todo "\"$(pid_n 1)\""
run_afk --json
assert_eq "lease: an unheld todo issue is left alone" "$(grep -c -e '^POST' -e '^PATCH' "$LOG")$(lget "$(iid 1)")" "0"

# AC-4 (F7): stranded and held_by_board issues set to Todo are resumed: one
# resume comment, the state the hold interrupted, since and the open question
# kept, and a stranded issue's recovery issue closed in the same pass.
REC="f0000000-0000-0000-0000-0000000000aa"
new_scenario resume_held
three_projects
seed 1 stranded proj "$(pid_n 1)" 2026-01-01T00:00:01Z
lset 1 "{resume_state:\"waiting_human\", question_id:\"q-7\", question_seq:4, recovery_issue_id:\"$REC\", action_text_applied:\"waiting on q-7\"}"
seed 2 held_by_board proj2 "$(pid_n 2)"; lset 2 '{resume_state:"working"}'
jq --arg id "$(iid 1)" '.stranded_reported = [$id]' "$(LEDGER_OF)" >"$(LEDGER_OF).t" && mv "$(LEDGER_OF).t" "$(LEDGER_OF)"
inbox 1 2
issue 1 todo "\"$(pid_n 1)\""; issue 2 todo "\"$(pid_n 2)\""
route PATCH "/api/issues/$REC" 200 '{}'
for mode in lease pull; do
  [[ "$mode" == pull ]] && { : >"$LOG"; : >"$BODYLOG"; pull_mode; }
  [[ "$mode" == lease ]] && cp "$(LEDGER_OF)" "$SCEN/seeded.json"
  [[ "$mode" == pull ]] && cp "$SCEN/seeded.json" "$(LEDGER_OF)"
  run_afk --json
  assert_eq "resume ($mode): restored states" "$(lget "$(iid 1)") $(lget "$(iid 2)")" "waiting_human working"
  assert_eq "resume ($mode): one resume comment each" "$(grep -c 'resumed by AFK PM (test-host)' "$BODYLOG")" "2"
  assert_eq "resume ($mode): since, question and seq kept" "$(lget "$(iid 1)" .since) $(lget "$(iid 1)" .question_id) $(lget "$(iid 1)" .question_seq)" "2026-01-01T00:00:01Z q-7 4"
  assert_eq "resume ($mode): re-blocked with the last applied text" "$(lget "$(iid 1)" .action_text_applied)" "waiting on q-7"
  assert_eq "resume ($mode): the recovery issue is closed, once" "$(grep -c "^PATCH /api/issues/$REC$" "$LOG")" "1"
  assert_eq "resume ($mode): no claim comment" "$(grep -c 'claimed by AFK PM' "$BODYLOG")" "0"
done

# AC-4 (P6d): a comment reopened a waiting_human issue. The nudge scans the
# comments (Josh's `approve <digest8>` becomes the approval record), posts no
# comment at all, and re-blocks.
for mode in lease pull; do
  new_scenario "nudge_approve_$mode"
  write_config
  jq --argjson i "$PATT" '.interim_comment_approval = $i' "$CONFIG" >"$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  seed_working "$ISSUE1" HOM-12 waiting_human \
    "{\"question_id\":\"plan-$PD8\",\"question_seq\":3,\"question_sent_at\":\"2026-03-01T00:00:00.000Z\",\"action_text_applied\":\"waiting on plan-$PD8\"}"
  mkdir -p "$STATE/paperclip/plans"
  jq -nc --arg d "$PD" '{schema:"afk-paperclip-plan-record/1", digest:$d, digest8:$d[0:8], question_id:("plan-" + $d[0:8]), posted_seq:3, state:"posted"}' \
    >"$STATE/paperclip/plans/$ISSUE1.json"
  route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
  [[ "$mode" == pull ]] && pull_mode
  route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
  route GET "/api/issues/$ISSUE1" 200 '{"status":"todo","identifier":"HOM-12"}'
  route GET "/api/issues/$ISSUE1/comments" 200 "[$(jc 1 "approve $PD8")]"
  route GET "/api/issues/$ISSUE1/approvals" 200 '[]'
  route GET /api/health 200 "{\"commit\":\"$PCOMMIT\"}"
  route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-n"}'
  route PATCH "/api/issues/$ISSUE1" 200 '{}'
  run_afk --json
  assert_eq "nudge ($mode): the approve comment is the approval record" "$(jq -r '.kind + " " + .digest' "$STATE/paperclip/approvals/$ISSUE1.json" 2>/dev/null)" "plan $PD"
  assert_eq "nudge ($mode): no comment posted" "$(grep -c "^POST /api/issues/$ISSUE1/comments$" "$LOG")" "0"
  assert_eq "nudge ($mode): in_progress then the re-block, still waiting_human" \
    "$(grep -c "^PATCH /api/issues/$ISSUE1$" "$LOG") $(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$STATE/paperclip/ledger.json")" "2 waiting_human"
  assert_contains "nudge ($mode): re-blocked with the open question" "$(last_block)" "waiting on plan-$PD8"
done

# AC-4: a nudge on a queued issue keeps its place (queued_at) and posts nothing.
new_scenario nudge_queued
three_projects
seed 1 working proj "$(pid_n 1)"; seed 2 working proj2 "$(pid_n 2)"
seed 5 queued proj3 "$(pid_n 3)" 2026-01-01T00:00:05Z; seed 6 queued proj3 "$(pid_n 3)" 2026-01-01T00:00:06Z
lset 5 '{queued_at:"2026-01-01T00:00:05Z", action_text:"queued: test-host busy (2/2 active)", action_text_applied:"queued: test-host busy (2/2 active)"}'
lset 6 '{queued_at:"2026-01-01T00:00:06Z", action_text:"queued: test-host busy (2/2 active)", action_text_applied:"queued: test-host busy (2/2 active)"}'
inbox 1 2 5 6
pull_mode
issue 1 blocked "\"$(pid_n 1)\""; issue 2 blocked "\"$(pid_n 2)\""; issue 5 blocked "\"$(pid_n 3)\""; issue 6 todo "\"$(pid_n 3)\""
route GET "/api/issues/$(iid 6)/comments" 200 "[{\"id\":\"c0000000-0000-0000-0000-00000000000b\",\"body\":\"any news?\",\"authorUserId\":\"$BOARD\",\"authorAgentId\":null,\"createdAt\":\"2026-03-01T00:00:00Z\"}]"
run_afk --json
assert_eq "nudge (queued): still queued, same queued_at, comment handled" \
  "$(lget "$(iid 6)") $(lget "$(iid 6)" .queued_at) $(lget "$(iid 6)" .since)" "queued 2026-01-01T00:00:06Z 2026-03-01T00:00:00Z"
assert_eq "nudge (queued): nothing posted, re-blocked with the queue text" \
  "$(posts_to "$(iid 6)") $(last_block)" "0 queued: test-host busy (2/2 active)"
assert_eq "nudge (queued): the other queued issue is untouched" "$(lget "$(iid 5)") $(grep -c "^PATCH /api/issues/$(iid 5)$" "$LOG")" "queued 0"

# AC-5 (P8a): in_progress with no active run. Held issues are repaired by a
# self-wake and the re-block (or the pending final); an unheld one keeps the
# log line.
new_scenario strand_repair
three_projects
seed 1 working proj "$(pid_n 1)"; seed 2 working proj2 "$(pid_n 2)"; lset 2 '{pending_final:"in_review"}'
inbox 1 2 3
issue 1 in_progress "\"$(pid_n 1)\""; issue 2 in_progress "\"$(pid_n 2)\""; issue 3 in_progress "\"$(pid_n 3)\""
for n in 1 2 3; do route GET "/api/issues/$(iid $n)/active-run" 200 'null'; done
run_afk --json
assert_eq "strand repair: one report per repaired issue" "$(grep -o 'PAPERCLIP_STRAND_REPAIRED: PROJ-[0-9]' <<<"$OUT_TEXT" | sort | tr '\n' ' ')" "PAPERCLIP_STRAND_REPAIRED: PROJ-1 PAPERCLIP_STRAND_REPAIRED: PROJ-2 "
assert_eq "strand repair: re-blocked with the last applied text, still working" "$(lget "$(iid 1)") $(lget "$(iid 1)" .action_text_applied)" "working AFK host is working on this"
assert_contains "strand repair: the pending final is re-sent" "$(cat "$BODYLOG")" '{"status":"in_review"}'
assert_eq "strand repair: the final closes the issue" "$(lget "$(iid 2)")" "closed"
assert_contains "strand repair: an unheld issue keeps the log line" "$OUT_TEXT" "in_progress without a live run, left alone: PROJ-3"
assert_eq "strand repair: nothing written to the unheld issue" "$(grep -c -e "^PATCH /api/issues/$(iid 3)$" -e "^POST /api/issues/$(iid 3)/" "$LOG")" "0"

new_scenario strand_no_run
three_projects
seed 1 working proj "$(pid_n 1)"
inbox 1; issue 1 in_progress "\"$(pid_n 1)\""
route GET "/api/issues/$(iid 1)/active-run" 200 'null'
route POST "/api/agents/$AGENT1/wakeup" 202 '{}'
run_afk --json
assert_contains "strand repair: a 202 with no run id is held and reported" "$OUT_TEXT" "self-wake returned no run, held: PROJ-1"
assert_eq "  ...nothing written, no repair claimed" "$(grep -c '^PATCH' "$LOG") $(grep -c 'STRAND_REPAIRED' <<<"$OUT_TEXT")" "0 0"

# AC-6 (P8b): a self-wake refused with execution_reconciliation_required parks
# the issue and opens exactly one NEEDS HUMAN issue across three passes.
new_scenario reconcile
three_projects
seed 1 working proj "$(pid_n 1)"
inbox 1; pull_mode; issue 1 todo "\"$(pid_n 1)\""
route POST "/api/agents/$AGENT1/wakeup" 409 '{"error":"Issue execution needs reconciliation","code":"execution_reconciliation_required"}'
route POST "/api/companies/$COMPANY/issues" 201 '{"id":"f0000000-0000-0000-0000-0000000000bb"}'
for pass in 1 2 3; do run_afk --json; done
assert_eq "reconcile: parked, slot released" "$(lget "$(iid 1)")" "reconciliation_blocked"
assert_eq "reconcile: exactly one NEEDS HUMAN issue over three passes" "$(grep -c "^POST /api/companies/$COMPANY/issues$" "$LOG")" "1"
assert_contains "reconcile: the issue names the fix, keyed by the issue id" "$(cat "$BODYLOG")" "\"title\":\"NEEDS HUMAN: cancel PROJ-1 and recreate it\""
assert_contains "  ...idempotent" "$(cat "$BODYLOG")" "\"idempotencyKey\":\"afk-recon-$(iid 1)\""
assert_eq "reconcile: one self-wake in all (then skipped)" "$(grep -c "^POST /api/agents/$AGENT1/wakeup$" "$LOG")" "1"
assert_eq "reconcile: one stopped notice with the reason" \
  "$(cat "$STATE"/paperclip/notices/proj/*."$(iid 1)".stopped.json 2>/dev/null | jq -r .reason)" "RECONCILIATION_REQUIRED"
assert_contains "reconcile: a later pass reports it locally" "$OUT_TEXT" "PAPERCLIP_RECONCILIATION_REQUIRED, held: PROJ-1"

# AC-7 (F3): approvals are listed every pass for every waiting_human issue; a
# failed read is reported and the pass still completes.
new_scenario approvals_read
three_projects
seed 1 waiting_human proj "$(pid_n 1)"; lset 1 '{question_id:"q-1", action_text_applied:"waiting on q-1"}'
seed 2 waiting_human proj2 "$(pid_n 2)"; lset 2 '{question_id:"q-2", action_text_applied:"waiting on q-2"}'
seed 3 working proj3 "$(pid_n 3)"
inbox 1 2 3
issue 1 blocked "\"$(pid_n 1)\""; issue 2 blocked "\"$(pid_n 2)\""; issue 3 blocked "\"$(pid_n 3)\""
route GET "/api/issues/$(iid 1)/approvals" 200 '[{"id":"ap-1","type":"approve_plan","status":"approved","payload":{"x":1}}]'
route GET "/api/issues/$(iid 2)/approvals" 500 '{}'
run_afk --json
assert_eq "approvals: recorded for PC-8" "$(lget "$(iid 1)" '.approvals_seen.items | tojson')" '[{"id":"ap-1","type":"approve_plan","status":"approved"}]'
assert_contains "approvals: a failed read is reported as not read" "$OUT_TEXT" "PAPERCLIP_APPROVALS_UNREADABLE, approvals not read: PROJ-2"
assert_eq "approvals: the pass completes; a working issue is not read" \
  "$(jq -r .result <<<"$OUT_TEXT" 2>/dev/null | head -1) $(grep -c "^GET /api/issues/$(iid 3)/approvals$" "$LOG")" "completed 0"

# Review M1: only a readable "no run" is a strand. A failed /active-run read
# may hide a run AFK didn't mint, so it holds and reports, writing nothing.
new_scenario strand_unreadable
three_projects
seed 1 working proj "$(pid_n 1)"
inbox 1; issue 1 in_progress "\"$(pid_n 1)\""
route GET "/api/issues/$(iid 1)/active-run" 500 '{}'
run_afk --json
assert_contains "strand: an unreadable active run is held and reported" "$OUT_TEXT" "active run unreadable, held: PROJ-1"
assert_eq "  ...no self-wake, nothing written, not marked" \
  "$(grep -c -e '^POST' -e '^PATCH' "$LOG") $(lget "$(iid 1)" '.reblock_due // "none"')" "0 none"

# Review L1: a board-held issue in_progress with no run waits for Josh's Todo.
new_scenario strand_board_held
three_projects
seed 1 held_by_board proj "$(pid_n 1)"; lset 1 '{resume_state:"working"}'
inbox 1; issue 1 in_progress "\"$(pid_n 1)\""
route GET "/api/issues/$(iid 1)/active-run" 200 'null'
run_afk --json
assert_eq "strand: a board-held issue is not repaired, still held_by_board" \
  "$(grep -c -e '^POST' -e '^PATCH' "$LOG") $(lget "$(iid 1)")" "0 held_by_board"
assert_contains "  ...and keeps the left-alone line" "$OUT_TEXT" "in_progress without a live run, left alone: PROJ-1"

# Review M2: in lease mode Josh's Todo on a stranded issue arrives as a wake
# (in_progress with a run). The resume restores waiting_human, keeps the open
# question in the block text, drops resume_state, closes the recovery issue,
# and a later approve <digest8> is accepted.
new_scenario resume_lease_wake
write_config
jq --argjson i "$PATT" '.interim_comment_approval = $i' "$CONFIG" >"$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
seed_working "$ISSUE1" HOM-12 stranded \
  "{\"resume_state\":\"waiting_human\",\"question_id\":\"plan-$PD8\",\"question_seq\":3,\"question_sent_at\":\"2026-03-01T00:00:00.000Z\",\"recovery_issue_id\":\"$REC\",\"action_text_applied\":\"waiting on plan-$PD8\"}"
mkdir -p "$STATE/paperclip/plans"
jq -nc --arg d "$PD" '{schema:"afk-paperclip-plan-record/1", digest:$d, digest8:$d[0:8], question_id:("plan-" + $d[0:8]), posted_seq:3, state:"posted"}' \
  >"$STATE/paperclip/plans/$ISSUE1.json"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 '{"status":"in_progress","identifier":"HOM-12","title":"T","description":"D","updatedAt":"x"}'
route GET "/api/issues/$ISSUE1/active-run" 200 '{"id":"run-w","contextSnapshot":{"wakeReason":"issue_status_changed"}}'
route GET "/api/issues/$ISSUE1/approvals" 200 '[]'
route POST "/api/issues/$ISSUE1/comments" 201 '{}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
route PATCH "/api/issues/$REC" 200 '{}'
route GET /api/health 200 "{\"commit\":\"$PCOMMIT\"}"
run_afk --json
assert_eq "lease resume: waiting_human restored, resume_state dropped" \
  "$(jq -r --arg id "$ISSUE1" '.issues[$id] | .state + " " + (.resume_state // "none")' "$STATE/paperclip/ledger.json")" "waiting_human none"
assert_eq "lease resume: the block text keeps the open question" "$(last_block)" "waiting on plan-$PD8"
assert_eq "lease resume: the recovery issue is closed" "$(grep -c "^PATCH /api/issues/$REC$" "$LOG")" "1"
route GET "/api/issues/$ISSUE1" 200 "{\"status\":\"blocked\",\"identifier\":\"HOM-12\",\"unblockDescriptor\":{\"owner\":{\"agentId\":\"$AGENT1\"}}}"
route GET "/api/issues/$ISSUE1/comments" 200 "[$(jc 1 "approve $PD8" 2026-03-02T00:00:00.000Z)]"
run_afk --json
assert_eq "lease resume: a later approve <digest8> is accepted" "$(jq -r '.kind + " " + .digest' "$STATE/paperclip/approvals/$ISSUE1.json" 2>/dev/null)" "plan $PD"

# Only a clean 200/204 with no id at all means "no run". A malformed id or a
# body that isn't JSON may hide a live run, so the issue is held, in the
# in_progress branch and in the stopped branch alike.
STOPT="Stopped: project changed after claim; reassign to restart"
new_scenario strand_malformed
three_projects
seed 1 working proj "$(pid_n 1)"; seed 2 working proj2 "$(pid_n 2)"
seed 3 stopped proj3 "$(pid_n 3)"
lset 3 "{fixed_text:\"$STOPT\", action_text:\"$STOPT\", action_text_applied:\"$STOPT\", stop_reason:\"PROJECT_CHANGED\"}"
inbox 1 2 3
issue 1 in_progress "\"$(pid_n 1)\""; issue 2 in_progress "\"$(pid_n 2)\""; issue 3 in_progress "\"$(pid_n 3)\""
route GET "/api/issues/$(iid 1)/active-run" 200 '{"id":"run 1;x"}'
route GET "/api/issues/$(iid 2)/active-run" 200 'not json'
route GET "/api/issues/$(iid 3)/active-run" 500 '{}'
run_afk --json
assert_contains "no run: a 200 with a malformed run id is held" "$OUT_TEXT" "active run unreadable, held: PROJ-1"
assert_contains "no run: a 200 whose body isn't JSON is held" "$OUT_TEXT" "active run unreadable, held: PROJ-2"
assert_contains "no run: a stopped issue's unreadable active run is held" "$OUT_TEXT" "active run unreadable, held: PROJ-3"
assert_eq "  ...no self-wake, nothing written, none marked for repair" \
  "$(grep -c -e '^POST' -e '^PATCH' "$LOG") $(jq -r '[.issues[] | select(.reblock_due != null)] | length' "$(LEDGER_OF)")" "0 0"

# ===========================================================================
head1 "Review M3: a closed issue reassigned during a pause is a new adoption"
new_scenario closed_reassigned_paused
write_config
mkdir -p "$STATE/paperclip" "$HOME/.config/agent-flow-kit/paperclip" "$STATE/paperclip/notices/proj"
: >"$HOME/.config/agent-flow-kit/paperclip/stop"
old_notice="$STATE/paperclip/notices/proj/1700000000.000000001.$ISSUE1.claimed.json"
old_brief="$STATE/paperclip/notices/proj/brief.$ISSUE1.1700000000.000000001.md"
printf '{}\n' >"$old_notice"; printf 'old\n' >"$old_brief"
jq -nc --arg id "$ISSUE1" --arg a "$AGENT1" --arg p "$PROJ1" --arg n "$old_notice" --arg b "$old_brief" \
  '{issues:{($id):{host_agent_id:$a,paperclip_project_id:$p,slug:"proj",identifier:"PROJ-1",state:"closed",
    since:"2026-01-01T00:00:00Z",claim:"confirmed",claim_attempted:true,claimed_notice:"written",
    claimed_notice_path:$n,claimed_brief:"written",claimed_brief_path:$b,
    claimed_notice_epoch:1700000000,claim_artifact_counter:1}},last_successful_pass:null}' \
  >"$STATE/paperclip/ledger.json"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"in_progress\",\"identifier\":\"PROJ-1\",\"title\":\"T\",\"description\":\"D\",\"updatedAt\":\"2026-02-01T00:00:00Z\"}"
route GET "/api/issues/$ISSUE1/active-run" 200 '{"id":"run-1"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
route POST "/api/issues/$ISSUE1/comments" 201 '{}'
route GET "/api/issues/$ISSUE1/comments" 200 '[]'
run_afk --json
LEDGER="$STATE/paperclip/ledger.json"
assert_eq "M3 paused re-adoption clears old claim state" \
  "$(jq -r --arg id "$ISSUE1" '.issues[$id] | "\(.state) \(.claim // "none") \(.claimed_notice // "none")"' "$LEDGER")" \
  'pending_claim none none'
rm -f "$HOME/.config/agent-flow-kit/paperclip/stop"
run_afk --json
assert_eq "M3 unpaused adoption posts a fresh claim" "$(grep -c 'claimed by AFK PM' "$BODYLOG")" 1
assert_eq "M3 unpaused adoption writes a fresh notice" \
  "$([[ "$(jq -r --arg id "$ISSUE1" '.issues[$id].claimed_notice_path' "$LEDGER")" != "$old_notice" ]] && echo yes)" yes
assert_eq "M3 unpaused adoption writes a fresh brief" \
  "$([[ "$(jq -r --arg id "$ISSUE1" '.issues[$id].claimed_brief_path' "$LEDGER")" != "$old_brief" ]] && echo yes)" yes

# N3: a definite claim POST backoff still leaves the current issue blocked
# before the pass stops, both after a report wake and on fresh adoption.
head1 "Review N3: claim POST backoff retains the self-block"
new_scenario claim_backoff_report
write_config; seed 1 working proj "$PROJ1"; inbox 1; issue 1 blocked "\"$PROJ1\""
lset 1 '{claim:"intent",claim_comment_pending:true,claim_attempted:false,reblock_due:"nudge"}'
claim_backoff_id="$(iid 1)"
route POST "/api/issues/$claim_backoff_id/comments" 429 '{}'
run_afk --json
assert_eq "N3 report: 429 claim sends in_progress and self-block PATCHes" \
  "$(grep -c "^PATCH /api/issues/$claim_backoff_id$" "$LOG")" 2
assert_eq "N3 report: the rejected claim POST was attempted once" \
  "$(grep -c "^POST /api/issues/$claim_backoff_id/comments$" "$LOG")" 1
assert_eq "N3 report: current issue is blocked once" \
  "$(grep -c 'unblockDescriptor' "$BODYLOG")" 1

new_scenario claim_backoff_adoption
write_config; inbox 1; issue 1 in_progress "\"$PROJ1\""
route POST "/api/issues/$claim_backoff_id/comments" 429 '{}'
run_afk --json
assert_eq "N3 adoption: 429 claim still self-blocks" \
  "$(grep -c "^PATCH /api/issues/$claim_backoff_id$" "$LOG")" 1
assert_eq "N3 adoption: the rejected claim POST was attempted once" \
  "$(grep -c "^POST /api/issues/$claim_backoff_id/comments$" "$LOG")" 1
assert_eq "N3 adoption: current issue is blocked once" \
  "$(grep -c 'unblockDescriptor' "$BODYLOG")" 1

# A successful POST is still unconfirmed until the marker read-back works.
# The adoption path must hold the issue without producing PM-facing artifacts.
new_scenario claim_readback_unresolved
write_config; inbox 1; issue 1 in_progress "\"$PROJ1\""
touch "$FIXDIR/.claim_readback_off"
route GET "/api/issues/$claim_backoff_id/comments" 200 '[]'
run_afk --json
assert_eq "review unresolved claim stays pending" \
  "$(jq -r --arg id "$claim_backoff_id" '.issues[$id].state' "$STATE/paperclip/ledger.json")" pending_claim
assert_eq "review unresolved claim writes no claimed notice" \
  "$(find "$STATE/paperclip/notices" -name '*.claimed.json' 2>/dev/null | wc -l | tr -d ' ')" 0
assert_eq "review unresolved claim writes no brief" \
  "$(find "$STATE/paperclip/notices" -name 'brief.*' 2>/dev/null | wc -l | tr -d ' ')" 0
assert_eq "review unresolved claim still self-blocks" \
  "$(grep -c "^PATCH /api/issues/$claim_backoff_id$" "$LOG")" 1

if bash "$KIT_ROOT/tests/paperclip-claim-review-tests.sh"; then ok "review M1/M2 claim regressions"
else bad "review M1/M2 claim regressions"; fi

# ===========================================================================
head1 "21. Question replies: local, bound to the latest question (AFK-PC-DELIVERY-L0)"
# ===========================================================================
# The comment scanner keeps the first qualifying Josh reply as question_reply;
# readiness's own question check (afk_pce_question_closed) reads the row.
row1() { jq -c --arg id "${1:-$ISSUE1}" '.issues[$id]' "$STATE/paperclip/ledger.json"; }
reply_of() { jq -r --arg id "${1:-$ISSUE1}" '.issues[$id].question_reply // "none" | if type == "object" then "\(.question_id) \(.question_seq) \(.comment_id) \(.created_at)" else . end' "$STATE/paperclip/ledger.json"; }
qcheck() { # <ledger-row> -- closed|open, by the reader's check with no plan approved
  if bash -c '. "$1/lib/afk-paperclip-evidence.sh"; afk_pce_question_closed "$2" "" null' _ "$KIT_ROOT" "$1"; then echo closed; else echo open; fi
}
reply_scenario() { # <name> <comments-json> [<ledger-extra-json>]
  local x="${3:-}"; [[ -n "$x" ]] || x='{}'
  new_scenario "$1"; write_config
  seed_working "$ISSUE1" HOM-12 waiting_human "$(jq -nc --argjson x "$x" \
    '{question_id:"q7", question_seq:4, question_sent_at:"2026-03-01T00:00:00.000Z", action_text_applied:"waiting on q7"} + $x')"
  route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
  route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
  route GET "/api/issues/$ISSUE1" 200 "{\"status\":\"blocked\",\"identifier\":\"HOM-12\",\"unblockDescriptor\":{\"owner\":{\"agentId\":\"$AGENT1\"}}}"
  route GET "/api/issues/$ISSUE1/comments" 200 "$2"
  route GET "/api/issues/$ISSUE1/approvals" 200 '[]'
  route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-q"}'
  route PATCH "/api/issues/$ISSUE1" 200 '{}'
  run_afk --json
  NOTICE_DIR="$STATE/paperclip/notices/proj"
}
QRY="[$(jc 1 early 2026-02-15T00:00:00.000Z), $(jc 2 yes 2026-03-02T00:00:00.000Z), $(jc 3 also 2026-03-03T00:00:00.000Z)]"
reply_scenario reply_first "$QRY"
assert_eq "an older comment is not a reply; the first later Josh comment is, bound to q7 seq 4" \
  "$(reply_of)" "q7 4 c0000000-0000-0000-0000-000000000002 2026-03-02T00:00:00.000Z"
assert_eq "  ...every comment is still a plain human comment, still waiting_human, nothing posted" \
  "$(find "$NOTICE_DIR" -name 'reply.*.md' 2>/dev/null | wc -l | tr -d ' ') $(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$STATE/paperclip/ledger.json") $(grep -c '^POST /api/issues' "$LOG")" \
  "3 waiting_human 0"
assert_eq "  ...and the reader counts the question closed" "$(qcheck "$(row1)")" "closed"
write_spool "$ISSUE1" 00000005 "{\"id\":\"$E1\",\"kind\":\"question\",\"question_id\":\"q8\",\"body\":\"next\"}"
route POST "/api/issues/$ISSUE1/comments" 201 '{"createdAt":"2026-03-05T00:00:00.000Z"}'
run_afk --json
assert_eq "a newer question: the old reply stays bound to q7 seq 4, never moved" \
  "$(jq -r --arg id "$ISSUE1" '.issues[$id] | "\(.question_id) \(.question_seq)"' "$STATE/paperclip/ledger.json") $(reply_of)" \
  "q8 5 q7 4 c0000000-0000-0000-0000-000000000002 2026-03-02T00:00:00.000Z"
assert_eq "  ...so the newer question is open" "$(qcheck "$(row1)")" "open"

reply_scenario reply_decision "[$(jc 1 "approve $PD8"), $(jc 2 "  reject $PD8"$'\n' 2026-03-03T00:00:00.000Z), $(jc 3 "approve $PD8 please" 2026-03-04T00:00:00.000Z)]"
assert_eq "a trimmed approve|reject <digest8> on a non-plan question is no reply; the next plain comment is" \
  "$(reply_of)" "q7 4 c0000000-0000-0000-0000-000000000003 2026-03-04T00:00:00.000Z"
assert_eq "  ...each still reaches the PM as a reply file, and none decides anything" \
  "$(find "$NOTICE_DIR" -name 'reply.*.md' 2>/dev/null | wc -l | tr -d ' ') $(find "$STATE/paperclip" -path '*approvals*' -type f | wc -l | tr -d ' ') $(notices approval_rejected) $(notices approval_granted)" \
  "3 0 0 0"
reply_scenario reply_unusable "[$(jc 1 x yesterday), $(jc 2 x 2026-03-02T00:00:00.000Z "\"$AGENT2\"")]"
assert_eq "an unusable createdAt or an agent's comment is no reply" "$(reply_of) $(qcheck "$(row1)")" "none open"
reply_scenario reply_unsent "[$(jc 1 yes)]" '{"question_sent_at":null}'
assert_eq "an unknown question_sent_at records no reply (fail closed)" "$(reply_of)" "none"
reply_scenario reply_fraction "[$(jc 1 yes 2026-03-01T00:00:00Z)]" '{"question_sent_at":"2026-03-01T00:00:00.500Z"}'
assert_eq "instants are compared as times, not strings: 00:00:00Z is before 00:00:00.500Z" "$(reply_of)" "none"
reply_scenario reply_equal "[$(jc 1 yes 2026-03-01T00:00:00.5Z), $(jc 2 yes 2026-03-01T00:00:00.500000000Z)]" '{"question_sent_at":"2026-03-01T00:00:00.500Z"}'
assert_eq "the same instant, however written, is not later" "$(reply_of)" "none"
reply_scenario reply_fraction_later "[$(jc 1 yes 2026-03-01T00:00:00.600Z)]" '{"question_sent_at":"2026-03-01T00:00:00.500Z"}'
assert_eq "a later fraction of the same second is later" "$(reply_of)" "q7 4 c0000000-0000-0000-0000-000000000001 2026-03-01T00:00:00.600Z"
reply_scenario reply_plan_question "[$(jc 1 "looks good")]" "{\"question_id\":\"plan-$PD8\",\"action_text_applied\":\"waiting on plan-$PD8\"}"
assert_eq "a plan question is answered only by its approval: a plain comment is no reply" "$(reply_of)" "none"

# AC-3: a stranded issue with an unanswered question resumed into a full
# project is queued, then promoted to working by the FIFO sweep. The question
# survives the promotion, so the reader still counts it open.
new_scenario resume_queue_promote
three_projects
seed 9 working proj "$(pid_n 1)"
seed 1 stranded proj "$(pid_n 1)" 2026-01-01T00:00:01Z
lset 1 '{resume_state:"waiting_human", question_id:"q-7", question_seq:4, question_sent_at:"2026-03-01T00:00:00.000Z", action_text_applied:"waiting on q-7"}'
inbox 9 1; issue 9 blocked "\"$(pid_n 1)\""; issue 1 todo "\"$(pid_n 1)\""
run_afk --json
assert_eq "resume into a full project: queued, question kept" "$(lget "$(iid 1)") $(lget "$(iid 1)" .question_id)" "queued q-7"
issue 9 'done' "\"$(pid_n 1)\""; issue 1 blocked "\"$(pid_n 1)\""
run_afk --json
assert_eq "FIFO promotion: working, the same question and seq, no reply" \
  "$(lget "$(iid 1)") $(lget "$(iid 1)" .question_id) $(lget "$(iid 1)" .question_seq) $(reply_of "$(iid 1)")" "working q-7 4 none"
assert_eq "  ...so working with that question is still open to the reader" "$(qcheck "$(row1 "$(iid 1)")")" "open"

# AC-6, self-contained: over three passes no legacy final is delivered,
# rewritten or recovered, readiness refuses each pass, and only the reply is
# new. (The one-off baseline-kit comparison is qualification, not this suite.)
new_scenario legacy_finals; three_projects
seed 1 waiting_human proj "$(pid_n 1)"; seed 2 working proj2 "$(pid_n 2)"
lset 1 '{question_id:"q7", question_seq:4, question_sent_at:"2026-03-01T00:00:00.000Z", action_text:"waiting on q7", action_text_applied:"waiting on q7",
  pending_final:"in_review", final_delivery_hold:{status:"in_review", http_status:422}}'
lset 2 '{pending_final:"done"}'
mkdir -p "$STATE/paperclip/spool/$(iid 1)"; printf 'in_review' >"$STATE/paperclip/spool/$(iid 1)/.final"
inbox 1 2; issue 1 blocked "\"$(pid_n 1)\""; issue 2 blocked "\"$(pid_n 2)\""
route GET "/api/issues/$(iid 1)/comments" 200 "[$(jc 1 "any news?" 2026-03-02T00:00:00.000Z)]"
route PATCH "/api/issues/$(iid 2)" 500 '{}'
for _ in 1 2 3; do
  run_afk --json
  env -i PATH="$PATH" HOME="$HOME" LANG=C AFK_STATE_DIR="$STATE" AFK_PAPERCLIP_CONFIG="$CONFIG" \
    bash "$AFK" paperclip-readiness --issue "$(iid 1)" --dir "$REPO1" --json </dev/null 2>/dev/null |
    jq -r '.reasons | index("LEGACY_FINAL_PRESENT") != null' >>"$SCEN/readiness"
done
assert_eq "legacy finals, 3 passes: no final status PATCH, no comment POST" \
  "$(grep -cE '"status": *"(in_review|done)"' "$BODYLOG") $(grep -c '^POST /api/issues/' "$LOG")" "0 0"
assert_eq "  ...readiness reported LEGACY_FINAL_PRESENT on every pass" "$(paste -sd' ' - <"$SCEN/readiness")" "true true true"
assert_eq "  ...the held final, the pending one and the .final bytes are exactly as seeded" \
  "$(jq -c --arg a "$(iid 1)" --arg b "$(iid 2)" '[.issues[$a].pending_final, .issues[$a].final_delivery_hold, .issues[$b].pending_final, .issues[$b].final_delivery_hold]' "$(LEDGER_OF)") $(sha256sum <"$STATE/paperclip/spool/$(iid 1)/.final")" \
  "[\"in_review\",{\"status\":\"in_review\",\"http_status\":422},\"done\",null] $(printf 'in_review' | sha256sum)"
assert_eq "  ...the only new record: the qualifying reply" "$(reply_of "$(iid 1)")" "q7 4 c0000000-0000-0000-0000-000000000001 2026-03-02T00:00:00.000Z"

# ============================================================================
head1 "22. A stored final_intent (storage + guards, AFK-PC-DELIVERY-L1)"
# ============================================================================
# A synthetic fixture only: nothing in shipped code ever writes kind
# "final_intent" to the spool (L3 is the future producer). These digest/tree
# shapes reuse the kit's existing readiness conventions; they are never
# dereferenced here (no git, no network).
FI_PD="$(printf 'd%.0s' {1..64})"
FI_ES="sha256:$(printf 'e%.0s' {1..64})"
FI_TREE="$(printf '1%.0s' {1..40})"
FI_COMMIT="$(printf '2%.0s' {1..40})"
FI_E1="f1111111-1111-1111-1111-111111111111"
FI_E2="f2222222-2222-2222-2222-222222222222"
# final_intent_entry <id> <issue_id> <identifier> -- a raw U3 spool head. The
# envelope's own `.id` (a UUID) IS the identity; U3 defines no separate
# spool `entry_id` field.
final_intent_entry() {
  jq -nc --arg eid "$1" --arg iss "$2" --arg ident "$3" --arg pd "$FI_PD" --arg es "$FI_ES" \
    --arg tree "$FI_TREE" --arg commit "$FI_COMMIT" \
    '{id:$eid, kind:"final_intent", schema:"afk-paperclip-final/2",
      issue:$iss, identifier:$ident, plan_digest:$pd, evidence_set_sha256:$es,
      tree:$tree, commit:$commit, dir:"/tmp/afk-pc-test-dir", common_dir:"/tmp/afk-pc-test-dir/.git",
      status:"in_review", reviewer_user_id:"reviewer-1", body:"ready for review",
      published_at:"2026-10-08T00:00:00Z"}'
}
# fi_payload <entry_id> <issue_id> <identifier> -- the subset L1 persists.
fi_payload() {
  jq -c '{issue, identifier, plan_digest, evidence_set_sha256, tree, commit, dir, common_dir,
           status, reviewer_user_id, body, published_at}' <<<"$(final_intent_entry "$1" "$2" "$3")"
}

new_scenario fi_persist
write_config
seed 1 working proj "$(pid_n 1)"
inbox 1; issue 1 in_progress "\"$(pid_n 1)\""
write_spool "$(iid 1)" 001 "$(final_intent_entry "$FI_E1" "$(iid 1)" PROJ-1)"
run_afk --json
assert_eq "valid intent: spool entry removed" \
  "$(find "$STATE/paperclip/spool/$(iid 1)" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" "0"
assert_eq "valid intent: persisted with entry_id and attempts:0" \
  "$(jq -c --arg id "$(iid 1)" '.issues[$id].final_intent | {entry_id, attempts}' "$(LEDGER_OF)")" \
  "{\"entry_id\":\"$FI_E1\",\"attempts\":0}"
assert_eq "valid intent: the persisted payload matches the U3 fields" \
  "$(jq -cS --arg id "$(iid 1)" '.issues[$id].final_intent.payload' "$(LEDGER_OF)")" \
  "$(jq -cS . <<<"$(fi_payload "$FI_E1" "$(iid 1)" PROJ-1)")"
assert_eq "valid intent: zero HTTP writes (ordering proof is fi_write_fail)" \
  "$(grep -cE '^(POST|PATCH) ' "$LOG")" "0"

new_scenario fi_replay
write_config
seed 2 working proj "$(pid_n 1)"
lset 2 "{\"final_intent\":{\"entry_id\":\"$FI_E1\",\"attempts\":2,\"payload\":$(fi_payload "$FI_E1" "$(iid 2)" PROJ-2)}}"
inbox 2; issue 2 in_progress "\"$(pid_n 1)\""
write_spool "$(iid 2)" 001 "$(final_intent_entry "$FI_E1" "$(iid 2)" PROJ-2)"
run_afk --json
assert_eq "replay after restart: the duplicate spool entry is removed" \
  "$(find "$STATE/paperclip/spool/$(iid 2)" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" "0"
assert_eq "  ...only after proving identity: attempts/progress untouched" \
  "$(jq -r --arg id "$(iid 2)" '.issues[$id].final_intent.attempts' "$(LEDGER_OF)")" "2"
assert_eq "  ...zero HTTP writes" "$(grep -cE '^(POST|PATCH) ' "$LOG")" "0"

new_scenario fi_invalid
write_config
seed 3 working proj "$(pid_n 1)"
inbox 3; issue 3 in_progress "\"$(pid_n 1)\""
write_spool "$(iid 3)" 001 "$(final_intent_entry "$FI_E2" "$(iid 3)" PROJ-3 | jq -c 'del(.plan_digest)')"
run_afk --json
assert_eq "invalid typed entry: moved to dead/ with a visible reason" \
  "$(cat "$STATE/paperclip/spool/$(iid 3)/dead/001.json.reason" 2>/dev/null)" "PAPERCLIP_FINAL_INTENT_INVALID"
assert_eq "  ...never a usable intent" "$(jq -r --arg id "$(iid 3)" '.issues[$id].final_intent // "none"' "$(LEDGER_OF)")" "none"
assert_eq "  ...and no final/send fallback: zero HTTP writes" "$(grep -cE '^(POST|PATCH) ' "$LOG")" "0"

new_scenario fi_conflict
write_config
seed 4 working proj "$(pid_n 1)"
seed 40 working proj "$(pid_n 1)"
lset 4 "{\"final_intent\":{\"entry_id\":\"$FI_E1\",\"attempts\":0,\"payload\":$(fi_payload "$FI_E1" "$(iid 4)" PROJ-4)}}"
lset 40 "{\"final_intent\":{\"entry_id\":\"$FI_E1\",\"attempts\":0,\"payload\":$(fi_payload "$FI_E1" "$(iid 40)" PROJ-40)}}"
inbox 4 40; issue 4 in_progress "\"$(pid_n 1)\""; issue 40 in_progress "\"$(pid_n 1)\""
write_spool "$(iid 4)" 001 "$(final_intent_entry "$FI_E2" "$(iid 4)" PROJ-4)"
write_spool "$(iid 40)" 001 "$(final_intent_entry "$FI_E1" "$(iid 40)" PROJ-40 | jq -c '.body = "changed body"')"
run_afk --json
assert_eq "conflicting input (different id): the raw head is preserved, not removed or dead-lettered" \
  "$(find "$STATE/paperclip/spool/$(iid 4)" -maxdepth 1 -name '001.json' 2>/dev/null | wc -l | tr -d ' ')" "1"
assert_eq "  ...the established ledger intent is kept exactly as it was" \
  "$(jq -r --arg id "$(iid 4)" '.issues[$id].final_intent.entry_id' "$(LEDGER_OF)")" "$FI_E1"
assert_contains "  ...a visible local refusal" "$OUT_TEXT" "final intent conflict"
assert_eq "same id, changed payload: the raw head is preserved too" \
  "$(find "$STATE/paperclip/spool/$(iid 40)" -maxdepth 1 -name '001.json' 2>/dev/null | wc -l | tr -d ' ')" "1"
assert_eq "  ...the established ledger intent (and attempts) is kept exactly as it was" \
  "$(jq -c --arg id "$(iid 40)" '.issues[$id].final_intent | {entry_id, attempts}' "$(LEDGER_OF)")" \
  "{\"entry_id\":\"$FI_E1\",\"attempts\":0}"
assert_eq "  ...zero HTTP writes across both" "$(grep -cE '^(POST|PATCH) ' "$LOG")" "0"

# U5: every out-of-cycle path -- a Paperclip-initiated wake, a board-recovery
# block, a reopened (todo) issue, and a raw-head strand/todo issue -- while a
# final_intent (persisted or raw) already exists. The board-recovery fixture
# (tests:2016-2019) is the one that discriminates the main-loop guard from
# the report-cycle guard: a self-owned plain-blocked issue never writes
# either way, but a missing guard here would post a recovery notice.
new_scenario fi_u5_paths
three_projects
seed 5 working proj "$(pid_n 1)"
seed 6 working proj2 "$(pid_n 2)"
seed 7 working proj3 "$(pid_n 3)"
seed 8 working proj "$(pid_n 1)"
seed 9 working proj "$(pid_n 1)"
lset 5 "{\"final_intent\":{\"entry_id\":\"$FI_E1\",\"attempts\":0,\"payload\":$(fi_payload "$FI_E1" "$(iid 5)" PROJ-5)}}"
lset 6 "{\"final_intent\":{\"entry_id\":\"$FI_E1\",\"attempts\":0,\"payload\":$(fi_payload "$FI_E1" "$(iid 6)" PROJ-6)}}"
lset 7 "{\"final_intent\":{\"entry_id\":\"$FI_E1\",\"attempts\":0,\"payload\":$(fi_payload "$FI_E1" "$(iid 7)" PROJ-7)}}"
inbox 5 6 7 8 9
issue 5 in_progress "\"$(pid_n 1)\""
issue 6 blocked "\"$(pid_n 2)\""
route GET "/api/issues/$(iid 6)" 200 "{\"status\":\"blocked\",\"identifier\":\"PROJ-6\",\"projectId\":\"$(pid_n 2)\",\"unblockDescriptor\":{\"owner\":{\"agentId\":\"$AGENT1\"}},\"activeRecoveryAction\":{\"status\":\"active\",\"ownerType\":\"board\"}}"
route POST "/api/companies/$COMPANY/issues" 201 '{"id":"f0000000-0000-0000-0000-000000000002"}'
issue 7 todo "\"$(pid_n 3)\""
issue 8 in_progress "\"$(pid_n 1)\""
route GET "/api/issues/$(iid 8)/active-run" 200 'null' # no live run: would strand without the guard
issue 9 todo "\"$(pid_n 1)\""
write_spool "$(iid 8)" 001 "$(final_intent_entry "$FI_E1" "$(iid 8)" PROJ-8)"
write_spool "$(iid 9)" 001 "$(final_intent_entry "$FI_E1" "$(iid 9)" PROJ-9)"
run_afk --json
assert_eq "U5: a wake, a board-recovery block, a todo reopen and raw strand/todo heads all do zero writes while an intent exists" \
  "$(grep -cE '^(POST|PATCH) ' "$LOG")" "0"
assert_eq "  ...reads remain allowed (every issue detail was still fetched)" \
  "$(grep -c '^GET /api/issues/' "$LOG")" "5"
assert_eq "  ...no board-recovery notice was posted" \
  "$(grep -c "^POST /api/companies/$COMPANY/issues\$" "$LOG")" "0"
assert_eq "  ...raw strand head: persisted locally, no reblock_due pollution" \
  "$(jq -c --arg id "$(iid 8)" '.issues[$id] | {fi: (.final_intent.entry_id // "none"), rb: (.reblock_due // "none")}' "$(LEDGER_OF)")" \
  "{\"fi\":\"$FI_E1\",\"rb\":\"none\"}"
assert_eq "  ...raw todo head: persisted locally, state unchanged" \
  "$(jq -c --arg id "$(iid 9)" '.issues[$id] | {fi: (.final_intent.entry_id // "none"), st: .state}' "$(LEDGER_OF)")" \
  "{\"fi\":\"$FI_E1\",\"st\":\"working\"}"

# Group B (EDGE-C1-01/BL-10): a failed ledger write must not lose the intent,
# and a later write in the same pass or a later pass must not persist/delete
# it either, until the failure clears.
new_scenario fi_write_fail
write_config
seed 10 working proj "$(pid_n 1)"
inbox 10; issue 10 in_progress "\"$(pid_n 1)\""
write_spool "$(iid 10)" 001 "$(final_intent_entry "$FI_E1" "$(iid 10)" PROJ-10)"
mkdir -p "$STATE/paperclip/ledger.json.afk-tmp"
run_afk --json
assert_eq "write failure: the head file still exists" \
  "$(find "$STATE/paperclip/spool/$(iid 10)" -maxdepth 1 -name '001.json' 2>/dev/null | wc -l | tr -d ' ')" "1"
assert_eq "  ...the ledger has no final_intent for this issue" \
  "$(jq -r --arg id "$(iid 10)" '.issues[$id].final_intent // "none"' "$(LEDGER_OF)")" "none"
assert_contains "  ...a visible storage error" "$OUT_TEXT" "PAPERCLIP_STORAGE_ERROR"
assert_eq "  ...zero HTTP writes" "$(grep -cE '^(POST|PATCH) ' "$LOG")" "0"
rmdir "$STATE/paperclip/ledger.json.afk-tmp"
run_afk --json
assert_eq "after the failure clears: persisted exactly once" \
  "$(jq -c --arg id "$(iid 10)" '.issues[$id].final_intent | {entry_id, attempts}' "$(LEDGER_OF)")" \
  "{\"entry_id\":\"$FI_E1\",\"attempts\":0}"
assert_eq "  ...and the head is removed" \
  "$(find "$STATE/paperclip/spool/$(iid 10)" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" "0"
assert_eq "  ...still zero HTTP writes" "$(grep -cE '^(POST|PATCH) ' "$LOG")" "0"

# Group D (BL-01/EDGE-C1-02): an intent behind an undrained entry is never
# dead-lettered; the drain stops at it and it is recognized at the head.
new_scenario fi_not_head
write_config
seed 11 working proj "$(pid_n 1)"
inbox 11; issue 11 in_progress "\"$(pid_n 1)\""
write_spool "$(iid 11)" 001 "{\"id\":\"$E1\",\"kind\":\"comment\",\"body\":\"ahead\"}"
write_spool "$(iid 11)" 002 "$(final_intent_entry "$FI_E1" "$(iid 11)" PROJ-11)"
run_afk --json
# This fixture is also a legacy Paperclip-initiated wake (an existing working
# row, in_progress, a run that is not the agent's own self-wake): the main
# loop's wake acknowledgment and re-block are legitimate baseline writes
# that happen before the intent is the head. Pass 1's exact ordered non-GET
# trace (corrected gate addendum): wake ack comment, main-loop self-block,
# self-wake, in_progress, the ahead entry's comment -- and nothing after it
# (NEW-C2-01: no trailing PATCH once the intent becomes the head).
assert_eq "not-head intent, pass1: exact ordered write trace" \
  "$(grep -vE '^GET ' "$LOG")" \
  "$(printf 'POST /api/issues/%s/comments\nPATCH /api/issues/%s\nPOST /api/agents/%s/wakeup\nPATCH /api/issues/%s\nPOST /api/issues/%s/comments' \
      "$(iid 11)" "$(iid 11)" "$AGENT1" "$(iid 11)" "$(iid 11)")"
assert_eq "  ...the drained entry's own marker appears exactly once" \
  "$(grep -c "afk-entry:$E1" "$BODYLOG")" "1"
# ADJ-C3-02: the same five writes, by body, in order (one compact JSON per write).
assert_eq "  ...exact ordered bodies: ack, blocked, wake payload, in_progress, entry marker" \
  "$(grep -v '^---$' "$BODYLOG" | jq -r --arg id "$(iid 11)" --arg a "$AGENT1" --arg m "<!-- afk-entry:$E1 -->" \
      '(.body // "") as $b
       | if ($b | startswith("AFK host acknowledged:")) then "ack"
         elif .status == "blocked" and .unblockDescriptor.owner.agentId == $a then "blocked"
         elif . == {source:"timer", payload:{issueId:$id}} then "wake"
         elif . == {status:"in_progress"} then "in_progress"
         elif ($b | startswith("ahead") and contains($m)) then "entry"
         else "other" end' | paste -sd' ' -)" \
  "ack blocked wake in_progress entry"
assert_eq "  ...the intent is never dead-lettered" \
  "$(find "$STATE/paperclip/spool/$(iid 11)/dead" -name '002.json' 2>/dev/null | wc -l | tr -d ' ')" "0"
assert_eq "  ...and stays live, now the head" \
  "$(find "$STATE/paperclip/spool/$(iid 11)" -maxdepth 1 -name '002.json' 2>/dev/null | wc -l | tr -d ' ')" "1"
run_afk --json
assert_eq "next pass: now the head, persisted" \
  "$(jq -r --arg id "$(iid 11)" '.issues[$id].final_intent.entry_id' "$(LEDGER_OF)")" "$FI_E1"
assert_eq "  ...the already-delivered entry marker is never re-sent" \
  "$(grep -c "afk-entry:$E1" "$BODYLOG")" "1"
assert_eq "  ...pass 2 adds zero non-GET writes" \
  "$(grep -vcE '^GET ' "$LOG")" "5"

# Group A (BL-07/BL-08/EDGE-C1-06) and G3: schema, non-UUID id, wrong issue
# and a non-in_review status are each a visible local invalid disposition.
new_scenario fi_invalid_variants
write_config
seed 12 working proj "$(pid_n 1)"
seed 13 working proj "$(pid_n 1)"
seed 14 working proj "$(pid_n 1)"
seed 15 working proj "$(pid_n 1)"
inbox 12 13 14 15
issue 12 in_progress "\"$(pid_n 1)\""
issue 13 in_progress "\"$(pid_n 1)\""
issue 14 in_progress "\"$(pid_n 1)\""
issue 15 in_progress "\"$(pid_n 1)\""
write_spool "$(iid 12)" 001 "$(final_intent_entry "$FI_E1" "$(iid 12)" PROJ-12 | jq -c '.schema = "afk-paperclip-final/1"')"
write_spool "$(iid 13)" 001 "$(final_intent_entry "$FI_E1" "$(iid 13)" PROJ-13 | jq -c '.id = "not-a-uuid"')"
write_spool "$(iid 14)" 001 "$(final_intent_entry "$FI_E1" "$(iid 15)" PROJ-14)"
write_spool "$(iid 15)" 001 "$(final_intent_entry "$FI_E1" "$(iid 15)" PROJ-15 | jq -c '.status = "done"')"
run_afk --json
assert_eq "wrong schema: dead-lettered" \
  "$(cat "$STATE/paperclip/spool/$(iid 12)/dead/001.json.reason" 2>/dev/null)" "PAPERCLIP_FINAL_INTENT_INVALID"
assert_eq "non-UUID id: dead-lettered" \
  "$(cat "$STATE/paperclip/spool/$(iid 13)/dead/001.json.reason" 2>/dev/null)" "PAPERCLIP_FINAL_INTENT_INVALID"
assert_eq "wrong issue field: dead-lettered" \
  "$(cat "$STATE/paperclip/spool/$(iid 14)/dead/001.json.reason" 2>/dev/null)" "PAPERCLIP_FINAL_INTENT_INVALID"
assert_eq "status != in_review: dead-lettered" \
  "$(cat "$STATE/paperclip/spool/$(iid 15)/dead/001.json.reason" 2>/dev/null)" "PAPERCLIP_FINAL_INTENT_INVALID"
assert_eq "  ...none became a usable intent, zero HTTP writes across all four" \
  "$(grep -cE '^(POST|PATCH) ' "$LOG")" "0"

# Group C (BL-02/EDGE-C1-03/O3): a contended raw head is preserved, not lost,
# and is recognized once the lock clears.
new_scenario fi_lock_contended_raw
write_config
seed 16 working proj "$(pid_n 1)"
inbox 16; issue 16 in_progress "\"$(pid_n 1)\""
write_spool "$(iid 16)" 001 "$(final_intent_entry "$FI_E1" "$(iid 16)" PROJ-16)"
mkdir -p "$STATE/paperclip/spool/$(iid 16)/.seq.lock"
run_afk --json
assert_eq "contended raw head: preserved, not removed" \
  "$(find "$STATE/paperclip/spool/$(iid 16)" -maxdepth 1 -name '001.json' 2>/dev/null | wc -l | tr -d ' ')" "1"
assert_eq "  ...no ledger intent recorded yet" \
  "$(jq -r --arg id "$(iid 16)" '.issues[$id].final_intent // "none"' "$(LEDGER_OF)")" "none"
assert_eq "  ...zero HTTP writes" "$(grep -cE '^(POST|PATCH) ' "$LOG")" "0"
rmdir "$STATE/paperclip/spool/$(iid 16)/.seq.lock"
run_afk --json
assert_eq "once the lock clears: persisted" \
  "$(jq -r --arg id "$(iid 16)" '.issues[$id].final_intent.entry_id' "$(LEDGER_OF)")" "$FI_E1"

# EDGE-C1-04: a raw head while paused stays frozen -- nothing deleted, moved
# or persisted; a persisted intent is equally frozen (no attempts drift).
new_scenario fi_pause_raw
write_config
mkdir -p "$HOME/.config/agent-flow-kit/paperclip"; : >"$HOME/.config/agent-flow-kit/paperclip/stop"
seed 17 working proj "$(pid_n 1)"
seed 18 working proj "$(pid_n 1)"
lset 18 "{\"final_intent\":{\"entry_id\":\"$FI_E1\",\"attempts\":0,\"payload\":$(fi_payload "$FI_E1" "$(iid 18)" PROJ-18)}}"
inbox 17 18; issue 17 in_progress "\"$(pid_n 1)\""; issue 18 in_progress "\"$(pid_n 1)\""
write_spool "$(iid 17)" 001 "$(final_intent_entry "$FI_E1" "$(iid 17)" PROJ-17)"
run_afk --json
assert_eq "paused with a raw head: frozen in place" \
  "$(find "$STATE/paperclip/spool/$(iid 17)" -maxdepth 1 -name '001.json' 2>/dev/null | wc -l | tr -d ' ')" "1"
assert_eq "  ...no ledger intent" \
  "$(jq -r --arg id "$(iid 17)" '.issues[$id].final_intent // "none"' "$(LEDGER_OF)")" "none"
assert_eq "  ...paused with a persisted intent: unchanged too" \
  "$(jq -c --arg id "$(iid 18)" '.issues[$id].final_intent | {entry_id, attempts}' "$(LEDGER_OF)")" \
  "{\"entry_id\":\"$FI_E1\",\"attempts\":0}"
assert_eq "  ...zero HTTP writes" "$(grep -cE '^(POST|PATCH) ' "$LOG")" "0"

# ADJ-C3-01: a persisted intent with an ordinary entry still queued. Not
# paused, and the pending entry rules out the cycle's quiet early return, so
# only the report cycle's ledger guard stands before its wakeup.
new_scenario fi_persisted_report
write_config
seed 19 working proj "$(pid_n 1)"
lset 19 "{\"final_intent\":{\"entry_id\":\"$FI_E1\",\"attempts\":1,\"payload\":$(fi_payload "$FI_E1" "$(iid 19)" PROJ-19)}}"
inbox 19; issue 19 in_progress "\"$(pid_n 1)\""
write_spool "$(iid 19)" 001 "{\"id\":\"$E1\",\"kind\":\"comment\",\"body\":\"queued\"}"
fi_before="$(jq -cS --arg id "$(iid 19)" '.issues[$id].final_intent' "$(LEDGER_OF)")"
run_afk --json
assert_eq "persisted intent + queued comment: zero POST/PATCH" "$(grep -cE '^(POST|PATCH) ' "$LOG")" "0"
assert_eq "  ...an empty body log" "$(cat "$BODYLOG")" ""
assert_eq "  ...the queued comment stays in the spool" \
  "$(find "$STATE/paperclip/spool/$(iid 19)" -maxdepth 1 -name '001.json' 2>/dev/null | wc -l | tr -d ' ')" "1"
assert_eq "  ...the ledger intent is unchanged (canonical)" \
  "$(jq -cS --arg id "$(iid 19)" '.issues[$id].final_intent' "$(LEDGER_OF)")" "$fi_before"

# GAPS-C3-01: a leftover `sending` whose marker read-back confirms the ordinary
# head removes that head, so the cycle's locked snapshot now sees the intent.
# The main loop's wake ack/self-block before it are legitimate (fi_not_head).
new_scenario fi_readback_arrival
write_config
seed 20 working proj "$(pid_n 1)"
lset 20 "{\"sending\":{\"entry_id\":\"$E1\",\"issue_id\":\"$(iid 20)\",\"at\":\"2026-01-01T00:00:00Z\"}}"
inbox 20; issue 20 in_progress "\"$(pid_n 1)\""
route GET "/api/issues/$(iid 20)/comments" 200 "[{\"authorAgentId\":\"$AGENT1\",\"body\":\"sent\\n\\n<!-- afk-entry:$E1 -->\"}]"
write_spool "$(iid 20)" 001 "{\"id\":\"$E1\",\"kind\":\"comment\",\"body\":\"sent\"}"
write_spool "$(iid 20)" 002 "$(final_intent_entry "$FI_E1" "$(iid 20)" PROJ-20)"
run_afk --json
assert_eq "confirmed read-back: the ordinary head is removed and sending cleared" \
  "$(find "$STATE/paperclip/spool/$(iid 20)" -maxdepth 1 -name '001.json' 2>/dev/null | wc -l | tr -d ' ') $(jq -r --arg id "$(iid 20)" '.issues[$id].sending // "none"' "$(LEDGER_OF)")" \
  "0 none"
assert_eq "  ...the intent, now the head, is held in place" \
  "$(find "$STATE/paperclip/spool/$(iid 20)" -maxdepth 1 -name '002.json' 2>/dev/null | wc -l | tr -d ' ')" "1"
assert_eq "  ...no agent wakeup after the transition" "$(grep -c "^POST /api/agents/$AGENT1/wakeup$" "$LOG")" "0"
assert_eq "  ...no in_progress body, and the confirmed entry is never re-posted" \
  "$(grep -c '"status":"in_progress"' "$BODYLOG") $(grep -c "afk-entry:$E1" "$BODYLOG")" "0 0"

# ===========================================================================
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
