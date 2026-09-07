#!/usr/bin/env bash
# Reviewer's own stub harness for AFK-PORT-1.5A. Independent of tests/run-tests.sh:
# it builds its own worktree, catalog, stubs and fixtures, so a bug in the
# story's own suite cannot hide behind it. Sourced by every attack-*.sh.
set -uo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
DISPATCH="$KIT_ROOT/files/model-router/scripts/dispatch.sh"
SHIPPED_POLICY="$KIT_ROOT/files/model-router/context-budget-policy.yaml"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n        %s\n' "$1" "${2:-}"; }
eq()  { [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "expected [$3] got [$2]"; }
has() { [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "missing [$3] in: ${2:0:300}"; }
hasnt() { [[ "$2" != *"$3"* ]] && ok "$1" || bad "$1" "unexpectedly contains [$3]"; }
nofile() { [[ ! -e "$1" ]] && ok "$2" || bad "$2" "$1 exists"; }
emptyfile() { [[ ! -s "$1" ]] && ok "$2" || bad "$2" "$(cat "$1")"; }

setup_env() {
  ROOT="$(mktemp -d /tmp/afk15a-review.XXXXXX)"
  WORK="$ROOT/work"; BIN="$WORK/bin"; WT="$WORK/wt"; HOME_DIR="$WORK/home"
  STUB_STATE="$WORK/state"
  mkdir -p "$BIN" "$WT/_bmad/bmm/agents" "$HOME_DIR/.claude" "$STUB_STATE"
  printf 'You are the dev persona.\n' > "$WT/_bmad/bmm/agents/dev.md"

  cat > "$WORK/catalog.yaml" <<'YAML'
schema_version: 1
profiles:
  "claude/strong":
    hosting: vendor
    physical:
      - model_id: "claude/opus"
        placement: null
  local-code-standard:
    hosting: local
    min_context: 65536
    physical:
      - model_id: qwen36-27b
        placement: cachyos-7900xtx
  "openai/strong":
    hosting: vendor
    min_context: 400000
    physical:
      - model_id: "openai/gpt-5.6-sol"
        placement: null
YAML
  windowed_catalog() { # windowed_catalog <out> <window>
    awk -v w="$2" '{print} /^  "claude\/strong":[[:space:]]*$/ {print "    min_context: " w}' \
      "$WORK/catalog.yaml" > "$1"
  }

  cat > "$BIN/orca" <<'STUB'
#!/usr/bin/env bash
sub="$1 $2"; shift 2 || true
case "$sub" in
  "worktree list") jq -n --arg p "$STUB_WT_PATH" --arg id "$STUB_WT_ID" '{ok:true,result:{worktrees:[{id:$id,path:$p}]}}' ;;
  "repo list") jq -n --arg id "$STUB_REPO_ID" --arg pol "${STUB_SETUP_POLICY:-start-immediately}" '{ok:true,result:{repos:[{id:$id,hookSettings:{setupAgentStartupPolicy:$pol}}]}}' ;;
  "terminal create")
    while (( $# )); do case "$1" in
      --command) printf '%s' "$2" > "$STUB_STATE/last-command.txt"; shift 2 ;;
      --title) shift 2 ;; *) shift ;; esac; done
    echo created >> "$STUB_STATE/terminal-creates"
    jq -n '{ok:true,result:{terminal:{handle:"term_stub"}}}' ;;
  "terminal read") jq -n --arg t "${STUB_TERMINAL_TAIL:-}" --arg s "${STUB_TERMINAL_STATUS:-running}" '{ok:true,result:{terminal:{handle:"term_stub",status:$s,tail:($t|split("\n"))}}}' ;;
  "terminal rename") jq -n '{ok:true}' ;;
  *) jq -n '{ok:true,result:{}}' ;;
esac
STUB
  cat > "$BIN/agent-stamp-validate" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$STUB_STATE/validator-argv.txt"
jq -n '{valid:true, catalog_version:"sha256:'"$(printf '0%.0s' {1..64})"'", checks:[]}'
exit 0
STUB
  cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [[ "$prev" == "-o" ]] && out="$a"; prev="$a"; done
