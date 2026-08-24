historical_tree_match(){
  local dst="$1" repo_path="$2" exclude="${3:-}" want rev tmp hist
  [[ -d "$dst" ]] || return 1
  want="$(hash_tree "$dst" "$exclude")"
  while IFS= read -r rev; do
    tmp="$(mktemp -d)"
    if git -C "$KIT_ROOT" archive "$rev" "$repo_path" | tar -x -C "$tmp" 2>/dev/null; then
      hist="$(hash_tree "$tmp/$repo_path" "$exclude")"
      rm -rf "$tmp"
      [[ "$want" == "$hist" ]] && { printf '%s' "$rev"; return 0; }
    else
      rm -rf "$tmp"
    fi
  done < <(git -C "$KIT_ROOT" rev-list --all -- "$repo_path")
  return 1
}

historical_claude_match(){
  local dst="$1" rev src hist start_line n cand
  [[ -f "$dst" ]] || return 1
  start_line="$(grep -n -F -m1 '## Local GPU delegation (junior-dev protocol)' "$dst" | cut -d: -f1 || true)"
  [[ -n "$start_line" ]] || return 1
  while IFS= read -r rev; do
    src="$(mktemp)"; hist="$(mktemp)"; cand="$(mktemp)"
    if git -C "$KIT_ROOT" show "$rev:files/claude-global-CLAUDE.md" > "$src" 2>/dev/null \
       && extract_claude_payload "$src" "$hist"; then
      n="$(wc -l < "$hist" | tr -d ' ')"
      sed -n "${start_line},$((start_line+n-1))p" "$dst" > "$cand"
      if cmp -s "$hist" "$cand"; then
        rm -f "$src" "$hist" "$cand"; printf '%s:%s:%s' "$rev" "$start_line" "$n"; return 0
      fi
    fi
    rm -f "$src" "$hist" "$cand"
  done < <(git -C "$KIT_ROOT" rev-list --all -- files/claude-global-CLAUDE.md)
  return 1
}

rewrite_line_range(){
  local dst="$1" start_line="$2" line_count="$3" begin="$4" end="$5" payload="$6" tmp end_line
  tmp="$(mktemp "${dst}.tmp.XXXXXX")"; end_line=$((start_line+line_count-1))
  awk -v s="$start_line" -v e="$end_line" -v b="$begin" -v z="$end" -v p="$payload" '
    function emit_payload( line) { while ((getline line < p) > 0) print line; close(p) }
    NR==s { print b; emit_payload(); print z }
    NR>=s && NR<=e { next }
    { print }
  ' "$dst" > "$tmp"
  mv "$tmp" "$dst"
}

historical_codex_prefix_match(){
  local dst="$1" rev hist n prefix
  [[ -f "$dst" ]] || return 1
  while IFS= read -r rev; do
    hist="$(mktemp)"; prefix="$(mktemp)"
    if git -C "$KIT_ROOT" show "$rev:files/codex-AGENTS.md" > "$hist" 2>/dev/null; then
      n="$(wc -c < "$hist" | tr -d ' ')"
      head -c "$n" "$dst" > "$prefix" 2>/dev/null || true
      if cmp -s "$hist" "$prefix"; then
        rm -f "$hist" "$prefix"; printf '%s:%s' "$rev" "$n"; return 0
      fi
    fi
    rm -f "$hist" "$prefix"
  done < <(git -C "$KIT_ROOT" rev-list --all -- files/codex-AGENTS.md)
  return 1
}

replace_tree_preserve_config(){
  local src="$1" dst="$2" preserve_rel="${3:-}" stage backup
  mkdir -p "$(dirname "$dst")"
  stage="$(mktemp -d "$(dirname "$dst")/.agent-flow-kit.stage.XXXXXX")"
  cp -R "$src/." "$stage/"
  if [[ -n "$preserve_rel" && -f "$dst/$preserve_rel" ]]; then
    cp "$dst/$preserve_rel" "$stage/$preserve_rel"
  fi
  backup="${dst}.agent-flow-kit-old.$$"
  if [[ -e "$dst" || -L "$dst" ]]; then mv "$dst" "$backup"; fi
  if mv "$stage" "$dst"; then rm -rf "$backup" 2>/dev/null || true
  else [[ -e "$backup" ]] && mv "$backup" "$dst"; rm -rf "$stage"; return 1; fi
}

link_ok(){ [[ -L "$1" && "$(readlink "$1")" == "$2" ]]; }
ensure_one_link(){
  local link="$1" target="$2"
  if link_ok "$link" "$target"; then return 0; fi
  rm -f "$link"
  ln -s "$target" "$link"
}
ensure_links(){
  mkdir -p "$HOME/.claude/skills"
  ensure_one_link "$CLAUDE_MODEL_LINK" "$MODEL_DST"
  ensure_one_link "$CLAUDE_HUMANIZER_LINK" "$HUMANIZER_DST"
}

