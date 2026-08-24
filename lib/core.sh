need_cmd(){ command -v "$1" >/dev/null 2>&1 || die "required command missing: $1"; }
sha256_stream(){
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  else die "need sha256sum or shasum"; fi
}
sha256_file(){
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$f" | awk '{print $1}'
  else die "need sha256sum or shasum"; fi
}

hash_tree(){
  local dir="$1" exclude="${2:-}"
  [[ -d "$dir" ]] || { printf 'MISSING'; return; }
  (
    cd "$dir" || exit 1
    find . \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r rel; do
      [[ -n "$exclude" && "$rel" == "$exclude" ]] && continue
      if [[ -L "$rel" ]]; then
        printf 'L\t%s\t%s\n' "$rel" "$(readlink "$rel")"
      else
        printf 'F\t%s\t%s\n' "$rel" "$(sha256_file "$rel")"
      fi
    done
  ) | sha256_stream
}

extract_claude_payload(){
  local src="$1" out="$2"
  awk '
    $0=="## Local GPU delegation (junior-dev protocol)" {capture=1}
    capture {
      if (seen_model && /^## / && $0!="## Model & effort routing (BMAD flow)") exit
      print
      if ($0=="## Model & effort routing (BMAD flow)") seen_model=1
    }
  ' "$src" > "$out"
  grep -Fqx '## Local GPU delegation (junior-dev protocol)' "$out" || return 1
  grep -Fqx '## Model & effort routing (BMAD flow)' "$out" || return 1
}

preserve_mode(){
  local src="$1" dst="$2" mode=""
  [[ -e "$src" ]] || return 0
  if mode="$(stat -c '%a' "$src" 2>/dev/null)"; then :
  else mode="$(stat -f '%Lp' "$src" 2>/dev/null || true)"; fi
  [[ -n "$mode" ]] && chmod "$mode" "$dst"
}

extract_marked_section(){
  local src="$1" begin="$2" end="$3" out="$4"
  [[ -f "$src" ]] || return 1
  local bc ec
  bc="$(grep -Fxc "$begin" "$src" || true)"; ec="$(grep -Fxc "$end" "$src" || true)"
  [[ "$bc" == 1 && "$ec" == 1 ]] || return 1
  awk -v b="$begin" -v e="$end" '
    $0==b {on=1; next}
    $0==e {if(on){exit}}
    on {print}
  ' "$src" > "$out"
}

write_marked_section(){
  local dst="$1" begin="$2" end="$3" payload="$4" tmp
  mkdir -p "$(dirname "$dst")"
  tmp="$(mktemp "${dst}.tmp.XXXXXX")"
  if [[ -f "$dst" ]] && grep -Fqx "$begin" "$dst" && grep -Fqx "$end" "$dst"; then
    local on=0 line
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == "$begin" ]]; then
        printf '%s\n' "$begin" >> "$tmp"
        cat "$payload" >> "$tmp"
        printf '%s\n' "$end" >> "$tmp"
        on=1
        continue
      fi
      if (( on )); then
        [[ "$line" == "$end" ]] && on=0
        continue
      fi
      printf '%s\n' "$line" >> "$tmp"
    done < "$dst"
  else
    if [[ -f "$dst" && -s "$dst" ]]; then
      cat "$dst" > "$tmp"
      printf '\n' >> "$tmp"
    fi
    printf '%s\n' "$begin" >> "$tmp"
    cat "$payload" >> "$tmp"
    printf '%s\n' "$end" >> "$tmp"
  fi
  preserve_mode "$dst" "$tmp"
  mv "$tmp" "$dst"
}

rewrite_legacy_claude(){
  local dst="$1" payload="$2" tmp
  tmp="$(mktemp "${dst}.tmp.XXXXXX")"
  awk -v p="$payload" -v b="$CLAUDE_BEGIN" -v e="$CLAUDE_END" '
    function emit_payload( line) {
      while ((getline line < p) > 0) print line
      close(p)
    }
    $0=="## Local GPU delegation (junior-dev protocol)" && !done {
      print b; emit_payload(); print e
      capture=1; seen_model=0; done=1; next
    }
    capture {
      if ($0=="## Model & effort routing (BMAD flow)") {seen_model=1; next}
      if (seen_model && /^## /) {capture=0; print; next}
      next
    }
    {print}
  ' "$dst" > "$tmp"
  mv "$tmp" "$dst"
}

rewrite_legacy_codex_prefix(){
  local dst="$1" old_bytes="$2" payload="$3" tmp rest
  tmp="$(mktemp "${dst}.tmp.XXXXXX")"; rest="$(mktemp)"
  dd if="$dst" of="$rest" bs=1 skip="$old_bytes" 2>/dev/null || true
  printf '%s\n' "$CODEX_BEGIN" > "$tmp"
  cat "$payload" >> "$tmp"
  printf '%s\n' "$CODEX_END" >> "$tmp"
  cat "$rest" >> "$tmp"
  rm -f "$rest"
  mv "$tmp" "$dst"
}

canonical_revision(){ git -C "$KIT_ROOT" rev-parse HEAD; }
checkout_clean(){ git -C "$KIT_ROOT" diff --quiet --exit-code -- . && git -C "$KIT_ROOT" diff --cached --quiet --exit-code -- .; }

canonical_model_hash(){ hash_tree "$KIT_ROOT/files/model-router" './subscriptions.yaml'; }
canonical_humanizer_hash(){ hash_tree "$KIT_ROOT/files/humanizer"; }
canonical_claude_payload(){ extract_claude_payload "$KIT_ROOT/files/claude-global-CLAUDE.md" "$1"; }
canonical_codex_payload(){ cp "$KIT_ROOT/files/codex-AGENTS.md" "$1"; }

installed_model_hash(){ hash_tree "$MODEL_DST" './subscriptions.yaml'; }
installed_humanizer_hash(){ hash_tree "$HUMANIZER_DST"; }
installed_section_hash(){
  local dst="$1" begin="$2" end="$3" tmp
  tmp="$(mktemp)"
  if extract_marked_section "$dst" "$begin" "$end" "$tmp"; then sha256_file "$tmp"; else printf 'MISSING'; fi
  rm -f "$tmp"
}
