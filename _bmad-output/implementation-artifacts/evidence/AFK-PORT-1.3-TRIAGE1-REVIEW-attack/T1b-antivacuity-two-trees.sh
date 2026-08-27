#!/usr/bin/env bash
# T1b — does the new regression actually discriminate, and what else changed?
#
# WHAT THIS ANSWERS
#
# The triage record claims (AFK-PORT-1.3.md:271-278) that on the pre-triage tree
# two decisive assertions of the `heartbeat-window` scenario FAIL, while the
# `heartbeat-window-legacy` control passes on both trees by construction. That
# claim was never executed: the worker that wrote it had no shell, and neither
# did the reviewer that registered it. This runs it.
#
# It builds two trees from the repository itself:
#   POST = 7d126fc, the triage tree, unmodified
#   PRE  = 7d126fc with lib/afk-monitor.sh replaced by the cfcf9b5 version
# so the ONLY difference between them is the product change under review. The
# test file is the new one in both, which is exactly the anti-vacuity question:
# does the new test fail against the old product?
#
# Part C then shows the one behaviour difference the record does not name: a
# descriptor that declares `heartbeat_seconds: 0`. Pre-triage, the first
# heartbeat installed the process default and the Dispatch became expirable.
# Post-triage the refresh agrees with registration and the deadline stays 0, so
# `WORKER_HEARTBEAT_EXPIRED` can never fire for it (the sweep's `deadline > 0`
# gate, lib/afk-monitor.sh:772-773). That is register entry R1 — non-blocking:
# no descriptor the kit writes sets the field at all.
#
# SAFETY: `git archive` into mktemp — no worktree is added, no branch, no stash,
# no index touched, the checkout is only READ. Both suites run against their own
# extracted tree with their own HOME.
#
# EXIT: 0 the record's anti-vacuity claim is CONFIRMED
#       1 NOT CONFIRMED (the new scenario passes against the old product too)
#       2 inconclusive (a tree could not be built, or a suite did not run)

set -uo pipefail

KIT_ROOT="${KIT_ROOT:-$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
PRE_REV="${PRE_REV:-cfcf9b5}"
POST_REV="${POST_REV:-7d126fc}"

command -v jq  >/dev/null 2>&1 || { echo "INCONCLUSIVE: jq is required"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "INCONCLUSIVE: git is required"; exit 2; }
git -C "$KIT_ROOT" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "INCONCLUSIVE: $KIT_ROOT is not a git checkout"; exit 2; }
for r in "$PRE_REV" "$POST_REV"; do
  git -C "$KIT_ROOT" rev-parse --verify --quiet "$r^{commit}" >/dev/null || {
    echo "INCONCLUSIVE: revision $r is not in this repository"; exit 2; }
done

TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT
PRE="$TMPROOT/pre"; POST="$TMPROOT/post"
mkdir -p "$PRE" "$POST"
say() { printf '%s\n' "$*"; }
strip_ansi() { sed -e $'s/\033\\[[0-9;]*m//g'; }

git -C "$KIT_ROOT" archive "$POST_REV" | tar -x -C "$POST" || {
  echo "INCONCLUSIVE: could not extract $POST_REV"; exit 2; }
git -C "$KIT_ROOT" archive "$POST_REV" | tar -x -C "$PRE" || {
  echo "INCONCLUSIVE: could not extract $POST_REV twice"; exit 2; }
git -C "$KIT_ROOT" show "$PRE_REV:lib/afk-monitor.sh" > "$PRE/lib/afk-monitor.sh" || {
  echo "INCONCLUSIVE: could not read lib/afk-monitor.sh at $PRE_REV"; exit 2; }
if cmp -s "$PRE/lib/afk-monitor.sh" "$POST/lib/afk-monitor.sh"; then
  say "INCONCLUSIVE: lib/afk-monitor.sh is identical at $PRE_REV and $POST_REV,"
  say "              so there is no product change to discriminate on."
  exit 2
fi
for t in "$PRE" "$POST"; do
  [[ -x "$t/bin/agent-flow-kit" ]] || chmod +x "$t/bin/agent-flow-kit" 2>/dev/null
  [[ -f "$t/tests/lifecycle-dispatch-tests.sh" ]] || {
    echo "INCONCLUSIVE: no dispatch gate in the extracted tree"; exit 2; }
done

BOUND=()
if command -v timeout >/dev/null 2>&1; then BOUND=(timeout 1800); fi

SUITE_RC=0
run_suite() { # <tree> -> output on stdout, exit status in SUITE_RC
  local out
  out="$(${BOUND[0]:+"${BOUND[@]}"} bash "$1/tests/lifecycle-dispatch-tests.sh" 2>&1 </dev/null)"
  SUITE_RC=$?
  printf '%s' "$out" | strip_ansi
}

say "== running the dispatch gate on the PRE tree ($PRE_REV lib + new tests) ==="
PRE_OUT="$(run_suite "$PRE")"; PRE_RC=$SUITE_RC
PRE_SUMMARY="$(printf '%s\n' "$PRE_OUT" | tail -1)"
say "  exit $PRE_RC — $PRE_SUMMARY"
say ""
say "== running the dispatch gate on the POST tree ($POST_REV, unmodified) ====="
POST_OUT="$(run_suite "$POST")"; POST_RC=$SUITE_RC
POST_SUMMARY="$(printf '%s\n' "$POST_OUT" | tail -1)"
say "  exit $POST_RC — $POST_SUMMARY"
say ""

