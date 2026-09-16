#!/usr/bin/env bash
# Render one compact, read-only AFK status segment from the lifecycle contract.
# The cache contains only normalized status JSON. Rendering is strictly
# cache-only: harness hooks/plugins own publication and background refresh.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Dynamic sibling resolved from this script's canonical directory.
# shellcheck disable=SC1091
. "$SELF_DIR/runtime-scope.sh"
POLICY="${AFK_STATUS_POLICY:-$SELF_DIR/status-policy.json}"
DEFAULT_CACHE_DIR="$(afk_default_status_cache_dir 2>/dev/null || true)"
CACHE="${AFK_STATUS_CACHE:-${DEFAULT_CACHE_DIR:+$DEFAULT_CACHE_DIR/status.json}}"
RUNTIME_CACHE_DIR="${AFK_STATUS_CACHE_DIR:-$DEFAULT_CACHE_DIR}"
INPUT=""
HARNESS="${AFK_STATUS_HARNESS:-NOT_EVALUATED}"
NOW="${AFK_STATUS_NOW:-$(date -u +%s)}"

while (( $# )); do
  case "$1" in
    --input)   (( $# >= 2 )) || exit 2; INPUT="$2"; shift ;;
    --cache)   (( $# >= 2 )) || exit 2; CACHE="$2"; shift ;;
    --harness) (( $# >= 2 )) || exit 2; HARNESS="$2"; shift ;;
    --now)     (( $# >= 2 )) || exit 2; NOW="$2"; shift ;;
    *) exit 2 ;;
  esac
  shift
done

unavailable() { printf 'AFK UNAVAILABLE[%s]\n' "$1"; }
[[ "$NOW" =~ ^[0-9]+$ ]] || { unavailable STATUS_CONTRACT_INVALID; exit 0; }
[[ -f "$POLICY" && -r "$POLICY" ]] || { unavailable STATUS_CONTRACT_INVALID; exit 0; }

read -r _BUDGET_MS _REFRESH_S STALE_S < <(jq -er '
  select(keys == ["reason_codes","refresh_interval_seconds","render_budget_ms","schema","staleness_threshold_seconds"])
  | select(.schema == "afk-status-policy/1")
  | select(.render_budget_ms > 0 and .refresh_interval_seconds >= 0 and .staleness_threshold_seconds >= .refresh_interval_seconds)
  | [.render_budget_ms,.refresh_interval_seconds,.staleness_threshold_seconds] | @tsv
' "$POLICY" 2>/dev/null) || { unavailable STATUS_CONTRACT_INVALID; exit 0; }

BOUND="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
[[ -n "$BOUND" ]] || { unavailable STATUS_TIMEOUT; exit 0; }
BUDGET_SECONDS="$(awk -v ms="$_BUDGET_MS" 'BEGIN { printf "%.3f", ms / 1000 }')"
bounded_jq() { "$BOUND" "$BUDGET_SECONDS" jq "$@"; }

mtime() { stat -Lc %Y "$1" 2>/dev/null || stat -Lf %m "$1" 2>/dev/null || printf 0; }
valid_status() {
  [[ -f "$1" && -r "$1" ]] && bounded_jq -e 'type == "object" and .kind == "lifecycle_result"
    and (.schema_version | type == "string")
    and (.orchestration | type == "object")
    and (.dispatch_monitor | type == "object")' "$1" >/dev/null 2>&1
}

DOC=""; SOURCE="UNAVAILABLE"; AGE=0
if [[ -n "$INPUT" ]]; then
  if valid_status "$INPUT"; then DOC="$INPUT"; SOURCE="FRESH"; else unavailable STATUS_CONTRACT_INVALID; exit 0; fi
else
  [[ -n "$CACHE" ]] || { unavailable STATUS_UNAVAILABLE; exit 0; }
  if [[ -f "$CACHE" ]] && valid_status "$CACHE"; then
    AGE=$(( NOW - $(mtime "$CACHE") )); (( AGE < 0 )) && AGE=0
  fi
  if [[ -f "$CACHE" ]] && valid_status "$CACHE"; then
    DOC="$CACHE"; AGE=$(( NOW - $(mtime "$CACHE") )); (( AGE < 0 )) && AGE=0
    if (( AGE > STALE_S )); then SOURCE="STALE"; else SOURCE="FRESH"; fi
  else
    unavailable STATUS_UNAVAILABLE
    exit 0
  fi
fi

runtime="$RUNTIME_CACHE_DIR/runtime-${HARNESS}.json"
# jq programs below are single-quoted deliberately; their `$now`, `$stale`,
# `$harness`, and `$runtime` names are jq variables, not shell expansion.
runtime_json='{}'
# shellcheck disable=SC2016
if [[ -f "$runtime" && -r "$runtime" ]] && bounded_jq -e --argjson now "$NOW" --argjson stale "$STALE_S" '
    .schema=="afk-runtime-observation/1" and
    ((.observed_at|fromdateiso8601) as $seen | $now >= $seen and ($now-$seen) <= $stale)
  ' "$runtime" >/dev/null 2>&1; then
  runtime_json="$(<"$runtime")"
fi
# shellcheck disable=SC2016
segment="$(bounded_jq -r --arg harness "$HARNESS" --argjson runtime "$runtime_json" '
  def v($x): if ($x == null or $x == "" or $x == "-") then "NOT_EVALUATED" else ($x|tostring) end;
  def count_states($names): [.dispatch_monitor.dispatches[]? | select((.state // "") as $s | $names | index($s))] | length;
  (.orchestration.session.mode // null) as $mode |
  (.orchestration.session.persona // null) as $persona |
  (.orchestration.session.task // null) as $task |
  (.orchestration.session.phase // null) as $phase |
  ($runtime.model.value // null) as $observed_model |
  ($runtime.context.used_tokens // null) as $observed_used |
  ($runtime.context.limit_tokens // null) as $observed_limit |
  ($observed_model // .runtime.model // .extra.runtime.model // null) as $model |
  ($observed_used // .runtime.context.used_tokens // .extra.pm_budget.usage_tokens // null) as $used |
  ($observed_limit // .runtime.context.limit_tokens // .extra.pm_budget.window_tokens // null) as $limit |
  ((.orchestration.session.needs_human // false) or (.extra.pm_budget.needs_human // false)
    or (.dispatch_monitor.state == "NEEDS_HUMAN")) as $needs |
  ([.findings[]? | select(.severity == "owner_action") | .reason][0]
    // (if $needs then "NEEDS_HUMAN" else "NONE" end)) as $owner |
  "AFK " + v($mode) + "/" + v($persona)
  + " task=" + v($task)
  + " cli=" + v($harness) + "/" + v($model)
  + " ctx=" + v($used) + "/" + v($limit)
  + " phase=" + v($phase)
  + " workers=" + (count_states(["WATCHING","WORKING","RUNNING"])|tostring)
    + "/" + (count_states(["MONITOR_DEGRADED","BLOCKED"])|tostring)
    + "/" + (count_states(["COMPLETED","SETTLED","DONE"])|tostring)
  + " bridge=" + v(.orchestration.state)
  + " owner=" + v($owner)
  + " update=" + v(.source_eligibility.revision_relation)
  + " sub=" + v(.runtime.subscription.state // .extra.runtime.subscription.state // null)
  + " reset=" + v(.runtime.subscription.reset_at // .extra.runtime.subscription.reset_at // null)
  + (if $needs then " !NEEDS_HUMAN!" else "" end)
' "$DOC" 2>/dev/null)" || { unavailable STATUS_TIMEOUT; exit 0; }

if [[ "$SOURCE" == "STALE" ]]; then
  printf 'STALE[%ss] %s\n' "$AGE" "$segment"
else
  printf '%s\n' "$segment"
fi
