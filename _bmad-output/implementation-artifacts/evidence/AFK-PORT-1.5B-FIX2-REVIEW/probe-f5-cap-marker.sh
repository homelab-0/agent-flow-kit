#!/usr/bin/env bash
# Probe F5 — the CONTINUATION-CAP marker's suggested max_cycles is
# max(story limit, authorised cycle), so applying the remedy never lowers a
# limit the story already carries.
set -uo pipefail
SRC="${1:?dispatch.sh}"
source "$SRC" >/dev/null 2>&1 || true
M="$(mktemp)"; trap 'rm -f "$M"' EXIT
arity="$(declare -f refuse_continuation_cap | sed -n '/local marker=/p' | tr -s ' ')"
echo "signature locals:$arity"
row() { # <limit-arg> <cycle> <label>
  local out
  if refuse_continuation_cap "$M" "$2" 2 2 /p/policy.yaml "$1" 2>/dev/null; then :; fi
  out="$(grep -E '^\s*max_cycles:' "$M" | tr -d ' ')"
  printf '  story max_cycles=%-6s cycle=%s -> marker %s   [%s]\n' "${1:-<empty>}" "$2" "$out" "$3"
}
row 8   4 "larger existing limit KEPT (must be 8)"
row 3   4 "limit below the cycle raised to it (must be 4)"
row ""  4 "unreadable limit falls back to the cycle (must be 4)"
row abc 4 "non-numeric falls back to the cycle (must be 4)"
row 4   4 "equal (must be 4)"
echo -n "  marker states the non-lowering rule: "
grep -qF 'never lowers the limit you already have' "$M" && echo yes || echo NO
