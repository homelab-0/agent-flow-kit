#!/usr/bin/env bash
# ATTACK 3 — the new prompt paragraph (AC-3): data never shell, byte-stable.
set -uo pipefail
ROOT="${AFK_REVIEW_ROOT:-$(git rev-parse --show-toplevel)}"
source "$ROOT/files/model-router/scripts/dispatch.sh" 2>/dev/null || true
set +e   # dispatch.sh sets -e when sourced; this attack script must keep running
rm -f /tmp/rev1.5b/PWNED
echo "--- injection: launcher value (the story path) carrying shell ---"
for s in '$(touch /tmp/rev1.5b/PWNED)story.md' \
         '`touch /tmp/rev1.5b/PWNED`story.md' \
         'a;touch /tmp/rev1.5b/PWNED;b.md' \
         '$(echo hi)/$USER/${HOME}/s.md' \
         'story with spaces.md'
do
  out="$(worker_discipline_paragraph "$s")"
  printf '%-42s -> path echoed as: %s\n' "$s" "$(grep -o "$(printf '%s' "$s" | sed 's/[.[\*^$()+?{|]/\\&/g').checkpoint.json" <<<"$out" | head -1)"
done
if [[ -e /tmp/rev1.5b/PWNED ]]; then echo "RESULT: SHELL EXECUTED  <-- blocker"; else echo "RESULT: no shell executed by any injected story path"; fi
echo
echo "--- CONTROL (anti-vacuity): the same probe DOES fire under eval ---"
( eval "echo \"\$(touch /tmp/rev1.5b/PWNED)\"" >/dev/null 2>&1 )
[[ -e /tmp/rev1.5b/PWNED ]] && echo "control ok: the probe is live" || echo "CONTROL FAILED"
rm -f /tmp/rev1.5b/PWNED
echo
echo "--- byte stability: 200 renders of the same input ---"
u="$(for i in $(seq 200); do worker_discipline_paragraph "docs/s-1.md" | sha256sum; done | sort -u | wc -l)"
echo "distinct digests over 200 runs: $u  (1 == byte-stable)"
worker_discipline_paragraph "docs/s-1.md" | sha256sum | sed 's/^/digest: /'
echo
echo "--- does it embed anything volatile? (timestamp / threshold / observed number) ---"
worker_discipline_paragraph "docs/s-1.md" | grep -nE '[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{4,}|ratio|threshold|token' || echo "none found"
echo
echo "--- story/persona CONTENT cannot reach the paragraph (only the path is an input) ---"
declare -f worker_discipline_paragraph | grep -cE '\$\(|`|cat .*\$story|eval' | sed 's/^/command-substitution or eval sites in the function body: /'

exit 0   # trailing grep with zero matches must not read as a failed attack
