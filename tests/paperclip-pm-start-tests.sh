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
post_body=""
for ((i = 0; i < n; i++)); do [[ "${args[$i]}" == -X ]] && method="${args[$((i + 1))]}"; done
url="${args[$((n - 1))]}"
tmp="${url#*://}"; path="/${tmp#*/}"
printf '%s %s\n' "$method" "$path" >>"$CURL_STUB_LOG"
for ((i = 0; i < n; i++)); do
  if [[ "${args[$i]}" == --data-binary && "${args[$((i + 1))]}" == @/dev/fd/* ]]; then
    post_body="$(cat "${args[$((i + 1))]#@}")"
    printf '%s\n---\n' "$post_body" >>"$CURL_STUB_BODYLOG"
  fi
done
if [[ -n "${CURL_STUB_COMMENTS_FILE:-}" && "$path" == */comments ]]; then
  if [[ "$method" == POST ]]; then
    body="$(jq -r '.body // empty' <<<"$post_body")"
    jq -c --arg b "$body" --arg a "$CURL_STUB_AGENT" '. + [{authorAgentId:$a, body:$b}]' \
      "$CURL_STUB_COMMENTS_FILE" >"$CURL_STUB_COMMENTS_FILE.tmp"
    mv "$CURL_STUB_COMMENTS_FILE.tmp" "$CURL_STUB_COMMENTS_FILE"
    if [[ "${KILL_POINT:-}" == claim ]]; then
      : >"$KILL_MARKER"; while [[ -e "$KILL_MARKER" ]]; do sleep 0.05; done
    fi
  elif [[ "$method" == GET ]]; then
    comment_key="${method}_${path#/}"; comment_key="${comment_key//\//_}"
    comment_fixture="$CURL_STUB_FIXTURES/$comment_key"
    if [[ -f "$comment_fixture" && "$(head -1 "$comment_fixture")" == 200 ]]; then
      jq -cs '.[0] + .[1]' <(tail -n +2 "$comment_fixture") "$CURL_STUB_COMMENTS_FILE"
    else
      cat "$CURL_STUB_COMMENTS_FILE"
    fi
    printf 200; exit 0
  fi
fi
key="${method}_${path#/}"; key="${key//\//_}"
f="$CURL_STUB_FIXTURES/$key"
[[ -f "$f" ]] || f="$CURL_STUB_FIXTURES/DEFAULT"
if [[ ! -f "$f" ]]; then printf '000'; exit 0; fi
code="$(head -1 "$f")"
# A /me with no runtimeConfig key reports a lease-mode heartbeat (AD-26).
if [[ "$method" == GET && "$path" == /api/agents/me ]] && ! grep -q '"runtimeConfig"' "$f"; then
  tail -n +2 "$f" | jq -c '. + {runtimeConfig: {heartbeat: {enabled: true, intervalSec: 0, wakeOnDemand: true}}}'
else
  tail -n +2 "$f"
fi
printf '%s' "$code"
SH

