#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECONCILER="$ROOT/bin/afk-release-reconcile"
passed=0
failed=0

ok() { passed=$((passed + 1)); }
no() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

if bash -n "$RECONCILER"; then ok; else no "release reconciler parses"; fi

if grep -Fq "readonly TRUST_REMOTE='https://github.com/jlengelbrecht/agent-flow-kit.git'" "$RECONCILER" &&
   grep -Fq "readonly TRUST_REF='refs/heads/master'" "$RECONCILER" &&
   grep -Fq "readonly TRUST_BRANCH='master'" "$RECONCILER"; then
  ok
else
  no "release source is an immutable AFK trust anchor"
fi

if "$RECONCILER" --help 2>&1 | grep -Fq 'remote, ref, branch, and repository root are immutable trust anchors'; then
  ok
else
  no "operator help reports immutable trust anchors"
fi

set +e
unsupported="$(env OSTYPE=unsupported "$RECONCILER" --plan 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 2 && "$unsupported" == *'"reason":"AUTO_UPDATE_PLATFORM_UNSUPPORTED"'* ]]; then
  ok
else
  no "unsupported platforms fail closed without release access"
fi

if grep -Fq "readonly REQUIRE_TRUSTED_TOOLS=true" "$RECONCILER" &&
   grep -Fq 'CANDIDATE_SANDBOX_UNAVAILABLE' "$RECONCILER" &&
   grep -Fq 'last_good_verified' "$RECONCILER"; then
  ok
else
  no "trusted-tool, sandbox, and verified-last-good boundaries remain present"
fi

printf '%s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
