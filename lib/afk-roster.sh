#!/usr/bin/env bash
# afk-roster.sh — Per-project agent roster discovery (BMAD & Factory roles) and
# agent context-window monitoring / automatic replacement handoff.
#
# AFK runs centrally on the host and manages agents per project. When a project
# contains BMAD personas (_bmad/bmm/agents/*.md or .agents/skills/bmad-agent-*),
# AFK discovers those exact personas (John/PM, Mary/Analyst, Winston/Architect,
# Sally/UX Designer, Amelia/Dev, Quinn/Reviewer). Otherwise it provides the
# built-in Software Factory agent roster.
#
# Also tracks each running project agent's context window usage (in integer PPM)
# and triggers automatic checkpointing (>= 70%) and agent replacement (>= 80%
# or compaction event) so no project agent ever compacts itself into a broken
# loop. This file is SOURCED, never executed.

# shellcheck disable=SC2034,SC2154
if [[ -n "${AFK_ROSTER_SOURCED:-}" ]]; then
  return 0
fi
AFK_ROSTER_SOURCED=1

AFK_ROSTER_CHECKPOINT_PPM=700000
AFK_ROSTER_REPLACE_PPM=800000
AFK_ROSTER_DEFAULT_WINDOW=200000
AFK_ROSTER_MAX_REPLACEMENTS=3

# afk_roster_resolve_skill <repo_path> <role>
# Resolves the project-local persona/skill markdown path for <role>, or prints
# "builtin" when the repo relies on AFK's built-in factory role prompt.
afk_roster_resolve_skill() {
  local repo="$1" role="$2"
  case "$role" in
    pm)
      for p in \
        "$repo/.agents/skills/bmad-agent-pm/SKILL.md" \
        "$repo/_bmad/bmm/agents/pm.md" \
        "$repo/.claude/agents/pm.md" \
        "$repo/.claude/agents/spec-writer.md" \
        "$repo/.github/agents/pm.md" \
        "$repo/.agents/skills/pm/SKILL.md"; do
        [[ -f "$p" ]] && { printf '%s' "$p"; return 0; }
      done ;;
    analyst)
      for p in \
        "$repo/.agents/skills/bmad-agent-analyst/SKILL.md" \
        "$repo/_bmad/bmm/agents/analyst.md" \
        "$repo/.claude/agents/analyst.md" \
        "$repo/.claude/agents/researcher.md" \
        "$repo/.github/agents/analyst.md" \
        "$repo/.agents/skills/analyst/SKILL.md"; do
        [[ -f "$p" ]] && { printf '%s' "$p"; return 0; }
      done ;;
    architect)
      for p in \
        "$repo/.agents/skills/bmad-agent-architect/SKILL.md" \
        "$repo/_bmad/bmm/agents/architect.md" \
        "$repo/.agents/skills/bmad-architecture/SKILL.md" \
        "$repo/.claude/agents/architect.md" \
        "$repo/.github/agents/architect.md" \
        "$repo/.agents/skills/architect/SKILL.md"; do
        [[ -f "$p" ]] && { printf '%s' "$p"; return 0; }
      done ;;
    ux-designer)
      for p in \
        "$repo/.agents/skills/bmad-agent-ux-designer/SKILL.md" \
        "$repo/_bmad/bmm/agents/ux-designer.md" \
        "$repo/.agents/skills/bmad-ux/SKILL.md" \
        "$repo/.claude/agents/ux-designer.md" \
        "$repo/.claude/agents/reviewer-ux.md" \
        "$repo/.github/agents/ux-designer.md" \
        "$repo/.agents/skills/ux-designer/SKILL.md"; do
        [[ -f "$p" ]] && { printf '%s' "$p"; return 0; }
      done ;;
    dev)
      for p in \
        "$repo/.agents/skills/bmad-agent-dev/SKILL.md" \
        "$repo/_bmad/bmm/agents/dev.md" \
        "$repo/.agents/skills/bmad-build/SKILL.md" \
        "$repo/.claude/agents/dev.md" \
        "$repo/.claude/agents/builder.md" \
        "$repo/.github/agents/dev.md" \
        "$repo/.agents/skills/dev/SKILL.md"; do
        [[ -f "$p" ]] && { printf '%s' "$p"; return 0; }
      done ;;
    reviewer)
      for p in \
        "$repo/.agents/skills/bmad-review/SKILL.md" \
        "$repo/.agents/skills/bmad-code-review/SKILL.md" \
        "$repo/.claude/agents/reviewer.md" \
        "$repo/.claude/agents/reviewer-code.md" \
        "$repo/.github/agents/reviewer.md" \
        "$repo/.agents/skills/reviewer/SKILL.md"; do
        [[ -f "$p" ]] && { printf '%s' "$p"; return 0; }
      done ;;
    approver)
      for p in \
        "$repo/.claude/agents/approver.md" \
        "$repo/.github/agents/approver.md" \
        "$repo/.agents/skills/approver/SKILL.md"; do
        [[ -f "$p" ]] && { printf '%s' "$p"; return 0; }
      done ;;
  esac
  printf 'builtin'
}

