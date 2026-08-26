#!/usr/bin/env bash
# E: discriminate "the record VANISHED" from "jq failed for another reason".
set -uo pipefail
KIT="$1"; ROOT="$2"; N="$3"
rm -rf "$ROOT"; mkdir -p "$ROOT"; ST="$ROOT/st"; mkdir -p "$ST"
STOP="$ROOT/stop"
(
  . "$KIT/lib/afk-common.sh"; . "$KIT/lib/afk-source.sh"; . "$KIT/lib/afk-inventory.sh"
  . "$KIT/lib/afk-commands.sh"; . "$KIT/lib/afk-plan.sh"; . "$KIT/lib/afk-mutate.sh"
  AFK_STATE_DIR="$ST"; AFK_LOCK_DIR="$ST/lock"
  while [[ ! -e "$STOP" ]]; do afk_lock_take >/dev/null 2>&1 && afk_lock_release >/dev/null 2>&1; done
) & A=$!
(
  . "$KIT/lib/afk-common.sh"; . "$KIT/lib/afk-source.sh"; . "$KIT/lib/afk-inventory.sh"
  . "$KIT/lib/afk-commands.sh"; . "$KIT/lib/afk-plan.sh"; . "$KIT/lib/afk-mutate.sh"
  AFK_STATE_DIR="$ST"; AFK_LOCK_DIR="$ST/lock"
  hits=0; malformed=0; gone=0; present_ok=0
  for _ in $(seq 1 "$N"); do
    afk_lock_evaluate
    if [[ "$AFK_LOCK_OWNER_DETAIL" == "the lock owner record could not be parsed" ]]; then
      hits=$((hits+1))
      # immediately: is the record there at all, and if so is it valid JSON?
      if [[ ! -e "$AFK_LOCK_DIR/owner.json" ]]; then gone=$((gone+1))
      elif jq -e . "$AFK_LOCK_DIR/owner.json" >/dev/null 2>&1; then present_ok=$((present_ok+1))
      else malformed=$((malformed+1)); cp -- "$AFK_LOCK_DIR/owner.json" "$ROOT/bad.$hits" 2>/dev/null; fi
    fi
  done
  printf 'parse_verdicts=%s  record_gone_right_after=%s  record_present_and_VALID=%s  record_present_and_malformed=%s\n' \
    "$hits" "$gone" "$present_ok" "$malformed"
) > "$ROOT/out" 2>&1
: > "$STOP"; wait "$A" 2>/dev/null
cat "$ROOT/out"
echo "any malformed record ever captured: $(ls "$ROOT"/bad.* 2>/dev/null | wc -l)"
