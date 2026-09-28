#!/usr/bin/env bash
# paperclip-accept-tests.sh — `agent-flow-kit route-accept` (lib/afk-accept.sh)
# and dispatch.sh's Paperclip preconditions and .afk/ protected-path check
# (AFK-PC-4). Stub-only: dispatch.sh is sourced as in
# tests/dispatch-secret-scan-tests.sh, the launch is a stub, no harness runs.
#
# Usage: tests/paperclip-accept-tests.sh
# Exit:  0 all passed, 1 any failure.

set -uo pipefail

KIT_ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
AFK="$KIT_ROOT/bin/agent-flow-kit"
DISPATCH="$KIT_ROOT/files/model-router/scripts/dispatch.sh"
TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@test GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@test

PASS=0 FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; FAIL=$((FAIL + 1)); }
head1() { printf '\n\033[1m%s\033[0m\n' "$1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }

ISSUE="e1111111-1111-1111-1111-111111111111"
COMMIT="d554c4789ed3930f8a53ac9fdf6503b3187097da"
PLAND="$(printf 'p' | sha256sum | awk '{print $1}')"
HOME_DIR="$TMPROOT/home"; STATE="$TMPROOT/state"; CONFIG="$TMPROOT/paperclip.json"
mkdir -p "$HOME_DIR" "$STATE/paperclip/plans" "$STATE/paperclip/approvals"
jq -nc --arg c "$COMMIT" --arg r "$TMPROOT" \
  '{api_url:"https://paperclip.test",company_id:"cccccccc-cccc-cccc-cccc-cccccccccccc",
    board_user_id:"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",host_label:"h",
    agents:[{agent_id:"11111111-1111-1111-1111-111111111111",key_ref:"op://x/y",project:"proj1",repo_path:$r,harness:"claude"}],
    interim_comment_approval:{attested_on:"2026-09-27",paperclip_commit:$c}}' >"$CONFIG"
jq -nc --arg d "$PLAND" '{schema:"afk-paperclip-plan-record/1", digest:$d,
  stories:[{id:"HOM-12.S1", gates:["bash tests/a.sh","bash tests/b.sh"]}]}' >"$STATE/paperclip/plans/$ISSUE.json"
approve() { jq -nc --arg d "$PLAND" --arg c "$COMMIT" \
  '{schema:"afk-paperclip-approval/1",kind:"plan",digest:$d,paperclip_commit:$c}' >"$STATE/paperclip/approvals/$ISSUE.json"; }
export HOME="$HOME_DIR" AFK_STATE_DIR="$STATE" AFK_PAPERCLIP_CONFIG="$CONFIG"

# new_story <name> [<stamp-jq-edit>] [<frontmatter-extra>] [<gates-yaml>] -> story path
new_story() {
  local s="$TMPROOT/$1.md"
  printf -- '---\n%s\ngates:\n%s\n---\n# story\n' "${3-home: paperclip:HOM-12
paperclip_issue: $ISSUE}" "${4:-  - \"bash tests/a.sh\"
  - \"bash tests/b.sh\"}" >"$s"
  jq -n '{harness:"claude", model_profile:"local-code-standard", effort:"medium", cost_class:"free",
          metered:false, catalog_version:"sha256:abc", placement_required:true,
          task:{story_id:"HOM-12.S1", tags:["tests"]}, override:null}' | jq "${2:-.}" >"$s.stamp.json"
  printf '%s' "$s"
}
RC=0 OUT=""
accept() { OUT="$(bash "$AFK" route-accept --json "$@" 2>&1)"; RC=$?; }
res() { jq -r .result <<<"$OUT" 2>/dev/null; }

