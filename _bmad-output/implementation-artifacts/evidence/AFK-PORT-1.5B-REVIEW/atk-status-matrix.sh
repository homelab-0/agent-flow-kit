#!/usr/bin/env bash
# ATTACK 5 — the status decision, over the whole (worker signal x gates x budget
# state) space. The three conditionals below are TRANSCRIBED VERBATIM from
# files/model-router/scripts/dispatch.sh (the lines are printed first, so the
# transcription is checkable against the file).
set -uo pipefail
ROOT="${AFK_REVIEW_ROOT:-$(git rev-parse --show-toplevel)}"
D="$ROOT/files/model-router/scripts/dispatch.sh"
echo "=== the source lines this attack transcribes ==="
grep -n -A4 'if \[\[ -z "\$RESULT_STATUS" && "\$GATES_OK" != true' "$D"
grep -n -A1 '\[\[ -n "\$RESULT_STATUS" \]\] ||' "$D"
grep -n -A2 '\[\[ "\$GATES_OK" == true && "\$RESULT_STATUS" == "done" \]\]' "$D"
echo
decide() { # <signal:yes|no> <gates_ok> <budget_state>
  local sig="$1" GATES_OK="$2" BUDGET_STATE="$3" RESULT_STATUS="" EX_DONE=0 EX_GATES_FAILED=1
  [[ "$sig" == yes ]] && RESULT_STATUS="continuation_required"
  if [[ -z "$RESULT_STATUS" && "$GATES_OK" != true \
        && "$BUDGET_STATE" == "CONTINUATION_REQUIRED" ]]; then
    RESULT_STATUS="continuation_required"
  fi
  [[ -n "$RESULT_STATUS" ]] || \
    RESULT_STATUS="$([[ $GATES_OK == true ]] && echo 'done' || echo 'gates_failed')"
  local ex; ( [[ "$GATES_OK" == true && "$RESULT_STATUS" == "done" ]] ) && ex=0 || ex=1
  printf 'signal=%-3s gates=%-5s budget.state=%-22s -> status=%-22s exit=%s\n' \
    "$sig" "$GATES_OK" "$BUDGET_STATE" "$RESULT_STATUS" "$ex"
}
echo "=== the matrix ==="
for sig in no yes; do for g in true false; do
  for b in OK CHECKPOINT_DUE CONTINUATION_REQUIRED NOT_EVALUATED; do decide "$sig" "$g" "$b"; done
done; done
echo
echo "=== the row to look at ==="
echo "signal=no gates=true budget.state=CONTINUATION_REQUIRED  ->  status=done, exit 0"
echo "  i.e. an END-OF-RUN usage at or past continuation_ratio on a run whose gates"
echo "  passed publishes budget.state=CONTINUATION_REQUIRED beside status=done, and"
echo "  the monitor projects context_budget=CONTINUATION_REQUIRED on a COMPLETED,"
echo "  settled Dispatch. Nothing in the contract's table covers this combination."
echo
echo "=== reachability: the usage that produces it ==="
source "$D" 2>/dev/null || true
BUDGET_CHECKPOINT_PPM=700000; BUDGET_CONTINUATION_PPM=850000; HARNESS=claude
BUDGET_STATE=OK BUDGET_REASON="" BUDGET_FINDINGS=()
budget_evaluate_usage "$(jq -nc '{usage_tokens:180000,window_tokens:200000,provenance:"HARNESS_ENVELOPE",observed_at:"END_OF_RUN",reason:null}')" 200000 >/dev/null 2>&1
printf 'a run that ended at 180000/200000 with passing gates: budget.state=%s findings=[%s]\n' \
  "$BUDGET_STATE" "${BUDGET_FINDINGS[*]-}"
