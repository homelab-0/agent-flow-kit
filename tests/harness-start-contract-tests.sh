#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="$ROOT/adapters/opencode/plugin.js"
HERMES="$ROOT/adapters/hermes/session-start.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
passed=0
failed=0

ok() { passed=$((passed + 1)); }
no() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

if node --check "$PLUGIN" >/dev/null; then ok; else no "OpenCode plugin parses"; fi

if grep -Fq 'experimental.session.compacting' "$PLUGIN" &&
   grep -Fq 'worker-context.sh' "$PLUGIN" &&
   grep -Fq 'pm-session.sh' "$PLUGIN"; then
  ok
else
  no "OpenCode plugin exposes context and PM hooks"
fi

if grep -Fq 'spawn(sessionStart, [], { detached, stdio: "ignore"' "$PLUGIN" &&
   ! grep -Eq '(^|[^A-Za-z])exec\(' "$PLUGIN"; then
  ok
else
  no "OpenCode startup uses an argument-safe detached updater"
fi

set +e
out="$(env HOME="$TMP/home" "$HERMES" -- true 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 3 && "$out" == *"updater unavailable"* ]]; then
  ok
else
  no "Hermes wrapper fails closed without the stable updater"
fi

printf '%s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
