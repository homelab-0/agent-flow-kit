#!/usr/bin/env bash
# shellcheck disable=SC2016 # assertions intentionally match literal shell source
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
START="$ROOT/bin/afk-session-start"
passed=0
failed=0

ok() { passed=$((passed + 1)); }
no() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

if bash -n "$START"; then ok; else no "session gate parses"; fi

if "$START" --help 2>&1 | grep -Fq -- '--adapter claude|codex|opencode|hermes'; then
  ok
else
  no "session gate declares all supported harnesses"
fi

if grep -Fq 'BASH_ENV=' "$START" && grep -Fq "ENV=''" "$START" &&
   grep -Fq '"$BASH_EXEC" -p "$runtime/manage.sh"' "$START"; then
  ok
else
  no "adapter installation uses the constrained privileged Bash boundary"
fi

if grep -Fq 'CONVERGED|CURRENT)' "$START" &&
   grep -Fq 'RETAINED)' "$START" &&
   grep -Fq '"$verified" == true' "$START"; then
  ok
else
  no "session launch requires a verified current or retained release"
fi

if grep -Fq 'MACOS_SANDBOX_PENDING' "$START" &&
   grep -Fq 'last_good_verified":false' "$START"; then
  ok
else
  no "Darwin remains an explicit fail-closed boundary"
fi

printf '%s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
