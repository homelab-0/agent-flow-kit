#!/usr/bin/env bash
# Remote launchers may use this wrapper to reconcile AFK before entering
# Hermes. This is an entry contract, not a claim that Hermes has native hooks.
set -uo pipefail

ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
UPDATER="$ROOT/bin/afk-session-start"

if [[ ! -x "$UPDATER" ]]; then
  printf 'hermes-session-start: updater unavailable at stable runtime path\n' >&2
  exit 3
fi

if [[ "${1:-}" == -- ]]; then shift; fi
exec "$UPDATER" -- "$@"
