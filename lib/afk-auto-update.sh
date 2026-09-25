#!/usr/bin/env bash
# afk-auto-update.sh — `agent-flow-kit enroll-auto-update`: enroll this host
# once so the release client runs on a schedule instead of from a runbook.
#
# Linux: a systemd USER service and timer run the installed
# `afk-release-reconcile --apply` every check_interval_seconds.
# macOS: the release client refuses by design (MACOS_SANDBOX_PENDING), so a
# launchd user agent runs `enroll-auto-update --check`, which compares the
# trusted ref against the applied revision and records the answer. It never
# fetches objects, never runs candidate code and never applies.
#
# The deploy key is read from the host's own 1Password reference straight into
# a private temporary file beside its destination, its fingerprint is compared
# with the one the kit policy pins, and only then is it moved into place. Its
# bytes never reach stdout, stderr, a log, the config or a state file.
#
# The unit and agent texts below are the templates. They ship in the managed
# lib tree, so the lifecycle installs and verifies them like any other code;
# the rendered files are owned by this command, which re-renders or removes
# them.

AFK_AU_UNIT="afk-release-reconcile"
AFK_AU_LABEL="io.github.jlengelbrecht.agent-flow-kit.update-check"
# Upper bound on one scheduled run: fetch, qualification and lifecycle apply.
AFK_AU_TIMEOUT_SECONDS=600

afk_au_paths() {
  AFK_AU_POLICY="${AFK_RELEASE_POLICY:-$AFK_INSTALL_ROOT/lifecycle/release-policy.json}"
  AFK_AU_CONFIG="${AFK_AUTO_UPDATE_CONFIG:-${HOME:+$HOME/.config/agent-flow-kit/auto-update.json}}"
  # An explicit key wins, then the path enrollment recorded, then the default.
  AFK_AU_KEY="${AFK_RELEASE_DEPLOY_KEY:-}"
  if [[ -z "$AFK_AU_KEY" && -n "$AFK_AU_CONFIG" && -r "$AFK_AU_CONFIG" ]]; then
    AFK_AU_KEY="$(jq -r '.key_path | strings | select(startswith("/"))' "$AFK_AU_CONFIG" 2>/dev/null)"
  fi
  AFK_AU_KEY="${AFK_AU_KEY:-${HOME:+$HOME/.config/agent-flow-kit/deploy-key/agent-flow-kit_ed25519}}"
  AFK_AU_CHECK_STATE="$AFK_STATE_DIR/auto-update-check.json"
  AFK_AU_RUNTIME_BIN="$AFK_SKILLS_HOME/afk-runtime/bin"
  AFK_AU_SYSTEMD_DIR="${AFK_SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/systemd/user}"
  AFK_AU_LAUNCHD_DIR="${AFK_LAUNCHD_DIR:-${HOME:-}/Library/LaunchAgents}"
  AFK_AU_OP="${AFK_OP_BIN:-op}"
  case "${AFK_AUTO_UPDATE_PLATFORM:-$(uname -s)}" in
    linux|Linux)   AFK_AU_PLATFORM=linux;  AFK_AU_SCHEDULER="$AFK_AU_SYSTEMD_DIR/$AFK_AU_UNIT.timer" ;;
    darwin|Darwin) AFK_AU_PLATFORM=darwin; AFK_AU_SCHEDULER="$AFK_AU_LAUNCHD_DIR/$AFK_AU_LABEL.plist" ;;
    *)             AFK_AU_PLATFORM=unsupported; AFK_AU_SCHEDULER="" ;;
  esac
}

afk_au_interval() {
  local v
  v="$(jq -r '.check_interval_seconds // empty' "$AFK_AU_POLICY" 2>/dev/null)"
  if [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 60 )); then printf '%s\n' "$v"; else printf '900\n'; fi
}

