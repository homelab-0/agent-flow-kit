#!/usr/bin/env bash
# probe-02 — F2/B2 re-transcribed against LEDGER semantics.
#
# attack-05's setup planted per-cycle RESULT files to reach the cap. That is no
# longer the count, so the whole scenario is rebuilt from REAL launches: two
# continuations are actually dispatched, and the ledger they write is what the
# cap is read from. Then the first reviewer's two defects are re-run.
cd "$(git rev-parse --show-toplevel)"
E="_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.5C-POSTFIX-REVIEW"
ROOT="$(pwd)"
# shellcheck source=/dev/null
source "$E/harness-lib.sh"
KIT_ROOT="$ROOT"; DISPATCH="$KIT_ROOT/files/model-router/scripts/dispatch.sh"
# shellcheck source=/dev/null
source "$E/fixtures2.sh"

handover() { # <basename> <cycle> <from-cycle>   — the cycle's own thin result says it handed over
  jq -n --arg s "$1" --argjson c "$2" --argjson f "$3" \
    '{story:$s, cycle:$c, status:"continuation_required",
      budget:{state:"CONTINUATION_REQUIRED", usage_tokens:190000, usage_ratio:0.950000,
              continuation_artifact:null, continuation_of:{cycle:$f}}}' \
    > "$WT/$1.md.result.c$2.json"
}
LG() { jq -c '[.entries[].cycle]' "$WT/$1.md.continuations.json"; }
LN() { jq -r '.entries|length' "$WT/$1.md.continuations.json"; }

head1 "A. the HAPPY PATH: two continuations launch, the ledger has two, the third refuses"
reset_stubs; spawn_reset
cont_story p2                       # max_cycles: 8, so only the cap can refuse
retain p2 1 null                    # cycle 1 handed over
assert_no_file "before any launch: no ledger exists" "$WT/p2.md.continuations.json"
rc="$(run_dispatch p2.md 2)"; assert_eq "continuation 1 of $CAP launches" "$rc" "0"
assert_eq "ledger after launch 1" "$(LG p2)" "[2]"
handover p2 2 1
reset_stubs; rc="$(run_dispatch p2.md 3)"; assert_eq "continuation $CAP of $CAP launches" "$rc" "0"
assert_eq "ledger after launch 2" "$(LG p2)" "[2,3]"
handover p2 3 2
reset_stubs; rm -f "$WT/p2.md.blocked"
rc="$(run_dispatch p2.md 4)"
assert_eq "the third continuation refuses" "$rc" "3"
assert_contains "at the cap, typed" "$(cat "$WT/p2.md.blocked")" "reason=CONTINUATION_CAP_REACHED"
assert_contains "counting the ledger's length" "$(cat "$WT/p2.md.blocked")" "count=$CAP"
assert_eq "and a refusal spends nothing: the ledger is unmoved" "$(LN p2)" "$CAP"
assert_empty_file "nothing launched" "$STUB_STATE/terminal-creates"
printf '  ledger: %s\n' "$(jq -c . "$WT/p2.md.continuations.json")"

head1 "B. the BYPASS (attack-05 B): re-dispatch the PREVIOUS cycle number"
reset_stubs; rm -f "$WT/p2.md.blocked"
BEFORE_C3="$(cat "$WT/p2.md.result.c3.json")"
rc="$(run_dispatch p2.md 3)"
printf '  exit=%s  terminals launched=%s\n' "$rc" "$(wc -l < "$STUB_STATE/terminal-creates")"
assert_eq "the earlier cycle number is REFUSED, not launched" "$rc" "3"
BM="$(cat "$WT/p2.md.blocked")"
assert_contains "with the stable reason code" "$BM" "reason=CYCLE_ALREADY_RETAINED"
assert_contains "naming the cycle"            "$BM" "cycle=3"
assert_contains "and the next free cycle"     "$BM" "next_free_cycle=4"
assert_contains "NEEDS-HUMAN typed marker"    "$BM" "NEEDS-HUMAN:"
assert_empty_file "nothing was launched"      "$STUB_STATE/terminal-creates"
assert_empty_file "nothing was placed"        "$STUB_STATE/curl-calls"
assert_eq "the ledger did not grow"           "$(LN p2)" "$CAP"
head1 "   ... and it cannot be repeated"
for i in 1 2 3; do
  reset_stubs; rm -f "$WT/p2.md.blocked"
  r="$(run_dispatch p2.md 3)"; printf '    repeat %s: exit=%s\n' "$i" "$r"
  assert_eq "repeat $i still refused" "$r" "3"
done

head1 "C. the DEFLATION (attack-05 B/C): the retained result cannot be rewritten"
assert_eq "cycle 3's retained result is byte-identical to before the re-dispatch" \
  "$(cat "$WT/p2.md.result.c3.json")" "$BEFORE_C3"
assert_eq "so the count cannot go down" "$(LN p2)" "$CAP"

head1 "D. CONTROL (attack-05 C): the cap still holds for 4 and for 5"
for c in 4 5; do
  reset_stubs; rm -f "$WT/p2.md.blocked"
  r="$(run_dispatch p2.md "$c")"
  assert_eq "cycle $c is still refused" "$r" "3"
  assert_contains "cycle $c refused at the CAP" "$(cat "$WT/p2.md.blocked")" "reason=CONTINUATION_CAP_REACHED"
done

