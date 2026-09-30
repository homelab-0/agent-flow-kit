#!/usr/bin/env bash
# paperclip-pm-registry-tests.sh — the isolated deterministic gate for
# lib/afk-pm-registry.sh: PM registry lookup, stale-owner reaping, and the
# paperclip-take/paperclip-settle notice verbs (AFK-PC-2a).
#
# No network: `orca` is a stub on PATH, following the pattern in
# tests/paperclip-poll-tests.sh. Two real temp git worktrees of one repo
# stand in for "a repo checked out twice".
#
# Usage: tests/paperclip-pm-registry-tests.sh
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

if bash -n "$KIT_ROOT/lib/afk-pm-registry.sh"; then ok "bash -n lib/afk-pm-registry.sh"
else bad "bash -n lib/afk-pm-registry.sh"; fi

STUBS="$TMPROOT/stubs"; mkdir -p "$STUBS"
TERMFILE="$TMPROOT/terminals.json"
cat > "$STUBS/orca-cli" <<'SH'
#!/usr/bin/env bash
[[ "${1:-}" == --version ]] && { echo 1.4.216; exit 0; }
if [[ "$1 $2" == "terminal list" ]]; then
  [[ "${ORCA_STUB_MODE:-ok}" == fail ]] && exit 1
  cat "$ORCA_STUB_TERMINALS"
  exit 0
fi
exit 1
SH
chmod +x "$STUBS/orca-cli"
# The stub reaches the kit only through the resolver's host config.
printf '{"orca_bin":"%s"}\n' "$STUBS/orca-cli" >"$STUBS/host.json"
# A decoy named orca on PATH. Kit code must never run it (AD-28 R10);
# the real stub is orca-cli and reaches the kit only through the resolver.
printf '#!/bin/sh\n: >"%s"\nexit 1\n' "$STUBS/.bare-orca-ran" >"$STUBS/orca"; chmod +x "$STUBS/orca"
set_terminals() { printf '%s' "$1" >"$TERMFILE"; } # {"terminals":[...]}

REPO="$TMPROOT/repo"
git init -q "$REPO"
git -C "$REPO" config user.email t@test; git -C "$REPO" config user.name t
: >"$REPO/f"; git -C "$REPO" -c commit.gpgsign=false add f
git -C "$REPO" -c commit.gpgsign=false commit -qm init
git -C "$REPO" worktree add -q "$TMPROOT/repo-wt2" -b wt2 >/dev/null 2>&1

STATE="$TMPROOT/state"
HOME_DIR="$TMPROOT/home"; mkdir -p "$HOME_DIR"

scope_key() { # <terminal>
  printf 'terminal-%s' "$(printf 'terminal\0%s' "$1" | sha256sum | awk '{print $1}')"
}

write_owner() { # <terminal> <session> <worktree_path>
  local sk; sk="$(scope_key "$1")"
  mkdir -p "$STATE/pm/scopes/$sk"
  jq -nc --arg t "$1" --arg s "$2" --arg wp "$3" \
    '{schema:"afk-pm-ownership/2",owned:true,role:"PM",harness:"claude",session:$s,terminal:$t,
      worktree:{id:"w",path:$wp},run_id:null,observed_at:"2026-09-27T00:00:00Z",observed_epoch:1,
      freshness_seconds:120,transition_id:null,previous:null}' >"$STATE/pm/scopes/$sk/ownership.json"
  printf '%s' "$sk"
}

write_handoff() { # <old-terminal> <state> <successor-terminal> <updated_at>
  local sk; sk="$(scope_key "$1")"
  jq -nc --arg t "$1" --arg st "$2" --arg succ "$3" --arg at "$4" \
    '{schema:"afk-pm-handoff/2",transition_id:"pm-t",state:$st,continuation_sha256:"sha256:x",
      old:{session:"s",terminal:$t,harness:"claude",worktree:{id:"w",path:"'"$REPO"'"},run_id:null},
      successor:{session:null,terminal:$succ,harness:"claude",worktree:{id:"w",path:"'"$REPO"'"},run_id:null},
      observed_at:$at,updated_at:$at}' >"$STATE/pm/scopes/$sk/handoff.json"
}

