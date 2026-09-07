#!/usr/bin/env bash
# Attack 6 — test vacuity. Each of run-tests.sh's key new assertions is
# re-implemented here VERBATIM (same parse, same comparison) and run against
# (a) the real dispatch.sh, where it must PASS, and (b) a deliberately broken
# scratch copy under /tmp, where it must FAIL. An assertion that passes on both
# proves nothing; that is the whole point of the exercise.
set -uo pipefail
WT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SRC="$WT/files/model-router/scripts/dispatch.sh"
SENT='sentinel-gateway-credential-2f4a9c'
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/op" <<S
#!/usr/bin/env bash
[[ "\$1" == "read" && -n "\${2:-}" ]] || exit 2
printf '%s' '$SENT'
S
chmod +x "$BIN/op"
printf 'export OP_SERVICE_ACCOUNT_TOKEN=stub-sa\n' > "$TMP/op-env"
fail=0

build() { # <script> -> the gateway command text, built with the suite's inputs
  PATH="$BIN:$PATH" bash -c '
    . "$1"; set +e
    build_claude_gateway_command "/home/op" "/usr/bin:/bin" "op" \
      "/wt/STORY.md.prompt" "qwen36-27b" "high" "/wt/STORY.md.claude-result.json" \
      "/wt/_bmad/bmm/agents/dev.md" "https://gateway.invalid" \
      "op://stubvault/agw-claude-code/credential" "'"$TMP"'/op-env" \
      "kserve-a5000" "65536"' _b "$1"
}

# --- the assertions, exactly as tests/run-tests.sh states them --------------
A_allowlist() { # <cmd> -> 0 if the suite's SET assertion would PASS
  local GWCMD="$1" seg names
  seg="${GWCMD#*env -i }"; seg="${seg%% claude -p*}"
  names="$(tr ' ' '\n' <<<"$seg" | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' | tr '\n' ' ')"
  [[ "$names" == "HOME PATH USER LANG TERM ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_CUSTOM_HEADERS CLAUDE_CODE_MAX_CONTEXT_TOKENS " ]]
}
A_sentinel_absent() { ! grep -qF -- "$SENT" <<<"$1"; }
A_byte_identity() { # <script> <cmd>
  local twin tail
  twin="$(bash -c '. "$1"; set +e; build_claude_command "/home/op" "/usr/bin:/bin" "op" \
      "/wt/STORY.md.prompt" "qwen36-27b" "high" "/wt/STORY.md.claude-result.json" \
      "/wt/_bmad/bmm/agents/dev.md"' _b "$1")"
  tail="${2#*CLAUDE_CODE_MAX_CONTEXT_TOKENS=65536 }"; tail="${tail%; unset ANTHROPIC_AUTH_TOKEN}"
  [[ "$tail" == "${twin#*TERM=dumb }" ]]
}
A_two_subs() { [[ "$(grep -o '\$(' <<<"$1" | wc -l)" == "2" ]]; }
A_no_apikey() { ! grep -qF 'ANTHROPIC_API_KEY' <<<"$1"; }

check() { # <label> <expect pass|fail> <assertion-fn> <script> [cmd]
  local label="$1" want="$2" fn="$3" script="$4" cmd="${5:-}"
  [[ -n "$cmd" ]] || cmd="$(build "$script")"
  local got=pass
  case "$fn" in
    A_byte_identity) "$fn" "$script" "$cmd" || got=fail ;;
    *)               "$fn" "$cmd"           || got=fail ;;
  esac
  if [[ "$got" == "$want" ]]; then printf 'PASS %-58s assertion %s (expected)\n' "$label" "$got"
  else printf 'FAIL %-58s assertion %s, expected %s\n' "$label" "$got" "$want"; fail=1; fi
}

echo "== BASELINE: every assertion passes on the real dispatch.sh"
BASE="$(build "$SRC")"
check "baseline / allowlist-is-exactly-the-contract" pass A_allowlist       "$SRC" "$BASE"
check "baseline / credential value absent"           pass A_sentinel_absent "$SRC" "$BASE"
check "baseline / claude invocation byte-identical"  pass A_byte_identity   "$SRC" "$BASE"
check "baseline / exactly two command substitutions" pass A_two_subs        "$SRC" "$BASE"
check "baseline / no ANTHROPIC_API_KEY"              pass A_no_apikey       "$SRC" "$BASE"

echo
echo "== MUTANTS: the same assertions must FAIL when the property is broken"

mut() { cp "$SRC" "$TMP/$1.sh"; shift; python3 - "$@"; }

