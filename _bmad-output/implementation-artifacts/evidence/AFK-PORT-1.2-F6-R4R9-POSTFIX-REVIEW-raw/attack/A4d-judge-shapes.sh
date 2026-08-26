#!/usr/bin/env bash
# A4d — every shape a record path can take, judged by the FIXED single-read
# judge, plus what a whole acquisition then does with it (and how much of the
# publication-wait budget it spends).
set -uo pipefail
KIT=/home/devbox/repos/jlengelbrecht/agent-flow-kit; CTL="$1"
kv(){ printf '%s\n' "$1"|awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,"");print;exit}'; }
probe() { # <label> <setup-fn>
  local label="$1" setup="$2"
  R=$(mktemp -d); S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"
  "$setup"
  V=$(kv "$("$CTL" "$KIT" "$S" rjudge "$L/owner.json")" verdict)
  A=$("$CTL" "$KIT" "$S" racquire)
  printf '%-28s judge=%-58s acq_rc=%s state=%s waits=%s\n' \
    "$label" "$V" "$(kv "$A" rc)" "$(kv "$A" owner_state)" "$(kv "$A" publish_waits)"
  printf '%-28s acq_detail=%s\n' "" "$(kv "$A" owner_detail)"
  rm -rf "$R"
}
s_absent()   { mkdir -p "$L"; }
s_empty()    { mkdir -p "$L"; : > "$L/owner.json"; }
s_garbage()  { mkdir -p "$L"; printf 'this is not json at all\n' > "$L/owner.json"; }
s_trunc()    { mkdir -p "$L"; "$CTL" "$KIT" "$S" record inc-1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2>/dev/null | head -c 60 > "$L/owner.json"; }
s_ws()       { mkdir -p "$L"; printf '   \n\n  \n' > "$L/owner.json"; }
s_null()     { mkdir -p "$L"; printf 'null\n' > "$L/owner.json"; }
s_array()    { mkdir -p "$L"; printf '[1,2,3]\n' > "$L/owner.json"; }
s_dir()      { mkdir -p "$L/owner.json"; }
s_fifo()     { mkdir -p "$L"; mkfifo "$L/owner.json"; }
s_symlink()  { mkdir -p "$L"; ln -s /etc/hostname "$L/owner.json"; }
s_dangling() { mkdir -p "$L"; ln -s "$L/nope.json" "$L/owner.json"; }
s_unread()   { mkdir -p "$L"; printf '{}\n' > "$L/owner.json"; chmod 000 "$L/owner.json"; }
for p in absent empty garbage trunc ws null array dir fifo symlink dangling unread; do
  probe "$p" "s_$p"
done
