#!/usr/bin/env bash
set -uo pipefail
KIT=/home/devbox/repos/jlengelbrecht/agent-flow-kit; CTL="$KIT/tests/lockctl-helper.sh"
kv() { printf '%s\n' "$1" | awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,"");print;exit}'; }
ms() { date +%s%3N; }
mk() { R=$(mktemp -d); S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"; }

echo "### A2.1 plain stale lock is still reclaimed"
mk; INC=$(kv "$("$CTL" "$KIT" "$S" strand)" inc)
t0=$(ms); O=$("$CTL" "$KIT" "$S" acquire); t1=$(ms)
echo "$O" | sed 's/^/    /'; echo "    elapsed_ms=$((t1-t0))"
echo "    lock_after=$([[ -e $L ]] && echo present || echo gone)  residue=$(find "$S" -maxdepth 1 -name 'lock.*' | wc -l)"
rm -rf "$R"

echo "### A2.2 stale lock + ABANDONED marker (dead reclaimer) still reclaimed"
mk; INC=$(kv "$("$CTL" "$KIT" "$S" strand)" inc)
"$CTL" "$KIT" "$S" strand-marker "$INC" >/dev/null   # separate process -> dead marker owner
t0=$(ms); O=$("$CTL" "$KIT" "$S" acquire); t1=$(ms)
echo "$O" | sed 's/^/    /'; echo "    elapsed_ms=$((t1-t0))"
rm -rf "$R"

echo "### A2.3 present-and-unparseable marker: refuse instantly, touch nothing"
mk; INC=$(kv "$("$CTL" "$KIT" "$S" strand)" inc)
printf 'not json\n' > "$L/reclaim.$INC.json"
B=$(find "$S" | sort | md5sum)
t0=$(ms); O=$("$CTL" "$KIT" "$S" acquire); t1=$(ms)
echo "$O" | sed 's/^/    /'; echo "    elapsed_ms=$((t1-t0))"
echo "    tree_unchanged=$([[ "$(find "$S" | sort | md5sum)" == "$B" ]] && echo yes || echo NO)"
rm -rf "$R"

echo "### A2.4 marker record with a FUTURE schema (present, unjudgeable)"
mk; INC=$(kv "$("$CTL" "$KIT" "$S" strand)" inc)
jq -nc '{lock_schema_version:"999.0",host_identity:"x",boot_identity:"y",pid:1,process_start_identity:"z",incarnation:"inc-1-0123456789abcdef",complete:true}' > "$L/reclaim.$INC.json"
t0=$(ms); O=$("$CTL" "$KIT" "$S" acquire); t1=$(ms)
echo "$O" | sed 's/^/    /'; echo "    elapsed_ms=$((t1-t0))"
rm -rf "$R"

echo "### A2.5 marker held by a LIVE reclaimer: wait, do not reclaim"
mk; INC=$(kv "$("$CTL" "$KIT" "$S" strand)" inc)
# a live process that owns a marker: emulate by writing a record naming THIS shell
"$CTL" "$KIT" "$S" record "$INC" >/dev/null 2>&1
bash -c 'sleep 5' & LIVEPID=$!
# build a marker record for the live pid using the library
( . "$KIT/lib/afk-common.sh"; . "$KIT/lib/afk-source.sh"; . "$KIT/lib/afk-inventory.sh"; . "$KIT/lib/afk-commands.sh"; . "$KIT/lib/afk-plan.sh"; . "$KIT/lib/afk-mutate.sh"
  AFK_STATE_DIR="$S"; AFK_LOCK_DIR="$L"
  i=$(afk_lock_incarnation_new); afk_lock_owner_record "$i" ) > "$L/reclaim.$INC.json"
t0=$(ms); O=$("$CTL" "$KIT" "$S" acquire); t1=$(ms)
echo "$O" | sed 's/^/    /'; echo "    elapsed_ms=$((t1-t0))"
kill $LIVEPID 2>/dev/null; rm -rf "$R"
