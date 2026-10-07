#!/usr/bin/env bash
# lifecycle-concurrency-tests.sh — the isolated deterministic gate for the
# OPERATION LOCK under real concurrency.
#
# The other two lifecycle gates prove what a single process does. This one
# proves what several processes do to each other, because the lock's whole
# job is a property no single-process test can falsify: at most one owner.
#
# Every contention scenario runs REAL separate processes, released together by
# a barrier rather than by hope, against a throwaway state directory under
# mktemp. Nothing here touches the developer's HOME, the router, a provider
# session or Orca.
#
# Layers:
#   PROTOCOL  — the lock primitives are driven directly through
#               tests/lockctl-helper.sh, one process per participant, so the
#               observation/reclamation and hold/release boundaries can be
#               interleaved deliberately instead of waited for.
#   RECORD    — owner records are judged as data: a record missing a field, in
#               an unknown schema, or naming an incarnation this kit would
#               never write must fail closed rather than be interpreted.
#
# Usage: tests/lifecycle-concurrency-tests.sh
# Exit:  0 all passed, 1 any failure.

set -uo pipefail

KIT_ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
LOCKCTL="$KIT_ROOT/tests/lockctl-helper.sh"

TMPROOT="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"' EXIT

PASS=0 FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  {
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  if [[ -n "${2:-}" ]]; then printf '        %s\n' "$2"; fi
  FAIL=$((FAIL + 1))
}
head1() { printf '\n\033[1m%s\033[0m\n' "$1"; }

