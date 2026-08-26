#!/usr/bin/env bash
# A9d — the reclaimer LOSES the take it earned (a contender creates the lock
# path between the abandoned lock being renamed aside and the reclaimer's own
# mkdir). The real afk_lock_take still runs and still loses. The destruction
# must be reported anyway, exactly once, naming what it destroyed.
set -uo pipefail
KIT="$1"; CTL="$2"; ROUNDS="${3:-15}"
kv(){ printf '%s\n' "$1"|awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,"");print;exit}'; }
silent=0; dup=0; ok=0
for round in $(seq 1 "$ROUNDS"); do
  R=$(mktemp -d); S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"
  INC=$(kv "$("$CTL" "$KIT" "$S" strand)" inc)
  OUT="$("$CTL" "$KIT" "$S" reclaim-losing-take "$INC")"
  RC=$(kv "$OUT" rc); REC=$(kv "$OUT" reclaimed); N=$(kv "$OUT" reclaim_reports)
  ST=$(kv "$OUT" stolen); DET=$(kv "$OUT" reclaim_detail)
  GONE=$([[ -f "$L/owner.json" ]] && jq -r '.incarnation' "$L/owner.json" 2>/dev/null || printf '')
  if [[ "$ST" != "stolen" ]]; then echo "  round $round: contender did NOT steal (fixture did not fire) -- $OUT"; continue; fi
  if [[ "$GONE" == "$INC" ]]; then echo "  round $round: the abandoned lock was NOT destroyed"; continue; fi
  case "$N" in
    0) silent=$((silent+1)); echo "  round $round: SILENT DESTRUCTION rc=$RC reclaimed=$REC reports=0" ;;
    1) ok=$((ok+1)) ;;
    *) dup=$((dup+1)); echo "  round $round: DUPLICATE REPORT reports=$N" ;;
  esac
  [[ $round == 1 ]] && echo "  sample: rc=$RC reclaimed=$REC reports=$N stolen=$ST detail='$DET'"
  rm -rf "$R"
done
echo "rounds=$ROUNDS  exactly-once=$ok  silent=$silent  duplicated=$dup"
