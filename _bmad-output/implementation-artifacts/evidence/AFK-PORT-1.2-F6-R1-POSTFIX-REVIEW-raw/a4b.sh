#!/usr/bin/env bash
# A4b: STAGGERED arrivals onto a stale lock, so contenders land at every point
# of a reclaimer's marker lifetime -- the arrival pattern a same-instant
# barrier cannot produce.
set -uo pipefail
KIT="$1"; ROOT="$2"; ROUNDS="$3"
LC="$KIT/tests/lockctl-helper.sh"
rm -rf "$ROOT"; mkdir -p "$ROOT"; ST="$ROOT/st"
DELAYS=(0 0.004 0.008 0.012 0.016 0.020 0.026 0.032 0.040 0.048 0.056 0.064 0.072 0.080 0.090 0.100)
for r in $(seq 1 "$ROUNDS"); do
  rm -rf "$ST"; mkdir -p "$ST"
  bash "$LC" "$KIT" "$ST" strand >/dev/null 2>&1
  pids=(); k=0
  for d in "${DELAYS[@]}"; do
    k=$((k+1))
    ( sleep "$d"; exec bash "$LC" "$KIT" "$ST" acquire ) > "$ROOT/o.$r.$k" 2>&1 & pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p"; done
done
echo "total_acquisitions=$(ls "$ROOT"/o.* | wc -l)"
echo "--- rc tally ---"
grep -h '^rc=' "$ROOT"/o.* | sort | uniq -c
echo "--- owner_detail tally ---"
grep -h '^owner_detail=' "$ROOT"/o.* | sort | uniq -c
echo "--- rc=3 records in full ---"
for f in "$ROOT"/o.*; do if grep -q '^rc=3$' "$f"; then echo "[$f] $(tr '\n' ' ' < "$f")"; fi; done | head -30
echo "--- rc=2 records in full ---"
for f in "$ROOT"/o.*; do if grep -q '^rc=2$' "$f"; then echo "[$f] $(tr '\n' ' ' < "$f")"; fi; done | head -20
echo "residue: $(ls -A "$ST" 2>/dev/null | tr '\n' ' ')"
