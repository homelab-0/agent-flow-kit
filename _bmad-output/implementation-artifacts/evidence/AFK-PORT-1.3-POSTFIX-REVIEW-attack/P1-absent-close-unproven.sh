#!/usr/bin/env bash
# P1 — a durable close that FAILS still reports the terminal RELEASED, because
# for an ABSENT handle the re-observation was already true before the request.
#
# WHAT THIS ATTACKS
#
# The cycle-3 fix (lib/afk-monitor.sh:800-825) puts ABSENT, IDLE and EXITED in
# one arm: request the durable close, reload the listing, report REMOVED if the
# handle is absent afterwards and NEEDS_OWNER if it is not.
#
# For IDLE and EXITED that re-observation is evidence: the handle WAS listed, so
# its disappearance is caused by the close.
#
# For ABSENT it is a tautology. The handle was not listed BEFORE the request, so
# it will not be listed after it whether the close succeeded, failed, or was
# rejected outright. The one observation that could discriminate — the close
# request's own exit status — is discarded at :815 (`|| true`). So an Orca that
# answers `terminal list` but refuses the close records NO durable intent, and
# the pass still reports REMOVED / TERMINAL_RELEASED, marks the Dispatch SETTLED,
# and exits 0. afk_monitor_cleanup_record:1000-1004 returns immediately for a
# SETTLED record, so no later pass can ever revisit it: the tab comes back on the
# next reconnect and owns nothing.
#
# This is the harm B1 named ("a settled worker must not reappear as a resumed
# tab"), reached through the narrower door the fix left open.
#
# REACHABILITY (no exotic state required)
#   - an Orca that errors when asked to close a handle it is not listing — which
#     is exactly the ABSENT case, i.e. the case this arm exists for;
#   - an installed Orca that does not support `--durable` at all: every close
#     then fails, IDLE/EXITED correctly fail closed (still listed on
#     re-observation) and ABSENT alone converts a total failure into a release;
#   - any transient close rejection (permissions, provider-session error) that
#     leaves the daemon healthy enough to answer `terminal list`.
#
# CONTROLS
#   A — the same fixture with a close that SUCCEEDS for an unlisted handle: the
#       ledger records the intent and the tab does NOT come back. Shows the
#       difference is the close outcome, not the fixture.
#   B — a LISTED IDLE handle against a stub whose close ALWAYS fails: the code
#       fails closed on NEEDS_OWNER, because there the re-observation carries
#       information. Isolates ABSENT as the only arm that decides on a tautology.
#
# EXIT: 0 REPRODUCED (blocker stands) · 1 NOT REPRODUCED · 2 inconclusive.

set -uo pipefail

KIT_ROOT="${KIT_ROOT:-$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
AFK="$KIT_ROOT/bin/agent-flow-kit"
[[ -f "$AFK" ]] || { echo "INCONCLUSIVE: no bin/agent-flow-kit under $KIT_ROOT"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "INCONCLUSIVE: jq is required"; exit 2; }

TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT
BIN="$TMPROOT/bin"; CHECKOUT="$TMPROOT/checkout"
mkdir -p "$BIN" "$CHECKOUT"

STUB_TERMS="$TMPROOT/orca-terminals.txt"     # what Orca rediscovers on reconnect
STUB_CLOSED="$TMPROOT/orca-closed.txt"       # durable close intents actually RECORDED
: > "$STUB_TERMS"; : > "$STUB_CLOSED"
export STUB_TERMS STUB_CLOSED

# The stub differs from the gate's stub in exactly one property: whether the
# close request succeeds. Everything else is the gate's own model, including
# "a handle whose durable close was RECORDED is filtered out of every later
# listing" — that is what makes a durable close durable.
#   STUB_CLOSE_FAILS=0  always succeeds            (the gate's stub)
#   STUB_CLOSE_FAILS=1  fails for an UNLISTED handle (Orca: no such terminal)
#   STUB_CLOSE_FAILS=2  always fails                 (Orca without --durable)
cat > "$BIN/orca" <<'STUB'
#!/usr/bin/env bash
is_listed() {
  local h s
  while read -r h s; do
    [[ -n "$h" ]] || continue
    grep -q -x -F -- "$h" "$STUB_CLOSED" 2>/dev/null && continue
    [[ "$h" == "$1" ]] && return 0
  done < "$STUB_TERMS"
  return 1
}
case "${1:-} ${2:-}" in
  "terminal list")
    first=1
    printf '{"terminals":['
    while read -r h s; do
      [[ -n "$h" ]] || continue
      grep -q -x -F -- "$h" "$STUB_CLOSED" 2>/dev/null && continue
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