# orca — worktree show, terminal list (bare and --worktree), terminal create.
# No launch, no real terminal: every response is a fixture this test controls.
cat >"$STUBS/orca-cli" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == --version ]] && { echo 1.4.216; exit 0; }
case "$1 $2" in
  "worktree show") cat "$ORCA_WT_FILE" ;;
  "terminal list")
    if [[ "${3:-}" == --worktree ]]; then cat "$ORCA_TERMLIST_WT_FILE"
    else jq -c '. + {_meta:{runtimeId:"rt-1"}}' "$ORCA_TERMLIST_FILE"; fi ;;
  # Every listed terminal runs claude on pane tab-<handle>:leaf-<handle>.
  "worktree ps")
    jq -c '{result:{worktrees:[{id:"wt-1",agents:[.result.terminals[] | {paneKey:(if .handle=="term-created-1" then "tab-c:leaf-c" else "tab-"+.handle+":leaf-"+.handle end),
      state:"working",agentType:"claude"}]}]},_meta:{runtimeId:"rt-1"}}' "$ORCA_TERMLIST_FILE" ;;
  "terminal show")
    [[ "${4:-}" == term-created-1 ]] || exit 1
    printf '{"result":{"terminal":{"handle":"term-created-1","tabId":"tab-c","leafId":"leaf-c","worktreeId":"wt-1"}},"_meta":{"runtimeId":"rt-1"}}' ;;
  "terminal create")
    printf '%s\n' "$*" >>"$ORCA_CREATE_LOG"
    if [[ -n "${BOOTSTRAP_MARKER:-}" ]]; then
      for ((i = 1; i < $#; i++)); do
        if [[ "${!i}" == --command ]]; then
          j=$((i + 1)); bootstrap_command="${!j}"
          bootstrap_wt_path="$(jq -r '.result.worktree.path' "$ORCA_WT_FILE")"
          (cd "$bootstrap_wt_path" && eval "$bootstrap_command")
          break
        fi
      done
    fi
    printf '{"result":{"terminal":{"handle":"term-created-1"}}}'
    if [[ "${KILL_POINT:-}" == create ]]; then
      printf '{"result":{"terminals":[{"handle":"term-created-1","title":"renamed by statusline","connected":true,"orphaned":false}]}}' >"$ORCA_TERMLIST_FILE"
      : >"$KILL_MARKER"; while [[ -e "$KILL_MARKER" ]]; do sleep 0.05; done
    fi ;;
  *) exit 1 ;;
esac
SH
cat >"$STUBS/tr" <<'SH'
#!/usr/bin/env bash
if [[ "${KILL_POINT:-}" == notice ]] &&
   find "$KILL_NOTICE_PATH" -maxdepth 1 -name '*.claimed.json' -print -quit 2>/dev/null | grep -q . &&
   ! find "$KILL_NOTICE_PATH" -maxdepth 1 -name 'brief.*.md' -print -quit 2>/dev/null | grep -q .; then
  : >"$KILL_MARKER"; while [[ -e "$KILL_MARKER" ]]; do sleep 0.05; done
fi
exec /usr/bin/tr "$@"
SH
# The stub reaches the kit only through the resolver's host config.
printf '{"orca_bin":"%s"}\n' "$STUBS/orca-cli" >"$STUBS/host.json"
# A decoy named orca on PATH. Kit code must never run it (AD-28 R10);
# the real stub is orca-cli and reaches the kit only through the resolver.
printf '#!/bin/sh\n: >"%s"\nexit 1\n' "$STUBS/.bare-orca-ran" >"$STUBS/orca"; chmod +x "$STUBS/orca"

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
[[ -n "${READINESS_CALL_LOG:-}" ]] && printf 'called\n' >>"$READINESS_CALL_LOG"
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
ISSUE2="e2222222-2222-2222-2222-222222222222"
PROJ1="aaaaaaaa-0000-4000-8000-000000000001"

# new_scenario <name> — fresh HOME, fixtures, git repo and Orca fixtures.
new_scenario() {
  SCEN="$TMPROOT/$1"; mkdir -p "$SCEN"
  COMMENTS_FILE="$SCEN/comments.json"; printf '[]\n' >"$COMMENTS_FILE"
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
  local out err; local -a adapter_env=()
  [[ ${AFK_PM_BOOTSTRAP_BIN+x} ]] && adapter_env+=("AFK_PM_BOOTSTRAP_BIN=$AFK_PM_BOOTSTRAP_BIN")
  [[ ${AFK_SKILLS_HOME+x} ]] && adapter_env+=("AFK_SKILLS_HOME=$AFK_SKILLS_HOME")
  [[ ${BOOTSTRAP_MARKER+x} ]] && adapter_env+=("BOOTSTRAP_MARKER=$BOOTSTRAP_MARKER")
  [[ ${AFK_CLAUDE_BIN+x} ]] && adapter_env+=("AFK_CLAUDE_BIN=$AFK_CLAUDE_BIN")
  [[ ${HARNESS_ARGV_LOG+x} ]] && adapter_env+=("HARNESS_ARGV_LOG=$HARNESS_ARGV_LOG")
  [[ ${READINESS_CALL_LOG+x} ]] && adapter_env+=("READINESS_CALL_LOG=$READINESS_CALL_LOG")
  [[ ${ORCA_TERMINAL_HANDLE+x} ]] && adapter_env+=("ORCA_TERMINAL_HANDLE=$ORCA_TERMINAL_HANDLE")
  out="$(env -i PATH="$STUBS:$PATH" HOME="${HOME:-$SCEN/home}" LANG=C \
    AFK_KIT_ROOT="${AFK_KIT_ROOT:-$KIT_ROOT}" \
    AFK_STATE_DIR="$STATE" AFK_PAPERCLIP_CONFIG="$CONFIG" \
    AFK_OP_BIN="$STUBS/op" AFK_CURL_BIN="$STUBS/curl" AFK_HOST_CONFIG="$STUBS/host.json" OP_SERVICE_ACCOUNT_TOKEN=test-op-token \
    AFK_PCS_READINESS_BIN="$STUBS/readiness" READINESS_OK="${READINESS_OK:-true}" READINESS_REASON="${READINESS_REASON:-}" \
    CURL_STUB_LOG="$LOG" CURL_STUB_BODYLOG="$BODYLOG" CURL_STUB_FIXTURES="$FIXDIR" \
    CURL_STUB_COMMENTS_FILE="${COMMENTS_FILE:-}" CURL_STUB_AGENT="$AGENT1" \
    ORCA_WT_FILE="$ORCA_WT_FILE" ORCA_TERMLIST_FILE="$ORCA_TERMLIST_FILE" ORCA_TERMLIST_WT_FILE="$ORCA_TERMLIST_WT_FILE" \
    ORCA_CREATE_LOG="$ORCA_CREATE_LOG" SYSTEMCTL_LOG="$SYSTEMCTL_LOG" ${SYSTEMCTL_SHOWENV:+SYSTEMCTL_SHOWENV="$SYSTEMCTL_SHOWENV"} \
    SYSTEMCTL_ENABLED="${SYSTEMCTL_ENABLED:-enabled}" SYSTEMCTL_ACTIVE="${SYSTEMCTL_ACTIVE:-active}" \
    AFK_PCT_SYSTEMD_DIR="$SCEN/systemd-user" "${adapter_env[@]}" \
    bash "${AFK_BIN_OVERRIDE:-$AFK}" "$@" 2>"$SCEN/err")"
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

kill_pass_at() { # claim | notice | create; only kills the pass PID started here
  local point="$1" pass_pid seen=false i
  KILL_MARKER="$SCEN/kill-ready"
  KILL_NOTICE_PATH="$STATE/paperclip/notices/proj"
  KILL_BRIEF_PATH="$KILL_NOTICE_PATH"
  env -i PATH="$STUBS:$PATH" HOME="$HOME" LANG=C \
    AFK_STATE_DIR="$STATE" AFK_PAPERCLIP_CONFIG="$CONFIG" AFK_HOST_CONFIG="$STUBS/host.json" \
    AFK_OP_BIN="$STUBS/op" AFK_CURL_BIN="$STUBS/curl" OP_SERVICE_ACCOUNT_TOKEN=test-op-token \
    AFK_PCS_READINESS_BIN="$STUBS/readiness" READINESS_OK=true \
    CURL_STUB_LOG="$LOG" CURL_STUB_BODYLOG="$BODYLOG" CURL_STUB_FIXTURES="$FIXDIR" \
    CURL_STUB_COMMENTS_FILE="$COMMENTS_FILE" CURL_STUB_AGENT="$AGENT1" \
    ORCA_WT_FILE="$ORCA_WT_FILE" ORCA_TERMLIST_FILE="$ORCA_TERMLIST_FILE" \
    ORCA_TERMLIST_WT_FILE="$ORCA_TERMLIST_WT_FILE" ORCA_CREATE_LOG="$ORCA_CREATE_LOG" \
    KILL_POINT="$point" KILL_MARKER="$KILL_MARKER" KILL_NOTICE_PATH="$KILL_NOTICE_PATH" \
    KILL_BRIEF_PATH="$KILL_BRIEF_PATH" bash "$AFK" paperclip-poll --json \
    >"$SCEN/killed.out" 2>&1 &
  pass_pid=$!
  for ((i=0; i<200; i++)); do
    if [[ -e "$KILL_MARKER" ]]; then seen=true; break; fi
    kill -0 "$pass_pid" 2>/dev/null || break
    sleep 0.05
  done
  assert_eq "$point: reached the kill point" "$seen" true
  if [[ "$seen" == true ]]; then kill -9 "$pass_pid" 2>/dev/null; fi
  wait "$pass_pid" 2>/dev/null || true
  rm -f "$KILL_MARKER"
  # A SIGKILL leaves the poll lock. Age only this test's dead pass lock so
  # the next pass can use the normal stale-lock recovery path.
  [[ -d "$STATE/paperclip/.lock" ]] && touch -d '-1000 seconds' "$STATE/paperclip/.lock"
}

# Bootstrap adapter resolution: installed flat layout, missing adapters, and
# explicit override precedence. Orca executes the command only while marked.
head1 "0. bootstrap adapter resolution"
new_scenario installed_bootstrap
write_config '{"pm_start_enabled":true}'
issue_route in_progress "$BOARD"
AFK_SKILLS_HOME="$SCEN/skills"; INSTALLED_RUNTIME="$AFK_SKILLS_HOME/afk-runtime"
mkdir -p "$INSTALLED_RUNTIME"
cp -R "$KIT_ROOT/bin" "$KIT_ROOT/lib" "$INSTALLED_RUNTIME/"
cp "$KIT_ROOT/adapters/runtime-scope.sh" "$INSTALLED_RUNTIME/runtime-scope.sh"
install -m 755 "$KIT_ROOT/adapters/orca-pm-bootstrap.sh" "$INSTALLED_RUNTIME/orca-pm-bootstrap.sh"
AFK_KIT_ROOT="$INSTALLED_RUNTIME"
AFK_BIN_OVERRIDE="$INSTALLED_RUNTIME/bin/agent-flow-kit"
BOOTSTRAP_MARKER=installed-layout
ORCA_TERMINAL_HANDLE=term-created-1
AFK_CLAUDE_BIN="$STUBS/harness"; HARNESS_ARGV_LOG="$SCEN/installed-harness.argv"
[[ ! -d "$INSTALLED_RUNTIME/adapters" ]] && ok "installed runtime has no adapters directory" || bad "installed runtime has no adapters directory"
# Independently source the copied registry library: the flat sibling helper
# must satisfy its scope-key primitive without a source-tree adapters path.
installed_key="$(env -i PATH="$STUBS:$PATH" AFK_INSTALL_ROOT="$INSTALLED_RUNTIME" bash -c \
  '. "$AFK_INSTALL_ROOT/lib/afk-pm-registry.sh" && afk_pmr_claim_key_for_terminal installed-check')"
expected_key="terminal-$(printf 'terminal\0%s' installed-check | sha256sum | awk '{print $1}')"
assert_eq "installed registry sources sibling runtime-scope.sh" "$installed_key" "$expected_key"
unset AFK_PM_BOOTSTRAP_BIN
do_pass
assert_contains "installed entrypoint runs the real flat bootstrap" "$(cat "$HARNESS_ARGV_LOG" 2>/dev/null)" "paperclip-take --slug proj"
assert_absent "installed flat adapter avoids unavailable hold" "$OUT_TEXT" PM_BOOTSTRAP_UNAVAILABLE
INTENT_FILE="$STATE/paperclip/pm-start-intents/proj.$ISSUE1.json"
# Invoke the same real installed adapter directly with the generated intent to
# prove its sibling lib/ lookup and the intent's bootstrap path independently.
(cd "$REPO" && env -i PATH="$STUBS:$PATH" HOME="$SCEN/home" LANG=C \
  ORCA_TERMINAL_HANDLE=term-created-1 AFK_HOST_CONFIG="$STUBS/host.json" \
  ORCA_WT_FILE="$ORCA_WT_FILE" AFK_CLAUDE_BIN="$STUBS/harness" \
  HARNESS_ARGV_LOG="$SCEN/direct-installed-harness.argv" \
  bash "$INSTALLED_RUNTIME/orca-pm-bootstrap.sh" --intent "$INTENT_FILE" >/dev/null 2>&1)
assert_contains "real flat bootstrap loads sibling lib/ and accepts generated intent" \
  "$(cat "$SCEN/direct-installed-harness.argv" 2>/dev/null)" "paperclip-take --slug proj"
unset AFK_BIN_OVERRIDE AFK_PM_BOOTSTRAP_BIN AFK_SKILLS_HOME AFK_KIT_ROOT BOOTSTRAP_MARKER
unset AFK_CLAUDE_BIN HARNESS_ARGV_LOG ORCA_TERMINAL_HANDLE

new_scenario missing_bootstrap
write_config '{"pm_start_enabled":true}'
issue_route in_progress "$BOARD"
AFK_SKILLS_HOME="$SCEN/no-skills"; mkdir -p "$AFK_SKILLS_HOME/afk-runtime"
AFK_KIT_ROOT="$SCEN/no-kit-adapters"; mkdir -p "$AFK_KIT_ROOT"
unset AFK_PM_BOOTSTRAP_BIN BOOTSTRAP_MARKER
do_pass
assert_contains "neither bootstrap path executable reports unavailable" \
  "$(jq -r --arg id "$ISSUE1" '.issues[$id].action_text // empty' "$STATE/paperclip/ledger.json")" PM_BOOTSTRAP_UNAVAILABLE
assert_eq "missing bootstrap does not create a terminal" "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" 0
# A held start on a working issue must keep its reason stable across reports;
# otherwise each inbox sweep restores queued text and the report cycle wakes
# the agent again on every timer pass.
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"blocked\",\"identifier\":\"PROJ-1\",\"title\":\"T\",\"description\":\"D\",\"updatedAt\":\"2026-01-01T00:00:00Z\",\"createdByUserId\":\"$BOARD\",\"projectId\":\"$PROJ1\",\"assigneeAgentId\":\"$AGENT1\",\"unblockDescriptor\":{\"owner\":{\"agentId\":\"$AGENT1\"}}}"
route GET "/api/issues/$ISSUE1/active-run" 200 '{"id":"run-1"}'
route GET "/api/issues/$ISSUE1/comments" 200 '[]'
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-report"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
: >"$LOG"
for pass in 1 2 3; do run_afk paperclip-poll --json; done
assert_eq "held bootstrap reason survives the report cycle" \
  "$(jq -r --arg id "$ISSUE1" '.issues[$id].action_text_applied' "$STATE/paperclip/ledger.json")" \
  "queued: no PM (start held: PM_BOOTSTRAP_UNAVAILABLE)"
assert_eq "held bootstrap with no new work produces no report wake" \
  "$(grep -c "^POST /api/agents/$AGENT1/wakeup$" "$LOG")" 0
AFK_PM_BOOTSTRAP_BIN="$SCEN/recovered-bootstrap"
printf '#!/bin/sh\nexit 0\n' >"$AFK_PM_BOOTSTRAP_BIN"; chmod +x "$AFK_PM_BOOTSTRAP_BIN"
mkdir -p "$STATE/paperclip/spool/$ISSUE1"
printf '%s' '{"id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","kind":"comment","body":"held-start regression"}' \
  >"$STATE/paperclip/spool/$ISSUE1/00000001.json"
: >"$LOG"
run_afk paperclip-poll --json
assert_eq "a held start retries when bootstrap becomes available" \
  "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" 1
# If the self-wake's run appears on the next inbox sweep, it must not be
# mistaken for a Paperclip-originated wake and acknowledged as such.
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"in_progress\",\"identifier\":\"PROJ-1\",\"title\":\"T\",\"description\":\"D\",\"updatedAt\":\"2026-01-01T00:00:00Z\",\"createdByUserId\":\"$BOARD\",\"projectId\":\"$PROJ1\",\"unblockDescriptor\":{\"owner\":{\"agentId\":\"$AGENT1\"}}}"
route GET "/api/issues/$ISSUE1/active-run" 200 '{"id":"run-report","contextSnapshot":{"wakeReason":"timer"}}'
route GET "/api/issues/$ISSUE1/comments" 200 '[]'
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
: >"$LOG"; : >"$BODYLOG"
run_afk paperclip-poll --json
assert_absent "our own report run is not acknowledged as a Paperclip wake" \
  "$(cat "$BODYLOG")" "AFK host acknowledged:"
unset AFK_PM_BOOTSTRAP_BIN

new_scenario override_bootstrap
write_config '{"pm_start_enabled":true}'
issue_route in_progress "$BOARD"
AFK_KIT_ROOT="$KIT_ROOT"; AFK_SKILLS_HOME="$SCEN/skills"; mkdir -p "$AFK_SKILLS_HOME/afk-runtime"
BOOTSTRAP_MARKER="$SCEN/override-called"; AFK_PM_BOOTSTRAP_BIN="$SCEN/override.sh"
printf '#!/bin/sh\nprintf override >"%s"\n' "$BOOTSTRAP_MARKER" >"$AFK_PM_BOOTSTRAP_BIN"
chmod +x "$AFK_PM_BOOTSTRAP_BIN"
mkdir -p "$AFK_SKILLS_HOME/afk-runtime"
printf '#!/bin/sh\nprintf installed >"%s"\n' "$SCEN/installed-decoy-called" >"$AFK_SKILLS_HOME/afk-runtime/orca-pm-bootstrap.sh"
chmod +x "$SCEN/skills/afk-runtime/orca-pm-bootstrap.sh"
do_pass
assert_eq "explicit bootstrap override wins" "$(cat "$BOOTSTRAP_MARKER" 2>/dev/null)" override
assert_absent "installed adapter loses to explicit override" "$(cat "$SCEN/installed-decoy-called" 2>/dev/null)" installed
unset AFK_PM_BOOTSTRAP_BIN AFK_SKILLS_HOME AFK_KIT_ROOT BOOTSTRAP_MARKER

# ============================================================================
head1 "1. none + Josh-created -> exactly one terminal create"
# ============================================================================
new_scenario none_josh
write_config '{"pm_start_enabled":true}'
issue_route in_progress "$BOARD"
do_pass
assert_eq "none+Josh: pass exit 0" "$RC" "0"
assert_eq "none+Josh: exactly one terminal create" "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" "1"
INTENT_FILE="$STATE/paperclip/pm-start-intents/proj.$ISSUE1.json"
assert_contains "none+Josh: fixed instruction text present" "$(cat "$INTENT_FILE")" "You are the BMAD PM for project proj"
assert_contains "none+Josh: the started PM is told to take by --slug" "$(cat "$INTENT_FILE")" "paperclip-take --slug proj"
assert_contains "none+Josh: the terminal title names the slug" "$(cat "$ORCA_CREATE_LOG")" "PM proj (paperclip)"
assert_absent "none+Josh: no issue title in the create argv" "$(cat "$ORCA_CREATE_LOG")" "T\""
assert_absent "none+Josh: no issue description in the create argv" "$(cat "$ORCA_CREATE_LOG")" "\"D\""
INTENT_FILE="$STATE/paperclip/pm-start-intents/proj.$ISSUE1.json"
assert_absent "none+Josh: no issue title in the bootstrap intent" "$(cat "$INTENT_FILE" 2>/dev/null)" "\"T\""
assert_absent "none+Josh: no issue description in the bootstrap intent" "$(cat "$INTENT_FILE" 2>/dev/null)" "\"D\""
LEDGER="$STATE/paperclip/ledger.json"
assert_eq "none+Josh: ledger records the terminal" "$(jq -r --arg id "$ISSUE1" '.pm_started[$id].terminal' "$LEDGER")" "term-created-1"
assert_eq "none+Josh: the ledger row records the identity tuple" \
  "$(jq -r --arg id "$ISSUE1" '.pm_started[$id].identity | "\(.runtime_id) \(.tab_id):\(.leaf_id) \(.agent_type)"' "$LEDGER")" \
  "rt-1 tab-c:leaf-c claude"
# The real adapter validates the intent the lib wrote (the fixed text is
# rebuilt and byte-compared there), so the two copies can never drift.
run_adapter() { # <intent-file>
  (cd "$REPO_ABS" && env -i PATH="$STUBS:$PATH" HOME="$SCEN/home" LANG=C ORCA_TERMINAL_HANDLE=term-created-1 \
    AFK_HOST_CONFIG="$STUBS/host.json" ORCA_WT_FILE="$ORCA_WT_FILE" AFK_CLAUDE_BIN="$STUBS/harness" HARNESS_ARGV_LOG="$SCEN/harness.argv" \
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
  '{schema:"afk-pm-ownership/3", owned:true, terminal:$t, session:$s, harness:"claude", worktree:{path:$wp},
    identity:{handle:$t, runtime_id:"rt-1", tab_id:("tab-"+$t), leaf_id:("leaf-"+$t), agent_type:"claude"}}' \
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
  '{schema:"afk-pm-ownership/3", owned:true, terminal:$t, session:$s, harness:"claude", worktree:{path:$wp},
    identity:{handle:$t, runtime_id:"rt-1", tab_id:("tab-"+$t), leaf_id:("leaf-"+$t), agent_type:"claude"}}' \
  >"$STATE/pm/scopes/$SK1/ownership.json"
jq -nc --arg t term-amb-2 --arg s s2 --arg wp "$REPO_ABS" \
  '{schema:"afk-pm-ownership/3", owned:true, terminal:$t, session:$s, harness:"claude", worktree:{path:$wp},
    identity:{handle:$t, runtime_id:"rt-1", tab_id:("tab-"+$t), leaf_id:("leaf-"+$t), agent_type:"claude"}}' \
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
head1 "3b. unknown -> no create, and the queued text names the reason"
# ============================================================================
new_scenario unknown_state
write_config '{"pm_start_enabled":true}'
SKU="$(scope_key term-old-rt)"
mkdir -p "$STATE/pm/scopes/$SKU"
# Recorded under runtime rt-0; Orca now reports rt-1 (an Orca update).
jq -nc --arg t term-old-rt --arg wp "$REPO_ABS" \
  '{schema:"afk-pm-ownership/3", owned:true, terminal:$t, session:"s", harness:"claude", worktree:{path:$wp},
    identity:{handle:$t, runtime_id:"rt-0", tab_id:"tab-x", leaf_id:"leaf-x", agent_type:"claude"}}' \
  >"$STATE/pm/scopes/$SKU/ownership.json"
