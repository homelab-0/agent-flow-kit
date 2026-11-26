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
json_var="JSON_$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')"
if [[ -n "${!json_var:-}" ]]; then cat "${!json_var}"; exit 0; fi
printf 'answer from %s\n' "$name"
SH
  chmod +x "$BIN/$h"
done
AFK="$KIT_ROOT/bin/afk"
LIBS='. "'"$KIT_ROOT"'/lib/afk-common.sh" 2>/dev/null; . "'"$KIT_ROOT"'/lib/afk-harnesses.sh" 2>/dev/null; . "'"$KIT_ROOT"'/lib/afk-smart-router.sh" 2>/dev/null; . "'"$KIT_ROOT"'/lib/afk-cli.sh"'

# ============================================================================
head1 "1. Task kind from the prompt"
# ============================================================================
G="$(bash -c "$LIBS"'; for p in "review this diff" "design the architecture for sync" "make the landing page responsive" "explain how the scheduler works" "refactor the parser" "fix a typo in the readme" "add a retry to the client" "check for XSS in the form" "" "find the vulnerability" "fix the concurrency bug" "use dependency injection" "explain why the build fails and fix it"; do printf "%s," "$(afk_cli_guess_task "$p")"; done')"
assert_eq "Prompts map to their kind; word stems match inflections, and a prompt asking for a change is not research" \
  "$G" "review,architecture,webdev,research,complex,quick,coding,security,coding,security,complex,coding,coding,"

# ============================================================================
head1 "2. The choice and the alternatives"
# ============================================================================
E="$("$AFK" --explain --json "add a retry to the client" 2>/dev/null)"
assert_eq "--explain picks one of the installed CLIs and says the task was guessed" \
  "$(jq -r '"\(.task):\(.task_guessed):\(.choice.harness | IN("claude","codex","opencode"))"' <<<"$E")" "coding:true:true"
# opencode is installed here but has no route: its only catalog model uses the
# SuperGrok plan, and a plan login is never used outside its own vendor CLI.
assert_eq "--explain lists the best route per installed CLI that may be used, best first" \
  "$(jq -r '[.by_harness[].harness] | sort | join(",")' <<<"$E"):$(jq -r '[.by_harness[].effective_score] | . == (sort | reverse)' <<<"$E")" "claude,codex:true"
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
assert_eq "claude interactive: model, effort, then the prompt after --; no permission bypass unless --yolo" \
  "$(argv claude sonnet high interactive false "do it" "")" "$BIN/claude|--model|sonnet|--effort|high|--|do it|"
assert_eq "claude one-shot asks for JSON, with --yolo" \
  "$(argv claude sonnet "" print true "do it" "")" "$BIN/claude|--model|sonnet|--dangerously-skip-permissions|-p|--output-format|json|--|do it|"
assert_eq "codex interactive uses -m and the effort config (its -p means profile, so it is never used)" \
  "$(argv codex gpt-6-sol medium interactive false "do it" "")" "$BIN/codex|-m|gpt-6-sol|-c|model_reasoning_effort=\"medium\"|--|do it|"
assert_eq "codex one-shot runs exec in or out of a git repository, with JSON and the answer file" \
  "$(argv codex gpt-6-sol "" print false "do it" /tmp/o)" "$BIN/codex|exec|--skip-git-repo-check|--json|-o|/tmp/o|-m|gpt-6-sol|--|do it|"
assert_eq "opencode interactive passes the prompt as --prompt=; one-shot uses run with JSON" \
  "$(argv opencode a/b "" interactive false "hi" "")|$(argv opencode a/b "" print false "hi" "")" "$BIN/opencode|-m|a/b|--prompt=hi||$BIN/opencode|run|--format|json|-m|a/b|--|hi|"
assert_eq "Passed-through arguments go before the prompt, so no CLI reads them as prompt text" \
  "$(argv codex m "" print false "hi" /tmp/o --skip-something)" "$BIN/codex|exec|--skip-git-repo-check|--json|-o|/tmp/o|-m|m|--skip-something|--|hi|"
assert_eq "A prompt that starts with a dash is not read as an option" \
  "$(argv claude m "" print false "-n is a flag" "")" "$BIN/claude|--model|m|-p|--output-format|json|--| -n is a flag|"