HOMEDIR=""; STATE=""; WATCH=""; INBOX=""
new_scenario() {
  HOMEDIR="$TMPROOT/sc-$1/home"
  STATE="$HOMEDIR/.local/state/agent-flow-kit"
  WATCH="$STATE/dispatch/watch"; INBOX="$STATE/dispatch/inbox"
  mkdir -p "$HOMEDIR"
}
RUN_OUT=""; RUN_RC=0
run_afk() {
  RUN_OUT="$(env PATH="$BIN:$PATH" HOME="$HOMEDIR" \
             XDG_STATE_HOME="$HOMEDIR/.local/state" \
             AFK_KIT_ROOT="$CHECKOUT" \
             STUB_TERMS="$STUB_TERMS" STUB_CLOSED="$STUB_CLOSED" \
             STUB_CLOSE_FAILS="${STUB_CLOSE_FAILS:-0}" \
             bash "$AFK" "$@" </dev/null 2>/dev/null)"
  RUN_RC=$?
}
jget() { printf '%s' "$RUN_OUT" | jq -r "$1" 2>/dev/null; }
rec()  { jq -r "$2" "$WATCH/$1.json" 2>/dev/null; }
register() { printf '%s' "$1" > "$TMPROOT/descriptor.json"; run_afk monitor --json --register "$TMPROOT/descriptor.json"; }
deliver()  {
  mkdir -p "$INBOX"
  jq -nc --arg d "$1" --arg t "$2" \
    '{schema_version:"1.0", delivery_id:$d, dispatch_id:$t, kind:"worker_done",
      result:{status:"done", summary:"one bounded worker result"}}' > "$INBOX/$1.json"
}
descriptor() { # <id> <task> <terminal handle>
  jq -nc --arg id "$1" --arg task "$2" --arg term "$3" \
    '{dispatch_id:$id, task_id:$task,
      terminal:{handle:$term, owned:true},
      worktree:{path:"", owned:true},
      branch:{name:"", repo:"", base:"", remote:"", owned:true,
              disposable:false, pr_merged:false, remote_delete_authorized:false}}'
}
is_listed() { # <handle>
  env PATH="$BIN:$PATH" STUB_TERMS="$STUB_TERMS" STUB_CLOSED="$STUB_CLOSED" \
    orca terminal list --json </dev/null 2>/dev/null \
    | jq -e --arg h "$1" '[.terminals[] | select(.handle == $h)] | length > 0' >/dev/null 2>&1
}
say() { printf '%s\n' "$*"; }

# ===========================================================================
say "== ATTACK: ABSENT handle, durable close REFUSED by Orca =================="
# ===========================================================================
export STUB_CLOSE_FAILS=1
new_scenario ghost-fail
# term-ghost is a session Orca is not listing right now but WILL rediscover.
register "$(descriptor d-ghost TASK-P1 term-ghost)"
[[ "$RUN_RC" == "0" ]] || { say "INCONCLUSIVE: register failed rc=$RUN_RC"; exit 2; }
deliver del-ghost d-ghost
run_afk monitor --json --cleanup --live
A_RC="$RUN_RC"
A_TERM="$(rec d-ghost '.cleanup.terminal')"
A_STATE="$(rec d-ghost '.state')"
A_RETAINED="$(jget '.dispatch_monitor.retained.terminals')"
A_LEDGER=no; grep -q -x -F -- term-ghost "$STUB_CLOSED" 2>/dev/null && A_LEDGER=yes

say "  cleanup.terminal            = $A_TERM      (predicted: REMOVED)"
say "  record state                = $A_STATE     (predicted: SETTLED)"
say "  exit code                   = $A_RC        (predicted: 0)"
say "  retained.terminals          = $A_RETAINED  (predicted: 0)"
say "  durable intent RECORDED?    = $A_LEDGER    (predicted: no — the close was refused)"

