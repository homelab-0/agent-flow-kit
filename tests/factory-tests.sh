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
ROUTE_LOCAL="$(AFK_LITELLM_BASE_URL="http://gateway.example.com:4000" AFK_ROUTER_LITELLM_ASSUME_ONLINE=1 bash "$AFK" factory route-preview --repo "$BMAD_REPO" --stage build --risk low --json)"
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
bash "$AFK" factory tooling-sync --repo "$LITELLM_REPO" --mcp-mode litellm --litellm-url "http://gateway.example.com:4000" --enable-mcp postgres-ro,github --json >/dev/null
assert_eq "LiteLLM tooling-sync routes project .mcp.json servers through LiteLLM /mcp/<server> gateway" \
  "$(jq -r '"\(.mcpServers["postgres-ro"].url)|\(.mcpServers["github"].headers["x-litellm-mcp"])"' "$LITELLM_REPO/.mcp.json")" \
  "http://gateway.example.com:4000/mcp/postgres-ro|true"

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

# ----------------------------------------------------------------------------
# 9. Factory Stall Watchdog, Auto-Nudge Recovery & Universal Stage Timeout
# ----------------------------------------------------------------------------
printf '\n9. Factory stall watchdog, auto-nudge recovery & universal stage timeout\n'

WD_REPO="$TMPROOT/repo-watchdog"
mkdir -p "$WD_REPO"
git -C "$WD_REPO" init -b main >/dev/null 2>&1
git -C "$WD_REPO" config user.email "test@example.com"
git -C "$WD_REPO" config user.name "AFK Test"
echo "watchdog" > "$WD_REPO/README.md"
git -C "$WD_REPO" add README.md
git -C "$WD_REPO" commit -m "init" >/dev/null 2>&1
bash "$AFK" factory init --repo "$WD_REPO" >/dev/null

# 9a: Healthy active job (current bash PID $$, fresh epoch) is NOT interrupted
ACTIVE_DIR="$WD_REPO/.afk/jobs/job-healthy"
mkdir -p "$ACTIVE_DIR"
NOW_EP="$(date -u +%s)"
cat > "$ACTIVE_DIR/job.json" <<JSON
{"schema":"afk-factory-job/1","id":"job-healthy","slug":"wd","repo_path":"$WD_REPO","worktree_path":"$WD_REPO","stage":"build","round":1}
JSON
cat > "$ACTIVE_DIR/heartbeat.json" <<JSON
{"schema":"afk-factory-heartbeat/1","pid":$$,"state":"running","stage":"build","role":"dev","last_beat_epoch":$NOW_EP,"nudge_count":0}
JSON

# 9b: Dead coordinator mid-build (intake + spec already saved on disk) -> nudged & resumed to completion
STALLED_DIR="$WD_REPO/.afk/jobs/job-crashed"
mkdir -p "$STALLED_DIR/round-1"
cat > "$STALLED_DIR/job.json" <<JSON
{"schema":"afk-factory-job/1","id":"job-crashed","slug":"wd","title":"Recover stalled build","repo_path":"$WD_REPO","worktree_path":"$WD_REPO","stage":"build","round":1}
JSON
printf 'VERDICT: ACCEPT\nRISK: low\nSURFACES: code\n## Summary\n- Accepted.\n' > "$STALLED_DIR/intake.md"
printf '# Spec\n- Finish stalled task.\n' > "$STALLED_DIR/spec.md"
cat > "$STALLED_DIR/heartbeat.json" <<JSON
{"schema":"afk-factory-heartbeat/1","pid":999999,"state":"running","stage":"build","role":"dev","last_beat_epoch":$((NOW_EP - 1200)),"nudge_count":0}
JSON

# 9c: Job that already exhausted max_nudges -> escalates to needs-human instead of looping forever
CAP_DIR="$WD_REPO/.afk/jobs/job-cap"
mkdir -p "$CAP_DIR/round-1"
cat > "$CAP_DIR/job.json" <<JSON
{"schema":"afk-factory-job/1","id":"job-cap","slug":"wd","title":"Repeatedly stalled job","repo_path":"$WD_REPO","worktree_path":"$WD_REPO","stage":"build","round":1}
JSON
cat > "$CAP_DIR/heartbeat.json" <<JSON
{"schema":"afk-factory-heartbeat/1","pid":999998,"state":"running","stage":"build","role":"dev","last_beat_epoch":$((NOW_EP - 1200)),"nudge_count":2}
JSON

WD_OUT="$(
  AFK_WATCHDOG_MAX_NUDGES=2 \
  OP_SERVICE_ACCOUNT_TOKEN=stub \
  AFK_OP_BIN="$STUB_BIN/op" \
  AFK_CURL_BIN="$STUB_BIN/curl" \
  bash "$AFK" factory watchdog --repo "$WD_REPO" --stale-seconds 600 --json
)"

assert_eq "Watchdog leaves healthy live PID untouched, nudges+resumes dead runner to APPROVE, and escalates job exceeding max_nudges" \
  "$(jq -r '[.actions[] | "\(.job_id)=\(.action):\(.stage)"] | sort | join(",")' <<<"$WD_OUT")" \
  "job-cap=escalated_max_nudges:needs-human,job-crashed=nudged_and_resumed:merged,job-healthy=healthy_running:build"

assert_contains "Watchdog recovery nudge was injected into resumed build prompt" \
  "$(cat "$STALLED_DIR/.prompt-build-dev.md")" \
  "Watchdog Stall Recovery Nudge"

# 9d: Subscription harness wall-clock timeout kills hung claude (`sleep 5` > 1s) and fails over in-flight to agy
HUNG_BIN="$TMPROOT/hung-cli-bin"
mkdir -p "$HUNG_BIN"
cat > "$HUNG_BIN/claude" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "2.1.322 (Claude Code)"; exit 0; fi
sleep 5
exit 0
SH
cp "$MOCK_CLI_BIN/agy" "$HUNG_BIN/agy"
chmod +x "$HUNG_BIN/claude" "$HUNG_BIN/agy"

rm -f "$AFK_ROUTER_SIGNALS_FILE" "$AFK_STATE_DIR/router/pool-signals.json"
# Clean job-healthy before running timeout test so repo is clean
rm -rf "$ACTIVE_DIR"
TMO_JOB_DIR="$WD_REPO/.afk/jobs/job-hung-claude"
mkdir -p "$TMO_JOB_DIR/round-1"
printf 'VERDICT: ACCEPT\nRISK: high\nSURFACES: architecture\n## Summary\n- High risk.\n' > "$TMO_JOB_DIR/intake.md"
cat > "$TMO_JOB_DIR/job.json" <<JSON
{"schema":"afk-factory-job/1","id":"job-hung-claude","slug":"wd","title":"Timeout failover test","repo_path":"$WD_REPO","worktree_path":"$WD_REPO","stage":"spec","round":1,"risk":"high","surfaces":["architecture"]}
JSON

# Invoke stage agent directly on high-risk `spec` (where claude/opus is #1 and agy/gemini-4-carbon is #2):
# claude hangs -> killed after 1s (`stage_timeout_1s`) -> marks anthropic-max degraded -> fails over to agy!
(
  export PATH="$HUNG_BIN:$PATH"
  export AFK_FACTORY_LIVE_HARNESS=1
  export AFK_STAGE_TIMEOUT_SEC=1
  export AFK_ROUTER_HARNESS_LIST=""
  # shellcheck disable=SC1091
  . "$KIT_ROOT/lib/afk-common.sh"
  # shellcheck disable=SC1091
  . "$KIT_ROOT/lib/afk-paperclip.sh"
  # shellcheck disable=SC1091
  . "$KIT_ROOT/lib/afk-roster.sh"
  # shellcheck disable=SC1091
  . "$KIT_ROOT/lib/afk-paperclip-hire.sh"
  # shellcheck disable=SC1091
  . "$KIT_ROOT/lib/afk-harnesses.sh"
  # shellcheck disable=SC1091
  . "$KIT_ROOT/lib/afk-tooling.sh"
  # shellcheck disable=SC1091
  . "$KIT_ROOT/lib/afk-smart-router.sh"
  # shellcheck disable=SC1091
  . "$KIT_ROOT/lib/afk-factory.sh"
  printf '# Issue\nTest hung claude\n' > "$TMO_JOB_DIR/issue.md"
  afk_factory_invoke_stage_agent "$WD_REPO" "$WD_REPO" "$TMO_JOB_DIR" "architect" "spec" "$TMO_JOB_DIR/issue.md" "$TMO_JOB_DIR/spec.md" ""
)

