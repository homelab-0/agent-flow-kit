#!/usr/bin/env bash
# factory-tests.sh — Hermetic test gate for the AFK Software Factory:
#   1. Per-project roster discovery (BMAD vs Factory Default)
#   2. Dynamic Paperclip hiring, stage assignment, and retirement
#   3. Agent context-window monitoring & automatic replacement handoff
#   4. Deterministic check gate & Situational Merge Approver (Approve vs Escalate)
#   5. Attention-minimal human-in-the-loop status reporting

set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AFK="$KIT_ROOT/bin/agent-flow-kit"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0 FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s (%s)\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
head1(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

assert_eq() {
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi
}
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing '$3' in '$2'"; fi
}

export HOME="$TMPROOT/home"
export AFK_STATE_DIR="$HOME/.local/state/agent-flow-kit"
export AFK_PAPERCLIP_CONFIG="$HOME/.config/agent-flow-kit/paperclip.json"
mkdir -p "$HOME/.config/agent-flow-kit" "$AFK_STATE_DIR"

# ============================================================================
head1 "1. Per-project agent roster discovery (BMAD vs Factory Default)"
# ============================================================================

BMAD_REPO="$TMPROOT/spektacle"
PLAIN_REPO="$TMPROOT/prox-ops"
mkdir -p "$BMAD_REPO/.agents/skills/bmad-agent-pm" \
         "$BMAD_REPO/.agents/skills/bmad-agent-analyst" \
         "$BMAD_REPO/.agents/skills/bmad-agent-architect" \
         "$BMAD_REPO/.agents/skills/bmad-agent-ux-designer" \
         "$BMAD_REPO/.agents/skills/bmad-agent-dev" \
         "$BMAD_REPO/.agents/skills/bmad-review" \
         "$PLAIN_REPO"

for s in bmad-agent-pm bmad-agent-analyst bmad-agent-architect bmad-agent-ux-designer bmad-agent-dev bmad-review; do
  printf '# %s skill\n' "$s" > "$BMAD_REPO/.agents/skills/$s/SKILL.md"
done

for r in "$BMAD_REPO" "$PLAIN_REPO"; do
  git init -q "$r"
  git -C "$r" config user.name "Test"
  git -C "$r" config user.email "test@example.invalid"
  printf 'hello\n' > "$r/README.md"
  git -C "$r" add README.md
  git -C "$r" commit -q -m "init"
done

BMAD_ROSTER="$(bash "$AFK" factory roster --repo "$BMAD_REPO" --json)"
PLAIN_ROSTER="$(bash "$AFK" factory roster --repo "$PLAIN_REPO" --json)"

assert_eq "BMAD repo detected as framework=bmad" \
  "$(jq -r '.framework' <<<"$BMAD_ROSTER")" "bmad"
assert_eq "BMAD roster maps pm->John, architect->Winston, ux-designer->Sally, dev->Amelia, reviewer->Quinn" \
  "$(jq -r '[.agents[] | "\(.role):\(.persona_name)"] | join(",")' <<<"$BMAD_ROSTER")" \
  "pm:John,analyst:Mary,architect:Winston,ux-designer:Sally,dev:Amelia,reviewer:Quinn,approver:Approver"
assert_contains "BMAD dev resolves project-local SKILL.md" \
  "$(jq -r '.agents[] | select(.role=="dev") | .skill_path' <<<"$BMAD_ROSTER")" \
  ".agents/skills/bmad-agent-dev/SKILL.md"

assert_eq "Non-BMAD repo detected as framework=factory-default" \
  "$(jq -r '.framework' <<<"$PLAIN_ROSTER")" "factory-default"
assert_eq "Non-BMAD repo uses builtin skills" \
  "$(jq -r '.agents[] | select(.role=="dev") | .skill_path' <<<"$PLAIN_ROSTER")" "builtin"

# ============================================================================
head1 "2. Context-window monitoring & automatic agent replacement"
# ============================================================================

