preflight_common(){
  need_cmd git; need_cmd jq; need_cmd tar; need_cmd awk; need_cmd find
  [[ -d "$KIT_ROOT/.git" || -f "$KIT_ROOT/.git" ]] || die "kit checkout is not a Git worktree"
  [[ -d "$KIT_ROOT/files/model-router" && -d "$KIT_ROOT/files/humanizer" ]] || die "canonical files/ tree incomplete"
}
preflight_mutation(){
  preflight_common
  checkout_clean || die "canonical checkout has tracked local changes; commit/stash before lifecycle mutation"
}

preflight_adopt(){
  local bad=0 cpayload xpayload
  cpayload="$(mktemp)"; xpayload="$(mktemp)"; canonical_claude_payload "$cpayload"; canonical_codex_payload "$xpayload"

  if [[ -e "$MODEL_DST" ]]; then
    if [[ "$(installed_model_hash)" != "$(canonical_model_hash)" ]] && ! historical_tree_match "$MODEL_DST" files/model-router './subscriptions.yaml' >/dev/null; then
      err "LOCAL_DRIFT model-router-core: existing tree is not a known canonical revision"; bad=1
    fi
  fi
  if [[ -e "$HUMANIZER_DST" ]]; then
    if [[ "$(installed_humanizer_hash)" != "$(canonical_humanizer_hash)" ]] && ! historical_tree_match "$HUMANIZER_DST" files/humanizer >/dev/null; then
      err "LOCAL_DRIFT humanizer: existing tree is not a known canonical revision"; bad=1
    fi
  fi

  if [[ -f "$CLAUDE_POLICY_DST" ]]; then
    if grep -Fqx "$CLAUDE_BEGIN" "$CLAUDE_POLICY_DST" || grep -Fqx "$CLAUDE_END" "$CLAUDE_POLICY_DST"; then
      local shash; shash="$(installed_section_hash "$CLAUDE_POLICY_DST" "$CLAUDE_BEGIN" "$CLAUDE_END")"
      if [[ "$shash" == MISSING ]]; then err "BROKEN claude-policy: malformed managed markers"; bad=1
      elif [[ "$shash" != "$(sha256_file "$cpayload")" ]]; then err "LOCAL_DRIFT claude-policy: managed section differs and no state exists"; bad=1; fi
    elif ! historical_claude_match "$CLAUDE_POLICY_DST" >/dev/null; then
      err "NEEDS_OWNER claude-policy: existing file has no safely claimable canonical policy block"; bad=1
    fi
  fi

  if [[ -f "$CODEX_POLICY_DST" ]]; then
    if grep -Fqx "$CODEX_BEGIN" "$CODEX_POLICY_DST" || grep -Fqx "$CODEX_END" "$CODEX_POLICY_DST"; then
      local xhash; xhash="$(installed_section_hash "$CODEX_POLICY_DST" "$CODEX_BEGIN" "$CODEX_END")"
      if [[ "$xhash" == MISSING ]]; then err "BROKEN codex-policy: malformed managed markers"; bad=1
      elif [[ "$xhash" != "$(sha256_file "$xpayload")" ]]; then err "LOCAL_DRIFT codex-policy: managed section differs and no state exists"; bad=1; fi
    elif ! historical_codex_prefix_match "$CODEX_POLICY_DST" >/dev/null; then
      err "NEEDS_OWNER codex-policy: existing file is not a known canonical prefix"; bad=1
    fi
  fi

  for pair in "$CLAUDE_MODEL_LINK|$MODEL_DST" "$CLAUDE_HUMANIZER_LINK|$HUMANIZER_DST"; do
    local p="${pair%%|*}" t="${pair#*|}"
    if [[ -e "$p" || -L "$p" ]]; then link_ok "$p" "$t" || { err "LOCAL_DRIFT managed link $p"; bad=1; }; fi
  done
  rm -f "$cpayload" "$xpayload"
  (( bad == 0 ))
}

apply_adopt(){
  local cpayload xpayload legacy oldbytes targets rev
  cpayload="$(mktemp)"; xpayload="$(mktemp)"; canonical_claude_payload "$cpayload"; canonical_codex_payload "$xpayload"

  replace_tree_preserve_config "$KIT_ROOT/files/model-router" "$MODEL_DST" subscriptions.yaml
  chmod +x "$MODEL_DST/scripts/"*.sh 2>/dev/null || true
  replace_tree_preserve_config "$KIT_ROOT/files/humanizer" "$HUMANIZER_DST"

  if [[ -f "$CLAUDE_POLICY_DST" && ! $(grep -Fxc "$CLAUDE_BEGIN" "$CLAUDE_POLICY_DST" || true) -eq 1 ]]; then
    legacy="$(historical_claude_match "$CLAUDE_POLICY_DST")"
    local lstart lcount rest
    rest="${legacy#*:}"; lstart="${rest%%:*}"; lcount="${rest##*:}"
    rewrite_line_range "$CLAUDE_POLICY_DST" "$lstart" "$lcount" "$CLAUDE_BEGIN" "$CLAUDE_END" "$cpayload"
  else
    write_marked_section "$CLAUDE_POLICY_DST" "$CLAUDE_BEGIN" "$CLAUDE_END" "$cpayload"
  fi

  if [[ -f "$CODEX_POLICY_DST" && ! $(grep -Fxc "$CODEX_BEGIN" "$CODEX_POLICY_DST" || true) -eq 1 ]]; then
    legacy="$(historical_codex_prefix_match "$CODEX_POLICY_DST")"
    oldbytes="${legacy#*:}"
    rewrite_legacy_codex_prefix "$CODEX_POLICY_DST" "$oldbytes" "$xpayload"
  else
    write_marked_section "$CODEX_POLICY_DST" "$CODEX_BEGIN" "$CODEX_END" "$xpayload"
  fi

  ensure_links
  rm -f "$cpayload" "$xpayload"
  rev="$(canonical_revision)"; targets="$(registered_targets_json)"
  [[ -n "$TARGET" ]] && targets="$(add_target_json "$TARGET")"
  write_state "$rev" "$targets"
}

