#!/usr/bin/env bash
# github-health.sh — GitHub platform health gate for the dispatch flow.
# Source: the official public status API (githubstatus.com, Statuspage v2, no auth).
# Exit 0 = operational · 1 = degraded/outage (details on stdout) · 2 = undetermined.
# Policy: see "PR discipline" in ~/.claude/CLAUDE.md — on exit 1, HOLD PR creation,
# merges, and anything that must fork from a not-yet-merged develop; park finished
# work on its story branch; poll (~15 min) until green. Never batch stories into one
# PR because GitHub was down.
set -uo pipefail

s="$(curl -sf --max-time 15 https://www.githubstatus.com/api/v2/status.json)" || {
  echo "github: UNDETERMINED — cannot reach githubstatus.com (check local connectivity before blaming GitHub)"
  exit 2
}
ind="$(jq -r '.status.indicator // "unknown"' <<<"$s")"
desc="$(jq -r '.status.description // ""' <<<"$s")"

if [[ "$ind" == "none" ]]; then
  echo "github: operational ($desc)"
  exit 0
fi

echo "github: $ind — $desc"
curl -sf --max-time 15 https://www.githubstatus.com/api/v2/components.json 2>/dev/null \
  | jq -r '.components[] | select(.status != "operational") | "  degraded: \(.name) -> \(.status)"' 2>/dev/null
exit 1