assert_eq "Universal stage timeout kills hung subscription harness (claude 1s) and fails over in-flight to agy" \
  "$(jq -sr '[.[] | "\(.status):\(.harness):\(.error // "ok")"] | join("->")' "$TMO_JOB_DIR/route-history.jsonl")" \
  "failed_attempt:claude:stage_timeout_1s->ok:agy:ok"

# ----------------------------------------------------------------------------
# 10. Paperclip v2026.1106.0 Native Integration: Real Git Merge, Issue Docs,
#     Work Products, Cost Telemetry, Confirmation Cards, Sync-Reviews & Poller
# ----------------------------------------------------------------------------
head1 "10. Paperclip v2026.1106.0 native integration (docs, work-products, cost-events, confirmations, sync-reviews, skills-store, poll)"

PC_REPO="$TMPROOT/repo-pc-native"
mkdir -p "$PC_REPO"
git -C "$PC_REPO" init -b main >/dev/null 2>&1
git -C "$PC_REPO" config user.email "test@example.com"
git -C "$PC_REPO" config user.name "AFK Test"
printf 'package demo\n' > "$PC_REPO/app.go"
git -C "$PC_REPO" add app.go
git -C "$PC_REPO" commit -m "initial main commit" >/dev/null 2>&1
bash "$AFK" factory init --repo "$PC_REPO" >/dev/null

PC_STATE="$TMPROOT/pc-mock-state"
mkdir -p "$PC_STATE"
PC_REQ_LOG="$PC_STATE/requests.jsonl"
: > "$PC_REQ_LOG"
printf '0\n' > "$PC_STATE/spent_cents"
printf '[]\n' > "$PC_STATE/interactions.json"
printf '[]\n' > "$PC_STATE/comments.json"
printf '[{"id":"44444444-2222-4333-8444-555555555555","identifier":"HOM-99","title":"Add poller helper","description":"Create poller_ok.go","status":"todo","assigneeAgentId":null}]\n' > "$PC_STATE/todo_issues.json"

PC_CURL_BIN="$TMPROOT/pc-curl-bin"
mkdir -p "$PC_CURL_BIN"
cat > "$PC_CURL_BIN/curl" <<'PCCURL'
#!/usr/bin/env bash
method="GET" url="" data=""
while (($#)); do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data|--data-binary|--data-raw|-d)
      if [[ "${2:-}" == @* ]]; then
        data="$(cat -- "${2#@}" 2>/dev/null || true)"
      else
        data="${2:-}"
      fi
      shift 2 ;;
    http*://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
jq -cn --arg m "$method" --arg u "$url" --arg d "$data" \
  '{method:$m, url:$u, body:(try ($d | fromjson) catch $d)}' >> "$PC_REQ_LOG"

case "$method $url" in
  "GET "*"/api/agents/479f0f09-ee4a-4b31-902b-b662d906f41b")
    spent="$(cat "$PC_STATE/spent_cents" 2>/dev/null || echo 0)"
    printf '{"id":"479f0f09-ee4a-4b31-902b-b662d906f41b","status":"idle","budgetMonthlyCents":1000,"spentMonthlyCents":%s}200' "$spent" ;;
  "POST "*"/api/companies/"*"/agent-hires")
    printf '{"agent":{"id":"a1111111-2222-4333-8444-555555555555","status":"active"}}201' ;;
  "GET "*"/api/issues/"*"/active-run")
    printf '{"id":"b1111111-2222-4333-8444-555555555555"}200' ;;
  "GET "*"/api/issues/"*"/documents/"*)
    printf '{"error":"not_found"}404' ;;
  "PUT "*"/api/issues/"*"/documents/"*)
    dkey="${url##*/}"
    printf '{"id":"d1111111-2222-4333-8444-555555555555","key":"%s","latestRevisionId":"f1111111-2222-4333-8444-555555555555","latestRevisionNumber":1}200' "$dkey" ;;
  "POST "*"/api/companies/"*"/cost-events")
    printf '{"id":"c1111111-2222-4333-8444-555555555555"}201' ;;
  "POST "*"/api/issues/"*"/work-products")
    printf '{"id":"e2222222-2222-4333-8444-555555555555","type":"commit"}201' ;;
  "POST "*"/api/issues/"*"/interactions")
    printf '{"interaction":{"id":"e1111111-2222-4333-8444-555555555555","kind":"request_confirmation"}}201' ;;
  "GET "*"/api/issues/"*"/interactions")
    printf '%s200' "$(cat "$PC_STATE/interactions.json")" ;;
  "GET "*"/api/issues/"*"/comments")
    printf '%s200' "$(cat "$PC_STATE/comments.json")" ;;
  "GET "*"/api/companies/"*"/skills/"*"/files?path="*)
    printf '%s200' '{"path":"SKILL.md","kind":"skill","content":"---\nname: paperclip-audit-skill\ndescription: Company audit skill from Paperclip store\n---\n# Audit Skill\n"}' ;;
  "GET "*"/api/companies/"*"/skills")
    printf '[{"id":"99999999-2222-4333-8444-555555555555","slug":"paperclip-audit-skill","description":"Company audit skill","fileInventory":[{"path":"SKILL.md","kind":"skill"}]}]200' ;;
  "GET "*"/api/companies/"*"/issues?projectId="*)
    printf '%s200' "$(cat "$PC_STATE/todo_issues.json")" ;;
  "POST "*"/api/issues/"*"/checkout")
    printf '{"ok":true}200' ;;
  *)
    printf '{"ok":true}200' ;;
esac
PCCURL
chmod +x "$PC_CURL_BIN/curl"

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
      "slug": "pcproj",
      "repo_path": "$PC_REPO",
      "harness": "claude",
      "max_active_issues": 1,
      "merge": "pm",
      "factory_enabled": true
    }
  ]
}
JSON
chmod 600 "$AFK_PAPERCLIP_CONFIG"

PC_RUNNER="$TMPROOT/pc-runner.sh"
cat > "$PC_RUNNER" <<'SH'
#!/usr/bin/env bash
STAGE="$1"; ROLE="$2"; PROMPT="$3"; OUT="$4"
case "$STAGE" in
  intake) printf 'VERDICT: ACCEPT\nRISK: low\nSURFACES: code\n## Summary\n- Ready.\n' > "$OUT" ;;
  spec)   printf '# Engineering Plan\n- Create feature file cleanly.\n' > "$OUT" ;;
  build)
    if [[ "$AFK_FACTORY_JOB_DIR" == *"job-pc-merge"* ]]; then
      printf 'package demo\nfunc Feature() string { return "merged" }\n' > "$AFK_FACTORY_WORKTREE/feature.go"
    elif [[ "$AFK_FACTORY_JOB_DIR" == *"job-pc-escalate"* ]]; then
      if grep -q "Human Board Feedback" "$AFK_FACTORY_COMPILED_PROMPT"; then
        git -C "$AFK_FACTORY_WORKTREE" rm -f CODEOWNERS >/dev/null 2>&1 || rm -f "$AFK_FACTORY_WORKTREE/CODEOWNERS"
        # Reset branch to main so CODEOWNERS is no longer in branch diff, then add clean file
        git -C "$AFK_FACTORY_WORKTREE" reset --soft main >/dev/null 2>&1 || true
        git -C "$AFK_FACTORY_WORKTREE" checkout HEAD -- CODEOWNERS >/dev/null 2>&1 || rm -f "$AFK_FACTORY_WORKTREE/CODEOWNERS"
        printf 'owner note addressed\n' > "$AFK_FACTORY_WORKTREE/owner_note.txt"
      else
        printf '* @org/owners\n' > "$AFK_FACTORY_WORKTREE/CODEOWNERS"
      fi
    elif [[ "$AFK_FACTORY_JOB_DIR" == *"job-pc-human-accept"* ]]; then
      printf '* @org/security\n' > "$AFK_FACTORY_WORKTREE/CODEOWNERS"
    else
      printf 'package demo\nfunc Polled() bool { return true }\n' > "$AFK_FACTORY_WORKTREE/poller_ok.go"
    fi
    printf '## Summary\n- Built changes in worktree.\n' > "$OUT"
    ;;
  review-code)
    printf 'VERDICT: PASS\n## Summary\n- Clean implementation.\n' > "$OUT" ;;
esac
printf '{"used_tokens":5000,"input_tokens":4000,"output_tokens":1000,"window_tokens":200000,"compacted":false}\n'
SH
chmod +x "$PC_RUNNER"

