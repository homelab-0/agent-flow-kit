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
export AFK_ROUTER_BENCHMARKS_FILE="$KIT_ROOT/files/model-router/benchmarks.json"
export AFK_ROUTER_SIGNALS_FILE="$TMPROOT/pool-signals.json"
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

# Simulate anthropic-max subscription pool exhausted (95% used) -> should fail over automatically to #2 LMArena Agent (agy/gemini-4-carbon)
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
assert_eq "When anthropic-max pool is exhausted (95%), smart router fails over to #2 benchmarked agy/gemini-4-carbon" \
  "$(jq -r '"\(.harness)/\(.model):\(.entitlement_pool)"' <<<"$ROUTE_FAILOVER")" "agy/gemini-4-carbon:antigravity-pool"

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
  "$(jq -r '"\(.launch_class):\(.entitlement_pool):\(.router_source)"' <<<"$ROUTE_LOCAL")" "claude-gateway:litellm-local:afk-benchmarks+litellm"

# ----------------------------------------------------------------------------
# 5. Universal Cross-Platform Harness Install Detection & Update Engine (Linux + macOS)
# ----------------------------------------------------------------------------
printf '\n5. Universal cross-platform harness install-origin & update engine (Linux + macOS)\n'

# Source library directly to test pure cross-platform origin classification across macOS Homebrew, Linux npm --prefix, Bun, and self-managed
# shellcheck disable=SC1091
. "$KIT_ROOT/lib/afk-harnesses.sh"

BREW_ORIGIN="$(afk_harness_classify_origin "codex" "/opt/homebrew/bin/codex" "/opt/homebrew/Cellar/codex/0.167.1/bin/codex")"
assert_eq "macOS Homebrew path resolves to brew upgrade codex" \
  "$(jq -r '"\(.install_method):\(.update_command)"' <<<"$BREW_ORIGIN")" "homebrew:brew upgrade codex"

NPM_ORIGIN="$(afk_harness_classify_origin "codex" "/home/user/.local/bin/codex" "/home/user/.local/lib/node_modules/@openai/codex/bin/codex.js")"
assert_eq "Custom npm prefix resolves to npm install -g --prefix ... @openai/codex@latest" \
  "$(jq -r '"\(.install_method):\(.package_name):\(.install_prefix)"' <<<"$NPM_ORIGIN")" "npm:@openai/codex:/home/user/.local"

BUN_ORIGIN="$(afk_harness_classify_origin "pi" "/Users/dev/.bun/bin/pi" "/Users/dev/.bun/install/global/node_modules/@mariozechner/pi-coding-agent/dist/cli.js")"
assert_eq "Bun global path resolves to bun add -g @mariozechner/pi-coding-agent@latest" \
  "$(jq -r '"\(.install_method):\(.update_command)"' <<<"$BUN_ORIGIN")" "bun:bun add -g @mariozechner/pi-coding-agent@latest"

SELF_ORIGIN="$(afk_harness_classify_origin "opencode" "/Users/dev/.opencode/bin/opencode" "/Users/dev/.opencode/bin/opencode")"
assert_eq "Self-managed OpenCode binary resolves to opencode upgrade" \
  "$(jq -r '"\(.install_method):\(.update_command)"' <<<"$SELF_ORIGIN")" 'self-managed:"/Users/dev/.opencode/bin/opencode" upgrade'

# ----------------------------------------------------------------------------
# 6. Shared Subscription Pool Attribution (Codex + OpenCode + Pi) & Free vs Metered Models
# ----------------------------------------------------------------------------
printf '\n6. Shared subscription pool attribution & OpenCode free vs metered-API models\n'

