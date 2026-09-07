#!/usr/bin/env bash
# ATTACK 10 — leftovers and ordering side effects the story's own suite does
# not assert: a stale .blocked marker after the story is made dispatchable, the
# prompt file the refusal leaves behind, and a record line written before the
# stamp is validated.
set -uo pipefail
. "$(dirname "$0")/attack-harness.sh"
setup_env
cat_with() { awk -v w="$2" '{print} /^  "claude\/strong":[[:space:]]*$/ {print "    min_context: " w}' \
             "$WORK/catalog.yaml" > "$1"; }
write_story "$WT/s.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/s.md.stamp.json" high false
cat_with "$WORK/c-big.yaml" 100000000
reset_stubs; run_dispatch s.md >/dev/null
EST="$(jq -r .budget.estimate_tokens "$WT/s.md.result.json")"
rm -f "$WT/s.md.result.json"

# 1. refuse, then widen the window and dispatch again
cat_with "$WORK/c-tiny.yaml" "$EST"
reset_stubs
rc="$(STUB_CATALOG="$WORK/c-tiny.yaml" run_dispatch s.md)"
eq "10: the refusal fired" "$rc" "8"
[[ -f "$WT/s.md.prompt" ]] && printf '     (info) the refusal leaves a generated prompt file behind (%s bytes)\n' "$(wc -c < "$WT/s.md.prompt")"
reset_stubs
rc="$(STUB_CATALOG="$WORK/c-big.yaml" run_dispatch s.md)"
eq "10: a widened window dispatches successfully" "$rc" "0"
if [[ -f "$WT/s.md.blocked" ]]; then
  bad "10: the STALE .blocked marker survives a later successful dispatch" \
      "$(head -1 "$WT/s.md.blocked")"
else ok "10: the .blocked marker is cleared by the successful dispatch"; fi
printf '     (info) artifacts after success: %s\n' "$(cd "$WT" && ls s.md* | tr '\n' ' ')"

# 2. does a SIZING_RISK line get written even when the launch then fails?
cat_with "$WORK/c-risk.yaml" "$(( EST * 10 / 7 ))"
write_story "$WT/r.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/r.md.stamp.json" high false
reset_stubs
cat > "$BIN/agent-stamp-validate" <<'STUB'
#!/usr/bin/env bash
jq -n '{valid:false, catalog_version:"sha256:x", checks:[{name:"not_expired",passed:false,reason_code:"stamp_expired",message:"expired"}]}'
exit 1
STUB
chmod +x "$BIN/agent-stamp-validate"
rc="$(STUB_CATALOG="$WORK/c-risk.yaml" run_dispatch r.md)"
printf '     (info) stamp-invalid dispatch exit=%s\n' "$rc"
if grep -qa '^- budget: SIZING_RISK' "$WT/r.md"; then
  bad "10: a SIZING_RISK line is written into the story even though the launch was REFUSED at stamp validation" \
      "$(grep -a '^- budget:' "$WT/r.md")"
else ok "10: no record line is written when the dispatch never launches"; fi
summary
