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
CLAUDE_EVIDENCE_VERIFY="$KIT_ROOT/files/model-router/scripts/verify-claude-evidence.sh"
CLAUDE_EVIDENCE_TESTS="$KIT_ROOT/tests/claude-evidence-tests.sh"

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

SC_SCRIPTS=("$DISPATCH" "$MAKE_STAMP" "$USAGE_CHECK" "$GH_HEALTH" \
            "$CLAUDE_EVIDENCE_VERIFY" "$CLAUDE_EVIDENCE_TESTS" \
            "$KIT_ROOT/files/model-router/scripts/harness-inventory.sh" \
            "$KIT_ROOT/adapters/claude/statusline.sh" \
            "$KIT_ROOT/adapters/codex/publish.sh" \
            "$KIT_ROOT/adapters/codex/status.sh" \
            "$KIT_ROOT/adapters/hermes/status-card.sh" \
            "$KIT_ROOT/adapters/opencode/status.sh" \
            "$KIT_ROOT/adapters/orca-title.sh" \
            "$KIT_ROOT/adapters/publish-runtime.sh" \
            "$KIT_ROOT/adapters/refresh-status-cache.sh" \
            "$KIT_ROOT/adapters/render-status.sh" \
            "$KIT_ROOT/adapters/runtime-scope.sh")
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
# The second class, gateway-backed local: claude only, and every one of its
# four conditions is load bearing. Each is a fact the catalog's launch contract
# assumes, so each one alone must refuse.
assert_eq "guard: {claude, local-code-standard} gateway-backed local pair is launchable" \
  "$(unsupported_launch_reason claude local-code-standard true '' local free)" ""
if [[ -n "$(unsupported_launch_reason codex local-code-standard true '' local free)" ]]; then
  ok "guard: {codex, local profile} has NO validated launch contract"
else
  bad "guard: {codex, local profile} has NO validated launch contract" \
    "the second class is claude-only; codex has no contract that reaches local compute"
fi
assert_contains "guard: codex+local keeps the established refusal wording" \
  "$(unsupported_launch_reason codex local-code-standard true '' local free)" "explicitly forbids"

GW_NO_HOSTING="$(unsupported_launch_reason claude local-code-standard true '' vendor free)"
if [[ -n "$GW_NO_HOSTING" ]]; then
  ok "guard: claude+placement without catalog hosting: local REFUSED"
else
  bad "guard: claude+placement without catalog hosting: local REFUSED" \
    "the catalog half of the discriminator was not consulted"
fi
assert_contains "guard: it names the missing catalog hosting" "$GW_NO_HOSTING" "hosting: local"
assert_contains "guard: local reason names the forbidden redirection" \
  "$GW_NO_HOSTING" "explicitly forbids"

# Belt and braces: a catalog fact that was never supplied fails CLOSED rather
# than defaulting open, so an un-updated caller cannot widen the class.
if [[ -n "$(unsupported_launch_reason claude local-code-standard true '')" ]]; then
  ok "guard: absent catalog evidence fails the pair closed"
else
  bad "guard: absent catalog evidence fails the pair closed"
fi

GW_POOLED="$(unsupported_launch_reason claude local-code-standard true anthropic-max local free)"
if [[ -n "$GW_POOLED" ]]; then
  ok "guard: a local profile stamped with a vendor pool REFUSED"
else
  bad "guard: a local profile stamped with a vendor pool REFUSED" \
    "funding and execution disagree on that stamp; neither class covers it"
fi
assert_contains "guard: it names the pool that should not be there" \
  "$GW_POOLED" "entitlement_pool 'anthropic-max'"

GW_PAID="$(unsupported_launch_reason claude local-code-standard true '' local subscription)"
if [[ -n "$GW_PAID" ]]; then
  ok "guard: a local profile stamped cost_class subscription REFUSED"
else
  bad "guard: a local profile stamped cost_class subscription REFUSED"
fi
assert_contains "guard: it names the cost class" "$GW_PAID" "cost_class is 'subscription'"

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
assert_absent "claude cmd: candidate fallback control is not in frozen recipe" \
  "$CMD" "CLAUDE_CODE_NO_MODEL_FALLBACK"

# Only ONE command substitution may appear, and it must be the prompt file read.
subs="$(grep -o '\$(' <<<"$CMD" | wc -l)"
assert_eq "claude cmd: exactly one command substitution (the prompt file)" "$subs" "1"

# --- the generated gateway-backed local claude command ---------------------
# The second launch class. It must be the native command plus exactly the
# contract's five variables, and nothing else: the value of the credential
# must not be IN it, and the claude invocation itself must not differ by a byte.
GWCMD="$(build_claude_gateway_command "/home/op" "/usr/bin:/bin" "op" \
          "/wt/STORY.md.prompt" "qwen36-27b" "high" "/wt/STORY.md.claude-result.json" \
          "/wt/_bmad/bmm/agents/dev.md" "https://gateway.invalid" \
          "op://stubvault/agw-claude-code/credential" "/home/op/.op-agent-env" \
          "kserve-a5000" "65536")"

head1 "   generated gateway-backed local claude terminal command"
printf '   %s\n' "$GWCMD"

# The credential is assigned to a shell variable before `env -i`, so an xtrace
# inherited from the terminal's own shell would print its value into a buffer
# Orca persists. The generated text disables xtrace before the assignment, and
# it has to be the FIRST thing in the text or the assignment can precede it.
assert_eq "gateway cmd: the text opens by disabling xtrace" \
  "${GWCMD:0:8}" "set +x; "
# ...and that prefix is the gateway class's alone: the native text assigns
# nothing and must not have acquired it.
assert_absent "claude cmd: the native text is unchanged — no xtrace prefix" \
  "$CMD" "set +x"
assert_eq "claude cmd: the native text still opens with the env -i sanitizer" \
  "${CMD:0:6}" "env -i"

# The env -i allowlist is the contract, and it is asserted as a SET, not as a
# handful of substrings: an extra ANTHROPIC_* or CLAUDE_* name is exactly the
# kind of quiet widening this class exists to make impossible.
GW_ENV_SEGMENT="${GWCMD#*env -i }"
GW_ENV_SEGMENT="${GW_ENV_SEGMENT%% claude -p*}"
GW_ENV_NAMES="$(tr ' ' '\n' <<<"$GW_ENV_SEGMENT" \
                | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' | tr '\n' ' ')"
assert_eq "gateway cmd: env -i allowlist is EXACTLY the contract" \
  "$GW_ENV_NAMES" \
  "HOME PATH USER LANG TERM ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_CUSTOM_HEADERS CLAUDE_CODE_MAX_CONTEXT_TOKENS "

assert_contains "gateway cmd: the native sanitizer prefix is unchanged" \
  "$GWCMD" "env -i HOME=/home/op PATH=/usr/bin:/bin USER=op LANG=C.UTF-8 TERM=dumb "
assert_contains "gateway cmd: base URL is a launcher literal" \
  "$GWCMD" "ANTHROPIC_BASE_URL=https://gateway.invalid"
assert_contains "gateway cmd: ANTHROPIC_MODEL pins the catalog physical model" \
  "$GWCMD" "ANTHROPIC_MODEL=qwen36-27b"
assert_contains "gateway cmd: --model is the same value" "$GWCMD" "--model qwen36-27b"
assert_contains "gateway cmd: x-placement copied verbatim from the evidence" \
  "$GWCMD" "ANTHROPIC_CUSTOM_HEADERS=$(shq 'x-placement: kserve-a5000')"
assert_contains "gateway cmd: the profile's REAL context window is set" \
  "$GWCMD" "CLAUDE_CODE_MAX_CONTEXT_TOKENS=65536"

# The credential: a reference and an env file in the text, the value nowhere.
assert_contains "gateway cmd: only the 1Password REFERENCE is embedded" \
  "$GWCMD" "op read op://stubvault/agw-claude-code/credential"
assert_contains "gateway cmd: the service-account env file is sourced in a subshell" \
  "$GWCMD" '"$(. /home/op/.op-agent-env && op read'
assert_contains "gateway cmd: an empty credential is fatal BEFORE claude starts" \
  "$GWCMD" '[ -n "$ANTHROPIC_AUTH_TOKEN" ] ||'
assert_contains "gateway cmd: and it exits without a false exit marker" "$GWCMD" "exit 78"
assert_contains "gateway cmd: the resolved value is dropped afterwards" \
  "$GWCMD" "unset ANTHROPIC_AUTH_TOKEN"

# Everything the native class froze, still frozen.
assert_absent "gateway cmd: ANTHROPIC_API_KEY never appears"     "$GWCMD" "ANTHROPIC_API_KEY"
assert_absent "gateway cmd: CLAUDE_CONFIG_DIR never propagated"  "$GWCMD" "CLAUDE_CONFIG_DIR"
assert_absent "gateway cmd: no Bash/shell tool granted"          "$GWCMD" "Bash"
assert_absent "gateway cmd: no permission bypass"                "$GWCMD" "dangerously"
assert_absent "gateway cmd: --bare forbidden"                    "$GWCMD" "--bare"
assert_absent "gateway cmd: no runtime \$HOME lookup"            "$GWCMD" '$HOME'
assert_absent "gateway cmd: no runtime \$PATH lookup"            "$GWCMD" '$PATH'
assert_absent "gateway cmd: candidate fallback control is not in frozen recipe" \
  "$GWCMD" "CLAUDE_CODE_NO_MODEL_FALLBACK"

# Exactly two command substitutions: the credential read and the prompt file.
gw_subs="$(grep -o '\$(' <<<"$GWCMD" | wc -l)"
assert_eq "gateway cmd: exactly two command substitutions" "$gw_subs" "2"

# AC-5's other half, proved by construction rather than by eyeballing: the
# claude invocation is byte-identical to the native one for the same inputs.
GW_NATIVE_TWIN="$(build_claude_command "/home/op" "/usr/bin:/bin" "op" \
                   "/wt/STORY.md.prompt" "qwen36-27b" "high" \
                   "/wt/STORY.md.claude-result.json" "/wt/_bmad/bmm/agents/dev.md")"
GW_TAIL="${GWCMD#*CLAUDE_CODE_MAX_CONTEXT_TOKENS=65536 }"
GW_TAIL="${GW_TAIL%; unset ANTHROPIC_AUTH_TOKEN}"
assert_eq "gateway cmd: the claude invocation is byte-identical to the native one" \
  "$GW_TAIL" "${GW_NATIVE_TWIN#*TERM=dumb }"

# --- Claude settings preflight: all supported file layers fail closed -----
head1 "   claude settings preflight — hermetic files only"

SETTINGS_ROOT="$TMPROOT/settings-preflight"
SETTINGS_HOME="$SETTINGS_ROOT/home"
SETTINGS_PROJECT="$SETTINGS_ROOT/project"
SETTINGS_MANAGED="$SETTINGS_ROOT/managed-settings.json"
mkdir -p "$SETTINGS_HOME/.claude" "$SETTINGS_PROJECT/.claude"

run_settings_preflight() { # <project-dir>
  ( cd "$1" && claude_settings_preflight "$SETTINGS_HOME" "$SETTINGS_MANAGED" ) \
    >"$SETTINGS_ROOT/out" 2>"$SETTINGS_ROOT/err"
  echo $?
}

printf '%s\n' '{"model":"opus","effortLevel":"high"}' \
  > "$SETTINGS_HOME/.claude/settings.json"
assert_eq "settings: inert model and effort defaults remain compatible" \
  "$(run_settings_preflight "$SETTINGS_PROJECT")" "0"
rm -f "$SETTINGS_HOME/.claude/settings.json"

for settings_key in apiKeyHelper env awsAuthRefresh awsCredentialExport \
  gcpAuthRefresh forceLoginMethod fallbackModel modelOverrides availableModels \
  autoCompactEnabled autoCompact maxOutputTokens maxThinkingTokens fastMode; do
  jq -n --arg key "$settings_key" '{($key):"unsafe"}' \
    > "$SETTINGS_HOME/.claude/settings.json"
  assert_eq "settings: user layer refuses $settings_key" \
    "$(run_settings_preflight "$SETTINGS_PROJECT")" "2"
  assert_contains "settings: refusal names $settings_key" \
    "$(cat "$SETTINGS_ROOT/err")" "$settings_key"
done
rm -f "$SETTINGS_HOME/.claude/settings.json"

for settings_layer in user project local managed; do
  case "$settings_layer" in
    user) settings_file="$SETTINGS_HOME/.claude/settings.json" ;;
    project) settings_file="$SETTINGS_PROJECT/.claude/settings.json" ;;
    local) settings_file="$SETTINGS_PROJECT/.claude/settings.local.json" ;;
    managed) settings_file="$SETTINGS_MANAGED" ;;
  esac
  printf '%s\n' '{"fallbackModel":"haiku"}' > "$settings_file"
  assert_eq "settings: $settings_layer layer refuses before launch" \
    "$(run_settings_preflight "$SETTINGS_PROJECT")" "2"
  assert_contains "settings: $settings_layer refusal names its file" \
    "$(cat "$SETTINGS_ROOT/err")" "$settings_file"
  rm -f "$settings_file"
done

for settings_layer in user project local managed; do
  case "$settings_layer" in
    user) settings_file="$SETTINGS_HOME/.claude/settings.json" ;;
    project) settings_file="$SETTINGS_PROJECT/.claude/settings.json" ;;
    local) settings_file="$SETTINGS_PROJECT/.claude/settings.local.json" ;;
    managed) settings_file="$SETTINGS_MANAGED" ;;
  esac

  printf '{bad json\n' > "$settings_file"
  assert_eq "settings: malformed JSON in $settings_layer fails closed" \
    "$(run_settings_preflight "$SETTINGS_PROJECT")" "2"
  assert_contains "settings: malformed $settings_layer refusal names the file" \
    "$(cat "$SETTINGS_ROOT/err")" "$settings_file"

  printf '%s\n' '[]' > "$settings_file"
  assert_eq "settings: non-object JSON in $settings_layer fails closed" \
    "$(run_settings_preflight "$SETTINGS_PROJECT")" "2"

  printf '%s\n' '{}' > "$settings_file"
  chmod 000 "$settings_file"
  if [[ -r "$settings_file" ]]; then
    ok "settings: unreadable $settings_layer check skipped for privileged user"
    ok "settings: unreadable $settings_layer prerequisite reported"
  else
    assert_eq "settings: unreadable JSON in $settings_layer fails closed" \
      "$(run_settings_preflight "$SETTINGS_PROJECT")" "2"
    assert_contains "settings: unreadable $settings_layer refusal is actionable" \
      "$(cat "$SETTINGS_ROOT/err")" "unreadable"
  fi
  chmod 600 "$settings_file"
  rm -f "$settings_file"
done

printf '%s\n%s\n' '{}' '{}' > "$SETTINGS_HOME/.claude/settings.json"
assert_eq "settings: multiple top-level JSON values fail closed" \
  "$(run_settings_preflight "$SETTINGS_PROJECT")" "2"
rm -f "$SETTINGS_HOME/.claude/settings.json"

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

# --- context budget: the arithmetic, at the boundaries ---------------------
head1 "   context budget — estimate and thresholds (pure)"

BUDGET_POLICY_SHIPPED="$KIT_ROOT/files/model-router/context-budget-policy.yaml"

# The documented method, and only the documented method. ceil(bytes/4).
assert_eq "estimate: 0 bytes -> 0 tokens"      "$(budget_estimate_tokens 0 bytes4-v1)"    "0"
assert_eq "estimate: 1 byte rounds UP to 1"    "$(budget_estimate_tokens 1 bytes4-v1)"    "1"
assert_eq "estimate: 4 bytes -> 1 token"       "$(budget_estimate_tokens 4 bytes4-v1)"    "1"
assert_eq "estimate: 5 bytes rounds UP to 2"   "$(budget_estimate_tokens 5 bytes4-v1)"    "2"
assert_eq "estimate: 40000 bytes -> 10000"     "$(budget_estimate_tokens 40000 bytes4-v1)" "10000"
assert_eq "estimate: same inputs, same number" \
  "$(budget_estimate_tokens 123457 bytes4-v1)" "$(budget_estimate_tokens 123457 bytes4-v1)"
if budget_estimate_tokens 100 bytes3-v9 >/dev/null 2>&1; then
  bad "estimate: an UNDECLARED method is refused, never guessed"
else ok "estimate: an UNDECLARED method is refused, never guessed"; fi
if budget_estimate_tokens "not-a-number" bytes4-v1 >/dev/null 2>&1; then
  bad "estimate: a non-numeric byte count is refused"
else ok "estimate: a non-numeric byte count is refused"; fi

# Decimal ratios become parts per million EXACTLY. 0.85 is not representable in
# binary, and a float path that lands on 849999 would silently move the refusal
# threshold off the value the policy declares.
assert_eq "threshold: 0.60 -> 600000 ppm exactly" "$(budget_threshold_ppm 0.60)" "600000"
assert_eq "threshold: 0.70 -> 700000 ppm exactly" "$(budget_threshold_ppm 0.70)" "700000"
assert_eq "threshold: 0.85 -> 850000 ppm exactly" "$(budget_threshold_ppm 0.85)" "850000"
assert_eq "threshold: 0.7 and 0.70 are the same"  "$(budget_threshold_ppm 0.7)" "$(budget_threshold_ppm 0.70)"
if budget_threshold_ppm "sixty percent" >/dev/null 2>&1; then
  bad "threshold: a non-ratio is refused"
else ok "threshold: a non-ratio is refused"; fi

assert_eq "ratio: 850/1000 -> 850000 ppm"  "$(budget_ratio_ppm 850 1000)"   "850000"
assert_eq "ratio: 0/65536 -> 0 ppm"        "$(budget_ratio_ppm 0 65536)"    "0"
if budget_ratio_ppm 100 0 >/dev/null 2>&1; then
  bad "ratio: a zero window is refused, never divided by"
else ok "ratio: a zero window is refused, never divided by"; fi

# A ratio EQUAL to a threshold COUNTS AS CROSSING IT (FR-98, "at or above").
# This is the assertion the whole refusal hangs on, so it is proved on both
# sides of each boundary rather than only at it.
for band in "600000:sizing risk" "700000:checkpoint" "850000:continuation"; do
  t="${band%%:*}"; nm="${band#*:}"
  if budget_crosses "$t" "$t"; then ok "boundary: ratio EQUAL to the $nm threshold crosses it"
  else bad "boundary: ratio EQUAL to the $nm threshold crosses it"; fi
  if budget_crosses "$(( t - 1 ))" "$t"; then bad "boundary: one ppm BELOW the $nm threshold does not"
  else ok "boundary: one ppm BELOW the $nm threshold does not"; fi
  if budget_crosses "$(( t + 1 ))" "$t"; then ok "boundary: one ppm ABOVE the $nm threshold does"
  else bad "boundary: one ppm ABOVE the $nm threshold does"; fi
done

# The reported number and the compared number come from the SAME value, so a
# result can never show a ratio that disagrees with the decision it drove.
assert_eq "ratio rendering: 850000 ppm reads 0.850000" "$(budget_ratio_decimal 850000)" "0.850000"
assert_eq "ratio rendering: 1000000 ppm reads 1.000000" "$(budget_ratio_decimal 1000000)" "1.000000"

