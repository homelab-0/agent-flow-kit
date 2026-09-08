#!/usr/bin/env bash
# ATTACK 2 — the continuation cycle, the cap, the decision key and the stamp
# refusal, driven through the REAL dispatch.sh against the run-tests stub rig
# (harness-lib.sh, extracted verbatim). Every case carries its own control.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
E="_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.5C-REVIEW"
# shellcheck source=/dev/null
ROOT="$PWD"
source "$E/harness-lib.sh"
# harness-lib.sh derives KIT_ROOT from its OWN location; re-pin it to the repo.
KIT_ROOT="$ROOT"; DISPATCH="$KIT_ROOT/files/model-router/scripts/dispatch.sh"
: > "$STUB_STATE/terminal-creates"
# the stub terminal must reach its end state, or every launch "fails" for rig reasons
export STUB_TERMINAL_TAIL="ok
CLAUDE_EXIT=0"

CONT_OK='{"schema":"afk-continuation/1","completed":["a"],"current_state":"half",
 "remaining_acceptance":["AC-2"],"next_steps":["do b"],"updated_at":"2026-09-07T00:00:00Z",
 "in_flight":[],"unretired_findings":[]}'

mk() { # mk <name> [extra-frontmatter]
  write_story "$WT/$1.md" "persona: dev
gates: [\"true\"]
max_cycles: 9${2:+
$2}"
  write_stamp "$WT/$1.md.stamp.json" high false
}
# plant a retained per-cycle result exactly as dispatch.sh writes one
plant() { # plant <story> <cycle> <status> <continuation_of:null|json>
  jq -n --arg s "$WT/$1.md" --argjson c "$2" --arg st "$3" --argjson cof "$4" \
    '{story:$s, cycle:$c, status:$st,
      budget:{state:"CONTINUATION_REQUIRED", usage_tokens:120000, usage_ratio:0.9,
              continuation_artifact:{path:"x",sha256:"sha256:aa"},
              continuation_of:$cof, continuation_decision:null,
              findings:[]}}' > "$WT/$1.md.result.c$2.json"
}
bigart() { # bigart <story> <padding-bytes> — a VALID artifact of a chosen size
  python3 -c 'import json,sys; d=json.load(sys.stdin); d["current_state"]="X"*int(sys.argv[1]); json.dump(d,open(sys.argv[2],"w"))' \
    "$2" "$WT/$1.md.continuation.json" <<<"$CONT_OK"
}
art() { printf '%s' "$CONT_OK" > "$WT/$1.md.continuation.json"; }

head1 "A. an ORDINARY cycle is untouched by a stray artifact"
mk ord; art ord
rc=$(run_dispatch "$WT/ord.md" 1)
assert_eq "ordinary cycle succeeds"            "$rc" "0"
assert_eq "no continuation_of recorded"        "$(jq -r '.budget.continuation_of' "$WT/ord.md.result.json")" "null"
assert_absent "no continuation heading in prompt" "$(cat "$WT/ord.md.prompt")" "Continuation from cycle"
assert_eq "per-cycle result retained"          "$(jq -r .cycle "$WT/ord.md.result.c1.json")" "1"
assert_eq "retained copy is byte-identical"    "$(sha256sum < "$WT/ord.md.result.json" | cut -d' ' -f1)" \
                                               "$(sha256sum < "$WT/ord.md.result.c1.json" | cut -d' ' -f1)"

