#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf -- "$TMP"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
no() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }
eq() { if [[ "$2" == "$3" ]]; then ok; else no "$1 expected=$3 got=$2"; fi; }
wait_title_starts() { local prefix="$1" tries=60 value; while ((tries-- > 0)); do value="$(jq -r '.[]|select(.handle=="self")|.title' "$terminals")"; [[ "$value" == "$prefix"* ]] && return 0; sleep 0.1; done; return 1; }
wait_title_contains() { local part="$1" tries=60 value; while ((tries-- > 0)); do value="$(jq -r '.[]|select(.handle=="self")|.title' "$terminals")"; [[ "$value" == *"$part"* ]] && return 0; sleep 0.1; done; return 1; }
wait_owned() { local directory="$1" tries=60 value; while ((tries-- > 0)); do value="$(jq -r '.state' "$directory"/*.json 2>/dev/null || true)"; [[ "$value" == OWNED ]] && return 0; sleep 0.1; done; return 1; }
wait_rename_after() { local count="$1" tries=60 value; while ((tries-- > 0)); do value="$(grep -c '^terminal rename ' "$log" || true)"; ((value > count)) && return 0; sleep 0.1; done; return 1; }

fake="$TMP/orca"; terminals="$TMP/terminals.json"; log="$TMP/orca.log"
printf '%s\n' '[{"handle":"self","title":"User title"},{"handle":"foreign","title":"Foreign title"}]' >"$terminals"
# shellcheck disable=SC2016
{
  printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' '[[ "${1:-}" != --version ]] || { echo 1.4.216; exit 0; }' 'printf "%s\n" "$*" >>"$AFK_FAKE_LOG"'
  printf '%s\n' '[[ -z "${AFK_FAKE_DELAY:-}" ]] || sleep "$AFK_FAKE_DELAY"' 'verb="${1:-} ${2:-}"; shift 2; handle=""; title=""'
  printf '%s\n' 'while (($#)); do case "$1" in --terminal) handle="$2"; shift 2;; --title) title="$2"; shift 2;; *) shift;; esac; done'
  printf '%s\n' 'if [[ "$verb" == "terminal show" ]]; then if [[ "${AFK_FAKE_SHOW_FOREIGN:-0}" == 1 ]]; then handle=foreign; fi; jq -nc --argjson terminal "$(jq -c --arg h "$handle" '\''map(select(.handle==$h))[0]'\'' "$AFK_FAKE_TERMINALS")" '\''{result:{terminal:$terminal}}'\''; exit; fi'
  printf '%s\n' 'if [[ "$verb" == "terminal rename" ]]; then jq --arg h "$handle" --arg t "$title" '\''map(if .handle==$h then .title=$t else . end)'\'' "$AFK_FAKE_TERMINALS" >"$AFK_FAKE_TERMINALS.tmp"; mv "$AFK_FAKE_TERMINALS.tmp" "$AFK_FAKE_TERMINALS"; jq -nc --arg h "$handle" --arg t "$title" '\''{result:{rename:{handle:$h,title:$t}}}'\''; exit; fi' 'exit 1'
} >"$fake"; chmod +x "$fake"
# The fake reaches the adapter only through the resolver's host config.
printf '{"orca_bin":"%s"}\n' "$fake" >"$TMP/host.json"

cache="$TMP/status.json"; runtime_cache="$TMP/runtime"; mkdir -p "$runtime_cache"
jq -n '{schema_version:"1.0",kind:"lifecycle_result",source_eligibility:{revision_relation:"SAME"},orchestration:{state:"ACTIVE",session:{mode:"ORCH",persona:"PM",task:"AFK-TITLE",phase:"implementation",needs_human:false}},dispatch_monitor:{state:"WATCHING",dispatches:[]},findings:[],runtime:{subscription:{state:"ACTIVE"}}}' >"$cache"
common=(AFK_HOST_CONFIG="$TMP/host.json" AFK_FAKE_LOG="$log" AFK_FAKE_TERMINALS="$terminals" AFK_STATUS_CACHE="$cache" AFK_STATUS_CACHE_DIR="$runtime_cache" AFK_ORCA_TITLE_STATE_DIR="$TMP/title-state" ORCA_TERMINAL_HANDLE=self ORCA_WORKTREE_ID=parent-marker)

# No Orca session marker means no observation and no mutation.
env -u ORCA_WORKTREE_ID -u ORCA_WORKTREE_PATH AFK_HOST_CONFIG="$TMP/host.json" AFK_FAKE_LOG="$log" AFK_FAKE_TERMINALS="$terminals" AFK_STATUS_CACHE="$cache" \
  ORCA_TERMINAL_HANDLE=self "$ROOT/adapters/orca-title.sh" --harness codex
