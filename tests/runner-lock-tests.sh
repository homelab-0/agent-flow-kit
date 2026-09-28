#!/usr/bin/env bash
# runner-lock-tests.sh — hermetic gate for the AFK-TP-4 AC-1 host-wide suite
# lock, against its own lock path under mktemp (never the real one). Drives
# the SAME algorithm tests/run-tests.sh and tests/lifecycle-mutation-tests.sh
# use, via tests/suite-lock.sh (each of those runs as its own `bash` process,
# so it can't be sourced across them any other way).
#
# Usage: tests/runner-lock-tests.sh
# Exit:  0 all passed, 1 any failure.

set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# When run-tests.sh launches this as its own child gate, it has already
# exported AFK_TEST_LOCK_NESTED=1 for ITS OWN chain of child suites — that
# marker must not leak into the independent lockers this gate spawns below,
# or every one of them silently bypasses the lock it exists to test.
unset AFK_TEST_LOCK_NESTED AFK_TEST_LOCK

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0 FAIL=0 SKIPPED=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; SKIPPED=$((SKIPPED + 1)); }

export AFK_SUITE_LOCK_SRC="$KIT_ROOT/tests/suite-lock.sh"

# The locker: acquire, print ACQUIRED, sleep $1s, release, print RELEASED.
# Exits with the acquire function's own code on failure (3 = timeout). Reads
# the same env knobs the production copies do (AFK_TEST_LOCK_PATH,
# AFK_TEST_LOCK_TIMEOUT, AFK_TEST_LOCK=off, AFK_TEST_LOCK_NESTED=1,
# AFK_TEST_LOCK_FORCE_MKDIR=1, AFK_TEST_LOCK_POLL_S).
LOCKER="$TMPROOT/locker.sh"
cat >"$LOCKER" <<'LOCKER_EOF'
#!/usr/bin/env bash
set -uo pipefail
source "${AFK_SUITE_LOCK_SRC:?}"
afk_test_lock_acquire; rc=$?
(( rc != 0 )) && exit "$rc"
echo ACQUIRED; sleep "${1:-0}"; afk_test_lock_release; echo RELEASED
LOCKER_EOF
chmod +x "$LOCKER"

# The racer: acquire, record START <pid> <ns>, hold for $1s, record
# END <pid> <ns>, release — into the SHARED $AFK_RACE_LOG. Each printf is one
# small write() call, atomic under O_APPEND regardless of who else holds the
# lock, so the log is safe to append to even while proving the lock broken.
RACER="$TMPROOT/racer.sh"
cat >"$RACER" <<'RACER_EOF'
#!/usr/bin/env bash
set -uo pipefail
# Sub-second epoch time, nanosecond-ish precision: `date +%s%N` has no
# nanoseconds on BSD/macOS (it just prints a literal "N"). Prefer bash's own
# $EPOCHREALTIME (seconds.microseconds, bash 5+), then python3, then perl.
# FAIL loudly rather than silently falling back to whole-second precision,
# which would make the overlap check meaningless.
now_ns() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    printf '%s%06d000\n' "${EPOCHREALTIME%.*}" "$((10#${EPOCHREALTIME#*.}))"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time()*1e9))'
  elif command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf("%d\n", time()*1e9)'
  else
    return 1
  fi
}
source "${AFK_SUITE_LOCK_SRC:?}"
afk_test_lock_acquire; rc=$?
(( rc != 0 )) && exit "$rc"
ts="$(now_ns)" || { echo "FATAL: no sub-second clock available (need bash 5+, python3 or perl)" >&2; exit 2; }
printf 'START %s %s\n' "$$" "$ts" >>"${AFK_RACE_LOG:?}"
sleep "${1:-0.03}"
ts="$(now_ns)" || { echo "FATAL: no sub-second clock available (need bash 5+, python3 or perl)" >&2; exit 2; }
printf 'END %s %s\n' "$$" "$ts" >>"${AFK_RACE_LOG:?}"
afk_test_lock_release
RACER_EOF
chmod +x "$RACER"

# Any two [START,END] intervals in $1 belonging to different pids must not
# overlap. Exit 0 = no overlap, 1 = overlap found (also prints which pids).
check_no_overlap() { # <race-log>
  awk '
    $1=="START"{s[$2]=$3}
    $1=="END"{e[$2]=$3}
    END{
      n=0
      for (p in s) if (p in e) pids[n++]=p
      bad=0
      for (i=0;i<n;i++) for (j=i+1;j<n;j++) {
        a=pids[i]; b=pids[j]
        if (s[a] < e[b] && s[b] < e[a]) { bad=1; printf "OVERLAP pid=%s pid=%s\n", a, b }
      }
      exit bad
    }
  ' "$1"
}

