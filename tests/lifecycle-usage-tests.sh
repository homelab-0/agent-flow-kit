#!/usr/bin/env bash
# lifecycle-usage-tests.sh — the isolated deterministic gate for
# `agent-flow-kit usage-report` (lib/afk-usage.sh).
#
# Runnable standalone: `bash tests/lifecycle-usage-tests.sh`. It sources
# lib/afk-usage.sh directly, points every source at small synthetic fixtures
# under tests/fixtures/usage/ (never the real host state), and pins "now" so
# the --days window is deterministic. Nothing here touches the real HOME.
#
# Usage: tests/lifecycle-usage-tests.sh
# Exit:  0 all passed, 1 any failure.

set -uo pipefail

KIT_ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
FIXTURES="$KIT_ROOT/tests/fixtures/usage"

# shellcheck source=lib/afk-common.sh
. "$KIT_ROOT/lib/afk-common.sh"
# shellcheck source=lib/afk-usage.sh
. "$KIT_ROOT/lib/afk-usage.sh"

PASS=0 FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; FAIL=$((FAIL + 1)); }
head1() { printf '\n\033[1m%s\033[0m\n' "$1"; }

assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }

# "Now" is pinned so the 7-day cutoff lands exactly where the fixtures expect:
# in-window records are 2026-09-20/21, out-of-window records are 2026-09-01
# and earlier.
export AFK_USAGE_NOW_EPOCH
AFK_USAGE_NOW_EPOCH="$(date -u -d '2026-09-23T12:00:00Z' +%s)"

TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT

# --- assemble a throwaway opencode.db from the checked-in SQL seed ----------
export AFK_USAGE_OPENCODE_DB="$TMPROOT/opencode.db"
if afk_have sqlite3; then
  sqlite3 "$AFK_USAGE_OPENCODE_DB" < "$FIXTURES/opencode/seed.sql"
fi

export AFK_USAGE_CLAUDE_PROJECTS_DIR="$FIXTURES/claude"
export AFK_USAGE_CODEX_HOMES="$FIXTURES/codex"
export AFK_USAGE_PRICES_FILE="$KIT_ROOT/files/model-router/usage-prices.yaml"

# Repo-aware workspace-name stripping (regression: worker_sessions_per_story
# used to print the raw encoded project-dir string). Real orca/workspaces
# layout is <repo>/<workspace>; a throwaway one here proves the split.
mkdir -p "$TMPROOT/orca-workspaces/agent-flow-kit/afk-te-4-review" \
         "$TMPROOT/orca-workspaces/agent-flow-kit/afk-te-4"
export AFK_USAGE_ORCA_WORKSPACES_DIR="$TMPROOT/orca-workspaces"

head1 "AC-1: bash + jq only; sqlite3 optional"
# opencode reporting "ok" when sqlite3 IS present is exercised by AC-2 below
# (it seeds and reads the opencode.db fixture). Here: force the "no sqlite3"
# path regardless of host, by hiding it on PATH.
NOSQLITE_BIN="$TMPROOT/nosqlite-bin"
mkdir -p "$NOSQLITE_BIN"
for t in bash jq date awk sed grep find sort head tail tr wc cat mktemp printf dirname rm basename; do
  p="$(command -v "$t" 2>/dev/null)"; [[ -n "$p" ]] && ln -sf "$p" "$NOSQLITE_BIN/$t"
done
out_nosqlite="$(PATH="$NOSQLITE_BIN" bash -c '
  . "'"$KIT_ROOT"'/lib/afk-common.sh"
  . "'"$KIT_ROOT"'/lib/afk-usage.sh"
  afk_usage_report --json --days 7
' 2>&1)"
assert_eq "opencode reports unknown with sqlite3 not installed" \
  "$(jq -r .opencode_status <<<"$out_nosqlite" 2>/dev/null)" "unknown (sqlite3 not installed)"

head1 "AC-2: fixtures produce a known report, including dedupe"
REPORT="$(afk_usage_report --json --days 7)"
echo "$REPORT" > "$TMPROOT/report.json"

assert_eq "claude opus: 1 session (dedupe collapses the duplicated record)" \
  "$(jq -r '.by_harness_model[] | select(.harness=="claude" and .model=="claude-opus-5") | .sessions' "$TMPROOT/report.json")" "1"
assert_eq "claude opus: 2 calls after dedupe (3 raw records, 1 duplicate, 1 out of window)" \
  "$(jq -r '.by_harness_model[] | select(.harness=="claude" and .model=="claude-opus-5") | .calls' "$TMPROOT/report.json")" "2"
assert_eq "claude opus: input tokens summed across the 2 deduped calls" \
  "$(jq -r '.by_harness_model[] | select(.harness=="claude" and .model=="claude-opus-5") | .input' "$TMPROOT/report.json")" "310000"
