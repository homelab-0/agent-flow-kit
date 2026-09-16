#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
passed=0
failed=0

ok() { passed=$((passed + 1)); }
no() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

before="$(declare -F | wc -l)"
# shellcheck source=/dev/null
. "$ROOT/adapters/manage-core.sh"
# shellcheck source=/dev/null
. "$ROOT/adapters/manage-transactions.sh"
after="$(declare -F | wc -l)"

if (( after > before )); then ok; else no "core module defines functions"; fi
if declare -F acquire_manager_lock >/dev/null; then ok; else no "lock primitive is available"; fi
if declare -F jsonc_plugin >/dev/null; then ok; else no "JSONC primitive is available"; fi
if declare -F v2_record_identity_valid >/dev/null; then ok; else no "v2 identity validator is available"; fi
if declare -F migrate_v2_record >/dev/null; then ok; else no "v2 migrator is available"; fi
if declare -F recover_v2_migration >/dev/null; then ok; else no "migration recovery is available"; fi
if declare -F rollback_pending_install >/dev/null; then ok; else no "install recovery is available"; fi

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
printf 'fixture\n' >"$tmp/file"
if safe_exact_path "$tmp/file" "$tmp/file"; then ok; else no "exact regular path is accepted"; fi
ln -s "$tmp/file" "$tmp/link"
if safe_exact_path "$tmp/link" "$tmp/link"; then no "symlink is rejected"; else ok; fi

printf '%s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
