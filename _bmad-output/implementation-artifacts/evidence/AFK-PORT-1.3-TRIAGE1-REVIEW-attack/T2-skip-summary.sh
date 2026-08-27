#!/usr/bin/env bash
# T2 — do the counted skips actually reach the aggregator, and do they change
#      what the gate DECIDES?
#
# WHAT THIS ANSWERS
#
# The triage delta gave tests/lifecycle-readiness-tests.sh a counted skip()
# (:53) and a summary that becomes "N passed, M failed, K skipped" (:1265-1270).
# The claim under review is narrow and mechanical: the counts stay on the LAST
# line, so tests/run-tests.sh's `tail -1` aggregation (:1086-1087) carries the
# skip count instead of swallowing it, and the exit semantics
# (`(( FAIL == 0 )) || exit 1`) are unchanged by a skip.
#
# Part A replays the SHIPPED summary block itself — extracted from the real
# file, not a copy — with counts injected, so the format and the exit status are
# checked on the code that ships rather than on a description of it. It does the
# same for the dispatch gate (the precedent the triage round followed) and for
# tests/run-tests.sh, whose own summary prints the two lines in the OPPOSITE
# order. That ordering is register entry R8: harmless today because nothing
# tails run-tests, and a one-line fix if that ever changes.
#
# Part B runs the readiness gate for real on a PATH with no timeout(1), which is
# the reachable host condition that makes it skip, and checks that the summary
# it then prints is the three-count form with a non-zero skip count. The control
# is the same suite on the ordinary PATH.
#
# SAFETY: the extracted block runs in its own bash with counts assigned and
# nothing else; part B runs the readiness gate, which builds its whole world
# under mktemp. Nothing here writes to the checkout.
#
# EXIT: 0 every prediction held
#       1 at least one diverged
#       2 inconclusive (a block could not be extracted, or a suite did not run)

set -uo pipefail

KIT_ROOT="${KIT_ROOT:-$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
READINESS="$KIT_ROOT/tests/lifecycle-readiness-tests.sh"
DISPATCH="$KIT_ROOT/tests/lifecycle-dispatch-tests.sh"
RUNTESTS="$KIT_ROOT/tests/run-tests.sh"
for f in "$READINESS" "$DISPATCH" "$RUNTESTS"; do
  [[ -f "$f" ]] || { echo "INCONCLUSIVE: missing $f"; exit 2; }
done

TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT
say() { printf '%s\n' "$*"; }
strip_ansi() { sed -e $'s/\033\\[[0-9;]*m//g'; }
DIVERGED=0

extract_summary() { # <suite file> — the shipped block, verbatim, from its `if`
  local n
  n="$(grep -n -F -x 'if (( SKIPPED > 0 )); then' "$1" | head -1 | cut -d: -f1)"
  [[ -n "$n" ]] || return 1
  tail -n "+$n" "$1"
}

R_RC=0; R_LAST=""
replay() { # <suite file> <PASS> <FAIL> <SKIPPED>
  local blk="$TMPROOT/block.sh" out
  { printf '#!/usr/bin/env bash\nset -uo pipefail\nPASS=%s\nFAIL=%s\nSKIPPED=%s\n' \
      "$2" "$3" "$4"
    extract_summary "$1"; } > "$blk" || return 1
  out="$(bash "$blk" 2>&1)"; R_RC=$?
  R_LAST="$(tail -1 <<<"$out" | strip_ansi)"   # exactly run-tests.sh's reading
  return 0
}

expect() { # <what> <observed> <predicted>
  if [[ "$2" == "$3" ]]; then
    printf '    ok   %-42s %s\n' "$1" "$2"
  else
    printf '    BAD  %-42s observed %-24s predicted %s\n' "$1" "$2" "$3"
    DIVERGED=$((DIVERGED + 1))
  fi
}

say "== PART A: the shipped summary blocks, replayed =========================="
for pair in "readiness:$READINESS" "dispatch:$DISPATCH" "run-tests:$RUNTESTS"; do
  name="${pair%%:*}"; file="${pair#*:}"
  say ""
  say "  $name ($file)"
  if ! replay "$file" 231 0 1; then
    say "    INCONCLUSIVE: no 'if (( SKIPPED > 0 )); then' block in this file"
    exit 2
  fi
  if [[ "$name" == "run-tests" ]]; then
    # Documented, not asserted: this one prints the counts FIRST, so its own
    # last line is the sentence. R8.
    say "    last line with skips = '$R_LAST'"
    say "    exit                 = $R_RC"
    say "    (recorded for R8 — nothing tails run-tests today, so this is a"
    say "     consistency note rather than a defect)"
    continue
  fi
  expect "last line carries the skip count" "$R_LAST" "231 passed, 0 failed, 1 skipped"
  expect "a skip alone does not fail the gate" "$R_RC" "0"

  replay "$file" 231 0 0
  expect "no skips: the line is unchanged" "$R_LAST" "231 passed, 0 failed"
  expect "and still exits 0" "$R_RC" "0"

  replay "$file" 230 1 1
  expect "a real failure still fails" "$R_RC" "1"
  expect "with the skip count still shown" "$R_LAST" "230 passed, 1 failed, 1 skipped"
