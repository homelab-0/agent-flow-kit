#!/usr/bin/env bash
# paperclip-readiness-tests.sh — `agent-flow-kit paperclip-readiness`, the
# read-only completion reader (lib/afk-paperclip-evidence.sh). Evidence comes
# from the kit's own route-accept and paperclip-evidence producers on a
# fixture /2 plan; each case edits a copy of the ready state. Offline: no
# network, no harness, no Paperclip.
#
# Usage: tests/paperclip-readiness-tests.sh
# Exit:  0 all passed, 1 any failure.

set -uo pipefail

KIT_ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
AFK="$KIT_ROOT/bin/agent-flow-kit"
TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@test GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@test
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

PASS=0 FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; FAIL=$((FAIL + 1)); }
head1() { printf '\n\033[1m%s\033[0m\n' "$1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
sha() { sha256sum | cut -d' ' -f1; }

ISSUE="f3333333-3333-4333-8333-333333333333"
COMMIT="d554c4789ed3930f8a53ac9fdf6503b3187097da"
RG='agent-flow-kit review-verdict --check'
HOME_DIR="$TMPROOT/home"; STATE="$TMPROOT/state"; CONFIG="$TMPROOT/paperclip.json"
AD="$STATE/paperclip/attempts/$ISSUE"; Z="sha256:$(printf '%064d' 0)"; T2="$(printf '%040d' 1)"
mkdir -p "$HOME_DIR" "$STATE/paperclip/plans" "$STATE/paperclip/approvals"
export HOME="$HOME_DIR" AFK_STATE_DIR="$STATE" AFK_PAPERCLIP_CONFIG="$CONFIG"

# The product repository: two commits, the private scope ignored through the
# exclude file every worktree shares, and a linked worktree of it.
R="$TMPROOT/repo"; git init -q "$R"; printf 'a\n' >"$R/a.txt"; printf '*.log\n' >"$R/.gitignore"
printf '.pm-brief/\n' >>"$R/.git/info/exclude"
git -C "$R" add -A; git -C "$R" commit -qm c0; C0="$(git -C "$R" rev-parse HEAD)"
printf 'b\n' >>"$R/a.txt"; git -C "$R" commit -qam c1
W="$TMPROOT/wt"; git -C "$R" worktree add -q --detach "$W" HEAD
F="$TMPROOT/foreign"; git clone -q "$R" "$F"
PB="$R/.pm-brief"; mkdir -p "$PB"
jq -nc --arg c "$COMMIT" --arg r "$R" \
  '{schema:"afk-paperclip-config/2",api_url:"https://paperclip.test",company_id:"cccccccc-cccc-cccc-cccc-cccccccccccc",
    board_user_id:"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
    host:{label:"h",agent_id:"11111111-1111-1111-1111-111111111111",key_ref:"op://x/y"},
    projects:[{paperclip_project_id:"aaaaaaaa-0000-4000-8000-000000000001",slug:"proj1",repo_path:$r,harness:"claude"}],
    interim_comment_approval:{attested_on:"2026-09-27",paperclip_commit:$c}}' >"$CONFIG"
LEDGER="$(jq -nc --arg id "$ISSUE" '{issues:{($id):{slug:"proj1", identifier:"HOM-20", state:"working"}}}')"
printf '%s\n' "$LEDGER" >"$STATE/paperclip/ledger.json"

# put_plan <plan-json> -- the stored record and Josh's approval of its digest,
# rendered and projected exactly as paperclip-plan does.
put_plan() {
  PD="$( (. "$KIT_ROOT/lib/afk-paperclip-plan.sh"; afk_pcp_render "$1") | sha)"
  jq -n --argjson p "$1" --arg d "$PD" '{schema:"afk-paperclip-plan-record/1", state:"posted", digest:$d,
    repo:$p.repo, base:$p.base, stories:$p.stories} + (if $p.schema == "afk-paperclip-plan/2" then {plan_schema:$p.schema} else {} end)' \
    >"$STATE/paperclip/plans/$ISSUE.json"
  approve
}
approve() { jq -nc --arg d "$PD" --arg c "$COMMIT" \
  '{schema:"afk-paperclip-approval/1",kind:"plan",digest:$d,paperclip_commit:$c}' >"$STATE/paperclip/approvals/$ISSUE.json"; }
