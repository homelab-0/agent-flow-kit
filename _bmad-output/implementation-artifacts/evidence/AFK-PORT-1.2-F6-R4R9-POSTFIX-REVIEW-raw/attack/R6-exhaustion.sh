#!/usr/bin/env bash
# F6-R6 — what an acquisition says when the bounded retry is exhausted while
# the owner is PROVABLY DEAD.  The reclamation is forced to keep returning 3
# ("the situation moved, observe again"), which is exactly what a lock that
# keeps changing hands produces naturally.
set -uo pipefail
KIT="${1:-/home/devbox/repos/jlengelbrecht/agent-flow-kit}"
R=$(mktemp -d); S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"
trap 'rm -rf "$R"' EXIT
. "$KIT/lib/afk-common.sh"; . "$KIT/lib/afk-source.sh"; . "$KIT/lib/afk-inventory.sh"
. "$KIT/lib/afk-commands.sh"; . "$KIT/lib/afk-plan.sh"; . "$KIT/lib/afk-mutate.sh"
AFK_STATE_DIR="$S"; AFK_LOCK_DIR="$L"
afk_state_dir_ensure "$S" >/dev/null
STALE=$(bash -c '. "'"$KIT"'/lib/afk-common.sh"; . "'"$KIT"'/lib/afk-source.sh"
  . "'"$KIT"'/lib/afk-inventory.sh"; . "'"$KIT"'/lib/afk-commands.sh"
  . "'"$KIT"'/lib/afk-plan.sh"; . "'"$KIT"'/lib/afk-mutate.sh"
  AFK_STATE_DIR="'"$S"'"; AFK_LOCK_DIR="'"$L"'"; afk_lock_take >/dev/null 2>&1
  printf "%s" "$AFK_LOCK_INCARNATION"')
afk_lock_reclaim() { return 3; }   # the situation keeps moving
rc=0; afk_lock_acquire || rc=$?
echo "acquire rc=$rc"
echo "owner_state=$AFK_LOCK_OWNER_STATE"
echo "owner_detail=$AFK_LOCK_OWNER_DETAIL"
AFK_OP_RESULT=""; AFK_OP_REASON=""; AFK_OP_DETAIL=""
case "$rc" in
  3) echo "reason a run would report: OPERATION_LOCK_OWNER_UNVERIFIABLE"
     echo "action:  $(afk_reason_action OPERATION_LOCK_OWNER_UNVERIFIABLE 2>/dev/null)" ;;
  *) echo "reason: (rc $rc)" ;;
esac
echo "reclamation reported: $AFK_LOCK_RECLAIMED"
if [[ "$AFK_LOCK_OWNER_STATE" == "DEAD" && "$rc" == "3" ]]; then
  echo "==> F6-R6 CONFIRMED: the owner is proven DEAD ('$AFK_LOCK_OWNER_DETAIL') and the"
  echo "    run still reports OPERATION_LOCK_OWNER_UNVERIFIABLE and tells an operator to"
  echo "    remove by hand a lock the kit itself has just proven reclaimable."
else
  echo "==> not reproduced (state=$AFK_LOCK_OWNER_STATE rc=$rc)"
fi
