#!/usr/bin/env bash
# lifecycle-tests.sh — the isolated deterministic gate for the read-only
# lifecycle foundation.
#
# Every scenario runs against a throwaway HOME and a throwaway Git checkout
# built from scratch. Nothing in this suite touches the developer's real HOME,
# real installation, real Git state, the router, a provider session, or Orca.
#
# Layers:
#   UNIT      — the pure primitives are sourced and called directly.
#   SCENARIO  — bin/agent-flow-kit is RUN against a fixture host, and the
#               machine-readable result plus the exit code are the assertion.
#
# The MUTATING half of the surface — plans, approvals, the adoption and update
# transactions, backups, rollback, interruption recovery and offline
# verification — has its own isolated gate in tests/lifecycle-mutation-tests.sh.
# The SCOPED READINESS half — host, new-work, target and route readiness, live
# probes, the orchestration bridge — has its own gate in
# tests/lifecycle-readiness-tests.sh.
#
# Usage: tests/lifecycle-tests.sh
# Exit:  0 all passed, 1 any failure.

set -uo pipefail

KIT_ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
AFK="$KIT_ROOT/bin/agent-flow-kit"
CONTRACT_DOC="$KIT_ROOT/docs/LIFECYCLE-CONTRACT.md"

TMPROOT="$(mktemp -d)"; trap 'rm -rf "$TMPROOT"' EXIT

# A single sentinel used everywhere a secret could leak. If this string ever
# reaches emitted output, the redaction contract is broken.
SENTINEL='afk-sentinel-secret-DO-NOT-EMIT-4f2c9a1b'

export GIT_AUTHOR_NAME="afk-test" GIT_AUTHOR_EMAIL="afk@test.invalid"
export GIT_COMMITTER_NAME="afk-test" GIT_COMMITTER_EMAIL="afk@test.invalid"

PASS=0 FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  {
  printf '  \033[31mFAIL\033[0m %s\n' "$1"
  if [[ -n "${2:-}" ]]; then printf '        %s\n' "$2"; fi
  FAIL=$((FAIL + 1))
}
skip() { printf '  \033[33mSKIP\033[0m %s\n' "$1"; }
head1() { printf '\n\033[1m%s\033[0m\n' "$1"; }

