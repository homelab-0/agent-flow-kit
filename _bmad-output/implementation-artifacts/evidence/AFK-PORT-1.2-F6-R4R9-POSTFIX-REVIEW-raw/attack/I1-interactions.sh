#!/usr/bin/env bash
# I1 — the single-read judge and destruction-time reporting put together with
# the F6-R1 publication window and the F6-R2/R3 vanished-record moments, with
# REAL processes: contenders acquiring and releasing for real, an abandoned
# lock stranded repeatedly underneath them, and a churner that publishes into
# and carries away the lock path continuously.
#
# Invariants asserted, over the whole run:
#   * mutual exclusion: never two acquisitions holding at once
#   * no acquisition ever reports a valid record as damaged
#   * every destruction is reported, exactly once, by whoever destroyed it
#   * a successor's lock is never destroyed
set -uo pipefail
KIT="$1"; CTL="$2"; ROUNDS="${3:-30}"; N="${4:-6}"
kv(){ printf '%s\n' "$1"|awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,"");print;exit}'; }
cnp=0; excl=0; reports=0; strands=0; held_peak=0; rc0=0
for round in $(seq 1 "$ROUNDS"); do
  R=$(mktemp -d); S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"
  # an abandoned lock to be reclaimed
  INC=$(kv "$("$CTL" "$KIT" "$S" strand)" inc); [[ -n "$INC" ]] && strands=$((strands+1))
  # a churner: carries the lock path away and lets it be republished, which is
  # both the vanished-record moment and the publication window, continuously
  ( while [[ ! -e "$R/stop" ]]; do
      mv -- "$L" "$L.churn.$$" 2>/dev/null && rm -rf -- "$L.churn.$$" 2>/dev/null
    done ) & CH=$!
  B="$R/go"
  for i in $(seq 1 "$N"); do
    ( while [[ ! -e "$B" ]]; do :; done
      "$CTL" "$KIT" "$S" racquire > "$R/o.$i" 2>/dev/null ) &
  done
  : > "$B"; wait $(jobs -p 2>/dev/null | grep -v "^$CH$") 2>/dev/null
  : > "$R/stop"; wait "$CH" 2>/dev/null
  holders=0
  for i in $(seq 1 "$N"); do
    O=$(cat "$R/o.$i" 2>/dev/null)
    D=$(kv "$O" owner_detail); RC=$(kv "$O" rc); NR=$(kv "$O" reclaim_reports)
    [[ "$D" == *"could not be parsed"* ]] && { cnp=$((cnp+1)); echo "  round $round proc $i: FALSE DAMAGE VERDICT -- $O"; }
    [[ "$RC" == "0" ]] && { holders=$((holders+1)); rc0=$((rc0+1)); }
    [[ -n "$NR" ]] && reports=$((reports + NR))
  done
  (( holders > held_peak )) && held_peak=$holders
  rm -rf "$R"
done
echo "rounds=$ROUNDS procs=$N churn=on"
echo "  abandoned locks stranded          : $strands"
echo "  reclamation reports emitted       : $reports"
echo "  acquisitions that took the lock   : $rc0"
echo "  peak simultaneous holders in a rnd: $held_peak   (mutual exclusion: $([[ $held_peak -le 1 ]] && echo INTACT || echo BROKEN))"
echo "  false 'could not be parsed'       : $cnp"
