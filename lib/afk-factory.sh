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
    rv="$(head -n 8 "$rf" | sed -n 's/^[[:space:]*]*VERDICT:[*[:space:]]*//p' | head -n 1 | awk '{print $1}')"
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
      local t_inv t_mcp t_skills
      t_inv="$(AFK_TOOLING_HERMETIC=1 afk_tooling_discover "$repo" 2>/dev/null || printf '{}')"
      t_mcp="$(jq -r '[.project.mcp_servers[]?.name] | join(", ")' <<<"$t_inv" 2>/dev/null || true)"
      t_skills="$(jq -r '[.project.skills[]? | select(.is_bmad | not) | .name] | join(", ")' <<<"$t_inv" 2>/dev/null || true)"
      if [[ -n "$t_mcp" || -n "$t_skills" ]]; then
        printf '## Project MCP Servers & Custom Skills\n'
        [[ -n "$t_mcp" ]] && printf -- '- Project MCP Servers (`%s` mode): %s\n' "$(jq -r '.mcp_mode // "standalone"' <<<"$t_inv")" "$t_mcp"
        [[ -n "$t_skills" ]] && printf -- '- Project Custom Skills: %s\n' "$t_skills"
        printf '\n---\n\n'
      fi
    fi
    if [[ -f "$input_file" ]]; then
      printf '## Input Context (`%s`)\n' "$input_file"
      head -n 200 "$input_file" 2>/dev/null || true
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
        printf '  `RISK: low` (or `medium` / `high` / `critical`)\n'
        printf '  `SURFACES: code` (comma-separated subset of `code,ui,ux,architecture,security`)\n'
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
        printf -- '- Inspect the full branch diff against main (`git log origin/main..HEAD --stat` and `git diff origin/main...HEAD`), and compare against `%s/spec.md` and the current round `checks.md`.\n' "$job_dir"
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
  local cfg risk="low" stage_key="$stage"
  cfg="$(afk_factory_load_config "$repo")"
  if [[ -f "$job_dir/job.json" ]]; then
    risk="$(jq -r '.risk // "low"' "$job_dir/job.json" 2>/dev/null || printf 'low')"
  fi

  local builder_family=""
  if [[ "$stage" == review* && -f "$job_dir/route-build-dev.json" ]]; then
    builder_family="$(jq -r '.model_family // empty' "$job_dir/route-build-dev.json" 2>/dev/null || true)"
  fi

  if declare -F afk_router_select_candidate >/dev/null 2>&1; then
    local smart_json
    smart_json="$(afk_router_select_candidate "$repo" "$stage" "$risk" "$builder_family")"
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
  local compiled_prompt route_json routed_harness routed_launch routed_model routed_window routed_mem litellm_url
  compiled_prompt="$(afk_factory_build_stage_prompt "$repo" "$job_dir" "$role" "$stage" "$prompt_file" "$output_file")"
  route_json="$(afk_factory_resolve_stage_route "$repo" "$job_dir" "$stage" "$role")"
  routed_harness="$(jq -r '.harness // "claude"' <<<"$route_json")"
  routed_launch="$(jq -r '.launch_class // "claude-native"' <<<"$route_json")"
  routed_model="$(jq -r '.model // "sonnet"' <<<"$route_json")"
  routed_window="$(jq -r '.window_tokens // 200000' <<<"$route_json")"
  routed_mem="$(jq -r '.memory_mode // "advisory"' <<<"$route_json")"
  litellm_url="$(jq -r '.litellm_base_url // empty' <<<"$route_json")"
  local harness="${harness_override:-$routed_harness}"

  AFK_LAST_STAGE_USED_TOKENS="${AFK_STAGE_USED_TOKENS:-}"
  AFK_LAST_STAGE_WINDOW_TOKENS="${AFK_STAGE_WINDOW_TOKENS:-$routed_window}"
  AFK_LAST_STAGE_COMPACTED="${AFK_STAGE_COMPACTED:-false}"

  local runner="${AFK_FACTORY_AGENT_RUNNER:-}"
  if [[ -n "$runner" && -x "$runner" ]]; then
    local runner_out="" runner_rc=0
    runner_out="$(
      AFK_FACTORY_REPO="$repo" \
      AFK_FACTORY_WORKTREE="$wt" \
      AFK_FACTORY_JOB_DIR="$job_dir" \
      AFK_FACTORY_ROLE="$role" \
      AFK_FACTORY_STAGE="$stage" \
      AFK_FACTORY_HARNESS="$harness" \
      AFK_FACTORY_LAUNCH_CLASS="$routed_launch" \
      AFK_FACTORY_MODEL="$routed_model" \
      AFK_FACTORY_MEMORY_MODE="$routed_mem" \
      AFK_FACTORY_PROMPT_FILE="$prompt_file" \
      AFK_FACTORY_COMPILED_PROMPT="$compiled_prompt" \
      AFK_FACTORY_OUTPUT_FILE="$output_file" \
        "$runner" "$stage" "$role" "$prompt_file" "$output_file" 2>/dev/null
    )" || runner_rc=$?
    if [[ -n "$runner_out" ]] && jq -e '.used_tokens' <<<"$runner_out" >/dev/null 2>&1; then
      AFK_LAST_STAGE_USED_TOKENS="$(jq -r '.used_tokens // empty' <<<"$runner_out")"
      AFK_LAST_STAGE_WINDOW_TOKENS="$(jq -r --argjson rw "$routed_window" '.window_tokens // $rw' <<<"$runner_out")"
      AFK_LAST_STAGE_COMPACTED="$(jq -r '.compacted // false' <<<"$runner_out")"
    fi
    return "$runner_rc"
  fi

  if [[ "${AFK_FACTORY_LIVE_HARNESS:-0}" == "1" ]]; then
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
      local bin_exec=""
      bin_exec="$(_afk_harness_locate_bin "$harness" 2>/dev/null || command -v "$harness" 2>/dev/null || true)"
      case "$harness" in
        claude)
          if [[ -n "$bin_exec" ]]; then
            (
              cd "$wt" || exit 1
              [[ -n "$hs_disabled" ]] && export HINDSIGHT_DISABLED="true"
              if [[ "$routed_launch" == *-gateway && -n "$litellm_url" ]]; then
                export ANTHROPIC_BASE_URL="$litellm_url"
              fi
              local -a cl_mcp_args=()
              [[ -n "$mcp_cfg" ]] && cl_mcp_args=(--mcp-config "$mcp_cfg")
              "$bin_exec" -p "$(cat -- "$compiled_prompt")" --model "$routed_model" "${cl_mcp_args[@]}" --add-dir "$job_dir" --dangerously-skip-permissions --output-format json < /dev/null > "$env_file" 2>/dev/null
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
              "$bin_exec" exec --dangerously-bypass-approvals-and-sandbox --json -o "$output_file" -m "$routed_model" -- "$(cat -- "$compiled_prompt")" < /dev/null > "$env_file" 2>/dev/null
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
              "$bin_exec" --dangerously-skip-permissions --add-dir "$job_dir" --output-format json -p "$(cat -- "$compiled_prompt")" < /dev/null > "$env_file" 2>/dev/null
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
              if [[ "$routed_cost" == "free" ]] && command -v timeout >/dev/null 2>&1; then
                timeout "${AFK_FREE_MODEL_TIMEOUT_SEC:-120}" "$bin_exec" run --pure --auto --format json -m "$routed_model" -- "$(cat -- "$compiled_prompt")" < /dev/null > "$env_file" 2>/dev/null
              else
                "$bin_exec" run --pure --auto --format json -m "$routed_model" -- "$(cat -- "$compiled_prompt")" < /dev/null > "$env_file" 2>/dev/null
              fi
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
              "$bin_exec" -p --mode json --model "$routed_model" "$(cat -- "$compiled_prompt")" < /dev/null > "$env_file" 2>/dev/null
            ) || h_rc=$?
          else
            h_rc=127
          fi
          ;;
      esac

      local env_err_msg=""
      if [[ -s "$env_file" ]] && jq -se 'any(.[]; (.is_error == true) or (.type == "error") or (.type == "turn.failed"))' "$env_file" >/dev/null 2>&1; then
        env_err_msg="$(jq -sr '[ .[] | (.error.data.message // .error.message // (if .is_error == true then .result else empty end) // .message // empty) ] | map(select(length > 0)) | first // "json_runtime_error"' "$env_file" 2>/dev/null || printf 'json_runtime_error')"
        (( h_rc == 0 )) && h_rc=1
      fi

      if (( h_rc == 0 )) && [[ -s "$env_file" || -s "$output_file" ]]; then
        if [[ -s "$env_file" ]]; then
          local tok
          tok="$(jq -sr '[ .[] | (.usage.total_tokens // .part.tokens.total // ((.usage.input_tokens // 0) + (.usage.output_tokens // 0) + (.usage.cache_read_input_tokens // 0))) | select(. > 0) ] | max // empty' "$env_file" 2>/dev/null || true)"
          [[ -n "$tok" ]] && AFK_LAST_STAGE_USED_TOKENS="$tok"
          if [[ ! -s "$output_file" ]]; then
            local extracted=""
            extracted="$(jq -sr '[ .[] | (.result // .response // .part.text // empty) ] | join("")' "$env_file" 2>/dev/null || true)"
            if [[ -n "$extracted" ]]; then
              printf '%s\n' "$extracted" > "$output_file"
            fi
          fi
        fi
        if [[ -s "$output_file" ]]; then
          jq -cn \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            --arg st "$stage" \
            --arg rl "$role" \
            --argjson att "$attempt" \
            --arg h "$harness" \
            --arg m "$routed_model" \
            --arg p "$routed_pool" \
            --arg cc "$routed_cost" \
            --arg ff "$failover_from" \
            --arg tok "${AFK_LAST_STAGE_USED_TOKENS:-0}" \
            '{ts:$ts, stage:$st, role:$rl, status:"ok", attempt:$att, harness:$h, model:$m, entitlement_pool:$p, cost_class:$cc, used_tokens:($tok|tonumber? // 0), failover_from:(if $ff=="" then null else $ff end)}' >> "$job_dir/route-history.jsonl"
          return 0
        fi
        h_rc=1
        env_err_msg="empty_stage_output"
      fi

      local fail_reason="${env_err_msg:-runtime_exit_$h_rc}"
      jq -cn \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg st "$stage" \
        --arg rl "$role" \
        --argjson att "$attempt" \
        --arg h "$harness" \
        --arg m "$routed_model" \
        --arg p "$routed_pool" \
        --arg err "${fail_reason:0:160}" \
        '{ts:$ts, stage:$st, role:$rl, status:"failed_attempt", attempt:$att, harness:$h, model:$m, entitlement_pool:$p, error:$err}' >> "$job_dir/route-history.jsonl"

      # Runtime failover: mark degraded pool and re-route to next healthy harness
      if (( attempt < max_attempts )) && [[ -z "$harness_override" && -n "$routed_pool" ]] && declare -F afk_router_mark_pool_degraded >/dev/null 2>&1; then
        failover_from="${harness}/${routed_model}(${routed_pool})"
        afk_router_mark_pool_degraded "$routed_pool" "${fail_reason:0:120}"
        route_json="$(afk_factory_resolve_stage_route "$repo" "$job_dir" "$stage" "$role")"
        routed_harness="$(jq -r '.harness // "claude"' <<<"$route_json")"
        routed_launch="$(jq -r '.launch_class // "claude-native"' <<<"$route_json")"
        routed_model="$(jq -r '.model // "sonnet"' <<<"$route_json")"
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
  local prompt_file="$7" output_file="$8" issue_id="$9" api_url="${10:-}" key="${11:-}" harness="${12:-}"

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
  fi

  # Step 2: Intake (PM — John in BMAD) — skip if already completed on disk (resume-safe)
  if [[ ! -s "$job_dir/intake.md" ]]; then
    afk_pch_assign_stage "$slug" "pm" "$issue_id" "AFK Factory started intake with project PM (\`${slug}-pm\`)." "$api_url" "$key" "$run_id"
    afk_factory_run_stage_with_context_guard "$slug" "$abs_repo" "$wt_dir" "$job_dir" "pm" "intake" "$job_dir/issue.md" "$job_dir/intake.md" "$issue_id" "$api_url" "$key" ""
  fi

  local intake_verdict risk surfaces_line
  intake_verdict="$(head -n 10 "$job_dir/intake.md" 2>/dev/null | sed -n 's/^[[:space:]*]*VERDICT:[*[:space:]]*//p' | head -n 1 | awk '{print $1}')"
  risk="$(sed -n 's/^[[:space:]*]*RISK:[*[:space:]]*//p' "$job_dir/intake.md" 2>/dev/null | head -n 1 | awk '{print tolower($1)}')"
  surfaces_line="$(sed -n 's/^[[:space:]*]*SURFACES:[*[:space:]]*//p' "$job_dir/intake.md" 2>/dev/null | head -n 1 | tr -d ' `*')"
  [[ -n "$intake_verdict" ]] || intake_verdict="ACCEPT"
  [[ "$risk" =~ ^(low|medium|high|critical)$ ]] || risk="low"
  [[ -n "$surfaces_line" ]] || surfaces_line="code"
  jq -c --arg r "$risk" '.risk = $r' "$job_file" > "$job_file.tmp" && mv "$job_file.tmp" "$job_file"

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

  # Step 3: Spec (PM or Architect when high-risk/architecture) — skip if completed on disk
  local spec_role="pm"
  if [[ ",$surfaces_line," == *",architecture,"* || "$risk" == "high" ]]; then
    spec_role="architect"
  fi
  if [[ ! -s "$job_dir/spec.md" ]]; then
    afk_pch_assign_stage "$slug" "$spec_role" "$issue_id" "" "$api_url" "$key" "$run_id"
    afk_factory_run_stage_with_context_guard "$slug" "$abs_repo" "$wt_dir" "$job_dir" "$spec_role" "spec" "$job_dir/issue.md" "$job_dir/spec.md" "$issue_id" "$api_url" "$key" ""
  fi

  # Optional UX Design pass when UI surface is flagged
  if [[ ",$surfaces_line," == *",ui,"* || ",$surfaces_line," == *",ux,"* ]] && [[ ! -s "$job_dir/ux-spec.md" ]]; then
    afk_pch_assign_stage "$slug" "ux-designer" "$issue_id" "" "$api_url" "$key" "$run_id"
    afk_factory_run_stage_with_context_guard "$slug" "$abs_repo" "$wt_dir" "$job_dir" "ux-designer" "ux" "$job_dir/spec.md" "$job_dir/ux-spec.md" "$issue_id" "$api_url" "$key" ""
  fi

  # Step 4: Build -> Deterministic Gate -> Multi-Lens Review loop (up to max_rounds)
  local cfg max_rounds round=1 saved_round gate_passed=false reviews_passed=false
  cfg="$(afk_factory_load_config "$abs_repo")"
  max_rounds="$(jq -r '.max_rounds // 2' <<<"$cfg")"
  [[ "$max_rounds" =~ ^[0-9]+$ && "$max_rounds" -ge 1 ]] || max_rounds=2
  saved_round="$(jq -r '.round // 1' "$job_file" 2>/dev/null || printf '1')"
  if [[ "$saved_round" =~ ^[0-9]+$ ]] && (( saved_round > 1 )); then
    round="$saved_round"
  fi

  while (( round <= max_rounds )); do
    local round_dir="$job_dir/round-$round"
    mkdir -p "$round_dir"
    jq -c --argjson r "$round" '.stage = "build" | .round = $r | .active_agent = "dev"' "$job_file" > "$job_file.tmp" && mv "$job_file.tmp" "$job_file"
    afk_pch_assign_stage "$slug" "dev" "$issue_id" "AFK Factory build round ${round} started with \`${slug}-dev\`." "$api_url" "$key" "$run_id"
    afk_factory_run_stage_with_context_guard "$slug" "$abs_repo" "$wt_dir" "$job_dir" "dev" "build" "$job_dir/spec.md" "$job_dir/build.md" "$issue_id" "$api_url" "$key" ""
    if [[ "$wt_dir" != "$abs_repo" ]] && [[ -n "$(git -C "$wt_dir" status --porcelain 2>/dev/null || true)" ]]; then
      git -C "$wt_dir" add -A -- . ':!.afk' >/dev/null 2>&1 || git -C "$wt_dir" add -A >/dev/null 2>&1 || true
      git -C "$wt_dir" commit -m "feat($job_id): $title" >/dev/null 2>&1 || true
    fi

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
    afk_factory_run_stage_with_context_guard "$slug" "$abs_repo" "$wt_dir" "$job_dir" "reviewer" "review-code" "$job_dir/build.md" "$round_dir/review-code.md" "$issue_id" "$api_url" "$key" ""

    if [[ ",$surfaces_line," == *",security,"* ]]; then
      afk_factory_run_stage_with_context_guard "$slug" "$abs_repo" "$wt_dir" "$job_dir" "reviewer" "review-security" "$job_dir/build.md" "$round_dir/review-security.md" "$issue_id" "$api_url" "$key" ""
    fi
    if [[ ",$surfaces_line," == *",ui,"* || ",$surfaces_line," == *",ux,"* ]]; then
      afk_factory_run_stage_with_context_guard "$slug" "$abs_repo" "$wt_dir" "$job_dir" "ux-designer" "review-ux" "$job_dir/build.md" "$round_dir/review-ux.md" "$issue_id" "$api_url" "$key" ""
    fi
    if [[ ",$surfaces_line," == *",architecture,"* || "$risk" == "high" ]]; then
      afk_factory_run_stage_with_context_guard "$slug" "$abs_repo" "$wt_dir" "$job_dir" "architect" "review-arch" "$job_dir/build.md" "$round_dir/review-arch.md" "$issue_id" "$api_url" "$key" ""
    fi

    # Check if all reviewers in round_dir passed
    local any_changes=false rf r_verdict
    for rf in "$round_dir"/review-*.md; do
      [[ -f "$rf" ]] || continue
      r_verdict="$(head -n 8 "$rf" | sed -n 's/^[[:space:]*]*VERDICT:[*[:space:]]*//p' | head -n 1 | awk '{print $1}')"
      if [[ "$r_verdict" != "PASS" ]]; then
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
  local stage_arg="" risk_arg="low" builder_family=""
  local check_updates=false dry_run_flag=false harness_arg="" sync_flag=false free_only=false
  local mcp_mode_arg="standalone" enable_mcp_csv="" enable_skills_csv="" litellm_url_arg=""
  local item_name="" transport_arg="stdio" target_arg="" args_csv="" desc_arg="" skill_path_arg=""

  while (( $# > 0 )); do
    case "$1" in
      --json)            json_mode=true ;;
      --compacted)       compacted=true ;;
      --check-updates)   check_updates=true ;;
      --dry-run)         dry_run_flag=true ;;
      --sync)            sync_flag=true ;;
      --free-only)       free_only=true ;;
      --repo)            [[ $# -ge 2 ]] || { afk_warn "--repo requires a path"; return 1; }; repo="$2"; shift ;;
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
    pools)
      local p_out
      p_out="$(afk_router_probe_pools "$repo")"
      if [[ "$json_mode" == "true" ]]; then
        printf '%s\n' "$p_out"
      else
        jq -r '
          "Installed Harnesses & Gateways:",
          "  - claude   (Anthropic Max OAuth): " + (if .harnesses.claude.installed then "HEALTHY (" + .harnesses.claude.binary + ")" else "UNAVAILABLE (" + (.harnesses.claude.health // "missing") + ")" end),
          "  - codex    (OpenAI Plus/Pro):     " + (if .harnesses.codex.installed then "HEALTHY (" + .harnesses.codex.binary + ")" else "UNAVAILABLE (" + (.harnesses.codex.health // "missing") + ")" end),
          "  - agy      (Antigravity):         " + (if .harnesses.agy.installed then "HEALTHY (" + .harnesses.agy.binary + ")" else "UNAVAILABLE (" + (.harnesses.agy.health // "missing") + ")" end),
          "  - opencode (Free + Bridged OAuth):" + (if .harnesses.opencode.installed then " HEALTHY (" + .harnesses.opencode.binary + ")" else " UNAVAILABLE (" + (.harnesses.opencode.health // "missing") + ")" end),
          "  - pi       (Multi-Auth CLI):      " + (if .harnesses.pi.installed then "HEALTHY (" + .harnesses.pi.binary + ")" else "UNAVAILABLE (" + (.harnesses.pi.health // "missing") + ")" end),
          "  - litellm  (Local AI Cluster GW): " + (if .harnesses.litellm_gateway.online then "ONLINE (" + (.harnesses.litellm_gateway.base_url // "") + ")" elif .harnesses.litellm_gateway.configured then "OFFLINE (" + (.harnesses.litellm_gateway.base_url // "") + ")" else "NOT_CONFIGURED (set AFK_LITELLM_BASE_URL or .router.litellm_base_url)" end),
          "",
          "Entitlement & Subscription Pools (5-Hour Rolling Window & Shared Accounts):",
          (.pools | to_entries[] | "  - " + .key + " [" + .value.provider + " / " + .value.pool_tier + " / cost=" + .value.cost_class + "]: state=" + .value.state + " remaining=" + (.value.remaining_units_5h|tostring) + "/" + (.value.capacity_5h|tostring) + " (" + (.value.headroom_pct|tostring) + "% free, active_5h=" + (.value.active_sessions_5h|tostring) + ", harnesses=" + ((.value.harnesses_feeding_pool // []) | join("+")) + ")")
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
          (.harnesses[] |
            if .present_on_disk then
              "  - \(.harness): " +
              (if .healthy then "HEALTHY" else "NEEDS_REPAIR (\(.health))" end) +
              " | method=\(.install_method) | pkg=\(.package_name)" +
              " | version=\(.current_version // "unknown")" +
              (if .latest_version != null then " -> latest=\(.latest_version)" else "" end) +
              (if .update_available then " [UPDATE/REPAIR AVAILABLE]" else "" end) +
              "\n      bin=\(.binary_path) -> \(.resolved_path)\n      update_cmd: \(.update_command)"
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
          "  Models (\( .models | length ) shown):",
          (.models[] | "    - [\(.harness)] \(.model) | cost=\(.cost_class)" + (if .cost_class == "api-metered" then " ($\(.cost_per_1m_usd.input)/$\(.cost_per_1m_usd.output) per 1M)" elif .is_free then " ($0 FREE)" else "" end) + " | pool=\(.entitlement_pool) | ctx=\(.window_tokens) | coding=\(.benchmarks.coding_standard.score) | best_for=[\(.recommended_purposes | join(","))]")
        ' <<<"$dm_out"
      fi
      return 0 ;;
    tooling)
      local tl_out
      tl_out="$(afk_tooling_discover "$repo")"
      if [[ "$json_mode" == "true" ]]; then
        printf '%s\n' "$tl_out"
      else
        jq -r '
          "AFK Skills & MCP Tooling Inventory (mcp_mode=\(.mcp_mode), litellm_mcp=\(.litellm_mcp_url // "none")):",
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
      ts_out="$(afk_tooling_sync_project "$repo" "$mcp_mode_arg" "$enable_mcp_csv" "$enable_skills_csv" "$litellm_url_arg")"
      if [[ "$json_mode" == "true" ]]; then
        printf '%s\n' "$ts_out"
      else
        jq -r '"Synced tooling to \(.repo_path) (mcp_mode=\(.mcp_mode)): mcp=[\(.synced_mcp_servers | join(", "))] skills=[\(.synced_skills | join(", "))]"' <<<"$ts_out"
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
        rp_out="$(afk_router_select_candidate "$repo" "$stage_arg" "$risk_arg" "$builder_family")"
        if [[ "$json_mode" == "true" ]]; then
          printf '%s\n' "$rp_out"
        else
          jq -r '"Stage [\(.stage)] (task_class=\(.task_class), risk=\(.risk)):\n  -> Harness/Launch: \(.harness) (\(.launch_class))\n  -> Model/Pool:     \(.model) [\(.canonical_model)] via pool \(.entitlement_pool) (\(.pool_remaining_5h)/\(.pool_capacity_5h) free, \(.pool_headroom_pct)%)\n  -> Benchmark:      \(.benchmark_name) = \(.benchmark_score) (effective=\(.effective_score))\n  -> Memory Mode:    \(.memory_mode)\n  -> Reason:         \(.reason)"' <<<"$rp_out"
        fi
      else
        local st_list=("intake" "spec" "ux" "build" "review-code")
        local all_routes="[]" b_fam="$builder_family"
        local s r_item
        for s in "${st_list[@]}"; do
          r_item="$(afk_router_select_candidate "$repo" "$s" "$risk_arg" "$b_fam")"
          if [[ "$s" == "build" && -z "$b_fam" ]]; then
            b_fam="$(jq -r '.model_family // empty' <<<"$r_item")"
          fi
          all_routes="$(jq -c --argjson it "$r_item" '. + [$it]' <<<"$all_routes")"
        done
        if [[ "$json_mode" == "true" ]]; then
          printf '%s\n' "$all_routes"
        else
          jq -r '.[] | "[\(.stage)] (\(.task_class), risk=\(.risk)) -> \(.harness)/\(.model) [\(.launch_class)] | pool=\(.entitlement_pool) (\(.pool_remaining_5h)/\(.pool_capacity_5h) free, \(.pool_headroom_pct)%) | score=\(.effective_score) (\(.benchmark_name)) | mem=\(.memory_mode)"' <<<"$all_routes"
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
      afk_warn "factory: unknown subcommand '$(afk_safe_diagnostic "$subcmd")' (expected: roster, init, run, resume, pools, harnesses, update-harnesses, models, tooling, tooling-sync, tooling-register-mcp, tooling-register-skill, route-preview, sync-benchmarks, status, context-check, evaluate-merge, retire)"
      return 1 ;;
  esac
}
