#!/usr/bin/env bash
# ATTACK 6 — the boundary EXACTLY, through the real dispatch. The fixture in
# attack-03 was too small for one token of window to land on a ppm boundary;
# here the payload is padded so the ratio can be driven to exactly 0.850000 and
# exactly 0.600000, and to one ppm either side of each.
set -uo pipefail
. "$(dirname "$0")/attack-harness.sh"
setup_env
WINDOW=1000000                     # ratio in ppm == estimate in tokens
cat_with() { awk -v w="$2" '{print} /^  "claude\/strong":[[:space:]]*$/ {print "    min_context: " w}' \
             "$WORK/catalog.yaml" > "$1"; }
cat_with "$WORK/c.yaml" "$WINDOW"
export STUB_CATALOG="$WORK/c.yaml"

write_story "$WT/s.md" "persona: dev
gates: [\"true\"]
payload_refs: [pad.txt]"
write_stamp "$WT/s.md.stamp.json" high false

pad_to() { # drive the ESTIMATE to exactly <target> tokens
  local target="$1" size=$(( $1 * 4 )) est i
  for i in 1 2 3 4 5 6; do
    head -c "$size" /dev/zero | tr '\0' 'q' > "$WT/pad.txt"
    reset_stubs; rm -f "$WT/s.md.result.json" "$WT/s.md.blocked"
    ( cd "$WT" && rm -f s.md.result.json ) ; run_dispatch s.md >/dev/null
    if [[ -f "$WT/s.md.result.json" ]]; then est="$(jq -r .budget.estimate_tokens "$WT/s.md.result.json")"
    else est="$(sed -n '1s/.*estimate=\([0-9]*\).*/\1/p' "$WT/s.md.blocked")"; fi
    [[ "$est" == "$target" ]] && { printf '%s' "$size"; return 0; }
    size=$(( size - (est - target) * 4 ))
  done
  printf '%s' "$size"; return 1
}
probe() { # <label> <target-estimate> -> RC / RATIO / FINDINGS
  head -c "$1" /dev/zero | tr '\0' 'q' > "$WT/pad.txt"
  reset_stubs; rm -f "$WT/s.md.result.json" "$WT/s.md.blocked"
  RC="$(run_dispatch s.md)"
  if [[ -f "$WT/s.md.result.json" ]]; then
    RATIO="$(jq -r .budget.estimate_ratio "$WT/s.md.result.json")"
    EST="$(jq -r .budget.estimate_tokens "$WT/s.md.result.json")"
    FINDINGS="$(jq -c .budget.findings "$WT/s.md.result.json")"
  else
    RATIO="$(sed -n '1s/.*ratio=\([0-9.]*\).*/\1/p' "$WT/s.md.blocked")"
    EST="$(sed -n '1s/.*estimate=\([0-9]*\).*/\1/p' "$WT/s.md.blocked")"; FINDINGS="(refused)"
  fi
  printf '     (info) %-30s est=%-8s ratio=%-10s exit=%-2s findings=%s\n' "$2" "$EST" "$RATIO" "$RC" "$FINDINGS"
}

for band in 850000:continuation 700000:checkpoint 600000:sizing_risk; do
  T="${band%%:*}"; NM="${band#*:}"
  SZ="$(pad_to "$T")" && ok "6/$NM: fixture pinned to an estimate of exactly $T tokens" \
    || bad "6/$NM: could not pin the estimate to $T" "landed at $SZ bytes"
  probe "$SZ" "$NM: ratio EXACTLY 0.$T"
  case "$NM" in
    continuation)
      eq "6: ratio EXACTLY 0.850000 REFUSES (equal counts as crossing)" "$RC" "8"
      eq "6: and the refusal reports the exact ratio" "$RATIO" "0.850000"
      probe "$(( SZ - 4 ))" "continuation: 849999 ppm"
      eq "6: ONE ppm below 0.850000 does NOT refuse" "$RC" "0"
      eq "6: and it reports 0.849999" "$RATIO" "0.849999"
      eq "6: and it is still in the risk band" "$FINDINGS" '["SIZING_RISK"]'
      probe "$(( SZ + 4 ))" "continuation: 850001 ppm"
      eq "6: ONE ppm above 0.850000 refuses" "$RC" "8" ;;
    checkpoint)
      eq "6: 0.700000 is NOT a pre-dispatch action (lane B owns it)" "$RC" "0"
      eq "6: 0.700000 produces only SIZING_RISK here" "$FINDINGS" '["SIZING_RISK"]'
      eq "6: and no CHECKPOINT_DUE is ever produced" \
         "$(jq -r '.budget.state' "$WT/s.md.result.json")" "OK" ;;
    sizing_risk)
      eq "6: ratio EXACTLY 0.600000 fires SIZING_RISK" "$FINDINGS" '["SIZING_RISK"]'
      eq "6: and the ratio reported is exact" "$RATIO" "0.600000"
      eq "6: dispatch proceeds" "$RC" "0"
      probe "$(( SZ - 4 ))" "sizing_risk: 599999 ppm"
      eq "6: ONE ppm below 0.600000 fires NOTHING" "$FINDINGS" '[]'
      eq "6: and it reports 0.599999" "$RATIO" "0.599999"
      eq "6: and the state is still OK" "$(jq -r '.budget.state' "$WT/s.md.result.json")" "OK"
      hasnt "6: and nothing was appended to the story" "$(cat "$WT/s.md")" "SIZING_RISK" ;;
  esac
done
summary
