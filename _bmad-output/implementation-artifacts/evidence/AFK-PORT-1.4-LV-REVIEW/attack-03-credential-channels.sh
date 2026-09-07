#!/usr/bin/env bash
# Attack 1 — credential leakage at TERMINAL RUNTIME (the half the suite's stubs
# cannot reach, because the stubbed `orca terminal create` never executes the
# command text). Each probe runs the real generated text in a real shell.
# Controls are inline: every probe that expects "absent" is paired with a
# positive case proving the probe can see the value when it IS there.
set -uo pipefail
WT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$WT/files/model-router/scripts/dispatch.sh"
set +e   # dispatch.sh carries `set -euo pipefail`

# SAFETY: this script inspects environments. It must never echo a REAL secret
# that happens to be ambient on the host, so every probe shell is started from a
# scrubbed environment and all output goes through a redactor.
CLEANENV=(env -u OP_SERVICE_ACCOUNT_TOKEN -u ANTHROPIC_AUTH_TOKEN -u ANTHROPIC_API_KEY
          -u OP_SESSION -u AGENT_ROUTER_TOKEN)
redact() { sed -E 's/ops_[A-Za-z0-9_-]{16,}/<REDACTED-SERVICE-ACCOUNT-TOKEN>/g;
                   s/sk-[A-Za-z0-9_-]{16,}/<REDACTED-KEY>/g'; }

SENT='SENTINEL-cred-8b12ef'
BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/home"
cat > "$BIN/op" <<S
#!/usr/bin/env bash
[[ "\$1" == "read" && -n "\${2:-}" ]] || exit 2
printf '%s' '$SENT'
S
cat > "$BIN/claude" <<S
#!/usr/bin/env bash
env > "$TMP/claude-env.txt"
sleep 0.4
cat > /dev/null
printf '{"result":"ok","is_error":false}'
S
chmod +x "$BIN/op" "$BIN/claude"
printf 'export OP_SERVICE_ACCOUNT_TOKEN=SA-SENTINEL-1234\n' > "$TMP/op-env"
printf 'prompt\n' > "$TMP/prompt"
mk() { build_claude_gateway_command "$TMP/home" "$BIN:/usr/bin:/bin" op "$TMP/prompt" \
        qwen36-27b high "$TMP/result.json" "" https://gw.invalid "op://v/i/f" "${1:-$TMP/op-env}" p 65536; }
CMD="$(mk)"
fail=0
say() { printf '%s %s\n' "$1" "$2"; [[ "$1" == FAIL ]] && fail=1; return 0; }

echo "== P1: the generated command text itself"
grep -q "$SENT" <<<"$CMD" && say FAIL "P1 credential value IS in the command text" || say PASS "P1 no credential value in the command text"
grep -q 'op://v/i/f' <<<"$CMD" && say PASS "P1 control: the REFERENCE is in the text (probe can see strings)" || say FAIL "P1 control broken"

echo "== P2: what survives in the terminal shell AFTER the command"
# The terminal shell outlives the command (dispatch.sh orca_launch header).
cat > "$TMP/after.sh" <<S
PATH="$BIN:/usr/bin:/bin"
$CMD
printf 'AFTER-VAR:[%s]\n' "\${ANTHROPIC_AUTH_TOKEN-<unset>}"
printf 'AFTER-SA:[%s]\n' "\${OP_SERVICE_ACCOUNT_TOKEN-<unset>}"
printf 'AFTER-ENV-DUMP:\n'; env | grep -E 'ANTHROPIC|OP_SERVICE' || echo '  (none)'
S
out="$("${CLEANENV[@]}" bash "$TMP/after.sh" 2>&1 | redact)"
printf '%s\n' "$out" | sed 's/^/   /'
grep -q "AFTER-VAR:\[<unset>\]" <<<"$out" && say PASS "P2 ANTHROPIC_AUTH_TOKEN is unset in the terminal shell afterwards" || say FAIL "P2 the resolved credential SURVIVES in the terminal shell"
grep -q "AFTER-SA:\[<unset>\]" <<<"$out" && say PASS "P2 OP_SERVICE_ACCOUNT_TOKEN never reaches the terminal shell (subshell claim holds)" || say FAIL "P2 the service-account token LEAKED into the terminal shell"

echo "== P3: is the resolved credential EXPORTED before the unset?"
# A command run between the assignment and the unset would inherit it only if
# the variable is exported. Probe by inserting an env-dumping child.
probe="${CMD/env -i HOME=/CHILD_ENV_PROBE=1 env | grep -c ANTHROPIC_AUTH_TOKEN > $TMP/exported.txt; env -i HOME=}"
( "${CLEANENV[@]}" bash -c "PATH=\"$BIN:/usr/bin:/bin\"; $probe" ) >/dev/null 2>&1
n="$(cat "$TMP/exported.txt" 2>/dev/null || echo ?)"
[[ "$n" == "0" ]] && say PASS "P3 the resolved credential is NOT exported (a sibling child cannot inherit it)" \
                  || say FAIL "P3 the resolved credential IS exported to children (count=$n)"
( "${CLEANENV[@]}" bash -c 'export ANTHROPIC_AUTH_TOKEN=x; env | grep -c ANTHROPIC_AUTH_TOKEN > "$0"' "$TMP/exported-ctl.txt" ) >/dev/null 2>&1
nc="$(cat "$TMP/exported-ctl.txt" 2>/dev/null || echo ?)"
[[ "$nc" == "1" ]] && say PASS "P3 control: the same probe DOES see an exported variable (count=$nc)" \
                   || say FAIL "P3 control broken (count=$nc)"

echo "== P4: xtrace inheritance (an operator shell with set -x, or SHELLOPTS/BASH_ENV)"
cat > "$TMP/xtrace.sh" <<S
set -x
PATH="$BIN:/usr/bin:/bin"
$CMD
S
xout="$("${CLEANENV[@]}" bash "$TMP/xtrace.sh" 2>&1 | redact)"
if grep -q "$SENT" <<<"$xout"; then
  say FAIL "P4 under set -x the credential VALUE is printed to the terminal buffer"
  printf '   first offending trace line: %s\n' "$(grep -m1 -o ".\{0,40\}$SENT.\{0,20\}" <<<"$xout")"
else
  say PASS "P4 set -x does not print the credential"
fi
# same via inherited SHELLOPTS (no rc file needed, env only)
xout2="$("${CLEANENV[@]}" PATH="$BIN:/usr/bin:/bin" bash -o xtrace -c "$CMD" 2>&1 | redact)"
grep -q "$SENT" <<<"$xout2" && say FAIL "P4b bash -o xtrace prints the credential" \
                            || say PASS "P4b bash -o xtrace does not print the credential"

echo "== P5: /proc/<pid>/cmdline of \`env\` before exec (disclosed residual 1)"
ls -l /proc/self/cmdline | sed 's/^/   /'
mnt="$(awk '$2=="/proc"{print $4}' /proc/self/mounts)"
printf '   /proc mount options: %s\n' "$mnt"
case "$mnt" in *hidepid=1*|*hidepid=2*|*hidepid=invisible*|*hidepid=ptraceable*)
    say PASS "P5 /proc is mounted with hidepid — cross-user cmdline reads are blocked" ;;
  *) say NOTE "P5 /proc has NO hidepid: /proc/<pid>/cmdline is mode 0444, world-readable by any local user" ;;