head1 "1. pm-auto refusals, each with its named reason (AC-3)"
approve
accept --story "$(new_story plain '.task.story_id = "AFK-X"' 'persona: dev')" --kind pm-auto --actor pm
assert_eq "no paperclip home -> PM_AUTO_NOT_PAPERCLIP" "$(res) $RC" "PM_AUTO_NOT_PAPERCLIP 4"
accept --story "$(new_story ovr '.override = {actor:"josh", reason:"x"}')" --kind pm-auto --actor pm
assert_eq "an override stamp -> PM_AUTO_NOT_NATURAL" "$(res)" "PM_AUTO_NOT_NATURAL"
accept --story "$(new_story sub '.cost_class = "subscription"')" --kind pm-auto --actor pm
assert_eq "subscription cost class -> PM_AUTO_NOT_FREE" "$(res)" "PM_AUTO_NOT_FREE"
accept --story "$(new_story met '.metered = true')" --kind pm-auto --actor pm
assert_eq "metered -> PM_AUTO_NOT_FREE" "$(res)" "PM_AUTO_NOT_FREE"
for tag in security iam secrets prod-iac destructive-tools; do
  accept --story "$(new_story "hx-$tag" ".task.tags += [\"$tag\"]")" --kind pm-auto --actor pm
  assert_eq "tag $tag -> HARD_EXCLUSION" "$(res)" "HARD_EXCLUSION"
done
accept --story "$(new_story iac '.task.tags += ["iac"]')" --kind pm-auto --actor pm
assert_eq "iac is not prod-iac" "$(res)" "ok"
accept --story "$(new_story hxcase '.task.tags += [" Security "]')" --kind pm-auto --actor pm
assert_eq "tag matching is trimmed and case-folded -> HARD_EXCLUSION" "$(res)" "HARD_EXCLUSION"
accept --story "$(new_story hxstr '.task.tags = "security"')" --kind pm-auto --actor pm
assert_eq "tags that are not an array of strings -> STAMP_INVALID, never a pass" "$(res) $RC" "STAMP_INVALID 4"
S="$(new_story twodoc)"; D2="$(jq '.override = {actor:"x", reason:"y"}' "$S.stamp.json")"; printf '%s\n' "$D2" >>"$S.stamp.json"
accept --story "$S" --kind pm-auto --actor pm
assert_eq "a stamp file holding two documents -> STAMP_INVALID" "$(res)" "STAMP_INVALID"
rm -f "$STATE/paperclip/approvals/$ISSUE.json"
accept --story "$(new_story unappr)" --kind pm-auto --actor pm
assert_eq "no approval -> PLAN_NOT_APPROVED" "$(res)" "PLAN_NOT_APPROVED"
approve
accept --story "$(new_story s2 '.task.story_id = "HOM-12.S2"')" --kind pm-auto --actor pm
assert_eq "story not in the plan -> STORY_NOT_IN_PLAN" "$(res)" "STORY_NOT_IN_PLAN"
accept --story "$(new_story reord . "home: paperclip:HOM-12
paperclip_issue: $ISSUE" '  - "bash tests/b.sh"
  - "bash tests/a.sh"')" --kind pm-auto --actor pm
assert_eq "gates reordered -> STORY_CONTRACT_MUTATED" "$(res)" "STORY_CONTRACT_MUTATED"
accept --story "$(new_story badhome . "home: paperclip:HOM-13
paperclip_issue: $ISSUE")" --kind human --actor josh
assert_eq "home disagreeing with the story id -> STORY_HOME_INVALID" "$(res)" "STORY_HOME_INVALID"
S="$(new_story nostamp)"; rm -f "$S.stamp.json"
accept --story "$S" --kind human --actor josh
assert_eq "no stamp -> STAMP_MISSING, nothing written" "$(res):$([[ -e "$S.acceptance.json" ]] && echo w)" "STAMP_MISSING:"

