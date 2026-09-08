#!/usr/bin/env bash
# Probe F3 — the launcher-owned worktree sentence: content, byte-stability,
# and that nothing the story or persona says can reach it.
set -uo pipefail
SRC="${1:?dispatch.sh}"
source "$SRC" >/dev/null 2>&1 || true
if ! declare -F worker_worktree_paragraph >/dev/null; then
  echo "worker_worktree_paragraph: ABSENT in $SRC"; exit 0; fi
A="$(worker_worktree_paragraph "/wt/some worktree")"
B="$(worker_worktree_paragraph "/wt/some worktree")"
C="$(worker_worktree_paragraph "/wt/other")"
printf 'text  : %s\n' "$(printf '%s' "$A" | tr '\n' '~')"
printf 'stable: %s\n' "$([[ "$A" == "$B" ]] && echo yes || echo NO)"
printf 'bound : %s\n' "$([[ "$A" != "$C" ]] && echo 'yes (differs by root)' || echo NO)"
printf 'inputs: %s\n' "$(declare -f worker_worktree_paragraph | grep -cE '\$STORY|\$PERSONA|\bfm\b|yq') story/persona references (0 = launcher-owned)"
printf 'callsite: %s\n' "$(grep -F 'worker_worktree_paragraph "$(realpath' "$SRC")"
printf 'cd in launcher: %s occurrences\n' "$(grep -cE '^[[:space:]]*(cd|pushd|popd) ' "$SRC")"