assert_eq "claude sonnet: 2 sessions across the worker fixtures" \
  "$(jq -r '.by_harness_model[] | select(.harness=="claude" and .model=="claude-sonnet-5") | .sessions' "$TMPROOT/report.json")" "2"
assert_eq "claude haiku subagent call is counted" \
  "$(jq -r '.by_harness_model[] | select(.harness=="claude" and .model=="claude-haiku-5") | .calls' "$TMPROOT/report.json")" "1"
assert_eq "codex sol: 1 session summarized from the rollout fixture" \
  "$(jq -r '.by_harness_model[] | select(.harness=="codex" and .model=="gpt-5.6-sol") | .sessions' "$TMPROOT/report.json")" "1"
assert_eq "codex sol: last token_count total is what is reported" \
  "$(jq -r '.by_harness_model[] | select(.harness=="codex" and .model=="gpt-5.6-sol") | .input' "$TMPROOT/report.json")" "2000"
assert_eq "opencode reports ok when sqlite3 and the db are present" \
  "$(jq -r .opencode_status "$TMPROOT/report.json")" "ok"

head1 "AC-2: session classification"
assert_eq "interactive class present for the repos-path session" \
  "$(jq -r '.by_class_model[] | select(.class=="interactive" and .model=="claude-opus-5") | .model' "$TMPROOT/report.json")" "claude-opus-5"
assert_eq "interactive class also covers the second real model" \
  "$(jq -r '.by_class_model[] | select(.class=="interactive" and .model=="claude-fable-5") | .model' "$TMPROOT/report.json")" "claude-fable-5"
assert_eq "worker class total calls (2 workspaces, 1 call each)" \
  "$(jq -r '[.by_class_model[] | select(.class=="worker") | .calls] | add' "$TMPROOT/report.json")" "2"
assert_eq "subagent class is distinguished from worker even under orca-workspaces" \
  "$(jq -r '.by_class_model[] | select(.class=="subagent") | .model' "$TMPROOT/report.json")" "claude-haiku-5"

head1 "AC-2: context histogram and waste signals"
assert_eq "one call lands in the 50k-150k context bucket" \
  "$(jq -r '.context_histogram."50k_150k"' "$TMPROOT/report.json")" "1"
assert_eq "one call lands in the 150k-300k context bucket (also >200k interactive)" \
  "$(jq -r '.context_histogram."150k_300k"' "$TMPROOT/report.json")" "1"
assert_eq "interactive calls over 200k context" \
  "$(jq -r '.waste.interactive_calls_over_200k_context' "$TMPROOT/report.json")" "1"
assert_eq "one Write call recorded" "$(jq -r '.waste.write_calls' "$TMPROOT/report.json")" "1"
assert_eq "one Edit call recorded" "$(jq -r '.waste.edit_calls' "$TMPROOT/report.json")" "1"
assert_eq "the interactive session spans over 4h (10:00 to 15:30)" \
  "$(jq -r '.waste.sessions_over_4h' "$TMPROOT/report.json")" "1"

head1 "AC-2: worker sessions per story (repo-stripped, suffix-stripped)"
# Regression: this used to be the raw encoded project-dir string
# (-home-devbox-orca-workspaces-agent-flow-kit-afk-te-4-review), not the bare
# story id. Exact match, not endswith, so a regression cannot hide again.
assert_eq "story key is the bare workspace name, not the raw project dir" \
  "$(jq -r '.worker_sessions_per_story[] | select(.sessions == 2) | .story' "$TMPROOT/report.json")" "afk-te-4"
assert_eq "afk-te-4 story combines the -review and base workspaces" \
  "$(jq -r '.worker_sessions_per_story[] | select(.story == "afk-te-4") | .sessions' "$TMPROOT/report.json")" "2"

