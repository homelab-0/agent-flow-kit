#!/usr/bin/env bash
# probe-05 — the first reviewer's attack-03 A / attack-05 setups, replayed with
# the MARKERS printed, so each of their now-failing assertions can be labelled
# setup artefact or regression rather than guessed at.
cd "$(git rev-parse --show-toplevel)"
E="_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.5C-POSTFIX-REVIEW"
ROOT="$(pwd)"
# shellcheck source=/dev/null
source "$E/harness-lib.sh"
KIT_ROOT="$ROOT"; DISPATCH="$KIT_ROOT/files/model-router/scripts/dispatch.sh"
# shellcheck source=/dev/null
source "$E/fixtures2.sh"
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
why() { printf '    exit=%s  marker=%s\n' "$1" "$(head -1 "$2" 2>/dev/null || echo '<none>')"; }

head1 "attack-05's setup, replayed: RESULTS planted, NO ledger written"
mk byp; plant byp 1 continuation_required null
plant byp 2 continuation_required '{"cycle":1}'; plant byp 3 continuation_required '{"cycle":2}'
assert_no_file "the setup writes no ledger at all" "$WT/byp.md.continuations.json"
reset_stubs; rm -f "$WT/byp.md.blocked"; rc="$(run_dispatch byp.md 4)"; why "$rc" "$WT/byp.md.blocked"
assert_eq "A: cycle 4 LAUNCHES, because the ledger the cap counts is empty" "$rc" "0"
assert_eq "   and the launch wrote the story's first ledger entry" \
  "$(jq -c '[.entries[].cycle]' "$WT/byp.md.continuations.json")" "[4]"
reset_stubs; rm -f "$WT/byp.md.blocked"; rc="$(run_dispatch byp.md 3)"; why "$rc" "$WT/byp.md.blocked"
assert_eq "B: the bypass is CLOSED" "$rc" "3"
assert_contains "   by the retained-result half of the guard" \
  "$(cat "$WT/byp.md.blocked")" "reason=CYCLE_ALREADY_RETAINED"
reset_stubs; rm -f "$WT/byp.md.blocked"; rc="$(run_dispatch byp.md 4)"; why "$rc" "$WT/byp.md.blocked"
assert_contains "C: cycle 4 is refused — by the LEDGER half, not by the cap" \
  "$(cat "$WT/byp.md.blocked")" "reason=CYCLE_ALREADY_RETAINED"
reset_stubs; rm -f "$WT/byp.md.blocked"; rc="$(run_dispatch byp.md 5)"; why "$rc" "$WT/byp.md.blocked"
assert_eq "C: cycle 5 proceeds — one ledger entry is genuinely under the cap of $CAP" "$rc" "0"

head1 "attack-03 A's setup, replayed"
write_story "$WT/dflt.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/dflt.md.stamp.json" high false
printf '%s' "$CONT_OK" > "$WT/dflt.md.continuation.json"
plant dflt 1 continuation_required null
plant dflt 2 continuation_required '{"cycle":1}'; plant dflt 3 continuation_required '{"cycle":2}'
reset_stubs; rm -f "$WT/dflt.md.blocked"; rc="$(run_dispatch dflt.md 4)"; why "$rc" "$WT/dflt.md.blocked"
assert_eq "the cap does not fire, so max_cycles does — count 0, not 2" "$rc" "3"
assert_contains "   the untyped per-story limit" "$(cat "$WORK/err")" "max_cycles (3) exceeded"
assert_no_file  "   and no marker at all" "$WT/dflt.md.blocked"
# the SAME story with the ledger the fix counts from
ledger dflt 2 3
reset_stubs; rm -f "$WT/dflt.md.blocked"; rc="$(run_dispatch dflt.md 4)"; why "$rc" "$WT/dflt.md.blocked"
assert_contains "with a ledger of $CAP, the SAME story gets the typed cap marker" \
  "$(cat "$WT/dflt.md.blocked")" "CONTINUATION-CAP: reason=CONTINUATION_CAP_REACHED"

printf '\n%s: %s passed, %s failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
