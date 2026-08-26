#!/usr/bin/env bash
# lifecycle-mutation-tests.sh — the isolated deterministic gate for the
# MUTATING half of the lifecycle: plans, approvals, adoption and update
# transactions, backups, rollback, interruption recovery and offline
# verification.
#
# Every scenario runs against a throwaway HOME and a throwaway Git checkout
# built from scratch under mktemp. Nothing here touches the developer's real
# HOME, real installation, real Git state, the router, a provider session, or
# Orca (AC-28, AC-30). The read-only surface has its own gate in
# tests/lifecycle-tests.sh; this suite is where destructive paths are proven.
#
# Layers:
#   UNIT      — the writers, the section machinery and the plan binding are
#               sourced and called directly, so byte-level preservation and
#               falsifiability are asserted on bytes.
#   SCENARIO  — bin/agent-flow-kit is RUN, and the machine-readable result,
#               the exit code and the filesystem afterwards are the assertion.
#
# Usage: tests/lifecycle-mutation-tests.sh
# Exit:  0 all passed, 1 any failure.

set -uo pipefail

KIT_ROOT="${PROBE_KIT_ROOT:?}"
AFK="$KIT_ROOT/bin/agent-flow-kit"
CONTRACT_DOC="$KIT_ROOT/docs/LIFECYCLE-CONTRACT.md"

TMPROOT="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"' EXIT

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
assert_file()     { if [[ -e "$2" ]]; then ok "$1"; else bad "$1" "missing: $2"; fi; }

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

make_checkout() { # <dir>
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

# A complete, healthy legacy installation with user-owned content on both
# sides of the managed section.
install_kit() { # <home> <checkout>
  local h="$1" c="$2"
  mkdir -p "$h/.agents/skills" "$h/.claude/skills" "$h/.codex"
  cp -R "$c/files/model-router" "$h/.agents/skills/model-router"
  cp -R "$c/files/humanizer" "$h/.agents/skills/humanizer"
  ln -s "$h/.agents/skills/model-router" "$h/.claude/skills/model-router"
  ln -s "$h/.agents/skills/humanizer" "$h/.claude/skills/humanizer"
  {
    printf '# my own notes, owned by me\n'
    printf 'a second personal line\n'
    section_begin claude-global-policy; printf '\n'
    cat "$c/files/claude-global-CLAUDE.md"
    section_end claude-global-policy; printf '\n'
    printf '# a trailing user note\n'
  } > "$h/.claude/CLAUDE.md"
  cp "$c/files/codex-AGENTS.md" "$h/.codex/AGENTS.md"
}

# A schema-2 recovery journal carrying complete authority for one step.
#
# Schema 2 requires the pre-mutation observation and the plan entry, because a
# recorded destination is evidence that a path was being touched and is never
# on its own authority to change or remove it. Every recovery scenario builds
# its journal here so that a scenario proving a REFUSAL differs from the
# authorized case in exactly the fact under test.
write_journal() { # <backup-dir> <component> <action> <destination> <pre-identity-or-empty> [state]
  jq -n --arg b "$1" --arg c "$2" --arg a "$3" --arg d "$4" --arg pre "$5" \
        --arg st "${6:-IN_PROGRESS}" \
    '{journal_schema_version: "2.0", state: $st, operation_id: "op-fixture",
      command: "update",
      backup_dir: (if $b == "" then null else $b end),
      rollback_state: "IN_PROGRESS",
      pre_mutation: [{component: $c,
                      observed_identity: (if $pre == "" then null else $pre end)}],
      plan: {command: "update", disposition: "MUTATION_REQUIRED",
             components: [{component: $c, action: $a, destination: $d,
                           expected_destination_identity: (if $pre == "" then null else $pre end),
                           target_identity: null, backup_required: true}]},
      completed_steps: [{component: $c, action: $a, result: "ATTEMPTED",
                         destination: $d}]}' > "$(journal_path)"
}