head1 "AC-2: oversized tool result waste signal (generated at run time, not committed)"
TOOLRESULT_DIR="$TMPROOT/toolresult-claude/-home-devbox-repos-jlengelbrecht-agent-flow-kit"
mkdir -p "$TOOLRESULT_DIR"
cp "$FIXTURES"/claude/-home-devbox-repos-jlengelbrecht-agent-flow-kit/*.jsonl "$TOOLRESULT_DIR/"
big="$(head -c 21000 /dev/zero | tr '\0' 'x')"
printf '{"timestamp":"2026-09-20T10:07:00.000Z","sessionId":"sess-interactive-1","message":{"content":[{"type":"tool_result","content":"%s"}]}}\n' "$big" >> "$TOOLRESULT_DIR/session-a.jsonl"
out_big="$(AFK_USAGE_CLAUDE_PROJECTS_DIR="$TMPROOT/toolresult-claude" afk_usage_report --json --days 7)"
assert_eq "one oversized (>20KB) tool result is detected" "$(jq -r '.waste.oversized_tool_results' <<<"$out_big")" "1"

head1 "AC-2: codex sessions with >1000 token_count events (generated at run time)"
BIGCODEX="$TMPROOT/bigcodex/sessions"
mkdir -p "$BIGCODEX"
{
  echo '{"timestamp":"2026-09-20T20:10:01.000Z","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}'
  for i in $(seq 1 1001); do
    printf '{"timestamp":"2026-09-20T20:%02d:%02d.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":%d,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":10}}}}\n' \
      $(( (i / 60) % 60 )) $(( i % 60 )) "$i"
  done
} > "$BIGCODEX/rollout-big.jsonl"
out_bigcodex="$(AFK_USAGE_CLAUDE_PROJECTS_DIR="$TMPROOT/empty-claude" AFK_USAGE_CODEX_HOMES="$TMPROOT/bigcodex" afk_usage_report --json --days 7)"
assert_eq "one codex session exceeds 1000 token_count events" \
  "$(jq -r '.waste.codex_sessions_over_1000_tc_events' <<<"$out_bigcodex")" "1"

head1 "AC-3: missing price table refuses the whole verb"
err="$(AFK_USAGE_PRICES_FILE="$TMPROOT/no-such-prices.yaml" afk_usage_report --json --days 7 2>&1 1>/dev/null)"
rc=0
AFK_USAGE_PRICES_FILE="$TMPROOT/no-such-prices.yaml" afk_usage_report --json --days 7 >/dev/null 2>&1 || rc=$?
assert_eq "usage-report exits non-zero when the price table is unreadable" "$rc" "1"
case "$err" in
  *USAGE_PRICES_UNREADABLE*) ok "error names USAGE_PRICES_UNREADABLE" ;;
  *) bad "error names USAGE_PRICES_UNREADABLE" "got: $err" ;;
esac

head1 "AC-2: an unpriced model reports an unknown, not a crash, cost"
UNPRICED_DIR="$TMPROOT/unpriced-claude/-home-devbox-repos-jlengelbrecht-agent-flow-kit"
mkdir -p "$UNPRICED_DIR"
echo '{"timestamp":"2026-09-20T10:00:00.000Z","sessionId":"sess-unpriced","requestId":"req-u1","message":{"id":"msg-u1","model":"some-unpriced-model","usage":{"input_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":10}}}' \
  > "$UNPRICED_DIR/session.jsonl"
out_unpriced="$(AFK_USAGE_CLAUDE_PROJECTS_DIR="$TMPROOT/unpriced-claude" AFK_USAGE_CODEX_HOMES="$TMPROOT/empty-codex" afk_usage_report --json --days 7)"
assert_eq "unpriced model cost is reported as unknown, run still succeeds" \
  "$(jq -r '.by_harness_model[] | select(.model=="some-unpriced-model") | .cost' <<<"$out_unpriced")" "unknown"

head1 "AC-4: nothing is written; the verb is read-only"
before="$(find "$FIXTURES" -type f | sort | xargs -I{} sha256sum {} 2>/dev/null | sha256sum)"
afk_usage_report --json --days 7 >/dev/null
after="$(find "$FIXTURES" -type f | sort | xargs -I{} sha256sum {} 2>/dev/null | sha256sum)"
assert_eq "fixture tree is byte-identical after a run" "$after" "$before"

head1 "--days validation and human-mode rendering"
rc=0
afk_usage_report --json --days notanumber >/dev/null 2>&1 || rc=$?
assert_eq "non-numeric --days is a usage failure" "$rc" "$AFK_EXIT_USAGE"
human="$(afk_usage_report --days 7)"
case "$human" in
  *"observations, not routing guidance"*) ok "human output carries the disclaimer" ;;
  *) bad "human output carries the disclaimer" "got: $human" ;;
esac

head1 "regression: human rendering does not fan out into one report per row"
# Bug: .by_harness_model[] used as a bare generator inside a string-concat
# pipeline reran the WHOLE report once per model, each copy showing only that
# one row. The fixtures now carry 4+ distinct claude models plus a
# "<synthetic>" one, so a collapse back to a single row is caught here.
assert_eq "the report header appears exactly once" \
  "$(grep -c '^agent-flow-kit usage-report' <<<"$human")" "1"
model_lines="$(awk '/== per harness x model ==/{f=1;next} /^$/{f=0} f' <<<"$human" | grep -c .)"
json_models="$(jq -r '.by_harness_model | length' "$TMPROOT/report.json")"
assert_eq "human 'per harness x model' line count matches the JSON group count" "$model_lines" "$json_models"
case "$human" in
  *"claude-fable-5"*) ok "a second real model (claude-fable-5) appears in human output" ;;
  *) bad "a second real model (claude-fable-5) appears in human output" "got: $human" ;;
esac
case "$human" in
  *"claude-sonnet-5"*) ok "codex and opencode rows are not crowded out (claude-sonnet-5 present)" ;;
  *) bad "codex and opencode rows are not crowded out (claude-sonnet-5 present)" "got: $human" ;;
esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
