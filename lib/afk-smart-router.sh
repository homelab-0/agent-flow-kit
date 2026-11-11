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

# afk_router_mark_pool_degraded <pool_id> [<reason>]
# Marks an entitlement pool exhausted/degraded in pool-signals.json when a CLI
# fails at runtime with 401/429/auth/quota errors so AFK immediately fails over.
afk_router_mark_pool_degraded() {
  local pool_id="$1" reason="${2:-runtime_failure}"
  [[ -n "$pool_id" ]] || return 0
  local sig_file cur="{}"
  sig_file="$(afk_router_signals_path)"
  mkdir -p "$(dirname -- "$sig_file")"
  [[ -f "$sig_file" ]] && cur="$(cat -- "$sig_file" 2>/dev/null || printf '{}')"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq --arg pid "$pool_id" --arg r "$reason" --arg ts "$now" \
    '.pools[$pid] = ((.pools[$pid] // {}) + {used_pct: 100, degraded_reason: $r, updated_at: $ts})' \
    <<<"$cur" > "${sig_file}.tmp.$$" && mv "${sig_file}.tmp.$$" "$sig_file"
}

_afk_router_count_recent_activity() {
  local dir="$1" mmin="$2"
  [[ -d "$dir" ]] || { printf '0\n'; return 0; }
  find "$dir" -maxdepth 5 -type f \( -name '*.jsonl' -o -name '*.json' \) -mmin "-$mmin" 2>/dev/null | wc -l | tr -d '[:space:]'
}

# afk_router_probe_pools [<repo>]
# Computes 5-hour (300m) rolling usage & remaining capacity per subscription pool,
# factoring in each pool's declared size (five_hour_session_capacity & pool_tier).
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
    # Shared subscription pool accounting: if OpenCode or Pi uses OpenAI OAuth, feed `openai-plus`
    if jq -e '.[] | select(.harness == "opencode" and .entitlement_pool == "openai-plus")' <<<"$bindings_json" >/dev/null 2>&1; then
      x_5h=$(( x_5h + o_5h ))
    fi
    if jq -e '.[] | select(.harness == "pi" and .entitlement_pool == "openai-plus")' <<<"$bindings_json" >/dev/null 2>&1; then
      x_5h=$(( x_5h + p_5h ))
    fi
  fi

  local sig_json="{}"
  if [[ -f "$sig_file" ]]; then
    sig_json="$(cat -- "$sig_file" 2>/dev/null || printf '{}')"
  fi

  local litellm_on
  litellm_on="$(jq -r '.litellm_gateway.online' <<<"$harnesses_json")"

  jq -cn \
    --slurpfile cat "$cat_file" \
    --argjson h "$harnesses_json" \
    --argjson bind "$bindings_json" \
    --argjson sig "$sig_json" \
    --argjson c5 "$c_5h" \
    --argjson x5 "$x_5h" \
    --argjson a5 "$a_5h" \
    --argjson o5 "$o_5h" \
    --argjson lon "$litellm_on" \
    '
    def calc_pool($pid; $raw_sessions; $is_local; $default_harnesses):
      (($cat[0].entitlement_pools[$pid] // null) // (
        if $pid == "opencode-free" then {provider:"OpenCode Free Tier", cost_class:"free", pool_tier:"free", five_hour_session_capacity:200}
        else {} end
      )) as $meta |
      ($sig.pools[$pid].capacity_5h // $meta.five_hour_session_capacity // 50) as $cap |
      ($sig.pools[$pid].used_pct // (
        if $is_local then
          (if $lon then 0 else 100 end)
        else
          ((($raw_sessions * 100) / $cap) | round | if . > 98 then 98 else . end)
        end
      )) as $used |
      (100 - $used) as $headroom |
      (($cap * $headroom / 100) | floor) as $rem_units |
      (if $is_local and ($lon | not) then "offline"
       elif $pid == "opencode-free" and (($h.opencode.installed // false) | not) then "offline"
       elif $used >= 90 then "exhausted"
       elif $used >= 75 then "warning"
       else "available" end) as $state |
      ([ $bind[] | select(.entitlement_pool == $pid) | .harness ] | unique) as $bound_h |
      ([ $bind[] | select(.entitlement_pool == $pid) | .account_fingerprint ] | unique) as $fps |
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
        active_sessions_5h: $raw_sessions,
        harnesses_feeding_pool: (if ($bound_h | length) > 0 then $bound_h else $default_harnesses end),
        account_fingerprints: $fps
      };

    {
      schema: "afk-router-pools/2",
      harnesses: $h,
      pools: {
        "anthropic-max":    calc_pool("anthropic-max"; $c5; false; ["claude"]),
        "openai-plus":      calc_pool("openai-plus"; $x5; false; ["codex"]),
        "antigravity-pool": calc_pool("antigravity-pool"; $a5; false; ["agy"]),
        "xai-grok":         calc_pool("xai-grok"; $o5; false; ["opencode"]),
        "opencode-free":    calc_pool("opencode-free"; $o5; false; ["opencode"]),
        "litellm-local":    calc_pool("litellm-local"; 0; true; ["claude","opencode"])
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
      # Avoid flooding with dozens of minor variants; keep free models + flagship bridged models
      select(
        .is_free == true or
        (.model | test("gpt-6-astra$|gpt-6\\.1-sol$|gpt-5\\.3-codex-spark$|claude-opus-5-5$|claude-sonnet-5-5$|gemini-4-carbon"))
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
        is_bridged_oauth: (.harness == "opencode" and .cost_class == "subscription"),
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