SC="" HOMEDIR="" CHECKOUT=""
new_scenario() { # <name>
  SC="$TMPROOT/sc-$1"
  HOMEDIR="$SC/home"
  CHECKOUT="$SC/checkout"
  mkdir -p "$HOMEDIR" "$CHECKOUT"
  make_checkout "$CHECKOUT"
}

RUN_OUT="" RUN_ERR="" RUN_RC=0
run_afk() { # <args...>
  RUN_OUT="$(HOME="$HOMEDIR" \
             XDG_STATE_HOME="$HOMEDIR/.local/state" \
             AFK_KIT_ROOT="$CHECKOUT" \
             bash "$AFK" "$@" 2>"$TMPROOT/stderr")"
  RUN_RC=$?
  RUN_ERR="$(cat "$TMPROOT/stderr" 2>/dev/null)"
}

jget() { printf '%s' "$RUN_OUT" | jq -r "$1"; }

plan_field() { # <component-id> <field>
  printf '%s' "$RUN_OUT" | jq -r --arg id "$1" ".extra.plan.components[] | select(.component == \$id) | .$2"
}

component_field() { # <component-id> <field-expr>
  printf '%s' "$RUN_OUT" | jq -r --arg id "$1" ".components[] | select(.id == \$id) | $2"
}

STATE_DIR_REL=".local/state/agent-flow-kit"
manifest_path() { printf '%s/%s/state.json' "$HOMEDIR" "$STATE_DIR_REL"; }
journal_path()  { printf '%s/%s/journal.json' "$HOMEDIR" "$STATE_DIR_REL"; }
lock_path()     { printf '%s/%s/lock' "$HOMEDIR" "$STATE_DIR_REL"; }

manifest_get() { jq -r "$1" "$(manifest_path)" 2>/dev/null; }

manifest_patch() { # <jq filter>
  local f
  f="$(manifest_path)"
  jq "$1" "$f" > "$f.new" && mv "$f.new" "$f"
}

# The journal's own identity, or "absent" when there is none.
#
# A journal is OPENED only when an executable, conflict-free plan reaches the
# mutation boundary, and a committed journal is deliberately LEFT on disk
# afterwards as the record of the last completed operation (LIFECYCLE-CONTRACT
# step 9). So "this command opened no journal" is proven by the journal not
# MOVING, not by its absence: on a host that has ever been adopted, absence is
# the wrong question and would pass or fail for the wrong reason.
journal_fingerprint() {
  local j
  j="$(journal_path)"
  if [[ -e "$j" ]]; then hash_of_file "$j"; else printf 'absent'; fi
}

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

# The identities the lifecycle itself computes, computed independently here.
tree_id()    { bash -c '. "$1/lib/afk-common.sh"; afk_tree_identity "$2" "$3"' _ "$KIT_ROOT" "$1" "${2:-}"; }
# A component identity is "sha256:<hex>", not bare hex: a journal fixture that
# records the bare digest records something the lifecycle will never observe.
file_id()    { bash -c '. "$1/lib/afk-common.sh"; afk_sha256_file "$2"' _ "$KIT_ROOT" "$1"; }

# Host and boot identity derived from the library under test, so a lock fixture
# cannot drift from the identity construction the lock actually compares.
lib_identity() { # <host|boot>
  bash -c '. "$1/lib/afk-common.sh"; . "$1/lib/afk-plan.sh"; . "$1/lib/afk-mutate.sh"
           if [[ "$2" == host ]]; then afk_host_identity; else afk_boot_identity; fi' \
    _ "$KIT_ROOT" "$1"
}

# The start identity of a running process, the way the lock records it.
proc_start_identity() { # <pid>
  bash -c '. "$1/lib/afk-common.sh"; . "$1/lib/afk-plan.sh"; . "$1/lib/afk-mutate.sh"
           afk_process_start_identity "$2"' _ "$KIT_ROOT" "$1"
}

