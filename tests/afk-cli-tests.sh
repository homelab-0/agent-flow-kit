#!/usr/bin/env bash
# afk-cli-tests.sh — the standalone `afk` route: task guessing, routing over
# the CLIs installed here, launch commands per CLI, one-shot failover and
# pinning. Stub CLIs only; no real agent, no network.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
PASS=0 FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s (%s)\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
head1(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing '$3' in '${2:0:300}'"; fi; }

export HOME="$TMPROOT/home" TMPDIR="$TMPROOT/tmp"
mkdir -p "$HOME" "$TMPDIR"
export AFK_STATE_DIR="$HOME/.local/state/agent-flow-kit"
export AFK_SKIP_BENCHMARK_AUTOSYNC=1
export AFK_ROUTER_BENCHMARKS_FILE="$KIT_ROOT/files/model-router/benchmarks.json"
export AFK_ROUTER_SIGNALS_FILE="$TMPROOT/signals.json"
# Hermetic: the router treats these CLIs as installed and probes nothing real.
export AFK_ROUTER_HARNESS_LIST="claude,codex,opencode"
BIN="$TMPROOT/bin"; mkdir -p "$BIN"
export AFK_HARNESS_BIN_DIR_OVERRIDE="$BIN"
LOG="$TMPROOT/argv.log"; export LOG; : > "$LOG"
for h in claude codex opencode; do
  cat > "$BIN/$h" <<'SH'
#!/usr/bin/env bash
name="$(basename "$0")"
printf '%s' "$name" >> "$LOG"; for a in "$@"; do printf ' [%s]' "$a" >> "$LOG"; done; printf '\n' >> "$LOG"
fail_var="FAIL_$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
if [[ -n "${!fail_var:-}" ]]; then printf '%s\n' "${!fail_var}" >&2; exit 1; fi
printf 'answer from %s\n' "$name"
SH
  chmod +x "$BIN/$h"
done
AFK="$KIT_ROOT/bin/afk"
LIBS='. "'"$KIT_ROOT"'/lib/afk-common.sh" 2>/dev/null; . "'"$KIT_ROOT"'/lib/afk-harnesses.sh" 2>/dev/null; . "'"$KIT_ROOT"'/lib/afk-smart-router.sh" 2>/dev/null; . "'"$KIT_ROOT"'/lib/afk-cli.sh"'

# ============================================================================
head1 "1. Task kind from the prompt"
# ============================================================================
G="$(bash -c "$LIBS"'; for p in "review this diff" "design the architecture for sync" "make the landing page responsive" "explain how the scheduler works" "refactor the parser" "fix a typo in the readme" "add a retry to the client" "check for XSS in the form" ""; do printf "%s," "$(afk_cli_guess_task "$p")"; done')"
assert_eq "Prompts map to review, architecture, webdev, research, complex, quick, coding, security, and an empty prompt to coding" \
  "$G" "review,architecture,webdev,research,complex,quick,coding,security,coding,"

# ============================================================================
head1 "2. The choice and the alternatives"
# ============================================================================
E="$("$AFK" --explain --json "add a retry to the client" 2>/dev/null)"
assert_eq "--explain picks one of the installed CLIs and says the task was guessed" \
  "$(jq -r '"\(.task):\(.task_guessed):\(.choice.harness | IN("claude","codex","opencode"))"' <<<"$E")" "coding:true:true"
assert_eq "--explain lists the best route per installed CLI, best first" \
  "$(jq -r '[.by_harness[].harness] | sort | join(",")' <<<"$E"):$(jq -r '[.by_harness[].effective_score] | . == (sort | reverse)' <<<"$E")" "claude,codex,opencode:true"
assert_eq "--explain starts nothing" "$(wc -l < "$LOG" | tr -d ' ')" "0"
E="$("$AFK" --explain --json --harness codex "add a retry" 2>/dev/null)"
assert_eq "--harness keeps the router to that CLI" "$(jq -r .choice.harness <<<"$E")" "codex"
NOROUTE="$(bash -c "$LIBS"'
  afk_router_select_candidate() { printf "{\"harness\":\"claude\",\"model\":\"sonnet\",\"router_source\":\"fallback-default\"}"; }
  afk_cli_route /r coding balanced codex; printf ":%s" "$?"')"
assert_eq "A last-resort route to a CLI the user did not allow is refused, not launched" "$NOROUTE" ":3"
E="$("$AFK" --explain --json --harness codex --model gpt-test "x" 2>/dev/null)"
assert_eq "--harness with --model skips the router" "$(jq -r '"\(.choice.harness)/\(.choice.model):\(.choice.pinned)"' <<<"$E")" "codex/gpt-test:true"
E="$("$AFK" --explain --json --task review "anything" 2>/dev/null)"
assert_eq "--task overrides the guess, and a review never goes to a free model" \
  "$(jq -r '"\(.task):\(.task_guessed):\(.choice.cost_class != "free")"' <<<"$E")" "review:false:true"
# What the CLI asks the router for, per task and preference.
ASK="$(bash -c "$LIBS"'
  afk_router_select_candidate() { printf "%s/%s/pf=%s/only=%s " "$2" "$3" "${AFK_ROUTER_PREFER_FREE:-}" "${AFK_ROUTER_ONLY_HARNESSES:-}"; }
  afk_cli_route /r quick balanced claude,codex; afk_cli_route /r coding balanced claude
  afk_cli_route /r coding cheap claude; afk_cli_route /r coding best claude
  afk_cli_route /r complex balanced claude; afk_cli_route /r review best claude
  afk_cli_route /r webdev balanced claude; afk_cli_route /r security balanced claude')"
assert_eq "Quick and cheap ask for free models first, best and complex ask for the strongest, and the CLI list is passed through" \
  "$ASK" "build/low/pf=1/only=claude,codex build/low/pf=/only=claude build/low/pf=1/only=claude build/high/pf=/only=claude build/high/pf=/only=claude review-code/high/pf=/only=claude ux/low/pf=/only=claude review-security/low/pf=/only=claude "
assert_eq "The CLI never turns on the router's hermetic test mode" "$(grep -c 'AFK_ROUTER_HARNESS_LIST' "$KIT_ROOT/lib/afk-cli.sh")" "0"

# ============================================================================
head1 "3. The command each CLI is started with"
# ============================================================================
argv() { bash -c "$LIBS"'; afk_cli_launch_argv "$@" | tr "\0" "|"' _ "$@"; }
assert_eq "claude interactive: model, effort, prompt; no permission bypass unless --yolo" \
  "$(argv claude sonnet high interactive false "do it")" "$BIN/claude|--model|sonnet|--effort|high|do it|"
assert_eq "claude one-shot with --yolo" \
  "$(argv claude sonnet "" print true "do it")" "$BIN/claude|--model|sonnet|--dangerously-skip-permissions|-p|do it|"
assert_eq "codex interactive uses -m and the effort config (its -p means profile, so it is never used)" \
  "$(argv codex gpt-6-sol medium interactive false "do it")" "$BIN/codex|-m|gpt-6-sol|-c|model_reasoning_effort=\"medium\"|--|do it|"
assert_eq "codex one-shot runs codex exec" \
  "$(argv codex gpt-6-sol "" print false "do it")" "$BIN/codex|exec|-m|gpt-6-sol|--|do it|"
assert_eq "opencode interactive passes the prompt with --prompt; one-shot uses run" \
  "$(argv opencode a/b "" interactive false "hi")|$(argv opencode a/b "" print false "hi")" "$BIN/opencode|-m|a/b|--prompt|hi||$BIN/opencode|run|-m|a/b|--|hi|"
assert_eq "Arguments after -- reach the CLI unchanged" \
  "$(argv claude sonnet "" interactive false "" --continue)" "$BIN/claude|--model|sonnet|--continue|"

# ============================================================================
head1 "4. One-shot answers and failover"
# ============================================================================
: > "$LOG"
O="$("$AFK" -p --json "add a retry to the client" 2>/dev/null)"
assert_eq "-p prints the chosen CLI's answer" "$(jq -r '"\(.ok):\(.attempts):\(.output)"' <<<"$O")" "true:1:answer from $(jq -r .harness <<<"$O")"
FIRST="$(jq -r .harness <<<"$O")"
FV="FAIL_$(printf '%s' "$FIRST" | tr '[:lower:]' '[:upper:]')"
rm -f "$AFK_ROUTER_SIGNALS_FILE"; : > "$LOG"
O="$(env "$FV=Error: 429 rate limit exceeded" "$AFK" -p --json "add a retry to the client" 2>/dev/null)"
assert_eq "A CLI that hits its rate limit is marked and the next one answers" \
  "$(jq -r '"\(.ok):\(.attempts):\(.harness != "'"$FIRST"'")"' <<<"$O")" "true:2:true"
assert_eq "The pool behind the failed CLI is recorded as out of quota" \
  "$(jq -r '[.pools[] | select(.degraded_kind == "quota")] | length' "$AFK_ROUTER_SIGNALS_FILE" 2>/dev/null)" "1"
rm -f "$AFK_ROUTER_SIGNALS_FILE"
O="$(env FAIL_CODEX="Error: 429" "$AFK" -p --json --harness codex "add a retry" 2>/dev/null)"; rc=$?
assert_eq "A pinned CLI that fails is reported, not swapped for another" \
  "$rc:$(jq -r '"\(.ok):\(.tried)"' <<<"$O")" "5:false:codex/$(jq -r '.tried' <<<"$O" | cut -d/ -f2-)"
rm -f "$AFK_ROUTER_SIGNALS_FILE"
O="$(env FAIL_CLAUDE=boom FAIL_CODEX=boom FAIL_OPENCODE=boom "$AFK" -p --json "add a retry" 2>/dev/null)"; rc=$?
assert_eq "When every CLI fails, it stops after three attempts" "$rc:$(jq -r '.tried | split(", ") | length' <<<"$O")" "5:3"
rm -f "$AFK_ROUTER_SIGNALS_FILE"
O="$(printf 'piped prompt' | "$AFK" -p --json 2>/dev/null)"
assert_eq "-p reads the prompt from stdin when none is given" "$(jq -r .ok <<<"$O")" "true"

# ============================================================================
head1 "5. Interactive start and bad input"
# ============================================================================
: > "$LOG"
"$AFK" --harness claude --model sonnet "hello there" >/dev/null 2>&1
assert_eq "afk with a prompt hands the terminal to the CLI with that prompt" "$(cat "$LOG")" "claude [--model] [sonnet] [hello there]"
"$AFK" --bogus >/dev/null 2>&1; r1=$?
"$AFK" --harness agy x >/dev/null 2>&1; r2=$?
"$AFK" --prefer fastest x >/dev/null 2>&1; r3=$?
"$AFK" -p </dev/null >/dev/null 2>&1; r4=$?
assert_eq "An unknown option, a CLI that is not installed, a bad --prefer and -p without a prompt are refused" "$r1:$r2:$r3:$r4" "2:3:2:2"
H="$("$AFK" --help)"
assert_contains "afk --help explains the three ways to use it" "$H" "afk --explain"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