assert_eq()       { if [[ "$2" == "$3"   ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
assert_ne()       { if [[ "$2" != "$3"   ]]; then ok "$1"; else bad "$1" "should not equal '$3'"; fi; }
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1" "missing substring: $3"; fi; }
assert_absent()   { if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1" "should NOT contain: $3"; fi; }
assert_no_file()  { if [[ -e "$2" ]]; then bad "$1" "exists: $2"; else ok "$1"; fi; }

hash_of_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# ===========================================================================
# fixtures
# ===========================================================================

section_begin() { printf '# >>> agent-flow-kit managed section: %s >>>' "$1"; }
section_end()   { printf '# <<< agent-flow-kit managed section: %s <<<' "$1"; }

git_commit_all() { # <dir> <message>
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" -c commit.gpgsign=false commit -q --no-verify -m "$2" >/dev/null 2>&1
}

# make_checkout <dir> [lifecycle-schema-version]
# A minimal but complete canonical checkout: the declaration, the managed
# source inputs, and a real Git history.
make_checkout() {
  local d="$1" ver="${2:-1.0}"
  mkdir -p "$d/adapters" "$d/bin" "$d/lib" "$d/lifecycle" "$d/files/model-router/scripts" "$d/files/humanizer/skills/humanizer"
  cat > "$d/lifecycle/kit.json" <<JSON
{
  "kit_id": "agent-flow-kit",
  "lifecycle_schema_version": "$ver",
  "state_schema_version": "1.0",
  "result_schema_version": "1.0",
  "default_branch": "master",
  "managed_inputs": ["adapters", "bin", "lib", "files", "lifecycle"]
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
  printf 'runtime adapter v1\n' > "$d/adapters/README"
  printf 'runtime executable v1\n' > "$d/bin/agent-flow-kit"
  printf 'runtime library v1\n' > "$d/lib/afk-common.sh"
  printf '{"schema":"test-release-policy/1"}\n' > "$d/lifecycle/release-policy.json"
  git init -q "$d" >/dev/null 2>&1
  git -C "$d" symbolic-ref HEAD refs/heads/master >/dev/null 2>&1
  git_commit_all "$d" "canonical v1"
}

# make_bmad_target <dir> — a target repository wired for agent-flow-kit: the v6
# tree story template carrying the frontmatter contract, and the persona files
# dispatch injects. This is the shape target readiness has to resolve, and the
# fixture is deliberately minimal so a missing piece is what a test removes.
make_bmad_target() {
  local d="$1"
  mkdir -p "$d/_bmad/bmm/workflows/4-implementation/create-story" "$d/_bmad/bmm/agents"
  cat > "$d/_bmad/bmm/workflows/4-implementation/create-story/template.md" <<'TEMPLATE'
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
  printf 'You are the dev persona.\n' > "$d/_bmad/bmm/agents/dev.md"
  printf 'You are the PM persona.\n'  > "$d/_bmad/bmm/agents/pm.md"
}

SC="" HOMEDIR="" CHECKOUT=""
new_scenario() { # <name>
  SC="$TMPROOT/sc-$1"
  HOMEDIR="$SC/home"
  CHECKOUT="$SC/checkout"
  mkdir -p "$HOMEDIR" "$CHECKOUT"
  make_checkout "$CHECKOUT"
}

# install_kit <home> <checkout> — a complete, healthy legacy installation.
install_kit() {
  local h="$1" c="$2"
  mkdir -p "$h/.agents/skills" "$h/.claude/skills" "$h/.codex"
  cp -R "$c/adapters" "$h/.agents/skills/afk-runtime"
  mkdir -p "$h/.agents/skills/afk-runtime/bin" "$h/.agents/skills/afk-runtime/lib" "$h/.agents/skills/afk-runtime/lifecycle"
  cp -R "$c/bin/." "$h/.agents/skills/afk-runtime/bin/"
  cp -R "$c/lib/." "$h/.agents/skills/afk-runtime/lib/"
  cp "$c/lifecycle/release-policy.json" "$h/.agents/skills/afk-runtime/lifecycle/release-policy.json"
  cp -R "$c/files/model-router" "$h/.agents/skills/model-router"
  cp -R "$c/files/humanizer" "$h/.agents/skills/humanizer"
  ln -s "$h/.agents/skills/model-router" "$h/.claude/skills/model-router"
  ln -s "$h/.agents/skills/humanizer" "$h/.claude/skills/humanizer"
  {
    printf '# my own notes, owned by me\n'
    section_begin claude-global-policy; printf '\n'
    cat "$c/files/claude-global-CLAUDE.md"
    section_end claude-global-policy; printf '\n'
    printf '# a trailing user note\n'
  } > "$h/.claude/CLAUDE.md"
  cp "$c/files/codex-AGENTS.md" "$h/.codex/AGENTS.md"
}

RUN_OUT="" RUN_ERR="" RUN_RC=0
run_afk() { # <args...> — runs against $HOMEDIR / $CHECKOUT
  RUN_OUT="$(HOME="$HOMEDIR" \
             XDG_STATE_HOME="$HOMEDIR/.local/state" \
             AFK_KIT_ROOT="$CHECKOUT" \
             bash "$AFK" "$@" 2>"$TMPROOT/stderr")"
  RUN_RC=$?
  RUN_ERR="$(cat "$TMPROOT/stderr" 2>/dev/null)"
}

jget() { printf '%s' "$RUN_OUT" | jq -r "$1"; }

component_field() { # <component-id> <field-expr>
  printf '%s' "$RUN_OUT" | jq -r --arg id "$1" ".components[] | select(.id == \$id) | $2"
}

target_field() { # <target-id> <field-expr>
  printf '%s' "$RUN_OUT" | jq -r --arg id "$1" ".targets[] | select(.id == \$id) | $2"
}

adoption_field() { # <component-id> <field>
  printf '%s' "$RUN_OUT" | jq -r --arg id "$1" ".extra.adoption.components[] | select(.id == \$id) | .$2"
}

has_finding_reason() { # <reason>
  printf '%s' "$RUN_OUT" | jq -r --arg r "$1" '[.findings[] | select(.reason == $r)] | length'
}

STATE_DIR_REL=".local/state/agent-flow-kit"

# write_manifest — establish ownership the way a successful adoption
# transaction would: record the identities status just observed, plus the
# checkout's revision and repository identity.
write_manifest() {
  run_afk status --json
  mkdir -p "$HOMEDIR/$STATE_DIR_REL"
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
    }' > "$HOMEDIR/$STATE_DIR_REL/state.json"
}

manifest_patch() { # <jq filter>
  local f="$HOMEDIR/$STATE_DIR_REL/state.json"
  jq "$1" "$f" > "$f.new" && mv "$f.new" "$f"
}

# fingerprint_tree — content identity of a directory used to prove that a
# read-only command changed nothing. It covers files, symlinks AND directories
# (so a created-then-empty directory is caught), plus permission bits and
# ownership (so a metadata-only change is caught).
fingerprint_tree() {
  ( cd "$1" 2>/dev/null || exit 0
    find . -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
      meta="$(ls -ldn -- "$f" 2>/dev/null | awk '{print $1, $3, $4}')"
      if [[ -L "$f" ]]; then
        printf 'L %s %s -> %s\n' "$f" "$meta" "$(readlink -- "$f")"
      elif [[ -d "$f" ]]; then
        printf 'D %s %s\n' "$f" "$meta"
      else
        printf 'F %s %s %s\n' "$f" "$meta" "$(hash_of_file "$f")"
      fi
    done )
}

# The .git directory is excluded from the worktree fingerprint and asserted
# separately, by logical content: refs, reachable objects, HEAD and porcelain
# status. Git's index stat cache is deliberately not asserted — Git itself may
# refresh it on any read, and the invariant that matters is that no ref, no
# object and no tracked path changed.
fingerprint_worktree() {
  fingerprint_tree "$1" | awk '$2 != "./.git" && $2 !~ /^\.\/\.git\//'
}

fingerprint_git_identity() { # <checkout>
  {
    git -C "$1" rev-parse HEAD
    git -C "$1" symbolic-ref -q HEAD || printf 'DETACHED\n'
    git -C "$1" for-each-ref --format='%(refname) %(objectname)'
    git -C "$1" rev-list --all 2>/dev/null | LC_ALL=C sort
    git -C "$1" status --porcelain --untracked-files=all
    git -C "$1" config --get core.bare
  } 2>/dev/null
}

# ===========================================================================
head1 "0. Pure primitives (lib sourced, nothing executed)"
# ===========================================================================

# shellcheck source=../lib/afk-common.sh
. "$KIT_ROOT/lib/afk-common.sh"

U="$TMPROOT/unit"; mkdir -p "$U/tree/sub" "$U/other"
printf 'a\n' > "$U/tree/a.txt"
printf 'b\n' > "$U/tree/sub/b.txt"
printf 'local\n' > "$U/tree/subscriptions.yaml"
printf 'outside\n' > "$U/other/target.txt"

T1="$(afk_tree_identity "$U/tree" "")"
T2="$(afk_tree_identity "$U/tree" "")"
assert_eq "tree identity is deterministic" "$T1" "$T2"
assert_contains "tree identity is a bounded sha256 identifier" "$T1" "sha256:"

T_EXCL="$(afk_tree_identity "$U/tree" "subscriptions.yaml")"
assert_ne "excluding a member changes the identity" "$T_EXCL" "$T1"
printf 'local changed\n' > "$U/tree/subscriptions.yaml"
assert_eq "an excluded machine-owned member cannot move the managed identity" \
  "$(afk_tree_identity "$U/tree" "subscriptions.yaml")" "$T_EXCL"
printf 'a changed\n' > "$U/tree/a.txt"
assert_ne "but a managed member does move it" \
  "$(afk_tree_identity "$U/tree" "subscriptions.yaml")" "$T_EXCL"
printf 'a\n' > "$U/tree/a.txt"

# A relative root cannot be hashed: the internal end-of-scan sentinel is only
# unambiguous because every real record is an absolute path.
if afk_tree_identity "tree" "" >/dev/null 2>&1; then
  bad "a relative tree root is refused"
else
  ok "a relative tree root is refused"
fi

# Exclusions are matched by exact string equality, never by word splitting or
# globbing: a declared exclusion with a space stays one member, and a glob
# character excludes nothing but itself.
mkdir -p "$U/spacetree"
printf 'one\n' > "$U/spacetree/keep me.txt"
printf 'two\n' > "$U/spacetree/other.txt"
S_ALL="$(afk_tree_identity "$U/spacetree" "")"
S_EXCL="$(afk_tree_identity "$U/spacetree" "keep me.txt")"
assert_ne "an exclusion containing a space excludes exactly that member" "$S_EXCL" "$S_ALL"
assert_eq "a glob exclusion is not expanded" \
  "$(afk_tree_identity "$U/spacetree" '*.txt')" "$S_ALL"

# An unreadable member fails the identity outright rather than hashing the
# part that happened to be readable.
printf 'locked\n' > "$U/tree/locked.txt"
chmod 000 "$U/tree/locked.txt" 2>/dev/null
if cat "$U/tree/locked.txt" >/dev/null 2>&1; then
  skip "unreadable tree member (this user can read a mode-000 file)"
else
  if afk_tree_identity "$U/tree" "" >/dev/null 2>&1; then
    bad "an unreadable member fails the whole tree identity"
  else
    ok "an unreadable member fails the whole tree identity"
  fi
fi
chmod 644 "$U/tree/locked.txt" 2>/dev/null
rm -f "$U/tree/locked.txt"

# Names are encoded, so a newline or tab in a filename cannot forge a record.
assert_eq "a newline in a name is encoded, not emitted raw" \
  "$(afk_encode_path "$(printf 'a\nb')")" 'a\nb'
assert_eq "a tab in a name is encoded" "$(afk_encode_path "$(printf 'a\tb')")" 'a\tb'
assert_eq "a backslash is escaped first, so the encoding is reversible" \
  "$(afk_encode_path 'a\nb')" 'a\\nb'

# --- path guard -----------------------------------------------------------
assert_eq "guard: real file with file expected" "$(afk_path_guard "$U/tree/a.txt" file "")" "PATH_OK"
assert_eq "guard: real dir with dir expected"   "$(afk_path_guard "$U/tree" dir "")" "PATH_OK"
assert_eq "guard: absent path"                  "$(afk_path_guard "$U/nope" file "")" "PATH_ABSENT"
assert_eq "guard: dir where a file is declared" "$(afk_path_guard "$U/tree" file "")" "PATH_TYPE_MISMATCH"

ln -s "$U/other/target.txt" "$U/tree/linked.txt"
assert_eq "guard: symlink where a real file is declared fails closed" \
  "$(afk_path_guard "$U/tree/linked.txt" file "")" "PATH_UNEXPECTED_SYMLINK"
assert_eq "guard: a link inside its boundary is accepted" \
  "$(afk_path_guard "$U/tree/linked.txt" link "$U")" "PATH_OK"
assert_eq "guard: a link escaping its boundary fails closed" \
  "$(afk_path_guard "$U/tree/linked.txt" link "$U/tree")" "PATH_ESCAPES_OWNERSHIP_BOUNDARY"
assert_eq "guard: a real file where a link is declared" \
  "$(afk_path_guard "$U/tree/a.txt" link "$U")" "PATH_NOT_A_SYMLINK"

# The parent chain is resolved too: a symlinked parent directory silently moves
# a managed path out of its declared territory.
mkdir -p "$U/realparent" "$U/container"
printf 'x\n' > "$U/realparent/child.txt"
ln -s "$U/realparent" "$U/container/parent"
assert_eq "guard: a symlinked PARENT escaping the container fails closed" \
  "$(afk_path_guard "$U/container/parent/child.txt" file "" "$U/container")" "PATH_PARENT_ESCAPES_BOUNDARY"
assert_eq "guard: the same path inside its container is accepted" \
  "$(afk_path_guard "$U/container/parent/child.txt" file "" "$U")" "PATH_OK"
assert_eq "guard: an unresolvable declared boundary fails closed" \
  "$(afk_path_guard "$U/tree/a.txt" file "" "$U/no-such-container")" "PATH_BOUNDARY_UNRESOLVABLE"

assert_eq "tree scan finds the escaping symlink" \
  "$(afk_tree_find_escaping_symlink "$U/tree")" "linked.txt"
rm -f "$U/tree/linked.txt"
if afk_tree_find_escaping_symlink "$U/tree" >/dev/null; then
  bad "a clean tree reports no escape"
else
  ok "a clean tree reports no escape"
fi

assert_eq "containment: child of root"   "$(afk_is_within /a/b/c /a/b && echo in || echo out)" "in"
assert_eq "containment: sibling of root" "$(afk_is_within /a/bc /a/b && echo in || echo out)" "out"

# --- managed sections -----------------------------------------------------
SFILE="$U/CLAUDE.md"
{ printf 'before\n'; section_begin s1; printf '\n'; printf 'payload one\npayload two\n'
  section_end s1; printf '\n'; printf 'after\n'; } > "$SFILE"
assert_eq "section payload extracted exactly" \
  "$(afk_section_extract "$SFILE" s1)" "$(printf 'payload one\npayload two')"

afk_section_extract "$SFILE" absent >/dev/null
assert_eq "an absent section returns 2" "$?" "2"

{ cat "$SFILE"; section_begin s1; printf '\n'; } > "$U/dup.md"
afk_section_extract "$U/dup.md" s1 >/dev/null
assert_eq "a duplicated begin marker is malformed (3), never best-effort" "$?" "3"

{ printf 'x\n'; section_begin s1; printf '\n'; printf 'unterminated\n'; } > "$U/unterm.md"
afk_section_extract "$U/unterm.md" s1 >/dev/null
assert_eq "an unterminated section is malformed (3)" "$?" "3"

{ printf 'x\n'; section_end s1; printf '\n'; printf 'p\n'; section_begin s1; printf '\n'; } > "$U/rev.md"
afk_section_extract "$U/rev.md" s1 >/dev/null
assert_eq "reversed markers are malformed (3)" "$?" "3"

# The contracted normalization, proven on both sides of a comparison.
printf 'payload one\npayload two\n' > "$U/canon.md"
assert_eq "section identity equals canonical payload identity" \
  "$(afk_section_identity "$SFILE" s1)" "$(afk_file_payload_identity "$U/canon.md")"
printf 'payload one\npayload two' > "$U/canon-nonewline.md"
assert_eq "a missing final newline does not manufacture drift" \
  "$(afk_section_identity "$SFILE" s1)" "$(afk_file_payload_identity "$U/canon-nonewline.md")"
printf 'payload one\npayload THREE\n' > "$U/canon-diff.md"
assert_ne "a real payload change does move the identity" \
  "$(afk_section_identity "$SFILE" s1)" "$(afk_file_payload_identity "$U/canon-diff.md")"

# --- the reason vocabulary is real, not decorative -------------------------
BAD_MSG=0; BAD_ACTION=0; REASON_COUNT=0
while IFS= read -r code; do
  [[ -n "$code" ]] || continue
  REASON_COUNT=$((REASON_COUNT + 1))
  msg="$(afk_reason_message "$code")"
  act="$(afk_reason_action "$code")"
  if [[ -z "$msg" || "$msg" == "$AFK_REASON_FALLBACK" ]]; then
    BAD_MSG=$((BAD_MSG + 1))
    printf '        no specific message: %s\n' "$code"
  fi
  if [[ -z "$act" ]]; then BAD_ACTION=$((BAD_ACTION + 1)); fi
done < <(afk_reason_codes)
assert_ne "the published reason vocabulary is non-empty" "$REASON_COUNT" "0"
assert_eq "every published reason code carries a specific message" "$BAD_MSG" "0"
assert_eq "every published reason code carries a required action" "$BAD_ACTION" "0"
assert_eq "the vocabulary has no duplicate codes" \
  "$(afk_reason_codes | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')" "0"

# ===========================================================================
head1 "1. Secret redaction — with an anti-vacuity control"
# ===========================================================================
# Proving that emitted output lacks the sentinel proves nothing on its own: an
# implementation that never reads anything would pass. So first prove the value
# genuinely reaches the record builder, by swapping in an identity redactor.

identity_redactor() { printf '%s\n' "$1"; }

# Every reported environment name is checked individually: one leaking source
# is enough, and a single-variable test would not find it.
ENV_NAMES_UNDER_TEST="ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL CLAUDE_CONFIG_DIR OPENAI_API_KEY OPENAI_BASE_URL CODEX_API_KEY AGENT_ROUTER_URL AGENT_ROUTER_TOKEN OP_SERVICE_ACCOUNT_TOKEN AGENT_STAMP_VALIDATE_CATALOG_PATH"
VACUOUS=0; UNREDACTED=0; NO_PRESENCE=0
for name in $ENV_NAMES_UNDER_TEST; do
  export "$name=$SENTINEL"
  AFK_REDACT_FN=identity_redactor
  rec_raw="$(afk_env_record "$name")"
  AFK_REDACT_FN=afk_redact_value
  rec_red="$(afk_env_record "$name")"
  if [[ "$rec_raw" != *"$SENTINEL"* ]]; then
    VACUOUS=$((VACUOUS + 1))
    printf '        never reached the result path: %s\n' "$name"
  fi
  if [[ "$rec_red" == *"$SENTINEL"* ]]; then
    UNREDACTED=$((UNREDACTED + 1))
    printf '        survived redaction: %s\n' "$name"
  fi
  if [[ "$rec_red" != *'"present":true'* ]]; then NO_PRESENCE=$((NO_PRESENCE + 1)); fi
  unset "$name"
done
assert_eq "anti-vacuity: every reported variable DOES reach the result path" "$VACUOUS" "0"
assert_eq "the shipped redactor removes every one of them" "$UNREDACTED" "0"
assert_eq "presence is still reported for every one of them" "$NO_PRESENCE" "0"

export AGENT_ROUTER_TOKEN="$SENTINEL"
REDACTED_REC="$(afk_env_record AGENT_ROUTER_TOKEN)"
assert_contains "redacted presence is still reported" "$REDACTED_REC" "[REDACTED]"
assert_contains "the variable name is still reported" "$REDACTED_REC" "AGENT_ROUTER_TOKEN"
assert_eq "a secret-bearing name is classified as such" \
  "$(afk_env_classification AGENT_ROUTER_TOKEN)" "SECRET_BEARING"
assert_eq "a non-secret name is classified as configuration" \
  "$(afk_env_classification AGENT_ROUTER_URL)" "CONFIGURATION"
unset AGENT_ROUTER_TOKEN

# Caller-supplied text is never echoed unless it is in the closed vocabulary.
assert_eq "a known option is echoed back verbatim" "$(afk_safe_diagnostic '--json')" "--json"
assert_eq "a live-mode option is in the closed vocabulary" "$(afk_safe_diagnostic '--live')" "--live"
assert_eq "an unknown option is replaced" \
  "$(afk_safe_diagnostic "--$SENTINEL")" "<unrecognized option>"
assert_eq "an unknown bare argument is replaced" \
  "$(afk_safe_diagnostic "$SENTINEL")" "<unrecognized argument>"

# ===========================================================================
head1 "2. Repository identity and mutation-source eligibility"
# ===========================================================================

new_scenario identity
install_kit "$HOMEDIR" "$CHECKOUT"
run_afk status --json
HEAD_SHA="$(git -C "$CHECKOUT" rev-parse HEAD)"
ROOT_SHA="$(git -C "$CHECKOUT" rev-list --max-parents=0 HEAD | tail -n1)"

assert_eq "checkout revision recorded exactly"   "$(jget '.checkout.revision')" "$HEAD_SHA"
assert_eq "repository identified by root commit" "$(jget '.checkout.repository_identity')" "rootcommit:$ROOT_SHA"
assert_eq "identity method is declared"          "$(jget '.checkout.identity_method')" "root_commit"
assert_eq "kit declaration read"                 "$(jget '.checkout.kit_id')" "agent-flow-kit"
assert_eq "the declaration is complete"          "$(jget '.checkout.declaration')" "COMPLETE"
assert_eq "clean checkout is an eligible source" "$(jget '.source_eligibility.state')" "ELIGIBLE"
assert_eq "clean checkout allows mutation"       "$(jget '.source_eligibility.mutation_allowed')" "true"
assert_eq "managed inputs are carried as a list" "$(jget '.checkout.managed_inputs | length')" "5"

# Directory naming is not evidence of identity (FR-29).
REAL_CHECKOUT="$CHECKOUT"
NAMED="$SC/agent-flow-kit"
mkdir -p "$NAMED"
cp -R "$CHECKOUT/files" "$NAMED/files"
git init -q "$NAMED" >/dev/null 2>&1
git -C "$NAMED" symbolic-ref HEAD refs/heads/master >/dev/null 2>&1
git_commit_all "$NAMED" "impostor"
CHECKOUT="$NAMED"
run_afk status --json
assert_eq "a directory merely NAMED agent-flow-kit is not identified" \
  "$(jget '.source_eligibility.state')" "SOURCE_INELIGIBLE"
assert_eq "and says why" \
  "$(jget '.source_eligibility.reasons | index("SOURCE_REPOSITORY_UNIDENTIFIED") != null')" "true"

# A non-Git directory cannot prove a revision.
NOGIT="$SC/nogit"
mkdir -p "$NOGIT"
cp -R "$REAL_CHECKOUT/files" "$NOGIT/files"
cp -R "$REAL_CHECKOUT/lifecycle" "$NOGIT/lifecycle"
CHECKOUT="$NOGIT"
run_afk status --json
assert_eq "a non-Git source is ineligible" \
  "$(jget '.source_eligibility.reasons | index("SOURCE_NOT_A_GIT_CHECKOUT") != null')" "true"
assert_eq "and reports no revision it cannot prove" "$(jget '.checkout.revision')" "null"
CHECKOUT="$REAL_CHECKOUT"

# --- the source declaration is a complete shape or it is nothing ----------
new_scenario declaration
install_kit "$HOMEDIR" "$CHECKOUT"
KIT_DECL_ORIG="$SC/kit-declaration-original.json"
cp "$CHECKOUT/lifecycle/kit.json" "$KIT_DECL_ORIG"

printf 'this is not json\n' > "$CHECKOUT/lifecycle/kit.json"
run_afk status --json
assert_eq "an unparseable declaration is refused" \
  "$(jget '.source_eligibility.reasons | index("SOURCE_DECLARATION_UNREADABLE") != null')" "true"
assert_eq "and blocks mutation" "$(jget '.source_eligibility.mutation_allowed')" "false"
assert_eq "and is reported as such" "$(jget '.checkout.declaration')" "UNREADABLE"

for missing in default_branch managed_inputs state_schema_version kit_id; do
  jq "del(.$missing)" "$KIT_DECL_ORIG" > "$CHECKOUT/lifecycle/kit.json"
  run_afk status --json
  if [[ "$missing" == "kit_id" ]]; then
    # Without a kit id there is no identity at all, which is the stronger,
    # earlier refusal.
    assert_eq "a declaration without kit_id cannot identify the repository" \
      "$(jget '.source_eligibility.reasons | index("SOURCE_REPOSITORY_UNIDENTIFIED") != null')" "true"
  else
    assert_eq "a declaration missing $missing is incomplete, never partly honoured" \
      "$(jget '.source_eligibility.reasons | index("SOURCE_DECLARATION_INCOMPLETE") != null')" "true"
  fi
  assert_eq "and it blocks mutation: $missing" "$(jget '.source_eligibility.mutation_allowed')" "false"
done

jq '.managed_inputs = ["/etc"]' "$KIT_DECL_ORIG" > "$CHECKOUT/lifecycle/kit.json"
run_afk status --json
assert_eq "an absolute managed input is refused" \
  "$(jget '.source_eligibility.reasons | index("SOURCE_DECLARATION_INCOMPLETE") != null')" "true"
jq '.managed_inputs = ["../elsewhere"]' "$KIT_DECL_ORIG" > "$CHECKOUT/lifecycle/kit.json"
run_afk status --json
assert_eq "a managed input escaping the checkout is refused" \
  "$(jget '.source_eligibility.reasons | index("SOURCE_DECLARATION_INCOMPLETE") != null')" "true"
jq '.managed_inputs = []' "$KIT_DECL_ORIG" > "$CHECKOUT/lifecycle/kit.json"
run_afk status --json
assert_eq "an empty managed-input declaration is refused" \
  "$(jget '.source_eligibility.reasons | index("SOURCE_DECLARATION_INCOMPLETE") != null')" "true"

# A declared input path containing a space stays ONE pathspec.
new_scenario spacedinput
install_kit "$HOMEDIR" "$CHECKOUT"
mkdir -p "$CHECKOUT/my inputs"
printf 'declared\n' > "$CHECKOUT/my inputs/thing.txt"
jq '.managed_inputs = ["files", "lifecycle", "my inputs"]' "$CHECKOUT/lifecycle/kit.json" \
  > "$CHECKOUT/lifecycle/kit.json.new"
mv "$CHECKOUT/lifecycle/kit.json.new" "$CHECKOUT/lifecycle/kit.json"
git_commit_all "$CHECKOUT" "declare a spaced input"
run_afk status --json
assert_eq "a spaced managed input is one declared path, not two" \
  "$(jget '.checkout.managed_inputs | length')" "3"
assert_eq "and it is present, so nothing is reported missing" \
  "$(jget '.source_eligibility.reasons | index("SOURCE_MANAGED_INPUT_MISSING") == null')" "true"
assert_eq "the clean checkout stays eligible" "$(jget '.source_eligibility.mutation_allowed')" "true"
printf 'dirty\n' > "$CHECKOUT/my inputs/scratch.txt"
run_afk status --json
assert_eq "dirt inside the spaced input is detected as managed dirt" \
  "$(jget '.source_eligibility.reasons | index("SOURCE_MANAGED_INPUT_DIRTY") != null')" "true"
rm -f "$CHECKOUT/my inputs/scratch.txt"

# --- dirty managed inputs block; dirt outside the input set does not -------
new_scenario dirty
install_kit "$HOMEDIR" "$CHECKOUT"
write_manifest
printf 'scratch\n' > "$CHECKOUT/files/scratch-dirty.txt"
run_afk status --json
assert_eq "an uncommitted managed input blocks mutation" \
  "$(jget '.source_eligibility.mutation_allowed')" "false"
assert_eq "with its own stable reason" \
  "$(jget '.source_eligibility.reasons | index("SOURCE_MANAGED_INPUT_DIRTY") != null')" "true"
# The frozen independence requirement: an ineligible source must not corrupt a
# separately verified installation.
assert_eq "installed state stays healthy while the source is ineligible" \
  "$(jget '.installed.state')" "CURRENT"
assert_eq "installed integrity stays READY" "$(jget '.readiness.INSTALLED_INTEGRITY.state')" "READY"
assert_eq "mutation-source eligibility is separately FALSE" \
  "$(jget '.readiness.MUTATION_SOURCE_ELIGIBLE.state')" "FALSE"
assert_eq "every source finding is scoped to MUTATION_SOURCE only" \
  "$(printf '%s' "$RUN_OUT" | jq -r '[.findings[] | select(.ownership == "CANONICAL_SOURCE")
     | select(.blocked_scopes != ["MUTATION_SOURCE"])] | length')" "0"
assert_ne "overall is not BROKEN"    "$(jget '.overall.state')" "BROKEN"
assert_ne "overall is not NOT_READY" "$(jget '.overall.state')" "NOT_READY"
assert_eq "and status still exits successfully" "$RUN_RC" "0"
# The same state, with eligibility made part of the requested scope.
run_afk status --json --require-source-eligible
assert_eq "eligibility in the requested scope exits 4 (source refusal)" "$RUN_RC" "4"
rm -f "$CHECKOUT/files/scratch-dirty.txt"

printf 'notes\n' > "$CHECKOUT/NOTES.md"
run_afk status --json
assert_eq "dirt outside the input set does not block mutation" \
  "$(jget '.source_eligibility.mutation_allowed')" "true"
assert_eq "but is still reported" \
  "$(jget '.source_eligibility.reasons | index("SOURCE_DIRT_OUTSIDE_INPUT_SET") != null')" "true"
rm -f "$CHECKOUT/NOTES.md"

# --- unexpected revisions, downgrade and divergence ------------------------
new_scenario revisions
install_kit "$HOMEDIR" "$CHECKOUT"
write_manifest
OLD_SHA="$(git -C "$CHECKOUT" rev-parse HEAD)"
printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
git_commit_all "$CHECKOUT" "canonical v2"
NEW_SHA="$(git -C "$CHECKOUT" rev-parse HEAD)"

run_afk status --json
assert_eq "a newer canonical revision is an ordinary update" \
  "$(jget '.source_eligibility.revision_relation')" "AHEAD"
assert_eq "and the source stays eligible" "$(jget '.source_eligibility.mutation_allowed')" "true"
assert_eq "the component reports UPDATE_AVAILABLE" \
  "$(component_field model-router .state)" "UPDATE_AVAILABLE"
assert_eq "with a stable reason" \
  "$(component_field model-router .reason)" "CANONICAL_REVISION_AHEAD"
assert_eq "update availability is a warning, not a failure" "$RUN_RC" "0"
assert_contains "and the next safe action says so" "$(jget '.next_safe_action')" "Canonical content is ahead"

# Now pretend the newer revision was applied and the checkout sits at the old
# one: that is a rollback, never an ordinary update.
manifest_patch ".applied_revision = \"$NEW_SHA\""
git -C "$CHECKOUT" checkout -q "$OLD_SHA" >/dev/null 2>&1
run_afk status --json
assert_eq "an older source is a downgrade, not an update" \
  "$(jget '.source_eligibility.revision_relation')" "BEHIND"
assert_eq "downgrade blocks unattended mutation" \
  "$(jget '.source_eligibility.mutation_allowed')" "false"
assert_eq "with its own reason" \
  "$(jget '.source_eligibility.reasons | index("SOURCE_DOWNGRADE_REQUIRES_INTENT") != null')" "true"
assert_eq "a detached HEAD is reported too" \
  "$(jget '.source_eligibility.reasons | index("SOURCE_DETACHED_HEAD") != null')" "true"
run_afk status --json --allow-rollback --allow-noncanonical-source
assert_eq "explicit intent unblocks it" "$(jget '.source_eligibility.mutation_allowed')" "true"
assert_eq "and the intent is recorded, not forgotten" \
  "$(jget '.source_eligibility.explicit_intent.allow_rollback')" "true"
assert_eq "the reason is still retained as evidence" \
  "$(jget '.source_eligibility.reasons | index("SOURCE_DOWNGRADE_REQUIRES_INTENT") != null')" "true"

git -C "$CHECKOUT" checkout -q master >/dev/null 2>&1
git -C "$CHECKOUT" checkout -q -b sidebranch >/dev/null 2>&1
run_afk status --json
assert_eq "a non-default branch is noncanonical" \
  "$(jget '.source_eligibility.reasons | index("SOURCE_NONCANONICAL_BRANCH") != null')" "true"
assert_eq "and blocks unattended mutation" "$(jget '.source_eligibility.mutation_allowed')" "false"
git -C "$CHECKOUT" checkout -q master >/dev/null 2>&1

manifest_patch '.applied_revision = "0000000000000000000000000000000000000000"'
run_afk status --json
assert_eq "an unreachable applied revision is refused, not guessed" \
  "$(jget '.source_eligibility.reasons | index("APPLIED_REVISION_UNREACHABLE") != null')" "true"

manifest_patch ".applied_revision = \"$NEW_SHA\" | .repository.identity = \"rootcommit:deadbeef\""
run_afk status --json
assert_eq "a different repository identity is refused as a source" \
  "$(jget '.source_eligibility.reasons | index("SOURCE_REPOSITORY_MISMATCH") != null')" "true"

# --- a divergent applied revision is neither ahead nor behind --------------
new_scenario diverged
install_kit "$HOMEDIR" "$CHECKOUT"
write_manifest
git -C "$CHECKOUT" checkout -q -b sideline >/dev/null 2>&1
printf 'sideline content\n' > "$CHECKOUT/files/model-router/SKILL.md"
git_commit_all "$CHECKOUT" "sideline v2"
SIDE_SHA="$(git -C "$CHECKOUT" rev-parse HEAD)"
git -C "$CHECKOUT" checkout -q master >/dev/null 2>&1
printf 'humanizer v2\n' > "$CHECKOUT/files/humanizer/SKILL.md"
git_commit_all "$CHECKOUT" "master v2"
manifest_patch ".applied_revision = \"$SIDE_SHA\""
run_afk status --json
assert_eq "an applied revision on another line of history is DIVERGED" \
  "$(jget '.source_eligibility.revision_relation')" "DIVERGED"
assert_eq "divergence blocks unattended mutation" \
  "$(jget '.source_eligibility.mutation_allowed')" "false"
assert_eq "with its own stable reason" \
  "$(jget '.source_eligibility.reasons | index("SOURCE_REVISION_UNEXPECTED") != null')" "true"
run_afk status --json --allow-noncanonical-source
assert_eq "explicit intent unblocks divergence too" \
  "$(jget '.source_eligibility.mutation_allowed')" "true"

# --- a declared managed input that is absent from the source --------------
new_scenario missinginput
install_kit "$HOMEDIR" "$CHECKOUT"
write_manifest
rm -rf "$CHECKOUT/files"
run_afk status --json
assert_eq "an absent declared managed input is reported" \
  "$(jget '.source_eligibility.reasons | index("SOURCE_MANAGED_INPUT_MISSING") != null')" "true"
assert_eq "and blocks mutation" "$(jget '.source_eligibility.mutation_allowed')" "false"
# The canonical side is now unreadable. Matching the applied identity proves
# nothing about currency, so this is never CURRENT.
assert_eq "an unreadable canonical side is not CURRENT" \
  "$(component_field codex-global-guidance .state)" "UNKNOWN"
assert_eq "with its own stable reason" \
  "$(component_field codex-global-guidance .reason)" "CANONICAL_IDENTITY_UNREADABLE"
assert_eq "and it is not mutation-safe" \
  "$(component_field codex-global-guidance .mutation_safe)" "false"
assert_eq "the managed tree is not CURRENT either" \
  "$(component_field model-router .state)" "UNKNOWN"
assert_eq "no source-derived component claims to be CURRENT" \
  "$(printf '%s' "$RUN_OUT" | jq -r '[.components[] | select(.state == "CURRENT") | .id]
     | map(select(. == "model-router" or . == "humanizer"
                  or . == "codex-global-guidance" or . == "claude-global-policy"))
     | length')" "0"
assert_eq "installed integrity is still reported independently" \
  "$(jget '.readiness.INSTALLED_INTEGRITY.state')" "READY"

# --- status never changes Git ---------------------------------------------
new_scenario nogitmutation
install_kit "$HOMEDIR" "$CHECKOUT"
GIT_ID_BEFORE="$(fingerprint_git_identity "$CHECKOUT")"
GIT_HEAD_BEFORE="$(git -C "$CHECKOUT" rev-parse HEAD)"
GIT_BRANCH_BEFORE="$(git -C "$CHECKOUT" rev-parse --abbrev-ref HEAD)"
run_afk status --json
run_afk adopt --inspect --json
assert_eq "HEAD is unchanged"   "$(git -C "$CHECKOUT" rev-parse HEAD)" "$GIT_HEAD_BEFORE"
assert_eq "branch is unchanged" "$(git -C "$CHECKOUT" rev-parse --abbrev-ref HEAD)" "$GIT_BRANCH_BEFORE"
assert_eq "refs, reachable objects and working state are all unchanged" \
  "$(fingerprint_git_identity "$CHECKOUT")" "$GIT_ID_BEFORE"

# --- an incompatible source lifecycle schema refuses ----------------------
new_scenario futureschema
rm -rf "$CHECKOUT"; mkdir -p "$CHECKOUT"
make_checkout "$CHECKOUT" "2.0"
install_kit "$HOMEDIR" "$CHECKOUT"
run_afk status --json
assert_eq "a newer major lifecycle schema in the source is refused" \
  "$(jget '.source_eligibility.reasons | index("SOURCE_LIFECYCLE_SCHEMA_INCOMPATIBLE") != null')" "true"
assert_eq "and blocks mutation" "$(jget '.source_eligibility.mutation_allowed')" "false"

new_scenario pastschema
rm -rf "$CHECKOUT"; mkdir -p "$CHECKOUT"
make_checkout "$CHECKOUT" "0.9"
install_kit "$HOMEDIR" "$CHECKOUT"
run_afk status --json
assert_eq "an OLDER major lifecycle schema is refused just as firmly" \
  "$(jget '.source_eligibility.reasons | index("SOURCE_LIFECYCLE_SCHEMA_INCOMPATIBLE") != null')" "true"

# ===========================================================================
head1 "3. Unknown / legacy host and inspect-only adoption"
# ===========================================================================

new_scenario legacy
install_kit "$HOMEDIR" "$CHECKOUT"
run_afk status --json
assert_eq "an unadopted host is not adopted" "$(jget '.installed.adopted')" "false"
assert_eq "installed state is UNKNOWN"       "$(jget '.installed.state')" "UNKNOWN"
assert_eq "every component is UNKNOWN/NOT_ADOPTED" \
  "$(component_field model-router .reason)" "NOT_ADOPTED"
assert_eq "an unadopted installation is deterministically not ready" "$RUN_RC" "3"
assert_eq "overall says so"                  "$(jget '.overall.state')" "NOT_READY"
assert_contains "and names the next safe action" "$(jget '.next_safe_action')" "adopt --inspect"

HOME_FP_BEFORE="$(fingerprint_tree "$HOMEDIR")"
run_afk adopt --inspect --json
ADOPT_FIRST="$RUN_OUT"
assert_eq "an exactly canonical legacy install is auto-adoptable" \
  "$(jget '.extra.adoption.disposition')" "AUTO_ADOPTABLE"
assert_eq "and exits successfully" "$RUN_RC" "0"
assert_eq "inspection declares itself inspect-only" "$(jget '.extra.adoption.inspect_only')" "true"
assert_eq "no mutation was performed"  "$(jget '.extra.adoption.mutation_performed')" "false"
assert_eq "no manifest was created"    "$(jget '.extra.adoption.manifest_created')" "false"
assert_eq "no ownership was claimed"   "$(jget '.extra.adoption.ownership_claimed')" "false"
assert_eq "no revision advanced"       "$(jget '.extra.adoption.applied_revision_advanced')" "false"
assert_eq "the managed copy matches current canonical content" \
  "$(adoption_field model-router reason)" "EXACT_CANONICAL"
assert_eq "the managed section matches current canonical content" \
  "$(adoption_field claude-global-policy reason)" "EXACT_CANONICAL"
assert_eq "machine-local state is adoptable by ownership rule" \
  "$(adoption_field model-router-config reason)" "MACHINE_OWNED_REGION"
assert_eq "recognized wiring is adoptable" \
  "$(adoption_field model-router-claude-link reason)" "EXACT_RECOGNIZED_WIRING"
assert_no_file "no state manifest appeared"  "$HOMEDIR/$STATE_DIR_REL/state.json"
assert_no_file "no state directory appeared" "$HOMEDIR/$STATE_DIR_REL"

run_afk adopt --inspect --json
assert_eq "repeated analysis is byte-identical" "$RUN_OUT" "$ADOPT_FIRST"
assert_eq "and still mutates nothing" "$(fingerprint_tree "$HOMEDIR")" "$HOME_FP_BEFORE"

# Every reported disposition is inside the frozen vocabulary.
assert_eq "dispositions stay inside the frozen set" \
  "$(printf '%s' "$RUN_OUT" | jq -r '[.extra.adoption.components[].classification]
      | map(select(. != "AUTO_ADOPTABLE" and . != "APPROVAL_REQUIRED"
                   and . != "REFUSED" and . != "NOT_INSTALLED")) | length')" "0"

# --- legacy recognition: installed content matches a PRIOR canonical rev ---
new_scenario legacyprior
install_kit "$HOMEDIR" "$CHECKOUT"
printf 'codex guidance v2\n' > "$CHECKOUT/files/codex-AGENTS.md"
printf 'policy line one\npolicy line two\npolicy line three\n' > "$CHECKOUT/files/claude-global-CLAUDE.md"
printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
git_commit_all "$CHECKOUT" "canonical v2"
run_afk adopt --inspect --json
assert_eq "a recognized prior canonical file is still auto-adoptable" \
  "$(adoption_field codex-global-guidance reason)" "RECOGNIZED_PRIOR_CANONICAL"
assert_eq "a recognized prior canonical section is still auto-adoptable" \
  "$(adoption_field claude-global-policy reason)" "RECOGNIZED_PRIOR_CANONICAL"
# Trees are recognized from Git objects, with the machine-owned member excluded
# on both sides, so a legacy managed copy is not stranded at APPROVAL_REQUIRED
# just because it is a directory.
assert_eq "a recognized prior canonical TREE is auto-adoptable too" \
  "$(adoption_field model-router reason)" "RECOGNIZED_PRIOR_CANONICAL"
assert_eq "the whole analysis stays auto-adoptable" \
  "$(jget '.extra.adoption.disposition')" "AUTO_ADOPTABLE"

# Recognition is not a bounded window: many later commits must not push a
# still-recognizable revision out of view.
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  printf 'filler %s\n' "$i" > "$CHECKOUT/FILLER.md"
  printf 'humanizer v%s\n' "$i" > "$CHECKOUT/files/humanizer/SKILL.md"
  git_commit_all "$CHECKOUT" "filler $i"
done
run_afk adopt --inspect --json
assert_eq "recognition survives a long later history (file)" \
  "$(adoption_field codex-global-guidance reason)" "RECOGNIZED_PRIOR_CANONICAL"
assert_eq "recognition survives a long later history (tree)" \
  "$(adoption_field model-router reason)" "RECOGNIZED_PRIOR_CANONICAL"

# --- unrecognized content needs an owner, and never auto-adopts -----------
new_scenario legacyunknown
install_kit "$HOMEDIR" "$CHECKOUT"
printf 'hand-written local guidance nobody recorded\n' > "$HOMEDIR/.codex/AGENTS.md"
run_afk adopt --inspect --json
assert_eq "unrecognized content requires approval" \
  "$(adoption_field codex-global-guidance classification)" "APPROVAL_REQUIRED"
assert_eq "with a stable reason" \
  "$(adoption_field codex-global-guidance reason)" "UNRECOGNIZED_CONTENT"
assert_eq "and the aggregate is APPROVAL_REQUIRED" \
  "$(jget '.extra.adoption.disposition')" "APPROVAL_REQUIRED"
assert_eq "which is an owner-action exit" "$RUN_RC" "2"
assert_no_file "still no manifest" "$HOMEDIR/$STATE_DIR_REL/state.json"

# --- a redirected path refuses outright -----------------------------------
new_scenario legacyrefuse
install_kit "$HOMEDIR" "$CHECKOUT"
mkdir -p "$SC/elsewhere"
printf 'redirected\n' > "$SC/elsewhere/stolen.md"
rm -f "$HOMEDIR/.codex/AGENTS.md"
ln -s "$SC/elsewhere/stolen.md" "$HOMEDIR/.codex/AGENTS.md"
run_afk adopt --inspect --json
assert_eq "an unexpectedly redirected destination refuses adoption" \
  "$(adoption_field codex-global-guidance classification)" "REFUSED"
assert_eq "and the aggregate refuses"    "$(jget '.extra.adoption.disposition')" "REFUSED"
assert_eq "which is an owner-action exit" "$RUN_RC" "2"

# --- an ineligible source cannot be adopted from --------------------------
new_scenario adoptineligible
install_kit "$HOMEDIR" "$CHECKOUT"
printf 'scratch\n' > "$CHECKOUT/files/scratch-dirty.txt"
run_afk adopt --inspect --json
assert_eq "an ineligible mutation source refuses adoption analysis" \
  "$(jget '.extra.adoption.disposition')" "REFUSED"
assert_eq "with its own stable reason" \
  "$(adoption_field installation reason)" "ADOPTION_SOURCE_INELIGIBLE"
assert_eq "which is an owner-action exit" "$RUN_RC" "2"
assert_no_file "and nothing was written" "$HOMEDIR/$STATE_DIR_REL"
rm -f "$CHECKOUT/files/scratch-dirty.txt"
run_afk adopt --inspect --json
assert_eq "once the source is eligible again the analysis proceeds" \
  "$(jget '.extra.adoption.disposition')" "AUTO_ADOPTABLE"

# --- an already-adopted host is not an adoption candidate -----------------
new_scenario alreadyadopted
install_kit "$HOMEDIR" "$CHECKOUT"
write_manifest
run_afk adopt --inspect --json
assert_eq "an adopted installation refuses adoption analysis" \
  "$(jget '.extra.adoption.disposition')" "REFUSED"
assert_eq "with a stable reason" \
  "$(adoption_field installation reason)" "ADOPTION_NOT_APPLICABLE_ALREADY_ADOPTED"

# ===========================================================================
head1 "4. Ownership and state branches on an adopted host"
# ===========================================================================

new_scenario adopted
install_kit "$HOMEDIR" "$CHECKOUT"
write_manifest
run_afk status --json
assert_eq "an unchanged adopted host is CURRENT" "$(jget '.installed.state')" "CURRENT"
assert_eq "overall READY"                        "$(jget '.overall.state')" "READY"
assert_eq "exit 0"                               "$RUN_RC" "0"
assert_eq "the applied revision is recorded"     "$(jget '.installed.applied_revision')" \
  "$(git -C "$CHECKOUT" rev-parse HEAD)"
assert_eq "managed copy tree CURRENT" "$(component_field model-router .state)" "CURRENT"
assert_eq "managed copy file CURRENT" "$(component_field codex-global-guidance .state)" "CURRENT"
assert_eq "managed section CURRENT"   "$(component_field claude-global-policy .state)" "CURRENT"
assert_eq "managed link CURRENT"      "$(component_field model-router-claude-link .state)" "CURRENT"
assert_eq "every component carries an ownership class" \
  "$(printf '%s' "$RUN_OUT" | jq -r '[.components[] | select(.ownership == null)] | length')" "0"
assert_eq "every component carries an integrity identity or a reason" \
  "$(printf '%s' "$RUN_OUT" | jq -r '[.components[] | select(.evidence.observed == null and .reason == null)] | length')" "0"

# Independently computed identity: the manifest is not merely echoing itself.
assert_eq "the recorded file identity is a real content hash" \
  "$(component_field codex-global-guidance .evidence.observed)" \
  "sha256:$(hash_of_file "$HOMEDIR/.codex/AGENTS.md")"

# --- machine-owned and user-owned differences are legitimate, never drift --
printf 'launcher:\n  router_endpoint: https://this-host.invalid\n' \
  > "$HOMEDIR/.agents/skills/model-router/subscriptions.yaml"
printf '\n# another note I added myself\n' >> "$HOMEDIR/.claude/CLAUDE.md"
run_afk status --json
assert_eq "machine-owned config is LOCAL_ADAPTATION by ownership rule" \
  "$(component_field model-router-config .state)" "LOCAL_ADAPTATION"
assert_eq "with an ownership-rule provenance, not a judgement call" \
  "$(component_field model-router-config .evidence.provenance)" "OWNERSHIP_RULE"
assert_eq "and the managed tree is unaffected by it" \
  "$(component_field model-router .state)" "CURRENT"
assert_eq "user content outside the section is EXTERNAL_STATE" \
  "$(component_field 'claude-global-policy:outside-section' .state)" "EXTERNAL_STATE"
assert_eq "the managed section itself stays CURRENT" \
  "$(component_field claude-global-policy .state)" "CURRENT"
assert_eq "and neither is kit drift" "$(jget '.overall.state')" "READY"
assert_eq "user-owned content is reported by shape, not by content" \
  "$(component_field 'claude-global-policy:outside-section' '.evidence.observed | test("lines outside")')" "true"

# --- unexplained difference in kit-owned territory is LOCAL_DRIFT ---------
new_scenario drift
install_kit "$HOMEDIR" "$CHECKOUT"
write_manifest
printf 'edited by hand\n' >> "$HOMEDIR/.agents/skills/model-router/SKILL.md"
run_afk status --json
assert_eq "an unexplained managed edit is LOCAL_DRIFT" \
  "$(component_field model-router .state)" "LOCAL_DRIFT"
assert_eq "with a stable reason" \
  "$(component_field model-router .reason)" "UNEXPLAINED_MANAGED_DIFFERENCE"
assert_eq "it is not mutation-safe" "$(component_field model-router .mutation_safe)" "false"
assert_eq "it demands owner action" "$(component_field model-router .owner_action_required)" "true"
assert_eq "it blocks installed integrity" \
  "$(component_field model-router '.blocked_scopes | index("INSTALLED_INTEGRITY") != null')" "true"
assert_eq "overall NEEDS_OWNER"   "$(jget '.overall.state')" "NEEDS_OWNER"
assert_eq "exit 2 (owner action)" "$RUN_RC" "2"
assert_eq "expected and observed identities are both reported" \
  "$(printf '%s' "$RUN_OUT" | jq -r '[.findings[] | select(.reason == "UNEXPLAINED_MANAGED_DIFFERENCE")
     | select(.evidence.expected != null and .evidence.observed != null)] | length')" "1"

# A NON-critical component's drift is scoped to itself (FR-19, FR-21).
new_scenario driftnoncritical
install_kit "$HOMEDIR" "$CHECKOUT"
write_manifest
printf 'edited by hand\n' >> "$HOMEDIR/.agents/skills/humanizer/SKILL.md"
run_afk status --json
assert_eq "non-critical drift is still LOCAL_DRIFT" \
  "$(component_field humanizer .state)" "LOCAL_DRIFT"
assert_eq "and still refuses to be overwritten" \
  "$(component_field humanizer .mutation_safe)" "false"
assert_eq "but does not poison host readiness" \
  "$(component_field humanizer '.blocked_scopes | index("INSTALLED_INTEGRITY") == null')" "true"
assert_eq "overall stays a success with warnings" "$(jget '.overall.state')" "READY_WITH_WARNINGS"
assert_eq "and exits 0" "$RUN_RC" "0"

# --- a managed link pointing somewhere unexpected INSIDE its boundary -----
new_scenario linktarget
install_kit "$HOMEDIR" "$CHECKOUT"
write_manifest
rm -f "$HOMEDIR/.claude/skills/model-router"
ln -s "$HOMEDIR/.agents/skills/humanizer" "$HOMEDIR/.claude/skills/model-router"
run_afk status --json
assert_eq "a link inside the boundary but pointing elsewhere passes the path guard" \
  "$(component_field model-router-claude-link '.reason | startswith("PATH_") | not')" "true"
assert_eq "and is LOCAL_DRIFT, not BROKEN" \
  "$(component_field model-router-claude-link .state)" "LOCAL_DRIFT"
assert_eq "with the link-specific reason" \
  "$(component_field model-router-claude-link .reason)" "LINK_TARGET_UNEXPECTED"
assert_eq "it is not mutation-safe" \
  "$(component_field model-router-claude-link .mutation_safe)" "false"
assert_eq "the resolved target is reported as evidence" \
  "$(component_field model-router-claude-link '.evidence.observed | startswith("link:")')" "true"
assert_eq "exit 2 (owner action, the link is execution critical)" "$RUN_RC" "2"

# --- BROKEN -------------------------------------------------------------
new_scenario broken
install_kit "$HOMEDIR" "$CHECKOUT"
write_manifest
rm -f "$HOMEDIR/.codex/AGENTS.md"
run_afk status --json
assert_eq "a missing non-critical component is BROKEN" \
  "$(component_field codex-global-guidance .state)" "BROKEN"
assert_eq "with a stable reason" \
  "$(component_field codex-global-guidance .reason)" "COMPONENT_MISSING"
assert_eq "scoped to itself, so the host is only warned" "$(jget '.overall.state')" "READY_WITH_WARNINGS"

rm -rf "$HOMEDIR/.agents/skills/model-router"
run_afk status --json
assert_eq "a missing execution-critical component is BROKEN" \
  "$(component_field model-router .state)" "BROKEN"
assert_eq "installed state is BROKEN" "$(jget '.installed.state')" "BROKEN"
assert_eq "overall NOT_READY"         "$(jget '.overall.state')" "NOT_READY"
assert_eq "exit 3 (deterministic not-ready)" "$RUN_RC" "3"

# --- a component installed but not recorded -------------------------------
new_scenario notrecorded
install_kit "$HOMEDIR" "$CHECKOUT"
write_manifest
manifest_patch 'del(.components["humanizer"])'
run_afk status --json
assert_eq "an unrecorded component is UNKNOWN" "$(component_field humanizer .state)" "UNKNOWN"
assert_eq "with a stable reason" "$(component_field humanizer .reason)" "COMPONENT_NOT_RECORDED"
assert_eq "and is not mutation-safe" "$(component_field humanizer .mutation_safe)" "false"

# --- an unreadable managed member is BROKEN, never quietly hashed ---------
new_scenario unreadablemember
install_kit "$HOMEDIR" "$CHECKOUT"
write_manifest
printf 'locked content\n' > "$HOMEDIR/.agents/skills/humanizer/locked.md"
chmod 000 "$HOMEDIR/.agents/skills/humanizer/locked.md" 2>/dev/null
if cat "$HOMEDIR/.agents/skills/humanizer/locked.md" >/dev/null 2>&1; then
  skip "unreadable managed member (this user can read a mode-000 file)"
else
  run_afk status --json
  assert_eq "an unreadable member makes the component BROKEN" \
    "$(component_field humanizer .state)" "BROKEN"
  assert_eq "with a stable reason" \
    "$(component_field humanizer .reason)" "IDENTITY_UNREADABLE"
  assert_eq "and no identity is reported for it" \
    "$(component_field humanizer .evidence.observed)" "null"
fi
chmod 644 "$HOMEDIR/.agents/skills/humanizer/locked.md" 2>/dev/null

# ===========================================================================
head1 "5. Registered adaptations, revalidated every time"
# ===========================================================================

new_scenario adaptation
install_kit "$HOMEDIR" "$CHECKOUT"
write_manifest
MR_DEST="$HOMEDIR/.agents/skills/model-router"
CGP_DEST="$HOMEDIR/.claude/CLAUDE.md"
printf 'a deliberate local patch\n' >> "$MR_DEST/SKILL.md"
run_afk status --json
assert_eq "before registration the difference is drift" \
  "$(component_field model-router .state)" "LOCAL_DRIFT"
ADAPTED_ID="$(component_field model-router .evidence.observed)"

manifest_patch ".adaptations = [{
  id: \"local-patch-1\",
  component: \"model-router\",
  location: \"$MR_DEST\",
  type: \"tree-content\",
  reason: \"host-specific note appended by the owner\",
  expected_identity: \"$ADAPTED_ID\",
  disposition: \"PRESERVE\"
}]"
run_afk status --json
assert_eq "a valid registered adaptation legitimizes the difference" \
  "$(component_field model-router .state)" "LOCAL_ADAPTATION"
