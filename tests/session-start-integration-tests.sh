#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2329 # generated fixtures and exported poison functions
set -uo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
if ! command -v jq >/dev/null || ! command -v yq >/dev/null || ! command -v node >/dev/null; then
  printf 'session-start-integration-tests: jq, yq, and node are required\n' >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$PASS" "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf 'not ok - %s\n' "$1"; }
assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then ok "$label"; else not_ok "$label (got=$actual expected=$expected)"; fi
}
assert_json_eq() {
  local label="$1" left="$2" right="$3"
  if diff -u <(jq -S . "$left") <(jq -S . "$right") >/dev/null; then ok "$label"; else not_ok "$label"; fi
}

SKILLS="$TMP/skills"; RUNTIME="$SKILLS/afk-runtime"; TRACE="$TMP/updater.trace"
mkdir -p "$RUNTIME/bin"
cp -R "$ROOT/adapters/." "$RUNTIME/"

write_updater() {
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "updater\n" >>"${AFK_TEST_TRACE:?}"' \
    'case "${AFK_TEST_UPDATER_MODE:-success}" in' \
    '  fail) printf "afk-session-start: retained last good; test failure\n" >&2; exit 3 ;;' \
    '  timeout) exec sleep 5 ;;' \
    'esac' \
    'while (( $# )); do' \
    '  if [[ "$1" == -- ]]; then shift; (( $# == 0 )) || exec "$@"; break; fi' \
    '  shift' \
    'done' \
    'printf "%s\n" '\''{"state":"CURRENT","last_good_verified":true}'\''' \
    >"$RUNTIME/bin/afk-session-start"
  chmod +x "$RUNTIME/bin/afk-session-start"
}
write_updater
: >"$TRACE"

# Direct execution of the production entrypoint is immune to PATH-selected
# Bash and BASH_ENV, while its separately validated launch PATH still resolves
# the user's relative harness and adapter-owned yq. Adapter management is bound
# to the installed sibling runtime, never an ambient AFK_SKILLS_HOME.
SECURE_SKILLS="$TMP/secure-skills"
SECURE_RUNTIME="$SECURE_SKILLS/afk-runtime"
SECURE_LAUNCH_BIN="$TMP/secure-launch-bin"
POISON_SKILLS="$TMP/poison-skills"
mkdir -p "$SECURE_RUNTIME/bin" "$SECURE_LAUNCH_BIN" \
  "$POISON_SKILLS/afk-runtime" "$TMP/secure-home"
cp "$ROOT/bin/afk-session-start" "$SECURE_RUNTIME/bin/afk-session-start"
cat >"$SECURE_RUNTIME/bin/afk-release-reconcile" <<'EOF'
#!/bin/bash -p
printf 'reconciled\n' >"$AFK_TEST_RECONCILE_MARKER"
printf '%s\n' '{"state":"CURRENT","last_good_verified":true}'
EOF
cat >"$SECURE_RUNTIME/manage.sh" <<'EOF'
#!/bin/bash -p
printf '%s\n' "$AFK_SKILLS_HOME" >"$AFK_TEST_SKILLS_ROOT_MARKER"
yq --version >/dev/null
printf 'managed\n' >"$AFK_TEST_MANAGE_MARKER"
EOF
cat >"$POISON_SKILLS/afk-runtime/manage.sh" <<'EOF'
#!/bin/bash -p
printf 'poisoned\n' >"$AFK_TEST_POISON_MANAGE_MARKER"
exit 99
EOF
cat >"$SECURE_LAUNCH_BIN/bash" <<'EOF'
#!/bin/bash -p
printf 'path-bash\n' >"$AFK_TEST_SESSION_POISON_MARKER"
exit 99
EOF
cat >"$SECURE_LAUNCH_BIN/yq" <<'EOF'
#!/bin/bash -p
printf 'relative-yq\n' >"$AFK_TEST_YQ_MARKER"
EOF
cat >"$SECURE_LAUNCH_BIN/codex" <<'EOF'
#!/bin/bash -p
printf 'relative-codex\n' >"$AFK_TEST_COMMAND_MARKER"
EOF
chmod +x "$SECURE_RUNTIME/bin/afk-session-start" \
  "$SECURE_RUNTIME/bin/afk-release-reconcile" "$SECURE_RUNTIME/manage.sh" \
  "$POISON_SKILLS/afk-runtime/manage.sh" "$SECURE_LAUNCH_BIN/"*
SESSION_BASH_ENV="$TMP/session-bash-env"
printf 'printf "bash-env\\n" >"$AFK_TEST_SESSION_POISON_MARKER"\n' >"$SESSION_BASH_ENV"
set +e
PATH="$TMP/missing-launch-entry:$SECURE_LAUNCH_BIN:/usr/bin:/bin" \
  BASH_ENV="$SESSION_BASH_ENV" \
  AFK_SKILLS_HOME="$POISON_SKILLS" HOME="$TMP/secure-home" \
  AFK_STATE_DIR="$TMP/secure-state" \
  AFK_TEST_RECONCILE_MARKER="$TMP/secure-reconciled" \
  AFK_TEST_SKILLS_ROOT_MARKER="$TMP/secure-skills-root" \
  AFK_TEST_MANAGE_MARKER="$TMP/secure-managed" \
  AFK_TEST_POISON_MANAGE_MARKER="$TMP/secure-poison-managed" \
  AFK_TEST_SESSION_POISON_MARKER="$TMP/secure-poisoned" \
  AFK_TEST_YQ_MARKER="$TMP/secure-yq" \
  AFK_TEST_COMMAND_MARKER="$TMP/secure-command" \
  "$SECURE_RUNTIME/bin/afk-session-start" --adapter codex -- codex \
  >"$TMP/secure-session.out" 2>"$TMP/secure-session.err"
SECURE_SESSION_RC=$?
set -e
assert_eq 'production session start preserves a validated relative launch command' \
  "$SECURE_SESSION_RC" 0
if [[ -e "$TMP/secure-reconciled" && -e "$TMP/secure-managed" &&
      -e "$TMP/secure-yq" && -e "$TMP/secure-command" ]]; then
  ok 'session start completes reconcile, adapter, yq, and command phases'
else
  not_ok 'session start completes reconcile, adapter, yq, and command phases'
fi
assert_eq 'session manager is bound to the installed sibling skills root' \
  "$(<"$TMP/secure-skills-root")" "$SECURE_SKILLS"
if [[ ! -e "$TMP/secure-poisoned" && ! -e "$TMP/secure-poison-managed" ]]; then
  ok 'session start ignores PATH Bash, BASH_ENV, and ambient skills-root poisoning'
else
  not_ok 'session start ignores PATH Bash, BASH_ENV, and ambient skills-root poisoning'
fi

# Claude: keep existing status and hook ownership, add one stable synchronous
# updater hook, and remove only AFK's exact fields.
CLAUDE_HOME="$TMP/claude-home"; CLAUDE_STATE="$TMP/claude-state"
mkdir -p "$CLAUDE_HOME/.claude"
jq -nc '{theme:"owner-choice",statusLine:{type:"command",command:"owner-status",padding:4},hooks:{
  SessionStart:[
    {matcher:"startup",hooks:[{type:"command",command:"hindsight recall",timeout:9}]},
    {hooks:[{type:"command",command:"owner-start"}]}
  ],Stop:[{hooks:[{type:"command",command:"owner-stop"}]}]
}}' >"$CLAUDE_HOME/.claude/settings.json"
cp "$CLAUDE_HOME/.claude/settings.json" "$TMP/claude-before.json"
AFK_TEST_TRACE="$TRACE" "$RUNTIME/manage.sh" install claude --home "$CLAUDE_HOME" --state-dir "$CLAUDE_STATE" --adapter-root "$RUNTIME" >/dev/null
AFK_TEST_TRACE="$TRACE" "$RUNTIME/manage.sh" install claude --home "$CLAUDE_HOME" --state-dir "$CLAUDE_STATE" --adapter-root "$RUNTIME" >/dev/null
CLAUDE_SETTINGS="$CLAUDE_HOME/.claude/settings.json"
UPDATER="$RUNTIME/bin/afk-session-start"
assert_eq 'Claude installs one stable updater hook' "$(jq --arg u "$UPDATER" '[.hooks.SessionStart[]?.hooks[]?|select(.command==$u)]|length' "$CLAUDE_SETTINGS")" 1
assert_eq 'Claude updater hook is synchronous and bounded' "$(jq --arg u "$UPDATER" '[.hooks.SessionStart[]?.hooks[]?|select(.command==$u)][0] | [.type,.timeout,has("async")]|@tsv' -r "$CLAUDE_SETTINGS")" $'command\t30\tfalse'
assert_eq 'Claude preserves Hindsight hook position' "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$CLAUDE_SETTINGS")" 'hindsight recall'
assert_eq 'Claude preserves user SessionStart hook' "$(jq '[.hooks.SessionStart[]?.hooks[]?|select(.command=="owner-start")]|length' "$CLAUDE_SETTINGS")" 1
assert_eq 'adapter installation never runs the updater' "$(wc -l <"$TRACE" 2>/dev/null || printf 0)" 0

