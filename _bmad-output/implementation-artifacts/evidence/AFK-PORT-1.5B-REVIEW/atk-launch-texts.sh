#!/usr/bin/env bash
# ATTACK 2 — the frozen launch command texts, built from master and from HEAD,
# compared byte-for-byte for every class the builders expose. Independent of
# the repo's own oracle.
set -uo pipefail
ROOT="${AFK_REVIEW_ROOT:-$(git rev-parse --show-toplevel)}"
W=${TMP:-/tmp}/rev1.5b/lt; rm -rf "$W"; mkdir -p "$W/master" "$W/head"
git -C "$ROOT" show ec83010:files/model-router/scripts/dispatch.sh > "$W/master/dispatch.sh"
cp "$ROOT/files/model-router/scripts/dispatch.sh" "$W/head/dispatch.sh"
emit() { # <dispatch.sh>
  bash -c '
    set -uo pipefail
    source "$1" 2>/dev/null || true
    P=/tmp/rev1.5b/lt/prompt.txt; printf "PROMPT BODY\n" > "$P"
    PER=/tmp/rev1.5b/lt/persona.md; printf "PERSONA\n" > "$PER"
    R=/tmp/rev1.5b/lt/res.json
    echo "== claude plain"
    build_claude_command /h /usr/bin joe "$P" "claude-opus-5" "medium" "$R" "$PER" 2>&1; echo
    echo "== claude no-persona"
    build_claude_command /h /usr/bin joe "$P" "claude-opus-5" "medium" "$R" "" 2>&1; echo
    echo "== claude gateway"
    build_claude_gateway_command /h /usr/bin joe "$P" "qwen3" "high" "$R" "$PER" "http://gw:4000" "op://v/i/f" "/e/op.env" "pl-abc" "128000" 2>&1; echo
    echo "== codex"
    build_codex_command "$P" "gpt-5" "medium" 2>&1; echo
  ' _ "$1"
}
emit "$W/master/dispatch.sh" > "$W/master.txt" 2>&1
emit "$W/head/dispatch.sh"   > "$W/head.txt"   2>&1
echo "master sha: $(sha256sum < "$W/master.txt")"
echo "head   sha: $(sha256sum < "$W/head.txt")"
if diff -u "$W/master.txt" "$W/head.txt"; then
  echo "RESULT: launch texts IDENTICAL across all classes"
else
  echo "RESULT: LAUNCH TEXTS DIFFER  <-- blocker"
fi
echo
echo "--- CONTROL (anti-vacuity): the comparison can see a difference ---"
sed 's/--effort/--effortX/' "$W/head.txt" > "$W/ctl.txt"
diff -q "$W/master.txt" "$W/ctl.txt" >/dev/null && echo "CONTROL FAILED (blind)" || echo "control ok: a seeded change is detected"
echo
echo "--- forbidden flags in the frozen texts ---"
grep -c 'stream-json' "$W/head.txt" | sed 's/^/stream-json occurrences: /'
grep -o -- '--json' "$W/head.txt" | wc -l | sed 's/^/codex --json occurrences: /'

exit 0   # trailing greps with zero matches must not read as a failed attack
