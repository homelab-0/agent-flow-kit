#!/usr/bin/env bash
# afk-factory.sh — The AFK Software Factory Orchestrator & Situational Merge
# Approver.
#
# Drives work across projects on the host through a deterministic pipeline:
#   intake -> spec -> [ux] -> build -> gate -> review -> approve -> merged | needs-human
#
# Key guarantees:
# 1. Per-project dynamic agent hiring & retirement in Paperclip (BMAD personas
#    when present in the repo, built-in Factory roles otherwise).
# 2. Context-window monitoring & automatic agent replacement when any project
#    agent approaches its context limit (>= 80% or compaction).
# 3. Deterministic check gate (.afk/checks.sh from the base checkout) before
#    any reviewer runs and before merge.
# 4. Situational Merge Approver: auto-approves & merges clean, verified changes
#    within budget and outside protected paths; escalates protected paths,
#    oversized diffs, high-risk architectural changes, or exhausted repair loops
#    to the human board user in Paperclip.
#
# This file is SOURCED, never executed.

# shellcheck disable=SC2034,SC2154
if [[ -n "${AFK_FACTORY_SOURCED:-}" ]]; then
  return 0
fi
AFK_FACTORY_SOURCED=1

declare -F afk_roster_discover >/dev/null 2>&1 || . "$(dirname -- "${BASH_SOURCE[0]}")/afk-roster.sh"
declare -F afk_pch_ensure_project_team >/dev/null 2>&1 || . "$(dirname -- "${BASH_SOURCE[0]}")/afk-paperclip-hire.sh"
declare -F afk_harness_inspect_all >/dev/null 2>&1 || . "$(dirname -- "${BASH_SOURCE[0]}")/afk-harnesses.sh"
declare -F afk_tooling_discover >/dev/null 2>&1 || . "$(dirname -- "${BASH_SOURCE[0]}")/afk-tooling.sh"
declare -F afk_router_select_candidate >/dev/null 2>&1 || . "$(dirname -- "${BASH_SOURCE[0]}")/afk-smart-router.sh"

AFK_FACTORY_DEFAULT_MAX_ROUNDS=2
AFK_FACTORY_DEFAULT_MAX_LINES=800
AFK_FACTORY_DEFAULT_MAX_FILES=25

# afk_factory_default_config_json
afk_factory_default_config_json() {
  cat <<'JSON'
{
  "schema": "afk-factory-config/1",
  "max_rounds": 2,
  "merge_policy": "situational",
  "queue": "todo",
  "queue_label": "factory",
  "scope_paths": ["_bmad-output"],
  "land": "auto",
  "diff_budget": {
    "max_lines": 800,
    "max_files": 25
  },
  "protected_paths": [
    ".afk/checks.sh",
    ".afk/config.json",
    ".github/workflows/",
    "CODEOWNERS",
    "safety_validation",
    "migrations/",
    "networkpolicy"
  ],
  "router": {
    "mode": "smart",
    "litellm_base_url": "",
    "hindsight": {
      "build_stages": "advisory",
      "review_stages": "blind"
    }
  },
  "routing": {
    "intake": {"model": "sonnet", "effort": "medium", "window": 200000, "memory_mode": "advisory"},
    "research": {"model": "sonnet", "effort": "medium", "window": 200000, "memory_mode": "advisory"},
    "spec": {"model": "opus", "effort": "high", "window": 200000, "memory_mode": "advisory"},
    "ux": {"model": "sonnet", "effort": "medium", "window": 200000, "memory_mode": "advisory"},
    "build": {"model": "sonnet", "effort": "high", "window": 200000, "memory_mode": "advisory"},
    "review_low": {"model": "sonnet", "effort": "medium", "window": 200000, "memory_mode": "blind"},
    "review_medium": {"model": "sonnet", "effort": "high", "window": 200000, "memory_mode": "blind"},
    "review_high": {"model": "opus", "effort": "high", "window": 200000, "memory_mode": "blind"},
    "approve": {"model": "sonnet", "effort": "medium", "window": 200000, "memory_mode": "blind"}
  }
}
JSON
}

# afk_factory_init_repo <repo_path> <json_mode>
# Creates .afk/config.json and .afk/checks.sh if absent.
afk_factory_init_repo() {
  local repo="$1" json_mode="${2:-false}"
  if [[ -z "$repo" || ! -d "$repo" ]]; then
    afk_warn "factory init: repository path does not exist"
    return 1
  fi
  local abs_repo
  abs_repo="$(cd -P -- "$repo" 2>/dev/null && pwd -P)" || return 1
  mkdir -p "$abs_repo/.afk/jobs"
  local cfg_file="$abs_repo/.afk/config.json"
  local checks_file="$abs_repo/.afk/checks.sh"
  local created_cfg=false created_checks=false

  if [[ ! -f "$cfg_file" ]]; then
    afk_factory_default_config_json > "$cfg_file"
    created_cfg=true
  fi
  if [[ ! -f "$checks_file" ]]; then
    cat > "$checks_file" <<'SH'
#!/usr/bin/env bash
# .afk/checks.sh — Deterministic project gate executed by AFK Factory before
# review and before merge. Run from the base checkout against the job worktree.
set -euo pipefail
if [[ -f package.json ]] && command -v npm >/dev/null 2>&1; then
  npm test --if-present
elif [[ -f pyproject.toml || -f pytest.ini ]] && command -v pytest >/dev/null 2>&1; then
  pytest
elif [[ -x tests/run-tests.sh ]]; then
  bash tests/run-tests.sh
fi
SH
    chmod +x "$checks_file"
    created_checks=true
  fi
  local allowlist_file="$abs_repo/.afk/gates-allowlist"
  if [[ ! -f "$allowlist_file" ]]; then
    cat > "$allowlist_file" <<'AL'
# Commands a planned change may declare as its checks. One exact command per
# line, run from the repository root.
bash .afk/checks.sh
AL
  fi

  local roster fw
  roster="$(afk_roster_discover "$abs_repo")"
  fw="$(jq -r '.framework' <<<"$roster")"
  if [[ "$json_mode" == "true" ]]; then
    jq -cn \
      --arg repo "$abs_repo" \
      --arg fw "$fw" \
      --arg cfg "$cfg_file" \
      --arg chk "$checks_file" \
      --argjson c_cfg "$created_cfg" \
      --argjson c_chk "$created_checks" \
      '{ok: true, repo_path: $repo, framework: $fw, config_path: $cfg, checks_path: $chk, created_config: $c_cfg, created_checks: $c_chk}'
  else
    printf 'Initialized AFK Factory in %s (framework=%s)\n' "$abs_repo" "$fw"
  fi
  return 0
}

# afk_factory_load_config <repo_path>
# The repo's .afk/config.json laid over the built-in defaults, so a key the
# file leaves out keeps its default. Without that, a config that omits
# `protected_paths` protects nothing. A missing, empty or invalid file yields
# the defaults alone.
afk_factory_load_config() {
  local repo="$1" defaults merged
  defaults="$(afk_factory_default_config_json)"
  if [[ -s "$repo/.afk/config.json" ]]; then
    merged="$(jq -c -s 'if (.[1] | type) == "object" then .[0] * .[1] else .[0] end' \
      <(printf '%s' "$defaults") "$repo/.afk/config.json" 2>/dev/null)" || merged=""
    if [[ -n "$merged" ]]; then
      printf '%s\n' "$merged"
      return 0
    fi
  fi
  printf '%s\n' "$defaults"
}

# todo: every Todo issue can be built. label: only a Todo carrying queue_label.
_afk_factory_queue_mode() { # <repo>
  local cfg mode
  cfg="$(afk_factory_load_config "$1")"
  mode="$(jq -r '.queue // "todo"' <<<"$cfg" 2>/dev/null || printf 'todo')"
  [[ "$mode" == "label" ]] || mode="todo"
  printf '%s' "$mode"
}

_afk_factory_queue_label() { # <repo>
  local cfg label
  cfg="$(afk_factory_load_config "$1")"
  label="$(jq -r '.queue_label // "factory"' <<<"$cfg" 2>/dev/null || printf 'factory')"
  [[ -n "$label" && "$label" != "null" ]] || label="factory"
  printf '%s' "$label"
}

# First configured scope directory that holds a sprint-status file.
# Empty when this repo did not opt into that scope. Default is _bmad-output.
_afk_factory_bmad_scope_path() { # <repo>
  local repo="$1" cfg p
  [[ -d "$repo" ]] || return 1
  cfg="$(afk_factory_load_config "$repo")"
  while IFS= read -r p; do
    [[ -n "$p" && "$p" != "null" ]] || continue
    [[ "$p" == /* || "$p" == *".."* ]] && continue
    if [[ -f "$repo/$p/implementation-artifacts/sprint-status.yaml" ]]; then
      printf '%s' "$p"
      return 0
    fi
  done < <(jq -r '(.scope_paths // ["_bmad-output"])[]?' <<<"$cfg" 2>/dev/null)
  return 1
}

# Keep the host assigned. Clearing the assignee cancels the run that has to
# post the approval card, and the board then shows an ownerless In Review issue.
_afk_factory_in_review_body() { # <host_agent_id>
  jq -cn --arg a "${1:-}" '{status:"in_review"} + (if $a != "" then {assigneeAgentId:$a} else {} end)'
}

# Skip a consecutive copy of the same route event. A resumed stage that logs
# the identical attempt again does not grow route-history twice.
_afk_factory_append_route_event() { # <file> <json-line>
  local file="$1" line="$2" key="" last=""
  [[ -n "$file" && -n "$line" ]] || return 0
  line="${line//$'\n'/}"
  key="$(jq -c 'del(.ts)' <<<"$line" 2>/dev/null || true)"
  if [[ -s "$file" && -n "$key" ]]; then
    last="$(tail -n 1 -- "$file" | jq -c 'del(.ts)' 2>/dev/null || true)"
    [[ "$key" == "$last" ]] && return 0
  fi
  printf '%s\n' "$line" >> "$file"
}

# _afk_factory_commit_tmp <file>
# Renames <file>.tmp over <file> only when it holds a JSON object. A jq that
# failed on bad input leaves an empty temp file and still lets `&&` continue
# past a plain `mv`; that is how a job file gets blanked.
_afk_factory_commit_tmp() {
  local f="$1" t="$1.tmp"
  if [[ -s "$t" ]] && jq -e 'type == "object"' "$t" >/dev/null 2>&1; then
    mv -f -- "$t" "$f"
    return $?
  fi
  rm -f -- "$t"
  return 1
}

# The boot and start time of a process, so a PID the kernel handed out again
# is not mistaken for the runner that recorded it. A restarted container
# starts numbering PIDs from the bottom, which makes reuse the normal case.
_afk_factory_boot_id() {
  if declare -F afk_boot_identity >/dev/null 2>&1; then
    afk_boot_identity 2>/dev/null || true
  elif [[ -r /proc/sys/kernel/random/boot_id ]]; then
    cat /proc/sys/kernel/random/boot_id 2>/dev/null || true
  fi
}
_afk_factory_proc_start() { # <pid> ; rc 0 printed, 1 cannot tell, 2 no such process
  local pid="$1" out rc
  if declare -F afk_process_start_identity >/dev/null 2>&1; then
    out="$(afk_process_start_identity "$pid" 2>/dev/null)"; rc=$?
    [[ $rc -eq 0 ]] && printf '%s' "$out"
    return "$rc"
  fi
  kill -0 "$pid" 2>/dev/null || return 2
  return 1
}

# The name of this host as a lock owner sees it. Two pods can share one
# volume during a rollout; a PID is only meaningful on the host that wrote it.
_afk_factory_host_id() {
  local h
  h="$(uname -n 2>/dev/null || hostname 2>/dev/null || true)"
  printf '%s' "${h:-unknown-host}"
}

# _afk_factory_runner_record <pid> -> JSON naming <pid> as a job's runner.
# The caller passes its own $BASHPID: inside $(...) this function would see
# the short-lived command-substitution shell instead.
_afk_factory_runner_record() {
  local pid="${1:-$BASHPID}" start="" boot=""
  start="$(_afk_factory_proc_start "$pid" 2>/dev/null || true)"
  boot="$(_afk_factory_boot_id)"
  jq -cn --argjson pid "$pid" --arg start "$start" --arg boot "$boot" --arg host "$(_afk_factory_host_id)" \
    --arg token "$BASHPID.$RANDOM$RANDOM" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{pid: $pid, start: $start, boot: $boot, host: $host, token: $token, at: $at}'
}

# _afk_factory_runner_alive <owner.json>
#   0 the recorded runner is running, or that cannot be ruled out
#   1 it is provably gone
# A runner recorded by another host is never judged by a local PID: it counts
# as alive here, and only its heartbeat going stale lets it be replaced.
_afk_factory_runner_alive() {
  local rec="$1" stale_arg="${2:-}" pid start boot host now_boot cur rc
  if [[ ! -s "$rec" ]]; then
    # The lock exists and its record does not yet: a runner between the two
    # writes. Give it a moment before calling the lock abandoned.
    local d now mt
    d="$(dirname -- "$rec")"
    [[ -d "$d" ]] || return 1
    now="$(date -u +%s)"
    mt="$(stat -c %Y "$d" 2>/dev/null || stat -f %m "$d" 2>/dev/null || printf '0')"
    [[ "$mt" =~ ^[0-9]+$ ]] || mt="$now"
    (( now - mt < 30 )) && return 0
    return 1
  fi
  pid="$(jq -r '.pid // empty' "$rec" 2>/dev/null || true)"
  start="$(jq -r '.start // empty' "$rec" 2>/dev/null || true)"
  boot="$(jq -r '.boot // empty' "$rec" 2>/dev/null || true)"
  host="$(jq -r '.host // empty' "$rec" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  if [[ -n "$host" && "$host" != "$(_afk_factory_host_id)" ]]; then
    # Another host's PID cannot be checked from here. Its runner counts as
    # alive while the job's heartbeat is fresh, and as gone once it is
    # older than the stall threshold. Without that, a lock left by a pod
    # that was replaced would hold its job for good.
    # The last sign of life is the newest of the job's heartbeat, the lock
    # directory's time and the record's own time: a lock taken a moment ago
    # on a job whose heartbeat is old from an earlier wait is alive.
    local hb beat stale now ldmt at_ep sign
    case "$rec" in
      */.run.lock/owner.json) hb="$(dirname -- "$(dirname -- "$rec")")/heartbeat.json" ;;
      *) hb="$rec" ;;
    esac
    stale="${stale_arg:-${AFK_WATCHDOG_STALE_SEC:-900}}"
    [[ "$stale" =~ ^[0-9]+$ ]] || stale=900
    now="$(date -u +%s)"
    beat="$(jq -r '.last_beat_epoch // 0' "$hb" 2>/dev/null || printf '0')"
    [[ "$beat" =~ ^[0-9]+$ ]] || beat=0
    ldmt="$(stat -c %Y "$(dirname -- "$rec")" 2>/dev/null || stat -f %m "$(dirname -- "$rec")" 2>/dev/null || printf '0')"
    [[ "$ldmt" =~ ^[0-9]+$ ]] || ldmt=0
    at_ep="$(jq -r '(.at // "") | if . == "" then 0 else (try fromdateiso8601 catch 0) end' "$rec" 2>/dev/null || printf '0')"
    [[ "$at_ep" =~ ^[0-9]+$ ]] || at_ep=0
    sign="$beat"
    (( ldmt > sign )) && sign="$ldmt"
    (( at_ep > sign )) && sign="$at_ep"
    (( now - sign < stale )) && return 0
    return 1
  fi
  now_boot="$(_afk_factory_boot_id)"
  if [[ -n "$boot" && -n "$now_boot" && "$boot" != "$now_boot" ]]; then
    return 1
  fi
  cur="$(_afk_factory_proc_start "$pid" 2>/dev/null)"; rc=$?
  case "$rc" in
    0) [[ -z "$start" || "$cur" == "$start" ]] && return 0; return 1 ;;
    2) return 1 ;;
    *) kill -0 "$pid" 2>/dev/null && return 0; return 1 ;;
  esac
}

# _afk_factory_runner_killable <owner.json> -> 0 when the recorded runner is a
# process on this host whose start time matches the record. Anything less
# (another host, a record with no start time, a PID now used by another
# process) is never signalled.
_afk_factory_runner_killable() {
  local rec="$1" pid start host cur
  [[ -s "$rec" ]] || return 1
  pid="$(jq -r '.pid // empty' "$rec" 2>/dev/null || true)"
  start="$(jq -r '.start // empty' "$rec" 2>/dev/null || true)"
  host="$(jq -r '.host // empty' "$rec" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ && -n "$start" ]] || return 1
  [[ -z "$host" || "$host" == "$(_afk_factory_host_id)" ]] || return 1
  cur="$(_afk_factory_proc_start "$pid" 2>/dev/null)" || return 1
  [[ "$cur" == "$start" ]]
}

# _afk_factory_lock_steal <lock> -> 0 this caller removed the lock.
# Moving the directory aside is atomic, so of several callers that judged the
# same lock dead only one gets it; the rest find nothing to move and retry.
# Removing it in place let a slower caller delete a faster one's fresh lock.
_afk_factory_lock_steal() {
  local lock="$1" dead
  dead="$lock.dead.$BASHPID.$RANDOM"
  mv -- "$lock" "$dead" 2>/dev/null || return 1
  rm -rf -- "$dead" 2>/dev/null || true
  return 0
}

# _afk_factory_job_lock <job_dir> -> 0 this shell now runs the job, 1 another
# live runner does. One job must never be driven by two runners: the poll
# pass, the watchdog, review sync and `factory resume` can all reach the same
# job, and two of them would build, push and merge twice.
_afk_factory_job_lock() {
  local lock="$1/.run.lock" rec token me="$BASHPID" stale repo
  rec="$(_afk_factory_runner_record "$me")"
  # The stall threshold the project configured, so every caller judges a
  # foreign runner the same way the watchdog does.
  repo="$(cd -P -- "$1/../../.." 2>/dev/null && pwd -P || true)"
  stale="${AFK_WATCHDOG_STALE_SEC:-$(jq -r '.watchdog.stale_seconds // 900' "$repo/.afk/config.json" 2>/dev/null || printf '900')}"
  [[ "$stale" =~ ^[0-9]+$ ]] || stale=900
  if ! mkdir "$lock" 2>/dev/null; then
    _afk_factory_runner_alive "$lock/owner.json" "$stale" && return 1
    # Taking over a dead lock is done by one caller at a time, and that
    # caller writes its record before letting the next one look. Otherwise a
    # second caller that also judged the old lock dead removes the first
    # caller's fresh one.
    if ! mkdir "$lock.reap" 2>/dev/null; then
      local rmt now
      now="$(date -u +%s)"
      rmt="$(stat -c %Y "$lock.reap" 2>/dev/null || stat -f %m "$lock.reap" 2>/dev/null || printf '%s' "$now")"
      [[ "$rmt" =~ ^[0-9]+$ ]] && (( now - rmt > 30 )) && rmdir "$lock.reap" 2>/dev/null
      return 1
    fi
    if _afk_factory_runner_alive "$lock/owner.json" "$stale" || ! _afk_factory_lock_steal "$lock" || ! mkdir "$lock" 2>/dev/null; then
      rmdir "$lock.reap" 2>/dev/null
      return 1
    fi
    printf '%s\n' "$rec" > "$lock/owner.json" 2>/dev/null || true
    rmdir "$lock.reap" 2>/dev/null
  else
    printf '%s\n' "$rec" > "$lock/owner.json" 2>/dev/null || true
  fi
  # Confirm the record on disk is ours: a lock taken in the same instant by
  # another caller that also passed the checks above shows its own token.
  token="$(jq -r '.token' <<<"$rec" 2>/dev/null)"
  [[ "$(jq -r '.token // empty' "$lock/owner.json" 2>/dev/null)" == "$token" ]] || return 1
  AFK_FACTORY_LOCK_TOKEN="$token"
  return 0
}
_afk_factory_job_unlock() { # <job_dir>
  local lock="$1/.run.lock" held
  held="$(jq -r '.token // empty' "$lock/owner.json" 2>/dev/null || true)"
  # Only the runner that holds the lock releases it.
  [[ -z "$held" || "$held" == "${AFK_FACTORY_LOCK_TOKEN:-}" ]] || return 0
  rm -rf -- "$lock" 2>/dev/null || true
}

# The children of a process, from pgrep when it exists and from ps otherwise.
_afk_factory_children() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -P "$1" 2>/dev/null || true
  else
    ps -A -o pid= -o ppid= 2>/dev/null | awk -v p="$1" '$2 == p {print $1}'
  fi
}

# _afk_factory_kill_tree <pid>
# Ends a runner and everything it started. Killing the runner alone leaves its
# agent CLI editing the worktree while a replacement starts in the same place.
# Never signals this shell or any process it descends from.
_afk_factory_kill_tree() {
  local root="$1" kid p
  [[ "$root" =~ ^[0-9]+$ ]] || return 0
  local -a mine=() all=() queue=()
  p="$BASHPID"
  while [[ "$p" =~ ^[0-9]+$ ]] && (( p > 1 )); do
    mine+=("$p")
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d '[:space:]')"
  done
  mine+=("$$")
  for p in "${mine[@]}"; do [[ "$p" == "$root" ]] && return 0; done
  all=("$root"); queue=("$root")
  while (( ${#queue[@]} > 0 )); do
    local cur="${queue[0]}"; queue=("${queue[@]:1}")
    while IFS= read -r kid; do
      [[ "$kid" =~ ^[0-9]+$ ]] || continue
      local skip=false
      for p in "${mine[@]}"; do [[ "$p" == "$kid" ]] && skip=true; done
      [[ "$skip" == true ]] && continue
      all+=("$kid"); queue+=("$kid")
    done < <(_afk_factory_children "$cur")
  done
  kill -TERM "${all[@]}" 2>/dev/null || true
  sleep 2
  kill -KILL "${all[@]}" 2>/dev/null || true
}

# _afk_factory_strict_verdict <file> [<lines>]
# The verdict a stage output states on its `VERDICT:` line, or nothing.
# The verdict is the first word after the label. Text after it is allowed
# ("VERDICT: PASS — two notes below"), but a line naming a second verdict is
# not a verdict at all: "VERDICT: PASS or CHANGES_REQUESTED" is not a PASS.
_afk_factory_strict_verdict() {
  local file="$1" lines="${2:-8}" line first rest known="PASS CHANGES_REQUESTED ACCEPT REJECT NEEDS-INFO" k
  [[ -f "$file" ]] || return 0
  line="$(head -n "$lines" -- "$file" 2>/dev/null \
    | sed -n 's/^[[:space:]*`#>_-]*VERDICT:[[:space:]*`_]*//p' | head -n 1 \
    | tr '[:lower:]' '[:upper:]' | tr -d '*`\r')"
  [[ -n "$line" ]] || return 0
  first="$(printf '%s' "$line" | sed 's/^\([A-Z_-]*\).*/\1/')"
  rest="${line#"$first"}"
  # Punctuation becomes spaces so each word of the remainder stands alone.
  rest=" $(printf '%s' "$rest" | tr -c 'A-Z_-' ' ') "
  case " $known " in
    *" $first "*) ;;
    *) return 0 ;;
  esac
  for k in $known; do
    [[ "$rest" == *" $k "* ]] && return 0
  done
  printf '%s' "$first"
}

