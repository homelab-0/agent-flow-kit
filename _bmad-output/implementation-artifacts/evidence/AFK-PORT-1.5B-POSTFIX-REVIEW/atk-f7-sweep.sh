#!/usr/bin/env bash
# F7/RES-9 — the unpublished-reason sweep now sees budget.usage_reason.
# Also measures what the union costs the ORIGINAL .reason sweep.
set -uo pipefail
ROOT="${AFK_REVIEW_ROOT:-$(git rev-parse --show-toplevel)}"
PUB_REASONS='["ROUTE_READY","NOT_A_REAL_ONE_A"]'   # stand-in readiness set
PUB_BUDGET='["USAGE_UNOBSERVABLE","HIGH_USAGE"]'
UNION="$(jq -nc --argjson a "$PUB_REASONS" --argjson b "$PUB_BUDGET" '$a + $b')"
sweep() { printf '%s' "$2" | jq -r --argjson pub "$1" \
  '[.. | objects | (.reason?, .usage_reason?) | select(type == "string")
    | . as $r | select(($pub | index($r)) == null)] | length'; }
echo "=== the fix: usage_reason is now swept ==="
printf 'published usage_reason      -> unpublished=%s (expect 0)\n' \
  "$(sweep "$UNION" '{"budget":{"usage_reason":"USAGE_UNOBSERVABLE"}}')"
printf 'invented usage_reason       -> unpublished=%s (expect 1)\n' \
  "$(sweep "$UNION" '{"budget":{"usage_reason":"NOT_A_PUBLISHED_CODE"}}')"
printf 'CONTROL invented .reason    -> unpublished=%s (expect 1)\n' \
  "$(sweep "$UNION" '{"readiness":{"reason":"NOT_A_PUBLISHED_CODE"}}')"
echo
echo "=== the cost of the union: a budget code in a readiness .reason now passes ==="
printf 'readiness .reason = HIGH_USAGE (a BUDGET code) -> unpublished=%s\n' \
  "$(sweep "$UNION" '{"readiness":{"reason":"HIGH_USAGE"}}')"
printf '  under the pre-fix set (readiness codes only) it would be     -> %s\n' \
  "$(sweep "$PUB_REASONS" '{"readiness":{"reason":"HIGH_USAGE"}}')"
echo "(the suite documents this trade-off in its own comment; recorded as a residual)"
