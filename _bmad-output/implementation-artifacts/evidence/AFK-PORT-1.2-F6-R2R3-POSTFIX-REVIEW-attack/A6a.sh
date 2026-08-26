#!/usr/bin/env bash
set -uo pipefail
KIT=/home/devbox/repos/jlengelbrecht/agent-flow-kit; CTL="$KIT/tests/lockctl-helper.sh"
kv(){ printf '%s\n' "$1"|awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,"");print;exit}'; }
R=$(mktemp -d); S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"
trap 'rm -rf "$R"' EXIT
. "$KIT/lib/afk-common.sh"; . "$KIT/lib/afk-source.sh"; . "$KIT/lib/afk-inventory.sh"
. "$KIT/lib/afk-commands.sh"; . "$KIT/lib/afk-plan.sh"; . "$KIT/lib/afk-mutate.sh"
AFK_STATE_DIR="$S"; AFK_LOCK_DIR="$L"
# a real DEAD owner record, prepared in advance
"$CTL" "$KIT" "$S" strand >/dev/null; cp "$L/owner.json" "$R/dead.json"; rm -rf "$L"
for d in 0.040 0.045 0.050 0.055 0.060 0.065; do
  rm -rf "$L"; mkdir -p "$L"
  AFK_LOCK_PUBLISH_SLICES_LEFT=3
  ( sleep "$d"; cp "$R/dead.json" "$L/.t" 2>/dev/null && mv "$L/.t" "$L/owner.json" 2>/dev/null ) &
  afk_lock_evaluate_settled; wait 2>/dev/null
  printf 'delay=%s -> state=%-8s slices_left=%s detail=%s\n' \
    "$d" "$AFK_LOCK_OWNER_STATE" "$AFK_LOCK_PUBLISH_SLICES_LEFT" "$AFK_LOCK_OWNER_DETAIL"
done
