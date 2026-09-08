#!/usr/bin/env bash
# probe-06 — the ledger is read ONCE at the top of main() and appended at the
# launch. Does the gap between the two admit a second window?
cd "$(git rev-parse --show-toplevel)"
E="_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.5C-POSTFIX-REVIEW"
ROOT="$(pwd)"
# shellcheck source=/dev/null
source "$E/harness-lib.sh"
KIT_ROOT="$ROOT"; DISPATCH="$KIT_ROOT/files/model-router/scripts/dispatch.sh"
# shellcheck source=/dev/null
source "$E/fixtures2.sh"

head1 "A. two dispatches of the SAME continuation cycle, started together"
reset_stubs; spawn_reset
cont_story p6; retain p6 1 null
pids=(); for i in 1 2 3; do ( run_dispatch p6.md 2 > "$WORK/rc$i" ) & pids+=($!); done
for p in "${pids[@]}"; do wait "$p"; done
printf '  exits: %s %s %s\n' "$(cat "$WORK/rc1")" "$(cat "$WORK/rc2")" "$(cat "$WORK/rc3")"
LEN="$(jq -r '.entries|length' "$WT/p6.md.continuations.json" 2>/dev/null || echo missing)"
LAUNCHED="$(wc -l < "$STUB_STATE/terminal-creates")"
printf '  ledger entries=%s  terminals launched=%s\n' "$LEN" "$LAUNCHED"
printf '  ledger: %s\n' "$(jq -c '[.entries[].cycle]' "$WT/p6.md.continuations.json" 2>/dev/null)"
if [[ "$LEN" == "1" ]]; then ok "exactly one window was spent for cycle 2"
else bad "cycle 2 spent more than one window" "ledger length $LEN, $LAUNCHED terminals — the guard is read before the launch and not re-checked under the lock"; fi
head1 "   ... but the ledger itself is not corrupted or lost by the concurrent appends"
if jq -e '.schema == "afk-continuation-ledger/1" and (.entries|type=="array")' \
     "$WT/p6.md.continuations.json" >/dev/null 2>&1; then
  ok "the ledger still parses under its declared schema"
else bad "the ledger is corrupt after concurrent appends" "$(cat "$WT/p6.md.continuations.json")"; fi
if [[ "$LEN" == "$LAUNCHED" ]]; then ok "one ledger entry per terminal actually created"
else bad "the ledger under-counts the windows spent" "entries $LEN vs terminals $LAUNCHED"; fi

head1 "B. CONTROL — serial dispatches of DIFFERENT cycles each append exactly one"
reset_stubs; spawn_reset
cont_story p6s; retain p6s 1 null
rc="$(run_dispatch p6s.md 2)"; assert_eq "cycle 2 launches" "$rc" "0"
jq -n --arg s p6s --argjson c 2 '{story:$s,cycle:$c,status:"continuation_required",
  budget:{state:"CONTINUATION_REQUIRED",usage_tokens:1,usage_ratio:0.9,
          continuation_artifact:null,continuation_of:{cycle:1}}}' > "$WT/p6s.md.result.c2.json"
reset_stubs; rc="$(run_dispatch p6s.md 3)"; assert_eq "cycle 3 launches" "$rc" "0"
assert_eq "two cycles, two entries" "$(jq -r '.entries|length' "$WT/p6s.md.continuations.json")" "2"

printf '\n%s: %s passed, %s failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
