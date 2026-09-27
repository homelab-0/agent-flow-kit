#!/usr/bin/env bash
# auto-update-enroll-tests.sh — the isolated deterministic gate for
# `agent-flow-kit enroll-auto-update` (lib/afk-auto-update.sh).
#
# No network and nothing on the real host: op, ssh-keygen, systemctl,
# loginctl, launchctl and `git ls-remote` are stubs, the installed release
# client is a stub that prints one result, and every run gets a throwaway HOME.
#
# Usage: tests/auto-update-enroll-tests.sh
# Exit:  0 all passed, 1 any failure.

set -uo pipefail

KIT_ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
AFK="$KIT_ROOT/bin/agent-flow-kit"
POLICY="$KIT_ROOT/lifecycle/release-policy.json"
TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT

PASS=0 FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; FAIL=$((FAIL + 1)); }
head1() { printf '\n\033[1m%s\033[0m\n' "$1"; }
assert_eq()       { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing substring: $3"; fi; }
assert_absent()   { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "should NOT contain: $3"; fi; }
assert_missing()  { if [[ -e "$2" ]]; then bad "$1" "exists: $2"; else ok "$1"; fi; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

PINNED="$(jq -r '.deploy_key_fingerprint' "$POLICY")"
REMOTE_HEAD="1111111111111111111111111111111111111111"

# --- stubs -------------------------------------------------------------------
STUBS="$TMPROOT/stubs"; LOG="$TMPROOT/stub.log"; OUT="$TMPROOT/out"
mkdir -p "$STUBS" "$OUT"; : >"$LOG"
cat >"$STUBS/op" <<'SH'
#!/usr/bin/env bash
[[ "$1" == read ]] || exit 2
case "$2" in
  *good*)  printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' 'AFKTESTKEYBYTES-GOOD' '-----END OPENSSH PRIVATE KEY-----' ;;
  *wrong*) printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' 'AFKTESTKEYBYTES-WRONG' '-----END OPENSSH PRIVATE KEY-----' ;;
  *junk*)  printf '%s\n' 'AFKTESTKEYBYTES-JUNK' ;;
  *) printf '[ERROR] could not read secret\n' >&2; exit 1 ;;
esac
SH
cat >"$STUBS/ssh-keygen" <<'SH'
#!/usr/bin/env bash
if grep -q JUNK "${*: -1}"; then printf 'not a key file\n' >&2; exit 255; fi
if grep -q GOOD "${*: -1}"; then printf '256 %s afk (ED25519)\n' "$AFK_TEST_PINNED"
else printf '256 SHA256:notThePinnedDeployKey afk (ED25519)\n'; fi
SH
# The scheduler stubs keep their enabled/loaded state in the throwaway HOME.
# AFK_TEST_SYSTEMCTL_FAIL lists steps that fail: a verb (`daemon-reload`,
# `enable`, `start`...), `enable-now`, or `<step>@<n>` for only its n-th call
# in this HOME; `1` fails every enable.
cat >"$STUBS/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$AFK_TEST_LOG"
if [[ "$2" == show ]]; then
  # AC-3: `systemctl --user show <unit> -p Result -p ExecMainStatus --value`.
  # AFK_TEST_SYSTEMCTL_RESULT/EXITCODE steer what the last run "reports".
  printf '%s\n' "${AFK_TEST_SYSTEMCTL_RESULT:-success}"
  printf '%s\n' "${AFK_TEST_SYSTEMCTL_EXITCODE:-0}"
  exit 0
fi
E="$HOME/.stub-timer-enabled" A="$HOME/.stub-timer-active"
step="$2"; [[ "${3:-}" == --now ]] && step="$2-now"
n=$(( $(cat "$HOME/.stub-count-$step" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$HOME/.stub-count-$step"
for f in $AFK_TEST_SYSTEMCTL_FAIL; do
  case "$f" in
    1) [[ "$2" != enable ]] || exit 1 ;;
    "$step"|"$step@$n") exit 1 ;;
  esac
done
case "$step" in
  enable)      : >"$E" ;;
  enable-now)  : >"$E"; : >"$A" ;;
  disable)     rm -f "$E" ;;
  disable-now) rm -f "$E" "$A" ;;
  start)       : >"$A" ;;
  stop)        rm -f "$A" ;;
  is-enabled)  if [[ -f "$E" ]]; then echo enabled; else echo disabled; exit 1; fi ;;
  is-active)   if [[ -f "$A" ]]; then echo active; else echo inactive; exit 3; fi ;;
esac
SH
# Like launchd, bootout finishes asynchronously (the agent is gone only after
# two more prints), bootstrap fails while the agent is still loaded, and
# .stub-bootstrap-fails makes the next N bootstraps fail. The loaded file is a
# copy of the plist launchd loaded.
cat >"$STUBS/launchctl" <<'SH'
#!/usr/bin/env bash
printf 'launchctl %s\n' "$*" >>"$AFK_TEST_LOG"
L="$HOME/.stub-agent-loaded" P="$HOME/.stub-bootout-pending" F="$HOME/.stub-bootstrap-fails"
case "$1" in
  bootstrap)
    n="$(cat "$F" 2>/dev/null || echo 0)"
    if (( n > 0 )); then echo $((n - 1)) >"$F"; exit 5; fi
    [[ ! -f "$L" ]] || exit 5
    cp "$3" "$L" ;;
  bootout) [[ ! -f "$L" ]] || echo 2 >"$P" ;;
  print)
    if [[ -f "$P" ]]; then
      n="$(cat "$P")"
      if (( n <= 1 )); then rm -f "$P" "$L"; else echo $((n - 1)) >"$P"; fi
    fi
    [[ -f "$L" ]] ;;