assert_eq()       { if [[ "$2" == "$3"   ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
assert_ne()       { if [[ "$2" != "$3"   ]]; then ok "$1"; else bad "$1" "should not equal '$3'"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing substring: $3"; fi; }
assert_no_file()  { if [[ -e "$2" ]]; then bad "$1" "exists: $2"; else ok "$1"; fi; }
assert_file()     { if [[ -e "$2" ]]; then ok "$1"; else bad "$1" "missing: $2"; fi; }

# ===========================================================================
# fixtures
# ===========================================================================

SCN=0
new_state() { # -> a fresh, empty state directory; sets STATE and LOCK
  SCN=$((SCN + 1))
  STATE="$TMPROOT/state-$SCN"
  LOCK="$STATE/lock"
  mkdir -p "$STATE"
  chmod 700 "$STATE"
}

ctl() { bash "$LOCKCTL" "$KIT_ROOT" "$STATE" "$@" 2>/dev/null; }

# `key=value` out of a helper's output.
kv() { printf '%s\n' "$1" | awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }'; }

lock_field() { jq -r "$1 // \"\"" "$LOCK/owner.json" 2>/dev/null; }

# Anything a reclamation or a release should have taken with it. Named by glob
# rather than by listing, so a name with a newline in it cannot hide.
lock_residue() {
  local p acc="" pat
  for pat in "$STATE"/lock.stale.* "$STATE"/lock.released.* "$STATE"/.afk-reclaim.* \
             "$STATE"/.afk-take.*; do
    [[ -e "$pat" ]] || continue
    p="$(basename -- "$pat")"
    acc="$acc $p"
  done
  printf '%s' "${acc# }"
}

# Everything the lock path is: the names under it and the bytes of its record.
# Used to assert that a refusal removed nothing on the way to refusing.
lock_snapshot() {
  find "$LOCK" 2>/dev/null | LC_ALL=C sort
  cat "$LOCK/owner.json" 2>/dev/null
}

# A lock held by a process that no longer exists, carrying a complete record
# the library itself wrote. This is the abandoned lock every reclamation test
# starts from — never a hand-rolled JSON blob, so a fixture cannot drift from
# the record the lock actually writes.
strand_lock() { # -> STRANDED_INC
  local out
  out="$(ctl strand)"
  STRANDED_INC="$(kv "$out" inc)"
  [[ -n "$STRANDED_INC" ]] || bad "fixture: a lock could be stranded" "$out"
}

# Rewrite one field of the stranded owner record, so a record that is complete
# in every other way can be judged on exactly one difference.
patch_owner() { # <jq filter>
  jq -c "$1" "$LOCK/owner.json" > "$LOCK/owner.json.x" && mv "$LOCK/owner.json.x" "$LOCK/owner.json"
}

# Wait for a process this shell did not start -- the fixture's successor is a
# grandchild, so `wait` says nothing about it. `kill -0` is a builtin, so this
# costs no forks.
spin_for_exit() { # <pid>
  local i=0
  [[ -n "$1" ]] || return 1
  while kill -0 "$1" 2>/dev/null; do
    i=$((i + 1))
    (( i < 60000000 )) || return 1
  done
  return 0
}

# Release N helper processes at the same instant. Children announce themselves
# in <bar>/ready.<id> and spin on <bar>/go; the barrier is a real rendezvous,
# not a sleep long enough to look like one.
barrier_wait_ready() { # <bar> <n>
  local bar="$1" n="$2" i=0 have
  while :; do
    have="$(find "$bar" -mindepth 1 -maxdepth 1 -name 'ready.*' | wc -l)"
    (( have >= n )) && return 0
    i=$((i + 1))
    (( i < 60000000 )) || return 1
  done
}

# ===========================================================================
head1 "1. PROTOCOL — at most one owner, under a barrier"
# ===========================================================================
# The failure this pins: two processes that both observe the same abandoned
# lock and both act on that observation. Every one of them is released at the
# same instant and publishes itself as an owner while it holds the lock; the
# peak number of owners published at once is the whole assertion.

new_state
strand_lock
BAR="$TMPROOT/bar-1"; OWNERS="$TMPROOT/owners-1"
mkdir -p "$BAR" "$OWNERS"
N=2
OUTDIR="$TMPROOT/out-1"; mkdir -p "$OUTDIR"
for i in $(seq 1 "$N"); do
  ( ctl contend "$BAR" "$OWNERS" "$i" > "$OUTDIR/$i" ) &
done
if barrier_wait_ready "$BAR" "$N"; then : > "$BAR/go"; else bad "two contenders reached the barrier" "timed out"; fi
wait

ACQUIRED=0; RECLAIMED=0; PEAK=0
for i in $(seq 1 "$N"); do
  o="$(cat "$OUTDIR/$i")"
  [[ "$(kv "$o" rc)" == "0" ]] && ACQUIRED=$((ACQUIRED + 1))
  [[ "$(kv "$o" reclaimed)" == "true" ]] && RECLAIMED=$((RECLAIMED + 1))
  p="$(kv "$o" peak)"; [[ -n "$p" ]] && (( p > PEAK )) && PEAK="$p"
done
assert_eq "two contenders on one abandoned lock: exactly one acquires" "$ACQUIRED" "1"
assert_eq "and exactly one reports the reclamation"                    "$RECLAIMED" "1"
assert_eq "and never more than one owner exists at a time"             "$PEAK" "1"
assert_no_file "the lock is gone once the winner released it"          "$LOCK"
assert_eq "the winner released the incarnation it installed" \
  "$(for i in $(seq 1 "$N"); do kv "$(cat "$OUTDIR/$i")" released; done | grep -c '^true$')" "1"

# The same property with a crowd rather than a pair. Neither a lock caught
# mid-publication nor a marker caught mid-handover is a way a loser may refuse
# any more — sections 10 and 11 pin those deliberately, and a crowd released
# from one barrier cannot construct either reliably enough to pin anything. So
# the refusal set stays permissive here on purpose: the count of owners is the
# invariant this scenario exists to assert, and it is one.
new_state
strand_lock
BAR="$TMPROOT/bar-2"; OWNERS="$TMPROOT/owners-2"
mkdir -p "$BAR" "$OWNERS"
N=8
OUTDIR="$TMPROOT/out-2"; mkdir -p "$OUTDIR"
for i in $(seq 1 "$N"); do
  ( ctl contend "$BAR" "$OWNERS" "$i" > "$OUTDIR/$i" ) &
done
if barrier_wait_ready "$BAR" "$N"; then : > "$BAR/go"; else bad "eight contenders reached the barrier" "timed out"; fi
wait

ACQUIRED=0; RECLAIMED=0; PEAK=0; BADRC=""
for i in $(seq 1 "$N"); do
  o="$(cat "$OUTDIR/$i")"
  r="$(kv "$o" rc)"
  [[ "$r" == "0" ]] && ACQUIRED=$((ACQUIRED + 1))
  case "$r" in 0|1|3) : ;; *) BADRC="$BADRC $i:$r" ;; esac
  [[ "$(kv "$o" reclaimed)" == "true" ]] && RECLAIMED=$((RECLAIMED + 1))
  p="$(kv "$o" peak)"; [[ -n "$p" ]] && (( p > PEAK )) && PEAK="$p"
done
assert_eq "eight contenders: never more than one owner at a time" "$PEAK" "1"
assert_eq "and at most one reclamation of the one abandoned lock" \
  "$(( RECLAIMED > 1 ? 1 : 0 ))" "0"
assert_eq "every loser refused for a reason the lock has a name for" "$BADRC" ""
assert_eq "and the crowd did not leave the lock unacquirable" \
  "$(( ACQUIRED >= 1 ? 1 : 0 ))" "1"
assert_eq "no reclamation residue survives the crowd" "$(lock_residue)" ""

# ===========================================================================
head1 "2. PROTOCOL — a stale observation never grants ownership"
# ===========================================================================
# The reported failure: a process observed a lock, judged it abandoned, and
# then removed whatever the lock path named at the moment it got around to it.
# Between those two moments the lock can have been reclaimed by someone else
# and be held, live, by a successor. Here that interleaving is forced rather
# than raced for: the observer is stopped at exactly that boundary.

new_state
strand_lock
STALE_A="$STRANDED_INC"
OBSERVED="$TMPROOT/observed-3"; GO="$TMPROOT/go-3"
OBS_OUT="$TMPROOT/obs-3"
( ctl observe-then-reclaim "$OBSERVED" "$GO" > "$OBS_OUT" ) &
OBS_PID=$!
# Wait for the observation to be on record, and not one instruction longer.
i=0; while [[ ! -e "$OBSERVED" ]]; do i=$((i + 1)); (( i < 60000000 )) || break; done
OBS="$(cat "$OBSERVED" 2>/dev/null)"
assert_eq "the observer judged the abandoned lock abandoned" "$(kv "$OBS" state)" "DEAD"
assert_eq "and recorded the exact incarnation it judged"     "$(kv "$OBS" inc)" "$STALE_A"

# With the observer stopped at the boundary, a successor takes the lock and
# stays alive holding it.
READY="$TMPROOT/ready-3"; LETGO="$TMPROOT/letgo-3"
PARK_OUT="$TMPROOT/park-3"
( ctl park "$READY" "$LETGO" > "$PARK_OUT" ) &
PARK_PID=$!
i=0; while [[ ! -e "$READY" ]]; do i=$((i + 1)); (( i < 60000000 )) || break; done
SUCC_INC="$(lock_field '.incarnation')"
assert_ne "a successor holds the lock now"          "$SUCC_INC" ""
assert_ne "and it is not the incarnation observed"  "$SUCC_INC" "$STALE_A"

# Now let the observer act on its stale observation.
: > "$GO"
wait "$OBS_PID"
OBS_RESULT="$(cat "$OBS_OUT")"
assert_ne "acting on the stale observation does not acquire" "$(kv "$OBS_RESULT" rc)" "0"
assert_eq "and leaves the successor's lock exactly where it was" \
  "$(kv "$OBS_RESULT" lock_inc_after)" "$SUCC_INC"
assert_eq "the successor still holds the lock on disk" "$(lock_field '.incarnation')" "$SUCC_INC"

: > "$LETGO"
wait "$PARK_PID"
PARK_RESULT="$(cat "$PARK_OUT")"
assert_eq "and the successor's own release still succeeds" "$(kv "$PARK_RESULT" released)" "true"
assert_eq "leaving no lock behind"                         "$(kv "$PARK_RESULT" lock_after)" "NONE"
assert_no_file "and no reclamation residue"                "$LOCK"

# Reclaiming the same stale incarnation twice is idempotent: the second attempt
# is a refusal, not a second removal.
new_state
strand_lock
FIRST="$(ctl reclaim "$STRANDED_INC")"
assert_eq "the first reclamation of an abandoned lock succeeds" "$(kv "$FIRST" rc)" "0"
SECOND_TARGET="$(lock_field '.incarnation')"
assert_ne "and installs a different incarnation" "$SECOND_TARGET" "$STRANDED_INC"
SECOND="$(ctl reclaim "$STRANDED_INC")"
assert_ne "reclaiming the same incarnation again does not acquire" "$(kv "$SECOND" rc)" "0"
assert_eq "and does not disturb what is there now" \
  "$(kv "$SECOND" lock_inc_after)" "$SECOND_TARGET"
assert_eq "the lock on disk is untouched" "$(lock_field '.incarnation')" "$SECOND_TARGET"

# ===========================================================================
head1 "3. PROTOCOL — a former owner releases only what it installed"
# ===========================================================================
# The reported failure: release removed the lock DIRECTORY on the strength of
# a boolean, so a process whose lock had been reclaimed underneath it deleted
# the live lock of whoever came next.

new_state
strand_lock
FORMER_INC="$STRANDED_INC"
RECL="$(ctl reclaim "$FORMER_INC")"
assert_eq "the abandoned lock is reclaimed by a successor" "$(kv "$RECL" rc)" "0"
SUCCESSOR_INC="$(lock_field '.incarnation')"
assert_ne "and the successor's incarnation is its own" "$SUCCESSOR_INC" "$FORMER_INC"

REL="$(ctl release-as "$FORMER_INC")"
assert_ne "the former owner's release does not report success" "$(kv "$REL" released)" "true"
assert_eq "and removes nothing"        "$(kv "$REL" lock_inc_after)" "$SUCCESSOR_INC"
assert_file "the successor's lock survives its predecessor's release" "$LOCK/owner.json"
assert_eq "byte for byte the same owner" "$(lock_field '.incarnation')" "$SUCCESSOR_INC"

# A release quoting an incarnation this kit would never have written is refused
# before it can name a directory.
REL_BOGUS="$(ctl release-as '../../../etc')"
assert_ne "a release quoting a malformed incarnation reports success" \
  "$(kv "$REL_BOGUS" released)" "true"
assert_file "and removes nothing" "$LOCK/owner.json"

# The owner of record releases its own incarnation and only then is the lock
# gone.
REL_OK="$(ctl release-as "$SUCCESSOR_INC")"
assert_eq "the exact incarnation on disk releases"  "$(kv "$REL_OK" released)" "true"
assert_no_file "and the lock is gone"               "$LOCK"

# ===========================================================================
head1 "4. PROTOCOL — an owner that is alive is never reclaimed"
# ===========================================================================

new_state
READY="$TMPROOT/ready-4"; LETGO="$TMPROOT/letgo-4"
PARK_OUT="$TMPROOT/park-4"
( ctl park "$READY" "$LETGO" > "$PARK_OUT" ) &
PARK_PID=$!
i=0; while [[ ! -e "$READY" ]]; do i=$((i + 1)); (( i < 60000000 )) || break; done
LIVE_INC="$(lock_field '.incarnation')"
assert_ne "a live owner holds the lock" "$LIVE_INC" ""

JUDGE="$(ctl judge)"
assert_eq "a second process judges that owner alive"      "$(kv "$JUDGE" state)" "LIVE"
ACQ="$(ctl acquire)"
assert_eq "and refuses rather than reclaiming"            "$(kv "$ACQ" rc)" "1"
assert_eq "reporting no reclamation"                      "$(kv "$ACQ" reclaimed)" "false"
FORCED="$(ctl reclaim "$LIVE_INC")"
assert_ne "a reclamation aimed straight at a live owner does not acquire" \
  "$(kv "$FORCED" rc)" "0"
assert_eq "and the live owner is still on disk" "$(lock_field '.incarnation')" "$LIVE_INC"

: > "$LETGO"
wait "$PARK_PID"
assert_eq "the live owner released normally" "$(kv "$(cat "$PARK_OUT")" released)" "true"
assert_no_file "and the lock is gone"        "$LOCK"

# ===========================================================================
head1 "5. RECORD — a pid that was recycled is not its own former owner"
# ===========================================================================
# The four identity facts exist so that a pid answering today is not mistaken
# for the pid that took the lock. A record naming a pid that IS running, with a
# start identity that is not that process's, is a recycled pid: dead owner,
# reclaimable, and never LIVE.

new_state
strand_lock
patch_owner ".pid = $$ | .process_start_identity = \"starttime:1\""
JUDGE="$(ctl judge)"
assert_eq "a live pid with a different start identity is not the owner" \
  "$(kv "$JUDGE" state)" "DEAD"
assert_contains "and the diagnosis says so" "$(kv "$JUDGE" detail)" "different process"
ACQ="$(ctl acquire)"
assert_eq "so the lock is reclaimable"       "$(kv "$ACQ" rc)" "0"
assert_eq "and the reclamation is reported"  "$(kv "$ACQ" reclaimed)" "true"

# The same pid WITH its own start identity is the owner, and blocks.
new_state
READY="$TMPROOT/ready-5"; LETGO="$TMPROOT/letgo-5"
( ctl park "$READY" "$LETGO" > "$TMPROOT/park-5" ) &
PARK_PID=$!
i=0; while [[ ! -e "$READY" ]]; do i=$((i + 1)); (( i < 60000000 )) || break; done
assert_eq "an exact pid AND start identity match is a live owner" \
  "$(kv "$(ctl judge)" state)" "LIVE"
: > "$LETGO"; wait "$PARK_PID"

# ===========================================================================
head1 "6. RECORD — a reboot is decidable, another host is not"
# ===========================================================================

new_state
strand_lock
patch_owner '.boot_identity = "boot-id:00000000-0000-0000-0000-000000000000"'
JUDGE="$(ctl judge)"
assert_eq "a lock from an earlier boot of this host is abandoned" "$(kv "$JUDGE" state)" "DEAD"
assert_contains "with the reboot named as the reason" "$(kv "$JUDGE" detail)" "before this host booted"
assert_eq "so it is reclaimed rather than waited on" "$(kv "$(ctl acquire)" rc)" "0"

new_state
strand_lock
patch_owner '.host_identity = "some-other-machine/0123456789abcdef"'
JUDGE="$(ctl judge)"
assert_eq "a lock taken on another host is foreign"  "$(kv "$JUDGE" state)" "FOREIGN"
ACQ="$(ctl acquire)"
assert_eq "and fails closed rather than reclaiming"  "$(kv "$ACQ" rc)" "3"
assert_file "leaving the foreign lock exactly where it was" "$LOCK/owner.json"
assert_eq "with its record unchanged" "$(lock_field '.host_identity')" "some-other-machine/0123456789abcdef"

# ===========================================================================
head1 "7. RECORD — missing, partial or unreadable metadata fails closed"
# ===========================================================================
# Every one of these is a lock this host must refuse to judge. None of them may
# be reclaimed, and none of them may be removed on the way to refusing.

# <waited> is whether this lock is one the acquisition may spend its
# publication-wait budget on. Only a lock carrying NO record can be a lock
# mid-publication; every other unjudgeable record is a diagnosis, and paying
# latency for it would be a regression dressed up as caution.
fail_closed_case() { # <name> <jq patch|EMPTYDIR|GARBAGE|NOTADIR> <waited yes|no>
  local name="$1" patch="$2" waited="$3" judge acq before after
  new_state
  case "$patch" in
    EMPTYDIR) mkdir -p "$LOCK" ;;
    NOTADIR)  : > "$LOCK" ;;
    GARBAGE)  mkdir -p "$LOCK"; printf 'not json at all\n' > "$LOCK/owner.json" ;;
    *)        strand_lock; patch_owner "$patch" ;;
  esac
  before="$(lock_snapshot)"
  judge="$(ctl judge)"
  acq="$(ctl acquire)"
  after="$(lock_snapshot)"
  assert_eq "$name: the owner cannot be judged"          "$(kv "$judge" state)" "UNKNOWN"
  assert_eq "$name: acquisition fails closed"            "$(kv "$acq" rc)" "3"
  assert_eq "$name: and the lock is left untouched"      "$after" "$before"
  if [[ "$waited" == "yes" ]]; then
    assert_ne "$name: refused only after the wait for a record was spent" \
      "$(kv "$acq" publish_waits)" "0"
  else
    assert_eq "$name: refused at once, with no wait spent on a decided answer" \
      "$(kv "$acq" publish_waits)" "0"
  fi
}

