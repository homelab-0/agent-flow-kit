#!/usr/bin/env bash
# afk-harnesses.sh — Universal Cross-Platform Harness Lifecycle, Update Engine,
# Auth-Health Inspection, Effort-Dial Inventory, Live Model Catalog Discovery &
# Shared Subscription Pool Attribution.
#
# Works across Linux and macOS (Darwin) without requiring GNU-only utilities:
#   1. Detects installed CLI harnesses (claude, codex, agy, grok, opencode, pi, devin)
#      and determines HOW each binary was installed (homebrew, npm + prefix, bun,
#      pnpm, uv, pipx, cargo, or native self-managed installer).
#   2. Checks for upstream updates and applies updates via the exact install
#      channel (`codex` via npm/brew, `claude update`, `grok update`, `opencode upgrade`,
#      `agy update`, `pi` via npm/brew/self, `devin update`), repairing broken binary shims.
#   3. Inventories per-harness and per-model reasoning effort dials (`--effort`,
#      `-c model_reasoning_effort=...`, model tier suffixes) and live auth health
#      (detecting signed-out / `401 token_revoked` harnesses and surfacing exact
#      re-login commands without ever printing secrets).
#   4. Enumerates live models exposed by each harness after updates, classifies
#      exact cost (FREE $0 vs OAuth Subscription vs Local Cluster vs Metered API),
#      maps multi-provider harnesses onto shared entitlement pools + privacy-safe
#      account fingerprints, and scores models against synced public benchmarks.

if [[ -n "${AFK_HARNESSES_SOURCED:-}" ]]; then
  return 0
fi
AFK_HARNESSES_SOURCED=1

afk_harness_discovered_models_path() {
  if [[ -n "${AFK_DISCOVERED_MODELS_FILE:-}" ]]; then
    printf '%s\n' "$AFK_DISCOVERED_MODELS_FILE"
    return 0
  fi
  printf '%s\n' "${HOME:-/tmp}/.config/afk/discovered-models.json"
}

# Portable OS identifier: "linux" | "darwin" | lowercase uname
_afk_harness_os() {
  if [[ -n "${AFK_HARNESS_OS_OVERRIDE:-}" ]]; then
    printf '%s\n' "$AFK_HARNESS_OS_OVERRIDE"
    return 0
  fi
  uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]'
}

