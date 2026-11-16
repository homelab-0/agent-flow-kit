#!/usr/bin/env bash
# afk-smart-router.sh — Multi-Harness, Pool-Capacity, Effort-Escalating &
# Public-Benchmark Smart Router (with Frontier & Security Specialist Routing)
#
# Evaluates which installed CLI harness + subscription pool (or LiteLLM gateway)
# should execute each Software Factory or BMAD stage based strictly on:
#   1. Installed & authenticated harnesses on the host (claude, codex, agy, grok,
#      opencode, pi, devin + LiteLLM gateway)
#   2. Subscription pool size (capacity), live 5h/7d usage headroom, and scoped
#      frontier sub-quotas (e.g., Anthropic `seven_day:fable`)
#   3. Auto-refreshed public benchmark leaderboards (LMArena Agent/WebDev/Text,
#      SWE-bench, Artificial Analysis API, and models.dev context limits)
#   4. Task class, BMAD persona complexity floors (`pm` PRD/epics, `architect`),
#      frontier escalation (`Fable`), and cybersecurity specialist models
#      (`Claude Mythos`, `OpenAI Daybreak Blue`)
#   5. Dynamic reasoning effort selection & automatic mid-task effort escalation
#      across retry rounds (`medium` -> `high` -> `xhigh` -> `max`)
#   6. Independent Cross-Family Blind Review (ensuring reviewers use a different
#      model family than the builder whenever available)

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
  local user_cat="$HOME/.config/afk/benchmarks.json"
  local repo_cat=""
  if [[ -f "${AFK_REPO_ROOT:-}/files/model-router/benchmarks.json" ]]; then
    repo_cat="${AFK_REPO_ROOT}/files/model-router/benchmarks.json"
  elif [[ -f "$(dirname -- "${BASH_SOURCE[0]}")/../files/model-router/benchmarks.json" ]]; then
    repo_cat="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/files/model-router/benchmarks.json"
  elif [[ -f "$HOME/.agents/skills/model-router/benchmarks.json" ]]; then
    repo_cat="$HOME/.agents/skills/model-router/benchmarks.json"
  fi
  if [[ -f "$user_cat" ]]; then
    # Prefer repo catalog if user cache is from an older schema lacking grok/fable/mythos/daybreak
    if [[ -n "$repo_cat" && -f "$repo_cat" ]]; then
      local u_schema
      u_schema="$(jq -r '.schema // ""' "$user_cat" 2>/dev/null || true)"
      if [[ "$u_schema" != "afk-benchmark-catalog/3" ]]; then
        printf '%s\n' "$repo_cat"
        return 0
      fi
    fi
    printf '%s\n' "$user_cat"
    return 0
  fi
  if [[ -n "$repo_cat" && -f "$repo_cat" ]]; then
    printf '%s\n' "$repo_cat"
    return 0
  fi
  # No catalog anywhere. Name the user path so the caller's error says where
  # one is expected; a caller must check the file exists before reading it.
  printf '%s\n' "$user_cat"
  return 1
}

afk_router_signals_path() {
  printf '%s\n' "${AFK_ROUTER_SIGNALS_FILE:-$HOME/.config/afk/pool-signals.json}"
}

# _afk_router_write_json <dest>   (JSON on stdin)
# Writes through a uniquely named temp file in the destination directory and
# renames it into place. `$$` is the same in every background subshell of one
# poll pass, so a `.tmp.$$` name is shared by concurrent jobs; mktemp is not.
# Empty or invalid JSON never replaces the destination and leaves no temp file.
# The file keeps the mode it had; a new one gets <mode> (default 644). mktemp
# alone would make every rewritten file owner-only.
_afk_router_write_json() {
  local dest="$1" mode="${2:-644}" tmp cur_mode=""
  mkdir -p "$(dirname -- "$dest")" 2>/dev/null || return 1
  tmp="$(mktemp "${dest}.tmp.XXXXXX" 2>/dev/null)" || return 1
  if [[ -e "$dest" ]]; then
    cur_mode="$(stat -c %a "$dest" 2>/dev/null || stat -f %Lp "$dest" 2>/dev/null || true)"
    [[ "$cur_mode" =~ ^[0-7]{3,4}$ ]] && mode="$cur_mode"
  fi
  if cat > "$tmp" 2>/dev/null && [[ -s "$tmp" ]] && jq -e . "$tmp" >/dev/null 2>&1 \
     && chmod "$mode" "$tmp" 2>/dev/null && mv -f -- "$tmp" "$dest" 2>/dev/null; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# _afk_router_lock <lockdir> [<wait_tenths>] [<stale_sec>]
# A short mkdir lock for the read-modify-write of a small state file. Writers
# hold it for milliseconds, so a lock older than <stale_sec> (default 10)
# belongs to a killed writer. Taking over is itself serialized: two waiters
# that both judge the same lock stale must not both remove it, or the slower
# one removes the faster one's fresh lock. The wait (default 30s) is longer
# than the stale age, so a waiter always outlives a dead holder.
AFK_ROUTER_LOCK_TOKEN=""
_afk_router_lock_mtime() {
  local mt
  mt="$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true)"
  [[ "$mt" =~ ^[0-9]+$ ]] && printf '%s' "$mt"
}
_afk_router_lock() {
  local lockdir="$1" tries="${2:-300}" stale="${3:-10}" i=0 now mt token
  token="$BASHPID.$RANDOM$RANDOM"
  while ! mkdir "$lockdir" 2>/dev/null; do
    # mkdir also fails on a read-only or missing parent. Only an existing
    # lock is worth waiting for.
    [[ -d "$lockdir" ]] || { i=$(( i + 10 )); (( i < tries )) || return 1; sleep 0.1; continue; }
    now="$(date -u +%s)"
    mt="$(_afk_router_lock_mtime "$lockdir")"
    # A lock with no readable time, or one dated in the future, is judged by
    # its age from now on: neither may hold the file for good.
    if [[ -n "$mt" ]] && { (( now - mt >= stale )) || (( mt > now + 60 )); }; then
      if mkdir "$lockdir.reap" 2>/dev/null; then
        mt="$(_afk_router_lock_mtime "$lockdir")"
        if [[ -n "$mt" ]] && { (( now - mt >= stale )) || (( mt > now + 60 )); }; then
          rm -rf -- "$lockdir" 2>/dev/null || true
        fi
        rmdir "$lockdir.reap" 2>/dev/null || true
        continue
      fi
      # Another waiter is taking over; a reap lock left by a killed waiter is
      # cleared once it is stale itself.
      mt="$(_afk_router_lock_mtime "$lockdir.reap")"
      [[ -n "$mt" ]] && (( now - mt >= stale )) && rmdir "$lockdir.reap" 2>/dev/null
    fi
    i=$(( i + 1 ))
    (( i < tries )) || return 1
    sleep 0.1
  done
  printf '%s\n' "$token" > "$lockdir/owner" 2>/dev/null || true
  AFK_ROUTER_LOCK_TOKEN="$token"
  return 0
}
# Releases the lock only for the writer that holds it.
_afk_router_unlock() {
  local held=""
  held="$(cat -- "$1/owner" 2>/dev/null || true)"
  if [[ -z "$held" || "$held" == "${AFK_ROUTER_LOCK_TOKEN:-}" ]]; then
    rm -f -- "$1/owner" 2>/dev/null
    rmdir "$1" 2>/dev/null || true
  fi
  AFK_ROUTER_LOCK_TOKEN=""
}

# Portable file mtime epoch (Linux GNU stat -c %Y and macOS BSD stat -f %m)
_afk_router_file_mtime() {
  local f="$1" mt
  [[ -f "$f" ]] || { printf '0\n'; return 0; }
  mt="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || printf '0')"
  [[ "$mt" =~ ^[0-9]+$ ]] || mt=0
  printf '%s\n' "$mt"
}

# afk_router_ensure_fresh_benchmarks [<ttl_sec>]
# Refreshes ~/.config/afk/benchmarks.json before live dispatch when it is
# missing, on an older schema, or older than the TTL (default 24h). Skipped in
# hermetic test modes.
#
# A sync that fails, or finds no leaderboard feed reachable, leaves the catalog
# as it was, so its age alone would trigger another sync on every route. An
# attempt marker throttles retries (default 15 minutes) and keeps the jobs of
# one poll pass from all syncing at once.
# shellcheck disable=SC2120  # the TTL argument is for callers outside this file
afk_router_ensure_fresh_benchmarks() {
  local ttl="${1:-${AFK_BENCHMARK_TTL_SEC:-86400}}"
  if [[ -n "${AFK_ROUTER_BENCHMARKS_FILE:-}" || -n "${AFK_ROUTER_HARNESS_LIST:-}" || -n "${AFK_FACTORY_AGENT_RUNNER:-}" || -n "${AFK_CURL_BIN:-}" || "${AFK_SKIP_BENCHMARK_AUTOSYNC:-0}" == "1" ]]; then
    return 0
  fi
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=86400
  local retry="${AFK_BENCHMARK_RETRY_SEC:-900}"
  [[ "$retry" =~ ^[0-9]+$ ]] || retry=900
  local user_cat="$HOME/.config/afk/benchmarks.json"
  local marker="${user_cat}.sync-attempt"
  local now_ep mtime schema="" attempt_at measured=0 age
  now_ep="$(date -u +%s)"
  mtime="$(_afk_router_file_mtime "$user_cat")"
  if [[ -f "$user_cat" ]]; then
    schema="$(jq -r '.schema // ""' "$user_cat" 2>/dev/null || true)"
    measured="$(jq -r '.sync_receipt.live_scores // 0' "$user_cat" 2>/dev/null || printf '0')"
    [[ "$measured" =~ ^[0-9]+$ ]] || measured=0
  fi
  # A file dated in the future (a volume restored from a skewed clock) is
  # treated as stale, not as fresh until the clock catches up.
  age=$(( now_ep - mtime ))
  # A catalog with no measured score (the first sync found no board) is
  # retried on the retry spacing, not left for a full day.
  if [[ -f "$user_cat" && "$schema" == "afk-benchmark-catalog/3" ]] && (( measured > 0 && age >= 0 && age < ttl )); then
    return 0
  fi
  attempt_at="$(_afk_router_file_mtime "$marker")"
  age=$(( now_ep - attempt_at ))
  if (( age >= 0 && age < retry )); then
    return 0
  fi
  mkdir -p "$(dirname -- "$marker")" 2>/dev/null || return 0
  # One job syncs; the others of the same poll pass carry on with the catalog
  # they have.
  mkdir "$marker.lock" 2>/dev/null || {
    local lmt; lmt="$(_afk_router_lock_mtime "$marker.lock")"
    [[ -n "$lmt" ]] && (( now_ep - lmt > 300 )) && rmdir "$marker.lock" 2>/dev/null
    return 0
  }
  # Another job may have finished a sync between the check above and taking
  # the lock; look again, with the time now, before starting another.
  now_ep="$(date -u +%s)"
  attempt_at="$(_afk_router_file_mtime "$marker")"
  age=$(( now_ep - attempt_at ))
  if (( age >= 0 && age < retry )); then
    rmdir "$marker.lock" 2>/dev/null || true
    return 0
  fi
  : > "$marker" 2>/dev/null
  afk_router_sync_benchmarks "$user_cat" >/dev/null 2>&1 || true
  rmdir "$marker.lock" 2>/dev/null || true
  return 0
}

# afk_router_stage_to_task_class <stage> <risk> [<role>] [<surfaces>] [<round>]
afk_router_stage_to_task_class() {
  local stage="$1" risk="${2:-low}" role="${3:-}" surfaces="${4:-}" round="${5:-1}"
  local norm_surf
  norm_surf=",$(printf '%s' "$surfaces" | tr '[:upper:]' '[:lower:]' | tr -d ' '), "
  norm_surf="${norm_surf% }"

  # 1. Explicit security stages, roles, or security-flagged surfaces
  if [[ "$stage" == "review-security" || "$stage" == security* || "$stage" == threat* || "$role" == "security" ]]; then
    printf 'security\n'
    return 0
  fi
  if [[ "$norm_surf" =~ ,(security|auth|crypto|iam|cve|vuln|pentest), ]] && [[ "$stage" == "spec" || "$stage" == "build" ]]; then
    printf 'security\n'
    return 0
  fi

  # 2. Critical frontier synthesis or Round 3+ high-risk escalation
  if [[ "$risk" == "critical" ]] && [[ "$stage" =~ ^(spec|arch.*|prd|epics|stories|build)$ ]]; then
    printf 'frontier_synthesis\n'
    return 0
  fi
  if [[ "$round" =~ ^[0-9]+$ ]] && (( round >= 3 )) && [[ "$risk" == "high" ]] && [[ "$stage" =~ ^(spec|arch.*|build)$ ]]; then
    printf 'frontier_synthesis\n'
    return 0
  fi

  # 3. Planning artifacts. A low-risk spec with a small diff is an ordinary
  #    edit, not an architecture synthesis, so it does not take the frontier floor.
  local diff_lines="${6:-0}"
  [[ "$diff_lines" =~ ^[0-9]+$ ]] || diff_lines=0
  case "$stage" in
    prd|epics|stories|product-brief|correct-course|arch*)
      printf 'architecture\n'
      return 0
      ;;
    spec)
      if [[ "$risk" == "low" ]] && (( diff_lines < 80 )); then
        printf 'coding_standard\n'
      else
        printf 'architecture\n'
      fi
      return 0
      ;;
  esac
  if [[ "$role" == "pm" || "$role" == "architect" ]] && [[ "$stage" != "intake" && "$stage" != "research" && "$stage" != review* ]]; then
    printf 'architecture\n'
    return 0
  fi

  # 4. Standard lifecycle stages
  case "$stage" in
    intake|research)
      printf 'research\n' ;;
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

