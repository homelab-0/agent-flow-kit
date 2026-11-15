#!/usr/bin/env bash
# factory-tooling-tests.sh — Hermetic tests for the two libraries the AFK
# Software Factory uses to manage its harnesses and their tooling:
#   lib/afk-tooling.sh    registry, Paperclip Studio sync, per-job worktree tooling
#   lib/afk-harnesses.sh  harness auth state, updates, model and pool discovery
#
# Nothing here reaches the network or runs a real harness CLI or package
# manager: HOME is a temp directory, `curl` and the package managers on PATH
# are stubs, AFK_HARNESS_BIN_DIR_OVERRIDE points at a directory this suite
# owns, and the Paperclip HTTP helper is replaced by a fixture-driven stub.
#
# AFK_FACTORY_TOOLING_TEST_LIB_DIR=<dir> runs the same tests against another
# copy of the two libraries. Every test here is written to fail on the code
# as it was before the fix it covers.

set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="${AFK_FACTORY_TOOLING_TEST_LIB_DIR:-$KIT_ROOT/lib}"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0 FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s (%s)\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
head1(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi
}

# ---------------------------------------------------------------------------
# Isolation
# ---------------------------------------------------------------------------

# No AFK_* setting of the calling shell may steer the code under test.
while IFS= read -r leaked_var; do
  unset "$leaked_var"
done < <(compgen -v | grep '^AFK_' || true)

export HOME="$TMPROOT/home"
export TMPDIR="$TMPROOT/tmp"
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$TMPDIR"
umask 022

# Stubs that shadow anything on PATH able to reach the network or install
# software. Each records that it was called and fails.
STUB_BIN="$TMPROOT/stub-bin"
STUB_CALLS="$TMPROOT/stub-calls.log"
mkdir -p "$STUB_BIN"
: > "$STUB_CALLS"
for stub_name in curl npm brew bun pnpm uv pipx cargo; do
  cat > "$STUB_BIN/$stub_name" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$stub_name" "\$*" >> "$STUB_CALLS"
exit 7
SH
  chmod +x "$STUB_BIN/$stub_name"
done
export PATH="$STUB_BIN:$PATH"
if [[ "$(command -v curl)" != "$STUB_BIN/curl" ]]; then
  printf 'cannot shadow curl on PATH; refusing to run\n' >&2
  exit 2
fi

# Harness binaries are only ever looked up here, never on the real PATH.
NO_HARNESS_BIN="$TMPROOT/no-harness-bin"
mkdir -p "$NO_HARNESS_BIN"
export AFK_HARNESS_BIN_DIR_OVERRIDE="$NO_HARNESS_BIN"

# shellcheck source=/dev/null
. "$LIB_DIR/afk-tooling.sh"
# shellcheck source=/dev/null
. "$LIB_DIR/afk-harnesses.sh"

# ---------------------------------------------------------------------------
# Paperclip stand-ins (defined instead of sourcing lib/afk-paperclip.sh)
# ---------------------------------------------------------------------------
# Fixture layout under $PC_DIR:
#   skills.json                 body of GET /api/companies/<id>/skills
#   files/<skill id>/<path>     content of one skill file
#   agents/<agent id>.code      HTTP status of GET /api/agents/<id>/skills (default 200)
#   agents/<agent id>.body      its body (default: nothing attached)
#   ledger.json                 hired project agents (default: none)
PC_DIR="$TMPROOT/unset-pc"
PC_LOG="$TMPROOT/unset-pc.log"
PC_CFG_FILE="$TMPROOT/no-paperclip.json"
CASE="$TMPROOT/unset-case"

afk_pc_config_path() { printf '%s' "$PC_CFG_FILE"; }
afk_pc_read_key() { printf 'test-key'; }
afk_pch_load_ledger() { cat "$PC_DIR/ledger.json" 2>/dev/null || printf '{}'; }