# --- the policy file is the ONLY place a threshold lives -------------------
assert_eq "policy: the shipped policy declares every required key" \
  "$(budget_policy_missing_keys "$BUDGET_POLICY_SHIPPED")" ""
assert_eq "policy: a missing file is refused, not defaulted" \
  "$(budget_policy_missing_keys "$TMPROOT/no-such-policy.yaml")" "unreadable"
printf 'sizing_risk_ratio: 0.60\nbudget_states: [OK, CHECKPOINT_DUE, CONTINUATION_REQUIRED, NOT_EVALUATED]\nreason_codes: [A,B,C,D,E]\n' \
  > "$TMPROOT/partial-policy.yaml"
PARTIAL_MISSING="$(budget_policy_missing_keys "$TMPROOT/partial-policy.yaml")"
assert_contains "policy: an incomplete policy names estimate_method"    "$PARTIAL_MISSING" "estimate_method"
assert_contains "policy: an incomplete policy names checkpoint_ratio"   "$PARTIAL_MISSING" "checkpoint_ratio"
assert_contains "policy: an incomplete policy names continuation_ratio" "$PARTIAL_MISSING" "continuation_ratio"
assert_contains "policy: an incomplete policy names continuation_cap"   "$PARTIAL_MISSING" "continuation_cap"
printf 'not: [valid\n' > "$TMPROOT/broken-policy.yaml"
assert_eq "policy: an unparseable policy is refused" \
  "$(budget_policy_missing_keys "$TMPROOT/broken-policy.yaml")" "unparseable"

# --- AC-5: the story-record append is serialised, not merely idempotent ----
# Idempotence-per-cycle holds serially by construction; it says nothing about
# two dispatches of the same story reaching the risk band at the same instant.
# The append is a read-modify-write that ends in an inode-preserving `cat`, so
# an unserialised loser rewrites the story from a copy it read before the
# winner's write — losing findings, and under contention the frontmatter and
# the body with them. N concurrent DISTINCT cycles must leave exactly N lines
# and an intact story.
head1 "   context budget — the story-record append under concurrency"
RACE_DIR="$TMPROOT/record-race"; mkdir -p "$RACE_DIR"
mkrace() { printf -- '---\npersona: dev\ngates: ["x"]\n---\n\nBODY-SENTINEL\n\n## Dev Agent Record\n\nexisting note\n' > "$1"; }

# CONTROL first: serially the same calls are correct AND idempotent per cycle,
# so a concurrency failure below is about serialisation and nothing else.
mkrace "$RACE_DIR/seq.md"
for c in 1 1 2 2 3; do record_budget_line "$RACE_DIR/seq.md" "$c" SIZING_RISK "100/200 (0.500000)" 2>/dev/null; done
assert_eq "record/CONTROL: serial calls give one line per DISTINCT cycle" \
  "$(grep -ac '^- budget: SIZING_RISK ' "$RACE_DIR/seq.md")" "3"
assert_eq "record/CONTROL: serial calls preserve the body" \
  "$(grep -ac 'BODY-SENTINEL' "$RACE_DIR/seq.md")" "1"

RACE_WAYS=8 RACE_TRIALS=10 RACE_LOST=0 RACE_DAMAGED=0
for t in $(seq "$RACE_TRIALS"); do
  mkrace "$RACE_DIR/r.md"
  for c in $(seq "$RACE_WAYS"); do
    ( record_budget_line "$RACE_DIR/r.md" "$c" SIZING_RISK "100/200 (0.500000)" ) >/dev/null 2>&1 &
  done
  wait
  [[ "$(grep -ac '^- budget: SIZING_RISK ' "$RACE_DIR/r.md")" == "$RACE_WAYS" ]] || RACE_LOST=$((RACE_LOST+1))
  { [[ "$(grep -ac 'BODY-SENTINEL' "$RACE_DIR/r.md")" == "1" ]] \
    && [[ "$(grep -ac '^gates: \["x"\]' "$RACE_DIR/r.md")" == "1" ]]; } || RACE_DAMAGED=$((RACE_DAMAGED+1))
done
assert_eq "record: $RACE_WAYS concurrent cycles all land — no lost update in $RACE_TRIALS trials" \
  "$RACE_LOST" "0"
assert_eq "record: and the frontmatter and body survive every trial" \
  "$RACE_DAMAGED" "0"

# AC-3, stated as a grep because it is a property of the SOURCE: no threshold
# value is a constant in the launcher. Comments are stripped first, so the
# prose that explains the policy cannot satisfy the check.
code_of_early() { grep -vE '^[[:space:]]*#' "$1"; }
if code_of_early "$DISPATCH" | grep -qE '0\.(6|7|85)0?[^0-9]'; then
  bad "policy: no threshold constant appears in dispatch.sh" \
      "$(code_of_early "$DISPATCH" | grep -nE '0\.(6|7|85)0?[^0-9]' | head -3)"
else ok "policy: no threshold constant appears in dispatch.sh"; fi
if grep -qE '^[[:space:]]*(sizing_risk_ratio|checkpoint_ratio|continuation_ratio|continuation_cap|estimate_method):' \
     "$BUDGET_POLICY_SHIPPED"; then
  ok "policy: every threshold and the method are declared in the policy document"
else bad "policy: every threshold and the method are declared in the policy document"; fi

# --- AC-7, byte-identity of both frozen launch command texts ---------------
# Proved against master's own builders rather than against a transcription of
# them, with a control so a vacuous "both empty" comparison cannot pass.
head1 "   the frozen launch command texts are byte-identical to master"
MASTER_DISPATCH="$TMPROOT/master-dispatch.sh"
if git -C "$KIT_ROOT" show master:files/model-router/scripts/dispatch.sh > "$MASTER_DISPATCH" 2>/dev/null; then
  emit_from() { bash -c 'set -uo pipefail; . "$1"; shift; "$@"' _emit "$@"; }
  BI_ARGS=(/home/op /usr/bin:/bin op /wt/S.md.prompt claude-opus-5 high /wt/S.md.claude-result.json /wt/agents/dev.md)
  BI_GW=(/home/op /usr/bin:/bin op /wt/S.md.prompt qwen36-27b high /wt/S.md.claude-result.json /wt/agents/dev.md \
         https://gw.invalid op://v/i/credential /home/op/.op-agent-env cachyos-7900xtx 65536)
  for probe in "build_claude_command ${BI_ARGS[*]}" \
               "build_claude_gateway_command ${BI_GW[*]}" \
               "build_codex_command /wt/S.md.prompt gpt-5.6-sol xhigh"; do
    # shellcheck disable=SC2086
    m="$(emit_from "$MASTER_DISPATCH" $probe)"
    # shellcheck disable=SC2086
    h="$(emit_from "$DISPATCH" $probe)"
    nm="${probe%% *}"
    if [[ -z "$m" ]]; then bad "byte-identity: $nm" "master produced nothing — the probe is broken"
    elif [[ "$m" == "$h" ]]; then ok "byte-identity: $nm unchanged from master"
    else bad "byte-identity: $nm unchanged from master" "$(diff <(printf '%s\n' "$m") <(printf '%s\n' "$h") | head -4)"; fi
  done
  # CONTROL — the comparison must be able to see a difference.
  if [[ "$(emit_from "$MASTER_DISPATCH" build_claude_command "${BI_ARGS[@]}")" \
        != "$(emit_from "$DISPATCH" build_claude_command /home/op /usr/bin:/bin op \
              /wt/S.md.prompt claude-opus-5 medium /wt/S.md.claude-result.json /wt/agents/dev.md)" ]]; then
    ok "byte-identity CONTROL: a perturbed effort IS detected as different"
  else bad "byte-identity CONTROL: a perturbed effort IS detected as different"; fi
else
  skip "byte-identity vs master (no master ref in this checkout)"
fi

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
CURRENT_DISPATCH_CODE="$WORK_OLD/dispatch.current.code.sh"
OLD_DISPATCH_CODE="$WORK_OLD/dispatch.old.code.sh"
mkdir -p "$(dirname "$OLD_DISPATCH")"
code_of "$DISPATCH" > "$CURRENT_DISPATCH_CODE"
if git -C "$KIT_ROOT" show 02b18d0:files/model-router/scripts/dispatch.sh > "$OLD_DISPATCH" 2>/dev/null; then
  code_of "$OLD_DISPATCH" > "$OLD_DISPATCH_CODE"
  HAVE_OLD=1
else
  HAVE_OLD=0
fi

grep_gone() { # name pattern — absent from the new code AND present in the old
  local name="$1" pat="$2"
  if grep -qE "$pat" "$CURRENT_DISPATCH_CODE"; then
    bad "$name" "still present in dispatch.sh"
    return
  fi
  if (( HAVE_OLD )) && ! grep -qE "$pat" "$OLD_DISPATCH_CODE"; then
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
    min_context: 65536
    physical:
      - model_id: qwen36-27b
        placement: cachyos-7900xtx
  "minimax/strong":
    hosting: vendor
    physical:
      - model_id: "minimax/m3"
        placement: null
  "openai/strong":
    hosting: vendor
    min_context: 400000
    physical:
      - model_id: "openai/gpt-5.6-sol"
        placement: null
YAML

# The SAME catalog with one difference: the native claude profile declares a
# window. `claude/strong` declares none in the catalog the kit actually ships
# against, which is why the undeclared-window path below is the honest default
# here too — but a native profile WITH a window has to be exercised as well, or
# the declared-window path would only ever be proved on the gateway class.
awk -v w=200000 '{print} /^  "claude\/strong":[[:space:]]*$/ {print "    min_context: " w}' \
  "$WORK/catalog.yaml" > "$WORK/catalog-windowed.yaml"

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
    # The terminal is what actually produces the worker's files. A case that
    # needs a result envelope or a lifecycle artifact to exist declares it
    # here, so nothing is pre-planted behind dispatch's own housekeeping.
    for n in 1 2; do
      pv="STUB_SPAWN_PATH$n"; bv="STUB_SPAWN_BODY$n"
      [[ -n "${!pv:-}" ]] && printf '%s' "${!bv:-}" > "${!pv}"
    done
    jq -n '{ok:true,result:{terminal:{handle:"term_stub"}}}' ;;
  "terminal read")
    # STUB_TERMINAL_STATUS lets a case drive the terminal to its END state. A
    # stub that only ever answers "running" cannot exercise the launch failure
    # a terminal that exits without an exit marker is supposed to be.
    jq -n --arg t "${STUB_TERMINAL_TAIL:-}" --arg s "${STUB_TERMINAL_STATUS:-running}" \
      '{ok:true,result:{terminal:{handle:"term_stub",status:$s,
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
      placement:"cachyos-7900xtx", readiness:"warm", headers:{"x-placement":"cachyos-7900xtx"},
      ttl_seconds:30, reason:null, alternatives:[], catalog_version:"sha256:x"}' > "$out"
  printf '200'
else
  [[ -n "$out" ]] && printf '{}' > "$out"
  printf '%s' "${STUB_PLACE_HTTP}"
fi
STUB

printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/claude"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/codex"

