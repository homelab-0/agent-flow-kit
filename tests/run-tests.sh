#!/usr/bin/env bash
# run-tests.sh — fixture-driven proof that the rewired dispatcher does what the
# frozen contracts say, without a live BMAD run and without launching a harness.
#
# Two layers:
#   UNIT        — dispatch.sh is sourced (its main() is guarded), and the pure
#                 builders are called directly. This is where the generated
#                 terminal command text is asserted on.
#   INTEGRATION — dispatch.sh is RUN against a temporary worktree with stubbed
#                 orca / agent-stamp-validate / curl / claude binaries on PATH.
#                 Every refusal path is reached for real, and its exit code is
#                 the assertion.
#
# The lifecycle surface has its own isolated gates — tests/lifecycle-tests.sh
# for the read-only half, tests/lifecycle-mutation-tests.sh for the destructive
# half, tests/lifecycle-concurrency-tests.sh for the operation lock under real
# contention, tests/lifecycle-readiness-tests.sh for scoped execution
# readiness, and tests/lifecycle-dispatch-tests.sh for the durable
# worker-completion watch and its provenance-bound cleanup. Sections 6 through
# 10 aggregate them here so one command still answers "is the kit green".
#
# Usage: tests/run-tests.sh
# Exit:  0 all passed, 1 any failure.

# SC2016 is disabled file-wide ON PURPOSE: many needles here are single-quoted
# '$HOME' / '$(' / '$?' strings that MUST stay literal. Expanding them is
# precisely the bug these assertions exist to catch.
# shellcheck disable=SC2016

set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH="$KIT_ROOT/files/model-router/scripts/dispatch.sh"
MAKE_STAMP="$KIT_ROOT/files/model-router/scripts/make-stamp.sh"
USAGE_CHECK="$KIT_ROOT/files/model-router/scripts/usage-check.sh"
GH_HEALTH="$KIT_ROOT/files/model-router/scripts/github-health.sh"

TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT
WORK_OLD="$TMPROOT/old"

PASS=0 FAIL=0 SKIPPED=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  {
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  if [[ -n "${2:-}" ]]; then printf '        %s\n' "$2"; fi
  FAIL=$((FAIL+1))
}
head1(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; SKIPPED=$((SKIPPED+1)); }