# 10a: Auto-approved job merges git branch into main, upserts Issue Documents, logs cost-events & registers commit Work Product
PC_MERGE_OUT="$(
  PC_REQ_LOG="$PC_REQ_LOG" PC_STATE="$PC_STATE" \
  AFK_FACTORY_AGENT_RUNNER="$PC_RUNNER" \
  OP_SERVICE_ACCOUNT_TOKEN=stub \
  AFK_OP_BIN="$STUB_BIN/op" \
  AFK_CURL_BIN="$PC_CURL_BIN/curl" \
  bash "$AFK" factory run --repo "$PC_REPO" --slug pcproj --job job-pc-merge \
    --issue 11111111-2222-4333-8444-555555555555 --title "Land real git merge" --json
)"

assert_eq "Approved job actually lands feature.go onto base repository main branch" \
  "$([[ -f "$PC_REPO/feature.go" ]] && echo present || echo missing):$(jq -r '.stage' <<<"$PC_MERGE_OUT")" \
  "present:merged"

assert_eq "job.json records exact merged_commit matching base repo HEAD" \
  "$(jq -r '.merged_commit' <<<"$PC_MERGE_OUT")" \
  "$(git -C "$PC_REPO" rev-parse HEAD)"

assert_eq "Paperclip Issue Documents upserted for plan, review-report, and merge-decision" \
  "$(jq -sr '[.[] | select(.method == "PUT" and (.url | contains("/documents/"))) | (.url | split("/") | last)] | sort | unique | join(",")' "$PC_REQ_LOG")" \
  "merge-decision,plan,review-report"

assert_eq "Paperclip cost-events posted for all 4 stages with host agentId and positive token counts" \
  "$(jq -sr '[.[] | select(.method == "POST" and (.url | endswith("/cost-events"))) | select(.body.agentId == "479f0f09-ee4a-4b31-902b-b662d906f41b" and .body.inputTokens == 4000 and .body.outputTokens == 1000)] | length' "$PC_REQ_LOG")" \
  "4"

assert_eq "Paperclip commit Work Product registered with status=merged and reviewState=approved" \
  "$(jq -sr '[.[] | select(.method == "POST" and (.url | endswith("/work-products"))) | "\(.body.type):\(.body.status):\(.body.reviewState)"] | last' "$PC_REQ_LOG")" \
  "commit:merged:approved"

# 10b: Escalated job creates request_confirmation card; human rejection triggers Round 2 repair with feedback; human acceptance merges
: > "$PC_REQ_LOG"
PC_ESC_OUT="$(
  PC_REQ_LOG="$PC_REQ_LOG" PC_STATE="$PC_STATE" \
  AFK_FACTORY_AGENT_RUNNER="$PC_RUNNER" \
  OP_SERVICE_ACCOUNT_TOKEN=stub \
  AFK_OP_BIN="$STUB_BIN/op" \
  AFK_CURL_BIN="$PC_CURL_BIN/curl" \
  bash "$AFK" factory run --repo "$PC_REPO" --slug pcproj --job job-pc-escalate \
    --issue 22222222-2222-4333-8444-555555555555 --title "Touch protected CODEOWNERS" --json
)"

assert_eq "Escalated job leaves CODEOWNERS unmerged on main, registers ready_for_review Work Product, and creates request_confirmation card" \
  "$([[ -f "$PC_REPO/CODEOWNERS" ]] && echo leaked || echo isolated):$(jq -r '.stage' <<<"$PC_ESC_OUT"):$(jq -r '.pending_interaction_id' <<<"$PC_ESC_OUT"):$(jq -sr '[.[] | select(.url | endswith("/interactions")) | .body.kind] | last' "$PC_REQ_LOG")" \
  "isolated:needs-human:e1111111-2222-4333-8444-555555555555:request_confirmation"

# Simulate human board clicking "Request changes" on the confirmation card
cat > "$PC_STATE/interactions.json" <<'JSON'
[{"id":"e1111111-2222-4333-8444-555555555555","kind":"request_confirmation","result":{"outcome":"rejected","reason":"Do not touch CODEOWNERS; write owner_note.txt instead."}}]
JSON

SYNC_REJ_OUT="$(
  PC_REQ_LOG="$PC_REQ_LOG" PC_STATE="$PC_STATE" \
  AFK_FACTORY_AGENT_RUNNER="$PC_RUNNER" \
  OP_SERVICE_ACCOUNT_TOKEN=stub \
  AFK_OP_BIN="$STUB_BIN/op" \
  AFK_CURL_BIN="$PC_CURL_BIN/curl" \
  bash "$AFK" factory sync-reviews --repo "$PC_REPO" --slug pcproj --json
)"

assert_eq "sync-reviews detects rejected confirmation card, injects feedback into Round 2 build, fixes protected path, and lands owner_note.txt" \
  "$(jq -r '.actions[0].action + ":" + .actions[0].stage' <<<"$SYNC_REJ_OUT"):$([[ -f "$PC_REPO/owner_note.txt" && ! -f "$PC_REPO/CODEOWNERS" ]] && echo clean_landed || echo bad)" \
  "reentered_with_feedback:merged:clean_landed"

# Now test human clicking "Approve & merge" (`outcome: "accepted"`) on an escalated CODEOWNERS change
printf '[]\n' > "$PC_STATE/interactions.json"
PC_ACC_ESC="$(
  PC_REQ_LOG="$PC_REQ_LOG" PC_STATE="$PC_STATE" \
  AFK_FACTORY_AGENT_RUNNER="$PC_RUNNER" \
  OP_SERVICE_ACCOUNT_TOKEN=stub \
  AFK_OP_BIN="$STUB_BIN/op" \
  AFK_CURL_BIN="$PC_CURL_BIN/curl" \
  bash "$AFK" factory run --repo "$PC_REPO" --slug pcproj --job job-pc-human-accept \
    --issue 33333333-2222-4333-8444-555555555555 --title "Authorized CODEOWNERS update" --json
)"
cat > "$PC_STATE/interactions.json" <<'JSON'
[{"id":"e1111111-2222-4333-8444-555555555555","kind":"request_confirmation","result":{"outcome":"accepted"}}]
JSON

SYNC_ACC_OUT="$(
  PC_REQ_LOG="$PC_REQ_LOG" PC_STATE="$PC_STATE" \
  AFK_FACTORY_AGENT_RUNNER="$PC_RUNNER" \
  OP_SERVICE_ACCOUNT_TOKEN=stub \
  AFK_OP_BIN="$STUB_BIN/op" \
  AFK_CURL_BIN="$PC_CURL_BIN/curl" \
  bash "$AFK" factory sync-reviews --repo "$PC_REPO" --slug pcproj --json
)"

assert_eq "sync-reviews detects accepted confirmation card and merges authorized CODEOWNERS onto main" \
  "$(jq -r '.actions[0].action' <<<"$SYNC_ACC_OUT"):$([[ -f "$PC_REPO/CODEOWNERS" ]] && echo landed || echo missing)" \
  "approved_and_merged:landed"

# 10c: Budget hard-stop check, Paperclip Skills Store sync, and autonomous `factory poll`
printf '1000\n' > "$PC_STATE/spent_cents"
BUDGET_OUT="$(
  PC_REQ_LOG="$PC_REQ_LOG" PC_STATE="$PC_STATE" \
  AFK_FACTORY_AGENT_RUNNER="$PC_RUNNER" \
  OP_SERVICE_ACCOUNT_TOKEN=stub \
  AFK_OP_BIN="$STUB_BIN/op" \
  AFK_CURL_BIN="$PC_CURL_BIN/curl" \
  bash "$AFK" factory run --repo "$PC_REPO" --slug pcproj --job job-pc-budget \
    --issue 55555555-2222-4333-8444-555555555555 --title "Should stop on budget" --json
)"
assert_contains "Pre-flight Paperclip monthly budget hard-stop pauses job before spending LLM tokens" \
  "$(jq -r '.merge_evaluation.reasons[0]' <<<"$BUDGET_OUT")" \
  "budget hard-stop"
rm -rf "$PC_REPO/.afk/jobs/job-pc-budget"
printf '100\n' > "$PC_STATE/spent_cents"

PC_SKILLS_SYNC="$(
  PC_REQ_LOG="$PC_REQ_LOG" PC_STATE="$PC_STATE" \
  AFK_PAPERCLIP_SKILLS_DIR="$TMPROOT/pc-skills" \
  AFK_TOOLING_REGISTRY_FILE="$TMPROOT/pc-tooling-reg.json" \
  OP_SERVICE_ACCOUNT_TOKEN=stub \
  AFK_OP_BIN="$STUB_BIN/op" \
  AFK_CURL_BIN="$PC_CURL_BIN/curl" \
  bash "$AFK" factory tooling --sync-paperclip-skills --json
)"
assert_eq "Paperclip Company Skills Store sync downloads SKILL.md and registers skill in AFK central registry" \
  "$(jq -r '"\(.ok):\(.synced_count):\(.synced_skills[0].slug)"' <<<"$PC_SKILLS_SYNC"):$([[ -f "$TMPROOT/pc-skills/paperclip-audit-skill/SKILL.md" ]] && echo file_ok || echo missing)" \
  "true:1:paperclip-audit-skill:file_ok"

