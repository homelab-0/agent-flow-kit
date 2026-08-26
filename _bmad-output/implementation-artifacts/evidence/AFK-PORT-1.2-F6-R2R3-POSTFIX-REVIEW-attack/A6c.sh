#!/usr/bin/env bash
# A6c — end to end, real afk_lock_acquire, no injected budget: an acquisition
# whose publication-wait budget was spent on an EARLIER lock refuses a LIVE
# process's publication window at once, with remove-by-hand guidance.
set -uo pipefail
KIT=/home/devbox/repos/jlengelbrecht/agent-flow-kit; CTL="$KIT/tests/lockctl-helper.sh"
R=$(mktemp -d); S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"
trap 'rm -rf "$R"' EXIT
. "$KIT/lib/afk-common.sh"; . "$KIT/lib/afk-source.sh"; . "$KIT/lib/afk-inventory.sh"
. "$KIT/lib/afk-commands.sh"; . "$KIT/lib/afk-plan.sh"; . "$KIT/lib/afk-mutate.sh"
AFK_STATE_DIR="$S"; AFK_LOCK_DIR="$L"
"$CTL" "$KIT" "$S" strand >/dev/null; cp "$L/owner.json" "$R/dead.json"; rm -rf "$L"

for d in "$@"; do
  rm -rf "$L" "$R/adv-done"
  # The adversary is a LIVE process that holds the lock directory throughout.
  ( mkdir -p "$L"
    sleep "$d"
    cp "$R/dead.json" "$L/.t" && mv "$L/.t" "$L/owner.json"   # a stale record lands
    sleep 0.05
    rm -f "$L/owner.json"                                     # and is taken away again
    # this process is now a live owner in its publication window
    i=0; while [[ ! -e "$R/judged" ]]; do i=$((i+1)); (( i<40000000 )) || break; done
    r="$(afk_lock_owner_record "$(afk_lock_incarnation_new)")"
    printf '%s\n' "$r" > "$L/.p" && mv "$L/.p" "$L/owner.json"
    printf 'live_owner_pid=%s\n' "$$" > "$R/adv-done"
    i=0; while [[ ! -e "$R/stop" ]]; do i=$((i+1)); (( i<40000000 )) || break; done ) &
  ADV=$!
  rm -f "$R/judged" "$R/stop"
  t0=$(date +%s%3N); rc=0; afk_lock_acquire || rc=$?; t1=$(date +%s%3N)
  : > "$R/judged"
  i=0; while [[ ! -e "$R/adv-done" ]]; do i=$((i+1)); (( i<40000000 )) || break; done
  printf 'delay=%s rc=%s slices_left=%s elapsed_ms=%s state=%s\n  detail: %s\n' \
    "$d" "$rc" "$AFK_LOCK_PUBLISH_SLICES_LEFT" "$((t1-t0))" "$AFK_LOCK_OWNER_STATE" "$AFK_LOCK_OWNER_DETAIL"
  printf '  the lock one instant later: %s (%s)\n' \
    "$(jq -r '"pid " + (.pid|tostring) + " inc " + .incarnation' "$L/owner.json" 2>/dev/null)" \
    "$(cat "$R/adv-done" 2>/dev/null)"
  : > "$R/stop"; wait $ADV 2>/dev/null
  [[ "$AFK_LOCK_HELD" != "true" ]] || { afk_lock_release || true; }
done
