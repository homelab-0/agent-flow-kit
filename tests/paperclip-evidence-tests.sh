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
  stories:[range(1; 11) | {id:"HOM-12.S\(.)", gates:["bash tests/a.sh","bash tests/b.sh"]}]}' >"$STATE/paperclip/plans/$ISSUE.json"
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

printf '\n%d passed, %d failed (%ds)\n' "$PASS" "$FAIL" "$SECONDS"
(( FAIL == 0 ))