afk_pc_curl() { # <METHOD> <url> <key> <run_id> [<body>]
  local method="$1" url="$2" body="${5:-}" aid sid fpath code
  printf '%s %s %s\n' "$method" "$url" "$body" >> "$PC_LOG"
  case "$method $url" in
    "GET "*/api/companies/*/skills/*/files\?path=*)
      sid="${url#*/skills/}"; sid="${sid%%/files*}"
      fpath="${url##*\?path=}"
      if [[ -f "$PC_DIR/files/$sid/$fpath" ]]; then
        printf '200\n'
        jq -cn --arg p "$fpath" --arg c "$(cat "$PC_DIR/files/$sid/$fpath")" '{path: $p, content: $c}'
      else
        printf '404\n{}'
      fi ;;
    "GET "*/api/agents/*/skills)
      aid="${url#*/api/agents/}"; aid="${aid%%/skills}"
      code="$(cat "$PC_DIR/agents/$aid.code" 2>/dev/null || printf '200')"
      printf '%s\n%s' "$code" "$(cat "$PC_DIR/agents/$aid.body" 2>/dev/null || printf '{"desiredSkills":[]}')" ;;
    "GET "*/api/companies/*/skills)
      printf '200\n%s' "$(cat "$PC_DIR/skills.json" 2>/dev/null || printf '[]')" ;;
    "POST "*/api/companies/*/skills)
      printf '201\n{"id":"created-skill-id"}' ;;
    *)
      printf '200\n{"ok":true}' ;;
  esac
}

# The catalog the model sync scores against; a fixture so the suite does not
# depend on files/model-router/benchmarks.json.
CATALOG_FIXTURE="$TMPROOT/catalog.json"
printf '{"candidates":[]}\n' > "$CATALOG_FIXTURE"
afk_router_catalog_path() { printf '%s\n' "$CATALOG_FIXTURE"; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# new_case <name>: a fresh sandbox with its own registry, skills store and
# Paperclip fixtures.
new_case() {
  CASE="$TMPROOT/cases/$1"
  PC_DIR="$CASE/pc"
  PC_LOG="$CASE/pc.log"
  PC_CFG_FILE="$CASE/no-paperclip.json"
  mkdir -p "$CASE" "$PC_DIR/files" "$PC_DIR/agents"
  : > "$PC_LOG"
  export AFK_TOOLING_REGISTRY_FILE="$CASE/tooling.json"
  export AFK_PAPERCLIP_SKILLS_DIR="$CASE/skills-store"
  export AFK_DISCOVERED_MODELS_FILE="$CASE/discovered-models.json"
}

file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || printf 'missing'; }

new_git_repo() { # <dir>
  mkdir -p "$1"
  git -C "$1" init -q
  git -C "$1" config user.name "AFK Test"
  git -C "$1" config user.email "test@example.invalid"
  printf 'hello\n' > "$1/README.md"
  git -C "$1" add README.md
  git -C "$1" commit -q -m "init"
}

pc_skill_file() { # <skill id> <path> <content>
  mkdir -p "$PC_DIR/files/$1"
  printf '%s\n' "$3" > "$PC_DIR/files/$1/$2"
}

# write_registry <servers_json> <central_json|null> [<skills_json>]
write_registry() {
  local skills_json="${3:-}"
  [[ -n "$skills_json" ]] || skills_json='{}'
  jq -n --argjson srv "$1" --argjson pc "$2" --argjson sk "$skills_json" '{
    schema: "afk-tooling-registry/1",
    default_mcp_mode: "standalone",
    litellm_mcp_url: null,
    mcp_servers: $srv,
    skills: $sk,
    paperclip_central: $pc
  }' > "$AFK_TOOLING_REGISTRY_FILE"
}

PG_SERVER='{"pg":{"name":"pg","transport":"stdio","command":"pg-cmd","args":[],"source":"local"}}'
PG_CENTRAL='{"synced_epoch":1,"mcp_mode":"standalone","enabled_mcp":["pg"],"enabled_skills":[],"desired_skills":[],"agent_desired_skills":{}}'

run_sync() { afk_tooling_sync_paperclip_skills "https://pc.test" "test-key" "co-1" "agent-host"; }

# Model sync with every source pinned to a fixture or to nothing. A test adds
# or overrides variables in front of the call.
sync_models_offline() {
  AFK_OPENCODE_MODELS_FIXTURE="${AFK_OPENCODE_MODELS_FIXTURE:-$CASE/no-opencode-models.txt}" \
  AFK_AGY_MODELS_FIXTURE="${AFK_AGY_MODELS_FIXTURE:-$CASE/no-agy-models.txt}" \
  AFK_CODEX_AUTH_FILE="${AFK_CODEX_AUTH_FILE:-$CASE/no-codex-auth.json}" \
  AFK_OPENCODE_AUTH_FILE="${AFK_OPENCODE_AUTH_FILE:-$CASE/no-opencode-auth.json}" \
  AFK_PI_AUTH_FILE="${AFK_PI_AUTH_FILE:-$CASE/no-pi-auth.json}" \
  AFK_CLAUDE_CREDS_FILE="${AFK_CLAUDE_CREDS_FILE:-$CASE/no-claude-creds.json}" \
    afk_harness_sync_models
}

# ===========================================================================
head1 "T1. The registry is never saved or read as anything but a JSON object"
# ===========================================================================

new_case t1-string-server
write_registry '{"keep":{"name":"keep","transport":"stdio","command":"keep-cmd","args":[],"source":"local"}}' \
  '{"synced_epoch":1,"mcp_mode":"standalone","enabled_mcp":["keep"],"enabled_skills":[],"desired_skills":[],"agent_desired_skills":{}}'
cat > "$PC_DIR/skills.json" <<'JSON'
[{"id":"s1","slug":"afk-fleet-tooling","key":"company/co-1/afk-fleet-tooling","fileInventory":[{"path":"SKILL.md"},{"path":"mcp.json"}]}]
JSON
pc_skill_file s1 SKILL.md '# Fleet tooling'
pc_skill_file s1 mcp.json '{"mcpServers":{"github":"npx github-mcp"}}'
T1_OUT="$(run_sync 2>/dev/null)"; T1_RC=$?
assert_eq "A Studio mcp.json whose server is a string fails the sync and leaves the previous registry in place" \
  "$T1_RC:$(jq -r '.ok' <<<"$T1_OUT" 2>/dev/null):$(jq -r '.paperclip_central.enabled_mcp | join(",")' "$AFK_TOOLING_REGISTRY_FILE" 2>/dev/null):$(jq -r '.mcp_servers.keep.command' "$AFK_TOOLING_REGISTRY_FILE" 2>/dev/null)" \
  "1:false:keep:keep-cmd"

new_case t1-save-refuses
write_registry '{"keep":{"name":"keep","transport":"stdio","command":"keep-cmd","args":[],"source":"local"}}' null
afk_tooling_save_registry "" 2>/dev/null; T1_RC_EMPTY=$?
afk_tooling_save_registry '["not","an","object"]' 2>/dev/null; T1_RC_ARRAY=$?
assert_eq "Saving empty or non-object content is refused and the registry file is kept" \
  "$T1_RC_EMPTY:$T1_RC_ARRAY:$(jq -r '.mcp_servers | keys | join(",")' "$AFK_TOOLING_REGISTRY_FILE" 2>/dev/null)" \
  "1:1:keep"

new_case t1-load-fallback
printf '\n' > "$AFK_TOOLING_REGISTRY_FILE"
assert_eq "A registry file that holds no JSON object is read as the empty default registry" \
  "$(afk_tooling_load_registry 2>/dev/null | jq -r '"\(.schema):\(.mcp_servers | length):\(.paperclip_central)"' 2>/dev/null)" \
  "afk-tooling-registry/1:0:null"

afk_tooling_register_mcp pg stdio pg-cmd >/dev/null 2>&1
assert_eq "Registering a server repairs a damaged registry file" \
  "$(jq -r '.mcp_servers.pg.command' "$AFK_TOOLING_REGISTRY_FILE" 2>/dev/null)" \
  "pg-cmd"

# ===========================================================================
head1 "T2. A sync that stops part way changes nothing, and files removed upstream leave the store"
# ===========================================================================

new_case t2-bundle-removed
cat > "$PC_DIR/skills.json" <<'JSON'
[{"id":"g1","slug":"gateway","key":"company/co-1/gateway","fileInventory":[{"path":"SKILL.md"},{"path":"tooling.json"},{"path":"docs/old.md"}]}]
JSON
pc_skill_file g1 SKILL.md '# Gateway'
pc_skill_file g1 tooling.json '{"mcpServers":{"gh":{"command":"gh-mcp"}}}'
# The stub serves a file by its URL-encoded path.
pc_skill_file g1 'docs%2Fold.md' 'old notes'
run_sync >/dev/null 2>&1; T2_RC1=$?
T2_HAD="$([[ -f "$AFK_PAPERCLIP_SKILLS_DIR/gateway/docs/old.md" ]] && echo had-notes || echo no-notes)"
pc_skill_file g1 tooling.json '{"mcpServers":{"gh":"npx gh-mcp"}}'
run_sync >/dev/null 2>&1; T2_RC2=$?
# Upstream drops the broken file and the notes from the skill.
printf '[{"id":"g1","slug":"gateway","key":"company/co-1/gateway","fileInventory":[{"path":"SKILL.md"}]}]\n' > "$PC_DIR/skills.json"
rm -f "$PC_DIR/files/g1/tooling.json" "$PC_DIR/files/g1/docs%2Fold.md"
T2_OUT="$(run_sync 2>/dev/null)"; T2_RC3=$?
assert_eq "Once Studio removes a broken tooling file the next sync succeeds, and the store keeps only the files Studio still lists" \
  "$T2_RC1:$T2_HAD:$T2_RC2:$T2_RC3:$(jq -r '.ok' <<<"$T2_OUT" 2>/dev/null):$(cd "$AFK_PAPERCLIP_SKILLS_DIR/gateway" 2>/dev/null && find . -type f | sort | tr '\n' ',')" \
  "0:had-notes:1:0:true:./SKILL.md,"

new_case t2-abort-untouched
cat > "$PC_DIR/skills.json" <<'JSON'
[
  {"id":"b1","slug":"agentmail","key":"paperclipai/paperclip/agentmail","folderPath":"bundled/paperclip-core","sourceLabel":"Paperclip bundled","fileInventory":[{"path":"SKILL.md"}]},
  {"id":"s2","slug":"notes","key":"company/co-1/notes","fileInventory":[{"path":"SKILL.md"}]}
]
JSON
pc_skill_file b1 SKILL.md '# Agentmail'
pc_skill_file s2 SKILL.md '# Notes v1'
printf '{"desiredSkills":["paperclipai/paperclip/agentmail"]}' > "$PC_DIR/agents/agent-host.body"
run_sync >/dev/null 2>&1
cp "$AFK_TOOLING_REGISTRY_FILE" "$CASE/registry-before.json"
# Next round: agentmail is detached, notes changes, a new skill appears, and
# the fleet bundle is broken, so the sync has to stop.
printf '{"desiredSkills":[]}' > "$PC_DIR/agents/agent-host.body"
pc_skill_file s2 SKILL.md '# Notes v2'
cat > "$PC_DIR/skills.json" <<'JSON'
[
  {"id":"b1","slug":"agentmail","key":"paperclipai/paperclip/agentmail","folderPath":"bundled/paperclip-core","sourceLabel":"Paperclip bundled","fileInventory":[{"path":"SKILL.md"}]},
  {"id":"s2","slug":"notes","key":"company/co-1/notes","fileInventory":[{"path":"SKILL.md"}]},
  {"id":"s3","slug":"fresh","key":"company/co-1/fresh","fileInventory":[{"path":"SKILL.md"}]},
  {"id":"f1","slug":"afk-fleet-tooling","key":"company/co-1/afk-fleet-tooling","fileInventory":[{"path":"SKILL.md"},{"path":"mcp.json"}]}
]
JSON
pc_skill_file s3 SKILL.md '# Fresh'
pc_skill_file f1 SKILL.md '# Fleet'
pc_skill_file f1 mcp.json '{"mcpServers":{"gh":"npx gh-mcp"}}'
run_sync >/dev/null 2>"$CASE/abort.err"; T2A_RC=$?
assert_eq "A sync stopped by a broken bundle leaves the skills store and the registry exactly as they were, and says so" \
  "$T2A_RC:$(cat "$AFK_PAPERCLIP_SKILLS_DIR/notes/SKILL.md" 2>/dev/null):$([[ -f "$AFK_PAPERCLIP_SKILLS_DIR/agentmail/SKILL.md" ]] && echo agentmail-kept || echo agentmail-gone):$([[ -e "$AFK_PAPERCLIP_SKILLS_DIR/fresh" ]] && echo fresh-written || echo fresh-absent):$(cmp -s "$AFK_TOOLING_REGISTRY_FILE" "$CASE/registry-before.json" && echo registry-same || echo registry-changed):$(grep -c 'were not changed' "$CASE/abort.err" 2>/dev/null || true)" \
  "1:# Notes v1:agentmail-kept:fresh-absent:registry-same:1"

# ===========================================================================
head1 "T3. A failed agent-skills lookup aborts the sync"
# ===========================================================================

new_case t3-host-agent
cat > "$PC_DIR/skills.json" <<'JSON'
[
  {"id":"b1","slug":"agentmail","key":"paperclipai/paperclip/agentmail","folderPath":"bundled/paperclip-core","sourceLabel":"Paperclip bundled","fileInventory":[{"path":"SKILL.md"}]},
  {"id":"s2","slug":"notes","key":"company/co-1/notes","fileInventory":[{"path":"SKILL.md"}]}
]
JSON
pc_skill_file b1 SKILL.md '# Agentmail'
pc_skill_file s2 SKILL.md '# Notes'
printf '{"desiredSkills":["paperclipai/paperclip/agentmail"],"desiredSkillEntries":[{"slug":"agentmail"}]}' > "$PC_DIR/agents/agent-host.body"
run_sync >/dev/null 2>&1
# Age the snapshot so "unchanged" is visible even within the same second.
jq '.paperclip_central.synced_epoch = 1' "$AFK_TOOLING_REGISTRY_FILE" > "$CASE/aged.json" && mv "$CASE/aged.json" "$AFK_TOOLING_REGISTRY_FILE"
printf '503' > "$PC_DIR/agents/agent-host.code"
printf '{"error":"unavailable"}' > "$PC_DIR/agents/agent-host.body"
T3_OUT="$(run_sync 2>/dev/null)"; T3_RC=$?
assert_eq "A failed host agent-skills request aborts the sync and keeps the desired bundled skill and the previous snapshot" \
  "$T3_RC:$(jq -r '.ok' <<<"$T3_OUT" 2>/dev/null):$([[ -f "$AFK_PAPERCLIP_SKILLS_DIR/agentmail/SKILL.md" ]] && echo kept || echo deleted):$(jq -r '"\(.paperclip_central.synced_epoch):\(.paperclip_central.desired_skills | join(","))"' "$AFK_TOOLING_REGISTRY_FILE" 2>/dev/null)" \
  "1:false:kept:1:agentmail"

new_case t3-project-agent
cat > "$PC_DIR/skills.json" <<'JSON'
[{"id":"s2","slug":"notes","key":"company/co-1/notes","fileInventory":[{"path":"SKILL.md"}]}]
JSON
pc_skill_file s2 SKILL.md '# Notes'
# The shape lib/afk-paperclip-hire.sh writes: lifecycle in `state`.
printf '{"projects":{"demo":{"agents":{"dev":{"name":"demo-dev","role":"dev","state":"active","agent_id":"agent-proj"}}}}}' > "$PC_DIR/ledger.json"
printf '{"desiredSkills":["company/co-1/notes"]}' > "$PC_DIR/agents/agent-proj.body"
run_sync >/dev/null 2>&1
jq '.paperclip_central.synced_epoch = 1' "$AFK_TOOLING_REGISTRY_FILE" > "$CASE/aged.json" && mv "$CASE/aged.json" "$AFK_TOOLING_REGISTRY_FILE"
printf '500' > "$PC_DIR/agents/agent-proj.code"
T3P_OUT="$(run_sync 2>/dev/null)"; T3P_RC=$?
assert_eq "A failed project agent-skills request aborts the sync and keeps that agent's desired skills" \
  "$T3P_RC:$(jq -r '.ok' <<<"$T3P_OUT" 2>/dev/null):$(jq -r '"\(.paperclip_central.synced_epoch):\(.paperclip_central.agent_desired_skills.demo | join(","))"' "$AFK_TOOLING_REGISTRY_FILE" 2>/dev/null)" \
  "1:false:1:notes"

new_case t3-agent-states
cat > "$PC_DIR/skills.json" <<'JSON'
[
  {"id":"s2","slug":"notes","key":"company/co-1/notes","fileInventory":[{"path":"SKILL.md"}]},
  {"id":"s3","slug":"docs","key":"company/co-1/docs","fileInventory":[{"path":"SKILL.md"}]}
]
JSON
pc_skill_file s2 SKILL.md '# Notes'
pc_skill_file s3 SKILL.md '# Docs'
cat > "$PC_DIR/ledger.json" <<'JSON'
{"projects":{"demo":{"agents":{
  "dev":    {"state":"active",       "agent_id":"agent-active"},
  "qa":     {"state":"idle",         "agent_id":"agent-idle"},
  "ux":     {"state":"paused",       "agent_id":"agent-paused"},
  "arch":   {"state":"terminated",   "agent_id":"agent-terminated"},
  "sec":    {"state":"active_local", "agent_id":"local-demo-sec"},
  "ops":    {"state":"active",       "agent_id":"agent-gone"}
}}}}
JSON
printf '{"desiredSkills":["company/co-1/notes"]}' > "$PC_DIR/agents/agent-active.body"
printf '{"desiredSkills":["company/co-1/docs"]}' > "$PC_DIR/agents/agent-idle.body"
printf '404' > "$PC_DIR/agents/agent-gone.code"
printf '{"error":"not found"}' > "$PC_DIR/agents/agent-gone.body"
T3S_OUT="$(run_sync 2>/dev/null)"; T3S_RC=$?
T3S_ASKED="$(sed -n 's#^GET .*/api/agents/\([^/]*\)/skills .*#\1#p' "$PC_LOG" | grep -vx 'agent-host' | sort | tr '\n' ',')"
assert_eq "Skills are fetched for active and idle project agents only, and an agent Paperclip answers 404 for counts as having none" \
  "$T3S_RC:$(jq -r '.ok' <<<"$T3S_OUT" 2>/dev/null):$T3S_ASKED:$(jq -r '.paperclip_central.agent_desired_skills.demo | sort | join(",")' "$AFK_TOOLING_REGISTRY_FILE" 2>/dev/null)" \
  "0:true:agent-active,agent-gone,agent-idle,:docs,notes"

