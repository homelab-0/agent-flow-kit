#!/usr/bin/env bash
set -uo pipefail
KIT="$1"; ROOT="$2"
LC="$KIT/tests/lockctl-helper.sh"
rm -rf "$ROOT"; mkdir -p "$ROOT"; ST="$ROOT/st"
new(){ rm -rf "$ST"; mkdir -p "$ST"; }
one(){ tr '\n' ' ' ; echo; }
lockinc(){ jq -r '.incarnation // ""' "$ST/lock/owner.json" 2>/dev/null; }

echo "== B1 former owner releases AFTER a successor acquired =="
new; bash "$LC" "$KIT" "$ST" strand > "$ROOT/b1s" 2>&1; OLD=$(sed -n 's/^inc=//p' "$ROOT/b1s")
bash "$LC" "$KIT" "$ST" acquire >/dev/null 2>&1   # reclaims, then releases
new; bash "$LC" "$KIT" "$ST" strand > "$ROOT/b1s" 2>&1; OLD=$(sed -n 's/^inc=//p' "$ROOT/b1s")
RDY="$ROOT/r1"; GO="$ROOT/g1"
bash "$LC" "$KIT" "$ST" park "$RDY" "$GO" > "$ROOT/b1p" 2>&1 & P=$!
i=0; while [[ ! -e "$RDY" ]]; do i=$((i+1)); (( i<40000000 )) || break; done
NEW=$(lockinc)
echo -n "  old=$OLD.. new=$NEW.. former-owner-release: "; bash "$LC" "$KIT" "$ST" release-as "$OLD" | one
echo "  lock_inc_still=$(lockinc) same_as_successor=$([[ "$(lockinc)" == "$NEW" ]] && echo yes || echo no)"
: > "$GO"; wait "$P"

echo "== B2 release claiming a bogus incarnation =="
new; bash "$LC" "$KIT" "$ST" strand >/dev/null 2>&1; B=$(lockinc)
echo -n "  "; bash "$LC" "$KIT" "$ST" release-as "inc-1-0000000000000000" | one
echo "  lock_intact=$([[ "$(lockinc)" == "$B" ]] && echo yes || echo no)"

echo "== B3 repeated reclaim of the same incarnation =="
new; bash "$LC" "$KIT" "$ST" strand >/dev/null 2>&1; X=$(lockinc)
for k in 1 2 3; do echo -n "  attempt$k: "; bash "$LC" "$KIT" "$ST" reclaim "$X" | one; done

echo "== B4 owner SIGKILLed while holding the lock =="
new; RDY="$ROOT/r4"; GO="$ROOT/g4"
bash "$LC" "$KIT" "$ST" park "$RDY" "$GO" > "$ROOT/b4" 2>&1 & P=$!
i=0; while [[ ! -e "$RDY" ]]; do i=$((i+1)); (( i<40000000 )) || break; done
pkill -9 -P "$P" 2>/dev/null; kill -9 "$P" 2>/dev/null; wait "$P" 2>/dev/null
echo -n "  next acquire: "; bash "$LC" "$KIT" "$ST" acquire | one
echo "  residue=[$(ls -A "$ST" | tr '\n' ' ')]"

echo "== B5 reclaimer SIGKILLed holding the arbitration marker =="
new; bash "$LC" "$KIT" "$ST" strand >/dev/null 2>&1; X=$(lockinc)
bash "$LC" "$KIT" "$ST" strand-marker "$X" >/dev/null 2>&1   # marker owner exits -> DEAD marker
echo "  marker_present=$([[ -e "$ST/lock/reclaim.$X.json" ]] && echo yes || echo no)"
echo -n "  next acquire: "; bash "$LC" "$KIT" "$ST" acquire | one
echo "  residue=[$(ls -A "$ST" | tr '\n' ' ')]"

echo "== B6/B7 identity changes: pid reuse shape, boot mismatch, host mismatch =="
INC=$(bash "$LC" "$KIT" "$ST" incarnation | sed 's/^inc=//')
mkrec(){ new; mkdir -p "$ST/lock"; jq -nc --arg i "$INC" --arg h "$1" --arg b "$2" --argjson p "$3" --arg s "$4" \
  '{lock_schema_version:"2.0",host_identity:$h,boot_identity:$b,pid:$p,process_start_identity:$s,incarnation:$i,complete:true}' > "$ST/lock/owner.json"; }
H=$(bash -c '. '"$KIT"'/lib/afk-common.sh; afk_host_identity'); B=$(bash -c '. '"$KIT"'/lib/afk-common.sh; afk_boot_identity')
mkrec "$H" "$B" 1 "wrong-start-identity"; echo -n "  pid-reuse-shape: "; bash "$LC" "$KIT" "$ST" judge | one
mkrec "$H" "not-this-boot" 1 "s";        echo -n "  boot-mismatch:   "; bash "$LC" "$KIT" "$ST" judge | one
mkrec "other-host" "$B" 1 "s";           echo -n "  host-mismatch:   "; bash "$LC" "$KIT" "$ST" judge | one
echo -n "  host-mismatch acquire: "; bash "$LC" "$KIT" "$ST" acquire | one
echo "  foreign lock still present=$([[ -d "$ST/lock" ]] && echo yes || echo no)"

echo "== B8 lock path is a symlink / a regular file =="
new; ln -s /etc "$ST/lock";  echo -n "  symlink: "; bash "$LC" "$KIT" "$ST" acquire | one; echo "  /etc intact=$([[ -d /etc/hosts || -f /etc/hosts ]] && echo yes || echo no) link_present=$([[ -L "$ST/lock" ]] && echo yes || echo no)"
new; : > "$ST/lock";        echo -n "  regular: "; bash "$LC" "$KIT" "$ST" acquire | one; echo "  file_present=$([[ -f "$ST/lock" ]] && echo yes || echo no)"

echo "== B9 contender SIGKILLed while inside the bounded publication wait =="
new; W="$ROOT/w9"; P9="$ROOT/p9"; G9="$ROOT/g9"
bash "$LC" "$KIT" "$ST" publish-slowly "$W" "$P9" "$G9" > "$ROOT/b9o" 2>&1 & OW=$!
i=0; while [[ ! -e "$W" ]]; do i=$((i+1)); (( i<40000000 )) || break; done
bash "$LC" "$KIT" "$ST" acquire > "$ROOT/b9c" 2>&1 & C=$!
sleep 0.5
kill -9 "$C" 2>/dev/null; wait "$C" 2>/dev/null
echo "  contender killed mid-wait; lock dir still ownerless=$([[ -d "$ST/lock" && ! -e "$ST/lock/owner.json" ]] && echo yes || echo no)"
: > "$P9"; sleep 0.2; echo "  winner published inc=$(lockinc | cut -c1-20)"
: > "$G9"; wait "$OW" 2>/dev/null
echo "  after winner released: residue=[$(ls -A "$ST" | tr '\n' ' ')]"
