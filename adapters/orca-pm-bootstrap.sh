#!/usr/bin/env bash
# Fixed successor entrypoint.  Resume text is passed as one argv data value to
# the selected harness and is never evaluated as a shell command.
set -euo pipefail
[[ "${1:-}" == --intent && -n "${2:-}" ]] || exit 2
intent="$2"
# The kit's Orca resolver: lib/ sits beside the installed runtime, or one level
# up in a checkout.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
if [[ -r "$here/lib/afk-orca.sh" ]]; then . "$here/lib/afk-orca.sh"; else . "$here/../lib/afk-orca.sh"; fi
# shellcheck disable=SC1091
if [[ -r "$here/lib/afk-pm-control.sh" ]]; then . "$here/lib/afk-pm-control.sh"; else . "$here/../lib/afk-pm-control.sh"; fi

# AFK-PC-2b: a first-ever PM start has no predecessor, so it carries a sibling
# intent kind that skips the handoff receipt and run-continuity checks below.
# The resume text is still one argv data value, validated as fixed kit text
# with only <slug>/<harness> interpolated (never Paperclip bytes), and is
# never evaluated.
if [[ "$(jq -r '.schema // empty' "$intent" 2>/dev/null)" == "afk-pm-bootstrap-first-start-intent/2" ]]; then
  jq -e 'def s: type=="string" and length>0;
    (.slug|s) and (.slug|test("^[a-z0-9-]{1,40}$")) and
    (.harness|IN("claude","codex","opencode")) and (.resume_instruction|s) and
    (.worktree.id|s) and (.worktree.path|s)' "$intent" >/dev/null 2>&1 || exit 1
  fs_harness="$(jq -r .harness "$intent")"; fs_resume="$(jq -r .resume_instruction "$intent")"
  fs_wi="$(jq -r .worktree.id "$intent")"; fs_wp="$(jq -r .worktree.path "$intent")"
  fs_slug="$(jq -r .slug "$intent")"
  # The only text this kind may carry is the fixed kit instruction; rebuild it
  # and refuse anything else, so an edited intent cannot become a prompt.
  [[ "$fs_resume" == "You are the BMAD PM for project $fs_slug. Register with \`agent-flow-kit pm-start --harness $fs_harness\`, then run \`agent-flow-kit paperclip-take --slug $fs_slug\` and read the brief file it names." ]] || exit 1
  fs_actual_path="$(pwd -P 2>/dev/null || true)"
  [[ "$fs_actual_path" == "$fs_wp" && -n "${ORCA_TERMINAL_HANDLE:-}" ]] || exit 1
  [[ -z "${ORCA_WORKTREE_PATH:-}" || "${ORCA_WORKTREE_PATH}" == "$fs_wp" ]] || exit 1
  afk_orca_run pm-bootstrap-worktree -- worktree show --worktree "path:$fs_actual_path" --json || exit 1
  fs_shown="$AFK_ORCA_OUT"
  fs_observed_id="$(jq -r '.result.worktree.id // .result.id // .worktree.id // .id // empty' <<<"$fs_shown" 2>/dev/null)"
  fs_observed_path="$(jq -r '.result.worktree.path // .result.path // .worktree.path // .path // empty' <<<"$fs_shown" 2>/dev/null)"
  fs_observed_path="$(cd "$fs_observed_path" 2>/dev/null && pwd -P)" || fs_observed_path=""
  [[ -n "$fs_observed_id" && "$fs_observed_id" == "$fs_wi" && "$fs_observed_path" == "$fs_wp" ]] || exit 1
  case "$fs_harness" in
    claude) fs_harness_bin="${AFK_CLAUDE_BIN:-claude}" ;;
    codex) fs_harness_bin="${AFK_CODEX_BIN:-codex}" ;;
    opencode) fs_harness_bin="${AFK_OPENCODE_BIN:-opencode}" ;;
  esac
  export AFK_RUNTIME_ROLE=PM
  export ORCA_WORKTREE_ID="$fs_observed_id" ORCA_WORKTREE_PATH="$fs_observed_path"
  if [[ "$fs_harness" == opencode ]]; then exec "$fs_harness_bin" --prompt "$fs_resume"; fi
  exec "$fs_harness_bin" -- "$fs_resume"