# S1 and S3 build; S2 reviews S1, S4 reviews S3.
PLAN="$(jq -nc --arg g "$RG" '{schema:"afk-paperclip-plan/2", repo:"/r/repo", base:"main", stories:[
  {id:"HOM-20.S1",title:"B1",size:"S",lane:"l",files:[],gates:["bash tests/a.sh","bash tests/b.sh"],role:"builder"},
  {id:"HOM-20.S2",title:"R1",size:"S",lane:"l",files:[],gates:["bash tests/a.sh",$g],role:"reviewer",reviews:"HOM-20.S1"},
  {id:"HOM-20.S3",title:"B2",size:"S",lane:"l",files:[],gates:["bash tests/a.sh","bash tests/b.sh"],role:"builder"},
  {id:"HOM-20.S4",title:"R2",size:"S",lane:"l",files:[],gates:["bash tests/a.sh",$g],role:"reviewer",reviews:"HOM-20.S3"}]}')"
put_plan "$PLAN"; PD0="$PD"

sp() { printf '%s' "$PB/HOM-20.$1.md"; }
for s in S1 S2 S3 S4; do
  g2='bash tests/b.sh'; [[ "$s" == S2 || "$s" == S4 ]] && g2="$RG"
  printf -- '---\nhome: paperclip:HOM-20\npaperclip_issue: %s\ngates:\n  - "bash tests/a.sh"\n  - "%s"\n---\n# s\n' "$ISSUE" "$g2" >"$(sp "$s")"
  jq -n --arg sid "HOM-20.$s" '{harness:"claude", model_profile:"local-code-standard", effort:"medium", cost_class:"free",
    metered:false, catalog_version:"sha256:abc", placement_required:false, task:{story_id:$sid, tags:["tests"]}, override:null}' >"$(sp "$s").stamp.json"
done
RC=0 OUT=""
tuple() { bash "$AFK" route-accept --story "$(sp "$1")" --verify --json </dev/null 2>/dev/null | jq -c .tuple; }
accept() { bash "$AFK" route-accept --json --story "$(sp "$1")" --kind pm-auto --actor pm </dev/null 2>/dev/null | jq -r '.attempt // .result'; }
snapj() { jq -nc --arg t "$1" '{schema:"afk-snapshot/1", base_commit:null, tree:$t}'; }
launch() { # <S> <cycle> <dispatch-id> [<tree>]
  jq -nc --argjson t "$(tuple "$1")" --argjson s "$(snapj "${4:-$T}")" '{tuple:$t, snapshot:$s}' |
    bash "$AFK" paperclip-evidence launch --story "$(sp "$1")" --cycle "$2" --dispatch-id "$3" --json 2>/dev/null | jq -r .result
}
BG='{"bash tests/a.sh":"pass","bash tests/b.sh":"pass"}'
RGJ="$(jq -nc --arg g "$RG" '{"bash tests/a.sh":"pass", ($g):"pass"}')"
outcome() { # <S> <attempt> <cycle> <dispatch-id> <pre> <post> <gates> [<verdict_text-json>]; OTUP overrides the tuple
  local res; res="$(jq -nc --argjson k "$3" --arg d "$4" --argjson g "$7" '{story:"s.md", cycle:$k, status:"done", launch:{dispatch_id:$d}, gates:$g}')"
  jq -nc --arg r "$res" --argjson t "${OTUP:-$(tuple "$1")}" --argjson a "$(snapj "$5")" --argjson b "$(snapj "$6")" --argjson v "${8:-null}" \
    '{tuple:$t, snapshots:{gate_pre:$a, gate_post:$b}, result_text:($r + "\n"), verdict_text:$v}' |
    bash "$AFK" paperclip-evidence outcome --story "$(sp "$1")" --attempt "$2" --cycle "$3" --dispatch-id "$4" --json 2>/dev/null | jq -r .result
}
vt() { # <reviewer> <target> <verdict> [<findings>] -- the captured verdict text, JSON-encoded
  jq -nc --arg r "HOM-20.$1" --arg t "HOM-20.$2" --arg v "$3" --argjson f "${4:-[]}" \
    '{schema:"afk-review-verdict/1", reviewer_story_id:$r, reviews_story_id:$t, verdict:$v, findings:$f}' | jq -Rs .
}
rd() { OUT="$(bash "$AFK" paperclip-readiness --issue "$ISSUE" --dir "${DIR:-$R}" --json "$@" 2>"$TMPROOT/err" </dev/null)"; RC=$?; }
jf() { jq -r "$1" <<<"$OUT" 2>/dev/null; }
is() { # <name> <exact reasons, comma-joined> [readiness args] -- not ready, exit 3, no evidence set
  local n="$1" w="$2"; shift 2; rd "$@"
  assert_eq "$n" "$RC $(jf '.ready') $(jf '.reasons | join(",")') $(jf .evidence_set_sha256)" "3 false $w null"
}
edit() { local f="$AD/$1"; jq -c --arg z "$Z" --arg t2 "$T2" "$2" "$f" >"$f.t" && mv "$f.t" "$f"; }
reset() { rm -rf "$STATE"; cp -a "$TMPROOT/state0" "$STATE"; PD="$PD0"; rm -f "$HOME_DIR/.config/agent-flow-kit/paperclip/stop"; }
s1() { printf 'HOM-20.S1/1.c1.%s.json' "$1"; }

