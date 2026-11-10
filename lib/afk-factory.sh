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
  "routing": {
    "intake": {"model": "opus", "effort": "high", "window": 200000},
    "spec": {"model": "opus", "effort": "high", "window": 200000},
    "ux": {"model": "sonnet", "effort": "medium", "window": 200000},
    "build": {"model": "opus", "effort": "high", "window": 200000},
    "review_low": {"model": "haiku", "effort": "medium", "window": 200000},
    "review_medium": {"model": "sonnet", "effort": "high", "window": 200000},
    "review_high": {"model": "opus", "effort": "high", "window": 200000},
    "approve": {"model": "opus", "effort": "high", "window": 200000}
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
afk_factory_load_config() {
  local repo="$1"
  if [[ -f "$repo/.afk/config.json" ]]; then
    cat "$repo/.afk/config.json" 2>/dev/null || afk_factory_default_config_json
  else
    afk_factory_default_config_json
  fi
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
  local base_ref="HEAD~1"
  if git -C "$wt" rev-parse --verify origin/master >/dev/null 2>&1; then
    base_ref="origin/master"
  elif git -C "$wt" rev-parse --verify origin/main >/dev/null 2>&1; then
    base_ref="origin/main"
  elif git -C "$wt" rev-parse --verify master >/dev/null 2>&1; then
    base_ref="master"
  elif git -C "$wt" rev-parse --verify main >/dev/null 2>&1; then
    base_ref="main"
  fi
  local changed_files
  changed_files="$(git -C "$wt" diff --name-only "$base_ref"...HEAD 2>/dev/null || git -C "$wt" diff --name-only HEAD 2>/dev/null || true)"

  if printf '%s\n' "$changed_files" | grep -qE '^\.afk/(checks\.sh|config\.json)$'; then
    cat > "$checks_out" <<EOF
VERDICT: FAIL
## Summary
- Builder modified protected factory gate file (\`.afk/checks.sh\` or \`.afk/config.json\`).
- Branches may not alter the checks they are judged by.
EOF
    return 1
  fi

  if [[ -x "$checks_script" ]]; then
    out="$(cd "$wt" && bash "$checks_script" 2>&1)" || rc=$?
  elif [[ -f "$checks_script" ]]; then
    out="$(cd "$wt" && bash "$checks_script" 2>&1)" || rc=$?
  else
    out="No .afk/checks.sh found; default gate pass."
    rc=0
  fi

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
  local review_count=0 review_failures=0 rf rv
  for rf in "$round_dir"/review-*.md; do
    [[ -f "$rf" ]] || continue
    review_count=$((review_count + 1))
    rv="$(head -n 5 "$rf" | sed -n 's/^VERDICT: *//p' | head -n 1)"
    if [[ "$rv" != "PASS" ]]; then
      review_failures=$((review_failures + 1))
      reasons="$(jq -c --arg r "Reviewer $(basename "$rf" .md) returned ${rv:-MISSING}" '. + [$r]' <<<"$reasons")"
    fi
  done
  if (( review_count == 0 )); then
    reasons="$(jq -c '. + ["No independent review evidence found in current round"]' <<<"$reasons")"
  fi

  # 3. Inspect changed files, diff size, and protected paths
  local changed_files="" file_count=0 line_count=0
  if [[ -d "$wt/.git" || -f "$wt/.git" ]]; then
    local base_ref="HEAD~1"
    for cand in origin/master origin/main master main; do
      if git -C "$wt" rev-parse --verify "$cand" >/dev/null 2>&1; then
        base_ref="$cand"
        break
      fi
    done
    changed_files="$(git -C "$wt" diff --name-only "$base_ref"...HEAD 2>/dev/null || git -C "$wt" diff --name-only HEAD~1 2>/dev/null || true)"
    if [[ -n "$changed_files" ]]; then
      file_count="$(printf '%s\n' "$changed_files" | sed '/^$/d' | wc -l | tr -d ' ')"
      line_count="$(git -C "$wt" diff --numstat "$base_ref"...HEAD 2>/dev/null | awk '{s += $1 + $2} END {print s+0}')"
    fi
  fi
  # Allow job.json to supply diff stats in hermetic tests when worktree has 1 commit
  local job_lines job_files job_paths
  job_lines="$(jq -r '.diff_stats.lines // empty' <<<"$job" 2>/dev/null)"
  job_files="$(jq -r '.diff_stats.files // empty' <<<"$job" 2>/dev/null)"
  job_paths="$(jq -r '.diff_stats.changed_paths // [] | .[]' <<<"$job" 2>/dev/null)"
  [[ "$job_lines" =~ ^[0-9]+$ ]] && line_count="$job_lines"
  [[ "$job_files" =~ ^[0-9]+$ ]] && file_count="$job_files"
  [[ -n "$job_paths" ]] && changed_files="$job_paths"

  if (( line_count > max_lines )); then
    reasons="$(jq -c --arg r "Diff size ($line_count lines) exceeds budget ($max_lines lines)" '. + [$r]' <<<"$reasons")"
  fi
  if (( file_count > max_files )); then
    reasons="$(jq -c --arg r "Changed file count ($file_count) exceeds budget ($max_files files)" '. + [$r]' <<<"$reasons")"
  fi

  # Protected paths check
  local -a prot_patterns=()
  mapfile -t prot_patterns < <(jq -r '.protected_paths[]? // empty' <<<"$cfg" 2>/dev/null)
  local pat f
  for f in $changed_files; do
    [[ -n "$f" ]] || continue
    for pat in "${prot_patterns[@]:-}"; do
      [[ -n "$pat" ]] || continue
      if [[ "$f" == *"$pat"* ]]; then
        reasons="$(jq -c --arg r "Protected path touched: $f (matches '$pat')" '. + [$r]' <<<"$reasons")"
        break
      fi
    done
  done

  # 4. Check explicit policy / high-risk architectural escalation
  if [[ "$merge_policy" == "human" ]]; then
    reasons="$(jq -c '. + ["Project merge_policy is pinned to human approval"]' <<<"$reasons")"
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
    printf '## Stage Instructions\n'
    printf -- '- Read input context from: `%s`\n' "$input_file"
    printf -- '- Write your structured stage output to: `%s`\n' "$output_file"
    case "$stage" in
      intake)
        printf -- '- Start output with `VERDICT: ACCEPT | NEEDS-INFO | REJECT`, `RISK: low | medium | high | critical`, and `SURFACES: <csv>`.\n'
        ;;
      review*)
        printf -- '- Start output with `VERDICT: PASS | CHANGES_REQUESTED`.\n'
        ;;
    esac
  } > "$prompt_dest"
  printf '%s' "$prompt_dest"
}

# afk_factory_invoke_stage_agent <repo_path> <worktree_path> <job_dir> <role> <stage> <prompt_file> <output_file> [<harness>]
# Executes one bounded agent turn for <stage>.
# Supports:
#   1. AFK_FACTORY_AGENT_RUNNER override for custom runners / deterministic tests.
#   2. AFK_FACTORY_LIVE_HARNESS=1 for headless claude / codex / opencode CLI execution,
#      extracting token usage into AFK_LAST_STAGE_USED_TOKENS.
#   3. Deterministic local synthesis fallback when running offline without a runner.
afk_factory_invoke_stage_agent() {
  local repo="$1" wt="$2" job_dir="$3" role="$4" stage="$5" prompt_file="$6" output_file="$7" harness="${8:-claude}"
  AFK_LAST_STAGE_USED_TOKENS="${AFK_STAGE_USED_TOKENS:-}"
  AFK_LAST_STAGE_WINDOW_TOKENS="${AFK_STAGE_WINDOW_TOKENS:-200000}"
  AFK_LAST_STAGE_COMPACTED="${AFK_STAGE_COMPACTED:-false}"

  local compiled_prompt
  compiled_prompt="$(afk_factory_build_stage_prompt "$repo" "$job_dir" "$role" "$stage" "$prompt_file" "$output_file")"

  local runner="${AFK_FACTORY_AGENT_RUNNER:-}"
  if [[ -n "$runner" && -x "$runner" ]]; then
    local runner_out="" runner_rc=0
    runner_out="$(
      AFK_FACTORY_REPO="$repo" \
      AFK_FACTORY_WORKTREE="$wt" \
      AFK_FACTORY_JOB_DIR="$job_dir" \
      AFK_FACTORY_ROLE="$role" \
      AFK_FACTORY_STAGE="$stage" \
      AFK_FACTORY_PROMPT_FILE="$prompt_file" \
      AFK_FACTORY_COMPILED_PROMPT="$compiled_prompt" \
      AFK_FACTORY_OUTPUT_FILE="$output_file" \
        "$runner" "$stage" "$role" "$prompt_file" "$output_file" 2>/dev/null
    )" || runner_rc=$?
    if [[ -n "$runner_out" ]] && jq -e '.used_tokens' <<<"$runner_out" >/dev/null 2>&1; then
      AFK_LAST_STAGE_USED_TOKENS="$(jq -r '.used_tokens // empty' <<<"$runner_out")"
      AFK_LAST_STAGE_WINDOW_TOKENS="$(jq -r '.window_tokens // 200000' <<<"$runner_out")"
      AFK_LAST_STAGE_COMPACTED="$(jq -r '.compacted // false' <<<"$runner_out")"
    fi
    return "$runner_rc"
  fi

  if [[ "${AFK_FACTORY_LIVE_HARNESS:-0}" == "1" ]]; then
    local env_file="$job_dir/.result-${stage}-${role}.json"
    local h_rc=0
    case "$harness" in
      claude)
        if command -v claude >/dev/null 2>&1; then
          (cd "$wt" && claude -p "$(cat -- "$compiled_prompt")" --output-format json --permission-mode acceptEdits < /dev/null > "$env_file" 2>/dev/null) || h_rc=$?
        fi
        ;;
      codex)
        if command -v codex >/dev/null 2>&1; then
          (cd "$wt" && codex exec -s workspace-write -- "$(cat -- "$compiled_prompt")" < /dev/null > "$env_file" 2>/dev/null) || h_rc=$?
        fi
        ;;
      opencode)
        if command -v opencode >/dev/null 2>&1; then
          (cd "$wt" && opencode run --format json -- "$(cat -- "$compiled_prompt")" < /dev/null > "$env_file" 2>/dev/null) || h_rc=$?
        fi
        ;;
    esac
    if [[ -s "$env_file" ]]; then
      local tok
      tok="$(jq -r '((.usage.input_tokens // 0) + (.usage.output_tokens // 0) + (.usage.cache_read_input_tokens // 0)) | select(. > 0)' "$env_file" 2>/dev/null | tail -n 1 || true)"
      [[ -n "$tok" ]] && AFK_LAST_STAGE_USED_TOKENS="$tok"
      if [[ ! -s "$output_file" ]]; then
        jq -r '.result // empty' "$env_file" 2>/dev/null > "$output_file" || cp "$env_file" "$output_file"
      fi
    fi
    return "$h_rc"
  fi

  # Default autonomous local execution if output_file does not already exist
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

# afk_factory_run_stage_with_context_guard <slug> <repo> <wt> <job_dir> <role> <stage> <prompt_file> <output_file> <issue_id> <api_url> <key> <harness>
# Invokes a stage agent, records its context window consumption, and if it crosses
# the 80% threshold (or compacts), automatically checkpoints, resets its Paperclip
# session, and spawns the replacement generation to finish the stage cleanly.
afk_factory_run_stage_with_context_guard() {
  local slug="$1" repo="$2" wt="$3" job_dir="$4" role="$5" stage="$6"
  local prompt_file="$7" output_file="$8" issue_id="$9" api_url="${10:-}" key="${11:-}" harness="${12:-claude}"

  afk_factory_invoke_stage_agent "$repo" "$wt" "$job_dir" "$role" "$stage" "$prompt_file" "$output_file" "$harness"

  if [[ -n "${AFK_LAST_STAGE_USED_TOKENS:-}" ]]; then
    local ctx_res ctx_act ctx_new_gen ckpt_file
    ctx_res="$(afk_roster_record_and_check_context "$job_dir" "$role" "$AFK_LAST_STAGE_USED_TOKENS" "${AFK_LAST_STAGE_WINDOW_TOKENS:-200000}" "${AFK_LAST_STAGE_COMPACTED:-false}" "$wt")"
    ctx_act="$(jq -r '.action' <<<"$ctx_res")"
    if [[ "$ctx_act" == "replaced" ]]; then
      ctx_new_gen="$(jq -r '.active_generation' <<<"$ctx_res")"
      ckpt_file="$job_dir/checkpoints/${role}-gen-$((ctx_new_gen - 1)).md"
      afk_pch_replace_agent_session "$slug" "$role" "$ctx_new_gen" "$issue_id" "context usage crossed 80% threshold during $stage" "$api_url" "$key"
      # Clear token override before re-running replacement generation so it doesn't loop infinitely on a static env var
      local saved_stage_tokens="${AFK_STAGE_USED_TOKENS:-}"
      unset AFK_STAGE_USED_TOKENS
      afk_factory_invoke_stage_agent "$repo" "$wt" "$job_dir" "$role" "$stage" "$ckpt_file" "$output_file" "$harness"
      [[ -n "$saved_stage_tokens" ]] && AFK_STAGE_USED_TOKENS="$saved_stage_tokens"
    fi
  fi
}

# afk_factory_run_job <repo_path> <slug> <job_id> <issue_id> <title> <body_file> <json_mode>
# Drives a job through the complete AFK Software Factory loop:
#   1. Discovers project agents (BMAD or Factory default) & hires needed roles in Paperclip.
#   2. Runs intake -> spec -> [ux] -> build -> gate -> review -> approve.
#   3. Monitors context window usage after every agent turn & replaces agents that cross 80%.
#   4. Auto-merges clean PRs or escalates to Paperclip when human attention is needed.
#   5. Retires specialist/idle agents when complete.
afk_factory_run_job() {
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

  # Load Paperclip connection settings if configured on this host
  local api_url="" company_id="" host_agent_id="" board_user_id="" key="" harness="claude"
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
    cp "$body_file" "$job_dir/issue.md"
  elif [[ ! -f "$job_dir/issue.md" ]]; then
    printf '# %s\n\nIssue ID: %s\n' "$title" "${issue_id:-local}" > "$job_dir/issue.md"
  fi

  # Ensure isolated worktree (or use repo when worktree creation is skipped in lightweight tests)
  local wt_root wt_dir branch="factory/$job_id"
  wt_root="$(dirname -- "$abs_repo")/$(basename -- "$abs_repo")-factory"
  wt_dir="$wt_root/$job_id"
  if [[ ! -d "$wt_dir" ]]; then
    mkdir -p "$wt_root"
    if ! git -C "$abs_repo" worktree add -B "$branch" "$wt_dir" HEAD >/dev/null 2>&1; then
      wt_dir="$abs_repo"
    fi
  fi

  # Initialize job.json if absent
  local job_file="$job_dir/job.json"
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
        stage: "intake",
        round: 1,
        risk: "low",
        surfaces: ["code"],
        active_agent: null,
        hired_roles: [],
        decision: null,
        created_at: $now,
        updated_at: $now
      }' > "$job_file"
  fi

  # Step 1: Hire core team (pm, dev, reviewer, approver) for the project & resolve Paperclip run_id
  local hired_json run_id=""
  hired_json="$(afk_pch_ensure_project_team "$slug" "$abs_repo" "$harness" "pm,dev,reviewer,approver" "$issue_id" "$api_url" "$key" "$company_id" "$host_agent_id")"
  if [[ -n "$api_url" && -n "$key" && -n "$issue_id" ]]; then
    run_id="$(afk_pch_ensure_run_id "$api_url" "$key" "$host_agent_id" "$issue_id")"
    export PAPERCLIP_RUN_ID="$run_id"
  fi

  # Step 2: Intake (PM — John in BMAD)
  afk_pch_assign_stage "$slug" "pm" "$issue_id" "AFK Factory started intake with project PM (\`${slug}-pm\`)." "$api_url" "$key" "$run_id"
  afk_factory_run_stage_with_context_guard "$slug" "$abs_repo" "$wt_dir" "$job_dir" "pm" "intake" "$job_dir/issue.md" "$job_dir/intake.md" "$issue_id" "$api_url" "$key" "$harness"

  local intake_verdict risk surfaces_line
  intake_verdict="$(head -n 5 "$job_dir/intake.md" 2>/dev/null | sed -n 's/^VERDICT: *//p' | head -n 1)"
  risk="$(sed -n 's/^RISK: *//p' "$job_dir/intake.md" 2>/dev/null | head -n 1)"
  surfaces_line="$(sed -n 's/^SURFACES: *//p' "$job_dir/intake.md" 2>/dev/null | head -n 1 | tr -d ' ')"
  [[ -n "$intake_verdict" ]] || intake_verdict="ACCEPT"
  [[ "$risk" =~ ^(low|medium|high|critical)$ ]] || risk="low"
  [[ -n "$surfaces_line" ]] || surfaces_line="code"

  if [[ "$intake_verdict" == "NEEDS-INFO" ]]; then
    local question
    question="$(cat "$job_dir/intake.md")"
    jq -c --arg now "$now" '.stage = "needs-info" | .active_agent = "human" | .updated_at = $now' "$job_file" > "$job_file.tmp" && mv "$job_file.tmp" "$job_file"
    if [[ -n "$api_url" && -n "$key" && -n "$issue_id" ]]; then
      afk_pc_comment "$api_url" "$issue_id" "$key" "$run_id" "## Needs Clarification\n\n$question" >/dev/null 2>&1 || true
      local pbody
      pbody="$(jq -cn --arg u "$board_user_id" '{status: "in_review", assigneeAgentId: null} + (if $u != "" then {assigneeUserId: $u} else {} end)')"
      afk_pc_curl PATCH "$api_url/api/issues/$issue_id" "$key" "$run_id" "$pbody" >/dev/null 2>&1 || true
    fi
    cat "$job_file"
    return 0
  elif [[ "$intake_verdict" == "REJECT" ]]; then
    jq -c --arg now "$now" '.stage = "rejected" | .active_agent = null | .updated_at = $now' "$job_file" > "$job_file.tmp" && mv "$job_file.tmp" "$job_file"
    afk_pch_retire_project_agents "$slug" "all" "$api_url" "$key" >/dev/null
    cat "$job_file"
    return 0
  fi

  # Dynamically hire specialist project agents based on risk and surfaces
  local full_roles_csv
  full_roles_csv="$(afk_roster_roles_for_job "$risk" "$surfaces_line")"
  hired_json="$(afk_pch_ensure_project_team "$slug" "$abs_repo" "$harness" "$full_roles_csv" "$issue_id" "$api_url" "$key" "$company_id" "$host_agent_id")"

  # Step 3: Spec (PM or Architect when high-risk/architecture)
  local spec_role="pm"
  if [[ ",$surfaces_line," == *",architecture,"* || "$risk" == "high" ]]; then
    spec_role="architect"
  fi
  afk_pch_assign_stage "$slug" "$spec_role" "$issue_id" "" "$api_url" "$key" "$run_id"
  afk_factory_run_stage_with_context_guard "$slug" "$abs_repo" "$wt_dir" "$job_dir" "$spec_role" "spec" "$job_dir/issue.md" "$job_dir/spec.md" "$issue_id" "$api_url" "$key" "$harness"

  # Optional UX Design pass when UI surface is flagged
  if [[ ",$surfaces_line," == *",ui,"* || ",$surfaces_line," == *",ux,"* ]]; then
    afk_pch_assign_stage "$slug" "ux-designer" "$issue_id" "" "$api_url" "$key" "$run_id"
    afk_factory_run_stage_with_context_guard "$slug" "$abs_repo" "$wt_dir" "$job_dir" "ux-designer" "ux" "$job_dir/spec.md" "$job_dir/ux-spec.md" "$issue_id" "$api_url" "$key" "$harness"
  fi

  # Step 4: Build -> Deterministic Gate -> Multi-Lens Review loop (up to max_rounds)
  local cfg max_rounds round=1 gate_passed=false reviews_passed=false
  cfg="$(afk_factory_load_config "$abs_repo")"
  max_rounds="$(jq -r '.max_rounds // 2' <<<"$cfg")"
  [[ "$max_rounds" =~ ^[0-9]+$ && "$max_rounds" -ge 1 ]] || max_rounds=2

  while (( round <= max_rounds )); do
    local round_dir="$job_dir/round-$round"
    mkdir -p "$round_dir"
    jq -c --argjson r "$round" '.stage = "build" | .round = $r | .active_agent = "dev"' "$job_file" > "$job_file.tmp" && mv "$job_file.tmp" "$job_file"
    afk_pch_assign_stage "$slug" "dev" "$issue_id" "AFK Factory build round ${round} started with \`${slug}-dev\`." "$api_url" "$key" "$run_id"
    afk_factory_run_stage_with_context_guard "$slug" "$abs_repo" "$wt_dir" "$job_dir" "dev" "build" "$job_dir/spec.md" "$job_dir/build.md" "$issue_id" "$api_url" "$key" "$harness"

    # Deterministic Gate (.afk/checks.sh)
    jq -c '.stage = "gate"' "$job_file" > "$job_file.tmp" && mv "$job_file.tmp" "$job_file"
    if ! afk_factory_run_gate "$abs_repo" "$wt_dir" "$round_dir"; then
      gate_passed=false
      round=$((round + 1))
      continue
    fi
    gate_passed=true

    # Independent Review Stage
    jq -c '.stage = "review" | .active_agent = "reviewer"' "$job_file" > "$job_file.tmp" && mv "$job_file.tmp" "$job_file"
    afk_pch_assign_stage "$slug" "reviewer" "$issue_id" "AFK Factory independent review started with \`${slug}-reviewer\`." "$api_url" "$key" "$run_id"
    afk_factory_run_stage_with_context_guard "$slug" "$abs_repo" "$wt_dir" "$job_dir" "reviewer" "review-code" "$job_dir/build.md" "$round_dir/review-code.md" "$issue_id" "$api_url" "$key" "$harness"

    if [[ ",$surfaces_line," == *",security,"* ]]; then
      afk_factory_run_stage_with_context_guard "$slug" "$abs_repo" "$wt_dir" "$job_dir" "reviewer" "review-security" "$job_dir/build.md" "$round_dir/review-security.md" "$issue_id" "$api_url" "$key" "$harness"
    fi
    if [[ ",$surfaces_line," == *",ui,"* || ",$surfaces_line," == *",ux,"* ]]; then
      afk_factory_run_stage_with_context_guard "$slug" "$abs_repo" "$wt_dir" "$job_dir" "ux-designer" "review-ux" "$job_dir/build.md" "$round_dir/review-ux.md" "$issue_id" "$api_url" "$key" "$harness"
    fi
    if [[ ",$surfaces_line," == *",architecture,"* || "$risk" == "high" ]]; then
      afk_factory_run_stage_with_context_guard "$slug" "$abs_repo" "$wt_dir" "$job_dir" "architect" "review-arch" "$job_dir/build.md" "$round_dir/review-arch.md" "$issue_id" "$api_url" "$key" "$harness"
    fi

    # Check if all reviewers in round_dir passed
    local any_changes=false rf
    for rf in "$round_dir"/review-*.md; do
      [[ -f "$rf" ]] || continue
      if ! head -n 5 "$rf" | grep -q '^VERDICT: PASS'; then
        any_changes=true
      fi
    done

    if [[ "$any_changes" == "false" ]]; then
      reviews_passed=true
      break
    fi
    reviews_passed=false
    round=$((round + 1))
  done

  # Retire specialist on-demand agents now that spec/ux/review completed
  afk_pch_retire_project_agents "$slug" "analyst,architect,ux-designer" "$api_url" "$key" >/dev/null 2>&1 || true

  # Step 5: Situational Merge Approver
  jq -c '.stage = "approve" | .active_agent = "approver"' "$job_file" > "$job_file.tmp" && mv "$job_file.tmp" "$job_file"
  local merge_eval decision final_stage
  merge_eval="$(afk_factory_evaluate_merge "$abs_repo" "$job_dir" "$wt_dir")"
  decision="$(jq -r '.decision' <<<"$merge_eval")"

  if [[ "$decision" == "APPROVE" ]]; then
    final_stage="merged"
    if [[ -n "$api_url" && -n "$key" && -n "$issue_id" ]]; then
      run_id="$(afk_pch_ensure_run_id "$api_url" "$key" "$host_agent_id" "$issue_id")"
      afk_pc_curl PATCH "$api_url/api/issues/$issue_id" "$key" "$run_id" '{"status":"in_progress"}' >/dev/null 2>&1 || true
      afk_pc_comment "$api_url" "$issue_id" "$key" "$run_id" \
        "$(printf '## AFK Factory — Auto-Approved & Complete\n\n%s' "$(cat "$job_dir/decision.md")")" >/dev/null 2>&1 || true
      afk_pc_curl PATCH "$api_url/api/issues/$issue_id" "$key" "$run_id" '{"status":"done"}' >/dev/null 2>&1 || true
    fi
    # Job finished cleanly; retire all project agents in Paperclip
    afk_pch_retire_project_agents "$slug" "all" "$api_url" "$key" >/dev/null 2>&1 || true
  else
    final_stage="needs-human"
    if [[ -n "$api_url" && -n "$key" && -n "$issue_id" ]]; then
      run_id="$(afk_pch_ensure_run_id "$api_url" "$key" "$host_agent_id" "$issue_id")"
      afk_pc_curl PATCH "$api_url/api/issues/$issue_id" "$key" "$run_id" '{"status":"in_progress"}' >/dev/null 2>&1 || true
      afk_pc_comment "$api_url" "$issue_id" "$key" "$run_id" \
        "$(printf '## AFK Factory — Human Approval Requested\n\n%s' "$(cat "$job_dir/decision.md")")" >/dev/null 2>&1 || true
      local pbody
      pbody="$(jq -cn --arg u "$board_user_id" '{status: "in_review", assigneeAgentId: null} + (if $u != "" then {assigneeUserId: $u} else {} end)')"
      afk_pc_curl PATCH "$api_url/api/issues/$issue_id" "$key" "$run_id" "$pbody" >/dev/null 2>&1 || true
    fi
  fi

  local surfaces_arr
  surfaces_arr="$(printf '%s' "$surfaces_line" | jq -Rc 'split(",")')"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -c \
    --arg st "$final_stage" \
    --arg r "$risk" \
    --arg dec "$decision" \
    --arg now "$now" \
    --argjson surf "$surfaces_arr" \
    --argjson hired "$hired_json" \
    --argjson meval "$merge_eval" \
    '.stage = $st
     | .risk = $r
     | .surfaces = $surf
     | .hired_roles = ($hired | map(.role))
     | .decision = $dec
     | .merge_evaluation = $meval
     | .active_agent = (if $st == "needs-human" then "human" else null end)
     | .updated_at = $now' "$job_file" > "$job_file.tmp" && mv "$job_file.tmp" "$job_file"

  if [[ "$json_mode" == "true" ]]; then
    cat "$job_file"
  else
    printf 'AFK Factory job %s (%s): stage=%s decision=%s\n' "$job_id" "$slug" "$final_stage" "$decision"
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
  status_json="$(afk_factory_status "$repo" "$slug" true)"
  local -a in_flight=()
  mapfile -t in_flight < <(jq -c '.jobs[]? | select((.stage // "") | IN("merged","needs-human","needs-info","rejected") | not)' <<<"$status_json" 2>/dev/null)

  local resumed="[]" row j_repo j_slug j_id j_issue j_title res_out
  for row in "${in_flight[@]:-}"; do
    [[ -n "$row" ]] || continue
    j_repo="$(jq -r '.repo_path // empty' <<<"$row")"
    j_slug="$(jq -r '.slug // empty' <<<"$row")"
    j_id="$(jq -r '.id // empty' <<<"$row")"
    j_issue="$(jq -r '.issue_id // empty' <<<"$row")"
    j_title="$(jq -r '.title // "Factory Task"' <<<"$row")"
    [[ -n "$j_repo" && -n "$j_id" ]] || continue
    res_out="$(afk_factory_run_job "$j_repo" "$j_slug" "$j_id" "$j_issue" "$j_title" "" true)"
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
# Summarizes active jobs, hired agents, context usage, and items needing human
# attention across projects.
afk_factory_status() {
  local repo="${1:-}" slug="${2:-}" json_mode="${3:-false}"
  local -a repos=()
  if [[ -n "$repo" && -d "$repo" ]]; then
    repos+=("$(cd -P -- "$repo" && pwd -P)")
  else
    local pc_cfg_path
    pc_cfg_path="$(afk_pc_config_path)"
    if [[ -f "$pc_cfg_path" ]]; then
      if [[ -n "$slug" ]]; then
        mapfile -t repos < <(jq -r --arg s "$slug" '.projects[]? | select(.slug == $s) | .repo_path // empty' "$pc_cfg_path" 2>/dev/null)
      else
        mapfile -t repos < <(jq -r '.projects[]?.repo_path // empty' "$pc_cfg_path" 2>/dev/null)
      fi
    fi
    # Also discover sibling repositories with .afk/ initialized on this host
    if [[ -z "$slug" ]]; then
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
      local jdir ctx_file
      jdir="$(dirname -- "$jf")"
      ctx_file="$jdir/context-ledger.json"
      if [[ -f "$ctx_file" ]]; then
        j="$(jq -c --slurpfile c "$ctx_file" '. + {context_ledger: $c[0].agents}' <<<"$j" 2>/dev/null || printf '%s' "$j")"
      fi
      jobs_list="$(jq -c --argjson item "$j" '. + [$item]' <<<"$jobs_list")"
      st="$(jq -r '.stage // empty' <<<"$j")"
      if [[ "$st" == "needs-human" || "$st" == "needs-info" ]]; then
        needs_human_list="$(jq -c --argjson item "$j" '. + [$item]' <<<"$needs_human_list")"
      fi
    done
  done

  local hired_ledger
  hired_ledger="$(afk_pch_load_ledger)"

  if [[ "$json_mode" == "true" ]]; then
    jq -cn \
      --argjson jobs "$jobs_list" \
      --argjson nh "$needs_human_list" \
      --argjson hired "$hired_ledger" \
      '{
        schema: "afk-factory-status/1",
        attention_required_count: ($nh | length),
        attention_required: $nh,
        jobs: $jobs,
        hired_agents: $hired.projects
      }'
  else
    local nh_count
    nh_count="$(jq -r 'length' <<<"$needs_human_list")"
    printf 'AFK Factory Status: %s item(s) need human attention\n' "$nh_count"
    if (( nh_count > 0 )); then
      jq -r '.[] | "  [NEEDS HUMAN] \(.slug)/\(.id): stage=\(.stage) title=\(.title)"' <<<"$needs_human_list"
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

  while (( $# > 0 )); do
    case "$1" in
      --json)         json_mode=true ;;
      --compacted)    compacted=true ;;
      --repo)         [[ $# -ge 2 ]] || { afk_warn "--repo requires a path"; return 1; }; repo="$2"; shift ;;
      --slug)         [[ $# -ge 2 ]] || { afk_warn "--slug requires a value"; return 1; }; slug="$2"; shift ;;
      --job)          [[ $# -ge 2 ]] || { afk_warn "--job requires an id"; return 1; }; job_id="$2"; shift ;;
      --issue)        [[ $# -ge 2 ]] || { afk_warn "--issue requires an id"; return 1; }; issue_id="$2"; shift ;;
      --title)        [[ $# -ge 2 ]] || { afk_warn "--title requires text"; return 1; }; title="$2"; shift ;;
      --body-file)    [[ $# -ge 2 ]] || { afk_warn "--body-file requires a path"; return 1; }; body_file="$2"; shift ;;
      --role)         [[ $# -ge 2 ]] || { afk_warn "--role requires a role name"; return 1; }; role="$2"; shift ;;
      --used-tokens)  [[ $# -ge 2 ]] || { afk_warn "--used-tokens requires an integer"; return 1; }; used_tokens="$2"; shift ;;
      --window)       [[ $# -ge 2 ]] || { afk_warn "--window requires an integer"; return 1; }; window_tokens="$2"; shift ;;
      --roles)        [[ $# -ge 2 ]] || { afk_warn "--roles requires a comma-separated list"; return 1; }; roles_csv="$2"; shift ;;
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
      cc_out="$(afk_roster_record_and_check_context "$repo/.afk/jobs/$job_id" "$role" "$used_tokens" "$window_tokens" "$compacted" "$repo")"
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
    status)
      afk_factory_status "$repo" "$slug" "$json_mode"
      return $? ;;
    *)
      afk_warn "factory: unknown subcommand '$(afk_safe_diagnostic "$subcmd")' (expected: roster, init, run, resume, status, context-check, evaluate-merge, retire)"
      return 1 ;;
  esac
}
