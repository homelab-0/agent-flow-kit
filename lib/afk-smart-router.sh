#!/usr/bin/env bash
# afk-smart-router.sh — Multi-Harness, Pool-Capacity & Public-Benchmark Smart Router
#
# Evaluates which installed CLI harness + subscription pool (or LiteLLM gateway)
# should execute each Software Factory stage based strictly on:
#   1. Installed harnesses on the host (claude, codex, agy, opencode, + LiteLLM gateway)
#   2. Subscription pool size (capacity) and live 5h/7d usage headroom
#   3. Live public benchmark leaderboards (LMArena Agent/WebDev/Text, SWE-bench,
#      Artificial Analysis API, and models.dev context limits)
#   4. Independent Cross-Family Blind Review (ensuring code reviewers use a
#      different model family than the builder whenever available)

if [[ -n "${AFK_SMART_ROUTER_SOURCED:-}" ]]; then
  return 0
fi
AFK_SMART_ROUTER_SOURCED=1

# shellcheck disable=SC1091
declare -F afk_harness_inspect_all >/dev/null 2>&1 || . "$(dirname -- "${BASH_SOURCE[0]}")/afk-harnesses.sh"

afk_router_catalog_path() {
  if [[ -n "${AFK_ROUTER_BENCHMARKS_FILE:-}" && -f "${AFK_ROUTER_BENCHMARKS_FILE}" ]]; then
    printf '%s\n' "$AFK_ROUTER_BENCHMARKS_FILE"
    return 0
  fi
  if [[ -f "$HOME/.config/afk/benchmarks.json" ]]; then
    printf '%s\n' "$HOME/.config/afk/benchmarks.json"
    return 0
  fi
  if [[ -f "${AFK_REPO_ROOT:-}/files/model-router/benchmarks.json" ]]; then
    printf '%s\n' "${AFK_REPO_ROOT}/files/model-router/benchmarks.json"
    return 0
  fi
  if [[ -f "$HOME/.agents/skills/model-router/benchmarks.json" ]]; then
    printf '%s\n' "$HOME/.agents/skills/model-router/benchmarks.json"
    return 0
  fi
  printf '%s\n' "/home/user/repos/jlengelbrecht/agent-flow-kit/files/model-router/benchmarks.json"
}

afk_router_signals_path() {
  printf '%s\n' "${AFK_ROUTER_SIGNALS_FILE:-$HOME/.config/afk/pool-signals.json}"
}

# afk_router_stage_to_task_class <stage> <risk>
afk_router_stage_to_task_class() {
  local stage="$1" risk="${2:-low}"
  case "$stage" in
    intake|research)
      printf 'research\n' ;;
    spec|arch*)
      printf 'architecture\n' ;;
    ux)
      printf 'webdev\n' ;;
    build)
      case "$risk" in
        high|critical) printf 'coding_complex\n' ;;
        *)             printf 'coding_standard\n' ;;
      esac
      ;;
    review*|approve)
      printf 'coding_review\n' ;;
    *)
      printf 'coding_standard\n' ;;
  esac
}

_afk_router_verify_binary() {
  local name="$1" cand=""
  if declare -F _afk_harness_locate_bin >/dev/null 2>&1; then
    cand="$(_afk_harness_locate_bin "$name" || true)"
  else
    cand="$(command -v "$name" 2>/dev/null || true)"
  fi
  if [[ -n "$cand" ]] && "$cand" --version >/dev/null 2>&1; then
    printf '%s' "$cand"
    return 0
  fi
  printf ''
}

# afk_router_discover_harnesses [<litellm_url>]
# Discovers installed & executable CLI binaries and LiteLLM gateway availability.
afk_router_discover_harnesses() {
  local litellm_url="${1:-${AFK_LITELLM_BASE_URL:-}}"
  local claude_bin="" codex_bin="" agy_bin="" opencode_bin="" pi_bin=""
  local codex_note=""
  if [[ -n "${AFK_ROUTER_HARNESS_LIST:-}" ]]; then
    local list=",${AFK_ROUTER_HARNESS_LIST},"
    [[ "$list" == *",claude,"* ]] && claude_bin="/mock/bin/claude"
    [[ "$list" == *",codex,"* ]] && codex_bin="/mock/bin/codex"
    [[ "$list" == *",agy,"* ]] && agy_bin="/mock/bin/agy"
    [[ "$list" == *",opencode,"* ]] && opencode_bin="/mock/bin/opencode"
    [[ "$list" == *",pi,"* ]] && pi_bin="/mock/bin/pi"
  else
    claude_bin="$(_afk_router_verify_binary claude)"
    codex_bin="$(_afk_router_verify_binary codex)"
    local raw_codex=""
    raw_codex="$(_afk_harness_locate_bin codex 2>/dev/null || command -v codex 2>/dev/null || true)"
    if [[ -z "$codex_bin" && -n "$raw_codex" ]]; then
      codex_note="broken_binary ($raw_codex failed --version)"
    fi
    agy_bin="$(_afk_router_verify_binary agy)"
    opencode_bin="$(_afk_router_verify_binary opencode)"
    pi_bin="$(_afk_router_verify_binary pi)"
  fi

  local litellm_online=false litellm_models="[]"
  if [[ -n "$litellm_url" ]]; then
    if [[ "${AFK_ROUTER_LITELLM_ASSUME_ONLINE:-0}" == "1" ]]; then
      litellm_online=true
      litellm_models='["local-coding","qwen3.8-coder"]'
    else
      local m_resp
      m_resp="$(curl -sS --connect-timeout 1 --max-time 2 "$litellm_url/v1/models" 2>/dev/null || true)"
      if [[ -n "$m_resp" ]] && jq -e '.data' <<<"$m_resp" >/dev/null 2>&1; then
        litellm_online=true
        litellm_models="$(jq -c '[.data[].id]' <<<"$m_resp" 2>/dev/null || printf '[]')"
      fi
    fi
  fi

  jq -cn \
    --arg cb "$claude_bin" \
    --arg xb "$codex_bin" \
    --arg xn "$codex_note" \
    --arg ab "$agy_bin" \
    --arg ob "$opencode_bin" \
    --arg pb "$pi_bin" \
    --arg lurl "$litellm_url" \
    --argjson lon "$litellm_online" \
    --argjson lmods "$litellm_models" \
    '{
      claude:   {installed: ($cb != ""), binary: (if $cb == "" then null else $cb end), health: (if $cb != "" then "ok" else "missing" end)},
      codex:    {installed: ($xb != ""), binary: (if $xb == "" then null else $xb end), health: (if $xb != "" then "ok" elif $xn != "" then $xn else "missing" end)},
      agy:      {installed: ($ab != ""), binary: (if $ab == "" then null else $ab end), health: (if $ab != "" then "ok" else "missing" end)},
      opencode: {installed: ($ob != ""), binary: (if $ob == "" then null else $ob end), health: (if $ob != "" then "ok" else "missing" end)},
      pi:       {installed: ($pb != ""), binary: (if $pb == "" then null else $pb end), health: (if $pb != "" then "ok" else "missing" end)},
      litellm_gateway: {
        configured: ($lurl != ""),
        base_url: (if $lurl == "" then null else $lurl end),
        online: $lon,
        models: $lmods
      }
    }'
}

