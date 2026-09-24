#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECONCILER="$ROOT/bin/afk-release-reconcile"
passed=0
failed=0

ok() { passed=$((passed + 1)); }
no() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

if bash -n "$RECONCILER"; then ok; else no "release reconciler parses"; fi

if grep -Fq "readonly TRUST_REMOTE='ssh://git@github.com/jlengelbrecht/agent-flow-kit.git'" "$RECONCILER" &&
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

# The pinned GitHub host keys must be exactly the ones GitHub publishes. This
# cross-checks the shipped key blobs against their documented fingerprints.
KNOWN_HOSTS="$ROOT/bin/afk-release-known-hosts"
if [[ "$(awk '$1=="github.com"' "$KNOWN_HOSTS" | wc -l)" -eq "$(wc -l <"$KNOWN_HOSTS")" ]]; then
  ok
else
  no "pinned host keys name only github.com"
fi
if command -v ssh-keygen >/dev/null 2>&1; then
  fingerprints="$(ssh-keygen -l -E sha256 -f "$KNOWN_HOSTS" | awk '{print $2}' | LC_ALL=C sort | tr '\n' ' ' || true)"
  if [[ "$fingerprints" == 'SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM ' ]]; then
    ok
  else
    no "pinned host keys match GitHub's published fingerprints (got: $fingerprints)"
  fi
fi

printf '%s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
