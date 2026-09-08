#!/usr/bin/env bash
# ATTACK 6 — AC-6: a continuation cycle's thin result settles through the
# UNMODIFIED monitor path, with context_budget sourced as lane B defined.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
E="_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.5C-REVIEW"; ROOT="$PWD"
# shellcheck source=/dev/null
source "$E/harness-lib.sh"
KIT_ROOT="$ROOT"; DISPATCH="$KIT_ROOT/files/model-router/scripts/dispatch.sh"
: > "$STUB_STATE/terminal-creates"; export STUB_TERMINAL_TAIL="ok
CLAUDE_EXIT=0"
CONT_OK='{"schema":"afk-continuation/1","completed":["a"],"current_state":"half",
 "remaining_acceptance":["AC"],"next_steps":["b"],"updated_at":"2026-09-07T00:00:00Z",
 "in_flight":[],"unretired_findings":[]}'
write_story "$WT/set.md" "persona: dev
gates: [\"true\"]
max_cycles: 9"; write_stamp "$WT/set.md.stamp.json" high false
printf '%s' "$CONT_OK" > "$WT/set.md.continuation.json"
jq -n '{story:"s",cycle:1,status:"continuation_required",
  budget:{state:"CONTINUATION_REQUIRED",usage_tokens:9,usage_ratio:0.9,
          continuation_artifact:{path:"x",sha256:"sha256:aa"},continuation_of:null}}' \
  > "$WT/set.md.result.c1.json"
rc=$(run_dispatch "$WT/set.md" 2)
head1 "A. a continuation cycle's thin result is the ordinary shape"
assert_eq "the cycle ran" "$rc" "0"
R="$WT/set.md.result.json"
st="$(jq -r '.budget.state' "$R")"
echo "  budget.state=$st  status=$(jq -r .status "$R")"
# the monitor's OWN bounding expression, copied verbatim from lib/afk-monitor.sh
cb="$(jq -r '(.budget.state // "") as $s
  | if ["OK","CHECKPOINT_DUE","CONTINUATION_REQUIRED","NOT_EVALUATED"] | index($s)
    then $s else "NOT_EVALUATED" end' "$R")"
if [[ "$cb" != "NOT_EVALUATED" || "$st" == "NOT_EVALUATED" ]]; then
  ok "the monitor's bounding expression yields a real state ($cb), not a fallback"
else bad "the monitor's bounding expression yields a real state" "state=$st -> $cb"; fi
assert_eq "the result carries the members the monitor and the PM read" \
  "$(jq -r '[has("story"),has("cycle"),has("status"),(.budget|has("state")),(.budget|has("continuation_of"))]|all' "$R")" "true"
assert_eq "the retained per-cycle copy is identical" \
  "$(jq -S . "$R")" "$(jq -S . "$WT/set.md.result.c2.json")"
assert_eq "a fresh terminal was created for the continuation, like any cycle" \
  "$(jq -r '.launch.orca_terminal' "$R")" "term_stub"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; (( FAIL == 0 ))
