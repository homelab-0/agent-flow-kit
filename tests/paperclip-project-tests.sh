#!/usr/bin/env bash
# paperclip-project-tests.sh — the isolated gate for `paperclip-project
# add|set|remove|list` and `paperclip-config --migrate`
# (lib/afk-paperclip-project.sh, AD-23 onboarding and migration).
#
# No network: op and curl are stubs on PATH, the same pattern as
# tests/paperclip-poll-tests.sh.
#
# Usage: tests/paperclip-project-tests.sh
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

STUBS="$TMPROOT/stubs"; mkdir -p "$STUBS"
cat >"$STUBS/op" <<'SH'
#!/usr/bin/env bash
[[ "$1" == read && "$2" == op://test/agent1 ]] && { printf 'KEY-AGENT1-SECRET-VALUE\n'; exit 0; }
exit 1
SH
# A fixture per "<METHOD>_<path>" (slashes as _); first line is the status.
cat >"$STUBS/curl" <<'SH'
#!/usr/bin/env bash
method=GET; n=$#; args=("$@")
for ((i = 0; i < n; i++)); do [[ "${args[$i]}" == -X ]] && method="${args[$((i + 1))]}"; done
url="${args[$((n - 1))]}"; tmp="${url#*://}"; path="/${tmp#*/}"
printf '%s %s\n' "$method" "$path" >>"$CURL_STUB_LOG"
key="${method}_${path#/}"; key="${key//\//_}"
f="$CURL_STUB_FIXTURES/$key"
[[ -f "$f" ]] || f="$CURL_STUB_FIXTURES/DEFAULT"
[[ -f "$f" ]] || { printf '000'; exit 0; }
code="$(head -1 "$f")"
if [[ "$method" == GET && "$path" =~ ^/api/issues/[0-9a-f-]{36}$ && -f "$CURL_STUB_FIXTURES/.default_project" ]] &&
   ! grep -q '"projectId"' "$f"; then
  tail -n +2 "$f" | jq -c --arg p "$(cat "$CURL_STUB_FIXTURES/.default_project")" '. + {projectId: $p}'
else
  tail -n +2 "$f"
fi
printf '%s' "$code"
SH
chmod +x "$STUBS"/*

route() { local key="${1}_${2#/}"; key="${key//\//_}"; { printf '%s\n' "$3"; [[ -n "${4:-}" ]] && printf '%s\n' "$4"; } >"$FIXDIR/$key"; }

new_scenario() {
  SCEN="$TMPROOT/$1"; mkdir -p "$SCEN"
  HOME="$SCEN/home"; mkdir -p "$HOME"
  STATE="$HOME/.local/state/agent-flow-kit"
  FIXDIR="$SCEN/fixtures"; mkdir -p "$FIXDIR"
  CONFIG="$SCEN/paperclip.json"; LOG="$SCEN/curl.log"; : >"$LOG"
}

RC=0 OUT=""
afk() { # <command...> -- runs the kit against the scenario's config and stubs
  OUT="$(env -i PATH="$STUBS:$PATH" HOME="$HOME" LANG=C ${AFK_TEST_TMPDIR:+TMPDIR="$AFK_TEST_TMPDIR"} \
    AFK_STATE_DIR="$STATE" AFK_PAPERCLIP_CONFIG="$CONFIG" AFK_OP_BIN="$STUBS/op" AFK_CURL_BIN="$STUBS/curl" \
    CURL_STUB_LOG="$LOG" CURL_STUB_FIXTURES="$FIXDIR" bash "$AFK" "$@" 2>&1)"
  RC=$?
}

COMPANY="cccccccc-cccc-cccc-cccc-cccccccccccc"
BOARD="emXp8Svi8ncWyL1EORTkRNQYjFjCdQon"
AGENT1="11111111-1111-1111-1111-111111111111"
PROJ1="aaaaaaaa-0000-4000-8000-000000000001"
PROJ2="aaaaaaaa-0000-4000-8000-000000000002"
ISSUE1="e1111111-1111-1111-1111-111111111111"

mkrepo() { # <path> <origin-url>
  mkdir -p "$1"; git -C "$1" init -q -b main
  mkdir -p "$1/.afk"; printf 'bash tests/run-tests.sh\n' >"$1/.afk/gates-allowlist"
  git -C "$1" add .afk/gates-allowlist
  git -C "$1" -c user.name=t -c user.email=t@t commit -qm init
  git -C "$1" remote add origin "$2"
}
REPO1="$TMPROOT/repos/repo1"; mkrepo "$REPO1" "git@github.com:test/repo1.git"
REPO2="$TMPROOT/repos/repo2"; mkrepo "$REPO2" "git@github.com:test/repo2.git"
KITREPO="$TMPROOT/repos/agent-flow-kit"; mkrepo "$KITREPO" "git@github.com:test/agent-flow-kit.git"
NOALLOW="$TMPROOT/repos/noallow"; mkdir -p "$NOALLOW"; git -C "$NOALLOW" init -q -b main
NOTGIT="$TMPROOT/repos/notgit"; mkdir -p "$NOTGIT"

project_body() { # <id> [<archivedAt>] [<repoUrl>]
  jq -nc --arg p "$1" --arg a "${2:-}" --arg u "${3:-}" \
    '{id:$p, name:"Proj", archivedAt:(if $a == "" then null else $a end), codebase:{repoUrl:(if $u == "" then null else $u end)}}'
}

# v2_config [<projects-json>] -- a v2 config with zero projects by default.
v2_config() {
  jq -n --arg co "$COMPANY" --arg bu "$BOARD" --arg ag "$AGENT1" --argjson p "${1:-[]}" \
    '{schema:"afk-paperclip-config/2", api_url:"https://paperclip.test", company_id:$co, board_user_id:$bu,
      host:{label:"test-host", agent_id:$ag, key_ref:"op://test/agent1"}, projects:$p, pm_start_enabled:true}' >"$CONFIG"
}

# ============================================================================
head1 "0. bash -n"
# ============================================================================
if bash -n "$KIT_ROOT/lib/afk-paperclip-project.sh"; then ok "bash -n lib/afk-paperclip-project.sh"
else bad "bash -n lib/afk-paperclip-project.sh"; fi

# ============================================================================
head1 "1. add: success, then the poller resolves an issue to it"
# ============================================================================
new_scenario add_ok
v2_config
route GET "/api/projects/$PROJ1" 200 "$(project_body "$PROJ1" "" "https://github.com/test/repo1")"
afk paperclip-project add --project-id "$PROJ1" --slug proj --repo "$REPO1" --max-active 2
assert_eq "add: exit 0" "$RC" "0"
assert_contains "add: reports the slug" "$OUT" "added project proj"
assert_eq "add: row written" "$(jq -c '.projects[0] | [.slug, .harness, .max_active_issues, .merge]' "$CONFIG")" '["proj","claude",2,"human"]'
assert_eq "add: other fields preserved" "$(jq -r '.pm_start_enabled' "$CONFIG")" "true"
assert_eq "add: config mode 600" "$(stat -c %a "$CONFIG")" "600"
assert_eq "add: only the project was read" "$(grep -vc '^GET /api/projects/' "$LOG")" "0"
route GET /api/agents/me 200 "{\"id\":\"$AGENT1\"}"
route GET /api/agents/me/inbox-lite 200 "[{\"id\":\"$ISSUE1\"}]"
route GET "/api/issues/$ISSUE1" 200 "{\"status\":\"in_progress\",\"identifier\":\"P-1\",\"title\":\"T\",\"description\":\"D\",\"updatedAt\":\"2026-01-01T00:00:00Z\",\"projectId\":\"$PROJ1\"}"
route GET "/api/issues/$ISSUE1/active-run" 200 '{"id":"run-1"}'
route PATCH "/api/issues/$ISSUE1" 200 '{}'
route POST "/api/issues/$ISSUE1/comments" 201 '{}'
route POST "/api/agents/$AGENT1/wakeup" 202 '{"id":"run-2"}'
afk paperclip-poll --json
assert_eq "poll after add: issue pinned to the new slug" "$(jq -r --arg id "$ISSUE1" '.issues[$id].slug' "$STATE/paperclip/ledger.json")" "proj"
assert_absent "poll after add: not waiting_setup" "$(jq -r --arg id "$ISSUE1" '.issues[$id].state' "$STATE/paperclip/ledger.json")" "waiting_setup"

# ============================================================================
head1 "2. add: refusals"
# ============================================================================
new_scenario add_refuse
v2_config "[{\"paperclip_project_id\":\"$PROJ2\",\"slug\":\"other\",\"repo_path\":\"$REPO2\",\"harness\":\"claude\",\"max_active_issues\":1}]"
before="$(cat "$CONFIG")"
route GET "/api/projects/$PROJ1" 200 "$(project_body "$PROJ1")"
add() { afk paperclip-project add --project-id "$PROJ1" --slug proj --repo "$REPO1" "$@"; }
afk paperclip-project add --project-id nope --slug proj --repo "$REPO1"
assert_contains "bad project id" "$OUT" "PAPERCLIP_ID_INVALID"
afk paperclip-project add --project-id "$PROJ1" --slug "Bad Slug" --repo "$REPO1"
assert_contains "bad slug" "$OUT" "PAPERCLIP_CONFIG_INVALID"
afk paperclip-project add --project-id "$PROJ1" --slug claimed --repo "$REPO1"
assert_contains "reserved slug" "$OUT" "PAPERCLIP_CONFIG_INVALID"
afk paperclip-project add --project-id "$PROJ1" --slug proj --repo relative/path
assert_contains "relative repo" "$OUT" "PAPERCLIP_CONFIG_INVALID"
afk paperclip-project add --project-id "$PROJ1" --slug proj --repo "$NOTGIT"
assert_contains "not a git repo" "$OUT" "NOT_A_GIT_REPO"
afk paperclip-project add --project-id "$PROJ1" --slug proj --repo "$NOALLOW"
assert_contains "no gates allowlist" "$OUT" "PAPERCLIP_PROJECT_REPO_NOT_READY"
afk paperclip-project add --project-id "$PROJ2" --slug proj --repo "$REPO1"
assert_contains "duplicate project id" "$OUT" "already configured"
afk paperclip-project add --project-id "$PROJ1" --slug other --repo "$REPO1"
assert_contains "duplicate slug" "$OUT" "already configured"
afk paperclip-project add --project-id "$PROJ1" --slug proj --repo "$REPO2"
assert_contains "duplicate repo" "$OUT" "already configured"
git -C "$REPO1" worktree add -q "$TMPROOT/repos/repo1-wt" -b wt 2>/dev/null
afk paperclip-project add --project-id "$PROJ1" --slug proj --repo "$TMPROOT/repos/repo1-wt"
assert_absent "a linked worktree of another repo is a different repo" "$OUT" "already configured"
v2_config "[{\"paperclip_project_id\":\"$PROJ2\",\"slug\":\"other\",\"repo_path\":\"$REPO1\",\"harness\":\"claude\",\"max_active_issues\":1}]"
afk paperclip-project add --project-id "$PROJ1" --slug proj --repo "$TMPROOT/repos/repo1-wt"
assert_contains "duplicate common-dir through a linked worktree" "$OUT" "already configured"
before="$(cat "$CONFIG")"
afk paperclip-project add --project-id "$PROJ1" --slug proj --repo "$KITREPO" --merge pm
assert_contains "--merge pm on the kit repo" "$OUT" "PAPERCLIP_MERGE_KIT_REPO"
afk paperclip-project add --project-id "$PROJ1" --slug proj --repo "$REPO2" --merge bogus
assert_contains "bad merge value" "$OUT" "PAPERCLIP_CONFIG_INVALID"
route GET "/api/projects/$PROJ1" 404 '{}'
afk paperclip-project add --project-id "$PROJ1" --slug proj --repo "$KITREPO"
assert_contains "project not 200" "$OUT" "PAPERCLIP_PROJECT_UNREADABLE"
route GET "/api/projects/$PROJ1" 200 "$(project_body "$PROJ1" "2026-01-01T00:00:00Z")"
afk paperclip-project add --project-id "$PROJ1" --slug proj --repo "$KITREPO"
assert_contains "archived project" "$OUT" "PAPERCLIP_PROJECT_ARCHIVED"
assert_eq "no refusal changed the config" "$(cat "$CONFIG")" "$before"

new_scenario add_mismatch
v2_config
route GET "/api/projects/$PROJ1" 200 "$(project_body "$PROJ1" "" "https://GitHub.com/test/elsewhere.git")"
afk paperclip-project add --project-id "$PROJ1" --slug proj --repo "$REPO1"
assert_eq "mismatch: refused" "$RC" "4"
assert_contains "mismatch: code" "$OUT" "PAPERCLIP_PROJECT_REPO_MISMATCH"
assert_contains "mismatch: Paperclip's normalized form" "$OUT" "github.com/test/elsewhere"
assert_contains "mismatch: the origin's normalized form" "$OUT" "github.com/test/repo1"
assert_eq "mismatch: nothing written" "$(jq '.projects | length' "$CONFIG")" "0"
afk paperclip-project add --project-id "$PROJ1" --slug proj --repo "$REPO1" --accept-mismatch
assert_eq "mismatch + --accept-mismatch: added" "$RC" "0"
assert_contains "mismatch + --accept-mismatch: says the poller still self-blocks" "$OUT" "self-blocks"

new_scenario add_no_write
v2_config
route GET "/api/projects/$PROJ1" 200 "$(project_body "$PROJ1")"
afk paperclip-project add --project-id "$PROJ1" --slug proj --repo "$REPO1"
assert_eq "add never writes to Paperclip" "$(grep -vc '^GET ' "$LOG")" "0"

# ============================================================================
head1 "3. set, remove, list"
# ============================================================================
new_scenario set_remove
v2_config "[{\"paperclip_project_id\":\"$PROJ1\",\"slug\":\"proj\",\"repo_path\":\"$REPO1\",\"harness\":\"claude\",\"max_active_issues\":1},
            {\"paperclip_project_id\":\"$PROJ2\",\"slug\":\"kit\",\"repo_path\":\"$KITREPO\",\"harness\":\"claude\",\"max_active_issues\":1}]"
route GET "/api/projects/$PROJ1" 200 "$(project_body "$PROJ1")"
route GET "/api/projects/$PROJ2" 200 "$(project_body "$PROJ2" "2026-01-01T00:00:00Z")"
afk paperclip-project set --slug proj --harness codex --max-active 3 --merge pm
assert_eq "set: fields changed" "$(jq -c '.projects[0] | [.harness, .max_active_issues, .merge]' "$CONFIG")" '["codex",3,"pm"]'
assert_eq "set: the other project untouched" "$(jq -r '.projects[1].harness' "$CONFIG")" "claude"
afk paperclip-project set --slug kit --merge pm
assert_contains "set --merge pm on the kit repo refused" "$OUT" "PAPERCLIP_MERGE_KIT_REPO"
afk paperclip-project set --slug nope --max-active 2
assert_contains "set: unknown slug" "$OUT" "PAPERCLIP_PROJECT_UNKNOWN"
afk paperclip-project set --slug proj --harness emacs
assert_contains "set: bad harness" "$OUT" "PAPERCLIP_CONFIG_INVALID"
afk paperclip-project list --json
assert_eq "list: readiness of a live project" "$(jq -r '.projects[] | select(.slug == "proj") | .readiness' <<<"$OUT")" "ok"
assert_eq "list: readiness of an archived project" "$(jq -r '.projects[] | select(.slug == "kit") | .readiness' <<<"$OUT")" "PAPERCLIP_PROJECT_ARCHIVED"
afk paperclip-project list
assert_contains "list: table has a readiness column" "$OUT" "readiness"
mkdir -p "$STATE/paperclip"
jq -n --arg id "$ISSUE1" '{issues: {($id): {slug: "proj", state: "working"}}}' >"$STATE/paperclip/ledger.json"
afk paperclip-project remove --slug proj
assert_contains "remove: refused while an issue is not closed" "$OUT" "PAPERCLIP_PROJECT_IN_USE"
assert_eq "remove: refused, row kept" "$(jq '.projects | length' "$CONFIG")" "2"
jq '.issues[].state = "closed"' "$STATE/paperclip/ledger.json" >"$SCEN/l" && mv "$SCEN/l" "$STATE/paperclip/ledger.json"
afk paperclip-project remove --slug proj
assert_eq "remove: allowed once closed" "$(jq -r '.projects | map(.slug) | join(",")' "$CONFIG")" "kit"
afk paperclip-project remove --slug proj
assert_contains "remove: unknown slug" "$OUT" "PAPERCLIP_PROJECT_UNKNOWN"
afk paperclip-project bogus
assert_eq "an unknown verb is a usage error" "$RC" "1"

# ============================================================================
head1 "4. paperclip-config --migrate"
# ============================================================================
v1_config() { # the real ubuntu-devbox v1 shape, ids redacted
  jq -n --arg co "$COMPANY" --arg bu "$BOARD" --arg ag "$AGENT1" --arg repo "$1" '
    {api_url:"https://paperclip.example", company_id:$co, board_user_id:$bu, host_label:"ubuntu-devbox",
     maintenance_issue_id:"dddddddd-dddd-dddd-dddd-dddddddddddd",
     interim_comment_approval:{attested_on:"2026-09-26", paperclip_commit:"4a1b2c3d4e5f60718293a4b5c6d7e8f9a0b1c2d3"},
     pm_start_enabled:true,
     agents:[{agent_id:$ag, key_ref:"op://test/agent1", project:"Spektacle", repo_path:$repo, harness:"claude",
              max_active_issues:1, pm_merge_allowed:true}]}' >"$CONFIG"
}
new_scenario migrate_ok
mkrepo "$TMPROOT/repos/Spektacle" "git@github.com:test/Spektacle.git"
v1_config "$TMPROOT/repos/Spektacle"
afk paperclip-config --migrate
assert_contains "no --project-id: refused" "$OUT" "PAPERCLIP_ID_INVALID"
assert_eq "no --project-id: the file is untouched" "$(jq -r 'has("agents")' "$CONFIG")" "true"
afk paperclip-config --migrate --project-id "$PROJ1"
assert_eq "migrate: exit 0" "$RC" "0"
assert_contains "migrate: says pm_merge_allowed was dropped" "$OUT" "pm_merge_allowed"
assert_eq "migrate: schema" "$(jq -r .schema "$CONFIG")" "afk-paperclip-config/2"
assert_eq "migrate: host" "$(jq -c '.host' "$CONFIG")" "{\"label\":\"ubuntu-devbox\",\"agent_id\":\"$AGENT1\",\"key_ref\":\"op://test/agent1\"}"
assert_eq "migrate: project row" "$(jq -c '.projects[0] | [.slug, .paperclip_project_id, .harness, .max_active_issues, .merge]' "$CONFIG")" "[\"spektacle\",\"$PROJ1\",\"claude\",1,\"human\"]"
assert_eq "migrate: v1 keys gone" "$(jq -r '[has("agents"), has("host_label"), has("pm_merge_allowed")] | any' "$CONFIG")" "false"
assert_eq "migrate: other fields kept" "$(jq -c '[.pm_start_enabled, .maintenance_issue_id, .interim_comment_approval.attested_on]' "$CONFIG")" '[true,"dddddddd-dddd-dddd-dddd-dddddddddddd","2026-09-26"]'
assert_eq "migrate: config mode 600" "$(stat -c %a "$CONFIG")" "600"
backups=("$CONFIG".v1.*)
assert_eq "migrate: one backup" "${#backups[@]}" "1"
assert_eq "migrate: backup is the v1 file" "$(jq -r 'has("agents")' "${backups[0]}")" "true"
afk paperclip-project list --json
assert_eq "migrate: the loader accepts the result" "$RC" "0"
before="$(cat "$CONFIG")"
afk paperclip-project set --slug spektacle --max-active 1
assert_eq "migrate: reload and rewrite is byte-for-byte stable" "$(cat "$CONFIG")" "$before"
afk paperclip-config --migrate --project-id "$PROJ1"
assert_contains "already v2" "$OUT" "PAPERCLIP_MIGRATE_NOT_NEEDED"

new_scenario migrate_refusals
v1_config "$TMPROOT/repos/Spektacle"
jq '.agents += [.agents[0]]' "$CONFIG" >"$SCEN/c" && mv "$SCEN/c" "$CONFIG"
afk paperclip-config --migrate --project-id "$PROJ1"
assert_contains "two agents" "$OUT" "PAPERCLIP_MIGRATE_MULTI_AGENT"
v1_config "$TMPROOT/repos/Spektacle"
jq '.agents[0].project = "Not A Slug!"' "$CONFIG" >"$SCEN/c" && mv "$SCEN/c" "$CONFIG"
afk paperclip-config --migrate --project-id "$PROJ1"
assert_contains "a v1 name that is not a slug needs --slug" "$OUT" "--slug"
afk paperclip-config --migrate --project-id "$PROJ1" --slug spektacle
assert_eq "--slug supplies it" "$RC" "0"
new_scenario migrate_held_issue
v1_config "$TMPROOT/repos/Spektacle"
mkdir -p "$STATE/paperclip"
jq -n '{issues: {"x": {slug: "p", state: "waiting_human"}}}' >"$STATE/paperclip/ledger.json"
afk paperclip-config --migrate --project-id "$PROJ1"
assert_contains "an issue that is not closed" "$OUT" "PAPERCLIP_MIGRATE_STATE_HELD"
assert_eq "held: the file is untouched" "$(jq -r 'has("agents")' "$CONFIG")" "true"
new_scenario migrate_held_notice
v1_config "$TMPROOT/repos/Spektacle"
mkdir -p "$STATE/paperclip/notices/claimed/k1"; echo '{}' >"$STATE/paperclip/notices/claimed/k1/n.json"
afk paperclip-config --migrate --project-id "$PROJ1"
assert_contains "a claimed notice" "$OUT" "PAPERCLIP_MIGRATE_STATE_HELD"

# ============================================================================
head1 "5. Review fixes: corrupt ledger, backup mode, loader probe, unreadable origin, no key in output"
# ============================================================================
new_scenario ledger_corrupt_remove
v2_config "[{\"paperclip_project_id\":\"$PROJ1\",\"slug\":\"proj\",\"repo_path\":\"$REPO1\",\"harness\":\"claude\",\"max_active_issues\":1}]"
mkdir -p "$STATE/paperclip"; printf 'garbage{' >"$STATE/paperclip/ledger.json"
afk paperclip-project remove --slug proj
assert_contains "remove: a corrupt ledger refuses" "$OUT" "PAPERCLIP_PROJECT_IN_USE"
assert_contains "remove: says the ledger is unreadable" "$OUT" "unreadable"
assert_eq "remove: corrupt ledger keeps the row" "$(jq '.projects | length' "$CONFIG")" "1"

new_scenario ledger_corrupt_migrate
v1_config "$TMPROOT/repos/Spektacle"
mkdir -p "$STATE/paperclip"; printf 'garbage{' >"$STATE/paperclip/ledger.json"
afk paperclip-config --migrate --project-id "$PROJ1"
assert_contains "migrate: a corrupt ledger refuses" "$OUT" "PAPERCLIP_MIGRATE_STATE_HELD"
assert_eq "migrate: corrupt ledger leaves the file" "$(jq -r 'has("agents")' "$CONFIG")" "true"

new_scenario migrate_backup_mode
v1_config "$TMPROOT/repos/Spektacle"; chmod 644 "$CONFIG"
afk paperclip-config --migrate --project-id "$PROJ1" --json
backups=("$CONFIG".v1.*)
assert_eq "migrate: backup is mode 600 even from a 644 source" "$(stat -c %a "${backups[0]}")" "600"
assert_absent "migrate --json: no key value" "$OUT" "KEY-AGENT1-SECRET-VALUE"

new_scenario migrate_probe_fails
v1_config "$TMPROOT/repos/Spektacle"
jq 'del(.host_label)' "$CONFIG" >"$SCEN/c" && mv "$SCEN/c" "$CONFIG"
afk paperclip-config --migrate --project-id "$PROJ1"
assert_contains "migrate: a result the loader refuses is not written" "$OUT" "does not load"
assert_eq "migrate: probe failure leaves the v1 file" "$(jq -r 'has("agents")' "$CONFIG")" "true"
assert_eq "migrate: probe failure makes no backup" "$(ls "$CONFIG".v1.* 2>/dev/null | wc -l | tr -d ' ')" "0"

new_scenario add_origin_unreadable
v2_config
NOORIGIN="$TMPROOT/repos/noorigin"; mkrepo "$NOORIGIN" "git@github.com:test/x.git"; git -C "$NOORIGIN" remote remove origin
route GET "/api/projects/$PROJ1" 200 "$(project_body "$PROJ1" "" "https://github.com/test/x")"
afk paperclip-project add --project-id "$PROJ1" --slug proj --repo "$NOORIGIN"
assert_contains "add: repoUrl set and origin unreadable" "$OUT" "ORIGIN_UNREADABLE"
assert_eq "add: origin unreadable writes nothing" "$(jq '.projects | length' "$CONFIG")" "0"

new_scenario no_key_in_output
v2_config
route GET "/api/projects/$PROJ1" 200 "$(project_body "$PROJ1")"
afk paperclip-project add --project-id "$PROJ1" --slug proj --repo "$REPO1" --json
assert_absent "add --json: no key value" "$OUT" "KEY-AGENT1-SECRET-VALUE"
afk paperclip-project list --json
assert_absent "list --json: no key value" "$OUT" "KEY-AGENT1-SECRET-VALUE"
afk paperclip-project list
assert_absent "list: no key value" "$OUT" "KEY-AGENT1-SECRET-VALUE"

# ============================================================================
head1 "6. Triage: a value option never swallows a following option; probe write failure"
# ============================================================================
new_scenario flag_swallow
v2_config
route GET "/api/projects/$PROJ1" 200 "$(project_body "$PROJ1")"
afk paperclip-project add --project-id "$PROJ1" --repo --slug proj
assert_eq "add --repo --slug: a usage error" "$RC" "1"
assert_contains "add --repo --slug: names the option" "$OUT" "--repo requires its declared value"
assert_eq "add --repo --slug: nothing written" "$(jq '.projects | length' "$CONFIG")" "0"
afk paperclip-project set --slug proj --merge --harness codex
assert_eq "set --merge --harness: a usage error" "$RC" "1"

new_scenario probe_write_fails
v1_config "$TMPROOT/repos/Spektacle"
AFK_TEST_TMPDIR="$SCEN/no-such-dir" afk paperclip-config --migrate --project-id "$PROJ1"
assert_contains "migrate: an unwritable probe is a write failure" "$OUT" "PAPERCLIP_CONFIG_WRITE_FAILED"
assert_eq "migrate: probe failure leaves the v1 file" "$(jq -r 'has("agents")' "$CONFIG")" "true"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
