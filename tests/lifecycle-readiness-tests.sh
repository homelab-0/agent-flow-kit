#!/usr/bin/env bash
# lifecycle-readiness-tests.sh — the isolated deterministic gate for scoped
# execution readiness: host, new-work, per-target and per-route.
#
# Two layers, and the live one is STUBBED end to end:
#   UNIT      — the readiness primitives are sourced and called directly, with
#               table-driven matrices for target wiring, launch contracts and
#               funding conflicts.
#   SCENARIO  — bin/agent-flow-kit is RUN against a fixture host with stubbed
#               orca / agent-stamp-validate / claude / codex / curl on PATH,
#               so every live branch is reached for real without a network, a
#               provider session, a worker or a token.
#
# Stub behaviour is selected through named STUB_* globals that run_afk passes
# explicitly, and every scenario resets them. A bare `VAR=value run_afk ...`
# would be wrong here: bash keeps such an assignment after a FUNCTION call, so
# one scenario's stub would silently configure the next one's.
#
# run_afk also pins every provider variable the funding checks look at, so this
# suite answers the same whether or not the developer's own shell exports one.
#
# A check that could not compute a verdict here SKIPS loudly and is counted:
# the summary line carries the skip count, and a skipped check is not a pass.
#
# Nothing in this suite touches the developer's real HOME, real installation,
# real Git state, the router, a provider session, or Orca.
#
# Usage: tests/lifecycle-readiness-tests.sh
# Exit:  0 all passed, 1 any failure.

set -uo pipefail

KIT_ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
AFK="$KIT_ROOT/bin/agent-flow-kit"

TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT

SENTINEL='afk-sentinel-secret-DO-NOT-EMIT-4f2c9a1b'

export GIT_AUTHOR_NAME="afk-test" GIT_AUTHOR_EMAIL="afk@test.invalid"
export GIT_COMMITTER_NAME="afk-test" GIT_COMMITTER_EMAIL="afk@test.invalid"

PASS=0 FAIL=0 SKIPPED=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  {
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  if [[ -n "${2:-}" ]]; then printf '        %s\n' "$2"; fi
  FAIL=$((FAIL + 1))
}
# A check this host cannot decide. It is counted and reported, because a
# scenario that quietly computed nothing is indistinguishable from one that
# passed, and that is exactly how a bounding assertion goes vacuous.
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; SKIPPED=$((SKIPPED + 1)); }
head1() { printf '\n\033[1m%s\033[0m\n' "$1"; }

assert_eq()       { if [[ "$2" == "$3"   ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
assert_ne()       { if [[ "$2" != "$3"   ]]; then ok "$1"; else bad "$1" "should not equal '$3'"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing substring: $3"; fi; }
assert_absent()   { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "should NOT contain: $3"; fi; }

# ===========================================================================
head1 "0. Readiness primitives (lib sourced, nothing executed)"
# ===========================================================================

# shellcheck source=../lib/afk-common.sh
. "$KIT_ROOT/lib/afk-common.sh"
# shellcheck source=../lib/afk-readiness.sh
. "$KIT_ROOT/lib/afk-readiness.sh"

# --- the readiness vocabulary is real, and does not shadow the base one ----
BAD_MSG=0; BAD_ACT=0; COUNT=0
while IFS= read -r code; do
  [[ -n "$code" ]] || continue
  COUNT=$((COUNT + 1))
  if [[ -z "$(afk_readiness_reason_message "$code")" ]]; then
    BAD_MSG=$((BAD_MSG + 1)); printf '        no message: %s\n' "$code"
  fi
  if [[ -z "$(afk_readiness_reason_action "$code")" ]]; then
    BAD_ACT=$((BAD_ACT + 1)); printf '        no action: %s\n' "$code"
  fi
done < <(afk_readiness_reason_codes)
assert_ne "the readiness vocabulary is non-empty" "$COUNT" "0"
assert_eq "every readiness code carries a specific message" "$BAD_MSG" "0"
assert_eq "every readiness code carries a required action"  "$BAD_ACT" "0"
assert_eq "no duplicate readiness codes" \
  "$(afk_readiness_reason_codes | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')" "0"
assert_eq "the readiness half never collides with the base half" \
  "$(comm -12 <(afk_reason_codes | LC_ALL=C sort) \
              <(afk_readiness_reason_codes | LC_ALL=C sort) | wc -l | tr -d ' ')" "0"
# The extension hook is what makes those messages reachable from a finding.
assert_eq "the base dispatcher reaches a readiness message" \
  "$(afk_reason_message ROUTER_TIMED_OUT)" "$(afk_readiness_reason_message ROUTER_TIMED_OUT)"
assert_ne "and it is not the generic fallback" \
  "$(afk_reason_message ROUTER_TIMED_OUT)" "$AFK_REASON_FALLBACK"
assert_eq "an unknown code still falls back exactly once" \
  "$(afk_reason_message NOT_A_REAL_CODE)" "$AFK_REASON_FALLBACK"

# --- the launch contract this executor declares ---------------------------
assert_eq "claude + a vendor profile is launchable" \
  "$(afk_launch_contract_reason claude claude/strong false)" ""
assert_eq "codex + a vendor profile is launchable" \
  "$(afk_launch_contract_reason codex openai/strong false)" ""
assert_ne "claude + a placement-required profile has no launch contract" \
  "$(afk_launch_contract_reason claude local-code-standard true)" ""
assert_ne "codex + a placement-required profile has no launch contract" \
  "$(afk_launch_contract_reason codex local-code-standard true)" ""
assert_ne "an unknown harness has no launch contract at all" \
  "$(afk_launch_contract_reason banana claude/strong false)" ""

# --- funding conflicts are per route, per harness, and name-only ----------
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CONFIG_DIR 2>/dev/null || true
unset OPENAI_API_KEY OPENAI_BASE_URL CODEX_API_KEY 2>/dev/null || true
assert_eq "a clean environment conflicts with nothing" \
  "$(afk_route_funding_conflict claude subscription false)" ""
export ANTHROPIC_API_KEY="$SENTINEL"
assert_contains "an API key conflicts with a claude subscription route" \
  "$(afk_route_funding_conflict claude subscription false)" "ANTHROPIC_API_KEY"
assert_absent "the reported conflict is the NAME, never the value" \
  "$(afk_route_funding_conflict claude subscription false)" "$SENTINEL"
assert_eq "the same key does not touch a codex route" \
  "$(afk_route_funding_conflict codex subscription false)" ""
assert_eq "an explicitly metered route is not blocked by credential shape" \
  "$(afk_route_funding_conflict claude metered true)" ""
assert_eq "nor is an explicitly API-backed entitlement" \
  "$(afk_route_funding_conflict claude api false)" ""
unset ANTHROPIC_API_KEY

# --- execution-stamp shape ------------------------------------------------
SU="$TMPROOT/stamps"; mkdir -p "$SU"
jq -n '{harness:"claude", model_profile:"claude/strong", effort:"high",
        cost_class:"subscription", entitlement_pool:"anthropic-max", metered:false,
        placement_policy:"prefer-warm-local", placement_required:false,
        catalog_version:"sha256:abc", expires_at:"2099-01-01T00:00:00Z",
        task:{story_id:"S-1", tags:["docs"]}, override:null}' > "$SU/good.json"
if afk_stamp_shape_is_valid "$SU/good.json"; then ok "a closed, complete stamp is valid"
else bad "a closed, complete stamp is valid"; fi

for mutation in 'del(.harness)' 'del(.expires_at)' '.metered = "no"' \
                '.expires_at = "tomorrow"' 'del(.task)' '.task = {}' \
                '.placement_required = "yes"' '.extra_field = 1'; do
  jq "$mutation" "$SU/good.json" > "$SU/bad.json"
  if afk_stamp_shape_is_valid "$SU/bad.json"; then
    bad "a stamp mutated by '$mutation' is refused"
  else
    ok "a stamp mutated by '$mutation' is refused"
  fi
done

if EPOCH="$(afk_epoch_of_utc '2099-01-01T00:00:00Z')" && [[ "$EPOCH" =~ ^[0-9]+$ ]]; then
  ok "an RFC3339 UTC instant resolves to epoch seconds"
else
  skip "no usable date(1) dialect on this host"
fi

# --- target wiring, table driven ------------------------------------------
TMPL_REL="_bmad/bmm/workflows/4-implementation/create-story/template.md"

make_target() { # <dir> — a target repository wired for agent-flow-kit
  mkdir -p "$1/_bmad/bmm/workflows/4-implementation/create-story" "$1/_bmad/bmm/agents"
  cat > "$1/$TMPL_REL" <<'TEMPLATE'
---
linear:
stamp:
persona: dev
gates:
  - "<real command>"
max_cycles: 3
---

Story body.
TEMPLATE
  printf 'dev persona\n' > "$1/_bmad/bmm/agents/dev.md"
  printf 'pm persona\n'  > "$1/_bmad/bmm/agents/pm.md"
}

TU="$TMPROOT/targets"; mkdir -p "$TU"
make_target "$TU/ok"
afk_target_wiring_evaluate "$TU/ok"
assert_eq "a fully wired target resolves"       "$AFK_TW_STATE" "READY"
assert_eq "with a stable reason"                "$AFK_TW_REASON" "TARGET_WIRING_PROVEN"
assert_eq "and reports the recognized layout"   "$AFK_TW_DETAIL" "bmad-v6-tree"
assert_contains "and a bounded wiring identity" "$AFK_TW_IDENTITY" "sha256:"

afk_target_wiring_evaluate "$TU/not-there"
assert_eq "an absent target path is BROKEN" "$AFK_TW_STATE" "BROKEN"
assert_eq "with a stable reason"            "$AFK_TW_REASON" "TARGET_PATH_MISSING"

mkdir -p "$TU/bare"
afk_target_wiring_evaluate "$TU/bare"
assert_eq "directory presence alone is never compatibility" "$AFK_TW_STATE" "INCOMPATIBLE"
assert_eq "with a stable reason" "$AFK_TW_REASON" "TARGET_WIRING_UNRECOGNIZED"

for case_name in missing-linear missing-stamp missing-persona missing-gates missing-max_cycles \
                 retired-route retired-local_gpu no-frontmatter no-dev no-pm dangling-persona; do
  d="$TU/case-$case_name"
  rm -rf "$d"; make_target "$d"
  want=""
  case "$case_name" in
    missing-*)
      key="${case_name#missing-}"
      grep -v -E "^[[:space:]]*$key:" "$d/$TMPL_REL" > "$d/t.new"
      mv "$d/t.new" "$d/$TMPL_REL"
      want="TARGET_WIRING_SCHEMA_INCOMPATIBLE" ;;
    retired-*)
      key="${case_name#retired-}"
      awk -v k="$key" 'NR == 1 { print; print k ": something"; next } { print }' \
        "$d/$TMPL_REL" > "$d/t.new"
      mv "$d/t.new" "$d/$TMPL_REL"
      want="TARGET_WIRING_MALFORMED" ;;
    no-frontmatter)
      printf 'Just a story body.\n' > "$d/$TMPL_REL"
      want="TARGET_WIRING_SCHEMA_INCOMPATIBLE" ;;
    no-dev)
      rm -f "$d/_bmad/bmm/agents/dev.md"; want="TARGET_PERSONA_UNRESOLVED" ;;
    no-pm)
      rm -f "$d/_bmad/bmm/agents/pm.md";  want="TARGET_PERSONA_UNRESOLVED" ;;
    dangling-persona)
      rm -f "$d/_bmad/bmm/agents/dev.md"
      ln -s "$d/_bmad/bmm/agents/nowhere.md" "$d/_bmad/bmm/agents/dev.md"
      want="TARGET_PERSONA_UNRESOLVED" ;;
  esac
  afk_target_wiring_evaluate "$d"
  assert_eq "target wiring case '$case_name' fails closed" "$AFK_TW_REASON" "$want"
  assert_ne "and never reports READY: $case_name" "$AFK_TW_STATE" "READY"