assert_eq "with the adaptation-record provenance" \
  "$(component_field model-router .evidence.provenance)" "ADAPTATION_RECORD"
assert_eq "and names the record" "$(component_field model-router .adaptation)" "local-patch-1"
assert_eq "the record is reported as matched" \
  "$(printf '%s' "$RUN_OUT" | jq -r '.adaptations[] | select(.id == "local-patch-1") | .state')" "VALID_MATCHED"
assert_eq "overall READY_WITH_ADAPTATION" "$(jget '.overall.state')" "READY_WITH_ADAPTATION"
assert_eq "which is a success" "$RUN_RC" "0"

# A stale record legitimizes nothing.
manifest_patch '.adaptations[0].expected_identity = "sha256:0000000000000000000000000000000000000000000000000000000000000000"'
run_afk status --json
assert_eq "a stale adaptation cannot legitimize the difference" \
  "$(component_field model-router .state)" "LOCAL_DRIFT"
assert_eq "and the record is reported STALE" \
  "$(printf '%s' "$RUN_OUT" | jq -r '.adaptations[] | select(.id == "local-patch-1") | .state')" "STALE"
assert_eq "with its own finding" "$(has_finding_reason ADAPTATION_STALE)" "1"
assert_eq "exit 2" "$RUN_RC" "2"

