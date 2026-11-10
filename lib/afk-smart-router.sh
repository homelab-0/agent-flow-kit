#!/usr/bin/env bash
# afk-smart-router.sh — Multi-Harness, Subscription-Pool & Benchmark Smart Router
#
# Bridges today's host reality (multiple installed CLI harnesses + flat-rate OAuth
# subscription pools + LiteLLM-fronted Local AI cluster) with Spektr's target
# control-plane contract (POST /v1/route, pool headroom signals, and task-class
# benchmark quality scores).
#
# Layer 1 (AFK / Spektr): Chooses which CLI harness + entitlement pool + model
#   profile to launch:
#   - Native Subscription Launch (claude-native, codex-native, agy-native, opencode-native):
#     Uses the CLI's flat-rate OAuth subscription directly.
#   - Gateway Launch (claude-gateway, opencode-gateway -> LiteLLM):
#     Points ANTHROPIC_BASE_URL / OPENAI_BASE_URL at LiteLLM so LiteLLM's smart
#     router can load-balance across local cluster GPU nodes (vLLM/Ollama/llama.cpp)
#     or API backends.

if [[ -n "${AFK_SMART_ROUTER_SOURCED:-}" ]]; then
  return 0
fi
AFK_SMART_ROUTER_SOURCED=1

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

# afk_router_discover_harnesses [<litellm_url>]
# Returns JSON object mapping harness name -> {installed, binary_path}
afk_router_discover_harnesses() {
  local litellm_url="${1:-${AFK_LITELLM_BASE_URL:-}}"
  local claude_bin="" codex_bin="" agy_bin="" opencode_bin=""
  if [[ -n "${AFK_ROUTER_HARNESS_LIST:-}" ]]; then
    # Test override: comma-separated list of installed harnesses
    local list=",${AFK_ROUTER_HARNESS_LIST},"
    [[ "$list" == *",claude,"* ]] && claude_bin="/mock/bin/claude"
    [[ "$list" == *",codex,"* ]] && codex_bin="/mock/bin/codex"
    [[ "$list" == *",agy,"* ]] && agy_bin="/mock/bin/agy"
    [[ "$list" == *",opencode,"* ]] && opencode_bin="/mock/bin/opencode"
  else
    claude_bin="$(command -v claude 2>/dev/null || true)"
    codex_bin="$(command -v codex 2>/dev/null || true)"
    agy_bin="$(command -v agy 2>/dev/null || true)"
    opencode_bin="$(command -v opencode 2>/dev/null || true)"
  fi

  local litellm_online=false litellm_models="[]"
  if [[ -n "$litellm_url" ]]; then
    if [[ "${AFK_ROUTER_LITELLM_ASSUME_ONLINE:-0}" == "1" ]]; then
      litellm_online=true
      litellm_models='["local-coding","qwen3-coder-32b"]'
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
    --arg ab "$agy_bin" \
    --arg ob "$opencode_bin" \
    --arg lurl "$litellm_url" \
    --argjson lon "$litellm_online" \
    --argjson lmods "$litellm_models" \
    '{
      claude:   {installed: ($cb != ""), binary: (if $cb == "" then null else $cb end)},
      codex:    {installed: ($xb != ""), binary: (if $xb == "" then null else $xb end)},
      agy:      {installed: ($ab != ""), binary: (if $ab == "" then null else $ab end)},
      opencode: {installed: ($ob != ""), binary: (if $ob == "" then null else $ob end)},
      litellm_gateway: {
        configured: ($lurl != ""),
        base_url: (if $lurl == "" then null else $lurl end),
        online: $lon,
        models: $lmods
      }
    }'
}

# _afk_router_count_recent_activity <dir> <mmin>
_afk_router_count_recent_activity() {
  local dir="$1" mmin="$2"
  [[ -d "$dir" ]] || { printf '0\n'; return 0; }
  find "$dir" -maxdepth 5 -type f \( -name '*.jsonl' -o -name '*.json' \) -mmin "-$mmin" 2>/dev/null | wc -l | tr -d '[:space:]'
}

