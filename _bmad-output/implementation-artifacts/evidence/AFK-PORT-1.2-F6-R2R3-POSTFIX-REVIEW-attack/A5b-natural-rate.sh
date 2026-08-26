#!/usr/bin/env bash
# A5b — natural rate of the F6-R4 misverdict, with a FAITHFUL adversary: the
# record is installed by rename (as afk_state_file_write does), so no torn
# read is possible and every "could not be parsed" is the discriminator race.
set -uo pipefail
KIT=/home/devbox/repos/jlengelbrecht/agent-flow-kit
R=$(mktemp -d); S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"
trap 'rm -rf "$R"' EXIT
. "$KIT/lib/afk-common.sh"; . "$KIT/lib/afk-source.sh"; . "$KIT/lib/afk-inventory.sh"
. "$KIT/lib/afk-commands.sh"; . "$KIT/lib/afk-plan.sh"; . "$KIT/lib/afk-mutate.sh"
AFK_STATE_DIR="$S"; AFK_LOCK_DIR="$L"
afk_lock_owner_record "$(afk_lock_incarnation_new)" > "$R/rec.json"
( while [[ ! -e "$R/stop" ]]; do
    if mkdir -- "$L" 2>/dev/null; then
      cp -- "$R/rec.json" "$L/.t" 2>/dev/null && mv -- "$L/.t" "$L/owner.json" 2>/dev/null
    fi
    mv -- "$L" "$L.gone" 2>/dev/null && rm -rf -- "$L.gone" 2>/dev/null
  done ) &
N=${1:-60000}; parsed_after=0; unparsed_after=0; gone_after=0; total_cnp=0; notdir=0
for ((i=0;i<N;i++)); do
  afk_lock_evaluate
  case "$AFK_LOCK_OWNER_DETAIL" in
    "the lock owner record could not be parsed")
      total_cnp=$((total_cnp+1))
      if v="$(jq -r '.incarnation // ""' "$L/owner.json" 2>/dev/null)" && [[ -n "$v" ]]; then
        parsed_after=$((parsed_after+1))
      elif [[ -f "$L/owner.json" ]]; then unparsed_after=$((unparsed_after+1))
      else gone_after=$((gone_after+1)); fi ;;
    "the lock path is not a directory") notdir=$((notdir+1)) ;;
  esac
done
: > "$R/stop"; wait 2>/dev/null
echo "iterations=$N  could_not_be_parsed=$total_cnp  (valid_record_present_afterwards=$parsed_after, still_unparseable=$unparsed_after, gone_again=$gone_after)"
echo "not_a_directory=$notdir"
