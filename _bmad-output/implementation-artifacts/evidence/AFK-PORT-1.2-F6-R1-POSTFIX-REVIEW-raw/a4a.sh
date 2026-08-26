#!/usr/bin/env bash
# A4a: N-way simultaneous reclaim of one stale lock, many rounds. Looking for
# ANY loser told to remove the lock by hand while a successor holds it.
set -uo pipefail
KIT="$1"; ROOT="$2"; N="$3"; ROUNDS="$4"
LC="$KIT/tests/lockctl-helper.sh"
rm -rf "$ROOT"; mkdir -p "$ROOT"; ST="$ROOT/st"; mkdir -p "$ST"
declare -A TALLY=()
badguidance=0; residue_rounds=0; multiwin=0
for r in $(seq 1 "$ROUNDS"); do
  rm -rf "$ST"; mkdir -p "$ST"
  bash "$LC" "$KIT" "$ST" strand >/dev/null 2>&1        # stale lock, owner pid gone
  bar="$ROOT/bar.$r"; own="$ROOT/own.$r"; rm -rf "$bar" "$own"; mkdir -p "$bar" "$own"
  pids=()
  for id in $(seq 1 "$N"); do
    bash "$LC" "$KIT" "$ST" contend "$bar" "$own" "$id" > "$ROOT/o.$r.$id" 2>&1 & pids+=($!)
  done
  for id in $(seq 1 "$N"); do i=0; while [[ ! -e "$bar/ready.$id" ]]; do i=$((i+1)); (( i<40000000 )) || break; done; done
  : > "$bar/go"
  for p in "${pids[@]}"; do wait "$p"; done
  wins=0
  for id in $(seq 1 "$N"); do
    rc=$(sed -n 's/^rc=//p' "$ROOT/o.$r.$id")
    TALLY[$rc]=$(( ${TALLY[$rc]:-0} + 1 ))
    [[ "$rc" == "0" ]] && wins=$((wins+1))
    pk=$(sed -n 's/^peak=//p' "$ROOT/o.$r.$id"); [[ -n "$pk" && "$pk" != "1" ]] && multiwin=$((multiwin+1))
  done
  (( wins == 1 )) || { echo "ROUND $r: winners=$wins  <-- MUTUAL EXCLUSION"; }
  left=$(ls -A "$ST" 2>/dev/null | tr '\n' ' ')
  [[ -n "$left" ]] && { residue_rounds=$((residue_rounds+1)); echo "ROUND $r residue: $left"; }
done
echo "--- tally over $ROUNDS rounds x $N contenders ---"
for k in "${!TALLY[@]}"; do echo "rc=$k count=${TALLY[$k]}"; done
echo "peak_gt_1_observations=$multiwin residue_rounds=$residue_rounds"
echo "--- distinct owner_detail values on rc=3 ---"
grep -l '^rc=3$' "$ROOT"/o.* 2>/dev/null | xargs -r grep -h '^owner_detail=' | sort | uniq -c
echo "--- distinct owner_detail values on rc=2 ---"
grep -l '^rc=2$' "$ROOT"/o.* 2>/dev/null | xargs -r grep -h '^owner_detail=' | sort | uniq -c
