#!/usr/bin/env bash
# probe-03 — F3 (numeric-string cycle), F4 (story binding), F5 (the sizing
# refusal's record line and the determinism claim made for it).
cd "$(git rev-parse --show-toplevel)"
E="_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.5C-POSTFIX-REVIEW"
ROOT="$(pwd)"
# shellcheck source=/dev/null
source "$E/harness-lib.sh"
KIT_ROOT="$ROOT"; DISPATCH="$KIT_ROOT/files/model-router/scripts/dispatch.sh"
# shellcheck source=/dev/null
source "$E/fixtures2.sh"

decision_story() { # <basename> <cycle-literal-as-written>
  write_story "$WT/$1.md" "persona: dev
gates: [\"true\"]
max_cycles: 20
continuation_decision:
  cycle: $2
  actor: pm
  at: 2026-09-07T00:00:00Z
  reason: one more"
  write_stamp "$WT/$1.md.stamp.json" high false
  printf '%s' "$CONT_BODY" > "$WT/$1.md.continuation.json"
}

head1 "F3 — the decision's cycle is read as a number however it was written"
i=0
for SPELL in '4' '"4"' "'4'"; do
  i=$((i+1)); N="p3n$i"
  reset_stubs; spawn_reset
  decision_story "$N" "$SPELL"
  retain "$N" 3 '{"cycle":2}'; ledger "$N" 2 3
  rm -f "$WT/$N.md.blocked"
  rc="$(run_dispatch "$N.md" 4)"
  assert_eq "cycle: $SPELL authorises the capped cycle" "$rc" "0"
  assert_eq "cycle: $SPELL is recorded as a number" \
    "$(bud '.budget.continuation_decision.cycle|type' "$WT/$N.md.result.json")" "number"
  assert_eq "cycle: $SPELL normalises to 4" \
    "$(bud '.budget.continuation_decision.cycle' "$WT/$N.md.result.json")" "4"
done
head1 "   CONTROLS — spellings that are NOT this cycle still do not authorise"
i=0
for SPELL in '5' '"5"' '"four"' 'null' 'true'; do
  i=$((i+1)); N="p3c$i"
  reset_stubs; spawn_reset
  decision_story "$N" "$SPELL"
  retain "$N" 3 '{"cycle":2}'; ledger "$N" 2 3
  rm -f "$WT/$N.md.blocked"
  rc="$(run_dispatch "$N.md" 4)"
  assert_eq "cycle: $SPELL does NOT authorise cycle 4" "$rc" "3"
  assert_contains "cycle: $SPELL is refused at the cap" \
    "$(cat "$WT/$N.md.blocked" 2>/dev/null)" "reason=CONTINUATION_CAP_REACHED"
done

head1 "F4 — the hand-over artifact names the story it belongs to"
mk_bind() { # <basename> <story_id-json-fragment or empty>
  reset_stubs; spawn_reset
  cont_story "$1"; retain "$1" 1 null
  if [[ -n "${2:-}" ]]; then
    printf '%s' "$(ckpt afk-continuation/1 "{\"in_flight\":\"x\",\"unretired_findings\":[],\"story_id\":$2}")" \
      > "$WT/$1.md.continuation.json"
  fi
  rm -f "$WT/$1.md.blocked"
}
mk_bind p3-match '"p3-match"'
rc="$(run_dispatch p3-match.md 2)"
assert_eq "match: consumed" "$rc" "0"
assert_absent "match: and nothing reported as unbound" \
  "$(jq -c '.budget.findings' "$WT/p3-match.md.result.json")" "CONTINUATION_ARTIFACT_UNBOUND"

mk_bind p3-miss '"some-other-story"'
rc="$(run_dispatch p3-miss.md 2)"
assert_eq "mismatch: refused, pre-launch" "$rc" "3"
MM="$(cat "$WT/p3-miss.md.blocked")"
assert_contains "mismatch: on the invalid-artifact path" "$MM" "reason=CONTINUATION_ARTIFACT_INVALID"
assert_contains "mismatch: with the detail"             "$MM" "detail=STORY_MISMATCH"
assert_absent   "mismatch: never quoting the artifact's own content" "$MM" "some-other-story"
assert_no_file  "mismatch: no result claims an outcome" "$WT/p3-miss.md.result.json"
assert_empty_file "mismatch: nothing placed"   "$STUB_STATE/curl-calls"
assert_empty_file "mismatch: nothing launched" "$STUB_STATE/terminal-creates"
assert_no_file  "mismatch: and no ledger entry" "$WT/p3-miss.md.continuations.json"

mk_bind p3-absent ''
rc="$(run_dispatch p3-absent.md 2)"
assert_eq "absent: accepted this cycle" "$rc" "0"
assert_contains "absent: and reported as unbound" \
  "$(jq -c '.budget.findings' "$WT/p3-absent.md.result.json")" "CONTINUATION_ARTIFACT_UNBOUND"

head1 "   ADVERSARIAL — a null / empty story_id is not a mismatch, and not a claim"
j=0
for V in 'null' '""'; do
  j=$((j+1)); N="p3-nul$j"
  mk_bind "$N" "$V"
  rc="$(run_dispatch "$N.md" 2)"
  assert_eq "story_id $V is treated as absent, not a mismatch" "$rc" "0"
  assert_contains "story_id $V is reported unbound" \
    "$(jq -c '.budget.findings' "$WT/$N.md.result.json")" "CONTINUATION_ARTIFACT_UNBOUND"
done
head1 "   the prompt asks the worker for the value the launcher checks"
mk_bind p3-prompt ''
rc="$(run_dispatch p3-prompt.md 2)"
assert_contains "the prompt names the story_id the launcher compares against" \
  "$(cat "$WT/p3-prompt.md.prompt")" 'story_id, which is
"p3-prompt"'

head1 "F5 — a continuation refused by SIZING leaves a record line"
reset_stubs; spawn_reset
cont_story p3s; retain p3s 1 null
rc="$(run_dispatch p3s.md 2)"          # a normal continuation, to learn its estimate
EST="$(bud .budget.estimate_tokens "$WT/p3s.md.result.json")"
# a window equal to that estimate makes the ratio >= 1.0 by construction
awk -v w="$EST" '{print} /^  "claude\/strong":[[:space:]]*$/ {print "    min_context: " w}' \
  "$WORK/catalog.yaml" > "$WORK/catalog-cont.yaml"
# cycle 2 is now settled; run the case as cycle 3
jq -n --arg s p3s --argjson c 2 \
  '{story:$s, cycle:$c, status:"continuation_required",
    budget:{state:"CONTINUATION_REQUIRED", usage_tokens:190000, usage_ratio:0.95,
            continuation_artifact:null, continuation_of:{cycle:1}}}' > "$WT/p3s.md.result.c2.json"
