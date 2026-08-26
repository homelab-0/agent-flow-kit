#!/usr/bin/env bash
# A9c — N real processes race to reclaim ONE abandoned lock. Exactly one of
# them destroys it, so across the whole fleet there must be exactly ONE
# reclamation report: never zero (silent destruction) and never two (a
# destruction reported twice).
set -uo pipefail
KIT=/home/devbox/repos/jlengelbrecht/agent-flow-kit; CTL="$1"; N="${2:-8}"; ROUNDS="${3:-25}"
kv(){ printf '%s\n' "$1"|awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,"");print;exit}'; }
bad=0; tot_reports=0
for round in $(seq 1 "$ROUNDS"); do
  R=$(mktemp -d); S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"
  INC=$(kv "$("$CTL" "$KIT" "$S" strand)" inc)
  B="$R/barrier"
  for i in $(seq 1 "$N"); do
    ( while [[ ! -e "$B" ]]; do :; done; "$CTL" "$KIT" "$S" racquire > "$R/out.$i" 2>/dev/null ) &
  done
  : > "$B"; wait
  reports=0; owners=0
  for i in $(seq 1 "$N"); do
    r=$(kv "$(cat "$R/out.$i")" reclaim_reports); [[ -n "$r" ]] || r=0
    reports=$((reports + r))
    [[ "$(kv "$(cat "$R/out.$i")" rc)" == "0" ]] && owners=$((owners+1))
  done
  tot_reports=$((tot_reports + reports))
  # the abandoned incarnation is gone from the lock path in every case
  if (( reports != 1 )); then
    bad=$((bad+1)); echo "  round $round: reports=$reports owners_rc0=$owners  <-- NOT exactly once"
    for i in $(seq 1 "$N"); do echo "     [$i] $(tr '\n' ' ' < "$R/out.$i")"; done
  fi
  (( owners <= 1 )) || { bad=$((bad+1)); echo "  round $round: MUTUAL EXCLUSION BROKEN owners=$owners"; }
  rm -rf "$R"
done
echo "rounds=$ROUNDS procs=$N  total_reports=$tot_reports (expected $ROUNDS)  violations=$bad"