# The reconnect. Orca comes back and rediscovers the session it had pruned.
printf 'term-ghost IDLE\n' >> "$STUB_TERMS"
BACK=no; is_listed term-ghost && BACK=yes
say "  tab present after reconnect = $BACK        (predicted: yes)"

# And nothing can be done about it any more: a SETTLED Dispatch owns nothing.
run_afk monitor --json --cleanup --live
A2_RC="$RUN_RC"; A2_RETAINED="$(jget '.dispatch_monitor.retained.terminals')"
say "  second cleanup pass: exit=$A2_RC retained.terminals=$A2_RETAINED (predicted: 0 and 0)"

REPRODUCED=0
if [[ "$A_TERM" == "REMOVED" && "$A_STATE" == "SETTLED" && "$A_LEDGER" == "no" && "$BACK" == "yes" ]]; then
  REPRODUCED=1
fi

# ===========================================================================
say ""
say "== CONTROL A: identical fixture, the close SUCCEEDS ======================"
# ===========================================================================
export STUB_CLOSE_FAILS=0
new_scenario ghost-ok
register "$(descriptor d-ok TASK-P1B term-ok)"
deliver del-ok d-ok
run_afk monitor --json --cleanup --live
C1_TERM="$(rec d-ok '.cleanup.terminal')"
C1_LEDGER=no; grep -q -x -F -- term-ok "$STUB_CLOSED" 2>/dev/null && C1_LEDGER=yes
printf 'term-ok IDLE\n' >> "$STUB_TERMS"
C1_BACK=no; is_listed term-ok && C1_BACK=yes
say "  cleanup.terminal            = $C1_TERM   (predicted: REMOVED)"
say "  durable intent RECORDED?    = $C1_LEDGER (predicted: yes)"
say "  tab present after reconnect = $C1_BACK   (predicted: no — it was durably closed)"
CONTROL_A_OK=0
[[ "$C1_TERM" == "REMOVED" && "$C1_LEDGER" == "yes" && "$C1_BACK" == "no" ]] && CONTROL_A_OK=1

# ===========================================================================
say ""
say "== CONTROL B: a LISTED IDLE handle, close ALWAYS fails ==================="
# ===========================================================================
# The same failure, at a status where the re-observation carries information.
# The code fails closed here — which is what makes the ABSENT arm's REMOVED a
# property of the tautology rather than of the close.
export STUB_CLOSE_FAILS=2
new_scenario idle-fail
printf 'term-idle IDLE\n' >> "$STUB_TERMS"
register "$(descriptor d-idle TASK-P1C term-idle)"
deliver del-idle d-idle
run_afk monitor --json --cleanup --live
C2_RC="$RUN_RC"
C2_TERM="$(rec d-idle '.cleanup.terminal')"
C2_STATE="$(rec d-idle '.state')"
say "  cleanup.terminal = $C2_TERM   (predicted: NEEDS_OWNER)"
say "  record state     = $C2_STATE  (predicted: COMPLETED — not settled)"
say "  exit code        = $C2_RC     (predicted: 2)"
CONTROL_B_OK=0
[[ "$C2_TERM" == "NEEDS_OWNER" && "$C2_STATE" == "COMPLETED" ]] && CONTROL_B_OK=1

# ===========================================================================
say ""
if (( CONTROL_A_OK == 0 )); then
  say "VERDICT: INCONCLUSIVE — control A did not behave as predicted, so the"
  say "         fixture cannot support a claim either way."
  exit 2
fi
if (( REPRODUCED == 1 )); then
  say "VERDICT: REPRODUCED — a refused durable close on an ABSENT handle is"
  say "         reported REMOVED / TERMINAL_RELEASED, the Dispatch is SETTLED and"
  say "         unreachable by any later pass, and the tab returns on reconnect."
  if (( CONTROL_B_OK == 1 )); then
    say "         Control B holds: the same refusal at IDLE fails closed, so the"
    say "         difference is the tautological re-observation, not the stub."
  else
    say "         NOTE: control B did not hold — read the finding with that caveat."
  fi
  exit 0
fi
say "VERDICT: NOT REPRODUCED — the release verdict was not decided by an"
say "         observation that predated the request."
exit 1