fail_closed_case "a record with no incarnation"      'del(.incarnation)' no
fail_closed_case "a record with no pid"              'del(.pid)' no
fail_closed_case "a record with no start identity"   'del(.process_start_identity)' no
fail_closed_case "a record with no boot identity"    'del(.boot_identity)' no
fail_closed_case "a record not marked complete"      '.complete = false' no
fail_closed_case "a record in an older lock schema"  '.lock_schema_version = "1.0"' no
fail_closed_case "a record in a future lock schema"  '.lock_schema_version = "9.9"' no
fail_closed_case "an incarnation shaped like a path" '.incarnation = "../../../etc/passwd"' no
fail_closed_case "an incarnation with no entropy"    '.incarnation = "inc-1-ab"' no
fail_closed_case "a lock with no owner record"       'EMPTYDIR' yes
fail_closed_case "a lock whose record is not JSON"   'GARBAGE' no
fail_closed_case "a lock path that is not a directory" 'NOTADIR' no

# ===========================================================================
head1 "8. PROTOCOL — a reclaimer killed mid-reclamation does not brick the lock"
# ===========================================================================
# The arbitration marker is what makes reclamation single-winner. A marker left
# by a process that died holding it must be judgeable and recoverable, or the
# fix for a permanent lock would have introduced a permanent lock.

new_state
strand_lock
STRANDED="$STRANDED_INC"
MARK="$(ctl strand-marker "$STRANDED")"
assert_eq "a reclaimer can claim the marker for an exact incarnation" "$(kv "$MARK" rc)" "0"
assert_file "and the marker is on disk, fully formed" "$LOCK/reclaim.$STRANDED.json"
assert_eq "carrying a complete owner record of its own" \
  "$(jq -r '.complete' "$LOCK/reclaim.$STRANDED.json" 2>/dev/null)" "true"

ACQ="$(ctl acquire)"
assert_eq "an abandoned marker is recovered rather than obeyed forever" "$(kv "$ACQ" rc)" "0"
assert_eq "and the reclamation is still reported"                       "$(kv "$ACQ" reclaimed)" "true"
assert_no_file "with no marker residue"                                 "$LOCK"

# A marker held by a process that is ALIVE is a reclamation in progress, and is
# waited on rather than trampled. The marker record is the stranded lock's own
# record with this suite's pid and start identity substituted, so every other
# field is one the library wrote.
new_state
strand_lock
MARKER="$LOCK/reclaim.$STRANDED_INC.json"
LIVE_START="$(bash -c '. "$1/lib/afk-common.sh"; . "$1/lib/afk-source.sh"
                       . "$1/lib/afk-inventory.sh"; . "$1/lib/afk-commands.sh"
                       . "$1/lib/afk-plan.sh"; . "$1/lib/afk-mutate.sh"
                       afk_process_start_identity "$2"' _ "$KIT_ROOT" "$$")"
assert_ne "this host can state its own start identity" "$LIVE_START" ""
jq -c --argjson p "$$" --arg s "$LIVE_START" \
  '.pid = $p | .process_start_identity = $s' "$LOCK/owner.json" > "$MARKER"

ACQ_LIVE="$(ctl acquire)"
assert_eq "a reclamation already in progress is waited on, not raced" "$(kv "$ACQ_LIVE" rc)" "1"
assert_contains "and the refusal says what is happening" \
  "$(kv "$ACQ_LIVE" owner_detail)" "already being reclaimed"
assert_file "the abandoned lock is left for the live reclaimer" "$LOCK/owner.json"
assert_eq "still carrying the incarnation it did" "$(lock_field '.incarnation')" "$STRANDED_INC"

# ===========================================================================
head1 "9. RECORD — the incarnation this kit writes is unique and well shaped"
# ===========================================================================

new_state
A="$(kv "$(ctl incarnation)" inc)"
B="$(kv "$(ctl incarnation)" inc)"
assert_ne "an incarnation is produced" "$A" ""
assert_ne "two incarnations never collide" "$A" "$B"
assert_eq "and each is shaped the way the reader demands" \
  "$(printf '%s' "$A" | grep -cE '^inc-[0-9]{1,10}-[0-9a-f]{16,32}$')" "1"