# The lock schema and a fresh incarnation, both taken from the library, so no
# fixture below can drift from the record the lock actually writes or from the
# token shape its reader demands.
lib_lock_schema() {
  bash -c '. "$1/lib/afk-common.sh"; . "$1/lib/afk-plan.sh"; . "$1/lib/afk-mutate.sh"
           printf "%s" "$AFK_LOCK_SCHEMA_VERSION"' _ "$KIT_ROOT"
}
lib_incarnation() {
  bash -c '. "$1/lib/afk-common.sh"; . "$1/lib/afk-plan.sh"; . "$1/lib/afk-mutate.sh"
           afk_lock_incarnation_new' _ "$KIT_ROOT"
}

# A lock held by an owner this host can prove is ALIVE: the test process itself.
write_live_lock() {
  mkdir -p "$(lock_path)"
  jq -n --arg v "$(lib_lock_schema)" --arg h "$(lib_identity host)" \
        --arg b "$(lib_identity boot)" --arg p "$$" \
        --arg st "$(proc_start_identity "$$")" --arg inc "$(lib_incarnation)" \
    '{lock_schema_version: $v, host_identity: $h, boot_identity: $b,
      pid: ($p | tonumber), process_start_identity: $st,
      incarnation: $inc, complete: true}' \
    > "$(lock_path)/owner.json"
}

# Wait until a contender is provably INSIDE the publication wait rather than
# merely slow to get there. A waiting acquisition pauses in a `sleep` child, so
# "a child of that pid is sleeping" is a fact this host can observe instead of
# a duration this host has to guess. Bounded, and it gives up the instant the
# contender exits -- which is exactly what a tree that condemns the window does,
# and is the failure being pinned.
wait_until_contender_pauses() { # <pid>
  local pid="$1" i=0 c g
  while kill -0 "$pid" 2>/dev/null; do
    for c in $(cat "/proc/$pid/task/$pid/children" 2>/dev/null); do
      [[ "$(cat "/proc/$c/comm" 2>/dev/null)" == "sleep" ]] && return 0
      for g in $(cat "/proc/$c/task/$c/children" 2>/dev/null); do
        [[ "$(cat "/proc/$g/comm" 2>/dev/null)" == "sleep" ]] && return 0
      done
    done
    i=$((i + 1))
    (( i < 400000 )) || return 1
  done
  return 1
}

# A lock caught MID-PUBLICATION by an owner that is ALIVE. Taking the lock is
# two steps -- `mkdir` is the atomic test-and-set, the owner record appears an
# instant later -- and this fixture stops between them: the directory is
# created, the caller is told the window is open, and the record is published
# only when the caller says so. Every byte of that record still comes from the
# library, so only the timing is the fixture's. The process stays alive
# throughout, so what it publishes is an owner this host can prove is LIVE.
#
# Sets PUBLISHER_PID and writes the incarnation it will publish to <window>.inc.
hold_publication_window() { # <window-file> <publish-file> <let-go-file>
  HOME="$HOMEDIR" XDG_STATE_HOME="$HOMEDIR/.local/state" bash -c '
    . "$1/lib/afk-common.sh"; . "$1/lib/afk-source.sh"; . "$1/lib/afk-inventory.sh"
    . "$1/lib/afk-commands.sh"; . "$1/lib/afk-plan.sh"; . "$1/lib/afk-mutate.sh"
    AFK_STATE_DIR="$2"; AFK_LOCK_DIR="$2/lock"
    afk_state_dir_ensure "$AFK_STATE_DIR" || exit 1
    inc="$(afk_lock_incarnation_new)" || exit 1
    record="$(afk_lock_owner_record "$inc")" || exit 1
    mkdir -- "$AFK_LOCK_DIR" 2>/dev/null || exit 1
    chmod 700 -- "$AFK_LOCK_DIR" 2>/dev/null || true
    printf "%s" "$inc" > "$3.inc"
    : > "$3"
    i=0; while [[ ! -e "$4" ]]; do i=$((i + 1)); (( i < 60000000 )) || break; done
    afk_state_file_write "$AFK_LOCK_DIR/owner.json" "$record" || exit 1
    i=0; while [[ ! -e "$5" ]]; do i=$((i + 1)); (( i < 60000000 )) || break; done
  ' _ "$KIT_ROOT" "$HOMEDIR/$STATE_DIR_REL" "$1" "$2" "$3" &
  PUBLISHER_PID=$!
}