MOCK_AUTH_DIR="$TMPROOT/mock-auth"
mkdir -p "$MOCK_AUTH_DIR"
cat > "$MOCK_AUTH_DIR/codex-auth.json" <<'JSON'
{"auth_mode": "oauth", "tokens": {"account_id": "acct_shared_12345"}}
JSON
cat > "$MOCK_AUTH_DIR/opencode-auth.json" <<'JSON'
{
  "openai": {"type": "oauth", "accountId": "acct_shared_12345"},
  "anthropic": {"type": "api", "key": "sk-ant-redacted"}
}
JSON
cat > "$MOCK_AUTH_DIR/pi-auth.json" <<'JSON'
{
  "openai-codex": {"type": "oauth", "accountId": "acct_shared_12345"}
}
JSON
cat > "$MOCK_AUTH_DIR/opencode-models.txt" <<'TXT'
opencode/deepseek-v4.1-flash-free
{"id":"deepseek-v4.1-flash-free","providerID":"opencode","name":"DeepSeek V4.1 Flash Free","status":"active","cost":{"input":0,"output":0},"limit":{"context":262144,"output":65536},"capabilities":{"reasoning":true,"toolcall":true,"input":{"image":false}}}
openai/gpt-6.1-sol
{"id":"gpt-6.1-sol","providerID":"openai","name":"GPT-6.1 Sol","status":"active","cost":{"input":2.5,"output":10},"limit":{"context":400000,"output":128000},"capabilities":{"reasoning":true,"toolcall":true,"input":{"image":true}}}
anthropic/claude-opus-5-5
{"id":"claude-opus-5-5","providerID":"anthropic","name":"Claude Opus 5.5 (Metered API)","status":"active","cost":{"input":15,"output":75},"limit":{"context":1000000,"output":128000},"capabilities":{"reasoning":true,"toolcall":true,"input":{"image":true}}}
TXT
cat > "$MOCK_AUTH_DIR/agy-models.txt" <<'TXT'
gemini-4-carbon-high	Gemini 4 Carbon (High)
TXT

DISC_FILE="$TMPROOT/discovered-models.json"
MODELS_OUT="$(
  AFK_CODEX_AUTH_FILE="$MOCK_AUTH_DIR/codex-auth.json" \
  AFK_OPENCODE_AUTH_FILE="$MOCK_AUTH_DIR/opencode-auth.json" \
  AFK_PI_AUTH_FILE="$MOCK_AUTH_DIR/pi-auth.json" \
  AFK_OPENCODE_MODELS_FIXTURE="$MOCK_AUTH_DIR/opencode-models.txt" \
  AFK_AGY_MODELS_FIXTURE="$MOCK_AUTH_DIR/agy-models.txt" \
  AFK_DISCOVERED_MODELS_FILE="$DISC_FILE" \
  bash "$AFK" factory models --sync --json
)"

assert_eq "Codex, OpenCode (OpenAI OAuth), and Pi share the exact same openai-plus pool & account fingerprint" \
  "$(jq -r '.shared_pool_topology[] | select(.entitlement_pool == "openai-plus") | "\(.shared_across_harnesses):\(.harnesses_feeding_pool | join("+")):\(.account_fingerprints | length)"' <<<"$MODELS_OUT")" \
  "true:codex+opencode+pi:1"

assert_eq "OpenCode \$0 model is classified free (opencode-free), OpenAI OAuth is subscription (openai-plus), Anthropic API key is api-metered" \
  "$(jq -r '[.models[] | select(.harness == "opencode") | "\(.model)=\(.cost_class)/\(.entitlement_pool)"] | sort | join(",")' <<<"$MODELS_OUT")" \
  "anthropic/claude-opus-5-5=api-metered/api-metered,openai/gpt-6.1-sol=subscription/openai-plus,opencode/deepseek-v4.1-flash-free=free/opencode-free"

# When subscription pools are under pressure (warning 82%) and LiteLLM is offline, free OpenCode model wins low-risk intake/build while metered API stays blocked!
ROUTE_FREE="$(
  AFK_ROUTER_HARNESS_LIST="claude,agy,opencode" \
  AFK_DISCOVERED_MODELS_FILE="$DISC_FILE" \
  bash "$AFK" factory route-preview --repo "$BMAD_REPO" --stage intake --risk low --json
)"
assert_eq "When subscription pools are in warning and LiteLLM is offline, router shifts low-risk intake to \$0 opencode/deepseek-v4.1-flash-free (blocking metered API)" \
  "$(jq -r '"\(.harness)/\(.model):\(.cost_class):\(.is_free)"' <<<"$ROUTE_FREE")" \
  "opencode/opencode/deepseek-v4.1-flash-free:free:true"