# _afk_factory_project_merge_policy <slug> [<repo>]
# The merge authority Josh set for the project in the Paperclip config:
# `pm` lets a clean change merge unattended, `human` (the default once a
# project is listed) never does. The project is found by slug and by
# checkout, and when they name different entries the stricter answer wins:
# running a job without --slug must not escape the project's setting.
# Empty when neither names a listed project.
_afk_factory_project_merge_policy() {
  local slug="$1" repo="${2:-}" path abs="" row r_slug r_path r_merge r_abs found=false strict=""
  path="$(afk_pc_config_path 2>/dev/null || true)"
  [[ -n "$path" && -f "$path" ]] || return 0
  [[ -n "$repo" ]] && abs="$(cd -P -- "$repo" 2>/dev/null && pwd -P || true)"
  # A config that cannot be read whole means a person merges: a malformed
  # row must not hide the projects after it and let a change merge.
  local rows
  if ! rows="$(jq -r '.projects[]? | objects
      | [((.slug // "") | tostring), ((.repo_path // "") | tostring),
         ((.merge // "") | if type == "string" and . != "" then . else "human" end)]
      | join("\u001f")' "$path" 2>/dev/null)"; then
    printf 'human'
    return 0
  fi
  # Each configured checkout is resolved the same way as the job's, so a
  # path written through a symlink still names the same project.
  # \x1f, not a tab: read collapses repeated tabs, which shifted an empty
  # field's neighbour into its place and turned "human" into nothing.
  while IFS=$'\x1f' read -r r_slug r_path r_merge; do
    [[ -n "$r_slug$r_path" ]] || continue
    [[ -n "$r_merge" ]] || r_merge="human"
    r_abs=""
    [[ -n "$r_path" ]] && r_abs="$(cd -P -- "$r_path" 2>/dev/null && pwd -P || printf '%s' "${r_path%/}")"
    if { [[ -n "$slug" && "$r_slug" == "$slug" ]]; } || { [[ -n "$abs" && -n "$r_abs" && "$r_abs" == "$abs" ]]; }; then
      found=true
      [[ "$r_merge" == "pm" ]] || strict="${strict:-$r_merge}"
    fi
  done < <(printf '%s\n' "$rows")
  [[ "$found" == true ]] || return 0
  printf '%s' "${strict:-pm}"
}

# The integration branch this task was cut from. Local main wins over
# origin/main: a stale remote would count earlier local merges as this task's diff.
# Used only for a job that recorded no base of its own.
_afk_factory_task_base_ref() {
  local wt="$1" cand
  for cand in main master origin/main origin/master; do
    if git -C "$wt" rev-parse --verify "$cand" >/dev/null 2>&1; then
      printf '%s' "$cand"
      return 0
    fi
  done
  printf 'HEAD~1'
}

# _afk_factory_job_base <job_dir> <worktree>
# The commit this job's branch was cut from, recorded when the worktree was
# created. Guessing "main, else master, else the previous commit" measures the
# wrong diff on a repo whose working branch is neither: the budget and the
# protected-path check then see one commit, or another branch's history.
_afk_factory_job_base() {
  local job_dir="$1" wt="$2" sha=""
  if [[ -f "$job_dir/job.json" ]]; then
    sha="$(jq -r '.base_sha // empty' "$job_dir/job.json" 2>/dev/null || true)"
  fi
  if [[ -n "$sha" ]] && git -C "$wt" cat-file -e "${sha}^{commit}" 2>/dev/null; then
    printf '%s' "$sha"
    return 0
  fi
  _afk_factory_task_base_ref "$wt"
}
_afk_factory_job_base_branch() { # <job_dir> <worktree>
  local job_dir="$1" wt="$2" br=""
  if [[ -f "$job_dir/job.json" ]]; then
    br="$(jq -r '.base_branch // empty' "$job_dir/job.json" 2>/dev/null || true)"
  fi
  if [[ -z "$br" ]]; then
    br="$(_afk_factory_task_base_ref "$wt")"
    [[ "$br" == "HEAD~1" ]] && br="main"
  fi
  printf '%s' "${br#origin/}"
}

# afk_factory_run_gate <base_repo> <worktree_dir> <round_dir>
# Runs the deterministic check gate from <base_repo>/.afk/checks.sh inside
# <worktree_dir> and checks for unauthorized edits to protected_paths in the
# stage gate ONLY when configured as hard-blocked, while recording touched
# protected paths for the Situational Merge Approver.
afk_factory_run_gate() {
  local base_repo="$1" wt="$2" round_dir="$3"
  mkdir -p "$round_dir"
  local checks_out="$round_dir/checks.md"
  local checks_script="$base_repo/.afk/checks.sh"
  local rc=0 out=""

  # Verify the branch did not tamper with .afk/checks.sh or .afk/config.json itself.
  # --no-renames: with rename detection a moved file is listed under its new
  # name only, and `git mv .afk/checks.sh elsewhere` would go unseen.
  local base_ref job_dir
  job_dir="$(dirname -- "$round_dir")"
  base_ref="$(_afk_factory_job_base "$job_dir" "$wt")"
  local changed_files
  changed_files="$(git -C "$wt" diff --no-renames --name-only "$base_ref"...HEAD 2>/dev/null || git -C "$wt" diff --no-renames --name-only HEAD 2>/dev/null || true)"

  if printf '%s\n' "$changed_files" | grep -qE '^\.afk/(checks\.sh|config\.json)$'; then
    cat > "$checks_out" <<EOF
VERDICT: FAIL
## Summary
- Builder modified protected factory gate file (\`.afk/checks.sh\` or \`.afk/config.json\`).
- Branches may not alter the checks they are judged by.
EOF
    return 1
  fi

  # Run the checks as committed on the base, when they are committed. The base
  # checkout's working copy can be written by an agent through its absolute
  # path, and that edit never shows in the branch diff checked above.
  # The copy sits in the worktree's own .afk directory, so a script that
  # finds the repository from its own location finds the worktree.
  local run_script="$checks_script" tmp_script="" extract_failed=false
  if git -C "$base_repo" cat-file -e "${base_ref}:.afk/checks.sh" 2>/dev/null; then
    mkdir -p "$wt/.afk" 2>/dev/null || true
    tmp_script="$(mktemp "$wt/.afk/.base-checks.XXXXXX" 2>/dev/null || true)"
    if [[ -n "$tmp_script" ]] && git -C "$base_repo" show "${base_ref}:.afk/checks.sh" > "$tmp_script" 2>/dev/null && [[ -s "$tmp_script" ]]; then
      run_script="$tmp_script"
    else
      # The committed script could not be read out. Falling back to the
      # working copy would run a script nobody reviewed.
      extract_failed=true
    fi
  fi
  # The commit the checks are about to judge. The approver refuses evidence
  # for any other commit, and a check that commits its own changes fails.
  local gated_head gated_ref
  gated_head="$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)"
  gated_ref="$(git -C "$wt" symbolic-ref --quiet HEAD 2>/dev/null || true)"
  AFK_LAST_GATED_HEAD=""
  AFK_LAST_GATED_ROUND_DIR=""

  # A check that waits on input or never returns must not hold the job open.
  local gate_tmo cfg_gate
  cfg_gate="$(afk_factory_load_config "$base_repo")"
  gate_tmo="${AFK_GATE_TIMEOUT_SEC:-$(jq -r '.gate_timeout_sec // 3600' <<<"$cfg_gate" 2>/dev/null || printf '3600')}"
  [[ "$gate_tmo" =~ ^[0-9]+$ && "$gate_tmo" -gt 0 ]] || gate_tmo=3600
  local -a gate_cmd=(bash "$run_script")
  if command -v timeout >/dev/null 2>&1; then
    gate_cmd=(timeout -k 30 "$gate_tmo" bash "$run_script")
  elif command -v gtimeout >/dev/null 2>&1; then
    gate_cmd=(gtimeout -k 30 "$gate_tmo" bash "$run_script")
  fi

  # An uncommitted script runs from the base checkout's working copy, which an
  # agent can reach by its absolute path. It must be the script the job
  # started with.
  local want_digest=""
  if [[ "$run_script" == "$checks_script" && -f "$checks_script" ]]; then
    want_digest="$(jq -r '.checks_script_sha256 // empty' "$job_dir/job.json" 2>/dev/null || true)"
  fi
  if [[ "$extract_failed" == true ]]; then
    out="The committed .afk/checks.sh could not be read from ${base_ref}, so no checks ran."
    rc=1
  elif [[ -n "$want_digest" && "$(_afk_factory_file_digest "$checks_script")" != "$want_digest" ]]; then
    out="The base checkout's .afk/checks.sh changed after this job started, so it was not run. If the change was made by a person, reply on the issue with instructions for another round and that round uses the script as it is then. Committing .afk/checks.sh avoids this for new jobs."
    rc=1
  elif [[ -f "$run_script" ]]; then
    out="$(cd "$wt" && "${gate_cmd[@]}" 2>&1 </dev/null)" || rc=$?
    if (( rc == 124 || rc == 137 )); then
      out="${out}"$'\n'"Deterministic check gate did not finish within ${gate_tmo}s and was stopped."
    fi
  else
    out="No .afk/checks.sh found; default gate pass."
    rc=0
  fi
  [[ -n "$tmp_script" ]] && rm -f -- "$tmp_script"
  if [[ -n "$gated_head" ]]; then
    if [[ "$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)" != "$gated_head" ]] \
       || [[ "$(git -C "$wt" symbolic-ref --quiet HEAD 2>/dev/null || true)" != "$gated_ref" ]] \
       || [[ -n "$(git -C "$wt" status --porcelain --untracked-files=no -- . ':!.afk' 2>/dev/null || true)" ]]; then
      out="${out}"$'\n'"The checks changed the branch while they ran, so their result does not describe the commit they started on. The branch was put back to that commit."
      rc=1
      # What the checks committed or changed is not the builder's work and is
      # not reviewed; leaving it would carry it into the next round's merge.
      if [[ -n "$gated_ref" ]]; then
        git -C "$wt" checkout -q -f -B "${gated_ref#refs/heads/}" "$gated_head" >/dev/null 2>&1 || true
      else
        git -C "$wt" reset -q --hard "$gated_head" >/dev/null 2>&1 || true
      fi
    fi
  fi
  printf '%s\n' "$gated_head" > "$round_dir/checks.sha" 2>/dev/null || true
  # Kept in the runner too: agents can write to the job directory, so the
  # file alone is not trusted by the approver run that follows.
  AFK_LAST_GATED_HEAD="$gated_head"
  AFK_LAST_GATED_ROUND_DIR="$round_dir"

  if (( rc == 0 )); then
    cat > "$checks_out" <<EOF
VERDICT: PASS
## Summary
- Deterministic check gate exited 0.

## Output
\`\`\`
$(printf '%s\n' "$out" | tail -n 60)
\`\`\`
EOF
    return 0
  else
    cat > "$checks_out" <<EOF
VERDICT: FAIL
## Summary
- Deterministic check gate failed with exit code $rc.

## Output
\`\`\`
$(printf '%s\n' "$out" | tail -n 120)
\`\`\`
EOF
    return 1
  fi
}

# afk_factory_evaluate_merge <repo_path> <job_dir> [<worktree_dir>]
# Situational Merge Approver:
# Inspects deterministic gate results, all reviewer verdicts in the current
# round, diff line/file count, risk classification, and protected paths.
# Writes <job_dir>/decision.md and prints structured JSON with:
#   decision: "APPROVE" | "ESCALATE"
#   reasons: [...]
afk_factory_evaluate_merge() {
  local repo="$1" job_dir="$2" wt="${3:-}"
  local job_file="$job_dir/job.json"
  if [[ ! -f "$job_file" ]]; then
    afk_warn "factory evaluate-merge: missing job.json in $job_dir"
    return 1
  fi
  local job cfg round risk merge_policy max_lines max_files
  job="$(cat "$job_file")"
  cfg="$(afk_factory_load_config "$repo")"
  round="$(jq -r '.round // 1' <<<"$job")"
  risk="$(jq -r '.risk // "low"' <<<"$job")"
  merge_policy="$(jq -r '.merge_policy // "situational"' <<<"$cfg")"
  max_lines="$(jq -r '.diff_budget.max_lines // 800' <<<"$cfg")"
  max_files="$(jq -r '.diff_budget.max_files // 25' <<<"$cfg")"
  [[ -n "$wt" ]] || wt="$(jq -r '.worktree_path // empty' <<<"$job")"
  [[ -n "$wt" && -d "$wt" ]] || wt="$repo"

  local round_dir="$job_dir/round-$round"
  local reasons="[]"

  # 1. Check deterministic gate verdict
  local gate_verdict="MISSING"
  if [[ -f "$round_dir/checks.md" ]]; then
    if head -n 5 "$round_dir/checks.md" | grep -q '^VERDICT: PASS'; then
      gate_verdict="PASS"
    else
      gate_verdict="FAIL"
    fi
  fi
  if [[ "$gate_verdict" != "PASS" ]]; then
    reasons="$(jq -c --arg r "Deterministic check gate is $gate_verdict" '. + [$r]' <<<"$reasons")"
  fi

  # 2. Check all reviewer verdicts in round_dir
  # The round names the reviews it required. A review that timed out leaves no
  # file, and counting only the files present would let the change merge on
  # the reviews that happened to finish.
  local review_count=0 review_failures=0 rf rv lens
  local -a lenses=()
  if [[ -s "$round_dir/expected-reviews" ]]; then
    mapfile -t lenses < <(sed '/^[[:space:]]*$/d' "$round_dir/expected-reviews" 2>/dev/null)
  else
    for rf in "$round_dir"/review-*.md; do
      [[ -f "$rf" ]] || continue
      lenses+=("$(basename "$rf" .md)")
    done
  fi
  for lens in "${lenses[@]:-}"; do
    [[ -n "$lens" ]] || continue
    rf="$round_dir/$lens.md"
    review_count=$((review_count + 1))
    rv=""
    [[ -s "$rf" ]] && rv="$(_afk_factory_strict_verdict "$rf")"
    if [[ "$rv" != "PASS" ]]; then
      review_failures=$((review_failures + 1))
      reasons="$(jq -c --arg r "Reviewer $lens returned ${rv:-MISSING}" '. + [$r]' <<<"$reasons")"
    fi
  done
  if (( review_count == 0 )); then
    reasons="$(jq -c '. + ["No independent review evidence found in current round"]' <<<"$reasons")"
  fi

  # The checks and the reviews must be evidence about the commit being merged.
  # An agent that commits after the gate ran would otherwise ship ungated code.
  if [[ -d "$wt/.git" || -f "$wt/.git" ]] && [[ -z "$(head -n 1 "$round_dir/checks.sha" 2>/dev/null | tr -d '[:space:]')" ]]; then
    reasons="$(jq -c '. + ["No record of which commit the checks ran on"]' <<<"$reasons")"
  fi
  if [[ -s "$round_dir/checks.sha" && ( -d "$wt/.git" || -f "$wt/.git" ) ]]; then
    local gated_sha head_sha
    gated_sha="$(head -n 1 "$round_dir/checks.sha" 2>/dev/null | tr -d '[:space:]')"
    head_sha="$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)"
    if [[ -n "$gated_sha" && -n "$head_sha" && "$gated_sha" != "$head_sha" ]]; then
      reasons="$(jq -c --arg r "Branch moved after the checks ran (checked ${gated_sha:0:8}, now ${head_sha:0:8})" '. + [$r]' <<<"$reasons")"
    fi
  fi

  # 3. Inspect changed files, diff size, and protected paths
  local changed_files="" file_count=0 line_count=0 is_git=false dirty=""
  if [[ -d "$wt/.git" || -f "$wt/.git" ]]; then
    is_git=true
    local base_ref
    base_ref="$(_afk_factory_job_base "$job_dir" "$wt")"
    # --no-renames lists both sides of a move, so a protected file renamed
    # out of its path still shows under the protected name.
    changed_files="$(git -C "$wt" diff --no-renames --name-only "$base_ref"...HEAD 2>/dev/null || git -C "$wt" diff --no-renames --name-only HEAD~1 2>/dev/null || true)"
    if [[ -n "$changed_files" ]]; then
      file_count="$(printf '%s\n' "$changed_files" | sed '/^$/d' | wc -l | tr -d ' ')"
      # numstat prints "-" for a binary file; count it as one changed line so
      # a binary-only change is not measured as empty.
      line_count="$(git -C "$wt" diff --no-renames --numstat "$base_ref"...HEAD 2>/dev/null | awk '{a = ($1 == "-") ? 1 : $1; d = ($2 == "-") ? 0 : $2; s += a + d} END {print s+0}')"
    fi
    # Tracked changes only: a check script that leaves a report file behind is
    # not uncommitted work. A build that could not commit is caught after the
    # build.
    dirty="$(git -C "$wt" status --porcelain --untracked-files=no -- . ':!.afk' 2>/dev/null | head -n 5 || true)"
  fi
  # Tests can state diff figures in job.json instead of building a large diff.
  # Outside a test run the measured diff is the only source: job.json sits in
  # a directory every agent can write, and a trusted figure there would let a
  # builder declare its own change small.
  if [[ "${AFK_FACTORY_TEST_DIFF_STATS:-0}" == "1" ]]; then
    local job_lines job_files job_paths
    job_lines="$(jq -r '.diff_stats.lines // empty' <<<"$job" 2>/dev/null)"
    job_files="$(jq -r '.diff_stats.files // empty' <<<"$job" 2>/dev/null)"
    job_paths="$(jq -r '.diff_stats.changed_paths // [] | .[]' <<<"$job" 2>/dev/null)"
    [[ "$job_lines" =~ ^[0-9]+$ ]] && line_count="$job_lines"
    [[ "$job_files" =~ ^[0-9]+$ ]] && file_count="$job_files"
    [[ -n "$job_paths" ]] && changed_files="$job_paths"
  fi
  [[ "$line_count" =~ ^[0-9]+$ ]] || line_count=0
  [[ "$file_count" =~ ^[0-9]+$ ]] || file_count=0

  # Nothing to merge is not a pass. A build that could not commit, or wrote
  # its work somewhere else, leaves the branch where it started.
  if [[ "$is_git" == true && "$file_count" -eq 0 ]]; then
    reasons="$(jq -c '. + ["Branch has no committed changes to merge"]' <<<"$reasons")"
  fi
  if [[ -n "$dirty" ]]; then
    reasons="$(jq -c '. + ["Worktree has uncommitted changes the checks and reviews did not cover"]' <<<"$reasons")"
  fi

  if (( line_count > max_lines )); then
    reasons="$(jq -c --arg r "Diff size ($line_count lines) exceeds budget ($max_lines lines)" '. + [$r]' <<<"$reasons")"
  fi
  if (( file_count > max_files )); then
    reasons="$(jq -c --arg r "Changed file count ($file_count) exceeds budget ($max_files files)" '. + [$r]' <<<"$reasons")"
  fi

  # Protected paths check
  local -a prot_patterns=()
  mapfile -t prot_patterns < <(jq -r '.protected_paths[]? // empty' <<<"$cfg" 2>/dev/null)
  # One path per line: a path with a space is one path, not three words, and
  # the comparison ignores case so `Migrations/` is still `migrations/`.
  local pat f f_lc pat_lc
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    f_lc="$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')"
    for pat in "${prot_patterns[@]:-}"; do
      [[ -n "$pat" ]] || continue
      pat_lc="$(printf '%s' "$pat" | tr '[:upper:]' '[:lower:]')"
      if [[ "$f_lc" == *"$pat_lc"* ]]; then
        reasons="$(jq -c --arg r "Protected path touched: $f (matches '$pat')" '. + [$r]' <<<"$reasons")"
        break
      fi
    done
  done <<<"$changed_files"

  # 4. Check explicit policy / high-risk architectural escalation
  if [[ "$merge_policy" == "human" ]]; then
    reasons="$(jq -c '. + ["Project merge_policy is pinned to human approval"]' <<<"$reasons")"
  fi
  # The per-project merge authority in the Paperclip config is the standing
  # control over who may merge. A project listed there without `merge: pm`
  # is never merged unattended.
  local proj_merge
  proj_merge="$(_afk_factory_project_merge_policy "$(jq -r '.slug // empty' <<<"$job" 2>/dev/null)" "$repo")"
  if [[ -n "$proj_merge" && "$proj_merge" != "pm" ]]; then
    reasons="$(jq -c --arg r "Project merge authority is '$proj_merge': a person merges this project" '. + [$r]' <<<"$reasons")"
  fi
  if [[ "$risk" == "critical" ]]; then
    reasons="$(jq -c '. + ["Job risk is rated critical"]' <<<"$reasons")"
  fi

  local reason_len decision="APPROVE"
  reason_len="$(jq -r 'length' <<<"$reasons")"
  if (( reason_len > 0 )); then
    decision="ESCALATE"
  fi

  local decision_file="$job_dir/decision.md"
  if [[ "$decision" == "APPROVE" ]]; then
    cat > "$decision_file" <<EOF
DECISION: APPROVE
## Summary
- Deterministic gate: PASS
- Independent reviews: $review_count passed, 0 changes requested
- Diff size: $line_count lines across $file_count files (within budget)
- Protected paths: none touched
- Action: Situational Approver authorized autonomous merge.
EOF
  else
    cat > "$decision_file" <<EOF
DECISION: ESCALATE
## Summary
- Deterministic gate: $gate_verdict
- Independent reviews: $review_count total ($review_failures requesting changes)
- Diff size: $line_count lines across $file_count files
- Action: Escalating to human in Paperclip for review/approval.

## Escalation Triggers
$(jq -r '.[] | "- " + .' <<<"$reasons")
EOF
  fi

  jq -cn \
    --arg dec "$decision" \
    --arg gate "$gate_verdict" \
    --argjson revs "$review_count" \
    --argjson fails "$review_failures" \
    --argjson lines "$line_count" \
    --argjson files "$file_count" \
    --argjson reasons "$reasons" \
    '{
      decision: $dec,
      gate_verdict: $gate,
      reviews_count: $revs,
      reviews_failed: $fails,
      diff_lines: $lines,
      diff_files: $files,
      reasons: $reasons
    }'
}

# afk_factory_build_stage_prompt <repo_path> <job_dir> <role> <stage> <input_file> <output_file>
# Constructs a bounded prompt combining the project agent's discovered persona/skill,
# any replacement handoff checkpoint, and the stage contract.
afk_factory_build_stage_prompt() {
  local repo="$1" job_dir="$2" role="$3" stage="$4" input_file="$5" output_file="$6"
  local roster skill_path persona_name
  roster="$(afk_roster_discover "$repo" 2>/dev/null || true)"
  skill_path="$(jq -r --arg r "$role" '.agents[]? | select(.role == $r) | .skill_path // empty' <<<"$roster" 2>/dev/null)"
  persona_name="$(jq -r --arg r "$role" '.agents[]? | select(.role == $r) | .persona_name // $r' <<<"$roster" 2>/dev/null)"

  local prompt_dest="$job_dir/.prompt-${stage}-${role}.md"
  {
    printf '# AFK Software Factory Stage: %s (Role: %s / %s)\n\n' "$stage" "$role" "$persona_name"
    if [[ -n "$skill_path" && -f "$skill_path" ]]; then
      printf '## Project Agent Persona & Skill (%s)\n' "$skill_path"
      head -n 120 "$skill_path" 2>/dev/null || true
      local cust_toml
      cust_toml="$(dirname -- "$skill_path")/customize.toml"
      if [[ -f "$cust_toml" ]]; then
        printf '\n### Persona Principles (%s)\n' "$cust_toml"
        sed '/^\[\[agent\.menu\]\]/,$d' "$cust_toml" 2>/dev/null | head -n 60 || true
      fi
      printf '\n---\n\n'
    fi
    # Include latest replacement checkpoint if this role was previously replaced due to context limits
    local latest_ckpt=""
    if [[ -d "$job_dir/checkpoints" ]]; then
      latest_ckpt="$(ls -1 "$job_dir/checkpoints/${role}-gen-"*.md 2>/dev/null | sort -V | tail -n 1 || true)"
    fi
    if [[ -n "$latest_ckpt" && -f "$latest_ckpt" ]]; then
      printf '## Context Replacement Handoff Checkpoint (%s)\n' "$(basename "$latest_ckpt")"
      cat "$latest_ckpt"
      printf '\n---\n\n'
    fi
    printf '## Headless Factory Execution Mode (CRITICAL OVERRIDE)\n'
    printf -- '- You are executing unattended in an autonomous AFK Software Factory stage (`%s`).\n' "$stage"
    printf -- '- SKIP all interactive activation greetings, icon prefixes, and menu tables (`On Activation` Steps 1-8). Do NOT pause or wait for user menu selection.\n'
    printf -- '- Write your final structured stage artifact directly to `%s` (or output ONLY the exact artifact markdown as your final response with no conversational preamble).\n\n' "$output_file"
    if declare -F afk_tooling_discover >/dev/null 2>&1; then
      local t_inv t_mcp t_skills scan_target="$repo" job_wt="" job_slug=""
      if [[ -f "$job_dir/job.json" ]]; then
        job_wt="$(jq -r '.worktree_path // empty' "$job_dir/job.json" 2>/dev/null || true)"
        job_slug="$(jq -r '.slug // empty' "$job_dir/job.json" 2>/dev/null || true)"
        [[ -n "$job_wt" && -d "$job_wt" ]] && scan_target="$job_wt"
      fi
      t_inv="$(AFK_TOOLING_HERMETIC=1 afk_tooling_discover "$scan_target" "$job_slug" 2>/dev/null || printf '{}')"
      t_mcp="$(jq -r '[.project.mcp_servers[]?.name] | join(", ")' <<<"$t_inv" 2>/dev/null || true)"
      t_skills="$(jq -r '[.project.skills[]? | select(.is_bmad | not) | .name] | join(", ")' <<<"$t_inv" 2>/dev/null || true)"
      if [[ -n "$t_mcp" || -n "$t_skills" ]]; then
        printf '## Project MCP Servers & Custom Skills (`%s`)\n' "$(jq -r '.config_source // "standalone-local"' <<<"$t_inv")"
        [[ -n "$t_mcp" ]] && printf -- '- Active MCP Servers (`%s` mode): %s\n' "$(jq -r '.mcp_mode // "standalone"' <<<"$t_inv")" "$t_mcp"
        [[ -n "$t_skills" ]] && printf -- '- Active Custom/Fleet Skills (`.agents/skills/`): %s\n' "$t_skills"
        printf '\n---\n\n'
      fi
    fi
    if [[ -f "$input_file" ]]; then
      printf '## Input Context (`%s`)\n' "$input_file"
      head -n 200 "$input_file" 2>/dev/null || true
      printf '\n---\n\n'
    fi
    if [[ -f "$job_dir/watchdog-nudge.md" ]]; then
      printf '## Watchdog Stall Recovery Nudge (IMPORTANT)\n'
      cat -- "$job_dir/watchdog-nudge.md" 2>/dev/null || true
      printf '\n---\n\n'
    fi
    if [[ -f "$job_dir/human-feedback.md" ]]; then
      printf '## Human Board Feedback (MUST ADDRESS)\n'
      cat -- "$job_dir/human-feedback.md" 2>/dev/null || true
      printf '\n---\n\n'
    fi
    if [[ "$stage" == "build" && -f "$job_dir/job.json" ]]; then
      local cur_round prev_round
      cur_round="$(jq -r '.round // 1' "$job_dir/job.json" 2>/dev/null || printf '1')"
      if [[ "$cur_round" =~ ^[0-9]+$ ]] && (( cur_round > 1 )); then
        prev_round=$((cur_round - 1))
        if [[ -f "$job_dir/round-$prev_round/checks.md" ]] && ! head -n 5 "$job_dir/round-$prev_round/checks.md" | grep -q '^VERDICT: PASS'; then
          printf '## Prior Round %s Deterministic Gate Failure (MUST FIX)\n' "$prev_round"
          head -n 100 "$job_dir/round-$prev_round/checks.md" 2>/dev/null || true
          printf '\n---\n\n'
        fi
        local pr_rf pr_rv
        for pr_rf in "$job_dir/round-$prev_round"/review-*.md; do
          [[ -f "$pr_rf" ]] || continue
          pr_rv="$(head -n 8 "$pr_rf" | sed -n 's/^[[:space:]*]*VERDICT:[*[:space:]]*//p' | head -n 1 | awk '{print $1}')"
          if [[ "$pr_rv" != "PASS" ]]; then
            printf '## Prior Round %s Reviewer Feedback — `%s` (MUST ADDRESS ALL BLOCKING FINDINGS)\n' "$prev_round" "$(basename "$pr_rf")"
            head -n 120 "$pr_rf" 2>/dev/null || true
            printf '\n---\n\n'
          fi
        done
      fi
    fi
    printf '## Stage Instructions\n'
    printf -- '- Input context path: `%s`\n' "$input_file"
    printf -- '- Target output path: `%s` (if `%s` is outside your writable workspace root, output the exact required markdown directly as your final response without outer code fences).\n' "$output_file" "$output_file"
    case "$stage" in
      intake)
        printf -- '- Do NOT modify repository source files during `intake`.\n'
        printf -- '- Begin `%s` with these exact three plain-text header lines (no bolding, no icons):\n' "$output_file"
        printf '  `VERDICT: ACCEPT` (or `NEEDS-INFO` / `REJECT`)\n'
        printf '  `RISK: low` (or `medium` / `high` / `critical` — use `critical` for multi-subsystem frontier overhauls or severe security/data-integrity impact)\n'
        printf '  `SURFACES: code` (comma-separated subset of `code,ui,ux,architecture,security` — always include `security` when auth, tokens, crypto, secrets, IAM/RBAC, or vulnerabilities/CVEs are involved)\n'
        printf -- '- Follow with `## Summary` summarizing scope and constraints.\n'
        ;;
      spec)
        printf -- '- Do NOT modify repository source files during `spec`.\n'
        printf -- '- Inspect the relevant files in the current working directory and write a concise, actionable engineering specification with clear Acceptance Criteria and target files to `%s`.\n' "$output_file"
        ;;
      build)
        printf -- '- Implement the specification (and fix any Prior Round Gate/Reviewer Blocking Findings shown above) in the current git worktree working directory.\n'
        printf -- '- Run relevant tests to verify your changes pass cleanly.\n'
        printf -- '- Stage and commit your code changes on the current git branch (`git add` + `git commit`; never stage `.afk/`).\n'
        printf -- '- Write a concise summary of changes and test verification to `%s`.\n' "$output_file"
        ;;
      review*)
        printf -- '- Do NOT modify repository source files during `%s`.\n' "$stage"
        # Name the commit this job branched from. "origin/main" does not exist
        # in a repo whose branch is master or that has no remote, and the
        # reviewer then picks its own, different, diff to review.
        local rv_base
        rv_base="$(jq -r '.base_sha // empty' "$job_dir/job.json" 2>/dev/null || true)"
        [[ -n "$rv_base" ]] || rv_base="origin/main"
        printf -- '- Inspect the full branch diff against the commit this work branched from (`git log %s..HEAD --stat` and `git diff %s...HEAD`), and compare against `%s/spec.md` and the current round `checks.md`.\n' "$rv_base" "$rv_base" "$job_dir"
        printf -- '- Begin `%s` with this exact plain-text first line (no bolding, no icons): `VERDICT: PASS` or `VERDICT: CHANGES_REQUESTED`.\n' "$output_file"
        printf -- '- Follow with `## Summary` and any concrete findings.\n'
        ;;
    esac
  } > "$prompt_dest"
  printf '%s' "$prompt_dest"
}

# afk_factory_resolve_stage_route <repo> <job_dir> <stage> <role>
# Resolves the harness, model, effort, context window, and Hindsight memory_mode
# for a stage using public benchmark scores, pool capacity/headroom, and LiteLLM.
afk_factory_resolve_stage_route() {
  local repo="$1" job_dir="$2" stage="$3" role="$4"
  local cfg risk="low" round_num=1 surfaces_csv="code" wt_path="" diff_lines=0 stage_key="$stage"
  cfg="$(afk_factory_load_config "$repo")"
  if [[ -f "$job_dir/job.json" ]]; then
    risk="$(jq -r '.risk // "low"' "$job_dir/job.json" 2>/dev/null || printf 'low')"
    round_num="$(jq -r '.round // 1' "$job_dir/job.json" 2>/dev/null || printf '1')"
    surfaces_csv="$(jq -r '(.surfaces // ["code"]) | join(",")' "$job_dir/job.json" 2>/dev/null || printf 'code')"
    wt_path="$(jq -r '.worktree_path // empty' "$job_dir/job.json" 2>/dev/null || true)"
  fi
  if [[ "$stage" == review* && -n "$wt_path" && -d "$wt_path" ]]; then
    diff_lines="$(git -C "$wt_path" diff --numstat HEAD~1..HEAD 2>/dev/null | awk '{s += ($1+0) + ($2+0)} END {print s+0}' 2>/dev/null || printf '0')"
  fi

  local builder_family=""
  if [[ "$stage" == review* && -f "$job_dir/route-build-dev.json" ]]; then
    builder_family="$(jq -r '.model_family // empty' "$job_dir/route-build-dev.json" 2>/dev/null || true)"
  fi

  if declare -F afk_router_select_candidate >/dev/null 2>&1; then
    local smart_json
    smart_json="$(afk_router_select_candidate "$repo" "$stage" "$risk" "$builder_family" "$role" "$round_num" "$surfaces_csv" "$diff_lines")"
    if [[ -n "$smart_json" ]]; then
      smart_json="$(jq -c --arg rl "$role" '. + {role: $rl}' <<<"$smart_json")"
      printf '%s\n' "$smart_json" > "$job_dir/route-${stage}-${role}.json"
      printf '%s\n' "$smart_json"
      return 0
    fi
  fi

  if [[ "$stage" == review* ]]; then
    case "$risk" in
      high|critical) stage_key="review_high" ;;
      medium)        stage_key="review_medium" ;;
      *)             stage_key="review_low" ;;
    esac
  fi

  local default_mem="advisory"
  if [[ "$stage" == review* || "$stage" == "approve" ]]; then
    default_mem="$(jq -r '.router.hindsight.review_stages // "blind"' <<<"$cfg" 2>/dev/null)"
  else
    default_mem="$(jq -r '.router.hindsight.build_stages // "advisory"' <<<"$cfg" 2>/dev/null)"
  fi

  local model effort window mem_mode litellm_url source="tier-map"
  model="$(jq -r --arg k "$stage_key" '.routing[$k].model // "sonnet"' <<<"$cfg" 2>/dev/null)"
  effort="$(jq -r --arg k "$stage_key" '.routing[$k].effort // "medium"' <<<"$cfg" 2>/dev/null)"
  window="$(jq -r --arg k "$stage_key" '.routing[$k].window // 200000' <<<"$cfg" 2>/dev/null)"
  mem_mode="$(jq -r --arg k "$stage_key" --arg dm "$default_mem" '.routing[$k].memory_mode // $dm' <<<"$cfg" 2>/dev/null)"
  litellm_url="${AFK_LITELLM_BASE_URL:-$(jq -r '.router.litellm_base_url // empty' <<<"$cfg" 2>/dev/null)}"

  local route_json
  route_json="$(jq -cn \
    --arg st "$stage" \
    --arg rl "$role" \
    --arg m "$model" \
    --arg ef "$effort" \
    --arg mm "$mem_mode" \
    --arg src "$source" \
    --arg lurl "$litellm_url" \
    --argjson win "$window" \
    '{stage:$st, role:$rl, harness:"claude", launch_class:"claude-native", model:$m, model_family:"anthropic", effort:$ef, window_tokens:$win, memory_mode:$mm, router_source:$src, litellm_base_url:(if $lurl=="" then null else $lurl end)}')"
  printf '%s\n' "$route_json" > "$job_dir/route-${stage}-${role}.json"
  printf '%s\n' "$route_json"
}

# afk_factory_invoke_stage_agent <repo_path> <worktree_path> <job_dir> <role> <stage> <prompt_file> <output_file> [<harness>]
# Executes one bounded agent turn for <stage>.
# Supports:
#   1. AFK_FACTORY_AGENT_RUNNER override for custom runners / deterministic tests.
#   2. AFK_FACTORY_LIVE_HARNESS=1 for headless claude / codex / agy / opencode CLI execution,
#      extracting token usage into AFK_LAST_STAGE_USED_TOKENS.
#   3. Deterministic local synthesis fallback when running offline without a runner.
# shellcheck disable=SC2030,SC2031
afk_factory_invoke_stage_agent() {
  local repo="$1" wt="$2" job_dir="$3" role="$4" stage="$5" prompt_file="$6" output_file="$7" harness_override="${8:-}"
  local compiled_prompt route_json routed_harness routed_launch routed_model routed_effort routed_window routed_mem litellm_url
  compiled_prompt="$(afk_factory_build_stage_prompt "$repo" "$job_dir" "$role" "$stage" "$prompt_file" "$output_file")"
  route_json="$(afk_factory_resolve_stage_route "$repo" "$job_dir" "$stage" "$role")"
  routed_harness="$(jq -r '.harness // "claude"' <<<"$route_json")"
  routed_launch="$(jq -r '.launch_class // "claude-native"' <<<"$route_json")"
  routed_model="$(jq -r '.model // "sonnet"' <<<"$route_json")"
  routed_effort="$(jq -r '.effort // "medium"' <<<"$route_json")"
  routed_window="$(jq -r '.window_tokens // 200000' <<<"$route_json")"
  routed_mem="$(jq -r '.memory_mode // "advisory"' <<<"$route_json")"
  litellm_url="$(jq -r '.litellm_base_url // empty' <<<"$route_json")"
  local harness="${harness_override:-$routed_harness}"

  AFK_LAST_STAGE_USED_TOKENS="${AFK_STAGE_USED_TOKENS:-}"
  AFK_LAST_STAGE_WINDOW_TOKENS="${AFK_STAGE_WINDOW_TOKENS:-$routed_window}"
  AFK_LAST_STAGE_COMPACTED="${AFK_STAGE_COMPACTED:-false}"
  AFK_LAST_STAGE_INPUT_TOKENS=0
  AFK_LAST_STAGE_CACHED_TOKENS=0
  AFK_LAST_STAGE_OUTPUT_TOKENS=0
  AFK_LAST_STAGE_HARNESS="$harness"
  AFK_LAST_STAGE_MODEL="$routed_model"
  AFK_LAST_STAGE_EFFORT="$routed_effort"
  AFK_LAST_STAGE_PROVIDER="$(jq -r '.model_family // .provider // "anthropic"' <<<"$route_json" 2>/dev/null || printf 'anthropic')"
  AFK_LAST_STAGE_COST_CLASS="$(jq -r '.cost_class // "subscription"' <<<"$route_json" 2>/dev/null || printf 'subscription')"
  AFK_LAST_STAGE_COST_CENTS=0

  # Every agent run is bounded. Without timeout or gtimeout an agent could run
  # on after its runner is presumed gone, while another runner starts in the
  # same worktree; so no live stage starts on such a host.
  if [[ -n "${AFK_FACTORY_AGENT_RUNNER:-}" || "${AFK_FACTORY_LIVE_HARNESS:-0}" == "1" || "${AFK_FACTORY_OFFLINE_SYNTH:-0}" != "1" ]] \
     && ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
    AFK_LAST_STAGE_FAILURE="no_timeout_binary"
    return 1
  fi
  local runner="${AFK_FACTORY_AGENT_RUNNER:-}"
  if [[ -n "$runner" && -x "$runner" ]]; then
    local runner_out="" runner_rc=0 r_tmo
    # An output left by an earlier, interrupted attempt must not pass for
    # this one's.
    rm -f -- "$output_file"
    # A custom runner is bounded like any stage: a hung one with a fresh
    # heartbeat would otherwise never be recovered.
    r_tmo="${AFK_STAGE_TIMEOUT_SEC:-$(jq -r '.watchdog.stage_timeout_sec // 900' <<<"$(afk_factory_load_config "$repo")" 2>/dev/null || printf '900')}"
    [[ "$r_tmo" =~ ^[0-9]+$ && "$r_tmo" -gt 0 ]] || r_tmo=900
    local -a r_cmd=()
    if command -v timeout >/dev/null 2>&1; then r_cmd=(timeout -k 20 "$r_tmo")
    else r_cmd=(gtimeout -k 20 "$r_tmo"); fi
    runner_out="$(
      AFK_FACTORY_REPO="$repo" \
      AFK_FACTORY_WORKTREE="$wt" \
      AFK_FACTORY_JOB_DIR="$job_dir" \
      AFK_FACTORY_ROLE="$role" \
      AFK_FACTORY_STAGE="$stage" \
      AFK_FACTORY_HARNESS="$harness" \
      AFK_FACTORY_LAUNCH_CLASS="$routed_launch" \
      AFK_FACTORY_MODEL="$routed_model" \
      AFK_FACTORY_EFFORT="$routed_effort" \
      AFK_FACTORY_MEMORY_MODE="$routed_mem" \
      AFK_FACTORY_PROMPT_FILE="$prompt_file" \
      AFK_FACTORY_COMPILED_PROMPT="$compiled_prompt" \
      AFK_FACTORY_OUTPUT_FILE="$output_file" \
        "${r_cmd[@]}" "$runner" "$stage" "$role" "$prompt_file" "$output_file" 2>/dev/null
    )" || runner_rc=$?
    if [[ -n "$runner_out" ]] && jq -e '.used_tokens or .input_tokens' <<<"$runner_out" >/dev/null 2>&1; then
      AFK_LAST_STAGE_USED_TOKENS="$(jq -r '.used_tokens // ((.input_tokens // 0) + (.output_tokens // 0)) // empty' <<<"$runner_out")"
      AFK_LAST_STAGE_WINDOW_TOKENS="$(jq -r --argjson rw "$routed_window" '.window_tokens // $rw' <<<"$runner_out")"
      AFK_LAST_STAGE_COMPACTED="$(jq -r '.compacted // false' <<<"$runner_out")"
      AFK_LAST_STAGE_INPUT_TOKENS="$(jq -r '.input_tokens // (((.used_tokens // 0) * 80) / 100 | floor)' <<<"$runner_out")"
      AFK_LAST_STAGE_CACHED_TOKENS="$(jq -r '.cached_input_tokens // 0' <<<"$runner_out")"
      AFK_LAST_STAGE_OUTPUT_TOKENS="$(jq -r '.output_tokens // ((.used_tokens // 0) - (((.used_tokens // 0) * 80) / 100 | floor))' <<<"$runner_out")"
      AFK_LAST_STAGE_COST_CENTS="$(jq -r '.cost_cents // 0' <<<"$runner_out")"
    elif [[ -s "$output_file" ]]; then
      AFK_LAST_STAGE_INPUT_TOKENS=$(( $(wc -c < "$compiled_prompt" 2>/dev/null || printf '400') / 4 ))
      AFK_LAST_STAGE_OUTPUT_TOKENS=$(( $(wc -c < "$output_file" 2>/dev/null || printf '200') / 4 ))
    fi
    return "$runner_rc"
  fi

  # A stage runs a real agent unless a test asks for canned output by name.
  # The canned outputs below include `VERDICT: PASS` reviews, so reaching them
  # by default let any caller that forgot a flag approve work nobody reviewed.
  if [[ "${AFK_FACTORY_LIVE_HARNESS:-0}" == "1" || "${AFK_FACTORY_OFFLINE_SYNTH:-0}" != "1" ]]; then
    local attempt=1 max_attempts=3 failover_from=""
    while (( attempt <= max_attempts )); do
      local env_file="$job_dir/.result-${stage}-${role}.json"
      local h_rc=0 hs_disabled="" routed_pool="" routed_cost=""
      routed_pool="$(jq -r '.entitlement_pool // empty' <<<"$route_json")"
      routed_cost="$(jq -r '.cost_class // "subscription"' <<<"$route_json")"
      [[ "$routed_mem" == "blind" || "$routed_mem" == "off" ]] && hs_disabled="true"
      rm -f "$env_file" "$output_file"
      local mcp_cfg=""
      if [[ -f "$wt/.mcp.json" ]]; then
        mcp_cfg="$wt/.mcp.json"
      elif [[ -f "$repo/.mcp.json" ]]; then
        mcp_cfg="$repo/.mcp.json"
      fi
      local bin_exec="" stage_cfg stage_tmo
      # With the bin-directory override set (a pinned image), the CLI comes
      # from there or not at all: falling back to PATH could start a
      # different, unpinned binary.
      if [[ -n "${AFK_HARNESS_BIN_DIR_OVERRIDE:-}" ]]; then
        bin_exec="$(_afk_harness_locate_bin "$harness" 2>/dev/null || true)"
      else
        bin_exec="$(_afk_harness_locate_bin "$harness" 2>/dev/null || command -v "$harness" 2>/dev/null || true)"
      fi
      stage_cfg="$(afk_factory_load_config "$repo")"
      if [[ "$routed_cost" == "free" ]]; then
        stage_tmo="${AFK_FREE_MODEL_TIMEOUT_SEC:-$(jq -r '.watchdog.free_stage_timeout_sec // 120' <<<"$stage_cfg" 2>/dev/null || printf '120')}"
      else
        stage_tmo="${AFK_STAGE_TIMEOUT_SEC:-$(jq -r '.watchdog.stage_timeout_sec // 900' <<<"$stage_cfg" 2>/dev/null || printf '900')}"
      fi
      [[ "$stage_tmo" =~ ^[0-9]+$ && "$stage_tmo" -gt 0 ]] || stage_tmo=900
      # -k: a CLI that ignores TERM is killed 20s later instead of running on.
      local -a tmo_cmd=()
      if command -v timeout >/dev/null 2>&1; then
        tmo_cmd=(timeout -k 20 "$stage_tmo")
      elif command -v gtimeout >/dev/null 2>&1; then
        tmo_cmd=(gtimeout -k 20 "$stage_tmo")
      fi

      case "$harness" in
        claude)
          if [[ -n "$bin_exec" ]]; then
            (
              cd "$wt" || exit 1
              [[ -n "$hs_disabled" ]] && export HINDSIGHT_DISABLED="true"
              if [[ "$routed_launch" == *-gateway && -n "$litellm_url" ]]; then
                export ANTHROPIC_BASE_URL="$litellm_url"
              fi
              local -a cl_mcp_args=() cl_eff_args=()
              [[ -n "$mcp_cfg" ]] && cl_mcp_args=(--mcp-config "$mcp_cfg")
              [[ -n "$routed_effort" ]] && cl_eff_args=(--effort "$routed_effort")
              "${tmo_cmd[@]}" "$bin_exec" -p "$(_afk_factory_prompt_text "$compiled_prompt")" --model "$routed_model" "${cl_eff_args[@]}" "${cl_mcp_args[@]}" --add-dir "$job_dir" --dangerously-skip-permissions --output-format json < /dev/null > "$env_file" 2>/dev/null
            ) || h_rc=$?
          else
            h_rc=127
          fi
          ;;
        codex)
          if [[ -n "$bin_exec" ]]; then
            (
              cd "$wt" || exit 1
              [[ -n "$hs_disabled" ]] && export HINDSIGHT_DISABLED="true"
              if [[ "$routed_launch" == *-gateway && -n "$litellm_url" ]]; then
                export OPENAI_BASE_URL="$litellm_url"
              fi
              local -a cx_eff_args=()
              [[ -n "$routed_effort" ]] && cx_eff_args=(-c "model_reasoning_effort=\"$routed_effort\"")
              "${tmo_cmd[@]}" "$bin_exec" exec --dangerously-bypass-approvals-and-sandbox --json -o "$output_file.last-message" -m "$routed_model" "${cx_eff_args[@]}" -- "$(_afk_factory_prompt_text "$compiled_prompt")" < /dev/null > "$env_file" 2>/dev/null
            ) || h_rc=$?
          else
            h_rc=127
          fi
          ;;
        agy)
          if [[ -n "$bin_exec" ]]; then
            (
              cd "$wt" || exit 1
              [[ -n "$hs_disabled" ]] && export HINDSIGHT_DISABLED="true"
              local agy_model="$routed_model" agy_tier="high"
              case "$routed_effort" in
                low|medium|high) agy_tier="$routed_effort" ;;
                *)               agy_tier="high" ;;
              esac
              if [[ -n "$agy_model" && "$agy_model" != *"-low" && "$agy_model" != *"-medium" && "$agy_model" != *"-high" ]]; then
                agy_model="${agy_model}-${agy_tier}"
              fi
              local -a agy_mod_args=()
              [[ -n "$agy_model" ]] && agy_mod_args+=(--model "$agy_model")
              [[ -n "$routed_effort" ]] && agy_mod_args+=(--effort "$routed_effort")
              "${tmo_cmd[@]}" "$bin_exec" --dangerously-skip-permissions "${agy_mod_args[@]}" --add-dir "$job_dir" --output-format json -p "$(_afk_factory_prompt_text "$compiled_prompt")" < /dev/null > "$env_file" 2>/dev/null
            ) || h_rc=$?
          else
            h_rc=127
          fi
          ;;
        grok)
          if [[ -n "$bin_exec" ]]; then
            (
              cd "$wt" || exit 1
              [[ -n "$hs_disabled" ]] && export HINDSIGHT_DISABLED="true"
              local -a gr_eff_args=()
              [[ -n "$routed_effort" ]] && gr_eff_args=(--effort "$routed_effort")
              "${tmo_cmd[@]}" "$bin_exec" --always-approve --output-format json -m "$routed_model" "${gr_eff_args[@]}" -p "$(_afk_factory_prompt_text "$compiled_prompt")" < /dev/null > "$env_file" 2>/dev/null
            ) || h_rc=$?
          else
            h_rc=127
          fi
          ;;
        opencode)
          if [[ -n "$bin_exec" ]]; then
            (
              cd "$wt" || exit 1
              [[ -n "$hs_disabled" ]] && export HINDSIGHT_DISABLED="true"
              if [[ "$routed_launch" == *-gateway && -n "$litellm_url" ]]; then
                export OPENAI_BASE_URL="$litellm_url"
              fi
              "${tmo_cmd[@]}" "$bin_exec" run --pure --auto --format json -m "$routed_model" -- "$(_afk_factory_prompt_text "$compiled_prompt")" < /dev/null > "$env_file" 2>/dev/null
            ) || h_rc=$?
          else
            h_rc=127
          fi
          ;;
        pi)
          if [[ -n "$bin_exec" ]]; then
            (
              cd "$wt" || exit 1
              [[ -n "$hs_disabled" ]] && export HINDSIGHT_DISABLED="true"
              "${tmo_cmd[@]}" "$bin_exec" -p --mode json --model "$routed_model" "$(_afk_factory_prompt_text "$compiled_prompt")" < /dev/null > "$env_file" 2>/dev/null
            ) || h_rc=$?
          else
            h_rc=127
          fi
          ;;
        *)
          # A route naming a harness this runner cannot launch is a failure,
          # not a stage that quietly produced nothing.
          h_rc=127
          ;;
      esac

      # Codex writes its closing message to a side file. Use it as the stage
      # output only when the agent did not write the artifact itself; writing
      # it over the artifact replaced a full intake with "Done, wrote intake.md".
      if [[ -f "$output_file.last-message" ]]; then
        [[ ! -s "$output_file" && -s "$output_file.last-message" ]] && cp -- "$output_file.last-message" "$output_file" 2>/dev/null
        rm -f -- "$output_file.last-message"
      fi

      local env_err_msg=""
      if (( h_rc == 124 || h_rc == 137 )); then
        env_err_msg="stage_timeout_${stage_tmo}s"
      elif [[ -s "$env_file" ]] && jq -se 'any(.[]; (.is_error == true) or (.type == "error") or (.type == "turn.failed"))' "$env_file" >/dev/null 2>&1; then
        env_err_msg="$(jq -sr '[ .[] | (.error.data.message // .error.message // (if .is_error == true then .result else empty end) // .message // empty) ] | map(select(length > 0)) | first // "json_runtime_error"' "$env_file" 2>/dev/null || printf 'json_runtime_error')"
        (( h_rc == 0 )) && h_rc=1
      fi

      if (( h_rc == 0 )) && [[ -s "$env_file" || -s "$output_file" ]]; then
        local in_tok=0 cached_tok=0 out_tok=0
        if [[ -s "$env_file" ]]; then
          local tok
          tok="$(jq -sr '[ .[] | (.usage.total_tokens // .part.tokens.total // ((.usage.input_tokens // 0) + (.usage.output_tokens // 0) + (.usage.cache_read_input_tokens // 0) + (.usage.cached_input_tokens // 0))) | select(. > 0) ] | max // empty' "$env_file" 2>/dev/null || true)"
          [[ -n "$tok" ]] && AFK_LAST_STAGE_USED_TOKENS="$tok"
          in_tok="$(jq -sr '[ .[] | (.usage.input_tokens // .part.tokens.input // 0) ] | max // 0' "$env_file" 2>/dev/null || printf '0')"
          cached_tok="$(jq -sr '[ .[] | (.usage.cache_read_input_tokens // .usage.cached_input_tokens // .usage.cache_read_tokens // .part.tokens.cache.read // 0) ] | max // 0' "$env_file" 2>/dev/null || printf '0')"
          out_tok="$(jq -sr '[ .[] | (.usage.output_tokens // .part.tokens.output // 0) ] | max // 0' "$env_file" 2>/dev/null || printf '0')"
          if [[ ! -s "$output_file" ]]; then
            local extracted=""
            extracted="$(jq -sr '[ .[] | (.result // .response // .text // .part.text // empty) ] | join("")' "$env_file" 2>/dev/null || true)"
            if [[ -n "$extracted" ]]; then
              printf '%s\n' "$extracted" > "$output_file"
            fi
          fi
        fi
        if [[ -s "$output_file" ]]; then
          if (( in_tok == 0 && out_tok == 0 )); then
            in_tok=$(( $(wc -c < "$compiled_prompt" 2>/dev/null || printf '400') / 4 ))
            out_tok=$(( $(wc -c < "$output_file" 2>/dev/null || printf '200') / 4 ))
          fi
          [[ -n "${AFK_LAST_STAGE_USED_TOKENS:-}" ]] || AFK_LAST_STAGE_USED_TOKENS=$(( in_tok + cached_tok + out_tok ))
          AFK_LAST_STAGE_INPUT_TOKENS="$in_tok"
          AFK_LAST_STAGE_CACHED_TOKENS="$cached_tok"
          AFK_LAST_STAGE_OUTPUT_TOKENS="$out_tok"
          AFK_LAST_STAGE_HARNESS="$harness"
          AFK_LAST_STAGE_MODEL="$routed_model"
          AFK_LAST_STAGE_EFFORT="$routed_effort"
          AFK_LAST_STAGE_PROVIDER="$(jq -r '.model_family // .provider // "anthropic"' <<<"$route_json" 2>/dev/null || printf 'anthropic')"
          AFK_LAST_STAGE_COST_CLASS="$routed_cost"
          if [[ "$routed_cost" == "api-metered" ]]; then
            AFK_LAST_STAGE_COST_CENTS="$(jq -cn --argjson r "$route_json" --argjson it "$in_tok" --argjson ot "$out_tok" '
              (($r.cost_per_1m_usd.input // 3.0) * $it / 10000.0) + (($r.cost_per_1m_usd.output // 15.0) * $ot / 10000.0)
              | ceil
            ' 2>/dev/null || printf '0')"
          else
            AFK_LAST_STAGE_COST_CENTS=0
          fi
          local r_tc r_bn r_bs r_es
          r_tc="$(jq -r '.task_class // "coding_standard"' <<<"$route_json" 2>/dev/null || printf 'coding_standard')"
          r_bn="$(jq -r '.benchmark_name // "Public Leaderboard"' <<<"$route_json" 2>/dev/null || printf 'Public Leaderboard')"
          r_bs="$(jq -r '.benchmark_score // 0' <<<"$route_json" 2>/dev/null || printf '0')"
          r_es="$(jq -r '.effective_score // 0' <<<"$route_json" 2>/dev/null || printf '0')"
          _afk_factory_append_route_event "$job_dir/route-history.jsonl" "$(jq -cn \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --arg st "$stage" \
            --arg rl "$role" \
            --arg tc "$r_tc" \
            --arg ef "$routed_effort" \
            --arg bn "$r_bn" \
            --argjson bs "$r_bs" \
            --argjson es "$r_es" \
            --argjson att "$attempt" \
            --arg h "$harness" \
            --arg m "$routed_model" \
            --arg p "$routed_pool" \
            --arg cc "$routed_cost" \
            --arg ff "$failover_from" \
            --arg tok "${AFK_LAST_STAGE_USED_TOKENS:-0}" \
            --argjson it "$in_tok" \
            --argjson ct "$cached_tok" \
            --argjson ot "$out_tok" \
            '{ts:$ts, stage:$st, role:$rl, task_class:$tc, status:"ok", attempt:$att, harness:$h, model:$m, effort:$ef, entitlement_pool:$p, cost_class:$cc, benchmark_name:$bn, benchmark_score:$bs, effective_score:$es, used_tokens:($tok|tonumber? // 0), input_tokens:$it, cached_input_tokens:$ct, output_tokens:$ot, failover_from:(if $ff=="" then null else $ff end)}')"
          return 0
        fi
        h_rc=1
        env_err_msg="empty_stage_output"
      fi
      # Exit 0 with nothing written at all is still a failed attempt.
      if (( h_rc == 0 )); then
        h_rc=1
        env_err_msg="${env_err_msg:-empty_stage_output}"
      fi

      local fail_reason="${env_err_msg:-runtime_exit_$h_rc}"
      AFK_LAST_STAGE_FAILURE="$fail_reason"
      _afk_factory_append_route_event "$job_dir/route-history.jsonl" "$(jq -cn \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg st "$stage" \
        --arg rl "$role" \
        --arg ef "$routed_effort" \
        --argjson att "$attempt" \
        --arg h "$harness" \
        --arg m "$routed_model" \
        --arg p "$routed_pool" \
        --arg err "${fail_reason:0:160}" \
        '{ts:$ts, stage:$st, role:$rl, status:"failed_attempt", attempt:$att, harness:$h, model:$m, effort:$ef, entitlement_pool:$p, error:$err}')"

      # Runtime failover: quarantine restricted model (403/model_not_found) OR mark degraded pool, then re-route!
      if (( attempt < max_attempts )) && [[ -z "$harness_override" && -n "$routed_pool" ]] && declare -F afk_router_mark_pool_degraded >/dev/null 2>&1; then
        failover_from="${harness}/${routed_model}(${routed_pool})"
        local lfail
        lfail="$(printf '%s' "$fail_reason" | tr '[:upper:]' '[:lower:]')"
        if [[ "$lfail" =~ (model_not_found|does[[:space:]]+not[[:space:]]+have[[:space:]]+access|not[[:space:]]+authorized[[:space:]]+for[[:space:]]+model|unknown[[:space:]]+model|403) ]] && declare -F afk_router_mark_model_unavailable >/dev/null 2>&1; then
          afk_router_mark_model_unavailable "$routed_model" "${fail_reason:0:120}"
        else
          afk_router_mark_pool_degraded "$routed_pool" "${fail_reason:0:120}"
        fi
        route_json="$(afk_factory_resolve_stage_route "$repo" "$job_dir" "$stage" "$role")"
        routed_harness="$(jq -r '.harness // "claude"' <<<"$route_json")"
        routed_launch="$(jq -r '.launch_class // "claude-native"' <<<"$route_json")"
        routed_model="$(jq -r '.model // "sonnet"' <<<"$route_json")"
        routed_effort="$(jq -r '.effort // "medium"' <<<"$route_json")"
        routed_window="$(jq -r '.window_tokens // 200000' <<<"$route_json")"
        routed_mem="$(jq -r '.memory_mode // "advisory"' <<<"$route_json")"
        litellm_url="$(jq -r '.litellm_base_url // empty' <<<"$route_json")"
        harness="$routed_harness"
        AFK_LAST_STAGE_WINDOW_TOKENS="$routed_window"
        attempt=$((attempt + 1))
        continue
      fi
      return "$h_rc"
    done
  fi

  # Canned stage outputs for offline tests (AFK_FACTORY_OFFLINE_SYNTH=1 only).
  if [[ -s "$output_file" ]]; then
    return 0
  fi

  case "$stage" in
    intake)
      cat > "$output_file" <<'EOF'
VERDICT: ACCEPT
RISK: low
SURFACES: code
## Summary
- Scoped request from issue.md for autonomous factory execution.
EOF
      ;;
    spec)
      cat > "$output_file" <<EOF
