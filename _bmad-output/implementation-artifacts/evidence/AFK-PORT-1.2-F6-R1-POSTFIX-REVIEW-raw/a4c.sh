#!/usr/bin/env bash
# A4c: forced interleaving for the self-reported residual risk -- the
# arbitration marker vanishes between the claim observing it and the judge
# reading it (exactly what a winner's `mv` of the lock directory does, since
# the marker lives INSIDE the lock directory).
set -uo pipefail
KIT="$1"; ROOT="$2"
LC="$KIT/tests/lockctl-helper.sh"
rm -rf "$ROOT"; mkdir -p "$ROOT"; ST="$ROOT/st"; mkdir -p "$ST"
. "$KIT/lib/afk-common.sh"; . "$KIT/lib/afk-source.sh"; . "$KIT/lib/afk-inventory.sh"
. "$KIT/lib/afk-commands.sh"; . "$KIT/lib/afk-plan.sh"; . "$KIT/lib/afk-mutate.sh"
AFK_STATE_DIR="$ST"; AFK_LOCK_DIR="$ST/lock"
eval "$(declare -f afk_lock_marker_claim | sed '1s/^afk_lock_marker_claim/afk_lock_marker_claim_orig/')"

stale_lock() {
  rm -rf "$ST"; mkdir -p "$ST"
  bash "$LC" "$KIT" "$ST" strand >/dev/null 2>&1
  afk_lock_incarnation_at "$AFK_LOCK_DIR/owner.json"
}

echo "===== case 1: reclaim() alone ====="
STALE="$(stale_lock)"; echo "stale_inc=$STALE"
afk_lock_evaluate; echo "judged=$AFK_LOCK_OWNER_STATE|$AFK_LOCK_OWNER_DETAIL"
afk_lock_marker_claim_orig "$AFK_LOCK_DIR/reclaim.$STALE.json"; echo "competitor_marker_rc=$?"
afk_lock_marker_claim() {
  local rc=0
  afk_lock_marker_claim_orig "$@" || rc=$?
  if (( rc == 1 )); then rm -f -- "$1"; echo "[interleave] marker vanished between claim and judge" >&2; fi
  return "$rc"
}
rc=0; afk_lock_reclaim "$STALE" || rc=$?
echo "reclaim_rc=$rc owner_detail=$AFK_LOCK_OWNER_DETAIL"

echo
echo "===== case 2: full afk_lock_acquire, same interleaving ====="
STALE="$(stale_lock)"; echo "stale_inc=$STALE"
afk_lock_marker_claim_orig "$AFK_LOCK_DIR/reclaim.$STALE.json" >/dev/null
AFK_LOCK_HELD="false"; AFK_LOCK_INCARNATION=""
arc=0; afk_lock_acquire || arc=$?
echo "acquire_rc=$arc owner_state=$AFK_LOCK_OWNER_STATE owner_detail=$AFK_LOCK_OWNER_DETAIL"
case "$arc" in
  3) echo "EMITTED=OPERATION_LOCK_OWNER_UNVERIFIABLE / 'remove $AFK_LOCK_DIR by hand'  <-- UNSAFE if a successor holds it" ;;
  1) echo "EMITTED=CONCURRENT_OPERATION_IN_PROGRESS (safe)" ;;
  0) echo "ACQUIRED (rc=0)" ;;
  *) echo "EMITTED=OPERATION_LOCK_UNAVAILABLE (safe)" ;;
esac
echo "lock_present_after=$([[ -d "$AFK_LOCK_DIR" ]] && echo yes || echo no)"