esac
SH
# macOS has no timeout binary by default (coreutils installs gtimeout). When
# neither exists, the stub drops timeout's options and duration and runs the
# command directly, so the suite behaves the same on every supported host.
REAL_TIMEOUT="$(command -v timeout || command -v gtimeout || true)"
cat >"$STUBS/timeout" <<SH
#!/usr/bin/env bash
printf 'timeout %s\n' "\$*" >>"$LOG"
[[ -z "\${AFK_TEST_TIMEOUT_EXPIRE:-}" ]] || exit 124
if [[ -n "$REAL_TIMEOUT" ]]; then exec "$REAL_TIMEOUT" "\$@"; fi
while [[ "\${1:-}" == -* ]]; do shift; done
shift
exec "\$@"
SH
printf '#!/usr/bin/env bash\nprintf "no\\n"\n' >"$STUBS/loginctl"
# Fake bash candidates for AC-1: they never really run anything, they only
# answer the version probe `afk_au_resolve_bash` runs against them, so a
# "3.2" stub exercises the refusal path with no macOS 3.2 anywhere near this
# host and no real bash needs to be built or installed for the test.
printf '#!/usr/bin/env bash\nprintf "3.2\\n"\n' >"$STUBS/bash-old"
printf '#!/usr/bin/env bash\nprintf "5.2\\n"\n' >"$STUBS/bash-new"
cat >"$STUBS/git" <<SH
#!/usr/bin/env bash
if [[ "\$1" == ls-remote ]]; then
  printf 'git-ssh %s\n' "\$GIT_SSH_COMMAND" >>"$LOG"
  printf '%s\trefs/heads/master\n' "$REMOTE_HEAD"; exit 0
