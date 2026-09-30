#!/usr/bin/env bash
# Claude statusLine compositor. The original command is invoked once with the
# exact JSON bytes Claude supplied on stdin and its lines are printed
# untouched; AFK's cache-only alert line goes above them and its own line below.
# All AFK side effects are bounded and fail open.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${AFK_STATE_DIR:-${XDG_STATE_HOME:-${HOME:+$HOME/.local/state}}/agent-flow-kit}"
record="$STATE_DIR/adapters/claude.json"
# shellcheck disable=SC1091
. "$HERE/runtime-scope.sh" 2>/dev/null || true
# The owner's saved command. Without jq, fall back to a minimal sed parse of the
# two flat JSON strings (handles \" \\ \/ escapes, which is what a shell command
# needs); the owner's lines must survive a missing jq.
json_str() { # file key
  sed -En 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' "$1" 2>/dev/null | head -n1 | sed -E 's/\\(["\\/])/\1/g'
}
read_prior() {
  local backup="" cmd=""
  [[ "${AFK_CLAUDE_COMPOSING:-0}" != 1 && -r "$record" ]] || return 0
  if command -v jq >/dev/null 2>&1; then backup="$(jq -r '.backup // ""' "$record" 2>/dev/null)"
  else backup="$(json_str "$record" backup)"; fi
  [[ -n "$backup" && -r "$backup" ]] || return 0
  if command -v jq >/dev/null 2>&1; then cmd="$(jq -r '.value.command // ""' "$backup" 2>/dev/null)"
  else cmd="$(json_str "$backup" command)"; fi
  printf '%s' "$cmd"
}
if ! input="$(mktemp "${TMPDIR:-/tmp}/afk-claude-status.XXXXXX" 2>/dev/null)"; then
  # No scratch space: hand stdin straight to the owner's command, unbounded as
  # it was before AFK composed it. AFK adds nothing.
  prior="$(read_prior)"
  if [[ -n "$prior" && "$prior" != "$0" ]]; then AFK_CLAUDE_COMPOSING=1 exec /bin/sh -c "$prior" 2>/dev/null; fi
  exit 0
fi
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
# Prior (owner) command: its own time bound, run in its own process group so a
# timeout takes the whole tree (and its lock files' holders) with it. Portable:
# no timeout/gtimeout needed.
prior="$(read_prior)"
PRIOR_T="${AFK_CLAUDE_PRIOR_TIMEOUT_SECONDS:-8}"; [[ "$PRIOR_T" =~ ^[0-9]+(\.[0-9]+)?$ ]] || PRIOR_T=8
now="${AFK_STATUS_NOW:-$(date -u +%s)}"
mtime() { stat -Lc %Y "$1" 2>/dev/null || stat -Lf %m "$1" 2>/dev/null || printf 0; }
prior_state=none; pkeep="$input.keep"; pout="$input.out"; pmark="$input.timedout"
trap 'rm -f -- "$input" "$pkeep" "$pout" "$pmark"' EXIT
: >"$pkeep"
if [[ -n "$prior" && "$prior" != "$0" ]]; then
  set -m
  AFK_CLAUDE_COMPOSING=1 /bin/sh -c "$prior" <"$input" >"$pout" 2>/dev/null &
  ppid=$!
  # The watchdog is its own process group too, so stopping it also stops its sleep.
  ( sleep "$PRIOR_T"; : >"$pmark"; kill -TERM -- "-$ppid"; sleep 0.3; kill -KILL -- "-$ppid" ) >/dev/null 2>&1 </dev/null &
  wd=$!
  set +m
  wait "$ppid" 2>/dev/null
  kill -- "-$wd" >/dev/null 2>&1; wait "$wd" >/dev/null 2>&1
  if [[ -e "$pmark" ]]; then prior_state=timeout
  else
    while IFS= read -r l || [[ -n "$l" ]]; do [[ -n "$l" ]] && printf '%s\n' "$l"; done <"$pout" >"$pkeep"
    [[ -s "$pkeep" ]] && prior_state=ok
  fi
  last_good="${AFK_STATUS_CACHE_DIR:-$(afk_default_status_cache_dir 2>/dev/null || true)}"
  last_good="${last_good:+$last_good/prior-last-good.out}"
  if [[ "$prior_state" == ok && -n "$last_good" ]]; then
    ( umask 077; mkdir -p -- "${last_good%/*}" && cp -- "$pkeep" "$last_good.tmp.$$" && mv -f -- "$last_good.tmp.$$" "$last_good" ) 2>/dev/null || true
  elif [[ "$prior_state" != ok && -n "$last_good" && -s "$last_good" ]] \
      && (( now - $(mtime "$last_good") <= 300 )); then
    cp -- "$last_good" "$pkeep" 2>/dev/null && prior_state=replayed
  fi
fi

args=(--harness claude --form claude --prior "$prior_state")
# Usage line whenever the owner's lines are absent and nothing was replayed.
[[ "$prior_state" == none || "$prior_state" == timeout ]] && args+=(--usage)
tagged="$("$HERE/render-status.sh" "${args[@]}" 2>/dev/null || true)"
# Layout: alert, the owner's lines untouched, then AFK's own lines.
while IFS=$'\t' read -r tag body; do [[ "$tag" == A ]] && printf '%s\n' "$body"; done <<<"$tagged"
cat -- "$pkeep"
for want in L U V; do
  while IFS=$'\t' read -r tag body; do [[ "$tag" == "$want" ]] && printf '%s\n' "$body"; done <<<"$tagged"
done
exit 0
