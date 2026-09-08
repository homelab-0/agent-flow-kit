#!/usr/bin/env bash
# Probe F1 — feed real envelopes through the adapter + budget evaluator of the
# SOURCE UNDER REVIEW, and through master's adapter as the control.
# Usage: probe-f1-adapter.sh <path-to-dispatch.sh> <label>
set -uo pipefail
SRC="${1:?dispatch.sh}"; LABEL="${2:-under-review}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
FIX="$ROOT/tests/fixtures/claude-result-envelope-multiturn.json"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# single-turn variant: SAME totals, num_turns forced to 1
jq '.num_turns = 1' "$FIX" > "$TMP/single.json"
# no-turn-count variant: num_turns removed entirely
jq 'del(.num_turns)' "$FIX" > "$TMP/noturns.json"

# shellcheck disable=SC1090
source "$SRC" >/dev/null 2>&1 || true

run_case() { # <label> <file> <window>
  local lbl="$1" f="$2" win="$3" obs
  BUDGET_FINDINGS=(); BUDGET_STATE="NOT_EVALUATED"; BUDGET_REASON="CONTEXT_WINDOW_UNDECLARED"
  BUDGET_USAGE_SCOPE=""; BUDGET_USAGE_RATIO=""; BUDGET_USAGE_REASON=""; BUDGET_USAGE_PPM=""
  BUDGET_CHECKPOINT_PPM=700000; BUDGET_CONTINUATION_PPM=850000; HARNESS=claude
  obs="$(harness_usage_observation claude "$f" qwen36-27b)"
  budget_evaluate_usage "$obs" "$win" >/dev/null 2>&1
  printf '%s | scope=%s ratio=%s reason=%s state=%s findings=[%s] tokens=%s\n' \
    "$lbl" "${BUDGET_USAGE_SCOPE:-<unset>}" "${BUDGET_USAGE_RATIO:-null}" \
    "${BUDGET_USAGE_REASON:-null}" "$BUDGET_STATE" \
    "$(IFS=,; echo "${BUDGET_FINDINGS[*]:-}")" "${BUDGET_USAGE_TOKENS:-null}"
}

echo "### $LABEL ($SRC)"
run_case "FU.1 83-turn      " "$FIX"           65536
run_case "same totals turns=1" "$TMP/single.json"  65536
run_case "num_turns absent  " "$TMP/noturns.json" 65536
