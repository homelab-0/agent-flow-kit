#!/usr/bin/env bash
# lockctl-helper.sh — a single-purpose driver for the operation lock, used by
# tests/lifecycle-concurrency-tests.sh to put several REAL processes on the
# same lock at the same time.
#
# Usage: lockctl-helper.sh <kit-root> <state-dir> <verb> [args...]
#
# Every verb prints one `key=value` line per fact it establishes, so a caller
# reads the outcome without parsing prose.

set -uo pipefail

KIT="$1"; shift
STATE="$1"; shift

# shellcheck source=/dev/null
. "$KIT/lib/afk-common.sh"
# shellcheck source=/dev/null
. "$KIT/lib/afk-source.sh"
# shellcheck source=/dev/null
. "$KIT/lib/afk-inventory.sh"
# shellcheck source=/dev/null
. "$KIT/lib/afk-commands.sh"
# shellcheck source=/dev/null
. "$KIT/lib/afk-plan.sh"
# shellcheck source=/dev/null
. "$KIT/lib/afk-mutate.sh"

AFK_STATE_DIR="$STATE"
AFK_LOCK_DIR="$STATE/lock"

# A wait that never blocks the suite forever and never calls sleep: the whole
# point of these fixtures is that they are bounded even when they fail.
spin_until() { # <path>
  local i=0
  while [[ ! -e "$1" ]]; do
    i=$((i + 1))
    (( i < 40000000 )) || return 1
  done
  return 0
}

burn() { local i=0; while (( i < 30000 )); do i=$((i + 1)); done; }

lock_inc() { afk_lock_incarnation_at "$AFK_LOCK_DIR/owner.json" 2>/dev/null || printf ''; }

# Everything an acquisition establishes, including how much of the publication
# wait budget it actually spent: `publish_waits=0` on a refusal is the proof
# that a lock which cannot be judged is still refused without latency.
report_acquire() { # <rc>
  local left="${AFK_LOCK_PUBLISH_SLICES_LEFT:-}" total="${AFK_LOCK_PUBLISH_WAIT_SLICES:-}"
  printf 'rc=%s\n' "$1"
  printf 'reclaimed=%s\n' "$AFK_LOCK_RECLAIMED"
  printf 'inc=%s\n' "$AFK_LOCK_INCARNATION"
  printf 'owner_state=%s\n' "$AFK_LOCK_OWNER_STATE"
  printf 'owner_detail=%s\n' "$AFK_LOCK_OWNER_DETAIL"
  if [[ -n "$left" && -n "$total" ]]; then
    printf 'publish_waits=%s\n' "$(( total - left ))"
  else
    printf 'publish_waits=unsupported\n'
  fi
}

# Hold the LOSS of the arbitration marker open. `afk_lock_marker_claim` is
# replaced by a wrapper that calls the real one — copied out first, so not one
# line of the claim is a fixture's — and then, only when the claim was lost,
# announces itself and stands still until the caller says go. Whatever the
# caller does to the marker meanwhile happens strictly between the claim and
# the judge that reads it, which is the interleaving a barrier cannot produce.
AFK_TEST_LOST=""
AFK_TEST_GO=""
hold_lost_marker_claim() { # <lost-file> <go-file>
  AFK_TEST_LOST="$1"; AFK_TEST_GO="$2"
  eval "afk_lock_marker_claim_real() $(declare -f afk_lock_marker_claim | tail -n +2)"
  afk_lock_marker_claim() {
    local r=0
    afk_lock_marker_claim_real "$@" || r=$?
    if (( r == 1 )); then
      : > "$AFK_TEST_LOST"
      spin_until "$AFK_TEST_GO" || true
    fi
    return "$r"
  }
}

verb="$1"; shift
rc=0
inc=""
record=""