# An abandoned lock written by the LIBRARY in a process that then exits, so the
# owner it names is provably gone and the record is one the kit really wrote.
# Prints the incarnation it stranded.
strand_lock() {
  HOME="$HOMEDIR" XDG_STATE_HOME="$HOMEDIR/.local/state" bash -c '
    . "$1/lib/afk-common.sh"; . "$1/lib/afk-source.sh"; . "$1/lib/afk-inventory.sh"
    . "$1/lib/afk-commands.sh"; . "$1/lib/afk-plan.sh"; . "$1/lib/afk-mutate.sh"
    AFK_STATE_DIR="$2"; AFK_LOCK_DIR="$2/lock"
    afk_state_dir_ensure "$AFK_STATE_DIR" || exit 1
    afk_lock_take >/dev/null 2>&1 || exit 1
    printf "%s" "$AFK_LOCK_INCARNATION"
  ' _ "$KIT_ROOT" "$HOMEDIR/$STATE_DIR_REL"
}
outside_id() {
  bash -c '. "$1/lib/afk-common.sh"; . "$1/lib/afk-plan.sh"; . "$1/lib/afk-mutate.sh"
           afk_outside_bytes "$2" "$3" | afk_sha256_stdin' _ "$KIT_ROOT" "$1" "$2"
}

# Establish ownership the way an operator would: through the real transaction.
adopt_host() {
  run_afk adopt --json
  if [[ "$RUN_RC" != "0" ]]; then
    bad "fixture: adopt established ownership" \
      "exit $RUN_RC: $(printf '%s' "$RUN_OUT" | jq -r '.operation.reason // "?"' 2>/dev/null)"
  fi
}

# ===========================================================================
head1 "0. Managed-section writes preserve user-owned bytes (unit)"
# ===========================================================================

# shellcheck source=../lib/afk-common.sh
. "$KIT_ROOT/lib/afk-common.sh"
# The declared component inventory is a DEPENDENCY of the plan binding, not an
# optional companion: afk_plan_binding_compute enumerates afk_component_table,
# so a unit layer that omits it would bind nothing at all.
# shellcheck source=../lib/afk-inventory.sh
. "$KIT_ROOT/lib/afk-inventory.sh"
# shellcheck source=../lib/afk-plan.sh
. "$KIT_ROOT/lib/afk-plan.sh"
# shellcheck source=../lib/afk-mutate.sh
. "$KIT_ROOT/lib/afk-mutate.sh"

U="$TMPROOT/unit"; mkdir -p "$U"
printf 'new payload one\nnew payload two\n' > "$U/payload.md"
printf 'no trailing newline payload' > "$U/payload-nonewline.md"

build_section_file() { # <path> <leading> <payload> <trailing>
  { printf '%s' "$2"
    section_begin s1; printf '\n'
    printf '%s' "$3"
    section_end s1; printf '\n'
    printf '%s' "$4"; } > "$1"
}

# --- upgrading an existing section ----------------------------------------
build_section_file "$U/upgrade.md" 'leading one
leading two
' 'old payload
' 'trailing one
trailing two
'
OUTSIDE_BEFORE="$(afk_outside_bytes "$U/upgrade.md" s1 | afk_sha256_stdin)"
if afk_write_managed_section "$U/upgrade.md" s1 "$U/payload.md"; then
  ok "section upgrade: the write succeeds"
else
  bad "section upgrade: the write succeeds"
fi
assert_eq "section upgrade: outside content is byte-identical" \
  "$(afk_outside_bytes "$U/upgrade.md" s1 | afk_sha256_stdin)" "$OUTSIDE_BEFORE"
assert_eq "section upgrade: the payload is the canonical payload" \
  "$(afk_section_identity "$U/upgrade.md" s1)" "$(afk_file_payload_identity "$U/payload.md")"