assert_eq()       { if [[ "$2" == "$3"    ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing substring: $3"; fi; }
assert_absent()   { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "should NOT contain: $3"; fi; }
assert_no_file()    { if [[ -f "$2" ]]; then bad "$1" "file exists: $2"; else ok "$1"; fi; }
assert_empty_file() { if [[ -s "$2" ]]; then bad "$1" "non-empty: $2"; else ok "$1"; fi; }

# ===========================================================================
head1 "0. shellcheck — every script the kit ships"
# ===========================================================================

# A sub-gate that cannot run must say so. The previous form captured stdout
# only, discarded stderr and never looked at the exit status, so a checker that
# failed to START — `nix run` refusing a disabled experimental feature is the
# live example — produced empty stdout and was read as "clean". Twelve scripts
# were reported checked by a checker that never executed.
#
# So the checker is PROVED to run before anything is checked with it: it is
# asked for its version and must exit 0 and identify itself. What it then says
# about each file is decided by its exit status, not by whether it happened to
# print something. shellcheck is not required to be installed; it is required
# that the gate never claims a result it did not compute.

SC_CMD=()
SC_VERSION=""
SC_WHY=""

sc_probe() { # <command word>...
  local out rc
  out="$("$@" --version 2>&1)"; rc=$?
  if (( rc != 0 )); then
    SC_WHY="$1 exited $rc: $(head -1 <<<"$out")"; return 1
  fi
  if [[ "$out" != *ShellCheck* ]]; then
    SC_WHY="$1 answered --version without identifying as ShellCheck"; return 1
  fi
  SC_VERSION="$(awk -F': *' '/^version:/ {print $2; exit}' <<<"$out")"
  return 0
}

if command -v shellcheck >/dev/null && sc_probe shellcheck; then
  SC_CMD=(shellcheck)
elif command -v nix >/dev/null &&
     sc_probe nix --extra-experimental-features "nix-command flakes" run nixpkgs#shellcheck --; then
  SC_CMD=(nix --extra-experimental-features "nix-command flakes" run nixpkgs#shellcheck --)
elif command -v nix >/dev/null && sc_probe nix run nixpkgs#shellcheck --; then
  SC_CMD=(nix run nixpkgs#shellcheck --)
fi

# One file, one verdict, decided by the checker's exit status:
#   0 with no output  the file is clean
#   1 with output     the file has findings   -> FAIL, findings shown
#   anything else     the checker did not deliver a verdict -> FAIL, never PASS
sc_check() { # <path> [extra checker args...]
  local f="$1"; shift
  local errf="$TMPROOT/shellcheck.err" out rc
  out="$("${SC_CMD[@]}" -s bash "$@" "$f" 2>"$errf")"; rc=$?
  local base; base="$(basename "$f")"
  case "$rc" in
    0)
      if [[ -n "$out" ]]; then
        bad "shellcheck clean: $base" "exit 0 but the checker still reported: $(head -1 <<<"$out")"
      else
        ok "shellcheck clean: $base"
      fi ;;
    1)
      if [[ -z "$out" ]]; then
        bad "shellcheck ran: $base" "checker exited 1 with no findings — it did not run: $(head -1 "$errf")"
      else
        bad "shellcheck clean: $base" "$(head -5 <<<"$out")"
      fi ;;
    *)
      bad "shellcheck ran: $base" "checker exited $rc: $(head -1 "$errf")" ;;
  esac
}

SC_SCRIPTS=("$DISPATCH" "$MAKE_STAMP" "$USAGE_CHECK" "$GH_HEALTH")
# The lifecycle surface. Checked at warning level and above, with two codes
# excluded for a structural reason rather than a stylistic one: the lifecycle
# files are always sourced together and share one result model, so a variable
# assigned in afk-common.sh and read in afk-inventory.sh looks unused (SC2034)
# or unassigned (SC2154) to a single-file analysis. `set -u` in the entry point
# is the real guard against an unset read.
SC_LIFECYCLE=("$KIT_ROOT/bin/agent-flow-kit" "$KIT_ROOT/lib/afk-common.sh" \
              "$KIT_ROOT/lib/afk-source.sh" "$KIT_ROOT/lib/afk-inventory.sh" \
              "$KIT_ROOT/lib/afk-readiness.sh" "$KIT_ROOT/lib/afk-monitor.sh" \
              "$KIT_ROOT/lib/afk-commands.sh" \
              "$KIT_ROOT/lib/afk-plan.sh" "$KIT_ROOT/lib/afk-mutate.sh" \
              "$KIT_ROOT/tests/lockctl-helper.sh")

if (( ${#SC_CMD[@]} > 0 )); then
  ok "shellcheck runs here: ${SC_CMD[0]} ${SC_VERSION:-(version not reported)}"
  for s in "${SC_SCRIPTS[@]}"; do
    [[ -f "$s" ]] || continue
    sc_check "$s"
  done
  for s in "${SC_LIFECYCLE[@]}"; do
    [[ -f "$s" ]] || continue
    sc_check "$s" --severity=warning --exclude=SC2034,SC2154
  done
else
  printf '  \033[33m!! shellcheck did not run on this host: %s\033[0m\n' \
    "${SC_WHY:-no shellcheck and no nix on PATH}"
  printf '  \033[33m!! nothing below section 0 was linted; this gate reports NOTHING, not clean\033[0m\n'
  for s in "${SC_SCRIPTS[@]}" "${SC_LIFECYCLE[@]}"; do
    [[ -f "$s" ]] || continue
    skip "shellcheck NOT RUN: $(basename "$s")"
  done
fi

# ===========================================================================
head1 "1. Pure builders (dispatch.sh sourced, main() not run)"
# ===========================================================================

# shellcheck source=/dev/null
source "$DISPATCH"

# --- effort: the closed set, validated fail-closed -------------------------
for e in low medium high xhigh; do
  if effort_is_stampable "$e"; then ok "effort '$e' accepted (one-to-one, not collapsed)"
  else bad "effort '$e' accepted"; fi
done
for e in max banana HIGH "" "high "; do
  if effort_is_stampable "$e"; then bad "effort '$e' rejected" "fail-open effort would run at the DEFAULT effort silently"
  else ok "effort '${e:-<empty>}' rejected fail-closed"; fi
done

# --- launch-contract capability: what THIS adapter can actually launch -----
# The adapter declares its own capability; it never judges the route. Native
# reachability is stamp-derived, belt and braces: profile family AND
# entitlement pool must both be the harness vendor's own.
assert_eq "guard: {claude, claude/strong, anthropic-max} native pair is launchable" \
  "$(unsupported_launch_reason claude 'claude/strong' false anthropic-max)" ""
assert_eq "guard: {codex, openai/strong, openai-plus} native pair is launchable" \
  "$(unsupported_launch_reason codex 'openai/strong' false openai-plus)" ""
if [[ -n "$(unsupported_launch_reason claude local-code-standard true '')" ]]; then
  ok "guard: {claude, local profile} has NO validated launch contract"
else
  bad "guard: {claude, local profile} has NO validated launch contract"
fi
if [[ -n "$(unsupported_launch_reason codex local-code-standard true '')" ]]; then
  ok "guard: {codex, local profile} has NO validated launch contract"
else
  bad "guard: {codex, local profile} has NO validated launch contract"
fi
assert_contains "guard: local reason names the forbidden redirection" \
  "$(unsupported_launch_reason claude local-code-standard true '')" "explicitly forbids"

# The second instance of the class: {claude, minimax/strong} is vendor-hosted
# (placement_required=false) in catalog 1.5.0, reachable ONLY via the forbidden
# ANTHROPIC_BASE_URL redirection. The old placement-keyed guard waved it
# through to a native Anthropic launch of 'm3' on anthropic-max while every
# artifact recorded minimax — the exact provenance mismatch this refuses.
MINIMAX_REASON="$(unsupported_launch_reason claude 'minimax/strong' false minimax-max)"
if [[ -n "$MINIMAX_REASON" ]]; then
  ok "guard: {claude, minimax/strong, minimax-max} REFUSED (no native reachability)"
else
  bad "guard: {claude, minimax/strong, minimax-max} REFUSED (no native reachability)" \
    "a vendor-hosted non-native pair passed the guard: silent provider/funding mismatch"
fi
assert_contains "guard: minimax reason names the profile-family mismatch" \
  "$MINIMAX_REASON" "outside the native family 'claude/*'"
assert_contains "guard: minimax reason names the pool mismatch" \
  "$MINIMAX_REASON" "'minimax-max' is not the native pool 'anthropic-max'"
if [[ -n "$(unsupported_launch_reason codex 'minimax/strong' false minimax-max)" ]]; then
  ok "guard: {codex, minimax/strong} REFUSED (cross-harness control)"
else
  bad "guard: {codex, minimax/strong} REFUSED (cross-harness control)"
fi
# Belt and braces: either mismatch ALONE refuses.
if [[ -n "$(unsupported_launch_reason claude 'claude/strong' false minimax-max)" ]]; then
  ok "guard: native family on a foreign pool REFUSED"
else
  bad "guard: native family on a foreign pool REFUSED"
fi
if [[ -n "$(unsupported_launch_reason claude 'minimax/strong' false anthropic-max)" ]]; then
  ok "guard: foreign family on the native pool REFUSED"
else
  bad "guard: foreign family on the native pool REFUSED"
fi

# --- validator exit remap: never collides with dispatch's own 0/1/2/3 ------
assert_eq "validator exit 0 -> dispatch 0 (proceed)"           "$(remap_validator_exit 0)" "0"
assert_eq "validator exit 1 -> dispatch 4 (policy-invalid)"     "$(remap_validator_exit 1)" "4"
assert_eq "validator exit 2 -> dispatch 5 (uncheckable)"        "$(remap_validator_exit 2)" "5"
assert_eq "validator exit 127 -> dispatch 5 (uncheckable)"      "$(remap_validator_exit 127)" "5"

# --- provider qualifier stripped at the CLI boundary only ------------------
assert_eq "claude/opus -> opus"                 "$(native_model_arg 'claude/opus')" "opus"
assert_eq "openai/gpt-5.6-sol -> gpt-5.6-sol"   "$(native_model_arg 'openai/gpt-5.6-sol')" "gpt-5.6-sol"

# --- the generated claude command ------------------------------------------
TASK_TEXT='Implement the widget; then run `rm -rf /` "$(whoami)"'
CMD="$(build_claude_command "/home/op" "/usr/bin:/bin" "op" \
        "/wt/STORY.md.prompt" "opus" "xhigh" "/wt/STORY.md.claude-result.json" \
        "/wt/_bmad/bmm/agents/dev.md")"

head1 "   generated claude terminal command"
printf '   %s\n' "$CMD"

assert_contains "claude cmd: allowlist sanitizer (env -i)"      "$CMD" "env -i "
assert_contains "claude cmd: HOME is a launcher literal"        "$CMD" "HOME=/home/op"
assert_contains "claude cmd: PATH is a launcher literal"        "$CMD" "PATH=/usr/bin:/bin"
assert_contains "claude cmd: USER is a launcher literal"        "$CMD" "USER=op"
assert_contains "claude cmd: LANG/TERM pinned"                  "$CMD" "LANG=C.UTF-8 TERM=dumb"
assert_contains "claude cmd: stamped model passed explicitly"   "$CMD" "--model opus"
assert_contains "claude cmd: stamped effort passed explicitly"  "$CMD" "--effort xhigh"
assert_contains "claude cmd: explicit least-privilege tools"    "$CMD" '--tools "Read,Glob,Grep,Write"'
assert_contains "claude cmd: --strict-mcp-config mandatory"     "$CMD" "--strict-mcp-config"
assert_contains "claude cmd: permission mode acceptEdits"       "$CMD" "--permission-mode acceptEdits"
assert_contains "claude cmd: stdin redirected"                  "$CMD" "< /dev/null"
assert_contains "claude cmd: JSON result to a FILE, not stdout" "$CMD" "> /wt/STORY.md.claude-result.json"
assert_contains "claude cmd: in-band exit capture"              "$CMD" 'echo "CLAUDE_EXIT=$?"'
assert_contains "claude cmd: prompt read from the prompt file"  "$CMD" 'cat -- /wt/STORY.md.prompt'
assert_contains "claude cmd: persona injected by PATH"          "$CMD" "--append-system-prompt-file /wt/_bmad/bmm/agents/dev.md"

# The two frozen Claude requirements this is really here to prove:
# TASK_TEXT is hostile on purpose: a backtick, a quote and a command
# substitution. None of it may appear in the generated command.
assert_absent "claude cmd: NO task text is shell source"        "$CMD" "$TASK_TEXT"
assert_absent "claude cmd: no task backtick survives"           "$CMD" "rm -rf"
assert_absent "claude cmd: no task subshell survives"           "$CMD" "whoami"
assert_absent "claude cmd: no runtime \$HOME lookup"            "$CMD" '$HOME'
assert_absent "claude cmd: no runtime \$PATH lookup"            "$CMD" '$PATH'
assert_absent "claude cmd: no runtime \$USER lookup"            "$CMD" '$USER'
assert_absent "claude cmd: CLAUDE_CONFIG_DIR never propagated"  "$CMD" "CLAUDE_CONFIG_DIR"
assert_absent "claude cmd: no Bash/shell tool granted"          "$CMD" "Bash"
assert_absent "claude cmd: no permission bypass"                "$CMD" "dangerously"
assert_absent "claude cmd: no bypassPermissions"                "$CMD" "bypassPermissions"
assert_absent "claude cmd: --bare forbidden"                    "$CMD" "--bare"

# Only ONE command substitution may appear, and it must be the prompt file read.
subs="$(grep -o '\$(' <<<"$CMD" | wc -l)"
assert_eq "claude cmd: exactly one command substitution (the prompt file)" "$subs" "1"

# --- the generated codex command -------------------------------------------
CCMD="$(build_codex_command "/wt/STORY.md.prompt" "gpt-5.6-sol" "xhigh")"
head1 "   generated codex terminal command"
printf '   %s\n' "$CCMD"

assert_contains "codex cmd: OPENAI_API_KEY unset"           "$CCMD" "-u OPENAI_API_KEY"
assert_contains "codex cmd: CODEX_API_KEY unset"            "$CCMD" "-u CODEX_API_KEY"
assert_contains "codex cmd: ANTHROPIC_API_KEY unset too"    "$CCMD" "-u ANTHROPIC_API_KEY"
assert_contains "codex cmd: sandbox workspace-write"        "$CCMD" "-s workspace-write"
assert_contains "codex cmd: xhigh PRESERVED, not collapsed" "$CCMD" "model_reasoning_effort=xhigh"
assert_contains "codex cmd: in-band exit capture"           "$CCMD" 'echo "CODEX_EXIT=$?"'
assert_contains "codex cmd: task via the prompt file"       "$CCMD" 'cat -- /wt/STORY.md.prompt'
assert_absent   "codex cmd: --full-auto forbidden"          "$CCMD" "--full-auto"
assert_absent   "codex cmd: no approvals/sandbox bypass"    "$CCMD" "dangerously-bypass"
assert_absent   "codex cmd: no danger-full-access"          "$CCMD" "danger-full-access"

# high must stay high, and must not be reachable from xhigh
assert_contains "codex cmd: high maps to high" \
  "$(build_codex_command /p m high)" "model_reasoning_effort=high"

# ===========================================================================
head1 "2. Retired paths are actually gone (source greps)"
# ===========================================================================

# CODE only: full-line comments are stripped first, so a pattern cannot be
# "satisfied" by prose in a comment that merely explains why the thing is gone.
code_of() { grep -vE '^[[:space:]]*#' "$1"; }

grep_absent() { # name file pattern  (raw: for prose files)
  # Stack-aware: a file still byte-identical to the 02b18d0 base has not been
  # migrated at this layer of the stacked-PR chain yet - skip honestly rather
  # than fail. At the top of the stack every file differs from base, so
  # nothing is skipped and every assertion runs.
  local rel="${2#"$KIT_ROOT"/}"
  if git -C "$KIT_ROOT" diff --quiet 02b18d0 -- "$rel" 2>/dev/null; then
    skip "$1 (file unchanged from base: later stack layer)"
    return
  fi
  if grep -qE "$3" "$2" 2>/dev/null; then bad "$1" "still present in $(basename "$2")"; else ok "$1"; fi
}

# The retired dispatcher, as it actually was. Every pattern below is asserted to
# MATCH it — a grep that no longer matches the old code is a vacuous grep, and
# would silently stop guarding anything.
OLD_DISPATCH="$WORK_OLD/dispatch.old.sh"
mkdir -p "$(dirname "$OLD_DISPATCH")"
if git -C "$KIT_ROOT" show 02b18d0:files/model-router/scripts/dispatch.sh > "$OLD_DISPATCH" 2>/dev/null; then
  HAVE_OLD=1
else
  HAVE_OLD=0
fi

grep_gone() { # name pattern — absent from the new code AND present in the old
  local name="$1" pat="$2"
  if code_of "$DISPATCH" | grep -qE "$pat"; then
    bad "$name" "still present in dispatch.sh"
    return
  fi
  if (( HAVE_OLD )) && ! code_of "$OLD_DISPATCH" | grep -qE "$pat"; then
    bad "$name" "VACUOUS GREP: pattern '$pat' did not match the retired code either"
    return
  fi
  ok "$name"
}

grep_gone "dispatch: rate-limit fallback loop deleted"   'rate.?limit|usage limit|limit reached|overloaded'
grep_gone "dispatch: FALLBACKS array deleted"            'FALLBACKS'
grep_gone "dispatch: ROUTES fallback iteration deleted"  'for route in'
grep_gone "dispatch: route.fallback no longer read"      'route\.fallback'
grep_gone "dispatch: route.provider/model no longer read" "\.route\.(provider|model|effort|agent)"
grep_gone "dispatch: subscriptions provider lookup gone" 'providers\.'
grep_gone "dispatch: --full-auto gone"                   '[-]-full-auto'
grep_gone "dispatch: --skip-git-repo-check gone"         '[-]-skip-git-repo-check'
grep_gone "dispatch: old .bmad/agents default gone"      '\.bmad/agents'
grep_gone "dispatch: lossy xhigh->high collapse gone"    'xhigh\|high'

# These two never existed in dispatch.sh (they were SKILL.md prose); assert the
# new code does not introduce them.
if code_of "$DISPATCH" | grep -qE 'orchestration|worker-start'; then
  bad "dispatch: no orca orchestration worker-start" "present in code"
else ok "dispatch: no orca orchestration worker-start"; fi
if code_of "$DISPATCH" | grep -qE 'terminal wait'; then
  bad "dispatch: never relies on 'terminal wait' (it does not fire)" "present in code"
else ok "dispatch: never relies on 'terminal wait' (it does not fire)"; fi

grep_absent "SKILL: worker-start bypass path removed"      "$KIT_ROOT/files/model-router/SKILL.md" 'worker-start'
grep_absent "SKILL: tier/leaderboard routing tables gone"  "$KIT_ROOT/files/model-router/SKILL.md" 'leaderboard|SWE-bench|LMArena'
# as a frontmatter KEY, not as prose explaining that it is gone
grep_absent "SKILL: local_gpu no longer a frontmatter key"  "$KIT_ROOT/files/model-router/SKILL.md" '^[[:space:]]*local_gpu:'
grep_absent "SKILL: route no longer a frontmatter key"      "$KIT_ROOT/files/model-router/SKILL.md" '^[[:space:]]*route:'
grep_absent "HANDOFF: route no longer a frontmatter key"    "$KIT_ROOT/HANDOFF.md" '^[[:space:]]*route: \{'
grep_absent "HANDOFF: local_gpu no longer a frontmatter key" "$KIT_ROOT/HANDOFF.md" '^[[:space:]]*local_gpu:'
grep_absent "subscriptions: routing tables retired"        "$KIT_ROOT/files/model-router/subscriptions.yaml" '^routing:|budget_rules|fallbacks:|review_diversity'
grep_absent "usage-check: routing guidance retired"        "$USAGE_CHECK" 'routing guidance by'

if grep -q '_bmad/bmm/agents' "$DISPATCH"; then ok "dispatch: AGENT_DIR default is _bmad/bmm/agents"
else bad "dispatch: AGENT_DIR default is _bmad/bmm/agents"; fi

# ===========================================================================
head1 "3. Integration — real dispatch.sh against stubbed Orca/validator/router"
# ===========================================================================

WORK="$TMPROOT/work"; mkdir -p "$WORK"
BIN="$WORK/bin"; WT="$WORK/wt"; HOME_DIR="$WORK/home"
mkdir -p "$BIN" "$WT/_bmad/bmm/agents" "$HOME_DIR/.claude"
printf 'You are the dev persona.\n' > "$WT/_bmad/bmm/agents/dev.md"

# --- trusted catalog (the launcher's, never the stamp's) -------------------
cat > "$WORK/catalog.yaml" <<'YAML'
schema_version: 1
profiles:
  "claude/strong":
    hosting: vendor
    physical:
      - model_id: "claude/opus"
        placement: null
  local-code-standard:
    hosting: local
    physical:
      - model_id: qwen36-27b
        placement: workstation
  "minimax/strong":
    hosting: vendor
    physical:
      - model_id: "minimax/m3"
        placement: null
YAML

# --- stub orca ------------------------------------------------------------
cat > "$BIN/orca" <<'STUB'
#!/usr/bin/env bash
sub="$1 $2"; shift 2 || true
case "$sub" in
  "worktree list")
    jq -n --arg p "$STUB_WT_PATH" --arg id "$STUB_WT_ID" \
      '{ok:true,result:{worktrees:[{id:$id,path:$p}]}}' ;;
  "repo list")
    jq -n --arg id "$STUB_REPO_ID" --arg pol "${STUB_SETUP_POLICY:-start-immediately}" \
      '{ok:true,result:{repos:[{id:$id,hookSettings:{setupAgentStartupPolicy:$pol}}]}}' ;;
  "terminal create")
    while (( $# )); do
      case "$1" in
        --command) printf '%s' "$2" > "$STUB_STATE/last-command.txt"; shift 2 ;;
        --title)   printf '%s' "$2" > "$STUB_STATE/last-title.txt"; shift 2 ;;
        *) shift ;;
      esac
    done
    echo created >> "$STUB_STATE/terminal-creates"
    jq -n '{ok:true,result:{terminal:{handle:"term_stub"}}}' ;;
  "terminal read")
    jq -n --arg t "${STUB_TERMINAL_TAIL:-}" \
      '{ok:true,result:{terminal:{handle:"term_stub",status:"running",
        tail:($t|split("\n"))}}}' ;;
  "terminal rename") jq -n '{ok:true}' ;;
  *) jq -n '{ok:true,result:{}}' ;;