bash "$AFK" factory init --repo "$BMAD_REPO" --json >/dev/null
CTX_OK="$(bash "$AFK" factory context-check --repo "$BMAD_REPO" --job job-ctx --role dev --used-tokens 100000 --window 200000 --json)"
assert_eq "50% context usage -> status OK, action continue, gen 1" \
  "$(jq -r '"\(.status):\(.action):\(.active_generation)"' <<<"$CTX_OK")" "OK:continue:1"

CTX_CP="$(bash "$AFK" factory context-check --repo "$BMAD_REPO" --job job-ctx --role dev --used-tokens 145000 --window 200000 --json)"
assert_eq "72.5% context usage -> status CHECKPOINT_DUE, action checkpointed, gen 1" \
  "$(jq -r '"\(.status):\(.action):\(.active_generation)"' <<<"$CTX_CP")" "CHECKPOINT_DUE:checkpointed:1"
assert_eq "Checkpoint file written on disk" \
  "$([[ -f "$(jq -r '.checkpoint_file' <<<"$CTX_CP")" ]] && echo yes || echo no)" "yes"

CTX_REP="$(bash "$AFK" factory context-check --repo "$BMAD_REPO" --job job-ctx --role dev --used-tokens 165000 --window 200000 --json)"
assert_eq "82.5% context usage -> status REPLACE_AGENT, action replaced, gen 1->2" \
  "$(jq -r '"\(.status):\(.action):\(.previous_generation)->\(.active_generation)"' <<<"$CTX_REP")" "REPLACE_AGENT:replaced:1->2"

# Exhaust remaining replacements (max 3)
bash "$AFK" factory context-check --repo "$BMAD_REPO" --job job-ctx --role dev --used-tokens 170000 --window 200000 --json >/dev/null
bash "$AFK" factory context-check --repo "$BMAD_REPO" --job job-ctx --role dev --used-tokens 170000 --window 200000 --json >/dev/null
CTX_CAP="$(bash "$AFK" factory context-check --repo "$BMAD_REPO" --job job-ctx --role dev --used-tokens 170000 --window 200000 --json)"
assert_eq "Exceeding max replacements (3) -> replacement_cap_reached" \
  "$(jq -r '.action' <<<"$CTX_CAP")" "replacement_cap_reached"

# ============================================================================
head1 "3. Dynamic Paperclip hiring, replacement reset & situational auto-merge"
# ============================================================================

STUB_BIN="$TMPROOT/bin"
CURL_LOG="$TMPROOT/curl.log"
mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/op" <<'OP'
#!/usr/bin/env bash
printf 'pc-secret-key-do-not-log\n'
OP
chmod +x "$STUB_BIN/op"

cat > "$STUB_BIN/curl" <<'CURL'
#!/usr/bin/env bash
method="GET" url=""
while (($#)); do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    http*://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s %s\n' "$method" "$url" >> "$CURL_LOG"
case "$method $url" in
  *"POST "*"/api/companies/"*"/agent-hires")
    printf '{"agent":{"id":"a1111111-2222-4333-8444-555555555555","status":"active"}}201' ;;
  *"POST "*"/api/agents/"*"/terminate")
    printf '{"ok":true}200' ;;
  *"POST "*"/api/agents/"*"/runtime-state/reset-session")
    printf '{"ok":true}200' ;;
  *)
    printf '{"ok":true}200' ;;
esac
CURL
chmod +x "$STUB_BIN/curl"

cat > "$AFK_PAPERCLIP_CONFIG" <<JSON
{
  "schema": "afk-paperclip-config/2",
  "api_url": "https://paperclip.example",
  "company_id": "4ffcc005-8076-4062-b72e-e4f2d899ecb0",
  "board_user_id": "emXp8Svi8ncWyL1EORTkRNQYjFjCdQon",
  "host": {
    "label": "ubuntu-devbox",
    "agent_id": "479f0f09-ee4a-4b31-902b-b662d906f41b",
    "key_ref": "op://develop/paperclip/KEY"
  },
  "projects": [
    {
      "paperclip_project_id": "7254d23d-3987-406d-a04f-9acf3854d6c1",
      "slug": "spektacle",
      "repo_path": "$BMAD_REPO",
      "harness": "claude",
      "max_active_issues": 1,
      "merge": "pm"
    }
  ]
}
JSON
chmod 600 "$AFK_PAPERCLIP_CONFIG"

