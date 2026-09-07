#!/usr/bin/env bash
# Attack 5 — shell safety of every new literal that enters the generated
# command text. Each hostile value is injected into build_claude_gateway_command
# and the generated text is EXECUTED in a sandbox whose PATH holds only stubs.
# A canary file proves whether injected shell ran; the stub `claude` records the
# environment it was actually handed (paths are baked in, since env -i strips
# everything not on the allowlist). Control at the end: the same literal built
# WITHOUT shq must pop the canary, so a clean run is not a blind one.
set -uo pipefail
WT="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
. "$WT/files/model-router/scripts/dispatch.sh"   # main() stays guarded ($0 != BASH_SOURCE)
set +e   # dispatch.sh carries `set -euo pipefail`; sourcing it imposes it on us

BIN="$TMP/bin"; mkdir -p "$BIN" "$TMP/home"
cat > "$BIN/claude" <<S
#!/usr/bin/env bash
env > "$TMP/claude-env.txt"
printf '%s\n' "\$@" > "$TMP/claude-argv.txt"
cat > /dev/null
printf '{"result":"ok","is_error":false}'
S
cat > "$BIN/op" <<'S'
#!/usr/bin/env bash
[[ "$1" == "read" && -n "${2:-}" ]] || exit 2
printf '%s' 'SENTINEL-9f3a'
S
chmod +x "$BIN/claude" "$BIN/op"
printf 'export OP_SERVICE_ACCOUNT_TOKEN=stub-sa\n' > "$TMP/op-env"
printf 'the prompt\n' > "$TMP/prompt"
CAN="$TMP/CANARY"

fail=0
run_case() { # <label> <base_url> <token_ref> <op_env_file> <header> <max_context>
  local label="$1" url="$2" ref="$3" opf="$4" hdr="$5" ctx="$6"
  rm -f "$CAN" "$TMP/claude-env.txt" "$TMP/claude-argv.txt"
  local cmd rc
  cmd="$(build_claude_gateway_command "$TMP/home" "$BIN:/usr/bin:/bin" "op" "$TMP/prompt" \
          "qwen36-27b" "high" "$TMP/result.json" "" "$url" "$ref" "$opf" "$hdr" "$ctx")" || {
    echo "FAIL $label — builder itself errored"; fail=1; return; }
  { printf '=== CASE: %s\n' "$label"; printf '%s\n\n' "$cmd"; } >> "$TMP/log"
  ( cd "$TMP" && PATH="$BIN:/usr/bin:/bin" bash -c "$cmd" ) > "$TMP/stdout" 2> "$TMP/stderr"; rc=$?
  if [[ -e "$CAN" ]]; then
    echo "FAIL $label — INJECTION EXECUTED (canary popped)"; fail=1; rm -f "$CAN"; return
  fi
  local hdrgot="(claude never ran)"
  [[ -f "$TMP/claude-env.txt" ]] && hdrgot="$(sed -n 's/^ANTHROPIC_CUSTOM_HEADERS=//p' "$TMP/claude-env.txt")"
  local cred=no
  [[ -f "$TMP/claude-env.txt" ]] && grep -q 'SENTINEL-9f3a' "$TMP/claude-env.txt" && cred=yes
  printf 'PASS %s — no injection; rc=%s; ANTHROPIC_CUSTOM_HEADERS=[%s]; credential-in-harness-env=%s\n' \
    "$label" "$rc" "$hdrgot" "$cred"
}

run_case "benign"                  https://gw.invalid 'op://v/i/f'                 "$TMP/op-env" 'kserve-a5000' 65536
run_case "header quote+subshell"   https://gw.invalid 'op://v/i/f'                 "$TMP/op-env" "a\"; touch $CAN; \"b" 65536
run_case "header \$( ) injection"  https://gw.invalid 'op://v/i/f'                 "$TMP/op-env" "a\$(touch $CAN)b" 65536
run_case "header embedded space"   https://gw.invalid 'op://v/i/f'                 "$TMP/op-env" 'a b FOO=bar' 65536
run_case "header newline"          https://gw.invalid 'op://v/i/f'                 "$TMP/op-env" "$(printf 'a\ntouch %s\nb' "$CAN")" 65536
run_case "header semicolon"        https://gw.invalid 'op://v/i/f'                 "$TMP/op-env" "a; touch $CAN" 65536
run_case "base_url injection"      "https://x\$(touch $CAN)" 'op://v/i/f'          "$TMP/op-env" 'p' 65536
run_case "token_ref injection"     https://gw.invalid "op://v/i/f\"; touch $CAN; \"" "$TMP/op-env" 'p' 65536
run_case "op_env_file backticks"   https://gw.invalid 'op://v/i/f'                 "$TMP/op-env\`touch $CAN\`" 'p' 65536
run_case "min_context injection"   https://gw.invalid 'op://v/i/f'                 "$TMP/op-env" 'p' "65536; touch $CAN"

# ---- CONTROLS -------------------------------------------------------------
rm -f "$CAN"
( cd "$TMP" && PATH="$BIN:/usr/bin:/bin" bash -c "X=a; touch $CAN; true" ) >/dev/null 2>&1
if [[ -e "$CAN" ]]; then echo "PASS CONTROL-A: an UNQUOTED literal (X=a; touch CANARY) does pop the canary"; rm -f "$CAN"
else echo "FAIL CONTROL-A: the canary mechanism does not work"; fail=1; fi

# CONTROL-B: the harness really is reached and really does receive the values,
# so the "no injection" results above are not "nothing ran".
rm -f "$TMP/claude-env.txt"
cmd="$(build_claude_gateway_command "$TMP/home" "$BIN:/usr/bin:/bin" "op" "$TMP/prompt" \
        "qwen36-27b" "high" "$TMP/result.json" "" https://gw.invalid 'op://v/i/f' "$TMP/op-env" 'kserve-a5000' 65536)"
( cd "$TMP" && PATH="$BIN:/usr/bin:/bin" bash -c "$cmd" ) >/dev/null 2>&1
if [[ -f "$TMP/claude-env.txt" ]]; then
  echo "PASS CONTROL-B: the sandboxed harness ran; its full environment was:"
  sed 's/^/      /' "$TMP/claude-env.txt" | sed 's/SENTINEL-9f3a/<CREDENTIAL>/'
else
  echo "FAIL CONTROL-B: the harness never ran; every case above is vacuous"; fail=1
fi
cp "$TMP/log" "$(dirname "$0")/attack-02-generated-texts.txt" 2>/dev/null || true
exit $fail
