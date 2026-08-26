#!/usr/bin/env bash
# A8 — mutual exclusion under N-way contention, with an abandoned lock and an
# abandoned marker seeded into half the rounds so the reclamation paths and the
# new return-3 paths are on the critical path.
set -uo pipefail
KIT=/home/devbox/repos/jlengelbrecht/agent-flow-kit; CTL="$KIT/tests/lockctl-helper.sh"
kv(){ printf '%s\n' "$1"|awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,"");print;exit}'; }
N=${1:-10}; ROUNDS=${2:-8}
worstpeak=0; twoowners=0; reclaims=0; residue=0; declare -A RC
for ((r=1;r<=ROUNDS;r++)); do
  R=$(mktemp -d); S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"
  B="$R/bar"; O="$R/own"; mkdir -p "$B" "$O"
  if (( r % 2 == 0 )); then
    INC=$(kv "$("$CTL" "$KIT" "$S" strand)" inc)
    (( r % 4 == 0 )) && "$CTL" "$KIT" "$S" strand-marker "$INC" >/dev/null
  fi
  pids=()
  for ((i=1;i<=N;i++)); do ( "$CTL" "$KIT" "$S" contend "$B" "$O" "c$i" > "$R/out.$i" ) & pids+=($!); done
  while (( $(find "$B" -name 'ready.*' | wc -l) < N )); do :; done
  : > "$B/go"
  for p in "${pids[@]}"; do wait "$p"; done
  for ((i=1;i<=N;i++)); do
    t="$(cat "$R/out.$i")"; rc=$(kv "$t" rc); RC[$rc]=$(( ${RC[$rc]:-0} + 1 ))
    pk=$(kv "$t" peak); [[ -z "$pk" ]] || { (( pk > worstpeak )) && worstpeak=$pk; (( pk > 1 )) && twoowners=$((twoowners+1)); }
    [[ "$(kv "$t" reclaimed)" != "true" ]] || reclaims=$((reclaims+1))
    hi=$(kv "$t" held_inc_on_disk); ic=$(kv "$t" inc)
    if [[ -n "$hi" && "$hi" != "$ic" ]]; then echo "  !! owner saw a foreign incarnation on disk: $hi vs $ic"; fi
  done
  n=$(find "$S" -maxdepth 1 -name 'lock.*' | wc -l); residue=$((residue+n))
  rm -rf "$R"
done
echo "rounds=$ROUNDS contenders=$N"
echo "  peak simultaneous owners ever = $worstpeak   (rounds with >1 owner: $twoowners)"
echo "  reclamations=$reclaims   leftover residue dirs=$residue"
for k in "${!RC[@]}"; do echo "  rc=$k n=${RC[$k]}"; done