done

# Two physical copies of the wiring that disagree: ownership ambiguity, not a
# tie to break.
d="$TU/case-ambiguous"
rm -rf "$d"; make_target "$d"
mkdir -p "$d/.agents/skills/bmad-create-story"
printf -- '---\nlinear:\nstamp:\npersona: dev\ngates:\nmax_cycles: 3\n---\nDIFFERENT\n' \
  > "$d/.agents/skills/bmad-create-story/template.md"
afk_target_wiring_evaluate "$d"
assert_eq "two disagreeing wiring copies are ownership ambiguity" \
  "$AFK_TW_REASON" "TARGET_WIRING_OWNERSHIP_AMBIGUOUS"

# The skills layout is recognized on its own, and a mirrored copy that resolves
# to the same bytes is not ambiguity.
d="$TU/case-skills"
rm -rf "$d"
mkdir -p "$d/.agents/skills/bmad-create-story" "$d/.claude/skills" "$d/_bmad/bmm/agents"
cat > "$d/.agents/skills/bmad-create-story/template.md" <<'TEMPLATE'
---
linear:
stamp:
persona: dev
gates:
  - "<real command>"
max_cycles: 3
---
TEMPLATE
ln -s "$d/.agents/skills/bmad-create-story" "$d/.claude/skills/bmad-create-story"
printf 'dev persona\n' > "$d/_bmad/bmm/agents/dev.md"
printf 'pm persona\n'  > "$d/_bmad/bmm/agents/pm.md"
afk_target_wiring_evaluate "$d"
assert_eq "the skills layout resolves too" "$AFK_TW_STATE" "READY"
assert_eq "and is reported as the layout it is" "$AFK_TW_DETAIL" "bmad-v6-skills"

# --- harness workspace trust is READ, never written -----------------------
TRUST="$TMPROOT/claude.json"
AFK_CLAUDE_TRUST_DB="$TRUST"
jq -n --arg p "$TU/ok" '{projects: {($p): {hasTrustDialogAccepted: true}}}' > "$TRUST"
afk_claude_workspace_trusted "$TU/ok"
assert_eq "an accepted trust decision is reported" "$?" "0"
jq -n --arg p "$TU/ok" '{projects: {($p): {hasTrustDialogAccepted: false}}}' > "$TRUST"
afk_claude_workspace_trusted "$TU/ok"
assert_eq "a path awaiting the prompt is reported" "$?" "1"
TRUST_BEFORE="$(jq -S -c . "$TRUST")"
afk_claude_workspace_trusted "$TU/ok"
assert_eq "reading the trust record never changes it" "$(jq -S -c . "$TRUST")" "$TRUST_BEFORE"
printf '{}' > "$TRUST"
afk_claude_workspace_trusted "$TU/ok"
assert_eq "an unknown path is unproven, never assumed" "$?" "2"
AFK_CLAUDE_TRUST_DB=""

assert_ne "the probe bound is at least one second" "$(afk_probe_timeout_seconds)" "0"

# ===========================================================================
# scenario fixtures
# ===========================================================================

git_commit_all() { git -C "$1" add -A >/dev/null 2>&1
                   git -C "$1" -c commit.gpgsign=false commit -q --no-verify -m "$2" >/dev/null 2>&1; }

make_checkout() {
  local d="$1"
  mkdir -p "$d/lifecycle" "$d/files/model-router/scripts" "$d/files/humanizer/skills/humanizer"
  cat > "$d/lifecycle/kit.json" <<'JSON'
{
  "kit_id": "agent-flow-kit",
  "lifecycle_schema_version": "1.0",
  "state_schema_version": "1.0",
  "result_schema_version": "1.0",
  "default_branch": "master",
  "managed_inputs": ["files", "lifecycle"]
}
JSON
  printf 'model-router skill v1\n' > "$d/files/model-router/SKILL.md"
  printf 'dispatch v1\n' > "$d/files/model-router/scripts/dispatch.sh"
  printf 'launcher:\n  router_endpoint: https://canonical.invalid\n' \
    > "$d/files/model-router/subscriptions.yaml"
  printf 'humanizer v1\n' > "$d/files/humanizer/SKILL.md"
  printf 'humanizer inner skill v1\n' > "$d/files/humanizer/skills/humanizer/SKILL.md"
  printf 'policy line one\npolicy line two\n' > "$d/files/claude-global-CLAUDE.md"
  printf 'codex guidance v1\n' > "$d/files/codex-AGENTS.md"
  git init -q "$d" >/dev/null 2>&1
  git -C "$d" symbolic-ref HEAD refs/heads/master >/dev/null 2>&1
  git_commit_all "$d" "canonical v1"
}

section_begin() { printf '# >>> agent-flow-kit managed section: %s >>>' "$1"; }
section_end()   { printf '# <<< agent-flow-kit managed section: %s <<<' "$1"; }

install_kit() {
  local h="$1" c="$2"
  mkdir -p "$h/.agents/skills" "$h/.claude/skills" "$h/.codex"
  cp -R "$c/files/model-router" "$h/.agents/skills/model-router"
  cp -R "$c/files/humanizer" "$h/.agents/skills/humanizer"
  ln -s "$h/.agents/skills/model-router" "$h/.claude/skills/model-router"
  ln -s "$h/.agents/skills/humanizer" "$h/.claude/skills/humanizer"
  { printf '# my own notes\n'
    section_begin claude-global-policy; printf '\n'
    cat "$c/files/claude-global-CLAUDE.md"
    section_end claude-global-policy; printf '\n'; } > "$h/.claude/CLAUDE.md"
  cp "$c/files/codex-AGENTS.md" "$h/.codex/AGENTS.md"
}