POLL_OUT="$(
  PC_REQ_LOG="$PC_REQ_LOG" PC_STATE="$PC_STATE" \
  AFK_FACTORY_AGENT_RUNNER="$PC_RUNNER" \
  OP_SERVICE_ACCOUNT_TOKEN=stub \
  AFK_OP_BIN="$STUB_BIN/op" \
  AFK_CURL_BIN="$PC_CURL_BIN/curl" \
  bash "$AFK" factory poll --slug pcproj --json
)"
assert_eq "Autonomous factory poll claims todo issue HOM-99 via atomic checkout, runs pipeline, and merges poller_ok.go onto main" \
  "$(jq -r '"\(.dispatched_count):\(.dispatched[0].job_id):\(.dispatched[0].stage)"' <<<"$POLL_OUT"):$([[ -f "$PC_REPO/poller_ok.go" ]] && echo landed || echo missing)" \
  "1:hom-99:merged:landed"

# ----------------------------------------------------------------------------
# 11. Live Quota Accuracy: Anthropic OAuth 7d/5h Telemetry, Codex rate_limits,
#     Transient Timeout TTL Recovery & Unauthenticated Pool Gating
# ----------------------------------------------------------------------------
head1 "11. Live quota accuracy (Anthropic OAuth 97%/82%, Codex rate_limits, transient timeout TTL, unauthenticated xai-grok)"

QUOTA_TMP="$TMPROOT/quota-accuracy"
mkdir -p "$QUOTA_TMP/codex-sessions" "$QUOTA_TMP/bin"
for hbin in claude codex agy opencode; do
  cat > "$QUOTA_TMP/bin/$hbin" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "1.0.0"; exit 0; fi
exit 0
SH
  chmod +x "$QUOTA_TMP/bin/$hbin"
done

cat > "$QUOTA_TMP/claude-97.json" <<'JSON'
{
  "five_hour": null,
  "seven_day": {
    "utilization": 97.0,
    "resets_at": "2026-11-13T20:59:59Z"
  },
  "extra_usage": {
    "is_enabled": false,
    "disabled_reason": "out_of_credits"
  },
  "limits": [
    {"kind": "weekly_all", "group": "weekly", "percent": 97, "severity": "critical", "is_active": true}
  ]
}
JSON

cat > "$QUOTA_TMP/claude-82.json" <<'JSON'
{
  "five_hour": {"utilization": 25.0},
  "seven_day": {
    "utilization": 82.0,
    "resets_at": "2026-11-13T20:59:59Z"
  },
  "extra_usage": {"is_enabled": false},
  "limits": [
    {"kind": "weekly_all", "group": "weekly", "percent": 82, "severity": "warning", "is_active": true}
  ]
}
JSON

FUTURE_EPOCH=$(( $(date -u +%s) + 43200 ))
cat > "$QUOTA_TMP/codex-sessions/rollout-2026-11-11T01-00-00-test.jsonl" <<EOF
{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":84.0,"window_minutes":10080,"resets_at":$FUTURE_EPOCH},"secondary":null,"plan_type":"pro"}}}
EOF

STALE_TIMEOUT_EP=$(( $(date -u +%s) - 1800 ))
cat > "$QUOTA_TMP/signals-stale-timeout.json" <<EOF
{
  "pools": {
    "antigravity-pool": {
      "used_pct": 100,
      "degraded_reason": "stage_timeout_900s",
      "updated_epoch": $STALE_TIMEOUT_EP
    }
  }
}
EOF

cat > "$QUOTA_TMP/oc-auth-no-xai.json" <<'JSON'
{
  "openai": {"type": "oauth", "accountId": "acct_qtest"}
}
JSON
cat > "$QUOTA_TMP/codex-auth.json" <<'JSON'
{"auth_mode": "oauth", "tokens": {"account_id": "acct_qtest"}}
JSON

Q_POOLS_97="$(
  unset AFK_ROUTER_HARNESS_LIST
  AFK_HARNESS_BIN_DIR_OVERRIDE="$QUOTA_TMP/bin" \
  AFK_ROUTER_BENCHMARKS_FILE="$KIT_ROOT/files/model-router/benchmarks.json" \
  AFK_ROUTER_SIGNALS_FILE="$QUOTA_TMP/signals-stale-timeout.json" \
  AFK_CLAUDE_USAGE_FIXTURE="$QUOTA_TMP/claude-97.json" \
  AFK_CODEX_SESSIONS_DIR="$QUOTA_TMP/codex-sessions" \
  AFK_OPENCODE_AUTH_FILE="$QUOTA_TMP/oc-auth-no-xai.json" \
  AFK_CODEX_AUTH_FILE="$QUOTA_TMP/codex-auth.json" \
  AFK_PI_AUTH_FILE="$QUOTA_TMP/nonexistent-pi.json" \
  bash "$AFK" factory pools --json
)"
assert_eq "Live quota probe detects Claude 97% exhausted, Codex 84% warning, expires stale 30m agy timeout, and marks unauthenticated xai-grok offline" \
  "$(jq -r '"\(.pools["anthropic-max"].state):\(.pools["anthropic-max"].used_pct):\(.pools["anthropic-max"].quota_source):\(.pools["openai-plus"].state):\(.pools["openai-plus"].used_pct):\(.pools["antigravity-pool"].state):\(.pools["xai-grok"].state)"' <<<"$Q_POOLS_97")" \
  "exhausted:97:anthropic_oauth_api:warning:84:available:offline"

Q_ROUTE_82_LOW="$(
  unset AFK_ROUTER_HARNESS_LIST
  AFK_HARNESS_BIN_DIR_OVERRIDE="$QUOTA_TMP/bin" \
  AFK_ROUTER_BENCHMARKS_FILE="$KIT_ROOT/files/model-router/benchmarks.json" \
  AFK_ROUTER_SIGNALS_FILE="$QUOTA_TMP/signals-stale-timeout.json" \
  AFK_CLAUDE_USAGE_FIXTURE="$QUOTA_TMP/claude-82.json" \
  AFK_CODEX_SESSIONS_DIR="$QUOTA_TMP/codex-sessions" \
  AFK_OPENCODE_AUTH_FILE="$QUOTA_TMP/oc-auth-no-xai.json" \
  AFK_CODEX_AUTH_FILE="$QUOTA_TMP/codex-auth.json" \
  AFK_DISCOVERED_MODELS_FILE="$QUOTA_TMP/empty-disc.json" \
  bash "$AFK" factory route-preview --repo "$BMAD_REPO" --stage build --risk low --json
)"
assert_eq "When Claude is nearly used up (82% warning) and Codex is 84% warning, low-risk build conserves both and routes to agy/gemini-4-carbon" \
  "$(jq -r '"\(.harness)/\(.model):\(.entitlement_pool)"' <<<"$Q_ROUTE_82_LOW")" \
  "agy/gemini-4-carbon:antigravity-pool"

# ----------------------------------------------------------------------------
# 12. Grok Auto-Onboarding, Frontier/Security Models (Fable, Mythos, Daybreak),
#     BMAD PM Floor, Dynamic Effort Escalation & Signed-Out Auth Alerts
GF_TMP="$TMPROOT/grok-frontier-sec"
mkdir -p "$GF_TMP/bin" "$GF_TMP/codex-sessions"
head1 "12. Grok CLI onboarding, Fable/Mythos/Daybreak routing, BMAD PM floor, effort escalation & auth alerts"

for hbin in claude codex agy; do
  cat > "$GF_TMP/bin/$hbin" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "2.5.0"; exit 0; fi
exit 0
SH
  chmod +x "$GF_TMP/bin/$hbin"
done

cat > "$GF_TMP/bin/grok" <<SH
#!/usr/bin/env bash
if [[ "\${1:-}" == "--version" ]]; then echo "1.0.77"; exit 0; fi
printf '%s\n' "\$*" >> "$GF_TMP/grok-invocations.log"
printf '%s\n' '{"text":"VERDICT: PASS\n## Summary\n- Grok blind review clean.","stopReason":"end_turn","usage":{"input_tokens":3200,"cache_read_input_tokens":800,"output_tokens":120,"total_tokens":4120}}'
SH
chmod +x "$GF_TMP/bin/grok"

