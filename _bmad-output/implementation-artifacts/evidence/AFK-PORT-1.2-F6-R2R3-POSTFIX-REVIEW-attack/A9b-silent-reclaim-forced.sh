#!/usr/bin/env bash
# A9b — force the reclaimer to lose the take it earned. It removes the
# abandoned lock (the one place the lifecycle removes another process's file)
# and then reports NOTHING, because AFK_LOCK_RECLAIMED is only set when the
# same process also wins the mkdir that follows.
set -uo pipefail
KIT=/home/devbox/repos/jlengelbrecht/agent-flow-kit; CTL="$KIT/tests/lockctl-helper.sh"
kv(){ printf '%s\n' "$1"|awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,"");print;exit}'; }
R=$(mktemp -d); S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"
trap 'rm -rf "$R"' EXIT
INC=$(kv "$("$CTL" "$KIT" "$S" strand)" inc)
echo "abandoned lock present: $([[ -f $L/owner.json ]] && echo yes), inc=$INC"
BIN="$R/bin"; mkdir -p "$BIN"
cat > "$BIN/jq" <<'SHIM'
#!/usr/bin/env bash
[[ "$X_REAL_JQ" != "${BASH_SOURCE[0]}" ]] || exit 97
if [[ "$*" == *"--arg schema"* ]]; then
  printf 'x\n' >> "$X_COUNT"
  # the SECOND owner-record build in a reclamation is afk_lock_take's, which
  # happens after the stale directory has already been renamed aside
  if [[ "$(wc -l < "$X_COUNT")" == "2" ]]; then
    mkdir -- "$X_LOCK" 2>/dev/null && printf 'stolen\n' > "$X_STOLE"
  fi
fi
exec "$X_REAL_JQ" "$@"
SHIM
chmod 755 "$BIN/jq"
export X_REAL_JQ="$(command -v jq)" X_COUNT="$R/count" X_LOCK="$L" X_STOLE="$R/stole"
: > "$R/count"
OUT="$( PATH="$BIN:$PATH" "$CTL" "$KIT" "$S" reclaim "$INC" )"
printf '%s\n' "$OUT" | sed 's/^/  /'
echo "  another contender took the lock path first: $(cat "$R/stole" 2>/dev/null || echo no)"
echo "  the abandoned incarnation's record is gone : $([[ -f $L/owner.json ]] && echo no || echo YES)"
echo "  stale residue left behind                  : $(find "$S" -maxdepth 1 -name 'lock.stale.*' | wc -l)"
echo "  --> the abandoned lock was removed; rc is 3 ('observe again'), so"
echo "      AFK_LOCK_RECLAIMED stays false and no OPERATION_LOCK_RECLAIMED is ever emitted."
