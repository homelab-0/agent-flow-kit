#!/usr/bin/env bash
# ATTACK 3 — (a) the cap gate versus the story's own max_cycles at the SHIPPED
# defaults, (b) harness agnosticism, (c) the artifact as a prompt-injection
# surface, (d) doc/code truth greps.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
E="_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.5C-REVIEW"
ROOT="$PWD"
# shellcheck source=/dev/null
source "$E/harness-lib.sh"
KIT_ROOT="$ROOT"; DISPATCH="$KIT_ROOT/files/model-router/scripts/dispatch.sh"
: > "$STUB_STATE/terminal-creates"
export STUB_TERMINAL_TAIL="ok
CLAUDE_EXIT=0"
CONT_OK='{"schema":"afk-continuation/1","completed":["a"],"current_state":"half",
 "remaining_acceptance":["AC-2"],"next_steps":["do b"],"updated_at":"2026-09-07T00:00:00Z",
 "in_flight":[],"unretired_findings":[]}'
plant() { jq -n --arg s "$WT/$1.md" --argjson c "$2" --argjson cof "$4" --arg st "$3" \
  '{story:$s,cycle:$c,status:$st,budget:{state:"CONTINUATION_REQUIRED",usage_tokens:9,usage_ratio:0.9,
    continuation_artifact:{path:"x",sha256:"sha256:aa"},continuation_of:$cof,findings:[]}}' \
  > "$WT/$1.md.result.c$2.json"; }
art() { printf '%s' "$CONT_OK" > "$WT/$1.md.continuation.json"; }

CAP="$(yq -r '.continuation_cap' "$KIT_ROOT/files/model-router/context-budget-policy.yaml")"
head1 "A. the cap versus max_cycles at the SHIPPED defaults (cap=$CAP)"
# A story that declares NO max_cycles gets the launcher default (3). The cap
# allows 2 continuations, so the cycle the cap is about is cycle 4.
write_story "$WT/dflt.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/dflt.md.stamp.json" high false
art dflt
plant dflt 1 continuation_required null
plant dflt 2 continuation_required '{"cycle":1}'
plant dflt 3 continuation_required '{"cycle":2}'
rc=$(run_dispatch "$WT/dflt.md" 4)
echo "  [default max_cycles] exit=$rc"
echo "  stderr: $(grep -a 'max_cycles\|CONTINUATION' "$WORK/err" | head -3)"
if [[ -f "$WT/dflt.md.blocked" ]] && grep -q CONTINUATION_CAP_REACHED "$WT/dflt.md.blocked"; then
  ok "the cap gate is REACHED at the shipped default max_cycles"
else
  bad "the cap gate is reached at the shipped default max_cycles" \
      "refused earlier by max_cycles; no CONTINUATION-CAP marker was written"