# afk_roster_detect_framework <repo_path>
# Prints "bmad", "custom", or "factory-default".
afk_roster_detect_framework() {
  local repo="$1"
  if [[ -f "$repo/.afk/roster.json" ]]; then
    jq -r '.framework // "custom"' "$repo/.afk/roster.json" 2>/dev/null || printf 'custom'
    return 0
  fi
  if [[ -d "$repo/_bmad" || -d "$repo/.agents/skills/bmad-agent-pm" || -d "$repo/.agents/skills/bmad-review" ]]; then
    printf 'bmad'
    return 0
  fi
  if [[ -d "$repo/.claude/agents" || -d "$repo/.github/agents" ]]; then
    printf 'custom'
    return 0
  fi
  printf 'factory-default'
}

# afk_roster_discover <repo_path>
# Emits the complete JSON roster for <repo_path>.
afk_roster_discover() {
  local repo="$1"
  if [[ -z "$repo" || ! -d "$repo" ]]; then
    return 1
  fi
  local abs_repo fw
  abs_repo="$(cd -P -- "$repo" 2>/dev/null && pwd -P)" || return 1
  if [[ -f "$abs_repo/.afk/roster.json" ]] && jq -e '.schema == "afk-project-roster/1" and (.agents | type == "array")' "$abs_repo/.afk/roster.json" >/dev/null 2>&1; then
    jq -c --arg r "$abs_repo" '.repo_path = $r' "$abs_repo/.afk/roster.json"
    return 0
  fi
  fw="$(afk_roster_detect_framework "$abs_repo")"
  local pm_skill analyst_skill arch_skill ux_skill dev_skill rev_skill app_skill
  pm_skill="$(afk_roster_resolve_skill "$abs_repo" pm)"
  analyst_skill="$(afk_roster_resolve_skill "$abs_repo" analyst)"
  arch_skill="$(afk_roster_resolve_skill "$abs_repo" architect)"
  ux_skill="$(afk_roster_resolve_skill "$abs_repo" ux-designer)"
  dev_skill="$(afk_roster_resolve_skill "$abs_repo" dev)"
  rev_skill="$(afk_roster_resolve_skill "$abs_repo" reviewer)"
  app_skill="$(afk_roster_resolve_skill "$abs_repo" approver)"

  local pm_name="Intake PM" analyst_name="Analyst" arch_name="Architect"
  local ux_name="UX Designer" dev_name="Builder" rev_name="Reviewer" app_name="Approver"
  if [[ "$fw" == "bmad" ]]; then
    pm_name="John"
    analyst_name="Mary"
    arch_name="Winston"
    ux_name="Sally"
    dev_name="Amelia"
    rev_name="Quinn"
  fi

  jq -cn \
    --arg repo "$abs_repo" \
    --arg fw "$fw" \
    --arg pm_name "$pm_name" --arg pm_skill "$pm_skill" \
    --arg an_name "$analyst_name" --arg an_skill "$analyst_skill" \
    --arg ar_name "$arch_name" --arg ar_skill "$arch_skill" \
    --arg ux_name "$ux_name" --arg ux_skill "$ux_skill" \
    --arg dv_name "$dev_name" --arg dv_skill "$dev_skill" \
    --arg rv_name "$rev_name" --arg rv_skill "$rev_skill" \
    --arg ap_name "$app_name" --arg ap_skill "$app_skill" \
    '{
      schema: "afk-project-roster/1",
      repo_path: $repo,
      framework: $fw,
      agents: [
        {
          role: "pm",
          persona_name: $pm_name,
          paperclip_role: "pm",
          title: (if $fw == "bmad" then "Product Manager (BMAD - " + $pm_name + ")" else "Factory Intake & Spec PM" end),
          icon: "target",
          skill_path: $pm_skill,
          stages: ["intake", "spec"],
          on_demand: false,
          capabilities: "Scopes incoming issues, writes bounded specs and acceptance criteria, asks at most one clarifying question when blocked."
        },
        {
          role: "analyst",
          persona_name: $an_name,
          paperclip_role: "researcher",
          title: (if $fw == "bmad" then "Business Analyst (BMAD - " + $an_name + ")" else "Domain & Requirements Analyst" end),
          icon: "search",
          skill_path: $an_skill,
          stages: ["research"],
          on_demand: true,
          capabilities: "Performs domain recon, competitive analysis, and requirements discovery when an issue flags research."
        },
        {
          role: "architect",
          persona_name: $ar_name,
          paperclip_role: "cto",
          title: (if $fw == "bmad" then "System Architect (BMAD - " + $ar_name + ")" else "Technical Architect" end),
          icon: "cpu",
          skill_path: $ar_skill,
          stages: ["spec", "review-arch"],
          on_demand: true,
          capabilities: "Designs technical architecture spines and reviews high-risk or cross-cutting architectural changes."
        },
        {
          role: "ux-designer",
          persona_name: $ux_name,
          paperclip_role: "designer",
          title: (if $fw == "bmad" then "UX Designer (BMAD - " + $ux_name + ")" else "UX & UI Specialist" end),
          icon: "sparkles",
          skill_path: $ux_skill,
          stages: ["ux", "review-ux"],
          on_demand: true,
          capabilities: "Produces UX/UI specifications and reviews frontend changes for usability and visual consistency."
        },
        {
          role: "dev",
          persona_name: $dv_name,
          paperclip_role: "engineer",
          title: (if $fw == "bmad" then "Senior Software Engineer (BMAD - " + $dv_name + ")" else "Factory Builder" end),
          icon: "code",
          skill_path: $dv_skill,
          stages: ["build"],
          on_demand: false,
          capabilities: "Implements scoped stories in isolated git worktrees, runs project check gates, and repairs review findings."
        },
        {
          role: "reviewer",
          persona_name: $rv_name,
          paperclip_role: "qa",
          title: (if $fw == "bmad" then "Independent Reviewer (BMAD - " + $rv_name + ")" else "Factory Multi-Lens Reviewer" end),
          icon: "shield",
          skill_path: $rv_skill,
          stages: ["review"],
          on_demand: false,
          capabilities: "Runs adversarial, edge-case, security, and verification-gap review lenses against the builder diff and acceptance criteria."
        },
        {
          role: "approver",
          persona_name: $ap_name,
          paperclip_role: "pm",
          title: "Situational Merge Approver",
          icon: "crown",
          skill_path: $ap_skill,
          stages: ["approve"],
          on_demand: false,
          capabilities: "Evaluates deterministic check gate evidence, reviewer verdicts, diff budget, and protected paths to auto-merge clean PRs or escalate to human."
        }
      ]
    }'
}

