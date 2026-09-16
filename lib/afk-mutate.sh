#!/usr/bin/env bash
# afk-mutate.sh — the mutation transaction: lock, journal, backups, writes,
# rollback, offline verification and the single durable commit point.
#
# This file is SOURCED, never executed. It is the ONLY file in the lifecycle
# that writes to a managed destination, and every write in it is reachable only
# through afk_transaction_execute, which:
#
#   1. revalidates the plan binding immediately before the first write,
#   2. runs while an exclusive operation lock is held,
#   3. writes a secret-free recovery journal and every required backup BEFORE
#      the first managed write,
#   4. revalidates each component's own prerequisites immediately before that
#      component's write,
#   5. rolls back every change it made if anything fails, and VERIFIES the
#      restoration rather than assuming it,
#   6. verifies the complete installed result offline,
#   7. and only then commits the applied-state manifest.
#
# The order is the contract. A step that cannot be proven complete never
# advances the applied revision (FR-43, FR-44, NFR-3).
#
# shellcheck disable=SC2034,SC2154
# The AFK_OP_*/AFK_VERIFY_* accumulators and the declared-path globals are
# shared with the other lifecycle files, which are always sourced together.

if [[ -n "${AFK_MUTATE_SOURCED:-}" ]]; then
  return 0
fi
AFK_MUTATE_SOURCED=1

# The recovery journal is READ BACK as the authority for what an interrupted
# operation is allowed to undo, so its required structure is versioned like any
# other contract. Schema 2 makes `pre_mutation` and `plan.components` REQUIRED
# for recovery: schema 1 recorded destinations without recording what this
# lifecycle had proven was at them, and a destination alone is evidence, never
# authority to remove anything. A journal at any other major version is refused
# rather than interpreted.
AFK_JOURNAL_SCHEMA_VERSION="2.0"
AFK_SUPPORTED_JOURNAL_SCHEMA_MAJOR="2"
AFK_LOCK_SCHEMA_VERSION="2.0"

AFK_OP_ID=""
AFK_OP_RESULT=""            # one of afk_operation_results
AFK_OP_REASON=""
AFK_OP_DETAIL=""
AFK_OP_STEPS=""             # ndjson: one record per attempted step
AFK_OP_POST_ENTRIES=""      # ndjson: post-mutation identities for the manifest
AFK_OP_BACKUP_DIR=""
AFK_OP_STAGE_DIR=""
AFK_OP_MUTATED="false"
AFK_OP_ROLLBACK_STATE="NOT_REQUIRED"
AFK_OP_COMMITTED="false"
AFK_OP_PRIOR_REVISION=""
AFK_OP_APPLIED_REVISION=""
AFK_OP_TARGET_REVISION=""

afk_operation_results() {
  printf 'NO_CHANGE\nCONVERGED\nADOPTED\nPLAN_ONLY\nAPPROVAL_REQUIRED\nREFUSED\nSTALE_PLAN\nROLLED_BACK\nUNRECOVERABLE\nRECOVERED\n'
}

# The reason codes this file and afk-plan.sh add to the published vocabulary.
# afk-common.sh owns the read-only half; `schema` emits both halves and the
# gate compares the union against the contract document.
afk_mutation_reason_codes() {
  cat <<'CODES'
PLAN_NO_CHANGE_REQUIRED
PLAN_NOT_COMPUTABLE
PLAN_STALE_SOURCE_CHANGED
PLAN_STALE_MANIFEST_CHANGED
PLAN_STALE_DESTINATION_CHANGED
PLAN_APPROVAL_REQUIRED
PLAN_APPROVAL_MISMATCH
PLAN_COMPONENT_CONFLICT
COMPONENT_NOT_INSTALLED
ADAPTATION_REEVALUATION_REQUIRED
CONCURRENT_OPERATION_IN_PROGRESS
OPERATION_LOCK_UNAVAILABLE
BACKUP_PREREQUISITE_UNMET
PERMISSION_PREREQUISITE_UNMET
MANAGED_WRITE_FAILED
POST_WRITE_IDENTITY_MISMATCH
OUTSIDE_CONTENT_NOT_PRESERVED
OPERATION_ROLLED_BACK
OPERATION_ROLLBACK_INCOMPLETE
OPERATION_RECOVERED
OPERATION_JOURNAL_SCHEMA_UNSUPPORTED
OPERATION_RECOVERY_AUTHORITY_INSUFFICIENT
OPERATION_RECOVERY_VERIFICATION_FAILED
OPERATION_LOCK_OWNER_UNVERIFIABLE
OPERATION_LOCK_RECLAIMED
DESTINATION_METADATA_NOT_PRESERVED
STATE_MANIFEST_WRITE_FAILED
VERIFICATION_PASSED
VERIFICATION_FAILED
CODES
}

# Reverse a stream of lines without `tac`, which is not portable.
afk_reverse_lines() {
  awk '{ line[NR] = $0 } END { for (i = NR; i > 0; i--) print line[i] }'
}

# --- the operation lock (FR-92) ---------------------------------------------
#
# `mkdir` is the portable atomic test-and-set: it either creates the directory
# or fails because someone else holds it. The lock is taken only when a
# mutation is actually going to be attempted, so every refusal, every plan and
# every read-only path stays write-free.
#
# An empty directory is a good mutex and a useless diagnosis. A process killed
# with SIGKILL, an OOM kill or a power loss leaves one behind forever, and
# every later mutation then refuses with CONCURRENT_OPERATION_IN_PROGRESS and
# the guidance "wait for the operation in progress to finish" — advice that can
# never come true, for an installation that is bricked until someone finds an
# undocumented `rmdir`. Failing closed is right; failing closed with untrue
# guidance and no way out is not.
#
# So the lock carries an OWNER RECORD naming the facts that together make
# "is that process still running?" a decidable question, and one more that
# makes "is this still the SAME lock?" decidable too:
#
#   host identity  — which machine took it (a state directory can be shared)
#   boot identity  — which boot of that machine (pids do not survive a reboot)
#   pid            — which process
#   start identity — WHEN that pid started, so a recycled pid is not mistaken
#                    for the original owner
#   incarnation    — a value unique to THIS acquisition, so a lock that has
#                    been replaced since it was observed is never mistaken for
#                    the one that was judged
#
# An exact live owner blocks. A provably dead owner is reclaimed. Anything
# else — another host, an incomplete record, a record in a schema this version
# does not know, a host that cannot answer the liveness question — fails closed
# with an owner action that names the lock.
#
# The incarnation is what makes the two destructive steps single-winner:
#
#   RECLAIM  observing a stale lock does not authorize removing it. The
#            observer must first win an arbitration marker named for the exact
#            incarnation it judged, linked into the stale directory itself with
#            link(2) — atomic, and refused outright when it already exists. The
#            winner re-reads the record, proves the incarnation has not moved,
#            renames the directory aside and only then proves that what it
#            moved was the incarnation it judged. A loser never touches the
#            directory, so it can never delete a successor's live lock.
#
#   RELEASE  holding the lock is not enough either: a process releases only the
#            exact incarnation it installed. It re-reads the record, renames
#            the directory to a private name, proves the record it moved is
#            still its own, and removes only that. A former owner whose lock
#            was reclaimed underneath it removes nothing.
#
# Neither path ever observes a stale lock and then removes and recreates it:
# the observation and the removal are separated by a claim that exactly one
# process can hold.

AFK_LOCK_HELD="false"
AFK_LOCK_INCARNATION=""       # the exact incarnation THIS process installed
AFK_LOCK_OWNER_STATE="NONE"   # NONE|LIVE|DEAD|UNKNOWN|FOREIGN
AFK_LOCK_OWNER_DETAIL=""
AFK_LOCK_OWNER_INCARNATION="" # the incarnation the observed record names
AFK_LOCK_RECLAIMED="false"
# One line per abandoned lock THIS process destroyed, so a reclamation is
# reported once for each thing that was removed rather than once for an
# acquisition that happened to succeed.
AFK_LOCK_RECLAIMED_DETAILS=""
AFK_LOCK_RELEASED="false"

# The one state a lock can be in that is not a diagnosis but a moment: the
# directory exists and the owner record has not appeared in it yet. Named once
# so the judge that produces it and the acquisition that waits it out cannot
# drift apart.
AFK_LOCK_NO_RECORD_DETAIL="the lock carries no owner record"

afk_lock_state() {
  if [[ -n "${AFK_LOCK_DIR:-}" && -e "$AFK_LOCK_DIR" ]]; then
    printf 'HELD\n'
  else
    printf 'NONE\n'
  fi
}

afk_host_identity() {
  local h="" m=""
  h="$(uname -n 2>/dev/null)" || h=""
  if [[ -r /etc/machine-id ]]; then m="$(cat /etc/machine-id 2>/dev/null)" || m=""; fi
  if [[ -z "$m" && -r /var/lib/dbus/machine-id ]]; then
    m="$(cat /var/lib/dbus/machine-id 2>/dev/null)" || m=""
  fi
  [[ -n "$h" || -n "$m" ]] || return 1
  printf '%s/%s' "${h:-unnamed}" "${m:-no-machine-id}"
}

# A value that changes on every boot of this machine. Without one, a lock left
# before a reboot is indistinguishable from a lock taken a second ago, so its
# absence makes the owner UNKNOWN rather than assumed dead.
afk_boot_identity() {
  local v=""
  if [[ -r /proc/sys/kernel/random/boot_id ]]; then
    v="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)" || v=""
    [[ -z "$v" ]] || { printf 'boot-id:%s' "$v"; return 0; }
  fi
  if [[ -r /proc/stat ]]; then
    v="$(awk '$1 == "btime" { print $2; exit }' /proc/stat 2>/dev/null)" || v=""
    [[ -z "$v" ]] || { printf 'btime:%s' "$v"; return 0; }
  fi
  v="$(sysctl -n kern.boottime 2>/dev/null)" || v=""
  [[ -z "$v" ]] || { printf 'kern.boottime:%s' "$v"; return 0; }
  return 1
}

# afk_process_start_identity <pid>
# 0 — identity printed; 1 — the process exists or cannot be judged, with no
# identity available (ambiguous); 2 — the process provably does not exist.
afk_process_start_identity() {
  local pid="$1" line rest out
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [[ -r "/proc/$pid/stat" ]]; then
    line="$(cat "/proc/$pid/stat" 2>/dev/null)" || return 1
    # The comm field is parenthesized and may contain spaces, so everything up
    # to and including the final ") " is dropped before the fields are counted.
    rest="${line##*) }"
    [[ "$rest" != "$line" ]] || return 1
    out="$(printf '%s' "$rest" | awk '{print $20}')"
    case "$out" in ''|*[!0-9]*) return 1 ;; esac
    printf 'starttime:%s' "$out"
    return 0
  fi
  if [[ -d "/proc/$$" ]]; then
    # This host has a procfs that answers for THIS process, and it has no entry
    # for that pid. That is proof, not an inference.
    return 2
  fi
  if out="$(ps -o lstart= -p "$pid" 2>/dev/null)" && [[ -n "$out" ]]; then
    printf 'lstart:%s' "$(printf '%s' "$out" | tr -s '[:space:]' ' ')"
    return 0
  fi
  if ps -p "$pid" >/dev/null 2>&1; then
    return 1
  fi
  if command -v ps >/dev/null 2>&1; then
    return 2
  fi
  return 1
}

