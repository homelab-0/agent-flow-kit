#!/usr/bin/env bash
# factory-safety-tests.sh — Hermetic tests for the fail-closed behaviour of the
# AFK Software Factory job runner (lib/afk-factory.sh):
#   - a stage that fails stops the job; nothing is assumed, canned or merged
#   - the merge approver needs every required review, a real change, and the
#     project's merge authority
#   - only the board user can approve, and only by saying so
#   - one runner per job, across restarts and reused PIDs
#   - landing waits for checks and merges the commit that was reviewed
#
# Stages are played by a scripted runner (AFK_FACTORY_AGENT_RUNNER) or by stub
# binaries. No network, no real agent CLI, no real GitHub.

set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AFK="$KIT_ROOT/bin/agent-flow-kit"
TMPROOT="$(mktemp -d)"
trap '[[ "${AFK_TEST_KEEP_TMP:-0}" == "1" ]] && printf "kept: %s\n" "$TMPROOT" || rm -rf "$TMPROOT"' EXIT

PASS=0 FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s (%s)\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
head1(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing '$3' in '${2:0:300}'"; fi
}

export HOME="$TMPROOT/home"
export AFK_STATE_DIR="$HOME/.local/state/agent-flow-kit"
export AFK_PAPERCLIP_CONFIG="$HOME/.config/agent-flow-kit/paperclip.json"
export AFK_SKIP_BENCHMARK_AUTOSYNC=1
export AFK_FACTORY_BEAT_SEC=1
# Name the harness for routing, so no real agent CLI on this host is probed.
export AFK_ROUTER_HARNESS_LIST=claude
mkdir -p "$HOME/.config/agent-flow-kit" "$AFK_STATE_DIR"
unset AFK_FACTORY_OFFLINE_SYNTH AFK_FACTORY_LIVE_HARNESS AFK_FACTORY_AGENT_RUNNER \
      AFK_FACTORY_TEST_DIFF_STATS 2>/dev/null || true

# --- a scripted agent --------------------------------------------------------
# Behaviour per stage comes from R_<STAGE> variables; every call is logged.
CALLS="$TMPROOT/calls.log"
RUNNER="$TMPROOT/runner.sh"
cat > "$RUNNER" <<'SH'
#!/usr/bin/env bash
STAGE="$1"; OUT="$4"; WT="${AFK_FACTORY_WORKTREE:-.}"; JOB="${AFK_FACTORY_JOB_DIR:-.}"
FEATURE="feature-$(basename "$JOB").txt"
printf '%s\n' "$STAGE" >> "$CALLS"
usage() { printf '{"used_tokens":%s,"window_tokens":200000,"compacted":false}\n' "${R_TOKENS:-1000}"; }
review() { # <mode>
  case "$1" in
    pass)      printf 'VERDICT: PASS\n## Summary\n- Fine.\n' > "$OUT" ;;
    changes)   printf 'VERDICT: CHANGES_REQUESTED\n## Summary\n- Fix it.\n' > "$OUT" ;;
    ambiguous) printf 'VERDICT: PASS or CHANGES_REQUESTED\n## Summary\n- Unsure.\n' > "$OUT" ;;
    none)      : ;;
    fail)      exit 1 ;;
  esac
}
case "$STAGE" in
  intake)
    case "${R_INTAKE:-ok}" in
      ok)      printf 'VERDICT: ACCEPT\nRISK: low\nSURFACES: code\n## Summary\n- Ready.\n' > "$OUT" ;;
      marked)  printf '**VERDICT:** **ACCEPT**\nRISK: **High.**\nSURFACES: `Code`, Security\n## Summary\n- Ready.\n' > "$OUT" ;;
      prose)   printf '## Summary\n- Looks like a reasonable request.\n' > "$OUT" ;;
      reject)  printf 'VERDICT: REJECT.\n## Summary\n- Out of scope.\n' > "$OUT" ;;
      none)    : ;;
      fail)    exit 1 ;;
    esac ;;
  spec)
    [[ "${R_SPEC:-ok}" == fail ]] && exit 1
    printf '# Spec\n- Do the thing.\n' > "$OUT" ;;
  build)
    case "${R_BUILD:-ok}" in
      ok)        printf 'feature\n' >> "$WT/$FEATURE" ;;
      nochange)  : ;;
      fail)      printf 'half done\n' >> "$WT/$FEATURE"; exit 1 ;;
      workflow)  mkdir -p "$WT/.github/workflows"; printf 'on: push\n' > "$WT/.github/workflows/ci.yml" ;;
      move-checks) git -C "$WT" mv .afk/checks.sh docs-checks.sh ;;
      big)       seq 1 900 > "$WT/big.txt"
                 # A builder trying to declare its own change small.
                 jq '.diff_stats = {lines: 1, files: 1, changed_paths: ["README.md"]}' "$JOB/job.json" > "$JOB/job.json.x" && mv "$JOB/job.json.x" "$JOB/job.json" ;;
      slow)      printf 'slow\n' >> "$WT/$FEATURE"; sleep "${R_SLEEP:-6}" ;;
      other-branch) git -C "$WT" checkout -q -b side-branch; printf 'side\n' >> "$WT/$FEATURE" ;;
    esac
    printf '## Summary\n- Built.\n' > "$OUT" ;;
  review-code)     review "${R_REVIEW:-pass}" ;;
  review-security) review "${R_SEC:-pass}" ;;
  review-arch)     review "${R_ARCH:-pass}" ;;
  review-ux)       review "${R_UX:-pass}" ;;
esac
usage
SH
chmod +x "$RUNNER"
export CALLS

new_repo() { # <name> [<branch>] -> path; a git repo with the factory initialised and committed
  local r="$TMPROOT/$1" br="${2:-main}"
  mkdir -p "$r"
  git -C "$r" init -q -b "$br"
  git -C "$r" config user.name "Test"
  git -C "$r" config user.email "test@example.invalid"
  printf 'hello\n' > "$r/README.md"
  git -C "$r" add README.md
  git -C "$r" commit -q -m "init"
  bash "$AFK" factory init --repo "$r" >/dev/null
  # Local landing: the job's branch is merged into this checkout.
  jq '.land = "local" | .max_rounds = 2' "$r/.afk/config.json" > "$r/.afk/config.json.x" && mv "$r/.afk/config.json.x" "$r/.afk/config.json"
  printf '.afk/jobs/\n' > "$r/.gitignore"
  git -C "$r" add .afk/config.json .afk/checks.sh .afk/gates-allowlist .gitignore
  git -C "$r" commit -q -m "factory config"
  printf '%s' "$r"
}
run_job() { # <repo> <job> [env assignments...] -> job JSON
  local repo="$1" job="$2"; shift 2
  : > "$CALLS"
  env AFK_FACTORY_AGENT_RUNNER="$RUNNER" "$@" bash "$AFK" factory run --repo "$repo" --job "$job" --title "Job $job" --json 2>/dev/null
}
calls() { tr '\n' ',' < "$CALLS" | sed 's/,$//'; }
count_call() { grep -c "^$1\$" "$CALLS" 2>/dev/null || true; }
field() { jq -r "$2" <<<"$1" 2>/dev/null; }
reasons() { jq -r '(.merge_evaluation.reasons // []) | join(" | ")' <<<"$1" 2>/dev/null; }

