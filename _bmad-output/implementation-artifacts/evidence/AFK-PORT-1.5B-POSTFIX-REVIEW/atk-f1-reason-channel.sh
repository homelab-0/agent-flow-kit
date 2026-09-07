#!/usr/bin/env bash
# F1/BLK-1 — the CONTINUATION-REQUIRED reason's content must reach nothing.
set -uo pipefail
ROOT="${AFK_REVIEW_ROOT:-$(git rev-parse --show-toplevel)}"
# shellcheck disable=SC1090
source "$ROOT/files/model-router/scripts/dispatch.sh" 2>/dev/null || true

echo "=== A. artifact_redact / BUDGET_REDACT_FN gone? ==="
type artifact_redact >/dev/null 2>&1 && echo "PRESENT artifact_redact" || echo "ABSENT artifact_redact"
grep -n 'artifact_redact\|BUDGET_REDACT_FN' "$ROOT/files/model-router/scripts/dispatch.sh" || echo "no references in dispatch.sh"
echo "(repo-wide:)"; grep -rn 'artifact_redact\|BUDGET_REDACT_FN' "$ROOT" --exclude-dir=.git --exclude-dir=evidence || echo "none repo-wide"

echo
echo "=== B. summary output for adversarial reasons ==="
while IFS= read -r r; do
  printf '%-58s -> %s\n' "$r" "$(continuation_signal_summary "CONTINUATION-REQUIRED: $r")"
done <<'REASONS'
hunter2
password=Tr0ub4dor&3
xoxb-2f9a:8c1d-77aa-9e0f
eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJhIjoxfQ.sig
AKIAIOSFODNN7EXAMPLE
context exhausted, the token was sk-live-9f2a4c7e1b8d3550
*
$(id)
`id`
${PATH}
tokens usage tokens context context
REASONS

echo
echo "=== C. can the summary ever echo caller bytes? vocabulary probe ==="
for w in 'Context,' 'CONTEXT' 'c0ntext' 'contextual' 'con-text' 'hunter2' 'gates!' 'x' ''; do
  printf '[%s] -> [%s]\n' "$w" "$(continuation_reason_word "$w")"
done

echo
echo "=== D. every dispatch.sh site that consumes the signal line ==="
grep -n 'CONTINUATION-REQUIRED\|\$signal\|\$summary\|continuation_signal_summary' "$ROOT/files/model-router/scripts/dispatch.sh"