# 1+2: a second holder waits, and prints the holder line while it does.
LP="$TMPROOT/lock1"
AFK_TEST_LOCK_PATH="$LP" bash "$LOCKER" 1.5 >"$TMPROOT/h1.out" 2>&1 &
h1=$!
sleep 0.3; t0=$SECONDS
AFK_TEST_LOCK_PATH="$LP" bash "$LOCKER" 0 >"$TMPROOT/h2.out" 2>&1
elapsed=$((SECONDS - t0)); wait "$h1"
if grep -q ACQUIRED "$TMPROOT/h2.out" && (( elapsed >= 1 )); then
  ok "second holder blocked until the first released (${elapsed}s)"
else
  bad "second holder blocked until the first released" "elapsed=${elapsed}s out=$(cat "$TMPROOT/h2.out")"
fi
if grep -q '^waiting on suite lock, held by: pid=' "$TMPROOT/h2.out"; then
  ok "holder line names pid/cwd/start while waiting"
else
  bad "holder line names pid/cwd/start while waiting" "$(cat "$TMPROOT/h2.out")"
fi

# 3: the timeout exits 3.
LP="$TMPROOT/lock3"
AFK_TEST_LOCK_PATH="$LP" bash "$LOCKER" 3 >/dev/null 2>&1 &
h1=$!
sleep 0.3
AFK_TEST_LOCK_PATH="$LP" AFK_TEST_LOCK_TIMEOUT=1 bash "$LOCKER" 0 >"$TMPROOT/h2.out" 2>&1; rc=$?; wait "$h1"
if (( rc == 3 )) && grep -q 'timed out' "$TMPROOT/h2.out"; then
  ok "timeout exits 3 with a clear message"
else
  bad "timeout exits 3 with a clear message" "rc=$rc out=$(cat "$TMPROOT/h2.out")"
fi

# 4: a stale mkdir lock with a dead pid is reclaimed, not waited out.
# The dead pid is a subshell that disables its OWN inherited EXIT trap and
# then exits on its own — no external kill, so there's no race between that
# signal and the subshell's first statement; killing it instead intermittently
# fired our EXIT trap (rm -rf "$TMPROOT") from inside the subshell if the
# signal arrived before it ran anything, corrupting an unrelated later test.
LP="$TMPROOT/lock4"; mkdir "$LP.d"
( trap '' EXIT; exit 0 ) & deadpid=$!; wait "$deadpid" 2>/dev/null
echo "$deadpid" >"$LP.d/pid"; echo "pid=$deadpid cwd=/nowhere start=1970-01-01T00:00:00Z" >"$LP.d/holder"
t0=$SECONDS
AFK_TEST_LOCK_PATH="$LP" AFK_TEST_LOCK_FORCE_MKDIR=1 AFK_TEST_LOCK_TIMEOUT=5 bash "$LOCKER" 0 >"$TMPROOT/h.out" 2>&1
rc=$?; elapsed=$((SECONDS - t0))
if (( rc == 0 )) && grep -q ACQUIRED "$TMPROOT/h.out" && (( elapsed < 5 )); then
  ok "stale mkdir lock (dead pid) reclaimed without waiting for the timeout"
else
  bad "stale mkdir lock (dead pid) reclaimed" "rc=$rc elapsed=${elapsed}s out=$(cat "$TMPROOT/h.out")"
fi

# 5: AFK_TEST_LOCK=off bypasses the lock.
LP="$TMPROOT/lock5"
AFK_TEST_LOCK_PATH="$LP" bash "$LOCKER" 1.5 >/dev/null 2>&1 &
h1=$!
sleep 0.3; t0=$SECONDS
AFK_TEST_LOCK=off AFK_TEST_LOCK_PATH="$LP" bash "$LOCKER" 0 >"$TMPROOT/h2.out" 2>&1
elapsed=$((SECONDS - t0)); wait "$h1"
if grep -q ACQUIRED "$TMPROOT/h2.out" && (( elapsed < 2 )); then
  ok "AFK_TEST_LOCK=off bypasses the lock (${elapsed}s)"
else
  bad "AFK_TEST_LOCK=off bypasses the lock" "elapsed=${elapsed}s out=$(cat "$TMPROOT/h2.out")"
