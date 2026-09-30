#!/usr/bin/env bash
# afk-monitor.sh — the durable worker-completion watch, and the
# provenance-bound release of the resources one dispatched worker owned.
#
# This file is SOURCED, never executed, and like every other lifecycle library
# it does not set -e: every step reports through a state and a stable reason
# code, and a step that cannot answer says so rather than aborting the run.
#
# WHY THIS EXISTS
#
# A coordinator that launches a worker and then relies on a later human message
# to make it look again is not an orchestration loop: the completion arrives
# while nobody is watching, and the worker's terminal, worktree and branch stay
# behind because the moment they could have been released passed unobserved.
# The watch therefore lives on DISK, not in a turn:
#
#   watch/<dispatch_id>.json   the durable record of one supervised Dispatch.
#                              It is written before control is yielded and it
#                              survives coordinator turns, coordinator restarts
#                              and Orca disconnects.
#   inbox/<delivery_id>.json   deliveries the supervised transport commits. A
#                              delivery is consumed by a later invocation; it is
#                              never lost because nobody was listening.
#   results/<dispatch_id>.*    the retained compact result and its traceability
#                              record, kept OUTSIDE the worktree that produced
#                              them so the worktree can be released afterwards.
#
# COMPLETION AUTHORITY
#
# Only a supervised `worker_done` or `escalation` delivery completes a worker.
# Terminal idleness, an exited process, transcript text, provider session
# history and tab state are diagnostic observations: each of them can be true of
# a worker that failed, was killed, or never started, so none of them may
# manufacture a result. A watched dispatch whose terminal exits without a
# delivery becomes a loud monitoring FAULT, and a heartbeat that expires becomes
# a different loud fault — neither becomes DONE and neither becomes FAILED.
#
# AT-LEAST-ONCE, IDEMPOTENT
#
# Delivery is at-least-once, so the same `worker_done` can arrive twice: after
# an Orca disconnect that dropped the acknowledgement, or after a coordinator
# restart. The order here is retention, reconciliation, THEN acknowledgement,
# and every effect is keyed by `delivery_id`: a replay is recognized, the
# duplicate is dropped, and it can neither schedule settlement twice, write a
# second traceability record, nor repeat a cleanup that already happened.
#
# BOUNDED, NEVER A BUSY LOOP
#
# Nothing here blocks. There is no `--wait`, no rolling poll and no long-lived
# turn: each invocation performs one bounded pass over the inbox and the watch
# set and returns. The record carries the declared poll interval and backoff
# ceiling so a scheduler outside this process can drive the next pass; that is
# the whole of the loop, and it cannot spin. Every observation that leaves this
# host — the Orca listing, the durable close, and the three remote-branch git
# calls — runs under the same declared bound and never prompts, and a host that
# cannot enforce that bound does not get the call run unbounded: the observation
# is refused, reported as PROBE_BOUND_UNAVAILABLE, and whatever it could not
# decide is retained for its owner. A pass that reached the network through an
# unbounded call would be exactly the hang this engine exists to remove.
#
# CLEANUP IS PROVENANCE-BOUND
#
# A resource is a cleanup candidate only because a watch record proves AFK
# created it for this exact Dispatch. Nothing is ever swept by age, by name, or
# by looking like scratch: a coordinator's own terminal, a user's branch, a
# protected branch and a legacy worktree have no provenance here and are
# therefore not reachable by this code at all. Every disposition is reported
# independently as REMOVED, RETAINED, NOT_APPLICABLE or NEEDS_OWNER, and
# ambiguity fails closed on NEEDS_OWNER rather than deleting.
#
# LIVE BOUNDARY
#
# The read-only summary is a filesystem fact and is computed on every command.
# Registration and reconciliation are filesystem work and start no process. The
# settlement pass has to ask Orca whether a terminal may be closed and has to
# prove it closed, so it is gated behind explicit `--live` exactly like every
# other external observation in this kit.
#
# shellcheck disable=SC2034,SC2154
# The AFK_R_DISPATCH result-model input is declared here and read by
# afk_build_result and afk_render_human in afk-common.sh; the lifecycle files
# are always sourced together and `set -u` in the entry point is the real guard
# against an unset read.

if [[ -n "${AFK_MONITOR_SOURCED:-}" ]]; then
  return 0
fi
AFK_MONITOR_SOURCED=1

# The one Orca resolver and bounded runner (AD-28 R1, R2).
# shellcheck source=lib/afk-orca.sh
# shellcheck disable=SC1091
declare -F afk_orca_run >/dev/null 2>&1 || . "$(dirname -- "${BASH_SOURCE[0]}")/afk-orca.sh"

AFK_SUPPORTED_DISPATCH_SCHEMA_MAJOR="1"

# --- declared local configuration -------------------------------------------
# Assigned to a default only when the caller left them empty, exactly like the
# declared paths in afk-common.sh. bin/agent-flow-kit re-derives them after it
# has resolved AFK_STATE_DIR, so a lib sourced on its own never reads an unset
# variable and the entry point never inherits an empty derivation.

AFK_DISPATCH_DIR="${AFK_DISPATCH_DIR:-${AFK_STATE_DIR:+$AFK_STATE_DIR/dispatch}}"
AFK_DISPATCH_WATCH_DIR="${AFK_DISPATCH_WATCH_DIR:-${AFK_DISPATCH_DIR:+$AFK_DISPATCH_DIR/watch}}"
AFK_DISPATCH_INBOX_DIR="${AFK_DISPATCH_INBOX_DIR:-${AFK_DISPATCH_DIR:+$AFK_DISPATCH_DIR/inbox}}"
AFK_DISPATCH_RESULT_DIR="${AFK_DISPATCH_RESULT_DIR:-${AFK_DISPATCH_DIR:+$AFK_DISPATCH_DIR/results}}"
AFK_DISPATCH_MESSAGE_DIR="${AFK_DISPATCH_MESSAGE_DIR:-${AFK_DISPATCH_DIR:+$AFK_DISPATCH_DIR/messages}}"

# The bounded watch budget. These are carried ON the record so the scheduler
# that drives the next pass reads them from the same place the monitor wrote
# them; nothing here sleeps for them.
AFK_MONITOR_POLL_SECONDS="${AFK_MONITOR_POLL_SECONDS:-15}"
AFK_MONITOR_BACKOFF_CEILING_SECONDS="${AFK_MONITOR_BACKOFF_CEILING_SECONDS:-300}"
AFK_MONITOR_HEARTBEAT_SECONDS="${AFK_MONITOR_HEARTBEAT_SECONDS:-1800}"

# Branch names that are never a deletion candidate whatever a record claims.
# This is a floor, not the rule: the rule is provenance, and a branch AFK
# cannot prove it created for this Dispatch is already unreachable here.
AFK_MONITOR_PROTECTED_BRANCHES="${AFK_MONITOR_PROTECTED_BRANCHES:-master
main
develop
release
HEAD}"

# --- run inputs (assigned by bin/agent-flow-kit) ----------------------------

AFK_MONITOR_MODE="${AFK_MONITOR_MODE:-report}"   # report|register|reconcile|cleanup
AFK_MONITOR_LIVE="${AFK_MONITOR_LIVE:-false}"
AFK_MONITOR_DESCRIPTOR="${AFK_MONITOR_DESCRIPTOR:-}"

# --- accumulated monitor state ----------------------------------------------

AFK_DISPATCH_EMPTY='{"state": "NOT_AVAILABLE", "evaluated": false, "reason": "DISPATCH_WATCH_NOT_AVAILABLE", "counts": null, "pending_deliveries": 0, "retained": null, "dispatches": [], "required_action": null}'
AFK_R_DISPATCH="$AFK_DISPATCH_EMPTY"

# Two flags, because they answer two different questions.
#
# AFK_MON_PASS_NEEDS_HUMAN is what THIS pass did and could not resolve: a
# descriptor it refused, a delivery it could not read, a resource it would not
# release. Those facts leave no mark in the watch set a later reading could
# recover, so they are carried across the pass.
#
# AFK_MON_NEEDS_HUMAN is the DERIVED verdict, and it belongs to the reading
# afk_monitor_summarize just took. The summary runs twice per monitor
# invocation — once before the action and once after it — and the second
# reading must be allowed to disagree with the first: a pass that repaired the
# only degraded Dispatch it found describes the state it left behind, not the
# union of everything the process ever saw.
AFK_MON_NEEDS_HUMAN="false"
AFK_MON_PASS_NEEDS_HUMAN="false"
AFK_MON_REPLAYS=0
AFK_MON_CONSUMED=0
AFK_MON_TERMINALS_JSON="[]"
AFK_MON_TERMINALS_LOADED="false"
AFK_MON_GIT_OUT=""
AFK_MON_GIT_STATUS=""

afk_monitor_reset() {
  AFK_R_DISPATCH="$AFK_DISPATCH_EMPTY"
  AFK_MON_NEEDS_HUMAN="false"
  AFK_MON_PASS_NEEDS_HUMAN="false"
  AFK_MON_REPLAYS=0
  AFK_MON_CONSUMED=0
  AFK_MON_TERMINALS_JSON="[]"
  AFK_MON_TERMINALS_LOADED="false"
  AFK_MON_GIT_OUT=""
  AFK_MON_GIT_STATUS=""
}

# One unresolved fact this pass produced. It is recorded on the pass as well as
# on the derived verdict, so re-reading the watch set cannot erase it.
afk_monitor_needs_human() {
  AFK_MON_PASS_NEEDS_HUMAN="true"
  AFK_MON_NEEDS_HUMAN="true"
}