# ============================================================================
head1 "1. A stage runs a real agent or it fails; nothing is canned by default"
# ============================================================================
R1="$(new_repo r-default)"
EMPTY_BIN="$TMPROOT/no-harness"; mkdir -p "$EMPTY_BIN"
DEFAULT_OUT="$(env -u AFK_ROUTER_HARNESS_LIST AFK_HARNESS_BIN_DIR_OVERRIDE="$EMPTY_BIN" PATH="/usr/bin:/bin" bash "$AFK" factory run --repo "$R1" --job job-default --title "No agent here" --json 2>/dev/null)"
assert_eq "With no agent CLI available and no test flag, the job stops for a person instead of approving itself" \
  "$(field "$DEFAULT_OUT" '"\(.stage):\(.decision):\(.escalation_kind)"')" "needs-human:ESCALATE:stage_failure"
assert_eq "No canned intake, review or build output was written for it" \
  "$(find "$R1/.afk/jobs/job-default" -name 'intake.md' -o -name 'build.md' -o -name 'review-*.md' | wc -l | tr -d ' ')" "0"
assert_eq "Its branch was not merged into the base checkout" \
  "$(git -C "$R1" log --oneline | wc -l | tr -d ' ')" "2"

CLEAN_OUT="$(run_job "$R1" job-clean)"
assert_eq "A clean job with a real change, passing checks and a passing review merges" \
  "$(field "$CLEAN_OUT" '"\(.stage):\(.decision)"'):$([[ -f "$R1/feature-job-clean.txt" ]] && printf landed || printf missing)" "merged:APPROVE:landed"
assert_eq "The job records the commit its branch was cut from" \
  "$(field "$CLEAN_OUT" '(.base_sha | length):\(.base_branch)"' 2>/dev/null || field "$CLEAN_OUT" '"\(.base_sha | length):\(.base_branch)"')" "40:main"

: > "$CALLS"
AGAIN_OUT="$(AFK_FACTORY_AGENT_RUNNER="$RUNNER" bash "$AFK" factory run --repo "$R1" --job job-clean --title "Job job-clean" --json 2>/dev/null)"
assert_eq "A job that already merged is never run again" \
  "$(field "$AGAIN_OUT" '.stage'):$(wc -l < "$CALLS" | tr -d ' ')" "merged:0"

# ============================================================================
head1 "2. A stage that fails or cannot be read stops the job"
# ============================================================================
R2="$(new_repo r-stages)"
O="$(run_job "$R2" intake-none R_INTAKE=none)"
assert_eq "An intake that writes nothing stops the job; nothing is built" \
  "$(field "$O" '"\(.stage):\(.escalation_kind)"'):$(calls)" "needs-human:stage_failure:intake"
assert_contains "The reason says the request was never assessed" "$(reasons "$O")" "Intake did not complete"

O="$(run_job "$R2" intake-prose R_INTAKE=prose)"
assert_eq "An intake with no verdict is not taken as ACCEPT" \
  "$(field "$O" '.stage'):$(calls)" "needs-human:intake"

O="$(run_job "$R2" intake-fail R_INTAKE=fail)"
assert_eq "An intake whose agent exits non-zero stops the job" "$(field "$O" '.stage'):$(calls)" "needs-human:intake"

O="$(run_job "$R2" intake-reject R_INTAKE=reject)"
assert_eq "A REJECT written with a full stop is still a rejection" "$(field "$O" '.stage'):$(calls)" "rejected:intake"

O="$(run_job "$R2" intake-marked R_INTAKE=marked)"
assert_eq "Bold markers, capitals and backticks in the intake are read: high risk, security surface" \
  "$(field "$O" '"\(.risk):\(.surfaces | join(","))"')" "high:code,security"
assert_eq "That job required the security and architecture reviews, and ran them" \
  "$(tr '\n' ',' < "$R2/.afk/jobs/intake-marked/round-1/expected-reviews" | sed 's/,$//'):$(count_call review-security):$(count_call review-arch)" \
  "review-code,review-security,review-arch:1:1"

O="$(run_job "$R2" spec-fail R_SPEC=fail)"
assert_eq "A failed specification stage stops the job before any build" \
  "$(field "$O" '.stage'):$(count_call build)" "needs-human:0"

printf 'Use the retry helper.\n' > "$R2/.afk/jobs/spec-fail/human-feedback.md" 2>/dev/null
O="$(run_job "$R2" build-fail R_BUILD=fail)"
assert_eq "A failed build stops the job: no checks, no review, no merge" \
  "$(field "$O" '"\(.stage):\(.escalation_kind)"'):$(count_call review-code):$([[ -f "$R2/feature-build-fail.txt" ]] && printf merged || printf not-merged)" \
  "needs-human:stage_failure:0:not-merged"

O="$(run_job "$R2" build-empty R_BUILD=nochange)"
assert_eq "A build that changes nothing is not approved for merge" "$(field "$O" '"\(.stage):\(.decision)"')" "needs-human:ESCALATE"
assert_contains "The reason names the empty branch" "$(reasons "$O")" "no committed changes"

printf '#!/bin/sh\nexit 1\n' > "$R2/.git/hooks/pre-commit"; chmod +x "$R2/.git/hooks/pre-commit"
O="$(run_job "$R2" commit-refused)"
rm -f "$R2/.git/hooks/pre-commit"
assert_eq "A build whose commit is refused stops the job, and the uncommitted work is still in its worktree" \
  "$(field "$O" '.stage'):$([[ -f "$(field "$O" '.worktree_path')/feature-commit-refused.txt" ]] && printf work-kept || printf work-lost):$(count_call review-code)" \
  "needs-human:work-kept:0"
assert_contains "The reason says the build could not be committed" "$(reasons "$O")" "could not be committed"

# ============================================================================
head1 "3. Every review a round requires must pass"
# ============================================================================
R3="$(new_repo r-reviews)"
O="$(run_job "$R3" sec-missing R_INTAKE=marked R_SEC=none)"
assert_eq "A security review that produced nothing blocks the merge, even though the code review passed" \
  "$(field "$O" '"\(.stage):\(.decision)"')" "needs-human:ESCALATE"
assert_contains "The reason names the missing review" "$(reasons "$O")" "review-security returned MISSING"
assert_eq "A missing review does not trigger another build round" "$(count_call build)" "1"

O="$(run_job "$R3" sec-crash R_INTAKE=marked R_SEC=fail)"
assert_eq "A security reviewer that crashes blocks the merge the same way" "$(field "$O" '.stage')" "needs-human"

O="$(run_job "$R3" verdict-ambiguous R_REVIEW=ambiguous)"
assert_eq "\"VERDICT: PASS or CHANGES_REQUESTED\" is not a pass" "$(field "$O" '.stage')" "needs-human"

