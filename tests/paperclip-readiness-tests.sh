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
mkstories() { # the four stories and their stamps under $PB
  local s g2
  for s in S1 S2 S3 S4; do
    g2='bash tests/b.sh'; [[ "$s" == S2 || "$s" == S4 ]] && g2="$RG"
    printf -- '---\nhome: paperclip:HOM-20\npaperclip_issue: %s\ngates:\n  - "bash tests/a.sh"\n  - "%s"\n---\n# s\n' "$ISSUE" "$g2" >"$(sp "$s")"
    jq -n --arg sid "HOM-20.$s" '{harness:"claude", model_profile:"local-code-standard", effort:"medium", cost_class:"free",
      metered:false, catalog_version:"sha256:abc", placement_required:false, task:{story_id:$sid, tags:["tests"]}, override:null}' >"$(sp "$s").stamp.json"
  done
}
mkstories
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
assert_eq "readiness callers: the verb, the reader and the poller's withdrawal recompute only" \
  "$(grep -rlE 'paperclip-readiness|afk_pce_readiness|afk_cmd_paperclip_readiness' "$KIT_ROOT/bin" "$KIT_ROOT/lib" "$KIT_ROOT/files" | sed "s|^$KIT_ROOT/||" | LC_ALL=C sort | paste -sd' ' -)" \
  "bin/agent-flow-kit lib/afk-paperclip-evidence.sh lib/afk-paperclip.sh"
assert_eq "  ...the poller calls the shared reader on exactly one line" \
  "$(grep -cE 'paperclip-readiness|afk_pce_readiness|afk_cmd_paperclip_readiness' "$KIT_ROOT/lib/afk-paperclip.sh")" "1"

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
for st in waiting_human queued closed stopped stranded nonsense; do
  reset; lput "$(jq -c --arg id "$ISSUE" --arg s "$st" '.issues[$id].state = $s' <<<"$LEDGER")"; is "ledger state $st (no question)" "LEDGER_NOT_ACTIVE"
done
reset; lput "$(jq -c --arg id "$ISSUE" '.issues[$id] += {state:"waiting_human", question_id:"", question_seq:1}' <<<"$LEDGER")"
is "waiting_human with an empty question id" "LEDGER_NOT_ACTIVE"
reset; lput "$(jq -c --arg id "$ISSUE" '.issues[$id] += {question_id:"q-7", question_seq:"4"}' <<<"$LEDGER")"
is "a malformed question seq" "LEDGER_NOT_ACTIVE"
# Not the poller's question form, even with a reply bound to exactly it.
Q65="$(printf 'q%.0s' {1..65})"
for qs in '"q 7" 4' "\"$Q65\" 4" '"q-7" 4.5' '"q-7" -1'; do
  q="${qs% *}" s="${qs##* }"
  reset; lput "$(jq -c --arg id "$ISSUE" --argjson q "$q" --argjson s "$s" \
    '.issues[$id] += {question_id:$q, question_seq:$s, question_reply:{question_id:$q, question_seq:$s}}' <<<"$LEDGER")"
  is "a malformed question identity with a matching reply: ${q:0:12} $s" "LEDGER_NOT_ACTIVE"
done
# The row a resume into a full project and a FIFO promotion leave behind
# (paperclip-poll-tests.sh section 21): working, the question unanswered.
QROW='{question_id:"q-7", question_seq:4, question_sent_at:"2026-03-01T00:00:00.000Z"}'
reset; lput "$(jq -c --arg id "$ISSUE" ".issues[\$id] += $QROW" <<<"$LEDGER")"; is "working with an unanswered question" "QUESTION_OPEN"
for rp in '{question_id:"q-7", question_seq:3}' '{question_id:"q-6", question_seq:4}' '"q-7"'; do
  reset; lput "$(jq -c --arg id "$ISSUE" ".issues[\$id] += $QROW + {question_reply:$rp}" <<<"$LEDGER")"
  is "a reply bound to another question or seq, or malformed: $rp" "QUESTION_OPEN"