GWR='{"harness":"claude","model":"qwen36-27b","launch_class":"claude-gateway","litellm_base_url":"http://gw"}'
GW1="$(AFK_GATEWAY_KEY=sekrit-123 bash -c "$LIBS"'; afk_cli_launch_envjson "$1"' _ "$GWR")"
assert_eq "A claude gateway launch gets the gateway address, its own config dir and the key by variable name only" \
  "$(jq -r '"\(.env_set.ANTHROPIC_BASE_URL)|\(.env_set.CLAUDE_CONFIG_DIR | endswith("/gateway-claude"))|\(.env_from.ANTHROPIC_AUTH_TOKEN)|\([.env_unset | index("ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN") | . != null] | all)"' <<<"$GW1"):$(grep -c sekrit <<<"$GW1")" \
  "http://gw|true|AFK_GATEWAY_KEY|true:0"
GW2="$(env -u AFK_GATEWAY_KEY bash -c "$LIBS"'; afk_cli_launch_envjson "$1"; printf ":%s" "$?"' _ "$GWR")"
GW3="$(AFK_GATEWAY_KEY=k bash -c "$LIBS"'; afk_cli_launch_envjson "{\"harness\":\"claude\",\"launch_class\":\"claude-gateway\"}"; printf ":%s" "$?"')"
GW4="$(AFK_GATEWAY_KEY=k bash -c "$LIBS"'; afk_cli_launch_envjson "{\"harness\":\"codex\",\"launch_class\":\"codex-gateway\",\"litellm_base_url\":\"http://gw\"}"; printf ":%s" "$?"')"
assert_eq "No gateway key, no gateway address, or a CLI that would expose its plan login: the gateway route cannot launch" \
  "${GW2##*:}${GW3##*:}${GW4##*:}:$(grep -c 'AFK_GATEWAY_KEY' <<<"$GW2")" "111:1"
NAT="$(bash -c "$LIBS"'; afk_cli_launch_envjson "{\"harness\":\"claude\",\"launch_class\":\"claude-native\"}"')"
assert_eq "A native route changes nothing in the environment" "$NAT" '{"env_set":{},"env_from":{},"env_unset":[]}'

PLAN="$(AFK_GATEWAY_KEY=sekrit-123 "$AFK" --launch-plan --json --route "$GWR" --mode print -- "-n is a flag" 2>/dev/null)"
assert_eq "--launch-plan prints the afk-launch-plan/1 JSON with argv, env and the answer format, and no secret" \
  "$(jq -r '"\(.schema)|\(.ok)|\(.argv[0] | endswith("/claude"))|\(.argv[-1])|\(.answer.format)|\(.env_from.ANTHROPIC_AUTH_TOKEN)"' <<<"$PLAN"):$(grep -c sekrit <<<"$PLAN")" \
  "afk-launch-plan/1|true|true| -n is a flag|json|AFK_GATEWAY_KEY:0"
PLAN2="$(env -u AFK_GATEWAY_KEY "$AFK" --launch-plan --json --route "$GWR" -- "hi" 2>/dev/null)"; rcp=$?
assert_eq "A plan that cannot launch says why and exits 4" "$rcp:$(jq -r '"\(.ok)|\(.error | test("AFK_GATEWAY_KEY"))"' <<<"$PLAN2")" "4:false|true"
CXP="$("$AFK" --launch-plan --json --route '{"harness":"codex","model":"m"}' --mode print -- "hi" 2>/dev/null)"
assert_eq "A codex print plan names the file its answer is written to" "$(jq -r '"\(.answer.format)|\(.answer.file == .argv[(.argv | index("-o")) + 1])"' <<<"$CXP")" "text-file|true"
rm -f "$(jq -r .answer.file <<<"$CXP")"
SIP="$(printf '%s' '{"harness":"codex","model":"m"}' | "$AFK" --launch-plan --json --route - --mode print -- "hi" 2>/dev/null)"
assert_eq "--route - reads the route from stdin, so it stays off the command line" \
  "$(jq -r '"\(.ok)|\(.argv[0] | endswith("/codex"))|\(.argv[-1])"' <<<"$SIP")" "true|true|hi"
rm -f "$(jq -r .answer.file <<<"$SIP")"
P1="$("$AFK" --launch-plan --json --route '{"harness":"opencode","model":"openai/gpt-6.1-sol"}' -- hi 2>/dev/null)"; r1=$?
P2="$("$AFK" --launch-plan --json --route '{"harness":"opencode","model":"opencode/glm-free"}' -- hi 2>/dev/null)"; r2=$?
P3="$("$AFK" --launch-plan --json --route '{"harness":"codex","model":"m","cost_class":"subscription","entitlement_pool":"xai-grok"}' -- hi 2>/dev/null)"; r3=$?
assert_eq "Every launch checks the plan-login rule: opencode with a ChatGPT model and codex on the SuperGrok plan are refused; opencode's own free model is fine" \
  "$r1:$(jq -r .ok <<<"$P1"):$r2:$(jq -r .ok <<<"$P2"):$r3:$(jq -r .ok <<<"$P3")" "4:false:0:true:4:false"
: > "$LOG"
"$AFK" --harness opencode --model openai/gpt-6.1-sol "hi" >/dev/null 2>&1; rpin=$?
assert_eq "A pinned opencode route to another vendor's model is refused and nothing starts" "$rpin:$(wc -l < "$LOG" | tr -d ' ')" "4:0"
GWK="$(CLAUDE_CODE_OAUTH_TOKEN=plan-token AFK_GATEWAY_KEY_ENV=CLAUDE_CODE_OAUTH_TOKEN bash -c "$LIBS"'; afk_cli_launch_envjson "$1"; printf ":%s" "$?"' _ "$GWR")"
assert_eq "The gateway key may not be taken from a vendor credential variable" "${GWK##*:}:$(grep -c plan-token <<<"$GWK")" "1:0"
GWU="$(AFK_GATEWAY_KEY=k CLAUDE_CODE_SOMETHING_NEW=x bash -c "$LIBS"'; afk_cli_launch_envjson "$1"' _ "$GWR")"
assert_eq "A gateway launch unsets every Claude and Anthropic variable in the environment, and the known credential ones, but not what it sets" \
  "$(jq -r '[.env_unset | index("CLAUDE_CODE_SOMETHING_NEW", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN", "CLAUDE_CODE_SESSION_ACCESS_TOKEN") | . != null] | all' <<<"$GWU"):$(jq -r '[.env_unset | index("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN") == null] | all' <<<"$GWU")" "true:true"
APP="$(bash -c "$LIBS"'
  plan="{\"env_set\":{\"ANTHROPIC_BASE_URL\":\"http://gw\"},\"env_from\":{\"ANTHROPIC_AUTH_TOKEN\":\"AFK_GATEWAY_KEY\"},\"env_unset\":[\"CLAUDE_CODE_OAUTH_TOKEN\",\"AFK_GATEWAY_KEY\"]}"
  ( AFK_GATEWAY_KEY=gk CLAUDE_CODE_OAUTH_TOKEN=plan; afk_cli_apply_plan_env "$plan" && printf "%s|%s|%s" "${ANTHROPIC_AUTH_TOKEN:-}" "${CLAUDE_CODE_OAUTH_TOKEN:-gone}" "$ANTHROPIC_BASE_URL" )
  printf ":"
  ( unset AFK_GATEWAY_KEY; afk_cli_apply_plan_env "$plan"; printf "%s" "$?" )')"
assert_eq "Applying a plan copies the key before unsetting, drops the plan token, and refuses an empty key source" "$APP" "gk|gone|http://gw:1"
EXJ="$("$AFK" --explain --json -- "-v flag handling" 2>/dev/null)"
assert_eq "--explain JSON carries its schema, and the words after -- are the prompt even with a leading dash" \
  "$(jq -r .schema <<<"$EXJ")" "afk-route-explain/1"
MODEL_HS="$(bash -c "$LIBS"'; afk_cli_harnesses_for_model gpt-6-astra "claude,codex,opencode"; printf ":"; afk_cli_harnesses_for_model not-a-model "claude,codex"')"
assert_eq "--model alone is matched to the CLI the catalog says serves it" "$MODEL_HS" "codex=gpt-6-astra:"
CANON="$(bash -c "$LIBS"'; afk_cli_harnesses_for_model "$(jq -r ".candidates[] | select(.harness == \"claude\") | .canonical_model" "$AFK_ROUTER_BENCHMARKS_FILE" | head -n 1)" "claude"')"
assert_eq "A canonical model name launches under the name the CLI uses" "${CANON#claude=}" "$(jq -r '.candidates[] | select(.harness == "claude") | .model' "$AFK_ROUTER_BENCHMARKS_FILE" | head -n 1)"

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
assert_eq "A pinned CLI that hits its rate limit is still recorded for the router" \
  "$(jq -r '[.pools[] | select(.degraded_kind == "quota")] | length' "$AFK_ROUTER_SIGNALS_FILE" 2>/dev/null)" "1"
assert_eq "A pinned CLI that fails is reported, not swapped for another" \
  "$rc:$(jq -r '"\(.ok):\(.tried)"' <<<"$O")" "5:false:codex/$(jq -r '.tried' <<<"$O" | cut -d/ -f2-)"
rm -f "$AFK_ROUTER_SIGNALS_FILE"
O="$(env FAIL_CLAUDE=boom FAIL_CODEX=boom FAIL_OPENCODE=boom "$AFK" -p --json "add a retry" 2>/dev/null)"; rc=$?
assert_eq "When every usable CLI fails, it stops once none is left" "$rc:$(jq -r '.tried | split(", ") | length' <<<"$O")" "5:2"
rm -f "$AFK_ROUTER_SIGNALS_FILE"
cat > "$BIN/claude.json" <<'J'
{"type":"result","is_error":true,"result":"Claude AI usage limit reached"}
J
O="$(env JSON_CLAUDE="$BIN/claude.json" "$AFK" -p --json --task coding "add a retry" 2>/dev/null)"
assert_eq "An error the CLI reports in its JSON with exit 0 still fails over, and marks the pool" \
  "$(jq -r '"\(.ok):\(.harness != "claude")"' <<<"$O"):$(jq -r '.pools["anthropic-max"].degraded_kind // "none"' "$AFK_ROUTER_SIGNALS_FILE" 2>/dev/null)" "true:true:quota"
rm -f "$AFK_ROUTER_SIGNALS_FILE"
O="$(env FAIL_CLAUDE="segfault in plugin" "$AFK" -p --json --task coding "add a retry" 2>/dev/null)"
assert_eq "A failure that is not about quota or sign-in moves on without marking any pool" \
  "$(jq -r '"\(.ok):\(.harness != "claude")"' <<<"$O"):$( [[ -s "$AFK_ROUTER_SIGNALS_FILE" ]] && jq -r '[.pools[]?] | length' "$AFK_ROUTER_SIGNALS_FILE" || printf 0)" "true:true:0"
rm -f "$AFK_ROUTER_SIGNALS_FILE"
O="$(printf 'piped prompt' | "$AFK" -p --json 2>/dev/null)"
assert_eq "-p reads the prompt from stdin when none is given" "$(jq -r .ok <<<"$O")" "true"

# ============================================================================
head1 "5. Interactive start and bad input"
# ============================================================================
: > "$LOG"
"$AFK" --harness claude --model sonnet "hello there" >/dev/null 2>&1
assert_eq "afk with a prompt hands the terminal to the CLI with that prompt" "$(cat "$LOG")" "claude [--model] [sonnet] [--] [hello there]"
: > "$LOG"
"$AFK" --model gpt-6-astra "hi" >/dev/null 2>&1
assert_eq "--model without --harness starts the CLI that serves it" "$(cut -d' ' -f1 "$LOG")" "codex"
"$AFK" --model not-a-model "hi" >/dev/null 2>&1; rm_=$?
assert_eq "--model the catalog does not know, without --harness, is refused" "$rm_" "2"
: > "$LOG"
"$AFK" --harness claude --model sonnet --pass --continue >/dev/null 2>&1
assert_eq "Interactive arguments given with --pass reach the CLI" "$(cat "$LOG")" "claude [--model] [sonnet] [--continue]"
"$AFK" --bogus >/dev/null 2>&1; r1=$?
"$AFK" --harness agy x >/dev/null 2>&1; r2=$?
"$AFK" --prefer fastest x >/dev/null 2>&1; r3=$?
"$AFK" -p </dev/null >/dev/null 2>&1; r4=$?
assert_eq "An unknown option, a CLI that is not installed, a bad --prefer and -p without a prompt are refused" "$r1:$r2:$r3:$r4" "2:3:2:2"
H="$("$AFK" --help)"
assert_contains "afk --help explains the three ways to use it" "$H" "afk --explain"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
