#!/usr/bin/env bash
# paperclip-report-tests.sh — the isolated deterministic gate for
# `agent-flow-kit paperclip-report` (lib/afk-paperclip-report.sh, AFK-PC-3a).
#
# No network: `orca` is a stub on PATH, following the pattern in
# tests/paperclip-pm-registry-tests.sh. A real temp git repo stands in for
# "the issue's project repo".
#
# Usage: tests/paperclip-report-tests.sh
# Exit:  0 all passed, 1 any failure.

set -uo pipefail

KIT_ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
AFK="$KIT_ROOT/bin/agent-flow-kit"
TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT

PASS=0 FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; FAIL=$((FAIL + 1)); }
head1() { printf '\n\033[1m%s\033[0m\n' "$1"; }
assert_eq()       { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing substring: $3 in: $2"; fi; }

if bash -n "$KIT_ROOT/lib/afk-paperclip-report.sh"; then ok "bash -n lib/afk-paperclip-report.sh"
else bad "bash -n lib/afk-paperclip-report.sh"; fi

STUBS="$TMPROOT/stubs"; mkdir -p "$STUBS"
TERMFILE="$TMPROOT/terminals.json"
cat > "$STUBS/orca" <<'SH'
#!/usr/bin/env bash
if [[ "$1 $2" == "terminal list" ]]; then
  cat "$ORCA_STUB_TERMINALS"
  exit 0
fi
exit 1
SH
chmod +x "$STUBS/orca"
set_terminals() { printf '%s' "$1" >"$TERMFILE"; }

REPO="$TMPROOT/repo"
git init -q "$REPO"
git -C "$REPO" config user.email t@test; git -C "$REPO" config user.name t
: >"$REPO/f"; git -C "$REPO" -c commit.gpgsign=false add f
git -C "$REPO" -c commit.gpgsign=false commit -qm init

STATE="$TMPROOT/state"
HOME_DIR="$TMPROOT/home"; mkdir -p "$HOME_DIR"
CONFIG="$HOME_DIR/.config/agent-flow-kit/paperclip.json"

ISSUE="e1111111-1111-1111-1111-111111111111"
AGENT1="11111111-1111-1111-1111-111111111111"

scope_key() { printf 'terminal-%s' "$(printf 'terminal\0%s' "$1" | sha256sum | awk '{print $1}')"; }

write_owner() { # <terminal>
  local sk; sk="$(scope_key "$1")"
  mkdir -p "$STATE/pm/scopes/$sk"
  jq -nc --arg t "$1" --arg wp "$REPO" \
    '{schema:"afk-pm-ownership/2",owned:true,role:"PM",harness:"claude",session:"s",terminal:$t,
      worktree:{id:"w",path:$wp},run_id:null,observed_at:"2026-09-27T00:00:00Z",observed_epoch:1,
      freshness_seconds:120,transition_id:null,previous:null}' >"$STATE/pm/scopes/$sk/ownership.json"
}

write_config() {
  mkdir -p "$HOME_DIR/.config/agent-flow-kit"
  jq -nc --arg r "$REPO" --arg a "$AGENT1" \
    '{api_url:"https://paperclip.test",company_id:"cccccccc-cccc-cccc-cccc-cccccccccccc",
      board_user_id:"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",host_label:"h",
      agents:[{agent_id:$a,key_ref:"op://x/y",project:"proj1",repo_path:$r,harness:"claude"}]}' >"$CONFIG"
}

write_ledger() { # [pending_cost_results-json]
  mkdir -p "$STATE/paperclip"
  jq -nc --arg id "$ISSUE" --argjson pending "${1:-[]}" \
    '{issues:{($id): {project:"proj1", pending_cost_results:$pending}}}' >"$STATE/paperclip/ledger.json"
}

reset_state() {
  rm -rf "$STATE"; mkdir -p "$STATE"
  write_config; write_ledger
  write_owner termA
  set_terminals '{"terminals":[{"handle":"termA","connected":true,"orphaned":false}]}'
}