head1 "1. Ready: real /2 plan, acceptance and producer evidence"
T="$(bash "$AFK" paperclip-evidence snapshot --dir "$R" 2>/dev/null | jq -r .tree)"
for s in S1 S3; do accept "$s" >/dev/null; launch "$s" 1 "d$s" >/dev/null; outcome "$s" 1 1 "d$s" "$T" "$T" "$BG" >/dev/null; done
assert_eq "builder evidence recorded" "$(jq -r .outcome "$AD/$(s1 outcome)")" "RECORDED"
for p in S2:S1 S4:S3; do
  s="${p%%:*}"; accept "$s" >/dev/null; launch "$s" 1 "d$s" >/dev/null
  outcome "$s" 1 1 "d$s" "$T" "$T" "$RGJ" "$(vt "$s" "${p#*:}" APPROVE)" >/dev/null
done
assert_eq "reviewer evidence recorded with a passing review record" \
  "$(jq -r .outcome "$AD/HOM-20.S2/1.c1.outcome.json") $(jq -r .check_ok "$AD/HOM-20.S2/1.c1.review.json")" "RECORDED true"
cp -a "$STATE" "$TMPROOT/state0"
rd
assert_eq "every build and review passes on the current tree -> ready, exit 0, no reasons" \
  "$RC $(jf .ready) $(jf '.reasons | length') $(jf .issue) $(jf .plan_digest) $(jf .tree)" "0 true 0 $ISSUE $PD0 $T"
assert_eq "selected stories: role, target, attempt, cycle, dispatch, digests" \
  "$(jf '[.stories[] | "\(.story_id)/\(.role)/\(.reviews)/\(.attempt).\(.cycle)/\(.dispatch_id)/\(.result_sha256 | test("^sha256:"))/\(.verdict_sha256 != null)"] | join(" ")')" \
  "HOM-20.S1/builder/null/1.1/dS1/true/false HOM-20.S2/reviewer/HOM-20.S1/1.1/dS2/true/true HOM-20.S3/builder/null/1.1/dS3/true/false HOM-20.S4/reviewer/HOM-20.S3/1.1/dS4/true/true"
recs='[]'
for f in "$AD"/HOM-20.S*/1.*; do
  recs="$(jq -c --arg s "$(jq -r .story_id "$f")" --arg kd "$(jq -r .kind "$f")" --arg h "sha256:$(jq -cS . "$f" | sha)" \
    '. + [{story_id:$s, attempt:1, cycle:(if $kd == "accept" then null else 1 end), kind:$kd, sha256:$h}]' <<<"$recs")"
done
WANT="sha256:$(jq -cSn --arg i "$ISSUE" --arg pd "$PD0" --arg t "$T" --argjson r "$recs" \
  '{schema:"afk-paperclip-evidence-set/1", issue:$i, plan_digest:$pd, tree:$t, records:($r | sort_by([.story_id, .attempt, .cycle, .kind]))}' | sha)"
assert_eq "the evidence set hash binds exactly the selected accept/launch/outcome/review records (14)" \
  "$(jf .evidence_set_sha256) $(jq length <<<"$recs")" "$WANT 14"
READY="$OUT"
sumall() {
  { (cd "$STATE" && find . \( -type f -o -type l \) | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s ' "$f"; if [[ -L "$f" ]]; then readlink "$f"; else sha <"$f"; fi; done)
    git -C "$R" status --porcelain=v1 -uall --ignored; git -C "$R" rev-parse HEAD; sha <"$R/.git/index"; find "$PB" -type f | LC_ALL=C sort; } | sha
}
git -C "$R" status >/dev/null; B="$(sumall)"
SPY="$TMPROOT/spy"; mkdir -p "$SPY"
for b in curl wget claude codex opencode orca orca-ide ssh; do printf '#!/bin/sh\ntouch "%s/called"\nexit 1\n' "$TMPROOT" >"$SPY/$b"; chmod +x "$SPY/$b"; done
PATH="$SPY:$PATH" AFK_CURL_BIN="$SPY/curl" rd; PATH="$SPY:$PATH" AFK_CURL_BIN="$SPY/curl" rd
assert_eq "repeated queries: the same answer, state, product and private files byte-identical, no network or model call" \
  "$OUT $(sumall) $([[ -e "$TMPROOT/called" ]] && echo CALLED) $([[ -e "$STATE/paperclip/spool" ]] && echo SPOOL)" "$READY $B  "
OUT="$(bash "$AFK" paperclip-readiness --issue "$ISSUE" --dir "$R" 2>/dev/null </dev/null)"; RC=$?
assert_eq "text mode on ready" "$OUT $RC" "ready tree=$T evidence_set_sha256=$WANT 0"
rd --commit "$(git -C "$R" rev-parse HEAD)"
assert_eq "a supplied commit recording the tested tree -> ready" "$RC $(jf .evidence_set_sha256)" "0 $WANT"
DIR="$W" rd
assert_eq "a linked worktree of the owner's repository on the same tree -> ready" "$RC $(jf .evidence_set_sha256)" "0 $WANT"
printf 'private\n' >"$PB/extra-brief.md"; rd
assert_eq "an ignored private brief does not change product identity" "$RC $(jf .evidence_set_sha256)" "0 $WANT"
rm -f "$PB/extra-brief.md"
assert_eq "no automatic caller: only the CLI routes to the reader" \
  "$(grep -rlE 'paperclip-readiness|afk_pce_readiness|afk_cmd_paperclip_readiness' "$KIT_ROOT/bin" "$KIT_ROOT/lib" "$KIT_ROOT/files" | sed "s|^$KIT_ROOT/||" | LC_ALL=C sort | paste -sd' ' -)" \
  "bin/agent-flow-kit lib/afk-paperclip-evidence.sh"

head1 "2. Usage"
for args in "--issue $ISSUE" "--dir $R" "--issue nope --dir $R" "--issue $ISSUE --dir $R --commit xyz" \
            "--issue $ISSUE --dir $R --bogus" "--issue $ISSUE --dir $R --commit"; do
  # shellcheck disable=SC2086
  bash "$AFK" paperclip-readiness $args >/dev/null 2>&1 </dev/null; RC=$?
  assert_eq "invalid usage -> exit 1: $args" "$RC" "1"
done
bash "$AFK" paperclip-readiness --issue "$ISSUE" --dir "$R" --commit '' >/dev/null 2>&1 </dev/null; RC=$?
assert_eq "invalid usage -> exit 1: an explicit empty --commit" "$RC" "1"

head1 "3. Plan and approval"
rm -f "$STATE/paperclip/approvals/$ISSUE.json"; is "approval withdrawn" "PLAN_NOT_APPROVED"
OUT="$(bash "$AFK" paperclip-readiness --issue "$ISSUE" --dir "$R" 2>/dev/null </dev/null)"; RC=$?
assert_eq "text mode on not ready" "$OUT $RC" "not ready: PLAN_NOT_APPROVED 3"
reset; rm -f "$STATE/paperclip/plans/$ISSUE.json"; is "lost plan record" "PLAN_NOT_APPROVED,PLAN_RECORD_INVALID"
reset; printf '{' >"$STATE/paperclip/plans/$ISSUE.json"; is "corrupt plan record" "PLAN_NOT_APPROVED,PLAN_RECORD_INVALID"
reset; mv "$STATE/paperclip/plans/$ISSUE.json" "$TMPROOT/p.json"; ln -s "$TMPROOT/p.json" "$STATE/paperclip/plans/$ISSUE.json"
is "symlinked plan record" "PLAN_RECORD_INVALID"
reset; P="$STATE/paperclip/plans/$ISSUE.json"; jq -c '.stories[1].role = "builder" | del(.stories[1].reviews)' "$P" >"$P.t"; mv "$P.t" "$P"
is "a story's role edited under the approved digest" "PLAN_DIGEST_MISMATCH"
reset; put_plan "$(jq -c '.stories[0].title = "B1 again"' <<<"$PLAN")"
is "re-plan: every recorded tuple binds the old plan" \
  "PLAN_BINDING_CHANGED:HOM-20.S1,PLAN_BINDING_CHANGED:HOM-20.S2,PLAN_BINDING_CHANGED:HOM-20.S3,PLAN_BINDING_CHANGED:HOM-20.S4"
reset; put_plan "$(jq -c '.stories[1].reviews = "HOM-20.S2"' <<<"$PLAN")"; is "an approved self-review plan" "PLAN_REVIEW_TARGET_INVALID"
reset; put_plan "$(jq -c '.schema = "afk-paperclip-plan/1" | .stories |= map(del(.role, .reviews))' <<<"$PLAN")"
is "an approved /1 plan is never ready" "PLAN_HAS_NO_REVIEW_ROLES"
assert_eq "...and stays approved for everything else" "$(bash "$AFK" paperclip-approval --issue "$ISSUE" --json 2>/dev/null | jq -r .approved)" "true"
reset
for f in HOM-20.S1/1.accept.json "$(s1 launch)" "$(s1 outcome)"; do
  edit "$f" '.tuple.plan_story_sha256 = $z | if has("tuple_at_outcome") then .tuple_at_outcome.plan_story_sha256 = $z else . end'
done
is "a tuple bound to another plan story hash" "PLAN_BINDING_CHANGED:HOM-20.S1"

head1 "4. Newest attempt only, never an older success"
reset; accept S1 >/dev/null; is "a newer accepted, unlaunched attempt" "ATTEMPT_NOT_LAUNCHED:HOM-20.S1"
reset; accept S1 >/dev/null; launch S1 1 dS1b >/dev/null; is "a newer launched, unfinished attempt" "ATTEMPT_UNFINISHED:HOM-20.S1"
reset; for k in accept c1.launch c1.outcome; do jq -c '.attempt = 9' "$AD/HOM-20.S1/1.$k.json" >"$AD/HOM-20.S1/9.$k.json"; done
rd; assert_eq "numeric order: attempt 9 selected over 1" "$RC $(jf '.stories[0].attempt')" "0 9"
jq -c '.attempt = 10' "$AD/HOM-20.S1/1.accept.json" >"$AD/HOM-20.S1/10.accept.json"
is "...then 10 (unlaunched) over 9, never a name order" "ATTEMPT_NOT_LAUNCHED:HOM-20.S1"
reset; rm -rf "$AD/HOM-20.S3"; jq '.metered = true' "$(sp S3).stamp.json" >"$TMPROOT/st"; cp "$(sp S3).stamp.json" "$TMPROOT/st0"
cp "$TMPROOT/st" "$(sp S3).stamp.json"; RA="$(accept S3)"; cp "$TMPROOT/st0" "$(sp S3).stamp.json"
assert_eq "a routing refusal before acceptance creates no attempt" "$RA $([[ -e "$AD/HOM-20.S3" ]] && echo D)" "PM_AUTO_NOT_FREE "
is "...so the story has no evidence at all" "STORY_EVIDENCE_MISSING:HOM-20.S3"

head1 "5. Records: malformed, symlinked, foreign"
reset; printf '{' >"$AD/$(s1 outcome)"; is "malformed outcome" "RECORD_INVALID:HOM-20.S1"
reset; cat "$AD/$(s1 launch)" "$AD/$(s1 launch)" >"$TMPROOT/two"; cp "$TMPROOT/two" "$AD/$(s1 launch)"; is "two values in a launch record" "RECORD_INVALID:HOM-20.S1"
reset; mv "$AD/$(s1 outcome)" "$TMPROOT/o.json"; ln -s "$TMPROOT/o.json" "$AD/$(s1 outcome)"; is "symlinked outcome" "RECORD_INVALID:HOM-20.S1"
reset; ln -s "$TMPROOT/nowhere" "$AD/HOM-20.S1/2.accept.json"; is "a dangling newer acceptance is not passed over" "RECORD_INVALID:HOM-20.S1"
reset; mv "$AD/HOM-20.S1" "$TMPROOT/s1dir"; ln -s "$TMPROOT/s1dir" "$AD/HOM-20.S1"; is "symlinked attempt directory" "RECORD_INVALID:HOM-20.S1"
reset; edit "$(s1 outcome)" '.dispatch_id = "dX"'; is "an outcome of another dispatch" "RECORD_INVALID:HOM-20.S1"
reset; edit "$(s1 outcome)" '.attempt = 2'; is "an outcome of another attempt" "RECORD_INVALID:HOM-20.S1"
reset; edit "$(s1 launch)" '.accept_tuple_match = false'; is "accept_tuple_match false" "TUPLE_MISMATCH:HOM-20.S1"
reset; edit "$(s1 outcome)" '.tuple_at_outcome.stamp_sha256 = $z'; is "a stale tuple at outcome" "TUPLE_MISMATCH:HOM-20.S1"
reset; edit "$(s1 outcome)" '.snapshots.gate_post = null'; is "a null snapshot never compares as success" "SNAPSHOT_MISSING:HOM-20.S1"

head1 "6. Outcomes and gates"
reset; accept S1 >/dev/null; launch S1 1 dS1c >/dev/null; OTUP="$(tuple S1)"; rm -f "$STATE/paperclip/approvals/$ISSUE.json"
outcome S1 2 1 dS1c "$T" "$T" "$BG" >/dev/null; approve; unset OTUP
is "APPROVAL_CHANGED, even after re-approval" "OUTCOME_NOT_RECORDED:HOM-20.S1,TUPLE_MISMATCH:HOM-20.S1"
reset; edit "$(s1 outcome)" '.status = "gates_failed" | .gates_ok = false | .result.gates["bash tests/b.sh"] = "fail"'
is "a failed build" "STORY_NOT_DONE:HOM-20.S1,GATES_NOT_PASSED:HOM-20.S1"
reset; edit "$(s1 outcome)" '.result.gates["bash extra.sh"] = "pass"'; is "an extra gate key" "GATE_SET_MISMATCH:HOM-20.S1"
reset; edit "$(s1 outcome)" 'del(.result.gates["bash tests/b.sh"])'; is "a missing gate key" "GATE_SET_MISMATCH:HOM-20.S1"
reset; edit "$(s1 outcome)" '.snapshots.gate_post.tree = $t2'
is "a builder gate moved the tree" "BUILDER_GATES_MUTATED:HOM-20.S1,TREE_CHANGED:HOM-20.S1,REVIEW_TREE_MISMATCH:HOM-20.S2"

head1 "7. Reviews: missing, rejected, invalid, not independent"
reset; rm -f "$AD/HOM-20.S2/1.c1.review.json"; is "missing review record" "REVIEW_MISSING:HOM-20.S2"
reset; accept S2 >/dev/null; launch S2 1 dS2b >/dev/null; OTUP="$(tuple S2)"
mv "$STATE/paperclip/plans/$ISSUE.json" "$TMPROOT/plan.away"
outcome S2 2 1 dS2b "$T" "$T" "$RGJ" "$(vt S2 S1 APPROVE)" >/dev/null; mv "$TMPROOT/plan.away" "$STATE/paperclip/plans/$ISSUE.json"; unset OTUP
is "a plan lost mid-review leaves no review record, and the reviewer is never read as a builder" \
  "OUTCOME_NOT_RECORDED:HOM-20.S2,TUPLE_MISMATCH:HOM-20.S2,REVIEW_MISSING:HOM-20.S2"
assert_eq "...its role stays reviewer" "$(jf '.stories[1].role')" "reviewer"
rcase() { # <name> <reasons> <gates> <verdict_text-json> -- a fresh reviewer cycle 2 of S2
  reset; launch S2 2 dS2x >/dev/null; outcome S2 1 2 dS2x "$T" "$T" "$3" "$4" >/dev/null; is "$1" "$2"
}
rcase "CHANGES_REQUESTED" "REVIEW_NOT_APPROVED:HOM-20.S2,REVIEW_CHECK_NOT_OK:HOM-20.S2" "$RGJ" "$(vt S2 S1 CHANGES_REQUESTED)"
rcase "an open major" "REVIEW_OPEN_MAJOR:HOM-20.S2,REVIEW_CHECK_NOT_OK:HOM-20.S2" "$RGJ" \
  "$(vt S2 S1 APPROVE '[{"severity":"major","status":"open","summary":"x"}]')"
rcase "no verdict captured" "REVIEW_VERDICT_MISSING:HOM-20.S2,REVIEW_CHECK_NOT_OK:HOM-20.S2" "$RGJ" null
rcase "an invalid verdict" "REVIEW_INVALID:HOM-20.S2,REVIEW_CHECK_NOT_OK:HOM-20.S2" "$RGJ" '"not json"'
rcase "a verdict naming another builder" "REVIEW_IDS_MISMATCH:HOM-20.S2,REVIEW_CHECK_NOT_OK:HOM-20.S2" "$RGJ" "$(vt S2 S3 APPROVE)"
assert_eq "...the producer's own check also failed" "$(jq -r .check_ok "$AD/HOM-20.S2/1.c2.review.json")" "false"
reset; edit HOM-20.S2/1.c1.review.json '.verdict.reviews_story_id = "HOM-20.S3"'
is "a passing review record of another builder" "REVIEW_IDS_MISMATCH:HOM-20.S2"
assert_eq "...whose check_ok stays true, so the reader's own id check decides" "$(jq -r .check_ok "$AD/HOM-20.S2/1.c1.review.json")" "true"
rcase "the canonical check failed" "GATES_NOT_PASSED:HOM-20.S2,REVIEW_GATE_NOT_PASSED:HOM-20.S2" \
  "$(jq -c --arg g "$RG" '.[$g] = "fail"' <<<"$RGJ")" "$(vt S2 S1 APPROVE)"
rcase "the canonical check missing" "GATE_SET_MISMATCH:HOM-20.S2,REVIEW_GATE_NOT_PASSED:HOM-20.S2" \
  '{"bash tests/a.sh":"pass"}' "$(vt S2 S1 APPROVE)"
reset; edit HOM-20.S2/1.c1.review.json '.dispatch_id = "dS9"'; is "a review record of another dispatch" "REVIEW_FOREIGN:HOM-20.S2"
reset; rm -f "$AD/HOM-20.S2/1.c1.review.json"; mkdir "$AD/HOM-20.S2/1.c1.review.json"; is "a directory at the review record" "REVIEW_INVALID:HOM-20.S2"
reset; for k in launch outcome review; do edit "HOM-20.S2/1.c1.$k.json" '.dispatch_id = "dS1"'; done
is "self-review: the builder's own dispatch" "REVIEW_NOT_INDEPENDENT:HOM-20.S2,DISPATCH_ID_REUSED:dS1"
reset; for k in launch outcome; do edit "HOM-20.S3/1.c1.$k.json" '.dispatch_id = "dS1"'; done; is "two builders, one dispatch" "DISPATCH_ID_REUSED:dS1"
reset; launch S2 2 dS2e >/dev/null; outcome S2 1 2 dS2e "$T" "$T2" "$RGJ" "$(vt S2 S1 APPROVE)" >/dev/null
is "a reviewer edit during its gates" "REVIEW_TREE_MUTATED:HOM-20.S2"
reset; launch S2 2 dS2t "$T2" >/dev/null; outcome S2 1 2 dS2t "$T2" "$T2" "$RGJ" "$(vt S2 S1 APPROVE)" >/dev/null
is "a review of another tree" "REVIEW_TREE_MISMATCH:HOM-20.S2"

head1 "8. Current tree, commit and repository"
reset; for p in S3:dS3n S4:dS4n; do launch "${p%%:*}" 2 "${p#*:}" "$T2" >/dev/null; done
outcome S3 1 2 dS3n "$T2" "$T2" "$BG" >/dev/null; outcome S4 1 2 dS4n "$T2" "$T2" "$RGJ" "$(vt S4 S3 APPROVE)" >/dev/null
is "multiple builders, one tested a stale tree" "TREE_CHANGED:HOM-20.S3"
reset; printf 'edit\n' >>"$R/a.txt"; is "a current product edit" "TREE_CHANGED:HOM-20.S1,TREE_CHANGED:HOM-20.S3"
git -C "$R" checkout -q -- a.txt
printf '{}\n' >"$R/notes.md.result.json"; is "a non-ignored sidecar-named file is product" "TREE_CHANGED:HOM-20.S1,TREE_CHANGED:HOM-20.S3"
rm -f "$R/notes.md.result.json"
is "a supplied commit of another tree" "COMMIT_TREE_MISMATCH" --commit "$C0"
is "an unknown commit" "COMMIT_TREE_MISMATCH" --commit deadbeef
is "a tree id is not a commit" "COMMIT_TREE_MISMATCH" --commit "$T"
DIR="$F" is "a clone outside the owner's repository" "WORKTREE_FOREIGN"
GIT_DIR="$F/.git" DIR="$F" is "...also under an ambient GIT_DIR naming the clone" "WORKTREE_FOREIGN"
GIT_DIR="$R/.git" GIT_WORK_TREE="$R" DIR="$F" is "...and when GIT_DIR/GIT_WORK_TREE name the owner" "WORKTREE_FOREIGN"
GIT_DIR="$F/.git" GIT_WORK_TREE="$F" GIT_INDEX_FILE="$TMPROOT/no-index" GIT_COMMON_DIR="$F/.git" rd
assert_eq "the owner's worktree under ambient redirection to the clone -> ready" \
  "$RC $(jf .evidence_set_sha256) $([[ -e "$TMPROOT/no-index" ]] && echo INDEX)" "0 $WANT "
mkdir -p "$TMPROOT/plain"; DIR="$TMPROOT/plain" is "no repository" \
  "TREE_UNAVAILABLE,WORKTREE_FOREIGN"

head1 "9. Ledger and legacy finals: reported, never touched"
lput() { printf '%s\n' "$1" >"$STATE/paperclip/ledger.json"; }
reset; rm -f "$STATE/paperclip/ledger.json"; is "missing ledger (and so no owner)" "LEDGER_NOT_ACTIVE,OWNER_REPO_UNKNOWN"
reset; printf '{"issues":' >"$STATE/paperclip/ledger.json"; is "unparseable ledger" "LEDGER_NOT_ACTIVE,OWNER_REPO_UNKNOWN"
for st in waiting_human queued closed stopped nonsense; do
  reset; lput "$(jq -c --arg id "$ISSUE" --arg s "$st" '.issues[$id].state = $s' <<<"$LEDGER")"; is "ledger state $st" "LEDGER_NOT_ACTIVE"
done
reset; lput "$(jq -c '.issues = {}' <<<"$LEDGER")"; is "issue not in the ledger" "LEDGER_NOT_ACTIVE,OWNER_REPO_UNKNOWN"
reset; mv "$STATE/paperclip/ledger.json" "$TMPROOT/l.json"; ln -s "$TMPROOT/l.json" "$STATE/paperclip/ledger.json"; is "symlinked ledger" "LEDGER_NOT_ACTIVE"
reset; mkdir -p "$HOME_DIR/.config/agent-flow-kit/paperclip"; : >"$HOME_DIR/.config/agent-flow-kit/paperclip/stop"; is "stop flag" "LEDGER_NOT_ACTIVE"
legacy() { # <name> -- two reads leave every byte as it was
  local b; b="$(sumall)"; is "$1" "LEGACY_FINAL_PRESENT"; rd; assert_eq "...state byte-identical after repeated reads" "$(sumall)" "$b"
}
reset; lput "$(jq -c --arg id "$ISSUE" '.issues[$id].pending_final = "done"' <<<"$LEDGER")"; legacy "pending_final"
reset; lput "$(jq -c --arg id "$ISSUE" '.issues[$id].final_delivery_hold = {status:"in_review"}' <<<"$LEDGER")"; legacy "final_delivery_hold"
reset; mkdir -p "$STATE/paperclip/spool/$ISSUE"; printf 'in_review' >"$STATE/paperclip/spool/$ISSUE/.final"; legacy "spool .final"

printf '\n%d passed, %d failed (%ds)\n' "$PASS" "$FAIL" "$SECONDS"
(( FAIL == 0 ))
