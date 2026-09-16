#!/usr/bin/env bash
# Claude statusLine compositor. The original command is invoked once with the
# exact JSON bytes Claude supplied on stdin, then AFK's cache-only segment is
# prepended. All AFK side effects are bounded and fail open.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${AFK_STATE_DIR:-${XDG_STATE_HOME:-${HOME:+$HOME/.local/state}}/agent-flow-kit}"
record="$STATE_DIR/adapters/claude.json"
input="$(mktemp "${TMPDIR:-/tmp}/afk-claude-status.XXXXXX")" || exit 0
trap 'rm -f -- "$input"' EXIT
cat >"$input"
unset AFK_RUNTIME_SESSION_ID
session_id="$(jq -r '.session_id // .sessionID // .session.id // empty' "$input" 2>/dev/null || true)"
if [[ -n "$session_id" ]]; then export AFK_RUNTIME_SESSION_ID="$session_id"; fi

("$HERE/worker-context.sh" observe --harness claude --input "$input" >/dev/null 2>&1 </dev/null &)
"$HERE/pm-session.sh" observe --harness claude --input "$input" >/dev/null 2>&1 || true
"$HERE/publish-runtime.sh" --harness claude --input "$input" >/dev/null 2>&1 || true
"$HERE/refresh-status-cache.sh" --background >/dev/null 2>&1 || true
"$HERE/orca-title.sh" --background --harness claude >/dev/null 2>&1 || true
afk="$("$HERE/render-status.sh" --harness claude 2>/dev/null || printf 'AFK UNAVAILABLE[STATUS_UNAVAILABLE]')"

prior=""
if [[ "${AFK_CLAUDE_COMPOSING:-0}" != 1 && -r "$record" ]]; then
  backup="$(jq -r '.backup // ""' "$record" 2>/dev/null)"
  if [[ -n "$backup" && -r "$backup" ]]; then
    prior="$(jq -r '.value.command // ""' "$backup" 2>/dev/null)"
  fi
fi
prior_out=""
if [[ -n "$prior" && "$prior" != "$0" ]]; then
  bound=""; command -v timeout >/dev/null 2>&1 && bound=timeout
  [[ -z "$bound" ]] && command -v gtimeout >/dev/null 2>&1 && bound=gtimeout
  if [[ -n "$bound" ]]; then
    prior_out="$(AFK_CLAUDE_COMPOSING=1 "$bound" "${AFK_CLAUDE_PRIOR_TIMEOUT_SECONDS:-2}" bash -lc "$prior" <"$input" 2>/dev/null || true)"
  fi
fi
if [[ -n "$prior_out" ]]; then printf '%s | %s\n' "$afk" "$prior_out"; else printf '%s\n' "$afk"; fi