# Two acquisitions by ONE process do not share a token: a release must never be
# able to answer for an earlier acquisition of the same pid.
new_state
FIRST="$(ctl acquire)"
SECOND="$(ctl acquire)"
assert_eq "a process can acquire, release and acquire again" \
  "$(kv "$FIRST" rc)$(kv "$SECOND" rc)" "00"
assert_ne "and the two acquisitions carry different incarnations" \
  "$(kv "$FIRST" inc)" "$(kv "$SECOND" inc)"

# ===========================================================================
head1 "10. PROTOCOL — a lock caught mid-publication is waited on, not condemned"
# ===========================================================================
# The reported failure: taking the lock is two steps — `mkdir` is the atomic
# test-and-set, and the owner record appears an instant later — and a
# contender that observed the gap judged the lock unjudgeable and refused with
# OPERATION_LOCK_OWNER_UNVERIFIABLE, whose owner action is "remove the lock by
# hand". An operator following that while the winner mutates is exactly the
# two-owners-one-installation state the lock exists to prevent.
#
# Every scenario here constructs that gap deliberately rather than racing for
# it: the winner is stopped between its two steps and released by the test.

# The contender needs to be inside its acquisition before the window closes.
# This is bounded and it is not a rendezvous, so it stops early the moment the
# contender exits — which on a tree that refuses the window outright is what
# happens, and is the failure being pinned.
#
# The bound is real wall-clock time, not an iteration count: a fixed count of
# `kill -0` checks measures CPU/syscall speed, not elapsed time, and on a host
# where each check costs more, the same count can burn as long as the lock's
# own publication-wait ceiling (AFK_LOCK_PUBLISH_WAIT_SLICES *
# AFK_LOCK_PUBLISH_WAIT_SLICE, ~2.4s+) — racing this fixture's own PUB release
# against the contender's budget instead of comfortably inside it. `sleep`
# with a fractional argument is the same real timer the lock's own
# `afk_lock_pause` relies on, so 300ms here stays 300ms everywhere.
burn_until_gone() { # <pid>
  local pid="$1" i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$((i + 1))
    (( i < 15 )) || return 0
    sleep 0.02 2>/dev/null || true
  done
  return 0
}

spin_for_file() { # <path>
  local i=0
  while [[ ! -e "$1" ]]; do i=$((i + 1)); (( i < 60000000 )) || return 1; done
  return 0
}

new_state
WIN="$TMPROOT/win-10"; PUB="$TMPROOT/pub-10"; LETGO="$TMPROOT/letgo-10"
PUB_OUT="$TMPROOT/pubout-10"
( ctl publish-slowly "$WIN" "$PUB" "$LETGO" > "$PUB_OUT" ) &
PUB_PID=$!
spin_for_file "$WIN" || bad "a winner could hold the publication window open" "timed out"

assert_file    "the window is open: the lock directory exists"  "$LOCK"
assert_no_file "and no owner record has been published into it" "$LOCK/owner.json"
WIN_JUDGE="$(ctl judge)"
assert_eq "the record alone cannot say who owns a lock mid-publication" \
  "$(kv "$WIN_JUDGE" state)" "UNKNOWN"
assert_contains "which is the state the old refusal was built on" \
  "$(kv "$WIN_JUDGE" detail)" "no owner record"

READY="$TMPROOT/ready-10"; CON_OUT="$TMPROOT/con-10"
( ctl acquire-announced "$READY" > "$CON_OUT" ) &
CON_PID=$!
spin_for_file "$READY" || bad "a contender reached the lock" "timed out"
burn_until_gone "$CON_PID"
: > "$PUB"
wait "$CON_PID"
CON="$(cat "$CON_OUT")"

assert_eq "a contender that observed the window waits it out rather than refusing" \
  "$(kv "$CON" rc)" "1"
assert_eq "and reports the live owner it was waiting for" \
  "$(kv "$CON" owner_state)" "LIVE"
assert_ne "having actually spent wait budget on the window" \
  "$(kv "$CON" publish_waits)" "0"
assert_eq "so nothing it says can be read as 'this lock has no owner'" \
  "$(printf '%s' "$(kv "$CON" owner_detail)" | grep -c 'no owner record')" "0"
assert_file "and the winner's lock is untouched" "$LOCK/owner.json"
assert_eq "still carrying the incarnation the winner published" \
  "$(lock_field '.incarnation')" "$(kv "$(cat "$PUB_OUT")" inc)"

: > "$LETGO"
wait "$PUB_PID"
assert_eq "the winner still releases its own incarnation cleanly" \
  "$(kv "$(cat "$PUB_OUT")" released)" "true"
assert_no_file "leaving no lock behind" "$LOCK"
assert_eq "and no residue" "$(lock_residue)" ""

# The same window, but the winner DIES inside it. Now there is no owner to
# wait for, the wait is spent, and the refusal is made — this is the one case
# where "remove it by hand" is true, and it must still be reached.
new_state
mkdir -p "$LOCK"          # what a process killed between mkdir and write leaves
BEFORE_ORPHAN="$(lock_snapshot)"
ORPHAN="$(ctl acquire)"
assert_eq "a window nobody is publishing into still fails closed" \
  "$(kv "$ORPHAN" rc)" "3"
assert_ne "only after the wait for a record was actually spent" \
  "$(kv "$ORPHAN" publish_waits)" "0"
assert_contains "and the refusal says the record never appeared" \
  "$(kv "$ORPHAN" owner_detail)" "none appeared while it was waited on"
assert_eq "the lock is left exactly where it was, for its owner to remove" \
  "$(lock_snapshot)" "$BEFORE_ORPHAN"
assert_eq "and nothing was reclaimed on the way to refusing" \
  "$(kv "$ORPHAN" reclaimed)" "false"

# A lock published long before the contender arrives costs no wait at all: the
# budget is for a window, not a tax on every acquisition.
new_state
READY2="$TMPROOT/ready-10b"; LETGO2="$TMPROOT/letgo-10b"; PARK_OUT2="$TMPROOT/park-10b"
( ctl park "$READY2" "$LETGO2" > "$PARK_OUT2" ) &
PARK_PID2=$!
spin_for_file "$READY2" || bad "a live owner could park on the lock" "timed out"
SETTLED="$(ctl acquire)"
assert_eq "a fully published live owner blocks a contender"  "$(kv "$SETTLED" rc)" "1"
assert_eq "and no publication wait is spent doing it"        "$(kv "$SETTLED" publish_waits)" "0"
: > "$LETGO2"
wait "$PARK_PID2"

# ---------------------------------------------------------------------------
# The ordinary case the gates never constructed: a crowd released onto a CLEAN
# lock path. Every loser here observes the winner's publication window, so a
# tree that condemns that window fails this outright.
new_state
BAR="$TMPROOT/bar-10"; OWNERS="$TMPROOT/owners-10"
mkdir -p "$BAR" "$OWNERS"
N=12
OUTDIR="$TMPROOT/out-10"; mkdir -p "$OUTDIR"
for i in $(seq 1 "$N"); do
  ( ctl contend "$BAR" "$OWNERS" "$i" > "$OUTDIR/$i" ) &
done
if barrier_wait_ready "$BAR" "$N"; then : > "$BAR/go"; else bad "twelve contenders reached the barrier" "timed out"; fi
wait

CLEAN_ACQ=0; CLEAN_BLOCKED=0; CLEAN_UNJUDGEABLE=0; CLEAN_PEAK=0; CLEAN_BADRC=""
for i in $(seq 1 "$N"); do
  o="$(cat "$OUTDIR/$i")"
  r="$(kv "$o" rc)"
  case "$r" in
    0) CLEAN_ACQ=$((CLEAN_ACQ + 1)) ;;
    1) CLEAN_BLOCKED=$((CLEAN_BLOCKED + 1)) ;;
    3) CLEAN_UNJUDGEABLE=$((CLEAN_UNJUDGEABLE + 1)) ;;
    *) CLEAN_BADRC="$CLEAN_BADRC $i:$r" ;;
  esac
  p="$(kv "$o" peak)"; [[ -n "$p" ]] && (( p > CLEAN_PEAK )) && CLEAN_PEAK="$p"
