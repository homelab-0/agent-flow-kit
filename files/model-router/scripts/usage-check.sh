#!/usr/bin/env bash
# usage-check.sh — pool temperature across all subscriptions, for the router's
# pre-routing check. Run once at the START of a planning session, not per story.
#
# Honest coverage (as of 2026-08):
#   claude — real numbers via ccstatusline-usage (same source as Josh's statusline)
#   codex  — NO headless usage surface (TUI /status only) → reported unknown
#   devin  — NO CLI usage surface (website only) → reported unknown; free models
#            (swe-1-7*, swe-1-6, glm-5-2) never draw quota regardless
# Unknown pools are covered reactively by dispatch.sh's rate-limit fallback chains.

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
# luna call (costs a sliver of the Plus pool — use sparingly).
codex_home="${CODEX_HOME:-}"
[[ -z "$codex_home" ]] && codex_home="$(ls -d "$HOME"/.config/orca/codex-accounts/*/home 2>/dev/null | head -1)"
[[ -z "$codex_home" ]] && codex_home="$HOME/.codex"

if [[ "${1:-}" == "--probe-codex" ]]; then
  (cd /tmp && timeout 120 codex exec --skip-git-repo-check -m gpt-5.6-luna "Reply with only: ok" >/dev/null 2>&1) || true
fi

newest_session="$(find "$codex_home/sessions" "$HOME/.codex/sessions" -name 'rollout-*.jsonl' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
if [[ -n "$newest_session" ]]; then
  # schema note (verified 2026-08-16, codex 0.145/plus): windows are labeled by
  # window_minutes (~300 = 5h, ~10080 = weekly); on Plus, primary IS the weekly
  # window and secondary is null. resets_at is epoch seconds.
  rl_json="$(grep -a '"rate_limits"' "$newest_session" 2>/dev/null | tail -1 \
    | jq -c '[.. | objects | select(has("rate_limits")) | .rate_limits] | last // empty' 2>/dev/null)"
  c5h="$(jq -r '[.primary, .secondary] | map(select(. != null and .window_minutes != null)) | map(select(.window_minutes < 1000))  | (first.used_percent // "?")' <<<"$rl_json" 2>/dev/null)"
  cwk="$(jq -r '[.primary, .secondary] | map(select(. != null and .window_minutes != null)) | map(select(.window_minutes >= 1000)) | (first.used_percent // "?")' <<<"$rl_json" 2>/dev/null)"
  wk_reset="$(jq -r '[.primary, .secondary] | map(select(. != null and .window_minutes != null)) | map(select(.window_minutes >= 1000)) | (first.resets_at // empty)' <<<"$rl_json" 2>/dev/null)"
  [[ -n "$wk_reset" ]] && wk_reset=" | weekly resets $(date -d "@$wk_reset" '+%a %H:%M' 2>/dev/null)"
  age_min=$(( ( $(date +%s) - $(stat -c %Y "$newest_session") ) / 60 ))
  if [[ -n "$rl_json" ]]; then
    echo "codex:   5h ${c5h:-?}% | weekly ${cwk:-?}%${wk_reset:-} | snapshot ${age_min}min old   (ChatGPT Plus \$20/mo — SMALL pool: diversity/fallback, not bulk)"
  else
    echo "codex:   snapshot found but no rate_limits parsed (${newest_session##*/}) — treat as unknown"
  fi
else
  echo "codex:   no local snapshot yet — appears after the first codex run, or force one with: usage-check.sh --probe-codex   (ChatGPT Plus — SMALL pool)"
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
  recharge="$(jq -r '.auto_recharge // .has_failed_auto_recharge // empty' <<<"$bst" 2>/dev/null)"
  ar_flag="$(jq -r 'if .auto_recharge_enabled == true then " | WARNING: AUTO-RECHARGE IS ON" else "" end' <<<"$bst" 2>/dev/null)"
  echo "devin:   cycle consumption ${acus} ACU | on-demand pot \$${overage}${ar_flag}   (quota %: browser-only, see settings/usage; free models never draw quota)"
else
  echo "devin:   cycle consumption ${acus} ACU | billing status unavailable (no CLI credentials)   (quota %: browser-only; free models never draw quota)"
fi
echo ""
echo "routing guidance by claude weekly %:"
echo "  <50%   route normally (claude default)"
echo "  50-70% shift standard-tier bulk toward openai + devin-free; claude keeps strong/frontier + MCP-bound stories"
echo "  70-85% claude ONLY where claude-unique (qa/MCP stories, safety-critical); everything else openai/devin-free"
echo "  >85%   flag pool pressure to Josh before dispatching anything non-urgent"