if [[ ! -e "$log" ]]; then ok; else no "publisher ran outside an Orca-managed session"; fi

# The hot-path entry returns before a deliberately slow fake CLI, while the
# background worker renames only the exported handle.
start="$(date +%s%N)"
env "${common[@]}" AFK_FAKE_DELAY=0.5 AFK_ORCA_TITLE_TIMEOUT_SECONDS=2 "$ROOT/adapters/orca-title.sh" --background --harness codex
elapsed_ms=$(( ($(date +%s%N) - start) / 1000000 ))
if ((elapsed_ms < 300)); then ok; else no "background publisher blocked for ${elapsed_ms}ms"; fi
if wait_title_starts AFK; then ok; else no "background title was not published"; fi
wait_owned "$TMP/title-state" || no "background ownership receipt was not settled"
title_record="$(find "$TMP/title-state" -name '*.json' -type f -print -quit)"
eq "title ownership evidence is private" "$(stat -c '%a' "$title_record")" 600
eq "foreign terminal title is untouched" "$(jq -r '.[]|select(.handle=="foreign")|.title' "$terminals")" "Foreign title"
if grep -F 'terminal rename --terminal self --title AFK ' "$log" >/dev/null && ! grep -F -- '--terminal foreign' "$log" >/dev/null; then ok; else no "rename did not stay on the exact handle"; fi
if ! grep -F 'terminal list' "$log" >/dev/null; then ok; else no "publisher searched for a fallback terminal"; fi

rename_count="$(grep -c '^terminal rename ' "$log")"
env "${common[@]}" AFK_ORCA_TITLE_INTERVAL_SECONDS=60 "$ROOT/adapters/orca-title.sh" --harness codex
eq "throttle suppresses duplicate rename work" "$(grep -c '^terminal rename ' "$log")" "$rename_count"

# Unavailable and stale cache states remain visible instead of being promoted
# to a healthy title.
env "${common[@]}" AFK_STATUS_CACHE="$TMP/missing.json" AFK_ORCA_TITLE_INTERVAL_SECONDS=0 "$ROOT/adapters/orca-title.sh" --harness codex
eq "unavailable cache is truthful in title" "$(jq -r '.[]|select(.handle=="self")|.title' "$terminals")" 'AFK UNAVAILABLE[STATUS_UNAVAILABLE]'
touch -d '@100' "$cache"
env "${common[@]}" AFK_STATUS_NOW=200 AFK_ORCA_TITLE_INTERVAL_SECONDS=0 "$ROOT/adapters/orca-title.sh" --harness opencode
if [[ "$(jq -r '.[]|select(.handle=="self")|.title' "$terminals")" == STALE* ]]; then ok; else no "stale cache was not visible in title"; fi