esac
# Demonstrate the window concretely: race a reader against the same construct.
# Bounded and quiet: only the racer's own process subtree is scanned.
cat > "$TMP/race.sh" <<S
PATH="$BIN:/usr/bin:/bin"
$CMD
S
found=no
deadline=$(( $(date +%s) + 45 ))
while [[ "$found" == no ]] && (( $(date +%s) < deadline )); do
  ( "${CLEANENV[@]}" bash "$TMP/race.sh" >/dev/null 2>&1 ) &
  racer=$!
  while kill -0 $racer 2>/dev/null; do
    if grep -rlZ "$SENT" /proc/[0-9]*/cmdline 2>/dev/null | head -c1 | grep -q .; then found=yes; break; fi
  done
  wait $racer 2>/dev/null
done
[[ "$found" == yes ]] && say NOTE "P5 REPRODUCED: an unprivileged poller read the credential from /proc/<pid>/cmdline during the launch" \
                      || say NOTE "P5 not observed in 10 polling rounds (the window is short; absence here is not proof of safety)"
printf '   /proc/<pid>/environ (post-exec, the steady state) permissions: %s\n' "$(stat -c '%A %U' /proc/self/environ)"

echo "== P6: the refusal path (empty read / op failure / unreadable env file)"
for case_ in "empty-read" "op-fails" "unreadable-env-file"; do
  case "$case_" in
    empty-read)  printf '#!/usr/bin/env bash\nprintf ""\n' > "$BIN/op"; C="$(mk)" ;;
    op-fails)    printf '#!/usr/bin/env bash\necho "op: authorization required for %s" >&2; exit 1\n' "$SENT" > "$BIN/op"; C="$(mk)" ;;
    unreadable-env-file) printf '#!/usr/bin/env bash\nprintf "%%s" "%s"\n' "$SENT" > "$BIN/op"; C="$(mk "$TMP/nope-not-here")" ;;
  esac
  chmod +x "$BIN/op"
  rm -f "$TMP/claude-env.txt" "$TMP/result.json"
  o="$( PATH="$BIN:/usr/bin:/bin" bash -c "$C" 2>&1 ); rc=$?"
  o="$( "${CLEANENV[@]}" PATH="$BIN:/usr/bin:/bin" bash -c "$C" 2>&1 | redact )"; rc=${PIPESTATUS[0]}
  printf '   [%s] rc=%s output=%s\n' "$case_" "$rc" "$(tr '\n' '|' <<<"$o")"
  grep -q 'CLAUDE_EXIT=' <<<"$o" && say FAIL "P6 [$case_] printed a CLAUDE_EXIT line (would be harvested as a real result)" \
                                 || say PASS "P6 [$case_] printed NO CLAUDE_EXIT line"
  [[ -f "$TMP/claude-env.txt" ]] && say FAIL "P6 [$case_] claude STARTED anyway" || say PASS "P6 [$case_] claude never started"
done
# control: the happy path DOES print a CLAUDE_EXIT line, so P6 is not vacuous
printf '#!/usr/bin/env bash\nprintf "%%s" "%s"\n' "$SENT" > "$BIN/op"; chmod +x "$BIN/op"
o="$( "${CLEANENV[@]}" PATH="$BIN:/usr/bin:/bin" bash -c "$(mk)" 2>&1 | redact )"
grep -q 'CLAUDE_EXIT=0' <<<"$o" && say PASS "P6 control: the happy path DOES print CLAUDE_EXIT=0" \
                                || say FAIL "P6 control broken"
exit $fail