# --- the stub dependency set ----------------------------------------------
BIN="$TMPROOT/bin"; mkdir -p "$BIN"

cat > "$BIN/orca" <<'STUB'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "status --json")
    case "${STUB_ORCA:-ok}" in
      down) exit 1 ;;
      slow) sleep 5; printf '{"ok":true}\n' ;;
      *)    printf '{"ok":true}\n' ;;
    esac ;;
  "capabilities --json")
    case "${STUB_ORCA_CAPS:-full}" in
      none)    exit 1 ;;
      partial) printf '{"capabilities":["worktree-ownership"]}\n' ;;
      *)       printf '{"capabilities":["worktree-ownership","visible-worker-launch","argument-environment-transport","provider-runtime","session-process-isolation"]}\n' ;;
    esac ;;
  *) exit 1 ;;
esac
STUB

cat > "$BIN/agent-stamp-validate" <<'STUB'
#!/usr/bin/env bash
mode="${STUB_VALIDATOR:-honest}"
contract=false; stamp=""
while (( $# )); do
  case "$1" in
    --contract) contract=true; shift ;;
    --stamp)    stamp="${2:-}"; shift 2 ;;
    --catalog)  shift 2 ;;
    *)          shift ;;
  esac
done
if $contract; then
  case "$mode" in
    nocontract) exit 1 ;;
    future)     printf '{"identity":"stub","stamp_schema_version":"9.0"}\n'; exit 0 ;;
    *)          printf '{"identity":"stub","stamp_schema_version":"1.0"}\n'; exit 0 ;;
  esac
fi
case "$mode" in
  always-valid) exit 0 ;;
  reject-all)   exit 1 ;;
  broken)       exit 2 ;;
esac
# The honest stand-in rejects exactly the conditions the fixture set encodes,
# and nothing else. It is not a validator; it is a stub whose dispositions the
# lifecycle is allowed to depend on.
prof="$(jq -r '.model_profile // ""' "$stamp" 2>/dev/null)"
exp="$(jq -r '.expires_at // ""' "$stamp" 2>/dev/null)"
eff="$(jq -r '.effort // ""' "$stamp" 2>/dev/null)"
cat="$(jq -r '.catalog_version // ""' "$stamp" 2>/dev/null)"
if [[ "$prof" == *TAMPERED* ]]; then exit 1; fi
if [[ "$exp" < "2050-01-01T00:00:00Z" ]]; then exit 1; fi
if [[ "$cat" == "sha256:not-this-catalog" ]]; then exit 1; fi
case "$eff" in low|medium|high|xhigh) ;; *) exit 1 ;; esac
exit 0
STUB

cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--help" ]]; then
  case "${STUB_CLAUDE_CAPS:-full}" in
    unreadable) exit 1 ;;
    partial)    printf 'usage\n--model\n' ;;
    *)          printf 'usage\n--model\n--effort\n--permission-mode\n--append-system-prompt-file\n--strict-mcp-config\n' ;;
  esac
  exit 0
fi
if [[ "${1:-} ${2:-}" == "auth status" ]]; then
  case "${STUB_CLAUDE_AUTH:-sub}" in
    api)   printf 'authMethod: apiKey\n'; exit 0 ;;
    none)  printf 'Not logged in\n'; exit 1 ;;
    weird) printf 'a shape nobody declared\n'; exit 0 ;;
    *)     printf 'authMethod: claude.ai\napiProvider: firstParty\n'; exit 0 ;;
  esac
fi
exit 1
STUB

cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--help" ]]; then
  printf 'usage\nexec\n--sandbox\n--config\n'
  exit 0
fi
if [[ "${1:-} ${2:-}" == "login status" ]]; then
  case "${STUB_CODEX_AUTH:-sub}" in
    api)  printf 'Logged in using an API key\n'; exit 0 ;;
    none) printf 'Not logged in\n'; exit 1 ;;
    *)    printf 'Logged in using ChatGPT\n'; exit 0 ;;
  esac
fi
exit 1
STUB

cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
wants_code=false
for a in "$@"; do
  if [[ "$a" == '%{http_code}' ]]; then wants_code=true; fi
done
case "${STUB_ROUTER:-ok}" in
  down) exit 7 ;;
  slow) sleep 5 ;;
  http500)
    if $wants_code; then printf '500'; else printf '{}'; fi
    exit 0 ;;
  badshape)
    if $wants_code; then printf '200'; else printf '{"hello":"world"}'; fi
    exit 0 ;;
esac
if $wants_code; then printf '200'; exit 0; fi
printf '{"catalog_version":"%s"}' "${STUB_ROUTER_CATALOG:-sha256:abc}"
STUB