CLAUDE_HOOK="$(jq -r --arg u "$UPDATER" '.hooks.SessionStart[]?.hooks[]?|select(.command==$u)|.command' "$CLAUDE_SETTINGS")"
AFK_TEST_TRACE="$TRACE" bash -c "$CLAUDE_HOOK" >/dev/null
assert_eq 'native Claude hook invokes the stable updater' "$(grep -c '^updater$' "$TRACE")" 1
rm -f -- "$RUNTIME/bin/afk-session-start"
set +e
AFK_TEST_TRACE="$TRACE" bash -c "$CLAUDE_HOOK" >/dev/null 2>"$TMP/claude-unavailable.err"
CLAUDE_UNAVAILABLE_RC=$?
set -e
if [[ "$CLAUDE_UNAVAILABLE_RC" -ne 0 && -s "$TMP/claude-unavailable.err" ]]; then
  ok 'missing native updater fails visibly'
else
  not_ok 'missing native updater fails visibly'
fi
"$RUNTIME/manage.sh" remove claude --home "$CLAUDE_HOME" --state-dir "$CLAUDE_STATE" --adapter-root "$RUNTIME" >/dev/null
assert_json_eq 'Claude removal restores user and Hindsight configuration' "$TMP/claude-before.json" "$CLAUDE_SETTINGS"
write_updater
: >"$TRACE"