# Malformed / unknown / invalid records are rejected structurally.
manifest_patch '.adaptations = [{id: "no-fields"}]'
run_afk status --json
assert_eq "a record missing required fields is INVALID" \
  "$(printf '%s' "$RUN_OUT" | jq -r '.adaptations[0].state')" "INVALID"
assert_eq "with a stable reason" "$(has_finding_reason ADAPTATION_MALFORMED)" "1"

manifest_patch ".adaptations = [{id: \"ghost\", component: \"not-a-component\",
  location: \"$MR_DEST\", type: \"tree-content\", reason: \"r\",
  expected_identity: \"$ADAPTED_ID\", disposition: \"PRESERVE\"}]"
run_afk status --json
assert_eq "a record naming an undeclared component is rejected" \
  "$(has_finding_reason ADAPTATION_UNKNOWN_COMPONENT)" "1"

manifest_patch ".adaptations = [{id: \"baddisp\", component: \"model-router\",
  location: \"$MR_DEST\", type: \"tree-content\", reason: \"r\",
  expected_identity: \"$ADAPTED_ID\", disposition: \"IGNORE_FOREVER\"}]"
run_afk status --json
assert_eq "an unsupported disposition is rejected" \
  "$(has_finding_reason ADAPTATION_INVALID_DISPOSITION)" "1"

