#!/usr/bin/env bash
# A3 — an adversary that forces vanished-marker / vanished-record observations
# over and over. Acquisition must TERMINATE, bounded, with a truthful detail.
set -uo pipefail
KIT=/home/devbox/repos/jlengelbrecht/agent-flow-kit; CTL="$KIT/tests/lockctl-helper.sh"
kv() { printf '%s\n' "$1" | awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,"");print;exit}'; }
R=$(mktemp -d); S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"
trap 'rm -rf "$R"' EXIT
. "$KIT/lib/afk-common.sh"; . "$KIT/lib/afk-source.sh"; . "$KIT/lib/afk-inventory.sh"
. "$KIT/lib/afk-commands.sh"; . "$KIT/lib/afk-plan.sh"; . "$KIT/lib/afk-mutate.sh"
AFK_STATE_DIR="$S"; AFK_LOCK_DIR="$L"
DEADINC="$(kv "$("$CTL" "$KIT" "$S" strand)" inc)"
cp "$L/owner.json" "$R/dead-owner.json"; MARKER="reclaim.$DEADINC.json"
cp "$L/owner.json" "$R/dead-marker.json"
rm -rf "$L"
# adversary: rebuild a DEAD lock that ALREADY carries a losing marker, then
# carry the whole directory away -- the exact F6-R2 interleaving, on repeat.
( while [[ ! -e "$R/stop" ]]; do
    if mkdir -- "$L" 2>/dev/null; then
      cp -- "$R/dead-owner.json" "$L/.t" && mv -- "$L/.t" "$L/owner.json"
      cp -- "$R/dead-marker.json" "$L/.m" && mv -- "$L/.m" "$L/$MARKER"
    fi
    mv -- "$L" "$L.gone" 2>/dev/null && rm -rf -- "$L.gone" 2>/dev/null
  done ) &
ADV=$!
worst=0; declare -A RCS; declare -A DET
for i in $(seq 1 40); do
  t0=$(date +%s%3N); O="$("$CTL" "$KIT" "$S" acquire)"; t1=$(date +%s%3N)
  e=$((t1-t0)); (( e > worst )) && worst=$e
  r=$(kv "$O" rc); RCS[$r]=$(( ${RCS[$r]:-0} + 1 ))
  d="$(kv "$O" owner_detail)"; DET["$r :: $d"]=$(( ${DET["$r :: $d"]:-0} + 1 ))
done
: > "$R/stop"; wait $ADV 2>/dev/null
echo "40 acquisitions under a vanish adversary; worst wall clock ${worst} ms"
for k in "${!RCS[@]}"; do echo "  rc=$k  n=${RCS[$k]}"; done
echo "--- rc :: detail ---"
for k in "${!DET[@]}"; do printf '  %3d  %s\n' "${DET[$k]}" "$k"; done
echo "residue: $(find "$S" -maxdepth 1 -name 'lock.*' | wc -l)"