# --- the published monitor reason vocabulary --------------------------------
#
# Co-located with the engine that emits them, exactly like the readiness half:
# a code, the sentence that explains it and the action that resolves it are
# added in one place, and afk_reason_message/afk_reason_action consult this hook
# before their own table. Both print nothing for a code they do not own.

afk_monitor_reason_codes() {
  cat <<'CODES'
DISPATCH_WATCH_NOT_AVAILABLE
DISPATCH_WATCH_IDLE
DISPATCH_WATCH_ACTIVE
DISPATCH_WATCH_REGISTERED
DISPATCH_DESCRIPTOR_INVALID
DISPATCH_RECORD_UNREADABLE
DISPATCH_RECORD_SCHEMA_UNSUPPORTED
DISPATCH_UNKNOWN
DELIVERY_UNREADABLE
DELIVERY_REPLAY_IGNORED
WORKER_DONE_RETAINED
WORKER_ESCALATION_RETAINED
RESULT_NOT_RETAINED
RESULT_UNPARSEABLE
WORKER_HEARTBEAT_EXPIRED
WORKER_TERMINAL_EXITED_WITHOUT_DELIVERY
MONITOR_DEGRADED
TERMINAL_RELEASED
TERMINAL_RELEASE_UNPROVEN
TERMINAL_RETAINED_ACTIVE
TERMINAL_RETAINED_AWAITING_ANSWER
TERMINAL_RETAINED_AMBIGUOUS
TERMINAL_RETAINED_USER_TAKEOVER
TERMINAL_NOT_OWNED
WORKTREE_REMOVED
WORKTREE_RETAINED_UNSETTLED
WORKTREE_RETAINED_DIRTY
WORKTREE_NOT_OWNED
BRANCH_DELETED
BRANCH_RETAINED_UNMERGED
BRANCH_RETAINED_UNIQUE_COMMITS
BRANCH_RETAINED_PROTECTED
BRANCH_RETAINED_WORKTREE_PRESENT
BRANCH_NOT_OWNED
REMOTE_BRANCH_DELETED
REMOTE_BRANCH_ABSENT
REMOTE_BRANCH_RETAINED_UNAUTHORIZED
CLEANUP_NEEDS_OWNER
CLEANUP_COMPLETE
CODES
}

afk_monitor_reason_message() { # <reason> — empty for a code this file does not own
  case "$1" in
    DISPATCH_WATCH_NOT_AVAILABLE)  printf 'No durable dispatch watch exists on this host, so no supervised worker is being watched from here.' ;;
    DISPATCH_WATCH_IDLE)           printf 'The durable dispatch watch exists and holds no unsettled Dispatch.' ;;
    DISPATCH_WATCH_ACTIVE)         printf 'The durable dispatch watch holds at least one Dispatch that has not settled yet.' ;;
    DISPATCH_WATCH_REGISTERED)     printf 'A durable watch record covers this Dispatch, so its completion will be consumed by a later pass rather than by a live turn.' ;;
    DISPATCH_DESCRIPTOR_INVALID)   printf 'The supplied dispatch descriptor does not present the members a durable watch record is built from.' ;;
    DISPATCH_RECORD_UNREADABLE)    printf 'A durable watch record exists but could not be parsed, so the Dispatch it describes cannot be reconciled.' ;;
    DISPATCH_RECORD_SCHEMA_UNSUPPORTED) printf 'A durable watch record declares a newer major schema than this lifecycle consumes.' ;;
    DISPATCH_UNKNOWN)              printf 'A completion delivery names a Dispatch this host holds no watch record for, so there is nothing it can be reconciled against.' ;;
    DELIVERY_UNREADABLE)           printf 'A completion delivery could not be read as the declared delivery shape, so it is retained unacknowledged rather than discarded.' ;;
    DELIVERY_REPLAY_IGNORED)       printf 'A completion delivery that was already consumed arrived again; delivery is at-least-once, so the duplicate was dropped without repeating any effect.' ;;
    WORKER_DONE_RETAINED)          printf 'A supervised worker_done was retained, reconciled against its Dispatch, and only then acknowledged.' ;;
    WORKER_ESCALATION_RETAINED)    printf 'A supervised worker escalation was retained and reconciled; it completes the watch and hands the decision to a human.' ;;
    RESULT_NOT_RETAINED)           printf 'A completion result could not be retained outside the worker workspace, so it was not acknowledged and the delivery remains recoverable.' ;;
    RESULT_UNPARSEABLE)            printf 'A completion delivery carried no readable result status, so nothing about the worker outcome can be recorded.' ;;
    WORKER_HEARTBEAT_EXPIRED)      printf 'A watched worker stopped reporting inside its declared heartbeat window; this is a monitoring fault and is not a worker result.' ;;
    WORKER_TERMINAL_EXITED_WITHOUT_DELIVERY) printf 'A watched worker terminal is gone and no supervised completion delivery ever arrived, so the outcome is unknown rather than done.' ;;
    MONITOR_DEGRADED)              printf 'The completion watch for at least one Dispatch is degraded: it can neither complete it nor invent an outcome for it.' ;;
    TERMINAL_RELEASED)             printf 'The AFK-owned worker terminal was released through the supervised lifecycle and is durably absent afterwards.' ;;
    TERMINAL_RELEASE_UNPROVEN)     printf 'A durable close was requested for the AFK-owned worker terminal and its absence could not be proven afterwards.' ;;
    TERMINAL_RETAINED_ACTIVE)      printf 'The worker terminal is still active, so generic cleanup does not touch it.' ;;
    TERMINAL_RETAINED_AWAITING_ANSWER) printf 'The worker terminal is waiting on an answer, so generic cleanup does not touch it.' ;;
    TERMINAL_RETAINED_AMBIGUOUS)   printf 'The worker terminal is in an ambiguous state, so generic cleanup does not touch it.' ;;
    TERMINAL_RETAINED_USER_TAKEOVER) printf 'The worker terminal was taken over by its user, so generic cleanup does not touch it.' ;;
    TERMINAL_NOT_OWNED)            printf 'No AFK-owned worker terminal is recorded for this Dispatch, so there is none for settlement to release.' ;;
    WORKTREE_REMOVED)              printf 'The AFK-owned worker worktree was removed after its worker settled and its result was retained elsewhere.' ;;
    WORKTREE_RETAINED_UNSETTLED)   printf 'The worker that owns this workspace has not settled, so its resources are retained rather than released.' ;;
    WORKTREE_RETAINED_DIRTY)       printf 'The AFK-owned worktree still carries unaccounted tracked or untracked changes, so removing it would destroy work nobody looked at.' ;;
    WORKTREE_NOT_OWNED)            printf 'No AFK-owned worktree is recorded for this Dispatch, so there is none for settlement to remove.' ;;
    BRANCH_DELETED)                printf 'The AFK-owned local branch was deleted after its worktree was removed and its commits were proven reachable from the expected base.' ;;
    BRANCH_RETAINED_UNMERGED)      printf 'The AFK-owned local branch is neither merged nor explicitly disposable, so it is retained.' ;;
    BRANCH_RETAINED_UNIQUE_COMMITS) printf 'The AFK-owned local branch carries commits that are not reachable from its expected base, so it is retained; unique or unpushed work fails closed.' ;;
    BRANCH_RETAINED_PROTECTED)     printf 'This is a protected or default branch and is never a deletion candidate.' ;;
    BRANCH_RETAINED_WORKTREE_PRESENT) printf 'The worktree that checks this branch out has not been removed, so the branch is retained.' ;;
    BRANCH_NOT_OWNED)              printf 'This branch carries no AFK provenance for this Dispatch, so it is report-only inventory and never a deletion target.' ;;
    REMOTE_BRANCH_DELETED)         printf 'The remote topic branch was deleted under an explicitly recorded repository authority.' ;;
    REMOTE_BRANCH_ABSENT)          printf 'No remote topic branch exists for this Dispatch, so there is none to delete.' ;;
    REMOTE_BRANCH_RETAINED_UNAUTHORIZED) printf 'Deleting the remote topic branch is not an authority this host already holds, so the remote branch is retained and reported.' ;;
    CLEANUP_NEEDS_OWNER)           printf 'A cleanup step could not be proven safe, so it was not performed and the resource is retained for its owner.' ;;
    CLEANUP_COMPLETE)              printf 'Every resource this Dispatch owned reached a terminal disposition, so the Dispatch is settled.' ;;
    *) printf '' ;;
  esac
}