state_get(){ jq -r "$1 // empty" "$STATE_FILE" 2>/dev/null || true; }
component_expected(){ state_get ".components[\"$1\"].canonical_hash"; }

write_state(){
  local rev="$1" target_json="$2" cm ch cc cx tmp cpayload xpayload
  cm="$(canonical_model_hash)"; ch="$(canonical_humanizer_hash)"
  cpayload="$(mktemp)"; xpayload="$(mktemp)"
  canonical_claude_payload "$cpayload"; canonical_codex_payload "$xpayload"
  cc="$(sha256_file "$cpayload")"; cx="$(sha256_file "$xpayload")"
  rm -f "$cpayload" "$xpayload"
  mkdir -p "$STATE_DIR"
  tmp="$(mktemp "$STATE_DIR/state.json.tmp.XXXXXX")"
  jq -n \
    --arg rev "$rev" --arg root "$KIT_ROOT" \
    --arg md "$MODEL_DST" --arg hd "$HUMANIZER_DST" \
    --arg cd "$CLAUDE_POLICY_DST" --arg xd "$CODEX_POLICY_DST" \
    --arg ml "$CLAUDE_MODEL_LINK" --arg hl "$CLAUDE_HUMANIZER_LINK" \
    --arg cm "$cm" --arg ch "$ch" --arg cc "$cc" --arg cx "$cx" \
    --arg cfg "$MODEL_DST/subscriptions.yaml" \
    --argjson targets "$target_json" \
    '{schema_version:1, kit:{repo_root:$root,last_applied_revision:$rev},
      components:{
        "model-router-core":{mode:"managed_copy",destination:$md,canonical_hash:$cm,excludes:["subscriptions.yaml"]},
        "humanizer":{mode:"managed_copy",destination:$hd,canonical_hash:$ch},
        "claude-policy":{mode:"managed_section",destination:$cd,canonical_hash:$cc},
        "codex-policy":{mode:"managed_section",destination:$xd,canonical_hash:$cx},
        "claude-model-router-link":{mode:"managed_link",destination:$ml,target:$md},
        "claude-humanizer-link":{mode:"managed_link",destination:$hl,target:$hd}
      },
      machine_local:{"model-router-launcher":{mode:"machine_local_config",path:$cfg}},
      targets:$targets}' > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

registered_targets_json(){
  if [[ -f "$STATE_FILE" ]]; then jq -c '.targets // []' "$STATE_FILE"; else printf '[]'; fi
}
add_target_json(){
  local path="$1" base
  base="$(registered_targets_json)"
  jq -nc --argjson a "$base" --arg p "$path" '$a | if any(.path==$p) then . else . + [{path:$p,mode:"target_repo_wiring"}] end'
}

target_status(){
  local target="$1" template fm
  [[ -d "$target" ]] || { printf 'BROKEN|target path missing'; return; }
  template=""
  [[ -f "$target/_bmad/bmm/workflows/4-implementation/create-story/template.md" ]] && template="$target/_bmad/bmm/workflows/4-implementation/create-story/template.md"
  [[ -z "$template" && -f "$target/.agents/skills/bmad-create-story/template.md" ]] && template="$target/.agents/skills/bmad-create-story/template.md"
  [[ -n "$template" ]] || { printf 'NEEDS_OWNER|BMAD create-story template not found'; return; }
  fm="$(awk 'BEGIN{n=0} /^---[[:space:]]*$/{n++; if(n==2){print; exit}} {if(n>0) print}' "$template")"
  grep -Eq '^[[:space:]]*stamp:' <<<"$fm" || { printf 'NEEDS_OWNER|template missing stamp field'; return; }
  grep -Eq '^[[:space:]]*persona:' <<<"$fm" || { printf 'NEEDS_OWNER|template missing persona field'; return; }
  grep -Eq '^[[:space:]]*gates:' <<<"$fm" || { printf 'NEEDS_OWNER|template missing gates field'; return; }
  grep -Eq '^[[:space:]]*max_cycles:' <<<"$fm" || { printf 'NEEDS_OWNER|template missing max_cycles field'; return; }
  if grep -Eq '^[[:space:]]*route:' <<<"$fm"; then printf 'BROKEN|retired route field still present'; return; fi
  [[ -e "$target/_bmad/bmm/agents/dev.md" ]] || { printf 'NEEDS_OWNER|dev persona not wired at _bmad/bmm/agents/dev.md'; return; }
  printf 'CURRENT|%s' "$template"
}
