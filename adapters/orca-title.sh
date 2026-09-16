#!/usr/bin/env bash
# Publish AFK's cache-only compact segment as the current Orca tab title.
# Every external call is bounded and names the exact exported terminal handle.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="publish"; HARNESS="${AFK_STATUS_HARNESS:-NOT_EVALUATED}"
while (($#)); do
  case "$1" in
    --background) MODE="background" ;;
    --restore) MODE="restore" ;;
    --enable) MODE="enable" ;;
    --harness) (( $# >= 2 )) || exit 2; HARNESS="$2"; shift ;;
    *) exit 2 ;;
  esac
  shift
done
case "$HARNESS" in claude|codex|opencode|hermes) : ;; *) exit 0 ;; esac

terminal="${ORCA_TERMINAL_HANDLE:-}"
# ORCA_WORKTREE_ID/PATH is the managed-session marker. Its value is not used as
# a selector: only the exact terminal handle may be targeted.
[[ -n "$terminal" && ( -n "${ORCA_WORKTREE_ID:-}" || -n "${ORCA_WORKTREE_PATH:-}" ) ]] || exit 0
orca_bin="${ORCA_CLI_COMMAND:-${AFK_ORCA_BIN:-orca}}"

if [[ "$MODE" == background ]]; then
  nohup "$0" --harness "$HARNESS" </dev/null >/dev/null 2>&1 &
  exit 0
fi

cache_base="${XDG_CACHE_HOME:-${HOME:+$HOME/.cache}}"
state_dir="${AFK_ORCA_TITLE_STATE_DIR:-${cache_base:+$cache_base/agent-flow-kit/orca-titles}}"
[[ -n "$state_dir" ]] || exit 0
mkdir -p "$state_dir" 2>/dev/null || exit 0
chmod 700 "$state_dir" 2>/dev/null || true
if command -v sha256sum >/dev/null 2>&1; then
  key="$(printf '%s' "$terminal" | sha256sum | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  key="$(printf '%s' "$terminal" | shasum -a 256 | awk '{print $1}')"
else
  exit 0
fi
record="$state_dir/$key.json"
command -v flock >/dev/null 2>&1 || exit 0
exec 9>"$state_dir/$key.lock" || exit 0
flock -n 9 || exit 0

atomic_write() {
  local value="$1" tmp
  tmp="$(mktemp "$state_dir/.orca-title.XXXXXX")" || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  printf '%s\n' "$value" >"$tmp" && mv -f -- "$tmp" "$record"
}

owned=""
if [[ -e "$record" ]]; then
  owned="$(jq -ce --arg t "$terminal" '
    select(.schema=="afk-orca-title-ownership/1" and .terminal==$t and
      (.state|IN("CAPTURED","OWNED","RESTORING","RESTORED")) and
      (.prior_title|type)=="string" and (.installed_title|type)=="string" and
      ((.pending_title|type)=="string" or .pending_title==null) and
      (.last_attempt_epoch|type)=="number")' "$record" 2>/dev/null)" || exit 0
fi

if [[ "$MODE" == enable ]]; then
  [[ -z "$owned" || "$(jq -r .state <<<"$owned")" != RESTORED ]] || rm -f -- "$record"
  exit 0
fi