issue_route in_progress "$BOARD"
do_pass
assert_eq "unknown: no terminal create" "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" "0"
assert_eq "unknown: the queued text names the lookup's reason" \
  "$(jq -r --arg id "$ISSUE1" '.issues[$id].action_text' "$STATE/paperclip/ledger.json")" "queued: PM state unknown (PM_RUNTIME_MISMATCH)"
assert_eq "unknown: the owner is kept" "$([[ -f "$STATE/pm/scopes/$SKU/ownership.json" ]] && echo kept)" "kept"

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
  for b in bash jq stat id env timeout uname; do ln -s "$(command -v "$b")" "$MGRBIN/$b"; done
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
assert_contains "the service pins the resolved absolute Orca path" "$(cat "$SCEN/systemd-user/afk-paperclip-poll.service")" "AFK_ORCA_BIN=$STUBS/orca-cli"
printf '{"orca_bin":"/bin/false"}\n' >"$STUBS/host.json"
run_afk paperclip-timer --install --json
assert_contains "install refuses a failed Orca handshake" "$OUT_TEXT" "ORCA_CLI_NOT_RESOLVED"
run_afk paperclip-timer --status --json
assert_contains "status reports a failed Orca handshake" "$OUT_TEXT" "ORCA_CLI_NOT_RESOLVED"
run_afk paperclip-project list --json
assert_contains "project list reports a failed Orca handshake" "$OUT_TEXT" "ORCA_CLI_NOT_RESOLVED"
printf '{"orca_bin":"%s"}\n' "$STUBS/orca-cli" >"$STUBS/host.json"

