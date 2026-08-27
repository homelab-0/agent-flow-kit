#!/usr/bin/env bash
# lifecycle-dispatch-tests.sh — the isolated deterministic gate for the durable
# worker-completion watch and the provenance-bound release of the resources a
# settled worker owned.
#
# Two layers:
#   UNIT      — the monitor primitives are sourced and called directly.
#   SCENARIO  — bin/agent-flow-kit is RUN against a fixture host with a stubbed
#               orca on PATH and real local Git repositories, so every
#               settlement branch is reached for real without a network, a
#               provider session, a worker, or a live Orca.
#
# Each section gets its own HOME, and therefore its own dispatch watch. That is
# not tidiness: the monitor is a whole-watch pass by design, so a record left
# behind by an earlier section would be re-evaluated by a later one and its
# findings would land in the count the later section is asserting on.
#
# The Orca stub models the two properties this contract turns on: a terminal
# that was closed WITHOUT a durable close intent comes back the next time Orca
# reconnects and rediscovers its sessions, and whether a close SUCCEEDS at all
# is a property of the daemon rather than something this kit may assume.
# Section 7 exercises both directly, so the non-resurrection assertion and the
# proven-release assertion are falsifiable rather than decorative.
#
# A check that could not compute a verdict here SKIPS loudly and is counted:
# the summary line carries the skip count, and a skipped check is not a pass.
#
# Nothing here touches the developer's real HOME, real installation, real Git
# state, a provider session, or a real Orca.
#
# Usage: tests/lifecycle-dispatch-tests.sh
# Exit:  0 all passed, 1 any failure.

set -uo pipefail

KIT_ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
AFK="$KIT_ROOT/bin/agent-flow-kit"

TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT

export GIT_AUTHOR_NAME="afk-test" GIT_AUTHOR_EMAIL="afk@test.invalid"
export GIT_COMMITTER_NAME="afk-test" GIT_COMMITTER_EMAIL="afk@test.invalid"

PASS=0 FAIL=0 SKIPPED=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  {
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  if [[ -n "${2:-}" ]]; then printf '        %s\n' "$2"; fi
  FAIL=$((FAIL + 1))
}
# A check this host cannot decide. It is counted and reported, because a
# scenario that quietly computed nothing is indistinguishable from one that
# passed, and that is exactly how a bounding assertion goes vacuous.
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; SKIPPED=$((SKIPPED + 1)); }
head1() { printf '\n\033[1m%s\033[0m\n' "$1"; }

assert_eq()       { if [[ "$2" == "$3"   ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
assert_ne()       { if [[ "$2" != "$3"   ]]; then ok "$1"; else bad "$1" "should not equal '$3'"; fi; }
assert_lt()       { if (( $2 < $3 )); then ok "$1"; else bad "$1" "expected less than $3, got $2"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing substring: $3"; fi; }
assert_file()     { if [[ -e "$2" ]]; then ok "$1"; else bad "$1" "missing: $2"; fi; }
assert_no_file()  { if [[ -e "$2" ]]; then bad "$1" "still present: $2"; else ok "$1"; fi; }

# ===========================================================================
head1 "0. Monitor primitives (lib sourced, nothing executed)"
# ===========================================================================

# shellcheck source=../lib/afk-common.sh
. "$KIT_ROOT/lib/afk-common.sh"
# shellcheck source=../lib/afk-readiness.sh
. "$KIT_ROOT/lib/afk-readiness.sh"
# shellcheck source=../lib/afk-monitor.sh
. "$KIT_ROOT/lib/afk-monitor.sh"

BAD_MSG=0; BAD_ACT=0; COUNT=0
while IFS= read -r code; do
  [[ -n "$code" ]] || continue
  COUNT=$((COUNT + 1))
  if [[ -z "$(afk_monitor_reason_message "$code")" ]]; then
    BAD_MSG=$((BAD_MSG + 1)); printf '        no message: %s\n' "$code"
  fi
  if [[ -z "$(afk_monitor_reason_action "$code")" ]]; then
    BAD_ACT=$((BAD_ACT + 1)); printf '        no action: %s\n' "$code"
  fi
done < <(afk_monitor_reason_codes)
assert_ne "the monitor vocabulary is non-empty" "$COUNT" "0"
assert_eq "every monitor code carries a specific message" "$BAD_MSG" "0"
assert_eq "every monitor code carries a required action"  "$BAD_ACT" "0"
assert_eq "no duplicate monitor codes" \
  "$(afk_monitor_reason_codes | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')" "0"
assert_eq "the monitor half never collides with the base half" \
  "$(comm -12 <(afk_reason_codes | LC_ALL=C sort) \
              <(afk_monitor_reason_codes | LC_ALL=C sort) | wc -l | tr -d ' ')" "0"
assert_eq "nor with the readiness half" \
  "$(comm -12 <(afk_readiness_reason_codes | LC_ALL=C sort) \
              <(afk_monitor_reason_codes | LC_ALL=C sort) | wc -l | tr -d ' ')" "0"
assert_eq "the base dispatcher reaches a monitor message" \
  "$(afk_reason_message CLEANUP_NEEDS_OWNER)" "$(afk_monitor_reason_message CLEANUP_NEEDS_OWNER)"
assert_ne "and it is not the generic fallback" \
  "$(afk_reason_message CLEANUP_NEEDS_OWNER)" "$AFK_REASON_FALLBACK"

# A dispatch id names a file inside kit state and arrives from outside.
for good in d1 AFK-PORT-1.3 a_b.c-9; do
  if afk_dispatch_id_is_safe "$good"; then ok "dispatch id '$good' is accepted"
  else bad "dispatch id '$good' is accepted"; fi
done
for evil in "" "../escape" "a/b" ".hidden" "a..b" "-leading"; do
  if afk_dispatch_id_is_safe "$evil"; then bad "dispatch id '${evil:-<empty>}' is refused"
  else ok "dispatch id '${evil:-<empty>}' is refused"; fi
done

for protected in master main develop release HEAD; do
  if afk_monitor_branch_is_protected "$protected"; then ok "'$protected' is never a deletion candidate"
  else bad "'$protected' is never a deletion candidate"; fi
done
if afk_monitor_branch_is_protected "topic-a"; then
  bad "an ordinary topic branch is not protected by name"
else
  ok "an ordinary topic branch is not protected by name"
fi

# The derived monitor verdict belongs to the reading the summary just took;
# what the PASS could not resolve is carried separately. That difference is the
# whole of "this watch needs a human" versus "some earlier reading in this
# process did", so it is asserted directly on the primitives. The watch and
# inbox are pinned to an empty fixture directory first: this suite never reads
# the developer's own dispatch state, not even from a sourced function.
AFK_DISPATCH_WATCH_DIR="$TMPROOT/unit/watch"
AFK_DISPATCH_INBOX_DIR="$TMPROOT/unit/inbox"
AFK_DISPATCH_RESULT_DIR="$TMPROOT/unit/results"
mkdir -p "$AFK_DISPATCH_WATCH_DIR" "$AFK_DISPATCH_INBOX_DIR" "$AFK_DISPATCH_RESULT_DIR"

afk_monitor_reset
assert_eq "a fresh monitor pass needs nobody" "$(afk_monitor_exit_code)" "$AFK_EXIT_OK"
AFK_MON_NEEDS_HUMAN="true"
afk_monitor_summarize
assert_eq "a derived verdict does not survive the next reading" \
  "$AFK_MON_NEEDS_HUMAN" "false"
afk_monitor_needs_human
afk_monitor_summarize
assert_eq "but what the pass itself could not resolve does" \
  "$AFK_MON_NEEDS_HUMAN" "true"
assert_eq "and it decides the exit code" "$(afk_monitor_exit_code)" "$AFK_EXIT_OWNER_ACTION"
afk_monitor_reset

# ===========================================================================
# scenario fixtures
# ===========================================================================

CHECKOUT="$TMPROOT/checkout"
BIN="$TMPROOT/bin"
mkdir -p "$CHECKOUT" "$BIN"

git_commit_all() { git -C "$1" add -A >/dev/null 2>&1
                   git -C "$1" -c commit.gpgsign=false commit -q --no-verify -m "$2" >/dev/null 2>&1; }

make_checkout() {
  local d="$1"
  mkdir -p "$d/lifecycle" "$d/files/model-router/scripts" "$d/files/humanizer/skills/humanizer"
  cat > "$d/lifecycle/kit.json" <<'JSON'
{
  "kit_id": "agent-flow-kit",
  "lifecycle_schema_version": "1.0",
  "state_schema_version": "1.0",
  "result_schema_version": "1.0",
  "default_branch": "master",
  "managed_inputs": ["files", "lifecycle"]
}
JSON
  printf 'model-router skill v1\n' > "$d/files/model-router/SKILL.md"
  printf 'dispatch v1\n' > "$d/files/model-router/scripts/dispatch.sh"
  printf 'launcher:\n  router_endpoint: https://canonical.invalid\n' \
    > "$d/files/model-router/subscriptions.yaml"
  printf 'humanizer v1\n' > "$d/files/humanizer/SKILL.md"
  printf 'humanizer inner skill v1\n' > "$d/files/humanizer/skills/humanizer/SKILL.md"
  printf 'policy line one\n' > "$d/files/claude-global-CLAUDE.md"
  printf 'codex guidance v1\n' > "$d/files/codex-AGENTS.md"
  git init -q "$d" >/dev/null 2>&1
  git -C "$d" symbolic-ref HEAD refs/heads/master >/dev/null 2>&1
  git_commit_all "$d" "canonical v1"
}
make_checkout "$CHECKOUT"

# --- the Orca stub --------------------------------------------------------
#
# Two files are the whole model. STUB_TERMS is what Orca rediscovers when it
# reconnects — the session history — and STUB_CLOSED is the set of terminals
# whose DURABLE close intent was recorded. A close without --durable kills the
# PTY and records nothing, so that terminal comes back on the next listing.
#
# STUB_CLOSE_FAILS selects whether the close REQUEST itself succeeds, which is
# a property of the daemon and not something the lifecycle may assume:
#   0  every close succeeds                     (the ordinary daemon)
#   1  a close for a handle Orca is not listing is refused ("no such terminal")
#   2  every close is refused                   (a build with no --durable)
STUB_TERMS="$TMPROOT/orca-terminals.txt"
STUB_CLOSED="$TMPROOT/orca-closed.txt"
: > "$STUB_TERMS"; : > "$STUB_CLOSED"
export STUB_TERMS STUB_CLOSED
STUB_CLOSE_FAILS=0

cat > "$BIN/orca" <<'STUB'
#!/usr/bin/env bash
is_listed() { # <handle> — what `terminal list` would show at this instant
  local h s
  while read -r h s; do
    [[ -n "$h" ]] || continue
    if grep -q -x -F -- "$h" "$STUB_CLOSED" 2>/dev/null; then continue; fi
    if [[ "$h" == "$1" ]]; then return 0; fi
  done < "$STUB_TERMS"
  return 1
}
case "${1:-} ${2:-}" in
  "terminal list")
    first=1
    printf '{"terminals":['
    while read -r h s; do
      [[ -n "$h" ]] || continue
      if grep -q -x -F -- "$h" "$STUB_CLOSED" 2>/dev/null; then continue; fi
      if (( first )); then first=0; else printf ','; fi
      printf '{"handle":"%s","status":"%s"}' "$h" "$s"
    done < "$STUB_TERMS"
    printf ']}\n'
    exit 0 ;;
  "terminal close")
    shift 2
    handle=""; durable=0
    while (( $# )); do
      case "$1" in
        --handle)  handle="${2:-}"; shift 2 ;;
        --durable) durable=1; shift ;;
        *)         shift ;;
      esac
    done
    case "${STUB_CLOSE_FAILS:-0}" in
      2) printf 'orca: this build does not support --durable\n' >&2; exit 1 ;;
      1) if ! is_listed "$handle"; then
           printf 'orca: no such terminal: %s\n' "$handle" >&2; exit 1
         fi ;;
    esac
    if (( durable )) && [[ -n "$handle" ]]; then
      printf '%s\n' "$handle" >> "$STUB_CLOSED"
      printf '{"ok":true,"closed":true,"durable":true}\n'
    else
      printf '{"ok":true,"closed":true,"durable":false}\n'
    fi
    exit 0 ;;