# Which harness binaries answer `--version`, remembered for a few minutes.
# Every route decision used to start all seven CLIs to ask, several seconds
# each time, and a job makes a route decision per stage and per retry.
_afk_router_bin_cache_path() {
  printf '%s\n' "${AFK_ROUTER_BIN_CACHE_FILE:-$HOME/.config/afk/harness-bin-cache.json}"
}
_afk_router_verify_binary() {
  local name="$1" cand="" cache ttl="${AFK_ROUTER_BIN_CACHE_SEC:-300}" now hit="" cur="{}" fail_ttl="${AFK_ROUTER_BIN_FAIL_CACHE_SEC:-30}"
  if declare -F _afk_harness_locate_bin >/dev/null 2>&1; then
    cand="$(_afk_harness_locate_bin "$name" || true)"
  else
    cand="$(command -v "$name" 2>/dev/null || true)"
  fi
  [[ -n "$cand" ]] || { printf ''; return 0; }
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=300
  cache="$(_afk_router_bin_cache_path)"
  now="$(date -u +%s)"
  if (( ttl > 0 )) && [[ -f "$cache" ]]; then
    # Keyed by path and the binary's mtime: an updated or replaced CLI is
    # checked again at once.
    # A failure is remembered only briefly: a CLI caught mid-update must not
    # drop out of routing for the full cache time.
    [[ "$fail_ttl" =~ ^[0-9]+$ ]] || fail_ttl=30
    hit="$(jq -r --arg p "$cand" --argjson now "$now" --argjson ttl "$ttl" --argjson fttl "$fail_ttl" --arg mt "$(_afk_router_file_mtime "$cand")" \
      '(.[$p] // null) | if . != null and (.mtime == $mt) and (($now - (.at // 0)) < (if .ok then $ttl else $fttl end)) then (.ok | tostring) else empty end' "$cache" 2>/dev/null || true)"
  fi
  if [[ -z "$hit" ]]; then
    if "$cand" --version >/dev/null 2>&1 </dev/null; then hit=true; else hit=false; fi
    # Locked so concurrent jobs add to the cache instead of replacing it. A
    # lock that cannot be had is not worth waiting for: the cache is skipped.
    if (( ttl > 0 )) && _afk_router_lock "$cache.lock" 20; then
      [[ -f "$cache" ]] && cur="$(cat -- "$cache" 2>/dev/null || printf '{}')"
      jq -e 'type == "object"' <<<"$cur" >/dev/null 2>&1 || cur="{}"
      jq -c --arg p "$cand" --argjson now "$now" --arg mt "$(_afk_router_file_mtime "$cand")" --argjson ok "$hit" \
        '.[$p] = {ok: $ok, at: $now, mtime: $mt}' <<<"$cur" 2>/dev/null | _afk_router_write_json "$cache" 2>/dev/null || true
      _afk_router_unlock "$cache.lock"
    fi
  fi
  if [[ "$hit" == true ]]; then
    printf '%s' "$cand"
    return 0
  fi
  printf ''
}

# afk_router_discover_harnesses [<litellm_url>]
# Discovers installed & executable CLI binaries and LiteLLM gateway availability.
afk_router_discover_harnesses() {
  local litellm_url="${1:-${AFK_LITELLM_BASE_URL:-}}"
  local claude_bin="" codex_bin="" agy_bin="" grok_bin="" opencode_bin="" pi_bin="" devin_bin=""
  local codex_note=""
  if [[ -n "${AFK_ROUTER_HARNESS_LIST:-}" ]]; then
    local list=",${AFK_ROUTER_HARNESS_LIST},"
    [[ "$list" == *",claude,"* ]] && claude_bin="/mock/bin/claude"
    [[ "$list" == *",codex,"* ]] && codex_bin="/mock/bin/codex"
    [[ "$list" == *",agy,"* ]] && agy_bin="/mock/bin/agy"
    [[ "$list" == *",grok,"* ]] && grok_bin="/mock/bin/grok"
    [[ "$list" == *",opencode,"* ]] && opencode_bin="/mock/bin/opencode"
    [[ "$list" == *",pi,"* ]] && pi_bin="/mock/bin/pi"
    [[ "$list" == *",devin,"* ]] && devin_bin="/mock/bin/devin"
  else
    claude_bin="$(_afk_router_verify_binary claude)"
    codex_bin="$(_afk_router_verify_binary codex)"
    local raw_codex=""
    raw_codex="$(_afk_harness_locate_bin codex 2>/dev/null || command -v codex 2>/dev/null || true)"
    if [[ -z "$codex_bin" && -n "$raw_codex" ]]; then
      codex_note="broken_binary ($raw_codex failed --version)"
    fi
    agy_bin="$(_afk_router_verify_binary agy)"
    grok_bin="$(_afk_router_verify_binary grok)"
    opencode_bin="$(_afk_router_verify_binary opencode)"
    pi_bin="$(_afk_router_verify_binary pi)"
    devin_bin="$(_afk_router_verify_binary devin)"
  fi

  local litellm_online=false litellm_models="[]"
  if [[ -n "$litellm_url" ]]; then
    if [[ "${AFK_ROUTER_LITELLM_ASSUME_ONLINE:-0}" == "1" ]]; then
      litellm_online=true
      litellm_models="${AFK_ROUTER_LITELLM_MODELS:-[\"qwen36-27b\"]}"
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
    --arg gb "$grok_bin" \
    --arg ob "$opencode_bin" \
    --arg pb "$pi_bin" \
    --arg db "$devin_bin" \
    --arg lurl "$litellm_url" \
    --argjson lon "$litellm_online" \
    --argjson lmods "$litellm_models" \
    '{
      claude:   {installed: ($cb != ""), binary: (if $cb == "" then null else $cb end), health: (if $cb != "" then "ok" else "missing" end)},
      codex:    {installed: ($xb != ""), binary: (if $xb == "" then null else $xb end), health: (if $xb != "" then "ok" elif $xn != "" then $xn else "missing" end)},
      agy:      {installed: ($ab != ""), binary: (if $ab == "" then null else $ab end), health: (if $ab != "" then "ok" else "missing" end)},
      grok:     {installed: ($gb != ""), binary: (if $gb == "" then null else $gb end), health: (if $gb != "" then "ok" else "missing" end)},
      opencode: {installed: ($ob != ""), binary: (if $ob == "" then null else $ob end), health: (if $ob != "" then "ok" else "missing" end)},
      pi:       {installed: ($pb != ""), binary: (if $pb == "" then null else $pb end), health: (if $pb != "" then "ok" else "missing" end)},
      devin:    {installed: ($db != ""), binary: (if $db == "" then null else $db end), health: (if $db != "" then "ok" else "missing" end)},
      litellm_gateway: {
        configured: ($lurl != ""),
        base_url: (if $lurl == "" then null else $lurl end),
        online: $lon,
        models: $lmods
      }
    }'
}