# A value no two acquisitions can share. It names the ACQUISITION, not the
# process: a pid that acquires, releases and acquires again must not reuse a
# token, or the second acquisition would answer for the first one's removal.
# A host that cannot produce one cannot take a lock — an acquisition whose
# identity cannot be established is refused rather than made unfalsifiable.
afk_lock_incarnation_new() {
  local n=""
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    n="$(tr -dc '0-9a-f' < /proc/sys/kernel/random/uuid 2>/dev/null)" || n=""
  fi
  if [[ ${#n} -lt 16 && -r /dev/urandom ]]; then
    n="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -dc '0-9a-f')" || n=""
  fi
  (( ${#n} >= 16 )) || return 1
  printf 'inc-%s-%s' "$$" "${n:0:32}"
}

# The token becomes part of a directory and a file name, so a record carrying
# anything but the shape this kit writes is refused rather than interpreted.
afk_lock_incarnation_valid() { # <token>
  [[ "$1" =~ ^inc-[0-9]{1,10}-[0-9a-f]{16,32}$ ]]
}

# afk_lock_incarnation_at <owner record path>
# Prints the incarnation the record names, or fails when it names none.
afk_lock_incarnation_at() {
  local v
  [[ -f "$1" && ! -L "$1" ]] || return 1
  v="$(jq -r '.incarnation // ""' "$1" 2>/dev/null)" || return 1
  afk_lock_incarnation_valid "$v" || return 1
  printf '%s' "$v"
}

afk_lock_owner_record() { # <incarnation>
  local inc="$1" host boot start
  host="$(afk_host_identity)" || host=""
  boot="$(afk_boot_identity)" || boot=""
  start="$(afk_process_start_identity "$$")" || start=""
  [[ -n "$host" && -n "$boot" && -n "$start" && -n "$inc" ]] || return 1
  jq -nc --arg schema "$AFK_LOCK_SCHEMA_VERSION" \
         --arg host "$host" --arg boot "$boot" --arg pid "$$" \
         --arg start "$start" --arg inc "$inc" \
    '{lock_schema_version: $schema,
      host_identity: $host,
      boot_identity: $boot,
      pid: ($pid | tonumber),
      process_start_identity: $start,
      incarnation: $inc,
      complete: true}'
}

# afk_lock_judge_record <owner record path>
# Prints "<STATE>|<detail>|<incarnation>". The detail never carries a pipe.
# Used for the lock itself and for a reclamation marker alike, so an abandoned
# reclaimer is judged by exactly the rules an abandoned owner is.
afk_lock_judge_record() {
  local rec="$1" raw doc schema host boot pid start inc complete
  local now_host now_boot now_start rc
  # The record is read ONCE and judged on the bytes that read returned, because
  # every verdict below has to describe one instant. A record is installed by
  # renaming one complete temporary file onto the name, so a torn or
  # half-written record is never observable: the bytes are a whole record or
  # there are none. No bytes therefore means the record was not there — a
  # release or a reclamation, the same moment as a lock still being published
  # — and bytes that do not parse mean a record that really is damaged.
  #
  # Asking the filesystem a second time to tell those apart would be asking
  # about a second instant: a successor that publishes into the same name
  # between the two is a valid record reported as a damaged one, and the
  # refusal that follows tells an operator to remove a lock a live owner holds.
  # One observation, one verdict.
  #
  # The one guard that still runs before the read is not a discriminator: a
  # path that is not a plain file is not read at all, because reading a
  # directory, a device or a fifo is not a judgement, it is a hazard. It can
  # only ever produce the no-record moment, never a diagnosis, so racing it
  # costs nothing but another look.
  if [[ ! -f "$rec" || -L "$rec" ]]; then
    printf 'UNKNOWN|%s|' "$AFK_LOCK_NO_RECORD_DETAIL"; return 0
  fi
  raw="$(cat -- "$rec" 2>/dev/null)" || raw=""
  if [[ -z "$raw" ]]; then
    printf 'UNKNOWN|%s|' "$AFK_LOCK_NO_RECORD_DETAIL"; return 0
  fi
  doc="$(printf '%s' "$raw" | jq -c '.' 2>/dev/null)" || doc=""
  if [[ -z "$doc" ]]; then
    printf 'UNKNOWN|the lock owner record could not be parsed|'; return 0
  fi
  schema="$(printf '%s' "$doc" | jq -r '.lock_schema_version // ""')"
  if [[ "$schema" != "$AFK_LOCK_SCHEMA_VERSION" ]]; then
    printf 'UNKNOWN|the lock owner record is written in a schema this version does not know|'
    return 0
  fi
  host="$(printf '%s' "$doc" | jq -r '.host_identity // ""')"
  boot="$(printf '%s' "$doc" | jq -r '.boot_identity // ""')"
  pid="$(printf '%s' "$doc" | jq -r 'if (.pid | type) == "number" then (.pid | tostring) else "" end')"
  start="$(printf '%s' "$doc" | jq -r '.process_start_identity // ""')"
  inc="$(printf '%s' "$doc" | jq -r '.incarnation // ""')"
  complete="$(printf '%s' "$doc" | jq -r 'if .complete == true then "true" else "false" end')"
  if [[ "$complete" != "true" || -z "$host" || -z "$boot" || -z "$pid" || -z "$start" ]]; then
    printf 'UNKNOWN|the lock owner record is incomplete|'; return 0
  fi
  if ! afk_lock_incarnation_valid "$inc"; then
    printf 'UNKNOWN|the lock owner record names no usable incarnation|'; return 0
  fi

  now_host="$(afk_host_identity)" || now_host=""
  now_boot="$(afk_boot_identity)" || now_boot=""
  if [[ -z "$now_host" || -z "$now_boot" ]]; then
    printf 'UNKNOWN|this host cannot identify itself well enough to judge the lock owner|%s' "$inc"
    return 0
  fi
  if [[ "$host" != "$now_host" ]]; then
    printf 'FOREIGN|the lock was taken on another host|%s' "$inc"; return 0
  fi
  if [[ "$boot" != "$now_boot" ]]; then
    # Same machine, earlier boot: no process from that boot can still be alive.
    printf 'DEAD|the lock was taken before this host booted|%s' "$inc"; return 0
  fi

  now_start="$(afk_process_start_identity "$pid")"; rc=$?
  case "$rc" in
    0)
      if [[ "$now_start" == "$start" ]]; then
        printf 'LIVE|pid %s|%s' "$pid" "$inc"
      else
        printf 'DEAD|pid %s belongs to a different process now|%s' "$pid" "$inc"
      fi ;;
    2) printf 'DEAD|pid %s is no longer running|%s' "$pid" "$inc" ;;
    *) printf 'UNKNOWN|pid %s could not be proven alive or dead|%s' "$pid" "$inc" ;;
  esac
  return 0
}

# Decide what the existing lock's owner is, from the record it left.
afk_lock_evaluate() {
  local judged
  AFK_LOCK_OWNER_STATE="NONE"; AFK_LOCK_OWNER_DETAIL=""; AFK_LOCK_OWNER_INCARNATION=""
  [[ -n "${AFK_LOCK_DIR:-}" && -e "$AFK_LOCK_DIR" ]] || return 0

  if [[ ! -d "$AFK_LOCK_DIR" || -L "$AFK_LOCK_DIR" ]]; then
    AFK_LOCK_OWNER_STATE="UNKNOWN"
    AFK_LOCK_OWNER_DETAIL="the lock path is not a directory"
    return 0
  fi
  judged="$(afk_lock_judge_record "$AFK_LOCK_DIR/owner.json")"
  IFS='|' read -r AFK_LOCK_OWNER_STATE AFK_LOCK_OWNER_DETAIL AFK_LOCK_OWNER_INCARNATION \
    <<<"$judged"
  return 0
}

afk_lock_take() {
  local inc record
  inc="$(afk_lock_incarnation_new)" || return 1
  record="$(afk_lock_owner_record "$inc")" || return 1
  mkdir -- "$AFK_LOCK_DIR" 2>/dev/null || return 1
  chmod 700 -- "$AFK_LOCK_DIR" 2>/dev/null || true
  if ! afk_state_file_write "$AFK_LOCK_DIR/owner.json" "$record"; then
    # Nothing but this process has ever seen this directory: the mkdir above
    # is what created it, and no incarnation was ever published inside it.
    rm -rf -- "$AFK_LOCK_DIR" 2>/dev/null
    return 1
  fi
  AFK_LOCK_HELD="true"
  AFK_LOCK_INCARNATION="$inc"
  return 0
}

# Claim the right to reclaim one exact incarnation, by hard-linking a complete
# reclaimer record onto the marker path. link(2) refuses an existing name, so
# the marker appears fully formed or not at all and exactly one process wins.
#
# 0 claimed; 1 the marker is already held; 2 the claim could not be made.
afk_lock_marker_claim() { # <marker path>
  local marker="$1" inc record stage
  inc="$(afk_lock_incarnation_new)" || return 2
  record="$(afk_lock_owner_record "$inc")" || return 2
  stage="$AFK_STATE_DIR/.afk-reclaim.$inc.json"
  afk_state_file_write "$stage" "$record" || return 2
  if ln -- "$stage" "$marker" 2>/dev/null; then
    rm -f -- "$stage" 2>/dev/null
    return 0
  fi
  rm -f -- "$stage" 2>/dev/null
  [[ -e "$marker" ]] || return 2
  return 1
}

# Take an abandoned marker out of the way, single-winner: the destination name
# is this process's own, so exactly one of two racing discarders renames it and
# the loser simply observes the marker gone and starts over.
afk_lock_marker_discard() { # <marker path>
  local marker="$1" inc aside
  inc="$(afk_lock_incarnation_new)" || return 1
  aside="$marker.abandoned.$inc"
  mv -- "$marker" "$aside" 2>/dev/null || return 1
  rm -f -- "$aside" 2>/dev/null
  return 0
}

# afk_lock_reclaim <incarnation observed as stale>
# 0 reclaimed and the lock is now held by this process;
# 1 a live process is reclaiming it, or took it first;
# 2 the situation cannot be judged — fail closed;
# 3 the situation moved underneath us — observe again.
afk_lock_reclaim() {
  local stale_inc="$1" marker judged state detail unused_inc own_inc aside rc
  afk_lock_incarnation_valid "$stale_inc" || return 2
  marker="$AFK_LOCK_DIR/reclaim.$stale_inc.json"

  rc=0; afk_lock_marker_claim "$marker" || rc=$?
  case "$rc" in
    0) : ;;
    1)
      judged="$(afk_lock_judge_record "$marker")"
      IFS='|' read -r state detail unused_inc <<<"$judged"
      case "$state" in
        LIVE)
          AFK_LOCK_OWNER_DETAIL="an abandoned lock is already being reclaimed by $detail"
          return 1 ;;
        DEAD)
          afk_lock_marker_discard "$marker"
          return 3 ;;
        *)
          # The marker lives INSIDE the lock directory, so the winning
          # reclaimer's rename carries it away. A marker that is simply gone is
          # therefore that instant of the handover, not a reclaimer this
          # process is unable to judge — the same distinction the publication
          # window draws, on the neighbouring path. Refusing it would tell a
          # loser to remove a lock the winner is about to hold. Observe again;
          # the retry is bounded by the acquisition's own attempt ceiling.
          if [[ "$state" == "UNKNOWN" && "$detail" == "$AFK_LOCK_NO_RECORD_DETAIL" ]]; then
            return 3
          fi
          AFK_LOCK_OWNER_DETAIL="a reclamation of this lock was started by a process that cannot be judged"
          return 2 ;;
      esac ;;
    *) return 3 ;;
  esac

  # The marker was linked into whatever directory the lock path named at that
  # instant. Holding it, re-judge that directory from scratch: the caller's
  # observation is not evidence, and a successor — live, foreign or simply a
  # different incarnation — is left strictly alone.
  judged="$(afk_lock_judge_record "$AFK_LOCK_DIR/owner.json")"
  IFS='|' read -r state detail unused_inc <<<"$judged"
  if [[ "$state" != "DEAD" ]] ||
     [[ "$(afk_lock_incarnation_at "$AFK_LOCK_DIR/owner.json" 2>/dev/null)" != "$stale_inc" ]]; then
    rm -f -- "$marker" 2>/dev/null
    if [[ "$state" == "LIVE" ]]; then
      AFK_LOCK_OWNER_STATE="LIVE"
      AFK_LOCK_OWNER_DETAIL="$detail"
      return 1
    fi
    return 3
  fi

  # Reclaim by RENAME onto a name only this process can have produced, so the
  # rename cannot collide and nothing is removed before it has been read.
  if ! own_inc="$(afk_lock_incarnation_new)"; then
    rm -f -- "$marker" 2>/dev/null
    return 2
  fi
  aside="$AFK_LOCK_DIR.stale.$own_inc"
  # The name is this process's own incarnation, so it cannot already exist. If
  # it somehow does, refuse: `mv` onto an existing directory would nest rather
  # than rename, and a lock nested inside stale material is worse than a lock.
  if [[ -e "$aside" ]]; then
    rm -f -- "$marker" 2>/dev/null
    return 2
  fi
  if ! mv -- "$AFK_LOCK_DIR" "$aside" 2>/dev/null; then
    rm -f -- "$marker" 2>/dev/null
    return 3
  fi
  # What was moved is read before it is removed: if it is not the incarnation
  # that was judged, it is put back untouched and the operation fails closed.
  if [[ "$(afk_lock_incarnation_at "$aside/owner.json" 2>/dev/null)" != "$stale_inc" ]]; then
    # Put it back only onto an empty name: a restore that landed inside a lock
    # someone else has since taken would nest a directory in a live owner's.
    [[ -e "$AFK_LOCK_DIR" ]] || mv -- "$aside" "$AFK_LOCK_DIR" 2>/dev/null || true
    AFK_LOCK_OWNER_DETAIL="the lock changed identity while it was being reclaimed"
    return 2
  fi
  # The abandoned lock is destroyed HERE: the rename has already taken it off
  # the lock path, and what was moved has just been proven to be the
  # incarnation that was judged. Whether this process then wins the empty path
  # it created is a separate question, and a reclamation that reports itself
  # only when it does is a reclamation that can be silent — the one place the
  # lifecycle removes something another process created goes unreported,
  # because the contender that took the freed path reclaimed nothing and has
  # nothing to report. The reclaimer owns the report, whoever wins the take.
  AFK_LOCK_RECLAIMED="true"
  AFK_LOCK_RECLAIMED_DETAILS+="$detail"$'\n'
  rc=3
  if afk_lock_take; then rc=0; fi
  rm -rf -- "$aside" 2>/dev/null
  return "$rc"
}