# ===========================================================================
head1 "T4. Concurrent jobs of one process do not corrupt shared files"
# ===========================================================================

new_case t4-registry-race
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  ( afk_tooling_register_mcp "srv$i" stdio "cmd$i" >/dev/null 2>&1 ) &
done
wait
assert_eq "Twelve registrations started at once from one process all land in the registry and leave no temp or lock behind" \
  "$(jq -r '.mcp_servers | length' "$AFK_TOOLING_REGISTRY_FILE" 2>/dev/null):$(find "$CASE" -maxdepth 1 -name 'tooling.json.*' | wc -l | tr -d '[:space:]')" \
  "12:0"

new_case t4-lock-held
mkdir "$AFK_TOOLING_REGISTRY_FILE.afk-lock"
( afk_tooling_register_mcp held stdio held-cmd >/dev/null 2>&1 ) &
T4_PID=$!
sleep 1
T4_WHILE_HELD="$(jq -r '.mcp_servers.held.command // "absent"' "$AFK_TOOLING_REGISTRY_FILE" 2>/dev/null || true)"
rmdir "$AFK_TOOLING_REGISTRY_FILE.afk-lock"
wait "$T4_PID"
assert_eq "A registry update waits while another job holds the lock and completes once it is released" \
  "${T4_WHILE_HELD:-absent}:$(jq -r '.mcp_servers.held.command // "absent"' "$AFK_TOOLING_REGISTRY_FILE" 2>/dev/null)" \
  "absent:held-cmd"

new_case t4-lock-stale
mkdir "$AFK_TOOLING_REGISTRY_FILE.afk-lock"
touch -t 202001010000 "$AFK_TOOLING_REGISTRY_FILE.afk-lock"
AFK_TOOLING_LOCK_WAIT_SEC=5 afk_tooling_register_mcp late stdio late-cmd >/dev/null 2>&1
assert_eq "A lock left behind by a dead job is taken over and released" \
  "$(jq -r '.mcp_servers.late.command // "absent"' "$AFK_TOOLING_REGISTRY_FILE" 2>/dev/null):$([[ -e "$AFK_TOOLING_REGISTRY_FILE.afk-lock" ]] && echo lock-left || echo lock-gone)" \
  "late-cmd:lock-gone"

new_case t4-lock-orphan-waiters
# Several waiters find the same dead lock at the same moment. Each holder
# marks itself inside, looks for anyone else, holds briefly and looks again.
# One round lets the old takeover through about half the time; four rounds
# of five waiters make a pass on that code unlikely.
T4_LOCK="$CASE/shared.afk-lock"
mkdir -p "$CASE/inside"
: > "$CASE/overlaps"
: > "$CASE/entries"
for t4_round in 1 2 3 4; do
  mkdir "$T4_LOCK"
  touch -t 202001010000 "$T4_LOCK"
  rm -f "$CASE/go"
  for t4_w in 1 2 3 4 5; do
    (
      while [[ ! -e "$CASE/go" ]]; do sleep 0.01; done
      if _afk_tooling_lock "$T4_LOCK"; then
        : > "$CASE/inside/$BASHPID"
        t4_n1="$(find "$CASE/inside" -type f | wc -l | tr -d '[:space:]')"
        sleep 0.05
        t4_n2="$(find "$CASE/inside" -type f | wc -l | tr -d '[:space:]')"
        rm -f "$CASE/inside/$BASHPID"
        if (( t4_n1 > 1 || t4_n2 > 1 )); then printf 'round %s waiter %s\n' "$t4_round" "$t4_w" >> "$CASE/overlaps"; fi
        printf 'in\n' >> "$CASE/entries"
        _afk_tooling_unlock "$T4_LOCK"
      fi
    ) &
  done
  sleep 0.2
  : > "$CASE/go"
  wait
