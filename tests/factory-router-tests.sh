#!/usr/bin/env bash
# factory-router-tests.sh — Hermetic tests for the factory's benchmark sync and
# benchmark-driven routing (lib/afk-smart-router.sh).
#
# Nothing here touches the network: the public feeds are read from fixture
# files through AFK_BENCHMARK_FEED_DIR, and harnesses are named through
# AFK_ROUTER_HARNESS_LIST.

set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0 FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s (%s)\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
head1(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi
}

export HOME="$TMPROOT/home"
export TMPDIR="$TMPROOT/tmp"
mkdir -p "$HOME/.config/afk" "$TMPDIR"
unset AFK_ROUTER_BENCHMARKS_FILE AFK_ROUTER_HARNESS_LIST AFK_ROUTER_SIGNALS_FILE \
      AFK_FACTORY_AGENT_RUNNER AFK_CURL_BIN AFK_SKIP_BENCHMARK_AUTOSYNC \
      AFK_BENCHMARK_FEED_DIR ARTIFICIAL_ANALYSIS_API_KEY AA_API_KEY \
      AFK_LITELLM_BASE_URL AFK_DISCOVERED_MODELS_FILE 2>/dev/null || true

# shellcheck source=/dev/null
. "$KIT_ROOT/lib/afk-smart-router.sh"

BASE="$KIT_ROOT/files/model-router/benchmarks.json"
FEEDS="$TMPROOT/feeds"
mkdir -p "$FEEDS"

# A leaderboard in the shape the dataset server returns. Named rows carry the
# catalog's models; filler rows pad the board to 45 so a model the board does
# not list sits below rank 45.
make_board() { # <value-field> <named-rows-json>
  jq -cn --arg vf "$1" --argjson named "$2" '
    ($named | map(.rank)) as $used |
    ($named + [range(1; 46) | select(. as $r | $used | index($r) | not) | {rank: ., model_name: ("Filler Model \(.) (High)")}])
    | sort_by(.rank)
    | {rows: map({row: ({model_name, rank, leaderboard_publish_date: "2026-11-11"} + {($vf): (2000 - (.rank * 10))})})}'
}

AGENT_ROWS='[
  {"rank":1,"model_name":"Claude Fable 5.2 (Max)"},
  {"rank":2,"model_name":"Claude Opus 5.5 (Max)"},
  {"rank":3,"model_name":"Gemini 4 Carbon (High)"},
  {"rank":4,"model_name":"Claude Sonnet 5.5 (Max)"},
  {"rank":5,"model_name":"Claude Fable 5.1 (Max)"},
  {"rank":6,"model_name":"GPT-6 Astra (Max)"},
  {"rank":7,"model_name":"GPT-6.1 Sol (Max)"},
  {"rank":9,"model_name":"Claude Opus 5.5 (High)"},
  {"rank":17,"model_name":"Grok 4.7 (xHigh)"},
  {"rank":32,"model_name":"Qwen3.8-Max"},
  {"rank":34,"model_name":"Grok 4.6 (xHigh)"},
  {"rank":43,"model_name":"Qwen3.8-27B"}
]'
WEBDEV_ROWS='[
  {"rank":2,"model_name":"Claude Opus 5.5 (Max)"},
  {"rank":3,"model_name":"Claude Sonnet 5.5 (xHigh)"},
  {"rank":1,"model_name":"Claude Fable 5.2 (xHigh)"},
  {"rank":7,"model_name":"Claude Fable 5.1 (Max)"},
  {"rank":9,"model_name":"Claude Sonnet 5.5 (High)"}
]'
TEXT_ROWS='[
  {"rank":1,"model_name":"Gemini 4 Carbon (High)"},
  {"rank":4,"model_name":"Claude Opus 5.5 (Max)"}
]'