reset_state() { rm -rf "$STATE"; mkdir -p "$STATE"; }

run_afk() { # <args...> — env vars ORCA_TERMINAL_HANDLE/ORCA_STUB_MODE read from caller's env
  local out
  out="$(env -i PATH="$STUBS:$PATH" HOME="$HOME_DIR" LANG=C \
    AFK_STATE_DIR="$STATE" AFK_HOST_CONFIG="$STUBS/host.json" ORCA_STUB_TERMINALS="$TERMFILE" \
    ORCA_STUB_MODE="${ORCA_STUB_MODE:-ok}" ORCA_TERMINAL_HANDLE="${ORCA_TERMINAL_HANDLE:-}" \
    AFK_PAPERCLIP_CONFIG="$HOME_DIR/.config/agent-flow-kit/paperclip.json" \
    bash "$AFK" "$@" 2>&1)"
  RC=$?
  OUT_TEXT="$out"
}

lookup() { # <repo_path> -> prints JSON; also honors ORCA_STUB_MODE/ORCA_TERMINAL_HANDLE-independent
  env -i PATH="$STUBS:$PATH" HOME="$HOME_DIR" LANG=C \
    AFK_STATE_DIR="$STATE" AFK_HOST_CONFIG="$STUBS/host.json" ORCA_STUB_TERMINALS="$TERMFILE" \
    ORCA_STUB_MODE="${ORCA_STUB_MODE:-ok}" AFK_INSTALL_ROOT="$KIT_ROOT" \
    bash -c '
      source "'"$KIT_ROOT"'/lib/afk-common.sh"
      source "'"$KIT_ROOT"'/lib/afk-readiness.sh"
      source "'"$KIT_ROOT"'/lib/afk-paperclip.sh"
      source "'"$KIT_ROOT"'/lib/afk-pm-registry.sh"
      afk_pm_registry_lookup "$1"
    ' _ "$1"
}

write_paperclip_config() { # <slug> <repo_path>
  mkdir -p "$HOME_DIR/.config/agent-flow-kit"
  jq -nc --arg p "$1" --arg r "$2" \
    '{schema:"afk-paperclip-config/2",api_url:"https://paperclip.test",company_id:"cccccccc-cccc-cccc-cccc-cccccccccccc",
      board_user_id:"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
      host:{label:"h",agent_id:"11111111-1111-1111-1111-111111111111",key_ref:"op://x/y"},
      projects:[{paperclip_project_id:"aaaaaaaa-0000-4000-8000-000000000001",slug:$p,repo_path:$r,harness:"claude"}]}' >"$HOME_DIR/.config/agent-flow-kit/paperclip.json"
}

write_notice() { # <slug> <epoch> <issue_id> <event>
  mkdir -p "$STATE/paperclip/notices/$1"
  jq -nc --arg id "$3" --arg ev "$4" --arg p "$1" \
    '{id:$id,identifier:"AB",host_agent_id:"11111111-1111-1111-1111-111111111111",slug:$p,
      repo_path:"'"$REPO"'",harness:"claude",event:$ev,time:"2026-09-27T00:00:00Z"}' \
    >"$STATE/paperclip/notices/$1/$2.$3.$4.json"
}

# ============================================================================
head1 "1. registry lookup"
# ============================================================================
reset_state
write_owner termA 11111111-1111-1111-1111-111111111111 "$REPO" >/dev/null
set_terminals '{"terminals":[{"handle":"termA","connected":true,"orphaned":false}]}'

out="$(lookup "$TMPROOT/repo-wt2")"
assert_eq "lookup via second worktree finds the same live owner" "$(jq -r .state <<<"$out")" "live"
assert_eq "  ...owner terminal is termA" "$(jq -r .owner.terminal <<<"$out")" "termA"

set_terminals '{"terminals":[]}'
out="$(lookup "$REPO")"
assert_eq "absent terminal -> stale, none live" "$(jq -r .state <<<"$out")" "none"
assert_eq "  ...stale list carries the dead owner" "$(jq -r '.stale[0].terminal' <<<"$out")" "termA"

