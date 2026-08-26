#!/usr/bin/env bash
# D: the budget is per-ACQUISITION, so slices spent watching one lock
# generation are gone when a LATER generation's window is observed. Does the
# "none appeared while it was waited on" claim survive that?
set -uo pipefail
KIT="$1"; ROOT="$2"; LC="$KIT/tests/lockctl-helper.sh"
rm -rf "$ROOT"; mkdir -p "$ROOT"; ST="$ROOT/st"; mkdir -p "$ST"
STOP="$ROOT/stop"
(
  n=0
  while [[ ! -e "$STOP" ]]; do
    n=$((n+1))
    mkdir -- "$ST/lock" 2>/dev/null || { sleep 0.01; continue; }
    sleep 0.9                      # an ownerless generation that lives ~0.9s
    mv -- "$ST/lock" "$ST/gone.$n" 2>/dev/null && rm -rf -- "$ST/gone.$n" &
  done
) & ADV=$!
sleep 0.2
t0=$(date +%s%N); bash "$LC" "$KIT" "$ST" acquire > "$ROOT/d1" 2>&1; t1=$(date +%s%N)
: > "$STOP"; kill "$ADV" 2>/dev/null; wait "$ADV" 2>/dev/null
echo "elapsed_ms=$(( (t1-t0)/1000000 ))  $(tr '\n' ' ' < "$ROOT/d1")"