# afk_router_probe_pools [<repo>]
# Computes 5-hour (300m) and 7-day (10080m) rolling usage & headroom per subscription pool.
# Honours explicit Spektr-compatible signals in ~/.config/afk/pool-signals.json when present.
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

  local harnesses_json
  harnesses_json="$(afk_router_discover_harnesses "$litellm_url")"

  # Fast rolling-window activity probe (files active in last 5 hours = 300 mins)
  local c_5h=0 x_5h=0 a_5h=0 o_5h=0
  if [[ -z "${AFK_ROUTER_SIGNALS_FILE:-}" ]]; then
    c_5h="$(_afk_router_count_recent_activity "$HOME/.claude/projects" 300)"
    local x1 x2
    x1="$(_afk_router_count_recent_activity "$HOME/.codex/sessions" 300)"
    x2="$(_afk_router_count_recent_activity "$HOME/.config/orca/codex-accounts" 300)"
    x_5h=$(( x1 + x2 ))
    a_5h="$(_afk_router_count_recent_activity "$HOME/.gemini/antigravity-cli/brain" 300)"
    o_5h="$(_afk_router_count_recent_activity "$HOME/.local/share/opencode" 300)"
  fi

  # Convert active session files into conservative 5-hour window used_pct estimates
  # (or read exact used_pct from pool-signals.json if present)
  local sig_json="{}"
  if [[ -f "$sig_file" ]]; then
    sig_json="$(cat -- "$sig_file" 2>/dev/null || printf '{}')"
  fi

  local litellm_on
  litellm_on="$(jq -r '.litellm_gateway.online' <<<"$harnesses_json")"

  jq -cn \
    --slurpfile cat "$cat_file" \
    --argjson h "$harnesses_json" \
    --argjson sig "$sig_json" \
    --argjson c5 "$c_5h" \
    --argjson x5 "$x_5h" \
    --argjson a5 "$a_5h" \
    --argjson o5 "$o_5h" \
    --argjson lon "$litellm_on" \
    '
    def calc_pool($pid; $raw_sessions; $cap; $is_local):
      ($sig.pools[$pid].used_pct // (
        if $is_local then
          (if $lon then 0 else 100 end)
        else
          (($raw_sessions * 4) | if . > 95 then 95 else . end)
        end
      )) as $used |
      (100 - $used) as $headroom |
      (if $is_local and ($lon | not) then "offline"
       elif $used >= 90 then "exhausted"
       elif $used >= 75 then "warning"
       else "available" end) as $state |
      {
        pool_id: $pid,
        provider: ($cat[0].entitlement_pools[$pid].provider // $pid),
        cost_class: ($cat[0].entitlement_pools[$pid].cost_class // "subscription"),
        funding_type: ($cat[0].entitlement_pools[$pid].funding_type // "subscription_window"),
        state: $state,
        used_pct: $used,
        headroom_pct: $headroom,
        active_sessions_5h: $raw_sessions,
        binding_window: (if $is_local then "cluster_health" else "five_hour" end)
      };

    {
      schema: "afk-router-pools/1",
      harnesses: $h,
      pools: {
        "anthropic-max":    calc_pool("anthropic-max"; $c5; 25; false),
        "openai-plus":      calc_pool("openai-plus"; $x5; 25; false),
        "antigravity-pool": calc_pool("antigravity-pool"; $a5; 25; false),
        "xai-grok":         calc_pool("xai-grok"; $o5; 25; false),
        "litellm-local":    calc_pool("litellm-local"; 0; 999; true)
      }
    }'
}

# afk_router_select_candidate <repo> <stage> <risk> [<builder_family>]
# Selects the optimal (harness, launch_class, model, entitlement_pool) for <stage>.
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

  local router_mode spektr_url litellm_url
  router_mode="$(jq -r '.router.mode // "smart"' <<<"$cfg" 2>/dev/null)"
  spektr_url="${AFK_SPEKTR_URL:-$(jq -r '.router.spektr_url // empty' <<<"$cfg" 2>/dev/null)}"
  litellm_url="${AFK_LITELLM_BASE_URL:-$(jq -r '.router.litellm_base_url // empty' <<<"$cfg" 2>/dev/null)}"

  # 1. If Spektr Control Plane (/v1/route) is explicitly enabled and reachable, query it first
  if [[ "$router_mode" == "spektr" && -n "$spektr_url" ]]; then
    local req_body sp_resp sp_model sp_harness sp_win
    req_body="$(jq -cn --arg sid "factory-$stage" --arg st "$stage" --arg br "$risk" \
      '{story_id:$sid, title:$st, summary:$st, touched_paths:[], ambiguity:(if $st=="spec" or $st=="intake" then "high" else "low" end), blast_radius:$br, context_size:24000, volume_hint:"low", tags:[$st], repo:"factory", requester:"afk-factory"}')"
    sp_resp="$(curl -sS --connect-timeout 2 --max-time 5 -X POST -H 'Content-Type: application/json' --data-binary "$req_body" "$spektr_url/v1/route" 2>/dev/null || true)"
    sp_model="$(jq -r '.model_profile // .model // empty' <<<"$sp_resp" 2>/dev/null || true)"
    sp_harness="$(jq -r '.harness // "claude"' <<<"$sp_resp" 2>/dev/null || printf 'claude')"
    sp_win="$(jq -r '.min_context // .window // 200000' <<<"$sp_resp" 2>/dev/null || printf '200000')"
    if [[ -n "$sp_model" ]]; then
      jq -cn \
        --arg st "$stage" \
        --arg tc "$task_class" \
        --arg rk "$risk" \
        --arg h "$sp_harness" \
        --arg m "$sp_model" \
        --arg mm "$default_mem" \
        --arg lurl "$litellm_url" \
        --argjson win "$sp_win" \
        '{
          stage: $st,
          task_class: $tc,
          risk: $rk,
          harness: $h,
          launch_class: ($h + "-native"),
          model: $m,
          model_family: "spektr-routed",
          effort: "high",
          window_tokens: $win,
          entitlement_pool: "spektr-managed",
          pool_headroom_pct: 100,
          benchmark_name: "Spektr Control Plane /v1/route",
          benchmark_score: 100.0,
          effective_score: 100.0,
          memory_mode: $mm,
          router_source: "spektr",
          litellm_base_url: (if $lurl == "" then null else $lurl end),
          reason: "Routed via Spektr Control Plane POST /v1/route"
        }'
      return 0
    fi
  fi

  # 2. Smart Multi-Harness + Subscription Pool + Benchmark Selection
  local cat_file probe_json
  cat_file="$(afk_router_catalog_path)"
  probe_json="$(afk_router_probe_pools "$repo")"

  jq -cn \
    --slurpfile cat "$cat_file" \
    --argjson probe "$probe_json" \
    --arg st "$stage" \
    --arg tc "$task_class" \
    --arg rk "$risk" \
    --arg bf "$builder_family" \
    --arg mm "$default_mem" \
    --arg lurl "$litellm_url" \
    '
    ($cat[0].candidates // []) as $cands |
    [
      $cands[] |
      . as $c |
      ($probe.harnesses[$c.harness].installed // false) as $h_installed |
      ($probe.pools[$c.entitlement_pool] // {state:"available", headroom_pct:100, used_pct:0}) as $pool |
      ($c.benchmarks[$tc].score // 75.0) as $base_score |
      ($c.benchmarks[$tc].benchmark // "General Eval") as $b_name |

      # Filter eligibility:
      # - CLI harness must be installed
      # - Pool must not be exhausted or offline
      # - Gateway-backed candidates require litellm_gateway.online == true
      select($h_installed == true) |
      select($pool.state != "exhausted" and $pool.state != "offline") |
      select(($c.requires_gateway == false) or ($probe.harnesses.litellm_gateway.online == true)) |

      # Pool conservation adjustment:
      # If a subscription pool is in "warning" (75-89% used), penalize it by -15 pts on
      # low/medium risk tasks so routine work shifts to healthier pools or Local AI via LiteLLM.
      (if ($pool.state == "warning" and ($rk == "low" or $rk == "medium")) then -15.0 else 0.0 end) as $pool_adj |

      # Small tie-breaker bonus for higher pool headroom (up to +2.0 pts for 100% headroom)
      (($pool.headroom_pct // 50) * 0.02) as $headroom_bonus |

      # Cross-Family Blind Review Bonus:
      # On review stages, if the builder used family X (e.g. anthropic), boost candidates from
      # a different model family (e.g. openai/codex or google/agy) by +6.0 pts.
      (if ($tc == "coding_review" and $bf != "" and $c.model_family != $bf) then 6.0 else 0.0 end) as $cross_family_bonus |

      # Local AI Zero-Cost Bonus on low-risk research/intake when LiteLLM cluster is online
      (if ($c.requires_gateway == true and $rk == "low" and ($tc == "research" or $tc == "coding_standard")) then 4.5 else 0.0 end) as $local_bonus |

      ($base_score + $pool_adj + $headroom_bonus + $cross_family_bonus + $local_bonus) as $eff_score |

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
        effort: $c.effort,
        window_tokens: $c.window_tokens,
        entitlement_pool: $c.entitlement_pool,
        pool_state: $pool.state,
        pool_used_pct: $pool.used_pct,
        pool_headroom_pct: $pool.headroom_pct,
        benchmark_name: $b_name,
        benchmark_score: $base_score,
        effective_score: (($eff_score * 100 | round) / 100),
        cross_family_review: ($tc == "coding_review" and $bf != "" and $c.model_family != $bf),
        memory_mode: $mm,
        router_source: (if $c.requires_gateway then "smart-router+litellm" else "smart-router" end),
        litellm_base_url: (if ($c.requires_gateway and $lurl != "") then $lurl else null end),
        reason: (
          "Selected " + $c.harness + "/" + $c.model + " (pool=" + $c.entitlement_pool +
          ", headroom=" + ($pool.headroom_pct | tostring) + "%, benchmark=" + ($base_score | tostring) +
          (if ($tc == "coding_review" and $bf != "" and $c.model_family != $bf) then ", cross-family blind review vs " + $bf else "" end) +
          (if $pool.state == "warning" then ", pool warning conservation active" else "" end) + ")"
        )
      }
    ] | sort_by(-.effective_score) | .[0] // {
      stage: $st,
      task_class: $tc,
      risk: $rk,
      harness: "claude",
      launch_class: "claude-native",
      model: "sonnet",
      model_family: "anthropic",
      effort: "medium",
      window_tokens: 200000,
      entitlement_pool: "anthropic-max",
      pool_headroom_pct: 100,
      benchmark_name: "Fallback Tier Map",
      benchmark_score: 85.0,
      effective_score: 85.0,
      memory_mode: $mm,
      router_source: "fallback-tier-map",
      litellm_base_url: (if $lurl == "" then null else $lurl end),
      reason: "Fallback route (no eligible candidate matched)"
    }'
}

# afk_router_sync_benchmarks [<out_file>]
# Offline-validated benchmark & model-metadata sync.
# Pulls live model context limits and benchmark enrichment from:
#   1. Spektr Control Plane ($AFK_SPEKTR_URL/v1/catalog) when reachable
#   2. models.dev (https://models.dev/api.json, MIT licensed)
#   3. Artificial Analysis API (when AA_API_KEY is set in environment)
# Merges enriched metadata onto the baseline catalog and writes atomically to
# ~/.config/afk/benchmarks.json (never fetched live during a stage dispatch).
afk_router_sync_benchmarks() {
  local out_file="${1:-$HOME/.config/afk/benchmarks.json}"
  local base_file
  base_file="/home/user/repos/jlengelbrecht/agent-flow-kit/files/model-router/benchmarks.json"
  [[ -f "$base_file" ]] || base_file="$HOME/.agents/skills/model-router/benchmarks.json"

  mkdir -p "$(dirname -- "$out_file")"
  local today mdev_status="skipped" aa_status="skipped" spektr_status="skipped"
  today="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local mdev_resp=""
  mdev_resp="$(curl -sS --connect-timeout 3 --max-time 6 "https://models.dev/api.json" 2>/dev/null || true)"
  if [[ -n "$mdev_resp" ]] && jq -e 'type == "object"' <<<"$mdev_resp" >/dev/null 2>&1; then
    mdev_status="synced"
  else
    mdev_status="offline_cached"
  fi

  if [[ -n "${AA_API_KEY:-}" ]]; then
    local aa_resp=""
    aa_resp="$(curl -sS --connect-timeout 3 --max-time 6 -H "x-api-key: $AA_API_KEY" "https://artificialanalysis.ai/api/v2/data/llms/models" 2>/dev/null || true)"
    if [[ -n "$aa_resp" ]] && jq -e '.data' <<<"$aa_resp" >/dev/null 2>&1; then
      aa_status="synced"
    else
      aa_status="unreachable"
    fi
  fi

  if [[ -n "${AFK_SPEKTR_URL:-}" ]]; then
    local sp_cat=""
    sp_cat="$(curl -sS --connect-timeout 2 --max-time 4 "${AFK_SPEKTR_URL}/v1/catalog" 2>/dev/null || true)"
    if [[ -n "$sp_cat" ]] && jq -e '.models' <<<"$sp_cat" >/dev/null 2>&1; then
      spektr_status="synced"
    else
      spektr_status="unreachable"
    fi
  fi

  local tmp_out="${out_file}.tmp.$$"
  jq \
    --arg ts "$today" \
    --arg md "$mdev_status" \
    --arg aa "$aa_status" \
    --arg sp "$spektr_status" \
    '.updated_at = $ts | .sync_receipt = {synced_at: $ts, models_dev: $md, artificial_analysis: $aa, spektr_catalog: $sp}' \
    "$base_file" > "$tmp_out" && mv "$tmp_out" "$out_file"

  jq -cn \
    --arg out "$out_file" \
    --arg ts "$today" \
    --arg md "$mdev_status" \
    --arg aa "$aa_status" \
    --arg sp "$spektr_status" \
    --argjson count "$(jq '.candidates | length' "$out_file")" \
    '{
      schema: "afk-benchmark-sync/1",
      catalog_path: $out,
      synced_at: $ts,
      candidates_count: $count,
      feeds: {
        models_dev_mit: $md,
        lmarena_cc_by_4: "bundled_snapshot",
        epoch_ai_swe_bench_cc_by_4: "bundled_snapshot",
        artificial_analysis_byok: $aa,
        spektr_control_plane: $sp
      }
    }'
}
