#!/usr/bin/env bash
# S1 — a REMAINING observe-then-observe site the R4 fix did not remove.
# afk_lock_reclaim judges the record, then throws the incarnation the judge
# returned away (the variable is literally named `unused_inc`) and re-reads
# owner.json with afk_lock_incarnation_at.  Two looks, two instants, at the
# one place the lifecycle destroys another process's lock.
# This forces a successor to publish between the two looks and asks which way
# the site fails.
set -uo pipefail
KIT="${1:-/home/devbox/repos/jlengelbrecht/agent-flow-kit}"
R=$(mktemp -d); S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"
trap 'rm -rf "$R"' EXIT
. "$KIT/lib/afk-common.sh"; . "$KIT/lib/afk-source.sh"; . "$KIT/lib/afk-inventory.sh"
. "$KIT/lib/afk-commands.sh"; . "$KIT/lib/afk-plan.sh"; . "$KIT/lib/afk-mutate.sh"
AFK_STATE_DIR="$S"; AFK_LOCK_DIR="$L"
afk_state_dir_ensure "$S" >/dev/null
# an abandoned lock: taken by a subshell that then exits
STALE=$(bash -c '. "'"$KIT"'/lib/afk-common.sh"; . "'"$KIT"'/lib/afk-source.sh"
  . "'"$KIT"'/lib/afk-inventory.sh"; . "'"$KIT"'/lib/afk-commands.sh"
  . "'"$KIT"'/lib/afk-plan.sh"; . "'"$KIT"'/lib/afk-mutate.sh"
  AFK_STATE_DIR="'"$S"'"; AFK_LOCK_DIR="'"$L"'"; afk_lock_take >/dev/null 2>&1
  printf "%s" "$AFK_LOCK_INCARNATION"')
echo "abandoned incarnation: $STALE"
# a REAL successor's record, published into the same name between the judge
# and the re-read.  This is what a legitimate handover looks like.
SUCC_INC="$(afk_lock_incarnation_new)"
afk_lock_owner_record "$SUCC_INC" > "$R/succ.json"
FIRED=0
between() {
  if (( FIRED == 0 )) && [[ "$BASH_COMMAND" == *'afk_lock_incarnation_at "$AFK_LOCK_DIR/owner.json"'* ]]; then
    FIRED=1
    cp -- "$R/succ.json" "$L/.t" && mv -- "$L/.t" "$L/owner.json"
  fi
}
set -T; trap between DEBUG
rc=0; afk_lock_reclaim "$STALE" || rc=$?
trap - DEBUG; set +T
echo "interposed between the judge and the re-read: $([[ $FIRED == 1 ]] && echo YES || echo no)"
echo "afk_lock_reclaim rc=$rc   (0=took it, 1=live owner, 2=hard refusal, 3=observe again)"
NOW=$(jq -r '.incarnation // ""' "$L/owner.json" 2>/dev/null || printf '<gone>')
echo "the successor's record after the call: $NOW"
echo "successor's lock still intact        : $([[ "$NOW" == "$SUCC_INC" ]] && echo YES || echo NO)"
echo "reclamation reported                 : $AFK_LOCK_RECLAIMED"
echo "residue                              : $(find "$S" -maxdepth 1 -name 'lock.stale.*' | wc -l)"
if [[ "$NOW" == "$SUCC_INC" && "$rc" != "2" ]]; then
  echo "==> FAILS CLOSED: the second look can only cost a retry, never a wrong destruction."
else
  echo "==> HARMFUL: rc=$rc and the successor's record is $NOW"
fi