# Portable file mtime epoch (Linux GNU stat -c %Y and macOS BSD stat -f %m)
_afk_router_file_mtime() {
  local f="$1"
  [[ -f "$f" ]] || { printf '0\n'; return 0; }
  stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || printf '0\n'
}

# afk_router_mark_pool_degraded <pool_id> [<reason>]
# Marks an entitlement pool degraded in pool-signals.json with severity-aware TTLs:
#   - Hard auth revocation (401/token_revoked): 24h TTL (auto-cleared on re-auth mtime)
#   - Rate limit / quota exhaustion (429/quota/out_of_credits): 1h cooldown TTL
#   - Transient stage timeout / empty output: 15m (900s) cooldown TTL so immediate
#     retries fail over cleanly without permanently bricking the pool.
afk_router_mark_pool_degraded() {
  local pool_id="$1" reason="${2:-runtime_failure}"
  [[ -n "$pool_id" ]] || return 0
  local sig_file cur="{}"
  sig_file="$(afk_router_signals_path)"
  mkdir -p "$(dirname -- "$sig_file")"
  [[ -f "$sig_file" ]] && cur="$(cat -- "$sig_file" 2>/dev/null || printf '{}')"
  local now now_ep lreason kind="transient" ttl_sec=900 used_val=95
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  now_ep="$(date -u +%s)"
  lreason="$(printf '%s' "$reason" | tr '[:upper:]' '[:lower:]')"
  if [[ "$lreason" =~ (401|unauthorized|token_revoked|invalidated[[:space:]]+oauth|refresh[[:space:]]+token) ]]; then
    kind="auth"
    ttl_sec=86400
    used_val=100
  elif [[ "$lreason" =~ (429|rate_limit|rate[[:space:]]+limit|quota|out_of_credits|spend_limit|exhausted) ]]; then
    kind="quota"
    ttl_sec=3600
    used_val=100
  fi
  jq --arg pid "$pool_id" --arg r "$reason" --arg k "$kind" --arg ts "$now" \
    --argjson ep "$now_ep" --argjson ttl "$ttl_sec" --argjson u "$used_val" \
    '.pools[$pid] = ((.pools[$pid] // {}) + {used_pct: $u, degraded_reason: $r, degraded_kind: $k, updated_at: $ts, updated_epoch: $ep, ttl_sec: $ttl})' \
    <<<"$cur" > "${sig_file}.tmp.$$" && mv "${sig_file}.tmp.$$" "$sig_file"
}

_afk_router_count_recent_activity() {
  local dir="$1" mmin="$2"
  [[ -d "$dir" ]] || { printf '0\n'; return 0; }
  find "$dir" -maxdepth 5 -type f \( -name '*.jsonl' -o -name '*.json' \) -mmin "-$mmin" 2>/dev/null | wc -l | tr -d '[:space:]'
}