preflight_update(){
  local bad=0 got exp
  [[ -f "$STATE_FILE" ]] || { err "UNKNOWN no installed-state manifest; run adopt"; return 1; }
  [[ "$(state_get '.schema_version')" == 1 ]] || { err "BROKEN unsupported state schema"; return 1; }
  local applied current
  applied="$(state_get '.kit.last_applied_revision')"; current="$(canonical_revision)"
  if [[ "$applied" != "$current" ]] && ! git -C "$KIT_ROOT" merge-base --is-ancestor "$applied" "$current" 2>/dev/null; then
    err "NEEDS_OWNER checkout is not a forward descendant of last applied revision $applied"
    bad=1
  fi

  got="$(installed_model_hash)"; exp="$(component_expected 'model-router-core')"
  [[ "$got" == "$exp" ]] || { err "LOCAL_DRIFT model-router-core expected=$exp actual=$got"; bad=1; }
  got="$(installed_humanizer_hash)"; exp="$(component_expected humanizer)"
  [[ "$got" == "$exp" ]] || { err "LOCAL_DRIFT humanizer expected=$exp actual=$got"; bad=1; }
  got="$(installed_section_hash "$CLAUDE_POLICY_DST" "$CLAUDE_BEGIN" "$CLAUDE_END")"; exp="$(component_expected 'claude-policy')"
  [[ "$got" == "$exp" ]] || { err "LOCAL_DRIFT claude-policy expected=$exp actual=$got"; bad=1; }
  got="$(installed_section_hash "$CODEX_POLICY_DST" "$CODEX_BEGIN" "$CODEX_END")"; exp="$(component_expected 'codex-policy')"
  [[ "$got" == "$exp" ]] || { err "LOCAL_DRIFT codex-policy expected=$exp actual=$got"; bad=1; }
  link_ok "$CLAUDE_MODEL_LINK" "$MODEL_DST" || { err "LOCAL_DRIFT claude model-router link"; bad=1; }
  link_ok "$CLAUDE_HUMANIZER_LINK" "$HUMANIZER_DST" || { err "LOCAL_DRIFT claude humanizer link"; bad=1; }
  [[ -f "$MODEL_DST/subscriptions.yaml" ]] || { err "BROKEN machine-local launcher config missing"; bad=1; }
  (( bad == 0 ))
}

apply_update(){
  local oldrev rev cm ch cpayload xpayload cc cx changed=0 targets
  oldrev="$(state_get '.kit.last_applied_revision')"; rev="$(canonical_revision)"
  cm="$(canonical_model_hash)"; ch="$(canonical_humanizer_hash)"
  cpayload="$(mktemp)"; xpayload="$(mktemp)"; canonical_claude_payload "$cpayload"; canonical_codex_payload "$xpayload"
  cc="$(sha256_file "$cpayload")"; cx="$(sha256_file "$xpayload")"

  if [[ "$cm" != "$(component_expected 'model-router-core')" ]]; then replace_tree_preserve_config "$KIT_ROOT/files/model-router" "$MODEL_DST" subscriptions.yaml; chmod +x "$MODEL_DST/scripts/"*.sh 2>/dev/null || true; changed=1; fi
  if [[ "$ch" != "$(component_expected humanizer)" ]]; then replace_tree_preserve_config "$KIT_ROOT/files/humanizer" "$HUMANIZER_DST"; changed=1; fi
  if [[ "$cc" != "$(component_expected 'claude-policy')" ]]; then write_marked_section "$CLAUDE_POLICY_DST" "$CLAUDE_BEGIN" "$CLAUDE_END" "$cpayload"; changed=1; fi
  if [[ "$cx" != "$(component_expected 'codex-policy')" ]]; then write_marked_section "$CODEX_POLICY_DST" "$CODEX_BEGIN" "$CODEX_END" "$xpayload"; changed=1; fi
  rm -f "$cpayload" "$xpayload"

  targets="$(registered_targets_json)"; [[ -n "$TARGET" ]] && targets="$(add_target_json "$TARGET")"
  if [[ "$rev" != "$oldrev" || "$targets" != "$(registered_targets_json)" ]]; then changed=1; fi
  if (( changed )); then write_state "$rev" "$targets"; say "UPDATED $oldrev -> $rev"; else say "CURRENT no filesystem changes"; fi
}