esac
exit 1
STUB
chmod +x "$BIN/orca"

terminal_add()    { printf '%s %s\n' "$1" "$2" >> "$STUB_TERMS"; }
terminal_listed() { # <handle> -> 0 when Orca still knows about it
  PATH="$BIN:$PATH" orca terminal list --json </dev/null 2>/dev/null \
    | jq -e --arg h "$1" '[.terminals[] | select(.handle == $h)] | length > 0' >/dev/null 2>&1
}
durable_close_requested() { # <handle> -> 0 when the durable close intent was recorded
  grep -q -x -F -- "$1" "$STUB_CLOSED" 2>/dev/null
}

HOMEDIR=""; STATE=""; WATCH=""; INBOX=""; RESULTS=""
new_scenario() { # <name> — a fresh HOME, and therefore a fresh dispatch watch
  HOMEDIR="$TMPROOT/sc-$1/home"
  STATE="$HOMEDIR/.local/state/agent-flow-kit"
  WATCH="$STATE/dispatch/watch"
  INBOX="$STATE/dispatch/inbox"
  RESULTS="$STATE/dispatch/results"
  mkdir -p "$HOMEDIR"
}

RUN_OUT=""; RUN_ERR=""; RUN_RC=0
run_afk() { # <args...>
  # stdin is closed deliberately: some of these calls happen inside a
  # `while read` loop, and a child that inherited that loop's input would eat
  # the cases the loop has not read yet.
  RUN_OUT="$(env PATH="$BIN:$PATH" HOME="$HOMEDIR" \
             XDG_STATE_HOME="$HOMEDIR/.local/state" \
             AFK_KIT_ROOT="$CHECKOUT" \
             STUB_TERMS="$STUB_TERMS" STUB_CLOSED="$STUB_CLOSED" \
             STUB_CLOSE_FAILS="${STUB_CLOSE_FAILS:-0}" \
             bash "$AFK" "$@" </dev/null 2>"$TMPROOT/stderr")"
  RUN_RC=$?
  RUN_ERR="$(cat "$TMPROOT/stderr" 2>/dev/null)"
}

jget() { printf '%s' "$RUN_OUT" | jq -r "$1"; }
rec()  { jq -r "$2" "$WATCH/$1.json" 2>/dev/null; }
count_findings() { # <reason>
  printf '%s' "$RUN_OUT" | jq -r --arg r "$1" '[.findings[] | select(.reason == $r)] | length'
}
count_files() { # <dir> <name pattern>
  find "$1" -maxdepth 1 -type f -name "$2" 2>/dev/null | wc -l | tr -d ' '
}
branch_sha() { # <repo> <branch>
  git -C "$1" rev-parse --verify --quiet "refs/heads/$2" 2>/dev/null
}

descriptor() { # <id> <task> <terminal|-> <worktree|-> <branch|-> <repo|-> <base|-> <remote|->
               # <pr_merged> <disposable> <remote_auth> [owned]
  jq -nc --arg id "$1" --arg task "$2" --arg term "$3" --arg wt "$4" \
     --arg br "$5" --arg repo "$6" --arg base "$7" --arg remote "$8" \
     --argjson merged "$9" --argjson disposable "${10}" --argjson auth "${11}" \
     --argjson owned "${12:-true}" '
    {dispatch_id: $id, task_id: $task,
     terminal: {handle: (if $term == "-" then "" else $term end), owned: $owned},
     worktree: {path: (if $wt == "-" then "" else $wt end), owned: $owned},
     branch: {name: (if $br == "-" then "" else $br end),
              repo: (if $repo == "-" then "" else $repo end),
              base: (if $base == "-" then "" else $base end),
              remote: (if $remote == "-" then "" else $remote end),
              owned: $owned, disposable: $disposable, pr_merged: $merged,
              remote_delete_authorized: $auth}}'
}

register() { # <descriptor json>
  printf '%s' "$1" > "$TMPROOT/descriptor.json"
  run_afk monitor --json --register "$TMPROOT/descriptor.json"
}

deliver() { # <delivery id> <dispatch id> <kind> <status>
  mkdir -p "$INBOX"
  jq -nc --arg d "$1" --arg t "$2" --arg k "$3" --arg s "$4" \
    '{schema_version: "1.0", delivery_id: $d, dispatch_id: $t, kind: $k,
      result: {status: $s, summary: "one bounded worker result",
               evidence: ["evidence/one.log"]}}' > "$INBOX/$1.json"
}

deliver_heartbeat() { # <delivery id> <dispatch id> — a heartbeat carries no result
  mkdir -p "$INBOX"
  jq -nc --arg d "$1" --arg t "$2" \
    '{schema_version: "1.0", delivery_id: $d, dispatch_id: $t, kind: "heartbeat"}' \
    > "$INBOX/$1.json"
}