fi

# 6: a nested child (AFK_TEST_LOCK_NESTED=1) does not re-take the lock.
LP="$TMPROOT/lock6"
AFK_TEST_LOCK_PATH="$LP" bash "$LOCKER" 1.5 >/dev/null 2>&1 &
h1=$!
sleep 0.3; t0=$SECONDS
AFK_TEST_LOCK_PATH="$LP" AFK_TEST_LOCK_NESTED=1 bash "$LOCKER" 0 >"$TMPROOT/h2.out" 2>&1
elapsed=$((SECONDS - t0)); wait "$h1"
if grep -q ACQUIRED "$TMPROOT/h2.out" && (( elapsed < 2 )); then
  ok "a nested child (AFK_TEST_LOCK_NESTED=1) does not re-take the lock"
else
  bad "a nested child does not re-take the lock" "elapsed=${elapsed}s out=$(cat "$TMPROOT/h2.out")"
fi

# 7: BLOCKER regression — N=14 racers against a seeded dead-pid mkdir lock,
# repeated for 3 rounds, must never let two critical sections overlap. A tight
# AFK_TEST_LOCK_POLL_S keeps this within ~10s despite N racers serializing
# through 1s-granularity waits by default.
N=14
overlap_seen=0
racer_fail=0
for round in 1 2 3; do
  LP="$TMPROOT/lock7-$round"; mkdir "$LP.d"
  ( trap '' EXIT; exit 0 ) & deadpid=$!; wait "$deadpid" 2>/dev/null
  echo "$deadpid" >"$LP.d/pid"; echo "pid=$deadpid cwd=/nowhere start=1970-01-01T00:00:00Z" >"$LP.d/holder"
  RACELOG="$TMPROOT/race-$round.log"; : >"$RACELOG"
  pids=()
  for ((i = 0; i < N; i++)); do
    AFK_TEST_LOCK_PATH="$LP" AFK_TEST_LOCK_FORCE_MKDIR=1 AFK_TEST_LOCK_POLL_S=0.02 \
      AFK_RACE_LOG="$RACELOG" bash "$RACER" 0.03 >"$TMPROOT/racer-$round-$i.err" 2>&1 &
    pids+=("$!")
  done
  for p in "${pids[@]}"; do wait "$p" || racer_fail=1; done
  check_no_overlap "$RACELOG" || overlap_seen=1
done
if (( racer_fail != 0 )); then
  bad "N=$N racers x 3 rounds: every racer ran cleanly" \
    "at least one racer exited non-zero (e.g. no sub-second clock available) — see $TMPROOT/racer-*.err"
elif (( overlap_seen == 0 )); then
  ok "N=$N racers x 3 rounds against a dead-pid mkdir lock: no two critical sections overlap"
else
  bad "N=$N racers x 3 rounds: no overlap" "an overlap was detected — see above"
fi

# 8: MAJOR regression — the holder spawns a setsid-detached sleeping child
# (with the lock fd closed for it, exactly as run_gate/run_dispatch now do
# for every child they launch), then exits; a second acquirer must get the
# lock PROMPTLY even though the detached grandchild is still alive. Needs
# `setsid`; skip cleanly (not a silent pass) where it's unavailable, and FAIL
# rather than pass if it ran but never actually produced the grandchild we
# meant to prove is still alive.
if ! command -v setsid >/dev/null 2>&1; then
  skip "second acquirer gets the lock promptly after the holder exits (no setsid on this host)"
else
  LP="$TMPROOT/lock8"
  HOLDER_FD="$TMPROOT/holder_fd.sh"
  cat >"$HOLDER_FD" <<'HOLDER_EOF'