# The caller can run this Orca stub because its PATH has the helper. The
# manager's PATH below omits it, so only the child-side handshake catches it.
cat >"$STUBS/orca-needs-helper" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == --version ]] || exit 1
command -v orca-version-helper >/dev/null 2>&1 || exit 1
printf '1.4.216\n'
SH
printf '#!/usr/bin/env bash\nexit 0\n' >"$STUBS/orca-version-helper"
chmod +x "$STUBS/orca-needs-helper" "$STUBS/orca-version-helper"
mgr_scenario mgr_orca_path
envfile600 "$HOME/.op-agent-env"
printf 'PATH=%s\nAFK_OP_BIN=%s\n' "$MGRBIN" "$STUBS/op" >"$SYSTEMCTL_SHOWENV"
printf '{"orca_bin":"%s"}\n' "$STUBS/orca-needs-helper" >"$STUBS/host.json"
run_afk paperclip-timer --install --json
assert_contains "M5 manager PATH cannot run Orca: install refuses" "$OUT_TEXT" ORCA_CLI_NOT_RESOLVED
run_afk paperclip-timer --status --json
assert_contains "M5 manager PATH cannot run Orca: status reports reason" "$OUT_TEXT" ORCA_CLI_NOT_RESOLVED
run_afk paperclip-project list --json
assert_contains "M5 manager PATH cannot run Orca: list reports reason" "$OUT_TEXT" ORCA_CLI_NOT_RESOLVED
printf '{"orca_bin":"%s"}\n' "$STUBS/orca-cli" >"$STUBS/host.json"

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