done
reset; lput "$(jq -c --arg id "$ISSUE" ".issues[\$id] += $QROW + {question_reply:{question_id:\"q-7\", question_seq:4}}" <<<"$LEDGER")"
rd; assert_eq "a reply bound to the latest question id and seq -> ready, the same evidence" "$RC $(jf .evidence_set_sha256)" "0 $WANT"
lput "$(jq -c --arg id "$ISSUE" ".issues[\$id] += $QROW + {state:\"waiting_human\", question_reply:{question_id:\"q-7\", question_seq:4}}" <<<"$LEDGER")"
rd; assert_eq "...in waiting_human too" "$RC $(jf .evidence_set_sha256)" "0 $WANT"
mkdir -p "$HOME_DIR/.config/agent-flow-kit/paperclip"; : >"$HOME_DIR/.config/agent-flow-kit/paperclip/stop"
is "...but never past the stop flag" "LEDGER_NOT_ACTIVE"
reset; lput "$(jq -c --arg id "$ISSUE" ".issues[\$id] += $QROW + {question_id:\"plan-${PD0:0:8}\"}" <<<"$LEDGER")"
is "a plan question the stored record does not name stays open" "QUESTION_OPEN"
reset; lput "$(jq -c '.issues = {}' <<<"$LEDGER")"; is "issue not in the ledger" "LEDGER_NOT_ACTIVE,OWNER_REPO_UNKNOWN"
reset; mv "$STATE/paperclip/ledger.json" "$TMPROOT/l.json"; ln -s "$TMPROOT/l.json" "$STATE/paperclip/ledger.json"; is "symlinked ledger" "LEDGER_NOT_ACTIVE"
reset; mkdir -p "$HOME_DIR/.config/agent-flow-kit/paperclip"; : >"$HOME_DIR/.config/agent-flow-kit/paperclip/stop"; is "stop flag" "LEDGER_NOT_ACTIVE"
legacy() { # <name> -- two reads leave every byte as it was
  local b; b="$(sumall)"; is "$1" "LEGACY_FINAL_PRESENT"; rd; assert_eq "...state byte-identical after repeated reads" "$(sumall)" "$b"
}
reset; lput "$(jq -c --arg id "$ISSUE" '.issues[$id].pending_final = "done"' <<<"$LEDGER")"; legacy "pending_final"
reset; lput "$(jq -c --arg id "$ISSUE" '.issues[$id].final_delivery_hold = {status:"in_review"}' <<<"$LEDGER")"; legacy "final_delivery_hold"
reset; mkdir -p "$STATE/paperclip/spool/$ISSUE"; printf 'in_review' >"$STATE/paperclip/spool/$ISSUE/.final"; legacy "spool .final"

# Only a strict afk-paperclip-final/2 marker is not legacy; it proves nothing.
MK="$STATE/paperclip/spool/$ISSUE/.final"
fin() { mkdir -p "$STATE/paperclip/spool/$ISSUE"; printf '%s' "$1" >"$MK"; }
M2="$(jq -nc --arg i "$ISSUE" --arg z "$Z" '{schema:"afk-paperclip-final/2", entry_id:"e0000000-0000-4000-8000-000000000001", issue:$i, evidence_set_sha256:$z}')"
reset; fin "$M2"; b="$(sumall)"; rd; rd
assert_eq "a strict /2 marker with valid evidence -> ready, and its bytes stay as they were" "$RC $(jf .evidence_set_sha256) $(sumall)" "0 $WANT $b"
rm -f "$STATE/paperclip/approvals/$ISSUE.json"; is "...every other check still applies" "PLAN_NOT_APPROVED"
reset; fin "$M2"; lput "$(jq -c --arg id "$ISSUE" '.issues[$id].pending_final = "done"' <<<"$LEDGER")"; legacy "a /2 marker beside a pending_final"
for e in '. + {extra:1}' 'del(.entry_id)' '.schema = "afk-paperclip-final/3"' '.issue = "f4444444-4444-4444-8444-444444444444"' \
         '.evidence_set_sha256 |= ascii_upcase' '.evidence_set_sha256 |= ltrimstr("sha256:")' '.entry_id = "e1"' '.issue = 1' '[.]'; do
  reset; fin "$(jq -c "$e" <<<"$M2")"; legacy "a marker that is not strict /2: $e"
done
reset; fin "${M2%\}},\"issue\":\"$ISSUE\"}"; legacy "a /2 marker with a duplicate member"
reset; fin "$M2$M2"; legacy "two /2 markers in one file"
reset; fin "$(printf '%s%4100s' "$M2" '')"; legacy "a /2 marker over 4 KiB"
reset; fin ""; printf '%s' "$M2" >"$TMPROOT/m2"; rm -f "$MK"; ln -s "$TMPROOT/m2" "$MK"; legacy "a symlinked /2 marker"
reset; mkdir -p "$MK"; legacy "a directory at the marker"
# L1 (AFK-PC-DELIVERY-L1/U3) adds exactly one more occurrence: the read-side
# validator comparison in lib/afk-paperclip.sh, which only ever checks an
# untrusted spool input -- it never writes a /2 marker. No producer exists;
# the proxy is narrowed to name it precisely rather than widened to permit it
# anywhere.
assert_eq "no producer: only the reader and the lib validator name the /2 marker schema" \
  "$(grep -rl 'afk-paperclip-final/2' "$KIT_ROOT/bin" "$KIT_ROOT/lib" "$KIT_ROOT/files" | sed "s|^$KIT_ROOT/||" | LC_ALL=C sort | paste -sd' ' -)" \
  "lib/afk-paperclip-evidence.sh lib/afk-paperclip.sh"
assert_eq "  ...and lib/afk-paperclip.sh names it on exactly one line" \
  "$(grep -c 'afk-paperclip-final/2' "$KIT_ROOT/lib/afk-paperclip.sh")" "1"
assert_eq "  ...that line is exactly the validator's schema comparison" \
  "$(grep 'afk-paperclip-final/2' "$KIT_ROOT/lib/afk-paperclip.sh" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" \
  'and (.schema == "afk-paperclip-final/2")'

head1 "10. Answered questions through the public paths"
# A second host world. paperclip-plan publishes a real /2 plan, fixture poll
# passes send its question and read Josh's comments, and the kit's producers
# record the evidence. Nothing seeds waiting_human, a question or an approval.
X="$TMPROOT/w10"; mkdir -p "$X/fix"
AGENT="11111111-1111-1111-1111-111111111111" PROJ="aaaaaaaa-0000-4000-8000-000000000001" BOARD="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
R="$X/repo"; git init -q -b main "$R"; mkdir -p "$R/.afk"
printf 'bash tests/a.sh\nbash tests/b.sh\n%s\n' "$RG" >"$R/.afk/gates-allowlist"; printf '.pm-brief/\n' >>"$R/.git/info/exclude"
git -C "$R" add -A; git -C "$R" commit -qm c0
PB="$R/.pm-brief"; mkdir -p "$PB"; mkstories
STATE="$X/state"; AD="$STATE/paperclip/attempts/$ISSUE"; CONFIG="$X/paperclip.json"; L10="$STATE/paperclip/ledger.json"
export AFK_STATE_DIR="$STATE" AFK_PAPERCLIP_CONFIG="$CONFIG"
jq --arg r "$R" '.projects[0].repo_path = $r' "$TMPROOT/paperclip.json" >"$CONFIG"
mkdir -p "$STATE/paperclip"
jq -nc --arg id "$ISSUE" --arg a "$AGENT" --arg p "$PROJ" '{issues:{($id):{host_agent_id:$a, paperclip_project_id:$p, slug:"proj1",
  identifier:"HOM-20", state:"working", since:"2026-01-01T00:00:00Z", action_text:"AFK host is working on this",
  action_text_applied:"AFK host is working on this"}}, stranded_reported:[], drain_tampered_reported:false, last_successful_pass:null}' >"$L10"
