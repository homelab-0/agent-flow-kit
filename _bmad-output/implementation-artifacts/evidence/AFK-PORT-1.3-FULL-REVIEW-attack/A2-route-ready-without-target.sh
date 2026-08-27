#!/usr/bin/env bash
# A2 — ROUTE_READY is reported TRUE with the "compatible BMAD target" leg of the
# frozen intersection never evaluated, whenever the number of registered targets
# is anything other than exactly one and no --target was supplied. The same
# defect silently removes the Claude workspace-trust decision from the route.
#
# Frozen text under attack:
#   AFK-PORT-1.3.md acceptance criteria:
#     "Then usable execution equals router-approved profile n kit-supported
#      launch contract n host capabilities n compatible BMAD target n valid
#      final stamp"
#   AFK-PORT-1.3.md, "Observed Host Bootstrap / Autonomy Concern":
#     "Story 1.3 must detect and report a selected Claude path that is awaiting
#      workspace trust as an affected-harness/route readiness condition with
#      loud NEEDS_HUMAN; it must not claim the route launchable"
#   docs/LIFECYCLE-CONTRACT.md, route-readiness table:
#     "The target BMAD wiring the route needs | the target repository |
#      ROUTE_TARGET_UNRESOLVED"
#
# Code under attack: lib/afk-readiness.sh:1598-1632
#     target_id="$AFK_ROUTE_TARGET"
#     if [[ -z "$target_id" ]]; then
#       target_id="$(... 'if length == 1 then .[0].id else "" end')"
#     fi
#     if [[ -n "$target_id" ]]; then ...check... fi     # <- no else branch
# With 0 or >=2 registered targets and no --target, target_id is empty, the
# whole target check is skipped, tpath stays empty, and the workspace-trust
# evaluation guarded on it never runs. Nothing refuses the ambiguity.
#
# Only tests/lifecycle-tests.sh:1845 mentions --target, and only as a usage
# refusal; every route scenario in tests/lifecycle-readiness-tests.sh registers
# exactly one target, which is the one arity that hides this.

set -uo pipefail

KIT_ROOT="${AFK_ATTACK_KIT_ROOT:-$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../../../.." && pwd -P)}"
AFK="$KIT_ROOT/bin/agent-flow-kit"
if [[ ! -f "$AFK" ]]; then
  printf 'A2: %s not found — set AFK_ATTACK_KIT_ROOT\n' "$AFK" >&2
  exit 2
fi

TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT
export GIT_AUTHOR_NAME="afk-attack" GIT_AUTHOR_EMAIL="afk@attack.invalid"
export GIT_COMMITTER_NAME="afk-attack" GIT_COMMITTER_EMAIL="afk@attack.invalid"

say()  { printf '  %s\n' "$*"; }
head1(){ printf '\n== %s\n' "$*"; }
VERDICT=0
fails() { printf '\n  >>> %s\n' "$*"; VERDICT=1; }

git_commit_all() { git -C "$1" add -A >/dev/null 2>&1
                   git -C "$1" -c commit.gpgsign=false commit -q --no-verify -m "$2" >/dev/null 2>&1; }

# --- fixture, mirroring tests/lifecycle-readiness-tests.sh ------------------
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

TMPL_REL="_bmad/bmm/workflows/4-implementation/create-story/template.md"
make_target() { # a target repository wired for agent-flow-kit
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

BIN="$TMPROOT/bin"; mkdir -p "$BIN"

cat > "$BIN/orca" <<'STUB'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "status --json")       printf '{"ok":true}\n' ;;
  "capabilities --json") printf '{"capabilities":["worktree-ownership","visible-worker-launch","argument-environment-transport","provider-runtime","session-process-isolation"]}\n' ;;
  *) exit 1 ;;
esac
STUB

cat > "$BIN/agent-stamp-validate" <<'STUB'
#!/usr/bin/env bash
contract=false; stamp=""
while (( $# )); do
  case "$1" in
    --contract) contract=true; shift ;;
    --stamp)    stamp="${2:-}"; shift 2 ;;
    --catalog)  shift 2 ;;
    *)          shift ;;
  esac
done
if $contract; then printf '{"identity":"stub","stamp_schema_version":"1.0"}\n'; exit 0; fi
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
  printf 'usage\n--model\n--effort\n--permission-mode\n--append-system-prompt-file\n--strict-mcp-config\n'
  exit 0
fi
if [[ "${1:-} ${2:-}" == "auth status" ]]; then
  printf 'authMethod: claude.ai\napiProvider: firstParty\n'; exit 0