head1 "2. Writes: pm-auto, human, override (AC-2, AC-3)"
S="$(new_story good)"
WANT="sha256:$(jq -cS '{harness, model_profile, effort, cost_class, metered, catalog_version, task:{story_id: .task.story_id}}' "$S.stamp.json" | sha256sum | awk '{print $1}')"
accept --story "$S" --kind pm-auto --actor pm
assert_eq "pm-auto accepted" "$(res) $RC" "ok 0"
assert_eq "record shape, policy paperclip-free-lane, the AC-2 digest" \
  "$(jq -c '[.schema, .story_id, .decision_digest == $w, .kind, .actor, .policy, .reason]' --arg w "$WANT" "$S.acceptance.json")" \
  '["afk-acceptance/1","HOM-12.S1",true,"pm-auto","pm","paperclip-free-lane",null]'
H="$(new_story human '.cost_class = "subscription" | .metered = true | .task.story_id = "AFK-X"' 'persona: dev')"
accept --story "$H" --kind human --actor josh
assert_eq "human written, provenance only (no policy)" "$(jq -c '[.kind, .actor, .policy]' "$H.acceptance.json")" '["human","josh",null]'
OUT="$(bash "$AFK" route-accept --story "$H" --kind override --actor josh 2>&1)"; RC=$?
assert_eq "override without --reason is a usage error" "$RC" "1"
accept --story "$H" --kind override --actor josh --reason "pool pressure"
assert_eq "override written with its reason" "$(jq -c '[.kind, .reason]' "$H.acceptance.json")" '["override","pool pressure"]'

head1 "3. dispatch preconditions (AC-4), launch stubbed"
# gate_then_launch mirrors main(): after validate_stamp, the marked check,
# then the stubbed launch. The same code on every cycle.
gate_then_launch() { # <story> [<afk-bin>]
  OUT="$(AGENT_FLOW_KIT_BIN="${2:-$AFK}" bash -c '
    . "$1"; CONFIG_FILE=/nonexistent
    launch() { echo LAUNCHED; }
    if paperclip_story_marked "$2" "$2.stamp.json"; then paperclip_preconditions "$2" || exit 4; fi
    launch' _ "$DISPATCH" "$1" 2>&1)"; RC=$?
}
blocked() { head -1 "$1.blocked" 2>/dev/null | cut -d: -f1; }
S="$(new_story disp)"
gate_then_launch "$S"
assert_eq "no acceptance -> ACCEPTANCE_MISSING, exit 4" "$RC $(blocked "$S")" "4 ACCEPTANCE_MISSING"
if [[ "$OUT" != *LAUNCHED* && "$OUT" == *ACCEPTANCE_MISSING* ]]; then ok "  ...not launched, marker named in the output"
else bad "  ...not launched, marker named in the output" "$OUT"; fi
accept --story "$S" --kind pm-auto --actor pm
rm -f "$S.blocked"; gate_then_launch "$S"
assert_eq "everything valid -> launched, no marker" "$RC $OUT $([[ -e "$S.blocked" ]] && echo B)" \
  "0 dispatch: paperclip: acceptance digest, plan approval and story gates verified