done
assert_eq "twelve contenders on a clean lock path: never more than one owner" \
  "$CLEAN_PEAK" "1"
assert_eq "and not one of them is told the lock has no owner" \
  "$CLEAN_UNJUDGEABLE" "0"
assert_eq "every outcome is either ownership or a live owner to wait for" \
  "$CLEAN_BADRC" ""
assert_eq "at least one of them acquired"  "$(( CLEAN_ACQ >= 1 ? 1 : 0 ))" "1"
assert_eq "and the rest were blocked by an owner, not by an unjudgeable lock" \
  "$(( CLEAN_ACQ + CLEAN_BLOCKED ))" "$N"
assert_no_file "no lock survives the clean-path crowd" "$LOCK"
assert_eq "and no residue survives it either" "$(lock_residue)" ""

# ===========================================================================
head1 "11. PROTOCOL — a record seen and then found gone is a moment, not a verdict"
# ===========================================================================
# The publication window is one instant of one file appearing. The same
# reasoning decides two neighbouring instants of a record DISAPPEARING, and
# both used to be refused with OPERATION_LOCK_OWNER_UNVERIFIABLE and its
# "remove the lock by hand" — while a successor held the lock.
#
#   * the arbitration marker lives inside the lock directory, so the winning
#     reclaimer's rename carries it away between a loser's claim and the judge
#     that reads it;
#   * the owner record can be released or reclaimed between the existence test
#     and the read of it, and a read of a file that is gone yields nothing —
#     which is indistinguishable, byte for byte, from a record that could not
#     be parsed.
#
# Neither is raced for here. Each is constructed deliberately: the first by
# holding a real losing claim still while the handover happens, the second by
# performing the release underneath a real read.

# --- the marker the winner's rename carried away ---------------------------

new_state
strand_lock
R2_INC="$STRANDED_INC"
assert_eq "another reclaimer wins the marker for the abandoned incarnation" \
  "$(kv "$(ctl strand-marker "$R2_INC")" rc)" "0"
assert_file "so a later arrival must lose the claim" "$LOCK/reclaim.$R2_INC.json"

R2_LOST="$TMPROOT/lost-11a"; R2_GO="$TMPROOT/go-11a"; R2_OUT="$TMPROOT/out-11a"
( ctl reclaim-marker-interleaved "$R2_INC" "$R2_LOST" "$R2_GO" > "$R2_OUT" ) &
R2_PID=$!
spin_for_file "$R2_LOST" || bad "a loser reached the marker it must judge" "timed out"
assert_file "the loser is held between its claim and that judge" "$LOCK/reclaim.$R2_INC.json"
# Exactly what the winner does next: the directory is renamed aside, and the
# marker inside it goes with it.
mv -- "$LOCK" "$STATE/handover-a"
rm -rf -- "$STATE/handover-a"
: > "$R2_GO"
wait "$R2_PID"
R2A="$(cat "$R2_OUT")"

assert_eq "a loser whose marker was carried off by the winner observes again" \
  "$(kv "$R2A" rc)" "3"
assert_eq "and says nothing about a reclaimer it could not judge" \
  "$(printf '%s' "$(kv "$R2A" owner_detail)" | grep -c 'cannot be judged')" "0"

# The same interleaving through a whole acquisition, with a LIVE successor
# holding the lock at the end of it — the state the old refusal told an
# operator to delete.
new_state
strand_lock
R2B_INC="$STRANDED_INC"
ctl strand-marker "$R2B_INC" > /dev/null
R2B_LOST="$TMPROOT/lost-11b"; R2B_GO="$TMPROOT/go-11b"; R2B_OUT="$TMPROOT/out-11b"
( ctl acquire-marker-interleaved "$R2B_LOST" "$R2B_GO" > "$R2B_OUT" ) &
R2B_PID=$!
spin_for_file "$R2B_LOST" || bad "an acquisition reached the marker it must judge" "timed out"
mv -- "$LOCK" "$STATE/handover-b"
rm -rf -- "$STATE/handover-b"
R2B_READY="$TMPROOT/ready-11b"; R2B_LETGO="$TMPROOT/letgo-11b"
R2B_PARK="$TMPROOT/park-11b"
( ctl park "$R2B_READY" "$R2B_LETGO" > "$R2B_PARK" ) &
R2B_PARK_PID=$!
spin_for_file "$R2B_READY" || bad "a successor took the lock the winner freed" "timed out"
: > "$R2B_GO"
wait "$R2B_PID"
R2B="$(cat "$R2B_OUT")"

assert_eq "an acquisition that lost the marker to a successor is told to wait" \
  "$(kv "$R2B" rc)" "1"
assert_eq "naming the live owner that now holds the lock" \
  "$(kv "$R2B" owner_state)" "LIVE"
assert_eq "so no operator is ever told to remove a lock a live owner holds" \
  "$(printf '%s' "$(kv "$R2B" owner_detail)" | grep -c 'cannot be judged')" "0"
assert_eq "and it reclaimed nothing on the way to waiting" \
  "$(kv "$R2B" reclaimed)" "false"
assert_eq "the successor's lock still carries the incarnation it published" \
  "$(lock_field '.incarnation')" "$(kv "$(cat "$R2B_PARK")" inc)"
: > "$R2B_LETGO"
wait "$R2B_PARK_PID"
assert_eq "which it then releases cleanly" "$(kv "$(cat "$R2B_PARK")" released)" "true"
assert_no_file "leaving no lock behind" "$LOCK"
assert_eq "and no residue" "$(lock_residue)" ""

# A marker that is STILL THERE and cannot be judged is a diagnosis, not a
# moment: it must still fail closed, at once, touching nothing.
new_state
strand_lock
printf 'not json at all\n' > "$LOCK/reclaim.$STRANDED_INC.json"
R2C_BEFORE="$(lock_snapshot)"
R2C="$(ctl acquire)"
assert_eq "a marker that is present and unreadable still fails closed" \
  "$(kv "$R2C" rc)" "3"
assert_contains "saying the reclaimer could not be judged" \
  "$(kv "$R2C" owner_detail)" "cannot be judged"
assert_eq "with no wait spent on a decided answer" "$(kv "$R2C" publish_waits)" "0"
assert_eq "and the lock left exactly where it was" "$(lock_snapshot)" "$R2C_BEFORE"

# --- the owner record released underneath the read of it -------------------
#
# `jq` is what reads the record. A `jq` placed ahead of the real one on PATH
# performs the release — rename aside, then remove, exactly as afk_lock_release
# does — for exactly ONE read of exactly the record being judged, and then
# hands over to the real `jq`, which finds nothing there. Not a line of the
# judge is replaced; only the instant the release lands is the fixture's.

REAL_JQ="$(command -v jq)"
REAL_CAT="$(command -v cat)"
assert_ne "this host has a real jq to hand the fixture"  "$REAL_JQ"  ""
assert_ne "this host has a real cat to hand the fixture" "$REAL_CAT" ""

# The hook is installed under BOTH names a judge could read a record with, so
# what is asserted is the VERDICT and not which tool produced it. Whichever of
# them opens the record first fires the moment; the other hands straight over.
arm_vanishing_record() { # -> VANISH_BIN, and the AFK_TEST_* environment for it
  VANISH_BIN="$TMPROOT/vanish-$SCN"
  mkdir -p "$VANISH_BIN"
  cat > "$VANISH_BIN/jq" <<'SHIM'
#!/usr/bin/env bash
# Not a reader: a moment. On the FIRST read of exactly the record under test
# the lock is released — renamed aside and removed, the way afk_lock_release
# does it — and the real reader is then run against a name that is gone. Not a
# line of the judge is replaced; only the instant the release lands is the
# fixture's. When AFK_TEST_VANISH_SUCCESSOR is set, a REAL successor takes the
# freed path and publishes a REAL record into the same name before the judge
# is allowed to decide.
case "${0##*/}" in
  jq)  real="$AFK_TEST_REAL_JQ" ;;
  cat) real="$AFK_TEST_REAL_CAT" ;;
  *)   printf 'fixture: unknown reader %s\n' "${0##*/}" >&2; exit 97 ;;