head1 "B. a real hand-over is consumed into prompt AND estimate"
mk cont; art cont; plant cont 1 continuation_required null
rc=$(run_dispatch "$WT/cont.md" 2)
assert_eq "continuation cycle launches"        "$rc" "0"
assert_contains "fixed heading in prompt"      "$(cat "$WT/cont.md.prompt")" "Continuation from cycle 1"
assert_contains "artifact CONTENT in prompt"   "$(cat "$WT/cont.md.prompt")" '"remaining_acceptance"'
P="$(cat "$WT/cont.md.prompt")"
# ordering: heading must sit after the story instructions and before the budget paragraph
h=$(grep -n 'Continuation from cycle' <<<"$P" | head -1 | cut -d: -f1)
b=$(grep -n -i 'phase boundary\|context budget\|CONTINUATION-REQUIRED:' <<<"$P" | tail -1 | cut -d: -f1)
if (( h < b )); then ok "heading precedes the budget paragraph"; else bad "heading precedes the budget paragraph" "h=$h b=$b"; fi
assert_eq "continuation_of.cycle"              "$(jq -r '.budget.continuation_of.cycle' "$WT/cont.md.result.json")" "1"
assert_eq "continuation_of.trigger"            "$(jq -r '.budget.continuation_of.trigger' "$WT/cont.md.result.json")" "WORKER_SIGNAL"
assert_eq "continuation_of.usage_tokens"       "$(jq -r '.budget.continuation_of.usage_tokens' "$WT/cont.md.result.json")" "120000"
assert_eq "artifact sha is the artifact's"     "$(jq -r '.budget.continuation_of.artifact_sha256' "$WT/cont.md.result.json")" \
                                               "sha256:$(sha256sum < "$WT/cont.md.continuation.json" | cut -d' ' -f1)"
assert_contains "REPEATED_CONTINUATION finding" "$(jq -c '.budget.findings' "$WT/cont.md.result.json")" "REPEATED_CONTINUATION"
assert_contains "record chain line in story"   "$(cat "$WT/cont.md")" "CONTINUATION"
assert_contains "chain line carries the sha"   "$(cat "$WT/cont.md")" "sha256:"
# ESTIMATE: the continuation artifact's bytes must enter the estimate.
# Run under the WINDOWED catalog so a threshold can actually fire.
mk est2; rc2=$(STUB_CATALOG="$WORK/catalog-windowed.yaml" run_dispatch "$WT/est2.md" 1)
e_plain=$(jq -r '.budget.estimate_tokens' "$WT/est2.md.result.json")
mk est3; plant est3 1 continuation_required null; bigart est3 40000
rc3=$(STUB_CATALOG="$WORK/catalog-windowed.yaml" run_dispatch "$WT/est3.md" 2)
e_big=$(jq -r '.budget.estimate_tokens' "$WT/est3.md.result.json")
bytes=$(wc -c < "$WT/est3.md.continuation.json")
if (( e_big - e_plain >= bytes/4 )); then ok "artifact bytes enter the estimate (>= bytes/4)"
else bad "artifact bytes enter the estimate" "big=$e_big plain=$e_plain bytes=$bytes"; fi

# and an artifact large enough must be able to trip the sizing REFUSAL
mk huge; plant huge 1 continuation_required null
bigart huge 800000
creates_before=$(wc -l < "$STUB_STATE/terminal-creates")
rc=$(STUB_CATALOG="$WORK/catalog-windowed.yaml" run_dispatch "$WT/huge.md" 2)
if [[ "$rc" != "0" ]]; then ok "a large continuation artifact trips the sizing refusal (exit $rc)"
else bad "a large continuation artifact trips the sizing refusal" "exit 0"; fi
M="$(cat "$WT/huge.md.blocked" 2>/dev/null)$(cat "$WORK/err")"
assert_contains "refusal names the artifact as a sub-line" "$M" "of which"
assert_contains "  and names the artifact path"            "$M" "huge.md.continuation.json"
assert_eq "nothing launched on the sizing refusal" "$(wc -l < "$STUB_STATE/terminal-creates")" "$creates_before"
# CONTROL: the same story WITHOUT the oversized artifact launches
mk huge2; art huge2; plant huge2 1 continuation_required null
rc=$(STUB_CATALOG="$WORK/catalog-windowed.yaml" run_dispatch "$WT/huge2.md" 2)
assert_eq "control: without the oversized artifact the cycle launches" "$rc" "0"