fi
# and the marker's own remedy, applied EXACTLY as printed, must unblock the cycle
write_story "$WT/dflt2.md" "persona: dev
gates: [\"true\"]
continuation_decision:
  cycle: 4
  actor: josh
  at: 2026-09-07T00:00:00Z
  reason: one more"
write_stamp "$WT/dflt2.md.stamp.json" high false
art dflt2
plant dflt2 1 continuation_required null
plant dflt2 2 continuation_required '{"cycle":1}'
plant dflt2 3 continuation_required '{"cycle":2}'
rc=$(run_dispatch "$WT/dflt2.md" 4)
assert_eq "the marker's remedy, applied verbatim, lets the authorised cycle proceed" "$rc" "0"
echo "  stderr: $(tail -2 "$WORK/err")"
# CONTROL: the identical story with max_cycles raised
write_story "$WT/dflt3.md" "persona: dev
gates: [\"true\"]
max_cycles: 9
continuation_decision:
  cycle: 4
  actor: josh
  at: 2026-09-07T00:00:00Z
  reason: one more"
write_stamp "$WT/dflt3.md.stamp.json" high false
art dflt3
plant dflt3 1 continuation_required null
plant dflt3 2 continuation_required '{"cycle":1}'
plant dflt3 3 continuation_required '{"cycle":2}'
rc=$(run_dispatch "$WT/dflt3.md" 4)
assert_eq "control: the SAME story with max_cycles: 9 proceeds" "$rc" "0"
# does anything the human reads mention max_cycles?
M="$(cat "$WT/dflt.md.blocked" 2>/dev/null || true)"
if grep -q max_cycles <<<"$M$(sed -n '/### Continuation cycles/,/### The context budget on/p' docs/LIFECYCLE-CONTRACT.md)$(sed -n '/A continuation is the next cycle/,/^### /p' files/model-router/SKILL.md)"; then
  ok "the cap marker or the docs mention the max_cycles interaction"
else
  bad "the cap marker or the docs mention the max_cycles interaction" "no mention anywhere"
fi

head1 "B. harness agnosticism — the SAME continuation on codex"
write_story "$WT/cx.md" "persona: dev
gates: [\"true\"]
max_cycles: 9"
write_stamp "$WT/cx.md.stamp.json" high false "openai/strong" codex openai-plus
art cx; plant cx 1 continuation_required null
export STUB_TERMINAL_TAIL="ok
CODEX_EXIT=0"
rc=$(run_dispatch "$WT/cx.md" 2)
assert_eq "codex continuation launches"      "$rc" "0"
assert_eq "codex records continuation_of"    "$(jq -r '.budget.continuation_of.cycle' "$WT/cx.md.result.json")" "1"
assert_contains "codex prompt carries the section" "$(cat "$WT/cx.md.prompt")" "Continuation from cycle 1"
assert_contains "codex REPEATED_CONTINUATION" "$(jq -c .budget.findings "$WT/cx.md.result.json")" "REPEATED_CONTINUATION"
export STUB_TERMINAL_TAIL="ok
CLAUDE_EXIT=0"
echo "  --- no CLI name in the continuation logic ---"
if awk '/^# Continuation cycles \(FR-102/,/^# worker_discipline_paragraph/' \
     files/model-router/scripts/dispatch.sh | grep -nE '\b(claude|codex)\b'; then
  bad "no harness CLI name inside the continuation logic"
else ok "no harness CLI name inside the continuation logic"; fi

head1 "C. the artifact is DATA — it cannot become shell, a marker or a log"
write_story "$WT/inj.md" "persona: dev
gates: [\"true\"]
max_cycles: 9"
write_stamp "$WT/inj.md.stamp.json" high false
plant inj 1 continuation_required null
python3 - "$WT/inj.md.continuation.json" <<'PY'
import json,sys
json.dump({"schema":"afk-continuation/1","completed":["a"],
 "current_state":"$(touch /tmp/AFK_PWNED_1)`touch /tmp/AFK_PWNED_2`; touch /tmp/AFK_PWNED_3",
 "remaining_acceptance":["s3cr3t-sentinel-9f2a"],"next_steps":["x"],
 "updated_at":"2026-09-07T00:00:00Z","in_flight":[],"unretired_findings":[]},
 open(sys.argv[1],"w"))
PY
rm -f /tmp/AFK_PWNED_*
rc=$(run_dispatch "$WT/inj.md" 2)
assert_eq "the cycle still launches"            "$rc" "0"
if compgen -G "/tmp/AFK_PWNED_*" >/dev/null; then bad "artifact content never reaches a shell"; \
  else ok "artifact content never reaches a shell"; fi
assert_contains "and it DID reach the prompt as data" "$(cat "$WT/inj.md.prompt")" "AFK_PWNED_1"
assert_absent "no artifact content in the launched command text" \
  "$(cat "$STUB_STATE/last-command.txt")" "AFK_PWNED"
assert_absent "no artifact content in the thin result" \
  "$(cat "$WT/inj.md.result.json")" "s3cr3t-sentinel-9f2a"
assert_absent "no artifact content in the story record line" \
  "$(cat "$WT/inj.md")" "s3cr3t-sentinel-9f2a"
assert_absent "no artifact content on stderr" "$(cat "$WORK/err")" "s3cr3t-sentinel-9f2a"
# CONTROL: the sentinel really is in the artifact
assert_contains "control: the sentinel is in the artifact" \
  "$(cat "$WT/inj.md.continuation.json")" "s3cr3t-sentinel-9f2a"

head1 "D. doc / code truth"
for code in CONTINUATION_CAP_REACHED CONTINUATION_STAMP_REFRESH_REQUIRED REPEATED_CONTINUATION; do
  for f in files/model-router/context-budget-policy.yaml lib/afk-commands.sh \
           docs/LIFECYCLE-CONTRACT.md files/model-router/scripts/dispatch.sh; do
    if grep -q "$code" "$f"; then ok "$code declared in $(basename "$f")"
    else bad "$code declared in $(basename "$f")"; fi
  done
done
assert_eq "no threshold constant in the launcher" \
  "$(grep -nE '^[^#]*(0\.6|0\.7|0\.85)' files/model-router/scripts/dispatch.sh | wc -l)" "0"
assert_eq "no continuation_cap fallback default in code" \
  "$(grep -cE 'BUDGET_CONTINUATION_CAP:-|continuation_cap.*\|\|.*[0-9]' files/model-router/scripts/dispatch.sh)" "0"
assert_eq "no context_size in the launcher" \
  "$(grep -c 'context_size' files/model-router/scripts/dispatch.sh)" "0"
if command -v shellcheck >/dev/null; then
  if shellcheck -x files/model-router/scripts/dispatch.sh >"$WORK/sc" 2>&1; then ok "shellcheck clean"
  else bad "shellcheck clean" "$(head -5 "$WORK/sc")"; fi
else skip "shellcheck not installed"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