esac
[[ "$real" != "${BASH_SOURCE[0]}" ]] || { printf 'fixture reader recursion\n' >&2; exit 97; }
if [[ -n "${AFK_TEST_VANISH_REC:-}" && "${*: -1}" == "$AFK_TEST_VANISH_REC" &&
      ! -e "$AFK_TEST_VANISH_FLAG" ]]; then
  : > "$AFK_TEST_VANISH_FLAG"
  mv -- "$AFK_TEST_VANISH_LOCK" "$AFK_TEST_VANISH_LOCK.handover" 2>/dev/null
  rm -rf -- "$AFK_TEST_VANISH_LOCK.handover" 2>/dev/null
  if [[ -n "${AFK_TEST_VANISH_SUCCESSOR:-}" ]]; then
    bash "$AFK_TEST_VANISH_SUCCESSOR" > "$AFK_TEST_VANISH_SUCCESSOR_OUT" 2>/dev/null &
    printf '%s' "$!" > "$AFK_TEST_VANISH_SUCCESSOR_PID"
    i=0
    while [[ ! -e "$AFK_TEST_VANISH_SUCCESSOR_READY" ]]; do
      i=$((i + 1)); (( i < 40000000 )) || break
    done
    # The record this read opened is gone; handing the real reader the name
    # would hand back the SUCCESSOR's bytes, which is not what a read of a
    # released record returns. Return what it does return: nothing.
    exit 1
  fi
fi
exec "$real" "$@"
SHIM
  cp "$VANISH_BIN/jq" "$VANISH_BIN/cat"
  chmod 755 "$VANISH_BIN/jq" "$VANISH_BIN/cat"
  export AFK_TEST_REAL_JQ="$REAL_JQ"
  export AFK_TEST_REAL_CAT="$REAL_CAT"
  export AFK_TEST_VANISH_REC="$LOCK/owner.json"
  export AFK_TEST_VANISH_LOCK="$LOCK"
  export AFK_TEST_VANISH_FLAG="$TMPROOT/vanished-$SCN"
}

# The same moment, with a live successor publishing into the freed name before
# the judge decides. `park` acquires the lock for real, publishes the record
# the library writes, and stays alive until it is told to let go.
arm_vanishing_record_with_successor() { # <ready-file> <go-file> <out-file>
  arm_vanishing_record
  cat > "$TMPROOT/successor-$SCN.sh" <<SUCC
exec bash "$LOCKCTL" "$KIT_ROOT" "$STATE" park "$1" "$2"
SUCC
  export AFK_TEST_VANISH_SUCCESSOR="$TMPROOT/successor-$SCN.sh"
  export AFK_TEST_VANISH_SUCCESSOR_READY="$1"
  export AFK_TEST_VANISH_SUCCESSOR_OUT="$3"
  export AFK_TEST_VANISH_SUCCESSOR_PID="$TMPROOT/successor-pid-$SCN"
}

disarm_vanishing_record() {
  unset AFK_TEST_REAL_JQ AFK_TEST_REAL_CAT AFK_TEST_VANISH_REC AFK_TEST_VANISH_LOCK \
        AFK_TEST_VANISH_FLAG AFK_TEST_VANISH_SUCCESSOR AFK_TEST_VANISH_SUCCESSOR_READY \
        AFK_TEST_VANISH_SUCCESSOR_OUT AFK_TEST_VANISH_SUCCESSOR_PID
}

new_state
strand_lock
arm_vanishing_record
assert_eq "the record the judge is about to read is valid JSON the library wrote" \
  "$(jq -r '.complete' "$LOCK/owner.json" 2>/dev/null)" "true"
R3A="$( PATH="$VANISH_BIN:$PATH" ctl judge )"
assert_no_file "the release lands underneath the read" "$LOCK"
assert_eq "a record released mid-read is reported as a record that is not there" \
  "$(kv "$R3A" detail)" "the lock carries no owner record"
assert_eq "never as a record that could not be parsed" \
  "$(printf '%s' "$(kv "$R3A" detail)" | grep -c 'could not be parsed')" "0"
disarm_vanishing_record

# The whole acquisition: the lock it was judging was released a microsecond
# earlier, so the right outcome is to take the free lock — not to refuse a
# lock that no longer exists and tell an operator to go and remove it.
new_state
strand_lock
arm_vanishing_record
R3B="$( PATH="$VANISH_BIN:$PATH" ctl acquire )"
disarm_vanishing_record
assert_eq "an acquisition whose lock was released mid-read takes the free path" \
  "$(kv "$R3B" rc)" "0"
assert_eq "having reclaimed nothing to get there" "$(kv "$R3B" reclaimed)" "false"
assert_eq "and never called the vanished record unparseable" \
  "$(printf '%s' "$(kv "$R3B" owner_detail)" | grep -c 'could not be parsed')" "0"
assert_eq "it releases its own incarnation cleanly afterwards" \
  "$(kv "$R3B" released)" "true"
assert_no_file "leaving no lock behind" "$LOCK"
assert_eq "and no residue" "$(lock_residue)" ""

# ===========================================================================
head1 "12. PROTOCOL — one observation, one verdict (the discriminator)"
# ===========================================================================
# Telling "the record is gone" apart from "the record is damaged" used to be a
# SECOND look at the name after the read of it came back empty. Two looks are
# two instants, and the lock path is exactly where a successor arrives between
# them: released, taken again, and republished under the same name. The second
# look then finds a brand-new, perfectly valid record and calls it damaged —
# OPERATION_LOCK_OWNER_UNVERIFIABLE and "remove the lock by hand", against a
# lock a live owner is holding. That is the harm the whole F6 series exists to
# remove, re-created by the repair for it.
#
# So the record is read ONCE and judged on the bytes that read returned. The
# fixture below constructs precisely the interleaving that used to be misread:
# the release lands underneath the read, a REAL successor takes the freed path
# and publishes a REAL record into the same name, and only then is the judge
# allowed to decide.

new_state
strand_lock
R4_READY="$TMPROOT/ready-12a"; R4_GO="$TMPROOT/go-12a"; R4_PARK="$TMPROOT/park-12a"
arm_vanishing_record_with_successor "$R4_READY" "$R4_GO" "$R4_PARK"
R4A="$( PATH="$VANISH_BIN:$PATH" ctl judge )"
assert_file "a live successor published into the freed name before the judge decided" \
  "$LOCK/owner.json"
assert_eq "a record read once and found gone is reported as a record that is not there" \
  "$(kv "$R4A" detail)" "the lock carries no owner record"
assert_eq "never as a record that could not be parsed, whatever arrived afterwards" \
  "$(printf '%s' "$(kv "$R4A" detail)" | grep -c 'could not be parsed')" "0"
R4_SUCC_PID="$(cat "$TMPROOT/successor-pid-$SCN" 2>/dev/null || printf '')"
: > "$R4_GO"
spin_for_exit "$R4_SUCC_PID" || bad "the successor let go of the lock" "timed out"
disarm_vanishing_record
assert_no_file "and the successor's lock is released cleanly afterwards" "$LOCK"
assert_eq "leaving no residue" "$(lock_residue)" ""

# The same instant through a whole acquisition: the outcome an operator would
# actually be handed. A live successor holds the lock, so the only truthful
# answer is "wait for it", never "remove it".
new_state
strand_lock
R4B_READY="$TMPROOT/ready-12b"; R4B_GO="$TMPROOT/go-12b"; R4B_PARK="$TMPROOT/park-12b"
arm_vanishing_record_with_successor "$R4B_READY" "$R4B_GO" "$R4B_PARK"
R4B="$( PATH="$VANISH_BIN:$PATH" ctl acquire )"
R4B_SUCC_PID="$(cat "$TMPROOT/successor-pid-$SCN" 2>/dev/null || printf '')"
disarm_vanishing_record
assert_eq "an acquisition that read a vanished record while a successor published waits" \
  "$(kv "$R4B" rc)" "1"
assert_eq "naming the live owner that now holds the lock" \
  "$(kv "$R4B" owner_state)" "LIVE"
assert_eq "and never calls the successor's valid record unparseable" \
  "$(printf '%s' "$(kv "$R4B" owner_detail)" | grep -c 'could not be parsed')" "0"
assert_eq "so no operator is ever told to remove a lock a live successor holds" \
  "$(printf '%s' "$(kv "$R4B" owner_detail)" | grep -c 'no owner record')" "0"