# --- the publication window -------------------------------------------------
#
# Taking the lock is two steps that cannot be one: `mkdir` is the atomic
# test-and-set, and the owner record appears inside the directory a moment
# later. Between them the lock exists and carries no record, and a contender
# that observes exactly then judges it UNKNOWN — the record it needs has not
# been written yet.
#
# Refusing that as unjudgeable is not merely imprecise, it is unsafe. The
# UNKNOWN refusal's owner action is "confirm nothing is running, then remove
# the lock by hand", and an operator who follows it while the winner is
# mutating produces exactly the two-owners-one-installation state this
# protocol exists to prevent. It is outside the contract's enumeration too: a
# lock a live winner is in the middle of publishing is not a foreign lock, not
# an incomplete record, and not a host that cannot answer.
#
# So a lock that carries no record is WAITED ON rather than judged — briefly,
# boundedly, and only while acquiring, never while a read-only path is merely
# observing. The state resolves itself in one file write.
#
# The same reading decides every neighbouring place a record can be seen to
# exist and then be found gone: a record that disappears between the existence
# test and the read, and an arbitration marker the winning reclaimer's rename
# carried out of the lock directory. Neither is a diagnosis — a record is
# installed by a single rename, so an unreadable one that is no longer there
# was never damaged, it was released — and neither is refused. Both are
# reported as a lock carrying no record and observed again.
#
# The budget is spent across a whole acquisition rather than per attempt, so
# the ceiling holds however often the lock changes hands underneath us. A lock
# that still carries no record when it is gone is refused exactly as before,
# and the refusal is now true when it is made: nothing published that lock
# while it was watched, which is what makes "remove it by hand" safe advice.

AFK_LOCK_PUBLISH_WAIT_SLICE="0.02"    # seconds between observations
AFK_LOCK_PUBLISH_WAIT_SLICES=120      # ceiling: 120 observations ~= 3s per acquisition
AFK_LOCK_PUBLISH_SLICES_LEFT=0
AFK_LOCK_SLEEP_FRACTIONAL=""          # probed once: does `sleep` take a fraction?

# One short pause. `sleep` is not in the required-tool set and not every `sleep`
# accepts a fraction of a second, so the fraction is probed once and a host
# whose sleep cannot do it counts instead — a bounded arithmetic loop, never an
# unbounded spin and never a whole second of latency on a millisecond window.
afk_lock_pause() {
  local i=0
  if [[ -z "$AFK_LOCK_SLEEP_FRACTIONAL" ]]; then
    if afk_have sleep && sleep "$AFK_LOCK_PUBLISH_WAIT_SLICE" 2>/dev/null; then
      AFK_LOCK_SLEEP_FRACTIONAL="true"
      return 0                        # the probe was itself the first pause
    fi
    AFK_LOCK_SLEEP_FRACTIONAL="false"
  fi
  if [[ "$AFK_LOCK_SLEEP_FRACTIONAL" == "true" ]]; then
    sleep "$AFK_LOCK_PUBLISH_WAIT_SLICE" 2>/dev/null || true
    return 0
  fi
  while (( i < 8000 )); do i=$((i + 1)); done
  return 0
}

# Judge the lock, waiting out an owner record that has not been published yet.
# Every other UNKNOWN is a diagnosis rather than a moment and is returned at
# once, so a genuinely unjudgeable lock costs no latency at all.
afk_lock_evaluate_settled() {
  afk_lock_evaluate
  while [[ "$AFK_LOCK_OWNER_STATE" == "UNKNOWN" &&
           "$AFK_LOCK_OWNER_DETAIL" == "$AFK_LOCK_NO_RECORD_DETAIL" ]]; do
    if (( AFK_LOCK_PUBLISH_SLICES_LEFT <= 0 )); then
      # Say what was actually established, so the guidance that follows is a
      # report rather than a guess.
      AFK_LOCK_OWNER_DETAIL="$AFK_LOCK_NO_RECORD_DETAIL and none appeared while it was waited on"
      break
    fi
    AFK_LOCK_PUBLISH_SLICES_LEFT=$((AFK_LOCK_PUBLISH_SLICES_LEFT - 1))
    afk_lock_pause
    afk_lock_evaluate
  done
  return 0
}

# 0 acquired; 1 an exact live owner holds it; 2 the lock could not be
# established at all; 3 a lock exists whose owner cannot be judged.
afk_lock_acquire() {
  local attempt=0 rc
  AFK_LOCK_RECLAIMED="false"; AFK_LOCK_RECLAIMED_DETAILS=""
  [[ -n "${AFK_LOCK_DIR:-}" && -n "${AFK_STATE_DIR:-}" ]] || return 2
  afk_state_dir_ensure "$AFK_STATE_DIR" || return 2
  AFK_LOCK_PUBLISH_SLICES_LEFT="$AFK_LOCK_PUBLISH_WAIT_SLICES"

  while (( attempt < 4 )); do
    attempt=$((attempt + 1))
    if afk_lock_take; then return 0; fi
    # The lock that beat us to `mkdir` is already gone: that is a lock free to
    # be taken, not a lock that could not be established. Observe again.
    if [[ ! -e "$AFK_LOCK_DIR" ]]; then continue; fi

    afk_lock_evaluate_settled
    case "$AFK_LOCK_OWNER_STATE" in
      LIVE) return 1 ;;
      NONE) continue ;;   # released or reclaimed underneath us: take it again
      DEAD) : ;;
      *)    return 3 ;;
    esac

    rc=0; afk_lock_reclaim "$AFK_LOCK_OWNER_INCARNATION" || rc=$?
    case "$rc" in
      0) return 0 ;;   # the reclamation reported itself where it happened
      1) return 1 ;;
      2) return 3 ;;
      *) : ;;   # the situation moved: observe again
    esac
  done

  # The lock changed hands under us more times than a bounded retry allows.
  # That is a busy installation, not a broken one — report it truthfully.
  afk_lock_evaluate_settled
  case "$AFK_LOCK_OWNER_STATE" in
    NONE) afk_lock_take && return 0; return 2 ;;
    LIVE) return 1 ;;
    *)    return 3 ;;
  esac
}

# A process releases the exact incarnation it installed and nothing else. A
# former owner whose lock was reclaimed underneath it removes nothing, so a
# successor's live lock can never be deleted by its predecessor.
afk_lock_release() {
  local inc="$AFK_LOCK_INCARNATION" aside
  AFK_LOCK_RELEASED="false"
  if [[ "$AFK_LOCK_HELD" != "true" || -z "${AFK_LOCK_DIR:-}" ]]; then
    AFK_LOCK_HELD="false"; AFK_LOCK_INCARNATION=""
    return 0
  fi
  AFK_LOCK_HELD="false"
  AFK_LOCK_INCARNATION=""
  afk_lock_incarnation_valid "$inc" || return 1
  [[ "$(afk_lock_incarnation_at "$AFK_LOCK_DIR/owner.json" 2>/dev/null)" == "$inc" ]] || return 1

  aside="$AFK_LOCK_DIR.released.$inc"
  [[ ! -e "$aside" ]] || return 1
  mv -- "$AFK_LOCK_DIR" "$aside" 2>/dev/null || return 1
  if [[ "$(afk_lock_incarnation_at "$aside/owner.json" 2>/dev/null)" != "$inc" ]]; then
    [[ -e "$AFK_LOCK_DIR" ]] || mv -- "$aside" "$AFK_LOCK_DIR" 2>/dev/null || true
    return 1
  fi
  rm -rf -- "$aside" 2>/dev/null
  AFK_LOCK_RELEASED="true"
  return 0
}

# --- the recovery journal (FR-41, FR-45) ------------------------------------
#
# Secret-free by construction: identities, declared paths, revisions and step
# records. No file content, no environment value, nothing user-owned.

afk_journal_write() { # <state>
  local doc
  [[ -n "$AFK_JOURNAL" ]] || return 1
  doc="$(jq -nc \
    --arg schema "$AFK_JOURNAL_SCHEMA_VERSION" \
    --arg state "$1" \
    --arg op "$AFK_OP_ID" \
    --arg command "$AFK_PLAN_COMMAND" \
    --arg prior "$AFK_OP_PRIOR_REVISION" \
    --arg target "$AFK_CO_REVISION" \
    --arg plan_identity "$AFK_PLAN_IDENTITY" \
    --arg backups "$AFK_OP_BACKUP_DIR" \
    --arg rollback "$AFK_OP_ROLLBACK_STATE" \
    --argjson plan "$AFK_PLAN_JSON" \
    --argjson steps "$(afk_ndjson_to_array "$AFK_OP_STEPS")" \
    '{journal_schema_version: $schema,
      state: $state,
      operation_id: $op,
      command: $command,
      prior_revision: (if $prior == "" then null else $prior end),
      target_revision: (if $target == "" then null else $target end),
      plan_identity: $plan_identity,
      backup_dir: (if $backups == "" then null else $backups end),
      rollback_state: $rollback,
      pre_mutation: ($plan.binding.components // []),
      plan: {command: $plan.command,
             disposition: $plan.disposition,
             components: [($plan.components // [])[]
                          | {component, action, destination,
                             expected_destination_identity, target_identity,
                             backup_required}]},
      completed_steps: $steps}')" || return 1
  [[ -n "$doc" ]] || return 1
  # The journal is recovery AUTHORITY, so it is written private to its owner
  # rather than at whatever umask the invoking shell carried.
  afk_state_file_write "$AFK_JOURNAL" "$doc" || return 1
  return 0
}

# Intent is recorded BEFORE the write it describes, so a process killed between
# a write and its journal entry still leaves a record that the destination was
# being touched. Rollback restores from the backup either way.
afk_journal_step() { # <component> <action> <result> <destination>
  AFK_OP_STEPS="${AFK_OP_STEPS}$(jq -nc \
    --arg component "$1" --arg action "$2" --arg result "$3" --arg destination "$4" \
    '{component: $component, action: $action, result: $result,
      destination: (if $destination == "" then null else $destination end)}')"$'\n'
}

