print_status(){
  local overall=0 rev applied got exp upstream relation tstat path
  rev="$(canonical_revision)"
  printf 'KIT checkout %s\n' "$rev"
  checkout_clean && printf 'CURRENT checkout-clean\n' || { printf 'LOCAL_DRIFT checkout has tracked modifications\n'; overall=1; }

  if (( FETCH )); then
    if git -C "$KIT_ROOT" fetch --quiet 2>/dev/null; then printf 'CURRENT remote refs refreshed\n'; else printf 'NEEDS_OWNER remote fetch unavailable\n'; overall=1; fi
  fi
  upstream="$(git -C "$KIT_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  if [[ -n "$upstream" ]]; then
    relation="$(git -C "$KIT_ROOT" rev-list --left-right --count HEAD..."$upstream" 2>/dev/null || true)"
    if [[ -n "$relation" ]]; then
      local behind; behind="${relation##*[[:space:]]}"
      if (( behind > 0 )); then printf 'UPDATE_AVAILABLE source checkout is %s commit(s) behind %s\n' "$behind" "$upstream"; overall=1; else printf 'CURRENT source checkout not behind %s\n' "$upstream"; fi
    fi
  fi

  if [[ ! -f "$STATE_FILE" ]]; then
    printf 'UNKNOWN no installed-state manifest (legacy or not adopted)\n'
    [[ -e "$MODEL_DST" ]] && printf 'UNKNOWN model-router-core legacy install detected\n'
    [[ -e "$HUMANIZER_DST" ]] && printf 'UNKNOWN humanizer legacy install detected\n'
    return 1
  fi
  applied="$(state_get '.kit.last_applied_revision')"
  if [[ "$rev" == "$applied" ]]; then printf 'CURRENT applied revision %s\n' "$applied"; else printf 'UPDATE_AVAILABLE applied=%s checkout=%s\n' "$applied" "$rev"; overall=1; fi

  got="$(installed_model_hash)"; exp="$(component_expected 'model-router-core')"; [[ "$got" == "$exp" ]] && printf 'CURRENT model-router-core\n' || { printf 'LOCAL_DRIFT model-router-core expected=%s actual=%s\n' "$exp" "$got"; overall=1; }
  got="$(installed_humanizer_hash)"; exp="$(component_expected humanizer)"; [[ "$got" == "$exp" ]] && printf 'CURRENT humanizer\n' || { printf 'LOCAL_DRIFT humanizer expected=%s actual=%s\n' "$exp" "$got"; overall=1; }
  got="$(installed_section_hash "$CLAUDE_POLICY_DST" "$CLAUDE_BEGIN" "$CLAUDE_END")"; exp="$(component_expected 'claude-policy')"; [[ "$got" == "$exp" ]] && printf 'CURRENT claude-policy\n' || { printf 'LOCAL_DRIFT claude-policy expected=%s actual=%s\n' "$exp" "$got"; overall=1; }
  got="$(installed_section_hash "$CODEX_POLICY_DST" "$CODEX_BEGIN" "$CODEX_END")"; exp="$(component_expected 'codex-policy')"; [[ "$got" == "$exp" ]] && printf 'CURRENT codex-policy\n' || { printf 'LOCAL_DRIFT codex-policy expected=%s actual=%s\n' "$exp" "$got"; overall=1; }
  link_ok "$CLAUDE_MODEL_LINK" "$MODEL_DST" && printf 'CURRENT claude-model-router-link\n' || { printf 'LOCAL_DRIFT claude-model-router-link\n'; overall=1; }
  link_ok "$CLAUDE_HUMANIZER_LINK" "$HUMANIZER_DST" && printf 'CURRENT claude-humanizer-link\n' || { printf 'LOCAL_DRIFT claude-humanizer-link\n'; overall=1; }
  [[ -f "$MODEL_DST/subscriptions.yaml" ]] && printf 'LOCAL_ADAPTATION model-router-launcher %s\n' "$MODEL_DST/subscriptions.yaml" || { printf 'BROKEN model-router-launcher missing\n'; overall=1; }

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    tstat="$(target_status "$path")"
    printf '%s target %s — %s\n' "${tstat%%|*}" "$path" "${tstat#*|}"
    [[ "${tstat%%|*}" == CURRENT ]] || overall=1
  done < <(jq -r '.targets[]?.path' "$STATE_FILE")
  if [[ -n "$TARGET" ]]; then
    tstat="$(target_status "$TARGET")"; printf '%s target %s — %s\n' "${tstat%%|*}" "$TARGET" "${tstat#*|}"; [[ "${tstat%%|*}" == CURRENT ]] || overall=1
  fi
  return "$overall"
}

