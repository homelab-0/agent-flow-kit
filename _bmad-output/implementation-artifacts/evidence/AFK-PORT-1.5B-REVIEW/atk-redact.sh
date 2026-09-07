#!/usr/bin/env bash
# ATTACK 1 — artifact_redact strength vs the kit's own afk_redact_value.
set -uo pipefail
cd "$(dirname "$0")" >/dev/null 2>&1 || true
ROOT="${AFK_REVIEW_ROOT:-$(git rev-parse --show-toplevel)}"
# shellcheck disable=SC1090
source "$ROOT/files/model-router/scripts/dispatch.sh" 2>/dev/null || true
echo "--- CONTROL: the reviewed test's own sentinel (30 chars) ---"
printf 'in : %s\nout: %s\n\n' "sk-live-9f2a4c7e1b8d3550aa11bb22cc33" "$(artifact_redact "leaked sk-live-9f2a4c7e1b8d3550aa11bb22cc33 here")"
echo "--- ATTACK: real-world secrets under 24 chars, or broken by an excluded char ---"
for s in \
  'AKIAIOSFODNN7EXAMPLE' \
  'ghp_16C7e42F292c6912' \
  'hunter2' \
  'xoxb-2f9a:8c1d-77aa-991b-4e2a-77cc-11dd-99ff' \
  'Bearer eyJhbGci=OiJIUzI1NiIsInR5cCI6IkpXVCJ9' \
  'password=Tr0ub4dor&3'
do
  printf '%-46s -> %s\n' "$s" "$(artifact_redact "CONTINUATION-REQUIRED: auth failed with $s")"
done
echo
echo "--- the kit's OWN redactor on the same values (lib/afk-common.sh) ---"
source "$ROOT/lib/afk-common.sh" 2>/dev/null || true
for s in 'AKIAIOSFODNN7EXAMPLE' 'hunter2'; do
  printf '%-22s -> %s\n' "$s" "$(afk_redact_value "$s")"
done
