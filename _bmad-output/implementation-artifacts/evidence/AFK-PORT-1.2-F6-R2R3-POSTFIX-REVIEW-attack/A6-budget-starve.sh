#!/usr/bin/env bash
# A6 (i) — the publication-wait budget is spent ACROSS an acquisition. Prove it
# can reach zero mid-acquisition without returning, and that a LIVE owner's
# publication window met afterwards is refused at once with remove-by-hand.
set -uo pipefail
KIT=/home/devbox/repos/jlengelbrecht/agent-flow-kit; CTL="$KIT/tests/lockctl-helper.sh"
kv(){ printf '%s\n' "$1"|awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,"");print;exit}'; }
R=$(mktemp -d); S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"
trap 'rm -rf "$R"' EXIT
. "$KIT/lib/afk-common.sh"; . "$KIT/lib/afk-source.sh"; . "$KIT/lib/afk-inventory.sh"
. "$KIT/lib/afk-commands.sh"; . "$KIT/lib/afk-plan.sh"; . "$KIT/lib/afk-mutate.sh"
AFK_STATE_DIR="$S"; AFK_LOCK_DIR="$L"

echo "### (a) the budget can reach 0 mid-acquisition and the loop still exits normally"
mkdir -p "$L"                       # ownerless: the publication window
AFK_LOCK_PUBLISH_SLICES_LEFT=3
( sleep 0.07; "$CTL" "$KIT" "$S" strand >/dev/null 2>&1 || true ) &   # a DEAD record lands
afk_lock_evaluate_settled
echo "    state=$AFK_LOCK_OWNER_STATE detail='$AFK_LOCK_OWNER_DETAIL' slices_left=$AFK_LOCK_PUBLISH_SLICES_LEFT"
wait 2>/dev/null; rm -rf "$L"

echo "### (b) a LIVE owner's publication window, met with the budget already spent"
READY="$R/ready"; PUB="$R/pub"; GO="$R/go"; OUT="$R/pubout"
( "$CTL" "$KIT" "$S" publish-slowly "$READY" "$PUB" "$GO" > "$OUT" ) & PP=$!
i=0; while [[ ! -e "$READY" ]]; do i=$((i+1)); (( i<40000000 )) || break; done
echo "    window open, lock exists=$([[ -d $L ]] && echo yes) record=$([[ -f $L/owner.json ]] && echo yes || echo no)"
AFK_LOCK_PUBLISH_SLICES_LEFT=0
t0=$(date +%s%3N); afk_lock_evaluate_settled; t1=$(date +%s%3N)
echo "    verdict: state=$AFK_LOCK_OWNER_STATE"
echo "    detail : $AFK_LOCK_OWNER_DETAIL"
echo "    elapsed_ms=$((t1-t0))  (a full budget would have waited ~2400 ms)"
echo "    -> afk_lock_acquire maps UNKNOWN to rc 3 => OPERATION_LOCK_OWNER_UNVERIFIABLE"
echo "    -> operator guidance: remove $L by hand"
: > "$PUB"; i=0; while [[ ! -f "$L/owner.json" ]]; do i=$((i+1)); (( i<40000000 )) || break; done
echo "    the same lock one instant later: $(jq -r '"pid " + (.pid|tostring) + " LIVE, inc " + .incarnation' "$L/owner.json" 2>/dev/null)"
: > "$GO"; wait $PP 2>/dev/null; cat "$OUT" | sed 's/^/    /'
