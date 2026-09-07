#!/usr/bin/env bash
# F4/RES-3,RES-4 — the claude adapter reports only what it saw.
set -uo pipefail
ROOT="${AFK_REVIEW_ROOT:-$(git rev-parse --show-toplevel)}"
D="$ROOT/files/model-router/scripts/dispatch.sh"
# shellcheck disable=SC1090
source "$D" 2>/dev/null || true
load_budget_policy "$ROOT/files/model-router/context-budget-policy.yaml" >/dev/null 2>&1
W="$(mktemp -d /tmp/atk-f4.XXXXXX)"
probe() { printf '%s' "$2" > "$W/e.json"
  printf '%-56s -> %s\n' "$1" "$(usage_adapter_claude "$W/e.json" "${3:-opus}" | jq -c .)"; }

echo "=== A. observability: usage present but with no token member ==="
probe "usage:{output_tokens:9999} (no context member)" '{"usage":{"output_tokens":9999}}'
probe "usage:{} empty object"                           '{"usage":{}}'
probe "usage absent entirely"                           '{"type":"result"}'
probe "usage: null"                                     '{"usage":null}'
probe "usage: a string"                                 '{"usage":"nope"}'
echo "--- CONTROLS: any ONE of the three IS an observation ---"
probe "input_tokens only"          '{"usage":{"input_tokens":7}}'
probe "cache_read only"            '{"usage":{"cache_read_input_tokens":42}}'
probe "cache_creation only"        '{"usage":{"cache_creation_input_tokens":5}}'
probe "a genuine zero input_tokens" '{"usage":{"input_tokens":0}}'

echo
echo "=== B. window corroboration is an EXACT modelUsage key match ==="
ENV1='{"usage":{"input_tokens":10},"modelUsage":{"some-other-model":{"contextWindow":200000}}}'
probe "one non-matching entry, asking for opus" "$ENV1" opus
probe "CONTROL: the matching key IS read"       "$ENV1" some-other-model
ENV2='{"usage":{"input_tokens":10},"modelUsage":{"opus":{"contextWindow":200000},"x":{"contextWindow":9}}}'
probe "two entries, exact key present"          "$ENV2" opus
probe "two entries, no key match"               "$ENV2" haiku
probe "no modelUsage at all"                    '{"usage":{"input_tokens":10}}' opus
echo "single-entry fallback still in the source?"
grep -n 'to_entries\[0\]\|length) == 1' "$D" || echo "  ABSENT — no single-entry fallback"

echo
echo "=== C. WINDOW_UNCORROBORATED is bounded to an observation that happened ==="
row() { HARNESS="${3:-claude}"; BUDGET_FINDINGS=(); BUDGET_STATE="OK"; BUDGET_REASON=""
  budget_evaluate_usage "$1" 1000000 2>/dev/null
  printf '%-52s state=%-18s findings=[%s]\n' "$2" "$BUDGET_STATE" "${BUDGET_FINDINGS[*]-}"; }
row '{"usage_tokens":10,"window_tokens":null,"provenance":"HARNESS_ENVELOPE","observed_at":"END_OF_RUN","reason":null}' \
    "observed, no window -> UNCORROBORATED"
row '{"usage_tokens":10,"window_tokens":1000000,"provenance":"HARNESS_ENVELOPE","observed_at":"END_OF_RUN","reason":null}' \
    "CONTROL: agreeing window -> no finding"
row '{"usage_tokens":10,"window_tokens":999999,"provenance":"HARNESS_ENVELOPE","observed_at":"END_OF_RUN","reason":null}' \
    "CONTROL: disagreeing window -> DISAGREEMENT only"
row "$(usage_adapter_codex)" "CONTROL: nothing observed -> no corroboration claim" codex
row "$(usage_adapter_claude "$W/none.json" opus)" "CONTROL: unobservable claude -> no claim" claude
rm -rf "$W"
