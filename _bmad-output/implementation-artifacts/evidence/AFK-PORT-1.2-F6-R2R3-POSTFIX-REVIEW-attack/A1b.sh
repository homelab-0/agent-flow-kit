#!/usr/bin/env bash
set -uo pipefail
KIT="$1"; CTL="$KIT/tests/lockctl-helper.sh"
kv() { printf '%s\n' "$1" | awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,"");print;exit}'; }
R=$(mktemp -d); trap 'rm -rf "$R"' EXIT
S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"
INC=$(kv "$("$CTL" "$KIT" "$S" strand)" inc)
"$CTL" "$KIT" "$S" strand-marker "$INC" >/dev/null
LOST="$R/lost"; GO="$R/go"; OUT="$R/out"
( "$CTL" "$KIT" "$S" reclaim-marker-interleaved "$INC" "$LOST" "$GO" > "$OUT" ) & P=$!
for i in $(seq 1 200000); do [[ -e "$LOST" ]] && break; done
mv -- "$L" "$S/won"; rm -rf -- "$S/won"; : > "$GO"; wait $P
cat "$OUT"