make_board score  "$AGENT_ROWS"  > "$FEEDS/lmarena-agent.json"
make_board rating "$WEBDEV_ROWS" > "$FEEDS/lmarena-webdev.json"
make_board rating "$TEXT_ROWS"   > "$FEEDS/lmarena-text.json"
# One row with a rank that is not a number must be ignored, not crash the sync.
jq -c '.rows += [{row: {model_name: "GPT-6 Astra (Low)", rank: "n/a", score: 1}}]' "$FEEDS/lmarena-agent.json" > "$FEEDS/a.tmp" \
  && mv "$FEEDS/a.tmp" "$FEEDS/lmarena-agent.json"

bench() { jq -r --arg id "$2" --arg c "$3" --arg f "$4" '.candidates[] | select(.id == $id) | .benchmarks[$c][$f] | tostring' "$1"; }
base_score() { jq -r --arg id "$1" --arg c "$2" '.candidates[] | select(.id == $id) | .benchmarks[$c].score | tostring' "$BASE"; }
leftovers() { find "$1" -maxdepth 1 \( -name '*.tmp.*' -o -name '*.lock' -o -name '*.reap' \) 2>/dev/null | wc -l | tr -d ' '; }

# ============================================================================
head1 "1. A sync reads measured scores off the leaderboards"
# ============================================================================
OUT="$TMPROOT/sync1/benchmarks.json"
mkdir -p "$TMPROOT/sync1"
REC="$(AFK_BENCHMARK_FEED_DIR="$FEEDS" afk_router_sync_benchmarks "$OUT")"; RC=$?

assert_eq "A sync with reachable leaderboards succeeds" \
  "$RC:$(jq -r '.result' <<<"$REC"):$(jq -r '.schema' "$OUT")" "0:synced:afk-benchmark-catalog/3"

assert_eq "A model takes its best-ranked row across effort variants (Opus 5.5: #2 Max, not #9 High)" \
  "$(bench "$OUT" claude-opus-native coding_complex score):$(bench "$OUT" claude-opus-native coding_complex rank):$(bench "$OUT" claude-opus-native coding_complex basis):$(bench "$OUT" claude-opus-native coding_complex live)" \
  "97.1:2:measured:true"

assert_eq "Grok 4.7 is matched by its real leaderboard name and scored from rank 17" \
  "$(bench "$OUT" grok-4.7-native coding_complex score):$(bench "$OUT" grok-4.7-native coding_complex basis)" \
  "83.6:measured"

assert_eq "Grok 4.5 is not on the board: it does not borrow Grok 4.7's row and its estimate is capped below the last rank" \
  "$(bench "$OUT" opencode-grok-native coding_complex score):$(bench "$OUT" opencode-grok-native coding_complex basis):$(bench "$OUT" opencode-grok-native coding_complex live)" \
  "80:capped:false"

assert_eq "The local 27B model is scored from its own row (#43), not from the larger Qwen3.8-Max (#32)" \
  "$(bench "$OUT" litellm-local-coding coding_complex rank):$(bench "$OUT" litellm-local-coding coding_complex score)" \
  "43:80"

assert_eq "A frontier-reserved model keeps its fixed coding score but takes a measured webdev score for its own version (Fable 5.2 #1, not Fable 5.1 #7)" \
  "$(bench "$OUT" claude-fable-native coding_complex score):$(bench "$OUT" claude-fable-native coding_complex basis):$(bench "$OUT" claude-fable-native webdev rank):$(bench "$OUT" claude-fable-native webdev score)" \
  "$(base_score claude-fable-native coding_complex):null:1:97.5"

assert_eq "A security specialist is never rescored from a general leaderboard" \
  "$(jq -c '[.candidates[] | select(.id == "claude-mythos-native") | .benchmarks[] | (.basis // "none")] | unique' "$OUT")" \
  '["none"]'

assert_eq "Architecture blends the agent rank with the reasoning rank (Opus: 97.1*0.6 + 94.8*0.4)" \
  "$(bench "$OUT" claude-opus-native architecture score):$(bench "$OUT" claude-opus-native architecture text_score)" \
  "96.2:94.8"