SK="terminal-$(printf 'terminal\0%s' termA | sha256sum | awk '{print $1}')"; mkdir -p "$STATE/pm/scopes/$SK"
jq -nc --arg wp "$R" '{schema:"afk-pm-ownership/2",owned:true,role:"PM",harness:"claude",session:"s",terminal:"termA",
  worktree:{id:"w",path:$wp},run_id:null,observed_at:"2026-09-27T00:00:00Z",observed_epoch:1,
  freshness_seconds:120,transition_id:null,previous:null}' >"$STATE/pm/scopes/$SK/ownership.json"
cat >"$X/orca-cli" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == --version ]] && { echo 1.4.216; exit 0; }
[[ "$1 $2" == "terminal list" ]] && { printf '{"terminals":[{"handle":"termA","connected":true,"orphaned":false}]}'; exit 0; }
exit 1
SH
printf '{"orca_bin":"%s"}\n' "$X/orca-cli" >"$X/host.json"
cat >"$X/op" <<'SH'
#!/usr/bin/env bash
[[ "$1" == read && -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]] && { printf 'KEY-TEST\n'; exit 0; }
exit 2
SH
# curl: a fixture per method and path (first line the status), else no answer.
cat >"$X/curl" <<'SH'
#!/usr/bin/env bash
args=("$@"); n=$#; method=GET
for ((i = 0; i < n; i++)); do [[ "${args[$i]}" == -X ]] && method="${args[$((i + 1))]}"; done
url="${args[$((n - 1))]}"; tmp="${url#*://}"; path="/${tmp#*/}"
printf '%s %s\n' "$method" "$path" >>"$CURL_LOG"
key="${method}_${path#/}"; f="$CURL_FIX/${key//\//_}"
[[ -f "$f" ]] || { printf '000'; exit 0; }
tail -n +2 "$f"; printf '%s' "$(head -1 "$f")"
SH
chmod +x "$X/orca-cli" "$X/op" "$X/curl"
fx() { local k="${1}_${2#/}"; { printf '%s\n' "$3"; [[ -n "${4:-}" ]] && printf '%s\n' "$4"; } >"$X/fix/${k//\//_}"; }
pm() { OUT="$(env -i PATH="$PATH" HOME="$HOME_DIR" LANG=C AFK_STATE_DIR="$STATE" AFK_HOST_CONFIG="$X/host.json" \
  AFK_PAPERCLIP_CONFIG="$CONFIG" ORCA_TERMINAL_HANDLE=termA bash "$AFK" "$@" --json 2>/dev/null </dev/null)"; RC=$?; }