# The bindings that make a record falsifiable: id uniqueness, the type its
# ownership class can have, the component's declared location, and an expected
# identity in the right shape. A record loose in any of these would legitimize
# whatever happens to be installed.
manifest_patch ".adaptations = [
  {id: \"dup\", component: \"model-router\", location: \"$MR_DEST\", type: \"tree-content\",
   reason: \"r\", expected_identity: \"$ADAPTED_ID\", disposition: \"PRESERVE\"},
  {id: \"dup\", component: \"model-router\", location: \"$MR_DEST\", type: \"tree-content\",
   reason: \"r\", expected_identity: \"$ADAPTED_ID\", disposition: \"PRESERVE\"}]"
run_afk status --json
assert_eq "a duplicated adaptation id is rejected" \
  "$(has_finding_reason ADAPTATION_DUPLICATE_ID)" "1"

manifest_patch ".adaptations = [{id: \"wrongtype\", component: \"model-router\",
  location: \"$MR_DEST\", type: \"link-target\", reason: \"r\",
  expected_identity: \"$ADAPTED_ID\", disposition: \"PRESERVE\"}]"
run_afk status --json
assert_eq "a type that does not belong to the ownership class is rejected" \
  "$(has_finding_reason ADAPTATION_TYPE_MISMATCH)" "1"
assert_eq "and legitimizes nothing" "$(component_field model-router .state)" "LOCAL_DRIFT"

manifest_patch ".adaptations = [{id: \"wrongloc\", component: \"model-router\",
  location: \"/somewhere/else\", type: \"tree-content\", reason: \"r\",
  expected_identity: \"$ADAPTED_ID\", disposition: \"PRESERVE\"}]"
run_afk status --json
assert_eq "a location that is not the component's declared location is rejected" \
  "$(has_finding_reason ADAPTATION_LOCATION_MISMATCH)" "1"
assert_eq "and legitimizes nothing" "$(component_field model-router .state)" "LOCAL_DRIFT"

manifest_patch ".adaptations = [{id: \"badshape\", component: \"model-router\",
  location: \"$MR_DEST\", type: \"tree-content\", reason: \"r\",
  expected_identity: \"whatever-is-there\", disposition: \"PRESERVE\"}]"
run_afk status --json
assert_eq "an expected identity in the wrong shape is rejected" \
  "$(has_finding_reason ADAPTATION_EXPECTED_SHAPE_INVALID)" "1"

# A managed section declares its location as <file>#<section-id>.
manifest_patch ".adaptations = [{id: \"sectionloc\", component: \"claude-global-policy\",
  location: \"$CGP_DEST\", type: \"section-payload\", reason: \"r\",
  expected_identity: \"sha256:0000000000000000000000000000000000000000000000000000000000000000\",
  disposition: \"PRESERVE\"}]"
run_afk status --json
assert_eq "a section record without its section id is a location mismatch" \
  "$(has_finding_reason ADAPTATION_LOCATION_MISMATCH)" "1"
manifest_patch ".adaptations[0].location = \"$CGP_DEST#claude-global-policy\""
run_afk status --json
assert_eq "with the declared section location it is structurally valid" \
  "$(has_finding_reason ADAPTATION_LOCATION_MISMATCH)" "0"
assert_eq "though it is stale against what is installed" \
  "$(has_finding_reason ADAPTATION_STALE)" "1"

# OWNER_REVIEW is honoured as declared.
manifest_patch ".adaptations = [{
  id: \"needs-review\", component: \"model-router\", location: \"$MR_DEST\",
  type: \"tree-content\", reason: \"owner wants to look at this\",
  expected_identity: \"$ADAPTED_ID\", disposition: \"OWNER_REVIEW\"
}]"
run_afk status --json
assert_eq "an OWNER_REVIEW adaptation is still recognized" \
  "$(component_field model-router .state)" "LOCAL_ADAPTATION"
assert_eq "but is not mutation-safe" "$(component_field model-router .mutation_safe)" "false"
assert_eq "and says why"             "$(component_field model-router .reason)" "ADAPTATION_OWNER_REVIEW"

# An adaptation whose component cannot be observed at all cannot be revalidated.
rm -rf "$HOMEDIR/.agents/skills/model-router"
run_afk status --json
assert_eq "an unobservable component makes its adaptation unrevalidatable" \
  "$(has_finding_reason ADAPTATION_TARGET_UNOBSERVABLE)" "1"

# ===========================================================================
head1 "6. Manifest schema compatibility, shape and interrupted operations"
# ===========================================================================

new_scenario schemas
install_kit "$HOMEDIR" "$CHECKOUT"
write_manifest

manifest_patch '.state_schema_version = "2.0"'
run_afk status --json
assert_eq "an unknown newer major state schema refuses" "$(jget '.installed.state')" "INCOMPATIBLE"
assert_eq "with a stable reason"  "$(has_finding_reason STATE_SCHEMA_UNKNOWN_MAJOR)" "1"
assert_eq "and requires an owner" "$(jget '.overall.state')" "NEEDS_OWNER"
assert_eq "exit 2"                "$RUN_RC" "2"

manifest_patch '.state_schema_version = "0.9"'
run_afk status --json
assert_eq "a recognized older schema is usable but flagged for migration" \
  "$(has_finding_reason STATE_SCHEMA_MIGRATION_REQUIRED)" "1"
assert_eq "and the installation stays readable" "$(jget '.installed.adopted')" "true"
assert_eq "exiting successfully with a warning" "$RUN_RC" "0"

printf 'this is not json at all\n' > "$HOMEDIR/$STATE_DIR_REL/state.json"
run_afk status --json
assert_eq "an unrecognized manifest shape yields an owner decision" \
  "$(has_finding_reason STATE_SCHEMA_UNRECOGNIZED)" "1"
assert_eq "overall NEEDS_OWNER" "$(jget '.overall.state')" "NEEDS_OWNER"
assert_eq "exit 2"              "$RUN_RC" "2"

# The complete shape is validated before the manifest is treated as adopted.
new_scenario manifestshape
install_kit "$HOMEDIR" "$CHECKOUT"
for broken in 'del(.applied_revision)' 'del(.repository)' '.repository.identity = 42' \
              'del(.components)' '.components = []' '.adaptations = {}' \
              '.targets = "none"' '.applied_revision = "not-a-sha"' \
              '.components["model-router"].identity = null' \
              '.targets = [{path: "/tmp/afk-target"}]'; do
  write_manifest
  manifest_patch "$broken"
  run_afk status --json
  if [[ "$(has_finding_reason STATE_MANIFEST_SHAPE_INVALID)" == "1" ]]; then
    ok "an invalid manifest shape is refused: $broken"
  else
    bad "an invalid manifest shape is refused: $broken" \
      "adopted=$(jget '.installed.adopted') state=$(jget '.installed.state')"
  fi
  assert_eq "and it is never treated as adopted: $broken" "$(jget '.installed.adopted')" "false"
done

# The manifest path itself is guarded before it is read.
new_scenario manifestpath
install_kit "$HOMEDIR" "$CHECKOUT"
write_manifest
mkdir -p "$SC/elsewhere"
mv "$HOMEDIR/$STATE_DIR_REL/state.json" "$SC/elsewhere/state.json"
ln -s "$SC/elsewhere/state.json" "$HOMEDIR/$STATE_DIR_REL/state.json"
run_afk status --json
assert_eq "a manifest redirected out of the state directory is refused" \
  "$(has_finding_reason STATE_MANIFEST_PATH_UNSAFE)" "1"
assert_eq "and is never treated as adopted" "$(jget '.installed.adopted')" "false"
assert_eq "which requires an owner" "$(jget '.overall.state')" "NEEDS_OWNER"

# --- the operation journal ------------------------------------------------
new_scenario interrupted
install_kit "$HOMEDIR" "$CHECKOUT"
write_manifest
printf '{"state": "IN_PROGRESS", "operation_id": "op-1"}\n' > "$HOMEDIR/$STATE_DIR_REL/journal.json"
run_afk status --json
assert_eq "an open journal makes the installation INTERRUPTED" \
  "$(jget '.installed.state')" "INTERRUPTED"
assert_eq "read-only status never calls that stably healthy" \
  "$(jget '.overall.state')" "NEEDS_OWNER"
assert_eq "with a stable reason" "$(has_finding_reason OPERATION_INTERRUPTED)" "1"
assert_eq "exit 2"               "$RUN_RC" "2"
printf '{"state": "COMMITTED", "operation_id": "op-1"}\n' > "$HOMEDIR/$STATE_DIR_REL/journal.json"
run_afk status --json
assert_eq "a committed journal is not an interruption" "$(jget '.installed.state')" "CURRENT"

printf 'not json\n' > "$HOMEDIR/$STATE_DIR_REL/journal.json"
run_afk status --json
assert_eq "an unparseable journal proves nothing was completed" \
  "$(jget '.installed.journal_state')" "UNREADABLE"
assert_eq "with its own stable reason" "$(has_finding_reason OPERATION_JOURNAL_UNREADABLE)" "1"
assert_eq "and the installation is INTERRUPTED, not healthy" \
  "$(jget '.installed.state')" "INTERRUPTED"