fi
exec "$(command -v git)" "\$@"
SH
chmod +x "$STUBS"/*
# The macOS check also runs catalog-sync, which resolves git and curl only from
# AFK_CATALOG_SYNC_TOOL_PATH. Point that at fakes that never touch the network:
# git answers with a sentinel commit that exists nowhere, curl refuses.
CS_TOOLS="$TMPROOT/cs-tools"; CS_FAKE_SHA=cafecafecafecafecafecafecafecafecafecafe
mkdir -p "$CS_TOOLS"
cat >"$CS_TOOLS/git" <<SH
#!$(command -v bash)
printf 'cs-git %s\n' "\$*" >>"$LOG"
printf '%s\trefs/heads/main\n' "$CS_FAKE_SHA"
SH
cat >"$CS_TOOLS/curl" <<SH
#!$(command -v bash)
printf 'cs-curl %s\n' "\${*: -1}" >>"$LOG"
exit 22
SH
chmod +x "$CS_TOOLS"/*

new_home() { # <name> -> path; a home with a stub installed release client
  local h="$TMPROOT/$1"
  mkdir -p "$h/.agents/skills/afk-runtime/bin"
  cat >"$h/.agents/skills/afk-runtime/bin/afk-release-reconcile" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${AFK_RELEASE_DEPLOY_KEY:-unset}" >"$HOME/.first-attempt-key"
printf '%s\n' '{"schema":"afk-release-result/2","state":"APPLIED","reason":"NO_CHANGE"}'
SH
  printf '#!/usr/bin/env bash\nexit 0\n' >"$h/.agents/skills/afk-runtime/bin/agent-flow-kit"
  printf 'github.com ssh-ed25519 AAAAstub\n' >"$h/.agents/skills/afk-runtime/bin/afk-release-known-hosts"
  chmod +x "$h/.agents/skills/afk-runtime/bin/afk-release-reconcile" "$h/.agents/skills/afk-runtime/bin/agent-flow-kit"
  # The release client refuses a key below a group-writable HOME; do not
  # inherit one from the runner's umask.
  chmod 755 "$h"
  printf '%s\n' "$h"
}

RC=0
run_afk() { # <home> <platform> <out-name> args... ; sets RC
  local h="$1" p="$2" o="$3"; shift 3
  env -i PATH="$STUBS:$PATH" HOME="$h" USER=tester LANG=C \
    AFK_STATE_DIR="${AFK_TEST_STATE_DIR:-$h/.local/state/agent-flow-kit}" AFK_PM_DIR="$h/.local/state/agent-flow-kit/pm" \
    AFK_AUTO_UPDATE_PLATFORM="$p" AFK_OP_BIN="${AFK_TEST_OP:-$STUBS/op}" \
    AFK_RELEASE_POLICY="${AFK_TEST_POLICY:-$POLICY}" AFK_CATALOG_SYNC_TOOL_PATH="$CS_TOOLS" \
    AFK_TEST_PINNED="$PINNED" AFK_TEST_LOG="$LOG" AFK_TEST_SYSTEMCTL_FAIL="${AFK_TEST_SYSTEMCTL_FAIL:-}" \
    AFK_TEST_TIMEOUT_EXPIRE="${AFK_TEST_TIMEOUT_EXPIRE:-}" \
    AFK_AU_BASH_CANDIDATES="${AFK_TEST_BASH_CANDIDATES-$STUBS/bash-new}" \
    AFK_TEST_SYSTEMCTL_RESULT="${AFK_TEST_SYSTEMCTL_RESULT:-}" AFK_TEST_SYSTEMCTL_EXITCODE="${AFK_TEST_SYSTEMCTL_EXITCODE:-}" \
    bash "$AFK" "$@" >"$OUT/$o.out" 2>"$OUT/$o.err"
  RC=$?
}

KEY_REL=".config/agent-flow-kit/deploy-key/agent-flow-kit_ed25519"
UNIT_REL=".config/systemd/user/afk-release-reconcile"
PLIST_REL="Library/LaunchAgents/io.github.jlengelbrecht.agent-flow-kit.update-check.plist"

head1 "The fingerprint is policy, not code"
assert_contains "policy pins the deploy key fingerprint" "$PINNED" "SHA256:bSEA/KNX1UdAkGPXvamZgkrCfPfpT0Umadr4aDyvxkA"
assert_absent "no fingerprint literal in lib/afk-auto-update.sh" \
  "$(grep -v '^[[:space:]]*#' "$KIT_ROOT/lib/afk-auto-update.sh")" "bSEA/"

head1 "Refusals install nothing"
H="$(new_home refuse)"
AFK_TEST_OP="$TMPROOT/no-such-op" run_afk "$H" linux no-op enroll-auto-update --key-ref op://v/good/notesPlain
assert_eq "missing op refuses (exit 4)" "$RC" "4"
assert_contains "missing op is named" "$(cat "$OUT/no-op.err")" "OP_UNAVAILABLE"
run_afk "$H" linux unreadable enroll-auto-update --key-ref op://v/absent/notesPlain
assert_eq "unreadable ref refuses (exit 4)" "$RC" "4"
assert_contains "unreadable ref is named" "$(cat "$OUT/unreadable.err")" "KEY_REF_UNREADABLE"
run_afk "$H" linux mismatch enroll-auto-update --key-ref op://v/wrong/notesPlain
assert_eq "fingerprint mismatch refuses (exit 4)" "$RC" "4"
assert_contains "mismatch is named" "$(cat "$OUT/mismatch.err")" "FINGERPRINT_MISMATCH"
assert_missing "mismatch: no key installed" "$H/$KEY_REL"
assert_eq "mismatch: no scratch file left behind" \
  "$(find "$H/.config/agent-flow-kit/deploy-key" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
assert_missing "mismatch: no config recorded" "$H/.config/agent-flow-kit/auto-update.json"
assert_missing "mismatch: no timer installed" "$H/$UNIT_REL.timer"
run_afk "$H" linux not-op enroll-auto-update --key-ref /tmp/key
assert_eq "a non-op reference is a usage failure" "$RC" "1"
run_afk "$H" linux junk enroll-auto-update --key-ref op://v/junk/notesPlain
assert_eq "unparseable key refuses (exit 4)" "$RC" "4"
assert_contains "unparseable key is named" "$(cat "$OUT/junk.err")" "KEY_UNPARSEABLE"
assert_absent "unparseable key is not called a mismatch" "$(cat "$OUT/junk.err")" "FINGERPRINT_MISMATCH"
assert_eq "failure after op read: no scratch file left behind" \
  "$(find "$H/.config/agent-flow-kit/deploy-key" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
for bad_path in "$H/keys/has space" "$H/keys/pct%key" "$H/keys/dollar\$key" "$H/keys/hash#key"; do
  run_afk "$H" linux unsafe enroll-auto-update --key-ref op://v/good/notesPlain --key-file "$bad_path"
  assert_eq "unsafe --key-file refused: $bad_path" "$RC" "1"
  assert_contains "unsafe --key-file is named: $bad_path" "$(cat "$OUT/unsafe.err")" "KEY_PATH_UNSAFE"
done
assert_missing "unsafe --key-file: nothing installed" "$H/keys"

head1 "Conflicting modes and options are refused"
H="$(new_home modes)"
run_afk "$H" linux both enroll-auto-update --check --remove
assert_eq "--check with --remove refused (exit 1)" "$RC" "1"
assert_contains "--check with --remove is named" "$(cat "$OUT/both.err")" "cannot be combined"
run_afk "$H" linux tworefs enroll-auto-update --key-ref op://v/good/a --key-ref op://v/good/b
assert_eq "--key-ref twice with different values refused" "$RC" "1"
run_afk "$H" linux samerefs enroll-auto-update --key-ref op://v/good/a --key-ref op://v/good/a
assert_eq "--key-ref twice with the same value is accepted" "$RC" "0"
run_afk "$H" linux remove-ref enroll-auto-update --remove --key-ref op://v/good/a
assert_eq "--remove with --key-ref refused" "$RC" "1"
run_afk "$H" linux check-file enroll-auto-update --check --key-file "$H/k"
assert_eq "--check with --key-file refused" "$RC" "1"
assert_contains "the refusal says why" "$(cat "$OUT/check-file.err")" "apply only to enrollment"

head1 "Nothing is installed before the runtime is ready"
H="$(new_home notready)"
rm -f "$H/.agents/skills/afk-runtime/bin/afk-release-known-hosts"
run_afk "$H" linux notready enroll-auto-update --key-ref op://develop/good/notesPlain
assert_eq "missing known-hosts refuses (exit 4)" "$RC" "4"
assert_contains "not ready is named" "$(cat "$OUT/notready.err")" "NOT_READY"
assert_absent "not ready never reports ENROLLED" "$(cat "$OUT/notready.out")" "ENROLLED"
assert_missing "not ready: no key installed" "$H/$KEY_REL"
assert_missing "not ready: no config recorded" "$H/.config/agent-flow-kit/auto-update.json"
assert_missing "not ready: no timer installed" "$H/$UNIT_REL.timer"
H="$(new_home notready2)"
chmod -x "$H/.agents/skills/afk-runtime/bin/afk-release-reconcile"
run_afk "$H" linux notready2 enroll-auto-update --key-ref op://develop/good/notesPlain
assert_eq "a non-executable release client refuses (exit 4)" "$RC" "4"
assert_missing "non-executable client: no key installed" "$H/$KEY_REL"

head1 "Something other than a file at the key path"
H="$(new_home occupied)"
mkdir -p "$H/$KEY_REL"
run_afk "$H" linux occupied enroll-auto-update --key-ref op://develop/good/notesPlain
assert_eq "a directory at the key path refuses (exit 4)" "$RC" "4"
assert_contains "occupied key path is named" "$(cat "$OUT/occupied.err")" "KEY_PATH_OCCUPIED"
assert_eq "occupied: nothing written beside or into it" \
  "$(find "$H/.config/agent-flow-kit/deploy-key" -type f | wc -l | tr -d ' ')" "0"
assert_missing "occupied: no config recorded" "$H/.config/agent-flow-kit/auto-update.json"
assert_missing "occupied: no timer installed" "$H/$UNIT_REL.timer"
run_afk "$H" linux occupied-status status --json
assert_eq "occupied: status not enrolled" "$(jq -r .extra.auto_update.enrolled "$OUT/occupied-status.out" 2>/dev/null)" "false"

head1 "A scheduler that will not enable leaves nothing enrolled"
H="$(new_home enablefail)"
AFK_TEST_SYSTEMCTL_FAIL=1 run_afk "$H" linux enablefail enroll-auto-update --key-ref op://develop/good/notesPlain
if (( RC != 0 )); then ok "enable failure exits non-zero ($RC)"; else bad "enable failure exits non-zero" "exit 0"; fi
assert_contains "enable failure is named" "$(cat "$OUT/enablefail.err")" "SCHEDULER_UNAVAILABLE"
assert_absent "enable failure never reports ENROLLED" "$(cat "$OUT/enablefail.out")" "ENROLLED"
assert_missing "enable failure: no stale timer" "$H/$UNIT_REL.timer"
assert_missing "enable failure: no stale service" "$H/$UNIT_REL.service"
assert_missing "enable failure: no config recorded" "$H/.config/agent-flow-kit/auto-update.json"
run_afk "$H" linux enablefail-status status --json
assert_eq "enable failure: status not enrolled" "$(jq -r .extra.auto_update.enrolled "$OUT/enablefail-status.out" 2>/dev/null)" "false"

head1 "Linux re-enrollment that fails puts the previous timer back"
H="$(new_home rollback)"
RB_CONFIG_PATH="$H/.config/agent-flow-kit/auto-update.json"
jq '.check_interval_seconds = 1800' "$POLICY" >"$TMPROOT/policy-1800.json"
run_afk "$H" linux rb-enroll enroll-auto-update --key-ref op://develop/good/notesPlain
assert_eq "rollback: the first enrollment succeeds" "$RC" "0"
RB_TIMER="$(cksum <"$H/$UNIT_REL.timer")"; RB_SERVICE="$(cksum <"$H/$UNIT_REL.service")"
RB_CONFIG="$(cksum <"$RB_CONFIG_PATH")"
RB_CALLS=""
rb_run() { # <name> <failing-steps> — re-enroll at 1800s with those systemctl steps failing
  local mark
  rm -f "$H"/.stub-count-*
  mark="$(wc -l <"$LOG")"
  AFK_TEST_SYSTEMCTL_FAIL="$2" AFK_TEST_POLICY="$TMPROOT/policy-1800.json" \
    run_afk "$H" linux "$1" enroll-auto-update --key-ref op://develop/good/notesPlain
  RB_CALLS="$(tail -n +"$((mark + 1))" "$LOG")"
  if (( RC != 0 )); then ok "$1: exits non-zero ($RC)"; else bad "$1: exits non-zero" "exit 0"; fi
  assert_absent "$1: never reports ENROLLED" "$(cat "$OUT/$1.out")" "ENROLLED"
  assert_eq "$1: previous timer file kept" "$(cksum <"$H/$UNIT_REL.timer")" "$RB_TIMER"
  assert_eq "$1: previous service file kept" "$(cksum <"$H/$UNIT_REL.service")" "$RB_SERVICE"
  assert_eq "$1: config kept" "$(cksum <"$RB_CONFIG_PATH" 2>/dev/null)" "$RB_CONFIG"
}
rb_run rb-enable enable-now
assert_contains "rb-enable: says the previous units were restored" "$(cat "$OUT/rb-enable.err")" "state and the config were restored"
assert_contains "rb-enable: reloads after restoring the files" "$RB_CALLS" \
  "systemctl --user enable --now afk-release-reconcile.timer"$'\n'"systemctl --user daemon-reload"
assert_contains "rb-enable: previous active state restored" "$RB_CALLS" "systemctl --user start afk-release-reconcile.timer"
run_afk "$H" linux rb-status status --json
assert_eq "rb-enable: status still enrolled" "$(jq -r .extra.auto_update.enrolled "$OUT/rb-status.out" 2>/dev/null)" "true"

rb_run rb-reload daemon-reload
assert_contains "rb-reload: the unloaded case is named" "$(cat "$OUT/rb-reload.err")" "nothing was unscheduled"
assert_absent "rb-reload: nothing unscheduled" "$RB_CALLS" "disable"
assert_absent "rb-reload: nothing enabled" "$RB_CALLS" "enable --now"
assert_eq "rb-reload: timer still enabled" "$([[ -f "$H/.stub-timer-enabled" ]] && echo y)" "y"

for rb in "daemon-reload@2:daemon-reload" "enable:enable" "start:start"; do
  rb_run "rb-fail-${rb%%:*}" "enable-now ${rb%%:*}"
  assert_contains "rb-fail-${rb%%:*}: ROLLBACK_FAILED names the step" "$(cat "$OUT/rb-fail-${rb%%:*}.err")" \
    "ROLLBACK_FAILED: systemctl --user could not enable the new afk-release-reconcile.timer and restoring the previous one failed at ${rb#*:}"
  assert_absent "rb-fail-${rb%%:*}: never claims a restore" "$(cat "$OUT/rb-fail-${rb%%:*}.err")" "were restored"
done

# The previous timer was enabled but not running: enable --now starts it, the
# scheduler check then fails, and the rollback stops it again.
rm -f "$H/.stub-timer-active"
rb_run rb-inactive is-enabled@2
assert_contains "rb-inactive: the restore is reported" "$(cat "$OUT/rb-inactive.err")" "state and the config were restored"
assert_contains "rb-inactive: stopped again" "$RB_CALLS" "systemctl --user stop afk-release-reconcile.timer"
assert_missing "rb-inactive: previous inactive state restored" "$H/.stub-timer-active"
assert_eq "rb-inactive: previous enabled state restored" "$([[ -f "$H/.stub-timer-enabled" ]] && echo y)" "y"

head1 "Linux: key, units, first attempt"
H="$(new_home linux)"
run_afk "$H" linux enroll1 enroll-auto-update --key-ref op://develop/good/notesPlain
assert_eq "enroll succeeds" "$RC" "0"
assert_eq "key installed with mode 0600" "$(mode_of "$H/$KEY_REL")" "600"
assert_contains "key content is what op returned" "$(cat "$H/$KEY_REL")" "AFKTESTKEYBYTES-GOOD"
SERVICE="$(cat "$H/$UNIT_REL.service" 2>/dev/null)"; TIMER="$(cat "$H/$UNIT_REL.timer" 2>/dev/null)"
assert_contains "service runs the installed client with --apply" "$SERVICE" \
  "ExecStart=\"$H/.agents/skills/afk-runtime/bin/afk-release-reconcile\" --apply"
assert_contains "service has a bounded timeout" "$SERVICE" "TimeoutStartSec="
assert_contains "timer uses the policy interval" "$TIMER" "OnUnitActiveSec=900"
assert_contains "timer is persistent" "$TIMER" "Persistent=true"
assert_contains "timer enabled as a user unit" "$(cat "$LOG")" "systemctl --user enable --now afk-release-reconcile.timer"
ENROLL1="$(cat "$OUT/enroll1.out")"
assert_eq "one summary line" "$(wc -l <"$OUT/enroll1.out" | tr -d ' ')" "1"
assert_contains "summary reports the state" "$ENROLL1" "auto-update: ENROLLED platform=linux interval=900s"
assert_contains "summary reports the first attempt" "$ENROLL1" "first_attempt=APPLIED/NO_CHANGE"
assert_contains "first attempt runs under timeout" "$(cat "$LOG")" \
  "timeout 600 $H/.agents/skills/afk-runtime/bin/afk-release-reconcile --apply"
assert_contains "no linger: says how to enable it" "$ENROLL1" "sudo loginctl enable-linger tester"
assert_absent "never runs sudo itself" "$(cat "$LOG")" "sudo"
assert_eq "config records the reference" \
  "$(jq -r .key_ref "$H/.config/agent-flow-kit/auto-update.json")" "op://develop/good/notesPlain"

TIMER_SUM="$(cksum <"$H/$UNIT_REL.timer")"
run_afk "$H" linux enroll2 enroll-auto-update --key-ref op://develop/good/notesPlain
assert_eq "re-run succeeds" "$RC" "0"
assert_contains "re-run leaves the key unchanged" "$(cat "$OUT/enroll2.out")" "(unchanged)"
assert_eq "re-run leaves the timer byte-identical" "$(cksum <"$H/$UNIT_REL.timer")" "$TIMER_SUM"
assert_eq "re-run leaves one key file" "$(find "$H/.config/agent-flow-kit/deploy-key" -type f | wc -l | tr -d ' ')" "1"

AFK_TEST_TIMEOUT_EXPIRE=1 run_afk "$H" linux timedout enroll-auto-update --key-ref op://develop/good/notesPlain
assert_eq "a timed-out first attempt still enrolls" "$RC" "0"
assert_contains "a timed-out first attempt reports TIMED_OUT" "$(cat "$OUT/timedout.out")" "first_attempt=TIMED_OUT"

AFK_TEST_POLICY="$TMPROOT/policy-1800.json" run_afk "$H" linux enroll3 enroll-auto-update --key-ref op://develop/good/notesPlain
assert_contains "timer follows a changed policy interval" "$(cat "$H/$UNIT_REL.timer")" "OnUnitActiveSec=1800"

mkdir -p "$H/.local/state/agent-flow-kit/releases"
printf '%s\n' '{"state":"RETAINED","reason":"FETCH_UNAVAILABLE","ended_at":"2026-09-24T00:00:00Z"}' \
  >"$H/.local/state/agent-flow-kit/releases/latest.json"
run_afk "$H" linux status status --json
assert_eq "status reports enrolled" "$(jq -r .extra.auto_update.enrolled "$OUT/status.out" 2>/dev/null)" "true"
assert_eq "status reports the last result" "$(jq -r .extra.auto_update.last_result.reason "$OUT/status.out" 2>/dev/null)" "FETCH_UNAVAILABLE"
run_afk "$H" linux status-human status
assert_contains "human status shows enrollment" "$(cat "$OUT/status-human.out")" "enrolled  platform=linux"

run_afk "$H" linux remove enroll-auto-update --remove
assert_eq "remove succeeds" "$RC" "0"
assert_missing "remove: timer gone" "$H/$UNIT_REL.timer"
assert_missing "remove: service gone" "$H/$UNIT_REL.service"
assert_contains "remove: deploy key left in place" "$(cat "$H/$KEY_REL")" "AFKTESTKEYBYTES-GOOD"
run_afk "$H" linux status-after status --json
assert_eq "status reports not enrolled after removal" "$(jq -r .extra.auto_update.enrolled "$OUT/status-after.out" 2>/dev/null)" "false"

head1 "--key-file reaches the units and the first attempt; % is escaped"
# The key stays below HOME: a key below the world-writable /tmp is one the
# release client refuses, so enrollment refuses it too.
H="$(new_home keyfile)"
CUSTOM_KEY="$H/custom-keys/custom_ed25519"
AFK_TEST_STATE_DIR="$H/pct%state/agent-flow-kit" \
  run_afk "$H" linux keyfile enroll-auto-update --key-ref op://develop/good/notesPlain --key-file "$CUSTOM_KEY"
assert_eq "enroll with --key-file succeeds" "$RC" "0"
assert_eq "custom key installed with mode 0600" "$(mode_of "$CUSTOM_KEY")" "600"
assert_eq "first attempt ran with the --key-file key" "$(cat "$H/.first-attempt-key" 2>/dev/null)" "$CUSTOM_KEY"
SERVICE="$(cat "$H/$UNIT_REL.service" 2>/dev/null)"
assert_contains "service passes the --key-file key" "$SERVICE" "AFK_RELEASE_DEPLOY_KEY=$CUSTOM_KEY\""
assert_contains "% in a unit value is escaped" "$SERVICE" "pct%%state/agent-flow-kit"
assert_absent "no unescaped % in the unit" "$SERVICE" "pct%state/"
run_afk "$H" linux keyfile-status status --json
assert_eq "status finds the recorded key path" "$(jq -r .extra.auto_update.key_present "$OUT/keyfile-status.out" 2>/dev/null)" "true"
: >"$LOG"
run_afk "$H" linux keyfile-check enroll-auto-update --check
assert_contains "--check uses the recorded key path" "$(cat "$LOG")" "-i '$CUSTOM_KEY'"
run_afk "$H" linux keyfile-remove enroll-auto-update --remove
assert_contains "--remove names the recorded key path" "$(cat "$OUT/keyfile-remove.out")" "deploy key at $CUSTOM_KEY"

head1 "Enrollment applies the release client's exact key rule"
# Both implementations run on the same fixtures: the client's function is
# lifted verbatim from bin/afk-release-reconcile, so neither can drift alone.
CLIENT_RULE="$(sed -n '/^deploy_key_is_usable() {$/,/^}$/p' "$KIT_ROOT/bin/afk-release-reconcile")"
assert_contains "the client rule is found" "$CLIENT_RULE" "deploy_key_is_usable() {"
P="$(new_home pin)"
mkdir -p "$P/.local/state/agent-flow-kit" "$P/.config/agent-flow-kit/deploy-key"
chmod 755 "$P/.local" "$P/.local/state" "$P/.local/state/agent-flow-kit" "$P/.agents" \
  "$P/.agents/skills" "$P/.agents/skills/afk-runtime" "$P/.config" "$P/.config/agent-flow-kit"
chmod 700 "$P/.config/agent-flow-kit/deploy-key"
PK="$P/.config/agent-flow-kit/deploy-key/agent-flow-kit_ed25519"
(umask 077; printf 'k\n' >"$PK"; printf 'k\n' >"$P/.local/state/agent-flow-kit/k"; printf 'k\n' >"$P/.agents/skills/afk-runtime/k")
pin() { # <label> <expected usable|refused> <key>
  local c l
  c="$(HOME="$P" DEPLOY_KEY="$3" STAT_EXEC="$(command -v stat)" \
    TRUSTED_DRIVER_SOURCE="$P/.agents/skills/afk-runtime" STATE_DIR="$P/.local/state/agent-flow-kit" \
    bash -c "$CLIENT_RULE"$'\n''deploy_key_is_usable && echo usable || echo refused')"
  # shellcheck disable=SC2016 # expanded by the child shell
  l="$(HOME="$P" AFK_AU_RUNTIME_BIN="$P/.agents/skills/afk-runtime/bin" AFK_STATE_DIR="$P/.local/state/agent-flow-kit" \
    bash -c '. "$1"; afk_au_key_usable "$2" && echo usable || echo refused' _ "$KIT_ROOT/lib/afk-auto-update.sh" "$3")"
  assert_eq "$1: client and enrollment agree" "$l" "$c"
  assert_eq "$1: $2" "$c" "$2"
}
pin "a private key below private directories" usable "$PK"
chmod 775 "$P/.config/agent-flow-kit"; pin "a group-writable parent" refused "$PK"
chmod 755 "$P/.config/agent-flow-kit"
chmod 757 "$P/.config"; pin "a world-writable grandparent" refused "$PK"; chmod 755 "$P/.config"
chmod 644 "$PK"; pin "a key others can read" refused "$PK"; chmod 600 "$PK"
ln -s "$PK" "$P/.config/agent-flow-kit/deploy-key/link"
pin "a symlinked key" refused "$P/.config/agent-flow-kit/deploy-key/link"
pin "a key in the state tree" refused "$P/.local/state/agent-flow-kit/k"
pin "a key in the runtime tree" refused "$P/.agents/skills/afk-runtime/k"

head1 "AFK's own config directory is tightened; other parents are not touched"
H="$(new_home own775)"
mkdir -p "$H/.config/agent-flow-kit"; chmod 755 "$H/.config"; chmod 775 "$H/.config/agent-flow-kit"
run_afk "$H" linux own775 enroll-auto-update --key-ref op://develop/good/notesPlain
assert_eq "a 775 ~/.config/agent-flow-kit still enrolls" "$RC" "0"
assert_eq "it loses group and world write" "$(mode_of "$H/.config/agent-flow-kit")" "755"
assert_contains "and enrollment says so" "$(cat "$OUT/own775.err")" "removed group and world write from $H/.config/agent-flow-kit"
assert_contains "then reports ENROLLED" "$(cat "$OUT/own775.out")" "auto-update: ENROLLED"
H="$(new_home foreign777)"
mkdir -p "$H/.config"; chmod 777 "$H/.config"
run_afk "$H" linux foreign777 enroll-auto-update --key-ref op://develop/good/notesPlain
assert_eq "a writable parent AFK does not own refuses (exit 4)" "$RC" "4"
assert_contains "the refusal prints the exact chmod" "$(cat "$OUT/foreign777.err")" "chmod go-w -- '$H/.config'"
assert_eq "that directory is left as it was" "$(mode_of "$H/.config")" "777"
assert_missing "no key installed" "$H/$KEY_REL"
assert_absent "never reports ENROLLED" "$(cat "$OUT/foreign777.out")" "ENROLLED"
# Both failing: the whole walk runs first, so AFK's own directory is not
# tightened on the way to a refusal.
H="$(new_home both)"
mkdir -p "$H/.config/agent-flow-kit"; chmod 777 "$H/.config"; chmod 775 "$H/.config/agent-flow-kit"
run_afk "$H" linux both enroll-auto-update --key-ref op://develop/good/notesPlain
assert_eq "own and a foreign parent both writable: refused (exit 4)" "$RC" "4"
assert_eq "the refusal changes nothing: own directory" "$(mode_of "$H/.config/agent-flow-kit")" "775"
assert_eq "the refusal changes nothing: the foreign parent" "$(mode_of "$H/.config")" "777"
assert_contains "one chmod fixes both" "$(cat "$OUT/both.err")" \
  "chmod go-w -- '$H/.config' '$H/.config/agent-flow-kit'"
assert_absent "no removal is claimed" "$(cat "$OUT/both.err")" "removed group and world write"
# A symlinked config directory: refused before anything is created or changed.
H="$(new_home cfglink)"
mkdir -p "$H/.config" "$TMPROOT/cfglink-target"; chmod 755 "$H/.config"; chmod 775 "$TMPROOT/cfglink-target"
ln -s "$TMPROOT/cfglink-target" "$H/.config/agent-flow-kit"
run_afk "$H" linux cfglink enroll-auto-update --key-ref op://develop/good/notesPlain
assert_eq "a symlinked ~/.config/agent-flow-kit refuses (exit 4)" "$RC" "4"
assert_contains "it is named as the unsafe directory" "$(cat "$OUT/cfglink.err")" \
  "KEY_PARENT_UNSAFE: $H/.config/agent-flow-kit is a symlink"
assert_eq "the link target keeps its mode" "$(mode_of "$TMPROOT/cfglink-target")" "775"
assert_eq "nothing is created through the link" "$(find "$TMPROOT/cfglink-target" -mindepth 1 | wc -l | tr -d ' ')" "0"
assert_absent "no removal is claimed" "$(cat "$OUT/cfglink.err")" "removed group and world write"
# ~/.config itself links outside HOME: AFK's directory resolves there and is
# not AFK's to tighten.
H="$(new_home outside)"
mkdir -p "$TMPROOT/outside-config/agent-flow-kit"; chmod 775 "$TMPROOT/outside-config/agent-flow-kit"
ln -s "$TMPROOT/outside-config" "$H/.config"
run_afk "$H" linux outside enroll-auto-update --key-ref op://develop/good/notesPlain
assert_eq "a config directory outside HOME refuses (exit 4)" "$RC" "4"
assert_eq "the directory outside HOME is untouched" "$(mode_of "$TMPROOT/outside-config/agent-flow-kit")" "775"
assert_absent "no removal is claimed" "$(cat "$OUT/outside.err")" "removed group and world write"

head1 "macOS: an explicit bash 4.2+ interpreter, never a shebang (AC-1)"
H="$(new_home nobash)"
AFK_TEST_BASH_CANDIDATES="$STUBS/bash-old" run_afk "$H" darwin nobash enroll-auto-update --key-ref op://develop/good/notesPlain
assert_eq "only bash 3.2 available refuses (exit 4)" "$RC" "4"
assert_contains "the refusal is named" "$(cat "$OUT/nobash.err")" "MODERN_BASH_REQUIRED"
assert_missing "no modern bash: no plist written" "$H/$PLIST_REL"
assert_missing "no modern bash: no key installed" "$H/$KEY_REL"
assert_missing "no modern bash: no config recorded" "$H/.config/agent-flow-kit/auto-update.json"
H="$(new_home prefbash)"
AFK_TEST_BASH_CANDIDATES="$STUBS/bash-new:$STUBS/bash-old" \
  run_afk "$H" darwin prefbash enroll-auto-update --key-ref op://develop/good/notesPlain
assert_eq "a modern bash ahead of an old one enrolls" "$RC" "0"
assert_contains "the modern candidate is chosen, not the old one" "$(cat "$H/$PLIST_REL")" "<string>$STUBS/bash-new</string>"

head1 "macOS re-enrollment upgrades an old-format plist in place (AC-4)"
H="$(new_home oldformat)"
mkdir -p "$H/Library/LaunchAgents"
cat >"$H/$PLIST_REL" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>io.github.jlengelbrecht.agent-flow-kit.update-check</string>
  <key>ProgramArguments</key><array>
    <string>$H/.agents/skills/afk-runtime/bin/agent-flow-kit</string>
    <string>enroll-auto-update</string><string>--check</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin</string>
  </dict>
  <key>StartInterval</key><integer>900</integer>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST
run_afk "$H" darwin oldformat enroll-auto-update --key-ref op://develop/good/notesPlain
assert_eq "re-enroll over an old-format plist succeeds" "$RC" "0"
NEWPLIST="$(cat "$H/$PLIST_REL" 2>/dev/null)"
assert_contains "the old plist gains the explicit interpreter" "$NEWPLIST" "<string>$STUBS/bash-new</string>"
assert_contains "the old plist gains the new PATH order" "$NEWPLIST" \
  "<key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>"
assert_contains "the old plist gains the log paths" "$NEWPLIST" "StandardOutPath"
assert_contains "the upgrade reloads via the existing bootout/bootstrap path" "$(cat "$LOG")" "launchctl bootout gui/"

head1 "macOS: a check-only agent"
H="$(new_home mac)"
run_afk "$H" darwin mac-enroll enroll-auto-update --key-ref op://develop/good/notesPlain
assert_eq "enroll succeeds" "$RC" "0"
PLIST="$(cat "$H/$PLIST_REL" 2>/dev/null)"
assert_contains "agent runs the check" "$PLIST" "<string>enroll-auto-update</string><string>--check</string>"
assert_absent "agent never applies" "$PLIST" "--apply"
assert_absent "agent never runs the release client" "$PLIST" "afk-release-reconcile"
assert_contains "agent uses the policy interval" "$PLIST" "<integer>900</integer>"
assert_contains "agent PATH puts homebrew/local ahead of the system bash" "$PLIST" \
  "<key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>"
assert_absent "agent PATH is not the enrolling shell's" "$PLIST" "$STUBS:"
assert_contains "the shebang no longer decides: arg0 is the resolved bash" "$PLIST" \
  "<array>"$'\n'"    <string>$STUBS/bash-new</string>"$'\n'"    <string>$H/.agents/skills/afk-runtime/bin/agent-flow-kit</string>"
assert_contains "agent loaded with launchctl" "$(cat "$LOG")" "launchctl bootstrap gui/"
assert_contains "check uses the pinned-key transport" "$(cat "$LOG")" "IdentitiesOnly=yes"
assert_contains "failures are logged: StandardOutPath" "$PLIST" \
  "<key>StandardOutPath</key><string>$H/Library/Logs/agent-flow-kit/update-check.log</string>"
assert_contains "failures are logged: StandardErrorPath" "$PLIST" \
  "<key>StandardErrorPath</key><string>$H/Library/Logs/agent-flow-kit/update-check.log</string>"
assert_eq "the log directory is private" "$(mode_of "$H/Library/Logs/agent-flow-kit")" "700"
assert_contains "summary reports the available update" "$(cat "$OUT/mac-enroll.out")" "first_attempt=update available: $REMOTE_HEAD"
CHECK="$H/.local/state/agent-flow-kit/auto-update-check.json"
assert_eq "check state records the update" "$(jq -r .state "$CHECK")" "UPDATE_AVAILABLE"
assert_eq "check state never applies" "$(jq -r .applies "$CHECK")" "false"
run_afk "$H" darwin mac-status status --json
assert_eq "status surfaces the update" "$(jq -r .extra.auto_update.update_available "$OUT/mac-status.out" 2>/dev/null)" "true"
au_status() { # <home> <applied-revision> — the status section as status computes it
  # shellcheck disable=SC2016
  env -i PATH="$STUBS:$PATH" HOME="$1" AFK_TEST_LOG="$LOG" AFK_AUTO_UPDATE_PLATFORM=darwin \
    AFK_STATE_DIR="$1/.local/state/agent-flow-kit" AFK_SKILLS_HOME="$1/.agents/skills" \
    AFK_INSTALL_ROOT="$KIT_ROOT" AFK_RELEASE_POLICY="$POLICY" AFK_APPLIED_REVISION="$2" \
    bash -c 'source "$AFK_INSTALL_ROOT/lib/afk-auto-update.sh" && afk_auto_update_status_json'
}
assert_eq "a check older than the applied revision is not reported" \
  "$(au_status "$H" "$REMOTE_HEAD" | jq -r .update_available)" "false"
assert_eq "a different applied revision still reports the update" \
  "$(au_status "$H" "2222222222222222222222222222222222222222" | jq -r .update_available)" "true"

head1 "status tells the truth about a failed or stale check, not a quiet false (AC-3)"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq --arg t "$NOW_ISO" '.state="CURRENT" | .checked_at=$t' "$CHECK" >"$CHECK.tmp" && mv "$CHECK.tmp" "$CHECK"
assert_eq "a fresh successful check is healthy" "$(au_status "$H" "" | jq -r .health)" "ok"
jq --arg t "$NOW_ISO" '.state="CHECK_FAILED" | .checked_at=$t' "$CHECK" >"$CHECK.tmp" && mv "$CHECK.tmp" "$CHECK"
assert_eq "a failed check reports last_run_failed, never a quiet false" "$(au_status "$H" "" | jq -r .health)" "last_run_failed"
assert_eq "update_available never claims current on a failed check" "$(au_status "$H" "" | jq -r .update_available)" "false"
jq '.state="CURRENT" | .checked_at="2000-01-01T00:00:00Z"' "$CHECK" >"$CHECK.tmp" && mv "$CHECK.tmp" "$CHECK"
assert_eq "an old successful check reports check_stale" "$(au_status "$H" "" | jq -r .health)" "check_stale"

au_status_linux() { # <home> — the status section as status computes it, Linux side
  # shellcheck disable=SC2016
  env -i PATH="$STUBS:$PATH" HOME="$1" AFK_TEST_LOG="$LOG" AFK_AUTO_UPDATE_PLATFORM=linux \
    AFK_STATE_DIR="$1/.local/state/agent-flow-kit" AFK_SKILLS_HOME="$1/.agents/skills" \
    AFK_INSTALL_ROOT="$KIT_ROOT" AFK_RELEASE_POLICY="$POLICY" \
    AFK_TEST_SYSTEMCTL_RESULT="${AFK_TEST_SYSTEMCTL_RESULT:-success}" \
    AFK_TEST_SYSTEMCTL_EXITCODE="${AFK_TEST_SYSTEMCTL_EXITCODE:-0}" \
    bash -c 'source "$AFK_INSTALL_ROOT/lib/afk-auto-update.sh" && afk_auto_update_status_json'
}
HL="$(new_home linux-health)"
mkdir -p "$HL/.local/state/agent-flow-kit/releases"
printf '{"state":"CONVERGED","reason":"RELEASE_APPLIED","ended_at":"%s"}\n' "$NOW_ISO" \
  >"$HL/.local/state/agent-flow-kit/releases/latest.json"
assert_eq "linux: a healthy recent apply is ok" "$(au_status_linux "$HL" | jq -r .health)" "ok"
assert_eq "linux: a non-zero last run is reported honestly, not just the client's own report" \
  "$(AFK_TEST_SYSTEMCTL_RESULT=exit-code AFK_TEST_SYSTEMCTL_EXITCODE=1 au_status_linux "$HL" | jq -r .health)" "last_run_failed"
printf '{"state":"CONVERGED","reason":"RELEASE_APPLIED","ended_at":"2000-01-01T00:00:00Z"}\n' \
  >"$HL/.local/state/agent-flow-kit/releases/latest.json"
assert_eq "linux: an old successful apply reports check_stale" "$(au_status_linux "$HL" | jq -r .health)" "check_stale"

head1 "macOS: the check runs catalog-sync hermetically and keeps the check's exit"
CS_STATE="$H/.local/state/agent-flow-kit/catalog/latest.json"
: >"$LOG"
run_afk "$H" darwin mac-check enroll-auto-update --check
assert_eq "mac --check exits as afk_au_check does (0, update available)" "$RC" "0"
assert_contains "mac --check reports the update" "$(cat "$OUT/mac-check.out")" "update available: $REMOTE_HEAD"
assert_contains "catalog-sync ran through the fake git" "$(cat "$LOG")" "cs-git -c credential.helper="
assert_contains "catalog-sync fetched only from the fake curl, at the sentinel commit" "$(cat "$LOG")" \
  "cs-curl https://raw.githubusercontent.com/jlengelbrecht/prox-ops/$CS_FAKE_SHA/"
assert_eq "no real git: the recorded commit is the sentinel" "$(jq -r .source_sha "$CS_STATE" 2>/dev/null)" "$CS_FAKE_SHA"
assert_eq "the fake curl failure is recorded, nothing installed" "$(jq -r .reason "$CS_STATE" 2>/dev/null)" "SOURCE_UNREACHABLE"
jq 'del(.trust.remote_url)' "$POLICY" >"$TMPROOT/policy-noremote.json"
: >"$LOG"
AFK_TEST_POLICY="$TMPROOT/policy-noremote.json" run_afk "$H" darwin mac-check-fail enroll-auto-update --check
assert_eq "a failed mac check still exits 5 after catalog-sync" "$RC" "5"
assert_contains "catalog-sync still ran through the fakes" "$(cat "$LOG")" "cs-curl https://raw.githubusercontent.com/jlengelbrecht/prox-ops/$CS_FAKE_SHA/"

head1 "macOS re-enrollment waits for bootout and never loses the working agent"
jq '.check_interval_seconds = 1800' "$POLICY" >"$TMPROOT/policy-1800.json"
AFK_TEST_POLICY="$TMPROOT/policy-1800.json" run_afk "$H" darwin mac-reenroll enroll-auto-update --key-ref op://develop/good/notesPlain
assert_eq "re-enroll succeeds once the old agent is gone" "$RC" "0"
assert_contains "launchd loaded the new interval" "$(cat "$H/.stub-agent-loaded" 2>/dev/null)" "<integer>1800</integer>"
printf '3\n' >"$H/.stub-bootstrap-fails"
run_afk "$H" darwin mac-fail enroll-auto-update --key-ref op://develop/good/notesPlain
if (( RC != 0 )); then ok "a failed re-enroll exits non-zero ($RC)"; else bad "a failed re-enroll exits non-zero" "exit 0"; fi
assert_absent "a failed re-enroll never reports ENROLLED" "$(cat "$OUT/mac-fail.out")" "ENROLLED"
assert_contains "the failure says the previous agent was restored" "$(cat "$OUT/mac-fail.err")" "previous agent and config were restored"
assert_contains "the previous plist is back" "$(cat "$H/$PLIST_REL" 2>/dev/null)" "<integer>1800</integer>"
assert_contains "launchd runs the previous agent again" "$(cat "$H/.stub-agent-loaded" 2>/dev/null)" "<integer>1800</integer>"
assert_eq "the previous config is kept" \
  "$(jq -r .key_ref "$H/.config/agent-flow-kit/auto-update.json" 2>/dev/null)" "op://develop/good/notesPlain"
run_afk "$H" darwin mac-fail-status status --json
assert_eq "still enrolled after the failed re-enroll" "$(jq -r .extra.auto_update.enrolled "$OUT/mac-fail-status.out" 2>/dev/null)" "true"

head1 "No key bytes anywhere but the key file"
LEAKS="$(grep -rl --exclude-dir=stubs AFKTESTKEYBYTES "$TMPROOT" 2>/dev/null \
  | grep -v -e "/$KEY_REL\$" -e "^$CUSTOM_KEY\$")"
assert_eq "no output, log, config, unit or state file carries key bytes" "$LEAKS" ""

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
