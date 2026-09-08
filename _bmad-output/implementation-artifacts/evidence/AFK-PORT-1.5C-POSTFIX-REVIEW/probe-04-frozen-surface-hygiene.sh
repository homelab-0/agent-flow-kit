#!/usr/bin/env bash
# probe-04 — F6/F7 and the frozen-surface obligations, checked against master.
cd "$(git rev-parse --show-toplevel)"
E="_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.5C-POSTFIX-REVIEW"
ROOT="$(pwd)"
# shellcheck source=/dev/null
source "$E/harness-lib.sh"
KIT_ROOT="$ROOT"; DISPATCH="$KIT_ROOT/files/model-router/scripts/dispatch.sh"
BASE=88c24b6 HEAD_C=b7c16c2 MASTER=e76cb95

head1 "A. lib/afk-monitor.sh is byte-identical to master"
M="$(git show "$MASTER:lib/afk-monitor.sh" | sha256sum | cut -d' ' -f1)"
H="$(sha256sum lib/afk-monitor.sh | cut -d' ' -f1)"
printf '  master %s\n  head   %s\n' "$M" "$H"
assert_eq "afk-monitor.sh unchanged" "$H" "$M"
# non-vacuity: the same comparison detects a one-line mutation
MUT="$( { git show "$MASTER:lib/afk-monitor.sh"; echo '# mutated'; } | sha256sum | cut -d' ' -f1)"
if [[ "$MUT" == "$M" ]]; then bad "the comparison is vacuous" "a mutation hashed the same"
else ok "the comparison is non-vacuous (a one-line mutation hashes differently)"; fi