rm -f "$HOMEDIR/$STATE_DIR_REL/journal.json"
mkdir -p "$HOMEDIR/$STATE_DIR_REL/journal.json"
run_afk status --json
assert_eq "a journal path of the wrong type is unsafe, not absent" \
  "$(jget '.installed.journal_state')" "UNSAFE"
assert_eq "with its own stable reason" "$(has_finding_reason OPERATION_JOURNAL_PATH_UNSAFE)" "1"
assert_eq "and the installation is INTERRUPTED" "$(jget '.installed.state')" "INTERRUPTED"
rmdir "$HOMEDIR/$STATE_DIR_REL/journal.json"

printf '{"state": "COMMITTED"}\n' > "$SC/elsewhere-journal.json"
ln -s "$SC/elsewhere-journal.json" "$HOMEDIR/$STATE_DIR_REL/journal.json"
run_afk status --json
assert_eq "a journal redirected out of the state directory is unsafe" \
  "$(jget '.installed.journal_state')" "UNSAFE"
assert_eq "even though it claims to be committed" \
  "$(has_finding_reason OPERATION_JOURNAL_PATH_UNSAFE)" "1"
rm -f "$HOMEDIR/$STATE_DIR_REL/journal.json"

# ===========================================================================
head1 "7. Path type, containment and symlink boundaries fail closed"
# ===========================================================================

new_scenario paths
install_kit "$HOMEDIR" "$CHECKOUT"
write_manifest

# A managed copy file replaced by a symlink to somewhere else entirely. The
# lifecycle must refuse BEFORE reading it — proven with a secret in the target.
mkdir -p "$SC/elsewhere"
printf 'redirected content %s\n' "$SENTINEL" > "$SC/elsewhere/stolen.md"
rm -f "$HOMEDIR/.codex/AGENTS.md"
ln -s "$SC/elsewhere/stolen.md" "$HOMEDIR/.codex/AGENTS.md"
run_afk status --json
assert_eq "an unexpected symlink on a managed destination is BROKEN" \
  "$(component_field codex-global-guidance .state)" "BROKEN"
assert_eq "with the path-guard reason" \
  "$(component_field codex-global-guidance .reason)" "PATH_UNEXPECTED_SYMLINK"
assert_eq "and no identity was computed through it" \
  "$(component_field codex-global-guidance .evidence.observed)" "null"
assert_absent "nothing behind the redirection was read into the result" "$RUN_OUT" "$SENTINEL"
rm -f "$HOMEDIR/.codex/AGENTS.md"
cp "$CHECKOUT/files/codex-AGENTS.md" "$HOMEDIR/.codex/AGENTS.md"

# A symlink INSIDE a managed tree that escapes the ownership boundary.
ln -s "$SC/elsewhere/stolen.md" "$HOMEDIR/.agents/skills/model-router/escape.md"
run_afk status --json
assert_eq "a symlink escaping a managed tree is BROKEN" \
  "$(component_field model-router .state)" "BROKEN"
assert_eq "with the containment reason" \
  "$(component_field model-router .reason)" "PATH_ESCAPES_OWNERSHIP_BOUNDARY"
assert_eq "and names the offending member" \
  "$(component_field model-router .detail)" "escape.md"
assert_absent "the escaped content never reaches the result" "$RUN_OUT" "$SENTINEL"
rm -f "$HOMEDIR/.agents/skills/model-router/escape.md"

# A managed link repointed outside the declared ownership boundary.
rm -f "$HOMEDIR/.claude/skills/model-router"
ln -s "$SC/elsewhere" "$HOMEDIR/.claude/skills/model-router"
run_afk status --json
assert_eq "a managed link redirected outside its boundary is BROKEN" \
  "$(component_field model-router-claude-link .state)" "BROKEN"
assert_eq "with the containment reason" \
  "$(component_field model-router-claude-link .reason)" "PATH_ESCAPES_OWNERSHIP_BOUNDARY"
assert_eq "and it blocks a critical scope" \
  "$(component_field model-router-claude-link '.blocked_scopes | index("INSTALLED_INTEGRITY") != null')" "true"

# A managed link replaced by a real directory.
rm -f "$HOMEDIR/.claude/skills/model-router"
mkdir -p "$HOMEDIR/.claude/skills/model-router"
run_afk status --json
assert_eq "a real directory where a link is declared is BROKEN" \
  "$(component_field model-router-claude-link .state)" "BROKEN"
assert_eq "with the type reason" \
  "$(component_field model-router-claude-link .reason)" "PATH_NOT_A_SYMLINK"
rmdir "$HOMEDIR/.claude/skills/model-router"
ln -s "$HOMEDIR/.agents/skills/model-router" "$HOMEDIR/.claude/skills/model-router"

# A managed tree replaced by a plain file.
rm -rf "$HOMEDIR/.agents/skills/humanizer"
printf 'not a directory\n' > "$HOMEDIR/.agents/skills/humanizer"
run_afk status --json
assert_eq "a file where a managed tree is declared is BROKEN" \
  "$(component_field humanizer .state)" "BROKEN"
assert_eq "with the type reason" "$(component_field humanizer .reason)" "PATH_TYPE_MISMATCH"

# A PARENT directory of a managed destination redirected out of its container.
new_scenario parentredirect
install_kit "$HOMEDIR" "$CHECKOUT"
write_manifest
mkdir -p "$SC/outside"
mv "$HOMEDIR/.claude/skills" "$SC/outside/skills"
ln -s "$SC/outside/skills" "$HOMEDIR/.claude/skills"
run_afk status --json
assert_eq "a symlinked parent directory fails closed" \
  "$(component_field model-router-claude-link .reason)" "PATH_PARENT_ESCAPES_BOUNDARY"
assert_eq "the component is BROKEN, not silently followed" \
  "$(component_field model-router-claude-link .state)" "BROKEN"
assert_eq "and no identity was computed through it" \
  "$(component_field model-router-claude-link .evidence.observed)" "null"
assert_eq "components in other declared roots are unaffected" \
  "$(component_field codex-global-guidance .state)" "CURRENT"

# Malformed managed-section markers are never guessed at.
new_scenario markers
install_kit "$HOMEDIR" "$CHECKOUT"
write_manifest
{ cat "$HOMEDIR/.claude/CLAUDE.md"; section_begin claude-global-policy; printf '\n'; } \
  > "$HOMEDIR/.claude/CLAUDE.md.new"
mv "$HOMEDIR/.claude/CLAUDE.md.new" "$HOMEDIR/.claude/CLAUDE.md"
run_afk status --json
assert_eq "duplicated section markers are BROKEN, not best-effort" \
  "$(component_field claude-global-policy .state)" "BROKEN"
assert_eq "with a stable reason" \
  "$(component_field claude-global-policy .reason)" "MANAGED_SECTION_MARKERS_MALFORMED"
assert_eq "and it is not mutation-safe" \
  "$(component_field claude-global-policy .mutation_safe)" "false"

# ===========================================================================
head1 "8. Registered BMAD targets are scoped, never global"
# ===========================================================================
# One compatible target, one that exists but is not wired, and one that is not
# there at all. The point of the scenario is that all three coexist: neither
# broken target poisons the healthy one, and neither poisons the host.

new_scenario targets
install_kit "$HOMEDIR" "$CHECKOUT"
write_manifest
make_bmad_target "$SC/repo-ok"
mkdir -p "$SC/repo-bare"
manifest_patch ".targets = [{id: \"repo-ok\", path: \"$SC/repo-ok\"},
                            {id: \"repo-bare\", path: \"$SC/repo-bare\"},
                            {id: \"repo-gone\", path: \"$SC/repo-gone\"}]"
run_afk status --json
assert_eq "every registered target is inventoried" "$(jget '.targets | length')" "3"

assert_eq "a missing target is BROKEN" \
  "$(target_field repo-gone .reason)" "TARGET_PATH_MISSING"
assert_eq "and blocks only its own scope" \
  "$(target_field repo-gone '.blocked_scopes[0]')" "TARGET_READY:repo-gone"

assert_eq "a target that exists but is not wired is INCOMPATIBLE, not ready" \
  "$(target_field repo-bare .state)" "INCOMPATIBLE"
assert_eq "because directory presence is not compatibility" \
  "$(target_field repo-bare .reason)" "TARGET_WIRING_UNRECOGNIZED"
assert_eq "and it too blocks only its own scope" \
  "$(target_field repo-bare '.blocked_scopes[0]')" "TARGET_READY:repo-bare"

assert_eq "the wired target resolves mechanically" \
  "$(target_field repo-ok .state)" "READY"
assert_eq "with a stable reason" \
  "$(target_field repo-ok .reason)" "TARGET_WIRING_PROVEN"
assert_eq "and blocks nothing at all" \
  "$(target_field repo-ok '.blocked_scopes | length')" "0"

# Target A incompatible and target B compatible, side by side, with the
# aggregate refusing to collapse a set of repositories into one boolean.
assert_eq "the aggregate scope reports PARTIAL, never a single false" \
  "$(jget '.readiness.TARGET_READY.state')" "PARTIAL"
assert_eq "with its own reason" \
  "$(jget '.readiness.TARGET_READY.reason')" "TARGET_SCOPE_PARTIAL"
assert_eq "TARGET_READY(repo-ok) is true" \
  "$(jget '.readiness.TARGET_READY.targets[] | select(.id == "repo-ok") | .state')" "TRUE"
assert_eq "TARGET_READY(repo-bare) is false" \
  "$(jget '.readiness.TARGET_READY.targets[] | select(.id == "repo-bare") | .state')" "FALSE"
assert_eq "the wiring identity of the healthy target is bounded evidence" \
  "$(jget '.readiness.TARGET_READY.targets[] | select(.id == "repo-ok") | .wiring_identity | startswith("sha256:")')" "true"

assert_eq "no bad target makes the host not ready" \
  "$(jget '.overall.state')" "READY_WITH_WARNINGS"
assert_eq "and none of it fails the command" "$RUN_RC" "0"
assert_eq "installed integrity is untouched by any of it" \
  "$(jget '.readiness.INSTALLED_INTEGRITY.state')" "READY"

# ===========================================================================
head1 "9. No live probe is performed by default"
# ===========================================================================

new_scenario noprobe
install_kit "$HOMEDIR" "$CHECKOUT"
write_manifest

# Stub every external binary a live probe would have to use. Each records that
# it was called. If any marker appears, status crossed a boundary it promised
# not to cross.
STUBBIN="$SC/stubbin"; mkdir -p "$STUBBIN"
for prog in curl wget claude codex orca agent-stamp-validate op ssh nc; do
  cat > "$STUBBIN/$prog" <<STUB
#!/usr/bin/env bash
printf '%s\n' "$prog was invoked" >> "$SC/live-probe-marker"
exit 0
STUB
  chmod +x "$STUBBIN/$prog"
done
rm -f "$SC/live-probe-marker"

RUN_OUT="$(HOME="$HOMEDIR" XDG_STATE_HOME="$HOMEDIR/.local/state" \
           AFK_KIT_ROOT="$CHECKOUT" PATH="$STUBBIN:$PATH" \
           AGENT_ROUTER_URL="https://router.invalid" \
           AGENT_ROUTER_TOKEN="$SENTINEL" \
           bash "$AFK" status --json 2>"$TMPROOT/stderr")"
RUN_RC=$?

assert_no_file "no external binary was invoked" "$SC/live-probe-marker"
assert_eq "router availability is NOT_EVALUATED"   "$(jget '.live_facts.router_status.state')" "NOT_EVALUATED"
assert_eq "with the frozen reason code"            "$(jget '.live_facts.router_status.reason')" "LIVE_PROBE_NOT_REQUESTED"
assert_eq "native Claude session NOT_EVALUATED"    "$(jget '.live_facts.claude_native_session.state')" "NOT_EVALUATED"
assert_eq "native Codex session NOT_EVALUATED"     "$(jget '.live_facts.codex_native_session.state')" "NOT_EVALUATED"
assert_eq "Orca runtime NOT_EVALUATED"             "$(jget '.live_facts.orca_runtime.state')" "NOT_EVALUATED"
assert_eq "validator fixtures NOT_EVALUATED"       "$(jget '.live_facts.validator_fixtures.state')" "NOT_EVALUATED"
assert_eq "host execution readiness NOT_EVALUATED" "$(jget '.readiness.HOST_EXECUTION_READY.state')" "NOT_EVALUATED"
assert_eq "new-work readiness NOT_EVALUATED"       "$(jget '.readiness.NEW_WORK_READY.state')" "NOT_EVALUATED"
# Not-evaluated and out-of-scope stay distinguishable (FR-73).
assert_eq "route readiness is OUT_OF_SCOPE, not merely unprobed" \
  "$(jget '.readiness.ROUTE_READY.state')" "OUT_OF_SCOPE"
assert_eq "with its own reason" \
  "$(jget '.readiness.ROUTE_READY.reason')" "NO_EXECUTION_STAMP_SUPPLIED"
assert_eq "an unprobed live fact is never reported as evaluated" \
  "$(jget '.live_facts.router_status.evaluated')" "false"
assert_eq "an offline-evaluated scope is reported as evaluated" \
  "$(jget '.readiness.INSTALLED_INTEGRITY.evaluated')" "true"

# Executable RESOLUTION is a filesystem fact and IS evaluated by default — the
# binaries above are on PATH — and it still starts none of them.
assert_eq "the resolution of a stubbed harness is reported" \
  "$(jget '.live_facts.claude_executable.state')" "PRESENT"
assert_no_file "and resolving it still invoked nothing" "$SC/live-probe-marker"

# ===========================================================================
head1 "10. Secrets never reach emitted output (end to end, every path)"
# ===========================================================================

new_scenario secrets
install_kit "$HOMEDIR" "$CHECKOUT"
write_manifest

# Two distinct paths a secret could take into the result: the environment, and
# a file the lifecycle demonstrably reads.
printf 'launcher:\n  token: %s\n' "$SENTINEL" \
  > "$HOMEDIR/.agents/skills/model-router/subscriptions.yaml"
printf '\n# a private note containing %s\n' "$SENTINEL" >> "$HOMEDIR/.claude/CLAUDE.md"

RUN_OUT="$(HOME="$HOMEDIR" XDG_STATE_HOME="$HOMEDIR/.local/state" \
           AFK_KIT_ROOT="$CHECKOUT" \
           ANTHROPIC_API_KEY="$SENTINEL" AGENT_ROUTER_TOKEN="$SENTINEL" \
           OP_SERVICE_ACCOUNT_TOKEN="$SENTINEL" \
           bash "$AFK" status --json 2>"$TMPROOT/stderr")"
RUN_RC=$?
RUN_ERR="$(cat "$TMPROOT/stderr")"

assert_absent "no secret value appears in machine output" "$RUN_OUT" "$SENTINEL"
assert_absent "and none on stderr"                        "$RUN_ERR" "$SENTINEL"
assert_eq "conflicting variable names are still reported by name" \
  "$(jget '[.environment[] | select(.name == "ANTHROPIC_API_KEY" and .present)] | length')" "1"
assert_eq "and their values are marked redacted" \
  "$(jget '.environment[] | select(.name == "ANTHROPIC_API_KEY") | .value')" "[REDACTED]"
assert_eq "no environment record claims to have emitted a value" \
  "$(jget '[.environment[] | select(.value_emitted)] | length')" "0"

# The anti-vacuity half: prove the secret-bearing files really were read, by
# checking the reported identity against an independently computed hash.
assert_eq "the machine-local file WAS read (its identity matches its bytes)" \
  "$(component_field model-router-config .evidence.observed)" \
  "sha256:$(hash_of_file "$HOMEDIR/.agents/skills/model-router/subscriptions.yaml")"
assert_eq "the secret-bearing user file WAS read (its shape is reported)" \
  "$(component_field 'claude-global-policy:outside-section' '.evidence.observed | test("^[0-9]+ lines")')" "true"

# Evidence is bounded identifiers, never content: nothing long, nothing
# multi-line, which is what keeps a hash from becoming a file dump.
assert_eq "every evidence identifier is bounded and single-line" \
  "$(printf '%s' "$RUN_OUT" | jq -r '[.. | objects | select(has("evidence")) | .evidence
     | (.expected, .observed) | select(type == "string")
     | select((length > 512) or test("\n"))] | length')" "0"