# ----------------------------------------------------------------------------
# 7. Centralized & Per-Project Skills + MCP Management (LiteLLM Gateway vs Standalone)
# ----------------------------------------------------------------------------
printf '\n7. Centralized & per-project Skills and MCP management (litellm vs standalone)\n'

export AFK_TOOLING_REGISTRY_FILE="$TMPROOT/tooling-registry.json"
CENTRAL_SKILL_SRC="$TMPROOT/central-skills/k8s-ops"
mkdir -p "$CENTRAL_SKILL_SRC"
cat > "$CENTRAL_SKILL_SRC/SKILL.md" <<'MD'
---
name: k8s-ops
description: Kubernetes cluster operations helper
---
# K8s Ops Skill
MD

bash "$AFK" factory tooling-register-mcp --name postgres-ro --transport stdio --target npx --args "-y,@modelcontextprotocol/server-postgres" --description "Read-only Postgres MCP" >/dev/null
bash "$AFK" factory tooling-register-skill --name k8s-ops --path "$CENTRAL_SKILL_SRC" >/dev/null

# Mode A: Standalone per-project provisioning (for users without LiteLLM)
STANDALONE_REPO="$TMPROOT/repo-standalone-mcp"
mkdir -p "$STANDALONE_REPO"
bash "$AFK" factory tooling-sync --repo "$STANDALONE_REPO" --mcp-mode standalone --enable-mcp postgres-ro --enable-skills k8s-ops --json >/dev/null
assert_eq "Standalone tooling-sync writes native stdio command to project .mcp.json and installs central skill" \
  "$(jq -r '.mcpServers["postgres-ro"].command' "$STANDALONE_REPO/.mcp.json"):$(test -f "$STANDALONE_REPO/.agents/skills/k8s-ops/SKILL.md" && echo ok)" \
  "npx:ok"

# Mode B: Centralized LiteLLM MCP Gateway provisioning
LITELLM_REPO="$TMPROOT/repo-litellm-mcp"
mkdir -p "$LITELLM_REPO"
bash "$AFK" factory tooling-sync --repo "$LITELLM_REPO" --mcp-mode litellm --litellm-url "http://litellm.homelab0.org:4000" --enable-mcp postgres-ro,github --json >/dev/null
assert_eq "LiteLLM tooling-sync routes project .mcp.json servers through LiteLLM /mcp/<server> gateway" \
  "$(jq -r '"\(.mcpServers["postgres-ro"].url)|\(.mcpServers["github"].headers["x-litellm-mcp"])"' "$LITELLM_REPO/.mcp.json")" \
  "http://litellm.homelab0.org:4000/mcp/postgres-ro|true"

# ----------------------------------------------------------------------------
# 8. Live-Harness Runtime Failover, Multi-Round Review Loop & Non-BMAD E2E
# ----------------------------------------------------------------------------
printf '\n8. Live-harness runtime pool failover, multi-round review fix loop & non-BMAD E2E\n'

MOCK_CLI_BIN="$TMPROOT/mock-cli-bin"
mkdir -p "$MOCK_CLI_BIN"

cat > "$MOCK_CLI_BIN/codex" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "codex-cli 0.167.1"; exit 0; fi
printf '{"type":"turn.failed","error":{"message":"token_revoked 401"}}\n'
exit 1
SH
cat > "$MOCK_CLI_BIN/opencode" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "1.19.5"; exit 0; fi
if [[ "$*" == *"openai/"* ]]; then
  # OpenCode exits 0 even on JSON auth errors — verify AFK catches this!
  printf '%s\n' '{"type":"error","error":{"data":{"message":"Token refresh failed: 401"}}}'
  exit 0
fi
printf '%s\n' '{"type":"text","part":{"type":"text","text":"VERDICT: ACCEPT\nRISK: low\nSURFACES: code\n## Summary\n- Handled by free OpenCode model."}}'
printf '%s\n' '{"type":"step_finish","part":{"tokens":{"total":14200}}}'
exit 0
SH
cat > "$MOCK_CLI_BIN/agy" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "agy version 1.5.5"; exit 0; fi
printf '%s\n' '{"response":"VERDICT: PASS\n## Summary\n- Blind cross-family review passed after automatic openai-plus failover.","usage":{"total_tokens":18500}}'
exit 0
SH
cat > "$MOCK_CLI_BIN/claude" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "2.1.322 (Claude Code)"; exit 0; fi
PROMPT_TEXT="$*"
if [[ "$PROMPT_TEXT" == *"review-code.md"* ]]; then
  printf '%s\n' '{"result":"VERDICT: PASS\n## Summary\n- Review passed.","usage":{"input_tokens":7000,"output_tokens":250}}'
  exit 0