head1 "12. Killed passes resume without duplicate claims, notices or terminals"
for point in claim notice create; do
  new_scenario "kill_$point"
  write_config '{"pm_start_enabled":true}'
  COMMENTS_FILE="$SCEN/comments.json"; printf '[]\n' >"$COMMENTS_FILE"
  route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
  route GET /api/agents/me/inbox-lite 200 "[{\"id\":\"$ISSUE1\"}]"
  route GET "/api/issues/$ISSUE1/active-run" 200 '{"id":"run-1"}'
  route POST "/api/issues/$ISSUE1/comments" 201 '{}'
  route PATCH "/api/issues/$ISSUE1" 200 '{}'
  issue_route in_progress "$BOARD"
  kill_pass_at "$point"
  case "$point" in
    claim)
      assert_eq "claim kill: intent was durable before POST" \
        "$(jq -r --arg id "$ISSUE1" '.issues[$id].claim' "$STATE/paperclip/ledger.json")" intent ;;
    notice)
      assert_eq "notice kill: the claimed notice was journaled" \
        "$(jq -r --arg id "$ISSUE1" '.issues[$id].claimed_notice' "$STATE/paperclip/ledger.json")" written ;;
    create)
      assert_eq "create kill: pm_started intent preceded terminal create" \
        "$(jq -r --arg id "$ISSUE1" '.pm_started[$id].state' "$STATE/paperclip/ledger.json")" intent
      assert_eq "create kill: the intent file path was journaled" \
        "$(jq -r --arg id "$ISSUE1" '.pm_started[$id].intent_file' "$STATE/paperclip/ledger.json")" \
        "$STATE/paperclip/pm-start-intents/proj.$ISSUE1.json" ;;
  esac
  run_afk paperclip-poll --json
  assert_eq "$point replay: pass completes" "$RC" 0
  assert_eq "$point replay: one claim comment" \
    "$(jq '[.[] | select(.body | contains("claimed by AFK PM"))] | length' "$COMMENTS_FILE")" 1
  assert_eq "$point replay: marker survives comment read-back" \
    "$(jq --arg id "$ISSUE1" '[.[] | select(.body | contains("<!-- afk-claim:" + $id + " -->"))] | length' "$COMMENTS_FILE")" 1
  assert_eq "$point replay: one claimed notice" \
    "$(find "$STATE/paperclip/notices/proj" -name '*.claimed.json' | wc -l | tr -d ' ')" 1
  assert_eq "$point replay: one brief" \
    "$(find "$STATE/paperclip/notices/proj" -name 'brief.*.md' | wc -l | tr -d ' ')" 1
  assert_eq "$point replay: both artifacts have receipts" \
    "$(jq -r --arg id "$ISSUE1" '.issues[$id] | .claimed_notice + "/" + .claimed_brief' "$STATE/paperclip/ledger.json")" \
    written/written
  assert_eq "$point replay: one terminal create" "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" 1
  assert_eq "$point replay: one pm_started row" \
    "$(jq '.pm_started | length' "$STATE/paperclip/ledger.json")" 1
  if [[ "$point" == create ]]; then
    assert_eq "create replay: the join records a candidate, not an unproved receipt" \
      "$(jq -r --arg id "$ISSUE1" '.pm_started[$id] | .state + "/" + (.terminal|tostring) + "/" + .candidate.handle' "$STATE/paperclip/ledger.json")" \
      intent/null/term-created-1
    assert_contains "create replay: the unresolved start is visible" \
      "$(jq -r --arg id "$ISSUE1" '.issues[$id].action_text' "$STATE/paperclip/ledger.json")" \
      'queued: no PM (start unresolved:'
  fi
  assert_eq "$point replay: claim confirmed by read-back" \
    "$(jq -r --arg id "$ISSUE1" '.issues[$id].claim' "$STATE/paperclip/ledger.json")" confirmed
done
COMMENTS_FILE=""

head1 "13. Refused stale-owner reap cannot authorize a PM start"
new_scenario refused_reap
COUNT_FILE="$SCEN/lookups"; printf '0\n' >"$COUNT_FILE"
REAP_START_FILE="$SCEN/unexpected-create"
reap_result="$(COUNT_FILE="$COUNT_FILE" REAP_START_FILE="$REAP_START_FILE" KIT_ROOT="$KIT_ROOT" bash -c '
  . "$KIT_ROOT/lib/afk-paperclip-start.sh"
  AFK_PC_CFG="{\"pm_start_enabled\":true}"
  detail="{\"createdByUserId\":\"board\"}"
  board_user_id=board; repo_path=/test/repo; host_name=test-host
  afk_pm_registry_lookup() {
    local n; n="$(cat "$COUNT_FILE")"; n=$((n+1)); printf "%s\n" "$n" >"$COUNT_FILE"
    if (( n == 1 )); then printf "{\"state\":\"none\",\"stale\":[{\"scope\":\"stale-owner\"}]}"
    else printf "{\"state\":\"unknown\",\"reason\":\"PM_OWNER_LIVE\"}"; fi
  }
  afk_cmd_pm_registry_reap() { return 1; }
  afk_pcs_create_terminal() { : >"$REAP_START_FILE"; }
  afk_pcs_start_pm
  printf "%s" "$AFK_PCS_ACTION_OVERRIDE"
