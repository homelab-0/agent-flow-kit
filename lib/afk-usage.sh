#!/usr/bin/env bash
# afk-usage.sh — `agent-flow-kit usage-report`: what the pools spent, by
# harness, model, class and story, over a rolling window.
#
# OBSERVABILITY ONLY, same posture as files/model-router/scripts/usage-check.sh:
# no routing guidance, not a routing input. Read-only (AC-4): every source
# below is read, never written. Sources are all local and all optional
# (AC-1): a missing or unreadable source reports "unknown" and the verb still
# succeeds; only a missing price table refuses the whole run (AC-3), because a
# cost computed from no declared prices is a guess, not an estimate.
#
# This file is SOURCED, never executed, like every other lib/afk-*.sh.

if [[ -n "${AFK_USAGE_SOURCED:-}" ]]; then
  return 0
fi
AFK_USAGE_SOURCED=1

# Standalone-runnable: derive AFK_INSTALL_ROOT from this file's own location
# when sourced outside bin/agent-flow-kit, as the lifecycle test does.
if [[ -z "${AFK_INSTALL_ROOT:-}" ]]; then
  _afk_usage_lib_dir="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  AFK_INSTALL_ROOT="$(cd -P -- "$_afk_usage_lib_dir/.." && pwd -P)"
  unset _afk_usage_lib_dir
fi

# Every source path is overridable so the lifecycle test can point this at
# small synthetic fixtures instead of the real host state.
AFK_USAGE_PRICES_FILE="${AFK_USAGE_PRICES_FILE:-$AFK_INSTALL_ROOT/files/model-router/usage-prices.yaml}"
AFK_USAGE_CLAUDE_PROJECTS_DIR="${AFK_USAGE_CLAUDE_PROJECTS_DIR:-${HOME:-}/.claude/projects}"
AFK_USAGE_CODEX_HOMES="${AFK_USAGE_CODEX_HOMES:-}"   # colon-separated; auto-detected when empty
AFK_USAGE_OPENCODE_DB="${AFK_USAGE_OPENCODE_DB:-${HOME:-}/.local/share/opencode/opencode.db}"
AFK_USAGE_NOW_EPOCH="${AFK_USAGE_NOW_EPOCH:-$(date +%s)}"
AFK_USAGE_ORCA_WORKSPACES_DIR="${AFK_USAGE_ORCA_WORKSPACES_DIR:-${HOME:-}/orca/workspaces}"