out="$(ORCA_STUB_MODE=fail lookup "$REPO")"
assert_eq "Orca unavailable -> nothing stale, owner still live" "$(jq -r .state <<<"$out")" "live"
assert_eq "  ...orca field reports ORCA_UNAVAILABLE" "$(jq -r .orca <<<"$out")" "ORCA_UNAVAILABLE"
assert_eq "  ...stale list is empty" "$(jq -c .stale <<<"$out")" "[]"

reset_state
write_owner termA 11111111-1111-1111-1111-111111111111 "$REPO" >/dev/null
write_owner termB 22222222-2222-2222-2222-222222222222 "$TMPROOT/repo-wt2" >/dev/null
set_terminals '{"terminals":[{"handle":"termA","connected":true,"orphaned":false},{"handle":"termB","connected":true,"orphaned":false}]}'
out="$(lookup "$REPO")"
assert_eq "two live owners -> ambiguous" "$(jq -r .state <<<"$out")" "ambiguous"
assert_eq "  ...both terminals listed" "$(jq -c '[.owners[].terminal] | sort' <<<"$out")" '["termA","termB"]'

reset_state
write_owner termA 11111111-1111-1111-1111-111111111111 "$REPO" >/dev/null
write_handoff termA SUCCESSOR_LAUNCHED termC "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
out="$(lookup "$REPO")"
assert_eq "fresh SUCCESSOR_LAUNCHED -> handoff_in_progress" "$(jq -r .state <<<"$out")" "handoff_in_progress"

write_handoff termA SUCCESSOR_LAUNCHED termC "2020-01-01T00:00:00Z"
out="$(lookup "$REPO")"
assert_eq "old SUCCESSOR_LAUNCHED -> handoff_stalled" "$(jq -r .state <<<"$out")" "handoff_stalled"
assert_eq "  ...reason is PM_HANDOFF_STALLED" "$(jq -r .reason <<<"$out")" "PM_HANDOFF_STALLED"
rm -f "$STATE/pm/scopes/$(scope_key termA)/handoff.json"

# ============================================================================
head1 "2. pm-registry-reap"
# ============================================================================
reset_state
SK="$(write_owner termA 11111111-1111-1111-1111-111111111111 "$REPO")"
write_paperclip_config proj1 "$REPO"
write_notice proj1 1000 66666666-6666-6666-6666-666666666666 claimed
set_terminals '{"terminals":[{"handle":"termA","connected":true,"orphaned":false}]}'
ORCA_TERMINAL_HANDLE=termA run_afk paperclip-take --slug proj1 --json
assert_eq "take (owner) claims the seeded notice" "$RC" "0"

run_afk pm-registry-reap --scope "$SK" --json
assert_eq "reap refuses a live owner" "$(jq -r .result <<<"$OUT_TEXT")" "PM_OWNER_LIVE"
assert_eq "  ...exit code 2" "$RC" "2"

for bad_list in '{"ok":false,"error":{"code":"x"}}' '{"ok":true,"result":{"terminals":[],"truncated":true}}' \
    '{"ok":true,"result":{"terminals":[{"handle":"termZ"}]}}' '{"ok":true,"result":{}}'; do
  set_terminals "$bad_list"
  run_afk pm-registry-reap --scope "$SK" --json
  assert_eq "reap refuses on an uncertain list: $bad_list" "$(jq -r .result <<<"$OUT_TEXT")" "ORCA_UNAVAILABLE"
done
set_terminals '{"ok":true,"result":{"terminals":[{"handle":"termA","title":"t","connected":false,"orphaned":false}],"truncated":false}}'
run_afk pm-registry-reap --scope "$SK" --json
assert_eq "reap refuses a disconnected but not orphaned owner" "$(jq -r .result <<<"$OUT_TEXT")" "PM_OWNER_LIVE"

set_terminals '{"terminals":[]}'
run_afk pm-registry-reap --scope "$SK" --json
assert_eq "reap of a stale owner succeeds" "$(jq -r .result <<<"$OUT_TEXT")" "reaped"
assert_eq "  ...returns the one claimed notice" "$(jq -r .notices_returned <<<"$OUT_TEXT")" "1"
assert_eq "  ...ownership.json is gone" "$([[ -f "$STATE/pm/scopes/$SK/ownership.json" ]] && echo yes || echo no)" "no"
assert_eq "  ...notice is back under its project" \
  "$([[ -f "$STATE/paperclip/notices/proj1/1000.66666666-6666-6666-6666-666666666666.claimed.json" ]] && echo yes || echo no)" "yes"