# Each secret source is checked on its own: one leaking source is enough.
for var in ANTHROPIC_API_KEY AGENT_ROUTER_TOKEN OP_SERVICE_ACCOUNT_TOKEN CLAUDE_CONFIG_DIR; do
  one_out="$(HOME="$HOMEDIR" XDG_STATE_HOME="$HOMEDIR/.local/state" \
             AFK_KIT_ROOT="$CHECKOUT" env "$var=$SENTINEL" \
             bash "$AFK" status --json 2>&1)"
  assert_absent "no leak through $var alone" "$one_out" "$SENTINEL"
done

# Human output is the same model, and must be just as safe.
HUMAN_SECRET="$(HOME="$HOMEDIR" XDG_STATE_HOME="$HOMEDIR/.local/state" \
                AFK_KIT_ROOT="$CHECKOUT" ANTHROPIC_API_KEY="$SENTINEL" \
                bash "$AFK" status 2>&1)"
assert_absent "no secret value appears in human output" "$HUMAN_SECRET" "$SENTINEL"

# Failure paths are output paths too. A secret mistyped onto the command line,
# or present in the environment while the command fails, must not be echoed.
run_afk status "--$SENTINEL"
assert_eq "an unrecognized option is a usage failure" "$RUN_RC" "1"
assert_absent "and the offending argument is never echoed (stderr)" "$RUN_ERR" "$SENTINEL"
assert_absent "nor on stdout"                                       "$RUN_OUT" "$SENTINEL"
assert_contains "the diagnostic says an option was not recognized" "$RUN_ERR" "<unrecognized option>"

run_afk "$SENTINEL"
assert_eq "an unrecognized command is a usage failure" "$RUN_RC" "1"
assert_absent "and the command text is never echoed" "$RUN_ERR" "$SENTINEL"

run_afk status --json --require-source-eligible --not-real
assert_eq "an unknown option among valid ones still fails" "$RUN_RC" "1"

# An option VALUE is never echoed either, however it was mistyped.
run_afk status --stamp "$SENTINEL" --json
assert_absent "a --stamp value never reaches a diagnostic (stderr)" "$RUN_ERR" "$SENTINEL"
assert_absent "nor the machine result"                              "$RUN_OUT" "$SENTINEL"

# An internal failure path: the libraries cannot be found.
NOLIB_ERR="$(HOME="$HOMEDIR" AFK_LIB_DIR="$SC/no-such-lib-dir" \
             ANTHROPIC_API_KEY="$SENTINEL" bash "$AFK" status 2>&1)"
NOLIB_RC=$?
assert_eq "a missing library is a stable internal failure" "$NOLIB_RC" "1"
assert_contains "with a stable message" "$NOLIB_ERR" "required library"
assert_absent "and no environment value on that path either" "$NOLIB_ERR" "$SENTINEL"

# An undeclared HOME refuses rather than reading whatever /.claude happens to be.
NOHOME_ERR="$(env -u HOME -u XDG_STATE_HOME -u AFK_STATE_DIR -u AFK_MANIFEST \
                  -u AFK_JOURNAL -u AFK_SKILLS_HOME -u AFK_CLAUDE_HOME -u AFK_CODEX_HOME \
                  AFK_KIT_ROOT="$CHECKOUT" ANTHROPIC_API_KEY="$SENTINEL" \
                  bash "$AFK" status 2>&1)"
NOHOME_RC=$?
assert_eq "an undeclared HOME is a stable usage failure" "$NOHOME_RC" "1"
assert_contains "that names what must be declared" "$NOHOME_ERR" "HOME is not set"
assert_absent "and leaks nothing" "$NOHOME_ERR" "$SENTINEL"

# ===========================================================================
head1 "11. Repeated read-only evaluation is side-effect free and stable"
# ===========================================================================

# The very first invocation on a pristine host is the one most likely to create
# something (a state directory, a cache, a lock). It is checked on its own.
new_scenario firstrun
install_kit "$HOMEDIR" "$CHECKOUT"
FIRST_FP="$(fingerprint_tree "$HOMEDIR")"
run_afk status --json
assert_eq "the first ever run creates nothing on the host" \
  "$(fingerprint_tree "$HOMEDIR")" "$FIRST_FP"
assert_no_file "no state tree was created"  "$HOMEDIR/.local"
assert_no_file "no cache tree was created"  "$HOMEDIR/.cache"
assert_no_file "no config tree was created" "$HOMEDIR/.config"
run_afk adopt --inspect --json
assert_eq "and neither does the first adoption analysis" \
  "$(fingerprint_tree "$HOMEDIR")" "$FIRST_FP"

new_scenario idempotent
install_kit "$HOMEDIR" "$CHECKOUT"
write_manifest

HOME_FP_1="$(fingerprint_tree "$HOMEDIR")"
CO_FP_1="$(fingerprint_worktree "$CHECKOUT")"
GIT_ID_1="$(fingerprint_git_identity "$CHECKOUT")"
MANIFEST_HASH_1="$(hash_of_file "$HOMEDIR/$STATE_DIR_REL/state.json")"
STATE_FP_1="$(fingerprint_tree "$HOMEDIR/$STATE_DIR_REL")"

run_afk status --json; S1="$RUN_OUT"
run_afk status --json; S2="$RUN_OUT"
run_afk status --json; S3="$RUN_OUT"
run_afk status;        H1="$RUN_OUT"
run_afk status;        H2="$RUN_OUT"
run_afk status --require-source-eligible >/dev/null 2>&1
run_afk adopt --inspect --json
run_afk schema >/dev/null 2>&1

assert_eq "machine output is byte-stable across runs (1 vs 2)" "$S1" "$S2"
assert_eq "machine output is byte-stable across runs (2 vs 3)" "$S2" "$S3"
assert_eq "human output is byte-stable across runs"            "$H1" "$H2"
assert_eq "no timestamp leaked into the normalized result" \
  "$(printf '%s' "$S1" | jq -r '[paths(type == "string") as $p | getpath($p)
     | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))] | length')" "0"

# Every declared root is checked, including directories, modes and ownership.
assert_eq "the installed host is unchanged (contents, dirs, modes)" \
  "$(fingerprint_tree "$HOMEDIR")" "$HOME_FP_1"
assert_eq "the declared state directory is unchanged" \
  "$(fingerprint_tree "$HOMEDIR/$STATE_DIR_REL")" "$STATE_FP_1"
assert_eq "the checkout working tree is unchanged" \
  "$(fingerprint_worktree "$CHECKOUT")" "$CO_FP_1"
assert_eq "Git refs, reachable objects, HEAD and status are unchanged" \
  "$(fingerprint_git_identity "$CHECKOUT")" "$GIT_ID_1"
assert_eq "the state manifest was not rewritten" \
  "$(hash_of_file "$HOMEDIR/$STATE_DIR_REL/state.json")" "$MANIFEST_HASH_1"
assert_no_file "no lock file was created" "$HOMEDIR/$STATE_DIR_REL/lock"
assert_no_file "no journal was created"   "$HOMEDIR/$STATE_DIR_REL/journal.json"

# ===========================================================================
head1 "12. The machine contract itself"
# ===========================================================================

new_scenario contract
install_kit "$HOMEDIR" "$CHECKOUT"
write_manifest
printf 'edited by hand\n' >> "$HOMEDIR/.agents/skills/model-router/SKILL.md"
make_bmad_target "$SC/repo-ok"
manifest_patch ".targets = [{id: \"repo-ok\", path: \"$SC/repo-ok\"}]"
run_afk status --json

for key in schema_version kind command operation checkout installed source_eligibility \
           readiness live_facts orchestration environment components targets adaptations \
           findings overall next_safe_action; do
  assert_eq "top-level key present: $key" "$(jget "has(\"$key\")")" "true"
done
assert_eq "the result schema is versioned" "$(jget '.schema_version')" "1.0"
assert_eq "the command is identified"      "$(jget '.command')" "status"
assert_eq "the document declares its kind" "$(jget '.kind')" "lifecycle_result"

assert_eq "every component carries the full automation field set" \
  "$(printf '%s' "$RUN_OUT" | jq -r '[.components[]
     | select((has("id") and has("ownership") and has("state") and has("reason")
               and has("severity") and has("blocked_scopes") and has("owner")
               and has("owner_action_required") and has("mutation_safe")
               and has("transient") and has("evidence") and has("destination")) | not)] | length')" "0"
assert_eq "every finding carries the full automation field set" \
  "$(printf '%s' "$RUN_OUT" | jq -r '[.findings[]
     | select((has("component") and has("state") and has("reason") and has("severity")
               and has("blocked_scopes") and has("owner") and has("owner_action_required")
               and has("mutation_safe") and has("transient") and has("evidence")
               and has("message") and has("impact") and has("required_action")) | not)] | length')" "0"
assert_eq "every finding carries evidence provenance" \
  "$(printf '%s' "$RUN_OUT" | jq -r '[.findings[] | select(.evidence.provenance == null)] | length')" "0"
assert_eq "every finding severity is inside the frozen set" \
  "$(printf '%s' "$RUN_OUT" | jq -r '[.findings[] | select(.severity != "info" and .severity != "warning"
     and .severity != "owner_action" and .severity != "blocking")] | length')" "0"
assert_eq "every live fact carries the full automation field set" \
  "$(printf '%s' "$RUN_OUT" | jq -r '[.live_facts | to_entries[] | .value
     | select((has("state") and has("evaluated") and has("reason") and has("observed_at")
               and has("timeout_ms") and has("freshness_seconds")
               and has("evidence_provenance") and has("transient")
               and has("launch_authoritative")) | not)] | length')" "0"
assert_eq "no live fact ever claims launch authority" \
  "$(printf '%s' "$RUN_OUT" | jq -r '[.live_facts | to_entries[]
     | select(.value.launch_authoritative != false)] | length')" "0"
assert_eq "the exit code is carried in the document, not only in the process" \
  "$(jget '.overall.exit_code')" "$RUN_RC"

CONTRACT_JSON="$RUN_OUT"

# --- the published vocabulary, the document and the implementation agree ---
run_afk schema
SCHEMA_JSON="$RUN_OUT"
assert_eq "schema is valid JSON" "$(printf '%s' "$SCHEMA_JSON" | jq -r '.result_schema_version')" "1.0"