afk_journal_step_result() { # <component> <result>
  local updated
  updated="$(printf '%s' "$AFK_OP_STEPS" | jq -c --arg c "$1" --arg r "$2" \
    'if .component == $c and .result == "ATTEMPTED" then .result = $r else . end' 2>/dev/null)" \
    || return 1
  AFK_OP_STEPS="${updated}"$'\n'
  return 0
}

# --- backups ----------------------------------------------------------------
#
# A backup exists before the write that would need it, or the write does not
# happen. `cp -R` copies a symlink as a symlink, so a managed tree containing
# links is restored as it was rather than as its resolved contents.
#
# A destination that does not exist yet needs no backup: its restoration is
# removal, and the ABSENCE of a backup store is exactly how
# afk_restore_component knows that. Nothing has to be remembered separately
# about which case applied.

afk_backup_component() { # <component-id> <destination>
  local id="$1" dest="$2" store
  [[ -n "$AFK_OP_BACKUP_DIR" ]] || return 1
  mkdir -p -- "$AFK_OP_BACKUP_DIR" 2>/dev/null || return 1
  store="$AFK_OP_BACKUP_DIR/$id"
  rm -rf -- "$store" "$store.link" 2>/dev/null
  if [[ -L "$dest" ]]; then
    readlink -- "$dest" > "$store.link" 2>/dev/null || return 1
    return 0
  fi
  if [[ -d "$dest" ]]; then
    cp -R -p -- "$dest" "$store" 2>/dev/null || return 1
    return 0
  fi
  if [[ -f "$dest" ]]; then
    cp -p -- "$dest" "$store" 2>/dev/null || return 1
    return 0
  fi
  if [[ ! -e "$dest" ]]; then
    return 0
  fi
  return 1
}

# afk_restore_component <component-id> <destination> <backup-dir>
#                       <removal-authorized: true|false>
#
# A stored copy is put back. The ABSENCE of a stored copy is NOT by itself
# permission to delete the destination. It is permission only when the caller
# has independently proved, from this operation's own binding, that this exact
# component held nothing at this exact destination before this exact operation
# — the in-process rollback holds that proof in memory, and recovery reads it
# out of the journal's pre-mutation record. Without the proof, restoration
# FAILS. A "restore" that falls through to `rm -rf` on an unproven path is how
# a recovery turns into a deletion of content the lifecycle never owned.
afk_restore_component() {
  local id="$1" dest="$2" root="${3:-$AFK_OP_BACKUP_DIR}" removal="${4:-false}"
  local store target
  [[ -n "$id" && -n "$dest" && -n "$root" ]] || return 1
  store="$root/$id"
  if [[ -f "$store.link" && ! -L "$store.link" ]]; then
    target="$(cat -- "$store.link" 2>/dev/null)" || return 1
    rm -rf -- "$dest" 2>/dev/null || return 1
    ln -s -- "$target" "$dest" 2>/dev/null || return 1
    return 0
  fi
  if [[ -d "$store" && ! -L "$store" ]]; then
    rm -rf -- "$dest" 2>/dev/null || return 1
    cp -R -p -- "$store" "$dest" 2>/dev/null || return 1
    return 0
  fi
  if [[ -f "$store" && ! -L "$store" ]]; then
    rm -rf -- "$dest" 2>/dev/null || return 1
    cp -p -- "$store" "$dest" 2>/dev/null || return 1
    return 0
  fi
  [[ "$removal" == "true" ]] || return 1
  rm -rf -- "$dest" 2>/dev/null || return 1
  return 0
}

afk_backup_exists() { # <component-id> [backup-dir]
  local root="${2:-$AFK_OP_BACKUP_DIR}"
  [[ -e "$root/$1" || -f "$root/$1.link" ]]
}

# afk_restoration_verified <component-id> <expected-identity-or-empty>
#
# The ONE predicate that decides whether a restoration actually happened. Both
# the in-process rollback and interrupted-operation recovery call it, so a
# recovery can never settle for weaker evidence than a rollback: the identity
# is recomputed from the filesystem and compared against what the operation's
# binding recorded as pre-mutation state. An expected identity of nothing means
# nothing may be there now — absence, or for a managed section a host file that
# carries no section.
afk_restoration_verified() {
  local id="$1" expected="$2" row
  row="$(afk_component_row "$id")" || return 1
  afk_observe_component "$row"
  if [[ -n "$expected" ]]; then
    [[ "$AFK_OB_OBSERVED" == "$expected" ]] || return 1
    return 0
  fi
  [[ "$AFK_OB_GUARD" == "PATH_ABSENT" ]] && return 0
  if [[ "$AFK_OB_OWNERSHIP" == "MANAGED_SECTION" ]] && (( AFK_OB_SECTION_RC == 2 )); then
    return 0
  fi
  return 1
}

# Recovery material this installation no longer names. A backup directory is
# created BEFORE the journal that references it, so a process killed inside
# that window leaves copies of user content behind that nothing will ever
# reclaim. Sweeping runs under the operation lock, after the current journal is
# closed, so anything not named by the operation being kept is an orphan.
afk_sweep_orphan_recovery_material() { # <op-id-to-keep-or-empty>
  local keep="${1:-}" root entry base
  for root in "$AFK_BACKUP_ROOT" "$AFK_STAGE_ROOT"; do
    [[ -n "$root" && -d "$root" && ! -L "$root" ]] || continue
    for entry in "$root"/op-*; do
      [[ -e "$entry" ]] || continue
      base="${entry##*/}"
      [[ "$base" != "$keep" ]] || continue
      rm -rf -- "$entry" 2>/dev/null || true
    done
  done
  return 0
}

# --- writers ----------------------------------------------------------------
#
# Each writer replaces a whole destination, so a partially written destination
# is never left where the real one belongs. None of them merges anything:
# content comes from canonical source bytes, and the only thing carried over
# from the host is content the ownership model declares to belong to the host.

afk_parent_writable() { # <path>
  local parent
  parent="$(dirname -- "$1")"
  [[ -d "$parent" && -w "$parent" ]]
}

afk_cat_terminated() { # <file> — the file's bytes, guaranteed newline-terminated
  [[ -s "$1" ]] || return 0
  cat -- "$1" || return 1
  if [[ -n "$(tail -c 1 -- "$1" 2>/dev/null)" ]]; then printf '\n'; fi
  return 0
}

# The rename stays atomic: the destination is never a partially written file.
# What the rename must NOT carry over is the temporary file's own metadata —
# the destination's mode belongs to the host owner, not to the canonical
# source, and a temporary created at the process umask would silently widen a
# file the owner had deliberately restricted. The replacement is given the
# destination's mode BEFORE the rename, and the caller proves the result.
afk_write_managed_file() { # <source> <destination>
  local src="$1" dest="$2" tmp
  tmp="$dest.afk-tmp"
  afk_parent_writable "$dest" || return 1
  [[ -f "$src" ]] || return 1
  rm -rf -- "$tmp" 2>/dev/null
  cp -- "$src" "$tmp" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null; return 1; }
  afk_metadata_apply "$dest" "$tmp" || { rm -f -- "$tmp" 2>/dev/null; return 1; }
  mv -f -- "$tmp" "$dest" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null; return 1; }
  return 0
}

# A symlink is replaced in place rather than through a temporary name: `mv`
# onto a path that is a symlink to a directory follows it on some systems and
# would move the temporary link INSIDE the target tree. `rm` then `ln -s`
# cannot do that, and the backup covers the moment in between.
afk_write_managed_link() { # <link-target> <destination>
  local target="$1" dest="$2"
  afk_parent_writable "$dest" || return 1
  if [[ -d "$dest" && ! -L "$dest" ]]; then return 1; fi
  rm -f -- "$dest" 2>/dev/null || return 1
  ln -s -- "$target" "$dest" 2>/dev/null || return 1
  return 0
}

# afk_write_managed_tree <source-tree> <destination> <comma-separated exclusions>
# Declared machine-owned members are carried over from the existing
# destination, so a local subscriptions.yaml survives a managed-copy upgrade.
# When the host has no such member, the canonical default is what lands.
afk_write_managed_tree() {
  local src="$1" dest="$2" excl="${3:-}" stage item
  local -a items=()
  [[ -n "$AFK_OP_STAGE_DIR" ]] || return 1
  [[ -d "$src" ]] || return 1
  afk_parent_writable "$dest" || return 1
  mkdir -p -- "$AFK_OP_STAGE_DIR" 2>/dev/null || return 1
  stage="$AFK_OP_STAGE_DIR/staged"
  rm -rf -- "$stage" 2>/dev/null
  cp -R -p -- "$src" "$stage" 2>/dev/null || return 1
  if [[ -n "$excl" ]]; then
    IFS=',' read -r -a items <<< "$excl"
    for item in "${items[@]}"; do
      [[ -n "$item" ]] || continue
      case "$item" in
        /*|.|..|./*|../*|*/./*|*/../*|*/.|*/..) return 1 ;;
      esac
      if [[ -e "$dest/$item" && ! -L "$dest/$item" ]]; then
        # Exclusions may be bounded child trees owned by their own component
        # (the installed runtime's bin/ and lib/ siblings). Preserve the whole
        # declared member before replacing the parent, then let its component
        # converge independently. Symlinks remain refused by the tree guard.
        rm -rf -- "${stage:?}/$item" 2>/dev/null || return 1
        cp -R -p -- "$dest/$item" "$stage/$item" 2>/dev/null || return 1
      fi
    done
  fi
  afk_metadata_apply "$dest" "$stage" || return 1
  rm -rf -- "$dest" 2>/dev/null || return 1
  mv -- "$stage" "$dest" 2>/dev/null || return 1
  return 0
}

# afk_outside_bytes <file> <section-id>
# Every byte of the file that is NOT the managed section or its markers. This
# is what FR-37 promises to preserve, and it is compared byte for byte on both
# sides of a section write.
afk_outside_bytes() {
  local file="$1" id="$2" bounds bl el
  [[ -f "$file" ]] || return 0
  if bounds="$(afk_section_bounds "$file" "$id")"; then
    bl="${bounds%% *}"
    el="${bounds##* }"
    if (( bl > 1 )); then head -n "$((bl - 1))" -- "$file"; fi
    tail -n +"$((el + 1))" -- "$file"
  else
    cat -- "$file"
  fi
  return 0
}

# afk_write_managed_section <file> <section-id> <canonical-payload-file>
#
# head/tail copy bytes verbatim, so a CRLF line outside the section stays a
# CRLF line and a file with no final newline keeps having none.
#
# When the section is absent the file is APPENDED to, never rewritten: every
# existing byte stays where it is. If the file did not end with a newline, one
# is added before the marker, because a marker that is not a whole line is not
# a marker. That single byte is the "explicitly contracted unavoidable
# formatting behavior" FR-37 allows, and it is the only one.
afk_write_managed_section() {
  local file="$1" id="$2" payload="$3" tmp bounds bl el
  tmp="$file.afk-tmp"
  afk_parent_writable "$file" || return 1
  [[ -f "$payload" ]] || return 1
  if [[ -L "$file" ]] || [[ -e "$file" && ! -f "$file" ]]; then return 1; fi

  if [[ -f "$file" ]] && bounds="$(afk_section_bounds "$file" "$id")"; then
    bl="${bounds%% *}"
    el="${bounds##* }"
    {
      head -n "$bl" -- "$file"
      afk_cat_terminated "$payload"
      tail -n +"$el" -- "$file"
    } > "$tmp" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null; return 1; }
  else
    {
      if [[ -s "$file" ]]; then
        cat -- "$file"
        if [[ -n "$(tail -c 1 -- "$file" 2>/dev/null)" ]]; then printf '\n'; fi
      fi
      afk_section_marker_begin "$id"; printf '\n'
      afk_cat_terminated "$payload"
      afk_section_marker_end "$id"; printf '\n'
    } > "$tmp" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null; return 1; }
  fi
  afk_metadata_apply "$file" "$tmp" || { rm -f -- "$tmp" 2>/dev/null; return 1; }
  mv -f -- "$tmp" "$file" 2>/dev/null || { rm -f -- "$tmp" 2>/dev/null; return 1; }
  return 0
}

