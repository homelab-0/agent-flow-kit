#!/usr/bin/env bash
# I2 — the honest interaction test. N real contenders acquire the SAME lock at
# a barrier, each measuring how many owners are simultaneously published while
# it holds; an abandoned lock is stranded first so a reclamation is in flight
# through the same window; and a record-level churner carries owner.json out of
# the lock and back, which is the F6-R2/R3 vanished-record moment and the
# F6-R1 publication window -- WITHOUT destroying the mutex itself.
set -uo pipefail
KIT="$1"; CTL="$2"; ROUNDS="${3:-30}"; N="${4:-6}"
kv(){ printf '%s\n' "$1"|awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,"");print;exit}'; }
peak_all=0; cnp=0; reclaimed_true=0; strands=0; took=0; notdir=0
for round in $(seq 1 "$ROUNDS"); do
  R=$(mktemp -d); S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"
  BAR="$R/bar"; OWN="$R/own"; mkdir -p "$BAR" "$OWN"
  INC=$(kv "$("$CTL" "$KIT" "$S" strand)" inc); [[ -n "$INC" ]] && strands=$((strands+1))
  # record-level churn: the record vanishes and comes back, the lock stays
  ( while [[ ! -e "$R/stop" ]]; do
      if [[ -f "$L/owner.json" ]]; then
        mv -- "$L/owner.json" "$L/.hidden" 2>/dev/null && \
        mv -- "$L/.hidden" "$L/owner.json" 2>/dev/null
      fi
    done ) & CH=$!
  cpids=()
  for i in $(seq 1 "$N"); do
    ( "$CTL" "$KIT" "$S" contend "$BAR" "$OWN" "$i" > "$R/o.$i" 2>/dev/null ) &
    cpids+=($!)
  done
  w=0; while (( $(find "$BAR" -name "ready.*" | wc -l) < N )); do w=$((w+1)); (( w < 20000000 )) || break; done
  : > "$BAR/go"
  for cp in "${cpids[@]}"; do wait "$cp" 2>/dev/null; done
  : > "$R/stop"; wait "$CH" 2>/dev/null
  for i in $(seq 1 "$N"); do
    O=$(cat "$R/o.$i" 2>/dev/null); P=$(kv "$O" peak)
    [[ -n "$P" ]] && (( P > peak_all )) && peak_all=$P
    [[ "$(kv "$O" rc)" == "0" ]] && took=$((took+1))
    [[ "$(kv "$O" reclaimed)" == "true" ]] && reclaimed_true=$((reclaimed_true+1))
    D=$(kv "$O" owner_detail)
    [[ "$D" == *"could not be parsed"* ]] && { cnp=$((cnp+1)); echo "  round $round proc $i FALSE DAMAGE: $O"; }
    [[ "$D" == *"not a directory"* ]] && notdir=$((notdir+1))
  done
  rm -rf "$R"
done
echo "rounds=$ROUNDS procs=$N  (abandoned lock + record churn on every round)"
echo "  abandoned locks stranded            : $strands"
echo "  acquisitions that took the lock     : $took"
echo "  acquisitions reporting a reclamation: $reclaimed_true"
echo "  PEAK SIMULTANEOUS PUBLISHED OWNERS  : $peak_all   -> mutual exclusion $([[ $peak_all -le 1 ]] && echo INTACT || echo BROKEN)"
echo "  false 'could not be parsed'         : $cnp"
echo "  F6-R5 'not a directory' verdicts    : $notdir"