assert_eq "section upgrade: leading bytes survive" \
  "$(head -n 2 "$U/upgrade.md")" "$(printf 'leading one\nleading two')"
assert_eq "section upgrade: trailing bytes survive" \
  "$(tail -n 2 "$U/upgrade.md")" "$(printf 'trailing one\ntrailing two')"
assert_eq "section upgrade: exactly one begin marker remains" \
  "$(grep -c -x -F -- "$(section_begin s1)" "$U/upgrade.md")" "1"
assert_eq "section upgrade: exactly one end marker remains" \
  "$(grep -c -x -F -- "$(section_end s1)" "$U/upgrade.md")" "1"

# --- a file whose last line has no final newline --------------------------
build_section_file "$U/nonl.md" 'leading
' 'old
' 'trailing without newline'
OUTSIDE_BEFORE="$(afk_outside_bytes "$U/nonl.md" s1 | afk_sha256_stdin)"
afk_write_managed_section "$U/nonl.md" s1 "$U/payload.md"
assert_eq "missing final newline: outside content is still byte-identical" \
  "$(afk_outside_bytes "$U/nonl.md" s1 | afk_sha256_stdin)" "$OUTSIDE_BEFORE"
assert_eq "missing final newline: the file still ends without one" \
  "$(tail -c 1 "$U/nonl.md")" "e"

# --- CRLF content outside the section -------------------------------------
{ printf 'crlf leading\r\n'
  section_begin s1; printf '\n'
  printf 'old payload\n'
  section_end s1; printf '\n'
  printf 'crlf trailing\r\n'; } > "$U/crlf.md"
assert_eq "the CRLF fixture really carries carriage returns" \
  "$(grep -c $'\r' "$U/crlf.md")" "2"
OUTSIDE_BEFORE="$(afk_outside_bytes "$U/crlf.md" s1 | afk_sha256_stdin)"
afk_write_managed_section "$U/crlf.md" s1 "$U/payload.md"
assert_eq "CRLF outside content is preserved byte for byte" \
  "$(afk_outside_bytes "$U/crlf.md" s1 | afk_sha256_stdin)" "$OUTSIDE_BEFORE"
assert_eq "and the carriage returns are still there afterwards" \
  "$(grep -c $'\r' "$U/crlf.md")" "2"

# --- a payload with no final newline still terminates the marker line -----
build_section_file "$U/payload-nl.md" 'lead
' 'old
' 'tail
'
afk_write_managed_section "$U/payload-nl.md" s1 "$U/payload-nonewline.md"
assert_eq "a payload without a final newline does not swallow the end marker" \
  "$(grep -c -x -F -- "$(section_end s1)" "$U/payload-nl.md")" "1"
assert_eq "and the section identity still matches the canonical payload" \
  "$(afk_section_identity "$U/payload-nl.md" s1)" \
  "$(afk_file_payload_identity "$U/payload-nonewline.md")"

# --- insertion into a file that has no section yet -------------------------
printf 'user line one\nuser line two\n' > "$U/insert.md"
cp "$U/insert.md" "$U/insert.before"
afk_write_managed_section "$U/insert.md" s1 "$U/payload.md"
if head -c "$(wc -c < "$U/insert.before")" "$U/insert.md" | cmp -s - "$U/insert.before"; then
  ok "insertion: the original bytes are still the head of the file, unmoved"
else
  bad "insertion: the original bytes are still the head of the file, unmoved"
fi
assert_eq "insertion: the section is present with the canonical payload" \
  "$(afk_section_identity "$U/insert.md" s1)" "$(afk_file_payload_identity "$U/payload.md")"
assert_eq "insertion: outside content equals the original file" \
  "$(afk_outside_bytes "$U/insert.md" s1 | afk_sha256_stdin)" \
  "$(afk_sha256_file "$U/insert.before")"

