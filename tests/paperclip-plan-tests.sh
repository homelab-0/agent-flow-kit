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
cat >"$STUBS/orca" <<'SH'
#!/usr/bin/env bash
[[ "$1 $2" == "terminal list" ]] && { printf '{"terminals":[{"handle":"termA","connected":true,"orphaned":false}]}'; exit 0; }
exit 1
SH
chmod +x "$STUBS/orca"

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
    '{api_url:"https://paperclip.test",company_id:"cccccccc-cccc-cccc-cccc-cccccccccccc",
      board_user_id:"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",host_label:"h",
      agents:[{agent_id:"11111111-1111-1111-1111-111111111111",key_ref:"op://x/y",project:"proj1",repo_path:$r,harness:"claude"}]}
     + (if $i == null then {} else {interim_comment_approval:$i} end)' >"$CONFIG"
}
reset_state() {
  rm -rf "$STATE"; mkdir -p "$STATE/paperclip"
  write_config
  jq -nc --arg id "$ISSUE" '{issues:{($id):{project:"proj1", identifier:"HOM-12"}}}' >"$STATE/paperclip/ledger.json"
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
  OUT_TEXT="$(env -i PATH="$STUBS:$PATH" HOME="$HOME_DIR" LANG=C \
    AFK_STATE_DIR="$STATE" AFK_ORCA_BIN="$STUBS/orca" \
    AFK_PAPERCLIP_CONFIG="$CONFIG" ORCA_TERMINAL_HANDLE="$handle" \
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

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
