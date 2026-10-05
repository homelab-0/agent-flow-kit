#!/usr/bin/env bash
# paperclip-plan-tests.sh — the isolated deterministic gate for
# `agent-flow-kit paperclip-plan` and `paperclip-approval`
# (lib/afk-paperclip-plan.sh, AFK-PC-3b). No network: `orca` is a stub on
# PATH and a temp git repo is the project repo. The poller's approval side is
# covered in tests/paperclip-poll-tests.sh (section 17).
#
# Usage: tests/paperclip-plan-tests.sh
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

if bash -n "$KIT_ROOT/lib/afk-paperclip-plan.sh"; then ok "bash -n lib/afk-paperclip-plan.sh"
else bad "bash -n lib/afk-paperclip-plan.sh"; fi

STUBS="$TMPROOT/stubs"; mkdir -p "$STUBS"
cat >"$STUBS/orca-cli" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == --version ]] && { echo 1.4.216; exit 0; }
[[ "$1 $2" == "terminal list" ]] && { printf '{"terminals":[{"handle":"termA","connected":true,"orphaned":false}]}'; exit 0; }
exit 1
SH
# The stub reaches the kit only through the resolver's host config.
printf '{"orca_bin":"%s"}\n' "$STUBS/orca-cli" >"$STUBS/host.json"
# A decoy named orca on PATH. Kit code must never run it (AD-28 R10);
# the real stub is orca-cli and reaches the kit only through the resolver.
printf '#!/bin/sh\n: >"%s"\nexit 1\n' "$STUBS/.bare-orca-ran" >"$STUBS/orca"; chmod +x "$STUBS/orca"
chmod +x "$STUBS/orca-cli"

g() { git -C "$REPO" -c commit.gpgsign=false "$@"; }
REPO="$TMPROOT/repo"
git init -q -b main "$REPO"
g config user.email t@test; g config user.name t
: >"$REPO/f"; g add f; g commit -qm init
g branch bare # a base with no allowlist at all
mkdir -p "$REPO/.afk"
printf '# gates\n\nbash tests/a.sh\nbash tests/b.sh --fast\n' >"$REPO/.afk/gates-allowlist"
g add .afk; g commit -qm allowlist
# A worktree edit (never committed) that would widen the allowlist.
printf 'rm -rf /\n' >>"$REPO/.afk/gates-allowlist"

STATE="$TMPROOT/state"
HOME_DIR="$TMPROOT/home"; mkdir -p "$HOME_DIR/.config/agent-flow-kit"
CONFIG="$HOME_DIR/.config/agent-flow-kit/paperclip.json"
ISSUE="e1111111-1111-1111-1111-111111111111"
COMMIT="d554c4789ed3930f8a53ac9fdf6503b3187097da"

write_config() { # [<interim-json>]
  jq -nc --arg r "$REPO" --argjson i "${1:-null}" \
    '{schema:"afk-paperclip-config/2",api_url:"https://paperclip.test",company_id:"cccccccc-cccc-cccc-cccc-cccccccccccc",
      board_user_id:"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
      host:{label:"h",agent_id:"11111111-1111-1111-1111-111111111111",key_ref:"op://x/y"},
      projects:[{paperclip_project_id:"aaaaaaaa-0000-4000-8000-000000000001",slug:"proj1",repo_path:$r,harness:"claude"}]}
     + (if $i == null then {} else {interim_comment_approval:$i} end)' >"$CONFIG"
}
reset_state() {
  rm -rf "$STATE"; mkdir -p "$STATE/paperclip"
  write_config
  jq -nc --arg id "$ISSUE" '{issues:{($id):{slug:"proj1", identifier:"HOM-12"}}}' >"$STATE/paperclip/ledger.json"
  local sk; sk="terminal-$(printf 'terminal\0%s' termA | sha256sum | awk '{print $1}')"
  mkdir -p "$STATE/pm/scopes/$sk"
  jq -nc --arg wp "$REPO" \
    '{schema:"afk-pm-ownership/2",owned:true,role:"PM",harness:"claude",session:"s",terminal:"termA",
      worktree:{id:"w",path:$wp},run_id:null,observed_at:"2026-09-27T00:00:00Z",observed_epoch:1,
      freshness_seconds:120,transition_id:null,previous:null}' >"$STATE/pm/scopes/$sk/ownership.json"
}