head1 "C. hand-over with NO / invalid artifact -> loud NEEDS_HUMAN, nothing launched"
mk miss; plant miss 1 continuation_required null
creates_before=$(wc -l < "$STUB_STATE/terminal-creates" 2>/dev/null || echo 0)
rc=$(run_dispatch "$WT/miss.md" 2)
assert_eq "exit 3 (NEEDS_HUMAN)"               "$rc" "3"
assert_contains "marker typed"                 "$(cat "$WT/miss.md.blocked")" "CONTINUATION_ARTIFACT_INVALID"
assert_no_file "no result written"             "$WT/miss.md.result.c2.json"
assert_eq "nothing launched"                   "$(wc -l < "$STUB_STATE/terminal-creates")" "$creates_before"
mk bad1; plant bad1 1 continuation_required null; printf '{"schema":"wrong/1"}' > "$WT/bad1.md.continuation.json"
rc=$(run_dispatch "$WT/bad1.md" 2)
assert_eq "schema mismatch -> exit 3"          "$rc" "3"
assert_contains "verdict named"                "$(cat "$WT/bad1.md.blocked")" "ARTIFACT_SCHEMA_MISMATCH"

head1 "D. the cap: two proceed, the third refuses, a decision authorises one"
mk cap; art cap
plant cap 1 continuation_required null
plant cap 2 continuation_required '{"cycle":1}'
plant cap 3 continuation_required '{"cycle":2}'
creates_before=$(wc -l < "$STUB_STATE/terminal-creates")
rc=$(run_dispatch "$WT/cap.md" 4)
assert_eq "cycle 4 refused (exit 3)"           "$rc" "3"
M="$(cat "$WT/cap.md.blocked")"
assert_contains "typed marker"                 "$M" "CONTINUATION-CAP:"
assert_contains "reason code"                  "$M" "reason=CONTINUATION_CAP_REACHED"
assert_contains "count"                        "$M" "count=2"
assert_contains "cap"                          "$M" "cap=2"
assert_contains "exact frontmatter shape"      "$M" "continuation_decision:"
assert_contains "  names the cycle"            "$M" "cycle: 4"
assert_no_file "no result written at the cap"  "$WT/cap.md.result.c4.json"
assert_eq "nothing placed or launched"         "$(wc -l < "$STUB_STATE/terminal-creates")" "$creates_before"
# CONTROL: the third continuation was refused, but the SECOND was not
mk cap2; art cap2; plant cap2 1 continuation_required null; plant cap2 2 continuation_required '{"cycle":1}'
rc=$(run_dispatch "$WT/cap2.md" 3)
assert_eq "control: cycle 3 (1 consumed) proceeds" "$rc" "0"
# the decision key, for the RIGHT cycle
mk capd "continuation_decision:
  cycle: 4
  actor: josh
  at: 2026-09-07T00:00:00Z
  reason: one more"
art capd; plant capd 1 continuation_required null
plant capd 2 continuation_required '{"cycle":1}'; plant capd 3 continuation_required '{"cycle":2}'
rc=$(run_dispatch "$WT/capd.md" 4)
assert_eq "authorised cycle proceeds"          "$rc" "0"
assert_eq "decision recorded verbatim"         "$(jq -r '.budget.continuation_decision.actor' "$WT/capd.md.result.json")" "josh"
assert_contains "REPEATED_CONTINUATION still fires" "$(jq -c .budget.findings "$WT/capd.md.result.json")" "REPEATED_CONTINUATION"
# the WRONG cycle does not carry forward
mk capw "continuation_decision:
  cycle: 3
  actor: josh
  at: 2026-09-07T00:00:00Z
  reason: earlier"
art capw; plant capw 1 continuation_required null
plant capw 2 continuation_required '{"cycle":1}'; plant capw 3 continuation_required '{"cycle":2}'
rc=$(run_dispatch "$WT/capw.md" 4)
assert_eq "a decision for an earlier cycle does NOT authorise" "$rc" "3"
# malformed decision (member missing)
mk capm "continuation_decision:
  cycle: 4
  actor: josh"