cat > "$GF_TMP/grok-auth.json" <<'JSON'
{
  "https://auth.x.ai::77777777-8888-4999-aaaa-bbbbbbbbbbbb": {
    "access_token": "redacted-test-token",
    "expires_at": 1893456000000
  }
}
JSON

cat > "$GF_TMP/grok-models.json" <<'JSON'
{
  "default_model": "grok-4.7",
  "models": [
    {
      "id": "grok-4.7",
      "name": "Grok 4.7",
      "context_window": 256000,
      "max_context_window": 500000,
      "default_reasoning_effort": "medium",
      "reasoning_efforts": ["xhigh", "high", "medium", "low"]
    },
    {
      "id": "grok-4.7-build-fast",
      "name": "Grok 4.7 Build Fast",
      "context_window": 256000,
      "default_reasoning_effort": "low",
      "reasoning_efforts": ["medium", "low"]
    }
  ]
}
JSON

cat > "$GF_TMP/claude-healthy-fable.json" <<'JSON'
{
  "five_hour": {"utilization": 22.0},
  "seven_day": {"utilization": 40.0, "resets_at": "2026-11-13T20:59:59Z"},
  "extra_usage": {"is_enabled": false},
  "limits": [
    {"kind": "weekly_all", "group": "weekly", "percent": 40, "severity": "info", "is_active": true},
    {"kind": "fable", "group": "scoped_weekly", "percent": 56, "severity": "info", "is_active": true}
  ]
}
JSON

cat > "$GF_TMP/codex-auth-valid.json" <<'JSON'
{"auth_mode": "chatgpt", "tokens": {"access_token": "tok_test", "account_id": "acct_sec_test"}}
JSON

# 12a: Grok CLI auto-discovery, xai-grok auth binding, and model + effort dial inventory
GF_MODELS="$(
  unset AFK_ROUTER_HARNESS_LIST
  AFK_HARNESS_BIN_DIR_OVERRIDE="$GF_TMP/bin" \
  AFK_ROUTER_BENCHMARKS_FILE="$KIT_ROOT/files/model-router/benchmarks.json" \
  AFK_DISCOVERED_MODELS_FILE="$GF_TMP/discovered-models.json" \
  AFK_GROK_AUTH_FILE="$GF_TMP/grok-auth.json" \
  AFK_GROK_MODELS_CACHE="$GF_TMP/grok-models.json" \
  AFK_CODEX_AUTH_FILE="$GF_TMP/codex-auth-valid.json" \
  AFK_OPENCODE_AUTH_FILE="$GF_TMP/no-oc.json" \
  AFK_PI_AUTH_FILE="$GF_TMP/no-pi.json" \
  bash "$AFK" factory models --sync --harness grok --json
)"
assert_eq "Newly installed grok CLI is auto-discovered with xai-grok subscription pool and effort dial [low,medium,high,xhigh]" \
  "$(jq -r '"\(.harness_effort_dials.grok.cli_flag):\([.models[] | "\(.model)=\(.entitlement_pool)[\(.supported_efforts | join("/"))]"] | sort | join(","))"' <<<"$GF_MODELS")" \
  "--effort <level>:grok-4.7-build-fast=xai-grok[low/medium],grok-4.7=xai-grok[low/medium/high/xhigh]"

# 12b: High vs Critical risk spec (Opus 5.5 vs Fable frontier reservation) & BMAD PM epics complexity floor
GF_ENV_ARGS=(
  AFK_HARNESS_BIN_DIR_OVERRIDE="$GF_TMP/bin"
  AFK_ROUTER_BENCHMARKS_FILE="$KIT_ROOT/files/model-router/benchmarks.json"
  AFK_DISCOVERED_MODELS_FILE="$GF_TMP/discovered-models.json"
  AFK_ROUTER_SIGNALS_FILE="$GF_TMP/signals.json"
  AFK_CLAUDE_USAGE_FIXTURE="$GF_TMP/claude-healthy-fable.json"
  AFK_CODEX_SESSIONS_DIR="$GF_TMP/codex-sessions"
  AFK_CODEX_AUTH_FILE="$GF_TMP/codex-auth-valid.json"
  AFK_GROK_AUTH_FILE="$GF_TMP/grok-auth.json"
  AFK_OPENCODE_AUTH_FILE="$GF_TMP/no-oc.json"
  AFK_PI_AUTH_FILE="$GF_TMP/no-pi.json"
)

SPEC_HIGH="$(unset AFK_ROUTER_HARNESS_LIST; env "${GF_ENV_ARGS[@]}" bash "$AFK" factory route-preview --repo "$BMAD_REPO" --stage spec --risk high --json)"
SPEC_CRIT="$(unset AFK_ROUTER_HARNESS_LIST; env "${GF_ENV_ARGS[@]}" bash "$AFK" factory route-preview --repo "$BMAD_REPO" --stage spec --risk critical --json)"
BMAD_PM_EPICS="$(unset AFK_ROUTER_HARNESS_LIST; env "${GF_ENV_ARGS[@]}" bash "$AFK" factory route-preview --repo "$BMAD_REPO" --stage epics --role pm --risk medium --json)"

assert_eq "High-risk spec uses claude/opus (effort=high) while critical-risk frontier_synthesis unlocks claude/claude-fable-5-1 (effort=xhigh)" \
  "$(jq -r '"\(.model):\(.effort):\(.task_class)"' <<<"$SPEC_HIGH")->$(jq -r '"\(.model):\(.effort):\(.task_class)"' <<<"$SPEC_CRIT")" \
  "opus:high:architecture->claude-fable-5-1:xhigh:frontier_synthesis"

assert_eq "BMAD PM creating epics/PRD at medium risk routes to Opus 5.5 (effort=high) and never downgrades to Sonnet" \
  "$(jq -r '"\(.harness)/\(.canonical_model):\(.task_class):\(.effort)"' <<<"$BMAD_PM_EPICS")" \
  "claude/anthropic/claude-opus-5-5:architecture:high"

# 12c: Security specialist routing (Mythos + cross-family Daybreak Blue) & per-model 403 quarantine
SEC_BUILD="$(unset AFK_ROUTER_HARNESS_LIST; env "${GF_ENV_ARGS[@]}" AFK_SECURITY_MODELS="mythos,daybreak-blue" bash "$AFK" factory route-preview --repo "$BMAD_REPO" --stage build --surfaces code,security --risk high --json)"
SEC_REVIEW="$(unset AFK_ROUTER_HARNESS_LIST; env "${GF_ENV_ARGS[@]}" AFK_SECURITY_MODELS="mythos,daybreak-blue" bash "$AFK" factory route-preview --repo "$BMAD_REPO" --stage review-security --surfaces code,security --risk high --builder-family anthropic --json)"
STD_BUILD="$(unset AFK_ROUTER_HARNESS_LIST; env "${GF_ENV_ARGS[@]}" AFK_SECURITY_MODELS="mythos,daybreak-blue" bash "$AFK" factory route-preview --repo "$BMAD_REPO" --stage build --surfaces code --risk medium --json)"

assert_eq "Security-surface build routes to Claude Mythos while cross-family blind review-security routes to OpenAI Daybreak Blue (and non-security build reserves them)" \
  "$(jq -r '"\(.harness)/\(.model):\(.task_class)"' <<<"$SEC_BUILD")->$(jq -r '"\(.harness)/\(.model):\(.task_class)"' <<<"$SEC_REVIEW")|std=$(jq -r '.model' <<<"$STD_BUILD")" \
  "claude/claude-mythos-5-2:security->codex/gpt-daybreak-blue-latest:security|std=sonnet"

# Quarantine restricted Mythos model on 403 without poisoning anthropic-max pool
(
  # shellcheck disable=SC1091
  source "$KIT_ROOT/lib/afk-harnesses.sh"
  # shellcheck disable=SC1091
  source "$KIT_ROOT/lib/afk-smart-router.sh"
  AFK_ROUTER_SIGNALS_FILE="$GF_TMP/signals.json" afk_router_mark_model_unavailable "claude-mythos-5-2" "403 model_not_found"
)
SEC_BUILD_FALLBACK="$(unset AFK_ROUTER_HARNESS_LIST; env "${GF_ENV_ARGS[@]}" AFK_SECURITY_MODELS="mythos,daybreak-blue" bash "$AFK" factory route-preview --repo "$BMAD_REPO" --stage build --surfaces code,security --risk high --json)"
assert_eq "Quarantining 403 Mythos model leaves anthropic-max healthy and fails security build over to Daybreak Blue" \
  "$(jq -r '"\(.harness)/\(.model)"' <<<"$SEC_BUILD_FALLBACK")" \
  "codex/gpt-daybreak-blue-latest"