RC=0 OUT_TEXT=""
run_afk() { # <handle> <args...>
  local handle="$1"; shift
  local out
  out="$(env -i PATH="$STUBS:$PATH" HOME="$HOME_DIR" LANG=C \
    AFK_STATE_DIR="$STATE" AFK_ORCA_BIN="$STUBS/orca" ORCA_STUB_TERMINALS="$TERMFILE" \
    AFK_PAPERCLIP_CONFIG="$CONFIG" ORCA_TERMINAL_HANDLE="$handle" \
    bash "$AFK" "$@" 2>&1)"
  RC=$?
  OUT_TEXT="$out"
}

body_file() { printf '%s' "$1" >"$TMPROOT/body.txt"; printf '%s' "$TMPROOT/body.txt"; }

head1 "1. Caller and body validation (AC-1, AC-2)"
reset_state
run_afk stranger paperclip-report --issue "$ISSUE" --comment-file "$(body_file hi)" --json
assert_contains "a non-owner is refused" "$OUT_TEXT" "PAPERCLIP_NOT_OWNER"

run_afk termA paperclip-report --issue 22222222-2222-2222-2222-222222222222 --comment-file "$(body_file hi)" --json
assert_contains "an unknown issue is refused" "$OUT_TEXT" "PAPERCLIP_ISSUE_UNKNOWN"

printf -v _big '%*s' 16385 ''; printf '%s' "${_big// /x}" >"$TMPROOT/big.txt"
run_afk termA paperclip-report --issue "$ISSUE" --comment-file "$TMPROOT/big.txt" --json
assert_contains "a body over 16 KiB is refused" "$OUT_TEXT" "PAPERCLIP_BODY_TOO_LARGE"
assert_eq "  ...nothing published" "$(find "$STATE/paperclip/spool" -name '[0-9]*.json' 2>/dev/null | wc -l)" "0"

head1 "2. Ordering and crash recovery (AC-2)"
reset_state
mkdir -p "$STATE/paperclip/spool/$ISSUE/.tmp"
: >"$STATE/paperclip/spool/$ISSUE/.tmp/leftover-from-a-crash.json"
run_afk termA paperclip-report --issue "$ISSUE" --comment-file "$(body_file one)" --json
assert_eq "first comment gets seq 1" "$(jq -r .seq <<<"$OUT_TEXT")" "1"
run_afk termA paperclip-report --issue "$ISSUE" --comment-file "$(body_file two)" --json
assert_eq "second comment gets seq 2" "$(jq -r .seq <<<"$OUT_TEXT")" "2"
run_afk termA paperclip-report --issue "$ISSUE" --comment-file "$(body_file three)" --json
assert_eq "third comment gets seq 3, despite the leftover .tmp file" "$(jq -r .seq <<<"$OUT_TEXT")" "3"
assert_eq "  ...the leftover .tmp file is still there, untouched" \
  "$(find "$STATE/paperclip/spool/$ISSUE/.tmp" -type f | wc -l)" "1"

rm -f "$STATE/paperclip/spool/$ISSUE/.seq.lock" 2>/dev/null
printf '%s\n' 3 >"$STATE/paperclip/spool/$ISSUE/.seq"
cp "$STATE/paperclip/spool/$ISSUE/00000003.json" "$STATE/paperclip/spool/$ISSUE/00000004.json"
run_afk termA paperclip-report --issue "$ISSUE" --comment-file "$(body_file four)" --json
assert_eq "a counter left behind a live entry (interrupted writer) steps past it" "$(jq -r .seq <<<"$OUT_TEXT")" "5"

mkfifo "$TMPROOT/body.fifo"
run_afk termA paperclip-report --issue "$ISSUE" --comment-file "$TMPROOT/body.fifo" --json
assert_contains "a FIFO body file is refused, not read (no hang)" "$OUT_TEXT" "PAPERCLIP_BODY_UNREADABLE"