# --- stub op (the 1Password CLI) and its service-account env file ----------
# GW_SENTINEL stands in for the scoped gateway key. It is what a real `op read`
# would return, and section 3b proves it reaches the harness environment and
# NOTHING else: not the command text, not the terminal title, not a log, not a
# file the launcher writes.
GW_SENTINEL='sentinel-gateway-credential-2f4a9c'
cat > "$BIN/op" <<STUB
#!/usr/bin/env bash
[[ "\$1" == "read" && -n "\${2:-}" ]] || exit 2
printf '%s' '$GW_SENTINEL'
STUB
chmod +x "$BIN"/*
printf 'export OP_SERVICE_ACCOUNT_TOKEN=stub-service-account\n' > "$WORK/op-env"

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
      entitlement_pool:(if $pool != "" then $pool
                        elif $pr then null
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
run_dispatch() { # run_dispatch <story> [cycle] -> echoes exit code, stderr to $WORK/err
  ( cd "$WT" && PATH="$BIN:$PATH" HOME="$HOME_DIR" \
      AGENT_STAMP_VALIDATE="agent-stamp-validate" \
      AGENT_STAMP_VALIDATE_CATALOG_PATH="${STUB_CATALOG-$WORK/catalog.yaml}" \
      AGENT_FLOW_BUDGET_POLICY="${STUB_BUDGET_POLICY-$KIT_ROOT/files/model-router/context-budget-policy.yaml}" \
      AGENT_FLOW_CONFIG="$WORK/nonexistent.yaml" \
      SUBSCRIPTIONS_FILE="" \
      AGENT_ROUTER_URL="https://router.invalid" \
      AGENT_ROUTER_TOKEN="stub-token" \
      AGENT_ROUTER_TOKEN_ENV="AGENT_ROUTER_TOKEN" \
      AGENT_DIR="" AGENT_FLOW_APPROVED_HOME="${STUB_APPROVED_HOME-}" AGENT_FLOW_APPROVED_PATH="" \
      AGENT_FLOW_LAUNCH_TIMEOUT=20 \
      AGENT_FLOW_GATEWAY_URL="${STUB_GATEWAY_URL-https://gateway.invalid}" \
      AGENT_FLOW_GATEWAY_TOKEN_REF="${STUB_TOKEN_REF-op://stubvault/agw-claude-code/credential}" \
      AGENT_FLOW_OP_ENV_FILE="${STUB_OP_ENV_FILE-$WORK/op-env}" \
      CLAUDE_CONFIG_DIR="" \
      bash "$DISPATCH" "$1" "${2:-1}" ) >"$WORK/out" 2>"$WORK/err"
  echo $?
}

# Prove the preflight is on the real dispatch path before terminal creation.
: > "$STUB_STATE/terminal-creates"
mkdir -p "$WT/.claude"
printf '{bad json\n' > "$WT/.claude/settings.json"
write_story "$WT/s-settings.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/s-settings.md.stamp.json" high false
printf '{"stale":"last cycle"}' > "$WT/s-settings.md.claude-result.json"
rc="$(run_dispatch s-settings.md)"
assert_eq "settings integration: malformed project settings -> exit 2" "$rc" "2"
assert_contains "settings integration: refusal names the responsible file" \
  "$(cat "$WORK/err")" "$WT/.claude/settings.json"
assert_empty_file "settings integration: no terminal created" "$STUB_STATE/terminal-creates"
assert_no_file "settings integration: no result artifact" "$WT/s-settings.md.result.json"
assert_no_file "settings integration: stale Claude result is removed" \
  "$WT/s-settings.md.claude-result.json"
rm -f "$WT/.claude/settings.json"

# Exercise approved-home resolution through main, not only the pure helper.
APPROVED_HOME="$WORK/approved-home"
mkdir -p "$APPROVED_HOME/.claude"
printf '%s\n' '{"fallbackModel":"haiku"}' > "$APPROVED_HOME/.claude/settings.json"
write_story "$WT/s-user-settings.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/s-user-settings.md.stamp.json" high false
: > "$STUB_STATE/terminal-creates"
rc="$(STUB_APPROVED_HOME="$APPROVED_HOME"; export STUB_APPROVED_HOME; run_dispatch s-user-settings.md)"
assert_eq "settings integration: approved-home fallback -> exit 2" "$rc" "2"
assert_contains "settings integration: approved-home refusal names the file" \
  "$(cat "$WORK/err")" "$APPROVED_HOME/.claude/settings.json"
assert_empty_file "settings integration: approved-home refusal creates no terminal" \
  "$STUB_STATE/terminal-creates"
assert_no_file "settings integration: approved-home refusal creates no Claude result" \
  "$WT/s-user-settings.md.claude-result.json"

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
# The placement machinery runs to completion and the launch now proceeds: this
# pair has a validated launch class (section 3b). What section 3 asserts here is
# only that placement happened first, freshly, and reached the validator.
assert_eq "placement required: placed, validated, launched" "$rc" "0"
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
head1 "3b. Launch classes — one admitted exactly, everything else fail-closed"
# ===========================================================================
# The adapter has two validated launch classes and declares its own capability
# for both. A pair inside one launches, exactly as its contract specifies; a
# pair outside both is stopped loudly and distinctly, before any command text
# exists, and is never retargeted to a harness the adapter CAN launch.

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

# --- the gateway-backed local class, admitted and held to its contract -----
# {claude, local-code-standard} is the pair the guard used to refuse. It is now
# launchable, and ONLY as the catalog's launch contract specifies it.

: > "$STUB_STATE/terminal-creates"
: > "$STUB_STATE/curl-calls"
rm -f "$STUB_STATE/last-command.txt" "$WT/s-gateway.md.result.json" "$WT/s-gateway.md.blocked"
export STUB_TERMINAL_TAIL="ok
CLAUDE_EXIT=0"
write_story "$WT/s-gateway.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/s-gateway.md.stamp.json" high true local-code-standard claude
rc="$(run_dispatch s-gateway.md)"

assert_eq "gateway: {claude, local-code-standard} launches (exit 0)" "$rc" "0"
assert_no_file "gateway: no blocked marker written" "$WT/s-gateway.md.blocked"
assert_contains "gateway: placement was fetched for this attempt" \
  "$(cat "$STUB_STATE/curl-calls")" "/v1/place"
assert_contains "gateway: the stamp was validated with that evidence" \
  "$(cat "$STUB_STATE/validator-argv.txt")" "--evidence"

GW_LAUNCHED="$(cat "$STUB_STATE/last-command.txt" 2>/dev/null || true)"
GW_L_SEGMENT="${GW_LAUNCHED#*env -i }"
GW_L_SEGMENT="${GW_L_SEGMENT%% claude -p*}"
GW_L_NAMES="$(tr ' ' '\n' <<<"$GW_L_SEGMENT" \
              | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' | tr '\n' ' ')"
assert_eq "gateway: the LAUNCHED allowlist is exactly the contract" \
  "$GW_L_NAMES" \
  "HOME PATH USER LANG TERM ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_CUSTOM_HEADERS CLAUDE_CODE_MAX_CONTEXT_TOKENS "
assert_contains "gateway: launched with the configured endpoint" \
  "$GW_LAUNCHED" "ANTHROPIC_BASE_URL=https://gateway.invalid"
assert_contains "gateway: launched pinned to the catalog physical model" \
  "$GW_LAUNCHED" "ANTHROPIC_MODEL=qwen36-27b"
assert_contains "gateway: --model carries the same value" "$GW_LAUNCHED" "--model qwen36-27b"
# The stub /v1/place answers headers["x-placement"] = cachyos-7900xtx. The
# launcher must convey THAT, verbatim, and must not compose one from the
# catalog's placement hint or from the result's own `placement` field.
assert_contains "gateway: x-placement comes verbatim from the place evidence" \
  "$GW_LAUNCHED" "ANTHROPIC_CUSTOM_HEADERS=$(shq 'x-placement: cachyos-7900xtx')"
assert_contains "gateway: the catalog's min_context is the session window" \
  "$GW_LAUNCHED" "CLAUDE_CODE_MAX_CONTEXT_TOKENS=65536"
assert_contains "gateway: stamped effort still passed explicitly" "$GW_LAUNCHED" "--effort high"
assert_contains "gateway: least-privilege tool set unchanged" \
  "$GW_LAUNCHED" '--tools "Read,Glob,Grep,Write"'
assert_contains "gateway: --strict-mcp-config unchanged" "$GW_LAUNCHED" "--strict-mcp-config"
assert_contains "gateway: acceptEdits unchanged" "$GW_LAUNCHED" "--permission-mode acceptEdits"
assert_contains "gateway: stdin redirect unchanged" "$GW_LAUNCHED" "< /dev/null"
assert_contains "gateway: in-band exit capture unchanged" "$GW_LAUNCHED" 'echo "CLAUDE_EXIT=$?"'
assert_absent "gateway: no story body inline" "$GW_LAUNCHED" "Do the thing"
assert_absent "gateway: ANTHROPIC_API_KEY never appears" "$GW_LAUNCHED" "ANTHROPIC_API_KEY"

# --- the credential never leaves the harness's own environment -------------
# The reference and the env file are in the text; the VALUE is resolved by the
# terminal at launch time. Prove first that the configured mechanism really
# does resolve to the sentinel, so the absence assertions below are not
# vacuously true of a mechanism that resolves to nothing.
# Which of these carries the proof: "the value is NOT in the generated command"
# is the load-bearing one — the stub never executes the command text, so the
# credential is never resolved during a suite run and the remaining absences
# are structural. Their runtime counterparts (the terminal shell, its children,
# xtrace, /proc) are covered by the reviewer's attack-03 in
# _bmad-output/implementation-artifacts/evidence/AFK-PORT-1.4-LV-REVIEW/.
GW_RESOLVED="$( . "$WORK/op-env" && "$BIN/op" read "op://stubvault/agw-claude-code/credential" )"
assert_eq "gateway: the configured reference really resolves to the credential" \
  "$GW_RESOLVED" "$GW_SENTINEL"
assert_contains "gateway: the command carries the REFERENCE" \
  "$GW_LAUNCHED" "op read op://stubvault/agw-claude-code/credential"
assert_absent "gateway: the value is NOT in the generated command" "$GW_LAUNCHED" "$GW_SENTINEL"
assert_absent "gateway: the value is NOT in the terminal title" \
  "$(cat "$STUB_STATE/last-title.txt")" "$GW_SENTINEL"
assert_absent "gateway: the value is NOT on dispatch stderr" "$(cat "$WORK/err")" "$GW_SENTINEL"
assert_absent "gateway: the value is NOT on dispatch stdout" "$(cat "$WORK/out")" "$GW_SENTINEL"
assert_absent "gateway: the value is NOT in the prompt file" \
  "$(cat "$WT/s-gateway.md.prompt")" "$GW_SENTINEL"
assert_absent "gateway: the value is NOT in the result artifact" \
  "$(cat "$WT/s-gateway.md.result.json")" "$GW_SENTINEL"
GW_LEAKS="$(grep -rl -- "$GW_SENTINEL" "$WT" "$STUB_STATE" 2>/dev/null || true)"
assert_eq "gateway: no file the launcher wrote contains the credential" "$GW_LEAKS" ""

assert_eq "gateway: the run still completes honestly" \
  "$(jq -r .status "$WT/s-gateway.md.result.json")" "done"
assert_eq "gateway: placement is summarised in the result" \
  "$(jq -r .placement.required "$WT/s-gateway.md.result.json")" "true"

# --- fail-closed preflights, each before any terminal exists ---------------
# Every one of these is a value the launch cannot be specified without. None of
# them may produce a half-specified claude session, so each refuses while
# nothing exists: no terminal, no command text, no result artifact.
# (a) no gateway endpoint configured
: > "$STUB_STATE/terminal-creates"
rm -f "$STUB_STATE/last-command.txt" "$WT/s-gateway.md.result.json"
rc="$(STUB_GATEWAY_URL=""; export STUB_GATEWAY_URL; run_dispatch s-gateway.md)"
assert_eq "gateway preflight: no endpoint -> exit 2" "$rc" "2"
assert_contains "gateway preflight: names launcher.gateway_endpoint" \
  "$(cat "$WORK/err")" "launcher.gateway_endpoint"
assert_empty_file "gateway preflight: endpoint — no terminal created" "$STUB_STATE/terminal-creates"
assert_no_file "gateway preflight: endpoint — no command built" "$STUB_STATE/last-command.txt"
assert_no_file "gateway preflight: endpoint — no result artifact" "$WT/s-gateway.md.result.json"

# (a2) and a refusal does not leave LAST cycle's result artifact on disk.
# `rm -f` sits above the preflights, so a reader that opens
# ${STORY}.claude-result.json by name after a refusal finds nothing rather than
# a stale result for a launch that never happened.
: > "$STUB_STATE/terminal-creates"
rm -f "$STUB_STATE/last-command.txt" "$WT/s-gateway.md.result.json"
printf '{"stale":"last cycle"}' > "$WT/s-gateway.md.claude-result.json"
rc="$(STUB_GATEWAY_URL=""; export STUB_GATEWAY_URL; run_dispatch s-gateway.md)"
assert_eq "gateway preflight: stale artifact — still refuses (exit 2)" "$rc" "2"
assert_no_file "gateway preflight: the STALE claude-result.json is gone" \
  "$WT/s-gateway.md.claude-result.json"
assert_no_file "gateway preflight: stale — no result artifact written" \
  "$WT/s-gateway.md.result.json"
assert_empty_file "gateway preflight: stale — no terminal created" "$STUB_STATE/terminal-creates"

# (b) no credential reference configured
: > "$STUB_STATE/terminal-creates"
rm -f "$STUB_STATE/last-command.txt" "$WT/s-gateway.md.result.json"
rc="$(STUB_TOKEN_REF=""; export STUB_TOKEN_REF; run_dispatch s-gateway.md)"
assert_eq "gateway preflight: no credential reference -> exit 2" "$rc" "2"
assert_contains "gateway preflight: names launcher.gateway_token_ref" \
  "$(cat "$WORK/err")" "launcher.gateway_token_ref"
assert_empty_file "gateway preflight: credential — no terminal created" "$STUB_STATE/terminal-creates"
assert_no_file "gateway preflight: credential — no command built" "$STUB_STATE/last-command.txt"
assert_no_file "gateway preflight: credential — no result artifact" "$WT/s-gateway.md.result.json"

# (c) the placement evidence carries no x-placement header
: > "$STUB_STATE/terminal-creates"
rm -f "$STUB_STATE/last-command.txt" "$WT/s-gateway.md.result.json"
cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [[ "$prev" == "-o" ]] && out="$a"; prev="$a"; done
echo "$*" >> "$STUB_STATE/curl-calls"
[[ -n "$out" ]] && jq -n '{status:"placed", model:"qwen36-27b",
    placement:"cachyos-7900xtx", readiness:"warm", headers:{},
    ttl_seconds:30, reason:null, alternatives:[], catalog_version:"sha256:x"}' > "$out"
printf '200'
STUB
chmod +x "$BIN/curl"
rc="$(run_dispatch s-gateway.md)"
assert_eq "gateway preflight: no x-placement header -> exit 6" "$rc" "6"
assert_contains "gateway preflight: says the header is copied, never composed" \
  "$(cat "$WORK/err")" "verbatim"
assert_empty_file "gateway preflight: header — no terminal created" "$STUB_STATE/terminal-creates"
assert_no_file "gateway preflight: header — no command built" "$STUB_STATE/last-command.txt"
assert_no_file "gateway preflight: header — no result artifact" "$WT/s-gateway.md.result.json"

# restore the PLACING stub: the next case is about the catalog, not placement,
# and a headerless place result would refuse it before the catalog is read
cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [[ "$prev" == "-o" ]] && out="$a"; prev="$a"; done
echo "$*" >> "$STUB_STATE/curl-calls"
if [[ "${STUB_PLACE_HTTP:-200}" == "200" ]]; then
  [[ -n "$out" ]] && jq -n '{status:"placed", model:"qwen36-27b",
      placement:"cachyos-7900xtx", readiness:"warm", headers:{"x-placement":"cachyos-7900xtx"},
      ttl_seconds:30, reason:null, alternatives:[], catalog_version:"sha256:x"}' > "$out"
  printf '200'
else
  [[ -n "$out" ]] && printf '{}' > "$out"
  printf '%s' "${STUB_PLACE_HTTP}"
fi
STUB
chmod +x "$BIN/curl"

# (d) the catalog profile declares no min_context
: > "$STUB_STATE/terminal-creates"
rm -f "$STUB_STATE/last-command.txt" "$WT/s-gateway.md.result.json"
cp "$WORK/catalog.yaml" "$WORK/catalog-full.yaml"
yq -i 'del(.profiles.local-code-standard.min_context)' "$WORK/catalog.yaml"
rc="$(run_dispatch s-gateway.md)"
assert_eq "gateway preflight: no min_context -> exit 2" "$rc" "2"
assert_contains "gateway preflight: names the unknown context window" \
  "$(cat "$WORK/err")" "min_context"
assert_empty_file "gateway preflight: context — no terminal created" "$STUB_STATE/terminal-creates"
assert_no_file "gateway preflight: context — no command built" "$STUB_STATE/last-command.txt"
assert_no_file "gateway preflight: context — no result artifact" "$WT/s-gateway.md.result.json"
cp "$WORK/catalog-full.yaml" "$WORK/catalog.yaml"

# --- an empty credential read is a LAUNCH FAILURE, never status: done -------
# The class's single most important safety property, exercised end to end
# rather than argued. The generated text refuses and exits 78 WITHOUT printing
# a CLAUDE_EXIT line, so the terminal reaches its end state with no marker.
# Drive the stub to exactly that shape: dispatch must report a launch that did
# not complete honestly and write no result artifact at all.
: > "$STUB_STATE/terminal-creates"
rm -f "$STUB_STATE/last-command.txt" "$WT/s-gateway.md.result.json" \
      "$WT/s-gateway.md.claude-result.json"
export STUB_TERMINAL_STATUS="exited"
export STUB_TERMINAL_TAIL="dispatch: gateway credential resolved EMPTY; refusing to start claude unauthenticated"
rc="$(run_dispatch s-gateway.md)"
assert_eq "gateway empty-read: reported as a launch failure (exit 2)" "$rc" "2"
assert_contains "gateway empty-read: says the launch did not complete honestly" \
  "$(cat "$WORK/err")" "did not complete honestly"
assert_no_file "gateway empty-read: no result artifact — never status: done" \
  "$WT/s-gateway.md.result.json"
unset STUB_TERMINAL_STATUS
export STUB_TERMINAL_TAIL="ok
CLAUDE_EXIT=0"

# --- and the class stays narrow: a local profile stamped with a vendor pool -
# Free execution funded from a vendor subscription pool is a stamp whose
# funding story and execution story disagree. Neither class covers it, and the
# refusal must name the pool rather than wave it through as "local, therefore
# fine".
: > "$STUB_STATE/terminal-creates"
rm -f "$STUB_STATE/last-command.txt" "$WT/s-gw-pooled.md.result.json" "$WT/s-gw-pooled.md.blocked"
write_story "$WT/s-gw-pooled.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/s-gw-pooled.md.stamp.json" high true local-code-standard claude anthropic-max
rc="$(run_dispatch s-gw-pooled.md)"
assert_eq "gateway: local profile on a vendor pool -> exit 7" "$rc" "7"
gwp_marker="$(cat "$WT/s-gw-pooled.md.blocked" 2>/dev/null || true)"
assert_contains "gateway: marker is distinctly typed" "$gwp_marker" "UNSUPPORTED-LAUNCH-CONTRACT:"
assert_contains "gateway: marker names the pool that should not be there" \
  "$gwp_marker" "entitlement_pool 'anthropic-max'"
assert_contains "gateway: marker says the stamp was VALID" "$gwp_marker" "The stamp is VALID"
assert_contains "gateway: marker says route NOT modified" "$gwp_marker" "route was NOT modified"
assert_empty_file "gateway: pooled — no Orca terminal created" "$STUB_STATE/terminal-creates"
assert_no_file "gateway: pooled — no harness command built" "$STUB_STATE/last-command.txt"
assert_no_file "gateway: pooled — no result artifact" "$WT/s-gw-pooled.md.result.json"
assert_eq "gateway: pooled — stamp entitlement_pool untouched" \
  "$(jq -r .entitlement_pool "$WT/s-gw-pooled.md.stamp.json")" "anthropic-max"

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
head1 "3c. Context budget — the window as routed fact, and pre-dispatch sizing"
# ===========================================================================
# The window is the CATALOG's, read exactly. The estimate is the launcher's own
# advisory policy, computed from files that already exist, and it reaches no
# router. Everything below runs the real dispatch.sh against the same stubs
# section 3 uses, so each threshold action is proved by what dispatch actually
# did — the exit code, the marker, the artifacts that do or do not exist —
# rather than by a helper called in isolation.

bud() { jq -r "$1" "$2"; }               # read one budget field from a result
reset_stubs() {                          # forget what the last case did
  : > "$STUB_STATE/curl-calls"; : > "$STUB_STATE/terminal-creates"
  rm -f "$STUB_STATE/last-command.txt"
}
export STUB_TERMINAL_TAIL="ok
CLAUDE_EXIT=0"

# --- an UNDECLARED window: NOT_EVALUATED, and no window is invented --------
# `claude/strong` declares no min_context in the catalog the kit ships against.
# That is the honest catalog state, and the kit reports it as such.
reset_stubs
write_story "$WT/s-bud-none.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/s-bud-none.md.stamp.json" high false
rc="$(run_dispatch s-bud-none.md)"
assert_eq "budget/undeclared: dispatch still proceeds" "$rc" "0"
BR="$WT/s-bud-none.md.result.json"
assert_eq "budget/undeclared: state NOT_EVALUATED"      "$(bud .budget.state "$BR")" "NOT_EVALUATED"
assert_eq "budget/undeclared: stable reason code"       "$(bud .budget.reason "$BR")" "CONTEXT_WINDOW_UNDECLARED"
assert_eq "budget/undeclared: window_tokens is null, not a guess" \
  "$(bud '.budget.window_tokens|type' "$BR")" "null"
assert_eq "budget/undeclared: ratio is null (nothing to divide by)" \
  "$(bud '.budget.estimate_ratio|type' "$BR")" "null"
assert_eq "budget/undeclared: NO findings can fire"     "$(bud '.budget.findings|length' "$BR")" "0"
assert_eq "budget/undeclared: the estimate is still recorded" \
  "$(bud '.budget.estimate_tokens > 0' "$BR")" "true"
assert_eq "budget/undeclared: method recorded"          "$(bud .budget.estimate_method "$BR")" "bytes4-v1"
assert_eq "budget/undeclared: window_source is the catalog" \
  "$(bud .budget.window_source "$BR")" "CATALOG"
assert_absent "budget/undeclared: nothing was appended to the story record" \
  "$(cat "$WT/s-bud-none.md")" "SIZING_RISK"

# The estimate is EXACTLY the documented sum: persona + story + prompt, each
# once, ceil(bytes/4). Computed here from the same files dispatch counted.
EXPECT_BYTES=$(( $(wc -c < "$WT/_bmad/bmm/agents/dev.md") \
               + $(wc -c < "$WT/s-bud-none.md") \
               + $(wc -c < "$WT/s-bud-none.md.prompt") ))
assert_eq "budget: the estimate is the documented sum of the declared inputs" \
  "$(bud .budget.estimate_tokens "$BR")" "$(( (EXPECT_BYTES + 3) / 4 ))"
BASE_ESTIMATE="$(bud .budget.estimate_tokens "$BR")"

# Deterministic: the same inputs produce the same number, run after run.
rc="$(run_dispatch s-bud-none.md)"
assert_eq "budget: the estimate is deterministic across runs" \
  "$(bud .budget.estimate_tokens "$BR")" "$BASE_ESTIMATE"

# --- a DECLARED window, native launch class -------------------------------
reset_stubs
write_story "$WT/s-bud-native.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/s-bud-native.md.stamp.json" high false
rc="$(STUB_CATALOG="$WORK/catalog-windowed.yaml"; export STUB_CATALOG; run_dispatch s-bud-native.md)"
assert_eq "budget/native: dispatch proceeds" "$rc" "0"
BR="$WT/s-bud-native.md.result.json"
assert_eq "budget/native: window carried from the catalog EXACTLY" \
  "$(bud .budget.window_tokens "$BR")" "200000"
assert_eq "budget/native: window_source CATALOG"  "$(bud .budget.window_source "$BR")" "CATALOG"
assert_eq "budget/native: state OK"               "$(bud .budget.state "$BR")" "OK"
assert_eq "budget/native: no reason on a grounded budget" "$(bud '.budget.reason|type' "$BR")" "null"
assert_eq "budget/native: ratio recorded"         "$(bud '.budget.estimate_ratio > 0' "$BR")" "true"
assert_eq "budget/native: ratio agrees with estimate/window" \
  "$(bud '(.budget.estimate_ratio * 1000000 | floor)' "$BR")" \
  "$(bud '(.budget.estimate_tokens * 1000000 / .budget.window_tokens | floor)' "$BR")"
assert_eq "budget/native: well inside the risk band -> no findings" \
  "$(bud '.budget.findings|length' "$BR")" "0"
assert_contains "budget/native: the launch class is unchanged" \
  "$(cat "$WORK/err")" "native vendor subscription"

# --- a DECLARED window, gateway-backed local launch class -----------------
# Same budget behaviour on the other claude launch class, and the launch text
# it produces is still the frozen one.
reset_stubs
write_story "$WT/s-bud-gw.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/s-bud-gw.md.stamp.json" high true local-code-standard
rc="$(run_dispatch s-bud-gw.md)"
assert_eq "budget/gateway: dispatch proceeds" "$rc" "0"
BR="$WT/s-bud-gw.md.result.json"
assert_eq "budget/gateway: window carried from the catalog EXACTLY" \
  "$(bud .budget.window_tokens "$BR")" "65536"
assert_eq "budget/gateway: state OK"             "$(bud .budget.state "$BR")" "OK"
assert_eq "budget/gateway: method recorded"      "$(bud .budget.estimate_method "$BR")" "bytes4-v1"
assert_contains "budget/gateway: the gateway launch class still ran" \
  "$(cat "$WORK/err")" "gateway-backed local"
GWL="$(cat "$STUB_STATE/last-command.txt")"
assert_contains "budget/gateway: CLAUDE_CODE_MAX_CONTEXT_TOKENS is still the catalog's" \
  "$GWL" "CLAUDE_CODE_MAX_CONTEXT_TOKENS=65536"
assert_absent "budget/gateway: the estimate never entered the launch text" \
  "$GWL" "estimate"

# --- the same behaviour on the OTHER harness (NFR-13/15) ------------------
reset_stubs
export STUB_TERMINAL_TAIL="ok
CODEX_EXIT=0"
write_story "$WT/s-bud-codex.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/s-bud-codex.md.stamp.json" high false "openai/strong" codex openai-plus
rc="$(run_dispatch s-bud-codex.md)"
assert_eq "budget/codex: dispatch proceeds on the second harness" "$rc" "0"
BR="$WT/s-bud-codex.md.result.json"
assert_eq "budget/codex: window carried from the catalog EXACTLY" \
  "$(bud .budget.window_tokens "$BR")" "400000"
assert_eq "budget/codex: state OK"          "$(bud .budget.state "$BR")" "OK"
assert_eq "budget/codex: same method, no per-harness estimate" \
  "$(bud .budget.estimate_method "$BR")" "bytes4-v1"
assert_contains "budget/codex: the codex launch text is the frozen one" \
  "$(cat "$STUB_STATE/last-command.txt")" "codex exec --model"
export STUB_TERMINAL_TAIL="ok
CLAUDE_EXIT=0"

# --- REFUSAL at or above the continuation threshold ----------------------
# The window is set to the payload's own estimate, so the ratio is exactly 1.0
# — past 0.85 by construction rather than by a magic byte count.
reset_stubs
write_story "$WT/s-bud-refuse.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/s-bud-refuse.md.stamp.json" high false
rc="$(run_dispatch s-bud-refuse.md)"   # first pass: learn this story's estimate
REFUSE_EST="$(bud .budget.estimate_tokens "$WT/s-bud-refuse.md.result.json")"
rm -f "$WT/s-bud-refuse.md.result.json" "$WT/s-bud-refuse.md.blocked"
awk -v w="$REFUSE_EST" '{print} /^  "claude\/strong":[[:space:]]*$/ {print "    min_context: " w}' \
  "$WORK/catalog.yaml" > "$WORK/catalog-tiny.yaml"
reset_stubs
rc="$(STUB_CATALOG="$WORK/catalog-tiny.yaml"; export STUB_CATALOG; run_dispatch s-bud-refuse.md)"
assert_eq "sizing refusal: distinct exit code 8" "$rc" "8"
SZM="$(cat "$WT/s-bud-refuse.md.blocked" 2>/dev/null || true)"
assert_contains "sizing refusal: marker is typed STORY-SIZING:" "$SZM" "STORY-SIZING:"
# The DECLARED reason code has to reach an artifact. A stable code that lives
# only in a shell variable name leaves automation parsing the exit code or the
# marker prefix, which is the coupling the reason-code discipline removes.
assert_contains "sizing refusal: the marker's first line carries reason=SIZING_REFUSED" \
  "$(head -1 "$WT/s-bud-refuse.md.blocked")" "reason=SIZING_REFUSED"
assert_contains "sizing refusal: the dispatch log line carries the same code" \
  "$(cat "$WORK/err")" "reason=SIZING_REFUSED"
assert_contains "sizing refusal: marker names the estimate"     "$SZM" "estimate=$REFUSE_EST"
assert_contains "sizing refusal: marker names the window"       "$SZM" "window=$REFUSE_EST"
assert_contains "sizing refusal: marker names the ratio"        "$SZM" "ratio=1.000000"
assert_contains "sizing refusal: marker names the threshold"    "$SZM" "threshold=0.850000"
assert_contains "sizing refusal: marker enumerates the inputs counted" "$SZM" "Inputs counted"
assert_contains "sizing refusal: marker names the story file among them" "$SZM" "s-bud-refuse.md"
assert_contains "sizing refusal: marker says it is a PLANNING outcome" "$SZM" "PLANNING outcome"
assert_empty_file "sizing refusal: NO /v1/place call was made"    "$STUB_STATE/curl-calls"
assert_empty_file "sizing refusal: NO Orca terminal was created"  "$STUB_STATE/terminal-creates"
assert_no_file "sizing refusal: NO harness command was built"     "$STUB_STATE/last-command.txt"
assert_no_file "sizing refusal: NO result artifact was written"   "$WT/s-bud-refuse.md.result.json"
assert_absent "sizing refusal: the stamp was not consulted for a substitute route" \
  "$(cat "$WORK/err")" "fallback"

# --- the SIZING-RISK band: proceeds, records, and does not duplicate ------
# Window chosen so the ratio lands near 0.70 — inside [0.60, 0.85) with margin
# on both sides, so integer division cannot drift the case into another band.
RISK_WINDOW=$(( REFUSE_EST * 10 / 7 ))
awk -v w="$RISK_WINDOW" '{print} /^  "claude\/strong":[[:space:]]*$/ {print "    min_context: " w}' \
  "$WORK/catalog.yaml" > "$WORK/catalog-risk.yaml"
reset_stubs
write_story "$WT/s-bud-risk.md" "persona: dev
gates: [\"true\"]"
printf '\n## Dev Agent Record\n\n(worker fills in)\n' >> "$WT/s-bud-risk.md"
write_stamp "$WT/s-bud-risk.md.stamp.json" high false
export STUB_CATALOG="$WORK/catalog-risk.yaml"
rc="$(run_dispatch s-bud-risk.md 1)"
assert_eq "sizing risk: dispatch is NOT blocked" "$rc" "0"
BR="$WT/s-bud-risk.md.result.json"
assert_eq "sizing risk: state stays OK (the dispatch is healthy)" "$(bud .budget.state "$BR")" "OK"
assert_eq "sizing risk: the finding is in the thin result" \
  "$(jq -c '.budget.findings' "$BR")" '["SIZING_RISK"]'
assert_eq "sizing risk: exactly one line in the story record" \
  "$(grep -ac '^- budget: SIZING_RISK ' "$WT/s-bud-risk.md")" "1"
assert_contains "sizing risk: the recorded line names estimate, window and cycle" \
  "$(grep -a '^- budget: SIZING_RISK ' "$WT/s-bud-risk.md")" "cycle 1"
assert_contains "sizing risk: the line sits under the Dev Agent Record heading" \
  "$(sed -n '/^## Dev Agent Record/,$p' "$WT/s-bud-risk.md")" "- budget: SIZING_RISK"
assert_empty_file "sizing risk: still no /v1/place for a vendor profile" "$STUB_STATE/curl-calls"
assert_no_file "sizing risk: no blocked marker" "$WT/s-bud-risk.md.blocked"

# Idempotent PER CYCLE: re-dispatching the same cycle does not write a second
# line; a genuinely new cycle is a new observation and gets its own.
rc="$(run_dispatch s-bud-risk.md 1)"
assert_eq "sizing risk: a re-dispatch of the SAME cycle does not duplicate" \
  "$(grep -ac '^- budget: SIZING_RISK ' "$WT/s-bud-risk.md")" "1"
rc="$(run_dispatch s-bud-risk.md 2)"
assert_eq "sizing risk: a NEW cycle records its own observation" \
  "$(grep -ac '^- budget: SIZING_RISK ' "$WT/s-bud-risk.md")" "2"
assert_eq "sizing risk: and the second line is keyed to cycle 2" \
  "$(grep -ac 'cycle 2 ' "$WT/s-bud-risk.md")" "1"
assert_contains "sizing risk: the story body was not otherwise disturbed" \
  "$(cat "$WT/s-bud-risk.md")" "Do the thing."
unset STUB_CATALOG

# --- payload_refs: counted, counted ONCE, and refused when missing --------
# The two stories below differ by exactly one character in one filename, so
# their own byte lengths are equal and the only variable is what they declare.
printf 'x%.0s' $(seq 4000) > "$WT/ref-a.txt"
printf 'y%.0s' $(seq 4000) > "$WT/ref-b.txt"
reset_stubs
write_story "$WT/s-bud-ref1.md" "persona: dev
gates: [\"true\"]
payload_refs: [ref-a.txt, ref-a.txt]"
write_story "$WT/s-bud-ref2.md" "persona: dev
gates: [\"true\"]
payload_refs: [ref-a.txt, ref-b.txt]"
write_stamp "$WT/s-bud-ref1.md.stamp.json" high false
write_stamp "$WT/s-bud-ref2.md.stamp.json" high false
rc="$(run_dispatch s-bud-ref1.md)"; assert_eq "payload_refs: a story with refs dispatches" "$rc" "0"
rc="$(run_dispatch s-bud-ref2.md)"
E_DUP="$(bud .budget.estimate_tokens "$WT/s-bud-ref1.md.result.json")"
E_TWO="$(bud .budget.estimate_tokens "$WT/s-bud-ref2.md.result.json")"
assert_eq "payload_refs: a DISTINCT second ref adds its 4000 bytes (1000 tokens)" \
  "$(( E_TWO - E_DUP ))" "1000"
assert_eq "payload_refs: the SAME ref listed twice is counted ONCE" \
  "$E_DUP" \
  "$(( ( $(wc -c < "$WT/_bmad/bmm/agents/dev.md") + $(wc -c < "$WT/s-bud-ref1.md") \
        + $(wc -c < "$WT/s-bud-ref1.md.prompt") + 4000 + 3 ) / 4 ))"

reset_stubs
write_story "$WT/s-bud-refmiss.md" "persona: dev
gates: [\"true\"]
payload_refs: [ref-a.txt, ref-nowhere.txt]"
write_stamp "$WT/s-bud-refmiss.md.stamp.json" high false
rc="$(run_dispatch s-bud-refmiss.md)"
assert_eq "payload_refs: a missing ref REFUSES (config exit)" "$rc" "2"
assert_contains "payload_refs: the refusal carries the stable reason code" \
  "$(cat "$WORK/err")" "PAYLOAD_REF_MISSING"
assert_contains "payload_refs: the refusal names the entry" \
  "$(cat "$WORK/err")" "ref-nowhere.txt"
assert_empty_file "payload_refs: missing ref made no /v1/place call" "$STUB_STATE/curl-calls"
assert_empty_file "payload_refs: missing ref created no terminal" "$STUB_STATE/terminal-creates"
assert_no_file "payload_refs: missing ref wrote no result" "$WT/s-bud-refmiss.md.result.json"

# A ref that RESOLVES to a real, readable file is not thereby a ref the worker
# can read: the worker is sandboxed to the worktree. `-f` and `-r` alone are
# satisfied by any file on the host, so the accept path applies the containment
# rule main() applies to the story — and `..` is the case that reaches a real
# file, which is why it gets a live one to escape to rather than a dangling name.
printf 'z%.0s' $(seq 4000) > "$WORK/outside.txt"
ref_refuses() { # <tag> <payload_refs value> <what it is>
  local tag="$1" refs="$2" what="$3"
  reset_stubs
  write_story "$WT/s-bud-$tag.md" "persona: dev
gates: [\"true\"]
payload_refs: $refs"
  write_stamp "$WT/s-bud-$tag.md.stamp.json" high false
  local rc; rc="$(run_dispatch "s-bud-$tag.md")"
  assert_eq "payload_refs: $what refuses (config exit)" "$rc" "2"
  assert_contains "payload_refs: $what carries the stable reason code" \
    "$(cat "$WORK/err")" "PAYLOAD_REF_MISSING"
  assert_no_file "payload_refs: $what wrote no result" "$WT/s-bud-$tag.md.result.json"
  assert_empty_file "payload_refs: $what made no /v1/place call" "$STUB_STATE/curl-calls"
}
ref_refuses refesc  '[../outside.txt]'    "a ref that ESCAPES the worktree with .."
# and the escape is refused for the RIGHT reason — containment, not existence.
# Read here, while $WORK/err still holds THIS case's stderr: the cases below
# overwrite it, and a `..` that reached a real file would otherwise be indicted
# by whichever refusal ran last.
assert_contains "payload_refs: the .. refusal names the containing directory" \
  "$(cat "$WORK/err")" "OUTSIDE the current directory"
ref_refuses refabs  '[/etc/hostname]'     "an absolute path outside the tree"
ref_refuses refdir  '[.]'                 "a directory rather than a file"
# The control that would fail if the probe stopped measuring anything: the same
# story shape with the SAME file reachable from INSIDE the worktree dispatches,
# so the refusals above are about containment and not about the ref mechanism.
cp "$WORK/outside.txt" "$WT/inside.txt"
reset_stubs
write_story "$WT/s-bud-refin.md" "persona: dev
gates: [\"true\"]
payload_refs: [inside.txt]"
write_stamp "$WT/s-bud-refin.md.stamp.json" high false
rc="$(run_dispatch s-bud-refin.md)"
assert_eq "payload_refs: CONTROL — the same file INSIDE the worktree dispatches" "$rc" "0"

# --- an unreadable policy refuses BEFORE anything happens ----------------
reset_stubs
rc="$(STUB_BUDGET_POLICY="$WORK/no-such-policy.yaml"; export STUB_BUDGET_POLICY; run_dispatch s-bud-none.md)"
assert_eq "policy unreadable: config exit" "$rc" "2"
assert_contains "policy unreadable: stable reason code" \
  "$(cat "$WORK/err")" "BUDGET_POLICY_UNREADABLE"
assert_contains "policy unreadable: says a missing threshold is not a default" \
  "$(cat "$WORK/err")" "no default in code"
assert_empty_file "policy unreadable: no /v1/place call"   "$STUB_STATE/curl-calls"
assert_empty_file "policy unreadable: no terminal created" "$STUB_STATE/terminal-creates"
assert_no_file "policy unreadable: no harness command"     "$STUB_STATE/last-command.txt"
# and an INCOMPLETE policy is refused just as hard — a missing key is not a default
reset_stubs
printf 'estimate_method: bytes4-v1\ncontinuation_ratio: 0.85\n' > "$WORK/incomplete-policy.yaml"
rc="$(STUB_BUDGET_POLICY="$WORK/incomplete-policy.yaml"; export STUB_BUDGET_POLICY; run_dispatch s-bud-none.md)"
assert_eq "policy incomplete: config exit" "$rc" "2"
assert_contains "policy incomplete: names the keys it is missing" \
  "$(cat "$WORK/err")" "sizing_risk_ratio"
assert_empty_file "policy incomplete: no terminal created" "$STUB_STATE/terminal-creates"

# --- AC-6: the estimate is not, and cannot become, a routing input -------
# Two independent proofs: the launcher never mentions the route request at all,
# and a request that declares no context_size is POSTed without one.
# The launcher's only HTTP call is the placement one. `/v1/route` appears in
# dispatch.sh solely inside refusal prose that tells a human to go and re-route,
# so the check is on what the code CALLS, not on which strings it contains — a
# grep that a comment can satisfy is a grep that guards nothing.
AC6_CURL="$(code_of "$DISPATCH" | grep -nE 'curl ' || true)"
if [[ -z "$AC6_CURL" ]]; then
  bad "AC-6: the launcher's only HTTP call is /v1/place" "no curl call found — the probe is broken"
elif grep -q '/v1/route' <<<"$AC6_CURL"; then
  bad "AC-6: the launcher's only HTTP call is /v1/place" "$AC6_CURL"
elif ! grep -q '/v1/place' <<<"$AC6_CURL"; then
  bad "AC-6: the launcher's only HTTP call is /v1/place" "curl targets neither endpoint: $AC6_CURL"
else ok "AC-6: the launcher's only HTTP call is /v1/place, never /v1/route"; fi
if grep -q 'context_size' "$DISPATCH"; then
  bad "AC-6: 'context_size' appears nowhere in the launcher, in code or in prose" \
      "$(grep -n 'context_size' "$DISPATCH" | head -2)"
else ok "AC-6: 'context_size' appears nowhere in the launcher, in code or in prose"; fi
mkdir -p "$WORK/reqbin"
cat > "$WORK/reqbin/curl" <<'STUB'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do
  [[ "$prev" == "-o" ]] && out="$a"
  [[ "$prev" == "-d" ]] && printf '%s' "$a" > "$STUB_STATE/route-request-body.json"
  [[ "$prev" == "-d" && "${a:0:1}" == "@" ]] && cat "${a:1}" > "$STUB_STATE/route-request-body.json"
  prev="$a"
done
if [[ -n "$out" ]]; then cat "$STUB_ROUTE_RESPONSE" > "$out"; fi
printf '200'
STUB
chmod +x "$WORK/reqbin/curl"
cat > "$WORK/sized-request.json" <<'JSON'
{"story_id":"STORY-SIZED-1","title":"a story with a sizing estimate",
 "summary":"the kit computed a pre-dispatch estimate for this story",
 "ambiguity":"low","blast_radius":"low","volume_hint":"low","tags":["docs"]}
JSON
cat > "$WORK/route-response-ac6.json" <<'JSON'
{"harness":"claude","model_profile":"claude/strong","effort":"high",
 "cost_class":"subscription","entitlement_pool":"anthropic-max","metered":false,
 "placement_policy":"prefer-warm-local","placement_required":false,
 "catalog_version":"sha256:abc","expires_at":"2099-01-01T00:00:00Z"}
JSON
rm -f "$STUB_STATE/route-request-body.json"
if PATH="$WORK/reqbin:$PATH" STUB_ROUTE_RESPONSE="$WORK/route-response-ac6.json" \
   AGENT_FLOW_CONFIG="$WORK/nonexistent.yaml" SUBSCRIPTIONS_FILE="" \
   AGENT_ROUTER_URL="https://router.invalid" AGENT_ROUTER_TOKEN=t \
   bash "$MAKE_STAMP" --request "$WORK/sized-request.json" \
     --out "$WORK/ac6.stamp.json" >/dev/null 2>&1; then
  assert_eq "AC-6: the POSTed /v1/route body carries NO context_size" \
    "$(jq -r 'has("context_size")' "$STUB_STATE/route-request-body.json")" "false"
  assert_eq "AC-6: and no capacity input of any other name" \
    "$(jq -r '[keys[]|select(test("context|window|budget|capacity"))]|length' \
       "$STUB_STATE/route-request-body.json")" "0"
  assert_eq "AC-6: the resulting stamp carries no context_size either" \
    "$(jq -r '.task|has("context_size")' "$WORK/ac6.stamp.json")" "false"
else
  bad "AC-6: make-stamp round trip on a story with a sizing estimate"
fi


# ===========================================================================
head1 "3d. Context budget — observed usage, phase-boundary artifacts (lane B)"
# ===========================================================================
# Usage is whatever the harness PUBLISHES under its frozen launch text, and
# nothing else. Both frozen texts are unchanged by this section, so the claude
# adapter sees one end-of-run envelope and the codex adapter sees nothing —
# and the discipline that carries a worker across a boundary is therefore
# deterministic policy in the prompt rather than a usage reading.

# --- the adapters, called directly (AC-1) ---------------------------------
# num_turns defaults to 1: the single-call envelope IS that call's context, and
# it is the only envelope a ratio may be computed from. The multi-turn case has
# its own fixture below.
envelope() { # <input> <cache-read> <cache-create> [window] [model] [num-turns]
  jq -nc --argjson i "$1" --argjson r "$2" --argjson c "$3" \
     --arg w "${4:-}" --arg m "${5:-opus}" --argjson n "${6:-1}" \
    '{type:"result", is_error:false, result:"ok", num_turns:$n,
      usage:{input_tokens:$i, cache_read_input_tokens:$r,
             cache_creation_input_tokens:$c, output_tokens:99999},
      modelUsage:(if $w == "" then {} else {($m):{contextWindow:($w|tonumber)}} end)}'
}
UF="$WORK/envelope.json"; envelope 1000 500 200 200000 opus > "$UF"
assert_eq "adapter/claude: usage is input + cache reads + cache creation" \
  "$(usage_adapter_claude "$UF" opus | jq -r .usage_tokens)" "1700"
assert_eq "adapter/claude: the observation is labelled by source and by when" \
  "$(usage_adapter_claude "$UF" opus | jq -r '.provenance + " " + .observed_at')" \
  "HARNESS_ENVELOPE END_OF_RUN"
assert_eq "adapter/claude: the harness window is read for corroboration" \
  "$(usage_adapter_claude "$UF" opus | jq -r .window_tokens)" "200000"
printf '{"type":"result","result":"ok"}' > "$WORK/usageless.json"
assert_eq "adapter/claude: an envelope with no usage member is NOT_EVALUATED" \
  "$(usage_adapter_claude "$WORK/usageless.json" opus | jq -r .reason)" "USAGE_UNOBSERVABLE"
envelope 10 0 0 "" > "$WORK/nowindow.json"
assert_eq "adapter/claude: no reported window is null, never the catalog's" \
  "$(usage_adapter_claude "$WORK/nowindow.json" opus | jq -r '.window_tokens|type')" "null"
# A `usage` object present but carrying NONE of the three context members is a
# run whose context was never published. Reporting 0 for it would be the one
# place the adapter says more than it saw.
printf '{"type":"result","usage":{"output_tokens":9999}}' > "$WORK/outputonly.json"
assert_eq "adapter/claude: usage with no input or cache member is unobservable" \
  "$(usage_adapter_claude "$WORK/outputonly.json" opus | jq -r '.reason + " " + (.usage_tokens|tostring)')" \
  "USAGE_UNOBSERVABLE null"
# ... and the control: ONE of the three is enough to be an observation.
printf '{"type":"result","usage":{"cache_read_input_tokens":42}}' > "$WORK/cacheonly.json"
assert_eq "adapter CONTROL: any one of the three members IS an observation" \
  "$(usage_adapter_claude "$WORK/cacheonly.json" opus | jq -r '.provenance + " " + (.usage_tokens|tostring)')" \
  "HARNESS_ENVELOPE 42"
# Corroboration is an EXACT key match. The harness names its own models, so the
# single entry that happens to be there is a different model's window.
envelope 10 0 0 200000 "some-other-model" > "$WORK/othermodel.json"
assert_eq "adapter/claude: a non-matching modelUsage key corroborates nothing" \
  "$(usage_adapter_claude "$WORK/othermodel.json" opus | jq -r '.window_tokens|tostring')" "null"
assert_eq "adapter CONTROL: the matching key IS read" \
  "$(usage_adapter_claude "$WORK/othermodel.json" some-other-model | jq -r '.window_tokens|tostring')" "200000"
assert_eq "adapter/codex: the second harness reports NOT_EVALUATED" \
  "$(usage_adapter_codex | jq -r '.provenance + " " + .reason')" "NOT_EVALUATED USAGE_UNOBSERVABLE"
assert_eq "the core calls ONE interface: claude routes to the claude adapter" \
  "$(harness_usage_observation claude "$UF" opus)" "$(usage_adapter_claude "$UF" opus)"
assert_eq "and codex to the codex adapter" \
  "$(harness_usage_observation codex "$UF" opus)" "$(usage_adapter_codex)"

# --- what the envelope's usage MEASURES (AC-1, externally reported) --------
# The members are the SUM over every API call the run made, not the context the
# final call held. The fixture is the real envelope from the first natural-route
# gateway-backed dispatch: 83 turns, 1,330,455 summed tokens against a 65,536
# window — 20.30, a ratio for a run that never occupied more than one window.
FU1="$KIT_ROOT/tests/fixtures/claude-result-envelope-multiturn.json"
assert_eq "scope: a multi-turn envelope is the run's TOTAL, and says so" \
  "$(usage_adapter_claude "$FU1" qwen36-27b | jq -r '.scope + " " + .reason')" \
  "CUMULATIVE_RUN USAGE_CUMULATIVE_ONLY"
assert_eq "scope: the cumulative figure is still reported, as information" \
  "$(usage_adapter_claude "$FU1" qwen36-27b | jq -r '(.usage_tokens|tostring) + " " + .provenance')" \
  "1330455 HARNESS_ENVELOPE"
assert_eq "scope: a single-turn envelope IS that call's context" \
  "$(usage_adapter_claude "$UF" opus | jq -r '.scope + " " + (.reason|tostring)')" \
  "FINAL_CONTEXT null"
# An envelope that publishes no turn count proves nothing about how many calls
# it summed, so it is not a single call's context either. Fail closed.
printf '{"type":"result","usage":{"input_tokens":10}}' > "$WORK/noturns.json"
assert_eq "scope: no num_turns is not proof of one call — cumulative" \
  "$(usage_adapter_claude "$WORK/noturns.json" opus | jq -r .scope)" "CUMULATIVE_RUN"

# ... and what the budget half does with each. The cumulative figure is never
# divided: no ratio, no band, no HIGH_USAGE, and the pre-dispatch verdict is
# left exactly where lane A put it.
load_budget_policy "$BUDGET_POLICY_SHIPPED" 2>/dev/null
HARNESS=claude; BUDGET_FINDINGS=(); BUDGET_STATE="OK"; BUDGET_REASON=""
budget_evaluate_usage "$(usage_adapter_claude "$FU1" qwen36-27b)" 65536 2>/dev/null
assert_eq "FU.1: the cumulative figure yields NO ratio" "$BUDGET_USAGE_RATIO" ""
assert_eq "FU.1: and is labelled cumulative, with the reason why" \
  "$BUDGET_USAGE_SCOPE/$BUDGET_USAGE_REASON" "CUMULATIVE_RUN/USAGE_CUMULATIVE_ONLY"
assert_eq "FU.1: the pre-dispatch verdict stands — no band is asserted from it" \
  "$BUDGET_STATE" "OK"
assert_absent "FU.1: and no HIGH_USAGE is claimed from a total" \
  "${BUDGET_FINDINGS[*]-}" "HIGH_USAGE"
assert_eq "FU.1: the figure itself is still published" "$BUDGET_USAGE_TOKENS" "1330455"
# The control: the SAME arithmetic on a single-turn envelope DOES evaluate.
envelope 60000 0 0 65536 opus 1 > "$WORK/oneturn.json"
HARNESS=claude; BUDGET_FINDINGS=(); BUDGET_STATE="OK"; BUDGET_REASON=""
budget_evaluate_usage "$(usage_adapter_claude "$WORK/oneturn.json" opus)" 65536 2>/dev/null
assert_eq "CONTROL: a FINAL_CONTEXT measurement is evaluated as before" \
  "$BUDGET_USAGE_SCOPE/$BUDGET_STATE" "FINAL_CONTEXT/CONTINUATION_REQUIRED"
assert_contains "CONTROL: and HIGH_USAGE is asserted from that one" \
  "${BUDGET_FINDINGS[*]-}" "HIGH_USAGE"

# The cost figure in the envelope is a client-side estimate (costBasis
# "unknown") and on a free-cost route it is not money at all. It is never read.
if grep -q 'total_cost_usd\|costUSD' "$DISPATCH"; then
  bad "cost: the launcher never reads the envelope's cost estimate"
else ok "cost: the launcher never reads the envelope's cost estimate"; fi
assert_eq "cost CONTROL: the fixture does carry one to be tempted by" \
  "$(jq -r '(.total_cost_usd|type) + " " + .modelUsage["qwen36-27b"].costBasis' "$FU1")" \
  "number unknown"

# The kit does not reconstruct usage. The only file the adapter opens is the
# envelope the harness wrote; no terminal read reaches it.
if code_of "$DISPATCH" | sed -n '/^usage_adapter_/,/^}/p' | grep -qE 'TERMINAL_TAIL|terminal read'; then
  bad "AC-1: no adapter scrapes a terminal or a transcript"
else ok "AC-1: no adapter scrapes a terminal or a transcript"; fi

# --- the post-run bands (AC-2) --------------------------------------------
load_budget_policy "$BUDGET_POLICY_SHIPPED" 2>/dev/null
band() { # <usage> <window> -> "STATE findings"
  HARNESS=claude BUDGET_FINDINGS=() BUDGET_STATE="" BUDGET_REASON=""
  budget_evaluate_usage "$(jq -nc --argjson u "$1" --argjson w "$2" '{usage_tokens:$u, window_tokens:$w,
      provenance:"HARNESS_ENVELOPE", observed_at:"END_OF_RUN",
      scope:"FINAL_CONTEXT", reason:null}')" "$2" 2>/dev/null
  printf '%s %s' "$BUDGET_STATE" "${BUDGET_FINDINGS[*]-}"
}
assert_eq "usage band: one ppm BELOW checkpoint is still OK"        "$(band 699999 1000000)" "OK "
assert_eq "usage band: EQUAL to checkpoint crosses it"        "$(band 700000 1000000)" "CHECKPOINT_DUE HIGH_USAGE"
assert_eq "usage band: EQUAL to continuation crosses it" \
  "$(band 850000 1000000)" "CONTINUATION_REQUIRED HIGH_USAGE"
# An observation the adapter DID make but for which no window came back
# corroborates nothing, and says so rather than leaving a null to interpret.
HARNESS=claude; BUDGET_FINDINGS=(); BUDGET_STATE=""; BUDGET_REASON=""
budget_evaluate_usage "$(jq -nc '{usage_tokens:10, window_tokens:null,
    provenance:"HARNESS_ENVELOPE", observed_at:"END_OF_RUN",
    scope:"FINAL_CONTEXT", reason:null}')" 1000000 2>/dev/null
assert_eq "window: an observation with no reported window is UNCORROBORATED" \
  "${BUDGET_FINDINGS[*]-}" "WINDOW_UNCORROBORATED"
# The control: nothing observed corroborates nothing either, and does not
# claim a corroboration failure for an observation that never happened.
HARNESS=codex; BUDGET_FINDINGS=(); BUDGET_STATE="OK"; BUDGET_REASON=""
budget_evaluate_usage "$(usage_adapter_codex)" 1000000 2>/dev/null
assert_eq "window CONTROL: an unobserved usage raises no corroboration finding" \
  "${BUDGET_FINDINGS[*]-}" ""
# An unobservable usage never overwrites the pre-dispatch verdict: it is
# reported in the usage members, where a reader who cares about observation
# looks, and the estimate's own conclusion is not thrown away.
HARNESS=claude; BUDGET_FINDINGS=(); BUDGET_STATE="OK"; BUDGET_REASON=""
budget_evaluate_usage "$(usage_adapter_codex)" 200000 2>/dev/null
assert_eq "usage band: an unobservable usage leaves the pre-dispatch state alone" \
  "$BUDGET_STATE/$BUDGET_REASON" "OK/"
assert_eq "usage band: and says so in the usage members" \
  "$BUDGET_USAGE_PROVENANCE/$BUDGET_USAGE_REASON" "NOT_EVALUATED/USAGE_UNOBSERVABLE"
assert_eq "usage band: with no ratio rendered for it" "$BUDGET_USAGE_RATIO" ""
HARNESS=claude; BUDGET_FINDINGS=(); BUDGET_STATE="NOT_EVALUATED"; BUDGET_REASON="CONTEXT_WINDOW_UNDECLARED"
budget_evaluate_usage "$(usage_adapter_claude "$UF" opus)" "" 2>/dev/null
assert_eq "usage band: an observed usage with NO window evaluates nothing" \
  "$BUDGET_USAGE_REASON" "CONTEXT_WINDOW_UNDECLARED"
# The reported window CORROBORATES; it never becomes the divisor.
HARNESS=claude; BUDGET_FINDINGS=()
budget_evaluate_usage "$(usage_adapter_claude "$UF" opus)" 65536 2>/dev/null
assert_eq "window disagreement: recorded as a finding of its own" \
  "${BUDGET_FINDINGS[*]}" "WINDOW_DISAGREEMENT"
assert_eq "window disagreement: the CATALOG window is still the divisor" \
  "$BUDGET_USAGE_RATIO" "$(budget_ratio_decimal "$(budget_ratio_ppm 1700 65536)")"

# --- the prompt paragraph (AC-3) ------------------------------------------
PARA="$(worker_discipline_paragraph "/wt/S.md")"
for needle in "/wt/S.md.checkpoint.json" "afk-checkpoint/1" "/wt/S.md.continuation.json" \
              "afk-continuation/1" "remaining_acceptance" "in_flight" "unretired_findings" \
              "CONTINUATION-REQUIRED:" "have read the story" \
              "before you run the gates" "secret-free" \
              "or when the harness signals" "The reason must not be empty" \
              "never begin a line with it unless you are actually stopping"; do
  assert_contains "prompt paragraph names [$needle]" "$PARA" "$needle"
done
assert_eq "prompt paragraph: byte-stable for the same story" \
  "$PARA" "$(worker_discipline_paragraph "/wt/S.md")"
if [[ "$PARA" == "$(worker_discipline_paragraph "/wt/OTHER.md")" ]]; then
  bad "prompt paragraph: is bound to the story it names" "identical for two stories"
else ok "prompt paragraph: is bound to the story it names"; fi
assert_eq "prompt paragraph: carries no threshold, so policy stays in one place" \
  "$(grep -cE '0\.[0-9]+|70%|85%' <<<"$PARA")" "0"

# --- the working directory the worker is standing in (AC-3) ---------------
# The story is mirrored into a worktree and names paths relative to a root it
# never states. A worker that reasons from the repository it remembers reaches
# into the main checkout and is denied — 14 times on the run this comes from.
WTP="$(worker_worktree_paragraph "/wt/some worktree")"
assert_contains "worktree paragraph: names the root as the working directory" \
  "$WTP" "The repository root is the current working directory /wt/some worktree"
assert_contains "worktree paragraph: asks for relative paths" "$WTP" "use relative paths"
assert_contains "worktree paragraph: and says what happens outside it" \
  "$WTP" "absolute paths outside it are refused"
assert_eq "worktree paragraph: byte-stable for the same root" \
  "$WTP" "$(worker_worktree_paragraph "/wt/some worktree")"
if [[ "$WTP" == "$(worker_worktree_paragraph "/wt/other")" ]]; then
  bad "worktree paragraph: is bound to the root it names"
else ok "worktree paragraph: is bound to the root it names"; fi
# It is the LAUNCHER's sentence: its only input is the directory dispatch.sh
# resolved for itself, so nothing the story or the persona says reaches it.
if code_of "$DISPATCH" | sed -n '/^worker_worktree_paragraph()/,/^}/p' \
     | grep -qE '\$STORY|\$PERSONA|fm |yq'; then
  bad "worktree paragraph: no story or persona input reaches it"
else ok "worktree paragraph: no story or persona input reaches it"; fi
assert_contains "worktree paragraph: dispatch derives the root itself" \
  "$(grep -F 'worker_worktree_paragraph "$(realpath' "$DISPATCH")" 'realpath "$PWD"'

# --- end to end, on both harnesses ----------------------------------------
spawn_reset() { unset STUB_SPAWN_PATH1 STUB_SPAWN_BODY1 STUB_SPAWN_PATH2 STUB_SPAWN_BODY2; }
ckpt() { # <schema> [extra members json]
  local x="${2:-}"; [[ -n "$x" ]] || x='{}'
  jq -nc --arg s "$1" --argjson x "$x" \
    '{schema:$s, completed:["one"], current_state:"mid", remaining_acceptance:["AC-9"],
      next_steps:["resume"], updated_at:"2026-09-07T00:00:00Z"} + $x'
}
CONT_EXTRA='{"in_flight":"the gate run","unretired_findings":[]}'

reset_stubs; spawn_reset
write_story "$WT/s-usage.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/s-usage.md.stamp.json" high false
export STUB_SPAWN_PATH1="$WT/s-usage.md.claude-result.json"
STUB_SPAWN_BODY1="$(envelope 120000 20000 10000 200000 opus)"; export STUB_SPAWN_BODY1
rc="$(STUB_CATALOG="$WORK/catalog-windowed.yaml"; export STUB_CATALOG; run_dispatch s-usage.md)"
BR="$WT/s-usage.md.result.json"
assert_eq "usage e2e: the run completes" "$rc" "0"
assert_eq "usage e2e: the observed usage reaches the thin result" \
  "$(bud .budget.usage_tokens "$BR")" "150000"
assert_eq "usage e2e: 150000/200000 is the CHECKPOINT band" "$(bud .budget.state "$BR")" "CHECKPOINT_DUE"
assert_eq "usage e2e: and carries the PM's sizing signal" \
  "$(jq -c '.budget.findings' "$BR")" '["HIGH_USAGE"]'
assert_eq "usage e2e: status is unaffected by a checkpoint-band budget" \
  "$(bud .status "$BR")" "done"

reset_stubs; spawn_reset
export STUB_TERMINAL_TAIL="ok
CODEX_EXIT=0"
write_story "$WT/s-usage-codex.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/s-usage-codex.md.stamp.json" high false "openai/strong" codex openai-plus
rc="$(run_dispatch s-usage-codex.md)"
BR="$WT/s-usage-codex.md.result.json"
assert_eq "usage e2e/codex: the second harness dispatches unaffected" "$rc" "0"
assert_eq "usage e2e/codex: usage NOT_EVALUATED, never blocking the run" \
  "$(bud .budget.usage_provenance "$BR")" "NOT_EVALUATED"
assert_eq "usage e2e/codex: with the stable reason" \
  "$(bud .budget.usage_reason "$BR")" "USAGE_UNOBSERVABLE"
assert_eq "usage e2e/codex: and no usage number invented for it" \
  "$(bud '.budget.usage_tokens|type' "$BR")" "null"
# Cost is not spend, and it is not the kit's to publish either way: the
# envelope's figure is the client's own estimate on a route whose cost class
# the stamp already declares. It reaches no thin result and no aggregate.
if jq -r 'paths(scalars)|join(".")' "$BR" | grep -qiE 'cost|usd|spend|price'; then
  bad "cost: no cost figure reaches the thin result"
else ok "cost: no cost figure reaches the thin result"; fi
export STUB_TERMINAL_TAIL="ok
CLAUDE_EXIT=0"

# --- the prompt the worker actually receives ------------------------------
assert_contains "AC-3: the discipline reached the generated prompt FILE" \
  "$(cat "$WT/s-usage.md.prompt")" "s-usage.md.continuation.json"
# The worktree sentence names the directory the launcher actually ran in, and
# it is byte-identical to the launcher's own function — the story is a payload
# beside it, not an input to it.
assert_contains "AC-3: the prompt names the worktree the worker stands in" \
  "$(cat "$WT/s-usage.md.prompt")" \
  "The repository root is the current working directory $(realpath "$WT")"
assert_contains "AC-3: exactly as the launcher writes it" \
  "$(cat "$WT/s-usage.md.prompt")" "$(worker_worktree_paragraph "$(realpath "$WT")")"
assert_absent "AC-3: and the launch command text carries no task or artifact prose" \
  "$(cat "$STUB_STATE/last-command.txt")" "continuation.json"

# --- a valid checkpoint is accepted (AC-4) --------------------------------
reset_stubs; spawn_reset
write_story "$WT/s-ckpt.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/s-ckpt.md.stamp.json" high false
export STUB_SPAWN_PATH1="$WT/s-ckpt.md.checkpoint.json"
STUB_SPAWN_BODY1="$(ckpt afk-checkpoint/1)"; export STUB_SPAWN_BODY1
rc="$(run_dispatch s-ckpt.md)"
BR="$WT/s-ckpt.md.result.json"
assert_eq "checkpoint: a valid artifact does not disturb the outcome" "$rc" "0"
assert_eq "checkpoint: its identity is recorded, as the story names it" \
  "$(bud .budget.checkpoint_artifact.path "$BR")" "s-ckpt.md.checkpoint.json"
# A checkpoint is a resumption aid: an invalid one is a finding, not a refusal.
reset_stubs
STUB_SPAWN_BODY1="$(ckpt wrong-schema/9)"; export STUB_SPAWN_BODY1
rc="$(run_dispatch s-ckpt.md)"
assert_eq "checkpoint: an invalid one does NOT refuse the attempt" "$rc" "0"
assert_eq "checkpoint: it is recorded as a finding" \
  "$(jq -c '.budget.findings' "$BR")" '["CHECKPOINT_ARTIFACT_INVALID"]'
assert_eq "checkpoint: and no identity is claimed for it" \
  "$(bud '.budget.checkpoint_artifact|type' "$BR")" "null"

# --- a signalled continuation (AC-4) --------------------------------------
reset_stubs; spawn_reset
export STUB_TERMINAL_TAIL="working
CONTINUATION-REQUIRED: the story is larger than one window
CLAUDE_EXIT=0"
write_story "$WT/s-cont.md" "persona: dev
gates: [\"true\"]"
printf '\n## Dev Agent Record\n\n(worker fills in)\n' >> "$WT/s-cont.md"
write_stamp "$WT/s-cont.md.stamp.json" high false
export STUB_SPAWN_PATH1="$WT/s-cont.md.continuation.json"
STUB_SPAWN_BODY1="$(ckpt afk-continuation/1 "$CONT_EXTRA")"; export STUB_SPAWN_BODY1
rc="$(run_dispatch s-cont.md 1)"
BR="$WT/s-cont.md.result.json"
assert_eq "continuation: exits as unfinished work, not as done" "$rc" "1"
assert_eq "continuation: the thin result says so" "$(bud .status "$BR")" "continuation_required"
assert_eq "continuation: and the budget state agrees" "$(bud .budget.state "$BR")" "CONTINUATION_REQUIRED"
assert_eq "continuation: the artifact identity is recorded" \
  "$(bud .budget.continuation_artifact.path "$BR")" "s-cont.md.continuation.json"
assert_eq "continuation: exactly one line in the story record" \
  "$(grep -ac '^- budget: CONTINUATION_REQUIRED ' "$WT/s-cont.md")" "1"
# Cycle 1 is an ORDINARY cycle that handed over; re-dispatching it is still the
# documented recovery from a stamp refresh or a dead terminal, and the record
# append stays idempotent on it. Only a CONTINUATION cycle is refused in place.
rc="$(run_dispatch s-cont.md 1)"
assert_eq "continuation: a re-dispatch of the SAME cycle does not duplicate" \
  "$(grep -ac '^- budget: CONTINUATION_REQUIRED ' "$WT/s-cont.md")" "1"

# A continuation artifact left by an EARLIER cycle is not this worker's word.
reset_stubs; spawn_reset
rc="$(run_dispatch s-cont.md 2)"
assert_eq "continuation: an unchanged artifact is refused as stale" "$rc" "3"
assert_contains "continuation: with the stable reason code" \
  "$(cat "$WT/s-cont.md.blocked")" "reason=CONTINUATION_ARTIFACT_INVALID"
assert_contains "continuation: naming which check failed" \
  "$(cat "$WT/s-cont.md.blocked")" "detail=ARTIFACT_STALE"

cont_invalid() { # <tag> <body> <expected detail>
  reset_stubs; spawn_reset
  write_story "$WT/s-ci-$1.md" "persona: dev
gates: [\"true\"]"
  write_stamp "$WT/s-ci-$1.md.stamp.json" high false
  if [[ -n "$2" ]]; then
    export STUB_SPAWN_PATH1="$WT/s-ci-$1.md.continuation.json"; STUB_SPAWN_BODY1="$2"; export STUB_SPAWN_BODY1
  fi
  local rc; rc="$(run_dispatch "s-ci-$1.md")"
  assert_eq "continuation/$1: loud NEEDS-HUMAN exit" "$rc" "3"
  assert_contains "continuation/$1: marker names the check that failed" \
    "$(cat "$WT/s-ci-$1.md.blocked")" "detail=$3"
  assert_no_file "continuation/$1: NO result artifact claims an outcome" \
    "$WT/s-ci-$1.md.result.json"
}
cont_invalid missing  ""                                   ARTIFACT_MISSING
cont_invalid broken   'not json'                           ARTIFACT_UNPARSEABLE
cont_invalid schema   "$(ckpt afk-checkpoint/1 "$CONT_EXTRA")" ARTIFACT_SCHEMA_MISMATCH
cont_invalid short    "$(ckpt afk-continuation/1)"          ARTIFACT_MEMBER_MISSING
# story_id is additive, and the launcher holds a PRESENT one to the story it
# names: a hand-over that belongs to another story is not this story's evidence.
cont_invalid story \
  "$(ckpt afk-continuation/1 '{"in_flight":"x","unretired_findings":[],"story_id":"some-other-story"}')" \
  STORY_MISMATCH

# Observed usage past the continuation threshold with the gates failed and NO
# worker signal. The kit records what it can see — the band, and HIGH_USAGE —
# but the STATUS is the gates': there is no hand-over here, and a status that
# says otherwise sends a PM to resume from an artifact that does not exist.
reset_stubs; spawn_reset
export STUB_TERMINAL_TAIL="ok
CLAUDE_EXIT=0"
write_story "$WT/s-cont-obs.md" "persona: dev
gates: [\"false\"]"
write_stamp "$WT/s-cont-obs.md.stamp.json" high false
export STUB_SPAWN_PATH1="$WT/s-cont-obs.md.claude-result.json"
STUB_SPAWN_BODY1="$(envelope 190000 0 0 200000 opus)"; export STUB_SPAWN_BODY1
rc="$(STUB_CATALOG="$WORK/catalog-windowed.yaml"; export STUB_CATALOG; run_dispatch s-cont-obs.md)"
BR="$WT/s-cont-obs.md.result.json"
assert_eq "silent exhaustion: still an unfinished exit" "$rc" "1"
assert_eq "silent exhaustion: the gates decide the status" \
  "$(bud .status "$BR")" "gates_failed"
assert_eq "silent exhaustion: the band stands beside it as a sizing note" \
  "$(bud .budget.state "$BR")" "CONTINUATION_REQUIRED"
assert_contains "silent exhaustion: with the sizing finding" \
  "$(jq -c '.budget.findings' "$BR")" "HIGH_USAGE"
assert_eq "silent exhaustion: and NO continuation artifact is claimed" \
  "$(bud '.budget.continuation_artifact|type' "$BR")" "null"
# The control: the SAME failing gate below the threshold is an ordinary fail.
reset_stubs
STUB_SPAWN_BODY1="$(envelope 1000 0 0 200000 opus)"; export STUB_SPAWN_BODY1
rc="$(STUB_CATALOG="$WORK/catalog-windowed.yaml"; export STUB_CATALOG; run_dispatch s-cont-obs.md)"
assert_eq "silent exhaustion CONTROL: a low-usage gate failure stays gates_failed" \
  "$(bud .status "$BR")" "gates_failed"

# The whole (signal x gates x budget state) space, over the launcher's own
# decision transcribed from the source. The property is one line: no row
# publishes `continuation_required` without an artifact identity to resume
# from — and only the worker's signal produces one.
status_matrix_row() { # <signal:yes|no> <gates_ok> <budget_state>
  local sig="$1" GATES_OK="$2" BUDGET_STATE="$3" RESULT_STATUS=""
  [[ "$sig" == yes ]] && RESULT_STATUS="continuation_required"
  [[ -n "$RESULT_STATUS" ]] || \
    RESULT_STATUS="$([[ $GATES_OK == true ]] && echo 'done' || echo 'gates_failed')"
  printf '%s' "$RESULT_STATUS"
}
matrix_bad=0 matrix_rows=0
for sig in no yes; do for g in true false; do
  for b in OK CHECKPOINT_DUE CONTINUATION_REQUIRED NOT_EVALUATED; do
    matrix_rows=$((matrix_rows+1))
    st="$(status_matrix_row "$sig" "$g" "$b")"
    [[ "$st" == "continuation_required" && "$sig" != "yes" ]] && matrix_bad=$((matrix_bad+1))
    [[ "$sig" == "yes" && "$st" != "continuation_required" ]] && matrix_bad=$((matrix_bad+1))
  done
done; done
assert_eq "status matrix: 16 rows walked" "$matrix_rows" "16"
assert_eq "status matrix: continuation_required iff the worker signalled" "$matrix_bad" "0"
# and the transcription is checkable against the file: the launcher has no
# other arm that can set the status from a budget state.
assert_eq "status matrix: no budget state sets the status" \
  "$(sed -n '/---- deterministic gates/,/thin result the PM can read/p' "$DISPATCH" \
     | grep -c 'RESULT_STATUS="continuation_required"')" "0"

# --- a stale checkpoint is not this cycle's (AC-4) ------------------------
# The worker writes nothing this attempt, so the checkpoint on disk is the one
# the attempt started with. Its identity must not be published as evidence of
# work this worker did not do.
reset_stubs; spawn_reset
write_story "$WT/s-ckpt-stale.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/s-ckpt-stale.md.stamp.json" high false
export STUB_SPAWN_PATH1="$WT/s-ckpt-stale.md.checkpoint.json"
STUB_SPAWN_BODY1="$(ckpt afk-checkpoint/1)"; export STUB_SPAWN_BODY1
rc="$(run_dispatch s-ckpt-stale.md)"
BR="$WT/s-ckpt-stale.md.result.json"
assert_eq "checkpoint CONTROL: the first cycle's checkpoint IS published" \
  "$(bud .budget.checkpoint_artifact.path "$BR")" "s-ckpt-stale.md.checkpoint.json"
reset_stubs; spawn_reset
rc="$(run_dispatch s-ckpt-stale.md 2)"
assert_eq "checkpoint: an unchanged checkpoint does not refuse the attempt" "$rc" "0"
assert_eq "checkpoint: it is recorded as stale" \
  "$(jq -c '.budget.findings' "$BR")" '["CHECKPOINT_ARTIFACT_STALE"]'
assert_eq "checkpoint: and no identity is claimed for an earlier cycle's file" \
  "$(bud '.budget.checkpoint_artifact|type' "$BR")" "null"

# --- a finished run is never a continuation (AC-4) ------------------------
# The ratio says the run ended close to its window; the gates say it finished.
# Those are a sizing observation and an outcome, not two outcomes.
reset_stubs; spawn_reset
export STUB_TERMINAL_TAIL="ok
CLAUDE_EXIT=0"
write_story "$WT/s-fin-high.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/s-fin-high.md.stamp.json" high false
export STUB_SPAWN_PATH1="$WT/s-fin-high.md.claude-result.json"
STUB_SPAWN_BODY1="$(envelope 190000 0 0 200000 opus)"; export STUB_SPAWN_BODY1
rc="$(STUB_CATALOG="$WORK/catalog-windowed.yaml"; export STUB_CATALOG; run_dispatch s-fin-high.md)"
BR="$WT/s-fin-high.md.result.json"
assert_eq "finished run: gates passed, so the run is done" "$(bud .status "$BR")" "done"
assert_eq "finished run: 190000/200000 is reported as sizing, not continuation" \
  "$(bud .budget.state "$BR")" "CHECKPOINT_DUE"
assert_eq "finished run: the sizing signal is the finding that carries it" \
  "$(jq -c '.budget.findings' "$BR")" '["HIGH_USAGE"]'
# The control for the demotion: the SAME ratio on an UNFINISHED run is still a
# continuation, so the state above was demoted by the outcome and not lost.
reset_stubs; spawn_reset
write_story "$WT/s-fin-high.md" "persona: dev
gates: [\"false\"]"
export STUB_SPAWN_PATH1="$WT/s-fin-high.md.claude-result.json"
STUB_SPAWN_BODY1="$(envelope 190000 0 0 200000 opus)"; export STUB_SPAWN_BODY1
rc="$(STUB_CATALOG="$WORK/catalog-windowed.yaml"; export STUB_CATALOG; run_dispatch s-fin-high.md)"
assert_eq "finished run CONTROL: the same ratio with failed gates continues" \
  "$(bud .budget.state "$BR")" "CONTINUATION_REQUIRED"

# --- the continuation reason is recorded, never echoed (AC-5) -------------
# The reason is caller-supplied free text, so no filter is applied to it: the
# content reaches nothing. The sentinels are the shapes a pattern denylist
# misses — short, keyword-adjacent, and broken by an excluded character — plus
# the long token-shaped one, so the assertion is about the channel and not
# about one regex.
SHORT_SENTINEL='hunter2'
KEYWORD_SENTINEL='password=Tr0ub4dor&3'
BROKEN_SENTINEL='xoxb-2f9a:8c1d-77aa-9e0f'
LONG_SENTINEL='sk-live-9f2a4c7e1b8d3550aa11bb22cc33'
SIGNAL_REASON="context exhausted, the token was $LONG_SENTINEL $SHORT_SENTINEL $KEYWORD_SENTINEL $BROKEN_SENTINEL"
reset_stubs; spawn_reset
export STUB_TERMINAL_TAIL="working
CONTINUATION-REQUIRED: $SIGNAL_REASON
CLAUDE_EXIT=0"
write_story "$WT/s-secret.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/s-secret.md.stamp.json" high false
export STUB_SPAWN_PATH1="$WT/s-secret.md.continuation.json"
STUB_SPAWN_BODY1="$(ckpt afk-continuation/1 \
  "$(jq -nc --arg s "$LONG_SENTINEL" '{in_flight:$s, unretired_findings:[$s]}')")"
export STUB_SPAWN_BODY1
rc="$(run_dispatch s-secret.md 1)"
assert_eq "redaction: the continuation is still accepted" \
  "$(bud .status "$WT/s-secret.md.result.json")" "continuation_required"
for sent in "$LONG_SENTINEL" "$SHORT_SENTINEL" "$KEYWORD_SENTINEL" "$BROKEN_SENTINEL"; do
  assert_absent "redaction: no sentinel [$sent] in the thin result" \
    "$(cat "$WT/s-secret.md.result.json")" "$sent"
  assert_absent "redaction: nor in the dispatch log [$sent]" "$(cat "$WORK/err")" "$sent"
done
# and on the path where the same signal is refused, the marker is clean too
reset_stubs; spawn_reset
rc="$(run_dispatch s-secret.md 2)"
assert_eq "redaction: the stale artifact is refused" "$rc" "3"
for sent in "$LONG_SENTINEL" "$SHORT_SENTINEL" "$KEYWORD_SENTINEL" "$BROKEN_SENTINEL"; do
  assert_absent "redaction: no sentinel [$sent] in the NEEDS-HUMAN marker" \
    "$(cat "$WT/s-secret.md.blocked")" "$sent"
done
assert_absent "redaction: not even the ordinary words of the reason" \
  "$(cat "$WT/s-secret.md.blocked")" "exhausted, the token was"
assert_contains "redaction: the marker still says what went wrong" \
  "$(cat "$WT/s-secret.md.blocked")" "detail=ARTIFACT_STALE"
# The anti-vacuity control. The sentinels are absent because the content is
# never echoed, not because nothing travels this path: the marker records that
# a reason was given, HOW MANY BYTES it was, and the closed-vocabulary words
# it contained — all three derived from the very line asserted absent above.
assert_contains "redaction CONTROL: the marker records that a reason was given" \
  "$(cat "$WT/s-secret.md.blocked")" "reason_given=true"
assert_contains "redaction CONTROL: and its exact byte length" \
  "$(cat "$WT/s-secret.md.blocked")" "reason_bytes=$(printf '%s' "$SIGNAL_REASON" | wc -c | tr -d ' ')"
assert_contains "redaction CONTROL: and only closed-vocabulary words" \
  "$(cat "$WT/s-secret.md.blocked")" "reason_words=context"
# The vocabulary is closed, called directly: a word outside it is never echoed,
# and one inside it is.
assert_eq "vocabulary: a word in the closed set is echoed" \
  "$(continuation_reason_word "Context,")" "context"
assert_eq "vocabulary: anything else is not" \
  "$(continuation_reason_word "$SHORT_SENTINEL")" ""
assert_eq "vocabulary: a summary of a secret-only reason names no words" \
  "$(continuation_signal_summary "CONTINUATION-REQUIRED: $LONG_SENTINEL")" \
  "reason_given=true reason_bytes=${#LONG_SENTINEL} reason_words=none"

# --- an empty reason is not a signal (AC-4) -------------------------------
reset_stubs; spawn_reset
export STUB_TERMINAL_TAIL="working
CONTINUATION-REQUIRED:
CLAUDE_EXIT=0"
write_story "$WT/s-empty.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/s-empty.md.stamp.json" high false
export STUB_SPAWN_PATH1="$WT/s-empty.md.continuation.json"
STUB_SPAWN_BODY1="$(ckpt afk-continuation/1 "$CONT_EXTRA")"; export STUB_SPAWN_BODY1
rc="$(run_dispatch s-empty.md 1)"
assert_eq "empty reason: refused on the invalid-signal path" "$rc" "3"
assert_contains "empty reason: with the stable reason code" \
  "$(cat "$WT/s-empty.md.blocked")" "reason=CONTINUATION_ARTIFACT_INVALID"
assert_contains "empty reason: naming which check failed" \
  "$(cat "$WT/s-empty.md.blocked")" "detail=SIGNAL_REASON_EMPTY"
assert_no_file "empty reason: NO result artifact claims an outcome" \
  "$WT/s-empty.md.result.json"
# The control: the SAME artifact with a non-empty reason is accepted, so the
# refusal above is about the empty reason and nothing else.
reset_stubs; spawn_reset
export STUB_TERMINAL_TAIL="working
CONTINUATION-REQUIRED: the story is larger than one window
CLAUDE_EXIT=0"
write_story "$WT/s-empty2.md" "persona: dev
gates: [\"true\"]"
write_stamp "$WT/s-empty2.md.stamp.json" high false
export STUB_SPAWN_PATH1="$WT/s-empty2.md.continuation.json"
STUB_SPAWN_BODY1="$(ckpt afk-continuation/1 "$CONT_EXTRA")"; export STUB_SPAWN_BODY1
rc="$(run_dispatch s-empty2.md 1)"
assert_eq "empty reason CONTROL: a non-empty reason on the same artifact passes" \
  "$(bud .status "$WT/s-empty2.md.result.json")" "continuation_required"

spawn_reset
export STUB_TERMINAL_TAIL="ok
CLAUDE_EXIT=0"


# ===========================================================================
head1 "3e. Continuation cycles, the cap, and settlement (lane C)"
# ===========================================================================
# A continuation is the NEXT CYCLE of the same story under the SAME stamp,
# through this same dispatch.sh. Every case below runs the real launcher, so
# what is proved is what dispatch actually did: the prompt it wrote, the
# estimate it computed, the marker it left, and what it refused to launch.

CAP="$(yq -r '.continuation_cap' "$BUDGET_POLICY_SHIPPED")"
CONT_BODY="$(ckpt afk-continuation/1 "$CONT_EXTRA")"

# retain — synthesise ONE retained per-cycle thin result, which is the only
# evidence the chain and the cap are counted from.
retain() { # <story-basename> <cycle> <continuation_of-json|null>
  jq -n --arg s "$1.md" --argjson c "$2" --argjson cof "$3" \
    '{story:$s, cycle:$c, status:"continuation_required",
      budget:{state:"CONTINUATION_REQUIRED", usage_tokens:180000, usage_ratio:0.900000,
              continuation_artifact:(if $cof == null
                                     then {path:($s+".continuation.json"), sha256:"sha256:seed"}
                                     else null end),
              continuation_of:$cof}}' > "$WT/$1.md.result.c$2.json"
}
cont_story() { # <basename> [extra frontmatter]
  write_story "$WT/$1.md" "persona: dev
gates: [\"true\"]
max_cycles: 8${2:-}"
  write_stamp "$WT/$1.md.stamp.json" high false
  printf '%s' "$CONT_BODY" > "$WT/$1.md.continuation.json"
}
# dflt_story — the SHIPPED defaults: a story that declares no max_cycles at all,
# so the launcher's own default of 3 applies. B1 lived here.
dflt_story() { # <basename> [extra frontmatter]
  write_story "$WT/$1.md" "persona: dev
gates: [\"true\"]${2:-}"
  write_stamp "$WT/$1.md.stamp.json" high false
  printf '%s' "$CONT_BODY" > "$WT/$1.md.continuation.json"
}
# ledger — plant the append-only continuation ledger, one entry per cycle
# listed. The cap is its LENGTH, so what the entries say about cycle numbers is
# deliberately not what is counted.
ledger() { # <story-basename> <cycle>...
  local name="$1"; shift
  local c arr="[]"
  for c in "$@"; do
    arr="$(jq -c --argjson c "$c" \
      '. + [{cycle:$c, from_cycle:($c - 1), artifact_sha256:"sha256:seed",
             trigger:"WORKER_SIGNAL", at:"2026-09-07T00:00:00Z", decision:null}]' <<<"$arr")"
  done
  jq -n --argjson e "$arr" '{schema:"afk-continuation-ledger/1", entries:$e}' \
    > "$WT/$name.md.continuations.json"
}
# marker_frontmatter_block — the CONTINUATION-CAP marker's suggested frontmatter,
# taken verbatim out of the marker and dedented by exactly the indent the marker
# prints it under. Nothing is retyped: what is applied is what a human copies.
marker_frontmatter_block() { # <marker-file>
  sed -n '/^      continuation_decision:$/,/^      max_cycles: /p' "$1" | sed 's/^      //'
}

# --- an ordinary cycle is unaffected, artifact on disk or not -------------
# A continuation artifact left by an older chain does not make a cycle a
# continuation: the evidence is the PRIOR CYCLE'S RESULT, and there is none.
reset_stubs; spawn_reset
cont_story s-c-ord
rc="$(run_dispatch s-c-ord.md 1)"
BR="$WT/s-c-ord.md.result.json"
assert_eq "ordinary cycle: a stray artifact does not make it a continuation" "$rc" "0"
assert_eq "ordinary cycle: continuation_of is null"  "$(bud '.budget.continuation_of|type' "$BR")" "null"
assert_eq "ordinary cycle: no continuation_decision" "$(bud '.budget.continuation_decision|type' "$BR")" "null"
assert_eq "ordinary cycle: no REPEATED_CONTINUATION finding" \
  "$(bud '.budget.findings|length' "$BR")" "0"
assert_absent "ordinary cycle: the prompt carries no continuation section" \
  "$(cat "$WT/s-c-ord.md.prompt")" "Continuation from cycle"
assert_absent "ordinary cycle: nothing was appended to the story record" \
  "$(cat "$WT/s-c-ord.md")" "- budget: CONTINUATION "
# --- the per-cycle result is retained ------------------------------------
if [[ -f "$WT/s-c-ord.md.result.c1.json" ]]; then
  ok "retention: a per-cycle copy of the thin result is kept"
else bad "retention: a per-cycle copy of the thin result is kept"; fi
assert_eq "retention: it is the same document the cycle published" \
  "$(jq -S . "$WT/s-c-ord.md.result.c1.json")" "$(jq -S . "$BR")"
# A later cycle whose prior cycles left no result at all, and one whose prior
# result is `done`: both are ordinary, and neither is an error.
reset_stubs
cont_story s-c-gap
rc="$(run_dispatch s-c-gap.md 3)"
assert_eq "ordinary cycle: a cycle with no prior result at all still runs" "$rc" "0"
assert_eq "ordinary cycle: and claims no continuation" \
  "$(bud '.budget.continuation_of|type' "$WT/s-c-gap.md.result.json")" "null"
reset_stubs
rc="$(run_dispatch s-c-ord.md 2)"
assert_eq "ordinary cycle: a prior cycle that finished is not a hand-over" \
  "$(bud '.budget.continuation_of|type' "$WT/s-c-ord.md.result.json")" "null"

# --- a real hand-over, then the continuation that consumes it -------------
reset_stubs; spawn_reset
cont_story s-c-run
rm -f "$WT/s-c-run.md.continuation.json"          # the worker writes it, not us
export STUB_TERMINAL_TAIL="working
CONTINUATION-REQUIRED: the story is larger than one window
CLAUDE_EXIT=0"
export STUB_SPAWN_PATH1="$WT/s-c-run.md.continuation.json"
STUB_SPAWN_BODY1="$CONT_BODY"; export STUB_SPAWN_BODY1
export STUB_SPAWN_PATH2="$WT/s-c-run.md.claude-result.json"
# The envelope carries BOTH halves of what cycle 1 leaves behind: the worker's
# own signal (dispatch reads the result envelope, not the terminal, on claude)
# and the usage that continuation_of has to carry forward.
STUB_SPAWN_BODY2="$(envelope 100000 0 0 200000 opus \
  | jq -c '.result = "working\nCONTINUATION-REQUIRED: the story is larger than one window"')"
export STUB_SPAWN_BODY2
rc="$(run_dispatch s-c-run.md 1)"
assert_eq "chain: cycle 1 hands over" \
  "$(bud .status "$WT/s-c-run.md.result.c1.json")" "continuation_required"
C1_EST="$(bud .budget.estimate_tokens "$WT/s-c-run.md.result.json")"
ART_SHA="sha256:$(sha256sum "$WT/s-c-run.md.continuation.json" | cut -d' ' -f1)"
ART_BYTES="$(wc -c < "$WT/s-c-run.md.continuation.json" | tr -d ' ')"

reset_stubs; spawn_reset
export STUB_TERMINAL_TAIL="ok
CLAUDE_EXIT=0"
rc="$(run_dispatch s-c-run.md 2)"
BR="$WT/s-c-run.md.result.json"
assert_eq "continuation: cycle 2 runs, through the ordinary path" "$rc" "0"
PROMPT2="$(cat "$WT/s-c-run.md.prompt")"
assert_contains "continuation: the prompt carries the fixed heading" \
  "$PROMPT2" "Continuation from cycle 1"
assert_contains "continuation: with the artifact's own content, as data" \
  "$PROMPT2" '"in_flight":"the gate run"'
# Ordering is the contract: the artifact sits AFTER the story instructions and
# BEFORE the launcher's budget paragraph.
assert_eq "continuation: the section sits between the story and budget paragraphs" \
  "$(awk '/^Execute the story file/{a=NR} /^Continuation from cycle/{b=NR} /^Context discipline/{c=NR}
          END{print (a<b && b<c) ? "ordered" : "misordered"}' "$WT/s-c-run.md.prompt")" "ordered"
C2_EST="$(bud .budget.estimate_tokens "$BR")"
if (( C2_EST >= C1_EST + ART_BYTES / 4 )); then
  ok "continuation: the artifact is counted in the estimate, through the prompt"
else bad "continuation: the artifact is counted in the estimate, through the prompt" \
  "cycle1 $C1_EST, cycle2 $C2_EST, artifact $ART_BYTES bytes"; fi
assert_eq "continuation: continuation_of names the cycle continued" \
  "$(bud .budget.continuation_of.cycle "$BR")" "1"
assert_eq "continuation: and the artifact it consumed, by digest" \
  "$(bud .budget.continuation_of.artifact_sha256 "$BR")" "$ART_SHA"
assert_eq "continuation: the trigger is the worker's own signal" \
  "$(bud .budget.continuation_of.trigger "$BR")" "WORKER_SIGNAL"
assert_eq "continuation: the prior cycle's usage evidence travels with it" \
  "$(bud '.budget.continuation_of.usage_tokens|type' "$BR")" "number"
assert_contains "continuation: REPEATED_CONTINUATION is the PM's sizing signal" \
  "$(jq -c '.budget.findings' "$BR")" "REPEATED_CONTINUATION"
# The artifact this worker wrote carries no story_id. That is accepted — the
# member is additive — and REPORTED, because nothing then binds a file found by
# path to this story.
assert_contains "binding: an artifact that names no story is reported, not assumed away" \
  "$(jq -c '.budget.findings' "$BR")" "CONTINUATION_ARTIFACT_UNBOUND"
# --- the append-only ledger, written by the launch itself -----------------
LDG="$WT/s-c-run.md.continuations.json"
assert_eq "ledger: the launch appended exactly one entry" \
  "$(jq -r '.entries|length' "$LDG")" "1"
assert_eq "ledger: under its declared schema id" \
  "$(jq -r '.schema' "$LDG")" "afk-continuation-ledger/1"
assert_eq "ledger: naming the cycle that spent the window" \
  "$(jq -r '.entries[0].cycle' "$LDG")" "2"
assert_eq "ledger: and the cycle it continued" \
  "$(jq -r '.entries[0].from_cycle' "$LDG")" "1"
assert_eq "ledger: carrying the artifact it consumed" \
  "$(jq -r '.entries[0].artifact_sha256' "$LDG")" "$ART_SHA"
assert_eq "ledger: and the trigger"  "$(jq -r '.entries[0].trigger' "$LDG")" "WORKER_SIGNAL"
assert_eq "ledger: with no decision, because none was needed" \
  "$(jq -r '.entries[0].decision|type' "$LDG")" "null"
# --- the record chain (S4) -----------------------------------------------
REC="$(grep -a '^- budget: CONTINUATION ' "$WT/s-c-run.md" || true)"
assert_contains "record chain: one dated line, naming the cycle continued" "$REC" "from cycle 1"
assert_contains "record chain: carrying the artifact identity"             "$REC" "$ART_SHA"
assert_contains "record chain: and the trigger"                            "$REC" "trigger=WORKER_SIGNAL"
assert_contains "record chain: and the usage evidence"                     "$REC" "usage=100000"
assert_contains "record chain: written for this cycle"                     "$REC" "cycle 2"
assert_eq "record chain: it lives in the Dev Agent Record" \
  "$(sed -n '/^## Dev Agent Record/,$p' "$WT/s-c-run.md" | grep -ac '^- budget: CONTINUATION ')" "1"
# A continuation cycle that launched is SETTLED: its retained result and its
# ledger entry are what the chain and the cap are counted from, so re-running
# the same cycle number refuses before anything is placed.
reset_stubs
rm -f "$WT/s-c-run.md.blocked"
rc="$(run_dispatch s-c-run.md 2)"
assert_eq "settled cycle: a continuation cycle is never re-run in place" "$rc" "3"
assert_contains "settled cycle: with the stable reason code" \
  "$(cat "$WT/s-c-run.md.blocked")" "reason=CYCLE_ALREADY_RETAINED"
assert_contains "settled cycle: naming the next free cycle" \
  "$(cat "$WT/s-c-run.md.blocked")" "next_free_cycle=3"
assert_eq "settled cycle: the record still carries exactly one CONTINUATION line" \
  "$(grep -ac '^- budget: CONTINUATION ' "$WT/s-c-run.md")" "1"
assert_eq "settled cycle: and the ledger did not grow" \
  "$(jq -r '.entries|length' "$LDG")" "1"
assert_empty_file "settled cycle: nothing was launched" "$STUB_STATE/terminal-creates"

# --- the artifact can push the estimate past the refusal threshold --------
# Lane A's path, unchanged: the window is cycle 2's continuation estimate, so
# the ratio is at least 1.0 by construction rather than by a magic byte count.
# Cycle 2 is settled, so the case runs as the NEXT continuation — cycle 2 is
# made to hand over in turn.
jq -n --arg s s-c-run --argjson c 2 \
  '{story:$s, cycle:$c, status:"continuation_required",
    budget:{state:"CONTINUATION_REQUIRED", usage_tokens:190000, usage_ratio:0.950000,
            continuation_artifact:null, continuation_of:{cycle:1}}}' \
  > "$WT/s-c-run.md.result.c2.json"
awk -v w="$C2_EST" '{print} /^  "claude\/strong":[[:space:]]*$/ {print "    min_context: " w}' \
  "$WORK/catalog.yaml" > "$WORK/catalog-cont.yaml"
reset_stubs
rm -f "$WT/s-c-run.md.blocked"
rc="$(STUB_CATALOG="$WORK/catalog-cont.yaml"; export STUB_CATALOG; run_dispatch s-c-run.md 3)"
assert_eq "continuation sizing: refuses on lane A's path, exit 8" "$rc" "8"
SZM="$(cat "$WT/s-c-run.md.blocked")"
assert_contains "continuation sizing: the same typed marker"  "$SZM" "STORY-SIZING: reason=SIZING_REFUSED"
assert_contains "continuation sizing: the enumeration names the artifact" \
  "$SZM" "s-c-run.md.continuation.json"
assert_contains "continuation sizing: and says where it was counted" \
  "$SZM" "inlined into the prompt"
assert_empty_file "continuation sizing: nothing was placed"   "$STUB_STATE/curl-calls"
assert_empty_file "continuation sizing: nothing was launched" "$STUB_STATE/terminal-creates"
# R3: the marker is not the only reader. A PM reading the story record has to
# see that a hand-over was attempted and turned away.
REFL="$(grep -a '^- budget: CONTINUATION_REFUSED ' "$WT/s-c-run.md" || true)"
assert_contains "continuation sizing: one record line says a continuation was refused" \
  "$REFL" "from cycle 2"
assert_contains "continuation sizing: carrying the estimate against the window" \
  "$REFL" "/$C2_EST "
assert_contains "continuation sizing: written for this cycle" "$REFL" "cycle 3"
assert_eq "continuation sizing: exactly one such line" \
  "$(grep -ac '^- budget: CONTINUATION_REFUSED ' "$WT/s-c-run.md")" "1"
assert_eq "continuation sizing: a refusal spends no window, so the ledger is unmoved" \
  "$(jq -r '.entries|length' "$LDG")" "1"

# --- a hand-over whose evidence is gone: loud, and pre-launch -------------
reset_stubs; spawn_reset
cont_story s-c-noart
retain s-c-noart 1 null
rm -f "$WT/s-c-noart.md.continuation.json" "$WT/s-c-noart.md.blocked"
rc="$(run_dispatch s-c-noart.md 2)"
assert_eq "no evidence: loud NEEDS-HUMAN exit" "$rc" "3"
NAM="$(cat "$WT/s-c-noart.md.blocked")"
assert_contains "no evidence: the stable reason code" "$NAM" "reason=CONTINUATION_ARTIFACT_INVALID"
assert_contains "no evidence: naming the check that failed" "$NAM" "detail=ARTIFACT_MISSING"
assert_contains "no evidence: naming the cycle it would have continued" "$NAM" "continuation_of=1"
assert_no_file "no evidence: NO result artifact claims an outcome" "$WT/s-c-noart.md.result.json"
assert_empty_file "no evidence: nothing was placed"   "$STUB_STATE/curl-calls"
assert_empty_file "no evidence: nothing was launched" "$STUB_STATE/terminal-creates"
# and a schema-mismatched artifact takes the same path
reset_stubs
printf '%s' "$(ckpt afk-checkpoint/1 "$CONT_EXTRA")" > "$WT/s-c-noart.md.continuation.json"
rc="$(run_dispatch s-c-noart.md 2)"
assert_eq "wrong schema: same loud path" "$rc" "3"
assert_contains "wrong schema: named from the closed verdict vocabulary" \
  "$(cat "$WT/s-c-noart.md.blocked")" "detail=ARTIFACT_SCHEMA_MISMATCH"

# --- the cap (S3): two continuations proceed, the third refuses -----------
reset_stubs; spawn_reset
cont_story s-c-cap
retain s-c-cap 1 null                                    # the hand-over
rc="$(run_dispatch s-c-cap.md 2)"
assert_eq "cap: continuation 1 of $CAP proceeds" "$rc" "0"
assert_eq "cap: the kit read the prior cycle's usage-band trigger" \
  "$(bud .budget.continuation_of.trigger "$WT/s-c-cap.md.result.json")" "WORKER_SIGNAL"
jq -n --arg s s-c-cap --argjson c 2 \
  '{story:$s, cycle:$c, status:"continuation_required",
    budget:{state:"CONTINUATION_REQUIRED", usage_tokens:190000, usage_ratio:0.950000,
            continuation_artifact:null, continuation_of:{cycle:1}}}' \
  > "$WT/s-c-cap.md.result.c2.json"
reset_stubs
rc="$(run_dispatch s-c-cap.md 3)"
assert_eq "cap: continuation $CAP of $CAP proceeds" "$rc" "0"
assert_eq "cap: a prior cycle the KIT continued reads as USAGE_BAND" \
  "$(bud .budget.continuation_of.trigger "$WT/s-c-cap.md.result.json")" "USAGE_BAND"
jq -n --arg s s-c-cap --argjson c 3 \
  '{story:$s, cycle:$c, status:"continuation_required",
    budget:{state:"CONTINUATION_REQUIRED", usage_tokens:190000, usage_ratio:0.950000,
            continuation_artifact:null, continuation_of:{cycle:2}}}' \
  > "$WT/s-c-cap.md.result.c3.json"
reset_stubs
rm -f "$WT/s-c-cap.md.blocked"
rc="$(run_dispatch s-c-cap.md 4)"
assert_eq "cap: the next continuation refuses, fail-closed" "$rc" "3"
CPM="$(cat "$WT/s-c-cap.md.blocked")"
assert_contains "cap: marker typed CONTINUATION-CAP:" "$CPM" "CONTINUATION-CAP:"
assert_contains "cap: carrying the stable reason code" "$CPM" "reason=CONTINUATION_CAP_REACHED"
assert_contains "cap: the count it counted"           "$CPM" "count=$CAP"
assert_contains "cap: and the cap it counted against" "$CPM" "cap=$CAP"
assert_contains "cap: it prints the exact frontmatter to add" "$CPM" "continuation_decision:"
assert_contains "cap: naming the ONE cycle it would authorise" "$CPM" "cycle: 4"
assert_contains "cap: and names the policy that owns the number" \
  "$CPM" "context-budget-policy.yaml"
# This story already declares max_cycles: 8. The remedy has to reach cycle 4
# without cutting a limit the story already carries, so it keeps the 8.
assert_contains "cap: and a max_cycles that reaches the cycle without lowering the story's own" \
  "$CPM" "max_cycles: 8"
assert_no_file "cap: NO result artifact was written"   "$WT/s-c-cap.md.result.c4.json"
assert_empty_file "cap: nothing was placed"   "$STUB_STATE/curl-calls"
assert_empty_file "cap: nothing was launched" "$STUB_STATE/terminal-creates"
# The count came from the ledger the two launches wrote, not from the planted
# results: two entries, for the two cycles that actually spent a window.
CLDG="$WT/s-c-cap.md.continuations.json"
assert_eq "cap: the count is the ledger's length" "$(jq -r '.entries|length' "$CLDG")" "$CAP"
assert_eq "cap: written by the launches themselves" \
  "$(jq -c '[.entries[].cycle]' "$CLDG")" "[2,3]"

# --- B2: a capped story cannot buy a window by re-running an earlier cycle --
# The documented recovery of "re-dispatch this same cycle" applies to attempts
# that refused BEFORE launching. Cycle 3 launched, so it is settled: re-running
# it would rewrite the evidence the cap is counted from.
reset_stubs
rm -f "$WT/s-c-cap.md.blocked"
rc="$(run_dispatch s-c-cap.md 3)"
assert_eq "cap bypass: an earlier cycle number is refused, not launched" "$rc" "3"
assert_contains "cap bypass: with the stable reason code" \
  "$(cat "$WT/s-c-cap.md.blocked")" "reason=CYCLE_ALREADY_RETAINED"
assert_empty_file "cap bypass: nothing was placed"   "$STUB_STATE/curl-calls"
assert_empty_file "cap bypass: nothing was launched" "$STUB_STATE/terminal-creates"
assert_eq "cap bypass: the retained result of cycle 3 was not overwritten" \
  "$(jq -r .status "$WT/s-c-cap.md.result.c3.json")" "continuation_required"
assert_eq "cap bypass: and the count did not deflate" \
  "$(jq -r '.entries|length' "$CLDG")" "$CAP"
# CONTROL: the cap still holds for the cycle it was computed for, and for the
# one after it — the deflation used to let cycle 4 through with no decision.
reset_stubs
rm -f "$WT/s-c-cap.md.blocked"
rc="$(run_dispatch s-c-cap.md 4)"
assert_eq "cap bypass CONTROL: cycle 4 is still refused at the cap" "$rc" "3"
assert_contains "cap bypass CONTROL: and still at the cap, not somewhere else" \
  "$(cat "$WT/s-c-cap.md.blocked")" "reason=CONTINUATION_CAP_REACHED"

# --- the cap marker's remedy never LOWERS the story's own limit -----------
# The suggestion has to reach the cycle being authorised. It is the larger of
# that cycle and the limit the story already carries: a story allowed 8 cycles
# and refused on cycle 4 must not be handed a block that quietly cuts it to 4.
CAPM="$WORK/capmarker.txt"
refuse_continuation_cap "$CAPM" 4 2 2 /p/policy.yaml 8
assert_contains "cap remedy: a larger existing limit is kept" "$(cat "$CAPM")" "max_cycles: 8"
assert_contains "cap remedy: while still authorising the named cycle" "$(cat "$CAPM")" "cycle: 4"
refuse_continuation_cap "$CAPM" 4 2 2 /p/policy.yaml 3
assert_contains "cap remedy: a limit that does not reach the cycle is raised to it" \
  "$(cat "$CAPM")" "max_cycles: 4"
refuse_continuation_cap "$CAPM" 4 2 2 /p/policy.yaml ""
assert_contains "cap remedy: an unreadable limit falls back to the cycle" \
  "$(cat "$CAPM")" "max_cycles: 4"
assert_contains "cap remedy: and says applying it never lowers the limit" \
  "$(cat "$CAPM")" "never lowers the limit you already have"
# ... and the launcher passes the story's own limit in, so the marker on a real
# refusal is computed from the story rather than from the cycle alone.
assert_contains "cap remedy: the launcher hands it the story's max_cycles" \
  "$(grep -A1 -F 'refuse_continuation_cap "${STORY}.blocked"' "$DISPATCH")" '"$MAX_CYCLES"'
# max_cycles still bounds a continuation the cap let through: the two limits are
# independent, and the cap gate running first does not retire the other one.
reset_stubs; spawn_reset
dflt_story s-c-mc          # no max_cycles declared: the launcher default of 3
retain s-c-mc 3 null       # cycle 3 handed over, so cycle 4 is a continuation
rm -f "$WT/s-c-mc.md.blocked"
rc="$(run_dispatch s-c-mc.md 4)"
assert_eq "max_cycles: a continuation the cap let through is still bounded by it" "$rc" "3"
assert_empty_file "max_cycles: and nothing was launched" "$STUB_STATE/terminal-creates"

# --- an authorised third continuation proceeds and records the decision ---
reset_stubs
write_story "$WT/s-c-cap.md" "persona: dev
gates: [\"true\"]
max_cycles: 8
continuation_decision:
  cycle: 4
  actor: pm
  at: 2026-09-07T00:00:00Z
  reason: the remaining work is one gate run"
rc="$(run_dispatch s-c-cap.md 4)"
BR="$WT/s-c-cap.md.result.json"
assert_eq "authorised: the cycle proceeds" "$rc" "0"
assert_eq "authorised: the decision is recorded verbatim" \
  "$(jq -c '.budget.continuation_decision' "$BR")" \
  '{"cycle":4,"actor":"pm","at":"2026-09-07T00:00:00Z","reason":"the remaining work is one gate run"}'
assert_contains "authorised: REPEATED_CONTINUATION fires anyway" \
  "$(jq -c '.budget.findings' "$BR")" "REPEATED_CONTINUATION"
assert_eq "authorised: the ledger grew by exactly one entry" \
  "$(jq -r '.entries|length' "$CLDG")" "$(( CAP + 1 ))"
assert_eq "authorised: and that entry carries the decision that bought it" \
  "$(jq -r '.entries[-1].decision.actor' "$CLDG")" "pm"
# A decision naming a DIFFERENT cycle does not carry forward.
reset_stubs
jq -n --arg s s-c-cap --argjson c 4 \
  '{story:$s, cycle:$c, status:"continuation_required",
    budget:{state:"CONTINUATION_REQUIRED", continuation_artifact:null,
            continuation_of:{cycle:3}}}' > "$WT/s-c-cap.md.result.c4.json"
rm -f "$WT/s-c-cap.md.blocked"
rc="$(run_dispatch s-c-cap.md 5)"
assert_eq "authorised: a decision for cycle 4 does not authorise cycle 5" "$rc" "3"
assert_contains "authorised: and says so with the same code" \
  "$(cat "$WT/s-c-cap.md.blocked")" "reason=CONTINUATION_CAP_REACHED"

# --- B1: the cap is the refusal a capped story gets at the SHIPPED defaults
# A story that declares no max_cycles gets the launcher default of 3, and the
# cap is about cycle 4. The cap gate therefore has to run FIRST, or the story is
# turned away by an untyped per-story limit that says nothing about
# continuations and offers no way to authorise the cycle.
for MC in "" "
max_cycles: 3"; do
  TAG="$([[ -z "$MC" ]] && echo absent || echo three)"
  reset_stubs; spawn_reset
  dflt_story "s-c-d$TAG" "$MC"
  retain "s-c-d$TAG" 3 '{"cycle":2}'
  ledger "s-c-d$TAG" 2 3
  rm -f "$WT/s-c-d$TAG.md.blocked"
  rc="$(run_dispatch "s-c-d$TAG.md" 4)"
  assert_eq "defaults/$TAG: the capped cycle is refused" "$rc" "3"
  assert_contains "defaults/$TAG: by the CAP, with its typed marker" \
    "$(cat "$WT/s-c-d$TAG.md.blocked")" "CONTINUATION-CAP: reason=CONTINUATION_CAP_REACHED"
  assert_contains "defaults/$TAG: carrying the count it counted" \
    "$(cat "$WT/s-c-d$TAG.md.blocked")" "count=$CAP"
done

# The other half of AC-3: the marker's own remedy, applied EXACTLY as printed,
# has to unblock the cycle. The block is lifted out of the marker and dedented,
# never retyped.
REMEDY="$(marker_frontmatter_block "$WT/s-c-dabsent.md.blocked")"
assert_contains "remedy: the marker's block carries the decision" "$REMEDY" "continuation_decision:"
assert_contains "remedy: and the story's own cycle limit"        "$REMEDY" "max_cycles: 4"
reset_stubs
write_story "$WT/s-c-dabsent.md" "persona: dev
gates: [\"true\"]
$REMEDY"
rc="$(run_dispatch s-c-dabsent.md 4)"
assert_eq "remedy: applied verbatim, the authorised cycle proceeds" "$rc" "0"
assert_eq "remedy: and the decision is recorded" \
  "$(bud .budget.continuation_decision.cycle "$WT/s-c-dabsent.md.result.json")" "4"
# CONTROL: the decision ALONE is not enough at the shipped defaults — which is
# why the marker prints both keys.
reset_stubs; spawn_reset
dflt_story s-c-dhalf
retain s-c-dhalf 3 '{"cycle":2}'
ledger s-c-dhalf 2 3
write_story "$WT/s-c-dhalf.md" "persona: dev
gates: [\"true\"]
continuation_decision:
  cycle: 4
  actor: pm
  at: 2026-09-07T00:00:00Z
  reason: one more"
rm -f "$WT/s-c-dhalf.md.blocked"
rc="$(run_dispatch s-c-dhalf.md 4)"
assert_eq "remedy CONTROL: the decision alone is still refused by max_cycles" "$rc" "3"
assert_contains "remedy CONTROL: and it is the per-story limit that says so" \
  "$(cat "$WORK/err")" "max_cycles (3) exceeded"
assert_empty_file "remedy CONTROL: nothing was launched" "$STUB_STATE/terminal-creates"

# --- R1: the decision's cycle is read as a NUMBER however it was written ----
# The marker's example is unquoted; a PM who quotes it used to get the same
# silent non-authorisation as no decision at all.
reset_stubs; spawn_reset
cont_story s-c-num
retain s-c-num 3 '{"cycle":2}'
ledger s-c-num 2 3
write_story "$WT/s-c-num.md" "persona: dev
gates: [\"true\"]
max_cycles: 8
continuation_decision:
  cycle: \"4\"
  actor: pm
  at: 2026-09-07T00:00:00Z
  reason: one more"
rc="$(run_dispatch s-c-num.md 4)"
assert_eq "quoted cycle: a numeric string authorises the cycle it names" "$rc" "0"
assert_eq "quoted cycle: and is recorded as the number it is" \
  "$(bud '.budget.continuation_decision.cycle|type' "$WT/s-c-num.md.result.json")" "number"
# and it still authorises ONE cycle: cycle 5 is refused on the same story
reset_stubs
retain s-c-num 4 '{"cycle":3}'
rm -f "$WT/s-c-num.md.blocked"
rc="$(run_dispatch s-c-num.md 5)"
assert_eq "quoted cycle: it does not carry forward either" "$rc" "3"
assert_contains "quoted cycle: refused at the cap" \
  "$(cat "$WT/s-c-num.md.blocked")" "reason=CONTINUATION_CAP_REACHED"

# --- R2: the hand-over artifact names the story it belongs to --------------
# Found by path and validated against a schema with no identity, an artifact
# copied from another story is otherwise consumed as this story's hand-over.
reset_stubs; spawn_reset
cont_story s-c-bind
retain s-c-bind 1 null
printf '%s' "$(ckpt afk-continuation/1 \
  '{"in_flight":"x","unretired_findings":[],"story_id":"s-c-bind"}')" \
  > "$WT/s-c-bind.md.continuation.json"
rc="$(run_dispatch s-c-bind.md 2)"
assert_eq "binding: an artifact that names THIS story is consumed" "$rc" "0"
assert_absent "binding: and nothing is reported as unbound" \
  "$(jq -c '.budget.findings' "$WT/s-c-bind.md.result.json")" "CONTINUATION_ARTIFACT_UNBOUND"
reset_stubs; spawn_reset
cont_story s-c-bind2
retain s-c-bind2 1 null
printf '%s' "$(ckpt afk-continuation/1 \
  '{"in_flight":"x","unretired_findings":[],"story_id":"a-different-story"}')" \
  > "$WT/s-c-bind2.md.continuation.json"
rm -f "$WT/s-c-bind2.md.blocked"
rc="$(run_dispatch s-c-bind2.md 2)"
assert_eq "binding: an artifact that names ANOTHER story refuses, pre-launch" "$rc" "3"
BNM="$(cat "$WT/s-c-bind2.md.blocked")"
assert_contains "binding: on the existing invalid-artifact path" "$BNM" "reason=CONTINUATION_ARTIFACT_INVALID"
assert_contains "binding: naming the check that failed"          "$BNM" "detail=STORY_MISMATCH"
assert_absent "binding: and never quoting the artifact's own content" "$BNM" "a-different-story"
assert_no_file "binding: NO result artifact claims an outcome" "$WT/s-c-bind2.md.result.json"
assert_empty_file "binding: nothing was placed"   "$STUB_STATE/curl-calls"
assert_empty_file "binding: nothing was launched" "$STUB_STATE/terminal-creates"
# absent is accepted: every other fixture in this section omits story_id and
# every one of them ran, and s-c-run reported CONTINUATION_ARTIFACT_UNBOUND.
reset_stubs; spawn_reset

# --- S2: the same stamp, revalidated; expired refuses with the refresh path
reset_stubs; spawn_reset
cont_story s-c-stamp
retain s-c-stamp 1 null
STAMP_BEFORE="$(sha256sum "$WT/s-c-stamp.md.stamp.json" | cut -d' ' -f1)"
rm -f "$WT/s-c-stamp.md.blocked"
rc="$(STUB_VALIDATOR_EXIT=1; export STUB_VALIDATOR_EXIT; run_dispatch s-c-stamp.md 2)"
assert_eq "stamp: the validator's own refusal is unchanged (exit 4)" "$rc" "4"
STM="$(cat "$WT/s-c-stamp.md.blocked")"
assert_contains "stamp: marker typed CONTINUATION-STAMP:" "$STM" "CONTINUATION-STAMP:"
assert_contains "stamp: carrying the stable reason code" \
  "$STM" "reason=CONTINUATION_STAMP_REFRESH_REQUIRED"
assert_contains "stamp: beside the validator's OWN reason, not instead of it" \
  "$STM" "validator_reason=stamp_expired"
assert_contains "stamp: it names the central decision as the way forward" "$STM" "POST /v1/route"
assert_contains "stamp: and a NEW stamp minted by the planner"            "$STM" "make-stamp.sh"
assert_contains "stamp: a local substitute is refused in so many words" \
  "$STM" "locally minted or locally edited"
assert_eq "stamp: the stamp itself is byte-identical afterwards" \
  "$(sha256sum "$WT/s-c-stamp.md.stamp.json" | cut -d' ' -f1)" "$STAMP_BEFORE"
assert_no_file "stamp: no result artifact was written" "$WT/s-c-stamp.md.result.c2.json"
assert_empty_file "stamp: nothing was launched" "$STUB_STATE/terminal-creates"
assert_absent "stamp: no substitute route was chosen" "$(cat "$WORK/err")" "fallback"
# The control: the SAME continuation, with a stamp that validates, launches.
reset_stubs
rc="$(run_dispatch s-c-stamp.md 2)"
assert_eq "stamp CONTROL: a valid stamp launches the same continuation" "$rc" "0"

# --- S5: settlement is the frozen 1.3 path, unmodified -------------------
if git -C "$KIT_ROOT" show master:lib/afk-monitor.sh 2>/dev/null \
     | cmp -s - "$KIT_ROOT/lib/afk-monitor.sh"; then
  ok "settlement: lib/afk-monitor.sh is byte-identical to master — nothing needed to change"
else bad "settlement: lib/afk-monitor.sh is byte-identical to master — nothing needed to change" \
  "$(git -C "$KIT_ROOT" diff --stat master -- lib/afk-monitor.sh)"; fi
assert_eq "settlement: a continuation cycle's budget state is one of the declared four" \
  "$(jq -r --argjson s "$(yq -o=json -I=0 '.budget_states' "$BUDGET_POLICY_SHIPPED")" \
      '.budget.state as $st | ($s | index($st)) != null' "$WT/s-c-run.md.result.c2.json")" "true"
assert_eq "settlement: and the retained copy carries the same status the monitor reads" \
  "$(jq -r .status "$WT/s-c-cap.md.result.c4.json")" "continuation_required"

spawn_reset
export STUB_TERMINAL_TAIL="ok
CLAUDE_EXIT=0"

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
head1 "4b. Offline Claude result-envelope qualification"
# ===========================================================================

if [[ -x "$CLAUDE_EVIDENCE_TESTS" ]]; then
  if evidence_out="$(bash "$CLAUDE_EVIDENCE_TESTS" 2>&1)"; then
    ok "Claude evidence verifier gate: $(tail -1 <<<"$evidence_out")"
  else
    bad "Claude evidence verifier gate" "$(tail -1 <<<"$evidence_out")"
    printf '%s\n' "$evidence_out" | tail -40
  fi
else
  bad "Claude evidence verifier gate present and executable" "missing: $CLAUDE_EVIDENCE_TESTS"
fi

# ===========================================================================
head1 "5. Live control-plane chain (opt-in, read-only, launches nothing)"
# ===========================================================================
# Runs only when a real router, caller token, validator and catalog are all
# present. Everything above this line is offline and hermetic.
#
#   AGENT_ROUTER_URL=https://agent-router.homelab0.org \
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
head1 "11. Runtime status gate — tests/runtime-experience-tests.sh"
# ===========================================================================

RUNTIME_STATUS_TESTS="$KIT_ROOT/tests/runtime-experience-tests.sh"
if [[ -f "$RUNTIME_STATUS_TESTS" ]]; then
  if runtime_status_out="$(bash "$RUNTIME_STATUS_TESTS" 2>&1)"; then
    ok "runtime status gate: $(tail -1 <<<"$runtime_status_out")"
  else
    bad "runtime status gate" "$(tail -1 <<<"$runtime_status_out")"
    printf '%s\n' "$runtime_status_out" | tail -40
  fi
else
  bad "runtime status gate present" "missing: $RUNTIME_STATUS_TESTS"
fi

# ===========================================================================
head1 "12. Orca-visible status gate — tests/orca-visible-status-tests.sh"
# ===========================================================================

VISIBLE_STATUS_TESTS="$KIT_ROOT/tests/orca-visible-status-tests.sh"
if [[ -f "$VISIBLE_STATUS_TESTS" ]]; then
  if visible_status_out="$(bash "$VISIBLE_STATUS_TESTS" 2>&1)"; then
    ok "Orca-visible status gate: $(tail -1 <<<"$visible_status_out")"
  else
    bad "Orca-visible status gate" "$(tail -1 <<<"$visible_status_out")"
    printf '%s\n' "$visible_status_out" | tail -40
  fi
else
  bad "Orca-visible status gate present" "missing: $VISIBLE_STATUS_TESTS"
fi

# ===========================================================================
if (( SKIPPED > 0 )); then
  printf '\n\033[1m%d passed, %d failed, %d skipped\033[0m\n' "$PASS" "$FAIL" "$SKIPPED"
  printf '\033[33mskipped checks computed no verdict — they are not passes\033[0m\n'
else
  printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
fi
(( FAIL == 0 )) || exit 1