# Codex: preserve existing hooks, order the updater before the AFK publisher,
# and keep PreCompact presentation-only.
CODEX_HOME="$TMP/codex-home"; CODEX_STATE="$TMP/codex-state"
mkdir -p "$CODEX_HOME/.codex"
printf '[tui]\nstatus_line = ["model", "git-branch"]\n' >"$CODEX_HOME/.codex/config.toml"
jq -nc '{owner:true,hooks:{SessionStart:[
  {matcher:"startup",hooks:[{type:"command",command:"hindsight recall"}]},
  {hooks:[{type:"command",command:"owner-start"}]}
],PreCompact:[{hooks:[{type:"command",command:"owner-compact"}]}],Stop:[{hooks:[{type:"command",command:"owner-stop"}]}]}}' >"$CODEX_HOME/.codex/hooks.json"
cp "$CODEX_HOME/.codex/hooks.json" "$TMP/codex-hooks-before.json"
AFK_TEST_TRACE="$TRACE" "$RUNTIME/manage.sh" install codex --home "$CODEX_HOME" --state-dir "$CODEX_STATE" --adapter-root "$RUNTIME" >/dev/null
AFK_TEST_TRACE="$TRACE" "$RUNTIME/manage.sh" install codex --home "$CODEX_HOME" --state-dir "$CODEX_STATE" --adapter-root "$RUNTIME" >/dev/null
CODEX_HOOKS="$CODEX_HOME/.codex/hooks.json"; PUBLISHER="$RUNTIME/codex/publish.sh"
assert_eq 'Codex installs one stable updater hook' "$(jq --arg u "$UPDATER" '[.hooks.SessionStart[]?.hooks[]?|select(.command==$u)]|length' "$CODEX_HOOKS")" 1
assert_eq 'Codex installs one SessionStart publisher' "$(jq --arg p "$PUBLISHER" '[.hooks.SessionStart[]?.hooks[]?|select(.command==$p)]|length' "$CODEX_HOOKS")" 1
assert_eq 'Codex updater precedes AFK publisher' "$(jq --arg u "$UPDATER" --arg p "$PUBLISHER" '([.hooks.SessionStart[]?.hooks[]?.command]|index($u)) < ([.hooks.SessionStart[]?.hooks[]?.command]|index($p))' "$CODEX_HOOKS")" true
assert_eq 'Codex AFK hooks are synchronous' "$(jq --arg u "$UPDATER" --arg p "$PUBLISHER" '[.hooks.SessionStart[]?.hooks[]?|select(.command==$u or .command==$p)|has("async")]|any' "$CODEX_HOOKS")" false
assert_eq 'Codex PreCompact never reruns updater' "$(jq --arg u "$UPDATER" '[.hooks.PreCompact[]?.hooks[]?|select(.command==$u)]|length' "$CODEX_HOOKS")" 0
assert_eq 'Codex preserves Hindsight and user hooks' "$(jq '[.hooks.SessionStart[]?.hooks[]?|select(.command=="hindsight recall" or .command=="owner-start")]|length' "$CODEX_HOOKS")" 2
assert_eq 'Codex installation never runs updater' "$(wc -l <"$TRACE")" 0
if grep -Fq '/releases/candidates/' "$CLAUDE_SETTINGS" "$CODEX_HOOKS"; then
  not_ok 'native hooks avoid candidate-cache paths'
else
  ok 'native hooks avoid candidate-cache paths'
fi
"$RUNTIME/manage.sh" remove codex --home "$CODEX_HOME" --state-dir "$CODEX_STATE" --adapter-root "$RUNTIME" >/dev/null
assert_json_eq 'Codex removal restores Hindsight and user hooks' "$TMP/codex-hooks-before.json" "$CODEX_HOOKS"
assert_eq 'Codex removal restores native status line' "$(yq -p=toml -o=json -I=0 '.tui.status_line' "$CODEX_HOME/.codex/config.toml")" '["model","git-branch"]'

# Darwin keeps AFK presentation and pressure handling but does not register the
# Linux-only blocking updater. The copied manager is a platform fixture; no
# production environment variable can disable reconciliation on Linux.
DARWIN_RUNTIME="$TMP/darwin-runtime"; cp -R "$RUNTIME" "$DARWIN_RUNTIME"
sed -i 's|^afk_auto_update_supported().*|afk_auto_update_supported() { return 1; }|' "$DARWIN_RUNTIME/manage.sh"
DARWIN_CLAUDE_HOME="$TMP/darwin-claude-home"; DARWIN_CLAUDE_STATE="$TMP/darwin-claude-state"
mkdir -p "$DARWIN_CLAUDE_HOME/.claude"; printf '{}\n' >"$DARWIN_CLAUDE_HOME/.claude/settings.json"
"$DARWIN_RUNTIME/manage.sh" install claude --home "$DARWIN_CLAUDE_HOME" --state-dir "$DARWIN_CLAUDE_STATE" --adapter-root "$DARWIN_RUNTIME" >/dev/null
assert_eq 'Darwin Claude omits blocking updater hook' \
  "$(jq --arg u "$DARWIN_RUNTIME/bin/afk-session-start" '[.hooks.SessionStart[]?.hooks[]?|select(.command==$u)]|length' "$DARWIN_CLAUDE_HOME/.claude/settings.json")" 0