# _afk_router_probe_claude_quota
# Queries real 5-hour & 7-day OAuth utilization from Anthropic's official usage API
# (`https://api.anthropic.com/api/oauth/usage`) with a 120s local metadata cache
# (never stores or prints tokens). Supports AFK_CLAUDE_USAGE_FIXTURE for hermetic tests.
_afk_router_probe_claude_quota() {
  local raw=""
  if [[ -n "${AFK_CLAUDE_USAGE_FIXTURE:-}" && -f "${AFK_CLAUDE_USAGE_FIXTURE}" ]]; then
    raw="$(cat -- "$AFK_CLAUDE_USAGE_FIXTURE" 2>/dev/null || true)"
  elif [[ -n "${AFK_ROUTER_SIGNALS_FILE:-}" || -n "${AFK_ROUTER_HARNESS_LIST:-}" ]]; then
    printf '{}\n'
    return 0
  else
    local creds_file="${AFK_CLAUDE_CREDS_FILE:-$HOME/.claude/.credentials.json}"
    [[ -f "$creds_file" ]] || { printf '{}\n'; return 0; }
    local cache_file="${AFK_QUOTA_CACHE_FILE:-$HOME/.config/afk/live-quota-cache.json}"
    local now_ep
    now_ep="$(date -u +%s)"
    if [[ -f "$cache_file" ]]; then
      local cached
      cached="$(jq -c --argjson now "$now_ep" '
        if (.claude.fetched_epoch // 0) > 0 and (($now - (.claude.fetched_epoch // 0)) < 120) then
          .claude.data
        else empty end
      ' "$cache_file" 2>/dev/null || true)"
      if [[ -n "$cached" ]]; then
        printf '%s\n' "$cached"
        return 0
      fi
    fi
    local tok=""
    tok="$(jq -r '.claudeAiOauth.accessToken // empty' "$creds_file" 2>/dev/null || true)"
    [[ -n "$tok" ]] || { printf '{}\n'; return 0; }
    raw="$(curl -fsSL --connect-timeout 2 --max-time 4 \
      -H "Authorization: Bearer $tok" \
      -H "anthropic-beta: oauth-2025-04-20" \
      "https://api.anthropic.com/api/oauth/usage" 2>/dev/null || true)"
    tok=""
    [[ -n "$raw" ]] || { printf '{}\n'; return 0; }
  fi

  local parsed=""
  parsed="$(jq -c '
    if (type == "object") and (has("seven_day") or has("five_hour") or has("limits")) then
      ((.five_hour.utilization // 0) | tonumber? // 0) as $fh |
      ((.seven_day.utilization // ([.limits[]? | select(.is_active == true and .group == "weekly") | .percent] | max) // 0) | tonumber? // 0) as $wk |
      ((.extra_usage.is_enabled // false) == true and ((.extra_usage.utilization // 100) < 90)) as $extra_ok |
      (if $extra_ok then ([ $fh, (($wk * 0.80)) ] | max | round)
       else ([ $fh, $wk, ([.limits[]? | select(.is_active == true) | .percent] | max // 0) ] | max | round) end) as $eff |
      {
        ok: true,
        source: "anthropic_oauth_api",
        used_pct: (if $eff > 100 then 100 elif $eff < 0 then 0 else $eff end),
        five_hour_pct: ($fh | round),
        seven_day_pct: ($wk | round),
        resets_at: (.seven_day.resets_at // (.limits[0].resets_at // null)),
        severity: (([.limits[]? | select(.is_active == true) | .severity][0]) // null),
        extra_usage_enabled: (.extra_usage.is_enabled // false)
      }
    else {} end
  ' <<<"$raw" 2>/dev/null || printf '{}')"

  if [[ -z "${AFK_CLAUDE_USAGE_FIXTURE:-}" && -n "$parsed" && "$parsed" != "{}" ]]; then
    local cache_file="${AFK_QUOTA_CACHE_FILE:-$HOME/.config/afk/live-quota-cache.json}"
    local cur_cache="{}" now_ep
    now_ep="$(date -u +%s)"
    mkdir -p "$(dirname -- "$cache_file")"
    [[ -f "$cache_file" ]] && cur_cache="$(cat -- "$cache_file" 2>/dev/null || printf '{}')"
    (umask 077 && jq -cn --argjson cur "$cur_cache" --argjson d "$parsed" --argjson ep "$now_ep" \
      '$cur + {claude: {fetched_epoch: $ep, data: $d}}' > "${cache_file}.tmp.$$" && mv "${cache_file}.tmp.$$" "$cache_file") 2>/dev/null || true
  fi
  [[ -n "$parsed" ]] || parsed="{}"
  printf '%s\n' "$parsed"
}

# _afk_router_probe_codex_quota
# Reads the freshest non-expired `rate_limits` snapshot written by Codex into
# rollout-*.jsonl (zero network cost). Supports AFK_CODEX_SESSIONS_DIR for tests.
_afk_router_probe_codex_quota() {
  local -a search_dirs=()
  if [[ -n "${AFK_CODEX_SESSIONS_DIR:-}" ]]; then
    [[ -d "$AFK_CODEX_SESSIONS_DIR" ]] && search_dirs+=("$AFK_CODEX_SESSIONS_DIR")
  elif [[ -n "${AFK_ROUTER_SIGNALS_FILE:-}" || -n "${AFK_ROUTER_HARNESS_LIST:-}" ]]; then
    printf '{}\n'
    return 0
  else
    [[ -d "$HOME/.codex/sessions" ]] && search_dirs+=("$HOME/.codex/sessions")
    local d
    for d in "$HOME"/.config/orca/codex-accounts/*/home/sessions; do
      [[ -d "$d" ]] && search_dirs+=("$d")
    done
  fi
  (( ${#search_dirs[@]} > 0 )) || { printf '{}\n'; return 0; }

  local -a recent_files=()
  mapfile -t recent_files < <(find "${search_dirs[@]}" -name 'rollout-*.jsonl' -type f 2>/dev/null | awk -F/ '{print $NF" "$0}' | sort | tail -8 | cut -d' ' -f2-)
  local idx f rl_line now_ep
  now_ep="$(date -u +%s)"
  for (( idx=${#recent_files[@]}-1; idx>=0; idx-- )); do
    f="${recent_files[$idx]}"
    [[ -f "$f" ]] || continue
    rl_line="$(grep -a '"rate_limits"' "$f" 2>/dev/null | tail -1 || true)"
    [[ -n "$rl_line" ]] || continue
    local parsed
    parsed="$(jq -c --argjson now "$now_ep" '
      ([.. | objects | select(has("rate_limits")) | .rate_limits] | last // null) as $rl |
      if $rl == null then empty
      else
        ([ $rl.primary, $rl.secondary ] | map(select(. != null and .used_percent != null and ((.resets_at // ($now + 1)) > $now)))) as $wins |
        if ($wins | length) == 0 then empty
        else
          ($wins | map(.used_percent) | max | round) as $eff |
          ([ $wins[] | select((.window_minutes // 0) < 1000) | .used_percent ][0] // null) as $fh |
          ([ $wins[] | select((.window_minutes // 0) >= 1000) | .used_percent ][0] // null) as $wk |
          ([ $wins[] | .resets_at | select(. != null) ] | min // null) as $rst |
          {
            ok: true,
            source: "codex_rate_limits",
            used_pct: (if $eff > 100 then 100 elif $eff < 0 then 0 else $eff end),
            five_hour_pct: (if $fh == null then null else ($fh | round) end),
            seven_day_pct: (if $wk == null then null else ($wk | round) end),
            resets_at_epoch: $rst,
            plan_type: ($rl.plan_type // null)
          }
        end
      end
    ' <<<"$rl_line" 2>/dev/null || true)"
    if [[ -n "$parsed" ]]; then
      printf '%s\n' "$parsed"
      return 0
    fi
  done
  printf '{}\n'
}

# afk_router_probe_pools [<repo>]
# Computes real subscription pool utilization & remaining capacity by combining:
#   1. Live provider quota telemetry (Anthropic OAuth 5h/7d API, Codex session rate_limits)
#   2. TTL-bounded runtime failure signals (expiring transient timeouts after 15m & clearing
#      auth failures automatically when credential files are refreshed)
#   3. Real account bindings (preventing unauthenticated pools like xai-grok from appearing available)
#   4. 5-hour (300m) local session activity fallback when provider telemetry is unavailable.
afk_router_probe_pools() {
  local repo="${1:-}"
  local cfg="{}" litellm_url="${AFK_LITELLM_BASE_URL:-}"
  if [[ -n "$repo" && -f "$repo/.afk/config.json" ]]; then
    cfg="$(cat -- "$repo/.afk/config.json" 2>/dev/null || printf '{}')"
    [[ -z "$litellm_url" ]] && litellm_url="$(jq -r '.router.litellm_base_url // empty' <<<"$cfg" 2>/dev/null)"
  fi

  local cat_file sig_file
  cat_file="$(afk_router_catalog_path)"
  sig_file="$(afk_router_signals_path)"

  local harnesses_json bindings_json="[]"
  harnesses_json="$(afk_router_discover_harnesses "$litellm_url")"
  if declare -F afk_harness_probe_account_bindings >/dev/null 2>&1; then
    if [[ -z "${AFK_ROUTER_HARNESS_LIST:-}" || -n "${AFK_OPENCODE_AUTH_FILE:-}" || -n "${AFK_CODEX_AUTH_FILE:-}" || -n "${AFK_PI_AUTH_FILE:-}" ]]; then
      bindings_json="$(afk_harness_probe_account_bindings)"
    fi
  fi

  local c_5h=0 x_5h=0 a_5h=0 o_5h=0 p_5h=0
  if [[ -z "${AFK_ROUTER_SIGNALS_FILE:-}" ]]; then
    c_5h="$(_afk_router_count_recent_activity "$HOME/.claude/projects" 300)"
    local x1 x2
    x1="$(_afk_router_count_recent_activity "$HOME/.codex/sessions" 300)"
    x2="$(_afk_router_count_recent_activity "$HOME/.config/orca/codex-accounts" 300)"
    x_5h=$(( x1 + x2 ))
    a_5h="$(find "$HOME/.gemini/antigravity-cli/brain" -mindepth 1 -maxdepth 1 -type d -mmin -300 2>/dev/null | wc -l | tr -d '[:space:]')"
    o_5h="$(_afk_router_count_recent_activity "$HOME/.local/share/opencode" 300)"
    p_5h="$(_afk_router_count_recent_activity "$HOME/.pi/agent/sessions" 300)"
    if jq -e '.[] | select(.harness == "opencode" and .entitlement_pool == "openai-plus")' <<<"$bindings_json" >/dev/null 2>&1; then
      x_5h=$(( x_5h + o_5h ))
    fi
    if jq -e '.[] | select(.harness == "pi" and .entitlement_pool == "openai-plus")' <<<"$bindings_json" >/dev/null 2>&1; then
      x_5h=$(( x_5h + p_5h ))
    fi
  fi

  local claude_q="{}" codex_q="{}"
  claude_q="$(_afk_router_probe_claude_quota)"
  codex_q="$(_afk_router_probe_codex_quota)"

  local sig_json="{}"
  if [[ -f "$sig_file" ]]; then
    sig_json="$(cat -- "$sig_file" 2>/dev/null || printf '{}')"
  fi

  local now_ep openai_auth_mtime=0 claude_auth_mtime=0 m1=0 m2=0
  now_ep="$(date -u +%s)"
  m1="$(_afk_router_file_mtime "${AFK_CODEX_AUTH_FILE:-$HOME/.codex/auth.json}")"
  m2="$(_afk_router_file_mtime "${AFK_OPENCODE_AUTH_FILE:-$HOME/.local/share/opencode/auth.json}")"
  (( m1 > m2 )) && openai_auth_mtime="$m1" || openai_auth_mtime="$m2"
  claude_auth_mtime="$(_afk_router_file_mtime "${AFK_CLAUDE_CREDS_FILE:-$HOME/.claude/.credentials.json}")"

  local litellm_on hermetic_mode="false"
  litellm_on="$(jq -r '.litellm_gateway.online' <<<"$harnesses_json")"
  [[ -n "${AFK_ROUTER_HARNESS_LIST:-}" && -z "${AFK_OPENCODE_AUTH_FILE:-}" ]] && hermetic_mode="true"

  jq -cn \
    --slurpfile cat "$cat_file" \
    --argjson h "$harnesses_json" \
    --argjson bind "$bindings_json" \
    --argjson sig "$sig_json" \
    --argjson cq "$claude_q" \
    --argjson xq "$codex_q" \
    --argjson c5 "$c_5h" \
    --argjson x5 "$x_5h" \
    --argjson a5 "$a_5h" \
    --argjson o5 "$o_5h" \
    --argjson now "$now_ep" \
    --argjson oa_mt "$openai_auth_mtime" \
    --argjson ca_mt "$claude_auth_mtime" \
    --argjson lon "$litellm_on" \
    --argjson herm "$hermetic_mode" \
    '
    def parse_ep($obj):
      if ($obj.updated_epoch // null) != null then $obj.updated_epoch
      elif ($obj.updated_at // null) != null then
        (($obj.updated_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) // 0)
      else null end;

    def active_signal($pid; $auth_mtime):
      ($sig.pools[$pid] // null) as $s |
      if $s == null then null
      else
        parse_ep($s) as $up_ep |
        if $up_ep == null then $s
        else
          (($s.degraded_reason // "") | ascii_downcase) as $lr |
          ($s.degraded_kind // (
            if ($lr | test("401|unauthorized|revoked|invalidated oauth|refresh token")) then "auth"
            elif ($lr | test("429|rate_limit|rate limit|quota|out_of_credits|exhausted")) then "quota"
            else "transient" end
          )) as $kind |
          ($s.ttl_sec // (
            if $kind == "auth" then 86400
            elif $kind == "quota" then 3600
            else 900 end
          )) as $ttl |
          if ($kind == "auth" and $auth_mtime > $up_ep) then null
          elif (($now - $up_ep) >= $ttl) then null
          else ($s + {degraded_kind: $kind, ttl_remaining_sec: ($ttl - ($now - $up_ep))}) end
        end
      end;

    def calc_pool($pid; $raw_sessions; $is_local; $default_harnesses; $live_q; $auth_mtime):
      (($cat[0].entitlement_pools[$pid] // null) // (
        if $pid == "opencode-free" then {provider:"OpenCode Free Tier", cost_class:"free", pool_tier:"free", five_hour_session_capacity:200}
        else {} end
      )) as $meta |
      active_signal($pid; $auth_mtime) as $asig |
      ([ $bind[] | select(.entitlement_pool == $pid) | .harness ] | unique) as $bound_h |
      ([ $bind[] | select(.entitlement_pool == $pid) | .account_fingerprint ] | unique) as $fps |
      ($asig.capacity_5h // ($sig.pools[$pid].capacity_5h // null) // $meta.five_hour_session_capacity // 50) as $cap |
      (
        $pid == "xai-grok" and ($herm | not) and ($asig == null) and (($bound_h | length) == 0)
      ) as $unauthenticated |
      (
        if $asig != null and ($asig.used_pct // null) != null then
          {used: $asig.used_pct, src: ("runtime_signal:" + ($asig.degraded_kind // "manual"))}
        elif $unauthenticated then
          {used: 100, src: "unauthenticated"}
        elif ($live_q.ok // false) == true then
          {used: $live_q.used_pct, src: $live_q.source}
        elif $is_local then
          {used: (if $lon then 0 else 100 end), src: "gateway_probe"}
        else
          {used: (((($raw_sessions * 100) / $cap) | round) | if . > 98 then 98 else . end), src: "local_5h_activity"}
        end
      ) as $uinfo |
      $uinfo.used as $used |
      (100 - $used) as $headroom |
      (($cap * $headroom / 100) | floor) as $rem_units |
      (if $is_local and ($lon | not) then "offline"
       elif $pid == "opencode-free" and (($h.opencode.installed // false) | not) then "offline"
       elif $unauthenticated then "offline"
       elif $used >= 90 then "exhausted"
       elif $used >= 75 then "warning"
       else "available" end) as $state |
      {
        pool_id: $pid,
        provider: ($meta.provider // $pid),
        pool_tier: ($meta.pool_tier // "standard"),
        cost_class: ($meta.cost_class // "subscription"),
        state: $state,
        capacity_5h: $cap,
        remaining_units_5h: $rem_units,
        used_pct: $used,
        headroom_pct: $headroom,
        quota_source: $uinfo.src,
        weekly_used_pct: ($live_q.seven_day_pct // null),
        five_hour_used_pct: ($live_q.five_hour_pct // null),
        resets_at: ($live_q.resets_at // null),
        degraded_reason: ($asig.degraded_reason // null),
        active_sessions_5h: $raw_sessions,
        harnesses_feeding_pool: (if ($bound_h | length) > 0 then $bound_h else $default_harnesses end),
        account_fingerprints: $fps
      };

    {
      schema: "afk-router-pools/2",
      harnesses: $h,
      pools: {
        "anthropic-max":    calc_pool("anthropic-max"; $c5; false; ["claude"]; $cq; $ca_mt),
        "openai-plus":      calc_pool("openai-plus"; $x5; false; ["codex"]; $xq; $oa_mt),
        "antigravity-pool": calc_pool("antigravity-pool"; $a5; false; ["agy"]; {}; 0),
        "xai-grok":         calc_pool("xai-grok"; $o5; false; ["opencode"]; {}; 0),
        "opencode-free":    calc_pool("opencode-free"; $o5; false; ["opencode"]; {}; 0),
        "litellm-local":    calc_pool("litellm-local"; 0; true; ["claude","opencode"]; {}; 0)
      }
    }'
}

# afk_router_select_candidate <repo> <stage> <risk> [<builder_family>]
# Evaluates public benchmark scores + pool size/headroom + live discovered models
# (including free OpenCode models and shared multi-harness OAuth pools) to pick
# the winning (harness, launch_class, model, entitlement_pool) for <stage>.
afk_router_select_candidate() {
  local repo="${1:-}" stage="${2:-build}" risk="${3:-low}" builder_family="${4:-}"
  local cfg="{}"
  if [[ -n "$repo" && -f "$repo/.afk/config.json" ]]; then
    cfg="$(cat -- "$repo/.afk/config.json" 2>/dev/null || printf '{}')"
  fi

  local task_class
  task_class="$(afk_router_stage_to_task_class "$stage" "$risk")"

  local default_mem="advisory"
  if [[ "$stage" == review* || "$stage" == "approve" ]]; then
    default_mem="$(jq -r '.router.hindsight.review_stages // "blind"' <<<"$cfg" 2>/dev/null)"
  else
    default_mem="$(jq -r '.router.hindsight.build_stages // "advisory"' <<<"$cfg" 2>/dev/null)"
  fi

  local litellm_url allow_metered prefer_free
  litellm_url="${AFK_LITELLM_BASE_URL:-$(jq -r '.router.litellm_base_url // empty' <<<"$cfg" 2>/dev/null)}"
  allow_metered="${AFK_ROUTER_ALLOW_METERED_API:-$(jq -r '.router.allow_metered_api // false' <<<"$cfg" 2>/dev/null)}"
  prefer_free="${AFK_ROUTER_PREFER_FREE:-$(jq -r '.router.prefer_free_for_low_risk // false' <<<"$cfg" 2>/dev/null)}"
  [[ "$allow_metered" == "true" || "$allow_metered" == "1" ]] && allow_metered="true" || allow_metered="false"
  [[ "$prefer_free" == "true" || "$prefer_free" == "1" ]] && prefer_free="true" || prefer_free="false"

  local cat_file probe_json disc_file tmp_disc
  cat_file="$(afk_router_catalog_path)"
  probe_json="$(afk_router_probe_pools "$repo")"
  disc_file="$(afk_harness_discovered_models_path)"
  tmp_disc="$(mktemp "${TMPDIR:-/tmp}/afk-disc-ref.XXXXXX")"
  if [[ -n "${AFK_DISCOVERED_MODELS_FILE:-}" && -f "${AFK_DISCOVERED_MODELS_FILE}" ]]; then
    cp -- "$AFK_DISCOVERED_MODELS_FILE" "$tmp_disc"
  elif [[ -z "${AFK_ROUTER_HARNESS_LIST:-}" && -f "$disc_file" ]]; then
    cp -- "$disc_file" "$tmp_disc"
  else
    printf '{"models":[]}\n' > "$tmp_disc"
  fi

  local result_json
  result_json="$(jq -cn \
    --slurpfile cat "$cat_file" \
    --slurpfile disc "$tmp_disc" \
    --argjson probe "$probe_json" \
    --arg st "$stage" \
    --arg tc "$task_class" \
    --arg rk "$risk" \
    --arg bf "$builder_family" \
    --arg mm "$default_mem" \
    --arg lurl "$litellm_url" \
    --argjson allow_api "$allow_metered" \
    --argjson pref_free "$prefer_free" \
    '
    # Convert dynamically discovered models (free tier + bridged OAuth frontier models)
    # into router candidate records so newly added models enter routing automatically.
    ([
      $disc[0].models[]? |
      select(.capabilities.toolcall == true) |
      select(.cost_class == "free" or .cost_class == "subscription" or ($allow_api == true and .cost_class == "api-metered")) |
      # Avoid flooding with dozens of minor variants; keep free models + flagship bridged models,
      # and deduplicate agy gemini-4-carbon against catalog agy-carbon-native.
      select((.harness == "agy" and (.model | test("^gemini-4-carbon"))) | not) |
      select(
        .is_free == true or
        (.model | test("gpt-6-astra$|gpt-6\\.1-sol$|gpt-5\\.3-codex-spark$|claude-opus-5-5(-high)?$|claude-sonnet-5-5(-high)?$|gemini-4-argon-high$|gemini-3\\.8-flash-high$"))
      ) |
      {
        id: .id,
        harness: .harness,
        launch_class: .launch_class,
        entitlement_pool: .entitlement_pool,
        cost_class: .cost_class,
        is_free: .is_free,
        model: .model,
        canonical_model: .canonical_model,
        model_family: .model_family,
        effort: (if .capabilities.reasoning then "high" else "medium" end),
        window_tokens: .window_tokens,
        requires_gateway: false,
        is_bridged_oauth: (
          (.harness == "opencode" and .cost_class == "subscription") or
          (.harness == "agy" and (.model | test("^claude-")))
        ),
        benchmarks: (
          .benchmarks | with_entries(.value = {score: .value.score, benchmark: (.value.benchmark // .value.source // "Dynamic Eval")})
        )
      }
    ]) as $dyn_cands |

    (($cat[0].candidates // []) + $dyn_cands) as $cands |
    (
      ($probe.pools["anthropic-max"].state != "available") and
      ($probe.pools["antigravity-pool"].state != "available")
    ) as $subs_under_pressure |

    [
      $cands[] |
      . as $c |
      ($probe.harnesses[$c.harness].installed // false) as $h_installed |
      ($probe.pools[$c.entitlement_pool] // {state:"available", headroom_pct:100, used_pct:0, capacity_5h:50, remaining_units_5h:50, cost_class:($c.cost_class // "subscription")}) as $pool |
      ($c.cost_class // $pool.cost_class // "subscription") as $cclass |
      ($c.benchmarks[$tc].score // 75.0) as $base_score |
      ($c.benchmarks[$tc].benchmark // "Public Leaderboard Aggregate") as $b_name |

      # Eligibility gates:
      # 1. Harness binary installed & healthy on host
      # 2. Metered API models blocked unless allow_metered_api == true
      # 3. Pool not exhausted (>=90%) or offline
      # 4. Gateway candidates require LiteLLM gateway to be online
      select($h_installed == true) |
      select($cclass != "api-metered" or $allow_api == true) |
      select($pool.state != "exhausted" and $pool.state != "offline") |
      select((($c.requires_gateway // false) == false) or ($probe.harnesses.litellm_gateway.online == true)) |

      # Pool conservation adjustment:
      (if ($pool.state == "warning" and ($rk == "low" or $rk == "medium")) then -15.0 else 0.0 end) as $pool_adj |

      # Pool headroom + pool size bonus:
      (($pool.headroom_pct // 50) * 0.02) as $headroom_bonus |
      ((($pool.remaining_units_5h // 25) | if . > 60 then 60 else . end) * 0.025) as $capacity_bonus |

      # Prefer native harness slightly (+0.5) over bridged OAuth when both are healthy on the same pool
      (if ($c.is_bridged_oauth // false) then -0.5 else 0.0 end) as $bridge_adj |

      # Cross-Family Blind Review Bonus:
      (if ($tc == "coding_review" and $bf != "" and $c.model_family != $bf) then 6.0 else 0.0 end) as $cross_family_bonus |

      # Local AI Zero-Cost Bonus on low-risk tasks when LiteLLM cluster is online
      (if (($c.requires_gateway // false) == true and $rk == "low" and ($tc == "research" or $tc == "coding_standard")) then 6.5 else 0.0 end) as $local_bonus |

      # Free OpenCode Model Bonus ($0 cost):
      # Boost capable free models on low-risk intake/build when `prefer_free_for_low_risk` is enabled
      # OR when primary subscription pools are under pressure (warning/exhausted).
      (if (($c.is_free // false) == true and $rk == "low" and ($tc == "research" or $tc == "coding_standard") and ($pref_free == true or $subs_under_pressure == true)) then 14.0 else 0.0 end) as $free_bonus |

      ($base_score + $pool_adj + $headroom_bonus + $capacity_bonus + $bridge_adj + $cross_family_bonus + $local_bonus + $free_bonus) as $eff_score |

      {
        stage: $st,
        task_class: $tc,
        risk: $rk,
        candidate_id: $c.id,
        harness: $c.harness,
        launch_class: $c.launch_class,
        model: $c.model,
        canonical_model: $c.canonical_model,
        model_family: $c.model_family,
        cost_class: $cclass,
        is_free: ($c.is_free // ($cclass == "free")),
        effort: $c.effort,
        window_tokens: $c.window_tokens,
        entitlement_pool: $c.entitlement_pool,
        pool_state: $pool.state,
        pool_capacity_5h: $pool.capacity_5h,
        pool_remaining_5h: $pool.remaining_units_5h,
        pool_used_pct: $pool.used_pct,
        pool_headroom_pct: $pool.headroom_pct,
        benchmark_name: $b_name,
        benchmark_score: $base_score,
        effective_score: (($eff_score * 100 | round) / 100),
        cross_family_review: ($tc == "coding_review" and $bf != "" and $c.model_family != $bf),
        memory_mode: $mm,
        router_source: (if ($c.requires_gateway // false) then "afk-benchmarks+litellm" else "afk-benchmarks" end),
        litellm_base_url: (if (($c.requires_gateway // false) and $lurl != "") then $lurl else null end),
        reason: (
          "Selected " + $c.harness + "/" + $c.model + " [" + $c.canonical_model + ", cost=" + $cclass + "] " +
          "(pool=" + $c.entitlement_pool + " " + ($pool.remaining_units_5h|tostring) + "/" + ($pool.capacity_5h|tostring) + " free [" + ($pool.headroom_pct|tostring) + "%], " +
          "benchmark=" + ($base_score|tostring) + " via " + $b_name +
          (if ($tc == "coding_review" and $bf != "" and $c.model_family != $bf) then ", cross-family blind review vs " + $bf else "" end) +
          (if $pool.state == "warning" then ", pool conservation penalty applied" else "" end) + ")"
        )
      }
    ] | sort_by(-.effective_score) | .[0] // {
      stage: $st,
      task_class: $tc,
      risk: $rk,
      harness: "claude",
      launch_class: "claude-native",
      model: "sonnet",
      canonical_model: "anthropic/claude-sonnet-5-5",
      model_family: "anthropic",
      cost_class: "subscription",
      is_free: false,
      effort: "medium",
      window_tokens: 1000000,
      entitlement_pool: "anthropic-max",
      pool_headroom_pct: 100,
      benchmark_name: "Fallback Default",
      benchmark_score: 85.0,
      effective_score: 85.0,
      memory_mode: $mm,
      router_source: "fallback-default",
      litellm_base_url: (if $lurl == "" then null else $lurl end),
      reason: "Fallback route (no eligible candidate matched)"
    }')"
  rm -f "$tmp_disc"
  printf '%s\n' "$result_json"
}

# afk_router_sync_benchmarks [<out_file>]
# Pulls live public benchmark rankings and model capabilities from popular public sources:
#   1. LMArena Agent Leaderboard (HuggingFace Datasets API — real-world agentic coding)
#   2. LMArena WebDev Leaderboard (HuggingFace Datasets API — UI/UX & frontend coding Elo)
#   3. LMArena Text Leaderboard (HuggingFace Datasets API — reasoning & synthesis Elo)
#   4. SWE-bench Official Leaderboard (GitHub JSON — verified issue resolution)
#   5. Artificial Analysis API (optional when ARTIFICIAL_ANALYSIS_API_KEY / AA_API_KEY is set)
#   6. models.dev API (live context window & output token limits)
# Computes normalized 0-100 task-class scores for every candidate and writes atomically
# to ~/.config/afk/benchmarks.json.
afk_router_sync_benchmarks() {
  local out_file="${1:-$HOME/.config/afk/benchmarks.json}"
  local base_file="/home/user/repos/jlengelbrecht/agent-flow-kit/files/model-router/benchmarks.json"
  [[ -f "$base_file" ]] || base_file="$HOME/.agents/skills/model-router/benchmarks.json"

  mkdir -p "$(dirname -- "$out_file")"
  local today sync_tmp
  today="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  sync_tmp="$(mktemp -d)"

  printf '[]' > "$sync_tmp/agent.json"
  printf '[]' > "$sync_tmp/webdev.json"
  printf '[]' > "$sync_tmp/text.json"
  printf '[]' > "$sync_tmp/swebench.json"
  printf '{}' > "$sync_tmp/mdev.json"
  printf '[]' > "$sync_tmp/aa.json"

  local st_agent="offline" st_webdev="offline" st_text="offline" st_swe="offline" st_mdev="offline" st_aa="no_key"

  local raw
  raw="$(curl -sS --connect-timeout 3 --max-time 8 "https://datasets-server.huggingface.co/rows?dataset=lmarena-ai%2Fleaderboard-dataset&config=agent&split=latest&offset=0&length=50" 2>/dev/null || true)"
  if [[ -n "$raw" ]] && jq -e '.rows | length > 0' <<<"$raw" >/dev/null 2>&1; then
    jq -c '[.rows[].row | {model_name, rank, score, date: .leaderboard_publish_date}]' <<<"$raw" > "$sync_tmp/agent.json"
    st_agent="live_synced ($(jq -r '.[0].date // "latest"' "$sync_tmp/agent.json"))"
  fi

  raw="$(curl -sS --connect-timeout 3 --max-time 8 "https://datasets-server.huggingface.co/rows?dataset=lmarena-ai%2Fleaderboard-dataset&config=webdev&split=latest&offset=0&length=50" 2>/dev/null || true)"
  if [[ -n "$raw" ]] && jq -e '.rows | length > 0' <<<"$raw" >/dev/null 2>&1; then
    jq -c '[.rows[].row | {model_name, rank, rating, date: .leaderboard_publish_date}]' <<<"$raw" > "$sync_tmp/webdev.json"
    st_webdev="live_synced ($(jq -r '.[0].date // "latest"' "$sync_tmp/webdev.json"))"
  fi

  raw="$(curl -sS --connect-timeout 3 --max-time 8 "https://datasets-server.huggingface.co/rows?dataset=lmarena-ai%2Fleaderboard-dataset&config=text&split=latest&offset=0&length=50" 2>/dev/null || true)"
  if [[ -n "$raw" ]] && jq -e '.rows | length > 0' <<<"$raw" >/dev/null 2>&1; then
    jq -c '[.rows[].row | {model_name, rank, rating}]' <<<"$raw" > "$sync_tmp/text.json"
    st_text="live_synced"
  fi

  raw="$(curl -sS --connect-timeout 3 --max-time 8 "https://raw.githubusercontent.com/SWE-bench/swe-bench.github.io/master/data/leaderboards.json" 2>/dev/null || true)"
  if [[ -n "$raw" ]] && jq -e '.leaderboards' <<<"$raw" >/dev/null 2>&1; then
    jq -c '[.leaderboards[] | select(.name=="Verified") | .results[] | {name, resolved}] | .[0:50]' <<<"$raw" > "$sync_tmp/swebench.json" 2>/dev/null || true
    st_swe="live_synced"
  fi

  raw="$(curl -sS --connect-timeout 3 --max-time 8 "https://models.dev/api.json" 2>/dev/null || true)"
  if [[ -n "$raw" ]] && jq -e 'type == "object"' <<<"$raw" >/dev/null 2>&1; then
    jq -c 'with_entries(.value = (.value.models // {} | with_entries(.value = (.value.limit.context // null))))' <<<"$raw" > "$sync_tmp/mdev.json" 2>/dev/null || true
    st_mdev="live_synced"
  fi

  local aa_key="${ARTIFICIAL_ANALYSIS_API_KEY:-${AA_API_KEY:-}}"
  if [[ -n "$aa_key" ]]; then
    raw="$(curl -sS --connect-timeout 3 --max-time 8 -H "x-api-key: $aa_key" "https://artificialanalysis.ai/api/v2/data/llms/models" 2>/dev/null || true)"
    if [[ -n "$raw" ]] && jq -e '.data' <<<"$raw" >/dev/null 2>&1; then
      jq -c '[.data[] | {slug, name, coding: .evaluations.artificial_analysis_coding_index, intelligence: .evaluations.artificial_analysis_intelligence_index}]' <<<"$raw" > "$sync_tmp/aa.json"
      st_aa="live_synced"
    else
      st_aa="error"
    fi
  fi

  # Recompute live context windows and normalized 0-100 benchmark scores from live feeds!
  local tmp_out="${out_file}.tmp.$$"
  jq \
    --arg ts "$today" \
    --arg sa "$st_agent" \
    --arg sw "$st_webdev" \
    --arg stx "$st_text" \
    --arg ss "$st_swe" \
    --arg sm "$st_mdev" \
    --arg saa "$st_aa" \
    --slurpfile agf "$sync_tmp/agent.json" \
    --slurpfile wdf "$sync_tmp/webdev.json" \
    --slurpfile txf "$sync_tmp/text.json" \
    --slurpfile swf "$sync_tmp/swebench.json" \
    --slurpfile mdf "$sync_tmp/mdev.json" \
    --slurpfile aaf "$sync_tmp/aa.json" \
    '
    ($agf[0] // []) as $ag |
    ($wdf[0] // []) as $wd |
    ($txf[0] // []) as $tx |
    ($swf[0] // []) as $swb |
    ($mdf[0] // {}) as $md |
    ($aaf[0] // []) as $aa |
    .updated_at = $ts |
    .sync_receipt = {
      synced_at: $ts,
      lmarena_agent: $sa,
      lmarena_webdev: $sw,
      lmarena_text: $stx,
      swe_bench_official: $ss,
      swe_bench_entries: ($swb | length),
      models_dev: $sm,
      artificial_analysis: $saa
    } |
    .candidates |= map(
      . as $c |
      # 1. Update context window dynamically from models.dev if present
      (($md[$c.models_dev_provider // ""][$c.models_dev_id // ""]) // $c.window_tokens) as $live_win |
      .window_tokens = $live_win |

      # 2. Match live LMArena Agent row (rank -> normalized 84..98 score)
      ([ $ag[]? | select((.model_name // "") | contains($c.arena_match // "__none__")) ][0]) as $ag_hit |
      (if $ag_hit != null and ($ag_hit.rank != null) then
        ((98.0 - (($ag_hit.rank - 1) * 0.9)) | if . < 80 then 80 else (. * 10 | round / 10) end)
       else null end) as $ag_score |

      # 3. Match live LMArena WebDev row (rating/rank -> normalized 84..97.5 score)
      ([ $wd[]? | select((.model_name // "") | contains($c.arena_match // "__none__")) ][0]) as $wd_hit |
      (if $wd_hit != null and ($wd_hit.rank != null) then
        ((97.5 - (($wd_hit.rank - 1) * 0.9)) | if . < 80 then 80 else (. * 10 | round / 10) end)
       else null end) as $wd_score |

      # 4. Match live LMArena Text row (rank -> normalized 85..97.5 score)
      ([ $tx[]? | select((.model_name // "") | contains($c.arena_match // "__none__")) ][0]) as $tx_hit |
      (if $tx_hit != null and ($tx_hit.rank != null) then
        ((97.5 - (($tx_hit.rank - 1) * 0.9)) | if . < 80 then 80 else (. * 10 | round / 10) end)
       else null end) as $tx_score |

      # 5. Match Artificial Analysis Coding Index when API key is configured
      ([ $aa[]? | select((.slug // "") | contains($c.aa_slug_match // "__none__")) | select(.coding != null) ][0]) as $aa_hit |

      if $ag_score != null then
        .benchmarks.coding_complex = {
          score: (if $aa_hit != null then (($ag_score * 0.6 + $aa_hit.coding * 0.4) * 10 | round / 10) else $ag_score end),
          benchmark: ("LMArena Agent #" + ($ag_hit.rank|tostring) + " (" + ($ag_hit.date // "live") + ")")
        } |
        .benchmarks.architecture = {
          score: (((($ag_score * 0.6) + (($tx_score // $ag_score) * 0.4)) * 10) | round / 10),
          benchmark: ("LMArena Agent #" + ($ag_hit.rank|tostring) + " + Reasoning")
        }
      else . end |
      if $wd_score != null then
        .benchmarks.webdev = {
          score: $wd_score,
          benchmark: ("LMArena WebDev #" + ($wd_hit.rank|tostring) + (if $wd_hit.rating != null then " (" + ($wd_hit.rating|round|tostring) + " Elo)" else "" end))
        }
      else . end |
      if $tx_score != null then
        .benchmarks.research = {
          score: $tx_score,
          benchmark: ("LMArena Reasoning #" + ($tx_hit.rank|tostring) + (if $tx_hit.rating != null then " (" + ($tx_hit.rating|round|tostring) + " Elo)" else "" end))
        }
      else . end
    )
    ' "$base_file" > "$tmp_out" && mv "$tmp_out" "$out_file"
  rm -rf "$sync_tmp"

  jq -cn \
    --arg out "$out_file" \
    --arg ts "$today" \
    --arg sa "$st_agent" \
    --arg sw "$st_webdev" \
    --arg stx "$st_text" \
    --arg ss "$st_swe" \
    --arg sm "$st_mdev" \
    --arg saa "$st_aa" \
    --argjson count "$(jq '.candidates | length' "$out_file")" \
    '{
      schema: "afk-benchmark-sync/2",
      catalog_path: $out,
      synced_at: $ts,
      candidates_count: $count,
      feeds: {
        lmarena_agent: $sa,
        lmarena_webdev: $sw,
        lmarena_text: $stx,
        swe_bench_official: $ss,
        models_dev: $sm,
        artificial_analysis: $saa
      }
    }'
}