# Run a clean low-risk job with simulated 85% token pressure on the first builder turn
# to prove both Paperclip hiring, automatic builder replacement, and situational auto-merge.
ISSUE1="11111111-2222-4333-8444-666666666666"
RUN1="$(OP_SERVICE_ACCOUNT_TOKEN=stub \
        AFK_OP_BIN="$STUB_BIN/op" \
        AFK_CURL_BIN="$STUB_BIN/curl" \
        CURL_LOG="$CURL_LOG" \
        AFK_STAGE_USED_TOKENS=170000 \
        AFK_STAGE_WINDOW_TOKENS=200000 \
        bash "$AFK" factory run --slug spektacle --job job-clean --issue "$ISSUE1" --title "Add helper widget" --json)"

assert_eq "Clean job with passing gate & reviews auto-merges (stage=merged, decision=APPROVE)" \
  "$(jq -r '"\(.stage):\(.decision)"' <<<"$RUN1")" "merged:APPROVE"
assert_contains "Paperclip agent-hires endpoint was called to hire project agents" \
  "$(cat "$CURL_LOG")" "POST https://paperclip.example/api/companies/4ffcc005-8076-4062-b72e-e4f2d899ecb0/agent-hires"
assert_contains "Paperclip reset-session endpoint was called when builder crossed 80% context" \
  "$(cat "$CURL_LOG")" "/runtime-state/reset-session"
assert_contains "Paperclip terminate endpoint was called to retire agents on completion" \
  "$(cat "$CURL_LOG")" "/terminate"
assert_contains "Compiled build prompt includes discovered BMAD Amelia persona and replacement handoff checkpoint" \
  "$(cat "$BMAD_REPO/.afk/jobs/job-clean/.prompt-build-dev.md")" "Context Replacement Handoff Checkpoint (dev-gen-1.md)"
assert_contains "Compiled build prompt injects discovered project-local Amelia SKILL.md" \
  "$(cat "$BMAD_REPO/.afk/jobs/job-clean/.prompt-build-dev.md")" "# bmad-agent-dev skill"

# ============================================================================
head1 "4. Situational Merge Approver escalates protected paths & oversized diffs"
# ============================================================================

# Create a job that touches a protected path (.github/workflows/ci.yml)
PROT_JOB_DIR="$BMAD_REPO/.afk/jobs/job-protected"
mkdir -p "$PROT_JOB_DIR/round-1"
cat > "$PROT_JOB_DIR/job.json" <<JSON
{
  "schema": "afk-factory-job/1",
  "id": "job-protected",
  "slug": "spektacle",
  "issue_id": "22222222-2222-4333-8444-666666666666",
  "title": "Update CI workflow",
  "repo_path": "$BMAD_REPO",
  "worktree_path": "$BMAD_REPO",
  "branch": "factory/job-protected",
  "stage": "approve",
  "round": 1,
  "risk": "medium",
  "surfaces": ["code"],
  "diff_stats": {
    "lines": 40,
    "files": 1,
    "changed_paths": [".github/workflows/ci.yml"]
  }
}
JSON
printf 'VERDICT: PASS\n' > "$PROT_JOB_DIR/round-1/checks.md"
printf 'VERDICT: PASS\n' > "$PROT_JOB_DIR/round-1/review-code.md"

EVAL_PROT="$(bash "$AFK" factory evaluate-merge --repo "$BMAD_REPO" --job job-protected --json)"
assert_eq "Protected path (.github/workflows/ci.yml) triggers DECISION: ESCALATE" \
  "$(jq -r '.decision' <<<"$EVAL_PROT")" "ESCALATE"
assert_contains "Escalation reason names the protected path" \
  "$(jq -r '.reasons | join("; ")' <<<"$EVAL_PROT")" "Protected path touched: .github/workflows/ci.yml"