echo "$*" >> "$STUB_STATE/curl-calls"
[[ -n "$out" ]] && jq -n '{status:"placed",model:"qwen36-27b",placement:"cachyos-7900xtx",readiness:"warm",headers:{"x-placement":"cachyos-7900xtx"},ttl_seconds:30,reason:null,alternatives:[],catalog_version:"sha256:x"}' > "$out"
printf '200'
STUB
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/claude"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/codex"
  cat > "$BIN/op" <<'STUB'
#!/usr/bin/env bash
[[ "$1" == "read" && -n "${2:-}" ]] || exit 2
printf '%s' 'sentinel-gw'
STUB
  chmod +x "$BIN"/*
  printf 'export OP_SERVICE_ACCOUNT_TOKEN=stub\n' > "$WORK/op-env"

  export STUB_STATE STUB_WT_PATH="$WT" STUB_REPO_ID="repo-1234" STUB_WT_ID="repo-1234::$WT"
  export STUB_TERMINAL_TAIL="ok
CLAUDE_EXIT=0"
}

write_stamp() { # <file> <effort> <placement_required> [profile] [harness] [pool]
  jq -n --arg e "$2" --argjson pr "$3" --arg p "${4:-claude/strong}" \
        --arg h "${5:-claude}" --arg pool "${6:-}" \
    '{harness:$h, model_profile:$p, effort:$e,
      cost_class:(if $pr then "free" else "subscription" end),
      entitlement_pool:(if $pool != "" then $pool elif $pr then null else "anthropic-max" end),
      metered:false, placement_policy:"prefer-warm-local", placement_required:$pr,
      catalog_version:"sha256:abc", expires_at:"2099-01-01T00:00:00Z",
      task:{story_id:"STORY-TEST-1", tags:["docs"]}, override:null}' > "$1"
}
write_story() { { printf -- '---\n%s\n---\n\nDo the thing.\n' "$2"; } > "$1"; }

reset_stubs() { : > "$STUB_STATE/curl-calls"; : > "$STUB_STATE/terminal-creates"; rm -f "$STUB_STATE/last-command.txt"; }

run_dispatch() { # <story> [cycle] -> exit code; stderr in $WORK/err
  ( cd "${RUN_CWD:-$WT}" && PATH="$BIN:$PATH" HOME="$HOME_DIR" \
      AGENT_STAMP_VALIDATE="agent-stamp-validate" \
      AGENT_STAMP_VALIDATE_CATALOG_PATH="${STUB_CATALOG-$WORK/catalog.yaml}" \
      AGENT_FLOW_BUDGET_POLICY="${STUB_BUDGET_POLICY-$SHIPPED_POLICY}" \
      AGENT_FLOW_CONFIG="$WORK/nonexistent.yaml" SUBSCRIPTIONS_FILE="" \
      AGENT_ROUTER_URL="https://router.invalid" AGENT_ROUTER_TOKEN="stub-token" \
      AGENT_ROUTER_TOKEN_ENV="AGENT_ROUTER_TOKEN" \
      AGENT_DIR="" AGENT_FLOW_APPROVED_HOME="" AGENT_FLOW_APPROVED_PATH="" \
      AGENT_FLOW_LAUNCH_TIMEOUT=20 \
      AGENT_FLOW_GATEWAY_URL="https://gateway.invalid" \
      AGENT_FLOW_GATEWAY_TOKEN_REF="op://stubvault/agw-claude-code/credential" \
      AGENT_FLOW_OP_ENV_FILE="$WORK/op-env" CLAUDE_CONFIG_DIR="" \
      bash "$DISPATCH" "$1" "${2:-1}" ) >"$WORK/out" 2>"$WORK/err"
  echo $?
}
bud() { jq -r "$1" "$2"; }
summary() { printf '\n%s: %d passed, %d failed\n' "${0##*/}" "$PASS" "$FAIL"; [[ $FAIL -eq 0 ]]; }