# Specification
## Summary
- Generated specification from issue brief.
- Target repository: $repo

## Acceptance Criteria
1. Implement the requested change cleanly inside the worktree.
2. Pass all deterministic checks in \`.afk/checks.sh\`.
3. Pass independent review lenses with zero blocker findings.
EOF
      ;;
    ux)
      cat > "$output_file" <<'EOF'
# UX Specification
## Summary
- Keep UI states clear, accessible, and consistent with existing components.
EOF
      ;;
    build)
      local sha="HEAD"
      if git -C "$wt" rev-parse --short HEAD >/dev/null 2>&1; then
        sha="$(git -C "$wt" rev-parse --short HEAD)"
        # A canned build still has to change something: a branch with no
        # change on it is never approved for merge.
        if [[ "$wt" != "$repo" ]]; then
          printf 'Canned build for %s at %s.\n' "$(basename -- "$job_dir")" "$sha" >> "$wt/AFK_SYNTH_BUILD.md"
        fi
      fi
      cat > "$output_file" <<EOF
## Summary
- Completed build pass on worktree branch.
- Verified local project structure at commit \`$sha\`.
EOF
      ;;
    review*)
      cat > "$output_file" <<'EOF'
VERDICT: PASS
## Summary
- Verified implementation against spec.md and deterministic gate results.
- No blocker or major findings.
EOF
      ;;
  esac
  return 0
}

# _afk_factory_prompt_text <file>
# The compiled prompt as one string for a CLI argument. The kernel refuses a
# single argument over 128 KB, and the refusal looks like any other launch
# failure, so a long pasted log would fail every harness in turn. The prompt
# is cut to fit and says so.
_afk_factory_prompt_text() {
  local file="$1" max="${AFK_FACTORY_PROMPT_MAX_BYTES:-110000}" size
  [[ "$max" =~ ^[0-9]+$ && "$max" -gt 1000 ]] || max=110000
  size="$(wc -c < "$file" 2>/dev/null | tr -d '[:space:]')"
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  if (( size <= max )); then
    cat -- "$file"
    return 0
  fi
  head -c "$max" -- "$file"
  printf '\n\n[The prompt was cut here at %s bytes of %s. Read the files named above for the rest.]\n' "$max" "$size"
}

# _afk_factory_touch_heartbeat <job_dir> <stage> <role> <state:running|idle|done> [<runner_pid>]
# Records that the job's runner is alive and where it is. The watchdog reads
# it to tell a working stage from a crashed or silent one. The runner is
# named by PID plus start time and boot: a PID alone is reused after a
# restart. A recovery count is kept while the job stays in one stage and
# cleared when it moves on, so three interruptions spread over a long job are
# not counted as three failures of one stage.
_afk_factory_touch_heartbeat() {
  local job_dir="$1" stage="$2" role="${3:-}" state="${4:-running}" runner="${5:-}"
  local hb_file="$job_dir/heartbeat.json" cur="{}"
  [[ -f "$hb_file" ]] && cur="$(cat -- "$hb_file" 2>/dev/null || printf '{}')"
  jq -e 'type == "object"' <<<"$cur" >/dev/null 2>&1 || cur="{}"
  local now_iso now_ep nudges prev_stage pid_val="null" start="" boot=""
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  now_ep="$(date -u +%s)"
  nudges="$(jq -r '.nudge_count // 0' <<<"$cur" 2>/dev/null || printf '0')"
  [[ "$nudges" =~ ^[0-9]+$ ]] || nudges=0
  prev_stage="$(jq -r '.stage // empty' <<<"$cur" 2>/dev/null || true)"
  [[ -n "$prev_stage" && "$prev_stage" != "$stage" ]] && nudges=0
  if [[ "$state" == "running" ]]; then
    # $BASHPID, not $$: in a background job $$ is the poll process.
    pid_val="${runner:-$BASHPID}"
    [[ "$pid_val" =~ ^[0-9]+$ ]] || pid_val="$BASHPID"
    start="$(_afk_factory_proc_start "$pid_val" 2>/dev/null || true)"
    boot="$(_afk_factory_boot_id)"
  fi
  local tmp
  tmp="$(mktemp "${hb_file}.tmp.XXXXXX" 2>/dev/null)" || return 0
  if jq -cn \
    --arg st "$stage" \
    --arg rl "$role" \
    --arg s "$state" \
    --arg iso "$now_iso" \
    --argjson ep "$now_ep" \
    --argjson pid "$pid_val" \
    --arg start "$start" \
    --arg boot "$boot" \
    --argjson nc "$nudges" \
    '{
      schema: "afk-factory-heartbeat/1",
      pid: $pid,
      start: (if $start == "" then null else $start end),
      boot: (if $boot == "" then null else $boot end),
      state: $s,
      stage: $st,
      role: $rl,
      last_beat_at: $iso,
      last_beat_epoch: $ep,
      nudge_count: $nc
    }' > "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
    mv -f -- "$tmp" "$hb_file"
  else
    rm -f -- "$tmp"
  fi
}

# _afk_factory_beat_start <job_dir> <stage> <role> / _afk_factory_beat_stop
# Keeps the heartbeat fresh while a stage or the check gate runs. Without it
# the heartbeat is written only when a stage starts and ends, so any stage
# longer than the stall threshold looks stalled and gets killed mid-work.
AFK_FACTORY_BEAT_PID=""
AFK_FACTORY_BEAT_DIR=""
_afk_factory_beat_start() {
  local job_dir="$1" stage="$2" role="${3:-}" parent="$BASHPID" every="${AFK_FACTORY_BEAT_SEC:-60}"
  [[ "$every" =~ ^[0-9]+$ && "$every" -gt 0 ]] || every=60
  _afk_factory_beat_stop
  # Without timeout or gtimeout nothing bounds a stage, and the watchdog's
  # stall check is the only limit left. A fresh heartbeat would disable it.
  # Landing is bounded by its own check wait, so it beats regardless.
  if [[ "$stage" != "landing" ]]; then
    command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1 || return 0
  fi
  AFK_FACTORY_BEAT_DIR="$job_dir"
  (
    while sleep "$every"; do
      # Stop with the runner: a beat that outlived it would hide a crash.
      kill -0 "$parent" 2>/dev/null || exit 0
      _afk_factory_touch_heartbeat "$job_dir" "$stage" "$role" "running" "$parent"
    done
  ) </dev/null >/dev/null 2>&1 &
  AFK_FACTORY_BEAT_PID=$!
}
_afk_factory_beat_stop() {
  if [[ -n "${AFK_FACTORY_BEAT_PID:-}" ]]; then
    pkill -P "$AFK_FACTORY_BEAT_PID" 2>/dev/null || true
    kill "$AFK_FACTORY_BEAT_PID" 2>/dev/null || true
    wait "$AFK_FACTORY_BEAT_PID" 2>/dev/null || true
    # A beat stopped mid-write leaves its temp file.
    [[ -n "$AFK_FACTORY_BEAT_DIR" ]] && rm -f -- "$AFK_FACTORY_BEAT_DIR"/heartbeat.json.tmp.* 2>/dev/null
  fi
  AFK_FACTORY_BEAT_PID=""
  AFK_FACTORY_BEAT_DIR=""
}


# _afk_factory_report_stage_telemetry <slug> <job_dir> <stage> <role> <issue_id> <api_url> <key> <company_id> <host_agent_id> <project_id> <run_id> [<gen>]
_afk_factory_report_stage_telemetry() {
  local slug="$1" job_dir="$2" stage="$3" role="$4" issue_id="${5:-}"
  local api_url="${6:-}" key="${7:-}" company_id="${8:-}" host_agent_id="${9:-}"
  local project_id="${10:-}" run_id="${11:-}" gen="${12:-1}"
  [[ -n "$api_url" && -n "$key" && -n "$company_id" && -n "$host_agent_id" ]] || return 0
  declare -F afk_pch_report_cost_event >/dev/null 2>&1 || return 0

  local round_num=1 job_id_val
  job_id_val="$(basename -- "$job_dir")"
  if [[ -f "$job_dir/job.json" ]]; then
    round_num="$(jq -r '.round // 1' "$job_dir/job.json" 2>/dev/null || printf '1')"
  fi
  local cc="${AFK_LAST_STAGE_COST_CLASS:-subscription}" btype="subscription_included"
  case "$cc" in
    free)        btype="fixed" ;;
    api-metered) btype="metered_api" ;;
    *)           btype="subscription_included" ;;
  esac
  local prov="${AFK_LAST_STAGE_PROVIDER:-anthropic}"
  local biller="${AFK_LAST_STAGE_HARNESS:-claude}"
  local model="${AFK_LAST_STAGE_MODEL:-sonnet}"
  local in_tok="${AFK_LAST_STAGE_INPUT_TOKENS:-0}"
  local cached_tok="${AFK_LAST_STAGE_CACHED_TOKENS:-0}"
  local out_tok="${AFK_LAST_STAGE_OUTPUT_TOKENS:-0}"
  local cost_cents="${AFK_LAST_STAGE_COST_CENTS:-0}"
  local bcode="afk:${slug}:${stage}:${role}"
  local idem="afk-cost:${job_id_val}:${stage}:${role}:r${round_num}:g${gen}"

  afk_pch_report_cost_event "$api_url" "$key" "$company_id" "$host_agent_id" \
    "$issue_id" "$project_id" "$run_id" "$bcode" "$prov" "$biller" "$btype" \
    "$model" "$in_tok" "$cached_tok" "$out_tok" "$cost_cents" "$idem" >/dev/null 2>&1 || true
}

# _afk_factory_write_review_report <job_dir> <round>
# Aggregates deterministic check gate output and all reviewer verdicts for <round>
# into <job_dir>/review-report.md for Paperclip Issue Document publication.
_afk_factory_write_review_report() {
  local job_dir="$1" round="$2"
  local round_dir="$job_dir/round-$round" out_file="$job_dir/review-report.md"
  {
    printf '# Gate & Independent Review Report (Round %s)\n\n' "$round"
    if [[ -f "$round_dir/checks.md" ]]; then
      printf '## Deterministic Gate (`.afk/checks.sh`)\n\n'
      cat -- "$round_dir/checks.md" 2>/dev/null || true
      printf '\n\n'
    fi
    local rf
    for rf in "$round_dir"/review-*.md; do
      [[ -f "$rf" ]] || continue
      printf '## Independent Review — `%s`\n\n' "$(basename -- "$rf" .md)"
      cat -- "$rf" 2>/dev/null || true
      printf '\n\n'
    done
  } > "$out_file"
}

# owner/name when origin points at GitHub. Empty otherwise.
# Accepts the https, scp-style and ssh:// forms, with or without a port, a
# trailing slash or ".git", and the ssh.github.com alias. The host must be
# github.com itself: "notgithub.com" is not GitHub.
_afk_factory_github_repo() { # <repo>
  local url
  url="$(git -C "$1" remote get-url origin 2>/dev/null || true)"
  url="${url%/}"
  url="${url%.git}"
  if [[ "$url" =~ (^|[@/])(ssh\.)?github\.com(:[0-9]+)?[:/]([^/:]+)/([^/]+)$ ]]; then
    printf '%s/%s' "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
  fi
}
# 0 when origin names GitHub in a form the parser above could not read. The
# caller must stop there; treating the repo as "not GitHub" would merge the
# branch into the local checkout and report it merged.
_afk_factory_github_unparsed() { # <repo>
  local url
  url="$(git -C "$1" remote get-url origin 2>/dev/null || true)"
  [[ "$url" =~ (^|[@/.])github\.com([:/]|$) ]] && [[ -z "$(_afk_factory_github_repo "$1")" ]]
}

_afk_factory_stage_command() { # <repo> <role>
  local repo="$1" role="$2" skill=""
  if declare -F afk_roster_resolve_skill >/dev/null 2>&1; then
    skill="$(afk_roster_resolve_skill "$repo" "$role" 2>/dev/null || true)"
  fi
  if [[ -z "$skill" || "$skill" == "builtin" ]]; then
    printf 'builtin-%s' "$role"
  else
    basename -- "$(dirname -- "$skill")"
  fi
}

# One row per stage so the card can show which command and model did the work.
_afk_factory_note_stage() { # <job_dir> <repo> <stage> <role> <api> <key> <run> <issue> <host>
  local job_dir="$1" repo="$2" stage="$3" role="$4" api="${5:-}" key="${6:-}" run="${7:-}" issue="${8:-}" host="${9:-}"
  local model effort cmd line
  model="${AFK_LAST_STAGE_HARNESS:-unknown}/${AFK_LAST_STAGE_MODEL:-unknown}"
  effort="${AFK_LAST_STAGE_EFFORT:-medium}"
  cmd="$(_afk_factory_stage_command "$repo" "$role")"
  printf '%s\n' "$(jq -cn --arg st "$stage" --arg role "$role" --arg cmd "$cmd" --arg model "$model" --arg ef "$effort" \
    '{stage:$st, role:$role, command:$cmd, model:$model, effort:$ef}')" >> "$job_dir/who.jsonl"
  {
    printf '%s\n' "# Who is working"
    printf '\n'
    if [[ -f "$job_dir/workspace.txt" ]]; then
      cat -- "$job_dir/workspace.txt"
      printf '\n'
    fi
    printf 'Worktree: %s\n' "$(jq -r '.worktree_path // "unset"' "$job_dir/job.json" 2>/dev/null || printf 'unset')"
    printf '%s\n' "| Stage | Role | Command | Model | Effort |"
    printf '%s\n' "| --- | --- | --- | --- | --- |"
    jq -r '[.stage, .role, .command, .model, .effort] | "| " + join(" | ") + " |"' "$job_dir/who.jsonl"
    printf '\n%s\n' "Review uses the review command in that table. A project with no project skills uses the built-in command of the same name."
    printf '%s\n' "Monitor is the check-in on this card. Watchdog is the host agent. Neither is a project skill."
  } > "$job_dir/who.md"
  if [[ -n "$api" && -n "$key" && -n "$issue" ]]; then
    local next notes
    next="$(date -u -d '+20 minutes' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
    notes="$stage is $model ($effort), command $cmd"
    afk_pc_curl PATCH "$api/api/issues/$issue" "$key" "$run" \
      "$(jq -cn --arg t "$next" --arg n "${notes:0:500}" '{executionPolicy:{monitor:{nextCheckAt:$t, notes:$n, scheduledBy:"assignee", recoveryPolicy:"wake_owner"}}}')" >/dev/null 2>&1 || true
    afk_pch_upsert_document "$api" "$key" "$run" "$issue" "who" "Who is working" "$job_dir/who.md" "$notes" >/dev/null 2>&1 || true
    afk_pc_comment "$api" "$issue" "$key" "$run" "$(printf '%s · %s · %s · %s · %s' "$stage" "$role" "$cmd" "$model" "$effort")" >/dev/null 2>&1 || true
  fi
}

# Watchdog dropdown = host. Workspace path is recorded. Project agents stay idle.
_afk_factory_bind_issue_controls() { # <api> <key> <run> <issue> <host> <job_dir>
  local api="$1" key="$2" run="$3" issue="$4" host="$5" job_dir="$6"
  [[ -n "$api" && -n "$key" && -n "$issue" && -n "$host" ]] || return 0
  afk_pc_curl PUT "$api/api/issues/$issue/watchdog" "$key" "$run" \
    "$(jq -cn --arg a "$host" '{agentId:$a, instructions:"Resume the current stage. Do not redo intake or spec when those files already exist."}')" >/dev/null 2>&1 || true
  local resp body name cwd
  resp="$(afk_pc_curl GET "$api/api/issues/$issue" "$key" "" 2>/dev/null || true)"
  if [[ "${resp%%$'\n'*}" == 2?? ]]; then
    body="${resp#*$'\n'}"
    name="$(jq -r '.currentExecutionWorkspace.name // empty' <<<"$body" 2>/dev/null || true)"
    cwd="$(jq -r '.currentExecutionWorkspace.cwd // empty' <<<"$body" 2>/dev/null || true)"
    if [[ -n "$name" || -n "$cwd" ]]; then
      printf 'Workspace: %s\nPath: %s\n' "${name:-unset}" "${cwd:-unset}" > "$job_dir/workspace.txt"
    fi
  fi
}

_afk_factory_clear_execution_policy() { # <api> <key> <run> <issue>
  [[ -n "${1:-}" && -n "${2:-}" && -n "${4:-}" ]] || return 0
  afk_pc_curl PATCH "$1/api/issues/$4" "$2" "${3:-}" '{"executionPolicy":null}' >/dev/null 2>&1 || true
}

_afk_factory_set_approval_gate() { # <api> <key> <run> <issue> <host> <board_user>
  local api="$1" key="$2" run="$3" issue="$4" host="$5" board="$6"
  [[ -n "$api" && -n "$key" && -n "$issue" && -n "$host" && -n "$board" ]] || return 0
  # Review participant stays the host. A paused project agent cannot advance
  # the stage. The board user is the approver.
  afk_pc_curl PATCH "$api/api/issues/$issue" "$key" "$run" \
    "$(jq -cn --arg a "$host" --arg u "$board" '{
      assigneeAgentId: $a,
      executionPolicy: {
        mode: "normal",
        stages: [
          {type: "review", approvalsNeeded: 1, participants: [{type: "agent", agentId: $a}]},
          {type: "approval", approvalsNeeded: 1, participants: [{type: "user", userId: $u}]}
        ]
      }
    }')" >/dev/null 2>&1 || true
}

# Push the branch and open a pull request. Prints the URL, or nothing.
# A pull request already open for the branch is reused. One already merged is
# returned too, so a job restarted after its merge finds the merge and does
# not open a second pull request.
_afk_factory_ensure_pr() { # <abs_repo> <wt> <branch> <title> <job_id>
  local abs_repo="$1" wt="$2" branch="$3" title="$4" job_id="$5"
  local remote ghbin base list url job_dir
  remote="$(_afk_factory_github_repo "$abs_repo")"
  [[ -n "$remote" ]] || return 1
  ghbin="${AFK_FACTORY_GH_BIN:-gh}"
  command -v "$ghbin" >/dev/null 2>&1 || return 1
  local land_mode
  land_mode="$(jq -r '.land // "auto"' <<<"$(afk_factory_load_config "$abs_repo")" 2>/dev/null || printf 'auto')"
  [[ "$land_mode" == "local" ]] && return 1
  job_dir="$abs_repo/.afk/jobs/$job_id"
  base="$(_afk_factory_job_base_branch "$job_dir" "$wt")"
  [[ -n "$base" ]] || base="main"
  list="$("$ghbin" pr list --repo "$remote" --head "$branch" --state all --json url,number,state,headRefOid 2>/dev/null || true)"
  # A merged pull request counts as this job's merge only when it merged the
  # commit the worktree holds now. One merged by hand before a later round
  # does not carry that round's commits.
  local wt_head
  wt_head="$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)"
  url="$(jq -r --arg h "$wt_head" 'if type=="array" then ([.[] | select((.state // "OPEN") == "MERGED" and ((.headRefOid // "") == $h))][0].url // empty) else empty end' <<<"$list" 2>/dev/null || true)"
  if [[ -n "$url" ]]; then
    printf '%s' "$url"
    return 0
  fi
  if [[ "${AFK_FACTORY_SKIP_PUSH:-}" != "1" ]]; then
    git -C "$wt" push -u origin "$branch" >/dev/null 2>&1 || return 1
  fi
  url="$(jq -r 'if type=="array" then ([.[] | select((.state // "OPEN") == "OPEN")][0].url // empty) else empty end' <<<"$list" 2>/dev/null || true)"
  if [[ -z "$url" ]]; then
    url="$("$ghbin" pr create --repo "$remote" --base "$base" --head "$branch" --title "$title" \
      --body "$(printf 'Branch %s for %s.\n' "$branch" "$job_id")" 2>/dev/null || true)"
    url="$(printf '%s\n' "$url" | grep -E '^https://' | head -n 1 || true)"
  fi
  [[ -n "$url" ]] || return 1
  printf '%s' "$url"
}

# _afk_factory_pr_checks_state <ghbin> <remote> <pr_url> -> pass | fail | pending | none | unknown
# Reads the pull request's check runs and commit statuses.
_afk_factory_pr_checks_state() {
  local ghbin="$1" remote="$2" url="$3" doc
  doc="$("$ghbin" pr view --repo "$remote" "$url" --json statusCheckRollup 2>/dev/null)" || { printf 'unknown'; return 0; }
  jq -r '
    if (type != "object") then "unknown"
    else
      [ (.statusCheckRollup // [])[]
        | if (.status // null) != null or (.conclusion // null) != null then
            (if ((.status // "") | ascii_upcase) != "COMPLETED" then "pending"
             elif ((.conclusion // "") | ascii_upcase) as $c | ($c == "SUCCESS" or $c == "NEUTRAL" or $c == "SKIPPED") then "pass"
             else "fail" end)
          else
            ((.state // "") | ascii_upcase) as $st
            | (if $st == "SUCCESS" then "pass" elif ($st == "PENDING" or $st == "EXPECTED" or $st == "") then "pending" else "fail" end)
          end ]
      | if length == 0 then "none" elif any(. == "fail") then "fail" elif any(. == "pending") then "pending" else "pass" end
    end' <<<"$doc" 2>/dev/null || printf 'unknown'
}

# _afk_factory_wait_pr_checks <abs_repo> <ghbin> <remote> <pr_url>
# Waits for the pull request's checks before a merge. Prints nothing and
# returns 0 when they passed or the repository has none; otherwise prints the
# reason and returns 1. Merging the moment the pull request opens ships the
# change before CI has reported, and on a repository with required checks the
# merge is simply refused every time.
_afk_factory_wait_pr_checks() {
  local abs_repo="$1" ghbin="$2" remote="$3" url="$4" cfg mode tmo every settle state waited=0 seen_any=false
  cfg="$(afk_factory_load_config "$abs_repo")"
  mode="$(jq -r '.land_checks // "wait"' <<<"$cfg" 2>/dev/null || printf 'wait')"
  [[ "$mode" == "skip" ]] && return 0
  tmo="${AFK_FACTORY_CHECKS_TIMEOUT_SEC:-$(jq -r '.land_checks_timeout_sec // 1200' <<<"$cfg" 2>/dev/null || printf '1200')}"
  every="${AFK_FACTORY_CHECKS_POLL_SEC:-20}"
  # Checks appear a little after the pull request does. An empty list this
  # early does not yet mean the repository has no checks.
  settle="${AFK_FACTORY_CHECKS_SETTLE_SEC:-30}"
  [[ "$tmo" =~ ^[0-9]+$ ]] || tmo=1200
  [[ "$every" =~ ^[0-9]+$ && "$every" -gt 0 ]] || every=20
  [[ "$settle" =~ ^[0-9]+$ ]] || settle=30
  while :; do
    state="$(_afk_factory_pr_checks_state "$ghbin" "$remote" "$url")"
    case "$state" in
      pass) return 0 ;;
      fail) printf 'Pull request checks failed'; return 1 ;;
      unknown) printf 'Pull request checks could not be read'; return 1 ;;
      none)
        if [[ "$seen_any" == false ]] && (( waited >= settle )); then
          return 0
        fi
        ;;
      pending) seen_any=true ;;
    esac
    if (( waited >= tmo )); then
      printf 'Pull request checks were still running after %ss' "$tmo"
      return 1
    fi
    sleep "$every"
    waited=$(( waited + every ))
  done
}

# _afk_factory_land_branch <abs_repo> <wt_dir> <branch> <job_id> <title>
# A GitHub origin opens a pull request and merges that. Any other checkout
# merges the branch locally. Prints JSON. `ok:true` means the change is on the
# base branch; a branch with nothing on it is never reported as landed.
_afk_factory_land_branch() {
  local abs_repo="$1" wt_dir="$2" branch="$3" job_id="$4" title="$5"
  local pr_url="" remote="" land_mode="auto"
  remote="$(_afk_factory_github_repo "$abs_repo")"
  land_mode="$(jq -r '.land // "auto"' <<<"$(afk_factory_load_config "$abs_repo")" 2>/dev/null || printf 'auto')"
  if [[ -z "$remote" && "$land_mode" != "local" ]] && _afk_factory_github_unparsed "$abs_repo"; then
    jq -cn '{ok:false, action:"remote_unreadable", commit:"", reason:"origin looks like GitHub but its owner and repository could not be read; nothing was merged"}'
    return 1
  fi
  if [[ -n "$remote" && "$land_mode" != "local" ]]; then
    local ghbin head_sha job_dir base pr_doc pr_state merge_sha pr_num reason
    ghbin="${AFK_FACTORY_GH_BIN:-gh}"
    job_dir="$abs_repo/.afk/jobs/$job_id"
    # Merge exactly the commit the checks ran on and the reviews read. Checked
    # before anything is pushed or waited on.
    head_sha="$(git -C "$wt_dir" rev-parse HEAD 2>/dev/null || true)"
    # With the worktree gone, the branch tip in the base repository is what
    # GitHub has for the pull request.
    [[ -n "$head_sha" ]] || head_sha="$(git -C "$abs_repo" rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null || true)"
    local approved_sha=""
    approved_sha="$(_afk_factory_checked_commit "$job_dir")"
    if [[ -z "$approved_sha" || "$approved_sha" != "$head_sha" ]]; then
      jq -cn '{ok:false, action:"head_moved", commit:"", reason:"The branch is not at the commit the checks ran on; nothing was merged"}'
      return 1
    fi
    pr_url="$(_afk_factory_ensure_pr "$abs_repo" "$wt_dir" "$branch" "$title" "$job_id" 2>/dev/null || true)"
    if [[ -z "$pr_url" ]]; then
      jq -cn '{ok:false, action:"pr_failed", commit:"", reason:"GitHub remote is set and the pull request was not opened"}'
      return 1
    fi
    pr_doc="$("$ghbin" pr view --repo "$remote" "$pr_url" --json state,mergeCommit 2>/dev/null || true)"
    pr_state="$(jq -r '.state // empty' <<<"$pr_doc" 2>/dev/null || true)"
    if [[ "$pr_state" != "MERGED" ]]; then
      if ! reason="$(_afk_factory_wait_pr_checks "$abs_repo" "$ghbin" "$remote" "$pr_url")"; then
        jq -cn --arg u "$pr_url" --arg r "${reason:-Pull request checks did not pass}" '{ok:false, action:"checks_not_green", commit:"", pr_url:$u, reason:$r}'
        return 1
      fi
      # Squash under a subject and body written here, pinned to the checked
      # commit. The default squash message strings the branch's commit
      # messages together, trailers included.
      pr_num="${pr_url##*/}"
      local -a merge_args=(pr merge --repo "$remote" --squash --subject "$title (#$pr_num)" --body "")
      [[ -n "$head_sha" ]] && merge_args+=(--match-head-commit "$head_sha")
      if ! "$ghbin" "${merge_args[@]}" "$pr_url" >/dev/null 2>&1; then
        jq -cn --arg u "$pr_url" '{ok:false, action:"pr_open", commit:"", pr_url:$u, reason:"Pull request is open and was not merged"}'
        return 1
      fi
      pr_doc="$("$ghbin" pr view --repo "$remote" "$pr_url" --json state,mergeCommit 2>/dev/null || true)"
    fi
    # The merge commit GitHub made, not whatever the local checkout holds.
    merge_sha="$(jq -r '.mergeCommit.oid // empty' <<<"$pr_doc" 2>/dev/null || true)"
    base="$(_afk_factory_job_base_branch "$job_dir" "$abs_repo")"
    local pull_note=""
    if [[ "${AFK_FACTORY_SKIP_PUSH:-}" != "1" ]]; then
      git -C "$abs_repo" pull --ff-only "origin" "$base" >/dev/null 2>&1 || pull_note="the local checkout could not be fast-forwarded to it"
    fi
    [[ -n "$merge_sha" ]] || merge_sha="$(git -C "$abs_repo" rev-parse HEAD 2>/dev/null || true)"
    [[ -d "$wt_dir" && "$wt_dir" != "$abs_repo" ]] && git -C "$abs_repo" worktree remove --force "$wt_dir" >/dev/null 2>&1 || true
    jq -cn --arg c "$merge_sha" --arg u "$pr_url" --arg n "$pull_note" \
      '{ok:true, action:"merged_pr", commit:$c, pr_url:$u} + (if $n == "" then {} else {note:$n} end)'
    return 0
  fi
  if [[ ! -d "$abs_repo/.git" && ! -f "$abs_repo/.git" ]]; then
    printf '{"ok":true,"action":"non_git","commit":""}\n'
    return 0
  fi
  if [[ "$wt_dir" == "$abs_repo" ]]; then
    jq -cn '{ok:false, action:"in_place", commit:"", reason:"The job ran in the base checkout, so there is no branch to merge"}'
    return 1
  fi
  if ! git -C "$abs_repo" rev-parse --verify "$branch" >/dev/null 2>&1; then
    jq -cn --arg b "$branch" '{ok:false, action:"branch_missing", commit:"", reason:("Branch " + $b + " does not exist; nothing was merged")}'
    return 1
  fi
  # The worktree must be on the job's branch. Work committed to another
  # branch was checked and reviewed there, and merging this one would land
  # nothing while the worktree holding the work is removed.
  if [[ -d "$wt_dir" ]]; then
    local wt_head br_head
    wt_head="$(git -C "$wt_dir" rev-parse HEAD 2>/dev/null || true)"
    br_head="$(git -C "$abs_repo" rev-parse "$branch" 2>/dev/null || true)"
    if [[ -n "$wt_head" && -n "$br_head" && "$wt_head" != "$br_head" ]]; then
      jq -cn --arg b "$branch" '{ok:false, action:"branch_mismatch", commit:"", reason:("The worktree is not on " + $b + "; the reviewed work is on another branch and was not merged")}'
      return 1
    fi
  fi
  local ahead=""
  ahead="$(git -C "$abs_repo" rev-list --count "HEAD..$branch" 2>/dev/null || true)"
  if [[ ! "$ahead" =~ ^[0-9]+$ ]]; then
    jq -cn --arg b "$branch" '{ok:false, action:"unreadable", commit:"", reason:("Could not compare " + $b + " with the base checkout")}'
    return 1
  fi
  if (( ahead == 0 )); then
    # Already contained in the base: only true when an earlier run of this
    # job merged it. A branch still at the commit it was cut from has nothing
    # on it, and is never reported as landed.
    local base_sha_j br_sha
    base_sha_j="$(jq -r '.base_sha // empty' "$abs_repo/.afk/jobs/$job_id/job.json" 2>/dev/null || true)"
    br_sha="$(git -C "$abs_repo" rev-parse "$branch" 2>/dev/null || true)"
    if [[ -n "$base_sha_j" && "$br_sha" == "$base_sha_j" ]]; then
      jq -cn --arg b "$branch" '{ok:false, action:"nothing_to_merge", commit:"", reason:("Branch " + $b + " has no commits beyond the one it was cut from")}'
      return 1
    fi
    local sha
    sha="$(git -C "$abs_repo" rev-parse HEAD 2>/dev/null || true)"
    if [[ -d "$wt_dir" ]] && [[ -z "$(git -C "$wt_dir" status --porcelain -- . ':!.afk' 2>/dev/null || true)" ]]; then
      git -C "$abs_repo" worktree remove --force "$wt_dir" >/dev/null 2>&1 || true
    fi
    jq -cn --arg c "$sha" '{ok:true, action:"already_up_to_date", commit:$c}'
    return 0
  fi
  local dirty_tracked
  dirty_tracked="$(git -C "$abs_repo" status --porcelain --untracked-files=no 2>/dev/null || true)"
  if [[ -n "$dirty_tracked" ]]; then
    jq -cn '{ok:false, action:"dirty_base", commit:"", reason:"Base repository checkout has uncommitted tracked modifications"}'
    return 1
  fi
  # Merge the commit the checks ran on, and only while the branch is still
  # there: a branch moved since is not what was checked and reviewed.
  local checked_sha
  checked_sha="$(_afk_factory_checked_commit "$abs_repo/.afk/jobs/$job_id")"
  if [[ -z "$checked_sha" || "$checked_sha" != "$(git -C "$abs_repo" rev-parse "$branch" 2>/dev/null || true)" ]]; then
    jq -cn '{ok:false, action:"head_moved", commit:"", reason:"The branch is not at the commit the checks ran on; nothing was merged"}'
    return 1
  fi
  if git -C "$abs_repo" merge --no-ff "$checked_sha" -m "Merge branch '$branch' ($job_id): $title" >/dev/null 2>&1; then
    local merged_sha
    merged_sha="$(git -C "$abs_repo" rev-parse HEAD 2>/dev/null || true)"
    [[ -d "$wt_dir" ]] && git -C "$abs_repo" worktree remove --force "$wt_dir" >/dev/null 2>&1 || true
    jq -cn --arg c "$merged_sha" '{ok:true, action:"merged", commit:$c}'
    return 0
  else
    git -C "$abs_repo" merge --abort >/dev/null 2>&1 || true
    jq -cn --arg b "$branch" '{ok:false, action:"conflict", commit:"", reason:("Git merge conflict landing " + $b + " into base checkout")}'
    return 1
  fi
}

# _afk_factory_latest_comment_id <api_url> <key> <issue_id>
_afk_factory_latest_comment_id() {
  local api_url="${1:-}" key="${2:-}" issue_id="${3:-}"
  [[ -n "$api_url" && -n "$key" && -n "$issue_id" ]] || return 0
  local resp code body
  resp="$(afk_pc_curl GET "$api_url/api/issues/$issue_id/comments" "$key" "")"
  code="${resp%%$'\n'*}"
  body="${resp#*$'\n'}"
  if [[ "$code" == 2?? ]]; then
    jq -r 'if type == "array" then (last.id // empty) else ((.comments // []) | last.id // empty) end' <<<"$body" 2>/dev/null || true
  fi
}

# afk_factory_run_stage_with_context_guard <slug> <repo> <wt> <job_dir> <role> <stage> <prompt_file> <output_file> <issue_id> <api_url> <key> <harness> [<company_id>] [<host_agent_id>] [<project_id>] [<run_id>]
# Invokes a stage agent, records its context window consumption & Paperclip cost telemetry,
# and if it crosses the 80% threshold (or compacts), automatically checkpoints, resets its
# Paperclip session, and spawns the replacement generation to finish the stage cleanly.
afk_factory_run_stage_with_context_guard() {
  local slug="$1" repo="$2" wt="$3" job_dir="$4" role="$5" stage="$6"
  local prompt_file="$7" output_file="$8" issue_id="$9" api_url="${10:-}" key="${11:-}" harness="${12:-}"
  local company_id="${13:-}" host_agent_id="${14:-}" project_id="${15:-}" run_id="${16:-}"

  local stage_rc=0
  AFK_LAST_STAGE_FAILURE=""
  _afk_factory_touch_heartbeat "$job_dir" "$stage" "$role" "running"
  _afk_factory_beat_start "$job_dir" "$stage" "$role"
  afk_factory_invoke_stage_agent "$repo" "$wt" "$job_dir" "$role" "$stage" "$prompt_file" "$output_file" "$harness" || stage_rc=$?
  _afk_factory_beat_stop
  rm -f "$job_dir/watchdog-nudge.md"
  _afk_factory_touch_heartbeat "$job_dir" "$stage" "$role" "running"
  # A review that failed or ran out of time leaves no verdict behind, even if
  # it wrote one before it stopped.
  if (( stage_rc != 0 )) && [[ "$stage" == review* ]]; then
    rm -f -- "$output_file"
  fi
  # A stage that wrote nothing has failed whatever its exit status says.
  if (( stage_rc == 0 )) && [[ ! -s "$output_file" ]]; then
    stage_rc=1
    AFK_LAST_STAGE_FAILURE="${AFK_LAST_STAGE_FAILURE:-empty_stage_output}"
  fi
  _afk_factory_report_stage_telemetry "$slug" "$job_dir" "$stage" "$role" "$issue_id" "$api_url" "$key" "$company_id" "$host_agent_id" "$project_id" "$run_id" "1"

  if [[ -n "${AFK_LAST_STAGE_USED_TOKENS:-}" ]]; then
    local ctx_res ctx_act ctx_new_gen ckpt_file
    ctx_res="$(afk_roster_record_and_check_context "$job_dir" "$role" "$AFK_LAST_STAGE_USED_TOKENS" "${AFK_LAST_STAGE_WINDOW_TOKENS:-200000}" "${AFK_LAST_STAGE_COMPACTED:-false}" "$wt")"
    ctx_act="$(jq -r '.action' <<<"$ctx_res")"
    if [[ "$ctx_act" == "replaced" ]]; then
      ctx_new_gen="$(jq -r '.active_generation' <<<"$ctx_res")"
      ckpt_file="$job_dir/checkpoints/${role}-gen-$((ctx_new_gen - 1)).md"
      afk_pch_replace_agent_session "$slug" "$role" "$ctx_new_gen" "$issue_id" "context usage crossed 80% threshold during $stage" "$api_url" "$key" "$run_id"
    fi
    # Each stage is one bounded run, so by the time usage is known the stage
    # is over. A stage that finished keeps its output; re-running it here
    # deleted a completed review and asked a fresh agent for a new verdict.
    # Only a stage that failed is handed to the replacement.
    if [[ "$ctx_act" == "replaced" ]] && (( stage_rc != 0 )); then
      # Clear token override before re-running replacement generation so it doesn't loop infinitely on a static env var
      local saved_stage_tokens="${AFK_STAGE_USED_TOKENS:-}"
      unset AFK_STAGE_USED_TOKENS
      stage_rc=0
      _afk_factory_beat_start "$job_dir" "$stage" "$role"
      afk_factory_invoke_stage_agent "$repo" "$wt" "$job_dir" "$role" "$stage" "$ckpt_file" "$output_file" "$harness" || stage_rc=$?
      _afk_factory_beat_stop
      (( stage_rc == 0 )) && [[ ! -s "$output_file" ]] && stage_rc=1
      _afk_factory_report_stage_telemetry "$slug" "$job_dir" "$stage" "$role" "$issue_id" "$api_url" "$key" "$company_id" "$host_agent_id" "$project_id" "$run_id" "$ctx_new_gen"
      [[ -n "$saved_stage_tokens" ]] && AFK_STAGE_USED_TOKENS="$saved_stage_tokens"
    fi
  fi
  _afk_factory_note_stage "$job_dir" "$repo" "$stage" "$role" "$api_url" "$key" "$run_id" "$issue_id" "$host_agent_id"
  return "$stage_rc"
}

# afk_factory_run_job <repo_path> <slug> <job_id> <issue_id> <title> <body_file> <json_mode>
# Drives a job through the complete AFK Software Factory loop:
#   1. Discovers project agents (BMAD or Factory default) & hires needed roles in Paperclip.
#   2. Runs intake -> spec -> [ux] -> build -> gate -> review -> approve.
#   3. Monitors context window usage after every agent turn & replaces agents that cross 80%.
#   4. Auto-merges clean PRs or escalates to Paperclip when human attention is needed.
#   5. Retires specialist/idle agents when complete.
# _afk_factory_announce <slug> <role> <issue> <summary> <api> <key> <run>
# Shows the stage on the Paperclip issue before its agent starts. A stage the
# board cannot see does not start: the job keeps its place and waits, and the
# next pass tries again. Without Paperclip configured there is nothing to show.
# Reads and writes the job runner's job_file.
_afk_factory_announce() {
  local rc=0
  afk_pch_assign_stage "$@" || rc=$?
  if (( rc == 2 || rc == 3 )); then
    local waits max="${AFK_FACTORY_PAPERCLIP_WAIT_MAX:-15}"
    [[ "$max" =~ ^[0-9]+$ ]] || max=15
    # Only a refusal Paperclip actually answered (rc 2) counts toward the
    # limit. During an outage (rc 3) the job waits without a count: stopping
    # it then would post a notice nobody can see and strand it.
    if (( rc == 2 )); then
      waits="$(jq -r '(.blocked_count // 0) + 1' "$job_file" 2>/dev/null || printf '1')"
    else
      waits="$(jq -r '.blocked_count // 0' "$job_file" 2>/dev/null || printf '0')"
    fi
    jq -c --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg st "$2" --argjson n "$waits" \
      '.blocked_reason = "paperclip_unreachable" | .blocked_role = $st | .blocked_at = $now | .blocked_count = $n' \
      "$job_file" > "$job_file.tmp" && _afk_factory_commit_tmp "$job_file"
    if (( waits > max )); then
      # A refusal that never clears is not an outage. Stop the job for a
      # person instead of retrying for ever.
      jq -c 'del(.blocked_reason, .blocked_role, .blocked_at, .blocked_count)' "$job_file" > "$job_file.tmp" && _afk_factory_commit_tmp "$job_file"
      _afk_factory_fail_job "Paperclip refused to show the $2 stage on the issue $((waits - 1)) times in a row, so the stage was never started" "stage_failure" >/dev/null
      return 1
    fi
    afk_warn "factory: Paperclip did not accept the stage change for ${3:-the issue}; the stage waits for the next pass"
    return 1
  fi
  if jq -e '.blocked_reason != null or .blocked_count != null' "$job_file" >/dev/null 2>&1; then
    jq -c 'del(.blocked_reason, .blocked_role, .blocked_at, .blocked_count)' "$job_file" > "$job_file.tmp" && _afk_factory_commit_tmp "$job_file"
  fi
  return 0
}

# _afk_factory_fail_job <reason> [<kind>]
# Stops the job for a person, with the reason, and merges nothing. Called from
# inside the job runner and reads its locals (job_dir, job_file, job_id, slug,
# json_mode and the Paperclip connection). `kind` records why the job stopped,
# so a later "approve" on the issue is read as "carry on", never as "merge".
_afk_factory_fail_job() {
  local reason="$1" kind="${2:-stage_failure}" now_f last_cid_f=""
  now_f="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cat > "$job_dir/decision.md" <<EOF
DECISION: ESCALATE
## Summary
- $reason
- Nothing was merged.
- Reply on the issue to have the factory try again; anything you write is passed to the agent as instructions.
EOF
  if [[ -n "${api_url:-}" && -n "${key:-}" && -n "${issue_id:-}" ]]; then
    run_id="$(afk_pch_ensure_run_id "$api_url" "$key" "${host_agent_id:-}" "$issue_id")"
    afk_pc_comment "$api_url" "$issue_id" "$key" "$run_id" \
      "$(printf '## AFK Factory — Stopped, Needs a Person\n\n%s' "$(cat "$job_dir/decision.md")")" >/dev/null 2>&1 || true
    # Everything up to this comment has been seen. Without the marker the next
    # review sync would take the newest old comment as a fresh instruction.
    last_cid_f="$(_afk_factory_latest_comment_id "$api_url" "$key" "$issue_id")"
    afk_pc_curl PATCH "$api_url/api/issues/$issue_id" "$key" "$run_id" "$(_afk_factory_in_review_body "${host_agent_id:-}")" >/dev/null 2>&1 || true
  fi
  jq -c --arg now "$now_f" --arg r "$reason" --arg k "$kind" --arg lcid "$last_cid_f" \
    '.stage = "needs-human" | .decision = "ESCALATE" | .active_agent = "human" | .escalation_kind = $k
     | .pending_interaction_id = null
     | .last_seen_comment_id = (if $lcid == "" then (.last_seen_comment_id // null) else $lcid end)
     | .updated_at = $now | .merge_evaluation = {decision:"ESCALATE", reasons:[$r]}' \
    "$job_file" > "$job_file.tmp" && _afk_factory_commit_tmp "$job_file"
  _afk_factory_touch_heartbeat "$job_dir" "needs-human" "" "done"
  if [[ "${json_mode:-false}" == "true" ]]; then
    cat "$job_file"
  else
    printf 'AFK Factory job %s (%s): stage=needs-human decision=ESCALATE (%s)\n' "$job_id" "$slug" "$reason"
  fi
}

# afk_factory_run_job <repo> <slug> <job_id> [<issue_id>] [<title>] [<body_file>] [<json_mode>]
# Runs one job, or continues it from the stage files already on disk.
#
# Exactly one runner drives a job at a time. The poll pass, the watchdog,
# review sync and `factory resume` can all reach the same job; the lock taken
# here is what stops two of them building, pushing and merging it twice. A
# job that already merged or was rejected is never run again.
afk_factory_run_job() {
  local repo="$1" slug="$2" job_id="$3" issue_id="${4:-}" json_mode="${7:-false}"
  local abs_repo
  abs_repo="$(cd -P -- "$repo" 2>/dev/null && pwd -P)" || {
    afk_warn "factory run: invalid repository path"
    return 1
  }
  [[ -n "$job_id" ]] || job_id="${issue_id:-job-$(date -u +%Y%m%d%H%M%S)}"
  # The id becomes a directory name and a branch name.
  if [[ ! "$job_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || "$job_id" == *..* ]]; then
    afk_warn "factory run: a job id may hold only letters, digits, '.', '_' and '-'"
    return 1
  fi
  local job_dir="$abs_repo/.afk/jobs/$job_id"
  local job_file="$job_dir/job.json"
  mkdir -p "$job_dir" || return 1

  if ! _afk_factory_job_lock "$job_dir"; then
    if [[ "$json_mode" == "true" ]]; then
      if jq -e 'type == "object"' "$job_file" >/dev/null 2>&1; then
        jq -c '. + {already_running: true}' "$job_file"
      else
        jq -cn --arg id "$job_id" '{id: $id, stage: "running", already_running: true}'
      fi
    else
      printf 'AFK Factory job %s: already running\n' "$job_id"
    fi
    return 0
  fi

  # Show a sign of life at once: another host judges a foreign lock by it.
  _afk_factory_touch_heartbeat "$job_dir" "$(jq -r '.stage // "intake"' "$job_file" 2>/dev/null || printf 'intake')" "" "running"

  # A job file cut off mid-write is set aside. The stage files on disk carry
  # the job's progress, so it continues from them with a fresh record.
  if [[ -e "$job_file" ]] && ! jq -e 'type == "object"' "$job_file" >/dev/null 2>&1; then
    mv -f -- "$job_file" "$job_file.corrupt.$(date -u +%Y%m%dT%H%M%SZ)" 2>/dev/null || rm -f -- "$job_file"
  fi
  if [[ -f "$job_file" ]]; then
    local done_stage
    done_stage="$(jq -r '.stage // empty' "$job_file" 2>/dev/null || true)"
    if [[ "$done_stage" == "merged" || "$done_stage" == "rejected" ]]; then
      _afk_factory_job_unlock "$job_dir"
      if [[ "$json_mode" == "true" ]]; then
        cat "$job_file"
      else
        printf 'AFK Factory job %s (%s): already %s\n' "$job_id" "$slug" "$done_stage"
      fi
      return 0
    fi
  fi

  # Real agents unless a test asked for canned output or supplied a runner.
  if [[ "${AFK_FACTORY_OFFLINE_SYNTH:-0}" != "1" && -z "${AFK_FACTORY_AGENT_RUNNER:-}" ]]; then
    local -x AFK_FACTORY_LIVE_HARNESS=1
  fi
  local run_rc=0
  _afk_factory_run_job_locked "$abs_repo" "$slug" "$job_id" "${@:4}" || run_rc=$?
  _afk_factory_beat_stop
  _afk_factory_job_unlock "$job_dir"
  return "$run_rc"
}

_afk_factory_run_job_locked() {
  local repo="$1" slug="$2" job_id="$3" issue_id="${4:-}" title="${5:-Factory Task}"
  local body_file="${6:-}" json_mode="${7:-false}"

  local abs_repo
  abs_repo="$(cd -P -- "$repo" 2>/dev/null && pwd -P)" || {
    afk_warn "factory run: invalid repository path"
    return 1
  }
  [[ -n "$slug" ]] || slug="$(basename -- "$abs_repo" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-')"
  slug="${slug%-}"
  [[ -n "$job_id" ]] || job_id="${issue_id:-job-$(date -u +%Y%m%d%H%M%S)}"

  local job_dir="$abs_repo/.afk/jobs/$job_id"
  mkdir -p "$job_dir/round-1"
  local job_file="$job_dir/job.json"
  if [[ -f "$job_file" ]] && jq -e '.mode == "consultation"' "$job_file" >/dev/null 2>&1; then
    afk_factory_run_consultation "$abs_repo" "$slug" "$job_id" "$issue_id" "$title" "$body_file" "$json_mode" \
      "$(jq -r '.consult_role // "pm"' "$job_file")"
    return $?
  fi

  # Load Paperclip connection settings if configured on this host
  local api_url="" company_id="" host_agent_id="" board_user_id="" project_id="" key="" harness="claude"
  local pc_cfg_path
  pc_cfg_path="$(afk_pc_config_path)"
  if [[ -f "$pc_cfg_path" ]]; then
    local pc_cfg
    pc_cfg="$(cat "$pc_cfg_path" 2>/dev/null)" || pc_cfg=""
    if [[ -n "$pc_cfg" ]]; then
      api_url="$(jq -r '.api_url // empty' <<<"$pc_cfg" 2>/dev/null)"
      company_id="$(jq -r '.company_id // empty' <<<"$pc_cfg" 2>/dev/null)"
      host_agent_id="$(jq -r '.host.agent_id // empty' <<<"$pc_cfg" 2>/dev/null)"
      board_user_id="$(jq -r '.board_user_id // empty' <<<"$pc_cfg" 2>/dev/null)"
      project_id="$(jq -r --arg s "$slug" '(.projects[]? | select(.slug == $s) | .paperclip_project_id) // empty' <<<"$pc_cfg" 2>/dev/null)"
      harness="$(jq -r --arg s "$slug" '(.projects[]? | select(.slug == $s) | .harness) // "claude"' <<<"$pc_cfg" 2>/dev/null)"
      local key_ref
      key_ref="$(jq -r '.host.key_ref // empty' <<<"$pc_cfg" 2>/dev/null)"
      if [[ -n "$key_ref" ]]; then
        AFK_PC_CFG="$pc_cfg"
        key="$(afk_pc_read_key "$key_ref" 2>/dev/null || true)"
      fi
    fi
  fi

  # Write issue.md (untrusted input data)
  if [[ -n "$body_file" && -f "$body_file" ]]; then
    if [[ "$(cd -P -- "$(dirname -- "$body_file")" && pwd -P)/$(basename -- "$body_file")" != "$job_dir/issue.md" ]]; then
      cp "$body_file" "$job_dir/issue.md"
    fi
  elif [[ ! -f "$job_dir/issue.md" ]]; then
    printf '# %s\n\nIssue ID: %s\n' "$title" "${issue_id:-local}" > "$job_dir/issue.md"
  fi

  # Every job in a git repository gets its own worktree. If one cannot be
  # made the job stops: running in the base checkout instead would let an
  # agent with permission prompts off edit the branch everything else is cut
  # from. A directory that is not a git repository has nothing to isolate.
  local wt_root wt_dir branch="factory/$job_id" is_git_repo=false wt_error=""
  local base_sha="" base_branch=""
  wt_root="$(dirname -- "$abs_repo")/$(basename -- "$abs_repo")-factory"
  wt_dir="$wt_root/$job_id"
  git -C "$abs_repo" rev-parse --git-dir >/dev/null 2>&1 && is_git_repo=true
  if [[ "$is_git_repo" == true ]]; then
    if [[ ! -d "$wt_dir" ]]; then
      mkdir -p "$wt_root"
      git -C "$abs_repo" worktree prune >/dev/null 2>&1 || true
      # The commit the branch starts from is the diff base for the budget, the
      # protected-path check and the pull request.
      base_sha="$(git -C "$abs_repo" rev-parse HEAD 2>/dev/null || true)"
      base_branch="$(git -C "$abs_repo" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
      if ! git -C "$abs_repo" worktree add -B "$branch" "$wt_dir" HEAD >/dev/null 2>&1; then
        wt_error="Could not create an isolated worktree at $wt_dir"
      fi
    elif ! git -C "$wt_dir" rev-parse --git-dir >/dev/null 2>&1; then
      wt_error="$wt_dir exists and is not a git worktree"
    else
      # It must be this repository's registered worktree for this job's
      # branch, and not the base checkout reached through a link.
      local wt_real reg="" repo_real l_path="" l_line
      wt_real="$(cd -P -- "$wt_dir" 2>/dev/null && pwd -P || true)"
      repo_real="$(cd -P -- "$abs_repo" 2>/dev/null && pwd -P || printf '%s' "$abs_repo")"
      while IFS= read -r l_line; do
        case "$l_line" in
          "worktree "*) l_path="$(cd -P -- "${l_line#worktree }" 2>/dev/null && pwd -P || printf '%s' "${l_line#worktree }")" ;;
          "branch "*) [[ -n "$wt_real" && "$l_path" == "$wt_real" ]] && reg="${l_line#branch }" ;;
        esac
      done < <(git -C "$abs_repo" worktree list --porcelain 2>/dev/null)
      if [[ -z "$wt_real" || "$wt_real" == "$repo_real" ]]; then
        wt_error="$wt_dir resolves to the base checkout"
      elif [[ "$reg" != "refs/heads/$branch" ]]; then
        wt_error="$wt_dir is not this repository's worktree for $branch"
      fi
    fi
  else
    wt_dir="$abs_repo"
  fi

  # Initialize job.json if absent
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ ! -f "$job_file" ]]; then
    jq -cn \
      --arg id "$job_id" \
      --arg slug "$slug" \
      --arg issue "$issue_id" \
      --arg title "$title" \
      --arg repo "$abs_repo" \
      --arg wt "$wt_dir" \
      --arg br "$branch" \
      --arg bsha "$base_sha" \
      --arg bbr "$base_branch" \
      --arg csum "$(_afk_factory_file_digest "$abs_repo/.afk/checks.sh")" \
      --arg now "$now" \
      '{
        schema: "afk-factory-job/1",
        id: $id,
        slug: $slug,
        issue_id: (if $issue == "" then null else $issue end),
        title: $title,
        repo_path: $repo,
        worktree_path: $wt,
        branch: $br,
        base_sha: (if $bsha == "" then null else $bsha end),
        base_branch: (if $bbr == "" then null else $bbr end),
        checks_script_sha256: (if $csum == "" then null else $csum end),
        stage: "intake",
        round: 1,
        risk: "low",
        surfaces: ["code"],
        active_agent: null,
        hired_roles: [],
        decision: null,
        created_at: $now,
        updated_at: $now
      }' > "$job_file.tmp" && _afk_factory_commit_tmp "$job_file"
  fi
  if [[ ! -f "$job_file" ]]; then
    afk_warn "factory run: could not write $job_file"
    return 1
  fi
  _afk_factory_touch_heartbeat "$job_dir" "$(jq -r '.stage // "intake"' "$job_file" 2>/dev/null || printf 'intake')" "" "running"

  # Step 1: Pre-flight Paperclip budget check + hire core team (pm, dev, reviewer, approver) & resolve run_id
  local run_id=""
  if [[ -n "$api_url" && -n "$key" && -n "$issue_id" ]]; then
    run_id="$(afk_pch_ensure_run_id "$api_url" "$key" "$host_agent_id" "$issue_id")"
    _afk_factory_bind_issue_controls "$api_url" "$key" "$run_id" "$issue_id" "$host_agent_id" "$job_dir"
  fi
  if [[ -n "$wt_error" ]]; then
    _afk_factory_fail_job "$wt_error. No agent was started." "no_worktree"
    return 0
  fi
  if [[ -n "$api_url" && -n "$key" && -n "$host_agent_id" ]] && declare -F afk_pch_check_budget >/dev/null 2>&1; then
    local b_chk b_state b_spent b_limit
    b_chk="$(afk_pch_check_budget "$api_url" "$key" "$host_agent_id")"
    b_state="$(jq -r '.state // "ok"' <<<"$b_chk" 2>/dev/null || printf 'ok')"
    if [[ "$b_state" == "hard_stop" ]]; then
      b_spent="$(jq -r '.spent_cents // 0' <<<"$b_chk")"
      b_limit="$(jq -r '.budget_cents // 0' <<<"$b_chk")"
      cat > "$job_dir/decision.md" <<EOF
DECISION: ESCALATE
## Summary
- Paperclip monthly agent budget hard-stop reached (${b_spent}c / ${b_limit}c).
- Pausing autonomous execution until board increases budget or approves continuation.
EOF
      local b_lcid=""
      if [[ -n "$issue_id" ]]; then
        afk_pc_comment "$api_url" "$issue_id" "$key" "$run_id" "$(cat "$job_dir/decision.md")" >/dev/null 2>&1 || true
        b_lcid="$(_afk_factory_latest_comment_id "$api_url" "$key" "$issue_id")"
      fi
      # escalation_kind: an approval of a budget stop means "continue", and
      # must never be taken as approval to merge a branch nobody built.
      jq -c --arg now "$now" --arg r "Paperclip monthly budget hard-stop (${b_spent}c/${b_limit}c)" --arg lcid "$b_lcid" \
        '.stage = "needs-human" | .decision = "ESCALATE" | .active_agent = "human" | .escalation_kind = "budget"
         | .last_seen_comment_id = (if $lcid == "" then (.last_seen_comment_id // null) else $lcid end)
         | .updated_at = $now | .merge_evaluation = {decision:"ESCALATE", reasons:[$r]}' \
        "$job_file" > "$job_file.tmp" && _afk_factory_commit_tmp "$job_file"
      [[ "$json_mode" == "true" ]] && cat "$job_file" || printf 'AFK Factory job %s (%s): budget hard_stop\n' "$job_id" "$slug"
      return 0
    fi
  fi

  local hired_json
  hired_json="$(afk_pch_ensure_project_team "$slug" "$abs_repo" "$harness" "pm,dev,reviewer,approver" "$issue_id" "$api_url" "$key" "$company_id" "$host_agent_id")"
  if declare -F afk_tooling_prepare_worktree >/dev/null 2>&1; then
    afk_tooling_prepare_worktree "$abs_repo" "$wt_dir" "$job_dir" "$slug"
  fi

  # Step 2: Intake (PM — John in BMAD) — skip if already completed on disk (resume-safe)
  local stage_rc=0
  if [[ ! -s "$job_dir/intake.md" ]]; then
    _afk_factory_announce "$slug" "pm" "$issue_id" "AFK Factory started intake with project PM (\`${slug}-pm\`)." "$api_url" "$key" "$run_id" || { _afk_factory_touch_heartbeat "$job_dir" "waiting" "" "done"; [[ "$json_mode" == "true" ]] && cat "$job_file"; return 0; }
    afk_factory_run_stage_with_context_guard "$slug" "$abs_repo" "$wt_dir" "$job_dir" "pm" "intake" "$job_dir/issue.md" "$job_dir/intake.md" "$issue_id" "$api_url" "$key" "" "$company_id" "$host_agent_id" "$project_id" "$run_id" || stage_rc=$?
    if (( stage_rc != 0 )) || [[ ! -s "$job_dir/intake.md" ]]; then
      rm -f "$job_dir/intake.md"
      _afk_factory_fail_job "Intake did not complete (${AFK_LAST_STAGE_FAILURE:-no output}), so the request was never assessed" "stage_failure"
      return 0
    fi
  fi

  # Read the intake as written by a model: bold markers, backticks, capitals
  # and a trailing full stop are all common. An intake that cannot be read
  # stops the job; it is not taken as "accept, low risk, code only".
  local intake_verdict risk surfaces_line
  intake_verdict="$(_afk_factory_strict_verdict "$job_dir/intake.md" 10)"
  risk="$(sed -n 's/^[[:space:]*`#>_-]*RISK:[[:space:]]*//p' "$job_dir/intake.md" 2>/dev/null | head -n 1 | tr '[:upper:]' '[:lower:]' | sed 's/^[^a-z]*\([a-z]*\).*/\1/')"
  surfaces_line="$(sed -n 's/^[[:space:]*`#>_-]*SURFACES:[[:space:]]*//p' "$job_dir/intake.md" 2>/dev/null | head -n 1 | tr '[:upper:]' '[:lower:]' | tr -d ' `*' | sed 's/[.;]*$//')"
  case "$intake_verdict" in
    ACCEPT|NEEDS-INFO|REJECT) ;;
    *)
      mv -f "$job_dir/intake.md" "$job_dir/intake.unreadable.md" 2>/dev/null || rm -f "$job_dir/intake.md"
      _afk_factory_fail_job "Intake gave no verdict the factory could read (expected ACCEPT, NEEDS-INFO or REJECT)" "stage_failure"
      return 0
      ;;
  esac
  # An unreadable risk is treated as high: the heavier path costs a review,
  # the lighter one skips it.
  [[ "$risk" =~ ^(low|medium|high|critical)$ ]] || risk="high"
  [[ -n "$surfaces_line" ]] || surfaces_line="code"
  jq -c --arg r "$risk" --arg s "$surfaces_line" \
    '.risk = $r | .surfaces = ($s | split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) | map(select(length > 0)))' \
    "$job_file" > "$job_file.tmp" && _afk_factory_commit_tmp "$job_file"

  if [[ "$intake_verdict" == "NEEDS-INFO" ]]; then
    local question last_cid=""
    question="$(cat "$job_dir/intake.md")"
    if [[ -n "$api_url" && -n "$key" && -n "$issue_id" ]]; then
      afk_pc_comment "$api_url" "$issue_id" "$key" "$run_id" "## Needs Clarification\n\n$question" >/dev/null 2>&1 || true
      last_cid="$(_afk_factory_latest_comment_id "$api_url" "$key" "$issue_id")"
      local pbody
      pbody="$(_afk_factory_in_review_body "$host_agent_id")"
      afk_pc_curl PATCH "$api_url/api/issues/$issue_id" "$key" "$run_id" "$pbody" >/dev/null 2>&1 || true
    fi
    jq -c --arg now "$now" --arg lcid "$last_cid" \
      '.stage = "needs-info" | .active_agent = "human" | .last_seen_comment_id = (if $lcid == "" then null else $lcid end) | .updated_at = $now' \
      "$job_file" > "$job_file.tmp" && _afk_factory_commit_tmp "$job_file"
    cat "$job_file"
    return 0
  elif [[ "$intake_verdict" == "REJECT" ]]; then
    # Tell the board why and hand the issue back; a rejection recorded only
    # on this host leaves the issue in progress under the factory for good.
    if [[ -n "$api_url" && -n "$key" && -n "$issue_id" ]]; then
      afk_pc_comment "$api_url" "$issue_id" "$key" "$run_id" \
        "$(printf '## AFK Factory — Request Declined at Intake\n\n%s' "$(cat "$job_dir/intake.md")")" >/dev/null 2>&1 || true
      afk_pc_curl PATCH "$api_url/api/issues/$issue_id" "$key" "$run_id" "$(_afk_factory_in_review_body "$host_agent_id")" >/dev/null 2>&1 || true
    fi
    jq -c --arg now "$now" '.stage = "rejected" | .active_agent = null | .updated_at = $now' "$job_file" > "$job_file.tmp" && _afk_factory_commit_tmp "$job_file"
    declare -F afk_tooling_cleanup_worktree >/dev/null 2>&1 && afk_tooling_cleanup_worktree "$abs_repo" "$wt_dir" "$job_dir"
    afk_pch_retire_project_agents "$slug" "all" "$api_url" "$key" >/dev/null
    cat "$job_file"
    return 0
  fi

  # Dynamically hire specialist project agents based on risk and surfaces
  local full_roles_csv
  full_roles_csv="$(afk_roster_roles_for_job "$risk" "$surfaces_line")"
  hired_json="$(afk_pch_ensure_project_team "$slug" "$abs_repo" "$harness" "$full_roles_csv" "$issue_id" "$api_url" "$key" "$company_id" "$host_agent_id")"
  if declare -F afk_tooling_prepare_worktree >/dev/null 2>&1; then
    afk_tooling_prepare_worktree "$abs_repo" "$wt_dir" "$job_dir" "$slug"
  fi

  # Step 3: Spec (PM or Architect when high/critical-risk or architecture) — skip if completed on disk
  local spec_role="pm"
  if [[ ",$surfaces_line," == *",architecture,"* || "$risk" == "high" || "$risk" == "critical" ]]; then
    spec_role="architect"
  fi
  if [[ ! -s "$job_dir/spec.md" ]]; then
    _afk_factory_announce "$slug" "$spec_role" "$issue_id" "" "$api_url" "$key" "$run_id" || { _afk_factory_touch_heartbeat "$job_dir" "waiting" "" "done"; [[ "$json_mode" == "true" ]] && cat "$job_file"; return 0; }
    stage_rc=0
    afk_factory_run_stage_with_context_guard "$slug" "$abs_repo" "$wt_dir" "$job_dir" "$spec_role" "spec" "$job_dir/issue.md" "$job_dir/spec.md" "$issue_id" "$api_url" "$key" "" "$company_id" "$host_agent_id" "$project_id" "$run_id" || stage_rc=$?
    if (( stage_rc != 0 )) || [[ ! -s "$job_dir/spec.md" ]]; then
      rm -f "$job_dir/spec.md"
      _afk_factory_fail_job "The specification stage did not complete (${AFK_LAST_STAGE_FAILURE:-no output}); nothing was built" "stage_failure"
      return 0
    fi
  fi
  if [[ -s "$job_dir/spec.md" && -n "$api_url" && -n "$key" && -n "$issue_id" ]]; then
    run_id="$(afk_pch_ensure_run_id "$api_url" "$key" "$host_agent_id" "$issue_id")"
    afk_pch_upsert_document "$api_url" "$(afk_pch_key_for_role "$slug" "$spec_role" "$key")" "$run_id" "$issue_id" "plan" "Engineering Specification ($job_id)" "$job_dir/spec.md" "Generated engineering specification via ${slug}-${spec_role}" >/dev/null 2>&1 || true
  fi

  # Optional UX Design pass when UI surface is flagged
  if [[ ",$surfaces_line," == *",ui,"* || ",$surfaces_line," == *",ux,"* ]] && [[ ! -s "$job_dir/ux-spec.md" ]]; then
    _afk_factory_announce "$slug" "ux-designer" "$issue_id" "" "$api_url" "$key" "$run_id" || { _afk_factory_touch_heartbeat "$job_dir" "waiting" "" "done"; [[ "$json_mode" == "true" ]] && cat "$job_file"; return 0; }
    stage_rc=0
    afk_factory_run_stage_with_context_guard "$slug" "$abs_repo" "$wt_dir" "$job_dir" "ux-designer" "ux" "$job_dir/spec.md" "$job_dir/ux-spec.md" "$issue_id" "$api_url" "$key" "" "$company_id" "$host_agent_id" "$project_id" "$run_id" || stage_rc=$?
    if (( stage_rc != 0 )) || [[ ! -s "$job_dir/ux-spec.md" ]]; then
      rm -f "$job_dir/ux-spec.md"
      _afk_factory_fail_job "The UX design stage did not complete (${AFK_LAST_STAGE_FAILURE:-no output}); nothing was built" "stage_failure"
      return 0
    fi
    if [[ -n "$api_url" && -n "$key" && -n "$issue_id" ]]; then
      run_id="$(afk_pch_ensure_run_id "$api_url" "$key" "$host_agent_id" "$issue_id")"
      afk_pch_upsert_document "$api_url" "$(afk_pch_key_for_role "$slug" "ux-designer" "$key")" "$run_id" "$issue_id" "ux-design" "UX Design Specification ($job_id)" "$job_dir/ux-spec.md" "Generated UX design specification via ${slug}-ux-designer" >/dev/null 2>&1 || true
    fi
  fi

  # Step 4: Build -> Deterministic Gate -> Multi-Lens Review loop (up to max_rounds)
  local cfg max_rounds max_rounds_ovr round=1 saved_round gate_passed=false reviews_passed=false
  cfg="$(afk_factory_load_config "$abs_repo")"
  max_rounds="$(jq -r '.max_rounds // 2' <<<"$cfg")"
  [[ "$max_rounds" =~ ^[0-9]+$ && "$max_rounds" -ge 1 ]] || max_rounds=2
  max_rounds_ovr="$(jq -r '.max_rounds_override // 0' "$job_file" 2>/dev/null || printf '0')"
  if [[ "$max_rounds_ovr" =~ ^[0-9]+$ ]] && (( max_rounds_ovr > max_rounds )); then
    max_rounds="$max_rounds_ovr"
  fi
  saved_round="$(jq -r '.round // 1' "$job_file" 2>/dev/null || printf '1')"
  if [[ "$saved_round" =~ ^[0-9]+$ ]] && (( saved_round > 1 )); then
    round="$saved_round"
  fi

  while (( round <= max_rounds )); do
    local round_dir="$job_dir/round-$round"
    mkdir -p "$round_dir"
    # A job stopped only because Paperclip refused the review announcement
    # resumes at the review, when the checks passed on the commit still at
    # the head. Rebuilding would throw away a checked build.
    local skip_to_review=false
    if [[ "$(jq -r '.resume_at // empty' "$job_file" 2>/dev/null)" == "review" ]] \
       && [[ "$(jq -r '.round // 0 | tostring' "$job_file" 2>/dev/null)" == "$round" ]] \
       && head -n 5 "$round_dir/checks.md" 2>/dev/null | grep -q '^VERDICT: PASS' \
       && [[ -n "$(cat "$round_dir/checks.sha" 2>/dev/null)" ]] \
       && [[ "$(cat "$round_dir/checks.sha" 2>/dev/null)" == "$(git -C "$wt_dir" rev-parse HEAD 2>/dev/null)" ]]; then
      skip_to_review=true
      # No agent has run since these checks; their record is taken now, before
      # the reviewers start, so a reviewer that rewrites it is undone.
      AFK_LAST_GATED_HEAD="$(head -n 1 "$round_dir/checks.sha" 2>/dev/null | tr -d '[:space:]')"
      AFK_LAST_GATED_ROUND_DIR="$round_dir"
    fi
    if [[ "$skip_to_review" != true ]]; then
      jq -c --argjson r "$round" '.stage = "build" | .round = $r | .active_agent = "dev"' "$job_file" > "$job_file.tmp" && _afk_factory_commit_tmp "$job_file"
      _afk_factory_announce "$slug" "dev" "$issue_id" "AFK Factory build round ${round} started with \`${slug}-dev\`." "$api_url" "$key" "$run_id" || { _afk_factory_touch_heartbeat "$job_dir" "waiting" "" "done"; [[ "$json_mode" == "true" ]] && cat "$job_file"; return 0; }

      # The reviews this round must produce, written before any of them runs.
      # The approver checks each one; a review that never finished is a missing
      # verdict, not a review that can be left out.
      {
        printf 'review-code\n'
        [[ ",$surfaces_line," == *",security,"* ]] && printf 'review-security\n'
        [[ ",$surfaces_line," == *",ui,"* || ",$surfaces_line," == *",ux,"* ]] && printf 'review-ux\n'
        [[ ",$surfaces_line," == *",architecture,"* || "$risk" == "high" || "$risk" == "critical" ]] && printf 'review-arch\n'
      } > "$round_dir/expected-reviews"

      stage_rc=0
      afk_factory_run_stage_with_context_guard "$slug" "$abs_repo" "$wt_dir" "$job_dir" "dev" "build" "$job_dir/spec.md" "$job_dir/build.md" "$issue_id" "$api_url" "$key" "" "$company_id" "$host_agent_id" "$project_id" "$run_id" || stage_rc=$?
      if (( stage_rc != 0 )); then
        # The person's instructions stay on disk for the retry.
        _afk_factory_fail_job "The build did not complete in round ${round} (${AFK_LAST_STAGE_FAILURE:-no output}). Any partial work is on branch $branch and was not checked or reviewed" "stage_failure"
        return 0
      fi
      rm -f "$job_dir/human-feedback.md"
      declare -F afk_tooling_unstage_ephemeral >/dev/null 2>&1 && afk_tooling_unstage_ephemeral "$wt_dir" "$job_dir"
      if [[ "$wt_dir" != "$abs_repo" ]] && [[ -n "$(git -C "$wt_dir" status --porcelain 2>/dev/null || true)" ]]; then
        git -C "$wt_dir" add -A -- . ':!.afk' >/dev/null 2>&1 || git -C "$wt_dir" add -A >/dev/null 2>&1 || true
        declare -F afk_tooling_unstage_ephemeral >/dev/null 2>&1 && afk_tooling_unstage_ephemeral "$wt_dir" "$job_dir"
        local commit_err=""
        commit_err="$(git -C "$wt_dir" commit -m "feat($job_id): $title" 2>&1 >/dev/null)" || true
        # A refused commit (a hook, no git identity) leaves the work in the
        # tree only. Checks and reviews would pass on it, the branch would
        # show no change, and the job would end "merged" with the work deleted.
        if [[ -n "$(git -C "$wt_dir" status --porcelain -- . ':!.afk' 2>/dev/null || true)" ]]; then
          _afk_factory_fail_job "The build could not be committed in round ${round} ($(printf '%s' "${commit_err:-git commit failed}" | head -n 1 | cut -c1-200)). The work is uncommitted in $wt_dir" "stage_failure"
          return 0
        fi
      fi

      # Deterministic Gate (.afk/checks.sh)
      jq -c '.stage = "gate"' "$job_file" > "$job_file.tmp" && _afk_factory_commit_tmp "$job_file"
      _afk_factory_touch_heartbeat "$job_dir" "gate" "" "running"
      _afk_factory_beat_start "$job_dir" "gate" ""
      local gate_rc=0
      afk_factory_run_gate "$abs_repo" "$wt_dir" "$round_dir" || gate_rc=$?
      _afk_factory_beat_stop
      if (( gate_rc != 0 )); then
        gate_passed=false
        _afk_factory_write_review_report "$job_dir" "$round"
        if [[ -n "$api_url" && -n "$key" && -n "$issue_id" ]]; then
          afk_pch_upsert_document "$api_url" "$(afk_pch_key_for_role "$slug" "reviewer" "$key")" "$run_id" "$issue_id" "review-report" "Gate & Review Report (Round $round)" "$job_dir/review-report.md" "Round $round deterministic gate failed" >/dev/null 2>&1 || true
        fi
        round=$((round + 1))
        continue
      fi
    fi
    gate_passed=true

    # Independent Review Stage
    jq -c --argjson r "$round" '.stage = "review" | .round = $r | .active_agent = "reviewer" | .resume_at = "review"' "$job_file" > "$job_file.tmp" && _afk_factory_commit_tmp "$job_file"
    _afk_factory_announce "$slug" "reviewer" "$issue_id" "AFK Factory independent review started with \`${slug}-reviewer\`." "$api_url" "$key" "$run_id" || { _afk_factory_touch_heartbeat "$job_dir" "waiting" "" "done"; [[ "$json_mode" == "true" ]] && cat "$job_file"; return 0; }
    jq -c 'del(.resume_at)' "$job_file" > "$job_file.tmp" && _afk_factory_commit_tmp "$job_file"
    afk_factory_run_stage_with_context_guard "$slug" "$abs_repo" "$wt_dir" "$job_dir" "reviewer" "review-code" "$job_dir/build.md" "$round_dir/review-code.md" "$issue_id" "$api_url" "$key" "" "$company_id" "$host_agent_id" "$project_id" "$run_id" || true

    if [[ ",$surfaces_line," == *",security,"* ]]; then
      afk_factory_run_stage_with_context_guard "$slug" "$abs_repo" "$wt_dir" "$job_dir" "reviewer" "review-security" "$job_dir/build.md" "$round_dir/review-security.md" "$issue_id" "$api_url" "$key" "" "$company_id" "$host_agent_id" "$project_id" "$run_id" || true
    fi
    if [[ ",$surfaces_line," == *",ui,"* || ",$surfaces_line," == *",ux,"* ]]; then
      afk_factory_run_stage_with_context_guard "$slug" "$abs_repo" "$wt_dir" "$job_dir" "ux-designer" "review-ux" "$job_dir/build.md" "$round_dir/review-ux.md" "$issue_id" "$api_url" "$key" "" "$company_id" "$host_agent_id" "$project_id" "$run_id" || true
    fi
    if [[ ",$surfaces_line," == *",architecture,"* || "$risk" == "high" || "$risk" == "critical" ]]; then
      afk_factory_run_stage_with_context_guard "$slug" "$abs_repo" "$wt_dir" "$job_dir" "architect" "review-arch" "$job_dir/build.md" "$round_dir/review-arch.md" "$issue_id" "$api_url" "$key" "" "$company_id" "$host_agent_id" "$project_id" "$run_id" || true
    fi

    _afk_factory_write_review_report "$job_dir" "$round"
    if [[ -n "$api_url" && -n "$key" && -n "$issue_id" ]]; then
      run_id="$(afk_pch_ensure_run_id "$api_url" "$key" "$host_agent_id" "$issue_id")"
      afk_pch_upsert_document "$api_url" "$(afk_pch_key_for_role "$slug" "reviewer" "$key")" "$run_id" "$issue_id" "review-report" "Gate & Review Report (Round $round)" "$job_dir/review-report.md" "Round $round gate & independent review report" >/dev/null 2>&1 || true
    fi

    # Check every review the round required.
    local any_changes=false review_missing=false lens r_verdict
    while IFS= read -r lens; do
      [[ -n "$lens" ]] || continue
      if [[ ! -s "$round_dir/$lens.md" ]]; then
        review_missing=true
        continue
      fi
      r_verdict="$(_afk_factory_strict_verdict "$round_dir/$lens.md")"
      if [[ "$r_verdict" != "PASS" ]]; then
        any_changes=true
      fi
    done < "$round_dir/expected-reviews"

    # A reviewer that produced nothing is not asking for changes. Building
    # again would not help; stop and let the approver report what is missing.
    if [[ "$review_missing" == "true" ]]; then
      reviews_passed=false
      break
    fi
    if [[ "$any_changes" == "false" ]]; then
      reviews_passed=true
      break
    fi
    reviews_passed=false
    round=$((round + 1))
  done
  # A loop that used up its rounds leaves `round` one past the last round run;
  # the approver must judge the last round that exists.
  if (( round > max_rounds )); then
    round="$max_rounds"
  fi
  jq -c --argjson r "$round" '.round = $r' "$job_file" > "$job_file.tmp" && _afk_factory_commit_tmp "$job_file"

  # Retire specialist on-demand agents now that spec/ux/review completed
  afk_pch_retire_project_agents "$slug" "analyst,architect,ux-designer" "$api_url" "$key" >/dev/null 2>&1 || true

  # Step 5: Situational Merge Approver & Real Git Branch Landing
  jq -c '.stage = "approve" | .active_agent = "approver"' "$job_file" > "$job_file.tmp" && _afk_factory_commit_tmp "$job_file"
  local merge_eval decision final_stage merged_commit="" pending_inter_id="" last_cid="" branch_head=""
  branch_head="$(git -C "$wt_dir" rev-parse HEAD 2>/dev/null || git -C "$abs_repo" rev-parse HEAD 2>/dev/null || true)"
  # The checked commit as this runner saw it, not as an agent may have
  # rewritten it in the job directory since.
  if [[ -n "${AFK_LAST_GATED_HEAD:-}" && "${AFK_LAST_GATED_ROUND_DIR:-}" == "$job_dir/round-$round" ]]; then
    printf '%s\n' "$AFK_LAST_GATED_HEAD" > "$job_dir/round-$round/checks.sha" 2>/dev/null || true
  fi
  merge_eval="$(afk_factory_evaluate_merge "$abs_repo" "$job_dir" "$wt_dir")"
  decision="$(jq -r '.decision // empty' <<<"$merge_eval" 2>/dev/null || true)"
  [[ "$decision" == "APPROVE" || "$decision" == "ESCALATE" ]] || decision="ESCALATE"

  if [[ "$decision" == "APPROVE" ]]; then
    local land_res land_ok land_reason
    # Waiting for pull request checks can take longer than the stall
    # threshold; keep the heartbeat fresh so the watchdog leaves it alone.
    _afk_factory_touch_heartbeat "$job_dir" "landing" "" "running"
    _afk_factory_beat_start "$job_dir" "landing" ""
    land_res="$(_afk_factory_land_branch "$abs_repo" "$wt_dir" "$branch" "$job_id" "$title")" || true
    _afk_factory_beat_stop
    land_ok="$(jq -r '.ok // false' <<<"$land_res" 2>/dev/null || printf 'false')"
    if [[ "$land_ok" == "true" ]]; then
      merged_commit="$(jq -r '.commit // empty' <<<"$land_res" 2>/dev/null || printf '%s' "$branch_head")"
      final_stage="merged"
      # Record the merge before anything else. The Paperclip calls below take
      # time and can fail; a restart in that window used to find the job
      # still "approve", rebuild it and merge a second time.
      jq -c --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sha "$merged_commit" \
        '.stage = "merged" | .decision = "APPROVE" | .active_agent = null | .updated_at = $now
         | .merged_commit = (if $sha == "" then (.merged_commit // null) else $sha end)' \
        "$job_file" > "$job_file.tmp" && _afk_factory_commit_tmp "$job_file"
      if [[ -n "$merged_commit" ]]; then
        printf '\n- Landed commit: `%s` (branch `%s`)\n' "$merged_commit" "$branch" >> "$job_dir/decision.md"
      fi
      if [[ -n "$api_url" && -n "$key" && -n "$issue_id" ]]; then
        run_id="$(afk_pch_ensure_run_id "$api_url" "$key" "$host_agent_id" "$issue_id")"
        _afk_factory_clear_execution_policy "$api_url" "$key" "$run_id" "$issue_id"
        afk_pc_curl PATCH "$api_url/api/issues/$issue_id" "$key" "$run_id" '{"status":"in_progress"}' >/dev/null 2>&1 || true
        afk_pch_upsert_document "$api_url" "$(afk_pch_key_for_role "$slug" "dev" "$key")" "$run_id" "$issue_id" "merge-decision" "Situational Merge Decision ($job_id)" "$job_dir/decision.md" "Auto-approved and merged commit ${merged_commit:0:8}" >/dev/null 2>&1 || true
        if [[ -n "$merged_commit" ]]; then
          afk_pch_register_commit_work_product "$api_url" "$key" "$run_id" "$issue_id" "$project_id" "$merged_commit" "$branch" "feat($job_id): $title" "Autonomous AFK Factory merge ($slug)" "merged" "approved" >/dev/null 2>&1 || true
        fi
        afk_pc_comment "$api_url" "$issue_id" "$key" "$run_id" \
          "$(printf '## AFK Factory — Auto-Approved & Merged\n\n%s' "$(cat "$job_dir/decision.md")")" >/dev/null 2>&1 || true
        afk_pch_finish_issue "$slug" "dev" "$issue_id" "$api_url" "$key" "$run_id" >/dev/null 2>&1 || true
      fi
      # Job finished cleanly; retire all project agents in Paperclip
      afk_pch_retire_project_agents "$slug" "all" "$api_url" "$key" >/dev/null 2>&1 || true
    else
      land_reason="$(jq -r '.reason // "Git branch merge failed"' <<<"$land_res" 2>/dev/null || printf 'Git branch merge failed')"
      decision="ESCALATE"
      merge_eval="$(jq -c --arg r "$land_reason" '.decision = "ESCALATE" | .reasons = ((.reasons // []) + [$r])' <<<"$merge_eval")"
      printf '\n## Merge Blocked\n- %s\n' "$land_reason" >> "$job_dir/decision.md"
    fi
  fi

  if [[ "$decision" != "APPROVE" ]]; then
    final_stage="needs-human"
    local open_url=""
    open_url="$(_afk_factory_ensure_pr "$abs_repo" "$wt_dir" "$branch" "$title" "$job_id" 2>/dev/null || true)"
    if [[ -n "$open_url" ]]; then
      printf '\n- Pull request: %s\n' "$open_url" >> "$job_dir/decision.md"
    fi
    if [[ -n "$api_url" && -n "$key" && -n "$issue_id" ]]; then
      run_id="$(afk_pch_ensure_run_id "$api_url" "$key" "$host_agent_id" "$issue_id")"
      afk_pc_curl PATCH "$api_url/api/issues/$issue_id" "$key" "$run_id" '{"status":"in_progress"}' >/dev/null 2>&1 || true
      local dec_doc_json="" inter_json=""
      dec_doc_json="$(afk_pch_upsert_document "$api_url" "$(afk_pch_key_for_role "$slug" "approver" "$key")" "$run_id" "$issue_id" "merge-decision" "Situational Merge Escalation ($job_id)" "$job_dir/decision.md" "Escalated to board for review (round $round)" 2>/dev/null || true)"
      if [[ -n "$branch_head" ]]; then
        afk_pch_register_commit_work_product "$api_url" "$key" "$run_id" "$issue_id" "$project_id" "$branch_head" "$branch" "feat($job_id): $title" "Awaiting human board review on branch $branch" "ready_for_review" "needs_board_review" >/dev/null 2>&1 || true
      fi
      afk_pc_comment "$api_url" "$issue_id" "$key" "$run_id" \
        "$(printf '## AFK Factory — Human Approval Requested\n\n%s' "$(cat "$job_dir/decision.md")")" >/dev/null 2>&1 || true
      last_cid="$(_afk_factory_latest_comment_id "$api_url" "$key" "$issue_id")"
      inter_json="$(afk_pch_request_confirmation "$api_url" "$key" "$run_id" "$issue_id" "$board_user_id" \
        "afk-confirm:${issue_id}:r${round}:${branch_head:0:12}" \
        "Approve AFK Factory Merge ($job_id)" \
        "Branch \`$branch\` requires human board review before landing." \
        "Approve and merge branch \`$branch\` into \`$slug\`, or request revisions?" \
        "$(cat "$job_dir/decision.md")" \
        "$dec_doc_json" 2>/dev/null || true)"
      if [[ -n "$inter_json" ]]; then
        pending_inter_id="$(jq -r '.id // empty' <<<"$inter_json" 2>/dev/null || true)"
      fi
      local pbody
      pbody="$(_afk_factory_in_review_body "$host_agent_id")"
      afk_pc_curl PATCH "$api_url/api/issues/$issue_id" "$key" "$run_id" "$pbody" >/dev/null 2>&1 || true
      _afk_factory_set_approval_gate "$api_url" "$key" "$run_id" "$issue_id" "$host_agent_id" "$board_user_id"
    fi
  fi

  local surfaces_arr
  surfaces_arr="$(printf '%s' "$surfaces_line" | jq -Rc 'split(",")' 2>/dev/null || printf '["code"]')"
  # One empty argument would fail the whole write and leave the job looking
  # unfinished, to be picked up and run again.
  jq -e 'type == "array"' <<<"$surfaces_arr" >/dev/null 2>&1 || surfaces_arr='["code"]'
  jq -e 'type == "array"' <<<"$hired_json" >/dev/null 2>&1 || hired_json='[]'
  jq -e 'type == "object"' <<<"$merge_eval" >/dev/null 2>&1 \
    || merge_eval='{"decision":"ESCALATE","reasons":["The merge evaluation could not be read"]}'
  if [[ "$final_stage" != "merged" && "$(jq -r '.decision // empty' <<<"$merge_eval")" == "APPROVE" ]]; then
    decision="ESCALATE"
  fi
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -c \
    --arg st "$final_stage" \
    --arg r "$risk" \
    --arg dec "$decision" \
    --arg msha "$merged_commit" \
    --arg piid "$pending_inter_id" \
    --arg lcid "$last_cid" \
    --arg now "$now" \
    --argjson surf "$surfaces_arr" \
    --argjson hired "$hired_json" \
    --argjson meval "$merge_eval" \
    '.stage = $st
     | .risk = $r
     | .surfaces = $surf
     | .hired_roles = ($hired | map(.role))
     | .decision = $dec
     | .merged_commit = (if $msha == "" then (.merged_commit // null) else $msha end)
     | .pending_interaction_id = (if $piid == "" then null else $piid end)
     | .last_seen_comment_id = (if $lcid == "" then (.last_seen_comment_id // null) else $lcid end)
     | .merge_evaluation = $meval
     | .escalation_kind = (if $st == "needs-human" then "merge" else null end)
     | .active_agent = (if $st == "needs-human" then "human" else null end)
     | .updated_at = $now' "$job_file" > "$job_file.tmp" && _afk_factory_commit_tmp "$job_file"
  if [[ "$final_stage" == "merged" ]] && declare -F afk_tooling_cleanup_worktree >/dev/null 2>&1; then
    afk_tooling_cleanup_worktree "$abs_repo" "$wt_dir" "$job_dir"
  fi
  _afk_factory_touch_heartbeat "$job_dir" "$final_stage" "" "done"

  if [[ "$json_mode" == "true" ]]; then
    cat "$job_file"
  else
    printf 'AFK Factory job %s (%s): stage=%s decision=%s\n' "$job_id" "$slug" "$final_stage" "$decision"
  fi
  return 0
}

# afk_factory_watchdog [<repo_path>] [<slug>] [<stale_seconds>] [<dry_run>] [<json_mode>]
# Deterministic stall detector & auto-nudge/recovery loop:
#   - Inspects in-flight jobs (`stage` not in `merged|needs-human|needs-info|rejected`).
#   - Detects crashed coordinators (`dead_runner` when PID no longer exists) and
#     silent/hung stages (`stalled_stage` when `now - last_beat_epoch >= stale_seconds`).
#   - Terminates hung PIDs, injects a Watchdog Recovery Nudge into the stage prompt,
#     and re-dispatches from the last completed stage artifact (up to `max_nudges`, default 2).
#   - Escalates to Paperclip (`in_review` assigned to human board user) if `nudge_count > max_nudges`.
afk_factory_watchdog() {
  local repo="${1:-}" slug="${2:-}" stale_arg="${3:-}" dry_run="${4:-false}" json_mode="${5:-false}"
  local status_json
  status_json="$(afk_factory_status "$repo" "$slug" true enabled)"
  local -a in_flight=()
  mapfile -t in_flight < <(jq -c '.jobs[]? | select((.stage // "") | IN("merged","needs-human","needs-info","needs-consultation","consulted","rejected") | not)' <<<"$status_json" 2>/dev/null)

  local actions="[]" now_ep row j_repo j_slug j_id j_issue j_title j_stage j_dir hb_file cfg stale_sec max_nudges
  now_ep="$(date -u +%s)"

  for row in "${in_flight[@]:-}"; do
    [[ -n "$row" ]] || continue
    j_repo="$(jq -r '.repo_path // empty' <<<"$row")"
    j_slug="$(jq -r '.slug // empty' <<<"$row")"
    j_id="$(jq -r '.id // empty' <<<"$row")"
    j_issue="$(jq -r '.issue_id // empty' <<<"$row")"
    j_title="$(jq -r '.title // "Factory Task"' <<<"$row")"
    j_stage="$(jq -r '.stage // "unknown"' <<<"$row")"
    [[ -n "$j_repo" && -n "$j_id" ]] || continue
    j_dir="$j_repo/.afk/jobs/$j_id"
    hb_file="$j_dir/heartbeat.json"

    cfg="$(afk_factory_load_config "$j_repo")"
    stale_sec="${stale_arg:-${AFK_WATCHDOG_STALE_SEC:-$(jq -r '.watchdog.stale_seconds // 900' <<<"$cfg" 2>/dev/null || printf '900')}}"
    max_nudges="${AFK_WATCHDOG_MAX_NUDGES:-$(jq -r '.watchdog.max_nudges // 2' <<<"$cfg" 2>/dev/null || printf '2')}"
    [[ "$stale_sec" =~ ^[0-9]+$ ]] || stale_sec=900
    [[ "$max_nudges" =~ ^[0-9]+$ ]] || max_nudges=2

    local hb="{}" pid="" beat_ep=0 nudges=0 age=0 stall_reason=""
    if [[ -f "$hb_file" ]]; then
      hb="$(cat -- "$hb_file" 2>/dev/null || printf '{}')"
      jq -e 'type == "object"' <<<"$hb" >/dev/null 2>&1 || hb="{}"
      pid="$(jq -r '.pid // empty' <<<"$hb" 2>/dev/null)"
      beat_ep="$(jq -r '.last_beat_epoch // 0' <<<"$hb" 2>/dev/null || printf '0')"
      nudges="$(jq -r '.nudge_count // 0' <<<"$hb" 2>/dev/null || printf '0')"
    fi
    [[ "$nudges" =~ ^[0-9]+$ ]] || nudges=0
    if [[ ! "$beat_ep" =~ ^[0-9]+$ || "$beat_ep" -eq 0 ]]; then
      # No heartbeat yet: age the job from its record.
      beat_ep="$(stat -c %Y "$j_dir/job.json" 2>/dev/null || stat -f %m "$j_dir/job.json" 2>/dev/null || printf '%s' "$now_ep")"
    fi
    age=$(( now_ep - beat_ep ))

    # Who is running the job, if anyone. The run lock names the runner by PID,
    # start time and boot, so a PID reused after a restart does not pass for
    # it. A job from before the lock existed is judged by its heartbeat, which
    # carries the same fields.
    local runner_alive=false runner_pid="" grace=120 seen_token=""
    seen_token="$(jq -r '.token // empty' "$j_dir/.run.lock/owner.json" 2>/dev/null || true)"
    if [[ -d "$j_dir/.run.lock" ]]; then
      if _afk_factory_runner_alive "$j_dir/.run.lock/owner.json" "$stale_sec"; then
        runner_alive=true
        runner_pid="$(jq -r '.pid // empty' "$j_dir/.run.lock/owner.json" 2>/dev/null || true)"
      fi
    elif [[ -n "$pid" && "$pid" != "null" ]] && _afk_factory_runner_alive "$hb_file" "$stale_sec"; then
      runner_alive=true
      runner_pid="$pid"
    fi

    # A job waiting for Paperclip to accept its stage change has no runner on
    # purpose. It is retried on the next pass and is not a stall.
    local j_blocked
    j_blocked="$(jq -r '.blocked_reason // empty' "$j_dir/job.json" 2>/dev/null || true)"

    # A runner on another host that counts as alive has, by that test, shown
    # a sign of life within the threshold. Judging it again by the heartbeat
    # alone would take over a lock it took a moment ago.
    local runner_foreign=false o_host
    o_host="$(jq -r '.host // empty' "$j_dir/.run.lock/owner.json" 2>/dev/null || true)"
    [[ -n "$o_host" && "$o_host" != "$(_afk_factory_host_id)" ]] && runner_foreign=true
    if [[ "$runner_alive" == true ]]; then
      if [[ "$runner_foreign" != true ]] && (( age >= stale_sec )); then
        stall_reason="stalled_stage (stage=$j_stage silent for ${age}s >= ${stale_sec}s, pid=${runner_pid:-unknown})"
      fi
    elif [[ "$j_blocked" == "paperclip_unreachable" ]]; then
      if [[ "$dry_run" == "true" ]]; then
        actions="$(jq -c --arg s "$j_slug" --arg id "$j_id" --arg st "$j_stage" \
          '. + [{slug:$s, job_id:$id, stage:$st, action:"would_retry_paperclip_wait"}]' <<<"$actions")"
      elif (( age >= grace )); then
        local w_out
        w_out="$(afk_factory_run_job "$j_repo" "$j_slug" "$j_id" "$j_issue" "$j_title" "" true)"
        actions="$(jq -c --arg s "$j_slug" --arg id "$j_id" --arg st "$(jq -r '.stage // "unknown"' <<<"$w_out" 2>/dev/null)" \
          '. + [{slug:$s, job_id:$id, stage:$st, action:"retried_paperclip_wait"}]' <<<"$actions")"
      else
        actions="$(jq -c --arg s "$j_slug" --arg id "$j_id" --arg st "$j_stage" \
          '. + [{slug:$s, job_id:$id, stage:$st, action:"waiting_on_paperclip"}]' <<<"$actions")"
      fi
      continue
    elif [[ -d "$j_dir/.run.lock" ]]; then
      stall_reason="dead_runner (the runner of stage=$j_stage is gone)"
    elif (( age >= grace )); then
      # No lock at all: a runner that has not taken it yet, or one that died
      # before this version. Two poll intervals settle which.
      stall_reason="dead_runner (no runner for stage=$j_stage after ${age}s)"
    fi

    if [[ -z "$stall_reason" ]]; then
      actions="$(jq -c --arg s "$j_slug" --arg id "$j_id" --arg st "$j_stage" --argjson a "$age" \
        '. + [{slug:$s, job_id:$id, stage:$st, action:"healthy_running", age_sec:$a}]' <<<"$actions")"
      continue
    fi

    if [[ "$dry_run" == "true" ]]; then
      actions="$(jq -c --arg s "$j_slug" --arg id "$j_id" --arg st "$j_stage" --arg r "$stall_reason" --argjson nc "$nudges" \
        '. + [{slug:$s, job_id:$id, stage:$st, action:"would_recover", reason:$r, nudge_count:$nc}]' <<<"$actions")"
      continue
    fi

    # End a hung runner and everything it started before another takes over,
    # but only a process that provably is that runner. A runner on another
    # host, or one recorded without a start time, is not signalled; its lock
    # is taken over once the heartbeat has gone stale.
    if [[ "$runner_alive" == true ]]; then
      if [[ -d "$j_dir/.run.lock" ]] && _afk_factory_runner_killable "$j_dir/.run.lock/owner.json"; then
        _afk_factory_kill_tree "$runner_pid"
      elif [[ ! -d "$j_dir/.run.lock" ]] && _afk_factory_runner_killable "$hb_file"; then
        _afk_factory_kill_tree "$runner_pid"
      fi
    fi
    # Take over only the lock that was judged above, and only one watchdog at
    # a time: another one may have replaced it with a live lock since.
    if [[ -d "$j_dir/.run.lock" ]]; then
      # A reap directory left by a watchdog that was killed mid-takeover is
      # cleared once it is 30 seconds old.
      if [[ -d "$j_dir/.run.lock.reap" ]]; then
        local rpm
        rpm="$(stat -c %Y "$j_dir/.run.lock.reap" 2>/dev/null || stat -f %m "$j_dir/.run.lock.reap" 2>/dev/null || printf '%s' "$now_ep")"
        [[ "$rpm" =~ ^[0-9]+$ ]] && (( now_ep - rpm > 30 )) && rmdir "$j_dir/.run.lock.reap" 2>/dev/null
      fi
      mkdir "$j_dir/.run.lock.reap" 2>/dev/null || continue
      if [[ "$(jq -r '.token // empty' "$j_dir/.run.lock/owner.json" 2>/dev/null || true)" != "$seen_token" ]] \
         || ! _afk_factory_lock_steal "$j_dir/.run.lock"; then
        rmdir "$j_dir/.run.lock.reap" 2>/dev/null
        continue
      fi
      rmdir "$j_dir/.run.lock.reap" 2>/dev/null
    fi
    # The runner that held the job is gone. A heartbeat write it or its beat
    # loop was stopped in the middle of left a temp file; clear them. A write
    # still in flight only loses its rename.
    rm -f -- "$j_dir"/heartbeat.json.tmp.* 2>/dev/null || true

    # The recovery count lives in the job record, keyed by the stage that
    # stalled. A rerun moves through earlier stages first, so a count kept
    # with the heartbeat was cleared before the same stage could stall again,
    # and a job that kept dying was rebuilt for ever.
    # Keyed by stage and round: stalls in three different build rounds are
    # three single stalls, not one stage failing three times.
    local rec_stage rec_round rec_count j_round
    rec_stage="$(jq -r '.recovery.stage // empty' "$j_dir/job.json" 2>/dev/null || true)"
    rec_round="$(jq -r '.recovery.round // empty | tostring' "$j_dir/job.json" 2>/dev/null || true)"
    rec_count="$(jq -r '.recovery.count // 0' "$j_dir/job.json" 2>/dev/null || printf '0')"
    j_round="$(jq -r '.round // 1 | tostring' "$j_dir/job.json" 2>/dev/null || printf '1')"
    [[ "$rec_count" =~ ^[0-9]+$ ]] || rec_count=0
    if [[ "$rec_stage" == "$j_stage" && "$rec_round" == "$j_round" ]]; then
      nudges=$(( rec_count + 1 ))
    elif ! jq -e 'has("recovery")' "$j_dir/job.json" >/dev/null 2>&1 \
         && [[ "$(jq -r '.stage // empty' <<<"$hb" 2>/dev/null)" == "$j_stage" ]]; then
      # A job from before the count moved to the job record carries it in
      # its heartbeat; an upgrade must not reset a job that is mid-recovery.
      # A job the board told to retry has `.recovery: null` and starts over.
      nudges=$(( nudges + 1 ))
    else
      nudges=1
    fi
    jq -c --arg st "$j_stage" --argjson nc "$nudges" --argjson rd "${j_round:-1}" '.recovery = {stage: $st, round: $rd, count: $nc}' \
      "$j_dir/job.json" > "$j_dir/job.json.tmp" && _afk_factory_commit_tmp "$j_dir/job.json"
    local now_iso hb_tmp
    now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    hb_tmp="$(mktemp "${hb_file}.tmp.XXXXXX" 2>/dev/null || true)"
    if [[ -n "$hb_tmp" ]]; then
      jq -cn \
        --arg st "$j_stage" \
        --arg iso "$now_iso" \
        --argjson ep "$now_ep" \
        --argjson nc "$nudges" \
        '{schema:"afk-factory-heartbeat/1", pid:null, state:"recovering", stage:$st, role:"", last_beat_at:$iso, last_beat_epoch:$ep, nudge_count:$nc}' > "$hb_tmp" \
        && mv -f -- "$hb_tmp" "$hb_file" || rm -f -- "$hb_tmp"
    fi

    if (( nudges > max_nudges )); then
      cat > "$j_dir/decision.md" <<EOF
DECISION: ESCALATE

## Summary
- Watchdog detected repeated stall/interruption on job \`$j_id\` (\`$stall_reason\`).
- Exceeded \`max_nudges=$max_nudges\` (${nudges} attempts); escalating for human inspection.
EOF
      # escalation_kind "stall": approving this card means "try again". It
      # must not merge a branch that never finished its checks or reviews.
      jq -c --arg now "$now_iso" --arg r "Watchdog stall cap exceeded ($nudges/$max_nudges): $stall_reason" \
        '.stage = "needs-human" | .decision = "ESCALATE" | .active_agent = "human" | .escalation_kind = "stall"
         | .pending_interaction_id = null | .updated_at = $now | .merge_evaluation = {decision:"ESCALATE", reasons:[$r]}' \
        "$j_dir/job.json" > "$j_dir/job.json.tmp" && _afk_factory_commit_tmp "$j_dir/job.json"

      # Notify Paperclip if linked to an issue
      local pc_cfg_path pc_cfg api_url host_agent_id board_user_id key_ref key="" run_id=""
      pc_cfg_path="$(afk_pc_config_path)"
      if [[ -n "$j_issue" && -f "$pc_cfg_path" ]]; then
        pc_cfg="$(cat "$pc_cfg_path" 2>/dev/null || true)"
        api_url="$(jq -r '.api_url // empty' <<<"$pc_cfg" 2>/dev/null)"
        host_agent_id="$(jq -r '.host.agent_id // empty' <<<"$pc_cfg" 2>/dev/null)"
        board_user_id="$(jq -r '.board_user_id // empty' <<<"$pc_cfg" 2>/dev/null)"
        key_ref="$(jq -r '.host.key_ref // empty' <<<"$pc_cfg" 2>/dev/null)"
        if [[ -n "$api_url" && -n "$key_ref" ]]; then
          AFK_PC_CFG="$pc_cfg"
          key="$(afk_pc_read_key "$key_ref" 2>/dev/null || true)"
          if [[ -n "$key" ]]; then
            run_id="$(afk_pch_ensure_run_id "$api_url" "$key" "$host_agent_id" "$j_issue")"
            afk_pc_comment "$api_url" "$j_issue" "$key" "$run_id" "$(cat "$j_dir/decision.md")" >/dev/null 2>&1 || true
            local wd_lcid wd_inter wd_piid=""
            wd_lcid="$(_afk_factory_latest_comment_id "$api_url" "$key" "$j_issue")"
            wd_inter="$(afk_pch_request_confirmation "$api_url" "$key" "$run_id" "$j_issue" "$board_user_id" \
              "afk-confirm:${j_issue}:watchdog:${now_ep}" \
              "Resume AFK Factory job ($j_id)?" \
              "The job \`$j_id\` stalled repeatedly and was stopped." \
              "Accept to let the factory try again, or reject with instructions." \
              "$(cat "$j_dir/decision.md")" \
              "" 2>/dev/null || true)"
            [[ -n "$wd_inter" ]] && wd_piid="$(jq -r '.id // empty' <<<"$wd_inter" 2>/dev/null || true)"
            # Mark what has been seen, so the next sync does not take an old
            # comment for a new instruction.
            jq -c --arg lcid "$wd_lcid" --arg piid "$wd_piid" \
              '.last_seen_comment_id = (if $lcid == "" then (.last_seen_comment_id // null) else $lcid end)
               | .pending_interaction_id = (if $piid == "" then null else $piid end)' \
              "$j_dir/job.json" > "$j_dir/job.json.tmp" && _afk_factory_commit_tmp "$j_dir/job.json"
            local pbody
            pbody="$(_afk_factory_in_review_body "$host_agent_id")"
            afk_pc_curl PATCH "$api_url/api/issues/$j_issue" "$key" "$run_id" "$pbody" >/dev/null 2>&1 || true
          fi
        fi
      fi
      actions="$(jq -c --arg s "$j_slug" --arg id "$j_id" --arg r "$stall_reason" --argjson nc "$nudges" \
        '. + [{slug:$s, job_id:$id, stage:"needs-human", action:"escalated_max_nudges", reason:$r, nudge_count:$nc}]' <<<"$actions")"
      continue
    fi

    # Write Watchdog Nudge note & log event, then re-dispatch job from last completed stage
    cat > "$j_dir/watchdog-nudge.md" <<EOF
- Watchdog recovery #${nudges} triggered because the prior attempt stalled or exited unexpectedly: \`${stall_reason}\`.
- Inspect \`git status\` and \`git log -n 2\` in the worktree first so you continue cleanly from any partial work without redoing completed commits, then finish the current stage output immediately.
EOF
    jq -cn --arg ts "$now_iso" --arg st "$j_stage" --arg r "$stall_reason" --argjson nc "$nudges" \
      '{ts:$ts, stage:$st, status:"watchdog_nudge", nudge_count:$nc, reason:$r}' >> "$j_dir/route-history.jsonl"

    # run_job decides how stages execute: real agents unless a test asked
    # otherwise. The guess that used to sit here could never come out "live",
    # so every recovery reviewed the work with a canned PASS.
    local res_out new_st new_dec
    res_out="$(afk_factory_run_job "$j_repo" "$j_slug" "$j_id" "$j_issue" "$j_title" "" true)"
    new_st="$(jq -r '.stage // "unknown"' <<<"$res_out" 2>/dev/null)"
    new_dec="$(jq -r '.decision // "null"' <<<"$res_out" 2>/dev/null)"
    actions="$(jq -c --arg s "$j_slug" --arg id "$j_id" --arg st "$new_st" --arg dec "$new_dec" --arg r "$stall_reason" --argjson nc "$nudges" \
      '. + [{slug:$s, job_id:$id, stage:$st, decision:$dec, action:"nudged_and_resumed", reason:$r, nudge_count:$nc}]' <<<"$actions")"
  done

  if [[ "$json_mode" == "true" ]]; then
    jq -cn --argjson a "$actions" '{schema:"afk-factory-watchdog/1", inspected_count:($a|length), actions:$a}'
  else
    printf 'AFK Factory Watchdog: inspected %s in-flight job(s)\n' "$(jq -r 'length' <<<"$actions")"
    jq -r '.[] | "  [\(.action | ascii_upcase)] \(.slug)/\(.job_id): stage=\(.stage)" + (if .reason then " (\(.reason))" else "" end)' <<<"$actions"
  fi
  return 0
}

# afk_factory_resume <repo_path> <slug> <json_mode>
# Scans for interrupted in-flight jobs (e.g., after a host reboot) whose stage
# is not terminal/waiting-human (merged, needs-human, needs-info, rejected) and
# resumes them from their existing on-disk stage artifacts and checkpoints.
afk_factory_resume() {
  local repo="${1:-}" slug="${2:-}" json_mode="${3:-false}"
  local status_json
  status_json="$(afk_factory_status "$repo" "$slug" true enabled)"
  local -a in_flight=()
  mapfile -t in_flight < <(jq -c '.jobs[]? | select((.stage // "") | IN("merged","needs-human","needs-info","needs-consultation","consulted","rejected") | not)' <<<"$status_json" 2>/dev/null)

  local resumed="[]" row j_repo j_slug j_id j_issue j_title res_out
  for row in "${in_flight[@]:-}"; do
    [[ -n "$row" ]] || continue
    j_repo="$(jq -r '.repo_path // empty' <<<"$row")"
    j_slug="$(jq -r '.slug // empty' <<<"$row")"
    j_id="$(jq -r '.id // empty' <<<"$row")"
    j_issue="$(jq -r '.issue_id // empty' <<<"$row")"
    j_title="$(jq -r '.title // "Factory Task"' <<<"$row")"
    [[ -n "$j_repo" && -n "$j_id" ]] || continue
    # A job another runner already holds answers "already_running" and is
    # left alone.
    res_out="$(afk_factory_run_job "$j_repo" "$j_slug" "$j_id" "$j_issue" "$j_title" "" true)"
    jq -e 'type == "object"' <<<"$res_out" >/dev/null 2>&1 \
      || res_out="$(jq -cn --arg s "$j_slug" --arg id "$j_id" '{slug:$s, id:$id, stage:"unknown", decision:null}')"
    jq -e '.already_running == true' <<<"$res_out" >/dev/null 2>&1 && continue
    resumed="$(jq -c --argjson item "$res_out" '. + [$item]' <<<"$resumed")"
  done

  if [[ "$json_mode" == "true" ]]; then
    jq -cn --argjson r "$resumed" '{schema:"afk-factory-resume/1", resumed_count:($r|length), resumed:$r}'
  else
    printf 'AFK Factory Resume: %s interrupted job(s) resumed\n' "$(jq -r 'length' <<<"$resumed")"
    jq -r '.[] | "  [RESUMED] \(.slug)/\(.id): stage=\(.stage) decision=\(.decision)"' <<<"$resumed"
  fi
  return 0
}

# afk_factory_issue_wants_consultation <role> <title> <description>
# Planning roles always consult. A code assignee still consults when the issue
# itself asks for a PRD, spec, brainstorm, RFC, or requirements pass.
afk_factory_issue_wants_consultation() {
  local role="${1:-}" title="${2:-}" desc="${3:-}"
  case "$role" in
    pm|analyst|architect|ux-designer) return 0 ;;
  esac
  printf '%s\n%s\n' "$title" "$desc" | grep -Eqi '(^|[^[:alnum:]_])(PRD|Spec|Brainstorm|RFC|Requirements)([^[:alnum:]_]|$)'
}

# _afk_factory_consult_questions_json <consult_md>
# Reads `Q: id|prompt|answerMode|required|optId:Label;optId:Label` lines.
_afk_factory_consult_questions_json() {
  local file="$1" line qid qprompt qmode qreq qopts questions='[]' req_bool opts_json oid olabel pair
  [[ -f "$file" ]] || { printf '[]\n'; return 0; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == Q:* ]] || continue
    line="${line#Q:}"
    line="${line#"${line%%[![:space:]]*}"}"
    qid="" qprompt="" qmode="" qreq="" qopts=""
    IFS='|' read -r qid qprompt qmode qreq qopts <<< "$line"
    [[ -n "$qid" && -n "$qprompt" ]] || continue
    [[ "$qmode" == "text" || "$qmode" == "single_select" || "$qmode" == "multi_select" ]] || qmode="text"
    if [[ "$qreq" == "optional" ]]; then req_bool=false; else req_bool=true; fi
    opts_json='[]'
    if [[ "$qmode" != "text" && -n "$qopts" ]]; then
      local -a opairs=()
      IFS=';' read -r -a opairs <<< "$qopts"
      for pair in "${opairs[@]:-}"; do
        [[ -n "$pair" && "$pair" == *:* ]] || continue
        oid="${pair%%:*}"
        olabel="${pair#*:}"
        [[ -n "$oid" && -n "$olabel" ]] || continue
        opts_json="$(jq -c --arg i "$oid" --arg l "$olabel" '. + [{id:$i, label:$l}]' <<<"$opts_json")"
      done
    fi
    if [[ "$qmode" != "text" ]] && ! jq -e 'length >= 2' <<<"$opts_json" >/dev/null 2>&1; then
      qmode="text"
      opts_json='[]'
    fi
    questions="$(jq -c \
      --arg id "$qid" --arg p "$qprompt" --arg m "$qmode" \
      --argjson req "$req_bool" --argjson opts "$opts_json" \
      '. + [{id:$id, prompt:$p, answerMode:$m, required:$req}
        + (if $m == "text" then {} else {options:$opts, customAnswer:{enabled:true}} end)]' <<<"$questions")"
  done < "$file"
  if ! jq -e 'length > 0' <<<"$questions" >/dev/null 2>&1; then
    questions='[{"id":"outcome","prompt":"What outcome should this PRD commit to?","answerMode":"text","required":true}]'
  fi
  printf '%s\n' "$questions"
}

_afk_factory_consult_mode() { # <file>
  local mode
  mode="$(sed -n 's/^MODE:[[:space:]]*//p' "${1:-}" 2>/dev/null | head -n 1 | tr -d '[:space:]')"
  if [[ "$mode" == "CONFIRM" ]]; then
    printf 'CONFIRM'
  else
    printf 'QUESTIONS'
  fi
}

_afk_factory_consult_draft() { # <file> <title>
  local file="$1" title="$2" draft
  draft="$(awk 'BEGIN{p=0} /^## Draft[[:space:]]*$/{p=1; next} p{print}' "$file" 2>/dev/null || true)"
  if [[ -z "${draft//[[:space:]]/}" ]]; then
    draft="$(grep -v -E '^(MODE:|Q:)' "$file" 2>/dev/null || true)"
  fi
  if [[ -z "${draft//[[:space:]]/}" ]]; then
    draft="# PRD — ${title}"$'\n\n'"## Problem"$'\n'"${title}"
  fi
  printf '%s\n' "$draft"
}

# afk_factory_run_consultation <repo> <slug> <job_id> <issue_id> <title> <body_file> <json_mode> [<role>]
# Planning dialogue for a PM, analyst, architect, or UX issue. Writes documents/prd,
# posts ask_user_questions or a PRD confirmation, and waits in_review. Never merges code.
# A planning job is one runner at a time too. Called on its own (a claimed
# planning issue, a board reply) it takes the job lock; called from the job
# runner it runs under the lock that runner already holds.
afk_factory_run_consultation() {
  local c_repo="$1" c_job="$3" c_issue="${4:-}" c_json="${7:-false}" c_abs c_dir c_owner c_rc=0 c_own=false
  c_abs="$(cd -P -- "$c_repo" 2>/dev/null && pwd -P)" || {
    afk_warn "factory consultation: invalid repository path"
    return 1
  }
  [[ -n "$c_job" ]] || c_job="${c_issue:-consult-$(date -u +%Y%m%d%H%M%S)}"
  if [[ ! "$c_job" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || "$c_job" == *..* ]]; then
    afk_warn "factory consultation: a job id may hold only letters, digits, '.', '_' and '-'"
    return 1
  fi
  c_dir="$c_abs/.afk/jobs/$c_job"
  mkdir -p "$c_dir" || return 1
  c_owner="$(jq -r '.token // empty' "$c_dir/.run.lock/owner.json" 2>/dev/null || true)"
  # Already held by this caller only when the token is the one it took.
  if [[ -z "$c_owner" || "$c_owner" != "${AFK_FACTORY_LOCK_TOKEN:-}" ]]; then
    if ! _afk_factory_job_lock "$c_dir"; then
      if [[ "$c_json" == "true" ]]; then
        if jq -e 'type == "object"' "$c_dir/job.json" >/dev/null 2>&1; then
          jq -c '. + {already_running: true}' "$c_dir/job.json"
        else
          jq -cn --arg id "$c_job" '{id: $id, stage: "running", already_running: true}'
        fi
      fi
      return 0
    fi
    c_own=true
  fi
  if [[ "${AFK_FACTORY_OFFLINE_SYNTH:-0}" != "1" && -z "${AFK_FACTORY_AGENT_RUNNER:-}" ]]; then
    local -x AFK_FACTORY_LIVE_HARNESS=1
  fi
  _afk_factory_touch_heartbeat "$c_dir" "consultation" "${8:-pm}" "running"
  _afk_factory_beat_start "$c_dir" "consultation" "${8:-pm}"
  _afk_factory_run_consultation_locked "$c_abs" "$2" "$c_job" "${@:4}" || c_rc=$?
  _afk_factory_beat_stop
  _afk_factory_touch_heartbeat "$c_dir" "$(jq -r '.stage // "consultation"' "$c_dir/job.json" 2>/dev/null || printf 'consultation')" "" "done"
  [[ "$c_own" == true ]] && _afk_factory_job_unlock "$c_dir"
  return "$c_rc"
}

_afk_factory_run_consultation_locked() {
  local repo="$1" slug="$2" job_id="$3" issue_id="${4:-}" title="${5:-Planning}"
  local body_file="${6:-}" json_mode="${7:-false}" role="${8:-pm}"
  local abs_repo
  abs_repo="$(cd -P -- "$repo" 2>/dev/null && pwd -P)" || {
    afk_warn "factory consultation: invalid repository path"
    return 1
  }
  case "$role" in
    pm|analyst|architect|ux-designer) ;;
    *) role="pm" ;;
  esac
  [[ -n "$job_id" ]] || job_id="${issue_id:-consult-$(date -u +%Y%m%d%H%M%S)}"

  local job_dir="$abs_repo/.afk/jobs/$job_id"
  mkdir -p "$job_dir"
  local job_file="$job_dir/job.json"
  if [[ -n "$body_file" && -f "$body_file" && "$body_file" != "$job_dir/issue.md" ]]; then
    cp "$body_file" "$job_dir/issue.md"
  elif [[ ! -f "$job_dir/issue.md" ]]; then
    printf '# %s\n\nIssue ID: %s\n' "$title" "${issue_id:-local}" > "$job_dir/issue.md"
  fi

  local api_url="" company_id="" host_agent_id="" board_user_id="" project_id="" key="" harness="claude"
  local pc_cfg_path pc_cfg=""
  pc_cfg_path="$(afk_pc_config_path)"
  if [[ -f "$pc_cfg_path" ]]; then
    pc_cfg="$(cat -- "$pc_cfg_path" 2>/dev/null || true)"
    api_url="$(jq -r '.api_url // empty' <<<"$pc_cfg" 2>/dev/null)"
    company_id="$(jq -r '.company_id // empty' <<<"$pc_cfg" 2>/dev/null)"
    host_agent_id="$(jq -r '.host.agent_id // empty' <<<"$pc_cfg" 2>/dev/null)"
    board_user_id="$(jq -r '.board_user_id // empty' <<<"$pc_cfg" 2>/dev/null)"
    project_id="$(jq -r --arg s "$slug" '(.projects[]? | select(.slug == $s) | .paperclip_project_id) // empty' <<<"$pc_cfg" 2>/dev/null)"
    harness="$(jq -r --arg s "$slug" '(.projects[]? | select(.slug == $s) | .harness) // "claude"' <<<"$pc_cfg" 2>/dev/null)"
    local key_ref
    key_ref="$(jq -r '.host.key_ref // empty' <<<"$pc_cfg" 2>/dev/null)"
    if [[ -n "$key_ref" ]]; then
      AFK_PC_CFG="$pc_cfg"
      key="$(afk_pc_read_key "$key_ref" 2>/dev/null || true)"
    fi
  fi

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ ! -f "$job_file" ]]; then
    jq -cn \
      --arg id "$job_id" --arg slug "$slug" --arg issue "$issue_id" --arg title "$title" \
      --arg repo "$abs_repo" --arg role "$role" --arg now "$now" \
      '{
        schema: "afk-factory-job/1",
        id: $id,
        slug: $slug,
        issue_id: (if $issue == "" then null else $issue end),
        title: $title,
        repo_path: $repo,
        worktree_path: $repo,
        branch: null,
        stage: "consulting",
        round: 1,
        risk: "medium",
        surfaces: ["planning"],
        mode: "consultation",
        consult_role: $role,
        active_agent: $role,
        hired_roles: [],
        decision: null,
        created_at: $now,
        updated_at: $now
      }' > "$job_file"
  else
    jq -c --arg role "$role" --arg now "$now" \
      '.mode = "consultation" | .consult_role = $role | .stage = "consulting" | .active_agent = $role | .surfaces = ["planning"] | .updated_at = $now' \
      "$job_file" > "$job_file.tmp" && _afk_factory_commit_tmp "$job_file"
  fi

  local run_id=""
  if [[ -n "$api_url" && -n "$key" && -n "$issue_id" ]]; then
    run_id="$(afk_pch_ensure_run_id "$api_url" "$key" "$host_agent_id" "$issue_id")"
  fi
  afk_pch_ensure_project_team "$slug" "$abs_repo" "$harness" "$role" "$issue_id" "$api_url" "$key" "$company_id" "$host_agent_id" >/dev/null
  _afk_factory_announce "$slug" "$role" "$issue_id" "AFK consultation started with \`${slug}-${role}\`." "$api_url" "$key" "$run_id" || {
    [[ "$json_mode" == "true" ]] && cat "$job_file"
    return 0
  }

  local prompt_file="$job_dir/consult-input.md" output_file="$job_dir/consult.md"
  {
    printf '# Consultation\n\nRole: %s\n\n' "$role"
    cat -- "$job_dir/issue.md" 2>/dev/null || true
    if [[ -s "$job_dir/human-feedback.md" ]]; then
      printf '\n\n# Board answers\n\n'
      cat -- "$job_dir/human-feedback.md"
    fi
  } > "$prompt_file"
  if [[ -s "$job_dir/human-feedback.md" ]]; then
    rm -f "$output_file"
  fi
  if [[ ! -s "$output_file" ]]; then
    afk_factory_invoke_stage_agent "$abs_repo" "$abs_repo" "$job_dir" "$role" "consult" "$prompt_file" "$output_file" "$harness" >/dev/null 2>&1 || true
  fi
  if [[ ! -s "$output_file" ]]; then
    if [[ -s "$job_dir/human-feedback.md" ]]; then
      cat > "$output_file" <<EOF
MODE: CONFIRM
## Draft
# PRD — ${title}

## Problem
${title}

## Confirmed direction
$(cat -- "$job_dir/human-feedback.md")

## Acceptance
1. The board confirmed this PRD. Implementation is a separate issue.
EOF
    else
      cat > "$output_file" <<EOF
MODE: QUESTIONS
Q: outcome|What outcome should this PRD commit to?|text|required
## Draft
# PRD — ${title}

## Problem
${title}

## Open point
- The outcome is not confirmed yet.
EOF
    fi
  fi

  local mode draft doc_json="" inter_json="" pending_id="" pending_kind="" stage_out="needs-consultation"
  mode="$(_afk_factory_consult_mode "$output_file")"
  draft="$(_afk_factory_consult_draft "$output_file" "$title")"
  printf '%s\n' "$draft" > "$job_dir/prd.md"

  local role_key="$key"
  [[ -n "$key" ]] && role_key="$(afk_pch_key_for_role "$slug" "$role" "$key")"
  if [[ -n "$api_url" && -n "$role_key" && -n "$issue_id" ]]; then
    run_id="$(afk_pch_ensure_run_id "$api_url" "$key" "$host_agent_id" "$issue_id")"
    doc_json="$(afk_pch_upsert_document "$api_url" "$role_key" "$run_id" "$issue_id" "prd" "PRD ($job_id)" "$job_dir/prd.md" "Consultation draft via ${slug}-${role}" 2>/dev/null || true)"
    if [[ "$mode" == "CONFIRM" ]]; then
      inter_json="$(afk_pch_request_confirmation "$api_url" "$role_key" "$run_id" "$issue_id" "$board_user_id" \
        "afk-prd:${issue_id}:$(date -u +%Y%m%d%H%M%S)" \
        "Accept PRD ($job_id)" \
        "The PRD is ready for a decision." \
        "Accept this PRD and open an implementation issue, or request changes?" \
        "$draft" \
        "$doc_json" \
        "Accept PRD" "Request changes" 2>/dev/null || true)"
      pending_kind="request_confirmation"
      afk_pch_comment_as_role "$api_url" "$issue_id" "$key" "$run_id" "$slug" "$role" \
        "PRD draft is in \`documents/prd\`. Confirm it, or send changes." >/dev/null 2>&1 || true
    else
      local questions qids
      questions="$(_afk_factory_consult_questions_json "$output_file")"
      qids="$(jq -r 'map(.id) | join(",")' <<<"$questions" 2>/dev/null || printf 'outcome')"
      inter_json="$(afk_pch_ask_user_questions "$api_url" "$role_key" "$run_id" "$issue_id" "$board_user_id" \
        "afk-questions:${issue_id}:${qids}" \
        "Questions from ${slug}-${role}" \
        "$questions" 2>/dev/null || true)"
      pending_kind="ask_user_questions"
      afk_pch_comment_as_role "$api_url" "$issue_id" "$key" "$run_id" "$slug" "$role" \
        "I need a few answers before the PRD can be confirmed. The questions are on the issue card. A draft is in \`documents/prd\`." >/dev/null 2>&1 || true
    fi
    if [[ -n "$inter_json" ]]; then
      pending_id="$(jq -r '.id // empty' <<<"$inter_json" 2>/dev/null || true)"
    fi
    local pbody
    pbody="$(_afk_factory_in_review_body "$host_agent_id")"
    afk_pc_curl PATCH "$api_url/api/issues/$issue_id" "$key" "$run_id" "$pbody" >/dev/null 2>&1 || true
  elif [[ "$mode" != "CONFIRM" ]]; then
    pending_kind="ask_user_questions"
  else
    pending_kind="request_confirmation"
  fi

  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -c \
    --arg st "$stage_out" --arg role "$role" --arg pk "$pending_kind" --arg pid "$pending_id" --arg now "$now" \
    '.stage = $st | .mode = "consultation" | .consult_role = $role | .decision = "WAIT"
     | .active_agent = "human" | .pending_interaction_kind = (if $pk == "" then null else $pk end)
     | .pending_interaction_id = (if $pid == "" then null else $pid end) | .updated_at = $now' \
    "$job_file" > "$job_file.tmp" && _afk_factory_commit_tmp "$job_file"

  if [[ "$json_mode" == "true" ]]; then
    cat "$job_file"
  else
    printf 'AFK Factory consultation %s (%s): stage=%s via %s\n' "$job_id" "$slug" "$stage_out" "$role"
  fi
  return 0
}

_afk_factory_dispatch_claimed_issue() { # repo slug job issue title body assignee description
  local repo="$1" slug="$2" job_id="$3" issue_id="$4" title="$5" body_file="$6" assignee="${7:-}" desc="${8:-}"
  local role=""
  role="$(afk_pch_role_for_agent_id "$slug" "$assignee")"
  if afk_factory_issue_wants_consultation "$role" "$title" "$desc"; then
    case "$role" in
      pm|analyst|architect|ux-designer) ;;
      *) role="pm" ;;
    esac
    afk_factory_run_consultation "$repo" "$slug" "$job_id" "$issue_id" "$title" "$body_file" true "$role"
  else
    afk_factory_run_job "$repo" "$slug" "$job_id" "$issue_id" "$title" "$body_file" true
  fi
}

_afk_factory_accept_consultation() { # api key company host board slug repo job issue title dir project
  local api_url="$1" key="$2" company_id="$3" host_agent_id="$4" board_user_id="$5"
  local slug="$6" repo="$7" job_id="$8" issue_id="$9" title="${10}" job_dir="${11}" project_id="${12}"
  local harness="claude"
  harness="$(jq -r --arg s "$slug" '(.projects[]? | select(.slug == $s) | .harness) // "claude"' "$(afk_pc_config_path)" 2>/dev/null || printf 'claude')"
  afk_pch_ensure_project_team "$slug" "$repo" "$harness" "pm,dev" "$issue_id" "$api_url" "$key" "$company_id" "$host_agent_id" >/dev/null
  local dev_id run_id created child_id now
  dev_id="$(afk_pch_agent_id "$slug" "dev")"
  created="$(afk_pch_create_child_issue "$api_url" "$key" "$company_id" "$issue_id" "$project_id" "$dev_id" \
    "Implement: ${title}" \
    "Execute the accepted PRD on parent ${issue_id}. The source document is documents/prd. Do not reopen planning unless the PRD itself is wrong." \
    "afk-consult-child:${issue_id}:dev")"
  child_id="$(jq -r '.id // empty' <<<"${created:-null}" 2>/dev/null || true)"
  run_id="$(afk_pch_ensure_run_id "$api_url" "$key" "$host_agent_id" "$issue_id")"
  afk_pch_comment_as_role "$api_url" "$issue_id" "$key" "$run_id" "$slug" "pm" \
    "PRD accepted. Opened an implementation issue for \`${slug}-dev\`." >/dev/null 2>&1 || true
  afk_pch_finish_issue "$slug" "pm" "$issue_id" "$api_url" "$key" "$run_id" >/dev/null 2>&1 || true
  afk_pch_retire_project_agents "$slug" "all" "$api_url" "$key" >/dev/null 2>&1 || true
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -c --arg now "$now" --arg cid "$child_id" \
    '.stage = "consulted" | .decision = "ACCEPT" | .active_agent = null | .pending_interaction_id = null
     | .child_issue_id = (if $cid == "" then null else $cid end) | .updated_at = $now' \
    "$job_dir/job.json" > "$job_dir/job.json.tmp" && _afk_factory_commit_tmp "$job_dir/job.json"
  jq -cn --arg s "$slug" --arg id "$job_id" --arg cid "$child_id" \
    '{slug:$s, job_id:$id, action:"accepted_plan", child_issue_id:(if $cid == "" then null else $cid end)}'
}

# _afk_factory_comment_is_approval <body>
# 0 when the comment is an approval and nothing else. "Merge conflicts with
# main, please rebase" and "Approve once the test is fixed" begin with the
# same words and mean the opposite, so a leading word is not enough.
_afk_factory_comment_is_approval() {
  local norm
  # Markdown emphasis (not strikethrough or a quote), a thumbs-up or check
  # mark, and a closing "!" or "."
  # do not change what the word says. Anything else does: "merge?" is a
  # question and "approve 👎" is not an approval, so any other character left
  # over means this is not a clean approval.
  norm="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '\r' \
    | sed -e 's/👍//g; s/✅//g; s/✔️//g; s/✔//g' -e 's/[*_`]//g' \
    | tr -s '[:space:]' ' ' | sed 's/^ //; s/[ !.]*$//')"
  [[ "$norm" =~ ^(approve|approved|lgtm|merge|ship\ it)$ ]]
}

