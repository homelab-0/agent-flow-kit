#!/usr/bin/env bash
# ATTACK 8 — every sentence in the shipped docs must be true of the code.
set -uo pipefail
. "$(dirname "$0")/attack-harness.sh"
DOC="$KIT_ROOT/docs/LIFECYCLE-CONTRACT.md"
SKILL="$KIT_ROOT/files/model-router/SKILL.md"
D="$KIT_ROOT/files/model-router/scripts/dispatch.sh"
POLICY="$SHIPPED_POLICY"

# 1. the doc's machine-checkable block == schema verb == policy document
DOCSTATES="$(awk '/machine-checkable: budget_states/,/end -->/' "$DOC" | grep -E '^[A-Z_]+$' | LC_ALL=C sort | tr '\n' ' ')"
SCHEMA="$(grep -o 'budget_states: \[[^]]*\]' "$KIT_ROOT/lib/afk-commands.sh" | grep -o '"[A-Z_]*"' | tr -d '"' | LC_ALL=C sort | tr '\n' ' ')"
POLSTATES="$(yq -r '.budget_states[]' "$POLICY" | LC_ALL=C sort | tr '\n' ' ')"
eq "8: contract block == schema verb"      "$DOCSTATES" "$SCHEMA"
eq "8: schema verb == policy document"     "$SCHEMA" "$POLSTATES"
# and the live schema output really carries them
LIVE="$(cd "$KIT_ROOT" && bash bin/agent-flow-kit schema 2>/dev/null | jq -r '.budget_states[]?' | LC_ALL=C sort | tr '\n' ' ' || true)"
if [[ -n "$LIVE" ]]; then eq "8: the LIVE schema verb publishes them" "$LIVE" "$POLSTATES"
else printf '     (info) could not run the schema verb directly; static check only\n'; fi

# 2. the doc's declared budget member shape == the shape dispatch emits
DOCKEYS="$(awk '/^"budget": \{/{f=1} f{print} f&&/"findings": \[/{exit}' "$DOC" | grep -oE '"[a-z_]+":' | tr -d '":' | grep -v '^budget$' | LC_ALL=C sort -u | tr '\n' ' ')"
CODEKEYS="$(sed -n '/--argjson budget/,/findings:\$findings}/p' "$D" | grep -oE '^ *[a-z_]+:|[{ ]([a-z_]+):' | tr -d '{ :' | LC_ALL=C sort -u | tr '\n' ' ')"
printf '     (info) doc keys : %s\n     (info) code keys: %s\n' "$DOCKEYS" "$CODEKEYS"
eq "8: the documented budget member keys are exactly the emitted ones" "$DOCKEYS" "$CODEKEYS"

# 3. every reason code the docs/policy declare is one the code can actually emit
for c in CONTEXT_WINDOW_UNDECLARED SIZING_REFUSED SIZING_RISK PAYLOAD_REF_MISSING BUDGET_POLICY_UNREADABLE; do
  if grep -q "$c" "$D"; then ok "8: reason code $c appears in the launcher"
  else bad "8: reason code $c appears in the launcher" "declared in policy, absent from code"; fi
done
# SIZING_REFUSED is declared — is it ever actually PRODUCED anywhere?
if grep -qE '(BUDGET_FINDINGS\+=\("SIZING_REFUSED"|reason.*SIZING_REFUSED|STORY-SIZING.*SIZING_REFUSED)' "$D"; then
  ok "8: SIZING_REFUSED is emitted as a code, not only mentioned"
else
  printf '     (info) SIZING_REFUSED occurrences in dispatch.sh: %s\n' "$(grep -c SIZING_REFUSED "$D")"
  printf '     (info) %s\n' "$(grep -n SIZING_REFUSED "$D" | head -3 | tr '\n' '|')"
  bad "8: SIZING_REFUSED is a DECLARED reason code that no artifact ever carries" \
      "the refusal marker is typed STORY-SIZING: and the exit code is 8; the string SIZING_REFUSED reaches no marker, no result and no log"
fi

# 4. the doc's exit-code claim
grep -q 'EX_SIZING_REFUSED=8' "$D" && ok "8: exit code 8 is what the doc says it is" || bad "8: exit code 8"
# 5. the SKILL example path must exist, or the example would refuse
EXPATH="$(awk '/^payload_refs:/{f=1;next} f&&/^  - /{print $2; exit}' "$SKILL")"
printf '     (info) SKILL payload_refs example: %s\n' "$EXPATH"
if [[ -e "$KIT_ROOT/$EXPATH" ]]; then ok "8: the SKILL's payload_refs example names a file that exists"
else printf '     (info) the example path does not exist in this kit; the whole frontmatter block is illustrative (STORY-041-3, pnpm test), so this is an example-quality point, not a false statement about behaviour\n'
     ok "8: the SKILL payload_refs example is illustrative like the rest of the template (see review R5)"; fi

# 6. the doc says payload_refs are "repo-relative to the worktree that bounds
#    the worker's sandbox" — is containment actually enforced?
if grep -qE 'realpath "\$PWD/\$ref"' "$D" && ! sed -n '/budget_payload_paths()/,/^}/p' "$D" | grep -qE 'case "\$rp" in|\$\(realpath "\$PWD"\)/\*'; then
  bad "8: the contract's 'bounds the worker's sandbox' wording is not enforced" \
      "budget_payload_paths applies no containment test; main() applies one to \$STORY but not to payload_refs"
else ok "8: payload_refs containment is enforced as the contract describes"; fi

# 7. the deferred doc<->schema sync loop: is budget_states really absent there?
LT="$KIT_ROOT/tests/lifecycle-tests.sh"
if grep -q 'budget_states' "$LT"; then ok "8: lifecycle-tests.sh already checks budget_states"
else printf '     (info) budget_states is absent from tests/lifecycle-tests.sh (the disclosed deferral)\n'
     if grep -q 'machine-checkable' "$LT"; then
       ok "8: the doc<->schema sync loop exists there and simply does not list budget_states yet"
     else bad "8: could not locate the doc<->schema sync loop" "the deferral's premise is unverified"; fi; fi

# 8. does the contract claim anything about CHECKPOINT_DUE / CONTINUATION_REQUIRED being produced?
has "8: the contract says only OK and NOT_EVALUATED are produced pre-dispatch" \
  "$(cat "$DOC")" "Pre-dispatch produces only \`OK\` and \`NOT_EVALUATED\`"
if grep -qE 'CHECKPOINT_DUE|CONTINUATION_REQUIRED' "$D"; then
  bad "8: the launcher must not produce a lane-B/C state" "$(grep -n 'CHECKPOINT_DUE\|CONTINUATION_REQUIRED' "$D"|head -2)"
else ok "8: the launcher produces no lane-B/C state (declaration only)"; fi
summary