assert_eq "Classes no feed measures stay fixed estimates and are not marked live" \
  "$(bench "$OUT" claude-sonnet-native coding_standard score):$(bench "$OUT" claude-sonnet-native coding_standard live)" \
  "$(base_score claude-sonnet-native coding_standard):null"

assert_eq "The receipt names the candidates a reachable board did not list, and counts measured scores" \
  "$(jq -c '.unmatched' <<<"$REC"):$(jq -r '.live_scores > 0' <<<"$REC"):$(jq -r '.feeds.swe_bench_official' <<<"$REC")" \
  '["opencode-grok-native"]:true:not_scored'

assert_eq "A row whose rank is not a number is dropped without failing the sync" \
  "$(bench "$OUT" codex-astra-native coding_complex rank)" "6"

assert_eq "A sync leaves no temp files beside the catalog and no scratch directory behind" \
  "$(leftovers "$TMPROOT/sync1"):$(find "$TMPDIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "0:0"

# ============================================================================
head1 "2. An unreachable feed keeps the last measured scores"
# ============================================================================
PARTIAL="$TMPROOT/feeds-no-text"
mkdir -p "$PARTIAL"
cp "$FEEDS/lmarena-agent.json" "$FEEDS/lmarena-webdev.json" "$PARTIAL/"
BEFORE_SYNC="$(bench "$OUT" agy-carbon-native research synced_epoch)"
sleep 1
REC2="$(AFK_BENCHMARK_FEED_DIR="$PARTIAL" afk_router_sync_benchmarks "$OUT")"; RC2=$?

assert_eq "With the reasoning board down, a measured research score is carried forward with its original sync time" \
  "$RC2:$(jq -r '.feeds.lmarena_text' <<<"$REC2"):$(bench "$OUT" agy-carbon-native research basis):$(bench "$OUT" agy-carbon-native research rank):$(bench "$OUT" agy-carbon-native research synced_epoch)" \
  "0:offline:measured:1:$BEFORE_SYNC"

assert_eq "Architecture keeps the carried reasoning half while the agent half is re-measured" \
  "$(bench "$OUT" claude-opus-native architecture score):$(bench "$OUT" claude-opus-native architecture text_score)" \
  "96.2:94.8"