art capm; plant capm 1 continuation_required null
plant capm 2 continuation_required '{"cycle":1}'; plant capm 3 continuation_required '{"cycle":2}'
rc=$(run_dispatch "$WT/capm.md" 4)
assert_eq "a malformed decision does NOT authorise" "$rc" "3"

head1 "E. stale results from ANOTHER story cannot move the count"
mk iso; art iso; plant iso 1 continuation_required null
mk other; plant other 1 continuation_required null; plant other 2 continuation_required '{"cycle":1}'
plant other 3 continuation_required '{"cycle":2}'
rc=$(run_dispatch "$WT/iso.md" 2)
assert_eq "another story's chain is irrelevant" "$rc" "0"

head1 "F. an EXPIRED stamp on a continuation"
mk exp; art exp; plant exp 1 continuation_required null
before="$(sha256sum < "$WT/exp.md.stamp.json" | cut -d' ' -f1)"
creates_before=$(wc -l < "$STUB_STATE/terminal-creates")
rc=$(STUB_VALIDATOR_EXIT=1 run_dispatch "$WT/exp.md" 2)
assert_eq "refused with the validator's own exit" "$rc" "4"
M="$(cat "$WT/exp.md.blocked" 2>/dev/null)"
assert_contains "typed marker"                 "$M" "CONTINUATION-STAMP:"
assert_contains "refresh reason"               "$M" "reason=CONTINUATION_STAMP_REFRESH_REQUIRED"
assert_contains "validator reason beside it"   "$M" "validator_reason=stamp_expired"
assert_contains "names the central refresh"    "$M" "/v1/route"
assert_contains "names make-stamp.sh"          "$M" "make-stamp.sh"
assert_eq "stamp byte-identical afterwards"    "$(sha256sum < "$WT/exp.md.stamp.json" | cut -d' ' -f1)" "$before"
assert_eq "nothing launched"                   "$(wc -l < "$STUB_STATE/terminal-creates")" "$creates_before"
assert_no_file "no result written"             "$WT/exp.md.result.c2.json"
# CONTROL: the same continuation launches on a valid stamp
mk expc; art expc; plant expc 1 continuation_required null
rc=$(run_dispatch "$WT/expc.md" 2)
assert_eq "control: valid stamp -> the same cycle launches" "$rc" "0"
# CONTROL: an ORDINARY cycle with an expired stamp gets NO continuation marker
mk expo
rc=$(STUB_VALIDATOR_EXIT=1 run_dispatch "$WT/expo.md" 1)
assert_eq "control: ordinary expired stamp still exit 4" "$rc" "4"
if [[ -f "$WT/expo.md.blocked" ]] && grep -q CONTINUATION "$WT/expo.md.blocked"; then
  bad "control: ordinary cycle must not get a CONTINUATION-STAMP marker"
else ok "control: ordinary cycle gets no CONTINUATION-STAMP marker"; fi

head1 "G. record-chain idempotence across a re-dispatch of the same cycle"
mk idem; art idem; plant idem 1 continuation_required null
run_dispatch "$WT/idem.md" 2 >/dev/null
n1=$(grep -c 'CONTINUATION' "$WT/idem.md")
run_dispatch "$WT/idem.md" 2 >/dev/null
n2=$(grep -c 'CONTINUATION' "$WT/idem.md")
assert_eq "re-dispatch adds no second line"    "$n2" "$n1"
# CONTROL: a NEW continuation cycle (cycle 3 continuing cycle 2) DOES add a line.
# Cycle 2 above finished `done`, so plant cycle 2 as a hand-over first.
plant idem 2 continuation_required '{"cycle":1}'
run_dispatch "$WT/idem.md" 3 >/dev/null
n3=$(grep -c 'CONTINUATION' "$WT/idem.md")
if (( n3 > n2 )); then ok "control: a NEW continuation cycle does add a line"; else bad "control: a new continuation cycle adds a line" "n2=$n2 n3=$n3"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
