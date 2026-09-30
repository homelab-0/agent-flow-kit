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
# `legacy` is the one-line dump the Orca title and the other harnesses still
# consume. `claude` emits the tagged multi-line layout the Claude compositor
# places (A alert, L AFK line, U usage line, V verbose line).
FORM=legacy; WANT_USAGE=""; PRIOR_STATE=none
VERBOSE=""; [[ "${AFK_STATUS_VERBOSE:-}" == 1 ]] && VERBOSE=1

while (( $# )); do
  case "$1" in
    --input)   (( $# >= 2 )) || exit 2; INPUT="$2"; shift ;;
    --cache)   (( $# >= 2 )) || exit 2; CACHE="$2"; shift ;;
    --harness) (( $# >= 2 )) || exit 2; HARNESS="$2"; shift ;;
    --now)     (( $# >= 2 )) || exit 2; NOW="$2"; shift ;;
    --form)    (( $# >= 2 )) || exit 2; FORM="$2"; shift ;;
    --prior)   (( $# >= 2 )) || exit 2; PRIOR_STATE="$2"; shift ;;
    --usage)   WANT_USAGE=1 ;;
    --verbose) VERBOSE=1 ;;
    *) exit 2 ;;
  esac
  shift
done

# Rendering in a bounded time: GNU timeout when present, otherwise a
# background job plus watchdog (macOS ships neither timeout nor gtimeout).
BOUND="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
bounded() { # seconds command...
  local secs="$1" pid wd rc; shift
  if [[ -n "$BOUND" ]]; then "$BOUND" "$secs" "$@"; return; fi
  "$@" & pid=$!
  ( sleep "$secs"; kill -TERM "$pid" ) >/dev/null 2>&1 </dev/null & wd=$!
  wait "$pid"; rc=$?
  kill "$wd" >/dev/null 2>&1; wait "$wd" >/dev/null 2>&1
  return "$rc"
}
BUDGET_SECONDS=0.250
bounded_jq() { bounded "$BUDGET_SECONDS" jq "$@"; }
NOCOLOR=""; [[ -n "${NO_COLOR+x}" ]] && NOCOLOR=1
ROLE=none
# PM role only where the existing ownership binding proves it (same terminal,
# session, worktree and harness as worker-context.sh pm_binding).
resolve_role() {
  local pm_dir="${AFK_PM_DIR:-$(afk_default_pm_dir 2>/dev/null || true)}" here
  here="$(pwd -P 2>/dev/null || true)"
  [[ -n "$pm_dir" && -n "${ORCA_TERMINAL_HANDLE:-}" && -n "${AFK_RUNTIME_SESSION_ID:-}" && -n "$here" \
    && -r "$pm_dir/ownership.json" ]] || return 0
  # jq variables in the single-quoted program are not shell expansions.
  # shellcheck disable=SC2016
  bounded_jq -e --arg h "$HARNESS" --arg s "$AFK_RUNTIME_SESSION_ID" --arg t "$ORCA_TERMINAL_HANDLE" --arg p "$here" '
    (.schema|IN("afk-pm-ownership/2","afk-pm-ownership/3")) and .owned==true and .role=="PM" and .harness==$h and .session==$s
    and .terminal==$t and .worktree.path==$p and (.worktree.id|type)=="string" and (.worktree.id|length)>0
    ' "$pm_dir/ownership.json" >/dev/null 2>&1 && ROLE=pm
  return 0
}
# The usage line depends only on runtime-<harness>.json, never on the lifecycle
# cache, so it is a shared jq fragment (names are jq variables, not shell).
# shellcheck disable=SC2016
USAGE_JQ='(def pct($p; $body): (if $p >= 90 then sgr("31") elif $p >= 70 then sgr("33") else "" end) + $body + (if $p >= 70 then rst else "" end);
       def bar($p): (($p * 8 / 100) | round) as $n | [range(0; 8) | if . < $n then "█" else "░" end] | join("");
       def lim($k; $n): $runtime.rate_limits[$k].used_percentage as $p
         | if ($p | type) == "number" then pct($p; "\($n) [\(bar($p))] \($p | floor)%") else empty end;
       ($runtime.context.used_percentage) as $cp | ($runtime.context.limit_tokens) as $cl |
       ([ lim("five_hour"; "5h"), lim("seven_day"; "7d"),
          (if ($cp | type) == "number" then pct($cp; "ctx \($cp | floor)%" + (if ($cl | type) == "number" then " of " + (if $cl >= 1000000 then (($cl / 100000 | floor) / 10 | tostring) + "M" else (($cl / 1000 | floor | tostring) + "k") end) else "" end)) else empty end),
          (if (($runtime.model.value // "") | type) == "string" and ($runtime.model.value // "") != "" then ($runtime.model.value | clean) else empty end)
        ] | join(" " + sgr("2") + "|" + rst + " ")) as $u
       | if $u != "" then "U\t" + $u + rst else empty end)'
runtime_json='{}'
load_runtime() { # fresh runtime observation into runtime_json
  local runtime="$RUNTIME_CACHE_DIR/runtime-${HARNESS}.json"
  # shellcheck disable=SC2016
  if [[ -f "$runtime" && -r "$runtime" ]] && bounded_jq -e --argjson now "$NOW" --argjson stale "${STALE_S:-180}" '
      .schema=="afk-runtime-observation/1" and
      ((.observed_at|fromdateiso8601) as $seen | $now >= $seen and ($now-$seen) <= $stale)
    ' "$runtime" >/dev/null 2>&1; then
    runtime_json="$(<"$runtime")"
  fi
}
unavailable() {
  if [[ "$FORM" != claude ]]; then printf 'AFK UNAVAILABLE[%s]\n' "$1"; return; fi
  resolve_role
  # Plain chat: no AFK line. PM: the role is known even without data.
  if [[ "$ROLE" == pm ]]; then
    if [[ -n "$NOCOLOR" ]]; then printf 'L\tAFK PM · status unavailable\n'
    else printf 'L\t\033[1mAFK PM\033[0m \033[33mstatus unavailable\033[0m\n'; fi
  fi
  [[ -n "$WANT_USAGE" ]] || return 0
  load_runtime
  # shellcheck disable=SC2016
  bounded_jq -nr --argjson runtime "$runtime_json" --argjson color "$([[ -n "$NOCOLOR" ]] && echo false || echo true)" '
    def sgr($c): if $color then "\u001b[" + $c + "m" else "" end;
    def rst: sgr("0");
    def clean: tostring | gsub("[[:cntrl:]]"; " ");
    '"$USAGE_JQ" 2>/dev/null || true
}
[[ "$NOW" =~ ^[0-9]+$ ]] || { unavailable STATUS_CONTRACT_INVALID; exit 0; }
[[ -f "$POLICY" && -r "$POLICY" ]] || { unavailable STATUS_CONTRACT_INVALID; exit 0; }

read -r _BUDGET_MS _REFRESH_S STALE_S < <(jq -er '
  select(keys == ["reason_codes","refresh_interval_seconds","render_budget_ms","schema","staleness_threshold_seconds"])
  | select(.schema == "afk-status-policy/1")
  | select(.render_budget_ms > 0 and .refresh_interval_seconds >= 0 and .staleness_threshold_seconds >= .refresh_interval_seconds)
  | [.render_budget_ms,.refresh_interval_seconds,.staleness_threshold_seconds] | @tsv
' "$POLICY" 2>/dev/null) || { unavailable STATUS_CONTRACT_INVALID; exit 0; }

BUDGET_SECONDS="$(awk -v ms="$_BUDGET_MS" 'BEGIN { printf "%.3f", ms / 1000 }')"

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

# jq programs below are single-quoted deliberately; their `$now`, `$stale`,
# `$harness`, and `$runtime` names are jq variables, not shell expansion.
load_runtime
if [[ "$FORM" == claude ]]; then
  resolve_role
  reasons="$(cat -- "$SELF_DIR/status-reasons.json" 2>/dev/null || true)"; [[ -n "$reasons" ]] || reasons='{}'
  # shellcheck disable=SC2016
  tagged="$(bounded_jq -r --argjson runtime "$runtime_json" --argjson reasons "$reasons" \
    --arg role "$ROLE" --argjson age "$AGE" --argjson stale "$([[ "$SOURCE" == STALE ]] && echo true || echo false)" \
    --argjson color "$([[ -n "$NOCOLOR" ]] && echo false || echo true)" --argjson usage "$([[ -n "$WANT_USAGE" ]] && echo true || echo false)" '
    def sgr($c): if $color then "\u001b[" + $c + "m" else "" end;
    def rst: sgr("0");
    def clean: tostring | gsub("[[:cntrl:]]"; " ");
    def trunc($n): if length > $n then .[0:$n-1] + "…" else . end;
    def phrase: clean | ($reasons[.] // .);
    def mins: if $age > 59940 then ">16h" else (($age / 60) | floor | tostring) + "m" end;
    def states($n): [.dispatch_monitor.dispatches[]? | select((.state // "") as $s | $n | index($s))] | length;
    (.extra.pm_budget // {}) as $pb | ($pb.state // "") as $pbs |
    ([.findings[]? | select(.severity == "owner_action") | .reason] - ["PM_CONTINUATION_REQUIRED"]) as $oa |
    ($pb.needs_human == true and $pbs != "CONTINUATION_REQUIRED") as $pbn |
    ((.dispatch_monitor.state // "") == "NEEDS_HUMAN") as $dmn |
    ([ (if ((.orchestration.session.needs_human // false) or $pbn or $dmn or ($oa | length > 0)) then
          {r: 3, k: "NEEDS YOU", red: true,
           d: (($oa[0] // (if $dmn then .dispatch_monitor.required_action else null end)
                // (if $pbn then $pb.reason else null end) // "NEEDS_HUMAN") | phrase)} else empty end),
       (if $pbs == "CONTINUATION_REQUIRED" then {r: 2, k: "HANDOFF NOW", red: true, d: ("PM_CONTINUATION_REQUIRED" | phrase)} else empty end),
       (if $pbs == "CHECKPOINT_DUE" then {r: 1, k: "CHECKPOINT", red: false, d: ("PM_CHECKPOINT_DUE" | phrase)} else empty end)
     ] | sort_by(-.r)) as $alerts |
    (.extra.auto_update // {}) as $au | (.overall.state // "") as $ov |
    ([ (if $stale then mins else empty end), (if $role == "pm" then "PM" else empty end) ] | join(" · ")) as $ctx |
    (if ($alerts | length) > 0 then
       "A\t" + sgr(if $alerts[0].red then "1;7;31" else "1;7;33" end) + " ! AFK " + $alerts[0].k + " " + rst
       + " " + sgr("1") + ($alerts[0].d | trunc(60)) + rst
       + (if $ctx != "" then " " + sgr("2") + "· " + $ctx + rst else "" end)
       + (if ($alerts | length) > 1 then " " + sgr("2") + "+" + (($alerts | length) - 1 | tostring) + " more" + rst else "" end)
     else empty end),
    ( def blocked: states(["MONITOR_DEGRADED","BLOCKED"]);
      def running: states(["WATCHING","WORKING","RUNNING"]);
      [ (if blocked > 0 then {p: "\(blocked) blocked", c: "31", d: 8} else empty end),
        (if $role == "pm" and running > 0 then {p: "\(running) worker\(if running > 1 then "s" else "" end)", c: "", d: 6} else empty end),
        (if ((.extra.pm_handoff.state // "") | IN("SUCCESSOR_LAUNCHED","ACKED")) then {p: "handing off to successor", c: "36", d: 9} else empty end),
        (if $au.update_available == true then
           {p: (if $au.enrolled == true and $au.platform == "linux" then "update ready: applies at next session start" else "update available: run agent-flow-kit update" end), c: "36", d: 4}
         elif (($au.health // "ok") != "ok") then {p: "updater unhealthy: run agent-flow-kit status", c: "33", d: 4}
         elif ($ov | IN("NOT_READY","NEEDS_OWNER")) then {p: "needs repair: run agent-flow-kit status", c: "33", d: 4}
         else empty end),
        (if ((.extra.catalog.findings // []) | length) > 0 or ((.extra.catalog.last_sync.outcome // "") | test("FAIL")) then {p: "catalog stale", c: "33", d: 2} else empty end)
      ] as $raw |
      (if $role == "pm" then "AFK PM" else "AFK" end) as $label |
      (if $role == "pm" and $stale then " (" + mins + " old)" else "" end) as $old |
      # Narrow-width order: lowest drop rank goes first; the label never does.
      def fit: if (($label | length) + ($old | length) + ([.[] | 3 + (.p | length)] | add // 0)) > 100 and length > 0
        then (map(.d) | min) as $m | (map(.d == $m) | index(true)) as $i | del(.[$i]) | fit else . end;
      ($raw | fit) as $fields |
      if $role == "pm" or ($fields | length) > 0 then
        "L\t" + sgr("1") + $label + rst + (if $old != "" then sgr("33") + $old + rst else "" end)
        + ([ $fields[] | " " + sgr("2") + "·" + rst + " " + (if .c != "" then sgr(.c) + .p + rst else .p end) ] | join(""))
        + rst
      else empty end ),
    (if $usage then '"$USAGE_JQ"' else empty end),
    "X\t\($au.last_result.state // "-")/\($au.last_result.reason // "-")"
  ' "$DOC" 2>/dev/null)" || { unavailable STATUS_TIMEOUT; exit 0; }
  printf '%s\n' "$tagged" | grep -v '^X'
  if [[ -n "$VERBOSE" ]]; then
    legacy="$("$0" --harness "$HARNESS" --cache "$DOC" --now "$NOW" 2>/dev/null | tr -d '\000-\037')"
    dbg="$legacy src=$SOURCE age=${AGE}s cache=$(basename "$RUNTIME_CACHE_DIR" | sed 's/^[a-z]*-//' | cut -c1-8) role_source=$([[ "$ROLE" == pm ]] && echo pm_binding || echo none) prior=$PRIOR_STATE au=$(printf '%s\n' "$tagged" | sed -n 's/^X\t//p')"
    if [[ -n "$NOCOLOR" ]]; then printf 'V\t%s\n' "$dbg"; else printf 'V\t\033[2m%s\033[0m\n' "$dbg"; fi
  fi
  exit 0
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
