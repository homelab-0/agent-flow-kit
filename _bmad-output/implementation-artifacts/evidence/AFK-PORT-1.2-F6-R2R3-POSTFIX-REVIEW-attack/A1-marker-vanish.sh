#!/usr/bin/env bash
# A1 — independently force the lost-marker-then-vanish interleaving.
set -uo pipefail
. "$(dirname "$0")/env.sh"
R=$(mktemp -d); trap 'rm -rf "$R"' EXIT
S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"
# strand a lock: a subshell takes it and exits without releasing
STR=$("$CTL" "$KIT" "$S" strand)
INC=$(kv "$STR" inc)
echo "stranded inc=$INC  rc=$(kv "$STR" rc)"
# a foreign reclaimer wins the marker
echo "strand-marker rc=$("$CTL" "$KIT" "$S" strand-marker "$INC" | sed -n 's/^rc=//p')"
ls "$L"
# now a loser reclaims, held between claim and judge
LOST="$R/lost"; GO="$R/go"; OUT="$R/out"
( "$CTL" "$KIT" "$S" reclaim-marker-interleaved "$INC" "$LOST" "$GO" > "$OUT" ) &
P=$!
for i in $(seq 1 200000); do [[ -e "$LOST" ]] && break; done
[[ -e "$LOST" ]] || { echo "TIMEOUT waiting for lost"; kill $P; exit 1; }
echo "loser is parked; marker present: $([[ -e "$L/reclaim.$INC.json" ]] && echo yes || echo no)"
# the winner's rename carries the marker away
mv -- "$L" "$S/won"; rm -rf -- "$S/won"
: > "$GO"; wait $P
echo "--- loser result ---"; cat "$OUT"
