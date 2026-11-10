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
  printf '%s\n' "/home/devbox/repos/jlengelbrecht/agent-flow-kit/files/model-router/benchmarks.json"
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
# Discovers installed CLI binaries and LiteLLM gateway availability.
afk_router_discover_harnesses() {
  local litellm_url="${1:-${AFK_LITELLM_BASE_URL:-}}"
  local claude_bin="" codex_bin="" agy_bin="" opencode_bin=""
  if [[ -n "${AFK_ROUTER_HARNESS_LIST:-}" ]]; then
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

  local harnesses_json
  harnesses_json="$(afk_router_discover_harnesses "$litellm_url")"

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
    def calc_pool($pid; $raw_sessions; $is_local):
      ($cat[0].entitlement_pools[$pid] // {}) as $meta |
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
        active_sessions_5h: $raw_sessions
      };

    {
      schema: "afk-router-pools/2",
      harnesses: $h,
      pools: {
        "anthropic-max":    calc_pool("anthropic-max"; $c5; false),
        "openai-plus":      calc_pool("openai-plus"; $x5; false),
        "antigravity-pool": calc_pool("antigravity-pool"; $a5; false),
        "xai-grok":         calc_pool("xai-grok"; $o5; false),
        "litellm-local":    calc_pool("litellm-local"; 0; true)
      }
    }'
}