# --- offline verification (FR-27, FR-43) ------------------------------------
#
# Observes and proves; never repairs, never probes a live service, never
# activates orchestration. Used by the `verify` command AND as the final gate
# before any applied-state manifest is committed — the same function, so a
# convergence can never be committed on evidence weaker than a verify demands.

AFK_VERIFY_ENTRIES=""
AFK_VERIFY_FAILURES=0
AFK_VERIFY_WARNINGS=0
AFK_VERIFY_CHECKS=0
AFK_VERIFY_OWN_OPERATION=""

afk_verify_note() { # <subject> <check> <result: PASS|FAIL|WARN|SKIP> <reason> [expected] [observed]
  AFK_VERIFY_CHECKS=$((AFK_VERIFY_CHECKS + 1))
  case "$3" in
    FAIL) AFK_VERIFY_FAILURES=$((AFK_VERIFY_FAILURES + 1)) ;;
    WARN) AFK_VERIFY_WARNINGS=$((AFK_VERIFY_WARNINGS + 1)) ;;
    *) : ;;
  esac
  AFK_VERIFY_ENTRIES="${AFK_VERIFY_ENTRIES}$(jq -nc \
    --arg subject "$1" --arg check "$2" --arg result "$3" --arg reason "$4" \
    --arg expected "${5:-}" --arg observed "${6:-}" \
    '{subject: $subject, check: $check, result: $result,
      reason: (if $reason == "" then null else $reason end),
      evidence: {expected: (if $expected == "" then null else $expected end),
                 observed: (if $observed == "" then null else $observed end)}}')"$'\n'
}

afk_identity_in_manifest() { # <manifest-json> <component-id>
  printf '%s' "$1" | jq -r --arg id "$2" \
    'if (.components[$id].identity | type) == "string" then .components[$id].identity else "" end'
}

# The journal is read from disk rather than from a cached variable, and this
# operation's OWN journal is not an interruption: during a transaction the
# journal is legitimately open, which is exactly what makes it recovery
# evidence.
afk_verify_journal_check() {
  local state="NONE" opid=""
  if [[ -e "$AFK_JOURNAL" || -L "$AFK_JOURNAL" ]]; then
    if [[ -f "$AFK_JOURNAL" && ! -L "$AFK_JOURNAL" ]]; then
      state="$(jq -r 'if (.state | type) == "string" then .state else "" end' "$AFK_JOURNAL" 2>/dev/null)"
      opid="$(jq -r 'if (.operation_id | type) == "string" then .operation_id else "" end' "$AFK_JOURNAL" 2>/dev/null)"
      [[ -n "$state" ]] || state="UNREADABLE"
    else
      state="UNSAFE"
    fi
  fi
  if [[ "$state" == "NONE" || "$state" == "COMMITTED" ]] \
     || { [[ -n "$AFK_VERIFY_OWN_OPERATION" ]] && [[ "$opid" == "$AFK_VERIFY_OWN_OPERATION" ]]; }; then
    afk_verify_note "operation-journal" "no_open_operation" "PASS" "" "COMMITTED" "$state"
    return 0
  fi
  afk_verify_note "operation-journal" "no_open_operation" "FAIL" "OPERATION_INTERRUPTED" \
    "COMMITTED" "$state"
  return 1
}

# afk_verify_against_manifest <manifest-json> <applied-revision>
# Returns 0 when every blocking check passed.
afk_verify_against_manifest() {
  local manifest="$1" applied="$2" row recorded major n i tid tpath valid
  AFK_VERIFY_ENTRIES=""
  AFK_VERIFY_FAILURES=0
  AFK_VERIFY_WARNINGS=0
  AFK_VERIFY_CHECKS=0

  # --- manifest invariants -------------------------------------------------
  if printf '%s' "$manifest" | jq -e --arg r "$applied" '
        (type == "object")
        and (.applied_revision | type == "string")
        and (.applied_revision | test("^[0-9a-f]{40}$"))
        and (.applied_revision == $r)
        and (.repository.identity | type == "string")
        and (.repository.identity | length > 0)
        and (.components | type == "object")
        and (.adaptations | type == "array")
        and (.targets | type == "array")
        and (.state_schema_version | type == "string")' >/dev/null 2>&1; then
    afk_verify_note "state-manifest" "manifest_invariants" "PASS" "" "$applied" "$applied"
  else
    afk_verify_note "state-manifest" "manifest_invariants" "FAIL" "STATE_MANIFEST_SHAPE_INVALID" \
      "a complete manifest recording $applied" "invalid"
  fi

  major="$(printf '%s' "$manifest" | jq -r 'if (.state_schema_version | type) == "string"
        then (.state_schema_version | split(".") | .[0]) else "" end')"
  if [[ "$major" == "$AFK_SUPPORTED_STATE_SCHEMA_MAJOR" ]]; then
    afk_verify_note "state-manifest" "state_schema_compatible" "PASS" "" \
      "$AFK_SUPPORTED_STATE_SCHEMA_MAJOR.x" "$major"
  else
    afk_verify_note "state-manifest" "state_schema_compatible" "FAIL" "STATE_SCHEMA_UNRECOGNIZED" \
      "$AFK_SUPPORTED_STATE_SCHEMA_MAJOR.x" "${major:-unparseable}"
  fi

  afk_verify_journal_check

  if [[ "$(afk_lock_state)" == "NONE" || "$AFK_LOCK_HELD" == "true" ]]; then
    afk_verify_note "operation-lock" "no_operation_in_progress" "PASS" "" "NONE" "NONE"
  else
    afk_verify_note "operation-lock" "no_operation_in_progress" "FAIL" \
      "CONCURRENT_OPERATION_IN_PROGRESS" "NONE" "HELD"
  fi

  # --- every declared component -------------------------------------------
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    afk_observe_component "$row"
    recorded="$(afk_identity_in_manifest "$manifest" "$AFK_OB_ID")"

    if [[ "$AFK_OB_OWNERSHIP" == "MACHINE_LOCAL" ]]; then
      # Declared machine-owned: content is legitimate by ownership rule, so
      # verification proves only that nothing redirected the path.
      if [[ "$AFK_OB_GUARD" == "PATH_OK" || "$AFK_OB_GUARD" == "PATH_ABSENT" ]]; then
        afk_verify_note "$AFK_OB_ID" "machine_local_preserved" "PASS" "MACHINE_OWNED_REGION" \
          "" "$AFK_OB_GUARD"
      else
        afk_verify_note "$AFK_OB_ID" "machine_local_preserved" "FAIL" "$AFK_OB_GUARD" \
          "PATH_OK" "$AFK_OB_GUARD"
      fi
      continue
    fi

    if [[ -z "$recorded" ]]; then
      if [[ "$AFK_OB_GUARD" == "PATH_ABSENT" ]] \
         || { [[ "$AFK_OB_OWNERSHIP" == "MANAGED_SECTION" ]] && (( AFK_OB_SECTION_RC == 2 )); }; then
        afk_verify_note "$AFK_OB_ID" "component_integrity" "SKIP" "COMPONENT_NOT_INSTALLED" "" "absent"
      else
        afk_verify_note "$AFK_OB_ID" "component_integrity" "FAIL" "COMPONENT_NOT_RECORDED" \
          "a recorded applied identity" "${AFK_OB_OBSERVED:-unrecorded content}"
      fi
      continue
    fi

    if [[ "$AFK_OB_GUARD" == "PATH_ABSENT" ]]; then
      afk_verify_note "$AFK_OB_ID" "component_integrity" "FAIL" "COMPONENT_MISSING" "$recorded" "absent"
      continue
    fi
    if [[ "$AFK_OB_GUARD" != "PATH_OK" ]]; then
      afk_verify_note "$AFK_OB_ID" "component_integrity" "FAIL" "$AFK_OB_GUARD" \
        "$recorded" "$AFK_OB_GUARD"
      continue
    fi
    if [[ -n "$AFK_OB_ESCAPE" ]]; then
      afk_verify_note "$AFK_OB_ID" "component_integrity" "FAIL" "PATH_ESCAPES_OWNERSHIP_BOUNDARY" \
        "$recorded" "$AFK_OB_ESCAPE"
      continue
    fi
    if [[ "$AFK_OB_OWNERSHIP" == "MANAGED_SECTION" ]]; then
      if (( AFK_OB_SECTION_RC == 3 )); then
        afk_verify_note "$AFK_OB_ID" "component_integrity" "FAIL" "MANAGED_SECTION_MARKERS_MALFORMED" \
          "$recorded" "malformed"
        continue
      fi
      if (( AFK_OB_SECTION_RC == 2 )); then
        afk_verify_note "$AFK_OB_ID" "component_integrity" "FAIL" "MANAGED_SECTION_ABSENT" \
          "$recorded" "absent"
        continue
      fi
    fi
    if [[ -z "$AFK_OB_OBSERVED" ]]; then
      afk_verify_note "$AFK_OB_ID" "component_integrity" "FAIL" "IDENTITY_UNREADABLE" "$recorded" ""
      continue
    fi
    if [[ "$AFK_OB_OBSERVED" == "$recorded" ]]; then
      afk_verify_note "$AFK_OB_ID" "component_integrity" "PASS" "" "$recorded" "$AFK_OB_OBSERVED"
    elif [[ -n "$AFK_OB_ADAPT" ]]; then
      # A valid registered adaptation is the one legitimate way installed
      # content may differ from the identity the manifest records.
      afk_verify_note "$AFK_OB_ID" "component_integrity" "PASS" "REGISTERED_ADAPTATION" \
        "$recorded" "$AFK_OB_OBSERVED"
    else
      afk_verify_note "$AFK_OB_ID" "component_integrity" "FAIL" "UNEXPLAINED_MANAGED_DIFFERENCE" \
        "$recorded" "$AFK_OB_OBSERVED"
    fi
  done < <(afk_component_table)

  # --- registered adaptations (FR-94) --------------------------------------
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    valid="$(printf '%s' "$row" | jq -r 'if .valid then "y" else "n" end')"
    tid="$(printf '%s' "$row" | jq -r '.id')"
    if [[ "$valid" == "y" ]]; then
      afk_verify_note "${tid:-<unnamed>}" "adaptation_valid" "PASS" "" \
        "$(printf '%s' "$row" | jq -r '.expected_identity')" ""
    else
      afk_verify_note "${tid:-<unnamed>}" "adaptation_valid" "FAIL" \
        "$(printf '%s' "$row" | jq -r '.validation_reason // "ADAPTATION_MALFORMED"')" "" ""
    fi
  done <<< "$AFK_ADAPT_RECORDS"

  # --- registered target wiring structure ----------------------------------
  # Structure only: proving persona/template resolution is live readiness work
  # and belongs to Story 1.3, so a missing target warns inside its own scope.
  n="$(printf '%s' "$manifest" | jq -r '(.targets // []) | length')"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  for (( i = 0; i < n; i++ )); do
    tid="$(printf '%s' "$manifest" | jq -r ".targets[$i].id // \"\"")"
    tpath="$(printf '%s' "$manifest" | jq -r ".targets[$i].path // \"\"")"
    [[ -n "$tid" ]] || continue
    if [[ -d "$tpath" ]]; then
      afk_verify_note "$tid" "target_structure" "PASS" "TARGET_READINESS_NOT_EVALUATED" "$tpath" "present"
    else
      afk_verify_note "$tid" "target_structure" "WARN" "TARGET_PATH_MISSING" "$tpath" "absent"
    fi
  done

  (( AFK_VERIFY_FAILURES == 0 ))
}

