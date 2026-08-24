#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRY="$ROOT/bin/agent-flow-kit"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0
ok(){ printf 'PASS %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf 'FAIL %s%s\n' "$1" "${2:+ — $2}"; FAIL=$((FAIL+1)); }
assert_contains(){ [[ "$2" == *"$3"* ]] && ok "$1" || bad "$1" "missing: $3"; }
assert_eq(){ [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "expected=$3 got=$2"; }
hash_file(){
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}
hash_stream(){
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
  else shasum -a 256 | awk '{print $1}'; fi
}
home_fingerprint(){
  local root="$1" f
  find "$root" \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r f; do
    if [[ -L "$f" ]]; then printf 'L %s %s\n' "$f" "$(readlink "$f")"
    else printf 'F %s %s\n' "$f" "$(hash_file "$f")"; fi
  done | hash_stream
}

make_fixture(){
  local d="$1"
  mkdir -p "$d/bin" "$d/lib" "$d/files/model-router/scripts" "$d/files/humanizer"
  cp "$ENTRY" "$d/bin/agent-flow-kit"; cp "$ROOT/lib/"*.sh "$d/lib/"; chmod +x "$d/bin/agent-flow-kit"
  printf 'router-v1\n' > "$d/files/model-router/SKILL.md"
  printf '#!/usr/bin/env bash\necho dispatch-v1\n' > "$d/files/model-router/scripts/dispatch.sh"; chmod +x "$d/files/model-router/scripts/dispatch.sh"
  cat > "$d/files/model-router/subscriptions.yaml" <<'YAML'
launcher:
  router_endpoint: https://router.invalid
  caller_token_env: TEST_TOKEN
  catalog_path: /tmp/agent-flow-kit-test-catalog.yaml
  stamp_validator: missing-validator-for-test
  harness_binaries:
    claude: claude
    codex: codex
YAML
  printf 'humanizer-v1\n' > "$d/files/humanizer/SKILL.md"
  cat > "$d/files/claude-global-CLAUDE.md" <<'CLAUDE'
## machine-only prelude
not managed

## Local GPU delegation (junior-dev protocol)
local-v1

## Model & effort routing (BMAD flow)
route-v1
### Epic source declaration (single source of truth per epic)
epic-v1
### PM merge authority (story PRs → develop)
merge-v1

## machine-only suffix
not managed either
CLAUDE
  printf '# Codex policy\npolicy-v1\n' > "$d/files/codex-AGENTS.md"
  git -C "$d" init -q
  git -C "$d" config user.email tests@example.invalid
  git -C "$d" config user.name tests
  git -C "$d" add .
  git -C "$d" commit -qm v1
}

make_target(){
  local d="$1"
  mkdir -p "$d/_bmad/bmm/workflows/4-implementation/create-story" "$d/_bmad/bmm/agents"
  cat > "$d/_bmad/bmm/workflows/4-implementation/create-story/template.md" <<'TPL'
---
stamp:
persona: dev
gates:
  - "true"
max_cycles: 3
---
# Story
TPL
  printf 'dev persona\n' > "$d/_bmad/bmm/agents/dev.md"
}

KIT="$TMP/kit"; HOME1="$TMP/home1"; TARGET1="$TMP/target1"
mkdir -p "$KIT" "$HOME1"; make_fixture "$KIT"; make_target "$TARGET1"

# 1 clean first adoption + target registration
out="$(HOME="$HOME1" "$KIT/bin/agent-flow-kit" adopt --target "$TARGET1")" || bad "clean adoption exits zero"
assert_contains "clean adoption reports adopted" "$out" "ADOPTED"
assert_contains "target wiring detected" "$out" "CURRENT target"
[[ -f "$HOME1/.local/state/agent-flow-kit/state.json" ]] && ok "state manifest created" || bad "state manifest created"
assert_eq "machine-local ownership recorded" "$(jq -r '.machine_local["model-router-launcher"].mode' "$HOME1/.local/state/agent-flow-kit/state.json")" "machine_local_config"
assert_eq "target ownership recorded separately" "$(jq -r '.targets[0].mode' "$HOME1/.local/state/agent-flow-kit/state.json")" "target_repo_wiring"

# 2 current installation and idempotent no-op
out="$(HOME="$HOME1" "$KIT/bin/agent-flow-kit" status)" || bad "current status exits zero"
assert_contains "current status sees managed copy" "$out" "CURRENT model-router-core"
before="$(home_fingerprint "$HOME1")"
out="$(HOME="$HOME1" "$KIT/bin/agent-flow-kit" update)"
after="$(home_fingerprint "$HOME1")"
assert_contains "idempotent update reports no changes" "$out" "CURRENT no filesystem changes"
assert_eq "idempotent update leaves filesystem unchanged" "$after" "$before"

# 3 canonical update: managed copies converge; local config and unrelated policy survive
printf '\nlocal_override: keep-me\n' >> "$HOME1/.agents/skills/model-router/subscriptions.yaml"
printf '\n# CLAUDE USER NOTE\nkeep-claude\n' >> "$HOME1/.claude/CLAUDE.md"
printf '\n# CODEX USER NOTE\nkeep-codex\n' >> "$HOME1/.codex/AGENTS.md"
printf 'router-v2\n' > "$KIT/files/model-router/SKILL.md"
printf 'humanizer-v2\n' > "$KIT/files/humanizer/SKILL.md"
sed -i.bak 's/route-v1/route-v2/' "$KIT/files/claude-global-CLAUDE.md"; rm -f "$KIT/files/claude-global-CLAUDE.md.bak"
printf '# Codex policy\npolicy-v2\n' > "$KIT/files/codex-AGENTS.md"
git -C "$KIT" add files && git -C "$KIT" commit -qm v2
set +e; out="$(HOME="$HOME1" "$KIT/bin/agent-flow-kit" status 2>&1)"; rc=$?; set -e
assert_eq "update available status exits nonzero" "$rc" "1"
assert_contains "update available is visible" "$out" "UPDATE_AVAILABLE"
HOME="$HOME1" "$KIT/bin/agent-flow-kit" update >/dev/null
assert_eq "managed copy updated" "$(cat "$HOME1/.agents/skills/model-router/SKILL.md")" "router-v2"
assert_contains "machine-local config preserved" "$(cat "$HOME1/.agents/skills/model-router/subscriptions.yaml")" "local_override: keep-me"
assert_contains "Claude unrelated content preserved" "$(cat "$HOME1/.claude/CLAUDE.md")" "keep-claude"
assert_contains "Claude managed section updated" "$(cat "$HOME1/.claude/CLAUDE.md")" "route-v2"
assert_contains "Codex unrelated content preserved" "$(cat "$HOME1/.codex/AGENTS.md")" "keep-codex"
assert_contains "Codex managed section updated" "$(cat "$HOME1/.codex/AGENTS.md")" "policy-v2"

# 4 harmless managed-file drift blocks the whole update and leaves manifest at old revision
printf '\n# harmless drift fixture\n' >> "$HOME1/.agents/skills/model-router/SKILL.md"
printf 'router-v3\n' > "$KIT/files/model-router/SKILL.md"; git -C "$KIT" add files/model-router/SKILL.md; git -C "$KIT" commit -qm v3
old_state="$(jq -r '.kit.last_applied_revision' "$HOME1/.local/state/agent-flow-kit/state.json")"
set +e; out="$(HOME="$HOME1" "$KIT/bin/agent-flow-kit" update 2>&1)"; rc=$?; set -e
[[ "$rc" -ne 0 ]] && ok "local drift update refuses" || bad "local drift update refuses"
assert_contains "local drift evidence names component" "$out" "LOCAL_DRIFT model-router-core"
assert_contains "local drift fixture survives refusal" "$(cat "$HOME1/.agents/skills/model-router/SKILL.md")" "harmless drift fixture"
assert_eq "failed update does not advance manifest" "$(jq -r '.kit.last_applied_revision' "$HOME1/.local/state/agent-flow-kit/state.json")" "$old_state"

# 5 legacy stale canonical install (no manifest) can be safely claimed from Git history
HOME2="$TMP/home2"; mkdir -p "$HOME2/.agents/skills" "$HOME2/.claude/skills" "$HOME2/.codex"
V1="$(git -C "$KIT" rev-list --max-parents=0 HEAD)"; ARC="$TMP/archive"; mkdir -p "$ARC"
git -C "$KIT" archive "$V1" files/model-router files/humanizer files/claude-global-CLAUDE.md files/codex-AGENTS.md | tar -x -C "$ARC"
cp -R "$ARC/files/model-router" "$HOME2/.agents/skills/model-router"; cp -R "$ARC/files/humanizer" "$HOME2/.agents/skills/humanizer"
ln -s "$HOME2/.agents/skills/model-router" "$HOME2/.claude/skills/model-router"; ln -s "$HOME2/.agents/skills/humanizer" "$HOME2/.claude/skills/humanizer"
{ printf '# user prelude\n'; awk '$0=="## Local GPU delegation (junior-dev protocol)"{on=1} on{if(seen && /^## / && $0!="## Model & effort routing (BMAD flow)") exit; print; if($0=="## Model & effort routing (BMAD flow)") seen=1}' "$ARC/files/claude-global-CLAUDE.md"; printf '# user trailer\n'; } > "$HOME2/.claude/CLAUDE.md"
cp "$ARC/files/codex-AGENTS.md" "$HOME2/.codex/AGENTS.md"
printf '\nlegacy_override: preserve\n' >> "$HOME2/.agents/skills/model-router/subscriptions.yaml"
out="$(HOME="$HOME2" "$KIT/bin/agent-flow-kit" adopt)"
assert_contains "legacy canonical install adopted" "$out" "ADOPTED"
assert_eq "legacy tree converged to current" "$(cat "$HOME2/.agents/skills/model-router/SKILL.md")" "router-v3"
assert_contains "legacy machine-local config preserved" "$(cat "$HOME2/.agents/skills/model-router/subscriptions.yaml")" "legacy_override: preserve"
assert_contains "legacy Claude unrelated trailer preserved" "$(cat "$HOME2/.claude/CLAUDE.md")" "user trailer"

# 6 unknown legacy local modification is not auto-claimed
HOME3="$TMP/home3"; cp -R "$HOME2" "$HOME3"; rm -rf "$HOME3/.local/state/agent-flow-kit"
rm -f "$HOME3/.claude/skills/model-router" "$HOME3/.claude/skills/humanizer"
ln -s "$HOME3/.agents/skills/model-router" "$HOME3/.claude/skills/model-router"; ln -s "$HOME3/.agents/skills/humanizer" "$HOME3/.claude/skills/humanizer"
printf '\nmanual unknown edit\n' >> "$HOME3/.agents/skills/humanizer/SKILL.md"
set +e; out="$(HOME="$HOME3" "$KIT/bin/agent-flow-kit" adopt 2>&1)"; rc=$?; set -e
[[ "$rc" -ne 0 ]] && ok "unknown legacy modification refuses" || bad "unknown legacy modification refuses"
assert_contains "unknown legacy refusal is actionable" "$out" "LOCAL_DRIFT humanizer"

# 7 missing validator/client dependency is visible during verify
STUB="$TMP/stubbin"; mkdir -p "$STUB"
cat > "$STUB/yq" <<'YQ'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo 'yq version v4.44.3'; exit 0; fi
q="${2:-}"
case "$q" in
  *router_endpoint*) echo 'https://router.invalid';;
  *caller_token_env*) echo 'TEST_TOKEN';;
  *catalog_path*) echo '/tmp/agent-flow-kit-test-catalog.yaml';;
  *stamp_validator*) echo 'missing-validator-for-test';;
  *harness_binaries.claude*) echo 'claude';;
  *harness_binaries.codex*) echo 'codex';;
  *) echo '';;
esac
YQ
for x in orca claude codex; do printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/$x"; chmod +x "$STUB/$x"; done
chmod +x "$STUB/yq"; printf 'catalog\n' > /tmp/agent-flow-kit-test-catalog.yaml
set +e; out="$(PATH="$STUB:$PATH" TEST_TOKEN=x HOME="$HOME2" "$KIT/bin/agent-flow-kit" verify --offline 2>&1)"; rc=$?; set -e
rm -f /tmp/agent-flow-kit-test-catalog.yaml
[[ "$rc" -ne 0 ]] && ok "missing validator makes verify fail" || bad "missing validator makes verify fail"
assert_contains "missing validator is explicitly reported" "$out" "validator/client dependency missing"

# 8 target wiring failure is visible
BADTARGET="$TMP/badtarget"; mkdir -p "$BADTARGET"
set +e; out="$(HOME="$HOME2" "$KIT/bin/agent-flow-kit" status --target "$BADTARGET" 2>&1)"; rc=$?; set -e
[[ "$rc" -ne 0 ]] && ok "bad target status nonzero" || bad "bad target status nonzero"
assert_contains "bad target names missing BMAD template" "$out" "BMAD create-story template not found"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
