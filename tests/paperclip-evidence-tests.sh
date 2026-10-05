#!/usr/bin/env bash
# paperclip-evidence-tests.sh — the content snapshot and the write-once
# attempt, launch and outcome evidence of a Paperclip dispatch
# (lib/afk-paperclip-evidence.sh), route-accept's tuple and attempt
# allocation (lib/afk-accept.sh), and dispatch.sh's producer boundary. Offline:
# dispatch.sh is sourced or run with stubs, no harness runs, no network.
#
# Usage: tests/paperclip-evidence-tests.sh
# Exit:  0 all passed, 1 any failure.

set -uo pipefail

KIT_ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
AFK="$KIT_ROOT/bin/agent-flow-kit"
DISPATCH="$KIT_ROOT/files/model-router/scripts/dispatch.sh"
TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@test GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@test
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

PASS=0 FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; FAIL=$((FAIL + 1)); }
head1() { printf '\n\033[1m%s\033[0m\n' "$1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
assert_ne() { if [[ "$2" != "$3" && -n "$2" && -n "$3" ]]; then ok "$1"; else bad "$1" "both were '$2'"; fi; }
sha() { sha256sum | cut -d' ' -f1; }

ISSUE="e1111111-1111-1111-1111-111111111111"
COMMIT="d554c4789ed3930f8a53ac9fdf6503b3187097da"
PLAND="$(printf 'p' | sha)"
HOME_DIR="$TMPROOT/home"; STATE="$TMPROOT/state"; CONFIG="$TMPROOT/paperclip.json"
mkdir -p "$HOME_DIR" "$STATE/paperclip/plans" "$STATE/paperclip/approvals"
jq -nc --arg c "$COMMIT" --arg r "$TMPROOT" \
  '{schema:"afk-paperclip-config/2",api_url:"https://paperclip.test",company_id:"cccccccc-cccc-cccc-cccc-cccccccccccc",
    board_user_id:"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
    host:{label:"h",agent_id:"11111111-1111-1111-1111-111111111111",key_ref:"op://x/y"},
    projects:[{paperclip_project_id:"aaaaaaaa-0000-4000-8000-000000000001",slug:"proj1",repo_path:$r,harness:"claude"}],
    interim_comment_approval:{attested_on:"2026-09-27",paperclip_commit:$c}}' >"$CONFIG"
jq -nc --arg d "$PLAND" '{schema:"afk-paperclip-plan-record/1", digest:$d,
  stories:[range(1; 12) | {id:"HOM-12.S\(.)", gates:["bash tests/a.sh","bash tests/b.sh"]}]}' >"$STATE/paperclip/plans/$ISSUE.json"
approve() { jq -nc --arg d "$PLAND" --arg c "$COMMIT" \
  '{schema:"afk-paperclip-approval/1",kind:"plan",digest:$d,paperclip_commit:$c}' >"$STATE/paperclip/approvals/$ISSUE.json"; }
export HOME="$HOME_DIR" AFK_STATE_DIR="$STATE" AFK_PAPERCLIP_CONFIG="$CONFIG"
approve