done
assert_eq "Five jobs that find a dead job's lock at once take it over one at a time, all of them get in, and no lock is left" \
  "$(wc -l < "$CASE/overlaps" | tr -d '[:space:]') overlaps:$(wc -l < "$CASE/entries" | tr -d '[:space:]') entries:$([[ -e "$T4_LOCK" || -e "$T4_LOCK.reap" ]] && echo lock-left || echo lock-gone)" \
  "0 overlaps:20 entries:lock-gone"

new_case t4-lock-future
mkdir "$AFK_TOOLING_REGISTRY_FILE.afk-lock"
touch -t 209901010000 "$AFK_TOOLING_REGISTRY_FILE.afk-lock"
T4_START="$(date +%s)"
AFK_TOOLING_LOCK_WAIT_SEC=4 afk_tooling_register_mcp soon stdio soon-cmd >/dev/null 2>&1; T4_FUTURE_RC=$?
T4_ELAPSED=$(( $(date +%s) - T4_START ))
assert_eq "A lock dated in the future is taken over at once instead of costing the full wait" \
  "$T4_FUTURE_RC:$(jq -r '.mcp_servers.soon.command // "absent"' "$AFK_TOOLING_REGISTRY_FILE" 2>/dev/null):$( (( T4_ELAPSED < 3 )) && echo quick || echo "waited-${T4_ELAPSED}s")" \
  "0:soon-cmd:quick"

new_case t4-lock-owner
T4_LOCK="$CASE/own.afk-lock"
_afk_tooling_lock "$T4_LOCK"
# This holder runs past the stale age, and another job takes the lock over
# and is still inside when the first one finishes.
touch -t 202001010000 "$T4_LOCK"
( _afk_tooling_lock "$T4_LOCK" )
_afk_tooling_unlock "$T4_LOCK"
assert_eq "A holder whose lock was taken over as stale does not release the new holder's lock" \
  "$([[ -d "$T4_LOCK" ]] && echo still-held || echo released)" \
  "still-held"

new_case t4-lock-timeout
write_registry '{}' null
mkdir "$AFK_TOOLING_REGISTRY_FILE.afk-lock"
AFK_TOOLING_LOCK_WAIT_SEC=1 afk_tooling_register_mcp blocked stdio blocked-cmd >/dev/null 2>&1; T4_TIMEOUT_RC=$?
rmdir "$AFK_TOOLING_REGISTRY_FILE.afk-lock" 2>/dev/null
assert_eq "A registry update that cannot get the lock within the bounded wait fails without writing" \
  "$T4_TIMEOUT_RC:$(jq -r '.mcp_servers.blocked.command // "absent"' "$AFK_TOOLING_REGISTRY_FILE" 2>/dev/null)" \
  "1:absent"

new_case t4-exclude-race
T4_REPO="$CASE/repo"
new_git_repo "$T4_REPO"
printf 'user-notes/\n' >> "$T4_REPO/.git/info/exclude"
write_registry "$PG_SERVER" "$PG_CENTRAL"
T4_JOBS="1 2 3 4 5 6 7 8"
for i in $T4_JOBS; do
  git -C "$T4_REPO" worktree add -q -b "job-$i" "$CASE/wt-$i" >/dev/null 2>&1
  mkdir -p "$CASE/jobs/job-$i"
done
# The lock is held while all eight start, so they reach the shared file
# together the moment it is released. Left to chance the old code lost blocks
# in most runs but not all; holding the lock makes the outcome the same every
# time.
mkdir "$T4_REPO/.git/info/exclude.afk-lock"
for i in $T4_JOBS; do
  ( afk_tooling_prepare_worktree "$T4_REPO" "$CASE/wt-$i" "$CASE/jobs/job-$i" >/dev/null 2>&1 ) &