reset_stubs; rm -f "$WT/p3s.md.blocked"
rc="$(STUB_CATALOG="$WORK/catalog-cont.yaml"; export STUB_CATALOG; run_dispatch p3s.md 3)"
assert_eq "sizing: the continuation is refused, exit 8" "$rc" "8"
REFL="$(grep -a '^- budget: CONTINUATION_REFUSED ' "$WT/p3s.md" || true)"
printf '  record line: %s\n' "$REFL"
assert_contains "sizing: one record line, naming the cycle continued" "$REFL" "from cycle 2"
assert_contains "sizing: written for this cycle"                      "$REFL" "cycle 3"
assert_eq "sizing: exactly one such line" \
  "$(grep -ac '^- budget: CONTINUATION_REFUSED ' "$WT/p3s.md")" "1"
assert_eq "sizing: it lives in the Dev Agent Record" \
  "$(sed -n '/^## Dev Agent Record/,$p' "$WT/p3s.md" | grep -ac '^- budget: CONTINUATION_REFUSED ')" "1"
assert_eq "sizing: a refusal spends no window — the ledger is unmoved (cycle 2's entry only)" \
  "$(jq -r '.entries|length' "$WT/p3s.md.continuations.json")" "1"
assert_empty_file "sizing: nothing placed"   "$STUB_STATE/curl-calls"
assert_empty_file "sizing: nothing launched" "$STUB_STATE/terminal-creates"
# the CONTROL: an ORDINARY cycle refused by sizing writes no such line
reset_stubs; spawn_reset
cont_story p3so
awk -v w="$(( EST / 3 ))" '{print} /^  "claude\/strong":[[:space:]]*$/ {print "    min_context: " w}' \
  "$WORK/catalog.yaml" > "$WORK/catalog-ord.yaml"
rc="$(STUB_CATALOG="$WORK/catalog-ord.yaml"; export STUB_CATALOG; run_dispatch p3so.md 1)"
assert_eq "CONTROL: an ordinary cycle refused by sizing, exit 8" "$rc" "8"
assert_eq "CONTROL: writes no CONTINUATION_REFUSED line" \
  "$(grep -ac '^- budget: CONTINUATION_REFUSED ' "$WT/p3so.md" || true)" "0"

head1 "   F5 claim under test — 'the estimate stays deterministic' across a re-dispatch"
markest() { sed -n '1s/.*estimate=\([0-9]*\).*/\1/p' "$1"; }
EST1="$(markest "$WT/p3s.md.blocked")"
BYTES1="$(wc -c < "$WT/p3s.md")"
reset_stubs; rm -f "$WT/p3s.md.blocked"
rc="$(STUB_CATALOG="$WORK/catalog-cont.yaml"; export STUB_CATALOG; run_dispatch p3s.md 3)"
EST2="$(markest "$WT/p3s.md.blocked")"
BYTES2="$(wc -c < "$WT/p3s.md")"
printf '  attempt 1: story %s bytes, estimate %s\n  attempt 2: story %s bytes, estimate %s\n' \
  "$BYTES1" "$EST1" "$BYTES2" "$EST2"
assert_eq "the refusal is stable across the re-dispatch" "$rc" "8"
assert_eq "the record line is still written exactly once" \
  "$(grep -ac '^- budget: CONTINUATION_REFUSED ' "$WT/p3s.md")" "1"
if [[ "$EST1" == "$EST2" ]]; then
  ok "the estimate is identical across the re-dispatch"
else
  bad "the estimate MOVED across the re-dispatch of the same cycle" \
      "first attempt $EST1, re-dispatch $EST2 — the story file is a counted payload input and the record line grew it"
fi
# and a THIRD attempt, to show where it settles
reset_stubs; rm -f "$WT/p3s.md.blocked"
rc="$(STUB_CATALOG="$WORK/catalog-cont.yaml"; export STUB_CATALOG; run_dispatch p3s.md 3)"
EST3="$(markest "$WT/p3s.md.blocked")"
printf '  attempt 3: estimate %s\n' "$EST3"
assert_eq "from the second attempt on it is stable (the append is idempotent)" "$EST3" "$EST2"

printf '\n%s: %s passed, %s failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
