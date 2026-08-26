#!/usr/bin/env bash
# F6-R8 — the restore guard `[[ -e "$AFK_LOCK_DIR" ]] || mv -- "$aside" ...`
# is a test then an act. A contender that creates the lock path between them
# makes the `mv` land the stale directory INSIDE a live owner's lock.
# Forced with a DEBUG trap: not a line of the guard is replaced.
set -uo pipefail
KIT="${1:-/home/devbox/repos/jlengelbrecht/agent-flow-kit}"
R=$(mktemp -d); S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"
trap 'rm -rf "$R"' EXIT
. "$KIT/lib/afk-common.sh"; . "$KIT/lib/afk-source.sh"; . "$KIT/lib/afk-inventory.sh"
. "$KIT/lib/afk-commands.sh"; . "$KIT/lib/afk-plan.sh"; . "$KIT/lib/afk-mutate.sh"
AFK_STATE_DIR="$S"; AFK_LOCK_DIR="$L"
afk_state_dir_ensure "$S" >/dev/null
# a lock this process holds, so afk_lock_release takes the restore path
afk_lock_take >/dev/null 2>&1 || { echo "fixture: no lock"; exit 1; }
MYINC="$AFK_LOCK_INCARNATION"
# make the proof-after-rename FAIL, so the restore guard is reached
FIRED=0
sabotage() {
  # after the rename aside, corrupt the aside record so the incarnation proof
  # fails, then -- between the `-e` test and the `mv` back -- a contender
  # creates the lock path for real.
  if (( FIRED == 0 )) && [[ "$BASH_COMMAND" == *'mv -- "$aside"'* ]]; then
    FIRED=1
    mkdir -- "$L" 2>/dev/null && printf 'contender\n' > "$L/marker"
  fi
}
# corrupt the aside so the guard path runs at all
eval "afk_lock_incarnation_at_real() $(declare -f afk_lock_incarnation_at | tail -n +2)"
afk_lock_incarnation_at() {
  case "$1" in
    *.released.*/owner.json) printf ''; return 1 ;;
    *) afk_lock_incarnation_at_real "$@" ;;
  esac
}
set -T; trap sabotage DEBUG
afk_lock_release; RC=$?
trap - DEBUG; set +T
echo "release rc=$RC  guard raced: $([[ $FIRED == 1 ]] && echo YES || echo no)"
echo "lock path is a live contender's dir: $([[ -f $L/marker ]] && echo yes || echo no)"
NEST=$(find "$L" -maxdepth 1 -name 'lock.released.*' 2>/dev/null | wc -l)
echo "stale directories NESTED inside the live lock: $NEST"
if (( NEST > 0 )); then
  echo "==> F6-R8 REPRODUCED: $(find "$L" -maxdepth 1 -name 'lock.released.*')"
  echo "    contents: $(ls "$L" | tr '\n' ' ')"
else
  echo "==> not reproduced this way"
fi
