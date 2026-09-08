#!/usr/bin/env bash
# Rebuilds harness-lib.sh from tests/run-tests.sh (verbatim slices, no edits).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
E=_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.5C-POSTFIX-REVIEW
{ head -5 "$E/harness-lib.sh"
  sed -n '30,56p' tests/run-tests.sh
  sed -n '658,840p' tests/run-tests.sh; } > "$E/harness-lib.sh.new"
mv "$E/harness-lib.sh.new" "$E/harness-lib.sh"
# fixtures2 — the 3e helper definitions, verbatim slices, appended so the probes
# use the suite's own fixture vocabulary without borrowing any assertion.
{ printf '#!/usr/bin/env bash\n# fixtures2.sh — verbatim slices of tests/run-tests.sh helper defs.\n'
  sed -n '429p'            tests/run-tests.sh
  sed -n '1349,1356p'      tests/run-tests.sh
  sed -n '1832,1839p'      tests/run-tests.sh
  sed -n '2146,2196p'      tests/run-tests.sh; } > "$E/fixtures2.sh"