fi
if [[ "$PROMPT_TEXT" == *"Target output path:"*"/spec.md"* ]]; then
  printf '%s\n' '{"result":"# Spec\n- Add widget helper.","usage":{"input_tokens":5000,"output_tokens":300}}'
  exit 0
fi
if [[ "$PROMPT_TEXT" == *"Prior Round 1 Reviewer Feedback"* ]]; then
  printf '%s\n' '{"result":"## Summary\n- Fixed Round 1 reviewer finding cleanly.","usage":{"input_tokens":8000,"output_tokens":400}}'
  exit 0
fi
printf '%s\n' '{"result":"## Summary\n- Initial Round 1 implementation.","usage":{"input_tokens":6000,"output_tokens":350}}'
exit 0
SH
chmod +x "$MOCK_CLI_BIN/codex" "$MOCK_CLI_BIN/opencode" "$MOCK_CLI_BIN/agy" "$MOCK_CLI_BIN/claude"

# Reset pool signals & harness list so router probes MOCK_CLI_BIN and starts fresh (`available`)
rm -f "$AFK_ROUTER_SIGNALS_FILE" "$AFK_STATE_DIR/router/pool-signals.json"
unset AFK_ROUTER_HARNESS_LIST
unset AFK_FACTORY_AGENT_RUNNER

FAILOVER_REPO="$TMPROOT/repo-non-bmad-e2e"
mkdir -p "$FAILOVER_REPO"
git -C "$FAILOVER_REPO" init -b main >/dev/null 2>&1
git -C "$FAILOVER_REPO" config user.email "test@example.com"
git -C "$FAILOVER_REPO" config user.name "AFK Test"
echo "hello" > "$FAILOVER_REPO/README.md"
git -C "$FAILOVER_REPO" add README.md
git -C "$FAILOVER_REPO" commit -m "init" >/dev/null 2>&1
bash "$AFK" factory init --repo "$FAILOVER_REPO" >/dev/null

# 8a: Low-risk job with AFK_ROUTER_PREFER_FREE=1 on non-BMAD repo -> free OpenCode model + auto-merge
NON_BMAD_FREE_OUT="$(
  PATH="$MOCK_CLI_BIN:$PATH" \
  AFK_CODEX_AUTH_FILE="$MOCK_AUTH_DIR/codex-auth.json" \
  AFK_OPENCODE_AUTH_FILE="$MOCK_AUTH_DIR/opencode-auth.json" \
  AFK_PI_AUTH_FILE="$MOCK_AUTH_DIR/pi-auth.json" \
  AFK_FACTORY_LIVE_HARNESS=1 \
  AFK_ROUTER_PREFER_FREE=1 \
  AFK_DISCOVERED_MODELS_FILE="$DISC_FILE" \
  OP_SERVICE_ACCOUNT_TOKEN=stub \
  AFK_OP_BIN="$STUB_BIN/op" \
  AFK_CURL_BIN="$STUB_BIN/curl" \
  bash "$AFK" factory run --repo "$FAILOVER_REPO" --slug nonbmad --job job-nonbmad-free --title "Add widget helper" --json
)"

assert_eq "Non-BMAD repo runs full live-harness pipeline end-to-end and auto-merges" \
  "$(jq -r '"\(.stage):\(.decision)"' <<<"$NON_BMAD_FREE_OUT")" \
  "merged:APPROVE"

assert_eq "Low-risk intake used \$0 free OpenCode model under AFK_ROUTER_PREFER_FREE=1" \
  "$(jq -sr '[.[] | select(.stage == "intake" and .status == "ok") | "\(.harness):\(.cost_class)"] | first' "$FAILOVER_REPO/.afk/jobs/job-nonbmad-free/route-history.jsonl")" \
  "opencode:free"

