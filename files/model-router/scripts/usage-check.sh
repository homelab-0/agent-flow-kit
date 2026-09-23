#!/usr/bin/env bash
# usage-check.sh — OBSERVABILITY ONLY. Pool temperature across the subscriptions
# the native harnesses are signed into, for a human to read.
#
# This script emits NO ROUTING GUIDANCE and is not a routing input. Routing is
# decided by POST /v1/route against the central catalog, which already knows the
# entitlement picture; a second, local, threshold-based opinion about which pool
# to prefer was one of three competing routing authorities and has been retired.
# Read this to understand what you are seeing, or to decide whether to have a
# conversation about re-routing — the re-route itself is a new /v1/route call.
#
# Honest coverage (as of 2026-08):
#   claude — real numbers via ccstatusline-usage (same source as Josh's statusline)
#   codex  — NO headless usage surface (TUI /status only) → reported unknown
#   devin  — NO CLI usage surface (website only) → reported unknown
# An unknown pool is simply unknown. There is no longer a runtime fallback chain
# covering it reactively: dispatch.sh never re-routes.

set -uo pipefail

BUNX="$(command -v bunx || echo "$HOME/.bun/bin/bunx")"

strip_ansi() { sed -e 's/\x1b\[[0-9;]*m//g'; }

# model.id must be a real Claude model or the package skips the usage bars
claude_line="$(echo '{"session_id":"usage-check","model":{"id":"claude-fable-5"},"workspace":{"current_dir":"'"$PWD"'"}}' \
  | timeout 45 "$BUNX" -y ccstatusline-usage@latest 2>/dev/null | strip_ansi | tr '\n' ' ')"

# -a + LC_ALL=C: residual escape bytes make grep treat the line as binary and
# silently suppress -o output otherwise
g() { LC_ALL=C grep -aoE "$1" <<<"$claude_line"; }
session_pct="$(g 'Session:[^%]*[0-9.]+%' | LC_ALL=C grep -aoE '[0-9.]+%' | tail -1)"
weekly_pct="$(g 'Weekly:[^%]*[0-9.]+%'   | LC_ALL=C grep -aoE '[0-9.]+%' | tail -1)"
reset_hr="$(g '[0-9]+:[0-9]+[^0-9]*hr' | head -1 | LC_ALL=C tr -cd '0-9:hr ' )"

if [[ -n "${weekly_pct:-}" ]]; then
  echo "claude:  session ${session_pct:-?} | weekly ${weekly_pct} | session resets in ${reset_hr:-?}   (Max 20x — the big pool)"
else
  echo "claude:  UNKNOWN — ccstatusline-usage probe failed; assume warm and rely on fallbacks"
fi

# --- codex: parse the rate_limits snapshot from the newest session JSONL -------
# codex writes rate_limits into token_count events: primary = 5h window,
# secondary = weekly, each with used_percent + resets_in_seconds. Same data as
# TUI /status, zero network. --probe-codex forces a fresh snapshot via one tiny
# luna call (costs a sliver of the Pro pool — use sparingly).
codex_home="${CODEX_HOME:-}"
# shellcheck disable=SC2012  # deliberate: -d on a glob of KNOWN Orca-managed
# account dirs (uuid-named, never exotic). `find` here would need two -path
# expressions and BSD/GNU divergence for no gain; this form is portable as-is.
[[ -z "$codex_home" ]] && codex_home="$(ls -d "$HOME"/.config/orca/codex-accounts/*/home "$HOME/Library/Application Support/orca/codex-accounts/"*/home 2>/dev/null | head -1)"
[[ -z "$codex_home" ]] && codex_home="$HOME/.codex"

if [[ "${1:-}" == "--probe-codex" ]]; then
  (cd /tmp && timeout 120 codex exec --skip-git-repo-check -m gpt-5.6-luna "Reply with only: ok" >/dev/null 2>&1) || true
fi

# portable (BSD find has no -printf): rollout basenames embed the timestamp, so
# sorting by basename is chronological
newest_session="$(find "$codex_home/sessions" "$HOME/.codex/sessions" -name 'rollout-*.jsonl' 2>/dev/null | awk -F/ '{print $NF" "$0}' | sort | tail -1 | cut -d' ' -f2-)"
if [[ -n "$newest_session" ]]; then
  # schema note (verified 2026-08-16, codex 0.145/pro): windows are labeled by
  # window_minutes (~300 = 5h, ~10080 = weekly); on Pro, primary IS the weekly
  # window and secondary is null. resets_at is epoch seconds. plan_type lives
  # alongside rate_limits in the same object (e.g. "pro") — read it, never assume it.
  rl_json="$(grep -a '"rate_limits"' "$newest_session" 2>/dev/null | tail -1 \
    | jq -c '[.. | objects | select(has("rate_limits")) | .rate_limits] | last // empty' 2>/dev/null)"
  c5h="$(jq -r '[.primary, .secondary] | map(select(. != null and .window_minutes != null)) | map(select(.window_minutes < 1000))  | (first.used_percent // "?")' <<<"$rl_json" 2>/dev/null)"
  cwk="$(jq -r '[.primary, .secondary] | map(select(. != null and .window_minutes != null)) | map(select(.window_minutes >= 1000)) | (first.used_percent // "?")' <<<"$rl_json" 2>/dev/null)"
  wk_reset="$(jq -r '[.primary, .secondary] | map(select(. != null and .window_minutes != null)) | map(select(.window_minutes >= 1000)) | (first.resets_at // empty)' <<<"$rl_json" 2>/dev/null)"
  [[ -n "$wk_reset" ]] && wk_reset=" | weekly resets $(date -d "@$wk_reset" '+%a %H:%M' 2>/dev/null)"
  codex_plan="$(jq -r '.plan_type // empty' <<<"$rl_json" 2>/dev/null)"
  codex_plan="${codex_plan:-unknown}"
  age_min=$(( ( $(date +%s) - $(stat -c %Y "$newest_session") ) / 60 ))
  if [[ -n "$rl_json" ]]; then
    echo "codex:   plan=${codex_plan}  5h ${c5h:-?}% | weekly ${cwk:-?}%${wk_reset:-} | snapshot ${age_min}min old   (ChatGPT — pool shared with opencode/gpt-6-astra)"
  else
    echo "codex:   snapshot found but no rate_limits parsed (${newest_session##*/}) — treat as unknown"
  fi
