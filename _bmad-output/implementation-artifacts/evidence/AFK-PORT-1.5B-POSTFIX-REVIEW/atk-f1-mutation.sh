#!/usr/bin/env bash
# F1 anti-vacuity — restore the PREVIOUS commit's behaviour in a scratch copy and
# show the new AC-5 sentinels DO travel, i.e. the new assertions are not vacuous.
set -uo pipefail
ROOT="${AFK_REVIEW_ROOT:-$(git rev-parse --show-toplevel)}"
SCRATCH="$(mktemp -d /tmp/atk-f1-mut.XXXXXX)"
git -C "$ROOT" show 54dfd14:files/model-router/scripts/dispatch.sh > "$SCRATCH/old-dispatch.sh"
# shellcheck disable=SC1090
source "$SCRATCH/old-dispatch.sh" 2>/dev/null || true
echo "=== OLD behaviour (54dfd14): what the marker's third line would have carried ==="
for s in 'hunter2' 'password=Tr0ub4dor&3' 'xoxb-2f9a:8c1d-77aa-9e0f' 'sk-live-9f2a4c7e1b8d3550aa11bb22cc33'; do
  line="CONTINUATION-REQUIRED: context exhausted, the token was $s"
  out="$(artifact_redact "$line")"
  printf 'sentinel=%-36s marker_line=%s\n' "$s" "$out"
  case "$out" in *"$s"*) echo "   -> LEAKS (new assert_absent would FAIL here)";;
                  *) echo "   -> masked by the 24-char denylist";; esac
done
rm -rf "$SCRATCH"