fi

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
afk_orca_run pm-bootstrap-worktree -- worktree show --worktree "path:$actual_path" --json || exit 1
shown="$AFK_ORCA_OUT"
observed_id="$(jq -r '.result.worktree.id // .result.id // .worktree.id // .id // empty' <<<"$shown" 2>/dev/null)"
observed_path="$(jq -r '.result.worktree.path // .result.path // .worktree.path // .path // empty' <<<"$shown" 2>/dev/null)"
observed_path="$(cd "$observed_path" 2>/dev/null && pwd -P)" || observed_path=""
[[ -n "$observed_id" && "$observed_id" == "$wi" && "$observed_path" == "$wp" ]] || exit 1

# Orca may start the command before the launcher persists its receipt.  Wait a
# bounded interval for that durable gate; never start a harness before it.
tries="${AFK_PM_BOOTSTRAP_POLLS:-50}"; delay="${AFK_PM_BOOTSTRAP_POLL_SECONDS:-0.1}"
while ((tries-- > 0)); do
  if jq -e --arg id "$tid" --arg t "$ORCA_TERMINAL_HANDLE" --arg h "$harness" --arg wi "$wi" --arg wp "$wp" \
    --arg continuation_sha "$continuation_sha" --arg run "$(jq -r '.run_id // empty' "$intent")" \
    '(.schema|IN("afk-pm-handoff/2","afk-pm-handoff/3")) and .transition_id==$id and .state=="SUCCESSOR_LAUNCHED" and
     .continuation_sha256==$continuation_sha and .successor.terminal==$t and .successor.harness==$h and
     .successor.worktree.id==$wi and .successor.worktree.path==$wp and
     .successor.run_id==(if $run=="" then null else $run end)' \
    "$pm_dir/handoff.json" >/dev/null 2>&1 &&
    [[ -f "$pm_dir/transitions/$tid/launch-receipt.json" &&
       -f "$pm_dir/transitions/$tid/launch-create.json" &&
       -f "$pm_dir/transitions/$tid/launch-attempt.json" ]] &&
    receipt="$(jq -c . "$pm_dir/transitions/$tid/launch-receipt.json" 2>/dev/null)" &&
    create="$(jq -c . "$pm_dir/transitions/$tid/launch-create.json" 2>/dev/null)" &&
    attempt="$(jq -c . "$pm_dir/transitions/$tid/launch-attempt.json" 2>/dev/null)" &&
    afk_pmc_launch_evidence "$receipt" "$create" "$attempt" "$(jq -c . "$intent")" &&
    jq -e --arg t "$ORCA_TERMINAL_HANDLE" '.terminal==$t' <<<"$receipt" >/dev/null 2>&1; then
    break
  fi
  sleep "$delay"
done
((tries >= 0)) || exit 1
if [[ -f "$pm_dir/ownership.json" ]] || jq -e 'has("expected_old")' "$pm_dir/handoff.json" >/dev/null 2>&1; then
  owner="$(jq -c . "$pm_dir/ownership.json" 2>/dev/null)" || exit 1
  common="$(afk_pmc_common_dir "$wp")" || exit 1
  [[ "$(afk_pmc_handoff_state "$(jq -c . "$pm_dir/handoff.json")" "$owner" "$common")" != conflict ]] || exit 1
fi
if jq -e '.identity!=null' <<<"$receipt" >/dev/null 2>&1; then
  afk_orca_identity "$ORCA_TERMINAL_HANDLE" "$harness" || exit 1
  jq -e --argjson expected "$(jq -c .identity <<<"$receipt")" '
    {handle,runtime_id,execution_host_id,worktree_id,tab_id,leaf_id,incarnation_id,agent_type}==
    ($expected|{handle,runtime_id,execution_host_id,worktree_id,tab_id,leaf_id,incarnation_id,agent_type})' \
    <<<"$AFK_ORCA_IDENTITY" >/dev/null 2>&1 || exit 1
fi

# Run continuity is a precondition when the old coordinator declared a Run.
# A timeout, refusal, or receipt that does not prove this terminal's binding
# stops before the harness starts.
run_id="$(jq -r '.run_id // empty' "$intent")"
if [[ -n "$run_id" ]]; then
  afk_orca_run pm-bootstrap-run-use -- orchestration run-use --id "$run_id" --from "$ORCA_TERMINAL_HANDLE" --json || exit 1
  run_receipt="$AFK_ORCA_OUT"
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