# ============================================================================
head1 "3. paperclip-take / paperclip-settle"
# ============================================================================
reset_state
write_owner termA 11111111-1111-1111-1111-111111111111 "$REPO" >/dev/null
write_paperclip_config proj1 "$REPO"
write_notice proj1 1000 66666666-6666-6666-6666-666666666666 claimed
write_notice proj1 2000 77777777-7777-7777-7777-777777777777 claimed
set_terminals '{"terminals":[{"handle":"termA","connected":true,"orphaned":false}]}'

ORCA_TERMINAL_HANDLE=termZ run_afk paperclip-take --slug proj1 --json
assert_eq "take by a non-owner refuses" "$(jq -r .result <<<"$OUT_TEXT")" "PAPERCLIP_NOT_OWNER"
assert_eq "  ...exit code 2" "$RC" "2"

ORCA_TERMINAL_HANDLE=termA run_afk paperclip-take --slug ../proj1 --json
assert_eq "take refuses a path-shaped project name" "$(jq -r .result <<<"$OUT_TEXT")" "PAPERCLIP_PROJECT_UNKNOWN"

ORCA_TERMINAL_HANDLE=termA run_afk paperclip-take --slug Proj1 --json
assert_eq "take refuses a slug outside ^[a-z0-9-]{1,40}$" "$(jq -r .result <<<"$OUT_TEXT")" "PAPERCLIP_PROJECT_UNKNOWN"

ORCA_TERMINAL_HANDLE=termA run_afk paperclip-take --slug claimed --json
assert_eq "take refuses the kit's own claimed/ directory as a slug" "$(jq -r .result <<<"$OUT_TEXT")" "PAPERCLIP_PROJECT_UNKNOWN"

ORCA_TERMINAL_HANDLE=termA run_afk paperclip-take --project proj1 --json
assert_contains "the old --project flag is refused, not aliased" "$OUT_TEXT" "PAPERCLIP_FLAG_RENAMED"
assert_eq "  ...as a usage error" "$RC" "1"
assert_eq "  ...and nothing was claimed" "$(find "$STATE/paperclip/notices/claimed" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"

ORCA_TERMINAL_HANDLE=termA run_afk paperclip-take --slug proj1 --json
assert_eq "take by the owner succeeds" "$RC" "0"
assert_eq "  ...claims in ascending order" "$(jq -r '.[0].id' <<<"$OUT_TEXT")" "66666666-6666-6666-6666-666666666666"
assert_eq "  ...prints a path, not the notice contents" "$(jq -r '.[0].notice' <<<"$OUT_TEXT")" \
  "$STATE/paperclip/notices/claimed/$(scope_key termA)/1000.66666666-6666-6666-6666-666666666666.claimed.json"
assert_contains "  ...no raw Paperclip text ever appears" "$(jq -c <<<"$OUT_TEXT")" '"notice":'

ORCA_TERMINAL_HANDLE=termA run_afk paperclip-take --slug proj1 --json
assert_eq "a second take never returns the same notices" "$(jq -c <<<"$OUT_TEXT")" "[]"

ID=66666666-6666-6666-6666-666666666666
ORCA_TERMINAL_HANDLE=termA run_afk paperclip-settle --notice "$ID" --json
assert_eq "settle moves the claimed notice" "$(jq -r .result <<<"$OUT_TEXT")" "settled"
assert_eq "  ...it lands in settled/" \
  "$([[ -f "$STATE/paperclip/notices/settled/1000.$ID.claimed.json" ]] && echo yes || echo no)" "yes"

ORCA_TERMINAL_HANDLE=termA run_afk paperclip-settle --notice "$ID" --json
assert_eq "settling an already-settled notice is an idempotent no-op" "$(jq -r .result <<<"$OUT_TEXT")" "settled"
assert_eq "  ...moved count is zero the second time" "$(jq -r .moved <<<"$OUT_TEXT")" "0"
assert_eq "  ...exit code 0" "$RC" "0"