# Control bytes are removed and the configured maximum is enforced.
jq '.orchestration.session.task="line\u001b[31m\nnext"' "$cache" >"$TMP/control.json"; touch "$TMP/control.json"
env "${common[@]}" AFK_STATUS_CACHE="$TMP/control.json" AFK_ORCA_TITLE_INTERVAL_SECONDS=0 AFK_ORCA_TITLE_MAX_LENGTH=48 "$ROOT/adapters/orca-title.sh" --harness claude
title="$(jq -r '.[]|select(.handle=="self")|.title' "$terminals")"
if (( ${#title} <= 48 )) && [[ "$title" != *$'\033'* && "$title" != *$'\n'* ]]; then ok; else no "title length/control sanitization failed"; fi

# Restore is allowed only while the exact installed title is still present.
env "${common[@]}" AFK_ORCA_TITLE_INTERVAL_SECONDS=0 "$ROOT/adapters/orca-title.sh" --restore --harness claude
eq "owned title restores original user title" "$(jq -r '.[]|select(.handle=="self")|.title' "$terminals")" 'User title'
env "${common[@]}" "$ROOT/adapters/orca-title.sh" --enable --harness claude
env "${common[@]}" AFK_ORCA_TITLE_INTERVAL_SECONDS=0 "$ROOT/adapters/orca-title.sh" --harness claude
jq 'map(if .handle=="self" then .title="User override" else . end)' "$terminals" >"$TMP/t"; mv "$TMP/t" "$terminals"
before_drift="$(grep -c '^terminal rename ' "$log")"
env "${common[@]}" AFK_ORCA_TITLE_INTERVAL_SECONDS=0 "$ROOT/adapters/orca-title.sh" --harness claude
env "${common[@]}" "$ROOT/adapters/orca-title.sh" --restore --harness claude
eq "user title drift is preserved" "$(jq -r '.[]|select(.handle=="self")|.title' "$terminals")" 'User override'
eq "drift causes no rename or restore" "$(grep -c '^terminal rename ' "$log")" "$before_drift"

# A spoofed show response cannot redirect the later rename.
spoof_before="$(grep -c '^terminal rename ' "$log")"
env "${common[@]}" AFK_ORCA_TITLE_STATE_DIR="$TMP/spoof-state" AFK_FAKE_SHOW_FOREIGN=1 AFK_ORCA_TITLE_INTERVAL_SECONDS=0 "$ROOT/adapters/orca-title.sh" --harness codex
eq "foreign show response is refused" "$(grep -c '^terminal rename ' "$log")" "$spoof_before"

# A stalled Orca call is killed by the adapter's own bound.
bounded_start="$(date +%s%N)"
env "${common[@]}" AFK_ORCA_TITLE_STATE_DIR="$TMP/bounded-state" AFK_FAKE_DELAY=3 AFK_ORCA_TITLE_TIMEOUT_SECONDS=1 "$ROOT/adapters/orca-title.sh" --harness codex
bounded_ms=$(( ($(date +%s%N) - bounded_start) / 1000000 ))
if ((bounded_ms < 1800)); then ok; else no "stalled Orca call was not bounded (${bounded_ms}ms)"; fi

# Concurrent event publishers serialize under flock and produce one rename.
jq 'map(if .handle=="self" then .title="Concurrent prior" else . end)' "$terminals" >"$TMP/t"; mv "$TMP/t" "$terminals"
dup_before="$(grep -c '^terminal rename ' "$log")"
env "${common[@]}" AFK_STATUS_NOW=200 AFK_ORCA_TITLE_STATE_DIR="$TMP/dup-state" AFK_FAKE_DELAY=0.3 "$ROOT/adapters/orca-title.sh" --background --harness opencode
env "${common[@]}" AFK_STATUS_NOW=200 AFK_ORCA_TITLE_STATE_DIR="$TMP/dup-state" AFK_FAKE_DELAY=0.3 "$ROOT/adapters/orca-title.sh" --background --harness opencode
wait_rename_after "$dup_before" || no "concurrent publisher never renamed"
sleep 0.8
eq "concurrent publishers issue one rename" "$(grep -c '^terminal rename ' "$log")" "$((dup_before + 1))"

# An identical user-authored title is never adopted as AFK ownership.
identical_before="$(grep -c '^terminal rename ' "$log")"
env "${common[@]}" AFK_STATUS_NOW=200 AFK_ORCA_TITLE_STATE_DIR="$TMP/identical-state" AFK_ORCA_TITLE_INTERVAL_SECONDS=0 "$ROOT/adapters/orca-title.sh" --harness opencode
eq "identical-looking title is not renamed" "$(grep -c '^terminal rename ' "$log")" "$identical_before"
if [[ -z "$(find "$TMP/identical-state" -name '*.json' -type f -print -quit)" ]]; then ok; else no "identical-looking user title was adopted"; fi

# Hermes uses the same publisher when its read-only card runs in Orca.
jq 'map(if .handle=="self" then .title="Hermes prior" else . end)' "$terminals" >"$TMP/t"; mv "$TMP/t" "$terminals"
env "${common[@]}" AFK_ORCA_TITLE_STATE_DIR="$TMP/hermes-state" "$ROOT/adapters/hermes/status-card.sh" >/dev/null
if wait_title_contains 'cli=hermes/'; then ok; else no "Hermes did not publish the universal title"; fi

# The resolver's --version handshake runs inside the adapter's own bound, not
# the library's 10 s default.
printf '#!/usr/bin/env bash\nsleep 30\n' >"$TMP/hang-version-orca"; chmod +x "$TMP/hang-version-orca"
printf '{"orca_bin":"%s"}\n' "$TMP/hang-version-orca" >"$TMP/hang-host.json"
start_ms="$(date +%s%3N)"
env "${common[@]}" AFK_HOST_CONFIG="$TMP/hang-host.json" AFK_ORCA_TITLE_STATE_DIR="$TMP/hang-state" \
  AFK_ORCA_TITLE_INTERVAL_SECONDS=0 AFK_ORCA_TITLE_TIMEOUT_SECONDS=1 "$ROOT/adapters/orca-title.sh" --harness codex
elapsed_ms=$(( $(date +%s%3N) - start_ms ))
if ((elapsed_ms < 4000)); then ok; else no "a hanging handshake held the title tick for ${elapsed_ms}ms"; fi

printf '%s passed, %s failed\n' "$pass" "$fail"
((fail == 0))