afk_monitor_reason_action() { # <reason> — empty for a code this file does not own
  case "$1" in
    DISPATCH_WATCH_NOT_AVAILABLE|DISPATCH_WATCH_IDLE|DISPATCH_WATCH_ACTIVE|DISPATCH_WATCH_REGISTERED|DELIVERY_REPLAY_IGNORED|WORKER_DONE_RETAINED|TERMINAL_RELEASED|WORKTREE_REMOVED|BRANCH_DELETED|REMOTE_BRANCH_DELETED|REMOTE_BRANCH_ABSENT|CLEANUP_COMPLETE) \
                                   printf 'No action required.' ;;
    DISPATCH_DESCRIPTOR_INVALID)   printf 'Correct the dispatch descriptor: a durable watch needs a dispatch id, a task id, and the provenance of the resources the worker owns.' ;;
    DISPATCH_RECORD_UNREADABLE|DISPATCH_RECORD_SCHEMA_UNSUPPORTED) \
                                   printf 'Inspect the named watch record by hand; the monitor never rewrites a record it cannot read and never guesses the Dispatch it describes.' ;;
    DISPATCH_UNKNOWN)              printf 'Register the Dispatch this delivery names, or remove the delivery once its Dispatch is confirmed gone; no Dispatch is ever invented from a delivery.' ;;
    DELIVERY_UNREADABLE)           printf 'Inspect the retained delivery by hand: it is still on disk and will be reconciled as soon as it is readable.' ;;
    WORKER_ESCALATION_RETAINED)    printf 'Answer the escalation the worker raised; its resources stay retained until the decision is made.' ;;
    RESULT_NOT_RETAINED)           printf 'Make the declared state directory writable, then re-run the reconciliation; the delivery was not acknowledged and nothing was lost.' ;;
    RESULT_UNPARSEABLE)            printf 'Inspect the retained delivery by hand; a completion with no readable status is never turned into an outcome.' ;;
    WORKER_HEARTBEAT_EXPIRED)      printf 'Look at the worker: this is a monitoring fault, so decide the outcome yourself rather than reading it as done or failed.' ;;
    WORKER_TERMINAL_EXITED_WITHOUT_DELIVERY) printf 'Look at the worker and its retained evidence; the lifecycle will not manufacture a completion from a terminal that is merely gone.' ;;
    MONITOR_DEGRADED)              printf 'Resolve the reported monitoring fault; the Dispatch stays watched and recoverable until it is.' ;;
    TERMINAL_RELEASE_UNPROVEN)     printf 'Close the named terminal through Orca by hand and confirm it stays closed across a reconnect.' ;;
    TERMINAL_RETAINED_ACTIVE|TERMINAL_RETAINED_AWAITING_ANSWER|TERMINAL_RETAINED_AMBIGUOUS|TERMINAL_RETAINED_USER_TAKEOVER) \
                                   printf 'No action required for cleanup: this terminal is deliberately out of reach of generic cleanup until it is idle or exited.' ;;
    TERMINAL_NOT_OWNED|WORKTREE_NOT_OWNED|BRANCH_NOT_OWNED) \
                                   printf 'No action required here: a resource without AFK provenance is inventory for a separate owner-approved plan, never a target of worker settlement.' ;;
    WORKTREE_RETAINED_UNSETTLED)   printf 'Settle the worker first; a workspace is released only after its worker has settled and its result is retained elsewhere.' ;;
    WORKTREE_RETAINED_DIRTY)       printf 'Account for the changes in the reported worktree, then re-run cleanup; nothing is deleted while unexplained content is in it.' ;;
    BRANCH_RETAINED_UNMERGED|BRANCH_RETAINED_UNIQUE_COMMITS) \
                                   printf 'Merge or explicitly dispose of the reported branch; a branch with unique or unpushed work is never deleted automatically.' ;;
    BRANCH_RETAINED_PROTECTED)     printf 'No action required: a protected or default branch is not a cleanup candidate.' ;;
    BRANCH_RETAINED_WORKTREE_PRESENT) printf 'Resolve the worktree disposition first; the branch is considered only once the worktree that checks it out is gone.' ;;
    REMOTE_BRANCH_RETAINED_UNAUTHORIZED) printf 'Delete the remote topic branch through the repository authority that owns it; this host does not broaden its own GitHub authority to do it.' ;;
    CLEANUP_NEEDS_OWNER)           printf 'Resolve the reported resource by hand; cleanup fails closed rather than removing something it cannot prove it owns and can spare.' ;;
    *) printf '' ;;
  esac
}

# --- small helpers ----------------------------------------------------------

# A dispatch id names a file inside kit state and arrives from outside, so it is
# validated as an identifier and never used as a path fragment before it is.
afk_dispatch_id_is_safe() { # <id>
  [[ -n "${1:-}" ]] || return 1
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || return 1
  case "$1" in
    *..*) return 1 ;;
  esac
  return 0
}

afk_monitor_records() { # one watch-record path per line, in a stable order
  [[ -n "${AFK_DISPATCH_WATCH_DIR:-}" && -d "$AFK_DISPATCH_WATCH_DIR" ]] || return 0
  find "$AFK_DISPATCH_WATCH_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | LC_ALL=C sort
}

afk_monitor_deliveries() { # one delivery path per line, in a stable order
  [[ -n "${AFK_DISPATCH_INBOX_DIR:-}" && -d "$AFK_DISPATCH_INBOX_DIR" ]] || return 0
  find "$AFK_DISPATCH_INBOX_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | LC_ALL=C sort
}

afk_monitor_record_read() { # <path> -> compact record on stdout; 1 unreadable, 2 unsupported major
  local doc major
  doc="$(jq -c '.' "$1" 2>/dev/null)" || return 1
  [[ -n "$doc" ]] || return 1
  major="$(printf '%s' "$doc" | jq -r 'if (.schema_version | type) == "string"
    then (.schema_version | split(".")[0]) else "" end' 2>/dev/null)" || major=""
  [[ "$major" =~ ^[0-9]+$ ]] || return 2
  (( major <= AFK_SUPPORTED_DISPATCH_SCHEMA_MAJOR )) || return 2
  printf '%s' "$doc"
  return 0
}

afk_monitor_record_write() { # <path> <record json>
  local sorted
  sorted="$(printf '%s' "$2" | jq -S -c '.' 2>/dev/null)" || return 1
  [[ -n "$sorted" ]] || return 1
  afk_state_file_write "$1" "$sorted"
}

afk_monitor_jget() { # <json> <filter>
  printf '%s' "$1" | jq -r "$2" 2>/dev/null
}

afk_monitor_now() {
  local n
  n="$(date -u +%s 2>/dev/null)" || n=""
  case "$n" in
    ''|*[!0-9]*) printf '0' ;;
    *)           printf '%s' "$n" ;;
  esac
}

afk_monitor_fault() { # <record json> <fault code> -> record json with the fault set
  printf '%s' "$1" | jq -c --arg f "$2" '.state = "MONITOR_DEGRADED" | .fault = $f' 2>/dev/null
}

# --- the bounded external observation ---------------------------------------
#
# The settlement pass reaches outside this host exactly five times: the Orca
# listing, the durable close, and the three remote-branch git calls. All five go
# through one of the two wrappers below, under the same declared bound the probe
# runner enforces and under an environment that cannot ask a human anything.
#
# A host with no bounding tool does not get an unbounded call pretending to be a
# bounded one. It reports PROBE_BOUND_UNAVAILABLE and the call is NOT MADE, so
# the resource is retained on NEEDS_OWNER instead of the coordinator being stuck
# inside a pass that never returns. That is stricter than afk_probe_run, whose
# warn-and-run reading belongs to the readiness probes and is documented where
# they are: a readiness probe that outruns its bound costs time, while a
# settlement observation that outruns its bound is the hang this engine exists
# to remove — and one of these calls can delete a branch.

# Reported once per run, sharing the probe runner's already-reported flag so a
# run that has already said this does not say it twice.
afk_monitor_bound_unavailable() {
  if [[ "${AFK_PROBE_UNBOUNDED_REPORTED:-false}" != "true" ]]; then
    AFK_PROBE_UNBOUNDED_REPORTED="true"
    afk_add_finding "live-probe" "KIT_STATE" "UNKNOWN" "PROBE_BOUND_UNAVAILABLE" \
      "warning" "" "CAPABILITY_PROBE" "a bounded probe" "no timeout tool on this host" \
      "true" "true" ""
  fi
}

# The three remote-branch git calls. An unbounded `git ls-remote` behind a
# dropped VPN, a black-holed host or a stalled proxy stops the "one bounded
# pass" from being one; an https remote whose credentials expired is worse,
# because git blocks on an interactive username prompt inside the pass and needs
# no network fault at all to do it.
#
# Sets AFK_MON_GIT_OUT to bounded stdout and AFK_MON_GIT_STATUS to
# BOUND_UNAVAILABLE, TIMEOUT, NONZERO or OK. Returns 0 only for OK.
afk_monitor_git_remote() { # <argv...>
  local secs out rc
  AFK_MON_GIT_OUT=""; AFK_MON_GIT_STATUS=""
  if ! afk_have timeout; then
    AFK_MON_GIT_STATUS="BOUND_UNAVAILABLE"
    afk_monitor_bound_unavailable
    return 1
  fi
  secs="$(afk_probe_timeout_seconds)"
  out="$(GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true SSH_ASKPASS=/bin/true \
         GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes" \
         timeout "$secs" "$@" 2>/dev/null)"
  rc=$?
  # Bounded evidence, never a transcript: a remote can print anything it likes.
  AFK_MON_GIT_OUT="$(printf '%s' "$out" | head -c 4096)"
  if (( rc == 124 )); then
    AFK_MON_GIT_STATUS="TIMEOUT"; return 1
  fi
  if (( rc != 0 )); then
    AFK_MON_GIT_STATUS="NONZERO"; return 1
  fi
  AFK_MON_GIT_STATUS="OK"
  return 0
}

# --- the Orca terminal observation (live only) ------------------------------
#
# One bounded read-only listing per load, reused by every disposition, so a
# settlement pass over five dispatches does not ask Orca five times. A host that
# cannot bound the listing does not make it: nothing is loaded, every handle
# reads UNKNOWN, and every terminal fails closed on NEEDS_OWNER.

