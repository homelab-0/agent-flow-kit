#!/usr/bin/env bash
# runner-lock-tests.sh — hermetic gate for the AFK-TP-4 AC-1 host-wide suite
# lock, against its own lock path under mktemp (never the real one). The
# locker below is the same acquire/release algorithm carried in
# tests/run-tests.sh and tests/lifecycle-mutation-tests.sh; each of those runs
# as its own `bash` process, so it cannot be sourced across them and is proven
# here against a standalone copy driven by real background processes.
#
# Usage: tests/runner-lock-tests.sh
# Exit:  0 all passed, 1 any failure.

set -uo pipefail

# When run-tests.sh launches this as its own child gate, it has already
# exported AFK_TEST_LOCK_NESTED=1 for ITS OWN chain of child suites — that
# marker must not leak into the independent lockers this gate spawns below,
# or every one of them silently bypasses the lock it exists to test.
unset AFK_TEST_LOCK_NESTED AFK_TEST_LOCK

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0 FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

# Reads the same env knobs the production copies do: AFK_TEST_LOCK_PATH,
# AFK_TEST_LOCK_TIMEOUT, AFK_TEST_LOCK=off, AFK_TEST_LOCK_NESTED=1,
# AFK_TEST_LOCK_FORCE_MKDIR=1. Acquires, prints ACQUIRED, sleeps $1s, releases,
# prints RELEASED; exits with the acquire function's own code on failure.
LOCKER="$TMPROOT/locker.sh"
cat >"$LOCKER" <<'LOCKER_EOF'
#!/usr/bin/env bash
set -uo pipefail
AFK_TEST_LOCK_MKDIR=""
afk_test_lock_acquire() {
  [[ "${AFK_TEST_LOCK:-}" == "off" || "${AFK_TEST_LOCK_NESTED:-}" == "1" ]] && return 0
  local lockdir="${AFK_TEST_LOCK_PATH:?}"
  local timeout="${AFK_TEST_LOCK_TIMEOUT:-0}" waited=0 ownerpid printed=0
  local mine; mine="pid=$$ cwd=$PWD start=$(date -u +%FT%TZ)"
  if [[ "${AFK_TEST_LOCK_FORCE_MKDIR:-}" != "1" ]] && command -v flock >/dev/null 2>&1; then
    exec {AFK_TEST_LOCK_FD}<>"$lockdir"
    if ! flock -n "$AFK_TEST_LOCK_FD" 2>/dev/null; then
      printf 'waiting on suite lock, held by: %s\n' "$(cat "$lockdir" 2>/dev/null || echo unknown)"
      if (( timeout > 0 )); then
        flock -w "$timeout" "$AFK_TEST_LOCK_FD" 2>/dev/null ||
          { printf 'suite lock wait timed out after %ss\n' "$timeout" >&2; return 3; }
      else
        flock "$AFK_TEST_LOCK_FD"
      fi
    fi
    printf '%s\n' "$mine" >"$lockdir"
  else
    while ! mkdir "$lockdir.d" 2>/dev/null; do
      ownerpid="$(cat "$lockdir.d/pid" 2>/dev/null || true)"
      if [[ -n "$ownerpid" ]] && ! kill -0 "$ownerpid" 2>/dev/null; then
        if mkdir "$lockdir.d.reclaim" 2>/dev/null; then rm -rf "$lockdir.d"; rmdir "$lockdir.d.reclaim"; fi
        continue
      fi
      if (( printed == 0 )); then
        printf 'waiting on suite lock, held by: %s\n' "$(cat "$lockdir.d/holder" 2>/dev/null || echo unknown)"
        printed=1
      fi
      (( timeout > 0 && waited >= timeout )) &&
        { printf 'suite lock wait timed out after %ss\n' "$timeout" >&2; return 3; }
      sleep 1; waited=$((waited + 1))
    done
    echo "$$" >"$lockdir.d/pid"; printf '%s\n' "$mine" >"$lockdir.d/holder"
    AFK_TEST_LOCK_MKDIR="$lockdir.d"
  fi
  export AFK_TEST_LOCK_NESTED=1
  return 0
}
afk_test_lock_release() { [[ -n "$AFK_TEST_LOCK_MKDIR" ]] && rm -rf "$AFK_TEST_LOCK_MKDIR"; }
afk_test_lock_acquire; rc=$?
(( rc != 0 )) && exit "$rc"
echo ACQUIRED; sleep "${1:-0}"; afk_test_lock_release; echo RELEASED
LOCKER_EOF
chmod +x "$LOCKER"

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
LP="$TMPROOT/lock4"; mkdir "$LP.d"
( sleep 30 ) & deadpid=$!; kill "$deadpid" 2>/dev/null; wait "$deadpid" 2>/dev/null
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
if grep -q ACQUIRED "$TMPROOT/h2.out" && (( elapsed < 1 )); then
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
if grep -q ACQUIRED "$TMPROOT/h2.out" && (( elapsed < 1 )); then
  ok "a nested child (AFK_TEST_LOCK_NESTED=1) does not re-take the lock"
else
  bad "a nested child does not re-take the lock" "elapsed=${elapsed}s out=$(cat "$TMPROOT/h2.out")"
fi

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