head1 "E. the count is the LENGTH, whatever the cycle numbers say"
reset_stubs; spawn_reset
write_story "$WT/p2n.md" "persona: dev
gates: [\"true\"]
max_cycles: 99"
write_stamp "$WT/p2n.md.stamp.json" high false
printf '%s' "$CONT_BODY" > "$WT/p2n.md.continuation.json"
retain p2n 40 '{"cycle":39}'
jq -n '{schema:"afk-continuation-ledger/1",
        entries:[{cycle:900,from_cycle:1,artifact_sha256:"x",trigger:"WORKER_SIGNAL",at:"t",decision:null},
                 {cycle:901,from_cycle:2,artifact_sha256:"x",trigger:"WORKER_SIGNAL",at:"t",decision:null}]}' \
  > "$WT/p2n.md.continuations.json"
rm -f "$WT/p2n.md.blocked"
rc="$(run_dispatch p2n.md 41)"
assert_eq "two entries with unrelated cycle numbers still reach the cap" "$rc" "3"
assert_contains "and are counted as $CAP" "$(cat "$WT/p2n.md.blocked")" "count=$CAP"
# CONTROL: one entry is under the cap
jq -n '{schema:"afk-continuation-ledger/1",
        entries:[{cycle:900,from_cycle:1,artifact_sha256:"x",trigger:"WORKER_SIGNAL",at:"t",decision:null}]}' \
  > "$WT/p2n.md.continuations.json"
reset_stubs; rm -f "$WT/p2n.md.blocked"
rc="$(run_dispatch p2n.md 41)"
assert_eq "CONTROL: one entry is under the cap and proceeds" "$rc" "0"
assert_eq "CONTROL: and the launch appended the third-from-nothing entry" "$(LN p2n)" "2"

head1 "F. an unreadable ledger is not an empty one"
for bad_ledger in 'not json' '{"schema":"afk-continuation-ledger/2","entries":[]}' '{"entries":[]}' '[]'; do
  reset_stubs; spawn_reset
  cont_story p2u; retain p2u 1 null
  printf '%s' "$bad_ledger" > "$WT/p2u.md.continuations.json"
  rc="$(run_dispatch p2u.md 2)"
  assert_eq "refuses on ledger <$bad_ledger>" "$rc" "3"
  assert_contains "saying a count that cannot be read is not zero" \
    "$(cat "$WORK/err")" "not a count of zero"
  assert_empty_file "and nothing was launched" "$STUB_STATE/terminal-creates"
done
# CONTROL: the well-formed empty ledger reads as zero and proceeds
reset_stubs; spawn_reset
cont_story p2u2; retain p2u2 1 null
printf '{"schema":"afk-continuation-ledger/1","entries":[]}' > "$WT/p2u2.md.continuations.json"
rc="$(run_dispatch p2u2.md 2)"
assert_eq "CONTROL: a well-formed empty ledger proceeds" "$rc" "0"

head1 "G. the entry is written only when a window is actually spent"
# a stamp refusal happens AFTER the cap gate and BEFORE the launch
reset_stubs; spawn_reset
cont_story p2x; retain p2x 1 null
rm -f "$WT/p2x.md.blocked"
rc="$(STUB_VALIDATOR_EXIT=1; export STUB_VALIDATOR_EXIT; run_dispatch p2x.md 2)"
printf '  stamp-refusal exit=%s\n' "$rc"
assert_no_file "a refused attempt writes NO ledger" "$WT/p2x.md.continuations.json"

head1 "H. ADVERSARIAL — the ledger is a file in the worker's own sandbox"
reset_stubs; spawn_reset
rm -f "$WT/p2.md.blocked"
mv "$WT/p2.md.continuations.json" "$WORK/stash-ledger.json"
rc="$(run_dispatch p2.md 4)"
printf '  after deleting the ledger, the capped cycle 4 -> exit=%s\n' "$rc"
if [[ "$rc" == "0" ]]; then
  bad "deleting the ledger hands the capped story its windows back" "exit 0, launched"
else
  ok "deleting the ledger does not resurrect the capped story"
fi
mv "$WORK/stash-ledger.json" "$WT/p2.md.continuations.json"

head1 "I. CONTROL — an ORDINARY cycle is still re-dispatchable (the documented recovery)"
reset_stubs; spawn_reset
cont_story p2o; retain p2o 1 null
rc="$(run_dispatch p2o.md 1)"          # cycle 1 is ordinary: no prior result below it
assert_eq "an ordinary cycle re-dispatches" "$rc" "0"
assert_no_file "and writes no ledger entry" "$WT/p2o.md.continuations.json"

head1 "J. RESIDUAL — a continuation UNDER the cap still meets the UNTYPED max_cycles"
# B1 was fixed by putting the CAP gate first. A continuation that is not at the
# cap still falls through to max_cycles, which at the shipped default of 3 is
# the same untyped message with no marker and no remedy.
sed 's/^continuation_cap: .*/continuation_cap: 9/' "$BUDGET_POLICY_SHIPPED" > "$WORK/cap9.yaml"
reset_stubs; spawn_reset
dflt_story p2m; retain p2m 3 '{"cycle":2}'; ledger p2m 2 3
rm -f "$WT/p2m.md.blocked"
rc="$(STUB_BUDGET_POLICY="$WORK/cap9.yaml"; export STUB_BUDGET_POLICY; run_dispatch p2m.md 4)"
printf '  cap 9, max_cycles at the shipped default -> exit=%s\n  stderr: %s\n  marker: %s\n' \
  "$rc" "$(grep -o 'max_cycles ([0-9]*) exceeded' "$WORK/err" || echo none)" \
  "$(cat "$WT/p2m.md.blocked" 2>/dev/null || echo '<none written>')"
assert_eq "refused" "$rc" "3"
if grep -q 'max_cycles (3) exceeded' "$WORK/err"; then
  bad "under the cap the refusal is the UNTYPED max_cycles message, with no marker and no remedy" \
      "same shape as B1, one gate further along"
else ok "under the cap the refusal is typed"; fi

printf '\n%s: %s passed, %s failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