# afk_router_select_candidate <repo> <stage> <risk> [<builder_family>]
# Evaluates public benchmark scores + pool size/headroom to pick the winning
# (harness, launch_class, model, entitlement_pool) for <stage>.
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

  local litellm_url
  litellm_url="${AFK_LITELLM_BASE_URL:-$(jq -r '.router.litellm_base_url // empty' <<<"$cfg" 2>/dev/null)}"

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
      ($probe.pools[$c.entitlement_pool] // {state:"available", headroom_pct:100, used_pct:0, capacity_5h:50, remaining_units_5h:50}) as $pool |
      ($c.benchmarks[$tc].score // 75.0) as $base_score |
      ($c.benchmarks[$tc].benchmark // "Public Leaderboard Aggregate") as $b_name |

      # Eligibility gates:
      # 1. Harness binary installed on host
      # 2. Pool not exhausted (>=90%) or offline
      # 3. Gateway candidates require LiteLLM gateway to be online
      select($h_installed == true) |
      select($pool.state != "exhausted" and $pool.state != "offline") |
      select(($c.requires_gateway == false) or ($probe.harnesses.litellm_gateway.online == true)) |

      # Pool conservation adjustment:
      # When a subscription pool enters warning (75-89% used), penalize it by -15 pts on
      # low/medium risk tasks so work flows to larger/healthier pools or Local AI via LiteLLM.
      (if ($pool.state == "warning" and ($rk == "low" or $rk == "medium")) then -15.0 else 0.0 end) as $pool_adj |

      # Pool headroom + pool size bonus:
      # Rewards pools with higher % free headroom (up to +2.0) and larger remaining unit capacity (up to +1.5)
      (($pool.headroom_pct // 50) * 0.02) as $headroom_bonus |
      ((($pool.remaining_units_5h // 25) | if . > 60 then 60 else . end) * 0.025) as $capacity_bonus |

      # Cross-Family Blind Review Bonus:
      # On code review stages, if family X (e.g. anthropic) built the code, boost independent
      # model families (e.g. openai/codex or google/agy) by +6.0 pts.
      (if ($tc == "coding_review" and $bf != "" and $c.model_family != $bf) then 6.0 else 0.0 end) as $cross_family_bonus |

      # Local AI Zero-Cost Bonus on low-risk tasks when LiteLLM cluster is online
      (if ($c.requires_gateway == true and $rk == "low" and ($tc == "research" or $tc == "coding_standard")) then 6.5 else 0.0 end) as $local_bonus |

      ($base_score + $pool_adj + $headroom_bonus + $capacity_bonus + $cross_family_bonus + $local_bonus) as $eff_score |

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
        pool_capacity_5h: $pool.capacity_5h,
        pool_remaining_5h: $pool.remaining_units_5h,
        pool_used_pct: $pool.used_pct,
        pool_headroom_pct: $pool.headroom_pct,
        benchmark_name: $b_name,
        benchmark_score: $base_score,
        effective_score: (($eff_score * 100 | round) / 100),
        cross_family_review: ($tc == "coding_review" and $bf != "" and $c.model_family != $bf),
        memory_mode: $mm,
        router_source: (if $c.requires_gateway then "afk-benchmarks+litellm" else "afk-benchmarks" end),
        litellm_base_url: (if ($c.requires_gateway and $lurl != "") then $lurl else null end),
        reason: (
          "Selected " + $c.harness + "/" + $c.model + " [" + $c.canonical_model + "] " +
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
    }'
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
  local base_file="/home/devbox/repos/jlengelbrecht/agent-flow-kit/files/model-router/benchmarks.json"
  [[ -f "$base_file" ]] || base_file="$HOME/.agents/skills/model-router/benchmarks.json"

  mkdir -p "$(dirname -- "$out_file")"
  local today
  today="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local arena_agent="{}" arena_webdev="{}" arena_text="{}" swebench="{}" mdev="{}" aa_data="{}"
  local st_agent="offline" st_webdev="offline" st_text="offline" st_swe="offline" st_mdev="offline" st_aa="no_key"

  local raw
  raw="$(curl -sS --connect-timeout 3 --max-time 8 "https://datasets-server.huggingface.co/rows?dataset=lmarena-ai%2Fleaderboard-dataset&config=agent&split=latest&offset=0&length=50" 2>/dev/null || true)"
  if [[ -n "$raw" ]] && jq -e '.rows | length > 0' <<<"$raw" >/dev/null 2>&1; then
    arena_agent="$(jq -c '[.rows[].row | {model_name, rank, score, date: .leaderboard_publish_date}]' <<<"$raw")"
    st_agent="live_synced ($(jq -r '.[0].date // "latest"' <<<"$arena_agent"))"
  fi

  raw="$(curl -sS --connect-timeout 3 --max-time 8 "https://datasets-server.huggingface.co/rows?dataset=lmarena-ai%2Fleaderboard-dataset&config=webdev&split=latest&offset=0&length=50" 2>/dev/null || true)"
  if [[ -n "$raw" ]] && jq -e '.rows | length > 0' <<<"$raw" >/dev/null 2>&1; then
    arena_webdev="$(jq -c '[.rows[].row | {model_name, rank, rating, date: .leaderboard_publish_date}]' <<<"$raw")"
    st_webdev="live_synced ($(jq -r '.[0].date // "latest"' <<<"$arena_webdev"))"
  fi

  raw="$(curl -sS --connect-timeout 3 --max-time 8 "https://datasets-server.huggingface.co/rows?dataset=lmarena-ai%2Fleaderboard-dataset&config=text&split=latest&offset=0&length=50" 2>/dev/null || true)"
  if [[ -n "$raw" ]] && jq -e '.rows | length > 0' <<<"$raw" >/dev/null 2>&1; then
    arena_text="$(jq -c '[.rows[].row | {model_name, rank, rating}]' <<<"$raw")"
    st_text="live_synced"
  fi

  raw="$(curl -sS --connect-timeout 3 --max-time 8 "https://raw.githubusercontent.com/SWE-bench/swe-bench.github.io/master/data/leaderboards.json" 2>/dev/null || true)"
  if [[ -n "$raw" ]] && jq -e '.leaderboards' <<<"$raw" >/dev/null 2>&1; then
    swebench="$(jq -c '[.leaderboards[] | select(.name=="Verified") | .results[] | {name, resolved}] | .[0:50]' <<<"$raw" 2>/dev/null || printf '[]')"
    st_swe="live_synced"
  fi

  raw="$(curl -sS --connect-timeout 3 --max-time 8 "https://models.dev/api.json" 2>/dev/null || true)"
  if [[ -n "$raw" ]] && jq -e 'type == "object"' <<<"$raw" >/dev/null 2>&1; then
    mdev="$(jq -c 'with_entries(.value = (.value.models // {} | with_entries(.value = (.value.limit.context // null))))' <<<"$raw" 2>/dev/null || printf '{}')"
    st_mdev="live_synced"
  fi

  local aa_key="${ARTIFICIAL_ANALYSIS_API_KEY:-${AA_API_KEY:-}}"
  if [[ -n "$aa_key" ]]; then
    raw="$(curl -sS --connect-timeout 3 --max-time 8 -H "x-api-key: $aa_key" "https://artificialanalysis.ai/api/v2/data/llms/models" 2>/dev/null || true)"
    if [[ -n "$raw" ]] && jq -e '.data' <<<"$raw" >/dev/null 2>&1; then
      aa_data="$(jq -c '[.data[] | {slug, name, coding: .evaluations.artificial_analysis_coding_index, intelligence: .evaluations.artificial_analysis_intelligence_index}]' <<<"$raw")"
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
    --argjson ag "${arena_agent:-[]}" \
    --argjson wd "${arena_webdev:-[]}" \
    --argjson tx "${arena_text:-[]}" \
    --argjson md "${mdev:-{}}" \
    --argjson aa "${aa_data:-[]}" \
    '
    .updated_at = $ts |
    .sync_receipt = {
      synced_at: $ts,
      lmarena_agent: $sa,
      lmarena_webdev: $sw,
      lmarena_text: $stx,
      swe_bench_official: $ss,
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
