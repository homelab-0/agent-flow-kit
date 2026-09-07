#!/usr/bin/env bash
# ATTACK 3 — arithmetic at the edges, through the REAL dispatch: exact 0.60 and
# 0.85 boundaries, window 0 / null / negative / non-numeric, huge payloads.
set -uo pipefail
. "$(dirname "$0")/attack-harness.sh"
setup_env

write_story "$WT/s.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/s.md.stamp.json" high false
cat_with() { awk -v w="$2" '{print} /^  "claude\/strong":[[:space:]]*$/ {print "    min_context: " w}' \
             "$WORK/catalog.yaml" > "$1"; }

# Learn this story's estimate with a window so large no threshold can fire.
cat_with "$WORK/c-big.yaml" 100000000
reset_stubs; rc="$(STUB_CATALOG="$WORK/c-big.yaml" run_dispatch s.md)"
EST="$(bud .budget.estimate_tokens "$WT/s.md.result.json")"
eq "3: baseline dispatches with a huge window" "$rc" "0"
printf '     (info) estimate for the fixture story: %s tokens\n' "$EST"

probe_at() { # <name> <window> -> exit code + ratio
  reset_stubs; rm -f "$WT/s.md.result.json" "$WT/s.md.blocked"
  cat_with "$WORK/c-probe.yaml" "$2"
  local rc; rc="$(STUB_CATALOG="$WORK/c-probe.yaml" run_dispatch s.md)"
  if [[ -f "$WT/s.md.result.json" ]]; then
    RATIO="$(jq -r '.budget.estimate_ratio' "$WT/s.md.result.json")"
    FINDINGS="$(jq -c '.budget.findings' "$WT/s.md.result.json")"
  elif [[ -f "$WT/s.md.blocked" ]]; then
    RATIO="$(sed -n '1s/.*ratio=\([0-9.]*\).*/\1/p' "$WT/s.md.blocked")"; FINDINGS="-"
  else RATIO="-"; FINDINGS="-"; fi
  RC="$rc"
  printf '     (info) %-34s window=%-10s exit=%-2s ratio=%-10s findings=%s\n' "$1" "$2" "$rc" "$RATIO" "$FINDINGS"
}

# --- the 0.85 boundary, from both sides -----------------------------------
W_AT=$(( EST * 1000000 / 850000 ))            # ratio >= 0.850000
probe_at "continuation: window AT boundary" "$W_AT"
eq "3: ratio at/over 0.850000 refuses with exit 8" "$RC" "8"
[[ "$RATIO" == 0.85* || "$RATIO" == 0.86* ]] && ok "3: and the refusal ratio really is at the boundary" \
  || bad "3: and the refusal ratio really is at the boundary" "$RATIO"
W_BELOW=$(( EST * 1000000 / 850000 + 1 ))     # one token more window
probe_at "continuation: one token MORE window" "$W_BELOW"
eq "3: one ppm below 0.85 does NOT refuse" "$RC" "0"
if [[ "$(printf '%s' "$RATIO" | tr -d .)" -lt 850000 ]] 2>/dev/null; then ok "3: and its ratio is strictly below the threshold"
else bad "3: and its ratio is strictly below the threshold" "$RATIO"; fi

# --- the 0.60 boundary, from both sides -----------------------------------
W60=$(( EST * 1000000 / 600000 ))
probe_at "sizing risk: window AT 0.60" "$W60"
eq "3: at 0.600000 dispatch proceeds" "$RC" "0"
eq "3: at 0.600000 SIZING_RISK fires (>= is crossing)" "$FINDINGS" '["SIZING_RISK"]'
W60B=$(( EST * 1000000 / 600000 + 1 ))
probe_at "sizing risk: one token MORE window" "$W60B"
eq "3: one ppm below 0.60 fires NO finding" "$FINDINGS" '[]'

# --- degenerate windows ---------------------------------------------------
for w in 0 -1 '"0"' null notanumber 0.5; do
  reset_stubs; rm -f "$WT/s.md.result.json" "$WT/s.md.blocked"
  cat_with "$WORK/c-bad.yaml" "$w"
  rc="$(STUB_CATALOG="$WORK/c-bad.yaml" run_dispatch s.md)"
  if [[ -f "$WT/s.md.result.json" ]]; then
    st="$(jq -r '.budget.state' "$WT/s.md.result.json")"; wt="$(jq -r '.budget.window_tokens' "$WT/s.md.result.json")"
  else st="-"; wt="-"; fi
  printf '     (info) min_context=%-12s exit=%-2s state=%-14s window_tokens=%s\n' "$w" "$rc" "$st" "$wt"
  if [[ "$rc" == "0" && "$st" == "OK" ]]; then
    bad "3/window=$w: a degenerate window must not be reported as a healthy budget" "exit 0, state OK, window $wt"
  else ok "3/window=$w: not silently accepted as a healthy budget (exit $rc state $st)"; fi
done

# --- estimate 0 is unreachable through dispatch (story is never empty) ----
# but the pure function must still be correct, and the ratio must be 0.
. "$DISPATCH" 2>/dev/null || true
eq "3: budget_estimate_tokens 0 -> 0"     "$(budget_estimate_tokens 0 bytes4-v1)" "0"
eq "3: budget_ratio_ppm 0/65536 -> 0"     "$(budget_ratio_ppm 0 65536)" "0"
if budget_ratio_ppm 100 0 >/dev/null 2>&1; then bad "3: ratio refuses a zero window"; else ok "3: ratio refuses a zero window"; fi
if budget_ratio_ppm 100 -5 >/dev/null 2>&1; then bad "3: ratio refuses a negative window"; else ok "3: ratio refuses a negative window"; fi
eq "3: threshold 0.850 == 0.85"           "$(budget_threshold_ppm 0.850)" "$(budget_threshold_ppm 0.85)"
if budget_threshold_ppm '.85' >/dev/null 2>&1; then bad "3: threshold refuses '.85'"; else ok "3: threshold refuses '.85'"; fi
if budget_threshold_ppm '85%' >/dev/null 2>&1; then bad "3: threshold refuses '85%'"; else ok "3: threshold refuses '85%'"; fi
eq "3: threshold 1.0 -> 1000000"          "$(budget_threshold_ppm 1.0)" "1000000"
eq "3: threshold 0.8500001 truncates to 850000 (6dp is the resolution)" \
   "$(budget_threshold_ppm 0.8500001)" "850000"

# --- a huge payload: no overflow, refusal still fires ---------------------
reset_stubs; rm -f "$WT/s.md.result.json" "$WT/s.md.blocked"
head -c 8000000 /dev/zero | tr '\0' 'a' > "$WT/huge.txt"
write_story "$WT/s-huge.md" "persona: dev
gates: [\"true\"]
payload_refs: [huge.txt]"
write_stamp "$WT/s-huge.md.stamp.json" high false
cat_with "$WORK/c-huge.yaml" 200000
rc="$(STUB_CATALOG="$WORK/c-huge.yaml" run_dispatch s-huge.md)"
eq "3/huge: a 20MB payload refuses (exit 8), no overflow" "$rc" "8"
has "3/huge: the marker's ratio is a sane large number" "$(cat "$WT/s-huge.md.blocked")" "ratio=1"
summary
