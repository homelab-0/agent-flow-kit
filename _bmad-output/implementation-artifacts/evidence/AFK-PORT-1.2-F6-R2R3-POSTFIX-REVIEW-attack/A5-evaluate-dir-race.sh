#!/usr/bin/env bash
# A5 — afk_lock_evaluate tests -e then -d. If the lock directory is carried
# away by a winner's rename in between, the verdict is "the lock path is not a
# directory": an UNKNOWN diagnosis (rc 3, remove-by-hand) for a lock that is
# simply gone or has a successor.
set -uo pipefail
KIT=/home/devbox/repos/jlengelbrecht/agent-flow-kit
R=$(mktemp -d); S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"
trap 'rm -rf "$R"; kill %1 2>/dev/null' EXIT
. "$KIT/lib/afk-common.sh"; . "$KIT/lib/afk-source.sh"; . "$KIT/lib/afk-inventory.sh"
. "$KIT/lib/afk-commands.sh"; . "$KIT/lib/afk-plan.sh"; . "$KIT/lib/afk-mutate.sh"
AFK_STATE_DIR="$S"; AFK_LOCK_DIR="$L"
# one real owner record, reused by the churn
mkdir -p "$R/seed"; REC="$(afk_lock_owner_record "$(afk_lock_incarnation_new)")"
printf '%s\n' "$REC" > "$R/rec.json"
# adversary: create the lock (with a record) and carry it away, forever
( while [[ ! -e "$R/stop" ]]; do
    mkdir -- "$L" 2>/dev/null && cp -- "$R/rec.json" "$L/owner.json" 2>/dev/null
    mv -- "$L" "$L.gone" 2>/dev/null && rm -rf -- "$L.gone" 2>/dev/null
  done ) &
N=${1:-150000}
declare -A HITS
for ((i=0;i<N;i++)); do
  afk_lock_evaluate
  k="$AFK_LOCK_OWNER_STATE|$AFK_LOCK_OWNER_DETAIL"
  HITS["$k"]=$(( ${HITS["$k"]:-0} + 1 ))
done
: > "$R/stop"; wait 2>/dev/null
echo "iterations=$N"
for k in "${!HITS[@]}"; do printf '  %8d  %s\n' "${HITS[$k]}" "$k"; done