new_repo() { # <dir> — a repository with one commit on master
  git init -q "$1" >/dev/null 2>&1
  git -C "$1" symbolic-ref HEAD refs/heads/master >/dev/null 2>&1
  printf 'base\n' > "$1/README"
  git_commit_all "$1" "base"
}

# ===========================================================================
head1 "1. The watch is durable, and registering it is idempotent"
# ===========================================================================

new_scenario watch

run_afk monitor --json
assert_eq "a host that never dispatched reports no watch" \
  "$(jget '.dispatch_monitor.state')" "NOT_AVAILABLE"
assert_eq "with a stable reason" \
  "$(jget '.dispatch_monitor.reason')" "DISPATCH_WATCH_NOT_AVAILABLE"
assert_eq "and reporting it is a successful pass" "$RUN_RC" "0"
assert_no_file "reporting created no watch directory" "$WATCH"

register "$(descriptor d-basic TASK-1 term-basic - - - - - false false false)"
assert_eq "registering a Dispatch succeeds" "$RUN_RC" "0"
assert_file "and writes a durable watch record" "$WATCH/d-basic.json"
assert_eq "the record starts watching" "$(rec d-basic '.state')" "WATCHING"
assert_eq "nothing is acknowledged yet" "$(rec d-basic '.acknowledged')" "false"
assert_eq "no result is retained yet" "$(rec d-basic '.result.retained')" "false"
assert_eq "settlement has been scheduled zero times" "$(rec d-basic '.settlement.scheduled_count')" "0"
assert_eq "every cleanup disposition starts PENDING" \
  "$(rec d-basic '[.cleanup.terminal, .cleanup.worktree, .cleanup.local_branch, .cleanup.remote_branch] | unique | join(",")')" \
  "PENDING"
assert_ne "the bounded poll budget is carried on the record" \
  "$(rec d-basic '.poll.interval_seconds')" "null"
assert_ne "with its backoff ceiling" "$(rec d-basic '.poll.backoff_ceiling_seconds')" "null"
assert_eq "the watch is now reported as active" \
  "$(jget '.dispatch_monitor.state')" "WATCHING"
assert_eq "with one watched Dispatch" "$(jget '.dispatch_monitor.counts.watching')" "1"

WATCH_BEFORE="$(jq -S -c . "$WATCH/d-basic.json")"
register "$(descriptor d-basic TASK-1 term-other - - - - - false false false)"
assert_eq "re-registering the same Dispatch changes nothing" \
  "$(jq -S -c . "$WATCH/d-basic.json")" "$WATCH_BEFORE"
assert_eq "and says so rather than resetting the watch" \
  "$(count_findings DISPATCH_WATCH_REGISTERED)" "1"
assert_eq "still exactly one watch record" "$(count_files "$WATCH" '*.json')" "1"

printf 'not a descriptor\n' > "$TMPROOT/descriptor.json"
run_afk monitor --json --register "$TMPROOT/descriptor.json"
assert_eq "an unusable descriptor is refused" \
  "$(count_findings DISPATCH_DESCRIPTOR_INVALID)" "1"
assert_eq "as an owner action" "$RUN_RC" "2"
assert_eq "and no Dispatch was invented from it" "$(count_files "$WATCH" '*.json')" "1"

register "$(descriptor ../escape TASK-X - - - - - - false false false)"
assert_eq "a descriptor whose id is not an identifier is refused" \
  "$(count_findings DISPATCH_DESCRIPTOR_INVALID)" "1"
assert_eq "and still exactly one watch record" "$(count_files "$WATCH" '*.json')" "1"

# ===========================================================================
head1 "2. A completion that arrives after the turn yielded is still consumed"
# ===========================================================================

deliver del-1 d-basic worker_done done
run_afk monitor --json --reconcile
assert_eq "the durable watcher consumed the delivery on its own" \
  "$(rec d-basic '.state')" "COMPLETED"
assert_eq "and acknowledged it" "$(rec d-basic '.acknowledged')" "true"
assert_eq "the result was retained" "$(rec d-basic '.result.retained')" "true"
assert_eq "with the worker's own status" "$(rec d-basic '.result.status')" "done"
assert_contains "and a bounded identity" "$(rec d-basic '.result.identity')" "sha256:"
assert_file "the retained result is on disk" "$RESULTS/d-basic.result.json"
assert_file "with its traceability record beside it" "$RESULTS/d-basic.traceability.json"
assert_eq "settlement was scheduled exactly once" \
  "$(rec d-basic '.settlement.scheduled_count')" "1"
assert_eq "and one traceability record was written" \
  "$(rec d-basic '.traceability.records')" "1"
assert_eq "the delivery was acknowledged only after all of that" \
  "$(count_files "$INBOX" '*.json')" "0"
assert_eq "normalized state counts it as completed" \
  "$(jget '.dispatch_monitor.counts.completed')" "1"
assert_eq "and nothing is left pending" "$(jget '.dispatch_monitor.pending_deliveries')" "0"
assert_eq "a completed worker needs no human on its own" "$RUN_RC" "0"
assert_eq "the retained result is reported" "$(count_findings WORKER_DONE_RETAINED)" "1"

# ===========================================================================
head1 "3. Delivery is at-least-once, and its handling is idempotent"
# ===========================================================================

# An Orca disconnect after worker_done was committed but before the
# acknowledgement reached it: the same delivery arrives again.
RESULT_BEFORE="$(rec d-basic '.result.identity')"
deliver del-1 d-basic worker_done done
run_afk monitor --json --reconcile
assert_eq "the replay is recognized and dropped" \
  "$(count_findings DELIVERY_REPLAY_IGNORED)" "1"
assert_eq "settlement is still scheduled exactly once" \
  "$(rec d-basic '.settlement.scheduled_count')" "1"
assert_eq "traceability was not written a second time" \
  "$(rec d-basic '.traceability.records')" "1"
assert_eq "and there is still exactly one traceability record on disk" \
  "$(count_files "$RESULTS" '*.traceability.json')" "1"
assert_eq "the retained result is unchanged" "$(rec d-basic '.result.identity')" "$RESULT_BEFORE"
assert_eq "the record stays completed" "$(rec d-basic '.state')" "COMPLETED"
assert_eq "and the duplicate was consumed rather than left behind" \
  "$(count_files "$INBOX" '*.json')" "0"

# A coordinator restart with one completed unacknowledged Dispatch and one
# active Dispatch reconciles the first and preserves the second.
register "$(descriptor d-active TASK-2 term-active - - - - - false false false)"
deliver del-2 d-basic worker_done gates_failed
run_afk monitor --json --reconcile
assert_eq "the completed Dispatch is reconciled" "$(rec d-basic '.state')" "COMPLETED"
assert_eq "carrying the outcome the worker actually reported" \
  "$(rec d-basic '.result.status')" "gates_failed"
assert_eq "the active Dispatch is preserved exactly as it was" \
  "$(rec d-active '.state')" "WATCHING"
assert_eq "and is still unacknowledged" "$(rec d-active '.acknowledged')" "false"
assert_eq "settlement was still scheduled only once for the completed one" \
  "$(rec d-basic '.settlement.scheduled_count')" "1"

# ===========================================================================
head1 "4. A monitoring fault is a fault, never an invented worker result"
# ===========================================================================

# Heartbeat expiry. The deadline is moved into the past rather than slept
# through: the condition under test is the expiry, not the wall clock.
new_scenario heartbeat
register "$(descriptor d-heartbeat TASK-3 term-heartbeat - - - - - false false false)"
jq '.heartbeat_deadline_epoch = 1' "$WATCH/d-heartbeat.json" > "$TMPROOT/hb.json"
mv "$TMPROOT/hb.json" "$WATCH/d-heartbeat.json"
run_afk monitor --json --reconcile
assert_eq "an expired heartbeat degrades the watch" \
  "$(rec d-heartbeat '.state')" "MONITOR_DEGRADED"
assert_eq "with a monitoring fault, not an outcome" \
  "$(rec d-heartbeat '.fault')" "WORKER_HEARTBEAT_EXPIRED"
assert_eq "no result was manufactured" "$(rec d-heartbeat '.result.retained')" "false"
assert_eq "and the status stays unknown" "$(rec d-heartbeat '.result.status')" "null"
assert_eq "reported loudly" "$(count_findings WORKER_HEARTBEAT_EXPIRED)" "1"
assert_eq "as an owner action" "$RUN_RC" "2"
assert_eq "and the watch as a whole needs a human" \
  "$(jget '.dispatch_monitor.state')" "NEEDS_HUMAN"