assert_eq 'Darwin Claude retains presentation and pressure hooks' \
  "$(jq '[.hooks.SessionStart[]?.hooks[]?,.hooks.PreCompact[]?.hooks[]?,.hooks.UserPromptSubmit[]?.hooks[]?]|length' "$DARWIN_CLAUDE_HOME/.claude/settings.json")" 3
assert_eq 'Darwin Claude ownership records auto-update unavailable' \
  "$(jq -r '.auto_update|tostring' "$DARWIN_CLAUDE_STATE/adapters/claude.json")" false
"$DARWIN_RUNTIME/manage.sh" remove claude --home "$DARWIN_CLAUDE_HOME" --state-dir "$DARWIN_CLAUDE_STATE" --adapter-root "$DARWIN_RUNTIME" >/dev/null

DARWIN_CODEX_HOME="$TMP/darwin-codex-home"; DARWIN_CODEX_STATE="$TMP/darwin-codex-state"
mkdir -p "$DARWIN_CODEX_HOME/.codex"; printf '' >"$DARWIN_CODEX_HOME/.codex/config.toml"; printf '{"hooks":{}}\n' >"$DARWIN_CODEX_HOME/.codex/hooks.json"
"$DARWIN_RUNTIME/manage.sh" install codex --home "$DARWIN_CODEX_HOME" --state-dir "$DARWIN_CODEX_STATE" --adapter-root "$DARWIN_RUNTIME" >/dev/null
assert_eq 'Darwin Codex omits blocking updater hook' \
  "$(jq --arg u "$DARWIN_RUNTIME/bin/afk-session-start" '[.hooks.SessionStart[]?.hooks[]?|select(.command==$u)]|length' "$DARWIN_CODEX_HOME/.codex/hooks.json")" 0
assert_eq 'Darwin Codex retains publisher and pressure instruction' \
  "$(jq --arg p "$DARWIN_RUNTIME/codex/publish.sh" --arg i "$DARWIN_RUNTIME/worker-context.sh session-start --harness codex" '[.hooks.SessionStart[]?.hooks[]?|select(.command==$p or .command==$i)]|length' "$DARWIN_CODEX_HOME/.codex/hooks.json")" 2
assert_eq 'Darwin Codex ownership records auto-update unavailable' \
  "$(jq -r '.auto_update|tostring' "$DARWIN_CODEX_STATE/adapters/codex.json")" false
"$DARWIN_RUNTIME/manage.sh" remove codex --home "$DARWIN_CODEX_HOME" --state-dir "$DARWIN_CODEX_STATE" --adapter-root "$DARWIN_RUNTIME" >/dev/null

# An explicit macOS session start cannot re-prove candidate bytes from recorded
# revision fields alone. It retains installed state, refuses visibly, and invokes
# neither the reconciler nor the requested session command.
DARWIN_START_ROOT="$TMP/darwin-start"; DARWIN_START_STATE="$TMP/darwin-start-state"
mkdir -p "$DARWIN_START_ROOT/bin" "$DARWIN_START_STATE/releases"
cp "$ROOT/bin/afk-session-start" "$DARWIN_START_ROOT/bin/afk-session-start"
sed -i 's|^afk_is_darwin().*|afk_is_darwin() { return 0; }|' "$DARWIN_START_ROOT/bin/afk-session-start"
printf '#!/usr/bin/env bash\nprintf invoked >"$AFK_DARWIN_RECONCILER_MARKER"\nexit 99\n' >"$DARWIN_START_ROOT/bin/afk-release-reconcile"
chmod +x "$DARWIN_START_ROOT/bin/afk-session-start" "$DARWIN_START_ROOT/bin/afk-release-reconcile"
darwin_revision=0123456789abcdef0123456789abcdef01234567
jq -nc --arg r "$darwin_revision" '{applied_revision:$r}' >"$DARWIN_START_STATE/state.json"
jq -nc --arg r "$darwin_revision" '{schema:"afk-release-current/1",revision:$r}' >"$DARWIN_START_STATE/releases/current.json"
DARWIN_START_POISON_BIN="$TMP/darwin-start-poison-bin"
DARWIN_START_POISON_MARKER="$TMP/darwin-start-poisoned"
mkdir "$DARWIN_START_POISON_BIN"
for poison_tool in dirname realpath stat jq cat; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$0" >>"$AFK_TEST_POISON_MARKER"\nexit 99\n' \
    >"$DARWIN_START_POISON_BIN/$poison_tool"
  chmod +x "$DARWIN_START_POISON_BIN/$poison_tool"
