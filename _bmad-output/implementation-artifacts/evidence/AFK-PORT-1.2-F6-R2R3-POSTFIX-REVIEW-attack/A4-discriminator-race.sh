#!/usr/bin/env bash
# A4 — race the F6-R3 discriminator: release the record mid-read AND let a
# LIVE successor publish before the one stat that decides gone-vs-unparseable.
set -uo pipefail
KIT="${1:-/home/devbox/repos/jlengelbrecht/agent-flow-kit}"; CTL="$KIT/tests/lockctl-helper.sh"
kv() { printf '%s\n' "$1" | awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,"");print;exit}'; }
R=$(mktemp -d); S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"
trap 'rm -rf "$R"' EXIT
INC=$(kv "$("$CTL" "$KIT" "$S" strand)" inc)
echo "stranded (DEAD) inc=$INC"

BIN="$R/bin"; mkdir -p "$BIN"
cat > "$BIN/jq" <<'SHIM'
#!/usr/bin/env bash
if [[ -n "${X_REC:-}" && "${*: -1}" == "$X_REC" && ! -e "$X_FLAG" ]]; then
  : > "$X_FLAG"
  # the release lands: the record and its directory go away
  mv -- "$X_LOCK" "$X_LOCK.handover" 2>/dev/null
  rm -rf -- "$X_LOCK.handover" 2>/dev/null
  # and a LIVE successor publishes into the same name BEFORE the discriminator
  "$X_CTL" "$X_KIT" "$X_STATE" park "$X_READY" "$X_GO" > "$X_PARK" &
  i=0; while [[ ! -e "$X_READY" ]]; do i=$((i+1)); (( i < 40000000 )) || break; done
fi
exec "$X_REAL_JQ" "$@"
SHIM
chmod 755 "$BIN/jq"
export X_REAL_JQ="$(command -v jq)" X_REC="$L/owner.json" X_LOCK="$L" X_FLAG="$R/fired" \
       X_CTL="$CTL" X_KIT="$KIT" X_STATE="$S" X_READY="$R/ready" X_GO="$R/go" X_PARK="$R/park"

OUT="$( PATH="$BIN:$PATH" "$CTL" "$KIT" "$S" acquire )"
echo "--- victim acquisition ---"; printf '%s\n' "$OUT" | sed 's/^/    /'
echo "    successor holds lock: $([[ -e "$L/owner.json" ]] && echo yes || echo no)"
echo "    successor inc on disk: $(jq -r '.incarnation' "$L/owner.json" 2>/dev/null)"
echo "    successor pid alive:  $(jq -r '.pid' "$L/owner.json" 2>/dev/null | xargs -I{} sh -c 'kill -0 {} 2>/dev/null && echo yes || echo no')"
: > "$R/go"; wait 2>/dev/null
echo "--- successor ---"; cat "$R/park" 2>/dev/null | sed 's/^/    /'
