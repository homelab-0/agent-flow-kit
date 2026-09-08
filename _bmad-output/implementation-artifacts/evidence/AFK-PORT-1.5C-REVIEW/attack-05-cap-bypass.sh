#!/usr/bin/env bash
# ATTACK 5 — can the cap be walked around without a recorded decision?
# The cap counts prior cycles 1..n-1. The cycle NUMBER is an operator argument.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
E="_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.5C-REVIEW"; ROOT="$PWD"
# shellcheck source=/dev/null
source "$E/harness-lib.sh"
KIT_ROOT="$ROOT"; DISPATCH="$KIT_ROOT/files/model-router/scripts/dispatch.sh"
: > "$STUB_STATE/terminal-creates"
export STUB_TERMINAL_TAIL="ok
CLAUDE_EXIT=0"
CONT_OK='{"schema":"afk-continuation/1","completed":["a"],"current_state":"half",
 "remaining_acceptance":["AC-2"],"next_steps":["b"],"updated_at":"2026-09-07T00:00:00Z",
 "in_flight":[],"unretired_findings":[]}'
plant() { jq -n --arg s "$WT/$1.md" --argjson c "$2" --argjson cof "$4" --arg st "$3" \
  '{story:$s,cycle:$c,status:$st,budget:{state:"CONTINUATION_REQUIRED",usage_tokens:9,usage_ratio:0.9,
    continuation_artifact:{path:"x",sha256:"sha256:aa"},continuation_of:$cof,findings:[]}}' \
  > "$WT/$1.md.result.c$2.json"; }
mk() { write_story "$WT/$1.md" "persona: dev
gates: [\"true\"]
max_cycles: 9"; write_stamp "$WT/$1.md.stamp.json" high false
  printf '%s' "$CONT_OK" > "$WT/$1.md.continuation.json"; }

head1 "A. the cap fires at cycle 4 (baseline)"
mk byp
plant byp 1 continuation_required null
plant byp 2 continuation_required '{"cycle":1}'
plant byp 3 continuation_required '{"cycle":2}'
rc=$(run_dispatch "$WT/byp.md" 4)
assert_eq "cycle 4 is refused at the cap" "$rc" "3"
assert_contains "with the typed marker" "$(cat "$WT/byp.md.blocked")" "CONTINUATION_CAP_REACHED"

head1 "B. the operator now re-dispatches the PREVIOUS cycle number instead"
creates_before=$(wc -l < "$STUB_STATE/terminal-creates")
rc=$(run_dispatch "$WT/byp.md" 3)
launched=$(( $(wc -l < "$STUB_STATE/terminal-creates") - creates_before ))
echo "  exit=$rc  terminals launched=$launched"
if [[ "$rc" == "0" && "$launched" -gt 0 ]]; then
  bad "a story refused at the cap cannot get another window by re-running an earlier cycle number" \
      "cycle 3 re-dispatched as a continuation and LAUNCHED, with no recorded decision"
else
  ok "a story refused at the cap cannot get another window by re-running an earlier cycle number"
fi
[[ -f "$WT/byp.md.result.json" ]] && {
  echo "  continuation_of: $(jq -c '.budget.continuation_of' "$WT/byp.md.result.json")"
  echo "  findings:        $(jq -c '.budget.findings' "$WT/byp.md.result.json")"
  echo "  decision:        $(jq -c '.budget.continuation_decision' "$WT/byp.md.result.json")"; }
echo "  --- and it can be repeated indefinitely ---"
for i in 1 2 3; do rc=$(run_dispatch "$WT/byp.md" 3); echo "    repeat $i: exit=$rc"; done

head1 "C. CONTROL — the cap still holds for the cycle it was computed for"
rc=$(run_dispatch "$WT/byp.md" 4)
assert_eq "control: cycle 4 is still refused" "$rc" "3"
rc=$(run_dispatch "$WT/byp.md" 5)
assert_eq "control: cycle 5 is refused too"   "$rc" "3"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