done
set +e
(
  dirname() { printf 'function-dirname\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  realpath() { printf 'function-realpath\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  stat() { printf 'function-stat\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  jq() { printf 'function-jq\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  cat() { printf 'function-cat\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  compgen() { printf 'function-compgen\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  mapfile() { printf 'function-mapfile\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  export -f dirname realpath stat jq cat compgen mapfile
  PATH="$DARWIN_START_POISON_BIN:/usr/bin:/bin" \
    AFK_TEST_POISON_MARKER="$DARWIN_START_POISON_MARKER" \
    HOME="$TMP/darwin-start-home" AFK_STATE_DIR="$DARWIN_START_STATE" \
    AFK_DARWIN_RECONCILER_MARKER="$TMP/darwin-reconciler-invoked" \
    "$DARWIN_START_ROOT/bin/afk-session-start" -- sh -c 'printf launched >"$1"' _ "$TMP/darwin-launched"
) >"$TMP/darwin-start.out" 2>"$TMP/darwin-start.err"
DARWIN_START_RC=$?
set -e
assert_eq 'macOS explicit start refuses without sandbox proof' "$DARWIN_START_RC" 3
assert_eq 'session-start bootstrap ignores PATH and imported-function poisoning' \
  "$([[ -e "$DARWIN_START_POISON_MARKER" ]] && wc -c <"$DARWIN_START_POISON_MARKER" || printf 0)" 0
if [[ ! -e "$TMP/darwin-launched" && ! -e "$TMP/darwin-reconciler-invoked" ]]; then ok 'macOS refusal runs neither command nor unconfined reconcile'; else not_ok 'macOS refusal runs neither command nor unconfined reconcile'; fi
assert_eq 'macOS sandbox blocker is visible' "$(jq -r .reason "$TMP/darwin-start.out")" MACOS_SANDBOX_PENDING
assert_eq 'macOS does not synthesize last-good verification' "$(jq -r '.last_good_verified|tostring' "$TMP/darwin-start.out")" false
assert_eq 'macOS reports a matching recorded last-good as retained' \
  "$(jq -r '.last_good_retained|tostring' "$TMP/darwin-start.out")" true

DARWIN_EMPTY_STATE="$TMP/darwin-empty-state"
set +e
HOME="$TMP/darwin-empty-home" AFK_STATE_DIR="$DARWIN_EMPTY_STATE" \
  "$DARWIN_START_ROOT/bin/afk-session-start" >"$TMP/darwin-empty.out" 2>"$TMP/darwin-empty.err"
DARWIN_EMPTY_RC=$?
set -e
assert_eq 'macOS empty-state start still refuses' "$DARWIN_EMPTY_RC" 3
assert_eq 'macOS never invents retention without recorded state' \
  "$(jq -r '.last_good_retained|tostring' "$TMP/darwin-empty.out")" false
if [[ ! -e "$DARWIN_EMPTY_STATE" ]]; then ok 'macOS empty-state refusal remains non-mutating'; else not_ok 'macOS empty-state refusal remains non-mutating'; fi

DARWIN_USER_JQ_ROOT="$TMP/darwin-user-jq"; mkdir -p "$DARWIN_USER_JQ_ROOT"
DARWIN_USER_JQ_MARKER="$TMP/darwin-user-jq-executed"
printf '#!/usr/bin/env bash\nprintf invoked >%q\nexit 99\n' \
  "$DARWIN_USER_JQ_MARKER" >"$DARWIN_USER_JQ_ROOT/jq"
chmod +x "$DARWIN_USER_JQ_ROOT/jq"
DARWIN_USER_JQ_START="$TMP/darwin-user-jq-session-start"
cp "$DARWIN_START_ROOT/bin/afk-session-start" "$DARWIN_USER_JQ_START"
sed -i "s|readonly -a JQ_CANDIDATES=(/usr/bin/jq)|readonly -a JQ_CANDIDATES=('$DARWIN_USER_JQ_ROOT/jq')|" \
  "$DARWIN_USER_JQ_START"
chmod +x "$DARWIN_USER_JQ_START"
DARWIN_USER_JQ_COMMAND_MARKER="$TMP/darwin-user-jq-command"
DARWIN_USER_JQ_RECONCILER_MARKER="$TMP/darwin-user-jq-reconciler"
DARWIN_STATE_BEFORE="$(sha256sum "$DARWIN_START_STATE/state.json" "$DARWIN_START_STATE/releases/current.json")"
set +e
HOME="$TMP/darwin-user-jq-home" AFK_STATE_DIR="$DARWIN_START_STATE" \
  AFK_DARWIN_RECONCILER_MARKER="$DARWIN_USER_JQ_RECONCILER_MARKER" \
  "$DARWIN_USER_JQ_START" -- sh -c 'printf launched >"$1"' _ "$DARWIN_USER_JQ_COMMAND_MARKER" \
  >"$TMP/darwin-user-jq.out" 2>"$TMP/darwin-user-jq.err"
DARWIN_USER_JQ_RC=$?
set -e
assert_eq 'user-owned Darwin jq fails closed' "$DARWIN_USER_JQ_RC" 3
assert_eq 'untrusted Darwin jq cannot claim retained state' \
  "$(jq -r '.last_good_retained|tostring' "$TMP/darwin-user-jq.out")" false
if [[ ! -e "$DARWIN_USER_JQ_MARKER" && ! -e "$DARWIN_USER_JQ_COMMAND_MARKER" &&
      ! -e "$DARWIN_USER_JQ_RECONCILER_MARKER" &&
      "$(sha256sum "$DARWIN_START_STATE/state.json" "$DARWIN_START_STATE/releases/current.json")" == "$DARWIN_STATE_BEFORE" ]]; then
  ok 'untrusted Darwin jq is neither executed nor allowed to launch or write state'
else
  not_ok 'untrusted Darwin jq is neither executed nor allowed to launch or write state'
fi

# OpenCode follows the same Darwin policy: emit one stable warning, skip the
# updater process, and still register and process normal AFK events.
DARWIN_PLUGIN="$TMP/darwin-plugin.mjs"; cp "$ROOT/adapters/opencode/plugin.js" "$DARWIN_PLUGIN"
sed -i 's|function autoUpdatePlatform() { return process.platform }|function autoUpdatePlatform() { return "darwin" }|' "$DARWIN_PLUGIN"
DARWIN_TOASTS="$TMP/darwin-opencode-toasts.jsonl"; DARWIN_OPEN_CACHE="$TMP/darwin-open-cache"
AFK_TEST_PLUGIN="$DARWIN_PLUGIN" AFK_TEST_TOASTS="$DARWIN_TOASTS" AFK_STATUS_CACHE_DIR="$DARWIN_OPEN_CACHE" \
  node --input-type=module <<'NODE'
import { appendFileSync } from "node:fs"
import { pathToFileURL } from "node:url"
const pluginModule = await import(pathToFileURL(process.env.AFK_TEST_PLUGIN))
const client = { tui: { showToast: async (payload) => appendFileSync(process.env.AFK_TEST_TOASTS, JSON.stringify(payload) + "\n") } }
const plugin = await pluginModule.default({ client })
await plugin.event({ event: { type: "message.updated", properties: { info: { sessionID: "darwin-session", modelID: "darwin-model" } } } })
await new Promise((resolve) => setTimeout(resolve, 100))
NODE
assert_eq 'Darwin OpenCode surfaces stable sandbox blocker' "$(jq -r '.body.message' "$DARWIN_TOASTS")" 'AFK UNAVAILABLE[MACOS_SANDBOX_PENDING]'
assert_eq 'Darwin OpenCode still processes normal AFK events' "$(jq -r '.model.value+":"+.session.value' "$DARWIN_OPEN_CACHE/runtime-opencode.json")" 'darwin-model:darwin-session'

# OpenCode: the plugin is composed once, awaits exactly one bounded startup
# reconcile, and never retries from normal events.
OPEN_HOME="$TMP/open-home"; OPEN_STATE="$TMP/open-state"
mkdir -p "$OPEN_HOME/.config/opencode"
jq -nc '{plugin:["@vectorize-io/hindsight-coding-agents","file:///owner/plugin.js"],credentialRef:"env:OPENCODE_TOKEN"}' >"$OPEN_HOME/.config/opencode/opencode.json"
cp "$OPEN_HOME/.config/opencode/opencode.json" "$TMP/opencode-before.json"
"$RUNTIME/manage.sh" install opencode --home "$OPEN_HOME" --state-dir "$OPEN_STATE" --adapter-root "$RUNTIME" >/dev/null
"$RUNTIME/manage.sh" install opencode --home "$OPEN_HOME" --state-dir "$OPEN_STATE" --adapter-root "$RUNTIME" >/dev/null
assert_eq 'OpenCode composes one AFK plugin' "$(jq --arg p "file://$RUNTIME/opencode/plugin.js" '[.plugin[]|select(.==$p)]|length' "$OPEN_HOME/.config/opencode/opencode.json")" 1
assert_eq 'OpenCode preserves Hindsight and user plugins' "$(jq '[.plugin[]|select(.=="@vectorize-io/hindsight-coding-agents" or .=="file:///owner/plugin.js")]|length' "$OPEN_HOME/.config/opencode/opencode.json")" 2
assert_eq 'OpenCode preserves credential reference' "$(jq -r .credentialRef "$OPEN_HOME/.config/opencode/opencode.json")" 'env:OPENCODE_TOKEN'

: >"$TRACE"; TOASTS="$TMP/opencode-toasts.jsonl"
AFK_TEST_TRACE="$TRACE" AFK_STATUS_CACHE_DIR="$TMP/open-cache" OPENCODE_TOKEN=DO-NOT-EXPOSE AFK_TEST_TOASTS="$TOASTS" AFK_TEST_PLUGIN="$RUNTIME/opencode/plugin.js" \
  node --input-type=module <<'NODE'
import { appendFileSync } from "node:fs"
import { pathToFileURL } from "node:url"
const pluginModule = await import(pathToFileURL(process.env.AFK_TEST_PLUGIN))
const client = { tui: { showToast: async (payload) => appendFileSync(process.env.AFK_TEST_TOASTS, JSON.stringify(payload) + "\n") } }
const plugin = await pluginModule.default({ client })
appendFileSync(process.env.AFK_TEST_TRACE, "factory-return\n")
await plugin.event({ event: { type: "session.created", properties: { info: {
  id: "test-session", model: { providerID: "test-provider", modelID: "test-model", variant: "max" }
} } } })
await plugin.event({ event: { type: "message.updated", properties: { info: {
  role: "assistant", sessionID: "test-session", providerID: "test-provider", modelID: "test-model",
  tokens: { input: 11, output: 7, reasoning: 3, cache: { read: 0, write: 0 } }
} } } })
await plugin.event({ event: { type: "session.idle", properties: { sessionID: "test-session" } } })
await new Promise((resolve) => setTimeout(resolve, 250))
NODE
assert_eq 'OpenCode startup reconciles exactly once' "$(grep -c '^updater$' "$TRACE")" 1
assert_eq 'OpenCode awaits updater before normal event work' "$(sed -n '1p' "$TRACE")" updater
assert_eq 'OpenCode events do not rerun updater' "$(grep -c '^updater$' "$TRACE")" 1
assert_eq 'OpenCode normalizes the live nested model shape' "$(jq -r '[.provider.value,.model.value,.session.value]|@tsv' "$TMP/open-cache/runtime-opencode.json")" $'test-provider\ttest-model\ttest-session'
assert_eq 'OpenCode preserves observed fields across sparse idle events' "$(jq -r '[.model.state,.provider.state,.turn_tokens.value]|@tsv' "$TMP/open-cache/runtime-opencode.json")" $'AVAILABLE\tAVAILABLE\t21'
if grep -Fq 'DO-NOT-EXPOSE' "$TOASTS" 2>/dev/null; then
  not_ok 'OpenCode toast does not expose credentials'
else
  ok 'OpenCode toast does not expose credentials'
fi

# With no caller override, separate Orca terminals must not share OpenCode's
# runtime observation file.
for scoped_case in 'open-a:Alpha' 'open-b:Beta'; do
  scoped_terminal="${scoped_case%%:*}"; scoped_model="${scoped_case#*:}"
  XDG_CACHE_HOME="$TMP/open-scoped-cache" ORCA_TERMINAL_HANDLE="$scoped_terminal" \
    AFK_TEST_MODEL="$scoped_model" AFK_TEST_PLUGIN="$RUNTIME/opencode/plugin.js" \
    node --input-type=module <<'NODE'
import { pathToFileURL } from "node:url"
const pluginModule = await import(pathToFileURL(process.env.AFK_TEST_PLUGIN))
const plugin = await pluginModule.default({ client: { tui: { showToast: async () => {} } } })
await plugin.event({ event: { type: "message.updated", properties: { info: { modelID: process.env.AFK_TEST_MODEL } } } })
await new Promise((resolve) => setTimeout(resolve, 100))
NODE
done
mapfile -t scoped_open_files < <(find "$TMP/open-scoped-cache/agent-flow-kit/scopes" -name runtime-opencode.json -type f | sort)
assert_eq 'OpenCode defaults to one runtime cache per terminal' "${#scoped_open_files[@]}" 2
assert_eq 'OpenCode terminal caches retain their own model' "$(jq -rs 'map(.model.value)|sort|join(":")' "${scoped_open_files[@]}")" Alpha:Beta

# Outside Orca, runtime observations require a session identity. Separate
# sessions in one worktree must never share sparse-event carry-forward.
mkdir -p "$TMP/open-worktree"
(cd "$TMP/open-worktree" && env -u ORCA_TERMINAL_HANDLE XDG_CACHE_HOME="$TMP/open-worktree-cache" \
  AFK_TEST_PLUGIN="$RUNTIME/opencode/plugin.js" node --input-type=module <<'NODE'
import { pathToFileURL } from "node:url"
const pluginModule = await import(pathToFileURL(process.env.AFK_TEST_PLUGIN))
const plugin = await pluginModule.default({ client: { tui: { showToast: async () => {} } } })
await plugin.event({ event: { type: "message.updated", properties: { info: { sessionID: "session-a", modelID: "Alpha" } } } })
await plugin.event({ event: { type: "session.idle", properties: { sessionID: "session-b" } } })
await plugin.event({ event: { type: "message.updated", properties: { info: { modelID: "Unbound" } } } })
await new Promise((resolve) => setTimeout(resolve, 100))
NODE
)
mapfile -t session_open_files < <(find "$TMP/open-worktree-cache/agent-flow-kit/scopes" -name runtime-opencode.json -type f | sort)
assert_eq 'OpenCode creates one non-Orca cache per identified session' "${#session_open_files[@]}" 2
assert_eq 'OpenCode never carries model state across sessions' \
  "$(jq -rs 'sort_by(.session.value)|map(.session.value+":"+.model.state+":"+(.model.value // "-"))|join("|")' "${session_open_files[@]}")" \
  'session-a:AVAILABLE:Alpha|session-b:NOT_EVALUATED:-'

rm -f -- "$RUNTIME/bin/afk-session-start"; : >"$TOASTS"
AFK_TEST_TRACE="$TRACE" AFK_TEST_TOASTS="$TOASTS" AFK_TEST_PLUGIN="$RUNTIME/opencode/plugin.js" \
  node --input-type=module <<'NODE'
import { appendFileSync } from "node:fs"
import { pathToFileURL } from "node:url"
const pluginModule = await import(pathToFileURL(process.env.AFK_TEST_PLUGIN))
const client = { tui: { showToast: async (payload) => appendFileSync(process.env.AFK_TEST_TOASTS, JSON.stringify(payload) + "\n") } }
await pluginModule.default({ client })
NODE
assert_eq 'OpenCode missing updater is explicitly visible' "$(jq -r '.body.message' "$TOASTS")" 'AFK UNAVAILABLE[UPDATER_UNAVAILABLE]'

write_updater; : >"$TOASTS"; : >"$TRACE"
START_EPOCH="$(date +%s)"
AFK_TEST_TRACE="$TRACE" AFK_TEST_UPDATER_MODE=timeout AFK_SESSION_START_TIMEOUT_MS=1000 AFK_TEST_TOASTS="$TOASTS" AFK_TEST_PLUGIN="$RUNTIME/opencode/plugin.js" \
  node --input-type=module <<'NODE'
import { appendFileSync } from "node:fs"
import { pathToFileURL } from "node:url"
const pluginModule = await import(pathToFileURL(process.env.AFK_TEST_PLUGIN))
const client = { tui: { showToast: async (payload) => appendFileSync(process.env.AFK_TEST_TOASTS, JSON.stringify(payload) + "\n") } }
await pluginModule.default({ client })
NODE
ELAPSED=$(( $(date +%s) - START_EPOCH ))
assert_eq 'OpenCode bounded timeout is explicitly visible' "$(jq -r '.body.message' "$TOASTS")" 'AFK UNAVAILABLE[UPDATER_TIMEOUT]'
if (( ELAPSED < 4 )); then ok 'OpenCode startup timeout is bounded'; else not_ok "OpenCode startup timeout is bounded (elapsed=${ELAPSED}s)"; fi
"$RUNTIME/manage.sh" remove opencode --home "$OPEN_HOME" --state-dir "$OPEN_STATE" --adapter-root "$RUNTIME" >/dev/null
assert_json_eq 'OpenCode removal restores plugins and credential reference' "$TMP/opencode-before.json" "$OPEN_HOME/.config/opencode/opencode.json"

# Hermes remains wrapper-only and presentation-only on an unqualified host.
write_updater; : >"$TRACE"
# $1 is intentionally expanded by the child shell.
# shellcheck disable=SC2016
AFK_TEST_TRACE="$TRACE" "$RUNTIME/hermes/session-start.sh" -- sh -c 'printf wrapped >"$1"' _ "$TMP/hermes-wrapped" >/dev/null
if [[ -s "$TMP/hermes-wrapped" ]]; then ok 'Hermes wrapper reconciles before supplied command'; else not_ok 'Hermes wrapper reconciles before supplied command'; fi
assert_eq 'Hermes wrapper invokes stable updater once' "$(grep -c '^updater$' "$TRACE")" 1
HERMES_CARD="$(AFK_STATUS_CACHE="$TMP/missing-status.json" "$RUNTIME/hermes/status-card.sh")"
assert_eq 'Hermes status remains a read-only card' "$(jq -r '.kind+":"+(.read_only|tostring)' <<<"$HERMES_CARD")" 'status_card:true'
set +e
HERMES_MANAGER_OUT="$(PATH=/usr/bin:/bin "$RUNTIME/manage.sh" install hermes --home "$TMP/hermes-home" --state-dir "$TMP/hermes-state" --adapter-root "$RUNTIME" 2>&1)"
HERMES_MANAGER_RC=$?
set -e
assert_eq 'Hermes native integration remains locally absent' "$HERMES_MANAGER_RC" 4
assert_eq 'Hermes native absence remains explicit' "$HERMES_MANAGER_OUT" HARNESS_NOT_INSTALLED:hermes
rm -f -- "$RUNTIME/bin/afk-session-start"
set +e
AFK_TEST_TRACE="$TRACE" "$RUNTIME/hermes/session-start.sh" -- true >/dev/null 2>"$TMP/hermes-unavailable.err"
HERMES_UNAVAILABLE_RC=$?
set -e
assert_eq 'Hermes wrapper refuses unavailable stable updater' "$HERMES_UNAVAILABLE_RC" 3
if grep -Fq 'updater unavailable at stable runtime path' "$TMP/hermes-unavailable.err"; then
  ok 'Hermes wrapper failure is visible'
else
  not_ok 'Hermes wrapper failure is visible'
fi

if grep -Fq '/releases/candidates/' "$RUNTIME/opencode/plugin.js" "$RUNTIME/hermes/session-start.sh"; then
  not_ok 'plugin and wrapper avoid candidate-cache paths'
else
  ok 'plugin and wrapper avoid candidate-cache paths'
fi
if grep -Fq 'remote presentation-only surface' "$ROOT/docs/RELEASE-UPDATE.md" && grep -Fq 'not a native-hook claim' "$ROOT/docs/RUNTIME-EXPERIENCE.md"; then
  ok 'docs distinguish Hermes wrapper from native hooks'
else
  not_ok 'docs distinguish Hermes wrapper from native hooks'
fi

printf '1..%d\n' "$((PASS + FAIL))"
if (( FAIL )); then printf '%d session-start integration assertions failed\n' "$FAIL" >&2; exit 1; fi
printf 'All %d session-start integration assertions passed.\n' "$PASS"