# --- insertion into a file with no final newline (the contracted exception)
printf 'user line without newline' > "$U/insert2.md"
cp "$U/insert2.md" "$U/insert2.before"
afk_write_managed_section "$U/insert2.md" s1 "$U/payload.md"
assert_eq "insertion adds exactly one contracted newline, and nothing else" \
  "$(afk_outside_bytes "$U/insert2.md" s1 | afk_sha256_stdin)" \
  "$(afk_cat_terminated "$U/insert2.before" | afk_sha256_stdin)"
assert_eq "the user's line is still intact" \
  "$(head -n 1 "$U/insert2.md")" "user line without newline"

# --- insertion into a file that does not exist ----------------------------
rm -f "$U/fresh.md"
afk_write_managed_section "$U/fresh.md" s1 "$U/payload.md"
assert_file "insertion creates the host file when it is absent" "$U/fresh.md"
assert_eq "and the created file carries exactly the section" \
  "$(afk_section_identity "$U/fresh.md" s1)" "$(afk_file_payload_identity "$U/payload.md")"

# --- malformed markers are recognized as malformed, never guessed at ------
{ printf 'x\n'; section_begin s1; printf '\n'; printf 'p\n'; section_end s1; printf '\n'
  section_begin s1; printf '\n'; } > "$U/malformed.md"
afk_section_extract "$U/malformed.md" s1 >/dev/null
assert_eq "a duplicated marker is malformed (3), so no plan will write to it" "$?" "3"

# --- backup and restore round-trip ----------------------------------------
AFK_OP_BACKUP_DIR="$U/backups"
mkdir -p "$U/tree/sub"
printf 'one\n' > "$U/tree/a.txt"
printf 'two\n' > "$U/tree/sub/b.txt"
ln -sf "a.txt" "$U/tree/link.txt"
TREE_ID_BEFORE="$(afk_tree_identity "$U/tree" "")"
assert_eq "backup: a managed tree is stored" \
  "$(afk_backup_component tree "$U/tree" && echo ok)" "ok"
rm -rf "$U/tree"
assert_eq "restore: the tree comes back with the same identity" \
  "$(afk_restore_component tree "$U/tree" "$AFK_OP_BACKUP_DIR" false >/dev/null; afk_tree_identity "$U/tree" "")" \
  "$TREE_ID_BEFORE"
assert_eq "restore: a symlink inside the tree is restored as a symlink" \
  "$(readlink "$U/tree/link.txt")" "a.txt"

printf 'link target\n' > "$U/linktarget.txt"
ln -sfn "$U/linktarget.txt" "$U/managed.link"
afk_backup_component mlink "$U/managed.link"
rm -f "$U/managed.link"
ln -sfn "$U/tree" "$U/managed.link"
afk_restore_component mlink "$U/managed.link" "$AFK_OP_BACKUP_DIR" false
assert_eq "restore: a managed link is repointed at its stored target" \
  "$(readlink "$U/managed.link")" "$U/linktarget.txt"

# F1 REGRESSION. The absence of a stored copy is NOT by itself permission to
# delete a path. Without proven removal authority the restore FAILS and the
# destination is left exactly as it was found; with it, and only with it, the
# path the operation created is removed.
printf 'created by the operation\n' > "$U/created.txt"
CREATED_BEFORE="$(hash_of_file "$U/created.txt")"
if afk_restore_component never-backed-up "$U/created.txt" "$AFK_OP_BACKUP_DIR" false; then
  bad "F1 restore: an unauthorized removal fails rather than deleting"
else
  ok "F1 restore: an unauthorized removal fails rather than deleting"
fi
assert_file "F1 restore: and the destination is untouched" "$U/created.txt"
assert_eq  "F1 restore: byte for byte" "$(hash_of_file "$U/created.txt")" "$CREATED_BEFORE"
if afk_restore_component never-backed-up "$U/created.txt" "$AFK_OP_BACKUP_DIR" true; then
  ok "F1 restore: proven removal authority removes what the operation created"
else
  bad "F1 restore: proven removal authority removes what the operation created"
