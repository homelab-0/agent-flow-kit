#!/usr/bin/env bash
# afk-orca.sh — the one way kit code finds and runs the Orca CLI (AD-28 R1, R2).
#
# This file is SOURCED, never executed, and is independently sourceable.
#
# Resolution (afk_orca_bin), first source that is set wins:
#   1. host.orca_bin in ~/.config/agent-flow-kit/host.json (AFK_HOST_CONFIG
#      overrides the path). The file is optional; when present it must be a
#      JSON object, and a set orca_bin must be an absolute path.
#   2. ORCA_CLI_COMMAND, when it is an absolute path.
#   3. AFK_ORCA_BIN, when it is an absolute path.
#   4. The platform default: $HOME/.local/bin/orca-ide on Linux,
#      /usr/local/bin/orca on macOS.
# A relative name (including bare `orca`, which outside an Orca terminal is
# the GNOME screen reader on Linux) is never executed. The chosen candidate is
# verified once per process with a bounded `<bin> --version`, which must print
# a semantic version. If it fails, the answer is ORCA_CLI_NOT_RESOLVED and no
# other candidate is tried.
#
# Invocation (afk_orca_run [--bound <s>] [--environment] <purpose> -- <args...>):
# the verified binary, `--json` appended when absent, stdin from /dev/null,
# TERM=dumb, ORCA_ENVIRONMENT and ORCA_PAIRING_CODE removed unless
# --environment is passed, and `timeout -k <grace> <bound>` (gtimeout when
# there is no timeout). Bound defaults to 10 s, or a call site's --bound;
# AFK_ORCA_TIMEOUT_SECONDS replaces the default and can only lower a --bound.
# Grace defaults to 3 s (AFK_ORCA_GRACE_SECONDS). The bound is clamped so
# bound plus grace never exceeds 60 s in one call.
#
# Return protocol: call afk_orca_run directly, never inside $(...), and read
#   AFK_ORCA_CODE  OK | ORCA_TIMEOUT | ORCA_ERROR:<code> | ORCA_CLI_FAILED |
#                  ORCA_LIST_INCOMPLETE | ORCA_CLI_NOT_RESOLVED |
#                  PROBE_BOUND_UNAVAILABLE
#   AFK_ORCA_OUT   the CLI's stdout: the JSON on OK, and on failure whatever
#                  the CLI printed (an {ok:false} envelope, when there is one)
#   AFK_ORCA_RC    the CLI's exit status, 0 when it was never run
# It returns 0 only when AFK_ORCA_CODE is OK.
#
# Identity and liveness (AD-28 R4, R5) are further down: afk_orca_identity
# records a terminal's tuple, and afk_orca_terminal_state judges one.

if [[ -n "${AFK_ORCA_SOURCED:-}" ]]; then
  return 0
fi
AFK_ORCA_SOURCED=1

# The per-process verification cache. Assigned here, never exported, so a
# child process can't inherit a verdict it didn't reach itself.
_AFK_ORCA_STATE=""
_AFK_ORCA_PATH=""
AFK_ORCA_OUT=""; AFK_ORCA_CODE=""; AFK_ORCA_RC=0

afk_orca_seconds() { # <value> <default> <max> -> an integer in 1..max
  local v="$1"
  [[ "$v" =~ ^[1-9][0-9]*$ ]] || v="$2"
  (( v <= $3 )) || v="$3"
  printf '%s' "$v"
}

afk_orca_bound_tool() {
  if command -v timeout >/dev/null 2>&1; then printf 'timeout'
  elif command -v gtimeout >/dev/null 2>&1; then printf 'gtimeout'
  else return 1; fi
}