afk_verification_json() { # <verified: true|false>
  jq -nc \
    --arg verified "$1" \
    --arg checks "$AFK_VERIFY_CHECKS" \
    --arg failures "$AFK_VERIFY_FAILURES" \
    --arg warnings "$AFK_VERIFY_WARNINGS" \
    --argjson entries "$(afk_ndjson_to_array "$AFK_VERIFY_ENTRIES")" \
    '{verified: ($verified == "true"),
      offline: true,
      repaired: false,
      live_probes_performed: false,
      checks_run: ($checks | tonumber),
      failures: ($failures | tonumber),
      warnings: ($warnings | tonumber),
      checks: $entries}'
}

# --- the applied-state manifest (FR-44) -------------------------------------

afk_build_manifest_json() { # <applied-revision>
  local adaptations targets
  adaptations="$(printf '%s' "$AFK_MANIFEST_JSON" | jq -c 'if (.adaptations | type) == "array" then .adaptations else [] end')"
  [[ -n "$adaptations" ]] || adaptations="[]"
  targets="$(printf '%s' "$AFK_MANIFEST_JSON" | jq -c 'if (.targets | type) == "array" then .targets else [] end')"
  [[ -n "$targets" ]] || targets="[]"
  jq -nc \
    --arg lifecycle "$AFK_CO_LIFECYCLE_SCHEMA" \
    --arg state_schema "$AFK_SUPPORTED_STATE_SCHEMA_MAJOR.0" \
    --arg applied "$1" \
    --arg identity "$AFK_CO_REPO_IDENTITY" \
    --argjson components "$(afk_ndjson_to_array "$AFK_OP_POST_ENTRIES")" \
    --argjson adaptations "$adaptations" \
    --argjson targets "$targets" \
    '{lifecycle_schema_version: (if $lifecycle == "" then "1.0" else $lifecycle end),
      state_schema_version: $state_schema,
      applied_revision: $applied,
      repository: {identity: $identity},
      components: (reduce $components[] as $c ({};
                     .[$c.component] = {ownership: $c.ownership,
                                        identity: $c.identity,
                                        path: $c.path})),
      adaptations: $adaptations,
      targets: $targets}'
}

# One rename is the whole commit: the manifest names the prior revision or the
# target revision, never a half-written mixture of the two.
afk_manifest_commit() { # <manifest-json>
  [[ -n "$AFK_MANIFEST" ]] || return 1
  afk_state_file_write "$AFK_MANIFEST" "$1" || return 1
  return 0
}

# --- per-component execution ------------------------------------------------

AFK_STEP_REASON=""
AFK_STEP_DETAIL=""

# afk_component_prewrite_ok <plan-entry-json>
# The safety-critical prerequisites are revalidated immediately before THIS
# component's write, not merely once for the whole operation: a symlink can be
# planted between two writes of the same transaction.
afk_component_prewrite_ok() {
  local entry="$1" row id expected want
  AFK_STEP_REASON=""; AFK_STEP_DETAIL=""
  id="$(printf '%s' "$entry" | jq -r '.component')"
  expected="$(printf '%s' "$entry" | jq -r '.expected_destination_identity // ""')"
  want="$(printf '%s' "$entry" | jq -r '.guard.expected_type')"

  row="$(afk_component_row "$id")" || { AFK_STEP_REASON="PLAN_NOT_COMPUTABLE"; return 1; }
  afk_observe_component "$row"
  AFK_STEP_DETAIL="$id"

  if [[ "$AFK_OB_WANT" != "$want" ]]; then
    AFK_STEP_REASON="PLAN_STALE_DESTINATION_CHANGED"; return 1
  fi
  if [[ -z "$expected" ]]; then
    # The plan expected nothing there. Anything there now is a change, and
    # writing over it would be the destructive guess FR-23 forbids.
    if [[ "$AFK_OB_GUARD" == "PATH_ABSENT" ]] \
       || { [[ "$AFK_OB_OWNERSHIP" == "MANAGED_SECTION" ]] && (( AFK_OB_SECTION_RC == 2 )); }; then
      AFK_STEP_DETAIL=""
      return 0
    fi
    AFK_STEP_REASON="PLAN_STALE_DESTINATION_CHANGED"
    return 1
  fi
  if [[ "$AFK_OB_GUARD" != "PATH_OK" ]]; then
    AFK_STEP_REASON="$AFK_OB_GUARD"; return 1
  fi
  if [[ -n "$AFK_OB_ESCAPE" ]]; then
    AFK_STEP_REASON="PATH_ESCAPES_OWNERSHIP_BOUNDARY"; AFK_STEP_DETAIL="$AFK_OB_ESCAPE"; return 1
  fi
  if [[ "$AFK_OB_OBSERVED" != "$expected" ]]; then
    AFK_STEP_REASON="PLAN_STALE_DESTINATION_CHANGED"; return 1
  fi
  AFK_STEP_DETAIL=""
  return 0
}

# afk_component_apply <plan-entry-json>
# Writes exactly one component and proves the write produced the identity the
# plan predicted. Sets AFK_STEP_REASON on failure.
afk_component_apply() {
  local entry="$1" id ownership action dest source extra target row
  local outside_before outside_after store_plain store_terminated
  local meta_before meta_after
  AFK_STEP_REASON=""; AFK_STEP_DETAIL=""
  id="$(printf '%s' "$entry" | jq -r '.component')"
  ownership="$(printf '%s' "$entry" | jq -r '.ownership')"
  action="$(printf '%s' "$entry" | jq -r '.action')"
  dest="$(printf '%s' "$entry" | jq -r '.destination')"
  source="$(printf '%s' "$entry" | jq -r '.source // ""')"
  extra="$(printf '%s' "$entry" | jq -r '.guard.declared_extra // ""')"
  target="$(printf '%s' "$entry" | jq -r '.target_identity // ""')"

  # What the destination declares about itself, on the same terms as the
  # outside-bytes proof below: captured before the write, compared after it.
  # An empty value means the destination declared nothing (it did not exist, or
  # it is a symlink), and nothing is then required of the result.
  meta_before="$(afk_metadata_of "$dest")"

  case "$ownership" in
    MANAGED_COPY_TREE)
      afk_write_managed_tree "$AFK_KIT_ROOT/$source" "$dest" "$extra" \
        || { AFK_STEP_REASON="MANAGED_WRITE_FAILED"; AFK_STEP_DETAIL="$id"; return 1; } ;;
    MANAGED_COPY_FILE)
      afk_write_managed_file "$AFK_KIT_ROOT/$source" "$dest" \
        || { AFK_STEP_REASON="MANAGED_WRITE_FAILED"; AFK_STEP_DETAIL="$id"; return 1; } ;;
    MANAGED_LINK)
      afk_write_managed_link "$extra" "$dest" \
        || { AFK_STEP_REASON="MANAGED_WRITE_FAILED"; AFK_STEP_DETAIL="$id"; return 1; } ;;
    MANAGED_SECTION)
      outside_before="$(afk_outside_bytes "$dest" "$extra" | afk_sha256_stdin)"
      afk_write_managed_section "$dest" "$extra" "$AFK_KIT_ROOT/$source" \
        || { AFK_STEP_REASON="MANAGED_WRITE_FAILED"; AFK_STEP_DETAIL="$id"; return 1; }
      outside_after="$(afk_outside_bytes "$dest" "$extra" | afk_sha256_stdin)"
      if [[ "$action" == "INSTALL" ]]; then
        # Insertion: what survives outside the new section must be exactly the
        # file as it was, or that file plus the one contracted final newline.
        if afk_backup_exists "$id"; then
          store_plain="$(afk_sha256_file "$AFK_OP_BACKUP_DIR/$id")"
          store_terminated="$(afk_cat_terminated "$AFK_OP_BACKUP_DIR/$id" | afk_sha256_stdin)"
          if [[ "$outside_after" != "$store_plain" && "$outside_after" != "$store_terminated" ]]; then
            AFK_STEP_REASON="OUTSIDE_CONTENT_NOT_PRESERVED"; AFK_STEP_DETAIL="$id"; return 1
          fi
        fi
      elif [[ "$outside_before" != "$outside_after" ]]; then
        # Upgrading a section that already existed must not move one byte of
        # user-owned content.
        AFK_STEP_REASON="OUTSIDE_CONTENT_NOT_PRESERVED"; AFK_STEP_DETAIL="$id"; return 1
      fi ;;
    *)
      AFK_STEP_REASON="MANAGED_WRITE_FAILED"; AFK_STEP_DETAIL="$id"; return 1 ;;
  esac

  # A managed write replaces bytes the kit owns. It does not get to change what
  # the host owner decided about the file itself, and an unintended change is a
  # preservation failure exactly like a change to the bytes outside a section.
  if [[ -n "$meta_before" ]]; then
    meta_after="$(afk_metadata_of "$dest")"
    if [[ "$meta_after" != "$meta_before" ]]; then
      AFK_STEP_REASON="DESTINATION_METADATA_NOT_PRESERVED"; AFK_STEP_DETAIL="$id"; return 1
    fi
  fi

  # Prove the write produced what the plan predicted, from the filesystem.
  row="$(afk_component_row "$id")" || {
    AFK_STEP_REASON="POST_WRITE_IDENTITY_MISMATCH"; AFK_STEP_DETAIL="$id"; return 1; }
  afk_observe_component "$row"
  if [[ -z "$AFK_OB_OBSERVED" || "$AFK_OB_OBSERVED" != "$target" ]]; then
    AFK_STEP_REASON="POST_WRITE_IDENTITY_MISMATCH"
    AFK_STEP_DETAIL="$id"
    return 1
  fi
  return 0
}

afk_post_entry_add() { # <component> <ownership> <path> <identity>
  AFK_OP_POST_ENTRIES="${AFK_OP_POST_ENTRIES}$(jq -nc \
    --arg component "$1" --arg ownership "$2" --arg path "$3" --arg identity "$4" \
    '{component: $component, ownership: $ownership, path: $path, identity: $identity}')"$'\n'
}

# --- rollback (FR-42) -------------------------------------------------------

AFK_ROLLBACK_FAILED=""

afk_transaction_rollback() {
  local step id dest ok expected removal
  AFK_ROLLBACK_FAILED=""
  AFK_OP_ROLLBACK_STATE="IN_PROGRESS"
  afk_journal_write "ROLLING_BACK" || true

  # Reverse order: the last change made is the first undone.
  while IFS= read -r step; do
    [[ -n "$step" ]] || continue
    id="$(printf '%s' "$step" | jq -r '.component')"
    dest="$(printf '%s' "$step" | jq -r '.destination // ""')"
    [[ -n "$id" && -n "$dest" ]] || continue

    # Removal is authorized by the plan this operation is executing, and only
    # when it agrees with the backup store: the plan expected nothing at this
    # destination AND no copy was stored for it. Either alone is not enough,
    # and a disagreement between them is not resolved in favour of deleting.
    expected="$(printf '%s' "$AFK_PLAN_JSON" | jq -r --arg id "$id" \
      '.components[] | select(.component == $id) | .expected_destination_identity // ""')"
    if [[ -z "$expected" ]] && ! afk_backup_exists "$id"; then
      removal="true"
    else
      removal="false"
    fi

    if afk_restore_component "$id" "$dest" "$AFK_OP_BACKUP_DIR" "$removal"; then
      ok="true"
    else
      ok="false"
    fi

    # Restoration is VERIFIED, not assumed: the pre-mutation identity is
    # recomputed from the restored destination.
    if [[ "$ok" == "true" ]] && ! afk_restoration_verified "$id" "$expected"; then
      ok="false"
    fi
    if [[ "$ok" != "true" ]]; then
      AFK_ROLLBACK_FAILED="${AFK_ROLLBACK_FAILED}${AFK_ROLLBACK_FAILED:+,}$id"
    fi
  done < <(printf '%s' "$AFK_OP_STEPS" | afk_reverse_lines)

  if [[ -z "$AFK_ROLLBACK_FAILED" ]]; then
    AFK_OP_ROLLBACK_STATE="COMPLETE"
    afk_journal_write "ROLLED_BACK" || true
    return 0
  fi
  AFK_OP_ROLLBACK_STATE="INCOMPLETE"
  afk_journal_write "ROLLBACK_INCOMPLETE" || true
  return 1
}