head1 "3. Concurrency: two backgrounded writers never collide (AC-2)"
reset_state
run_bg() { # <out-file> <args...> -- a standalone invocation, safe backgrounded
  local outfile="$1"; shift
  env -i PATH="$STUBS:$PATH" HOME="$HOME_DIR" LANG=C \
    AFK_STATE_DIR="$STATE" AFK_ORCA_BIN="$STUBS/orca" ORCA_STUB_TERMINALS="$TERMFILE" \
    AFK_PAPERCLIP_CONFIG="$CONFIG" ORCA_TERMINAL_HANDLE="termA" \
    bash "$AFK" "$@" >"$outfile" 2>&1
}
run_bg "$TMPROOT/c1.out" paperclip-report --issue "$ISSUE" --comment-file "$(body_file concA)" --json &
p1=$!
run_bg "$TMPROOT/c2.out" paperclip-report --issue "$ISSUE" --comment-file "$(body_file concB)" --json &
p2=$!
wait "$p1" "$p2"
s1="$(jq -r .seq "$TMPROOT/c1.out" 2>/dev/null)"
s2="$(jq -r .seq "$TMPROOT/c2.out" 2>/dev/null)"
if [[ -n "$s1" && -n "$s2" && "$s1" != "$s2" ]]; then
  ok "two concurrent writers get different seqs ($s1, $s2)"
else
  bad "two concurrent writers get different seqs" "got '$s1' and '$s2'"
fi
assert_eq "  ...exactly two live entries were published" \
  "$(find "$STATE/paperclip/spool/$ISSUE" -maxdepth 1 -name '[0-9]*.json' | wc -l)" "2"

head1 "4. Question entries and final closure (AC-2, AC-3)"
reset_state
run_afk termA paperclip-report --issue "$ISSUE" --question q-1 --comment-file "$(body_file "what now?")" --json
assert_eq "a question entry publishes" "$(jq -r .result <<<"$OUT_TEXT")" "ok"
qfile="$(find "$STATE/paperclip/spool/$ISSUE" -maxdepth 1 -name '[0-9]*.json' | sort | tail -1)"
assert_eq "  ...it carries its qid" "$(jq -r .question_id "$qfile")" "q-1"

run_afk termA paperclip-report --issue "$ISSUE" --final "done" --comment-file "$(body_file "all done")" --json
assert_eq "a final entry publishes" "$(jq -r .result <<<"$OUT_TEXT")" "ok"

run_afk termA paperclip-report --issue "$ISSUE" --comment-file "$(body_file "too late")" --json
assert_contains "after final, the next entry is refused" "$OUT_TEXT" "PAPERCLIP_SPOOL_CLOSED"

head1 "5. Pending cost events (AC-3)"
reset_state
write_ledger '["result.c1.json"]'
run_afk termA paperclip-report --issue "$ISSUE" --final "in_review" --comment-file "$(body_file "review")" --json
assert_contains "COST_EVENTS_PENDING fires with a pending ledger result" "$OUT_TEXT" "COST_EVENTS_PENDING"

head1 "6. Declared status (AC-4, AC-5, AC-6)"
reset_state
run_afk termA paperclip-report --issue "$ISSUE" --status "working on it" --story 1/3 --json
assert_eq "a status write returns version 1" "$(jq -r .version <<<"$OUT_TEXT")" "1"
run_afk termA paperclip-report --issue "$ISSUE" --status "still working" --json
assert_eq "a second status write increments version" "$(jq -r .version <<<"$OUT_TEXT")" "2"
sfile="$STATE/paperclip/status/$ISSUE.json"
assert_eq "  ...status file mode is 0600" "$(stat -c '%a' "$sfile")" "600"
assert_eq "  ...status dir mode is 0700" "$(stat -c '%a' "$(dirname "$sfile")")" "700"

multiline="$(printf 'line one\nline two')"
run_afk termA paperclip-report --issue "$ISSUE" --status "$multiline" --json
assert_contains "multi-line status text is rejected" "$OUT_TEXT" "PAPERCLIP_STATUS_INVALID"