# afk_roster_roles_for_job <risk> <surfaces_csv>
# Determines which roles must be staffed for a job given its risk and surfaces.
# Core roles (pm, dev, reviewer, approver) are always included; specialist roles
# (analyst, architect, ux-designer) are hired dynamically when needed.
afk_roster_roles_for_job() {
  local risk="${1:-low}" surfaces=",${2:-code},"
  local -a roles=(pm dev reviewer approver)
  if [[ "$surfaces" == *",research,"* || "$surfaces" == *",discovery,"* ]]; then
    roles+=(analyst)
  fi
  if [[ "$risk" == "high" || "$surfaces" == *",architecture,"* || "$surfaces" == *",security,"* ]]; then
    roles+=(architect)
  fi
  if [[ "$surfaces" == *",ui,"* || "$surfaces" == *",ux,"* || "$surfaces" == *",frontend,"* ]]; then
    roles+=(ux-designer)
  fi
  local IFS=,
  printf '%s' "${roles[*]}"
}

# afk_roster_builtin_prompt <role>
# Built-in role instructions used when a repo has no local skill file for <role>,
# or appended as the factory stage contract alongside a BMAD persona.
afk_roster_builtin_prompt() {
  local role="$1"
  case "$role" in
    pm)
      cat <<'EOF'
You are the Project Intake & Specification PM managed by AFK.
Read the issue file (`issue.md`) and repository context.
- If a critical product decision is missing and cannot be derived from the repository, start your output with `VERDICT: NEEDS-INFO` followed by ONE concrete question for the human.
- If the request is invalid or harmful, start with `VERDICT: REJECT` and state why.
- Otherwise, start with `VERDICT: ACCEPT`, rate `RISK: low|medium|high`, list `SURFACES: code[,ui][,security][,architecture]`, and write a clear, bounded `spec.md` with explicit Acceptance Criteria and target files. Never implement the code yourself.
EOF
      ;;
    analyst)
      cat <<'EOF'
You are the Domain & Requirements Analyst managed by AFK.
Read `issue.md` and `spec.md`, investigate the domain constraints in the repository, and write `research.md` opening with a 3-5 bullet `## Summary` and concrete findings for the spec and builder.
EOF
      ;;
    architect)
      cat <<'EOF'