# 8b: Default subscription routing: claude builds -> codex picked for cross-family review -> hits 401 -> marks shared openai-plus degraded -> fails over in-flight to agy!
rm -f "$AFK_ROUTER_SIGNALS_FILE" "$AFK_STATE_DIR/router/pool-signals.json"
NON_BMAD_FAILOVER_OUT="$(
  PATH="$MOCK_CLI_BIN:$PATH" \
  AFK_CODEX_AUTH_FILE="$MOCK_AUTH_DIR/codex-auth.json" \
  AFK_OPENCODE_AUTH_FILE="$MOCK_AUTH_DIR/opencode-auth.json" \
  AFK_PI_AUTH_FILE="$MOCK_AUTH_DIR/pi-auth.json" \
  AFK_FACTORY_LIVE_HARNESS=1 \
  AFK_DISCOVERED_MODELS_FILE="$DISC_FILE" \
  OP_SERVICE_ACCOUNT_TOKEN=stub \
  AFK_OP_BIN="$STUB_BIN/op" \
  AFK_CURL_BIN="$STUB_BIN/curl" \
  bash "$AFK" factory run --repo "$FAILOVER_REPO" --slug nonbmad --job job-nonbmad-failover --title "Add second helper" --json
)"

assert_eq "review-code caught codex 401, marked shared openai-plus degraded, skipped opencode/openai, and failed over in-flight to agy" \
  "$(jq -sr '[.[] | select(.stage == "review-code") | "\(.status):\(.harness):\(.attempt)"] | join("->")' "$FAILOVER_REPO/.afk/jobs/job-nonbmad-failover/route-history.jsonl"):$(jq -r '.decision' <<<"$NON_BMAD_FAILOVER_OUT")" \
  "failed_attempt:codex:1->ok:agy:2:APPROVE"

# Test automatic Round 1 CHANGES_REQUESTED -> Round 2 fix loop inside a single `factory run`
ROUND_RUNNER="$TMPROOT/round-runner.sh"
cat > "$ROUND_RUNNER" <<'SH'
#!/usr/bin/env bash
STAGE="$1"; ROLE="$2"; PROMPT="$3"; OUT="$4"
case "$STAGE" in
  intake) printf 'VERDICT: ACCEPT\nRISK: low\nSURFACES: code\n## Summary\n- Accept.\n' > "$OUT" ;;
  spec)   printf '# Spec\n- Build feature cleanly.\n' > "$OUT" ;;
  build)
    if grep -q "Prior Round 1 Reviewer Feedback" "$AFK_FACTORY_COMPILED_PROMPT"; then
      printf '## Summary\n- Addressed Round 1 finding.\n' > "$OUT"
    else
      printf '## Summary\n- Initial draft.\n' > "$OUT"
    fi
    ;;
  review-code)
    if [[ "$OUT" == *"/round-1/"* ]]; then
      printf 'VERDICT: CHANGES_REQUESTED\n## Summary\n- Missing edge-case guard.\n' > "$OUT"
    else
      printf 'VERDICT: PASS\n## Summary\n- Edge-case guard verified.\n' > "$OUT"
    fi
    ;;
esac
printf '{"used_tokens":12000,"window_tokens":200000,"compacted":false}\n'
SH
chmod +x "$ROUND_RUNNER"

MULTI_ROUND_OUT="$(
  AFK_FACTORY_AGENT_RUNNER="$ROUND_RUNNER" \
  OP_SERVICE_ACCOUNT_TOKEN=stub \
  AFK_OP_BIN="$STUB_BIN/op" \
  AFK_CURL_BIN="$STUB_BIN/curl" \
  bash "$AFK" factory run --repo "$FAILOVER_REPO" --slug spektacle --job job-two-round --title "Edge case fix loop" --json
)"

assert_eq "Single factory run automatically loops Round 1 CHANGES_REQUESTED -> Round 2 build fix -> PASS -> APPROVE" \
  "$(jq -r '"\(.round):\(.stage):\(.decision)"' <<<"$MULTI_ROUND_OUT")" \
  "2:merged:APPROVE"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