fi
exit 1
STUB

cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--help" ]]; then printf 'usage\nexec\n--sandbox\n--config\n'; exit 0; fi
if [[ "${1:-} ${2:-}" == "login status" ]]; then printf 'Logged in using ChatGPT\n'; exit 0; fi
exit 1
STUB

cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
wants_code=false
for a in "$@"; do if [[ "$a" == '%{http_code}' ]]; then wants_code=true; fi; done
if $wants_code; then printf '200'; exit 0; fi
printf '{"catalog_version":"sha256:abc"}'
STUB
chmod +x "$BIN"/*

CHECKOUT="$TMPROOT/checkout"; HOMEDIR="$TMPROOT/home"
TARGET_A="$TMPROOT/target-a"; TARGET_B="$TMPROOT/target-b"
STATE_DIR="$HOMEDIR/.local/state/agent-flow-kit"
mkdir -p "$HOMEDIR" "$CHECKOUT"
make_checkout "$CHECKOUT"
install_kit "$HOMEDIR" "$CHECKOUT"
make_target "$TARGET_A"          # wired
mkdir -p "$TARGET_B"             # a registered directory with no wiring at all

RUN_OUT=""; RUN_RC=0
run_afk() {
  RUN_OUT="$(env PATH="$BIN:$PATH" HOME="$HOMEDIR" \
             XDG_STATE_HOME="$HOMEDIR/.local/state" \
             AFK_KIT_ROOT="$CHECKOUT" \
             AGENT_ROUTER_URL="https://router.invalid" \
             AGENT_ROUTER_TOKEN="stub-token" \
             ANTHROPIC_API_KEY="" ANTHROPIC_AUTH_TOKEN="" ANTHROPIC_BASE_URL="" \
             CLAUDE_CONFIG_DIR="" OPENAI_API_KEY="" OPENAI_BASE_URL="" CODEX_API_KEY="" \
             bash "$AFK" "$@" </dev/null 2>"$TMPROOT/stderr")"
  RUN_RC=$?
}
jget() { printf '%s' "$RUN_OUT" | jq -r "$1"; }

# The manifest is written once from a real status result, then only its
# `targets` array is rewritten between cases: every other input is byte-identical
# across all six runs, so the registered-target ARITY is the only variable.
run_afk status --json
mkdir -p "$STATE_DIR"
printf '%s' "$RUN_OUT" | jq '{
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
    targets: []
  }' > "$STATE_DIR/state.json"

set_targets() { # <targets json array>
  jq --argjson t "$1" '.targets = $t' "$STATE_DIR/state.json" > "$STATE_DIR/state.json.new" \
    && mv "$STATE_DIR/state.json.new" "$STATE_DIR/state.json"
}
T_A="$(jq -nc --arg p "$TARGET_A" '[{id: "target-a", path: $p}]')"
T_B="$(jq -nc --arg p "$TARGET_B" '[{id: "target-b", path: $p}]')"
T_AB="$(jq -nc --arg a "$TARGET_A" --arg b "$TARGET_B" \
        '[{id: "target-a", path: $a}, {id: "target-b", path: $b}]')"

STAMP="$TMPROOT/story.stamp.json"
jq -n '{harness:"claude", model_profile:"claude/strong", effort:"high",
        cost_class:"subscription", entitlement_pool:"anthropic-max", metered:false,
        placement_policy:"prefer-warm-local", placement_required:false,
        catalog_version:"sha256:abc", expires_at:"2099-01-01T00:00:00Z",
        task:{story_id:"AFK-ATTACK-A2", tags:["docs"]}, override:null}' > "$STAMP"

probe() { # <label>
  run_afk status --json --live --stamp "$STAMP"
  say "$1"
  say "    ROUTE_READY.state        = $(jget '.readiness.ROUTE_READY.state')"
  say "    ROUTE_READY.reason       = $(jget '.readiness.ROUTE_READY.reason')"
  say "    TARGET_READY.state       = $(jget '.readiness.TARGET_READY.state')"
  say "    TARGET_READY.reason      = $(jget '.readiness.TARGET_READY.reason')"
  say "    claude_workspace_trust   = $(jget '.live_facts.claude_workspace_trust.reason')"
  say "    WORKSPACE_TRUST findings = $(jget '[.findings[] | select(.reason == "WORKSPACE_TRUST_REQUIRED")] | length')"
  say "    exit code                = $RUN_RC"
}

# ===========================================================================
head1 "A2 controls — exactly one registered target, which is the only arity tested"
# ===========================================================================
set_targets "$T_A"; probe "one WIRED target (control: the route is genuinely ready)"
[[ "$(jget '.readiness.ROUTE_READY.state')" == "TRUE" ]] \
  || fails "control broken: a fully wired single-target host is not route ready"

set_targets "$T_B"; probe "one UNWIRED target (control: the target leg really is enforced at arity 1)"
CTRL_REASON="$(jget '.readiness.ROUTE_READY.reason')"
CTRL_RC="$RUN_RC"
[[ "$CTRL_REASON" == "ROUTE_TARGET_UNRESOLVED" ]] \
  || fails "control broken: an unwired single target did not block the route"
[[ "$CTRL_RC" == "3" ]] || fails "control broken: the blocked route did not exit 3"

# ===========================================================================
head1 "A2 defect 1 — two registered targets, one of them unresolvable"
# ===========================================================================
set_targets "$T_AB"; probe "target-a wired + target-b unwired, no --target supplied"
D1_STATE="$(jget '.readiness.ROUTE_READY.state')"
D1_REASON="$(jget '.readiness.ROUTE_READY.reason')"
D1_RC="$RUN_RC"
if [[ "$D1_STATE" == "TRUE" && "$D1_REASON" == "ROUTE_READY_PROVEN" && "$D1_RC" == "0" ]]; then
  say "CONFIRMED: the identical unresolvable target-b that produced"
  say "           $CTRL_REASON / exit $CTRL_RC on its own is now invisible to the route."
  say "           ROUTE_READY is TRUE and the run exits 0, with the target leg of the"
  say "           frozen intersection never evaluated at all."
else
  fails "not reproduced: got $D1_STATE / $D1_REASON / exit $D1_RC"
fi
[[ "$(jget '.readiness.TARGET_READY.state')" == "PARTIAL" ]] \
  || say "    (note: TARGET_READY aggregate is not PARTIAL here — check the fixture)"

# ===========================================================================
head1 "A2 defect 2 — no registered target at all"
# ===========================================================================
set_targets '[]'; probe "zero registered targets"
D2_STATE="$(jget '.readiness.ROUTE_READY.state')"
D2_RC="$RUN_RC"
if [[ "$D2_STATE" == "TRUE" && "$D2_RC" == "0" ]]; then
  say "CONFIRMED: a route is proven launchable on a host with no BMAD target to"
  say "           dispatch it into. TARGET_READY says $(jget '.readiness.TARGET_READY.reason')."
else
  fails "not reproduced: got $D2_STATE / exit $D2_RC"
fi

# ===========================================================================
head1 "A2 defect 3 — the workspace-trust decision disappears with it"
# ===========================================================================
jq -n --arg p "$TARGET_A" '{projects: {($p): {hasTrustDialogAccepted: false}}}' \
  > "$HOMEDIR/.claude.json"

set_targets "$T_A"; probe "one target, trust withheld (control)"
TRUST_CTRL_REASON="$(jget '.readiness.ROUTE_READY.reason')"
TRUST_CTRL_RC="$RUN_RC"
[[ "$TRUST_CTRL_REASON" == "WORKSPACE_TRUST_REQUIRED" && "$TRUST_CTRL_RC" == "2" ]] \
  || fails "control broken: the trust prompt did not block the single-target route"

set_targets "$T_AB"; probe "two targets, the SAME trust withheld on target-a"
TRUST_STATE="$(jget '.readiness.ROUTE_READY.state')"
TRUST_FINDINGS="$(jget '[.findings[] | select(.reason == "WORKSPACE_TRUST_REQUIRED")] | length')"
TRUST_RC="$RUN_RC"
if [[ "$TRUST_STATE" == "TRUE" && "$TRUST_FINDINGS" == "0" && "$TRUST_RC" == "0" ]]; then
  say "CONFIRMED: registering a second target turns a loud owner-action refusal"
  say "           ($TRUST_CTRL_REASON, exit $TRUST_CTRL_RC) into a launchable route"
  say "           (exit $TRUST_RC) with zero WORKSPACE_TRUST_REQUIRED findings. The"
  say "           protected prompt is still unaccepted; readiness simply stopped looking."
else
  fails "not reproduced: got $TRUST_STATE / findings $TRUST_FINDINGS / exit $TRUST_RC"
fi

head1 "verdict"
if (( VERDICT == 0 )); then
  printf '  DEFECT REPRODUCED (A2)\n'
else
  printf '  NOT REPRODUCED (A2)\n'
fi
exit "$VERDICT"