# afk_au_ready — what the scheduled job will run must already be installed:
# the release client (Linux) or the kit command (macOS), the policy and the
# pinned known-hosts file. Checked before the key or any scheduler is touched.
afk_au_ready() {
  local missing="" runner="afk-release-reconcile"
  [[ "$AFK_AU_PLATFORM" == darwin ]] && runner="agent-flow-kit"
  [[ -x "$AFK_AU_RUNTIME_BIN/$runner" ]] || missing+=" $AFK_AU_RUNTIME_BIN/$runner"
  [[ -r "$AFK_AU_POLICY" ]] || missing+=" $AFK_AU_POLICY"
  [[ -s "$AFK_AU_RUNTIME_BIN/afk-release-known-hosts" ]] || missing+=" $AFK_AU_RUNTIME_BIN/afk-release-known-hosts"
  [[ -z "$missing" ]] && return 0
  afk_warn "enroll-auto-update: NOT_READY: missing or not executable:$missing (run agent-flow-kit update first); nothing was changed"
  return 1
}

# afk_au_put <path> <content> [umask] — write only when the content differs.
afk_au_put() {
  if [[ -f "$1" && "$(cat -- "$1")" == "$2" ]]; then return 0; fi
  (umask "${3:-022}" && mkdir -p -- "${1%/*}" && printf '%s\n' "$2" >"$1.tmp.$$" && mv -f -- "$1.tmp.$$" "$1")
}

afk_au_xml() { local s="${1//&/"&amp;"}"; s="${s//</"&lt;"}"; printf '%s' "${s//>/"&gt;"}"; }
afk_au_shq() { local q="'" e="'\\''"; printf "'%s'" "${1//"$q"/"$e"}"; }

# A regular file may be overwritten and a symlink replaced (never followed);
# anything else at the key path is refused.
afk_au_key_path_free() {
  if [[ -e "$AFK_AU_KEY" && ! -L "$AFK_AU_KEY" && ! -f "$AFK_AU_KEY" ]]; then
    afk_warn "enroll-auto-update: KEY_PATH_OCCUPIED: $AFK_AU_KEY exists and is not a regular file; nothing was installed"
    return 1
  fi
}