# --- interrupted-operation recovery (FR-45) ---------------------------------
#
# Runs before ANY new mutation. An open journal means a previous operation did
# not reach its commit point; this increment prefers deterministic rollback
# over resume, and what cannot be rolled back deterministically stops with
# NEEDS_OWNER rather than being written over.

AFK_RECOVERY_STATE="NONE"
AFK_RECOVERY_DETAIL=""
AFK_RECOVERY_REASON=""

afk_recovery_refuse() { # <reason> <detail>
  AFK_RECOVERY_STATE="NEEDS_OWNER"
  AFK_RECOVERY_REASON="$1"
  AFK_RECOVERY_DETAIL="$2"
  return 1
}

# The journal names a destination. That is EVIDENCE that a destination was
# being touched — it is never, by itself, authority to change or remove it. The
# authority for a step is assembled from facts that must all agree:
#
#   * the journal is at a schema major version this executable implements;
#   * the component id is one the CURRENT declared inventory contains;
#   * the recorded destination is that component's declared destination;
#   * the journal agrees with itself — its plan entry and its pre-mutation
#     entry name the same component and the same expected identity;
#   * the destination passes the same containment and symlink guard every
#     other managed write passes;
#   * the backup directory is inside the declared backup root;
#   * and either a stored copy exists for that component, or the bound
#     pre-mutation observation says the destination held NOTHING and the step
#     is the INSTALL that created it.
#
# Anything missing, contradictory, undeclared or unprovable fails closed with
# NEEDS_OWNER and keeps the journal and every backup. Nothing falls through to
# `rm -rf`.
afk_recover_interrupted() {
  local doc state op backup_dir schema major steps step
  local id dest action row declared_dest plan_entry pre_entry
  local plan_dest plan_expected pre_identity removal
  local resolved_backups resolved_root
  AFK_RECOVERY_STATE="NONE"; AFK_RECOVERY_DETAIL=""; AFK_RECOVERY_REASON=""

  [[ -n "$AFK_JOURNAL" ]] || return 0
  [[ -e "$AFK_JOURNAL" || -L "$AFK_JOURNAL" ]] || return 0

  case "$AFK_JOURNAL_STATE" in
    NONE|COMMITTED) return 0 ;;
    UNSAFE|UNREADABLE)
      afk_recovery_refuse "OPERATION_RECOVERY_AUTHORITY_INSUFFICIENT" \
        "the operation journal is $AFK_JOURNAL_STATE"
      return 1 ;;
    *) : ;;
  esac

  doc="$(jq -c '.' "$AFK_JOURNAL" 2>/dev/null)" || doc=""
  if [[ -z "$doc" ]]; then
    afk_recovery_refuse "OPERATION_RECOVERY_AUTHORITY_INSUFFICIENT" \
      "the operation journal could not be parsed"
    return 1
  fi

  schema="$(printf '%s' "$doc" | jq -r 'if (.journal_schema_version | type) == "string"
        then .journal_schema_version else "" end')"
  major="${schema%%.*}"
  if [[ -z "$schema" || "$major" != "$AFK_SUPPORTED_JOURNAL_SCHEMA_MAJOR" ]]; then
    afk_recovery_refuse "OPERATION_JOURNAL_SCHEMA_UNSUPPORTED" \
      "journal schema ${schema:-unversioned}"
    return 1
  fi

  state="$(printf '%s' "$doc" | jq -r 'if (.state | type) == "string" then .state else "" end')"
  op="$(printf '%s' "$doc" | jq -r 'if (.operation_id | type) == "string" then .operation_id else "" end')"
  backup_dir="$(printf '%s' "$doc" | jq -r 'if (.backup_dir | type) == "string" then .backup_dir else "" end')"
  steps="$(printf '%s' "$doc" | jq -c '(.completed_steps // [])[]' 2>/dev/null)"

  if [[ "$state" == "ROLLED_BACK" ]]; then
    # A previous run already restored everything and proved it; the journal is
    # merely stale.
    AFK_RECOVERY_STATE="RECOVERED"
    AFK_RECOVERY_DETAIL="${op:-the previous operation} was already rolled back"
    afk_journal_mark_committed
    afk_sweep_orphan_recovery_material ""
    return 0
  fi
  if [[ -z "$steps" ]]; then
    # Nothing was recorded as touched, so there is nothing to undo. This is
    # also the shape a run killed between opening its journal and finishing its
    # backups leaves behind, so its recovery material is reclaimed here.
    AFK_RECOVERY_STATE="RECOVERED"
    AFK_RECOVERY_DETAIL="${op:-the previous operation} wrote nothing"
    afk_journal_mark_committed
    afk_sweep_orphan_recovery_material ""
    return 0
  fi

  if [[ -z "$backup_dir" ]]; then
    afk_recovery_refuse "OPERATION_RECOVERY_AUTHORITY_INSUFFICIENT" \
      "recovery material for ${op:-the interrupted operation} is missing"
    return 1
  fi
  if [[ ! -d "$backup_dir" || -L "$backup_dir" ]]; then
    afk_recovery_refuse "OPERATION_RECOVERY_AUTHORITY_INSUFFICIENT" \
      "recovery material for ${op:-the interrupted operation} is missing"
    return 1
  fi
  # Containment is proved on the RESOLVED paths, so neither a `..` component nor
  # a symlinked backup directory can name recovery material outside the
  # declared state directory.
  resolved_backups="$(afk_realpath "$backup_dir")" || resolved_backups=""
  resolved_root="$(afk_realpath "${AFK_BACKUP_ROOT:-}")" || resolved_root=""
  if [[ -z "$resolved_backups" || -z "$resolved_root" ]] \
     || ! afk_is_within "$resolved_backups" "$resolved_root"; then
    afk_recovery_refuse "OPERATION_RECOVERY_AUTHORITY_INSUFFICIENT" \
      "the journal names a backup directory outside the declared state directory"
    return 1
  fi

  while IFS= read -r step; do
    [[ -n "$step" ]] || continue
    id="$(printf '%s' "$step" | jq -r '.component // ""')"
    dest="$(printf '%s' "$step" | jq -r '.destination // ""')"
    action="$(printf '%s' "$step" | jq -r '.action // ""')"
    if [[ -z "$id" || -z "$dest" ]]; then
      afk_recovery_refuse "OPERATION_RECOVERY_AUTHORITY_INSUFFICIENT" \
        "a recorded step names no component or no destination"
      return 1
    fi
    case "$action" in
      REPLACE|INSTALL) : ;;
      *) afk_recovery_refuse "OPERATION_RECOVERY_AUTHORITY_INSUFFICIENT" \
           "$id records no recognized operation binding"
         return 1 ;;
    esac

    # --- the component must be one this executable declares, at the
    #     destination it declares for it.
    if ! row="$(afk_component_row "$id")"; then
      afk_recovery_refuse "OPERATION_RECOVERY_AUTHORITY_INSUFFICIENT" \
        "$id is not a component this lifecycle declares"
      return 1
    fi
    declared_dest="$(printf '%s' "$row" | cut -d'|' -f6)"
    if [[ "$dest" != "$declared_dest" ]]; then
      afk_recovery_refuse "OPERATION_RECOVERY_AUTHORITY_INSUFFICIENT" \
        "$id records a destination this lifecycle does not declare for it"
      return 1
    fi

    # --- the journal must agree with itself -------------------------------
    plan_entry="$(printf '%s' "$doc" | jq -c --arg id "$id" \
      '[(.plan.components // [])[] | select(.component == $id)] | .[0] // empty' 2>/dev/null)"
    pre_entry="$(printf '%s' "$doc" | jq -c --arg id "$id" \
      '[(.pre_mutation // [])[] | select(.component == $id)] | .[0] // empty' 2>/dev/null)"
    if [[ -z "$plan_entry" || -z "$pre_entry" ]]; then
      afk_recovery_refuse "OPERATION_RECOVERY_AUTHORITY_INSUFFICIENT" \
        "$id is recorded as touched but the journal binds no plan or pre-mutation record for it"
      return 1
    fi
    plan_dest="$(printf '%s' "$plan_entry" | jq -r '.destination // ""')"
    plan_expected="$(printf '%s' "$plan_entry" | jq -r '.expected_destination_identity // ""')"
    pre_identity="$(printf '%s' "$pre_entry" | jq -r '.observed_identity // ""')"
    if [[ "$plan_dest" != "$dest" || "$plan_expected" != "$pre_identity" ]]; then
      afk_recovery_refuse "OPERATION_RECOVERY_AUTHORITY_INSUFFICIENT" \
        "the journal's plan and pre-mutation records disagree about $id"
      return 1
    fi

    # --- the same guard every managed write passes ------------------------
    afk_observe_component "$row"
    case "$AFK_OB_GUARD" in
      PATH_OK|PATH_ABSENT) : ;;
      *) afk_recovery_refuse "OPERATION_RECOVERY_AUTHORITY_INSUFFICIENT" \
           "$id: $AFK_OB_GUARD"
         return 1 ;;
    esac
    if [[ -n "$AFK_OB_ESCAPE" ]]; then
      afk_recovery_refuse "OPERATION_RECOVERY_AUTHORITY_INSUFFICIENT" \
        "$id: PATH_ESCAPES_OWNERSHIP_BOUNDARY"
      return 1
    fi

    # --- authority to restore, or authority to remove ---------------------
    if afk_backup_exists "$id" "$backup_dir"; then
      removal="false"
    else
      if [[ -n "$pre_identity" ]]; then
        afk_recovery_refuse "OPERATION_RECOVERY_AUTHORITY_INSUFFICIENT" \
          "$id records pre-mutation content but no copy of it was stored"
        return 1
      fi
      if [[ "$action" != "INSTALL" ]]; then
        afk_recovery_refuse "OPERATION_RECOVERY_AUTHORITY_INSUFFICIENT" \
          "$id records a $action with no stored copy to restore"
        return 1
      fi
      removal="true"
    fi

    if ! afk_restore_component "$id" "$dest" "$backup_dir" "$removal"; then
      afk_recovery_refuse "OPERATION_RECOVERY_AUTHORITY_INSUFFICIENT" \
        "could not restore $id"
      return 1
    fi
    if ! afk_restoration_verified "$id" "$pre_identity"; then
      afk_recovery_refuse "OPERATION_RECOVERY_VERIFICATION_FAILED" "$id"
      return 1
    fi
  done < <(printf '%s\n' "$steps" | afk_reverse_lines)

  AFK_RECOVERY_STATE="RECOVERED"
  AFK_RECOVERY_DETAIL="${op:-the interrupted operation} was rolled back"
  afk_journal_mark_committed
  afk_sweep_orphan_recovery_material ""
  return 0
}

# Housekeeping only: it marks the journal closed and can never change what a
# committed manifest means.
afk_journal_mark_committed() {
  local doc
  [[ -n "$AFK_JOURNAL" ]] || return 1
  [[ -f "$AFK_JOURNAL" && ! -L "$AFK_JOURNAL" ]] || return 1
  doc="$(jq -c '.state = "COMMITTED"' "$AFK_JOURNAL" 2>/dev/null)" || return 1
  [[ -n "$doc" ]] || return 1
  afk_state_file_write "$AFK_JOURNAL" "$doc" || return 1
  return 0
}

# --- the transaction --------------------------------------------------------
#
# One function owns the whole mutating phase. Every early return leaves the
# installation exactly as it was found, and every late failure goes through
# rollback before it returns.

