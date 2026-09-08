#!/usr/bin/env bash
# Rebuilds harness-lib.sh from tests/run-tests.sh (verbatim slices, no edits).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
E=_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.5C-REVIEW
{ head -4 "$E/harness-lib.sh"
  sed -n '30,56p' tests/run-tests.sh
  sed -n '658,840p' tests/run-tests.sh; } > "$E/harness-lib.sh.new"
mv "$E/harness-lib.sh.new" "$E/harness-lib.sh"
