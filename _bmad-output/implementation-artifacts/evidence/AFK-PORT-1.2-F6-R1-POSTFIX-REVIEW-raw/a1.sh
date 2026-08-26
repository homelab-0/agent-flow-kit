#!/usr/bin/env bash
set -uo pipefail
KIT="$1"; ROOT="$2"; N="$3"
LC="$KIT/tests/lockctl-helper.sh"
rm -rf "$ROOT"; mkdir -p "$ROOT"
ST="$ROOT/st"; mkdir -p "$ST"
W="$ROOT/w"; P="$ROOT/p"; G="$ROOT/g"
OUT="$ROOT/out"; mkdir -p "$OUT"
bash "$LC" "$KIT" "$ST" publish-slowly "$W" "$P" "$G" > "$OUT/owner.txt" 2>&1 &
OWNERPID=$!
i=0; while [[ ! -e "$W" ]]; do i=$((i+1)); (( i < 40000000 )) || { echo "window never opened"; exit 1; }; done
echo "window_open=yes lockdir=$([[ -d "$ST/lock" ]] && echo yes || echo no) owner_json=$([[ -e "$ST/lock/owner.json" ]] && echo yes || echo no)"
pids=()
for id in $(seq 1 "$N"); do
  bash "$LC" "$KIT" "$ST" acquire-announced "$ROOT/ready.$id" > "$OUT/c.$id.txt" 2>&1 &
  pids+=($!)
done
for id in $(seq 1 "$N"); do
  i=0; while [[ ! -e "$ROOT/ready.$id" ]]; do i=$((i+1)); (( i < 40000000 )) || break; done
done
sleep 0.3
echo "mid_window_owner_json=$([[ -e "$ST/lock/owner.json" ]] && echo yes || echo no)"
echo "publishing"
: > "$P"
for p in "${pids[@]}"; do wait "$p"; done
echo "contenders done"
: > "$G"
wait "$OWNERPID"
echo "--- owner ---"; cat "$OUT/owner.txt"
for id in $(seq 1 "$N"); do echo "--- c$id ---"; tr '\n' ' ' < "$OUT/c.$id.txt"; echo; done
echo "residue: $(ls -A "$ST" 2>/dev/null | tr '\n' ' ')"