esac
STUB

# --- stub agent-stamp-validate: exit code + argv recorder -----------------
cat > "$BIN/agent-stamp-validate" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$STUB_STATE/validator-argv.txt"
rc="${STUB_VALIDATOR_EXIT:-0}"
case "$rc" in
  0) jq -n '{valid:true, catalog_version:"sha256:'"$(printf '0%.0s' {1..64})"'", checks:[]}' ;;
  1) jq -n '{valid:false, catalog_version:"sha256:x", checks:[
        {name:"not_expired",passed:false,reason_code:"stamp_expired",
         message:"stamp expired at 2020-01-01T00:00:00Z"}]}' ;;
  *) echo "agent-stamp-validate: malformed stamp: boom" >&2 ;;
esac
exit "$rc"
STUB

# --- stub curl (POST /v1/place) -------------------------------------------
cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [[ "$prev" == "-o" ]] && out="$a"; prev="$a"; done
echo "$*" >> "$STUB_STATE/curl-calls"
if [[ "${STUB_PLACE_HTTP:-200}" == "200" ]]; then
  [[ -n "$out" ]] && jq -n '{status:"placed", model:"qwen36-27b",
      placement:"workstation", readiness:"warm", headers:{"x-placement":"workstation"},
      ttl_seconds:30, reason:null, alternatives:[], catalog_version:"sha256:x"}' > "$out"
  printf '200'