# The heartbeat WINDOW belongs to the Dispatch that declared it, and every
# refresh has to use that one. A Dispatch registered with a longer window whose
# deadline is refreshed from the process default expires while its worker is
# still reporting on time — a loud WORKER_HEARTBEAT_EXPIRED nobody caused — and
# a shorter one quietly stops being watched as closely as it asked to be.
DEFAULT_HB="$AFK_MONITOR_HEARTBEAT_SECONDS"
DECLARED_HB=$(( DEFAULT_HB * 3 ))
assert_ne "the fixture window really differs from the default" "$DECLARED_HB" "$DEFAULT_HB"

new_scenario heartbeat-window
register "$(descriptor d-hbwindow TASK-3B term-hbwindow - - - - - false false false \
            | jq -c --argjson hb "$DECLARED_HB" '.heartbeat_seconds = $hb')"
assert_eq "the declared window is persisted on the watch record" \
  "$(rec d-hbwindow '.heartbeat_seconds')" "$DECLARED_HB"
assert_eq "and the first deadline is one window away" \
  "$(rec d-hbwindow '.heartbeat_deadline_epoch - .created_epoch')" "$DECLARED_HB"

deliver_heartbeat del-hb-declared d-hbwindow
run_afk monitor --json --reconcile
assert_eq "a heartbeat refreshes the deadline with the DECLARED window" \
  "$(rec d-hbwindow '.heartbeat_deadline_epoch - .last_heartbeat_epoch')" "$DECLARED_HB"
assert_ne "never with the process default" \
  "$(rec d-hbwindow '.heartbeat_deadline_epoch - .last_heartbeat_epoch')" "$DEFAULT_HB"
assert_eq "the Dispatch is still simply being watched" "$(rec d-hbwindow '.state')" "WATCHING"
assert_eq "with no monitoring fault invented for it" "$(rec d-hbwindow '.fault')" "null"
assert_eq "and nothing was reported as expired" \
  "$(count_findings WORKER_HEARTBEAT_EXPIRED)" "0"
assert_eq "the heartbeat was consumed" "$(count_files "$INBOX" '*.json')" "0"
assert_eq "so the pass needs nobody" "$RUN_RC" "0"

# The compatibility control: a record written before the window was persisted
# carries none, and only that record refreshes from the process default.
new_scenario heartbeat-window-legacy
register "$(descriptor d-hblegacy TASK-3C term-hblegacy - - - - - false false false)"
jq 'del(.heartbeat_seconds)' "$WATCH/d-hblegacy.json" > "$TMPROOT/hb-legacy.json"
mv "$TMPROOT/hb-legacy.json" "$WATCH/d-hblegacy.json"
assert_eq "the control record carries no stored window" \
  "$(rec d-hblegacy '.heartbeat_seconds')" "null"
deliver_heartbeat del-hb-legacy d-hblegacy
run_afk monitor --json --reconcile
assert_eq "a record with no stored window still refreshes with the default" \
  "$(rec d-hblegacy '.heartbeat_deadline_epoch - .last_heartbeat_epoch')" "$DEFAULT_HB"
assert_eq "and it is still watched, not degraded" "$(rec d-hblegacy '.state')" "WATCHING"

# A terminal that is simply gone is not a completion.
new_scenario gone
terminal_add term-gone EXITED
register "$(descriptor d-gone TASK-4 term-gone - - - - - false false false)"
run_afk monitor --json --reconcile --live
assert_eq "a terminal that exited without a delivery degrades the watch" \
  "$(rec d-gone '.state')" "MONITOR_DEGRADED"
assert_eq "with its own fault" \
  "$(rec d-gone '.fault')" "WORKER_TERMINAL_EXITED_WITHOUT_DELIVERY"
assert_eq "and DONE is never manufactured from it" "$(rec d-gone '.result.status')" "null"
assert_eq "reported loudly" "$(count_findings WORKER_TERMINAL_EXITED_WITHOUT_DELIVERY)" "1"

# A completion that cannot be parsed stays unacknowledged and recoverable.
new_scenario unparseable
register "$(descriptor d-broken TASK-5 term-broken - - - - - false false false)"
mkdir -p "$INBOX"
jq -nc '{schema_version: "1.0", delivery_id: "del-broken", dispatch_id: "d-broken",
         kind: "worker_done", result: {summary: "no status anywhere"}}' \
  > "$INBOX/del-broken.json"
run_afk monitor --json --reconcile
assert_eq "an unreadable result is a loud fault" "$(count_findings RESULT_UNPARSEABLE)" "1"
assert_eq "the Dispatch is degraded, not completed" "$(rec d-broken '.state')" "MONITOR_DEGRADED"
assert_eq "nothing was acknowledged" "$(rec d-broken '.acknowledged')" "false"
assert_file "and the delivery is retained rather than dropped" "$INBOX/del-broken.json"
assert_eq "which is an owner action" "$RUN_RC" "2"

rm -f "$INBOX/del-broken.json"
deliver del-fixed d-broken worker_done done
run_afk monitor --json --reconcile
assert_eq "a corrected delivery reconciles on the next pass" \
  "$(rec d-broken '.state')" "COMPLETED"
assert_eq "the fault is cleared rather than remembered forever" "$(rec d-broken '.fault')" "null"
assert_eq "and the result is retained" "$(rec d-broken '.result.status')" "done"
# The pass that REPAIRED the only fault is not an owner action, and the summary
# it emits describes the state it just read. Both are properties of the PASS
# rather than of the record, and the record assertions above cannot see them: a
# summary that remembered the fault it had already repaired leaves this pass
# reporting NEEDS_HUMAN and exiting 2 over a document whose own counts say
# nothing is degraded.
assert_eq "the repairing pass is a successful pass" "$RUN_RC" "0"
assert_eq "and the summary describes the state it left behind" \
  "$(jget '.dispatch_monitor.state')" "WATCHING"
assert_eq "with nothing degraded in it" \
  "$(jget '.dispatch_monitor.counts.degraded')" "0"
assert_eq "and no dispatch carrying a fault" \
  "$(jget '[.dispatch_monitor.dispatches[] | select(.fault != null)] | length')" "0"

# A delivery never creates a Dispatch.
new_scenario orphan
deliver del-orphan d-nobody worker_done done
run_afk monitor --json --reconcile
assert_eq "a delivery for an unknown Dispatch is loud" "$(count_findings DISPATCH_UNKNOWN)" "1"
assert_no_file "and no watch record is invented from it" "$WATCH/d-nobody.json"
assert_file "the delivery stays on disk for its owner" "$INBOX/del-orphan.json"
assert_eq "and the pass that could not place it still needs a human" "$RUN_RC" "2"

# Escalation completes the watch and hands the decision to a human.
new_scenario escalation
register "$(descriptor d-escalate TASK-6 term-escalate - - - - - false false false)"
deliver del-esc d-escalate escalation needs_human
run_afk monitor --json --reconcile
assert_eq "an escalation is retained and reconciled" "$(rec d-escalate '.state')" "COMPLETED"
assert_eq "and marked as needing a human" "$(rec d-escalate '.result.needs_human')" "true"
assert_eq "loudly" "$(count_findings WORKER_ESCALATION_RETAINED)" "1"
assert_eq "which is an owner action" "$RUN_RC" "2"

run_afk monitor --json --cleanup --live
assert_eq "and its resources stay retained until that decision is made" \
  "$(count_findings CLEANUP_NEEDS_OWNER)" "1"
assert_eq "so the Dispatch is not settled" "$(rec d-escalate '.state')" "COMPLETED"

# ===========================================================================
head1 "5. Settlement releases exactly what provenance proves AFK created"
# ===========================================================================

new_scenario settle

REPO="$TMPROOT/repo-merged"
BARE="$TMPROOT/remote-merged.git"
WT="$TMPROOT/wt-merged"
new_repo "$REPO"
git init -q --bare "$BARE" >/dev/null 2>&1
git -C "$REPO" remote add origin "$BARE" >/dev/null 2>&1
git -C "$REPO" worktree add -q -b topic-merged "$WT" >/dev/null 2>&1
printf 'worker output\n' > "$WT/WORK.md"
git_commit_all "$WT" "the worker's commit"
git -C "$REPO" push -q origin topic-merged >/dev/null 2>&1
git -C "$REPO" -c commit.gpgsign=false merge -q --no-edit topic-merged >/dev/null 2>&1

assert_eq "the fixture branch really is merged into its base" \
  "$(git -C "$REPO" rev-list --count master..topic-merged 2>/dev/null)" "0"
assert_ne "and it really is on the remote" \
  "$(git -C "$REPO" ls-remote --heads origin topic-merged 2>/dev/null)" ""