assert_eq "and it reclaimed nothing on the way to waiting" "$(kv "$R4B" reclaimed)" "false"
assert_eq "the successor's lock still carries the incarnation it published" \
  "$(lock_field '.incarnation')" "$(kv "$(cat "$R4B_PARK")" inc)"
: > "$R4B_GO"
spin_for_exit "$R4B_SUCC_PID" || bad "the successor let go of the lock" "timed out"
assert_eq "which it then releases cleanly" "$(kv "$(cat "$R4B_PARK")" released)" "true"
assert_no_file "leaving no lock behind" "$LOCK"
assert_eq "and no residue" "$(lock_residue)" ""

# A record that is genuinely damaged is still a diagnosis, read once and
# refused at once. The single read must not have bought safety by making every
# unreadable record a moment.
new_state
strand_lock
printf 'not json at all\n' > "$LOCK/owner.json"
R4C_BEFORE="$(lock_snapshot)"
R4C="$(ctl acquire)"
assert_eq "bytes that were read and do not parse are still a diagnosis" \
  "$(kv "$R4C" rc)" "3"
assert_contains "saying the record could not be parsed" \
  "$(kv "$R4C" owner_detail)" "could not be parsed"
assert_eq "with no wait spent on a decided answer" "$(kv "$R4C" publish_waits)" "0"
assert_eq "and the lock left exactly where it was" "$(lock_snapshot)" "$R4C_BEFORE"

# ===========================================================================
head1 "13. PROTOCOL — a reclamation is never silent"
# ===========================================================================
# Reclaiming is the one place the lifecycle removes something another process
# created, so it is reported. The report used to belong to the ACQUISITION
# that followed it: a reclaimer that renamed the abandoned lock aside, proved
# it, removed it — and then lost the mkdir to a contender — returned "observe
# again" and said nothing, while the contender that took the freed path had
# reclaimed nothing and had nothing to say either. The abandoned lock was
# destroyed and nobody reported it.
#
# The report belongs to the destruction. Below, the take that follows the
# destruction is LOST for real: a contender creates the lock path in the window
# between the rename and the mkdir, and the real afk_lock_take runs and loses.

new_state
strand_lock
R9_INC="$STRANDED_INC"
R9="$(ctl reclaim-losing-take "$R9_INC")"
assert_eq "a reclaimer that loses the take it earned says observe again" \
  "$(kv "$R9" rc)" "3"
assert_eq "the contender really did take the lock path first" "$(kv "$R9" stolen)" "stolen"
assert_no_file "the abandoned incarnation's record is gone: it was destroyed" \
  "$LOCK/owner.json"
assert_eq "and the destruction is reported even though the take was lost" \
  "$(kv "$R9" reclaimed)" "true"
assert_eq "exactly once, for the one lock that was destroyed" \
  "$(kv "$R9" reclaim_reports)" "1"
assert_contains "naming the owner it proved was gone" \
  "$(kv "$R9" reclaim_detail)" "no longer running"
rm -rf -- "$LOCK"
assert_eq "and no reclamation residue survives it" "$(lock_residue)" ""

# The ordinary path is unchanged: a reclaimer that wins its take reports the
# same reclamation, once, and holds the lock.
new_state
strand_lock
R9B="$(ctl acquire)"
assert_eq "a reclaimer that wins the take acquires" "$(kv "$R9B" rc)" "0"
assert_eq "and reports the reclamation" "$(kv "$R9B" reclaimed)" "true"
assert_eq "releasing its own incarnation afterwards" "$(kv "$R9B" released)" "true"
assert_no_file "leaving no lock behind" "$LOCK"
assert_eq "and no residue" "$(lock_residue)" ""

# Nothing abandoned, nothing destroyed, nothing reported.
new_state
R9C="$(ctl acquire)"
assert_eq "an acquisition of a free lock path acquires" "$(kv "$R9C" rc)" "0"
assert_eq "and reports no reclamation, because it destroyed nothing" \
  "$(kv "$R9C" reclaimed)" "false"

# ===========================================================================
head1 "14. PROTOCOL — an interrupted acquisition leaves no lock behind"
# ===========================================================================
# The reported failure: a signal landing between `mkdir` and the owner record
# ended the taker with an empty lock behind it, which nothing released and
# every later acquisition refused as unjudgeable. The delivery point is CHOSEN:
# a test-only `mkdir` or `ln` on PATH parks the call that names the lock,
# before or after running the real tool, until the test says go. "pid" cases
# signal the taking shell alone; "group" cases signal it and the parked child,
# and what is on disk decides whether the record was published.

IP_BIN="$TMPROOT/interpose"
mkdir -p "$IP_BIN"
for tool in mkdir ln; do
  real="$(command -v "$tool")"
  [[ -n "$real" ]] || bad "fixture: the real $tool could be found" ""
  {
    printf '#!/usr/bin/env bash\n'
    printf '# generated by tests/lifecycle-concurrency-tests.sh — test-only interposer\n'
    printf 'real=%q\n' "$real"
    cat <<'SHIM'
if [[ -n "${AFK_IP_MATCH:-}" && "${*: -1}" == "$AFK_IP_MATCH" && ! -e "$AFK_IP_WIN" ]]; then
  rc=0
  if [[ "${AFK_IP_WHEN:-}" == after ]]; then "$real" "$@" || rc=$?; fi
  printf '%s\n' "$$" > "$AFK_IP_WIN.tmp" && mv -f -- "$AFK_IP_WIN.tmp" "$AFK_IP_WIN"
  i=0
  while [[ ! -e "$AFK_IP_GO" ]]; do i=$((i + 1)); (( i < 3000 )) || break; sleep 0.01; done
  [[ "${AFK_IP_WHEN:-}" != after ]] || exit "$rc"
fi
exec "$real" "$@"
SHIM
  } > "$IP_BIN/$tool"
  chmod 755 "$IP_BIN/$tool"
done

# Start one interposed take. `exec` keeps the pid the test signals identical
# to the pid that takes the lock. Sets IP_PID, IP_WIN, IP_GO and IP_OUT.
ip_launch() { # <mkdir|ln> <before|after> <tag> <done-file|-> <let-go-file|->
  local match="$LOCK"
  [[ "$1" == "ln" ]] && match="$LOCK/owner.json"
  IP_WIN="$TMPROOT/ipwin-$3"; IP_GO="$TMPROOT/ipgo-$3"; IP_OUT="$TMPROOT/ipout-$3"
  ( exec env PATH="$IP_BIN:$PATH" AFK_IP_MATCH="$match" AFK_IP_WHEN="$2" \
             AFK_IP_WIN="$IP_WIN" AFK_IP_GO="$IP_GO" \
             bash "$LOCKCTL" "$KIT_ROOT" "$STATE" take-interposed "$4" "$5" ) \
    > "$IP_OUT" 2>/dev/null &
  IP_PID=$!
}

# Bounded, and it gives up the moment the take it waits on is gone. Sets
# IP_SHIM_PID to the parked child's pid; a take that never parks is a failure.
ip_parked() { # <tag>
  local i=0
  IP_SHIM_PID=""
  while [[ ! -s "$IP_WIN" ]]; do
    if ! kill -0 "$IP_PID" 2>/dev/null || (( ++i >= 3000 )); then
      bad "$1: the take is parked at the chosen point" "it never got there"; return 1
    fi
    sleep 0.01
  done
  IP_SHIM_PID="$(cat "$IP_WIN")"
}

ip_stage_count() { find "$STATE" -maxdepth 1 -name '.afk-take.*' | wc -l | tr -d ' '; }

# --- pid-targeted: the signal is held until the take publishes or fails ----
ip_pid_case() { # <tool> <before|after> <signal> <status> <tag>
  local tool="$1" when="$2" sig="$3" want="$4" tag="$5" rc
  new_state
  ip_launch "$tool" "$when" "$tag" - -
  ip_parked "$tag" || return 1
  if [[ "$tool" == "mkdir" && "$when" == "after" ]]; then
    assert_file "$tag: the lock directory exists while the take is parked" "$LOCK"
  fi
  kill -"$sig" "$IP_PID" 2>/dev/null
  : > "$IP_GO"
  wait "$IP_PID"; rc=$?
  assert_eq "$tag: the taker terminates on the signal it was sent" "$rc" "$want"
  assert_no_file "$tag: and leaves no lock behind" "$LOCK"
  assert_eq "$tag: nor any staged record or release residue" "$(lock_residue)" ""
  assert_eq "$tag: and a fresh acquisition takes the lock at once" \
    "$(kv "$(ctl acquire)" rc)" "0"
}