# Portable POSIX/bash symlink resolver (works on macOS BSD readlink AND Linux GNU readlink)
_afk_harness_realpath() {
  local target="$1"
  [[ -n "$target" ]] || return 1
  local cur="$target" dir base link hops=0
  while [[ -L "$cur" ]] && (( hops < 20 )); do
    dir="$(cd -P -- "$(dirname -- "$cur")" 2>/dev/null && pwd -P)" || break
    link="$(readlink -- "$cur" 2>/dev/null)" || break
    if [[ "$link" == /* ]]; then
      cur="$link"
    else
      cur="$dir/$link"
    fi
    hops=$((hops + 1))
  done
  if [[ -e "$cur" ]]; then
    dir="$(cd -P -- "$(dirname -- "$cur")" 2>/dev/null && pwd -P)" || { printf '%s\n' "$cur"; return 0; }
    base="$(basename -- "$cur")"
    printf '%s/%s\n' "$dir" "$base"
  else
    printf '%s\n' "$cur"
  fi
}

# Privacy-safe 12-hex SHA-256 fingerprint for non-secret account IDs / emails
# (portable across Linux sha256sum and macOS shasum -a 256).
_afk_harness_hash12() {
  local val="$1"
  [[ -n "$val" ]] || { printf '\n'; return 0; }
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$val" | sha256sum | cut -c1-12
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$val" | shasum -a 256 | cut -c1-12
  else
    printf 'linked'
  fi
}

# Locate candidate binary on Linux or macOS without requiring it in minimal cron/systemd PATH
_afk_harness_locate_bin() {
  local name="$1"
  if [[ -n "${AFK_HARNESS_BIN_DIR_OVERRIDE:-}" ]]; then
    if [[ -x "${AFK_HARNESS_BIN_DIR_OVERRIDE}/$name" || -L "${AFK_HARNESS_BIN_DIR_OVERRIDE}/$name" ]]; then
      printf '%s\n' "${AFK_HARNESS_BIN_DIR_OVERRIDE}/$name"
      return 0
    fi
    return 1
  fi
  local p
  p="$(command -v "$name" 2>/dev/null || true)"
  if [[ -n "$p" ]]; then
    printf '%s\n' "$p"
    return 0
  fi
  local cand
  for cand in \
    "$HOME/.local/bin/$name" \
    "$HOME/.grok/bin/$name" \
    "$HOME/.opencode/bin/$name" \
    "$HOME/.bun/bin/$name" \
    "$HOME/.cargo/bin/$name" \
    "/opt/homebrew/bin/$name" \
    "/usr/local/bin/$name" \
    "/home/linuxbrew/.linuxbrew/bin/$name"; do
    if [[ -x "$cand" || -L "$cand" ]]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

# Default npm package name for each CLI harness when installed via npm/bun/pnpm
_afk_harness_default_npm_pkg() {
  case "$1" in
    claude)   printf '@anthropic-ai/claude-code' ;;
    codex)    printf '@openai/codex' ;;
    opencode) printf 'opencode-ai' ;;
    pi)       printf '@mariozechner/pi-coding-agent' ;;
    *)        printf '%s' "$1" ;;
  esac
}

# Per-harness reasoning effort dial descriptor (CLI flag + supported effort levels)
_afk_harness_effort_dial() {
  case "$1" in
    claude)
      printf '{"supports_effort":true,"cli_flag":"--effort <level>","supported_efforts":["low","medium","high","xhigh","max"]}\n' ;;
    codex)
      printf '{"supports_effort":true,"cli_flag":"-c model_reasoning_effort=<level>","supported_efforts":["low","medium","high","xhigh","max","ultra"]}\n' ;;
    agy)
      printf '{"supports_effort":true,"cli_flag":"--effort <level> (+ model tier suffix)","supported_efforts":["low","medium","high","xhigh","max"]}\n' ;;
    grok)
      printf '{"supports_effort":true,"cli_flag":"--effort <level>","supported_efforts":["low","medium","high","xhigh"]}\n' ;;
    opencode)
      printf '{"supports_effort":true,"cli_flag":"--variant <level>","supported_efforts":["low","medium","high"]}\n' ;;
    pi)
      printf '{"supports_effort":true,"cli_flag":"--thinking <level>","supported_efforts":["low","medium","high"]}\n' ;;
    devin)
      printf '{"supports_effort":true,"cli_flag":"--model <id>-<level>","supported_efforts":["low","medium","high","xhigh","max"]}\n' ;;
    *)
      printf '{"supports_effort":false,"cli_flag":null,"supported_efforts":["medium","high"]}\n' ;;
  esac
}

# Re-login command for operator recovery when a harness gets signed out or revoked
_afk_harness_reauth_command() {
  case "$1" in
    claude)   printf 'claude auth login' ;;
    codex)    printf 'codex login' ;;
    agy)      printf 'agy login' ;;
    grok)     printf 'grok login' ;;
    opencode) printf 'opencode auth login' ;;
    pi)       printf 'pi /login' ;;
    devin)    printf 'devin auth login' ;;
    *)        printf '%s login' "$1" ;;
  esac
}

# Extract npm package name & global prefix from a resolved .../node_modules/... path
# Prints: "<pkg>|<prefix>"
_afk_harness_parse_node_modules() {
  local resolved="$1" fallback_pkg="$2"
  local prefix="" rest="" pkg=""
  if [[ "$resolved" == */lib/node_modules/* ]]; then
    prefix="${resolved%%/lib/node_modules/*}"
    rest="${resolved#*/lib/node_modules/}"
  elif [[ "$resolved" == */node_modules/* ]]; then
    prefix="${resolved%%/node_modules/*}"
    rest="${resolved#*/node_modules/}"
  fi
  if [[ "$rest" == @*/* ]]; then
    local scope="${rest%%/*}"
    local after_scope="${rest#*/}"
    local sub="${after_scope%%/*}"
    pkg="${scope}/${sub}"
  elif [[ -n "$rest" ]]; then
    pkg="${rest%%/*}"
  else
    pkg="$fallback_pkg"
  fi
  printf '%s|%s\n' "$pkg" "$prefix"
}

# afk_harness_classify_origin <name> <bin_path> <resolved_path>
# Pure, deterministic classifier (works identically on Linux & macOS paths) that
# determines install_method, package_name, install_prefix, and exact update_cmd.
afk_harness_classify_origin() {
  local name="$1" bin_path="$2" resolved="$3"
  local default_npm
  default_npm="$(_afk_harness_default_npm_pkg "$name")"
  local method="self-managed" pkg="$name" prefix="" update_cmd="" pkg_json=""

  if [[ "$bin_path" == /opt/homebrew/* || "$resolved" == /opt/homebrew/* || "$resolved" == /usr/local/Cellar/* || "$bin_path" == /home/linuxbrew/.linuxbrew/* || "$resolved" == /home/linuxbrew/.linuxbrew/* ]]; then
    method="homebrew"
    if [[ "$resolved" == */Cellar/* ]]; then
      local after_cellar="${resolved#*/Cellar/}"
      pkg="${after_cellar%%/*}"
    elif [[ "$resolved" == */Caskroom/* ]]; then
      local after_cask="${resolved#*/Caskroom/}"
      pkg="${after_cask%%/*}"
    else
      pkg="$name"
    fi
    update_cmd="brew upgrade $pkg"
  elif [[ "$resolved" == */.bun/install/global/node_modules/* || "$bin_path" == */.bun/bin/* ]]; then
    method="bun"
    local parsed
    parsed="$(_afk_harness_parse_node_modules "$resolved" "$default_npm")"
    pkg="${parsed%%|*}"
    prefix="${parsed#*|}"
    update_cmd="bun add -g ${pkg}@latest"
  elif [[ "$resolved" == */pnpm/global/*node_modules/* || "$bin_path" == */pnpm/* ]]; then
    method="pnpm"
    local parsed
    parsed="$(_afk_harness_parse_node_modules "$resolved" "$default_npm")"
    pkg="${parsed%%|*}"
    prefix="${parsed#*|}"
    update_cmd="pnpm add -g ${pkg}@latest"
  elif [[ "$resolved" == */node_modules/* ]]; then
    method="npm"
    local parsed
    parsed="$(_afk_harness_parse_node_modules "$resolved" "$default_npm")"
    pkg="${parsed%%|*}"
    prefix="${parsed#*|}"
    if [[ -n "$prefix" && -f "$prefix/lib/node_modules/$pkg/package.json" ]]; then
      pkg_json="$prefix/lib/node_modules/$pkg/package.json"
    elif [[ -n "$prefix" && -f "$prefix/node_modules/$pkg/package.json" ]]; then
      pkg_json="$prefix/node_modules/$pkg/package.json"
    fi
    if [[ -n "$prefix" && "$prefix" != "/usr" && "$prefix" != "/usr/local" ]]; then
      update_cmd="npm install -g --prefix \"$prefix\" \"${pkg}@latest\""
    else
      update_cmd="npm install -g \"${pkg}@latest\""
    fi
  elif [[ "$resolved" == */uv/tools/* ]]; then
    method="uv"
    local after_uv="${resolved#*/uv/tools/}"
    pkg="${after_uv%%/*}"
    update_cmd="uv tool upgrade $pkg"
  elif [[ "$resolved" == */pipx/venvs/* ]]; then
    method="pipx"
    local after_px="${resolved#*/pipx/venvs/}"
    pkg="${after_px%%/*}"
    update_cmd="pipx upgrade $pkg"
  elif [[ "$bin_path" == */.cargo/bin/* || "$resolved" == */.cargo/bin/* ]]; then
    method="cargo"
    pkg="$name"
    update_cmd="cargo install $pkg"
  else
    method="self-managed"
    pkg="$name"
    prefix="$(dirname -- "$bin_path")"
    case "$name" in
      claude)   update_cmd="\"$bin_path\" update" ;;
      opencode) update_cmd="\"$bin_path\" upgrade" ;;
      agy)      update_cmd="\"$bin_path\" update" ;;
      grok)     update_cmd="\"$bin_path\" update" ;;
      devin)    update_cmd="\"$bin_path\" update" ;;
      codex)    update_cmd="\"$bin_path\" --upgrade" ;;
      pi)       update_cmd="\"$bin_path\" update" ;;
      *)        update_cmd="\"$bin_path\" update" ;;
    esac
  fi

  jq -cn \
    --arg m "$method" \
    --arg p "$pkg" \
    --arg pr "$prefix" \
    --arg uc "$update_cmd" \
    --arg pj "$pkg_json" \
    '{
      install_method: $m,
      package_name: $p,
      install_prefix: (if $pr == "" then null else $pr end),
      package_json: (if $pj == "" then null else $pj end),
      update_command: $uc
    }'
}

# Extract clean semantic version string from `--version` output or package.json
_afk_harness_extract_semver() {
  grep -Eo '[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._-]+)?' 2>/dev/null | head -n 1 || true
}

# Query latest upstream version when `--check-updates` is requested
_afk_harness_fetch_latest_version() {
  local method="$1" pkg="$2"
  case "$method" in
    npm|bun|pnpm)
      curl -fsSL --max-time 5 "https://registry.npmjs.org/${pkg}/latest" 2>/dev/null | jq -r '.version // empty' 2>/dev/null || true
      ;;
    homebrew)
      if command -v brew >/dev/null 2>&1; then
        brew info --json=v2 "$pkg" 2>/dev/null | jq -r '(.formulae[0].versions.stable // .casks[0].version // empty)' 2>/dev/null || true
      fi
      ;;
    *)
      case "$pkg" in
        opencode)
          curl -fsSL --max-time 5 "https://registry.npmjs.org/opencode-ai/latest" 2>/dev/null | jq -r '.version // empty' 2>/dev/null || true
          ;;
        claude)
          curl -fsSL --max-time 5 "https://registry.npmjs.org/@anthropic-ai/claude-code/latest" 2>/dev/null | jq -r '.version // empty' 2>/dev/null || true
          ;;
        *)
          printf ''
          ;;
      esac
      ;;
  esac
}

# afk_harness_inspect_auth_one <name> [<present_on_disk:true|false>]
# Checks non-secret credential presence & runtime auth-revocation signals for <name>.
# NEVER reads or prints secret tokens.
afk_harness_inspect_auth_one() {
  local name="$1" present="${2:-true}"
  local reauth_cmd
  reauth_cmd="$(_afk_harness_reauth_command "$name")"
  if [[ "$present" != "true" ]]; then
    jq -cn --arg cmd "$reauth_cmd" '{auth_state:"not_installed", signed_in:false, reason:null, reauth_command:$cmd}'
    return 0
  fi

  local sig_file="${AFK_ROUTER_SIGNALS_FILE:-$HOME/.config/afk/pool-signals.json}"
  local now_ep
  now_ep="$(date -u +%s)"
  local pool_id="" cred_file="" signed_in=false auth_state="signed_out" reason=""

  case "$name" in
    claude)
      pool_id="anthropic-max"
      cred_file="${AFK_CLAUDE_CREDS_FILE:-$HOME/.claude/.credentials.json}"
      if [[ -f "$cred_file" ]] && jq -e '(.claudeAiOauth.accessToken // .claudeAiOauth.refreshToken // "") != ""' "$cred_file" >/dev/null 2>&1; then
        signed_in=true
      fi
      ;;
    codex)
      pool_id="openai-plus"
      cred_file="${AFK_CODEX_AUTH_FILE:-$HOME/.codex/auth.json}"
      if [[ -f "$cred_file" ]] && jq -e '((.tokens.access_token // .tokens.refresh_token // .OPENAI_API_KEY // "") != "") or ((.tokens.account_id // "") != "")' "$cred_file" >/dev/null 2>&1; then
        signed_in=true
      fi
      ;;
    agy)
      pool_id="antigravity-pool"
      cred_file="$HOME/.gemini/antigravity-cli"
      if [[ -d "$cred_file" || -n "${AFK_HARNESS_BIN_DIR_OVERRIDE:-}" ]]; then
        signed_in=true
      fi
      ;;
    grok)
      pool_id="xai-grok"
      cred_file="${AFK_GROK_AUTH_FILE:-$HOME/.grok/auth.json}"
      if [[ -f "$cred_file" ]] && jq -e '(keys | length) > 0' "$cred_file" >/dev/null 2>&1; then
        signed_in=true
      fi
      ;;
    opencode)
      pool_id="opencode-free"
      cred_file="${AFK_OPENCODE_AUTH_FILE:-$HOME/.local/share/opencode/auth.json}"
      # OpenCode always exposes free tier even without OAuth; report authenticated
      signed_in=true
      ;;
    pi)
      pool_id="openai-plus"
      cred_file="${AFK_PI_AUTH_FILE:-$HOME/.pi/agent/auth.json}"
      if [[ -f "$cred_file" ]] && jq -e '(keys | length) > 0' "$cred_file" >/dev/null 2>&1; then
        signed_in=true
      fi
      ;;
    devin)
      pool_id="devin-pool"
      cred_file="${AFK_DEVIN_CREDS_FILE:-$HOME/.local/share/devin/credentials.toml}"
      if [[ -f "$cred_file" && -s "$cred_file" ]]; then
        signed_in=true
      fi
      ;;
  esac

  if [[ "$signed_in" == "true" ]]; then
    auth_state="authenticated"
  else
    auth_state="signed_out"
    reason="No active credentials found on disk"
  fi

  # Check if runtime signal recorded a 401 / token_revoked after credential file mtime
  if [[ -n "$pool_id" && -f "$sig_file" ]]; then
    local c_mtime=0
    if [[ -f "$cred_file" ]]; then
      c_mtime="$(stat -c %Y "$cred_file" 2>/dev/null || stat -f %m "$cred_file" 2>/dev/null || printf '0')"
    fi
    local sig_hit
    sig_hit="$(jq -r --arg pid "$pool_id" --argjson now "$now_ep" --argjson cm "$c_mtime" '
      (.pools[$pid] // null) as $s |
      if $s == null then empty
      else
        (($s.updated_epoch // null) // (if ($s.updated_at // null) != null then (($s.updated_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) // 0) else 0 end)) as $ue |
        (($s.degraded_reason // "") | ascii_downcase) as $lr |
        ($s.degraded_kind // (if ($lr | test("401|unauthorized|revoked|invalidated oauth|refresh token")) then "auth" else "other" end)) as $k |
        ($s.ttl_sec // 86400) as $ttl |
        if $k == "auth" and ($cm <= $ue) and (($now - $ue) < $ttl) then
          ($s.degraded_reason // "401 token_revoked")
        else empty end
      end
    ' "$sig_file" 2>/dev/null || true)"
    if [[ -n "$sig_hit" ]]; then
      signed_in=false
      auth_state="auth_revoked"
      reason="$sig_hit"
    fi
  fi

  jq -cn \
    --arg st "$auth_state" \
    --arg r "$reason" \
    --arg cmd "$reauth_cmd" \
    --argjson si "$signed_in" \
    '{
      auth_state: $st,
      signed_in: $si,
      reason: (if $r == "" then null else $r end),
      reauth_command: $cmd
    }'
}

# afk_harness_inspect_one <name> [<check_updates:true|false>]
afk_harness_inspect_one() {
  local name="$1" check_updates="${2:-false}"
  local os_name effort_dial
  os_name="$(_afk_harness_os)"
  effort_dial="$(_afk_harness_effort_dial "$name")"
  local bin_path=""
  bin_path="$(_afk_harness_locate_bin "$name" || true)"

  if [[ -z "$bin_path" ]]; then
    jq -cn \
      --arg n "$name" \
      --arg os "$os_name" \
      --argjson ed "$effort_dial" \
      '{
        harness: $n,
        os: $os,
        present_on_disk: false,
        healthy: false,
        needs_repair: false,
        health: "not_installed",
        auth_state: "not_installed",
        signed_in: false,
        reauth_command: null,
        binary_path: null,
        resolved_path: null,
        install_method: null,
        package_name: null,
        install_prefix: null,
        current_version: null,
        latest_version: null,
        update_available: false,
        update_command: null,
        effort_dial: $ed
      }'
    return 0
  fi

  local resolved origin method pkg prefix pkg_json update_cmd auth_info
  resolved="$(_afk_harness_realpath "$bin_path")"
  origin="$(afk_harness_classify_origin "$name" "$bin_path" "$resolved")"
  method="$(jq -r '.install_method' <<<"$origin")"
  pkg="$(jq -r '.package_name' <<<"$origin")"
  prefix="$(jq -r '.install_prefix // empty' <<<"$origin")"
  pkg_json="$(jq -r '.package_json // empty' <<<"$origin")"
  update_cmd="$(jq -r '.update_command' <<<"$origin")"
  auth_info="$(afk_harness_inspect_auth_one "$name" true)"

  local ver_out="" ver_rc=0 healthy=true needs_repair=false health="healthy" cur_ver=""
  ver_out="$("$bin_path" --version 2>&1)" || ver_rc=$?
  if (( ver_rc != 0 )); then
    healthy=false
    needs_repair=true
    local first_err
    first_err="$(printf '%s\n' "$ver_out" | grep -m1 -E 'Error:|Missing|cannot|not found' || printf 'exit_%s' "$ver_rc")"
    health="broken_binary (${first_err:0:90})"
    if [[ -n "$pkg_json" && -f "$pkg_json" ]]; then
      cur_ver="$(jq -r '.version // empty' "$pkg_json" 2>/dev/null || true)"
    fi
  else
    cur_ver="$(printf '%s\n' "$ver_out" | _afk_harness_extract_semver)"
  fi

  local latest_ver="" update_avail=false
  if [[ "$needs_repair" == "true" ]]; then
    update_avail=true
  fi
  if [[ "$check_updates" == "true" ]]; then
    latest_ver="$(_afk_harness_fetch_latest_version "$method" "$pkg")"
    if [[ -n "$latest_ver" && -n "$cur_ver" && "$latest_ver" != "$cur_ver" ]]; then
      update_avail=true
    fi
  fi

  jq -cn \
    --arg n "$name" \
    --arg os "$os_name" \
    --arg bp "$bin_path" \
    --arg rp "$resolved" \
    --arg m "$method" \
    --arg p "$pkg" \
    --arg pr "$prefix" \
    --arg cv "$cur_ver" \
    --arg lv "$latest_ver" \
    --arg uc "$update_cmd" \
    --arg hl "$health" \
    --argjson ok "$healthy" \
    --argjson nr "$needs_repair" \
    --argjson ua "$update_avail" \
    --argjson au "$auth_info" \
    --argjson ed "$effort_dial" \
    '{
      harness: $n,
      os: $os,
      present_on_disk: true,
      healthy: $ok,
      needs_repair: $nr,
      health: $hl,
      auth_state: $au.auth_state,
      signed_in: $au.signed_in,
      auth_reason: $au.reason,
      reauth_command: $au.reauth_command,
      binary_path: $bp,
      resolved_path: $rp,
      install_method: $m,
      package_name: $p,
      install_prefix: (if $pr == "" then null else $pr end),
      current_version: (if $cv == "" then null else $cv end),
      latest_version: (if $lv == "" then null else $lv end),
      update_available: $ua,
      update_command: $uc,
      effort_dial: $ed
    }'
}

# afk_harness_inspect_all [<check_updates:true|false>]
afk_harness_inspect_all() {
  local check_updates="${1:-false}"
  local os_name list="[]" h item
  os_name="$(_afk_harness_os)"
  for h in claude codex agy grok opencode pi devin; do
    item="$(afk_harness_inspect_one "$h" "$check_updates")"
    list="$(jq -c --argjson it "$item" '. + [$it]' <<<"$list")"
  done
  jq -cn \
    --arg os "$os_name" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson items "$list" \
    '{
      schema: "afk-harnesses/2",
      os: $os,
      checked_at: $ts,
      auth_alerts: [
        $items[] | select(.present_on_disk == true and .healthy == true and (.signed_in == false)) |
        {harness: .harness, auth_state: .auth_state, reason: .auth_reason, reauth_command: .reauth_command}
      ],
      harnesses: $items
    }'
}

# afk_harness_update <target_harness|all> [<dry_run:true|false>]
# Updates one or all installed harnesses via their detected install method,
# then automatically refreshes the live harness model catalog + public benchmarks.
afk_harness_update() {
  local target="${1:-all}" dry_run="${2:-false}"
  local -a names=()
  if [[ "$target" == "all" ]]; then
    names=(claude codex agy grok opencode pi devin)
  else
    IFS=, read -r -a names <<<"$target"
  fi

  local results="[]" updated_any=false h info present cmd before_ver after_ver rc out status_str
  for h in "${names[@]}"; do
    [[ -n "$h" ]] || continue
    info="$(afk_harness_inspect_one "$h" true)"
    present="$(jq -r '.present_on_disk' <<<"$info")"
    if [[ "$present" != "true" ]]; then
      results="$(jq -c --arg h "$h" '. + [{harness:$h, action:"skipped", reason:"not_installed"}]' <<<"$results")"
      continue
    fi
    cmd="$(jq -r '.update_command // empty' <<<"$info")"
    before_ver="$(jq -r '.current_version // "unknown"' <<<"$info")"
    if [[ "$dry_run" == "true" ]]; then
      results="$(jq -c --arg h "$h" --arg c "$cmd" --arg bv "$before_ver" --arg m "$(jq -r '.install_method' <<<"$info")" \
        '. + [{harness:$h, action:"dry_run", install_method:$m, before_version:$bv, command:$c}]' <<<"$results")"
      continue
    fi

    rc=0
    out="$(bash -c "$cmd" 2>&1)" || rc=$?
    local post_info post_ok
    post_info="$(afk_harness_inspect_one "$h" false)"
    after_ver="$(jq -r '.current_version // "unknown"' <<<"$post_info")"
    post_ok="$(jq -r '.healthy' <<<"$post_info")"
    if (( rc == 0 )) && [[ "$post_ok" == "true" ]]; then
      status_str="updated"
      updated_any=true
    else
      status_str="failed"
    fi
    results="$(jq -c \
      --arg h "$h" \
      --arg st "$status_str" \
      --arg m "$(jq -r '.install_method' <<<"$info")" \
      --arg c "$cmd" \
      --arg bv "$before_ver" \
      --arg av "$after_ver" \
      --argjson ok "$post_ok" \
      --arg note "${out:0:200}" \
      '. + [{harness:$h, action:$st, install_method:$m, before_version:$bv, after_version:$av, healthy:$ok, command:$c, output_excerpt:$note}]' <<<"$results")"
  done

  local model_sync_summary=null
  if [[ "$dry_run" != "true" && "$updated_any" == "true" ]]; then
    if declare -F afk_router_sync_benchmarks >/dev/null 2>&1; then
      afk_router_sync_benchmarks >/dev/null 2>&1 || true
    fi
    local ms
    ms="$(afk_harness_sync_models)"
    model_sync_summary="$(jq -c '{total_models: .summary.total_models, free_models: .summary.free_models, subscription_models: .summary.subscription_models}' <<<"$ms" 2>/dev/null || printf 'null')"
  fi

  jq -cn \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson dry "$dry_run" \
    --argjson res "$results" \
    --argjson ms "$model_sync_summary" \
    '{schema: "afk-harness-update/1", updated_at: $ts, dry_run: $dry, results: $res, model_catalog_refresh: $ms}'
}

# afk_harness_probe_account_bindings
# Inspects non-secret auth metadata across installed harnesses so AFK knows WHICH
# account & subscription pool backs each harness+provider pair (e.g., OpenCode or
# Pi authenticated via OpenAI Codex OAuth shares `openai-plus` with `codex`, and
# native `grok` CLI shares `xai-grok` with xAI OAuth!).
# NEVER outputs secret keys or tokens — only auth_type and 12-hex SHA-256 account_id hash.
afk_harness_probe_account_bindings() {
  local codex_auth="${AFK_CODEX_AUTH_FILE:-$HOME/.codex/auth.json}"
  local opencode_auth="${AFK_OPENCODE_AUTH_FILE:-$HOME/.local/share/opencode/auth.json}"
  local pi_auth="${AFK_PI_AUTH_FILE:-$HOME/.pi/agent/auth.json}"
  local claude_creds="${AFK_CLAUDE_CREDS_FILE:-$HOME/.claude/.credentials.json}"
  local grok_auth="${AFK_GROK_AUTH_FILE:-}"
  if [[ -z "$grok_auth" && -z "${AFK_OPENCODE_AUTH_FILE:-}" && -z "${AFK_HARNESS_BIN_DIR_OVERRIDE:-}" ]]; then
    grok_auth="$HOME/.grok/auth.json"
  fi

  local bindings="[]"

  # 1. Claude native OAuth
  if [[ -f "$claude_creds" || -d "$HOME/.claude" ]]; then
    local c_sub="max"
    if [[ -f "$claude_creds" ]]; then
      c_sub="$(jq -r '.claudeAiOauth.subscriptionType // "max"' "$claude_creds" 2>/dev/null || printf 'max')"
    fi
    bindings="$(jq -c --arg st "$c_sub" '. + [{
      harness: "claude",
      provider: "anthropic",
      auth_type: "oauth",
      cost_class: "subscription",
      entitlement_pool: "anthropic-max",
      account_fingerprint: ("anthropic-oauth:" + $st)
    }]' <<<"$bindings")"
  fi

  # 2. Codex native OpenAI OAuth
  local openai_acct_fp=""
  if [[ -f "$codex_auth" ]]; then
    local raw_cid c_mode
    c_mode="$(jq -r '.auth_mode // "oauth"' "$codex_auth" 2>/dev/null || printf 'oauth')"
    raw_cid="$(jq -r '(.tokens.account_id // .account_id // empty)' "$codex_auth" 2>/dev/null || true)"
    if [[ -n "$raw_cid" ]]; then
      openai_acct_fp="openai-acct:$(_afk_harness_hash12 "$raw_cid")"
    else
      openai_acct_fp="openai-oauth:primary"
    fi
    bindings="$(jq -c --arg m "$c_mode" --arg fp "$openai_acct_fp" '. + [{
      harness: "codex",
      provider: "openai",
      auth_type: $m,
      cost_class: (if $m == "api" then "api-metered" else "subscription" end),
      entitlement_pool: (if $m == "api" then "api-metered" else "openai-plus" end),
      account_fingerprint: $fp
    }]' <<<"$bindings")"
  fi

  # 3. Antigravity native subscription pool
  if _afk_harness_locate_bin agy >/dev/null 2>&1; then
    bindings="$(jq -c '. + [{
      harness: "agy",
      provider: "antigravity",
      auth_type: "oauth",
      cost_class: "subscription",
      entitlement_pool: "antigravity-pool",
      account_fingerprint: "agy-oauth:primary"
    }]' <<<"$bindings")"
  fi

  # 4. Grok native CLI subscription (`~/.grok/auth.json` key name `https://auth.x.ai::<uuid>`)
  local xai_acct_fp=""
  if [[ -n "$grok_auth" && -f "$grok_auth" ]] && jq -e '(keys | length) > 0' "$grok_auth" >/dev/null 2>&1; then
    local raw_xkey raw_xuid
    raw_xkey="$(jq -r 'keys[0] // empty' "$grok_auth" 2>/dev/null || true)"
    if [[ "$raw_xkey" == *"::"* ]]; then
      raw_xuid="${raw_xkey#*::}"
      xai_acct_fp="xai-acct:$(_afk_harness_hash12 "$raw_xuid")"
    else
      xai_acct_fp="xai-oauth:primary"
    fi
    bindings="$(jq -c --arg fp "$xai_acct_fp" '. + [{
      harness: "grok",
      provider: "xai",
      auth_type: "oauth",
      cost_class: "subscription",
      entitlement_pool: "xai-grok",
      account_fingerprint: $fp
    }]' <<<"$bindings")"
  fi

  # 5. OpenCode multi-provider credentials (free + bridged subscriptions + metered APIs)
  if _afk_harness_locate_bin opencode >/dev/null 2>&1 || [[ -f "$opencode_auth" ]]; then
    bindings="$(jq -c '. + [{
      harness: "opencode",
      provider: "opencode",
      auth_type: "free-tier",
      cost_class: "free",
      entitlement_pool: "opencode-free",
      account_fingerprint: "opencode:free"
    }]' <<<"$bindings")"

    if [[ -f "$opencode_auth" ]]; then
      local -a oc_rows=()
      mapfile -t oc_rows < <(jq -r 'to_entries[] | "\(.key)|\(.value.type // "api")|\(.value.accountId // .value.account_id // "")"' "$opencode_auth" 2>/dev/null || true)
      local row prov atype raw_aid fp pool cclass
      for row in "${oc_rows[@]:-}"; do
        [[ -n "$row" ]] || continue
        prov="${row%%|*}"
        local rest="${row#*|}"
        atype="${rest%%|*}"
        raw_aid="${rest#*|}"
        if [[ "$atype" == "oauth" ]]; then
          cclass="subscription"
          case "$prov" in
            openai|codex|openai-codex)
              pool="openai-plus"
              if [[ -n "$raw_aid" ]]; then
                fp="openai-acct:$(_afk_harness_hash12 "$raw_aid")"
              elif [[ -n "$openai_acct_fp" ]]; then
                fp="$openai_acct_fp"
              else
                fp="openai-oauth:primary"
              fi
              ;;
            anthropic)
              pool="anthropic-max"
              fp="anthropic-oauth:shared"
              ;;
            google|gemini)
              pool="antigravity-pool"
              fp="google-oauth:shared"
              ;;
            xai|grok)
              pool="xai-grok"
              if [[ -n "$raw_aid" ]]; then
                fp="xai-acct:$(_afk_harness_hash12 "$raw_aid")"
              elif [[ -n "$xai_acct_fp" ]]; then
                fp="$xai_acct_fp"
              else
                fp="xai-oauth:primary"
              fi
              ;;
            *)
              pool="xai-grok"
              fp="${prov}-oauth:shared"
              ;;
          esac
        else
          cclass="api-metered"
          pool="api-metered"
          fp="${prov}-api:metered"
        fi
        bindings="$(jq -c \
          --arg p "$prov" \
          --arg at "$atype" \
          --arg cc "$cclass" \
          --arg pl "$pool" \
          --arg fp "$fp" \
          '. + [{
            harness: "opencode",
            provider: $p,
            auth_type: $at,
            cost_class: $cc,
            entitlement_pool: $pl,
            account_fingerprint: $fp
          }]' <<<"$bindings")"
      done
    fi
  fi

  # 6. Pi coding agent multi-provider credentials (when ~/.pi/agent/auth.json exists)
  if [[ -f "$pi_auth" ]]; then
    local -a pi_rows=()
    mapfile -t pi_rows < <(jq -r 'to_entries[] | "\(.key)|\(.value.type // "oauth")|\(.value.accountId // .value.account_id // "")"' "$pi_auth" 2>/dev/null || true)
    local prow pprov patype praw pfp ppool pcclass
    for prow in "${pi_rows[@]:-}"; do
      [[ -n "$prow" ]] || continue
      pprov="${prow%%|*}"
      local prest="${prow#*|}"
      patype="${prest%%|*}"
      praw="${prest#*|}"
      if [[ "$patype" == "oauth" ]]; then
        pcclass="subscription"
        case "$pprov" in
          openai*|codex*)
            ppool="openai-plus"
            pfp="${praw:+openai-acct:$(_afk_harness_hash12 "$praw")}"
            [[ -n "$pfp" ]] || pfp="${openai_acct_fp:-openai-oauth:primary}"
            ;;
          anthropic*)
            ppool="anthropic-max"
            pfp="anthropic-oauth:shared"
            ;;
          xai*|grok*)
            ppool="xai-grok"
            pfp="${praw:+xai-acct:$(_afk_harness_hash12 "$praw")}"
            [[ -n "$pfp" ]] || pfp="${xai_acct_fp:-xai-oauth:primary}"
            ;;
          *)
            ppool="xai-grok"
            pfp="${pprov}-oauth:shared"
            ;;
        esac
      else
        pcclass="api-metered"
        ppool="api-metered"
        pfp="${pprov}-api:metered"
      fi
      bindings="$(jq -c \
        --arg p "$pprov" \
        --arg at "$patype" \
        --arg cc "$pcclass" \
        --arg pl "$ppool" \
        --arg fp "$pfp" \
        '. + [{
          harness: "pi",
          provider: $p,
          auth_type: $at,
          cost_class: $cc,
          entitlement_pool: $pl,
          account_fingerprint: $fp
        }]' <<<"$bindings")"
    done
  fi

  printf '%s\n' "$bindings"
}

# afk_harness_sync_models
# Queries live models + supported reasoning effort dials across installed harnesses,
# joins them with account/pool bindings and public benchmark scores, classifies FREE
# vs OAuth Subscription vs Metered API models + task purposes (including security &
# frontier synthesis), and writes ~/.config/afk/discovered-models.json.
afk_harness_sync_models() {
  local dest cat_path bindings
  dest="$(afk_harness_discovered_models_path)"
  mkdir -p "$(dirname -- "$dest")"
  if declare -F afk_router_catalog_path >/dev/null 2>&1; then
    cat_path="$(afk_router_catalog_path)"
  else
    cat_path="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/files/model-router/benchmarks.json"
  fi
  bindings="$(afk_harness_probe_account_bindings)"

  local tmp_oc tmp_agy tmp_grok tmp_codex
  tmp_oc="$(mktemp "${TMPDIR:-/tmp}/afk-oc-models.XXXXXX")"
  tmp_agy="$(mktemp "${TMPDIR:-/tmp}/afk-agy-models.XXXXXX")"
  tmp_grok="$(mktemp "${TMPDIR:-/tmp}/afk-grok-models.XXXXXX")"
  tmp_codex="$(mktemp "${TMPDIR:-/tmp}/afk-codex-models.XXXXXX")"
  printf '[]' > "$tmp_oc"
  printf '[]' > "$tmp_agy"
  printf '[]' > "$tmp_grok"
  printf '[]' > "$tmp_codex"

  # 1. Discover live OpenCode models (free tier + authenticated providers) with exact cost & capability metadata
  local oc_bin=""
  if [[ -n "${AFK_OPENCODE_MODELS_FIXTURE:-}" && -f "${AFK_OPENCODE_MODELS_FIXTURE}" ]]; then
    awk '/^[A-Za-z0-9_.-]+\// { next } { print }' "$AFK_OPENCODE_MODELS_FIXTURE" | jq -cs '.' > "$tmp_oc" 2>/dev/null || printf '[]' > "$tmp_oc"
  else
    oc_bin="$(_afk_harness_locate_bin opencode || true)"
    if [[ -n "$oc_bin" ]] && "$oc_bin" --version >/dev/null 2>&1; then
      local -a oc_provs=("opencode")
      local p
      while IFS= read -r p; do
        [[ -n "$p" && "$p" != "opencode" ]] && oc_provs+=("$p")
      done < <(jq -r '.[] | select(.harness == "opencode") | .provider' <<<"$bindings" 2>/dev/null)

      local combined="[]" prov_json
      for p in "${oc_provs[@]}"; do
        prov_json="$("$oc_bin" models "$p" --verbose 2>/dev/null | awk '/^[A-Za-z0-9_.-]+\// { next } { print }' | jq -cs '.' 2>/dev/null || printf '[]')"
        combined="$(jq -cs '.[0] + .[1]' <(printf '%s' "$combined") <(printf '%s' "$prov_json"))"
      done
      printf '%s\n' "$combined" > "$tmp_oc"
    fi
  fi

  # 2. Discover live Antigravity (`agy models`) entries + effort levels when agy is healthy
  local agy_bin=""
  if [[ -n "${AFK_AGY_MODELS_FIXTURE:-}" && -f "${AFK_AGY_MODELS_FIXTURE}" ]]; then
    tr '\r' '\n' < "$AFK_AGY_MODELS_FIXTURE" | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g; s/^[[:space:]]+//' | awk 'NF >= 2 && $1 ~ /^[a-z0-9][a-z0-9._-]+$/ { id=$1; $1=""; sub(/^[[:space:]]+/, ""); gsub(/"/, "\\\"", $0); printf "{\"id\":\"%s\",\"name\":\"%s\"}\n", id, $0 }' | jq -cs '.' > "$tmp_agy" 2>/dev/null || printf '[]' > "$tmp_agy"
  else
    agy_bin="$(_afk_harness_locate_bin agy || true)"
    if [[ -n "$agy_bin" ]] && "$agy_bin" --version >/dev/null 2>&1; then
      "$agy_bin" models 2>/dev/null | tr '\r' '\n' | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g; s/^[[:space:]]+//' | awk 'NF >= 2 && $1 ~ /^[a-z0-9][a-z0-9._-]+$/ { id=$1; $1=""; sub(/^[[:space:]]+/, ""); gsub(/"/, "\\\"", $0); printf "{\"id\":\"%s\",\"name\":\"%s\"}\n", id, $0 }' | jq -cs '.' > "$tmp_agy" 2>/dev/null || printf '[]' > "$tmp_agy"
    fi
  fi

  # 3. Discover live Grok CLI models + per-model reasoning_efforts (`~/.grok/models_cache.json` or `grok models`)
  local grok_cache="${AFK_GROK_MODELS_FIXTURE:-${AFK_GROK_MODELS_CACHE:-}}"
  if [[ -z "$grok_cache" && -z "${AFK_OPENCODE_MODELS_FIXTURE:-}" && -z "${AFK_HARNESS_BIN_DIR_OVERRIDE:-}" ]]; then
    grok_cache="$HOME/.grok/models_cache.json"
  fi
  if [[ -n "$grok_cache" && -f "$grok_cache" ]]; then
    jq -c '
      def erank($e): if $e=="low" then 1 elif $e=="medium" then 2 elif $e=="high" then 3 elif $e=="xhigh" then 4 else 5 end;
      [
        (if (.models | type) == "array" then .models[] else (.models | to_entries[]? | (.value.info // .value)) end)
        | select((.hidden // false) == false)
        | {
            id: .id,
            name: (.name // .id),
            description: (.description // ""),
            context_window: ((.context_windows // [.max_context_window // .context_window // 256000]) | max),
            default_effort: (.reasoning_effort // .default_reasoning_effort // "high"),
            supported_efforts: (
              ([.reasoning_efforts[]? | if type == "object" then .value else . end] | unique | sort_by(erank(.)))
              | if length > 0 then . else ["low","medium","high","xhigh"] end
            )
          }
      ]
    ' "$grok_cache" > "$tmp_grok" 2>/dev/null || printf '[]' > "$tmp_grok"
  elif [[ -z "${AFK_OPENCODE_MODELS_FIXTURE:-}" && -z "${AFK_HARNESS_BIN_DIR_OVERRIDE:-}" ]]; then
    local grok_bin=""
    grok_bin="$(_afk_harness_locate_bin grok || true)"
    if [[ -n "$grok_bin" ]] && "$grok_bin" --version >/dev/null 2>&1; then
      "$grok_bin" models 2>/dev/null | sed -nE 's/^[[:space:]]*[-*][[:space:]]+([A-Za-z0-9._-]+).*$/\1/p' | awk '{printf "{\"id\":\"%s\",\"name\":\"%s\",\"context_window\":500000,\"default_effort\":\"high\",\"supported_efforts\":[\"low\",\"medium\",\"high\",\"xhigh\"]}\n", $1, $1}' | jq -cs '.' > "$tmp_grok" 2>/dev/null || printf '[]' > "$tmp_grok"
    fi
  fi

  # 4. Discover live Codex models + per-model supported_reasoning_levels (`~/.codex/models_cache.json`)
  local codex_cache="${AFK_CODEX_MODELS_FIXTURE:-${AFK_CODEX_MODELS_CACHE:-}}"
  if [[ -z "$codex_cache" && -z "${AFK_OPENCODE_MODELS_FIXTURE:-}" && -z "${AFK_HARNESS_BIN_DIR_OVERRIDE:-}" ]]; then
    codex_cache="$HOME/.codex/models_cache.json"
  fi
  if [[ -n "$codex_cache" && -f "$codex_cache" ]]; then
    jq -c '
      def erank($e): if $e=="low" then 1 elif $e=="medium" then 2 elif $e=="high" then 3 elif $e=="xhigh" then 4 else 5 end;
      [.models[]? | {
        id: (.slug // .id),
        name: (.display_name // .name // .slug // .id),
        context_window: (.context_window // 400000),
        default_effort: (.default_reasoning_level // "high"),
        supported_efforts: (
          ([.supported_reasoning_levels[]? | if type == "object" then .effort else . end] | unique | sort_by(erank(.)))
          | if length > 0 then . else ["low","medium","high","xhigh"] end
        )
      }]
    ' "$codex_cache" > "$tmp_codex" 2>/dev/null || printf '[]' > "$tmp_codex"
  fi

  local harnesses_info
  harnesses_info="$(afk_harness_inspect_all false)"

  jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --slurpfile cat "$cat_path" \
    --slurpfile oc "$tmp_oc" \
    --slurpfile agy "$tmp_agy" \
    --slurpfile grk "$tmp_grok" \
    --slurpfile cdx "$tmp_codex" \
    --argjson bind "$bindings" \
    --argjson hinfo "$harnesses_info" \
    '
    def infer_family($prov; $id):
      ($id | ascii_downcase) as $lid |
      if ($lid | test("claude|fable|mythos")) or $prov == "anthropic" then "anthropic"
      elif ($lid | test("gpt|codex|daybreak|o1|o3|o4")) or $prov == "openai" then "openai"
      elif ($lid | test("gemini")) or $prov == "google" then "google"
      elif ($lid | test("grok")) or $prov == "xai" then "xai"
      elif ($lid | test("deepseek")) then "deepseek"
      elif ($lid | test("glm")) then "zhipu"
      elif ($lid | test("minimax")) then "minimax"
      elif ($lid | test("nemotron")) then "nvidia"
      else $prov end;

    # Estimate benchmark profile for newly discovered / free / specialist models
    def score_discovered($id; $fam; $cost_class; $reasoning; $toolcall; $vision; $ctx):
      ($id | ascii_downcase) as $lid |
      ([ $cat[0].candidates[]? | select(
          (.canonical_model | ascii_downcase | endswith("/" + $lid)) or
          (($lid | test("claude-mythos")) and (.canonical_model == "anthropic/claude-mythos-5-2")) or
          (($lid | test("daybreak-blue")) and (.canonical_model == "openai/gpt-daybreak-blue-latest")) or
          (($lid | test("claude-fable")) and (.canonical_model == "anthropic/claude-fable-5-1")) or
          (($lid | test("gpt-6\\.1-sol")) and (.canonical_model == "openai/gpt-6.1-sol")) or
          (($lid | test("gpt-6-astra")) and (.canonical_model == "openai/gpt-6-astra")) or
          (($lid | test("claude-opus-5-5")) and (.canonical_model == "anthropic/claude-opus-5-5")) or
          (($lid | test("claude-sonnet-5-5")) and (.canonical_model == "anthropic/claude-sonnet-5-5")) or
          (($lid | test("gemini-4-carbon")) and (.canonical_model == "google/gemini-4-carbon")) or
          (($lid | test("^grok-4\\.7")) and (.canonical_model == "xai/grok-4.7"))
        ) ][0]) as $known |
      if $known != null then
        {
          benchmarks: $known.benchmarks,
          recommended_purposes: (
            (if ($known.specialist_domain // "") == "security" then ["security-audit","threat-modeling","review-security","cve-triage"] else [] end) +
            (if ($known.frontier_only // false) == true then ["frontier-synthesis","critical-architecture"] else [] end) +
            (if ($known.benchmarks.architecture.score // 0) >= 92 then ["architecture","spec","bmad-pm"] else [] end) +
            (if ($known.benchmarks.coding_standard.score // 0) >= 90 then ["build","coding"] else [] end) +
            (if ($known.benchmarks.coding_review.score // 0) >= 90 then ["review-code"] else [] end) +
            (if ($known.benchmarks.research.score // 0) >= 90 then ["intake","research"] else [] end) +
            (if ($known.benchmarks.webdev.score // 0) >= 92 then ["ux","webdev"] else [] end)
          ),
          evaluation_source: "public_benchmark_match"
        }
      else
        (if ($lid | test("grok-4\\.6")) then 91.0
         elif ($lid | test("grok-4\\.5")) then 89.5
         elif ($lid | test("glm-5")) then 90.5
         elif ($lid | test("deepseek-v4")) then 88.5
         elif ($lid | test("minimax-m3")) then 88.0
         elif ($lid | test("nemotron-3\\.5-super")) then 85.0
         elif ($lid | test("mimo-v2")) then 84.5
         elif ($lid | test("gemini-4-argon|gemini-3\\.8-flash")) then 89.0
         elif ($lid | test("gpt-5\\.")) then 88.0
         elif $reasoning and $toolcall then 82.0
         elif $toolcall then 78.0
         else 70.0 end) as $base |
        {
          benchmarks: {
            research:           {score: (if $ctx >= 500000 then ($base + 1.0) else $base end), source: "Dynamic Capability + Open-Weights Eval"},
            architecture:       {score: (if $reasoning then $base else ($base - 6.0) end), source: "Dynamic Capability + Open-Weights Eval"},
            frontier_synthesis: {score: (if $reasoning then ($base - 1.0) else ($base - 10.0) end), source: "Dynamic Capability + Open-Weights Eval"},
            webdev:             {score: (if $vision then ($base + 1.0) else ($base - 2.0) end), source: "Dynamic Capability + Open-Weights Eval"},
            coding_standard:    {score: (if $toolcall then $base else ($base - 12.0) end), source: "Dynamic Capability + Open-Weights Eval"},
            coding_complex:     {score: (if $reasoning and $toolcall then ($base - 1.5) else ($base - 12.0) end), source: "Dynamic Capability + Open-Weights Eval"},
            coding_review:      {score: (if $reasoning then ($base - 1.0) else ($base - 8.0) end), source: "Dynamic Capability + Open-Weights Eval"},
            security:           {score: (if $reasoning then ($base - 1.5) else ($base - 10.0) end), source: "Dynamic Capability + Open-Weights Eval"}
          },
          recommended_purposes: (
            (if $cost_class == "free" and $toolcall then ["intake","low-risk-build","triage","pool-conservation"]
             elif $toolcall and $reasoning then ["intake","build","review-code"]
             elif $reasoning then ["intake","research"]
             else ["summarization"] end) +
            (if $vision then ["multimodal-ux"] else [] end)
          ),
          evaluation_source: "capability_and_family_eval"
        }
      end;

    # 1. OpenCode discovered entries
    ([
      $oc[0][]? |
      select((.status // "active") == "active") |
      . as $m |
      ($m.providerID // "opencode") as $prov |
      ([ $bind[] | select(.harness == "opencode" and .provider == $prov) ][0] // {
        auth_type: (if (($m.cost.input // 0) == 0 and ($m.cost.output // 0) == 0) then "free-tier" else "api" end),
        cost_class: (if (($m.cost.input // 0) == 0 and ($m.cost.output // 0) == 0) then "free" else "api-metered" end),
        entitlement_pool: (if (($m.cost.input // 0) == 0 and ($m.cost.output // 0) == 0) then "opencode-free" else "api-metered" end),
        account_fingerprint: "opencode:unauthenticated"
      }) as $b |
      (if $b.cost_class == "subscription" then "subscription"
       elif (($m.cost.input // 0) == 0 and ($m.cost.output // 0) == 0) then "free"
       else $b.cost_class end) as $cclass |
      (if $cclass == "free" then "opencode-free" else $b.entitlement_pool end) as $pool |
      infer_family($prov; $m.id) as $fam |
      ($m.capabilities.reasoning // false) as $reas |
      ($m.capabilities.toolcall // false) as $tc |
      ($m.capabilities.input.image // false) as $vis |
      ($m.limit.context // 128000) as $ctx |
      score_discovered($m.id; $fam; $cclass; $reas; $tc; $vis; $ctx) as $ev |
      {
        id: ("opencode:" + $prov + "/" + $m.id),
        harness: "opencode",
        launch_class: "opencode-native",
        provider: $prov,
        model: ($prov + "/" + $m.id),
        canonical_model: ($fam + "/" + $m.id),
        display_name: ($m.name // ($prov + "/" + $m.id)),
        model_family: $fam,
        auth_type: $b.auth_type,
        cost_class: $cclass,
        is_free: ($cclass == "free"),
        cost_per_1m_usd: {
          input: ($m.cost.input // 0),
          output: ($m.cost.output // 0)
        },
        entitlement_pool: $pool,
        account_fingerprint: $b.account_fingerprint,
        window_tokens: $ctx,
        effort_flag: "--variant",
        supported_efforts: (if $reas then ["low","medium","high"] else ["medium"] end),
        capabilities: {
          reasoning: $reas,
          toolcall: $tc,
          vision: $vis
        },
        recommended_purposes: $ev.recommended_purposes,
        evaluation_source: $ev.evaluation_source,
        benchmarks: $ev.benchmarks
      }
    ]) as $oc_models |

    # 2. Antigravity (`agy models`) discovered entries (computing exact supported_efforts per base model)
    (($agy[0] // []) | map({base: (.id | sub("-(high|medium|low)$"; "")), eff: (if (.id | test("-(high|medium|low)$")) then (.id | capture("-(?<e>high|medium|low)$").e) else "medium" end)})) as $agy_eff_pairs |
    ([
      $agy[0][]? |
      select((.id | endswith("-low") or endswith("-medium")) | not) |
      . as $am |
      ($am.id | sub("-(high|medium|low)$"; "")) as $base_id |
      (([ $agy_eff_pairs[] | select(.base == $base_id) | .eff ] + ["xhigh","max"]) | unique) as $sup_eff |
      infer_family("antigravity"; $base_id) as $fam |
      score_discovered($base_id; $fam; "subscription"; true; true; true; 1048576) as $ev |
      {
        id: ("agy:" + $am.id),
        harness: "agy",
        launch_class: "agy-native",
        provider: "antigravity",
        model: $am.id,
        canonical_model: ($fam + "/" + $base_id),
        display_name: $am.name,
        model_family: $fam,
        auth_type: "oauth",
        cost_class: "subscription",
        is_free: false,
        cost_per_1m_usd: {input: 0, output: 0},
        entitlement_pool: "antigravity-pool",
        account_fingerprint: "agy-oauth:primary",
        window_tokens: 1048576,
        effort_flag: "--effort",
        supported_efforts: $sup_eff,
        capabilities: {reasoning: true, toolcall: true, vision: true},
        recommended_purposes: $ev.recommended_purposes,
        evaluation_source: $ev.evaluation_source,
        benchmarks: $ev.benchmarks
      }
    ]) as $agy_models |

    # 3. Native Grok CLI (`grok models` / `~/.grok/models_cache.json`) discovered entries
    (([ $bind[] | select(.harness == "grok") ][0]) // null) as $grok_bind |
    ([
      $grk[0][]? |
      . as $gm |
      score_discovered($gm.id; "xai"; "subscription"; true; true; true; ($gm.context_window // 500000)) as $ev |
      {
        id: ("grok:" + $gm.id),
        harness: "grok",
        launch_class: "grok-native",
        provider: "xai",
        model: $gm.id,
        canonical_model: ("xai/" + $gm.id),
        display_name: ($gm.name // $gm.id),
        model_family: "xai",
        auth_type: ($grok_bind.auth_type // "oauth"),
        cost_class: "subscription",
        is_free: false,
        cost_per_1m_usd: {input: 0, output: 0},
        entitlement_pool: "xai-grok",
        account_fingerprint: ($grok_bind.account_fingerprint // "xai:unauthenticated"),
        window_tokens: ($gm.context_window // 500000),
        effort_flag: "--effort",
        supported_efforts: ($gm.supported_efforts // ["low","medium","high","xhigh"]),
        capabilities: {reasoning: true, toolcall: true, vision: true},
        recommended_purposes: $ev.recommended_purposes,
        evaluation_source: $ev.evaluation_source,
        benchmarks: $ev.benchmarks
      }
    ]) as $grok_models |

    # 4. Native Codex CLI (`~/.codex/models_cache.json`) effort-dial inventory
    (([ $bind[] | select(.harness == "codex") ][0]) // null) as $codex_bind |
    ([
      $cdx[0][]? |
      select((.id | test("^codex-auto-review$|^gpt-reserve$")) | not) |
      . as $cm |
      score_discovered($cm.id; "openai"; ($codex_bind.cost_class // "subscription"); true; true; true; ($cm.context_window // 1000000)) as $ev |
      {
        id: ("codex:" + $cm.id),
        harness: "codex",
        launch_class: "codex-native",
        provider: "openai",
        model: $cm.id,
        canonical_model: ("openai/" + $cm.id),
        display_name: ($cm.name // $cm.id),
        model_family: "openai",
        auth_type: ($codex_bind.auth_type // "oauth"),
        cost_class: ($codex_bind.cost_class // "subscription"),
        is_free: false,
        cost_per_1m_usd: {input: 0, output: 0},
        entitlement_pool: ($codex_bind.entitlement_pool // "openai-plus"),
        account_fingerprint: ($codex_bind.account_fingerprint // "openai:unauthenticated"),
        window_tokens: ($cm.context_window // 1000000),
        effort_flag: "-c model_reasoning_effort=<level>",
        supported_efforts: ($cm.supported_efforts // ["low","medium","high","xhigh","max"]),
        capabilities: {reasoning: true, toolcall: true, vision: true},
        recommended_purposes: $ev.recommended_purposes,
        evaluation_source: $ev.evaluation_source,
        benchmarks: $ev.benchmarks
      }
    ]) as $codex_models |

    ($oc_models + $agy_models + $grok_models + $codex_models) as $all_discovered |

    # Summarize shared pools where multiple harnesses share the same account/subscription!
    (
      $bind
      | group_by(.entitlement_pool)
      | map({
          entitlement_pool: .[0].entitlement_pool,
          cost_class: .[0].cost_class,
          account_fingerprints: (map(.account_fingerprint) | unique),
          harnesses_feeding_pool: (map(.harness) | unique),
          shared_across_harnesses: ((map(.harness) | unique | length) > 1)
        })
    ) as $shared_pools |

    {
      schema: "afk-discovered-models/2",
      synced_at: $ts,
      account_bindings: $bind,
      shared_pool_topology: $shared_pools,
      harness_effort_dials: (
        [
          $hinfo.harnesses[] | select(.present_on_disk == true) |
          {
            key: .harness,
            value: {
              auth_state: .auth_state,
              supports_effort: .effort_dial.supports_effort,
              cli_flag: .effort_dial.cli_flag,
              supported_efforts: .effort_dial.supported_efforts
            }
          }
        ] | from_entries
      ),
      summary: {
        total_models: ($all_discovered | length),
        free_models: ([ $all_discovered[] | select(.is_free == true) ] | length),
        subscription_models: ([ $all_discovered[] | select(.cost_class == "subscription") ] | length),
        metered_api_models: ([ $all_discovered[] | select(.cost_class == "api-metered") ] | length)
      },
      models: $all_discovered
    }
    ' > "${dest}.tmp.$$" && mv "${dest}.tmp.$$" "$dest"

  rm -f "$tmp_oc" "$tmp_agy" "$tmp_grok" "$tmp_codex"
  cat -- "$dest"
}
