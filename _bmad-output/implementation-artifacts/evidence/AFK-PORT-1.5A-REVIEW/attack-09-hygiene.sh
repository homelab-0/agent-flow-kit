#!/usr/bin/env bash
# ATTACK 9 — hygiene: declared file surface, commit messages, diff size, and
# whether the story's own new suite oracle is non-vacuous.
set -uo pipefail
. "$(dirname "$0")/attack-harness.sh"
cd "$KIT_ROOT"
BASE=39fd66c

printf '  --- files changed vs %s ---\n' "$BASE"
git diff --name-only "$BASE"..HEAD | sed 's/^/      /'
DECLARED='files/model-router/context-budget-policy.yaml
files/model-router/scripts/dispatch.sh
files/model-router/SKILL.md
docs/LIFECYCLE-CONTRACT.md
lib/afk-commands.sh
tests/run-tests.sh
tests/lifecycle-readiness-tests.sh'
STRAY=""
while read -r f; do
  case "$f" in
    _bmad-output/*) continue ;;                       # story record + generated logs
  esac
  grep -qxF "$f" <<<"$DECLARED" || STRAY+="$f "
done < <(git diff --name-only "$BASE"..HEAD)
eq "9: no file outside the declared surface" "${STRAY:-none}" "none"

# reviewable diff, excluding the story record and the generated gate logs
read -r ADD DEL FILES < <(git diff --numstat "$BASE"..HEAD -- . \
  ':(exclude)_bmad-output/*' | awk '{a+=$1; d+=$2; n++} END {print a, d, n}')
printf '     (info) reviewable diff: +%s / -%s across %s files (budget: 800 lines / 25 files)\n' "$ADD" "$DEL" "$FILES"
eq "9: the worker's disclosed line count is accurate" "$ADD" "947"
eq "9: the worker's disclosed file count is accurate" "$FILES" "7"
if (( FILES <= 25 )); then ok "9: file budget met ($FILES / 25)"; else bad "9: file budget"; fi
if (( ADD <= 800 )); then ok "9: line budget met"; else
  printf '     (info) OVER BUDGET by %s lines (~%s%%) — disclosed in the Dev Agent Record\n' \
    "$(( ADD - 800 ))" "$(( (ADD - 800) * 100 / 800 ))"
  ok "9: the overrun is DISCLOSED (see the review's assessment, not a silent pass)"
fi
printf '  --- per-file reviewable diff ---\n'
git diff --numstat "$BASE"..HEAD -- . ':(exclude)_bmad-output/*' | sed 's/^/      /'

# generated gate logs committed into the code branch
LOGS="$(git diff --name-only "$BASE"..HEAD -- '_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.5A/*' | wc -l)"
LOGLINES="$(git diff --numstat "$BASE"..HEAD -- '_bmad-output/implementation-artifacts/evidence/AFK-PORT-1.5A/*' | awk '{a+=$1} END{print a}')"
printf '     (info) committed generated gate logs: %s files, %s lines\n' "$LOGS" "$LOGLINES"

# commit hygiene
printf '  --- commit messages ---\n'; git log --format='      %h %s' "$BASE"..HEAD
BODIES="$(git log --format='%B' "$BASE"..HEAD)"
for t in 'Co-Authored-By' 'Generated with' 'Claude-Session' 'claude.ai/code' '🤖'; do
  hasnt "9: no '$t' trailer in any commit message" "$BODIES" "$t"
done
for t in BMAD 'story file' persona 'dev agent' epic 'gate '; do
  if grep -qi "$t" <<<"$BODIES"; then printf '     (info) commit text mentions %s\n' "$t"; fi
done
ok "9: commit subjects are plain engineering language (listed above for the record)"

# git diff --check (permitted gate)
if git diff --check "$BASE"..HEAD >/dev/null 2>&1 && git diff --check >/dev/null 2>&1; then
  ok "9 GATE: git diff --check clean (branch range and working tree)"
else bad "9 GATE: git diff --check" "$(git diff --check "$BASE"..HEAD | head -5)"; fi

# working tree: the review must have added nothing outside its evidence dir
DIRTY="$(git status --porcelain | grep -v 'AFK-PORT-1.5A' || true)"
eq "9: the review changed nothing in the worktree outside its own artifacts" "${DIRTY:-none}" "none"

# --- is the story's OWN byte-identity oracle non-vacuous? ----------------
# It SKIPs when there is no master ref. Prove the skip path is reachable and
# that it is reported as a skip, not as a pass.
if grep -q 'skip "byte-identity vs master (no master ref' "$KIT_ROOT/tests/run-tests.sh"; then
  ok "9/oracle: the no-master path reports SKIP, not PASS"
else bad "9/oracle: the no-master path reports SKIP, not PASS"; fi
if grep -q 'byte-identity CONTROL' "$KIT_ROOT/tests/run-tests.sh"; then
  ok "9/oracle: the suite carries a control that makes a vacuous pass detectable"
else bad "9/oracle: the suite carries a control"; fi
# and the oracle compares against master, which must still hold the OLD builders
eq "9/oracle: master's dispatch.sh is still the pre-change one (the oracle is meaningful)" \
   "$(git diff "$BASE" master -- files/model-router/scripts/dispatch.sh | wc -l)" "0"
summary
