#!/usr/bin/env bash
# A4c — the SAME hazard A4b targeted, moved onto the read the FIXED code
# actually performs. The judge now reads with `cat`, so the interposition is
# installed on `cat`: the release lands underneath the read, a REAL successor
# takes the freed path and publishes a REAL record into the same name, and
# only THEN is the judge allowed to reach its verdict.
# A pass = the acquisition never calls the successor's valid record damaged.
set -uo pipefail
KIT=/tmp/afk-r4r9-review-KUdQdf/trees/r4rev
CTL="${CTL_OVERRIDE:-$KIT/tests/lockctl-helper.sh}"
kv(){ printf '%s\n' "$1"|awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,"");print;exit}'; }
R=$(mktemp -d); S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"
trap 'rm -rf "$R"' EXIT
INC=$(kv "$("$CTL" "$KIT" "$S" strand)" inc)
echo "abandoned lock present: $([[ -f $L/owner.json ]] && echo yes || echo no)"
BIN="$R/bin"; mkdir -p "$BIN"
cat > "$BIN/jq" <<'SHIM'
#!/usr/bin/env bash
if [[ -n "${X_REC:-}" && "${*: -1}" == "$X_REC" && ! -e "$X_FLAG" ]]; then
  : > "$X_FLAG"
  # the lock this read was aimed at is RELEASED underneath the read
  mv -- "$X_LOCK" "$X_LOCK.handover" 2>/dev/null
  rm -rf -- "$X_LOCK.handover" 2>/dev/null
  # a REAL successor takes the freed path and publishes a REAL record
  "$X_CTL" "$X_KIT" "$X_STATE" park "$X_READY" "$X_GO" > "$X_PARK" &
  i=0; while [[ ! -e "$X_READY" ]]; do i=$((i+1)); (( i < 40000000 )) || break; done
  # the read of a record that has just been removed produces nothing
  exit 1
fi
exec "$X_REAL_JQ" "$@"
SHIM
chmod 755 "$BIN/jq"
export X_REAL_JQ="$(command -v jq)" X_REC="$L/owner.json" X_LOCK="$L" X_FLAG="$R/fired" \
       X_CTL="$CTL" X_KIT="$KIT" X_STATE="$S" X_READY="$R/ready" X_GO="$R/go" X_PARK="$R/park"
OUT="$( PATH="$BIN:$PATH" "$CTL" "$KIT" "$S" acquire )"
echo "--- victim acquisition ---"; printf '%s\n' "$OUT" | sed 's/^/    /'
echo "    hook fired: $([[ -e $R/fired ]] && echo YES || echo no-vacuous-pass)"
SPID=$(jq -r '.pid' "$L/owner.json" 2>/dev/null)
echo "    a LIVE successor holds the lock: pid=$SPID alive=$(kill -0 "$SPID" 2>/dev/null && echo yes || echo no)"
D=$(kv "$OUT" owner_detail); ST=$(kv "$OUT" owner_state)
echo "--- verdict ---"
if [[ "$D" == *"could not be parsed"* ]]; then
  echo "    FAIL: the successor's valid record was reported as damaged -> $D"
elif [[ "$ST" == "LIVE" ]]; then
  echo "    PASS: reported the LIVE successor ($D)"
else
  echo "    NOTE: state=$ST detail=$D"
fi
: > "$R/go"; wait 2>/dev/null