else
  echo "codex:   no local snapshot yet — appears after the first codex run, or force one with: usage-check.sh --probe-codex   (ChatGPT — pool shared with opencode/gpt-6-astra)"
fi

# --- opencode: 7-day assistant-message token totals by model, from its local db ---
# opencode has no usage/quota API. Its local sqlite store (message.data JSON:
# role, modelID, tokens.total, time.created epoch ms) at least shows how much it
# has drawn per model recently — e.g. gpt-6-astra riding the same ChatGPT pool
# Codex reports above. Read-only query; never writes.
opencode_db="$HOME/.local/share/opencode/opencode.db"
if ! command -v sqlite3 >/dev/null; then
  echo "opencode: unknown (sqlite3 not on PATH)"
elif [[ ! -f "$opencode_db" ]]; then
  echo "opencode: unknown (no local db at $opencode_db)"
else
  oc_rows="$(timeout 30 sqlite3 -readonly "$opencode_db" \
    "select json_extract(data,'\$.modelID'), sum(json_extract(data,'\$.tokens.total'))
     from message
     where json_extract(data,'\$.role')='assistant'
       and json_extract(data,'\$.time.created') >= (strftime('%s','now')-7*86400)*1000
     group by 1 order by 2 desc;" 2>/dev/null)"
  if [[ -n "$oc_rows" ]]; then
    oc_summary="$(echo "$oc_rows" | awk -F'|' '{printf "%s%s %s tok", (NR>1?", ":""), $1, $2}')"
    echo "opencode: last 7d — ${oc_summary}   (draws the same ChatGPT pool via gpt-6-astra)"
  else
    echo "opencode: unknown (no assistant messages in the last 7 days)"
  fi
fi

# --- devin: v3 org API (service user) + app billing status (CLI key) -----------
# Verified 2026-08-16. Quota PERCENTAGES are browser-session-only
# (app.devin.ai/api/org-*/billing/quota/usage rejects every token type) — check
# them at app.devin.ai/org/homelab-0/settings/usage. What tokens CAN see:
#   consumption burn  — v3 /consumption/daily (Member service user, 1P item
#                       "Devin Analytics" in vault develop; org-level, non-personal)
#   billing safety    — app /api/org-*/billing/status via the CLI's own
#                       windsurf_api_key (overage pot, auto-recharge flag)
# Free models (swe-1-7*, swe-1-6, glm-5-2) never draw quota regardless.
DEVIN_ORG="org-fcb0104a5e5a4468b2f6fe97a4b4f3cf"
dk="${DEVIN_SERVICE_KEY:-}"
if [[ -z "$dk" ]] && command -v op >/dev/null; then
  dk="$(timeout 60 op read "${DEVIN_SERVICE_KEY_OP_REF:-op://develop/Devin Analytics/credential}" 2>/dev/null || true)"
fi
if [[ -n "$dk" ]]; then
  cons="$(timeout 30 curl -sf "https://api.devin.ai/v3/organizations/$DEVIN_ORG/consumption/daily" -H "Authorization: Bearer $dk" 2>/dev/null)"
  acus="$(jq -r '.total_acus // "?"' <<<"$cons" 2>/dev/null)"
else
  acus="? (no service-user key — 1P item 'Devin Analytics' unreadable)"
fi
wkey="$(grep '^windsurf_api_key' "$HOME/.local/share/devin/credentials.toml" 2>/dev/null | sed 's/.*= *"\?//;s/"$//')"
if [[ -n "$wkey" ]]; then
  bst="$(timeout 30 curl -sf "https://app.devin.ai/api/$DEVIN_ORG/billing/status" -H "Authorization: Bearer $wkey" 2>/dev/null)"
  overage="$(jq -r '.overage_credits // "?"' <<<"$bst" 2>/dev/null)"
  ar_flag="$(jq -r 'if .auto_recharge_enabled == true then " | WARNING: AUTO-RECHARGE IS ON" else "" end' <<<"$bst" 2>/dev/null)"
  echo "devin:   cycle consumption ${acus} ACU | on-demand pot \$${overage}${ar_flag}   (quota %: browser-only, see settings/usage; free models never draw quota)"
else
  echo "devin:   cycle consumption ${acus} ACU | billing status unavailable (no CLI credentials)   (quota %: browser-only; free models never draw quota)"
fi
echo ""
echo "These are observations, not routing guidance. Routing comes from POST /v1/route."
echo "A hot pool is a reason to talk about re-routing with the human, which means a NEW"
echo "/v1/route call and a NEW stamp — never a local re-route at dispatch time."