verify_installation(){
  local bad=0 cfg validator catalog token_env router b
  preflight_update || return 1
  for b in jq yq curl orca; do command -v "$b" >/dev/null 2>&1 || { err "NEEDS_OWNER dependency missing: $b"; bad=1; }; done
  cfg="$MODEL_DST/subscriptions.yaml"
  if command -v yq >/dev/null 2>&1; then
    yq --version 2>&1 | grep -Eq 'version[[:space:]]+v?4\.' || { err "NEEDS_OWNER yq must be mikefarah v4+"; bad=1; }
    router="$(yq -r '.launcher.router_endpoint // ""' "$cfg" 2>/dev/null || true)"
    token_env="$(yq -r '.launcher.caller_token_env // ""' "$cfg" 2>/dev/null || true)"
    catalog="${AGENT_STAMP_VALIDATE_CATALOG_PATH:-$(yq -r '.launcher.catalog_path // ""' "$cfg" 2>/dev/null || true)}"
    validator="${AGENT_STAMP_VALIDATE:-$(yq -r '.launcher.stamp_validator // "agent-stamp-validate"' "$cfg" 2>/dev/null || true)}"
    [[ -n "$router" ]] || { err "BROKEN launcher.router_endpoint empty"; bad=1; }
    [[ -n "$token_env" ]] || { err "BROKEN launcher.caller_token_env empty"; bad=1; }
    [[ -n "$catalog" && -f "$catalog" ]] || { err "NEEDS_OWNER trusted validator catalog missing: ${catalog:-<empty>}"; bad=1; }
    if command -v "$validator" >/dev/null 2>&1; then
      local vhelp; vhelp="$("$validator" --help 2>&1 || true)"
      [[ "$vhelp" == *"-catalog"* && "$vhelp" == *"-stamp"* ]] || { err "NEEDS_OWNER validator/client incompatible: expected --catalog and --stamp interface"; bad=1; }
    else
      err "NEEDS_OWNER validator/client dependency missing: $validator"; bad=1
    fi
    for b in claude codex; do
      local hb; hb="$(yq -r ".launcher.harness_binaries.$b // \"\"" "$cfg" 2>/dev/null || true)"
      if [[ -z "$hb" ]] || ! command -v "$hb" >/dev/null 2>&1; then err "NEEDS_OWNER harness binary missing: $b (${hb:-unset})"; bad=1; fi
    done
    if [[ -n "$token_env" ]]; then
      if [[ ! "$token_env" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then err "BROKEN caller_token_env is not a valid environment variable name: $token_env"; bad=1
      elif [[ -z "${!token_env:-}" ]]; then err "NEEDS_OWNER caller token env not populated: $token_env"; bad=1; fi
    fi
    [[ -z "${ANTHROPIC_API_KEY:-}" ]] || { err "BROKEN ANTHROPIC_API_KEY is set; subscription-safe Claude launch requires it absent"; bad=1; }
    [[ -z "${CLAUDE_CONFIG_DIR:-}" ]] || { err "BROKEN CLAUDE_CONFIG_DIR is set; validated launch contract requires default store"; bad=1; }
    if (( ! OFFLINE )) && [[ -n "$router" && "$token_env" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && -n "${!token_env:-}" ]]; then
      local code; code="$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${!token_env}" --max-time 10 "${router%/}/v1/status" 2>/dev/null || true)"
      [[ "$code" == 200 ]] || { err "BROKEN router reachability/status HTTP ${code:-none}"; bad=1; }
    fi
  fi
  return "$bad"
}