# new_story <dir> <name> <story_id> [<stamp-jq-edit>] [<frontmatter>] -> story path
new_story() {
  local s="$1/$2.md"
  printf -- '---\n%s\ngates:\n  - "bash tests/a.sh"\n  - "bash tests/b.sh"\n---\n# story\n' "${5-home: paperclip:HOM-12
paperclip_issue: $ISSUE}" >"$s"
  jq -n --arg sid "$3" '{harness:"claude", model_profile:"local-code-standard", effort:"medium", cost_class:"free",
          metered:false, catalog_version:"sha256:abc", placement_required:false,
          task:{story_id:$sid, tags:["tests"]}, override:null}' | jq "${4:-.}" >"$s.stamp.json"
  printf '%s' "$s"
}
RC=0 OUT=""
accept() { OUT="$(bash "$AFK" route-accept --json "$@" 2>"$TMPROOT/err" </dev/null)"; RC=$?; }
ev() { OUT="$(bash "$AFK" paperclip-evidence "$@" 2>"$TMPROOT/err" </dev/null)"; RC=$?; }
ev_in() { local in="$1"; shift; OUT="$(printf '%s' "$in" | bash "$AFK" paperclip-evidence "$@" 2>"$TMPROOT/err")"; RC=$?; }
res() { jq -r .result <<<"$OUT" 2>/dev/null; }
jf() { jq -r "$1" <<<"$OUT" 2>/dev/null; }
adir() { printf '%s' "$STATE/paperclip/attempts/$ISSUE/$1"; }
latest() { ev latest --issue "$ISSUE" --story-id "$1" --json; }
snap() { bash "$AFK" paperclip-evidence snapshot --dir "$1" 2>/dev/null </dev/null; }
tree_of() { snap "$1" | jq -r '.tree // empty'; }
index_sum() { local p; p="$(git -C "$1" rev-parse --git-path index)"; [[ "$p" == /* ]] || p="$1/$p"; sha <"$p"; }
count_accepts() { find "$(adir "$1")" -maxdepth 1 -name '*.accept.json' ! -name '.*' 2>/dev/null | wc -l | tr -d ' '; }

head1 "1. Snapshot: content identity of the product tree, never a write"
R="$TMPROOT/repo"; git init -q "$R"; mkdir -p "$R/docs"
printf 'a\n' >"$R/a.txt"; printf 'tracked\n' >"$R/docs/x.md.result.json"; printf '*.log\n' >"$R/.gitignore"
# The private artifact scope is .pm-brief/, ignored through the exclude file
# every worktree of the repository shares, as in the real workflow.
printf '.pm-brief/\n' >>"$R/.git/info/exclude"
git -C "$R" add -A; git -C "$R" commit -qm base
W2="$TMPROOT/wt2"; git -C "$R" worktree add -q --detach "$W2" HEAD
for d in "$R" "$W2"; do printf 'b\n' >>"$d/a.txt"; printf 'new product\n' >"$d/new.txt"; mkdir -p "$d/.pm-brief"; done
# Each session has its own, different, private specs, stories and sidecars.
printf -- '---\nx: 1\n---\n' >"$R/.pm-brief/story-a.md"; printf 'spec\n' >"$R/.pm-brief/spec-a.md"
for f in prompt result.json checkpoint.json acceptance.json stamp.json; do printf '{}\n' >"$R/.pm-brief/story-a.md.$f"; done
printf -- '---\ny: 2\n---\n' >"$W2/.pm-brief/story-b.md"
for f in prompt continuation.json blocked result.c3.json verdict.json; do printf 'z\n' >"$W2/.pm-brief/story-b.md.$f"; done
mkdir -p "$W2/.pm-brief/story-b.md.context-events"; printf '{}\n' >"$W2/.pm-brief/story-b.md.context-events/1.json"
ST1="$(git -C "$R" status --porcelain=v1 -uall | sha)"; H1="$(git -C "$R" rev-parse HEAD)"
I1="$(index_sum "$R")"; I1B="$(index_sum "$W2")"; F1="$(sha <"$R/a.txt")"
S1="$(snap "$R")"; S2="$(snap "$W2")"
assert_eq "same dirty product tree, different private artifacts -> same tree" "$(jq -r .tree <<<"$S1")" "$(jq -r .tree <<<"$S2")"
assert_eq "snapshot shape: afk-snapshot/1 with HEAD as base_commit" "$(jq -r '[.schema, .base_commit] | join(" ")' <<<"$S1")" "afk-snapshot/1 $H1"
T0="$(jq -r .tree <<<"$S1")"
assert_eq "the tree holds tracked edits, untracked product files and the sidecar-named tracked file, nothing private" \
  "$(git -C "$R" ls-tree -r --name-only "$T0" | paste -sd, -)" ".gitignore,a.txt,docs/x.md.result.json,new.txt"
assert_eq "the tree carries the dirty content" "$(git -C "$R" cat-file -p "$T0:a.txt" | paste -sd, -)" "a,b"
assert_eq "real index, HEAD, status and worktree files unchanged" \
  "$(index_sum "$R") $(index_sum "$W2") $(git -C "$R" rev-parse HEAD) $(git -C "$R" status --porcelain=v1 -uall | sha) $(sha <"$R/a.txt")" \
  "$I1 $I1B $H1 $ST1 $F1"
printf 'more\n' >>"$R/new.txt"
assert_ne "an untracked product edit changes the snapshot" "$(tree_of "$R")" "$T0"
printf 'new product\n' >"$R/new.txt"
assert_eq "...and restoring it restores the same tree (deterministic)" "$(tree_of "$R")" "$T0"
# The real index's assume-unchanged bit must not hide worktree bytes.
git -C "$R" update-index --assume-unchanged a.txt; IA="$(index_sum "$R")"
assert_eq "an assume-unchanged path is snapshotted from its worktree bytes, not HEAD" "$(tree_of "$R")" "$T0"
printf 'hidden\n' >>"$R/a.txt"
assert_ne "...an edit behind assume-unchanged changes the snapshot" "$(tree_of "$R")" "$T0"
assert_eq "...and the real index is left exactly as it was" "$(index_sum "$R")" "$IA"
printf 'a\nb\n' >"$R/a.txt"; git -C "$R" update-index --no-assume-unchanged a.txt
printf 'changed\n' >"$R/docs/x.md.result.json"
assert_ne "a tracked file named like a sidecar is product: its edit changes the snapshot" "$(tree_of "$R")" "$T0"
printf 'tracked\n' >"$R/docs/x.md.result.json"
printf 'noise\n' >"$R/debug.log"
assert_eq "an ignored file is outside the snapshot (documented limit)" "$(tree_of "$R")" "$T0"
printf 'forced\n' >"$R/forced.log"; git -C "$R" add -f forced.log
assert_eq "an ignored file force-staged in the real index is tracked content: it is in the snapshot" \
  "$(git -C "$R" ls-tree -r --name-only "$(tree_of "$R")" forced.log)" "forced.log"
git -C "$R" rm -q --cached forced.log; rm -f "$R/forced.log"
mkdir -p "$W2/_bmad-output"; printf 'spec\n' >"$W2/_bmad-output/spec-x.md"
assert_ne "a spec left outside the private scope in one worktree is product: the trees differ" "$(tree_of "$W2")" "$T0"
rm -rf "$W2/_bmad-output"
printf 'doc\n' >"$W2/guide.md"; printf '{}\n' >"$W2/guide.md.prompt"; printf '{}\n' >"$W2/x.stamp.json"
mkdir -p "$W2/guide.md.context-events"; printf '{}\n' >"$W2/guide.md.context-events/1.json"
assert_eq "no exclusion is inferred from a name: sidecar-looking files outside the scope are all product" \
  "$(git -C "$W2" ls-tree -r --name-only "$(tree_of "$W2")" | grep -c -e '^guide\.md' -e '^x\.stamp\.json$')" "4"
rm -rf "$W2/guide.md" "$W2/guide.md.prompt" "$W2/x.stamp.json" "$W2/guide.md.context-events"; printf 'c\n' >>"$W2/a.txt"
assert_ne "a reviewer's edit changes the snapshot" "$(tree_of "$W2")" "$T0"
mkdir -p "$TMPROOT/notgit"
ev snapshot --dir "$TMPROOT/notgit" --json
assert_eq "no repository -> SNAPSHOT_FAILED, exit 1, never a tree" "$(res) $RC" "SNAPSHOT_FAILED 1"
N="$TMPROOT/nohead"; git init -q "$N"; printf 'f\n' >"$N/f"
assert_eq "a repository with no commit -> base_commit null, content still hashed" \
  "$(snap "$N" | jq -r '[.base_commit, (.tree | length)] | map(tostring) | join(" ")')" "null 40"

head1 "2. Acceptance tuple and attempt allocation"
SD="$TMPROOT/stories"; mkdir -p "$SD"
S="$(new_story "$SD" a1 HOM-12.S1)"
accept --story "$S" --kind pm-auto --actor pm
assert_eq "pm-auto accepted, attempt 1 reported" "$(res) $RC $(jf .attempt)" "ok 0 1"
REC="$(adir HOM-12.S1)/1.accept.json"
WANT="$(jq -ncS --arg i "$ISSUE" --arg dd "$(jq -r .decision_digest "$S.acceptance.json")" --arg pd "$PLAND" \
  --arg ps "sha256:$(jq -cS '.stories[] | select(.id == "HOM-12.S1")' "$STATE/paperclip/plans/$ISSUE.json" | sha)" \
  --arg st "sha256:$(sha <"$S.stamp.json")" \
  '{issue:$i, story_id:"HOM-12.S1", decision_digest:$dd, plan_digest:$pd, plan_story_sha256:$ps, stamp_sha256:$st}')"
assert_eq "attempt record: schema, kind, number and the tuple captured at acceptance" \
  "$(jq -cS '[.schema, .kind, .attempt, .tuple]' "$REC")" "$(jq -cS --argjson t "$WANT" -n '["afk-paperclip-attempt/1","accept",1,$t]')"
accept --story "$S" --verify
assert_eq "--verify ok carries the same tuple" "$(res) $(jq -cS .tuple <<<"$OUT")" "ok $WANT"
rm -f "$STATE/paperclip/approvals/$ISSUE.json"; accept --story "$S" --verify
assert_eq "a refused --verify carries no tuple" "$(res) $RC $(jf .tuple)" "PLAN_NOT_APPROVED 4 null"
approve
accept --story "$S" --kind pm-auto --actor pm
assert_eq "a second acceptance allocates attempt 2" "$(jf .attempt) $(count_accepts HOM-12.S1)" "2 2"
M="$(new_story "$SD" met HOM-12.S1 '.metered = true')"
accept --story "$M" --kind pm-auto --actor pm
assert_eq "a pre-acceptance routing refusal creates no attempt" "$(res) $(count_accepts HOM-12.S1)" "PM_AUTO_NOT_FREE 2"
rm -f "$STATE/paperclip/approvals/$ISSUE.json"; accept --story "$S" --kind pm-auto --actor pm; approve
assert_eq "an unapproved plan creates no attempt" "$(res) $(count_accepts HOM-12.S1)" "PLAN_NOT_APPROVED 2"
H="$(new_story "$SD" hum AFK-X '.cost_class = "subscription"' 'persona: dev')"
BEFORE="$(find "$STATE/paperclip/attempts" -type f | wc -l | tr -d ' ')"
accept --story "$H" --kind human --actor josh
assert_eq "a non-Paperclip human acceptance: written as before, no attempt" \
  "$(res) $RC $(jf .attempt) $(find "$STATE/paperclip/attempts" -type f | wc -l | tr -d ' ')" "ok 0 null $BEFORE"
D2="$(adir HOM-12.S2)"; mkdir -p "$D2"
for n in 9 10; do jq --argjson n "$n" '.attempt = $n | .story_id = "HOM-12.S2" | .tuple.story_id = "HOM-12.S2"' "$REC" >"$D2/$n.accept.json"; done
printf 'x' >"$D2/010.accept.json"; printf 'x' >"$D2/.tmp.1.2.99.accept.json"
accept --story "$(new_story "$SD" n2 HOM-12.S2)" --kind pm-auto --actor pm
assert_eq "allocation is numeric: after 9 and 10 comes 11 (padded and temp names ignored)" "$(jf .attempt)" "11"
latest HOM-12.S2
assert_eq "latest selects 11 over 9 and 10, never a lexical order" "$(jf '[.state, .attempt, (.attempts | map(tostring) | join(","))] | join(" ")')" "ATTEMPT_NOT_LAUNCHED 11 9,10,11"
for i in 1 2 3 4 5 6; do new_story "$SD" "par$i" HOM-12.S3 >/dev/null; done
for i in 1 2 3 4 5 6; do
  ( bash "$AFK" route-accept --json --story "$SD/par$i.md" --kind pm-auto --actor pm >"$TMPROOT/par.$i" 2>/dev/null </dev/null ) &
done
wait
assert_eq "six concurrent acceptances: six distinct attempts 1..6" \
  "$(for i in 1 2 3 4 5 6; do jq -r .attempt "$TMPROOT/par.$i"; done | sort -n | paste -sd, -)" "1,2,3,4,5,6"
assert_eq "...each record complete, none overwritten, no temp file left" \
  "$(for n in 1 2 3 4 5 6; do jq -r --argjson n "$n" 'select(.attempt == $n) | .kind' "$(adir HOM-12.S3)/$n.accept.json"; done | paste -sd, -) $(find "$(adir HOM-12.S3)" -name '.tmp.*' | wc -l | tr -d ' ')" \
  "accept,accept,accept,accept,accept,accept 0"

head1 "3. Launch and outcome records: linkage, write-once, approval binding"
S="$(new_story "$SD" l4 HOM-12.S4)"; accept --story "$S" --kind pm-auto --actor pm
TUP="$(bash "$AFK" route-accept --story "$S" --verify --json 2>/dev/null </dev/null | jq -c .tuple)"
SNAP="$(snap "$R")"; D4="$(adir HOM-12.S4)"
LIN="$(jq -nc --argjson t "$TUP" --argjson s "$SNAP" '{tuple:$t, snapshot:$s}')"
ev_in "$LIN" launch --story "$S" --cycle 1 --dispatch-id dispatch:one --json
assert_eq "launch recorded under the newest attempt" "$(res) $RC $(jf .attempt) $(jf .cycle)" "ok 0 1 1"
assert_eq "launch record: dispatch id, tuple, accept_tuple_match, launch snapshot" \
  "$(jq -c '[.kind, .dispatch_id, (.tuple == $t), .accept_tuple_match, .snapshot.tree == $s.tree]' --argjson t "$TUP" --argjson s "$SNAP" "$D4/1.c1.launch.json")" \
  '["launch","dispatch:one",true,true,true]'
latest HOM-12.S4
assert_eq "launched without an outcome -> ATTEMPT_UNFINISHED" "$(jf .state) $(jf .cycle)" "ATTEMPT_UNFINISHED 1"
L1="$(sha <"$D4/1.c1.launch.json")"
ev_in "$LIN" launch --story "$S" --cycle 1 --dispatch-id dispatch:other --json
assert_eq "a duplicate launch for the same cycle is refused, the record untouched" "$(res) $RC $(sha <"$D4/1.c1.launch.json")" "LAUNCH_DUPLICATE 4 $L1"
ev_in "$(jq -c '.tuple.plan_digest = ("0" * 64)' <<<"$LIN")" launch --story "$S" --cycle 2 --dispatch-id dispatch:two --json
assert_eq "a launch tuple that differs from the verified one -> TUPLE_CHANGED, nothing written" \
  "$(res) $RC $([[ -e "$D4/1.c2.launch.json" ]] && echo W)" "TUPLE_CHANGED 4 "
ev_in 'not json' launch --story "$S" --cycle 2 --dispatch-id dispatch:two --json
assert_eq "malformed launch input -> EVIDENCE_INPUT_INVALID" "$(res) $RC" "EVIDENCE_INPUT_INVALID 4"
ev_in "$(jq -c '.snapshot = {schema:"afk-snapshot/1", tree:"zz"}' <<<"$LIN")" launch --story "$S" --cycle 2 --dispatch-id dispatch:two --json
assert_eq "a malformed snapshot -> EVIDENCE_INPUT_INVALID" "$(res)" "EVIDENCE_INPUT_INVALID"
ev launch --story "$S" --cycle 01 --dispatch-id dispatch:two --json
assert_eq "a non-canonical cycle number -> EVIDENCE_ARGS_INVALID" "$(res) $RC" "EVIDENCE_ARGS_INVALID 1"
RESULT="$(jq -n '{story:"l4.md", cycle:1, status:"done", launch:{dispatch_id:"dispatch:one"},
  gates:{"bash tests/a.sh":"pass","bash tests/b.sh":"pass"}}')"
oin() { printf '%s\n' "$1" | jq -Rsc --argjson t "${2:-$TUP}" --argjson s "$SNAP" '{tuple:$t, snapshots:{gate_pre:$s, gate_post:$s}, result_text:.}'; }
ev_in "$(oin "$(jq '.cycle = 2' <<<"$RESULT")")" outcome --story "$S" --attempt 1 --cycle 2 --dispatch-id dispatch:one --json
assert_eq "an outcome with no launch -> LAUNCH_MISSING" "$(res) $RC" "LAUNCH_MISSING 4"
ev_in "$(oin "$(jq '.launch.dispatch_id = "dispatch:two"' <<<"$RESULT")")" outcome --story "$S" --attempt 1 --cycle 1 --dispatch-id dispatch:two --json
assert_eq "an outcome from another dispatch -> LAUNCH_FOREIGN" "$(res) $RC" "LAUNCH_FOREIGN 4"
ev_in "$(oin "$RESULT" "$(jq -c '.stamp_sha256 = "sha256:" + ("1" * 64)' <<<"$TUP")")" outcome --story "$S" --attempt 1 --cycle 1 --dispatch-id dispatch:one --json
assert_eq "an outcome carrying a tuple other than the launch's -> LAUNCH_FOREIGN" "$(res)" "LAUNCH_FOREIGN"
ev_in "$(oin "$(jq '.launch.dispatch_id = "dispatch:x"' <<<"$RESULT")")" outcome --story "$S" --attempt 1 --cycle 1 --dispatch-id dispatch:one --json
assert_eq "a result not produced by this dispatch -> RESULT_INVALID" "$(res) $RC" "RESULT_INVALID 4"
ev_in "$(jq -c '.result_text = "{\"status\":"' <<<"$(oin "$RESULT")")" outcome --story "$S" --attempt 1 --cycle 1 --dispatch-id dispatch:one --json
assert_eq "result bytes that are not one JSON object -> RESULT_INVALID" "$(res)" "RESULT_INVALID"
assert_eq "...and no refusal wrote an outcome" "$(find "$D4" -name '*.outcome.json' | wc -l | tr -d ' ')" "0"
ev_in "$(oin "$RESULT")" outcome --story "$S" --attempt 1 --cycle 1 --dispatch-id dispatch:one --json
assert_eq "outcome recorded" "$(res) $RC $(jf .outcome)" "ok 0 RECORDED"
assert_eq "outcome: canonical bytes hashed, status, gates, snapshots linked to the launch" \
  "$(jq -c '[.result_sha256, .status, .gates_ok, .gate_count, .snapshots.launch.tree == .snapshots.gate_post.tree, .approval_reason]' "$D4/1.c1.outcome.json")" \
  "[\"sha256:$(printf '%s\n' "$RESULT" | sha)\",\"done\",true,2,true,null]"
O1="$(sha <"$D4/1.c1.outcome.json")"
ev_in "$(oin "$(jq '.status = "gates_failed"' <<<"$RESULT")")" outcome --story "$S" --attempt 1 --cycle 1 --dispatch-id dispatch:one --json
assert_eq "a second outcome is refused and never replaces the first" "$(res) $RC $(sha <"$D4/1.c1.outcome.json")" "OUTCOME_DUPLICATE 4 $O1"
latest HOM-12.S4
assert_eq "latest: OUTCOME_RECORDED, done, gates passed" "$(jf '[.state, .outcome, .status, .gates_ok, .attempt, .cycle] | map(tostring) | join(" ")')" "OUTCOME_RECORDED RECORDED done true 1 1"
accept --story "$S" --kind pm-auto --actor pm
latest HOM-12.S4
assert_eq "a newer accepted, unlaunched attempt is surfaced, the older success is not selected" "$(jf .state) $(jf .attempt)" "ATTEMPT_NOT_LAUNCHED 2"
ev_in "$LIN" launch --story "$S" --cycle 2 --dispatch-id dispatch:c2 --json
latest HOM-12.S4
assert_eq "a continuation cycle under the new attempt, no outcome -> ATTEMPT_UNFINISHED" "$(jf .state) $(jf .attempt) $(jf .cycle)" "ATTEMPT_UNFINISHED 2 2"
ev_in "$LIN" launch --story "$S" --cycle 1 --dispatch-id dispatch:back --json
assert_eq "a launch below the newest launched cycle -> CYCLE_OUT_OF_ORDER, nothing written" \
  "$(res) $RC $(jf .newest_cycle) $([[ -e "$D4/2.c1.launch.json" ]] && echo W)" "CYCLE_OUT_OF_ORDER 4 2 "
rm -f "$STATE/paperclip/approvals/$ISSUE.json"
ev_in "$(oin "$(jq '.cycle = 2 | .launch.dispatch_id = "dispatch:c2"' <<<"$RESULT")")" outcome --story "$S" --attempt 2 --cycle 2 --dispatch-id dispatch:c2 --json
approve
assert_eq "approval withdrawn mid-cycle -> APPROVAL_CHANGED recorded with the reason" \
  "$(res) $(jf .outcome) $(jq -r '.approval_reason' "$D4/2.c2.outcome.json")" "ok APPROVAL_CHANGED PLAN_NOT_APPROVED"
latest HOM-12.S4
assert_eq "a re-approval afterwards does not turn it into the original approval" "$(jf .outcome) $(jf .status)" "APPROVAL_CHANGED done"
accept --story "$S" --kind pm-auto --actor pm
ev_in "$LIN" launch --story "$S" --cycle 3 --dispatch-id dispatch:c3 --json
jq '.expires_at = "2099-01-01T00:00:00Z"' "$S.stamp.json" >"$S.t" && mv "$S.t" "$S.stamp.json"
ev_in "$(oin "$(jq '.cycle = 3 | .launch.dispatch_id = "dispatch:c3"' <<<"$RESULT")")" outcome --story "$S" --attempt 3 --cycle 3 --dispatch-id dispatch:c3 --json
assert_eq "the stamp changed mid-cycle (decision digest unchanged) -> APPROVAL_CHANGED" \
  "$(jf .outcome) $(jq -r '[.approval_reason, (.tuple_at_outcome.stamp_sha256 != .tuple.stamp_sha256)] | map(tostring) | join(" ")' "$D4/3.c3.outcome.json")" \
  "APPROVAL_CHANGED TUPLE_DIFFERS true"
# Attempt 3 was accepted under the old stamp; --verify still passes on the
# new one (decision digest unchanged), so its tuple differs from attempt 3's.
TUP2="$(bash "$AFK" route-accept --story "$S" --verify --json 2>/dev/null </dev/null | jq -c .tuple)"
ev_in "$(jq -nc --argjson t "$TUP2" --argjson s "$SNAP" '{tuple:$t, snapshot:$s}')" launch --story "$S" --cycle 4 --dispatch-id dispatch:c4 --json
assert_eq "a launch under a tuple other than the accepted one is recorded with accept_tuple_match false" \
  "$(res) $(jf .attempt) $(jq -r .accept_tuple_match "$D4/3.c4.launch.json" 2>/dev/null)" "ok 3 false"
latest HOM-12.S4
assert_eq "...and latest surfaces accept_tuple_match false" "$(jf .state) $(jf .cycle) $(jf .accept_tuple_match)" "ATTEMPT_UNFINISHED 4 false"
ev_in "$(oin "$(jq -c '.cycle = 4 | .launch.dispatch_id = "dispatch:c4" | .gates = {}' <<<"$RESULT")" "$TUP2")" \
  outcome --story "$S" --attempt 3 --cycle 4 --dispatch-id dispatch:c4 --json
assert_eq "an empty gate map (gates skipped by a control) records gates_ok false, never vacuously true" \
  "$(res) $(jq -r '[.outcome, .gates_ok, .gate_count] | map(tostring) | join(" ")' "$D4/3.c4.outcome.json" 2>/dev/null)" "ok RECORDED false 0"
ev latest --issue "../../etc" --story-id HOM-12.S4 --json
assert_eq "an unsafe issue id -> EVIDENCE_ARGS_INVALID" "$(res) $RC" "EVIDENCE_ARGS_INVALID 1"
ev latest --issue "$ISSUE" --story-id "HOM-12.S4/../x" --json
assert_eq "an unsafe story id -> EVIDENCE_ARGS_INVALID" "$(res) $RC" "EVIDENCE_ARGS_INVALID 1"
mkdir -p "$TMPROOT/elsewhere"; ln -s "$TMPROOT/elsewhere" "$(adir HOM-12.S7)"
S7="$(new_story "$SD" s7 HOM-12.S7)"; accept --story "$S7" --kind pm-auto --actor pm
assert_eq "a symlinked attempt directory -> ATTEMPT_RECORD_FAILED, no acceptance, nothing written through it" \
  "$(res) $RC $([[ -e "$S7.acceptance.json" ]] && echo A) $(find "$TMPROOT/elsewhere" -type f | wc -l | tr -d ' ')" "ATTEMPT_RECORD_FAILED 1  0"
mkdir -p "$(adir HOM-12.S8)"; printf '{"schema":' >"$(adir HOM-12.S8)/1.accept.json"
latest HOM-12.S8
assert_eq "a malformed newest record -> RECORD_INVALID, never skipped" "$(jf .state) $(jf .record)" "RECORD_INVALID accept"
latest HOM-12.S9
assert_eq "no attempt at all -> STORY_EVIDENCE_MISSING" "$(res) $RC $(jf .state)" "ok 0 STORY_EVIDENCE_MISSING"

head1 "4. dispatch.sh producer boundary (real functions, sourced)"
P="$TMPROOT/prod"; git init -q "$P"; printf 'base\n' >"$P/p.txt"; git -C "$P" add -A; git -C "$P" commit -qm base
printf '.pm-brief/\n' >>"$P/.git/info/exclude"; PB="$P/.pm-brief"; mkdir -p "$PB"
cat >"$TMPROOT/producer.sh" <<'EOF'
# main()'s evidence order with the real dispatch.sh functions: preconditions,
# launch record, gates with snapshots, the thin result from memory.
. "$1"; CONFIG_FILE=/nonexistent; S="$2"; DID="$3"; shift 3
PAPERCLIP_STORY=false PAPERCLIP_TUPLE_JSON="" PAPERCLIP_ATTEMPT="" PAPERCLIP_GATE_PRE=null PAPERCLIP_GATE_POST=null
if paperclip_story_marked "$S" "$S.stamp.json"; then paperclip_preconditions "$S" || exit 4; PAPERCLIP_STORY=true; fi
paperclip_record_launch "$S" 1 "$DID" || exit 4
run_gates_with_evidence "" "$@"
G="$(for k in "${!GATE_RESULTS[@]}"; do jq -n --arg k "$k" --arg v "${GATE_RESULTS[$k]}" '{($k):$v}'; done | jq -s 'add // {}')"
R="$(jq -n --arg s "$S" --arg d "$DID" --arg ok "$GATES_OK" --argjson g "$G" \
  '{story:$s, cycle:1, status:(if $ok == "true" then "done" else "gates_failed" end), launch:{dispatch_id:$d}, gates:$g}')"
publish_thin_result "$S" 1 "$R"
echo "ATTEMPT=$PAPERCLIP_ATTEMPT"
EOF
produce() { # <afk-bin> <story> <dispatch-id> <gate...>
  local bin="$1"; shift
  OUT="$(cd "$P" && AGENT_FLOW_KIT_BIN="$bin" bash "$TMPROOT/producer.sh" "$DISPATCH" "$@" 2>"$TMPROOT/err" </dev/null)"; RC=$?
}
S6="$(new_story "$PB" prod HOM-12.S6)"; accept --story "$S6" --kind pm-auto --actor pm
printf '{"status":"done","planted":true}\n' >"$S6.result.json"
produce "$AFK" "$S6" dispatch:prod 'printf x >>p.txt' true
O6="$(adir HOM-12.S6)/1.c1.outcome.json"
assert_eq "a canonical Paperclip cycle records launch and outcome" "$RC $OUT $(jq -r .outcome "$O6" 2>/dev/null)" "0 ATTEMPT=1 RECORDED"
assert_eq "the outcome hashes the bytes written to <story>.result.json, not the planted file" \
  "$(jq -r '[.result_sha256, (.result.planted | tostring), .status] | join(" ")' "$O6")" "sha256:$(sha <"$S6.result.json") null done"
assert_eq "the retained per-cycle copy is the same bytes" "$(sha <"$S6.result.c1.json")" "$(sha <"$S6.result.json")"
assert_eq "snapshots: launch == gate_pre (private scope ignored), a gate that edited the tree moved gate_post" \
  "$(jq -r '[.snapshots.launch.tree == .snapshots.gate_pre.tree, .snapshots.gate_pre.tree != .snapshots.gate_post.tree, (.snapshots | all(. != null))] | map(tostring) | join(" ")' "$O6")" \
  "true true true"
latest HOM-12.S6
assert_eq "latest reads the canonical outcome" "$(jf .state) $(jf .status)" "OUTCOME_RECORDED done"
printf '#!/bin/sh\ntouch "%s/spy-called"\nexit 1\n' "$TMPROOT" >"$TMPROOT/afk-spy"; chmod +x "$TMPROOT/afk-spy"
NP="$(new_story "$PB" plain AFK-X '.' 'persona: dev')"
produce "$TMPROOT/afk-spy" "$NP" dispatch:plain true
assert_eq "a non-Paperclip cycle: result written as before, the kit never called, no evidence" \
  "$RC $OUT $(jq -r .status "$NP.result.json") $([[ -e "$TMPROOT/spy-called" ]] && echo C) $(cmp -s "$NP.result.json" "$NP.result.c1.json" && echo same)" \
  "0 ATTEMPT= done  same"
cat >"$TMPROOT/afk-old" <<EOF
#!/bin/sh
case "\$1" in route-accept) echo '{"result":"ok"}' ;; *) touch "$TMPROOT/old-evidence-called"; exit 1 ;; esac
EOF
chmod +x "$TMPROOT/afk-old"
S6B="$(new_story "$PB" prod2 HOM-12.S6)"
produce "$TMPROOT/afk-old" "$S6B" dispatch:old true
assert_eq "a Paperclip verifier answering ok without a tuple: refused before launch, nothing produced" \
  "$RC $([[ -e "$S6B.result.json" ]] && echo R) $(head -c 41 "$S6B.blocked") $([[ -e "$TMPROOT/old-evidence-called" ]] && echo C)" \
  "4  LAUNCH_EVIDENCE_UNRECORDED: TUPLE_MISSING "
S6C="$(new_story "$PB" prod3 HOM-12.S6)"
produce "$AFK" "$S6C" dispatch:noacc true
assert_eq "no acceptance: refused before launch, no phantom attempt or launch" \
  "$RC $(count_accepts HOM-12.S6) $(find "$(adir HOM-12.S6)" -name '*.launch.json' | wc -l | tr -d ' ')" "4 1 1"
# The real kit for everything but `outcome`, which refuses after the launch
# was recorded: the cycle's result must be produced exactly as without it.
cat >"$TMPROOT/afk-norec" <<EOF
#!/bin/sh
if [ "\$1" = paperclip-evidence ] && [ "\$2" = outcome ]; then cat >/dev/null; echo '{"result":"EVIDENCE_WRITE_FAILED"}'; exit 1; fi
exec bash "$AFK" "\$@"
EOF
chmod +x "$TMPROOT/afk-norec"
S9="$(new_story "$PB" norec HOM-12.S9)"; accept --story "$S9" --kind pm-auto --actor pm
produce "$TMPROOT/afk-norec" "$S9" dispatch:norec true
assert_eq "an outcome refused after the launch: exit 0, status done, the produced bytes published and retained" \
  "$RC $OUT $(jq -r '[.status, .launch.dispatch_id] | join(" ")' "$S9.result.json" 2>/dev/null) $(cmp -s "$S9.result.json" "$S9.result.c1.json" && echo same)" \
  "0 ATTEMPT=1 done dispatch:norec same"
NREC="$(grep -c 'outcome NOT recorded (EVIDENCE_WRITE_FAILED)' "$TMPROOT/err")"
latest HOM-12.S9
assert_eq "...the refusal is logged, no outcome record exists, and latest reads ATTEMPT_UNFINISHED" \
  "$NREC $(find "$(adir HOM-12.S9)" -name '*.outcome.json' | wc -l | tr -d ' ') $(jf .state) $(jf .cycle)" \
  "1 0 ATTEMPT_UNFINISHED 1"

head1 "5. dispatch.sh main() end to end, stubbed Orca and validator"
# W is an Orca worktree whose private scope (.pm-brief/) is ignored; the gate
# tests/b.sh edits a tracked file. The Orca stub "runs" the harness by
# answering the exit marker; each terminal create is logged as a harness run.
W="$TMPROOT/wt"; SB="$TMPROOT/stubs"; CALLS="$TMPROOT/calls.log"; TS="$TMPROOT/terminal.json"
git init -q "$W"; mkdir -p "$W/tests" "$W/_bmad/bmm/agents" "$SB" "$HOME_DIR/.claude"
printf 'base\n' >"$W/p.txt"; printf 'exit 0\n' >"$W/tests/a.sh"; printf 'printf "g\\n" >>p.txt\n' >"$W/tests/b.sh"
printf 'You are the dev persona.\n' >"$W/_bmad/bmm/agents/dev.md"
git -C "$W" add -A; git -C "$W" commit -qm base
printf '.pm-brief/\n' >>"$W/.git/info/exclude"; WB="$W/.pm-brief"; mkdir -p "$WB"
cat >"$SB/orca" <<STUB
#!/bin/sh
echo "orca \$*" >>"$CALLS"
case "\$1 \$2" in
  "worktree list") printf '{"result":{"worktrees":[{"path":"%s","id":"r1::wt1"}]}}' "$W" ;;
  "repo list") echo '{"result":{"repos":[{"id":"r1","hookSettings":{"setupAgentStartupPolicy":"start-immediately"}}]}}' ;;
  "terminal create") echo harness >>"$CALLS"; t=""
    while [ \$# -gt 0 ]; do [ "\$1" = --title ] && t="\$2"; shift; done
    jq -nc --arg t "\$t" --arg w "$W" '{handle:"term_stub",title:\$t,connected:true,orphaned:false,worktreeId:"r1::wt1",worktreePath:\$w}' >"$TS"
    echo '{"ok":true,"result":{"terminal":{"handle":"term_stub"}}}' ;;
  "terminal read") echo '{"ok":true,"result":{"terminal":{"handle":"term_stub","status":"running","tail":["ok","CLAUDE_EXIT=0"]}}}' ;;
  "terminal show") [ -s "$TS" ] || exit 1; jq -c '{ok:true,result:{terminal:.}}' "$TS" ;;
  "terminal list") if [ -s "$TS" ]; then jq -c '{ok:true,result:{terminals:[.]}}' "$TS"; else echo '{"ok":true,"result":{"terminals":[]}}'; fi ;;
  "terminal close") rm -f "$TS"; echo '{"ok":true}' ;;
  *) echo '{"ok":true,"result":{}}' ;;
esac
STUB
printf '#!/bin/sh\necho "{}"\n' >"$SB/validator"
printf '#!/bin/sh\nexit 0\n' >"$SB/claude"
chmod +x "$SB/orca" "$SB/validator" "$SB/claude"
printf 'profiles:\n  local-code-standard:\n    physical: [{model_id: qwen-test}]\n  "claude/strong":\n    hosting: vendor\n    physical: [{model_id: "claude/opus"}]\n' >"$TMPROOT/catalog.yaml"
MAIN_N=0
run_main() { # <story> [cycle] -- each run its own dispatch id (MAIN_DISPATCH_ID pins one); no ambient run identity
  MAIN_N=$((MAIN_N + 1))
  OUT="$(cd "$W" && env -u AFK_RUN_ID -u ORCA_RUN_ID -u AFK_CONTEXT_EVENT_DIR -u AGENT_ROUTER_TOKEN \
    AFK_DISPATCH_ID="${MAIN_DISPATCH_ID:-dispatch:main-$MAIN_N}" AFK_DELEGATING_PM="${MAIN_PM:-}" AGENT_DIR="$W/_bmad/bmm/agents" PATH="$SB:$PATH" AGENT_FLOW_CONFIG="${MAIN_CONFIG:-/nonexistent}" AGENT_STAMP_VALIDATE=validator \
    AGENT_STAMP_VALIDATE_CATALOG_PATH="$TMPROOT/catalog.yaml" AGENT_FLOW_KIT_BIN="$AFK" \
    AGENT_FLOW_APPROVED_HOME="$HOME_DIR" AGENT_FLOW_APPROVED_PATH="" AGENT_FLOW_LAUNCH_TIMEOUT=20 CLAUDE_CONFIG_DIR="" \
    bash "$DISPATCH" "$1" "${2:-1}" 2>&1 </dev/null)"; RC=$?
}
harness_runs() { grep -cx harness "$CALLS" 2>/dev/null || true; }
S5="$(new_story "$WB" main HOM-12.S5)"; accept --story "$S5" --kind pm-auto --actor pm
run_main "$S5"
if [[ "$OUT" == *"NO VALIDATED LAUNCH CONTRACT"* && "$OUT" != *"launch recorded"* ]]; then
  ok "main(): verified, then refused by the launch-contract guard before any launch record"
else bad "main(): verified, then refused by the launch-contract guard before any launch record" "$RC $OUT"; fi
latest HOM-12.S5
assert_eq "...and the accepted attempt reads ATTEMPT_NOT_LAUNCHED" "$(jf .state) $(jf .attempt)" "ATTEMPT_NOT_LAUNCHED 1"
# A launchable native pair. cost_class stays free because pm-auto accepts only
# the free lane; the stubbed validator is not asked about funding here.
S10="$(new_story "$WB" full HOM-12.S10 '.model_profile = "claude/strong" | .entitlement_pool = "anthropic-max"' "home: paperclip:HOM-12
paperclip_issue: $ISSUE
persona: dev
memory_mode: off")"
accept --story "$S10" --kind pm-auto --actor pm
D10="$(adir HOM-12.S10)"
run_main "$S10"
assert_eq "main(): a Paperclip cycle launches, gates and publishes done" \
  "$RC $(jq -r .status "$S10.result.json" 2>/dev/null) $(harness_runs)" "0 done 1"
[[ "$RC" == 0 ]] || printf '        %s\n' "$(tail -n 5 <<<"$OUT")"
assert_eq "...launch and outcome recorded under attempt 1, cycle 1, the result's dispatch id" \
  "$(jq -r --slurpfile r "$S10.result.json" '[.outcome, .status, .gates_ok, .gate_count, .dispatch_id == $r[0].launch.dispatch_id] | map(tostring) | join(" ")' "$D10/1.c1.outcome.json" 2>/dev/null)" \
  "RECORDED done true 2 true"
assert_eq "...the outcome hashes the bytes main() published, and the retained copy is the same" \
  "$(jq -r .result_sha256 "$D10/1.c1.outcome.json" 2>/dev/null) $(sha <"$S10.result.c1.json")" "sha256:$(sha <"$S10.result.json") $(sha <"$S10.result.json")"
assert_eq "...snapshots: launch == gate_pre, the gate's edit moved gate_post, none null" \
  "$(jq -r '[.snapshots.launch.tree == .snapshots.gate_pre.tree, .snapshots.gate_pre.tree != .snapshots.gate_post.tree, (.snapshots | all(. != null))] | map(tostring) | join(" ")' "$D10/1.c1.outcome.json" 2>/dev/null)" \
  "true true true"
R10="$(sha <"$S10.result.json")"
run_main "$S10"
assert_eq "replaying the done cycle without a new acceptance: refused before the harness, LAUNCH_DUPLICATE" \
  "$RC $(harness_runs) $(head -c 44 "$S10.blocked" 2>/dev/null)" "4 1 LAUNCH_EVIDENCE_UNRECORDED: LAUNCH_DUPLICATE"
latest HOM-12.S10
assert_eq "...nothing ran and nothing changed: the result and latest are still cycle 1's" \
  "$(sha <"$S10.result.json") $(jf '[.state, .attempt, .cycle] | map(tostring) | join(" ")')" "$R10 OUTCOME_RECORDED 1 1"
accept --story "$S10" --kind pm-auto --actor pm
run_main "$S10"; MRC=$RC
latest HOM-12.S10
assert_eq "a fresh acceptance opens attempt 2; the replayed cycle runs and is the latest evidence" \
  "$MRC $(harness_runs) $(jf '[.state, .attempt, .cycle, .status] | map(tostring) | join(" ")')" "0 2 OUTCOME_RECORDED 2 1 done"
# A harness preflight refusal (here the configured harness binary is missing)
# comes before the launch record, so the same cycle runs once the host is fixed.
printf 'launcher:\n  harness_binaries:\n    claude: afk-no-such-claude-binary\n' >"$TMPROOT/nobin.yaml"
accept --story "$S10" --kind pm-auto --actor pm
MAIN_CONFIG="$TMPROOT/nobin.yaml" run_main "$S10"; MRC=$RC
MREASON=""; [[ "$OUT" == *"harness binary 'afk-no-such-claude-binary' not found"* ]] && MREASON=missing-binary
latest HOM-12.S10
assert_eq "a preflight refusal (the missing binary): nothing ran, no launch record, latest reads ATTEMPT_NOT_LAUNCHED" \
  "$([[ "$MRC" != 0 ]] && echo refused) $MREASON $(harness_runs) $([[ -e "$D10/3.c1.launch.json" ]] && echo L) $(jf '[.state, .attempt] | map(tostring) | join(" ")')" \
  "refused missing-binary 2  ATTEMPT_NOT_LAUNCHED 3"
run_main "$S10"; MRC=$RC
latest HOM-12.S10
assert_eq "...and the same cycle, retried with the binary present, launches and records its outcome" \
  "$MRC $(harness_runs) $(jf '[.state, .attempt, .cycle, .status] | map(tostring) | join(" ")')" "0 3 OUTCOME_RECORDED 3 1 done"

head1 "6. A continuation cycle left between terminal receipt and ledger entry"
# Cycle 1 handed over, so cycle 2 is a continuation. The ledger path is a
# directory while cycle 2 launches: the terminal is created and its receipt
# written, then the ledger append fails, as a dispatcher stopped at that point
# would leave it. The retry repeats the same dispatch id and PM, so its
# command, and therefore its launch identity, is the earlier one's.
cont_story() { # <name> <story_id> <frontmatter> -> story path, cycle 1 handed over
  local s
  s="$(new_story "$WB" "$1" "$2" '.model_profile = "claude/strong" | .entitlement_pool = "anthropic-max"' "$3")"
  jq -n '{status:"continuation_required"}' >"$s.result.c1.json"
  jq -n '{schema:"afk-continuation/1", completed:["c1"], current_state:"s", remaining_acceptance:["a"],
    next_steps:["n"], updated_at:"2026-10-04T00:00:00Z", in_flight:[], unretired_findings:[]}' >"$s.continuation.json"
  printf '%s' "$s"
}
gap_run() { # <story> -- cycle 2 with its ledger append made to fail
  mkdir -p "$1.continuations.json"; run_main "$1" 2; rm -rf -- "$1.continuations.json"; }
MAIN_DISPATCH_ID=dispatch:cont MAIN_PM=pm:cont
S11="$(cont_story cont HOM-12.S11 "home: paperclip:HOM-12
paperclip_issue: $ISSUE
persona: dev
memory_mode: off")"
D11="$(adir HOM-12.S11)"; accept --story "$S11" --kind pm-auto --actor pm
H0="$(harness_runs)"; gap_run "$S11"; GRC=$RC
assert_eq "the gap: launch recorded under attempt 1, terminal created and receipted, no ledger entry" \
  "$([[ "$GRC" != 0 ]] && echo stopped) $(( $(harness_runs) - H0 )) $([[ -e "$D11/1.c2.launch.json" ]] && echo L) $(jq -r .terminal "$S11.continuation-launch-receipt.c2.json" 2>/dev/null)" \
  "stopped 1 L term_stub"
[[ "$GRC" != 0 ]] || printf '        %s\n' "$(tail -n 5 <<<"$OUT")"
accept --story "$S11" --kind pm-auto --actor pm
H1="$(harness_runs)"; run_main "$S11" 2; MRC=$RC MOUT=$OUT
latest HOM-12.S11
assert_eq "re-accepted, the cycle is refused before its launch record: the earlier terminal is not recovered under attempt 2" \
  "$MRC $(( $(harness_runs) - H1 )) $(head -n 1 "$S11.blocked" 2>/dev/null | cut -d' ' -f1-2) $([[ -e "$D11/2.c2.launch.json" ]] && echo L) $([[ -e "$S11.result.c2.json" ]] && echo R) $([[ -e "$S11.continuations.json" ]] && echo ledger)" \
  "4 0 LAUNCH_EVIDENCE_UNRECORDED: CONTINUATION_LAUNCH_UNCONFIRMED   "
[[ "$MRC" == 4 ]] || printf '        %s\n' "$(tail -n 5 <<<"$MOUT")"
assert_eq "...attempt 2 reads ATTEMPT_NOT_LAUNCHED and attempt 1 keeps its unfinished cycle-2 launch" \
  "$(jf '[.state, .attempt] | map(tostring) | join(" ")') $(jq -r .dispatch_id "$D11/1.c2.launch.json" 2>/dev/null)" "ATTEMPT_NOT_LAUNCHED 2 dispatch:cont"
# Advisory with no helper: memory_mode off/blind puts a per-run temp
# HINDSIGHT_CONFIG path into the command, so a retry is a different launch
# identity and is never recovered, Paperclip or not.
SN="$(cont_story contplain AFK-CONT "persona: dev
memory_mode: advisory")"
H2="$(harness_runs)"; AGENT_FLOW_HINDSIGHT_HELPER=/nonexistent gap_run "$SN"; GRC=$RC
AGENT_FLOW_HINDSIGHT_HELPER=/nonexistent run_main "$SN" 2
assert_eq "a non-Paperclip continuation in the same gap still recovers its confirmed terminal and ledgers it" \
  "$([[ "$GRC" != 0 ]] && echo stopped) $(( $(harness_runs) - H2 )) $([[ "$OUT" == *"recovered confirmed Orca terminal term_stub"* ]] && echo recovered) $(jq -r '[.entries[] | select(.cycle == 2) | .terminal] | join(",")' "$SN.continuations.json" 2>/dev/null)" \
  "stopped 1 recovered term_stub"
[[ "$OUT" == *"recovered confirmed"* ]] || printf '        %s\n' "$(tail -n 5 <<<"$OUT")"
unset MAIN_DISPATCH_ID MAIN_PM

head1 "7. Review verdicts: the /2 binding, the gate, the launch refusals, the review record"
# A second issue with a /2 plan: HOM-13.S1 is the builder, S2..S8 review it.
# Its digest is rendered by the kit's own renderer, as paperclip-plan does.
ISSUE2="e2222222-2222-2222-2222-222222222222"; RG='agent-flow-kit review-verdict --check'
PLAN2="$(jq -nc --arg g "$RG" '{schema:"afk-paperclip-plan/2", repo:"/r/repo", base:"main", stories:(
  [{id:"HOM-13.S1",title:"B",size:"S",lane:"l",files:[],gates:["bash tests/a.sh","bash tests/b.sh"],role:"builder"}]
  + [range(2; 9) | {id:"HOM-13.S\(.)",title:"R",size:"S",lane:"l",files:[],gates:["bash tests/a.sh",$g],role:"reviewer",reviews:"HOM-13.S1"}])}')"
PLAND2="$( (. "$KIT_ROOT/lib/afk-paperclip-plan.sh"; afk_pcp_render "$PLAN2") | sha)"
jq -n --argjson p "$PLAN2" --arg d "$PLAND2" '{schema:"afk-paperclip-plan-record/1", state:"posted", digest:$d,
  plan_schema:$p.schema, repo:$p.repo, base:$p.base, stories:$p.stories}' >"$STATE/paperclip/plans/$ISSUE2.json"
approve2() { jq -nc --arg d "${1:-$PLAND2}" --arg c "$COMMIT" \
  '{schema:"afk-paperclip-approval/1",kind:"plan",digest:$d,paperclip_commit:$c}' >"$STATE/paperclip/approvals/$ISSUE2.json"; }
approve2
adir2() { printf '%s' "$STATE/paperclip/attempts/$ISSUE2/$1"; }
latest2() { ev latest --issue "$ISSUE2" --story-id "$1" --json; }
FM2="home: paperclip:HOM-13
paperclip_issue: $ISSUE2"
rv_story() { # <dir> <name> <story_id> [<stamp-jq-edit>] [<extra frontmatter lines>] -> a reviewer story path
  local s="$1/$2.md"
  printf -- '---\n%s\n%sgates:\n  - "bash tests/a.sh"\n  - "%s"\n---\n# review\n' "$FM2" "${5:-}" "$RG" >"$s"
  jq -n --arg sid "$3" '{harness:"claude", model_profile:"local-code-standard", effort:"medium", cost_class:"free",
          metered:false, catalog_version:"sha256:abc", placement_required:false,
          task:{story_id:$sid, tags:["tests"]}, override:null}' | jq "${4:-.}" >"$s.stamp.json"
  printf '%s' "$s"
}
verdict() { # <reviewer_story_id> <reviews_story_id> <verdict> [<findings-json>]
  jq -nc --arg r "$1" --arg t "$2" --arg v "$3" --argjson f "${4:-[]}" \
    '{schema:"afk-review-verdict/1", reviewer_story_id:$r, reviews_story_id:$t, verdict:$v, findings:$f}'
}
vc() { OUT="$(AFK_GATE_STORY="$1" bash "$AFK" review-verdict --check --json 2>"$TMPROOT/err" </dev/null)"; RC=$?; }
vc_is() { # <name> <story> <expected "result rc">
  vc "$2"; assert_eq "$1" "$(res) $RC" "$3"
}

RV="$(rv_story "$SD" rv2 HOM-13.S2)"; accept --story "$RV" --kind pm-auto --actor pm
assert_eq "a /2 reviewer story is accepted (attempt 1)" "$(res) $(jf .attempt)" "ok 1"
OUT="$(env -u AFK_GATE_STORY bash "$AFK" review-verdict --check --json 2>/dev/null </dev/null)"; RC=$?
assert_eq "--check with no locator -> GATE_STORY_INVALID, exit 4" "$(res) $RC" "GATE_STORY_INVALID 4"
vc_is "a relative locator -> GATE_STORY_INVALID" "rv2.md" "GATE_STORY_INVALID 4"
ln -s "$RV" "$SD/rv2-link.md"
vc_is "a symlinked story -> GATE_STORY_INVALID" "$SD/rv2-link.md" "GATE_STORY_INVALID 4"
vc_is "no verdict file -> VERDICT_MISSING" "$RV" "VERDICT_MISSING 4"
verdict HOM-13.S2 HOM-13.S1 APPROVE >"$RV.verdict.json"
vc_is "a bound APPROVE with no findings passes, exit 0" "$RV" "ok 0"
verdict HOM-13.S2 HOM-13.S1 APPROVE '[{"severity":"major","status":"resolved","summary":"x"},{"severity":"minor","status":"open","summary":"y"}]' >"$RV.verdict.json"
vc_is "a resolved major and an open minor still pass" "$RV" "ok 0"
OUT="$(AFK_GATE_STORY="$RV" bash "$AFK" review-verdict --check 2>/dev/null </dev/null)"; RC=$?
assert_eq "text mode on a pass" "$OUT $RC" "review verdict: ok 0"
for bad in 'not json' "$(verdict HOM-13.S2 HOM-13.S1 APPROVE | jq -c '. + {extra:1}')" \
           "$(verdict HOM-13.S2 HOM-13.S1 APPROVE | jq -c 'del(.findings)')" \
           "$(verdict HOM-13.S2 HOM-13.S1 approve)" "$(verdict HOM-13.S2 HOM-13.S1 APPROVE | jq -c '.schema = "x"')" \
           "$(verdict HOM-13.S2 HOM-13.S1 APPROVE '[{"severity":"major","status":"open"}]')" \
           "$(verdict HOM-13.S2 HOM-13.S1 APPROVE)$(verdict HOM-13.S2 HOM-13.S1 APPROVE)" '[]' \
           "$(verdict HOM-13.S2 HOM-13.S1 APPROVE) 1" \
           "$(verdict HOM-13.S2 HOM-13.S1 APPROVE | sed 's/^{/{"verdict":"CHANGES_REQUESTED",/')"; do
  printf '%s\n' "$bad" >"$RV.verdict.json"; vc "$RV"
  assert_eq "malformed, partial, trailing-value or duplicate-member verdict -> VERDICT_INVALID: ${bad:0:48}" "$(res) $RC" "VERDICT_INVALID 4"
done
for byte in '\000' '\377'; do
  verdict HOM-13.S2 HOM-13.S1 APPROVE '[{"severity":"info","status":"open","summary":"aXb"}]' | tr X "$byte" >"$RV.verdict.json"
  vc_is "a verdict with the raw byte $byte (NUL or invalid UTF-8) -> VERDICT_INVALID" "$RV" "VERDICT_INVALID 4"
done
OUT="$(AFK_GATE_STORY="$RV" bash "$AFK" review-verdict 2>/dev/null </dev/null)"; RC=$?
assert_eq "review-verdict without --check is a usage error" "$RC" "1"
verdict HOM-13.S2 HOM-13.S1 APPROVE "$(jq -nc --arg s "$(head -c 70000 /dev/zero | tr '\0' a)" '[{severity:"info",status:"open",summary:$s}]')" >"$RV.verdict.json"
vc_is "a verdict over 64 KiB -> VERDICT_INVALID" "$RV" "VERDICT_INVALID 4"
rm -f "$RV.verdict.json"; verdict HOM-13.S2 HOM-13.S1 APPROVE >"$TMPROOT/v-target.json"; ln -s "$TMPROOT/v-target.json" "$RV.verdict.json"
vc_is "a symlinked verdict -> VERDICT_INVALID" "$RV" "VERDICT_INVALID 4"
rm -f "$RV.verdict.json"; mkdir "$RV.verdict.json"
vc_is "a directory at the verdict path -> VERDICT_INVALID" "$RV" "VERDICT_INVALID 4"
rmdir "$RV.verdict.json"
verdict HOM-13.S3 HOM-13.S1 APPROVE >"$RV.verdict.json"
vc_is "another reviewer's id -> VERDICT_IDS_MISMATCH" "$RV" "VERDICT_IDS_MISMATCH 4"
verdict HOM-13.S2 HOM-13.S9 APPROVE >"$RV.verdict.json"
vc_is "a target other than the plan's -> VERDICT_IDS_MISMATCH" "$RV" "VERDICT_IDS_MISMATCH 4"
verdict HOM-13.S2 HOM-13.S1 CHANGES_REQUESTED >"$RV.verdict.json"
vc_is "CHANGES_REQUESTED -> VERDICT_NOT_APPROVE" "$RV" "VERDICT_NOT_APPROVE 4"
for sev in major blocker; do
  verdict HOM-13.S2 HOM-13.S1 APPROVE "[{\"severity\":\"$sev\",\"status\":\"open\",\"summary\":\"x\"}]" >"$RV.verdict.json"
  vc_is "an APPROVE with an open $sev -> VERDICT_OPEN_MAJOR" "$RV" "VERDICT_OPEN_MAJOR 4"
done
verdict HOM-13.S2 HOM-13.S1 CHANGES_REQUESTED '[{"severity":"blocker","status":"open","summary":"x"}]' >"$RV.verdict.json"
vc "$RV"
assert_eq "every content reason is reported" "$(jf '.reasons | join(",")')" "VERDICT_NOT_APPROVE,VERDICT_OPEN_MAJOR"
OUT="$(AFK_GATE_STORY="$RV" bash "$AFK" review-verdict --check 2>/dev/null </dev/null)"; RC=$?
assert_eq "text mode names the reasons" "$OUT $RC" "agent-flow-kit review-verdict: VERDICT_NOT_APPROVE VERDICT_OPEN_MAJOR 4"
verdict HOM-13.S2 HOM-13.S1 APPROVE >"$RV.verdict.json"
rm -f "$STATE/paperclip/approvals/$ISSUE2.json"; vc "$RV"
assert_eq "approval withdrawn -> VERDICT_PLAN_UNBOUND, naming the tuple refusal" "$(res) $RC $(jf .tuple_reason)" "VERDICT_PLAN_UNBOUND 4 PLAN_NOT_APPROVED"
approve2 "$(printf '%064d' 0)"
vc_is "an approval of another digest -> VERDICT_PLAN_UNBOUND" "$RV" "VERDICT_PLAN_UNBOUND 4"
approve2
B1="$(new_story "$SD" b1 HOM-13.S1 '.' "$FM2")"; accept --story "$B1" --kind pm-auto --actor pm
verdict HOM-13.S1 HOM-13.S1 APPROVE >"$B1.verdict.json"
vc_is "a builder story's verdict -> VERDICT_PLAN_UNBOUND" "$B1" "VERDICT_PLAN_UNBOUND 4"
V1="$(new_story "$SD" v1 HOM-12.S1)"; accept --story "$V1" --kind pm-auto --actor pm
verdict HOM-12.S1 HOM-12.S1 APPROVE >"$V1.verdict.json"
vc_is "a /1 story's verdict -> VERDICT_PLAN_UNBOUND (no review role)" "$V1" "VERDICT_PLAN_UNBOUND 4"
# Another story's title edited in the stored record, digest kept: the
# reviewer's own tuple still verifies, but the record no longer renders to it.
cp "$STATE/paperclip/plans/$ISSUE2.json" "$TMPROOT/p2.orig"
jq '.stories[2].title = "edited"' "$TMPROOT/p2.orig" >"$STATE/paperclip/plans/$ISSUE2.json"
vc_is "a stored plan edited under the same digest -> VERDICT_PLAN_UNBOUND" "$RV" "VERDICT_PLAN_UNBOUND 4"
cp "$TMPROOT/p2.orig" "$STATE/paperclip/plans/$ISSUE2.json"
vc_is "...restored, the same verdict passes again" "$RV" "ok 0"

# Launch refusals, through the verb dispatch.sh calls. $PB is ignored in $P.
RL="$(rv_story "$PB" rl HOM-13.S3)"; accept --story "$RL" --kind pm-auto --actor pm
TUPR="$(bash "$AFK" route-accept --story "$RL" --verify --json 2>/dev/null </dev/null | jq -c .tuple)"
LINR="$(jq -nc --argjson t "$TUPR" --argjson s "$SNAP" '{tuple:$t, snapshot:$s}')"
DR="$(adir2 HOM-13.S3)"; nlaunch() { find "$1" -name '*.launch.json' 2>/dev/null | wc -l | tr -d ' '; }
for plant in file dangling dir; do
  case "$plant" in
    file) printf '{}\n' >"$RL.verdict.json" ;;
    dangling) ln -s "$TMPROOT/nowhere" "$RL.verdict.json" ;;
    dir) mkdir "$RL.verdict.json" ;;
  esac
  ev_in "$LINR" launch --story "$RL" --cycle 1 --dispatch-id dispatch:rl --json
  assert_eq "a preexisting verdict ($plant) -> VERDICT_PREEXISTS, no launch record" "$(res) $RC $(nlaunch "$DR")" "VERDICT_PREEXISTS 4 0"
  rm -rf -- "$RL.verdict.json"
done
RN="$(rv_story "$P" rn HOM-13.S4)"; accept --story "$RN" --kind pm-auto --actor pm
ev_in "$(jq -nc --argjson t "$(bash "$AFK" route-accept --story "$RN" --verify --json 2>/dev/null </dev/null | jq -c .tuple)" --argjson s "$SNAP" '{tuple:$t, snapshot:$s}')" \
  launch --story "$RN" --cycle 1 --dispatch-id dispatch:rn --json
assert_eq "a verdict path that is not ignored -> VERDICT_PATH_NOT_IGNORED, no launch record" \
  "$(res) $RC $(nlaunch "$(adir2 HOM-13.S4)")" "VERDICT_PATH_NOT_IGNORED 4 0"
# Another story edited under the same digest: the reviewer's own tuple still
# verifies, and its approved story still says reviewer, so it is not launched
# as a builder.
jq '.stories[0].title = "edited"' "$TMPROOT/p2.orig" >"$STATE/paperclip/plans/$ISSUE2.json"
ev_in "$LINR" launch --story "$RL" --cycle 1 --dispatch-id dispatch:rl --json
assert_eq "a reviewer whose plan record no longer renders -> VERDICT_PLAN_UNBOUND, no launch record" "$(res) $RC $(nlaunch "$DR")" "VERDICT_PLAN_UNBOUND 4 0"
cp "$TMPROOT/p2.orig" "$STATE/paperclip/plans/$ISSUE2.json"
ev_in "$LINR" launch --story "$RL" --cycle 1 --dispatch-id dispatch:rl --json
assert_eq "cleared, the same cycle launches under the same attempt, as a reviewer" "$(res) $(jf .attempt) $(jf .cycle) $(jf .role)" "ok 1 1 reviewer"
BL="$(new_story "$PB" bl HOM-13.S1 '.' "$FM2")"; accept --story "$BL" --kind pm-auto --actor pm
TUPB="$(bash "$AFK" route-accept --story "$BL" --verify --json 2>/dev/null </dev/null | jq -c .tuple)"
verdict HOM-13.S1 HOM-13.S1 APPROVE >"$BL.verdict.json"
ev_in "$(jq -nc --argjson t "$TUPB" --argjson s "$SNAP" '{tuple:$t, snapshot:$s}')" launch --story "$BL" --cycle 1 --dispatch-id dispatch:bl --json
assert_eq "a builder launches with a verdict file present, and no role" "$(res) $(jf .role)" "ok null"
NB="$(jf .attempt)"

# The review record, from the producer's verdict_text only.
oinv() { oin "$1" "$2" | jq -c --argjson v "$3" '. + {verdict_text:$v}'; }
rres() { jq -n --arg d "$1" --argjson k "$2" '{story:"rl.md", cycle:$k, status:"done", launch:{dispatch_id:$d},
  gates:{"bash tests/a.sh":"pass","agent-flow-kit review-verdict --check":"pass"}}'; }
VOK="$(verdict HOM-13.S3 HOM-13.S1 APPROVE)"
ev_in "$(oinv "$(rres dispatch:rl 1)" "$TUPR" "$(jq -Rs . <<<"$VOK")")" outcome --story "$RL" --attempt 1 --cycle 1 --dispatch-id dispatch:rl --json
assert_eq "a reviewer outcome is recorded" "$(res) $RC $(jf .outcome)" "ok 0 RECORDED"
assert_eq "review record: kind, linkage, tuple, verdict bytes hashed, check_ok, no reasons" \
  "$(jq -c --argjson t "$TUPR" '[.schema, .kind, .attempt, .cycle, .dispatch_id, (.tuple == $t), .verdict_sha256, .verdict.verdict, .check_ok, .reasons]' "$DR/1.c1.review.json" 2>/dev/null)" \
  "[\"afk-paperclip-attempt/1\",\"review\",1,1,\"dispatch:rl\",true,\"sha256:$(printf '%s\n' "$VOK" | sha)\",\"APPROVE\",true,[]]"
assert_eq "...and the outcome record keeps B's members exactly" "$(jq -c 'keys' "$DR/1.c1.outcome.json")" \
  '["approval_reason","attempt","created_at","cycle","dispatch_id","gate_count","gates_ok","issue","kind","outcome","result","result_sha256","schema","snapshots","status","story_id","tuple","tuple_at_outcome"]'
ev_in "$LINR" launch --story "$RL" --cycle 2 --dispatch-id dispatch:rl2 --json
ev_in "$(oinv "$(rres dispatch:rl2 2)" "$TUPR" null)" outcome --story "$RL" --attempt 1 --cycle 2 --dispatch-id dispatch:rl2 --json
assert_eq "no captured verdict -> review record VERDICT_MISSING, verdict and sha null" \
  "$(res) $(jq -c '[.check_ok, .reasons, .verdict, .verdict_sha256]' "$DR/1.c2.review.json" 2>/dev/null)" 'ok [false,["VERDICT_MISSING"],null,null]'
ev_in "$LINR" launch --story "$RL" --cycle 3 --dispatch-id dispatch:rl3 --json
ev_in "$(oinv "$(rres dispatch:rl3 3)" "$TUPR" "$(jq -Rs . <<<"$(verdict HOM-13.S3 HOM-13.S1 CHANGES_REQUESTED)")")" outcome --story "$RL" --attempt 1 --cycle 3 --dispatch-id dispatch:rl3 --json
assert_eq "captured CHANGES_REQUESTED -> check_ok false, the same validator's reason" \
  "$(jq -c '[.check_ok, .reasons, .verdict.verdict]' "$DR/1.c3.review.json" 2>/dev/null)" '[false,["VERDICT_NOT_APPROVE"],"CHANGES_REQUESTED"]'
# A stop between the two writes: the review record exists, the outcome does
# not (here its name is taken by a dangling link, so its write fails).
ev_in "$LINR" launch --story "$RL" --cycle 4 --dispatch-id dispatch:rl4 --json
ln -s "$TMPROOT/nowhere" "$DR/1.c4.outcome.json"
ev_in "$(oinv "$(rres dispatch:rl4 4)" "$TUPR" "$(jq -Rs . <<<"$VOK")")" outcome --story "$RL" --attempt 1 --cycle 4 --dispatch-id dispatch:rl4 --json
assert_eq "the outcome write fails after the review record was written" "$(res) $RC" "OUTCOME_DUPLICATE 4"
rm -f "$DR/1.c4.outcome.json"
latest2 HOM-13.S3
assert_eq "...review written, outcome not: latest reads ATTEMPT_UNFINISHED" \
  "$([[ -f "$DR/1.c4.review.json" ]] && echo review) $(jf .state) $(jf .cycle)" "review ATTEMPT_UNFINISHED 4"
ev_in "$(oinv "$(rres dispatch:rl4 4)" "$TUPR" "$(jq -Rs . <<<"$VOK")")" outcome --story "$RL" --attempt 1 --cycle 4 --dispatch-id dispatch:rl4 --json
assert_eq "...a retry is REVIEW_DUPLICATE and never writes an outcome past it" \
  "$(res) $RC $([[ -e "$DR/1.c4.outcome.json" ]] && echo O)" "REVIEW_DUPLICATE 4 "
printf '{}\n' >"$RL.verdict.json"
ev_in "$LINR" launch --story "$RL" --cycle 5 --dispatch-id dispatch:rl5 --json
assert_eq "a continuation cycle meets an earlier cycle's verdict -> VERDICT_PREEXISTS, nothing written" \
  "$(res) $RC $([[ -e "$DR/1.c5.launch.json" ]] && echo L)" "VERDICT_PREEXISTS 4 "
rm -f "$RL.verdict.json"; ev_in "$LINR" launch --story "$RL" --cycle 5 --dispatch-id dispatch:rl5 --json
ev_in "$(oinv "$(rres dispatch:rl5 5)" "$TUPR" 1)" outcome --story "$RL" --attempt 1 --cycle 5 --dispatch-id dispatch:rl5 --json
assert_eq "a verdict_text neither string nor null -> EVIDENCE_INPUT_INVALID, no review or outcome" \
  "$(res) $RC $(find "$DR" -name '1.c5.*' ! -name '*.launch.json' | wc -l | tr -d ' ')" "EVIDENCE_INPUT_INVALID 4 0"
jq '.stories[0].title = "edited"' "$TMPROOT/p2.orig" >"$STATE/paperclip/plans/$ISSUE2.json"
ev_in "$(oinv "$(rres dispatch:rl5 5)" "$TUPR" "$(jq -Rs . <<<"$VOK")")" outcome --story "$RL" --attempt 1 --cycle 5 --dispatch-id dispatch:rl5 --json
cp "$TMPROOT/p2.orig" "$STATE/paperclip/plans/$ISSUE2.json"
assert_eq "a plan record edited after launch: the reviewer still writes a review record, VERDICT_PLAN_UNBOUND" \
  "$(jf .outcome) $(jq -c '[.check_ok, .reasons]' "$DR/1.c5.review.json" 2>/dev/null)" 'RECORDED [false,["VERDICT_PLAN_UNBOUND"]]'
ev_in "$LINR" launch --story "$RL" --cycle 6 --dispatch-id dispatch:rl6 --json
rm -f "$STATE/paperclip/approvals/$ISSUE2.json"
ev_in "$(oinv "$(rres dispatch:rl6 6)" "$TUPR" "$(jq -Rs . <<<"$VOK")")" outcome --story "$RL" --attempt 1 --cycle 6 --dispatch-id dispatch:rl6 --json
approve2
assert_eq "approval withdrawn, record unchanged: APPROVAL_CHANGED beside a VERDICT_PLAN_UNBOUND review record" \
  "$(jf .outcome) $(jq -c '[.check_ok, .reasons]' "$DR/1.c6.review.json" 2>/dev/null)" 'APPROVAL_CHANGED [false,["VERDICT_PLAN_UNBOUND"]]'
RB="$(jq -n '{story:"bl.md", cycle:1, status:"done", launch:{dispatch_id:"dispatch:bl"}, gates:{"bash tests/a.sh":"pass","bash tests/b.sh":"pass"}}')"
ev_in "$(oinv "$RB" "$TUPB" "$(jq -Rs . <<<"$VOK")")" outcome --story "$BL" --attempt "$NB" --cycle 1 --dispatch-id dispatch:bl --json
assert_eq "a builder ignores verdict_text: outcome recorded, no review record" \
  "$(res) $(find "$(adir2 HOM-13.S1)" -name '*.review.json' | wc -l | tr -d ' ')" "ok 0"
assert_eq "...its outcome keeps B's members exactly" "$(jq -c 'keys' "$(adir2 HOM-13.S1)/$NB.c1.outcome.json" 2>/dev/null)" "$(jq -c 'keys' "$DR/1.c1.outcome.json")"
latest2 HOM-13.S1; LB="$(jq -c 'keys' <<<"$OUT")"; latest HOM-12.S6
assert_eq "...and latest reports B's members, as for a /1 story" "$LB" "$(jq -c 'keys' <<<"$OUT")"

# The producer with the real dispatch.sh functions: the reviewer's first gate
# writes the verdict and records the locator it was given; a planted locator
# in the dispatcher's environment never reaches a gate.
RP="$(rv_story "$PB" rp HOM-13.S5)"; accept --story "$RP" --kind pm-auto --actor pm
VP="$(verdict HOM-13.S5 HOM-13.S1 APPROVE)"; printf '%s\n' "$VP" >"$TMPROOT/vp.json"
G1="$(printf 'printf "%%s\\n" "${AFK_GATE_STORY-unset}" >>%q; cp %q "$AFK_GATE_STORY.verdict.json"' "$TMPROOT/gs.prod" "$TMPROOT/vp.json")"
G2="$(printf 'bash %q review-verdict --check' "$AFK")"
AFK_GATE_STORY=/planted/story.md produce "$AFK" "$RP" dispatch:rp "$G1" "$G2"
DP="$(adir2 HOM-13.S5)"
assert_eq "producer: the reviewer cycle passes both gates and records launch, review and outcome" \
  "$RC $OUT $(jq -r .status "$RP.result.json" 2>/dev/null) $([[ -f "$DP/1.c1.review.json" ]] && echo review) $(jq -r .outcome "$DP/1.c1.outcome.json" 2>/dev/null)" \
  "0 ATTEMPT=1 done review RECORDED"
assert_eq "...each gate's AFK_GATE_STORY is the verified story's absolute path, not the planted one" \
  "$(cat "$TMPROOT/gs.prod" 2>/dev/null)" "$(cd "$PB" && pwd -P)/rp.md"
assert_eq "...the review record holds the producer-captured bytes and passes" \
  "$(jq -r '[.verdict_sha256, .check_ok] | map(tostring) | join(" ")' "$DP/1.c1.review.json" 2>/dev/null)" "sha256:$(sha <"$TMPROOT/vp.json") true"
RVSUM="$(sha <"$DP/1.c1.review.json")"
verdict HOM-13.S5 HOM-13.S1 CHANGES_REQUESTED >"$RP.verdict.json"
assert_eq "...a later edit of the worktree verdict changes nothing captured" \
  "$(sha <"$DP/1.c1.review.json") $(jq -r .verdict.verdict "$DP/1.c1.review.json")" "$RVSUM APPROVE"
# A symlinked verdict, named by a relative story path under an exported CDPATH
# that has its own .pm-brief: the locator is still this worktree's story, and
# the producer records what the gate saw, VERDICT_INVALID.
RY="$(rv_story "$PB" ry HOM-13.S7)"; accept --story "$RY" --kind pm-auto --actor pm
G4="$(printf 'printf "%%s\\n" "$AFK_GATE_STORY" >%q; ln -s %q "$AFK_GATE_STORY.verdict.json"' "$TMPROOT/gs.cd" "$TMPROOT/vp.json")"
CDPATH="$W" produce "$AFK" .pm-brief/ry.md dispatch:ry "$G4" "$G2"
assert_eq "producer: a symlinked verdict fails the gate and is recorded VERDICT_INVALID; CDPATH never moves the locator" \
  "$RC $(jq -r .status "$RY.result.json" 2>/dev/null) $(jq -c '[.check_ok, .reasons]' "$(adir2 HOM-13.S7)/1.c1.review.json" 2>/dev/null) $(cat "$TMPROOT/gs.cd" 2>/dev/null)" \
  "0 gates_failed [false,[\"VERDICT_INVALID\"]] $(cd "$PB" && pwd -P)/ry.md"
NP2="$(new_story "$PB" plain2 AFK-Y '.' 'persona: dev')"
G3="$(printf 'printf "%%s\\n" "${AFK_GATE_STORY-unset}" >%q' "$TMPROOT/gs.plain")"
AFK_GATE_STORY=/planted/story.md produce "$AFK" "$NP2" dispatch:plain2 "$G3"
assert_eq "producer: a non-Paperclip gate never sees an inherited AFK_GATE_STORY" "$RC $(cat "$TMPROOT/gs.plain" 2>/dev/null)" "0 unset"

# dispatch.sh main(): the same, end to end. tests/a.sh records each gate's
# locator; agent-flow-kit on the gate PATH is the real kit.
cat >"$W/tests/a.sh" <<EOF
printf '%s\n' "\${AFK_GATE_STORY-unset}" >>"$TMPROOT/gs.main"
EOF
printf '#!/bin/sh\nexec bash "%s" "$@"\n' "$AFK" >"$SB/agent-flow-kit"; chmod +x "$SB/agent-flow-kit"
export AFK_GATE_STORY=/planted/main.md
NATIVE='.model_profile = "claude/strong" | .entitlement_pool = "anthropic-max"'
S12="$(new_story "$WB" mainb HOM-12.S3 "$NATIVE" "home: paperclip:HOM-12
paperclip_issue: $ISSUE
persona: dev
memory_mode: off")"
accept --story "$S12" --kind pm-auto --actor pm
: >"$TMPROOT/gs.main"; run_main "$S12"
assert_eq "main(): a Paperclip gate gets the verified story's absolute path over the planted one" \
  "$RC $(cat "$TMPROOT/gs.main")" "0 $(cd "$WB" && pwd -P)/mainb.md"
SP="$(new_story "$WB" mainplain AFK-MAINPLAIN "$NATIVE" "persona: dev
memory_mode: off")"
: >"$TMPROOT/gs.main"; run_main "$SP"
assert_eq "main(): a non-Paperclip gate has the inherited AFK_GATE_STORY removed" "$RC $(cat "$TMPROOT/gs.main")" "0 unset"
RM="$(rv_story "$WB" rvmain HOM-13.S6 "$NATIVE" $'persona: dev\nmemory_mode: off\n')"
accept --story "$RM" --kind pm-auto --actor pm
printf '{}\n' >"$RM.verdict.json"; H3="$(harness_runs)"
run_main "$RM"; MRC=$RC
latest2 HOM-13.S6
assert_eq "main(): a stale reviewer verdict -> VERDICT_PREEXISTS before the harness, no launch, no cycle consumed" \
  "$MRC $(( $(harness_runs) - H3 )) $(head -c 18 "$RM.blocked" 2>/dev/null) $(nlaunch "$(adir2 HOM-13.S6)") $(jf .state) $(jf .attempt)" \
  "4 0 VERDICT_PREEXISTS: 0 ATTEMPT_NOT_LAUNCHED 1"
[[ "$MRC" == 4 ]] || printf '        %s\n' "$(tail -n 5 <<<"$OUT")"
rm -f "$RM.verdict.json"; : >"$TMPROOT/gs.main"
run_main "$RM"; MRC=$RC
latest2 HOM-13.S6
assert_eq "...cleared, the same cycle 1 of attempt 1 launches; with no verdict the review gate fails" \
  "$MRC $(( $(harness_runs) - H3 )) $(jq -r .status "$RM.result.json" 2>/dev/null) $(jf '[.state, .attempt, .cycle, .gates_ok] | map(tostring) | join(" ")')" \
  "1 1 gates_failed OUTCOME_RECORDED 1 1 false"
assert_eq "...the review record says VERDICT_MISSING, and the gate saw the reviewer's own path" \
  "$(jq -c '[.check_ok, .reasons]' "$(adir2 HOM-13.S6)/1.c1.review.json" 2>/dev/null) $(cat "$TMPROOT/gs.main")" \
  "[false,[\"VERDICT_MISSING\"]] $(cd "$WB" && pwd -P)/rvmain.md"
RNM="$(rv_story "$W" rvtracked HOM-13.S8 "$NATIVE" $'persona: dev\nmemory_mode: off\n')"
accept --story "$RNM" --kind pm-auto --actor pm; H4="$(harness_runs)"
run_main "$RNM"; MRC=$RC
assert_eq "main(): a reviewer verdict path that is not ignored -> VERDICT_PATH_NOT_IGNORED before the harness, no launch" \
  "$MRC $(( $(harness_runs) - H4 )) $(head -c 25 "$RNM.blocked" 2>/dev/null) $(nlaunch "$(adir2 HOM-13.S8)")" \
  "4 0 VERDICT_PATH_NOT_IGNORED: 0"
[[ "$MRC" == 4 ]] || printf '        %s\n' "$(tail -n 5 <<<"$OUT")"
rm -f "$RNM" "$RNM".*
unset AFK_GATE_STORY

printf '\n%d passed, %d failed (%ds)\n' "$PASS" "$FAIL" "$SECONDS"
(( FAIL == 0 ))
