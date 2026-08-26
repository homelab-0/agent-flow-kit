#!/usr/bin/env bash
set -uo pipefail
KIT="$1"; ROOT="$2"
LC="$KIT/tests/lockctl-helper.sh"
rm -rf "$ROOT"; mkdir -p "$ROOT"; ST="$ROOT/st"; mkdir -p "$ST"

echo "=== A2a: lock that NEVER publishes (owner process alive, window never closes) ==="
W="$ROOT/w"; P="$ROOT/never"; G="$ROOT/g"
bash "$LC" "$KIT" "$ST" publish-slowly "$W" "$P" "$G" > "$ROOT/owner.txt" 2>&1 &
OP=$!
i=0; while [[ ! -e "$W" ]]; do i=$((i+1)); (( i < 40000000 )) || break; done
t0=$(date +%s%N)
bash "$LC" "$KIT" "$ST" acquire > "$ROOT/c.txt" 2>&1
t1=$(date +%s%N)
echo "elapsed_ms=$(( (t1-t0)/1000000 ))"
tr '\n' ' ' < "$ROOT/c.txt"; echo
kill -9 "$OP" 2>/dev/null; wait "$OP" 2>/dev/null
rm -rf "$ST/lock"

echo "=== A2b: genuinely unjudgeable lock (malformed record) must cost ZERO wait ==="
for bad in 'not json' '{}' '{"lock_schema_version":"9.9"}'; do
  rm -rf "$ST/lock"; mkdir -p "$ST/lock"; printf '%s' "$bad" > "$ST/lock/owner.json"
  t0=$(date +%s%N); bash "$LC" "$KIT" "$ST" acquire > "$ROOT/b.txt" 2>&1; t1=$(date +%s%N)
  printf 'record=%-32s elapsed_ms=%s ' "$bad" "$(( (t1-t0)/1000000 ))"; tr '\n' ' ' < "$ROOT/b.txt"; echo
done
rm -rf "$ST/lock"

echo "=== A2c: foreign / boot-mismatch locks must cost ZERO wait ==="
inc=$(bash "$LC" "$KIT" "$ST" incarnation | sed 's/^inc=//')
rm -rf "$ST/lock"; mkdir -p "$ST/lock"
jq -nc --arg i "$inc" '{lock_schema_version:"2.0",host_identity:"other-host",boot_identity:"b",pid:1,process_start_identity:"s",incarnation:$i,complete:true}' > "$ST/lock/owner.json"
t0=$(date +%s%N); bash "$LC" "$KIT" "$ST" acquire > "$ROOT/f.txt" 2>&1; t1=$(date +%s%N)
printf 'foreign elapsed_ms=%s ' "$(( (t1-t0)/1000000 ))"; tr '\n' ' ' < "$ROOT/f.txt"; echo
echo "lock_still_there=$([[ -d "$ST/lock" ]] && echo yes || echo no)"
rm -rf "$ST/lock"

echo "=== A2d: ownerless directory with NO owner process at all (pure orphan dir) ==="
mkdir -p "$ST/lock"
t0=$(date +%s%N); bash "$LC" "$KIT" "$ST" acquire > "$ROOT/o.txt" 2>&1; t1=$(date +%s%N)
printf 'orphan elapsed_ms=%s ' "$(( (t1-t0)/1000000 ))"; tr '\n' ' ' < "$ROOT/o.txt"; echo
echo "lock_still_there=$([[ -d "$ST/lock" ]] && echo yes || echo no)"