done

# ===========================================================================
say ""
say "== PART B: the readiness gate on a host that must skip ==================="
# ===========================================================================
#
# The suite's two skip sites are capability probes: `command -v timeout`
# (:712-725) and the date(1) dialect check (:149-153). Masking timeout(1) from
# PATH reaches the first one, which is the reachable host condition the counter
# exists for. Other assertions in the suite may move under a masked bound — that
# is not what is being measured here; the summary line is.

REAL_TIMEOUT="$(command -v timeout || true)"
if [[ -z "$REAL_TIMEOUT" ]]; then
  say "  INCONCLUSIVE: this host has no timeout(1), so the masked-PATH case"
  say "  cannot be distinguished from the ordinary one."
  exit 2
fi

SANDBOX="$TMPROOT/nobin"; mkdir -p "$SANDBOX"
IFS=':' read -r -a PATH_DIRS <<< "$PATH"
for d in "${PATH_DIRS[@]}"; do
  [[ -n "$d" && -d "$d" ]] || continue
  for f in "$d"/*; do
    [[ -e "$f" ]] || continue
    b="${f##*/}"
    [[ "$b" == "timeout" ]] && continue
    [[ -e "$SANDBOX/$b" ]] && continue
    ln -s "$f" "$SANDBOX/$b" 2>/dev/null || true
  done
done
if PATH="$SANDBOX" command -v timeout >/dev/null 2>&1; then
  say "  INCONCLUSIVE: the sandbox PATH still resolves timeout(1)"; exit 2
fi
for need in bash jq git find sed grep awk wc tr sort head tail cat cp mv date mktemp; do
  PATH="$SANDBOX" command -v "$need" >/dev/null 2>&1 || {
    say "  INCONCLUSIVE: sandbox PATH is missing $need"; exit 2; }
done

say "  control: the ordinary PATH (this is also an honest re-run of the gate)"
CTRL_OUT="$("$REAL_TIMEOUT" 1800 bash "$READINESS" 2>&1 </dev/null)"; CTRL_RC=$?
CTRL_LAST="$(tail -1 <<<"$CTRL_OUT" | strip_ansi)"
say "    exit $CTRL_RC — $CTRL_LAST"

say "  attack: the same suite with timeout(1) masked"
ATK_OUT="$(PATH="$SANDBOX" "$REAL_TIMEOUT" 1800 bash "$READINESS" 2>&1 </dev/null)"; ATK_RC=$?
ATK_LAST="$(tail -1 <<<"$ATK_OUT" | strip_ansi)"
say "    exit $ATK_RC — $ATK_LAST"

if [[ "$CTRL_RC" == "124" || "$ATK_RC" == "124" ]]; then
  say "  INCONCLUSIVE: a run hit the 1800s bound and was killed."; exit 2
fi

SKIPN="$(sed -n 's/^[0-9]* passed, [0-9]* failed, \([0-9]*\) skipped$/\1/p' <<<"$ATK_LAST")"
if [[ -n "$SKIPN" ]] && (( SKIPN >= 1 )); then
  say "    ok   the masked run reports $SKIPN skipped check(s) on its LAST line,"
  say "         which is the line run-tests.sh aggregates"
else
  say "    BAD  the masked run's last line does not carry a skip count: '$ATK_LAST'"
  DIVERGED=$((DIVERGED + 1))
fi
case "$CTRL_LAST" in
  *skipped*)
    say "    note the control run ALSO skipped something — that is the date(1)"
    say "         site, not a fixture problem; the counter is still the thing"
    say "         being measured" ;;
  *"passed,"*)
    say "    ok   the control's summary is the two-count form, so the skip count"
    say "         appears only when something actually skipped" ;;
  *)
    say "    BAD  the control produced no recognizable summary: '$CTRL_LAST'"
    DIVERGED=$((DIVERGED + 1)) ;;
esac

say ""
if (( DIVERGED == 0 )); then
  say "VERDICT: T2 holds. The counted skip reaches the aggregator on the last"
  say "         line, the summary is byte-identical when nothing skips, and a"
  say "         skip changes no verdict — FAIL is still the only thing that"
  say "         fails the gate. What a skip still does NOT do is make"
  say "         run-tests.sh's own skip count move (registered F2, out of scope"
  say "         for this round) — see R8."
  exit 0
fi
say "VERDICT: $DIVERGED check(s) diverged; see the BAD lines above."
exit 1
