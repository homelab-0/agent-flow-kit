#!/usr/bin/env bash
# Codex hook JSON is supplied on stdin. Codex's native TUI status line owns
# continuous context/rate display. At session start the hook also emits one
# supported systemMessage so the AFK-specific cache segment is visible.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
input="$(mktemp "${TMPDIR:-/tmp}/afk-codex-hook.XXXXXX")" || exit 0
trap 'rm -f -- "$input"' EXIT
cat >"$input"
unset AFK_RUNTIME_SESSION_ID
hook_event="$(jq -r '.hook_event_name // empty' "$input" 2>/dev/null || true)"
session_id="$(jq -r '.session_id // .sessionID // .session.id // empty' "$input" 2>/dev/null || true)"
if [[ -n "$session_id" ]]; then export AFK_RUNTIME_SESSION_ID="$session_id"; fi
continuation_instruction=""
if [[ "$hook_event" == PreCompact ]]; then
  continuation_instruction="$("$HERE/worker-context.sh" instruction --harness codex --session "$session_id" 2>/dev/null || true)"
  "$HERE/worker-context.sh" compact --harness codex --input "$input" >/dev/null 2>&1 || true
fi
"$HERE/pm-session.sh" observe --harness codex --input "$input" >/dev/null 2>&1 || true
"$HERE/publish-runtime.sh" --harness codex --input "$input" >/dev/null 2>&1 || true
"$HERE/refresh-status-cache.sh" --background >/dev/null 2>&1 || true
"$HERE/orca-title.sh" --background --harness codex >/dev/null 2>&1 || true
segment="$("$HERE/render-status.sh" --harness codex 2>/dev/null || printf 'AFK UNAVAILABLE[STATUS_UNAVAILABLE]')"
if [[ "$hook_event" == PreCompact && -n "$continuation_instruction" ]]; then
  jq -nc --arg message "$segment | AFK CONTINUATION_REQUIRED: this compact event is bound to an AFK worker or PM; stop at the next safe boundary and follow the AFK continuation instruction after compaction." \
    '{continue:true,systemMessage:$message}' 2>/dev/null || true
else
  jq -nc --arg message "$segment" '{systemMessage:$message}' 2>/dev/null || true
fi