# 12d: Dynamic mid-job effort escalation across rounds & headless Grok review when Claude=97% + Codex=401
EFF_R1="$(unset AFK_ROUTER_HARNESS_LIST; env "${GF_ENV_ARGS[@]}" bash "$AFK" factory route-preview --repo "$BMAD_REPO" --stage build --risk medium --round 1 --json)"
EFF_R2="$(unset AFK_ROUTER_HARNESS_LIST; env "${GF_ENV_ARGS[@]}" bash "$AFK" factory route-preview --repo "$BMAD_REPO" --stage build --risk medium --round 2 --json)"
EFF_R3="$(unset AFK_ROUTER_HARNESS_LIST; env "${GF_ENV_ARGS[@]}" bash "$AFK" factory route-preview --repo "$BMAD_REPO" --stage build --risk medium --round 3 --json)"

assert_eq "Dynamic effort escalates automatically as rounds increase (round 1 medium -> round 2 high -> round 3 xhigh)" \
  "$(jq -r '"\(.effort):\(.effort_escalated)"' <<<"$EFF_R1")->$(jq -r '"\(.effort):\(.effort_escalated)"' <<<"$EFF_R2")->$(jq -r '"\(.effort):\(.effort_escalated)"' <<<"$EFF_R3")" \
  "medium:false->high:true->xhigh:true"

# Simulate devbox live state: Claude 97% exhausted + Codex 401 token_revoked + Grok signed in + Agy healthy
NOW_EP="$(date -u +%s)"
cat > "$GF_TMP/signals-devbox.json" <<EOF
{
  "pools": {
    "openai-plus": {
      "used_pct": 100,
      "degraded_kind": "auth",
      "degraded_reason": "401 token_revoked: signing key invalidated",
      "updated_epoch": $NOW_EP
    }
  }
}
EOF
touch -d "@$((NOW_EP - 3600))" "$GF_TMP/codex-auth-valid.json" 2>/dev/null || true

DEVBOX_SIM_POOLS="$(
  unset AFK_ROUTER_HARNESS_LIST
  AFK_HARNESS_BIN_DIR_OVERRIDE="$GF_TMP/bin" \
  AFK_ROUTER_BENCHMARKS_FILE="$KIT_ROOT/files/model-router/benchmarks.json" \
  AFK_DISCOVERED_MODELS_FILE="$GF_TMP/discovered-models.json" \
  AFK_ROUTER_SIGNALS_FILE="$GF_TMP/signals-devbox.json" \
  AFK_CLAUDE_USAGE_FIXTURE="$QUOTA_TMP/claude-97.json" \
  AFK_CODEX_SESSIONS_DIR="$GF_TMP/codex-sessions" \
  AFK_CODEX_AUTH_FILE="$GF_TMP/codex-auth-valid.json" \
  AFK_GROK_AUTH_FILE="$GF_TMP/grok-auth.json" \
  AFK_OPENCODE_AUTH_FILE="$GF_TMP/no-oc.json" \
  AFK_PI_AUTH_FILE="$GF_TMP/no-pi.json" \
  bash "$AFK" factory pools --json
)"
DEVBOX_SIM_ROUTES="$(
  unset AFK_ROUTER_HARNESS_LIST
  AFK_HARNESS_BIN_DIR_OVERRIDE="$GF_TMP/bin" \
  AFK_ROUTER_BENCHMARKS_FILE="$KIT_ROOT/files/model-router/benchmarks.json" \
  AFK_DISCOVERED_MODELS_FILE="$GF_TMP/discovered-models.json" \
  AFK_ROUTER_SIGNALS_FILE="$GF_TMP/signals-devbox.json" \
  AFK_CLAUDE_USAGE_FIXTURE="$QUOTA_TMP/claude-97.json" \
  AFK_CODEX_SESSIONS_DIR="$GF_TMP/codex-sessions" \
  AFK_CODEX_AUTH_FILE="$GF_TMP/codex-auth-valid.json" \
  AFK_GROK_AUTH_FILE="$GF_TMP/grok-auth.json" \
  AFK_OPENCODE_AUTH_FILE="$GF_TMP/no-oc.json" \
  AFK_PI_AUTH_FILE="$GF_TMP/no-pi.json" \
  bash "$AFK" factory route-preview --repo "$BMAD_REPO" --risk medium --json
)"

assert_eq "Signed-out/revoked Codex pool surfaces auth_required + codex login alert while Agy builds and Grok blind-reviews cross-family" \
  "$(jq -r '"\(.pools["openai-plus"].state):\(.auth_alerts[0].reauth_command)"' <<<"$DEVBOX_SIM_POOLS")|$(jq -r '[.[] | select(.stage == "build" or .stage == "review-code") | "\(.stage)=\(.harness)/\(.model)"] | join(",")' <<<"$DEVBOX_SIM_ROUTES")" \
  "auth_required:codex login|build=agy/gemini-4-carbon,review-code=grok/grok-4.7"

# Verify headless grok invocation extracts .text and passes --effort
GROK_EXEC_RES="$(
  # shellcheck disable=SC1091
  source "$KIT_ROOT/lib/afk-harnesses.sh"
  # shellcheck disable=SC1091
  source "$KIT_ROOT/lib/afk-smart-router.sh"
  # shellcheck disable=SC1091
  source "$KIT_ROOT/lib/afk-roster.sh"
  # shellcheck disable=SC1091
  source "$KIT_ROOT/lib/afk-paperclip-hire.sh"
  # shellcheck disable=SC1091
  source "$KIT_ROOT/lib/afk-factory.sh"
  PATH="$GF_TMP/bin:$PATH"
  AFK_HARNESS_BIN_DIR_OVERRIDE="$GF_TMP/bin"
  AFK_ROUTER_HARNESS_LIST="grok"
  AFK_GROK_AUTH_FILE="$GF_TMP/grok-auth.json"
  AFK_ROUTER_BENCHMARKS_FILE="$KIT_ROOT/files/model-router/benchmarks.json"
  AFK_ROUTER_SIGNALS_FILE="$GF_TMP/grok-only-sig.json"
  AFK_FACTORY_LIVE_HARNESS=1
  printf 'Review diff\n' > "$GF_TMP/prompt.md"
  afk_factory_invoke_stage_agent "$BMAD_REPO" "$BMAD_REPO" "$BMAD_REPO/.afk/jobs/job-clean" "reviewer" "review-code" "$GF_TMP/prompt.md" "$GF_TMP/grok-out.md"
  printf '{"used_tokens":%s}\n' "${AFK_LAST_STAGE_USED_TOKENS:-0}"
)"
assert_eq "Headless grok CLI runner passes --effort high and extracts .text + token usage cleanly" \
  "$(head -n 1 "$GF_TMP/grok-out.md"):$(jq -r '.used_tokens' <<<"$GROK_EXEC_RES"):$(grep -c -- '--effort high' "$GF_TMP/grok-invocations.log")" \
  "VERDICT: PASS:4120:1"

# ----------------------------------------------------------------------------
# 13. Paperclip Central Tooling + Skills Auto-Bridge, 3-Tier Precedence,
#     Studio Publisher & Zero-Pollution Ephemeral Worktree Materialization
# ----------------------------------------------------------------------------
head1 "13. Paperclip Central Tooling + Skills Auto-Bridge, 3-tier fallback, Studio publish & clean worktree git merges"

BRIDGE_TMP="$TMPROOT/pc-bridge"
mkdir -p "$BRIDGE_TMP/curl-bin" "$BRIDGE_TMP/state" "$BRIDGE_TMP/skills-store"
BRIDGE_REQ_LOG="$BRIDGE_TMP/requests.jsonl"
: > "$BRIDGE_REQ_LOG"

cat > "$BRIDGE_TMP/paperclip.json" <<JSON
{
  "schema": "afk-paperclip-config/2",
  "api_url": "https://paperclip.bridge.test",
  "company_id": "4ffcc005-8076-4062-b72e-e4f2d899ecb0",
  "board_user_id": "emXp8Svi8ncWyL1EORTkRNQYjFjCdQon",
  "host": {
    "label": "ubuntu-devbox",
    "agent_id": "479f0f09-ee4a-4b31-902b-b662d906f41b",
    "key_ref": "op://develop/paperclip/KEY"
  },
  "projects": []
}
JSON
chmod 600 "$BRIDGE_TMP/paperclip.json"

cat > "$BRIDGE_TMP/curl-bin/curl" <<'BCCURL'
#!/usr/bin/env bash
method="GET"; url=""; body=""
while (( $# > 0 )); do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -H|-w) shift 2 ;;
    --data-binary) body="$2"; shift 2 ;;
    -s|-S|-sS|--max-time) [[ "$1" == "--max-time" ]] && shift 2 || shift ;;
    http*://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
