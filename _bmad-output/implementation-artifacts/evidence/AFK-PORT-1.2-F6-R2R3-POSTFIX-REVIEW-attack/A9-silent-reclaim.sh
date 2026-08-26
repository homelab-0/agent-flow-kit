#!/usr/bin/env bash
# A9 — an abandoned lock removed by a reclaimer that then LOSES the take: the
# lock is reclaimed, one contender converges, and nobody reports it.
set -uo pipefail
KIT=/home/devbox/repos/jlengelbrecht/agent-flow-kit; CTL="$KIT/tests/lockctl-helper.sh"
kv(){ printf '%s\n' "$1"|awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,"");print;exit}'; }
N=${1:-8}; ROUNDS=${2:-30}; silent=0; multi=0; ok=0; nowin=0
for ((r=1;r<=ROUNDS;r++)); do
  R=$(mktemp -d); S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"
  B="$R/bar"; O="$R/own"; mkdir -p "$B" "$O"
  "$CTL" "$KIT" "$S" strand >/dev/null            # one abandoned lock, every round
  pids=(); for ((i=1;i<=N;i++)); do ( "$CTL" "$KIT" "$S" contend "$B" "$O" "c$i" > "$R/out.$i" ) & pids+=($!); done
  while (( $(find "$B" -name 'ready.*'|wc -l) < N )); do :; done
  : > "$B/go"; for p in "${pids[@]}"; do wait "$p"; done
  wins=0; rec=0
  for ((i=1;i<=N;i++)); do t="$(cat "$R/out.$i")"
    [[ "$(kv "$t" rc)" != "0" ]] || wins=$((wins+1))
    [[ "$(kv "$t" reclaimed)" != "true" ]] || rec=$((rec+1)); done
  if (( wins == 1 && rec == 0 )); then silent=$((silent+1)); echo "  round $r: WON but the reclamation was SILENT (wins=$wins reclaimed=$rec)"
  elif (( rec > 1 )); then multi=$((multi+1)); echo "  round $r: reclaimed=$rec (>1)"
  elif (( wins == 0 )); then nowin=$((nowin+1))
  else ok=$((ok+1)); fi
  rm -rf "$R"
done
echo "rounds=$ROUNDS contenders=$N  reported-once=$ok  SILENT=$silent  over-reported=$multi  no-winner=$nowin"