fi
assert_no_file "restore: a destination the operation created is removed" "$U/created.txt"
# ===========================================================================
head1 "REVIEWER PROBE: the reclamation report on EVERY exit a mutating run has"
# ===========================================================================
count_reclaimed() { jq -r '[.findings[]?.reason | select(. == "OPERATION_LOCK_RECLAIMED")] | length' "$1" 2>/dev/null; }

# --- (a) the CONVERGED exit: a run that reclaims an abandoned lock and then
#         goes on to win the take and converge, must report exactly once.
new_scenario probeconverged
install_kit "$HOMEDIR" "$CHECKOUT"
adopt_host
printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
git_commit_all "$CHECKOUT" "canonical v2"
PC_INC="$(strand_lock)"
assert_ne "PROBE an abandoned lock was stranded" "$PC_INC" ""
PC_OUT="$SC/pc.json"
HOME="$HOMEDIR" XDG_STATE_HOME="$HOMEDIR/.local/state" AFK_KIT_ROOT="$CHECKOUT" \
  bash "$AFK" update --json > "$PC_OUT" 2>/dev/null
PC_RC=$?
assert_eq "PROBE the run converged over the abandoned lock" \
  "$(jq -r '.operation.result // ""' "$PC_OUT")" "CONVERGED"
assert_eq "PROBE and reported the destruction exactly once" "$(count_reclaimed "$PC_OUT")" "1"
assert_contains "PROBE naming the owner it proved was gone" \
  "$(jq -r '[.findings[]?|select(.reason=="OPERATION_LOCK_RECLAIMED")|.evidence.observed][0] // ""' "$PC_OUT")" "pid "
assert_eq "PROBE which is the ok exit" "$PC_RC" "0"
rm -rf -- "$(lock_path)"

# --- (b) the RECOVERY exit: an INTERRUPTED journal resolves under its own
#         acquisition -- a different afk_lock_acquire call site, a different
#         emission point, and one no retained fixture exercises with a
#         reclamation in flight.
new_scenario proberecovery
install_kit "$HOMEDIR" "$CHECKOUT"
adopt_host
printf 'model-router skill v2\n' > "$CHECKOUT/files/model-router/SKILL.md"
git_commit_all "$CHECKOUT" "canonical v2"
# an interrupted operation, produced exactly the way the retained
# `interrupted` scenario produces one: a backup, a journal that says a write
# was attempted, and a half-applied destination.
PR_BACKUPS="$HOMEDIR/$STATE_DIR_REL/backups/op-probe"
mkdir -p "$PR_BACKUPS"
cp "$HOMEDIR/.codex/AGENTS.md" "$PR_BACKUPS/codex-global-guidance"
PR_PRE="$(file_id "$HOMEDIR/.codex/AGENTS.md")"
printf 'half applied content\n' > "$HOMEDIR/.codex/AGENTS.md"
write_journal "$PR_BACKUPS" codex-global-guidance REPLACE "$HOMEDIR/.codex/AGENTS.md" "$PR_PRE"
PR_STATE="$(jq -r '.state // ""' "$(journal_path)" 2>/dev/null)"
assert_eq "PROBE the journal really is open" "$PR_STATE" "IN_PROGRESS"
PR_INC="$(strand_lock)"
assert_ne "PROBE an abandoned lock was stranded alongside the open journal" "$PR_INC" ""
PR_OUT="$SC/pr.json"
HOME="$HOMEDIR" XDG_STATE_HOME="$HOMEDIR/.local/state" AFK_KIT_ROOT="$CHECKOUT" \
  bash "$AFK" update --json > "$PR_OUT" 2>/dev/null
PR_RC=$?
printf '        [probe] journal state was: %s ; result=%s reason=%s reclaimed=%s\n' \
  "$PR_STATE" "$(jq -r '.operation.result // ""' "$PR_OUT")" \
  "$(jq -r '.operation.reason // ""' "$PR_OUT")" "$(count_reclaimed "$PR_OUT")"
assert_eq "PROBE the recovery exit reports the destruction exactly once" \
  "$(count_reclaimed "$PR_OUT")" "1"
rm -rf -- "$(lock_path)"

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 )) || exit 1
