#!/usr/bin/env bash
# F6-R5, forced. The fix report says no deterministic interleaving exists
# between afk_lock_evaluate's `[[ -e ]]` and `[[ ! -d ]]` because "both tests
# are shell builtins with no fork between them, so nothing external can be
# scheduled there, and forcing it would mean replacing the function under
# test".  A DEBUG trap is a scheduling point bash itself provides BETWEEN
# simple commands.  Not one line of afk_lock_evaluate is replaced.
set -uo pipefail
KIT="${1:-/home/devbox/repos/jlengelbrecht/agent-flow-kit}"
R=$(mktemp -d); S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"
trap 'rm -rf "$R"' EXIT
. "$KIT/lib/afk-common.sh"; . "$KIT/lib/afk-source.sh"; . "$KIT/lib/afk-inventory.sh"
. "$KIT/lib/afk-commands.sh"; . "$KIT/lib/afk-plan.sh"; . "$KIT/lib/afk-mutate.sh"
AFK_STATE_DIR="$S"; AFK_LOCK_DIR="$L"
afk_state_dir_ensure "$S" >/dev/null
afk_lock_take >/dev/null 2>&1 || { echo "fixture: could not take the lock"; exit 1; }
echo "a real lock is held, incarnation $AFK_LOCK_INCARNATION"
FIRED=0
handover() {
  # exactly what a legitimate release / winning reclaimer does
  if (( FIRED == 0 )) && [[ "$BASH_COMMAND" == *'! -d'* ]]; then
    FIRED=1
    mv -- "$L" "$L.handover" 2>/dev/null
    rm -rf -- "$L.handover" 2>/dev/null
  fi
}
set -T
trap handover DEBUG
afk_lock_evaluate
trap - DEBUG; set +T
echo "trap fired between the two tests: $([[ $FIRED == 1 ]] && echo YES || echo no)"
echo "state=$AFK_LOCK_OWNER_STATE"
echo "detail=$AFK_LOCK_OWNER_DETAIL"
if [[ "$AFK_LOCK_OWNER_DETAIL" == "the lock path is not a directory" ]]; then
  echo "==> F6-R5 REPRODUCED DETERMINISTICALLY: a lock legitimately handed over"
  echo "    between the two builtins is reported as a malformed lock path"
  echo "    (UNKNOWN -> 'remove the lock directory by hand')."
else
  echo "==> not reproduced this way (state=$AFK_LOCK_OWNER_STATE)"
fi
