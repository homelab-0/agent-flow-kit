#!/usr/bin/env bash
# ATTACK 2 — refusal ordering and side effects. A >= 0.85 estimate must create
# no placement call, no validation call, no terminal, no command text and no
# result; a policy that cannot be read must refuse before the stamp is opened.
# Then: can a launch be reached with a BAD policy?
set -uo pipefail
. "$(dirname "$0")/attack-harness.sh"
setup_env

# ---------- 2a. the refusal at ratio 1.0, on a LOCAL profile --------------
# Deliberately the placement_required profile: if the refusal were ordered
# after /v1/place, this case is the one that would prove it.
reset_stubs
write_story "$WT/s-refuse.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/s-refuse.md.stamp.json" high true local-code-standard
rc="$(run_dispatch s-refuse.md)"
eq "2a: a local profile normally dispatches (baseline)" "$rc" "0"
EST="$(bud .budget.estimate_tokens "$WT/s-refuse.md.result.json")"
[[ -s "$STUB_STATE/curl-calls" ]] && ok "2a CONTROL: the baseline DID call /v1/place" || bad "2a CONTROL: the baseline DID call /v1/place"
rm -f "$WT/s-refuse.md.result.json"
# rebuild the catalog so this profile's window == the estimate -> ratio 1.0
awk -v w="$EST" '{print} /^  local-code-standard:[[:space:]]*$/ {print "    min_context: " w}' \
  "$WORK/catalog.yaml" | grep -v '^    min_context: 65536$' > "$WORK/catalog-tiny.yaml"
reset_stubs; rm -f "$STUB_STATE/validator-argv.txt"
rc="$(STUB_CATALOG="$WORK/catalog-tiny.yaml" run_dispatch s-refuse.md)"
eq "2a: exit code is the distinct EX_SIZING_REFUSED=8" "$rc" "8"
M="$(cat "$WT/s-refuse.md.blocked" 2>/dev/null)"
has "2a: marker is typed STORY-SIZING:" "$M" "STORY-SIZING:"
has "2a: marker names the ratio"        "$M" "ratio=1.000000"
has "2a: marker names the threshold"    "$M" "threshold=0.850000"
emptyfile "$STUB_STATE/curl-calls"       "2a: NO /v1/place call was made"
emptyfile "$STUB_STATE/terminal-creates" "2a: NO Orca terminal was created"
nofile "$STUB_STATE/last-command.txt"    "2a: NO harness command text was built"
nofile "$WT/s-refuse.md.result.json"     "2a: NO result artifact was written"
nofile "$STUB_STATE/validator-argv.txt"  "2a: the stamp validator was NEVER invoked"

# ---------- 2b. the exact 0.85 boundary ------------------------------------
# A first pass at this lived here and was WRONG: it derived the boundary window
# from one story's estimate and applied it to a different story on a different
# profile, so it never actually landed on the boundary. The boundary is proved
# properly in attack-06-exact-boundary.sh, which pads the payload until the
# estimate is exactly 850000 tokens against a 1000000-token window.
printf '     (info) 2b: exact-boundary proof lives in attack-06-exact-boundary.sh\n'

# ---------- 2c. an unreadable / malformed policy refuses first -------------
for case in missing:"$WORK/nope.yaml" unparseable:BROKEN empty:EMPTY; do
  nm="${case%%:*}"; f="${case#*:}"
  case "$f" in BROKEN) f="$WORK/broken.yaml"; printf 'not: [valid\n' > "$f" ;;
               EMPTY)  f="$WORK/empty.yaml"; : > "$f" ;; esac
  reset_stubs; rm -f "$STUB_STATE/validator-argv.txt" "$WT/s-refuse.md.result.json"
  rc="$(STUB_BUDGET_POLICY="$f" run_dispatch s-refuse.md)"
  eq "2c/$nm: refuses with the CONFIG exit code" "$rc" "2"
  has "2c/$nm: names BUDGET_POLICY_UNREADABLE" "$(cat "$WORK/err")" "BUDGET_POLICY_UNREADABLE"
  nofile "$STUB_STATE/validator-argv.txt" "2c/$nm: the stamp was never opened"
  emptyfile "$STUB_STATE/curl-calls" "2c/$nm: no placement call"
  emptyfile "$STUB_STATE/terminal-creates" "2c/$nm: no terminal"
done

