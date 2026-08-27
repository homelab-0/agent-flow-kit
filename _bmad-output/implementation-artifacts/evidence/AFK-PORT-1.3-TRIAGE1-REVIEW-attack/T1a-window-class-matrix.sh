#!/usr/bin/env bash
# T1a — the persisted heartbeat window as a CLASS, not as the shipped instance.
#
# WHAT THIS ANSWERS
#
# The triage delta persists the resolved window on the watch record
# (lib/afk-monitor.sh:522-528, :546-547) and refreshes the deadline from it
# (:654-661). The shipped regression covers exactly two points of that class:
# a declared window of 3x the default, and a legacy record carrying none.
# This walks the rest of the input class through the REAL cli and prints what
# each shape persists and what the next heartbeat then writes.
#
# Part A: the descriptor's .heartbeat_seconds, one case per shape.
# Part B: the process default AFK_MONITOR_HEARTBEAT_SECONDS itself, which is a
#         DOCUMENTED operator knob (bin/agent-flow-kit:255), is normalized at
#         registration (:523-528), and is passed to jq unvalidated at the
#         refresh (:656) — where it is only a fallback that a record carrying
#         its own window does not need.
#
# NOTHING HERE IS A BLOCKER CLAIM. It is the evidence table behind register
# entries R1, R2 and R3 of evidence/AFK-PORT-1.3-TRIAGE1-REVIEW.md, written by a
# reviewer with no shell. The predictions are that reviewer's reading of the
# source; a divergence means the reading was wrong and the register entry has to
# be amended, not that the product regressed.
#
# SAFETY: an isolated HOME and XDG_STATE_HOME under mktemp; a stub `orca` that
# is never reached (no --live anywhere in this script); AFK_KIT_ROOT points at
# the real checkout and is only READ. No network, no provider, no git writes.
#
# EXIT: 0 every prediction held
#       1 at least one case diverged (read the table — it is the answer)
#       2 the fixture could not be built

set -uo pipefail

KIT_ROOT="${KIT_ROOT:-$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
AFK="$KIT_ROOT/bin/agent-flow-kit"
[[ -f "$AFK" ]] || { echo "INCONCLUSIVE: no bin/agent-flow-kit under $KIT_ROOT"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "INCONCLUSIVE: jq is required"; exit 2; }

TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT
BIN="$TMPROOT/bin"; mkdir -p "$BIN"
# Present but unreachable: every run below is offline (no --live), so the
# monitor never lists terminals. It exists so a PATH lookup cannot be the
# variable that explains a result.
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/orca"; chmod +x "$BIN/orca"

DEFAULT_HB=1800   # lib/afk-monitor.sh:108
HB_ENV=""         # empty is equivalent to unset for ${VAR:-1800}

RUN_OUT=""; RUN_RC=0
run_afk() { # <args...>
  RUN_OUT="$(env PATH="$BIN:$PATH" HOME="$HOMEDIR" \
             XDG_STATE_HOME="$HOMEDIR/.local/state" \
             AFK_KIT_ROOT="$KIT_ROOT" \
             AFK_MONITOR_HEARTBEAT_SECONDS="$HB_ENV" \
             bash "$AFK" "$@" </dev/null 2>"$TMPROOT/stderr")"
  RUN_RC=$?
}
say() { printf '%s\n' "$*"; }

HOMEDIR=""; WATCH=""; INBOX=""
O_REG_RC=""; O_PERSISTED=""; O_FIRST=""; O_REFRESH_RC=""; O_REFRESH=""; O_STATE=""

# A deadline of 0 is the product's "no deadline" encoding (:547, :660), and the
# sweep's `deadline > 0` gate (:772-773) is what makes it one. Reporting it as a
# delta would hide it behind an arbitrary negative number, so it gets a name.
delta_of() { # <record path> <epoch field>
  local d
  d="$(jq -r '.heartbeat_deadline_epoch // 0' "$1" 2>/dev/null)"
  if [[ "$d" == "0" ]]; then printf 'NO-DEADLINE'; return; fi
  jq -r --arg f "$2" '.heartbeat_deadline_epoch - (.[$f] // 0)' "$1" 2>/dev/null
}