if [[ -n "${BRIDGE_REQ_LOG:-}" ]]; then
  jq -cn --arg m "$method" --arg u "$url" --arg b "$body" \
    '{method:$m, url:$u, body:(try ($b | fromjson) catch $b)}' >> "$BRIDGE_REQ_LOG"
fi
case "$method $url" in
  "GET "*"/api/agents/479f0f09-ee4a-4b31-902b-b662d906f41b/skills")
    printf '%s200' '{"adapterType":"process","supported":false,"desiredSkills":["company/4ffcc005-8076-4062-b72e-e4f2d899ecb0/afk-fleet-tooling","company/4ffcc005-8076-4062-b72e-e4f2d899ecb0/qa-acceptance"],"desiredSkillEntries":[{"slug":"afk-fleet-tooling"},{"slug":"qa-acceptance"}]}' ;;
  "POST "*"/api/agents/"*"/skills/sync")
    printf '%s200' '{"ok":true,"desiredSkills":["company/4ffcc005-8076-4062-b72e-e4f2d899ecb0/afk-fleet-tooling"]}' ;;
  "GET "*"/api/companies/"*"/skills")
    if [[ -f "${BRIDGE_STATE_SKILLS:-}" ]]; then
      printf '%s200' "$(cat "$BRIDGE_STATE_SKILLS")"
    else
      cat <<'SKJSON' | tr -d '\n'
[
  {"id":"b0000001-0000-4000-8000-000000000001","slug":"agentmail","key":"paperclipai/paperclip/agentmail","folderPath":"bundled/paperclip-core","sourceBadge":"paperclip","sourceLabel":"Paperclip bundled","editable":false,"fileInventory":[{"path":"SKILL.md"}]},
  {"id":"b0000002-0000-4000-8000-000000000002","slug":"complain","key":"paperclipai/paperclip/complain","folderPath":"bundled/paperclip-core","sourceBadge":"paperclip","sourceLabel":"Paperclip bundled","editable":false,"fileInventory":[{"path":"SKILL.md"}]},
  {"id":"c0000001-0000-4000-8000-000000000001","slug":"afk-fleet-tooling","key":"company/4ffcc005-8076-4062-b72e-e4f2d899ecb0/afk-fleet-tooling","editable":true,"description":"Fleet MCP Gateway","fileInventory":[{"path":"SKILL.md"},{"path":"mcp.json"}]},
  {"id":"c0000002-0000-4000-8000-000000000002","slug":"qa-acceptance","key":"company/4ffcc005-8076-4062-b72e-e4f2d899ecb0/qa-acceptance","editable":true,"description":"QA Acceptance Playbook","fileInventory":[{"path":"SKILL.md"}]}
]
SKJSON
      printf '200'
    fi ;;
  "POST "*"/api/companies/"*"/skills")
    printf '%s201' '{"id":"c0000099-0000-4000-8000-000000000099","slug":"afk-fleet-tooling"}' ;;
  "PATCH "*"/api/companies/"*"/skills/"*"/files")
    printf '%s200' '{"ok":true,"editable":true}' ;;
  "GET "*"/api/companies/"*"/skills/c0000001-0000-4000-8000-000000000001/files?path=SKILL.md")
    printf '%s200' '{"path":"SKILL.md","content":"---\nname: afk-fleet-tooling\ndescription: Fleet MCP Gateway\n---\n# Fleet Tooling\n"}' ;;
  "GET "*"/api/companies/"*"/skills/c0000001-0000-4000-8000-000000000001/files?path=mcp.json")
    mcp_c='{"mcp_mode":"litellm","litellm_mcp_url":"http://gateway.example.com:4000","enabled_mcp":["postgres-ro","github","homelab-prom"],"enabled_skills":[],"mcpServers":{"homelab-prom":{"type":"http","url":"http://gateway.example.com:8080/mcp","headers":{"Authorization":"Bearer ${PROM_MCP_TOKEN}"}}}}'
    jq -cn --arg c "$mcp_c" '{path:"mcp.json", content:$c}' | tr -d '\n'
    printf '200' ;;
  "GET "*"/api/companies/"*"/skills/c0000002-0000-4000-8000-000000000002/files?path=SKILL.md")
    printf '%s200' '{"path":"SKILL.md","content":"---\nname: qa-acceptance\ndescription: QA Acceptance Playbook\n---\n# QA Acceptance\n"}' ;;
  *)
    printf '{"ok":true}200' ;;
esac
BCCURL
chmod +x "$BRIDGE_TMP/curl-bin/curl"

# 13a: Bundled Paperclip internal skills skipped; Studio mcp.json + desiredSkills synced
BRIDGE_SYNC_OUT="$(
  AFK_PAPERCLIP_CONFIG="$BRIDGE_TMP/paperclip.json" \
  AFK_PAPERCLIP_SKILLS_DIR="$BRIDGE_TMP/skills-store" \
  AFK_TOOLING_REGISTRY_FILE="$BRIDGE_TMP/tooling.json" \
  OP_SERVICE_ACCOUNT_TOKEN=stub \
  AFK_OP_BIN="$STUB_BIN/op" \
  AFK_CURL_BIN="$BRIDGE_TMP/curl-bin/curl" \
  bash "$AFK" factory tooling --sync-paperclip-skills --json
)"
assert_eq "Paperclip sync skips bundled internal skills (agentmail, complain) and syncs Studio mcp.json + qa-acceptance" \
  "$(jq -r '"\(.ok):\(.skipped_bundled_count):\(.synced_count):\(.central_mcp_synced):\(.central_source_skill):\([.synced_skills[].slug] | sort | join(","))"' <<<"$BRIDGE_SYNC_OUT"):$([[ -d "$BRIDGE_TMP/skills-store/agentmail" ]] && echo leaked || echo clean)" \
  "true:2:2:true:afk-fleet-tooling:afk-fleet-tooling,qa-acceptance:clean"

# 13b: Three-tier config precedence (Paperclip Central -> Repo Override -> Standalone Offline Fallback)
REPO_PC_INHERIT="$BRIDGE_TMP/repo-inherit"
mkdir -p "$REPO_PC_INHERIT"
INHERIT_SYNC="$(
  AFK_PAPERCLIP_CONFIG="$BRIDGE_TMP/paperclip.json" \
  AFK_PAPERCLIP_SKILLS_DIR="$BRIDGE_TMP/skills-store" \
  AFK_TOOLING_REGISTRY_FILE="$BRIDGE_TMP/tooling.json" \
  OP_SERVICE_ACCOUNT_TOKEN=stub \
  AFK_OP_BIN="$STUB_BIN/op" \
  AFK_CURL_BIN="$BRIDGE_TMP/curl-bin/curl" \
  bash "$AFK" factory tooling-sync --repo "$REPO_PC_INHERIT" --json
)"
assert_eq "Zero-flag tooling-sync inherits Paperclip Central LiteLLM gateway, custom MCP headers, and attached desiredSkills (excluding carrier)" \
  "$(jq -r '"\(.config_source):\(.mcp_mode):\(.synced_skills | join(","))"' <<<"$INHERIT_SYNC")|$(jq -r '"\(.mcpServers["postgres-ro"].url)|\(.mcpServers["homelab-prom"].url)"' "$REPO_PC_INHERIT/.mcp.json")|$([[ -f "$REPO_PC_INHERIT/.agents/skills/qa-acceptance/SKILL.md" && ! -d "$REPO_PC_INHERIT/.agents/skills/afk-fleet-tooling" ]] && echo skills_ok || echo bad)" \
  "paperclip-central:litellm:qa-acceptance|http://gateway.example.com:4000/mcp/postgres-ro|http://gateway.example.com:8080/mcp|skills_ok"