run_afk paperclip-settle --notice 99999999-9999-9999-9999-999999999999 --json
assert_eq "settling an unknown notice refuses" "$(jq -r .result <<<"$OUT_TEXT")" "PAPERCLIP_NOTICE_UNKNOWN"
assert_eq "  ...exit code 4" "$RC" "4"

# ============================================================================
head1 "4. take during a handoff"
# ============================================================================
reset_state
write_owner termA 11111111-1111-1111-1111-111111111111 "$REPO" >/dev/null
write_handoff termA SUCCESSOR_LAUNCHED termC "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_paperclip_config proj1 "$REPO"
write_notice proj1 1000 66666666-6666-6666-6666-666666666666 claimed
set_terminals '{"terminals":[{"handle":"termA","connected":true,"orphaned":false}]}'

ORCA_TERMINAL_HANDLE=termA run_afk paperclip-take --slug proj1 --json
assert_eq "the old owner is refused during a handoff" "$(jq -r .result <<<"$OUT_TEXT")" "PAPERCLIP_HANDOFF_IN_PROGRESS"

ORCA_TERMINAL_HANDLE=termC run_afk paperclip-take --slug proj1 --json
assert_eq "the named successor may take during a handoff" "$RC" "0"
assert_eq "  ...it claims the notice" "$(jq -r '.[0].id' <<<"$OUT_TEXT")" "66666666-6666-6666-6666-666666666666"

# ============================================================================
head1 "5. lookup with a disconnected (not orphaned) owner"
# ============================================================================
reset_state
SK5="$(write_owner termA 11111111-1111-1111-1111-111111111111 "$REPO")"
write_paperclip_config proj1 "$REPO"
set_terminals '{"terminals":[{"handle":"termA","connected":false,"orphaned":false}]}'

out="$(lookup "$REPO")"
assert_eq "a listed, disconnected owner is neither live nor stale" "$(jq -r .state <<<"$out")" "unknown"
assert_eq "  ...reason is PM_OWNER_DISCONNECTED" "$(jq -r .reason <<<"$out")" "PM_OWNER_DISCONNECTED"
assert_eq "  ...it is not in the stale list" "$(jq -c .stale <<<"$out")" "[]"
assert_eq "  ...it is named in owners" "$(jq -r '.owners[0].terminal' <<<"$out")" "termA"

ORCA_TERMINAL_HANDLE=termA run_afk paperclip-take --slug proj1 --json
assert_eq "take refuses a disconnected owner's own terminal" "$(jq -r .result <<<"$OUT_TEXT")" "PAPERCLIP_NOT_OWNER"
assert_eq "  ...exit code 2" "$RC" "2"

set_terminals '{"terminals":[{"handle":"termA","connected":true,"orphaned":false}]}'
run_afk pm-registry-reap --scope "$SK5" --json
assert_eq "a reconnected owner is live again, not reapable" "$(jq -r .result <<<"$OUT_TEXT")" "PM_OWNER_LIVE"

# ============================================================================
head1 "6. lookup with more than one in-progress handoff"
# ============================================================================
reset_state
write_owner termA 11111111-1111-1111-1111-111111111111 "$REPO" >/dev/null
write_owner termD 44444444-4444-4444-4444-444444444444 "$REPO" >/dev/null
write_handoff termA SUCCESSOR_LAUNCHED termC "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_handoff termD SUCCESSOR_LAUNCHED termE "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
set_terminals '{"terminals":[{"handle":"termA","connected":true,"orphaned":false},{"handle":"termD","connected":true,"orphaned":false}]}'

out="$(lookup "$REPO")"
assert_eq "two in-progress handoffs -> ambiguous, not glob order" "$(jq -r .state <<<"$out")" "ambiguous"
assert_eq "  ...reason is PM_HANDOFF_AMBIGUOUS" "$(jq -r .reason <<<"$out")" "PM_HANDOFF_AMBIGUOUS"
assert_eq "  ...both old terminals are named" "$(jq -c '[.handoffs[].old.terminal] | sort' <<<"$out")" '["termA","termD"]'
assert_eq "  ...both successors are named" "$(jq -c '[.handoffs[].successor.terminal] | sort' <<<"$out")" '["termC","termE"]'