case "$verb" in
  # Acquire, publish this process as an owner, observe how many owners are
  # published at the same moment, then stand down. The peak count is the
  # mutual-exclusion assertion.
  contend) # <barrier-dir> <owners-dir> <id>
    bar="$1"; owners="$2"; id="$3"
    : > "$bar/ready.$id"
    spin_until "$bar/go" || { printf 'rc=98\n'; exit 0; }
    afk_lock_acquire || rc=$?
    printf 'rc=%s\n' "$rc"
    printf 'reclaimed=%s\n' "$AFK_LOCK_RECLAIMED"
    printf 'inc=%s\n' "$AFK_LOCK_INCARNATION"
    if (( rc == 0 )); then
      : > "$owners/$id"
      peak=0
      for _ in 1 2 3 4 5; do
        n="$(find "$owners" -mindepth 1 -maxdepth 1 | wc -l)"
        (( n > peak )) && peak="$n"
        burn
      done
      printf 'peak=%s\n' "$peak"
      printf 'held_inc_on_disk=%s\n' "$(lock_inc)"
      rm -f -- "$owners/$id"
      afk_lock_release || true
      printf 'released=%s\n' "$AFK_LOCK_RELEASED"
    fi
    ;;

  # Take the lock and exit without releasing it: on return the lock is held by
  # a pid that no longer exists, which is the abandoned-lock fixture.
  strand)
    afk_lock_take || rc=$?
    printf 'rc=%s\n' "$rc"
    printf 'inc=%s\n' "$AFK_LOCK_INCARNATION"
    ;;

  # Acquire and hold until told to let go, staying alive throughout, so the
  # owner is provably LIVE for as long as the caller needs.
  park) # <ready-file> <go-file>
    afk_lock_acquire || rc=$?
    printf 'rc=%s\n' "$rc"
    printf 'reclaimed=%s\n' "$AFK_LOCK_RECLAIMED"
    printf 'inc=%s\n' "$AFK_LOCK_INCARNATION"
    : > "$1"
    spin_until "$2" || true
    afk_lock_release || true
    printf 'released=%s\n' "$AFK_LOCK_RELEASED"
    printf 'lock_after=%s\n' "$(afk_lock_state)"
    ;;

  acquire)
    afk_lock_acquire || rc=$?
    report_acquire "$rc"
    (( rc != 0 )) || { afk_lock_release || true; printf 'released=%s\n' "$AFK_LOCK_RELEASED"; }
    ;;

  # Acquire, but announce first: the caller learns the exact moment this
  # process is about to observe the lock, so an interleaving can be set up
  # around the observation instead of hoped for.
  acquire-announced) # <ready-file>
    : > "$1"
    afk_lock_acquire || rc=$?
    report_acquire "$rc"
    (( rc != 0 )) || { afk_lock_release || true; printf 'released=%s\n' "$AFK_LOCK_RELEASED"; }
    ;;

  # Take the lock in its two real steps with the PUBLICATION WINDOW held open:
  # the directory is created, the caller is told the window is open, and the
  # owner record is written only when the caller says so. Every byte of the
  # record still comes from the library, so the fixture cannot drift from what
  # the lock really writes -- only the timing between the two steps is the
  # caller's. The process stays alive afterwards, so the owner it names is
  # provably LIVE for as long as the caller needs it to be.
  publish-slowly) # <window-open-file> <publish-file> <let-go-file>
    inc="$(afk_lock_incarnation_new)" || { printf 'rc=1\n'; exit 0; }
    record="$(afk_lock_owner_record "$inc")" || { printf 'rc=1\n'; exit 0; }
    mkdir -- "$AFK_LOCK_DIR" 2>/dev/null || { printf 'rc=1\n'; exit 0; }
    chmod 700 -- "$AFK_LOCK_DIR" 2>/dev/null || true
    printf 'inc=%s\n' "$inc"
    : > "$1"
    spin_until "$2" || true
    afk_state_file_write "$AFK_LOCK_DIR/owner.json" "$record" || rc=1
    AFK_LOCK_HELD="true"
    AFK_LOCK_INCARNATION="$inc"
    printf 'rc=%s\n' "$rc"
    printf 'published_inc=%s\n' "$(lock_inc)"
    spin_until "$3" || true
    afk_lock_release || true
    printf 'released=%s\n' "$AFK_LOCK_RELEASED"
    ;;

  judge)
    afk_lock_evaluate
    printf 'state=%s\n' "$AFK_LOCK_OWNER_STATE"
    printf 'detail=%s\n' "$AFK_LOCK_OWNER_DETAIL"
    printf 'inc=%s\n' "$AFK_LOCK_OWNER_INCARNATION"
    ;;

  reclaim) # <incarnation>
    afk_lock_reclaim "$1" || rc=$?
    printf 'rc=%s\n' "$rc"
    printf 'inc=%s\n' "$AFK_LOCK_INCARNATION"
    printf 'lock_inc_after=%s\n' "$(lock_inc)"
    ;;

  # Reclaim <incarnation>, and LOSE the take that follows the destruction: a
  # contender creates the lock path in the window between the abandoned lock
  # being renamed aside and this process's own mkdir. `afk_lock_take` is
  # wrapped rather than replaced -- the real one still runs, and still loses --
  # so what is asserted is what the real reclamation reports when the lock it
  # destroyed is taken by somebody else.
  reclaim-losing-take) # <incarnation>
    eval "afk_lock_take_real() $(declare -f afk_lock_take | tail -n +2)"
    afk_lock_take() {
      if [[ ! -e "$STATE/stolen" ]]; then
        mkdir -- "$AFK_LOCK_DIR" 2>/dev/null && printf 'stolen' > "$STATE/stolen"
      fi
      afk_lock_take_real
    }
    afk_lock_reclaim "$1" || rc=$?
    printf 'rc=%s\n' "$rc"
    printf 'reclaimed=%s\n' "$AFK_LOCK_RECLAIMED"
    printf 'reclaim_reports=%s\n' \
      "$(printf '%s' "${AFK_LOCK_RECLAIMED_DETAILS:-}" | grep -c . || printf 0)"
    printf 'reclaim_detail=%s\n' \
      "$(printf '%s' "${AFK_LOCK_RECLAIMED_DETAILS:-}" | head -1)"
    printf 'stolen=%s\n' "$(cat "$STATE/stolen" 2>/dev/null || printf 'no')"
    printf 'lock_inc_after=%s\n' "$(lock_inc)"
    ;;

  # Observe the lock, then WAIT, then reclaim what was observed. The pause is
  # the interleaving point: whatever the caller does to the lock in between
  # happens strictly between the observation and the reclamation.
  observe-then-reclaim) # <observed-file> <go-file>
    afk_lock_evaluate
    {
      printf 'state=%s\n' "$AFK_LOCK_OWNER_STATE"
      printf 'inc=%s\n' "$AFK_LOCK_OWNER_INCARNATION"
    } > "$1"
    spin_until "$2" || true
    afk_lock_reclaim "$AFK_LOCK_OWNER_INCARNATION" || rc=$?
    printf 'rc=%s\n' "$rc"
    printf 'lock_inc_after=%s\n' "$(lock_inc)"
    ;;

  # Release while claiming to hold <incarnation>, whatever the lock now says.
  release-as) # <incarnation>
    AFK_LOCK_HELD="true"
    AFK_LOCK_INCARNATION="$1"
    afk_lock_release || rc=$?
    printf 'rc=%s\n' "$rc"
    printf 'released=%s\n' "$AFK_LOCK_RELEASED"
    printf 'lock_inc_after=%s\n' "$(lock_inc)"
    ;;

  # Reclaim <incarnation>, pausing between losing the arbitration marker and
  # judging it, so the caller decides what that judge sees.
  reclaim-marker-interleaved) # <incarnation> <lost-file> <go-file>
    hold_lost_marker_claim "$2" "$3"
    afk_lock_reclaim "$1" || rc=$?
    printf 'rc=%s\n' "$rc"
    printf 'owner_detail=%s\n' "$AFK_LOCK_OWNER_DETAIL"
    printf 'lock_inc_after=%s\n' "$(lock_inc)"
    ;;

  # A whole acquisition with the same pause in it, so the outcome an operator
  # would actually be handed is what gets asserted, not just a return code.
  acquire-marker-interleaved) # <lost-file> <go-file>
    hold_lost_marker_claim "$1" "$2"
    afk_lock_acquire || rc=$?
    report_acquire "$rc"
    (( rc != 0 )) || { afk_lock_release || true; printf 'released=%s\n' "$AFK_LOCK_RELEASED"; }
    ;;

  # Win the reclamation marker for <incarnation> and abandon it, which is what
  # a reclaimer killed between claiming and renaming leaves behind.
  strand-marker) # <incarnation>
    afk_lock_marker_claim "$AFK_LOCK_DIR/reclaim.$1.json" || rc=$?
    printf 'rc=%s\n' "$rc"
    ;;

  incarnation)
    printf 'inc=%s\n' "$(afk_lock_incarnation_new || printf '')"
    ;;

  record) # <incarnation>
    afk_lock_owner_record "$1" || rc=$?
    printf '\nrc=%s\n' "$rc"
    ;;

  *) printf 'rc=97\n'; exit 0 ;;
esac
exit 0