terminal_add term-merged IDLE
register "$(descriptor d-merged TASK-7 term-merged "$WT" topic-merged "$REPO" master origin true false true)"
deliver del-merged d-merged worker_done done
run_afk monitor --json --cleanup --live

assert_eq "the terminal was released" "$(rec d-merged '.cleanup.terminal')" "REMOVED"
assert_eq "the worktree was removed" "$(rec d-merged '.cleanup.worktree')" "REMOVED"
assert_eq "the local branch was deleted" "$(rec d-merged '.cleanup.local_branch')" "REMOVED"
assert_eq "and the authorized remote branch with it" \
  "$(rec d-merged '.cleanup.remote_branch')" "REMOVED"
assert_eq "so the Dispatch settled" "$(rec d-merged '.state')" "SETTLED"
assert_eq "reported as complete" "$(rec d-merged '.cleanup.complete')" "true"
assert_no_file "the worktree directory is gone" "$WT"
assert_eq "the local branch is gone" "$(branch_sha "$REPO" topic-merged)" ""
assert_eq "the remote branch is gone too" \
  "$(git -C "$REPO" ls-remote --heads origin topic-merged 2>/dev/null)" ""
if terminal_listed term-merged; then bad "the released terminal is absent afterwards"
else ok "the released terminal is absent afterwards"; fi
assert_file "the retained result outlived the worktree that produced it" \
  "$RESULTS/d-merged.result.json"
assert_eq "and settlement is reported without needing a human" \
  "$(count_findings CLEANUP_COMPLETE)" "1"
assert_eq "which is a successful pass" "$RUN_RC" "0"

# Repeating cleanup recreates nothing and changes nothing.
SETTLED_BEFORE="$(jq -S -c . "$WATCH/d-merged.json")"
run_afk monitor --json --cleanup --live
assert_eq "repeating cleanup is idempotent" \
  "$(jq -S -c . "$WATCH/d-merged.json")" "$SETTLED_BEFORE"
assert_no_file "it recreated no worktree" "$WT"
assert_eq "and no branch" "$(branch_sha "$REPO" topic-merged)" ""

# A merged branch whose remote deletion is NOT an authority this host holds.
new_scenario unauthorized
REPO2="$TMPROOT/repo-unauth"
BARE2="$TMPROOT/remote-unauth.git"
WT2="$TMPROOT/wt-unauth"
new_repo "$REPO2"
git init -q --bare "$BARE2" >/dev/null 2>&1
git -C "$REPO2" remote add origin "$BARE2" >/dev/null 2>&1
git -C "$REPO2" worktree add -q -b topic-unauth "$WT2" >/dev/null 2>&1
printf 'more output\n' > "$WT2/WORK.md"
git_commit_all "$WT2" "the worker's commit"
git -C "$REPO2" push -q origin topic-unauth >/dev/null 2>&1
git -C "$REPO2" -c commit.gpgsign=false merge -q --no-edit topic-unauth >/dev/null 2>&1

terminal_add term-unauth IDLE
register "$(descriptor d-unauth TASK-8 term-unauth "$WT2" topic-unauth "$REPO2" master origin true false false)"
deliver del-unauth d-unauth worker_done done
run_afk monitor --json --cleanup --live
assert_eq "the local worktree is released" "$(rec d-unauth '.cleanup.worktree')" "REMOVED"
assert_eq "including the local branch" "$(rec d-unauth '.cleanup.local_branch')" "REMOVED"
assert_eq "but the remote branch is retained" "$(rec d-unauth '.cleanup.remote_branch')" "RETAINED"
assert_eq "with the authority reason" "$(count_findings REMOTE_BRANCH_RETAINED_UNAUTHORIZED)" "1"
assert_ne "and the remote branch is still there" \
  "$(git -C "$REPO2" ls-remote --heads origin topic-unauth 2>/dev/null)" ""
assert_eq "so the Dispatch is not presented as settled" "$(rec d-unauth '.state')" "COMPLETED"
assert_eq "and cleanup is not reported complete" "$(rec d-unauth '.cleanup.complete')" "false"
assert_eq "the retained remote branch is counted in normalized state" \
  "$(jget '.dispatch_monitor.retained.remote_branches')" "1"

# --- the remote observation is bounded, and it never prompts ---------------
#
# The settlement pass reaches the network three times. A transport that accepts
# the connection and then says nothing — a dropped VPN, a black-holed host, a
# stalled proxy — is the ordinary way that happens, and an unbounded
# `git ls-remote` inside the pass turns "exactly one bounded pass per
# invocation" into a coordinator stuck in a call that never returns. The
# transport below stalls for two minutes: a pass that returns in seconds returns
# because the lifecycle bounded the observation itself, and one that does not
# fails the elapsed assertion rather than hanging this gate forever.
#
# The bounding tool is what makes that discriminate. On a host with no
# timeout(1) the wrapper REFUSES before the call is made, so the dispositions
# below would hold for a reason that has nothing to do with bounding a stalled
# transport. The two readings are therefore separated below: the stalled
# transport is only asserted where it can actually stall, and the refusal is
# asserted as its own labelled case.
new_scenario stalled-remote
SLOW_SSH="$TMPROOT/slow-ssh"
printf '#!/bin/sh\nexec sleep 120\n' > "$SLOW_SSH"; chmod +x "$SLOW_SSH"
REPO7="$TMPROOT/repo-stalled"
new_repo "$REPO7"
git -C "$REPO7" branch topic-stalled >/dev/null 2>&1
git -C "$REPO7" remote add origin "ssh://nowhere.invalid/x.git" >/dev/null 2>&1
register "$(descriptor d-stalled TASK-14 - - topic-stalled "$REPO7" master origin false false false)"
deliver del-stalled d-stalled worker_done done

BOUND_TOOL=no
if command -v timeout >/dev/null 2>&1; then BOUND_TOOL=yes; fi

STALL_START="$(date +%s)"
export GIT_SSH_COMMAND="$SLOW_SSH"
run_afk monitor --json --cleanup --live
unset GIT_SSH_COMMAND
STALL_ELAPSED=$(( $(date +%s) - STALL_START ))

# True of both readings: an observation that did not complete proves nothing
# either way, so it is never a deletion and never a "deleted".
assert_eq "an unprovable remote observation fails closed on NEEDS_OWNER" \
  "$(rec d-stalled '.cleanup.remote_branch')" "NEEDS_OWNER"
assert_eq "with the reason that names why" "$(count_findings CLEANUP_NEEDS_OWNER)" "1"
assert_eq "the Dispatch is not settled on an unproven remote" \
  "$(rec d-stalled '.state')" "COMPLETED"
assert_eq "the retained remote branch is still reported" \
  "$(jget '.dispatch_monitor.retained.remote_branches')" "1"
assert_eq "and the pass says a human must decide" "$RUN_RC" "2"

if [[ "$BOUND_TOOL" == "yes" ]]; then
  # The case under test: the call WAS made, against a transport that says
  # nothing for two minutes, and the pass returned anyway.
  assert_lt "a stalled remote does not stop the pass from returning" "$STALL_ELAPSED" "30"
  assert_eq "and the observation was bounded rather than refused" \
    "$(count_findings PROBE_BOUND_UNAVAILABLE)" "0"
else
  # The other reading, asserted as its own case rather than left looking like
  # the one above: nothing here touched the transport at all.
  assert_eq "a host that cannot bound the observation refuses to make it" \
    "$(count_findings PROBE_BOUND_UNAVAILABLE)" "1"
  skip "stalled-transport bounding NOT PROVEN on this host: no timeout(1), so the wrapper refused before the call"
fi

# The control: the same descriptor shape and the same code path against a
# transport that answers. Without it the assertions above would pass just as
# well on a lifecycle that had simply stopped looking at remotes.
new_scenario answering-remote
REPO8="$TMPROOT/repo-answering"
BARE8="$TMPROOT/remote-answering.git"
new_repo "$REPO8"
git init -q --bare "$BARE8" >/dev/null 2>&1
git -C "$REPO8" remote add origin "$BARE8" >/dev/null 2>&1
git -C "$REPO8" branch topic-answering >/dev/null 2>&1
git -C "$REPO8" push -q origin topic-answering >/dev/null 2>&1
register "$(descriptor d-answering TASK-15 - - topic-answering "$REPO8" master origin false false false)"
deliver del-answering d-answering worker_done done
run_afk monitor --json --cleanup --live
if [[ "$BOUND_TOOL" == "yes" ]]; then
  assert_eq "an answering transport still completes the disposition" \
    "$(rec d-answering '.cleanup.remote_branch')" "RETAINED"
  assert_eq "with the authority reason rather than an owner action" \
    "$(count_findings REMOTE_BRANCH_RETAINED_UNAUTHORIZED)" "1"
  assert_eq "and no cleanup step reports it could not prove itself" \
    "$(count_findings CLEANUP_NEEDS_OWNER)" "0"