VERDICTS="$(bash -c '
  . "'"$KIT_ROOT"'/lib/afk-common.sh" 2>/dev/null
  . "'"$KIT_ROOT"'/lib/afk-paperclip.sh" 2>/dev/null
  . "'"$KIT_ROOT"'/lib/afk-factory.sh" 2>/dev/null
  f="$1/verdict.md"
  for v in "VERDICT: PASS" "**VERDICT:** PASS" "VERDICT: PASS — two notes below" "VERDICT: pass." \
           "VERDICT: PASS or CHANGES_REQUESTED" "VERDICT: PASSED" "VERDICT: CHANGES_REQUESTED (see below)" \
           "VERDICT: **NEEDS-INFO**" "VERDICT: REJECT." "The verdict is PASS"; do
    printf "%s\n## Summary\n" "$v" > "$f"
    printf "[%s]" "$(_afk_factory_strict_verdict "$f")"
  done
' _ "$TMPROOT")"
assert_eq "A verdict line is read through markup and trailing notes; two verdicts, an unknown word or no label read as no verdict" \
  "$VERDICTS" "[PASS][PASS][PASS][PASS][][][CHANGES_REQUESTED][NEEDS-INFO][REJECT][]"

O="$(run_job "$R3" changes-twice R_REVIEW=changes)"
assert_eq "Reviews that keep asking for changes use the allowed rounds and then go to a person" \
  "$(field "$O" '"\(.stage):\(.round)"'):$(count_call build)" "needs-human:2:2"

O="$(run_job "$R3" ctx-replaced R_TOKENS=170000)"
assert_eq "A stage that finished is not run a second time when its agent crossed the context threshold" \
  "$(field "$O" '.stage'):$(count_call build):$(count_call review-code)" "merged:1:1"

# ============================================================================
head1 "4. The merge approver measures the real change"
# ============================================================================
R4="$(new_repo r-approver)"
O="$(run_job "$R4" touches-workflow R_BUILD=workflow)"
assert_contains "A change to .github/workflows/ goes to a person" "$(reasons "$O")" "Protected path touched: .github/workflows/ci.yml"

printf '{"land":"local","max_rounds":1}\n' > "$R4/.afk/config.json"
git -C "$R4" commit -q -am "config without a protected_paths key"
O="$(run_job "$R4" defaults-kept R_BUILD=workflow)"
assert_contains "A config file that omits protected_paths still protects the default paths" "$(reasons "$O")" "Protected path touched"

O="$(run_job "$R4" moves-checks R_BUILD=move-checks)"
assert_eq "Moving the check script out of its path is caught as tampering, and the job does not merge" \
  "$(field "$O" '.stage'):$(grep -c 'protected factory gate file' "$R4/.afk/jobs/moves-checks/round-1/checks.md")" "needs-human:1"

O="$(run_job "$R4" self-declared-small R_BUILD=big)"
assert_contains "Diff figures a builder wrote into the job file are ignored; the 900-line change is over budget" \
  "$(reasons "$O")" "Diff size (900 lines) exceeds budget"

RDEV="$(new_repo r-develop develop)"
seq 1 950 > "$RDEV/earlier-work.txt"; git -C "$RDEV" add earlier-work.txt; git -C "$RDEV" commit -q -m "earlier work on develop"
O="$(run_job "$RDEV" on-develop)"
assert_eq "On a repository whose branch is neither main nor master, only the job's own change is measured" \
  "$(field "$O" '"\(.stage):\(.merge_evaluation.diff_files):\(.base_branch)"')" "merged:1:develop"

RSLOW="$(new_repo r-slowgate)"
printf '#!/usr/bin/env bash\nsleep 60\n' > "$RSLOW/.afk/checks.sh"; git -C "$RSLOW" commit -q -am "a check that hangs"
T0=$SECONDS
O="$(run_job "$RSLOW" hung-checks AFK_GATE_TIMEOUT_SEC=2)"
assert_eq "A check script that hangs is stopped at its time limit and counts as a failure" \
  "$(field "$O" '.stage'):$(( SECONDS - T0 < 45 ))" "needs-human:1"

RUNTRACKED="$(new_repo r-tamper)"
O1="$(run_job "$RUNTRACKED" base-edit AFK_FACTORY_TEST_HOOK=1)"
printf '#!/usr/bin/env bash\nexit 1\n' > "$RUNTRACKED/.afk/checks.sh"   # an edit to the base checkout's working copy
O="$(run_job "$RUNTRACKED" base-edit-2)"
assert_eq "The checks run as committed on the base, not as edited in its working copy" \
  "$(field "$O1" '.stage'):$(head -n 1 "$RUNTRACKED/.afk/jobs/base-edit-2/round-1/checks.md")" "merged:VERDICT: PASS"
git -C "$RUNTRACKED" checkout -q -- .afk/checks.sh

cat > "$AFK_PAPERCLIP_CONFIG" <<JSON
{"schema":"afk-paperclip-config/2","projects":[
  {"slug":"humanproj","repo_path":"$R4","merge":"human"},
  {"slug":"pmproj","repo_path":"$R3","merge":"pm"},
  {"slug":"unsetproj","repo_path":"$R2"}]}
JSON
: > "$CALLS"
O="$(AFK_FACTORY_AGENT_RUNNER="$RUNNER" bash "$AFK" factory run --repo "$R4" --slug humanproj --job human-merge --title "Human merges" --json 2>/dev/null)"
assert_contains "A project whose merge authority is 'human' is never merged unattended" "$(reasons "$O")" "merge authority is 'human'"
: > "$CALLS"
O="$(AFK_FACTORY_AGENT_RUNNER="$RUNNER" bash "$AFK" factory run --repo "$R2" --slug unsetproj --job unset-merge --title "Unset" --json 2>/dev/null)"
assert_eq "A listed project with no merge setting is treated as 'human'" "$(field "$O" '.stage')" "needs-human"
: > "$CALLS"
O="$(AFK_FACTORY_AGENT_RUNNER="$RUNNER" bash "$AFK" factory run --repo "$R3" --slug pmproj --job pm-merge --title "PM merges" --json 2>/dev/null)"
assert_eq "A project whose merge authority is 'pm' merges a clean change" "$(field "$O" '.stage')" "merged"
rm -f "$AFK_PAPERCLIP_CONFIG"

# ============================================================================
head1 "5. One runner per job, across restarts and reused PIDs"
# ============================================================================
R5="$(new_repo r-lock)"
: > "$CALLS"
( AFK_FACTORY_AGENT_RUNNER="$RUNNER" R_BUILD=slow R_SLEEP=5 bash "$AFK" factory run --repo "$R5" --job two-runners --title "Slow" --json >"$TMPROOT/first.json" 2>/dev/null ) &
FIRST_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do grep -q '^build$' "$CALLS" 2>/dev/null && break; sleep 0.5; done
SECOND="$(AFK_FACTORY_AGENT_RUNNER="$RUNNER" bash "$AFK" factory run --repo "$R5" --job two-runners --title "Slow" --json 2>/dev/null)"
HB_WHILE="$(cat "$R5/.afk/jobs/two-runners/heartbeat.json" 2>/dev/null)"
WD_WHILE="$(bash "$AFK" factory watchdog --repo "$R5" --json 2>/dev/null)"
wait "$FIRST_PID"
assert_eq "A second runner on a job that is running is refused, and the stage runs once" \
  "$(field "$SECOND" '.already_running'):$(count_call build):$(jq -r '.stage' "$TMPROOT/first.json")" "true:1:merged"