# afk_orca_candidate: the path resolution would verify, without running
# anything. Readiness uses it for its offline executable fact.
afk_orca_candidate() {
  local cfg="${AFK_HOST_CONFIG:-${HOME:+$HOME/.config/agent-flow-kit/host.json}}" v
  if [[ -n "$cfg" && -e "$cfg" ]]; then
    v="$(jq -er 'if type != "object" then error("host config is not an object")
      else (.orca_bin // "") end | if type == "string" then . else error("orca_bin is not a string") end' \
      "$cfg" 2>/dev/null)" || return 1
    if [[ -n "$v" ]]; then
      [[ "$v" == /* ]] || return 1
      printf '%s' "$v"; return 0
    fi
  fi
  if [[ "${ORCA_CLI_COMMAND:-}" == /* ]]; then printf '%s' "$ORCA_CLI_COMMAND"; return 0; fi
  if [[ "${AFK_ORCA_BIN:-}" == /* ]]; then printf '%s' "$AFK_ORCA_BIN"; return 0; fi
  if [[ "$(uname -s 2>/dev/null)" == Darwin ]]; then printf '/usr/local/bin/orca'; return 0; fi
  [[ -n "${HOME:-}" ]] || return 1
  printf '%s/.local/bin/orca-ide' "$HOME"
}

# afk_orca_bin: prints the verified absolute path, or fails with AFK_ORCA_CODE
# set. Call it once in the main shell before any $(...) that runs Orca, so the
# verdict is cached where the subshells inherit it.
afk_orca_bin() {
  local cand tool out rc grace
  if [[ -z "$_AFK_ORCA_STATE" ]]; then
    _AFK_ORCA_STATE="ORCA_CLI_NOT_RESOLVED"
    if ! tool="$(afk_orca_bound_tool)"; then
      _AFK_ORCA_STATE="PROBE_BOUND_UNAVAILABLE"
    elif cand="$(afk_orca_candidate)" && [[ -f "$cand" && -x "$cand" ]]; then
      grace="$(afk_orca_seconds "${AFK_ORCA_GRACE_SECONDS:-}" 3 10)"
      out="$(env -u ORCA_ENVIRONMENT -u ORCA_PAIRING_CODE TERM=dumb "$tool" -k "$grace" \
        "$(afk_orca_seconds "${AFK_ORCA_TIMEOUT_SECONDS:-}" 10 $((60 - grace)))" \
        "$cand" --version </dev/null 2>/dev/null)"
      rc=$?
      out="${out%%$'\n'*}"; out="${out//[[:space:]]/}"
      if (( rc == 0 )) && [[ "$out" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
        _AFK_ORCA_STATE="OK"; _AFK_ORCA_PATH="$cand"
      fi
    fi
  fi
  if [[ "$_AFK_ORCA_STATE" == OK ]]; then
    printf '%s\n' "$_AFK_ORCA_PATH"; return 0
  fi
  AFK_ORCA_CODE="$_AFK_ORCA_STATE"
  return 1
}

afk_orca_run() {
  local bound grace keep_env=false purpose tool bin out rc code a has_json=false
  AFK_ORCA_OUT=""; AFK_ORCA_CODE="ORCA_CLI_FAILED"; AFK_ORCA_RC=0
  # Bound plus grace never exceeds 60 s (AD-28 R2).
  grace="$(afk_orca_seconds "${AFK_ORCA_GRACE_SECONDS:-}" 3 10)"
  bound="$(afk_orca_seconds "${AFK_ORCA_TIMEOUT_SECONDS:-}" 10 $((60 - grace)))"
  while [[ "${1:-}" == --* ]]; do
    case "$1" in
      --bound) bound="$(afk_orca_seconds "${2:-}" "$bound" $((60 - grace)))"
               [[ -z "${AFK_ORCA_TIMEOUT_SECONDS:-}" ]] \
                 || bound="$(afk_orca_seconds "$AFK_ORCA_TIMEOUT_SECONDS" "$bound" "$bound")"
               shift 2 ;;
      --environment) keep_env=true; shift ;;
      *) return 2 ;;
    esac
  done
  purpose="${1:-}"
  [[ "$purpose" =~ ^[a-z][a-z0-9-]*$ && "${2:-}" == -- && $# -ge 3 ]] || return 2
  shift 2
  # Resolved in this shell, not a subshell, so the verdict stays cached.
  if ! afk_orca_bin >/dev/null; then
    afk_orca_trace "$purpose"; return 1
  fi
  bin="$_AFK_ORCA_PATH"
  tool="$(afk_orca_bound_tool)" || { AFK_ORCA_CODE="PROBE_BOUND_UNAVAILABLE"; return 1; }
  for a in "$@"; do [[ "$a" == --json ]] && has_json=true; done
  local -a cmd=("$tool" -k "$grace" "$bound" "$bin" "$@")
  [[ "$has_json" == true ]] || cmd+=(--json)
  if [[ "$keep_env" == true ]]; then
    out="$(TERM=dumb "${cmd[@]}" </dev/null 2>/dev/null)"
  else
    out="$(env -u ORCA_ENVIRONMENT -u ORCA_PAIRING_CODE TERM=dumb "${cmd[@]}" </dev/null 2>/dev/null)"
  fi
  rc=$?
  AFK_ORCA_OUT="$out"; AFK_ORCA_RC=$rc
  if (( rc == 124 || rc == 137 )); then
    code="ORCA_TIMEOUT"
  else
    # One jq pass classifies the envelope. Output that isn't a JSON object is
    # left to the caller's own parse on exit 0, and is a CLI failure otherwise.
    code="$(jq -r 'if type != "object" then "NOT_JSON"
      elif .ok == false then
        (.error.code // null) as $c
        | if ($c|type) == "string" and ($c|test("^[A-Za-z0-9_.:-]{1,80}$")) then "ORCA_ERROR:" + $c
          else "ORCA_CLI_FAILED" end
      else (.result // .) as $r
        | if ($r|type) == "object" and ((($r.truncated // false) == true)
              or ((($r.totalCount|type) == "number") and ([$r[] | arrays] | length) > 0
                  and $r.totalCount > ([$r[] | arrays | length] | max)))
          then "ORCA_LIST_INCOMPLETE" else "OK" end
      end' <<<"$out" 2>/dev/null)" || code="NOT_JSON"
    [[ -n "$code" ]] || code="NOT_JSON"
    if [[ "$code" == NOT_JSON ]]; then
      if (( rc == 0 )); then code="OK"; else code="ORCA_CLI_FAILED"; fi
    elif (( rc != 0 )) && [[ "$code" == OK || "$code" == ORCA_LIST_INCOMPLETE ]]; then
      code="ORCA_CLI_FAILED"
    fi
  fi
  AFK_ORCA_CODE="$code"
  afk_orca_trace "$purpose" "bound=$bound grace=$grace"
  [[ "$code" == OK ]]
}

afk_orca_trace() { # <purpose> [detail]
  [[ "${AFK_ORCA_TRACE:-}" == 1 ]] || return 0
  printf 'afk-orca: %s %s rc=%s%s\n' "$1" "$AFK_ORCA_CODE" "$AFK_ORCA_RC" "${2:+ $2}" >&2
}

# --- Identity and liveness (AD-28 R4, R5) -------------------------------------
# A recorded terminal is the tuple afk_orca_identity builds from `terminal
# show`: {handle, runtime_id, execution_host_id, worktree_id, tab_id, leaf_id,
# incarnation_id, agent_type, recorded_at}. Handles are only comparable inside
# the runtime that issued them, so runtime_id travels with every handle.
AFK_ORCA_LIST_LIMIT=1000

# afk_orca_identity_from_show <show-json> <agent_type> -> the tuple, or fails.
afk_orca_identity_from_show() {
  jq -ce --arg a "$2" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    def s: type=="string" and length>0;
    def so: if type=="string" and length>0 then . else null end;
    (._meta.runtimeId) as $rt | (.result.terminal // empty) as $t
    | select(($rt|s) and ($t.handle|s) and ($t.tabId|s) and ($t.leafId|s) and ($a|s))
    | {handle:$t.handle, runtime_id:$rt, execution_host_id:($t.executionHostId|so),
       worktree_id:($t.worktreeId|so), tab_id:$t.tabId, leaf_id:$t.leafId,
       incarnation_id:($t.incarnationId|so), agent_type:$a, recorded_at:$at}' <<<"$1" 2>/dev/null
}

# afk_orca_identity [--bound <s>] <handle> <agent_type>: sets AFK_ORCA_IDENTITY
# to the tuple for a terminal Orca shows right now. Call it directly, never in
# $(...).
afk_orca_identity() {
  local -a bound=()
  if [[ "${1:-}" == --bound ]]; then bound=(--bound "$2"); shift 2; fi
  AFK_ORCA_IDENTITY=""
  afk_orca_run ${bound[@]+"${bound[@]}"} afk-identity -- terminal show --terminal "$1" --json || return 1
  AFK_ORCA_IDENTITY="$(afk_orca_identity_from_show "$AFK_ORCA_OUT" "$2")" || AFK_ORCA_IDENTITY=""
  AFK_ORCA_OUT="" # the show payload carries screen text (preview)
  [[ -n "$AFK_ORCA_IDENTITY" ]]
}

# One snapshot per decision: the complete terminal list, its runtime id, and
# (only when a join needs it) the worktree ps agent rows, projected at once to
# {paneKey, agentType} so no prompt or reply text outlives the call (S-9).
afk_orca_liveness_reset() {
  _AFK_ORCA_LV_CODE=""; _AFK_ORCA_LV_RUNTIME=""; _AFK_ORCA_LV_TERMINALS=""
  _AFK_ORCA_LV_AGENTS_CODE=""; _AFK_ORCA_LV_AGENTS=""; AFK_ORCA_LIST_CODE=""
}
afk_orca_liveness_reset

# afk_orca_list_state: fills the list half of the snapshot and sets
# AFK_ORCA_LIST_CODE: OK | ORCA_LIST_INCOMPLETE | ORCA_UNAVAILABLE. Call it
# directly, never in $(...), so the snapshot stays cached in the caller.
afk_orca_list_state() {
  if [[ -z "$_AFK_ORCA_LV_CODE" ]]; then
    _AFK_ORCA_LV_CODE="ORCA_UNAVAILABLE"
    if afk_orca_run --bound 5 afk-liveness-list -- terminal list --limit "$AFK_ORCA_LIST_LIMIT" --json; then
      # Every entry needs a string handle and boolean connected/orphaned, or
      # the whole list is uncertainty, never "no terminals".
      _AFK_ORCA_LV_TERMINALS="$(jq -ce '(.result // .) as $r
        | select(($r|type)=="object" and ($r.terminals|type)=="array" and
            all($r.terminals[]; type=="object" and (.handle|type)=="string" and (.handle|length)>0
              and (.connected|type)=="boolean" and (.orphaned|type)=="boolean"))
        | $r.terminals | map({handle, connected, orphaned})' <<<"$AFK_ORCA_OUT" 2>/dev/null)" \
        && [[ -n "$_AFK_ORCA_LV_TERMINALS" ]] && _AFK_ORCA_LV_CODE="OK"
      _AFK_ORCA_LV_RUNTIME="$(jq -r '._meta.runtimeId // empty | strings' <<<"$AFK_ORCA_OUT" 2>/dev/null)"
    elif [[ "$AFK_ORCA_CODE" == ORCA_LIST_INCOMPLETE ]]; then
      _AFK_ORCA_LV_CODE="ORCA_LIST_INCOMPLETE"
    fi
  fi
  AFK_ORCA_LIST_CODE="$_AFK_ORCA_LV_CODE"
  [[ "$AFK_ORCA_LIST_CODE" == OK ]]
}

afk_orca_agents_state() {
  if [[ -z "$_AFK_ORCA_LV_AGENTS_CODE" ]]; then
    _AFK_ORCA_LV_AGENTS_CODE="ORCA_UNAVAILABLE"
    if afk_orca_run --bound 5 afk-liveness-agents -- worktree ps --limit "$AFK_ORCA_LIST_LIMIT" --json; then
      _AFK_ORCA_LV_AGENTS="$(jq -ce --arg rt "$_AFK_ORCA_LV_RUNTIME" '
        select(._meta.runtimeId==$rt and (.result.worktrees|type)=="array")
        | [.result.worktrees[] | (.agents // [])[] | objects
           | {paneKey, agentType} | select((.paneKey|type)=="string")]' <<<"$AFK_ORCA_OUT" 2>/dev/null)" \
        && [[ -n "$_AFK_ORCA_LV_AGENTS" ]] && _AFK_ORCA_LV_AGENTS_CODE="OK"
    elif [[ "$AFK_ORCA_CODE" == ORCA_LIST_INCOMPLETE ]]; then
      _AFK_ORCA_LV_AGENTS_CODE="ORCA_LIST_INCOMPLETE"
    fi
    AFK_ORCA_OUT="" # the raw payload carries conversation text
  fi
  [[ "$_AFK_ORCA_LV_AGENTS_CODE" == OK ]]
}

# afk_orca_terminal_state <tuple-json>: sets AFK_ORCA_TERMINAL_STATE to one of
# live | detached | disconnected | stale | unknown, and AFK_ORCA_TERMINAL_REASON
# (null for live). Call it directly. `orphaned` alone never yields stale.
afk_orca_terminal_state() {
  local tuple="$1" handle runtime pane agent entry shown_rt
  AFK_ORCA_TERMINAL_STATE="unknown"; AFK_ORCA_TERMINAL_REASON="PM_IDENTITY_UNRECORDED"
  jq -e 'def s: type=="string" and length>0;
    (.handle|s) and (.runtime_id|s) and (.tab_id|s) and (.leaf_id|s) and (.agent_type|s)' \
    <<<"$tuple" >/dev/null 2>&1 || return 0
  handle="$(jq -r .handle <<<"$tuple")"; runtime="$(jq -r .runtime_id <<<"$tuple")"
  pane="$(jq -r '.tab_id + ":" + .leaf_id' <<<"$tuple")"; agent="$(jq -r .agent_type <<<"$tuple")"

  afk_orca_list_state || { AFK_ORCA_TERMINAL_REASON="$AFK_ORCA_LIST_CODE"; return 0; }
  if [[ -z "$_AFK_ORCA_LV_RUNTIME" ]]; then AFK_ORCA_TERMINAL_REASON="ORCA_UNAVAILABLE"; return 0; fi
  # A different runtime reissued every handle: absence proves nothing (OQ-2).
  if [[ "$_AFK_ORCA_LV_RUNTIME" != "$runtime" ]]; then AFK_ORCA_TERMINAL_REASON="PM_RUNTIME_MISMATCH"; return 0; fi

  entry="$(jq -c --arg h "$handle" 'map(select(.handle==$h)) | .[0] // empty' <<<"$_AFK_ORCA_LV_TERMINALS")"
  if [[ -z "$entry" ]]; then
    # Stale needs the handle-specific proof as well as absence from a
    # complete list in the same runtime.
    afk_orca_run --bound 5 afk-liveness-show -- terminal show --terminal "$handle" --json
    shown_rt="$(jq -r '._meta.runtimeId // empty | strings' <<<"$AFK_ORCA_OUT" 2>/dev/null)"
    AFK_ORCA_OUT=""
    if [[ "$AFK_ORCA_CODE" == "ORCA_ERROR:terminal_handle_stale" && "$shown_rt" == "$runtime" ]]; then
      AFK_ORCA_TERMINAL_STATE="stale"; AFK_ORCA_TERMINAL_REASON="PM_TERMINAL_STALE"
    else
      AFK_ORCA_TERMINAL_REASON="PM_TERMINAL_UNPROVEN"
    fi
    return 0
  fi
  if jq -e '.connected==false' <<<"$entry" >/dev/null; then
    AFK_ORCA_TERMINAL_STATE="disconnected"; AFK_ORCA_TERMINAL_REASON="PM_OWNER_DISCONNECTED"; return 0
  fi
  if jq -e '.orphaned==true' <<<"$entry" >/dev/null; then
    AFK_ORCA_TERMINAL_STATE="detached"; AFK_ORCA_TERMINAL_REASON="PM_TERMINAL_DETACHED"; return 0
  fi
  afk_orca_agents_state || { AFK_ORCA_TERMINAL_REASON="$_AFK_ORCA_LV_AGENTS_CODE"; return 0; }
  # Only an exact pane key counts; re-attached PTYs can report pty:N:pty:N.
  if jq -e --arg p "$pane" --arg a "$agent" 'any(.[]; .paneKey==$p and .agentType==$a)' \
    <<<"$_AFK_ORCA_LV_AGENTS" >/dev/null; then
    AFK_ORCA_TERMINAL_STATE="live"; AFK_ORCA_TERMINAL_REASON="null"
  else
    AFK_ORCA_TERMINAL_STATE="detached"; AFK_ORCA_TERMINAL_REASON="PM_TERMINAL_DETACHED"
  fi
}