head1 "B. the three frozen launch command texts are byte-identical to master"
# Emitted by BOTH sides' builders for identical inputs, not read off a
# transcription, and with a control so a vacuous comparison cannot pass.
MD="$WORK/master-dispatch.sh"; git show "$MASTER:files/model-router/scripts/dispatch.sh" > "$MD"
emit_from() { bash -c 'set -uo pipefail; . "$1"; shift; "$@"' _emit "$@"; }
A1=(/home/op /usr/bin:/bin op /wt/S.md.prompt claude-opus-5 high /wt/S.md.claude-result.json /wt/agents/dev.md)
A2=(/home/op /usr/bin:/bin op /wt/S.md.prompt qwen36-27b high /wt/S.md.claude-result.json /wt/agents/dev.md \
    https://gw.invalid op://v/i/credential /home/op/.op-agent-env cachyos-7900xtx 65536)
A3=(/wt/S.md.prompt gpt-5.6-sol xhigh)
for spec in "build_claude_command A1" "build_claude_gateway_command A2" "build_codex_command A3"; do
  fn="${spec%% *}"; an="${spec##* }"; declare -n args="$an"
  m="$(emit_from "$MD" "$fn" "${args[@]}")"
  h="$(emit_from "$DISPATCH" "$fn" "${args[@]}")"
  if [[ -z "$m" ]]; then bad "byte-identity: $fn" "master produced nothing — the probe is broken"
  elif [[ "$m" == "$h" ]]; then ok "byte-identity: $fn is byte-identical to master"
  else bad "byte-identity: $fn" "$(diff <(printf '%s\n' "$m") <(printf '%s\n' "$h") | head -6)"; fi
  unset -n args
done
# CONTROL: the comparison can see a difference
if [[ "$(emit_from "$MD" build_claude_command "${A1[@]}")" != \
      "$(emit_from "$DISPATCH" build_claude_command /home/op /usr/bin:/bin op /wt/S.md.prompt claude-opus-5 medium /wt/S.md.claude-result.json /wt/agents/dev.md)" ]]; then
  ok "byte-identity CONTROL: a perturbed effort IS detected"
else bad "byte-identity CONTROL: a perturbed effort IS detected"; fi

head1 "C. the diff stays inside the fix story's declared surface"
FILES="$(git diff --name-only "$BASE" "$HEAD_C")"
printf '%s\n' "$FILES" | sed 's/^/    /'
DECLARED="_bmad-output/implementation-artifacts/AFK-PORT-1.5C.md
docs/LIFECYCLE-CONTRACT.md
files/model-router/SKILL.md
files/model-router/context-budget-policy.yaml
files/model-router/scripts/dispatch.sh
lib/afk-commands.sh
tests/run-tests.sh"
OUT=0
while IFS= read -r f; do
  grep -qxF "$f" <<<"$DECLARED" || { bad "outside the declared surface: $f" ""; OUT=1; }
done <<<"$FILES"
(( OUT == 0 )) && ok "every changed file is inside the declared surface"
assert_absent "the reviewer's evidence directory is untouched" "$FILES" "evidence/AFK-PORT-1.5C-REVIEW"
assert_absent "make-stamp.sh untouched"  "$FILES" "make-stamp.sh"
assert_absent "the catalog untouched"    "$FILES" "catalog"
assert_absent "afk-monitor.sh untouched" "$FILES" "afk-monitor"

head1 "D. commit hygiene"
BODY="$(git log -1 --format='%B' "$HEAD_C")"
printf '  subject: %s\n' "$(git log -1 --format='%s' "$HEAD_C")"
for tell in "Co-Authored-By" "Generated with" "Claude-Session" "claude.ai/code" "🤖"; do
  assert_absent "no '$tell' trailer" "$BODY" "$tell"
done
for tell in "BMAD" "bmad" "story file" "persona" "epic" "dispatch worker"; do
  assert_absent "no internal vocabulary: '$tell'" "$BODY" "$tell"
done
git diff --check "$BASE" "$HEAD_C" > "$WORK/check" 2>&1; rc=$?
assert_eq "git diff --check clean" "$rc" "0"
assert_empty_file "and says nothing" "$WORK/check"
STAT="$(git diff --numstat "$BASE" "$HEAD_C" | awk '{a+=$1; d+=$2; n++} END {print a+d" "n}')"
printf '  added+deleted lines: %s across %s files\n' "${STAT% *}" "${STAT#* }"

head1 "E. F6 — the unpruned series is documented as load-bearing"
CT=docs/LIFECYCLE-CONTRACT.md
assert_contains "the contract says neither series is pruned" \
  "$(cat "$CT")" "Neither series is ever pruned"
assert_contains "and says why: the cap is counted from them" \
  "$(cat "$CT")" "uncountable"
assert_contains "the ledger schema id is declared in the contract" \
  "$(cat "$CT")" "afk-continuation-ledger/1"
assert_contains "the policy declares the same schema in prose" \
  "$(cat files/model-router/context-budget-policy.yaml)" "continuations.json"
head1 "   the three new reason codes are declared in all three places"
for code in CONTINUATION_REFUSED CONTINUATION_ARTIFACT_UNBOUND CYCLE_ALREADY_RETAINED; do
  assert_contains "$code in the policy" "$(cat files/model-router/context-budget-policy.yaml)" "$code"
  assert_contains "$code in afk-commands.sh schema" "$(cat lib/afk-commands.sh)" "$code"
  assert_contains "$code in the contract" "$(cat "$CT")" "$code"
  assert_contains "$code in the launcher" "$(cat files/model-router/scripts/dispatch.sh)" "$code"
done
head1 "   and the SKILL paragraph says what the marker says"
assert_contains "SKILL names max_cycles in the authorisation block" \
  "$(cat files/model-router/SKILL.md)" "max_cycles: 4"
assert_contains "SKILL names the ledger" \
  "$(cat files/model-router/SKILL.md)" "continuations.json"
assert_contains "SKILL names the settled-cycle refusal" \
  "$(cat files/model-router/SKILL.md)" "CYCLE_ALREADY_RETAINED"

head1 "F. F7 — the post-review registry in the story's Dev Agent Record"
ST=_bmad-output/implementation-artifacts/AFK-PORT-1.5C.md
assert_contains "the registry heading exists" "$(cat "$ST")" "### Post-review fix cycle (AFK-PORT-1.5C-FIX)"
REG="$(sed -n '/### Post-review fix cycle (AFK-PORT-1.5C-FIX)/,$p' "$ST")"
for item in B1 B2 R1 R2 R3 R4; do
  assert_contains "the registry dispositions $item" "$REG" "$item"
done
assert_contains "and says a commit cannot carry its own hash" "$REG" "cannot carry its own"

printf '\n%s: %s passed, %s failed\n' "$(basename "$0")" "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
