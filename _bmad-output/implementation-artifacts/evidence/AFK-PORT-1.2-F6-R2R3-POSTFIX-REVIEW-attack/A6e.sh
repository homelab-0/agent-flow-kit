#!/usr/bin/env bash
set -uo pipefail
KIT=/home/devbox/repos/jlengelbrecht/agent-flow-kit
R=$(mktemp -d); S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"
trap 'rm -rf "$R"' EXIT
. "$KIT/lib/afk-common.sh"; . "$KIT/lib/afk-source.sh"; . "$KIT/lib/afk-inventory.sh"
. "$KIT/lib/afk-commands.sh"; . "$KIT/lib/afk-plan.sh"; . "$KIT/lib/afk-mutate.sh"
AFK_STATE_DIR="$S"; AFK_LOCK_DIR="$L"
hit=0
for d in "$@"; do
  rm -rf "$L" "$R"/adv-done "$R"/judged "$R"/stop "$R"/d2id
  ( mkdir -p "$L"
    REC="$(afk_lock_owner_record "$(afk_lock_incarnation_new)")"
    sleep "$d"
    mv -- "$L" "$L.gone"; rm -rf -- "$L.gone" & sleep 0.006; mkdir -- "$L"; stat -c %i "$L" > "$R/d2id"
    i=0; while [[ ! -e "$R/judged" ]]; do i=$((i+1)); (( i<40000000 )) || break; done
    printf '%s\n' "$REC" > "$L/.p" && mv "$L/.p" "$L/owner.json"
    printf 'live_owner_pid=%s\n' "$$" > "$R/adv-done"
    i=0; while [[ ! -e "$R/stop" ]]; do i=$((i+1)); (( i<40000000 )) || break; done ) &
  ADV=$!
  t0=$(date +%s%3N); rc=0; afk_lock_acquire || rc=$?; t1=$(date +%s%3N)
  : > "$R/judged"; i=0; while [[ ! -e "$R/adv-done" ]]; do i=$((i+1)); (( i<40000000 )) || break; done
  el=$((t1-t0))
  # A refusal that came in well UNDER the full-budget cost is one that did not wait.
  mark=""
  if (( rc == 3 )) && (( el < 3200 )) && [[ "$AFK_LOCK_OWNER_DETAIL" == *"none appeared"* ]]; then mark=" <== REFUSED WITHOUT WAITING"; hit=$((hit+1)); fi
  printf 'delay=%s rc=%s left=%s ms=%s held=%s detail=%s%s\n' "$d" "$rc" "$AFK_LOCK_PUBLISH_SLICES_LEFT" "$el" "$AFK_LOCK_HELD" "$AFK_LOCK_OWNER_DETAIL" "$mark"
  [[ -z "$mark" ]] || printf '   the lock it refused, one instant later: %s (%s)\n' \
      "$(jq -r '"pid " + (.pid|tostring) + " inc " + .incarnation' "$L/owner.json" 2>/dev/null)" "$(cat "$R/adv-done")"
  : > "$R/stop"; wait $ADV 2>/dev/null
  [[ "$AFK_LOCK_HELD" != "true" ]] || { afk_lock_release || true; }
done
echo "hits=$hit"
