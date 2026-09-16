#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
passed=0
failed=0

ok() { passed=$((passed + 1)); }
no() { printf 'FAIL: %s\n' "$1" >&2; failed=$((failed + 1)); }

out="$("$ROOT/adapters/worker-context.sh" instruction --harness claude --session absent)"
if [[ -z "$out" ]]; then ok; else no "unbound session publishes no instruction"; fi

hook="$TMP/context-hook"
printf '#!/usr/bin/env bash\nexit 0\n' >"$hook"
chmod 700 "$hook"
mkdir -p "$TMP/events"
out="$(env AFK_WORKER_IDENTITY=worker:test AFK_RUN_ID=run-1 AFK_STORY_ID=story-1 \
  AFK_STORY_PATH="$TMP/story.md" AFK_CYCLE=1 AFK_DISPATCH_ID=dispatch-1 \
  AFK_OWNING_PM=run:run-1 AFK_DELEGATING_PM=run:run-1 \
  AFK_CONTEXT_EVENT_HOOK="$hook" AFK_CONTEXT_EVENT_DIR="$TMP/events" \
  "$ROOT/adapters/worker-context.sh" instruction --harness claude --session worker-session)"
if [[ "$out" == AFK\ CONTINUATION\ REQUIRED:* ]]; then ok; else no "bound worker receives continuation instruction"; fi

pm_dir="$TMP/pm"
mkdir -p "$pm_dir"
jq -nc --arg p "$(pwd -P)" '{schema:"afk-pm-ownership/2",owned:true,role:"PM",harness:"claude",
  session:"pm-session",terminal:"term-1",worktree:{id:"worktree-1",path:$p}}' >"$pm_dir/ownership.json"
out="$(env AFK_PM_DIR="$pm_dir" ORCA_TERMINAL_HANDLE=term-1 \
  "$ROOT/adapters/worker-context.sh" instruction --harness claude --session pm-session)"
if [[ "$out" == AFK\ PM\ CONTINUATION\ REQUIRED:* ]]; then ok; else no "bound PM receives PM continuation instruction"; fi

empty_pm="$TMP/no-terminal"
env -u ORCA_TERMINAL_HANDLE AFK_PM_DIR="$empty_pm" \
  "$ROOT/adapters/pm-session.sh" observe --harness claude --session ignored
if [[ ! -e "$empty_pm" ]]; then ok; else no "PM adapter without terminal is side-effect free"; fi

printf '%s passed, %s failed\n' "$passed" "$failed"
(( failed == 0 ))
