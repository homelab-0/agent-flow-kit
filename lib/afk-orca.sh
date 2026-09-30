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
