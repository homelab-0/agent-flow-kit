#!/usr/bin/env bash
set -uo pipefail
KIT="$1"; ROOT="$2"; LC="$KIT/tests/lockctl-helper.sh"
rm -rf "$ROOT"; mkdir -p "$ROOT"; ST="$ROOT/st"; mkdir -p "$ST"
one(){ tr '\n' ' '; echo; }
INC=$(bash "$LC" "$KIT" "$ST" incarnation | sed 's/^inc=//')
REC=$(bash "$LC" "$KIT" "$ST" record "$INC" | head -1)     # a genuine, complete record
echo "base_record_ok=$(printf '%s' "$REC" | jq -e '.complete' >/dev/null 2>&1 && echo yes || echo no)"
put(){ rm -rf "$ST/lock"; mkdir -p "$ST/lock"; printf '%s\n' "$1" > "$ST/lock/owner.json"; }
put "$(printf '%s' "$REC" | jq -c '.pid=1 | .process_start_identity="not-the-one-pid-1-has"')"
echo -n "  pid-reuse shape (real pid 1, wrong start id): "; bash "$LC" "$KIT" "$ST" judge | one
put "$(printf '%s' "$REC" | jq -c '.boot_identity="an-earlier-boot"')"
echo -n "  boot mismatch:                                "; bash "$LC" "$KIT" "$ST" judge | one
echo -n "  boot mismatch acquire:                        "; bash "$LC" "$KIT" "$ST" acquire | one
put "$(printf '%s' "$REC" | jq -c '.host_identity="some-other-host"')"
echo -n "  host mismatch:                                "; bash "$LC" "$KIT" "$ST" judge | one
echo -n "  host mismatch acquire:                        "; bash "$LC" "$KIT" "$ST" acquire | one
echo "  foreign lock still present=$([[ -d "$ST/lock" ]] && echo yes || echo no) record_untouched=$(diff <(printf '%s' "$REC" | jq -c '.host_identity="some-other-host"') <(jq -c . "$ST/lock/owner.json") >/dev/null && echo yes || echo no)"
# identity change BETWEEN observation and action
echo "== identity moves between observe and reclaim =="
rm -rf "$ST"; mkdir -p "$ST"
bash "$LC" "$KIT" "$ST" strand >/dev/null 2>&1
OBS="$ROOT/obs"; GO="$ROOT/go"
bash "$LC" "$KIT" "$ST" observe-then-reclaim "$OBS" "$GO" > "$ROOT/otr" 2>&1 & O=$!
i=0; while [[ ! -e "$OBS" ]]; do i=$((i+1)); (( i<40000000 )) || break; done
echo "  observed: $(tr '\n' ' ' < "$OBS")"
rm -rf "$ST/lock"; bash "$LC" "$KIT" "$ST" strand >/dev/null 2>&1     # lock changes identity underneath
SUCC=$(jq -r .incarnation "$ST/lock/owner.json"); echo "  successor_inc=${SUCC:0:22}"
: > "$GO"; wait "$O"
echo "  observer result: $(tr '\n' ' ' < "$ROOT/otr")"
echo "  successor untouched=$([[ "$(jq -r .incarnation "$ST/lock/owner.json" 2>/dev/null)" == "$SUCC" ]] && echo yes || echo no)"
echo "  residue=[$(ls -A "$ST" | tr '\n' ' ')]"