# M1 — a quietly widened allowlist
cp "$SRC" "$TMP/m1.sh"
sed -i 's|^CLAUDE_CODE_MAX_CONTEXT_TOKENS=\$(shq "\$max_context") \\|CLAUDE_CODE_MAX_CONTEXT_TOKENS=$(shq "$max_context") ANTHROPIC_SMALL_FAST_MODEL=haiku \\|' "$TMP/m1.sh"
grep -q ANTHROPIC_SMALL_FAST_MODEL "$TMP/m1.sh" && echo "   [M1 applied: one extra ANTHROPIC_* in the allowlist]" || { echo "   M1 NOT APPLIED"; fail=1; }
check "M1 extra allowlist variable"                  fail A_allowlist       "$TMP/m1.sh"

# M2 — the credential resolved by dispatch.sh and interpolated as a VALUE
cp "$SRC" "$TMP/m2.sh"
python3 - "$TMP/m2.sh" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
old='"ANTHROPIC_AUTH_TOKEN=\\"\\$(. $(shq "$op_env_file") && op read $(shq "$token_ref"))\\"; \\'
new='"ANTHROPIC_AUTH_TOKEN=$(shq "$(. "$op_env_file" >/dev/null 2>&1; op read "$token_ref")"); \\'
assert old in s, "M2 anchor not found"
open(p,"w").write(s.replace(old,new))
PY
echo "   [M2 applied: dispatch.sh resolves the credential itself]"
M2CMD="$(build "$TMP/m2.sh")"
check "M2 credential interpolated into the command text" fail A_sentinel_absent "$TMP/m2.sh" "$M2CMD"

# M3 — the claude invocation drifts from the native one
cp "$SRC" "$TMP/m3.sh"
python3 - "$TMP/m3.sh" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
i=s.index('build_claude_gateway_command()')
head,tail=s[:i],s[i:]
old='--permission-mode acceptEdits --tools \\"Read,Glob,Grep,Write\\" \\'
assert old in tail, "M3 anchor not found"
tail=tail.replace(old,'--permission-mode acceptEdits --tools \\"Read,Glob,Grep,Write,Bash\\" \\',1)
open(p,"w").write(head+tail)
PY
echo "   [M3 applied: gateway class silently grants Bash]"
check "M3 gateway claude invocation drifts from native"  fail A_byte_identity   "$TMP/m3.sh"

# M4 — a contract variable dropped
cp "$SRC" "$TMP/m4.sh"
sed -i 's|^CLAUDE_CODE_MAX_CONTEXT_TOKENS=\$(shq "\$max_context") \\||' "$TMP/m4.sh"
grep -q 'CLAUDE_CODE_MAX_CONTEXT_TOKENS=\$(shq' "$TMP/m4.sh" && { echo "   M4 NOT APPLIED"; fail=1; } || echo "   [M4 applied: CLAUDE_CODE_MAX_CONTEXT_TOKENS dropped]"
check "M4 a contract variable removed"                   fail A_allowlist       "$TMP/m4.sh"

# M5 — an API key added back
cp "$SRC" "$TMP/m5.sh"
sed -i 's|^ANTHROPIC_MODEL=\$(shq "\$model") \\|ANTHROPIC_MODEL=$(shq "$model") ANTHROPIC_API_KEY=$(shq "$token_ref") \\|' "$TMP/m5.sh"
grep -q 'ANTHROPIC_API_KEY=\$(shq' "$TMP/m5.sh" && echo "   [M5 applied: ANTHROPIC_API_KEY reintroduced]" || { echo "   M5 NOT APPLIED"; fail=1; }
check "M5 ANTHROPIC_API_KEY reintroduced (denylist)"     fail A_no_apikey       "$TMP/m5.sh"
check "M5 ...and the allowlist SET also catches it"      fail A_allowlist       "$TMP/m5.sh"

# M6 — the empty-read guard deleted
cp "$SRC" "$TMP/m6.sh"
sed -i '/^\[ -n .*ANTHROPIC_AUTH_TOKEN.* \] || { \\$/d; /^echo .dispatch: gateway credential resolved EMPTY/d; /^exit 78; }; \\$/d' "$TMP/m6.sh"
M6CMD="$(build "$TMP/m6.sh" 2>/dev/null)"
if grep -qF 'exit 78' <<<"$M6CMD"; then
  printf 'FAIL %-58s mutation did not apply\n' "M6 empty-read guard removed"; fail=1
else
  echo "   [M6 applied: empty-read guard removed from the generated text]"
  if grep -qF '[ -n "$ANTHROPIC_AUTH_TOKEN" ] ||' <<<"$M6CMD"; then
    printf 'FAIL %-58s the suite assertion would still pass\n' "M6 empty-read guard removed"; fail=1
  else
    printf 'PASS %-58s the suite assertion ([ -n ... ] ||) would FAIL\n' "M6 empty-read guard removed"
  fi
  # and the mutant really does start claude with an empty token
  if PATH="$TMP/nonexistent:/usr/bin:/bin" bash -c "$M6CMD" >/dev/null 2>&1; then :; fi
fi

echo
echo "== SUMMARY: an assertion is only worth its PASS if its mutant FAILS."
exit $fail