#!/usr/bin/env bash
set -uo pipefail
source "${AFK_SUITE_LOCK_SRC:?}"
afk_test_lock_acquire; rc=$?
(( rc != 0 )) && exit "$rc"
echo ACQUIRED
setsid bash -c 'echo $$ > "'"$1"'"; sleep 20' {AFK_TEST_LOCK_FD}<&- </dev/null >/dev/null 2>&1 &
disown
afk_test_lock_release
HOLDER_EOF
  chmod +x "$HOLDER_FD"
  GCPID_FILE="$TMPROOT/grandchild.pid"
  AFK_TEST_LOCK_PATH="$LP" bash "$HOLDER_FD" "$GCPID_FILE" >"$TMPROOT/h8.out" 2>&1
  for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$GCPID_FILE" ]] && break; sleep 0.1; done
  gcpid="$(cat "$GCPID_FILE" 2>/dev/null || true)"
  t0=$SECONDS
  AFK_TEST_LOCK_PATH="$LP" AFK_TEST_LOCK_TIMEOUT=5 bash "$LOCKER" 0 >"$TMPROOT/h8b.out" 2>&1
  rc=$?; elapsed=$((SECONDS - t0))
  alive="no"; [[ -n "$gcpid" ]] && kill -0 "$gcpid" 2>/dev/null && alive="yes"
  if [[ -z "$gcpid" ]]; then
    bad "second acquirer gets the lock promptly after the holder exits" \
      "the detached grandchild never wrote its pid file — this run proves nothing, not a pass"
  elif (( rc == 0 )) && grep -q ACQUIRED "$TMPROOT/h8b.out" && (( elapsed < 2 )) && [[ "$alive" == yes ]]; then
    ok "second acquirer gets the lock promptly (${elapsed}s) after the holder exits, detached grandchild alive=$alive"
  else
    bad "second acquirer gets the lock promptly after the holder exits" \
      "rc=$rc elapsed=${elapsed}s grandchild_alive=$alive out=$(cat "$TMPROOT/h8b.out")"
  fi
  [[ -n "$gcpid" ]] && kill -9 "$gcpid" 2>/dev/null
fi

# Backdate a path's mtime by <seconds> (GNU touch, with a BSD/macOS fallback).
backdate() { # <path> <seconds-ago>
  local past=$(( $(date +%s) - $2 ))
  touch -d "@$past" "$1" 2>/dev/null ||
    touch -t "$(date -r "$past" +%Y%m%d%H%M.%S 2>/dev/null)" "$1"
}

# 9a: MAJOR regression — a holder that dies between `mkdir` and writing its
# pid leaves an empty, permanently-unreclaimable-by-the-old-code directory.
# After the grace period, a new acquirer reclaims it.
LP="$TMPROOT/lock9a"; mkdir "$LP.d"
backdate "$LP.d" 5
t0=$SECONDS
AFK_TEST_LOCK_PATH="$LP" AFK_TEST_LOCK_FORCE_MKDIR=1 AFK_TEST_LOCK_EMPTY_GRACE_S=2 \
  AFK_TEST_LOCK_TIMEOUT=5 bash "$LOCKER" 0 >"$TMPROOT/h9a.out" 2>&1
rc=$?; elapsed=$((SECONDS - t0))
if (( rc == 0 )) && grep -q ACQUIRED "$TMPROOT/h9a.out" && (( elapsed < 5 )); then
  ok "empty mkdir lock older than the grace period is reclaimed (${elapsed}s)"
else
  bad "empty mkdir lock older than the grace period is reclaimed" \
    "rc=$rc elapsed=${elapsed}s out=$(cat "$TMPROOT/h9a.out")"
fi

# 9b: a FRESH empty directory (within the grace period) must NOT be
# reclaimed — a short timeout against it must time out, not succeed.
LP="$TMPROOT/lock9b"; mkdir "$LP.d"
AFK_TEST_LOCK_PATH="$LP" AFK_TEST_LOCK_FORCE_MKDIR=1 AFK_TEST_LOCK_EMPTY_GRACE_S=30 \
  AFK_TEST_LOCK_TIMEOUT=1 bash "$LOCKER" 0 >"$TMPROOT/h9b.out" 2>&1
rc=$?
if (( rc == 3 )) && ! grep -q ACQUIRED "$TMPROOT/h9b.out"; then
  ok "a fresh empty mkdir lock (within grace) is not reclaimed"
else
  bad "a fresh empty mkdir lock (within grace) is not reclaimed" \
    "rc=$rc out=$(cat "$TMPROOT/h9b.out")"
fi
rm -rf "$LP.d"

# 10: MINOR regression — the mkdir-fallback timeout is elapsed WALL TIME, not
# a count of poll iterations: POLL_S=0.02 with TIMEOUT=2 must take ~2s, not
# ~14*0.02s.
LP="$TMPROOT/lock10"
AFK_TEST_LOCK_PATH="$LP" AFK_TEST_LOCK_FORCE_MKDIR=1 bash "$LOCKER" 5 >/dev/null 2>&1 &
h1=$!
sleep 0.3; t0=$SECONDS
AFK_TEST_LOCK_PATH="$LP" AFK_TEST_LOCK_FORCE_MKDIR=1 AFK_TEST_LOCK_POLL_S=0.02 \
  AFK_TEST_LOCK_TIMEOUT=2 bash "$LOCKER" 0 >"$TMPROOT/h10.out" 2>&1
