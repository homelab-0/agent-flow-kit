#!/usr/bin/env bash
# Fixed successor entrypoint.  Resume text is passed as one argv data value to
# the selected harness and is never evaluated as a shell command.
set -euo pipefail
[[ "${1:-}" == --intent && -n "${2:-}" ]] || exit 2
intent="$2"
jq -e 'def s: type=="string" and length>0;
  .schema=="afk-pm-bootstrap-intent/1" and (.transition_id|s) and
  (.harness|IN("claude","codex","opencode")) and (.resume_instruction|s) and
  (.worktree.id|s) and (.worktree.path|s) and (.pm_dir|s) and
  (.continuation_sha256|s)' "$intent" >/dev/null 2>&1 || exit 1
tid="$(jq -r .transition_id "$intent")"; harness="$(jq -r .harness "$intent")"
resume="$(jq -r .resume_instruction "$intent")"; pm_dir="$(jq -r .pm_dir "$intent")"
wi="$(jq -r .worktree.id "$intent")"; wp="$(jq -r .worktree.path "$intent")"
continuation_sha="$(jq -r .continuation_sha256 "$intent")"
actual_path="$(pwd -P 2>/dev/null || true)"
[[ "$actual_path" == "$wp" && -n "${ORCA_TERMINAL_HANDLE:-}" ]] || exit 1
[[ -z "${ORCA_WORKTREE_PATH:-}" || "${ORCA_WORKTREE_PATH}" == "$wp" ]] || exit 1
orca_bin="${ORCA_CLI_COMMAND:-${AFK_ORCA_BIN:-orca}}"
bound=""; command -v timeout >/dev/null 2>&1 && bound=timeout
[[ -n "$bound" ]] || { command -v gtimeout >/dev/null 2>&1 && bound=gtimeout; }
[[ -n "$bound" ]] || exit 1
shown="$($bound "${AFK_ORCA_TIMEOUT_SECONDS:-5}" "$orca_bin" worktree show --worktree "path:$actual_path" --json)" || exit 1
observed_id="$(jq -r '.result.worktree.id // .result.id // .worktree.id // .id // empty' <<<"$shown" 2>/dev/null)"
observed_path="$(jq -r '.result.worktree.path // .result.path // .worktree.path // .path // empty' <<<"$shown" 2>/dev/null)"
observed_path="$(cd "$observed_path" 2>/dev/null && pwd -P || true)"
[[ -n "$observed_id" && "$observed_id" == "$wi" && "$observed_path" == "$wp" ]] || exit 1

# Orca may start the command before the launcher persists its receipt.  Wait a
# bounded interval for that durable gate; never start a harness before it.
tries="${AFK_PM_BOOTSTRAP_POLLS:-50}"; delay="${AFK_PM_BOOTSTRAP_POLL_SECONDS:-0.1}"
while ((tries-- > 0)); do
  if jq -e --arg id "$tid" --arg t "$ORCA_TERMINAL_HANDLE" --arg h "$harness" --arg wi "$wi" --arg wp "$wp" \
    --arg continuation_sha "$continuation_sha" \
    '.schema=="afk-pm-handoff/2" and .transition_id==$id and .state=="SUCCESSOR_LAUNCHED" and
     .continuation_sha256==$continuation_sha and .successor.terminal==$t and .successor.harness==$h and
     .successor.worktree.id==$wi and .successor.worktree.path==$wp' \
    "$pm_dir/handoff.json" >/dev/null 2>&1; then break; fi
  sleep "$delay"
done
((tries >= 0)) || exit 1

# Run continuity is a precondition when the old coordinator declared a Run.
# A timeout, refusal, or receipt that does not prove this terminal's binding
# stops before the harness starts.
run_id="$(jq -r '.run_id // empty' "$intent")"
if [[ -n "$run_id" ]]; then
  run_receipt="$($bound "${AFK_ORCA_TIMEOUT_SECONDS:-5}" "$orca_bin" orchestration run-use --id "$run_id" --from "$ORCA_TERMINAL_HANDLE" --json)" || exit 1
  jq -e --arg id "$run_id" --arg t "$ORCA_TERMINAL_HANDLE" '
    ((.result.run.id // .run.id // .result.id // .id)==$id) and
    ((.result.coordinatorTerminalHandle // .result.terminal.handle // .coordinatorTerminalHandle // .terminal.handle)==$t)' \
    <<<"$run_receipt" >/dev/null 2>&1 || exit 1
fi

case "$harness" in
  claude) harness_bin="${AFK_CLAUDE_BIN:-claude}" ;;
  codex) harness_bin="${AFK_CODEX_BIN:-codex}" ;;
  opencode) harness_bin="${AFK_OPENCODE_BIN:-opencode}" ;;
esac
export AFK_RUNTIME_ROLE=PM AFK_PM_TRANSITION_ID="$tid" AFK_PM_DIR="$pm_dir"
export ORCA_WORKTREE_ID="$observed_id" ORCA_WORKTREE_PATH="$observed_path"
[[ -z "$run_id" ]] || export ORCA_RUN_ID="$run_id"
if [[ "$harness" == opencode ]]; then exec "$harness_bin" --prompt "$resume"; fi
exec "$harness_bin" -- "$resume"