LAUNCHED "
jq '.model_profile = "claude/strong" | .cost_class = "subscription"' "$S.stamp.json" >"$S.t" && mv "$S.t" "$S.stamp.json"
gate_then_launch "$S"
assert_eq "re-routed stamp -> ACCEPTANCE_DIGEST_MISMATCH" "$RC $(blocked "$S")" "4 ACCEPTANCE_DIGEST_MISMATCH"
S="$(new_story disp2)"; accept --story "$S" --kind pm-auto --actor pm
gate_then_launch "$S"; assert_eq "cycle 1 passes" "$RC" "0"
sed -i 's#bash tests/b.sh#bash tests/b.sh --skip#' "$S"
gate_then_launch "$S"
assert_eq "cycle 2 after a gate edit -> STORY_CONTRACT_MUTATED" "$RC $(blocked "$S")" "4 STORY_CONTRACT_MUTATED"
S="$(new_story disp3)"; accept --story "$S" --kind pm-auto --actor pm
rm -f "$STATE/paperclip/approvals/$ISSUE.json"
gate_then_launch "$S"
assert_eq "approval withdrawn -> PLAN_NOT_APPROVED" "$RC $(blocked "$S")" "4 PLAN_NOT_APPROVED"
approve
sed -i '/^home:/d' "$S"
gate_then_launch "$S"
assert_eq "dropping home still runs the checks -> STORY_HOME_INVALID" "$RC $(blocked "$S")" "4 STORY_HOME_INVALID"
# The AC-2 digest leaves override and task.tags out, so a pm-auto acceptance
# is re-judged against the current stamp's lane on every cycle.
S="$(new_story lane)"; accept --story "$S" --kind pm-auto --actor pm
jq '.override = {actor:"josh", reason:"pool"}' "$S.stamp.json" >"$S.t" && mv "$S.t" "$S.stamp.json"
gate_then_launch "$S"
assert_eq "pm-auto acceptance, stamp later overridden (same digest) -> PM_AUTO_NOT_NATURAL" "$RC $(blocked "$S")" "4 PM_AUTO_NOT_NATURAL"
jq '.override = null | .task.tags += ["secrets"]' "$S.stamp.json" >"$S.t" && mv "$S.t" "$S.stamp.json"
gate_then_launch "$S"
assert_eq "pm-auto acceptance, hard-exclusion tag added (same digest) -> HARD_EXCLUSION" "$RC $(blocked "$S")" "4 HARD_EXCLUSION"
S="$(new_story forged)"; D="$(jq -r .decision_digest "$TMPROOT/disp2.md.acceptance.json")"
jq -nc --arg d "$D" '{schema:"afk-acceptance/1", story_id:"HOM-12.S1", decision_digest:$d}' >"$S.acceptance.json"
gate_then_launch "$S"
assert_eq "a record with the right digest but no kind/actor -> ACCEPTANCE_INVALID" "$RC $(blocked "$S")" "4 ACCEPTANCE_INVALID"
# A Paperclip story accepts pm-auto only: a human or override record, however
# it was written, is refused, and a hard-excluded stamp stays refused whatever
# the kind. route-accept will not write one either.
forge() { # <story> <kind> -- a record with the right digest, written directly
  jq -nc --arg k "$2" --arg d "sha256:$(jq -cS '{harness, model_profile, effort, cost_class, metered, catalog_version, task:{story_id: .task.story_id}}' "$1.stamp.json" | sha256sum | awk '{print $1}')" \
    '{schema:"afk-acceptance/1", story_id:"HOM-12.S1", decision_digest:$d, kind:$k, actor:"josh", reason:"r"}' >"$1.acceptance.json"
}
for k in human override; do
  for v in "free:." "metered:.cost_class = \"subscription\" | .metered = true" "excluded:.task.tags += [\"secrets\"]"; do
    S="$(new_story "forge-$k-${v%%:*}" "${v#*:}")"; forge "$S" "$k"
    want=ACCEPTANCE_KIND_NOT_ALLOWED; [[ "${v%%:*}" == excluded ]] && want=HARD_EXCLUSION
    gate_then_launch "$S"
    assert_eq "a forged $k record on a ${v%%:*} Paperclip stamp -> $want, not launched" \
      "$RC $(blocked "$S") $([[ "$OUT" == *LAUNCHED* ]] && echo L)" "4 $want "
    rm -f "$S.acceptance.json"; accept --story "$S" --kind "$k" --actor josh --reason r
    assert_eq "route-accept --kind $k on a ${v%%:*} Paperclip stamp -> $want, nothing written" \
      "$(res) $RC $([[ -e "$S.acceptance.json" ]] && echo W)" "$want 4 "
  done
done
S="$(new_story nonpc '.task.story_id = "AFK-X" | .cost_class = "subscription" | .metered = true' 'persona: dev')"
accept --story "$S" --kind human --actor josh; W="$(res)"
gate_then_launch "$S"
assert_eq "a non-Paperclip human acceptance on a metered stamp: written, dispatch unaffected" \
  "$W $(jq -r .kind "$S.acceptance.json") $RC $OUT" "ok human 0 LAUNCHED"
S="$(new_story disp4)"; printf '#!/bin/sh\necho garbage\n' >"$TMPROOT/afk-bad"; chmod +x "$TMPROOT/afk-bad"
gate_then_launch "$S" "$TMPROOT/afk-bad"
assert_eq "an unreadable verifier answer -> ACCEPTANCE_UNCHECKABLE" "$RC $(blocked "$S")" "4 ACCEPTANCE_UNCHECKABLE"

head1 "4. Other homes are untouched (AC-5)"
S="$(new_story linear '.task.story_id = "AFK-PC-9"' 'home: linear:GLY-1')"
printf '#!/bin/sh\ntouch "%s/called"\n' "$TMPROOT" >"$TMPROOT/afk-spy"; chmod +x "$TMPROOT/afk-spy"
gate_then_launch "$S" "$TMPROOT/afk-spy"
assert_eq "non-paperclip: launched, no output, no marker, verifier never called" \
  "$RC|$OUT|$([[ -e "$S.blocked" ]] && echo B)|$([[ -e "$TMPROOT/called" ]] && echo C)" "0|LAUNCHED||"
assert_eq "main() runs the check only behind paperclip_story_marked" \
  "$(grep -c 'paperclip_preconditions "\$STORY"' "$DISPATCH") $(grep -B1 'paperclip_preconditions "\$STORY"' "$DISPATCH" | grep -c 'if paperclip_story_marked')" "1 1"

head1 "5. .afk/ is protected on every home (AC-6)"
prot() { bash -c '. "$1"; afk_protected_paths "$2" "$3"' _ "$DISPATCH" "$@"; }
R="$TMPROOT/repo"; git init -q "$R"; mkdir -p "$R/.afk"; printf 'x\n' >"$R/.afk/gates-allowlist"
git -C "$R" add -A; git -C "$R" commit -qm base; BASE="$(git -C "$R" rev-parse HEAD)"
assert_eq "clean tree -> nothing" "$(prot "$R" "$BASE")" ""
printf 'rm -rf /\n' >>"$R/.afk/gates-allowlist"; git -C "$R" commit -qam widen
assert_eq "a commit touching .afk/ -> named" "$(prot "$R" "$BASE")" ".afk/gates-allowlist"
git -C "$R" reset -q --hard "$BASE"; git -C "$R" mv .afk/gates-allowlist moved; git -C "$R" commit -qm mv
assert_eq "a move out of .afk/ still names the old path" "$(prot "$R" "$BASE")" ".afk/gates-allowlist"
git -C "$R" reset -q --hard "$BASE"; printf '.afk/new\n' >"$R/.gitignore"; printf 'y\n' >"$R/.afk/new"
assert_eq "an untracked (even ignored) file under .afk/ -> named" "$(prot "$R" "$BASE")" ".afk/new"
# Fail closed: a git that cannot answer is AFK_PROTECTED_PATH_UNCHECKABLE (rc 3,
# nothing printed), never a clean tree.
N="$TMPROOT/nohead"; git init -q "$N"
assert_eq "a gone base and no HEAD -> rc 3, nothing printed" "$(prot "$N" "$BASE"; echo "rc=$?")" "rc=3"
mkdir -p "$TMPROOT/fakegit"
for sub in diff ls-files; do
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = %s ] && exit 128; done\nexec %s "$@"\n' "$sub" "$(command -v git)" >"$TMPROOT/fakegit/git"
  chmod +x "$TMPROOT/fakegit/git"
  assert_eq "a failing git $sub -> rc 3, nothing printed" \
    "$(PATH="$TMPROOT/fakegit:$PATH" prot "$R" "$BASE"; echo "rc=$?")" "rc=3"