afk_transaction_execute() { # <command: adopt|update>
  local command="$1" entry action id dest ownership record_identity applied_identity
  local manifest_json target_revision

  AFK_OP_STEPS=""
  AFK_OP_POST_ENTRIES=""
  AFK_OP_MUTATED="false"
  AFK_OP_COMMITTED="false"
  AFK_OP_ROLLBACK_STATE="NOT_REQUIRED"
  AFK_OP_REASON=""
  AFK_OP_DETAIL=""
  AFK_OP_PRIOR_REVISION="$AFK_APPLIED_REVISION"
  # The revision the host has ACTUALLY applied. It moves once, after the commit
  # that makes it true, and never before: reporting the target here would name
  # a revision this host never carried on every failure path after the first
  # write, including a rollback that completed correctly.
  AFK_OP_APPLIED_REVISION="$AFK_APPLIED_REVISION"
  AFK_OP_TARGET_REVISION="$AFK_CO_REVISION"

  # --- the mutation boundary: revalidate every bound input (FR-91) ---------
  if ! afk_plan_revalidate; then
    AFK_OP_RESULT="STALE_PLAN"
    AFK_OP_REASON="$AFK_PLAN_STALE_REASON"
    AFK_OP_DETAIL="$AFK_PLAN_STALE_DETAIL"
    return 1
  fi

  AFK_OP_ID="op-$(printf '%s' "$AFK_PLAN_IDENTITY" | tr -d ':' | cut -c 7-22)"
  AFK_OP_BACKUP_DIR="$AFK_BACKUP_ROOT/$AFK_OP_ID"
  AFK_OP_STAGE_DIR="$AFK_STAGE_ROOT/$AFK_OP_ID"
  AFK_VERIFY_OWN_OPERATION="$AFK_OP_ID"

  # --- recovery material exists BEFORE the first write (FR-41) -------------
  if ! mkdir -p -- "$AFK_OP_BACKUP_DIR" "$AFK_OP_STAGE_DIR" 2>/dev/null; then
    AFK_OP_RESULT="REFUSED"
    AFK_OP_REASON="BACKUP_PREREQUISITE_UNMET"
    AFK_OP_DETAIL="the recovery directory could not be created"
    return 1
  fi

  # The journal names this operation's backup directory BEFORE that directory
  # is filled. A run killed inside the backup loop would otherwise leave copies
  # of user content that no journal references and nothing ever reclaims; with
  # a PREPARING record on disk, the next command finds an operation that wrote
  # nothing, closes it, and sweeps the material it named.
  if ! afk_journal_write "PREPARING"; then
    AFK_OP_RESULT="REFUSED"
    AFK_OP_REASON="BACKUP_PREREQUISITE_UNMET"
    AFK_OP_DETAIL="the recovery journal could not be written"
    return 1
  fi

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    action="$(printf '%s' "$entry" | jq -r '.action')"
    case "$action" in REPLACE|INSTALL) : ;; *) continue ;; esac
    id="$(printf '%s' "$entry" | jq -r '.component')"
    dest="$(printf '%s' "$entry" | jq -r '.destination')"
    if ! afk_parent_writable "$dest"; then
      mkdir -p -- "$(dirname -- "$dest")" 2>/dev/null
      if ! afk_parent_writable "$dest"; then
        AFK_OP_RESULT="REFUSED"
        AFK_OP_REASON="PERMISSION_PREREQUISITE_UNMET"
        AFK_OP_DETAIL="$id"
        return 1
      fi
    fi
    if ! afk_backup_component "$id" "$dest"; then
      AFK_OP_RESULT="REFUSED"
      AFK_OP_REASON="BACKUP_PREREQUISITE_UNMET"
      AFK_OP_DETAIL="$id"
      return 1
    fi
  done < <(printf '%s' "$AFK_PLAN_ENTRIES")

  if ! afk_journal_write "IN_PROGRESS"; then
    AFK_OP_RESULT="REFUSED"
    AFK_OP_REASON="BACKUP_PREREQUISITE_UNMET"
    AFK_OP_DETAIL="the recovery journal could not be written"
    return 1
  fi

  # --- writes --------------------------------------------------------------
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    action="$(printf '%s' "$entry" | jq -r '.action')"
    id="$(printf '%s' "$entry" | jq -r '.component')"
    dest="$(printf '%s' "$entry" | jq -r '.destination')"
    ownership="$(printf '%s' "$entry" | jq -r '.ownership')"

    case "$action" in
      REPLACE|INSTALL)
        if ! afk_component_prewrite_ok "$entry"; then
          AFK_OP_RESULT="ROLLED_BACK"
          AFK_OP_REASON="${AFK_STEP_REASON:-PLAN_STALE_DESTINATION_CHANGED}"
          AFK_OP_DETAIL="$AFK_STEP_DETAIL"
          afk_transaction_finish_failure
          return 1
        fi
        afk_journal_step "$id" "$action" "ATTEMPTED" "$dest"
        afk_journal_write "IN_PROGRESS" || true
        AFK_OP_MUTATED="true"
        if ! afk_component_apply "$entry"; then
          AFK_OP_RESULT="ROLLED_BACK"
          AFK_OP_REASON="${AFK_STEP_REASON:-MANAGED_WRITE_FAILED}"
          AFK_OP_DETAIL="$AFK_STEP_DETAIL"
          afk_journal_step_result "$id" "FAILED" || true
          afk_transaction_finish_failure
          return 1
        fi
        afk_journal_step_result "$id" "APPLIED" || true
        afk_journal_write "IN_PROGRESS" || true
        afk_post_entry_add "$id" "$ownership" "$dest" "$AFK_OB_OBSERVED"
        ;;
      CLAIM|NONE|PRESERVE)
        # No write. The identity that will be recorded is re-observed rather
        # than copied from the plan, so the manifest describes the filesystem.
        [[ "$ownership" != "MACHINE_LOCAL" ]] || continue
        if ! afk_component_prewrite_ok "$entry"; then
          AFK_OP_RESULT="ROLLED_BACK"
          AFK_OP_REASON="${AFK_STEP_REASON:-PLAN_STALE_DESTINATION_CHANGED}"
          AFK_OP_DETAIL="$AFK_STEP_DETAIL"
          afk_transaction_finish_failure
          return 1
        fi
        [[ -n "$AFK_OB_OBSERVED" ]] || continue
        record_identity="$AFK_OB_OBSERVED"
        if [[ "$action" == "PRESERVE" ]]; then
          # A preserved adaptation must not become the recorded BASELINE: the
          # applied identity stays the canonical revision this host is at, and
          # the adaptation record keeps explaining the difference. Recording
          # the adapted bytes instead would quietly turn an exception into the
          # thing the next update replaces.
          applied_identity="$(printf '%s' "$entry" | jq -r '.applied_identity // ""')"
          [[ -z "$applied_identity" ]] || record_identity="$applied_identity"
        fi
        afk_post_entry_add "$id" "$ownership" "$dest" "$record_identity"
        ;;
      *) : ;;
    esac
  done < <(printf '%s' "$AFK_PLAN_ENTRIES")

  # --- final offline verification BEFORE any authority transition ----------
  # The manifest is BUILT for the target revision; the operation does not claim
  # to have applied it until the commit below succeeds.
  target_revision="$AFK_CO_REVISION"
  manifest_json="$(afk_build_manifest_json "$target_revision")"
  if [[ -z "$manifest_json" ]]; then
    AFK_OP_RESULT="ROLLED_BACK"
    AFK_OP_REASON="STATE_MANIFEST_WRITE_FAILED"
    afk_transaction_finish_failure
    return 1
  fi
  if ! afk_verify_against_manifest "$manifest_json" "$target_revision"; then
    AFK_OP_RESULT="ROLLED_BACK"
    AFK_OP_REASON="VERIFICATION_FAILED"
    afk_transaction_finish_failure
    return 1
  fi

  # --- the single durable authority transition (FR-43, FR-44) --------------
  if ! afk_manifest_commit "$manifest_json"; then
    AFK_OP_RESULT="ROLLED_BACK"
    AFK_OP_REASON="STATE_MANIFEST_WRITE_FAILED"
    afk_transaction_finish_failure
    return 1
  fi
  AFK_OP_COMMITTED="true"
  AFK_OP_APPLIED_REVISION="$target_revision"

  # --- housekeeping (cannot change what the commit means) ------------------
  afk_journal_mark_committed || true
  rm -rf -- "$AFK_OP_BACKUP_DIR" "$AFK_OP_STAGE_DIR" 2>/dev/null
  afk_sweep_orphan_recovery_material "$AFK_OP_ID"

  if [[ "$command" == "adopt" ]]; then
    AFK_OP_RESULT="ADOPTED"
  else
    AFK_OP_RESULT="CONVERGED"
  fi
  AFK_OP_REASON="VERIFICATION_PASSED"
  return 0
}

afk_transaction_finish_failure() {
  # Nothing reached the commit, so the applied revision is still the prior one.
  # This is belt and braces: the assignment that moves it lives after the
  # commit. Both exist because a failure path that names the target revision
  # beside the prior one reads as "this run advanced the host".
  AFK_OP_APPLIED_REVISION="$AFK_OP_PRIOR_REVISION"
  AFK_OP_COMMITTED="false"
  if [[ "$AFK_OP_MUTATED" != "true" ]]; then
    # Nothing was written, so there is nothing to restore. A plan that went
    # stale between the boundary check and a component's own check is exactly
    # this case, and it is reported as staleness rather than as a rollback.
    AFK_OP_ROLLBACK_STATE="NOT_REQUIRED"
    case "$AFK_OP_REASON" in
      PLAN_STALE_*) AFK_OP_RESULT="STALE_PLAN" ;;
      *) : ;;
    esac
    afk_journal_write "ROLLED_BACK" || true
    afk_journal_mark_committed || true
    rm -rf -- "$AFK_OP_BACKUP_DIR" "$AFK_OP_STAGE_DIR" 2>/dev/null
    afk_sweep_orphan_recovery_material "$AFK_OP_ID"
    return 0
  fi
  if afk_transaction_rollback; then
    afk_journal_mark_committed || true
    rm -rf -- "$AFK_OP_BACKUP_DIR" "$AFK_OP_STAGE_DIR" 2>/dev/null
    afk_sweep_orphan_recovery_material "$AFK_OP_ID"
    return 0
  fi
  # Restoration could not complete. The journal and every backup stay exactly
  # where they are: they are the owner's recovery material.
  AFK_OP_RESULT="UNRECOVERABLE"
  AFK_OP_REASON="OPERATION_ROLLBACK_INCOMPLETE"
  AFK_OP_DETAIL="$AFK_ROLLBACK_FAILED"
  return 1
}

afk_operation_json() {
  jq -nc \
    --arg id "$AFK_OP_ID" \
    --arg command "$AFK_PLAN_COMMAND" \
    --arg result "$AFK_OP_RESULT" \
    --arg reason "$AFK_OP_REASON" \
    --arg detail "$AFK_OP_DETAIL" \
    --arg plan_identity "$AFK_PLAN_IDENTITY" \
    --arg rollback "$AFK_OP_ROLLBACK_STATE" \
    --arg mutated "$AFK_OP_MUTATED" \
    --arg committed "$AFK_OP_COMMITTED" \
    --arg applied "${AFK_OP_APPLIED_REVISION:-$AFK_APPLIED_REVISION}" \
    --arg prior "${AFK_OP_PRIOR_REVISION:-$AFK_APPLIED_REVISION}" \
    --arg target "${AFK_OP_TARGET_REVISION:-}" \
    --argjson steps "$(afk_ndjson_to_array "$AFK_OP_STEPS")" \
    '{id: (if $id == "" then null else $id end),
      command: $command,
      mutating: true,
      result: $result,
      reason: (if $reason == "" then null else $reason end),
      detail: (if $detail == "" then null else $detail end),
      plan_identity: (if $plan_identity == "" then null else $plan_identity end),
      mutation_performed: ($mutated == "true"),
      applied_state_committed: ($committed == "true"),
      rollback_state: $rollback,
      prior_revision: (if $prior == "" then null else $prior end),
      applied_revision: (if $applied == "" then null else $applied end),
      target_revision: (if $target == "" then null else $target end),
      completed_steps: $steps}'
}