You are the System Architect managed by AFK.
Read `issue.md` and `spec.md`. Produce or refine the technical design in `architecture.md` (and during review, write `review-arch.md` starting with `VERDICT: PASS` or `VERDICT: CHANGES`). Keep changes minimal, modular, and aligned with repository invariants.
EOF
      ;;
    ux-designer)
      cat <<'EOF'
You are the UX & UI Designer managed by AFK.
Read `spec.md` and inspect the UI components. During design, write `ux-spec.md` with interaction states and visual constraints. During review, write `review-ux.md` starting with `VERDICT: PASS` or `VERDICT: CHANGES` followed by concrete usability or visual findings.
EOF
      ;;
    dev)
      cat <<'EOF'
You are the Senior Software Engineer (Builder) managed by AFK.
Work strictly inside the assigned git worktree on branch `factory/<job-id>`.
1. Read `spec.md` (and any prior round's `checks.md` or `review-*.md` findings, plus any `checkpoint.md` from a predecessor agent instance).
2. Implement the required changes, add/update unit and integration tests covering every acceptance criterion, and run the project checks.
3. Commit your changes on the branch and write `build.md` starting with a 3-5 bullet `## Summary`, the commit SHA, and how each acceptance criterion was verified.
EOF
      ;;
    reviewer)
      cat <<'EOF'
You are the Independent Reviewer managed by AFK.
Read `spec.md`, `build.md`, `checks.md`, and the git diff against the base branch. Do not trust claims in `build.md` without verifying them in the diff.
Check for: correctness, unverified acceptance criteria, weakened/skipped tests, edge cases, and security issues.
Start your review file (`review-code.md`) with `VERDICT: PASS` or `VERDICT: CHANGES`, followed by a `## Summary` and numbered actionable findings.
EOF
      ;;
    approver)
      cat <<'EOF'
You are the Situational Merge Approver managed by AFK.
Evaluate the deterministic gate output (`checks.md`), all reviewer files (`review-*.md`), the diff size, and touched paths.
- Output `DECISION: APPROVE` only when all deterministic checks pass, every reviewer verdict is `PASS`, no protected paths are modified, and the diff is within reviewable bounds.
- Otherwise output `DECISION: ESCALATE` with a concise summary and the exact reason human approval is required.
EOF
      ;;
  esac
}

# --- Context Window Monitoring & Automatic Agent Replacement -----------------

# afk_roster_context_eval <used_tokens> <window_tokens> [<compacted_bool>]
# Evaluates an agent's context pressure in integer PPM (parts per million).
# Prints JSON: {status: "OK"|"CHECKPOINT_DUE"|"REPLACE_AGENT", used_tokens, window_tokens, ratio_ppm, ratio_decimal}
afk_roster_context_eval() {
  local used="${1:-0}" window="${2:-$AFK_ROSTER_DEFAULT_WINDOW}" compacted="${3:-false}"
  [[ "$used" =~ ^[0-9]+$ ]] || used=0
  [[ "$window" =~ ^[0-9]+$ && "$window" -gt 0 ]] || window="$AFK_ROSTER_DEFAULT_WINDOW"
  local ppm=$(( (used * 1000000) / window ))
  local status="OK"
  if [[ "$compacted" == "true" ]] || (( ppm >= AFK_ROSTER_REPLACE_PPM )); then
    status="REPLACE_AGENT"
  elif (( ppm >= AFK_ROSTER_CHECKPOINT_PPM )); then
    status="CHECKPOINT_DUE"
  fi
  local whole=$(( ppm / 1000000 ))
  local frac
  frac="$(printf '%06d' $(( ppm % 1000000 )))"
  jq -cn \
    --arg st "$status" \
    --argjson u "$used" \
    --argjson w "$window" \
    --argjson p "$ppm" \
    --arg dec "${whole}.${frac}" \
    '{status: $st, used_tokens: $u, window_tokens: $w, ratio_ppm: $p, ratio_decimal: $dec}'
}