observe() { # <case name> <jq literal for .heartbeat_seconds, or "-" to omit>
  local name="$1" hb="$2" desc rec
  HOMEDIR="$TMPROOT/case-$name/home"
  WATCH="$HOMEDIR/.local/state/agent-flow-kit/dispatch/watch"
  INBOX="$HOMEDIR/.local/state/agent-flow-kit/dispatch/inbox"
  mkdir -p "$HOMEDIR"
  desc="$TMPROOT/case-$name/desc.json"
  if [[ "$hb" == "-" ]]; then
    jq -nc --arg id "d-$name" \
      '{schema_version:"1.0",dispatch_id:$id,task_id:"TASK",
        terminal:{handle:"",owned:false}}' > "$desc" 2>/dev/null
  else
    jq -nc --arg id "d-$name" --argjson hb "$hb" \
      '{schema_version:"1.0",dispatch_id:$id,task_id:"TASK",
        terminal:{handle:"",owned:false},heartbeat_seconds:$hb}' > "$desc" 2>/dev/null
  fi
  if [[ ! -s "$desc" ]]; then
    O_REG_RC="DESC-UNBUILDABLE"; O_PERSISTED="-"; O_FIRST="-"
    O_REFRESH_RC="-"; O_REFRESH="-"; O_STATE="-"; return
  fi

  run_afk monitor --json --register "$desc"
  O_REG_RC="$RUN_RC"
  rec="$WATCH/d-$name.json"
  if [[ ! -f "$rec" ]]; then
    O_PERSISTED="NO-RECORD"; O_FIRST="NO-RECORD"
    O_REFRESH_RC="-"; O_REFRESH="-"; O_STATE="-"
    return
  fi
  O_PERSISTED="$(jq -r '.heartbeat_seconds // "ABSENT"' "$rec" 2>/dev/null)"
  O_FIRST="$(delta_of "$rec" created_epoch)"

  mkdir -p "$INBOX"
  jq -nc --arg t "d-$name" \
    '{schema_version:"1.0",delivery_id:"hb-1",dispatch_id:$t,kind:"heartbeat"}' \
    > "$INBOX/hb-1.json"
  run_afk monitor --json --reconcile
  O_REFRESH_RC="$RUN_RC"
  O_REFRESH="$(delta_of "$rec" last_heartbeat_epoch)"
  O_STATE="$(jq -r '.state // "?"' "$rec" 2>/dev/null)"
}

DIVERGED=0
row() { printf '  %-14s %-13s %-13s %-13s %-8s %s\n' "$@"; }
check() { # <expected persisted> <expected first> <expected refresh>
  local got="$O_PERSISTED|$O_FIRST|$O_REFRESH" want="$1|$2|$3"
  if [[ "$1" == "EITHER" ]]; then
    say "        no prediction — this one is whatever jq's number printing does"
    say "        with it; recorded, not asserted"
    return
  fi
  if [[ "$got" == "$want" ]]; then
    say "        prediction HELD ($want)"
  else
    say "        DIVERGES — predicted '$want', observed '$got'"
    DIVERGED=$((DIVERGED + 1))
  fi
}

say "== PART A: the descriptor's declared window ==============================="
say ""
row "case" "persisted" "first" "after hb" "reg rc" "state"
say ""

# The two the shipped gate already pins. If either of these diverges the
# fixture is wrong, not the product — the whole run is then inconclusive.
observe absent -
row "absent" "$O_PERSISTED" "$O_FIRST" "$O_REFRESH" "$O_REG_RC" "$O_STATE"
check "$DEFAULT_HB" "$DEFAULT_HB" "$DEFAULT_HB"
CONTROL_A=$DIVERGED

observe declared 5400
row "5400" "$O_PERSISTED" "$O_FIRST" "$O_REFRESH" "$O_REG_RC" "$O_STATE"
check "5400" "5400" "5400"
CONTROL_B=$((DIVERGED - CONTROL_A))

# R1. Registration's reading of 0 has always been "no deadline" (:547). The
# delta made the REFRESH agree with it, so a Dispatch that declares 0 now never
# acquires a deadline at all. Before the delta the first heartbeat installed the
# process default. T1b part C shows that difference on the two trees.
observe zero 0
row "0" "$O_PERSISTED" "$O_FIRST" "$O_REFRESH" "$O_REG_RC" "$O_STATE"
check "0" "NO-DEADLINE" "NO-DEADLINE"

# The shell guard at :523-525 is what keeps these three off the record.
observe negative -30
row "-30" "$O_PERSISTED" "$O_FIRST" "$O_REFRESH" "$O_REG_RC" "$O_STATE"
check "$DEFAULT_HB" "$DEFAULT_HB" "$DEFAULT_HB"

observe fractional 1.5
row "1.5" "$O_PERSISTED" "$O_FIRST" "$O_REFRESH" "$O_REG_RC" "$O_STATE"
check "$DEFAULT_HB" "$DEFAULT_HB" "$DEFAULT_HB"

observe numeric-string '"1800"'
row '"1800"' "$O_PERSISTED" "$O_FIRST" "$O_REFRESH" "$O_REG_RC" "$O_STATE"
check "1800" "1800" "1800"

# R3. Digits-only for the shell guard, not a JSON number for --argjson, so the
# record is built by a jq that never ran. Predicted loud (no record written) —
# with a finding that names the watch DIRECTORY rather than the descriptor.
observe leading-zero '"0800"'
row '"0800"' "$O_PERSISTED" "$O_FIRST" "$O_REFRESH" "$O_REG_RC" "$O_STATE"
check "NO-RECORD" "NO-RECORD" "-"

# Digits in, but far enough out that jq may print the sum in exponent form —
# which the sweep's digits-only guard (:772) reads as 0, i.e. no deadline. The
# practical meaning of a 3-billion-year window is the same either way.
observe huge 1000000000000000000000000000000
row "1e30" "$O_PERSISTED" "$O_FIRST" "$O_REFRESH" "$O_REG_RC" "$O_STATE"
check EITHER - -