else
  skip "the answering-transport control NOT RUN: without timeout(1) no remote observation is made at all"
fi
assert_ne "the remote branch is untouched" \
  "$(git -C "$REPO8" ls-remote --heads origin topic-answering 2>/dev/null)" ""

# ===========================================================================
head1 "6. Cleanup refuses everything it cannot prove it may release"
# ===========================================================================

# An unsettled worker's resources are never touched.
new_scenario unsettled
REPO3="$TMPROOT/repo-unsettled"
WT3="$TMPROOT/wt-unsettled"
new_repo "$REPO3"
git -C "$REPO3" worktree add -q -b topic-unsettled "$WT3" >/dev/null 2>&1
terminal_add term-unsettled ACTIVE
register "$(descriptor d-unsettled TASK-9 term-unsettled "$WT3" topic-unsettled "$REPO3" master - false false false)"
run_afk monitor --json --cleanup --live
assert_eq "an unsettled worker keeps its resources" \
  "$(count_findings WORKTREE_RETAINED_UNSETTLED)" "1"
assert_file "its worktree is untouched" "$WT3"
assert_ne "its branch is untouched" "$(branch_sha "$REPO3" topic-unsettled)" ""
if terminal_listed term-unsettled; then ok "and its active terminal is never closed"
else bad "and its active terminal is never closed"; fi

# A terminal a human is using is out of reach of generic cleanup.
while IFS='|' read -r handle status want; do
  [[ -n "$handle" ]] || continue
  new_scenario "term-$handle"
  terminal_add "$handle" "$status"
  register "$(descriptor "d-$handle" TASK-T "$handle" - - - - - false false false)"
  deliver "del-$handle" "d-$handle" worker_done done
  run_afk monitor --json --cleanup --live
  assert_eq "a $status terminal is retained, not closed" \
    "$(rec "d-$handle" '.cleanup.terminal')" "RETAINED"
  assert_eq "and the reason names why: $want" "$(count_findings "$want")" "1"
  if terminal_listed "$handle"; then ok "and it is still there afterwards: $handle"
  else bad "and it is still there afterwards: $handle"; fi
done <<'CASES'
term-busy|ACTIVE|TERMINAL_RETAINED_ACTIVE
term-asking|AWAITING_ANSWER|TERMINAL_RETAINED_AWAITING_ANSWER
term-vague|AMBIGUOUS|TERMINAL_RETAINED_AMBIGUOUS
term-taken|USER_TAKEOVER|TERMINAL_RETAINED_USER_TAKEOVER
CASES

# A terminal with no watch record at all — a coordinator's own tab — is not
# reachable by this code, so generic cleanup cannot touch it.
new_scenario coordinator
terminal_add term-coordinator ACTIVE
run_afk monitor --json --cleanup --live
if terminal_listed term-coordinator; then ok "an unowned coordinator terminal is never closed"
else bad "an unowned coordinator terminal is never closed"; fi

# Unaccounted content in a worktree blocks its removal.
new_scenario dirty
REPO4="$TMPROOT/repo-dirty"
WT4="$TMPROOT/wt-dirty"
new_repo "$REPO4"
git -C "$REPO4" worktree add -q -b topic-dirty "$WT4" >/dev/null 2>&1
printf 'nobody looked at this\n' > "$WT4/UNTRACKED.md"
terminal_add term-dirty IDLE
register "$(descriptor d-dirty TASK-10 term-dirty "$WT4" topic-dirty "$REPO4" master - true false false)"
deliver del-dirty d-dirty worker_done done
run_afk monitor --json --cleanup --live
assert_eq "a dirty worktree is retained" "$(rec d-dirty '.cleanup.worktree')" "RETAINED"
assert_eq "with the reason that names why" "$(count_findings WORKTREE_RETAINED_DIRTY)" "1"
assert_file "and the unaccounted content is still there" "$WT4/UNTRACKED.md"
assert_eq "the branch behind it is retained too" \
  "$(rec d-dirty '.cleanup.local_branch')" "RETAINED"
assert_eq "for the reason that names why" "$(count_findings BRANCH_RETAINED_WORKTREE_PRESENT)" "1"

# Branch dispositions, one scenario and one repository per case.
branch_case() { # <name> <pr_merged> <disposable> <unique-commit> <disposition> <reason>
  local name="$1" merged="$2" disposable="$3" unique="$4" want="$5" want_reason="$6"
  local repo="$TMPROOT/repo-$name" wt="$TMPROOT/wt-$name"
  new_scenario "branch-$name"
  new_repo "$repo"
  git -C "$repo" worktree add -q -b "topic-$name" "$wt" >/dev/null 2>&1
  if [[ "$unique" == "true" ]]; then
    printf 'unique work\n' > "$wt/UNIQUE.md"
    git_commit_all "$wt" "unique work nobody has"
  fi
  git -C "$repo" worktree remove "$wt" >/dev/null 2>&1
  terminal_add "term-$name" IDLE
  register "$(descriptor "d-$name" TASK-B "term-$name" - "topic-$name" "$repo" master - \
              "$merged" "$disposable" false)"
  deliver "del-$name" "d-$name" worker_done done
  run_afk monitor --json --cleanup --live
  assert_eq "branch case '$name' is $want" "$(rec "d-$name" '.cleanup.local_branch')" "$want"
  assert_eq "branch case '$name' says why" "$(count_findings "$want_reason")" "1"
  if [[ "$want" == "REMOVED" ]]; then
    assert_eq "branch case '$name': the branch is gone" "$(branch_sha "$repo" "topic-$name")" ""
  else
    assert_ne "branch case '$name': the branch is retained on disk" \
      "$(branch_sha "$repo" "topic-$name")" ""
  fi
}

branch_case unmerged   false false false RETAINED BRANCH_RETAINED_UNMERGED
branch_case unique     true  false true  RETAINED BRANCH_RETAINED_UNIQUE_COMMITS
branch_case disposable false true  false REMOVED  BRANCH_DELETED

# A protected or default branch is never a deletion candidate, whatever the
# record claims about it.
new_scenario protected
REPO5="$TMPROOT/repo-protected"
new_repo "$REPO5"
terminal_add term-protected IDLE
register "$(descriptor d-protected TASK-11 term-protected - master "$REPO5" master - true true false)"
deliver del-protected d-protected worker_done done
run_afk monitor --json --cleanup --live
assert_eq "a protected branch is retained" "$(rec d-protected '.cleanup.local_branch')" "RETAINED"
assert_eq "with the reason that names why" "$(count_findings BRANCH_RETAINED_PROTECTED)" "1"
assert_ne "and it is still there" "$(branch_sha "$REPO5" master)" ""

# A resource this host cannot prove it created is report-only inventory.
new_scenario legacy
REPO6="$TMPROOT/repo-legacy"
WT6="$TMPROOT/wt-legacy"
new_repo "$REPO6"
git -C "$REPO6" worktree add -q -b legacy-branch "$WT6" >/dev/null 2>&1
terminal_add term-legacy IDLE
register "$(descriptor d-legacy TASK-12 term-legacy "$WT6" legacy-branch "$REPO6" master - \
            true true false false)"
deliver del-legacy d-legacy worker_done done
run_afk monitor --json --cleanup --live
assert_eq "an unowned terminal is retained" "$(rec d-legacy '.cleanup.terminal')" "RETAINED"
assert_eq "an unowned worktree is retained" "$(rec d-legacy '.cleanup.worktree')" "RETAINED"
assert_eq "an unowned branch is retained"   "$(rec d-legacy '.cleanup.local_branch')" "RETAINED"
assert_eq "the terminal says it carries no provenance" "$(count_findings TERMINAL_NOT_OWNED)" "1"
assert_eq "the worktree says the same" "$(count_findings WORKTREE_NOT_OWNED)" "1"
assert_eq "and so does the branch" "$(count_findings BRANCH_NOT_OWNED)" "1"
assert_file "the legacy worktree is untouched" "$WT6"
assert_ne "the legacy branch is untouched" "$(branch_sha "$REPO6" legacy-branch)" ""
if terminal_listed term-legacy; then ok "and the legacy terminal is untouched"
else bad "and the legacy terminal is untouched"; fi

# ===========================================================================
head1 "7. Closure is durable, and the proof is falsifiable"
# ===========================================================================