')"
assert_eq "refused reap: post-reap lookup runs" "$(cat "$COUNT_FILE")" 2
assert_eq "refused reap: no terminal starts" "$([[ -e "$REAP_START_FILE" ]] && echo yes || echo no)" no
assert_contains "refused reap: live owner remains authoritative" "$reap_result" PM_OWNER_LIVE

if bash "$KIT_ROOT/tests/paperclip-pm-review-tests.sh"; then ok "review H1/H2/M4 regressions"
else bad "review H1/H2/M4 regressions"; fi

# FIX-6 cycle 2: an already-working issue with no inbox start hook retries
# through the report sweep, which must use its ledger row and config project.
head1 "14. report sweep retries a held PM start from the ledger"
new_scenario report_sweep_retry
write_config '{"pm_start_enabled":true}'
mkdir -p "$STATE/paperclip"
jq -nc --arg id "$ISSUE1" --arg a "$AGENT1" --arg p "$PROJ1" \
  '{issues:{($id):{identifier:"PROJ-1",host_agent_id:$a,paperclip_project_id:$p,slug:"proj",state:"working",action_text:"queued: no PM (start held: PM_BOOTSTRAP_UNAVAILABLE)",action_text_applied:"queued: no PM (start held: PM_BOOTSTRAP_UNAVAILABLE)"}},pm_started:{}}' \
  >"$STATE/paperclip/ledger.json"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET /api/agents/me/inbox-lite 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"in_progress\",\"identifier\":\"PROJ-1\",\"title\":\"T\",\"description\":\"D\",\"updatedAt\":\"2026-01-01T00:00:00Z\",\"createdByUserId\":\"$BOARD\",\"projectId\":\"$PROJ1\",\"unblockDescriptor\":{\"owner\":{\"agentId\":\"$AGENT1\"}}}"
route GET "/api/issues/$ISSUE1/active-run" 404 '{}'
AFK_PM_BOOTSTRAP_BIN="$KIT_ROOT/adapters/orca-pm-bootstrap.sh"
AFK_KIT_ROOT="$KIT_ROOT"; AFK_SKILLS_HOME="$SCEN/skills"
run_afk paperclip-poll --json
[[ "$RC" == 0 ]] || printf 'report sweep diagnostic: %s\n' "$OUT_TEXT"
assert_eq "sweep path starts once when the inbox has no start hook" "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" 1
assert_eq "sweep path records the issue start" "$(jq -r --arg id "$ISSUE1" '.pm_started[$id].state' "$STATE/paperclip/ledger.json")" created
unset AFK_PM_BOOTSTRAP_BIN AFK_KIT_ROOT AFK_SKILLS_HOME

# A queued hold with applied text is quiet: it has no pending claim, spool,
# final or reblock. It still retries when PM-start prerequisites recover.
head1 "14b. quiet queued hold retries without a report cycle"
new_scenario quiet_queued_hold
write_config '{"pm_start_enabled":true}'
mkdir -p "$STATE/paperclip"
jq -nc --arg id "$ISSUE1" --arg a "$AGENT1" --arg p "$PROJ1" \
  '{issues:{($id):{identifier:"PROJ-1",host_agent_id:$a,paperclip_project_id:$p,slug:"proj",state:"queued",action_text:"queued: no PM (start held: PM_BOOTSTRAP_UNAVAILABLE)",action_text_applied:"queued: no PM (start held: PM_BOOTSTRAP_UNAVAILABLE)",claim_comment_pending:false,claim_attempted:true,pending_final:null,reblock_due:null}},pm_started:{}}' \
  >"$STATE/paperclip/ledger.json"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET /api/agents/me/inbox-lite 200 '[]'
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"todo\",\"identifier\":\"PROJ-1\",\"title\":\"T\",\"description\":\"D\",\"updatedAt\":\"2026-01-01T00:00:00Z\",\"createdByUserId\":\"$BOARD\",\"projectId\":\"$PROJ1\",\"assigneeAgentId\":\"$AGENT1\"}"
AFK_PM_BOOTSTRAP_BIN="$KIT_ROOT/adapters/orca-pm-bootstrap.sh"
AFK_KIT_ROOT="$KIT_ROOT"; AFK_SKILLS_HOME="$SCEN/skills"
run_afk paperclip-poll --json
assert_eq "quiet queued hold creates exactly one PM terminal" "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" 1
assert_eq "quiet queued hold creates no report wake" "$(grep -c "^POST /api/agents/$AGENT1/wakeup$" "$LOG")" 0
assert_absent "quiet queued hold makes no issue PATCH" "$(cat "$LOG")" "PATCH /api/issues/$ISSUE1"
unset AFK_PM_BOOTSTRAP_BIN AFK_KIT_ROOT AFK_SKILLS_HOME

# FIX-6 C3: the queued held-start sweep and inbox blocked path share one
# per-pass classification guard. A failed first attempt remains retryable.
head1 "14c. held queued start is checked once across both paths"
new_scenario shared_start_guard
write_config '{"pm_start_enabled":true}'
mkdir -p "$STATE/paperclip"
jq -nc --arg id "$ISSUE1" --arg a "$AGENT1" --arg p "$PROJ1" \
  '{issues:{($id):{identifier:"PROJ-1",host_agent_id:$a,paperclip_project_id:$p,slug:"proj",state:"queued",action_text:"queued: no PM (start held: PM_BOOTSTRAP_UNAVAILABLE)",action_text_applied:"queued: no PM (start held: PM_BOOTSTRAP_UNAVAILABLE)"}},pm_started:{}}' \
  >"$STATE/paperclip/ledger.json"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"blocked\",\"identifier\":\"PROJ-1\",\"title\":\"T\",\"description\":\"D\",\"updatedAt\":\"2026-01-01T00:00:00Z\",\"createdByUserId\":\"$BOARD\",\"projectId\":\"$PROJ1\",\"assigneeAgentId\":\"$AGENT1\",\"unblockDescriptor\":{\"owner\":{\"agentId\":\"$AGENT1\"}}}"
route GET "/api/issues/$ISSUE1/active-run" 404 '{}'
route GET "/api/issues/$ISSUE1/comments" 200 '[]'
READINESS_CALL_LOG="$SCEN/readiness.log"
READINESS_OK=integrity
unset AFK_PM_BOOTSTRAP_BIN AFK_SKILLS_HOME
run_afk paperclip-poll --json
assert_eq "same-pass held start is classified once" "$(wc -l <"$READINESS_CALL_LOG" | tr -d ' ')" 1
assert_eq "same-pass held start creates no terminal" "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" 0
assert_contains "same-pass held start remains queued for retry" \
  "$(jq -r --arg id "$ISSUE1" '.issues[$id].action_text' "$STATE/paperclip/ledger.json")" "queued: no PM"
