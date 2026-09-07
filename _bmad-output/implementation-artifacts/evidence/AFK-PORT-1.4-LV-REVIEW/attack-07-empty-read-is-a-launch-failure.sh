#!/usr/bin/env bash
# Attack 2 — "an empty credential read is reported as a LAUNCH FAILURE and never
# as status: done." The suite cannot test this: its stub `orca terminal create`
# never executes the command text and its `terminal read` always answers
# status:"running". So drive orca_launch() directly against a stub whose status
# transitions the way a real terminal's would, and check what dispatch does.
set -uo pipefail
WT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/state"
fail=0

cat > "$BIN/orca" <<'STUB'
#!/usr/bin/env bash
sub="$1 $2"; shift 2 || true
case "$sub" in
  "terminal create") jq -n '{ok:true,result:{terminal:{handle:"term_stub"}}}' ;;
  "terminal read")
    jq -n --arg t "${STUB_TAIL:-}" --arg s "${STUB_STATUS:-running}" \
      '{ok:true,result:{terminal:{handle:"term_stub",status:$s,tail:($t|split("\n"))}}}' ;;
  *) jq -n '{ok:true,result:{}}' ;;
esac
STUB
chmod +x "$BIN/orca"

probe() { # <status> <tail> -> "rc|last stderr line"
  PATH="$BIN:$PATH" STUB_STATUS="$1" STUB_TAIL="$2" bash -c '
    . "'"$WT"'/files/model-router/scripts/dispatch.sh"
    orca_launch sel "title" "cmd" CLAUDE_EXIT 3
  ' _p 2>&1; printf '|%s' "$?"
}

echo "== the refusal path: terminal ended, no CLAUDE_EXIT line"
# The generated text exits 78 without printing a marker, so a real terminal ends
# with the refusal message and no CLAUDE_EXIT.
o="$(probe exited 'dispatch: gateway credential resolved EMPTY; refusing to start claude unauthenticated')"
printf '   %s\n' "$o"
rc="${o##*|}"
grep -q 'did not complete honestly' <<<"$o" && [[ "$rc" == "2" ]] \
  && echo "PASS refusal is reported as a launch failure (exit 2), not a result" \
  || { echo "FAIL refusal was not reported as a launch failure"; fail=1; }

echo "== and dispatch never reaches the result writer on that path"
grep -n 'orca_launch "\$selector"' "$WT/files/model-router/scripts/dispatch.sh" | sed 's/^/   /'
grep -n 'status:\$status' "$WT/files/model-router/scripts/dispatch.sh" | sed 's/^/   /'
echo "   (orca_launch dies before the jq that writes \${STORY}.result.json — die() exits)"

echo "== CONTROL: the same probe DOES harvest a real exit line"
o2="$(probe running 'some output
CLAUDE_EXIT=0')"
printf '   %s\n' "$o2"
[[ "${o2##*|}" == "0" ]] && echo "PASS control: a real CLAUDE_EXIT line is harvested (exit 0)" \
                         || { echo "FAIL control broken"; fail=1; }

echo "== the OTHER shape a real terminal may take: it outlives the command"
# dispatch.sh's own header says the terminal outlives its command. If Orca keeps
# reporting status:running after the refusal, orca_launch cannot see the end and
# polls to LAUNCH_TIMEOUT (default 5400s) before failing.
o3="$(probe running 'dispatch: gateway credential resolved EMPTY; refusing to start claude unauthenticated')"
printf '   %s\n' "$o3"
if grep -q 'giving up rather than guessing' <<<"$o3"; then
  echo "NOTE still fail-closed, but only after the full launch timeout elapses"
else
  echo "FAIL neither branch fired"; fail=1
fi
echo "== what the suite's own stub answers (why this is untested there) =="
grep -n 'status:"running"' "$WT/tests/run-tests.sh" | sed 's/^/   /'
exit $fail
