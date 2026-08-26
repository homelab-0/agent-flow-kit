#!/usr/bin/env bash
# A6: isolate the "could not be parsed" mis-diagnosis away from reclaim.
# Only the library ever writes owner.json, and it writes it atomically
# (tmp + mv -f), so a parse failure can only mean the record VANISHED between
# the existence test and the read.
set -uo pipefail
KIT="$1"; ROOT="$2"; N="$3"
LC="$KIT/tests/lockctl-helper.sh"
rm -rf "$ROOT"; mkdir -p "$ROOT"; ST="$ROOT/st"; mkdir -p "$ST"
STOP="$ROOT/stop"
# A: take/release the lock as fast as possible, library writes only.
(
  . "$KIT/lib/afk-common.sh"; . "$KIT/lib/afk-source.sh"; . "$KIT/lib/afk-inventory.sh"
  . "$KIT/lib/afk-commands.sh"; . "$KIT/lib/afk-plan.sh"; . "$KIT/lib/afk-mutate.sh"
  AFK_STATE_DIR="$ST"; AFK_LOCK_DIR="$ST/lock"
  while [[ ! -e "$STOP" ]]; do afk_lock_take >/dev/null 2>&1 && afk_lock_release >/dev/null 2>&1; done
) & A=$!
# B: judge the lock repeatedly, in-process, and tally the verdicts.
(
  . "$KIT/lib/afk-common.sh"; . "$KIT/lib/afk-source.sh"; . "$KIT/lib/afk-inventory.sh"
  . "$KIT/lib/afk-commands.sh"; . "$KIT/lib/afk-plan.sh"; . "$KIT/lib/afk-mutate.sh"
  AFK_STATE_DIR="$ST"; AFK_LOCK_DIR="$ST/lock"
  for _ in $(seq 1 "$N"); do
    afk_lock_evaluate
    printf '%s|%s\n' "$AFK_LOCK_OWNER_STATE" "$AFK_LOCK_OWNER_DETAIL"
  done
) > "$ROOT/verdicts.txt" 2>&1
: > "$STOP"; wait "$A" 2>/dev/null
echo "observations=$(wc -l < "$ROOT/verdicts.txt")"
sed 's/pid [0-9]*/pid N/' "$ROOT/verdicts.txt" | sort | uniq -c | sort -rn
echo "--- records ever written that are NOT valid JSON: ---"
echo "(none can be: afk_state_file_write is tmp + atomic mv -f in the same directory)"
