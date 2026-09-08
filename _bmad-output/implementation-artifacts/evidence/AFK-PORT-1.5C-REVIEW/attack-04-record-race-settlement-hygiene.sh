#!/usr/bin/env bash
# ATTACK 4 — the record-chain append under real contention, the non-vacuity of
# the monitor byte-identity assertion, and diff/commit hygiene.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
PASS=0 FAIL=0
ok()  { printf '  PASS %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; FAIL=$((FAIL+1)); }
head1(){ printf '\n%s\n' "$1"; }
assert_eq(){ [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "expected '$3', got '$2'"; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
DISPATCH="$PWD/files/model-router/scripts/dispatch.sh"

head1 "A. record_budget_line under REAL contention (30 racers, same code+cycle)"
# dispatch.sh guards its own main(), so the append can be driven directly.
cat > "$T/racer.sh" <<'R'
set -uo pipefail
# shellcheck source=/dev/null
source "$1"
record_budget_line "$2" "$3" CONTINUATION "from cycle 1 sha256:deadbeef trigger=WORKER_SIGNAL usage=9/0.9"
R
printf -- '---\npersona: dev\n---\n\n# S\n\n## Dev Agent Record\n\n' > "$T/s.md"
for i in $(seq 1 30); do ( bash "$T/racer.sh" "$DISPATCH" "$T/s.md" 2 >/dev/null 2>&1 ) & done
wait
n=$(grep -c 'CONTINUATION' "$T/s.md")
assert_eq "exactly one line survives 30 concurrent appends" "$n" "1"
assert_eq "the story is not corrupted (one Dev Agent Record heading)" \
  "$(grep -c '^## Dev Agent Record' "$T/s.md")" "1"
assert_eq "frontmatter still parses" "$(yq --front-matter=extract -r '.persona' "$T/s.md")" "dev"
# CONTROL: a different cycle DOES append
bash "$T/racer.sh" "$DISPATCH" "$T/s.md" 3 >/dev/null 2>&1
assert_eq "control: a different cycle appends its own line" "$(grep -c 'CONTINUATION' "$T/s.md")" "2"
# CONTROL: a different CODE at the same cycle also appends
( source "$DISPATCH"; record_budget_line "$T/s.md" 2 SIZING_RISK "x" ) >/dev/null 2>&1
assert_eq "control: a different code at the same cycle appends" \
  "$(grep -cE 'CONTINUATION|SIZING_RISK' "$T/s.md")" "3"
echo "  --- the surviving line ---"; grep -a 'CONTINUATION' "$T/s.md" | head -2 | sed 's/^/    /'

head1 "B. the monitor byte-identity assertion is NON-VACUOUS"
if git show master:lib/afk-monitor.sh 2>/dev/null | cmp -s - lib/afk-monitor.sh; then
  ok "lib/afk-monitor.sh is byte-identical to master"
else bad "lib/afk-monitor.sh is byte-identical to master"; fi
cp lib/afk-monitor.sh "$T/mut.sh"; printf '\n# mutation\n' >> "$T/mut.sh"
if git show master:lib/afk-monitor.sh 2>/dev/null | cmp -s - "$T/mut.sh"; then
  bad "control: the assertion detects a one-line mutation"
else ok "control: the assertion detects a one-line mutation"; fi
if git show master:no-such-file.sh 2>/dev/null | cmp -s - lib/afk-monitor.sh; then
  bad "control: the assertion fails CLOSED when the master side is unreadable"
else ok "control: the assertion fails CLOSED when the master side is unreadable"; fi
assert_eq "and the monitor's budget extraction is lane B's, unchanged" \
  "$(git diff master..HEAD --stat -- lib/afk-monitor.sh | wc -l)" "0"

head1 "C. diff surface and commit hygiene"
files=$(git diff --name-only master..HEAD | grep -v '^_bmad-output/' )
echo "$files" | sed 's/^/    /'
declared="files/model-router/scripts/dispatch.sh files/model-router/context-budget-policy.yaml lib/afk-commands.sh docs/LIFECYCLE-CONTRACT.md files/model-router/SKILL.md tests/run-tests.sh"
extra=""
for f in $files; do case " $declared " in *" $f "*) ;; *) extra="$extra $f" ;; esac; done
[[ -z "$extra" ]] && ok "no file outside the declared surface" || bad "no file outside the declared surface" "$extra"
lines=$(git diff --numstat master..HEAD -- $declared | awk '{a+=$1;d+=$2} END{print a+d}')
echo "    reviewable added+changed lines: $lines (budget 800), files: $(echo $files | wc -w) (budget 25)"
(( lines <= 800 )) && ok "diff within the 800-line budget" || bad "diff within the 800-line budget" "$lines"
msg=$(git log -1 --format='%B' master..HEAD)
if grep -qiE 'co-authored-by|generated with|🤖|as an AI|\bBMAD\b|story file|dev agent|persona|epic ' <<<"$msg"; then
  bad "commit message is plain: no trailers, no AI attribution, no BMAD vocabulary" "$(grep -inE 'co-authored-by|generated with|🤖|as an AI|\bBMAD\b|story file|dev agent|persona|epic ' <<<"$msg")"
else ok "commit message is plain: no trailers, no AI attribution, no BMAD vocabulary"; fi
if git diff --check master..HEAD; then ok "git diff --check clean"; else bad "git diff --check clean"; fi

head1 "D. secrets"
if git diff master..HEAD -- $declared | grep -aiE '^\+.*(BEGIN [A-Z ]*PRIVATE KEY|sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|xox[baprs]-)'; then
  bad "no secret material added"; else ok "no secret material added"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