head1 "7. Human output never prints the body (AC-5)"
reset_state
run_afk termA paperclip-report --issue "$ISSUE" --comment-file "$(body_file "a secret-looking body")"
assert_eq "  ...human output is just the seq" "$OUT_TEXT" "1"

head1 "8. Round trip: the report cycle reads and posts what we wrote"
reset_state
run_afk termA paperclip-report --issue "$ISSUE" --comment-file "$(body_file "round trip body")" --json
assert_eq "seed comment published" "$(jq -r .result <<<"$OUT_TEXT")" "ok"
run_afk termA paperclip-report --issue "$ISSUE" --question q-7 --comment-file "$(body_file "round trip question")" --json
assert_eq "seed question published" "$(jq -r .result <<<"$OUT_TEXT")" "ok"
run_afk termA paperclip-report --issue "$ISSUE" --final in_review --comment-file "$(body_file "round trip final")" --json
assert_eq "seed final published" "$(jq -r .result <<<"$OUT_TEXT")" "ok"

RT_CURL="$TMPROOT/rt-curl"
RT_LOG="$TMPROOT/rt-curl.log"
: >"$RT_LOG"
cat >"$RT_CURL" <<SH
#!/usr/bin/env bash
method="GET"
n=\$#
args=("\$@")
for ((i = 0; i < n; i++)); do
  [[ "\${args[\$i]}" == -X ]] && method="\${args[\$((i + 1))]}"
done
url="\${args[\$((n - 1))]}"
printf '%s %s\n' "\$method" "\$url" >>"$RT_LOG"
for ((i = 0; i < n; i++)); do
  if [[ "\${args[\$i]}" == --data-binary && "\${args[\$((i + 1))]}" == @/dev/fd/* ]]; then
    cat "\${args[\$((i + 1))]#@}" >>"$RT_LOG.body"
  fi
done
case "\$method \$url" in
  "POST "*/wakeup) printf '{"id":"run-1"}201' ;;
  "PATCH "*/api/issues/*) printf '{}200' ;;
  "POST "*/comments) printf '{}201' ;;
  *) printf '000' ;;
esac
SH
chmod +x "$RT_CURL"

out="$(env -i PATH="$STUBS:$PATH" HOME="$HOME_DIR" LANG=C AFK_STATE_DIR="$STATE" \
  AFK_CURL_BIN="$RT_CURL" bash -c '
    source "'"$KIT_ROOT"'/lib/afk-common.sh"
    source "'"$KIT_ROOT"'/lib/afk-readiness.sh"
    source "'"$KIT_ROOT"'/lib/afk-paperclip.sh"
    ledger="$(jq -c . "$AFK_STATE_DIR/paperclip/ledger.json")"
    actions="[]"
    host_label="h"
    afk_pc_report_cycle "https://paperclip.test" "k" "'"$AGENT1"'" "'"$ISSUE"'" "PROJ-1" "proj1" "/nonexistent"
  ')"
assert_contains "the report cycle posted a comment" "$(cat "$RT_LOG.body" 2>/dev/null)" "round trip body"
assert_contains "the report cycle posted the question" "$(cat "$RT_LOG.body" 2>/dev/null)" "round trip question"
assert_contains "the report cycle posted the final" "$(cat "$RT_LOG.body" 2>/dev/null)" "round trip final"
assert_contains "the final set the declared status" "$(cat "$RT_LOG.body" 2>/dev/null)" '"in_review"'
assert_eq "every spool entry was consumed, none dead-lettered" \
  "$(find "$STATE/paperclip/spool/$ISSUE" -name '[0-9]*.json' | wc -l)" "0"
assert_eq "  ...and the live directory is empty" \
  "$(find "$STATE/paperclip/spool/$ISSUE" -maxdepth 1 -name '[0-9]*.json' | wc -l)" "0"

head1 "Summary"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
