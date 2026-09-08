#!/usr/bin/env bash
# probe-01 — F1/B1 re-transcribed against LEDGER semantics.
#
# The first reviewer's attack-03 section A fabricated per-cycle RESULT files to
# simulate two prior continuations. The fix counts from the append-only ledger,
# so those results no longer reach the cap. Here the same scenario is built the
# way a real pair of launches builds it: two ledger entries.
cd "$(git rev-parse --show-toplevel)"
E="_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.5C-POSTFIX-REVIEW"
ROOT="$(pwd)"
# shellcheck source=/dev/null
source "$E/harness-lib.sh"
KIT_ROOT="$ROOT"; DISPATCH="$KIT_ROOT/files/model-router/scripts/dispatch.sh"
# shellcheck source=/dev/null
source "$E/fixtures2.sh"

head1 "A. at the SHIPPED defaults the capped cycle gets the TYPED cap refusal"
for MC in "" "
max_cycles: 3"; do
  TAG="$([[ -z "$MC" ]] && echo absent || echo three)"
  reset_stubs; spawn_reset
  dflt_story "p1-$TAG" "$MC"
  retain "p1-$TAG" 3 '{"cycle":2}'
  ledger "p1-$TAG" 2 3            # two windows really spent
  rm -f "$WT/p1-$TAG.md.blocked"
  rc="$(run_dispatch "p1-$TAG.md" 4)"
  M="$(cat "$WT/p1-$TAG.md.blocked" 2>/dev/null || echo '<no marker>')"
  printf '  [max_cycles %s] exit=%s\n' "$TAG" "$rc"
  printf '  stderr: %s\n' "$(tail -1 "$WORK/err")"
  assert_eq       "defaults/$TAG: refused with NEEDS_HUMAN" "$rc" "3"
  assert_contains "defaults/$TAG: by the CAP gate, typed" "$M" "CONTINUATION-CAP: reason=CONTINUATION_CAP_REACHED"
  assert_contains "defaults/$TAG: carrying the count"     "$M" "count=$CAP"
  assert_contains "defaults/$TAG: carrying the cap"       "$M" "cap=$CAP"
  assert_absent   "defaults/$TAG: not the untyped max_cycles message" "$(cat "$WORK/err")" "max_cycles ($CAP) exceeded"
  assert_empty_file "defaults/$TAG: nothing launched" "$STUB_STATE/terminal-creates"
  assert_empty_file "defaults/$TAG: nothing placed"   "$STUB_STATE/curl-calls"
done

head1 "B. the marker's own remedy, applied VERBATIM, unblocks the cycle"
REMEDY="$(marker_frontmatter_block "$WT/p1-absent.md.blocked")"
printf '  --- block lifted out of the marker ---\n%s\n  --------------------------------------\n' "$REMEDY"
assert_contains "remedy: carries the decision"        "$REMEDY" "continuation_decision:"
assert_contains "remedy: carries the story's own limit" "$REMEDY" "max_cycles: 4"
reset_stubs
# applied verbatim: the block is pasted into the frontmatter, values filled in
# only where the marker prints a <placeholder>.
BLOCK="$(printf '%s' "$REMEDY" | sed 's/<who decided>/pm/; s/<RFC3339 timestamp>/2026-09-07T00:00:00Z/; s/<why one more continuation is the right call>/one more/')"
write_story "$WT/p1-absent.md" "persona: dev
gates: [\"true\"]
$BLOCK"
rc="$(run_dispatch p1-absent.md 4)"
printf '  exit=%s  stderr-tail: %s\n' "$rc" "$(tail -1 "$WORK/err")"
assert_eq "remedy: the authorised cycle proceeds" "$rc" "0"
assert_eq "remedy: and the decision is recorded" \
  "$(bud .budget.continuation_decision.cycle "$WT/p1-absent.md.result.json")" "4"

head1 "C. CONTROL — the decision ALONE is not enough at the shipped defaults"
reset_stubs; spawn_reset
dflt_story p1-half
retain p1-half 3 '{"cycle":2}'; ledger p1-half 2 3
write_story "$WT/p1-half.md" "persona: dev
gates: [\"true\"]
continuation_decision:
  cycle: 4
  actor: pm
  at: 2026-09-07T00:00:00Z
  reason: one more"
rm -f "$WT/p1-half.md.blocked"
rc="$(run_dispatch p1-half.md 4)"
assert_eq "control: refused" "$rc" "3"
assert_contains "control: by max_cycles, which the marker therefore has to name" \
  "$(cat "$WORK/err")" "max_cycles (3) exceeded"
assert_empty_file "control: nothing launched" "$STUB_STATE/terminal-creates"

head1 "D. CONTROL — max_cycles still bounds what the cap lets through"
reset_stubs; spawn_reset
dflt_story p1-bound
retain p1-bound 3 '{"cycle":2}'; ledger p1-bound 2 3
write_story "$WT/p1-bound.md" "persona: dev
gates: [\"true\"]
max_cycles: 3
continuation_decision:
  cycle: 4
  actor: pm
  at: 2026-09-07T00:00:00Z
  reason: one more"
rm -f "$WT/p1-bound.md.blocked"
rc="$(run_dispatch p1-bound.md 4)"
assert_eq "bound: an authorised cycle past max_cycles is still refused" "$rc" "3"
assert_contains "bound: by the per-story limit" "$(cat "$WORK/err")" "max_cycles (3) exceeded"

head1 "E. ADVERSARIAL — applying the block verbatim to a story that ALREADY declares max_cycles"
# The marker's prose says 'leave a larger value alone'; the block it prints does
# not. A human who pastes the block verbatim onto a story with max_cycles: 8
# produces a DUPLICATE frontmatter key.
reset_stubs; spawn_reset
cont_story p1-dup                      # cont_story declares max_cycles: 8
retain p1-dup 3 '{"cycle":2}'; ledger p1-dup 2 3
rm -f "$WT/p1-dup.md.blocked"
rc="$(run_dispatch p1-dup.md 4)"
DUPM="$(cat "$WT/p1-dup.md.blocked")"
assert_contains "dup: the capped story with max_cycles: 8 still gets the typed marker" \
  "$DUPM" "CONTINUATION-CAP:"
RB="$(marker_frontmatter_block "$WT/p1-dup.md.blocked" | sed 's/<who decided>/pm/; s/<RFC3339 timestamp>/2026-09-07T00:00:00Z/; s/<why one more continuation is the right call>/one more/')"
printf '  --- block this marker prints for a story that already has max_cycles: 8 ---\n%s\n' "$RB"
write_story "$WT/p1-dup.md" "persona: dev
gates: [\"true\"]
max_cycles: 8
$RB"
reset_stubs
rc="$(run_dispatch p1-dup.md 4)"
printf '  verbatim-paste onto max_cycles: 8 -> exit=%s\n  stderr: %s\n' "$rc" "$(tail -2 "$WORK/err")"
if [[ "$rc" == "0" ]]; then ok "dup: a verbatim paste onto an existing max_cycles still dispatches"
else bad "dup: a verbatim paste onto an existing max_cycles does NOT dispatch" "exit $rc"; fi

printf '\n%s: %s passed, %s failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