poll() { env -i PATH="$PATH" HOME="$HOME_DIR" LANG=C AFK_STATE_DIR="$STATE" AFK_PAPERCLIP_CONFIG="$CONFIG" \
  AFK_OP_BIN="$X/op" AFK_CURL_BIN="$X/curl" OP_SERVICE_ACCOUNT_TOKEN=t CURL_LOG="$X/curl.log" CURL_FIX="$X/fix" \
  bash "$AFK" paperclip-poll --json >>"$X/poll.out" 2>&1 </dev/null; }
jcm() { jq -nc --arg id "c1000000-0000-4000-8000-00000000000$1" --arg b "$2" --arg c "$3" --arg u "$BOARD" \
  '{id:$id, body:$b, authorUserId:$u, authorAgentId:null, createdAt:$c}'; }
comments() { local IFS=,; fx GET "/api/issues/$ISSUE/comments" 200 "[$*]"; }
sent() { fx POST "/api/issues/$ISSUE/comments" 201 "{\"createdAt\":\"$1\"}"; }
row() { jq -r --arg id "$ISSUE" ".issues[\$id] | $1" "$L10"; }
approved() { bash "$AFK" paperclip-approval --issue "$ISSUE" --json 2>/dev/null </dev/null | jq -r .approved; }
keep() { rm -rf "${X:?}/$1"; cp -a "$STATE" "$X/$1"; }
back() { rm -rf "$STATE"; cp -a "$X/$1" "$STATE"; rm -f "$HOME_DIR/.config/agent-flow-kit/paperclip/stop"; }
fx GET /api/agents/me 200 "{\"id\":\"$AGENT\",\"runtimeConfig\":{\"heartbeat\":{\"enabled\":true,\"intervalSec\":0,\"wakeOnDemand\":true}}}"
fx GET /api/agents/me/inbox-lite 200 "[{\"id\":\"$ISSUE\"}]"
fx GET "/api/issues/$ISSUE" 200 "{\"status\":\"blocked\",\"identifier\":\"HOM-20\",\"projectId\":\"$PROJ\",\"updatedAt\":\"2026-01-01T00:00:00Z\",\"unblockDescriptor\":{\"owner\":{\"agentId\":\"$AGENT\"}}}"
fx GET "/api/projects/$PROJ" 200 "{\"id\":\"$PROJ\",\"name\":\"P\",\"archivedAt\":null,\"codebase\":{\"repoUrl\":null}}"
fx GET "/api/issues/$ISSUE/approvals" 200 '[]'
fx GET /api/health 200 "{\"commit\":\"$COMMIT\"}"
fx POST "/api/agents/$AGENT/wakeup" 202 '{"id":"run-1"}'
fx PATCH "/api/issues/$ISSUE" 200 '{}'

jq -c --arg r "$R" '.repo = $r' <<<"$PLAN" >"$X/plan.json"
pm paperclip-plan --issue "$ISSUE" --plan-file "$X/plan.json"
PDR="$(jq -r .digest <<<"$OUT" 2>/dev/null)"; D8="${PDR:0:8}"
assert_eq "paperclip-plan publishes the /2 plan question" "$RC $(jq -r '"\(.question_id) \(.seq)"' <<<"$OUT" 2>/dev/null)" "0 plan-$D8 1"
comments; sent 2026-03-01T00:00:00.000Z; poll
assert_eq "a poll pass sends it: waiting_human, its seq and Paperclip's createdAt" \
  "$(row '"\(.state) \(.question_id) \(.question_seq) \(.question_sent_at)"')" "waiting_human plan-$D8 1 2026-03-01T00:00:00.000Z"