if [[ -z "$PRE_SUMMARY" || -z "$POST_SUMMARY" ]]; then
  say "INCONCLUSIVE: a suite produced no summary line at all — it did not run."
  exit 2
fi

verdict_of() { # <output> <assertion label>
  if printf '%s\n' "$1" | grep -qxF "  PASS $2"; then printf 'PASS'
  elif printf '%s\n' "$1" | grep -qxF "  FAIL $2"; then printf 'FAIL'
  else printf 'ABSENT'; fi
}

# label | expected on PRE | expected on POST
ASSERTIONS=(
  "the declared window is persisted on the watch record|FAIL|PASS"
  "a heartbeat refreshes the deadline with the DECLARED window|FAIL|PASS"
  "never with the process default|FAIL|PASS"
  "and the first deadline is one window away|PASS|PASS"
  "a record with no stored window still refreshes with the default|PASS|PASS"
  "and it is still watched, not degraded|PASS|PASS"
  "an expired heartbeat degrades the watch|PASS|PASS"
  "with a monitoring fault, not an outcome|PASS|PASS"
)

printf '  %-58s %-14s %s\n' "assertion" "PRE (expected)" "POST (expected)"
BAD=0
for spec in "${ASSERTIONS[@]}"; do
  IFS='|' read -r label want_pre want_post <<< "$spec"
  got_pre="$(verdict_of "$PRE_OUT" "$label")"
  got_post="$(verdict_of "$POST_OUT" "$label")"
  mark=" "
  if [[ "$got_pre" != "$want_pre" || "$got_post" != "$want_post" ]]; then
    mark="<"; BAD=$((BAD + 1))
  fi
  printf ' %s%-58s %-14s %s\n' "$mark" "${label:0:58}" \
    "$got_pre ($want_pre)" "$got_post ($want_post)"
done
say ""

# ===========================================================================
say "== PART C: a declared window of 0, on both trees =========================="
# ===========================================================================
zero_case() { # <tree> -> "<persisted> <deadline after the heartbeat> <state>"
  local tree="$1" home="$TMPROOT/zero-$(basename "$tree")"
  local watch="$home/.local/state/agent-flow-kit/dispatch/watch"
  local inbox="$home/.local/state/agent-flow-kit/dispatch/inbox"
  mkdir -p "$home"
  jq -nc '{schema_version:"1.0",dispatch_id:"d-zero",task_id:"TASK",
           terminal:{handle:"",owned:false},heartbeat_seconds:0}' > "$home/desc.json"
  env HOME="$home" XDG_STATE_HOME="$home/.local/state" AFK_KIT_ROOT="$tree" \
      bash "$tree/bin/agent-flow-kit" monitor --json --register "$home/desc.json" \
      >/dev/null 2>&1 </dev/null
  [[ -f "$watch/d-zero.json" ]] || { printf 'NO-RECORD - -'; return; }
  mkdir -p "$inbox"
  jq -nc '{schema_version:"1.0",delivery_id:"hb-z",dispatch_id:"d-zero",kind:"heartbeat"}' \
    > "$inbox/hb-z.json"
  env HOME="$home" XDG_STATE_HOME="$home/.local/state" AFK_KIT_ROOT="$tree" \
      bash "$tree/bin/agent-flow-kit" monitor --json --reconcile \
      >/dev/null 2>&1 </dev/null
  printf '%s %s %s' \
    "$(jq -r '.heartbeat_seconds // "ABSENT"' "$watch/d-zero.json")" \
    "$(jq -r '.heartbeat_deadline_epoch // "?"' "$watch/d-zero.json")" \
    "$(jq -r '.state // "?"' "$watch/d-zero.json")"
}
read -r ZP_PERSIST ZP_DEADLINE ZP_STATE <<< "$(zero_case "$PRE")"
read -r ZO_PERSIST ZO_DEADLINE ZO_STATE <<< "$(zero_case "$POST")"
say "  PRE : persisted=$ZP_PERSIST deadline_after_heartbeat=$ZP_DEADLINE state=$ZP_STATE"
say "  POST: persisted=$ZO_PERSIST deadline_after_heartbeat=$ZO_DEADLINE state=$ZO_STATE"
if [[ "$ZP_DEADLINE" != "0" && "$ZP_DEADLINE" != "-" && "$ZO_DEADLINE" == "0" ]]; then
  say "  R1 CONFIRMED — pre-triage, a declared 0 acquired a real deadline on the"
  say "  first heartbeat and could expire; post-triage it never can. Reachable"
  say "  only through a hand-written descriptor: nothing in the kit sets the"
  say "  field (grep heartbeat_seconds over lib/, bin/, files/ finds no producer)."
else
  say "  R1 NOT CONFIRMED as described — the two trees agree on the 0 case."
fi

say ""
if (( BAD == 0 )); then
  say "VERDICT: CONFIRMED — every assertion landed where the record says it"
  say "         does. The new scenario discriminates against the old product,"
  say "         the legacy control passes on both trees (so it is a control and"
  say "         not a second copy of the same assertion), and the pre-existing"
  say "         expiry scenario is unaffected by the delta."
  exit 0
fi
say "VERDICT: NOT CONFIRMED as recorded — $BAD assertion(s) marked '<' above did"
say "         not land where the triage record claims. If the three decisive"
say "         ones passed on PRE, the regression is vacuous and the record's"
say "         anti-vacuity paragraph is wrong; if one is ABSENT, the label was"
say "         renamed and this script needs updating, not the product."
exit 1