done
assert_eq "main() fails the cycle on an uncheckable .afk/ check, gates skipped, .blocked written" \
  "$(grep -c 'elif \[\[ -n "\$afk_hits" \]\] || (( afk_rc != 0 ))' "$DISPATCH") $(grep -c 'AFK_PROTECTED_PATH_UNCHECKABLE: git could not' "$DISPATCH")" "1 1"
proj() { bash -c '. "$1"; shift; attempt_result_projection "$@"' _ "$DISPATCH" "$@"; }
assert_eq "result projection: AFK_PROTECTED_PATH forces gates_failed with paths" \
  "$(proj "" true 0 false AFK_PROTECTED_PATH '[".afk/new"]')" \
  '{"status":"gates_failed","launch":{"harness_exit":0},"failure_reason":"AFK_PROTECTED_PATH","paths":[".afk/new"]}'
assert_eq "main() checks .afk/ before the gates, beside the secret scan" \
  "$(grep -c 'elif \[\[ -n "\$afk_hits" \]\]' "$DISPATCH") $(grep -c 'AFK_PROTECTED_PATH: %s' "$DISPATCH")" "1 1"

head1 "6. dispatch.sh main(): the acceptance check runs before any launch"
# The real main() with stubbed orca, validator and harness, as in
# tests/lifecycle-dispatch-tests.sh. Every stub logs its call; orca refuses
# terminal creation, so nothing could run even if the order were wrong.
W="$TMPROOT/wt"; SB="$TMPROOT/stubs"; CALLS="$TMPROOT/calls.log"; mkdir -p "$W" "$SB"
cat >"$SB/orca" <<STUB
#!/bin/sh
echo "orca \$*" >>"$CALLS"
case "\$1 \$2" in
  "worktree list") printf '{"result":{"worktrees":[{"path":"%s","id":"r1::wt1"}]}}' "$W" ;;
  "repo list") echo '{"result":{"repos":[{"id":"r1","hookSettings":{"setupAgentStartupPolicy":"start-immediately"}}]}}' ;;
  *) exit 1 ;;
