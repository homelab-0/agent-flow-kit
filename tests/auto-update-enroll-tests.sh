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
cat >"$STUBS/systemctl" <<'SH'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$AFK_TEST_LOG"
case "$2" in
  enable)     [[ -z "$AFK_TEST_SYSTEMCTL_FAIL" ]] || exit 1; : >"$HOME/.stub-timer-enabled" ;;
  disable)    rm -f "$HOME/.stub-timer-enabled" ;;
  is-enabled) if [[ -f "$HOME/.stub-timer-enabled" ]]; then echo enabled; else echo disabled; exit 1; fi ;;
esac
SH
cat >"$STUBS/launchctl" <<'SH'
#!/usr/bin/env bash
printf 'launchctl %s\n' "$*" >>"$AFK_TEST_LOG"
case "$1" in
  bootstrap) : >"$HOME/.stub-agent-loaded" ;;
  bootout)   rm -f "$HOME/.stub-agent-loaded" ;;
  print)     [[ -f "$HOME/.stub-agent-loaded" ]] ;;
esac
SH
printf '#!/usr/bin/env bash\nprintf "no\\n"\n' >"$STUBS/loginctl"
cat >"$STUBS/git" <<SH
#!/usr/bin/env bash
if [[ "\$1" == ls-remote ]]; then
  printf 'git-ssh %s\n' "\$GIT_SSH_COMMAND" >>"$LOG"
  printf '%s\trefs/heads/master\n' "$REMOTE_HEAD"; exit 0
fi
exec "$(command -v git)" "\$@"
SH
chmod +x "$STUBS"/*

new_home() { # <name> -> path; a home with a stub installed release client
  local h="$TMPROOT/$1"
  mkdir -p "$h/.agents/skills/afk-runtime/bin"
  cat >"$h/.agents/skills/afk-runtime/bin/afk-release-reconcile" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${AFK_RELEASE_DEPLOY_KEY:-unset}" >"$HOME/.first-attempt-key"
printf '%s\n' '{"schema":"afk-release-result/2","state":"APPLIED","reason":"NO_CHANGE"}'
SH
  chmod +x "$h/.agents/skills/afk-runtime/bin/afk-release-reconcile"
  printf '%s\n' "$h"
}

RC=0
run_afk() { # <home> <platform> <out-name> args... ; sets RC
  local h="$1" p="$2" o="$3"; shift 3
  env -i PATH="$STUBS:$PATH" HOME="$h" USER=tester LANG=C \
    AFK_STATE_DIR="$h/.local/state/agent-flow-kit" AFK_PM_DIR="$h/.local/state/agent-flow-kit/pm" \
    AFK_AUTO_UPDATE_PLATFORM="$p" AFK_OP_BIN="${AFK_TEST_OP:-$STUBS/op}" \
    AFK_RELEASE_POLICY="${AFK_TEST_POLICY:-$POLICY}" \
    AFK_TEST_PINNED="$PINNED" AFK_TEST_LOG="$LOG" AFK_TEST_SYSTEMCTL_FAIL="${AFK_TEST_SYSTEMCTL_FAIL:-}" \
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

jq '.check_interval_seconds = 1800' "$POLICY" >"$TMPROOT/policy-1800.json"
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
H="$(new_home 'pct%home')"
CUSTOM_KEY="$TMPROOT/custom-keys/custom_ed25519"
run_afk "$H" linux keyfile enroll-auto-update --key-ref op://develop/good/notesPlain --key-file "$CUSTOM_KEY"
assert_eq "enroll with --key-file succeeds" "$RC" "0"
assert_eq "custom key installed with mode 0600" "$(mode_of "$CUSTOM_KEY")" "600"
assert_eq "first attempt ran with the --key-file key" "$(cat "$H/.first-attempt-key" 2>/dev/null)" "$CUSTOM_KEY"
SERVICE="$(cat "$H/$UNIT_REL.service" 2>/dev/null)"
assert_contains "service passes the --key-file key" "$SERVICE" "AFK_RELEASE_DEPLOY_KEY=$CUSTOM_KEY\""
assert_contains "% in a unit value is escaped" "$SERVICE" "pct%%home/.local/state"
assert_absent "no unescaped % in the unit" "$SERVICE" "pct%home/"

head1 "macOS: a check-only agent"
H="$(new_home mac)"
run_afk "$H" darwin mac-enroll enroll-auto-update --key-ref op://develop/good/notesPlain
assert_eq "enroll succeeds" "$RC" "0"
PLIST="$(cat "$H/$PLIST_REL" 2>/dev/null)"
assert_contains "agent runs the check" "$PLIST" "<string>enroll-auto-update</string><string>--check</string>"
assert_absent "agent never applies" "$PLIST" "--apply"
assert_absent "agent never runs the release client" "$PLIST" "afk-release-reconcile"
assert_contains "agent uses the policy interval" "$PLIST" "<integer>900</integer>"
assert_contains "agent PATH is fixed" "$PLIST" "<key>PATH</key><string>/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin</string>"
assert_absent "agent PATH is not the enrolling shell's" "$PLIST" "$STUBS"
assert_contains "agent loaded with launchctl" "$(cat "$LOG")" "launchctl bootstrap gui/"
assert_contains "check uses the pinned-key transport" "$(cat "$LOG")" "IdentitiesOnly=yes"
assert_contains "summary reports the available update" "$(cat "$OUT/mac-enroll.out")" "first_attempt=update available: $REMOTE_HEAD"
CHECK="$H/.local/state/agent-flow-kit/auto-update-check.json"
assert_eq "check state records the update" "$(jq -r .state "$CHECK")" "UPDATE_AVAILABLE"
assert_eq "check state never applies" "$(jq -r .applies "$CHECK")" "false"
run_afk "$H" darwin mac-status status --json
assert_eq "status surfaces the update" "$(jq -r .extra.auto_update.update_available "$OUT/mac-status.out" 2>/dev/null)" "true"

head1 "No key bytes anywhere but the key file"
LEAKS="$(grep -rl --exclude-dir=stubs AFKTESTKEYBYTES "$TMPROOT" 2>/dev/null \
  | grep -v -e "/$KEY_REL\$" -e "^$CUSTOM_KEY\$")"
assert_eq "no output, log, config, unit or state file carries key bytes" "$LEAKS" ""

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