# afk_router_mark_pool_degraded <pool_id> [<reason>]
# Marks an entitlement pool degraded in pool-signals.json with severity-aware TTLs:
#   - Hard auth revocation (401/token_revoked): 24h TTL (auto-cleared on re-auth mtime)
#   - Rate limit / quota exhaustion (429/quota/out_of_credits): 1h cooldown TTL
#   - Transient stage timeout / empty output: 15m (900s) cooldown TTL
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
  if [[ "$lreason" =~ (401|unauthorized|token_revoked|invalidated[[:space:]]+oauth|refresh[[:space:]]+token|not[[:space:]]+logged[[:space:]]+in) ]]; then
    kind="auth"
    ttl_sec=86400
    used_val=100
  elif [[ "$lreason" =~ (429|rate_limit|rate[[:space:]]+limit|quota|out_of_credits|spend_limit|exhausted) ]]; then
    kind="quota"
    ttl_sec=3600
    used_val=100
  fi
  # Read under the lock: several jobs run at once and each rewrites the whole
  # file, so an unlocked read would drop a peer's mark.
  local locked=false rc=0
  _afk_router_lock "${sig_file}.lock" && locked=true
  cur="{}"
  [[ -f "$sig_file" ]] && cur="$(cat -- "$sig_file" 2>/dev/null || printf '{}')"
  jq -e 'type == "object"' <<<"$cur" >/dev/null 2>&1 || cur="{}"
  jq --arg pid "$pool_id" --arg r "$reason" --arg k "$kind" --arg ts "$now" \
    --argjson ep "$now_ep" --argjson ttl "$ttl_sec" --argjson u "$used_val" \
    '.pools[$pid] = ((.pools[$pid] // {}) + {used_pct: $u, degraded_reason: $r, degraded_kind: $k, updated_at: $ts, updated_epoch: $ep, ttl_sec: $ttl})' \
    <<<"$cur" | _afk_router_write_json "$sig_file" || rc=$?
  [[ "$locked" == true ]] && _afk_router_unlock "${sig_file}.lock"
  return "$rc"
}

# afk_router_mark_model_unavailable <model_id> [<reason>]
# Quarantines a single restricted/unavailable model (e.g., 403/model_not_found on
# Mythos or Daybreak Blue) for 1h without poisoning the rest of the provider pool.
afk_router_mark_model_unavailable() {
  local model_id="$1" reason="${2:-model_unavailable}"
  [[ -n "$model_id" ]] || return 0
  local sig_file cur="{}"
  sig_file="$(afk_router_signals_path)"
  mkdir -p "$(dirname -- "$sig_file")"
  [[ -f "$sig_file" ]] && cur="$(cat -- "$sig_file" 2>/dev/null || printf '{}')"
  local now now_ep
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  now_ep="$(date -u +%s)"
  local locked=false rc=0
  _afk_router_lock "${sig_file}.lock" && locked=true
  cur="{}"
  [[ -f "$sig_file" ]] && cur="$(cat -- "$sig_file" 2>/dev/null || printf '{}')"
  jq -e 'type == "object"' <<<"$cur" >/dev/null 2>&1 || cur="{}"
  jq --arg mid "$model_id" --arg r "$reason" --arg ts "$now" --argjson ep "$now_ep" \
    '.unavailable_models[$mid] = {reason: $r, updated_at: $ts, updated_epoch: $ep, ttl_sec: 3600}' \
    <<<"$cur" | _afk_router_write_json "$sig_file" || rc=$?
  [[ "$locked" == true ]] && _afk_router_unlock "${sig_file}.lock"
  return "$rc"
}

_afk_router_count_recent_activity() {
  local dir="$1" mmin="$2"
  [[ -d "$dir" ]] || { printf '0\n'; return 0; }
  find "$dir" -maxdepth 5 -type f \( -name '*.jsonl' -o -name '*.json' \) -mmin "-$mmin" 2>/dev/null | wc -l | tr -d '[:space:]'
}