# The released terminal from section 5 stays absent across a reconnect: Orca
# rediscovers its session history on every listing, and only the recorded
# durable close intent keeps that tab from coming back.
assert_contains "the release recorded a DURABLE close intent" \
  "$(cat "$STUB_CLOSED")" "term-merged"
if terminal_listed term-merged; then bad "a settled worker's tab does not come back on reconnect"
else ok "a settled worker's tab does not come back on reconnect"; fi

# The control. A terminal closed WITHOUT the durable intent is still there on
# the next listing, so the assertion above is a real proof rather than an
# accident of a stub that forgets everything.
terminal_add term-nondurable IDLE
PATH="$BIN:$PATH" orca terminal close --handle term-nondurable </dev/null >/dev/null 2>&1
if terminal_listed term-nondurable; then
  ok "a non-durable close leaves the tab to come back, so the proof is falsifiable"
else
  bad "a non-durable close leaves the tab to come back, so the proof is falsifiable"
fi

# A terminal Orca is not listing at this instant is the case the durable close
# exists FOR: the daemon restarted, the tab was killed without a close intent,
# or Orca pruned a finished terminal whose provider session it will rediscover
# on the next reconnect. Absence is therefore not proof of release. Settlement
# requests the durable close and re-observes, exactly as it does for an idle
# terminal — because a Dispatch that settles owning nothing can never be
# released by a later pass, and the tab comes back.
new_scenario ghost
if terminal_listed term-ghost; then bad "fixture: term-ghost must not be listed yet"
else ok "Orca is not listing term-ghost, so cleanup cannot observe it"; fi
register "$(descriptor d-ghost TASK-16 term-ghost - - - - - false false false)"
deliver del-ghost d-ghost worker_done done
run_afk monitor --json --cleanup --live
if durable_close_requested term-ghost; then
  ok "an absent terminal still gets the durable close requested for it"
else
  bad "an absent terminal still gets the durable close requested for it" \
      "no durable close intent was recorded for term-ghost"
fi
assert_eq "and only then is it reported released" \
  "$(rec d-ghost '.cleanup.terminal')" "REMOVED"
assert_eq "so the Dispatch settles on a proven release" "$(rec d-ghost '.state')" "SETTLED"
if terminal_listed term-ghost; then
  bad "the durably closed tab does not come back on the next listing"
else
  ok "the durably closed tab does not come back on the next listing"
fi

# The control: the idle path is unchanged by any of this, which is what makes
# the assertion above a difference in the product rather than in the stub.
new_scenario ghost-control
terminal_add term-listed IDLE
register "$(descriptor d-listed TASK-17 term-listed - - - - - false false false)"
deliver del-listed d-listed worker_done done
run_afk monitor --json --cleanup --live
if durable_close_requested term-listed; then
  ok "the idle path requests the durable close exactly as before"
else
  bad "the idle path requests the durable close exactly as before"
fi
assert_eq "and reports the release" "$(rec d-listed '.cleanup.terminal')" "REMOVED"

# Whether Orca will accept a durable close for a handle it is NOT listing is a
# property of the daemon, and this kit does not get to assume it. For an absent
# handle the re-observation afterwards repeats what was already true before the
# request, so the request's own outcome is the only evidence there is: an Orca
# that refuses the close leaves the terminal unproven, not released. Otherwise a
# total failure of the durable-close mechanism converts into a settled Dispatch
# that owns nothing while its tab comes back on the next reconnect.
new_scenario ghost-refused
STUB_CLOSE_FAILS=1
if terminal_listed term-ghost-refused; then bad "fixture: term-ghost-refused must not be listed yet"
else ok "Orca is not listing term-ghost-refused either"; fi
register "$(descriptor d-ghost-refused TASK-18 term-ghost-refused - - - - - false false false)"
deliver del-ghost-refused d-ghost-refused worker_done done
run_afk monitor --json --cleanup --live
if durable_close_requested term-ghost-refused; then
  bad "a refused close records no durable intent" "the ledger recorded one anyway"
else
  ok "a refused close records no durable intent"
fi
assert_eq "so the release is unproven rather than reported REMOVED" \
  "$(rec d-ghost-refused '.cleanup.terminal')" "NEEDS_OWNER"
assert_eq "with the reason that names why" \
  "$(count_findings TERMINAL_RELEASE_UNPROVEN)" "1"
assert_eq "the Dispatch does not settle on it" \
  "$(rec d-ghost-refused '.state')" "COMPLETED"
assert_eq "the terminal is still counted as retained" \
  "$(jget '.dispatch_monitor.retained.terminals')" "1"
assert_eq "and the pass says a human must decide" "$RUN_RC" "2"
STUB_CLOSE_FAILS=0

# The control for that: the same refusal at a status where the re-observation
# DOES carry information. It fails closed there too, which is what shows the
# case above is decided by the close outcome rather than by the stub.
new_scenario idle-refused
STUB_CLOSE_FAILS=2
terminal_add term-idle-refused IDLE
register "$(descriptor d-idle-refused TASK-19 term-idle-refused - - - - - false false false)"
deliver del-idle-refused d-idle-refused worker_done done
run_afk monitor --json --cleanup --live
assert_eq "a listed terminal whose close is refused is unproven too" \
  "$(rec d-idle-refused '.cleanup.terminal')" "NEEDS_OWNER"
assert_eq "and it is still there afterwards" \
  "$(rec d-idle-refused '.state')" "COMPLETED"
if terminal_listed term-idle-refused; then ok "the terminal Orca would not close is still listed"
else bad "the terminal Orca would not close is still listed"; fi
STUB_CLOSE_FAILS=0

# ===========================================================================
head1 "8. The pass's Orca observations are bounded, or they are not made"
# ===========================================================================
#
# The settlement pass reaches Orca twice — the listing, and the durable close —
# and both are external observations of exactly the kind "exactly one bounded
# pass per invocation" is about. A host with no timeout(1) cannot enforce that
# bound, so the observation is REFUSED and reported rather than run unbounded:
# an Orca that accepts the request and then says nothing would otherwise leave
# the coordinator inside the pass that was settling a worker, which is the hang
# this engine exists to remove.
#
# The fixture differs from this host's own PATH in exactly one entry — whether
# timeout(1) is reachable — so the only variable between the case under test and
# its controls is the bound.

REAL_TIMEOUT="$(command -v timeout || true)"
NOBIN="$TMPROOT/nobin"          # every PATH executable EXCEPT timeout
WITHTO="$TMPROOT/withtimeout"   # one entry: timeout
STALLBIN="$TMPROOT/stallbin"    # one entry: an orca that can stall
mkdir -p "$NOBIN" "$WITHTO" "$STALLBIN"

BOUND_FIXTURE=no
if [[ -n "$REAL_TIMEOUT" ]]; then
  IFS=':' read -r -a SB_PATH_DIRS <<< "$PATH"
  for sb_dir in "${SB_PATH_DIRS[@]}"; do
    [[ -n "$sb_dir" && -d "$sb_dir" ]] || continue
    for sb_file in "$sb_dir"/*; do
      [[ -e "$sb_file" ]] || continue
      sb_base="${sb_file##*/}"
      [[ "$sb_base" == "timeout" ]] && continue
      [[ -e "$NOBIN/$sb_base" ]] && continue
      ln -s "$sb_file" "$NOBIN/$sb_base" 2>/dev/null || true
    done
  done
  ln -s "$REAL_TIMEOUT" "$WITHTO/timeout" 2>/dev/null || true
  # The suite's own stub, with one added property: it can accept the request and
  # then say nothing for two minutes. Derived from the same file so the model of
  # durable closure cannot drift between the two.
  { printf '#!/usr/bin/env bash\n'
    printf 'if [[ "${STUB_ORCA_STALL:-0}" == "1" ]]; then sleep 120; fi\n'
    tail -n +2 "$BIN/orca"; } > "$STALLBIN/orca"
  chmod +x "$STALLBIN/orca"
  BOUND_FIXTURE=yes
  if PATH="$NOBIN" command -v timeout >/dev/null 2>&1; then BOUND_FIXTURE=no; fi
  for sb_need in bash jq git find sed grep awk sort head tail date mktemp; do
    PATH="$NOBIN" command -v "$sb_need" >/dev/null 2>&1 || BOUND_FIXTURE=no
  done
fi

