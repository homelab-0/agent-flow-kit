#!/usr/bin/env bash
# A5: a reclaimer that KEEPS HOLDING the lock, plus staggered contenders.
# Any contender refused with rc=3 was told to remove a lock that is provably
# live at that instant.
set -uo pipefail
KIT="$1"; ROOT="$2"; ROUNDS="$3"
LC="$KIT/tests/lockctl-helper.sh"
rm -rf "$ROOT"; mkdir -p "$ROOT"; ST="$ROOT/st"
DELAYS=(0 0.004 0.008 0.012 0.016 0.020 0.024 0.028 0.032 0.036 0.040 0.048 0.056 0.064 0.072 0.080)
bad=0; total=0
for r in $(seq 1 "$ROUNDS"); do
  rm -rf "$ST"; mkdir -p "$ST"
  bash "$LC" "$KIT" "$ST" strand >/dev/null 2>&1
  RDY="$ROOT/rdy.$r"; GO="$ROOT/go.$r"
  bash "$LC" "$KIT" "$ST" park "$RDY" "$GO" > "$ROOT/park.$r" 2>&1 & PARK=$!
  pids=(); k=0
  for d in "${DELAYS[@]}"; do
    k=$((k+1)); ( sleep "$d"; exec bash "$LC" "$KIT" "$ST" acquire ) > "$ROOT/o.$r.$k" 2>&1 & pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; done
  # the holder is still parked here: prove it before letting go
  holder_alive=$(kill -0 "$PARK" 2>/dev/null && echo yes || echo no)
  lock_now=$([[ -d "$ST/lock" ]] && echo present || echo absent)
  owner_inc=$(jq -r '.incarnation // ""' "$ST/lock/owner.json" 2>/dev/null)
  for k in $(seq 1 ${#DELAYS[@]}); do
    total=$((total+1))
    if grep -q '^rc=3$' "$ROOT/o.$r.$k" 2>/dev/null; then
      bad=$((bad+1))
      echo "ROUND $r c$k REFUSED-WITH-REMOVE-GUIDANCE | $(tr '\n' ' ' < "$ROOT/o.$r.$k") | holder_process_alive=$holder_alive lock=$lock_now owner_inc=${owner_inc:0:24}"
    fi
  done
  : > "$GO"; wait "$PARK" 2>/dev/null
done
echo "=== total_acquisitions=$total  told_to_remove_a_live_lock=$bad ==="
grep -h '^rc=' "$ROOT"/o.* | sort | uniq -c
