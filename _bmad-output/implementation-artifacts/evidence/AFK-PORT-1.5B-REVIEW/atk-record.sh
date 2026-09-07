#!/usr/bin/env bash
# ATTACK 6 — record_budget_line: idempotence keyed on code+cycle, coexistence,
# and the lane A race property on the new signature.
set -uo pipefail
ROOT="${AFK_REVIEW_ROOT:-$(git rev-parse --show-toplevel)}"
source "$ROOT/files/model-router/scripts/dispatch.sh" 2>/dev/null || true
W=${TMP:-/tmp}/rev1.5b/rec; rm -rf "$W"; mkdir -p "$W"
mk() { printf -- '---\npersona: dev\n---\n\nBODY-SENTINEL\n\n## Dev Agent Record\n\n(worker)\n\n## After\n\ntail\n' > "$1"; }

echo "=== both codes in ONE cycle coexist, each once ==="
mk "$W/a.md"
for i in 1 2 3; do
  record_budget_line "$W/a.md" 1 SIZING_RISK "100/200 (0.500000)" 2>/dev/null
  record_budget_line "$W/a.md" 1 CONTINUATION_REQUIRED "sha256:deadbeef" 2>/dev/null
done
grep -ac '^- budget: SIZING_RISK ' "$W/a.md" | sed 's/^/  SIZING_RISK lines (want 1): /'
grep -ac '^- budget: CONTINUATION_REQUIRED ' "$W/a.md" | sed 's/^/  CONTINUATION_REQUIRED lines (want 1): /'
grep -ac 'BODY-SENTINEL' "$W/a.md" | sed 's/^/  body preserved (want 1): /'
echo "  placement:"; grep -n -A6 '## Dev Agent Record' "$W/a.md" | sed 's/^/    /'

echo
echo "=== a NEW cycle is a new observation ==="
for c in 1 2 3; do record_budget_line "$W/a.md" "$c" CONTINUATION_REQUIRED "sha256:x$c" 2>/dev/null; done
grep -ac '^- budget: CONTINUATION_REQUIRED ' "$W/a.md" | sed 's/^/  CONTINUATION_REQUIRED lines over cycles 1-3 (want 3): /'

echo
echo "=== the lane A race property, on the new signature (8-way x 10 trials) ==="
LOST=0 DAMAGED=0
for t in $(seq 10); do
  mk "$W/r.md"
  for c in $(seq 8); do ( record_budget_line "$W/r.md" "$c" SIZING_RISK "100/200 (0.500000)" ) >/dev/null 2>&1 & done
  wait
  [[ "$(grep -ac '^- budget: SIZING_RISK ' "$W/r.md")" == 8 ]] || LOST=$((LOST+1))
  [[ "$(grep -ac 'BODY-SENTINEL' "$W/r.md")" == 1 ]] || DAMAGED=$((DAMAGED+1))
done
echo "  trials with a lost line: $LOST/10   trials with a damaged body: $DAMAGED/10"

echo
echo "=== CONTROL (anti-vacuity): the UNLOCKED append under the same 8-way race ==="
CLOST=0
for t in $(seq 10); do
  mk "$W/c.md"
  for c in $(seq 8); do ( record_budget_line_unlocked "$W/c.md" "$c" SIZING_RISK "100/200 (0.500000)" ) >/dev/null 2>&1 & done
  wait
  [[ "$(grep -ac '^- budget: SIZING_RISK ' "$W/c.md")" == 8 ]] || CLOST=$((CLOST+1))
done
echo "  unlocked trials with a lost line: $CLOST/10  (>0 means the race harness above is not blind)"

echo
echo "=== a story with NO Dev Agent Record heading ==="
printf -- '---\npersona: dev\n---\n\nBODY-SENTINEL\n' > "$W/n.md"
record_budget_line "$W/n.md" 1 CONTINUATION_REQUIRED "sha256:z" 2>/dev/null
tail -4 "$W/n.md" | sed 's/^/  /'