REPO_LOCAL_OVR="$BRIDGE_TMP/repo-override"
mkdir -p "$REPO_LOCAL_OVR"
AFK_TOOLING_REGISTRY_FILE="$BRIDGE_TMP/tooling.json" bash "$AFK" factory tooling-register-mcp --name sqlite-local --transport stdio --target sqlite-mcp --args "--ro" >/dev/null
OVR_SYNC="$(
  AFK_PAPERCLIP_CONFIG="$BRIDGE_TMP/paperclip.json" \
  AFK_PAPERCLIP_SKILLS_DIR="$BRIDGE_TMP/skills-store" \
  AFK_TOOLING_REGISTRY_FILE="$BRIDGE_TMP/tooling.json" \
  bash "$AFK" factory tooling-sync --repo "$REPO_LOCAL_OVR" --mcp-mode standalone --enable-mcp sqlite-local --json
)"
STANDALONE_DISC="$(
  AFK_PAPERCLIP_CONFIG="$BRIDGE_TMP/no-paperclip.json" \
  AFK_TOOLING_REGISTRY_FILE="$BRIDGE_TMP/standalone-only.json" \
  AFK_TOOLING_HERMETIC=1 \
  bash "$AFK" factory tooling --json
)"
assert_eq "Explicit repo override beats Paperclip Central, and AFK without Paperclip runs in standalone-local mode" \
  "$(jq -r '"\(.config_source):\(.mcp_mode)"' <<<"$OVR_SYNC"):$(jq -r '.mcpServers["sqlite-local"].command' "$REPO_LOCAL_OVR/.mcp.json")|$(jq -r '"\(.config_source):\(.mcp_mode)"' <<<"$STANDALONE_DISC")" \
  "repo-override:standalone:sqlite-mcp|standalone-local:standalone"

# 13c: One-command Studio Publisher (`tooling-publish-paperclip`)
printf '[]' > "$BRIDGE_TMP/empty-skills.json"
: > "$BRIDGE_REQ_LOG"
PUB_OUT="$(
  BRIDGE_REQ_LOG="$BRIDGE_REQ_LOG" \
  BRIDGE_STATE_SKILLS="$BRIDGE_TMP/empty-skills.json" \
  AFK_PAPERCLIP_CONFIG="$BRIDGE_TMP/paperclip.json" \
  AFK_PAPERCLIP_SKILLS_DIR="$BRIDGE_TMP/skills-store" \
  AFK_TOOLING_REGISTRY_FILE="$BRIDGE_TMP/pub-tooling.json" \
  OP_SERVICE_ACCOUNT_TOKEN=stub \
  AFK_OP_BIN="$STUB_BIN/op" \
  AFK_CURL_BIN="$BRIDGE_TMP/curl-bin/curl" \
  bash "$AFK" factory tooling-publish-paperclip --mcp-mode litellm --litellm-url "http://gateway.example.com:4000" --enable-mcp "postgres-ro,github" --enable-skills "qa-acceptance" --json
)"
assert_eq "tooling-publish-paperclip creates Studio skill, PATCHes mcp.json, and attaches bundle to host agent via POST /skills/sync" \
  "$(jq -r '"\(.ok):\(.created):\(.attached_to_host_agent)"' <<<"$PUB_OUT")|$(jq -sr '[.[] | select(.method == "POST" or .method == "PATCH") | "\(.method):\(.url | sub("^https://[^/]+"; ""))"] | join(",")' "$BRIDGE_REQ_LOG")" \
  "true:true:true|POST:/api/companies/4ffcc005-8076-4062-b72e-e4f2d899ecb0/skills,PATCH:/api/companies/4ffcc005-8076-4062-b72e-e4f2d899ecb0/skills/c0000099-0000-4000-8000-000000000099/files,POST:/api/agents/479f0f09-ee4a-4b31-902b-b662d906f41b/skills/sync"

# 13d: Ephemeral job worktree auto-materialization (.mcp.json + opencode.json + .agents/skills) with ZERO git diff pollution on merge
WT_BRIDGE_REPO="$BRIDGE_TMP/wt-clean-repo"
mkdir -p "$WT_BRIDGE_REPO/.agents/skills/bmad-agent-dev"
git -C "$WT_BRIDGE_REPO" init -b main >/dev/null
git -C "$WT_BRIDGE_REPO" config user.email "factory@afk.test"
git -C "$WT_BRIDGE_REPO" config user.name "AFK Factory Test"
cat > "$WT_BRIDGE_REPO/.agents/skills/bmad-agent-dev/SKILL.md" <<'MD'
---
name: bmad-agent-dev
description: Original repo BMAD dev persona
---
# Original BMAD Dev
MD
printf 'package clean\n' > "$WT_BRIDGE_REPO/main.go"
git -C "$WT_BRIDGE_REPO" add -A
git -C "$WT_BRIDGE_REPO" commit -m "chore: initial commit with bmad skill" >/dev/null
bash "$AFK" factory init --repo "$WT_BRIDGE_REPO" --json >/dev/null

WT_PROBE_FILE="$BRIDGE_TMP/wt-probe.txt"
WT_BRIDGE_RUNNER="$BRIDGE_TMP/wt-runner.sh"
cat > "$WT_BRIDGE_RUNNER" <<SH
#!/usr/bin/env bash
STAGE="\$1"; ROLE="\$2"; PROMPT="\$3"; OUT="\$4"
case "\$STAGE" in
  intake) printf 'VERDICT: ACCEPT\nRISK: low\nSURFACES: code\n## Summary\n- Ready.\n' > "\$OUT" ;;
  spec)   printf '# Spec\n- Add clean_feature.go.\n' > "\$OUT" ;;
  build)
    mcp_u="\$(jq -r '.mcpServers["postgres-ro"].url // "missing"' "\$AFK_FACTORY_WORKTREE/.mcp.json" 2>/dev/null)"
    oc_u="\$(jq -r '.mcp["postgres-ro"].url // "missing"' "\$AFK_FACTORY_WORKTREE/opencode.json" 2>/dev/null)"
    sk_ok="\$([[ -f "\$AFK_FACTORY_WORKTREE/.agents/skills/qa-acceptance/SKILL.md" ]] && echo yes || echo no)"
    bmad_ok="\$(grep -q 'Original BMAD Dev' "\$AFK_FACTORY_WORKTREE/.agents/skills/bmad-agent-dev/SKILL.md" && echo intact || echo overwritten)"
    git_clean="\$([[ -z "\$(git -C "\$AFK_FACTORY_WORKTREE" status --porcelain)" ]] && echo clean || echo dirty)"
    prompt_has="\$(grep -q 'qa-acceptance' "\$AFK_FACTORY_COMPILED_PROMPT" && grep -q 'postgres-ro' "\$AFK_FACTORY_COMPILED_PROMPT" && echo both || echo missing)"
    printf '%s|%s|%s|%s|%s|%s\n' "\$mcp_u" "\$oc_u" "\$sk_ok" "\$bmad_ok" "\$git_clean" "\$prompt_has" > "$WT_PROBE_FILE"
    printf 'package clean\nfunc CleanFeature() bool { return true }\n' > "\$AFK_FACTORY_WORKTREE/clean_feature.go"
    printf '## Summary\n- Implemented CleanFeature.\n' > "\$OUT"
    ;;
  review-code)
    printf 'VERDICT: PASS\n## Summary\n- Verified.\n' > "\$OUT" ;;
esac
printf '{"used_tokens":2000,"input_tokens":1500,"output_tokens":500,"window_tokens":200000,"compacted":false}\n'
SH
chmod +x "$WT_BRIDGE_RUNNER"

WT_RUN_OUT="$(
  AFK_PAPERCLIP_CONFIG="$BRIDGE_TMP/no-live-pc.json" \
  AFK_PAPERCLIP_SKILLS_DIR="$BRIDGE_TMP/skills-store" \
  AFK_TOOLING_REGISTRY_FILE="$BRIDGE_TMP/tooling.json" \
  AFK_FACTORY_AGENT_RUNNER="$WT_BRIDGE_RUNNER" \
  bash "$AFK" factory run --repo "$WT_BRIDGE_REPO" --slug cleanproj --job job-ephemeral-bridge --title "Verify clean ephemeral bridge" --json
)"
MERGED_FILES="$(git -C "$WT_BRIDGE_REPO" diff --name-only HEAD~1..HEAD | tr '\n' ',' | sed 's/,$//')"
LEFTOVER_EXCL="$(grep -c 'AFK-EPHEMERAL' "$WT_BRIDGE_REPO/.git/info/exclude" 2>/dev/null || true)"

assert_eq "Ephemeral worktree exposes Paperclip MCPs (.mcp.json + opencode.json) & skills to agents while leaving BMAD intact" \
  "$(cat "$WT_PROBE_FILE")" \
  "http://gateway.example.com:4000/mcp/postgres-ro|http://gateway.example.com:4000/mcp/postgres-ro|yes|intact|clean|both"

assert_eq "Merged commit on main contains ONLY clean_feature.go with zero .mcp.json/opencode.json/.agents/skills pollution and cleaned info/exclude" \
  "$(jq -r '.stage' <<<"$WT_RUN_OUT"):${MERGED_FILES}:${LEFTOVER_EXCL}:$([[ -f "$WT_BRIDGE_REPO/.mcp.json" || -d "$WT_BRIDGE_REPO/.agents/skills/qa-acceptance" ]] && echo leaked || echo spotless)" \
  "merged:clean_feature.go:0:spotless"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