RC=0 OUT_TEXT=""
run_afk() { # <handle> <args...>
  local handle="$1"; shift
  OUT_TEXT="$(env -i PATH="${FAULT_PATH:+$FAULT_PATH:}$STUBS:$PATH" HOME="$HOME_DIR" LANG=C \
    AFK_STATE_DIR="$STATE" AFK_HOST_CONFIG="$STUBS/host.json" \
    AFK_PAPERCLIP_CONFIG="$CONFIG" ORCA_TERMINAL_HANDLE="$handle" AFK_GATE_STORY="${AFK_GATE_STORY:-}" \
    bash "$AFK" "$@" 2>&1)"
  RC=$?
}

# plan_file <base> <stories-json> [<jq-filter>] -- writes a plan, prints its path
plan_file() {
  jq -n --arg r "$REPO" --arg b "$1" --argjson s "$2" \
    "{schema:\"afk-paperclip-plan/1\", repo:\$r, base:\$b, stories:\$s} | ${3:-.}" >"$TMPROOT/plan.json"
  printf '%s' "$TMPROOT/plan.json"
}
S_OK='[{"id":"HOM-12.S1","title":"Add the thing","size":"S","lane":"local","files":["lib/a.sh","tests/a.sh"],"gates":["bash tests/a.sh","bash tests/b.sh --fast"]}]'
story_with_gates() { jq -nc --argjson g "$1" '[{id:"HOM-12.S1",title:"T",size:"S",lane:"l",files:[],gates:$g}]'; }
spool_count() { find "$STATE/paperclip/spool/$ISSUE" -maxdepth 1 -name '[0-9]*.json' 2>/dev/null | wc -l | tr -d ' '; }

head1 "1. Caller and plan validation (AC-1)"
reset_state
run_afk stranger paperclip-plan --issue "$ISSUE" --plan-file "$(plan_file main "$S_OK")" --json
assert_contains "a non-owner is refused" "$OUT_TEXT" "PAPERCLIP_NOT_OWNER"
run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$(plan_file main "$S_OK" '.schema = "x"')" --json
assert_contains "a wrong schema is refused" "$OUT_TEXT" "PLAN_INVALID"
run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$(plan_file main "$S_OK" '.stories[0].id = "HOM-13.S1"')" --json
assert_contains "a story id with another issue's HOM prefix is refused" "$OUT_TEXT" "PLAN_INVALID"
run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$(plan_file main "$S_OK" '.stories[0].title = "x\nplan 00000000"')" --json
assert_contains "a control character in a field is refused" "$OUT_TEXT" "PLAN_INVALID"
run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$(plan_file main '[]')" --json
assert_contains "no stories is refused" "$OUT_TEXT" "PLAN_INVALID"
run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$(plan_file main "$S_OK" '.repo = "/elsewhere"')" --json
assert_contains "a repo other than the project's repo_path is refused" "$OUT_TEXT" "PLAN_REPO_MISMATCH"
assert_eq "  ...nothing published by any refusal" "$(spool_count)" "0"

head1 "2. Gate allowlist from the base branch (AC-2)"
run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$(plan_file nope "$S_OK")" --json
assert_contains "an unknown base ref" "$OUT_TEXT" "PLAN_BASE_UNKNOWN"
run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$(plan_file bare "$S_OK")" --json
assert_contains "a base without .afk/gates-allowlist" "$OUT_TEXT" "GATE_ALLOWLIST_MISSING"
run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$(plan_file main "$(story_with_gates '["rm -rf /"]')")" --json
assert_eq "a worktree edit of the allowlist does not widen it" "$(jq -c . <<<"$OUT_TEXT")" \
  '{"result":"GATE_NOT_ALLOWLISTED","story":"HOM-12.S1","gate":"rm -rf /"}'