assert_eq "The heartbeat names the runner by PID, start time and boot" \
  "$(jq -r '"\(.pid != null):\(.start != null):\(.boot != null):\(.state)"' <<<"$HB_WHILE")" "true:true:true:running"
assert_eq "The watchdog leaves a job with a live runner alone" \
  "$(jq -r '[.actions[] | select(.job_id == "two-runners") | .action] | join(",")' <<<"$WD_WHILE")" "healthy_running"
assert_eq "The run lock is released when the job ends" "$([[ -d "$R5/.afk/jobs/two-runners/.run.lock" ]] && printf held || printf released)" "released"

# A job left mid-build by a runner that no longer exists.
orphan() { # <job> <owner-json>
  local d="$R5/.afk/jobs/$1"
  mkdir -p "$d/round-1" "$d/.run.lock"
  git -C "$R5" worktree add -q -B "factory/$1" "$R5-factory/$1" HEAD 2>/dev/null
  jq -cn --arg id "$1" --arg repo "$R5" --arg wt "$R5-factory/$1" --arg sha "$(git -C "$R5" rev-parse HEAD)" \
    '{schema:"afk-factory-job/1", id:$id, slug:"r-lock", issue_id:null, title:("Job " + $id), repo_path:$repo, worktree_path:$wt, branch:("factory/" + $id), base_sha:$sha, base_branch:"main", stage:"build", round:1, risk:"low", surfaces:["code"]}' > "$d/job.json"
  printf 'VERDICT: ACCEPT\nRISK: low\nSURFACES: code\n' > "$d/intake.md"
  printf '# Spec\n' > "$d/spec.md"
  printf '%s\n' "$2" > "$d/.run.lock/owner.json"
  jq -cn --argjson ep "$(date -u +%s)" '{schema:"afk-factory-heartbeat/1", pid:null, state:"running", stage:"build", last_beat_epoch:$ep, nudge_count:0}' > "$d/heartbeat.json"
}
orphan dead-pid '{"pid": 2147483000, "start": "x", "boot": "y"}'
# This shell's PID is alive, but it started at another time than the record
# says: the kernel handed the number out again, as it does after a restart.
orphan reused-pid "$(jq -cn --argjson pid "$$" '{pid: $pid, start: "started-long-ago", boot: ""}')"
: > "$CALLS"
WD="$(AFK_FACTORY_AGENT_RUNNER="$RUNNER" bash "$AFK" factory watchdog --repo "$R5" --json 2>/dev/null)"
assert_eq "A job whose runner is gone is picked up and finished" \
  "$(jq -r '[.actions[] | select(.job_id == "dead-pid") | "\(.action):\(.stage)"] | join(",")' <<<"$WD")" "nudged_and_resumed:merged"
assert_eq "A job whose runner's PID now belongs to another process is not mistaken for running" \
  "$(jq -r '[.actions[] | select(.job_id == "reused-pid") | "\(.action):\(.stage)"] | join(",")' <<<"$WD")" "nudged_and_resumed:merged"

: > "$R5/.afk/jobs/dead-pid/job.json"   # a job file cut off mid-write
ST="$(bash "$AFK" factory status --repo "$R5" --json 2>/dev/null)"
assert_eq "One empty job file does not blank the status of the other jobs" \
  "$(jq -r '[.jobs[].id] | index("reused-pid") != null' <<<"$ST")" "true"
O="$(run_job "$R5" dead-pid)"
assert_eq "A job with an unreadable job file is given a fresh record and carries on from its stage files" \
  "$(field "$O" '.id'):$(find "$R5/.afk/jobs/dead-pid" -maxdepth 1 -name 'job.json.corrupt.*' | wc -l | tr -d ' ')" "dead-pid:1"

assert_eq "A mistyped --repo is an error, not 'every project on the host'" \
  "$(bash "$AFK" factory resume --repo "$TMPROOT/no-such-dir" --json >/dev/null 2>&1; printf '%s' "$?")" "1"

# ============================================================================
head1 "6. Only the board user approves, and only by saying so"
# ============================================================================
RULES="$(bash -c '
  . "'"$KIT_ROOT"'/lib/afk-common.sh" 2>/dev/null
  . "'"$KIT_ROOT"'/lib/afk-paperclip.sh" 2>/dev/null
  . "'"$KIT_ROOT"'/lib/afk-factory.sh" 2>/dev/null
  for c in "approve" "Approved." "  LGTM!  " "ship it" "Merge" \
           "Merge conflicts with main, please rebase first" \
           "Approve once the failing test is fixed" \
           "LGTM except the auth change - revert that" \
           "merge: no, this is wrong" "Ship it after you fix the migration" ""; do
    if _afk_factory_comment_is_approval "$c"; then printf Y; else printf n; fi
  done
  printf "|"
  COMMENTS='"'"'[
    {"id":"c1","authorUserId":"board-1","authorAgentId":null,"body":"old board note"},
    {"id":"c2","authorUserId":null,"authorAgentId":"agent-9","body":"agent says approve"},
    {"id":"c3","authorUserId":"someone-else","authorAgentId":null,"body":"approve"},
    {"id":"c4","authorUserId":"board-1","authorAgentId":null,"body":"please add a test"}
  ]'"'"'
  printf "%s|" "$(_afk_factory_new_board_comment "$COMMENTS" "c1" "board-1")"
  printf "%s|" "$(_afk_factory_new_board_comment "$COMMENTS" "c4" "board-1")"
  printf "%s|" "$(_afk_factory_new_board_comment "$COMMENTS" "" "")"
  ONLY_OTHERS='"'"'[{"id":"c3","authorUserId":"someone-else","authorAgentId":null,"body":"approve"}]'"'"'
  printf "%s" "$(_afk_factory_new_board_comment "$ONLY_OTHERS" "" "board-1")"
')"
assert_eq "A comment approves only when the approval is the whole comment" "${RULES%%|*}" "YYYYYnnnnnn"
assert_eq "The newest comment by the board user after the last one seen is the instruction; other people and agents are ignored" \
  "$(cut -d'|' -f2 <<<"$RULES")" "please add a test"
assert_eq "Nothing new from the board user means no instruction, whoever else commented or whether a board user is configured" \
  "$(cut -d'|' -f3- <<<"$RULES")" "||"