ip_pid_case mkdir after  TERM 143 "14a-term"
ip_pid_case mkdir after  INT  130 "14a-int"
ip_pid_case mkdir after  HUP  129 "14a-hup"
ip_pid_case mkdir before TERM 143 "14b-term"
ip_pid_case mkdir before INT  130 "14b-int"
ip_pid_case mkdir before HUP  129 "14b-hup"
ip_pid_case ln    before TERM 143 "14c-term"
ip_pid_case ln    before INT  130 "14c-int"
ip_pid_case ln    before HUP  129 "14c-hup"

# --- group-shaped: the child dies too, and the disk decides -----------------
ip_group_case() { # <before|after> <tag>
  local when="$1" tag="$2" rc
  new_state
  ip_launch ln "$when" "$tag" - -
  ip_parked "$tag" || return 1
  kill -TERM "$IP_PID" "$IP_SHIM_PID" 2>/dev/null
  wait "$IP_PID"; rc=$?
  assert_eq "$tag: the taker terminates on the signal" "$rc" "143"
  assert_no_file "$tag: and leaves no lock behind" "$LOCK"
  assert_eq "$tag: nor any staged record or release residue" "$(lock_residue)" ""
}

ip_group_case before "14d-group-before-link"
ip_group_case after  "14d-group-after-link"

# A `mkdir` child killed after creating the directory reports failure, so its
# taker cannot prove the directory is its own and must not guess: it stays,
# judged like any lock carrying no record.
new_state
ip_launch mkdir after "14d-group-mkdir" - -
if ip_parked "14d-group-mkdir"; then
  kill -TERM "$IP_PID" "$IP_SHIM_PID" 2>/dev/null
  wait "$IP_PID"; RC14="$?"
  assert_eq "14d-group-mkdir: the taker terminates on the signal" "$RC14" "143"
  assert_eq "14d-group-mkdir: an unprovable directory is left, judged recordless" \
    "$(kv "$(ctl judge)" detail)" "the lock carries no owner record"
  assert_eq "14d-group-mkdir: with no staged record beside it" "$(ip_stage_count)" "0"
  rmdir -- "$LOCK" 2>/dev/null
fi

# --- a live owner arriving in the window is never touched -------------------
new_state
ip_launch ln before "14e" - -
if ip_parked "14e"; then
  rmdir -- "$LOCK"
  E_READY="$TMPROOT/ready-14e"; E_LETGO="$TMPROOT/letgo-14e"; E_PARK="$TMPROOT/park-14e"
  ( ctl park "$E_READY" "$E_LETGO" > "$E_PARK" ) &
  E_PARK_PID=$!
  spin_for_file "$E_READY" || bad "14e: a live owner took the freed path" "timed out"
  assert_eq "14e: the live owner's record is 0600 in a 0700 lock directory" \
    "$(stat -c '%a' "$LOCK/owner.json" 2>/dev/null || stat -f '%Lp' "$LOCK/owner.json" 2>/dev/null):$(stat -c '%a' "$LOCK" 2>/dev/null || stat -f '%Lp' "$LOCK" 2>/dev/null)" "600:700"
  E_BEFORE="$(lock_snapshot)"
  kill -TERM "$IP_PID" 2>/dev/null; : > "$IP_GO"
  wait "$IP_PID"; RC14="$?"
  assert_eq "14e: the signalled taker exits on its signal" "$RC14" "143"
  assert_eq "14e: the live owner's lock is byte-for-byte what it was" "$(lock_snapshot)" "$E_BEFORE"
  assert_eq "14e: and is still judged LIVE" "$(kv "$(ctl judge)" state)" "LIVE"
  : > "$E_LETGO"; wait "$E_PARK_PID"
  assert_eq "14e: which releases its own lock cleanly" "$(kv "$(cat "$E_PARK")" released)" "true"
  assert_eq "14e: leaving no residue" "$(lock_residue)" ""
fi

# --- a lock directory removed in the window is never recreated --------------
new_state
ip_launch ln before "14f" - -
if ip_parked "14f"; then
  rmdir -- "$LOCK"; : > "$IP_GO"
  wait "$IP_PID"
  F_OUT="$(cat "$IP_OUT")"
  assert_eq "14f: a take whose directory vanished never holds the lock" \
    "$(kv "$F_OUT" rc):$(kv "$F_OUT" held)" "1:false"
  assert_no_file "14f: and no lock directory is resurrected" "$LOCK"
  assert_eq "14f: nothing is left behind" "$(lock_residue)" ""
fi

# --- a directory replaced in the window: one owner, never two ---------------
# A parks before its link; its directory is removed; B creates the replacement
# and parks before ITS link. A links into it and owns it; B's link meets A's
# record and B never believes it holds anything. A then exits on a signal.
new_state
G_A_DONE="$TMPROOT/done-14g-a"
ip_launch ln before "14g-a" "$G_A_DONE" "$TMPROOT/letgo-14g-a"
G_A_PID="$IP_PID"; G_A_GO="$IP_GO"; G_A_OUT="$IP_OUT"
if ip_parked "14g-a"; then
  rmdir -- "$LOCK"
  ip_launch ln before "14g-b" - -
  if ip_parked "14g-b"; then
    : > "$G_A_GO"
    spin_for_file "$G_A_DONE" || bad "14g: A finished its take" "timed out"
    G_A_INC="$(kv "$(cat "$G_A_OUT")" inc)"
    assert_eq "14g: A links into the replacement and holds it" \
      "$(kv "$(cat "$G_A_OUT")" held):$(lock_field '.incarnation')" "true:$G_A_INC"
    : > "$IP_GO"; wait "$IP_PID"
    assert_eq "14g: B's link meets A's record; B never holds — one owner at most" \
      "$(kv "$(cat "$IP_OUT")" rc):$(kv "$(cat "$IP_OUT")" held)" "1:false"
    assert_eq "14g: and A's record is untouched" "$(lock_field '.incarnation')" "$G_A_INC"
  fi
  : > "$G_A_GO"
  kill -TERM "$G_A_PID" 2>/dev/null
  wait "$G_A_PID"; RC14="$?"
  assert_eq "14g: A exits on its signal" "$RC14" "143"
  assert_no_file "14g: releasing the lock it proved it holds" "$LOCK"
  assert_eq "14g: and nothing is left behind" "$(lock_residue)" ""
fi

# --- an uncatchable death in the window: the refusal is unchanged -----------
# SIGKILL to the taker and its child before the link leaves an empty 0700
# directory and a stage file. The stage is operator evidence only: the next
# acquisition waits the window out, refuses as before and reclaims nothing.
new_state
ip_launch ln before "14h" - -
if ip_parked "14h"; then
  kill -KILL "$IP_PID" "$IP_SHIM_PID" 2>/dev/null
  wait "$IP_PID" 2>/dev/null
  assert_eq "14h: an empty private lock directory is left, with the stage beside it" \
    "$(find "$LOCK" -mindepth 1 | wc -l | tr -d ' '):$(stat -c '%a' "$LOCK" 2>/dev/null || stat -f '%Lp' "$LOCK" 2>/dev/null):$(ip_stage_count)" \
    "0:700:1"
  H_STAGE="$(find "$STATE" -maxdepth 1 -name '.afk-take.*' | head -1)"
  H_STAGE_BYTES="$(cat "$H_STAGE")"; H_BEFORE="$(lock_snapshot)"
  H="$(ctl acquire)"
  assert_eq "14h: the next acquisition refuses the recordless lock, reclaiming nothing" \
    "$(kv "$H" rc):$(kv "$H" reclaimed)" "3:false"
  assert_contains "14h: after watching for a record that never appeared" \
    "$(kv "$H" owner_detail)" "none appeared while it was waited on"
  assert_eq "14h: the lock is left exactly as it was" "$(lock_snapshot)" "$H_BEFORE"
  assert_eq "14h: and the stage is neither consumed nor changed" "$(cat "$H_STAGE")" "$H_STAGE_BYTES"
  rmdir -- "$LOCK" 2>/dev/null; rm -f -- "$H_STAGE"
fi

# ===========================================================================
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
