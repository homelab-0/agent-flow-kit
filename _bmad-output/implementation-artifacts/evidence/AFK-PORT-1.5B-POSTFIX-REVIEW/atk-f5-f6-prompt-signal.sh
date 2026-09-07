#!/usr/bin/env bash
# F5/RES-5,RES-7 and F6/RES-6 — the paragraph, the empty signal, the docs.
set -uo pipefail
ROOT="${AFK_REVIEW_ROOT:-$(git rev-parse --show-toplevel)}"
D="$ROOT/files/model-router/scripts/dispatch.sh"
# shellcheck disable=SC1090
source "$D" 2>/dev/null || true
echo "=== A. the discipline paragraph, verbatim ==="
P="$(worker_discipline_paragraph "/wt/S.md")"; printf '%s\n' "$P"
echo
echo "sha256: $(printf '%s' "$P" | sha256sum | cut -d' ' -f1)"
echo "byte-stable across calls: $([[ "$P" == "$(worker_discipline_paragraph "/wt/S.md")" ]] && echo yes || echo NO)"
echo "story-parameterised:      $([[ "$P" != "$(worker_discipline_paragraph "/wt/T.md")" ]] && echo yes || echo NO)"
for n in "or when the harness signals context pressure" \
         "The reason must not be empty" \
         "never begin a line with it unless you are actually stopping" \
         "CONTINUATION-REQUIRED:" "secret-free"; do
  case "$P" in *"$n"*) echo "PRESENT  [$n]";; *) echo "MISSING  [$n]";; esac
done
echo
echo "=== B. the empty-reason signal takes the invalid path (transcribed) ==="
sed -n '/if grep -qa .\^CONTINUATION-REQUIRED:/,/^    fi$/p' "$D" | grep -vE '^\s*#'
echo "--- summary for each signal shape ---"
for s in 'CONTINUATION-REQUIRED:' 'CONTINUATION-REQUIRED: ' 'CONTINUATION-REQUIRED:   	 ' \
         'CONTINUATION-REQUIRED: out of room' 'CONTINUATION-REQUIRED:x'; do
  sum="$(continuation_signal_summary "$s")"
  [[ "$sum" == reason_given=false* ]] && v=SIGNAL_REASON_EMPTY || v='(evidence is checked)'
  printf '%-42s -> %-52s verdict=%s\n' "[$s]" "$sum" "$v"
done
echo
echo "=== C. F6 documentation: codex tail limit + line anchoring ==="
grep -n 'limit 5000\|line-anchored\|Known limitation' "$ROOT/docs/LIFECYCLE-CONTRACT.md"
echo "the codex tail read itself:"; grep -n 'limit 5000\|--limit' "$D"
echo
echo "=== D. F7: needs_human documented as delivery-only; usage_reason in the sweep ==="
grep -n 'delivery-only' "$ROOT/docs/LIFECYCLE-CONTRACT.md"
grep -n 'usage_reason' "$ROOT/tests/lifecycle-readiness-tests.sh"
