#!/usr/bin/env bash
# A3: try to starve / extend the bounded wait budget.
set -uo pipefail
KIT="$1"; ROOT="$2"
LC="$KIT/tests/lockctl-helper.sh"
rm -rf "$ROOT"; mkdir -p "$ROOT"; ST="$ROOT/st"; mkdir -p "$ST"
STOP="$ROOT/stop"

# Adversary: churn an OWNERLESS lock directory in and out of existence as fast
# as possible, so a contender's every observation is "no record" and the lock
# also keeps disappearing (the NONE -> continue path).
(
  while [[ ! -e "$STOP" ]]; do
    mkdir -- "$ST/lock" 2>/dev/null && { i=0; while (( i < 400 )); do i=$((i+1)); done; rm -rf -- "$ST/lock" 2>/dev/null; }
  done
) & ADV=$!

maxms=0; maxwaits=0
for r in $(seq 1 12); do
  t0=$(date +%s%N)
  bash "$LC" "$KIT" "$ST" acquire > "$ROOT/r.$r" 2>&1
  t1=$(date +%s%N); ms=$(( (t1-t0)/1000000 ))
  w=$(sed -n 's/^publish_waits=//p' "$ROOT/r.$r")
  rc=$(sed -n 's/^rc=//p' "$ROOT/r.$r")
  (( ms > maxms )) && maxms=$ms
  [[ "$w" =~ ^[0-9]+$ ]] && (( w > maxwaits )) && maxwaits=$w
  printf 'round=%s rc=%s waits=%s ms=%s\n' "$r" "$rc" "$w" "$ms"
done
: > "$STOP"; wait "$ADV" 2>/dev/null
echo "MAX_ELAPSED_MS=$maxms MAX_WAITS=$maxwaits BUDGET=120"

echo "=== A3b: can the budget be raised from the environment? ==="
rm -rf "$ST/lock"; mkdir -p "$ST/lock"   # ownerless, never publishes
t0=$(date +%s%N)
AFK_LOCK_PUBLISH_WAIT_SLICES=100000 AFK_LOCK_PUBLISH_SLICES_LEFT=100000 AFK_LOCK_PUBLISH_WAIT_SLICE=5 \
  bash "$LC" "$KIT" "$ST" acquire > "$ROOT/env.txt" 2>&1
t1=$(date +%s%N)
echo "env_override elapsed_ms=$(( (t1-t0)/1000000 ))"; tr '\n' ' ' < "$ROOT/env.txt"; echo
rm -rf "$ST/lock"
