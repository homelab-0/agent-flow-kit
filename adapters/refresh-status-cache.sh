#!/usr/bin/env bash
# Slow lifecycle production path. Call with --background from a harness event;
# render-status.sh never executes this command (or agent-flow-kit) itself.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Dynamic sibling resolved from this script's canonical directory.
# shellcheck disable=SC1091
. "$HERE/runtime-scope.sh"
DEFAULT_CACHE_DIR="$(afk_default_status_cache_dir 2>/dev/null || true)"
CACHE="${AFK_STATUS_CACHE:-${DEFAULT_CACHE_DIR:+$DEFAULT_CACHE_DIR/status.json}}"
INTERVAL="${AFK_STATUS_REFRESH_SECONDS:-5}"
MODE="foreground"
while (( $# )); do
  case "$1" in
    --background) MODE=background; shift ;;
    --cache) (( $# >= 2 )) || exit 2; CACHE="$2"; shift 2 ;;
    *) exit 2 ;;
  esac
done
[[ -n "$CACHE" && "$INTERVAL" =~ ^[0-9]+$ ]] || exit 1
if [[ "$MODE" == background ]]; then
  nohup "$0" --cache "$CACHE" </dev/null >/dev/null 2>&1 &
  exit 0
fi

status_bin="${AFK_STATUS_BIN:-}"
if [[ -z "$status_bin" && -x "$HERE/bin/agent-flow-kit" ]]; then status_bin="$HERE/bin/agent-flow-kit"; fi
if [[ -z "$status_bin" && -x "$HERE/../bin/agent-flow-kit" ]]; then status_bin="$HERE/../bin/agent-flow-kit"; fi
if [[ -z "$status_bin" ]]; then status_bin="$(command -v agent-flow-kit 2>/dev/null || true)"; fi
[[ -x "$status_bin" ]] || exit 1

mkdir -p -- "$(dirname "$CACHE")" || exit 1
lock="${CACHE}.refresh.lockdir"
lock_owner=""
lock_candidate=""
lock_reclaim="$lock/reclaim"
file_id() { stat -Lc '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null; }
open_file_id() { # descriptor path
  /usr/bin/stat -Lc '%d:%i' "$1" 2>/dev/null || /usr/bin/stat -f '%d:%i' "$1" 2>/dev/null \
    || /bin/stat -Lc '%d:%i' "$1" 2>/dev/null || /bin/stat -f '%d:%i' "$1" 2>/dev/null
}
process_incarnation() { # pid
  local stat_line fields boot_id stamp sum rest
  kill -0 "$1" 2>/dev/null || return 1
  if [[ -r "/proc/$1/stat" ]]; then
    stat_line="$(<"/proc/$1/stat")" || return 1
    stat_line="${stat_line##*) }"
    read -r -a fields <<<"$stat_line"
    [[ "${#fields[@]}" -ge 20 && "${fields[19]}" =~ ^[0-9]+$ ]] || return 1
    boot_id="$(</proc/sys/kernel/random/boot_id)" || return 1
    read -r sum rest <<<"$(printf '%s:%s' "$boot_id" "${fields[19]}" | LC_ALL=C cksum)"
    [[ -n "$sum" ]] || return 1
    printf '%s\n' "$sum"
    return 0
  fi
  stamp="$(LC_ALL=C TZ=UTC0 ps -p "$1" -o lstart= 2>/dev/null)" || return 1
  [[ -n "$stamp" ]] || return 1
  read -r sum rest <<<"$(printf '%s' "$stamp" | LC_ALL=C cksum)"
  [[ -n "$sum" ]] || return 1
  printf '%s\n' "$sum"
}
release_lock() {
  local owner_id="" candidate_id=""
  if [[ -n "$lock_owner" && -n "$lock_candidate" \
    && ! -L "$lock_owner" && -f "$lock_owner" \
    && ! -L "$lock_candidate" && -f "$lock_candidate" ]]; then
    owner_id="$(file_id "$lock_owner" 2>/dev/null || true)"
    candidate_id="$(file_id "$lock_candidate" 2>/dev/null || true)"
    if [[ -n "$owner_id" && "$owner_id" == "$candidate_id" ]]; then /bin/rm -f "$lock_owner"; fi
  fi
  if [[ -n "$lock_candidate" && ! -L "$lock_candidate" ]]; then
    /bin/rm -f "$lock_candidate"
  fi
  if [[ -n "$lock" ]]; then
    rmdir -- "$lock" 2>/dev/null || true
  fi
  lock_owner=""
  lock_candidate=""
}
read_lock_owner() { # path
  local value
  [[ ! -L "$1" && -f "$1" ]] || return 1
  value="$(<"$1")" || return 1
  [[ "$value" =~ ^([0-9]+)[[:space:]]([0-9]+|live)$ ]] || return 1
  LOCK_PID="${BASH_REMATCH[1]}"; LOCK_INC="${BASH_REMATCH[2]}"
}
lock_owner_is_live() { # pid incarnation
  local live_inc=""
  kill -0 "$1" 2>/dev/null || return 1
  live_inc="$(process_incarnation "$1" 2>/dev/null || true)"
  [[ "$2" == live || -z "$live_inc" || "$live_inc" == "$2" ]]
}
make_lock_candidate() {
  local self_inc attempt old_umask fd_id path_id after_fd after_path current_id
  self_inc="$(process_incarnation "$$" 2>/dev/null || printf live)"
  old_umask="$(umask)"
  for ((attempt=0; attempt<8; attempt++)); do
    lock_candidate="${lock}.candidate.$$.$self_inc.$attempt"
    umask 077
    set -C
    if exec 9>"$lock_candidate"; then
      set +C; umask "$old_umask"
      fd_id="$(open_file_id /dev/fd/9 2>/dev/null || true)"
      path_id="$(file_id "$lock_candidate" 2>/dev/null || true)"
      if [[ -n "$fd_id" && "$fd_id" == "$path_id" && ! -L "$lock_candidate" && -f "$lock_candidate" ]] \
        && printf '%s %s\n' "$$" "$self_inc" >&9; then
        after_fd="$(open_file_id /dev/fd/9 2>/dev/null || true)"
        after_path="$(file_id "$lock_candidate" 2>/dev/null || true)"
        exec 9>&-
        if [[ -n "$after_fd" && "$fd_id" == "$after_fd" && "$fd_id" == "$after_path" \
          && ! -L "$lock_candidate" && -f "$lock_candidate" ]]; then return 0; fi
      else
        exec 9>&-
      fi
      current_id="$(file_id "$lock_candidate" 2>/dev/null || true)"
      if [[ -n "$fd_id" && "$current_id" == "$fd_id" && ! -L "$lock_candidate" ]]; then
        /bin/rm -f "$lock_candidate"
      fi
      lock_candidate=""
      return 1
    else
      set +C; umask "$old_umask"
    fi
  done
  lock_candidate=""
  return 1
}
acquire_lock() {
  local owner_id reclaim_id attempt
  if ! (umask 077; mkdir -- "$lock") 2>/dev/null; then
    [[ ! -L "$lock" && -d "$lock" ]] || return 1
  fi
  lock_owner="$lock/owner"
  make_lock_candidate || { release_lock; return 1; }
  for ((attempt=0; attempt<6; attempt++)); do
    if [[ -e "$lock_reclaim" || -L "$lock_reclaim" ]]; then
      [[ ! -L "$lock_reclaim" && -f "$lock_reclaim" ]] || { release_lock; return 1; }
      if [[ ! -e "$lock_owner" && ! -L "$lock_owner" ]]; then
        /bin/rm -f "$lock_reclaim" || { release_lock; return 2; }
        continue
      fi
      read_lock_owner "$lock_owner" || { release_lock; return 1; }
      lock_owner_is_live "$LOCK_PID" "$LOCK_INC" && { release_lock; return 2; }
      owner_id="$(file_id "$lock_owner" 2>/dev/null || true)"; reclaim_id="$(file_id "$lock_reclaim" 2>/dev/null || true)"
      [[ -n "$owner_id" && "$owner_id" == "$reclaim_id" ]] || { release_lock; return 1; }
      if /bin/rm -f "$lock_owner"; then /bin/rm -f "$lock_reclaim"; continue; fi
      release_lock; return 2
    fi
    if [[ ! -e "$lock_owner" && ! -L "$lock_owner" ]]; then
      if /bin/ln "$lock_candidate" "$lock_owner" 2>/dev/null; then
        owner_id="$(file_id "$lock_owner" 2>/dev/null || true)"; reclaim_id="$(file_id "$lock_candidate" 2>/dev/null || true)"
        [[ -n "$owner_id" && "$owner_id" == "$reclaim_id" ]] && return 0
        release_lock; return 1
      fi
      continue
    fi
    read_lock_owner "$lock_owner" || { release_lock; return 1; }
    lock_owner_is_live "$LOCK_PID" "$LOCK_INC" && { release_lock; return 2; }
    /bin/ln "$lock_owner" "$lock_reclaim" 2>/dev/null || { release_lock; return 2; }
  done
  release_lock; return 2
}
lock_rc=0
acquire_lock || lock_rc=$?
[[ "$lock_rc" == 0 ]] || { [[ "$lock_rc" == 2 ]] && exit 0; exit 1; }
tmp=""
cleanup() {
  [[ -z "$tmp" ]] || rm -f -- "$tmp"
  release_lock
}
trap cleanup EXIT
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || printf 0; }
now="$(date -u +%s)"
if [[ -f "$CACHE" ]] && (( now - $(mtime "$CACHE") < INTERVAL )); then exit 0; fi
tmp="$(mktemp "${CACHE}.tmp.XXXXXX")" || exit 1
[[ "$tmp" == "${CACHE}.tmp."?????? && ! -L "$tmp" && -f "$tmp" ]] || exit 1
if "$status_bin" status --json >"$tmp" 2>/dev/null \
  && jq -e 'type=="object" and .kind=="lifecycle_result"
    and (.orchestration|type)=="object" and (.dispatch_monitor|type)=="object"' "$tmp" >/dev/null 2>&1; then
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$CACHE"
fi