# A Claude project dir under orca-workspaces encodes the full absolute path
# "/home/<user>/orca/workspaces/<repo>/<workspace>" with "/" turned into "-",
# so there is no lossless way back to a bare workspace name from that string
# alone (both <repo> and <workspace> can contain dashes). What IS reliable is
# the real repo directory names under AFK_USAGE_ORCA_WORKSPACES_DIR: the
# longest one whose "orca-workspaces-<repo>-" marker appears in the string
# names the split point. Falls back to the naive suffix-after-marker split
# when no repo directory is known (e.g. a host with no orca/workspaces yet).
afk_usage_workspace_name() { # <raw claude project dir string> -> bare workspace name
  local proj="$1" d repo marker best="" best_len=0
  if [[ -d "$AFK_USAGE_ORCA_WORKSPACES_DIR" ]]; then
    for d in "$AFK_USAGE_ORCA_WORKSPACES_DIR"/*/; do
      [[ -d "$d" ]] || continue
      repo="$(basename "$d")"
      marker="orca-workspaces-$repo-"
      if [[ "$proj" == *"$marker"* && ${#marker} -gt $best_len ]]; then
        best="$marker"; best_len=${#marker}
      fi
    done
  fi
  if [[ -n "$best" ]]; then
    printf '%s' "${proj##*"$best"}"
  else
    printf '%s' "${proj##*orca-workspaces-}"
  fi
}

# --- prices: declared, never a constant in code (AC-3) ----------------------
# The YAML table is a top-level `model:` key with 2-space-indented
# `key: number` lines — the whole grammar, so a small awk state machine reads
# it without a YAML library: one JSON object per model, turned into a
# model->prices map by jq.
afk_usage_prices_json() { # -> JSON object {model: {input,output,cache_read,cache_write}} on stdout
  [[ -r "$AFK_USAGE_PRICES_FILE" ]] || return 1
  awk '
    function flush() {
      if (model != "") {
        printf "{\"model\":\"%s\"", model
        for (i = 1; i <= n; i++) printf ",\"%s\":%s", keys[i], vals[i]
        print "}"
      }
      model = ""; n = 0
    }
    /^[A-Za-z0-9_.-]+:[[:space:]]*$/ {
      flush(); model = $0; sub(/:[[:space:]]*$/, "", model); next
    }
    /^[[:space:]]+[A-Za-z0-9_]+:[[:space:]]*[0-9.]+[[:space:]]*$/ {
      line = $0; sub(/^[[:space:]]+/, "", line)
      split(line, kv, ":"); n++; keys[n] = kv[1]
      val = kv[2]; gsub(/[[:space:]]/, "", val); vals[n] = val
      next
    }
    END { flush() }
  ' "$AFK_USAGE_PRICES_FILE" \
    | jq -s -c 'map({(.model): {
        input: (.input_per_mtok // null), output: (.output_per_mtok // null),
        cache_read: (.cache_read_per_mtok // null), cache_write: (.cache_write_per_mtok // null)}})
        | add // {}'
}

# --- claude: ~/.claude/projects/**/*.jsonl -----------------------------------
#
# Session class (per the story): `subagent` when the file lives under a
# subagents/ dir or the record carries agentId/isSidechain; `worker` when the
# project dir name contains "orca-workspaces"; `interactive` otherwise.
afk_usage_claude_calls() { # <cutoff ISO8601> -> JSONL of call records on stdout
  local dir="$AFK_USAGE_CLAUDE_PROJECTS_DIR" cutoff="$1" f rel proj is_sub workspace
  [[ -d "$dir" ]] || return 0
  while IFS= read -r f; do
    rel="${f#"$dir"/}"
    proj="${rel%%/*}"
    is_sub=false
    [[ "$rel" == */subagents/* ]] && is_sub=true
    workspace="$proj"
    [[ "$proj" == *orca-workspaces* ]] && workspace="$(afk_usage_workspace_name "$proj")"
    jq -c --arg proj "$proj" --arg workspace "$workspace" --arg cutoff "$cutoff" --argjson is_sub "$is_sub" '
      select(.message.usage != null) |
      select((.timestamp // "0000") >= $cutoff) |
      {
        harness: "claude",
        model: (.message.model // "unknown"),
        msg_id: (.message.id // ""),
        req_id: (.requestId // ""),
        session_id: (.sessionId // .session_id // $proj),
        timestamp: .timestamp,
        input: (.message.usage.input_tokens // 0),
        cache_read: (.message.usage.cache_read_input_tokens // 0),
        cache_write: (.message.usage.cache_creation_input_tokens // 0),
        output: (.message.usage.output_tokens // 0),
        class: (if ($is_sub or .isSidechain == true or .agentId != null) then "subagent"
                elif ($proj | test("orca-workspaces")) then "worker"
                else "interactive" end),
        workspace: $workspace
      }' "$f" 2>/dev/null
  done < <(find "$dir" -name '*.jsonl' -type f 2>/dev/null)
}

# Waste signals scoped to Claude transcripts: oversized tool results and
# Write/Edit call volume. A second, lighter pass over the same files.
afk_usage_claude_waste() { # <cutoff ISO8601> -> JSONL {kind,bytes} on stdout
  local dir="$AFK_USAGE_CLAUDE_PROJECTS_DIR" cutoff="$1" f
  [[ -d "$dir" ]] || return 0
  while IFS= read -r f; do
    jq -c --arg cutoff "$cutoff" '
      select((.timestamp // "0000") >= $cutoff) |
      (.message.content // [])[]? |
      if .type == "tool_use" and (.name == "Write" or .name == "Edit") then
        {kind: .name, bytes: ((.input | tostring) | length)}
      elif .type == "tool_result" then
        {kind: "tool_result", bytes: ((.content | tostring) | length)}
      else empty end' "$f" 2>/dev/null
  done < <(find "$dir" -name '*.jsonl' -type f 2>/dev/null)
}

# --- codex: rollout-*.jsonl under $CODEX_HOME/sessions and every Orca account -
afk_usage_codex_homes() { # -> one candidate home dir per line
  if [[ -n "$AFK_USAGE_CODEX_HOMES" ]]; then
    tr ':' '\n' <<<"$AFK_USAGE_CODEX_HOMES"
    return 0
  fi
  local h
  for h in "${CODEX_HOME:-}" "${HOME:-}/.codex" "${HOME:-}"/.config/orca/codex-accounts/*/home; do
    [[ -n "$h" && -d "$h/sessions" ]] && printf '%s\n' "$h"
  done | sort -u
}

afk_usage_codex_calls() { # <cutoff ISO8601> -> JSONL of call records on stdout
  local cutoff="$1" home f
  while IFS= read -r home; do
    [[ -d "$home/sessions" ]] || continue
    while IFS= read -r f; do
      afk_usage_codex_summarize "$f" "$cutoff"
    done < <(find "$home/sessions" -name 'rollout-*.jsonl' -type f 2>/dev/null)
  done < <(afk_usage_codex_homes)
}

afk_usage_codex_summarize() { # <session file> <cutoff ISO8601>
  local f="$1" cutoff="$2" last_ts model usage tc_count tool_count
  last_ts="$(jq -r 'select(.type == "event_msg" and .payload.type == "token_count") | .timestamp' "$f" 2>/dev/null | tail -1)"
  [[ -n "$last_ts" ]] || return 0
  [[ "$last_ts" < "$cutoff" ]] && return 0
  model="$(jq -r 'select(.type == "turn_context") | .payload.model // empty' "$f" 2>/dev/null | head -1)"
  usage="$(jq -c 'select(.type == "event_msg" and .payload.type == "token_count") | .payload.info.total_token_usage' "$f" 2>/dev/null | tail -1)"
  tc_count="$(jq -c 'select(.type == "event_msg" and .payload.type == "token_count")' "$f" 2>/dev/null | wc -l | tr -d ' ')"
  tool_count="$(jq -c 'select(.type == "response_item" and (.payload.type == "custom_tool_call" or .payload.type == "function_call"))' "$f" 2>/dev/null | wc -l | tr -d ' ')"
  jq -n --arg model "${model:-unknown}" --argjson usage "${usage:-null}" \
    --arg session "$f" --argjson tc "${tc_count:-0}" --argjson tools "${tool_count:-0}" --arg ts "$last_ts" '
    {
      harness: "codex", model: $model, session_id: $session, timestamp: $ts,
      input: ($usage.input_tokens // 0), cache_read: ($usage.cached_input_tokens // 0),
      cache_write: ($usage.cache_write_input_tokens // 0), output: ($usage.output_tokens // 0),
      class: "codex", workspace: $session,
      token_count_events: $tc, tool_calls: $tools
    }'
}

# --- opencode: opencode.db via sqlite3, entirely optional (AC-1) ------------
afk_usage_opencode_calls() { # <cutoff epoch ms> -> JSONL of call records, or an unknown marker
  local cutoff_ms="$1" rows
  if ! afk_have sqlite3; then
    echo '{"unknown":"sqlite3 not installed"}'
    return 0
  fi
  if [[ ! -f "$AFK_USAGE_OPENCODE_DB" ]]; then
    echo '{"unknown":"no local db at '"$AFK_USAGE_OPENCODE_DB"'"}'
    return 0
  fi
  rows="$(sqlite3 -readonly -separator '|' "$AFK_USAGE_OPENCODE_DB" "
    select json_extract(data,'\$.modelID'), session_id, time_created,
           coalesce(json_extract(data,'\$.tokens.input'),0),
           coalesce(json_extract(data,'\$.tokens.output'),0),
           coalesce(json_extract(data,'\$.tokens.cache.read'),0),
           coalesce(json_extract(data,'\$.tokens.cache.write'),0)
    from message
    where json_extract(data,'\$.role') = 'assistant' and time_created >= $cutoff_ms;
  " 2>/dev/null)"
  [[ -n "$rows" ]] || return 0
  awk -F'|' '{
    printf "{\"harness\":\"opencode\",\"model\":\"%s\",\"session_id\":\"%s\",\"timestamp\":%s,\"input\":%s,\"output\":%s,\"cache_read\":%s,\"cache_write\":%s,\"class\":\"opencode\",\"workspace\":\"%s\"}\n", \
      $1, $2, $3, $4, $5, $6, $7, $2
  }' <<<"$rows"
}

# --- entry point --------------------------------------------------------------
#
# worker_sessions_per_story (below, in the jq program) groups by workspace
# name with the suffix `-review`, `-fix`, `-postfix` or `-r<n>` stripped. The
# story name is best-effort: Claude project dirs encode the full absolute path
# with "/" turned into "-", so there is no lossless way back to a bare
# workspace name; the declared PM suffix vocabulary is what is reliable.

afk_usage_report() { # "$@" -> report on stdout; returns 1 on USAGE_PRICES_UNREADABLE
  local days=7 json_mode=false a prices_json cutoff_iso cutoff_ms
  while (( $# > 0 )); do
    a="$1"
    case "$a" in
      --days)
        if (( $# < 2 )) || ! [[ "$2" =~ ^[0-9]+$ ]]; then
          afk_warn "usage-report: --days requires a non-negative integer"
          return "${AFK_EXIT_USAGE:-1}"
        fi
        days="$2"; shift ;;
      --json) json_mode=true ;;
      *)
        afk_warn "usage-report: unknown argument: $(afk_safe_diagnostic "$a" 2>/dev/null || echo "$a")"
        return "${AFK_EXIT_USAGE:-1}" ;;
    esac
    shift
  done

  if ! prices_json="$(afk_usage_prices_json)"; then
    afk_warn "USAGE_PRICES_UNREADABLE: $AFK_USAGE_PRICES_FILE"
    return 1
  fi

  cutoff_iso="$(date -u -d "@$((AFK_USAGE_NOW_EPOCH - days * 86400))" '+%Y-%m-%dT%H:%M:%S.000Z' 2>/dev/null \
    || date -u -r "$((AFK_USAGE_NOW_EPOCH - days * 86400))" '+%Y-%m-%dT%H:%M:%S.000Z')"
  cutoff_ms=$(( (AFK_USAGE_NOW_EPOCH - days * 86400) * 1000 ))

  # Arrays are spooled to temp files, not carried as jq --argjson argv: a real
  # host's transcript history can exceed the OS argument-list limit.
  # --slurpfile has no such cap. Cleanup is explicit at both exits below
  # rather than a RETURN trap, which would fire on every nested call's return
  # too and trip over locals (like $tmp_dir) that do not exist in that scope.
  local tmp_dir all_calls_file waste_file prices_file report_json rc
  tmp_dir="$(mktemp -d)" || return 1
  all_calls_file="$tmp_dir/calls.json"
  waste_file="$tmp_dir/waste.json"
  prices_file="$tmp_dir/prices.json"
  printf '%s' "$prices_json" > "$prices_file"

  local opencode_unknown
  {
    afk_usage_claude_calls "$cutoff_iso" | jq -c -s 'unique_by([.msg_id, .req_id] | tostring) | .[]'
    afk_usage_codex_calls "$cutoff_iso"
    afk_usage_opencode_calls "$cutoff_ms" | jq -c 'select(.unknown == null)'
  } > "$all_calls_file"
  opencode_unknown="$(afk_usage_opencode_calls "$cutoff_ms" | jq -r 'select(.unknown != null) | .unknown' | head -1)"
  afk_usage_claude_waste "$cutoff_iso" > "$waste_file"

  report_json="$(afk_usage_render_json "$all_calls_file" "$waste_file" "$prices_file" "$days" "$opencode_unknown")"
  rc=$?
  rm -rf "$tmp_dir"
  if (( rc != 0 )); then
    return 1
  fi

  if [[ "$json_mode" == "true" ]]; then
    printf '%s\n' "$report_json"
  else
    afk_usage_render_human "$report_json"
  fi
}

# The whole computation lives in one jq program: given the flat call array,
# the waste-signal array and the declared price map, it produces every section
# of the report as a single JSON document, which both render paths read from.
# Calls and waste are read with --slurpfile (no argv-size limit); the price
# table is small and bounded by the model catalog, so it is read directly.
afk_usage_render_json() { # <calls JSONL file> <waste JSONL file> <prices json file> <days> <opencode_unknown>
  jq -n --slurpfile calls "$1" --slurpfile waste "$2" --argjson prices "$(cat "$3")" \
    --argjson days "$4" --arg opencode_unknown "${5:-}" '
    def iso2epoch:
      if type == "number" then .
      else (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) end;
    def price(m):
      $prices[m] // null;
    def call_cost(c):
      (price(c.model)) as $p |
      if $p == null then null
      else ((c.input // 0) * (($p.input // 0)) + (c.output // 0) * (($p.output // 0))
            + (c.cache_read // 0) * (($p.cache_read // 0)) + (c.cache_write // 0) * (($p.cache_write // 0))) / 1000000
      end;
    ($calls | map(. + {cost: call_cost(.), context: ((.input // 0) + (.cache_read // 0) + (.cache_write // 0))})) as $calls |
    {
      window_days: $days,
      by_harness_model: ($calls | group_by([.harness, .model]) | map({
        harness: .[0].harness, model: .[0].model,
        sessions: (map(.session_id) | unique | length), calls: length,
        input: (map(.input) | add // 0), cache_read: (map(.cache_read) | add // 0),
        cache_write: (map(.cache_write) | add // 0), output: (map(.output) | add // 0),
        cost: ((map(.cost) | map(select(. != null)) | add) as $k | if $k == null then "unknown" else $k end)
      })),
      by_class_model: ($calls | map(select(.harness == "claude")) | group_by([.class, .model]) | map({
        class: .[0].class, model: .[0].model,
        sessions: (map(.session_id) | unique | length), calls: length,
        input: (map(.input) | add // 0), output: (map(.output) | add // 0)
      })),
      context_histogram: {
        under_50k: (($calls | map(select(.context < 50000))) | length),
        "50k_150k": (($calls | map(select(.context >= 50000 and .context < 150000))) | length),
        "150k_300k": (($calls | map(select(.context >= 150000 and .context < 300000))) | length),
        "300k_500k": (($calls | map(select(.context >= 300000 and .context < 500000))) | length),
        over_500k: (($calls | map(select(.context >= 500000))) | length)
      },
      waste: {
        oversized_tool_results: (($waste | map(select(.kind == "tool_result" and .bytes > 20480))) | length),
        write_calls: (($waste | map(select(.kind == "Write"))) | length),
        write_avg_bytes: (($waste | map(select(.kind == "Write") | .bytes)) as $w | if ($w | length) == 0 then 0 else (($w | add) / ($w | length) | floor) end),
        edit_calls: (($waste | map(select(.kind == "Edit"))) | length),
        sessions_over_4h: ($calls | group_by(.session_id) | map(select(length > 1)) | map({
              lo: (map(.timestamp | iso2epoch) | min), hi: (map(.timestamp | iso2epoch) | max)})
            | map(select((.hi - .lo) > 14400)) | length),
        interactive_calls_over_200k_context: ($calls | map(select(.class == "interactive" and .context > 200000)) | length),
        codex_sessions_over_1000_tc_events: ($calls | map(select(.harness == "codex" and (.token_count_events // 0) > 1000)) | length)
      },
      worker_sessions_per_story: ($calls | map(select(.class == "worker"))
        | group_by(.workspace | sub("-(review|fix|postfix|r[0-9]+)$"; ""))
        | map({story: (.[0].workspace | sub("-(review|fix|postfix|r[0-9]+)$"; "")), sessions: (map(.session_id) | unique | length)})
        | sort_by(.story)),
      top_sessions_by_cost: ($calls | group_by(.session_id) | map({
          session_id: .[0].session_id, harness: .[0].harness, model: .[0].model,
          cost: ((map(.cost) | map(select(. != null)) | add) as $k | if $k == null then "unknown" else $k end)
        }) | map(select(.cost != "unknown")) | sort_by(-.cost) | .[0:10]),
      opencode_status: (if ($opencode_unknown | length) > 0 then "unknown (\($opencode_unknown))" else "ok" end),
      disclaimer: "These are observations, not routing guidance. Routing comes from POST /v1/route."
    }'
}

afk_usage_render_human() { # <report json>
  local r="$1"
  jq -r '
    "agent-flow-kit usage-report — last \(.window_days) day(s)\n" +
    "\n== per harness x model ==\n" +
    ((.by_harness_model // []) | if length == 0 then "(none)" else (map("\(.harness)/\(.model): sessions=\(.sessions) calls=\(.calls) input=\(.input) cache_read=\(.cache_read) cache_write=\(.cache_write) output=\(.output) cost=\(.cost)") | join("\n")) end) + "\n" +
    "\n== per session class x model (claude) ==\n" +
    ((.by_class_model // []) | if length == 0 then "(none)" else (map("\(.class)/\(.model): sessions=\(.sessions) calls=\(.calls) input=\(.input) output=\(.output)") | join("\n")) end) + "\n" +
    "\n== context-at-call histogram ==\n" +
    "under 50k: \(.context_histogram.under_50k)  50-150k: \(.context_histogram."50k_150k")  150-300k: \(.context_histogram."150k_300k")  300-500k: \(.context_histogram."300k_500k")  over 500k: \(.context_histogram.over_500k)\n" +
    "\n== waste signals ==\n" +
    "oversized tool results (>20KB): \(.waste.oversized_tool_results)\n" +
    "Write calls: \(.waste.write_calls) (avg \(.waste.write_avg_bytes) bytes)   Edit calls: \(.waste.edit_calls)\n" +
    "sessions over 4h: \(.waste.sessions_over_4h)   interactive calls over 200k context: \(.waste.interactive_calls_over_200k_context)\n" +
    "codex sessions with >1000 token_count events: \(.waste.codex_sessions_over_1000_tc_events)\n" +
    "\n== worker sessions per story ==\n" +
    ((.worker_sessions_per_story // []) | if length == 0 then "(none in window)" else (map("\(.story): \(.sessions)") | join("\n")) end) + "\n" +
    "\n== top sessions by cost ==\n" +
    ((.top_sessions_by_cost // []) | if length == 0 then "(none)" else (map("\(.session_id) [\(.harness)/\(.model)]: \(.cost)") | join("\n")) end) + "\n" +
    "\nopencode: \(.opencode_status)\n" +
    "\n\(.disclaimer)"
  ' <<<"$r"
}