AFK_PM_BOOTSTRAP_BIN="$KIT_ROOT/adapters/orca-pm-bootstrap.sh"
AFK_KIT_ROOT="$KIT_ROOT"; AFK_SKILLS_HOME="$SCEN/skills"
READINESS_OK=true
run_afk paperclip-poll --json
assert_eq "later pass remains eligible for one retry" "$(wc -l <"$READINESS_CALL_LOG" | tr -d ' ')" 2
assert_eq "later retry creates exactly one PM terminal" "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" 1
unset READINESS_CALL_LOG READINESS_OK AFK_PM_BOOTSTRAP_BIN AFK_KIT_ROOT AFK_SKILLS_HOME

# A live registry owner with no pm_started row is a confirmation for the
# report cycle. It clears the stale hold once, and the marker is consumed.
head1 "15. live registry confirmation clears held text once"
new_scenario live_confirmation
write_config '{"pm_start_enabled":true}'
mkdir -p "$STATE/paperclip"
SK="$(scope_key term-confirmed)"; mkdir -p "$STATE/pm/scopes/$SK"
jq -nc --arg t term-confirmed --arg wp "$REPO" \
  '{schema:"afk-pm-ownership/3",owned:true,terminal:$t,session:"s",harness:"claude",worktree:{path:$wp}}' \
  >"$STATE/pm/scopes/$SK/ownership.json"
printf '{"result":{"terminals":[{"handle":"term-confirmed","connected":true,"orphaned":false}]}}' >"$ORCA_TERMLIST_FILE"
jq -nc --arg id "$ISSUE1" --arg a "$AGENT1" --arg p "$PROJ1" \
  '{issues:{($id):{identifier:"PROJ-1",host_agent_id:$a,paperclip_project_id:$p,slug:"proj",state:"working",action_text:"queued: no PM (start held: PM_BOOTSTRAP_UNAVAILABLE)",action_text_applied:"queued: no PM (start held: PM_BOOTSTRAP_UNAVAILABLE)"}},pm_started:{}}' \
  >"$STATE/paperclip/ledger.json"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 "{\"status\":\"in_progress\",\"identifier\":\"PROJ-1\",\"title\":\"T\",\"description\":\"D\",\"updatedAt\":\"2026-01-01T00:00:00Z\",\"createdByUserId\":\"$BOARD\",\"projectId\":\"$PROJ1\",\"unblockDescriptor\":{\"owner\":{\"agentId\":\"$AGENT1\"}}}"
route GET "/api/issues/$ISSUE1/active-run" 404 '{}'
route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-live"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
run_afk paperclip-poll --json
assert_eq "live confirmation consumed without pm_started receipt" "$(jq -r --arg id "$ISSUE1" '.issues[$id] | has("pm_confirmed")' "$STATE/paperclip/ledger.json")" false
assert_eq "live confirmation produces one report self-block" "$(grep -c '"status":"blocked"' "$BODYLOG")" 1
assert_absent "live confirmation clears the held action text" "$(jq -r --arg id "$ISSUE1" '.issues[$id].action_text' "$STATE/paperclip/ledger.json")" "no PM"
: >"$LOG"; : >"$BODYLOG"; route GET "/api/issues/$ISSUE1" 200 "{\"status\":\"in_progress\",\"identifier\":\"PROJ-1\",\"title\":\"T\",\"description\":\"D\",\"updatedAt\":\"2026-01-01T00:00:00Z\",\"createdByUserId\":\"$BOARD\",\"projectId\":\"$PROJ1\"}"
route GET "/api/issues/$ISSUE1/active-run" 404 '{}'
run_afk paperclip-poll --json
assert_eq "consumed confirmation does not repeat the report PATCH" "$(grep -c '"status":"blocked"' "$BODYLOG")" 0

# A changed hold is pending declaration until the report cycle PATCHes it.
head1 "16. changed hold text is applied once"
new_scenario changed_hold
write_config '{"pm_start_enabled":true}'
mkdir -p "$STATE/paperclip"
jq -nc --arg id "$ISSUE1" --arg a "$AGENT1" --arg p "$PROJ1" \
  '{issues:{($id):{identifier:"PROJ-1",host_agent_id:$a,paperclip_project_id:$p,slug:"proj",state:"working",action_text:"queued: no PM (start held: PM_BOOTSTRAP_UNAVAILABLE)",action_text_applied:"queued: no PM (start held: PM_REGISTRY_UNAVAILABLE)"}},pm_started:{}}' \
  >"$STATE/paperclip/ledger.json"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET "/api/agents/me/inbox-lite" 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 "{\"status\":\"in_progress\",\"identifier\":\"PROJ-1\",\"title\":\"T\",\"description\":\"D\",\"updatedAt\":\"2026-01-01T00:00:00Z\",\"createdByUserId\":\"$BOARD\",\"projectId\":\"$PROJ1\"}"
route GET "/api/issues/$ISSUE1/active-run" 404 '{}'
route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-change"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
AFK_KIT_ROOT="$SCEN/no-kit"; AFK_SKILLS_HOME="$SCEN/no-skills"
unset AFK_PM_BOOTSTRAP_BIN
run_afk paperclip-poll --json
assert_eq "new hold is reported with one PATCH" "$(grep -c '"status":"blocked"' "$BODYLOG")" 1
assert_eq "new hold becomes applied only after report PATCH" "$(jq -r --arg id "$ISSUE1" '.issues[$id].action_text_applied' "$STATE/paperclip/ledger.json")" \
  "queued: no PM (start held: PM_BOOTSTRAP_UNAVAILABLE)"
: >"$LOG"; : >"$BODYLOG"
run_afk paperclip-poll --json
assert_eq "applied hold stays quiet on the next pass" "$(grep -c '"status":"blocked"' "$BODYLOG")" 0

head1 "17. stale current detail cannot retry a held PM start"
new_scenario stale_held_start
write_config '{"pm_start_enabled":true}'
mkdir -p "$STATE/paperclip"
jq -nc --arg id "$ISSUE1" --arg a "$AGENT1" --arg p "$PROJ1" \
  '{issues:{($id):{identifier:"PROJ-1",host_agent_id:$a,paperclip_project_id:$p,slug:"proj",state:"queued",action_text:"queued: no PM (start refused: PM_BOOTSTRAP_UNAVAILABLE)",action_text_applied:"queued: no PM (start refused: PM_BOOTSTRAP_UNAVAILABLE)"}},pm_started:{}}' \
  >"$STATE/paperclip/ledger.json"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET /api/agents/me/inbox-lite 200 '[]'
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"cancelled\",\"identifier\":\"PROJ-1\",\"projectId\":\"$PROJ1\",\"assigneeAgentId\":\"$AGENT1\"}"
READINESS_CALL_LOG="$SCEN/stale-readiness.log"
: >"$READINESS_CALL_LOG"
AFK_PM_BOOTSTRAP_BIN="$KIT_ROOT/adapters/orca-pm-bootstrap.sh"
AFK_KIT_ROOT="$KIT_ROOT"; AFK_SKILLS_HOME="$SCEN/skills"
run_afk paperclip-poll --json
assert_eq "stale closed detail creates no PM terminal" "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" 0
assert_eq "stale closed detail skips PM-start classification" "$(wc -l <"$READINESS_CALL_LOG" | tr -d ' ')" 0
unset AFK_PM_BOOTSTRAP_BIN AFK_KIT_ROOT AFK_SKILLS_HOME READINESS_CALL_LOG