say ""
say "== PART B: the process default, which is an operator knob ================="
say ""
say "  AFK_MONITOR_HEARTBEAT_SECONDS is declared in the cli's Environment"
say "  section (bin/agent-flow-kit:255). Registration normalizes a malformed"
say "  value to 1800 (:526-528). The refresh passes the same variable straight"
say "  into jq (--argjson default_hb, :656) — which is parsed BEFORE the program"
say "  runs, so it breaks the refresh for every record, including ones that"
say "  carry their own window and never consult the fallback."
say ""

# Control: a well-formed non-default global. Both halves must agree on it.
HB_ENV=600
observe env-good -
row "env=600" "$O_PERSISTED" "$O_FIRST" "$O_REFRESH" "$O_REG_RC" "$O_STATE"
check "600" "600" "600"

# The attack: a plausible operator typo (units).
HB_ENV="30m"
observe env-units -
row "env=30m" "$O_PERSISTED" "$O_FIRST" "$O_REFRESH" "$O_REG_RC" "$O_STATE"
INBOX_LEFT="$(find "$INBOX" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
say "        predicted: registration normalizes to 1800 and succeeds, and the"
say "        refresh fails loudly instead of using it"
say "        persisted = $O_PERSISTED (predicted 1800)"
say "        heartbeat left in the inbox = $INBOX_LEFT (predicted 1: recoverable)"
say "        reconcile exit = $O_REFRESH_RC (predicted 2: owner action)"
if [[ "$O_PERSISTED" == "1800" && "$INBOX_LEFT" == "1" && "$O_REFRESH_RC" == "2" ]]; then
  say "        prediction HELD — the asymmetry is real, and it fails LOUD, which"
  say "        is why R2 is registered rather than raised as a blocker."
else
  say "        DIVERGES — observed persisted=$O_PERSISTED inbox=$INBOX_LEFT rc=$O_REFRESH_RC"
  DIVERGED=$((DIVERGED + 1))
fi
HB_ENV=""

# A record that carries its own window is not spared. Note the DELTA cannot
# discriminate here: registration wrote the deadline and last_heartbeat_epoch
# from one clock reading, so an un-refreshed record shows the same 5400 a
# successful refresh would. The inbox and the exit code are the discriminators.
HOMEDIR="$TMPROOT/case-env-own/home"
WATCH="$HOMEDIR/.local/state/agent-flow-kit/dispatch/watch"
INBOX="$HOMEDIR/.local/state/agent-flow-kit/dispatch/inbox"
mkdir -p "$HOMEDIR"
jq -nc '{schema_version:"1.0",dispatch_id:"d-own",task_id:"TASK",
         terminal:{handle:"",owned:false},heartbeat_seconds:5400}' \
  > "$TMPROOT/own-desc.json"
run_afk monitor --json --register "$TMPROOT/own-desc.json"
OWN_BEFORE="$(jq -r '.last_heartbeat_epoch // 0' "$WATCH/d-own.json" 2>/dev/null)"
mkdir -p "$INBOX"
jq -nc '{schema_version:"1.0",delivery_id:"hb-own",dispatch_id:"d-own",kind:"heartbeat"}' \
  > "$INBOX/hb-own.json"
sleep 1
HB_ENV="30m"
run_afk monitor --json --reconcile
OWN_RC="$RUN_RC"
HB_ENV=""
OWN_AFTER="$(jq -r '.last_heartbeat_epoch // 0' "$WATCH/d-own.json" 2>/dev/null)"
OWN_LEFT="$(find "$INBOX" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
say ""
say "  a record with its OWN window, refreshed under the malformed global:"
say "        last_heartbeat_epoch $OWN_BEFORE -> $OWN_AFTER (predicted: unchanged)"
say "        heartbeat left in the inbox = $OWN_LEFT (predicted 1)"
say "        exit = $OWN_RC (predicted 2)"
if [[ "$OWN_LEFT" == "1" && "$OWN_RC" == "2" && "$OWN_BEFORE" == "$OWN_AFTER" ]]; then
  say "        prediction HELD — the fallback argument is evaluated whether or"
  say "        not the fallback is used. One line of reuse from :523-528 closes"
  say "        it, and until then a misconfigured global stops the refresh for"
  say "        records that declared their own window."
else
  say "        DIVERGES — observed inbox=$OWN_LEFT rc=$OWN_RC epoch=$OWN_BEFORE/$OWN_AFTER"
  DIVERGED=$((DIVERGED + 1))
fi

say ""
if (( CONTROL_A > 0 || CONTROL_B > 0 )); then
  say "VERDICT: INCONCLUSIVE — one of the two cases the shipped gate already"
  say "         pins (absent, 5400) did not behave as the gate asserts, so this"
  say "         fixture cannot support a claim about the rest of the class."
  exit 2
fi
if (( DIVERGED == 0 )); then
  say "VERDICT: every prediction held. R1, R2 and R3 stand as written in"
  say "         evidence/AFK-PORT-1.3-TRIAGE1-REVIEW.md — all three non-blocking."
  exit 0
fi
say "VERDICT: $DIVERGED case(s) diverged from the reviewer's reading. The table"
say "         above is the answer; amend the affected register entry."
exit 1
