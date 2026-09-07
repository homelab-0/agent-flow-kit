#!/usr/bin/env bash
# F3/RES-2 — checkpoint freshness. The branch is transcribed from dispatch.sh
# (printed live first) and walked over REAL files with the REAL helpers.
set -uo pipefail
ROOT="${AFK_REVIEW_ROOT:-$(git rev-parse --show-toplevel)}"
D="$ROOT/files/model-router/scripts/dispatch.sh"
# shellcheck disable=SC1090
source "$D" 2>/dev/null || true
echo "=== live source: pre-launch capture ==="
grep -n 'CHECKPOINT_BEFORE' "$D"
echo
echo "=== live source: post-run verdict branch ==="
sed -n '/if \[\[ -f "\$CHECKPOINT_FILE" \]\]; then/,/^  fi$/p' "$D" | grep -vE '^\s*#'
echo
W="$(mktemp -d /tmp/atk-f3.XXXXXX)"; CHECKPOINT_FILE="$W/s.md.checkpoint.json"
ckpt() { jq -nc --arg s "$1" '{schema:$s, completed:[], current_state:"x",
  remaining_acceptance:[], next_steps:[], updated_at:"2026-09-07"}'; }
walk() { # <label>
  local verdict BUDGET_CHECKPOINT_JSON="" ; BUDGET_FINDINGS=()
  verdict="$(artifact_verdict "$CHECKPOINT_FILE" "afk-checkpoint/1" \
               completed current_state remaining_acceptance next_steps updated_at)" || true
  if [[ "$verdict" == "VALID" && -n "$CHECKPOINT_BEFORE" \
        && "$CHECKPOINT_BEFORE" == "$(sha256_of "$CHECKPOINT_FILE")" ]]; then
    verdict="CHECKPOINT_ARTIFACT_STALE"; fi
  if [[ "$verdict" == "VALID" ]]; then
    BUDGET_CHECKPOINT_JSON="$(artifact_identity_json "$CHECKPOINT_FILE")"
  elif [[ "$verdict" == "CHECKPOINT_ARTIFACT_STALE" ]]; then
    BUDGET_FINDINGS+=("CHECKPOINT_ARTIFACT_STALE")
  else BUDGET_FINDINGS+=("CHECKPOINT_ARTIFACT_INVALID"); fi
  printf '%-52s verdict=%-28s published=%-5s findings=[%s]\n' "$1" "$verdict" \
    "$([[ -n "$BUDGET_CHECKPOINT_JSON" ]] && echo yes || echo no)" "${BUDGET_FINDINGS[*]-}"
}
# cycle 1: no checkpoint before, worker writes one -> fresh, published
CHECKPOINT_BEFORE=""; ckpt afk-checkpoint/1 > "$CHECKPOINT_FILE"
walk "CONTROL cycle1: first checkpoint (nothing before)"
# cycle 2: sha captured pre-launch, worker writes NOTHING -> stale
CHECKPOINT_BEFORE="$(sha256_of "$CHECKPOINT_FILE")"
walk "cycle2: identical file after the run"
# cycle 2': worker DOES rewrite it -> fresh again
jq '.current_state="moved on"' "$CHECKPOINT_FILE" > "$CHECKPOINT_FILE.t" && mv "$CHECKPOINT_FILE.t" "$CHECKPOINT_FILE"
walk "CONTROL cycle2': a freshly written checkpoint is published"
# and an invalid one is still INVALID, not STALE
CHECKPOINT_BEFORE="$(sha256_of "$CHECKPOINT_FILE")"
ckpt afk-wrong/9 > "$CHECKPOINT_FILE"; CHECKPOINT_BEFORE="$(sha256_of "$CHECKPOINT_FILE")"
walk "CONTROL: an unchanged INVALID checkpoint stays INVALID"
echo
echo "=== the code published under the code vocabulary? ==="
grep -n 'CHECKPOINT_ARTIFACT_STALE\|WINDOW_UNCORROBORATED' \
  "$ROOT/files/model-router/context-budget-policy.yaml" "$ROOT/lib/afk-commands.sh"
rm -rf "$W"
