#!/usr/bin/env bash
# A6d — the budget is spent watching lock D1; D1 goes away; a LIVE process
# creates a BRAND NEW lock D2 and is in its publication window. The same
# acquisition refuses D2 in milliseconds, having never watched it, and says
# "none appeared while it was waited on".
set -uo pipefail
KIT=/home/devbox/repos/jlengelbrecht/agent-flow-kit
R=$(mktemp -d); S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"
trap 'rm -rf "$R"' EXIT
. "$KIT/lib/afk-common.sh"; . "$KIT/lib/afk-source.sh"; . "$KIT/lib/afk-inventory.sh"
. "$KIT/lib/afk-commands.sh"; . "$KIT/lib/afk-plan.sh"; . "$KIT/lib/afk-mutate.sh"
AFK_STATE_DIR="$S"; AFK_LOCK_DIR="$L"
for d in "$@"; do
  rm -rf "$L" "$R/adv-done" "$R/judged" "$R/stop" "$R/d1id" "$R/d2id"
  ( mkdir -p "$L"; stat -c %i "$L" > "$R/d1id"
    R2="$(afk_lock_owner_record "$(afk_lock_incarnation_new)")"   # prepared in advance
    sleep "$d"
    mv -- "$L" "$L.gone"; mkdir -- "$L"; stat -c %i "$L" > "$R/d2id"; rm -rf -- "$L.gone"
    i=0; while [[ ! -e "$R/judged" ]]; do i=$((i+1)); (( i<40000000 )) || break; done
    printf '%s\n' "$R2" > "$L/.p" && mv "$L/.p" "$L/owner.json"
    printf 'live_owner_pid=%s\n' "$$" > "$R/adv-done"
    i=0; while [[ ! -e "$R/stop" ]]; do i=$((i+1)); (( i<40000000 )) || break; done ) &
  ADV=$!
  t0=$(date +%s%3N); rc=0; afk_lock_acquire || rc=$?; t1=$(date +%s%3N)
  : > "$R/judged"
  i=0; while [[ ! -e "$R/adv-done" ]]; do i=$((i+1)); (( i<40000000 )) || break; done
  printf 'delay=%s rc=%s slices_left=%s elapsed_ms=%s state=%s held=%s\n  detail: %s\n' \
    "$d" "$rc" "$AFK_LOCK_PUBLISH_SLICES_LEFT" "$((t1-t0))" "$AFK_LOCK_OWNER_STATE" "$AFK_LOCK_HELD" "$AFK_LOCK_OWNER_DETAIL"
  printf '  D1 inode=%s  D2 inode=%s (different lock: %s)\n' \
    "$(cat "$R/d1id" 2>/dev/null)" "$(cat "$R/d2id" 2>/dev/null)" \
    "$([[ "$(cat "$R/d1id" 2>/dev/null)" != "$(cat "$R/d2id" 2>/dev/null)" ]] && echo yes || echo no)"
  printf '  D2 one instant later: %s (%s)\n' \
    "$(jq -r '"pid " + (.pid|tostring) + " inc " + .incarnation' "$L/owner.json" 2>/dev/null)" \
    "$(cat "$R/adv-done" 2>/dev/null)"
  : > "$R/stop"; wait $ADV 2>/dev/null
  [[ "$AFK_LOCK_HELD" != "true" ]] || { afk_lock_release || true; }
done