done
sleep 1.5
T4_WHILE_HELD="$(grep -c 'AFK-EPHEMERAL' "$T4_REPO/.git/info/exclude" || true)"
rmdir "$T4_REPO/.git/info/exclude.afk-lock"
wait
T4_COMPLETE=0
for i in $T4_JOBS; do
  if [[ "$(grep -cxF "# BEGIN AFK-EPHEMERAL:job-$i" "$T4_REPO/.git/info/exclude")" == "1" \
     && "$(grep -cxF "# END AFK-EPHEMERAL:job-$i" "$T4_REPO/.git/info/exclude")" == "1" ]]; then
    T4_COMPLETE=$((T4_COMPLETE + 1))
  fi
done
assert_eq "Eight worktrees prepared at once wait for the exclude lock, then each keeps its ignore block and the user's own line survives" \
  "held-$T4_WHILE_HELD:$T4_COMPLETE:$(grep -cxF 'user-notes/' "$T4_REPO/.git/info/exclude"):$(find "$T4_REPO/.git/info" -name 'exclude.*' | wc -l | tr -d '[:space:]')" \
  "held-0:8:1:0"

# ===========================================================================
head1 "T5. A skill slug cannot name a directory outside the skills store"
# ===========================================================================

new_case t5-dot-slugs
cat > "$PC_DIR/skills.json" <<'JSON'
[
  {"id":"evil","slug":"..","key":"company/co-1/evil","fileInventory":[{"path":"SKILL.md"},{"path":"sentinel.json"}]},
  {"id":"dot","slug":".hidden","key":"company/co-1/hidden","fileInventory":[{"path":"SKILL.md"}]},
  {"id":"s2","slug":"notes","key":"company/co-1/notes","fileInventory":[{"path":"SKILL.md"}]}
]
JSON
pc_skill_file evil SKILL.md '# Evil'
pc_skill_file evil sentinel.json 'OVERWRITTEN'
pc_skill_file dot SKILL.md '# Hidden'
pc_skill_file s2 SKILL.md '# Notes'
printf 'ORIGINAL\n' > "$CASE/sentinel.json"
T5_OUT="$(run_sync 2>/dev/null)"
assert_eq "A Studio skill with slug .. or a leading dot is skipped and writes nothing outside the skills store" \
  "$(cat "$CASE/sentinel.json"):$([[ -e "$CASE/SKILL.md" ]] && echo escaped || echo contained):$([[ -e "$AFK_PAPERCLIP_SKILLS_DIR/.hidden" ]] && echo dot-dir || echo no-dot-dir):$(jq -r '[.synced_skills[].slug] | join(",")' <<<"$T5_OUT" 2>/dev/null)" \
  "ORIGINAL:contained:no-dot-dir:notes"

# ===========================================================================
head1 "T6. Files that can hold MCP credentials are private, and logs carry no URL secrets"
# ===========================================================================

new_case t6-registry-mode
afk_tooling_register_mcp pg stdio pg-cmd >/dev/null 2>&1
assert_eq "The registry file is readable by its owner only" \
  "$(file_mode "$AFK_TOOLING_REGISTRY_FILE")" \
  "600"

new_case t6-worktree-modes
mkdir -p "$CASE/wt" "$CASE/job"
write_registry '{"prom":{"name":"prom","transport":"http","url":"https://prom.example.test/mcp","headers":{"Authorization":"Bearer t0ken"},"source":"paperclip"}}' \
  '{"synced_epoch":1,"mcp_mode":"standalone","enabled_mcp":["prom"],"enabled_skills":[],"desired_skills":[],"agent_desired_skills":{}}'
afk_tooling_prepare_worktree "$CASE/wt" "$CASE/wt" "$CASE/job" >/dev/null 2>&1
assert_eq "The job's .mcp.json and opencode.json are readable by their owner only" \
  "$(file_mode "$CASE/wt/.mcp.json"):$(file_mode "$CASE/wt/opencode.json")" \
  "600:600"

new_case t6-store-modes
cat > "$PC_DIR/skills.json" <<'JSON'
[{"id":"f1","slug":"afk-fleet-tooling","key":"company/co-1/afk-fleet-tooling","fileInventory":[{"path":"SKILL.md"},{"path":"mcp.json"}]}]
JSON
pc_skill_file f1 SKILL.md '# Fleet'
pc_skill_file f1 mcp.json '{"enabled_skills":["afk-fleet-tooling"],"mcpServers":{"prom":{"url":"https://prom.example.test/mcp","headers":{"Authorization":"Bearer t0ken"}}}}'
run_sync >/dev/null 2>&1
mkdir -p "$CASE/wt" "$CASE/job"
afk_tooling_prepare_worktree "$CASE/wt" "$CASE/wt" "$CASE/job" >/dev/null 2>&1
assert_eq "A Studio bundle file with MCP headers is owner-only in the skills store and in the job's copy of the skill" \
  "$(file_mode "$AFK_PAPERCLIP_SKILLS_DIR/afk-fleet-tooling/mcp.json"):$(file_mode "$CASE/wt/.agents/skills/afk-fleet-tooling/mcp.json")" \
  "600:600"

new_case t6-killed-write
new_git_repo "$CASE/repo"
git -C "$CASE/repo" worktree add -q -b job-k "$CASE/wt" >/dev/null 2>&1
mkdir -p "$CASE/job"
write_registry '{"prom":{"name":"prom","transport":"http","url":"https://prom.example.test/mcp","headers":{"Authorization":"Bearer t0ken"},"source":"paperclip"}}' \
  '{"synced_epoch":1,"mcp_mode":"standalone","enabled_mcp":["prom"],"enabled_skills":[],"desired_skills":[],"agent_desired_skills":{}}'
# The job dies the moment its .mcp.json is about to be renamed into place:
# the first mv it runs kills it.
{ ( mv() { kill -9 "$BASHPID"; }; afk_tooling_prepare_worktree "$CASE/repo" "$CASE/wt" "$CASE/job" >/dev/null 2>&1 ); } 2>/dev/null
git -C "$CASE/wt" add -A >/dev/null 2>&1
assert_eq "A job killed while writing .mcp.json leaves nothing in its worktree for git add -A to commit" \
  "$(git -C "$CASE/wt" diff --cached --name-only | tr '\n' ',')" \
  ""

new_case t6-log-origin
mkdir -p "$CASE/wt" "$CASE/job"
write_registry '{"gw":{"name":"gw","transport":"http","url":"https://user:pw@mcp.example.test:8443/mcp?token=SECRET123","source":"paperclip"}}' \
  '{"synced_epoch":1,"mcp_mode":"standalone","enabled_mcp":["gw"],"enabled_skills":[],"desired_skills":[],"agent_desired_skills":{}}'
# The reachability probe calls `curl`, which is the failing stub on PATH.
AFK_FACTORY_LIVE_HARNESS=1 afk_tooling_prepare_worktree "$CASE/wt" "$CASE/wt" "$CASE/job" >/dev/null 2>&1
T6_LOG="$(cat "$CASE/job/tooling-warnings.log" 2>/dev/null || true)"
assert_eq "An unreachable MCP server is logged by scheme, host and port only" \
  "$([[ "$T6_LOG" == *"(https://mcp.example.test:8443)"* ]] && echo origin || echo no-origin):$([[ "$T6_LOG" == *SECRET123* || "$T6_LOG" == *"user:pw"* ]] && echo leaked || echo clean)" \
  "origin:clean"

# ===========================================================================
head1 "T7. A failing automatic sync is backed off and reported to the job"
# ===========================================================================

new_case t7-sync-backoff
PC_CFG_FILE="$CASE/paperclip.json"
printf '{"api_url":"https://pc.test","company_id":"co-1","host":{"agent_id":"agent-host","key_ref":"op://vault/item/key"}}\n' > "$PC_CFG_FILE"
printf '503' > "$PC_DIR/agents/agent-host.code"
printf '{"error":"unavailable"}' > "$PC_DIR/agents/agent-host.body"
mkdir -p "$CASE/wt" "$CASE/job-1" "$CASE/job-2" "$CASE/job-3"
afk_tooling_prepare_worktree "$CASE/wt" "$CASE/wt" "$CASE/job-1" >/dev/null 2>&1
afk_tooling_prepare_worktree "$CASE/wt" "$CASE/wt" "$CASE/job-2" >/dev/null 2>&1
T7_TRIES="$(grep -c '^GET .*/api/agents/agent-host/skills' "$PC_LOG" || true)"
AFK_TOOLING_RETRY_SEC=0 afk_tooling_prepare_worktree "$CASE/wt" "$CASE/wt" "$CASE/job-3" >/dev/null 2>&1
T7_TRIES_AFTER="$(grep -c '^GET .*/api/agents/agent-host/skills' "$PC_LOG" || true)"
assert_eq "A failed sync is not retried within AFK_TOOLING_RETRY_SEC, its error is recorded and written to each job's warnings, and it is retried after" \
  "$T7_TRIES:$(jq -r '.last_error // "none"' "$AFK_TOOLING_REGISTRY_FILE.sync-status.json" 2>/dev/null | cut -d: -f1):$(grep -c 'AGENT_SKILLS_HTTP_503' "$CASE/job-1/tooling-warnings.log" 2>/dev/null || true):$(grep -c 'AGENT_SKILLS_HTTP_503' "$CASE/job-2/tooling-warnings.log" 2>/dev/null || true):$T7_TRIES_AFTER" \
  "1:AGENT_SKILLS_HTTP_503:1:1:2"

# ===========================================================================
head1 "T8. A project .mcp.json that cannot be parsed is not truncated"
# ===========================================================================

new_case t8-commented-mcp-json
mkdir -p "$CASE/repo"
cat > "$CASE/repo/.mcp.json" <<'JSON'
{
  // my own servers
  "mcpServers": {"mine": {"command": "my-cmd"}}
}
JSON
cp "$CASE/repo/.mcp.json" "$CASE/mcp-before.json"
write_registry "$PG_SERVER" null
afk_tooling_sync_project "$CASE/repo" standalone pg >/dev/null 2>&1; T8_RC=$?
assert_eq "Syncing into a .mcp.json with a comment fails and leaves the file and the project config untouched" \
  "$T8_RC:$(cmp -s "$CASE/repo/.mcp.json" "$CASE/mcp-before.json" && echo untouched || echo changed):$([[ -e "$CASE/repo/.afk/config.json" ]] && echo config-written || echo config-absent)" \
  "1:untouched:config-absent"

# ===========================================================================
head1 "T9. A user's own skill directory is never replaced"
# ===========================================================================

new_case t9-user-skill
new_git_repo "$CASE/repo"
mkdir -p "$CASE/repo/.agents/skills/k8s-ops" "$CASE/repo/.agents/skills/managed" \
         "$CASE/central/k8s-ops" "$CASE/central/managed"
printf 'USER VERSION\n' > "$CASE/repo/.agents/skills/k8s-ops/SKILL.md"
printf 'OLD\n' > "$CASE/repo/.agents/skills/managed/SKILL.md"
printf 'managed-by=afk-tooling\n' > "$CASE/repo/.agents/skills/managed/.afk-managed-skill"
printf 'CENTRAL\n' > "$CASE/central/k8s-ops/SKILL.md"
printf 'NEW\n' > "$CASE/central/managed/SKILL.md"
afk_tooling_register_skill k8s-ops "$CASE/central/k8s-ops" >/dev/null 2>&1
afk_tooling_register_skill managed "$CASE/central/managed" >/dev/null 2>&1
afk_tooling_sync_project "$CASE/repo" "" "" "k8s-ops,managed" >/dev/null 2>"$CASE/sync.err"
assert_eq "An untracked user skill directory is kept, with a warning naming it, while a directory the kit manages is refreshed" \
  "$(cat "$CASE/repo/.agents/skills/k8s-ops/SKILL.md" 2>/dev/null):$(cat "$CASE/repo/.agents/skills/managed/SKILL.md" 2>/dev/null):$(grep -c '\.agents/skills/k8s-ops' "$CASE/sync.err" 2>/dev/null || true)" \
  "USER VERSION:NEW:1"

# ===========================================================================
head1 "T12. The shared info/exclude and the job's files are cleaned up without collateral damage"
# ===========================================================================

new_case t12-unterminated-cleanup
new_git_repo "$CASE/repo"
cat > "$CASE/repo/.git/info/exclude" <<'EXCL'
# user rules
user-a/
# BEGIN AFK-EPHEMERAL:job-x
/.mcp.json
user-b/
# BEGIN AFK-EPHEMERAL:job-y
/opencode.json
# END AFK-EPHEMERAL:job-y
user-c/
EXCL
mkdir -p "$CASE/jobs/job-x"
printf '.mcp.json\n' > "$CASE/jobs/job-x/.ephemeral-tooling-paths"
afk_tooling_cleanup_worktree "$CASE/repo" "$CASE/repo" "$CASE/jobs/job-x" >/dev/null 2>&1
assert_eq "Cleaning up a job whose block has no END marker keeps the user's lines and other jobs' blocks" \
  "$(tr '\n' '|' < "$CASE/repo/.git/info/exclude")" \
  "# user rules|user-a/|user-b/|# BEGIN AFK-EPHEMERAL:job-y|/opencode.json|# END AFK-EPHEMERAL:job-y|user-c/|"

new_case t12-unterminated-prepare
new_git_repo "$CASE/repo"
cat > "$CASE/repo/.git/info/exclude" <<'EXCL'
user-a/
# BEGIN AFK-EPHEMERAL:job-x
/.mcp.json
user-b/
EXCL
mkdir -p "$CASE/jobs/job-x"
write_registry "$PG_SERVER" "$PG_CENTRAL"
afk_tooling_prepare_worktree "$CASE/repo" "$CASE/repo" "$CASE/jobs/job-x" >/dev/null 2>&1
assert_eq "Preparing a job whose earlier block has no END marker rewrites the block without dropping the user's lines" \
  "$(tr '\n' '|' < "$CASE/repo/.git/info/exclude")" \
  "user-a/|user-b/|# BEGIN AFK-EPHEMERAL:job-x|/.mcp.json|/opencode.json|# END AFK-EPHEMERAL:job-x|"

new_case t12-worktree-cleanup
new_git_repo "$CASE/repo"
git -C "$CASE/repo" worktree add -q -b job-wt "$CASE/wt" >/dev/null 2>&1
mkdir -p "$CASE/jobs/job-wt" "$CASE/central/notes"
printf '# Notes\n' > "$CASE/central/notes/SKILL.md"
write_registry "$PG_SERVER" \
  '{"synced_epoch":1,"mcp_mode":"standalone","enabled_mcp":["pg"],"enabled_skills":["notes"],"desired_skills":[],"agent_desired_skills":{}}' \
  "$(jq -cn --arg p "$CASE/central/notes" '{notes: {name: "notes", path: $p, source: "paperclip"}}')"
afk_tooling_prepare_worktree "$CASE/repo" "$CASE/wt" "$CASE/jobs/job-wt" >/dev/null 2>&1
T12_MATERIALIZED="$([[ -f "$CASE/wt/.mcp.json" && -f "$CASE/wt/opencode.json" && -f "$CASE/wt/.agents/skills/notes/SKILL.md" ]] && echo materialized || echo missing)"
afk_tooling_cleanup_worktree "$CASE/repo" "$CASE/wt" "$CASE/jobs/job-wt" >/dev/null 2>&1
assert_eq "Cleaning up a job in its own worktree removes the files it materialized, so nothing is left for git add -A" \
  "$T12_MATERIALIZED:$([[ -e "$CASE/wt/.mcp.json" || -e "$CASE/wt/opencode.json" || -e "$CASE/wt/.agents/skills/notes" ]] && echo left || echo removed):$(git -C "$CASE/wt" status --porcelain | wc -l | tr -d '[:space:]'):$(grep -c 'AFK-EPHEMERAL' "$CASE/repo/.git/info/exclude" || true)" \
  "materialized:removed:0:0"

new_case t12-cleanup-bounds
new_git_repo "$CASE/repo"
mkdir -p "$CASE/jobs/job-b" "$CASE/elsewhere/skills/linked"
printf 'outside\n' > "$CASE/outside.txt"
printf 'SECRET=1\n' > "$CASE/repo/.env"
printf 'scratch\n' > "$CASE/repo/scratch.txt"
printf 'not yours\n' > "$CASE/elsewhere/skills/linked/SKILL.md"
ln -s "$CASE/elsewhere" "$CASE/repo/.agents"
printf '{}\n' > "$CASE/repo/.mcp.json"
# A damaged list: only .mcp.json is something the kit materializes, and the
# skill entry reaches outside the worktree through the .agents symlink.
printf 'README.md\n../outside.txt\n.git\n.env\nscratch.txt\n.agents/skills/linked\n.mcp.json\n' > "$CASE/jobs/job-b/.ephemeral-tooling-paths"
afk_tooling_cleanup_worktree "$CASE/repo" "$CASE/repo" "$CASE/jobs/job-b" >/dev/null 2>&1
assert_eq "Cleanup removes only the files the kit materializes, never through a symlink, and empties the list afterwards" \
  "$([[ -f "$CASE/repo/README.md" ]] && echo tracked-kept || echo tracked-deleted):$([[ -f "$CASE/outside.txt" ]] && echo outside-kept || echo outside-deleted):$([[ -d "$CASE/repo/.git" ]] && echo git-kept || echo git-deleted):$([[ -f "$CASE/repo/.env" ]] && echo env-kept || echo env-deleted):$([[ -f "$CASE/repo/scratch.txt" ]] && echo scratch-kept || echo scratch-deleted):$([[ -f "$CASE/elsewhere/skills/linked/SKILL.md" ]] && echo link-target-kept || echo link-target-deleted):$([[ -e "$CASE/repo/.mcp.json" ]] && echo mcp-left || echo mcp-removed):$([[ -s "$CASE/jobs/job-b/.ephemeral-tooling-paths" ]] && echo list-kept || echo list-empty)" \
  "tracked-kept:outside-kept:git-kept:env-kept:scratch-kept:link-target-kept:mcp-removed:list-empty"

# ===========================================================================
head1 "T18. Publishing does not replace the fleet configuration with an empty one"
# ===========================================================================

new_case t18-empty-publish
PC_CFG_FILE="$CASE/paperclip.json"
printf '{"api_url":"https://pc.test","company_id":"co-1","host":{"agent_id":"agent-host","key_ref":"op://vault/item/key"}}\n' > "$PC_CFG_FILE"
T18_OUT="$(afk_tooling_publish_paperclip 2>"$CASE/publish.err")"; T18_RC=$?
T18_WRITES="$(grep -cE '^(PATCH|POST) ' "$PC_LOG" || true)"
T18_FORCED="$(AFK_TOOLING_PUBLISH_FORCE=1 afk_tooling_publish_paperclip 2>/dev/null)"
T18_FORCED_PATCHES="$(grep -c '^PATCH .*"path":"mcp.json"' "$PC_LOG" || true)"
rm -f "$AFK_TOOLING_REGISTRY_FILE"
T18_EXPLICIT="$(afk_tooling_publish_paperclip litellm "http://gw.example.test:4000" "pg" "" 2>/dev/null)"
assert_eq "Publishing an empty local registry is refused with nothing sent, unless forced; explicit servers still publish" \
  "$T18_RC:$(jq -r '.error' <<<"$T18_OUT" 2>/dev/null):$T18_WRITES:$([[ -s "$CASE/publish.err" ]] && echo explained || echo silent)|$(jq -r '.ok' <<<"$T18_FORCED" 2>/dev/null):$T18_FORCED_PATCHES|$(jq -r '"\(.ok):\(.enabled_mcp | join(","))"' <<<"$T18_EXPLICIT" 2>/dev/null)" \
  "1:EMPTY_LOCAL_REGISTRY:0:explained|true:1|true:pg"

# ===========================================================================
head1 "T27. An empty or broken project config does not silently switch tooling off"
# ===========================================================================

new_case t27-prepare-empty-config
mkdir -p "$CASE/repo/.afk" "$CASE/job"
: > "$CASE/repo/.afk/config.json"
write_registry "$PG_SERVER" "$PG_CENTRAL"
afk_tooling_prepare_worktree "$CASE/repo" "$CASE/repo" "$CASE/job" >/dev/null 2>&1
afk_tooling_prepare_worktree "$CASE/repo" "$CASE/repo" "$CASE/job" >/dev/null 2>&1
assert_eq "A job whose project config is empty still gets the central MCP servers, and the ignored config is logged once" \
  "$(jq -r '.mcpServers.pg.command' "$CASE/repo/.mcp.json" 2>/dev/null):$(grep -c 'config.json' "$CASE/job/tooling-warnings.log" 2>/dev/null || true)" \
  "pg-cmd:1"

new_case t27-sync-empty-config
mkdir -p "$CASE/repo/.afk"
: > "$CASE/repo/.afk/config.json"
write_registry "$PG_SERVER" null
afk_tooling_sync_project "$CASE/repo" standalone pg >/dev/null 2>&1; T27_RC=$?
assert_eq "Syncing a project whose config file is empty writes a valid config" \
  "$T27_RC:$(jq -r '.tooling.enabled_mcp | join(",")' "$CASE/repo/.afk/config.json" 2>/dev/null)" \
  "0:pg"

new_case t27-sync-broken-config
mkdir -p "$CASE/repo/.afk"
printf '{"router": {"litellm_base_url": "http://keep.me"},}\n' > "$CASE/repo/.afk/config.json"
cp "$CASE/repo/.afk/config.json" "$CASE/config-before.json"
write_registry "$PG_SERVER" null
afk_tooling_sync_project "$CASE/repo" standalone pg >/dev/null 2>&1; T27_RC=$?
assert_eq "Syncing a project whose config has a syntax error fails and does not overwrite it" \
  "$T27_RC:$(cmp -s "$CASE/repo/.afk/config.json" "$CASE/config-before.json" && echo untouched || echo overwritten)" \
  "1:untouched"

# ===========================================================================
head1 "H2. Only an explicit zero price makes an OpenCode model free"
# ===========================================================================

new_case h2-cost-class
printf '{}\n' > "$CASE/opencode-auth.json"
cat > "$CASE/opencode-models.txt" <<'TXT'
opencode/free0
{"id":"free0","providerID":"opencode","status":"active","cost":{"input":0,"output":0}}
opencode/paid
{"id":"paid","providerID":"opencode","status":"active","cost":{"input":3,"output":15}}
opencode/nocost
{"id":"nocost","providerID":"opencode","status":"active"}
mystery/nocost
{"id":"nocost","providerID":"mystery","status":"active"}
TXT
H2_OUT="$(AFK_OPENCODE_AUTH_FILE="$CASE/opencode-auth.json" AFK_OPENCODE_MODELS_FIXTURE="$CASE/opencode-models.txt" sync_models_offline 2>/dev/null)"
h2_class() { jq -r --arg m "$1" '.models[] | select(.model == $m) | "\(.cost_class)/\(.entitlement_pool)/\(.is_free)"' <<<"$H2_OUT" 2>/dev/null; }
assert_eq "A priced model under the opencode provider is metered while a zero-priced one stays free" \
  "$(h2_class opencode/paid)|$(h2_class opencode/free0)" \
  "api-metered/api-metered/false|free/opencode-free/true"
assert_eq "A model with no listed price is metered, with or without an account binding for its provider" \
  "$(h2_class opencode/nocost)|$(h2_class mystery/nocost)" \
  "api-metered/api-metered/false|api-metered/api-metered/false"

# ===========================================================================
head1 "H7. A failed catalog build is reported, and one bad entry does not fail it"
# ===========================================================================

new_case h7-null-ids
cat > "$CASE/opencode-models.txt" <<'TXT'
{"providerID":"opencode","status":"active","cost":{"input":0,"output":0}}
{"id":"free0","providerID":"opencode","status":"active","cost":{"input":0,"output":0}}
TXT
printf '{"models":[{"name":"no id"},{"id":"grok-x"}]}\n' > "$CASE/grok-models.json"
printf '{"models":[{"display_name":"no slug"},{"slug":"gpt-x"}]}\n' > "$CASE/codex-models.json"
H7_OUT="$(AFK_OPENCODE_MODELS_FIXTURE="$CASE/opencode-models.txt" AFK_GROK_MODELS_FIXTURE="$CASE/grok-models.json" AFK_CODEX_MODELS_FIXTURE="$CASE/codex-models.json" sync_models_offline 2>/dev/null)"; H7_RC=$?
assert_eq "Model entries without an id are dropped and the rest of the catalog is written" \
  "$H7_RC:$(jq -r '[.models[].id] | sort | join(",")' <<<"$H7_OUT" 2>/dev/null)" \
  "0:codex:gpt-x,grok:grok-x,opencode:opencode/free0"

new_case h7-failed-build
printf '{"schema":"previous"}\n' > "$AFK_DISCOVERED_MODELS_FILE"
printf 'this is not json\n' > "$CASE/broken-catalog.json"
H7F_OUT="$(CATALOG_FIXTURE="$CASE/broken-catalog.json" sync_models_offline 2>/dev/null)"; H7F_RC=$?
assert_eq "A catalog build that fails returns an error, prints nothing, keeps the previous file and leaves no temp file" \
  "$H7F_RC:$([[ -z "$H7F_OUT" ]] && echo silent || echo printed):$(jq -r '.schema' "$AFK_DISCOVERED_MODELS_FILE" 2>/dev/null):$(find "$CASE" -maxdepth 1 -name 'discovered-models.json.*' | wc -l | tr -d '[:space:]')" \
  "1:silent:previous:0"

# ===========================================================================
head1 "H13. An unknown OAuth provider gets its own pool"
# ===========================================================================

new_case h13-oauth-pools
printf '{"github-copilot":{"type":"oauth"},"xai":{"type":"oauth"}}\n' > "$CASE/opencode-auth.json"
printf '{"zai":{"type":"oauth"}}\n' > "$CASE/pi-auth.json"
H13_BIND="$(AFK_OPENCODE_AUTH_FILE="$CASE/opencode-auth.json" AFK_PI_AUTH_FILE="$CASE/pi-auth.json" AFK_CODEX_AUTH_FILE="$CASE/none.json" AFK_CLAUDE_CREDS_FILE="$CASE/none.json" afk_harness_probe_account_bindings 2>/dev/null)"
assert_eq "OAuth logins for providers the kit does not know get per-provider pools, not the Grok pool" \
  "$(jq -r '[.[] | select(.auth_type == "oauth") | "\(.harness)/\(.provider)=\(.entitlement_pool)"] | sort | join(",")' <<<"$H13_BIND" 2>/dev/null)" \
  "opencode/github-copilot=github-copilot-oauth,opencode/xai=xai-grok,pi/zai=zai-oauth"

# ===========================================================================
head1 "H14. Codex signed in with an API key is metered"
# ===========================================================================

new_case h14-codex-auth
codex_binding() { # <auth file content>
  printf '%s\n' "$1" > "$CASE/codex-auth.json"
  AFK_CODEX_AUTH_FILE="$CASE/codex-auth.json" AFK_OPENCODE_AUTH_FILE="$CASE/none.json" AFK_PI_AUTH_FILE="$CASE/none.json" AFK_CLAUDE_CREDS_FILE="$CASE/none.json" \
    afk_harness_probe_account_bindings 2>/dev/null \
    | jq -r '.[] | select(.harness == "codex") | "\(.cost_class)/\(.entitlement_pool)"' 2>/dev/null
}
assert_eq "Codex with auth_mode apikey is metered while a ChatGPT login stays on the subscription pool" \
  "$(codex_binding '{"auth_mode":"apikey","OPENAI_API_KEY":"sk-test"}')|$(codex_binding '{"auth_mode":"chatgpt","tokens":{"access_token":"tok","account_id":"acct"}}')" \
  "api-metered/api-metered|subscription/openai-plus"
assert_eq "A Codex auth file that holds an API key and no OAuth tokens is metered" \
  "$(codex_binding '{"OPENAI_API_KEY":"sk-test","tokens":null}')" \
  "api-metered/api-metered"

# ===========================================================================
head1 "H15. agy's sign-in check is only that its state directory is not empty"
# ===========================================================================

new_case h15-agy-auth
agy_auth_state() { HOME="$1" afk_harness_inspect_auth_one agy true 2>/dev/null | jq -r '.auth_state'; }
mkdir -p "$CASE/home-missing" "$CASE/home-empty/.gemini/antigravity-cli" "$CASE/home-used/.gemini/antigravity-cli"
printf 'state\n' > "$CASE/home-used/.gemini/antigravity-cli/installation_id"
assert_eq "agy is signed out when its state directory is missing, even though the binary directory override is set" \
  "${AFK_HARNESS_BIN_DIR_OVERRIDE:+override-set}:$(agy_auth_state "$CASE/home-missing")" \
  "override-set:signed_out"
assert_eq "An empty agy directory counts as signed out, and a non-empty agy directory counts as installed and signed in" \
  "$(agy_auth_state "$CASE/home-empty"):$(agy_auth_state "$CASE/home-used")" \
  "signed_out:authenticated"

# ===========================================================================
head1 "H19. Updates run only for known harnesses, as argv, and can be switched off"
# ===========================================================================

# make_stub_harness <dir> <name>: a stand-in binary that records every call.
make_stub_harness() {
  mkdir -p "$1"
  cat > "$1/$2" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CASE/$2-calls.log"
if [[ "\${1:-}" == "--version" ]]; then echo "9.9.9"; fi
exit 0
SH
  chmod +x "$1/$2"
}

new_case h19-unknown-name
make_stub_harness "$CASE/bin" npm
H19_OUT="$(AFK_HARNESS_BIN_DIR_OVERRIDE="$CASE/bin" afk_harness_update npm false 2>/dev/null)"; H19_RC=$?
assert_eq "Updating a name that is not a harness is refused and nothing is looked up or run" \
  "$H19_RC:$(jq -r '.error' <<<"$H19_OUT" 2>/dev/null):$([[ -e "$CASE/npm-calls.log" ]] && echo ran || echo not-run)" \
  "1:UNKNOWN_HARNESS:not-run"

new_case h19-mixed-list
make_stub_harness "$CASE/bin" claude
make_stub_harness "$CASE/bin" npm
AFK_HARNESS_BIN_DIR_OVERRIDE="$CASE/bin" afk_harness_update "claude,npm" false >/dev/null 2>&1; H19_RC=$?
assert_eq "A list that mixes a harness with any other name is refused as a whole" \
  "$H19_RC:$([[ -e "$CASE/claude-calls.log" || -e "$CASE/npm-calls.log" ]] && echo ran || echo not-run)" \
  "1:not-run"

new_case h19-shell-in-path
H19_BIN="$CASE/bin\$(touch pwned)"
make_stub_harness "$H19_BIN" claude
mkdir -p "$CASE/cwd"
H19_OUT="$(cd "$CASE/cwd" && AFK_HARNESS_BIN_DIR_OVERRIDE="$H19_BIN" afk_harness_update claude false 2>/dev/null)"
assert_eq "Shell syntax in a harness path is passed as a plain argument, and the harness's own update still runs" \
  "$([[ -e "$CASE/cwd/pwned" ]] && echo executed || echo inert):$(grep -cx 'update' "$CASE/claude-calls.log" 2>/dev/null || true):$(jq -r '.results[0].action' <<<"$H19_OUT" 2>/dev/null)" \
  "inert:1:updated"

new_case h19-updates-off
make_stub_harness "$CASE/bin" claude
H19_OUT="$(AFK_HARNESS_UPDATES=off AFK_HARNESS_BIN_DIR_OVERRIDE="$CASE/bin" afk_harness_update claude false 2>"$CASE/update.err")"; H19_RC=$?
assert_eq "AFK_HARNESS_UPDATES=off refuses the update before any binary is touched and says why" \
  "$H19_RC:$(jq -r '.error' <<<"$H19_OUT" 2>/dev/null):$([[ -e "$CASE/claude-calls.log" ]] && echo touched || echo untouched):$(grep -c 'AFK_HARNESS_UPDATES' "$CASE/update.err" 2>/dev/null || true)" \
  "1:HARNESS_UPDATES_DISABLED:untouched:1"

new_case h19-argv-matches-display
H19_MISMATCH=0
H19_CHECKED=0
# <name>|<bin_path>|<resolved_path>
while IFS='|' read -r h_name h_bin h_resolved; do
  [[ -n "$h_name" ]] || continue
  h_origin="$(afk_harness_classify_origin "$h_name" "$h_bin" "$h_resolved")"
  AFK_HARNESS_UPDATE_ARGV=()
  _afk_harness_update_argv "$h_name" \
    "$(jq -r '.install_method' <<<"$h_origin")" \
    "$(jq -r '.package_name' <<<"$h_origin")" \
    "$(jq -r '.install_prefix // empty' <<<"$h_origin")" \
    "$h_bin" 2>/dev/null
  H19_CHECKED=$((H19_CHECKED + 1))
  # The displayed command quotes some words; without the quotes it must be
  # the argv, word for word.
  if [[ "$(jq -r '.update_command' <<<"$h_origin" | tr -d '"')" != "${AFK_HARNESS_UPDATE_ARGV[*]:-}" ]]; then
    H19_MISMATCH=$((H19_MISMATCH + 1))
  fi
done <<'CASES'
codex|/opt/homebrew/bin/codex|/opt/homebrew/Cellar/codex/0.167.1/bin/codex
codex|/home/user/.local/bin/codex|/home/user/.local/lib/node_modules/@openai/codex/bin/codex.js
codex|/usr/local/bin/codex|/usr/local/lib/node_modules/@openai/codex/bin/codex.js
pi|/Users/dev/.bun/bin/pi|/Users/dev/.bun/install/global/node_modules/@mariozechner/pi-coding-agent/dist/cli.js
claude|/home/user/.local/share/pnpm/claude|/home/user/.local/share/pnpm/global/5/node_modules/@anthropic-ai/claude-code/cli.js
pi|/home/user/.local/bin/pi|/home/user/.local/share/uv/tools/pi-agent/bin/pi
pi|/home/user/.local/bin/pi|/home/user/.local/pipx/venvs/pi-agent/bin/pi
grok|/home/user/.cargo/bin/grok|/home/user/.cargo/bin/grok
opencode|/Users/dev/.opencode/bin/opencode|/Users/dev/.opencode/bin/opencode
codex|/opt/tools/codex|/opt/tools/codex
claude|/opt/tools/claude|/opt/tools/claude
CASES
assert_eq "For every install method the command an update runs is the command the report shows" \
  "$H19_MISMATCH mismatches in $H19_CHECKED" \
  "0 mismatches in 11"

# ===========================================================================
head1 "H20. Overriding one harness's paths does not hide another harness"
# ===========================================================================

new_case h20-grok-binding
mkdir -p "$CASE/home/.grok"
printf '{"https://auth.x.ai::11111111-2222-4333-8444-555555555555":{"access_token":"redacted"}}\n' > "$CASE/home/.grok/auth.json"
grok_pool() { jq -r '[.[] | select(.harness == "grok") | .entitlement_pool] | join(",")' 2>/dev/null; }
assert_eq "A Grok login is still found when the binary directory override is set" \
  "${AFK_HARNESS_BIN_DIR_OVERRIDE:+override-set}:$(HOME="$CASE/home" AFK_CODEX_AUTH_FILE="$CASE/none.json" AFK_PI_AUTH_FILE="$CASE/none.json" AFK_CLAUDE_CREDS_FILE="$CASE/none.json" afk_harness_probe_account_bindings 2>/dev/null | grok_pool)" \
  "override-set:xai-grok"
# The override is emptied for this one call, which the library reads as not
# set. Probing bindings only looks binaries up (`command -v`); it runs none.
assert_eq "A Grok login is still found when only the OpenCode auth file is overridden" \
  "$(HOME="$CASE/home" AFK_HARNESS_BIN_DIR_OVERRIDE="" AFK_OPENCODE_AUTH_FILE="$CASE/none.json" AFK_CODEX_AUTH_FILE="$CASE/none.json" AFK_PI_AUTH_FILE="$CASE/none.json" AFK_CLAUDE_CREDS_FILE="$CASE/none.json" afk_harness_probe_account_bindings 2>/dev/null | grok_pool)" \
  "xai-grok"

new_case h20-model-caches
mkdir -p "$CASE/home/.grok" "$CASE/home/.codex"
printf '{"models":[{"id":"grok-cached"}]}\n' > "$CASE/home/.grok/models_cache.json"
printf '{"models":[{"slug":"gpt-cached"}]}\n' > "$CASE/home/.codex/models_cache.json"
: > "$CASE/opencode-models.txt"
H20_OUT="$(HOME="$CASE/home" AFK_OPENCODE_MODELS_FIXTURE="$CASE/opencode-models.txt" sync_models_offline 2>/dev/null)"
assert_eq "The Grok and Codex model caches are read when the binary directory override and the OpenCode fixture are set" \
  "${AFK_HARNESS_BIN_DIR_OVERRIDE:+override-set}:$(jq -r '[.models[].id] | sort | join(",")' <<<"$H20_OUT" 2>/dev/null)" \
  "override-set:codex:gpt-cached,grok:grok-cached"

new_case h20-live-grok
mkdir -p "$CASE/bin" "$CASE/home"
cat > "$CASE/bin/grok" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then echo "1.0.0"; exit 0; fi
if [[ "\${1:-}" == "models" ]]; then
  printf 'asked\n' >> "$CASE/grok-models-asked.log"
  printf '  - grok-live-model\n'
fi
exit 0
SH
chmod +x "$CASE/bin/grok"
H20_LIVE="$(HOME="$CASE/home" AFK_HARNESS_BIN_DIR_OVERRIDE="$CASE/bin" sync_models_offline 2>/dev/null)"
HOME="$CASE/home" AFK_HARNESS_BIN_DIR_OVERRIDE="$CASE/bin" AFK_GROK_MODELS_FIXTURE="$CASE/pinned-missing.json" sync_models_offline >/dev/null 2>&1
assert_eq "With no Grok cache the model list comes from the grok binary in the override directory, unless Grok's own fixture variable pins it" \
  "$(jq -r '[.models[] | select(.harness == "grok") | .model] | join(",")' <<<"$H20_LIVE" 2>/dev/null):asked-$(wc -l < "$CASE/grok-models-asked.log" 2>/dev/null | tr -d '[:space:]')" \
  "grok-live-model:asked-1"

# A guard, not a behaviour test: the stubs on PATH record every call, and a
# package manager must never have been reached, whatever code was under test.
if grep -qvE '^curl ' "$STUB_CALLS"; then
  bad "the suite stayed away from package managers" "$(grep -vE '^curl ' "$STUB_CALLS" | head -3 | tr '\n' ';')"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