write_paperclip_config proj1 "$REPO"
write_notice proj1 1000 66666666-6666-6666-6666-666666666666 claimed
ORCA_TERMINAL_HANDLE=termC run_afk paperclip-take --slug proj1 --json
assert_eq "no successor may take while the handoff is ambiguous" "$(jq -r .result <<<"$OUT_TEXT")" "PAPERCLIP_NOT_OWNER"

# ============================================================================
head1 "7. pm-registry-reap never strands a notice silently"
# ============================================================================
reset_state
SK7="$(write_owner termA 11111111-1111-1111-1111-111111111111 "$REPO")"
write_paperclip_config proj1 "$REPO"
IDA=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
IDB=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
IDC=cccccccc-cccc-cccc-cccc-cccccccccccc
write_notice proj1 1000 "$IDA" claimed
write_notice proj1 2000 "$IDB" claimed
write_notice proj1 3000 "$IDC" claimed
set_terminals '{"terminals":[{"handle":"termA","connected":true,"orphaned":false}]}'
ORCA_TERMINAL_HANDLE=termA run_afk paperclip-take --slug proj1 --json
assert_eq "take claims all three seeded notices" "$RC" "0"

CLAIMED_DIR="$STATE/paperclip/notices/claimed/$(scope_key termA)"
UNRETURNED_DIR="$STATE/paperclip/notices/unreturned/$SK7"

# A: an invalid project on the claimed notice.
jq -c '.slug="../bad"' "$CLAIMED_DIR/1000.$IDA.claimed.json" >"$CLAIMED_DIR/1000.$IDA.claimed.json.tmp" \
  && mv "$CLAIMED_DIR/1000.$IDA.claimed.json.tmp" "$CLAIMED_DIR/1000.$IDA.claimed.json"

# B: the project destination is already occupied by a duplicate, so the
# recovery path is used instead (and succeeds, since nothing occupies it).
mkdir -p "$STATE/paperclip/notices/proj1"
: >"$STATE/paperclip/notices/proj1/2000.$IDB.claimed.json"

# C: the project destination AND the recovery destination are both already
# occupied — this one must stay exactly where it is, in the claimed dir.
: >"$STATE/paperclip/notices/proj1/3000.$IDC.claimed.json"
mkdir -p "$UNRETURNED_DIR"
: >"$UNRETURNED_DIR/3000.$IDC.claimed.json"

set_terminals '{"terminals":[]}'
run_afk pm-registry-reap --scope "$SK7" --json
assert_eq "reap still reaps the stale owner" "$(jq -r .result <<<"$OUT_TEXT")" "reaped"
assert_eq "  ...exit code 3 (notices were stranded)" "$RC" "3"
assert_eq "  ...none of the three notices were cleanly returned" "$(jq -r .notices_returned <<<"$OUT_TEXT")" "0"
assert_eq "  ...all three are reported stranded" "$(jq -r .notices_stranded <<<"$OUT_TEXT")" "3"

assert_eq "  ...A is recovered under notices/unreturned/<scope>/" \
  "$([[ -f "$UNRETURNED_DIR/1000.$IDA.claimed.json" ]] && echo yes || echo no)" "yes"
assert_eq "  ...B is recovered under notices/unreturned/<scope>/" \
  "$([[ -f "$UNRETURNED_DIR/2000.$IDB.claimed.json" ]] && echo yes || echo no)" "yes"
assert_eq "  ...C is left exactly where it was (never overwritten, never dropped)" \
  "$([[ -f "$CLAIMED_DIR/3000.$IDC.claimed.json" ]] && echo yes || echo no)" "yes"
assert_eq "  ...C's would-be recovery duplicate was not overwritten" \
  "$(cat "$UNRETURNED_DIR/3000.$IDC.claimed.json")" ""
assert_contains "  ...C is named in the stranded report by its source path" \
  "$(jq -r '[.stranded[].source] | join(",")' <<<"$OUT_TEXT")" "$CLAIMED_DIR/3000.$IDC.claimed.json"

# ============================================================================
assert_eq "the PATH decoy orca never ran" \
  "$([[ -e "$STUBS/.bare-orca-ran" ]] && echo ran || echo never)" "never"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
