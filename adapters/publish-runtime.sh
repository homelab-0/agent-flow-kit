#!/usr/bin/env bash
# Publish one harness-owned runtime observation. This adapter accepts only
# fields delivered by the harness event; missing fields remain NOT_EVALUATED.
set -uo pipefail

HARNESS="" INPUT="-"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Dynamic sibling resolved from this script's canonical directory.
# shellcheck disable=SC1091
. "$HERE/runtime-scope.sh"
DEFAULT_CACHE_DIR="$(afk_default_status_cache_dir 2>/dev/null || true)"
CACHE_DIR="${AFK_STATUS_CACHE_DIR:-$DEFAULT_CACHE_DIR}"
while (( $# )); do
  case "$1" in
    --harness) (( $# >= 2 )) || exit 2; HARNESS="$2"; shift 2 ;;
    --input) (( $# >= 2 )) || exit 2; INPUT="$2"; shift 2 ;;
    --cache-dir) (( $# >= 2 )) || exit 2; CACHE_DIR="$2"; shift 2 ;;
    *) exit 2 ;;
  esac
done
case "$HARNESS" in claude|codex|opencode) : ;; *) exit 2 ;; esac
[[ -n "$CACHE_DIR" ]] || exit 1
mkdir -p -- "$CACHE_DIR" || exit 1
chmod 700 "$CACHE_DIR" 2>/dev/null || true

raw="$(mktemp "${CACHE_DIR}/runtime-input.XXXXXX")" || exit 1
tmp="${CACHE_DIR}/runtime-${HARNESS}.json.tmp.$$"
trap 'rm -f -- "$raw" "$tmp"' EXIT
if [[ "$INPUT" == "-" ]]; then cat >"$raw"; else cp -- "$INPUT" "$raw"; fi
jq -e 'type == "object"' "$raw" >/dev/null 2>&1 || exit 1

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq --arg harness "$HARNESS" --arg now "$now" '
  def field($v): if ($v == null or $v == "") then {state:"NOT_EVALUATED"}
    else {state:"AVAILABLE",value:$v} end;
  def pct($v): if (($v|type)=="number") then {state:"AVAILABLE",used_percentage:$v}
    else {state:"NOT_EVALUATED"} end;
  if $harness == "claude" then
    {schema:"afk-runtime-observation/1",harness:$harness,observed_at:$now,
     model:field(.model.display_name // .model.id),
     session:field(.session_id),
     context:((pct(.context_window.used_percentage))
       + {used_tokens:(if (.context_window.current_usage|type)=="object"
            then ((.context_window.current_usage.input_tokens // 0)
              + (.context_window.current_usage.cache_creation_input_tokens // 0)
              + (.context_window.current_usage.cache_read_input_tokens // 0)) else null end),
          output_tokens:(.context_window.current_usage.output_tokens // null),
          limit_tokens:(.context_window.context_window_size // null)}),
     rate_limits:{five_hour:pct(.rate_limits.five_hour.used_percentage),
                  seven_day:pct(.rate_limits.seven_day.used_percentage)}}
  elif $harness == "codex" then
    {schema:"afk-runtime-observation/1",harness:$harness,observed_at:$now,
     model:field(.model),session:field(.session_id),
     context:{state:"NOT_EVALUATED"},
     rate_limits:{five_hour:{state:"NOT_EVALUATED"},seven_day:{state:"NOT_EVALUATED"}}}
  else
    (.event // .) as $e |
    ($e.properties.info // $e.properties.part // $e.properties // {}) as $i |
    {schema:"afk-runtime-observation/1",harness:$harness,observed_at:$now,
     model:field($i.modelID // $i.model.id // $i.model),
     provider:field($i.providerID // $i.provider.id // $i.provider),
     session:field($i.sessionID // $i.session_id // $e.properties.sessionID),
     context:{state:"NOT_EVALUATED",used_tokens:null,limit_tokens:null},
     turn_tokens:field(if ($i.tokens|type)=="object" then (($i.tokens.input // 0)
       + ($i.tokens.output // 0) + ($i.tokens.reasoning // 0)) else null end),
     rate_limits:{five_hour:{state:"NOT_EVALUATED"},seven_day:{state:"NOT_EVALUATED"}}}
  end
' "$raw" >"$tmp" || exit 1
chmod 600 "$tmp" 2>/dev/null || true
mv -f -- "$tmp" "$CACHE_DIR/runtime-${HARNESS}.json"
