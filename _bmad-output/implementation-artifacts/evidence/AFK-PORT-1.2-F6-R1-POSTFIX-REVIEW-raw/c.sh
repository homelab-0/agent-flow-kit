#!/usr/bin/env bash
set -uo pipefail
KIT="$1"; ROOT="$2"; LC="$KIT/tests/lockctl-helper.sh"
rm -rf "$ROOT"; mkdir -p "$ROOT"; ST="$ROOT/st"; mkdir -p "$ST"
echo "== C1 the no-fractional-sleep fallback: still bounded, still long enough? =="
mkdir -p "$ST/lock"
t0=$(date +%s%N)
PATH="$ROOT/nosleep:$PATH" bash "$LC" "$KIT" "$ST" acquire > "$ROOT/c1" 2>&1
t1=$(date +%s%N); echo "  (control, real sleep) ms=$(( (t1-t0)/1000000 )) $(tr '\n' ' ' < "$ROOT/c1")"
# a sleep that refuses fractions, exactly like a POSIX-only sleep
mkdir -p "$ROOT/nosleep"
cat > "$ROOT/nosleep/sleep" <<'SH'
#!/bin/sh
case "$1" in *.*) exit 1 ;; esac
exec /bin/sleep "$@"
SH
chmod +x "$ROOT/nosleep/sleep"
rm -rf "$ST/lock"; mkdir -p "$ST/lock"
t0=$(date +%s%N)
PATH="$ROOT/nosleep:$PATH" bash "$LC" "$KIT" "$ST" acquire > "$ROOT/c1b" 2>&1
t1=$(date +%s%N); echo "  (fraction-refusing sleep) ms=$(( (t1-t0)/1000000 )) $(tr '\n' ' ' < "$ROOT/c1b")"
rm -rf "$ST/lock"

echo "== C2 does the fallback still cover a real publication window? =="
W="$ROOT/w"; P="$ROOT/p"; G="$ROOT/g"
bash "$LC" "$KIT" "$ST" publish-slowly "$W" "$P" "$G" > "$ROOT/c2o" 2>&1 & OW=$!
i=0; while [[ ! -e "$W" ]]; do i=$((i+1)); (( i<40000000 )) || break; done
RDY="$ROOT/rdy"
( PATH="$ROOT/nosleep:$PATH"; exec bash "$LC" "$KIT" "$ST" acquire-announced "$RDY" ) > "$ROOT/c2c" 2>&1 & C=$!
i=0; while [[ ! -e "$RDY" ]]; do i=$((i+1)); (( i<40000000 )) || break; done
sleep 0.15
still=$(kill -0 "$C" 2>/dev/null && echo yes || echo no)
: > "$P"; wait "$C"; : > "$G"; wait "$OW"
echo "  contender_still_waiting_after_150ms=$still result: $(tr '\n' ' ' < "$ROOT/c2c")"