A1="$(jcm 1 "approve $D8" 2026-03-02T00:00:00.000Z)"; comments "$A1"; poll
assert_eq "the next pass reads Josh's approve comment: the approval of record, still waiting_human" \
  "$(approved) $(row .state)" "true waiting_human"
T="$(bash "$AFK" paperclip-evidence snapshot --dir "$R" 2>/dev/null | jq -r .tree)"
for s in S1 S3; do accept "$s" >/dev/null; launch "$s" 1 "e$s" >/dev/null; outcome "$s" 1 1 "e$s" "$T" "$T" "$BG" >/dev/null; done
for p in S2:S1 S4:S3; do
  s="${p%%:*}"; accept "$s" >/dev/null; launch "$s" 1 "e$s" >/dev/null
  outcome "$s" 1 1 "e$s" "$T" "$T" "$RGJ" "$(vt "$s" "${p#*:}" APPROVE)" >/dev/null
done
rd; R10="$(jf .evidence_set_sha256)"
assert_eq "recorded builder and reviewer evidence is ready in waiting_human" \
  "$RC $(jf .ready) $(jf '.reasons | length') $(jf .plan_digest) $(row .state)" "0 true 0 $PDR waiting_human"
keep approved
lput "$(jq -c --arg id "$ISSUE" '.issues[$id].state = "working"' "$L10")"; rd
assert_eq "...and in working with the same approved plan question" "$RC $(jf .evidence_set_sha256)" "0 $R10"
lput "$(jq -c --arg id "$ISSUE" '.issues[$id].question_seq = 9' "$L10")"; is "a plan question at another seq stays open" "QUESTION_OPEN"
back approved; comments "$A1" "$(jcm 2 "reject $D8" 2026-03-03T00:00:00.000Z)"; poll
is "Josh's reject withdraws the approval and reopens the plan question" "PLAN_NOT_APPROVED,QUESTION_OPEN"

back approved; printf 'Which name?\n' >"$X/q1.md"; pm paperclip-report --issue "$ISSUE" --question q1 --comment-file "$X/q1.md"
comments "$A1"; sent 2026-03-05T00:00:00.000Z; poll
assert_eq "a later non-plan question is sent" "$(row '"\(.state) \(.question_id) \(.question_seq)"')" "waiting_human q1 2"
is "...and is open" "QUESTION_OPEN"
C3="$(jcm 3 "earlier thought" 2026-03-04T00:00:00.000Z)"; comments "$A1" "$C3"; poll
is "a reply older than the question leaves it open" "QUESTION_OPEN"
# A decision-shaped comment on a non-plan question: the plan hook ignores it,
# and it is no reply either. The approval of record is untouched.
AP="$(sha <"$STATE/paperclip/approvals/$ISSUE.json")"
D5="$(jcm 5 "approve $D8" 2026-03-05T00:00:01.000Z)" D6="$(jcm 6 "  reject $D8"$'\n' 2026-03-05T00:00:02.000Z)"
comments "$A1" "$C3" "$D5" "$D6"; poll
is "approve or reject <digest8> on a non-plan question is no reply: still open" "QUESTION_OPEN"
assert_eq "...nothing recorded, and the approval stays exactly as it was" \
  "$(row '.question_reply // "none"') $(sha <"$STATE/paperclip/approvals/$ISSUE.json") $(approved)" "none $AP true"
comments "$A1" "$C3" "$D5" "$D6" "$(jcm 4 "call it foo" 2026-03-06T00:00:00.000Z)"; poll; rd
assert_eq "a qualifying newer Josh reply closes it: ready on the same evidence" \
  "$RC $(jf .evidence_set_sha256) $(row '.question_reply | "\(.question_id) \(.question_seq) \(.comment_id)"')" \
  "0 $R10 q1 2 c1000000-0000-4000-8000-000000000004"
keep replied
mkdir -p "$HOME_DIR/.config/agent-flow-kit/paperclip"; : >"$HOME_DIR/.config/agent-flow-kit/paperclip/stop"
is "despite the reply: the stop flag" "LEDGER_NOT_ACTIVE"
for st in queued stranded closed; do
  back replied; lput "$(jq -c --arg id "$ISSUE" --arg s "$st" '.issues[$id].state = $s' "$L10")"; is "despite the reply: state $st" "LEDGER_NOT_ACTIVE"
done
back replied; rm -f "$STATE/paperclip/approvals/$ISSUE.json"; is "despite the reply: no approval" "PLAN_NOT_APPROVED"
# AC-4 through the plan flow: re-publishing asks again, Josh approves, then
# rejects; the q1 reply stays on the row and changes nothing.
back replied; pm paperclip-plan --issue "$ISSUE" --plan-file "$X/plan.json"
comments "$A1"; sent 2026-03-08T00:00:00.000Z; poll
assert_eq "re-publishing the plan revokes the approval and asks again; the q1 reply stays" \
  "$RC $(row '"\(.question_id) \(.question_seq) \(.question_reply.question_id)"') $(approved)" "0 plan-$D8 3 q1 false"
A7="$(jcm 7 "approve $D8" 2026-03-09T00:00:00.000Z)"; comments "$A1" "$A7"; poll; rd
assert_eq "...Josh approves it again: ready on the same evidence" "$RC $(jf .evidence_set_sha256)" "0 $R10"
comments "$A1" "$A7" "$(jcm 8 "reject $D8" 2026-03-10T00:00:00.000Z)"; poll
is "...then rejects it: refused despite the reply metadata" "PLAN_NOT_APPROVED,QUESTION_OPEN"
assert_eq "...whose q1 reply is still on the row" "$(row '.question_reply.question_id')" "q1"

back replied; printf 'And the colour?\n' >"$X/q2.md"; pm paperclip-report --issue "$ISSUE" --question q2 --comment-file "$X/q2.md"
comments "$A1"; sent 2026-03-07T00:00:00.000Z; poll
is "a second question closes it again" "QUESTION_OPEN"
assert_eq "...the earlier reply stays bound to q1" "$(row '"\(.question_id) \(.question_reply.question_id)"')" "q2 q1"
comments "$A1" "$(jcm 9 "blue" 2026-03-08T00:00:00.000Z)"; poll; rd
assert_eq "a reply to the second question re-binds to it: ready on the same evidence" \
  "$RC $(jf .evidence_set_sha256) $(row '.question_reply | "\(.question_id) \(.question_seq) \(.comment_id)"')" \
  "0 $R10 q2 3 c1000000-0000-4000-8000-000000000009"
printf 'And the size?\n' >"$X/q3.md"; pm paperclip-report --issue "$ISSUE" --question q3 --comment-file "$X/q3.md"
sent 2026-03-09T00:00:00.000Z; poll
is "a third question opens it again" "QUESTION_OPEN"
assert_eq "...the reply stays bound to q2" "$(row '"\(.question_id) \(.question_seq) \(.question_reply.question_id)"')" "q3 4 q2"

head1 "11. Withdrawal: readiness at the recorded paths, through the poller"
# The section-10 world: a committed gates allowlist, a /2 plan approved
# through the public paths, builder and independent reviewer evidence. Each
# case restores a kept state, checks that state's own readiness reasons,
# then persists an intent bound to it with its strict /2 marker and runs real
# poll passes with final_delivery_enabled true. Nothing may be sent.
jq '.final_delivery_enabled = true' "$CONFIG" >"$CONFIG.t" && mv "$CONFIG.t" "$CONFIG"
det11() { # <status> -- the issue detail, with the pinned ownership fields
  fx GET "/api/issues/$ISSUE" 200 "$(jq -nc --arg s "$1" --arg p "$PROJ" --arg a "$AGENT" --arg u "$BOARD" \
    '{status:$s, identifier:"HOM-20", projectId:$p, updatedAt:"2026-01-01T00:00:00Z", assigneeAgentId:$a, createdByUserId:$u}
     + (if $s == "blocked" then {unblockDescriptor:{owner:{agentId:$a}}} else {} end)')"
}
det11 blocked
RP="$(cd -P -- "$R" && pwd -P)"; CD10="$(cd -P -- "$(git -C "$R" rev-parse --path-format=absolute --git-common-dir)" && pwd -P)"
HEADC="$(git -C "$R" rev-parse HEAD)"; FE="e1000000-0000-4000-8000-000000000001"; MK11="$STATE/paperclip/spool/$ISSUE/.final"
intent11() { # <attempts> [<payload jq edit>] -- a persisted intent of the current evidence and its /2 marker
  local p; p="$(jq -nc --arg i "$ISSUE" --arg pd "$PDR" --arg es "$R10" --arg t "$T" --arg c "$HEADC" --arg d "$RP" \
    --arg cd "$CD10" --arg u "$BOARD" '{issue:$i, identifier:"HOM-20", plan_digest:$pd, evidence_set_sha256:$es, tree:$t,
      commit:$c, dir:$d, common_dir:$cd, status:"in_review", reviewer_user_id:$u, body:"ready for review",
      published_at:"2026-10-10T00:00:00Z"}' | jq -c "${2:-.}")"
  lput "$(jq -c --arg id "$ISSUE" --arg e "$FE" --argjson n "$1" --argjson p "$p" \
    '.issues[$id].final_intent = {entry_id:$e, attempts:$n, payload:$p}' "$L10")"
  mkdir -p "$STATE/paperclip/spool/$ISSUE"
  jq -nc --arg e "$FE" --arg i "$ISSUE" --arg es "$(jq -r .evidence_set_sha256 <<<"$p")" \
    '{schema:"afk-paperclip-final/2", entry_id:$e, issue:$i, evidence_set_sha256:$es}' >"$MK11"
}
# zw -- the poll log's POST/PATCH count: exactly one number, 0 when none.
zw() { local n; n="$(grep -cE '^(POST|PATCH) ' "$X/curl.log" 2>/dev/null)"; printf '%s' "${n:-0}"; }
mk11() { if [[ -e "$MK11" ]]; then echo marker; else echo none; fi; }
wd11() { row '[(.final_withdrawn // [] | length), (.final_withdrawn[0].entry_id // "none"), (.final_withdrawn[0].reasons // [] | join(",")),
  (.final_intent.entry_id // "none"), (.final_withdraw_cleanup // "none" | tostring)] | map(tostring) | join(" ")'; }
fw11() { find "$STATE/paperclip/notices/proj1" -name '*.final_withdrawn.json' 2>/dev/null | wc -l | tr -d ' '; }
: >>"$X/curl.log"
assert_eq "the zero-write helper prints exactly one number" "$(zw | wc -l | tr -d ' ') $(zw | grep -cE '^[0-9]+$')" "0 1"

back replied; rd
assert_eq "11a. baseline: the replied state is ready, by its own reasons" \
  "$RC $(jf .ready) $(jf '.reasons | join(",")') $(jf .evidence_set_sha256)" "0 true  $R10"
lput "$(jq -c --arg id "$ISSUE" 'del(.issues[$id].question_reply)' "$L10")"
is "  ...without its reply, q1 is open" "QUESTION_OPEN"
intent11 0; comments "$A1" "$(jcm a "call it bar" 2026-03-11T00:00:00.000Z)"; w0="$(zw)"; poll
assert_eq "  ...an answer seen at the suppression point is saved first: eligible in the same pass, nothing sent" \
  "$(row '.question_reply.comment_id') $(row '.final_intent.eligible.evidence_set_sha256') $(wd11) $(mk11) $(( $(zw) - w0 ))" \
  "c1000000-0000-4000-8000-00000000000a $R10 0 none  $FE none marker 0"

back approved; rd
assert_eq "11b. baseline: the approved state is ready, by its own reasons" "$RC $(jf '.reasons | join(",")') $(jf .evidence_set_sha256)" "0  $R10"
intent11 0; comments "$A1" "$(jcm 2 "reject $D8" 2026-03-03T00:00:00.000Z)"; w0="$(zw)"; poll
assert_eq "  ...a plan reject seen first makes the same-pass recompute PLAN_NOT_APPROVED: withdrawn at attempts 0" \
  "$(approved) $(wd11)" "false 1 $FE PLAN_NOT_APPROVED,QUESTION_OPEN none none"
assert_eq "  ...the full intent is kept in final_withdrawn, its matching marker removed, one notice, nothing sent" \
  "$(row '.final_withdrawn[0] | [.attempts, .payload.evidence_set_sha256, .payload.dir] | map(tostring) | join(" ")') $(mk11) $(fw11) $(( $(zw) - w0 ))" \
  "0 $R10 $RP none 1 0"

back approved; intent11 1; comments "$A1" "$(jcm 2 "reject $D8" 2026-03-03T00:00:00.000Z)"; w0="$(zw)"; poll
assert_eq "11c. attempts>0: a terminal READINESS_CHANGED hold with reasons; intent and marker kept" \
  "$(row '.final_intent.hold | "\(.reason) \(.reasons | join(","))"') $(wd11) $(mk11)" \
  "READINESS_CHANGED PLAN_NOT_APPROVED,QUESTION_OPEN 0 none  $FE none marker"
poll
assert_eq "  ...a later pass never rearms or withdraws it, nothing sent" \
  "$(row '.final_intent.hold.reason') $(wd11) $(mk11) $(( $(zw) - w0 ))" "READINESS_CHANGED 0 none  $FE none marker 0"

# Recorded fields that differ from a ready answer.
PF="$(printf 'f%.0s' {1..64})"
while IFS='|' read -r fld val want; do
  back replied; intent11 0 ".$fld = \"$val\""; comments "$A1"; w0="$(zw)"; poll
  assert_eq "11d. recorded $fld differs from the ready answer: withdrawn with $want, nothing sent" \
    "$(wd11) $(mk11) $(( $(zw) - w0 ))" "1 $FE $want none none none 0"
done <<EOF
evidence_set_sha256|$Z|EVIDENCE_SET_CHANGED
tree|$T2|TREE_CHANGED
plan_digest|$PF|PLAN_CHANGED
EOF

back replied; intent11 0; printf 'edit\n' >"$R/new.txt"; comments "$A1"; w0="$(zw)"; poll
assert_eq "11e. a current product edit: withdrawn with the reader's own reasons" \
  "$(row '.final_withdrawn[0].reasons | [index("COMMIT_TREE_MISMATCH") != null, index("TREE_CHANGED:HOM-20.S1") != null] | map(tostring) | join(" ")') $(mk11) $(( $(zw) - w0 ))" \
  "true true none 0"
rm -f "$R/new.txt"

# The recorded paths themselves, before readiness runs.
XF="$X/foreign"; git clone -q "$R" "$XF"; XFP="$(cd -P -- "$XF" && pwd -P)"; ln -s "$R" "$X/rlink"
while IFS=';' read -r name edit want; do
  back replied; intent11 0 "$edit"; comments "$A1"; w0="$(zw)"; poll
  assert_eq "11f. $name: withdrawn with $want, nothing sent" "$(wd11) $(mk11) $(( $(zw) - w0 ))" "1 $FE $want none none none 0"
done <<EOF
moved or deleted worktree;.dir = "$X/moved-away";TREE_UNAVAILABLE
recorded through a symlink;.dir = "$X/rlink";TREE_UNAVAILABLE
replaced by another repository;.dir = "$XFP" | .common_dir = "$XFP/.git";WORKTREE_FOREIGN
recorded common_dir of another repository;.common_dir = "$XFP/.git";WORKTREE_FOREIGN
EOF

back replied; intent11 0; comments "$A1"; w0="$(zw)"
env -i PATH="$PATH" HOME="$HOME_DIR" LANG=C AFK_STATE_DIR="$STATE" AFK_PAPERCLIP_CONFIG="$CONFIG" \
  AFK_OP_BIN="$X/op" AFK_CURL_BIN="$X/curl" OP_SERVICE_ACCOUNT_TOKEN=t CURL_LOG="$X/curl.log" CURL_FIX="$X/fix" \
  GIT_DIR="$XF/.git" GIT_WORK_TREE="$XF" GIT_COMMON_DIR="$XF/.git" GIT_INDEX_FILE="$X/no-index" \
  bash "$AFK" paperclip-poll --json >>"$X/poll.out" 2>&1 </dev/null
assert_eq "11g. ambient GIT_* naming another repository is ignored by the path checks and readiness: eligible" \
  "$(row '.final_intent.eligible.evidence_set_sha256') $(wd11) $(mk11) $(( $(zw) - w0 )) $([[ -e "$X/no-index" ]] && echo INDEX)" \
  "$R10 0 none  $FE none marker 0 "

# At rest on the ready fixture: two deferrals, a blocked return resets the
# count (and is eligible), then the third consecutive deferral holds.
back replied; intent11 0; comments "$A1"; w0="$(zw)"
p11() { row '.final_intent | [.observed.status, .observed.passes, (.hold.reason // "none"), (.eligible != null)] | map(tostring) | join(" ")'; }
det11 in_progress; poll; poll
assert_eq "11h. not blocked twice: two deferrals, no hold, no eligibility" "$(p11)" "in_progress 2 none false"
det11 blocked; poll
assert_eq "  ...back to blocked before the bound: count reset, eligible" "$(p11)" "blocked 0 none true"
det11 in_progress; poll; poll
assert_eq "  ...two more deferrals from zero: still no hold" "$(p11)" "in_progress 2 none true"
poll
assert_eq "  ...the third consecutive one: terminal NOT_AT_REST, never withdrawn, nothing sent" \
  "$(p11) $(wd11) $(mk11) $(( $(zw) - w0 ))" "in_progress 3 NOT_AT_REST false 0 none  $FE none marker 0"
det11 blocked

printf '\n%d passed, %d failed (%ds)\n' "$PASS" "$FAIL" "$SECONDS"
(( FAIL == 0 ))