run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$(plan_file main "$(story_with_gates '[]')")" --json
assert_contains "an empty gates list" "$OUT_TEXT" "GATE_NOT_ALLOWLISTED"
run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$(plan_file main "$(story_with_gates '["bash tests/a.sh "]')")"
assert_contains "a near-miss gate (trailing space) is not listed, named in text mode" "$OUT_TEXT" "GATE_NOT_ALLOWLISTED: HOM-12.S1: bash tests/a.sh"
run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$(plan_file main "$(story_with_gates '["# gates"]')")" --json
assert_contains "a comment line is never a gate" "$OUT_TEXT" "GATE_NOT_ALLOWLISTED"
assert_eq "  ...still nothing published" "$(spool_count)" "0"

head1 "3. Publish, canonical body and digest (AC-3, AC-4)"
run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$(plan_file main "$S_OK")" --json
assert_eq "publish succeeds" "$(jq -r .result <<<"$OUT_TEXT")" "ok"
D="$(jq -r .digest <<<"$OUT_TEXT")"; D8="${D:0:8}"
ENTRY="$STATE/paperclip/spool/$ISSUE/00000001.json"
assert_eq "a question entry with question_id plan-<digest8>" "$(jq -r '.kind + " " + .question_id' "$ENTRY" 2>/dev/null)" "question plan-$D8"
BODY="$(jq -r .body "$ENTRY")"
PRE="${BODY%%$'\n'plan "$D8"$'\n'*}"
assert_eq "digest = sha256 of the body before the footer (footer excluded)" "$(printf '%s' "$PRE" | sha256sum | awk '{print $1}')" "$D"
assert_contains "the footer names the exact reply" "$BODY" "Reply exactly \`approve $D8\` to approve, or \`reject $D8\`."
assert_contains "the body shows every gate verbatim in a fence" "$BODY" $'```\nbash tests/a.sh\nbash tests/b.sh --fast\n```'
PLAN="$STATE/paperclip/plans/$ISSUE.json"
assert_eq "the plan file records digest, question and posted_seq" \
  "$(jq -r '[.digest, .question_id, .posted_seq, .base, (.stories|length)] | join(" ")' "$PLAN")" "$D plan-$D8 1 main 1"
jq -n --arg r "$REPO" --argjson s "$S_OK" '{stories:$s, base:"main", repo:$r, schema:"afk-paperclip-plan/1", extra:1}' >"$TMPROOT/plan2.json"
run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$TMPROOT/plan2.json" --json
assert_eq "the same plan (keys reordered, extra key) gives the same digest" "$(jq -r .digest <<<"$OUT_TEXT")" "$D"
assert_eq "  ...as a second question entry (seq 2)" "$(jq -r .seq <<<"$OUT_TEXT")" "2"

head1 "4. paperclip-approval and re-plan revocation (AC-4, AC-7)"
approve_rec() { # <digest> [<commit>]
  mkdir -p "$STATE/paperclip/approvals"
  jq -nc --arg d "$1" --arg c "${2:-$COMMIT}" \
    '{schema:"afk-paperclip-approval/1",kind:"plan",digest:$d,digest8:$d[0:8],comment_id:"x",comment_created_at:"t",decided_at:"t",paperclip_commit:$c}' \
    >"$STATE/paperclip/approvals/$ISSUE.json"
}
ATT="{\"attested_on\":\"2026-09-27\",\"paperclip_commit\":\"$COMMIT\"}"
run_afk termA paperclip-approval --issue 22222222-2222-2222-2222-222222222222 --json
assert_eq "no plan -> NO_PLAN" "$(jq -c '[.approved, .reason]' <<<"$OUT_TEXT")" '[false,"NO_PLAN"]'
run_afk termA paperclip-approval --issue "$ISSUE" --json
assert_eq "plan but no approval -> NOT_APPROVED" "$(jq -c '[.approved, .reason, .digest8]' <<<"$OUT_TEXT")" "[false,\"NOT_APPROVED\",\"$D8\"]"
write_config "$ATT"; approve_rec "$D"
run_afk termA paperclip-approval --issue "$ISSUE" --json
assert_eq "matching digest + attestation -> approved" "$(jq -c '[.approved, .reason]' <<<"$OUT_TEXT")" '[true,"APPROVED"]'
assert_eq "  ...exit 0" "$RC" "0"
approve_rec "$(printf '%064d' 0)"
run_afk termA paperclip-approval --issue "$ISSUE" --json
assert_eq "an approval of another digest -> PLAN_CHANGED" "$(jq -c '[.approved, .reason]' <<<"$OUT_TEXT")" '[false,"PLAN_CHANGED"]'
approve_rec "$D" "0000000000000000000000000000000000000000"
run_afk termA paperclip-approval --issue "$ISSUE" --json
assert_eq "attested commit changed since approval -> unattested" "$(jq -r .reason <<<"$OUT_TEXT")" "APPROVAL_INTERIM_UNATTESTED"
approve_rec "$D"; write_config
run_afk termA paperclip-approval --issue "$ISSUE" --json
assert_eq "attestation config removed -> unattested" "$(jq -c '[.approved, .reason]' <<<"$OUT_TEXT")" '[false,"APPROVAL_INTERIM_UNATTESTED"]'
write_config "$ATT"
run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$(plan_file main "$S_OK" '.stories[0].size = "M"')" --json
assert_eq "a changed plan gets a new digest" "$([[ "$(jq -r .digest <<<"$OUT_TEXT")" != "$D" ]] && echo new)" "new"
assert_eq "a re-plan revokes the approval record" "$([[ -e "$STATE/paperclip/approvals/$ISSUE.json" ]] && echo present || echo gone)" "gone"
run_afk termA paperclip-approval --issue "$ISSUE"
assert_eq "  ...and paperclip-approval says so (exit 1)" "$OUT_TEXT $RC" "not approved: NOT_APPROVED 1"

head1 "5. Allowlist comment rule"
printf '# c\n   \n\t\n  # indented\nbash tests/c.sh\r\n' >"$REPO/.afk/gates-allowlist"
g add .afk; g commit -qm quirks; g branch quirks; g reset -q --hard HEAD~1
reset_state
run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$(plan_file quirks "$(story_with_gates '["   "]')")" --json
assert_contains "a whitespace-only allowlist line is ignored, never a gate" "$OUT_TEXT" "GATE_NOT_ALLOWLISTED"
run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$(plan_file quirks "$(story_with_gates '["bash tests/c.sh"]')")" --json
assert_contains "a CRLF allowlist entry matches nothing" "$OUT_TEXT" "GATE_NOT_ALLOWLISTED"
run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$(plan_file quirks "$(story_with_gates '["# c"]')")" --json
assert_contains "a line starting with # is a comment" "$OUT_TEXT" "GATE_NOT_ALLOWLISTED"
run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$(plan_file quirks "$(story_with_gates '["  # indented"]')")" --json
assert_eq "an indented # line is an entry, not a comment" "$(jq -r .result <<<"$OUT_TEXT")" "ok"

head1 "6. Publication order: record, question, posted (failure points)"
# mv stubs that fail only the rename of a plan record in one state.
REAL_MV="$(command -v mv)"
for st in pending_publish posted; do
  mkdir -p "$TMPROOT/fault_$st"
  cat >"$TMPROOT/fault_$st/mv" <<SH
#!/usr/bin/env bash
dst="\${*: -1}"; src="\${*: -2:1}"
[[ "\$dst" == */paperclip/plans/*.json ]] && grep -q '"state":"$st"' "\$src" 2>/dev/null && exit 1
exec "$REAL_MV" "\$@"
SH
  chmod +x "$TMPROOT/fault_$st/mv"
done
reset_state
N0="$(spool_count)"
FAULT_PATH="$TMPROOT/fault_pending_publish" run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$(plan_file main "$S_OK")" --json
assert_eq "step 1 (pending record) fails -> refused" "$(jq -r .result <<<"$OUT_TEXT") $RC" "PAPERCLIP_REGISTRY_WRITE_FAILED 1"
assert_eq "  ...nothing published" "$(spool_count)" "$N0"
assert_eq "  ...no plan record" "$([[ -e "$PLAN" ]] && echo present || echo absent)" "absent"
mkdir -p "$STATE/paperclip/spool/$ISSUE"; : >"$STATE/paperclip/spool/$ISSUE/.final"
run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$(plan_file main "$S_OK")" --json
assert_eq "step 2 (publish) fails -> the writer's refusal" "$(jq -r .result <<<"$OUT_TEXT")" "PAPERCLIP_SPOOL_CLOSED"
assert_eq "  ...the pending record is removed" "$([[ -e "$PLAN" ]] && echo present || echo absent)" "absent"
rm -f "$STATE/paperclip/spool/$ISSUE/.final"
FAULT_PATH="$TMPROOT/fault_posted" run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$(plan_file main "$S_OK")" --json
assert_eq "step 3 (posted) fails -> refused, naming the published seq" "$(jq -c '[.result, .seq]' <<<"$OUT_TEXT") $RC" '["PAPERCLIP_REGISTRY_WRITE_FAILED",1] 1'
assert_eq "  ...the question is published" "$(spool_count)" "1"
assert_eq "  ...a pending_publish record that carries the seq is left" "$(jq -c '[.state, .posted_seq]' "$PLAN" 2>/dev/null)" '["pending_publish",1]'
run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$(plan_file main "$S_OK")" --json
assert_eq "no fault -> the record ends posted with its seq" "$(jq -c '[.state, .posted_seq]' "$PLAN" 2>/dev/null)" '["posted",2]'

head1 "7. Schema 2: roles, review targets, and the unchanged /1 body"
# A fixture allowlist on its own base: the review gate is never added to a
# live allowlist by a test.
RG='agent-flow-kit review-verdict --check'
printf 'bash tests/a.sh\nbash tests/b.sh --fast\n%s\n' "$RG" >"$REPO/.afk/gates-allowlist"
g add .afk; g commit -qm review-gate; g branch review; g reset -q --hard HEAD~1
reset_state
# Builder and reviewer differ in role, the reviewer's target and its review gate.
st() { jq -nc --arg id "$1" --arg r "$2" --arg t "${3:-}" --arg g "$RG" \
  '{id:$id,title:"X",size:"S",lane:"l",role:$r,files:[],gates:(["bash tests/a.sh"] + (if $r == "reviewer" then [$g] else [] end))}
   + (if $t == "" then {} else {reviews:$t} end)'; }
p2() { # [<jq-filter>] -- a /2 plan on the review base: S1 builder, S2 reviews S1
  plan_file review "$(jq -sc . < <(st HOM-12.S1 builder; st HOM-12.S2 reviewer HOM-12.S1))" ".schema = \"afk-paperclip-plan/2\" | ${1:-.}"
}
p2_refused() { # <name> <jq-filter> <reason>
  run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$(p2 "$2")" --json
  assert_eq "$1" "$(jq -r .result <<<"$OUT_TEXT") $RC" "$3 4"
}
p2_refused "/2: a story with no role" 'del(.stories[0].role)' PLAN_ROLE_INVALID
p2_refused "/2: an unknown role" '.stories[0].role = "author"' PLAN_ROLE_INVALID
p2_refused "/2: a builder that names a review target" '.stories[0].reviews = "HOM-12.S2"' PLAN_ROLE_INVALID
p2_refused "/2: a builder that runs the review gate" ".stories[0].gates += [\"$RG\"]" PLAN_ROLE_INVALID
p2_refused "/2: a reviewer of an unknown story" '.stories[1].reviews = "HOM-12.S9"' PLAN_REVIEW_TARGET_INVALID
p2_refused "/2: a reviewer with no target string" '.stories[1].reviews = 7' PLAN_REVIEW_TARGET_INVALID
p2_refused "/2: a reviewer with an empty target" '.stories[1].reviews = ""' PLAN_REVIEW_TARGET_INVALID
p2_refused "/2: a reviewer with a null target" '.stories[1].reviews = null' PLAN_REVIEW_TARGET_INVALID
p2_refused "/2: a reviewer reviewing itself" '.stories[1].reviews = "HOM-12.S2"' PLAN_REVIEW_TARGET_INVALID
p2_refused "/2: a reviewer of a reviewer (no recursion)" \
  '.stories += [.stories[1] | .id = "HOM-12.S3" | .reviews = "HOM-12.S2"]' PLAN_REVIEW_TARGET_INVALID
p2_refused "/2: a builder nobody reviews" '.stories += [.stories[0] | .id = "HOM-12.S3"]' PLAN_BUILDER_UNREVIEWED
p2_refused "/2: a reviewer without the exact review gate" '.stories[1].gates = ["bash tests/a.sh"]' PLAN_REVIEW_GATE_MISSING
p2_refused "/2: a near-miss review gate" '.stories[1].gates = ["bash tests/a.sh", "agent-flow-kit review-verdict --check "]' PLAN_REVIEW_GATE_MISSING
assert_eq "  ...nothing published by any /2 refusal" "$(spool_count)" "0"
run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$(p2)" --json
assert_eq "a valid /2 plan publishes" "$(jq -r .result <<<"$OUT_TEXT") $RC" "ok 0"
D2="$(jq -r .digest <<<"$OUT_TEXT")"
BODY2="$(jq -r .body "$STATE/paperclip/spool/$ISSUE/00000001.json")"
assert_contains "/2 body: the schema line right after Base" "$BODY2" $'- Base: `review`\n- Plan schema: 2\n\n## HOM-12.S1'
assert_contains "/2 body: the builder's role right after Lane" "$BODY2" $'- Lane: l\n- Role: builder\n- Files:'
assert_contains "/2 body: the reviewer's role and target right after Lane" "$BODY2" $'- Lane: l\n- Role: reviewer\n- Reviews: HOM-12.S1\n- Files:'
assert_eq "/2 digest = sha256 of the body before the footer" \
  "$(printf '%s' "${BODY2%%$'\n'plan "${D2:0:8}"$'\n'*}" | sha256sum | awk '{print $1}')" "$D2"
assert_eq "/2 record: plan_schema, roles and the reviewer's target kept" \
  "$(jq -c '[.plan_schema, [.stories[] | [.role, .reviews]]]' "$PLAN")" '["afk-paperclip-plan/2",[["builder",null],["reviewer","HOM-12.S1"]]]'
# The record paperclip-plan wrote, read by the evidence side: approved, the
# reviewer accepted, its review gate passes and its launch answers as reviewer.
write_config "$ATT"; approve_rec "$D2"
printf '.pm-brief/\n' >>"$REPO/.git/info/exclude"; mkdir -p "$REPO/.pm-brief"; RS="$REPO/.pm-brief/rv.md"
printf -- '---\nhome: paperclip:HOM-12\npaperclip_issue: %s\ngates:\n  - "bash tests/a.sh"\n  - "%s"\n---\n# review\n' "$ISSUE" "$RG" >"$RS"
jq -n '{harness:"claude", model_profile:"local-code-standard", effort:"medium", cost_class:"free", metered:false,
  catalog_version:"sha256:abc", placement_required:false, task:{story_id:"HOM-12.S2", tags:["tests"]}, override:null}' >"$RS.stamp.json"
run_afk termA route-accept --story "$RS" --kind pm-auto --actor pm --json
assert_eq "/2 end to end: the reviewer story of the published plan is accepted" "$(jq -r .result <<<"$OUT_TEXT")" "ok"
jq -nc '{schema:"afk-review-verdict/1", reviewer_story_id:"HOM-12.S2", reviews_story_id:"HOM-12.S1", verdict:"APPROVE", findings:[]}' >"$RS.verdict.json"
AFK_GATE_STORY="$RS" run_afk termA review-verdict --check --json
assert_eq "  ...its review gate passes against the written record" "$(jq -r .result <<<"$OUT_TEXT") $RC" "ok 0"
rm -f "$RS.verdict.json"
run_afk termA route-accept --story "$RS" --verify --json; TUPJ="$(jq -c .tuple <<<"$OUT_TEXT")"
run_afk termA paperclip-evidence snapshot --dir "$REPO"; SNAPJ="$OUT_TEXT"
run_afk termA paperclip-evidence launch --story "$RS" --cycle 1 --dispatch-id dispatch:e2e --json \
  <<<"$(jq -nc --argjson t "$TUPJ" --argjson s "$SNAPJ" '{tuple:$t, snapshot:$s}')"
assert_eq "  ...and its launch is recorded as a reviewer" "$(jq -c '[.result, .role]' <<<"$OUT_TEXT")" '["ok","reviewer"]'
run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$(p2 '.stories += [.stories[1] | .id = "HOM-12.S3"]')" --json
assert_eq "/2: two reviewers of one builder publish" "$(jq -r .result <<<"$OUT_TEXT") $RC" "ok 0"
run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$(p2)" --json
S1SHA="$(jq -cS '.stories[] | select(.id == "HOM-12.S1")' "$PLAN" | sha256sum)"
run_afk termA paperclip-plan --issue "$ISSUE" --plan-file \
  "$(p2 '.stories = [(.stories[1] | .id = "HOM-12.S1" | .reviews = "HOM-12.S2"), (.stories[0] | .id = "HOM-12.S2")]')" --json
assert_eq "swapping only the roles changes the digest" "$([[ "$(jq -r .digest <<<"$OUT_TEXT")" != "$D2" ]] && echo new)" "new"
assert_eq "  ...and S1's projected story, so its plan_story_sha256" \
  "$([[ "$(jq -cS '.stories[] | select(.id == "HOM-12.S1")' "$PLAN" | sha256sum)" != "$S1SHA" ]] && echo changed)" "changed"
reset_state
GOLD="$(printf '# AFK plan\n\n- Repo: `repo` (`%s`)\n- Base: `main`\n\n## HOM-12.S1: Add the thing\n\n- Size: S\n- Lane: local\n- Files:\n  - `lib/a.sh`\n  - `tests/a.sh`\n- Gates:\n\n```\nbash tests/a.sh\nbash tests/b.sh --fast\n```' "$REPO")"
GOLD_D="$(printf '%s\n' "$GOLD" | sha256sum | awk '{print $1}')"
run_afk termA paperclip-plan --issue "$ISSUE" --plan-file "$(plan_file main "$S_OK")" --json
BODY1="$(jq -r .body "$STATE/paperclip/spool/$ISSUE/00000001.json")"
assert_eq "/1 golden: the body is byte-identical to the fixed text" "${BODY1%%$'\n'plan *}" "$GOLD"$'\n'
assert_eq "/1 golden: the digest is the golden body's sha256" "$(jq -r .digest <<<"$OUT_TEXT")" "$GOLD_D"
run_afk termA paperclip-plan --issue "$ISSUE" --plan-file \
  "$(plan_file main "$S_OK" '.stories[0] += {role:"reviewer", reviews:"HOM-12.S9"}')" --json
assert_eq "/1 ignores role fields: same digest, no role or plan_schema stored" \
  "$(jq -r .digest <<<"$OUT_TEXT") $(jq -c '[.plan_schema, (.stories[0] | has("role"), has("reviews"))]' "$PLAN")" "$GOLD_D [null,false,false]"

assert_eq "the PATH decoy orca never ran" \
  "$([[ -e "$STUBS/.bare-orca-ran" ]] && echo ran || echo never)" "never"
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