# _afk_router_probe_claude_quota
# Queries real 5-hour & 7-day OAuth utilization (plus scoped `fable` sub-quota)
# from Anthropic's official usage API (`https://api.anthropic.com/api/oauth/usage`)
# with a 120s local metadata cache (never stores or prints tokens).
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
      ((.seven_day.utilization // ([.limits[]? | select(.is_active == true and .group == "weekly" and (.kind // "weekly_all") == "weekly_all") | .percent] | max) // 0) | tonumber? // 0) as $wk |
      (([.limits[]? | select((.group // "") == "scoped_weekly" or (.kind // "") == "weekly_scoped" or (((.kind // .id // .name // .label // "") | ascii_downcase) | contains("fable"))) | .percent] | max) // (.seven_day_fable.utilization // null)) as $fable_wk |
      ((.extra_usage.is_enabled // false) == true and ((.extra_usage.utilization // 100) < 90)) as $extra_ok |
      (if $extra_ok then ([ $fh, (($wk * 0.80)) ] | max | round)
       else ([ $fh, $wk, ([.limits[]? | select(.is_active == true and (.group // "weekly") != "scoped_weekly" and (.kind // "weekly_all") != "weekly_scoped" and ((((.kind // "") | ascii_downcase) | contains("fable")) | not)) | .percent] | max // 0) ] | max | round) end) as $eff |
      {
        ok: true,
        source: "anthropic_oauth_api",
        used_pct: (if $eff > 100 then 100 elif $eff < 0 then 0 else $eff end),
        five_hour_pct: ($fh | round),
        seven_day_pct: ($wk | round),
        fable_weekly_pct: (if $fable_wk == null then null else ($fable_wk | tonumber? // 0 | round) end),
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
    jq -e 'type == "object"' <<<"$cur_cache" >/dev/null 2>&1 || cur_cache="{}"
    (umask 077 && jq -cn --argjson cur "$cur_cache" --argjson d "$parsed" --argjson ep "$now_ep" \
      '$cur + {claude: {fetched_epoch: $ep, data: $d}}' | _afk_router_write_json "$cache_file" 600) 2>/dev/null || true
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
# Computes real subscription pool utilization, remaining capacity, and auth alerts.
afk_router_probe_pools() {
  local repo="${1:-}"
  local cfg="{}" litellm_url="${AFK_LITELLM_BASE_URL:-}"
  if [[ -n "$repo" && -f "$repo/.afk/config.json" ]]; then
    cfg="$(cat -- "$repo/.afk/config.json" 2>/dev/null || printf '{}')"
    [[ -z "$litellm_url" ]] && litellm_url="$(jq -r '.router.litellm_base_url // empty' <<<"$cfg" 2>/dev/null)"
  fi

  local cat_file sig_file
  cat_file="$(afk_router_catalog_path)" || true
  # With no catalog the pools still resolve from their built-in defaults.
  [[ -f "$cat_file" ]] || cat_file=/dev/null
  sig_file="$(afk_router_signals_path)"

  local harnesses_json bindings_json="[]"
  harnesses_json="$(afk_router_discover_harnesses "$litellm_url")"
  if declare -F afk_harness_probe_account_bindings >/dev/null 2>&1; then
    if [[ -z "${AFK_ROUTER_HARNESS_LIST:-}" || -n "${AFK_OPENCODE_AUTH_FILE:-}" || -n "${AFK_CODEX_AUTH_FILE:-}" || -n "${AFK_PI_AUTH_FILE:-}" || -n "${AFK_GROK_AUTH_FILE:-}" ]]; then
      bindings_json="$(afk_harness_probe_account_bindings)"
    fi
  fi

  local c_5h=0 x_5h=0 a_5h=0 o_5h=0 p_5h=0 g_5h=0 xai_5h=0
  if [[ -z "${AFK_ROUTER_SIGNALS_FILE:-}" ]]; then
    c_5h="$(_afk_router_count_recent_activity "$HOME/.claude/projects" 300)"
    local x1 x2
    x1="$(_afk_router_count_recent_activity "$HOME/.codex/sessions" 300)"
    x2="$(_afk_router_count_recent_activity "$HOME/.config/orca/codex-accounts" 300)"
    x_5h=$(( x1 + x2 ))
    a_5h="$(find "$HOME/.gemini/antigravity-cli/brain" -mindepth 1 -maxdepth 1 -type d -mmin -300 2>/dev/null | wc -l | tr -d '[:space:]')"
    o_5h="$(_afk_router_count_recent_activity "$HOME/.local/share/opencode" 300)"
    p_5h="$(_afk_router_count_recent_activity "$HOME/.pi/agent/sessions" 300)"
    g_5h="$(_afk_router_count_recent_activity "$HOME/.grok" 300)"
    xai_5h="$g_5h"
    if jq -e '.[] | select(.harness == "opencode" and .entitlement_pool == "xai-grok")' <<<"$bindings_json" >/dev/null 2>&1; then
      xai_5h=$(( xai_5h + o_5h ))
    fi
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
  # A truncated or hand-edited signals file must not take routing down.
  jq -e 'type == "object"' <<<"$sig_json" >/dev/null 2>&1 || sig_json="{}"
  jq -e 'type == "object"' <<<"$claude_q" >/dev/null 2>&1 || claude_q="{}"
  jq -e 'type == "object"' <<<"$codex_q" >/dev/null 2>&1 || codex_q="{}"
  jq -e 'type == "array"' <<<"$bindings_json" >/dev/null 2>&1 || bindings_json="[]"

  local now_ep openai_auth_mtime=0 claude_auth_mtime=0 grok_auth_mtime=0 m1=0 m2=0
  now_ep="$(date -u +%s)"
  m1="$(_afk_router_file_mtime "${AFK_CODEX_AUTH_FILE:-$HOME/.codex/auth.json}")"
  m2="$(_afk_router_file_mtime "${AFK_OPENCODE_AUTH_FILE:-$HOME/.local/share/opencode/auth.json}")"
  (( m1 > m2 )) && openai_auth_mtime="$m1" || openai_auth_mtime="$m2"
  claude_auth_mtime="$(_afk_router_file_mtime "${AFK_CLAUDE_CREDS_FILE:-$HOME/.claude/.credentials.json}")"
  grok_auth_mtime="$(_afk_router_file_mtime "${AFK_GROK_AUTH_FILE:-$HOME/.grok/auth.json}")"

  local litellm_on hermetic_mode="false"
  litellm_on="$(jq -r '.litellm_gateway.online' <<<"$harnesses_json")"
  [[ -n "${AFK_ROUTER_HARNESS_LIST:-}" && -z "${AFK_OPENCODE_AUTH_FILE:-}" && -z "${AFK_GROK_AUTH_FILE:-}" ]] && hermetic_mode="true"

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
    --argjson g5 "$xai_5h" \
    --argjson now "$now_ep" \
    --argjson oa_mt "$openai_auth_mtime" \
    --argjson ca_mt "$claude_auth_mtime" \
    --argjson ga_mt "$grok_auth_mtime" \
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
            if ($lr | test("401|unauthorized|revoked|invalidated oauth|refresh token|not logged in")) then "auth"
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
       elif ($asig.degraded_kind // "") == "auth" then "auth_required"
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
        fable_weekly_used_pct: ($live_q.fable_weekly_pct // null),
        resets_at: ($live_q.resets_at // null),
        degraded_kind: ($asig.degraded_kind // null),
        degraded_reason: ($asig.degraded_reason // null),
        active_sessions_5h: $raw_sessions,
        harnesses_feeding_pool: (if ($bound_h | length) > 0 then $bound_h else $default_harnesses end),
        account_fingerprints: $fps
      };

    {
      "anthropic-max":    calc_pool("anthropic-max"; $c5; false; ["claude"]; $cq; $ca_mt),
      "openai-plus":      calc_pool("openai-plus"; $x5; false; ["codex"]; $xq; $oa_mt),
      "antigravity-pool": calc_pool("antigravity-pool"; $a5; false; ["agy"]; {}; 0),
      "xai-grok":         calc_pool("xai-grok"; $g5; false; ["grok","opencode"]; {}; $ga_mt),
      "opencode-free":    calc_pool("opencode-free"; $o5; false; ["opencode"]; {}; 0),
      "litellm-local":    calc_pool("litellm-local"; 0; true; ["claude","opencode"]; {}; 0)
    } as $pools |

    (
      [
        $pools | to_entries[] | select(.value.state == "auth_required") |
        .value as $p |
        ($p.harnesses_feeding_pool[0] // "unknown") as $primary_h |
        {
          pool: .key,
          pool_id: .key,
          harnesses: $p.harnesses_feeding_pool,
          reason: ($p.degraded_reason // "Authentication token expired or signed out"),
          reauth_command: (
            if $primary_h == "codex" then "codex login"
            elif $primary_h == "claude" then "claude auth login"
            elif $primary_h == "grok" then "grok login"
            elif $primary_h == "agy" then "agy login"
            else ($primary_h + " login") end
          )
        }
      ] +
      (if (($h.grok.installed // false) == true and ($herm | not) and ($pools["xai-grok"].quota_source == "unauthenticated")) then
        [{pool: "xai-grok", pool_id: "xai-grok", harnesses: ["grok"], reason: "grok CLI installed on disk but not signed in", reauth_command: "grok login"}]
       else [] end)
    ) as $alerts |

    {
      schema: "afk-router-pools/3",
      harnesses: $h,
      auth_alerts: $alerts,
      unavailable_models: (
        ($sig.unavailable_models // {})
        | with_entries(select(($now - (.value.updated_epoch // 0)) < (.value.ttl_sec // 3600)))
      ),
      pools: $pools
    }'
}

# afk_router_select_candidate <repo> <stage> <risk> [<builder_family>] [<role>] [<round>] [<surfaces>] [<diff_lines>]
# Evaluates public benchmark scores + pool size/headroom + live discovered models +
# BMAD role complexity + security/frontier entitlements + automatic effort escalation.
afk_router_select_candidate() {
  local repo="${1:-}" stage="${2:-build}" risk="${3:-low}" builder_family="${4:-}"
  local role="${5:-}" round="${6:-1}" surfaces="${7:-}" diff_lines="${8:-0}"
  [[ "$round" =~ ^[0-9]+$ && "$round" -ge 1 ]] || round=1
  [[ "$diff_lines" =~ ^[0-9]+$ ]] || diff_lines=0

  afk_router_ensure_fresh_benchmarks

  local cfg="{}"
  if [[ -n "$repo" && -f "$repo/.afk/config.json" ]]; then
    cfg="$(cat -- "$repo/.afk/config.json" 2>/dev/null || printf '{}')"
  fi

  local task_class
  task_class="$(afk_router_stage_to_task_class "$stage" "$risk" "$role" "$surfaces" "$round" "$diff_lines")"

  local default_mem="advisory"
  if [[ "$stage" == review* || "$stage" == "approve" ]]; then
    default_mem="$(jq -r '.router.hindsight.review_stages // "blind"' <<<"$cfg" 2>/dev/null)"
  else
    default_mem="$(jq -r '.router.hindsight.build_stages // "advisory"' <<<"$cfg" 2>/dev/null)"
  fi

  local litellm_url allow_metered prefer_free sec_models_csv
  litellm_url="${AFK_LITELLM_BASE_URL:-$(jq -r '.router.litellm_base_url // empty' <<<"$cfg" 2>/dev/null)}"
  allow_metered="${AFK_ROUTER_ALLOW_METERED_API:-$(jq -r '.router.allow_metered_api // false' <<<"$cfg" 2>/dev/null)}"
  prefer_free="${AFK_ROUTER_PREFER_FREE:-$(jq -r '.router.prefer_free_for_low_risk // false' <<<"$cfg" 2>/dev/null)}"
  # A review is what an unattended merge rests on. Free and local models are
  # kept off it unless the project opts in.
  local allow_free_rev
  allow_free_rev="${AFK_ROUTER_ALLOW_FREE_REVIEWERS:-$(jq -r '.router.allow_free_reviewers // false' <<<"$cfg" 2>/dev/null)}"
  [[ "$allow_free_rev" == "true" || "$allow_free_rev" == "1" ]] && allow_free_rev="true" || allow_free_rev="false"
  sec_models_csv="${AFK_SECURITY_MODELS:-$(jq -r '(.router.security_models // []) | join(",")' <<<"$cfg" 2>/dev/null)}"
  if [[ -z "$sec_models_csv" && -f "$HOME/.config/afk/router.json" ]]; then
    sec_models_csv="$(jq -r '(.security_models // []) | join(",")' "$HOME/.config/afk/router.json" 2>/dev/null || true)"
  fi
  [[ "$allow_metered" == "true" || "$allow_metered" == "1" ]] && allow_metered="true" || allow_metered="false"
  [[ "$prefer_free" == "true" || "$prefer_free" == "1" ]] && prefer_free="true" || prefer_free="false"

  local cat_file probe_json disc_file tmp_disc
  cat_file="$(afk_router_catalog_path)" || true
  [[ -f "$cat_file" ]] || cat_file=/dev/null
  probe_json="$(afk_router_probe_pools "$repo")"
  # No usable probe means no harness is known to be installed. Route to the
  # explicit fallback below; an empty answer would be silently replaced by
  # the caller's own default.
  jq -e '(.pools | type) == "object" and (.harnesses | type) == "object"' <<<"$probe_json" >/dev/null 2>&1 \
    || probe_json='{"schema":"afk-router-pools/3","harnesses":{},"auth_alerts":[],"unavailable_models":{},"pools":{},"probe_failed":true}'
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
    --arg rl "$role" \
    --arg sf "$surfaces" \
    --argjson rnd "$round" \
    --argjson dl "$diff_lines" \
    --arg bf "$builder_family" \
    --arg mm "$default_mem" \
    --arg lurl "$litellm_url" \
    --arg sec_csv "$sec_models_csv" \
    --argjson allow_api "$allow_metered" \
    --argjson pref_free "$prefer_free" \
    --argjson allow_free_rev "$allow_free_rev" \
    --argjson now_ep "$(date -u +%s)" \
    --argjson carry_s "$(c="${AFK_BENCHMARK_CARRY_SEC:-1209600}"; [[ "$c" =~ ^[0-9]+$ ]] && printf '%s' "$c" || printf '1209600')" \
    '
    # Determine which restricted security specialist models are entitled/enabled
    (("," + ($sec_csv | ascii_downcase | gsub(" "; "")) + ",")) as $sec_norm |
    (
      ($sec_norm | contains(",all,")) or
      ($sec_norm | contains(",mythos,")) or
      ($sec_norm | contains(",claude-mythos,")) or
      ([ $disc[0].models[]? | select(.model | ascii_downcase | contains("mythos")) ] | length > 0)
    ) as $mythos_enabled |
    (
      ($sec_norm | contains(",all,")) or
      ($sec_norm | contains(",daybreak,")) or
      ($sec_norm | contains(",daybreak-blue,")) or
      ($sec_norm | contains(",gpt-daybreak-blue,")) or
      ([ $disc[0].models[]? | select(.model | ascii_downcase | contains("daybreak")) ] | length > 0)
    ) as $daybreak_enabled |

    def effort_rank($e):
      if $e == "low" then 1
      elif $e == "medium" then 2
      elif $e == "high" then 3
      elif $e == "xhigh" then 4
      elif $e == "max" or $e == "ultra" then 5
      else 2 end;

    def rank_to_effort($r):
      if $r <= 1 then "low"
      elif $r == 2 then "medium"
      elif $r == 3 then "high"
      elif $r == 4 then "xhigh"
      else "max" end;

    # Clamp desired effort rank to the closest effort level supported by the model/harness
    def clamp_effort($target_rank; $supported):
      ($supported // ["low","medium","high"]) as $sup |
      rank_to_effort($target_rank) as $ideal |
      if ($sup | index($ideal)) != null then $ideal
      else
        ([ $sup[] | {e: ., d: ((effort_rank(.) - $target_rank) | if . < 0 then -. else . end), r: effort_rank(.)} ]
         | sort_by(.d, -.r) | .[0].e // "high")
      end;

    # Compute base reasoning effort + automatic mid-task effort escalation
    def resolve_effort($cand_def; $supported):
      (
        if ($tc == "frontier_synthesis" or $rk == "critical") then 4
        elif ($tc == "security" or $tc == "architecture" or $tc == "coding_complex" or $rk == "high") then 3
        elif ($rl == "pm" or $rl == "architect" or $rl == "security") and ($st != "intake" or $rk != "low") then 3
        elif ($st | startswith("review")) and ($rk == "medium") then 3
        elif ($rk == "low" and ($dl > 0) and ($dl < 80) and ($tc == "research" or $tc == "coding_standard" or $tc == "coding_review" or $tc == "webdev")) then 2
        elif ($rk == "low" and ($tc == "research" or $tc == "coding_standard")) then 2
        else effort_rank($cand_def // "medium") end
      ) as $base_r |
      (if $rnd == 2 then 1 elif $rnd >= 3 then 2 else 0 end) as $round_bump |
      (if (($st | startswith("review")) and $dl >= 250 and $round_bump == 0) then 1 else 0 end) as $diff_bump |
      ($base_r + $round_bump + $diff_bump) as $raw_target |
      (if $raw_target > 5 then 5 else $raw_target end) as $target_r |
      clamp_effort($target_r; $supported) as $chosen |
      {
        effort: $chosen,
        base_effort: clamp_effort($base_r; $supported),
        escalated: (($round_bump + $diff_bump) > 0),
        reason: (
          if $round_bump > 0 then ("auto_escalated_round_" + ($rnd|tostring))
          elif $diff_bump > 0 then ("auto_escalated_large_diff_" + ($dl|tostring) + "L")
          elif $tc == "frontier_synthesis" then "critical_frontier_synthesis"
          elif $tc == "security" then "security_deep_audit"
          elif ($rl == "pm" or $rl == "architect") and $tc == "architecture" then ("bmad_" + $rl + "_synthesis_floor")
          else ("benchmark_task_" + $tc) end
        )
      };

    # Convert dynamically discovered models into router candidate records
    ([
      $disc[0].models[]? |
      select(.capabilities.toolcall == true) |
      select(.cost_class == "free" or .cost_class == "subscription" or ($allow_api == true and .cost_class == "api-metered")) |
      # Deduplicate native catalog flagship entries so we do not double-count them
      select((.harness == "agy" and (.model | test("^gemini-4-carbon"))) | not) |
      select((.harness == "grok" and (.model == "grok-4.7")) | not) |
      select((.harness == "codex" and (.model == "gpt-6-astra" or .model == "gpt-6.1-sol")) | not) |
      select(
        .is_free == true or
        (.model | test("gpt-6-astra$|gpt-6\\.1-sol$|gpt-5\\.3-codex-spark$|claude-fable|claude-mythos|daybreak-blue|claude-opus-5-5(-high)?$|claude-sonnet-5-5(-high)?$|gemini-4-argon-high$|gemini-3\\.8-flash-high$|^grok-4\\.6$"))
      ) |
      {
        id: .id,
        harness: .harness,
        launch_class: .launch_class,
        entitlement_pool: .entitlement_pool,
        cost_class: .cost_class,
        is_free: .is_free,
        tier: (if (.model | test("sonnet|sol|flash|luna")) then "standard" else "strong" end),
        model: .model,
        canonical_model: .canonical_model,
        model_family: .model_family,
        effort: (if .capabilities.reasoning then "high" else "medium" end),
        supported_efforts: (.supported_efforts // (if .capabilities.reasoning then ["low","medium","high"] else ["medium"] end)),
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
      ($probe.pools["antigravity-pool"].state != "available") and
      ($probe.pools["xai-grok"].state != "available")
    ) as $subs_under_pressure |

    [
      $cands[] |
      . as $c |
      ($probe.harnesses[$c.harness].installed // false) as $h_installed |
      ($probe.pools[$c.entitlement_pool] // {state:"available", headroom_pct:100, used_pct:0, capacity_5h:50, remaining_units_5h:50, cost_class:($c.cost_class // "subscription")}) as $pool |
      ($c.cost_class // $pool.cost_class // "subscription") as $cclass |
      ($c.benchmarks[$tc].score // $c.benchmarks.coding_complex.score // 75.0) as $base_score |
      ($c.benchmarks[$tc].benchmark // "Public Leaderboard Aggregate") as $b_name |
      (($c.requires_entitlement // "") == "") as $no_special_ent |
      (
        $no_special_ent or
        (($c.requires_entitlement == "mythos") and $mythos_enabled) or
        (($c.requires_entitlement == "daybreak-blue") and $daybreak_enabled)
      ) as $ent_ok |
      (
        (($c.scoped_quota // "") != "fable") or
        (($pool.fable_weekly_used_pct // 0) < 90)
      ) as $scoped_quota_ok |
      (($probe.unavailable_models[$c.model] // null) == null) as $model_ok |

      # Eligibility gates:
      # 1. Harness binary installed & healthy on host
      # 2. Specialist security entitlement (Mythos / Daybreak Blue) verified if required
      # 3. Model not quarantined by recent 403/model_not_found & scoped quota <90%
      # 4. Metered API models blocked unless allow_metered_api == true
      # 5. Pool not exhausted (>=90%), auth_required, or offline
      # 6. Gateway candidates require LiteLLM gateway to be online
      select($h_installed == true) |
      select($ent_ok == true) |
      select($scoped_quota_ok == true) |
      select($model_ok == true) |
      # Reviewer floor: no free or local model reviews work that may merge
      # unattended. A small diff kept the larger models out, and the
      # cross-family bonus then put a free model with an estimated score on
      # the review the merge rested on.
      select(
        ((($tc == "coding_review") or ($st | startswith("review")) or ($st == "approve")) | not)
        or $allow_free_rev
        or ((($c.is_free // false) != true) and ($cclass != "free") and (($c.requires_gateway // false) != true))
      ) |
      # Frontier models stay reserved for high-risk, security, architecture,
      # and large diffs. A known small edit is one case. Intake of a new
      # story is the other: the diff is still 0, and a low or medium risk
      # guess must not start on Astra, Fable, Opus, Gemini 4 Carbon, or
      # Grok 4.7. A zero-diff build is left alone so pool conservation can
      # still fail over.
      select(
        (
          ($c.model | test("astra|fable|mythos|daybreak|opus|gemini-4-carbon|gpt-6|(^|/)grok-4\\.7$")) and
          (
            (
              ($rk == "low") and ($dl > 0) and ($dl < 80) and
              ($tc == "research" or $tc == "coding_standard" or $tc == "coding_review" or $tc == "webdev")
            ) or (
              ($st == "intake") and ($rk == "low" or $rk == "medium")
            )
          )
        ) | not
      ) |
      select($cclass != "api-metered" or $allow_api == true) |
      select($pool.state != "exhausted" and $pool.state != "offline" and $pool.state != "auth_required") |
      # A gateway model is a candidate only while the gateway is up and lists
      # that model; routing to a name it does not serve fails every attempt.
      select((($c.requires_gateway // false) == false)
             or (($probe.harnesses.litellm_gateway.online == true)
                 and ((($probe.harnesses.litellm_gateway.models // []) | index($c.model)) != null))) |

      # Pool conservation adjustment:
      (if ($pool.state == "warning" and ($rk == "low" or $rk == "medium")) then -15.0 else 0.0 end) as $pool_adj |

      # Pool headroom + pool size bonus:
      (($pool.headroom_pct // 50) * 0.02) as $headroom_bonus |
      ((($pool.remaining_units_5h // 25) | if . > 60 then 60 else . end) * 0.025) as $capacity_bonus |

      # Prefer native harness slightly (+0.5) over bridged OAuth when both are healthy on the same pool
      (if ($c.is_bridged_oauth // false) then -0.5 else 0.0 end) as $bridge_adj |

      # Frontier quota-preservation rule: reserve Fable (`frontier_only`) for `frontier_synthesis` / `critical` / Round 3+
      (if (($c.frontier_only // false) == true and $tc != "frontier_synthesis" and $rk != "critical") then -6.0 else 0.0 end) as $frontier_adj |

      # Specialist security routing rule: boost Mythos & Daybreak Blue on security tasks (+4.0), reserve them (-15.0) on non-security tasks
      (if (($c.specialist_domain // "") == "security") then
         (if $tc == "security" then 4.0 else -15.0 end)
       else 0.0 end) as $security_adj |

      # BMAD Role Complexity Floor: prevent mid-tier execution models (`sonnet`, `sol`, `flash`, `local-coding`)
      # from handling BMAD PM (PRD/Epics/Stories) or Architect system-design synthesis!
      (if (($rl == "pm" or $rl == "architect") and ($tc == "architecture" or $tc == "frontier_synthesis") and (($c.tier // "") == "standard" or ($c.is_free // false) == true)) then -8.0 else 0.0 end) as $role_floor_adj |

      # Cross-Family Blind Review Bonus (applies to both `coding_review` and `review-security`):
      (if ((($tc == "coding_review") or ($st | startswith("review"))) and $bf != "" and $c.model_family != $bf) then 6.0 else 0.0 end) as $cross_family_bonus |

      # Local AI Zero-Cost Bonus on low-risk tasks when LiteLLM cluster is online
      (if (($c.requires_gateway // false) == true and $rk == "low" and ($tc == "research" or $tc == "coding_standard")) then 6.5 else 0.0 end) as $local_bonus |

      # Free OpenCode Model Bonus ($0 cost):
      (if (($c.is_free // false) == true and $rk == "low" and ($tc == "research" or $tc == "coding_standard") and ($pref_free == true or $subs_under_pressure == true)) then 14.0 else 0.0 end) as $free_bonus |

      ($base_score + $pool_adj + $headroom_bonus + $capacity_bonus + $bridge_adj + $frontier_adj + $security_adj + $role_floor_adj + $cross_family_bonus + $local_bonus + $free_bonus) as $eff_score |
      resolve_effort($c.effort; $c.supported_efforts) as $ef |
      # A measurement older than the carry window is reported as stale: the
      # catalog is left alone while no board answers, so its age is checked
      # here.
      (($c.benchmarks[$tc] // {}) as $be
       | ($be.basis // "estimate") as $bb
       | if ($be.score // null) == null then "estimate"
         elif ($bb == "measured" or $bb == "capped") and (($now_ep - ($be.synced_epoch // 0)) > $carry_s) then "stale"
         else $bb end) as $basis |

      {
        stage: $st,
        role: (if $rl == "" then null else $rl end),
        round: $rnd,
        task_class: $tc,
        risk: $rk,
        candidate_id: $c.id,
        harness: $c.harness,
        launch_class: $c.launch_class,
        model: $c.model,
        canonical_model: $c.canonical_model,
        model_family: $c.model_family,
        specialist_domain: ($c.specialist_domain // null),
        cost_class: $cclass,
        is_free: ($c.is_free // ($cclass == "free")),
        effort: $ef.effort,
        base_effort: $ef.base_effort,
        effort_escalated: $ef.escalated,
        effort_reason: $ef.reason,
        supported_efforts: ($c.supported_efforts // ["low","medium","high"]),
        window_tokens: $c.window_tokens,
        entitlement_pool: $c.entitlement_pool,
        pool_state: $pool.state,
        pool_capacity_5h: $pool.capacity_5h,
        pool_remaining_5h: $pool.remaining_units_5h,
        pool_used_pct: $pool.used_pct,
        pool_headroom_pct: $pool.headroom_pct,
        benchmark_name: $b_name,
        benchmark_score: $base_score,
        # measured: this sync or a recent one read it off a public board.
        # capped: the board is reachable and does not list the model.
        # estimate: a fixed figure from the catalog, never measured.
        benchmark_basis: $basis,
        benchmark_live: ($basis == "measured" and (($c.benchmarks[$tc].live // false) == true)),
        benchmark_synced_at: ($c.benchmarks[$tc].synced_at // null),
        effective_score: (($eff_score * 100 | round) / 100),
        cross_family_review: (((($tc == "coding_review") or ($st | startswith("review"))) and $bf != "" and $c.model_family != $bf)),
        memory_mode: $mm,
        router_source: (if ($c.requires_gateway // false) then "afk-benchmarks+litellm" else "afk-benchmarks" end),
        litellm_base_url: (if (($c.requires_gateway // false) and $lurl != "") then $lurl else null end),
        auth_alerts: $probe.auth_alerts,
        reason: (
          "Selected " + $c.harness + "/" + $c.model + " [" + $c.canonical_model + ", effort=" + $ef.effort +
          (if $ef.escalated then " (" + $ef.reason + ")" else "" end) +
          ", cost=" + $cclass + "] " +
          "(pool=" + $c.entitlement_pool + " " + ($pool.remaining_units_5h|tostring) + "/" + ($pool.capacity_5h|tostring) + " free [" + ($pool.headroom_pct|tostring) + "%], " +
          "benchmark=" + ($base_score|tostring) + " via " + $b_name +
          (if (($c.specialist_domain // "") == "security" and $tc == "security") then ", specialist cybersecurity model" else "" end) +
          (if ((($tc == "coding_review") or ($st | startswith("review"))) and $bf != "" and $c.model_family != $bf) then ", cross-family blind review vs " + $bf else "" end) +
          (if $pool.state == "warning" then ", pool conservation penalty applied" else "" end) + ")"
        )
      }
    ] | sort_by(-.effective_score) | .[0] // {
      stage: $st,
      role: (if $rl == "" then null else $rl end),
      round: $rnd,
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
      base_effort: "medium",
      effort_escalated: false,
      effort_reason: "fallback_default",
      supported_efforts: ["low","medium","high"],
      window_tokens: 1000000,
      entitlement_pool: "anthropic-max",
      pool_headroom_pct: 100,
      benchmark_name: "Fallback Default",
      benchmark_score: 85.0,
      benchmark_basis: "estimate",
      benchmark_live: false,
      benchmark_synced_at: null,
      effective_score: 85.0,
      memory_mode: $mm,
      router_source: "fallback-default",
      # Nothing passed the eligibility gates. The state that decided it is
      # recorded so the failure can be read from the route file alone.
      no_eligible_candidate: true,
      candidates_considered: ($cands | length),
      installed_harnesses: ([ ($probe.harnesses // {}) | to_entries[] | select(.key != "litellm_gateway" and (.value.installed // false) == true) | .key ]),
      pool_states: (($probe.pools // {}) | map_values(.state)),
      litellm_base_url: (if $lurl == "" then null else $lurl end),
      auth_alerts: ($probe.auth_alerts // []),
      reason: "Fallback route (no eligible candidate matched)"
    }')"
  rm -f "$tmp_disc"
  printf '%s\n' "$result_json"
}

# _afk_router_fetch_feed <name> <url> <dest> [<header>]
# Fetches one public feed into <dest>. With AFK_BENCHMARK_FEED_DIR set, the
# feed is read from <dir>/<name>.json instead and nothing touches the network:
# a missing file there is an unreachable feed. Returns 0 only when <dest> holds
# non-empty JSON.
_afk_router_fetch_feed() {
  local name="$1" url="$2" dest="$3" header="${4:-}"
  : > "$dest"
  if [[ -n "${AFK_BENCHMARK_FEED_DIR:-}" ]]; then
    [[ -f "$AFK_BENCHMARK_FEED_DIR/$name.json" ]] || return 1
    cp -- "$AFK_BENCHMARK_FEED_DIR/$name.json" "$dest" 2>/dev/null || return 1
  else
    local -a hdr=()
    [[ -n "$header" ]] && hdr=(-H "$header")
    curl -sS --connect-timeout 3 --max-time 8 ${hdr[@]+"${hdr[@]}"} "$url" > "$dest" 2>/dev/null || { : > "$dest"; return 1; }
  fi
  [[ -s "$dest" ]] && jq -e . "$dest" >/dev/null 2>&1
}

# afk_router_sync_benchmarks [<out_file>]
# Refreshes the benchmark catalog from the public feeds and writes it
# atomically. Prints a receipt (schema afk-benchmark-sync/3).
#
# Scores that can be measured come from the LMArena leaderboards (agent,
# webdev, text); context windows come from models.dev. Every other score in the
# catalog is a fixed estimate from files/model-router/benchmarks.json. Each
# measured entry is marked `live: true` with its rank, raw value and sync time,
# so a route can say whether it rests on a measurement or an estimate.
#
# A leaderboard lists one row per model and effort level ("Claude Opus 5.5
# (Max)"). A candidate's `arena_match` names the model without the effort
# suffix and is compared whole, ignoring case and punctuation; the best-ranked
# row wins. A partial name never matches, so "Grok 4.5" cannot take the score
# of "Grok 4.7".
#
# When a feed is unreachable, the scores it supplied last time are kept for up
# to AFK_BENCHMARK_CARRY_SEC (default 14 days) and then fall back to the fixed
# estimates. When no leaderboard feed is reachable at all, an existing catalog
# is left exactly as it is.
#
# Exit status: 0 synced from at least one leaderboard feed; 3 no leaderboard
# feed was reachable; 1 the catalog could not be read or written.
afk_router_sync_benchmarks() {
  local out_file="${1:-$HOME/.config/afk/benchmarks.json}"
  local base_file
  base_file="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/files/model-router/benchmarks.json"
  [[ -f "$base_file" ]] || base_file="$HOME/.agents/skills/model-router/benchmarks.json"
  if ! jq -e '(.candidates | type) == "array"' "$base_file" >/dev/null 2>&1; then
    jq -cn --arg out "$out_file" --arg b "$base_file" \
      '{schema:"afk-benchmark-sync/3", result:"error", reason:("base catalog missing or unreadable: " + $b), catalog_path:$out}'
    return 1
  fi

  mkdir -p "$(dirname -- "$out_file")" 2>/dev/null || true
  local today now_ep sync_tmp carry="${AFK_BENCHMARK_CARRY_SEC:-1209600}"
  [[ "$carry" =~ ^[0-9]+$ ]] || carry=1209600
  today="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  now_ep="$(date -u +%s)"
  sync_tmp="$(mktemp -d "${TMPDIR:-/tmp}/afk-bench-sync.XXXXXX")" || return 1

  local st_agent="offline" st_webdev="offline" st_text="offline" st_mdev="offline" st_aa="no_key"
  local lm="https://datasets-server.huggingface.co/rows?dataset=lmarena-ai%2Fleaderboard-dataset&split=latest&offset=0&length=100&config="
  # Rows are reduced to {model_name, rank, value, date}. A row without a
  # numeric rank is dropped here, so the scoring below never does arithmetic
  # on a string.
  local rows_filter='[.rows[]?.row | select((.rank | type) == "number") | select(((.category // "overall") | ascii_downcase) == "overall") | {model_name: (.model_name // ""), rank, value: (.score // .rating // null), date: (.leaderboard_publish_date // null)}]'
  local feed
  for feed in agent webdev text; do
    printf '[]' > "$sync_tmp/$feed.json"
    if _afk_router_fetch_feed "lmarena-$feed" "${lm}${feed}" "$sync_tmp/raw.json" \
       && jq -c "$rows_filter" "$sync_tmp/raw.json" > "$sync_tmp/rows.json" 2>/dev/null \
       && jq -e 'length > 0' "$sync_tmp/rows.json" >/dev/null 2>&1; then
      mv -f -- "$sync_tmp/rows.json" "$sync_tmp/$feed.json"
      case "$feed" in
        agent)  st_agent="live_synced ($(jq -r '.[0].date // "latest"' "$sync_tmp/$feed.json"))" ;;
        webdev) st_webdev="live_synced ($(jq -r '.[0].date // "latest"' "$sync_tmp/$feed.json"))" ;;
        text)   st_text="live_synced ($(jq -r '.[0].date // "latest"' "$sync_tmp/$feed.json"))" ;;
      esac
    fi
  done

  printf '{}' > "$sync_tmp/mdev.json"
  if _afk_router_fetch_feed "models-dev" "https://models.dev/api.json" "$sync_tmp/raw.json" \
     && jq -c 'if type == "object" then with_entries(.value = ((.value.models // {}) | with_entries(.value = (.value.limit.context // null)))) else error("not an object") end' \
          "$sync_tmp/raw.json" > "$sync_tmp/rows.json" 2>/dev/null; then
    mv -f -- "$sync_tmp/rows.json" "$sync_tmp/mdev.json"
    st_mdev="live_synced"
  fi

  printf '[]' > "$sync_tmp/aa.json"
  local aa_key="${ARTIFICIAL_ANALYSIS_API_KEY:-${AA_API_KEY:-}}"
  if [[ -n "$aa_key" || ( -n "${AFK_BENCHMARK_FEED_DIR:-}" && -f "${AFK_BENCHMARK_FEED_DIR}/artificial-analysis.json" ) ]]; then
    if _afk_router_fetch_feed "artificial-analysis" "https://artificialanalysis.ai/api/v2/data/llms/models" "$sync_tmp/raw.json" "x-api-key: $aa_key" \
       && jq -c '[.data[] | {slug: (.slug // ""), name, coding: .evaluations.artificial_analysis_coding_index} | select((.coding | type) == "number")]' \
            "$sync_tmp/raw.json" > "$sync_tmp/rows.json" 2>/dev/null; then
      mv -f -- "$sync_tmp/rows.json" "$sync_tmp/aa.json"
      st_aa="live_synced"
    else
      st_aa="error"
    fi
  fi
  aa_key=""

  # The previous catalog supplies the scores to keep when a feed is down.
  printf '{}' > "$sync_tmp/prev.json"
  local have_prev=false
  if [[ -f "$out_file" ]] && jq -e '.schema == "afk-benchmark-catalog/3" and ((.candidates | type) == "array")' "$out_file" >/dev/null 2>&1; then
    cp -- "$out_file" "$sync_tmp/prev.json" && have_prev=true
  fi

  local any_board=false
  [[ "$st_agent" == live_synced* || "$st_webdev" == live_synced* || "$st_text" == live_synced* ]] && any_board=true

  local result="synced" rc=0
  if [[ "$any_board" == false && "$have_prev" == true ]]; then
    # Nothing measured this time. Rewriting the catalog would replace the last
    # measured scores with estimates and make it look fresh for a day.
    result="feeds_unavailable"; rc=3
  else
    [[ "$any_board" == true ]] || { result="feeds_unavailable"; rc=3; }
    if ! jq \
      --arg ts "$today" \
      --argjson now "$now_ep" \
      --argjson carry "$carry" \
      --arg sa "$st_agent" --arg sw "$st_webdev" --arg stx "$st_text" --arg sm "$st_mdev" --arg saa "$st_aa" \
      --slurpfile agf "$sync_tmp/agent.json" \
      --slurpfile wdf "$sync_tmp/webdev.json" \
      --slurpfile txf "$sync_tmp/text.json" \
      --slurpfile mdf "$sync_tmp/mdev.json" \
      --slurpfile aaf "$sync_tmp/aa.json" \
      --slurpfile prevf "$sync_tmp/prev.json" \
      '
      ($agf[0] // []) as $ag | ($wdf[0] // []) as $wd | ($txf[0] // []) as $tx |
      ($mdf[0] // {}) as $md | ($prevf[0] // {}) as $prev |
      # Artificial Analysis publishes an index on its own scale. Only its
      # ordering is used, so it blends with the leaderboard rank scores.
      (($aaf[0] // []) | sort_by(-.coding)) as $aa |
      ($sa | startswith("live_synced")) as $ag_live |
      ($sw | startswith("live_synced")) as $wd_live |
      ($stx | startswith("live_synced")) as $tx_live |
      ($sm == "live_synced") as $md_live |

      # Only an effort suffix is dropped: "(Max)", "(xHigh)", "(High, thinking)".
      # A dated or harness-specific variant stays a separate model.
      def norm: ascii_downcase | sub("\\s*\\((low|medium|high|xhigh|max|thinking)(,[^)]*)?\\)\\s*$"; "") | gsub("[^a-z0-9.]+"; " ") | sub("^ +"; "") | sub(" +$"; "");
      def best($rows; $m):
        if (($m // "") | norm) == "" then null
        else (($m | norm) as $want | [ $rows[] | select((.model_name | norm) == $want) ] | sort_by(.rank) | .[0] // null) end;
      def rank_score($top; $rank):
        ($top - (($rank - 1) * 0.9)) | if . < 80 then 80 else ((. * 10 | round) / 10) end;
      def r1: (. * 10 | round) / 10;
      .updated_at = $ts |
      .candidates |= map(
        . as $c |
        # Defined here, where $c is the candidate being scored.
        def measured($feed; $hit; $score; $label):
          {score: $score, benchmark: $label, live: true, basis: "measured", feed: $feed, rank: $hit.rank, value: $hit.value,
           match: ($c.arena_match // ""), synced_at: $ts, synced_epoch: $now};
        # A score set by an earlier sync from a reachable board, for the same
        # leaderboard name, still inside the carry window. A candidate whose name
        # changed (a model upgrade under the same id) does not inherit the
        # score of the model it replaced.
        def carried($entry):
          if $entry != null and (($entry.basis // "estimate") != "estimate")
             # An entry written before names were recorded has no `match`, and
           # is taken to be for the same model once.
           and ((($entry | has("match")) | not) or (($entry.match // "") == ($c.arena_match // "")))
             and (($now - ($entry.synced_epoch // 0)) <= $carry) and (($entry.synced_epoch // 0) <= $now + 60)
          then ($entry + {match: ($entry.match // ($c.arena_match // ""))}) else null end;
        def estimate($entry):
          if $entry == null then null
          else ($entry | del(.feed, .rank, .value, .match, .synced_at, .synced_epoch, .text_score, .text_synced_epoch) + {live: false, basis: "estimate"}) end;
        # A model a reachable board does not list ranks below every model it
        # does list. Its fixed estimate is held to the score of the next rank
        # down, so an unranked model cannot outscore a ranked one on a guess.
        def unlisted($entry; $feed; $top; $rows; $board):
          if $entry == null then null
          else
            # From the last rank on the board, not the row count: a board that
          # skips ranks would otherwise cap an unlisted model above a listed one.
          rank_score($top; (([$rows[].rank] | max) // 0) + 1) as $cap |
            if (($entry.score // 0) > $cap) then
              ($entry | del(.rank, .value, .text_score, .text_synced_epoch) + {score: $cap, live: false, basis: "capped", feed: $feed, match: ($c.arena_match // ""),
                benchmark: ((.benchmark // "Estimate") + " (not listed on " + $board + ")"), synced_at: $ts, synced_epoch: $now})
            else estimate($entry) end
          end;
        ([ ($prev.candidates // [])[] | select(.id == $c.id) ][0] // null) as $pc |
        (($c.specialist_domain // "") == "") as $general |
        ($general and (($c.frontier_only // false) == false)) as $agent_ok |

        .window_tokens = (
          ($md[$c.models_dev_provider // ""][$c.models_dev_id // ""])
          # Carried from the last sync only for a model models.dev describes;
          # otherwise the figure in the catalog is the truth (a window an
          # earlier catalog had for a different model must not come back).
          // (if $md_live or (($c.models_dev_id // "") == "") then null else $pc.window_tokens end)
          // $c.window_tokens
        ) |

        best($ag; $c.arena_match) as $ag_hit |
        best($wd; $c.arena_match) as $wd_hit |
        best($tx; $c.arena_match) as $tx_hit |
        (if $ag_hit != null then rank_score(98.0; $ag_hit.rank) else null end) as $ag_score |
        (if $wd_hit != null then rank_score(97.5; $wd_hit.rank) else null end) as $wd_score |
        (if $tx_hit != null then rank_score(97.5; $tx_hit.rank) else null end) as $tx_score |
        # Artificial Analysis is used only for a candidate that names its exact
        # slug there (`aa_slug`). A partial match would take the rank of another model.
        (if (($c.aa_slug // "") == "") then null
         else ([ $aa | to_entries[] | select((.value.slug | ascii_downcase) == ($c.aa_slug | ascii_downcase)) | .key ][0] // null) end) as $aa_idx |
        (if $aa_idx != null then rank_score(98.0; $aa_idx + 1) else null end) as $aa_score |

        (if $agent_ok then
          (if $ag_live then
            (if $ag_score != null then
              .benchmarks.coding_complex = measured("lmarena_agent"; $ag_hit;
                (if $aa_score != null then (($ag_score * 0.6 + $aa_score * 0.4) | r1) else $ag_score end);
                ("LMArena Agent #" + ($ag_hit.rank | tostring) + " (" + ($ag_hit.date // "live") + ")"))
              |
              # A review is what an unattended merge rests on, so the reviewer
              # is chosen on the same measured agent ranking as complex builds,
              # not on a hand-written estimate.
              .benchmarks.coding_review = measured("lmarena_agent"; $ag_hit; .benchmarks.coding_complex.score;
                ("LMArena Agent #" + ($ag_hit.rank | tostring) + " (review)"))
              |
              # The reasoning half comes from the text board: this sync, else
              # the value an earlier sync measured, by the time of that measurement,
              # not the time the agent half was last refreshed.
              (carried($pc.benchmarks.architecture // null)) as $parch |
              (if $tx_live then $tx_score
               elif ($parch != null and ($parch.text_score != null) and (($now - ($parch.text_synced_epoch // 0)) <= $carry)) then $parch.text_score
               else null end) as $txs |
              (if $tx_live then $now elif $txs != null then $parch.text_synced_epoch else null end) as $txs_ep |
              .benchmarks.architecture = (measured("lmarena_agent"; $ag_hit;
                ((($ag_score * 0.6) + (($txs // $ag_score) * 0.4)) | r1);
                ("LMArena Agent #" + ($ag_hit.rank | tostring) + (if $txs != null then " + Reasoning" else "" end)))
                + {text_score: $txs, text_synced_epoch: $txs_ep})
            else
              .benchmarks.coding_complex = unlisted($c.benchmarks.coding_complex; "lmarena_agent"; 98.0; $ag; "LMArena Agent") |
              .benchmarks.coding_review = unlisted($c.benchmarks.coding_review; "lmarena_agent"; 98.0; $ag; "LMArena Agent") |
              .benchmarks.architecture = unlisted($c.benchmarks.architecture; "lmarena_agent"; 98.0; $ag; "LMArena Agent")
            end)
          else
            .benchmarks.coding_complex = (carried($pc.benchmarks.coding_complex // null) // estimate($c.benchmarks.coding_complex)) |
            .benchmarks.coding_review = (carried($pc.benchmarks.coding_review // null) // estimate($c.benchmarks.coding_review)) |
            # Carried whole only while its reasoning half is still in its own
            # window; otherwise it falls back to the agent half alone.
            (carried($pc.benchmarks.architecture // null)) as $ca |
            .benchmarks.architecture = (
              if $ca == null then estimate($c.benchmarks.architecture)
              elif ($ca.text_score != null) and (($now - ($ca.text_synced_epoch // 0)) > $carry) and ($ca.rank != null)
                then ($ca + {score: rank_score(98.0; $ca.rank), text_score: null, text_synced_epoch: null,
                             benchmark: ("LMArena Agent #" + ($ca.rank | tostring))})
              else $ca end)
          end)
        else . end) |

        (if $general then
          (if $wd_live then
            .benchmarks.webdev = (if $wd_score != null then
                measured("lmarena_webdev"; $wd_hit; $wd_score;
                  ("LMArena WebDev #" + ($wd_hit.rank | tostring) + (if ($wd_hit.value | type) == "number" then " (" + ($wd_hit.value | round | tostring) + " Elo)" else "" end)))
              else unlisted($c.benchmarks.webdev; "lmarena_webdev"; 97.5; $wd; "LMArena WebDev") end)
          else
            .benchmarks.webdev = (carried($pc.benchmarks.webdev // null) // estimate($c.benchmarks.webdev))
          end) |
          (if $tx_live then
            .benchmarks.research = (if $tx_score != null then
                measured("lmarena_text"; $tx_hit; $tx_score;
                  ("LMArena Reasoning #" + ($tx_hit.rank | tostring) + (if ($tx_hit.value | type) == "number" then " (" + ($tx_hit.value | round | tostring) + " Elo)" else "" end)))
              else unlisted($c.benchmarks.research; "lmarena_text"; 97.5; $tx; "LMArena Reasoning") end)
          else
            .benchmarks.research = (carried($pc.benchmarks.research // null) // estimate($c.benchmarks.research))
          end)
        else . end) |
        .benchmarks |= with_entries(select(.value != null))
      ) |
      . as $doc |
      .sync_receipt = {
        synced_at: $ts,
        lmarena_agent: $sa,
        lmarena_webdev: $sw,
        lmarena_text: $stx,
        swe_bench_official: "not_scored",
        swe_bench_entries: 0,
        models_dev: $sm,
        artificial_analysis: $saa,
        live_scores: ([ $doc.candidates[].benchmarks[] | select((.live // false) == true) ] | length),
        estimated_scores: ([ $doc.candidates[].benchmarks[] | select((.live // false) != true) ] | length),
        capped_scores: ([ $doc.candidates[].benchmarks[] | select((.basis // "") == "capped") ] | length),
        # A general candidate a reachable agent board does not list by that
        # name. Either the model is not ranked or its arena_match is wrong.
        unmatched: (if $ag_live then [ $doc.candidates[] | select(((.specialist_domain // "") == "") and ((.frontier_only // false) == false)) | select((.benchmarks.coding_complex.live // false) != true) | .id ] else [] end)
      }
      ' "$base_file" 2>/dev/null | _afk_router_write_json "$out_file"; then
      rm -rf -- "$sync_tmp"
      jq -cn --arg out "$out_file" --arg ts "$today" \
        '{schema:"afk-benchmark-sync/3", result:"error", reason:"the refreshed catalog could not be built or written; the previous catalog is unchanged", catalog_path:$out, synced_at:$ts}'
      return 1
    fi
  fi
  rm -rf -- "$sync_tmp"

  local count=0 live=0 unmatched="[]"
  if [[ -f "$out_file" ]]; then
    count="$(jq '.candidates | length' "$out_file" 2>/dev/null || printf '0')"
    live="$(jq '[.candidates[].benchmarks[] | select((.live // false) == true)] | length' "$out_file" 2>/dev/null || printf '0')"
    unmatched="$(jq -c '.sync_receipt.unmatched // []' "$out_file" 2>/dev/null || printf '[]')"
  fi
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  [[ "$live" =~ ^[0-9]+$ ]] || live=0
  jq -e 'type == "array"' <<<"$unmatched" >/dev/null 2>&1 || unmatched="[]"

  jq -cn \
    --arg out "$out_file" \
    --arg ts "$today" \
    --arg res "$result" \
    --arg sa "$st_agent" \
    --arg sw "$st_webdev" \
    --arg stx "$st_text" \
    --arg sm "$st_mdev" \
    --arg saa "$st_aa" \
    --argjson count "$count" \
    --argjson live "$live" \
    --argjson um "$unmatched" \
    '{
      schema: "afk-benchmark-sync/3",
      result: $res,
      catalog_path: $out,
      synced_at: $ts,
      candidates_count: $count,
      live_scores: $live,
      unmatched: $um,
      feeds: {
        lmarena_agent: $sa,
        lmarena_webdev: $sw,
        lmarena_text: $stx,
        swe_bench_official: "not_scored",
        models_dev: $sm,
        artificial_analysis: $saa
      }
    }'
  return "$rc"
}
