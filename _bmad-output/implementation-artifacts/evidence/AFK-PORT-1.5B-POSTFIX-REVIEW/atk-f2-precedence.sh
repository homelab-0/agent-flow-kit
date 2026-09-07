#!/usr/bin/env bash
# F2/RES-1 — the full precedence matrix: signal x gates x ratio.
# The conditionals below are TRANSCRIBED from dispatch.sh; the transcript is
# printed from the live source first so the walk cannot drift from the code.
set -uo pipefail
ROOT="${AFK_REVIEW_ROOT:-$(git rev-parse --show-toplevel)}"
D="$ROOT/files/model-router/scripts/dispatch.sh"
# shellcheck disable=SC1090
source "$D" 2>/dev/null || true

echo "=== live source of the three decision conditionals ==="
sed -n '/A run that finished is not a run that needs continuing/,/RESULT_STATUS="\$(\[\[ \$GATES_OK/p' "$D" \
  | grep -vE '^\s*#' | grep -v '^\s*$'
echo

load_budget_policy "$ROOT/files/model-router/context-budget-policy.yaml" >/dev/null 2>&1
echo "checkpoint_ppm=$BUDGET_CHECKPOINT_PPM continuation_ppm=$BUDGET_CONTINUATION_PPM"
echo

WIN=1000000
decide() { # <signal:yes|no> <gates:pass|fail> <usage-tokens|"">
  local sig="$1" gates="$2" tok="$3"
  local HARNESS=claude
  local RESULT_STATUS="" GATES_OK; BUDGET_FINDINGS=(); BUDGET_STATE="OK"; BUDGET_REASON=""
  BUDGET_USAGE_PPM=""
  [[ "$gates" == pass ]] && GATES_OK=true || GATES_OK=false
  if [[ -n "$tok" ]]; then
    budget_evaluate_usage "$(jq -nc --argjson u "$tok" --argjson w "$WIN" \
      '{usage_tokens:$u, window_tokens:$w, provenance:"HARNESS_ENVELOPE",
        observed_at:"END_OF_RUN", reason:null}')" "$WIN" 2>/dev/null
  else
    HARNESS=codex budget_evaluate_usage "$(usage_adapter_codex)" "$WIN" 2>/dev/null
  fi
  # --- worker signal path (transcribed: dispatch.sh, signal branch) ---
  if [[ "$sig" == yes ]]; then
    BUDGET_STATE="CONTINUATION_REQUIRED"; BUDGET_REASON=""
    RESULT_STATUS="continuation_required"
  fi
  # --- finished-run demotion (transcribed) ---
  if [[ -z "$RESULT_STATUS" && "$GATES_OK" == true \
        && "$BUDGET_STATE" == "CONTINUATION_REQUIRED" && -n "$BUDGET_USAGE_PPM" ]]; then
    if budget_crosses "$BUDGET_USAGE_PPM" "$BUDGET_CHECKPOINT_PPM"; then
      BUDGET_STATE="CHECKPOINT_DUE"; else BUDGET_STATE="OK"; fi
  fi
  # --- silent exhaustion (transcribed) ---
  if [[ -z "$RESULT_STATUS" && "$GATES_OK" != true \
        && "$BUDGET_STATE" == "CONTINUATION_REQUIRED" ]]; then
    RESULT_STATUS="continuation_required"
  fi
  [[ -n "$RESULT_STATUS" ]] || \
    RESULT_STATUS="$([[ $GATES_OK == true ]] && echo 'done' || echo 'gates_failed')"
  printf 'status=%-22s budget.state=%-22s findings=[%s]\n' \
    "$RESULT_STATUS" "$BUDGET_STATE" "${BUDGET_FINDINGS[*]-}"
}

fail=0
row() { # <label> <sig> <gates> <tok>
  local out; out="$(decide "$2" "$3" "$4")"
  printf '%-46s %s\n' "$1" "$out"
  # THE INVARIANT: CONTINUATION_REQUIRED must never sit beside status=done
  if [[ "$out" == *"status=done"* && "$out" == *"budget.state=CONTINUATION_REQUIRED"* ]]; then
    echo "   !! VIOLATION: CONTINUATION_REQUIRED beside status: done"; fail=1
  fi
  # a worker signal is never demoted
  if [[ "$2" == yes && "$out" != *"budget.state=CONTINUATION_REQUIRED"* ]]; then
    echo "   !! VIOLATION: worker signal was demoted"; fail=1
  fi
}
echo "=== matrix: signal x gates x ratio (window $WIN) ==="
for sig in no yes; do for gates in pass fail; do
  for tok in 100000 699999 700000 849999 850000 999999 ""; do
    row "sig=$sig gates=$gates usage=${tok:-unobservable}" "$sig" "$gates" "$tok"
  done
done; done
echo
echo "=== contract decision table rows ==="
grep -n 'gates \*\*passed\*\*, no worker signal\|gates failed, no worker signal' \
  "$ROOT/docs/LIFECYCLE-CONTRACT.md"
echo
[[ $fail -eq 0 ]] && echo "MATRIX: no violation" || echo "MATRIX: VIOLATIONS FOUND"
