#!/usr/bin/env bash
# ATTACK 7 — harness agnosticism (NFR-13/15) and AC-6 (route requests untouched).
set -uo pipefail
. "$(dirname "$0")/attack-harness.sh"
POLICY="$SHIPPED_POLICY"
D="$KIT_ROOT/files/model-router/scripts/dispatch.sh"
MS="$KIT_ROOT/files/model-router/scripts/make-stamp.sh"
code() { grep -vE '^[[:space:]]*#' "$1"; }

# --- no CLI name anywhere in the declared policy -------------------------
for w in claude codex opus sonnet anthropic openai qwen gpt harness cli; do
  if grep -qi "$w" "$POLICY"; then bad "7: the policy document names no harness ('$w')" "$(grep -in "$w" "$POLICY" | head -2)"
  else ok "7: the policy document names no harness ('$w')"; fi
done
# and no threshold constant in the launcher's code
if code "$D" | grep -qE '0\.(6|7|85)0?[^0-9]'; then
  bad "7: no threshold constant in dispatch.sh code" "$(code "$D" | grep -nE '0\.(6|7|85)0?[^0-9]' | head -3)"
else ok "7: no threshold constant in dispatch.sh code"; fi
if code "$D" | grep -qE '\b(600000|700000|850000)\b'; then
  bad "7: no ppm threshold constant in dispatch.sh code" "$(code "$D" | grep -nE '\b(600000|700000|850000)\b' | head -3)"
else ok "7: no ppm threshold constant in dispatch.sh code"; fi
# the pure budget functions must not mention a harness at all
PURE="$(sed -n '/^# budget_estimate_tokens/,/^budget_ratio_decimal/p;/^budget_ratio_decimal/,/^}/p' "$D")"
for w in claude codex qwen gateway; do
  hasnt "7: the budget arithmetic mentions no '$w'" "$PURE" "$w"
done
# reason codes carry no harness vocabulary
for c in $(yq -r '.reason_codes[]' "$POLICY") $(yq -r '.budget_states[]' "$POLICY"); do
  case "$c" in *CLAUDE*|*CODEX*|*OPUS*|*GPT*) bad "7: reason/state code '$c' is harness-specific" ;; esac
done
ok "7: no reason code or budget state carries a harness name"

# --- AC-6: make-stamp.sh untouched, and its request body carries nothing --
N="$(git -C "$KIT_ROOT" diff --numstat 39fd66c..HEAD -- files/model-router/scripts/make-stamp.sh | wc -l)"
eq "7/AC-6: make-stamp.sh is untouched by this change" "$N" "0"
for f in files/model-router/scripts/make-stamp.sh \
         files/model-router/catalog.yaml \
         contracts/agent-router/execution-stamp.schema.json; do
  [[ -e "$KIT_ROOT/$f" ]] || continue
  n="$(git -C "$KIT_ROOT" diff --numstat 39fd66c..HEAD -- "$f" | wc -l)"
  eq "7/AC-6: $f untouched" "$n" "0"
done
if grep -q 'context_size' "$D"; then bad "7/AC-6: 'context_size' appears in dispatch.sh" "$(grep -n context_size "$D"|head -2)"
else ok "7/AC-6: 'context_size' appears nowhere in dispatch.sh"; fi
CURLS="$(code "$D" | grep -E 'curl ' || true)"
[[ -n "$CURLS" ]] && ok "7/AC-6 CONTROL: dispatch.sh does make an HTTP call" || bad "7/AC-6 CONTROL: dispatch.sh does make an HTTP call"
if grep -q '/v1/route' <<<"$CURLS"; then bad "7/AC-6: a curl call targets /v1/route" "$CURLS"
else ok "7/AC-6: no curl call targets /v1/route"; fi
grep -q '/v1/place' <<<"$CURLS" && ok "7/AC-6: the only curl target is /v1/place" || bad "7/AC-6: the only curl target is /v1/place" "$CURLS"

# --- a REAL make-stamp round trip against a stub router -------------------
T="$(mktemp -d /tmp/afk15a-ms.XXXXXX)"; mkdir -p "$T/bin"
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do
  [[ "$prev" == "-o" ]] && out="$a"
  if [[ "$prev" == "-d" ]]; then
    if [[ "${a:0:1}" == "@" ]]; then cat "${a:1}" > "$CAPTURE"; else printf '%s' "$a" > "$CAPTURE"; fi
  fi
  prev="$a"
done
[[ -n "$out" ]] && cat "$RESP" > "$out"
printf '200'
STUB
chmod +x "$T/bin/curl"
cat > "$T/req.json" <<'JSON'
{"story_id":"STORY-SIZED-1","title":"a story that a sizing estimate was computed for",
 "summary":"pre-dispatch sizing ran for this story","ambiguity":"low","blast_radius":"low",
 "volume_hint":"high","tags":["docs"]}
JSON
cat > "$T/resp.json" <<'JSON'
{"harness":"claude","model_profile":"claude/strong","effort":"high","cost_class":"subscription",
 "entitlement_pool":"anthropic-max","metered":false,"placement_policy":"prefer-warm-local",
 "placement_required":false,"catalog_version":"sha256:abc","expires_at":"2099-01-01T00:00:00Z"}
JSON
if PATH="$T/bin:$PATH" CAPTURE="$T/body.json" RESP="$T/resp.json" \
   AGENT_FLOW_CONFIG="$T/none.yaml" SUBSCRIPTIONS_FILE="" \
   AGENT_ROUTER_URL="https://router.invalid" AGENT_ROUTER_TOKEN=t \
   bash "$MS" --request "$T/req.json" --out "$T/stamp.json" >/dev/null 2>&1; then
  ok "7/AC-6 CONTROL: the make-stamp round trip ran"
  eq "7/AC-6: the POSTed body carries no context_size" "$(jq -r 'has("context_size")' "$T/body.json")" "false"
  eq "7/AC-6: nor any capacity input under another name" \
     "$(jq -r '[paths(scalars)|join(".")|select(test("context|window|budget|capacity|token|size";"i"))]|length' "$T/body.json")" "0"
  eq "7/AC-6: the resulting stamp has no context_size" "$(jq -r '.task|has("context_size")' "$T/stamp.json")" "false"
  printf '     (info) POSTed keys: %s\n' "$(jq -c 'keys' "$T/body.json")"
else bad "7/AC-6: the make-stamp round trip failed" "$(PATH="$T/bin:$PATH" CAPTURE=$T/body.json RESP=$T/resp.json AGENT_ROUTER_URL=https://router.invalid AGENT_ROUTER_TOKEN=t bash "$MS" --request "$T/req.json" --out "$T/stamp.json" 2>&1 | tail -3)"; fi
summary