head1 "17b. held retry requires authoritative current ownership"
new_scenario unowned_held_start
write_config '{"pm_start_enabled":true}'
mkdir -p "$STATE/paperclip"
jq -nc --arg id "$ISSUE1" --arg a "$AGENT1" --arg p "$PROJ1" \
  '{issues:{($id):{identifier:"PROJ-1",host_agent_id:$a,paperclip_project_id:$p,slug:"proj",state:"queued",action_text:"queued: no PM (start refused: PM_BOOTSTRAP_UNAVAILABLE)",action_text_applied:"queued: no PM (start refused: PM_BOOTSTRAP_UNAVAILABLE)"}},pm_started:{}}' \
  >"$STATE/paperclip/ledger.json"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET "/api/agents/me/inbox-lite" 200 '[]'
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"todo\",\"identifier\":\"PROJ-1\",\"projectId\":\"$PROJ1\",\"createdByUserId\":\"$BOARD\"}"
READINESS_CALL_LOG="$SCEN/unowned-readiness.log"
: >"$READINESS_CALL_LOG"
AFK_PM_BOOTSTRAP_BIN="$KIT_ROOT/adapters/orca-pm-bootstrap.sh"
AFK_KIT_ROOT="$KIT_ROOT"; AFK_SKILLS_HOME="$SCEN/skills"
run_afk paperclip-poll --json
assert_eq "unowned current detail skips PM-start classification" "$(wc -l <"$READINESS_CALL_LOG" | tr -d ' ')" 0
assert_eq "unowned current detail creates no PM terminal" "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" 0
unset AFK_PM_BOOTSTRAP_BIN AFK_KIT_ROOT AFK_SKILLS_HOME READINESS_CALL_LOG

head1 "18. eligible omitted hold stays queued and retries later"
new_scenario omitted_eligible_hold
write_config '{"pm_start_enabled":true}'
mkdir -p "$STATE/paperclip"
jq -nc --arg id "$ISSUE1" --arg a "$AGENT1" --arg p "$PROJ1" \
  '{issues:{($id):{identifier:"PROJ-1",host_agent_id:$a,paperclip_project_id:$p,slug:"proj",state:"queued",action_text:"queued: no PM (start refused: PM_BOOTSTRAP_UNAVAILABLE)",action_text_applied:"queued: no PM (start refused: PM_BOOTSTRAP_UNAVAILABLE)"}},pm_started:{}}' \
  >"$STATE/paperclip/ledger.json"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET /api/agents/me/inbox-lite 200 '[]'
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"todo\",\"identifier\":\"PROJ-1\",\"projectId\":\"$PROJ1\",\"assigneeAgentId\":\"$AGENT1\",\"createdByUserId\":\"$BOARD\"}"
READINESS_CALL_LOG="$SCEN/omitted-readiness.log"
unset AFK_PM_BOOTSTRAP_BIN AFK_KIT_ROOT AFK_SKILLS_HOME
READINESS_OK=false; READINESS_REASON=PM_BOOTSTRAP_UNAVAILABLE
run_afk paperclip-poll --json
assert_eq "eligible omitted issue remains queued" "$(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$STATE/paperclip/ledger.json")" queued
assert_eq "eligible omitted issue retains its hold text" "$(jq -r --arg id "$ISSUE1" '.issues[$id].action_text' "$STATE/paperclip/ledger.json")" \
  "queued: no PM (start refused: PM_BOOTSTRAP_UNAVAILABLE)"
assert_eq "omitted first pass creates no terminal" "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" 0
AFK_PM_BOOTSTRAP_BIN="$KIT_ROOT/adapters/orca-pm-bootstrap.sh"
AFK_KIT_ROOT="$KIT_ROOT"; AFK_SKILLS_HOME="$SCEN/skills"
READINESS_OK=true; unset READINESS_REASON
run_afk paperclip-poll --json
assert_eq "eligible omitted issue retries on a later pass" "$(wc -l <"$ORCA_CREATE_LOG" | tr -d ' ')" 1
unset AFK_PM_BOOTSTRAP_BIN AFK_KIT_ROOT AFK_SKILLS_HOME READINESS_CALL_LOG

head1 "19. ordinary queue text cannot replace a PM-start hold"
new_scenario queue_text_preserves_hold
write_config '{"pm_start_enabled":true}'
mkdir -p "$STATE/paperclip"
jq -nc --arg id "$ISSUE1" --arg blocker "$ISSUE2" --arg a "$AGENT1" --arg p "$PROJ1" \
  '{issues:{($id):{identifier:"PROJ-1",host_agent_id:$a,paperclip_project_id:$p,slug:"proj",state:"queued",action_text:"queued: no PM (start refused: PM_BOOTSTRAP_UNAVAILABLE)",action_text_applied:"queued: no PM (start refused: PM_BOOTSTRAP_UNAVAILABLE)"},($blocker):{identifier:"PROJ-2",host_agent_id:$a,paperclip_project_id:$p,slug:"proj",state:"working",action_text:"AFK host is working on this",action_text_applied:"AFK host is working on this"}},pm_started:{}}' \
  >"$STATE/paperclip/ledger.json"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET /api/agents/me/inbox-lite 200 "[{\"id\":\"$ISSUE2\"}]"
route GET "/api/issues/$ISSUE1" 200 \
  "{\"status\":\"todo\",\"identifier\":\"PROJ-1\",\"projectId\":\"$PROJ1\",\"assigneeAgentId\":\"$AGENT1\",\"createdByUserId\":\"$BOARD\"}"
route GET "/api/issues/$ISSUE2" 500 '{}'
READINESS_CALL_LOG="$SCEN/queue-readiness.log"
unset AFK_PM_BOOTSTRAP_BIN AFK_KIT_ROOT AFK_SKILLS_HOME
READINESS_OK=false; READINESS_REASON=PM_BOOTSTRAP_UNAVAILABLE
run_afk paperclip-poll --json
assert_eq "ordinary queue sweep preserves PM-start hold text" "$(jq -r --arg id "$ISSUE1" '.issues[$id].action_text' "$STATE/paperclip/ledger.json")" \
  "queued: no PM (start refused: PM_BOOTSTRAP_UNAVAILABLE)"
assert_eq "quiet hold pass emits no repeated wakeup" "$(grep -c "^POST /api/agents/$AGENT1/wakeup$" "$LOG")" 0
unset READINESS_CALL_LOG READINESS_OK READINESS_REASON

# ============================================================================
assert_eq "the PATH decoy orca never ran" \
  "$([[ -e "$STUBS/.bare-orca-ran" ]] && echo ran || echo never)" "never"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