rc=$?; elapsed=$((SECONDS - t0)); kill "$h1" 2>/dev/null; wait "$h1" 2>/dev/null
if (( rc == 3 )) && (( elapsed >= 2 && elapsed <= 4 )); then
  ok "timeout is elapsed wall time, not poll-iteration count (${elapsed}s for TIMEOUT=2)"
else
  bad "timeout is elapsed wall time, not poll-iteration count" \
    "rc=$rc elapsed=${elapsed}s out=$(cat "$TMPROOT/h10.out")"
fi

# 11a: MAJOR regression — a reclaimer that died holding "$lockdir.d.reclaim"
# orphans that mutex. Pre-create it, backdated past the grace period,
# alongside a dead-pid lock: a waiter must still reclaim (not hang forever
# spinning on a failed mkdir), within about the grace period.
LP="$TMPROOT/lock11a"; mkdir "$LP.d"
( trap '' EXIT; exit 0 ) & deadpid=$!; wait "$deadpid" 2>/dev/null
echo "$deadpid" >"$LP.d/pid"; echo "pid=$deadpid cwd=/nowhere start=1970-01-01T00:00:00Z" >"$LP.d/holder"
mkdir "$LP.d.reclaim"; backdate "$LP.d.reclaim" 5
t0=$SECONDS
AFK_TEST_LOCK_PATH="$LP" AFK_TEST_LOCK_FORCE_MKDIR=1 AFK_TEST_LOCK_EMPTY_GRACE_S=2 \
  AFK_TEST_LOCK_POLL_S=0.1 AFK_TEST_LOCK_TIMEOUT=5 bash "$LOCKER" 0 >"$TMPROOT/h11a.out" 2>&1
rc=$?; elapsed=$((SECONDS - t0))
if (( rc == 0 )) && grep -q ACQUIRED "$TMPROOT/h11a.out" && (( elapsed <= 3 )); then
  ok "a waiter reclaims an orphaned .reclaim mutex within about the grace period (${elapsed}s)"
else
  bad "a waiter reclaims an orphaned .reclaim mutex within about the grace period" \
    "rc=$rc elapsed=${elapsed}s out=$(cat "$TMPROOT/h11a.out")"
fi

# 11b: the same orphaned-.reclaim scenario, but the mutex is FRESH (younger
# than grace) — nothing can reclaim it yet, so TIMEOUT must still fire. Before
# the fix, the failed reclaim mkdir fell straight into `continue` with no
# sleep and no timeout check: this hung the process spinning at 100% CPU
# forever instead of exiting 3.
LP="$TMPROOT/lock11b"; mkdir "$LP.d"
( trap '' EXIT; exit 0 ) & deadpid=$!; wait "$deadpid" 2>/dev/null
echo "$deadpid" >"$LP.d/pid"; echo "pid=$deadpid cwd=/nowhere start=1970-01-01T00:00:00Z" >"$LP.d/holder"
mkdir "$LP.d.reclaim"
t0=$SECONDS
timeout 10 env AFK_TEST_LOCK_PATH="$LP" AFK_TEST_LOCK_FORCE_MKDIR=1 AFK_TEST_LOCK_EMPTY_GRACE_S=5 \
  AFK_TEST_LOCK_POLL_S=0.1 AFK_TEST_LOCK_TIMEOUT=1 bash "$LOCKER" 0 >"$TMPROOT/h11b.out" 2>&1
rc=$?; elapsed=$((SECONDS - t0))
if (( rc == 3 )) && ! grep -q ACQUIRED "$TMPROOT/h11b.out" && (( elapsed >= 1 && elapsed <= 5 )); then
  ok "TIMEOUT still fires while an orphaned .reclaim mutex hasn't aged past grace (${elapsed}s, no hang)"
else
  bad "TIMEOUT still fires while an orphaned .reclaim mutex hasn't aged past grace" \
    "rc=$rc elapsed=${elapsed}s out=$(cat "$TMPROOT/h11b.out")"
fi
rm -rf "$LP.d" "$LP.d.reclaim" 2>/dev/null

if (( SKIPPED > 0 )); then
  printf '\n\033[1m%d passed, %d failed, %d skipped\033[0m\n' "$PASS" "$FAIL" "$SKIPPED"
else
  printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
fi
(( FAIL == 0 )) || exit 1
