#!/usr/bin/env bash
# A4b — the read of the OLD record yields nothing (it was released), and a LIVE
# successor has published into the same name by the time the one stat that
# discriminates gone-from-unparseable runs.
set -uo pipefail
KIT="${1:-/home/devbox/repos/jlengelbrecht/agent-flow-kit}"; CTL="$KIT/tests/lockctl-helper.sh"
kv() { printf '%s\n' "$1" | awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,"");print;exit}'; }
R=$(mktemp -d); S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"
trap 'rm -rf "$R"' EXIT
INC=$(kv "$("$CTL" "$KIT" "$S" strand)" inc)
BIN="$R/bin"; mkdir -p "$BIN"
cat > "$BIN/jq" <<'SHIM'
#!/usr/bin/env bash
if [[ -n "${X_REC:-}" && "${*: -1}" == "$X_REC" && ! -e "$X_FLAG" ]]; then
  : > "$X_FLAG"
  mv -- "$X_LOCK" "$X_LOCK.handover" 2>/dev/null
  rm -rf -- "$X_LOCK.handover" 2>/dev/null
  "$X_CTL" "$X_KIT" "$X_STATE" park "$X_READY" "$X_GO" > "$X_PARK" &
  i=0; while [[ ! -e "$X_READY" ]]; do i=$((i+1)); (( i < 40000000 )) || break; done
  # The read of the record that was there a moment ago produces nothing --
  # exactly what the real jq prints for a file that has just been removed.
  exit 5
fi
exec "$X_REAL_JQ" "$@"
SHIM
chmod 755 "$BIN/jq"
export X_REAL_JQ="$(command -v jq)" X_REC="$L/owner.json" X_LOCK="$L" X_FLAG="$R/fired" \
       X_CTL="$CTL" X_KIT="$KIT" X_STATE="$S" X_READY="$R/ready" X_GO="$R/go" X_PARK="$R/park"
OUT="$( PATH="$BIN:$PATH" "$CTL" "$KIT" "$S" acquire )"
echo "--- victim acquisition ---"; printf '%s\n' "$OUT" | sed 's/^/    /'
SPID=$(jq -r '.pid' "$L/owner.json" 2>/dev/null)
echo "    a LIVE successor holds the lock: pid=$SPID alive=$(kill -0 "$SPID" 2>/dev/null && echo yes || echo no)"
echo "--- what an operator would be told (afk_lock_refusal for that rc) ---"
( . "$KIT/lib/afk-common.sh"; . "$KIT/lib/afk-source.sh"; . "$KIT/lib/afk-inventory.sh"; . "$KIT/lib/afk-commands.sh"
  AFK_LOCK_DIR="$L"; AFK_LOCK_OWNER_DETAIL="$(kv "$OUT" owner_detail)"
  afk_next_action_for "OPERATION_LOCK_OWNER_UNVERIFIABLE" 2>/dev/null || \
  grep -n 'remove the reported lock directory by hand' "$KIT/lib/afk-common.sh" ) | sed 's/^/    /'
: > "$R/go"; wait 2>/dev/null