P2_OUT=""; P2_RC=0; P2_ELAPSED=0
run_sandboxed() { # <path> <args...> — always under an OUTER bound, so a pass
                  # that does not return fails an assertion instead of hanging
                  # this gate forever
  local p="$1" t0 t1; shift
  t0="$(date +%s)"
  P2_OUT="$("$REAL_TIMEOUT" 45 env PATH="$p" HOME="$HOMEDIR" \
            XDG_STATE_HOME="$HOMEDIR/.local/state" \
            AFK_KIT_ROOT="$CHECKOUT" \
            STUB_TERMS="$STUB_TERMS" STUB_CLOSED="$STUB_CLOSED" \
            STUB_CLOSE_FAILS=0 STUB_ORCA_STALL="${STUB_ORCA_STALL:-0}" \
            "$BASH" "$AFK" "$@" </dev/null 2>/dev/null)"
  P2_RC=$?
  t1="$(date +%s)"
  P2_ELAPSED=$(( t1 - t0 ))
}
p2_findings() { # <reason>
  printf '%s' "$P2_OUT" | jq -r --arg r "$1" '[.findings[] | select(.reason == $r)] | length' 2>/dev/null
}

if [[ "$BOUND_FIXTURE" != "yes" ]]; then
  skip "the Orca bounding cases NOT RUN: this host has no timeout(1), or a PATH sandbox without it could not be built"
else
  # The case under test: no bounding tool, and an Orca that never answers.
  new_scenario orca-unbounded
  terminal_add term-p2-unbounded IDLE
  register "$(descriptor d-p2u TASK-20 term-p2-unbounded - - - - - false false false)"
  deliver del-p2u d-p2u worker_done done
  STUB_ORCA_STALL=1
  run_sandboxed "$STALLBIN:$NOBIN" monitor --json --cleanup --live
  STUB_ORCA_STALL=0
  assert_lt "an unbounded host does not leave the pass inside the call" "$P2_ELAPSED" "30"
  assert_ne "so the outer bound never had to kill it" "$P2_RC" "124"
  assert_eq "the observation is reported as one that could not be bounded" \
    "$(p2_findings PROBE_BOUND_UNAVAILABLE)" "1"
  assert_eq "the terminal is unproven rather than released" \
    "$(rec d-p2u '.cleanup.terminal')" "NEEDS_OWNER"
  assert_eq "with the reason that names why" \
    "$(p2_findings TERMINAL_RELEASE_UNPROVEN)" "1"
  assert_eq "the Dispatch does not settle on an observation nobody made" \
    "$(rec d-p2u '.state')" "COMPLETED"
  assert_eq "and the pass says a human must decide" "$P2_RC" "2"
  if terminal_listed term-p2-unbounded; then
    ok "the terminal was not touched, because the close was never requested"
  else
    bad "the terminal was not touched, because the close was never requested"
  fi

  # Control A: the same stalling Orca WITH timeout(1) on PATH. The bound is
  # enforced, the listing times out, and the disposition is the same fail-closed
  # one — which is what shows the case above is the missing bound rather than
  # the sandbox or the stub.
  new_scenario orca-stalled-bounded
  terminal_add term-p2-stalled IDLE
  register "$(descriptor d-p2s TASK-21 term-p2-stalled - - - - - false false false)"
  deliver del-p2s d-p2s worker_done done
  STUB_ORCA_STALL=1
  run_sandboxed "$STALLBIN:$WITHTO:$NOBIN" monitor --json --cleanup --live
  STUB_ORCA_STALL=0
  assert_lt "a bounded host returns from a stalled Orca too" "$P2_ELAPSED" "30"
  assert_eq "and it reports no missing bound, because it had one" \
    "$(p2_findings PROBE_BOUND_UNAVAILABLE)" "0"
  assert_eq "the timed-out listing still fails closed" \
    "$(rec d-p2s '.cleanup.terminal')" "NEEDS_OWNER"

  # Control B: no bounding tool, but an Orca that answers immediately. The
  # refusal is about the bound, not about the stall.
  new_scenario orca-answering-unbounded
  terminal_add term-p2-answering IDLE
  register "$(descriptor d-p2a TASK-22 term-p2-answering - - - - - false false false)"
  deliver del-p2a d-p2a worker_done done
  run_sandboxed "$STALLBIN:$NOBIN" monitor --json --cleanup --live
  assert_eq "an answering Orca is not observed either, without a bound" \
    "$(rec d-p2a '.cleanup.terminal')" "NEEDS_OWNER"
  assert_eq "and the missing bound is what it says" \
    "$(p2_findings PROBE_BOUND_UNAVAILABLE)" "1"
  if terminal_listed term-p2-answering; then
    ok "the answering Orca's terminal is untouched, because nothing was asked of it"
  else
    bad "the answering Orca's terminal is untouched, because nothing was asked of it"
  fi

  # Control C: bound available and an Orca that answers — the normal
  # dispositions, through the same sandbox, so the three cases above are
  # differences in the bound rather than in the fixture.
  new_scenario orca-answering-bounded
  terminal_add term-p2-normal IDLE
  register "$(descriptor d-p2n TASK-23 term-p2-normal - - - - - false false false)"
  deliver del-p2n d-p2n worker_done done
  run_sandboxed "$STALLBIN:$WITHTO:$NOBIN" monitor --json --cleanup --live
  assert_eq "a bounded observation of an answering Orca releases the terminal" \
    "$(rec d-p2n '.cleanup.terminal')" "REMOVED"
  assert_eq "reports no missing bound" "$(p2_findings PROBE_BOUND_UNAVAILABLE)" "0"
  assert_eq "and settles the Dispatch" "$(rec d-p2n '.state')" "SETTLED"
  if durable_close_requested term-p2-normal; then
    ok "the durable close intent was recorded through the sandbox too"
  else
    bad "the durable close intent was recorded through the sandbox too"
  fi
fi

# ===========================================================================
head1 "9. The monitor never blocks, and never widens the command surface"
# ===========================================================================

new_scenario surface

run_afk monitor --cleanup
assert_eq "cleanup without --live is a usage failure" "$RUN_RC" "1"
assert_contains "and says why it needs one" "$RUN_ERR" "live"
run_afk monitor --reconcile --cleanup --live
assert_eq "two action verbs in one pass is a usage failure" "$RUN_RC" "1"
run_afk monitor --register
assert_eq "--register without its descriptor is a usage failure" "$RUN_RC" "1"
run_afk monitor --stamp /nowhere
assert_eq "monitor does not accept a readiness option" "$RUN_RC" "1"
run_afk status --reconcile
assert_eq "status does not accept a monitor verb" "$RUN_RC" "1"

register "$(descriptor d-surface TASK-13 - - - - - - false false false)"
deliver del-surface d-surface worker_done done
run_afk monitor --json --reconcile
run_afk monitor --json
MON_JSON="$RUN_OUT"
run_afk schema
SCHEMA_JSON="$RUN_OUT"
PUB="$(printf '%s' "$SCHEMA_JSON" | jq -c '.reason_codes')"

unpublished_reasons() { # <document>
  printf '%s' "$1" | jq -r --argjson pub "$PUB" \
    '[.. | objects | .reason? | select(type == "string")
      | . as $r | select(($pub | index($r)) == null)] | length'
}
assert_eq "every reason code in a monitor result is published" \
  "$(unpublished_reasons "$MON_JSON")" "0"
assert_eq "and the sweep still FAILS on an unpublished code" \
  "$(unpublished_reasons "$(printf '%s' "$MON_JSON" \
     | jq -c '.dispatch_monitor.reason = "NOT_A_PUBLISHED_CODE"')")" "1"

DISPATCH_SET="$(printf '%s' "$SCHEMA_JSON" | jq -c '.dispatch_states')"
CLEANUP_SET="$(printf '%s' "$SCHEMA_JSON" | jq -c '.cleanup_dispositions')"
assert_eq "every dispatch state is inside the published set" \
  "$(printf '%s' "$MON_JSON" | jq -r --argjson s "$DISPATCH_SET" \
     '[.dispatch_monitor.dispatches[] | .state | select(type == "string")
       | . as $st | select(($s | index($st)) == null)] | length')" "0"
assert_eq "every cleanup disposition is inside the published set" \
  "$(printf '%s' "$MON_JSON" | jq -r --argjson s "$CLEANUP_SET" \
     '[.dispatch_monitor.dispatches[] | (.cleanup // {}) | to_entries[]
       | .value | select(type == "string")
       | . as $d | select(($s | index($d)) == null)] | length')" "0"

# ===========================================================================
if (( SKIPPED > 0 )); then
  printf '\n\033[33mskipped checks computed no verdict — they are not passes\033[0m\n'
  printf '\033[1m%d passed, %d failed, %d skipped\033[0m\n' "$PASS" "$FAIL" "$SKIPPED"
else
  printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
fi
(( FAIL == 0 )) || exit 1