chmod +x "$BIN"/*

# --- stub selection, passed explicitly and reset per scenario -------------
STUB_ORCA=ok; STUB_ORCA_CAPS=full; STUB_VALIDATOR=honest
STUB_CLAUDE_AUTH=sub; STUB_CLAUDE_CAPS=full; STUB_CODEX_AUTH=sub
STUB_ROUTER=ok; STUB_ROUTER_CATALOG="sha256:abc"
LIVE_TIMEOUT_MS=5000
CLAUDE_BIN_OVERRIDE="claude"; CODEX_BIN_OVERRIDE="codex"
ROUTER_URL="https://router.invalid"; ROUTER_TOKEN="stub-token"
ENV_ANTHROPIC_API_KEY=""; ENV_OP_TOKEN=""

stub_reset() {
  STUB_ORCA=ok; STUB_ORCA_CAPS=full; STUB_VALIDATOR=honest
  STUB_CLAUDE_AUTH=sub; STUB_CLAUDE_CAPS=full; STUB_CODEX_AUTH=sub
  STUB_ROUTER=ok; STUB_ROUTER_CATALOG="sha256:abc"
  LIVE_TIMEOUT_MS=5000
  CLAUDE_BIN_OVERRIDE="claude"; CODEX_BIN_OVERRIDE="codex"
  ROUTER_URL="https://router.invalid"; ROUTER_TOKEN="stub-token"
  ENV_ANTHROPIC_API_KEY=""; ENV_OP_TOKEN=""
}

SC=""; HOMEDIR=""; CHECKOUT=""; TARGET=""
STATE_DIR_REL=".local/state/agent-flow-kit"

RUN_OUT=""; RUN_ERR=""; RUN_RC=0
run_afk() { # <args...>
  # Every provider variable the funding checks look at is pinned here, so this
  # suite answers the same whether or not the developer's own shell exports one.
  RUN_OUT="$(env PATH="$BIN:$PATH" HOME="$HOMEDIR" \
             XDG_STATE_HOME="$HOMEDIR/.local/state" \
             AFK_KIT_ROOT="$CHECKOUT" \
             AFK_LIVE_TIMEOUT_MS="$LIVE_TIMEOUT_MS" \
             AFK_CLAUDE_BIN="$CLAUDE_BIN_OVERRIDE" \
             AFK_CODEX_BIN="$CODEX_BIN_OVERRIDE" \
             AGENT_ROUTER_URL="$ROUTER_URL" \
             AGENT_ROUTER_TOKEN="$ROUTER_TOKEN" \
             ANTHROPIC_API_KEY="$ENV_ANTHROPIC_API_KEY" \
             ANTHROPIC_AUTH_TOKEN="" ANTHROPIC_BASE_URL="" CLAUDE_CONFIG_DIR="" \
             OPENAI_API_KEY="" OPENAI_BASE_URL="" CODEX_API_KEY="" \
             OP_SERVICE_ACCOUNT_TOKEN="$ENV_OP_TOKEN" \
             STUB_ORCA="$STUB_ORCA" STUB_ORCA_CAPS="$STUB_ORCA_CAPS" \
             STUB_VALIDATOR="$STUB_VALIDATOR" \
             STUB_CLAUDE_AUTH="$STUB_CLAUDE_AUTH" STUB_CLAUDE_CAPS="$STUB_CLAUDE_CAPS" \
             STUB_CODEX_AUTH="$STUB_CODEX_AUTH" \
             STUB_ROUTER="$STUB_ROUTER" STUB_ROUTER_CATALOG="$STUB_ROUTER_CATALOG" \
             bash "$AFK" "$@" 2>"$TMPROOT/stderr")"
  RUN_RC=$?
  RUN_ERR="$(cat "$TMPROOT/stderr" 2>/dev/null)"
}

jget() { printf '%s' "$RUN_OUT" | jq -r "$1"; }
has_finding_reason() {
  printf '%s' "$RUN_OUT" | jq -r --arg r "$1" '[.findings[] | select(.reason == $r)] | length'
}
finding_field() { # <reason> <jq filter applied to each matching finding>
  printf '%s' "$RUN_OUT" | jq -r --arg r "$1" "[.findings[] | select(.reason == \$r) | $2] | length"
}

write_manifest() {
  run_afk status --json
  mkdir -p "$HOMEDIR/$STATE_DIR_REL"
  printf '%s' "$RUN_OUT" | jq --arg tid "target-a" --arg tpath "$TARGET" '{
      lifecycle_schema_version: "1.0",
      state_schema_version: "1.0",
      applied_revision: .checkout.revision,
      repository: {identity: .checkout.repository_identity},
      components: (reduce (.components[]
                    | select((.ownership | startswith("MANAGED_")) and .evidence.observed != null))
                   as $c ({}; .[$c.id] = {ownership: $c.ownership,
                                          identity: $c.evidence.observed,
                                          path: $c.destination})),
      adaptations: [],
      targets: [{id: $tid, path: $tpath}]
    }' > "$HOMEDIR/$STATE_DIR_REL/state.json"
}

# The registered-target set of the fixture host, rewritten in place. Only the
# `targets` array changes: every other input stays byte-identical, so a run
# that differs differs because of the target ARITY and nothing else.
set_targets() { # <targets json array>
  jq --argjson t "$1" '.targets = $t' "$HOMEDIR/$STATE_DIR_REL/state.json" \
     > "$HOMEDIR/$STATE_DIR_REL/state.json.new" \
    && mv "$HOMEDIR/$STATE_DIR_REL/state.json.new" "$HOMEDIR/$STATE_DIR_REL/state.json"
}

new_scenario() { # <name>
  stub_reset
  SC="$TMPROOT/sc-$1"
  HOMEDIR="$SC/home"; CHECKOUT="$SC/checkout"; TARGET="$SC/target"
  mkdir -p "$HOMEDIR" "$CHECKOUT"
  make_checkout "$CHECKOUT"
  install_kit "$HOMEDIR" "$CHECKOUT"
  make_target "$TARGET"
  write_manifest
}

write_stamp() { # <path> [harness] [profile] [effort] [expires] [placement] [cost_class] [metered]
  jq -n --arg h "${2:-claude}" --arg p "${3:-claude/strong}" --arg e "${4:-high}" \
        --arg x "${5:-2099-01-01T00:00:00Z}" --argjson pr "${6:-false}" \
        --arg c "${7:-subscription}" --argjson m "${8:-false}" \
    '{harness:$h, model_profile:$p, effort:$e, cost_class:$c,
      entitlement_pool:"anthropic-max", metered:$m,
      placement_policy:"prefer-warm-local", placement_required:$pr,
      catalog_version:"sha256:abc", expires_at:$x,
      task:{story_id:"AFK-READINESS-1", tags:["docs"]}, override:null}' > "$1"
}

# ===========================================================================
head1 "1. Offline route readiness: deterministic refusals, no live claim"
# ===========================================================================

new_scenario offlineroute
STAMP="$SC/story.stamp.json"
write_stamp "$STAMP"
run_afk status --json --stamp "$STAMP"
assert_eq "a supplied stamp puts route readiness in scope" \
  "$(jget '.readiness.ROUTE_READY.evaluated')" "true"
assert_eq "offline evaluation never asserts a route is ready" \
  "$(jget '.readiness.ROUTE_READY.state')" "NOT_EVALUATED"
assert_eq "because the validator verdict is a live fact" \
  "$(jget '.readiness.ROUTE_READY.reason')" "STAMP_VALIDATION_UNPROVEN"
assert_eq "and host readiness stays unevaluated too" \
  "$(jget '.readiness.HOST_EXECUTION_READY.state')" "NOT_EVALUATED"
assert_eq "the stamp is identified by a bounded identity" \
  "$(jget '.readiness.ROUTE_READY.execution_stamp | startswith("sha256:")')" "true"

# Placement is never selected, persisted or assumed reusable.
assert_eq "no placement is selected by readiness" \
  "$(jget '.readiness.ROUTE_READY.placement_selected')" "false"
assert_eq "placement is reported as out of scope" \
  "$(jget '.live_facts.route_placement.state')" "OUT_OF_SCOPE"
assert_eq "with the ownership reason" \
  "$(jget '.live_facts.route_placement.reason')" "PLACEMENT_NOT_A_LIFECYCLE_CONCERN"
assert_eq "and the observation claims no launch authority" \
  "$(jget '.readiness.ROUTE_READY.launch_authoritative')" "false"

# A host that has never dispatched a worker says so, and it costs nothing.
assert_eq "the dispatch watch is not available on a fresh host" \
  "$(jget '.dispatch_monitor.state')" "NOT_AVAILABLE"
assert_eq "with a stable reason" \
  "$(jget '.dispatch_monitor.reason')" "DISPATCH_WATCH_NOT_AVAILABLE"
assert_eq "and reading it never makes the command fail" "$(jget '.overall.state')" "READY"

# --- deterministic refusals, table driven --------------------------------
refuse_case() { # <name> <expected reason> <write_stamp args...>
  local name="$1" want="$2"; shift 2
  write_stamp "$STAMP" "$@"
  run_afk status --json --stamp "$STAMP"
  assert_eq "route refusal '$name' is FALSE" "$(jget '.readiness.ROUTE_READY.state')" "FALSE"
  assert_eq "route refusal '$name' says why" "$(jget '.readiness.ROUTE_READY.reason')" "$want"
  assert_eq "route refusal '$name' exits 3"  "$RUN_RC" "3"
}

refuse_case "expired stamp" STAMP_EXPIRED claude claude/strong high 2000-01-01T00:00:00Z
refuse_case "effort outside the closed set" ROUTE_PROFILE_UNSUPPORTED claude claude/strong banana
refuse_case "placement-required profile" ROUTE_PROFILE_UNSUPPORTED \
  claude local-code-standard high 2099-01-01T00:00:00Z true
refuse_case "unknown harness" ROUTE_PROFILE_UNSUPPORTED banana claude/strong high

printf 'not json at all\n' > "$STAMP"
run_afk status --json --stamp "$STAMP"
assert_eq "an unreadable stamp is refused" "$(jget '.readiness.ROUTE_READY.reason')" "STAMP_UNREADABLE"
jq -n '{harness:"claude"}' > "$STAMP"
run_afk status --json --stamp "$STAMP"
assert_eq "a stamp outside the closed shape is refused" \
  "$(jget '.readiness.ROUTE_READY.reason')" "STAMP_SHAPE_INVALID"

# The route is never substituted, and the decision on disk is never touched.
write_stamp "$STAMP" claude local-code-standard high 2099-01-01T00:00:00Z true
STAMP_BEFORE="$(jq -S -c . "$STAMP")"
run_afk status --json --stamp "$STAMP"
assert_absent "a refused route never suggests a substitute" "$RUN_OUT" "falling back"
assert_eq "and the accepted decision on disk is byte-identical afterwards" \
  "$(jq -S -c . "$STAMP")" "$STAMP_BEFORE"

# --- funding conflicts block only the affected route ---------------------
new_scenario funding
STAMP="$SC/story.stamp.json"
write_stamp "$STAMP" claude claude/strong high
ENV_ANTHROPIC_API_KEY="$SENTINEL"
run_afk status --json --stamp "$STAMP"
assert_eq "a metered-path condition blocks the affected route" \
  "$(jget '.readiness.ROUTE_READY.reason')" "ROUTE_FUNDING_CONFLICT"
assert_eq "and only the route scope" \
  "$(finding_field ROUTE_FUNDING_CONFLICT 'select(.blocked_scopes != ["ROUTE_READY"])')" "0"
assert_eq "installed integrity is untouched by it" \
  "$(jget '.readiness.INSTALLED_INTEGRITY.state')" "READY"
assert_absent "and no credential value is emitted anywhere" "$RUN_OUT" "$SENTINEL"
assert_eq "the conflicting variable is reported by name" \
  "$(finding_field ROUTE_FUNDING_CONFLICT 'select(.evidence.observed | test("ANTHROPIC_API_KEY"))')" "1"

# The same host, the same credential, an explicitly metered route: allowed.
write_stamp "$STAMP" claude claude/strong high 2099-01-01T00:00:00Z false metered true
run_afk status --json --stamp "$STAMP"
assert_ne "credential shape alone never forbids an API-backed entitlement" \
  "$(jget '.readiness.ROUTE_READY.reason')" "ROUTE_FUNDING_CONFLICT"
stub_reset

# ===========================================================================
head1 "2. Live host readiness, and its independence from the router"
# ===========================================================================

new_scenario liveok
run_afk status --json --live
assert_eq "a complete host proves execution readiness" \
  "$(jget '.readiness.HOST_EXECUTION_READY.state')" "TRUE"
assert_eq "with a stable reason" \
  "$(jget '.readiness.HOST_EXECUTION_READY.reason')" "HOST_EXECUTION_READY_PROVEN"
assert_eq "Orca answered a read-only probe" "$(jget '.live_facts.orca_runtime.state')" "AVAILABLE"
assert_eq "and declared every required capability" \
  "$(jget '.live_facts.orca_capability.reason')" "ORCA_CAPABILITY_PROVEN"
assert_eq "the validator fixtures proved it is not always-success" \
  "$(jget '.live_facts.validator_fixtures.reason')" "VALIDATOR_FIXTURES_PROVEN"
assert_eq "the router answered too" "$(jget '.live_facts.router_status.state')" "AVAILABLE"
assert_eq "so new work is ready as well" "$(jget '.readiness.NEW_WORK_READY.state')" "TRUE"
assert_eq "a live observation is timestamped" \
  "$(jget '.live_facts.orca_runtime.observed_at | test("^[0-9]{4}-")')" "true"
assert_eq "carries its bound" "$(jget '.live_facts.orca_runtime.timeout_ms != null')" "true"
assert_eq "declares its freshness window" \
  "$(jget '.live_facts.orca_runtime.freshness_seconds != null')" "true"
assert_eq "and is never launch authority" \
  "$(jget '.live_facts.orca_runtime.launch_authoritative')" "false"

# A transient live observation is never persisted as installed-state truth.
assert_eq "the applied-state manifest carries no readiness or live section" \
  "$(jq -r 'has("live_facts") or has("readiness") or has("orchestration") or has("dispatch_monitor")' \
     "$HOMEDIR/$STATE_DIR_REL/state.json")" "false"
assert_eq "and no observation timestamp reached it" \
  "$(jq -r '[paths(type == "string") as $p | getpath($p)
     | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))] | length' \
     "$HOMEDIR/$STATE_DIR_REL/state.json")" "0"

# --- the router goes away; the host does not -----------------------------
STUB_ROUTER=down
run_afk status --json --live
assert_eq "an unreachable router leaves the host execution ready" \
  "$(jget '.readiness.HOST_EXECUTION_READY.state')" "TRUE"
assert_eq "while new-work readiness becomes false" \
  "$(jget '.readiness.NEW_WORK_READY.state')" "FALSE"
assert_eq "with the transient reason" \
  "$(jget '.readiness.NEW_WORK_READY.reason')" "ROUTER_UNREACHABLE"
assert_eq "the router fact is marked transient" \
  "$(jget '.live_facts.router_status.transient')" "true"
assert_eq "installed state is NOT made BROKEN by an outage" \
  "$(jget '.installed.state')" "CURRENT"
assert_eq "installed integrity stays READY" \
  "$(jget '.readiness.INSTALLED_INTEGRITY.state')" "READY"
assert_eq "a live outage exits 5, distinctly from a deterministic 3" "$RUN_RC" "5"
assert_eq "and no route is invented in the router's place" \
  "$(jget '.readiness.ROUTE_READY.state')" "OUT_OF_SCOPE"

STUB_ROUTER=http500
run_afk status --json --live
assert_eq "a non-200 router is unavailable, not incompatible" \
  "$(jget '.live_facts.router_status.reason')" "ROUTER_UNREACHABLE"
assert_eq "and the host is still ready" \
  "$(jget '.readiness.HOST_EXECUTION_READY.state')" "TRUE"

STUB_ROUTER=badshape
run_afk status --json --live
assert_eq "a 200 from something that is not the router is incompatible" \
  "$(jget '.live_facts.router_status.reason')" "ROUTER_API_SHAPE_UNSUPPORTED"
assert_eq "which still narrows new work only" \
  "$(jget '.readiness.HOST_EXECUTION_READY.state')" "TRUE"
stub_reset

if command -v timeout >/dev/null 2>&1; then
  STUB_ROUTER=slow
  LIVE_TIMEOUT_MS=1000
  run_afk status --json --live
  assert_eq "a router that does not answer in time reports a timeout" \
    "$(jget '.live_facts.router_status.reason')" "ROUTER_TIMED_OUT"
  assert_eq "distinctly from a deterministic failure" \
    "$(jget '.live_facts.router_status.transient')" "true"
  assert_eq "and the host stays ready through it" \
    "$(jget '.readiness.HOST_EXECUTION_READY.state')" "TRUE"
  stub_reset
else
  skip "router timeout (no timeout(1) on this host to bound a probe with)"
fi

# --- transport and authentication are preconditions ----------------------
ROUTER_URL="http://router.invalid"
ROUTER_TOKEN="$SENTINEL"
run_afk status --json --live
assert_eq "a plaintext router endpoint is refused" \
  "$(jget '.live_facts.router_status.reason')" "ROUTER_TRANSPORT_UNTRUSTED"
assert_absent "and the caller token never reaches the output" "$RUN_OUT" "$SENTINEL"
stub_reset

ROUTER_TOKEN=""
run_afk status --json --live
assert_eq "an unpopulated caller token is an owner action" \
  "$(jget '.live_facts.router_status.reason')" "ROUTER_AUTH_MISSING"
stub_reset

# ===========================================================================
head1 "3. Harnesses are individually optional; a route never substitutes"
# ===========================================================================

new_scenario harness
STAMP="$SC/story.stamp.json"
write_stamp "$STAMP" claude claude/strong high

# Codex absent, Claude healthy: the host is still execution ready.
CODEX_BIN_OVERRIDE="codex-not-installed"
run_afk status --json --live
assert_eq "one unavailable harness does not block host readiness" \
  "$(jget '.readiness.HOST_EXECUTION_READY.state')" "TRUE"
assert_eq "and the unavailable harness is reported independently" \
  "$(jget '.live_facts.codex_capability.reason')" "HARNESS_NOT_RESOLVED"
assert_eq "scoped to nothing global" \
  "$(finding_field HARNESS_NOT_RESOLVED 'select(.blocked_scopes | length > 0)')" "0"

# A route that selects the unavailable harness IS blocked, and nothing else is.
write_stamp "$STAMP" codex openai/strong high
run_afk status --json --live --stamp "$STAMP"
assert_eq "a route selecting an unavailable harness is not ready" \
  "$(jget '.readiness.ROUTE_READY.state')" "FALSE"
assert_eq "with a stable reason" \
  "$(jget '.readiness.ROUTE_READY.reason')" "ROUTE_HARNESS_UNAVAILABLE"
assert_eq "while the host stays ready through the other approved path" \
  "$(jget '.readiness.HOST_EXECUTION_READY.state')" "TRUE"
stub_reset

# Neither harness usable: no complete approved path, and the host says so.
CLAUDE_BIN_OVERRIDE="claude-not-installed"
CODEX_BIN_OVERRIDE="codex-not-installed"
run_afk status --json --live
assert_eq "no usable harness means no host execution readiness" \
  "$(jget '.readiness.HOST_EXECUTION_READY.state')" "FALSE"
assert_eq "with a stable reason" \
  "$(jget '.readiness.HOST_EXECUTION_READY.reason')" "NO_APPROVED_HARNESS_PATH"
assert_eq "and installation integrity is still reported independently" \
  "$(jget '.readiness.INSTALLED_INTEGRITY.state')" "READY"
assert_eq "status and offline verification stay usable" \
  "$(jget '.installed.state')" "CURRENT"
stub_reset

# --- native authentication classes ---------------------------------------
new_scenario auth
run_afk status --json --live
assert_eq "a native subscription session is the approved funding class" \
  "$(jget '.live_facts.claude_native_session.reason')" "AUTH_NATIVE_SUBSCRIPTION"

STUB_CLAUDE_AUTH=none
run_afk status --json --live
assert_eq "a stale session reports AUTH_REQUIRED" \
  "$(jget '.live_facts.claude_native_session.reason')" "AUTH_REQUIRED"
assert_eq "as an owner action, never an automatic login" \
  "$(finding_field AUTH_REQUIRED 'select(.severity == "owner_action")')" "1"

STUB_CLAUDE_AUTH=api
run_afk status --json --live
assert_eq "an API-key session is classified, not treated as a subscription" \
  "$(jget '.live_facts.claude_native_session.reason')" "AUTH_MODE_UNSUPPORTED"
assert_eq "and the other harness can still carry the host" \
  "$(jget '.readiness.HOST_EXECUTION_READY.state')" "TRUE"

STUB_CLAUDE_AUTH=weird
run_afk status --json --live
assert_eq "an unclassifiable status is unproven, never assumed good" \
  "$(jget '.live_facts.claude_native_session.reason')" "AUTH_STATUS_UNPROVEN"
stub_reset

STUB_CLAUDE_CAPS=partial
run_afk status --json --live
assert_eq "a harness that cannot prove its invocation contract is not ready" \
  "$(jget '.live_facts.claude_capability.reason')" "HARNESS_CAPABILITY_UNPROVEN"
stub_reset

# ===========================================================================
head1 "4. Orca and the validator gate host readiness, each on its own"
# ===========================================================================

new_scenario orcaval
STUB_ORCA=down
run_afk status --json --live
assert_eq "an unreachable Orca blocks host execution" \
  "$(jget '.readiness.HOST_EXECUTION_READY.state')" "FALSE"
assert_eq "with a stable reason" "$(jget '.live_facts.orca_runtime.reason')" "ORCA_PROBE_FAILED"
assert_eq "while installation integrity remains independently reportable" \
  "$(jget '.readiness.INSTALLED_INTEGRITY.state')" "READY"
assert_eq "and status itself is still usable" "$(jget '.installed.state')" "CURRENT"
stub_reset

STUB_ORCA_CAPS=partial
run_afk status --json --live
assert_eq "an Orca missing a required launch capability is incompatible" \
  "$(jget '.live_facts.orca_capability.reason')" "ORCA_CAPABILITY_INCOMPATIBLE"
assert_eq "which blocks host execution readiness" \
  "$(jget '.readiness.HOST_EXECUTION_READY.state')" "FALSE"

STUB_ORCA_CAPS=none
run_afk status --json --live
assert_eq "an Orca with no capability contract cannot be proven" \
  "$(jget '.live_facts.orca_capability.reason')" "ORCA_CAPABILITY_UNPROVEN"
stub_reset

# --- the anti-vacuity control --------------------------------------------
STUB_VALIDATOR=always-valid
run_afk status --json --live
assert_eq "an always-success validator fails the anti-vacuity check" \
  "$(jget '.live_facts.validator_fixtures.reason')" "VALIDATOR_ANTI_VACUITY_FAILED"
assert_eq "and blocks host execution readiness" \
  "$(jget '.readiness.HOST_EXECUTION_READY.state')" "FALSE"
assert_eq "as a blocking finding" \
  "$(finding_field VALIDATOR_ANTI_VACUITY_FAILED 'select(.severity == "blocking")')" "1"

STUB_VALIDATOR=reject-all
run_afk status --json --live
assert_eq "a validator that rejects the known-valid fixture is unusable" \
  "$(jget '.live_facts.validator_fixtures.reason')" "VALIDATOR_FIXTURE_FAILED"
assert_eq "which is a deterministic refusal, not a transient one" \
  "$(jget '.live_facts.validator_fixtures.transient')" "false"

STUB_VALIDATOR=future
run_afk status --json --live
assert_eq "a validator declaring a newer contract major is incompatible" \
  "$(jget '.live_facts.validator_contract.reason')" "VALIDATOR_CONTRACT_INCOMPATIBLE"

STUB_VALIDATOR=nocontract
run_afk status --json --live
assert_eq "no machine-readable contract is a warning, not a block" \
  "$(jget '.live_facts.validator_contract.reason')" "VALIDATOR_CONTRACT_UNREADABLE"
assert_eq "because the fixture suite is the proof that decides" \
  "$(jget '.readiness.HOST_EXECUTION_READY.state')" "TRUE"
stub_reset

# A validator that cannot ANSWER has refused nothing. Only an exit status of
# exactly 1 is its policy verdict; anything else is a dependency that did not
# answer, and the two must not collapse into one state or one exit code.
STUB_VALIDATOR=broken
run_afk status --json --live
assert_eq "a validator that cannot answer is unavailable, not a refusal" \
  "$(jget '.live_facts.validator_fixtures.reason')" "VALIDATOR_VERDICT_UNAVAILABLE"
assert_eq "and the observation is marked transient" \
  "$(jget '.live_facts.validator_fixtures.transient')" "true"
assert_eq "it still blocks host execution readiness" \
  "$(jget '.readiness.HOST_EXECUTION_READY.state')" "FALSE"
assert_eq "and the run exits 5, not the deterministic 3" "$RUN_RC" "5"
stub_reset

# A live evaluation materializes its fixtures outside the host and cleans up.
FP_BEFORE="$(find "$HOMEDIR" | LC_ALL=C sort)"
run_afk status --json --live
assert_eq "a live evaluation writes nothing into HOME" \
  "$(find "$HOMEDIR" | LC_ALL=C sort)" "$FP_BEFORE"

# ===========================================================================
head1 "5. Live route readiness is an intersection, and expires with the stamp"
# ===========================================================================

new_scenario liveroute
STAMP="$SC/story.stamp.json"
write_stamp "$STAMP"

run_afk status --json --live --stamp "$STAMP"
assert_eq "every authority answered, so the route is semantically ready" \
  "$(jget '.readiness.ROUTE_READY.state')" "TRUE"
assert_eq "with a stable reason" \
  "$(jget '.readiness.ROUTE_READY.reason')" "ROUTE_READY_PROVEN"
assert_eq "and it still authorizes no launch" \
  "$(jget '.readiness.ROUTE_READY.launch_authoritative')" "false"
assert_eq "no placement was selected on the way" \
  "$(jget '.readiness.ROUTE_READY.placement_selected')" "false"
assert_eq "the observation is explicitly diagnostic only" \
  "$(jget '.live_facts.route_authority.reason')" "LIVE_OBSERVATION_NOT_LAUNCH_AUTHORITY"
assert_eq "a ready route exits 0" "$RUN_RC" "0"

# An accepted, unexpired stamp survives a router outage, on the validator's word.
STUB_ROUTER=down
run_afk status --json --live --stamp "$STAMP"
assert_eq "route readiness continues through a router outage" \
  "$(jget '.readiness.ROUTE_READY.state')" "TRUE"
assert_eq "while new work stops" "$(jget '.readiness.NEW_WORK_READY.state')" "FALSE"
stub_reset

# The validator's refusal is final, and is never overridden here.
STUB_VALIDATOR=reject-all
run_afk status --json --live --stamp "$STAMP"
assert_eq "a validator refusal blocks the route" \
  "$(jget '.readiness.ROUTE_READY.state')" "FALSE"
assert_ne "and readiness never overrides it" \
  "$(jget '.readiness.ROUTE_READY.reason')" "ROUTE_READY_PROVEN"
stub_reset

STUB_VALIDATOR=broken
run_afk status --json --live --stamp "$STAMP"
assert_eq "a validator that cannot answer leaves the route unproven" \
  "$(jget '.readiness.ROUTE_READY.reason')" "STAMP_VALIDATION_UNPROVEN"
assert_eq "and an uncheckable live dependency exits 5" "$RUN_RC" "5"
stub_reset

# --- target scoping of a route --------------------------------------------
new_scenario routetarget
STAMP="$SC/story.stamp.json"
write_stamp "$STAMP"
rm -f "$TARGET/_bmad/bmm/agents/pm.md"
run_afk status --json --live --stamp "$STAMP"
assert_eq "a route whose target does not resolve is blocked" \
  "$(jget '.readiness.ROUTE_READY.reason')" "ROUTE_TARGET_UNRESOLVED"
assert_eq "the target itself says why" \
  "$(jget '.targets[] | select(.id == "target-a") | .reason')" "TARGET_PERSONA_UNRESOLVED"
assert_eq "and the host is not poisoned by one target" \
  "$(jget '.readiness.HOST_EXECUTION_READY.state')" "TRUE"
assert_eq "the target aggregate is FALSE over the registered set" \
  "$(jget '.readiness.TARGET_READY.state')" "FALSE"

# --- workspace trust is a human decision ----------------------------------
new_scenario trust
STAMP="$SC/story.stamp.json"
write_stamp "$STAMP"
jq -n --arg p "$TARGET" '{projects: {($p): {hasTrustDialogAccepted: false}}}' \
  > "$HOMEDIR/.claude.json"
TRUST_BEFORE="$(jq -S -c . "$HOMEDIR/.claude.json")"
run_afk status --json --live --stamp "$STAMP"
assert_eq "a path awaiting workspace trust blocks the route" \
  "$(jget '.readiness.ROUTE_READY.reason')" "WORKSPACE_TRUST_REQUIRED"
assert_eq "loudly, as an owner action" \
  "$(finding_field WORKSPACE_TRUST_REQUIRED 'select(.severity == "owner_action")')" "1"
assert_eq "which exits 2, not a not-ready 3" "$RUN_RC" "2"
assert_eq "and the trust record was read, never edited" \
  "$(jq -S -c . "$HOMEDIR/.claude.json")" "$TRUST_BEFORE"

jq --arg p "$TARGET" '.projects[$p].hasTrustDialogAccepted = true' "$HOMEDIR/.claude.json" \
  > "$HOMEDIR/.claude.json.new" && mv "$HOMEDIR/.claude.json.new" "$HOMEDIR/.claude.json"
run_afk status --json --live --stamp "$STAMP"
assert_eq "an accepted trust decision unblocks the route" \
  "$(jget '.readiness.ROUTE_READY.state')" "TRUE"

# --- the target binding is an OPERAND of the intersection ------------------
#
# Six runs over one fixture host, varying only the registered-target arity and
# whether the bound target is wired. A route is the intersection of every
# authority, and an operand that cannot be determined has to fail the route
# CLOSED: an intersection that silently drops one of its legs reports a route
# as launchable with that leg never evaluated, and takes the workspace-trust
# decision — a protected human decision — out with it.
#
# Registered-target arity is ordinary configuration. `--target` is optional by
# design, one target is used without being named, and two targets are exactly
# the multi-repository host the contract already describes.
new_scenario targetarity
STAMP="$SC/story.stamp.json"
write_stamp "$STAMP"
TARGET_B="$SC/target-b"          # registered, wired for nothing at all
mkdir -p "$TARGET_B"
T_WIRED="$(jq -nc --arg p "$TARGET" '[{id: "target-a", path: $p}]')"
T_UNWIRED="$(jq -nc --arg p "$TARGET_B" '[{id: "target-b", path: $p}]')"
T_BOTH="$(jq -nc --arg a "$TARGET" --arg b "$TARGET_B" \
          '[{id: "target-a", path: $a}, {id: "target-b", path: $b}]')"

# 1. control: exactly one wired target, used without being named.
set_targets "$T_WIRED"
run_afk status --json --live --stamp "$STAMP"
assert_eq "one wired target: the route is ready" \
  "$(jget '.readiness.ROUTE_READY.state')" "TRUE"
assert_eq "and the run is a success" "$RUN_RC" "0"

# 2. control: the same unwired target really does block the route on its own,
#    so its disappearance in case 3 is a difference in the product.
set_targets "$T_UNWIRED"
run_afk status --json --live --stamp "$STAMP"
assert_eq "one unwired target: the route is blocked" \
  "$(jget '.readiness.ROUTE_READY.state')" "FALSE"
assert_eq "with the target reason" \
  "$(jget '.readiness.ROUTE_READY.reason')" "ROUTE_TARGET_UNRESOLVED"
assert_eq "and a deterministic not-ready exit" "$RUN_RC" "3"

# 3. the wired target AND the unwired one, no --target: the binding is
#    ambiguous, and ambiguity is refused rather than guessed at.
set_targets "$T_BOTH"
run_afk status --json --live --stamp "$STAMP"
assert_eq "an ambiguous target binding never reports the route ready" \
  "$(jget '.readiness.ROUTE_READY.state')" "FALSE"
assert_eq "with the target reason" \
  "$(jget '.readiness.ROUTE_READY.reason')" "ROUTE_TARGET_UNRESOLVED"
assert_eq "and a deterministic not-ready exit" "$RUN_RC" "3"
assert_eq "while the per-target verdicts stay independent of each other" \
  "$(jget '.readiness.TARGET_READY.state')" "PARTIAL"

# 4. naming the target is how the ambiguity is resolved — by the operator.
run_afk status --json --live --stamp "$STAMP" --target target-a
assert_eq "naming the wired target binds the route to it" \
  "$(jget '.readiness.ROUTE_READY.state')" "TRUE"
run_afk status --json --live --stamp "$STAMP" --target target-b
assert_eq "and naming the unwired one blocks the route" \
  "$(jget '.readiness.ROUTE_READY.reason')" "ROUTE_TARGET_UNRESOLVED"

# 5. no registered target at all: nowhere to dispatch this route into.
set_targets '[]'
run_afk status --json --live --stamp "$STAMP"
assert_eq "a host with no registered target has no ready route" \
  "$(jget '.readiness.ROUTE_READY.state')" "FALSE"
assert_eq "with the target reason" \
  "$(jget '.readiness.ROUTE_READY.reason')" "ROUTE_TARGET_UNRESOLVED"
assert_eq "and the target scope reports the absence on its own" \
  "$(jget '.readiness.TARGET_READY.reason')" "NO_TARGET_REGISTERED"

# 6. the workspace-trust decision does not vanish with the binding. The trust
#    prompt is withheld for the wired target; registering a second target must
#    not turn that owner action into a launchable route.
jq -n --arg p "$TARGET" '{projects: {($p): {hasTrustDialogAccepted: false}}}' \
  > "$HOMEDIR/.claude.json"
set_targets "$T_WIRED"
run_afk status --json --live --stamp "$STAMP"
assert_eq "trust withheld at arity one blocks the route" \
  "$(jget '.readiness.ROUTE_READY.reason')" "WORKSPACE_TRUST_REQUIRED"
assert_eq "as an owner action" "$RUN_RC" "2"
set_targets "$T_BOTH"
run_afk status --json --live --stamp "$STAMP"
assert_eq "registering a second target does not make it launchable" \
  "$(jget '.readiness.ROUTE_READY.state')" "FALSE"
assert_ne "and the run is not reported as a success" "$RUN_RC" "0"
assert_eq "no route in this state is ever proven ready" \
  "$(jget '[.readiness.ROUTE_READY] | map(select(.reason == "ROUTE_READY_PROVEN")) | length')" "0"
# And the trust fact says which sentence is true rather than keeping the seed
# that means "nobody asked": a route with no determinable workspace has no
# per-directory trust decision to report, and says exactly that.
assert_eq "an undeterminable workspace is named, not left unprobed" \
  "$(jget '.live_facts.claude_workspace_trust.reason')" "NO_SELECTED_WORKSPACE"
rm -f "$HOMEDIR/.claude.json"

# ===========================================================================
head1 "6. The orchestration bridge is consumed, never owned"
# ===========================================================================

new_scenario orch
ORCH="$HOMEDIR/$STATE_DIR_REL/orchestration.json"

run_afk status --json
assert_eq "no orchestration state reports not available" \
  "$(jget '.orchestration.state')" "NOT_AVAILABLE"
assert_eq "with a stable reason" \
  "$(jget '.orchestration.reason')" "ORCHESTRATION_STATE_NOT_AVAILABLE"
assert_eq "and it never makes ordinary readiness fail" "$(jget '.overall.state')" "READY"
assert_eq "nor the command"                            "$RUN_RC" "0"

jq -n '{schema_version: "1.0",
        session: {state: "INACTIVE", mode: "PLAN", phase: null, task: null, needs_human: false},
        parent: {role: "PM", id: "sess-1"},
        workers: {available: 0, by_state: {}}}' > "$ORCH"
run_afk status --json
assert_eq "an inactive session is reported as inactive" "$(jget '.orchestration.state')" "INACTIVE"
assert_eq "with its own reason" \
  "$(jget '.orchestration.reason')" "ORCHESTRATION_SESSION_INACTIVE"
assert_eq "and still does not fail readiness" "$RUN_RC" "0"

jq -n '{schema_version: "1.0",
        session: {state: "ACTIVE", mode: "ORCH", phase: "implementation",
                  task: "AFK-PORT-1.3", needs_human: false},
        parent: {role: "COORDINATOR", id: "sess-9"},
        workers: {available: 2, by_state: {WORKING: 1, BLOCKED: 1}}}' > "$ORCH"
ORCH_BEFORE="$(jq -S -c . "$ORCH")"
run_afk status --json
assert_eq "an active session is summarized" "$(jget '.orchestration.state')" "ACTIVE"
assert_eq "with its mode"    "$(jget '.orchestration.session.mode')" "ORCH"
assert_eq "its phase"        "$(jget '.orchestration.session.phase')" "implementation"
assert_eq "its task"         "$(jget '.orchestration.session.task')" "AFK-PORT-1.3"
assert_eq "already-available worker counts" "$(jget '.orchestration.workers.available')" "2"
assert_eq "and per-state counts"            "$(jget '.orchestration.workers.by_state.WORKING')" "1"
# Parent identity is generic: nothing here is hard-coded to parent = PM.
assert_eq "the parent role is carried through as declared, not assumed" \
  "$(jget '.orchestration.parent.role')" "COORDINATOR"
assert_eq "and the parent identity with it" "$(jget '.orchestration.parent.id')" "sess-9"
assert_eq "the state document is consumed, never rewritten" \
  "$(jq -S -c . "$ORCH")" "$ORCH_BEFORE"

jq '.session.needs_human = true' "$ORCH" > "$ORCH.new" && mv "$ORCH.new" "$ORCH"
run_afk status --json
assert_eq "a pending human decision is surfaced loudly" \
  "$(has_finding_reason ORCHESTRATION_NEEDS_HUMAN)" "1"
assert_eq "as an owner action" \
  "$(finding_field ORCHESTRATION_NEEDS_HUMAN 'select(.severity == "owner_action")')" "1"
assert_eq "but scoped to nothing, so lifecycle readiness does not fail for it" \
  "$(finding_field ORCHESTRATION_NEEDS_HUMAN 'select(.blocked_scopes | length > 0)')" "0"
assert_eq "and installed integrity is unaffected" \
  "$(jget '.readiness.INSTALLED_INTEGRITY.state')" "READY"
assert_eq "which is still a successful command" "$RUN_RC" "0"

printf 'not json\n' > "$ORCH"
run_afk status --json
assert_eq "an unreadable state document is reported, not guessed at" \
  "$(jget '.orchestration.reason')" "ORCHESTRATION_STATE_UNREADABLE"
assert_eq "and does not fail readiness" "$RUN_RC" "0"

jq -n '{schema_version: "9.0", session: {state: "ACTIVE"}}' > "$ORCH"
run_afk status --json
assert_eq "a newer major state schema is refused, not interpreted" \
  "$(jget '.orchestration.reason')" "ORCHESTRATION_STATE_SCHEMA_UNSUPPORTED"

# Nothing in the document is passed through beyond the declared members.
jq -n --arg s "$SENTINEL" '{schema_version: "1.0", secret_field: $s,
        session: {state: "ACTIVE", mode: "ORCH", extra: $s},
        parent: {role: "PM"}, workers: {available: 1, by_state: {}}}' > "$ORCH"
run_afk status --json
assert_absent "an undeclared member of the state document is never passed through" \
  "$RUN_OUT" "$SENTINEL"
assert_eq "while the declared members still are" "$(jget '.orchestration.session.mode')" "ORCH"

# ===========================================================================
head1 "7. Live output stays safe, stable and completely projected"
# ===========================================================================

new_scenario liveparity
STAMP="$SC/story.stamp.json"
write_stamp "$STAMP"
jq -n '{schema_version: "1.0",
        session: {state: "ACTIVE", mode: "WORKER", phase: "gates", task: "T-1",
                  needs_human: false},
        parent: {role: "COORDINATOR", id: "sess-2"},
        workers: {available: 1, by_state: {WORKING: 1}}}' \
  > "$HOMEDIR/$STATE_DIR_REL/orchestration.json"

ENV_ANTHROPIC_API_KEY="$SENTINEL"
ENV_OP_TOKEN="$SENTINEL"
ROUTER_TOKEN="$SENTINEL"
run_afk status --json --live --stamp "$STAMP"
LIVE_JSON="$RUN_OUT"; LIVE_ERR="$RUN_ERR"
run_afk status --live --stamp "$STAMP"
LIVE_HUMAN="$RUN_OUT"
stub_reset

assert_absent "no secret reaches live machine output" "$LIVE_JSON" "$SENTINEL"
assert_absent "nor live human output"                 "$LIVE_HUMAN" "$SENTINEL"
assert_absent "nor stderr on a live run"              "$LIVE_ERR" "$SENTINEL"

MISSING=""
while IFS= read -r needle; do
  [[ -n "$needle" ]] || continue
  if [[ "$LIVE_HUMAN" != *"$needle"* ]]; then MISSING="${MISSING}[$needle] "; fi
done < <(printf '%s' "$LIVE_JSON" | jq -r '
  [ .readiness | to_entries[] | .key, .value.state, (.value.reason // empty) ]
  + [ .live_facts | to_entries[] | .key, .value.state, .value.reason ]
  + [ .orchestration | .state, .reason ]
  + [ .orchestration.session | .mode, .phase, .task ]
  + [ .orchestration.parent | .role, .id ]
  + [ .dispatch_monitor | .state, .reason ]
  + [ .findings[] | .reason, .message, .required_action ]
  | map(select(. != null and . != "")) | .[]')
assert_eq "live human output projects every readiness, live and orchestration fact" \
  "$MISSING" ""

# Every reason and every state emitted on a live path is inside the published
# vocabulary, so automation never meets a code the contract does not name.
#
# Each sweep binds the value it is testing to a jq VARIABLE before it reaches
# index(). jq evaluates the ARGUMENT of index() against the INPUT of index() —
# the published array — so `$pub | index(.reason)` asks the array for one of
# its own fields. That is an error where the value is an object and vacuously
# true where it is not, which is exactly how a sweep stops guarding anything.
# Every sweep is therefore followed by its own falsifiability control: the same
# expression, run over a copy of the document with one out-of-set value
# injected, must report it.
run_afk schema
SCHEMA_JSON="$RUN_OUT"
PUB_REASONS="$(printf '%s' "$SCHEMA_JSON" | jq -c '.reason_codes')"
PUB_READINESS="$(printf '%s' "$SCHEMA_JSON" | jq -c '.readiness_states')"
PUB_LIVE="$(printf '%s' "$SCHEMA_JSON" | jq -c '.live_fact_states')"
PUB_TARGET="$(printf '%s' "$SCHEMA_JSON" | jq -c '.target_states')"

unpublished_reasons() { # <document> -> how many reason strings are outside the set
  printf '%s' "$1" | jq -r --argjson pub "$PUB_REASONS" \
    '[.. | objects | .reason? | select(type == "string")
      | . as $r | select(($pub | index($r)) == null)] | length'
}
outside_readiness_states() { # <document>
  printf '%s' "$1" | jq -r --argjson s "$PUB_READINESS" \
    '[.readiness | to_entries[] | select(.key != "INSTALLED_INTEGRITY")
      | .value.state | select(type == "string")
      | . as $st | select(($s | index($st)) == null)] | length'
}
outside_live_fact_states() { # <document>
  printf '%s' "$1" | jq -r --argjson s "$PUB_LIVE" \
    '[.live_facts | to_entries[] | .value.state | select(type == "string")
      | . as $st | select(($s | index($st)) == null)] | length'
}
outside_target_states() { # <document>
  printf '%s' "$1" | jq -r --argjson s "$PUB_TARGET" \
    '[.targets[] | .state | select(type == "string")
      | . as $st | select(($s | index($st)) == null)] | length'
}

assert_eq "every reason code in a live result is published" \
  "$(unpublished_reasons "$LIVE_JSON")" "0"
assert_eq "every readiness state is inside the published set" \
  "$(outside_readiness_states "$LIVE_JSON")" "0"
assert_eq "every live-fact state is inside the published set" \
  "$(outside_live_fact_states "$LIVE_JSON")" "0"
assert_eq "every target state is inside the published set" \
  "$(outside_target_states "$LIVE_JSON")" "0"

assert_eq "the reason sweep still FAILS on an unpublished code" \
  "$(unpublished_reasons "$(printf '%s' "$LIVE_JSON" \
     | jq -c '.readiness.ROUTE_READY.reason = "NOT_A_PUBLISHED_CODE"')")" "1"
assert_eq "the readiness sweep still FAILS on an out-of-set state" \
  "$(outside_readiness_states "$(printf '%s' "$LIVE_JSON" \
     | jq -c '.readiness.ROUTE_READY.state = "BANANA"')")" "1"
assert_eq "the live-fact sweep still FAILS on an out-of-set state" \
  "$(outside_live_fact_states "$(printf '%s' "$LIVE_JSON" \
     | jq -c '.live_facts.orca_runtime.state = "BANANA"')")" "1"
assert_eq "the target sweep still FAILS on an out-of-set state" \
  "$(outside_target_states "$(printf '%s' "$LIVE_JSON" \
     | jq -c '.targets[0].state = "BANANA"')")" "1"

# A default run over unchanged state stays byte-stable now that live mode
# exists: the observation timestamps belong to the live path and nowhere else.
run_afk status --json; D1="$RUN_OUT"
run_afk status --json; D2="$RUN_OUT"
assert_eq "default machine output is still byte-stable" "$D1" "$D2"
assert_eq "and still emits no timestamp" \
  "$(printf '%s' "$D1" | jq -r '[paths(type == "string") as $p | getpath($p)
     | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))] | length')" "0"
assert_ne "while a live run does timestamp its observations" \
  "$(printf '%s' "$LIVE_JSON" | jq -r '[paths(type == "string") as $p | getpath($p)
     | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))] | length')" "0"

# ===========================================================================
if (( SKIPPED > 0 )); then
  printf '\n\033[33mskipped checks computed no verdict — they are not passes\033[0m\n'
  printf '\033[1m%d passed, %d failed, %d skipped\033[0m\n' "$PASS" "$FAIL" "$SKIPPED"
else
  printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
fi
(( FAIL == 0 )) || exit 1
