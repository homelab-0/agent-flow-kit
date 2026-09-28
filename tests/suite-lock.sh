# suite-lock.sh — AFK-TP-4 AC-1 host-wide suite lock, shared verbatim by
# tests/run-tests.sh, tests/lifecycle-mutation-tests.sh and
# tests/runner-lock-tests.sh (each `source`s this; it is not standalone).
#
# `flock` where available; a race-safe `mkdir` fallback (dead-holder reclaim
# via a second, contended mkdir, re-checked under that mutex) where it isn't.
# AFK_TEST_LOCK_NESTED=1 is set once held so a child suite the caller launches
# does not take it again; AFK_TEST_LOCK=off bypasses it for CI;
# AFK_TEST_LOCK_TIMEOUT bounds the wait (exit 3). AFK_TEST_LOCK_PATH overrides
# the path for hermetic tests, and AFK_TEST_LOCK_POLL_S overrides the mkdir
# fallback's 1s poll interval for a tight contention test. AFK_TEST_LOCK_FD is
# always a valid fd number (real once held via flock, a harmless placeholder
# otherwise) so a caller can
# unconditionally close it for a child with `{AFK_TEST_LOCK_FD}<&-` — the fd
# is NOT close-on-exec by default and a detached grandchild that outlives the
# caller would otherwise keep the flock held after the caller exits.
# AFK_TEST_LOCK_EMPTY_GRACE_S (default 30) bounds how long an mkdir'd
# directory may sit with no pid file before a reclaimer may consider it dead
# rather than merely being written by its holder right now.
AFK_TEST_LOCK_FD=63
AFK_TEST_LOCK_MKDIR=""

# Portable mtime in epoch seconds (GNU vs. BSD stat), or empty on failure —
# callers must guard on that emptiness rather than let an arithmetic
# comparison silently misbehave.
afk_test_lock_mtime() { # <path>
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

afk_test_lock_acquire() {
  [[ "${AFK_TEST_LOCK:-}" == "off" || "${AFK_TEST_LOCK_NESTED:-}" == "1" ]] && return 0
  local lockdir="${AFK_TEST_LOCK_PATH:-${XDG_RUNTIME_DIR:-/tmp}/agent-flow-kit-test-suite.lock}"
  local timeout="${AFK_TEST_LOCK_TIMEOUT:-0}" wait_start=$SECONDS ownerpid printed=0 recheck
  local grace="${AFK_TEST_LOCK_EMPTY_GRACE_S:-30}" dir_age now_epoch
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
    while true; do
      if mkdir "$lockdir.d" 2>/dev/null; then
        # Won the dir. Write our pid ATOMICALLY (temp file + mv within the
        # same dir) so no reader ever sees a partially-written pid file, then
        # verify it's really ours before proceeding.
        printf '%s' "$$" >"$lockdir.d/pid.$$.tmp" && mv -f "$lockdir.d/pid.$$.tmp" "$lockdir.d/pid"
        printf '%s\n' "$mine" >"$lockdir.d/holder"
        if [[ "$(cat "$lockdir.d/pid" 2>/dev/null)" == "$$" ]]; then
          AFK_TEST_LOCK_MKDIR="$lockdir.d"
          break
        fi
        continue
      fi
      # Someone else holds (or is still writing into) the dir. This read is
      # only an OBSERVATION — never acted on directly; only a won reclaim
      # mutex, which re-reads, may delete anything.
      ownerpid="$(cat "$lockdir.d/pid" 2>/dev/null || true)"
      if [[ -n "$ownerpid" ]] && ! kill -0 "$ownerpid" 2>/dev/null; then
        # Candidate stale. Only the process that wins this second, contended
        # mkdir may act, and it MUST re-read under that mutex and confirm the
        # pid is STILL the same dead one before deleting — a live holder can
        # have taken the dir over (new mkdir, different live pid) in the gap
        # between the observation above and now.
        if mkdir "$lockdir.d.reclaim" 2>/dev/null; then
          recheck="$(cat "$lockdir.d/pid" 2>/dev/null || true)"
          if [[ -n "$recheck" && "$recheck" == "$ownerpid" ]] && ! kill -0 "$recheck" 2>/dev/null; then
            rm -rf "$lockdir.d"
          fi
          rmdir "$lockdir.d.reclaim"
        fi
        continue
      fi
      if [[ -z "$ownerpid" ]]; then
        # No pid file yet — either the holder is still writing it (a normal,
        # brief moment: never reclaim on this alone), or the holder died
        # between winning the mkdir and writing its pid, in which case NO
        # pid ever appears and the live-pid staleness check above can never
        # fire — a permanent hang otherwise. After a grace period, an
        # empty, sufficiently OLD directory is reclaimable too, under the
        # same re-checked mutex: re-confirm it is STILL empty and STILL that
        # old before deleting, exactly as the dead-pid path re-confirms.
        dir_age="$(afk_test_lock_mtime "$lockdir.d")"
        if [[ -n "$dir_age" ]] && (( $(date +%s) - dir_age >= grace )); then
          if mkdir "$lockdir.d.reclaim" 2>/dev/null; then
            recheck="$(cat "$lockdir.d/pid" 2>/dev/null || true)"
            now_epoch="$(afk_test_lock_mtime "$lockdir.d")"
            if [[ -z "$recheck" && -n "$now_epoch" ]] && (( $(date +%s) - now_epoch >= grace )); then
              rm -rf "$lockdir.d"
            fi
            rmdir "$lockdir.d.reclaim"
          fi
          continue
        fi
      fi
      if (( printed == 0 )); then
        printf 'waiting on suite lock, held by: %s\n' "$(cat "$lockdir.d/holder" 2>/dev/null || echo unknown)"
        printed=1
      fi
      (( timeout > 0 && SECONDS - wait_start >= timeout )) &&
        { printf 'suite lock wait timed out after %ss\n' "$timeout" >&2; return 3; }
      sleep "${AFK_TEST_LOCK_POLL_S:-1}"
    done
  fi
  export AFK_TEST_LOCK_NESTED=1
  return 0
}
afk_test_lock_release() { [[ -n "$AFK_TEST_LOCK_MKDIR" ]] && rm -rf "$AFK_TEST_LOCK_MKDIR"; }
