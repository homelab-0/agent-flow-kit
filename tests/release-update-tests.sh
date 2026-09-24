#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2329 # generated fixtures and exported poison functions
set -uo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"

candidate_smoke() {
  local candidate="$1" smoke state revision freshness memory rc=0
  [[ -d "$candidate/.git" ]] || return 1
  local script
  for script in afk-release-reconcile afk-session-freshness afk-session-start; do
    bash -n "$candidate/bin/$script" || return 1
  done
  jq -e '
    .schema=="afk-release-policy/2" and
    .trust.remote_url=="ssh://git@github.com/jlengelbrecht/agent-flow-kit.git" and
    .trust.ref=="refs/heads/master" and .trust.default_branch=="master" and
    .trust.repository_root_commit=="d74e7f9542cfe2731e09a0ff5c5e1b4cf325062f" and
    .rollout.mode=="cohort_metadata_only" and .rollout.authoritative_promotion==false and
    .automatic_rollback_bypass==false
  ' "$candidate/lifecycle/release-policy.json" >/dev/null || return 1

  # Exercise two distributed runtime entry points against isolated, local-only
  # state. This is intentionally small enough for the qualification timeout and
  # never invokes the release client, Git transport, a native memory runtime,
  # or any credential-bearing configuration.
  smoke="$(mktemp -d)" || return 1
  state="$smoke/state"
  mkdir -p "$state/releases" || rc=1
  revision="$(git -C "$candidate" rev-parse HEAD 2>/dev/null || true)"
  [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || rc=1
  jq -nc --arg revision "$revision" \
    '{schema_version:"1.0",applied_revision:$revision}' >"$state/state.json" || rc=1
  jq -nc --arg revision "$revision" \
    '{schema:"afk-release-current/1",revision:$revision}' >"$state/releases/current.json" || rc=1
  freshness="$(AFK_STATE_DIR="$state" bash "$candidate/bin/afk-session-freshness" 2>/dev/null || true)"
  jq -e --arg revision "$revision" '
    .schema=="afk-session-freshness/2" and .state=="ACCEPTED_LOCALLY" and
    .reason=="RECORDED_LAST_GOOD" and .applied_revision==$revision and
    .accepted_revision==$revision and .offline==true and .launch_authoritative==false
  ' <<<"$freshness" >/dev/null 2>&1 || rc=1
  memory="$(AFK_STATE_DIR="$state" bash "$candidate/adapters/hindsight.sh" blind "$candidate" 2>/dev/null || true)"
  jq -e '
    .schema=="afk-memory-context/2" and .state=="DISABLED" and
    .native_integration=="BYPASSED_BY_SUPPORTED_CONFIG" and
    .environment.HINDSIGHT_DISABLED=="true" and .recall==[] and .retain==[]
  ' <<<"$memory" >/dev/null 2>&1 || rc=1
  rm -rf -- "$smoke"
  return "$rc"
}

if [[ "${1:-}" == --candidate-smoke ]]; then
  [[ $# -eq 2 ]] || exit 2
  candidate_smoke "$2"
  exit $?
fi

if ! command -v git >/dev/null || ! command -v jq >/dev/null ||
   ! command -v timeout >/dev/null || ! command -v python3 >/dev/null; then
  printf 'release-update-tests: git, jq, timeout, and python3 are required\n' >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$PASS" "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf 'not ok - %s\n' "$1"; }
assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then ok "$label"
  else not_ok "$label (got=$actual expected=$expected)"; fi
}
assert_file_contains() {
  local label="$1" file="$2" pattern="$3"
  if grep -Fq -- "$pattern" "$file"; then ok "$label"; else not_ok "$label"; fi
}
tree_identity() {
  /bin/bash -p -c '. "$1"; afk_tree_identity "$2"' _ "$ROOT/lib/afk-common.sh" "$1"
}

HOME_TEST="$TMP/home"; STATE="$HOME_TEST/.local/state/agent-flow-kit"
AUTHOR="$TMP/author"; REMOTE="$TMP/remote.git"; USER_CLONE="$TMP/user-clone"
mkdir -p "$HOME_TEST" "$STATE"
git clone -q "$ROOT" "$AUTHOR"
git -C "$AUTHOR" checkout -q -B master HEAD
git -C "$AUTHOR" config user.name 'AFK release test'
git -C "$AUTHOR" config user.email 'afk-release-test@example.invalid'

# Overlay only the release slice under test. This lets the focused test run in
# a dirty development worktree before these files have themselves been committed.
cp "$ROOT/bin/afk-release-reconcile" "$AUTHOR/bin/afk-release-reconcile"
cp "$ROOT/bin/afk-release-known-hosts" "$AUTHOR/bin/afk-release-known-hosts"
cp "$ROOT/bin/afk-session-freshness" "$AUTHOR/bin/afk-session-freshness"
cp "$ROOT/bin/afk-session-start" "$AUTHOR/bin/afk-session-start"
cp "$ROOT/lifecycle/release-policy.json" "$AUTHOR/lifecycle/release-policy.json"
cp "$ROOT/tests/release-update-tests.sh" "$AUTHOR/tests/release-update-tests.sh"
rm -rf "$AUTHOR/adapters"
cp -R "$ROOT/adapters" "$AUTHOR/adapters"
cp "$ROOT/lifecycle/kit.json" "$AUTHOR/lifecycle/kit.json"

# A narrow fake lifecycle makes this a release-client test, not a repetition of
# lifecycle-mutation-tests.sh. It has the same result fields consumed by the client.
cat >"$AUTHOR/bin/agent-flow-kit" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
driver_root="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
kit_root="${AFK_KIT_ROOT:?}"
state_dir="${AFK_STATE_DIR:?}"
test_home="${state_dir%/.local/state/agent-flow-kit}"
[[ "$kit_root" != "$driver_root" && "${AFK_LIB_DIR:-}" == "$driver_root/lib" &&
   "${AFK_MANIFEST:-}" == "$state_dir/state.json" &&
   "${AFK_JOURNAL:-}" == "$state_dir/journal.json" &&
   "${AFK_LOCK_DIR:-}" == "$state_dir/lock" &&
   "${AFK_BACKUP_ROOT:-}" == "$state_dir/backups" &&
   "${AFK_STAGE_ROOT:-}" == "$state_dir/stage" &&
   "${AFK_SKILLS_HOME:-}" == "$test_home/.agents/skills" &&
   "${AFK_CLAUDE_HOME:-}" == "$test_home/.claude" &&
   "${AFK_CODEX_HOME:-}" == "$test_home/.codex" &&
   "${AFK_ORCH_STATE:-}" == "$state_dir/orchestration.json" &&
   "${AFK_DISPATCH_DIR:-}" == "$state_dir/dispatch" &&
   "${AFK_DISPATCH_WATCH_DIR:-}" == "$state_dir/dispatch/watch" &&
   "${AFK_DISPATCH_INBOX_DIR:-}" == "$state_dir/dispatch/inbox" &&
   "${AFK_DISPATCH_RESULT_DIR:-}" == "$state_dir/dispatch/results" &&
   "${AFK_DISPATCH_MESSAGE_DIR:-}" == "$state_dir/dispatch/messages" &&
   "${AFK_PM_DIR:-}" == "$state_dir/pm/release-reconcile" &&
   -z "${HOME+x}" && -z "${AFK_TEST_ROLLBACK+x}" &&
   -z "${AFK_TEST_OPERATION_ID+x}" && -z "${AFK_TEST_RESULT_REASON+x}" &&
   -z "${AFK_ORCA_BIN+x}" ]] || exit 97
target="$(git -C "$kit_root" rev-parse HEAD)"
state="$state_dir/state.json"
applied="$(jq -r '.applied_revision // ""' "$state" 2>/dev/null || true)"
command_name="${1:-}"; shift || true
if [[ "$command_name" == verify ]]; then
  if [[ "$applied" == "$target" ]]; then
    jq -nc --arg target "$target" '{kind:"lifecycle_result",installed:{applied_revision:$target},extra:{verification:{verified:true}},overall:{exit_code:0}}'
    exit 0
  fi
  jq -nc --arg target "$target" --arg applied "$applied" '{kind:"lifecycle_result",installed:{applied_revision:$applied},extra:{verification:{verified:false}},overall:{exit_code:3}}'
  exit 3
fi
if [[ "$command_name" != update ]]; then exit 2; fi
plan=false; approval=""
while (( $# )); do
  case "$1" in --plan) plan=true ;; --approve-plan) approval="${2:-}"; shift ;; esac
  shift
done
disposition=MUTATION_REQUIRED; [[ "$applied" == "$target" ]] && disposition=NO_CHANGE
plan_identity="sha256:$(printf '%s' "$target" | sha256sum | awk '{print $1}')"
plan_doc="$(jq -nc --arg target "$target" --arg prior "$applied" --arg disposition "$disposition" --arg identity "$plan_identity" '{plan_identity:$identity,disposition:$disposition,prior_revision:$prior,target_revision:$target,approvals_required:0,conflicts:0,refusal_reason:null}')"
if [[ "$plan" == true ]]; then
  jq -nc --argjson plan "$plan_doc" '{kind:"lifecycle_result",source_eligibility:{state:"ELIGIBLE",mutation_allowed:true},extra:{plan:$plan},overall:{exit_code:0}}'
  exit 0
fi
if [[ "$approval" != "$plan_identity" ]]; then
  jq -nc --argjson plan "$plan_doc" '{kind:"lifecycle_result",source_eligibility:{state:"ELIGIBLE",mutation_allowed:true},extra:{plan:$plan},operation:{id:"test-refusal",result:"REFUSED",reason:"PLAN_IDENTITY_REQUIRED"},overall:{exit_code:2}}'
  exit 2
fi
if [[ -f "$state_dir/.test-rollback" ]]; then
  operation_id="$(cat "$state_dir/.test-operation-id" 2>/dev/null || printf test-rollback)"
  operation_reason="$(cat "$state_dir/.test-result-reason" 2>/dev/null || printf TEST_APPLY_ROLLED_BACK)"
  jq -nc --argjson plan "$plan_doc" --arg id "$operation_id" \
    --arg reason "$operation_reason" \
    '{kind:"lifecycle_result",source_eligibility:{state:"ELIGIBLE",mutation_allowed:true},extra:{plan:$plan},operation:{id:$id,result:"ROLLED_BACK",reason:$reason},overall:{exit_code:2}}'
  exit 2
fi
mkdir -p "$(dirname "$state")"
jq --arg target "$target" '.applied_revision=$target' "$state" >"${state}.tmp"
mv "${state}.tmp" "$state"
result=CONVERGED; [[ "$disposition" == NO_CHANGE ]] && result=NO_CHANGE
jq -nc --argjson plan "$plan_doc" --arg result "$result" '{kind:"lifecycle_result",source_eligibility:{state:"ELIGIBLE",mutation_allowed:true},extra:{plan:$plan},operation:{id:"test-apply",result:$result,reason:"TEST_APPLY"},overall:{exit_code:0}}'
STUB
chmod +x "$AUTHOR/bin/agent-flow-kit" "$AUTHOR/bin/afk-release-reconcile" \
  "$AUTHOR/bin/afk-session-freshness" "$AUTHOR/bin/afk-session-start" \
  "$AUTHOR/tests/release-update-tests.sh"
git -C "$AUTHOR" add bin adapters lifecycle tests/release-update-tests.sh
git -C "$AUTHOR" commit -qm 'test release one'
TARGET_ONE="$(git -C "$AUTHOR" rev-parse HEAD)"
BASE="$(git -C "$AUTHOR" rev-parse HEAD^)"
git init -q --bare "$REMOTE"
git -C "$AUTHOR" remote add test-origin "$REMOTE"
git -C "$AUTHOR" push -q test-origin master

TRUSTED_DRIVER_SOURCE="$TMP/trusted-driver-source"
mkdir -p "$TRUSTED_DRIVER_SOURCE/bin" "$TRUSTED_DRIVER_SOURCE/lib"
cp "$AUTHOR/bin/agent-flow-kit" "$TRUSTED_DRIVER_SOURCE/bin/agent-flow-kit"
cp -R "$AUTHOR/lib/." "$TRUSTED_DRIVER_SOURCE/lib/"
TRUSTED_BIN_IDENTITY="$(tree_identity "$TRUSTED_DRIVER_SOURCE/bin")"
TRUSTED_LIB_IDENTITY="$(tree_identity "$TRUSTED_DRIVER_SOURCE/lib")"

cat >"$HOME_TEST/.gitconfig" <<EOF
[url "file://$REMOTE"]
    insteadOf = ssh://git@github.com/jlengelbrecht/agent-flow-kit.git
EOF
# A provisioned deploy key at the default machine-local path. The content is a
# marker, never a real key: no test reaches the network.
DEPLOY_KEY_DIR="$HOME_TEST/.config/agent-flow-kit/deploy-key"
DEPLOY_KEY_FILE="$DEPLOY_KEY_DIR/agent-flow-kit_ed25519"
DEPLOY_KEY_MARKER='afk-test-deploy-key-private-material'
mkdir -p "$DEPLOY_KEY_DIR"
# The client refuses keys under group/world-writable directories; do not
# inherit that from the runner's umask.
chmod 755 "$HOME_TEST" "$HOME_TEST/.config" "$HOME_TEST/.config/agent-flow-kit"
chmod 700 "$DEPLOY_KEY_DIR"
(umask 077; printf '%s\n' "$DEPLOY_KEY_MARKER" >"$DEPLOY_KEY_FILE")
chmod 600 "$DEPLOY_KEY_FILE"
# User ssh state the client must never consult.
mkdir -p "$HOME_TEST/.ssh"
printf 'Host github.com\n  IdentityFile ~/.ssh/poison\n' >"$HOME_TEST/.ssh/config"
# The production client intentionally ignores the global rewrite above. A fake
# git executable is the bounded test transport seam: it changes only fetch
# transport and delegates every validation/configuration operation unchanged.
REAL_GIT="$(command -v git)"; TEST_BIN="$TMP/test-bin"; OFFLINE_MARKER="$TMP/offline"
mkdir "$TEST_BIN"
cat >"$TEST_BIN/git" <<EOF
#!/usr/bin/env bash
if [[ -n "\${AFK_TEST_GIT_ENV_MARKER:-}" ]]; then
  for name in GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE \
    GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_ASKPASS \
    SSH_ASKPASS GIT_CONFIG_PARAMETERS GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 \
    GIT_SSL_CAINFO GIT_SSL_CAPATH GIT_PROXY_COMMAND GIT_EXEC_PATH SSH_AUTH_SOCK; do
    [[ -v "\$name" ]] && printf '%s\n' "\$name" >>"\$AFK_TEST_GIT_ENV_MARKER"
  done
  # The client sets its own GIT_SSH_COMMAND for the fetch; only the ambient one is poison.
  [[ "\${GIT_SSH_COMMAND:-}" == *git-poison* ]] && printf 'GIT_SSH_COMMAND\n' >>"\$AFK_TEST_GIT_ENV_MARKER"
fi
anchor_fetch=false
for arg in "\$@"; do [[ "\$arg" == '+refs/heads/master:refs/afk/fetched' ]] && anchor_fetch=true; done
if [[ "\$anchor_fetch" == true ]]; then
  if [[ -n "\${AFK_TEST_SSH_CAPTURE:-}" ]]; then
    # Run the transport command the way git does, against the stub ssh.
    printf '%s' "\${GIT_SSH_COMMAND:-}" >"\$AFK_TEST_SSH_CAPTURE.command"
    /bin/sh -c "\$GIT_SSH_COMMAND"' "\$@"' ssh git@github.com "git-upload-pack 'jlengelbrecht/agent-flow-kit.git'" ||
      { printf 'fatal: Could not read from remote repository.\n' >&2; exit 128; }
  fi
  [[ -z "\${AFK_TEST_FETCH_EXECUTED:-}" ]] || : >"\$AFK_TEST_FETCH_EXECUTED"
  [[ -z "\${AFK_TEST_FETCH_FAIL:-}" ]] || exit 73
  if [[ -n "\${AFK_TEST_FETCH_ORPHAN_START:-}" ]]; then
    (
      trap '[[ -z "\${AFK_TEST_FETCH_ORPHAN_TERMINATING:-}" ]] || : >"\$AFK_TEST_FETCH_ORPHAN_TERMINATING"; while [[ ! -e "\${AFK_TEST_FETCH_ORPHAN_RELEASE:-}" ]]; do sleep 0.02; done; exit 0' TERM
      : >"\$AFK_TEST_FETCH_ORPHAN_START"
      while [[ ! -e "\${AFK_TEST_FETCH_ORPHAN_RELEASE:-}" ]]; do sleep 0.02; done
    ) &
    exit 0
  fi
  if [[ -n "\${AFK_TEST_FETCH_PARKED:-}" ]]; then
    trap '[[ -n "\${AFK_TEST_CHILD_TERMINATING:-}" ]] && : >"\$AFK_TEST_CHILD_TERMINATING"; while [[ ! -e "\${AFK_TEST_FETCH_RELEASE:-}" ]]; do sleep 0.02; done; exit 143' TERM
    : >"\$AFK_TEST_FETCH_PARKED"
    while [[ ! -e "\${AFK_TEST_FETCH_RELEASE:-}" ]]; do sleep 0.02; done
  fi
  remote='file://$REMOTE'
  [[ -e '$OFFLINE_MARKER' ]] && remote='file://$TMP/offline-remote'
  args=("\$@")
  for ((i=0; i<\${#args[@]}; i++)); do
    [[ "\${args[i]}" == origin ]] && args[i]="\$remote"
  done
  exec '$REAL_GIT' "\${args[@]}"
fi
exec '$REAL_GIT' "\$@"
EOF
chmod +x "$TEST_BIN/git"
# Stub ssh: records the argv and agent visibility it was started with.
cat >"$TEST_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$AFK_TEST_SSH_CAPTURE.argv"
[[ -v SSH_AUTH_SOCK ]] && printf 'SSH_AUTH_SOCK\n' >>"$AFK_TEST_SSH_CAPTURE.argv"
if [[ -n "${AFK_TEST_SSH_STDERR:-}" ]]; then printf '%s\n' "$AFK_TEST_SSH_STDERR" >&2; exit 255; fi
exit 0
EOF
chmod +x "$TEST_BIN/ssh"
RELEASE_CLIENT="$TMP/afk-release-reconcile-fixture"
cp "$AUTHOR/bin/afk-release-reconcile" "$RELEASE_CLIENT"
cp "$AUTHOR/bin/afk-release-known-hosts" "$TMP/afk-release-known-hosts"
sed -i \
  -e "s|readonly GIT_BIN='/usr/bin/git'|readonly GIT_BIN='$TEST_BIN/git'|" \
  -e "s|readonly SSH_BIN='/usr/bin/ssh'|readonly SSH_BIN='$TEST_BIN/ssh'|" \
  -e "s|^readonly TRUSTED_DRIVER_SOURCE=.*|readonly TRUSTED_DRIVER_SOURCE='$TRUSTED_DRIVER_SOURCE'|" \
  -e "s|readonly REQUIRE_TRUSTED_TOOLS=true|readonly REQUIRE_TRUSTED_TOOLS=false|" \
  "$RELEASE_CLIENT"
chmod +x "$RELEASE_CLIENT"
mkdir -p "$HOME_TEST/.agents/skills/model-router" "$HOME_TEST/.claude" "$HOME_TEST/.codex"
: >"$HOME_TEST/.claude/CLAUDE.md"; : >"$HOME_TEST/.codex/AGENTS.md"
jq -nc --arg base "$BASE" --arg home "$HOME_TEST" --arg runtime "$TRUSTED_DRIVER_SOURCE" \
  --arg bin_identity "$TRUSTED_BIN_IDENTITY" --arg lib_identity "$TRUSTED_LIB_IDENTITY" \
  '{schema_version:"1.0",repository_identity:"rootcommit:d74e7f9542cfe2731e09a0ff5c5e1b4cf325062f",applied_revision:$base,
    components:{
      "afk-runtime-bin":{path:($runtime+"/bin"),identity:$bin_identity},
      "afk-runtime-lib":{path:($runtime+"/lib"),identity:$lib_identity},
      "model-router":{path:($home+"/.agents/skills/model-router")},
      "claude-global-policy":{path:($home+"/.claude/CLAUDE.md")},
      "codex-global-guidance":{path:($home+"/.codex/AGENTS.md")}
    }}' >"$STATE/state.json"
git clone -q "$ROOT" "$USER_CLONE"
printf 'user dirt survives\n' >"$USER_CLONE/USER-DIRT"

run_update() {
  RUN_OUT="$(HOME="$HOME_TEST" AFK_STATE_DIR="$STATE" \
    AFK_LIB_DIR="$TMP/poison/lib" AFK_KIT_ROOT="$TMP/poison" \
    AFK_MANIFEST="$TMP/poison/manifest" AFK_JOURNAL="$TMP/poison/journal" \
    AFK_LOCK_DIR="$TMP/poison/lock" AFK_BACKUP_ROOT="$TMP/poison/backups" \
    AFK_STAGE_ROOT="$TMP/poison/stage" AFK_SKILLS_HOME="$TMP/poison/skills" \
    AFK_CLAUDE_HOME="$TMP/poison/claude" AFK_CODEX_HOME="$TMP/poison/codex" \
    AFK_ORCA_BIN="$TMP/poison/orca" AFK_TEST_ROLLBACK=true \
    "$RELEASE_CLIENT" "$@" 2>"$TMP/stderr")"
}

GIT_POISON_ROOT="$TMP/git-poison"; mkdir -p "$GIT_POISON_ROOT/worktree" "$GIT_POISON_ROOT/objects"
GIT_POISON_MARKER="$TMP/git-poison-environment"
GIT_DIR="$GIT_POISON_ROOT/repository" GIT_COMMON_DIR="$GIT_POISON_ROOT/common" \
  GIT_WORK_TREE="$GIT_POISON_ROOT/worktree" GIT_INDEX_FILE="$GIT_POISON_ROOT/index" \
  GIT_OBJECT_DIRECTORY="$GIT_POISON_ROOT/objects" \
  GIT_ALTERNATE_OBJECT_DIRECTORIES="$GIT_POISON_ROOT/alternates" \
  GIT_NAMESPACE=poison GIT_CEILING_DIRECTORIES=/ GIT_DISCOVERY_ACROSS_FILESYSTEM=1 \
  GIT_ASKPASS="$GIT_POISON_ROOT/askpass" SSH_ASKPASS="$GIT_POISON_ROOT/ssh-askpass" \
  GIT_SSH_COMMAND="$GIT_POISON_ROOT/ssh" \
  GIT_CONFIG_PARAMETERS="'core.hooksPath'='/tmp/poison-hooks'" GIT_CONFIG_COUNT=1 \
  GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/tmp/poison-hooks \
  GIT_SSL_CAINFO="$GIT_POISON_ROOT/ca" GIT_SSL_CAPATH="$GIT_POISON_ROOT/capath" \
  GIT_PROXY_COMMAND="$GIT_POISON_ROOT/proxy" GIT_EXEC_PATH="$GIT_POISON_ROOT/exec" \
  AFK_TEST_GIT_ENV_MARKER="$GIT_POISON_MARKER" \
  run_update --apply --policy "$AUTHOR/lifecycle/release-policy.json"
assert_eq 'online apply converges' "$(jq -r .state <<<"$RUN_OUT")" CONVERGED
if [[ ! -e "$GIT_POISON_MARKER" && ! -e "$GIT_POISON_ROOT/index" &&
      -z "$(find "$GIT_POISON_ROOT/worktree" "$GIT_POISON_ROOT/objects" -mindepth 1 -print -quit)" ]]; then
  ok 'Git execution ignores all ambient repository and helper controls'
else
  not_ok 'Git execution ignores all ambient repository and helper controls'
fi
assert_eq 'target comes from the exact ref' "$(jq -r .target_revision <<<"$RUN_OUT")" "$TARGET_ONE"
assert_eq 'verified success advances installed revision' "$(jq -r .applied_revision "$STATE/state.json")" "$TARGET_ONE"
assert_eq 'verified success records last-good' "$(jq -r '.last_good_verified' <<<"$RUN_OUT")" true
EXPECTED_PLAN="sha256:$(printf '%s' "$TARGET_ONE" | sha256sum | awk '{print $1}')"
assert_eq 'apply executes the exact qualified plan identity' "$(jq -r .plan_identity <<<"$RUN_OUT")" "$EXPECTED_PLAN"
assert_eq 'candidate lifecycle ignores poisoned inherited roots' "$(jq -r .operation.id <<<"$RUN_OUT")" test-apply
assert_file_contains 'unrelated user clone dirt is untouched' "$USER_CLONE/USER-DIRT" 'user dirt survives'
assert_eq 'attempt document is private' "$(stat -c %a "$STATE/releases/latest.json")" 600

run_update --apply --policy "$AUTHOR/lifecycle/release-policy.json"
assert_eq 'same revision is an idempotent current result' "$(jq -r .state <<<"$RUN_OUT")" CURRENT
assert_eq 'frequent session path is throttled after local proof' "$(jq -r .reason <<<"$RUN_OUT")" CHECK_INTERVAL_NOT_ELAPSED
assert_eq 'cohort is explicitly non-authoritative' "$(jq -r .rollout_authoritative <<<"$RUN_OUT")" false

accepted_path="$(jq -r .candidate_path "$STATE/releases/current.json")"
printf 'not qualified\n' >"$accepted_path/UNTRACKED-QUALIFICATION-INPUT"
run_update --apply --policy "$AUTHOR/lifecycle/release-policy.json"
assert_eq 'an untracked candidate file defeats the throttle proof' "$(jq -r .reason <<<"$RUN_OUT")" ALREADY_CURRENT
if find "$STATE/releases/candidates" -maxdepth 1 -type d -name 'quarantine.*' | grep -q .; then ok 'dirty candidate is quarantined'; else not_ok 'dirty candidate is quarantined'; fi
if [[ ! -e "$(jq -r .candidate_path "$STATE/releases/current.json")/UNTRACKED-QUALIFICATION-INPUT" ]]; then ok 'replacement candidate is entirely clean'; else not_ok 'replacement candidate is entirely clean'; fi

# Mirror-local rewrites are refused even though the stored remote remains the
# literal anchor. Remove the injected test value afterward to continue.
"$REAL_GIT" --git-dir="$STATE/releases/repository.git" config --add url.file:///untrusted.insteadOf ssh://git@github.com/
run_update --apply --force-check --policy "$AUTHOR/lifecycle/release-policy.json"
assert_eq 'mirror-local URL rewrite is refused' "$(jq -r .reason <<<"$RUN_OUT")" RELEASE_MIRROR_UNTRUSTED
"$REAL_GIT" --git-dir="$STATE/releases/repository.git" config --unset-all url.file:///untrusted.insteadOf

# A demonstrably dead lock owner is recoverable; ambiguous locks are not.
host="$(hostname 2>/dev/null || uname -n)"; machine="$(cat /etc/machine-id 2>/dev/null || true)"
boot="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || awk '/^btime / {print $2}' /proc/stat)"
mkdir "$STATE/releases/lock"
start="proc:$(sed 's/^.*) //' "/proc/$$/stat" | awk '{print $20}')"
jq -nc --arg host "$host|$machine" --arg boot "$boot" --arg start "$start" --argjson pid "$$" '{schema:"afk-release-lock/1",complete:true,host:$host,boot:$boot,pid:$pid,process_start:$start,incarnation:"live-owner"}' >"$STATE/releases/lock/owner.json"
LATEST_BEFORE_LOCK="$(sha256sum "$STATE/releases/latest.json" | awk '{print $1}')"
run_update --apply --force-check --policy "$AUTHOR/lifecycle/release-policy.json"
assert_eq 'live lock owner is retained without takeover' "$(jq -r .reason <<<"$RUN_OUT")" CONCURRENT_OPERATION_IN_PROGRESS
assert_eq 'lock contender does not replace shared latest result' "$(sha256sum "$STATE/releases/latest.json" | awk '{print $1}')" "$LATEST_BEFORE_LOCK"
rm -rf "$STATE/releases/lock"
mkdir "$STATE/releases/lock"
jq -nc --arg host "$host|$machine" --arg boot "$boot" '{schema:"afk-release-lock/1",complete:true,host:$host,boot:$boot,pid:99999999,process_start:"proc:1",incarnation:"dead-owner"}' >"$STATE/releases/lock/owner.json"
run_update --apply --force-check --policy "$AUTHOR/lifecycle/release-policy.json"
assert_eq 'dead same-host lock is recovered' "$(jq -r .state <<<"$RUN_OUT")" CURRENT

# The deploy key is the only credential channel. Capture the exact transport
# command and the argv ssh receives while an ambient agent socket and a user
# ssh config are both present; neither may reach git or ssh.
SSH_CAPTURE="$TMP/ssh-capture"
SSH_AUTH_SOCK="$TMP/poison-agent.sock" AFK_TEST_SSH_CAPTURE="$SSH_CAPTURE" \
  AFK_TEST_GIT_ENV_MARKER="$TMP/ssh-env-marker" \
  run_update --plan --force-check --policy "$AUTHOR/lifecycle/release-policy.json"
assert_eq 'deploy-key fetch reaches a verified plan' "$(jq -r .reason <<<"$RUN_OUT")" PLAN_VERIFIED_NO_CHANGE
EXPECTED_SSH_OPTIONS=(-o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$TMP/afk-release-known-hosts" -o GlobalKnownHostsFile=/dev/null
  -o UpdateHostKeys=no -o PreferredAuthentications=publickey -o BatchMode=yes -o ConnectTimeout=10)
assert_eq 'GIT_SSH_COMMAND has the exact pinned shape' "$(cat "$SSH_CAPTURE.command" 2>/dev/null)" \
  "'$TEST_BIN/ssh' -F /dev/null -i '$DEPLOY_KEY_FILE' -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=yes -o UserKnownHostsFile='$TMP/afk-release-known-hosts' -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no -o PreferredAuthentications=publickey -o BatchMode=yes -o ConnectTimeout=10"
assert_eq 'ssh gets only the deploy key, pinned host keys, and no user config or agent' \
  "$(cat "$SSH_CAPTURE.argv" 2>/dev/null)" \
  "$(printf '%s\n' -F /dev/null -i "$DEPLOY_KEY_FILE" "${EXPECTED_SSH_OPTIONS[@]}" \
    git@github.com "git-upload-pack 'jlengelbrecht/agent-flow-kit.git'")"
if [[ ! -e "$TMP/ssh-env-marker" ]]; then ok 'ambient ssh agent never reaches git'; else not_ok 'ambient ssh agent never reaches git'; fi

# Resolve the captured command with the real ssh client (-G prints the final
# configuration and exits) while the poison ~/.ssh/config is present.
REAL_SSH="$(command -v ssh 2>/dev/null || true)"
if [[ -n "$REAL_SSH" ]]; then
  captured_ssh="$(cat "$SSH_CAPTURE.command" 2>/dev/null)"
  resolved_ssh="$(env -i PATH=/usr/bin:/bin HOME="$HOME_TEST" /bin/sh -c \
    "'$REAL_SSH'${captured_ssh#"'$TEST_BIN/ssh'"}"' -G git@github.com' 2>/dev/null || true)"
  for expected_line in "identityfile $DEPLOY_KEY_FILE" \
      "userknownhostsfile $TMP/afk-release-known-hosts" "globalknownhostsfile /dev/null" \
      "identityagent none" "preferredauthentications publickey"; do
    if grep -Fxq -- "$expected_line" <<<"$resolved_ssh"; then ok "real ssh resolves: $expected_line"
    else not_ok "real ssh resolves: $expected_line"; fi
  done
  assert_eq 'real ssh resolves exactly one identity file' "$(grep -c '^identityfile ' <<<"$resolved_ssh")" 1
  if ! grep -E '^(proxycommand|controlpath) ' <<<"$resolved_ssh" | grep -vqE ' none$'; then
    ok 'real ssh resolves no proxy command or control path'
  else
    not_ok 'real ssh resolves no proxy command or control path'
  fi
else
  printf 'skip - real ssh -G resolution: no ssh client on this host\n'
fi

# Fetch stderr is classified by fixed strings and never persisted.
STDERR_MARKER='afk-test-ssh-stderr-marker'
fetch_stderr_case() { # <label> <stub ssh stderr> <expected state:reason>
  AFK_TEST_SSH_CAPTURE="$TMP/ssh-class" AFK_TEST_SSH_STDERR="$2 $STDERR_MARKER" \
    run_update --plan --force-check --policy "$AUTHOR/lifecycle/release-policy.json"
  assert_eq "$1" "$(jq -r '.state+":"+.reason' <<<"$RUN_OUT")" "$3"
}
fetch_stderr_case 'changed host key is HOST_KEY_MISMATCH' \
  '@@@@@@@@@@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@@@@@@@@@@' BLOCKED:HOST_KEY_MISMATCH
fetch_stderr_case 'unknown host key is HOST_KEY_MISMATCH' \
  'Host key verification failed.' BLOCKED:HOST_KEY_MISMATCH
fetch_stderr_case 'rejected key is DEPLOY_KEY_REJECTED' \
  'git@github.com: Permission denied (publickey).' BLOCKED:DEPLOY_KEY_REJECTED
fetch_stderr_case 'unreadable repository is REPOSITORY_ACCESS_DENIED' \
  'ERROR: Repository not found.' BLOCKED:REPOSITORY_ACCESS_DENIED
fetch_stderr_case 'other transport failure stays FETCH_UNAVAILABLE' \
  'ssh: connect to host github.com port 22: Network is unreachable' RETAINED:FETCH_UNAVAILABLE
if ! grep -rqF -e "$STDERR_MARKER" "$STATE/releases/attempts" "$STATE/releases/latest.json"; then
  ok 'fetch stderr is never persisted'
else
  not_ok 'fetch stderr is never persisted'
fi
if [[ -z "$(find "$STATE/releases" -maxdepth 1 -name '.child-output.*' -print -quit)" ]]; then
  ok 'fetch stderr scratch file is removed'
else
  not_ok 'fetch stderr scratch file is removed'
fi

# A missing, group/world-readable, symlinked, or state-tree key is refused with
# its own reason before any network attempt, so "no key" never reads as "offline".
KEY_FETCH_MARKER="$TMP/key-fetch-executed"
key_refusal() { # <label> <key path>
  rm -f "$KEY_FETCH_MARKER"
  AFK_RELEASE_DEPLOY_KEY="$2" AFK_TEST_FETCH_EXECUTED="$KEY_FETCH_MARKER" \
    run_update --plan --force-check --policy "$AUTHOR/lifecycle/release-policy.json"
  assert_eq "$1 is refused as DEPLOY_KEY_UNAVAILABLE" \
    "$(jq -r '.state+":"+.reason' <<<"$RUN_OUT")" BLOCKED:DEPLOY_KEY_UNAVAILABLE
  if [[ ! -e "$KEY_FETCH_MARKER" ]]; then ok "$1 never attempts a fetch"; else not_ok "$1 never attempts a fetch"; fi
}
key_refusal 'missing deploy key' "$TMP/no-such-key"
cp "$DEPLOY_KEY_FILE" "$TMP/wide-key"; chmod 644 "$TMP/wide-key"
key_refusal 'mode 0644 deploy key' "$TMP/wide-key"
ln -s "$DEPLOY_KEY_FILE" "$TMP/linked-key"
key_refusal 'symlinked deploy key' "$TMP/linked-key"
(umask 077; cp "$DEPLOY_KEY_FILE" "$STATE/deploy-key"); chmod 600 "$STATE/deploy-key"
key_refusal 'deploy key inside the release state tree' "$STATE/deploy-key"
ln -s "$STATE" "$HOME_TEST/state-link"
key_refusal 'state-tree key behind a symlinked parent' "$HOME_TEST/state-link/deploy-key"
key_refusal 'state-tree key reached through ..' "$DEPLOY_KEY_DIR/../../../.local/state/agent-flow-kit/deploy-key"
rm -f "$STATE/deploy-key" "$HOME_TEST/state-link"
mkdir -p "$HOME_TEST/shared-keys"; chmod 775 "$HOME_TEST/shared-keys"
(umask 077; cp "$DEPLOY_KEY_FILE" "$HOME_TEST/shared-keys/key"); chmod 600 "$HOME_TEST/shared-keys/key"
key_refusal 'deploy key under a group-writable directory' "$HOME_TEST/shared-keys/key"
if ! grep -rqF -e "$DEPLOY_KEY_MARKER" -e "$DEPLOY_KEY_DIR" -e "$TMP/wide-key" -e "$TMP/linked-key" \
    -e "$TMP/no-such-key" -e "$STATE/deploy-key" "$STATE/releases/attempts" "$STATE/releases/latest.json"; then
  ok 'release results carry no key material or key path'
else
  not_ok 'release results carry no key material or key path'
fi

# Paths that OpenSSH would re-parse inside an option value are refused, with
# their own reason, before any fetch.
unsafe_path_refusal() { # <label> <key path>
  rm -f "$KEY_FETCH_MARKER"
  AFK_RELEASE_DEPLOY_KEY="$2" AFK_TEST_FETCH_EXECUTED="$KEY_FETCH_MARKER" \
    run_update --plan --force-check --policy "$AUTHOR/lifecycle/release-policy.json"
  assert_eq "$1 is refused as SSH_OPTION_PATH_UNSAFE" \
    "$(jq -r '.state+":"+.reason' <<<"$RUN_OUT")" BLOCKED:SSH_OPTION_PATH_UNSAFE
  if [[ ! -e "$KEY_FETCH_MARKER" ]]; then ok "$1 never attempts a fetch"; else not_ok "$1 never attempts a fetch"; fi
}
unsafe_path_refusal 'key path with a space' "$TMP/deploy key"
unsafe_path_refusal 'key path with a tab' "$TMP/deploy"$'\t'"key"
unsafe_path_refusal 'key path with a single quote' "$TMP/deploy'key"
unsafe_path_refusal 'key path with a double quote' "$TMP/deploy\"key"
unsafe_path_refusal 'key path with a backslash' "$TMP/deploy\\key"
unsafe_path_refusal 'key path with a percent sign' "$TMP/deploy%dkey"
unsafe_path_refusal 'key path with a hash' "$TMP/deploy#key"
SAFE_RELEASE_CLIENT="$RELEASE_CLIENT"
for unsafe_dir in "$TMP/pinned hosts" "$TMP/pinned%hhosts"; do
  mkdir -p "$unsafe_dir"
  cp -p "$SAFE_RELEASE_CLIENT" "$TMP/afk-release-known-hosts" "$unsafe_dir/"
  RELEASE_CLIENT="$unsafe_dir/${SAFE_RELEASE_CLIENT##*/}"
  unsafe_path_refusal "pinned known_hosts under ${unsafe_dir##*/}" "$DEPLOY_KEY_FILE"
done
RELEASE_CLIENT="$SAFE_RELEASE_CLIENT"

# A policy that repeats the legacy HTTPS anchor no longer matches the compiled one.
jq '.trust.remote_url="https://github.com/jlengelbrecht/agent-flow-kit.git"' \
  "$AUTHOR/lifecycle/release-policy.json" >"$TMP/legacy-anchor-policy.json"
legacy_policy_rc=0
LEGACY_POLICY_OUT="$(HOME="$HOME_TEST" AFK_STATE_DIR="$STATE" "$RELEASE_CLIENT" --plan \
  --policy "$TMP/legacy-anchor-policy.json" 2>/dev/null)" || legacy_policy_rc=$?
assert_eq 'policy/compiled anchor mismatch refuses' \
  "$(jq -r .reason <<<"$LEGACY_POLICY_OUT"):$legacy_policy_rc" POLICY_UNTRUSTED:2

# A mirror created by the HTTPS-anchored client is migrated in place; any other
# stored origin is still refused.
MIRROR="$STATE/releases/repository.git"
"$REAL_GIT" --git-dir="$MIRROR" config remote.origin.url https://github.com/jlengelbrecht/agent-flow-kit.git
run_update --plan --force-check --policy "$AUTHOR/lifecycle/release-policy.json"
assert_eq 'legacy HTTPS mirror is migrated, not refused' "$(jq -r .reason <<<"$RUN_OUT")" PLAN_VERIFIED_NO_CHANGE
assert_eq 'migrated mirror stores the SSH anchor' \
  "$("$REAL_GIT" --git-dir="$MIRROR" config --get remote.origin.url)" ssh://git@github.com/jlengelbrecht/agent-flow-kit.git
"$REAL_GIT" --git-dir="$MIRROR" config remote.origin.url https://github.com/someone-else/agent-flow-kit.git
run_update --plan --force-check --policy "$AUTHOR/lifecycle/release-policy.json"
assert_eq 'a foreign stored origin is still refused' "$(jq -r .reason <<<"$RUN_OUT")" RELEASE_MIRROR_UNTRUSTED
"$REAL_GIT" --git-dir="$MIRROR" config remote.origin.url ssh://git@github.com/jlengelbrecht/agent-flow-kit.git

# Bootstrap trust decisions never invoke a same-named command supplied by PATH
# or an exported shell function. The fixed absolute helpers remain the only
# realpath/stat/jq/date executables used by the release client; even helpers
# used to enumerate imported functions are forced through Bash builtins.
POISON_BIN="$TMP/bootstrap-poison-bin"; POISON_MARKER="$TMP/bootstrap-poisoned"
mkdir "$POISON_BIN"
for poison_tool in realpath stat jq date cat; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$0" >>"$AFK_TEST_POISON_MARKER"\nexit 99\n' >"$POISON_BIN/$poison_tool"
  chmod +x "$POISON_BIN/$poison_tool"
done
printf '#!/bin/bash -p\nprintf "%%s\\n" "$0" >>"$AFK_TEST_POISON_MARKER"\nexit 99\n' \
  >"$POISON_BIN/bash"
chmod +x "$POISON_BIN/bash"
BASH_ENV_POISON="$TMP/bash-env-poison"
printf 'printf "bash-env\\n" >>"$AFK_TEST_POISON_MARKER"\n' >"$BASH_ENV_POISON"
(
  realpath() { printf 'function-realpath\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  stat() { printf 'function-stat\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  jq() { printf 'function-jq\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  date() { printf 'function-date\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  cat() { printf 'function-cat\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  compgen() { printf 'function-compgen\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  mapfile() { printf 'function-mapfile\n' >>"$AFK_TEST_POISON_MARKER"; return 99; }
  export -f realpath stat jq date cat compgen mapfile
  PATH="$POISON_BIN:$PATH" BASH_ENV="$BASH_ENV_POISON" \
    AFK_TEST_POISON_MARKER="$POISON_MARKER" \
    HOME="$HOME_TEST" AFK_STATE_DIR="$STATE" "$RELEASE_CLIENT" --plan --force-check \
    --policy "$AUTHOR/lifecycle/release-policy.json" >"$TMP/bootstrap-poison.out"
)
assert_eq 'fixed bootstrap helpers ignore PATH and function poisoning' \
  "$([[ -e "$POISON_MARKER" ]] && wc -c <"$POISON_MARKER" || printf 0)" 0
assert_eq 'poison-resistant release check completes' \
  "$(jq -r .state "$TMP/bootstrap-poison.out")" CURRENT

UNTRUSTED_DATE_ROOT="$TMP/user-owned-date"; mkdir -p "$UNTRUSTED_DATE_ROOT"
UNTRUSTED_DATE_MARKER="$TMP/user-owned-date-executed"
printf '#!/usr/bin/env bash\nprintf invoked >%q\nexit 99\n' \
  "$UNTRUSTED_DATE_MARKER" >"$UNTRUSTED_DATE_ROOT/date"
chmod +x "$UNTRUSTED_DATE_ROOT/date"
UNTRUSTED_DATE_CLIENT="$TMP/untrusted-date-release-client"
cp "$ROOT/bin/afk-release-reconcile" "$UNTRUSTED_DATE_CLIENT"
sed -i "s|readonly DATE_BIN='/usr/bin/date'|readonly DATE_BIN='$UNTRUSTED_DATE_ROOT/date'|" \
  "$UNTRUSTED_DATE_CLIENT"
chmod +x "$UNTRUSTED_DATE_CLIENT"
UNTRUSTED_DATE_STATE="$TMP/untrusted-date-state"
set +e
UNTRUSTED_DATE_OUT="$(AFK_STATE_DIR="$UNTRUSTED_DATE_STATE" \
  "$UNTRUSTED_DATE_CLIENT" --plan --force-check)"
untrusted_date_rc=$?
set -e
assert_eq 'user-owned fixed date is rejected before reconciliation' \
  "$untrusted_date_rc:$(jq -r '.state+":"+.reason' <<<"$UNTRUSTED_DATE_OUT")" \
  '2:BLOCKED:REQUIRED_TOOL_UNTRUSTED'
if [[ ! -e "$UNTRUSTED_DATE_MARKER" && ! -e "$UNTRUSTED_DATE_STATE" ]]; then
  ok 'untrusted release tool is neither executed nor allowed to write state'
else
  not_ok 'untrusted release tool is neither executed nor allowed to write state'
fi

DRIFTED_DRIVER_BACKUP="$TMP/trusted-driver-backup"
cp "$TRUSTED_DRIVER_SOURCE/bin/agent-flow-kit" "$DRIFTED_DRIVER_BACKUP"
DRIFTED_DRIVER_MARKER="$TMP/drifted-installed-driver-executed"
printf '#!/bin/bash -p\nprintf invoked >%q\nexit 99\n' \
  "$DRIFTED_DRIVER_MARKER" >"$TRUSTED_DRIVER_SOURCE/bin/agent-flow-kit"
chmod +x "$TRUSTED_DRIVER_SOURCE/bin/agent-flow-kit"
APPLIED_BEFORE_DRIVER_DRIFT="$(jq -r .applied_revision "$STATE/state.json")"
set +e
run_update --plan --force-check --policy "$AUTHOR/lifecycle/release-policy.json"
DRIFTED_DRIVER_RC=$?
set -e
assert_eq 'syntactically valid installed driver drift is refused' \
  "$DRIFTED_DRIVER_RC:$(jq -r .reason <<<"$RUN_OUT")" \
  '2:TRUSTED_DRIVER_UNAVAILABLE'
assert_eq 'driver drift refusal retains installed revision' \
  "$(jq -r .applied_revision "$STATE/state.json")" "$APPLIED_BEFORE_DRIVER_DRIFT"
if [[ ! -e "$DRIFTED_DRIVER_MARKER" ]]; then
  ok 'modified installed driver is never executed'
else
  not_ok 'modified installed driver is never executed'
fi
cp "$DRIFTED_DRIVER_BACKUP" "$TRUSTED_DRIVER_SOURCE/bin/agent-flow-kit"
chmod +x "$TRUSTED_DRIVER_SOURCE/bin/agent-flow-kit"

# A copy-time mutation lands only in the private snapshot. Snapshot identities
# must be checked before even syntax-checking that copied executable.
SNAPSHOT_MISMATCH_MARKER="$TMP/snapshot-mismatch-executed"
SNAPSHOT_MUTATING_CP="$TMP/snapshot-mutating-cp"
cat >"$SNAPSHOT_MUTATING_CP" <<EOF
#!/bin/bash -p
/usr/bin/cp "\$@" || exit \$?
source_path=''
destination=''
for arg in "\$@"; do
  [[ "\$arg" == */bin/. ]] && source_path="\$arg"
  destination="\$arg"
done
if [[ -n "\$source_path" ]]; then
  printf '#!/bin/bash -p\nprintf executed >%q\nexit 99\n' '$SNAPSHOT_MISMATCH_MARKER' \
    >"\${destination%/}/agent-flow-kit"
  chmod +x "\${destination%/}/agent-flow-kit"
fi
EOF
chmod +x "$SNAPSHOT_MUTATING_CP"
SNAPSHOT_MISMATCH_CLIENT="$TMP/snapshot-mismatch-release-client"
cp "$RELEASE_CLIENT" "$SNAPSHOT_MISMATCH_CLIENT"
sed -i "s|readonly CP_BIN='/usr/bin/cp'|readonly CP_BIN='$SNAPSHOT_MUTATING_CP'|" \
  "$SNAPSHOT_MISMATCH_CLIENT"
chmod +x "$SNAPSHOT_MISMATCH_CLIENT"
set +e
SNAPSHOT_MISMATCH_OUT="$(HOME="$HOME_TEST" AFK_STATE_DIR="$STATE" \
  "$SNAPSHOT_MISMATCH_CLIENT" --plan --force-check \
  --policy "$AUTHOR/lifecycle/release-policy.json" 2>"$TMP/snapshot-mismatch.err")"
SNAPSHOT_MISMATCH_RC=$?
set -e
assert_eq 'copy-time trusted snapshot mutation is refused' \
  "$SNAPSHOT_MISMATCH_RC:$(jq -r .reason <<<"$SNAPSHOT_MISMATCH_OUT")" \
  '2:TRUSTED_DRIVER_UNAVAILABLE'
if [[ ! -e "$SNAPSHOT_MISMATCH_MARKER" ]]; then
  ok 'mismatched trusted snapshot is never syntax-checked or executed'
else
  not_ok 'mismatched trusted snapshot is never syntax-checked or executed'
fi
if ! find "$STATE/releases" -maxdepth 1 -type d -name '.trusted-driver.*' | grep -q .; then
  ok 'mismatched trusted snapshot is removed'
else
  not_ok 'mismatched trusted snapshot is removed'
fi

# A tracked command leader may exit after leaving a same-group descendant. The
# lock and ACTIVE group record remain until the descendant has been terminated
# and drained.
ORPHAN_START="$TMP/fetch-orphan-start"; ORPHAN_TERMINATING="$TMP/fetch-orphan-terminating"
ORPHAN_RELEASE="$TMP/fetch-orphan-release"
HOME="$HOME_TEST" AFK_STATE_DIR="$STATE" \
  AFK_TEST_FETCH_ORPHAN_START="$ORPHAN_START" \
  AFK_TEST_FETCH_ORPHAN_TERMINATING="$ORPHAN_TERMINATING" \
  AFK_TEST_FETCH_ORPHAN_RELEASE="$ORPHAN_RELEASE" \
  "$RELEASE_CLIENT" --plan --force-check --policy "$AUTHOR/lifecycle/release-policy.json" \
  >"$TMP/orphan.out" 2>"$TMP/orphan.err" &
orphan_owner=$!
for _ in {1..500}; do [[ -e "$ORPHAN_TERMINATING" ]] && break; sleep 0.01; done
if [[ -e "$ORPHAN_START" && -e "$ORPHAN_TERMINATING" && -d "$STATE/releases/lock" ]] \
  && [[ "$(jq -r '.child.state // ""' "$STATE/releases/lock/owner.json")" == ACTIVE ]]; then
  ok 'leader exit retains ACTIVE lock while descendant drains'
else
  not_ok 'leader exit retains ACTIVE lock while descendant drains'
fi
touch "$ORPHAN_RELEASE"
set +e; wait "$orphan_owner"; orphan_rc=$?; set -e
assert_eq 'leader-exit descendant is drained before completion' "$orphan_rc" 0
if [[ ! -d "$STATE/releases/lock" ]]; then ok 'leader-exit lock releases after group drain'; else not_ok 'leader-exit lock releases after group drain'; fi

# If the owning shell is killed after ACTIVE publication, a live child group is
# still ownership. A contender must refuse until that exact group exits.
KILLED_PARKED="$TMP/killed-parent-parked"; KILLED_RELEASE="$TMP/killed-parent-release"
HOME="$HOME_TEST" AFK_STATE_DIR="$STATE" AFK_TEST_FETCH_PARKED="$KILLED_PARKED" \
  AFK_TEST_FETCH_RELEASE="$KILLED_RELEASE" "$RELEASE_CLIENT" --plan --force-check \
  --policy "$AUTHOR/lifecycle/release-policy.json" >"$TMP/killed-parent.out" 2>"$TMP/killed-parent.err" &
killed_parent=$!
for _ in {1..500}; do [[ -e "$KILLED_PARKED" ]] && break; sleep 0.01; done
assert_eq 'killed-parent fixture publishes ACTIVE group' \
  "$(jq -r '.child.state // ""' "$STATE/releases/lock/owner.json" 2>/dev/null)" ACTIVE
kill -KILL "$killed_parent"
set +e; wait "$killed_parent"; killed_parent_rc=$?; set -e
assert_eq 'parent is killed after ACTIVE publication' "$killed_parent_rc" 137
run_update --plan --force-check --policy "$AUTHOR/lifecycle/release-policy.json"
assert_eq 'live orphan group prevents stale-lock reclaim' \
  "$(jq -r .reason <<<"$RUN_OUT")" CONCURRENT_OPERATION_IN_PROGRESS
touch "$KILLED_RELEASE"
killed_reclaimed=false
for _ in {1..1000}; do
  run_update --plan --force-check --policy "$AUTHOR/lifecycle/release-policy.json"
  if [[ "$(jq -r .reason <<<"$RUN_OUT")" != CONCURRENT_OPERATION_IN_PROGRESS ]]; then
    killed_reclaimed=true
    break
  fi
  sleep 0.01
done
assert_eq 'released orphan eventually becomes reclaimable' "$killed_reclaimed" true
assert_eq 'stale lock is reclaimed only after orphan group exits' "$(jq -r .state <<<"$RUN_OUT")" CURRENT

# The pre-ACTIVE window is inert: the wrapper is gated, and parent death makes
# it exit without executing the requested command. Because owner.json still has
# child:null, a successor can safely reclaim rather than inherit a STARTING lock.
PRE_ACTIVE_CLIENT="$TMP/pre-active-client"; PRE_ACTIVE_MARKER="$TMP/pre-active-marker"
PRE_ACTIVE_RELEASE="$TMP/pre-active-release"; PRE_ACTIVE_EXECUTED="$TMP/pre-active-executed"
cp "$RELEASE_CLIENT" "$PRE_ACTIVE_CLIENT"
# shellcheck disable=SC2016 # copied-client fixture retains runtime variables
sed -i 's|child_pre_publish_boundary() { :; }|child_pre_publish_boundary() { printf "%s:%s\\n" "$1" "$2" >"$AFK_TEST_PRE_ACTIVE"; while [[ ! -e "$AFK_TEST_PRE_ACTIVE_RELEASE" ]]; do /bin/sleep 0.01; done; }|' "$PRE_ACTIVE_CLIENT"
chmod +x "$PRE_ACTIVE_CLIENT"
HOME="$HOME_TEST" AFK_STATE_DIR="$STATE" AFK_TEST_PRE_ACTIVE="$PRE_ACTIVE_MARKER" \
  AFK_TEST_PRE_ACTIVE_RELEASE="$PRE_ACTIVE_RELEASE" AFK_TEST_FETCH_EXECUTED="$PRE_ACTIVE_EXECUTED" \
  "$PRE_ACTIVE_CLIENT" --plan --force-check --policy "$AUTHOR/lifecycle/release-policy.json" \
  >"$TMP/pre-active.out" 2>"$TMP/pre-active.err" &
pre_active_parent=$!
for _ in {1..500}; do [[ -e "$PRE_ACTIVE_MARKER" ]] && break; sleep 0.01; done
assert_eq 'pre-ACTIVE fixture leaves child unpublished' \
  "$(jq -r '.child == null' "$STATE/releases/lock/owner.json" 2>/dev/null)" true
kill -KILL "$pre_active_parent"
set +e; wait "$pre_active_parent"; pre_active_rc=$?; set -e
assert_eq 'pre-ACTIVE parent is killed deterministically' "$pre_active_rc" 137
run_update --plan --force-check --policy "$AUTHOR/lifecycle/release-policy.json"
assert_eq 'successor reclaims pre-ACTIVE owner without duplicate launch' "$(jq -r .state <<<"$RUN_OUT")" CURRENT
if [[ ! -e "$PRE_ACTIVE_EXECUTED" ]]; then ok 'gated pre-ACTIVE wrapper never executes command'; else not_ok 'gated pre-ACTIVE wrapper never executes command'; fi
touch "$PRE_ACTIVE_RELEASE"

# Every catchable fatal signal terminates the reconciler after the bounded child
# returns. EXIT alone releases the exact lock and no result is published afterward.
SIGNAL_LATEST="$(sha256sum "$STATE/releases/latest.json" | awk '{print $1}')"
for signal_case in 'HUP:129' 'ABRT:134' 'USR1:138' 'USR2:140' 'PIPE:141' 'ALRM:142' 'TERM:143' 'XCPU:152' 'XFSZ:153' 'VTALRM:154' 'PROF:155'; do
  signal_name="${signal_case%%:*}"; expected_rc="${signal_case#*:}"
  SIGNAL_PARKED="$TMP/fetch-parked-$signal_name"
  SIGNAL_RELEASE="$TMP/fetch-release-$signal_name"
  SIGNAL_TERMINATING="$TMP/fetch-terminating-$signal_name"
  HOME="$HOME_TEST" AFK_STATE_DIR="$STATE" \
    AFK_LIB_DIR="$TMP/poison/lib" AFK_KIT_ROOT="$TMP/poison" \
    AFK_TEST_FETCH_PARKED="$SIGNAL_PARKED" AFK_TEST_FETCH_RELEASE="$SIGNAL_RELEASE" \
    AFK_TEST_CHILD_TERMINATING="$SIGNAL_TERMINATING" \
    "$RELEASE_CLIENT" --plan --force-check \
    --policy "$AUTHOR/lifecycle/release-policy.json" \
    >"$TMP/signal-$signal_name.out" 2>"$TMP/signal-$signal_name.err" &
  signal_pid=$!
  for _ in {1..500}; do [[ -e "$SIGNAL_PARKED" ]] && break; sleep 0.01; done
  if [[ -e "$SIGNAL_PARKED" ]]; then ok "$signal_name fixture reached bounded fetch"; else not_ok "$signal_name fixture reached bounded fetch"; fi
  kill -"$signal_name" "$signal_pid"
  for _ in {1..500}; do [[ -e "$SIGNAL_TERMINATING" ]] && break; sleep 0.01; done
  if [[ -e "$SIGNAL_TERMINATING" && -d "$STATE/releases/lock" ]]; then
    ok "SIG$signal_name retains lock while child group terminates"
  else
    not_ok "SIG$signal_name retains lock while child group terminates"
  fi
  touch "$SIGNAL_RELEASE"
  set +e; wait "$signal_pid"; signal_rc=$?
  assert_eq "SIG$signal_name terminates release reconciliation" "$signal_rc" "$expected_rc"
  if [[ ! -d "$STATE/releases/lock" ]]; then ok "EXIT releases lock after SIG$signal_name"; else not_ok "EXIT releases lock after SIG$signal_name"; fi
  assert_eq "SIG$signal_name attempt does not publish latest result" "$(sha256sum "$STATE/releases/latest.json" | awk '{print $1}')" "$SIGNAL_LATEST"
  assert_eq "SIG$signal_name attempt emits no result document" "$(wc -c <"$TMP/signal-$signal_name.out" | tr -d ' ')" 0
done

# A fetched candidate's lifecycle entry point is data until the trusted
# installed driver copies and verifies it. Even a syntactically valid entry
# point with an immediate host side effect must never run during reconciliation.
cp "$AUTHOR/bin/agent-flow-kit" "$TMP/trusted-agent-flow-kit"
UNQUALIFIED_CANDIDATE_MARKER="$TMP/unqualified-candidate-executed"
printf '%s\n' '#!/usr/bin/env bash' \
  "printf invoked >'$UNQUALIFIED_CANDIDATE_MARKER'" 'exit 99' \
  >"$AUTHOR/bin/agent-flow-kit"
chmod +x "$AUTHOR/bin/agent-flow-kit"
git -C "$AUTHOR" add bin/agent-flow-kit
git -C "$AUTHOR" commit -qm 'test unqualified candidate lifecycle'
git -C "$AUTHOR" push -q test-origin master
run_update --plan --force-check --policy "$AUTHOR/lifecycle/release-policy.json"
assert_eq 'trusted installed driver plans candidate content' "$(jq -r .state <<<"$RUN_OUT")" PLANNED
if [[ ! -e "$UNQUALIFIED_CANDIDATE_MARKER" ]]; then
  ok 'unqualified candidate lifecycle entry point is never executed'
else
  not_ok 'unqualified candidate lifecycle entry point is never executed'
fi
cp "$TMP/trusted-agent-flow-kit" "$AUTHOR/bin/agent-flow-kit"
chmod +x "$AUTHOR/bin/agent-flow-kit"
git -C "$AUTHOR" add bin/agent-flow-kit
git -C "$AUTHOR" commit -qm 'restore lifecycle fixture'
git -C "$AUTHOR" push -q test-origin master

# Plan a forward revision and prove the installed state is unchanged.
printf 'release two\n' >"$AUTHOR/files/release-test-marker"
git -C "$AUTHOR" add files/release-test-marker
git -C "$AUTHOR" commit -qm 'test release two'
TARGET_TWO="$(git -C "$AUTHOR" rev-parse HEAD)"
git -C "$AUTHOR" push -q test-origin master
BEFORE="$(sha256sum "$STATE/state.json" | awk '{print $1}')"
run_update --plan --policy "$AUTHOR/lifecycle/release-policy.json"
assert_eq 'plan observes the forward release' "$(jq -r .state <<<"$RUN_OUT")" PLANNED
assert_eq 'plan identifies the new target' "$(jq -r .target_revision <<<"$RUN_OUT")" "$TARGET_TWO"
assert_eq 'plan does not mutate installed state' "$(sha256sum "$STATE/state.json" | awk '{print $1}')" "$BEFORE"

touch "$STATE/.test-rollback"
printf '%s\n' 'DO-NOT-PERSIST-CANDIDATE-REASON' >"$STATE/.test-result-reason"
run_update --apply --force-check --policy "$AUTHOR/lifecycle/release-policy.json"
assert_eq 'lifecycle rollback is reported truthfully' "$(jq -r .state <<<"$RUN_OUT")" ROLLED_BACK
assert_eq 'candidate operation reason maps to release vocabulary' "$(jq -r .reason <<<"$RUN_OUT")" APPLY_ROLLED_BACK
if ! grep -R -Fq 'DO-NOT-PERSIST-CANDIDATE-REASON' "$STATE/releases/attempts" "$STATE/releases/latest.json"; then ok 'candidate reason is never persisted'; else not_ok 'candidate reason is never persisted'; fi
assert_eq 'rollback retains the prior installed revision' "$(jq -r .applied_revision "$STATE/state.json")" "$TARGET_ONE"

printf 'x%.0s' {1..160} >"$STATE/.test-operation-id"
run_update --apply --force-check --policy "$AUTHOR/lifecycle/release-policy.json"
assert_eq 'unbounded candidate operation id is refused' "$(jq -r .reason <<<"$RUN_OUT")" APPLY_RESULT_UNREADABLE
assert_eq 'unbounded candidate operation id is not persisted' "$(jq -r '.operation.id' <<<"$RUN_OUT")" null
rm -f "$STATE/.test-rollback" "$STATE/.test-operation-id" "$STATE/.test-result-reason"

# A syntactically valid candidate that fails distributed runtime behavior is
# rejected before its lifecycle plan can be trusted or applied.
cp "$AUTHOR/bin/afk-session-freshness" "$TMP/freshness-good"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''{"schema":"afk-session-freshness/2","state":"INVENTED"}\n'\''' >"$AUTHOR/bin/afk-session-freshness"
chmod +x "$AUTHOR/bin/afk-session-freshness"
git -C "$AUTHOR" add bin/afk-session-freshness
git -C "$AUTHOR" commit -qm 'test behaviorally broken release'
git -C "$AUTHOR" push -q test-origin master
run_update --plan --policy "$AUTHOR/lifecycle/release-policy.json"
assert_eq 'behaviorally broken runtime fails candidate qualification' "$(jq -r .reason <<<"$RUN_OUT")" CANDIDATE_QUALIFICATION_FAILED
assert_eq 'behavioral qualification failure retains installed revision' "$(jq -r .applied_revision "$STATE/state.json")" "$TARGET_ONE"
cp "$TMP/freshness-good" "$AUTHOR/bin/afk-session-freshness"
git -C "$AUTHOR" add bin/afk-session-freshness
git -C "$AUTHOR" commit -qm 'restore freshness behavior'
git -C "$AUTHOR" push -q test-origin master

# The behavioral smoke cannot see arbitrary host files or reach a host listener.
# A candidate that reports success only when both escape attempts fail therefore
# qualifies; without the sandbox this fixture emits an invalid state.
HOST_SENTINEL="$TMP/qualification-host-secret"
PORT_FILE="$TMP/qualification-port"
printf '%s\n' 'host-only' >"$HOST_SENTINEL"
python3 - "$PORT_FILE" >"$TMP/qualification-server.out" 2>&1 <<'PY' &
import http.server
import socketserver
import sys

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, _format, *_args):
        pass

with socketserver.TCPServer(("127.0.0.1", 0), QuietHandler) as server:
    with open(sys.argv[1], "w", encoding="utf-8") as stream:
        stream.write(str(server.server_address[1]))
    server.serve_forever()
PY
server_pid=$!
for _ in {1..500}; do [[ -s "$PORT_FILE" ]] && break; sleep 0.01; done
qualification_port="$(cat "$PORT_FILE" 2>/dev/null || true)"
if [[ "$qualification_port" =~ ^[0-9]+$ ]] &&
   bash -c 'exec 9<>"/dev/tcp/127.0.0.1/$1"' _ "$qualification_port" 2>/dev/null; then
  ok 'host qualification listener is reachable before sandboxing'
else
  not_ok 'host qualification listener is reachable before sandboxing'
fi
cp "$AUTHOR/bin/afk-session-freshness" "$AUTHOR/bin/afk-session-freshness.qualified-original"
cat >"$AUTHOR/bin/afk-session-freshness" <<EOF
#!/usr/bin/env bash
if [[ -r '$HOST_SENTINEL' ]] || exec 9<>"/dev/tcp/127.0.0.1/$qualification_port" 2>/dev/null; then
  printf '%s\n' '{"schema":"afk-session-freshness/2","state":"INVENTED"}'
  exit 0
fi
exec "\$(dirname -- "\${BASH_SOURCE[0]}")/afk-session-freshness.qualified-original" "\$@"
EOF
chmod +x "$AUTHOR/bin/afk-session-freshness" "$AUTHOR/bin/afk-session-freshness.qualified-original"
git -C "$AUTHOR" add bin/afk-session-freshness bin/afk-session-freshness.qualified-original
git -C "$AUTHOR" commit -qm 'test sandboxed behavioral release'
git -C "$AUTHOR" push -q test-origin master
run_update --plan --policy "$AUTHOR/lifecycle/release-policy.json"
assert_eq 'behavioral qualification blocks host file and network access' "$(jq -r .state <<<"$RUN_OUT")" PLANNED
kill "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
cp "$TMP/freshness-good" "$AUTHOR/bin/afk-session-freshness"
rm "$AUTHOR/bin/afk-session-freshness.qualified-original"
git -C "$AUTHOR" add -A bin/afk-session-freshness bin/afk-session-freshness.qualified-original
git -C "$AUTHOR" commit -qm 'restore sandbox fixture'
git -C "$AUTHOR" push -q test-origin master

AFK_TEST_FETCH_FAIL=true run_update --plan --force-check --policy "$AUTHOR/lifecycle/release-policy.json"
assert_eq 'generic fetch failure retains proven last-good' "$(jq -r .state <<<"$RUN_OUT")" RETAINED
assert_eq 'generic fetch failure uses neutral unavailable reason' "$(jq -r .reason <<<"$RUN_OUT")" FETCH_UNAVAILABLE

# Tool and sandbox failures use explicit copied-client seams, never PATH
# shadowing. Production continues to require validated root-owned executables.
UNTRUSTED_TOOL_CLIENT="$TMP/untrusted-tool-client"
ln -s "$TEST_BIN/git" "$TMP/untrusted-git-link"
cp "$AUTHOR/bin/afk-release-reconcile" "$UNTRUSTED_TOOL_CLIENT"
sed -i "s|readonly GIT_BIN='/usr/bin/git'|readonly GIT_BIN='$TMP/untrusted-git-link'|" "$UNTRUSTED_TOOL_CLIENT"
chmod +x "$UNTRUSTED_TOOL_CLIENT"
set +e; UNTRUSTED_TOOL_OUT="$(HOME="$HOME_TEST" "$UNTRUSTED_TOOL_CLIENT" --plan --policy "$AUTHOR/lifecycle/release-policy.json")"; untrusted_tool_rc=$?
assert_eq 'user-owned tool symlink target is refused' "$(jq -r .reason <<<"$UNTRUSTED_TOOL_OUT")" REQUIRED_TOOL_UNTRUSTED
assert_eq 'untrusted tool fails closed' "$untrusted_tool_rc" 2

NO_SANDBOX_CLIENT="$TMP/no-sandbox-client"
cp "$RELEASE_CLIENT" "$NO_SANDBOX_CLIENT"
sed -i "s|readonly BWRAP_BIN='/usr/bin/bwrap'|readonly BWRAP_BIN='$TMP/missing-bwrap'|" "$NO_SANDBOX_CLIENT"
chmod +x "$NO_SANDBOX_CLIENT"
set +e; NO_SANDBOX_OUT="$(HOME="$HOME_TEST" AFK_STATE_DIR="$STATE" "$NO_SANDBOX_CLIENT" --plan --force-check --policy "$AUTHOR/lifecycle/release-policy.json")"; no_sandbox_rc=$?
assert_eq 'missing candidate sandbox has a specific refusal' "$(jq -r .reason <<<"$NO_SANDBOX_OUT")" CANDIDATE_SANDBOX_UNAVAILABLE
assert_eq 'missing candidate sandbox fails closed' "$no_sandbox_rc" 2

PERSISTENCE_FAILURE_CLIENT="$TMP/persistence-failure-client"
cp "$RELEASE_CLIENT" "$PERSISTENCE_FAILURE_CLIENT"
# shellcheck disable=SC2016 # fixture patch keeps runtime destination variables literal
sed -i '/^  mv -f -- "$temporary" "$destination"$/i\  [[ "$destination" == "$latest_file" ]] \&\& return 1' \
  "$PERSISTENCE_FAILURE_CLIENT"
chmod +x "$PERSISTENCE_FAILURE_CLIENT"
PERSISTENCE_LATEST_BEFORE="$(sha256sum "$STATE/releases/latest.json" | awk '{print $1}')"
set +e
PERSISTENCE_FAILURE_OUT="$(HOME="$HOME_TEST" AFK_STATE_DIR="$STATE" \
  "$PERSISTENCE_FAILURE_CLIENT" --plan --force-check \
  --policy "$AUTHOR/lifecycle/release-policy.json")"
persistence_failure_rc=$?
set -e
assert_eq 'latest persistence failure is reported as blocked' \
  "$(jq -r '.state+":"+.reason' <<<"$PERSISTENCE_FAILURE_OUT")" \
  BLOCKED:RESULT_PERSISTENCE_FAILED
assert_eq 'latest persistence failure fails closed' "$persistence_failure_rc" 2
assert_eq 'failed latest write leaves the prior summary intact' \
  "$(sha256sum "$STATE/releases/latest.json" | awk '{print $1}')" \
  "$PERSISTENCE_LATEST_BEFORE"

ATTEMPT_FAILURE_CLIENT="$TMP/attempt-failure-client"
cp "$RELEASE_CLIENT" "$ATTEMPT_FAILURE_CLIENT"
# shellcheck disable=SC2016 # fixture patch keeps runtime destination variables literal
sed -i '/^  mv -f -- "$temporary" "$destination"$/i\  [[ "$destination" == "$attempt_dir/"* ]] \&\& return 1' \
  "$ATTEMPT_FAILURE_CLIENT"
chmod +x "$ATTEMPT_FAILURE_CLIENT"
ATTEMPT_LATEST_BEFORE="$(sha256sum "$STATE/releases/latest.json" | awk '{print $1}')"
set +e
ATTEMPT_FAILURE_OUT="$(HOME="$HOME_TEST" AFK_STATE_DIR="$STATE" \
  "$ATTEMPT_FAILURE_CLIENT" --plan --force-check \
  --policy "$AUTHOR/lifecycle/release-policy.json")"
attempt_failure_rc=$?
set -e
assert_eq 'attempt persistence failure is reported as blocked' \
  "$(jq -r '.state+":"+.reason' <<<"$ATTEMPT_FAILURE_OUT")" \
  BLOCKED:RESULT_PERSISTENCE_FAILED
assert_eq 'attempt persistence failure fails closed' "$attempt_failure_rc" 2
assert_eq 'failed attempt write does not publish a success summary' \
  "$(sha256sum "$STATE/releases/latest.json" | awk '{print $1}')" \
  "$ATTEMPT_LATEST_BEFORE"

LOCK_ERROR_STATE="$TMP/lock-error-state"; mkdir -p "$LOCK_ERROR_STATE"
cp "$STATE/state.json" "$LOCK_ERROR_STATE/state.json"
LOCK_ERROR_CLIENT="$TMP/lock-error-client"
cp "$RELEASE_CLIENT" "$LOCK_ERROR_CLIENT"
# shellcheck disable=SC2016 # fixture patch must retain literal command substitution
sed -i 's|owner="$(lock_owner_json)"|owner="$(false)"|' "$LOCK_ERROR_CLIENT"
chmod +x "$LOCK_ERROR_CLIENT"
set +e; LOCK_ERROR_OUT="$(HOME="$HOME_TEST" AFK_STATE_DIR="$LOCK_ERROR_STATE" "$LOCK_ERROR_CLIENT" --plan --force-check --policy "$AUTHOR/lifecycle/release-policy.json")"; lock_error_rc=$?
assert_eq 'lock initialization error is not contention' "$(jq -r .reason <<<"$LOCK_ERROR_OUT")" LOCK_INITIALIZATION_FAILED
assert_eq 'lock initialization error fails closed' "$lock_error_rc" 2

# Swap the qualified checkout immediately before lifecycle use. The recorded
# inode identity and symlink checks must reject it before any candidate code runs.
REPLACED_CLIENT="$TMP/replaced-candidate-client"
cp "$RELEASE_CLIENT" "$REPLACED_CLIENT"
# shellcheck disable=SC2016 # fixture patch must retain literal positional parameters
sed -i 's|candidate_pre_use_boundary() { :; }|candidate_pre_use_boundary() { if [[ ! -e "$1.replaced" ]]; then mv -- "$1" "$1.replaced"; ln -s "$1.replaced" "$1"; fi; }|' "$REPLACED_CLIENT"
chmod +x "$REPLACED_CLIENT"
set +e; REPLACED_OUT="$(HOME="$HOME_TEST" AFK_STATE_DIR="$STATE" "$REPLACED_CLIENT" --plan --force-check --policy "$AUTHOR/lifecycle/release-policy.json")"; replaced_rc=$?
assert_eq 'candidate replacement before lifecycle is refused' "$(jq -r .reason <<<"$REPLACED_OUT")" PLAN_NOT_SAFE_TO_APPLY
assert_eq 'candidate replacement refusal fails closed' "$replaced_rc" 2
replaced_path="$(find "$STATE/releases/candidates" -maxdepth 1 -type l -print -quit)"
if [[ -n "$replaced_path" && -d "$replaced_path.replaced" ]]; then
  rm "$replaced_path"; mv "$replaced_path.replaced" "$replaced_path"
fi

cp "$STATE/state.json" "$TMP/manifest-before-path-checks.json"
ln -s "$HOME_TEST/.agents/skills/model-router" "$TMP/router-link"
jq --arg path "$TMP/router-link" '.components["model-router"].path=$path' \
  "$STATE/state.json" >"$STATE/state.json.tmp"; mv "$STATE/state.json.tmp" "$STATE/state.json"
run_update --plan --force-check --policy "$AUTHOR/lifecycle/release-policy.json"
assert_eq 'symlinked installed destination is refused' "$(jq -r .reason <<<"$RUN_OUT")" INSTALLED_DESTINATIONS_UNTRUSTED
mkdir -p "$TMP/other-home/.claude"; : >"$TMP/other-home/.claude/CLAUDE.md"
jq --arg path "$TMP/other-home/.claude/CLAUDE.md" '.components["claude-global-policy"].path=$path' \
  "$TMP/manifest-before-path-checks.json" >"$STATE/state.json"
run_update --plan --force-check --policy "$AUTHOR/lifecycle/release-policy.json"
assert_eq 'cross-home installed destinations are refused' "$(jq -r .reason <<<"$RUN_OUT")" INSTALLED_DESTINATIONS_UNTRUSTED
cp "$TMP/manifest-before-path-checks.json" "$STATE/state.json"

BAD_MIRROR_STATE="$TMP/bad-mirror-state"; mkdir -p "$BAD_MIRROR_STATE/releases"
jq -nc --arg base "$TARGET_ONE" --arg home "$HOME_TEST" --arg runtime "$TRUSTED_DRIVER_SOURCE" \
  --arg bin_identity "$TRUSTED_BIN_IDENTITY" --arg lib_identity "$TRUSTED_LIB_IDENTITY" \
  '{schema_version:"1.0",applied_revision:$base,components:{
    "afk-runtime-bin":{path:($runtime+"/bin"),identity:$bin_identity},
    "afk-runtime-lib":{path:($runtime+"/lib"),identity:$lib_identity},
    "model-router":{path:($home+"/.agents/skills/model-router")},
    "claude-global-policy":{path:($home+"/.claude/CLAUDE.md")},
    "codex-global-guidance":{path:($home+"/.codex/AGENTS.md")}}}' >"$BAD_MIRROR_STATE/state.json"
printf 'not a repository\n' >"$BAD_MIRROR_STATE/releases/repository.git"
bad_mirror_rc=0
BAD_MIRROR_OUT="$(HOME="$HOME_TEST" AFK_STATE_DIR="$BAD_MIRROR_STATE" \
  "$RELEASE_CLIENT" --plan --force-check --policy "$AUTHOR/lifecycle/release-policy.json" 2>"$TMP/bad-mirror.err")" || bad_mirror_rc=$?
assert_eq 'mirror initialization failure is not reported as offline' "$(jq -r .reason <<<"$BAD_MIRROR_OUT")" RELEASE_MIRROR_UNUSABLE
assert_eq 'mirror initialization failure fails closed' "$bad_mirror_rc" 2

# A fetched commit with the trusted root but divergent history is rejected.
DIVERGER="$TMP/diverger"
git clone -q "$AUTHOR" "$DIVERGER"
git -C "$DIVERGER" config user.name 'AFK release test'
git -C "$DIVERGER" config user.email 'afk-release-test@example.invalid'
git -C "$DIVERGER" checkout -q -B master "$BASE"
printf 'divergent\n' >"$DIVERGER/files/divergent-release-marker"
git -C "$DIVERGER" add files/divergent-release-marker
git -C "$DIVERGER" commit -qm 'divergent release'
git -C "$DIVERGER" push -q --force "$REMOTE" master
run_update --apply --force-check --policy "$AUTHOR/lifecycle/release-policy.json"
assert_eq 'same-root divergent release is refused' "$(jq -r .reason <<<"$RUN_OUT")" SOURCE_NOT_FORWARD_ANCESTOR
assert_eq 'divergence cannot advance installed revision' "$(jq -r .applied_revision "$STATE/state.json")" "$TARGET_ONE"

# Offline launch proves the recorded candidate and preserves unrelated hooks.
cat >"$HOME_TEST/.gitconfig" <<EOF
[url "file://$TMP/offline-remote"]
    insteadOf = ssh://git@github.com/jlengelbrecht/agent-flow-kit.git
EOF
touch "$OFFLINE_MARKER"
INSTALLED_RUNTIME="$HOME_TEST/.agents/skills/afk-runtime"
mkdir -p "$INSTALLED_RUNTIME/bin"
cp -R "$AUTHOR/adapters/." "$INSTALLED_RUNTIME/"
# Expire the throttle so this launch exercises the explicit offline fallback.
jq '.checked_at_epoch=0' "$STATE/releases/current.json" >"$STATE/releases/current.json.tmp"
mv "$STATE/releases/current.json.tmp" "$STATE/releases/current.json"
mkdir -p "$HOME_TEST/.claude" "$HOME_TEST/.hindsight" "$HOME_TEST/.config/orca"
printf '%s\n' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"hindsight recall"}]}]},"theme":"owner-choice"}' >"$HOME_TEST/.claude/settings.json"
printf 'hindsight-owned\n' >"$HOME_TEST/.hindsight/config"
printf 'orca-owned\n' >"$HOME_TEST/.config/orca/config"
cp "$RELEASE_CLIENT" "$INSTALLED_RUNTIME/bin/afk-release-reconcile"
cp "$TMP/afk-release-known-hosts" "$INSTALLED_RUNTIME/bin/afk-release-known-hosts"
cp "$ROOT/bin/afk-session-start" "$INSTALLED_RUNTIME/bin/afk-session-start"
chmod +x "$INSTALLED_RUNTIME/bin/afk-release-reconcile" \
  "$INSTALLED_RUNTIME/bin/afk-session-start"