# Age the carried entries past the carry window.
jq '(.candidates[].benchmarks[] | select(.feed == "lmarena_text") | .synced_epoch) |= (. - 1000)
    | (.candidates[].benchmarks.architecture | select(. != null and (.synced_epoch // null) != null) | .synced_epoch) |= (. - 1000)' \
  "$OUT" > "$TMPROOT/aged.json" && cp "$TMPROOT/aged.json" "$OUT"
AFK_BENCHMARK_FEED_DIR="$PARTIAL" AFK_BENCHMARK_CARRY_SEC=500 afk_router_sync_benchmarks "$OUT" >/dev/null
assert_eq "A carried score older than the carry window falls back to the fixed estimate" \
  "$(bench "$OUT" agy-carbon-native research basis):$(bench "$OUT" agy-carbon-native research score)" \
  "estimate:$(base_score agy-carbon-native research)"

AFK_BENCHMARK_FEED_DIR="$FEEDS" afk_router_sync_benchmarks "$OUT" >/dev/null
EMPTY="$TMPROOT/feeds-none"; mkdir -p "$EMPTY"
SUM_BEFORE="$(cksum < "$OUT")"
REC3="$(AFK_BENCHMARK_FEED_DIR="$EMPTY" afk_router_sync_benchmarks "$OUT")"; RC3=$?
assert_eq "With no leaderboard reachable, an existing catalog is left byte-for-byte unchanged and the sync reports it" \
  "$RC3:$(jq -r '.result' <<<"$REC3"):$([[ "$(cksum < "$OUT")" == "$SUM_BEFORE" ]] && printf same || printf changed)" \
  "3:feeds_unavailable:same"

FRESH="$TMPROOT/sync-fresh/benchmarks.json"; mkdir -p "$TMPROOT/sync-fresh"
AFK_BENCHMARK_FEED_DIR="$EMPTY" afk_router_sync_benchmarks "$FRESH" >/dev/null; RC4=$?
assert_eq "With no leaderboard reachable and no catalog yet, the fixed estimates are written and nothing is marked measured" \
  "$RC4:$(jq -r '[.candidates[].benchmarks[] | select((.live // false) == true)] | length' "$FRESH"):$(jq -r '.candidates | length' "$FRESH")" \
  "3:0:$(jq -r '.candidates | length' "$BASE")"

BROKEN="$TMPROOT/feeds-broken"; mkdir -p "$BROKEN"
printf '<html>503 Service Unavailable</html>' > "$BROKEN/lmarena-agent.json"
printf '{"error":"Job has been terminated"}' > "$BROKEN/lmarena-webdev.json"
printf '{"rows":[]}' > "$BROKEN/lmarena-text.json"
SUM_BEFORE="$(cksum < "$OUT")"
AFK_BENCHMARK_FEED_DIR="$BROKEN" afk_router_sync_benchmarks "$OUT" >/dev/null; RC5=$?
assert_eq "An HTML error page, an error object and an empty board all count as unreachable and corrupt nothing" \
  "$RC5:$([[ "$(cksum < "$OUT")" == "$SUM_BEFORE" ]] && printf same || printf changed):$(leftovers "$TMPROOT/sync1")" \
  "3:same:0"

# ============================================================================
head1 "3. The freshness check does not retry a failing sync on every route"
# ============================================================================
# The sync is replaced by a counter inside a child shell, so the check is of
# when the freshness logic decides to sync, not of the sync itself.
SYNC_CALLS="$TMPROOT/sync-calls"
FRESH_PROBE="$TMPROOT/fresh-probe.sh"
cat > "$FRESH_PROBE" <<'SH'
#!/usr/bin/env bash
# usage: fresh-probe.sh <kit-root> <calls-file> <ensure-calls>
. "$1/lib/afk-smart-router.sh"
calls_file="$2"; n="$3"
afk_router_sync_benchmarks() { printf 'x\n' >> "$calls_file"; return 3; }
for ((i = 0; i < n; i++)); do afk_router_ensure_fresh_benchmarks; done
SH
probe() { bash "$FRESH_PROBE" "$KIT_ROOT" "$SYNC_CALLS" "$1"; }
calls() { wc -l < "$SYNC_CALLS" | tr -d ' '; }
: > "$SYNC_CALLS"
CAT_HOME="$HOME/.config/afk/benchmarks.json"

rm -f "$CAT_HOME" "$CAT_HOME.sync-attempt"
probe 3
assert_eq "A missing catalog triggers one sync attempt, then waits out the retry window" "$(calls)" "1"

AFK_BENCHMARK_RETRY_SEC=0 probe 1
assert_eq "Once the retry window has passed, the sync is attempted again" "$(calls)" "2"

cp "$OUT" "$CAT_HOME"
rm -f "$CAT_HOME.sync-attempt"
probe 2
assert_eq "A fresh catalog on the current schema is not synced" "$(calls)" "2"

AFK_BENCHMARK_TTL_SEC=0 probe 3
assert_eq "A catalog past its TTL is synced once, not on every call" "$(calls)" "3"

rm -f "$CAT_HOME.sync-attempt"
AFK_BENCHMARK_TTL_SEC=not-a-number AFK_BENCHMARK_RETRY_SEC=junk probe 2
assert_eq "A non-numeric TTL or retry setting falls back to the default instead of erroring" "$(calls)" "3"

rm -f "$CAT_HOME.sync-attempt"
AFK_BENCHMARK_TTL_SEC=0 AFK_SKIP_BENCHMARK_AUTOSYNC=1 probe 2
assert_eq "AFK_SKIP_BENCHMARK_AUTOSYNC=1 turns the automatic sync off" "$(calls)" "3"

# ============================================================================
head1 "4. Routes say whether they rest on a measurement"
# ============================================================================
ROUTE_REPO="$TMPROOT/repo"; mkdir -p "$ROUTE_REPO"
route() { # <harness-list> <stage> <risk> [<catalog>]
  AFK_ROUTER_BENCHMARKS_FILE="${4:-$OUT}" AFK_ROUTER_HARNESS_LIST="$1" \
  AFK_ROUTER_SIGNALS_FILE="$TMPROOT/signals-empty.json" \
    afk_router_select_candidate "$ROUTE_REPO" "$2" "$3"
}
printf '{}\n' > "$TMPROOT/signals-empty.json"

R_COMPLEX="$(route "claude,codex,agy" build high)"
assert_eq "A high-risk build is routed on a measured score and says so" \
  "$(jq -r '"\(.task_class):\(.harness)/\(.model):\(.benchmark_basis):\(.benchmark_live)"' <<<"$R_COMPLEX")" \
  "coding_complex:claude/opus:measured:true"

R_STD="$(route "claude,codex,agy" build low)"
assert_eq "A low-risk build is routed on a fixed estimate and says so" \
  "$(jq -r '"\(.task_class):\(.benchmark_basis):\(.benchmark_live)"' <<<"$R_STD")" \
  "coding_standard:estimate:false"

R_GROK="$(route "grok,opencode" build high)"
assert_eq "Between two Grok models, the ranked one beats the unranked one (was the reverse on fixed estimates)" \
  "$(jq -r '"\(.harness)/\(.model):\(.benchmark_basis)"' <<<"$R_GROK")" \
  "grok/grok-4.7:measured"

R_GROK_BASE="$(route "grok,opencode" build high "$BASE")"
assert_eq "On the unsynced catalog every score is an estimate" \
  "$(jq -r '.benchmark_basis' <<<"$R_GROK_BASE")" "estimate"

R_NONE="$(route "devin" build low)"
assert_eq "When nothing is eligible the fallback route says so and records what it saw" \
  "$(jq -r '"\(.router_source):\(.no_eligible_candidate):\(.installed_harnesses | join(","))"' <<<"$R_NONE")" \
  "fallback-default:true:devin"

# A catalog where a free model is the best reviewer on paper.
FREE_CAT="$TMPROOT/free-reviewer.json"
jq '.candidates += [{id:"free-reviewer", harness:"opencode", launch_class:"opencode-native", entitlement_pool:"opencode-free",
      cost_class:"free", is_free:true, model:"opencode/free-reviewer", canonical_model:"opencode/free-reviewer", model_family:"deepseek",
      tier:"standard", effort:"medium", supported_efforts:["medium"], window_tokens:200000,
      benchmarks:{coding_review:{score:99.9, benchmark:"estimate"}, coding_standard:{score:99.9, benchmark:"estimate"}}}]' "$OUT" > "$FREE_CAT"
R_REV="$(AFK_ROUTER_BENCHMARKS_FILE="$FREE_CAT" AFK_ROUTER_HARNESS_LIST="claude,opencode" AFK_ROUTER_SIGNALS_FILE="$TMPROOT/signals-empty.json" \
  afk_router_select_candidate "$ROUTE_REPO" review-code low anthropic reviewer 1 code 20)"
assert_eq "A review that can gate an unattended merge never goes to a free model, however it scores" \
  "$(jq -r '"\(.cost_class):\(.model == "opencode/free-reviewer")"' <<<"$R_REV")" "subscription:false"
R_REV_OK="$(AFK_ROUTER_ALLOW_FREE_REVIEWERS=1 AFK_ROUTER_BENCHMARKS_FILE="$FREE_CAT" AFK_ROUTER_HARNESS_LIST="claude,opencode" AFK_ROUTER_SIGNALS_FILE="$TMPROOT/signals-empty.json" \
  afk_router_select_candidate "$ROUTE_REPO" review-code low anthropic reviewer 1 code 20)"
assert_eq "A project that allows free reviewers gets one" "$(jq -r '.model' <<<"$R_REV_OK")" "opencode/free-reviewer"
R_BUILD_FREE="$(AFK_ROUTER_PREFER_FREE=1 AFK_ROUTER_BENCHMARKS_FILE="$FREE_CAT" AFK_ROUTER_HARNESS_LIST="claude,opencode" AFK_ROUTER_SIGNALS_FILE="$TMPROOT/signals-empty.json" \
  afk_router_select_candidate "$ROUTE_REPO" build low "" dev 1 code 20)"
assert_eq "The floor applies to reviews only: a low-risk build can still use the free model" "$(jq -r '.model' <<<"$R_BUILD_FREE")" "opencode/free-reviewer"

printf 'this is not json' > "$TMPROOT/signals-bad.json"
R_BADSIG="$(AFK_ROUTER_BENCHMARKS_FILE="$OUT" AFK_ROUTER_HARNESS_LIST="claude" AFK_ROUTER_SIGNALS_FILE="$TMPROOT/signals-bad.json" \
  afk_router_select_candidate "$ROUTE_REPO" build high)"
assert_eq "A corrupt signals file does not take routing down" \
  "$(jq -r '"\(.harness)/\(.model)"' <<<"$R_BADSIG" 2>/dev/null)" "claude/opus"

# ============================================================================
head1 "4b. Scores age out, small boards cap correctly, names match exactly"
# ============================================================================
AGED="$TMPROOT/aged-route.json"
jq '(.candidates[].benchmarks[] | select(.synced_epoch != null) | .synced_epoch) |= (. - 5000000)' "$OUT" > "$AGED"
R_AGED="$(AFK_ROUTER_BENCHMARKS_FILE="$AGED" AFK_ROUTER_HARNESS_LIST="claude,codex,agy" AFK_ROUTER_SIGNALS_FILE="$TMPROOT/signals-empty.json" \
  afk_router_select_candidate "$ROUTE_REPO" build high)"
assert_eq "A measurement older than the carry window is reported as stale at route time, not as live" \
  "$(jq -r '"\(.benchmark_basis):\(.benchmark_live)"' <<<"$R_AGED")" "stale:false"

SMALL="$TMPROOT/feeds-small"; mkdir -p "$SMALL"
make_board score '[{"rank":1,"model_name":"Claude Opus 5.5 (Max)"},{"rank":2,"model_name":"GPT-6 Astra (Max)"},{"rank":3,"model_name":"Gemini 4 Carbon (High)"}]' | \
  jq '.rows |= map(select(.row.rank <= 10))' > "$SMALL/lmarena-agent.json"
SOUT="$TMPROOT/small/benchmarks.json"; mkdir -p "$TMPROOT/small"
AFK_BENCHMARK_FEED_DIR="$SMALL" afk_router_sync_benchmarks "$SOUT" >/dev/null
assert_eq "On a ten-model board an unlisted model is held at the score of rank 11 (89), not the floor" \
  "$(bench "$SOUT" claude-sonnet-native coding_complex score):$(bench "$SOUT" claude-sonnet-native coding_complex basis)" "89:capped"
assert_eq "An unlisted model whose estimate is already below that is left at its estimate" \
  "$(bench "$SOUT" opencode-grok-native coding_complex score):$(bench "$SOUT" opencode-grok-native coding_complex basis)" "87.0:estimate"

TXT_ONLY="$TMPROOT/feeds-text-age"; mkdir -p "$TXT_ONLY"; cp "$FEEDS/lmarena-agent.json" "$TXT_ONLY/"
TOUT="$TMPROOT/text-age/benchmarks.json"; mkdir -p "$TMPROOT/text-age"
AFK_BENCHMARK_FEED_DIR="$FEEDS" afk_router_sync_benchmarks "$TOUT" >/dev/null
jq '(.candidates[].benchmarks.architecture | select(. != null and .text_synced_epoch != null) | .text_synced_epoch) |= (. - 5000000)' "$TOUT" > "$TOUT.x" && mv "$TOUT.x" "$TOUT"
AFK_BENCHMARK_FEED_DIR="$TXT_ONLY" afk_router_sync_benchmarks "$TOUT" >/dev/null
assert_eq "The reasoning half of an architecture score expires on its own measurement time, even while the agent board is up" \
  "$(bench "$TOUT" claude-opus-native architecture text_score):$(bench "$TOUT" claude-opus-native architecture score)" "null:97.1"

NAMES="$(jq -rn '
  def norm: ascii_downcase | sub("\\s*\\((low|medium|high|xhigh|max|thinking)(,[^)]*)?\\)\\s*$"; "") | gsub("[^a-z0-9.]+"; " ") | sub("^ +"; "") | sub(" +$"; "");
  ["Claude Opus 5.5 (Max)", "Qwen3.8-Max (0902)", "GPT-5.6 Sol (xHigh, Codex Harness)", "GPT-6.1 Sol"] | map(norm) | join("|")')"
assert_eq "Only an effort suffix is dropped from a leaderboard name; a dated variant stays distinct" \
  "$NAMES" "claude opus 5.5|qwen3.8 max 0902|gpt 5.6 sol|gpt 6.1 sol"
grep -q 'def norm: ascii_downcase | sub("\\\\s\*\\\\((low|medium|high|xhigh|max|thinking)' "$KIT_ROOT/lib/afk-smart-router.sh" \
  && ok "The router uses that same name rule" || bad "The router uses that same name rule" "pattern differs from the test"

RENAMED="$TMPROOT/renamed/benchmarks.json"; mkdir -p "$TMPROOT/renamed"
AFK_BENCHMARK_FEED_DIR="$FEEDS" afk_router_sync_benchmarks "$RENAMED" >/dev/null
jq '(.candidates[] | select(.id == "agy-carbon-native") | .benchmarks.research.match) = "Gemini 3 Carbon"' "$RENAMED" > "$RENAMED.x" && mv "$RENAMED.x" "$RENAMED"
AFK_BENCHMARK_FEED_DIR="$PARTIAL" afk_router_sync_benchmarks "$RENAMED" >/dev/null
assert_eq "A score measured for a model of a different name is not carried to the candidate that replaced it" \
  "$(bench "$RENAMED" agy-carbon-native research basis)" "estimate"

chmod 644 "$OUT"; AFK_BENCHMARK_FEED_DIR="$FEEDS" afk_router_sync_benchmarks "$OUT" >/dev/null
assert_eq "Rewriting the catalog keeps its file mode" "$(stat -c %a "$OUT" 2>/dev/null || stat -f %Lp "$OUT")" "644"

# A first run with no network writes estimates; the next attempt after the
# retry spacing must still try the boards.
: > "$SYNC_CALLS"
rm -f "$CAT_HOME" "$CAT_HOME.sync-attempt"
AFK_BENCHMARK_FEED_DIR="$EMPTY" afk_router_sync_benchmarks "$CAT_HOME" >/dev/null
AFK_BENCHMARK_RETRY_SEC=0 probe 1
assert_eq "A catalog with no measured score is retried on the retry spacing, not left for a day" "$(calls)" "1"

: > "$SYNC_CALLS"; rm -f "$CAT_HOME" "$CAT_HOME.sync-attempt"
SLOW_PROBE="$TMPROOT/slow-probe.sh"
cat > "$SLOW_PROBE" <<'SH'
#!/usr/bin/env bash
. "$1/lib/afk-smart-router.sh"
calls_file="$2"
afk_router_sync_benchmarks() { printf 'x\n' >> "$calls_file"; sleep 1; return 3; }
afk_router_ensure_fresh_benchmarks
SH
for _ in 1 2 3 4 5 6 7 8; do bash "$SLOW_PROBE" "$KIT_ROOT" "$SYNC_CALLS" & done; wait
assert_eq "Eight jobs that find the catalog missing at once start one sync between them" "$(calls)" "1"

CACHE_DIR="$TMPROOT/bincache"; mkdir -p "$CACHE_DIR/bin"
for b in a1 a2 a3 a4 a5 a6 a7 a8 a9 a10; do printf '#!/bin/sh\necho 1.0\n' > "$CACHE_DIR/bin/$b"; chmod +x "$CACHE_DIR/bin/$b"; done
for b in a1 a2 a3 a4 a5 a6 a7 a8 a9 a10; do
  ( AFK_ROUTER_BIN_CACHE_FILE="$CACHE_DIR/cache.json" AFK_HARNESS_BIN_DIR_OVERRIDE="$CACHE_DIR/bin" _afk_router_verify_binary "$b" >/dev/null ) &
done; wait
assert_eq "Ten concurrent availability checks all land in the shared cache" "$(jq 'length' "$CACHE_DIR/cache.json")" "10"

# ============================================================================
head1 "5. Concurrent jobs do not lose or corrupt pool signals"
# ============================================================================
SIG="$TMPROOT/sig/pool-signals.json"; mkdir -p "$TMPROOT/sig"
export AFK_ROUTER_SIGNALS_FILE="$SIG"
# Background subshells share $$, exactly like the jobs of one poll pass.
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  ( afk_router_mark_pool_degraded "pool-$i" "stage_timeout_900s" ) &
done
wait
assert_eq "Twelve concurrent marks all land in one valid file, with no temp or lock left behind" \
  "$(jq -r '.pools | length' "$SIG" 2>/dev/null):$(leftovers "$TMPROOT/sig")" "12:0"

afk_router_mark_model_unavailable "claude-mythos-5-2" "403 model_not_found"
assert_eq "Quarantining one model keeps every pool mark" \
  "$(jq -r '"\(.pools | length):\(.unavailable_models | keys | join(","))"' "$SIG")" "12:claude-mythos-5-2"

afk_router_mark_pool_degraded "openai-plus" "401 Unauthorized: refresh token was revoked"
afk_router_mark_pool_degraded "xai-grok" "429 rate limit exceeded"
assert_eq "Auth failures get a day, rate limits an hour, anything else fifteen minutes" \
  "$(jq -r '"\(.pools["openai-plus"].degraded_kind)/\(.pools["openai-plus"].ttl_sec):\(.pools["xai-grok"].degraded_kind)/\(.pools["xai-grok"].ttl_sec):\(.pools["pool-1"].degraded_kind)/\(.pools["pool-1"].ttl_sec)"' "$SIG")" \
  "auth/86400:quota/3600:transient/900"

printf '{"pools":' > "$SIG"   # a write cut off mid-file
afk_router_mark_pool_degraded "anthropic-max" "stage_timeout_900s"
assert_eq "A truncated signals file is replaced by a valid one on the next mark" \
  "$(jq -r '.pools | keys | join(",")' "$SIG" 2>/dev/null)" "anthropic-max"

mkdir "$SIG.lock"; touch -d '2 minutes ago' "$SIG.lock" 2>/dev/null || touch -t "$(date -v-2M +%Y%m%d%H%M.%S 2>/dev/null)" "$SIG.lock"
afk_router_mark_pool_degraded "antigravity-pool" "runtime_exit_1"
assert_eq "A lock left by a killed writer is taken over" \
  "$(jq -r '.pools | has("antigravity-pool")' "$SIG"):$(leftovers "$TMPROOT/sig")" "true:0"

# Several writers waiting on one orphaned lock: exactly one takes it over at
# a time, and every mark lands.
rm -f "$SIG"; mkdir "$SIG.lock"; touch -d '2 minutes ago' "$SIG.lock" 2>/dev/null || touch -t "$(date -v-2M +%Y%m%d%H%M.%S 2>/dev/null)" "$SIG.lock"
for i in 1 2 3 4 5 6; do ( afk_router_mark_pool_degraded "orphan-$i" "stage_timeout_900s" ) & done; wait
assert_eq "Six writers behind an orphaned lock all land their marks" \
  "$(jq -r '[.pools | keys[] | select(startswith("orphan-"))] | length' "$SIG"):$(leftovers "$TMPROOT/sig")" "6:0"
unset AFK_ROUTER_SIGNALS_FILE

# ============================================================================
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