# ============================================================================
head1 "7. Landing waits for checks and merges the reviewed commit"
# ============================================================================
GH="$TMPROOT/fake-gh"
cat > "$GH" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  "pr list")   cat "$GH_STATE/list.json" 2>/dev/null || printf '[]\n' ;;
  "pr create") printf 'https://github.com/example/demo/pull/7\n' ;;
  "pr view")
    if [[ "$*" == *statusCheckRollup* ]]; then
      n=$(( $(cat "$GH_STATE/views" 2>/dev/null || printf 0) + 1 )); printf '%s' "$n" > "$GH_STATE/views"
      if [[ -f "$GH_STATE/checks-$n.json" ]]; then cat "$GH_STATE/checks-$n.json"; else cat "$GH_STATE/checks.json"; fi
    elif [[ -f "$GH_STATE/merged" ]]; then printf '{"state":"MERGED","mergeCommit":{"oid":"abc123def456"}}\n'
    else printf '{"state":"OPEN","mergeCommit":null}\n'; fi ;;
  "pr merge")  [[ -f "$GH_STATE/refuse-merge" ]] && exit 1; : > "$GH_STATE/merged" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$GH"
land() { # <checks-json> [setup...] -> land result JSON
  local repo="$TMPROOT/r-gh-$RANDOM" checks="$1"; shift
  mkdir -p "$repo" "$TMPROOT/gh-state"; rm -rf "$TMPROOT/gh-state"/*; : > "$TMPROOT/gh.log"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name T; git -C "$repo" config user.email t@example.invalid
  printf 'x\n' > "$repo/a"; git -C "$repo" add a; git -C "$repo" commit -q -m init
  git -C "$repo" remote add origin "${LAND_ORIGIN:-https://github.com/example/demo.git}"
  git -C "$repo" worktree add -q -B factory/j1 "$repo-wt" HEAD
  printf 'y\n' > "$repo-wt/b"; git -C "$repo-wt" add b; git -C "$repo-wt" commit -q -m work
  printf '%s\n' "$checks" > "$TMPROOT/gh-state/checks.json"
  local s; for s in "$@"; do eval "$s"; done
  # land runs in a command substitution; hand the reviewed commit out by file.
  git -C "$repo-wt" rev-parse HEAD > "$TMPROOT/land-head"
  GH_LOG="$TMPROOT/gh.log" GH_STATE="$TMPROOT/gh-state" AFK_FACTORY_GH_BIN="$GH" AFK_FACTORY_SKIP_PUSH=1 \
  AFK_FACTORY_CHECKS_SETTLE_SEC=0 AFK_FACTORY_CHECKS_POLL_SEC=1 AFK_FACTORY_CHECKS_TIMEOUT_SEC="${LAND_TIMEOUT:-5}" \
  bash -c '
    . "'"$KIT_ROOT"'/lib/afk-common.sh" 2>/dev/null
    . "'"$KIT_ROOT"'/lib/afk-paperclip.sh" 2>/dev/null
    . "'"$KIT_ROOT"'/lib/afk-factory.sh" 2>/dev/null
    _afk_factory_land_branch "$1" "$1-wt" factory/j1 j1 "Add b"
  ' _ "$repo"
}
PASSING='{"statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"StatusContext","state":"SUCCESS"}]}'
FAILING='{"statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]}'
PENDING='{"statusCheckRollup":[{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":null}]}'

L="$(land "$PASSING")"
assert_eq "With checks green the pull request is merged and the merge commit GitHub reports is recorded" \
  "$(jq -r '"\(.ok):\(.action):\(.commit)"' <<<"$L")" "true:merged_pr:abc123def456"
MERGE_LINE="$(grep '^pr merge' "$TMPROOT/gh.log")"
assert_contains "The merge names the reviewed commit, so a later push cannot ride along" "$MERGE_LINE" "--match-head-commit $(cat "$TMPROOT/land-head")"
assert_contains "The squash message is written explicitly, not assembled from branch commits" "$MERGE_LINE" "--subject Add b (#7) --body"

L="$(land "$FAILING")"
assert_eq "A failing check blocks the merge" \
  "$(jq -r '"\(.ok):\(.action)"' <<<"$L"):$(grep -c '^pr merge' "$TMPROOT/gh.log")" "false:checks_not_green:0"

L="$(land "$PENDING" 'printf "%s\n" "$PASSING" > "$TMPROOT/gh-state/checks-3.json"; cp "$TMPROOT/gh-state/checks-3.json" "$TMPROOT/gh-state/checks-4.json"')"
assert_eq "Checks still running are waited for, then the merge goes ahead" "$(jq -r '"\(.ok):\(.action)"' <<<"$L")" "true:merged_pr"

L="$(LAND_TIMEOUT=2 land "$PENDING")"
assert_eq "Checks that never finish block the merge when the wait runs out" \
  "$(jq -r '"\(.ok):\(.action)"' <<<"$L"):$(grep -c '^pr merge' "$TMPROOT/gh.log")" "false:checks_not_green:0"

L="$(land 'not json at all')"
assert_eq "Checks that cannot be read block the merge" "$(jq -r '.ok' <<<"$L"):$(grep -c '^pr merge' "$TMPROOT/gh.log")" "false:0"

L="$(land "$PASSING" ': > "$TMPROOT/gh-state/merged"; printf "[{\"url\":\"https://github.com/example/demo/pull/7\",\"number\":7,\"state\":\"MERGED\",\"headRefOid\":\"%s\"}]\n" "$(git -C "$repo-wt" rev-parse HEAD)" > "$TMPROOT/gh-state/list.json"')"
assert_eq "A pull request already merged is recognised: no second pull request, no second merge" \
  "$(jq -r '"\(.ok):\(.action)"' <<<"$L"):$(grep -c '^pr create' "$TMPROOT/gh.log"):$(grep -c '^pr merge' "$TMPROOT/gh.log")" "true:merged_pr:0:0"
L="$(land "$PASSING" 'printf "[{\"url\":\"https://github.com/example/demo/pull/6\",\"number\":6,\"state\":\"MERGED\",\"headRefOid\":\"0000000000000000000000000000000000000000\"}]\n" > "$TMPROOT/gh-state/list.json"')"
assert_eq "A pull request merged earlier at a different commit does not count as this round's merge" \
  "$(grep -c '^pr create' "$TMPROOT/gh.log"):$(grep -c '^pr merge' "$TMPROOT/gh.log")" "1:1"

L="$(land "$PASSING" ': > "$TMPROOT/gh-state/refuse-merge"')"
assert_eq "A merge GitHub refuses is reported as not merged" "$(jq -r '"\(.ok):\(.action)"' <<<"$L")" "false:pr_open"

L="$(LAND_ORIGIN='https://github.com/example' land "$PASSING")"
assert_eq "An origin that names GitHub but cannot be parsed stops the landing; it is not merged locally instead" \
  "$(jq -r '"\(.ok):\(.action)"' <<<"$L")" "false:remote_unreadable"

URLS="$(bash -c '
  . "'"$KIT_ROOT"'/lib/afk-common.sh" 2>/dev/null
  . "'"$KIT_ROOT"'/lib/afk-paperclip.sh" 2>/dev/null
  . "'"$KIT_ROOT"'/lib/afk-factory.sh" 2>/dev/null
  d="$1/url-probe"; mkdir -p "$d"; git -C "$d" init -q
  for u in "https://github.com/o/r.git" "https://github.com/o/r/" "git@github.com:o/r.git" \
           "ssh://git@github.com:22/o/r.git" "ssh://git@ssh.github.com:443/o/r.git" \
           "https://notgithub.com/o/r" "https://gitlab.com/o/r.git"; do
    git -C "$d" remote remove origin 2>/dev/null; git -C "$d" remote add origin "$u"
    printf "%s;" "$(_afk_factory_github_repo "$d")"
  done
' _ "$TMPROOT")"
assert_eq "GitHub origins are read in every common form, and look-alike hosts are not GitHub" "$URLS" "o/r;o/r;o/r;o/r;o/r;;;"

RLOC="$(new_repo r-local-land)"
O="$(run_job "$RLOC" side-branch R_BUILD=other-branch)"
assert_eq "Work committed on a different branch than the job's is not reported as merged, and its worktree is kept" \
  "$(field "$O" '.stage'):$([[ -d "$(field "$O" '.worktree_path')" ]] && printf kept || printf removed)" "needs-human:kept"

# ============================================================================
head1 "7b. Review fixes: stall cap, lock takeover, merge authority, approvals"
# ============================================================================
LIBS='. "'"$KIT_ROOT"'/lib/afk-common.sh" 2>/dev/null; . "'"$KIT_ROOT"'/lib/afk-paperclip.sh" 2>/dev/null; . "'"$KIT_ROOT"'/lib/afk-factory.sh" 2>/dev/null'

# A job that dies in the same stage every time is stopped after max_nudges,
# even though each rerun passes through earlier stages first.
RCAP="$(new_repo r-stallcap)"
orphan_in() { # <repo> <job> <stage>
  local r="$1" d="$1/.afk/jobs/$2"
  mkdir -p "$d/round-1" "$d/.run.lock"
  git -C "$r" worktree add -q -B "factory/$2" "$r-factory/$2" HEAD 2>/dev/null
  jq -cn --arg id "$2" --arg repo "$r" --arg wt "$r-factory/$2" --arg sha "$(git -C "$r" rev-parse HEAD)" --arg st "$3" \
    '{schema:"afk-factory-job/1", id:$id, slug:"r-stallcap", issue_id:null, title:"cap", repo_path:$repo, worktree_path:$wt, branch:("factory/" + $id), base_sha:$sha, base_branch:"main", stage:$st, round:1, risk:"low", surfaces:["code"]}' > "$d/job.json"
  printf 'VERDICT: ACCEPT\nRISK: low\nSURFACES: code\n' > "$d/intake.md"; printf '# Spec\n' > "$d/spec.md"
  printf '{"pid": 2147483000, "start": "x", "boot": "y", "host": "%s"}\n' "$(uname -n)" > "$d/.run.lock/owner.json"
}
# The checks kill the job's runner, as a pod being killed during the gate
# would. Every rerun builds again and then dies at the gate again. They are
# committed before the job branches: the gate runs the checks as committed
# on the job's base.
cat > "$RCAP/.afk/checks.sh" <<SH
#!/usr/bin/env bash
kill -9 "\$(jq -r .pid "$RCAP/.afk/jobs/dies-in-gate/.run.lock/owner.json")"
sleep 5
SH
git -C "$RCAP" commit -q -am "checks that kill their runner"
orphan_in "$RCAP" dies-in-gate gate
for _ in 1 2 3 4; do
  AFK_FACTORY_AGENT_RUNNER="$RUNNER" AFK_WATCHDOG_MAX_NUDGES=2 bash "$AFK" factory watchdog --repo "$RCAP" --json >/dev/null 2>&1
done
assert_eq "A job that keeps dying in the same stage goes to a person after max_nudges, though each rerun starts at build" \
  "$(jq -r '"\(.stage):\(.escalation_kind):\(.recovery.stage)"' "$RCAP/.afk/jobs/dies-in-gate/job.json")" "needs-human:stall:gate"
assert_eq "The watchdog leaves no heartbeat temp files behind" \
  "$(find "$RCAP/.afk/jobs/dies-in-gate" -name 'heartbeat.json.tmp.*' | wc -l | tr -d ' ')" "0"

# Several callers reclaiming one dead lock: exactly one wins each time.
RACE="$(bash -c "$LIBS"'
  wins=0
  for trial in $(seq 1 15); do
    d="$1/race-$trial"; mkdir -p "$d/.run.lock"
    printf "{\"pid\": 2147483000, \"start\": \"x\", \"boot\": \"y\"}\n" > "$d/.run.lock/owner.json"
    # A winner stays alive while the others try: a lock whose holder has
    # exited is rightly free to take.
    for c in 1 2 3 4; do ( _afk_factory_job_lock "$d" && { printf "w\n" >> "$d/wins"; sleep 2; } ) & done; wait
    [[ "$(wc -l < "$d/wins" 2>/dev/null | tr -d " ")" == 1 ]] && wins=$((wins + 1))
  done
  printf "%s" "$wins"
' _ "$TMPROOT")"
assert_eq "Four callers reclaiming one dead job lock: exactly one gets it, in 15 trials out of 15" "$RACE" "15"

FOREIGN="$(bash -c "$LIBS"'
  d="$1/foreign"; mkdir -p "$d"
  printf "{\"pid\": %s, \"start\": \"x\", \"boot\": \"y\", \"host\": \"some-other-pod\", \"last_beat_epoch\": %s}\n" "$$" "$(date -u +%s)" > "$d/owner.json"
  _afk_factory_runner_alive "$d/owner.json" && printf alive || printf dead
  printf ":"
  _afk_factory_runner_killable "$d/owner.json" && printf killable || printf not-killable
  printf ":"
  printf "{\"pid\": %s, \"boot\": \"\"}\n" "$$" > "$d/legacy.json"
  _afk_factory_runner_killable "$d/legacy.json" && printf killable || printf not-killable
  printf ":"
  _afk_factory_kill_tree "$BASHPID"; printf survived
' _ "$TMPROOT")"
assert_eq "A runner on another host with a fresh heartbeat counts as alive and is never signalled; a record without a start time is never signalled; the watchdog never kills itself" \
  "$FOREIGN" "alive:not-killable:not-killable:survived"

cat > "$AFK_PAPERCLIP_CONFIG" <<JSON
{"schema":"afk-paperclip-config/2","projects":[{"slug":"guarded","repo_path":"$R4","merge":"human"}]}
JSON
: > "$CALLS"
O="$(AFK_FACTORY_AGENT_RUNNER="$RUNNER" bash "$AFK" factory run --repo "$R4" --job no-slug-given --title "No slug" --json 2>/dev/null)"
assert_contains "A project's merge authority applies when the job is run by checkout, without its slug" "$(reasons "$O")" "merge authority is 'human'"
rm -f "$AFK_PAPERCLIP_CONFIG"

NEAR="$(bash -c "$LIBS"'
  for c in "**approve**" "approve 👍" "Approved, thanks" "lgtm!!" "Merge conflicts with main, please rebase first"; do
    a=n; _afk_factory_comment_is_approval "$c" && a=A
    q=n; _afk_factory_comment_is_near_approval "$c" && q=Q
    printf "%s%s " "$a" "$q"
  done')"
assert_eq "Markup and emoji around an approval still approve; a short approval-like comment gets a question; instructions stay instructions" \
  "$NEAR" "AQ AQ nQ AQ nn "

RNM="$(new_repo r-nothing)"
O="$(run_job "$RNM" approve-empty R_BUILD=nochange)"
L="$(bash -c "$LIBS"'; _afk_factory_land_branch "$1" "$2" "factory/approve-empty" approve-empty "x"' _ "$RNM" "$(field "$O" '.worktree_path')")"
assert_eq "Landing a branch that never moved from its base is refused, even after an approval" \
  "$(jq -r '"\(.ok):\(.action)"' <<<"$L")" "false:nothing_to_merge"

printf '#!/usr/bin/env bash\nprintf report > test-report.xml\n' > "$RNM/.afk/checks.sh"; git -C "$RNM" commit -q -am "checks that leave a report"
O="$(run_job "$RNM" leaves-report)"
assert_eq "A report file left behind by the checks does not block the merge" "$(field "$O" '.stage')" "merged"

# ============================================================================
head1 "7c. Second review: questions, foreign locks, Paperclip waits, symlinks"
# ============================================================================
Q="$(bash -c "$LIBS"'
  for c in "merge?" "Approve?" "Merge ???" "approve ❌" "approve 👎" "ship it?" "approve ✅" "LGTM."; do
    a=n; _afk_factory_comment_is_approval "$c" && a=A
    q=n; _afk_factory_comment_is_near_approval "$c" && q=Q
    printf "%s%s " "$a" "$q"
  done')"
assert_eq "A question or a thumbs-down is never an approval; it gets a question back. A check mark or full stop still approves" \
  "$Q" "nQ nQ nQ nQ nQ nQ AQ AQ "

FL="$(bash -c "$LIBS"'
  d="$1/foreign-job"; mkdir -p "$d/.run.lock"
  printf "{\"pid\": 1, \"start\": \"x\", \"boot\": \"y\", \"host\": \"pod-that-was-replaced\", \"token\": \"t\"}\n" > "$d/.run.lock/owner.json"
  jq -cn --argjson ep "$(( $(date -u +%s) - 5000 ))" "{last_beat_epoch: \$ep}" > "$d/heartbeat.json"
  touch -d "2 hours ago" "$d/.run.lock" "$d/.run.lock/owner.json" 2>/dev/null
  _afk_factory_job_lock "$d" && printf took || printf refused
  rm -rf "$d/.run.lock"; mkdir -p "$d/.run.lock"
  printf "{\"pid\": 1, \"start\": \"x\", \"boot\": \"y\", \"host\": \"pod-still-running\", \"token\": \"t\"}\n" > "$d/.run.lock/owner.json"
  jq -cn --argjson ep "$(date -u +%s)" "{last_beat_epoch: \$ep}" > "$d/heartbeat.json"
  printf ":"; _afk_factory_job_lock "$d" && printf took || printf refused
' _ "$TMPROOT")"
assert_eq "A lock held by another host is taken over once that job's heartbeat is stale, and refused while it is fresh" "$FL" "took:refused"

# Paperclip refusing the stage change: the stage does not start, the job
# waits, a dry run only reports it, and repeated refusals reach a person.
RPW="$(new_repo r-pcwait)"
PCW_BIN="$TMPROOT/pcwait-bin"; mkdir -p "$PCW_BIN"
cat > "$PCW_BIN/curl" <<'SH'
#!/usr/bin/env bash
# PATCH on an issue is refused; everything else answers 200 with an empty object.
method=GET; for a in "$@"; do case "$prev" in -X) method="$a" ;; esac; prev="$a"; done
url="${*: -1}"
for a in "$@"; do case "$a" in https://*) url="$a" ;; esac; done
if [[ "$method" == PATCH && "$url" == */api/issues/* ]]; then printf '409'; exit 0; fi
printf '{}\n200'
SH
chmod +x "$PCW_BIN/curl"
O="$(AFK_CURL_BIN="$PCW_BIN/curl" AFK_FACTORY_AGENT_RUNNER="$RUNNER" bash -c "$LIBS"'
  api_url=https://paperclip.example key=k issue_id=11111111-2222-4333-8444-555555555555 run_id="" host_agent_id=""
  job_dir="$1/.afk/jobs/pcw"; job_file="$job_dir/job.json"; mkdir -p "$job_dir"
  printf "{\"id\":\"pcw\",\"stage\":\"build\"}\n" > "$job_file"
  slug=r-pcwait job_id=pcw json_mode=false
  r1=0; _afk_factory_announce "$slug" dev "$issue_id" "note" "$api_url" "$key" "" || r1=$?
  printf "%s:%s:%s" "$r1" "$(jq -r .blocked_reason "$job_file")" "$(jq -r .blocked_count "$job_file")"
  for _ in 1 2; do AFK_FACTORY_PAPERCLIP_WAIT_MAX=2 _afk_factory_announce "$slug" dev "$issue_id" "note" "$api_url" "$key" "" >/dev/null 2>&1; done
  printf ":%s" "$(jq -r .stage "$job_file")"
' _ "$RPW" 2>/dev/null)"
assert_eq "A stage Paperclip refuses to show does not start and waits; after the wait limit the job goes to a person" \
  "$O" "1:paperclip_unreachable:1:needs-human"

mkdir -p "$RPW/.afk/jobs/waiting"
jq -cn --arg repo "$RPW" '{id:"waiting", slug:"r-pcwait", repo_path:$repo, stage:"build", round:1, blocked_reason:"paperclip_unreachable"}' > "$RPW/.afk/jobs/waiting/job.json"
touch -d '10 minutes ago' "$RPW/.afk/jobs/waiting/job.json" 2>/dev/null
: > "$CALLS"
WD="$(AFK_FACTORY_AGENT_RUNNER="$RUNNER" bash "$AFK" factory watchdog --repo "$RPW" --dry-run --json 2>/dev/null)"
assert_eq "A dry run reports a job waiting on Paperclip and starts nothing" \
  "$(jq -r '[.actions[] | select(.job_id == "waiting") | .action] | join(",")' <<<"$WD"):$(wc -l < "$CALLS" | tr -d ' ')" "would_retry_paperclip_wait:0"

LINKED="$TMPROOT/linked-repo"; ln -s "$R4" "$LINKED"
cat > "$AFK_PAPERCLIP_CONFIG" <<JSON
{"schema":"afk-paperclip-config/2","projects":[{"slug":"via-link","repo_path":"$LINKED","merge":"human"}]}
JSON
MP="$(bash -c "$LIBS"'; _afk_factory_project_merge_policy "" "$1"' _ "$R4")"
assert_eq "A project configured through a symlinked path is still found by its checkout" "$MP" "human"
rm -f "$AFK_PAPERCLIP_CONFIG"

# ============================================================================
head1 "7d. Third review: fresh foreign locks, config rows, strikethrough, outages"
# ============================================================================
FF="$(bash -c "$LIBS"'
  d="$1/fresh-foreign"; mkdir -p "$d/.run.lock"
  printf "{\"pid\":1,\"start\":\"x\",\"boot\":\"y\",\"host\":\"pod-a\",\"token\":\"t\",\"at\":\"%s\"}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$d/.run.lock/owner.json"
  jq -cn --argjson ep "$(( $(date -u +%s) - 4000 ))" "{last_beat_epoch: \$ep}" > "$d/heartbeat.json"
  _afk_factory_job_lock "$d" && printf stolen || printf kept
' _ "$TMPROOT")"
assert_eq "A lock another host took a moment ago is kept, even when the job heartbeat is old from an earlier wait" "$FF" "kept"

cat > "$AFK_PAPERCLIP_CONFIG" <<'JSON'
{"schema":"afk-paperclip-config/2","projects":[{"slug":"no-path","merge":"human"},{"slug":"no-merge"},{"slug":"empty-path","repo_path":"","merge":"human"},{"slug":"auto","merge":"pm"}]}
JSON
CR="$(bash -c "$LIBS"'; for x in no-path no-merge empty-path auto; do printf "%s " "$(_afk_factory_project_merge_policy "$x")"; done')"
assert_eq "A config row with an empty or missing field keeps its merge setting, and no setting means a person merges" "$CR" "human human human pm "
rm -f "$AFK_PAPERCLIP_CONFIG"

ST="$(bash -c "$LIBS"'; for c in "~~merge~~" "> approve"; do _afk_factory_comment_is_approval "$c" && printf A || printf n; done')"
assert_eq "A struck-out or quoted approval word is not an approval" "$ST" "nn"

OUT_BIN="$TMPROOT/outage-bin"; mkdir -p "$OUT_BIN"
printf '#!/usr/bin/env bash\nexit 7\n' > "$OUT_BIN/curl"; chmod +x "$OUT_BIN/curl"
OUTAGE="$(AFK_CURL_BIN="$OUT_BIN/curl" bash -c "$LIBS"'
  api_url=https://paperclip.example key=k issue_id=11111111-2222-4333-8444-555555555555 host_agent_id=""
  job_dir="$1/.afk/jobs/outage"; job_file="$job_dir/job.json"; mkdir -p "$job_dir"
  printf "{\"id\":\"outage\",\"stage\":\"build\"}\n" > "$job_file"
  slug=r-pcwait job_id=outage json_mode=false
  for _ in 1 2 3 4 5; do AFK_FACTORY_PAPERCLIP_WAIT_MAX=2 _afk_factory_announce "$slug" dev "$issue_id" "" "$api_url" "$key" "" >/dev/null 2>&1; done
  printf "%s:%s:%s" "$(jq -r .stage "$job_file")" "$(jq -r .blocked_reason "$job_file")" "$(jq -r ".blocked_count // 0" "$job_file")"
' _ "$RPW" 2>/dev/null)"
assert_eq "While Paperclip cannot be reached at all the job keeps waiting and is not stopped" "$OUTAGE" "build:paperclip_unreachable:0"

# ============================================================================
head1 "7e. Fourth review: watchdog and foreign locks, retries, malformed config"
# ============================================================================
RFW="$(new_repo r-foreign-wd)"
FD="$RFW/.afk/jobs/foreign-fresh"; mkdir -p "$FD/.run.lock"
jq -cn --arg repo "$RFW" '{id:"foreign-fresh", slug:"r-foreign-wd", repo_path:$repo, stage:"build", round:1}' > "$FD/job.json"
printf '{"pid":1,"start":"x","boot":"y","host":"pod-a","token":"t","at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$FD/.run.lock/owner.json"
jq -cn --argjson ep "$(( $(date -u +%s) - 4000 ))" '{pid:1, stage:"build", state:"running", last_beat_epoch:$ep}' > "$FD/heartbeat.json"
WD="$(bash "$AFK" factory watchdog --repo "$RFW" --stale-seconds 600 --dry-run --json 2>/dev/null)"
assert_eq "The watchdog leaves a lock another host took a moment ago alone, though the job heartbeat is old" \
  "$(jq -r '[.actions[] | select(.job_id == "foreign-fresh") | .action] | join(",")' <<<"$WD")" "healthy_running"

RSEED="$(bash -c "$LIBS"'
  d="$1/seed"; mkdir -p "$d"
  printf "{\"id\":\"seed\",\"stage\":\"build\",\"round\":1,\"recovery\":null}\n" > "$d/job.json"
  printf "{\"stage\":\"build\",\"nudge_count\":3}\n" > "$d/heartbeat.json"
  jq -e "has(\"recovery\")" "$d/job.json" >/dev/null && printf told-to-retry || printf legacy
' _ "$TMPROOT")"
assert_eq "A job the board told to retry is recognised as such, not as a job carrying an old recovery count" "$RSEED" "told-to-retry"

cat > "$AFK_PAPERCLIP_CONFIG" <<'JSON'
{"schema":"afk-paperclip-config/2","projects":["junk",{"slug":"after-junk","merge":"human"},{"slug":"odd-merge","merge":{"x":1}}]}
JSON
MC="$(bash -c "$LIBS"'; for x in after-junk odd-merge; do printf "%s " "$(_afk_factory_project_merge_policy "$x")"; done')"
printf '{"projects":[' > "$AFK_PAPERCLIP_CONFIG"
MC2="$(bash -c "$LIBS"'; _afk_factory_project_merge_policy anything')"
rm -f "$AFK_PAPERCLIP_CONFIG"
assert_eq "A malformed config row does not hide the projects after it, an odd merge value means a person merges, and an unreadable config means a person merges" \
  "$MC|$MC2" "human human |human"

# ============================================================================
head1 "8. Limits that keep a stage from failing every agent in turn"
# ============================================================================
CAP="$(bash -c '
  . "'"$KIT_ROOT"'/lib/afk-common.sh" 2>/dev/null
  . "'"$KIT_ROOT"'/lib/afk-paperclip.sh" 2>/dev/null
  . "'"$KIT_ROOT"'/lib/afk-factory.sh" 2>/dev/null
  f="$1/big-prompt.md"; head -c 300000 /dev/zero | tr "\0" "a" > "$f"
  out="$(_afk_factory_prompt_text "$f")"
  printf "%s:%s" "$(( ${#out} < 131072 ))" "$(grep -c "prompt was cut here" <<<"$out")"
  printf "small prompt\n" > "$f"
  printf ":%s" "$(_afk_factory_prompt_text "$f")"
' _ "$TMPROOT")"
assert_eq "A prompt too long for one command-line argument is cut to fit and says so; a short one is untouched" \
  "$CAP" "1:1:small prompt"

# ============================================================================
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