# ---------- 2d. can a LAUNCH be reached with a bad policy? ----------------
# Every mutation below must refuse; a dispatch that reaches exit 0 means a
# threshold was reachable from somewhere other than the policy document.
mutate() { # <name> <sed-or-body>
  cp "$SHIPPED_POLICY" "$WORK/mut.yaml"; eval "$2"
  reset_stubs; rm -f "$WT/s-refuse.md.result.json" "$WT/s-refuse.md.blocked"
  local rc; rc="$(STUB_BUDGET_POLICY="$WORK/mut.yaml" run_dispatch s-refuse.md)"
  if [[ "$rc" == "0" ]]; then bad "2d/$1: a bad policy REACHED A LAUNCH" "exit 0; $(head -2 "$WORK/err")"
  else ok "2d/$1: refused (exit $rc)"; fi
  printf '     (info) 2d/%s exit=%s err=%s\n' "$1" "$rc" "$(grep -om1 '[A-Z_]\{6,\}' "$WORK/err" | head -1)"
}
mutate "missing-continuation_ratio" "sed -i '/^continuation_ratio:/d' \"\$WORK/mut.yaml\""
mutate "missing-sizing_risk_ratio"  "sed -i '/^sizing_risk_ratio:/d' \"\$WORK/mut.yaml\""
mutate "missing-estimate_method"    "sed -i '/^estimate_method:/d' \"\$WORK/mut.yaml\""
mutate "missing-continuation_cap"   "sed -i '/^continuation_cap:/d' \"\$WORK/mut.yaml\""
mutate "nonnumeric-threshold"       "sed -i 's/^continuation_ratio: 0.85.*/continuation_ratio: eighty-five/' \"\$WORK/mut.yaml\""
mutate "ratio-dot85"                "sed -i 's/^continuation_ratio: 0.85.*/continuation_ratio: \".85\"/' \"\$WORK/mut.yaml\""
mutate "ratio-percent"              "sed -i 's/^continuation_ratio: 0.85.*/continuation_ratio: \"85%\"/' \"\$WORK/mut.yaml\""
mutate "unknown-estimate-method"    "sed -i 's/^estimate_method:.*/estimate_method: bytes3-v9/' \"\$WORK/mut.yaml\""
mutate "risk-nonnumeric"            "sed -i 's/^sizing_risk_ratio: 0.60.*/sizing_risk_ratio: abc/' \"\$WORK/mut.yaml\""
mutate "checkpoint-nonnumeric"      "sed -i 's/^checkpoint_ratio: 0.70.*/checkpoint_ratio: nope/' \"\$WORK/mut.yaml\""
mutate "budget_states-only-three"   "sed -i '/^  - NOT_EVALUATED/d' \"\$WORK/mut.yaml\""
mutate "reason_codes-only-four"     "sed -i '/^  - BUDGET_POLICY_UNREADABLE/d' \"\$WORK/mut.yaml\""

# --- these are the interesting ones: forms that might be ACCEPTED wrongly --
probe() { # <name> <mutation> -> report exit + resulting decision, no verdict
  cp "$SHIPPED_POLICY" "$WORK/mut.yaml"; eval "$2"
  reset_stubs; rm -f "$WT/s-refuse.md.result.json" "$WT/s-refuse.md.blocked"
  local rc; rc="$(STUB_BUDGET_POLICY="$WORK/mut.yaml" run_dispatch s-refuse.md)"
  printf '     (probe) %-28s exit=%-2s %s\n' "$1" "$rc" \
    "$(grep -om1 'budget policy:.*' "$WORK/err" | head -1)"
}
probe "ratio-0.850 (trailing zero)" "sed -i 's/^continuation_ratio: 0.85.*/continuation_ratio: 0.850/' \"\$WORK/mut.yaml\""
probe "thresholds OUT OF ORDER"    "sed -i 's/^continuation_ratio: 0.85.*/continuation_ratio: 0.10/; s/^sizing_risk_ratio: 0.60.*/sizing_risk_ratio: 0.90/' \"\$WORK/mut.yaml\""
probe "continuation_cap: banana"   "sed -i 's/^continuation_cap: 2.*/continuation_cap: banana/' \"\$WORK/mut.yaml\""
probe "continuation_ratio: 0"      "sed -i 's/^continuation_ratio: 0.85.*/continuation_ratio: 0/' \"\$WORK/mut.yaml\""
probe "budget_states renamed x4"   "sed -i 's/^  - CHECKPOINT_DUE/  - BANANA/' \"\$WORK/mut.yaml\""
summary