else
  [[ -n "$out" ]] && printf '{}' > "$out"
  printf '%s' "${STUB_PLACE_HTTP}"
fi
STUB

printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/claude"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/codex"
chmod +x "$BIN"/*

STUB_STATE="$WORK/state"; mkdir -p "$STUB_STATE"
export STUB_STATE
export STUB_WT_PATH="$WT"
export STUB_REPO_ID="repo-1234"
export STUB_WT_ID="repo-1234::$WT"

# --- fixtures -------------------------------------------------------------
write_stamp() { # write_stamp <file> <effort> <placement_required> [profile] [harness] [pool]
  # A local (placement_required) profile is free and draws on no entitlement
  # pool, exactly as the catalog declares it — the fixture stays truthful even
  # though the stubbed validator would not notice.
  jq -n --arg e "$2" --argjson pr "$3" --arg p "${4:-claude/strong}" \
        --arg h "${5:-claude}" --arg pool "${6:-}" \
    '{harness:$h, model_profile:$p, effort:$e,
      cost_class:(if $pr then "free" else "subscription" end),
      entitlement_pool:(if $pr then null
                        elif $pool != "" then $pool
                        else "anthropic-max" end),
      metered:false,
      placement_policy:"prefer-warm-local", placement_required:$pr,
      catalog_version:"sha256:abc", expires_at:"2099-01-01T00:00:00Z",
      task:{story_id:"STORY-TEST-1", tags:["docs"]}, override:null}' > "$1"
}

write_story() { # write_story <file> <frontmatter-body>
  { printf -- '---\n%s\n---\n\nDo the thing.\n' "$2"; } > "$1"
}

# Hermetic: every launcher env var dispatch.sh reads is pinned here, so an
# ambient live-chain configuration (section 5) can never shadow a stub.
run_dispatch() { # run_dispatch <story> -> echoes exit code, stderr to $WORK/err
  ( cd "$WT" && PATH="$BIN:$PATH" HOME="$HOME_DIR" \
      AGENT_STAMP_VALIDATE="agent-stamp-validate" \
      AGENT_STAMP_VALIDATE_CATALOG_PATH="$WORK/catalog.yaml" \
      AGENT_FLOW_CONFIG="$WORK/nonexistent.yaml" \
      SUBSCRIPTIONS_FILE="" \
      AGENT_ROUTER_URL="https://router.invalid" \
      AGENT_ROUTER_TOKEN="stub-token" \
      AGENT_ROUTER_TOKEN_ENV="AGENT_ROUTER_TOKEN" \
      AGENT_DIR="" AGENT_FLOW_APPROVED_HOME="" AGENT_FLOW_APPROVED_PATH="" \
      AGENT_FLOW_LAUNCH_TIMEOUT=20 \
      CLAUDE_CONFIG_DIR="" \
      bash "$DISPATCH" "$1" 1 ) >"$WORK/out" 2>"$WORK/err"
  echo $?
}

# ---- empty gates fail closed ---------------------------------------------
write_story "$WT/s-nogates.md" "persona: dev
gates: []
max_cycles: 3"
write_stamp "$WT/s-nogates.md.stamp.json" high false
rc="$(run_dispatch s-nogates.md)"
assert_eq "empty gates -> exit 2 (refuses; never emits 'done')" "$rc" "2"
assert_contains "empty gates: says why" "$(cat "$WORK/err")" "cannot distinguish done from claimed-done"
assert_no_file "empty gates: no result artifact written" "$WT/s-nogates.md.result.json"

# ---- a stale route: block is refused, not ignored -------------------------
write_story "$WT/s-route.md" "persona: dev
route: {provider: claude, model: opus}
gates: [\"true\"]"
write_stamp "$WT/s-route.md.stamp.json" high false
rc="$(run_dispatch s-route.md)"
assert_eq "legacy route: block -> exit 2" "$rc" "2"
assert_contains "legacy route: block explains the move" "$(cat "$WORK/err")" "no longer an authority"

# ---- persona named but file missing: LOUD, never a silent no-op ----------
write_story "$WT/s-persona.md" "persona: ghostwriter
gates: [\"true\"]"
write_stamp "$WT/s-persona.md.stamp.json" high false
rc="$(run_dispatch s-persona.md)"
assert_eq "missing persona file -> exit 2" "$rc" "2"
assert_contains "missing persona: names the path it looked for" \
  "$(cat "$WORK/err")" "_bmad/bmm/agents/ghostwriter.md"
assert_contains "missing persona: says it must never no-op" \
  "$(cat "$WORK/err")" "never silently no-op"

# ---- missing stamp -------------------------------------------------------
write_story "$WT/s-nostamp.md" "persona: dev
gates: [\"true\"]"
rc="$(run_dispatch s-nostamp.md)"
assert_eq "no stamp -> exit 5 (uncheckable)" "$rc" "5"

# ---- effort outside the closed set --------------------------------------
write_story "$WT/s-effort.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/s-effort.md.stamp.json" max false
rc="$(run_dispatch s-effort.md)"
assert_eq "stamped effort 'max' -> exit 4 (fail-closed before launch)" "$rc" "4"
assert_contains "bad effort: explains --effort fails OPEN" \
  "$(cat "$WORK/err")" "fails OPEN"

# ---- validator says policy-invalid --------------------------------------
write_story "$WT/s-invalid.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/s-invalid.md.stamp.json" high false
rc="$(STUB_VALIDATOR_EXIT=1; export STUB_VALIDATOR_EXIT; run_dispatch s-invalid.md)"
assert_eq "validator exit 1 -> dispatch exit 4" "$rc" "4"
assert_contains "policy-invalid: failing check surfaced" "$(cat "$WORK/err")" "stamp_expired"
assert_no_file    "policy-invalid: no result artifact" "$WT/s-invalid.md.result.json"
assert_empty_file "policy-invalid: nothing was launched" "$STUB_STATE/terminal-creates"

# ---- validator could not run --------------------------------------------
rc="$(STUB_VALIDATOR_EXIT=2; export STUB_VALIDATOR_EXIT; run_dispatch s-invalid.md)"
assert_eq "validator exit 2 -> dispatch exit 5" "$rc" "5"
assert_contains "uncheckable: validator stderr surfaced" "$(cat "$WORK/err")" "malformed stamp"

# ---- catalog is launcher config, NEVER from the stamp -------------------
assert_contains "validator called with the launcher's --catalog" \
  "$(cat "$STUB_STATE/validator-argv.txt")" "--catalog $WORK/catalog.yaml"

# ---- placement NOT required: no /v1/place, no --evidence ----------------
: > "$STUB_STATE/curl-calls"
write_story "$WT/s-vendor.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/s-vendor.md.stamp.json" high false
export STUB_TERMINAL_TAIL="worker output here
CLAUDE_EXIT=0"
rc="$(run_dispatch s-vendor.md)"
assert_eq "vendor profile: full happy path -> exit 0" "$rc" "0"
assert_empty_file "vendor profile: no /v1/place call" "$STUB_STATE/curl-calls"
assert_absent "vendor profile: NO --evidence passed (presence is itself a failure)" \
  "$(cat "$STUB_STATE/validator-argv.txt")" "--evidence"
assert_contains "vendor profile: says placement not required" "$(cat "$WORK/err")" "not required"

# ---- the happy-path result artifact -------------------------------------
RES="$WT/s-vendor.md.result.json"
if [[ -f "$RES" ]]; then
  ok "result.json written"
  assert_eq "result: status done"            "$(jq -r .status "$RES")" "done"
  assert_eq "result: catalog_version carried" "$(jq -r .stamp.catalog_version "$RES")" "sha256:abc"
  assert_eq "result: stamp digest carried"    "$(jq -r '.stamp.digest|startswith("sha256:")' "$RES")" "true"
  assert_eq "result: stamp marked validated"  "$(jq -r .stamp.validated "$RES")" "true"
  assert_eq "result: placement summary"       "$(jq -r .placement.required "$RES")" "false"
  assert_eq "result: harness recorded"        "$(jq -r .route.harness "$RES")" "claude"
  assert_eq "result: native model recorded"   "$(jq -r .route.native_model "$RES")" "opus"
  assert_eq "result: effort recorded"         "$(jq -r .route.effort "$RES")" "high"
  assert_eq "result: persona recorded"        "$(jq -r .route.persona "$RES")" "dev"
  assert_eq "result: orca terminal recorded"  "$(jq -r .launch.orca_terminal "$RES")" "term_stub"
  assert_eq "result: harness exit recorded"   "$(jq -r .launch.harness_exit "$RES")" "0"
  assert_eq "result: gate recorded"           "$(jq -r '.gates["true"]' "$RES")" "pass"
else
  bad "result.json written"
fi

# ---- the launched command is the frozen one, with no task text ----------
LAUNCHED="$(cat "$STUB_STATE/last-command.txt" 2>/dev/null || true)"
assert_contains "launched cmd: env -i sanitizer"       "$LAUNCHED" "env -i "
assert_contains "launched cmd: --strict-mcp-config"    "$LAUNCHED" "--strict-mcp-config"
assert_contains "launched cmd: stamped effort"         "$LAUNCHED" "--effort high"
assert_contains "launched cmd: prompt file, not text"  "$LAUNCHED" ".md.prompt"
assert_absent   "launched cmd: no story body inline"   "$LAUNCHED" "Do the thing"
assert_contains "terminal titled for Orca visibility"  "$(cat "$STUB_STATE/last-title.txt")" "claude claude/strong high"

# ---- gate failure is exit 1, and the worker's word does not override ----
write_story "$WT/s-gatefail.md" "persona: dev
gates: [\"false\"]"
write_stamp "$WT/s-gatefail.md.stamp.json" high false
rc="$(run_dispatch s-gatefail.md)"
assert_eq "failing gate -> exit 1 despite harness exit 0" "$rc" "1"
assert_eq "failing gate: status gates_failed" \
  "$(jq -r .status "$WT/s-gatefail.md.result.json")" "gates_failed"

# ---- unknown-effort stderr warning is FAILURE even on exit 0 -----------
export STUB_TERMINAL_TAIL="Warning: Unknown --effort value 'high' — ignoring it and using the default effort.
CLAUDE_EXIT=0"
rc="$(run_dispatch s-vendor.md)"
assert_eq "unknown-effort warning -> exit 4 even though CLAUDE_EXIT=0" "$rc" "4"
assert_contains "unknown-effort: says it ran at the DEFAULT effort" \
  "$(cat "$WORK/err")" "DEFAULT effort"

# ---- NEEDS-HUMAN -------------------------------------------------------
export STUB_TERMINAL_TAIL="NEEDS-HUMAN: which database should this point at?
CLAUDE_EXIT=0"
rc="$(run_dispatch s-vendor.md)"
assert_eq "NEEDS-HUMAN -> exit 3" "$rc" "3"

# ---- placement REQUIRED: /v1/place is called and evidence is passed ----
: > "$STUB_STATE/curl-calls"
export STUB_TERMINAL_TAIL="ok
CLAUDE_EXIT=0"
write_story "$WT/s-local.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/s-local.md.stamp.json" high true local-code-standard
rc="$(run_dispatch s-local.md)"
# The placement MACHINERY runs to completion; the launch is then refused by the
# capability guard, because no local profile has a validated launch contract on
# either vendor harness today (section 3b). Exit 7, not 0.
assert_eq "placement required: placed+validated, then refused at the guard" "$rc" "7"
assert_contains "placement required: POST /v1/place called" \
  "$(cat "$STUB_STATE/curl-calls")" "/v1/place"
assert_contains "placement required: --evidence passed to the validator" \
  "$(cat "$STUB_STATE/validator-argv.txt")" "--evidence"

# evidence is fetched PER ATTEMPT, never cached: a second run calls again
: > "$STUB_STATE/curl-calls"
rc="$(run_dispatch s-local.md)"
assert_contains "placement: re-fetched on the next attempt (never cached)" \
  "$(cat "$STUB_STATE/curl-calls")" "/v1/place"

# ---- /v1/place failure refuses the launch -----------------------------
rc="$(STUB_PLACE_HTTP=503; export STUB_PLACE_HTTP; run_dispatch s-local.md)"
assert_eq "/v1/place 503 -> exit 6 (refused, never launched unplaced)" "$rc" "6"

# ---- setup policy gate -------------------------------------------------
rc="$(STUB_SETUP_POLICY=wait-for-setup; export STUB_SETUP_POLICY; run_dispatch s-vendor.md)"
assert_eq "repo waits for setup -> refuses to launch" "$rc" "2"
assert_contains "setup gate: says STOP" "$(cat "$WORK/err")" "STOP"

# ---- not an Orca worktree: refuse to go invisible ---------------------
rc="$(STUB_WT_PATH=/nowhere; export STUB_WT_PATH; run_dispatch s-vendor.md)"
assert_eq "not an Orca worktree -> exit 2 (refuses invisible launch)" "$rc" "2"
assert_contains "invisible launch: explains the requirement" \
  "$(cat "$WORK/err")" "invisible to Orca"

# ---- non-default CLAUDE_CONFIG_DIR fails closed -----------------------
out_rc="$( cd "$WT" && PATH="$BIN:$PATH" HOME="$HOME_DIR" \
    AGENT_STAMP_VALIDATE="agent-stamp-validate" \
    AGENT_STAMP_VALIDATE_CATALOG_PATH="$WORK/catalog.yaml" \
    AGENT_FLOW_CONFIG="$WORK/nonexistent.yaml" SUBSCRIPTIONS_FILE="" \
    AGENT_DIR="" AGENT_FLOW_APPROVED_HOME="" AGENT_FLOW_APPROVED_PATH="" \
    AGENT_ROUTER_URL="https://router.invalid" AGENT_ROUTER_TOKEN=t \
    AGENT_FLOW_LAUNCH_TIMEOUT=20 CLAUDE_CONFIG_DIR="/somewhere/else" \
    bash "$DISPATCH" s-vendor.md 1 >/dev/null 2>"$WORK/err"; echo $? )"
assert_eq "non-default CLAUDE_CONFIG_DIR -> fails closed" "$out_rc" "2"
assert_contains "CLAUDE_CONFIG_DIR: named as unsupported" "$(cat "$WORK/err")" "unsupported"

# ===========================================================================
head1 "3b. Launch-contract capability guard — fail-closed, reaches no runner"
# ===========================================================================
# The router's catalog approves {claude, local-code-standard} and /v1/route
# really does recommend it, but HARNESS-LAUNCH-claude.md §7 forbids every
# redirection that could point Claude Code at local compute. Routable and
# unlaunchable at once. The adapter must stop, loudly and distinctly, and must
# never retarget the attempt to a harness it CAN launch.

assert_guard_refuses() { # <harness> <profile>
  local h="$1" prof="$2" story="s-guard-$1.md" marker rc
  : > "$STUB_STATE/terminal-creates"
  : > "$STUB_STATE/curl-calls"
  rm -f "$STUB_STATE/last-command.txt" "$WT/$story.result.json" "$WT/$story.blocked"
  write_story "$WT/$story" "persona: dev
gates: [\"true\"]"
  write_stamp "$WT/$story.stamp.json" high true "$prof" "$h"
  rc="$(run_dispatch "$story")"

  assert_eq "guard[$h]: exit 7 — distinct from 1/2/3/4/5/6" "$rc" "7"

  marker="$(cat "$WT/$story.blocked" 2>/dev/null || true)"
  assert_contains "guard[$h]: marker is distinctly typed" "$marker" "UNSUPPORTED-LAUNCH-CONTRACT:"
  assert_contains "guard[$h]: marker names the harness"   "$marker" "harness=$h"
  assert_contains "guard[$h]: marker names the profile"   "$marker" "model_profile=$prof"
  assert_contains "guard[$h]: marker names the reason"    "$marker" "placement_required=true"
  assert_contains "guard[$h]: marker says the stamp was VALID" "$marker" "The stamp is VALID"
  assert_contains "guard[$h]: marker says route NOT modified"  "$marker" "route was NOT modified"
  assert_contains "guard[$h]: marker tells the human what to do" "$marker" "re-route"

  # Nothing was launched, and nothing was even BUILT.
  assert_empty_file "guard[$h]: no Orca terminal created"   "$STUB_STATE/terminal-creates"
  assert_no_file    "guard[$h]: no harness command built"   "$STUB_STATE/last-command.txt"
  assert_no_file    "guard[$h]: no result artifact"         "$WT/$story.result.json"

  # It fires AFTER the authorities have spoken, not instead of them.
  assert_contains "guard[$h]: fires after /v1/place ran" \
    "$(cat "$STUB_STATE/curl-calls")" "/v1/place"
  assert_contains "guard[$h]: fires after stamp validation" \
    "$(cat "$STUB_STATE/validator-argv.txt")" "--evidence"

  # The route is never mutated: the stamp on disk is byte-for-byte what it was.
  assert_eq "guard[$h]: stamp harness untouched" \
    "$(jq -r .harness "$WT/$story.stamp.json")" "$h"
  assert_eq "guard[$h]: stamp model_profile untouched" \
    "$(jq -r .model_profile "$WT/$story.stamp.json")" "$prof"
  assert_absent "guard[$h]: no substitute harness suggested in stderr" \
    "$(cat "$WORK/err")" "falling back"
}

assert_guard_refuses claude local-code-standard
assert_guard_refuses codex  local-code-standard

# The second instance of the class: {claude, minimax/strong, minimax-max} is a
# CLEAN stamp — vendor-hosted, placement_required=false, no override — that the
# old placement-keyed guard waved through to `claude --model m3` against
# Anthropic on anthropic-max while the stamp recorded minimax. Stamp-derived
# native reachability must refuse it before any command text exists, naming the
# actual mismatch.
: > "$STUB_STATE/terminal-creates"
rm -f "$STUB_STATE/last-command.txt" "$WT/s-guard-minimax.md.result.json" \
      "$WT/s-guard-minimax.md.blocked"
write_story "$WT/s-guard-minimax.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/s-guard-minimax.md.stamp.json" high false "minimax/strong" claude minimax-max
rc="$(run_dispatch s-guard-minimax.md)"
assert_eq "guard[minimax]: {claude, minimax/strong, minimax-max} -> exit 7" "$rc" "7"
mm_marker="$(cat "$WT/s-guard-minimax.md.blocked" 2>/dev/null || true)"
assert_contains "guard[minimax]: marker is distinctly typed" "$mm_marker" "UNSUPPORTED-LAUNCH-CONTRACT:"
assert_contains "guard[minimax]: marker names the profile-family mismatch" \
  "$mm_marker" "model_profile 'minimax/strong' is outside the native family 'claude/*'"
assert_contains "guard[minimax]: marker names the pool mismatch" \
  "$mm_marker" "entitlement_pool 'minimax-max' is not the native pool 'anthropic-max'"
assert_contains "guard[minimax]: marker says the stamp was VALID" "$mm_marker" "The stamp is VALID"
assert_contains "guard[minimax]: marker says route NOT modified"  "$mm_marker" "route was NOT modified"
assert_empty_file "guard[minimax]: no Orca terminal created" "$STUB_STATE/terminal-creates"
assert_no_file    "guard[minimax]: no harness command built" "$STUB_STATE/last-command.txt"
assert_no_file    "guard[minimax]: no result artifact"       "$WT/s-guard-minimax.md.result.json"
assert_eq "guard[minimax]: stamp model_profile untouched" \
  "$(jq -r .model_profile "$WT/s-guard-minimax.md.stamp.json")" "minimax/strong"
assert_eq "guard[minimax]: stamp entitlement_pool untouched" \
  "$(jq -r .entitlement_pool "$WT/s-guard-minimax.md.stamp.json")" "minimax-max"

# The vendor pairs each harness DOES have a contract for still launch normally —
# the guard is a capability declaration, not a blanket refusal.
: > "$STUB_STATE/terminal-creates"
export STUB_TERMINAL_TAIL="ok
CLAUDE_EXIT=0"
write_story "$WT/s-guard-ok.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/s-guard-ok.md.stamp.json" high false "claude/strong" claude
rc="$(run_dispatch s-guard-ok.md)"
assert_eq "guard: vendor pair {claude, claude/strong} still launches" "$rc" "0"
assert_no_file "guard: vendor pair leaves no blocked marker" "$WT/s-guard-ok.md.blocked"

# ===========================================================================
head1 "4. make-stamp.sh — expires_at verbatim, override is provenance only"
# ===========================================================================

cat > "$WORK/route-response.json" <<'JSON'
{
  "harness": "claude",
  "model_profile": "claude/strong",
  "effort": "xhigh",
  "cost_class": "subscription",
  "entitlement_pool": "anthropic-max",
  "placement_policy": "prefer-warm-local",
  "placement_required": false,
  "fallbacks": [],
  "metered": false,
  "rationale": "high ambiguity, high blast radius",
  "catalog_version": "sha256:deadbeef",
  "expires_at": "2099-06-01T12:34:56Z"
}
JSON

STAMP_OUT="$WORK/made.stamp.json"
if bash "$MAKE_STAMP" --response "$WORK/route-response.json" \
     --story-id STORY-TEST-9 --title "A test" --tag docs --tag iac \
     --context-size 12000 --out "$STAMP_OUT" >/dev/null 2>&1; then
  ok "make-stamp writes a stamp from a route response"
  assert_eq "stamp: expires_at copied VERBATIM" \
    "$(jq -r .expires_at "$STAMP_OUT")" "2099-06-01T12:34:56Z"
  assert_eq "stamp: effort carried"        "$(jq -r .effort "$STAMP_OUT")" "xhigh"
  assert_eq "stamp: task.story_id"         "$(jq -r .task.story_id "$STAMP_OUT")" "STORY-TEST-9"
  assert_eq "stamp: task.tags carried"     "$(jq -c .task.tags "$STAMP_OUT")" '["docs","iac"]'
  assert_eq "stamp: context_size carried"  "$(jq -r .task.context_size "$STAMP_OUT")" "12000"
  assert_eq "stamp: override null when accepted" "$(jq -r .override "$STAMP_OUT")" "null"
  assert_eq "stamp: rationale NOT carried (not in the closed shape)" \
    "$(jq -r 'has("rationale")' "$STAMP_OUT")" "false"
  assert_eq "stamp: fallbacks NOT carried (no runtime fallback exists)" \
    "$(jq -r 'has("fallbacks")' "$STAMP_OUT")" "false"
  extra="$(jq -r '[keys[]] - ["harness","model_profile","effort","cost_class","entitlement_pool","metered","placement_policy","placement_required","catalog_version","catalog_document_version","expires_at","task","override","created_at"] | join(",")' "$STAMP_OUT")"
  assert_eq "stamp: property set stays CLOSED" "$extra" ""
else
  bad "make-stamp writes a stamp from a route response" "$(bash "$MAKE_STAMP" --response "$WORK/route-response.json" --story-id X --out "$STAMP_OUT" 2>&1 | tail -3)"
fi

# override records provenance and moves the FINAL fields
if bash "$MAKE_STAMP" --response "$WORK/route-response.json" --story-id STORY-TEST-9 \
     --override-harness codex --override-profile openai/strong \
     --override-actor josh --override-reason "cross-provider review" \
     --out "$WORK/ov.stamp.json" >/dev/null 2>&1; then
  assert_eq "override: final harness moved"    "$(jq -r .harness "$WORK/ov.stamp.json")" "codex"
  assert_eq "override: final profile moved"    "$(jq -r .model_profile "$WORK/ov.stamp.json")" "openai/strong"
  assert_eq "override: ORIGINAL recommendation preserved" \
    "$(jq -r .override.original.model_profile "$WORK/ov.stamp.json")" "claude/strong"
  assert_eq "override: actor recorded"         "$(jq -r .override.actor "$WORK/ov.stamp.json")" "josh"
  assert_eq "override: expires_at STILL verbatim (no fresh window)" \
    "$(jq -r .expires_at "$WORK/ov.stamp.json")" "2099-06-01T12:34:56Z"
else
  bad "make-stamp records an override"
fi

# an unexplained override is refused
if bash "$MAKE_STAMP" --response "$WORK/route-response.json" --story-id X \
     --override-harness codex --out "$WORK/bad.stamp.json" >/dev/null 2>&1; then
  bad "override without actor/reason is refused"
else
  ok "override without actor/reason is refused"
fi

# a metered/cost_class mismatch is refused
jq '.cost_class="metered"' "$WORK/route-response.json" > "$WORK/bad-response.json"
if bash "$MAKE_STAMP" --response "$WORK/bad-response.json" --story-id X \
     --out "$WORK/bad2.stamp.json" >/dev/null 2>&1; then
  bad "metered/cost_class dual-key mismatch is refused"
else
  ok "metered/cost_class dual-key mismatch is refused"
fi

# ---------------------------------------------------------------------------
# null-laundering: `jq -r .field` prints the STRING "null" for a missing or
# explicitly-null field, and that string then passes every downstream non-empty
# check as an ordinary value. A stamp whose task.story_id is the four-character
# string "null" is a stamp for nothing, and it would sail through validation:
# task.story_id is re-checked at dispatch, but only for being a non-empty
# string, which "null" is. Absent identity must fail CLOSED at creation.
# ---------------------------------------------------------------------------

# A stub router so the --request path can be exercised without the network. It
# always answers with the same known-good ExecutionProfile.
mkdir -p "$WORK/nullbin"
cat > "$WORK/nullbin/curl" <<'STUB'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [[ "$prev" == "-o" ]] && out="$a"; prev="$a"; done
if [[ -n "$out" ]]; then cat "$STUB_ROUTE_RESPONSE" > "$out"; fi
printf '200'
STUB
chmod +x "$WORK/nullbin/curl"

assert_story_id_refused() { # <case-name> <request-json>
  local case_name="$1" req_json="$2"
  local req="$WORK/nullreq.json" out="$WORK/null.stamp.json" err rc
  printf '%s' "$req_json" > "$req"
  rm -f "$out"
  # NOTE for future test authors: section 1 sources dispatch.sh, which carries
  # `set -euo pipefail`, so this shell runs under `set -e` from that point on.
  # A BARE assignment from a command that exits non-zero would kill the whole
  # suite silently. Capturing inside an `if` keeps it in condition context.
  if err="$( PATH="$WORK/nullbin:$PATH" \
             STUB_ROUTE_RESPONSE="$WORK/route-response.json" \
             AGENT_FLOW_CONFIG="$WORK/nonexistent.yaml" SUBSCRIPTIONS_FILE="" \
             AGENT_ROUTER_URL="https://router.invalid" AGENT_ROUTER_TOKEN=t \
             bash "$MAKE_STAMP" --request "$req" --out "$out" 2>&1 )"; then
    rc=0
  else
    rc=$?
  fi
  if (( rc == 0 )); then
    bad "story_id $case_name: refused" "make-stamp exited 0"
  else
    ok "story_id $case_name: refused"
  fi
  assert_no_file  "story_id $case_name: NO stamp file produced" "$out"
  assert_contains "story_id $case_name: error names story_id"   "$err" "story_id"
  assert_contains "story_id $case_name: error explains why"     "$err" "task identity"
}

assert_story_id_refused "omitted" \
  '{"title":"t","ambiguity":"low","blast_radius":"low","tags":["docs"]}'
assert_story_id_refused "explicitly null" \
  '{"story_id":null,"title":"t","ambiguity":"low","blast_radius":"low","tags":["docs"]}'
assert_story_id_refused "empty string" \
  '{"story_id":"","title":"t","ambiguity":"low","blast_radius":"low","tags":["docs"]}'

# The control: a well-formed request on the SAME path still succeeds, so the
# three refusals above are the guard firing and not the stub being broken.
printf '%s' '{"story_id":"STORY-OK-1","title":"t","ambiguity":"low","blast_radius":"low","tags":["docs"]}' \
  > "$WORK/goodreq.json"
rm -f "$WORK/good.stamp.json"
if PATH="$WORK/nullbin:$PATH" STUB_ROUTE_RESPONSE="$WORK/route-response.json" \
   AGENT_FLOW_CONFIG="$WORK/nonexistent.yaml" SUBSCRIPTIONS_FILE="" \
   AGENT_ROUTER_URL="https://router.invalid" AGENT_ROUTER_TOKEN=t \
   bash "$MAKE_STAMP" --request "$WORK/goodreq.json" --out "$WORK/good.stamp.json" >/dev/null 2>&1; then
  ok "story_id present: --request path still stamps"
  assert_eq "story_id present: carried verbatim" \
    "$(jq -r .task.story_id "$WORK/good.stamp.json")" "STORY-OK-1"
  assert_absent "no field was laundered into the string \"null\"" \
    "$(jq -c . "$WORK/good.stamp.json")" '"null"'
else
  bad "story_id present: --request path still stamps"
fi

# A null ELEMENT inside tags is the same hazard one level down: it must not be
# stamped as the literal tag "null" and checked against forbidden_for as one.
printf '%s' '{"story_id":"STORY-OK-2","title":"t","ambiguity":"low","blast_radius":"low","tags":["docs",null,"iac"]}' \
  > "$WORK/nulltag.json"
rm -f "$WORK/nulltag.stamp.json"
if PATH="$WORK/nullbin:$PATH" STUB_ROUTE_RESPONSE="$WORK/route-response.json" \
   AGENT_FLOW_CONFIG="$WORK/nonexistent.yaml" SUBSCRIPTIONS_FILE="" \
   AGENT_ROUTER_URL="https://router.invalid" AGENT_ROUTER_TOKEN=t \
   bash "$MAKE_STAMP" --request "$WORK/nulltag.json" --out "$WORK/nulltag.stamp.json" >/dev/null 2>&1; then
  assert_eq "null tag element dropped, real tags kept" \
    "$(jq -c .task.tags "$WORK/nulltag.stamp.json")" '["docs","iac"]'
else
  bad "null tag element dropped, real tags kept" "make-stamp refused a valid request"
fi

# The response side has the same hazard: has() is true for an explicitly-null
# field, so a null harness would reach jq -r and be stamped as "null".
for f in harness model_profile effort catalog_version expires_at; do
  jq --arg f "$f" '.[$f] = null' "$WORK/route-response.json" > "$WORK/nullfield.json"
  if bash "$MAKE_STAMP" --response "$WORK/nullfield.json" --story-id X \
       --out "$WORK/nullfield.stamp.json" >/dev/null 2>&1; then
    bad "null response field '$f' is refused"
  else
    ok "null response field '$f' is refused"
  fi
  assert_no_file "null response field '$f': no stamp produced" "$WORK/nullfield.stamp.json"
done

# entitlement_pool is the deliberate exception: null is a LEGITIMATE value there
# (local execution draws on no pool), so it must still stamp.
jq '.entitlement_pool = null' "$WORK/route-response.json" > "$WORK/nullpool.json"
rm -f "$WORK/nullpool.stamp.json"
if bash "$MAKE_STAMP" --response "$WORK/nullpool.json" --story-id X \
     --out "$WORK/nullpool.stamp.json" >/dev/null 2>&1; then
  ok "null entitlement_pool is ACCEPTED (local execution draws on no pool)"
  assert_eq "null entitlement_pool stays JSON null, not \"null\"" \
    "$(jq -r '.entitlement_pool | type' "$WORK/nullpool.stamp.json")" "null"
else
  bad "null entitlement_pool is ACCEPTED (local execution draws on no pool)"
fi

# ===========================================================================
head1 "5. Live control-plane chain (opt-in, read-only, launches nothing)"
# ===========================================================================
# Runs only when a real router, caller token, validator and catalog are all
# present. Everything above this line is offline and hermetic.
#
#   AGENT_ROUTER_URL=https://gateway.example.com \
#   AGENT_ROUTER_TOKEN=<caller token> \
#   AGENT_STAMP_VALIDATE=/path/to/agent-stamp-validate \
#   AGENT_STAMP_VALIDATE_CATALOG_PATH=/path/to/catalog.yaml \
#     tests/run-tests.sh

LIVE_VALIDATOR="${AGENT_STAMP_VALIDATE:-agent-stamp-validate}"
if [[ -n "${AGENT_ROUTER_URL:-}" && -n "${AGENT_ROUTER_TOKEN:-}" ]] \
   && command -v "$LIVE_VALIDATOR" >/dev/null \
   && [[ -n "${AGENT_STAMP_VALIDATE_CATALOG_PATH:-}" && -f "${AGENT_STAMP_VALIDATE_CATALOG_PATH}" ]]; then

  L="$WORK/live"; mkdir -p "$L"
  cat > "$L/req.json" <<'JSON'
{"story_id":"KIT-SELFTEST","title":"kit self-test route shape",
 "summary":"Read-only round trip proving the RouteRequest and ExecutionStamp shapes line up. No implementation.",
 "ambiguity":"low","blast_radius":"low","context_size":12000,
 "volume_hint":"low","tags":["docs"],"requester":"kit-selftest"}
JSON

  http="$(curl -sS -o "$L/resp.json" -w '%{http_code}' -X POST "${AGENT_ROUTER_URL%/}/v1/route" \
          -H "Authorization: Bearer $AGENT_ROUTER_TOKEN" -H 'Content-Type: application/json' \
          --max-time 30 -d @"$L/req.json" || true)"
  assert_eq "live: POST /v1/route -> 200" "$http" "200"

  if [[ "$http" == "200" ]]; then
    for f in harness model_profile effort cost_class placement_policy placement_required catalog_version expires_at; do
      assert_eq "live: route response carries $f" "$(jq -r "has(\"$f\")" "$L/resp.json")" "true"
    done

    if bash "$MAKE_STAMP" --response "$L/resp.json" --story-id KIT-SELFTEST \
         --tag docs --context-size 12000 --out "$L/stamp.json" >/dev/null 2>&1; then
      ok "live: make-stamp froze the decision"
      assert_eq "live: expires_at byte-identical to the decision" \
        "$(jq -r .expires_at "$L/stamp.json")" "$(jq -r .expires_at "$L/resp.json")"
      assert_eq "live: catalog_version carried" \
        "$(jq -r .catalog_version "$L/stamp.json")" "$(jq -r .catalog_version "$L/resp.json")"

      req="$(jq -r .placement_required "$L/stamp.json")"
      if [[ "$req" == "true" ]]; then
        # Placement REQUIRED: prove the ordering. Validating without evidence must
        # fail; the only way to a valid verdict is place-THEN-validate.
        rc=0; "$LIVE_VALIDATOR" --catalog "$AGENT_STAMP_VALIDATE_CATALOG_PATH" \
              --stamp "$L/stamp.json" > "$L/v1.json" 2>/dev/null || rc=$?
        assert_eq "live: validate WITHOUT evidence -> validator exit 1" "$rc" "1"
        assert_eq "live: the failing check is placement_evidence_missing" \
          "$(jq -r '.checks[]|select(.name=="placement")|.reason_code' "$L/v1.json")" \
          "placement_evidence_missing"
        assert_eq "live: dispatch would remap that to exit 4" "$(remap_validator_exit "$rc")" "4"

        resolved_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        phttp="$(curl -sS -o "$L/place.json" -w '%{http_code}' -X POST "${AGENT_ROUTER_URL%/}/v1/place" \
                 -H "Authorization: Bearer $AGENT_ROUTER_TOKEN" -H 'Content-Type: application/json' \
                 --max-time 25 -d "$(jq -nc --arg p "$(jq -r .model_profile "$L/stamp.json")" \
                      --arg pol "$(jq -r .placement_policy "$L/stamp.json")" \
                      '{model_profile:$p, placement_policy:$pol}')" || true)"
        assert_eq "live: POST /v1/place -> 200" "$phttp" "200"
        jq -n --arg t "$resolved_at" --slurpfile r "$L/place.json" \
           '{resolved_at:$t, result:$r[0]}' > "$L/evidence.json"

        if [[ "$(jq -r .status "$L/place.json")" == "placed" ]]; then
          rc=0; "$LIVE_VALIDATOR" --catalog "$AGENT_STAMP_VALIDATE_CATALOG_PATH" \
                --stamp "$L/stamp.json" --evidence "$L/evidence.json" > "$L/v2.json" 2>/dev/null || rc=$?
          assert_eq "live: place THEN validate -> validator exit 0" "$rc" "0"
          assert_eq "live: verdict valid"  "$(jq -r .valid "$L/v2.json")" "true"
          assert_eq "live: all 8 frozen checks evaluated" "$(jq -r '.checks|length' "$L/v2.json")" "8"
          assert_eq "live: placement placed_and_fresh" \
            "$(jq -r '.checks[]|select(.name=="placement")|.reason_code' "$L/v2.json")" "placed_and_fresh"
        else
          bad "live: /v1/place returned status=placed" "got $(jq -r .status "$L/place.json")"
        fi
      else
        # Vendor-hosted: evidence must be ABSENT; supplying it is itself a failure.
        rc=0; "$LIVE_VALIDATOR" --catalog "$AGENT_STAMP_VALIDATE_CATALOG_PATH" \
              --stamp "$L/stamp.json" > "$L/v1.json" 2>/dev/null || rc=$?
        assert_eq "live: vendor profile validates with no evidence" "$rc" "0"
      fi
    else
      bad "live: make-stamp froze the decision"
    fi
  fi
else
  printf '  \033[33mSKIP\033[0m live chain (set AGENT_ROUTER_URL/_TOKEN + validator + catalog)\n'
fi

# ===========================================================================
head1 "6. Lifecycle gate — tests/lifecycle-tests.sh"
# ===========================================================================
# The read-only lifecycle surface has its own isolated deterministic gate. It is
# aggregated here so one command answers "is the kit green", and it runs in its
# OWN process: this suite sourced dispatch.sh, which carries `set -euo pipefail`,
# and that must not leak into another suite's shell. On failure its output tail
# is surfaced rather than buried — including the case where it fails without
# reaching a single assertion.

LIFECYCLE_TESTS="$KIT_ROOT/tests/lifecycle-tests.sh"
if [[ -f "$LIFECYCLE_TESTS" ]]; then
  if lifecycle_out="$(bash "$LIFECYCLE_TESTS" 2>&1)"; then
    ok "lifecycle gate: $(tail -1 <<<"$lifecycle_out")"
  else
    bad "lifecycle gate" "$(tail -1 <<<"$lifecycle_out")"
    printf '%s\n' "$lifecycle_out" | tail -40
  fi
else
  bad "lifecycle gate present" "missing: $LIFECYCLE_TESTS"
fi

# ===========================================================================
head1 "7. Lifecycle mutation gate — tests/lifecycle-mutation-tests.sh"
# ===========================================================================
# The destructive half — plans, approvals, the adoption and update
# transactions, backups, rollback, interruption recovery and offline
# verification — runs entirely against throwaway HOMEs and throwaway checkouts
# under mktemp. It is aggregated here for the same reason and in the same way:
# its own process, its output tail surfaced on failure.

MUTATION_TESTS="$KIT_ROOT/tests/lifecycle-mutation-tests.sh"
if [[ -f "$MUTATION_TESTS" ]]; then
  if mutation_out="$(bash "$MUTATION_TESTS" 2>&1)"; then
    ok "lifecycle mutation gate: $(tail -1 <<<"$mutation_out")"
  else
    bad "lifecycle mutation gate" "$(tail -1 <<<"$mutation_out")"
    printf '%s\n' "$mutation_out" | tail -40
  fi
else
  bad "lifecycle mutation gate present" "missing: $MUTATION_TESTS"
fi

# ===========================================================================
head1 "8. Lifecycle concurrency gate — tests/lifecycle-concurrency-tests.sh"
# ===========================================================================
# The operation lock is the one part of the lifecycle whose contract cannot be
# falsified by a single process: "at most one owner" needs several. This gate
# puts real processes on one lock behind a barrier and drives the observation,
# reclamation and release boundaries deliberately. Aggregated the same way as
# the other two: its own process, its output tail surfaced on failure.

CONCURRENCY_TESTS="$KIT_ROOT/tests/lifecycle-concurrency-tests.sh"
if [[ -f "$CONCURRENCY_TESTS" ]]; then
  if concurrency_out="$(bash "$CONCURRENCY_TESTS" 2>&1)"; then
    ok "lifecycle concurrency gate: $(tail -1 <<<"$concurrency_out")"
  else
    bad "lifecycle concurrency gate" "$(tail -1 <<<"$concurrency_out")"
    printf '%s\n' "$concurrency_out" | tail -40
  fi
else
  bad "lifecycle concurrency gate present" "missing: $CONCURRENCY_TESTS"
fi

# ===========================================================================
head1 "9. Lifecycle readiness gate — tests/lifecycle-readiness-tests.sh"
# ===========================================================================
# Scoped execution readiness — host, new-work, per-target and per-route — plus
# the stubbed live surface: Orca capability, the validator contract and its
# anti-vacuity fixtures, native harness capability and auth class, router
# availability, and the orchestration bridge. Every live branch is reached
# against stubbed binaries, so this gate opens no socket and launches nothing.
# Aggregated the same way as the other three: its own process, its output tail
# surfaced on failure.

READINESS_TESTS="$KIT_ROOT/tests/lifecycle-readiness-tests.sh"
if [[ -f "$READINESS_TESTS" ]]; then
  if readiness_out="$(bash "$READINESS_TESTS" 2>&1)"; then
    ok "lifecycle readiness gate: $(tail -1 <<<"$readiness_out")"
  else
    bad "lifecycle readiness gate" "$(tail -1 <<<"$readiness_out")"
    printf '%s\n' "$readiness_out" | tail -40
  fi
else
  bad "lifecycle readiness gate present" "missing: $READINESS_TESTS"
fi

# ===========================================================================
head1 "10. Lifecycle dispatch gate — tests/lifecycle-dispatch-tests.sh"
# ===========================================================================
# The durable worker-completion watch and the provenance-bound release of the
# resources a settled worker owned: at-least-once delivery and its idempotence,
# monitoring faults that never become worker results, durable terminal closure
# proven across a reconnect, and cleanup that fails closed on everything it
# cannot prove it created. Real local Git repositories, a stubbed Orca, no
# network. Aggregated the same way as the other four.

DISPATCH_TESTS="$KIT_ROOT/tests/lifecycle-dispatch-tests.sh"
if [[ -f "$DISPATCH_TESTS" ]]; then
  if dispatch_out="$(bash "$DISPATCH_TESTS" 2>&1)"; then
    ok "lifecycle dispatch gate: $(tail -1 <<<"$dispatch_out")"
  else
    bad "lifecycle dispatch gate" "$(tail -1 <<<"$dispatch_out")"
    printf '%s\n' "$dispatch_out" | tail -40
  fi
else
  bad "lifecycle dispatch gate present" "missing: $DISPATCH_TESTS"
fi

# ===========================================================================
if (( SKIPPED > 0 )); then
  printf '\n\033[1m%d passed, %d failed, %d skipped\033[0m\n' "$PASS" "$FAIL" "$SKIPPED"
  printf '\033[33mskipped checks computed no verdict — they are not passes\033[0m\n'
else
  printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
fi
(( FAIL == 0 )) || exit 1