bound=""; command -v timeout >/dev/null 2>&1 && bound=timeout
[[ -n "$bound" ]] || { command -v gtimeout >/dev/null 2>&1 && bound=gtimeout; }
[[ -n "$bound" ]] || exit 0
timeout_seconds="${AFK_ORCA_TITLE_TIMEOUT_SECONDS:-2}"
[[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || exit 0
max_length="${AFK_ORCA_TITLE_MAX_LENGTH:-120}"
[[ "$max_length" =~ ^[1-9][0-9]*$ && "$max_length" -le 160 ]] || exit 0

safe_prior() {
  local value="$1" clean
  clean="$(printf '%s' "$value" | jq -Rrs 'gsub("[\u0000-\u001F\u007F]";"") | .[0:160]' 2>/dev/null)" || return 1
  [[ "$value" == "$clean" ]]
}

show_exact() {
  local shown got_handle got_title
  shown="$($bound "$timeout_seconds" "$orca_bin" terminal show --terminal "$terminal" --json 2>/dev/null)" || return 1
  got_handle="$(jq -r '.result.terminal.handle // .terminal.handle // .result.handle // .handle // empty' <<<"$shown" 2>/dev/null)"
  [[ "$got_handle" == "$terminal" ]] || return 1
  got_title="$(jq -r '.result.terminal.title // .terminal.title // .result.title // .title // empty' <<<"$shown" 2>/dev/null)"
  printf '%s' "$got_title"
}

rename_exact() {
  local title="$1" receipt receipt_handle receipt_title
  receipt="$($bound "$timeout_seconds" "$orca_bin" terminal rename --terminal "$terminal" --title "$title" --json 2>/dev/null)" || return 1
  receipt_handle="$(jq -r '.result.rename.handle // .result.terminal.handle // .terminal.handle // .result.handle // .handle // empty' <<<"$receipt" 2>/dev/null)"
  receipt_title="$(jq -r '.result.rename.title // .result.terminal.title // .terminal.title // .result.title // .title // empty' <<<"$receipt" 2>/dev/null)"
  [[ "$receipt_handle" == "$terminal" && "$receipt_title" == "$title" ]] || return 1
}

now="$(date +%s)"
if [[ "$MODE" == restore ]]; then
  [[ -n "$owned" ]] || exit 0
  state="$(jq -r .state <<<"$owned")"
  [[ "$state" == OWNED || "$state" == RESTORING ]] || exit 0
  current="$(show_exact)" || exit 0
  installed="$(jq -r .installed_title <<<"$owned")"
  prior="$(jq -r .prior_title <<<"$owned")"
  safe_prior "$prior" || exit 0
  if [[ "$state" == RESTORING && "$current" == "$prior" ]]; then
    restored="$(jq -c --argjson now "$now" '.state="RESTORED"|.installed_title=.prior_title|.pending_title=null|.last_success_epoch=$now' <<<"$owned")"
    atomic_write "$restored" || true
    exit 0
  fi
  [[ "$current" == "$installed" ]] || exit 0
  if [[ "$state" == OWNED ]]; then
    restoring="$(jq -c --argjson now "$now" '.state="RESTORING"|.last_attempt_epoch=$now' <<<"$owned")"
    atomic_write "$restoring" || exit 0
  else restoring="$owned"; fi
  rename_exact "$prior" || exit 0
  [[ "$(show_exact)" == "$prior" ]] || exit 0
  restored="$(jq -c --argjson now "$now" '.state="RESTORED"|.installed_title=.prior_title|.pending_title=null|.last_success_epoch=$now' <<<"$restoring")"
  atomic_write "$restored" || true
  exit 0
fi

interval="${AFK_ORCA_TITLE_INTERVAL_SECONDS:-5}"
[[ "$interval" =~ ^[0-9]+$ ]] || exit 0
if [[ -n "$owned" ]]; then
  previous_attempt="$(jq -r .last_attempt_epoch <<<"$owned")"
  if ((now >= previous_attempt && now - previous_attempt < interval)); then exit 0; fi
  state="$(jq -r .state <<<"$owned")"
  [[ "$state" == OWNED || "$state" == CAPTURED ]] || exit 0
fi

# render-status is cache-only. jq strips control characters and truncates by
# Unicode code point, so terminal escape/newline injection cannot reach Orca.
segment="$("$HERE/render-status.sh" --harness "$HARNESS" 2>/dev/null || printf 'AFK UNAVAILABLE[STATUS_UNAVAILABLE]')"
title="$(printf '%s' "$segment" | jq -Rrs --argjson n "$max_length" 'gsub("[\u0000-\u001F\u007F]";"") | .[0:$n]' 2>/dev/null)" || exit 0
[[ -n "$title" ]] || title="AFK UNAVAILABLE[STATUS_UNAVAILABLE]"
if [[ -n "$owned" ]]; then
  owned="$(jq -c --argjson now "$now" '.last_attempt_epoch=$now' <<<"$owned")"
  atomic_write "$owned" || exit 0
fi
current="$(show_exact)" || exit 0

if [[ -z "$owned" ]]; then
  safe_prior "$current" || exit 0
  prior="$current"; installed="$current"
else
  state="$(jq -r .state <<<"$owned")"; prior="$(jq -r .prior_title <<<"$owned")"
  installed="$(jq -r .installed_title <<<"$owned")"
  if [[ "$state" == CAPTURED && "$current" == "$(jq -r '.pending_title // empty' <<<"$owned")" ]]; then
    promoted="$(jq -c --argjson now "$now" '.state="OWNED"|.installed_title=.pending_title|.pending_title=null|.last_success_epoch=$now' <<<"$owned")"
    atomic_write "$promoted" || true
    exit 0
  fi
  [[ "$current" == "$installed" ]] || exit 0
fi

if [[ "$current" == "$title" ]]; then
  # An identical-looking user title is not proof that AFK installed it.
  [[ -n "$owned" ]] || exit 0
  settled="$(jq -nc --arg t "$terminal" --arg h "$HARNESS" --arg prior "$prior" --arg installed "$title" --argjson now "$now" \
    '{schema:"afk-orca-title-ownership/1",state:"OWNED",terminal:$t,harness:$h,
      prior_title:$prior,installed_title:$installed,pending_title:null,last_attempt_epoch:$now,last_success_epoch:$now}')"
  atomic_write "$settled" || true
  exit 0
fi

captured="$(jq -nc --arg t "$terminal" --arg h "$HARNESS" --arg prior "$prior" --arg installed "$installed" --arg pending "$title" --argjson now "$now" \
  '{schema:"afk-orca-title-ownership/1",state:"CAPTURED",terminal:$t,harness:$h,
    prior_title:$prior,installed_title:$installed,pending_title:$pending,last_attempt_epoch:$now,last_success_epoch:null}')"
atomic_write "$captured" || exit 0
rename_exact "$title" || exit 0
[[ "$(show_exact)" == "$title" ]] || exit 0
settled="$(jq -c --argjson now "$now" '.state="OWNED"|.installed_title=.pending_title|.pending_title=null|.last_success_epoch=$now' <<<"$captured")"
atomic_write "$settled" || true