afk_monitor_terminals_load() {
  local parsed
  AFK_MON_TERMINALS_JSON="[]"
  AFK_MON_TERMINALS_LOADED="false"
  if ! afk_monitor_orca monitor-list terminal list --json; then
    return 1
  fi
  # ORCA-5: per-terminal .status does not exist in Orca's list; the liveness
  # fields replace it (AD-28 R5).
  parsed="$(printf '%s' "$AFK_ORCA_OUT" | jq -c '
    ((.terminals // .result.terminals // [])
     | map({handle: (.handle // ""), status: ((.status // "UNKNOWN") | ascii_upcase)}))' 2>/dev/null)" || parsed=""
  [[ -n "$parsed" ]] || return 1
  AFK_MON_TERMINALS_JSON="$parsed"
  AFK_MON_TERMINALS_LOADED="true"
  return 0
}

# ABSENT means one thing here: Orca is not listing this handle right now. What
# that PROVES depends on which question is being asked, and both readers say so
# explicitly rather than each assuming its own.
#   - the watch sweep reads it as a monitoring FAULT: a watched worker whose tab
#     is gone with no delivery is an unknown outcome, never a completion.
#   - cleanup reads it as UNPROVEN: a handle Orca has forgotten may still be a
#     resumable provider session, so absence alone is not a release. Cleanup
#     requests the durable close first and re-observes afterwards.
afk_monitor_terminal_status() { # <handle> -> ACTIVE|IDLE|EXITED|AWAITING_ANSWER|AMBIGUOUS|USER_TAKEOVER|ABSENT|UNKNOWN
  if [[ "$AFK_MON_TERMINALS_LOADED" != "true" ]]; then
    printf 'UNKNOWN'
    return 1
  fi
  printf '%s' "$AFK_MON_TERMINALS_JSON" | jq -r --arg h "$1" \
    'map(select(.handle == $h)) | if length > 0 then .[0].status else "ABSENT" end' 2>/dev/null
}

# The supported DURABLE close. Killing the PTY alone is not enough: a terminal
# whose close intent was never recorded comes back as a resumed provider tab the
# next time Orca reconnects and rediscovers its sessions. Bounded like the
# listing, and refused rather than run unbounded on a host that cannot bound it.
# ORCA-5: `--handle` and `--durable` are not Orca flags; the close becomes
# `terminal close --terminal <h> --tab` with its proof (AD-28 R8).
afk_monitor_terminal_release() { # <handle>
  afk_monitor_orca monitor-close terminal close --handle "$1" --durable --json
}

# Every monitor Orca call: the kit's resolver and bounded runner, at the live
# probe bound. A host that cannot bound the call reports it once and refuses.
afk_monitor_orca() { # <purpose> <orca args...>
  local purpose="$1"; shift
  afk_orca_run --bound "$(afk_probe_timeout_seconds)" "$purpose" -- "$@" && return 0
  [[ "$AFK_ORCA_CODE" != PROBE_BOUND_UNAVAILABLE ]] || afk_monitor_bound_unavailable
  return 1
}

# --- registration -----------------------------------------------------------

afk_monitor_descriptor_is_valid() { # <path>
  jq -e '
    (type == "object")
    and (.dispatch_id | type == "string") and (.dispatch_id | length > 0)
    and (.task_id | type == "string") and (.task_id | length > 0)
  ' "$1" >/dev/null 2>&1
}

afk_monitor_register() { # <descriptor path>
  local path="$1" desc did rpath rec now hb

  if [[ -z "$path" || ! -f "$path" ]] || ! afk_monitor_descriptor_is_valid "$path"; then
    afk_monitor_needs_human
    afk_add_finding "dispatch-watch" "KIT_STATE" "UNKNOWN" "DISPATCH_DESCRIPTOR_INVALID" \
      "owner_action" "" "FILE_STRUCTURE" "a complete dispatch descriptor" "unusable" \
      "false" "false" ""
    return 1
  fi
  desc="$(jq -c '.' "$path" 2>/dev/null)" || desc=""
  [[ -n "$desc" ]] || return 1
  did="$(afk_monitor_jget "$desc" '.dispatch_id')"
  if ! afk_dispatch_id_is_safe "$did"; then
    afk_monitor_needs_human
    afk_add_finding "dispatch-watch" "KIT_STATE" "UNKNOWN" "DISPATCH_DESCRIPTOR_INVALID" \
      "owner_action" "" "FILE_STRUCTURE" "an identifier-shaped dispatch id" "rejected" \
      "false" "false" ""
    return 1
  fi

  rpath="$AFK_DISPATCH_WATCH_DIR/$did.json"
  if [[ -f "$rpath" ]]; then
    # Registration is idempotent by design: a coordinator that restarts and
    # re-registers its own Dispatch must not reset the watch it already has.
    afk_add_finding "dispatch-watch" "KIT_STATE" "CURRENT" "DISPATCH_WATCH_REGISTERED" \
      "info" "" "FILE_STRUCTURE" "one watch record per Dispatch" "already registered" \
      "true" "false" "$did"
    return 0
  fi

  now="$(afk_monitor_now)"
  hb="$(afk_monitor_jget "$desc" '.heartbeat_seconds // empty')"
  case "$hb" in
    ''|*[!0-9]*) hb="$AFK_MONITOR_HEARTBEAT_SECONDS" ;;
  esac
  case "$hb" in
    ''|*[!0-9]*) hb=1800 ;;
  esac

  # The resolved window is PERSISTED, not just consumed: the deadline is
  # refreshed on every heartbeat, and a refresh that read the process default
  # instead would expire a Dispatch registered with a longer window and stop
  # watching a shorter one closely.
  rec="$(printf '%s' "$desc" | jq -c \
    --argjson now "$now" --argjson hb "$hb" \
    --argjson poll "$AFK_MONITOR_POLL_SECONDS" \
    --argjson ceiling "$AFK_MONITOR_BACKOFF_CEILING_SECONDS" '
    {schema_version: "1.0",
     dispatch_id: .dispatch_id,
     task_id: .task_id,
     state: "WATCHING",
     acknowledged: false,
     fault: null,
     created_epoch: $now,
     last_heartbeat_epoch: $now,
     heartbeat_seconds: $hb,
     heartbeat_deadline_epoch: (if $hb > 0 then ($now + $hb) else 0 end),
     poll: {interval_seconds: $poll, backoff_ceiling_seconds: $ceiling},
     provenance: {
       terminal: {handle: (.terminal.handle // ""),
                  owned: ((.terminal.owned // false) == true)},
       worktree: {path: (.worktree.path // ""),
                  owned: ((.worktree.owned // false) == true)},
       branch: {name: (.branch.name // ""),
                repo: (.branch.repo // ""),
                base: (.branch.base // ""),
                remote: (.branch.remote // ""),
                owned: ((.branch.owned // false) == true),
                disposable: ((.branch.disposable // false) == true),
                pr_merged: ((.branch.pr_merged // false) == true),
                remote_delete_authorized: ((.branch.remote_delete_authorized // false) == true)}},
     processed_deliveries: [],
     settlement: {scheduled_count: 0, due: false},
     traceability: {records: 0},
     result: {retained: false, path: null, identity: null, status: null,
              kind: null, needs_human: false},
     cleanup: {terminal: "PENDING", worktree: "PENDING",
               local_branch: "PENDING", remote_branch: "PENDING",
               complete: false}}' 2>/dev/null)" || rec=""
  if [[ -z "$rec" ]] || ! afk_monitor_record_write "$rpath" "$rec"; then
    afk_monitor_needs_human
    afk_add_finding "dispatch-watch" "KIT_STATE" "UNKNOWN" "RESULT_NOT_RETAINED" \
      "owner_action" "" "FILE_STRUCTURE" "a writable dispatch watch directory" "unwritable" \
      "false" "false" "$did"
    return 1
  fi
  afk_add_finding "dispatch-watch" "KIT_STATE" "CURRENT" "DISPATCH_WATCH_REGISTERED" \
    "info" "" "FILE_STRUCTURE" "a durable watch before control is yielded" "registered" \
    "true" "false" "$did"
  return 0
}

# --- reconciliation ---------------------------------------------------------
#
# One bounded pass: consume every pending delivery, then judge every record
# still watching. Retention first, reconciliation second, acknowledgement last —
# an acknowledgement that outruns retention is how a completion disappears.

afk_monitor_reconcile_delivery() { # <delivery path>
  local dpath="$1" doc did dispatch_id kind status rpath rec rc
  local resfile identity retained trace context_budget

  if ! doc="$(jq -c '.' "$dpath" 2>/dev/null)" || [[ -z "$doc" ]]; then
    afk_monitor_needs_human
    afk_add_finding "dispatch-delivery" "KIT_STATE" "UNKNOWN" "DELIVERY_UNREADABLE" \
      "owner_action" "" "FILE_STRUCTURE" "a parseable completion delivery" "unparseable" \
      "false" "false" ""
    return 1
  fi
  dispatch_id="$(afk_monitor_jget "$doc" '.dispatch_id // ""')"
  did="$(afk_monitor_jget "$doc" '.delivery_id // ""')"
  kind="$(afk_monitor_jget "$doc" '.kind // ""')"
  if ! afk_dispatch_id_is_safe "$dispatch_id" || ! afk_dispatch_id_is_safe "$did"; then
    afk_monitor_needs_human
    afk_add_finding "dispatch-delivery" "KIT_STATE" "UNKNOWN" "DELIVERY_UNREADABLE" \
      "owner_action" "" "FILE_STRUCTURE" "a delivery naming its Dispatch and itself" \
      "unusable" "false" "false" ""
    return 1
  fi

  rpath="$AFK_DISPATCH_WATCH_DIR/$dispatch_id.json"
  if [[ ! -f "$rpath" ]]; then
    # A delivery never creates a Dispatch: that would be manufacturing a worker
    # nobody launched. It stays on disk and it stays loud.
    afk_monitor_needs_human
    afk_add_finding "dispatch-delivery" "KIT_STATE" "UNKNOWN" "DISPATCH_UNKNOWN" \
      "owner_action" "" "FILE_STRUCTURE" "a registered Dispatch" "no watch record" \
      "false" "false" "$dispatch_id"
    return 1
  fi
  rec="$(afk_monitor_record_read "$rpath")"
  rc=$?
  if (( rc != 0 )); then
    afk_monitor_needs_human
    if (( rc == 2 )); then
      afk_add_finding "dispatch-watch" "KIT_STATE" "INCOMPATIBLE" "DISPATCH_RECORD_SCHEMA_UNSUPPORTED" \
        "owner_action" "" "MANIFEST_SCHEMA" "$AFK_SUPPORTED_DISPATCH_SCHEMA_MAJOR.x" \
        "newer" "false" "false" "$dispatch_id"
    else
      afk_add_finding "dispatch-watch" "KIT_STATE" "UNKNOWN" "DISPATCH_RECORD_UNREADABLE" \
        "owner_action" "" "FILE_STRUCTURE" "a parseable watch record" "unparseable" \
        "false" "false" "$dispatch_id"
    fi
    return 1
  fi

  # Replay. Delivery is at-least-once, so this is the ordinary case after a
  # disconnect, not an error: the duplicate is dropped and NOTHING is repeated.
  if printf '%s' "$rec" | jq -e --arg d "$did" \
       '((.processed_deliveries // []) | index($d)) != null' >/dev/null 2>&1; then
    rm -f -- "$dpath" 2>/dev/null
    AFK_MON_REPLAYS=$((AFK_MON_REPLAYS + 1))
    afk_add_finding "dispatch-delivery" "KIT_STATE" "CURRENT" "DELIVERY_REPLAY_IGNORED" \
      "info" "" "FILE_STRUCTURE" "exactly-once completion effects" "duplicate dropped" \
      "true" "false" "$dispatch_id"
    return 0
  fi

  case "$kind" in
    heartbeat)
      # The window this Dispatch was REGISTERED with decides the next deadline.
      # A record written before the window was persisted carries none, and only
      # that record falls back to the process default.
      rec="$(printf '%s' "$rec" | jq -c --arg d "$did" \
        --argjson now "$(afk_monitor_now)" \
        --argjson default_hb "$AFK_MONITOR_HEARTBEAT_SECONDS" '
        (if (.heartbeat_seconds | type) == "number"
         then .heartbeat_seconds else $default_hb end) as $hb
        | .last_heartbeat_epoch = $now
        | .heartbeat_deadline_epoch = (if $hb > 0 then ($now + $hb) else 0 end)
        | .processed_deliveries = ((.processed_deliveries // []) + [$d])' 2>/dev/null)" || rec=""
      if [[ -n "$rec" ]] && afk_monitor_record_write "$rpath" "$rec"; then
        rm -f -- "$dpath" 2>/dev/null
        return 0
      fi
      afk_monitor_needs_human
      afk_add_finding "dispatch-watch" "KIT_STATE" "UNKNOWN" "RESULT_NOT_RETAINED" \
        "owner_action" "" "FILE_STRUCTURE" "a writable watch record" "unwritable" \
        "false" "false" "$dispatch_id"
      return 1 ;;
    worker_done|escalation) : ;;
    *)
      afk_monitor_needs_human
      afk_add_finding "dispatch-delivery" "KIT_STATE" "UNKNOWN" "DELIVERY_UNREADABLE" \
        "owner_action" "" "FILE_STRUCTURE" "a declared delivery kind" "unrecognized" \
        "false" "false" "$dispatch_id"
      return 1 ;;
  esac

  status="$(afk_monitor_jget "$doc" '.result.status // ""')"
  if [[ -z "$status" ]]; then
    # Loud and RECOVERABLE: the delivery is left where it is, so a corrected one
    # reconciles on the next pass rather than the completion vanishing.
    rec="$(afk_monitor_fault "$rec" "RESULT_UNPARSEABLE")"
    if [[ -n "$rec" ]]; then afk_monitor_record_write "$rpath" "$rec" || true; fi
    afk_monitor_needs_human
    afk_add_finding "dispatch-watch" "KIT_STATE" "UNKNOWN" "RESULT_UNPARSEABLE" \
      "owner_action" "" "FILE_STRUCTURE" "a readable result status" "absent" \
      "false" "false" "$dispatch_id"
    return 1
  fi

  # --- retention, before anything is acknowledged --------------------------
  resfile="$AFK_DISPATCH_RESULT_DIR/$dispatch_id.result.json"
  retained="$(printf '%s' "$doc" | jq -S -c \
    '{dispatch_id, delivery_id, kind, result}' 2>/dev/null)" || retained=""
  identity=""
  if [[ -n "$retained" ]] && afk_state_file_write "$resfile" "$retained" \
     && jq -e '.' "$resfile" >/dev/null 2>&1; then
    identity="$(afk_sha256_file "$resfile")" || identity=""
  fi
  if [[ -z "$identity" ]]; then
    rec="$(afk_monitor_fault "$rec" "RESULT_NOT_RETAINED")"
    if [[ -n "$rec" ]]; then afk_monitor_record_write "$rpath" "$rec" || true; fi
    afk_monitor_needs_human
    afk_add_finding "dispatch-watch" "KIT_STATE" "UNKNOWN" "RESULT_NOT_RETAINED" \
      "owner_action" "" "HASH_COMPARISON" "a retained, re-readable result" "not retained" \
      "false" "false" "$dispatch_id"
    return 1
  fi

  # The traceability record is written by CONTENT rather than appended, so even
  # a replay that somehow reached this far cannot produce a second one.
  trace="$(jq -S -c -n --arg d "$dispatch_id" --arg dv "$did" --arg s "$status" --arg i "$identity" \
    '{dispatch_id: $d, delivery_id: $dv, status: $s, result_identity: $i}' 2>/dev/null)" || trace=""
  if [[ -n "$trace" ]]; then
    afk_state_file_write "$AFK_DISPATCH_RESULT_DIR/$dispatch_id.traceability.json" "$trace" || true
  fi

  # --- reconciliation, then the acknowledgement ----------------------------
  # The worker's own context-budget state, carried onto the watch record so a
  # reader sees it without opening the retained result (Story 1.5 lane B,
  # FR-105). BOUNDED here rather than trusted: a delivery is worker-shaped
  # input, and a state outside the published four is not a fifth state, it is
  # an unobserved one. Introduced by this capability — a record written before
  # it existed simply carries NOT_EVALUATED.
  context_budget="$(printf '%s' "$doc" | jq -r '
    (.result.budget.state // "") as $s
    | if ["OK","CHECKPOINT_DUE","CONTINUATION_REQUIRED","NOT_EVALUATED"] | index($s)
      then $s else "NOT_EVALUATED" end' 2>/dev/null)" || context_budget="NOT_EVALUATED"

  # Pressure publication is part of reconciliation, not a best-effort side
  # effect after acknowledgement. Prove the deterministic message is durable
  # before the watch record can say acknowledged or the inbox delivery can be
  # removed. A conflicting/unwritable message leaves the delivery retryable.
  if [[ "$context_budget" == CHECKPOINT_DUE || "$context_budget" == CONTINUATION_REQUIRED ]]; then
    local message_path message message_ok=false
    message_path="$AFK_DISPATCH_MESSAGE_DIR/$dispatch_id.$did.json"
    message="$(jq -nc --arg id "$dispatch_id" --arg delivery "$did" --arg state "$context_budget" --arg status "$status" '{schema:"afk-monitor-message/1",idempotency_key:($id+":"+$delivery),dispatch_id:$id,delivery_id:$delivery,kind:"WORKER_CONTEXT_PRESSURE",budget_state:$state,result_status:$status,continuation_dispatch:"canonical"}')"
    if mkdir -p -- "$AFK_DISPATCH_MESSAGE_DIR" && chmod 700 "$AFK_DISPATCH_MESSAGE_DIR"; then
      if [[ -f "$message_path" ]]; then
        jq -e --argjson expected "$message" '.==$expected' "$message_path" >/dev/null 2>&1 && message_ok=true
      elif afk_state_file_write "$message_path" "$message" \
        && jq -e --argjson expected "$message" '.==$expected' "$message_path" >/dev/null 2>&1; then
        message_ok=true
      fi
    fi
    if [[ "$message_ok" != true ]]; then
      rec="$(afk_monitor_fault "$rec" "RESULT_NOT_RETAINED")"
      if [[ -n "$rec" ]]; then afk_monitor_record_write "$rpath" "$rec" || true; fi
      afk_monitor_needs_human
      afk_add_finding "dispatch-watch" "KIT_STATE" "UNKNOWN" "RESULT_NOT_RETAINED" \
        "owner_action" "" "FILE_STRUCTURE" "a durable exact pressure message" "not retained" \
        "false" "false" "$dispatch_id"
      return 1
    fi
  fi

  rec="$(printf '%s' "$rec" | jq -c \
    --arg d "$did" --arg st "$status" --arg id "$identity" --arg rp "$resfile" \
    --arg kind "$kind" --arg cb "$context_budget" '
    .state = "COMPLETED"
    | .acknowledged = true
    | .fault = null
    | .result = {retained: true, path: $rp, identity: $id, status: $st, kind: $kind,
                 context_budget: $cb,
                 needs_human: (($kind == "escalation") or ($st == "needs_human"))}
    | .settlement.scheduled_count =
        (if ((.settlement.scheduled_count // 0) > 0) then (.settlement.scheduled_count) else 1 end)
    | .settlement.due = true
    | .traceability.records =
        (if ((.traceability.records // 0) > 0) then (.traceability.records) else 1 end)
    | .processed_deliveries = ((.processed_deliveries // []) + [$d])' 2>/dev/null)" || rec=""
  if [[ -z "$rec" ]] || ! afk_monitor_record_write "$rpath" "$rec"; then
    afk_monitor_needs_human
    afk_add_finding "dispatch-watch" "KIT_STATE" "UNKNOWN" "RESULT_NOT_RETAINED" \
      "owner_action" "" "FILE_STRUCTURE" "a writable watch record" "unwritable" \
      "false" "false" "$dispatch_id"
    return 1
  fi
  rm -f -- "$dpath" 2>/dev/null
  AFK_MON_CONSUMED=$((AFK_MON_CONSUMED + 1))

  if [[ "$kind" == "escalation" || "$status" == "needs_human" ]]; then
    afk_monitor_needs_human
    afk_add_finding "dispatch-watch" "KIT_STATE" "EXTERNAL_STATE" "WORKER_ESCALATION_RETAINED" \
      "owner_action" "" "FILE_STRUCTURE" "a decided worker" "escalated" \
      "true" "false" "$dispatch_id"
  else
    afk_add_finding "dispatch-watch" "KIT_STATE" "CURRENT" "WORKER_DONE_RETAINED" \
      "info" "" "HASH_COMPARISON" "retained, reconciled, then acknowledged" "$identity" \
      "true" "false" "$dispatch_id"
  fi
  return 0
}

afk_monitor_watch_sweep() {
  local rpath rec rc state deadline now handle tstatus did

  now="$(afk_monitor_now)"
  while IFS= read -r rpath; do
    [[ -n "$rpath" ]] || continue
    rec="$(afk_monitor_record_read "$rpath")"
    rc=$?
    (( rc == 0 )) || continue
    state="$(afk_monitor_jget "$rec" '.state // ""')"
    [[ "$state" == "WATCHING" ]] || continue
    did="$(afk_monitor_jget "$rec" '.dispatch_id // ""')"

    deadline="$(afk_monitor_jget "$rec" '.heartbeat_deadline_epoch // 0')"
    case "$deadline" in ''|*[!0-9]*) deadline=0 ;; esac
    if (( deadline > 0 && now > deadline )); then
      # A heartbeat that expired is a MONITORING fault. It says nothing about
      # whether the worker succeeded, so it produces neither result.
      rec="$(afk_monitor_fault "$rec" "WORKER_HEARTBEAT_EXPIRED")"
      if [[ -n "$rec" ]]; then afk_monitor_record_write "$rpath" "$rec" || true; fi
      afk_monitor_needs_human
      afk_add_finding "dispatch-watch" "KIT_STATE" "INTERRUPTED" "WORKER_HEARTBEAT_EXPIRED" \
        "owner_action" "" "FILE_STRUCTURE" "a heartbeat inside the declared window" \
        "expired" "false" "false" "$did"
      continue
    fi

    [[ "$AFK_MONITOR_LIVE" == "true" ]] || continue
    handle="$(afk_monitor_jget "$rec" '.provenance.terminal.handle // ""')"
    [[ -n "$handle" ]] || continue
    tstatus="$(afk_monitor_terminal_status "$handle")"
    case "$tstatus" in
      ABSENT|EXITED)
        # The inbox has already been drained, so a Dispatch that is still
        # WATCHING received no delivery. A gone terminal is not a completion.
        # This is the WATCH reading of ABSENT; the cleanup reading of the same
        # observation is "unproven until a durable close was requested and the
        # absence re-observed", and the two never trade places.
        rec="$(afk_monitor_fault "$rec" "WORKER_TERMINAL_EXITED_WITHOUT_DELIVERY")"
        if [[ -n "$rec" ]]; then afk_monitor_record_write "$rpath" "$rec" || true; fi
        afk_monitor_needs_human
        afk_add_finding "dispatch-watch" "KIT_STATE" "INTERRUPTED" \
          "WORKER_TERMINAL_EXITED_WITHOUT_DELIVERY" "owner_action" "" "CAPABILITY_PROBE" \
          "a supervised completion delivery" "terminal $tstatus" "false" "false" "$did" ;;
    esac
  done < <(afk_monitor_records)
  return 0
}

afk_monitor_reconcile() {
  local dpath
  if [[ "$AFK_MONITOR_LIVE" == "true" ]]; then
    afk_monitor_terminals_load || true
  fi
  while IFS= read -r dpath; do
    [[ -n "$dpath" ]] || continue
    afk_monitor_reconcile_delivery "$dpath" || true
  done < <(afk_monitor_deliveries)
  afk_monitor_watch_sweep
  return 0
}

# --- cleanup ----------------------------------------------------------------

afk_monitor_branch_is_protected() { # <branch>
  [[ -n "${1:-}" ]] || return 0
  printf '%s\n' "$AFK_MONITOR_PROTECTED_BRANCHES" | grep -q -x -F -- "$1"
}

afk_monitor_cleanup_terminal() { # <record json> -> "<disposition> <reason>"
  local rec="$1" existing handle owned tstatus
  existing="$(afk_monitor_jget "$rec" '.cleanup.terminal // "PENDING"')"
  case "$existing" in
    REMOVED)        printf 'REMOVED TERMINAL_RELEASED'; return 0 ;;
    NOT_APPLICABLE) printf 'NOT_APPLICABLE TERMINAL_NOT_OWNED'; return 0 ;;
  esac
  handle="$(afk_monitor_jget "$rec" '.provenance.terminal.handle // ""')"
  owned="$(afk_monitor_jget "$rec" '.provenance.terminal.owned // false')"
  if [[ -z "$handle" ]]; then
    printf 'NOT_APPLICABLE TERMINAL_NOT_OWNED'; return 0
  fi
  if [[ "$owned" != "true" ]]; then
    printf 'RETAINED TERMINAL_NOT_OWNED'; return 0
  fi
  tstatus="$(afk_monitor_terminal_status "$handle")"
  case "$tstatus" in
    ACTIVE)          printf 'RETAINED TERMINAL_RETAINED_ACTIVE'; return 0 ;;
    AWAITING_ANSWER) printf 'RETAINED TERMINAL_RETAINED_AWAITING_ANSWER'; return 0 ;;
    AMBIGUOUS)       printf 'RETAINED TERMINAL_RETAINED_AMBIGUOUS'; return 0 ;;
    USER_TAKEOVER)   printf 'RETAINED TERMINAL_RETAINED_USER_TAKEOVER'; return 0 ;;
    # ABSENT is not proof of release. A handle Orca is not listing right now is
    # a handle whose session it can still rediscover on the next reconnect —
    # which is the entire premise of the durable close. So it falls through to
    # the same request/re-observe pair as IDLE and EXITED, and skipping the
    # request is how a settled worker comes back as a tab.
    ABSENT|IDLE|EXITED) : ;;
    *)               printf 'NEEDS_OWNER TERMINAL_RELEASE_UNPROVEN'; return 0 ;;
  esac
  # The close's OWN outcome is evidence, and for ABSENT it is the only evidence
  # there is: a handle that was not listed before the request is not listed
  # after it whether the close succeeded, failed, or was refused outright, so a
  # re-observation alone would decide that arm on a tautology. A close that
  # failed and a terminal that is nonetheless gone is still an unproven closure,
  # so all three states consume the request's status.
  if ! afk_monitor_terminal_release "$handle"; then
    printf 'NEEDS_OWNER TERMINAL_RELEASE_UNPROVEN'; return 0
  fi
  # Re-observe rather than trusting the request: durable closure is a claim, and
  # a claim nobody checked is how a completed worker comes back as a tab.
  afk_monitor_terminals_load || true
  tstatus="$(afk_monitor_terminal_status "$handle")"
  if [[ "$tstatus" == "ABSENT" ]]; then
    printf 'REMOVED TERMINAL_RELEASED'
  else
    printf 'NEEDS_OWNER TERMINAL_RELEASE_UNPROVEN'
  fi
  return 0
}

afk_monitor_cleanup_worktree() { # <record json> <terminal disposition> -> "<disposition> <reason>"
  local rec="$1" tdisp="$2" existing wt owned repo respath dirty resolved_wt resolved_res
  existing="$(afk_monitor_jget "$rec" '.cleanup.worktree // "PENDING"')"
  case "$existing" in
    REMOVED)        printf 'REMOVED WORKTREE_REMOVED'; return 0 ;;
    NOT_APPLICABLE) printf 'NOT_APPLICABLE WORKTREE_NOT_OWNED'; return 0 ;;
  esac
  wt="$(afk_monitor_jget "$rec" '.provenance.worktree.path // ""')"
  owned="$(afk_monitor_jget "$rec" '.provenance.worktree.owned // false')"
  repo="$(afk_monitor_jget "$rec" '.provenance.branch.repo // ""')"
  if [[ -z "$wt" ]]; then
    printf 'NOT_APPLICABLE WORKTREE_NOT_OWNED'; return 0
  fi
  if [[ "$owned" != "true" ]]; then
    printf 'RETAINED WORKTREE_NOT_OWNED'; return 0
  fi
  if [[ ! -d "$wt" ]]; then
    printf 'REMOVED WORKTREE_REMOVED'; return 0
  fi
  if [[ "$tdisp" != "REMOVED" && "$tdisp" != "NOT_APPLICABLE" ]]; then
    # A terminal that is still there may still own this directory.
    printf 'RETAINED WORKTREE_RETAINED_UNSETTLED'; return 0
  fi
  # The retained result must live OUTSIDE the worktree, or removing the
  # worktree would destroy the evidence the settlement rests on.
  respath="$(afk_monitor_jget "$rec" '.result.path // ""')"
  if [[ -z "$respath" || ! -f "$respath" ]]; then
    printf 'NEEDS_OWNER CLEANUP_NEEDS_OWNER'; return 0
  fi
  resolved_wt="$(afk_realpath "$wt")" || resolved_wt=""
  resolved_res="$(afk_realpath "$respath")" || resolved_res=""
  if [[ -z "$resolved_wt" || -z "$resolved_res" ]] \
     || afk_is_within "$resolved_res" "$resolved_wt"; then
    printf 'NEEDS_OWNER CLEANUP_NEEDS_OWNER'; return 0
  fi
  dirty="$(git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null)" || dirty="unreadable"
  if [[ -n "$dirty" ]]; then
    printf 'RETAINED WORKTREE_RETAINED_DIRTY'; return 0
  fi
  if [[ -z "$repo" || ! -d "$repo" ]]; then
    printf 'NEEDS_OWNER CLEANUP_NEEDS_OWNER'; return 0
  fi
  # Removal goes through Git's own worktree bookkeeping. There is deliberately
  # no recursive delete here: a path this code cannot remove as a worktree is a
  # path it has not proven it created, and it is retained instead.
  git -C "$repo" worktree remove "$wt" >/dev/null 2>&1 || true
  if [[ -d "$wt" ]]; then
    printf 'NEEDS_OWNER CLEANUP_NEEDS_OWNER'
  else
    git -C "$repo" worktree prune >/dev/null 2>&1 || true
    printf 'REMOVED WORKTREE_REMOVED'
  fi
  return 0
}

afk_monitor_cleanup_branch() { # <record json> <worktree disposition> -> "<disposition> <reason>"
  local rec="$1" wdisp="$2" existing br repo base owned disposable merged unique
  existing="$(afk_monitor_jget "$rec" '.cleanup.local_branch // "PENDING"')"
  case "$existing" in
    REMOVED)        printf 'REMOVED BRANCH_DELETED'; return 0 ;;
    NOT_APPLICABLE) printf 'NOT_APPLICABLE BRANCH_NOT_OWNED'; return 0 ;;
  esac
  br="$(afk_monitor_jget "$rec" '.provenance.branch.name // ""')"
  repo="$(afk_monitor_jget "$rec" '.provenance.branch.repo // ""')"
  base="$(afk_monitor_jget "$rec" '.provenance.branch.base // ""')"
  owned="$(afk_monitor_jget "$rec" '.provenance.branch.owned // false')"
  disposable="$(afk_monitor_jget "$rec" '.provenance.branch.disposable // false')"
  merged="$(afk_monitor_jget "$rec" '.provenance.branch.pr_merged // false')"
  if [[ -z "$br" || -z "$repo" || ! -d "$repo" ]]; then
    printf 'NOT_APPLICABLE BRANCH_NOT_OWNED'; return 0
  fi
  if [[ "$owned" != "true" ]]; then
    printf 'RETAINED BRANCH_NOT_OWNED'; return 0
  fi
  if afk_monitor_branch_is_protected "$br"; then
    printf 'RETAINED BRANCH_RETAINED_PROTECTED'; return 0
  fi
  if ! git -C "$repo" show-ref --verify --quiet "refs/heads/$br" 2>/dev/null; then
    printf 'REMOVED BRANCH_DELETED'; return 0
  fi
  if [[ "$wdisp" != "REMOVED" && "$wdisp" != "NOT_APPLICABLE" ]]; then
    printf 'RETAINED BRANCH_RETAINED_WORKTREE_PRESENT'; return 0
  fi
  if [[ -z "$base" ]]; then
    printf 'NEEDS_OWNER CLEANUP_NEEDS_OWNER'; return 0
  fi
  unique="$(git -C "$repo" rev-list --count "$base..$br" 2>/dev/null)" || unique=""
  case "$unique" in
    ''|*[!0-9]*) printf 'NEEDS_OWNER CLEANUP_NEEDS_OWNER'; return 0 ;;
  esac
  if (( unique > 0 )); then
    # Unique or unpushed work fails closed, whatever a record claims about a
    # merged pull request.
    printf 'RETAINED BRANCH_RETAINED_UNIQUE_COMMITS'; return 0
  fi
  if [[ "$merged" != "true" && "$disposable" != "true" ]]; then
    printf 'RETAINED BRANCH_RETAINED_UNMERGED'; return 0
  fi
  git -C "$repo" branch -d "$br" >/dev/null 2>&1 || true
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$br" 2>/dev/null; then
    printf 'NEEDS_OWNER CLEANUP_NEEDS_OWNER'
  else
    printf 'REMOVED BRANCH_DELETED'
  fi
  return 0
}

afk_monitor_cleanup_remote_branch() { # <record json> <branch disposition> -> "<disposition> <reason>"
  local rec="$1" bdisp="$2" existing br repo remote authorized merged left
  existing="$(afk_monitor_jget "$rec" '.cleanup.remote_branch // "PENDING"')"
  case "$existing" in
    REMOVED)        printf 'REMOVED REMOTE_BRANCH_DELETED'; return 0 ;;
    NOT_APPLICABLE) printf 'NOT_APPLICABLE REMOTE_BRANCH_ABSENT'; return 0 ;;
  esac
  br="$(afk_monitor_jget "$rec" '.provenance.branch.name // ""')"
  repo="$(afk_monitor_jget "$rec" '.provenance.branch.repo // ""')"
  remote="$(afk_monitor_jget "$rec" '.provenance.branch.remote // ""')"
  authorized="$(afk_monitor_jget "$rec" '.provenance.branch.remote_delete_authorized // false')"
  merged="$(afk_monitor_jget "$rec" '.provenance.branch.pr_merged // false')"
  if [[ -z "$br" || -z "$remote" || -z "$repo" || ! -d "$repo" ]]; then
    printf 'NOT_APPLICABLE REMOTE_BRANCH_ABSENT'; return 0
  fi
  # A remote observation that did not complete inside its bound has proven
  # nothing: not that the branch is there, not that it is gone. It is never a
  # deletion and never a "deleted", and the remote branch is retained for its
  # owner with the reporting that goes with it.
  if ! afk_monitor_git_remote git -C "$repo" ls-remote --heads "$remote" "$br"; then
    printf 'NEEDS_OWNER CLEANUP_NEEDS_OWNER'; return 0
  fi
  left="$AFK_MON_GIT_OUT"
  if [[ -z "$left" ]]; then
    printf 'NOT_APPLICABLE REMOTE_BRANCH_ABSENT'; return 0
  fi
  # Authority is never widened here: without a recorded operation authority the
  # remote branch is reported and left exactly where it is.
  if [[ "$authorized" != "true" || "$merged" != "true" ]]; then
    printf 'RETAINED REMOTE_BRANCH_RETAINED_UNAUTHORIZED'; return 0
  fi
  if [[ "$bdisp" != "REMOVED" && "$bdisp" != "NOT_APPLICABLE" ]]; then
    printf 'RETAINED REMOTE_BRANCH_RETAINED_UNAUTHORIZED'; return 0
  fi
  afk_monitor_git_remote git -C "$repo" push "$remote" --delete "$br" || true
  if ! afk_monitor_git_remote git -C "$repo" ls-remote --heads "$remote" "$br"; then
    printf 'NEEDS_OWNER CLEANUP_NEEDS_OWNER'; return 0
  fi
  left="$AFK_MON_GIT_OUT"
  if [[ -z "$left" ]]; then
    printf 'REMOVED REMOTE_BRANCH_DELETED'
  else
    printf 'NEEDS_OWNER CLEANUP_NEEDS_OWNER'
  fi
  return 0
}

afk_monitor_cleanup_record() { # <record path>
  local rpath="$1" rec rc state did needs_human
  local tdisp treason wdisp wreason bdisp breason rdisp rreason
  local pair complete="true" owner="false" sev

  rec="$(afk_monitor_record_read "$rpath")"
  rc=$?
  if (( rc != 0 )); then
    afk_monitor_needs_human
    afk_add_finding "dispatch-watch" "KIT_STATE" "UNKNOWN" "DISPATCH_RECORD_UNREADABLE" \
      "owner_action" "" "FILE_STRUCTURE" "a parseable watch record" "unparseable" \
      "false" "false" ""
    return 1
  fi
  state="$(afk_monitor_jget "$rec" '.state // ""')"
  did="$(afk_monitor_jget "$rec" '.dispatch_id // ""')"
  needs_human="$(afk_monitor_jget "$rec" '.result.needs_human // false')"

  if [[ "$state" == "SETTLED" ]]; then
    # Idempotent by construction: a settled Dispatch owns nothing, so a repeated
    # cleanup has nothing to remove and nothing to recreate.
    return 0
  fi
  if [[ "$state" != "COMPLETED" ]]; then
    afk_add_finding "dispatch-cleanup" "KIT_STATE" "EXTERNAL_STATE" "WORKTREE_RETAINED_UNSETTLED" \
      "warning" "" "FILE_STRUCTURE" "a settled worker" "$state" "true" "false" "$did"
    return 0
  fi
  if [[ "$needs_human" == "true" ]]; then
    afk_monitor_needs_human
    afk_add_finding "dispatch-cleanup" "KIT_STATE" "EXTERNAL_STATE" "CLEANUP_NEEDS_OWNER" \
      "owner_action" "" "OWNERSHIP_RULE" "a decided worker" "awaiting a human" \
      "true" "false" "$did"
    return 0
  fi

  pair="$(afk_monitor_cleanup_terminal "$rec")"
  tdisp="${pair%% *}"; treason="${pair##* }"
  pair="$(afk_monitor_cleanup_worktree "$rec" "$tdisp")"
  wdisp="${pair%% *}"; wreason="${pair##* }"
  pair="$(afk_monitor_cleanup_branch "$rec" "$wdisp")"
  bdisp="${pair%% *}"; breason="${pair##* }"
  pair="$(afk_monitor_cleanup_remote_branch "$rec" "$bdisp")"
  rdisp="${pair%% *}"; rreason="${pair##* }"

  for pair in "$tdisp $treason" "$wdisp $wreason" "$bdisp $breason" "$rdisp $rreason"; do
    case "${pair%% *}" in
      REMOVED|NOT_APPLICABLE) sev="info" ;;
      NEEDS_OWNER)            sev="owner_action"; complete="false"; owner="true" ;;
      *)                      sev="warning"; complete="false" ;;
    esac
    afk_add_finding "dispatch-cleanup" "KIT_STATE" "EXTERNAL_STATE" "${pair##* }" \
      "$sev" "" "OWNERSHIP_RULE" "a released resource" "${pair%% *}" "true" "false" "$did"
  done
  if [[ "$owner" == "true" ]]; then
    afk_monitor_needs_human
  fi

  rec="$(printf '%s' "$rec" | jq -c \
    --arg t "$tdisp" --arg w "$wdisp" --arg b "$bdisp" --arg r "$rdisp" \
    --argjson complete "$complete" '
    .cleanup = {terminal: $t, worktree: $w, local_branch: $b, remote_branch: $r,
                complete: $complete}
    | .state = (if $complete then "SETTLED" else .state end)
    | .settlement.due = ($complete | not)' 2>/dev/null)" || rec=""
  if [[ -z "$rec" ]] || ! afk_monitor_record_write "$rpath" "$rec"; then
    afk_monitor_needs_human
    afk_add_finding "dispatch-watch" "KIT_STATE" "UNKNOWN" "RESULT_NOT_RETAINED" \
      "owner_action" "" "FILE_STRUCTURE" "a writable watch record" "unwritable" \
      "false" "false" "$did"
    return 1
  fi
  if [[ "$complete" == "true" ]]; then
    afk_add_finding "dispatch-cleanup" "KIT_STATE" "CURRENT" "CLEANUP_COMPLETE" \
      "info" "" "OWNERSHIP_RULE" "every owned resource released" "settled" \
      "true" "false" "$did"
  fi
  return 0
}

afk_monitor_cleanup() {
  local rpath
  afk_monitor_terminals_load || true
  while IFS= read -r rpath; do
    [[ -n "$rpath" ]] || continue
    afk_monitor_cleanup_record "$rpath" || true
  done < <(afk_monitor_records)
  return 0
}

# --- the normalized read-only summary ---------------------------------------
#
# Read-only in the strict sense: it creates no directory and writes no file, so
# an ordinary `status` on a host that never dispatched anything is completely
# unchanged by the existence of this engine.

afk_monitor_summarize() {
  local rpath rec rc state entries="" pending=0 dpath
  local total=0 watching=0 completed=0 settled=0 degraded=0 unreadable=0
  local t_ret=0 w_ret=0 b_ret=0 rb_ret=0
  local state_out reason action dispatches

  # The derived verdict describes the state this summary is about to READ, not
  # the union of everything the process has seen: `monitor` summarizes once
  # before its action and once after it, and a pass that repaired the only
  # degraded Dispatch must be allowed to say so. What the pass itself could not
  # resolve is carried separately and is not cleared here; findings already
  # accumulated stay exactly where they are.
  AFK_MON_NEEDS_HUMAN="$AFK_MON_PASS_NEEDS_HUMAN"

  if [[ -z "${AFK_DISPATCH_WATCH_DIR:-}" || ! -d "$AFK_DISPATCH_WATCH_DIR" ]]; then
    AFK_R_DISPATCH="$AFK_DISPATCH_EMPTY"
    return 0
  fi

  while IFS= read -r dpath; do
    [[ -n "$dpath" ]] || continue
    pending=$((pending + 1))
  done < <(afk_monitor_deliveries)

  while IFS= read -r rpath; do
    [[ -n "$rpath" ]] || continue
    total=$((total + 1))
    rec="$(afk_monitor_record_read "$rpath")"
    rc=$?
    if (( rc != 0 )); then
      unreadable=$((unreadable + 1))
      AFK_MON_NEEDS_HUMAN="true"
      entries="${entries}$(jq -nc \
        '{id: null, state: "MONITOR_DEGRADED", acknowledged: false,
          fault: "DISPATCH_RECORD_UNREADABLE", context_budget: "NOT_EVALUATED",
          cleanup: null}')"$'\n'
      continue
    fi
    state="$(afk_monitor_jget "$rec" '.state // ""')"
    case "$state" in
      WATCHING)         watching=$((watching + 1)) ;;
      COMPLETED)        completed=$((completed + 1)) ;;
      SETTLED)          settled=$((settled + 1)) ;;
      MONITOR_DEGRADED) degraded=$((degraded + 1)); AFK_MON_NEEDS_HUMAN="true" ;;
    esac
    if [[ -n "$(afk_monitor_jget "$rec" '.fault // ""')" ]]; then
      AFK_MON_NEEDS_HUMAN="true"
    fi
    if [[ "$(afk_monitor_jget "$rec" '.result.needs_human // false')" == "true" ]]; then
      AFK_MON_NEEDS_HUMAN="true"
    fi
    if [[ "$state" != "SETTLED" ]]; then
      case "$(afk_monitor_jget "$rec" '.cleanup.terminal // "PENDING"')" in
        REMOVED|NOT_APPLICABLE) : ;;
        *) if [[ -n "$(afk_monitor_jget "$rec" '.provenance.terminal.handle // ""')" ]]; then
             t_ret=$((t_ret + 1))
           fi ;;
      esac
      case "$(afk_monitor_jget "$rec" '.cleanup.worktree // "PENDING"')" in
        REMOVED|NOT_APPLICABLE) : ;;
        *) if [[ -n "$(afk_monitor_jget "$rec" '.provenance.worktree.path // ""')" ]]; then
             w_ret=$((w_ret + 1))
           fi ;;
      esac
      case "$(afk_monitor_jget "$rec" '.cleanup.local_branch // "PENDING"')" in
        REMOVED|NOT_APPLICABLE) : ;;
        *) if [[ -n "$(afk_monitor_jget "$rec" '.provenance.branch.name // ""')" ]]; then
             b_ret=$((b_ret + 1))
           fi ;;
      esac
      case "$(afk_monitor_jget "$rec" '.cleanup.remote_branch // "PENDING"')" in
        REMOVED|NOT_APPLICABLE) : ;;
        *) if [[ -n "$(afk_monitor_jget "$rec" '.provenance.branch.remote // ""')" ]]; then
             rb_ret=$((rb_ret + 1))
           fi ;;
      esac
    fi
    entries="${entries}$(printf '%s' "$rec" | jq -c \
      '{id: .dispatch_id, state: .state, acknowledged: (.acknowledged == true),
        fault: .fault, context_budget: (.result.context_budget // "NOT_EVALUATED"),
        cleanup: .cleanup}')"$'\n'
  done < <(afk_monitor_records)

  if (( total == 0 )); then
    state_out="IDLE"; reason="DISPATCH_WATCH_IDLE"
  elif [[ "$AFK_MON_NEEDS_HUMAN" == "true" ]]; then
    state_out="NEEDS_HUMAN"; reason="MONITOR_DEGRADED"
  elif (( watching > 0 || completed > 0 )); then
    state_out="WATCHING"; reason="DISPATCH_WATCH_ACTIVE"
  else
    state_out="IDLE"; reason="DISPATCH_WATCH_IDLE"
  fi
  action=""
  if [[ "$state_out" == "NEEDS_HUMAN" ]]; then
    action="$(afk_reason_action MONITOR_DEGRADED)"
  fi
  dispatches="$(printf '%s' "$entries" | jq -sc '.')" || dispatches="[]"

  AFK_R_DISPATCH="$(jq -nc \
    --arg state "$state_out" --arg reason "$reason" --arg action "$action" \
    --argjson total "$total" --argjson watching "$watching" --argjson completed "$completed" \
    --argjson settled "$settled" --argjson degraded "$degraded" --argjson unreadable "$unreadable" \
    --argjson pending "$pending" \
    --argjson t "$t_ret" --argjson w "$w_ret" --argjson b "$b_ret" --argjson rb "$rb_ret" \
    --argjson dispatches "$dispatches" \
    '{state: $state, evaluated: true, reason: $reason,
      counts: {total: $total, watching: $watching, completed: $completed,
               settled: $settled, degraded: $degraded, unreadable: $unreadable},
      pending_deliveries: $pending,
      retained: {terminals: $t, worktrees: $w, local_branches: $b, remote_branches: $rb},
      dispatches: $dispatches,
      required_action: (if $action == "" then null else $action end)}')" || AFK_R_DISPATCH=""
  if [[ -z "$AFK_R_DISPATCH" ]]; then
    AFK_R_DISPATCH="$AFK_DISPATCH_EMPTY"
    AFK_MON_NEEDS_HUMAN="true"
  fi
  return 0
}

# The exit code for a monitor-scoped run: the requested scope is the monitor
# pass itself, so a pass that ends with something only a human can decide is an
# owner action, and a pass that settled everything it could is a success.
afk_monitor_exit_code() {
  if [[ "$AFK_MON_NEEDS_HUMAN" == "true" ]]; then
    printf '%s' "$AFK_EXIT_OWNER_ACTION"
  else
    printf '%s' "$AFK_EXIT_OK"
  fi
}
