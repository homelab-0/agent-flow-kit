#!/usr/bin/env bash
# ATTACK 8/9 — harness agnosticism in the CORE budget logic, and diff size.
set -uo pipefail
ROOT="${AFK_REVIEW_ROOT:-$(git rev-parse --show-toplevel)}"
D="$ROOT/files/model-router/scripts/dispatch.sh"
echo "=== a CLI name inside the core budget functions (adapters excluded) ==="
for fn in load_budget_policy budget_threshold_ppm budget_ratio_ppm budget_crosses \
          budget_ratio_decimal budget_evaluate_usage artifact_redact artifact_verdict \
          artifact_identity_json worker_discipline_paragraph record_budget_line \
          record_budget_line_unlocked usage_unobservable; do
  n="$(sed -n "/^${fn}() {/,/^}/p" "$D" | grep -icE 'claude|codex|gemini|anthropic|openai')"
  printf '  %-32s CLI names: %s\n' "$fn" "$n"
done
echo
echo "  the dispatch point (allowed to name harnesses) and the adapters:"
sed -n '/^harness_usage_observation() {/,/^}/p' "$D" | sed 's/^/    /'
echo
echo "=== both harnesses have a named adapter; adding one is an adapter + a case arm ==="
grep -nE '^usage_adapter_[a-z]+\(\)' "$D" | sed 's/^/  /'
echo
echo "=== diff size against master (ec83010), story file excluded ==="
git -C "$ROOT" diff --stat ec83010..HEAD -- ':(exclude)_bmad-output/' | tail -1 | sed 's/^/  /'
ins="$(git -C "$ROOT" diff --numstat ec83010..HEAD -- ':(exclude)_bmad-output/' | awk '{i+=$1; d+=$2} END {print i" insertions, "d" deletions"}')"
files="$(git -C "$ROOT" diff --name-only ec83010..HEAD -- ':(exclude)_bmad-output/' | wc -l)"
echo "  measured: $ins across $files files"
echo "  the record claims: 800 insertions, 34 deletions across 10 files"
echo
echo "=== the diff stays inside the story's declared file surface ==="
git -C "$ROOT" diff --name-only ec83010..HEAD | sed 's/^/  /'
echo
echo "=== commit message: plain, no trailers ==="
git -C "$ROOT" log -1 --format='%B' | cat -A | sed -n '1,20p' | sed 's/^/  /'
echo "  trailer lines (Co-Authored-By / Generated with / Signed-off-by):"
git -C "$ROOT" log -1 --format='%B' | grep -ciE 'co-authored-by|generated with|signed-off-by|claude-session' | sed 's/^/    /'
echo
echo "=== git diff --check ==="
git -C "$ROOT" diff --check ec83010..HEAD && echo "  clean (exit 0)" || echo "  NOT clean"