# afk_roster_record_and_check_context <job_dir> <role> <used_tokens> <window_tokens> [<compacted_bool>] [<worktree_dir>]
# Updates <job_dir>/context-ledger.json for <role>.
# When status is CHECKPOINT_DUE or REPLACE_AGENT, writes a checkpoint handoff
# file under <job_dir>/checkpoints/<role>-gen-<gen>.md.
# When status is REPLACE_AGENT, increments the agent's generation counter (up to
# AFK_ROSTER_MAX_REPLACEMENTS) so AFK spawns a fresh replacement agent instance
# seeded from the checkpoint instead of continuing the bloated session.
afk_roster_record_and_check_context() {
  local job_dir="$1" role="$2" used="${3:-0}" window="${4:-$AFK_ROSTER_DEFAULT_WINDOW}"
  local compacted="${5:-false}" wt="${6:-}"
  [[ -d "$job_dir" ]] || mkdir -p "$job_dir"
  local ledger_file="$job_dir/context-ledger.json"
  local ledger='{"schema":"afk-context-ledger/1","agents":{}}'
  if [[ -f "$ledger_file" ]]; then
    ledger="$(cat "$ledger_file" 2>/dev/null)" || ledger='{"schema":"afk-context-ledger/1","agents":{}}'
  fi
  local eval_json status ppm dec
  eval_json="$(afk_roster_context_eval "$used" "$window" "$compacted")"
  status="$(jq -r '.status' <<<"$eval_json")"
  ppm="$(jq -r '.ratio_ppm' <<<"$eval_json")"
  dec="$(jq -r '.ratio_decimal' <<<"$eval_json")"

  local gen replacements
  gen="$(jq -r --arg r "$role" '.agents[$r].generation // 1' <<<"$ledger" 2>/dev/null)"
  replacements="$(jq -r --arg r "$role" '.agents[$r].replacements // 0' <<<"$ledger" 2>/dev/null)"
  [[ "$gen" =~ ^[0-9]+$ ]] || gen=1
  [[ "$replacements" =~ ^[0-9]+$ ]] || replacements=0

  local cp_file="" new_gen="$gen" action="continue"
  if [[ "$status" == "CHECKPOINT_DUE" || "$status" == "REPLACE_AGENT" ]]; then
    mkdir -p "$job_dir/checkpoints"
    cp_file="$job_dir/checkpoints/${role}-gen-${gen}.md"
    local git_stat="no worktree"
    if [[ -n "$wt" && -d "$wt" ]] && git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git_stat="$(git -C "$wt" status --short 2>/dev/null | head -n 30)"
    fi
    cat > "$cp_file" <<EOF
# AFK Agent Context Handoff Checkpoint
- Role: $role
- Generation: $gen
- Context Usage: $used / $window tokens ($dec)
- Trigger: $status

## Worktree State
\`\`\`
${git_stat:-clean}
\`\`\`

## Instructions for Replacement Agent (Generation $((gen + 1)))
Continue the stage from the current files in the job directory (\`spec.md\`, \`build.md\`, \`checks.md\`, \`review-*.md\`) and the existing commits/changes in the worktree. Do not repeat completed work.
EOF
    action="checkpointed"
  fi

  if [[ "$status" == "REPLACE_AGENT" ]]; then
    if (( replacements >= AFK_ROSTER_MAX_REPLACEMENTS )); then
      action="replacement_cap_reached"
    else
      new_gen=$((gen + 1))
      replacements=$((replacements + 1))
      action="replaced"
    fi
  fi

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ledger="$(jq -c \
    --arg r "$role" \
    --arg st "$status" \
    --arg act "$action" \
    --arg cp "$cp_file" \
    --arg dec "$dec" \
    --arg now "$now" \
    --argjson u "$used" \
    --argjson w "$window" \
    --argjson p "$ppm" \
    --argjson g "$new_gen" \
    --argjson rep "$replacements" \
    '.agents[$r] = {
      role: $r,
      generation: $g,
      replacements: $rep,
      last_status: $st,
      last_action: $act,
      used_tokens: $u,
      window_tokens: $w,
      ratio_ppm: $p,
      ratio_decimal: $dec,
      checkpoint_file: (if $cp == "" then null else $cp end),
      updated_at: $now
    }' <<<"$ledger")"

  printf '%s\n' "$ledger" > "$ledger_file.tmp.$$" && mv "$ledger_file.tmp.$$" "$ledger_file"
  jq -cn \
    --arg r "$role" \
    --arg st "$status" \
    --arg act "$action" \
    --arg cp "$cp_file" \
    --arg dec "$dec" \
    --argjson old_gen "$gen" \
    --argjson new_gen "$new_gen" \
    --argjson rep "$replacements" \
    --argjson u "$used" \
    --argjson w "$window" \
    --argjson p "$ppm" \
    '{
      role: $r,
      status: $st,
      action: $act,
      previous_generation: $old_gen,
      active_generation: $new_gen,
      replacements: $rep,
      used_tokens: $u,
      window_tokens: $w,
      ratio_ppm: $p,
      ratio_decimal: $dec,
      checkpoint_file: (if $cp == "" then null else $cp end)
    }'
}