# _afk_factory_comment_is_near_approval <body>
# 0 for a short comment that begins with an approval word and is not a clean
# approval: "Approved, thanks", "approve 👍", "**approve**". Such a comment gets
# a question back instead of being merged or sent to the builder.
_afk_factory_comment_is_near_approval() {
  local words first
  words="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' ' ' | tr -s ' \n' ' ' | sed 's/^ //; s/ $//')"
  first="${words%% *}"
  [[ "$first" =~ ^(approve|approved|lgtm|merge|ship)$ ]] || return 1
  (( $(wc -w <<<"$words") <= 4 ))
}

# _afk_factory_new_board_comment <comments-json> <last_seen_comment_id> <board_user_id>
# The newest comment after the last one seen that the board user wrote, or
# nothing. Only the board user's comments steer a job: any other person or
# agent able to comment on the issue could otherwise approve a merge or hand
# the builder instructions. With no board user configured, nobody qualifies.
_afk_factory_new_board_comment() {
  local com_body="$1" lcid="${2:-}" board="${3:-}"
  [[ -n "$board" ]] || return 0
  jq -r --arg lcid "$lcid" --arg board "$board" '
    (if type == "array" then . else (.comments // []) end) as $all
    | (if $lcid == "" then $all
       else ([$all | to_entries[] | select(.value.id == $lcid) | .key] | last // -1) as $idx
            | if $idx >= 0 then $all[($idx + 1):] else $all end
       end)
    | map(select((.authorAgentId // null) == null and (.authorUserId // "") == $board))
    | last.body // empty
  ' <<<"$com_body" 2>/dev/null || true
}

# _afk_factory_file_digest <file> -> hex digest, or nothing when unreadable
_afk_factory_file_digest() {
  [[ -f "$1" ]] || return 0
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" 2>/dev/null | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 < "$1" 2>/dev/null | cut -d' ' -f1
  fi
}

# _afk_factory_checked_commit <job_dir>
# The commit the current round's checks ran on, or nothing.
_afk_factory_checked_commit() {
  local jd="$1" r
  r="$(jq -r '.round // 1' "$jd/job.json" 2>/dev/null || printf '1')"
  head -n 1 "$jd/round-$r/checks.sha" 2>/dev/null | tr -d '[:space:]'
}

# _afk_factory_approval_invalid <job_dir> <worktree> [<repo> <branch>]
# Prints why an approved job may not be merged now and returns 0; returns 1
# when it may. Called under the job lock, from the job file as it is then.
_afk_factory_approval_invalid() {
  local j_dir="$1" wt="$2" a_repo="${3:-}" a_branch="${4:-}" doc stage kind gate round sha head
  doc="$(cat "$j_dir/job.json" 2>/dev/null || true)"
  stage="$(jq -r '.stage // empty' <<<"$doc" 2>/dev/null || true)"
  kind="$(jq -r '.escalation_kind // empty' <<<"$doc" 2>/dev/null || true)"
  gate="$(jq -r '.merge_evaluation.gate_verdict // empty' <<<"$doc" 2>/dev/null || true)"
  round="$(jq -r '.round // 1' <<<"$doc" 2>/dev/null || printf '1')"
  if [[ "$stage" != "needs-human" ]]; then
    printf 'the job is no longer waiting for a decision (it is at %s)' "${stage:-an unreadable stage}"; return 0
  fi
  if [[ -n "$kind" && "$kind" != "merge" ]]; then
    printf 'the job is not waiting on a merge decision'; return 0
  fi
  if [[ "$gate" != "PASS" ]] || ! head -n 5 "$j_dir/round-$round/checks.md" 2>/dev/null | grep -q '^VERDICT: PASS'; then
    printf 'the checks for this round did not pass'; return 0
  fi
  if [[ -n "$a_repo" && -n "$a_branch" && ! -e "$wt" ]]; then
    # The worktree is gone; the branch in the base repository is what lands.
    sha="$(head -n 1 "$j_dir/round-$round/checks.sha" 2>/dev/null | tr -d '[:space:]')"
    head="$(git -C "$a_repo" rev-parse --verify --quiet "refs/heads/$a_branch" 2>/dev/null || true)"
    if [[ -z "$sha" || "$sha" != "$head" ]]; then
      printf 'the branch has moved since the checks ran'; return 0
    fi
  fi
  if [[ -d "$wt/.git" || -f "$wt/.git" ]]; then
    sha="$(head -n 1 "$j_dir/round-$round/checks.sha" 2>/dev/null | tr -d '[:space:]')"
    head="$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)"
    if [[ -z "$sha" || "$sha" != "$head" ]]; then
      printf 'the branch has moved since the checks ran'; return 0
    fi
    if [[ -n "$(git -C "$wt" status --porcelain --untracked-files=no -- . ':!.afk' 2>/dev/null || true)" ]]; then
      printf 'the worktree has uncommitted changes'; return 0
    fi
  fi
  return 1
}

# afk_factory_sync_reviews [<repo_path>] [<slug>] [<dry_run>] [<json_mode>]
# Reconciles `needs-human`, `needs-info`, and `needs-consultation` Factory jobs
# against Paperclip interactions and board comments:
#   - Consultation acceptance opens an implementation issue and does not merge code.
#   - Consultation answers resume the same planning persona.
#   - Code-factory acceptance merges the git branch, registers the commit, marks done.
#   - Accepted / Approved -> merges git branch, registers commit Work Product,
#     updates `merge-decision` document, marks issue `done`, retires agents.
#   - Rejected / Revision feedback -> writes `human-feedback.md`, increments
#     repair round (`max_rounds_override`), transitions issue to `in_progress`,
#     and re-enters `afk_factory_run_job` with the human's exact instructions.
afk_factory_sync_reviews() {
  local repo="${1:-}" slug="${2:-}" dry_run="${3:-false}" json_mode="${4:-false}"
  local status_json
  status_json="$(afk_factory_status "$repo" "$slug" true enabled)"
  local -a waiting=()
  mapfile -t waiting < <(jq -c '.attention_required[]?' <<<"$status_json" 2>/dev/null)

  local pc_cfg_path pc_cfg="" api_url="" company_id="" host_agent_id="" board_user_id="" key=""
  pc_cfg_path="$(afk_pc_config_path)"
  if [[ -f "$pc_cfg_path" ]]; then
    pc_cfg="$(cat -- "$pc_cfg_path" 2>/dev/null || true)"
    api_url="$(jq -r '.api_url // empty' <<<"$pc_cfg" 2>/dev/null)"
    company_id="$(jq -r '.company_id // empty' <<<"$pc_cfg" 2>/dev/null)"
    host_agent_id="$(jq -r '.host.agent_id // empty' <<<"$pc_cfg" 2>/dev/null)"
    board_user_id="$(jq -r '.board_user_id // empty' <<<"$pc_cfg" 2>/dev/null)"
    local key_ref
    key_ref="$(jq -r '.host.key_ref // empty' <<<"$pc_cfg" 2>/dev/null)"
    if [[ -n "$key_ref" ]]; then
      AFK_PC_CFG="$pc_cfg"
      key="$(afk_pc_read_key "$key_ref" 2>/dev/null || true)"
    fi
  fi

  local actions="[]" summary_lines="[]"
  if [[ -z "$api_url" || -z "$key" ]]; then
    if [[ "$json_mode" == "true" ]]; then
      jq -cn '{schema:"afk-factory-sync-reviews/1", reviewed_count:0, actions:[], summary_lines:[]}'
    else
      printf 'AFK Factory Sync Reviews: Paperclip credentials unavailable or offline (0 synced)\n'
    fi
    return 0
  fi

  local row j_repo j_slug j_id j_issue j_title j_stage j_wt j_branch j_round j_piid j_lcid j_dir project_id
  for row in "${waiting[@]:-}"; do
    [[ -n "$row" ]] || continue
    j_repo="$(jq -r '.repo_path // empty' <<<"$row")"
    j_slug="$(jq -r '.slug // empty' <<<"$row")"
    j_id="$(jq -r '.id // empty' <<<"$row")"
    j_issue="$(jq -r '.issue_id // empty' <<<"$row")"
    j_title="$(jq -r '.title // "Factory Task"' <<<"$row")"
    j_stage="$(jq -r '.stage // "needs-human"' <<<"$row")"
    j_wt="$(jq -r '.worktree_path // empty' <<<"$row")"
    j_branch="$(jq -r '.branch // ("factory/" + (.id // ""))' <<<"$row")"
    j_round="$(jq -r '.round // 1' <<<"$row")"
    j_piid="$(jq -r '.pending_interaction_id // empty' <<<"$row")"
    j_lcid="$(jq -r '.last_seen_comment_id // empty' <<<"$row")"
    [[ -n "$j_repo" && -n "$j_id" && -n "$j_issue" ]] || continue
    j_dir="$j_repo/.afk/jobs/$j_id"
    [[ -d "$j_dir" ]] || continue
    [[ -n "$j_wt" ]] || j_wt="$j_repo"
    project_id="$(jq -r --arg s "$j_slug" '(.projects[]? | select(.slug == $s) | .paperclip_project_id) // empty' <<<"$pc_cfg" 2>/dev/null)"

    local int_resp int_code int_body com_resp com_code com_body
    int_resp="$(afk_pc_curl GET "$api_url/api/issues/$j_issue/interactions" "$key" "")"
    int_code="${int_resp%%$'\n'*}"
    int_body="${int_resp#*$'\n'}"
    com_resp="$(afk_pc_curl GET "$api_url/api/issues/$j_issue/comments" "$key" "")"
    com_code="${com_resp%%$'\n'*}"
    com_body="${com_resp#*$'\n'}"

    local inter_obj="{}" outcome="" reason="" sup_cid=""
    if [[ "$int_code" == 2?? ]]; then
      inter_obj="$(jq -c --arg pid "$j_piid" '
        (if type == "array" then . else (.interactions // []) end) as $arr
        # Only the card this job is waiting on. Falling back to the newest
        # confirmation on the issue acts on a card from an earlier round.
        | if $pid != "" then ([$arr[] | select(.id == $pid)][0] // {}) else {} end
      ' <<<"$int_body" 2>/dev/null || printf '{}')"
      outcome="$(jq -r '.result.outcome // empty' <<<"$inter_obj" 2>/dev/null || true)"
      reason="$(jq -r '.result.reason // empty' <<<"$inter_obj" 2>/dev/null || true)"
      sup_cid="$(jq -r '.result.commentId // empty' <<<"$inter_obj" 2>/dev/null || true)"
    fi

    local newest_cid="" new_human_body="" sup_body=""
    if [[ "$com_code" == 2?? ]]; then
      newest_cid="$(jq -r '(if type == "array" then . else (.comments // []) end) | last.id // empty' <<<"$com_body" 2>/dev/null || true)"
      if [[ -n "$sup_cid" ]]; then
        sup_body="$(jq -r --arg cid "$sup_cid" --arg board "$board_user_id" '
          (if type == "array" then . else (.comments // []) end)
          | map(select(.id == $cid and (.authorAgentId // null) == null and $board != "" and (.authorUserId // "") == $board))
          | first.body // empty
        ' <<<"$com_body" 2>/dev/null || true)"
      fi
      new_human_body="$(_afk_factory_new_board_comment "$com_body" "$j_lcid" "$board_user_id")"
    fi

    local j_mode
    j_mode="$(jq -r '.mode // "factory"' <<<"$row" 2>/dev/null || printf 'factory')"
    if [[ "$j_mode" == "consultation" ]]; then
      local c_kind="" c_answers="" c_feedback="" c_action="" c_out="" c_role=""
      c_kind="$(jq -r '.kind // empty' <<<"$inter_obj" 2>/dev/null || true)"
      c_answers="$(jq -r '[.result.answers[]? | (.text // .value // .answer // .label // empty)] | map(select(type == "string" and length > 0)) | join("\n")' <<<"$inter_obj" 2>/dev/null || true)"
      if [[ "$c_kind" == "request_confirmation" && "$outcome" == "accepted" ]]; then
        c_action="accept_plan"
      elif [[ -n "$c_answers" ]]; then
        c_action="resume"
        c_feedback="$c_answers"
      elif [[ "$outcome" == "rejected" ]]; then
        c_action="resume"
        c_feedback="${reason:-Board requested PRD changes.}"
      elif [[ -n "$new_human_body" ]]; then
        c_action="resume"
        c_feedback="$new_human_body"
      fi
      if [[ -z "$c_action" ]]; then
        continue
      fi
      if [[ "$dry_run" == "true" ]]; then
        actions="$(jq -c --arg s "$j_slug" --arg id "$j_id" --arg a "would_${c_action}" \
          '. + [{slug:$s, job_id:$id, action:$a}]' <<<"$actions")"
        continue
      fi
      if [[ "$c_action" == "accept_plan" ]]; then
        c_out="$(_afk_factory_accept_consultation "$api_url" "$key" "$company_id" "$host_agent_id" "$board_user_id" \
          "$j_slug" "$j_repo" "$j_id" "$j_issue" "$j_title" "$j_dir" "$project_id")"
      else
        printf '%s\n' "$c_feedback" > "$j_dir/human-feedback.md"
        rm -f "$j_dir/consult.md"
        c_role="$(jq -r '.consult_role // "pm"' "$j_dir/job.json" 2>/dev/null || printf 'pm')"
        afk_factory_run_consultation "$j_repo" "$j_slug" "$j_id" "$j_issue" "$j_title" "" true "$c_role" >/dev/null
        # Mark the comments read. Without it the same reply is "new" on every
        # pass and the consultation is re-run, with a fresh card, every 90s.
        local c_lcid
        c_lcid="$(_afk_factory_latest_comment_id "$api_url" "$key" "$j_issue")"
        [[ -n "$c_lcid" ]] || c_lcid="$newest_cid"
        if [[ -n "$c_lcid" ]]; then
          jq -c --arg lcid "$c_lcid" '.last_seen_comment_id = $lcid' \
            "$j_dir/job.json" > "$j_dir/job.json.tmp" && _afk_factory_commit_tmp "$j_dir/job.json"
        fi
        c_out="$(jq -cn --arg s "$j_slug" --arg id "$j_id" --arg st "$(jq -r '.stage // "needs-consultation"' "$j_dir/job.json")" \
          '{slug:$s, job_id:$id, action:"resumed_consultation", stage:$st}')"
      fi
      if [[ -n "$c_out" ]]; then
        actions="$(jq -c --argjson item "$c_out" '. + [$item]' <<<"$actions")"
        summary_lines="$(jq -c --arg m "$c_action $j_slug/$j_id" '. + [$m]' <<<"$summary_lines")"
      fi
      continue
    fi

    local action_kind="" feedback_text=""
    if [[ "$outcome" == "accepted" ]]; then
      action_kind="approve"
    elif [[ "$outcome" == "rejected" ]]; then
      action_kind="revise"
      feedback_text="${reason:-Human board reviewer requested changes via Paperclip confirmation card.}"
    elif [[ "$outcome" == "superseded_by_comment" || -n "$new_human_body" ]]; then
      local cand_body="${sup_body:-$new_human_body}"
      if [[ -n "$cand_body" ]]; then
        if [[ "$j_stage" == "needs-human" ]] && _afk_factory_comment_is_approval "$cand_body"; then
          action_kind="approve"
        elif [[ "$j_stage" == "needs-human" ]] && _afk_factory_comment_is_near_approval "$cand_body"; then
          # "Approved, thanks" reads like an approval and is not one. Asking
          # costs a comment; guessing either way costs a merge or a rebuild.
          action_kind="clarify"
        else
          action_kind="revise"
          feedback_text="$cand_body"
        fi
      fi
    fi

    [[ -n "$action_kind" ]] || continue

    # What the job is waiting on decides what an approval means. Only a job
    # that finished its checks and reviews and is waiting on the merge itself
    # is merged by one. A job stopped for budget, a stall or a failed stage
    # has no checked work to merge; approving it lets it carry on.
    local j_kind j_gate
    j_kind="$(jq -r '.escalation_kind // empty' <<<"$row" 2>/dev/null || true)"
    j_gate="$(jq -r '.merge_evaluation.gate_verdict // empty' <<<"$row" 2>/dev/null || true)"
    if [[ "$action_kind" == "approve" ]]; then
      if [[ -n "$j_kind" && "$j_kind" != "merge" ]]; then
        action_kind="revise"
        feedback_text="The board approved continuing. Carry on from where the job stopped."
      elif [[ "$j_gate" != "PASS" ]]; then
        # The change is waiting on a merge decision and its checks did not
        # pass. Approval does not merge failing checks, and rebuilding on an
        # approval only produces the same card again.
        action_kind="checks_failed"
      fi
    fi

    if [[ "$dry_run" == "true" ]]; then
      actions="$(jq -c --arg s "$j_slug" --arg id "$j_id" --arg a "would_${action_kind}" \
        '. + [{slug:$s, job_id:$id, action:$a}]' <<<"$actions")"
      continue
    fi

    local now_iso run_id=""
    now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    run_id="$(afk_pch_ensure_run_id "$api_url" "$key" "$host_agent_id" "$j_issue")"

    if [[ "$action_kind" == "clarify" || "$action_kind" == "checks_failed" ]]; then
      local note
      if [[ "$action_kind" == "clarify" ]]; then
        note="To merge, reply with just \`approve\`. Anything else is passed to the agent as instructions for another round."
      else
        note="Not merged: this change did not pass its checks (\`.afk/checks.sh\`). Reply with instructions for another round; the checks run again on that round, so if the checks themselves were wrong, fix them first and then reply."
      fi
      afk_pc_comment "$api_url" "$j_issue" "$key" "$run_id" "$note" >/dev/null 2>&1 || true
      newest_cid="$(_afk_factory_latest_comment_id "$api_url" "$key" "$j_issue")"
      jq -c --arg lcid "$newest_cid" --arg now "$now_iso" \
        '.last_seen_comment_id = (if $lcid == "" then .last_seen_comment_id else $lcid end) | .pending_interaction_id = (if .pending_interaction_id == null then null else ("answered:" + .pending_interaction_id) end) | .updated_at = $now' \
        "$j_dir/job.json" > "$j_dir/job.json.tmp" && _afk_factory_commit_tmp "$j_dir/job.json"
      actions="$(jq -c --arg s "$j_slug" --arg id "$j_id" --arg a "$action_kind" '. + [{slug:$s, job_id:$id, action:$a}]' <<<"$actions")"
      continue
    fi

    if [[ "$action_kind" == "approve" ]]; then
      local land_res land_ok merged_sha
      # Landing is a runner action like any other: one at a time per job.
      if ! _afk_factory_job_lock "$j_dir"; then
        actions="$(jq -c --arg s "$j_slug" --arg id "$j_id" '. + [{slug:$s, job_id:$id, action:"approve_deferred_job_busy"}]' <<<"$actions")"
        continue
      fi
      # The row was read before the lock. Read the job again under it: another
      # runner may have moved it on, or the branch may have moved since the
      # checks ran.
      if [[ "$(jq -r '.stage // empty' "$j_dir/job.json" 2>/dev/null || true)" != "needs-human" ]]; then
        # Someone else already acted on this job. Nothing to say on the issue.
        _afk_factory_job_unlock "$j_dir"
        actions="$(jq -c --arg s "$j_slug" --arg id "$j_id" '. + [{slug:$s, job_id:$id, action:"approve_skipped_job_moved_on"}]' <<<"$actions")"
        continue
      fi
      local still_bad=""
      _afk_factory_touch_heartbeat "$j_dir" "landing" "" "running"
      _afk_factory_beat_start "$j_dir" "landing" ""
      if still_bad="$(_afk_factory_approval_invalid "$j_dir" "$j_wt" "$j_repo" "$j_branch")"; then
        land_res="$(jq -cn --arg r "$still_bad" '{ok:false, action:"stale_approval", commit:"", reason:$r}')"
      else
        _afk_factory_clear_execution_policy "$api_url" "$key" "$run_id" "$j_issue"
        land_res="$(_afk_factory_land_branch "$j_repo" "$j_wt" "$j_branch" "$j_id" "$j_title")" || true
      fi
      _afk_factory_beat_stop
      land_ok="$(jq -r '.ok // false' <<<"$land_res" 2>/dev/null || printf 'false')"
      if [[ "$land_ok" == "true" ]]; then
        merged_sha="$(jq -r '.commit // empty' <<<"$land_res" 2>/dev/null || true)"
        # Record the merge before the Paperclip calls: a restart between the
        # two must not find the job still waiting and land it again.
        jq -c --arg now "$now_iso" --arg sha "$merged_sha" \
          '.stage = "merged" | .decision = "APPROVE" | .merged_commit = $sha | .active_agent = null | .pending_interaction_id = null | .updated_at = $now' \
          "$j_dir/job.json" > "$j_dir/job.json.tmp" && _afk_factory_commit_tmp "$j_dir/job.json"
        cat >> "$j_dir/decision.md" <<EOF

## Human Board Resolution ($now_iso)
- Outcome: APPROVED by board user in Paperclip
- Landed commit: \`${merged_sha}\` (branch \`${j_branch}\`)
EOF
        afk_pc_curl PATCH "$api_url/api/issues/$j_issue" "$key" "$run_id" '{"status":"in_progress"}' >/dev/null 2>&1 || true
        afk_pch_upsert_document "$api_url" "$(afk_pch_key_for_role "$j_slug" "dev" "$key")" "$run_id" "$j_issue" "merge-decision" "Situational Merge Decision ($j_id)" "$j_dir/decision.md" "Human board approved; merged ${merged_sha:0:8}" >/dev/null 2>&1 || true
        if [[ -n "$merged_sha" ]]; then
          afk_pch_register_commit_work_product "$api_url" "$key" "$run_id" "$j_issue" "$project_id" "$merged_sha" "$j_branch" "feat($j_id): $j_title" "Approved by human board and merged into $j_slug" "merged" "approved" >/dev/null 2>&1 || true
        fi
        afk_pc_comment "$api_url" "$j_issue" "$key" "$run_id" \
          "## AFK Factory — Human Approval Received & Merged\n\nLanded commit \`${merged_sha}\` from \`${j_branch}\`." >/dev/null 2>&1 || true
        afk_pch_finish_issue "$j_slug" "dev" "$j_issue" "$api_url" "$key" "$run_id" >/dev/null 2>&1 || true
        afk_pch_retire_project_agents "$j_slug" "all" "$api_url" "$key" >/dev/null 2>&1 || true
        declare -F afk_tooling_cleanup_worktree >/dev/null 2>&1 && afk_tooling_cleanup_worktree "$j_repo" "$j_wt" "$j_dir"

        jq -c --arg now "$now_iso" --arg sha "$merged_sha" --arg lcid "$newest_cid" \
          '.stage = "merged" | .decision = "APPROVE" | .merged_commit = $sha | .active_agent = null | .pending_interaction_id = null | .last_seen_comment_id = (if $lcid == "" then .last_seen_comment_id else $lcid end) | .updated_at = $now' \
          "$j_dir/job.json" > "$j_dir/job.json.tmp" && _afk_factory_commit_tmp "$j_dir/job.json"
        actions="$(jq -c --arg s "$j_slug" --arg id "$j_id" --arg sha "$merged_sha" \
          '. + [{slug:$s, job_id:$id, action:"approved_and_merged", merged_commit:$sha}]' <<<"$actions")"
        summary_lines="$(jq -c --arg m "merged $j_slug/$j_id (${merged_sha:0:8})" '. + [$m]' <<<"$summary_lines")"
      else
        # The approval was given and the merge did not happen. Say why, once,
        # and put up a fresh card: the accepted one would otherwise be acted
        # on again every pass, silently.
        local land_why new_card new_piid=""
        land_why="$(jq -r '.reason // "the merge failed"' <<<"$land_res" 2>/dev/null || printf 'the merge failed')"
        afk_pc_comment "$api_url" "$j_issue" "$key" "$run_id" \
          "$(printf '## AFK Factory — Approved, Not Merged\n\nThe approval was received, and the merge did not go through: %s.\n\nNothing was merged. Accept the new card to try again once that is resolved, or reply with instructions.' "$land_why")" >/dev/null 2>&1 || true
        newest_cid="$(_afk_factory_latest_comment_id "$api_url" "$key" "$j_issue")"
        new_card="$(afk_pch_request_confirmation "$api_url" "$key" "$run_id" "$j_issue" "$board_user_id" \
          "afk-confirm:${j_issue}:retry:$(date -u +%s)" \
          "Retry AFK Factory Merge ($j_id)" \
          "The merge of \`$j_branch\` did not go through: $land_why." \
          "Try the merge again, or request revisions?" \
          "$(cat "$j_dir/decision.md" 2>/dev/null || true)" \
          "" 2>/dev/null || true)"
        [[ -n "$new_card" ]] && new_piid="$(jq -r '.id // empty' <<<"$new_card" 2>/dev/null || true)"
        # With no new card the old one stays consumed: record a marker id so
        # this pass's accepted card is not read again.
        [[ -n "$new_piid" ]] || new_piid="none:$(date -u +%s)"
        jq -c --arg now "$now_iso" --arg why "$land_why" --arg piid "$new_piid" --arg lcid "$newest_cid" \
          '.pending_interaction_id = $piid | .last_land_error = $why
           | .last_seen_comment_id = (if $lcid == "" then .last_seen_comment_id else $lcid end) | .updated_at = $now' \
          "$j_dir/job.json" > "$j_dir/job.json.tmp" && _afk_factory_commit_tmp "$j_dir/job.json"
        afk_pc_curl PATCH "$api_url/api/issues/$j_issue" "$key" "$run_id" "$(_afk_factory_in_review_body "$host_agent_id")" >/dev/null 2>&1 || true
        actions="$(jq -c --arg s "$j_slug" --arg id "$j_id" --arg r "$land_why" \
          '. + [{slug:$s, job_id:$id, action:"approved_not_merged", reason:$r}]' <<<"$actions")"
        summary_lines="$(jq -c --arg m "approved, not merged $j_slug/$j_id: $land_why" '. + [$m]' <<<"$summary_lines")"
      fi
      _afk_factory_touch_heartbeat "$j_dir" "$(jq -r '.stage // "needs-human"' "$j_dir/job.json" 2>/dev/null)" "" "done"
      _afk_factory_job_unlock "$j_dir"
    elif [[ "$action_kind" == "revise" ]]; then
      # Appended: instructions from an earlier reply that a failed build never
      # used must not be lost when the board replies again.
      cat >> "$j_dir/human-feedback.md" <<EOF
- Human board feedback recorded at $now_iso:
$feedback_text
EOF
      local next_round=$(( j_round + 1 ))
      # The board asking for another round is a person acting: the check
      # script as it stands now, which they may have just fixed, is the one
      # the next round is judged by.
      local cur_digest
      cur_digest="$(_afk_factory_file_digest "$j_repo/.afk/checks.sh")"
      jq -c --arg d "$cur_digest" '.checks_script_sha256 = (if $d == "" then null else $d end)' \
        "$j_dir/job.json" > "$j_dir/job.json.tmp" && _afk_factory_commit_tmp "$j_dir/job.json"
      if [[ "$j_stage" == "needs-info" ]]; then
        rm -f "$j_dir/intake.md"
        jq -c --arg now "$now_iso" --arg lcid "$newest_cid" \
          '.stage = "intake" | .active_agent = "pm" | .recovery = null | .pending_interaction_id = null | .last_seen_comment_id = (if $lcid == "" then .last_seen_comment_id else $lcid end) | .updated_at = $now' \
          "$j_dir/job.json" > "$j_dir/job.json.tmp" && _afk_factory_commit_tmp "$j_dir/job.json"
      else
        jq -c --arg now "$now_iso" --arg lcid "$newest_cid" --argjson nr "$next_round" \
          '.stage = "build" | .round = $nr | .max_rounds_override = $nr | .active_agent = "dev" | .escalation_kind = null | .recovery = null | .pending_interaction_id = null | .last_seen_comment_id = (if $lcid == "" then .last_seen_comment_id else $lcid end) | .updated_at = $now' \
          "$j_dir/job.json" > "$j_dir/job.json.tmp" && _afk_factory_commit_tmp "$j_dir/job.json"
      fi
      local claim_patch
      claim_patch="$(jq -cn --arg a "$host_agent_id" '{status:"in_progress", assigneeUserId:null} + (if $a != "" then {assigneeAgentId:$a} else {} end)')"
      afk_pc_curl PATCH "$api_url/api/issues/$j_issue" "$key" "$run_id" "$claim_patch" >/dev/null 2>&1 || true

      local rerun_out new_st new_dec
      rerun_out="$(afk_factory_run_job "$j_repo" "$j_slug" "$j_id" "$j_issue" "$j_title" "" true)"
      new_st="$(jq -r '.stage // "unknown"' <<<"$rerun_out" 2>/dev/null)"
      new_dec="$(jq -r '.decision // "null"' <<<"$rerun_out" 2>/dev/null)"
      actions="$(jq -c --arg s "$j_slug" --arg id "$j_id" --arg st "$new_st" --arg dec "$new_dec" \
        '. + [{slug:$s, job_id:$id, action:"reentered_with_feedback", stage:$st, decision:$dec}]' <<<"$actions")"
      summary_lines="$(jq -c --arg m "re-ran $j_slug/$j_id with feedback -> $new_st" '. + [$m]' <<<"$summary_lines")"
    fi
  done

  if [[ "$json_mode" == "true" ]]; then
    jq -cn --argjson a "$actions" --argjson sl "$summary_lines" \
      '{schema:"afk-factory-sync-reviews/1", reviewed_count:($a|length), actions:$a, summary_lines:$sl}'
  else
    printf 'AFK Factory Sync Reviews: processed %s item(s)\n' "$(jq -r 'length' <<<"$actions")"
    jq -r '.[] | "  [\(.action | ascii_upcase)] \(.slug)/\(.job_id)" + (if .merged_commit then " -> \(.merged_commit)" elif .stage then " -> stage=\(.stage)" else "" end)' <<<"$actions"
  fi
  return 0
}

# afk_factory_poll_paperclip [<slug>] [<dry_run>] [<background>] [<json_mode>]
# Autonomous Paperclip work loop for Factory-enabled projects:
#   1. Reconciles human review confirmations & comments (`afk_factory_sync_reviews`).
#   2. Recovers stalled or interrupted jobs (`afk_factory_watchdog`).
#   3. Claims `todo` issues (and unclaimed `in_progress` host issues) via atomic
#      Paperclip checkout for projects with `factory_enabled: true` (or explicit <slug>),
#      enforcing `max_active_issues` and Paperclip monthly budget caps.
afk_factory_poll_paperclip() {
  local slug_filter="${1:-}" dry_run="${2:-false}" bg_mode="${3:-false}" json_mode="${4:-false}"
  local sr_json wd_json reviewed_cnt=0 summary_lines="[]" dispatched="[]"

  sr_json="$(afk_factory_sync_reviews "" "$slug_filter" "$dry_run" true 2>/dev/null || printf '{"reviewed_count":0,"summary_lines":[]}')"
  reviewed_cnt="$(jq -r '.reviewed_count // 0' <<<"$sr_json" 2>/dev/null || printf '0')"
  summary_lines="$(jq -c '.summary_lines // []' <<<"$sr_json" 2>/dev/null || printf '[]')"
  wd_json="$(afk_factory_watchdog "" "$slug_filter" "" "$dry_run" true 2>/dev/null || printf '{"actions":[]}')"

  local pc_cfg_path pc_cfg="" api_url="" company_id="" host_agent_id="" key=""
  pc_cfg_path="$(afk_pc_config_path)"
  if [[ -f "$pc_cfg_path" ]]; then
    pc_cfg="$(cat -- "$pc_cfg_path" 2>/dev/null || true)"
    api_url="$(jq -r '.api_url // empty' <<<"$pc_cfg" 2>/dev/null)"
    company_id="$(jq -r '.company_id // empty' <<<"$pc_cfg" 2>/dev/null)"
    host_agent_id="$(jq -r '.host.agent_id // empty' <<<"$pc_cfg" 2>/dev/null)"
    local key_ref
    key_ref="$(jq -r '.host.key_ref // empty' <<<"$pc_cfg" 2>/dev/null)"
    if [[ -n "$key_ref" ]]; then
      AFK_PC_CFG="$pc_cfg"
      key="$(afk_pc_read_key "$key_ref" 2>/dev/null || true)"
    fi
  fi

  if [[ -n "$api_url" && -n "$company_id" && -n "$key" ]]; then
    declare -F afk_tooling_ensure_paperclip_synced >/dev/null 2>&1 && afk_tooling_ensure_paperclip_synced
    local b_chk b_ok="true"
    if declare -F afk_pch_check_budget >/dev/null 2>&1 && [[ -n "$host_agent_id" ]]; then
      b_chk="$(afk_pch_check_budget "$api_url" "$key" "$host_agent_id")"
      # `.ok // true` is true when .ok is false: `//` replaces false as well
      # as null, so the budget stop never closed this gate.
      b_ok="$(jq -r 'if (type == "object") and (.ok == false or .state == "hard_stop") then "false" else "true" end' <<<"$b_chk" 2>/dev/null || printf 'true')"
    fi

    if [[ "$b_ok" == "true" ]]; then
      local -a proj_rows=()
      mapfile -t proj_rows < <(jq -c --arg sf "$slug_filter" '
        .projects[]?
        | select(if $sf != "" then .slug == $sf else (.factory_enabled == true) end)
      ' <<<"$pc_cfg" 2>/dev/null)

      local prow p_slug p_pid p_repo p_max
      for prow in "${proj_rows[@]:-}"; do
        [[ -n "$prow" ]] || continue
        p_slug="$(jq -r '.slug // empty' <<<"$prow")"
        p_pid="$(jq -r '.paperclip_project_id // empty' <<<"$prow")"
        p_repo="$(jq -r '.repo_path // empty' <<<"$prow")"
        p_max="$(jq -r '.max_active_issues // 1' <<<"$prow")"
        [[ -n "$p_slug" && -n "$p_pid" && -d "$p_repo" ]] || continue

        if ! declare -F afk_bmad_import_backlog >/dev/null 2>&1; then
          local _bmad_lib
          _bmad_lib="$(dirname -- "${BASH_SOURCE[0]}")/afk-bmad-import.sh"
          # shellcheck source=/dev/null
          [[ -f "$_bmad_lib" ]] && . "$_bmad_lib"
        fi
        local scope_rel=""
        scope_rel="$(_afk_factory_bmad_scope_path "$p_repo" 2>/dev/null || true)"
        if [[ "$dry_run" != "true" && -n "$scope_rel" ]] && declare -F afk_bmad_import_backlog >/dev/null 2>&1; then
          afk_bmad_import_backlog "$api_url" "$key" "$company_id" "$p_pid" \
            "$p_slug" "$p_repo" 15 "$scope_rel" >/dev/null 2>&1 || true
        fi

        # One planning reply per project per pass, before any new build is claimed.
        if [[ "$dry_run" != "true" ]] && declare -F afk_pc_pm_chat_scan_project >/dev/null 2>&1; then
          local board_user_id
          board_user_id="$(jq -r '.board_user_id // empty' <<<"$pc_cfg" 2>/dev/null)"
          afk_pc_pm_chat_scan_project "$api_url" "$key" "$company_id" "$p_pid" \
            "$host_agent_id" "$board_user_id" "$p_slug" "$p_repo" || true
        fi

        # Count active running jobs for this project
        local st_json active_cnt=0
        st_json="$(afk_factory_status "$p_repo" "$p_slug" true)"
        active_cnt="$(jq -r '[.jobs[]? | select((.stage // "") | IN("merged","needs-human","needs-info","needs-consultation","consulted","rejected") | not)] | length' <<<"$st_json" 2>/dev/null || printf '0')"
        # An unreadable status must not read as "nothing running": that
        # would lift the cap on concurrent jobs.
        [[ "$active_cnt" =~ ^[0-9]+$ ]] || continue
        [[ "$p_max" =~ ^[0-9]+$ ]] || p_max=1
        (( active_cnt < p_max )) || continue

        local l_resp l_code l_body proj_agent_ids queue_mode queue_label
        l_resp="$(afk_pc_curl GET "$api_url/api/companies/$company_id/issues?projectId=$p_pid&status=todo" "$key" "")"
        l_code="${l_resp%%$'\n'*}"
        l_body="${l_resp#*$'\n'}"
        [[ "$l_code" == 2?? ]] || continue
        proj_agent_ids="$(afk_pch_project_agent_ids_json "$p_slug")"
        [[ -n "$proj_agent_ids" ]] || proj_agent_ids='[]'
        queue_mode="$(_afk_factory_queue_mode "$p_repo")"
        queue_label="$(_afk_factory_queue_label "$p_repo")"

        local -a cand_issues=()
        mapfile -t cand_issues < <(jq -c --arg ha "$host_agent_id" --argjson ids "$proj_agent_ids" --arg queue "$queue_mode" --arg qlabel "$queue_label" '
          (if type == "array" then . else (.issues // []) end)[]?
          | select((.status // "todo") != "blocked")
          | select((((.blockedByIssueIds // .blockedBy // []) | if type == "array" then length else 0 end) == 0))
          | select(
              if $queue == "label" then
                ((.labels // []) | map(
                  if type == "string" then .
                  elif type == "object" then (.name // .slug // .label // "")
                  else "" end
                ) | index($qlabel) != null)
              else true end
            )
          | select(
              (.assigneeAgentId == null) or
              (.assigneeAgentId == "") or
              (.assigneeAgentId == $ha) or
              (.assigneeAgentId as $a | $ids | index($a) != null)
            )
        ' <<<"$l_body" 2>/dev/null)

        local iss iss_id iss_ident iss_title iss_desc iss_assignee job_id
        for iss in "${cand_issues[@]:-}"; do
          (( active_cnt < p_max )) || break
          iss_id="$(jq -r '.id // empty' <<<"$iss")"
          iss_ident="$(jq -r '.identifier // empty' <<<"$iss")"
          iss_title="$(jq -r '.title // "Factory Task"' <<<"$iss")"
          iss_desc="$(jq -r '.description // ""' <<<"$iss")"
          iss_assignee="$(jq -r '.assigneeAgentId // empty' <<<"$iss")"
          [[ -n "$iss_id" ]] || continue

          # Skip if already tracked in .afk/jobs
          if jq -e --arg iid "$iss_id" 'any(.jobs[]?; .issue_id == $iid)' <<<"$st_json" >/dev/null 2>&1; then
            continue
          fi

          job_id="$(printf '%s' "${iss_ident:-$iss_id}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-')"
          job_id="${job_id%-}"

          if [[ "$dry_run" == "true" ]]; then
            dispatched="$(jq -c --arg s "$p_slug" --arg j "$job_id" --arg i "$iss_id" \
              '. + [{slug:$s, job_id:$j, issue_id:$i, action:"would_claim"}]' <<<"$dispatched")"
            active_cnt=$((active_cnt + 1))
            continue
          fi

          # Atomic Paperclip checkout (Paperclip v2026.1106.0 requires X-Paperclip-Run-Id)
          local co_run_id co_body co_resp co_code
          co_run_id="$(afk_pch_ensure_run_id "$api_url" "$key" "$host_agent_id" "$iss_id")"
          co_body="$(jq -cn --arg a "$host_agent_id" '{agentId:$a, expectedStatuses:["todo","backlog","in_progress"]}')"
          co_resp="$(afk_pc_curl POST "$api_url/api/issues/$iss_id/checkout" "$key" "$co_run_id" "$co_body")"
          co_code="${co_resp%%$'\n'*}"
          [[ "$co_code" == 2?? ]] || continue

          [[ -f "$p_repo/.afk/config.json" ]] || afk_factory_init_repo "$p_repo" true >/dev/null 2>&1 || true
          mkdir -p "$p_repo/.afk/jobs/$job_id"
          local body_file="$p_repo/.afk/jobs/$job_id/issue.md"
          printf '# %s: %s\n\n%s\n' "${iss_ident:-$job_id}" "$iss_title" "$iss_desc" > "$body_file"

          if [[ "$bg_mode" == "true" ]]; then
            (
              AFK_FACTORY_LIVE_HARNESS="${AFK_FACTORY_LIVE_HARNESS:-1}" \
                _afk_factory_dispatch_claimed_issue "$p_repo" "$p_slug" "$job_id" "$iss_id" "$iss_title" "$body_file" "$iss_assignee" "$iss_desc" >/dev/null 2>&1
            ) &
            dispatched="$(jq -c --arg s "$p_slug" --arg j "$job_id" --arg i "$iss_id" \
              '. + [{slug:$s, job_id:$j, issue_id:$i, action:"dispatched_background"}]' <<<"$dispatched")"
            summary_lines="$(jq -c --arg m "claimed $p_slug/$job_id (background)" '. + [$m]' <<<"$summary_lines")"
          else
            local run_res f_st f_dec
            run_res="$(AFK_FACTORY_LIVE_HARNESS="${AFK_FACTORY_LIVE_HARNESS:-1}" _afk_factory_dispatch_claimed_issue "$p_repo" "$p_slug" "$job_id" "$iss_id" "$iss_title" "$body_file" "$iss_assignee" "$iss_desc")"
            f_st="$(jq -r '.stage // "unknown"' <<<"$run_res" 2>/dev/null)"
            f_dec="$(jq -r '.decision // "null"' <<<"$run_res" 2>/dev/null)"
            dispatched="$(jq -c --arg s "$p_slug" --arg j "$job_id" --arg i "$iss_id" --arg st "$f_st" --arg d "$f_dec" \
              '. + [{slug:$s, job_id:$j, issue_id:$i, action:"completed_sync", stage:$st, decision:$d}]' <<<"$dispatched")"
            summary_lines="$(jq -c --arg m "claimed $p_slug/$job_id -> $f_st ($f_dec)" '. + [$m]' <<<"$summary_lines")"
          fi
          active_cnt=$((active_cnt + 1))
        done
      done
    fi
  fi

  local auth_alerts="[]"
  if declare -F afk_router_probe_pools >/dev/null 2>&1; then
    local probe_json
    probe_json="$(afk_router_probe_pools "" 2>/dev/null || printf '{}')"
    auth_alerts="$(jq -c '.auth_alerts // []' <<<"$probe_json" 2>/dev/null || printf '[]')"
    if [[ "$(jq -r 'length' <<<"$auth_alerts" 2>/dev/null || printf '0')" -gt 0 ]]; then
      summary_lines="$(jq -c --argjson aa "$auth_alerts" \
        '. + ($aa | map("[AUTH REQUIRED] " + .pool + " (" + (.harnesses | join("+")) + "): " + (.reason // "signed out") + " -> run: " + (.reauth_command // "login")))' \
        <<<"$summary_lines" 2>/dev/null || printf '%s' "$summary_lines")"
    fi
  fi

  if [[ "$json_mode" == "true" ]]; then
    jq -cn \
      --argjson rev "$reviewed_cnt" \
      --argjson disp "$dispatched" \
      --argjson sr "$sr_json" \
      --argjson wd "$wd_json" \
      --argjson aa "$auth_alerts" \
      --argjson sl "$summary_lines" \
      '{
        schema: "afk-factory-poll/1",
        reviewed_count: $rev,
        dispatched_count: ($disp | length),
        dispatched: $disp,
        sync_reviews: $sr.actions,
        watchdog: $wd.actions,
        auth_alerts: $aa,
        summary_lines: $sl
      }'
  else
    printf 'AFK Factory Poll: reviewed=%s dispatched=%s\n' "$reviewed_cnt" "$(jq -r 'length' <<<"$dispatched")"
    jq -r '.[] | "  " + .' <<<"$summary_lines"
  fi
  return 0
}
# Summarizes active jobs, hired agents, context usage, and items needing human
# attention across projects.
# afk_factory_status [<repo>] [<slug>] [<json_mode>] [<scope>]
# scope "enabled": only projects with the factory switched on, and no scan of
# neighbouring directories. The watchdog, review sync and resume act on what
# this returns; with the wider default they kept re-running and merging jobs
# on a project whose factory had been turned off to stop it.
afk_factory_status() {
  local repo="${1:-}" slug="${2:-}" json_mode="${3:-false}" scope="${4:-all}"
  local -a repos=()
  if [[ -n "$repo" && -d "$repo" ]]; then
    repos+=("$(cd -P -- "$repo" && pwd -P)")
  else
    local pc_cfg_path
    pc_cfg_path="$(afk_pc_config_path)"
    if [[ -f "$pc_cfg_path" ]]; then
      if [[ -n "$slug" ]]; then
        mapfile -t repos < <(jq -r --arg s "$slug" '.projects[]? | select(.slug == $s) | .repo_path // empty' "$pc_cfg_path" 2>/dev/null)
      elif [[ "$scope" == "enabled" ]]; then
        mapfile -t repos < <(jq -r '(.factory_enabled == true) as $all | .projects[]? | select($all or (.factory_enabled == true)) | .repo_path // empty' "$pc_cfg_path" 2>/dev/null)
      else
        mapfile -t repos < <(jq -r '.projects[]?.repo_path // empty' "$pc_cfg_path" 2>/dev/null)
      fi
    fi
    # Also discover sibling repositories with .afk/ initialized on this host
    if [[ -z "$slug" && "$scope" != "enabled" ]]; then
      local scan_root="${AFK_REPOS_ROOT:-$(dirname -- "${AFK_KIT_ROOT:-$PWD}")}" cand_repo cand_abs seen
      for cand_repo in "$scan_root"/*; do
        [[ -d "$cand_repo/.afk" ]] || continue
        cand_abs="$(cd -P -- "$cand_repo" 2>/dev/null && pwd -P)" || continue
        seen=false
        local ex
        for ex in "${repos[@]:-}"; do
          [[ "$ex" == "$cand_abs" ]] && seen=true && break
        done
        [[ "$seen" == "false" ]] && repos+=("$cand_abs")
      done
    fi
  fi

  local jobs_list="[]" needs_human_list="[]" r jf j st
  for r in "${repos[@]:-}"; do
    [[ -n "$r" && -d "$r/.afk/jobs" ]] || continue
    for jf in "$r"/.afk/jobs/*/job.json; do
      [[ -f "$jf" ]] || continue
      j="$(cat "$jf" 2>/dev/null)" || continue
      # One truncated job file must not blank the status of every project.
      jq -e 'type == "object"' <<<"$j" >/dev/null 2>&1 || continue
      local jdir ctx_file
      jdir="$(dirname -- "$jf")"
      ctx_file="$jdir/context-ledger.json"
      if [[ -f "$ctx_file" ]]; then
        j="$(jq -c --slurpfile c "$ctx_file" '. + {context_ledger: $c[0].agents}' <<<"$j" 2>/dev/null || printf '%s' "$j")"
      fi
      jobs_list="$(jq -c --argjson item "$j" '. + [$item]' <<<"$jobs_list")"
      st="$(jq -r '.stage // empty' <<<"$j")"
      if [[ "$st" == "needs-human" || "$st" == "needs-info" || "$st" == "needs-consultation" ]]; then
        needs_human_list="$(jq -c --argjson item "$j" '. + [$item]' <<<"$needs_human_list")"
      fi
    done
  done

  local hired_ledger auth_alerts="[]"
  hired_ledger="$(afk_pch_load_ledger)"
  jq -e 'type == "object"' <<<"$hired_ledger" >/dev/null 2>&1 || hired_ledger='{"projects":{}}'
  if declare -F afk_router_probe_pools >/dev/null 2>&1; then
    local st_pools
    st_pools="$(afk_router_probe_pools "$repo" 2>/dev/null || printf '{}')"
    auth_alerts="$(jq -c '.auth_alerts // []' <<<"$st_pools" 2>/dev/null || printf '[]')"
  fi

  if [[ "$json_mode" == "true" ]]; then
    jq -cn \
      --argjson jobs "$jobs_list" \
      --argjson nh "$needs_human_list" \
      --argjson hired "$hired_ledger" \
      --argjson aa "$auth_alerts" \
      '{
        schema: "afk-factory-status/1",
        attention_required_count: ($nh | length),
        attention_required: $nh,
        auth_alerts: $aa,
        jobs: $jobs,
        hired_agents: $hired.projects
      }'
  else
    local nh_count aa_count
    nh_count="$(jq -r 'length' <<<"$needs_human_list")"
    aa_count="$(jq -r 'length' <<<"$auth_alerts")"
    printf 'AFK Factory Status: %s item(s) need human attention\n' "$nh_count"
    if (( nh_count > 0 )); then
      jq -r '.[] | "  [NEEDS HUMAN] \(.slug)/\(.id): stage=\(.stage) title=\(.title)"' <<<"$needs_human_list"
    fi
    if (( aa_count > 0 )); then
      jq -r '.[] | "  [AUTH REQUIRED] pool=\(.pool) (\(.harnesses | join("+"))): \(.reason) -> run: \(.reauth_command)"' <<<"$auth_alerts"
    fi
  fi
  return 0
}

# afk_cmd_factory <subcommand> [options...]
# Entry point called from bin/agent-flow-kit when $cmd == "factory".
afk_cmd_factory() {
  local subcmd="${1:-status}"
  if (( $# > 0 )); then shift; fi

  local json_mode=false repo="" slug="" job_id="" issue_id="" title="Factory Task"
  local body_file="" role="" used_tokens="" window_tokens="200000" compacted=false roles_csv="all"
  local stage_arg="" risk_arg="low" builder_family="" round_arg="1" surfaces_arg="" diff_lines_arg="0"
  local check_updates=false dry_run_flag=false harness_arg="" sync_flag=false free_only=false
  local sync_pc_skills=false bg_flag=false
  local mcp_mode_arg="" enable_mcp_csv="" enable_skills_csv="" litellm_url_arg=""
  local item_name="" transport_arg="stdio" target_arg="" args_csv="" desc_arg="" skill_path_arg=""
  local stale_sec_arg=""

  while (( $# > 0 )); do
    case "$1" in
      --json)                  json_mode=true ;;
      --compacted)             compacted=true ;;
      --check-updates)         check_updates=true ;;
      --dry-run)               dry_run_flag=true ;;
      --sync)                  sync_flag=true ;;
      --sync-paperclip-skills) sync_pc_skills=true ;;
      --background)            bg_flag=true ;;
      --free-only)             free_only=true ;;
      --stale-seconds)   [[ $# -ge 2 ]] || { afk_warn "--stale-seconds requires an integer"; return 1; }; stale_sec_arg="$2"; shift ;;
      --repo)            [[ $# -ge 2 ]] || { afk_warn "--repo requires a path"; return 1; }
                         # A mistyped path used to fall through to "all projects", so
                         # `factory resume --repo /typo` resumed every job on the host.
                         [[ -d "$2" ]] || { afk_warn "--repo: not a directory: $(afk_safe_diagnostic "$2")"; return 1; }
                         repo="$2"; shift ;;
      --slug)            [[ $# -ge 2 ]] || { afk_warn "--slug requires a value"; return 1; }; slug="$2"; shift ;;
      --job)             [[ $# -ge 2 ]] || { afk_warn "--job requires an id"; return 1; }; job_id="$2"; shift ;;
      --issue)           [[ $# -ge 2 ]] || { afk_warn "--issue requires an id"; return 1; }; issue_id="$2"; shift ;;
      --title)           [[ $# -ge 2 ]] || { afk_warn "--title requires text"; return 1; }; title="$2"; shift ;;
      --body-file)       [[ $# -ge 2 ]] || { afk_warn "--body-file requires a path"; return 1; }; body_file="$2"; shift ;;
      --role)            [[ $# -ge 2 ]] || { afk_warn "--role requires a role name"; return 1; }; role="$2"; shift ;;
      --used-tokens)     [[ $# -ge 2 ]] || { afk_warn "--used-tokens requires an integer"; return 1; }; used_tokens="$2"; shift ;;
      --window)          [[ $# -ge 2 ]] || { afk_warn "--window requires an integer"; return 1; }; window_tokens="$2"; shift ;;
      --roles)           [[ $# -ge 2 ]] || { afk_warn "--roles requires a comma-separated list"; return 1; }; roles_csv="$2"; shift ;;
      --stage)           [[ $# -ge 2 ]] || { afk_warn "--stage requires a stage name"; return 1; }; stage_arg="$2"; shift ;;
      --risk)            [[ $# -ge 2 ]] || { afk_warn "--risk requires low|medium|high|critical"; return 1; }; risk_arg="$2"; shift ;;
      --round)           [[ $# -ge 2 ]] || { afk_warn "--round requires an integer >= 1"; return 1; }; round_arg="$2"; shift ;;
      --surfaces)        [[ $# -ge 2 ]] || { afk_warn "--surfaces requires a comma-separated list"; return 1; }; surfaces_arg="$2"; shift ;;
      --diff-lines)      [[ $# -ge 2 ]] || { afk_warn "--diff-lines requires an integer"; return 1; }; diff_lines_arg="$2"; shift ;;
      --builder-family)  [[ $# -ge 2 ]] || { afk_warn "--builder-family requires a family name"; return 1; }; builder_family="$2"; shift ;;
      --harness)         [[ $# -ge 2 ]] || { afk_warn "--harness requires a harness name or all"; return 1; }; harness_arg="$2"; shift ;;
      --mcp-mode)        [[ $# -ge 2 ]] || { afk_warn "--mcp-mode requires litellm|standalone"; return 1; }; mcp_mode_arg="$2"; shift ;;
      --enable-mcp)      [[ $# -ge 2 ]] || { afk_warn "--enable-mcp requires a comma-separated list"; return 1; }; enable_mcp_csv="$2"; shift ;;
      --enable-skills)   [[ $# -ge 2 ]] || { afk_warn "--enable-skills requires a comma-separated list"; return 1; }; enable_skills_csv="$2"; shift ;;
      --litellm-url)     [[ $# -ge 2 ]] || { afk_warn "--litellm-url requires a URL"; return 1; }; litellm_url_arg="$2"; shift ;;
      --name)            [[ $# -ge 2 ]] || { afk_warn "--name requires an identifier"; return 1; }; item_name="$2"; shift ;;
      --transport)       [[ $# -ge 2 ]] || { afk_warn "--transport requires stdio|http|sse"; return 1; }; transport_arg="$2"; shift ;;
      --target)          [[ $# -ge 2 ]] || { afk_warn "--target requires a command or URL"; return 1; }; target_arg="$2"; shift ;;
      --args)            [[ $# -ge 2 ]] || { afk_warn "--args requires a comma-separated list"; return 1; }; args_csv="$2"; shift ;;
      --description)     [[ $# -ge 2 ]] || { afk_warn "--description requires text"; return 1; }; desc_arg="$2"; shift ;;
      --path)            [[ $# -ge 2 ]] || { afk_warn "--path requires a directory"; return 1; }; skill_path_arg="$2"; shift ;;
      *)
        afk_warn "factory $subcmd: unknown option '$(afk_safe_diagnostic "$1")'"
        return 1 ;;
    esac
    shift
  done

  # Resolve repo from slug via paperclip.json when --repo was omitted
  if [[ -z "$repo" && -n "$slug" ]]; then
    local pc_cfg_path
    pc_cfg_path="$(afk_pc_config_path)"
    if [[ -f "$pc_cfg_path" ]]; then
      repo="$(jq -r --arg s "$slug" '.projects[]? | select(.slug == $s) | .repo_path // empty' "$pc_cfg_path" 2>/dev/null)"
    fi
  fi

  case "$subcmd" in
    roster)
      if [[ -z "$repo" ]]; then
        afk_warn "factory roster requires --repo <path> or --slug <slug>"
        return 1
      fi
      local r_json
      r_json="$(afk_roster_discover "$repo")" || {
        afk_warn "factory roster: could not inspect repository $repo"
        return 1
      }
      if [[ "$json_mode" == "true" ]]; then
        printf '%s\n' "$r_json"
      else
        jq -r '"Project Roster (\(.framework)) for \(.repo_path):", (.agents[] | "  - \(.role) [\(.persona_name)]: \(.title) -> \(.skill_path)")' <<<"$r_json"
      fi
      return 0 ;;
    init)
      if [[ -z "$repo" ]]; then
        afk_warn "factory init requires --repo <path> or --slug <slug>"
        return 1
      fi
      afk_factory_init_repo "$repo" "$json_mode"
      return $? ;;
    run)
      if [[ -z "$repo" ]]; then
        afk_warn "factory run requires --repo <path> or --slug <slug>"
        return 1
      fi
      afk_factory_run_job "$repo" "$slug" "$job_id" "$issue_id" "$title" "$body_file" "$json_mode"
      return $? ;;
    evaluate-merge)
      if [[ -z "$repo" || -z "$job_id" ]]; then
        afk_warn "factory evaluate-merge requires --repo <path> and --job <id>"
        return 1
      fi
      local me_out
      me_out="$(afk_factory_evaluate_merge "$repo" "$repo/.afk/jobs/$job_id")" || return 1
      if [[ "$json_mode" == "true" ]]; then
        printf '%s\n' "$me_out"
      else
        jq -r '"Decision: \(.decision) (gate=\(.gate_verdict), reviews=\(.reviews_count), diff=\(.diff_lines)L/\(.diff_files)F)"' <<<"$me_out"
      fi
      return 0 ;;
    context-check)
      if [[ -z "$repo" || -z "$job_id" || -z "$role" || -z "$used_tokens" ]]; then
        afk_warn "factory context-check requires --repo, --job, --role, and --used-tokens"
        return 1
      fi
      local cc_out act new_gen
      cc_out="$(afk_roster_record_and_check_context "$repo/.afk/jobs/$job_id" "$role" "$used_tokens" "$window_tokens" "$compacted" "$repo")" \
        || { afk_warn "factory context-check: the context ledger could not be read or saved"; return 1; }
      act="$(jq -r '.action' <<<"$cc_out")"
      if [[ "$act" == "replaced" && -n "$slug" ]]; then
        new_gen="$(jq -r '.active_generation' <<<"$cc_out")"
        afk_pch_replace_agent_session "$slug" "$role" "$new_gen" "$issue_id" "context threshold reached" "" ""
      fi
      if [[ "$json_mode" == "true" ]]; then
        printf '%s\n' "$cc_out"
      else
        jq -r '"Context check [\(.role)]: status=\(.status) action=\(.action) gen=\(.previous_generation)->\(.active_generation) (\(.ratio_decimal))"' <<<"$cc_out"
      fi
      return 0 ;;
    retire)
      if [[ -z "$slug" ]]; then
        afk_warn "factory retire requires --slug <slug>"
        return 1
      fi
      local ret_out
      ret_out="$(afk_pch_retire_project_agents "$slug" "$roles_csv")"
      if [[ "$json_mode" == "true" ]]; then
        printf '%s\n' "$ret_out"
      else
        printf 'Retired agents for %s: %s\n' "$slug" "$(jq -c '.' <<<"$ret_out")"
      fi
      return 0 ;;
    resume)
      afk_factory_resume "$repo" "$slug" "$json_mode"
      return $? ;;
    watchdog)
      afk_factory_watchdog "$repo" "$slug" "$stale_sec_arg" "$dry_run_flag" "$json_mode"
      return $? ;;
    sync-reviews)
      afk_factory_sync_reviews "$repo" "$slug" "$dry_run_flag" "$json_mode"
      return $? ;;
    poll)
      afk_factory_poll_paperclip "$slug" "$dry_run_flag" "$bg_flag" "$json_mode"
      return $? ;;
    import-backlog)
      if [[ -z "$repo" || -z "$slug" ]]; then
        afk_warn "factory import-backlog requires --repo <path> and --slug <slug>"
        return 1
      fi
      if ! declare -F afk_bmad_import_backlog >/dev/null 2>&1; then
        local _bmad_lib
        _bmad_lib="$(dirname -- "${BASH_SOURCE[0]}")/afk-bmad-import.sh"
        # shellcheck source=/dev/null
        [[ -f "$_bmad_lib" ]] && . "$_bmad_lib"
      fi
      local pc_cfg_path pc_cfg api_url company_id project_id key
      pc_cfg_path="$(afk_pc_config_path)"
      [[ -f "$pc_cfg_path" ]] || { afk_warn "factory import-backlog: no Paperclip config"; return 1; }
      pc_cfg="$(cat -- "$pc_cfg_path")"
      api_url="$(jq -r '.api_url // empty' <<<"$pc_cfg")"
      company_id="$(jq -r '.company_id // empty' <<<"$pc_cfg")"
      project_id="$(jq -r --arg s "$slug" '(.projects[]? | select(.slug == $s) | .paperclip_project_id) // empty' <<<"$pc_cfg")"
      local key_ref
      key_ref="$(jq -r '.host.key_ref // empty' <<<"$pc_cfg")"
      AFK_PC_CFG="$pc_cfg"
      key="$(afk_pc_read_key "$key_ref" 2>/dev/null || true)"
      local scope_rel
      scope_rel="$(_afk_factory_bmad_scope_path "$repo" 2>/dev/null || true)"
      if [[ -z "$scope_rel" ]]; then
        printf '{"created":0,"skipped":0,"reason":"scope_paths"}\n'
        return 0
      fi
      afk_bmad_import_backlog "$api_url" "$key" "$company_id" "$project_id" "$slug" "$repo" 0 "$scope_rel"
      return $? ;;
    pools)
      local p_out
      p_out="$(afk_router_probe_pools "$repo")"
      if [[ "$json_mode" == "true" ]]; then
        printf '%s\n' "$p_out"
      else
        jq -r '
          (if ((.auth_alerts // []) | length) > 0 then
            "Auth & Sign-In Alerts:",
            (.auth_alerts[] | "  [AUTH REQUIRED] pool=\(.pool) (\(.harnesses | join("+"))): \(.reason) -> run: \(.reauth_command)"),
            ""
          else empty end),
          "Installed Harnesses & Gateways:",
          "  - claude   (Anthropic Max OAuth): " + (if .harnesses.claude.installed then "HEALTHY (" + .harnesses.claude.binary + ")" else "UNAVAILABLE (" + (.harnesses.claude.health // "missing") + ")" end),
          "  - codex    (OpenAI Plus/Pro):     " + (if .harnesses.codex.installed then "HEALTHY (" + .harnesses.codex.binary + ")" else "UNAVAILABLE (" + (.harnesses.codex.health // "missing") + ")" end),
          "  - agy      (Antigravity):         " + (if .harnesses.agy.installed then "HEALTHY (" + .harnesses.agy.binary + ")" else "UNAVAILABLE (" + (.harnesses.agy.health // "missing") + ")" end),
          "  - grok     (xAI Grok CLI):        " + (if .harnesses.grok.installed then "HEALTHY (" + .harnesses.grok.binary + ")" else "UNAVAILABLE (" + (.harnesses.grok.health // "missing") + ")" end),
          "  - opencode (Free + Bridged OAuth):" + (if .harnesses.opencode.installed then " HEALTHY (" + .harnesses.opencode.binary + ")" else " UNAVAILABLE (" + (.harnesses.opencode.health // "missing") + ")" end),
          "  - pi       (Multi-Auth CLI):      " + (if .harnesses.pi.installed then "HEALTHY (" + .harnesses.pi.binary + ")" else "UNAVAILABLE (" + (.harnesses.pi.health // "missing") + ")" end),
          "  - devin    (Cognition Devin CLI): " + (if .harnesses.devin.installed then "HEALTHY (" + .harnesses.devin.binary + ")" else "UNAVAILABLE (" + (.harnesses.devin.health // "missing") + ")" end),
          "  - litellm  (Local AI Cluster GW): " + (if .harnesses.litellm_gateway.online then "ONLINE (" + (.harnesses.litellm_gateway.base_url // "") + ")" elif .harnesses.litellm_gateway.configured then "OFFLINE (" + (.harnesses.litellm_gateway.base_url // "") + ")" else "NOT_CONFIGURED (set AFK_LITELLM_BASE_URL or .router.litellm_base_url)" end),
          "",
          "Entitlement & Subscription Pools (Live Provider Quota, TTL Signals & Shared Accounts):",
          (.pools | to_entries[] | "  - " + .key + " [" + .value.provider + " / " + .value.pool_tier + " / cost=" + .value.cost_class + "]: state=" + .value.state + " used=" + (.value.used_pct|tostring) + "% remaining=" + (.value.remaining_units_5h|tostring) + "/" + (.value.capacity_5h|tostring) + " (" + (.value.headroom_pct|tostring) + "% free, src=" + (.value.quota_source // "local") + (if .value.weekly_used_pct != null then ", weekly=" + (.value.weekly_used_pct|tostring) + "%" else "" end) + (if .value.fable_weekly_used_pct != null then ", fable_weekly=" + (.value.fable_weekly_used_pct|tostring) + "%" else "" end) + (if .value.resets_at != null then ", resets=" + (.value.resets_at | sub("\\.[0-9]+"; "")) else "" end) + (if .value.degraded_reason != null then ", reason=" + (.value.degraded_reason[0:56]) else "" end) + ", harnesses=" + ((.value.harnesses_feeding_pool // []) | join("+")) + ")")
        ' <<<"$p_out"
      fi
      return 0 ;;
    harnesses)
      local h_out
      h_out="$(afk_harness_inspect_all "$check_updates")"
      if [[ "$json_mode" == "true" ]]; then
        printf '%s\n' "$h_out"
      else
        jq -r '
          "Host Harness Lifecycle Inventory (os=\(.os), checked=\(.checked_at)):",
          (if ((.auth_alerts // []) | length) > 0 then
            (.auth_alerts[] | "  [AUTH ALERT] \(.harness): auth=\(.auth_state) (\(.reason // "sign-in required")) -> run: \(.reauth_command)")
          else empty end),
          (.harnesses[] |
            if .present_on_disk then
              "  - \(.harness): " +
              (if .healthy then "HEALTHY" else "NEEDS_REPAIR (\(.health))" end) +
              " | auth=" + (.auth_state // "unknown") +
              " | method=\(.install_method) | pkg=\(.package_name)" +
              " | version=\(.current_version // "unknown")" +
              (if .latest_version != null then " -> latest=\(.latest_version)" else "" end) +
              (if .update_available then " [UPDATE/REPAIR AVAILABLE]" else "" end) +
              "\n      bin=\(.binary_path) -> \(.resolved_path)" +
              "\n      effort_dial: " + (if .effort_dial.supports_effort then "\(.effort_dial.cli_flag) [\((.effort_dial.supported_efforts // []) | join(","))]" else "none" end) +
              "\n      update_cmd: \(.update_command)" +
              (if (.signed_in == false) and (.reauth_command // "") != "" then "\n      reauth_cmd: \(.reauth_command) (\(.auth_reason // "sign-in required"))" else "" end)
            else
              "  - \(.harness): NOT_INSTALLED"
            end
          )
        ' <<<"$h_out"
      fi
      return 0 ;;
    update-harnesses)
      local uh_target="${harness_arg:-all}" uh_out
      uh_out="$(afk_harness_update "$uh_target" "$dry_run_flag")"
      if [[ "$json_mode" == "true" ]]; then
        printf '%s\n' "$uh_out"
      else
        jq -r '
          "Harness Update Report (dry_run=\(.dry_run), at=\(.updated_at)):",
          (.results[] | "  - \(.harness): action=\(.action) method=\(.install_method // "n/a") version=\(.before_version // "-") -> \(.after_version // .before_version // "-") | cmd=\(.command // .reason // "-")"),
          (if .model_catalog_refresh != null then "  -> Refreshed live model catalog: \(.model_catalog_refresh.total_models) models (\(.model_catalog_refresh.free_models) free, \(.model_catalog_refresh.subscription_models) subscription)" else empty end)
        ' <<<"$uh_out"
      fi
      return 0 ;;
    models)
      local dm_path dm_out
      dm_path="$(afk_harness_discovered_models_path)"
      if [[ "$sync_flag" == "true" || ! -f "$dm_path" ]]; then
        dm_out="$(afk_harness_sync_models)"
      else
        dm_out="$(cat -- "$dm_path")"
      fi
      if [[ -n "$harness_arg" ]]; then
        dm_out="$(jq -c --arg h "$harness_arg" '.models |= map(select(.harness == $h))' <<<"$dm_out")"
      fi
      if [[ "$free_only" == "true" ]]; then
        dm_out="$(jq -c '.models |= map(select(.is_free == true))' <<<"$dm_out")"
      fi
      if [[ "$json_mode" == "true" ]]; then
        printf '%s\n' "$dm_out"
      else
        jq -r '
          "Discovered Harness Models & Shared Pool Topology (synced=\(.synced_at)):",
          "  Summary: total=\(.summary.total_models) | FREE($0)=\(.summary.free_models) | OAuth-Subscription=\(.summary.subscription_models) | Metered-API(gated)=\(.summary.metered_api_models)",
          "",
          "  Shared Pool & Account Bindings:",
          (.shared_pool_topology[] | "    * pool=\(.entitlement_pool) [cost=\(.cost_class)] <- harnesses=[\(.harnesses_feeding_pool | join(", "))] accounts=[\(.account_fingerprints | join(", "))]" + (if .shared_across_harnesses then " (SHARED ACROSS HARNESSES)" else "" end)),
          "",
          "  Harness Effort Dials:",
          ((.harness_effort_dials // {}) | to_entries[] | "    * \(.key): " + (if .value.supports_effort then "\(.value.cli_flag) [\((.value.supported_efforts // []) | join(","))]" else "none" end)),
          "",
          "  Models (\( .models | length ) shown):",
          (.models[] | "    - [\(.harness)] \(.model) | cost=\(.cost_class)" + (if .cost_class == "api-metered" then " ($\(.cost_per_1m_usd.input)/$\(.cost_per_1m_usd.output) per 1M)" elif .is_free then " ($0 FREE)" else "" end) + " | pool=\(.entitlement_pool) | ctx=\(.window_tokens) | efforts=[\((.supported_efforts // ["medium"]) | join(","))] | coding=\(.benchmarks.coding_standard.score) | best_for=[\(.recommended_purposes | join(","))]")
        ' <<<"$dm_out"
      fi
      return 0 ;;
    tooling)
      if [[ "$sync_pc_skills" == "true" ]]; then
        local pcs_out
        pcs_out="$(afk_tooling_sync_paperclip_skills)" || return 1
        if [[ "$json_mode" == "true" ]]; then
          printf '%s\n' "$pcs_out"
        else
          jq -r '"Synced \(.synced_count) skill(s) from Paperclip Skills Studio into \(.skills_dir) (skipped_bundled=\(.skipped_bundled_count // 0), central_mcp=\(.central_source_skill // "none")): \([.synced_skills[].slug] | if length > 0 then join(", ") else "none" end)"' <<<"$pcs_out"
        fi
        return 0
      fi
      local tl_out
      tl_out="$(afk_tooling_discover "$repo" "$slug")"
      if [[ "$json_mode" == "true" ]]; then
        printf '%s\n' "$tl_out"
      else
        jq -r '
          "AFK Skills & MCP Tooling Inventory (source=\(.config_source), mcp_mode=\(.mcp_mode), litellm_mcp=\(.litellm_mcp_url // "none")):",
          (if .paperclip_central != null then
            "  Paperclip Central Studio (synced=\(.paperclip_central.synced_at), bundle=\(.paperclip_central.source_skill // "none")):\n    - Central MCPs: \([.paperclip_central.enabled_mcp[]?] | if length > 0 then join(", ") else "none" end) | Attached/Central Skills: \([(.paperclip_central.enabled_skills // [])[], (.paperclip_central.desired_skills // [])[]] | unique | if length > 0 then join(", ") else "none" end)"
          else
            "  Paperclip Central Studio: not synced (standalone host mode)"
          end),
          "  Project (\(.repo_path // "none")):",
          "    - Skills: \(.project.skills_count) total (\(.project.non_bmad_skills_count) non-BMAD custom)",
          "    - MCP Servers (\(.project.mcp_count)): \([.project.mcp_servers[].name] | if length > 0 then join(", ") else "none" end)",
          "  Host & Central Catalog:",
          "    - Host Skills (\(.host.skills_count)): \([.host.skills[].name] | if length > 0 then join(", ") else "none" end)",
          "    - Host MCP Servers (\(.host.mcp_count)): \([.host.mcp_servers[].name] | if length > 0 then join(", ") else "none" end)",
          "    - AFK Central Registry: mcp=[\(.central_catalog.mcp_servers | join(", "))] skills=[\(.central_catalog.skills | join(", "))]"
        ' <<<"$tl_out"
      fi
      return 0 ;;
    tooling-sync)
      if [[ -z "$repo" ]]; then
        afk_warn "factory tooling-sync requires --repo <path> or --slug <slug>"
        return 1
      fi
      local ts_out
      ts_out="$(afk_tooling_sync_project "$repo" "$mcp_mode_arg" "$enable_mcp_csv" "$enable_skills_csv" "$litellm_url_arg" "$slug")"
      if [[ "$json_mode" == "true" ]]; then
        printf '%s\n' "$ts_out"
      else
        jq -r '"Synced tooling to \(.repo_path) (source=\(.config_source), mcp_mode=\(.mcp_mode)): mcp=[\(.synced_mcp_servers | join(", "))] skills=[\(.synced_skills | join(", "))]"' <<<"$ts_out"
      fi
      return 0 ;;
    tooling-publish-paperclip)
      local pub_slug="${item_name:-afk-fleet-tooling}" tp_out
      tp_out="$(afk_tooling_publish_paperclip "$mcp_mode_arg" "$litellm_url_arg" "$enable_mcp_csv" "$enable_skills_csv" "$pub_slug")" || return 1
      if [[ "$json_mode" == "true" ]]; then
        printf '%s\n' "$tp_out"
      else
        jq -r '"Published Paperclip Studio bundle \(.skill_slug) (\(.skill_id)): mcp_mode=\(.mcp_mode) litellm_mcp=\(.litellm_mcp_url // "none") mcp=[\(.enabled_mcp | join(", "))] skills=[\(.enabled_skills | join(", "))] attached_to_host=\(.attached_to_host_agent)"' <<<"$tp_out"
      fi
      return 0 ;;
    tooling-register-mcp)
      if [[ -z "$item_name" || -z "$target_arg" ]]; then
        afk_warn "factory tooling-register-mcp requires --name <id> and --target <cmd_or_url>"
        return 1
      fi
      local rm_out
      rm_out="$(afk_tooling_register_mcp "$item_name" "$transport_arg" "$target_arg" "$args_csv" "$desc_arg")"
      if [[ "$json_mode" == "true" ]]; then
        printf '%s\n' "$rm_out"
      else
        jq -r '"Registered central MCP server \(.name) (\(.transport))"' <<<"$rm_out"
      fi
      return 0 ;;
    tooling-register-skill)
      if [[ -z "$item_name" || -z "$skill_path_arg" ]]; then
        afk_warn "factory tooling-register-skill requires --name <id> and --path <skill_dir>"
        return 1
      fi
      local rs_out
      rs_out="$(afk_tooling_register_skill "$item_name" "$skill_path_arg" "$desc_arg")"
      if [[ "$json_mode" == "true" ]]; then
        printf '%s\n' "$rs_out"
      else
        jq -r '"Registered central skill \(.name) -> \(.path)"' <<<"$rs_out"
      fi
      return 0 ;;
    route-preview)
      if [[ -n "$stage_arg" ]]; then
        local rp_out
        rp_out="$(afk_router_select_candidate "$repo" "$stage_arg" "$risk_arg" "$builder_family" "$role" "$round_arg" "$surfaces_arg" "$diff_lines_arg")"
        if [[ "$json_mode" == "true" ]]; then
          printf '%s\n' "$rp_out"
        else
          jq -r '"Stage [\(.stage)] (task_class=\(.task_class), risk=\(.risk), role=\(.role // "-"), round=\(.round // 1)):\n  -> Harness/Launch: \(.harness) (\(.launch_class))\n  -> Model/Pool:     \(.model) [\(.canonical_model)] via pool \(.entitlement_pool) (\(.pool_remaining_5h)/\(.pool_capacity_5h) free, \(.pool_headroom_pct)%)\n  -> Effort Dial:    \(.effort) [supported: \((.supported_efforts // []) | join(","))] (escalated=\(.effort_escalated): \(.effort_reason))\n  -> Benchmark:      \(.benchmark_name) = \(.benchmark_score) (effective=\(.effective_score), synced=\(.benchmark_synced_at // "bundled"))\n  -> Memory Mode:    \(.memory_mode)\n  -> Reason:         \(.reason)"' <<<"$rp_out"
        fi
      else
        local -a st_list=("intake" "spec" "ux" "build" "review-code")
        if [[ ",$surfaces_arg," == *",security,"* ]]; then
          st_list+=("review-security")
        fi
        local all_routes="[]" b_fam="$builder_family"
        local s s_role r_item
        for s in "${st_list[@]}"; do
          s_role="$role"
          if [[ -z "$s_role" ]]; then
            case "$s" in
              intake) s_role="pm" ;;
              spec)   [[ "$risk_arg" == "high" || "$risk_arg" == "critical" ]] && s_role="architect" || s_role="pm" ;;
              ux)     s_role="ux-designer" ;;
              build)  s_role="dev" ;;
              review-*) s_role="reviewer" ;;
            esac
          fi
          r_item="$(afk_router_select_candidate "$repo" "$s" "$risk_arg" "$b_fam" "$s_role" "$round_arg" "$surfaces_arg" "$diff_lines_arg")"
          if [[ "$s" == "build" && -z "$b_fam" ]]; then
            b_fam="$(jq -r '.model_family // empty' <<<"$r_item")"
          fi
          all_routes="$(jq -c --argjson it "$r_item" '. + [$it]' <<<"$all_routes")"
        done
        if [[ "$json_mode" == "true" ]]; then
          printf '%s\n' "$all_routes"
        else
          jq -r '.[] | "[\(.stage)] (\(.task_class), risk=\(.risk), round=\(.round // 1)) -> \(.harness)/\(.model) [\(.launch_class), effort=\(.effort)] | pool=\(.entitlement_pool) (\(.pool_remaining_5h)/\(.pool_capacity_5h) free, \(.pool_headroom_pct)%) | score=\(.effective_score) (\(.benchmark_name)) | mem=\(.memory_mode)"' <<<"$all_routes"
        fi
      fi
      return 0 ;;
    sync-benchmarks)
      local sb_out
      sb_out="$(afk_router_sync_benchmarks)"
      if [[ "$json_mode" == "true" ]]; then
        printf '%s\n' "$sb_out"
      else
        jq -r '"Public Benchmark Sync Complete (\(.synced_at)):\n  - Catalog Snapshot:     \(.catalog_path) (\(.candidates_count) candidates)\n  - LMArena Agent:        \(.feeds.lmarena_agent)\n  - LMArena WebDev:       \(.feeds.lmarena_webdev)\n  - LMArena Reasoning:    \(.feeds.lmarena_text)\n  - SWE-bench Official:   \(.feeds.swe_bench_official)\n  - models.dev Limits:    \(.feeds.models_dev)\n  - Artificial Analysis:  \(.feeds.artificial_analysis)"' <<<"$sb_out"
      fi
      return 0 ;;
    status)
      afk_factory_status "$repo" "$slug" "$json_mode"
      return $? ;;
    *)
      afk_warn "factory: unknown subcommand '$(afk_safe_diagnostic "$subcmd")' (expected: roster, init, run, poll, sync-reviews, resume, watchdog, pools, harnesses, update-harnesses, models, tooling, tooling-sync, tooling-publish-paperclip, tooling-register-mcp, tooling-register-skill, route-preview, sync-benchmarks, status, context-check, evaluate-merge, retire)"
      return 1 ;;
  esac
}