# Mark job-protected as needs-human and verify `factory status` surfaces it in attention_required
jq -c '.stage = "needs-human" | .decision = "ESCALATE"' "$PROT_JOB_DIR/job.json" > "$PROT_JOB_DIR/job.json.tmp" && mv "$PROT_JOB_DIR/job.json.tmp" "$PROT_JOB_DIR/job.json"

STATUS_JSON="$(bash "$AFK" factory status --slug spektacle --json)"
assert_eq "factory status reports exactly 1 item needing human attention (job-protected, not job-clean)" \
  "$(jq -r '"\(.attention_required_count):\(.attention_required[0].id)"' <<<"$STATUS_JSON")" "1:job-protected"

# ─── Test 7: Smart Multi-Harness + Pool Headroom + Benchmark + LiteLLM Router ───
export AFK_ROUTER_HARNESS_LIST="claude,codex,agy,opencode"
export AFK_ROUTER_SIGNALS_FILE="$TMP/pool-signals.json"
cat > "$AFK_ROUTER_SIGNALS_FILE" <<'JSON'
{
  "pools": {
    "anthropic-max": { "used_pct": 20 },
    "openai-plus": { "used_pct": 15 },
    "antigravity-pool": { "used_pct": 10 },
    "xai-grok": { "used_pct": 10 }
  }
}
JSON

ROUTE_SPEC="$(bash "$AFK" factory route-preview --repo "$BMAD_REPO" --stage spec --risk high --json)"
assert_eq "Smart router picks claude/opus for high-risk architecture spec" \
  "$(jq -r '"\(.harness)/\(.model):\(.memory_mode)"' <<<"$ROUTE_SPEC")" "claude/opus:advisory"

ROUTE_REV="$(bash "$AFK" factory route-preview --repo "$BMAD_REPO" --stage review-code --risk medium --builder-family anthropic --json)"
assert_eq "Smart router enforces cross-family blind review (codex reviews anthropic build with blind memory)" \
  "$(jq -r '"\(.harness):\(.cross_family_review):\(.memory_mode)"' <<<"$ROUTE_REV")" "codex:true:blind"

# Simulate anthropic-max subscription pool exhausted (95% used) -> should fail over automatically to codex
cat > "$AFK_ROUTER_SIGNALS_FILE" <<'JSON'
{
  "pools": {
    "anthropic-max": { "used_pct": 95 },
    "openai-plus": { "used_pct": 15 },
    "antigravity-pool": { "used_pct": 10 },
    "xai-grok": { "used_pct": 10 }
  }
}
JSON
ROUTE_FAILOVER="$(bash "$AFK" factory route-preview --repo "$BMAD_REPO" --stage spec --risk high --json)"
assert_eq "When anthropic-max pool is exhausted (95%), smart router fails over to codex/gpt-5.6-sol" \
  "$(jq -r '"\(.harness)/\(.model):\(.entitlement_pool)"' <<<"$ROUTE_FAILOVER")" "codex/gpt-5.6-sol:openai-plus"

# Simulate all cloud pools in warning (82% used) + LiteLLM Local AI cluster online -> low-risk build routes to LiteLLM local cluster
cat > "$AFK_ROUTER_SIGNALS_FILE" <<'JSON'
{
  "pools": {
    "anthropic-max": { "used_pct": 82 },
    "openai-plus": { "used_pct": 82 },
    "antigravity-pool": { "used_pct": 82 },
    "xai-grok": { "used_pct": 82 }
  }
}
JSON
ROUTE_LOCAL="$(AFK_LITELLM_BASE_URL="http://litellm.homelab0.org:4000" AFK_ROUTER_LITELLM_ASSUME_ONLINE=1 bash "$AFK" factory route-preview --repo "$BMAD_REPO" --stage build --risk low --json)"
assert_eq "When subscription pools are in warning (82%) and LiteLLM is online, low-risk build shifts to litellm-local (claude-gateway)" \
  "$(jq -r '"\(.launch_class):\(.entitlement_pool):\(.router_source)"' <<<"$ROUTE_LOCAL")" "claude-gateway:litellm-local:smart-router+litellm"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