afk_au_install_key() { # <key-ref> — prints installed|unchanged
  local pinned dir
  pinned="$(jq -er '.deploy_key_fingerprint | select(type == "string" and startswith("SHA256:"))' \
    "$AFK_AU_POLICY" 2>/dev/null)" || {
    afk_warn "enroll-auto-update: POLICY_UNTRUSTED: the kit policy pins no deploy_key_fingerprint; nothing was installed"; return 1; }
  if ! command -v "$AFK_AU_OP" >/dev/null 2>&1; then
    afk_warn "enroll-auto-update: OP_UNAVAILABLE: the 1Password CLI (op) is not on PATH; nothing was installed"; return 1
  fi
  case "$AFK_AU_KEY" in
    "$AFK_SKILLS_HOME"/*|"$AFK_STATE_DIR"/*)
      afk_warn "enroll-auto-update: the deploy key path is inside a managed tree; nothing was installed"; return 1 ;;
  esac
  afk_au_key_path_free || return 1
  dir="${AFK_AU_KEY%/*}"
  (umask 077 && mkdir -p -- "$dir") || { afk_warn "enroll-auto-update: the deploy key directory could not be created"; return 1; }
  # A subshell owns the scratch copy, so its EXIT trap removes it on every way
  # out — a refusal, a failed command or a signal — without touching the
  # executable's own traps.
  (
    tmp="" fp=""
    trap 'rm -f -- "$tmp"' EXIT
    trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
    tmp="$(umask 077 && mktemp "$dir/.afk-enroll.XXXXXX")" || { afk_warn "enroll-auto-update: no private scratch file"; exit 1; }
    if ! (umask 077 && "$AFK_AU_OP" read "$1" >"$tmp" 2>/dev/null </dev/null) || [[ ! -s "$tmp" ]]; then
      afk_warn "enroll-auto-update: KEY_REF_UNREADABLE: op could not read that reference (signed in? right vault?); nothing was installed"
      exit 1
    fi
    fp="$(ssh-keygen -l -f "$tmp" </dev/null 2>/dev/null | awk '{print $2; exit}')"
    if [[ "$fp" != SHA256:* ]]; then
      afk_warn "enroll-auto-update: KEY_UNPARSEABLE: the value at that reference is not an SSH private key; nothing was installed"
      exit 1
    fi
    if [[ "$fp" != "$pinned" ]]; then
      afk_warn "enroll-auto-update: FINGERPRINT_MISMATCH: the key at that reference is not the pinned deploy key ($pinned); nothing was installed"
      exit 1
    fi
    afk_au_key_path_free || exit 1
    chmod 600 "$tmp" || exit 1
    if [[ -f "$AFK_AU_KEY" && ! -L "$AFK_AU_KEY" ]] && cmp -s "$tmp" "$AFK_AU_KEY"; then
      chmod 600 "$AFK_AU_KEY"; printf 'unchanged\n'; exit 0
    fi
    # mv onto a symlink to a directory would move INTO it; drop the link first.
    if [[ -L "$AFK_AU_KEY" ]]; then rm -f -- "$AFK_AU_KEY" || exit 1; fi
    mv -f -- "$tmp" "$AFK_AU_KEY" || { afk_warn "enroll-auto-update: the deploy key could not be moved into place"; exit 1; }
    tmp=""
    printf 'installed\n'
  )
}

# afk_au_key_path_valid — the same class the release client refuses in an ssh
# option path, plus `$` and control characters, which a unit would expand.
afk_au_key_path_valid() {
  case "$AFK_AU_KEY" in
    /*) : ;;
    *) afk_warn "enroll-auto-update: the deploy key path must be absolute; nothing was installed"; return 1 ;;
  esac
  case "$AFK_AU_KEY" in
    *[[:space:][:cntrl:]\'\"\\%#\$]*)
      afk_warn "enroll-auto-update: KEY_PATH_UNSAFE: the deploy key path may not contain whitespace, quotes, backslash, %, # or \$; nothing was installed"
      return 1 ;;
  esac
}

# afk_au_sd — a value as systemd reads it: `%` starts a specifier.
afk_au_sd() { printf '%s' "${1//"%"/"%%"}"; }

afk_au_write_config() { # <key-ref> — the reference, never the key
  local content
  content="$(jq -n --arg ref "$1" --arg key "$AFK_AU_KEY" --arg platform "$AFK_AU_PLATFORM" \
    '{schema: "afk-auto-update/1", key_ref: $ref, key_path: $key, platform: $platform}')" || return 1
  afk_au_put "$AFK_AU_CONFIG" "$content" 077
}

afk_au_systemd_service() {
  printf '%s\n' \
    '# Managed by agent-flow-kit enroll-auto-update; re-run it rather than editing.' \
    '[Unit]' 'Description=agent-flow-kit release reconcile' '' \
    '[Service]' 'Type=oneshot' \
    "Environment=\"AFK_STATE_DIR=$(afk_au_sd "$AFK_STATE_DIR")\"" \
    "Environment=\"AFK_RELEASE_DEPLOY_KEY=$(afk_au_sd "$AFK_AU_KEY")\"" \
    "ExecStart=\"$(afk_au_sd "$AFK_AU_RUNTIME_BIN")/afk-release-reconcile\" --apply" \
    "TimeoutStartSec=$AFK_AU_TIMEOUT_SECONDS"
}

afk_au_systemd_timer() { # <interval>
  printf '%s\n' \
    '# Managed by agent-flow-kit enroll-auto-update; re-run it rather than editing.' \
    '[Unit]' 'Description=agent-flow-kit release reconcile timer' '' \
    '[Timer]' "OnActiveSec=$1" "OnUnitActiveSec=$1" 'Persistent=true' '' \
    '[Install]' 'WantedBy=timers.target'
}

afk_au_launchd_plist() { # <interval> — CHECK ONLY: the agent never applies
  printf '%s\n' \
    '<?xml version="1.0" encoding="UTF-8"?>' \
    '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    '<!-- Managed by agent-flow-kit enroll-auto-update. Check only: it never applies. -->' \
    '<plist version="1.0"><dict>' \
    "  <key>Label</key><string>$AFK_AU_LABEL</string>" \
    '  <key>ProgramArguments</key><array>' \
    "    <string>$(afk_au_xml "$AFK_AU_RUNTIME_BIN/agent-flow-kit")</string>" \
    '    <string>enroll-auto-update</string><string>--check</string>' \
    '  </array>' \
    '  <key>EnvironmentVariables</key><dict>' \
    '    <key>PATH</key><string>/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin</string>' \
    "    <key>AFK_STATE_DIR</key><string>$(afk_au_xml "$AFK_STATE_DIR")</string>" \
    "    <key>AFK_RELEASE_DEPLOY_KEY</key><string>$(afk_au_xml "$AFK_AU_KEY")</string>" \
    '  </dict>' \
    "  <key>StartInterval</key><integer>$1</integer>" \
    '  <key>RunAtLoad</key><true/>' \
    '</dict></plist>'
}

# afk_au_scheduler_enabled — asks the scheduler, not the file system.
afk_au_scheduler_enabled() {
  [[ -n "$AFK_AU_SCHEDULER" && -f "$AFK_AU_SCHEDULER" ]] || return 1
  case "$AFK_AU_PLATFORM" in
    linux)  [[ "$(systemctl --user is-enabled "$AFK_AU_UNIT.timer" 2>/dev/null </dev/null)" == enabled ]] ;;
    darwin) launchctl print "gui/$(id -u)/$AFK_AU_LABEL" >/dev/null 2>&1 </dev/null ;;
    *)      return 1 ;;
  esac
}

# afk_au_unschedule — stop and remove the unit/agent files; the key and config stay.
afk_au_unschedule() {
  case "$AFK_AU_PLATFORM" in
    linux)
      systemctl --user disable --now "$AFK_AU_UNIT.timer" >/dev/null 2>&1 || true
      rm -f -- "$AFK_AU_SCHEDULER" "$AFK_AU_SYSTEMD_DIR/$AFK_AU_UNIT.service"
      systemctl --user daemon-reload >/dev/null 2>&1 || true ;;
    darwin)
      launchctl bootout "gui/$(id -u)/$AFK_AU_LABEL" >/dev/null 2>&1 || true
      rm -f -- "$AFK_AU_SCHEDULER" ;;
  esac
}

# afk_au_linux_restore_files — put the saved unit files back as they were
# (present with their text, or absent). Uses the caller's prev_* locals.
afk_au_linux_restore_files() {
  local svc="$AFK_AU_SYSTEMD_DIR/$AFK_AU_UNIT.service"
  if [[ -n "$prev_svc_set" ]]; then afk_au_put "$svc" "$prev_svc" || return 1; else rm -f -- "$svc" || return 1; fi
  if [[ -n "$prev_tmr_set" ]]; then afk_au_put "$AFK_AU_SCHEDULER" "$prev_tmr" || return 1; else rm -f -- "$AFK_AU_SCHEDULER" || return 1; fi
}

# afk_au_linux_rollback — after the manager saw the new units: restore the
# files, reload, then the previous enabled and active state, in that order.
# Prints the step that failed, if any.
afk_au_linux_rollback() {
  local t="$AFK_AU_UNIT.timer"
  afk_au_linux_restore_files || { printf 'restore-files'; return 1; }
  systemctl --user daemon-reload >/dev/null 2>&1 </dev/null || { printf 'daemon-reload'; return 1; }
  if [[ -n "$prev_enabled" ]]; then systemctl --user enable "$t" >/dev/null 2>&1 </dev/null || { printf 'enable'; return 1; }
  else systemctl --user disable "$t" >/dev/null 2>&1 </dev/null || { printf 'disable'; return 1; }; fi
  if [[ -n "$prev_active" ]]; then systemctl --user start "$t" >/dev/null 2>&1 </dev/null || { printf 'start'; return 1; }
  else systemctl --user stop "$t" >/dev/null 2>&1 </dev/null || { printf 'stop'; return 1; }; fi
}

# afk_au_enable_linux <interval> — sets AFK_AU_PREVIOUS on a re-enrollment and
# AFK_AU_RESTORED once every rollback step succeeded. A first enrollment that
# fails is unscheduled as before; a re-enrollment keeps the config.
afk_au_enable_linux() {
  local user t="$AFK_AU_UNIT.timer" svc="$AFK_AU_SYSTEMD_DIR/$AFK_AU_UNIT.service" step
  local prev_svc="" prev_svc_set="" prev_tmr="" prev_tmr_set="" prev_enabled="" prev_active=""
  AFK_AU_PREVIOUS="" AFK_AU_RESTORED=""
  [[ -f "$svc" || -f "$AFK_AU_SCHEDULER" ]] && AFK_AU_PREVIOUS=y
  if [[ -f "$svc" ]]; then prev_svc="$(cat -- "$svc")" || return 1; prev_svc_set=y; fi
  if [[ -f "$AFK_AU_SCHEDULER" ]]; then prev_tmr="$(cat -- "$AFK_AU_SCHEDULER")" || return 1; prev_tmr_set=y; fi
  if [[ -n "$AFK_AU_PREVIOUS" ]]; then
    [[ "$(systemctl --user is-enabled "$t" 2>/dev/null </dev/null)" == enabled ]] && prev_enabled=y
    [[ "$(systemctl --user is-active "$t" 2>/dev/null </dev/null)" == active ]] && prev_active=y
  fi
  if ! { afk_au_put "$svc" "$(afk_au_systemd_service)" \
         && afk_au_put "$AFK_AU_SCHEDULER" "$(afk_au_systemd_timer "$1")" \
         && systemctl --user daemon-reload >/dev/null 2>&1 </dev/null; }; then
    # The manager has not loaded the new units: put the files back, unschedule nothing.
    if [[ -n "$AFK_AU_PREVIOUS" ]] && afk_au_linux_restore_files; then
      AFK_AU_RESTORED=y
      afk_warn "enroll-auto-update: SCHEDULER_UNAVAILABLE: the new units could not be loaded (is a user manager running?); the previous unit files and the config were restored and nothing was unscheduled"
    elif [[ -n "$AFK_AU_PREVIOUS" ]]; then
      afk_warn "enroll-auto-update: ROLLBACK_FAILED: the new units could not be loaded and the previous unit files could not be restored; the config was kept; inspect $AFK_AU_SYSTEMD_DIR"
    else
      afk_au_unschedule
      afk_warn "enroll-auto-update: SCHEDULER_UNAVAILABLE: systemctl --user could not load $t (is a user manager running?); the units were removed"
    fi
    return 1
  fi
  if ! { systemctl --user enable --now "$t" >/dev/null 2>&1 </dev/null && afk_au_scheduler_enabled; }; then
    if [[ -z "$AFK_AU_PREVIOUS" ]]; then
      afk_au_unschedule
      afk_warn "enroll-auto-update: SCHEDULER_UNAVAILABLE: systemctl --user could not enable $t (is a user manager running?); the units were removed"
    elif step="$(afk_au_linux_rollback)"; then
      AFK_AU_RESTORED=y
      afk_warn "enroll-auto-update: SCHEDULER_UNAVAILABLE: systemctl --user could not enable the new $t; the previous units, their enabled and active state and the config were restored"
    else
      afk_warn "enroll-auto-update: ROLLBACK_FAILED: systemctl --user could not enable the new $t and restoring the previous one failed at $step; the config was kept; inspect: systemctl --user status $t"
    fi
    return 1
  fi
  user="${USER:-$(id -un)}"
  if [[ "$(loginctl show-user "$user" -p Linger --value 2>/dev/null)" == yes ]]; then
    AFK_AU_NOTE="linger=yes"
  else
    AFK_AU_NOTE="linger=no (the timer stops at logout; to keep it running: sudo loginctl enable-linger $user)"
  fi
}

# afk_au_darwin_load <domain> <plist-text> — bootout is asynchronous, so wait
# (bounded) until the old agent is gone, then bootstrap with bounded retries.
afk_au_darwin_load() {
  local i
  launchctl bootout "$1/$AFK_AU_LABEL" >/dev/null 2>&1 </dev/null || true
  for (( i = 0; i < 20; i++ )); do
    launchctl print "$1/$AFK_AU_LABEL" >/dev/null 2>&1 </dev/null || break
    sleep 0.5
  done
  afk_au_put "$AFK_AU_SCHEDULER" "$2" || return 1
  for (( i = 0; i < 3; i++ )); do
    (( i == 0 )) || sleep 1
    if launchctl bootstrap "$1" "$AFK_AU_SCHEDULER" >/dev/null 2>&1 </dev/null && afk_au_scheduler_enabled; then
      return 0
    fi
  done
  return 1
}

afk_au_enable_darwin() { # <interval> — sets AFK_AU_RESTORED when the previous agent was put back
  local domain prev=""
  domain="gui/$(id -u)"
  AFK_AU_RESTORED=""
  [[ -f "$AFK_AU_SCHEDULER" ]] && prev="$(cat -- "$AFK_AU_SCHEDULER")"
  if afk_au_darwin_load "$domain" "$(afk_au_launchd_plist "$1")"; then
    AFK_AU_NOTE="check-only (MACOS_SANDBOX_PENDING: apply with agent-flow-kit update)"
    return 0
  fi
  if [[ -n "$prev" ]] && afk_au_darwin_load "$domain" "$prev"; then
    AFK_AU_RESTORED=y
    afk_warn "enroll-auto-update: SCHEDULER_UNAVAILABLE: launchctl could not load the new $AFK_AU_LABEL; the previous agent and config were restored"
    return 1
  fi
  afk_au_unschedule
  afk_warn "enroll-auto-update: SCHEDULER_UNAVAILABLE: launchctl could not load $AFK_AU_LABEL; the agent was removed"
  return 1
}

# afk_au_check — compare the trusted ref with the applied revision and record
# the answer. Same pinned transport as the release client; fetches nothing.
afk_au_check() {
  local remote ref applied ssh_cmd out head state now
  remote="$(jq -r '.trust.remote_url // empty' "$AFK_AU_POLICY" 2>/dev/null)"
  ref="$(jq -r '.trust.ref // empty' "$AFK_AU_POLICY" 2>/dev/null)"
  applied="$(jq -r '.applied_revision // ""' "$AFK_STATE_DIR/state.json" 2>/dev/null)"
  ssh_cmd="/usr/bin/ssh -F /dev/null -i $(afk_au_shq "$AFK_AU_KEY") -o IdentitiesOnly=yes -o IdentityAgent=none"
  ssh_cmd+=" -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$(afk_au_shq "$AFK_AU_RUNTIME_BIN/afk-release-known-hosts")"
  ssh_cmd+=" -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no -o PreferredAuthentications=publickey -o BatchMode=yes -o ConnectTimeout=10"
  head=""
  if [[ -n "$remote" && -n "$ref" ]] \
     && out="$(env -i PATH="$PATH" HOME=/nonexistent LC_ALL=C GIT_TERMINAL_PROMPT=0 \
               GIT_SSH_COMMAND="$ssh_cmd" git ls-remote -- "$remote" "$ref" 2>/dev/null </dev/null)"; then
    head="${out%%[[:space:]]*}"
  fi
  if ! [[ "$head" =~ ^[0-9a-f]{40}$ ]]; then head=""; state=CHECK_FAILED
  elif [[ "$head" == "$applied" ]]; then state=CURRENT
  else state=UPDATE_AVAILABLE; fi
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  (umask 077 && mkdir -p -- "$AFK_STATE_DIR") || return 1
  afk_au_put "$AFK_AU_CHECK_STATE" "$(jq -n --arg s "$state" --arg h "$head" --arg a "$applied" --arg t "$now" \
    '{schema: "afk-auto-update-check/1", checked_at: $t, state: $s, applies: false,
      remote_revision: (if $h == "" then null else $h end),
      applied_revision: (if $a == "" then null else $a end)}')" || return 1
  case "$state" in
    UPDATE_AVAILABLE) printf 'update available: %s\n' "$head" ;;
    CURRENT)          printf 'current: %s\n' "$head" ;;
    *)                printf 'check failed: the trusted ref could not be read\n'; return 5 ;;
  esac
}

afk_au_remove() {
  afk_au_unschedule
  rm -f -- "$AFK_AU_CONFIG" "$AFK_AU_CHECK_STATE"
  printf 'auto-update: NOT_ENROLLED platform=%s (scheduler and config removed; the deploy key at %s was left in place)\n' \
    "$AFK_AU_PLATFORM" "$AFK_AU_KEY"
}

afk_cmd_enroll_auto_update() { # <enroll|check|remove> <key-ref> <key-file>
  local interval first out rc=0
  if [[ "$1" != enroll && ( -n "$2" || -n "$3" ) ]]; then
    afk_warn "enroll-auto-update: --key-ref and --key-file apply only to enrollment; --$1 uses the key path enrollment recorded"
    return "$AFK_EXIT_USAGE"
  fi
  [[ -n "$3" ]] && AFK_RELEASE_DEPLOY_KEY="$3"
  afk_au_paths
  if [[ -z "${HOME:-}" || -z "$AFK_AU_CONFIG" || -z "$AFK_AU_KEY" ]]; then
    afk_warn "enroll-auto-update: HOME is not set; nothing was changed"; return "$AFK_EXIT_USAGE"
  fi
  case "$1" in
    check)  afk_au_check; return $? ;;
    remove) afk_au_remove; return "$AFK_EXIT_OK" ;;
  esac
  if [[ "$AFK_AU_PLATFORM" == unsupported ]]; then
    afk_warn "enroll-auto-update: AUTO_UPDATE_PLATFORM_UNSUPPORTED"; return "$AFK_EXIT_SOURCE_REFUSED"
  fi
  if [[ "$2" != op://* ]]; then
    afk_warn "enroll-auto-update requires --key-ref op://<vault>/<item>/<field>"; return "$AFK_EXIT_USAGE"
  fi
  afk_au_key_path_valid || return "$AFK_EXIT_USAGE"
  afk_au_ready || return "$AFK_EXIT_SOURCE_REFUSED"
  interval="$(afk_au_interval)"
  AFK_AU_KEY_ACTION="$(afk_au_install_key "$2")" || return "$AFK_EXIT_SOURCE_REFUSED"
  # The config is written only once the scheduler is really enabled. A failed
  # enable leaves neither units nor an earlier config, unless the previous
  # scheduler was there before: macOS keeps the config when it put the agent
  # back; Linux always keeps it on re-enrollment, since status asks systemd.
  if [[ "$AFK_AU_PLATFORM" == linux ]]; then
    afk_au_enable_linux "$interval" || {
      [[ -n "$AFK_AU_PREVIOUS" ]] || rm -f -- "$AFK_AU_CONFIG"
      return "$AFK_EXIT_LIVE_UNAVAILABLE"; }
  elif ! afk_au_enable_darwin "$interval"; then
    [[ -n "$AFK_AU_RESTORED" ]] || rm -f -- "$AFK_AU_CONFIG"
    return "$AFK_EXIT_LIVE_UNAVAILABLE"
  fi
  afk_au_write_config "$2" || {
    afk_au_unschedule; rm -f -- "$AFK_AU_CONFIG"
    afk_warn "enroll-auto-update: the machine-local config could not be written; the scheduler was removed"
    return "$AFK_EXIT_USAGE"; }
  if [[ "$AFK_AU_PLATFORM" == linux ]]; then
    # Same bound as the unit; captured first, so no pipeline hides the status.
    out="$(AFK_RELEASE_DEPLOY_KEY="$AFK_AU_KEY" timeout "$AFK_AU_TIMEOUT_SECONDS" \
      "$AFK_AU_RUNTIME_BIN/afk-release-reconcile" --apply 2>/dev/null </dev/null)" || rc=$?
    if (( rc == 124 )); then
      first="TIMED_OUT"
    else
      first="$(jq -r '"\(.state // "UNKNOWN")/\(.reason // "-")"' <<<"$out" 2>/dev/null)"
      first="${first:-NO_RESULT}"
    fi
  else
    first="$(afk_au_check)"
  fi
  printf 'auto-update: ENROLLED platform=%s interval=%ss key=%s (%s) scheduler=%s first_attempt=%s; %s\n' \
    "$AFK_AU_PLATFORM" "$interval" "$AFK_AU_KEY" "$AFK_AU_KEY_ACTION" "$AFK_AU_SCHEDULER" "$first" "$AFK_AU_NOTE"
  return "$AFK_EXIT_OK"
}

# --- status ------------------------------------------------------------------

afk_auto_update_status_json() {
  # update_available compares the saved check with the revision status loaded,
  # so a check taken before the last apply is never reported.
  local last="null" config="{}"
  afk_au_paths
  [[ -r "$AFK_AU_CONFIG" ]] && config="$(jq -c '.' "$AFK_AU_CONFIG" 2>/dev/null || printf '{}')"
  if [[ "$AFK_AU_PLATFORM" == darwin && -r "$AFK_AU_CHECK_STATE" ]]; then
    last="$(jq -c '{state, at: .checked_at, remote_revision}' "$AFK_AU_CHECK_STATE" 2>/dev/null || printf 'null')"
  elif [[ -r "$AFK_STATE_DIR/releases/latest.json" ]]; then
    last="$(jq -c '{state, reason, at: .ended_at}' "$AFK_STATE_DIR/releases/latest.json" 2>/dev/null || printf 'null')"
  fi
  jq -nc --arg platform "$AFK_AU_PLATFORM" --arg sched "$AFK_AU_SCHEDULER" \
    --argjson config "$config" --argjson last "$last" \
    --arg has_config "$([[ -f "$AFK_AU_CONFIG" ]] && echo y)" \
    --arg has_sched "$(afk_au_scheduler_enabled && echo y)" \
    --arg has_key "$([[ -f "$AFK_AU_KEY" ]] && echo y)" \
    --arg applied "${AFK_APPLIED_REVISION:-}" \
    '{enrolled: ($has_config == "y" and $has_sched == "y"), platform: $platform,
      scheduler: (if $has_sched == "y" then $sched else null end),
      key_ref: ($config.key_ref // null), key_present: ($has_key == "y"),
      last_result: $last,
      update_available: ($platform == "darwin" and $last != null
        and $last.state == "UPDATE_AVAILABLE"
        and ($last.remote_revision | type == "string")
        and $last.remote_revision != $applied)}'
}

afk_auto_update_apply_status() {
  local au
  au="$(afk_auto_update_status_json)" || return 0
  AFK_R_EXTRA="$(jq -nc --argjson base "$AFK_R_EXTRA" --argjson au "$au" '$base + {auto_update: $au}')" || return 0
}