# shellcheck disable=SC2016 # HOME expands in the child shell by design
HOME="$HOME_TEST" AFK_STATE_DIR="$STATE" "$INSTALLED_RUNTIME/bin/afk-session-start" \
  --policy "$AUTHOR/lifecycle/release-policy.json" --adapter claude -- sh -c 'printf launched >"$HOME/launched"' >"$TMP/session.out" 2>"$TMP/session.err"
SESSION_RC=$?
assert_eq 'offline session launches only from verified last-good' "$SESSION_RC" 0
assert_file_contains 'offline session command ran' "$HOME_TEST/launched" launched
assert_eq 'existing Claude hook remains' "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$HOME_TEST/.claude/settings.json")" 'hindsight recall'
assert_eq 'unrelated Claude setting remains' "$(jq -r .theme "$HOME_TEST/.claude/settings.json")" owner-choice
assert_eq 'installed hook uses stable runtime path' "$(jq -r .statusLine.command "$HOME_TEST/.claude/settings.json")" "$HOME_TEST/.agents/skills/afk-runtime/claude/statusline.sh"
if grep -Fq '/releases/candidates/' "$HOME_TEST/.claude/settings.json"; then not_ok 'hook avoids candidate cache path'; else ok 'hook avoids candidate cache path'; fi
assert_file_contains 'Hindsight config remains byte-owned by Hindsight' "$HOME_TEST/.hindsight/config" hindsight-owned
assert_file_contains 'Orca config remains byte-owned by Orca' "$HOME_TEST/.config/orca/config" orca-owned

printf '1..%d\n' "$((PASS + FAIL))"
if (( FAIL )); then printf '%d release update assertions failed\n' "$FAIL" >&2; exit 1; fi
printf 'All %d release update assertions passed.\n' "$PASS"
