#!/usr/bin/env bash
# Stable, non-secret namespaces for runtime presentation and PM ownership.
# Runtime observations belong to one Orca terminal. PM handoff state belongs to
# one worktree so a successor terminal can acknowledge the same transition.

if [[ -n "${AFK_RUNTIME_SCOPE_SOURCED:-}" ]]; then
  return 0
fi
AFK_RUNTIME_SCOPE_SOURCED=1

afk_scope_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  else return 1
  fi
}

afk_runtime_scope_key() { # terminal|worktree
  local kind="$1" value="" digest
  case "$kind" in
    terminal)
      if [[ -n "${ORCA_TERMINAL_HANDLE:-}" ]]; then
        value="$ORCA_TERMINAL_HANDLE"
      elif [[ -n "${AFK_RUNTIME_SESSION_ID:-}" ]]; then
        kind=session
        value="$AFK_RUNTIME_SESSION_ID"
      else
        return 1
      fi
      ;;
    session) value="${AFK_RUNTIME_SESSION_ID:-}" ;;
    worktree) value="$(pwd -P 2>/dev/null || true)" ;;
    *) return 1 ;;
  esac
  [[ -n "$value" ]] || return 1
  digest="$(printf '%s\0%s' "$kind" "$value" | afk_scope_sha256)" || return 1
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s-%s\n' "$kind" "$digest"
}

afk_default_cache_root() {
  local base="${XDG_CACHE_HOME:-${HOME:+$HOME/.cache}}"
  [[ -n "$base" ]] || return 1
  printf '%s/agent-flow-kit\n' "$base"
}

afk_default_status_cache_dir() {
  local root key
  root="$(afk_default_cache_root)" || return 1
  key="$(afk_runtime_scope_key terminal)" || return 1
  printf '%s/scopes/%s\n' "$root" "$key"
}

afk_default_state_root() {
  local base="${XDG_STATE_HOME:-${HOME:+$HOME/.local/state}}"
  [[ -n "$base" ]] || return 1
  printf '%s/agent-flow-kit\n' "$base"
}

afk_default_pm_dir() {
  local state_root="${AFK_STATE_DIR:-}" key
  [[ -n "$state_root" ]] || state_root="$(afk_default_state_root)" || return 1
  key="$(afk_runtime_scope_key worktree)" || return 1
  printf '%s/pm/scopes/%s\n' "$state_root" "$key"
}