esac
STUB
printf '#!/bin/sh\necho validator >>"%s"\necho "{}"\n' "$CALLS" >"$SB/validator"
printf '#!/bin/sh\necho harness >>"%s"\n' "$CALLS" >"$SB/claude"
chmod +x "$SB/orca" "$SB/validator" "$SB/claude"
printf 'profiles:\n  local-code-standard:\n    physical: [{model_id: qwen-test}]\n' >"$TMPROOT/catalog.yaml"
run_main() { # <story> -> RC, OUT; the calls log is reset first
  : >"$CALLS"
  OUT="$(cd "$W" && PATH="$SB:$PATH" AGENT_FLOW_CONFIG=/nonexistent AGENT_STAMP_VALIDATE=validator \
    AGENT_STAMP_VALIDATE_CATALOG_PATH="$TMPROOT/catalog.yaml" AGENT_FLOW_KIT_BIN="$AFK" \
    bash "$DISPATCH" "$1" 2>&1)"; RC=$?
}
S="$(new_story main '.placement_required = false')"
mv "$S" "$W/main.md"; mv "$S.stamp.json" "$W/main.md.stamp.json"; S="$W/main.md"
run_main "$S"
assert_eq "main(): no acceptance -> exit 4, validator ran first, no terminal, no harness" \
  "$RC $(blocked "$S") $(paste -sd, "$CALLS")" "4 ACCEPTANCE_MISSING orca worktree list --json,orca repo list --json,validator"
accept --story "$S" --kind pm-auto --actor pm
rm -f "$S.blocked"; run_main "$S"
if [[ "$OUT" == *"acceptance digest, plan approval and story gates verified"* && "$OUT" == *"NO VALIDATED LAUNCH CONTRACT"* ]]; then
  ok "main(): accepted -> the check passes, then control reaches the launch-contract guard"
else bad "main(): accepted -> the check passes, then control reaches the launch-contract guard" "$RC $OUT"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
