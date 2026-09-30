#!/usr/bin/env bash
# make-stamp-override-tests.sh — the isolated gate for the entitlement pool an
# override stamps. Hermetic: --response mode, a fixture route response and a
# fixture catalog modelled on 1.9.1; no network, no router, no host state.
#
# Usage: tests/make-stamp-override-tests.sh
# Exit:  0 all passed, 1 any failure.

set -uo pipefail

KIT_ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
MAKE_STAMP="$KIT_ROOT/files/model-router/scripts/make-stamp.sh"
CATALOG="$KIT_ROOT/tests/fixtures/make-stamp-override-catalog.yaml"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

unset AFK_ORCA_BIN ORCA_CLI_COMMAND AGENT_ROUTER_URL AGENT_ROUTER_TOKEN \
      AFK_ROUTE_AVAILABLE_BINDINGS_CONTRACT AGENT_ROUTER_TOKEN_ENV
export HOME="$WORK/home" AGENT_FLOW_CONFIG="$WORK/none.yaml" SUBSCRIPTIONS_FILE=""
mkdir -p "$HOME"

PASS=0 FAIL=0 SKIP=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; FAIL=$((FAIL + 1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }

cat > "$WORK/resp.json" <<'JSON'
{"harness":"claude","model_profile":"claude/strong","effort":"high","cost_class":"subscription",
 "entitlement_pool":"anthropic-max","placement_policy":"prefer-warm-local","placement_required":false,
 "metered":false,"catalog_version":"sha256:deadbeef","expires_at":"2099-06-01T12:34:56Z"}
JSON

# ov <out> <catalog-or-empty> <harness> <profile> [response]: mint an override; the exit code is the result.
ov() {
  local out="$1" cat="$2" h="$3" p="$4" resp="${5:-$WORK/resp.json}"
  AGENT_STAMP_VALIDATE_CATALOG_PATH="$cat" bash "$MAKE_STAMP" --response "$resp" --story-id T-1 \
    --override-harness "$h" --override-profile "$p" --override-actor josh --override-reason "test" \
    --out "$out" 2>"$WORK/err"
}
# refused <name> <catalog> <harness> <profile> <message-fragment> [response]
refused() {
  local name="$1" out="$WORK/refused.json"; rm -f "$out"
  if ov "$out" "$2" "$3" "$4" "${6:-$WORK/resp.json}"; then bad "$name: refused" "a stamp was written"
  elif [[ -e "$out" ]]; then bad "$name: refused" "a stamp was left behind"
  elif ! grep -q -- "$5" "$WORK/err"; then bad "$name: refused" "message lacks '$5': $(tail -1 "$WORK/err")"
  else ok "$name: refused, no stamp written"; fi
}

echo "override pool comes from the trusted catalog"
if ov "$WORK/a.json" "$CATALOG" codex openai/strong; then
  assert_eq "claude/strong -> openai/strong: pool"      "$(jq -r .entitlement_pool "$WORK/a.json")" openai-plus
  assert_eq "claude/strong -> openai/strong: cost_class" "$(jq -r .cost_class "$WORK/a.json")" subscription
  assert_eq "claude/strong -> openai/strong: metered"    "$(jq -r .metered "$WORK/a.json")" false
  assert_eq "override record: original recommendation"   "$(jq -c '.override.original' "$WORK/a.json")" '{"harness":"claude","model_profile":"claude/strong"}'
  assert_eq "override record: actor, reason kept"        "$(jq -r '[.override.actor,.override.reason]|join("/")' "$WORK/a.json")" josh/test
  assert_eq "stamp shape stays closed"                   "$(jq -r '[keys[]] - ["harness","model_profile","effort","cost_class","entitlement_pool","metered","placement_policy","placement_required","catalog_version","catalog_document_version","expires_at","task","override","created_at"] | length' "$WORK/a.json")" 0
else bad "claude/strong -> openai/strong mints" "$(tail -2 "$WORK/err")"; fi

if ov "$WORK/l.json" "$CATALOG" claude local-code-standard; then
  assert_eq "local profile: pool null"       "$(jq -c .entitlement_pool "$WORK/l.json")" null
  assert_eq "local profile: cost_class free" "$(jq -r .cost_class "$WORK/l.json")" free
  assert_eq "local profile: metered false"   "$(jq -r .metered "$WORK/l.json")" false
else bad "local override mints" "$(tail -2 "$WORK/err")"; fi

echo "no override leaves the decision untouched"
AGENT_STAMP_VALIDATE_CATALOG_PATH="" bash "$MAKE_STAMP" --response "$WORK/resp.json" --story-id T-1 --out "$WORK/n.json" 2>/dev/null
assert_eq "no override: pool unchanged"    "$(jq -r .entitlement_pool "$WORK/n.json")" anthropic-max
proj='{harness,model_profile,effort,cost_class,entitlement_pool,metered,placement_policy,placement_required,catalog_version,expires_at}'
assert_eq "no override: decision fields byte-for-byte" "$(jq -c "$proj" "$WORK/n.json")" "$(jq -c "$proj" "$WORK/resp.json")"
assert_eq "no override: override is null"  "$(jq -c .override "$WORK/n.json")" null

echo "fail closed"
refused "catalog missing"     "$WORK/absent.yaml" codex openai/strong "no trusted catalog"
refused "profile unknown"     "$CATALOG" codex openai/nope "not in the trusted catalog"
refused "pair not in routing_pairs" "$CATALOG" claude openai/strong "not a routing pair"

yq '.profiles["openai/strong"].entitlements = []' "$CATALOG" > "$WORK/zero.yaml"
printf 'profiles: [unterminated\n  not: yaml: at all' > "$WORK/garbage.yaml"
refused "garbage catalog" "$WORK/garbage.yaml" codex openai/strong "unreadable or malformed"
refused "zero entitlements"   "$WORK/zero.yaml" codex openai/strong "0 entitlements"
yq '.profiles["openai/strong"].entitlements += [{"pool":"anthropic-max","cost_class":"subscription"}]' "$CATALOG" > "$WORK/two.yaml"
refused "two entitlements"    "$WORK/two.yaml" codex openai/strong "2 entitlements"

yq '.profiles["openai/strong"].entitlements = [{"pool":"openai-plus","cost_class":"metered"}]' "$CATALOG" > "$WORK/metered.yaml"
refused "metered, response mode carries no allow_metered" "$WORK/metered.yaml" codex openai/strong "allow_metered"
bad_ent() { yq "$2" "$CATALOG" > "$WORK/$1.yaml"; }
bad_ent scalar-ent '.profiles["openai/strong"].entitlements = "openai-plus"'
refused "entitlements is a scalar (no bare exit)" "$WORK/scalar-ent.yaml" codex openai/strong "unreadable or malformed"
bad_ent empty-pool '.profiles["openai/strong"].entitlements[0].pool = ""'
refused "empty pool" "$WORK/empty-pool.yaml" codex openai/strong "malformed entitlement pool"
bad_ent null-pool '.profiles["openai/strong"].entitlements[0].pool = null'
refused "subscription with null pool" "$WORK/null-pool.yaml" codex openai/strong "no pool"
bad_ent empty-cost '.profiles["openai/strong"].entitlements[0].cost_class = ""'
refused "empty cost_class" "$WORK/empty-cost.yaml" codex openai/strong "unrecognised cost_class"
bad_ent no-cost 'del(.profiles["openai/strong"].entitlements[0].cost_class)'
refused "missing cost_class" "$WORK/no-cost.yaml" codex openai/strong "unrecognised cost_class"
refused "metered in --response mode says why" "$WORK/metered.yaml" codex openai/strong "no route request"
echo '{"story_id":"T-1","title":"t","allow_metered":false}' > "$WORK/req-no.json"
echo '{"story_id":"T-1","title":"t","allow_metered":true}'  > "$WORK/req-yes.json"
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<STUB
#!/usr/bin/env bash
out=""; prev=""
for a in "\$@"; do [[ "\$prev" == "-o" ]] && out="\$a"; prev="\$a"; done
[[ -n "\$out" ]] && cat "$WORK/resp.json" > "\$out"
printf '200'
STUB
chmod +x "$WORK/bin/curl"
routed() { # <request> <out>
  PATH="$WORK/bin:$PATH" AGENT_ROUTER_URL=http://router.invalid AGENT_ROUTER_TOKEN=x \
  AGENT_STAMP_VALIDATE_CATALOG_PATH="$WORK/metered.yaml" bash "$MAKE_STAMP" --request "$1" \
    --override-harness codex --override-profile openai/strong --override-actor josh --override-reason t --out "$2" 2>"$WORK/err"
}
if routed "$WORK/req-no.json" "$WORK/m0.json"; then bad "metered with allow_metered false: refused" "a stamp was written"
elif [[ -e "$WORK/m0.json" ]] || ! grep -q "allow_metered" "$WORK/err"; then bad "metered with allow_metered false: refused for the right reason" "$(tail -1 "$WORK/err")"
else ok "metered with allow_metered false: refused on allow_metered, no stamp written"; fi
if routed "$WORK/req-yes.json" "$WORK/m1.json"; then
  assert_eq "metered with allow_metered true: pool, metered" "$(jq -r '[.entitlement_pool,.cost_class,.metered]|join("/")' "$WORK/m1.json")" openai-plus/metered/true
else bad "metered with allow_metered true mints" "$(tail -2 "$WORK/err")"; fi

echo "installed validator accepts the override stamp"
if command -v agent-stamp-validate >/dev/null; then
  digest="sha256:$( (sha256sum "$CATALOG" 2>/dev/null || shasum -a 256 "$CATALOG") | cut -d' ' -f1)"
  jq --arg d "$digest" '.catalog_version=$d' "$WORK/resp.json" > "$WORK/resp-v.json"
  if ov "$WORK/v.json" "$CATALOG" codex openai/strong "$WORK/resp-v.json"; then
    if agent-stamp-validate --catalog "$CATALOG" --stamp "$WORK/v.json" >"$WORK/verdict.json" 2>&1; then ok "validator accepts claude/strong -> codex openai/strong"
    else bad "validator accepts the override stamp" "$(head -c 300 "$WORK/verdict.json")"; fi
  else bad "override stamp for the validator mints" "$(tail -2 "$WORK/err")"; fi
else
  SKIP=$((SKIP + 1)); printf '  \033[33mSKIP\033[0m agent-stamp-validate not on PATH; validator acceptance not exercised\n'
fi

printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
(( FAIL == 0 ))