schema_vocab() { printf '%s' "$SCHEMA_JSON" | jq -r ".$1[]" | LC_ALL=C sort; }
doc_vocab() { # <key> — the machine-checkable block from the contract document
  awk -v key="$1" 'BEGIN { marker = "<!-- machine-checkable: " key " -->" }
    $0 == marker { inb = 1; next }
    inb && $0 == "<!-- end -->" { inb = 0 }
    inb && $0 !~ /^```/ && $0 != "" { print }
  ' "$CONTRACT_DOC" | LC_ALL=C sort
}

for key in commands component_states overall_states readiness_states target_states \
           live_fact_states orchestration_states orchestration_modes approved_harnesses \
           source_states ownership_classes severities readiness_scopes evidence_provenance \
           adaptation_dispositions adaptation_types adaptation_states adoption_dispositions \
           budget_states dispatch_result_statuses reason_codes; do
  s="$(schema_vocab "$key")"
  d="$(doc_vocab "$key")"
  if [[ -z "$s" ]]; then
    bad "schema publishes the $key vocabulary" "empty or missing in schema output"
  elif [[ "$s" == "$d" ]]; then
    ok "schema and contract document agree exactly on $key"
  else
    bad "schema and contract document agree exactly on $key" \
      "only in schema: $(comm -23 <(printf '%s\n' "$s") <(printf '%s\n' "$d") | tr '\n' ' ')|only in document: $(comm -13 <(printf '%s\n' "$s") <(printf '%s\n' "$d") | tr '\n' ' ')"
  fi
done

SCHEMA_EXITS="$(printf '%s' "$SCHEMA_JSON" | jq -r '.exit_codes | to_entries[] | "\(.key) \(.value)"' | LC_ALL=C sort)"
assert_eq "schema and contract document agree exactly on exit semantics" \
  "$SCHEMA_EXITS" "$(doc_vocab exit_codes)"
assert_contains "the exit vocabulary names the usage class" "$SCHEMA_EXITS" "command, internal, or usage failure"
assert_contains "and the owner-action class"                "$SCHEMA_EXITS" "owner action or conflict"

# Every reason the implementation actually emits is inside the published set.
#
# The value under test is bound to a jq VARIABLE before it reaches index().
# jq evaluates the ARGUMENT of index() against the INPUT of index() — the
# published array — so `$pub | index(.)` asks that array whether it contains
# ITSELF, which it always does, at index 0. The sweep would then select nothing
# and guard nothing. Each sweep therefore carries the executable falsifiability
# control the readiness gate carries: the same expression, run over a copy of
# the document with exactly one out-of-set value injected, must report exactly
# that one.
PUB_REASONS="$(printf '%s' "$SCHEMA_JSON" | jq -c '.reason_codes')"
unpublished_reasons() { # <document> -> how many reason strings are outside the set
  printf '%s' "$1" | jq -r --argjson pub "$PUB_REASONS" \
    '[.. | objects | .reason? | select(type == "string")
      | . as $r | select(($pub | index($r)) == null)] | length'
}
assert_eq "every reason code in a status result is published" \
  "$(unpublished_reasons "$CONTRACT_JSON")" "0"
assert_eq "and that sweep still FAILS on an unpublished code" \
  "$(unpublished_reasons "$(printf '%s' "$CONTRACT_JSON" \
     | jq -c '.readiness.ROUTE_READY.reason = "NOT_A_PUBLISHED_CODE"')")" "1"
assert_eq "the published vocabulary has no duplicate codes" \
  "$(printf '%s' "$SCHEMA_JSON" | jq -r '.reason_codes[]' | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')" "0"
run_afk adopt --inspect --json
ADOPT_SWEEP_JSON="$RUN_OUT"
assert_eq "every reason code in an adoption result is published" \
  "$(unpublished_reasons "$ADOPT_SWEEP_JSON")" "0"
assert_eq "and that sweep still FAILS on an unpublished code" \
  "$(unpublished_reasons "$(printf '%s' "$ADOPT_SWEEP_JSON" \
     | jq -c '.readiness.ROUTE_READY.reason = "NOT_A_PUBLISHED_CODE"')")" "1"

# --- human output is a COMPLETE projection of the same document -----------
run_afk status
HUMAN="$RUN_OUT"

MISSING=""
while IFS= read -r needle; do
  [[ -n "$needle" ]] || continue
  if [[ "$HUMAN" != *"$needle"* ]]; then MISSING="${MISSING}[$needle] "; fi
done < <(printf '%s' "$CONTRACT_JSON" | jq -r '
  [ .command, .schema_version, .checkout.revision, .checkout.repository_identity,
    .checkout.declaration, .installed.state, .installed.applied_revision,
    .installed.journal_state, .source_eligibility.state,
    .source_eligibility.revision_relation, .overall.state,
    (.overall.exit_code | tostring), .next_safe_action ]
  + [ .source_eligibility.reasons[] ]
  + [ .components[] | .id, .state, .destination ]
  + [ .components[] | select(.reason != null) | .reason ]
  + [ .components[] | select(.evidence.observed != null) | .evidence.observed ]
  + [ .findings[] | .reason, .message, .required_action ]
  + [ .readiness | to_entries[] | .key, .value.state ]
  + [ .readiness.TARGET_READY.targets[] | .id, .state, .reason, .path ]
  + [ .live_facts | to_entries[] | .key, .value.state, .value.reason ]
  + [ .orchestration | .state, .reason ]
  + [ .environment[] | .name ]
  + [ .targets[] | .id, .state, .path ]
  | map(select(. != null and . != "")) | .[]')
assert_eq "human output is a complete projection of the machine document" "$MISSING" ""

# And the projection is not a coincidence of one healthy host: the adoption
# analysis is projected too.
run_afk adopt --inspect --json
ADOPT_JSON="$RUN_OUT"
run_afk adopt --inspect
ADOPT_HUMAN="$RUN_OUT"
MISSING=""
while IFS= read -r needle; do
  [[ -n "$needle" ]] || continue
  if [[ "$ADOPT_HUMAN" != *"$needle"* ]]; then MISSING="${MISSING}[$needle] "; fi
done < <(printf '%s' "$ADOPT_JSON" | jq -r '
  [ .extra.adoption.disposition ]
  + [ .extra.adoption.components[] | .id, .classification ]
  + [ .extra.adoption.components[] | select(.reason != null) | .reason ]
  | map(select(. != null and . != "")) | .[]')
assert_eq "the adoption analysis is projected into human output too" "$MISSING" ""

# ===========================================================================
head1 "13. Coarse, stable exit semantics"
# ===========================================================================

new_scenario exits
install_kit "$HOMEDIR" "$CHECKOUT"
write_manifest
run_afk status
assert_eq "a healthy host exits 0" "$RUN_RC" "0"

printf 'edited by hand\n' >> "$HOMEDIR/.agents/skills/model-router/SKILL.md"
run_afk status
assert_eq "owner action exits 2" "$RUN_RC" "2"

new_scenario exits2
install_kit "$HOMEDIR" "$CHECKOUT"
run_afk status
assert_eq "deterministic not-ready exits 3" "$RUN_RC" "3"

new_scenario exits3
install_kit "$HOMEDIR" "$CHECKOUT"
write_manifest
printf 'scratch\n' > "$CHECKOUT/files/scratch-dirty.txt"
run_afk status --require-source-eligible
assert_eq "source refusal in the requested scope exits 4" "$RUN_RC" "4"
run_afk status
assert_eq "and the same state without that scope still exits 0" "$RUN_RC" "0"
rm -f "$CHECKOUT/files/scratch-dirty.txt"

# Every verb answers for itself. The mutating verbs are implemented (their own
# gate is tests/lifecycle-mutation-tests.sh); what this suite pins is that each
# one still returns a coarse, stable code from the frozen set on a healthy,
# already-converged host — and that none of them writes anything there.
run_afk adopt
assert_eq "adopting an already-adopted host is an owner-action refusal" "$RUN_RC" "2"
assert_contains "and says which state it refused on" "$RUN_OUT" "ADOPTION_NOT_APPLICABLE_ALREADY_ADOPTED"
run_afk update
assert_eq "update at the applied revision is a stable no-op (exit 0)" "$RUN_RC" "0"
assert_contains "and says it required no mutation" "$RUN_OUT" "PLAN_NO_CHANGE_REQUIRED"
run_afk verify
assert_eq "offline verification of a healthy host exits 0" "$RUN_RC" "0"
assert_contains "and reports itself verified" "$RUN_OUT" "verified=true"
run_afk not-a-command
assert_eq "an unknown command is a usage failure" "$RUN_RC" "1"
run_afk status --not-an-option
assert_eq "an unknown option is a usage failure" "$RUN_RC" "1"
run_afk help
assert_eq "help exits 0" "$RUN_RC" "0"
assert_contains "and documents the exit contract" "$RUN_OUT" "owner action or conflict"

# Options are validated against the command they were given to.
run_afk status --inspect
assert_eq "an option belonging to another command is refused" "$RUN_RC" "1"
run_afk schema --json
assert_eq "schema takes no options" "$RUN_RC" "1"
run_afk adopt --inspect --require-source-eligible
assert_eq "adopt does not accept the status-only scope option" "$RUN_RC" "1"
run_afk status --dry-run
assert_eq "the undocumented --dry-run alias does not exist" "$RUN_RC" "1"
run_afk adopt --inspect --plan
assert_eq "inspect and plan are different questions, not one command" "$RUN_RC" "1"
run_afk update --plan --approve-plan sha256:whatever
assert_eq "an approval has nothing to authorize on a plan-only run" "$RUN_RC" "1"
run_afk update --approve-plan
assert_eq "an approval without its plan identity is a usage failure" "$RUN_RC" "1"
run_afk adopt --live
assert_eq "a mutating verb does not accept live readiness options" "$RUN_RC" "1"
run_afk status --synthetic-route
assert_eq "a synthetic route request without --live is a usage failure" "$RUN_RC" "1"
run_afk status --target repo-ok
assert_eq "--target without the --stamp it binds is a usage failure" "$RUN_RC" "1"
run_afk status --stamp
assert_eq "--stamp without its path is a usage failure" "$RUN_RC" "1"

# The refusing and no-op verbs really did nothing.
FP_BEFORE="$(fingerprint_tree "$HOMEDIR")"
run_afk adopt
run_afk update
run_afk verify
run_afk not-a-command
assert_eq "the refused verbs changed nothing at all" "$(fingerprint_tree "$HOMEDIR")" "$FP_BEFORE"

# ===========================================================================
head1 "14. The coordinator's own artifacts (lane D)"
# ===========================================================================
#
# A PM artifact carries pointers and bounded summaries, is secret-free by rule,
# and is settled atomically: a refused submission leaves what is on disk as it was.
#
# AC-2: this section never called new_scenario itself — it relied on whichever
# section ran immediately before it leaving HOMEDIR/CHECKOUT set, so it only
# passed because everything runs in order. It now builds its own scenario, so
# it passes when run first or on its own too.
new_scenario pmartifacts
PMD="$HOMEDIR/.local/state/agent-flow-kit/pm"
# This section intentionally owns one synthetic artifact location. Pin it so
# the assertions verify the explicit override contract rather than depending
# on the caller worktree namespace selected by the production default.
export AFK_PM_DIR="$PMD"
pm_doc() { # [extra jq object]  -> the submitted document
  local extra="${1:-}"; [[ -n "$extra" ]] || extra='{}'
  jq -nc "{schema:\"afk-pm-checkpoint/1\", decisions:[\"story dispatched\"], envelope_actions:[], open_escalations:[],
           budget_state:{cycles:1}, in_flight_dispatches:[\"ctx_1\"], updated_at:\"2026-09-08T00:00:00Z\"} + $extra" > "$TMPROOT/pm-sub.json"
}

pm_doc
run_afk pm-checkpoint --json --write "$TMPROOT/pm-sub.json"
assert_eq "a valid checkpoint is accepted" "$RUN_RC" "0"
assert_eq "and written where the contract says" \
  "$(jq -r '.schema' "$PMD/checkpoint.json")" "afk-pm-checkpoint/1"
assert_eq "the result names the artifact it wrote" \
  "$(jget '.extra.pm_budget.checkpoint_artifact.path')" "$PMD/checkpoint.json"
# Story 1.6 owns the envelope vocabulary; an empty list is valid until it does.
assert_eq "an empty envelope_actions list is valid" \
  "$(jq -r '.envelope_actions | length' "$PMD/checkpoint.json")" "0"
GOOD="$(cat "$PMD/checkpoint.json")"

# Thin consumption is enforced, not merely asked for, and a submission that
# does not present the shape is refused whatever is wrong with it.
while IFS='|' read -r extra label; do
  if [[ "$extra" == "RAW" ]]; then printf 'not json' > "$TMPROOT/pm-sub.json"; else pm_doc "$extra"; fi
  run_afk pm-checkpoint --write "$TMPROOT/pm-sub.json"
  assert_eq "$label" "$RUN_RC" "1"
done <<CASES
{in_flight_dispatches:[{id:"ctx_1", transcript:"...the whole thing..."}]}|a dispatch BODY where an id belongs is refused
{decisions:"not a list"}|so is a member with the wrong type
{updated_at:""}|and one the contract requires but that carries nothing
{schema:"afk-pm-continuation/1"}|a document declaring another schema is about something else
RAW|and an unreadable submission
CASES
pm_doc
run_afk pm-checkpoint --continuation --write "$TMPROOT/pm-sub.json"
assert_eq "a continuation with no resume instruction is refused" "$RUN_RC" "1"
assert_absent "no continuation artifact was written for it" \
  "$(ls "$PMD" 2>/dev/null)" "continuation.json"

# --- secret-free BY RULE ---------------------------------------------------
pm_doc "{api_key:\"$SENTINEL\"}"
run_afk pm-checkpoint --json --write "$TMPROOT/pm-sub.json"
assert_eq "a secret-bearing member is refused, and not with a generic code" "$RUN_RC" "4"
assert_absent "the refused value reaches no result document" "$RUN_OUT" "$SENTINEL"
assert_absent "and no diagnostic"                            "$RUN_ERR" "$SENTINEL"
# A credential the member NAME cannot betray is caught by its shape.
pm_doc "{note:\"sk-$SENTINEL\"}"
run_afk pm-checkpoint --json --write "$TMPROOT/pm-sub.json"
assert_eq "a credential-shaped value under an innocent name is refused too" "$RUN_RC" "4"
assert_absent "and it is not echoed either" "$RUN_ERR" "$SENTINEL"
# And where one is likeliest: behind a flag in the resume command line, the one place a credential is never at the front of the value.
pm_doc "{schema:\"afk-pm-continuation/1\", resume_instruction:\"claude --resume PM --token sk-$SENTINEL\"}"
run_afk pm-checkpoint --json --continuation --write "$TMPROOT/pm-sub.json"
assert_eq "a credential embedded in a command line is refused as well" "$RUN_RC" "4"
assert_absent "without reaching the result document" "$RUN_OUT" "$SENTINEL"
assert_absent "or any diagnostic"                    "$RUN_ERR" "$SENTINEL"
assert_no_file "and no hand-over was written from it" "$PMD/continuation.json"

# --- atomic: a refusal never half-replaces what is already there -----------
assert_eq "every refusal above left the accepted artifact byte-identical" \
  "$(cat "$PMD/checkpoint.json")" "$GOOD"
assert_eq "and left no partial temporary behind" \
  "$(find "$PMD" -name '*.afk-tmp' 2>/dev/null | wc -l | tr -d ' ')" "0"
assert_eq "the artifact is readable by its owner alone" \
  "$(stat -c '%a' "$PMD/checkpoint.json" 2>/dev/null || stat -f '%OLp' "$PMD/checkpoint.json")" "600"

# The verb needs the submission it validates, and nothing else writes one.
run_afk pm-checkpoint --json
assert_eq "pm-checkpoint without --write is a usage failure" "$RUN_RC" "1"
run_afk status --write "$TMPROOT/pm-sub.json"
assert_eq "and --write means nothing to status" "$RUN_RC" "1"
unset AFK_PM_DIR

# ===========================================================================
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
